const std = @import("std");
const review = @import("review.zig");
const power_budget = @import("eval/power_budget.zig");
const power_sequencing = @import("eval/power_sequencing.zig");
const coverage = @import("coverage.zig");

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

/// CSS rules for review fragments. Embedded inline by `render_html.zig`'s
/// `<style>` block alongside the schematic page's own CSS so the embedded
/// review tables match the surrounding chrome without an extra request.
pub const body_css = @embedFile("assets/review.css");

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
                    "<thead><tr><th>Part</th><th>Ref</th><th>Net</th><th>Pins</th>" ++
                    "<th>i-typ (A)</th><th>i-max (A)</th></tr></thead><tbody>",
            );
            for (r.consumers) |c| {
                // Part: the (load "…") label if given, else the library
                // component, else the ref as a last resort.
                const part: []const u8 = if (c.label.len > 0) c.label else if (c.component.len > 0) c.component else c.ref_des;
                try w.writeAll(trCodeOpen);
                try writeHtmlEscaped(w, part);
                try w.writeAll(codeTdToCode);
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
