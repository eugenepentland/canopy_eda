const std = @import("std");
const env_mod = @import("eval/env.zig");
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
const draw = @import("render_svg/draw.zig");
const section_inset = @import("render_svg/section_inset.zig");
const block_diagram = @import("diagram/diagram.zig");
const membership = @import("diagram/membership.zig");
const rb = @import("render_block_types.zig");
const bom_html = @import("serve/bom_html.zig");
const pages_tmpl = @import("serve/templates/pages.zig");
const layout_status = @import("layout_status.zig");
const isHub = draw.isHub;
const pinOrder = draw.pinOrder;

const MUTED_EM_DASH = review_html.mutedDash;

// Shared table-row HTML fragments — reused across the port tables and the
// module-layout checklist so the literals aren't duplicated (guardian's
// repeated-string-literal check).
const ROW_TD_CODE_OPEN = "<tr><td><code>";
const TD_CELL_SEP = "</td><td>";
const ROW_TD_CLOSE = "</td></tr>";
const TABLE_DETAILS_CLOSE = "</tbody></table></details>";
const PILL_WARN = "pill-warn";

const Allocator = std.mem.Allocator;

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
    // Route prefix for *this* schematic view ("/schematics/" for designs,
    // "/modules/" for reusable modules). Drives the active link in the
    // Schematic ⇄ PCB Layout switcher; the PCB side is always "/pcb-layout/".
    schematic_path: []const u8,
) RenderError![]const u8 {
    var ctx = try setupRenderCtx(allocator, block);
    ctx.project_dir = project_dir;

    var asserted_fns = try asserted_fns_mod.buildMap(allocator, block);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    const w = &aw.writer;

    try w.writeAll("<!DOCTYPE html><html><head><meta charset=\"utf-8\">");
    try w.writeAll("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">");
    try w.print("<title>{s} — Schematic</title>", .{block.name});
    try w.writeAll("<link rel=\"stylesheet\" href=\"/static/codemirror.css\">");
    try w.writeAll("<link rel=\"stylesheet\" href=\"/static/schematic.css\">");
    try w.writeAll("<style>");
    try w.writeAll(navbar_css);
    if (review_doc != null) try w.writeAll(review_html.BODY_CSS);
    try w.writeAll("</style></head><body>");

    try pages_tmpl.Navbar.render(.{""}, w);
    try w.writeAll("<div class=\"sch-layout\">");
    try w.writeAll("<div class=\"sch-wrap\">");
    try writeHeader(w, block.name, design_name, status, schematic_path, block.revision, block.kicad_pcb_path != null);

    // Global PCB-layout controls (via/trace/DRC) that feed every per-sub-block
    // preview below. Shown only when the design has sub-blocks to preview — the
    // whole-design layout is deliberately never computed from this page.
    if (block.sub_blocks.len > 0) try writePcbGlobals(w);

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
        if (doc.traceability.rows.len > 0) {
            try w.writeAll("<div id=\"page-traceability\" class=\"page-anchor\">");
            try review_html.writeTraceability(w, doc.traceability);
            try w.writeAll("</div>");
        }
        if (doc.power_sequence.len > 0) {
            try w.writeAll("<div id=\"page-power-sequence\" class=\"page-anchor\">");
            try review_html.writePowerSequence(w, doc.power_sequence);
            try w.writeAll("</div>");
        }
        if (doc.test_points.len > 0) {
            try w.writeAll("<div id=\"page-test-points\" class=\"page-anchor\">");
            try review_html.writeTestPoints(w, doc.test_points);
            try w.writeAll("</div>");
        }
        if (doc.power_budget.len > 0) {
            try w.writeAll("<div id=\"page-power-budget\" class=\"page-anchor\">");
            try review_html.writePowerBudget(w, doc.power_budget);
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

    // Module-layout checklist — one row per top-level (sub-block …) flagging
    // whether its module carries a (placement …) spec yet. Surfaced so the
    // author can confirm every sub-module is laid out before a KiCad hand-off.
    // Only meaningful when the design actually instantiates modules.
    if (block.sub_blocks.len > 0) try writeModuleLayoutStatus(allocator, project_dir, w, block);

    // Design notes — structured TODO list backed by `<design>.notes.md`.
    // The task list + add form drive /api/notes/:name/tasks/*; the
    // scratchpad textarea round-trips through the raw /api/notes/:name
    // endpoint and holds anything that isn't a checkbox-format task.
    // Same file backs the MCP `add_design_note`/`complete_design_note`
    // tools so agents and humans share state.
    try w.writeAll(
        \\<details id="page-notes" class="sch-notes-card page-anchor">
        \\<summary>Design Notes <span class="sch-card-sub muted" id="sch-notes-count"></span></summary>
        \\<div class="sch-notes-body">
        \\<p class="sch-notes-hint muted">Log ERC errors and follow-ups for the next revision. Saved to
        \\<code>&lt;design&gt;.notes.md</code>; same store as the MCP <code>add_design_note</code> tool.</p>
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
        \\</div>
        \\</details>
    );

    for (block.sections, 0..) |sec, sec_idx| {
        var attached: std.ArrayListUnmanaged(env_mod.SubBlock) = .empty;
        defer attached.deinit(allocator);
        for (block.sub_blocks, 0..) |sb, sb_idx| {
            if (sub_attachments[sb_idx]) |idx| {
                if (idx == sec_idx) try attached.append(allocator, sb);
            }
        }
        try writeSection(&ctx, w, allocator, block, sec, 0, check_results, attached.items);
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
        var group_names: std.ArrayListUnmanaged(u8) = .empty;
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
        try writeSubBlockCard(&ctx, w, allocator, sb, check_results, .standalone, group);
    }

    if (block.sections.len == 0 and hasTopLevelHubs(block)) {
        try writeFlatHubs(&ctx, w, allocator, block, check_results);
    }

    // ERC violations and assertions no longer render at the bottom of the
    // page — they surface in the sidebar via the ERC button (which now also
    // lists the design's assertions). Keeps the page tail clean.

    try w.writeAll("</div>");
    try writeSidebar(w, review_doc, block.sub_blocks.len > 0);
    try w.writeAll("</div>");
    try writeScripts(w, allocator, design_name, block, &ctx, &asserted_fns, check_results, review_doc, schematic_path);
    // Per-sub-circuit Schematic ⇄ PCB toggle wiring — reuses the DESIGN_NAME
    // global declared by writeScripts, so it must follow that call. Only emitted
    // when there are sub circuits (matching the global PCB-settings bar above).
    if (block.sub_blocks.len > 0) try w.writeAll(SUBC_TOGGLE_SCRIPT);
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

fn writeHeader(
    w: anytype,
    title: []const u8,
    design_name: []const u8,
    status: review.Status,
    schematic_path: []const u8,
    revision: env_mod.Revision,
    has_kicad_pcb: bool,
) !void {
    // `schematic_path` is "/modules/" for a reusable module, "/schematics/" for
    // a full design. Modules get the Schematic ⇄ PCB Layout switcher (small
    // enough that the whole-block PCB layout is fast and useful); full designs
    // intentionally omit it — see the head-links comment below.
    const is_module = std.mem.eql(u8, schematic_path, "/modules/");
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
    // A module gets the Schematic ⇄ PCB Layout switcher (the PCB layout page
    // links back here), so the two views toggle symmetrically.
    if (is_module) {
        try w.print(
            "<nav class=\"viewtoggle\" aria-label=\"View\">" ++
                "<a class=\"active\" href=\"/modules/{s}\">Schematic</a>" ++
                "<a href=\"/pcb-layout/{s}\">PCB Layout</a></nav>",
            .{ design_name, design_name },
        );
    }
    // For a full design the whole-design PCB layout is intentionally not linked
    // from here: it places every component at once, which is too slow to be
    // useful. Instead each sub circuit shows its own PCB layout on demand via the
    // card's Schematic ⇄ PCB toggle — see the global "PCB Layout settings" bar
    // (writePcbGlobals) and the per-sub-circuit PCB view (writeSubCircuitPcb).
    try w.writeAll(
        "<button class=\"head-link head-btn\" id=\"reload-btn\" type=\"button\" " ++
            "title=\"Re-read the .sexp source from disk and rebuild\">\u{21BB} Reload</button>",
    );
    try w.writeAll(
        "<button class=\"head-link head-btn\" id=\"copy-src-btn\" type=\"button\" " ++
            "title=\"Download the raw .sexp source file\">\u{2B07} Export SRC</button>",
    );
    try w.writeAll("<button class=\"head-link head-btn\" id=\"erc-btn\" type=\"button\">ERC</button>");
    // Version history (designs only — module sources aren't snapshotted):
    // opens the sidebar History panel listing stored snapshots, each with a
    // "Diff vs current" action backed by GET /api/diff/:name.
    if (!is_module) {
        try w.writeAll(
            "<button class=\"head-link head-btn\" id=\"history-btn\" type=\"button\" " ++
                "title=\"Stored versions (snapshotted on every save/build) with diff vs current\">History</button>",
        );
    }
    // File-based KiCad-sync freshness chip — only for designs that declare a
    // (kicad-pcb "<path>") target. The schematic_viewer.js dry-runs the sync
    // on page load and recolours this: green when the .kicad_pcb already
    // matches the netlist, amber + a pending-op count when a Push would write
    // the board, grey when the board file can't be read. Click re-checks.
    if (has_kicad_pcb) {
        try w.writeAll(
            "<button class=\"head-link head-btn sync-chip\" id=\"kicad-sync-chip\" type=\"button\" " ++
                "title=\"Checking whether the .kicad_pcb matches the design\u{2026}\">\u{27F3} PCB sync\u{2026}</button>",
        );
    }
    // Single file-based PCB sync button — writes directly to the .kicad_pcb
    // declared by the design's (kicad-pcb "<path>") form. It runs the full
    // sync (prune stale footprints + refresh footprint geometry — ?prune=1
    // &refresh=1) behind the dry-run preview modal, so the user sees and
    // confirms every change before the board is written. pcbnew either auto-
    // prompts to reload (KiCad 8+) or surfaces it via File → Revert (KiCad 7).
    // The button is wired generically; if the design has no (kicad-pcb …) form
    // the server returns a clear 400 + message which the JS handler surfaces
    // as a toast.
    try w.writeAll(
        "<button class=\"head-link head-btn\" id=\"push-kicad-pcb-btn\" type=\"button\" " ++
            "title=\"Sync the design to the .kicad_pcb declared by (kicad-pcb \u{2026}): adds/updates parts, " ++
            "deletes stale footprints, and refreshes footprint geometry. Shows a preview to confirm first; " ++
            "pcbnew will prompt to reload, or use File \u{2192} Revert\">" ++
            "\u{2192} Push to KiCad PCB</button>",
    );
    try w.print("<a class=\"head-link\" href=\"/api/export-bom/{s}\">BOM</a>", .{design_name});
    try w.print("<a class=\"head-link\" href=\"/api/export-netlist/{s}\">Netlist</a>", .{design_name});
    try w.print(
        "<a class=\"head-link head-btn\" href=\"/api/export-review/{s}\" " ++
            "title=\"Download a self-contained design-review package (markdown + BOM CSV) as a zip\">" ++
            "📦 Export Review</a>",
        .{design_name},
    );
    // Global PDF upload: any datasheet, chosen by filename, lands in
    // lib/datasheets/. Users then wire one up by editing a component file's
    // `(datasheet "foo.pdf")` field. Keeps upload one-click without
    // committing to a specific part.
    try w.writeAll(
        "<label class=\"head-link head-btn\" style=\"cursor:pointer\">" ++
            "📄 Upload PDF" ++
            "<input type=\"file\" accept=\"application/pdf\" id=\"global-ds-upload\" hidden>" ++
            "</label>",
    );
    try w.writeAll("<span id=\"global-ds-status\" class=\"head-link\" style=\"color:#8b949e\"></span>");
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
    out: *std.ArrayListUnmanaged([]const u8),
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
fn writeSidebar(w: anytype, review_doc: ?review.ReviewDoc, has_modules: bool) !void {
    try w.writeAll("<aside class=\"sch-sidebar\" id=\"sch-sidebar\">");
    try w.writeAll("<nav class=\"sb-toc\" aria-label=\"Page contents\">");
    try writeTocChip(w, "page-block-diagram", "Block diagram");
    if (review_doc) |doc| {
        if (doc.traceability.rows.len > 0) try writeTocChip(w, "page-traceability", "Traceability");
        if (doc.power_sequence.len > 0) try writeTocChip(w, "page-power-sequence", "Power sequencing");
        if (doc.test_points.len > 0) try writeTocChip(w, "page-test-points", "Test points");
        if (doc.power_budget.len > 0) try writeTocChip(w, "page-power-budget", "Power budget");
    }
    try writeTocChip(w, "page-bom", "BOM");
    if (has_modules) try writeTocChip(w, "page-module-layouts", "Module layouts");
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
    return ctx;
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
    if (try analyzeHub(ctx, allocator, pin_groups, hub_ref)) |a| {
        try renderGroupedHubSvgs(ctx, w, allocator, a);
        return true;
    }
    return false;
}

/// CSS subset for static SVG exports — strips hover/click states (no JS in
/// a markdown viewer) but keeps the visual identity (component box colors,
/// pin label fonts, net stroke colors). Embed once at the top of an
/// exported document; per-hub SVGs reference these classes.
pub const STATIC_SVG_CSS =
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
    ctx: *RenderCtx,
    w: anytype,
    allocator: Allocator,
    block: *const DesignBlock,
    sec: Section,
    depth: u8,
    check_results: *const CheckResultMap,
    attached_subs: []const env_mod.SubBlock,
) !void {
    const indent_class: []const u8 = if (depth == 0) "sch-section" else "sch-section sch-subsection";
    const slug = try review.slugify(allocator, sec.name);
    try w.print("<section class=\"{s}\" id=\"sec-{s}\" data-slug=\"{s}\">", .{ indent_class, slug, slug });

    // Header
    const status_pill: []const u8 = switch (sec.status) {
        .concept => "pill-concept",
        .implemented => "pill-ok",
        .review => PILL_WARN,
    };
    try w.writeAll("<div class=\"sec-head\"><h2>");
    try writeHtmlEscaped(w, sec.name);
    try w.print("</h2><span class=\"pill {s}\">{s}</span>", .{ status_pill, @tagName(sec.status) });
    const sec_cov = try coverage.computeSectionCoverage(allocator, block, sec, check_results);
    if (sec_cov.checked > 0) {
        const cov_class: []const u8 = if (sec_cov.complete == sec_cov.checked) "pill-pass" else PILL_WARN;
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
    var hub_refs: std.ArrayListUnmanaged([]const u8) = .empty;
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

    try writeSectionHubs(ctx, w, allocator, sec.pin_groups, hub_refs.items, check_results);

    for (sec.sub_sections) |sub| try writeSection(ctx, w, allocator, block, sub, depth + 1, check_results, &.{});

    for (attached_subs) |sb| try writeSubBlockCard(ctx, w, allocator, sb, check_results, .attached, null);

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
        if (try analyzeHub(ctx, allocator, pin_groups, hub_ref)) |a| {
            if (a.inst.requirements.len > 0) {
                try w.print("<div class=\"sec-hub-reqs\" data-ref=\"{s}\"><h4 class=\"sec-hub-reqs-head\"><code>", .{a.inst.ref_des});
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
    ctx: *RenderCtx,
    w: anytype,
    allocator: Allocator,
    pin_groups: []const env_mod.PinGroup,
    hub_refs: []const []const u8,
    check_results: *const CheckResultMap,
) !void {
    for (hub_refs) |hub_ref| {
        if (try analyzeHub(ctx, allocator, pin_groups, hub_ref)) |a| {
            try writeHubCard(ctx, w, allocator, a, check_results);
        }
    }
}

fn writeHubCard(ctx: *RenderCtx, w: anytype, allocator: Allocator, h: HubAnalysis, check_results: *const CheckResultMap) !void {
    try w.print("<div class=\"sch-hub\" data-ref=\"{s}\">", .{h.inst.ref_des});
    try w.writeAll("<div class=\"hub-head\"><h3><code>");
    try writeHtmlEscaped(w, h.inst.ref_des);
    try w.writeAll("</code></h3><span class=\"hub-comp\">");
    try writeHtmlEscaped(w, h.inst.component);
    try w.writeAll("</span>");
    if (h.inst.value.len > 0) {
        try w.writeAll("<span class=\"hub-val\">");
        try writeHtmlEscaped(w, h.inst.value);
        try w.writeAll("</span>");
    }
    try w.writeAll("</div>");
    try w.writeAll("<div class=\"hub-inset-wrap\">");
    try renderGroupedHubSvgs(ctx, w, allocator, h);
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
    ctx: *RenderCtx,
    w: anytype,
    allocator: Allocator,
    h: HubAnalysis,
) !void {
    var buckets: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(PinGroup)) = .empty;
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
        try section_inset.renderHubAllPins(ctx, w, h.inst, h.groups);
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
        try section_inset.renderHubAllPins(ctx, w, h.inst, subset);
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

/// Parse `lib/pinouts/<x>.sexp` into a pin_id -> function-name map. Mirrors the
/// evaluator's loader (numeric pin ids stringify to "5", "11", …); ERC's loader
/// only handles atom/string ids and so drops every numeric pin.
fn loadPinoutNames(allocator: Allocator, path: []const u8) ?std.StringHashMapUnmanaged([]const u8) {
    const content = infra_fs.cwd().readFileAlloc(allocator, path, 1 << 18) catch return null;
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

/// Pin identifier as a string: bare number -> "5", atom/string -> itself.
fn pinIdStr(allocator: Allocator, node: ast.Node) ?[]const u8 {
    if (node.asNumber()) |n| {
        const i: i64 = @intFromFloat(n);
        return std.fmt.allocPrint(allocator, "{d}", .{i}) catch null;
    }
    return node.asAtom() orelse node.asString();
}

fn analyzeHub(
    ctx: *RenderCtx,
    allocator: Allocator,
    pin_groups: []const env_mod.PinGroup,
    hub_ref: []const u8,
) !?HubAnalysis {
    const hub_inst = ctx.inst_map.get(hub_ref) orelse return null;
    // Test points get a dedicated table at the top of the page; they don't
    // need their own per-section schematic card cluttering the layout.
    if (std.mem.eql(u8, hub_inst.component, "testpoint") or
        std.mem.startsWith(u8, hub_inst.component, "testpoint-")) return null;

    // Bucket pin_ids by `(pins ref (group "X") ...)` feature label so each
    // bucket can render as its own SVG with the label as a heading.
    var buckets: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty;
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

    var all_groups: std.ArrayListUnmanaged(PinGroup) = .empty;
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
        const hub_pg = try hub_mod.groupHubPins(ctx, pins, adj_entries, &pn_map);
        for (hub_pg) |g| {
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

fn writeSectionPorts(w: anytype, sec: Section) !void {
    if (sec.ports.len == 0) return;
    try w.print(
        "<details class=\"sec-ports\"><summary>Ports · {d}</summary>",
        .{sec.ports.len},
    );
    try w.writeAll("<table class=\"ports\"><thead><tr><th>Port</th><th>Dir</th><th>Type</th><th>Voltage</th><th>Role/Protocol</th></tr></thead><tbody>");
    for (sec.ports) |p| {
        try w.writeAll(ROW_TD_CODE_OPEN);
        try writeHtmlEscaped(w, p.name);
        try w.print("</code></td><td>{s}</td><td>{s}</td><td>", .{ @tagName(p.direction), @tagName(p.signal_type) });
        if (p.voltage) |v| try w.print("{d}V", .{v}) else try w.writeAll(MUTED_EM_DASH);
        try w.writeAll(TD_CELL_SEP);
        if (p.protocol.len > 0) {
            try w.writeAll("<code>");
            try writeHtmlEscaped(w, p.protocol);
            try w.writeAll("</code>");
        }
        if (p.role.len > 0) {
            if (p.protocol.len > 0) try w.writeAll(" · ");
            try writeHtmlEscaped(w, p.role);
        }
        if (p.protocol.len == 0 and p.role.len == 0) try w.writeAll(MUTED_EM_DASH);
        try w.writeAll(ROW_TD_CLOSE);
    }
    try w.writeAll(TABLE_DETAILS_CLOSE);
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
        try w.writeAll(ROW_TD_CODE_OPEN);
        try writeHtmlEscaped(w, p.name);
        try w.print("</code></td><td>{s}</td><td>", .{@tagName(p.direction)});
        if (e.electrical_type) |t| {
            try writeHtmlEscaped(w, @tagName(t));
        } else {
            try w.writeAll(MUTED_EM_DASH);
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
            try w.writeAll(MUTED_EM_DASH);
        }
        try w.writeAll(TD_CELL_SEP);
        if (e.domain.len > 0) {
            try writeHtmlEscaped(w, e.domain);
        } else {
            try w.writeAll(MUTED_EM_DASH);
        }
        try w.writeAll(ROW_TD_CLOSE);
    }
    try w.writeAll(TABLE_DETAILS_CLOSE);
}

fn writeContractVoltCell(w: anytype, v: ?f64) !void {
    try w.writeAll("<td>");
    if (v) |x| {
        try w.print("{d:.2}", .{x});
    } else {
        try w.writeAll(MUTED_EM_DASH);
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
fn sameSubBlockShape(a: env_mod.SubBlock, b: env_mod.SubBlock) bool {
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
    ctx: *RenderCtx,
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
    // text via /api/module-source) plus the Schematic ⇄ PCB Layout toggle. The
    // toggle flips this card's body between the schematic hubs and an on-demand
    // PCB-layout iframe (see writeSubCircuitPcb / SUBC_TOGGLE_SCRIPT) — replacing
    // the old open-in-new-tab links so the layout can be viewed, edited, roughed
    // and saved without leaving the schematic page.
    try w.writeAll("<div class=\"subc-head-actions\">");
    if (sb.source.len > 0) {
        try w.writeAll("<button type=\"button\" class=\"copy-src-btn\" data-src=\"");
        try writeHtmlEscaped(w, sb.source);
        try w.writeAll("\">Copy source</button>");
    }
    try w.writeAll("<div class=\"subc-toggle\" role=\"group\" aria-label=\"View\">");
    try w.writeAll("<button type=\"button\" class=\"subc-tab active\" data-subc-view=\"sch\">Schematic</button>");
    try w.writeAll("<button type=\"button\" class=\"subc-tab\" data-subc-view=\"pcb\">PCB Layout</button>");
    try w.writeAll("</div>"); // .subc-toggle
    try w.writeAll("</div>"); // .subc-head-actions
    try w.writeAll("</div>"); // .sec-head
    try w.writeAll(secDescOpen);
    try writeHtmlEscaped(w, sb.block.name);
    try w.writeAll("</p>");

    var hub_refs: std.ArrayListUnmanaged([]const u8) = .empty;
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
    var sb_pin_groups: std.ArrayListUnmanaged(env_mod.PinGroup) = .empty;
    defer sb_pin_groups.deinit(allocator);
    for (sb.block.sections) |sec| {
        for (sec.pin_groups) |pg| try sb_pin_groups.append(allocator, pg);
        for (sec.sub_sections) |sub_sec| {
            for (sub_sec.pin_groups) |pg| try sb_pin_groups.append(allocator, pg);
        }
    }

    // The card body is two stacked views the header toggle flips between. The
    // schematic hubs are the default; the PCB view loads its iframe on demand.
    try w.writeAll("<div class=\"subc-view subc-sch\">");
    try writeSectionHubs(ctx, w, allocator, sb_pin_groups.items, hub_refs.items, check_results);
    try w.writeAll("</div>");

    // PCB-layout view (hidden until the toggle selects it). A module sub circuit
    // gets the *editable* embed of its own layout (?embed=1&edit=1 — drag, Rough,
    // Save, ★ all write the module's lib/modules/<m>.layouts.json), so the user
    // can lay it out / rough it right here. A path- or inline-sourced sub circuit
    // has no reusable module layout, so it falls back to the read-only
    // design-scoped preview (?sub=<slug>). Wired by SUBC_TOGGLE_SCRIPT.
    try writeSubCircuitPcb(w, slug, sb);

    try w.writeAll(switch (mode) {
        .standalone => sectionClose,
        .attached => "</div>",
    });
}

/// Global PCB-layout controls shared by every sub circuit's inline PCB view. The
/// whole-design layout is intentionally not offered (it places every component
/// at once, which is too slow to be useful); each `(sub-block …)` card loads its
/// own PCB iframe on demand using these via/clearance/DRC values. The number
/// inputs mirror the standalone PCB page's Route panel defaults
/// (router.RouteParams). Read by SUBC_TOGGLE_SCRIPT when building each iframe URL.
fn writePcbGlobals(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\<details class="pcb-globals" id="page-pcb-globals">
        \\<summary>PCB Layout settings <span class="sch-card-sub muted">via / trace / DRC — used by each sub circuit's PCB view</span></summary>
        \\<div class="pcb-globals-body">
        \\<label>Track <input id="g-tw" type="number" step="0.05" min="0.05" value="0.127"></label>
        \\<label>Clearance <input id="g-cl" type="number" step="0.05" min="0.05" value="0.127"></label>
        \\<label>Via drill <input id="g-vd" type="number" step="0.05" min="0.1" value="0.2"></label>
        \\<label>Via &Oslash; <input id="g-va" type="number" step="0.05" min="0.2" value="0.4"></label>
        \\<label class="pcb-globals-chk"><input id="g-clr-show" type="checkbox"> show clearance</label>
        \\<label class="pcb-globals-chk"><input id="g-drc-show" type="checkbox" checked> show DRC</label>
        \\<span class="pcb-globals-hint muted">Switch a sub circuit to its &ldquo;PCB Layout&rdquo;
        \\view to lay it out. Changing a value here applies the next time a PCB view loads.</span>
        \\</div>
        \\</details>
    );
}

/// The PCB-layout view of a sub circuit card — the toggle's "PCB Layout" panel.
/// A lazily-loaded iframe (no `src` until the toggle first selects PCB, so
/// nothing is placed on page load) plus a one-line hint and an "open full editor"
/// escape hatch. `data-mod` is the sub circuit's module name (empty for
/// path-/inline-sourced ones) and `data-sub` its slug; SUBC_TOGGLE_SCRIPT reads
/// both to build the editable-module vs. read-only-preview iframe URL.
fn writeSubCircuitPcb(w: *std.Io.Writer, slug: []const u8, sb: env_mod.SubBlock) !void {
    const mod_name = moduleSourceName(sb) orelse "";
    // `slug` is review.slugify output ([a-z0-9-]) — safe in an attribute and a
    // URL component without further escaping.
    try w.writeAll("<div class=\"subc-view subc-pcb\" hidden data-sub=\"");
    try w.writeAll(slug);
    try w.writeAll("\" data-mod=\"");
    try writeHtmlEscaped(w, mod_name);
    try w.writeAll("\"><div class=\"subc-pcb-bar\">");
    const hint_mid = " drag to arrange, <b>Rough</b> for a clustered start, " ++
        "then ★ a saved layout to bless it. ";
    if (mod_name.len > 0) {
        try w.writeAll("<span class=\"subc-pcb-hint muted\">Editing <b>");
        try writeHtmlEscaped(w, mod_name);
        try w.writeAll("</b> —" ++ hint_mid ++
            "Saved into the module, so every design using it picks it up.</span>");
    } else {
        try w.writeAll("<span class=\"subc-pcb-hint muted\">Lay it out:" ++ hint_mid ++
            "Saved with this design.</span>");
    }
    try w.writeAll("<a class=\"subc-pcb-open view-src-link\" target=\"_blank\" rel=\"noopener\" href=\"#\">Open full editor \u{2197}</a>");
    try w.writeAll("</div><div class=\"subc-pcb-frame-wrap\">");
    try w.writeAll("<iframe class=\"subc-pcb-frame\" title=\"PCB layout\" loading=\"lazy\"></iframe>");
    try w.writeAll("</div>"); // .subc-pcb-frame-wrap
    try w.writeAll("</div>"); // .subc-pcb
}

/// "Module layouts" checklist panel — one row per top-level `(sub-block …)`,
/// tracking each sub-module through the placement workflow: AI authors the
/// grouping in the DSL, seeds a **Rough** placement (`?rough=1`), and a human
/// hand-finishes it and **stars** the result (the `/pcb-layout` panel's ★ — the
/// "done" marker). The Rough/Starred columns read each module's
/// `<module>.layouts.json` sidecar (`layout_status`). The `<summary>` shows the
/// starred tally even when collapsed and the card opens itself when a sub-module
/// still lacks a starred layout. A `(reflow)` sub-block is intentionally re-flowed
/// by the parent and so doesn't count as missing.
/// Caller guards on `block.sub_blocks.len > 0`.
fn writeModuleLayoutStatus(allocator: Allocator, project_dir: []const u8, w: *std.Io.Writer, block: *const DesignBlock) !void {
    // One sidecar read per sub-block, reused by both the summary tally and the
    // per-row chips. A non-module sub-block (path source / inline block) has no
    // resolvable sidecar, so its status stays all-false and reads as "—".
    const statuses = try allocator.alloc(layout_status.ModuleLayoutStatus, block.sub_blocks.len);
    defer allocator.free(statuses);
    var have: usize = 0;
    var missing: usize = 0;
    var rough_n: usize = 0;
    for (block.sub_blocks, statuses) |sb, *st| {
        st.* = if (moduleSourceName(sb)) |m| layout_status.read(allocator, project_dir, m) else .{};
        if (st.rough) rough_n += 1;
        if (st.starred) {
            have += 1;
        } else if (!sb.reflow) {
            missing += 1;
        }
    }
    const total = block.sub_blocks.len;
    const summary_pill: []const u8 = if (missing == 0) "pill-ok" else PILL_WARN;

    try w.print(
        "<details id=\"page-module-layouts\" class=\"sch-bom-card page-anchor\"{s}>",
        .{if (missing > 0) " open" else ""},
    );
    try w.print(
        "<summary>Module layouts <span class=\"pill {s}\">{d}/{d} starred</span>",
        .{ summary_pill, have, total },
    );
    try w.print(
        "<span class=\"sch-card-sub muted\">{d} rough · {d} starred</span>",
        .{ rough_n, have },
    );
    if (missing > 0) {
        try w.print(
            "<span class=\"sch-card-sub muted\">{d} sub circuit{s} still need a starred layout</span>",
            .{ missing, if (missing == 1) "" else "s" },
        );
    }
    try w.writeAll("</summary>");

    try w.writeAll(
        "<p class=\"muted\" style=\"font-size:0.85rem;margin:6px 0 10px;\">" ++
            "Workflow per sub circuit: author the placement grouping in the DSL, " ++
            "seed a <b>Rough</b> placement on the sub circuit's PCB Layout view (the “Rough” button), " ++
            "hand-finish it, then <b>star</b> the saved layout (the ★) as its blessed reference — " ++
            "do this for every sub circuit before a KiCad hand-off. A <code>(reflow)</code> " ++
            "sub circuit is placed freely by the parent and needs none.</p>",
    );

    try w.writeAll("<table><thead><tr><th>Sub circuit</th><th>Module</th>" ++
        "<th>Rough</th><th>Starred</th></tr></thead><tbody>");
    for (block.sub_blocks, statuses) |sb, st| {
        const mod_name = moduleSourceName(sb);
        try w.writeAll(ROW_TD_CODE_OPEN);
        try writeHtmlEscaped(w, sb.name);
        try w.writeAll("</code></td><td>");
        if (sb.source.len > 0) {
            // Module-name sources (no slash) link to the standalone /modules
            // viewer where the layout is authored; path-based sub-blocks can't
            // route there, so show the bare path.
            if (mod_name) |m| {
                try w.writeAll("<a href=\"/modules/");
                try writeUrlEncoded(w, m);
                try w.writeAll("\">");
                try writeHtmlEscaped(w, m);
                try w.writeAll("</a>");
            } else {
                try w.writeAll("<code>");
                try writeHtmlEscaped(w, sb.source);
                try w.writeAll("</code>");
            }
        } else {
            try writeHtmlEscaped(w, sb.block.name);
        }

        // Rough — has a rough placement been seeded for this module?
        try w.writeAll(TD_CELL_SEP);
        if (mod_name == null) {
            try w.writeAll(LAYOUT_DASH);
        } else if (st.rough) {
            try w.writeAll("<span class=\"pill pill-ok\">rough \u{2713}</span>");
        } else {
            try w.writeAll(ROUGH_TODO_CELL);
        }

        // Starred — has a finished layout been starred (the ★ / sync default)?
        try w.writeAll(TD_CELL_SEP);
        if (mod_name == null) {
            try w.writeAll(LAYOUT_DASH);
        } else if (st.starred) {
            try w.writeAll("<span class=\"pill pill-ok\">starred \u{2605}</span>");
        } else if (sb.reflow) {
            try w.writeAll("<span class=\"pill pill-concept\">reflow — parent places</span>");
        } else {
            try w.writeAll(STARRED_TODO_CELL);
        }
        try w.writeAll(ROW_TD_CLOSE);
    }
    try w.writeAll(TABLE_DETAILS_CLOSE);
}

/// The module name a sub-block instantiates, for resolving its layout sidecar:
/// `sb.source` when it is a bare module name (non-empty, no `/`). Null for
/// path-based sources and inline design-blocks, which have no `/modules/` page
/// or `<module>.layouts.json` to read.
fn moduleSourceName(sb: env_mod.SubBlock) ?[]const u8 {
    if (sb.source.len == 0) return null;
    if (std.mem.indexOfScalar(u8, sb.source, '/') != null) return null;
    return sb.source;
}

/// Shared "no data" cell for the Rough/Starred columns (a non-module sub-block).
const LAYOUT_DASH = "<span class=\"muted\">—</span>";

/// Rough column, not-yet-seeded state.
const ROUGH_TODO_CELL = "<span class=\"pill pill-todo\" title=\"No rough placement seeded yet — " ++
    "open the module's PCB Layout and hit Rough\">pending</span>";

/// Starred column, not-yet-starred state.
const STARRED_TODO_CELL = "<span class=\"pill pill-todo\" title=\"No layout starred yet — " ++
    "finish the layout and star it (\u{2605}) on the module's PCB Layout view\">\u{2606} not yet</span>";

/// Wires every sub circuit card's Schematic ⇄ PCB Layout toggle. Clicking "PCB
/// Layout" hides the schematic hubs and reveals the PCB view, lazily setting the
/// iframe `src` on first show (so opening the schematic page never triggers a
/// placement). A module sub circuit (`data-mod` set) loads the *editable* embed
/// of its own layout — drag / Rough / Save / ★ write the module's layout sidecar;
/// others load the read-only design-scoped preview (`?sub=`). The iframe URL
/// carries the global PCB-settings (via/track/clearance/DRC). Iterates `.subc-pcb`
/// (one per card) and resolves each card via `closest`, so a section that adopts
/// an attached sub circuit doesn't double-wire it. Reuses the `DESIGN_NAME`
/// global declared by writeScripts, so this must be emitted after it.
const SUBC_TOGGLE_SCRIPT =
    \\<script>(function(){
    \\function gv(id,dflt){var e=document.getElementById(id);var v=e?parseFloat(e.value):NaN;return (v>0)?v:dflt;}
    \\function gck(id){var e=document.getElementById(id);return (e&&e.checked)?1:0;}
    \\function settings(){return "track_width="+gv("g-tw",0.127)+"&clearance="+gv("g-cl",0.127)
    \\ +"&via_drill="+gv("g-vd",0.2)+"&via_dia="+gv("g-va",0.4)
    \\ +"&clr="+gck("g-clr-show")+"&drc="+gck("g-drc-show");}
    \\function embedUrl(mod,sub){
    \\ if(mod)return "/pcb-layout/"+encodeURIComponent(mod)+"?embed=1&edit=1&"+settings();
    \\ return "/pcb-layout/"+encodeURIComponent(DESIGN_NAME)+"?sub="+encodeURIComponent(sub)
    \\  +"&embed=1&edit=1&"+settings();}
    \\function fullUrl(mod,sub){
    \\ if(mod)return "/pcb-layout/"+encodeURIComponent(mod);
    \\ return "/pcb-layout/"+encodeURIComponent(DESIGN_NAME)+"?sub="+encodeURIComponent(sub)+"&embed=1&edit=1";}
    \\document.querySelectorAll(".subc-pcb").forEach(function(pcb){
    \\ var card=pcb.closest(".sch-section,.sch-attached-sub"); if(!card)return;
    \\ var tabs=card.querySelectorAll(".subc-tab");
    \\ var sch=card.querySelector(".subc-sch");
    \\ var frame=pcb.querySelector(".subc-pcb-frame");
    \\ if(!tabs.length||!sch||!frame)return;
    \\ var mod=pcb.getAttribute("data-mod")||""; var sub=pcb.getAttribute("data-sub")||"";
    \\ var open=pcb.querySelector(".subc-pcb-open"); if(open)open.setAttribute("href",fullUrl(mod,sub));
    \\ var loaded=false;
    \\ function show(view){
    \\  var isPcb=(view==="pcb"); sch.hidden=isPcb; pcb.hidden=!isPcb;
    \\  tabs.forEach(function(t){t.classList.toggle("active",t.getAttribute("data-subc-view")===view);});
    \\  if(isPcb&&!loaded){loaded=true; frame.setAttribute("src",embedUrl(mod,sub));}}
    \\ tabs.forEach(function(t){t.addEventListener("click",function(){show(t.getAttribute("data-subc-view"));});});
    \\});
    \\})();</script>
;

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
    ctx: *RenderCtx,
    w: anytype,
    allocator: Allocator,
    block: *const DesignBlock,
    check_results: *const CheckResultMap,
) !void {
    try w.writeAll("<section class=\"sch-section\" id=\"sec-design\" data-slug=\"design\"><div class=\"sec-head\"><h2>");
    try writeHtmlEscaped(w, block.name);
    try w.writeAll("</h2></div>");

    var hub_refs: std.ArrayListUnmanaged([]const u8) = .empty;
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

    try writeSectionHubs(ctx, w, allocator, &.{}, hub_refs.items, check_results);

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
pub const SCHEMATIC_VIEWER_JS = @import("serve/schematic_viewer_js.zig").SCHEMATIC_VIEWER_JS;

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
        var sb_refs: std.ArrayListUnmanaged([]const u8) = .empty;
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
        var flat_refs: std.ArrayListUnmanaged([]const u8) = .empty;
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
    var refs: std.ArrayListUnmanaged([]const u8) = .empty;
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

fn writeHtmlEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| switch (c) {
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '&' => try w.writeAll("&amp;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    };
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
pub const SCHEMATIC_CSS = @embedFile("assets/schematic_inline.css") ++ block_diagram.DIAGRAM_CSS;
