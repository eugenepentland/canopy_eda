const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;

/// Error set for source-file ID insertion. Combines file IO (read & write)
/// with the allocator failures that can come out of `ArrayList`/dupe.
pub const IdInsertError = std.mem.Allocator.Error ||
    std.fs.File.OpenError ||
    std.fs.File.ReadError ||
    std.fs.File.WriteError ||
    error{ FileTooBig, StreamTooLong, EndOfStream };

/// Insert pending (id xxxxxxxx) forms into a source file.
/// Each pending ID has a form_offset (byte position of the opening paren).
/// We find the matching closing paren and insert " (id xxxxxxxx)" before it.
pub fn insertPendingIds(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    pending: []const Evaluator.PendingId,
) IdInsertError!void {
    if (pending.len == 0) return;

    const source = try infra_fs.cwd().readFileAlloc(allocator, source_path, 10 * 1024 * 1024);
    defer allocator.free(source);

    // Sort by offset descending so insertions don't shift earlier offsets
    const sorted = try allocator.alloc(Evaluator.PendingId, pending.len);
    defer allocator.free(sorted);
    @memcpy(sorted, pending);
    std.mem.sort(Evaluator.PendingId, sorted, {}, struct {
        fn cmp(_: void, a: Evaluator.PendingId, b: Evaluator.PendingId) bool {
            return a.form_offset > b.form_offset;
        }
    }.cmp);

    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);
    try result.appendSlice(allocator, source);

    for (sorted) |pid| {
        const close = findMatchingClose(result.items, pid.form_offset) orelse continue;

        // Insert " (id xxxxxxxx)" before the closing paren
        var insert_buf: [32]u8 = undefined;
        const insert = std.fmt.bufPrint(&insert_buf, " (id {s})", .{pid.id}) catch continue;
        try result.insertSlice(allocator, close, insert);
    }

    // Write back
    const file = try infra_fs.cwd().createFile(source_path, .{});
    defer file.close();
    try file.writeAll(result.items);
}

/// Find the byte position of the closing paren matching the opening paren at `open`.
fn findMatchingClose(source: []const u8, open: usize) ?usize {
    if (open >= source.len or source[open] != '(') return null;
    var depth: u32 = 0;
    var i = open;
    var in_string = false;
    while (i < source.len) : (i += 1) {
        if (in_string) {
            if (source[i] == '\\' and i + 1 < source.len) {
                i += 1; // skip escaped char
            } else if (source[i] == '"') {
                in_string = false;
            }
            continue;
        }
        switch (source[i]) {
            '"' => in_string = true,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            ';' => {
                // Skip line comment
                while (i < source.len and source[i] != '\n') : (i += 1) {}
            },
            else => {},
        }
    }
    return null;
}

// spec: id_insert - findMatchingClose finds correct closing paren
test "findMatchingClose basic" {
    const src = "(instance \"R1\" (cap \"100nF\"))";
    const pos = findMatchingClose(src, 0);
    try std.testing.expect(pos != null);
    try std.testing.expectEqual(src.len - 1, pos.?);
}

// spec: id_insert - findMatchingClose handles strings containing parens
test "findMatchingClose with parens in strings" {
    const src = "(note \"has (parens) inside\")";
    const pos = findMatchingClose(src, 0);
    try std.testing.expect(pos != null);
    try std.testing.expectEqual(src.len - 1, pos.?);
}
