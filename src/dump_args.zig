//! The command line every read-only `netlisp *-dump` inspection command shares.
//!
//! `netlist-dump`, `gerber-dump` and `envelopes` measure different things, but
//! the two arguments that decide WHAT is inspected — `--project-dir` and the
//! trailing design names — are the same command line, and were the same twenty
//! lines written out three times. Modelled on `bench_args.Common`, which does
//! the same job for the `bench-*` harnesses.
//!
//! The shared decision worth having in ONE place is the strictness, and it is
//! the opposite of the bench harnesses': an unrecognised `--flag` and a run
//! naming no design are both usage errors here, never a tolerated no-op. These
//! commands exist to be diffed, and a dump that silently inspected nothing
//! reads exactly like a dump that found no difference.

const std = @import("std");

/// The shared half of a dump command's parsed command line. A command embeds
/// this and calls `parse`, passing a hook for its own flags.
pub const Common = struct {
    /// Project root the designs are resolved under.
    project_dir: []const u8 = "projects/designs",
    /// Positional design names, in command-line order.
    named: std.ArrayList([]const u8) = .empty,

    /// Scan `args`. Each argument is offered to `takeExtra` — the command's own
    /// flags, which advance `i` past any value they consume and return true —
    /// and everything it declines falls through to `--project-dir` and the
    /// positional names.
    ///
    /// Returns false for a command line that must not run: an unrecognised
    /// `--flag`, or no design named at all. The caller turns that into its own
    /// usage error, so each command keeps the error name its callers already
    /// match on.
    pub fn parse(
        self: *Common,
        arena: std.mem.Allocator,
        args: []const []const u8,
        extra: anytype,
        comptime takeExtra: anytype,
    ) std.mem.Allocator.Error!bool {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (takeExtra(extra, args, &i)) continue;
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--project-dir") and i + 1 < args.len) {
                i += 1;
                self.project_dir = args[i];
            } else if (std.mem.startsWith(u8, arg, "--")) {
                return false;
            } else try self.named.append(arena, arg);
        }
        return self.named.items.len > 0;
    }
};

/// The hook for a command with no flags of its own.
pub fn noExtra(_: void, _: []const []const u8, _: *usize) bool {
    return false;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

const Extra = struct {
    layout: []const u8 = "",
    digest: bool = false,

    fn take(self: *Extra, args: []const []const u8, i: *usize) bool {
        if (std.mem.eql(u8, args[i.*], "--layout") and i.* + 1 < args.len) {
            i.* += 1;
            self.layout = args[i.*];
            return true;
        }
        if (std.mem.eql(u8, args[i.*], "--digest")) {
            self.digest = true;
            return true;
        }
        return false;
    }
};

// spec: dump command line - the shared scan reads the project dir, collects positional design names, and lets a command take its own flags first
test "the shared dump scan reads the project dir, names, and command flags" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var common: Common = .{};
    var extra: Extra = .{};
    const ok = try common.parse(
        arena_state.allocator(),
        &.{ "--project-dir", "p", "--layout", "candidate", "board-a", "--digest", "board-b" },
        &extra,
        Extra.take,
    );
    try testing.expect(ok);
    try testing.expectEqualStrings("p", common.project_dir);
    try testing.expectEqualStrings("candidate", extra.layout);
    try testing.expect(extra.digest);
    try testing.expectEqual(@as(usize, 2), common.named.items.len);
    try testing.expectEqualStrings("board-a", common.named.items[0]);
    try testing.expectEqualStrings("board-b", common.named.items[1]);
}

// spec: dump command line - an unrecognised flag or a run naming no design is refused rather than inspecting nothing
test "the shared dump scan refuses an unknown flag and a run with no design" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var unknown: Common = .{};
    try testing.expect(!try unknown.parse(arena, &.{ "--wat", "b" }, {}, noExtra));
    var nameless: Common = .{};
    try testing.expect(!try nameless.parse(arena, &.{"--project-dir"}, {}, noExtra));
    // `--project-dir` as the LAST argument takes no value, so it is an
    // unrecognised trailing flag rather than a silent default.
    try testing.expectEqual(@as(usize, 0), nameless.named.items.len);
    var defaulted: Common = .{};
    try testing.expect(try defaulted.parse(arena, &.{"b"}, {}, noExtra));
    try testing.expectEqualStrings("projects/designs", defaulted.project_dir);
}
