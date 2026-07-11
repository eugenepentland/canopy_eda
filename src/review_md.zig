//! Static markdown export of the design-review page — the human/agent-readable
//! twin of what the schematic page shows. One `.md` document with: a status
//! summary, the block overview (the page's lead grouped-cards diagram), a
//! validation block (ERC + assertions + per-IC requirement checks), the power
//! budget/sequencing + test-point tables, and the per-section schematic SVGs.
//! The verbatim `.sexp` source is NOT embedded — the export zip already ships
//! every source file separately.
//!
//! The markdown embeds inline `<svg>` and a leading `<style>` block;
//! GitHub, VSCode preview, Obsidian, mdBook, and pandoc all render it. Per-hub
//! SVGs are compacted (dead interactive markup stripped, one line each) so the
//! document stays scannable — see `writeCompactSvg`.

const std = @import("std");
const env_mod = @import("eval/env.zig");
const erc_mod = @import("erc.zig");
const review = @import("review.zig");
const req_checks = @import("req_checks.zig");
const power_budget = @import("eval/power_budget.zig");
const power_sequencing = @import("eval/power_sequencing.zig");
const block_diagram = @import("diagram/diagram.zig");
const membership = @import("diagram/membership.zig");
const render_html = @import("render_html.zig");
const draw = @import("render_svg/draw.zig");
const escape = @import("escape.zig");

const DesignBlock = env_mod.DesignBlock;
const Section = env_mod.Section;
const Allocator = std.mem.Allocator;
const RenderCtx = @import("render_svg/context.zig").RenderCtx;

/// Render the design-review markdown document.
///
/// Mirrors the schematic page: a status summary, the system block diagram,
/// the validation block (ERC + assertions + per-IC requirement checks), the
/// power / test-point tables, and the per-section schematic SVGs. The verbatim
/// `.sexp` source is NOT embedded — the export zip already carries every
/// source file as a separate, diffable entry. `check_results` is the same map
/// produced by `req_checks.runChecks` + `applyVerifications`, driving the
/// requirement checks' pass/fail/verified/pending classification.
///
/// Validation (ERC, assertions, requirements) is placed up top, before the
/// long visual schematic, so a reviewer — human or agent — reads the verdict
/// first. The per-hub SVGs are compacted (dead interactive markup stripped,
/// one line each) so the document stays scannable instead of ballooning into
/// thousands of lines of pretty-printed SVG.
pub fn renderToMarkdown(
    allocator: Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    design_name: []const u8,
    doc: review.ReviewDoc,
    /// Short build/version stamp (the netlisp git hash) — printed in the header
    /// so a saved report self-identifies which build produced it.
    build_id: []const u8,
) (std.mem.Allocator.Error || std.Io.Writer.Error)![]const u8 {
    var ctx = try render_html.setupRenderCtx(allocator, block);
    ctx.project_dir = project_dir;

    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(allocator);

    // Title + generation timestamp + build stamp
    try w.print("# Design Review: {s}\n\n", .{design_name});
    try w.print("*Generated {s} by Netlisp · build `{s}`*\n\n", .{ doc.generated_at, build_id });

    // Declared board revision (omitted entirely for unversioned designs).
    if (doc.revision.present) {
        if (doc.revision.date.len > 0) {
            try w.print("**Revision {s}** · {s}\n\n", .{ doc.revision.id, doc.revision.date });
        } else {
            try w.print("**Revision {s}**\n\n", .{doc.revision.id});
        }
        for (doc.revision.changes) |c| {
            try w.print("- **{s}** — {s}\n", .{ c.id, c.summary });
        }
        if (doc.revision.changes.len > 0) try w.writeAll("\n");
    }

    // CSS subset for the inline SVGs that follow. Must come before any
    // <svg> body. Reuses the page's curated subset (no JS hooks).
    try w.writeAll("<style>\n");
    try w.writeAll(render_html.STATIC_SVG_CSS);
    try w.writeAll("\n");
    try w.writeAll(block_diagram.DIAGRAM_CSS);
    try w.writeAll("\n</style>\n\n");

    // Verdict first: summary, the system overview, then the validation block
    // (ERC + assertions + per-IC requirement checks — everything that can
    // pass/fail, grouped under one heading), then the engineering tables.
    try writeSummary(w, doc.summary);
    try writeBlockOverview(allocator, w, block);
    try w.writeAll("## Validation\n\n");
    try writeErc(w, doc.unresolved);
    try writeAssertions(w, doc.assertions);
    try writeRequirementChecklist(allocator, w, doc);
    try writePowerBudget(w, doc.power_budget);
    try writePowerSequence(w, doc.power_sequence);
    try writeTestPoints(w, doc.test_points);
    // The detailed visual schematic last — it's the longest part even compacted.
    try writeSchematicSections(allocator, &ctx, w, block);
    try writeBomStub(w, design_name, doc.bom);

    return buf.toOwnedSlice(allocator);
}

/// Render the `README.md` that ships at the root of the review-export zip — a
/// short map of the package so a reviewer (or agent) knows what to open first
/// and how the bundled source tree is laid out. `source_names` are the in-zip
/// paths of the `.sexp` files (e.g. `src/foo.sexp`, `lib/modules/bar.sexp`),
/// which it partitions into design / sub-modules / library definitions.
pub fn renderReadme(
    allocator: Allocator,
    design_name: []const u8,
    generated_at: []const u8,
    build_id: []const u8,
    source_names: []const []const u8,
) (std.mem.Allocator.Error || std.Io.Writer.Error)![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(allocator);

    try w.print("# Review package — {s}\n\n", .{design_name});
    try w.print(
        "Self-contained design-review snapshot of **{s}**, generated {s} by Netlisp (build `{s}`). " ++
            "Everything needed to review the design — the report, the BOM, and the full source — is in this zip.\n\n",
        .{ design_name, generated_at, build_id },
    );

    try w.writeAll("## Start here\n\n");
    try w.print(
        "- **`{s}-review.md`** — the review report. Open it in any Markdown viewer " ++
            "(GitHub, VS Code preview, Obsidian, …) so the schematics render inline. Top to bottom:\n",
        .{design_name},
    );
    try w.writeAll(
        "  - **Summary** — build status, instance / net counts, coverage\n" ++
            "  - **Block Overview** — grouped-cards system diagram with a concept / schematic / done maturity legend\n" ++
            "  - **Validation** — ERC violations, design assertions, and per-IC requirement checks " ++
            "(pass / fail / verified / pending) with datasheet citations\n" ++
            "  - **Power Budget / Power Sequencing / Test Points** — the engineering tables\n" ++
            "  - **Schematic** — per-section hub schematics (collapsed — click each to expand)\n" ++
            "  - **Bill of Materials** — part totals\n",
    );
    try w.print("- **`{s}-bom.csv`** — the bill of materials as a spreadsheet-ready CSV.\n\n", .{design_name});

    try w.writeAll("## Source files\n\n");
    try w.writeAll(
        "A complete, buildable snapshot of the design's S-expression source — the exact files " ++
            "that produced this report, laid out as a project tree (`netlisp build` rebuilds it):\n\n",
    );

    var design_n: usize = 0;
    var module_n: usize = 0;
    var lib_other_n: usize = 0;
    for (source_names) |n| {
        if (std.mem.startsWith(u8, n, "lib/modules/")) {
            module_n += 1;
        } else if (std.mem.startsWith(u8, n, "lib/")) {
            lib_other_n += 1;
        } else {
            design_n += 1;
        }
    }

    // Design source(s) — everything outside lib/ (the design `.sexp` + its
    // `.checks.sexp` sidecar). A standalone module has none (its root file lives
    // under lib/modules/ and is listed below), so skip the empty heading.
    if (design_n > 0) {
        try w.writeAll("**Design** — `src/`\n\n");
        for (source_names) |n| {
            if (std.mem.startsWith(u8, n, "lib/")) continue;
            try w.print("- `{s}`\n", .{n});
        }
        try w.writeAll("\n");
    }

    if (module_n > 0) {
        try w.print(
            "**Sub-modules** ({d}) — `lib/modules/` — the reusable sub-circuits this design instantiates\n\n",
            .{module_n},
        );
        for (source_names) |n| {
            if (!std.mem.startsWith(u8, n, "lib/modules/")) continue;
            try w.print("- `{s}`\n", .{n});
        }
        try w.writeAll("\n");
    }

    if (lib_other_n > 0) {
        try w.print(
            "**Library definitions** ({d}) — `lib/components/` (and any `lib/pinouts/`) — the part, " ++
                "footprint, and pin-map definitions for every placed component.\n\n",
            .{lib_other_n},
        );
    }

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
    const oc = s.overall_coverage;
    try w.print(
        "- **Coverage**: {d}% complete ({d}/{d} components fully filled in, {d} missing)\n",
        .{ oc.percent, oc.complete, oc.checked, oc.missing_total },
    );
    try w.writeAll("\n");
}

/// The page's lead diagram: the **Block overview** (grouped-cards view of the
/// authored `(group …)` clusters, with the concept/schematic/done maturity
/// legend). A design with no groups has no block overview, so we fall back to
/// the auto System block diagram so there's always one overview up top.
fn writeBlockOverview(allocator: Allocator, w: anytype, block: *const DesignBlock) !void {
    try w.writeAll("## Block Overview\n\n");
    const sub_attachments = try membership.computeSubBlockAttachments(allocator, block);
    defer allocator.free(sub_attachments);
    // The engine renderer writes to a `*std.Io.Writer`; bridge to this module's
    // ArrayList writer through a scratch Allocating buffer. The markdown/zip
    // export has no project root to read layout sidecars from, so chips cap at
    // the `schematic` maturity stage (no starred-layout lookup).
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const rendered = block_diagram.renderBlockOverview(allocator, block, sub_attachments, "", &aw.writer) catch false;
    if (!rendered) {
        // No `(group …)` clusters → the auto System overview is the best we have.
        try block_diagram.renderSystemSvg(allocator, block, sub_attachments, "", &aw.writer);
    }
    try w.writeAll(aw.written());
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
    try w.writeAll("### ERC\n\n");
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
    try w.writeAll("### Assertions\n\n");
    if (asserts.len == 0) {
        try w.writeAll("*No design assertions declared.*\n\n");
        return;
    }
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
    ctx: *RenderCtx,
    w: anytype,
    block: *const DesignBlock,
) !void {
    try w.writeAll("## Schematic\n\n");
    for (block.sections) |sec| {
        try writeSchematicSection(allocator, ctx, w, sec, 3);
        for (sec.sub_sections) |sub| {
            try writeSchematicSection(allocator, ctx, w, sub, 4);
        }
    }
    for (block.sub_blocks) |sb| {
        // HTML-escape the names — markdown renderers pass inline HTML through, so
        // a `<`/`&` in a sub-block name would inject markup into the document.
        try w.writeAll("### ");
        try escape.writeXml(w, sb.name);
        try w.writeAll(" *(sub-block)*\n\n");
        if (sb.block.name.len > 0) {
            try w.writeAll("*");
            try escape.writeXml(w, sb.block.name);
            try w.writeAll("*\n\n");
        }
        // writeHubBlock skips passives (drawn as spokes on each hub) itself.
        for (sb.block.instances) |inst| {
            try writeHubBlock(allocator, ctx, w, &.{}, inst.ref_des, inst.component, inst.value);
        }
    }
}

fn writeSchematicSection(
    allocator: Allocator,
    ctx: *RenderCtx,
    w: anytype,
    sec: Section,
    heading_level: u8,
) !void {
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
///
/// Passives (R/C/L/F/D) are skipped entirely: they're already drawn inline as
/// spokes on the hub SVGs they wire into, so a standalone block per passive
/// just repeats that symbol. Mirrors the live schematic page's `isHub` filter.
fn writeHubBlock(
    allocator: Allocator,
    ctx: *RenderCtx,
    w: anytype,
    pin_groups: []const env_mod.PinGroup,
    ref_des: []const u8,
    component: []const u8,
    value: []const u8,
) !void {
    if (!draw.isHubRef(ref_des)) return;
    // These land inside inline `<details><summary>…</summary>` HTML, which every
    // markdown renderer passes through verbatim — a `<`/`&` in a component name
    // would break the collapsible structure (or inject markup), so HTML-escape.
    try w.writeAll("<details><summary><strong><code>");
    try escape.writeXml(w, ref_des);
    try w.writeAll("</code></strong> · ");
    try escape.writeXml(w, component);
    if (value.len > 0) {
        try w.writeAll(" · ");
        try escape.writeXml(w, value);
    }
    try w.writeAll("</summary>\n\n");
    var sub_buf: std.ArrayList(u8) = .empty;
    defer sub_buf.deinit(allocator);
    const sw = sub_buf.writer(allocator);
    const rendered = render_html.renderHubSvg(ctx, sw, allocator, pin_groups, ref_des) catch false;
    if (rendered) {
        try writeCompactSvg(allocator, w, sub_buf.items);
        try w.writeAll("\n");
    } else {
        try w.writeAll("*No schematic body — only passives or no pin groupings declared.*\n");
    }
    try w.writeAll("\n</details>\n\n");
}

/// Emit a hub SVG slimmed for a static document. The shared schematic renderer
/// targets the live, interactive page, so it pretty-prints one element per line
/// and embeds click-only markup (transparent `hit-area` targets, hidden
/// `debug-pin` markers, `cursor:pointer`) that does nothing in a `.md`. We
/// excise those dead elements and collapse the result to a single line — the
/// visual is byte-for-byte identical when rendered, but a board's schematic
/// drops from thousands of lines to one line per hub. `data-net`/`data-ref`
/// are kept: they carry net/part names an agent can actually read.
fn writeCompactSvg(allocator: Allocator, w: anytype, svg: []const u8) !void {
    // Pass 1 — drop dead interactive elements + the cursor:pointer style.
    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(allocator);
    var i: usize = 0;
    while (i < svg.len) {
        if (svg[i] == '<') {
            const close = std.mem.indexOfScalarPos(u8, svg, i, '>') orelse svg.len - 1;
            const tag = svg[i .. close + 1];
            const dead = std.mem.indexOf(u8, tag, "class=\"hit-area\"") != null or
                std.mem.indexOf(u8, tag, "class=\"debug-pin\"") != null;
            if (!dead) try appendWithoutSubstr(&clean, allocator, tag, " style=\"cursor:pointer\"");
            i = close + 1;
        } else {
            try clean.append(allocator, svg[i]);
            i += 1;
        }
    }

    // Pass 2 — collapse every run of whitespace that spans a newline (the
    // pretty-print indentation) down to a single space. Text content (pin
    // numbers, labels) has no newlines, so it is untouched.
    var pending_break = false;
    for (clean.items) |c| {
        switch (c) {
            '\n', '\r', '\t' => pending_break = true,
            ' ' => if (!pending_break) try w.writeByte(' '),
            else => {
                if (pending_break) {
                    try w.writeByte(' ');
                    pending_break = false;
                }
                try w.writeByte(c);
            },
        }
    }
}

/// Append `s` to `list`, removing every occurrence of `needle`.
fn appendWithoutSubstr(list: *std.ArrayList(u8), allocator: Allocator, s: []const u8, needle: []const u8) !void {
    var rest = s;
    while (std.mem.indexOf(u8, rest, needle)) |at| {
        try list.appendSlice(allocator, rest[0..at]);
        rest = rest[at + needle.len ..];
    }
    try list.appendSlice(allocator, rest);
}

/// Per-IC requirement checks — every requirement-bearing component, whether
/// declared in a top-level section OR inside a sub-block module (the latter is
/// where most ICs live on a sub-block-heavy board, so omitting them — as the
/// old checklist did — left the doc looking requirement-free).
fn writeRequirementChecklist(allocator: Allocator, w: anytype, doc: review.ReviewDoc) !void {
    try w.writeAll("### Requirement Checks (per IC)\n\n");
    var emitted = false;
    // A multi-section IC (the main MCU declares pins in several sections) shows
    // up once per section in `component_requirements`; its requirements come
    // from the library and are identical each time, so emit each ref-des once.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    for (doc.sections) |sec| {
        for (sec.component_requirements) |entry| {
            if (entry.requirements.len == 0 or seen.contains(entry.ref_des)) continue;
            try seen.put(allocator, entry.ref_des, {});
            if (try writeRequirementEntry(allocator, w, entry)) emitted = true;
        }
    }
    for (doc.subblock_requirements) |entry| {
        if (entry.requirements.len == 0 or seen.contains(entry.ref_des)) continue;
        try seen.put(allocator, entry.ref_des, {});
        if (try writeRequirementEntry(allocator, w, entry)) emitted = true;
    }
    if (!emitted) try w.writeAll("*No requirement-bearing components in this design.*\n\n");
}

/// One component's requirement block. Returns false (emitting nothing) when the
/// component declares no requirements.
fn writeRequirementEntry(allocator: Allocator, w: anytype, entry: review.ComponentRequirementEntry) !bool {
    if (entry.requirements.len == 0) return false;
    try w.print("#### `{s}` — {s}\n\n", .{ entry.ref_des, entry.component });

    // Worst → best ordering, mirrors the live page's hub-card sort.
    // Build a [(req_idx, sort_key)] list and sort.
    const SortItem = struct { idx: usize, key: u8 };
    const sorted = allocator.alloc(SortItem, entry.requirements.len) catch return false;
    defer allocator.free(sorted);
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
    return true;
}

fn writeBomStub(w: anytype, design_name: []const u8, bom: []const review.BomGroup) !void {
    var total: usize = 0;
    for (bom) |g| total += g.entries.len;
    try w.print("## Bill of Materials\n\nSee attached `{s}-bom.csv` ({d} parts in {d} groups).\n\n", .{ design_name, total, bom.len });
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

fn lookupInstance(ctx: *RenderCtx, ref_des: []const u8) ?env_mod.Instance {
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
    // renderToMarkdown builds a RenderCtx that never frees (it is arena-scoped
    // by design — the live caller passes the per-request arena), so drive it
    // through an arena here too rather than the leak-checked testing allocator.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
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
    const out = try renderToMarkdown(allocator, &block, "/tmp", "test", doc, "abc1234");
    try std.testing.expect(std.mem.indexOf(u8, out, "# Design Review: test") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "## Summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "## Validation") != null);
    // The verbatim source is shipped as separate zip files, never embedded.
    try std.testing.expect(std.mem.indexOf(u8, out, "## Source") == null);
}

test "writeRequirementEntry badges a verified fail as overridden" {
    const alloc = std.testing.allocator;
    const reqs = [_]env_mod.Requirement{
        .{ .text = "Rail within tolerance" },
        .{ .text = "Cap present" },
    };
    const results = [_]req_checks.Result{
        // A failing check carrying a sign-off must render the overridden badge…
        .{ .status = .fail, .verification = .{ .req_id = "r1", .rationale = "waived" } },
        // …while a plain failing check keeps the bare FAIL badge.
        .{ .status = .fail },
    };
    const entry = review.ComponentRequirementEntry{
        .ref_des = "U1",
        .component = "reg",
        .requirements = &reqs,
        .req_results = &results,
    };
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    _ = try writeRequirementEntry(alloc, &aw.writer, entry);
    // The overridden badge must sit on the verified requirement, not the plain
    // one — a `!=`→`==` flip swaps the two badges.
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "*(overridden)* — Rail within tolerance") != null);
}
