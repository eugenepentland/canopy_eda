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
const rb = @import("render_block_types.zig");
const bom_html = @import("serve/bom_html.zig");
const pages_tmpl = @import("serve/templates/pages.zig");
const isHub = draw.isHub;
const pinOrder = draw.pinOrder;

const MUTED_EM_DASH = review_html.mutedDash;

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
    try writeHeader(w, block.name, design_name, status, schematic_path);

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
    const sub_attachments = try computeSubBlockAttachments(allocator, block);
    defer allocator.free(sub_attachments);

    // Top-of-page overview: block diagram, then the power/test-point tables.
    // These are read-only dashboards, so they sit above the per-section
    // schematics where the user does the detailed work. The summary table and
    // sub-block-requirements list were dropped from this page — the audit
    // counts live on the ERC button + sidebar instead.
    try w.writeAll("<div id=\"page-block-diagram\" class=\"page-anchor\">");
    try block_diagram.renderBlockDiagramTabs(allocator, block, sub_attachments, w);
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
    try bom_html.writeSchematicBomHtml(w, block);
    try w.writeAll("</details>");

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
    for (block.sub_blocks, 0..) |sb, sb_idx| {
        if (sub_attachments[sb_idx] != null) continue;
        try writeSubBlockCard(&ctx, w, allocator, sb, check_results, .standalone);
    }

    if (block.sections.len == 0 and hasTopLevelHubs(block)) {
        try writeFlatHubs(&ctx, w, allocator, block, check_results);
    }

    // ERC violations and assertions no longer render at the bottom of the
    // page — they surface in the sidebar via the ERC button (which now also
    // lists the design's assertions). Keeps the page tail clean.

    try w.writeAll("</div>");
    try writeSidebar(w, review_doc);
    try w.writeAll("</div>");
    try writeScripts(w, allocator, design_name, block, &ctx, &asserted_fns, check_results, review_doc);
    // Per-sub-block PCB preview wiring — reuses the DESIGN_NAME global declared
    // by writeScripts, so it must follow that call. Only emitted when there are
    // sub-blocks (matching the global PCB-settings bar above).
    if (block.sub_blocks.len > 0) try w.writeAll(SUB_PCB_SCRIPT);
    if (review_doc != null) {
        // review_notes.js (design-note handlers) reuses DESIGN_NAME —
        // already declared as a global by writeScripts above.
        try w.writeAll("<script src=\"/static/review_notes.js\"></script>");
    }
    try w.writeAll("</body></html>");

    return aw.written();
}

fn writeHeader(w: anytype, title: []const u8, design_name: []const u8, status: review.Status, schematic_path: []const u8) !void {
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
    try w.writeAll(".sexp</code></div></div>");
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
    // useful. Instead each sub-block previews its own PCB layout on demand — see
    // the global "PCB Layout settings" bar (writePcbGlobals) and the per-sub-
    // block "PCB Layout" panels (writeSubBlockPcb).
    try w.writeAll(
        "<button class=\"head-link head-btn\" id=\"reload-btn\" type=\"button\" " ++
            "title=\"Re-read the .sexp source from disk and rebuild\">\u{21BB} Reload</button>",
    );
    try w.writeAll(
        "<button class=\"head-link head-btn\" id=\"copy-src-btn\" type=\"button\" " ++
            "title=\"Copy the raw .sexp source to the clipboard\">\u{1F4CB} Copy SRC</button>",
    );
    try w.writeAll("<button class=\"head-link head-btn\" id=\"erc-btn\" type=\"button\">ERC</button>");
    try w.writeAll("<div class=\"kicad-menu\">");
    try w.writeAll("<button class=\"head-link head-btn\" id=\"kicad-btn\" type=\"button\">KiCad \u{25BE}</button>");
    try w.writeAll("<div class=\"kicad-panel\" id=\"kicad-panel\">");
    try w.print("<button class=\"kicad-row-btn\" onclick=\"window.location='/api/export-netlist/{s}'\">Download Netlist (.net)</button>", .{design_name});
    try w.print(
        "<button class=\"kicad-row-btn\" onclick=\"window.location='/api/export-kicad/{s}'\">" ++
            "Download Netlist + Footprints (.zip)</button>",
        .{design_name},
    );
    // File-based PCB sync — writes directly to the .kicad_pcb declared
    // by the design's (kicad-pcb "<path>") form. pcbnew either auto-
    // prompts to reload (KiCad 8+) or surfaces it via File → Revert
    // (KiCad 7). The button is wired generically; if the design has no
    // (kicad-pcb …) form the server returns a clear 400 + message
    // which the JS handler surfaces in the status text.
    try w.writeAll(
        "<button class=\"kicad-row-btn\" id=\"push-kicad-pcb-btn\" " ++
            "title=\"Write updates to the .kicad_pcb declared by (kicad-pcb \u{2026}); " ++
            "pcbnew will prompt to reload, or use File \u{2192} Revert\">" ++
            "\u{2192} Push to KiCad PCB</button>",
    );
    // Prune variant: same as Push, plus convert every `flag_stale` op into
    // a real `remove`. The server already supports this via the `prune=1`
    // query param — exposed here so the user can clean up orphan
    // footprints accumulated by past failed syncs in one click.
    try w.writeAll(
        "<button class=\"kicad-row-btn\" id=\"push-kicad-pcb-prune-btn\" " ++
            "title=\"Same as Push, but ALSO deletes every footprint flagged stale " ++
            "(no longer in the design). Use after the design and board have drifted apart.\">" ++
            "\u{2192} Push + Delete Stale</button>",
    );
    // Dot-net variant: keeps each `(decouple …)` per-pin sub-net (VDD.U18.IN)
    // as the pad net instead of collapsing to the bare rail (?dot_nets=1), so
    // the board shows which bypass cap pairs with which pin. Those become
    // electrically-distinct nets — the user rejoins them with copper/zone.
    try w.writeAll(
        "<button class=\"kicad-row-btn\" id=\"push-kicad-pcb-dotnets-btn\" " ++
            "title=\"Same as Push, but keeps per-pin decoupling sub-nets (e.g. VDD.U18.IN) " ++
            "as distinct pad nets so each bypass cap shows which pin it belongs to. " ++
            "Rejoin them with copper/zone since the ratsnest won't tie them.\">" ++
            "\u{2192} Push (per-pin nets)</button>",
    );
    // Refresh variant: re-bake every placed part's footprint geometry via a
    // same-name swap (?refresh=1). Position, identity, and routing are
    // preserved — only the silkscreen/fab/courtyard graphics update. Use after
    // the footprint library gains new outlines (e.g. recovered silk/fab) to
    // backfill them onto a board built before the fix.
    try w.writeAll(
        "<button class=\"kicad-row-btn\" id=\"push-kicad-pcb-refresh-btn\" " ++
            "title=\"Re-bake every placed footprint's silkscreen/fab/courtyard geometry from the library " ++
            "without moving anything (same-name swap; position, identity, and pad nets preserved). " ++
            "Use to backfill recovered outlines onto an existing board.\">" ++
            "\u{2192} Refresh Footprints</button>",
    );
    try w.writeAll("<span id=\"push-kicad-pcb-status\" class=\"kicad-row-status\"></span>");
    try w.writeAll("</div></div>");
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
fn writeSidebar(w: anytype, review_doc: ?review.ReviewDoc) !void {
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
    try ctx.collectFlat(block, "");
    var flat_sec_idx: usize = 0;
    for (block.sections) |sec| {
        for (sec.instances) |inst| try ctx.section_map.put(allocator, inst.ref_des, flat_sec_idx);
        for (sec.pin_groups) |pg| {
            if (!ctx.section_map.contains(pg.ref_des)) {
                try ctx.section_map.put(allocator, pg.ref_des, flat_sec_idx);
            }
        }
        flat_sec_idx += 1;
        for (sec.sub_sections) |sub| {
            for (sub.instances) |inst| try ctx.section_map.put(allocator, inst.ref_des, flat_sec_idx);
            for (sub.pin_groups) |pg| {
                if (!ctx.section_map.contains(pg.ref_des)) {
                    try ctx.section_map.put(allocator, pg.ref_des, flat_sec_idx);
                }
            }
            flat_sec_idx += 1;
        }
    }
    for (block.sub_blocks) |sb| {
        for (sb.block.instances) |inst| try ctx.section_map.put(allocator, inst.ref_des, flat_sec_idx);
        flat_sec_idx += 1;
    }
    try ctx.buildPinNetMap();
    try ctx.classify();
    try ctx.buildAdjacency();
    try ctx.synthesizeSpokeConnections();
    try ctx.buildNetIndex();
    try ctx.buildSignificantNets(block);
    try ctx.buildPinCanonicalNets();
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
        .review => "pill-warn",
    };
    try w.writeAll("<div class=\"sec-head\"><h2>");
    try writeHtmlEscaped(w, sec.name);
    try w.print("</h2><span class=\"pill {s}\">{s}</span>", .{ status_pill, @tagName(sec.status) });
    const sec_cov = try coverage.computeSectionCoverage(allocator, block, sec, check_results);
    if (sec_cov.checked > 0) {
        const cov_class: []const u8 = if (sec_cov.complete == sec_cov.checked) "pill-pass" else "pill-warn";
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

    for (attached_subs) |sb| try writeSubBlockCard(ctx, w, allocator, sb, check_results, .attached);

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
    if (!from_pin_groups) {
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
        try w.writeAll("<tr><td><code>");
        try writeHtmlEscaped(w, p.name);
        try w.print("</code></td><td>{s}</td><td>{s}</td><td>", .{ @tagName(p.direction), @tagName(p.signal_type) });
        if (p.voltage) |v| try w.print("{d}V", .{v}) else try w.writeAll(MUTED_EM_DASH);
        try w.writeAll("</td><td>");
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
        try w.writeAll("</td></tr>");
    }
    try w.writeAll("</tbody></table></details>");
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
        try w.writeAll("<tr><td><code>");
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
        try w.writeAll("</td><td>");
        if (e.domain.len > 0) {
            try writeHtmlEscaped(w, e.domain);
        } else {
            try w.writeAll(MUTED_EM_DASH);
        }
        try w.writeAll("</td></tr>");
    }
    try w.writeAll("</tbody></table></details>");
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
fn writeSubBlockCard(
    ctx: *RenderCtx,
    w: anytype,
    allocator: Allocator,
    sb: env_mod.SubBlock,
    check_results: *const CheckResultMap,
    mode: SubBlockMode,
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
    try w.writeAll(switch (mode) {
        .standalone => "</h2>",
        .attached => "</h3>",
    });
    try w.writeAll("<span class=\"pill pill-ok\">sub-block</span>");
    // "Copy source" pulls the underlying module/file text via
    // /api/module-source; "View" opens the standalone /modules viewer. Both
    // need the sub-block's source provenance — skip them when it's unknown.
    // The `/modules/:name` route can't carry a slashed path, so only
    // module-name sources (no `/`) get the View link; path-based sub-blocks
    // still get the copy button (the API takes the raw path via query).
    if (sb.source.len > 0) {
        try w.writeAll("<button type=\"button\" class=\"copy-src-btn\" data-src=\"");
        try writeHtmlEscaped(w, sb.source);
        try w.writeAll("\">Copy source</button>");
        if (std.mem.indexOfScalar(u8, sb.source, '/') == null) {
            try w.writeAll("<a class=\"view-src-link\" href=\"/modules/");
            try writeUrlEncoded(w, sb.source);
            try w.writeAll("\">View \u{2197}</a>");
        }
    }
    try w.writeAll("</div>");
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

    try writeSectionHubs(ctx, w, allocator, &.{}, hub_refs.items, check_results);

    // Per-sub-block PCB layout preview (read-only, computed on demand). Scoped
    // to this sub-block via ?sub=<slug> so the whole design is never placed; it
    // uses the page's global PCB-settings bar for via/clearance/DRC. The iframe
    // has no src until the user presses Generate, so nothing computes on load.
    try writeSubBlockPcb(w, slug);

    try w.writeAll(switch (mode) {
        .standalone => sectionClose,
        .attached => "</div>",
    });
}

/// Global PCB-layout controls shared by every sub-block's inline preview. The
/// whole-design layout is intentionally not offered (it places every component
/// at once, which is too slow to be useful); each `(sub-block …)` card computes
/// its own scoped preview on demand using these via/clearance/DRC values. The
/// number inputs mirror the standalone PCB page's Route panel defaults
/// (router.RouteParams). Read by SUB_PCB_SCRIPT when building each iframe URL.
fn writePcbGlobals(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\<details class="pcb-globals" id="page-pcb-globals">
        \\<summary>PCB Layout settings <span class="sch-card-sub muted">via / trace / DRC — used by each sub-block preview</span></summary>
        \\<div class="pcb-globals-body">
        \\<label>Track <input id="g-tw" type="number" step="0.05" min="0.05" value="0.127"></label>
        \\<label>Clearance <input id="g-cl" type="number" step="0.05" min="0.05" value="0.127"></label>
        \\<label>Via drill <input id="g-vd" type="number" step="0.05" min="0.1" value="0.2"></label>
        \\<label>Via &Oslash; <input id="g-va" type="number" step="0.05" min="0.2" value="0.4"></label>
        \\<label class="pcb-globals-chk"><input id="g-clr-show" type="checkbox"> show clearance</label>
        \\<label class="pcb-globals-chk"><input id="g-drc-show" type="checkbox" checked> show DRC</label>
        \\<span class="pcb-globals-hint muted">Open a sub-block's &ldquo;PCB Layout&rdquo;
        \\panel below and press Generate. Changing a value here applies on the next Generate.</span>
        \\</div>
        \\</details>
    );
}

/// The collapsible "PCB Layout" panel inside a sub-block card: a Generate /
/// Regenerate button plus a lazily-loaded iframe scoped to this sub-block. The
/// iframe src is filled in by SUB_PCB_SCRIPT from the global PCB-settings bar,
/// so nothing is computed until the user opens the panel and presses the button.
fn writeSubBlockPcb(w: *std.Io.Writer, slug: []const u8) !void {
    // `slug` is review.slugify output ([a-z0-9-]) — safe in an attribute and a
    // URL component without further escaping (same value used for data-slug).
    try w.writeAll("<details class=\"sub-pcb\"><summary>PCB Layout</summary>");
    try w.writeAll("<div class=\"sub-pcb-body\" data-sub=\"");
    try w.writeAll(slug);
    try w.writeAll("\"><div class=\"sub-pcb-controls\">");
    try w.writeAll("<button type=\"button\" class=\"sub-pcb-gen\">Generate layout</button>");
    try w.writeAll("<span class=\"sub-pcb-status muted\">Not generated yet</span></div>");
    try w.writeAll("<div class=\"sub-pcb-frame-wrap\" hidden>");
    try w.writeAll("<iframe class=\"sub-pcb-frame\" title=\"PCB layout preview\" loading=\"lazy\"></iframe>");
    try w.writeAll("</div></div></details>");
}

/// Wires every sub-block "PCB Layout" panel: on Generate, build the scoped,
/// routed embed URL from the global PCB-settings inputs and (re)load the
/// iframe. Reuses the `DESIGN_NAME` global declared by writeScripts, so this
/// must be emitted after it. Nothing runs until a button is pressed, so opening
/// the schematic page never triggers a placement.
const SUB_PCB_SCRIPT =
    \\<script>(function(){
    \\function gv(id,dflt){var e=document.getElementById(id);var v=e?parseFloat(e.value):NaN;return (v>0)?v:dflt;}
    \\function gck(id){var e=document.getElementById(id);return (e&&e.checked)?1:0;}
    \\function url(sub){
    \\ return "/pcb-layout/"+encodeURIComponent(DESIGN_NAME)+"?sub="+encodeURIComponent(sub)
    \\  +"&embed=1&route=1&regen=1"
    \\  +"&track_width="+gv("g-tw",0.127)+"&clearance="+gv("g-cl",0.127)
    \\  +"&via_drill="+gv("g-vd",0.2)+"&via_dia="+gv("g-va",0.4)
    \\  +"&clr="+gck("g-clr-show")+"&drc="+gck("g-drc-show");
    \\}
    \\document.querySelectorAll(".sub-pcb-body").forEach(function(body){
    \\ var sub=body.getAttribute("data-sub");
    \\ var btn=body.querySelector(".sub-pcb-gen");
    \\ var st=body.querySelector(".sub-pcb-status");
    \\ var wrap=body.querySelector(".sub-pcb-frame-wrap");
    \\ var frame=body.querySelector(".sub-pcb-frame");
    \\ if(!btn||!frame)return;
    \\ frame.addEventListener("load",function(){if(frame.getAttribute("src"))st.textContent="Generated";});
    \\ btn.addEventListener("click",function(){
    \\  st.textContent="Generating…"; wrap.hidden=false;
    \\  frame.setAttribute("src",url(sub)); btn.textContent="Regenerate";});
    \\});
    \\})();</script>
;

/// Match each top-level `(sub-block …)` to the section that wires it. The
/// heuristic counts "specific" shared nets: a net counts when its `net_ties`
/// reference exactly one sub-block name. That filters out shared rails
/// (VBATT/VDD/GND tie to many sub-blocks) so power blocks stay floating
/// while functional sub-blocks (`flash`, `usb`, `imu`, `adc1..3`) merge into
/// the section whose pin-group or port nets they tie to. Returns a slice
/// indexed by sub-block index; entries are the matched section index or
/// null when the sub-block didn't share any specific net with any section.
///
/// Power-classified nets (`(port … in/out power V)`) are excluded from the
/// count. A rail produced by one sub-block (e.g. a buck regulator's VOUT)
/// ties to exactly that sub-block, so a *consumer* section that declares an
/// `in power` port for the rail would otherwise look like the producer's
/// home — adopting the regulator card into, say, an LDO section. Dropping
/// power nets leaves adoption driven by signal nets (the peripheral's real
/// interface), so power producers stay floating as their own top-level card.
pub fn computeSubBlockAttachments(
    allocator: Allocator,
    block: *const DesignBlock,
) ![]?usize {
    const result = try allocator.alloc(?usize, block.sub_blocks.len);
    for (result) |*r| r.* = null;
    if (block.sub_blocks.len == 0 or block.sections.len == 0) return result;

    var net_to_subs: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)) = .empty;
    defer {
        var it = net_to_subs.iterator();
        while (it.next()) |e| e.value_ptr.deinit(allocator);
        net_to_subs.deinit(allocator);
    }

    for (block.net_ties) |nt| {
        const a_slash = std.mem.indexOfScalar(u8, nt.a, '/');
        const b_slash = std.mem.indexOfScalar(u8, nt.b, '/');
        var parent: []const u8 = "";
        var sub: []const u8 = "";
        if (a_slash == null and b_slash != null) {
            parent = nt.a;
            sub = nt.b[0..b_slash.?];
        } else if (b_slash == null and a_slash != null) {
            parent = nt.b;
            sub = nt.a[0..a_slash.?];
        } else continue;

        const gop = try net_to_subs.getOrPut(allocator, parent);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        _ = try gop.value_ptr.getOrPut(allocator, sub);
    }

    var sb_name_to_idx: std.StringHashMapUnmanaged(usize) = .empty;
    defer sb_name_to_idx.deinit(allocator);
    for (block.sub_blocks, 0..) |sb, idx| {
        try sb_name_to_idx.put(allocator, sb.name, idx);
    }

    // Explicit `(hosts "sub" …)` bindings are authoritative — they override the
    // net-count heuristic so a multi-sub subsystem (e.g. a PSU regulator + its
    // INA monitor) folds into one named section node regardless of how its
    // nets happen to tie. First declaration wins if two sections both claim it.
    var explicit_host: std.StringHashMapUnmanaged(usize) = .empty;
    defer explicit_host.deinit(allocator);
    for (block.sections, 0..) |sec, sec_idx| {
        for (sec.hosts) |host_name| {
            const gop = try explicit_host.getOrPut(allocator, host_name);
            if (!gop.found_existing) gop.value_ptr.* = sec_idx;
        }
    }

    // Every net declared as a power port anywhere (`(port … power V)`) is a
    // shared rail, not a peripheral interface. Collect them up front so the
    // affinity count below ignores them — otherwise a regulator sub-block
    // gets adopted into whichever consumer section declares the matching
    // `in power` port.
    var power_nets: std.StringHashMapUnmanaged(void) = .empty;
    defer power_nets.deinit(allocator);
    for (block.sections) |sec| {
        for (sec.ports) |port| {
            if (port.signal_type == .power) try power_nets.put(allocator, port.name, {});
        }
    }

    const sec_count = block.sections.len;
    const sb_count = block.sub_blocks.len;
    const counts = try allocator.alloc(usize, sb_count * sec_count);
    defer allocator.free(counts);
    @memset(counts, 0);

    for (block.sections, 0..) |sec, sec_idx| {
        var sec_nets: std.StringHashMapUnmanaged(void) = .empty;
        defer sec_nets.deinit(allocator);
        for (sec.pin_groups) |pg| {
            for (pg.pins) |p| try sec_nets.put(allocator, p.net, {});
        }
        for (sec.ports) |port| {
            try sec_nets.put(allocator, port.name, {});
        }

        var it = sec_nets.iterator();
        while (it.next()) |entry| {
            if (power_nets.contains(entry.key_ptr.*)) continue;
            const subs_ptr = net_to_subs.getPtr(entry.key_ptr.*) orelse continue;
            if (subs_ptr.count() != 1) continue;
            var sub_it = subs_ptr.keyIterator();
            const sub_name = sub_it.next().?.*;
            const sb_idx = sb_name_to_idx.get(sub_name) orelse continue;
            counts[sb_idx * sec_count + sec_idx] += 1;
        }
    }

    for (block.sub_blocks, 0..) |sb, sb_idx| {
        if (explicit_host.get(sb.name)) |sec_idx| {
            result[sb_idx] = sec_idx;
            continue;
        }
        var best_idx: ?usize = null;
        var best_count: usize = 0;
        var best_is_conn: bool = true;
        for (block.sections, 0..) |sec, sec_idx| {
            const c = counts[sb_idx * sec_count + sec_idx];
            if (c == 0) continue;
            const is_conn = rb.classifyByName(sec.name, sec.instances) == .connector;
            // Highest net-tie count wins; on a tie prefer a non-connector
            // section. A functional sub-block belongs with its subsystem, not
            // the connector it merely routes I/O through (the ADAR2004 RX
            // mixers tie their RFIN array against the mezzanine's ADC channels).
            const better = c > best_count or (c == best_count and best_is_conn and !is_conn);
            if (better) {
                best_count = c;
                best_idx = sec_idx;
                best_is_conn = is_conn;
            }
        }
        if (best_count >= 1) result[sb_idx] = best_idx;
    }
    return result;
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

// spec: render_html - Excludes power-classified nets so a power-producer sub-block is not adopted into a consuming section
test "computeSubBlockAttachments keeps a power producer out of a consuming section" {
    // Mirrors cyclops-analog: the "1.8 V LDO" section *consumes* V_RF_3P3
    // via `(port "V_RF_3P3" in power 3.3)`, while the buck33 sub-block
    // *produces* that rail. A separate USB section consumes a buck-
    // independent signal from the usb sub-block. Adoption must follow the
    // signal net, not the shared power rail.
    const ldo_ports = [_]env_mod.SectionPort{
        .{ .name = "V_RF_3P3", .direction = .in, .signal_type = .power, .voltage = 3.3 },
    };
    const usb_ports = [_]env_mod.SectionPort{
        .{ .name = "USB_DP", .direction = .io, .signal_type = .differential },
    };
    const sections = [_]Section{
        .{ .name = "TPS7A2018 1.8 V LDO", .ports = &ldo_ports },
        .{ .name = "USB", .ports = &usb_ports },
    };

    var buck_design = emptyAttachBlock("tps63806-rail");
    var usb_design = emptyAttachBlock("usb-c-hs");
    const sub_blocks = [_]env_mod.SubBlock{
        .{ .name = "buck33", .block = &buck_design },
        .{ .name = "usb", .block = &usb_design },
    };

    // Net-ties as the evaluator materialises bridge / consolidated-net
    // wiring: one side carries the `<sub>/<port>` prefix, the other the
    // parent net the design wires it to.
    const net_ties = [_]env_mod.NetTie{
        .{ .a = "buck33/VOUT", .b = "V_RF_3P3" }, // buck33 produces the rail
        .{ .a = "usb/DP", .b = "USB_DP" }, // usb drives the signal
    };

    var block = emptyAttachBlock("cyclops-analog");
    block.sections = &sections;
    block.sub_blocks = &sub_blocks;
    block.net_ties = &net_ties;

    const attachments = try computeSubBlockAttachments(std.testing.allocator, &block);
    defer std.testing.allocator.free(attachments);

    // buck33 shares only the power rail with the LDO section → not adopted,
    // so it renders as its own top-level synthetic card.
    try std.testing.expectEqual(@as(?usize, null), attachments[0]);
    // usb shares a signal net with the USB section (idx 1) → still adopted.
    try std.testing.expectEqual(@as(?usize, 1), attachments[1]);
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
) !void {
    try w.writeAll("<script>var DESIGN_NAME=");
    try writeJsString(w, design_name);
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
///     components:[{ref,component,value,kind,section,pins?:[{id,net,fn,alt}]}],
///     nets:[{name,members:[{ref,pin,fn?}]}]}`
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
        try w.writeAll(",\"category\":");
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
