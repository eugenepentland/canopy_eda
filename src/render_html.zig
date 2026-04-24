const std = @import("std");
const env_mod = @import("eval/env.zig");
const erc_mod = @import("erc.zig");
const review = @import("review.zig");
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

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);

    try w.writeAll("<!DOCTYPE html><html><head><meta charset=\"utf-8\">");
    try w.writeAll("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">");
    try w.print("<title>{s} — Schematic</title>", .{block.name});
    try w.writeAll("<style>");
    try w.writeAll(navbar_css);
    try w.writeAll(SCHEMATIC_CSS);
    try w.writeAll("</style></head><body>");

    try writeNavbar(w);
    try w.writeAll("<div class=\"sch-wrap\">");
    try writeHeader(w, block.name, design_name, status);
    try writeToolbar(w, design_name);

    for (block.sections) |sec| try writeSection(&ctx, w, allocator, sec, 0);

    // Designs without sections (typical of sub-block-only or flat hub+passives
    // designs like power-6v, pma3-14ln) still deserve a rendering. Emit a
    // synthetic card per sub-block, plus one flat card if any hubs live at
    // the top level outside any section.
    for (block.sub_blocks) |sb| try writeSubBlockCard(&ctx, w, allocator, sb);

    if (block.sections.len == 0 and hasTopLevelHubs(block)) {
        try writeFlatHubs(&ctx, w, allocator, block);
    }

    try w.writeAll("</div>");
    try writeScripts(w, design_name);
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
    try w.print("<a class=\"head-link\" href=\"/pcb/{s}\">PCB</a>", .{design_name});
    try w.print("<a class=\"head-link\" href=\"/review/{s}\">Review</a>", .{design_name});
    try w.print("<a class=\"head-link\" href=\"/schematics/{s}/canvas\">Canvas (legacy)</a>", .{design_name});
    try w.print("<a class=\"head-link\" href=\"/api/export-bom/{s}\">BOM</a>", .{design_name});
    try w.print("<a class=\"head-link\" href=\"/api/export-netlist/{s}\">Netlist</a>", .{design_name});
    try w.writeAll("</div></header>");
}

fn writeToolbar(w: anytype, design_name: []const u8) !void {
    _ = design_name;
    try w.writeAll("<div class=\"sch-tools\">");
    try w.writeAll("<input type=\"search\" id=\"sch-search\" placeholder=\"Search ref, net, or pin…\" autocomplete=\"off\">");
    try w.writeAll("<button type=\"button\" id=\"sch-clear-hl\" class=\"tool-btn\">Clear highlight</button>");
    try w.writeAll("</div>");
}

fn writeSection(ctx: *RenderCtx, w: anytype, allocator: Allocator, sec: Section, depth: u8) !void {
    const indent_class: []const u8 = if (depth == 0) "sch-section" else "sch-section sch-subsection";
    const slug = try review.slugify(allocator, sec.name);
    try w.print("<section class=\"{s}\" id=\"sec-{s}\">", .{ indent_class, slug });

    // Header
    const status_pill: []const u8 = switch (sec.status) {
        .concept => "pill-concept",
        .implemented => "pill-ok",
        .review => "pill-warn",
    };
    try w.writeAll("<div class=\"sec-head\"><h2>");
    try writeHtmlEscaped(w, sec.name);
    try w.print("</h2><span class=\"pill {s}\">{s}</span></div>", .{ status_pill, @tagName(sec.status) });

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

    for (sec.sub_sections) |sub| try writeSection(ctx, w, allocator, sub, depth + 1);

    try w.writeAll("</section>");
}

const HubAnalysis = struct {
    ref: []const u8,
    inst: FlatInst,
    direct: []const PinGroup,
    spoke: []const PinGroup,
};

/// Analyze hubs in a section and decide whether to render them as individual
/// cards or fold them into a single combined pin-map table. We merge when the
/// section has exactly two hubs with only direct pins (no dedicated spokes) —
/// typical of "STM32 GPIOs ↔ expansion connector" style pages where a big
/// table keyed by net is easier to scan than two side-by-side tables.
fn writeSectionHubs(
    ctx: *RenderCtx,
    w: anytype,
    allocator: Allocator,
    pin_groups: []const env_mod.PinGroup,
    hub_refs: []const []const u8,
) !void {
    var analyses: std.ArrayListUnmanaged(HubAnalysis) = .empty;
    defer analyses.deinit(allocator);

    for (hub_refs) |hub_ref| {
        if (try analyzeHub(ctx, allocator, pin_groups, hub_ref)) |a| {
            try analyses.append(allocator, a);
        }
    }

    const mergeable = analyses.items.len == 2 and
        analyses.items[0].spoke.len == 0 and
        analyses.items[1].spoke.len == 0 and
        analyses.items[0].direct.len > 0 and
        analyses.items[1].direct.len > 0;

    if (mergeable) {
        try writeCombinedPinMap(w, allocator, analyses.items[0], analyses.items[1]);
    } else {
        for (analyses.items) |a| try writeHubCardFromAnalysis(ctx, w, a);
    }
}

fn analyzeHub(
    ctx: *RenderCtx,
    allocator: Allocator,
    pin_groups: []const env_mod.PinGroup,
    hub_ref: []const u8,
) !?HubAnalysis {
    const hub_inst = ctx.inst_map.get(hub_ref) orelse return null;

    var pin_ids: std.ArrayListUnmanaged([]const u8) = .empty;
    defer pin_ids.deinit(allocator);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    var from_pin_groups = false;
    for (pin_groups) |pg| {
        if (!std.mem.eql(u8, pg.ref_des, hub_ref)) continue;
        from_pin_groups = true;
        for (pg.pins) |pp| {
            if (seen.contains(pp.pin)) continue;
            try seen.put(allocator, pp.pin, {});
            try pin_ids.append(allocator, pp.pin);
        }
    }
    if (!from_pin_groups) {
        if (ctx.adjacency.get(hub_ref)) |adj| {
            for (adj.items) |ae| {
                if (seen.contains(ae.pin)) continue;
                try seen.put(allocator, ae.pin, {});
                try pin_ids.append(allocator, ae.pin);
            }
        }
    }
    if (pin_ids.items.len == 0) return null;

    std.mem.sortUnstable([]const u8, pin_ids.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return pinOrder(a, b);
        }
    }.lt);

    const adj_entries = if (ctx.adjacency.get(hub_ref)) |list| list.items else &[_]AdjEntry{};
    var pn_map = hub_mod.buildPinNameMap(ctx, hub_inst.parts);
    defer pn_map.deinit(allocator);
    const all_groups = try hub_mod.groupHubPins(ctx, pin_ids.items, adj_entries, &pn_map);
    const partition = try section_inset.partitionGroups(allocator, ctx, hub_ref, all_groups);

    return .{
        .ref = hub_ref,
        .inst = hub_inst,
        .direct = partition.direct,
        .spoke = partition.spoke,
    };
}

fn writeHubCardFromAnalysis(ctx: *RenderCtx, w: anytype, a: HubAnalysis) !void {
    try w.writeAll("<div class=\"sch-hub\"><div class=\"hub-head\"><h3><code>");
    try writeHtmlEscaped(w, a.inst.ref_des);
    try w.writeAll("</code></h3><span class=\"hub-comp\">");
    try writeHtmlEscaped(w, a.inst.component);
    try w.writeAll("</span>");
    if (a.inst.value.len > 0 and !std.mem.eql(u8, a.inst.value, a.inst.component)) {
        try w.writeAll("<span class=\"hub-val\">");
        try writeHtmlEscaped(w, a.inst.value);
        try w.writeAll("</span>");
    }
    try w.writeAll("</div>");

    if (a.spoke.len > 0) {
        try w.writeAll("<div class=\"hub-inset-wrap\">");
        try section_inset.renderHubInset(ctx, w, a.inst, a.spoke);
        try w.writeAll("</div>");
    }
    if (a.direct.len > 0) try writePinTable(w, a.direct);

    try w.writeAll("</div>");
}

/// Emit a side-by-side pin-map table when a section contains two pure-direct
/// hubs. Every unique net appearing in either hub becomes a row; nets only on
/// one side get a muted placeholder on the other. Sorted by net name.
fn writeCombinedPinMap(w: anytype, allocator: Allocator, a: HubAnalysis, b: HubAnalysis) !void {
    const Row = struct {
        net: []const u8,
        a_pins: []const u8,
        a_fn: []const u8,
        b_pins: []const u8,
        b_fn: []const u8,
    };

    var map: std.StringHashMapUnmanaged(Row) = .empty;
    defer map.deinit(allocator);

    for (a.direct) |g| {
        const net = firstNet(g);
        if (net.len == 0) continue;
        const gop = try map.getOrPut(allocator, net);
        if (!gop.found_existing) gop.value_ptr.* = .{
            .net = net,
            .a_pins = "",
            .a_fn = "",
            .b_pins = "",
            .b_fn = "",
        };
        gop.value_ptr.a_pins = g.pin_numbers;
        gop.value_ptr.a_fn = g.display_name;
    }
    for (b.direct) |g| {
        const net = firstNet(g);
        if (net.len == 0) continue;
        const gop = try map.getOrPut(allocator, net);
        if (!gop.found_existing) gop.value_ptr.* = .{
            .net = net,
            .a_pins = "",
            .a_fn = "",
            .b_pins = "",
            .b_fn = "",
        };
        gop.value_ptr.b_pins = g.pin_numbers;
        gop.value_ptr.b_fn = g.display_name;
    }

    var rows: std.ArrayListUnmanaged(Row) = .empty;
    defer rows.deinit(allocator);
    var it = map.valueIterator();
    while (it.next()) |row| try rows.append(allocator, row.*);
    std.mem.sortUnstable(Row, rows.items, {}, struct {
        fn lt(_: void, x: Row, y: Row) bool {
            return std.mem.order(u8, x.net, y.net) == .lt;
        }
    }.lt);

    try w.writeAll("<div class=\"sch-hub sch-hub-merged\"><div class=\"hub-head\">");
    try w.writeAll("<h3><code>");
    try writeHtmlEscaped(w, a.inst.ref_des);
    try w.writeAll("</code> ↔ <code>");
    try writeHtmlEscaped(w, b.inst.ref_des);
    try w.writeAll("</code></h3><span class=\"hub-comp\">");
    try writeHtmlEscaped(w, a.inst.component);
    try w.writeAll(" · ");
    try writeHtmlEscaped(w, b.inst.component);
    try w.writeAll("</span></div>");

    try w.writeAll("<table class=\"pins pins-merged\"><thead><tr>");
    try w.print("<th colspan=\"2\">{s}</th><th>Net</th><th colspan=\"2\">{s}</th>", .{ a.inst.ref_des, b.inst.ref_des });
    try w.writeAll("</tr><tr><th>Pin</th><th>Function</th><th></th><th>Pin</th><th>Function</th></tr></thead><tbody>");

    for (rows.items) |r| {
        try w.print("<tr data-net=\"{s}\">", .{r.net});
        try w.writeAll("<td class=\"pin-nums\">");
        if (r.a_pins.len > 0) {
            try w.writeAll("<code>");
            try writeHtmlEscaped(w, r.a_pins);
            try w.writeAll("</code>");
        } else {
            try w.writeAll("<span class=\"muted\">—</span>");
        }
        try w.writeAll("</td><td>");
        if (r.a_fn.len > 0) try writeHtmlEscaped(w, r.a_fn) else try w.writeAll("<span class=\"muted\">—</span>");
        try w.writeAll("</td><td><code>");
        try writeHtmlEscaped(w, r.net);
        try w.writeAll("</code></td><td class=\"pin-nums\">");
        if (r.b_pins.len > 0) {
            try w.writeAll("<code>");
            try writeHtmlEscaped(w, r.b_pins);
            try w.writeAll("</code>");
        } else {
            try w.writeAll("<span class=\"muted\">—</span>");
        }
        try w.writeAll("</td><td>");
        if (r.b_fn.len > 0) try writeHtmlEscaped(w, r.b_fn) else try w.writeAll("<span class=\"muted\">—</span>");
        try w.writeAll("</td></tr>");
    }

    try w.writeAll("</tbody></table></div>");
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
fn writeSubBlockCard(ctx: *RenderCtx, w: anytype, allocator: Allocator, sb: env_mod.SubBlock) !void {
    const slug = try review.slugify(allocator, sb.name);
    try w.print("<section class=\"sch-section\" id=\"sec-{s}\">", .{slug});
    try w.writeAll("<div class=\"sec-head\"><h2>");
    try writeHtmlEscaped(w, sb.name);
    try w.writeAll("</h2><span class=\"pill pill-ok\">sub-block</span></div>");
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

    try w.writeAll("</section>");
}

/// Fallback rendering for designs that declare instances directly in
/// `design-block` without any `section` wrapper (e.g. pma3-14ln). Every
/// hub-prefixed top-level instance becomes its own card inside one synthetic
/// section.
fn writeFlatHubs(ctx: *RenderCtx, w: anytype, allocator: Allocator, block: *const DesignBlock) !void {
    try w.writeAll("<section class=\"sch-section\" id=\"sec-design\"><div class=\"sec-head\"><h2>");
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

    try writeSectionHubs(ctx, w, allocator, &.{}, hub_refs.items);

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

fn writePinTable(w: anytype, groups: []const PinGroup) !void {
    try w.writeAll("<table class=\"pins\"><thead><tr><th>Pins</th><th>Function</th><th>Net</th></tr></thead><tbody>");
    for (groups) |g| {
        // Find the first .net endpoint for the net column — every pin in a
        // direct group shares the same net, so peeking the first is enough.
        var net_name: []const u8 = "";
        for (g.conns) |c| switch (c.endpoint) {
            .net => |n| {
                net_name = n;
                break;
            },
            .pin => {},
        };
        try w.print("<tr data-net=\"{s}\"><td class=\"pin-nums\"><code>", .{net_name});
        try writeHtmlEscaped(w, g.pin_numbers);
        try w.writeAll("</code></td><td>");
        try writeHtmlEscaped(w, g.display_name);
        try w.writeAll("</td><td><code>");
        try writeHtmlEscaped(w, net_name);
        try w.writeAll("</code></td></tr>");
    }
    try w.writeAll("</tbody></table>");
}

fn writeScripts(w: anytype, design_name: []const u8) !void {
    try w.writeAll("<script>var DESIGN_NAME=");
    try writeJsString(w, design_name);
    try w.writeAll(";</script><script>");
    try w.writeAll(SCHEMATIC_JS);
    try w.writeAll("</script>");
}

fn writeJsString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        else => try w.writeByte(c),
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
    \\body{margin:0;background:#0d1117;color:#c9d1d9;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;}
    \\code{font-family:"SF Mono","Fira Code",monospace;font-size:0.9em;color:#c9d1d9;background:#161b22;padding:1px 5px;border-radius:3px;}
    \\a{color:#58a6ff;text-decoration:none;}a:hover{text-decoration:underline;}
    \\.sch-wrap{max-width:1200px;margin:0 auto;padding:24px 20px 48px;}
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
    \\.head-links{grid-column:1/-1;display:flex;gap:8px;margin-top:8px;}
    \\.head-link{padding:5px 12px;border:1px solid #30363d;border-radius:5px;color:#8b949e;font-size:0.85rem;}
    \\.head-link:hover{border-color:#58a6ff;color:#c9d1d9;text-decoration:none;}
    \\.sch-tools{display:flex;gap:8px;margin:16px 0 8px;align-items:center;position:sticky;top:0;background:#0d1117;padding:8px 0;z-index:10;border-bottom:1px solid #21262d;}
    \\#sch-search{flex:1;max-width:360px;padding:7px 10px;border:1px solid #30363d;background:#010409;color:#c9d1d9;border-radius:5px;font-size:0.9rem;}
    \\#sch-search:focus{border-color:#58a6ff;outline:none;}
    \\.tool-btn{padding:7px 12px;border:1px solid #30363d;background:#21262d;color:#c9d1d9;border-radius:5px;cursor:pointer;font-size:0.85rem;}
    \\.tool-btn:hover{background:#30363d;border-color:#58a6ff;}
    \\.sch-section{background:#161b22;border:1px solid #21262d;border-radius:8px;padding:14px 16px;margin-bottom:16px;}
    \\.sch-subsection{margin-left:14px;margin-top:12px;background:#12161d;}
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
    \\table.pins td{font-family:"SF Mono","Fira Code",monospace;font-size:0.85rem;}
    \\table.pins .pin-nums{color:#79c0ff;}
    \\table.pins-merged th[colspan="2"]{text-align:center;color:#58a6ff;}
    \\table.pins-merged td:nth-child(3){text-align:center;}
    \\.sch-hub-merged .hub-head h3 code{color:#79c0ff;}
    \\.sch-hub{border:1px solid #21262d;border-radius:6px;padding:10px 12px;margin:10px 0;background:#0d1117;}
    \\.hub-head{display:flex;align-items:baseline;gap:10px;margin-bottom:6px;}
    \\.hub-comp{color:#8b949e;font-size:0.85rem;font-family:"SF Mono",monospace;}
    \\.hub-val{color:#d29922;font-size:0.85rem;font-family:"SF Mono",monospace;margin-left:auto;}
    \\.hub-inset-wrap{background:#010409;border:1px solid #21262d;border-radius:4px;padding:6px;margin:6px 0;overflow-x:auto;}
    \\svg.hub-inset{display:block;width:100%;max-width:900px;height:auto;}
    \\svg .component{cursor:pointer;}
    \\svg .net{cursor:pointer;}
    \\svg .net:hover line:not(.hit-area),svg .net:hover polyline:not(.hit-area){stroke:#79c0ff;}
    \\svg .net.net-active line:not(.hit-area),svg .net.net-active polyline:not(.hit-area){stroke:#f85149;}
    \\svg .net.net-active text{fill:#f85149;}
    \\table.pins tr.row-highlight{background:rgba(248,81,73,0.12);}
    \\table.pins tr.row-hidden,section.sch-section.row-hidden{display:none;}
    \\details.sec-notes{margin:8px 0;}
    \\details summary{cursor:pointer;color:#8b949e;font-size:0.85rem;}
    \\details summary:hover{color:#c9d1d9;}
    \\details ul{margin:6px 0 0 20px;padding:0;}
    \\details li{margin:3px 0;font-size:0.88rem;color:#c9d1d9;line-height:1.45;}
;

// Highlight, search, and 2s version-poll. Plain JS, no framework.
const SCHEMATIC_JS =
    \\(function(){
    \\  function netOf(el){
    \\    while(el && el !== document){ if(el.dataset && el.dataset.net) return el.dataset.net; el=el.parentNode; }
    \\    return null;
    \\  }
    \\  function clearNetHighlight(){
    \\    document.querySelectorAll('.net-active').forEach(function(n){n.classList.remove('net-active');});
    \\    document.querySelectorAll('tr.row-highlight').forEach(function(n){n.classList.remove('row-highlight');});
    \\  }
    \\  function setNetHighlight(net){
    \\    clearNetHighlight();
    \\    if(!net) return;
    \\    document.querySelectorAll('svg .net').forEach(function(n){ if(n.dataset.net===net) n.classList.add('net-active'); });
    \\    document.querySelectorAll('table.pins tr').forEach(function(r){ if(r.dataset.net===net) r.classList.add('row-highlight'); });
    \\  }
    \\  document.addEventListener('click', function(e){
    \\    var n = netOf(e.target);
    \\    if(n) setNetHighlight(n);
    \\  });
    \\  var clear = document.getElementById('sch-clear-hl');
    \\  if(clear) clear.addEventListener('click', clearNetHighlight);
    \\  // Search: filter section cards and pin rows by text.
    \\  var search = document.getElementById('sch-search');
    \\  if(search) search.addEventListener('input', function(){
    \\    var q = search.value.trim().toLowerCase();
    \\    var sections = document.querySelectorAll('section.sch-section');
    \\    sections.forEach(function(sec){
    \\      var hay = sec.textContent.toLowerCase();
    \\      if(q.length === 0 || hay.indexOf(q) !== -1) sec.classList.remove('row-hidden');
    \\      else sec.classList.add('row-hidden');
    \\    });
    \\  });
    \\  // Live-reload on version bump.
    \\  var lastVersion = null;
    \\  function poll(){
    \\    fetch('/api/version/'+DESIGN_NAME).then(function(r){return r.json();}).then(function(j){
    \\      if(lastVersion === null){ lastVersion = j.version; return; }
    \\      if(j.version !== lastVersion){ window.location.reload(); }
    \\    }).catch(function(){});
    \\  }
    \\  setInterval(poll, 2000);
    \\  poll();
    \\})();
;
