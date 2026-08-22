//! `optimize_connector_pinout` CLI tool.
//!
//! Connector pad assignments are remapped only in a request-local copy of the
//! flattened netlist. The geometric search is the default; `route_trials > 0`
//! optionally sends only that many leading candidates through a bounded,
//! plan-neutral one-shot route. No source or sidecar is ever written.

const std = @import("std");
const connector_pinout = @import("../placement/connector_pinout.zig");
const optimizer = @import("../placement/optimizer.zig");
const flat_netlist = @import("../flat_netlist.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const modules_mod = @import("modules.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const route_plan = @import("route_plan.zig");
const route_policy = @import("../placement/route_policy.zig");
const route_score = @import("../placement/route_score.zig");
const drc = @import("../placement/drc.zig");
const drc_rules = @import("drc_rules.zig");
const net_name = @import("../net_name.zig");

const max_route_trials = 4;
const max_route_seconds = 60;

const Context = struct {
    problem: connector_pinout.Problem,
    placement_net: []const usize,
    connector_ref: []const u8,
};

/// Run a constrained, read-only connector assignment search.
pub fn mcpOptimizeConnectorPinout(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) pcb_layout_page.HandlerError!bool {
    const name = argStr(args_val, "name") orelse return fail(out, alloc, "missing required arg: name");
    const ref = argStr(args_val, "ref") orelse return fail(out, alloc, "missing required arg: ref");

    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |resolved| {
        resolved.eval.deinit();
        alloc.destroy(resolved.eval);
    };
    const layout_arg = argStr(args_val, "layout");
    const solved = pcb_layout_page.solveForRequest(alloc, project_dir, name, .{
        .layout = layout_arg,
        .sub = argStr(args_val, "sub"),
    }, &eval, &module_res) catch |err|
        return failFmt(out, alloc, "could not resolve layout: {s}", .{@errorName(err)});

    const context = buildContext(alloc, solved.placement, ref, args_val) catch |err|
        return failFmt(out, alloc, "invalid pinout problem: {s}", .{@errorName(err)});
    const result = connector_pinout.search(alloc, context.problem) catch |err|
        return failFmt(out, alloc, "pinout search failed: {s}", .{@errorName(err)});

    const requested_trials = argUsize(args_val, "route_trials") orelse 0;
    const route_trials = @min(requested_trials, max_route_trials);
    const seconds = @min(argUsize(args_val, "route_seconds") orelse 15, max_route_seconds);
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeResult(&aw.writer, .{
        .alloc = alloc,
        .project_dir = project_dir,
        .name = name,
        .layout = layout_arg,
        .solved = solved,
        .context = context,
        .result = result,
        .route_trials = route_trials,
        .route_seconds = seconds,
    });
    try out.appendSlice(alloc, aw.written());
    return true;
}

const WriteArgs = struct {
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    layout: ?[]const u8,
    solved: pcb_layout_page.SolvedRequest,
    context: Context,
    result: connector_pinout.Result,
    route_trials: usize,
    route_seconds: usize,
};

fn writeResult(w: *std.Io.Writer, args: WriteArgs) !void {
    try w.writeAll("{\"name\":");
    try pcb_layout_page.writeJsonStr(w, args.name);
    try w.writeAll(",\"layout\":");
    if (args.layout) |layout| try pcb_layout_page.writeJsonStr(w, layout) else try w.writeAll("null");
    try w.writeAll(",\"ref\":");
    try pcb_layout_page.writeJsonStr(w, args.context.connector_ref);
    try w.writeAll(",\"method\":\"constrained_multistart\"");
    try w.writeAll(",\"optimality\":\"best_found_not_proven\"");
    try w.print(",\"evaluated\":{d},\"feasible\":{d},\"baseline_geometric_cost\":{d:.3},\"route_trials\":{d}", .{
        args.result.evaluated,
        args.result.feasible,
        args.result.baseline_cost,
        args.route_trials,
    });
    try w.writeAll(",\"candidates\":[");
    for (args.result.candidates, 0..) |candidate, rank| {
        if (rank > 0) try w.writeAll(",");
        try writeCandidate(w, args, candidate, rank);
    }
    try w.writeAll("]}");
}

fn writeCandidate(
    w: *std.Io.Writer,
    args: WriteArgs,
    candidate: connector_pinout.Candidate,
    rank: usize,
) !void {
    try w.print(
        "{{\"rank\":{d},\"geometric_cost\":{d:.3},\"delta_geometric_cost\":{d:.3},\"pinout\":{{",
        .{ rank + 1, candidate.cost, candidate.cost - args.result.baseline_cost },
    );
    for (args.context.problem.pins, candidate.assignment, 0..) |pin, net, i| {
        if (i > 0) try w.writeAll(",");
        try pcb_layout_page.writeJsonStr(w, pin.name);
        try w.writeAll(":");
        try pcb_layout_page.writeJsonStr(w, args.context.problem.nets[net].name);
    }
    try w.writeAll("},\"changes\":[");
    var change_n: usize = 0;
    for (candidate.assignment, 0..) |net, pin_i| {
        const old = args.context.problem.current[pin_i];
        if (old == net) continue;
        if (change_n > 0) try w.writeAll(",");
        change_n += 1;
        try w.writeAll("{\"pin\":");
        try pcb_layout_page.writeJsonStr(w, args.context.problem.pins[pin_i].name);
        try w.writeAll(",\"from\":");
        try pcb_layout_page.writeJsonStr(w, args.context.problem.nets[old].name);
        try w.writeAll(",\"to\":");
        try pcb_layout_page.writeJsonStr(w, args.context.problem.nets[net].name);
        try w.writeAll("}");
    }
    try w.writeAll("]");
    if (rank < args.route_trials) try writeRouteTrial(w, args, candidate);
    try w.writeAll("}");
}

fn writeRouteTrial(w: *std.Io.Writer, args: WriteArgs, candidate: connector_pinout.Candidate) !void {
    const virtual = try virtualPlacement(args.alloc, args.solved.placement, args.context, candidate.assignment);
    var options = route_policy.Options{
        .effort = .one_shot,
        .existing_zones = args.solved.shown_zones.sources,
    };
    options.stop.max_route_ms = args.route_seconds * std.time.ms_per_s;
    const params = virtual.rules.design.routeParams();
    const routed = try route_plan.routeLoweredDiagnostic(args.alloc, virtual, params, options);
    const violations = drc_rules.checkFiltered(
        args.alloc,
        args.project_dir,
        args.name,
        virtual,
        routed.result,
        params.clearance,
    );
    var trace_mm: f64 = 0;
    for (routed.result.tracks) |track| {
        trace_mm += std.math.hypot(track.x2 - track.x1, track.y2 - track.y1);
    }
    const drc_errors = drc.errorCount(violations);
    const score = route_score.score(.{
        .routed = routed.result.routed,
        .total = routed.result.total,
        .vias = routed.result.vias.len,
        .trace_mm = trace_mm,
        .drc_errors = drc_errors,
    });
    try w.print(",\"route\":{{\"mode\":\"plan_neutral_one_shot\",\"seconds\":{d}", .{args.route_seconds});
    try w.print(",\"routed\":{d},\"total\":{d},\"vias\":{d}", .{
        routed.result.routed,
        routed.result.total,
        routed.result.vias.len,
    });
    try w.print(",\"trace_mm\":{d:.3},\"drc_errors\":{d},\"score\":{d:.2}}}", .{
        trace_mm,
        drc_errors,
        score,
    });
}

fn virtualPlacement(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    context: Context,
    assignment: []const usize,
) !optimizer.Placement {
    const nets = try alloc.dupe(flat_netlist.FlatNet, placement.nets);
    for (context.placement_net, 0..) |placement_net, dense_net| {
        var count: usize = 0;
        for (placement.nets[placement_net].pins) |pin| {
            if (!std.mem.eql(u8, pin.ref_des, context.connector_ref)) count += 1;
        }
        for (assignment) |assigned| if (assigned == dense_net) {
            count += 1;
        };
        const pins = try alloc.alloc(flat_netlist.FlatPin, count);
        var out_i: usize = 0;
        for (placement.nets[placement_net].pins) |pin| {
            if (std.mem.eql(u8, pin.ref_des, context.connector_ref)) continue;
            pins[out_i] = pin;
            out_i += 1;
        }
        for (assignment, 0..) |assigned, connector_pin| {
            if (assigned != dense_net) continue;
            pins[out_i] = .{
                .ref_des = context.connector_ref,
                .pin = context.problem.pins[connector_pin].name,
            };
            out_i += 1;
        }
        nets[placement_net].pins = pins;
    }
    var virtual = placement;
    virtual.nets = nets;
    return virtual;
}

fn buildContext(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    ref: []const u8,
    args_val: ?std.json.Value,
) !Context {
    const part_i = findPart(placement, ref) orelse return error.UnknownConnector;
    const part = placement.parts[part_i];
    var pins: std.ArrayList(connector_pinout.Pin) = .empty;
    var current: std.ArrayList(usize) = .empty;
    var placement_nets: std.ArrayList(usize) = .empty;
    var dense_by_net = try alloc.alloc(?usize, placement.nets.len);
    @memset(dense_by_net, null);

    for (placement.nets, 0..) |net, placement_net| {
        for (net.pins) |pin| {
            if (!std.mem.eql(u8, pin.ref_des, ref)) continue;
            if (pinIndexByName(pins.items, pin.pin) != null) return error.DuplicateConnectorPin;
            const pad = findPad(part, pin.pin) orelse return error.UnknownConnectorPad;
            const world = optimizer.worldPadCenter(&part, pad.x, pad.y);
            try pins.append(alloc, .{ .name = pin.pin, .at = .{ .x = world[0], .y = world[1] } });
            const dense = if (dense_by_net[placement_net]) |known| known else blk: {
                const next = placement_nets.items.len;
                try placement_nets.append(alloc, placement_net);
                dense_by_net[placement_net] = next;
                break :blk next;
            };
            try current.append(alloc, dense);
        }
    }
    if (pins.items.len < 2) return error.ConnectorNeedsTwoAssignedPins;
    sortConnectorPins(pins.items, current.items);
    const dense_nets = try buildNets(alloc, placement, ref, placement_nets.items, args_val);
    const fixed = try parseFixed(alloc, args_val, pins.items, dense_nets);
    const allowed = try parseAllowed(alloc, args_val, pins.items, dense_nets);
    const groups = try parseGroups(alloc, args_val, dense_nets);
    const movable = try parseMovable(alloc, args_val, pins.items);
    return .{
        .problem = .{
            .pins = try pins.toOwnedSlice(alloc),
            .nets = dense_nets,
            .current = try current.toOwnedSlice(alloc),
            .constraints = .{
                .fixed = fixed,
                .allowed = allowed,
                .groups = groups,
                .movable = movable,
            },
            .options = .{
                .samples = argUsize(args_val, "samples") orelse 2000,
                .top_k = argUsize(args_val, "top_k") orelse 10,
                .seed = argU64(args_val, "seed") orelse 1,
            },
        },
        .placement_net = try placement_nets.toOwnedSlice(alloc),
        .connector_ref = ref,
    };
}

fn buildNets(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    ref: []const u8,
    placement_nets: []const usize,
    args_val: ?std.json.Value,
) ![]const connector_pinout.Net {
    const out = try alloc.alloc(connector_pinout.Net, placement_nets.len);
    const ignored = argStringList(alloc, args_val, "ignore_nets");
    for (placement_nets, 0..) |placement_net, dense| {
        const net = placement.nets[placement_net];
        var remote: std.ArrayList(connector_pinout.Point) = .empty;
        for (net.pins) |pin| {
            if (std.mem.eql(u8, pin.ref_des, ref)) continue;
            if (worldPin(placement, pin)) |point| try remote.append(alloc, point);
        }
        out[dense] = .{
            .name = net.name,
            .remote = try remote.toOwnedSlice(alloc),
            .ignore_cost = isIgnored(net.name, ignored),
        };
    }
    return out;
}

fn parseFixed(
    alloc: std.mem.Allocator,
    args_val: ?std.json.Value,
    pins: []const connector_pinout.Pin,
    nets: []const connector_pinout.Net,
) ![]const connector_pinout.Fixed {
    const value = argValue(args_val, "fixed") orelse return &.{};
    if (value != .object) return error.FixedMustBeObject;
    var out: std.ArrayList(connector_pinout.Fixed) = .empty;
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string) return error.FixedNetMustBeString;
        try out.append(alloc, .{
            .pin = pinIndexByName(pins, entry.key_ptr.*) orelse return error.UnknownFixedPin,
            .net = netIndexByName(nets, entry.value_ptr.string) orelse return error.UnknownFixedNet,
        });
    }
    return out.toOwnedSlice(alloc);
}

fn parseAllowed(
    alloc: std.mem.Allocator,
    args_val: ?std.json.Value,
    pins: []const connector_pinout.Pin,
    nets: []const connector_pinout.Net,
) ![]const connector_pinout.Allowed {
    const value = argValue(args_val, "allowed_pins") orelse return &.{};
    if (value != .object) return error.AllowedMustBeObject;
    var out: std.ArrayList(connector_pinout.Allowed) = .empty;
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        const net = netIndexByName(nets, entry.key_ptr.*) orelse return error.UnknownAllowedNet;
        const names = try valueStringList(alloc, entry.value_ptr.*);
        const allowed_pins = try alloc.alloc(usize, names.len);
        for (names, 0..) |pin_name, i| {
            allowed_pins[i] = pinIndexByName(pins, pin_name) orelse return error.UnknownAllowedPin;
        }
        try out.append(alloc, .{ .net = net, .pins = allowed_pins });
    }
    return out.toOwnedSlice(alloc);
}

fn parseGroups(
    alloc: std.mem.Allocator,
    args_val: ?std.json.Value,
    nets: []const connector_pinout.Net,
) ![]const connector_pinout.Group {
    const value = argValue(args_val, "groups") orelse return &.{};
    if (value != .array) return error.GroupsMustBeArray;
    const out = try alloc.alloc(connector_pinout.Group, value.array.items.len);
    for (value.array.items, 0..) |item, i| {
        if (item != .object) return error.GroupMustBeObject;
        const names_value = item.object.get("nets") orelse return error.GroupNeedsNets;
        const names = try valueStringList(alloc, names_value);
        const group_nets = try alloc.alloc(usize, names.len);
        for (names, 0..) |group_name, n| {
            group_nets[n] = netIndexByName(nets, group_name) orelse return error.UnknownGroupNet;
        }
        const guard_name = objectStr(item.object, "guard_net");
        out[i] = .{
            .nets = group_nets,
            .max_spacing_mm = objectNumber(item.object, "max_spacing_mm") orelse 0,
            .ordered = objectBool(item.object, "ordered") orelse false,
            .guard_net = if (guard_name) |name| netIndexByName(nets, name) orelse return error.UnknownGuardNet else null,
            .guard_radius_mm = objectNumber(item.object, "guard_radius_mm") orelse 0,
        };
    }
    return out;
}

fn parseMovable(
    alloc: std.mem.Allocator,
    args_val: ?std.json.Value,
    pins: []const connector_pinout.Pin,
) ![]const bool {
    const value = argValue(args_val, "movable_pins") orelse return &.{};
    const names = try valueStringList(alloc, value);
    const movable = try alloc.alloc(bool, pins.len);
    @memset(movable, false);
    for (names) |name| movable[pinIndexByName(pins, name) orelse return error.UnknownMovablePin] = true;
    return movable;
}

fn findPart(placement: optimizer.Placement, ref: []const u8) ?usize {
    for (placement.parts, 0..) |part, i| if (std.mem.eql(u8, part.ref_des, ref)) return i;
    return null;
}

fn findPad(part: optimizer.Part, pin: []const u8) ?@import("../placement/geometry.zig").Pad {
    for (part.pads) |pad| if (std.mem.eql(u8, pad.number, pin)) return pad;
    return null;
}

fn worldPin(placement: optimizer.Placement, pin: flat_netlist.FlatPin) ?connector_pinout.Point {
    const part_i = findPart(placement, pin.ref_des) orelse return null;
    const part = placement.parts[part_i];
    const pad = findPad(part, pin.pin) orelse return null;
    const world = optimizer.worldPadCenter(&part, pad.x, pad.y);
    return .{ .x = world[0], .y = world[1] };
}

fn pinIndexByName(pins: []const connector_pinout.Pin, name: []const u8) ?usize {
    for (pins, 0..) |pin, i| if (std.mem.eql(u8, pin.name, name)) return i;
    return null;
}

fn sortConnectorPins(pins: []connector_pinout.Pin, current: []usize) void {
    for (1..pins.len) |i| {
        var at = i;
        while (at > 0 and pinBefore(pins[at], pins[at - 1])) : (at -= 1) {
            std.mem.swap(connector_pinout.Pin, &pins[at], &pins[at - 1]);
            std.mem.swap(usize, &current[at], &current[at - 1]);
        }
    }
}

fn pinBefore(a: connector_pinout.Pin, b: connector_pinout.Pin) bool {
    const an = std.fmt.parseUnsigned(u64, a.name, 10) catch null;
    const bn = std.fmt.parseUnsigned(u64, b.name, 10) catch null;
    if (an != null and bn != null) return an.? < bn.?;
    return std.mem.lessThan(u8, a.name, b.name);
}

fn netIndexByName(nets: []const connector_pinout.Net, name: []const u8) ?usize {
    var found: ?usize = null;
    for (nets, 0..) |net, i| {
        if (std.ascii.eqlIgnoreCase(net.name, name)) return i;
        if (std.ascii.eqlIgnoreCase(net_name.leaf(net.name), name)) {
            if (found != null) return null;
            found = i;
        }
    }
    return found;
}

fn isIgnored(name: []const u8, ignored: []const []const u8) bool {
    if (ignored.len == 0 and std.ascii.eqlIgnoreCase(name, "GND")) return true;
    for (ignored) |item| if (std.ascii.eqlIgnoreCase(name, item)) return true;
    return false;
}

fn argValue(args_val: ?std.json.Value, key: []const u8) ?std.json.Value {
    const args = args_val orelse return null;
    if (args != .object) return null;
    return args.object.get(key);
}

fn argStr(args_val: ?std.json.Value, key: []const u8) ?[]const u8 {
    const value = argValue(args_val, key) orelse return null;
    return if (value == .string) value.string else null;
}

fn argUsize(args_val: ?std.json.Value, key: []const u8) ?usize {
    const value = argValue(args_val, key) orelse return null;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        else => null,
    };
}

fn argU64(args_val: ?std.json.Value, key: []const u8) ?u64 {
    return argUsize(args_val, key);
}

fn argStringList(alloc: std.mem.Allocator, args_val: ?std.json.Value, key: []const u8) []const []const u8 {
    const value = argValue(args_val, key) orelse return &.{};
    return valueStringList(alloc, value) catch &.{};
}

fn valueStringList(alloc: std.mem.Allocator, value: std.json.Value) ![]const []const u8 {
    if (value != .array) return error.ExpectedStringArray;
    const out = try alloc.alloc([]const u8, value.array.items.len);
    for (value.array.items, 0..) |item, i| {
        if (item != .string) return error.ExpectedStringArray;
        out[i] = item.string;
    }
    return out;
}

fn objectStr(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn objectBool(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn objectNumber(object: std.json.ObjectMap, key: []const u8) ?f64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        else => null,
    };
}

fn fail(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    message: []const u8,
) pcb_layout_page.HandlerError!bool {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try aw.writer.writeAll("{\"error\":");
    try pcb_layout_page.writeJsonStr(&aw.writer, message);
    try aw.writer.writeAll("}");
    try out.appendSlice(alloc, aw.written());
    return false;
}

fn failFmt(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) pcb_layout_page.HandlerError!bool {
    return fail(out, alloc, std.fmt.allocPrint(alloc, fmt, args) catch "error");
}

const testing = std.testing;
const mcp_tools = @import("mcp_tools.zig");

test "optimize_connector_pinout is registered read-only" {
    try testing.expect(mcp_tools.isKnownTool("optimize_connector_pinout"));
    try testing.expect(!mcp_tools.isMutationTool("optimize_connector_pinout"));
}

test "connector pinout route trials default to zero in the strict schema" {
    try testing.expect(std.mem.indexOf(u8, mcp_tools.tools_list_result, "route_trials") != null);
    try testing.expect(std.mem.indexOf(u8, mcp_tools.tools_list_result, "default is 0") != null);
}
