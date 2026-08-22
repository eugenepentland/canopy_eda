//! Board-state types: one footprint as it exists on a user's `.kicad_pcb`.
//!
//! `kicad_pcb/reader.zig` FILLS these in straight off the on-disk board, and
//! `serve/sync.zig` DIFFS them against the design's flattened netlist. They
//! were declared in the diff engine, so the reader — the file-format layer —
//! had to import `serve/` to name its own return type, an inversion that also
//! closed a real cycle (`sync.zig` imports the reader right back to call it).
//!
//! Declaring them here puts them beneath both: the format layer owns the shape
//! of a board footprint, and the server reaches DOWN for it. Nothing here reads
//! or writes anything — the module is two plain data structs over `std` — so
//! neither side pulls in the other. `serve/sync.zig` re-exports both names.

const std = @import("std");

/// One (pad number, net name) assignment on a KiCad board footprint —
/// the granularity the diff loop compares against the design's flattened
/// netlist when deciding whether to emit a set_pad_net op.
pub const PadAssign = struct { number: []const u8, net: []const u8 };

/// Snapshot of one footprint as it exists on the user's `.kicad_pcb`, built by
/// the file-based reader directly from the on-disk board.
pub const BoardFp = struct {
    /// Project-stable canopy_uuid custom field. Empty when the footprint
    /// has never been synced (or was placed manually in KiCad).
    uuid: []const u8,
    /// KiCad-internal handle. Always populated. Echoed back in emitted ops so
    /// the file writer can target the right footprint regardless of whether
    /// canopy_uuid is set yet.
    kicad_uuid: []const u8,
    ref: []const u8,
    value: []const u8,
    footprint_name: []const u8,
    /// Every custom Field on the KiCad footprint, keyed by name. The reader
    /// captures the full map so the server can diff arbitrary design properties
    /// (mpn, manufacturer, datasheet, …).
    fields: std.StringHashMapUnmanaged([]const u8),
    pads: []const PadAssign,
    /// The current `(model …)` 3D-model placement on the board, parsed from
    /// `(offset (xyz …))` / `(rotate (xyz …))`. Lets the diff detect when a
    /// footprint's model orientation drifted from `model-config.json` and
    /// re-bake just that part (the 3D-alignment workflow), instead of either
    /// re-baking every part (`?refresh=1`) or never updating placed models.
    /// `has_model` is false when the board footprint carries no `(model …)`.
    has_model: bool = false,
    model_offset: [3]f64 = .{ 0, 0, 0 },
    model_rotate: [3]f64 = .{ 0, 0, 0 },
};
