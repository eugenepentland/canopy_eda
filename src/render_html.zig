//! Schematic HTML renderer: `renderToHtml` turns a `*const DesignBlock` into
//! the full server-rendered `/schematics/:name` page — hub-and-spoke inline SVG
//! (via `render_svg/` over a shared `RenderCtx` flatten/classify/adjacency pass)
//! plus the embedded review panels (power budget, coverage, checks). Read-only
//! over the block; page HTML is allocated into the caller's allocator. The JSON
//! scene-graph twin is `render_json.zig`.

const std = @import("std");
const env_mod = @import("eval/env.zig");
const rails_mod = @import("eval/rails.zig");
const parser_mod = @import("sexpr/parser.zig");
const infra_fs = @import("infra/fs.zig");
const ast = @import("sexpr/ast.zig");
const asserted_fns_mod = @import("asserted_fns.zig");
const erc_mod = @import("erc.zig");
const review = @import("review.zig");
const review_html = @import("review_html.zig");
const req_checks = @import("req_checks.zig");
const coverage = @import("coverage.zig");
pub const CheckResultMap = std.StringHashMapUnmanaged([]req_checks.Result);
const DesignBlock = env_mod.DesignBlock;
const Section = env_mod.Section;
const Instance = env_mod.Instance;
const AssertionResult = env_mod.AssertionResult;

const ctx_mod = @import("render_svg/context.zig");
const RenderCtx = ctx_mod.RenderCtx;
const FlatInst = ctx_mod.FlatInst;
const AdjEntry = ctx_mod.AdjEntry;
const PinGroup = ctx_mod.PinGroup;

const hub_mod = @import("render_svg/hub.zig");
const connection = @import("render_svg/connection.zig");
const draw = @import("render_svg/draw.zig");
const escape = @import("escape.zig");
const section_inset = @import("render_svg/section_inset.zig");
const block_diagram = @import("diagram/diagram.zig");
const membership = @import("diagram/membership.zig");
const rb = @import("render_block_types.zig");
const lib_limits = @import("lib_limits.zig");
const bom_html = @import("serve/bom_html.zig");
const pages_tmpl = @import("serve/templates/pages.zig");
const isHub = draw.isHub;
const pinOrder = draw.pinOrder;
const numeric = @import("numeric.zig");
const muted_em_dash = review_html.mutedDash;

// Shared table-row HTML fragments — reused across the port tables so the
// literals aren't duplicated (guardian's repeated-string-literal check).
const row_td_code_open = "<tr><td><code>";
const td_cell_sep = "</td><td>";
const row_td_close = "</td></tr>";
const table_details_close = "</tbody></table></details>";
const pill_warn = "pill-warn";

const Allocator = std.mem.Allocator;

/// The two intentionally separate schematic presentations. `original` keeps
/// every repeated endpoint as a local net label; `functional` may close
/// recognised feedback loops with direct outside rails.
pub const SchematicView = enum { original, functional };

/// Route prefix and presentation selected for one rendered schematic page.
/// `embed` trims the page chrome (navbar, header, sidebar) for the iframe
/// panes that host a schematic beside another surface.
pub const SchematicOptions = struct {
    path: []const u8,
    view: SchematicView = .functional,
    embed: bool = false,
    board_role: env_mod.BoardRole = .subcircuit,
};

const PageRender = struct {
    svg: *RenderCtx,
    view: SchematicView,
    /// The design's URL name, for the `?sub=` PCB-layout link a path- or
    /// inline-sourced sub circuit falls back to. Carried here rather than
    /// passed down because `writeSection` recurses and only the leaf needs it.
    ///
    /// Defaults to empty for the static hub-SVG exporters
    /// (`renderHubSvgForView`), which render one hub in isolation and so never
    /// reach a sub circuit card — the only reader of this field.
    design_name: []const u8 = "",
};

/// Parse the `?view=` selector. Functional leads — it is what a reader wants
/// from a schematic — so an absent or unrecognised value lands there and only
/// the two names the slider links spell out (`sequential`, and the enum's own
/// `original`) select the label-connected presentation. `render_schematic_png`
/// parses the same pair of names for the image export.
pub fn parseSchematicView(value: ?[]const u8) SchematicView {
    const raw = value orelse return .functional;
    if (std.ascii.eqlIgnoreCase(raw, "sequential")) return .original;
    if (std.ascii.eqlIgnoreCase(raw, "original")) return .original;
    return .functional;
}

/// The `?view=` spelling that reproduces `view`, or null when `view` is the
/// default a bare URL already renders. Every link this module writes appends
/// the selector through here, so the address bar carries a query only when it
/// is actually selecting something.
fn viewQuery(view: SchematicView) ?[]const u8 {
    return switch (view) {
        .functional => null,
        .original => "?view=sequential",
    };
}

/// Error set for HTML emit helpers. The writers in this module are
/// `ArrayListUnmanaged(u8).writer()` (only fails on OOM), but we also
/// embed the schematic BOM table via `bom_html.writeSchematicBomHtml`
/// which is declared with the wider `bom_html.BomError` (Writer.Error +
/// Dir.Iterator.Error) so the public surface widens to match.
pub const RenderError = bom_html.BomError;

// ── Repeated string literals ──────────────────────────────────────
const hubsArrayPrefix: []const u8 = ",\"hubs\":[";
const sectionClose: []const u8 = "</section>";
const secDescOpen: []const u8 = "<p class=\"sec-desc\">";

/// Render a design as a self-contained HTML schematic page. Mirrors the
/// review page's style: inline CSS, navbar, status banner, then a stack of
/// section cards. Each hub inside a section is partitioned into a direct-pin
/// table and a spoke-pin SVG inset.
pub fn renderToHtml(
    allocator: Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    design_name: []const u8,
    navbar_css: []const u8,
    status: review.Status,
    review_doc: ?review.ReviewDoc,
    check_results: *const CheckResultMap,
    // Route prefix and presentation mode for this schematic page.
    options: SchematicOptions,
) RenderError![]const u8 {
    var ctx = try setupRenderCtx(allocator, block);
    ctx.project_dir = project_dir;
    const page_render: PageRender = .{ .svg = &ctx, .view = options.view, .design_name = design_name };

    var asserted_fns = try asserted_fns_mod.buildMap(allocator, block);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    const w = &aw.writer;

    try w.writeAll("<!DOCTYPE html><html><head><meta charset=\"utf-8\">");
    try w.writeAll("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1,viewport-fit=cover\">");
    try w.writeAll("<title>");
    try writeHtmlEscaped(w, block.name);
    try w.writeAll(" — Schematic</title>");
    try w.writeAll("<link rel=\"stylesheet\" href=\"/static/codemirror.css\">");
    try w.writeAll("<link rel=\"stylesheet\" href=\"/static/schematic.css\">");
    try w.writeAll("<style>");
    try w.writeAll(navbar_css);
    if (review_doc != null) try w.writeAll(review_html.body_css);
    // `sch-embed` is the one hook the stylesheet needs to strip this page down
    // to its drawing for an iframe pane (the assembly workspace hosts it under
    // the board). Emitted server-side rather than set by script on load so the
    // pane never flashes the full-page chrome before hiding it.
    try w.print(
        "</style></head><body data-schematic-view=\"{s}\"{s}>",
        .{ @tagName(options.view), if (options.embed) " class=\"sch-embed\"" else "" },
    );

    try pages_tmpl.Navbar.render(.{""}, w);
    try w.writeAll("<div class=\"sch-layout\">");
    try w.writeAll("<div class=\"sch-wrap\">");
    var header_options = options;
    header_options.board_role = block.board.role;
    try writeHeader(w, block.name, design_name, status, header_options, block.revision, block.kicad_pcb_path != null);

    // Pair top-level `(sub-block …)` declarations with the section that wires
    // them (e.g. `(section "XSPI2 NOR Flash" …)` adopts `(sub-block "flash" …)`)
    // so the section's pin-table and the sub-block's internal hubs render as
    // one card instead of two unrelated cards on the page. Computed up front
    // so the system-overview SVG can suppress chips for adopted sub-blocks
    // (otherwise the overview would show e.g. both "USB" and "usb" chips, and
    // the "usb" chip's `#sec-usb` link would dangle since the attached card
    // sits under the section's `#sec-USB` anchor instead).
    const sub_attachments = try membership.computeSubBlockAttachments(allocator, block);
    defer allocator.free(sub_attachments);

    // Top-of-page overview: block diagram, then the power/test-point tables.
    // These are read-only dashboards, so they sit above the per-section
    // schematics where the user does the detailed work. The summary table and
    // sub-block-requirements list were dropped from this page — the audit
    // counts live on the ERC button + sidebar instead.
    try w.writeAll("<div id=\"page-block-diagram\" class=\"page-anchor\">");
    try block_diagram.renderBlockDiagramTabs(allocator, block, sub_attachments, project_dir, w);
    try w.writeAll("</div>");
    if (review_doc) |doc| {
        try w.writeAll("<div class=\"review-embed review-wrap\">");
        if (doc.power.sequence.len > 0) {
            try w.writeAll("<div id=\"page-power-sequence\" class=\"page-anchor\">");
            try review_html.writePowerSequence(w, doc.power.sequence);
            try w.writeAll("</div>");
        }
        if (doc.test_points.len > 0) {
            try w.writeAll("<div id=\"page-test-points\" class=\"page-anchor\">");
            try review_html.writeTestPoints(w, doc.test_points);
            try w.writeAll("</div>");
        }
        if (doc.power.budget.len > 0) {
            try w.writeAll("<div id=\"page-power-budget\" class=\"page-anchor\">");
            try review_html.writePowerBudget(w, doc.power.budget);
            try w.writeAll("</div>");
        }
        try w.writeAll("</div>");
    }

    // Editable BOM table — sits between the review dashboards and the
    // per-section schematic cards. Collapsed by default to keep the page
    // scannable; the <summary> carries a unique/total part count so the
    // headline number is visible without expanding.
    const bom_counts = try bom_html.countBom(allocator, block);
    try w.print(
        "<details id=\"page-bom\" class=\"sch-bom-card page-anchor\"><summary>Bill of Materials " ++
            "<span class=\"sch-card-sub muted\">{d} unique · {d} total parts</span></summary>",
        .{ bom_counts.unique, bom_counts.total },
    );
    try bom_html.writeSchematicBomHtml(allocator, w, block);
    try w.writeAll("</details>");

    // Design notes — structured TODO list backed by `<design>.notes.md`.
    // The task list + add form drive /api/notes/:name/tasks/*; the
    // scratchpad textarea round-trips through the raw /api/notes/:name
    // endpoint and holds anything that isn't a checkbox-format task.
    // Same file backs the CLI `add_design_note`/`complete_design_note`
    // tools so agents and humans share state.
    try w.writeAll(
        \\<details id="page-notes" class="sch-notes-card page-anchor">
        \\<summary>Design Notes <span class="sch-card-sub muted" id="sch-notes-count"></span></summary>
        \\<div class="sch-notes-body">
        \\<p class="sch-notes-hint muted">Log ERC errors and follow-ups for the next revision. Saved to
        \\<code>&lt;design&gt;.notes.md</code>; same store as the CLI <code>add_design_note</code> tool.</p>
        \\<div class="sch-notes-tasks" id="sch-notes-tasks"></div>
        \\<form class="sch-notes-add" id="sch-notes-add">
        \\<input type="text" id="sch-notes-add-text" class="sch-notes-add-text"
        \\placeholder="New TODO for the next revision…" autocomplete="off">
        \\<button type="submit" class="sch-notes-add-btn">Add</button>
        \\</form>
        \\<details class="sch-notes-scratch-wrap"><summary>Scratchpad</summary>
        \\<textarea id="sch-notes-text" class="sch-notes-text" rows="6"
        \\spellcheck="false" placeholder="Free-form notes (anything that isn't a structured TODO line)…"></textarea>
        \\</details>
        \\<div class="sch-notes-status muted" id="sch-notes-status" aria-live="polite"></div>
        \\<div class="sch-notes-error-details" id="sch-notes-error-details" hidden>
        \\<div class="sch-notes-error-head"><strong>Failure details</strong>
        \\<button type="button" class="sch-notes-error-copy" id="sch-notes-error-copy">Copy details</button></div>
        \\<pre id="sch-notes-error-text"></pre>
        \\</div>
        \\</div>
        \\</details>
    );

    for (block.sections, 0..) |sec, sec_idx| {
        // Shared with the PDF composer, which draws these same modules on the
        // section's own sheet — one authority so the two surfaces can never
        // disagree about which section owns a module.
        const attached = try membership.attachedSubBlocks(allocator, block, sub_attachments, sec_idx);
        defer allocator.free(attached);
        try writeSection(page_render, w, allocator, block, sec, 0, check_results, attached);
    }

    // Designs without sections (typical of sub-block-only or flat hub+passives
    // designs like power-6v, pma3-14ln) still deserve a rendering. Emit a
    // synthetic card per sub-block that didn't attach to a section, plus one
    // flat card if any hubs live at the top level outside any section.
    // Identical repeats of one module (a folded channel instantiated chN
    // times) collapse into a single exemplar card labeled with every
    // instance name — a channelized board renders its channel once.
    const sb_grouped = try allocator.alloc(bool, block.sub_blocks.len);
    @memset(sb_grouped, false);
    for (block.sub_blocks, 0..) |sb, sb_idx| {
        if (sub_attachments[sb_idx] != null or sb_grouped[sb_idx]) continue;
        var group_names: std.ArrayList(u8) = .empty;
        var copies: usize = 1;
        if (sb.source.len > 0) {
            for (block.sub_blocks[sb_idx + 1 ..], sb_idx + 1..) |other, oi| {
                if (sub_attachments[oi] != null or sb_grouped[oi]) continue;
                if (!sameSubBlockShape(sb, other)) continue;
                sb_grouped[oi] = true;
                copies += 1;
                try group_names.appendSlice(allocator, ", ");
                try group_names.appendSlice(allocator, other.name);
            }
        }
        const group: ?SubBlockGroup = if (copies > 1)
            .{ .extra_names = group_names.items, .copies = copies }
        else
            null;
        try writeSubBlockCard(page_render, w, allocator, sb, check_results, .standalone, group);
    }

    if (block.sections.len == 0 and hasTopLevelHubs(block)) {
        try writeFlatHubs(page_render, w, allocator, block, check_results);
    }

    // ERC violations and assertions no longer render at the bottom of the
    // page — they surface in the sidebar via the ERC button (which now also
    // lists the design's assertions). Keeps the page tail clean.

    try w.writeAll("</div>");
    try writeSidebar(w, review_doc);
    try w.writeAll("</div>");
    try writeScripts(w, allocator, design_name, block, &ctx, &asserted_fns, check_results, review_doc, options.path);
    if (review_doc != null) {
        // review_notes.js (design-note handlers) reuses DESIGN_NAME —
        // already declared as a global by writeScripts above.
        try w.writeAll("<script src=\"/static/review_notes.js\"></script>");
    }
    try w.writeAll("</body></html>");

    return aw.written();
}

/// Render the declared board revision as a pill beside the `.sexp` subtitle —
/// "Rev <id>" plus the date when present. When the design's `(revision …)`
/// form carries a `(change …)` changelog the pill becomes a button that opens
/// an in-file changelog popover (toggled by `schematic_viewer.js`), so a
/// recipient can see at a glance which spin they hold *and* read what changed
/// in it. With no changelog the pill is a plain, non-interactive label.
/// Renders nothing when the design declares no `(revision …)`.
fn writeRevisionPill(w: *std.Io.Writer, revision: env_mod.Revision) !void {
    if (!revision.present) return;
    if (revision.changes.len == 0) {
        try w.writeAll(" <span class=\"rev-pill\">Rev ");
        try writeRevisionLabel(w, revision);
        try w.writeAll("</span>");
        return;
    }
    // Clickable pill → in-file changelog popover. The "▾" is the open
    // affordance; the panel ships hidden and is toggled client-side.
    try w.writeAll(" <span class=\"rev-pill-wrap\">");
    try w.writeAll("<button type=\"button\" class=\"rev-pill rev-pill-btn\" id=\"rev-pill\" " ++
        "aria-expanded=\"false\" aria-controls=\"rev-changelog\" title=\"View changelog\">Rev ");
    try writeRevisionLabel(w, revision);
    try w.writeAll(" \u{25BE}</button>");
    try w.writeAll("<div class=\"rev-changelog\" id=\"rev-changelog\" role=\"dialog\" " ++
        "aria-label=\"Revision changelog\" hidden>");
    try w.writeAll("<div class=\"rev-cl-head\">Changelog \u{2014} Rev ");
    try writeRevisionLabel(w, revision);
    try w.writeAll("</div><ul class=\"rev-cl-list\">");
    for (revision.changes) |c| {
        try w.writeAll("<li><span class=\"rev-cl-id\">");
        try writeHtmlEscaped(w, c.id);
        try w.writeAll("</span><span class=\"rev-cl-text\">");
        try writeHtmlEscaped(w, c.summary);
        try w.writeAll("</span></li>");
    }
    try w.writeAll("</ul></div></span>");
}

/// Write the bare "<id>" / "<id> · <date>" label shared by the rev pill and
/// its changelog popover header.
fn writeRevisionLabel(w: *std.Io.Writer, revision: env_mod.Revision) !void {
    try writeHtmlEscaped(w, revision.id);
    if (revision.date.len > 0) {
        try w.writeAll(" · ");
        try writeHtmlEscaped(w, revision.date);
    }
}

fn writeSchematicModeSwitch(w: anytype, design_name: []const u8, options: SchematicOptions) !void {
    const functional = options.view == .functional;
    try w.print(
        "<nav class=\"schematic-mode-switch\" aria-label=\"Schematic view\">" ++
            "<span class=\"schematic-mode-label{s}\">Sequential</span>",
        .{if (!functional) " active" else ""},
    );
    try w.print("<a class=\"schematic-mode-slider{s}\" href=\"", .{if (functional) " functional" else ""});
    try w.writeAll(options.path);
    try writeUrlEncoded(w, design_name);
    // The slider links the OTHER view, so it carries the selector exactly when
    // the view it links is not the default.
    if (viewQuery(if (functional) .original else .functional)) |q| try w.writeAll(q);
    try w.print(
        "\" role=\"switch\" aria-checked=\"{s}\" aria-label=\"Switch to {s} view\" " ++
            "title=\"Switch to {s} view\"><span class=\"schematic-mode-thumb\"></span></a>" ++
            "<span class=\"schematic-mode-label{s}\">Functional</span></nav>",
        .{
            if (functional) "true" else "false",
            if (functional) "Sequential" else "Functional",
            if (functional) "Sequential" else "Functional",
            if (functional) " active" else "",
        },
    );
}

fn writeHeader(
    w: anytype,
    title: []const u8,
    design_name: []const u8,
    status: review.Status,
    options: SchematicOptions,
    revision: env_mod.Revision,
    has_kicad_pcb: bool,
) !void {
    // `options.path` is "/modules/" for a reusable module, "/schematics/" for
    // a full design. Both get Schematic ⇄ PCB Layout; physical board designs
    // additionally link to the view-only Assembly surface.
    const banner_class: []const u8 = switch (status) {
        .pass => "banner banner-pass",
        .warn => "banner banner-warn",
        .fail => "banner banner-fail",
    };
    const banner_label: []const u8 = switch (status) {
        .pass => "PASS",
        .warn => "WARNINGS",
        .fail => "NEEDS ATTENTION",
    };

    try w.writeAll("<header class=\"sch-head\"><div class=\"head-title\"><h1>");
    try writeHtmlEscaped(w, title);
    try w.writeAll("</h1><div class=\"subtitle\"><code>");
    try writeHtmlEscaped(w, design_name);
    try w.writeAll(".sexp</code>");
    try writeRevisionPill(w, revision);
    try w.writeAll("</div></div>");
    try w.print("<div class=\"{s}\">{s}</div>", .{ banner_class, banner_label });
    try w.writeAll("<div class=\"head-links\">");
    // Schematic ⇄ PCB Layout switcher — active tab uses `options.path`.
    try w.writeAll("<nav class=\"viewtoggle\" aria-label=\"View\"><a class=\"active\" href=\"");
    try w.writeAll(options.path);
    try writeUrlEncoded(w, design_name);
    if (viewQuery(options.view)) |q| try w.writeAll(q);
    try w.writeAll("\">Schematic</a><a href=\"/pcb-layout/");
    try writeUrlEncoded(w, design_name);
    try w.writeAll("\">PCB Layout</a><a href=\"/pcb-layout/");
    try writeUrlEncoded(w, design_name);
    try w.writeAll("?view=3d\">3D</a>");
    if (std.mem.eql(u8, options.path, "/schematics/")) {
        try w.writeAll("<a href=\"/assembly-debug/");
        try writeUrlEncoded(w, design_name);
        try w.writeAll("\">Assembly</a>");
    }
    // Thermal reads the same block as everything left of it and works on a
    // module as well as a design, so it is the one tab with no board of its own
    // to gate on. It is a link, never an embed: the cooling-scenario ladder
    // needs the saved layouts, and this page is deliberately .sexp-only.
    try w.writeAll("<a href=\"/thermal/");
    try writeUrlEncoded(w, design_name);
    try w.writeAll("\">Thermal</a>");
    try w.writeAll("</nav>");
    try writeSchematicModeSwitch(w, design_name, options);
    // A design's fabrication role is explicit source metadata, not inferred
    // from its outline or folder. Keep the selector off reusable module pages:
    // those are definitions embedded by a design, not project design roots.
    if (std.mem.eql(u8, options.path, "/schematics/")) {
        try w.writeAll(
            "<label class=\"board-role-control\" for=\"board-role-select\">" ++
                "<span>Design type</span><select id=\"board-role-select\" " ++
                "aria-label=\"Design type\" title=\"Choose whether this design is a reusable subcircuit or a whole PCB\">",
        );
        try w.print("<option value=\"subcircuit\"{s}>Subcircuit</option>", .{
            if (options.board_role == .subcircuit) " selected" else "",
        });
        try w.print("<option value=\"board\"{s}>Whole PCB</option>", .{
            if (options.board_role == .board) " selected" else "",
        });
        try w.writeAll("</select></label>");
    }
    // Deliberately minimal toolbar: Reload, Edit SRC, ERC, the BOM +
    // design-review + PDF exports, and a single PCB-sync control. Everything
    // else (History, Netlist export, datasheet upload) was moved off this bar
    // to keep it uncluttered.
    try w.writeAll(
        "<button class=\"head-link head-btn\" id=\"reload-btn\" type=\"button\" " ++
            "title=\"Re-read the .sexp source from disk and rebuild\">\u{21BB} Reload</button>",
    );
    // Edit the raw .sexp source in-browser: loads GET /api/source into a modal
    // editor and saves via POST /api/source (validates syntax, rebuilds, bumps
    // the live version).
    try w.writeAll(
        "<button class=\"head-link head-btn\" id=\"edit-src-btn\" type=\"button\" " ++
            "title=\"Edit the raw .sexp source\">\u{270E} Edit SRC</button>",
    );
    try w.writeAll("<button class=\"head-link head-btn\" id=\"erc-btn\" type=\"button\">ERC</button>");
    // BOM export: downloads `<name>-bom.csv` (the parts list — same columns as
    // the BOM table on this page, with any manual MPN/manufacturer/datasheet
    // edits merged in from the `.bom` sidecar). Plain <a download> — the
    // endpoint streams the CSV on demand, no JS needed.
    try w.writeAll("<a class=\"head-link head-btn\" id=\"bom-export-btn\" href=\"/api/export-bom/");
    try writeUrlEncoded(w, design_name);
    try w.writeAll(
        "\" download title=\"Download the bill of materials as <name>-bom.csv\">\u{2B07} BOM .csv</a>",
    );
    // Design-review export: downloads a .zip of `<name>-review.md` (the full
    // markdown report) + `<name>-bom.csv` + the verbatim `.sexp` source for the
    // design and every sub-module/component it imports. Plain <a download> —
    // the endpoint builds the zip on demand, no JS needed.
    try w.writeAll("<a class=\"head-link head-btn\" id=\"review-export-btn\" href=\"/api/export-review/");
    try writeUrlEncoded(w, design_name);
    try w.writeAll(
        "\" download title=\"Download the design-review package (review.md + BOM + all source .sexp) as a .zip\">\u{2B07} Review .zip</a>",
    );
    // Review PDF: the same report as a printable/emailable document (cover,
    // per-section schematic pages, validation appendix, power tables). Composed
    // on demand by GET /api/schematic-pdf/:name — a plain <a download>, no JS.
    // Written here rather than in the design branch so module pages get it too.
    try w.writeAll("<a class=\"head-link head-btn\" id=\"pdf-export-btn\" href=\"/api/schematic-pdf/");
    try writeUrlEncoded(w, design_name);
    try w.writeAll(
        "\" download title=\"Download the design-review document as <name>.pdf\">\u{2913} PDF</a>",
    );
    // KiCad schematic export: a .zip of the `.kicad_sch` hierarchy plus the
    // project sidecars (sym-lib-table / fp-lib-table / <name>.kicad_pro /
    // netlisp.kicad_sym) that make its library references resolve. Composed on
    // demand by GET /api/kicad-sch/:name — a plain <a download>, no JS, and on
    // module pages too for the same reason the PDF button is here.
    try w.writeAll("<a class=\"head-link head-btn\" id=\"kicad-sch-btn\" href=\"/api/kicad-sch/");
    try writeUrlEncoded(w, design_name);
    try w.writeAll(
        "\" download title=\"Download the KiCad schematic (.kicad_sch sheets + project files) as <name>-kicad-sch.zip\">" ++
            "\u{2913} KiCad</a>",
    );
    // Single file-based PCB-sync control — only for designs that declare a
    // (kicad-pcb "<path>") target. schematic_viewer.js dry-runs the sync on
    // page load and reflects the result in ONE button:
    //   • in sync  → a compact "✓ PCB" icon (click re-checks);
    //   • out of sync → "↑ Push to PCB (N)" with the pending-change count
    //     (click opens the dry-run preview modal and writes the .kicad_pcb on
    //     confirm);
    //   • unreadable board → "⚠ PCB unreachable".
    if (has_kicad_pcb) {
        try w.writeAll(
            "<button class=\"head-link head-btn sync-chip\" id=\"kicad-sync-chip\" type=\"button\" " ++
                "title=\"Checking whether the .kicad_pcb matches the design\u{2026}\">\u{27F3} PCB sync\u{2026}</button>",
        );
        // Schematic push into the SAME KiCad project directory the board sync
        // writes to. schematic_viewer.js dry-runs it, shows the per-file plan
        // for confirmation, and only then writes — the same preview-then-write
        // shape as the board button, and gated on the same (kicad-pcb …) form,
        // since without one there is no project directory to push into.
        try w.writeAll(
            "<button class=\"head-link head-btn\" id=\"kicad-sch-push-btn\" type=\"button\" " ++
                "title=\"Write the KiCad schematic into the project directory beside the .kicad_pcb " ++
                "(refuses to overwrite a hand-drawn sheet or a project KiCad has open)\">" ++
                "\u{2191} Push SCH</button>",
        );
    }
    try w.writeAll("</div></header>");
}

/// Roll-up requirement status for a section (or sub-block) — surfaced as a
/// status badge in the sidebar TOC so reviewers can see at a glance which
/// sections are clean, which still need an answer, and which have a real
/// failing check.
const SecStatus = enum {
    /// All requirements pass or have a `(verifies …)` sign-off.
    ok,
    /// Has unanswered requirements (`na`) or a fail with an override
    /// note attached (manual review still recommended).
    warn,
    /// Has at least one fail with no `(verifies …)` override.
    fail,
    /// No instances with requirements in this section at all.
    empty,
};

const SecCounts = struct {
    pass: usize = 0,
    verified: usize = 0,
    na: usize = 0,
    fail_overridden: usize = 0,
    fail_real: usize = 0,
    has_reqs: bool = false,

    fn status(self: SecCounts) SecStatus {
        if (!self.has_reqs) return .empty;
        if (self.fail_real > 0) return .fail;
        if (self.na > 0 or self.fail_overridden > 0) return .warn;
        if (self.pass + self.verified > 0) return .ok;
        return .empty;
    }
};

fn tallyRefCounts(
    check_results: *const CheckResultMap,
    ref_des: []const u8,
    out: *SecCounts,
) void {
    const results = check_results.get(ref_des) orelse return;
    if (results.len > 0) out.has_reqs = true;
    for (results) |r| switch (r.status) {
        .pass => out.pass += 1,
        .verified => out.verified += 1,
        .fail => {
            if (r.verification != null) out.fail_overridden += 1 else out.fail_real += 1;
        },
        .na => out.na += 1,
    };
}

/// Collect every ref_des that belongs to a section (its own instances +
/// pin-grouped top-level instances + every nested sub-section's refs).
/// Sub-block refs are walked separately by `tocEntryForSubBlock`.
fn collectSectionRefsRec(
    sec: Section,
    out: *std.ArrayList([]const u8),
    allocator: Allocator,
) std.mem.Allocator.Error!void {
    for (sec.pin_groups) |pg| try out.append(allocator, pg.ref_des);
    for (sec.instances) |inst| try out.append(allocator, inst.ref_des);
    for (sec.sub_sections) |sub| try collectSectionRefsRec(sub, out, allocator);
}

fn countsForRefs(check_results: *const CheckResultMap, refs: []const []const u8) SecCounts {
    var counts: SecCounts = .{};
    for (refs) |r| tallyRefCounts(check_results, r, &counts);
    return counts;
}

/// Sidebar: a compact "table of contents" chip bar above the search box
/// (jump to block diagram / summary / power tables / BOM), the search input,
/// and the detail pane (which the schematic-viewer JS uses for the section
/// list, audit summary, and per-section/component detail views).
///
/// Optional dashboards (power sequencing, test points, power budget) only
/// get a chip when their backing data is non-empty — the renderer skips
/// the matching `<section>` block in those cases too, so a chip linking to
/// a missing section would scroll to nowhere.
fn writeSidebar(w: anytype, review_doc: ?review.ReviewDoc) !void {
    try w.writeAll("<aside class=\"sch-sidebar\" id=\"sch-sidebar\">");
    try w.writeAll("<nav class=\"sb-toc\" aria-label=\"Page contents\">");
    try writeTocChip(w, "page-block-diagram", "Block diagram");
    if (review_doc) |doc| {
        if (doc.power.sequence.len > 0) try writeTocChip(w, "page-power-sequence", "Power sequencing");
        if (doc.test_points.len > 0) try writeTocChip(w, "page-test-points", "Test points");
        if (doc.power.budget.len > 0) try writeTocChip(w, "page-power-budget", "Power budget");
    }
    try writeTocChip(w, "page-bom", "BOM");
    try writeTocChip(w, "page-notes", "Notes");
    try w.writeAll("</nav>");
    try w.writeAll(
        \\<div class="sb-search">
        \\<input type="search" id="sch-search" placeholder="Search net, ref, pin, MPN…" autocomplete="off" spellcheck="false">
        \\<div id="sb-results" class="sb-results"></div>
        \\</div>
        \\<div id="sb-detail" class="sb-detail"></div>
        \\</aside>
    );
}

fn writeTocChip(w: anytype, anchor_id: []const u8, label: []const u8) !void {
    try w.print("<a class=\"sb-toc-btn\" href=\"#{s}\">", .{anchor_id});
    try writeHtmlEscaped(w, label);
    try w.writeAll("</a>");
}

/// Build a map of (ref_des|pin_id) -> asserted alt-function names (e.g. "SPI4_SCK",
/// or "TIM1_CH1, GPIO" when the pin declared multiple roles) from all
/// `(pin X (as "FN" ...) ...)` declarations in the design tree.
/// Build a fully-populated `RenderCtx` for `block`. Same setup the schematic
/// page does — flatten instances, build pin/net maps, classify, build
/// adjacency, etc. — exposed so static exporters (markdown review package)
/// can render the same per-hub SVGs the live page emits.
pub fn setupRenderCtx(allocator: Allocator, block: *const DesignBlock) std.mem.Allocator.Error!RenderCtx {
    var ctx = RenderCtx.init(allocator);
    try ctx.setup(block);
    try attachSvgLocalIslandBranches(&ctx);
    return ctx;
}

fn isSupplyLikeSchematicNet(net: []const u8) bool {
    if (draw.isGroundNet(net)) return true;
    for (rails_mod.schematic_supply_prefixes) |prefix| {
        if (std.ascii.startsWithIgnoreCase(net, prefix)) return true;
    }
    return false;
}

fn appendSvgAdjacency(ctx: *RenderCtx, ref_des: []const u8, entry: AdjEntry) !void {
    const gop = try ctx.adjacency.getOrPut(ctx.allocator, ref_des);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(ctx.allocator, entry);
}

/// SVG-only supplemental ownership for a resistor on the non-owner boundary of
/// a shared passive island. The JSON scene graph retains one canonical island
/// owner; the schematic gets the extra local branch readers need at the pin.
fn attachSvgLocalIslandBranches(ctx: *RenderCtx) !void {
    for (ctx.nets.items) |net| {
        const net_name = draw.baseNetName(net.name);
        if (isSupplyLikeSchematicNet(net_name)) continue;

        var hub_pin: ?env_mod.PinRef = null;
        var hub_count: usize = 0;
        for (net.pins) |pin| {
            if (ctx.spoke_set.contains(pin.ref_des)) continue;
            hub_count += 1;
            hub_pin = pin;
        }
        if (hub_count != 1) continue;

        for (net.pins) |spoke_pin| {
            if (!ctx.spoke_set.contains(spoke_pin.ref_des)) continue;
            const owner = ctx.spoke_anchor_net.get(spoke_pin.ref_des) orelse continue;
            if (std.mem.eql(u8, draw.baseNetName(owner), net_name)) continue;
            const inst = ctx.inst_map.get(spoke_pin.ref_des) orelse continue;
            const local_ref = draw.shortRef(spoke_pin.ref_des);
            const resistor = std.mem.eql(u8, inst.symbol, "generic-res") or (local_ref.len > 0 and local_ref[0] == 'R');
            if (!resistor) continue;

            const hub = hub_pin.?;
            const spoke_section = ctx.section_map.get(spoke_pin.ref_des);
            const hub_section = ctx.section_map.get(hub.ref_des);
            if (spoke_section != null and hub_section != null and spoke_section.? != hub_section.?) continue;
            try appendSvgAdjacency(ctx, hub.ref_des, .{
                .pin = hub.pin,
                .endpoint = .{ .pin = .{ .ref_des = spoke_pin.ref_des, .pin = spoke_pin.pin } },
            });
            try appendSvgAdjacency(ctx, spoke_pin.ref_des, .{
                .pin = spoke_pin.pin,
                .endpoint = .{ .pin = .{ .ref_des = hub.ref_des, .pin = hub.pin } },
            });
        }
    }
}

/// Emit one hub's grouped pin-table SVG(s) to `w`. Returns true if the hub
/// produced output (a renderable hub was found in `pin_groups` or in the
/// flat instance map for the given `hub_ref`); false otherwise.
pub fn renderHubSvg(
    ctx: *RenderCtx,
    w: anytype,
    allocator: Allocator,
    pin_groups: []const env_mod.PinGroup,
    hub_ref: []const u8,
) RenderError!bool {
    return renderHubSvgForView(ctx, w, allocator, pin_groups, hub_ref, .functional);
}

/// View-selectable static hub renderer. Native image export uses this entry so
/// its Sequential/Functional switch is the same layout decision as the web
/// page; the legacy `renderHubSvg` wrapper above remains Functional for PDF and
/// markdown callers that predate the two-view UI.
pub fn renderHubSvgForView(
    ctx: *RenderCtx,
    w: anytype,
    allocator: Allocator,
    pin_groups: []const env_mod.PinGroup,
    hub_ref: []const u8,
    view: SchematicView,
) RenderError!bool {
    if (try analyzeHub(ctx, allocator, pin_groups, hub_ref, view)) |a| {
        try renderGroupedHubSvgs(.{ .svg = ctx, .view = view }, w, allocator, a);
        return true;
    }
    return false;
}

/// CSS subset for static SVG exports — strips hover/click states (no JS in
/// a markdown viewer) but keeps the visual identity (component box colors,
/// pin label fonts, net stroke colors). Embed once at the top of an
/// exported document; per-hub SVGs reference these classes.
pub const static_svg_css =
    \\svg.hub-inset{display:block;width:100%;max-width:900px;height:auto;}
    \\svg .component rect{fill:#16213e;stroke:#4a9eff;stroke-width:1.5;}
    \\svg .component text{fill:#e6e6e6;font-family:"SF Mono",monospace;}
    \\svg .pin-stub line{stroke:#6e7681;stroke-width:1;}
    \\svg .pin-stub text{fill:#c9d1d9;font-family:"SF Mono",monospace;font-size:11px;}
    \\svg .net line,svg .net polyline{stroke:#8b949e;stroke-width:1.2;fill:none;}
    \\svg .net text{fill:#79c0ff;font-family:"SF Mono",monospace;font-size:10px;}
    \\svg .passive rect,svg .passive circle,svg .passive line{stroke:#8b949e;fill:none;}
    \\svg .passive text{fill:#c9d1d9;font-family:"SF Mono",monospace;font-size:10px;}
;

fn writeSection(
    page_render: PageRender,
    w: anytype,
    allocator: Allocator,
    block: *const DesignBlock,
    sec: Section,
    depth: u8,
    check_results: *const CheckResultMap,
    /// Indices into `block.sub_blocks` of the modules this section owns, per
    /// `membership.attachedSubBlocks` — the same authority the PDF composer uses
    /// to draw them on the section's sheet.
    attached_subs: []const usize,
) !void {
    const ctx = page_render.svg;
    const indent_class: []const u8 = if (depth == 0) "sch-section" else "sch-section sch-subsection";
    const slug = try review.slugify(allocator, sec.name);
    try w.print("<section class=\"{s}\" id=\"sec-{s}\" data-slug=\"{s}\">", .{ indent_class, slug, slug });

    // Header
    const status_pill: []const u8 = switch (sec.status) {
        .concept => "pill-concept",
        .implemented => "pill-ok",
        .review => pill_warn,
    };
    try w.writeAll("<div class=\"sec-head\"><h2>");
    try writeHtmlEscaped(w, sec.name);
    try w.print("</h2><span class=\"pill {s}\">{s}</span>", .{ status_pill, @tagName(sec.status) });
    const sec_cov = try coverage.computeSectionCoverage(allocator, block, sec, check_results);
    if (sec_cov.checked > 0) {
        const cov_class: []const u8 = if (sec_cov.complete == sec_cov.checked) "pill-pass" else pill_warn;
        try w.print(
            "<span class=\"pill {s}\" title=\"Click 'Coverage' below to see what's checked and what's missing\">{d}/{d} complete</span>",
            .{ cov_class, sec_cov.complete, sec_cov.checked },
        );
    }
    // Per-section "Edit src" — opens the raw `(section …)` form in a modal so
    // the user can rename a net or swap a passive's footprint in place. Only
    // top-level sections map 1:1 to an editable source span; sub-sections and
    // synthetic sub-block cards are skipped.
    if (depth == 0) {
        try w.writeAll("<button type=\"button\" class=\"sec-edit-src\" data-section=\"");
        try writeHtmlEscaped(w, sec.name);
        try w.writeAll("\" title=\"Edit this section's S-expression source\">Edit src</button>");
    }
    try w.writeAll("</div>");

    if (sec.description.len > 0) {
        try w.writeAll(secDescOpen);
        try writeHtmlEscaped(w, sec.description);
        try w.writeAll("</p>");
    }

    try review_html.writeSectionCoverage(w, sec_cov);

    try writeSectionPorts(w, sec);
    try writeSectionBoundaryContracts(w, sec);

    // Collect hubs in this section
    var hub_refs: std.ArrayList([]const u8) = .empty;
    defer hub_refs.deinit(allocator);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    for (sec.pin_groups) |pg| {
        if (seen.contains(pg.ref_des)) continue;
        try seen.put(allocator, pg.ref_des, {});
        try hub_refs.append(allocator, pg.ref_des);
    }
    for (sec.instances) |inst| {
        if (seen.contains(inst.ref_des)) continue;
        // Build FlatInst on the fly for the isHub check (ref_des is the key).
        const fi: FlatInst = .{
            .ref_des = inst.ref_des,
            .component = inst.component,
            .value = inst.value,
            .symbol = inst.symbol,
            .parts = inst.parts,
        };
        if (!isHub(fi)) continue;
        try seen.put(allocator, inst.ref_des, {});
        try hub_refs.append(allocator, inst.ref_des);
    }

    // Notes + requirements ride above the SVGs so the reviewer reads the
    // design rationale + datasheet rules before drilling into pin-level
    // wiring. Both blocks are collapsed by default to keep the section
    // card scannable; each hub's <details> says "Requirements (N)".
    if (sec.notes.len > 0) try writeNotes(w, sec.notes);
    try writeSectionRequirements(ctx, w, allocator, sec.pin_groups, hub_refs.items, check_results);

    try writeSectionHubs(page_render, w, allocator, sec.pin_groups, hub_refs.items, check_results);

    for (sec.sub_sections) |sub| try writeSection(page_render, w, allocator, block, sub, depth + 1, check_results, &.{});

    for (attached_subs) |sb_idx| {
        try writeSubBlockCard(page_render, w, allocator, block.sub_blocks[sb_idx], check_results, .attached, null);
    }

    try w.writeAll(sectionClose);
}

/// Per-section requirements panel: walks every hub in the section and
/// emits its `<details class="hub-reqs">` block. Rendered above the
/// SVGs so the reviewer sees the datasheet-derived rules before they
/// drill into pin-level wiring.
fn writeSectionRequirements(
    ctx: *RenderCtx,
    w: anytype,
    allocator: Allocator,
    pin_groups: []const env_mod.PinGroup,
    hub_refs: []const []const u8,
    check_results: *const CheckResultMap,
) !void {
    for (hub_refs) |hub_ref| {
        if (try analyzeHub(ctx, allocator, pin_groups, hub_ref, .original)) |a| {
            if (a.inst.requirements.len > 0) {
                try w.writeAll("<div class=\"sec-hub-reqs\" data-ref=\"");
                try writeHtmlEscaped(w, a.inst.ref_des);
                try w.writeAll("\"><h4 class=\"sec-hub-reqs-head\"><code>");
                try writeHtmlEscaped(w, a.inst.ref_des);
                try w.writeAll("</code> · ");
                try writeHtmlEscaped(w, a.inst.component);
                try w.writeAll("</h4>");
                try writeHubRequirements(w, a, check_results);
                try w.writeAll("</div>");
            }
        }
    }
}

const HubAnalysis = struct {
    ref: []const u8,
    inst: FlatInst,
    /// Every pin-group on this hub, tagged with its `(group "label")` feature
    /// label (empty when no label was declared). Rendered as one SVG per
    /// distinct label so the visual structure mirrors the source.
    groups: []const PinGroup,
};

/// Render every hub in a section as its own card. Each card shows the hub's
/// header (ref + component + value) followed by one SVG per `(group "label")`
/// feature block. The SVGs draw every pin connection — passive chains for
/// dedicated spokes and labeled net stubs for everything else — so the page
/// no longer needs a master pin-table to surface hub-to-net relationships.
/// Search and inspection of nets/components/pins live in the sidebar.
fn writeSectionHubs(
    page_render: PageRender,
    w: anytype,
    allocator: Allocator,
    pin_groups: []const env_mod.PinGroup,
    hub_refs: []const []const u8,
    check_results: *const CheckResultMap,
) !void {
    const ctx = page_render.svg;
    for (hub_refs) |hub_ref| {
        if (try analyzeHub(ctx, allocator, pin_groups, hub_ref, page_render.view)) |a| {
            try writeHubCard(page_render, w, allocator, a, check_results);
        }
    }
}

fn writeHubCard(
    page_render: PageRender,
    w: anytype,
    allocator: Allocator,
    h: HubAnalysis,
    check_results: *const CheckResultMap,
) !void {
    try w.writeAll("<div class=\"sch-hub\" data-ref=\"");
    try writeHtmlEscaped(w, h.inst.ref_des);
    try w.writeAll("\">");
    // The standalone SVG already carries the hub ref-des in its title. Keep
    // the surrounding card's component metadata, but do not print the same
    // ref-des a second time immediately above the drawing.
    try w.writeAll("<div class=\"hub-head\"><span class=\"hub-comp\">");
    try writeHtmlEscaped(w, h.inst.component);
    try w.writeAll("</span>");
    if (h.inst.value.len > 0) {
        try w.writeAll("<span class=\"hub-val\">");
        try writeHtmlEscaped(w, h.inst.value);
        try w.writeAll("</span>");
    }
    try w.writeAll("</div>");
    try w.writeAll("<div class=\"hub-inset-wrap\">");
    try renderGroupedHubSvgs(page_render, w, allocator, h);
    try w.writeAll("</div>");
    // Requirements now render once per section (above the SVGs) via
    // writeSectionRequirements — don't duplicate them inside each hub card.
    _ = check_results;
    try w.writeAll("</div>");
}

/// Emit a `<details>` dropdown listing every `(requirement ...)` declared on
/// the hub's component. Each row carries a ✓/✗/⋯ badge depending on whether
/// the requirement's attached `(check ...)` clause passed, failed, or is
/// absent (reviewer-judged).
/// Sort priority: worst-first so the reviewer sees what needs attention
/// before the noise. Real fails are most urgent, then signed-off fails (the
/// check still says no), then unanswered, then verified, then pass.
fn statusSortKey(status: req_checks.Status, has_verification: bool) u8 {
    return switch (status) {
        .fail => if (has_verification) @as(u8, 1) else @as(u8, 0),
        .na => 2,
        .verified => 3,
        .pass => 4,
    };
}

fn writeRequirementsDetails(w: anytype, requirements: []const env_mod.Requirement, results: []const req_checks.Result) !void {
    if (requirements.len == 0) return;

    var pass_ct: usize = 0;
    var fail_ct: usize = 0;
    var verified_ct: usize = 0;
    for (results) |r| switch (r.status) {
        .pass => pass_ct += 1,
        .fail => fail_ct += 1,
        .verified => verified_ct += 1,
        .na => {},
    };
    const header_class: []const u8 = if (fail_ct > 0) "hub-reqs has-fail" else if (pass_ct > 0) "hub-reqs" else "hub-reqs";
    // Requirements stay collapsed by default — even when failing — so the
    // section cards read clean. The summary keeps the fail/ok/verified badges,
    // so status is visible at a glance and the reviewer expands on demand.
    try w.print("<details class=\"{s}\"", .{header_class});
    try w.print("><summary>Requirements ({d})", .{requirements.len});
    if (fail_ct > 0) try w.print(" <span class=\"req-badge fail\">{d} failing</span>", .{fail_ct});
    if (pass_ct > 0) try w.print(" <span class=\"req-badge pass\">{d} ok</span>", .{pass_ct});
    if (verified_ct > 0) try w.print(" <span class=\"req-badge verified\">{d} verified</span>", .{verified_ct});
    try w.writeAll("</summary><ul>");

    // Build a sorted index into requirements so the rendered list
    // reads worst → best regardless of the order entries appear in
    // `lib/components/<part>.sexp`.
    const SortItem = struct { idx: usize, key: u8 };
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sorted = a.alloc(SortItem, requirements.len) catch return;
    for (requirements, 0..) |_, i| {
        const status: req_checks.Status = if (i < results.len) results[i].status else .na;
        const has_v = (i < results.len) and (results[i].verification != null);
        sorted[i] = .{ .idx = i, .key = statusSortKey(status, has_v) };
    }
    std.mem.sortUnstable(SortItem, sorted, {}, struct {
        fn lt(_: void, x: SortItem, y: SortItem) bool {
            if (x.key != y.key) return x.key < y.key;
            return x.idx < y.idx; // stable within group: preserve source order
        }
    }.lt);

    for (sorted) |it| {
        const i = it.idx;
        const r = requirements[i];
        const status: req_checks.Status = if (i < results.len) results[i].status else .na;
        const msg: []const u8 = if (i < results.len) results[i].message else "";
        const verification: ?env_mod.Verification = if (i < results.len) results[i].verification else null;
        // Labeled pill instead of an icon char — at-a-glance status reads
        // PASS / FAIL / VERIFIED / PENDING in color, plus a secondary
        // "OVERRIDDEN" pill on the fail-with-sign-off case.
        const pill_label: []const u8 = switch (status) {
            .pass => "PASS",
            .fail => "FAIL",
            .na => "PENDING",
            .verified => "VERIFIED",
        };
        const pill_title: []const u8 = switch (status) {
            .pass => "Automated check passed",
            .fail => "Automated check failed",
            .na => "No automated check — reviewer judgment required",
            .verified => "Manually verified by design-side (verifies …)",
        };
        try w.print(
            "<li class=\"req-row status-{s}\"><div class=\"req-head\">" ++
                "<span class=\"req-pill pill-{s}\" title=\"{s}\">{s}</span>",
            .{ @tagName(status), @tagName(status), pill_title, pill_label },
        );
        if (status == .fail and verification != null) {
            try w.writeAll(
                "<span class=\"req-pill pill-overridden\" " ++
                    "title=\"Has a design-side (verifies …) note attached — see rationale below\">" ++
                    "OVERRIDDEN</span>",
            );
        }
        try w.writeAll("<span class=\"req-text\">");
        try writeHtmlEscaped(w, r.text);
        try w.writeAll("</span>");
        if (r.ref) |ref| {
            try w.writeAll("<a class=\"note-ref\" target=\"_blank\" href=\"/pdf-view/");
            try writeHtmlEscaped(w, ref.pdf);
            var has_query = false;
            if (ref.page > 0) {
                try w.print("?page={d}", .{ref.page});
                has_query = true;
            }
            if (ref.quote) |q| {
                try w.writeAll(if (has_query) "&highlight=" else "?highlight=");
                try writeUrlEncoded(w, q);
            }
            try w.writeAll("\">📄 ");
            try writeHtmlEscaped(w, ref.pdf);
            if (ref.page > 0) try w.print(" p.{d}", .{ref.page});
            try w.writeAll("</a>");
        }
        try w.writeAll("</div>");
        if (r.ref) |ref| if (ref.quote) |q| {
            try w.writeAll("<div class=\"req-quote\">“");
            try writeHtmlEscaped(w, q);
            try w.writeAll("”</div>");
        };
        if (msg.len > 0) {
            try w.writeAll("<div class=\"req-msg\">");
            try writeHtmlEscaped(w, msg);
            try w.writeAll("</div>");
        }
        if (verification) |v| {
            const cls: []const u8 = if (status == .fail) "req-verif overridden" else "req-verif";
            try w.print("<div class=\"{s}\"><span class=\"req-verif-tag\">", .{cls});
            try w.writeAll(if (status == .fail) "Sign-off (overrides fail):" else "Verified by design:");
            try w.writeAll("</span> ");
            try writeHtmlEscaped(w, v.rationale);
            if (v.signed_by.len > 0) {
                try w.writeAll(" — <em>");
                try writeHtmlEscaped(w, v.signed_by);
                if (v.date.len > 0) {
                    try w.writeAll(", ");
                    try writeHtmlEscaped(w, v.date);
                }
                try w.writeAll("</em>");
            }
            try w.writeAll("</div>");
        }
        try w.writeAll("</li>");
    }
    try w.writeAll("</ul></details>");
}

/// Per-hub Requirements dropdown — looks up the hub's check results by
/// ref_des and hands them to the shared `writeRequirementsDetails` renderer.
fn writeHubRequirements(w: anytype, h: HubAnalysis, check_results: *const CheckResultMap) !void {
    const results: []const req_checks.Result = check_results.get(h.inst.ref_des) orelse &.{};
    try writeRequirementsDetails(w, h.inst.requirements, results);
}

/// Bucket a hub's pin-groups by `(group "label")` feature label and render
/// one mini-SVG per bucket with the label as a small heading. When there's
/// only one bucket (single label, or none), emit one ungrouped SVG.
fn renderGroupedHubSvgs(
    page_render: PageRender,
    w: anytype,
    allocator: Allocator,
    h: HubAnalysis,
) !void {
    const ctx = page_render.svg;
    var buckets: std.StringArrayHashMapUnmanaged(std.ArrayList(PinGroup)) = .empty;
    defer {
        var it = buckets.iterator();
        while (it.next()) |e| e.value_ptr.deinit(allocator);
        buckets.deinit(allocator);
    }

    for (h.groups) |g| {
        const gop = try buckets.getOrPut(allocator, g.group);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, g);
    }

    if (buckets.count() <= 1) {
        try section_inset.renderHubAllPins(ctx, w, h.inst, h.groups, page_render.view == .functional);
        return;
    }

    var it = buckets.iterator();
    while (it.next()) |entry| {
        const label = entry.key_ptr.*;
        const subset = entry.value_ptr.items;
        try w.writeAll("<div class=\"hub-group-block\">");
        if (label.len > 0) {
            try w.writeAll("<h4 class=\"hub-group-label\">");
            try writeHtmlEscaped(w, label);
            try w.writeAll("</h4>");
        }
        try section_inset.renderHubAllPins(ctx, w, h.inst, subset, page_render.view == .functional);
        try w.writeAll("</div>");
    }
}

/// Build the pin_id -> function-name map for a hub. Part-level names exist only
/// on `(part …)`/`(pins …)` instances; flat `(pin …)` instances (e.g. the
/// LT3045) carry none, so supplement from the component's pinout file
/// (`lib/pinouts/<pinout>.sexp`). Without this, hub blocks label pins by the
/// net they reach instead of the component's own pin name.
fn pinNameMapFor(ctx: *RenderCtx, allocator: Allocator, inst: FlatInst) std.StringHashMapUnmanaged([]const u8) {
    var map = hub_mod.buildPinNameMap(ctx, inst.parts);
    if (ctx.project_dir.len == 0) return map;
    // The pinout key is often dropped when a sub-block is flattened, so try it
    // first then fall back to the symbol/component name — the same chain the
    // evaluator uses to locate `lib/pinouts/<x>.sexp`. The component family
    // name survives flattening, so it's the reliable last resort.
    const candidates = [_][]const u8{ inst.pinout, inst.symbol, inst.component };
    for (candidates) |cand| {
        if (cand.len == 0) continue;
        const path = std.fmt.allocPrint(allocator, "{s}/lib/pinouts/{s}.sexp", .{ ctx.project_dir, cand }) catch continue;
        defer allocator.free(path);
        var pinmap = loadPinoutNames(allocator, path) orelse continue;
        var it = pinmap.iterator();
        while (it.next()) |kv| {
            if (!map.contains(kv.key_ptr.*)) map.put(allocator, kv.key_ptr.*, kv.value_ptr.*) catch return map;
        }
        if (map.count() > 0) break;
    }
    return map;
}

/// Parse `lib/pinouts/<x>.sexp` into a pin_id -> function-name map. Numeric pin
/// ids stringify to "5", "11", … — the spelling the evaluator's `ids.pinId`
/// gives a `PinRef.pin`, and the one `erc.loadPinoutMap` and
/// `kicad_sch/shape.zig`'s `readPinout` now key on too (via `Node.tokenText`).
fn loadPinoutNames(allocator: Allocator, path: []const u8) ?std.StringHashMapUnmanaged([]const u8) {
    const content = infra_fs.cwd().readFileAlloc(allocator, path, lib_limits.max_lib_file_bytes) catch return null;
    const nodes = parser_mod.parse(allocator, content) catch return null;
    if (nodes.len == 0) return null;
    const top = nodes[0].asList() orelse return null;
    if (top.len < 2 or !std.mem.eql(u8, top[0].asAtom() orelse "", "pinout")) return null;
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (top[2..]) |child| {
        const cl = child.asList() orelse continue;
        if (cl.len < 3 or !std.mem.eql(u8, cl[0].asAtom() orelse "", "pin")) continue;
        const id = pinIdStr(allocator, cl[1]) orelse continue;
        const name = cl[2].asString() orelse (cl[2].asAtom() orelse continue);
        map.put(allocator, id, name) catch continue;
    }
    return map;
}

/// Pin identifier as a string: bare number -> "5", atom/string -> itself. A
/// numeric token that is not a representable integer (`1e30`) is no pad at all,
/// so it returns null and the caller skips the row — same as `ids.pinId`. It
/// used to fall back to pad "0", which invented a row and could shadow a real
/// `(pin 0 …)` entry.
fn pinIdStr(allocator: Allocator, node: ast.Node) ?[]const u8 {
    if (node.asNumber()) |n| {
        const i: i64 = numeric.checkedInt(i64, n) orelse return null;
        return std.fmt.allocPrint(allocator, "{d}", .{i}) catch null;
    }
    return node.asAtom() orelse node.asString();
}

fn analyzeHub(
    ctx: *RenderCtx,
    allocator: Allocator,
    pin_groups: []const env_mod.PinGroup,
    hub_ref: []const u8,
    view: SchematicView,
) !?HubAnalysis {
    const hub_inst = ctx.inst_map.get(hub_ref) orelse return null;
    // Test points get a dedicated table at the top of the page; they don't
    // need their own per-section schematic card cluttering the layout.
    if (std.mem.eql(u8, hub_inst.component, "testpoint") or
        std.mem.startsWith(u8, hub_inst.component, "testpoint-")) return null;

    // Bucket pin_ids by `(pins ref (group "X") ...)` feature label so each
    // bucket can render as its own SVG with the label as a heading.
    var buckets: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    defer {
        var it = buckets.iterator();
        while (it.next()) |e| e.value_ptr.deinit(allocator);
        buckets.deinit(allocator);
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    var from_pin_groups = false;
    for (pin_groups) |pg| {
        if (!std.mem.eql(u8, pg.ref_des, hub_ref)) continue;
        from_pin_groups = true;
        for (pg.pins) |pp| {
            if (seen.contains(pp.pin)) continue;
            try seen.put(allocator, pp.pin, {});
            const gop = try buckets.getOrPut(allocator, pp.group);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, pp.pin);
        }
    }
    // No `(pins ref (group …))` declarations, but the instance is a multi-part
    // symbol `(instance ref ic (part "X" (pin …)) …)`: bucket each part's pins
    // under the part name so the hub renders one labelled box per part.
    if (!from_pin_groups and hub_inst.parts.len > 0) {
        for (hub_inst.parts) |part| {
            const gop = try buckets.getOrPut(allocator, part.name);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            for (part.pins) |pp| {
                if (seen.contains(pp.pin)) continue;
                try seen.put(allocator, pp.pin, {});
                try gop.value_ptr.append(allocator, pp.pin);
            }
        }
    }
    // Fall back to the synthesized spoke adjacency only when neither explicit
    // pin-groups nor parts gave this hub any pins.
    if (buckets.count() == 0) {
        if (ctx.adjacency.get(hub_ref)) |adj| {
            const gop = try buckets.getOrPut(allocator, "");
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            for (adj.items) |ae| {
                if (seen.contains(ae.pin)) continue;
                try seen.put(allocator, ae.pin, {});
                try gop.value_ptr.append(allocator, ae.pin);
            }
        }
    }
    if (buckets.count() == 0) return null;

    const adj_entries = if (ctx.adjacency.get(hub_ref)) |list| list.items else &[_]AdjEntry{};
    var pn_map = pinNameMapFor(ctx, allocator, hub_inst);
    defer pn_map.deinit(allocator);

    var all_groups: std.ArrayList(PinGroup) = .empty;
    var total_pins: usize = 0;
    var it = buckets.iterator();
    while (it.next()) |e| {
        const grp = e.key_ptr.*;
        const pins = e.value_ptr.items;
        total_pins += pins.len;
        std.mem.sortUnstable([]const u8, pins, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return pinOrder(a, b);
            }
        }.lt);
        const hub_pg = switch (view) {
            .original => try hub_mod.groupHubPins(ctx, pins, adj_entries, &pn_map),
            .functional => try hub_mod.groupHubPinsFunctional(ctx, pins, adj_entries, &pn_map),
        };
        const ordered = switch (view) {
            .original => hub_pg,
            .functional => try orderFunctionalPinGroups(ctx, hub_ref, hub_pg),
        };
        for (ordered) |g| {
            var tagged = g;
            tagged.group = grp;
            try all_groups.append(allocator, tagged);
        }
    }
    if (total_pins == 0) return null;

    return .{
        .ref = hub_ref,
        .inst = hub_inst,
        .groups = try all_groups.toOwnedSlice(allocator),
    };
}

fn pinGroupCanonicalNet(ctx: *RenderCtx, hub_ref: []const u8, group: PinGroup) ![]const u8 {
    for (group.conns) |conn| {
        const key = try std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ hub_ref, conn.pin });
        if (ctx.pin_canonical_nets.get(key)) |net| return draw.baseNetName(net);
    }
    return "";
}

/// Lift `items[from]` out and re-seat it at `after + 1`, sliding everything in
/// between one slot later. Generic over the element type so the pin groups and
/// their parallel canonical-net cache are permuted by the same call and cannot
/// drift out of sync.
fn moveGroupAfter(comptime T: type, items: []T, from: usize, after: usize) void {
    std.debug.assert(from > after + 1);
    const moved = items[from];
    std.mem.copyBackwards(T, items[after + 2 .. from + 1], items[after + 1 .. from]);
    items[after + 1] = moved;
}

fn isFeedbackPinGroup(group: PinGroup) bool {
    for (group.stub_labels) |label| {
        if (isFeedbackPinLabel(label)) return true;
    }
    return isFeedbackPinLabel(group.display_name);
}

fn isFeedbackPinLabel(label: []const u8) bool {
    return std.ascii.eqlIgnoreCase(label, "FB") or
        std.ascii.eqlIgnoreCase(label, "VFB") or
        std.ascii.eqlIgnoreCase(label, "SENSE") or
        std.ascii.eqlIgnoreCase(label, "VSENSE") or
        std.ascii.startsWithIgnoreCase(label, "FB_(") or
        std.ascii.startsWithIgnoreCase(label, "VFB_(") or
        std.ascii.startsWithIgnoreCase(label, "SENSE_(") or
        std.ascii.startsWithIgnoreCase(label, "VSENSE_(");
}

fn isFunctionalSignalTerminal(net: []const u8) bool {
    if (net.len == 0 or draw.isGroundNet(net)) return false;
    for (rails_mod.schematic_supply_prefixes) |prefix| {
        if (std.ascii.startsWithIgnoreCase(net, prefix)) return false;
    }
    return true;
}

/// `canonical_nets` is the per-position canonical net of `groups`, computed once
/// per hub by the caller and permuted alongside it. Deriving it here instead
/// cost an `allocPrint` per (source conn × candidate) pair — O(n²) arena
/// garbage per hub, on a page that renders every hub of every section.
fn relatedTargetIndex(
    ctx: *RenderCtx,
    hub_ref: []const u8,
    groups: []const PinGroup,
    canonical_nets: []const []const u8,
    source_idx: usize,
) !?usize {
    const source = groups[source_idx];
    const accepts_supply = isFeedbackPinGroup(source);
    for (source.conns) |conn| {
        const spoke = switch (conn.endpoint) {
            .pin => |pin| pin,
            .net => continue,
        };
        if (!ctx.spoke_set.contains(spoke.ref_des)) continue;
        const terminal = draw.baseNetName(try connection.getConnTerminal(ctx, conn.endpoint, hub_ref, conn.pin));
        if (!accepts_supply and !isFunctionalSignalTerminal(terminal)) continue;
        for (canonical_nets, 0..) |candidate_net, candidate_idx| {
            if (candidate_idx == source_idx) continue;
            if (std.mem.eql(u8, terminal, candidate_net)) return candidate_idx;
        }
    }

    // A visible boundary net deliberately terminates the drawing walk, so it
    // cannot reveal a relationship on the far side of that label. Placement
    // still follows passive-only signal paths across the boundary: a
    // differential termination between two AC-coupled inputs is one functional
    // unit and must be ordered together before the hub is split into columns.
    for (groups, 0..) |candidate, candidate_idx| {
        if (candidate_idx == source_idx) continue;
        if (try hub_mod.groupsSharePassiveSignalPath(ctx, hub_ref, source, candidate)) return candidate_idx;
    }
    return null;
}

/// Keep physical order as the baseline, then close only the gaps that carry a
/// functional connection. The later group moves beside the earlier one, so all
/// unrelated pins retain their relative order. This covers feedback dividers
/// and non-supply signal returns such as OSCINP/OSCINM, RFOUTBM/RFOUTBP, and
/// CPOUT/VTUNE without pulling ordinary VDD/VCC bias networks out of sequence.
fn orderFunctionalPinGroups(
    ctx: *RenderCtx,
    hub_ref: []const u8,
    groups: []const PinGroup,
) ![]const PinGroup {
    var ordered: std.ArrayList(PinGroup) = .empty;
    try ordered.appendSlice(ctx.allocator, groups);

    // Canonical net per position, permuted in lockstep with `ordered` below.
    const canonical_nets = try ctx.allocator.alloc([]const u8, ordered.items.len);
    for (ordered.items, canonical_nets) |group, *net| net.* = try pinGroupCanonicalNet(ctx, hub_ref, group);

    // Each group is considered as a source exactly once, in position order.
    // `source_idx` must therefore only ever advance: an earlier revision reset
    // it to `target_idx + 1` after a backward move, which — since that branch
    // requires `source_idx > target_idx + 1` — rewound to at or before the
    // current position. Two groups both related to one earlier target then
    // swapped the same pair of slots forever, spinning a request thread and
    // leaking an arena allocation per pass until the box ran out of memory.
    // Nothing is lost by not rewinding: a backward move only shifts groups
    // that already had their turn as a source.
    var source_idx: usize = 0;
    while (source_idx < ordered.items.len) : (source_idx += 1) {
        const target_idx = try relatedTargetIndex(ctx, hub_ref, ordered.items, canonical_nets, source_idx) orelse continue;
        if (target_idx > source_idx + 1) {
            moveGroupAfter(PinGroup, ordered.items, target_idx, source_idx);
            moveGroupAfter([]const u8, canonical_nets, target_idx, source_idx);
        } else if (source_idx > target_idx + 1) {
            moveGroupAfter(PinGroup, ordered.items, source_idx, target_idx);
            moveGroupAfter([]const u8, canonical_nets, source_idx, target_idx);
        }
    }
    return ordered.toOwnedSlice(ctx.allocator);
}

fn writeSectionPorts(w: anytype, sec: Section) !void {
    if (sec.ports.len == 0) return;
    try w.print(
        "<details class=\"sec-ports\"><summary>Ports · {d}</summary>",
        .{sec.ports.len},
    );
    try w.writeAll("<table class=\"ports\"><thead><tr><th>Port</th><th>Dir</th><th>Type</th><th>Voltage</th><th>Role/Protocol</th></tr></thead><tbody>");
    for (sec.ports) |p| {
        try w.writeAll(row_td_code_open);
        try writeHtmlEscaped(w, p.name);
        try w.print("</code></td><td>{s}</td><td>{s}</td><td>", .{ @tagName(p.direction), @tagName(p.signal_type) });
        if (p.voltage) |v| try w.print("{d}V", .{v}) else try w.writeAll(muted_em_dash);
        try w.writeAll(td_cell_sep);
        if (p.protocol.len > 0) {
            try w.writeAll("<code>");
            try writeHtmlEscaped(w, p.protocol);
            try w.writeAll("</code>");
        }
        if (p.role.len > 0) {
            if (p.protocol.len > 0) try w.writeAll(" · ");
            try writeHtmlEscaped(w, p.role);
        }
        if (p.protocol.len == 0 and p.role.len == 0) try w.writeAll(muted_em_dash);
        try w.writeAll(row_td_close);
    }
    try w.writeAll(table_details_close);
}

/// Render the per-section "Boundary contracts" block on the schematic page —
/// one row per `(port …)` that declared an `(electrical ...)` sub-clause.
/// Skipped entirely when no port on the section carries electrical data, so
/// sections without boundary contracts stay uncluttered. Reads
/// `env_mod.SectionPort` directly (the schematic page never builds the
/// flattened `PortSummary` view).
fn writeSectionBoundaryContracts(w: anytype, sec: Section) !void {
    var any = false;
    for (sec.ports) |p| {
        if (p.electrical != null) {
            any = true;
            break;
        }
    }
    if (!any) return;

    try w.writeAll("<details class=\"sec-contracts\"><summary>Boundary contracts</summary>");
    try w.writeAll("<table class=\"contracts\"><thead><tr>");
    try w.writeAll("<th>Port</th><th>Dir</th><th>Type</th>");
    try w.writeAll("<th>V<sub>OH</sub></th><th>V<sub>OL</sub></th>");
    try w.writeAll("<th>V<sub>IH</sub></th><th>V<sub>IL</sub></th>");
    try w.writeAll("<th>V<sub>max</sub></th><th>Drive</th><th>Domain</th>");
    try w.writeAll("</tr></thead><tbody>");
    for (sec.ports) |p| {
        const e = p.electrical orelse continue;
        try w.writeAll(row_td_code_open);
        try writeHtmlEscaped(w, p.name);
        try w.print("</code></td><td>{s}</td><td>", .{@tagName(p.direction)});
        if (e.electrical_type) |t| {
            try writeHtmlEscaped(w, @tagName(t));
        } else {
            try w.writeAll(muted_em_dash);
        }
        try w.writeAll("</td>");
        try writeContractVoltCell(w, e.v_oh_typ);
        try writeContractVoltCell(w, e.v_ol_typ);
        try writeContractVoltCell(w, e.v_ih_min);
        try writeContractVoltCell(w, e.v_il_max);
        try writeContractVoltCell(w, e.max_voltage);
        try w.writeAll("<td>");
        if (e.drive) |d| {
            try writeHtmlEscaped(w, @tagName(d));
        } else {
            try w.writeAll(muted_em_dash);
        }
        try w.writeAll(td_cell_sep);
        if (e.domain.len > 0) {
            try writeHtmlEscaped(w, e.domain);
        } else {
            try w.writeAll(muted_em_dash);
        }
        try w.writeAll(row_td_close);
    }
    try w.writeAll(table_details_close);
}

fn writeContractVoltCell(w: anytype, v: ?f64) !void {
    try w.writeAll("<td>");
    if (v) |x| {
        try w.print("{d:.2}", .{x});
    } else {
        try w.writeAll(muted_em_dash);
    }
    try w.writeAll("</td>");
}

fn writeNotes(w: anytype, notes: []const env_mod.SectionNote) !void {
    try w.writeAll("<details class=\"sec-notes\"><summary>");
    try w.print("Notes ({d})</summary><ul>", .{notes.len});
    for (notes) |n| {
        try w.writeAll("<li>");
        try writeHtmlEscaped(w, n.text);
        if (n.ref) |r| {
            try w.writeAll(" <a class=\"note-ref\" target=\"_blank\" href=\"/pdf-view/");
            try writeHtmlEscaped(w, r.pdf);
            var has_query = false;
            if (r.page > 0) {
                try w.print("?page={d}", .{r.page});
                has_query = true;
            }
            if (r.quote) |q| {
                try w.writeAll(if (has_query) "&highlight=" else "?highlight=");
                try writeUrlEncoded(w, q);
            }
            try w.writeAll("\">📄 ");
            try writeHtmlEscaped(w, r.pdf);
            if (r.page > 0) try w.print(" p.{d}", .{r.page});
            try w.writeAll("</a>");
        }
        try w.writeAll("</li>");
    }
    try w.writeAll("</ul></details>");
}

const SubBlockMode = enum {
    /// Standalone top-level card for sub-blocks that don't fit under a section
    /// (power chain, vref, fallback for section-less designs).
    standalone,
    /// Inline nested card rendered inside the section that adopts this
    /// sub-block (e.g. flash inside "XSPI2 NOR Flash").
    attached,
};

/// Render a sub-block's hubs as a card. In `standalone` mode the card is its
/// own `<section>` (used by section-less designs and floating sub-blocks); in
/// `attached` mode it's a `<div>` nested inside the adopting section's frame,
/// with the heading demoted to `<h3>`.
/// Two sub-blocks are render-identical when they come from the same module
/// source and evaluated to the same shape (instance/net counts and the same
/// component+value sequence). Module calls with different parameters that
/// change the produced circuit fail the sequence check and render apart.
///
/// Public because it is the single authority on this question: the schematic
/// page collapses identical repeats into one card, and `export_pdf.zig` gives
/// them one PDF page, off the same predicate.
pub fn sameSubBlockShape(a: env_mod.SubBlock, b: env_mod.SubBlock) bool {
    if (a.source.len == 0 or !std.mem.eql(u8, a.source, b.source)) return false;
    if (a.block.instances.len != b.block.instances.len) return false;
    if (a.block.nets.len != b.block.nets.len) return false;
    for (a.block.instances, b.block.instances) |ia, ib| {
        if (!std.mem.eql(u8, ia.component, ib.component)) return false;
        if (!std.mem.eql(u8, ia.value, ib.value)) return false;
    }
    return true;
}

/// Grouping info for identical repeated sub-blocks: the exemplar card
/// carries every sibling's name and a ×N count instead of N copies.
const SubBlockGroup = struct {
    extra_names: []const u8, // ", ch3, ch4, …" appended after the exemplar name
    copies: usize,
};

fn writeSubBlockCard(
    page_render: PageRender,
    w: anytype,
    allocator: Allocator,
    sb: env_mod.SubBlock,
    check_results: *const CheckResultMap,
    mode: SubBlockMode,
    group: ?SubBlockGroup,
) !void {
    const slug = try review.slugify(allocator, sb.name);
    switch (mode) {
        .standalone => try w.print("<section class=\"sch-section\" id=\"sec-{s}\" data-slug=\"{s}\">", .{ slug, slug }),
        // Use the `sub-` prefix to avoid id collisions when a section and an
        // attached sub-block share a slug (e.g. section "USB" + sub-block "usb").
        .attached => try w.print("<div class=\"sch-attached-sub\" id=\"sub-{s}\" data-slug=\"{s}\">", .{ slug, slug }),
    }
    try w.writeAll(switch (mode) {
        .standalone => "<div class=\"sec-head\"><h2>",
        .attached => "<div class=\"sec-head\"><h3>",
    });
    try writeHtmlEscaped(w, sb.name);
    if (group) |g| try writeHtmlEscaped(w, g.extra_names);
    try w.writeAll(switch (mode) {
        .standalone => "</h2>",
        .attached => "</h3>",
    });
    if (group) |g| {
        try w.print("<span class=\"pill pill-ok\">sub circuit &times;{d}</span>", .{g.copies});
        try w.writeAll("<span class=\"pill\">identical copies — rendered once</span>");
    } else {
        try w.writeAll("<span class=\"pill pill-ok\">sub circuit</span>");
    }
    // Right-side header actions: "Copy source" (pulls the underlying module/file
    // text via /api/module-source) plus a link to this sub circuit's PCB layout.
    //
    // The layout is a LINK, never an embed. It used to be a Schematic ⇄ PCB
    // toggle that swapped this card's body for a `/pcb-layout/…?embed=1` iframe,
    // which meant opening a sub circuit pulled a whole second page — placement
    // solve, sidecar parse and all — into the schematic. This page renders the
    // design's `.sexp` and nothing else, so the layout opens in its own tab.
    try w.writeAll("<div class=\"subc-head-actions\">");
    if (sb.source.len > 0) {
        try w.writeAll("<button type=\"button\" class=\"copy-src-btn\" data-src=\"");
        try writeHtmlEscaped(w, sb.source);
        try w.writeAll("\">Copy source</button>");
    }
    try writeSubCircuitPcbLink(w, page_render.design_name, slug, sb);
    try w.writeAll("</div>"); // .subc-head-actions
    try w.writeAll("</div>"); // .sec-head
    try w.writeAll(secDescOpen);
    try writeHtmlEscaped(w, sb.block.name);
    try w.writeAll("</p>");

    var hub_refs: std.ArrayList([]const u8) = .empty;
    defer hub_refs.deinit(allocator);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    for (sb.block.instances) |inst| {
        const fi: FlatInst = .{
            .ref_des = inst.ref_des,
            .component = inst.component,
            .value = inst.value,
            .symbol = inst.symbol,
            .parts = inst.parts,
        };
        if (!isHub(fi)) continue;
        if (seen.contains(inst.ref_des)) continue;
        try seen.put(allocator, inst.ref_des, {});
        try hub_refs.append(allocator, inst.ref_des);
    }

    // A module can organise its hub pins with `(pins "REF" (group "label") …)`
    // groups (the same convention top-level designs use). Collect them from the
    // sub-block's sections so the hub renders one labelled SVG per group instead
    // of a single flat pin list. (ref_des is remapped to the flattened hub by
    // ids.assignSubBlockRefDes, so it matches hub_refs above.)
    var sb_pin_groups: std.ArrayList(env_mod.PinGroup) = .empty;
    defer sb_pin_groups.deinit(allocator);
    for (sb.block.sections) |sec| {
        for (sec.pin_groups) |pg| try sb_pin_groups.append(allocator, pg);
        for (sec.sub_sections) |sub_sec| {
            for (sub_sec.pin_groups) |pg| try sb_pin_groups.append(allocator, pg);
        }
    }

    try writeSectionHubs(page_render, w, allocator, sb_pin_groups.items, hub_refs.items, check_results);

    try w.writeAll(switch (mode) {
        .standalone => sectionClose,
        .attached => "</div>",
    });
}

/// The sub circuit's "PCB Layout" header link — the one way to its layout from
/// this page, opening in a new tab rather than embedding.
///
/// A module sub circuit owns a reusable layout, so it links to that module's own
/// editor (`/pcb-layout/<module>`) where drag / Rough / Save / ★ write
/// `lib/modules/<module>.layouts.json` and every design instantiating it picks
/// the result up. A path- or inline-sourced sub circuit has no reusable module,
/// so it links to the design-scoped view of just its slice (`?sub=<slug>`).
///
/// `slug` is `review.slugify` output ([a-z0-9-]), safe unescaped in a URL;
/// `design_name` and the module name are percent-encoded.
fn writeSubCircuitPcbLink(
    w: *std.Io.Writer,
    design_name: []const u8,
    slug: []const u8,
    sb: env_mod.SubBlock,
) !void {
    try w.writeAll("<a class=\"subc-pcb-open\" target=\"_blank\" rel=\"noopener\" href=\"/pcb-layout/");
    if (moduleSourceName(sb)) |m| {
        try writeUrlEncoded(w, m);
        try w.writeAll("\">");
    } else {
        try writeUrlEncoded(w, design_name);
        try w.writeAll("?sub=");
        try w.writeAll(slug);
        try w.writeAll("\">");
    }
    try w.writeAll("PCB Layout \u{2197}</a>");
}

/// The module name a sub-block instantiates: `sb.source` when it is a bare
/// module name (non-empty, no `/`). Null for path-based sources and inline
/// design-blocks, which have no reusable module and so no `/pcb-layout/<module>`
/// page of their own.
fn moduleSourceName(sb: env_mod.SubBlock) ?[]const u8 {
    if (sb.source.len == 0) return null;
    if (std.mem.indexOfScalar(u8, sb.source, '/') != null) return null;
    return sb.source;
}

/// Minimal DesignBlock for attachment tests — all collections empty so the
/// test only populates the fields it exercises.
fn emptyAttachBlock(name: []const u8) DesignBlock {
    return .{
        .name = name,
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
}

fn svgPassiveCount(svg: []const u8) !usize {
    const needle = "data-passive-count=\"";
    var total: usize = 0;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, svg, cursor, needle)) |at| {
        const start = at + needle.len;
        const end = std.mem.indexOfScalarPos(u8, svg, start, '"') orelse return error.InvalidCharacter;
        total += try std.fmt.parseInt(usize, svg[start..end], 10);
        cursor = end + 1;
    }
    return total;
}

fn svgFirstY1After(svg: []const u8, marker: []const u8) !f64 {
    const marker_at = std.mem.indexOf(u8, svg, marker) orelse return error.InvalidCharacter;
    const y_at = std.mem.indexOfPos(u8, svg, marker_at + marker.len, " y1=\"") orelse return error.InvalidCharacter;
    const start = y_at + " y1=\"".len;
    const end = std.mem.indexOfScalarPos(u8, svg, start, '"') orelse return error.InvalidCharacter;
    return std.fmt.parseFloat(f64, svg[start..end]);
}

// spec: render_svg - Identical decoupling capacitors each render as their own labeled schematic symbol
test "SVG renders identical decoupling capacitors individually" {
    const instances = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "ic", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "C1", .component = "cap-0402", .value = "0.1uF", .footprint = "", .symbol = "generic-cap" },
        .{ .ref_des = "C2", .component = "cap-0402", .value = "0.1uF", .footprint = "", .symbol = "generic-cap" },
    };
    const supply_pins = [_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "C1", .pin = "1" },
        .{ .ref_des = "C2", .pin = "1" },
    };
    const ground_pins = [_]env_mod.PinRef{
        .{ .ref_des = "C1", .pin = "2" },
        .{ .ref_des = "C2", .pin = "2" },
    };
    const nets = [_]env_mod.Net{
        .{ .name = "VCC", .pins = &supply_pins },
        .{ .name = "GND", .pins = &ground_pins },
    };
    var block = emptyAttachBlock("passive-accounting");
    block.instances = &instances;
    block.nets = &nets;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ctx = try setupRenderCtx(allocator, &block);
    var svg: std.Io.Writer.Allocating = .init(allocator);
    try std.testing.expect(try renderHubSvg(&ctx, &svg.writer, allocator, &.{}, "U1"));

    var source_passives: usize = 0;
    for (instances) |inst| {
        const flat: FlatInst = .{ .ref_des = inst.ref_des, .component = inst.component, .value = inst.value, .symbol = inst.symbol };
        if (!draw.isHub(flat)) source_passives += 1;
    }
    try std.testing.expectEqual(source_passives, try svgPassiveCount(svg.written()));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, svg.written(), "data-passive-count=\"1\""));
    try std.testing.expect(std.mem.indexOf(u8, svg.written(), ">C1 0.1uF</text>") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg.written(), ">C2 0.1uF</text>") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg.written(), "2× 0.1uF") == null);
}

// spec: render_svg - A Functional shared RF bias rail directly joins compact P/M pull-up rows and centers its choke/bypass tree between them
// spec: render_svg - A Functional RF pair keeps its grounded termination and externally visible signal on clear outer rows instead of crossing the centered shared-bias tree
// spec: render_svg - Functional shared supply rails keep signal-owned RF bias chokes off unrelated pull-ups such as CE
test "functional RF bias rail joins compact output pull-ups around a centered bias tree" {
    const hub_pins = [_]env_mod.PartPin{
        .{ .pin = "1", .net = "LMX_CE", .pin_name = "CE" },
        .{ .pin = "2", .net = "AUX_2", .pin_name = "AUX2" },
        .{ .pin = "3", .net = "AUX_3", .pin_name = "AUX3" },
        .{ .pin = "7", .net = "V_3V3", .pin_name = "VCC" },
        .{ .pin = "11", .net = "V_3V3", .pin_name = "VCC" },
        .{ .pin = "22", .net = "LMX_RFOUTAM", .pin_name = "RFOUTAM" },
        .{ .pin = "23", .net = "LMX_RFOUTAP", .pin_name = "RFOUTAP" },
    };
    const hub_parts = [_]env_mod.Part{.{ .name = "Straps", .pins = &hub_pins }};
    const instances = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "lmx2595", .value = "", .footprint = "", .symbol = "lmx2595", .parts = &hub_parts },
        .{ .ref_des = "R_AM", .component = "res-0402", .value = "50R", .footprint = "", .symbol = "generic-res" },
        .{ .ref_des = "R_AP", .component = "res-0402", .value = "50R", .footprint = "", .symbol = "generic-res" },
        .{ .ref_des = "C_AM_TERM", .component = "cap-0402", .value = "0.01uF", .footprint = "", .symbol = "generic-cap" },
        .{ .ref_des = "R_AM_TERM", .component = "res-0402", .value = "50R", .footprint = "", .symbol = "generic-res" },
        .{ .ref_des = "C_AP_OUT", .component = "cap-0402", .value = "0.01uF", .footprint = "", .symbol = "generic-cap" },
        .{ .ref_des = "L_BIAS", .component = "ind-0402", .value = "18nH", .footprint = "", .symbol = "generic-ind" },
        .{ .ref_des = "C_BIAS", .component = "cap-0402", .value = "0.01uF", .footprint = "", .symbol = "generic-cap" },
        .{ .ref_des = "R_CE", .component = "res-0402", .value = "100K", .footprint = "", .symbol = "generic-res" },
    };
    const am_pins = [_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "22" },
        .{ .ref_des = "R_AM", .pin = "1" },
        .{ .ref_des = "C_AM_TERM", .pin = "1" },
    };
    const ap_pins = [_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "23" },
        .{ .ref_des = "R_AP", .pin = "1" },
        .{ .ref_des = "C_AP_OUT", .pin = "2" },
    };
    const bias_pins = [_]env_mod.PinRef{
        .{ .ref_des = "R_AM", .pin = "2" },
        .{ .ref_des = "R_AP", .pin = "2" },
        .{ .ref_des = "L_BIAS", .pin = "1" },
        .{ .ref_des = "C_BIAS", .pin = "1" },
    };
    const term_pins = [_]env_mod.PinRef{
        .{ .ref_des = "C_AM_TERM", .pin = "2" },
        .{ .ref_des = "R_AM_TERM", .pin = "1" },
    };
    const ground_pins = [_]env_mod.PinRef{
        .{ .ref_des = "R_AM_TERM", .pin = "2" },
        .{ .ref_des = "C_BIAS", .pin = "2" },
    };
    const out_pins = [_]env_mod.PinRef{.{ .ref_des = "C_AP_OUT", .pin = "1" }};
    const ce_pins = [_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "R_CE", .pin = "2" },
    };
    const aux_2_pins = [_]env_mod.PinRef{.{ .ref_des = "U1", .pin = "2" }};
    const aux_3_pins = [_]env_mod.PinRef{.{ .ref_des = "U1", .pin = "3" }};
    const supply_pins = [_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "7" },
        .{ .ref_des = "U1", .pin = "11" },
        .{ .ref_des = "L_BIAS", .pin = "2" },
        .{ .ref_des = "R_CE", .pin = "1" },
    };
    const nets = [_]env_mod.Net{
        .{ .name = "LMX_CE", .pins = &ce_pins },
        .{ .name = "AUX_2", .pins = &aux_2_pins },
        .{ .name = "AUX_3", .pins = &aux_3_pins },
        .{ .name = "LMX_RFOUTAM", .pins = &am_pins },
        .{ .name = "LMX_RFOUTAP", .pins = &ap_pins },
        .{ .name = "LO_BIAS_A", .pins = &bias_pins },
        .{ .name = "RFOUTAM_TERM", .pins = &term_pins },
        .{ .name = "GND", .pins = &ground_pins },
        .{ .name = "LO1_SYNTH", .pins = &out_pins },
        .{ .name = "V_3V3", .pins = &supply_pins },
    };
    const ports = [_]env_mod.Port{
        .{ .name = "LO1_SYNTH", .net = "LO1_SYNTH", .direction = "out" },
        .{ .name = "V_3V3", .net = "V_3V3", .direction = "in" },
        .{ .name = "GND", .net = "GND", .direction = "bidi" },
    };
    var block = emptyAttachBlock("lmx-output-network");
    block.instances = &instances;
    block.nets = &nets;
    block.ports = &ports;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ctx = try setupRenderCtx(allocator, &block);
    var svg: std.Io.Writer.Allocating = .init(allocator);
    try std.testing.expect(try renderHubSvg(&ctx, &svg.writer, allocator, &.{}, "U1"));

    try std.testing.expectEqual(@as(usize, 8), try svgPassiveCount(svg.written()));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, svg.written(), "<g data-ref=\"L_BIAS\""));
    const pin_22 = std.mem.indexOf(u8, svg.written(), "<g class=\"pin-stub\" data-ref=\"U1\" data-pin=\"22\"").?;
    const pullup = std.mem.indexOf(u8, svg.written(), "<g data-ref=\"R_AM\"").?;
    const pin_23 = std.mem.indexOf(u8, svg.written(), "<g class=\"pin-stub\" data-ref=\"U1\" data-pin=\"23\"").?;
    try std.testing.expect(pin_22 < pullup);
    try std.testing.expect(pullup < pin_23);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, svg.written(), ">LO_BIAS_A</text>"));
    try std.testing.expect(std.mem.count(u8, svg.written(), "data-net=\"LO_BIAS_A.local.R_AM\"") >= 3);

    const pin_22_y = try svgFirstY1After(svg.written(), "<g class=\"pin-stub\" data-ref=\"U1\" data-pin=\"22\"");
    const pin_23_y = try svgFirstY1After(svg.written(), "<g class=\"pin-stub\" data-ref=\"U1\" data-pin=\"23\"");
    const choke_y = try svgFirstY1After(svg.written(), "<g data-ref=\"L_BIAS\"");
    const bypass_y = try svgFirstY1After(svg.written(), "<g data-ref=\"C_BIAS\"");
    const termination_y = try svgFirstY1After(svg.written(), "<g data-ref=\"C_AM_TERM\"");
    const output_y = try svgFirstY1After(svg.written(), "<g data-ref=\"C_AP_OUT\"");
    try std.testing.expectApproxEqAbs(pin_22_y + pin_23_y, choke_y + bypass_y, 0.1);
    try std.testing.expectApproxEqAbs(@as(f64, 80.0), @abs(pin_23_y - pin_22_y), 0.1);
    try std.testing.expect(@abs(termination_y - choke_y) >= 40.0);
    try std.testing.expect(@abs(output_y - bypass_y) >= 40.0);
}

/// Count how many of a spoke's synthesized hub attachments land on `hub_ref`,
/// and report (via `anchored`) whether one of them is `want_pin`. Test helper
/// for the single-pin-side anchor behaviour.
fn countHubAttachments(adj: []const ctx_mod.AdjEntry, hub_ref: []const u8, want_pin: []const u8, anchored: *bool) usize {
    var n: usize = 0;
    for (adj) |ae| switch (ae.endpoint) {
        .pin => |p| {
            if (!std.mem.eql(u8, p.ref_des, hub_ref)) continue;
            n += 1;
            if (std.mem.eql(u8, p.pin, want_pin)) anchored.* = true;
        },
        .net => {},
    };
    return n;
}

// spec: render_html - A passive bridging a single-hub-pin net and a multi-hub-pin net renders off its single-pin side
// spec: render_html - A passive bridging two single-hub-pin nets has no anchor and keeps default placement
test "single-pin-side passive anchors to its lone hub pin, not the busy rail" {
    // R1 (a 10k pull-up) bridges a lone signal pin (U1.1, net SIG) and the VDD
    // rail (U1.2/3/4). It must render off the single SIG pin — i.e. be attached
    // only to U1.1, never the busy VDD pins. R2 is a control: it bridges two
    // lone-hub nets (symmetric), so it gets no anchor and keeps default placement.
    const insts = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "ic", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "R1", .component = "res", .value = "10k", .footprint = "", .symbol = "" },
        .{ .ref_des = "R2", .component = "res", .value = "0R", .footprint = "", .symbol = "" },
    };
    const sig_pins = [_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "R1", .pin = "1" } };
    const vdd_pins = [_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "2" }, .{ .ref_des = "U1", .pin = "3" },
        .{ .ref_des = "U1", .pin = "4" }, .{ .ref_des = "R1", .pin = "2" },
    };
    const a_pins = [_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "5" }, .{ .ref_des = "R2", .pin = "1" } };
    const b_pins = [_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "6" }, .{ .ref_des = "R2", .pin = "2" } };
    const nets = [_]env_mod.Net{
        .{ .name = "SIG", .pins = &sig_pins },
        .{ .name = "VDD", .pins = &vdd_pins },
        .{ .name = "SIGA", .pins = &a_pins },
        .{ .name = "SIGB", .pins = &b_pins },
    };

    var block = emptyAttachBlock("anchor-test");
    block.instances = &insts;
    block.nets = &nets;

    // RenderCtx never frees (it owns no deinit); an arena keeps the leak
    // checker happy while still exercising the real allocator paths.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try setupRenderCtx(arena.allocator(), &block);

    // R1 anchors to its single-pin side; the symmetric R2 does not.
    try std.testing.expectEqualStrings("SIG", ctx.spoke_anchor_net.get("R1").?);
    try std.testing.expect(ctx.spoke_anchor_net.get("R2") == null);

    // R1's only synthesized hub attachment is U1.1 — the VDD pins are suppressed.
    var anchored_to_sig_pin = false;
    const hub_attachments = countHubAttachments(ctx.adjacency.get("R1").?.items, "U1", "1", &anchored_to_sig_pin);
    try std.testing.expect(anchored_to_sig_pin);
    try std.testing.expectEqual(@as(usize, 1), hub_attachments);
}

/// Fallback rendering for designs that declare instances directly in
/// `design-block` without any `section` wrapper (e.g. pma3-14ln). Every
/// hub-prefixed top-level instance becomes its own card inside one synthetic
/// section.
fn writeFlatHubs(
    page_render: PageRender,
    w: anytype,
    allocator: Allocator,
    block: *const DesignBlock,
    check_results: *const CheckResultMap,
) !void {
    try w.writeAll("<section class=\"sch-section\" id=\"sec-design\" data-slug=\"design\"><div class=\"sec-head\"><h2>");
    try writeHtmlEscaped(w, block.name);
    try w.writeAll("</h2></div>");

    var hub_refs: std.ArrayList([]const u8) = .empty;
    defer hub_refs.deinit(allocator);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    for (block.instances) |inst| {
        const fi: FlatInst = .{
            .ref_des = inst.ref_des,
            .component = inst.component,
            .value = inst.value,
            .symbol = inst.symbol,
            .parts = inst.parts,
        };
        if (!isHub(fi)) continue;
        if (seen.contains(inst.ref_des)) continue;
        try seen.put(allocator, inst.ref_des, {});
        try hub_refs.append(allocator, inst.ref_des);
    }

    try writeSectionHubs(page_render, w, allocator, &.{}, hub_refs.items, check_results);

    try w.writeAll(sectionClose);
}

fn hasTopLevelHubs(block: *const DesignBlock) bool {
    for (block.instances) |inst| {
        const fi: FlatInst = .{
            .ref_des = inst.ref_des,
            .component = inst.component,
            .value = inst.value,
            .symbol = inst.symbol,
            .parts = inst.parts,
        };
        if (isHub(fi)) return true;
    }
    return false;
}

fn writeScripts(
    w: anytype,
    allocator: Allocator,
    design_name: []const u8,
    block: *const DesignBlock,
    ctx: *RenderCtx,
    asserted_fns: *const std.StringHashMapUnmanaged([]const u8),
    check_results: *const CheckResultMap,
    review_doc: ?review.ReviewDoc,
    schematic_path: []const u8,
) !void {
    try w.writeAll("<script>var DESIGN_NAME=");
    try writeJsString(w, design_name);
    // "module" when this page renders a reusable module (/modules/:name),
    // "design" for a project design — drives the sidebar's "Locate on PCB"
    // link target (modules have a whole-module /pcb-layout view; designs only
    // have per-sub-block scoped views).
    try w.print(";var SCH_VIEW=\"{s}\"", .{if (std.mem.eql(u8, schematic_path, "/modules/")) "module" else "design"});
    try w.writeAll(";var SCH_INDEX=");
    try writeSearchIndex(w, allocator, block, ctx, asserted_fns, check_results);
    try w.writeAll(";var SCH_AUDIT=");
    try writeAuditSummary(w, review_doc);
    try w.writeAll(";var SCH_ASSERTIONS=");
    try writeAssertionsJson(w, review_doc);
    try w.writeAll(";</script>");
    // CodeMirror (vendored) must load before schematic_viewer.js so the
    // global is available when the source editor initialises.
    try w.writeAll("<script src=\"/static/codemirror.bundle.js\"></script>");
    // Shared footprint engine must load before schematic_viewer.js (its sidebar
    // footprint preview calls FP.drawFootprint).
    try w.writeAll("<script src=\"/static/footprint_svg.js\"></script>");
    try w.writeAll("<script src=\"/static/schematic_viewer.js\"></script>");
}

/// Emit the small JSON object the sidebar's "Audit" block reads to label
/// its links — `unresolved` counts error+warning ERC violations, and
/// `assertion_fail` counts failed `(assert …)` evaluations. Both default
/// to 0 / null when no review-doc is attached so the client can suppress
/// the Audit block entirely on designs that don't build cleanly.
fn writeAuditSummary(w: anytype, review_doc: ?review.ReviewDoc) !void {
    if (review_doc) |doc| {
        var assertion_fail: usize = 0;
        for (doc.assertions) |a| {
            if (a.status == .fail) assertion_fail += 1;
        }
        try w.print(
            "{{\"present\":true,\"unresolved\":{d},\"assertion_total\":{d},\"assertion_fail\":{d}}}",
            .{ doc.unresolved.len, doc.assertions.len, assertion_fail },
        );
    } else {
        try w.writeAll("{\"present\":false}");
    }
}

/// Emit the full assertions list as a JSON array so the ERC sidebar panel can
/// render each `(assert …)` result alongside the ERC violations — the page no
/// longer shows an Assertions table at the bottom. Empty array when no
/// review-doc is attached.
fn writeAssertionsJson(w: anytype, review_doc: ?review.ReviewDoc) !void {
    try w.writeAll("[");
    if (review_doc) |doc| {
        for (doc.assertions, 0..) |a, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{{\"status\":\"{s}\",\"message\":", .{@tagName(a.status)});
            try writeJsString(w, a.message);
            try w.writeAll("}");
        }
    }
    try w.writeAll("]");
}

/// JS bundle for the schematic viewer (sidebar search, click handlers, live
/// reload). Served verbatim from `/static/schematic_viewer.js` — exposed pub
/// so `static_assets.zig` can register it without a second `@embedFile`.
pub const schematic_viewer_js_asset = @import("serve/schematic_viewer_js.zig").schematic_viewer_js_asset;

/// Walk the design and emit a JSON object the sidebar JS uses for search +
/// inspection. Shape:
///   `{sections:[{slug,name,description,hubs:[ref...]}],
///     components:[{ref,component,value,kind,section,src?,pins?:[{id,net,fn,alt}]}],
///     nets:[{name,members:[{ref,pin,fn?}]}]}`
/// `src` is the byte offset of the instance's defining form in the design
/// source (present only for top-level instances — the sidebar's
/// "Edit source →" jump).
/// Every instance (hubs AND passives) lands in `components` so search hits
/// "C83" or "10nF". Hubs additionally carry `pins` for the component-detail
/// view; passives don't (they have at most a few pins and are inspected on
/// the SVG itself). All strings are JSON-encoded.
fn writeSearchIndex(
    w: anytype,
    allocator: Allocator,
    block: *const DesignBlock,
    ctx: *RenderCtx,
    asserted_fns: *const std.StringHashMapUnmanaged([]const u8),
    check_results: *const CheckResultMap,
) !void {
    var ref_section: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer ref_section.deinit(allocator);
    try buildRefSectionMap(allocator, block, &ref_section);

    try w.writeAll("{\"sections\":[");

    var first = true;
    for (block.sections) |sec| {
        try emitSectionEntry(w, allocator, sec, &first, check_results);
    }
    for (block.sub_blocks) |sb| {
        if (!first) try w.writeAll(",");
        first = false;
        const slug = try review.slugify(allocator, sb.name);
        const sb_cat = rb.classifyByName(sb.name, sb.block.instances);
        // Roll up requirement counts for this sub-block (uses every
        // instance ref_des inside the sub-block design).
        var sb_refs: std.ArrayList([]const u8) = .empty;
        defer sb_refs.deinit(allocator);
        for (sb.block.instances) |inst| try sb_refs.append(allocator, inst.ref_des);
        const sb_counts = countsForRefs(check_results, sb_refs.items);
        try w.writeAll("{\"slug\":");
        try writeJsString(w, slug);
        try w.writeAll(",\"name\":");
        try writeJsString(w, sb.name);
        try w.writeAll(",\"description\":");
        try writeJsString(w, sb.block.name);
        // Marks this entry as a sub-block (vs. a plain section): the sidebar
        // uses it to build the per-sub-block "Locate on PCB" link
        // (/pcb-layout/:design?sub=<slug>&focus=<ref>).
        try w.writeAll(",\"sub\":true,\"category\":");
        try writeJsString(w, @tagName(sb_cat));
        try emitReqStatusFields(w, sb_counts);
        try w.writeAll(hubsArrayPrefix);
        try emitHubRefsForBlock(w, sb.block);
        try w.writeAll("]}");
    }
    if (block.sections.len == 0 and hasTopLevelHubs(block)) {
        if (!first) try w.writeAll(",");
        first = false;
        const flat_cat = rb.classifyByName(block.name, block.instances);
        var flat_refs: std.ArrayList([]const u8) = .empty;
        defer flat_refs.deinit(allocator);
        for (block.instances) |inst| try flat_refs.append(allocator, inst.ref_des);
        const flat_counts = countsForRefs(check_results, flat_refs.items);
        try w.writeAll("{\"slug\":\"design\",\"name\":");
        try writeJsString(w, block.name);
        try w.writeAll(",\"description\":\"\",\"category\":");
        try writeJsString(w, @tagName(flat_cat));
        try emitReqStatusFields(w, flat_counts);
        try w.writeAll(hubsArrayPrefix);
        try emitHubRefsForBlock(w, block);
        try w.writeAll("]}");
    }

    try w.writeAll("],\"components\":[");
    first = true;
    var inst_iter = ctx.inst_map.iterator();
    while (inst_iter.next()) |kv| {
        const inst = kv.value_ptr.*;
        const slug = ref_section.get(inst.ref_des) orelse "";
        try emitComponentEntry(w, allocator, inst, slug, ctx, asserted_fns, &first);
    }

    try w.writeAll("],\"nets\":[");
    first = true;
    var net_iter = ctx.net_index.iterator();
    while (net_iter.next()) |kv| {
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("{\"name\":");
        try writeJsString(w, kv.key_ptr.*);
        try w.writeAll(",\"members\":[");
        var first_m = true;
        for (kv.value_ptr.items) |pr| {
            if (!first_m) try w.writeAll(",");
            first_m = false;
            try w.writeAll("{\"ref\":");
            try writeJsString(w, pr.ref_des);
            try w.writeAll(",\"pin\":");
            try writeJsString(w, pr.pin);
            try w.writeAll("}");
        }
        try w.writeAll("]}");
    }

    try w.writeAll("]}");
}

/// Map every instance ref_des in the design to the slug of the section (or
/// sub-block) that contains it. Used by the search index so each component
/// can carry its section context (drives sidebar back-navigation).
fn buildRefSectionMap(
    allocator: Allocator,
    block: *const DesignBlock,
    map: *std.StringHashMapUnmanaged([]const u8),
) !void {
    for (block.sections) |sec| try addRefsForSection(allocator, sec, map);
    for (block.sub_blocks) |sb| {
        const slug = try review.slugify(allocator, sb.name);
        for (sb.block.instances) |inst| try map.put(allocator, inst.ref_des, slug);
    }
    if (block.sections.len == 0 and hasTopLevelHubs(block)) {
        for (block.instances) |inst| try map.put(allocator, inst.ref_des, "design");
    }
}

fn addRefsForSection(allocator: Allocator, sec: Section, map: *std.StringHashMapUnmanaged([]const u8)) !void {
    const slug = try review.slugify(allocator, sec.name);
    for (sec.instances) |inst| try map.put(allocator, inst.ref_des, slug);
    for (sec.pin_groups) |pg| try map.put(allocator, pg.ref_des, slug);
    for (sec.sub_sections) |sub| try addRefsForSection(allocator, sub, map);
}

fn emitSectionEntry(
    w: anytype,
    allocator: Allocator,
    sec: Section,
    first: *bool,
    check_results: *const CheckResultMap,
) !void {
    if (!first.*) try w.writeAll(",");
    first.* = false;
    const slug = try review.slugify(allocator, sec.name);
    const cat = rb.classifySection(sec);

    // Roll up requirement counts across this section + every nested
    // sub-section so the sidebar status reflects the worst child too.
    var refs: std.ArrayList([]const u8) = .empty;
    defer refs.deinit(allocator);
    try collectSectionRefsRec(sec, &refs, allocator);
    const counts = countsForRefs(check_results, refs.items);

    try w.writeAll("{\"slug\":");
    try writeJsString(w, slug);
    try w.writeAll(",\"name\":");
    try writeJsString(w, sec.name);
    try w.writeAll(",\"description\":");
    try writeJsString(w, sec.description);
    try w.writeAll(",\"category\":");
    try writeJsString(w, @tagName(cat));
    try emitReqStatusFields(w, counts);
    try w.writeAll(hubsArrayPrefix);
    var first_hub = true;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    for (sec.pin_groups) |pg| {
        if (seen.contains(pg.ref_des)) continue;
        try seen.put(allocator, pg.ref_des, {});
        if (!first_hub) try w.writeAll(",");
        first_hub = false;
        try writeJsString(w, pg.ref_des);
    }
    for (sec.instances) |inst| {
        const fi: FlatInst = .{ .ref_des = inst.ref_des, .component = inst.component, .value = inst.value, .symbol = inst.symbol, .parts = inst.parts };
        if (!isHub(fi)) continue;
        if (seen.contains(inst.ref_des)) continue;
        try seen.put(allocator, inst.ref_des, {});
        if (!first_hub) try w.writeAll(",");
        first_hub = false;
        try writeJsString(w, inst.ref_des);
    }
    try w.writeAll("]}");
    for (sec.sub_sections) |sub| try emitSectionEntry(w, allocator, sub, first, check_results);
}

/// Emit the comma-prefixed `,"req_status":"…","req_pass":N,…` fields
/// shared between top-level sections and sub-block synthetic sections.
/// The leading comma is intentional — caller has already emitted the
/// previous field.
fn emitReqStatusFields(w: anytype, counts: SecCounts) !void {
    const status = counts.status();
    try w.print(",\"req_status\":\"{s}\"", .{@tagName(status)});
    try w.print(",\"req_pass\":{d}", .{counts.pass});
    try w.print(",\"req_verified\":{d}", .{counts.verified});
    try w.print(",\"req_na\":{d}", .{counts.na});
    try w.print(",\"req_fail\":{d}", .{counts.fail_real});
    try w.print(",\"req_overridden\":{d}", .{counts.fail_overridden});
}

fn emitHubRefsForBlock(w: anytype, block: *const DesignBlock) !void {
    var first = true;
    for (block.instances) |inst| {
        const fi: FlatInst = .{ .ref_des = inst.ref_des, .component = inst.component, .value = inst.value, .symbol = inst.symbol, .parts = inst.parts };
        if (!isHub(fi)) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try writeJsString(w, inst.ref_des);
    }
}

fn emitComponentEntry(
    w: anytype,
    allocator: Allocator,
    inst: FlatInst,
    section_slug: []const u8,
    ctx: *RenderCtx,
    asserted_fns: *const std.StringHashMapUnmanaged([]const u8),
    first: *bool,
) !void {
    if (!first.*) try w.writeAll(",");
    first.* = false;
    const kind: []const u8 = if (isHub(inst)) "hub" else "passive";
    try w.writeAll("{\"ref\":");
    try writeJsString(w, inst.ref_des);
    try w.writeAll(",\"component\":");
    try writeJsString(w, inst.component);
    try w.writeAll(",\"value\":");
    try writeJsString(w, inst.value);
    try w.writeAll(",\"mpn\":");
    try writeJsString(w, inst.mpn);
    try w.writeAll(",\"manufacturer\":");
    try writeJsString(w, inst.manufacturer);
    try w.writeAll(",\"footprint\":");
    try writeJsString(w, inst.footprint);
    try w.writeAll(",\"kind\":");
    try writeJsString(w, kind);
    try w.writeAll(",\"section\":");
    try writeJsString(w, section_slug);
    // Byte offset of the defining form in the design source — the sidebar's
    // "Edit source →" jump target. Omitted when the instance doesn't live in
    // the top-level design file (sub-block children, synthetics).
    if (inst.src_offset > 0) try w.print(",\"src\":{d}", .{inst.src_offset});

    if (!std.mem.eql(u8, kind, "hub")) {
        try w.writeAll("}");
        return;
    }

    try w.writeAll(",\"pins\":[");
    var pn_map = pinNameMapFor(ctx, allocator, inst);
    defer pn_map.deinit(allocator);

    var seen_pin: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_pin.deinit(allocator);
    var first_pin = true;
    if (ctx.adjacency.get(inst.ref_des)) |adj| {
        for (adj.items) |ae| {
            if (seen_pin.contains(ae.pin)) continue;
            try seen_pin.put(allocator, ae.pin, {});
            const net_name: []const u8 = blk: {
                const key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ inst.ref_des, ae.pin });
                defer allocator.free(key);
                break :blk ctx.pin_canonical_nets.get(key) orelse switch (ae.endpoint) {
                    .net => |n| draw.baseNetName(n),
                    .pin => "",
                };
            };
            const fn_name: []const u8 = pn_map.get(ae.pin) orelse "";
            const alt_key = try std.fmt.allocPrint(allocator, "{s}|{s}", .{ inst.ref_des, ae.pin });
            defer allocator.free(alt_key);
            const alt: []const u8 = asserted_fns.get(alt_key) orelse "";

            if (!first_pin) try w.writeAll(",");
            first_pin = false;
            try w.writeAll("{\"id\":");
            try writeJsString(w, ae.pin);
            try w.writeAll(",\"net\":");
            try writeJsString(w, net_name);
            try w.writeAll(",\"fn\":");
            try writeJsString(w, fn_name);
            try w.writeAll(",\"alt\":");
            try writeJsString(w, alt);
            try w.writeAll("}");
        }
    }
    try w.writeAll("]}");
}

fn writeJsString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '<' => try w.writeAll("\\u003c"),
        '>' => try w.writeAll("\\u003e"),
        '&' => try w.writeAll("\\u0026"),
        else => if (c < 0x20) {
            try w.print("\\u{x:0>4}", .{c});
        } else {
            try w.writeByte(c);
        },
    };
    try w.writeByte('"');
}

/// Escape `s` for an HTML text node or a single/double-quoted attribute value.
/// Delegates to the shared `escape.writeXml`, which also escapes `'` — so this
/// helper is safe in every attribute context, not just double-quoted ones.
fn writeHtmlEscaped(w: anytype, s: []const u8) !void {
    try escape.writeXml(w, s);
}

/// Percent-encode a UTF-8 string for use as a query-parameter *value*.
/// Mirrors JS `encodeURIComponent` — every byte outside the RFC 3986
/// unreserved set (alnum + `-._~`) gets `%XX`-escaped, including spaces
/// and multi-byte UTF-8 sequences. Used to splice datasheet quote text
/// into `/pdf-view/?highlight=…` URLs.
fn writeUrlEncoded(w: anytype, s: []const u8) !void {
    for (s) |c| {
        const safe = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '~';
        if (safe) {
            try w.writeByte(c);
        } else {
            try w.print("%{X:0>2}", .{c});
        }
    }
}

/// Schematic-page CSS bundle: per-page layout + the system-overview block
/// classifier's column styles. Served from `/static/schematic.css` — exposed
/// pub so `static_assets.zig` can register it without re-`@embedFile`-ing
/// the source file.
pub const schematic_css = @embedFile("assets/schematic_inline.css") ++ block_diagram.diagram_css;

test "functional pin order moves a feedback output beside its feedback pin" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var ctx = RenderCtx.init(allocator);

    try ctx.spoke_set.put(allocator, "R_TOP", {});
    var resistor_adj: std.ArrayList(AdjEntry) = .empty;
    try resistor_adj.append(allocator, .{ .pin = "1", .endpoint = .{ .pin = .{ .ref_des = "U1", .pin = "2" } } });
    try resistor_adj.append(allocator, .{ .pin = "2", .endpoint = .{ .net = "VOUT" } });
    try ctx.adjacency.put(allocator, "R_TOP", resistor_adj);
    try ctx.pin_canonical_nets.put(allocator, "U1.1", "EN");
    try ctx.pin_canonical_nets.put(allocator, "U1.2", "FB");
    try ctx.pin_canonical_nets.put(allocator, "U1.3", "GND");
    try ctx.pin_canonical_nets.put(allocator, "U1.4", "VOUT");

    const groups = [_]PinGroup{
        .{ .display_name = "EN", .pin_numbers = "1", .stub_labels = &.{"EN"}, .conns = &.{.{ .pin = "1", .endpoint = .{ .net = "EN" } }} },
        .{ .display_name = "FB", .pin_numbers = "2", .stub_labels = &.{"FB"}, .conns = &.{.{ .pin = "2", .endpoint = .{ .pin = .{ .ref_des = "R_TOP", .pin = "1" } } }} },
        .{ .display_name = "GND", .pin_numbers = "3", .stub_labels = &.{"GND"}, .conns = &.{.{ .pin = "3", .endpoint = .{ .net = "GND" } }} },
        .{ .display_name = "VOUT", .pin_numbers = "4", .stub_labels = &.{"VOUT"}, .conns = &.{.{ .pin = "4", .endpoint = .{ .net = "VOUT" } }} },
    };

    const ordered = try orderFunctionalPinGroups(&ctx, "U1", &groups);
    try std.testing.expectEqualStrings("1", ordered[0].pin_numbers);
    try std.testing.expectEqualStrings("2", ordered[1].pin_numbers);
    try std.testing.expectEqualStrings("4", ordered[2].pin_numbers);
    try std.testing.expectEqualStrings("3", ordered[3].pin_numbers);
}

test "functional pin order pairs signal returns but leaves supply pullups sequential" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var ctx = RenderCtx.init(allocator);

    try ctx.spoke_set.put(allocator, "R_CE", {});
    try ctx.spoke_set.put(allocator, "R_TUNE", {});
    var ce_adj: std.ArrayList(AdjEntry) = .empty;
    try ce_adj.append(allocator, .{ .pin = "1", .endpoint = .{ .pin = .{ .ref_des = "U1", .pin = "1" } } });
    try ce_adj.append(allocator, .{ .pin = "2", .endpoint = .{ .net = "V_3V3" } });
    try ctx.adjacency.put(allocator, "R_CE", ce_adj);
    var tune_adj: std.ArrayList(AdjEntry) = .empty;
    try tune_adj.append(allocator, .{ .pin = "1", .endpoint = .{ .pin = .{ .ref_des = "U1", .pin = "2" } } });
    try tune_adj.append(allocator, .{ .pin = "2", .endpoint = .{ .net = "LMX_VTUNE" } });
    try ctx.adjacency.put(allocator, "R_TUNE", tune_adj);

    try ctx.pin_canonical_nets.put(allocator, "U1.1", "CE");
    try ctx.pin_canonical_nets.put(allocator, "U1.2", "CPOUT");
    try ctx.pin_canonical_nets.put(allocator, "U1.7", "V_3V3");
    try ctx.pin_canonical_nets.put(allocator, "U1.16", "SPI_SCK");
    try ctx.pin_canonical_nets.put(allocator, "U1.35", "LMX_VTUNE");

    const groups = [_]PinGroup{
        .{ .display_name = "CE", .pin_numbers = "1", .stub_labels = &.{"CE"}, .conns = &.{.{ .pin = "1", .endpoint = .{ .pin = .{ .ref_des = "R_CE", .pin = "1" } } }} },
        .{ .display_name = "CPOUT", .pin_numbers = "2", .stub_labels = &.{"CPOUT"}, .conns = &.{.{ .pin = "2", .endpoint = .{ .pin = .{ .ref_des = "R_TUNE", .pin = "1" } } }} },
        .{ .display_name = "VCC", .pin_numbers = "7", .stub_labels = &.{"VCC"}, .conns = &.{.{ .pin = "7", .endpoint = .{ .net = "V_3V3" } }} },
        .{ .display_name = "SCK", .pin_numbers = "16", .stub_labels = &.{"SCK"}, .conns = &.{.{ .pin = "16", .endpoint = .{ .net = "SPI_SCK" } }} },
        .{ .display_name = "VTUNE", .pin_numbers = "35", .stub_labels = &.{"VTUNE"}, .conns = &.{.{ .pin = "35", .endpoint = .{ .net = "LMX_VTUNE" } }} },
    };

    const ordered = try orderFunctionalPinGroups(&ctx, "U1", &groups);
    try std.testing.expectEqualStrings("1", ordered[0].pin_numbers);
    try std.testing.expectEqualStrings("2", ordered[1].pin_numbers);
    try std.testing.expectEqualStrings("35", ordered[2].pin_numbers);
    try std.testing.expectEqualStrings("7", ordered[3].pin_numbers);
    try std.testing.expectEqualStrings("16", ordered[4].pin_numbers);
}

test "functional pin order pairs inputs joined beyond visible nets" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var ctx = RenderCtx.init(allocator);

    for ([_][]const u8{ "C_P", "R_TERM", "C_N" }) |ref| {
        try ctx.spoke_set.put(allocator, ref, {});
    }
    try ctx.shared_rail_nets.put(allocator, "REF_P", {});
    try ctx.shared_rail_nets.put(allocator, "REF_N", {});

    var cp_adj: std.ArrayList(AdjEntry) = .empty;
    try cp_adj.append(allocator, .{ .pin = "2", .endpoint = .{ .pin = .{ .ref_des = "U1", .pin = "1" } } });
    try cp_adj.append(allocator, .{ .pin = "1", .endpoint = .{ .net = "REF_P" } });
    try ctx.adjacency.put(allocator, "C_P", cp_adj);
    var term_adj: std.ArrayList(AdjEntry) = .empty;
    try term_adj.append(allocator, .{ .pin = "1", .endpoint = .{ .net = "REF_P" } });
    try term_adj.append(allocator, .{ .pin = "2", .endpoint = .{ .net = "REF_N" } });
    try ctx.adjacency.put(allocator, "R_TERM", term_adj);
    var cn_adj: std.ArrayList(AdjEntry) = .empty;
    try cn_adj.append(allocator, .{ .pin = "1", .endpoint = .{ .net = "REF_N" } });
    try cn_adj.append(allocator, .{ .pin = "2", .endpoint = .{ .pin = .{ .ref_des = "U1", .pin = "4" } } });
    try ctx.adjacency.put(allocator, "C_N", cn_adj);

    var ref_p_pins: std.ArrayList(env_mod.PinRef) = .empty;
    try ref_p_pins.appendSlice(allocator, &.{
        .{ .ref_des = "C_P", .pin = "1" },
        .{ .ref_des = "R_TERM", .pin = "1" },
    });
    try ctx.net_index.put(allocator, "REF_P", ref_p_pins);
    var ref_n_pins: std.ArrayList(env_mod.PinRef) = .empty;
    try ref_n_pins.appendSlice(allocator, &.{
        .{ .ref_des = "R_TERM", .pin = "2" },
        .{ .ref_des = "C_N", .pin = "1" },
    });
    try ctx.net_index.put(allocator, "REF_N", ref_n_pins);

    try ctx.pin_canonical_nets.put(allocator, "U1.1", "OSC_P");
    try ctx.pin_canonical_nets.put(allocator, "U1.2", "OTHER");
    try ctx.pin_canonical_nets.put(allocator, "U1.4", "OSC_N");
    const groups = [_]PinGroup{
        .{ .display_name = "OSCINP", .pin_numbers = "1", .stub_labels = &.{"OSCINP"}, .stub_pins = &.{"1"}, .conns = &.{.{ .pin = "1", .endpoint = .{ .pin = .{ .ref_des = "C_P", .pin = "2" } } }} },
        .{ .display_name = "OTHER", .pin_numbers = "2", .stub_labels = &.{"OTHER"}, .stub_pins = &.{"2"}, .conns = &.{.{ .pin = "2", .endpoint = .{ .net = "OTHER" } }} },
        .{ .display_name = "OSCINM", .pin_numbers = "4", .stub_labels = &.{"OSCINM"}, .stub_pins = &.{"4"}, .conns = &.{.{ .pin = "4", .endpoint = .{ .pin = .{ .ref_des = "C_N", .pin = "2" } } }} },
    };

    const ordered = try orderFunctionalPinGroups(&ctx, "U1", &groups);
    try std.testing.expectEqualStrings("1", ordered[0].pin_numbers);
    try std.testing.expectEqualStrings("4", ordered[1].pin_numbers);
    try std.testing.expectEqualStrings("2", ordered[2].pin_numbers);
}

// spec: render_html - Functional pin ordering terminates when several pins share one earlier partner
test "functional pin order terminates with two pins related to the same earlier group" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var ctx = RenderCtx.init(allocator);

    // Two spokes land on the same net, so pins 4 and 5 are each "related" to
    // pin 2 — a target sitting more than one slot earlier, which is the
    // backward-move branch. Under the old rewind both took turns moving into
    // the slot after pin 2, displacing each other forever; this test hung
    // rather than failed. Reproduces /schematics/cyclops-analog, which spun a
    // request thread past 39 GB RSS instead of ever rendering.
    for ([_][]const u8{ "R_A", "R_B" }, [_][]const u8{ "4", "5" }) |spoke, hub_pin| {
        try ctx.spoke_set.put(allocator, spoke, {});
        var adj: std.ArrayList(AdjEntry) = .empty;
        try adj.append(allocator, .{ .pin = "1", .endpoint = .{ .pin = .{ .ref_des = "U1", .pin = hub_pin } } });
        try adj.append(allocator, .{ .pin = "2", .endpoint = .{ .net = "NET_T" } });
        try ctx.adjacency.put(allocator, spoke, adj);
    }
    try ctx.pin_canonical_nets.put(allocator, "U1.1", "SIG_P");
    try ctx.pin_canonical_nets.put(allocator, "U1.2", "NET_T");
    try ctx.pin_canonical_nets.put(allocator, "U1.3", "SIG_R");
    try ctx.pin_canonical_nets.put(allocator, "U1.4", "SIG_A");
    try ctx.pin_canonical_nets.put(allocator, "U1.5", "SIG_B");

    const groups = [_]PinGroup{
        .{ .display_name = "P", .pin_numbers = "1", .stub_labels = &.{"P"}, .conns = &.{.{ .pin = "1", .endpoint = .{ .net = "SIG_P" } }} },
        .{ .display_name = "T", .pin_numbers = "2", .stub_labels = &.{"T"}, .conns = &.{.{ .pin = "2", .endpoint = .{ .net = "NET_T" } }} },
        .{ .display_name = "R", .pin_numbers = "3", .stub_labels = &.{"R"}, .conns = &.{.{ .pin = "3", .endpoint = .{ .net = "SIG_R" } }} },
        .{ .display_name = "A", .pin_numbers = "4", .stub_labels = &.{"A"}, .conns = &.{.{ .pin = "4", .endpoint = .{ .pin = .{ .ref_des = "R_A", .pin = "1" } } }} },
        .{ .display_name = "B", .pin_numbers = "5", .stub_labels = &.{"B"}, .conns = &.{.{ .pin = "5", .endpoint = .{ .pin = .{ .ref_des = "R_B", .pin = "1" } } }} },
    };

    const ordered = try orderFunctionalPinGroups(&ctx, "U1", &groups);

    // Both related pins end up beside their shared partner, and every input
    // group survives exactly once — the move must reorder, never duplicate.
    try std.testing.expectEqual(groups.len, ordered.len);
    try std.testing.expectEqualStrings("1", ordered[0].pin_numbers);
    try std.testing.expectEqualStrings("2", ordered[1].pin_numbers);
    try std.testing.expectEqualStrings("5", ordered[2].pin_numbers);
    try std.testing.expectEqualStrings("4", ordered[3].pin_numbers);
    try std.testing.expectEqualStrings("3", ordered[4].pin_numbers);
}

test "loadPinoutNames rejects a top list whose head is not pinout" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "notpinout.sexp", .data = "(notpinout a b)" });
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const path = try std.fmt.allocPrint(arena, "{s}/notpinout.sexp", .{dir});
    // The guard `top.len < 2 or top[0] != "pinout"` bails on any non-pinout head.
    // `or`→`and` only bails when BOTH hold, so a well-formed non-pinout list would
    // parse into a spurious map instead of null.
    try std.testing.expect(loadPinoutNames(arena, path) == null);
}

// spec: Web Server - the schematic page serves an embedded pane variant that drops the navbar, page header, and sidebar
test "the embedded schematic page marks its body for the pane stylesheet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var block = emptyAttachBlock("Demo");
    var checks: CheckResultMap = .empty;
    const full = try renderToHtml(alloc, &block, "", "demo", "", .pass, null, &checks, .{ .path = "/schematics/" });
    const embedded = try renderToHtml(alloc, &block, "", "demo", "", .pass, null, &checks, .{ .path = "/schematics/", .embed = true });

    // One body class is the whole difference: the drawing is untouched, so a
    // board pick lands on exactly the card the full page would scroll to.
    try std.testing.expect(std.mem.indexOf(u8, embedded, "<body data-schematic-view=\"functional\" class=\"sch-embed\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, full, "class=\"sch-embed\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, full, "<body data-schematic-view=\"functional\">") != null);

    // The chrome the host surface already provides is hidden by stylesheet, so
    // the pane never flashes a navbar before dropping it.
    try std.testing.expect(std.mem.indexOf(u8, schematic_css, "body.sch-embed .navbar{display:none;}") != null);
    try std.testing.expect(std.mem.indexOf(u8, schematic_css, "body.sch-embed .sch-head{display:none;}") != null);
    try std.testing.expect(std.mem.indexOf(u8, schematic_css, "body.sch-embed .sch-sidebar{display:none;}") != null);
}

test "design note update failures have an accessible diagnostic panel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var block = emptyAttachBlock("Demo");
    var checks: CheckResultMap = .empty;
    const html = try renderToHtml(allocator, &block, "", "demo", "", .pass, null, &checks, .{ .path = "/schematics/" });

    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"sch-notes-status\" aria-live=\"polite\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"sch-notes-error-details\" hidden") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"sch-notes-error-copy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, schematic_css, ".sch-notes-status.is-actionable") != null);
    try std.testing.expect(std.mem.indexOf(u8, schematic_css, ".sch-notes-error-details pre") != null);
}

// spec: render_html - The schematic page renders no thermal panel, linking out to /thermal/:name instead, so the page reads nothing but the design's own .sexp
test "a review doc with screened thermal parts still renders no thermal panel" {
    const thermal = @import("eval/thermal.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // A part hot enough that the old panel would certainly have drawn a row.
    const parts = [_]thermal.PartThermal{.{ .ref_des = "U5", .component = "buck" }};
    var block = emptyAttachBlock("Demo");
    var checks: CheckResultMap = .empty;
    const doc: review.ReviewDoc = .{
        .design_name = "demo",
        .title = "Demo",
        .generated_at = "2026-08-19T00:00:00Z",
        .summary = std.mem.zeroInit(review.Summary, .{ .status = review.Status.pass }),
        .sections = &.{},
        .power = .{
            .budget = &.{},
            .sequence = &.{},
            .thermal = .{ .ambient_c = 25, .parts = &parts },
        },
        .test_points = &.{},
        .bom = &.{},
        .assertions = &.{},
        .unresolved = &.{},
    };
    const html = try renderToHtml(alloc, &block, "", "demo", "", .pass, doc, &checks, .{ .path = "/schematics/" });

    // Neither the panel nor the sidebar chip that used to scroll to it. The
    // chip mattered as much as the panel: a chip pointing at a section that is
    // no longer emitted scrolls to nowhere.
    try std.testing.expect(std.mem.indexOf(u8, html, "page-thermal") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h2>Thermal</h2>") == null);

    // The nav tab stays — that is where thermal went, and it is the reason
    // dropping the panel loses the reader nothing.
    try std.testing.expect(std.mem.indexOf(u8, html, "<a href=\"/thermal/demo\">Thermal</a>") != null);
}

// spec: render_html - Each sub circuit card links out to its PCB layout in a new tab rather than embedding one, so no sub circuit opens a layout from the schematic page
test "a sub circuit card carries a PCB-layout link and no embedded layout view" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mod = emptyAttachBlock("flash-module");
    const subs = [_]env_mod.SubBlock{.{ .name = "flash", .source = "xspi-flash", .block = &mod }};
    var block = emptyAttachBlock("Demo");
    block.sub_blocks = &subs;
    var checks: CheckResultMap = .empty;

    const html = try renderToHtml(alloc, &block, "", "demo", "", .pass, null, &checks, .{ .path = "/schematics/" });

    // No iframe, no view-swapping tabs, and no global PCB-settings bar that
    // only ever existed to parameterise those iframes. An iframe is the whole
    // point: it pulls a second page — placement solve and sidecar parse — into
    // this one.
    try std.testing.expect(std.mem.indexOf(u8, html, "subc-pcb-frame") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<iframe") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "subc-tab") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "embed=1") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "pcb-globals") == null);

    // Nor the "Module layouts" checklist, which read one .layouts.json per
    // sub-block, nor the sidebar chip that scrolled to it.
    try std.testing.expect(std.mem.indexOf(u8, html, "page-module-layouts") == null);

    // What remains is one link, opening in its own tab.
    try std.testing.expect(std.mem.indexOf(u8, html, "target=\"_blank\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "PCB Layout \u{2197}</a>") != null);
}

// spec: render_html - A sub circuit backed by a reusable module links to that module's own layout editor, and a path- or inline-sourced one to the design-scoped view of its slice
test "the PCB-layout link targets the module for a module sub circuit and the design otherwise" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // A module-sourced sub circuit owns a reusable layout, so it links to the
    // module's own editor — where a save writes lib/modules/<m>.layouts.json
    // and every design instantiating it picks the result up.
    var mod = emptyAttachBlock("flash-module");
    const mod_subs = [_]env_mod.SubBlock{.{ .name = "flash", .source = "xspi-flash", .block = &mod }};
    var mod_block = emptyAttachBlock("Demo");
    mod_block.sub_blocks = &mod_subs;
    var checks: CheckResultMap = .empty;
    const mod_html = try renderToHtml(alloc, &mod_block, "", "demo", "", .pass, null, &checks, .{ .path = "/schematics/" });
    try std.testing.expect(std.mem.indexOf(u8, mod_html, "href=\"/pcb-layout/xspi-flash\"") != null);

    // A path-sourced one has no reusable module, so it falls back to the
    // design-scoped view of just its slice, keyed on the card's slug.
    var inl = emptyAttachBlock("inline-module");
    const inl_subs = [_]env_mod.SubBlock{.{ .name = "Power In", .source = "boards/x/power.sexp", .block = &inl }};
    var inl_block = emptyAttachBlock("Demo");
    inl_block.sub_blocks = &inl_subs;
    const inl_html = try renderToHtml(alloc, &inl_block, "", "demo", "", .pass, null, &checks, .{ .path = "/schematics/" });
    try std.testing.expect(std.mem.indexOf(u8, inl_html, "href=\"/pcb-layout/demo?sub=power-in\"") != null);
}

// spec: Web Server - the schematic page exposes the current board role as a Design type selector on designs but not reusable module pages
test "schematic header exposes design type only for project designs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var block = emptyAttachBlock("Demo");
    block.board.role = .board;
    var checks: CheckResultMap = .empty;
    const design_html = try renderToHtml(allocator, &block, "", "demo", "", .pass, null, &checks, .{ .path = "/schematics/" });
    try std.testing.expect(std.mem.indexOf(u8, design_html, "id=\"board-role-select\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, design_html, "<option value=\"board\" selected>Whole PCB</option>") != null);
    try std.testing.expect(std.mem.indexOf(u8, schematic_viewer_js_asset, "/api/board-role/") != null);

    var module: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer module.deinit();
    try writeHeader(&module.writer, "Mod", "mod", .pass, .{ .path = "/modules/" }, .{}, false);
    try std.testing.expect(std.mem.indexOf(u8, module.written(), "board-role-select") == null);
}

// spec: render_html - Schematic pages expose a URL-backed Sequential and Functional slider with Functional as the default a bare URL renders
test "schematic header switches between sequential and functional views" {
    // A design served at /schematics/ gets a view toggle whose active Schematic
    // tab points back at /schematics/, with a sibling link to /pcb-layout/.
    // No `?view=` on any of them: Functional is what a bare URL renders, so the
    // default page never has to spell its own view out.
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeHeader(&aw.writer, "Demo", "demo", .pass, .{ .path = "/schematics/", .board_role = .board }, .{}, false);
    const html = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"viewtoggle\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"/schematics/demo\">Schematic</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"/pcb-layout/demo\">PCB Layout</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"/pcb-layout/demo?view=3d\">3D</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "/editor/") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"/assembly-debug/demo\">Assembly</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "aria-label=\"Schematic view\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"schematic-mode-label active\">Functional") != null);
    // The slider links the view it is NOT showing, so from the default it is
    // the Sequential link that carries the selector.
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"schematic-mode-slider functional\" href=\"/schematics/demo?view=sequential\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "role=\"switch\" aria-checked=\"true\"") != null);

    // A module served at /modules/ gets the same toggle rooted at /modules/ —
    // the switcher is symmetric across both page kinds. Held on Sequential,
    // every self-link carries `?view=sequential` so a reload stays put.
    var mw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer mw.deinit();
    try writeHeader(&mw.writer, "Mod", "mod", .pass, .{ .path = "/modules/", .view = .original }, .{}, false);
    const mhtml = mw.written();
    try std.testing.expect(std.mem.indexOf(u8, mhtml, "href=\"/modules/mod?view=sequential\">Schematic</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, mhtml, "href=\"/pcb-layout/mod\">PCB Layout</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, mhtml, "href=\"/pcb-layout/mod?view=3d\">3D</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, mhtml, "/editor/") == null);
    try std.testing.expect(std.mem.indexOf(u8, mhtml, "/assembly-debug/") == null);
    try std.testing.expect(std.mem.indexOf(u8, mhtml, "class=\"schematic-mode-slider\" href=\"/modules/mod\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mhtml, "role=\"switch\" aria-checked=\"false\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mhtml, "class=\"schematic-mode-label active\">Sequential") != null);

    // Absent and unrecognised values both land on Functional; only the two
    // names the Sequential link can carry select the label-connected view.
    try std.testing.expectEqual(SchematicView.functional, parseSchematicView(null));
    try std.testing.expectEqual(SchematicView.functional, parseSchematicView("unknown"));
    try std.testing.expectEqual(SchematicView.functional, parseSchematicView("functional"));
    try std.testing.expectEqual(SchematicView.original, parseSchematicView("sequential"));
    try std.testing.expectEqual(SchematicView.original, parseSchematicView("original"));
}

// spec: render_svg - A bridged sub-block port net keeps its wire and net label on the module's own pin
test "a bridged sub-block port net renders its net label" {
    // The cyclops-kband ADAR2001 case. The `tx` module declares an output port
    // TXOUT+; the parent bridges it (`(bridge "" TXOUT+)` ⇒ net-tie
    // TXOUT+ ↔ tx/TXOUT+), and the only pin on the flattened net is the module's
    // own U1.1 — the far end is net-less printed patch copper. The pad must still
    // draw its wire and net label. While the significance sets were keyed on the
    // PRE-rename spelling ("tx/TXOUT+") the test failed, the one-connection group
    // filtered to zero, and the pad drew nothing at all.
    const mod_insts = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "ic", .value = "", .footprint = "", .symbol = "" },
    };
    const out_pins = [_]env_mod.PinRef{.{ .ref_des = "U1", .pin = "1" }};
    const gnd_pins = [_]env_mod.PinRef{.{ .ref_des = "U1", .pin = "2" }};
    const mod_nets = [_]env_mod.Net{
        .{ .name = "TXOUT+", .pins = &out_pins },
        .{ .name = "GND", .pins = &gnd_pins },
    };
    const mod_ports = [_]env_mod.Port{
        .{ .name = "TXOUT+", .net = "TXOUT+", .direction = "out" },
    };
    var mod = emptyAttachBlock("tx-module");
    mod.instances = &mod_insts;
    mod.nets = &mod_nets;
    mod.ports = &mod_ports;

    const subs = [_]env_mod.SubBlock{.{ .name = "tx", .block = &mod }};
    const ties = [_]env_mod.NetTie{
        .{ .a = "TXOUT+", .b = "tx/TXOUT+" },
        .{ .a = "GND", .b = "tx/GND" },
    };
    var block = emptyAttachBlock("bridged-port-test");
    block.sub_blocks = &subs;
    block.net_ties = &ties;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try setupRenderCtx(a, &block);

    // The flattened net carries the parent's spelling, so the single-pin escape
    // must be keyed on it.
    try std.testing.expect(ctx.rendersWhenAlone("TXOUT+"));

    var buf: std.Io.Writer.Allocating = .init(a);
    try std.testing.expect(try renderHubSvg(&ctx, &buf.writer, a, &.{}, "U1"));
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), ">TXOUT+</text>") != null);
}

// spec: render_svg - A bridged sub-block port net renders its label without being coloured or flagged a board-boundary port
test "a bridged sub-block port net is not a boundary port" {
    // Same fixture as above. Calling the RESOLVED (parent-side) spelling a
    // BOUNDARY port fixed the missing label but repainted every bridged internal
    // net in the boundary-port blue and set its scene-graph `port` flag — stm32n6
    // went from 53 to 288 blue labels, recolouring ordinary internal nets like
    // ADC1_CS as board boundaries. The two roles are separate now: the label
    // renders, in the internal colour, with the port flag clear.
    const mod_insts = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "ic", .value = "", .footprint = "", .symbol = "" },
    };
    const out_pins = [_]env_mod.PinRef{.{ .ref_des = "U1", .pin = "1" }};
    const gnd_pins = [_]env_mod.PinRef{.{ .ref_des = "U1", .pin = "2" }};
    const mod_nets = [_]env_mod.Net{
        .{ .name = "TXOUT+", .pins = &out_pins },
        .{ .name = "GND", .pins = &gnd_pins },
    };
    const mod_ports = [_]env_mod.Port{
        .{ .name = "TXOUT+", .net = "TXOUT+", .direction = "out" },
    };
    var mod = emptyAttachBlock("tx-module");
    mod.instances = &mod_insts;
    mod.nets = &mod_nets;
    mod.ports = &mod_ports;

    const subs = [_]env_mod.SubBlock{.{ .name = "tx", .block = &mod }};
    const ties = [_]env_mod.NetTie{
        .{ .a = "TXOUT+", .b = "tx/TXOUT+" },
        .{ .a = "GND", .b = "tx/GND" },
    };
    var block = emptyAttachBlock("bridged-port-colour-test");
    block.sub_blocks = &subs;
    block.net_ties = &ties;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try setupRenderCtx(a, &block);

    // The parent-side spelling is internal wiring, not a declared boundary: the
    // parent block has no (port …) of its own.
    try std.testing.expect(!ctx.isBoundaryPort("TXOUT+"));
    try std.testing.expect(ctx.rendersWhenAlone("TXOUT+"));

    var buf: std.Io.Writer.Allocating = .init(a);
    try std.testing.expect(try renderHubSvg(&ctx, &buf.writer, a, &.{}, "U1"));
    const label = std.mem.indexOf(u8, buf.written(), ">TXOUT+</text>").?;
    // The label's own <text> opener carries the internal-net fill, never the
    // boundary-port blue.
    const open = std.mem.lastIndexOf(u8, buf.written()[0..label], "<text ").?;
    const tag = buf.written()[open..label];
    try std.testing.expect(std.mem.indexOf(u8, tag, "#e8c547") != null);
    try std.testing.expect(std.mem.indexOf(u8, tag, "#4a9eff") == null);
}

// spec: render_html - The schematic page escapes the design name everywhere it appears — document title, heading, subtitle filename — and escapes each hub card's ref-des into its data-ref attribute
test "the schematic page escapes the design name and every hub ref-des it renders" {
    // JUL-S7's render_html half. The render_json half has had a test since the
    // July fix (`serializeScene escapes a quote/backslash in the design name`);
    // this side was fixed at the same time and never covered, which left the
    // ledger recording the finding as only half guarded. Design names come
    // from .sexp files that arrive by import, upload and MCP write_file, and
    // ref-des values ride along with them.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const hostile = "</title><svg onload=alert(1)>\"'&";
    var block = emptyAttachBlock(hostile);
    var checks: CheckResultMap = .empty;
    const html = try renderToHtml(alloc, &block, "", "demo", "", .pass, null, &checks, .{ .path = "/schematics/" });

    // RCDATA breakout: `</title>` closing the element early is the whole
    // attack, and it must not survive anywhere on the page.
    try std.testing.expect(std.mem.indexOf(u8, html, "</title><svg") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<svg onload") == null);
    // Present in escaped form, so the absence above is escaping, not dropping.
    try std.testing.expect(std.mem.indexOf(u8, html, "&lt;/title&gt;&lt;svg onload=alert(1)&gt;&quot;&#39;&amp;") != null);
    // The name reaches the document title and the H1 by two different paths.
    try std.testing.expect(std.mem.indexOf(u8, html, "<title>&lt;/title&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h1>&lt;/title&gt;") != null);

    // The header's own two sinks, driven directly: the title in RCDATA and the
    // design name in the `<code>…​.sexp</code>` subtitle.
    var head: std.Io.Writer.Allocating = .init(alloc);
    try writeHeader(&head.writer, hostile, "de\"mo<x>", .pass, .{ .path = "/schematics/" }, .{}, false);
    try std.testing.expect(std.mem.indexOf(u8, head.written(), "<svg onload") == null);
    try std.testing.expect(std.mem.indexOf(u8, head.written(), "de&quot;mo&lt;x&gt;.sexp") != null);
    // …and the URL-encoded sink beside it, where escaping is not the right
    // answer and percent-encoding is.
    try std.testing.expect(std.mem.indexOf(u8, head.written(), "de%22mo%3Cx%3E") != null);

    // data-ref: an attribute context, so a bare `"` is a breakout with no
    // angle bracket needed. Hub cards key their editor hooks off this.
    const hub_instances = [_]env_mod.Instance{.{
        .ref_des = "U\" onmouseover=alert(1) x=\"",
        .component = "mcu",
        .value = "",
        .footprint = "qfn-32",
        .symbol = "generic",
    }};
    var hub_block = emptyAttachBlock("Board");
    hub_block.instances = &hub_instances;
    const hub_html = try renderToHtml(alloc, &hub_block, "", "demo", "", .pass, null, &checks, .{ .path = "/schematics/" });
    // The payload TEXT survives escaping — only the quote that would close the
    // attribute is neutralized, so that is what the assertion has to be about.
    try std.testing.expect(std.mem.indexOf(u8, hub_html, "U\" onmouseover") == null);
    try std.testing.expect(std.mem.indexOf(u8, hub_html, "data-ref=\"U&quot; onmouseover=alert(1) x=&quot;\"") != null);
}
