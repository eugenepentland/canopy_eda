//! Filesystem port. All `std.fs` access in production code goes through
//! this module so Guardian's `ban-fs` check has one whitelisted entry
//! point. The wrappers are intentionally thin re-exports — this is a
//! boundary marker, not an abstraction layer.
//!
//! Usage:
//!     const infra_fs = @import("infra/fs.zig");
//!     const file = try infra_fs.cwd().createFile(path, .{});
//!     const data = try infra_fs.cwd().readFileAlloc(allocator, path, max);

const std = @import("std");

/// Returns the working-directory `Dir` handle. Use exactly like
/// `std.fs.cwd()`: `infra_fs.cwd().readFileAlloc(...)`,
/// `infra_fs.cwd().createFile(...)`, etc.
pub const cwd = std.fs.cwd;
