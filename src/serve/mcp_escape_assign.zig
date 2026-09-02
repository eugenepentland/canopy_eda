//! `preview_escape_assignment` CLI tool — read-only view of the joint escape
//! assignment for a contended net set.
//!
//! `(assign-escapes …)` on a route wave hands its nets to
//! `placement/escape_assign`, which finds their shared hub, cuts a corridor
//! cross-section at the tightest constriction they all still fit through, and
//! gives each net its own parallel lane. That happens INSIDE a route, so the
//! only way to see the lanes was to route the board (minutes) and infer them
//! from the copper. This tool answers the same question directly: for these
//! nets, on this board's blessed placement, which corridor, how many lanes,
//! and which net lands where — as data AND as hand-applicable DSL text, so an
//! agent can inspect an assignment, or apply one net's lane by hand, without
//! ever running the router.
//!
//! Read-only and request-local: it resolves the placement exactly as
//! `describe_pcb_layout` does, runs one pure assignment, and writes nothing.

const std = @import("std");
const escape_assign = @import("../placement/escape_assign.zig");
const optimizer = @import("../placement/optimizer.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const route_plan = @import("route_plan.zig");
const modules_mod = @import("modules.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;

/// `preview_escape_assignment` — assign `nets` to parallel escape lanes over
/// `name`'s blessed placement and return `{name, ok, reason, hub, direction,
/// layer, corridor, lanes[], assignments[], unassigned[], dsl}`. Writes nothing.
pub fn mcpPreviewEscapeAssignment(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) pcb_layout_page.HandlerError!bool {
    const name = argStr(args_val, "name") orelse return fail(out, alloc, "missing required arg: name");
    const wanted = pcb_layout_page.mcpArgStrList(alloc, args_val, "nets");
    if (wanted.len < 2) return fail(out, alloc, "nets must name at least two contended nets");

    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = pcb_layout_page.solveForRequest(alloc, project_dir, name, .{}, &eval, &module_res) catch |e|
        return failFmt(out, alloc, "could not resolve layout: {s}", .{@errorName(e)});

    const scope = route_plan.resolveScope(alloc, solved.block, solved.placement, .{ .nets = wanted }) catch |e|
        return failFmt(out, alloc, "could not resolve nets: {s}", .{@errorName(e)});
    var members: std.ArrayList(usize) = .empty;
    for (scope.mask, 0..) |on, i| {
        if (on) try members.append(alloc, i);
    }
    if (members.items.len < 2)
        return failFmt(out, alloc, "only {d} of the named nets exist on this board", .{members.items.len});

    const assigned = escape_assign.plan(alloc, solved.placement, .{
        .nets = members.items,
        .hub = argStr(args_val, "hub") orelse "",
        .layer = layerArg(solved.placement, args_val),
    }) catch |e| return failFmt(out, alloc, "assignment failed: {s}", .{@errorName(e)});

    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeResult(&aw.writer, .{
        .alloc = alloc,
        .name = name,
        .placement = solved.placement,
        .assigned = assigned,
        .unknown = scope.unknown,
    });
    try out.appendSlice(alloc, aw.written());
    return true;
}

/// Everything the JSON writer reads, grouped so the writer stays low-arity.
const Result = struct {
    alloc: std.mem.Allocator,
    name: []const u8,
    placement: optimizer.Placement,
    assigned: escape_assign.Plan,
    unknown: []const []const u8,
};

fn writeResult(w: *std.Io.Writer, r: Result) std.Io.Writer.Error!void {
    try w.writeAll("{\"name\":");
    try pcb_layout_page.writeJsonStr(w, r.name);
    try w.print(",\"ok\":{s},\"reason\":", .{if (r.assigned.ok) "true" else "false"});
    try pcb_layout_page.writeJsonStr(w, r.assigned.reason);
    try w.writeAll(",\"hub\":");
    try pcb_layout_page.writeJsonStr(w, r.assigned.hub);
    try w.writeAll(",\"direction\":");
    try pcb_layout_page.writeJsonStr(w, @tagName(r.assigned.corridor.dir));
    var layer_buf: [16]u8 = undefined;
    try w.writeAll(",\"layer\":");
    try pcb_layout_page.writeJsonStr(w, r.placement.rules.signalLayerName(r.assigned.layer, &layer_buf));
    const c = r.assigned.corridor;
    try w.print(",\"corridor\":{{\"cut\":{d:.3},\"lo\":{d:.3},\"hi\":{d:.3},\"pitch\":{d:.4}}}", .{
        c.cut, c.lo, c.hi, c.pitch,
    });
    try w.print(",\"displacement_cap_mm\":{d:.3}", .{c.cap});
    try w.print(",\"lane_count\":{d},\"lanes\":[", .{r.assigned.schedule.lanes.len});
    for (r.assigned.schedule.lanes, 0..) |lane, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"pos\":{d:.3},\"x\":{d:.3},\"y\":{d:.3},\"band\":{d}}}", .{
            lane.pos, lane.x, lane.y, lane.band,
        });
    }
    try w.writeAll("],\"assignments\":[");
    for (r.assigned.schedule.assignments, 0..) |a, i| {
        if (i > 0) try w.writeAll(",");
        try writeAssignment(w, r, a);
    }
    // The nets the assignment DECLINED, repeated out of `assignments` so a
    // caller sees the refusals without filtering — each with the reason and how
    // far off its own ideal crossing the corridor would have put it. A refused
    // net keeps no guide and routes exactly as it does with no form authored.
    try w.writeAll("],\"unassigned\":[");
    for (r.assigned.schedule.unassigned, 0..) |a, i| {
        if (i > 0) try w.writeAll(",");
        try writeAssignment(w, r, a);
    }
    try w.writeAll("],\"unknown_nets\":[");
    for (r.unknown, 0..) |u, i| {
        if (i > 0) try w.writeAll(",");
        try pcb_layout_page.writeJsonStr(w, u);
    }
    try w.writeAll("],\"dsl\":");
    try writeDsl(w, r);
    try w.writeAll("}");
}

fn writeAssignment(w: *std.Io.Writer, r: Result, a: escape_assign.Assignment) std.Io.Writer.Error!void {
    try w.writeAll("{\"net\":");
    try pcb_layout_page.writeJsonStr(w, netName(r.placement, a.net));
    try w.writeAll(",\"ref\":");
    try pcb_layout_page.writeJsonStr(w, a.from.ref);
    try w.writeAll(",\"pad\":");
    try pcb_layout_page.writeJsonStr(w, a.from.pad);
    try w.print(",\"ideal\":{d:.3},\"offset\":{d:.3}", .{ a.fit.ideal, a.fit.offset });
    if (a.lane) |k| {
        try w.print(",\"lane\":{d},\"x\":{d:.3},\"y\":{d:.3}", .{ k, a.dst[0], a.dst[1] });
    } else {
        try w.writeAll(",\"lane\":null,\"refused\":");
        try pcb_layout_page.writeJsonStr(w, @tagName(a.fit.refusal));
    }
    try w.writeAll("}");
}

/// The assignment as a pasteable `(pcb-plan (route …))` fragment: one
/// single-net wave per assigned net carrying that net's own lane point as an
/// ordered waypoint. This is the HAND-APPLICABLE spelling — `(assign-escapes)`
/// on one wave says the same thing in one line and keeps following the parts
/// when they move, but a per-net waypoint can be edited, reordered, or applied
/// to one net at a time.
fn writeDsl(w: *std.Io.Writer, r: Result) std.Io.Writer.Error!void {
    var layer_buf: [16]u8 = undefined;
    var buf: std.Io.Writer.Allocating = .init(r.alloc);
    const b = &buf.writer;
    const layer = r.placement.rules.signalLayerName(r.assigned.layer, &layer_buf);
    b.writeAll("(pcb-plan\n  (route\n") catch return;
    for (r.assigned.schedule.assignments) |a| {
        if (a.lane == null) continue;
        b.print(
            "    (wave \"escape-{s}\" (nets \"{s}\")\n      (waypoints (at {d:.3} {d:.3} \"{s}\"))\n" ++
                "      (reason \"lane {d} of the {s} escape from {s}.{s}\"))\n",
            .{
                netName(r.placement, a.net), netName(r.placement, a.net),
                a.dst[0],                    a.dst[1],
                layer,                       a.lane.?,
                r.assigned.hub,              a.from.ref,
                a.from.pad,
            },
        ) catch return;
    }
    b.writeAll("  ))") catch return;
    try pcb_layout_page.writeJsonStr(w, buf.written());
}

fn netName(placement: optimizer.Placement, net_i: usize) []const u8 {
    return if (net_i < placement.nets.len) placement.nets[net_i].name else "";
}

/// The caller's `layer` name resolved to a signal-layer index, or null to let
/// the assigner pick the hub's own side.
fn layerArg(placement: optimizer.Placement, args_val: ?std.json.Value) ?u8 {
    const name = argStr(args_val, "layer") orelse return null;
    return placement.rules.signalIndexOfName(name);
}

/// `args.key` as a string (absent / non-object / non-string ⇒ null).
fn argStr(args_val: ?std.json.Value, key: []const u8) ?[]const u8 {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn fail(out: *std.ArrayList(u8), alloc: std.mem.Allocator, msg: []const u8) pcb_layout_page.HandlerError!bool {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.writeAll("{\"error\":");
    try pcb_layout_page.writeJsonStr(w, msg);
    try w.writeAll("}");
    try out.appendSlice(alloc, aw.written());
    return false;
}

fn failFmt(out: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) pcb_layout_page.HandlerError!bool {
    const msg = std.fmt.allocPrint(alloc, fmt, args) catch "error";
    return fail(out, alloc, msg);
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const mcp_tools = @import("mcp_tools.zig");

// spec: Web Server - preview_escape_assignment is a registered read-only CLI tool
test "preview_escape_assignment is registered read-only" {
    try testing.expect(mcp_tools.isKnownTool("preview_escape_assignment"));
    try testing.expect(!mcp_tools.isMutationTool("preview_escape_assignment"));
}

// spec: Web Server - preview_escape_assignment rejects a request naming fewer than two nets
test "preview_escape_assignment needs at least two contended nets" {
    // Request-local arena, exactly as the CLI dispatcher hands the handler.
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    var out: std.ArrayList(u8) = .empty;
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "name", .{ .string = "whatever" });
    try obj.put(arena, "nets", .{ .string = "ONLY_ONE" });
    const ok = try mcpPreviewEscapeAssignment(arena, "", .{ .object = obj }, &out);
    try testing.expect(!ok);
    try testing.expect(std.mem.indexOf(u8, out.items, "at least two") != null);
}

// spec: Web Server - preview_escape_assignment renders its assignment as a pasteable per-net waypoint plan
test "preview_escape_assignment renders assigned lanes as DSL waypoints" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    const geometry = @import("../placement/geometry.zig");
    const export_kicad = @import("../export_kicad.zig");
    const hub_pads = [_]geometry.Pad{
        .{ .number = "1", .x = -0.5, .y = -1, .w = 0.4, .h = 0.4 },
        .{ .number = "2", .x = -0.5, .y = 1, .w = 0.4, .h = 0.4 },
    };
    const leg = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "J1", .kind = .hub, .hw = 1, .hh = 3, .pads = &hub_pads, .fallback = false, .x = 10, .y = 0 },
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &leg, .fallback = false, .x = 0, .y = -1 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &leg, .fallback = false, .x = 0, .y = 1 },
    };
    const pins_a = [_]export_kicad.FlatPin{ .{ .ref_des = "J1", .pin = "1" }, .{ .ref_des = "R1", .pin = "1" } };
    const pins_b = [_]export_kicad.FlatPin{ .{ .ref_des = "J1", .pin = "2" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]optimizer.FlatNet{
        .{ .name = "SPI_A", .pins = &pins_a },
        .{ .name = "SPI_B", .pins = &pins_b },
    };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -5,
        .maxx = 11,
        .maxy = 5,
        .generated = true,
    };
    const both = [_]usize{ 0, 1 };
    const assigned = try escape_assign.plan(arena, placement, .{ .nets = &both });
    try testing.expect(assigned.ok);

    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeResult(&aw.writer, .{
        .alloc = arena,
        .name = "fixture",
        .placement = placement,
        .assigned = assigned,
        .unknown = &.{},
    });
    const json = aw.written();
    try testing.expect(std.mem.indexOf(u8, json, "\"hub\":\"J1\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"direction\":\"west\"") != null);
    // The DSL block is JSON-escaped, so the wave heads read with \" quoting.
    try testing.expect(std.mem.indexOf(u8, json, "escape-SPI_A") != null);
    try testing.expect(std.mem.indexOf(u8, json, "escape-SPI_B") != null);
    try testing.expect(std.mem.indexOf(u8, json, "(waypoints (at ") != null);
}

// spec: Web Server - preview_escape_assignment reports the nets its assignment refused and why
test "preview_escape_assignment reports its refusals" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    // A hand-built plan standing in for one whose corridor could not take every
    // net: SPI_B's ideal crossing lies past the displacement cap of any band.
    const assignments = [_]escape_assign.Assignment{
        .{ .net = 0, .lane = 0, .dst = .{ 1, 2 }, .fit = .{ .ideal = 2, .offset = 0.1 } },
        .{ .net = 1, .fit = .{ .ideal = 9, .offset = 3.75, .refusal = .out_of_band } },
    };
    const refused = [_]escape_assign.Assignment{assignments[1]};
    const nets = [_]optimizer.FlatNet{
        .{ .name = "SPI_A", .pins = &.{} },
        .{ .name = "SPI_B", .pins = &.{} },
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
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeResult(&aw.writer, .{
        .alloc = arena,
        .name = "fixture",
        .placement = placement,
        .assigned = .{
            .ok = true,
            .corridor = .{ .cap = 1.458 },
            .schedule = .{ .assignments = &assignments, .unassigned = &refused },
        },
        .unknown = &.{},
    });
    const json = aw.written();
    try testing.expect(std.mem.indexOf(u8, json, "\"displacement_cap_mm\":1.458") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"unassigned\":[{\"net\":\"SPI_B\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"refused\":\"out_of_band\"") != null);
    // …and the refused net contributes no pasteable waypoint wave.
    try testing.expect(std.mem.indexOf(u8, json, "escape-SPI_B") == null);
}
