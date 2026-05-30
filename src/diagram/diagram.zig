//! Umbrella entry for the category-split block diagram. `render_html.zig`
//! calls `renderBlockDiagramTabs` where it used to call the old single
//! hub-and-spoke `renderBlockDiagramSvg`, and concatenates `DIAGRAM_CSS` into
//! the page stylesheet.

const std = @import("std");
const env_mod = @import("../eval/env.zig");
const rb = @import("../render_block_types.zig");
const collect = @import("collect.zig");
const render = @import("render.zig");
const overview = @import("overview.zig");
const types = @import("types.zig");

const DesignBlock = env_mod.DesignBlock;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Build the design's connectivity graph from its netlist and render it as a
/// tabbed (Overview / Power / Clocks / Control / RF) block diagram. The
/// Overview tab is the category-grouped system silhouette; the rest are the
/// signal views. Emits nothing when the design has neither a block nor an edge.
pub fn renderBlockDiagramTabs(
    allocator: Allocator,
    block: *const DesignBlock,
    sub_attachments: []const ?usize,
    w: *Writer,
) (Allocator.Error || Writer.Error)!void {
    var graph = try collect.collectGraph(allocator, block, sub_attachments);
    defer graph.deinit(allocator);
    try render.renderTabs(allocator, &graph, w);
}

/// Render *only* the system-overview silhouette as a standalone inline SVG —
/// the static, non-interactive form used by the markdown/zip export (which
/// can't host the page's tab toggles). Falls back to a single synthetic chip
/// for a flat design with no sections or sub-blocks, mirroring the page's
/// `#sec-design` card.
pub fn renderOverviewSvg(
    allocator: Allocator,
    block: *const DesignBlock,
    sub_attachments: []const ?usize,
    w: *Writer,
) (Allocator.Error || Writer.Error)!void {
    var graph = try collect.collectGraph(allocator, block, sub_attachments);
    defer graph.deinit(allocator);
    if (try overview.renderStandaloneSvg(allocator, w, &graph)) return;

    // No real block in the graph (a flat top-level-hub design): synthesise one
    // chip from the design name so the silhouette isn't empty.
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
    _ = try overview.renderStandaloneSvg(allocator, w, &syn_graph);
}

/// A design has a "hub" worth a synthetic overview chip when it places at least
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

/// CSS fragment for the diagram, embedded into the schematic page stylesheet.
/// Bundles the signal-view CSS with the overview chip/column CSS.
pub const DIAGRAM_CSS = render.CSS ++ "\n" ++ overview.CSS;

/// The overview-only CSS subset, for the markdown export's `<style>` block.
pub const OVERVIEW_CSS = overview.CSS;

test {
    std.testing.refAllDecls(@This());
    _ = collect;
    _ = render;
    _ = overview;
    _ = @import("types.zig");
    _ = @import("classify.zig");
    _ = @import("membership.zig");
    _ = @import("layout.zig");
}
