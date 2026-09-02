//! Small intent-bearing circuit idioms: pull resistors, checked dividers, and
//! LED indicators. They lower to ordinary instances/pin-net declarations so
//! every existing ERC, BOM, renderer, and exporter sees exactly the same data
//! as the corresponding hand-written component pairs.

const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const env_mod = @import("env.zig");
const evaluator_mod = @import("evaluator.zig");
const instance_mod = @import("instance.zig");
const ids = @import("ids.zig");
const value_kind = @import("value_kind.zig");

const Node = ast.Node;
const Env = env_mod.Env;
const Instance = env_mod.Instance;
const Evaluator = evaluator_mod.Evaluator;
const EvalError = evaluator_mod.EvalError;
const PinNetDecl = evaluator_mod.PinNetDecl;
const resistor_family = "res-0402";

/// Intent-bearing circuit shorthand selected by design-block dispatch.
pub const Kind = enum { pullup, pulldown, divider, led };

/// Lower one shorthand form into ordinary component instances and pin nets.
pub fn emit(
    self: *Evaluator,
    kind: Kind,
    form_children: []const Node,
    env: *Env,
    instances: *std.ArrayList(Instance),
    pin_nets: *std.ArrayList(PinNetDecl),
) EvalError!void {
    return switch (kind) {
        .pullup, .pulldown => emitPull(self, kind, form_children, env, instances, pin_nets),
        .divider => emitDivider(self, form_children, env, instances, pin_nets),
        .led => emitLed(self, form_children, env, instances, pin_nets),
    };
}

fn emitPull(
    self: *Evaluator,
    kind: Kind,
    form: []const Node,
    env: *Env,
    instances: *std.ArrayList(Instance),
    pin_nets: *std.ArrayList(PinNetDecl),
) EvalError!void {
    const min_len: usize = if (kind == .pullup) 4 else 3;
    if (form.len < min_len) {
        self.setError(form[0].span, if (kind == .pullup)
            "(pullup …) expects SIGNAL VALUE RAIL"
        else
            "(pulldown …) expects SIGNAL VALUE [RETURN]");
        return EvalError.ArityError;
    }
    const signal = try stringArg(self, form[1], env, "pull signal");
    const value = try valueText(self, form[2]);
    const has_explicit_rail = form.len >= 4 and form[3].asList() == null;
    const rail = if (has_explicit_rail)
        try stringArg(self, form[3], env, "pull rail")
    else
        "GND";
    const semantic = try std.fmt.allocPrint(self.allocator, "R_{s}_{s}", .{
        if (kind == .pullup) "PU" else "PD", signal,
    });
    const form_id = try ids.getOrCreateFormId(self, form);
    var sidecar = ids.parseChildIdSidecar(self, form);
    const ctx = EmitContext.init(form, form_id, &sidecar, instances, pin_nets);
    try appendPart(self, ctx, .{ .family = resistor_family, .value = value, .prefix = 'R', .name = semantic, .key = "pull" }, &.{
        .{ .pin = "1", .net = signal },
        .{ .pin = "2", .net = rail },
    });
}

fn emitDivider(
    self: *Evaluator,
    form: []const Node,
    env: *Env,
    instances: *std.ArrayList(Instance),
    pin_nets: *std.ArrayList(PinNetDecl),
) EvalError!void {
    if (form.len < 6) {
        self.setError(form[0].span, "(divider …) expects VIN TAP RETURN R_TOP R_BOTTOM [(expect V TOLERANCE)]");
        return EvalError.ArityError;
    }
    const input = try stringArg(self, form[1], env, "divider input net");
    const tap = try stringArg(self, form[2], env, "divider tap net");
    const return_net = try stringArg(self, form[3], env, "divider return net");
    const top_value = try valueText(self, form[4]);
    const bottom_value = try valueText(self, form[5]);
    const top_ohms = (try self.evalNode(form[4], env)).asNumber() orelse return EvalError.TypeError;
    const bottom_ohms = (try self.evalNode(form[5], env)).asNumber() orelse return EvalError.TypeError;
    if (top_ohms <= 0 or bottom_ohms <= 0) {
        self.setError(form[4].span, "divider resistances must be positive");
        return EvalError.InvalidForm;
    }

    const top_name = try std.fmt.allocPrint(self.allocator, "R_{s}_T", .{tap});
    const bottom_name = try std.fmt.allocPrint(self.allocator, "R_{s}_B", .{tap});
    const form_id = try ids.getOrCreateFormId(self, form);
    var sidecar = ids.parseChildIdSidecar(self, form);
    const ctx = EmitContext.init(form, form_id, &sidecar, instances, pin_nets);
    try appendPart(self, ctx, .{ .family = resistor_family, .value = top_value, .prefix = 'R', .name = top_name, .key = "top" }, &.{
        .{ .pin = "1", .net = input },
        .{ .pin = "2", .net = tap },
    });
    try appendPart(self, ctx, .{ .family = resistor_family, .value = bottom_value, .prefix = 'R', .name = bottom_name, .key = "bottom" }, &.{
        .{ .pin = "1", .net = tap },
        .{ .pin = "2", .net = return_net },
    });

    for (form[6..]) |child| {
        if (!child.isForm("expect")) continue;
        const c = child.asList().?;
        if (c.len < 3) continue;
        const target = (try self.evalNode(c[1], env)).asNumber() orelse continue;
        const tolerance_pct = parsePercent(c[2]) orelse continue;
        const vin = voltageFromRailName(input) orelse {
            self.warnFmt(form[1].span, "divider input net '{s}' has no voltage encoded in its name; (expect …) could not be checked", .{input});
            continue;
        };
        const calculated = vin * bottom_ohms / (top_ohms + bottom_ohms);
        const allowed = @abs(target) * tolerance_pct / 100.0;
        const message = std.fmt.allocPrint(self.allocator, "Divider {s}: tap = {d:.4} V, expected {d:.4} V ± {d:.2}%", .{ tap, calculated, target, tolerance_pct }) catch return EvalError.OutOfMemory;
        try self.assertions.append(self.allocator, .{
            .passed = @abs(calculated - target) <= allowed,
            .message = message,
        });
    }
}

fn emitLed(
    self: *Evaluator,
    form: []const Node,
    env: *Env,
    instances: *std.ArrayList(Instance),
    pin_nets: *std.ArrayList(PinNetDecl),
) EvalError!void {
    if (form.len < 5) {
        self.setError(form[0].span, "(led …) expects NAME SUPPLY COLOR (r VALUE) [(return NET)]");
        return EvalError.ArityError;
    }
    const name = try stringArg(self, form[1], env, "LED name");
    const supply = try stringArg(self, form[2], env, "LED supply net");
    const color = form[3].asText() orelse return EvalError.TypeError;
    const r_form = form[4].asList() orelse return EvalError.InvalidForm;
    if (r_form.len < 2 or !std.mem.eql(u8, r_form[0].asAtom() orelse "", "r")) return EvalError.InvalidForm;
    const resistance = try valueText(self, r_form[1]);
    var return_net: []const u8 = "GND";
    var explicit_anode: ?[]const u8 = null;
    for (form[5..]) |child| {
        const c = child.asList() orelse continue;
        if (c.len < 2) continue;
        if (child.isForm("return")) return_net = try stringArg(self, c[1], env, "LED return net");
        if (child.isForm("anode")) explicit_anode = try stringArg(self, c[1], env, "LED anode net");
    }
    const anode_net = explicit_anode orelse
        try std.fmt.allocPrint(self.allocator, "{s}_LED_A", .{name});
    const resistor_name = try std.fmt.allocPrint(self.allocator, "R_{s}", .{name});
    const diode_name = try std.fmt.allocPrint(self.allocator, "D_{s}", .{name});
    const form_id = try ids.getOrCreateFormId(self, form);
    var sidecar = ids.parseChildIdSidecar(self, form);
    const ctx = EmitContext.init(form, form_id, &sidecar, instances, pin_nets);
    try appendPart(self, ctx, .{ .family = resistor_family, .value = resistance, .prefix = 'R', .name = resistor_name, .key = "resistor" }, &.{
        .{ .pin = "1", .net = supply },
        .{ .pin = "2", .net = anode_net },
    });
    try appendPart(self, ctx, .{ .family = "led-0402", .value = color, .prefix = 'D', .name = diode_name, .key = "diode" }, &.{
        .{ .pin = "1", .net = anode_net },
        .{ .pin = "2", .net = return_net },
    });
}

const Wire = struct { pin: []const u8, net: []const u8 };
const PartSpec = struct {
    family: []const u8,
    value: []const u8,
    prefix: u8,
    name: []const u8,
    key: []const u8,
};
const EmitContext = struct {
    form: []const Node,
    form_id: []const u8,
    sidecar: *ids.ChildIdSidecar,
    instances: *std.ArrayList(Instance),
    pin_nets: *std.ArrayList(PinNetDecl),

    fn init(
        form: []const Node,
        form_id: []const u8,
        sidecar: *ids.ChildIdSidecar,
        instances: *std.ArrayList(Instance),
        pin_nets: *std.ArrayList(PinNetDecl),
    ) EmitContext {
        return .{ .form = form, .form_id = form_id, .sidecar = sidecar, .instances = instances, .pin_nets = pin_nets };
    }
};

fn appendPart(
    self: *Evaluator,
    ctx: EmitContext,
    spec: PartSpec,
    wires: []const Wire,
) EvalError!void {
    const resolved = instance_mod.resolveComponent(self, .{ .component_instance = .{
        .family = spec.family,
        .value = spec.value,
    } }) orelse return EvalError.TypeError;
    const cached = self.component_cache.get(spec.family) orelse {
        self.setErrorFmt(ctx.form[0].span, "component '{s}' is not imported for this shorthand", .{spec.family});
        return EvalError.UnboundVariable;
    };
    // A shorthand's value is authored the same way a family call's is, so it
    // gets the same declared-kind check — `(pullup "SDA" 100nF VDD)` is a
    // capacitor written where the resistor value goes.
    if (!value_kind.accepts(cached.param_type, spec.value)) {
        self.setError(ctx.form[0].span, value_kind.mismatchMessage(self.allocator, spec.family, cached.param_type, spec.value));
        return EvalError.TypeError;
    }
    // An authored child sidecar is an explicit migration override: it lets a
    // shorthand replace existing instances without changing their PCB UUIDs.
    // New hierarchical forms need no sidecar and derive from the parent id.
    const id = if (ctx.sidecar.map.get(spec.key)) |existing|
        existing
    else if (self.hierarchical_ids)
        try ids.deriveChildId(self, ctx.form_id, spec.key, 0)
    else
        try ids.getOrCreateChildId(self, ctx.sidecar, spec.key);
    const ref = try ids.nextRefDes(self, spec.prefix);
    try ctx.instances.append(self.allocator, .{
        .ref_des = ref,
        .label = spec.name,
        .origin_key = spec.name,
        .component = resolved.family,
        .value = resolved.value,
        .footprint = resolved.footprint,
        .symbol = resolved.symbol,
        .pinout = resolved.pinout,
        .properties = resolved.properties,
        .attrs = resolved.attrs,
        .docs = resolved.docs,
        .thermal = .{ .decl = resolved.thermal },
        .requirements = resolved.requirements,
        .requirements_ignored = resolved.requirements_ignored,
        .electrical = resolved.electrical,
        .source_offset = ctx.form[0].span.offset,
        .id = id,
    });
    for (wires) |wire| try ctx.pin_nets.append(self.allocator, .{ .ref_des = ref, .pin = wire.pin, .net = wire.net });
}

fn stringArg(self: *Evaluator, node: Node, env: *Env, what: []const u8) EvalError![]const u8 {
    const value = try self.evalNode(node, env);
    return value.asString() orelse {
        self.setErrorFmt(node.span, "{s} must be a string", .{what});
        return EvalError.TypeError;
    };
}

fn valueText(self: *Evaluator, node: Node) EvalError![]const u8 {
    if (node.asText()) |text| return text;
    if (node.asNumber()) |number| return std.fmt.allocPrint(self.allocator, "{d}", .{number}) catch EvalError.OutOfMemory;
    self.setError(node.span, "component value must be a number or value token");
    return EvalError.TypeError;
}

fn parsePercent(node: Node) ?f64 {
    if (node.asNumber()) |n| return n;
    const atom = node.asText() orelse return null;
    const text = if (std.mem.endsWith(u8, atom, "%")) atom[0 .. atom.len - 1] else atom;
    return std.fmt.parseFloat(f64, text) catch null;
}

/// Decode the common voltage-bearing rail spellings used in designs. This is
/// intentionally limited to names, because the shorthand evaluates before the
/// post-build rail graph exists.
fn voltageFromRailName(name: []const u8) ?f64 {
    var start: usize = 0;
    while (start < name.len and !(std.ascii.isDigit(name[start]) or name[start] == '.')) : (start += 1) {}
    if (start >= name.len) return null;
    var buf: [32]u8 = undefined;
    var len: usize = 0;
    var seen_sep = false;
    for (name[start..], 0..) |c, rel_i| {
        if (std.ascii.isDigit(c)) {
            if (len >= buf.len) return null;
            buf[len] = c;
            len += 1;
        } else if (!seen_sep and isVoltageSeparator(c)) {
            const next_i = start + rel_i + 1;
            if (c != '.' and (next_i >= name.len or !std.ascii.isDigit(name[next_i]))) break;
            if (len >= buf.len) return null;
            buf[len] = '.';
            len += 1;
            seen_sep = true;
        } else if (len > 0) break;
    }
    if (len == 0) return null;
    if (buf[len - 1] == '.') len -= 1;
    return std.fmt.parseFloat(f64, buf[0..len]) catch null;
}

fn isVoltageSeparator(c: u8) bool {
    return c == '.' or c == 'P' or c == 'V';
}

const testing = std.testing;
const parser = @import("../sexpr/parser.zig");

fn testEvaluator(allocator: std.mem.Allocator) !Evaluator {
    var eval = Evaluator.init(allocator, "");
    inline for (.{ resistor_family, "led-0402" }) |family| try eval.component_cache.put(allocator, family, .{
        .name = family,
        .symbol_name = "",
        .footprint_name = "",
        .is_family = true,
        .param_type = "",
    });
    return eval;
}

// spec: eval/micro_forms - pullup and pulldown lower to one resistor with explicit signal and rail nets
test "pull shorthands emit ordinary resistor instances" {
    const allocator = std.heap.page_allocator;
    var eval = try testEvaluator(allocator);
    defer eval.deinit();
    var env = Env.init(allocator, null);
    defer env.deinit();
    var instances: std.ArrayList(Instance) = .empty;
    var pin_nets: std.ArrayList(PinNetDecl) = .empty;
    const nodes = try parser.parse(allocator, "(pullup \"SDA\" 4.7k \"V_3V3\") (pulldown \"EN\" 10k)");
    try emit(&eval, .pullup, nodes[0].asList().?, &env, &instances, &pin_nets);
    try emit(&eval, .pulldown, nodes[1].asList().?, &env, &instances, &pin_nets);
    try testing.expectEqual(@as(usize, 2), instances.items.len);
    try testing.expectEqualStrings("SDA", pin_nets.items[0].net);
    try testing.expectEqualStrings("V_3V3", pin_nets.items[1].net);
    try testing.expectEqualStrings("GND", pin_nets.items[3].net);
}

// spec: eval/micro_forms - divider emits two resistors and records a checked expected tap voltage
test "divider shorthand emits a checked resistor pair" {
    const allocator = std.heap.page_allocator;
    var eval = try testEvaluator(allocator);
    defer eval.deinit();
    var env = Env.init(allocator, null);
    defer env.deinit();
    var instances: std.ArrayList(Instance) = .empty;
    var pin_nets: std.ArrayList(PinNetDecl) = .empty;
    const nodes = try parser.parse(allocator, "(divider \"V_12V\" \"SENSE\" \"GND\" 47k 10k (expect 2.105 5%))");
    try emit(&eval, .divider, nodes[0].asList().?, &env, &instances, &pin_nets);
    try testing.expectEqual(@as(usize, 2), instances.items.len);
    try testing.expectEqual(@as(usize, 1), eval.assertions.items.len);
    try testing.expect(eval.assertions.items[0].passed);
}

// spec: eval/micro_forms - led emits a resistor and diode and accepts an explicit anode net for migrations
test "led shorthand emits its resistor and diode" {
    const allocator = std.heap.page_allocator;
    var eval = try testEvaluator(allocator);
    defer eval.deinit();
    var env = Env.init(allocator, null);
    defer env.deinit();
    var instances: std.ArrayList(Instance) = .empty;
    var pin_nets: std.ArrayList(PinNetDecl) = .empty;
    const nodes = try parser.parse(allocator, "(led \"PWR\" \"V_3V3\" green (r 1k) (anode \"PWR_A\"))");
    try emit(&eval, .led, nodes[0].asList().?, &env, &instances, &pin_nets);
    try testing.expectEqual(@as(usize, 2), instances.items.len);
    try testing.expectEqualStrings("PWR_A", pin_nets.items[1].net);
    try testing.expectEqualStrings("PWR_A", pin_nets.items[2].net);
    try testing.expectEqualStrings("GND", pin_nets.items[3].net);
}

// spec: eval/micro_forms - a shorthand value that is not the family's declared kind is rejected like a family call
test "a shorthand resistor value of the wrong kind is rejected" {
    const allocator = std.heap.page_allocator;
    var eval = try testEvaluator(allocator);
    defer eval.deinit();
    // Give the resistor family its real declared kind (the shared fixture
    // leaves it blank so the older tests exercise the untyped path).
    try eval.component_cache.put(allocator, resistor_family, .{
        .name = resistor_family,
        .symbol_name = "",
        .footprint_name = "",
        .is_family = true,
        .param_type = "resistance",
    });
    var env = Env.init(allocator, null);
    defer env.deinit();
    var instances: std.ArrayList(Instance) = .empty;
    var pin_nets: std.ArrayList(PinNetDecl) = .empty;
    // Quoted, because a bare `100nF` tokenizes as the NUMBER 1e-7 and reaches
    // the shorthand as digits with no unit left to contradict anything.
    const nodes = try parser.parse(allocator, "(pullup \"SDA\" \"100nF\" \"V_3V3\") (pullup \"SCL\" 4.7k \"V_3V3\")");
    try testing.expectError(EvalError.TypeError, emit(&eval, .pullup, nodes[0].asList().?, &env, &instances, &pin_nets));
    try testing.expect(std.mem.indexOf(u8, eval.last_error.?.message, "is not a resistance value") != null);
    // The right kind still lowers normally.
    try emit(&eval, .pullup, nodes[1].asList().?, &env, &instances, &pin_nets);
    try testing.expectEqual(@as(usize, 1), instances.items.len);
}
