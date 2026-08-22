//! Small cycle-free value and layer helpers shared by the maze router seams.

/// Design-rule inputs for routing, in millimetres.
pub const RouteParams = struct {
    track_width: f64 = 0.127,
    clearance: f64 = 0.127,
    via_drill: f64 = 0.2,
    via_dia: f64 = 0.4,
};

/// Signal-layer index for a placed part's SMD pads.
pub fn sideLayer(part: anytype) u8 {
    return if (part.side == .bottom) 1 else 0;
}

/// Whether any obstacle contributes copper on the bottom signal layer.
pub fn anyBottomPads(obstacles: anytype) bool {
    for (obstacles) |pad| if (pad.layer == 1 or pad.thru) return true;
    return false;
}
