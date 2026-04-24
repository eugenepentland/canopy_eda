const std = @import("std");
const env_mod = @import("eval/env.zig");
const erc_mod = @import("erc.zig");
const review = @import("review.zig");
const review_html = @import("review_html.zig");
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
const isHub = draw.isHub;
const pinOrder = draw.pinOrder;

const Allocator = std.mem.Allocator;

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
) ![]const u8 {
    var ctx = RenderCtx.init(allocator);
    ctx.project_dir = project_dir;
    try ctx.collectFlat(block, "");

    var flat_sec_idx: usize = 0;
    for (block.sections) |sec| {
        for (sec.instances) |inst| try ctx.section_map.put(allocator, inst.ref_des, flat_sec_idx);
        flat_sec_idx += 1;
        for (sec.sub_sections) |sub| {
            for (sub.instances) |inst| try ctx.section_map.put(allocator, inst.ref_des, flat_sec_idx);
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

    var asserted_fns: std.StringHashMapUnmanaged([]const u8) = .empty;
    appendAssertedFromBlock(allocator, &asserted_fns, block);

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
    try system_svg.renderSystemOverviewSvg(allocator, block, w);
    if (review_doc) |doc| {
        try w.writeAll("<div class=\"review-embed review-wrap\">");
        try review_html.writeSummaryTable(w, doc.summary);
        try review_html.writePowerSequence(w, doc.power_sequence);
        try review_html.writeTestPoints(w, doc.test_points);
        try review_html.writePowerBudget(w, doc.power_budget);
        try w.writeAll("</div>");
    }

    const rstate: ?review.ReviewState = if (review_doc) |d| d.review_state else null;
    for (block.sections) |sec| try writeSection(&ctx, w, allocator, sec, 0, rstate);

    // Designs without sections (typical of sub-block-only or flat hub+passives
    // designs like power-6v, pma3-14ln) still deserve a rendering. Emit a
    // synthetic card per sub-block, plus one flat card if any hubs live at
    // the top level outside any section.
    for (block.sub_blocks) |sb| try writeSubBlockCard(&ctx, w, allocator, sb, rstate);

    if (block.sections.len == 0 and hasTopLevelHubs(block)) {
        try writeFlatHubs(&ctx, w, allocator, block, rstate);
    }

    // Bottom-of-page audit trail: ERC violations and assertions. Repeated
    // below the schematic so a reviewer who scrolls through can stamp
    // approvals and then see the outstanding issues without jumping back.
    if (review_doc) |doc| {
        try w.writeAll("<div class=\"review-embed review-wrap\">");
        try review_html.writeUnresolved(w, doc.unresolved);
        try review_html.writeAssertions(w, doc.assertions);
        try w.writeAll("</div>");
    }

    try w.writeAll("</div>");
    try writeSidebar(w);
    try w.writeAll("</div>");
    try writeScripts(w, allocator, design_name, block, &ctx, &asserted_fns);
    if (review_doc != null) {
        // BODY_JS (review checklist handlers) reuses DESIGN_NAME — already
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
    try w.writeAll("<button class=\"head-link head-btn\" id=\"erc-btn\" type=\"button\">ERC</button>");
    try w.writeAll("<div class=\"kicad-menu\">");
    try w.writeAll("<button class=\"head-link head-btn\" id=\"kicad-btn\" type=\"button\">KiCad \u{25BE}</button>");
    try w.writeAll("<div class=\"kicad-panel\" id=\"kicad-panel\">");
    try w.print("<button class=\"kicad-row-btn\" onclick=\"window.location='/api/export-netlist/{s}'\">Download Netlist (.net)</button>", .{design_name});
    try w.print("<button class=\"kicad-row-btn\" onclick=\"window.location='/api/export-kicad/{s}'\">Download Netlist + Footprints (.zip)</button>", .{design_name});
    try w.writeAll("<div class=\"kicad-sep\"></div>");
    try w.writeAll("<label class=\"kicad-label\">Output directory</label>");
    try w.writeAll("<input type=\"text\" class=\"kicad-input\" id=\"kicad-path\" placeholder=\"/path/to/kicad/project\" />");
    try w.writeAll("<label class=\"kicad-label\">.kicad_pcb file (optional)</label>");
    try w.writeAll("<input type=\"text\" class=\"kicad-input\" id=\"kicad-pcb-file\" placeholder=\"defaults to {output_dir}/{name}.kicad_pcb\" />");
    try w.writeAll("<button class=\"kicad-row-btn\" id=\"kicad-save-path\">Save settings</button>");
    try w.writeAll("<div class=\"kicad-sep\"></div>");
    try w.writeAll("<button class=\"kicad-row-btn\" id=\"kicad-write-netlist\">Write netlist to path</button>");
    try w.writeAll("<button class=\"kicad-row-btn\" id=\"kicad-write-kicad\">Write netlist + footprints to path</button>");
    try w.writeAll("<label class=\"kicad-check\"><input type=\"checkbox\" id=\"kicad-short-nets\" /> Shorten net names (.kicad_pcb update)</label>");
    try w.writeAll("<button class=\"kicad-row-btn kicad-primary\" id=\"kicad-update-pcb\">Update KiCad PCB (pcb_update.py)</button>");
    try w.writeAll("<div class=\"kicad-status\" id=\"kicad-status\"></div>");
    try w.writeAll("</div></div>");
    try w.print("<a class=\"head-link\" href=\"/pcb/{s}\">PCB</a>", .{design_name});
    try w.print("<a class=\"head-link\" href=\"/schematics/{s}/canvas\">Canvas (legacy)</a>", .{design_name});
    try w.print("<a class=\"head-link\" href=\"/api/export-bom/{s}\">BOM</a>", .{design_name});
    try w.print("<a class=\"head-link\" href=\"/api/export-netlist/{s}\">Netlist</a>", .{design_name});
    try w.writeAll("</div></header>");
}

fn writeSidebar(w: anytype) !void {
    try w.writeAll(
        \\<aside class="sch-sidebar" id="sch-sidebar">
        \\<div class="sb-search">
        \\<input type="search" id="sch-search" placeholder="Search net, ref, pin…" autocomplete="off" spellcheck="false">
        \\<div id="sb-results" class="sb-results"></div>
        \\</div>
        \\<div id="sb-detail" class="sb-detail"></div>
        \\</aside>
    );
}

/// Build a map of (ref_des|pin_id) -> asserted alt-function names (e.g. "SPI4_SCK",
/// or "TIM1_CH1, GPIO" when the pin declared multiple roles) from all
/// `(pin X (as "FN" ...) ...)` declarations in the design tree.
fn appendAssertedFromBlock(allocator: Allocator, map: *std.StringHashMapUnmanaged([]const u8), block: *const DesignBlock) void {
    for (block.nets) |net| {
        for (net.pins) |p| {
            if (p.asserted_fns.len == 0) continue;
            const key = std.fmt.allocPrint(allocator, "{s}|{s}", .{ p.ref_des, p.pin }) catch continue;
            const joined = joinAssertedFns(allocator, p.asserted_fns) orelse continue;
            map.put(allocator, key, joined) catch {};
        }
    }
    for (block.sub_blocks) |sb| appendAssertedFromBlock(allocator, map, sb.block);
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

fn writeSection(ctx: *RenderCtx, w: anytype, allocator: Allocator, sec: Section, depth: u8, review_state: ?review.ReviewState) !void {
    const indent_class: []const u8 = if (depth == 0) "sch-section" else "sch-section sch-subsection";
    const slug = try review.slugify(allocator, sec.name);
    const rs: ?review.SectionReviewState = if (review_state) |state|
        review_html.findState(state, slug)
    else
        null;
    const approved_class: []const u8 = if (rs) |s| (if (s.approved) " sec-card-approved" else "") else "";
    try w.print("<section class=\"{s}{s}\" id=\"sec-{s}\" data-slug=\"{s}\">", .{ indent_class, approved_class, slug, slug });

    // Header
    const status_pill: []const u8 = switch (sec.status) {
        .concept => "pill-concept",
        .implemented => "pill-ok",
        .review => "pill-warn",
    };
    try w.writeAll("<div class=\"sec-head\"><h2>");
    try writeHtmlEscaped(w, sec.name);
    try w.print("</h2><span class=\"pill {s}\">{s}</span>", .{ status_pill, @tagName(sec.status) });
    if (rs) |s| if (s.approved) try w.writeAll("<span class=\"pill pill-approved\">APPROVED</span>");
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

    try writeSectionHubs(ctx, w, allocator, sec.pin_groups, hub_refs.items);

    if (sec.notes.len > 0) try writeNotes(w, sec.notes);

    for (sec.sub_sections) |sub| try writeSection(ctx, w, allocator, sub, depth + 1, review_state);

    // Approval + checklist widget anchored to this section's slug. The shared
    // review-state JS handler picks up the `data-slug` on the enclosing card
    // and POSTs to /api/review-state/:name/...
    if (rs) |s| try review_html.writeChecklist(w, s);

    try w.writeAll("</section>");
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
) !void {
    for (hub_refs) |hub_ref| {
        if (try analyzeHub(ctx, allocator, pin_groups, hub_ref)) |a| {
            try writeHubCard(ctx, w, allocator, a);
        }
    }
}

fn writeHubCard(ctx: *RenderCtx, w: anytype, allocator: Allocator, h: HubAnalysis) !void {
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
    try w.writeAll("</div></div>");
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

fn writeNotes(w: anytype, notes: []const []const u8) !void {
    try w.writeAll("<details class=\"sec-notes\"><summary>");
    try w.print("Notes ({d})</summary><ul>", .{notes.len});
    for (notes) |n| {
        try w.writeAll("<li>");
        try writeHtmlEscaped(w, n);
        try w.writeAll("</li>");
    }
    try w.writeAll("</ul></details>");
}

/// Synthetic section card for a sub-block instance (e.g. `(sub-block "buck"
/// (tpsm84338 …))`). Lists every hub that the sub-block's DesignBlock declares
/// and feeds them through the same writeHubCard path. The block's nets are
/// already flattened into `ctx` via `collectFlat`, so adjacency works.
fn writeSubBlockCard(ctx: *RenderCtx, w: anytype, allocator: Allocator, sb: env_mod.SubBlock, review_state: ?review.ReviewState) !void {
    const slug = try review.slugify(allocator, sb.name);
    const rs: ?review.SectionReviewState = if (review_state) |state|
        review_html.findState(state, slug)
    else
        null;
    const approved_class: []const u8 = if (rs) |s| (if (s.approved) " sec-card-approved" else "") else "";
    try w.print("<section class=\"sch-section{s}\" id=\"sec-{s}\" data-slug=\"{s}\">", .{ approved_class, slug, slug });
    try w.writeAll("<div class=\"sec-head\"><h2>");
    try writeHtmlEscaped(w, sb.name);
    try w.writeAll("</h2><span class=\"pill pill-ok\">sub-block</span>");
    if (rs) |s| if (s.approved) try w.writeAll("<span class=\"pill pill-approved\">APPROVED</span>");
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

    try writeSectionHubs(ctx, w, allocator, &.{}, hub_refs.items);

    if (rs) |s| try review_html.writeChecklist(w, s);

    try w.writeAll("</section>");
}

/// Fallback rendering for designs that declare instances directly in
/// `design-block` without any `section` wrapper (e.g. pma3-14ln). Every
/// hub-prefixed top-level instance becomes its own card inside one synthetic
/// section.
fn writeFlatHubs(ctx: *RenderCtx, w: anytype, allocator: Allocator, block: *const DesignBlock, review_state: ?review.ReviewState) !void {
    const rs: ?review.SectionReviewState = if (review_state) |state|
        review_html.findState(state, "design")
    else
        null;
    const approved_class: []const u8 = if (rs) |s| (if (s.approved) " sec-card-approved" else "") else "";
    try w.print("<section class=\"sch-section{s}\" id=\"sec-design\" data-slug=\"design\"><div class=\"sec-head\"><h2>", .{approved_class});
    try writeHtmlEscaped(w, block.name);
    if (rs) |s| if (s.approved) try w.writeAll("<span class=\"pill pill-approved\">APPROVED</span>");
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

    try writeSectionHubs(ctx, w, allocator, &.{}, hub_refs.items);

    if (rs) |s| try review_html.writeChecklist(w, s);

    try w.writeAll("</section>");
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
) !void {
    try w.writeAll("<script>var DESIGN_NAME=");
    try writeJsString(w, design_name);
    try w.writeAll(";var SCH_INDEX=");
    try writeSearchIndex(w, allocator, block, ctx, asserted_fns);
    try w.writeAll(";</script>");
    try w.writeAll("<script>");
    try w.writeAll(SCHEMATIC_VIEWER_JS);
    try w.writeAll("</script>");
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
) !void {
    var ref_section: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer ref_section.deinit(allocator);
    try buildRefSectionMap(allocator, block, &ref_section);

    try w.writeAll("{\"sections\":[");

    var first = true;
    for (block.sections) |sec| {
        try emitSectionEntry(w, allocator, sec, &first);
    }
    for (block.sub_blocks) |sb| {
        if (!first) try w.writeAll(",");
        first = false;
        const slug = try review.slugify(allocator, sb.name);
        const sb_cat = rb.classifyByName(sb.name, sb.block.instances);
        try w.writeAll("{\"slug\":");
        try writeJsString(w, slug);
        try w.writeAll(",\"name\":");
        try writeJsString(w, sb.name);
        try w.writeAll(",\"description\":");
        try writeJsString(w, sb.block.name);
        try w.writeAll(",\"category\":");
        try writeJsString(w, @tagName(sb_cat));
        try w.writeAll(",\"hubs\":[");
        try emitHubRefsForBlock(w, sb.block);
        try w.writeAll("]}");
    }
    if (block.sections.len == 0 and hasTopLevelHubs(block)) {
        if (!first) try w.writeAll(",");
        first = false;
        const flat_cat = rb.classifyByName(block.name, block.instances);
        try w.writeAll("{\"slug\":\"design\",\"name\":");
        try writeJsString(w, block.name);
        try w.writeAll(",\"description\":\"\",\"category\":");
        try writeJsString(w, @tagName(flat_cat));
        try w.writeAll(",\"hubs\":[");
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
) !void {
    if (!first.*) try w.writeAll(",");
    first.* = false;
    const slug = try review.slugify(allocator, sec.name);
    const cat = rb.classifySection(sec);
    try w.writeAll("{\"slug\":");
    try writeJsString(w, slug);
    try w.writeAll(",\"name\":");
    try writeJsString(w, sec.name);
    try w.writeAll(",\"description\":");
    try writeJsString(w, sec.description);
    try w.writeAll(",\"category\":");
    try writeJsString(w, @tagName(cat));
    try w.writeAll(",\"hubs\":[");
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
    for (sec.sub_sections) |sub| try emitSectionEntry(w, allocator, sub, first);
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

const SCHEMATIC_CSS =
    \\html,body{margin:0;background:#0d1117;color:#c9d1d9;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;}
    \\code{font-family:"SF Mono","Fira Code",monospace;font-size:0.9em;color:#c9d1d9;background:#161b22;padding:1px 5px;border-radius:3px;}
    \\a{color:#58a6ff;text-decoration:none;}a:hover{text-decoration:underline;}
    \\.sch-layout{display:grid;grid-template-columns:minmax(0,1fr) 320px;gap:0;align-items:start;}
    \\.sch-wrap{min-width:0;max-width:1200px;margin:0 auto;padding:24px 20px 48px;width:100%;box-sizing:border-box;}
    \\h1{color:#f0f6fc;margin:0;font-size:1.6rem;}
    \\h2{color:#f0f6fc;font-size:1.15rem;margin:0;}
    \\h3{color:#f0f6fc;font-size:0.95rem;margin:0;}
    \\.sch-head{display:grid;grid-template-columns:1fr auto;gap:12px;align-items:center;padding:16px 0;border-bottom:1px solid #21262d;}
    \\.head-title{grid-column:1;}
    \\.subtitle{color:#8b949e;font-size:0.9rem;margin-top:4px;}
    \\.banner{grid-column:2;padding:10px 20px;border-radius:6px;font-weight:700;letter-spacing:0.04em;font-size:0.85rem;}
    \\.banner-pass{background:#0d3a1f;color:#3fb950;border:1px solid #1e5631;}
    \\.banner-warn{background:#3a2e0d;color:#d29922;border:1px solid #5b4617;}
    \\.banner-fail{background:#3a0d16;color:#f85149;border:1px solid #5b1e28;}
    \\.head-links{grid-column:1/-1;display:flex;gap:8px;margin-top:8px;align-items:center;flex-wrap:wrap;}
    \\.head-link{padding:5px 12px;border:1px solid #30363d;border-radius:5px;color:#8b949e;font-size:0.85rem;}
    \\.head-link:hover{border-color:#58a6ff;color:#c9d1d9;text-decoration:none;}
    \\.head-btn{background:transparent;font-family:inherit;cursor:pointer;}
    \\.head-btn:hover{border-color:#58a6ff;color:#c9d1d9;}
    \\#erc-btn.erc-pass{border-color:#2ea043;color:#3fb950;}
    \\#erc-btn.erc-warn{border-color:#d29922;color:#d29922;}
    \\#erc-btn.erc-err{border-color:#da3633;color:#f85149;}
    \\.kicad-menu{position:relative;}
    \\.kicad-panel{display:none;position:absolute;top:calc(100% + 6px);left:0;z-index:50;background:#161b22;border:1px solid #30363d;border-radius:6px;padding:10px;width:340px;box-shadow:0 8px 24px rgba(0,0,0,0.6);}
    \\.kicad-menu.open .kicad-panel{display:block;}
    \\.kicad-row-btn{display:block;width:100%;text-align:left;padding:6px 10px;background:#21262d;color:#c9d1d9;border:1px solid #30363d;border-radius:4px;font-size:0.8rem;font-family:inherit;cursor:pointer;margin-bottom:6px;}
    \\.kicad-row-btn:hover{background:#30363d;border-color:#58a6ff;}
    \\.kicad-row-btn.kicad-primary{background:#1f6feb;border-color:#388bfd;color:#fff;margin-top:4px;}
    \\.kicad-row-btn.kicad-primary:hover{background:#388bfd;}
    \\.kicad-label{display:block;color:#8b949e;font-size:0.72rem;text-transform:uppercase;letter-spacing:0.04em;margin:6px 0 3px;}
    \\.kicad-input{width:100%;box-sizing:border-box;background:#0d1117;color:#c9d1d9;border:1px solid #30363d;border-radius:4px;padding:5px 8px;font-size:0.78rem;font-family:inherit;margin-bottom:4px;}
    \\.kicad-input:focus{outline:none;border-color:#58a6ff;}
    \\.kicad-check{display:flex;align-items:center;gap:6px;color:#c9d1d9;font-size:0.78rem;margin:4px 0 6px;}
    \\.kicad-sep{height:1px;background:#21262d;margin:8px 0;}
    \\.kicad-status{margin-top:6px;padding:6px 8px;border-radius:4px;font-size:0.74rem;white-space:pre-wrap;font-family:"SF Mono",monospace;color:#8b949e;}
    \\.kicad-status.ok{background:rgba(63,185,80,0.1);color:#3fb950;}
    \\.kicad-status.err{background:rgba(248,81,73,0.1);color:#f85149;}
    \\.sch-section{background:#161b22;border:1px solid #21262d;border-radius:8px;padding:14px 16px;margin-bottom:16px;}
    \\.sch-subsection{margin-left:14px;margin-top:12px;background:#12161d;}
    \\.sch-section.flash,.sch-hub.flash{outline:2px solid #58a6ff;outline-offset:-2px;transition:outline-color .25s;}
    \\.sec-head{display:flex;align-items:center;gap:10px;margin-bottom:8px;}
    \\.sec-desc{margin:4px 0 10px;color:#8b949e;font-size:0.9rem;}
    \\.pill{display:inline-block;padding:1px 8px;border-radius:10px;font-size:0.72rem;font-weight:600;text-transform:uppercase;letter-spacing:0.04em;}
    \\.pill-ok{background:#0d3a1f;color:#3fb950;}
    \\.pill-warn{background:#3a2e0d;color:#d29922;}
    \\.pill-concept{background:#24232e;color:#a89eff;}
    \\.muted{color:#6e7681;}
    \\table{width:100%;border-collapse:collapse;margin:6px 0 12px;}
    \\th,td{text-align:left;padding:6px 10px;border-bottom:1px solid #21262d;font-size:0.88rem;}
    \\th{background:#0d1117;color:#8b949e;font-weight:600;text-transform:uppercase;font-size:0.72rem;letter-spacing:0.04em;}
    \\table.ports{margin-top:2px;}
    \\.sch-hub{border:1px solid #21262d;border-radius:6px;padding:10px 12px;margin:10px 0;background:#0d1117;}
    \\.hub-head{display:flex;align-items:baseline;gap:10px;margin-bottom:6px;}
    \\.hub-comp{color:#8b949e;font-size:0.85rem;font-family:"SF Mono",monospace;}
    \\.hub-val{color:#d29922;font-size:0.85rem;font-family:"SF Mono",monospace;margin-left:auto;}
    \\.hub-inset-wrap{background:#010409;border:1px solid #21262d;border-radius:4px;padding:6px;margin:6px 0;overflow-x:auto;}
    \\.hub-group-block{margin:4px 0 8px;}
    \\.hub-group-block:first-child{margin-top:0;}
    \\.hub-group-label{color:#e8c547;font-size:0.8rem;font-weight:600;margin:4px 0 2px;letter-spacing:0.03em;}
    \\svg.hub-inset{display:block;width:100%;max-width:900px;height:auto;}
    \\svg .component{cursor:pointer;}
    \\svg .net{cursor:pointer;}
    \\svg .pin-stub{cursor:pointer;}
    \\svg .pin-stub.pin-active text{fill:#f85149;font-weight:700;}
    \\svg .net:hover line:not(.hit-area),svg .net:hover polyline:not(.hit-area){stroke:#79c0ff;}
    \\svg .net.net-active line:not(.hit-area),svg .net.net-active polyline:not(.hit-area){stroke:#f85149;stroke-width:2.5;}
    \\svg .net.net-active text{fill:#f85149;}
    \\details.sec-notes{margin:8px 0;}
    \\details summary{cursor:pointer;color:#8b949e;font-size:0.85rem;}
    \\details summary:hover{color:#c9d1d9;}
    \\details ul{margin:6px 0 0 20px;padding:0;}
    \\details li{margin:3px 0;font-size:0.88rem;color:#c9d1d9;line-height:1.45;}
    \\.sch-sidebar{position:sticky;top:0;height:100vh;background:#161b22;border-left:1px solid #30363d;display:flex;flex-direction:column;box-sizing:border-box;}
    \\.sb-search{padding:12px 14px;border-bottom:1px solid #21262d;position:relative;}
    \\.sb-search input{width:100%;padding:8px 10px;border:1px solid #30363d;background:#010409;color:#c9d1d9;border-radius:5px;font-size:0.9rem;box-sizing:border-box;}
    \\.sb-search input:focus{border-color:#58a6ff;outline:none;}
    \\.sb-results{position:absolute;top:100%;left:14px;right:14px;background:#0d1117;border:1px solid #30363d;border-top:none;border-radius:0 0 5px 5px;max-height:340px;overflow-y:auto;display:none;z-index:50;}
    \\.sb-results.open{display:block;}
    \\.sb-result{padding:7px 10px;cursor:pointer;font-size:0.85rem;font-family:"SF Mono",monospace;color:#c9d1d9;border-bottom:1px solid #21262d;display:flex;justify-content:space-between;gap:8px;}
    \\.sb-result:last-child{border-bottom:none;}
    \\.sb-result.selected,.sb-result:hover{background:#1f2937;}
    \\.sb-result-label{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
    \\.sb-result-meta{font-size:0.7rem;color:#6e7681;text-transform:uppercase;letter-spacing:0.04em;flex-shrink:0;align-self:center;}
    \\.sb-result-meta.t-net{color:#e8c547;}
    \\.sb-result-meta.t-comp{color:#58a6ff;}
    \\.sb-result-meta.t-pin{color:#c084fc;}
    \\.sb-result-meta.t-sec{color:#3fb950;}
    \\.sb-detail{flex:1;overflow-y:auto;padding:12px 14px;font-size:0.85rem;}
    \\.sb-detail h4{color:#f0f6fc;font-size:0.85rem;margin:0 0 6px;text-transform:uppercase;letter-spacing:0.05em;}
    \\.sb-detail .sb-back{display:inline-block;color:#58a6ff;cursor:pointer;font-size:0.8rem;margin-bottom:8px;}
    \\.sb-detail .sb-back:hover{text-decoration:underline;}
    \\.sb-list-item{padding:7px 8px;border-bottom:1px solid #21262d;cursor:pointer;border-radius:3px;}
    \\.sb-list-item:hover{background:#1f2937;}
    \\.sb-list-item .sb-li-head{font-family:"SF Mono",monospace;color:#c9d1d9;display:flex;align-items:center;gap:8px;}
    \\.sb-list-item .sb-li-sub{color:#8b949e;font-size:0.78rem;margin-top:2px;}
    \\.sb-cat{display:inline-block;padding:1px 6px;border-radius:8px;font-size:0.65rem;font-weight:700;text-transform:uppercase;letter-spacing:0.05em;line-height:1.4;flex-shrink:0;}
    \\.sb-cat.cat-mcu{background:rgba(31,111,235,0.18);color:#79c0ff;}
    \\.sb-cat.cat-power{background:rgba(218,54,51,0.18);color:#f85149;}
    \\.sb-cat.cat-memory{background:rgba(137,87,229,0.18);color:#b392f0;}
    \\.sb-cat.cat-peripheral{background:rgba(46,160,67,0.18);color:#56d364;}
    \\.sb-cat.cat-connector{background:rgba(210,153,34,0.18);color:#e8c547;}
    \\.sb-cat.cat-clock{background:rgba(68,170,153,0.18);color:#6be6c1;}
    \\.sb-cat.cat-comms{background:rgba(33,150,243,0.18);color:#79c0ff;}
    \\.sb-cat.cat-sensor{background:rgba(46,160,67,0.18);color:#56d364;}
    \\.sb-cat.cat-analog{background:rgba(224,64,251,0.18);color:#e879f9;}
    \\.sb-cat.cat-protection{background:rgba(139,148,158,0.18);color:#c9d1d9;}
    \\.sb-comp-meta{color:#8b949e;font-size:0.78rem;margin:6px 0 10px;}
    \\.sb-pin-row{padding:5px 4px;border-bottom:1px solid #21262d;font-family:"SF Mono",monospace;font-size:0.78rem;display:grid;grid-template-columns:46px 1fr;gap:6px;cursor:pointer;}
    \\.sb-pin-row:hover{background:#1f2937;}
    \\.sb-pin-row.active{background:rgba(248,81,73,0.12);}
    \\.sb-pin-row .sb-pin-id{color:#79c0ff;}
    \\.sb-pin-row .sb-pin-net{color:#e8c547;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
    \\.sb-pin-row .sb-pin-net:hover{text-decoration:underline;color:#f0d75e;}
    \\.sb-net-section{color:#3fb950;font-size:0.72rem;font-weight:600;text-transform:uppercase;letter-spacing:0.05em;margin:10px 0 4px;padding-top:6px;border-top:1px solid #21262d;}
    \\.sb-net-section:first-of-type{border-top:none;padding-top:0;margin-top:6px;}
    \\.sb-net-row{padding:6px 8px;border-radius:4px;cursor:pointer;}
    \\.sb-net-row:hover{background:#1f2937;}
    \\.sb-net-row-head{font-family:"SF Mono",monospace;font-size:0.82rem;}
    \\.sb-net-ref{color:#79c0ff;font-weight:600;}
    \\.sb-net-comp{color:#8b949e;font-size:0.78rem;}
    \\.sb-net-pins{font-family:"SF Mono",monospace;font-size:0.78rem;color:#c9d1d9;margin-top:2px;}
    \\.sb-net-pin{cursor:pointer;color:#c9d1d9;}
    \\.sb-net-pin:hover{color:#f85149;text-decoration:underline;}
    \\.sb-pin-row .sb-pin-fn{color:#8b949e;font-size:0.74rem;}
    \\.sb-pin-row .sb-pin-alt{color:#d2a8ff;}
    \\.sb-comp-link{color:#58a6ff;cursor:pointer;}
    \\.sb-comp-link:hover{text-decoration:underline;}
    \\.sb-pinout-filter{width:100%;box-sizing:border-box;background:#0d1117;color:#c9d1d9;border:1px solid #30363d;border-radius:4px;padding:5px 8px;font-size:0.78rem;font-family:inherit;margin:4px 0 8px;}
    \\.sb-pinout-filter:focus{outline:none;border-color:#58a6ff;}
    \\.sb-pinout-rows{display:flex;flex-direction:column;gap:4px;}
    \\.sb-pinout-row{padding:6px 8px;border:1px solid #21262d;border-radius:4px;font-family:"SF Mono",monospace;font-size:0.78rem;background:#0d1117;}
    \\.sb-pinout-row.is-wired{border-color:#3fb950;background:rgba(63,185,80,0.08);cursor:pointer;}
    \\.sb-pinout-row.is-wired:hover{background:rgba(63,185,80,0.16);}
    \\.sb-pinout-head{display:flex;gap:8px;align-items:baseline;flex-wrap:wrap;}
    \\.sb-pinout-head .sb-pin-id{color:#79c0ff;min-width:40px;}
    \\.sb-pinout-fn{color:#c9d1d9;}
    \\.sb-pinout-net{color:#e8c547;margin-left:auto;font-size:0.74rem;}
    \\.sb-pinout-alts{margin-top:4px;display:flex;gap:4px;flex-wrap:wrap;}
    \\.sb-pinout-alt{color:#d2a8ff;background:rgba(210,168,255,0.1);padding:1px 5px;border-radius:3px;font-size:0.72rem;}
    \\.sb-datasheet{display:flex;align-items:center;flex-wrap:wrap;gap:8px;margin:6px 0 10px;padding:8px 10px;background:#0d1117;border:1px solid #21262d;border-radius:5px;font-size:0.8rem;}
    \\.sb-ds-view{color:#58a6ff;text-decoration:none;}
    \\.sb-ds-view:hover{text-decoration:underline;}
    \\.sb-ds-upload,.sb-ds-replace{color:#c9d1d9;cursor:pointer;padding:3px 8px;background:#21262d;border:1px solid #30363d;border-radius:4px;}
    \\.sb-ds-upload:hover,.sb-ds-replace:hover{border-color:#58a6ff;}
    \\.sb-ds-status{width:100%;font-size:0.74rem;color:#8b949e;font-family:"SF Mono",monospace;}
    \\.sb-ds-status.ok{color:#3fb950;}
    \\.sb-ds-status.err{color:#f85149;}
    \\.sb-empty{color:#6e7681;font-style:italic;}
    \\.erc-ok{color:#3fb950;padding:8px 0;font-size:0.85rem;}
    \\.erc-group-head{margin:10px 0 4px;font-weight:600;font-size:0.78rem;text-transform:uppercase;letter-spacing:0.04em;}
    \\.erc-group-head.err{color:#f85149;}
    \\.erc-group-head.warn{color:#d29922;}
    \\.erc-group-head.info{color:#58a6ff;}
    \\.erc-item{padding:6px 8px;border-radius:4px;font-size:0.78rem;margin-bottom:4px;border-left:3px solid transparent;}
    \\.erc-item.erc-err{color:#f85149;background:rgba(248,81,73,0.08);border-left-color:#da3633;}
    \\.erc-item.erc-warn{color:#d29922;background:rgba(210,153,34,0.08);border-left-color:#d29922;}
    \\.erc-item.erc-info{color:#58a6ff;background:rgba(88,166,255,0.08);border-left-color:#58a6ff;}
    \\.erc-item[data-nav-ref],.erc-item[data-nav-net]{cursor:pointer;}
    \\.erc-item[data-nav-ref]:hover,.erc-item[data-nav-net]:hover{filter:brightness(1.2);}
    \\.erc-tag{color:#8b949e;font-size:0.72rem;font-family:"SF Mono",monospace;}
    \\@media(max-width:900px){.sch-layout{grid-template-columns:1fr;}.sch-sidebar{position:static;height:auto;max-height:50vh;border-left:none;border-top:1px solid #30363d;}}
++ system_svg.SYSTEM_OVERVIEW_CSS;
