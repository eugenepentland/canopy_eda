const std = @import("std");
const review = @import("review.zig");
const erc_mod = @import("erc.zig");
const power_budget = @import("eval/power_budget.zig");
const power_sequencing = @import("eval/power_sequencing.zig");
const render_power_tree_svg = @import("render_power_tree_svg.zig");
const coverage = @import("coverage.zig");
const traceability_mod = @import("traceability.zig");

/// Error set for HTML emit helpers in this module. Covers both writer
/// shapes the schematic page uses: an `ArrayListUnmanaged.writer()`
/// (only `OutOfMemory`) and a `*std.Io.Writer` (adds `WriteFailed`).
pub const RenderError = std.mem.Allocator.Error || std.Io.Writer.Error;

// ── Repeated string literals ──────────────────────────────────────
const codeTdSep: []const u8 = "</code></td><td>";
const codeTdToCode: []const u8 = "</code></td><td><code>";
const sectionClose: []const u8 = "</section>";
const spanSpanSep: []const u8 = "</span><span>";
const tableSectionClose: []const u8 = "</tbody></table></section>";
const tdTrClose: []const u8 = "</td></tr>";
const tdSep: []const u8 = "</td><td>";
pub const mutedDash: []const u8 = "<span class=\"muted\">—</span>";
const trCodeOpen: []const u8 = "<tr><td><code>";

/// Coverage-pill thresholds for the summary banner. Green at ≥95%, amber
/// at 70–94%, red below 70%. Picked so a near-perfect design lands green,
/// a typical work-in-progress lands amber, and a barely-started design
/// reads red at a glance.
const COVERAGE_PASS_PCT: u8 = 95;
const COVERAGE_WARN_PCT: u8 = 70;

/// Render the power-tree section as a wrapping `<section>` with the SVG.
/// Skips rendering when the tree has no nodes — sub-block-less designs
/// have an empty tree and we don't want an empty section card.
pub fn writePowerTree(allocator: std.mem.Allocator, w: anytype, tree: review.PowerTree) RenderError!void {
    if (tree.nodes.len == 0) return;
    try w.writeAll("<section class=\"power-tree-section\"><h2>Power Tree</h2>");
    try render_power_tree_svg.render(allocator, tree, w);
    try w.writeAll("</section>");
}

/// CSS rules for review fragments. Embedded inline by `render_html.zig`'s
/// `<style>` block alongside the schematic page's own CSS so the embedded
/// review tables match the surrounding chrome without an extra request.
pub const BODY_CSS = @embedFile("assets/review.css");

/// Render the Summary section: a 4-row table covering counts, ERC
/// severities, assertion outcomes, and critical-IC requirement coverage,
/// followed by a missing-requirements list when the design has
/// undocumented hubs.
pub fn writeSummaryTable(w: anytype, s: review.Summary) RenderError!void {
    try w.writeAll("<section><h2>Summary</h2><table class=\"summary\">");
    try w.print(
        "<tr><th>Sections</th><td>{d}</td><th>Components</th><td>{d}</td><th>Nets</th><td>{d}</td></tr>",
        .{ s.section_count, s.instance_count, s.net_count },
    );
    try w.print(
        "<tr><th>Errors</th><td class=\"{s}\">{d}</td><th>Warnings</th><td class=\"{s}\">{d}</td><th>Info</th><td>{d}</td></tr>",
        .{
            if (s.violation_error > 0) "fail" else "",
            s.violation_error,
            if (s.violation_warning > 0) "warn" else "",
            s.violation_warning,
            s.violation_info,
        },
    );
    try w.print(
        "<tr><th>Assertions pass</th><td class=\"pass\">{d}</td><th>warn</th><td class=\"{s}\">{d}</td><th>fail</th><td class=\"{s}\">{d}</td></tr>",
        .{
            s.assertion_pass,
            if (s.assertion_warn > 0) "warn" else "",
            s.assertion_warn,
            if (s.assertion_fail > 0) "fail" else "",
            s.assertion_fail,
        },
    );
    const missing_n = s.critical_missing_requirements.len;
    const cov_class: []const u8 = if (s.critical_count == 0) "" else if (missing_n == 0) "pass" else "warn";
    try w.print(
        "<tr><th>Critical ICs</th><td>{d}</td><th>With requirements</th><td class=\"{s}\">{d}</td><th>Missing</th><td class=\"{s}\">{d}</td></tr>",
        .{
            s.critical_count,
            cov_class,
            s.critical_with_requirements,
            if (missing_n > 0) "warn" else "",
            missing_n,
        },
    );
    const missing_mpn_n = s.bom_missing_mpn.len;
    const mpn_class: []const u8 = if (s.bom_total == 0) "" else if (missing_mpn_n == 0) "pass" else "warn";
    try w.print(
        "<tr><th>BOM parts</th><td>{d}</td><th>With MPN</th><td class=\"{s}\">{d}</td><th>Missing MPN</th><td class=\"{s}\">{d}</td></tr>",
        .{
            s.bom_total,
            mpn_class,
            s.bom_with_mpn,
            if (missing_mpn_n > 0) "warn" else "",
            missing_mpn_n,
        },
    );
    const oc = s.overall_coverage;
    const oc_pill = coveragePillClass(oc.checked, oc.percent);
    try w.print(
        "<tr><th>Coverage</th><td colspan=\"5\"><span class=\"pill {s}\">{d}% complete</span> · {d} of {d} components fully filled in · {d} missing</td></tr>",
        .{ oc_pill, oc.percent, oc.complete, oc.checked, oc.missing_total },
    );
    try w.writeAll("</table>");
    if (missing_n > 0) {
        try w.writeAll("<p class=\"hint\">Add <code>(requirement \"...\")</code> forms in <code>lib/components/&lt;name&gt;.sexp</code> for:</p>");
        try w.writeAll("<ul class=\"missing-reqs\">");
        for (s.critical_missing_requirements) |m| {
            try w.writeAll("<li><code>");
            try writeHtmlEscaped(w, m.ref_des);
            try w.writeAll("</code> — <code>");
            try writeHtmlEscaped(w, m.component);
            try w.writeAll("</code></li>");
        }
        try w.writeAll("</ul>");
    }
    try w.writeAll(sectionClose);
}

/// Render the Traceability section: one row per critical IC declared in the
/// design's `(design-doc …)` form, with a ✓/✗ for each of the four lifecycle
/// stages (footprint imported, datasheet imported, requirements defined,
/// placed + verified) and an "N/M ICs ready" roll-up pill. Skips rendering
/// entirely when the design declares no critical ICs.
pub fn writeTraceability(w: anytype, trace: traceability_mod.Traceability) RenderError!void {
    if (trace.rows.len == 0) return;
    const pill: []const u8 = if (trace.complete == trace.declared)
        "pass"
    else if (trace.complete == 0)
        "fail"
    else
        "warn";
    try w.writeAll("<section><h2>Traceability</h2>");
    try w.print(
        "<p class=\"hint\">Critical-IC lifecycle from the <code>(design-doc …)</code> declaration: " ++
            "import the footprint &amp; datasheet, add component requirements, then place &amp; verify. " ++
            "<span class=\"pill {s}\">{d}/{d} ICs ready</span></p>",
        .{ pill, trace.complete, trace.declared },
    );
    try w.writeAll("<table class=\"summary\"><thead><tr>" ++
        "<th>Critical IC</th><th>Footprint</th><th>Datasheet</th><th>Requirements</th><th>Placed + verified</th>" ++
        "</tr></thead><tbody>");
    for (trace.rows) |row| {
        try w.writeAll(trCodeOpen);
        try writeHtmlEscaped(w, row.component);
        try w.writeAll("</code>");
        if (row.role.len > 0) {
            try w.writeAll("<br><span class=\"muted\">");
            try writeHtmlEscaped(w, row.role);
            try w.writeAll("</span>");
        }
        if (!row.placed) {
            try w.writeAll("<br><span class=\"muted\">not yet placed</span>");
        }
        try w.writeAll("</td>");
        try writeStageCell(w, row.stages[@intFromEnum(traceability_mod.TraceStage.footprint)]);
        try writeStageCell(w, row.stages[@intFromEnum(traceability_mod.TraceStage.datasheet)]);
        try writeStageCell(w, row.stages[@intFromEnum(traceability_mod.TraceStage.requirements)]);
        try writeStageCell(w, row.stages[@intFromEnum(traceability_mod.TraceStage.placed_verified)]);
        try w.writeAll("</tr>");
    }
    try w.writeAll(tableSectionClose);
}

/// One lifecycle-stage cell: green ✓ when satisfied, muted ✗ otherwise.
fn writeStageCell(w: anytype, ok: bool) RenderError!void {
    if (ok) {
        try w.writeAll("<td class=\"pass\">✓</td>");
    } else {
        try w.writeAll("<td class=\"muted\">✗</td>");
    }
}

/// Render the Power Budget section: one collapsible row per rail, sorted
/// tightest-first, with source/load currents, computed margin, status
/// pill, and an expandable per-consumer breakdown that lists every
/// (ref_des, net) group landing on the rail.
pub fn writePowerBudget(w: anytype, rails: []const power_budget.Rail) RenderError!void {
    if (rails.len == 0) return;
    try w.writeAll("<section><h2>Power budget</h2>");
    try w.writeAll(
        "<p class=\"hint\">Rails sorted tightest first. " ++
            "Ferrite beads merge into upstream rails. " ++
            "Click a rail to see which components land on it.</p>",
    );

    // Column headers — grid-aligned with each <details>/<summary> below.
    try w.writeAll("<div class=\"rail-head\">");
    try w.writeAll("<span></span>");
    try w.writeAll(
        "<span>Rail</span><span>Source</span>" ++
            "<span>Src typ</span><span>Src max</span>" ++
            "<span>Load typ</span><span>Load max</span>" ++
            "<span>Margin</span><span>Status</span>",
    );
    try w.writeAll("</div>");

    for (rails) |r| {
        const row_class: []const u8 = switch (r.status) {
            .over => " row-fail",
            .tight => " row-warn",
            else => "",
        };
        const disabled = r.consumers.len == 0;
        try w.print("<details class=\"rail{s}\"{s}><summary class=\"rail-sum\">", .{ row_class, if (disabled) " open" else "" });
        try w.writeAll("<span class=\"rail-caret\">");
        if (disabled) try w.writeAll("·") else try w.writeAll("▸");
        try w.writeAll("</span>");
        try w.writeAll("<span class=\"rail-net\"><code>");
        try writeHtmlEscaped(w, r.net);
        try w.writeAll("</code></span>");
        try w.writeAll("<span>");
        if (r.source_label.len > 0) {
            try w.writeAll("<code>");
            try writeHtmlEscaped(w, r.source_label);
            try w.writeAll("</code>");
        } else {
            try w.writeAll(mutedDash);
        }
        try w.writeAll("</span>");
        try w.writeAll("<span>");
        try writeFloatCell(w, r.source_typ_a);
        try w.writeAll(spanSpanSep);
        try writeFloatCell(w, r.source_max_a);
        try w.writeAll(spanSpanSep);
        if (r.any_typ_load) try w.print("{d:.3}", .{r.load_typ_a}) else try w.writeAll(mutedDash);
        try w.writeAll(spanSpanSep);
        if (r.any_max_load) try w.print("{d:.3}", .{r.load_max_a}) else try w.writeAll(mutedDash);
        try w.writeAll(spanSpanSep);
        if (r.margin_pct) |m| try w.print("{d:.1}%", .{m}) else try w.writeAll(mutedDash);
        try w.print("</span><span><span class=\"pill pill-{s}\">{s}</span></span>", .{ @tagName(r.status), statusLabel(r.status) });
        try w.writeAll("</summary>");

        if (r.consumers.len > 0) {
            try w.writeAll(
                "<div class=\"rail-body\"><table class=\"consumer-table\">" ++
                    "<thead><tr><th>Ref</th><th>Net</th><th>Pins</th>" ++
                    "<th>i-typ (A)</th><th>i-max (A)</th></tr></thead><tbody>",
            );
            for (r.consumers) |c| {
                try w.writeAll(trCodeOpen);
                try writeHtmlEscaped(w, c.ref_des);
                try w.writeAll(codeTdToCode);
                try writeHtmlEscaped(w, c.net);
                try w.writeAll(codeTdSep);
                for (c.pins, 0..) |p, i| {
                    if (i > 0) try w.writeAll(", ");
                    try writeHtmlEscaped(w, p);
                }
                try w.writeAll(tdSep);
                if (c.i_typ) |v| try w.print("{d:.4}", .{v}) else try w.writeAll(mutedDash);
                try w.writeAll(tdSep);
                if (c.i_max) |v| try w.print("{d:.4}", .{v}) else try w.writeAll(mutedDash);
                try w.writeAll(tdTrClose);
            }
            try w.writeAll("</tbody></table></div>");
        } else {
            try w.writeAll(
                "<div class=\"rail-body\"><p class=\"hint\">" ++
                    "No annotated consumers on this rail. " ++
                    "Add <code>(i-typ X) (i-max Y)</code> on pins connected here — " ++
                    "or, for an upstream rail like VBATT, " ++
                    "annotate the downstream regulator's input pins " ++
                    "or use efficiency on its output port." ++
                    "</p></div>",
            );
        }

        try w.writeAll("</details>");
    }
    try w.writeAll(sectionClose);
}

fn statusLabel(s: power_budget.RailStatus) []const u8 {
    return switch (s) {
        .ok => "OK",
        .tight => "TIGHT",
        .over => "OVER",
        .no_source => "no source",
        .no_consumers => "no loads",
    };
}

/// Render the Power Sequencing section: rails ordered top-down by power-up
/// sequence, showing each rail's source sub-block, its `(enable …)` net,
/// and the upstream rail it depends on. `via` notes intermediate PG signals
/// so the reviewer can trace e.g. "LDO depends on VDD via PG_3V3".
pub fn writePowerSequence(w: anytype, rows: []const power_sequencing.SequenceRow) RenderError!void {
    if (rows.len == 0) return;
    try w.writeAll("<section><h2>Power sequencing</h2>");
    try w.writeAll(
        "<p class=\"hint\">Rails ordered top-down by power-up sequence. " ++
            "A rail's <code>enable</code> net must be stable before that rail comes up. " ++
            "Always-on rails have no enable and power up first.</p>",
    );
    try w.writeAll("<table><thead><tr><th>#</th><th>Rail</th><th>Source</th><th>Enable</th><th>Depends on</th><th>Status</th></tr></thead><tbody>");
    for (rows) |r| {
        const row_class: []const u8 = switch (r.status) {
            .unresolved => " class=\"row-warn\"",
            else => "",
        };
        try w.print("<tr{s}><td>{d}</td><td><code>", .{ row_class, r.order + 1 });
        try writeHtmlEscaped(w, r.rail);
        try w.writeAll(codeTdToCode);
        try writeHtmlEscaped(w, r.source);
        try w.writeAll(codeTdSep);
        if (r.enable.len > 0) {
            try w.writeAll("<code>");
            try writeHtmlEscaped(w, r.enable);
            try w.writeAll("</code>");
        } else {
            try w.writeAll(mutedDash);
        }
        try w.writeAll(tdSep);
        if (r.depends_on.len > 0) {
            try w.writeAll("<code>");
            try writeHtmlEscaped(w, r.depends_on);
            try w.writeAll("</code>");
            if (r.via.len > 0) {
                try w.writeAll(" <span class=\"muted\">via <code>");
                try writeHtmlEscaped(w, r.via);
                try w.writeAll("</code></span>");
            }
        } else {
            try w.writeAll(mutedDash);
        }
        try w.print("</td><td><span class=\"pill pill-{s}\">{s}</span></td></tr>", .{ @tagName(r.status), sequenceLabel(r.status) });
    }
    try w.writeAll(tableSectionClose);
}

fn sequenceLabel(s: power_sequencing.SequenceStatus) []const u8 {
    return switch (s) {
        .ok => "OK",
        .unresolved => "UNRESOLVED",
        .always_on => "ALWAYS-ON",
    };
}

/// Render the Test Points section — a probe-pad checklist for hardware
/// bring-up. Each row pairs a ref_des with the net visible at pin 1 and
/// the optional `(note …)` describing what to look for.
pub fn writeTestPoints(w: anytype, tps: []const review.TestPointEntry) RenderError!void {
    if (tps.len == 0) return;
    try w.writeAll("<section><h2>Test points</h2>");
    try w.writeAll("<p class=\"hint\">Physical probe pads on the board. Keep this list next to a multimeter when bringing up hardware.</p>");
    try w.writeAll("<table><thead><tr><th>Ref</th><th>Net</th><th>Purpose</th></tr></thead><tbody>");
    for (tps) |tp| {
        try w.writeAll(trCodeOpen);
        try writeHtmlEscaped(w, tp.ref_des);
        try w.writeAll(codeTdSep);
        if (tp.net.len > 0) {
            try w.writeAll("<code>");
            try writeHtmlEscaped(w, tp.net);
            try w.writeAll("</code>");
        } else {
            try w.writeAll("<span class=\"muted\">unconnected</span>");
        }
        try w.writeAll(tdSep);
        if (tp.purpose.len > 0) {
            try writeHtmlEscaped(w, tp.purpose);
        } else {
            try w.writeAll(mutedDash);
        }
        try w.writeAll(tdTrClose);
    }
    try w.writeAll(tableSectionClose);
}

/// Render the Unresolved Issues section — every error+warning ERC violation
/// the design still carries, severity-styled and with ref_des / net links so
/// the reviewer can drill into each one. Emits a "clean build" banner when
/// the slice is empty.
pub fn writeUnresolved(w: anytype, vs: []const erc_mod.Violation) RenderError!void {
    if (vs.len == 0) {
        try w.writeAll("<section><h2>Unresolved issues</h2><p class=\"hint\">No errors or warnings — clean build.</p></section>");
        return;
    }
    try w.writeAll("<section><h2>Unresolved issues</h2>");
    try w.writeAll("<table><thead><tr><th>Severity</th><th>Kind</th><th>Ref</th><th>Net</th><th>Message</th></tr></thead><tbody>");
    for (vs) |v| {
        const row_class: []const u8 = switch (v.severity) {
            .@"error" => " class=\"row-fail\"",
            .warning => " class=\"row-warn\"",
            .info => "",
        };
        try w.print("<tr{s}><td><span class=\"pill pill-{s}\">{s}</span></td><td><code>", .{
            row_class,
            @tagName(v.severity),
            @tagName(v.severity),
        });
        try writeHtmlEscaped(w, @tagName(v.kind));
        try w.writeAll(codeTdSep);
        if (v.ref_des.len > 0) try writeHtmlEscaped(w, v.ref_des) else try w.writeAll(mutedDash);
        try w.writeAll(tdSep);
        if (v.net.len > 0) try writeHtmlEscaped(w, v.net) else try w.writeAll(mutedDash);
        try w.writeAll(tdSep);
        try writeHtmlEscaped(w, v.message);
        try w.writeAll(tdTrClose);
    }
    try w.writeAll(tableSectionClose);
}

fn writeSections(w: anytype, sections: []const review.SectionReport) !void {
    if (sections.len == 0) return;
    try w.writeAll("<section><h2>Sections</h2>");
    for (sections) |s| {
        const status_pill: []const u8 = switch (s.status) {
            .concept => "pill-concept",
            .implemented => "pill-ok",
            .review => "pill-warn",
        };
        try w.print("<div class=\"sec-card\" id=\"sec-{s}\" data-slug=\"{s}\">", .{ s.slug, s.slug });
        try w.writeAll("<div class=\"sec-head\"><h3>");
        try writeHtmlEscaped(w, s.name);
        try w.print("</h3><span class=\"pill {s}\">{s}</span>", .{ status_pill, @tagName(s.status) });
        try w.print("<span class=\"muted sec-count\">{d} component{s}</span>", .{ s.instance_count, if (s.instance_count == 1) "" else "s" });
        try w.writeAll("</div>");

        if (s.description.len > 0) {
            try w.writeAll("<p class=\"sec-desc\">");
            try writeHtmlEscaped(w, s.description);
            try w.writeAll("</p>");
        }

        try writeSectionCoverage(w, s.coverage);

        if (s.ports.len > 0) {
            try w.writeAll("<details open class=\"sec-ports\"><summary>Ports</summary><ul>");
            for (s.ports) |p| {
                try w.writeAll("<li><code>");
                try writeHtmlEscaped(w, p.name);
                try w.print("</code> {s}", .{p.direction});
                if (p.voltage) |v| try w.print(" @ {d}V", .{v});
                if (p.protocol.len > 0) {
                    try w.writeAll(" · ");
                    try writeHtmlEscaped(w, p.protocol);
                }
                if (p.role.len > 0) {
                    try w.writeAll(" · ");
                    try writeHtmlEscaped(w, p.role);
                }
                try w.writeAll("</li>");
            }
            try w.writeAll("</ul></details>");
        }

        try writeBoundaryContracts(w, s.ports);

        // Design-specific notes: stored inline in the design's .sexp as
        // `(note "..." (ref "foo.pdf" (page N)))`. Editable from the GUI —
        // add/delete hit /api/section-note/:name/(add|remove) which splices
        // the form directly into the .sexp source.
        try w.writeAll("<details class=\"sec-notes\" open><summary>Design notes");
        try w.print(" ({d})</summary><ul class=\"note-list\">", .{s.notes.len});
        for (s.notes, 0..) |n, ni| {
            try w.print("<li data-index=\"{d}\">", .{ni});
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
            try w.writeAll(" <button class=\"note-del\" title=\"Delete note\">✕</button></li>");
        }
        try w.writeAll("</ul>");
        try w.writeAll("<div class=\"note-add\" data-section=\"");
        try writeHtmlEscaped(w, s.name);
        try w.writeAll("\">");
        try w.writeAll("<input type=\"text\" class=\"note-new-text\" placeholder=\"Add a design note…\">");
        try w.writeAll("<select class=\"note-new-pdf\"><option value=\"\">(no datasheet)</option></select>");
        try w.writeAll("<input type=\"number\" min=\"0\" class=\"note-new-page\" placeholder=\"page\">");
        try w.writeAll("<button class=\"note-add-btn\">Add</button>");
        try w.writeAll("</div></details>");

        // Component-level requirements render per-hub on the schematic card
        // itself (see `writeHubRequirements` in render_html.zig). They sit
        // right under the hub's SVG so the reviewer sees datasheet-derived
        // rules in the same visual row they're checking pins on — no
        // duplicate list at the section-summary level here.

        if (s.violations.len > 0) {
            try w.writeAll("<details open class=\"sec-vios\"><summary>Violations");
            try w.print(" ({d})</summary><ul>", .{s.violations.len});
            for (s.violations) |v| {
                try w.print("<li><span class=\"pill pill-{s}\">{s}</span> <code>", .{ @tagName(v.severity), @tagName(v.severity) });
                try writeHtmlEscaped(w, @tagName(v.kind));
                try w.writeAll("</code> ");
                if (v.ref_des.len > 0) {
                    try w.writeAll("<strong>");
                    try writeHtmlEscaped(w, v.ref_des);
                    try w.writeAll("</strong> — ");
                }
                try writeHtmlEscaped(w, v.message);
                try w.writeAll("</li>");
            }
            try w.writeAll("</ul></details>");
        }

        try w.writeAll("</div>");
    }
    try w.writeAll(sectionClose);
}

/// Render the per-section "Boundary contracts" table — one row per port
/// that declared `(electrical ...)` on its `(port …)` form. Lists the
/// logic levels, drive type, and domain so reviewers can see what voltage
/// contract the section commits to at each boundary. Skipped entirely
/// when no port on the section carries electrical metadata.
fn writeBoundaryContracts(w: anytype, ports: []const review.PortSummary) !void {
    var any = false;
    for (ports) |p| {
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
    for (ports) |p| {
        const e = p.electrical orelse continue;
        try w.writeAll("<tr><td><code>");
        try writeHtmlEscaped(w, p.name);
        try w.print("</code></td><td>{s}</td><td>", .{p.direction});
        if (e.electrical_type) |t| {
            try writeHtmlEscaped(w, @tagName(t));
        } else {
            try w.writeAll("—");
        }
        try w.writeAll("</td>");
        try writeVoltCell(w, e.v_oh_typ);
        try writeVoltCell(w, e.v_ol_typ);
        try writeVoltCell(w, e.v_ih_min);
        try writeVoltCell(w, e.v_il_max);
        try writeVoltCell(w, e.max_voltage);
        try w.writeAll("<td>");
        if (e.drive) |d| {
            try writeHtmlEscaped(w, @tagName(d));
        } else {
            try w.writeAll("—");
        }
        try w.writeAll("</td><td>");
        if (e.domain.len > 0) {
            try writeHtmlEscaped(w, e.domain);
        } else {
            try w.writeAll("—");
        }
        try w.writeAll(tdTrClose);
    }
    try w.writeAll("</tbody></table></details>");
}

fn writeVoltCell(w: anytype, v: ?f64) !void {
    try w.writeAll("<td>");
    if (v) |x| {
        try w.print("{d:.2}", .{x});
    } else {
        try w.writeAll("—");
    }
    try w.writeAll("</td>");
}

/// Render the per-section "Coverage" details block — a per-category
/// breakdown of what's filled, plus a list of incomplete components and
/// which specific fields they're missing. Collapsed by default so it
/// doesn't clutter the section card. Skipped entirely when no checkable
/// instances live in the section.
pub fn writeSectionCoverage(w: anytype, c: coverage.SectionCoverage) RenderError!void {
    if (c.checked == 0) return;
    const incomplete = c.checked - c.complete;
    try w.print(
        "<details class=\"sec-coverage\"><summary>Coverage · {d}/{d} components fully filled in",
        .{ c.complete, c.checked },
    );
    if (incomplete > 0) try w.print(" · {d} incomplete", .{incomplete});
    try w.writeAll("</summary>");
    try w.writeAll(
        "<p class=\"hint\">Each placed component is checked for these fields. " ++
            "Passives (R/C/L/F/D) need only <strong>value</strong> and <strong>footprint</strong>. " ++
            "ICs additionally need <strong>MPN</strong>, <strong>manufacturer</strong>, <strong>datasheet</strong>, " ++
            "and (when the library declares <code>(requirement …)</code> rules) every requirement <strong>verified</strong>.</p>",
    );
    try w.writeAll("<table class=\"coverage\"><thead><tr><th>Category</th><th>Filled</th></tr></thead><tbody>");
    try writeCoverageRow(w, "Value", c.filled.value, c.expected.value);
    try writeCoverageRow(w, "Footprint", c.filled.footprint, c.expected.footprint);
    try writeCoverageRow(w, "MPN", c.filled.mpn, c.expected.mpn);
    try writeCoverageRow(w, "Manufacturer", c.filled.manufacturer, c.expected.manufacturer);
    try writeCoverageRow(w, "Datasheet", c.filled.datasheet, c.expected.datasheet);
    try writeCoverageRow(w, "Requirements verified", c.filled.requirements_verified, c.expected.requirements_verified);
    try w.writeAll("</tbody></table>");
    try writeIncompleteInstances(w, c.instances);
    try w.writeAll("</details>");
}

fn coveragePillClass(checked: usize, percent: u8) []const u8 {
    if (checked == 0) return "pill-info";
    if (percent >= COVERAGE_PASS_PCT) return "pill-pass";
    if (percent >= COVERAGE_WARN_PCT) return "pill-warn";
    return "pill-fail";
}

fn writeCoverageRow(w: anytype, label: []const u8, filled: usize, expected: usize) !void {
    if (expected == 0) return;
    const cls: []const u8 = if (filled == expected) "pass" else if (filled * 2 >= expected) "warn" else "fail";
    try w.print(
        "<tr><th>{s}</th><td class=\"{s}\">{d} / {d}</td></tr>",
        .{ label, cls, filled, expected },
    );
}

fn writeIncompleteInstances(w: anytype, instances: []const coverage.InstanceCoverage) !void {
    var any = false;
    for (instances) |ic| {
        if (!ic.complete) {
            any = true;
            break;
        }
    }
    if (!any) return;
    try w.writeAll(
        "<p class=\"hint\">Incomplete components:</p>" ++
            "<table class=\"coverage-missing\"><thead><tr><th>Ref</th><th>Component</th><th>Missing</th></tr></thead><tbody>",
    );
    for (instances) |ic| {
        if (ic.complete) continue;
        try w.writeAll(trCodeOpen);
        try writeHtmlEscaped(w, ic.ref_des);
        try w.writeAll(codeTdToCode);
        try writeHtmlEscaped(w, ic.component);
        try w.writeAll(codeTdSep);
        var first = true;
        for (ic.checks) |chk| {
            if (chk.ok) continue;
            if (!first) try w.writeAll(", ");
            first = false;
            try writeHtmlEscaped(w, categoryLabel(chk.category));
        }
        try w.writeAll(tdTrClose);
    }
    try w.writeAll("</tbody></table>");
}

fn categoryLabel(c: coverage.CheckCategory) []const u8 {
    return switch (c) {
        .value => "value",
        .footprint => "footprint",
        .mpn => "MPN",
        .manufacturer => "manufacturer",
        .datasheet => "datasheet",
        .requirements_verified => "requirements verified",
    };
}

/// Render the Assertions section — one row per `(assert …)` /
/// `(assert-range …)` outcome the evaluator collected, status-pilled and
/// shown verbatim. Skipped entirely when the slice is empty.
pub fn writeAssertions(w: anytype, assertions: []const review.AssertionReport) RenderError!void {
    if (assertions.len == 0) return;
    try w.writeAll("<section><h2>Assertions</h2>");
    try w.writeAll("<table><thead><tr><th>Status</th><th>Message</th></tr></thead><tbody>");
    for (assertions) |a| {
        try w.print("<tr><td><span class=\"pill pill-{s}\">{s}</span></td><td>", .{ @tagName(a.status), @tagName(a.status) });
        try writeHtmlEscaped(w, a.message);
        try w.writeAll(tdTrClose);
    }
    try w.writeAll(tableSectionClose);
}

fn writeFloatCell(w: anytype, v: ?f64) !void {
    if (v) |f| {
        try w.print("{d:.3}", .{f});
    } else {
        try w.writeAll(mutedDash);
    }
}

fn writeHtmlEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| switch (c) {
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '&' => try w.writeAll("&amp;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(c),
    };
}

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
