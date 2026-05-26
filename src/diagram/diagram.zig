//! Umbrella entry for the category-split block diagram. `render_html.zig`
//! calls `renderBlockDiagramTabs` where it used to call the old single
//! hub-and-spoke `renderBlockDiagramSvg`, and concatenates `DIAGRAM_CSS` into
//! the page stylesheet.

const std = @import("std");
const env_mod = @import("../eval/env.zig");
const collect = @import("collect.zig");
const render = @import("render.zig");

const DesignBlock = env_mod.DesignBlock;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Build the design's connectivity graph from its netlist and render it as a
/// tabbed (Power / Clocks / Control / RF) block diagram. Emits nothing when no
/// view has any inter-block connection.
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

/// CSS fragment for the diagram, embedded into the schematic page stylesheet.
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
