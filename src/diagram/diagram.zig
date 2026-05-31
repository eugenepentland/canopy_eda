//! Umbrella entry for the category-split block diagram. `render_html.zig`
//! calls `renderBlockDiagramTabs` where it used to call the old single
//! hub-and-spoke `renderBlockDiagramSvg`, and concatenates `DIAGRAM_CSS` into
//! the page stylesheet.

const std = @import("std");
const env_mod = @import("../eval/env.zig");
const rb = @import("../render_block_types.zig");
const collect = @import("collect.zig");
const render = @import("render.zig");
const types = @import("types.zig");
const function = @import("function.zig");
const layout = @import("layout.zig");

const DesignBlock = env_mod.DesignBlock;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Build the design's connectivity graph from its netlist and render it as a
/// tabbed (System / Power / Clocks / Control / RF) block diagram. The System
/// tab is the combined connectivity diagram (every block + every inter-block
/// connection, color-coded by class); the rest are the focused per-class
/// views. Emits nothing when the design has neither a block nor an edge.
pub fn renderBlockDiagramTabs(
    allocator: Allocator,
    block: *const DesignBlock,
    sub_attachments: []const ?usize,
    w: *Writer,
) (Allocator.Error || Writer.Error)!void {
    var graph = try collect.collectGraph(allocator, block, sub_attachments);
    defer graph.deinit(allocator);
    // The coarsened Function view ("what does it do") is built off the same
    // graph and prepended as the default tab. Arena-owned (borrows `graph`'s
    // class registry), so it's freed wholesale, never `Graph.deinit`-ed.
    var fn_arena = std.heap.ArenaAllocator.init(allocator);
    defer fn_arena.deinit();
    const fg = try function.buildFunctionGraph(fn_arena.allocator(), block, &graph);
    // The Signal Chain view reuses the Function blocks, ordered by the design's
    // declared narrative stages. Empty (no `(chain …)` declared) ⇒ no such tab.
    const chain = try buildChainStages(fn_arena.allocator(), block);
    try render.renderTabsWithFunction(allocator, &graph, if (fg) |*f| f else null, chain, w);
}

/// One narrative stage being assembled from the design's `(function …)` chain
/// declarations: a position (for ordering), a label, and the member function
/// names that share that position.
const ChainGroup = struct { pos: f64, label: []const u8, members: std.ArrayListUnmanaged([]const u8) };

fn cmpChainPos(_: void, a: ChainGroup, b: ChainGroup) bool {
    return a.pos < b.pos;
}

/// Group the design's `(function … (chain pos "label"))` declarations into
/// ordered Signal-Chain stages: functions sharing a `pos` form one stage,
/// stages sort by `pos`, the first non-empty `label` names each. Returns an
/// empty slice when no function declares a chain position (⇒ no Signal Chain tab).
fn buildChainStages(arena: Allocator, block: *const DesignBlock) Allocator.Error![]layout.StageSpec {
    var groups: std.ArrayListUnmanaged(ChainGroup) = .empty;
    for (block.functions) |f| {
        if (f.chain_pos < 0) continue;
        var existing: ?*ChainGroup = null;
        for (groups.items) |*cand| {
            if (@abs(cand.pos - f.chain_pos) < 0.001) {
                existing = cand;
                break;
            }
        }
        if (existing) |g| {
            try g.members.append(arena, f.name);
            if (g.label.len == 0) g.label = f.chain_label;
        } else {
            var members: std.ArrayListUnmanaged([]const u8) = .empty;
            try members.append(arena, f.name);
            try groups.append(arena, .{ .pos = f.chain_pos, .label = f.chain_label, .members = members });
        }
    }
    std.sort.block(ChainGroup, groups.items, {}, cmpChainPos);
    const out = try arena.alloc(layout.StageSpec, groups.items.len);
    for (groups.items, 0..) |g, i| out[i] = .{ .label = g.label, .members = g.members.items };
    return out;
}

/// Render the combined System block diagram as a standalone inline SVG — the
/// static, non-interactive form used by the markdown/zip export (which can't
/// host the page's tab toggles). Falls back to a single synthetic box for a
/// flat design with no sections or sub-blocks, mirroring the page's
/// `#sec-design` card.
pub fn renderSystemSvg(
    allocator: Allocator,
    block: *const DesignBlock,
    sub_attachments: []const ?usize,
    w: *Writer,
) (Allocator.Error || Writer.Error)!void {
    var graph = try collect.collectGraph(allocator, block, sub_attachments);
    defer graph.deinit(allocator);
    if (try render.renderSystemStandalone(allocator, &graph, w)) return;

    // Nothing connected (a flat top-level-hub design): synthesise one box from
    // the design name so the diagram isn't empty.
    if (!hasTopLevelHub(block)) return;
    var syn = [_]types.Node{.{
        .label = block.name,
        .subtitle = "",
        .category = rb.classifyByName(block.name, block.instances),
        .slug = "design",
        .inputs = &.{},
        .outputs = &.{},
    }};
    var syn_graph = types.Graph{ .nodes = &syn, .edges = &.{} };
    _ = try render.renderSystemStandalone(allocator, &syn_graph, w);
}

/// A design has a "hub" worth a synthetic system box when it places at least
/// one non-passive top-level instance (ref-des outside the R/C/L/D/F passives).
fn hasTopLevelHub(block: *const DesignBlock) bool {
    for (block.instances) |inst| {
        if (inst.ref_des.len == 0) continue;
        switch (inst.ref_des[0]) {
            'R', 'C', 'L', 'D', 'F' => continue,
            else => return true,
        }
    }
    return false;
}

/// CSS fragment for the diagram, embedded into the schematic page stylesheet
/// and the markdown export's `<style>` block (the System view reuses the
/// signal-view node/edge/legend CSS).
pub const DIAGRAM_CSS = render.CSS;

test {
    std.testing.refAllDecls(@This());
    _ = collect;
    _ = render;
    _ = function;
    _ = @import("types.zig");
    _ = @import("classify.zig");
    _ = @import("membership.zig");
    _ = @import("layout.zig");
}
