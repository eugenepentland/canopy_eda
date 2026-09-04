const std = @import("std");
const navbar = @import("navbar.zig");

// ── Shared navbar ─────────────────────────────────────────────────────

pub const navbar_css = navbar.css;

// ── CSS for index page ────────────────────────────────────────────────

pub const index_css = @embedFile("assets/index.css");
