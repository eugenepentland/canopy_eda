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

/// The 256 KiB figure five of the `lib/pinouts` readers carried before the cap
/// above owned the class — `render_json.loadPinoutAlts` / `loadPinoutNames`,
/// `serve/api.pinoutApi`, `eval/ids.loadPinoutFile`, and
/// `serve/bom_html.buildSymbolPinCache`. It is named rather than deleted so
/// "raise these, never lower them" is testable instead of only asserted: each
/// of those readers now has a regression test that loads a pinout LARGER than
/// this and expects its pins back, and `max_lib_file_bytes` dropping to or
/// below this figure fails all of them at once. Nothing reads a file at it.
pub const retired_lib_file_cap_bytes: usize = 1024 * 256;

const std = @import("std");

/// Build a synthetic `(pinout "<name>" …)` source strictly larger than
/// `min_bytes`, ending in a `(pin LAST "LASTFN" (alt "SENTINEL" io))` the
/// caller can look for to prove the tail of the file — not just its head —
/// survived the read.
///
/// The sentinel pad is a BARE ATOM, not a quoted string: `bom_html`'s pad
/// reader takes `asAtom()` only, so a quoted sentinel is silently skipped
/// there and the fixture would stop testing the one reader whose failure is a
/// `catch continue`. An atom is the one spelling all five readers accept.
///
/// It lives with the caps rather than in each reader's module because it is a
/// fixture ABOUT the caps: every reader's regression test sizes off
/// `retired_lib_file_cap_bytes` through this one function, so no test can drift
/// to a fixture that no longer straddles the retired figure. Generated at test
/// time rather than committed — a ~260 KB fixture has no business in the tree
/// when the only property under test is its size.
pub fn synthPinoutSource(
    gpa: std.mem.Allocator,
    name: []const u8,
    min_bytes: usize,
) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    const head = try std.fmt.allocPrint(gpa, "(pinout \"{s}\"\n", .{name});
    defer gpa.free(head);
    try out.appendSlice(gpa, head);

    var i: usize = 1;
    while (out.items.len < min_bytes) : (i += 1) {
        const line = try std.fmt.allocPrint(gpa, "  (pin {d} \"PIN{d}\" (alt \"ALT{d}\" io))\n", .{ i, i, i });
        defer gpa.free(line);
        try out.appendSlice(gpa, line);
    }

    try out.appendSlice(gpa, "  (pin LAST \"LASTFN\" (alt \"SENTINEL\" io))\n)\n");
    return out.toOwnedSlice(gpa);
}

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
    // of the 256 KiB the five stale read sites used to carry.
    try std.testing.expect(max_lib_file_bytes > 1000 * 162);
    try std.testing.expect(max_lib_file_bytes > retired_lib_file_cap_bytes);
}

// spec: lib_limits - The shared over-cap pinout fixture is larger than the retired 256 KiB cap and still inside the live class cap
test "the synthetic over-cap pinout straddles the retired cap" {
    const src = try synthPinoutSource(std.testing.allocator, "big", retired_lib_file_cap_bytes + 4096);
    defer std.testing.allocator.free(src);

    // The two bounds every reader's regression test relies on: past the figure
    // the five stale sites carried, still comfortably inside the class cap.
    try std.testing.expect(src.len > retired_lib_file_cap_bytes);
    try std.testing.expect(src.len < max_lib_file_bytes);

    // The sentinel pin is the LAST content in the file, so a reader that finds
    // it read the whole thing rather than stopping short. Its pad is a bare
    // atom because `bom_html` accepts only `asAtom()` pads.
    try std.testing.expect(std.mem.startsWith(u8, src, "(pinout \"big\"\n"));
    try std.testing.expect(std.mem.endsWith(u8, src, "  (pin LAST \"LASTFN\" (alt \"SENTINEL\" io))\n)\n"));
}
