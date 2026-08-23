//! Parser for the explicit top-level `(board-role board|subcircuit)` form.

const std = @import("std");
const Node = @import("../sexpr/ast.zig").Node;
const BoardRole = @import("env.zig").BoardRole;

/// Parse an explicit board role, warning and retaining the safe subcircuit
/// default for missing, malformed, or unknown values.
pub fn parse(evaluator: anytype, children: []const Node) BoardRole {
    if (children.len < 2) {
        evaluator.warnFmt(children[0].span, "(board-role …) needs a role word — expected board|subcircuit", .{});
        return .subcircuit;
    }
    const word = children[1].asAtom() orelse {
        evaluator.warnFmt(children[1].span, "(board-role …) role must be a bare word — expected board|subcircuit", .{});
        return .subcircuit;
    };
    if (std.mem.eql(u8, word, "board")) return .board;
    if (std.mem.eql(u8, word, "subcircuit")) return .subcircuit;
    evaluator.warnFmt(children[1].span, "unknown board role '{s}' — expected board|subcircuit", .{word});
    return .subcircuit;
}

/// Parse `(power-plane on|off)`, retaining the compatibility default (on) for
/// missing or invalid values.
pub fn parsePowerPlane(evaluator: anytype, children: []const Node) bool {
    if (children.len < 2) {
        evaluator.warnFmt(children[0].span, "(power-plane …) needs on|off", .{});
        return true;
    }
    const word = children[1].asAtom() orelse {
        evaluator.warnFmt(children[1].span, "(power-plane …) value must be on|off", .{});
        return true;
    };
    if (std.mem.eql(u8, word, "on")) return true;
    if (std.mem.eql(u8, word, "off")) return false;
    evaluator.warnFmt(children[1].span, "unknown power-plane value '{s}' — expected on|off", .{word});
    return true;
}
