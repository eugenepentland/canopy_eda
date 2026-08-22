//! Stuck-net diagnostics JSON — the single serialization every routing surface
//! shares (`/api/pcb-describe`'s `routed.stuck`, the MCP `describe_pcb_layout`
//! tool, and `POST /api/pcb-route` which feeds the viewer's Stuck-nets panel),
//! so a net's inferred failure mode, its blockers, and its ranked dsl/code
//! remedies can never drift in shape between the agent-facing facts and the
//! hardware engineer's sidebar.

const std = @import("std");
const route_diagnose = @import("../placement/route_diagnose.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");

/// Opening of a `{"net": …}` object — the one spelling shared by every
/// net-keyed object in the routed facts (diagnoses, blockers, loops, net-edge
/// maps), so the literal lives here rather than once per writer module.
pub const net_key = "{\"net\":";

/// Emit the `,"stuck":[…]` block — one object per failed net with its inferred
/// failure mode, the copper blocking it, and the ranked remedies (each tagged
/// dsl vs code so an agent knows whether to edit the plan or the router).
pub fn writeStuckJson(w: *std.Io.Writer, stuck: []const route_diagnose.Diagnosis) std.Io.Writer.Error!void {
    try w.writeAll(",\"stuck\":[");
    for (stuck, 0..) |d, i| {
        if (i > 0) try w.writeAll(",");
        try writeOneStuck(w, d);
    }
    try w.writeAll("]");
}

fn writeOneStuck(w: *std.Io.Writer, d: route_diagnose.Diagnosis) std.Io.Writer.Error!void {
    try w.writeAll(net_key);
    try pcb_layout_page.writeJsonStr(w, d.net);
    try writeDiagnosisBody(w, d);
    try w.writeAll("}");
}

/// One failed net as a STANDALONE object, tagged `"status":"failed"` after the
/// net key and then carrying the identical diagnosis fields the `stuck[]` array
/// entries do — the per-net route-analyze endpoint's failed-net answer, so its
/// shape can never drift from the Route button's `routed.stuck[]` entries.
pub fn writeFailedNet(w: *std.Io.Writer, d: route_diagnose.Diagnosis) std.Io.Writer.Error!void {
    try w.writeAll(net_key);
    try pcb_layout_page.writeJsonStr(w, d.net);
    try w.writeAll(",\"status\":\"failed\"");
    try writeDiagnosisBody(w, d);
    try w.writeAll("}");
}

/// Emit a diagnosis's fields — `,"failure_mode"…],"drc_related":[…]` — after a
/// net key and WITHOUT the enclosing object braces, so the `stuck[]` array
/// writer and the per-net analyze object share one blocker/remedy serialization.
fn writeDiagnosisBody(w: *std.Io.Writer, d: route_diagnose.Diagnosis) std.Io.Writer.Error!void {
    try w.writeAll(",\"failure_mode\":");
    try pcb_layout_page.writeJsonStr(w, d.failure_mode);
    try w.writeAll(",\"why\":");
    try pcb_layout_page.writeJsonStr(w, d.why);
    try w.writeAll(",\"blockers\":[");
    for (d.blockers, 0..) |b, i| {
        if (i > 0) try w.writeAll(",");
        try writeStuckBlocker(w, b);
    }
    try w.writeAll("],\"remedies\":[");
    for (d.remedies, 0..) |rm, i| {
        if (i > 0) try w.writeAll(",");
        try writeStuckRemedy(w, rm);
    }
    try w.writeAll("],\"drc_related\":[");
    for (d.drc_related, 0..) |id, i| {
        if (i > 0) try w.writeAll(",");
        try pcb_layout_page.writeJsonStr(w, id);
    }
    try w.writeAll("]");
    try writeCdtProbe(w, d.cdt_probe);
}

/// Emit `,"cdt_probe":{…}` — the CDT feasibility verdicts (isolation vs. the full
/// current copper) that sharpen the dsl↔code fork — or `,"cdt_probe":null` for a
/// net that was never probed. Additive: existing consumers ignore the field.
fn writeCdtProbe(w: *std.Io.Writer, probe: ?route_diagnose.CdtProbe) std.Io.Writer.Error!void {
    try w.writeAll(",\"cdt_probe\":");
    const p = probe orelse return w.writeAll("null");
    try w.writeAll("{\"isolation\":\"");
    try w.writeAll(@tagName(p.isolation));
    try w.writeAll("\",\"with_copper\":\"");
    try w.writeAll(@tagName(p.with_copper));
    try w.writeAll("\"}");
}

fn writeStuckBlocker(w: *std.Io.Writer, b: route_diagnose.Blocker) std.Io.Writer.Error!void {
    try w.writeAll(net_key);
    try pcb_layout_page.writeJsonStr(w, b.net);
    try w.writeAll(",\"layer\":");
    try pcb_layout_page.writeJsonStr(w, b.layer);
    try w.print(",\"x\":{d:.1},\"y\":{d:.1},\"share\":{d:.2},\"rippable\":{}", .{ b.x, b.y, b.share, b.rippable });
    try w.writeAll("}");
}

fn writeStuckRemedy(w: *std.Io.Writer, rm: route_diagnose.Remedy) std.Io.Writer.Error!void {
    try w.writeAll("{\"kind\":");
    try pcb_layout_page.writeJsonStr(w, rm.kind);
    try w.writeAll(",\"dsl\":");
    try pcb_layout_page.writeJsonStr(w, rm.dsl);
    try w.writeAll(",\"rationale\":");
    try pcb_layout_page.writeJsonStr(w, rm.rationale);
    try w.writeAll(",\"confidence\":");
    try pcb_layout_page.writeJsonStr(w, rm.confidence);
    try w.writeAll(",\"target\":");
    try pcb_layout_page.writeJsonStr(w, @tagName(rm.target));
    try w.writeAll("}");
}

// spec: Web Server - Stuck-net diagnostics serialize through one shared writer so the facts JSON and the viewer route response agree
test "the shared stuck writer emits net, failure mode, blockers, and dsl/code remedies" {
    const blockers = [_]route_diagnose.Blocker{
        .{ .net = "GND", .layer = "F.Cu", .x = 1.25, .y = -2.5, .share = 0.5, .rippable = false },
    };
    const remedies = [_]route_diagnose.Remedy{
        .{
            .kind = "raise_priority",
            .dsl = "(net-class \"sig\" (priority 4))",
            .rationale = "routes it before the copper now in its way",
            .confidence = "high",
            .target = .dsl,
        },
        .{
            .kind = "grid_refine",
            .dsl = "",
            .rationale = "corridor is open but narrower than the routing grid",
            .confidence = "med",
            .target = .code,
        },
    };
    const stuck = [_]route_diagnose.Diagnosis{.{
        .net = "SPI_SCK",
        .failure_mode = "order_congestion",
        .why = "the frontier is ringed by rippable copper",
        .blockers = &blockers,
        .remedies = &remedies,
        .drc_related = &.{},
    }};
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeStuckJson(&aw.writer, &stuck);
    const out = aw.written();
    try std.testing.expect(std.mem.startsWith(u8, out, ",\"stuck\":[{\"net\":\"SPI_SCK\""));
    try std.testing.expect(std.mem.indexOf(u8, out, "\"failure_mode\":\"order_congestion\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"net\":\"GND\",\"layer\":\"F.Cu\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"rippable\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"target\":\"dsl\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"target\":\"code\"") != null);
}

// spec: Web Server - the shared stuck writer serializes the CDT feasibility probe's isolation and with-copper verdicts, and null when a net was unprobed
test "the stuck writer serializes the CDT probe verdicts, and null when absent" {
    const probed = [_]route_diagnose.Diagnosis{.{
        .net = "EN_UV",
        .failure_mode = "order_congestion",
        .why = "corridor is open but foreign copper fills it",
        .blockers = &.{},
        .remedies = &.{},
        .drc_related = &.{},
        .cdt_probe = .{ .isolation = .routable, .with_copper = .blocked },
    }};
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeStuckJson(&aw.writer, &probed);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"cdt_probe\":{\"isolation\":\"routable\",\"with_copper\":\"blocked\"}") != null);

    const unprobed = [_]route_diagnose.Diagnosis{.{
        .net = "X",
        .failure_mode = "unknown",
        .why = "",
        .blockers = &.{},
        .remedies = &.{},
        .drc_related = &.{},
    }};
    var aw2: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw2.deinit();
    try writeStuckJson(&aw2.writer, &unprobed);
    try std.testing.expect(std.mem.indexOf(u8, aw2.written(), "\"cdt_probe\":null") != null);
}
