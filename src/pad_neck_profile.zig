//! Cycle-free value type shared by the DSL, rule resolver, and router.

/// Narrow SMD launch followed by a linear return to nominal track width.
pub const Profile = struct {
    width: f64 = 0,
    max_length: f64 = 0,
    taper_length: f64 = 0,
};
