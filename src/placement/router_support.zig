//! Small cycle-free value and layer helpers shared by the maze router seams.

const pad_neck_profile = @import("../pad_neck_profile.zig");

/// Design-rule inputs for routing, in millimetres.
pub const RouteParams = struct {
    track_width: f64 = 0.127,
    clearance: f64 = 0.127,
    via_drill: f64 = 0.2,
    via_dia: f64 = 0.4,
    pad_neck: pad_neck_profile.Profile = .{},
};

/// Conservative constant width with which to probe a straight gateway from a
/// pad centre to `distance`: the widest point of that neck/taper segment.
pub fn padGatewayWidth(params: RouteParams, distance: f64) f64 {
    const profile = params.pad_neck;
    if (!(profile.width > 0) or profile.width >= params.track_width) return params.track_width;
    const neck_len = if (profile.max_length > 0) profile.max_length else 0.75;
    const taper_len = if (profile.taper_length > 0) profile.taper_length else 0.35;
    if (distance <= neck_len or taper_len <= 1e-9) return profile.width;
    if (distance >= neck_len + taper_len) return params.track_width;
    const f = (distance - neck_len) / taper_len;
    return profile.width + (params.track_width - profile.width) * f;
}

/// Temporarily select the conservative gateway width and return the old one.
pub fn usePadGateway(params: *RouteParams, distance: f64) f64 {
    const saved = params.track_width;
    params.track_width = padGatewayWidth(params.*, distance);
    return saved;
}

/// Signal-layer index for a placed part's SMD pads.
pub fn sideLayer(part: anytype) u8 {
    return if (part.side == .bottom) 1 else 0;
}

/// Whether any obstacle contributes copper on the bottom signal layer.
pub fn anyBottomPads(obstacles: anytype) bool {
    for (obstacles) |pad| if (pad.layer == 1 or pad.thru) return true;
    return false;
}
