//! The routed-copper bundle: what a layout persisted after routing, as data.
//!
//! The router PRODUCES this; the Gerber writer, the connectivity oracle and the
//! DRC all CONSUME it. It was declared in `export_gerber.zig` for want of a
//! neutral home, which made every `src/placement/*` module that measures its own
//! routed copper import the Gerber writer and reach UP a layer — the edge
//! `guardian.toml`'s `[[boundary]]` rule freezes.
//!
//! Nothing here draws or serializes anything: the module is a struct of slices
//! over types placement already owns, so it sits beneath both the layer that
//! fills it in and the layers that render it. `export_gerber.zig` re-exports
//! `Copper`, so callers in the export and serve layers keep their spelling.
//!
//! `pour.Copper` stays a separate fill-input mirror. It cannot be this type:
//! `Copper` names `pour.UserZone`, so this module imports `pour.zig` and `pour`
//! importing it back would be a cycle — which is exactly what that mirror's own
//! comment says it exists to avoid.

const std = @import("std");
const router = @import("router.zig");
const rf_port_report = @import("rf_port_report.zig");
const pour = @import("pour.zig");
const subcircuit_silkscreen = @import("../subcircuit_silkscreen.zig");

/// The routed copper a layout persisted — what the signal layers draw. `zones`
/// are hand-drawn user copper pours (any routable signal layer, outer face or
/// plane-free inner): each emits its carved margin-field fill on its layer,
/// exactly like a declared plane pour, so a user-drawn pour ships as real Gerber
/// copper. An outer zone lands on its face via `writeCopper`, an inner zone
/// (`UserZone.layer` ≥ 2) on its signal layer via `writeInnerCopper`.
pub const Copper = struct {
    tracks: []const router.Track = &.{},
    /// Exact curves corresponding to selected chord runs in `tracks`.
    arcs: []const router.Arc = &.{},
    /// Successful variable-width RF paths, swept as one copper region each.
    rf_paths: []const rf_port_report.Outcome = &.{},
    vias: []const router.Via = &.{},
    zones: []const pour.UserZone = &.{},
    /// Saved/imported polygons where generated board silkscreen is forbidden.
    silk_keepouts: []const subcircuit_silkscreen.Keepout = &.{},
};

// spec: export_gerber - Declares the routed-copper bundle in a neutral module beneath both the placement and export layers

test "an empty routed-copper bundle carries no copper of any kind" {
    // Every field defaults empty, so a caller that only persisted tracks may
    // omit the rest — the spelling the DRC, connectivity and Gerber callers all
    // rely on.
    const empty: Copper = .{};
    try std.testing.expectEqual(@as(usize, 0), empty.tracks.len);
    try std.testing.expectEqual(@as(usize, 0), empty.arcs.len);
    try std.testing.expectEqual(@as(usize, 0), empty.rf_paths.len);
    try std.testing.expectEqual(@as(usize, 0), empty.vias.len);
    try std.testing.expectEqual(@as(usize, 0), empty.zones.len);
    try std.testing.expectEqual(@as(usize, 0), empty.silk_keepouts.len);
}
