//! Parsing and materialisation for `(test-point …)`: physical pads by default,
//! with `(virtual)` preserving the schematic-only marker behavior.

const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const env_mod = @import("env.zig");
const evaluator_mod = @import("evaluator.zig");
const instance_mod = @import("instance.zig");
const modules = @import("modules.zig");
const ids = @import("ids.zig");

const Node = ast.Node;
const TestPoint = env_mod.TestPoint;
const TestPointTag = env_mod.TestPointTag;
const Evaluator = evaluator_mod.Evaluator;
const EvalError = evaluator_mod.EvalError;
const Env = env_mod.Env;
const Instance = env_mod.Instance;
const PinNetDecl = evaluator_mod.PinNetDecl;
const Note = env_mod.Note;

const component_name = "testpoint";

/// Mutable design-block collections populated by a test-point form.
pub const EvalContext = struct {
    instances: *std.ArrayList(Instance),
    pin_nets: *std.ArrayList(PinNetDecl),
    notes: *std.ArrayList(Note),
    test_points: *std.ArrayList(TestPoint),
};

/// Parse a `(test-point "TP1" "NET" [(virtual)] (purpose "...")
/// (required-for tag1 tag2))` form into a `TestPoint`. Returns null when the
/// positional ref-des or net is missing — caller handles the malformed-form
/// case (typically by emitting a parse warning and skipping the form).
///
/// Sub-form recognition is forgiving: unknown sub-forms are silently
/// ignored so the language can grow new optional annotations without
/// breaking older designs. Unknown tags inside `(required-for …)` are
/// likewise dropped, surfaced (eventually) by a separate lint rather than
/// a hard parse error.
///
/// The returned slice for `required_for` is freshly allocated; strings in
/// `ref_des`, `net`, and `purpose` are borrowed from the source AST.
pub fn parse(
    allocator: std.mem.Allocator,
    form_children: []const Node,
) std.mem.Allocator.Error!?TestPoint {
    // form_children[0] is the head atom ("test-point"); positional args
    // start at index 1.
    if (form_children.len < 3) return null;
    const ref_des = form_children[1].asString() orelse return null;
    const net = form_children[2].asString() orelse return null;

    var purpose: []const u8 = "";
    var tags: std.ArrayList(TestPointTag) = .empty;
    defer tags.deinit(allocator);
    var virtual = false;

    for (form_children[3..]) |sub| {
        const sub_list = sub.asList() orelse continue;
        if (sub_list.len == 0) continue;
        const head = sub_list[0].asAtom() orelse continue;

        if (std.mem.eql(u8, head, "virtual")) {
            virtual = true;
        } else if (std.mem.eql(u8, head, "purpose") and sub_list.len >= 2) {
            if (sub_list[1].asString()) |s| purpose = s;
        } else if (std.mem.eql(u8, head, "required-for") and sub_list.len >= 2) {
            for (sub_list[1..]) |tag_node| {
                const tag_atom = tag_node.asAtom() orelse continue;
                if (parseTag(tag_atom)) |t| try tags.append(allocator, t);
            }
        }
        // Unknown sub-forms ignored on purpose.
    }

    return .{
        .ref_des = ref_des,
        .net = net,
        .purpose = purpose,
        .required_for = try tags.toOwnedSlice(allocator),
        .virtual = virtual,
    };
}

/// Evaluate one first-class test-point declaration. Every declaration is kept
/// in `test_points` for its purpose / required-for metadata. By default it also
/// materialises the same library-backed part as
/// `(instance "TP1" testpoint (pin 1 "NET"))`; `(virtual)` is the explicit
/// marker-only escape hatch.
///
/// The returned instance is already appended to `instances`; section callers
/// use the optional return solely to add that same part to section membership.
pub fn evalForm(
    self: *Evaluator,
    form_children: []const Node,
    env: *Env,
    ctx: EvalContext,
) EvalError!?Instance {
    const tp = (try parse(self.allocator, form_children)) orelse return null;

    if (tp.virtual) {
        try ctx.test_points.append(self.allocator, tp);
        return null;
    }

    // The unified form is self-contained: callers should not have to retain
    // an `(import testpoint)` solely because the declaration now emits a pad.
    try modules.resolveImport(self, component_name, env);

    const parsed_id = ids.parseId(form_children);
    const inst_id = parsed_id orelse try ids.generateId(self);
    if (parsed_id == null) {
        try self.pending_ids.append(self.allocator, .{
            .form_offset = form_children[0].span.offset -| 1,
            .id = inst_id,
        });
    }

    var inst = instance_mod.instanceFromValue(
        self,
        .{ .component = component_name },
        tp.ref_des,
        form_children[0].span.offset,
        inst_id,
    ) orelse {
        self.setError(form_children[0].span, "testpoint component did not resolve to a physical library part");
        return EvalError.UnboundVariable;
    };
    inst.label = tp.ref_des;
    inst.origin_key = tp.ref_des;

    try ids.noteAuthoredRefDes(self, tp.ref_des, form_children[0].span);
    try ctx.instances.append(self.allocator, inst);
    try ctx.pin_nets.append(self.allocator, .{
        .ref_des = tp.ref_des,
        .pin = "1",
        .net = tp.net,
    });
    if (tp.purpose.len > 0) {
        try ctx.notes.append(self.allocator, .{ .ref_des = tp.ref_des, .text = tp.purpose });
    }
    try ctx.test_points.append(self.allocator, tp);
    return inst;
}

fn parseTag(s: []const u8) ?TestPointTag {
    if (std.mem.eql(u8, s, "bring-up")) return .bring_up;
    if (std.mem.eql(u8, s, "power")) return .power;
    if (std.mem.eql(u8, s, "clock")) return .clock;
    if (std.mem.eql(u8, s, "reset")) return .reset;
    if (std.mem.eql(u8, s, "debug")) return .debug;
    if (std.mem.eql(u8, s, "signal")) return .signal;
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────────

const parser = @import("../sexpr/parser.zig");

fn freeTestPoint(allocator: std.mem.Allocator, tp: TestPoint) void {
    if (tp.required_for.len > 0) allocator.free(tp.required_for);
}

// spec: eval/test_point - Parses ref-des and net from the first two positional arguments
test "parse reads ref_des and net positionally" {
    const alloc = std.testing.allocator;
    const nodes = try parser.parse(alloc, "(test-point \"TP1\" \"VDD_3V3\")");
    defer parser.freeNodes(alloc, nodes);
    const form = nodes[0].asList().?;

    const tp = (try parse(alloc, form)).?;
    defer freeTestPoint(alloc, tp);
    try std.testing.expectEqualStrings("TP1", tp.ref_des);
    try std.testing.expectEqualStrings("VDD_3V3", tp.net);
    try std.testing.expect(!tp.virtual);
}

// spec: eval/test_point - Parses (virtual) as an explicit marker-only test point
test "parse recognizes virtual marker" {
    const alloc = std.testing.allocator;
    const nodes = try parser.parse(alloc, "(test-point \"TP1\" \"VDD_3V3\" (virtual))");
    defer parser.freeNodes(alloc, nodes);

    const tp = (try parse(alloc, nodes[0].asList().?)).?;
    defer freeTestPoint(alloc, tp);
    try std.testing.expect(tp.virtual);
}

// spec: eval/test_point - Parses an optional (purpose "...") sub-form into the purpose field
test "parse extracts purpose sub-form" {
    const alloc = std.testing.allocator;
    const nodes = try parser.parse(alloc, "(test-point \"TP1\" \"VDD_3V3\" (purpose \"3.3V rail probe\"))");
    defer parser.freeNodes(alloc, nodes);
    const form = nodes[0].asList().?;

    const tp = (try parse(alloc, form)).?;
    defer freeTestPoint(alloc, tp);
    try std.testing.expectEqualStrings("3.3V rail probe", tp.purpose);
}

// spec: eval/test_point - Parses (required-for ...) sub-form recognizing bring-up power clock reset debug and signal tags
test "parse collects required-for tags" {
    const alloc = std.testing.allocator;
    const nodes = try parser.parse(alloc, "(test-point \"TP1\" \"VDD_3V3\" (required-for bring-up power clock reset debug signal))");
    defer parser.freeNodes(alloc, nodes);
    const form = nodes[0].asList().?;

    const tp = (try parse(alloc, form)).?;
    defer freeTestPoint(alloc, tp);
    try std.testing.expectEqual(@as(usize, 6), tp.required_for.len);
    try std.testing.expectEqual(TestPointTag.bring_up, tp.required_for[0]);
    try std.testing.expectEqual(TestPointTag.power, tp.required_for[1]);
    try std.testing.expectEqual(TestPointTag.clock, tp.required_for[2]);
    try std.testing.expectEqual(TestPointTag.reset, tp.required_for[3]);
    try std.testing.expectEqual(TestPointTag.debug, tp.required_for[4]);
    try std.testing.expectEqual(TestPointTag.signal, tp.required_for[5]);
}

// spec: eval/test_point - Returns null when ref-des or net positional arguments are missing
test "parse returns null when positional args missing" {
    const alloc = std.testing.allocator;
    const nodes = try parser.parse(alloc, "(test-point)");
    defer parser.freeNodes(alloc, nodes);
    const form = nodes[0].asList().?;

    try std.testing.expect((try parse(alloc, form)) == null);
}

// spec: eval/test_point - Ignores unknown sub-forms and unknown required-for tags
test "parse ignores unknown sub-forms and tags" {
    const alloc = std.testing.allocator;
    const nodes = try parser.parse(alloc, "(test-point \"TP1\" \"VDD_3V3\" (random-thing \"abc\") (required-for power gibberish))");
    defer parser.freeNodes(alloc, nodes);
    const form = nodes[0].asList().?;

    const tp = (try parse(alloc, form)).?;
    defer freeTestPoint(alloc, tp);
    try std.testing.expectEqual(@as(usize, 1), tp.required_for.len);
    try std.testing.expectEqual(TestPointTag.power, tp.required_for[0]);
}

fn addTestPointComponent(eval: *Evaluator, allocator: std.mem.Allocator) !void {
    try eval.component_cache.put(allocator, component_name, .{
        .name = component_name,
        .symbol_name = "",
        .footprint_name = "testpoint-1mm",
        .pinout_name = component_name,
        .is_family = false,
        .param_type = "",
    });
}

fn evalFixture(allocator: std.mem.Allocator, source: []const u8) !*env_mod.DesignBlock {
    var eval = Evaluator.init(allocator, ".");
    try addTestPointComponent(&eval, allocator);
    var env = Env.init(allocator, null);
    const nodes = try parser.parse(allocator, source);
    const value = try eval.evalNodes(nodes, &env);
    return value.design_block;
}

// spec: eval/test_point - Materializes a physical testpoint instance and pin-1 net by default
test "default form materializes a physical testpoint" {
    const block = try evalFixture(std.heap.page_allocator,
        \\(design-block "probe"
        \\  (test-point "TP_SIG" "SIG" (purpose "scope here") (id abcdef12)))
    );

    try std.testing.expectEqual(@as(usize, 1), block.instances.len);
    try std.testing.expectEqualStrings("TP1", block.instances[0].ref_des);
    try std.testing.expectEqualStrings("TP_SIG", block.instances[0].label);
    try std.testing.expectEqualStrings(component_name, block.instances[0].component);
    try std.testing.expect(env_mod.isTestPoint(block.instances[0].component));
    try std.testing.expectEqualStrings("testpoint-1mm", block.instances[0].footprint);
    try std.testing.expectEqualStrings("abcdef12", block.instances[0].id);
    try std.testing.expectEqual(@as(usize, 1), block.nets.len);
    try std.testing.expectEqualStrings("SIG", block.nets[0].name);
    try std.testing.expectEqualStrings("TP1", block.nets[0].pins[0].ref_des);
    try std.testing.expectEqualStrings("1", block.nets[0].pins[0].pin);
    try std.testing.expectEqual(@as(usize, 1), block.notes.len);
    try std.testing.expectEqualStrings("scope here", block.notes[0].text);
    try std.testing.expectEqual(@as(usize, 1), block.test_points.len);
    try std.testing.expectEqualStrings("TP1", block.test_points[0].ref_des);
    try std.testing.expect(!block.test_points[0].virtual);
}

// spec: eval/test_point - Keeps (virtual) test points marker-only with no physical instance or pad net
test "virtual form remains marker only" {
    const block = try evalFixture(std.heap.page_allocator,
        \\(design-block "probe"
        \\  (test-point "TP_SIG" "SIG" (virtual) (purpose "schematic marker")))
    );

    try std.testing.expectEqual(@as(usize, 0), block.instances.len);
    try std.testing.expectEqual(@as(usize, 0), block.nets.len);
    try std.testing.expectEqual(@as(usize, 1), block.test_points.len);
    try std.testing.expect(block.test_points[0].virtual);
    try std.testing.expectEqualStrings("schematic marker", block.test_points[0].purpose);
}

// spec: eval/test_point - Materializes test points inside sections and preserves section membership
test "section form materializes a member instance" {
    const block = try evalFixture(std.heap.page_allocator,
        \\(design-block "probe"
        \\  (section "Debug" "physical probes"
        \\    (test-point "TP_SIG" "SIG" (id abcdef12))))
    );

    try std.testing.expectEqual(@as(usize, 1), block.instances.len);
    try std.testing.expectEqual(@as(usize, 1), block.sections.len);
    try std.testing.expectEqual(@as(usize, 1), block.sections[0].instances.len);
    try std.testing.expectEqualStrings("TP1", block.sections[0].instances[0].ref_des);
}

// spec: eval/test_point - Materializes test points inside nested sections and preserves nested membership
test "nested section form materializes a member instance" {
    const block = try evalFixture(std.heap.page_allocator,
        \\(design-block "probe"
        \\  (section "Debug" "physical probes"
        \\    (section "Signals" "logic probes"
        \\      (test-point "TP_SIG" "SIG" (id abcdef12)))))
    );

    try std.testing.expectEqual(@as(usize, 1), block.instances.len);
    try std.testing.expectEqual(@as(usize, 1), block.sections[0].instances.len);
    try std.testing.expectEqual(@as(usize, 1), block.sections[0].sub_sections.len);
    try std.testing.expectEqual(@as(usize, 1), block.sections[0].sub_sections[0].instances.len);
    try std.testing.expectEqualStrings("TP1", block.sections[0].sub_sections[0].instances[0].ref_des);
}
