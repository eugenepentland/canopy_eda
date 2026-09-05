//! The deprecation log: superseded-but-accepted spellings met during
//! evaluation, recorded with the source position of the form and the spelling
//! that replaces it.
//!
//! Deliberately NOT the evaluator's `warnings` list. The release check profile
//! promotes every evaluator warning to an error, and each spelling recorded
//! here still works — permanently, in this wave. So a deprecation must never be
//! able to fail a build. `erc.checkDeprecatedForms` renders the log as
//! `deprecated_form` **info** findings instead, which `netlisp check
//! --severity info` shows and no profile escalates.
//!
//! Records are deduped by source position, so one retired form inside a module
//! instantiated ten times is reported once rather than ten times.

const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const env_mod = @import("env.zig");
const evaluator_mod = @import("evaluator.zig");

const Evaluator = evaluator_mod.Evaluator;

/// The evaluator-scoped log. One field on `Evaluator` rather than two, so the
/// dedupe index cannot be updated without the list it guards.
pub const Log = struct {
    /// Records in the order they were met. `materializeBlock` hands each
    /// design-block the range appended while its body evaluated.
    items: std.ArrayList(env_mod.DeprecatedForm) = .empty,
    /// `"file:line:col"` keys already in `items`.
    seen: std.StringHashMapUnmanaged(void) = .empty,

    pub fn deinit(self: *Log, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
        self.seen.deinit(allocator);
    }
};

/// Record one use of a superseded spelling. `fmt` must name the recommended
/// spelling — the whole point of the finding is that the author can rewrite the
/// line from it. Never fatal, never a warning; an allocation failure drops the
/// record rather than the build.
pub fn note(self: *Evaluator, span: ast.Span, comptime fmt: []const u8, args: anytype) void {
    const a = self.allocator;
    const key = std.fmt.allocPrint(a, "{s}:{d}:{d}", .{ self.current_file, span.line, span.col }) catch return;
    const gop = self.deprecations.seen.getOrPut(a, key) catch return;
    if (gop.found_existing) return;
    const msg = std.fmt.allocPrint(a, fmt, args) catch return;
    self.deprecations.items.append(a, .{
        .file = self.current_file,
        .line = span.line,
        .col = span.col,
        .message = msg,
    }) catch return;
}

const testing = std.testing;

// spec: eval/deprecations - Deprecation records dedupe by source position so a reused module reports once
test "deprecation log dedupes by source position" {
    const a = std.heap.page_allocator;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    eval.current_file = "lib/modules/x.sexp";
    const span: ast.Span = .{ .line = 12, .col = 3, .offset = 40 };
    note(&eval, span, "old spelling — write (new)", .{});
    note(&eval, span, "old spelling — write (new)", .{});
    note(&eval, .{ .line = 13, .col = 3, .offset = 60 }, "another — write (new)", .{});
    try testing.expectEqual(@as(usize, 2), eval.deprecations.items.items.len);
    try testing.expectEqualStrings("lib/modules/x.sexp", eval.deprecations.items.items[0].file);
    try testing.expectEqual(@as(u32, 12), eval.deprecations.items.items[0].line);
}
