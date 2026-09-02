//! Authored `(board … (keepout "NAME" (rect …) (side …) …))` regions, lifted
//! from board-local millimetres into the world frame and reduced to the four
//! questions every consumer asks:
//!
//!   • Does this board declare any region at all? (`anyDeclared` — the
//!     early-out that keeps a board without one byte-identical and free.)
//!   • Where is region R in world coordinates? (`resolve` / `Region.corners`.)
//!   • Does R apply to this board face? (`Region.coversSide`.)
//!   • Does R admit this copper anyway? (`Region.allowsNet`.)
//!
//! The placer (`optimizer.overlapsAny` and the force solve's guidance hinge),
//! the DRC rule (`drc_board_keepout.zig`), the `/pcb-layout` blob, the PNG and
//! `/api/pcb-describe` all read the regions from here, so the rectangle a
//! reader is shown is by construction the rectangle the placer refused and the
//! rectangle DRC measured.
//!
//! Board-local → world is a pure translation by the outline's top-left, the
//! same lift `(heatsink (rect …))` takes: the two forms are read off one
//! mechanical drawing and must land on the same millimetre.

const std = @import("std");
const env = @import("../eval/env.zig");
const optimizer = @import("optimizer.zig");
const outline = @import("outline.zig");
const pad_shape = @import("pad_shape.zig");
const pose_math = @import("pose_math.zig");
const net_name = @import("../net_name.zig");

/// One authored region in world millimetres, with the declaration that made it.
pub const Region = struct {
    spec: env.BoardKeepoutSpec,
    rect: optimizer.BoardRect,

    /// The rectangle's four corners, wound so consecutive pairs are its edges —
    /// the shape `pose_math.obbPenetration` wants.
    pub fn corners(self: Region) [4][2]f64 {
        const r = self.rect;
        return .{
            .{ r.minx, r.miny },
            .{ r.minx + r.w, r.miny },
            .{ r.minx + r.w, r.miny + r.h },
            .{ r.minx, r.miny + r.h },
        };
    }

    /// Does this region reserve `side`? `both` reserves the whole thickness.
    pub fn coversSide(self: Region, side: optimizer.Side) bool {
        return switch (self.spec.side) {
            .both => true,
            .top => side == .top,
            .bottom => side == .bottom,
        };
    }

    /// Does the region reserve the copper LAYER `layer` (0 = F.Cu, 1 = B.Cu,
    /// ≥2 = inner)? An inner layer sits under no assembly face, so a
    /// single-face region leaves it alone; `both` owns the whole thickness and
    /// therefore every layer.
    pub fn coversLayer(self: Region, layer: u8) bool {
        if (self.spec.side == .both) return true;
        return switch (layer) {
            0 => self.spec.side == .top,
            1 => self.spec.side == .bottom,
            else => false,
        };
    }

    /// Authored `(allow-nets …)` admission, matched the way every other board
    /// rule matches a net name: case-insensitively, full flattened name or its
    /// `/`-leaf.
    pub fn allowsNet(self: Region, name: []const u8) bool {
        for (self.spec.allow_nets) |allowed| {
            if (std.ascii.eqlIgnoreCase(name, allowed) or
                std.ascii.eqlIgnoreCase(net_name.leaf(name), allowed)) return true;
        }
        return false;
    }

    /// Signed inset of a world point: positive that far INSIDE the region,
    /// negative that far outside — the same sign convention the perimeter band
    /// and the board-edge rules use.
    pub fn insetAt(self: Region, x: f64, y: f64) f64 {
        const box = self.corners();
        return outline.signedInset(&box, x, y);
    }
};

/// Does `placement` declare any authored region with a frame to place it in?
/// False ⇒ every board-keepout code path short-circuits.
pub fn anyDeclared(placement: optimizer.Placement) bool {
    return placement.rules.board_keepouts.len > 0 and placement.board_rect != null;
}

/// Lift board-local specs into the world frame of `rect` (the outline's
/// top-left is the local origin). Returns an empty slice when there is no
/// outline to measure from — an unanchored region is not silently placed at
/// the world origin.
pub fn resolve(
    arena: std.mem.Allocator,
    rect: ?optimizer.BoardRect,
    specs: []const env.BoardKeepoutSpec,
) std.mem.Allocator.Error![]const Region {
    const r = rect orelse return &.{};
    if (specs.len == 0) return &.{};
    const out = try arena.alloc(Region, specs.len);
    for (specs, out) |spec, *region| {
        region.* = .{
            .spec = spec,
            .rect = .{
                .minx = r.minx + spec.rect.x,
                .miny = r.miny + spec.rect.y,
                .w = spec.rect.w,
                .h = spec.rect.h,
            },
        };
    }
    return out;
}

/// The regions a placement declares, already in world coordinates.
pub fn regionsOf(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
) std.mem.Allocator.Error![]const Region {
    return resolve(arena, placement.board_rect, placement.rules.board_keepouts);
}

/// Does `part`'s courtyard occupy `region` on a face the region reserves?
///
/// The courtyard's OWN rotated corners decide, never its bounding box: off a
/// quarter turn a box corner is a point the component does not occupy, and
/// measuring it would refuse a pose that never entered the region.
pub fn hitsPart(region: Region, part: optimizer.Part) bool {
    if (!region.coversSide(part.side)) return false;
    return pose_math.obbPenetration(pad_shape.worldCourtyardCorners(part), region.corners()) != null;
}

/// The first region `part` intrudes on, or null when the pose is legal. This
/// is the placer's whole question: `optimizer.overlapsAny` asks it of every
/// candidate pose, so a region refuses a part in every greedy search at once.
pub fn blockingPart(regions: []const Region, part: optimizer.Part) ?Region {
    for (regions) |region| {
        if (!region.spec.blocks.components) continue;
        if (hitsPart(region, part)) return region;
    }
    return null;
}

/// How deep `part`'s courtyard sits inside the regions that forbid it (mm, 0
/// when clear) — the force solve's hinge term, so relaxation is pushed out of
/// a region rather than only being refused at the end.
pub fn partDepth(regions: []const Region, part: optimizer.Part) f64 {
    var worst: f64 = 0;
    for (regions) |region| {
        if (!region.spec.blocks.components) continue;
        if (!region.coversSide(part.side)) continue;
        const hit = pose_math.obbPenetration(pad_shape.worldCourtyardCorners(part), region.corners()) orelse continue;
        worst = @max(worst, hit.depth);
    }
    return worst;
}
