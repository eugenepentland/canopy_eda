const std = @import("std");
const review = @import("review.zig");
const erc_mod = @import("erc.zig");
const power_budget = @import("eval/power_budget.zig");
const power_sequencing = @import("eval/power_sequencing.zig");
const env_mod = @import("eval/env.zig");

/// Render a ReviewDoc as a self-contained HTML page. Inline CSS. One small
/// inline script plus a CDN marked.js bundle power the checklist/markdown
/// interactions. The header navbar matches the rest of the EDA web server.
pub fn renderToHtml(allocator: std.mem.Allocator, doc: review.ReviewDoc, navbar_css: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);

    try w.writeAll("<!DOCTYPE html><html><head><meta charset=\"utf-8\">");
    try w.writeAll("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">");
    try w.print("<title>{s} — Review</title>", .{doc.title});
    try w.writeAll("<style>");
    try w.writeAll(navbar_css);
    try w.writeAll(REVIEW_CSS);
    try w.writeAll("</style>");
    try w.writeAll("<script src=\"https://cdn.jsdelivr.net/npm/marked/marked.min.js\"></script>");
    try w.writeAll("</head><body>");
    try writeNavbar(w);
    try w.writeAll("<div class=\"review-wrap\">");

    try writeHeader(w, doc);
    try writeRequirements(w, doc);
    try writeSummaryTable(w, doc.summary);
    try writeSections(w, doc.sections, doc.review_state);
    try writePowerSequence(w, doc.power_sequence);
    try writeTestPoints(w, doc.test_points);
    try writePowerBudget(w, doc.power_budget);
    try writeUnresolved(w, doc.unresolved);
    try writeAssertions(w, doc.assertions);

    try w.writeAll("</div>");
    try writeScript(w, doc.design_name);
    try w.writeAll("</body></html>");
    return buf.items;
}

fn writeRequirements(w: anytype, doc: review.ReviewDoc) !void {
    try w.writeAll("<section><h2>Requirements</h2>");
    if (doc.requirements_markdown.len == 0) {
        try w.writeAll("<p class=\"hint\">No requirements doc. Create <code>projects/designs/reviews/");
        try writeHtmlEscaped(w, doc.design_name);
        try w.writeAll(".requirements.md</code> to populate this section.</p>");
    } else {
        try w.writeAll("<div id=\"requirements-doc\" class=\"requirements markdown-body\"></div>");
    }
    try w.writeAll("</section>");
}

fn writeNavbar(w: anytype) !void {
    try w.writeAll("<div class=\"navbar\"><span class=\"brand\">Canopy EDA</span>");
    try w.writeAll("<a href=\"/\">Designs</a>");
    try w.writeAll("<a href=\"/library\">Library</a>");
    try w.writeAll("<a href=\"/account\" style=\"margin-left:auto\">Account</a>");
    try w.writeAll("</div>");
}

fn writeHeader(w: anytype, doc: review.ReviewDoc) !void {
    const banner_class: []const u8 = switch (doc.summary.status) {
        .pass => "banner banner-pass",
        .warn => "banner banner-warn",
        .fail => "banner banner-fail",
    };
    const banner_label: []const u8 = switch (doc.summary.status) {
        .pass => "PASS",
        .warn => "REVIEW WITH WARNINGS",
        .fail => "NEEDS ATTENTION",
    };

    try w.writeAll("<header class=\"review-head\">");
    try w.writeAll("<div class=\"head-title\"><h1>");
    try writeHtmlEscaped(w, doc.title);
    try w.writeAll("</h1><div class=\"subtitle\">Design review for <code>");
    try writeHtmlEscaped(w, doc.design_name);
    try w.writeAll(".sexp</code> · generated ");
    try writeHtmlEscaped(w, doc.generated_at);
    try w.writeAll("</div></div>");

    try w.print("<div class=\"{s}\">{s}</div>", .{ banner_class, banner_label });
    try w.writeAll("<div class=\"head-links\">");
    try w.print("<a class=\"head-link\" href=\"/schematics/{s}\">Schematic</a>", .{doc.design_name});
    try w.print("<a class=\"head-link\" href=\"/pcb/{s}\">PCB</a>", .{doc.design_name});
    try w.print("<a class=\"head-link\" href=\"/api/review/{s}\">JSON</a>", .{doc.design_name});
    try w.writeAll("</div>");
    try w.writeAll("</header>");
}

fn writeSummaryTable(w: anytype, s: review.Summary) !void {
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
    try w.writeAll("</table></section>");
}

fn writePowerBudget(w: anytype, rails: []const power_budget.Rail) !void {
    if (rails.len == 0) return;
    try w.writeAll("<section><h2>Power budget</h2>");
    try w.writeAll("<p class=\"hint\">Rails sorted tightest first. Ferrite beads merge into upstream rails. Click a rail to see which components land on it.</p>");

    // Column headers — grid-aligned with each <details>/<summary> below.
    try w.writeAll("<div class=\"rail-head\">");
    try w.writeAll("<span></span>");
    try w.writeAll("<span>Rail</span><span>Source</span><span>Src typ</span><span>Src max</span><span>Load typ</span><span>Load max</span><span>Margin</span><span>Status</span>");
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
            try w.writeAll("<span class=\"muted\">—</span>");
        }
        try w.writeAll("</span>");
        try w.writeAll("<span>");
        try writeFloatCell(w, r.source_typ_a);
        try w.writeAll("</span><span>");
        try writeFloatCell(w, r.source_max_a);
        try w.writeAll("</span><span>");
        if (r.any_typ_load) try w.print("{d:.3}", .{r.load_typ_a}) else try w.writeAll("<span class=\"muted\">—</span>");
        try w.writeAll("</span><span>");
        if (r.any_max_load) try w.print("{d:.3}", .{r.load_max_a}) else try w.writeAll("<span class=\"muted\">—</span>");
        try w.writeAll("</span><span>");
        if (r.margin_pct) |m| try w.print("{d:.1}%", .{m}) else try w.writeAll("<span class=\"muted\">—</span>");
        try w.print("</span><span><span class=\"pill pill-{s}\">{s}</span></span>", .{ @tagName(r.status), statusLabel(r.status) });
        try w.writeAll("</summary>");

        if (r.consumers.len > 0) {
            try w.writeAll("<div class=\"rail-body\"><table class=\"consumer-table\"><thead><tr><th>Ref</th><th>Net</th><th>Pins</th><th>i-typ (A)</th><th>i-max (A)</th></tr></thead><tbody>");
            for (r.consumers) |c| {
                try w.writeAll("<tr><td><code>");
                try writeHtmlEscaped(w, c.ref_des);
                try w.writeAll("</code></td><td><code>");
                try writeHtmlEscaped(w, c.net);
                try w.writeAll("</code></td><td>");
                for (c.pins, 0..) |p, i| {
                    if (i > 0) try w.writeAll(", ");
                    try writeHtmlEscaped(w, p);
                }
                try w.writeAll("</td><td>");
                if (c.i_typ) |v| try w.print("{d:.4}", .{v}) else try w.writeAll("<span class=\"muted\">—</span>");
                try w.writeAll("</td><td>");
                if (c.i_max) |v| try w.print("{d:.4}", .{v}) else try w.writeAll("<span class=\"muted\">—</span>");
                try w.writeAll("</td></tr>");
            }
            try w.writeAll("</tbody></table></div>");
        } else {
            try w.writeAll("<div class=\"rail-body\"><p class=\"hint\">No annotated consumers on this rail. Add <code>(i-typ X) (i-max Y)</code> on pins connected here — or, for an upstream rail like VBATT, annotate the downstream regulator's input pins or use efficiency on its output port.</p></div>");
        }

        try w.writeAll("</details>");
    }
    try w.writeAll("</section>");
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

fn writePowerSequence(w: anytype, rows: []const power_sequencing.SequenceRow) !void {
    if (rows.len == 0) return;
    try w.writeAll("<section><h2>Power sequencing</h2>");
    try w.writeAll("<p class=\"hint\">Rails ordered top-down by power-up sequence. A rail's <code>enable</code> net must be stable before that rail comes up. Always-on rails have no enable and power up first.</p>");
    try w.writeAll("<table><thead><tr><th>#</th><th>Rail</th><th>Source</th><th>Enable</th><th>Depends on</th><th>Status</th></tr></thead><tbody>");
    for (rows) |r| {
        const row_class: []const u8 = switch (r.status) {
            .unresolved => " class=\"row-warn\"",
            else => "",
        };
        try w.print("<tr{s}><td>{d}</td><td><code>", .{ row_class, r.order + 1 });
        try writeHtmlEscaped(w, r.rail);
        try w.writeAll("</code></td><td><code>");
        try writeHtmlEscaped(w, r.source);
        try w.writeAll("</code></td><td>");
        if (r.enable.len > 0) {
            try w.writeAll("<code>");
            try writeHtmlEscaped(w, r.enable);
            try w.writeAll("</code>");
        } else {
            try w.writeAll("<span class=\"muted\">—</span>");
        }
        try w.writeAll("</td><td>");
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
            try w.writeAll("<span class=\"muted\">—</span>");
        }
        try w.print("</td><td><span class=\"pill pill-{s}\">{s}</span></td></tr>", .{ @tagName(r.status), sequenceLabel(r.status) });
    }
    try w.writeAll("</tbody></table></section>");
}

fn sequenceLabel(s: power_sequencing.SequenceStatus) []const u8 {
    return switch (s) {
        .ok => "OK",
        .unresolved => "UNRESOLVED",
        .always_on => "ALWAYS-ON",
    };
}

fn writeTestPoints(w: anytype, tps: []const review.TestPointEntry) !void {
    if (tps.len == 0) return;
    try w.writeAll("<section><h2>Test points</h2>");
    try w.writeAll("<p class=\"hint\">Physical probe pads on the board. Keep this list next to a multimeter when bringing up hardware.</p>");
    try w.writeAll("<table><thead><tr><th>Ref</th><th>Net</th><th>Purpose</th></tr></thead><tbody>");
    for (tps) |tp| {
        try w.writeAll("<tr><td><code>");
        try writeHtmlEscaped(w, tp.ref_des);
        try w.writeAll("</code></td><td>");
        if (tp.net.len > 0) {
            try w.writeAll("<code>");
            try writeHtmlEscaped(w, tp.net);
            try w.writeAll("</code>");
        } else {
            try w.writeAll("<span class=\"muted\">unconnected</span>");
        }
        try w.writeAll("</td><td>");
        if (tp.purpose.len > 0) {
            try writeHtmlEscaped(w, tp.purpose);
        } else {
            try w.writeAll("<span class=\"muted\">—</span>");
        }
        try w.writeAll("</td></tr>");
    }
    try w.writeAll("</tbody></table></section>");
}

fn writeUnresolved(w: anytype, vs: []const erc_mod.Violation) !void {
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
        try w.writeAll("</code></td><td>");
        if (v.ref_des.len > 0) try writeHtmlEscaped(w, v.ref_des) else try w.writeAll("<span class=\"muted\">—</span>");
        try w.writeAll("</td><td>");
        if (v.net.len > 0) try writeHtmlEscaped(w, v.net) else try w.writeAll("<span class=\"muted\">—</span>");
        try w.writeAll("</td><td>");
        try writeHtmlEscaped(w, v.message);
        try w.writeAll("</td></tr>");
    }
    try w.writeAll("</tbody></table></section>");
}

fn writeSections(w: anytype, sections: []const review.SectionReport, state: review.ReviewState) !void {
    if (sections.len == 0) return;
    try w.writeAll("<section><h2>Sections</h2>");
    for (sections) |s| {
        const status_pill: []const u8 = switch (s.status) {
            .concept => "pill-concept",
            .implemented => "pill-ok",
            .review => "pill-warn",
        };
        const rs = findState(state, s.slug);
        const card_class: []const u8 = if (rs.approved) " sec-card-approved" else "";
        try w.print("<div class=\"sec-card{s}\" id=\"sec-{s}\" data-slug=\"{s}\">", .{ card_class, s.slug, s.slug });
        try w.writeAll("<div class=\"sec-head\"><h3>");
        try writeHtmlEscaped(w, s.name);
        try w.print("</h3><span class=\"pill {s}\">{s}</span>", .{ status_pill, @tagName(s.status) });
        if (rs.approved) {
            try w.writeAll("<span class=\"pill pill-approved\">APPROVED</span>");
        }
        try w.print("<span class=\"muted sec-count\">{d} component{s}</span>", .{ s.instance_count, if (s.instance_count == 1) "" else "s" });
        try w.writeAll("</div>");

        if (s.description.len > 0) {
            try w.writeAll("<p class=\"sec-desc\">");
            try writeHtmlEscaped(w, s.description);
            try w.writeAll("</p>");
        }

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

        if (s.notes.len > 0) {
            try w.writeAll("<details class=\"sec-notes\"><summary>Design notes");
            try w.print(" ({d})</summary><ul>", .{s.notes.len});
            for (s.notes) |n| {
                try w.writeAll("<li>");
                try writeHtmlEscaped(w, n);
                try w.writeAll("</li>");
            }
            try w.writeAll("</ul></details>");
        }

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

        try writeChecklist(w, rs);

        try w.writeAll("</div>");
    }
    try w.writeAll("</section>");
}

fn writeChecklist(w: anytype, rs: review.SectionReviewState) !void {
    const checked_count = countChecked(rs.items);
    try w.writeAll("<details class=\"sec-checklist\" open><summary>Review checklist");
    try w.print(" <span class=\"chk-progress\">({d}/{d})</span>", .{ checked_count, rs.items.len });
    if (rs.approved) {
        try w.writeAll(" <span class=\"chk-status chk-status-approved\">Approved");
        if (rs.approved_by.len > 0) {
            try w.writeAll(" by ");
            try writeHtmlEscaped(w, rs.approved_by);
        }
        if (rs.approved_at.len > 0) {
            try w.writeAll(" · ");
            try writeHtmlEscaped(w, rs.approved_at);
        }
        try w.writeAll("</span>");
    } else {
        try w.writeAll(" <span class=\"chk-status chk-status-pending\">Pending</span>");
    }
    try w.writeAll("</summary>");

    try w.writeAll("<ul class=\"chk-list\">");
    for (rs.items) |it| {
        const is_checked: []const u8 = if (it.checked) " checked" else "";
        try w.print("<li data-id=\"{s}\"><label><input type=\"checkbox\" class=\"chk-box\"{s}> ", .{ it.id, is_checked });
        try writeHtmlEscaped(w, it.text);
        try w.writeAll("</label><button class=\"chk-del\" title=\"Delete\">✕</button></li>");
    }
    try w.writeAll("</ul>");

    try w.writeAll("<div class=\"chk-add\">");
    try w.writeAll("<input type=\"text\" class=\"chk-new\" placeholder=\"Add a check (e.g. Power pins wired)\">");
    try w.writeAll("<button class=\"chk-add-btn\">Add</button>");
    try w.writeAll("</div>");

    try w.writeAll("<div class=\"chk-approve-row\">");
    try w.writeAll("<input type=\"text\" class=\"chk-reviewer\" placeholder=\"Reviewer name\" value=\"");
    try writeHtmlEscaped(w, rs.approved_by);
    try w.writeAll("\">");
    if (rs.approved) {
        try w.writeAll("<button class=\"chk-approve-btn\" data-approve=\"false\">Unapprove</button>");
    } else {
        try w.writeAll("<button class=\"chk-approve-btn\" data-approve=\"true\">Approve section</button>");
    }
    try w.writeAll("</div></details>");
}

fn findState(state: review.ReviewState, slug: []const u8) review.SectionReviewState {
    for (state.sections) |s| {
        if (std.mem.eql(u8, s.section_slug, slug)) return s;
    }
    return .{ .section_slug = slug, .items = &.{}, .approved = false, .approved_by = "", .approved_at = "" };
}

fn countChecked(items: []const review.ChecklistItem) usize {
    var n: usize = 0;
    for (items) |it| if (it.checked) {
        n += 1;
    };
    return n;
}

fn writeAssertions(w: anytype, assertions: []const review.AssertionReport) !void {
    if (assertions.len == 0) return;
    try w.writeAll("<section><h2>Assertions</h2>");
    try w.writeAll("<table><thead><tr><th>Status</th><th>Message</th></tr></thead><tbody>");
    for (assertions) |a| {
        try w.print("<tr><td><span class=\"pill pill-{s}\">{s}</span></td><td>", .{ @tagName(a.status), @tagName(a.status) });
        try writeHtmlEscaped(w, a.message);
        try w.writeAll("</td></tr>");
    }
    try w.writeAll("</tbody></table></section>");
}

fn writeBom(w: anytype, groups: []const review.BomGroup) !void {
    if (groups.len == 0) return;
    try w.writeAll("<section><h2>Bill of Materials</h2>");
    for (groups) |g| {
        try w.writeAll("<details class=\"bom-group\"><summary>");
        try writeHtmlEscaped(w, g.prefix);
        try w.print(" ({d})</summary>", .{g.entries.len});
        try w.writeAll("<table><thead><tr><th>Ref</th><th>Component</th><th>Value</th><th>Footprint</th></tr></thead><tbody>");
        for (g.entries) |e| {
            try w.writeAll("<tr><td><code>");
            try writeHtmlEscaped(w, e.ref_des);
            try w.writeAll("</code></td><td><code>");
            try writeHtmlEscaped(w, e.component);
            try w.writeAll("</code></td><td>");
            try writeHtmlEscaped(w, e.value);
            try w.writeAll("</td><td><code>");
            try writeHtmlEscaped(w, e.footprint);
            try w.writeAll("</code></td></tr>");
        }
        try w.writeAll("</tbody></table></details>");
    }
    try w.writeAll("</section>");
}

fn writeFloatCell(w: anytype, v: ?f64) !void {
    if (v) |f| {
        try w.print("{d:.3}", .{f});
    } else {
        try w.writeAll("<span class=\"muted\">—</span>");
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

const REVIEW_CSS =
    \\body{margin:0;background:#0d1117;color:#c9d1d9;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;}
    \\.review-wrap{max-width:1100px;margin:0 auto;padding:24px 20px 48px;}
    \\h1{color:#f0f6fc;margin:0;font-size:1.6rem;}
    \\h2{color:#f0f6fc;font-size:1.15rem;border-bottom:1px solid #21262d;padding-bottom:6px;margin:28px 0 12px;}
    \\h3{margin:0;color:#f0f6fc;font-size:1rem;}
    \\code{font-family:"SF Mono","Fira Code",monospace;font-size:0.9em;color:#c9d1d9;background:#161b22;padding:1px 5px;border-radius:3px;}
    \\a{color:#58a6ff;text-decoration:none;}
    \\a:hover{text-decoration:underline;}
    \\.review-head{display:grid;grid-template-columns:1fr auto;gap:12px;align-items:center;padding:16px 0;border-bottom:1px solid #21262d;}
    \\.head-title{grid-column:1;}
    \\.subtitle{color:#8b949e;font-size:0.9rem;margin-top:4px;}
    \\.banner{grid-column:2;padding:10px 20px;border-radius:6px;font-weight:700;letter-spacing:0.04em;font-size:0.85rem;}
    \\.banner-pass{background:#0d3a1f;color:#3fb950;border:1px solid #1e5631;}
    \\.banner-warn{background:#3a2e0d;color:#d29922;border:1px solid #5b4617;}
    \\.banner-fail{background:#3a0d16;color:#f85149;border:1px solid #5b1e28;}
    \\.head-links{grid-column:1/-1;display:flex;gap:8px;margin-top:8px;}
    \\.head-link{padding:5px 12px;border:1px solid #30363d;border-radius:5px;color:#8b949e;font-size:0.85rem;}
    \\.head-link:hover{border-color:#58a6ff;color:#c9d1d9;text-decoration:none;}
    \\table{width:100%;border-collapse:collapse;margin:8px 0;}
    \\th,td{text-align:left;padding:7px 10px;border-bottom:1px solid #21262d;font-size:0.9rem;}
    \\th{background:#161b22;color:#8b949e;font-weight:600;text-transform:uppercase;font-size:0.75rem;letter-spacing:0.03em;}
    \\table.summary td{font-family:"SF Mono","Fira Code",monospace;}
    \\.row-fail{background:rgba(248,81,73,0.08);}
    \\.row-warn{background:rgba(210,153,34,0.08);}
    \\.pill{display:inline-block;padding:1px 8px;border-radius:10px;font-size:0.72rem;font-weight:600;text-transform:uppercase;letter-spacing:0.04em;}
    \\.pill-pass,.pill-ok{background:#0d3a1f;color:#3fb950;}
    \\.pill-warn,.pill-tight{background:#3a2e0d;color:#d29922;}
    \\.pill-fail,.pill-over,.pill-error{background:#3a0d16;color:#f85149;}
    \\.pill-info,.pill-no_source,.pill-no_consumers,.pill-always_on{background:#1a2332;color:#8b949e;}
    \\.pill-unresolved{background:#3a2e0d;color:#d29922;}
    \\.pill-concept{background:#24232e;color:#a89eff;}
    \\.pass{color:#3fb950;}
    \\.warn{color:#d29922;}
    \\.fail{color:#f85149;}
    \\.muted{color:#6e7681;}
    \\.hint{color:#8b949e;font-size:0.85rem;margin:4px 0 10px;}
    \\.sec-card{background:#161b22;border:1px solid #21262d;border-radius:8px;padding:14px 16px;margin-bottom:12px;}
    \\.sec-head{display:flex;align-items:center;gap:10px;flex-wrap:wrap;}
    \\.sec-count{margin-left:auto;font-size:0.85rem;}
    \\.sec-desc{margin:6px 0 8px;color:#8b949e;font-size:0.9rem;}
    \\details{margin:8px 0;}
    \\summary{cursor:pointer;color:#8b949e;font-size:0.85rem;padding:4px 0;}
    \\summary:hover{color:#c9d1d9;}
    \\details ul{margin:6px 0 0 20px;padding:0;}
    \\details li{margin:3px 0;font-size:0.88rem;color:#c9d1d9;line-height:1.45;}
    \\.bom-group>table{margin-top:4px;}
    \\.rail-head,.rail-sum{display:grid;grid-template-columns:24px 90px 140px 80px 80px 80px 80px 70px 110px;align-items:center;gap:8px;padding:7px 10px;font-size:0.9rem;}
    \\.rail-head{background:#161b22;color:#8b949e;font-weight:600;text-transform:uppercase;font-size:0.72rem;letter-spacing:0.03em;border-bottom:1px solid #21262d;}
    \\details.rail{border-bottom:1px solid #21262d;}
    \\details.rail.row-fail>summary{background:rgba(248,81,73,0.08);}
    \\details.rail.row-warn>summary{background:rgba(210,153,34,0.08);}
    \\.rail-sum{cursor:pointer;list-style:none;}
    \\.rail-sum::-webkit-details-marker{display:none;}
    \\.rail-sum:hover{background:#1a1f27;}
    \\.rail-caret{color:#6e7681;font-size:0.8rem;transition:transform 0.15s;}
    \\details[open]>.rail-sum>.rail-caret{transform:rotate(90deg);}
    \\.rail-body{background:#0a0e14;padding:4px 12px 12px 44px;}
    \\.consumer-table{font-size:0.85rem;}
    \\.consumer-table th{font-size:0.7rem;background:transparent;}
    \\.consumer-table td{font-family:"SF Mono","Fira Code",monospace;}
    \\.requirements{background:#0a0e14;border:1px solid #21262d;border-radius:6px;padding:4px 18px;line-height:1.55;}
    \\.requirements h1,.requirements h2,.requirements h3{color:#f0f6fc;border:0;margin:14px 0 8px;}
    \\.requirements h1{font-size:1.25rem;}
    \\.requirements h2{font-size:1.1rem;}
    \\.requirements h3{font-size:1rem;}
    \\.requirements ul,.requirements ol{margin:6px 0 10px 22px;}
    \\.requirements li{margin:3px 0;}
    \\.requirements code{background:#161b22;}
    \\.requirements pre{background:#161b22;border:1px solid #21262d;border-radius:4px;padding:10px;overflow:auto;}
    \\.requirements p{margin:8px 0;}
    \\.requirements blockquote{border-left:3px solid #30363d;margin:8px 0;padding:2px 12px;color:#8b949e;}
    \\.pill-approved{background:#0d3a1f;color:#3fb950;}
    \\.sec-card-approved{border-left:3px solid #3fb950;}
    \\.sec-checklist{margin-top:10px;padding-top:8px;border-top:1px solid #21262d;}
    \\.sec-checklist>summary{color:#c9d1d9;font-weight:600;font-size:0.9rem;}
    \\.chk-progress{color:#8b949e;font-weight:400;}
    \\.chk-status{font-size:0.75rem;font-weight:600;padding:2px 8px;border-radius:10px;text-transform:uppercase;letter-spacing:0.04em;margin-left:6px;}
    \\.chk-status-approved{background:#0d3a1f;color:#3fb950;}
    \\.chk-status-pending{background:#24232e;color:#a89eff;}
    \\.chk-list{list-style:none;margin:8px 0;padding:0;}
    \\.chk-list li{display:flex;align-items:center;gap:8px;padding:4px 0;margin:0;border-bottom:1px solid #1a1f27;}
    \\.chk-list li:last-child{border-bottom:0;}
    \\.chk-list label{flex:1;cursor:pointer;color:#c9d1d9;font-size:0.9rem;display:flex;align-items:center;gap:8px;}
    \\.chk-box{width:16px;height:16px;cursor:pointer;accent-color:#3fb950;}
    \\.chk-box:checked + * {color:#8b949e;text-decoration:line-through;}
    \\.chk-del{background:transparent;color:#6e7681;border:0;cursor:pointer;font-size:0.9rem;padding:2px 6px;border-radius:3px;}
    \\.chk-del:hover{background:#3a0d16;color:#f85149;}
    \\.chk-add,.chk-approve-row{display:flex;gap:6px;margin-top:8px;}
    \\.chk-new,.chk-reviewer{flex:1;background:#0a0e14;color:#c9d1d9;border:1px solid #30363d;border-radius:4px;padding:5px 10px;font-size:0.88rem;font-family:inherit;}
    \\.chk-new:focus,.chk-reviewer:focus{outline:none;border-color:#58a6ff;}
    \\.chk-add-btn,.chk-approve-btn{background:#21262d;color:#c9d1d9;border:1px solid #30363d;border-radius:4px;padding:5px 14px;font-size:0.85rem;cursor:pointer;font-weight:600;}
    \\.chk-add-btn:hover,.chk-approve-btn:hover{background:#30363d;border-color:#58a6ff;}
    \\.chk-approve-btn{background:#0d3a1f;color:#3fb950;border-color:#1e5631;}
    \\.chk-approve-btn[data-approve="false"]{background:#3a2e0d;color:#d29922;border-color:#5b4617;}
    \\.chk-approve-btn:hover{filter:brightness(1.2);}
;

fn writeScript(w: anytype, design_name: []const u8) !void {
    try w.writeAll("<script>var DESIGN_NAME=");
    try writeJsString(w, design_name);
    try w.writeAll(";");
    try w.writeAll(CHECKLIST_JS);
    try w.writeAll("</script>");
}

fn writeJsString(w: anytype, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '<' => try w.writeAll("\\u003c"),
        '>' => try w.writeAll("\\u003e"),
        '&' => try w.writeAll("\\u0026"),
        0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeAll("\"");
}

const CHECKLIST_JS =
    \\(function(){
    \\  var reqEl=document.getElementById('requirements-doc');
    \\  if(reqEl&&window.marked){
    \\    fetch('/api/requirements/'+encodeURIComponent(DESIGN_NAME))
    \\      .then(function(r){return r.ok?r.text():''})
    \\      .then(function(md){if(md)reqEl.innerHTML=marked.parse(md);});
    \\  }
    \\  function post(path,body){
    \\    return fetch(path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)})
    \\      .then(function(r){if(!r.ok)throw new Error('HTTP '+r.status);return r;});
    \\  }
    \\  function base(){return '/api/review-state/'+encodeURIComponent(DESIGN_NAME);}
    \\  function sectionSlug(el){var c=el.closest('.sec-card');return c?c.getAttribute('data-slug'):null;}
    \\  document.addEventListener('change',function(e){
    \\    if(!e.target.classList.contains('chk-box'))return;
    \\    var slug=sectionSlug(e.target);
    \\    var li=e.target.closest('li');
    \\    if(!slug||!li)return;
    \\    post(base()+'/item/toggle',{section_slug:slug,id:li.getAttribute('data-id'),checked:e.target.checked})
    \\      .then(function(){location.reload();}).catch(function(err){alert('Toggle failed: '+err.message);});
    \\  });
    \\  document.addEventListener('click',function(e){
    \\    var t=e.target;
    \\    if(t.classList.contains('chk-add-btn')){
    \\      var row=t.closest('.chk-add');var input=row.querySelector('.chk-new');
    \\      var text=input.value.trim();if(!text)return;
    \\      var slug=sectionSlug(t);if(!slug)return;
    \\      post(base()+'/item',{section_slug:slug,text:text}).then(function(){location.reload();})
    \\        .catch(function(err){alert('Add failed: '+err.message);});
    \\    }else if(t.classList.contains('chk-del')){
    \\      var li=t.closest('li');var slug=sectionSlug(t);if(!li||!slug)return;
    \\      post(base()+'/item/delete',{section_slug:slug,id:li.getAttribute('data-id')}).then(function(){location.reload();})
    \\        .catch(function(err){alert('Delete failed: '+err.message);});
    \\    }else if(t.classList.contains('chk-approve-btn')){
    \\      var row=t.closest('.chk-approve-row');var input=row.querySelector('.chk-reviewer');
    \\      var approved=t.getAttribute('data-approve')==='true';
    \\      var reviewer=input.value.trim();
    \\      if(approved&&!reviewer){alert('Enter a reviewer name before approving.');input.focus();return;}
    \\      var slug=sectionSlug(t);if(!slug)return;
    \\      post(base()+'/approve',{section_slug:slug,approved:approved,reviewer:reviewer}).then(function(){location.reload();})
    \\        .catch(function(err){alert('Approve failed: '+err.message);});
    \\    }
    \\  });
    \\})();
;
