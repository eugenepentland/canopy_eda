//! The board's CANONICAL PAINT ORDER — one ordered list of named stages that
//! every board renderer paints in, bottom of the stack first.
//!
//! Three surfaces draw the same board: the `/pcb-layout` viewer's Canvas2D
//! scene (`serve/assets/pcb_board.js`), the WebGPU under-layer beneath it
//! (`serve/assets/pcb_gpu.js`), and the server-side PNG a CLI agent looks at
//! (`render_pcb_png.zig`). They used to hold three hand-maintained call
//! sequences, and they had drifted: silk under copper on two of them and above
//! it on the third, an outline painted first here and last there, whole classes
//! of copper (inner planes, inner pours, true arcs) that only one of them drew.
//! A picture an agent reasons about must be the picture the user sees, so the
//! order is stated ONCE here and each surface is driven from it:
//!
//!   * `pcb_board.js` mirrors this list as `PAINT_STAGES` and iterates it —
//!     for the quiet frame and for both halves of each drag split — instead of
//!     repeating the sequence per code path. `renderOrderTest` below re-reads
//!     that array out of the shipped asset text and fails when it disagrees
//!     with this one, which is the only cross-language check available (JS
//!     cannot import Zig).
//!   * `pcb_gpu.js` receives the same list per frame inside its policy blob
//!     and dispatches its own passes by stage name, so the GPU's draw order is
//!     handed to it rather than restated.
//!   * `render_pcb_png.zig` walks a stage table keyed by this enum; a stage it
//!     has no model for is an explicit hole in that table, never a silent gap.
//!
//! ## GPU ownership
//!
//! Under `?gpu=1` the WebGPU canvas sits UNDER the 2D one and draws the bulk
//! geometry of four stages. `Gpu.all` means the 2D pass is skipped whole;
//! `Gpu.fill` means the GPU drew the stage's bulk (pour fills, pad copper,
//! track/via bodies) and the 2D pass still runs for the adornments the GPU has
//! no pipeline for (rims, labels, highlight overdraws, selection fringes). That
//! policy is data here, so a NEW stage cannot inherit a remembered `if`.
//!
//! ## Assembly review
//!
//! The viewer's read-only assembly review (`PHYSICAL_REVIEW`) draws opaque
//! package bodies over the board, so copper and silk must pass UNDER the part
//! bodies rather than over them. That is the one deviation, and it is data too:
//! `review` is each stage's rank in that mode's sequence, a permutation of the
//! canonical ranks. Every other consumer uses the canonical order.
//!
//! ## Residual divergences from KiCad, deliberately preserved
//!
//! KiCad paints pads ABOVE tracks, which is also the only safe physical-review
//! order: an ordinary masked trace may begin inside a land, but its green
//! under-mask wash must never cover the land's exposed-copper rendering. All
//! three surfaces now agree on that order. Courtyards still sit below copper;
//! the ratsnest and clearance halos likewise sit under copper.

const std = @import("std");

/// How much of a stage's content the WebGPU under-layer draws for itself.
pub const Gpu = enum {
    /// 2D owns the stage entirely; the GPU has no pipeline for it.
    none,
    /// The GPU drew the stage's bulk geometry; the 2D pass still runs and
    /// skips only that bulk (see `gpuOwns` in `pcb_board.js`).
    fill,
    /// The GPU drew all of it; the 2D pass is skipped whole on a GPU frame.
    all,

    /// The spelling `pcb_board.js` / `pcb_gpu.js` use for this policy.
    pub fn word(self: Gpu) []const u8 {
        return switch (self) {
            .none => "",
            .fill => "fill",
            .all => "all",
        };
    }
};

/// One named stage of the paint stack.
pub const Stage = struct {
    /// Wire name, shared verbatim with `PAINT_STAGES` and the PNG stage table.
    name: []const u8,
    /// What this stage puts on the board.
    what: []const u8,
    /// How much of it the WebGPU under-layer owns.
    gpu: Gpu = .none,
    /// This stage's rank in the assembly review's sequence (see above).
    review: u8,
};

/// THE ORDER. Index 0 paints first (deepest); the last entry paints last and
/// therefore wins every overlap.
pub const stages = [_]Stage{
    .{
        .name = "substrate",
        .what = "board substrate wash and the reference grid",
        .gpu = .all,
        .review = 0,
    },
    .{
        .name = "plane_fills",
        .what = "plane and copper-pour fills, deepest copper layer upward",
        .gpu = .fill,
        .review = 1,
    },
    .{
        .name = "keepouts",
        .what = "keepout washes and their rims",
        .review = 2,
    },
    .{
        .name = "groups",
        .what = "sub-circuit group boxes",
        .review = 8,
    },
    .{
        .name = "ratsnest",
        .what = "airwires, decoupling loops and placement guides",
        .review = 3,
    },
    .{
        .name = "clearance",
        .what = "clearance halos around copper",
        .review = 4,
    },
    .{
        .name = "copper",
        .what = "routed tracks and arcs by layer (active layer last), then via barrels and their bores",
        .gpu = .fill,
        .review = 5,
    },
    .{
        .name = "parts",
        .what = "part bodies: courtyard, pad copper and drilled bores",
        .gpu = .fill,
        .review = 7,
    },
    .{
        .name = "pad_labels",
        .what = "pad and pin-number labels, above the copper that crosses them",
        .review = 9,
    },
    .{
        .name = "footprint_silk",
        .what = "footprint silkscreen, B side then F side",
        .review = 6,
    },
    .{
        .name = "board_silk",
        .what = "side-specific F./B.Silkscreen text and generated sub-circuit / test-point ink",
        .review = 10,
    },
    .{
        .name = "edge_cuts",
        .what = "the board outline and its dimensions",
        .review = 11,
    },
    .{
        .name = "overlays",
        .what = "antipads, DRC markers, selection and focus, panels",
        .review = 12,
    },
};

/// Position of `name` in the canonical order, or null when nothing is called
/// that.
pub fn indexOf(name: []const u8) ?usize {
    for (stages, 0..) |s, i| {
        if (std.mem.eql(u8, s.name, name)) return i;
    }
    return null;
}

// spec: Web Server - one canonical stage list names the board paint order for every renderer
test "the canonical order is a named sequence with a review permutation" {
    // Names are unique and non-empty (they are the join key between the three
    // renderers, so a duplicate would silently merge two stages), and the
    // review ranks are a permutation of 0..n-1 — the deviation reorders the
    // sequence, it never drops or duplicates a stage.
    var seen: [stages.len]bool = @splat(false);
    for (stages, 0..) |s, i| {
        try std.testing.expect(s.name.len > 0);
        try std.testing.expectEqual(i, indexOf(s.name).?);
        try std.testing.expect(s.review < stages.len);
        try std.testing.expect(!seen[s.review]);
        seen[s.review] = true;
    }
    // Pads and package bodies win over routed copper everywhere. In physical
    // review that also prevents an under-mask trace wash from visually coating
    // the exposed land where the route begins or ends.
    const copper = stages[indexOf("copper").?];
    const silk = stages[indexOf("footprint_silk").?];
    const parts = stages[indexOf("parts").?];
    try std.testing.expect(indexOf("copper").? < indexOf("parts").?);
    try std.testing.expect(copper.review < silk.review);
    try std.testing.expect(silk.review < parts.review);
    // …and in the canonical order silk is above copper on every surface.
    try std.testing.expect(indexOf("copper").? < indexOf("footprint_silk").?);
}

// spec: Web Server - every board renderer paints exposed pad copper above routed traces, so a normally masked trace entering a land cannot visually coat that component pad with solder mask
test "component lands paint above masked routed copper" {
    try std.testing.expect(indexOf("copper").? < indexOf("parts").?);
}

// spec: Web Server - the viewer's paint stages mirror the canonical order name for name
test "PAINT_STAGES in the viewer asset is this list, in this order" {
    const js = @embedFile("serve/assets/pcb_board.js");
    const open = "var PAINT_STAGES=[";
    const start = std.mem.indexOf(u8, js, open) orelse return error.NoPaintStages;
    const body_start = start + open.len;
    const end = std.mem.indexOfPos(u8, js, body_start, "\n];") orelse return error.UnterminatedPaintStages;
    const body = js[body_start..end];

    // Every stage spells its name, GPU policy and review rank in this fixed
    // head, so the mirror is checkable by substring rather than by parsing JS.
    var at: usize = 0;
    for (stages) |s| {
        var head: [96]u8 = undefined;
        const want = try std.fmt.bufPrint(&head, "{{n:\"{s}\",gpu:\"{s}\",rv:{d},", .{ s.name, s.gpu.word(), s.review });
        const pos = std.mem.indexOfPos(u8, body, at, want) orelse {
            std.debug.print("viewer PAINT_STAGES is missing (or misorders) `{s}`\n", .{want});
            return error.StageMissing;
        };
        at = pos + want.len;
    }
    // …and carries no stage this list does not name.
    try std.testing.expectEqual(stages.len, std.mem.count(u8, body, "{n:\""));
}
