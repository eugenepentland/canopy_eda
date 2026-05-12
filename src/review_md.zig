//! Static markdown export of the design-review page. Produces a single
//! self-contained `.md` document containing the system block diagram,
//! per-section schematic SVGs, BOM stub, power budget/sequencing tables,
//! test points, ERC violations, per-IC requirement checklist, and the
//! verbatim source file. Intended companion to `<name>-bom.csv`.
//!
//! The markdown embeds inline `<svg>` and a leading `<style>` block;
//! GitHub, VSCode preview, Obsidian, mdBook, and pandoc all render it.

const std = @import("std");
const env_mod = @import("eval/env.zig");
const erc_mod = @import("erc.zig");
const review = @import("review.zig");
const req_checks = @import("req_checks.zig");
const power_budget = @import("eval/power_budget.zig");
const power_sequencing = @import("eval/power_sequencing.zig");
const system_svg = @import("render_system_svg.zig");
const render_html = @import("render_html.zig");

const DesignBlock = env_mod.DesignBlock;
const Section = env_mod.Section;
const Allocator = std.mem.Allocator;
const CheckResultMap = std.StringHashMapUnmanaged([]req_checks.Result);

/// Render a full design-review markdown package.
///
/// `source` is the verbatim contents of the design's `.sexp` file (embedded
/// at the bottom of the markdown as a fenced code block); pass empty to
/// suppress that section. `check_results` is the same map produced by
/// `req_checks.runChecks` + `applyVerifications` — drives the per-IC
/// checklist's pass/fail/verified/pending classification.
pub fn renderToMarkdown(
    allocator: Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    design_name: []const u8,
    doc: review.ReviewDoc,
    source: []const u8,
    check_results: *const CheckResultMap,
) (std.mem.Allocator.Error || std.Io.Writer.Error)![]const u8 {
    var ctx = try render_html.setupRenderCtx(allocator, block);
    ctx.project_dir = project_dir;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);

    // Title + generation timestamp
    try w.print("# Design Review: {s}\n\n", .{design_name});
    try w.print("*Generated {s} by Canopy EDA*\n\n", .{doc.generated_at});

    // CSS subset for the inline SVGs that follow. Must come before any
    // <svg> body. Reuses the page's curated subset (no JS hooks).
    try w.writeAll("<style>\n");
    try w.writeAll(render_html.STATIC_SVG_CSS);
    try w.writeAll("\n");
    try w.writeAll(system_svg.SYSTEM_OVERVIEW_CSS);
    try w.writeAll("\n</style>\n\n");

    try writeSummary(w, doc.summary);
    try writeSystemDiagram(allocator, w, block);
    try writePowerBudget(w, doc.power_budget);
    try writePowerSequence(w, doc.power_sequence);
    try writeTestPoints(w, doc.test_points);
    try writeErc(w, doc.unresolved);
    try writeAssertions(w, doc.assertions);
    try writeSchematicSections(allocator, &ctx, w, block, check_results);
    try writeRequirementChecklist(w, doc.sections, check_results);
    try writeBomStub(w, design_name, doc.bom);
    try writeSource(w, source);

    return buf.toOwnedSlice(allocator);
}

// ── Sections ──────────────────────────────────────────────────────────

fn writeSummary(w: anytype, s: review.Summary) !void {
    try w.writeAll("## Summary\n\n");
    const verdict: []const u8 = switch (s.status) {
        .pass => "PASS",
        .warn => "WARN",
        .fail => "FAIL",
    };
    try w.print("- **Status**: {s}\n", .{verdict});
    try w.print("- **Sections**: {d} · **Instances**: {d} · **Nets**: {d}\n", .{ s.section_count, s.instance_count, s.net_count });
    try w.print("- **ERC**: {d} error(s), {d} warning(s), {d} info\n", .{ s.violation_error, s.violation_warning, s.violation_info });
    try w.print("- **Assertions**: {d} pass, {d} warn, {d} fail\n", .{ s.assertion_pass, s.assertion_warn, s.assertion_fail });
    try w.print("- **Critical components**: {d}/{d} have requirements\n", .{ s.critical_with_requirements, s.critical_count });
    try w.writeAll("\n");
}

fn writeSystemDiagram(allocator: Allocator, w: anytype, block: *const DesignBlock) !void {
    try w.writeAll("## System Block Diagram\n\n");
    try system_svg.renderSystemOverviewSvg(allocator, block, w);
    try w.writeAll("\n\n");
}

fn writePowerBudget(w: anytype, rails: []const power_budget.Rail) !void {
    try w.writeAll("## Power Budget\n\n");
    if (rails.len == 0) {
        try w.writeAll("*No power rails detected.*\n\n");
        return;
    }
    try w.writeAll("| Rail | Source | Source typ (A) | Source max (A) | Load typ (A) | Load max (A) | Margin | Status |\n");
    try w.writeAll("|------|--------|----------------|----------------|--------------|--------------|--------|--------|\n");
    for (rails) |r| {
        const src = if (r.source_label.len > 0) r.source_label else "—";
        try w.print("| `{s}` | {s} | ", .{ r.net, src });
        try writeFloatOrDash(w, r.source_typ_a);
        try w.writeAll(" | ");
        try writeFloatOrDash(w, r.source_max_a);
        try w.print(" | {d:.4} | {d:.4} | ", .{ r.load_typ_a, r.load_max_a });
        if (r.margin_pct) |m| try w.print("{d:.0}%", .{m}) else try w.writeAll("—");
        try w.print(" | {s} |\n", .{@tagName(r.status)});
    }
    try w.writeAll("\n");
}

fn writePowerSequence(w: anytype, rows: []const power_sequencing.SequenceRow) !void {
    try w.writeAll("## Power Sequencing\n\n");
    if (rows.len == 0) {
        try w.writeAll("*No power-up dependencies detected.*\n\n");
        return;
    }
    try w.writeAll("| # | Rail | Source | Enable | Depends on | Via | Status |\n");
    try w.writeAll("|---|------|--------|--------|------------|-----|--------|\n");
    for (rows) |row| {
        try w.print("| {d} | `{s}` | {s} | ", .{ row.order, row.rail, dashIfEmpty(row.source) });
        try w.print("{s} | {s} | {s} | {s} |\n", .{
            dashIfEmpty(row.enable),
            dashIfEmpty(row.depends_on),
            dashIfEmpty(row.via),
            @tagName(row.status),
        });
    }
    try w.writeAll("\n");
}

fn writeTestPoints(w: anytype, tps: []const review.TestPointEntry) !void {
    try w.writeAll("## Test Points (Bring-Up)\n\n");
    if (tps.len == 0) {
        try w.writeAll("*No test points declared.*\n\n");
        return;
    }
    try w.writeAll("| Ref | Net | Purpose |\n");
    try w.writeAll("|-----|-----|---------|\n");
    for (tps) |tp| {
        try w.print("| `{s}` | `{s}` | {s} |\n", .{ tp.ref_des, tp.net, dashIfEmpty(tp.purpose) });
    }
    try w.writeAll("\n");
}

fn writeErc(w: anytype, violations: []const erc_mod.Violation) !void {
    try w.writeAll("## ERC Check\n\n");
    if (violations.len == 0) {
        try w.writeAll("✓ 0 violations.\n\n");
        return;
    }
    try w.writeAll("| Severity | Kind | Ref | Net | Message |\n");
    try w.writeAll("|----------|------|-----|-----|---------|\n");
    for (violations) |v| {
        try w.print("| {s} | {s} | {s} | {s} | ", .{
            @tagName(v.severity),
            @tagName(v.kind),
            dashIfEmpty(v.ref_des),
            dashIfEmpty(v.net),
        });
        try writeMdEscaped(w, v.message);
        try w.writeAll(" |\n");
    }
    try w.writeAll("\n");
}

fn writeAssertions(w: anytype, asserts: []const review.AssertionReport) !void {
    if (asserts.len == 0) return;
    try w.writeAll("## Assertions\n\n");
    try w.writeAll("| Status | Message |\n");
    try w.writeAll("|--------|---------|\n");
    for (asserts) |a| {
        try w.print("| {s} | ", .{@tagName(a.status)});
        try writeMdEscaped(w, a.message);
        try w.writeAll(" |\n");
    }
    try w.writeAll("\n");
}

fn writeSchematicSections(
    allocator: Allocator,
    ctx: anytype,
    w: anytype,
    block: *const DesignBlock,
    check_results: *const CheckResultMap,
) !void {
    try w.writeAll("## Schematic\n\n");
    for (block.sections) |sec| {
        try writeSchematicSection(allocator, ctx, w, sec, 3, check_results);
        for (sec.sub_sections) |sub| {
            try writeSchematicSection(allocator, ctx, w, sub, 4, check_results);
        }
    }
    for (block.sub_blocks) |sb| {
        try w.print("### {s} *(sub-block)*\n\n", .{sb.name});
        if (sb.block.name.len > 0) {
            try w.print("*{s}*\n\n", .{sb.block.name});
        }
        for (sb.block.instances) |inst| {
            const fi = .{
                .ref_des = inst.ref_des,
                .component = inst.component,
                .value = inst.value,
                .symbol = inst.symbol,
                .parts = inst.parts,
            };
            _ = fi;
            try writeHubBlock(allocator, ctx, w, &.{}, inst.ref_des, inst.component, inst.value);
        }
    }
}

fn writeSchematicSection(
    allocator: Allocator,
    ctx: anytype,
    w: anytype,
    sec: Section,
    heading_level: u8,
    check_results: *const CheckResultMap,
) !void {
    _ = check_results;
    try writeHeading(w, heading_level, sec.name);
    if (sec.description.len > 0) {
        try writeMdEscaped(w, sec.description);
        try w.writeAll("\n\n");
    }
    // Per-section status pill (concept / implemented / review)
    try w.print("**Section status:** {s}\n\n", .{@tagName(sec.status)});

    // Hubs declared inline + via (pins ...) attachment
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    for (sec.pin_groups) |pg| {
        if (seen.contains(pg.ref_des)) continue;
        try seen.put(allocator, pg.ref_des, {});
        const inst = lookupInstance(ctx, pg.ref_des) orelse continue;
        try writeHubBlock(allocator, ctx, w, sec.pin_groups, pg.ref_des, inst.component, inst.value);
    }
    for (sec.instances) |inst| {
        if (seen.contains(inst.ref_des)) continue;
        try seen.put(allocator, inst.ref_des, {});
        try writeHubBlock(allocator, ctx, w, sec.pin_groups, inst.ref_des, inst.component, inst.value);
    }

    if (sec.notes.len > 0) {
        try w.writeAll("**Notes**\n\n");
        for (sec.notes) |n| {
            try w.writeAll("- ");
            try writeMdEscaped(w, n.text);
            if (n.ref) |r| {
                try w.print(" *({s}", .{r.pdf});
                if (r.page > 0) try w.print(" p.{d}", .{r.page});
                try w.writeAll(")*");
            }
            try w.writeAll("\n");
        }
        try w.writeAll("\n");
    }
}

/// One IC's heading + inline SVG. SVG is wrapped in `<details>` collapsed
/// by default so the markdown opens compact and reviewers expand only
/// what they need to inspect. Comment out the `<details>` wrap to flatten.
fn writeHubBlock(
    allocator: Allocator,
    ctx: anytype,
    w: anytype,
    pin_groups: []const env_mod.PinGroup,
    ref_des: []const u8,
    component: []const u8,
    value: []const u8,
) !void {
    try w.print("<details><summary><strong><code>{s}</code></strong> · {s}", .{ ref_des, component });
    if (value.len > 0) try w.print(" · {s}", .{value});
    try w.writeAll("</summary>\n\n");
    var sub_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer sub_buf.deinit(allocator);
    const sw = sub_buf.writer(allocator);
    const rendered = render_html.renderHubSvg(ctx, sw, allocator, pin_groups, ref_des) catch false;
    if (rendered) {
        try w.writeAll(sub_buf.items);
    } else {
        try w.writeAll("*No schematic body — only passives or no pin groupings declared.*\n");
    }
    try w.writeAll("\n</details>\n\n");
}

fn writeRequirementChecklist(
    w: anytype,
    sections: []const review.SectionReport,
    check_results: *const CheckResultMap,
) !void {
    try w.writeAll("## Per-IC Requirement Checklist\n\n");
    var emitted = false;
    for (sections) |sec| {
        for (sec.component_requirements) |entry| {
            if (entry.requirements.len == 0) continue;
            emitted = true;
            try w.print("### `{s}` — {s}\n\n", .{ entry.ref_des, entry.component });

            // Worst → best ordering, mirrors the live page's hub-card sort.
            // Build a [(req_idx, sort_key)] list and sort.
            const SortItem = struct { idx: usize, key: u8 };
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const sorted = a.alloc(SortItem, entry.requirements.len) catch continue;
            for (entry.requirements, 0..) |_, i| {
                const status: req_checks.Status = if (i < entry.req_results.len) entry.req_results[i].status else .na;
                const has_v = (i < entry.req_results.len) and (entry.req_results[i].verification != null);
                sorted[i] = .{ .idx = i, .key = sortKey(status, has_v) };
            }
            std.mem.sortUnstable(SortItem, sorted, {}, struct {
                fn lt(_: void, x: SortItem, y: SortItem) bool {
                    if (x.key != y.key) return x.key < y.key;
                    return x.idx < y.idx;
                }
            }.lt);

            for (sorted) |it| {
                const i = it.idx;
                const r = entry.requirements[i];
                const status: req_checks.Status = if (i < entry.req_results.len) entry.req_results[i].status else .na;
                const msg: []const u8 = if (i < entry.req_results.len) entry.req_results[i].message else "";
                const verification: ?env_mod.Verification = if (i < entry.req_results.len) entry.req_results[i].verification else null;

                const badge: []const u8 = switch (status) {
                    .pass => "✓ **PASS**",
                    .verified => "✓ **VERIFIED**",
                    .na => "⚠ **PENDING**",
                    .fail => if (verification != null) "✗ **FAIL** *(overridden)*" else "✗ **FAIL**",
                };
                try w.print("- {s} — ", .{badge});
                try writeMdEscaped(w, r.text);
                if (r.ref) |ref| {
                    try w.print(" *({s}", .{ref.pdf});
                    if (ref.page > 0) try w.print(" p.{d}", .{ref.page});
                    try w.writeAll(")*");
                }
                if (msg.len > 0) {
                    try w.writeAll("\n  - check: `");
                    try writeMdEscaped(w, msg);
                    try w.writeAll("`");
                }
                if (verification) |v| {
                    try w.writeAll("\n  - sign-off: ");
                    try writeMdEscaped(w, v.rationale);
                    if (v.signed_by.len > 0) {
                        try w.writeAll(" — *");
                        try writeMdEscaped(w, v.signed_by);
                        if (v.date.len > 0) {
                            try w.print(", {s}", .{v.date});
                        }
                        try w.writeAll("*");
                    }
                }
                try w.writeAll("\n");
            }
            try w.writeAll("\n");
        }
    }
    if (!emitted) try w.writeAll("*No requirement-bearing components in this design.*\n\n");
    _ = check_results;
}

fn writeBomStub(w: anytype, design_name: []const u8, bom: []const review.BomGroup) !void {
    var total: usize = 0;
    for (bom) |g| total += g.entries.len;
    try w.print("## Bill of Materials\n\nSee attached `{s}-bom.csv` ({d} parts in {d} groups).\n\n", .{ design_name, total, bom.len });
}

fn writeSource(w: anytype, source: []const u8) !void {
    try w.writeAll("## Source\n\n");
    if (source.len == 0) {
        try w.writeAll("*Source file unavailable.*\n");
        return;
    }
    try w.writeAll("```scheme\n");
    try w.writeAll(source);
    if (source.len > 0 and source[source.len - 1] != '\n') try w.writeAll("\n");
    try w.writeAll("```\n");
}

// ── Helpers ───────────────────────────────────────────────────────────

fn sortKey(status: req_checks.Status, has_verification: bool) u8 {
    return switch (status) {
        .fail => if (has_verification) @as(u8, 1) else @as(u8, 0),
        .na => 2,
        .verified => 3,
        .pass => 4,
    };
}

fn writeHeading(w: anytype, level: u8, text: []const u8) !void {
    var i: u8 = 0;
    while (i < level) : (i += 1) try w.writeAll("#");
    try w.writeAll(" ");
    try writeMdEscaped(w, text);
    try w.writeAll("\n\n");
}

fn dashIfEmpty(s: []const u8) []const u8 {
    return if (s.len == 0) "—" else s;
}

fn writeFloatOrDash(w: anytype, v: ?f64) !void {
    if (v) |x| try w.print("{d:.4}", .{x}) else try w.writeAll("—");
}

/// Escape characters that would break markdown formatting in inline text.
/// Keeps things conservative — only the table-cell + leading-bracket cases.
/// Code blocks (\`\`\`) and inline code (\`) handle their own escaping.
fn writeMdEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| switch (c) {
        '|' => try w.writeAll("\\|"),
        '\n' => try w.writeAll(" "),
        else => try w.writeByte(c),
    };
}

fn lookupInstance(ctx: anytype, ref_des: []const u8) ?env_mod.Instance {
    const fi = ctx.inst_map.get(ref_des) orelse return null;
    return env_mod.Instance{
        .ref_des = fi.ref_des,
        .component = fi.component,
        .value = fi.value,
        .symbol = fi.symbol,
        .footprint = "",
        .parts = fi.parts,
    };
}

// spec: review_md - emits markdown header for design name
test "renderToMarkdown header" {
    // Smoke test: ensure the function compiles and handles an empty doc.
    // A full integration test lives in the e2e curl/unzip checks.
    const allocator = std.testing.allocator;
    var block: DesignBlock = .{
        .name = "test",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const doc: review.ReviewDoc = .{
        .design_name = "test",
        .title = "test",
        .generated_at = "2026-01-01T00:00:00Z",
        .summary = .{
            .status = .pass,
            .section_count = 0,
            .instance_count = 0,
            .net_count = 0,
            .violation_error = 0,
            .violation_warning = 0,
            .violation_info = 0,
            .assertion_pass = 0,
            .assertion_warn = 0,
            .assertion_fail = 0,
        },
        .sections = &.{},
        .power_budget = &.{},
        .power_sequence = &.{},
        .test_points = &.{},
        .bom = &.{},
        .assertions = &.{},
        .unresolved = &.{},
    };
    var map: CheckResultMap = .empty;
    const out = try renderToMarkdown(allocator, &block, "/tmp", "test", doc, "", &map);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "# Design Review: test") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "## Summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "## Source") != null);
}
