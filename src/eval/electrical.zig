const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const env_mod = @import("env.zig");

const Node = ast.Node;
const ElectricalDecl = env_mod.ElectricalDecl;
const ElectricalType = env_mod.ElectricalType;
const Drive = env_mod.Drive;

/// Parse a `(electrical "PIN_FN" (type X) (v-ih-min Y) …)` form into an
/// `ElectricalDecl`. Returns null when the pin function name positional
/// argument is missing — caller emits a parse warning and skips.
///
/// Recognised sub-forms (all optional, missing fields stay null):
/// - `(type input|output|io|power-in|power-out|passive|nc)`
/// - `(drive push-pull|open-drain|open-emitter)`
/// - `(v-ih-min V)`, `(v-il-max V)`, `(v-oh-typ V)`, `(v-ol-typ V)`
/// - `(max-voltage V)`
/// - `(domain digital|analog|rf|…)`
///
/// Unknown sub-forms / unknown enum atoms are ignored on purpose so
/// future fields can land without breaking older library files.
pub fn parse(form_children: []const Node) ?ElectricalDecl {
    // form_children[0] is the head atom; arg 1 is the pin name.
    if (form_children.len < 2) return null;
    const pin_name = form_children[1].asString() orelse return null;

    var decl = ElectricalDecl{ .pin = pin_name };
    for (form_children[2..]) |sub| {
        const sub_list = sub.asList() orelse continue;
        if (sub_list.len < 2) continue;
        const head = sub_list[0].asAtom() orelse continue;

        if (std.mem.eql(u8, head, "type")) {
            const v = sub_list[1].asAtom() orelse continue;
            decl.electrical_type = parseElectricalType(v);
        } else if (std.mem.eql(u8, head, "drive")) {
            const v = sub_list[1].asAtom() orelse continue;
            decl.drive = parseDrive(v);
        } else if (std.mem.eql(u8, head, "v-ih-min")) {
            decl.v_ih_min = sub_list[1].asNumber();
        } else if (std.mem.eql(u8, head, "v-il-max")) {
            decl.v_il_max = sub_list[1].asNumber();
        } else if (std.mem.eql(u8, head, "v-oh-typ")) {
            decl.v_oh_typ = sub_list[1].asNumber();
        } else if (std.mem.eql(u8, head, "v-ol-typ")) {
            decl.v_ol_typ = sub_list[1].asNumber();
        } else if (std.mem.eql(u8, head, "max-voltage")) {
            decl.max_voltage = sub_list[1].asNumber();
        } else if (std.mem.eql(u8, head, "domain")) {
            if (sub_list[1].asAtom()) |a| decl.domain = a;
        }
        // Unknown sub-forms ignored.
    }
    return decl;
}

fn parseElectricalType(s: []const u8) ?ElectricalType {
    if (std.mem.eql(u8, s, "input")) return .input;
    if (std.mem.eql(u8, s, "output")) return .output;
    if (std.mem.eql(u8, s, "io")) return .io;
    if (std.mem.eql(u8, s, "power-in")) return .power_in;
    if (std.mem.eql(u8, s, "power-out")) return .power_out;
    if (std.mem.eql(u8, s, "passive")) return .passive;
    if (std.mem.eql(u8, s, "nc")) return .nc;
    return null;
}

fn parseDrive(s: []const u8) ?Drive {
    if (std.mem.eql(u8, s, "push-pull")) return .push_pull;
    if (std.mem.eql(u8, s, "open-drain")) return .open_drain;
    if (std.mem.eql(u8, s, "open-emitter")) return .open_emitter;
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────────

const parser = @import("../sexpr/parser.zig");

// spec: eval/electrical - Parses pin function name from the first positional argument
test "parse reads pin function name" {
    const alloc = std.testing.allocator;
    const nodes = try parser.parse(alloc, "(electrical \"VDD_1\" (type power-in))");
    defer parser.freeNodes(alloc, nodes);
    const form = nodes[0].asList().?;
    const decl = parse(form).?;
    try std.testing.expectEqualStrings("VDD_1", decl.pin);
    try std.testing.expectEqual(ElectricalType.power_in, decl.electrical_type.?);
}

// spec: eval/electrical - Returns null when the pin function name is missing
test "parse returns null without pin name" {
    const alloc = std.testing.allocator;
    const nodes = try parser.parse(alloc, "(electrical)");
    defer parser.freeNodes(alloc, nodes);
    try std.testing.expect(parse(nodes[0].asList().?) == null);
}

// spec: eval/electrical - Recognises every electrical-type enum atom
test "parse recognises all electrical types" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { src: []const u8, expect: ElectricalType }{
        .{ .src = "(electrical \"P\" (type input))", .expect = .input },
        .{ .src = "(electrical \"P\" (type output))", .expect = .output },
        .{ .src = "(electrical \"P\" (type io))", .expect = .io },
        .{ .src = "(electrical \"P\" (type power-in))", .expect = .power_in },
        .{ .src = "(electrical \"P\" (type power-out))", .expect = .power_out },
        .{ .src = "(electrical \"P\" (type passive))", .expect = .passive },
        .{ .src = "(electrical \"P\" (type nc))", .expect = .nc },
    };
    for (cases) |c| {
        const nodes = try parser.parse(alloc, c.src);
        defer parser.freeNodes(alloc, nodes);
        const decl = parse(nodes[0].asList().?).?;
        try std.testing.expectEqual(c.expect, decl.electrical_type.?);
    }
}

// spec: eval/electrical - Parses voltage level fields v-ih-min v-il-max v-oh-typ v-ol-typ max-voltage
test "parse captures voltage levels" {
    const alloc = std.testing.allocator;
    const src =
        \\(electrical "GPIO_PA5"
        \\  (type io)
        \\  (drive push-pull)
        \\  (v-ih-min 2.31)
        \\  (v-il-max 0.99)
        \\  (v-oh-typ 3.1)
        \\  (v-ol-typ 0.4)
        \\  (max-voltage 3.6)
        \\  (domain digital))
    ;
    const nodes = try parser.parse(alloc, src);
    defer parser.freeNodes(alloc, nodes);
    const decl = parse(nodes[0].asList().?).?;
    try std.testing.expectEqual(ElectricalType.io, decl.electrical_type.?);
    try std.testing.expectEqual(Drive.push_pull, decl.drive.?);
    try std.testing.expectApproxEqAbs(@as(f64, 2.31), decl.v_ih_min.?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.99), decl.v_il_max.?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3.1), decl.v_oh_typ.?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), decl.v_ol_typ.?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3.6), decl.max_voltage.?, 1e-9);
    try std.testing.expectEqualStrings("digital", decl.domain);
}

// spec: eval/electrical - Ignores unknown sub-forms and unrecognised enum atoms
test "parse ignores unknown sub-forms" {
    const alloc = std.testing.allocator;
    const nodes = try parser.parse(alloc, "(electrical \"VDD\" (type power-in) (mystery 42) (drive nonsense))");
    defer parser.freeNodes(alloc, nodes);
    const decl = parse(nodes[0].asList().?).?;
    try std.testing.expectEqual(ElectricalType.power_in, decl.electrical_type.?);
    try std.testing.expect(decl.drive == null);
}
