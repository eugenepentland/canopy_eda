//! Cycle-free trace-width profile shared by the DSL, rule resolver, and router.

/// Narrow SMD launch followed by a linear return to nominal track width.
pub const Profile = struct {
    width: f64 = 0,
    max_length: f64 = 0,
    taper_length: f64 = 0,
    /// Initial width for plane-backed power branches. Kept beside the other
    /// deliberate reductions from nominal class width so the public rule
    /// structs do not grow another independent geometry field.
    power_branch_width: f64 = 0,
};
