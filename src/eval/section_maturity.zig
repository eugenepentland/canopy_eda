//! Section-maturity crediting for the sub-block idiom. A `(section …)` whose
//! pin-level implementation is sealed in a module carries no direct instances
//! or `(pins …)` groups — the `(sub-block …)` is *not* evaluated inside the
//! section body, the documented idiom places it at design-block top level
//! right after its section — so the content-based inference in
//! `design_block.zig` marks it `concept` and ERC's concept_remaining check
//! reports a fully-implemented subsystem as unimplemented. This pass upgrades
//! such a section to `implemented` when the design associates it with a real
//! sub-block: a `(group …)` (top-level or inside `(diagram-layout …)`) whose
//! members list both the section name and an existing sub-block name, or a
//! `(sub-block …)` form directly following the `(section …)` form.

const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const env_mod = @import("env.zig");

const Node = ast.Node;

/// Upgrade `concept` sections that a `(group …)` membership or an adjacent
/// top-level `(sub-block …)` shows to be implemented. Runs after the block
/// body loop, before the sections are frozen onto the `DesignBlock`.
pub fn creditSections(
    sections: []env_mod.Section,
    sub_blocks: []const env_mod.SubBlock,
    groups: []const env_mod.Group,
    layout_groups: []const env_mod.LayoutGroup,
    body_forms: []const Node,
) void {
    for (sections) |*sec| {
        if (sec.status != .concept) continue;
        if (creditedByGroup(sec.name, sub_blocks, groups, layout_groups) or
            creditedByAdjacency(sec.name, body_forms))
        {
            sec.status = .implemented;
        }
    }
}

/// A group whose member list names both the section and a real sub-block is
/// the author's explicit "this sub-block implements that section" tie (e.g.
/// `(group "K-band TX" "ADF4159 #1 PLL" "pll")`).
fn creditedByGroup(
    sec_name: []const u8,
    sub_blocks: []const env_mod.SubBlock,
    groups: []const env_mod.Group,
    layout_groups: []const env_mod.LayoutGroup,
) bool {
    for (groups) |g| {
        if (membersTieSectionToSubBlock(g.members, sec_name, sub_blocks)) return true;
    }
    for (layout_groups) |g| {
        if (membersTieSectionToSubBlock(g.members, sec_name, sub_blocks)) return true;
    }
    return false;
}

fn membersTieSectionToSubBlock(
    members: []const []const u8,
    sec_name: []const u8,
    sub_blocks: []const env_mod.SubBlock,
) bool {
    var lists_section = false;
    var lists_sub_block = false;
    for (members) |m| {
        if (std.mem.eql(u8, m, sec_name)) lists_section = true;
        if (isSubBlockName(m, sub_blocks)) lists_sub_block = true;
    }
    return lists_section and lists_sub_block;
}

fn isSubBlockName(name: []const u8, sub_blocks: []const env_mod.SubBlock) bool {
    for (sub_blocks) |sb| {
        if (std.mem.eql(u8, sb.name, name)) return true;
    }
    return false;
}

/// A `(sub-block …)` form directly following the `(section …)` form is the
/// documented adjacency idiom. Matches the section by its literal string name;
/// a computed `(fmt …)` name falls back to the group rule.
fn creditedByAdjacency(sec_name: []const u8, body_forms: []const Node) bool {
    for (body_forms, 0..) |form, i| {
        if (!form.isForm("section")) continue;
        if (i + 1 >= body_forms.len or !body_forms[i + 1].isForm("sub-block")) continue;
        const children = form.asList() orelse continue;
        if (children.len < 2) continue;
        const name = children[1].asString() orelse continue;
        if (std.mem.eql(u8, name, sec_name)) return true;
    }
    return false;
}

const testing = std.testing;
const sexpr_parser = @import("../sexpr/parser.zig");
const evaluator_mod = @import("evaluator.zig");
const Evaluator = evaluator_mod.Evaluator;

/// One-cap module for the fixtures below — the sealed "implementation".
const test_module_src =
    \\(defmodule mymod ()
    \\  (design-block "Mod"
    \\    (instance "U1" fakeic (pin 1 "VDD") (pin 2 "GND"))))
    \\
;

fn evalFixtureBlock(alloc: std.mem.Allocator, source: []const u8) !*env_mod.DesignBlock {
    const nodes = try sexpr_parser.parse(alloc, source);
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    try eval.component_cache.put(alloc, "fakeic", .{
        .name = "fakeic",
        .symbol_name = "",
        .footprint_name = "",
        .is_family = false,
        .param_type = "",
    });
    var env = env_mod.Env.init(alloc, null);
    defer env.deinit();
    const v = try eval.evalNodes(nodes, &env);
    return switch (v) {
        .design_block => |b| b,
        else => error.TestUnexpectedResult,
    };
}

// spec: eval/design_block - a group naming both a concept section and a sub-block upgrades it to implemented
test "group tying section to sub-block credits the section" {
    const a = std.heap.page_allocator;
    // Sub-block placed BEFORE the section so the adjacency rule can't fire —
    // only the (diagram-layout (group …)) tie credits here.
    const block = try evalFixtureBlock(a, test_module_src ++
        \\(design-block "Top"
        \\  (diagram-layout (group "K-band TX" "ADF4159 PLL" "pll"))
        \\  (sub-block "pll" (mymod))
        \\  (section "ADF4159 PLL" "sealed in module" (port "VDD" in)))
    );
    try testing.expectEqual(@as(usize, 1), block.sections.len);
    try testing.expectEqual(env_mod.SectionStatus.implemented, block.sections[0].status);
}

// spec: eval/design_block - a sub-block form directly after its section upgrades the concept section to implemented
test "sub-block adjacent to its section credits the section" {
    const a = std.heap.page_allocator;
    const block = try evalFixtureBlock(a, test_module_src ++
        \\(design-block "Top"
        \\  (section "USB" "sealed in module" (port "VBUS" in))
        \\  (sub-block "usb" (mymod)))
    );
    try testing.expectEqual(@as(usize, 1), block.sections.len);
    try testing.expectEqual(env_mod.SectionStatus.implemented, block.sections[0].status);
}

// spec: eval/design_block - a concept section with no group tie or adjacent sub-block stays concept
test "unassociated concept section stays concept" {
    const a = std.heap.page_allocator;
    // The design HAS a sub-block, but it precedes the section and no group
    // ties them — an unrelated power block must not credit a real concept.
    const block = try evalFixtureBlock(a, test_module_src ++
        \\(design-block "Top"
        \\  (sub-block "pwr" (mymod))
        \\  (section "Wishful" "future work" (port "VDD" in)))
    );
    try testing.expectEqual(@as(usize, 1), block.sections.len);
    try testing.expectEqual(env_mod.SectionStatus.concept, block.sections[0].status);
}
