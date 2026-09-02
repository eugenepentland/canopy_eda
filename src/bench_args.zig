//! The command line every `netlisp bench-*` harness shares.
//!
//! `bench-page` and `bench-route` measure different things and each has flags
//! of its own, but the four arguments that decide WHAT is measured and WHERE
//! the answer goes — `--project-dir`, `--json`, `--baseline`, and the trailing
//! design names — are the same command line, and were the same twenty lines
//! written out twice. A harness that learns a new common flag should not have
//! to learn it twice, and two harnesses that disagree about how `--baseline` is
//! spelled are a CI gate that silently stops comparing.
//!
//! The scan itself lives here too, so a harness only writes the arm for its own
//! flags: an unrecognised `--flag` is neither an error nor a design name in
//! either harness, and that tolerance is a decision worth having in one place.

const std = @import("std");

/// The shared half of a harness's parsed command line. A harness embeds this
/// and calls `parse`, passing a hook for its own flags.
pub const Common = struct {
    /// Project root the designs are resolved under.
    project_dir: []const u8 = ".",
    /// Emit machine-readable JSON instead of the human table.
    json: bool = false,
    /// Committed baseline JSON (an earlier run's `--json`) to compare against.
    baseline: ?[]const u8 = null,
    /// Positional design names, in command-line order. Empty means "the whole
    /// corpus", which is each harness's own default.
    named: std.ArrayList([]const u8) = .empty,

    /// Scan `args`. Each argument is offered to `takeExtra` — the harness's own
    /// flags, which advance `i` past any value they consume and return true —
    /// and everything it declines falls through to the shared flags and the
    /// positional names.
    pub fn parse(
        self: *Common,
        arena: std.mem.Allocator,
        args: []const []const u8,
        extra: anytype,
        comptime takeExtra: anytype,
    ) std.mem.Allocator.Error!void {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (takeExtra(extra, args, &i)) continue;
            try self.take(arena, args, &i);
        }
    }

    /// Consume `args[i.*]` when it is one of the shared flags or a positional
    /// design name, advancing `i` past any value it takes.
    ///
    /// A flag whose value is missing (it was the last argument) leaves the
    /// field at its default rather than reading past the end, and an
    /// unrecognised `--flag` is ignored rather than becoming a design name.
    fn take(
        self: *Common,
        arena: std.mem.Allocator,
        args: []const []const u8,
        i: *usize,
    ) std.mem.Allocator.Error!void {
        const arg = args[i.*];
        if (std.mem.eql(u8, arg, "--project-dir")) {
            i.* += 1;
            if (i.* < args.len) self.project_dir = args[i.*];
        } else if (std.mem.eql(u8, arg, "--json")) {
            self.json = true;
        } else if (std.mem.eql(u8, arg, "--baseline")) {
            i.* += 1;
            if (i.* < args.len) self.baseline = args[i.*];
        } else if (!std.mem.startsWith(u8, arg, "--")) {
            try self.named.append(arena, arg);
        }
    }
};
