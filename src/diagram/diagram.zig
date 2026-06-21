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

const DesignBlock = env_mod.DesignBlock;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Build the design's connectivity graph from its netlist and render it as a
/// tabbed block diagram: the author-placed **Layout** leads when one exists
/// (`(layout …)`), otherwise the combined **System** overview leads as the
/// fallback, each followed by the focused per-class views (Power / Clocks /
/// Control). Emits nothing when the design has neither a block nor an edge.
pub fn renderBlockDiagramTabs(
    allocator: Allocator,
    block: *const DesignBlock,
    sub_attachments: []const ?usize,
    /// Project root, for deriving each chip's `layout` maturity stage from the
    /// sub-modules' `.layouts.json` sidecars (empty ⇒ chips cap at `schematic`).
    project_dir: []const u8,
    w: *Writer,
) (Allocator.Error || Writer.Error)!void {
    var graph = try collect.collectGraph(allocator, block, sub_attachments, project_dir);
    defer graph.deinit(allocator);
    try render.renderTabs(allocator, &graph, w);
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
    project_dir: []const u8,
    w: *Writer,
) (Allocator.Error || Writer.Error)!void {
    var graph = try collect.collectGraph(allocator, block, sub_attachments, project_dir);
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
    _ = @import("types.zig");
    _ = @import("classify.zig");
    _ = @import("membership.zig");
    _ = @import("layout.zig");
}
