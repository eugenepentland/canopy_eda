//! Renders the assembled `review.ReviewDoc` to JSON — the machine-readable
//! twin of `review_html.zig`, for API and MCP consumers of the design review.

const std = @import("std");
const json_writer = @import("json_writer.zig");
const review = @import("review.zig");
const erc_mod = @import("erc.zig");
const power_budget = @import("eval/power_budget.zig");
const power_sequencing = @import("eval/power_sequencing.zig");

// ── Repeated string literals ──────────────────────────────────────
const component_key: []const u8 = ",\"component\":";
const net_key: []const u8 = ",\"net\":";
const status_fmt: []const u8 = ",\"status\":\"{s}\"";
const ref_des_open: []const u8 = "{\"ref_des\":";

/// Serialize a ReviewDoc to JSON. Field names are snake_case. Consumers
/// (the web UI and the `generate_review` MCP tool) rely on the schema being
/// stable, so changes should be strictly additive.
pub fn renderToJson(allocator: std.mem.Allocator, doc: review.ReviewDoc) std.mem.Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(allocator);

    try w.writeAll("{\"design_name\":");
    try json_writer.writeString(w, doc.design_name);
    try w.writeAll(",\"title\":");
    try json_writer.writeString(w, doc.title);
    try w.writeAll(",\"generated_at\":");
    try json_writer.writeString(w, doc.generated_at);

    try w.writeAll(",\"revision\":");
    if (doc.revision.present) {
        try w.writeAll("{\"id\":");
        try json_writer.writeString(w, doc.revision.id);
        try w.writeAll(",\"date\":");
        try json_writer.writeString(w, doc.revision.date);
        try w.writeAll(",\"changes\":[");
        for (doc.revision.changes, 0..) |c, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"id\":");
            try json_writer.writeString(w, c.id);
            try w.writeAll(",\"summary\":");
            try json_writer.writeString(w, c.summary);
            try w.writeAll("}");
        }
        try w.writeAll("]}");
    } else {
        try w.writeAll("null");
    }

    try w.writeAll(",\"summary\":");
    try writeSummary(w, doc.summary);

    try w.writeAll(",\"sections\":[");
    for (doc.sections, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try writeSection(w, s);
    }
    try w.writeAll("]");

    try w.writeAll(",\"power_budget\":[");
    for (doc.power_budget, 0..) |r, i| {
        if (i > 0) try w.writeAll(",");
        try writeRail(w, r);
    }
    try w.writeAll("]");

    try w.writeAll(",\"power_tree\":{\"nodes\":[");
    for (doc.power_tree.nodes, 0..) |n, i| {
        if (i > 0) try w.writeAll(",");
        try writePowerTreeNode(w, n);
    }
    try w.writeAll("],\"edges\":[");
    for (doc.power_tree.edges, 0..) |e, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"from\":");
        try json_writer.writeString(w, e.from);
        try w.writeAll(",\"to\":");
        try json_writer.writeString(w, e.to);
        try w.writeAll("}");
    }
    try w.writeAll("]}");

    try w.writeAll(",\"power_sequence\":[");
    for (doc.power_sequence, 0..) |r, i| {
        if (i > 0) try w.writeAll(",");
        try writeSequenceRow(w, r);
    }
    try w.writeAll("]");

    try w.writeAll(",\"test_points\":[");
    for (doc.test_points, 0..) |tp, i| {
        if (i > 0) try w.writeAll(",");
        try writeTestPoint(w, tp);
    }
    try w.writeAll("]");

    try w.writeAll(",\"bom\":[");
    for (doc.bom, 0..) |g, i| {
        if (i > 0) try w.writeAll(",");
        try writeBomGroup(w, g);
    }
    try w.writeAll("]");

    try w.writeAll(",\"assertions\":[");
    for (doc.assertions, 0..) |a, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"message\":");
        try json_writer.writeString(w, a.message);
        try w.writeAll(",\"status\":\"");
        try w.writeAll(@tagName(a.status));
        try w.writeAll("\"}");
    }
    try w.writeAll("]");

    try w.writeAll(",\"unresolved\":[");
    for (doc.unresolved, 0..) |v, i| {
        if (i > 0) try w.writeAll(",");
        try writeViolation(w, v);
    }
    try w.writeAll("]");

    try w.writeAll(",\"subblock_requirements\":");
    try writeComponentRequirements(w, doc.subblock_requirements);

    try w.writeAll("}");
    return buf.items;
}

fn boolStr(b: bool) []const u8 {
    return if (b) "true" else "false";
}

fn writeComponentRequirements(
    w: anytype,
    entries: []const review.ComponentRequirementEntry,
) !void {
    try w.writeAll("[");
    for (entries, 0..) |entry, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll(ref_des_open);
        try json_writer.writeString(w, entry.ref_des);
        try w.writeAll(component_key);
        try json_writer.writeString(w, entry.component);
        try w.writeAll(",\"requirements\":[");
        for (entry.requirements, 0..) |r, j| {
            if (j > 0) try w.writeAll(",");
            try w.writeAll("{\"text\":");
            try json_writer.writeString(w, r.text);
            if (r.id.len > 0) {
                try w.writeAll(",\"id\":");
                try json_writer.writeString(w, r.id);
            }
            if (r.ref) |ref| {
                try w.writeAll(",\"pdf\":");
                try json_writer.writeString(w, ref.pdf);
                try w.print(",\"page\":{d}", .{ref.page});
            }
            const status_tag: []const u8 = if (j < entry.req_results.len)
                @tagName(entry.req_results[j].status)
            else
                "na";
            try w.print(status_fmt, .{status_tag});
            if (j < entry.req_results.len) {
                const rr = entry.req_results[j];
                if (rr.message.len > 0) {
                    try w.writeAll(",\"check_message\":");
                    try json_writer.writeString(w, rr.message);
                }
                if (rr.verification) |v| {
                    if (rr.status == .fail) {
                        try w.writeAll(",\"overridden_by_note\":true");
                    }
                    try w.writeAll(",\"verified_by\":{\"rationale\":");
                    try json_writer.writeString(w, v.rationale);
                    if (v.signed_by.len > 0) {
                        try w.writeAll(",\"signed_by\":");
                        try json_writer.writeString(w, v.signed_by);
                    }
                    if (v.date.len > 0) {
                        try w.writeAll(",\"date\":");
                        try json_writer.writeString(w, v.date);
                    }
                    try w.writeAll("}");
                }
            }
            try w.writeAll("}");
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]");
}

fn writeSummary(w: anytype, s: review.Summary) !void {
    try w.print(
        "{{\"status\":\"{s}\",\"section_count\":{d}," ++
            "\"instance_count\":{d},\"net_count\":{d}," ++
            "\"violations\":{{\"error\":{d},\"warning\":{d},\"info\":{d}}}," ++
            "\"assertions\":{{\"pass\":{d},\"warn\":{d},\"fail\":{d}}}",
        .{
            @tagName(s.status),
            s.section_count,
            s.instance_count,
            s.net_count,
            s.violation_error,
            s.violation_warning,
            s.violation_info,
            s.assertion_pass,
            s.assertion_warn,
            s.assertion_fail,
        },
    );
    try w.print(
        ",\"overall_coverage\":{{\"checked\":{d},\"complete\":{d},\"missing\":{d},\"percent\":{d}}}",
        .{
            s.overall_coverage.checked,
            s.overall_coverage.complete,
            s.overall_coverage.missing_total,
            s.overall_coverage.percent,
        },
    );
    try w.writeAll("}");
}

fn writeSection(w: anytype, s: review.SectionReport) !void {
    try w.writeAll("{\"name\":");
    try json_writer.writeString(w, s.name);
    try w.writeAll(",\"slug\":");
    try json_writer.writeString(w, s.slug);
    try w.print(status_fmt, .{@tagName(s.status)});
    try w.writeAll(",\"description\":");
    try json_writer.writeString(w, s.description);
    try w.print(",\"instance_count\":{d}", .{s.instance_count});

    try w.writeAll(",\"notes\":[");
    for (s.notes, 0..) |n, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"text\":");
        try json_writer.writeString(w, n.text);
        if (n.ref) |r| {
            try w.writeAll(",\"pdf\":");
            try json_writer.writeString(w, r.pdf);
            try w.print(",\"page\":{d}", .{r.page});
        }
        try w.writeAll("}");
    }
    try w.writeAll("]");

    try w.writeAll(",\"component_requirements\":");
    try writeComponentRequirements(w, s.component_requirements);

    try w.writeAll(",\"ports\":[");
    for (s.ports, 0..) |p, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try json_writer.writeString(w, p.name);
        try w.print(",\"direction\":\"{s}\"", .{p.direction});
        try w.print(",\"signal_type\":\"{s}\"", .{p.signal_type});
        if (p.voltage) |v| try w.print(",\"voltage\":{d}", .{v}) else try w.writeAll(",\"voltage\":null");
        if (p.role.len > 0) {
            try w.writeAll(",\"role\":");
            try json_writer.writeString(w, p.role);
        }
        if (p.protocol.len > 0) {
            try w.writeAll(",\"protocol\":");
            try json_writer.writeString(w, p.protocol);
        }
        try w.writeAll("}");
    }
    try w.writeAll("]");

    try writeBoundaryContracts(w, s.ports);

    try w.writeAll(",\"violations\":[");
    for (s.violations, 0..) |v, i| {
        if (i > 0) try w.writeAll(",");
        try writeViolation(w, v);
    }
    try w.writeAll("]");

    try writeSectionCoverage(w, s.coverage);

    try w.writeAll("}");
}

/// Emit the per-section `"coverage"` block: a `checked`/`complete` pair
/// plus per-category `filled`/`expected` maps so consumers can render
/// "MPN N/M" tables without re-walking instances. Always emits the key
/// (zero-counts when no checkable instances) so JSON schema stays
/// stable.
fn writeSectionCoverage(w: anytype, c: @import("coverage.zig").SectionCoverage) !void {
    try w.print(
        ",\"coverage\":{{\"checked\":{d},\"complete\":{d}",
        .{ c.checked, c.complete },
    );
    try w.print(
        ",\"filled\":{{\"value\":{d},\"footprint\":{d},\"mpn\":{d},\"manufacturer\":{d},\"datasheet\":{d},\"requirements_verified\":{d}}}",
        .{
            c.filled.value,
            c.filled.footprint,
            c.filled.mpn,
            c.filled.manufacturer,
            c.filled.datasheet,
            c.filled.requirements_verified,
        },
    );
    try w.print(
        ",\"expected\":{{\"value\":{d},\"footprint\":{d},\"mpn\":{d},\"manufacturer\":{d},\"datasheet\":{d},\"requirements_verified\":{d}}}",
        .{
            c.expected.value,
            c.expected.footprint,
            c.expected.mpn,
            c.expected.manufacturer,
            c.expected.datasheet,
            c.expected.requirements_verified,
        },
    );
    try w.writeAll("}");
}

/// Emit a `boundary_contracts` array containing one object per port that
/// declared `(electrical ...)` on its `(port …)` form. Matches the
/// "Boundary contracts" table in the review HTML — filters out ports
/// without electrical metadata so consumers don't have to walk the full
/// port list. Always emits the key (empty array when none) so JSON
/// schema stays stable.
fn writeBoundaryContracts(w: anytype, ports: []const review.PortSummary) !void {
    try w.writeAll(",\"boundary_contracts\":[");
    var first = true;
    for (ports) |p| {
        const e = p.electrical orelse continue;
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("{\"port\":");
        try json_writer.writeString(w, p.name);
        try w.print(",\"direction\":\"{s}\"", .{p.direction});
        if (e.electrical_type) |t| try w.print(",\"type\":\"{s}\"", .{@tagName(t)}) else try w.writeAll(",\"type\":null");
        if (e.drive) |d| try w.print(",\"drive\":\"{s}\"", .{@tagName(d)}) else try w.writeAll(",\"drive\":null");
        try w.writeAll(",\"v_oh_typ\":");
        try writeFloatOrNull(w, e.v_oh_typ);
        try w.writeAll(",\"v_ol_typ\":");
        try writeFloatOrNull(w, e.v_ol_typ);
        try w.writeAll(",\"v_ih_min\":");
        try writeFloatOrNull(w, e.v_ih_min);
        try w.writeAll(",\"v_il_max\":");
        try writeFloatOrNull(w, e.v_il_max);
        try w.writeAll(",\"max_voltage\":");
        try writeFloatOrNull(w, e.max_voltage);
        try w.writeAll(",\"domain\":");
        if (e.domain.len > 0) try json_writer.writeString(w, e.domain) else try w.writeAll("null");
        try w.writeAll("}");
    }
    try w.writeAll("]");
}

fn writePowerTreeNode(w: anytype, n: review.PowerTreeNode) !void {
    try w.writeAll("{\"rail\":");
    try json_writer.writeString(w, n.rail);
    try w.print(",\"layer\":{d}", .{n.layer});
    if (n.nominal) |v| try w.print(",\"nominal\":{d}", .{v});
    if (n.source_ref_des.len > 0) {
        try w.writeAll(",\"source_ref_des\":");
        try json_writer.writeString(w, n.source_ref_des);
    }
    try w.writeAll("}");
}

fn writeRail(w: anytype, r: power_budget.Rail) !void {
    try w.writeAll("{\"net\":");
    try json_writer.writeString(w, r.net);
    try w.writeAll(",\"source\":");
    if (r.source_label.len > 0) try json_writer.writeString(w, r.source_label) else try w.writeAll("null");
    try w.writeAll(",\"source_typ_a\":");
    try writeFloatOrNull(w, r.source_typ_a);
    try w.writeAll(",\"source_max_a\":");
    try writeFloatOrNull(w, r.source_max_a);
    try w.print(",\"load_typ_a\":{d:.4},\"load_max_a\":{d:.4}", .{ r.load_typ_a, r.load_max_a });
    try w.writeAll(",\"margin_pct\":");
    try writeFloatOrNull(w, r.margin_pct);
    try w.print(status_fmt, .{@tagName(r.status)});
    try w.writeAll(",\"consumers\":[");
    for (r.consumers, 0..) |c, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"ref\":");
        try json_writer.writeString(w, c.ref_des);
        try w.writeAll(",\"component\":");
        try json_writer.writeString(w, c.component);
        try w.writeAll(",\"label\":");
        try json_writer.writeString(w, c.label);
        try w.writeAll(net_key);
        try json_writer.writeString(w, c.net);
        try w.writeAll(",\"pins\":[");
        for (c.pins, 0..) |p, j| {
            if (j > 0) try w.writeAll(",");
            try json_writer.writeString(w, p);
        }
        try w.writeAll("],\"i_typ\":");
        try writeFloatOrNull(w, c.i_typ);
        try w.writeAll(",\"i_max\":");
        try writeFloatOrNull(w, c.i_max);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

fn writeSequenceRow(w: anytype, r: power_sequencing.SequenceRow) !void {
    try w.writeAll("{\"rail\":");
    try json_writer.writeString(w, r.rail);
    try w.writeAll(",\"source\":");
    try json_writer.writeString(w, r.source);
    try w.writeAll(",\"enable\":");
    if (r.enable.len > 0) try json_writer.writeString(w, r.enable) else try w.writeAll("null");
    try w.writeAll(",\"depends_on\":");
    if (r.depends_on.len > 0) try json_writer.writeString(w, r.depends_on) else try w.writeAll("null");
    try w.writeAll(",\"via\":");
    if (r.via.len > 0) try json_writer.writeString(w, r.via) else try w.writeAll("null");
    try w.print(",\"order\":{d},\"status\":\"{s}\"}}", .{ r.order, @tagName(r.status) });
}

fn writeTestPoint(w: anytype, tp: review.TestPointEntry) !void {
    try w.writeAll(ref_des_open);
    try json_writer.writeString(w, tp.ref_des);
    try w.writeAll(net_key);
    if (tp.net.len > 0) try json_writer.writeString(w, tp.net) else try w.writeAll("null");
    try w.writeAll(",\"purpose\":");
    if (tp.purpose.len > 0) try json_writer.writeString(w, tp.purpose) else try w.writeAll("null");
    try w.writeAll("}");
}

fn writeBomGroup(w: anytype, g: review.BomGroup) !void {
    try w.writeAll("{\"prefix\":");
    try json_writer.writeString(w, g.prefix);
    try w.writeAll(",\"entries\":[");
    for (g.entries, 0..) |e, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll(ref_des_open);
        try json_writer.writeString(w, e.ref_des);
        try w.writeAll(component_key);
        try json_writer.writeString(w, e.component);
        try w.writeAll(",\"value\":");
        try json_writer.writeString(w, e.value);
        try w.writeAll(",\"footprint\":");
        try json_writer.writeString(w, e.footprint);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

fn writeViolation(w: anytype, v: erc_mod.Violation) !void {
    try w.writeAll("{\"kind\":\"");
    try w.writeAll(@tagName(v.kind));
    try w.writeAll("\",\"severity\":\"");
    try w.writeAll(@tagName(v.severity));
    try w.writeAll("\",\"message\":");
    try json_writer.writeString(w, v.message);
    if (v.ref_des.len > 0) {
        try w.writeAll(",\"ref\":");
        try json_writer.writeString(w, v.ref_des);
    }
    if (v.net.len > 0) {
        try w.writeAll(net_key);
        try json_writer.writeString(w, v.net);
    }
    try w.writeAll("}");
}

fn writeFloatOrNull(w: anytype, v: ?f64) !void {
    if (v) |f| {
        try w.print("{d:.4}", .{f});
    } else {
        try w.writeAll("null");
    }
}
