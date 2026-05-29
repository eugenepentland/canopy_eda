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

/// Identifier for a signal class. The first `builtin_classes.len` ids are the
/// built-ins (stable, named below); a design that declares a novel
/// `(class <key>)` on a port gets a fresh id appended to its per-design
/// registry — that is how a brand-new circuit gets its own view with no code
/// change. A class is also a *view* unless it is a reference class (ground).
pub const ClassId = u8;
pub const CLASS_GROUND: ClassId = 0;
pub const CLASS_POWER: ClassId = 1;
pub const CLASS_CLOCK: ClassId = 2;
pub const CLASS_CONTROL: ClassId = 3;
pub const CLASS_RF: ClassId = 4;

/// Metadata for one signal class: its source key, the tab label, the edge
/// accent color, and whether it is a reference (drawn as a shared node, never
/// as edges — so it gets no view/tab). `key`/`label`/`color` are borrowed
/// slices (string literals for built-ins, source slices for declared keys),
/// so no `ClassDef` needs freeing.
pub const ClassDef = struct {
    key: []const u8,
    label: []const u8,
    color: []const u8,
    is_reference: bool = false,
};

/// Built-in classes, indexed by the `CLASS_*` ids above. A design's registry
/// (`Graph.classes`) starts from these and appends any novel declared keys.
/// `ground` is a reference class: GND touches every block, so drawing it would
/// produce an unreadable clique — it is a shared reference, not edges.
pub const builtin_classes = [_]ClassDef{
    .{ .key = "ground", .label = "Ground", .color = "#6e7681", .is_reference = true },
    .{ .key = "power", .label = "Power", .color = "#da3633" },
    .{ .key = "clock", .label = "Clocks", .color = "#4ab3a3" },
    .{ .key = "control", .label = "Control", .color = "#388bfd" },
    .{ .key = "rf", .label = "RF / Analog", .color = "#e040fb" },
};

/// Accent colors cycled for designer-declared classes that aren't built-ins.
pub const discovered_palette = [_][]const u8{
    "#ff8800", "#00b894", "#a29bfe", "#fdcb6e", "#fd79a8", "#55efc4",
};

/// Find a class id by key in a registry, or null if absent.
pub fn findClass(classes: []const ClassDef, key: []const u8) ?ClassId {
    for (classes, 0..) |c, i| {
        if (std.mem.eql(u8, c.key, key)) return @intCast(i);
    }
    return null;
}

/// 2-D point for routed-edge polylines.
pub const Pt = struct { x: f64, y: f64 };

/// One end of a power rail: net name and (optional) voltage. Mirrors the field
/// the old hub-diagram used so the Power view can keep showing in-box V tags.
/// `v_lo` is set only for a *programmable* rail declared with a `(rated lo hi)`
/// span where `lo != voltage`; the producer card then shows "lo–voltage V"
/// (e.g. a DUT bank rail's "1.8–3.3 V") instead of a single figure.
pub const RailEnd = struct {
    net: []const u8,
    voltage: ?f64 = null,
    v_lo: ?f64 = null,
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
    /// True for a synthesised board-edge endpoint (antenna / EMVS cell) rather
    /// than a real on-board block. Rendered with a dashed border; its `label`
    /// is owned and freed by `Graph.deinit`.
    is_boundary: bool = false,
};

/// A directed inter-block connection. `from` is the driver/producer side so
/// the layout can rank by signal flow and the renderer can draw an arrowhead.
/// `label` is an *owned* slice (the derived bus/net name): net names are built
/// in a scratch arena during collection, so the surviving label is duped into
/// the caller's allocator and freed by `Graph.deinit`.
pub const Edge = struct {
    from: u32,
    to: u32,
    class: ClassId,
    label: []const u8,
    voltage: ?f64 = null,
    /// Number of parallel nets this edge stands in for after differential-pair
    /// and same-endpoint collapse (e.g. ADF_CH1P+ADF_CH1N → 1 edge, fanout 2).
    fanout: u16 = 1,
};

/// Owned node + edge lists for a whole design, plus the per-design class
/// registry (`classes`, indexed by `ClassId`). Views are produced by filtering
/// `edges` on `class`. Caller must call `deinit`.
pub const Graph = struct {
    nodes: []Node,
    edges: []Edge,
    /// Class registry: `builtin_classes` plus any designer-declared keys. The
    /// slice is owned (allocated by `collect`); the `ClassDef` fields inside
    /// are borrowed, so only the slice itself is freed.
    classes: []const ClassDef = &builtin_classes,

    pub fn deinit(self: *Graph, allocator: Allocator) void {
        for (self.nodes) |n| {
            allocator.free(n.inputs);
            allocator.free(n.outputs);
            if (n.rails.len > 0) allocator.free(n.rails);
            if (n.slug.len > 0) allocator.free(n.slug);
            if (n.is_boundary and n.label.len > 0) allocator.free(n.label);
        }
        allocator.free(self.nodes);
        for (self.edges) |e| allocator.free(e.label);
        allocator.free(self.edges);
        // Free the registry only when it isn't the static built-in array.
        const builtin_ptr: [*]const ClassDef = &builtin_classes;
        if (self.classes.ptr != builtin_ptr) allocator.free(self.classes);
    }

    /// True when at least one edge carries class `id`.
    pub fn classHasEdge(self: *const Graph, id: ClassId) bool {
        for (self.edges) |e| {
            if (e.class == id) return true;
        }
        return false;
    }

    /// True when class `id` should render as a view: it is not a reference
    /// class and at least one edge carries it.
    pub fn isView(self: *const Graph, id: ClassId) bool {
        return id < self.classes.len and !self.classes[id].is_reference and self.classHasEdge(id);
    }
};
