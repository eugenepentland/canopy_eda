//! Which net does a `(pad …)`'s `(net …)` sub-form name?
//!
//! KiCad writes two shapes and netlisp must read both:
//!
//!   * `(net <id> "<name>")` — the canonical form. Slot 1 is an integer index
//!     into the file's top-level net table, and the quoted name beside it is a
//!     convenience copy.
//!   * `(net "<name>")` — name only, no table. Older netlisp-written boards are
//!     stored this way, and a reader that handles only the canonical form
//!     reports every pad on such a board as disconnected.
//!
//! Two importers resolve this — the schematic-side `import_kicad` and the
//! board-sync `kicad_pcb/reader` — and each used to carry its own copy of the
//! two-shape rule. A copy that learns only one shape is not a parse error; it
//! is a board that silently reads as unwired.

const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const numeric = @import("../numeric.zig");

/// The net named by one `(net …)` sub-form, or null when the form is malformed
/// or its id is not in `net_table`. The result borrows the source text (or the
/// table's own strings), so it lives as long as the parsed board.
pub fn nameOf(
    form: ast.Node,
    net_table: *const std.AutoHashMapUnmanaged(i64, []const u8),
) ?[]const u8 {
    const list = form.asList() orelse return null;
    if (list.len < 2) return null;
    if (list[1].asNumber()) |id| {
        return net_table.get(numeric.checkedInt(i64, id) orelse return null);
    }
    return list[1].asString();
}
