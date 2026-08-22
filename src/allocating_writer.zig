//! Allocator-error view of Zig's generic allocating writer.
//!
//! `std.Io.Writer.Allocating` can only fail while growing its buffer, but its
//! generic writer interface reports that failure as `WriteFailed`. This small
//! adapter preserves allocator-only error contracts at in-memory call sites.

const std = @import("std");

/// Writer facade that translates an allocating writer's `WriteFailed` into
/// the underlying `OutOfMemory` condition.
pub const AllocatingWriter = struct {
    writer: *std.Io.Writer,

    /// Write all bytes, mapping buffer-growth failure to `OutOfMemory`.
    pub fn writeAll(self: AllocatingWriter, bytes: []const u8) std.mem.Allocator.Error!void {
        self.writer.writeAll(bytes) catch return error.OutOfMemory;
    }

    /// Write one byte, mapping buffer-growth failure to `OutOfMemory`.
    pub fn writeByte(self: AllocatingWriter, byte: u8) std.mem.Allocator.Error!void {
        self.writer.writeByte(byte) catch return error.OutOfMemory;
    }

    /// Format into the buffer, mapping growth failure to `OutOfMemory`.
    pub fn print(self: AllocatingWriter, comptime format: []const u8, args: anytype) std.mem.Allocator.Error!void {
        self.writer.print(format, args) catch return error.OutOfMemory;
    }
};
