//! Shared types for the category-split block diagram.
//!
//! The diagram is split into four *views* (Power, Clocks, Control, RF). Every
//! inter-block connection is derived from the flattened netlist and tagged with
//! a `NetClass`; each view renders only the edges whose class maps to it.
//!
//! Two orthogonal axes:
//!   - `rb.Category` (from render_block_types.zig) is the *node* identity/color
//!     axis — what a block *is* (mcu, power, sensor …).
//!   - `NetClass` here is the *edge* axis — what a connection *carries*. A
//!     power-regulator node can still source a control net to an expander.

const std = @import("std");
const rb = @import("../render_block_types.zig");
const Allocator = std.mem.Allocator;

/// A diagram tab. Declaration order is the tab order on the page.
pub const View = enum { power, clocks, control, rf };

/// Human label for a view's tab.
pub fn viewLabel(v: View) []const u8 {
    return switch (v) {
        .power => "Power",
        .clocks => "Clocks",
        .control => "Control",
        .rf => "RF / Analog",
    };
}

/// Stable element id for a view's radio (one diagram per page → static ids).
pub fn viewId(v: View) []const u8 {
    return switch (v) {
        .power => "dg-tab-power",
        .clocks => "dg-tab-clocks",
        .control => "dg-tab-control",
        .rf => "dg-tab-rf",
    };
}

/// Short class-suffix slug for a view (`dg-panel-<slug>`, `dg-tab-<slug>`).
pub fn viewSlug(v: View) []const u8 {
    return switch (v) {
        .power => "power",
        .clocks => "clocks",
        .control => "control",
        .rf => "rf",
    };
}

/// Edge/accent color for a view.
pub fn viewColor(v: View) []const u8 {
    return switch (v) {
        .power => "#da3633",
        .clocks => "#4ab3a3",
        .control => "#2196f3",
        .rf => "#e040fb",
    };
}

/// Classification of a net, deciding which view (if any) its edges appear in.
/// `ground` maps to no view — GND touches every block, so drawing it would
/// produce an unreadable clique; it is surfaced as a shared reference, not edges.
pub const NetClass = enum { ground, power, clock, control, rf };

/// Which view a class routes to, or null when the class draws no edges.
pub fn viewOf(c: NetClass) ?View {
    return switch (c) {
        .ground => null,
        .power => .power,
        .clock => .clocks,
        .control => .control,
        .rf => .rf,
    };
}

/// 2-D point for routed-edge polylines.
pub const Pt = struct { x: f64, y: f64 };

/// One end of a power rail: net name and (optional) voltage. Mirrors the field
/// the old hub-diagram used so the Power view can keep showing in-box V tags.
pub const RailEnd = struct {
    net: []const u8,
    voltage: ?f64 = null,
};

/// One block in the diagram — one per `(section …)` and one per unattached
/// `(sub-block …)`. `label`/`subtitle` are unowned slices into the source
/// DesignBlock; `slug` is allocated by `review.slugify`; `inputs`/`outputs`
/// are owned slices.
pub const Node = struct {
    label: []const u8,
    subtitle: []const u8,
    category: rb.Category,
    /// On-page anchor slug — empty when the node has no card to link to.
    slug: []const u8,
    inputs: []RailEnd,
    outputs: []RailEnd,
    /// Primary supply rail (volts): the rail powering the most of this block's
    /// pins, used to group it into the power view's voltage band. -1 ⇒ unset
    /// (the layout falls back to declared ports / edges).
    power_rail: f64 = -1,
    /// All distinct supply rails (volts) this block uses, ascending. Lets the
    /// power view place a dual-rail part in the overlap of two bands. Owned;
    /// freed by `Graph.deinit`. Empty ⇒ unknown.
    rails: []const f64 = &.{},
};

/// A directed inter-block connection. `from` is the driver/producer side so
/// the layout can rank by signal flow and the renderer can draw an arrowhead.
/// `label` is an *owned* slice (the derived bus/net name): net names are built
/// in a scratch arena during collection, so the surviving label is duped into
/// the caller's allocator and freed by `Graph.deinit`.
pub const Edge = struct {
    from: u32,
    to: u32,
    class: NetClass,
    label: []const u8,
    voltage: ?f64 = null,
    /// Number of parallel nets this edge stands in for after differential-pair
    /// and same-endpoint collapse (e.g. ADF_CH1P+ADF_CH1N → 1 edge, fanout 2).
    fanout: u16 = 1,
};

/// Owned node + edge lists for a whole design. Views are produced by filtering
/// `edges` on `class`. Caller must call `deinit`.
pub const Graph = struct {
    nodes: []Node,
    edges: []Edge,

    pub fn deinit(self: *Graph, allocator: Allocator) void {
        for (self.nodes) |n| {
            allocator.free(n.inputs);
            allocator.free(n.outputs);
            if (n.rails.len > 0) allocator.free(n.rails);
            if (n.slug.len > 0) allocator.free(n.slug);
        }
        allocator.free(self.nodes);
        for (self.edges) |e| allocator.free(e.label);
        allocator.free(self.edges);
    }

    /// True when at least one edge routes to `view`.
    pub fn hasView(self: *const Graph, view: View) bool {
        for (self.edges) |e| {
            if (viewOf(e.class)) |v| {
                if (v == view) return true;
            }
        }
        return false;
    }
};
