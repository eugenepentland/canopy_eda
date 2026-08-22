//! `routability_preflight` MCP tool — the full structured output of the static
//! routability gates in `placement/routability_lint.zig`.
//!
//! `describe_pcb_layout` already mirrors these findings into its `lint[]`
//! array, but there they are prose with the numbers embedded, alongside a
//! megabyte of unrelated facts. An agent deciding *which* edit to make wants
//! the measurements themselves — the lane it has, the lane the net class
//! demands, and the two pads involved — so this tool returns them as fields.
//!
//! It never routes. The whole answer comes from the placement plus the
//! resolved `(net-class …)`/`(design-rules …)` geometry, which is why it is
//! worth asking BEFORE a solve: the findings name obstructions no re-ordering,
//! priority bump or effort tier can dissolve.

const std = @import("std");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const modules_mod = @import("modules.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const pcb_describe = @import("pcb_describe.zig");
const routability_lint = @import("../placement/routability_lint.zig");
const port_escape = @import("../placement/port_escape.zig");
const plan_resolve = @import("../placement/plan_resolve.zig");
const mcp_read_opts = @import("mcp_read_opts.zig");

/// Errors the handler can surface: allocation plus the JSON writer's.
pub const PreflightError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// `routability_preflight` — resolve `name`'s layout the way every other PCB
/// read tool does, run the static gates, and write the findings JSON. Returns
/// false (with a plain-text reason in `out`) when the design/layout will not
/// resolve, matching the other tools' failure convention.
pub fn mcpRoutabilityPreflight(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) PreflightError!bool {
    const name = argStr(args_val, "name") orelse {
        try out.appendSlice(alloc, "missing required arg: name");
        return false;
    };
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    // Placement-selection args only (`layout`/`sub`/`regen`/`rough`) — this tool
    // runs no router and reports `routed:false`, so a `route` flag could not
    // change its answer and its schema refuses one.
    const opts = mcp_read_opts.placementSelectOpts(args_val);
    const solved = pcb_layout_page.solveForRequest(alloc, project_dir, name, opts, &eval, &module_res) catch |e| {
        const msg = try std.fmt.allocPrint(alloc, "error resolving layout: {s}", .{@errorName(e)});
        defer alloc.free(msg);
        try out.appendSlice(alloc, msg);
        return false;
    };
    // A fan an authored `(assign-escapes …)` wave already owns is not re-flagged
    // as contended — the author decided about that escape, and the plan's own
    // `plan-escape-unassigned` warning covers whatever it could not seat.
    const assigned = try plan_resolve.escapeAssignedFor(alloc, solved.block, solved.placement);
    // The block's own `(port …)` nets: a `Placement` carries no port
    // declarations, so without this mask the port-escape gate cannot fire and
    // this tool would disagree with `describe_pcb_layout`'s `lint[]`.
    const ports = try port_escape.portNets(alloc, solved.block, solved.placement.nets);
    const findings = try routability_lint.preflight(alloc, solved.placement, .{
        .escapes_assigned = assigned,
        .port_nets = ports,
    });
    defer routability_lint.freeFindings(alloc, findings);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try writeJson(&aw.writer, name, findings);
    try out.appendSlice(alloc, aw.written());
    return true;
}

/// `{"name":…,"findings":[…],"counts":{…}}` — every finding with its
/// measurements, plus a per-rule tally so a caller can see at a glance whether
/// the board has one situation or fifty.
fn writeJson(
    w: *std.Io.Writer,
    name: []const u8,
    findings: []const routability_lint.Finding,
) std.Io.Writer.Error!void {
    try w.writeAll("{\"name\":");
    try pcb_layout_page.writeJsonStr(w, name);
    try w.print(",\"routed\":false,\"findings\":[", .{});
    for (findings, 0..) |f, i| {
        if (i > 0) try w.writeAll(",");
        try writeFinding(w, f);
    }
    try w.print(
        "],\"counts\":{{\"total\":{d},\"corridor\":{d},\"via_in_pad\":{d},\"sealed\":{d}" ++
            ",\"escape\":{d},\"port_blocked\":{d}}}}}",
        .{
            findings.len,
            countRule(findings, "pad-corridor-tight"),
            countRule(findings, "via-in-pad-conflict"),
            countRule(findings, "pad-sealed"),
            countRule(findings, "escape-contended"),
            countRule(findings, "port-blocked"),
        },
    );
}

fn writeFinding(w: *std.Io.Writer, f: routability_lint.Finding) std.Io.Writer.Error!void {
    try w.writeAll("{\"rule\":");
    try pcb_layout_page.writeJsonStr(w, f.rule);
    try w.print(",\"severity\":\"{s}\",\"refs\":[", .{@tagName(f.severity)});
    for (f.refs, 0..) |r, i| {
        if (i > 0) try w.writeAll(",");
        try pcb_layout_page.writeJsonStr(w, r);
    }
    try w.writeAll("],\"msg\":");
    try pcb_layout_page.writeJsonStr(w, f.msg);
    try w.writeAll(",\"a\":");
    try writeParty(w, f.detail.a);
    if (f.detail.b) |b| {
        try w.writeAll(",\"b\":");
        try writeParty(w, b);
    }
    try w.print(
        ",\"have_mm\":{d:.4},\"need_mm\":{d:.4},\"width_mm\":{d:.4},\"clearance_mm\":{d:.4},\"exits_blocked\":{d}",
        .{ f.detail.have_mm, f.detail.need_mm, f.detail.width_mm, f.detail.clearance_mm, f.detail.exits_blocked },
    );
    if (f.escape) |e| try writeEscape(w, e);
    if (f.suggestion.len > 0) {
        try w.writeAll(",\"suggestion\":");
        try pcb_layout_page.writeJsonStr(w, f.suggestion);
    }
    try w.writeAll("}");
}

/// The `escape-contended` counts and cross-section as their own block, so an
/// agent reads "8 nets, 10 lanes, 2 bands, 6 seated" as numbers rather than
/// parsing them back out of the prose.
fn writeEscape(w: *std.Io.Writer, e: routability_lint.Escape) std.Io.Writer.Error!void {
    try w.writeAll(",\"escape\":{\"side\":");
    try pcb_layout_page.writeJsonStr(w, e.side);
    try w.print(
        ",\"nets\":{d},\"lanes\":{d},\"seated\":{d},\"refused\":{d},\"bands\":{d}," ++
            "\"cut_mm\":{d:.3},\"span_mm\":{d:.3},\"pitch_mm\":{d:.4}}}",
        .{ e.nets, e.lanes, e.seated, e.nets - e.seated, e.bands, e.cut.at_mm, e.cut.span_mm, e.cut.pitch_mm },
    );
}

fn writeParty(w: *std.Io.Writer, p: routability_lint.Party) std.Io.Writer.Error!void {
    try w.writeAll("{\"ref\":");
    try pcb_layout_page.writeJsonStr(w, p.ref);
    try w.writeAll(",\"pad\":");
    try pcb_layout_page.writeJsonStr(w, p.pad);
    try w.writeAll(",\"net\":");
    try pcb_layout_page.writeJsonStr(w, p.net);
    try w.writeAll("}");
}

fn countRule(findings: []const routability_lint.Finding, rule: []const u8) usize {
    var n: usize = 0;
    for (findings) |f| {
        if (std.mem.eql(u8, f.rule, rule)) n += 1;
    }
    return n;
}

fn argStr(args_val: ?std.json.Value, key: []const u8) ?[]const u8 {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Web Server - the routability_preflight tool emits each finding's measurements and a per-rule tally
test "routability_preflight JSON carries the measurements and the per-rule counts" {
    const refs = [_][]const u8{"adf4159/C116"};
    const findings = [_]routability_lint.Finding{.{
        .rule = "pad-corridor-tight",
        .severity = .warn,
        .refs = &refs,
        .msg = "pads face each other across 0.180 mm",
        .detail = .{
            .a = .{ .ref = "adf4159/C116", .pad = "1", .net = "V_1V8A" },
            .b = .{ .ref = "adf4159/C116", .pad = "2", .net = "GND" },
            .have_mm = 0.18,
            .need_mm = 0.2536,
            .width_mm = 0.2532,
            .clearance_mm = 0.127,
        },
    }};
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeJson(&aw.writer, "barracuda", &findings);
    const out = aw.written();
    // The measurements must survive as FIELDS, not only inside the prose.
    try testing.expect(std.mem.indexOf(u8, out, "\"have_mm\":0.1800") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"need_mm\":0.2536") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"pad\":\"2\"") != null);
    // And the tally splits by rule so a caller sees the shape of the report.
    try testing.expect(std.mem.indexOf(u8, out, "\"total\":1,\"corridor\":1,\"via_in_pad\":0,\"sealed\":0") != null);
}

// spec: Web Server - routability_preflight carries an escape-contention finding's counts, cut and paste-ready suggestion
test "routability_preflight JSON carries the escape-contention block and its suggestion" {
    const refs = [_][]const u8{"J1"};
    const findings = [_]routability_lint.Finding{.{
        .rule = "escape-contended",
        .severity = .warn,
        .refs = &refs,
        .msg = "8 nets must leave J1 on its west side",
        .detail = .{ .a = .{ .ref = "J1" } },
        .escape = .{
            .side = "west",
            .nets = 8,
            .lanes = 10,
            .seated = 6,
            .bands = 2,
            .cut = .{ .at_mm = 176.6, .span_mm = 12.5, .pitch_mm = 0.2532 },
        },
        .suggestion = "(pcb-plan (route (wave \"escape-J1-west\" (nets \"A\") (assign-escapes \"F.Cu\" \"J1\"))))",
    }};
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeJson(&aw.writer, "barracuda", &findings);
    const out = aw.written();
    // The counts must survive as FIELDS: a lane shortfall is what the reader acts on.
    try testing.expect(std.mem.indexOf(u8, out, "\"escape\":{\"side\":\"west\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"nets\":8,\"lanes\":10,\"seated\":6,\"refused\":2,\"bands\":2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"cut_mm\":176.600") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"suggestion\":\"(pcb-plan (route") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"escape\":1") != null);
}

// spec: Web Server - the escape-contention suggestion parses back as an (assign-escapes …) route wave for the same nets
test "the escape-contention suggestion round-trips through the pcb-plan parser" {
    const escape_assign = @import("../placement/escape_assign.zig");
    const optimizer = @import("../placement/optimizer.zig");
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const nets = [_]optimizer.FlatNet{
        .{ .name = "SPI_SCK", .pins = &.{} },
        .{ .name = "SPI_MOSI", .pins = &.{} },
        .{ .name = "SPI_MISO", .pins = &.{} },
    };
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 1,
        .maxy = 1,
        .generated = true,
    };
    const fan = [_]usize{ 0, 1, 2 };
    const dsl = try escape_assign.suggestDsl(arena, placement, .{
        .hub = "J1",
        .nets = &fan,
        .seated = 1,
        .lanes = 2,
        .bands = 2,
        .corridor = .{ .dir = .west, .cut = 6.2, .pitch = 0.25 },
    });

    // The whole point of emitting DSL: the evaluator has to accept it verbatim.
    var eval = Evaluator.init(arena, "");
    defer eval.deinit();
    const src = try std.fmt.allocPrint(arena, "(design-block \"t\" {s})", .{dsl});
    const value = try eval.evalSource(src);
    const plan = value.design_block.pcb_plan orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(usize, 1), plan.route.len);
    const spec = plan.route[0].corridor.assign_escapes orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings("J1", spec.hub);
    try testing.expectEqualStrings("F.Cu", spec.layer);
    try testing.expectEqual(@as(usize, 3), plan.route[0].nets.len);
    try testing.expectEqualStrings("SPI_SCK", plan.route[0].nets[0]);
}
