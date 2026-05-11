const std = @import("std");
const env_mod = @import("eval/env.zig");
const erc_mod = @import("erc.zig");
const review = @import("review.zig");
const review_html = @import("review_html.zig");
const req_checks = @import("req_checks.zig");
const CheckResultMap = std.StringHashMapUnmanaged([]req_checks.Result);
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
const system_svg = @import("render_system_svg.zig");
const rb = @import("render_block_types.zig");
const bom_html = @import("serve/bom_html.zig");
const isHub = draw.isHub;
const pinOrder = draw.pinOrder;

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
) RenderError![]const u8 {
    var ctx = try setupRenderCtx(allocator, block);
    ctx.project_dir = project_dir;

    var asserted_fns: std.StringHashMapUnmanaged([]const u8) = .empty;
    try appendAssertedFromBlock(allocator, &asserted_fns, block);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);

    try w.writeAll("<!DOCTYPE html><html><head><meta charset=\"utf-8\">");
    try w.writeAll("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">");
    try w.print("<title>{s} — Schematic</title>", .{block.name});
    try w.writeAll("<style>");
    try w.writeAll(navbar_css);
    try w.writeAll(SCHEMATIC_CSS);
    if (review_doc != null) try w.writeAll(review_html.BODY_CSS);
    try w.writeAll("</style></head><body>");

    try writeNavbar(w);
    try w.writeAll("<div class=\"sch-layout\">");
    try w.writeAll("<div class=\"sch-wrap\">");
    try writeHeader(w, block.name, design_name, status);

    // Top-of-page overview: block diagram, then the review summary + power/
    // test-point tables. These are read-only dashboards, so they sit above
    // the per-section schematics where the user does the detailed work.
    try w.writeAll("<div id=\"page-block-diagram\" class=\"page-anchor\">");
    try system_svg.renderSystemOverviewSvg(allocator, block, w);
    try w.writeAll("</div>");
    if (review_doc) |doc| {
        try w.writeAll("<div class=\"review-embed review-wrap\">");
        try w.writeAll("<div id=\"page-summary\" class=\"page-anchor\">");
        try review_html.writeSummaryTable(w, doc.summary);
        try w.writeAll("</div>");
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
        if (doc.power_tree.nodes.len > 0) {
            try w.writeAll("<div id=\"page-power-tree\" class=\"page-anchor\">");
            try review_html.writePowerTree(allocator, w, doc.power_tree);
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
    // per-section schematic cards. <details open> so it's visible by
    // default but the user can collapse it on long pages.
    try w.writeAll("<details id=\"page-bom\" class=\"sch-bom-card page-anchor\" open><summary>Bill of Materials</summary>");
    try bom_html.writeSchematicBomHtml(w, block);
    try w.writeAll("</details>");

    for (block.sections) |sec| try writeSection(&ctx, w, allocator, sec, 0, check_results);

    // Designs without sections (typical of sub-block-only or flat hub+passives
    // designs like power-6v, pma3-14ln) still deserve a rendering. Emit a
    // synthetic card per sub-block, plus one flat card if any hubs live at
    // the top level outside any section.
    for (block.sub_blocks) |sb| try writeSubBlockCard(&ctx, w, allocator, sb, check_results);

    if (block.sections.len == 0 and hasTopLevelHubs(block)) {
        try writeFlatHubs(&ctx, w, allocator, block, check_results);
    }

    // Bottom-of-page audit trail: ERC violations and assertions. Repeated
    // below the schematic so a reviewer who scrolls through can stamp
    // approvals and then see the outstanding issues without jumping back.
    if (review_doc) |doc| {
        try w.writeAll("<div class=\"review-embed review-wrap\">");
        try w.writeAll("<div id=\"page-unresolved\" class=\"page-anchor\">");
        try review_html.writeUnresolved(w, doc.unresolved);
        try w.writeAll("</div>");
        if (doc.assertions.len > 0) {
            try w.writeAll("<div id=\"page-assertions\" class=\"page-anchor\">");
            try review_html.writeAssertions(w, doc.assertions);
            try w.writeAll("</div>");
        }
        try w.writeAll("</div>");
    }

    try w.writeAll("</div>");
    try writeSidebar(w, review_doc);
    try w.writeAll("</div>");
    try writeScripts(w, allocator, design_name, block, &ctx, &asserted_fns, check_results, review_doc);
    if (review_doc != null) {
        // BODY_JS (design-note handlers) reuses DESIGN_NAME — already
        // declared by writeScripts above.
        try w.writeAll("<script>");
        try w.writeAll(review_html.BODY_JS);
        try w.writeAll("</script>");
    }
    try w.writeAll("</body></html>");

    return buf.items;
}

fn writeNavbar(w: anytype) !void {
    try w.writeAll("<div class=\"navbar\"><span class=\"brand\">Canopy EDA</span>");
    try w.writeAll("<a href=\"/\">Designs</a>");
    try w.writeAll("<a href=\"/library\">Library</a>");
    try w.writeAll("<a href=\"/account\" style=\"margin-left:auto\">Account</a>");
    try w.writeAll("</div>");
}

fn writeHeader(w: anytype, title: []const u8, design_name: []const u8, status: review.Status) !void {
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
    try w.writeAll(
        "<button class=\"head-link head-btn\" id=\"reload-btn\" type=\"button\" " ++
            "title=\"Re-read the .sexp source from disk and rebuild\">\u{21BB} Reload</button>",
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
        try writeTocChip(w, "page-summary", "Summary");
        if (doc.power_sequence.len > 0) try writeTocChip(w, "page-power-sequence", "Power sequencing");
        if (doc.test_points.len > 0) try writeTocChip(w, "page-test-points", "Test points");
        if (doc.power_budget.len > 0) try writeTocChip(w, "page-power-budget", "Power budget");
    }
    try writeTocChip(w, "page-bom", "BOM");
    try w.writeAll("</nav>");
    try w.writeAll(
        \\<div class="sb-search">
        \\<input type="search" id="sch-search" placeholder="Search net, ref, pin…" autocomplete="off" spellcheck="false">
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
fn appendAssertedFromBlock(
    allocator: Allocator,
    map: *std.StringHashMapUnmanaged([]const u8),
    block: *const DesignBlock,
) std.mem.Allocator.Error!void {
    for (block.nets) |net| {
        for (net.pins) |p| {
            if (p.asserted_fns.len == 0) continue;
            const key = std.fmt.allocPrint(allocator, "{s}|{s}", .{ p.ref_des, p.pin }) catch continue;
            const joined = joinAssertedFns(allocator, p.asserted_fns) orelse continue;
            try map.put(allocator, key, joined);
        }
    }
    for (block.sub_blocks) |sb| try appendAssertedFromBlock(allocator, map, sb.block);
}

fn joinAssertedFns(allocator: Allocator, fns: []const []const u8) ?[]const u8 {
    if (fns.len == 0) return null;
    if (fns.len == 1) return fns[0];
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);
    for (fns, 0..) |f, i| {
        if (i > 0) w.writeAll(", ") catch return null;
        w.writeAll(f) catch return null;
    }
    return buf.toOwnedSlice(allocator) catch null;
}

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
    sec: Section,
    depth: u8,
    check_results: *const CheckResultMap,
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
    try w.writeAll("</div>");

    if (sec.description.len > 0) {
        try w.writeAll("<p class=\"sec-desc\">");
        try writeHtmlEscaped(w, sec.description);
        try w.writeAll("</p>");
    }

    try writeSectionPorts(w, sec);

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

    try writeSectionHubs(ctx, w, allocator, sec.pin_groups, hub_refs.items, check_results);

    if (sec.notes.len > 0) try writeNotes(w, sec.notes);

    for (sec.sub_sections) |sub| try writeSection(ctx, w, allocator, sub, depth + 1, check_results);

    try w.writeAll(sectionClose);
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
    try writeHubRequirements(w, h, check_results);
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

fn writeHubRequirements(w: anytype, h: HubAnalysis, check_results: *const CheckResultMap) !void {
    if (h.inst.requirements.len == 0) return;
    const results: []const req_checks.Result = check_results.get(h.inst.ref_des) orelse &.{};

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
    try w.print("<details class=\"{s}\"", .{header_class});
    if (fail_ct > 0) try w.writeAll(" open");
    try w.print("><summary>Requirements ({d})", .{h.inst.requirements.len});
    if (fail_ct > 0) try w.print(" <span class=\"req-badge fail\">{d} failing</span>", .{fail_ct});
    if (pass_ct > 0) try w.print(" <span class=\"req-badge pass\">{d} ok</span>", .{pass_ct});
    if (verified_ct > 0) try w.print(" <span class=\"req-badge verified\">{d} verified</span>", .{verified_ct});
    try w.writeAll("</summary><ul>");

    // Build a sorted index into h.inst.requirements so the rendered list
    // reads worst → best regardless of the order entries appear in
    // `lib/components/<part>.sexp`.
    const SortItem = struct { idx: usize, key: u8 };
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sorted = a.alloc(SortItem, h.inst.requirements.len) catch return;
    for (h.inst.requirements, 0..) |_, i| {
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
        const r = h.inst.requirements[i];
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
    var pn_map = hub_mod.buildPinNameMap(ctx, hub_inst.parts);
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

fn firstNet(g: PinGroup) []const u8 {
    for (g.conns) |c| switch (c.endpoint) {
        .net => |n| return n,
        .pin => {},
    };
    return "";
}

fn writeSectionPorts(w: anytype, sec: Section) !void {
    if (sec.ports.len == 0) return;
    try w.writeAll("<table class=\"ports\"><thead><tr><th>Port</th><th>Dir</th><th>Type</th><th>Voltage</th><th>Role/Protocol</th></tr></thead><tbody>");
    for (sec.ports) |p| {
        try w.writeAll("<tr><td><code>");
        try writeHtmlEscaped(w, p.name);
        try w.print("</code></td><td>{s}</td><td>{s}</td><td>", .{ @tagName(p.direction), @tagName(p.signal_type) });
        if (p.voltage) |v| try w.print("{d}V", .{v}) else try w.writeAll("<span class=\"muted\">—</span>");
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
        if (p.protocol.len == 0 and p.role.len == 0) try w.writeAll("<span class=\"muted\">—</span>");
        try w.writeAll("</td></tr>");
    }
    try w.writeAll("</tbody></table>");
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

/// Synthetic section card for a sub-block instance (e.g. `(sub-block "buck"
/// (tpsm84338 …))`). Lists every hub that the sub-block's DesignBlock declares
/// and feeds them through the same writeHubCard path. The block's nets are
/// already flattened into `ctx` via `collectFlat`, so adjacency works.
fn writeSubBlockCard(
    ctx: *RenderCtx,
    w: anytype,
    allocator: Allocator,
    sb: env_mod.SubBlock,
    check_results: *const CheckResultMap,
) !void {
    const slug = try review.slugify(allocator, sb.name);
    try w.print("<section class=\"sch-section\" id=\"sec-{s}\" data-slug=\"{s}\">", .{ slug, slug });
    try w.writeAll("<div class=\"sec-head\"><h2>");
    try writeHtmlEscaped(w, sb.name);
    try w.writeAll("</h2><span class=\"pill pill-ok\">sub-block</span>");
    try w.writeAll("</div>");
    try w.writeAll("<p class=\"sec-desc\">");
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

    try w.writeAll(sectionClose);
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
    try w.writeAll(";</script>");
    try w.writeAll("<script>");
    try w.writeAll(SCHEMATIC_VIEWER_JS);
    try w.writeAll("</script>");
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
        try w.print("{{\"present\":true,\"unresolved\":{d},\"assertion_total\":{d},\"assertion_fail\":{d}}}", .{ doc.unresolved.len, doc.assertions.len, assertion_fail });
    } else {
        try w.writeAll("{\"present\":false}");
    }
}

const SCHEMATIC_VIEWER_JS = @import("serve/schematic_viewer_js.zig").SCHEMATIC_VIEWER_JS;

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
    try w.writeAll(",\"kind\":");
    try writeJsString(w, kind);
    try w.writeAll(",\"section\":");
    try writeJsString(w, section_slug);

    if (!std.mem.eql(u8, kind, "hub")) {
        try w.writeAll("}");
        return;
    }

    try w.writeAll(",\"pins\":[");
    var pn_map = hub_mod.buildPinNameMap(ctx, inst.parts);
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

const SCHEMATIC_CSS = @embedFile("assets/schematic_inline.css") ++ system_svg.SYSTEM_OVERVIEW_CSS;
