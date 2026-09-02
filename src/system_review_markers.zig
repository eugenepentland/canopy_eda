//! The generated-region markers a system-review document carries, and the one
//! rule for recognising them.
//!
//! A `<!-- netlisp:generated <id> -->` … `<!-- /netlisp:generated -->` pair
//! brackets a block the packager rewrites. Three call sites need to know
//! whether a line IS such a marker, and two of them had grown their own copy of
//! the test: one matching the open marker by its literal prefix + ` -->`
//! suffix, the other going through an id extractor. Those agree only for as
//! long as nobody changes what an id may contain — the extractor is the
//! authority, since it is what the packager uses to look the region up.
//!
//! Fenced code is not markup: a ```` ``` ```` block may quote a marker as an
//! EXAMPLE, and stripping that would edit the document's prose.

const std = @import("std");
const system_review = @import("system_review.zig");

const open_suffix = " -->";

/// What `stripMarkerLines` can fail with: allocating the output, and the
/// allocating writer's own failure to grow.
pub const StripError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// The region id in `line` when it is a generated-region OPEN marker, else
/// null. `line` is matched whole, so a caller trims it first if its source
/// lines carry indentation.
pub fn openId(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, system_review.generated_region_open) or
        !std.mem.endsWith(u8, line, open_suffix)) return null;
    return line[system_review.generated_region_open.len .. line.len - open_suffix.len];
}

/// Is `line` a generated-region marker of either end?
pub fn isMarker(line: []const u8) bool {
    return openId(line) != null or std.mem.eql(u8, line, system_review.generated_region_close);
}

/// `source` with every generated-region marker line removed, so the remaining
/// text is what a human wrote. Lines inside a fenced code block are copied
/// verbatim — a marker quoted as an example is documentation, not markup.
/// Caller owns the result.
pub fn stripMarkerLines(allocator: std.mem.Allocator, source: []const u8) StripError![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    var lines = std.mem.splitScalar(u8, source, '\n');
    var in_fence = false;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        var marker = false;
        if (in_fence) {
            if (std.mem.eql(u8, trimmed, "```")) in_fence = false;
        } else if (std.mem.startsWith(u8, trimmed, "```")) {
            in_fence = true;
        } else {
            marker = isMarker(trimmed);
        }
        if (!marker) try out.writer.print("{s}\n", .{line});
    }
    return out.toOwnedSlice();
}
