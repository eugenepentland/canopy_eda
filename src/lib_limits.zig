//! Read caps for netlisp's own `lib/` source files.
//!
//! A cap here is a property of the FILE CLASS, not of whichever module happens
//! to open it, so every reader of a class shares the one figure below. Spelling
//! it per-reader has produced a real defect twice: a footprint that loaded in
//! the editor at 1 MiB was refused by the preview at 256 KiB, and the same
//! split left two of the pinout readers at 256 KiB while the rest read 1 MiB.
//! That is worse than it sounds because an over-cap read is SWALLOWED at nearly
//! every site (`catch continue` / `catch return null` / `catch return false`) —
//! the part goes quietly missing from a page, a BOM row or a pin-name map
//! instead of erroring. `divergent-const` guards a name held at two values; a
//! single owner removes the chance to disagree at all.
//!
//! Raise these, never lower them. Both classes live under the trusted local
//! project directory and neither is an upload seam, so they are sizing figures
//! rather than a defense against hostile input — the cost of headroom is one
//! rejected read that should have succeeded, and the cost of a tight cap is a
//! silent omission.

/// Cap on a `lib/footprints/<name>.sexp` read. One figure across every reader
/// of that file (the largest in-tree footprint is ~17 KB, so this is ~60x
/// headroom); a preview must not refuse a footprint the editor happily loads.
pub const max_footprint_bytes: usize = 1024 * 1024;

/// Cap on a netlisp `lib/<dir>/<name>.sexp` read (components / pinouts /
/// modules) - one figure across every reader of that class. The largest
/// in-tree pinout is ~36 KB at ~162 B/pin, so even a 1000-pin BGA stays far
/// inside this; the old 256 KiB was only ~7x that worst case.
pub const max_lib_file_bytes: usize = 1024 * 1024;

const std = @import("std");

// spec: lib_limits - Both lib/ read caps clear the largest part this tree targets, so neither may be lowered back under its worst case
test "lib read caps clear their worst-case part" {
    // The sizing evidence the figures were picked against, restated so a future
    // edit that lowers either one fails here instead of in production. Both
    // classes are read behind `catch continue` / `catch return null` / `catch
    // return false`, so a cap that a real part exceeds does not error — the
    // part goes quietly missing.

    // Largest footprint in the tree today, with room for something bigger.
    try std.testing.expect(max_footprint_bytes > 17 * 1024);

    // A 1000-pin BGA pinout at the measured ~162 B/pin. This is the figure that
    // made the raise necessary rather than cosmetic: it lands near 160 KB, 62%
    // of the 256 KiB four of these readers used to carry.
    try std.testing.expect(max_lib_file_bytes > 1000 * 162);
}
