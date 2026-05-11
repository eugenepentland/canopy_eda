const std = @import("std");
const ast = @import("../sexpr/ast.zig");

const Node = ast.Node;

/// Configuration parsed from a top-level `(power-config …)` form. Currently
/// only carries the derating fraction (default 0.8) but is the natural home
/// for future board-level power policy knobs.
pub const PowerConfig = struct {
    /// Fraction of declared source capacity that constitutes "tight"
    /// margin. ERC flags rails whose typical load exceeds
    /// `derating × source_typ`. Null → consumer uses its default (0.8).
    derating: ?f64 = null,
};

/// Parse `(power-config (derating 0.8))` into a `PowerConfig`. Returns
/// null when no derating sub-form is present so the caller can decide
/// what default to apply (Phase 2C: 0.8 in `power_budget`).
pub fn parse(form_children: []const Node) ?PowerConfig {
    var cfg = PowerConfig{};
    var any = false;

    for (form_children[1..]) |sub| {
        const sub_list = sub.asList() orelse continue;
        if (sub_list.len < 2) continue;
        const head = sub_list[0].asAtom() orelse continue;
        if (std.mem.eql(u8, head, "derating")) {
            const v = sub_list[1].asNumber() orelse continue;
            // Clamp to the (0, 1] band — values outside that range are
            // either meaningless ("derating 0" disables loading) or
            // wider-than-rated ("derating 1.5" would let the check pass
            // when it shouldn't).
            if (v <= 0 or v > 1) continue;
            cfg.derating = v;
            any = true;
        }
        // Unknown sub-forms ignored on purpose.
    }
    return if (any) cfg else null;
}

// ── Tests ──────────────────────────────────────────────────────────────

const parser = @import("../sexpr/parser.zig");

// spec: eval/power_config - Parses (power-config (derating R)) into a fractional derating value
test "parse extracts derating" {
    const alloc = std.testing.allocator;
    const nodes = try parser.parse(alloc, "(power-config (derating 0.7))");
    defer parser.freeNodes(alloc, nodes);
    const form = nodes[0].asList().?;

    const cfg = parse(form).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), cfg.derating.?, 1e-9);
}

// spec: eval/power_config - Returns null when the form has no derating sub-form
test "parse returns null with no derating" {
    const alloc = std.testing.allocator;
    const nodes = try parser.parse(alloc, "(power-config)");
    defer parser.freeNodes(alloc, nodes);
    const form = nodes[0].asList().?;

    try std.testing.expect(parse(form) == null);
}

// spec: eval/power_config - Clamps derating to the (0, 1] range
test "parse rejects out-of-range derating" {
    const alloc = std.testing.allocator;
    const nodes_too_high = try parser.parse(alloc, "(power-config (derating 1.5))");
    defer parser.freeNodes(alloc, nodes_too_high);
    try std.testing.expect(parse(nodes_too_high[0].asList().?) == null);

    const nodes_zero = try parser.parse(alloc, "(power-config (derating 0))");
    defer parser.freeNodes(alloc, nodes_zero);
    try std.testing.expect(parse(nodes_zero[0].asList().?) == null);

    const nodes_negative = try parser.parse(alloc, "(power-config (derating -0.2))");
    defer parser.freeNodes(alloc, nodes_negative);
    try std.testing.expect(parse(nodes_negative[0].asList().?) == null);
}

// spec: eval/power_config - Ignores unknown sub-forms
test "parse ignores unknown sub-forms" {
    const alloc = std.testing.allocator;
    const nodes = try parser.parse(alloc, "(power-config (something \"x\") (derating 0.75))");
    defer parser.freeNodes(alloc, nodes);
    const form = nodes[0].asList().?;

    const cfg = parse(form).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), cfg.derating.?, 1e-9);
}
