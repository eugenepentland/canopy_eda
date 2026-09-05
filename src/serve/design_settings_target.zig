//! Which of a design's files owns a design-scope singleton form — and how that
//! file wants it written.
//!
//! The PCB Design Settings drawer patches `(design-rules …)` and `(stackup …)`,
//! the Layout tab patches `(diagram-layout …)`, and the subcircuit router
//! control patches `(power-plane …)`. Every one of those heads is eligible to
//! live in an autoloaded sidecar (`eval/sidecars.zig`), so a design that
//! `split-design` has been run on keeps it in `<name>.layout.sexp` /
//! `<name>.diagram.sexp` rather than in `src/<name>.sexp`.
//!
//! A writer that assumes the design file therefore has two ways to be wrong,
//! and both are silent:
//!
//!   * it authors a SECOND copy. For a singleton (`stackup`, `board`,
//!     `pcb-plan`, `design-rules`, `diagram-layout`) the loader refuses the
//!     duplicate and the board stops evaluating; for a non-singleton like
//!     `power-plane` the splice appends the sidecar last, so the sidecar's copy
//!     silently overrides the edit that was just "saved".
//!   * it patches at a byte span it read from one file into another file. That
//!     is data corruption, not a failed edit.
//!
//! `resolve` answers the question once for every such writer: it scans the
//! design file's `(design-block …)` children and each sidecar's top level, and
//! returns the ONE file that holds the form together with the shape that file
//! wants. The same head in two files comes back as a conflict naming both —
//! which is what the loader would refuse anyway, reported before anything is
//! written rather than after.
//!
//! The lexical scanners live here too (rather than in one endpoint's module),
//! because "find this form's byte span" is now shared by every settings writer.

const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const paths = @import("../paths.zig");
const sidecars = @import("../eval/sidecars.zig");

pub const max_source_bytes: usize = 10 * 1024 * 1024;

/// Building a patched source buffer: allocation, plus the writer's own failure
/// mode. Spelled out rather than inferred, so a caller can switch on it.
pub const PatchError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// A half-open byte range `[start, end)` of one source form.
pub const Span = struct { start: usize, end: usize };

// ── Lexical scanning ───────────────────────────────────────────────────

/// Advance `cursor` past the string or `;` comment it currently sits on.
pub fn skipStringOrComment(source: []const u8, cursor: *usize, limit: usize) void {
    if (source[cursor.*] == ';') {
        while (cursor.* < limit and source[cursor.*] != '\n') cursor.* += 1;
        return;
    }
    cursor.* += 1;
    while (cursor.* < limit and source[cursor.*] != '"') : (cursor.* += 1) {
        if (source[cursor.*] == '\\' and cursor.* + 1 < limit) cursor.* += 1;
    }
    if (cursor.* < limit) cursor.* += 1;
}

fn headEnd(ch: u8) bool {
    return std.ascii.isWhitespace(ch) or ch == '(' or ch == ')';
}

/// One past the closing paren of the form opening at `open`, or null when the
/// source is unbalanced.
pub fn formEnd(source: []const u8, open: usize) ?usize {
    var cursor = open;
    var depth: usize = 0;
    while (cursor < source.len) {
        const ch = source[cursor];
        if (ch == '"' or ch == ';') {
            skipStringOrComment(source, &cursor, source.len);
            continue;
        }
        if (ch == '(') depth += 1;
        if (ch == ')') {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return cursor + 1;
        }
        cursor += 1;
    }
    return null;
}

/// The head atom of the form spanning `[open, end)`.
pub fn formHead(source: []const u8, open: usize, end: usize) []const u8 {
    var cursor = open + 1;
    while (cursor < end and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
    const start = cursor;
    while (cursor < end and !headEnd(source[cursor])) : (cursor += 1) {}
    return source[start..cursor];
}

/// The first direct `(head …)` child of `parent`, skipping strings, comments
/// and anything nested deeper.
pub fn directChild(source: []const u8, parent: Span, head: []const u8) ?Span {
    var cursor = parent.start + 1;
    var depth: usize = 0;
    while (cursor + 1 < parent.end) {
        const ch = source[cursor];
        if (ch == '"' or ch == ';') {
            skipStringOrComment(source, &cursor, parent.end);
            continue;
        }
        if (ch == '(') {
            if (depth == 0) {
                const end = formEnd(source, cursor) orelse return null;
                if (end > parent.end) return null;
                if (std.mem.eql(u8, formHead(source, cursor, end), head)) return .{ .start = cursor, .end = end };
                cursor = end;
                continue;
            }
            depth += 1;
        } else if (ch == ')') {
            if (depth == 0) break;
            depth -= 1;
        }
        cursor += 1;
    }
    return null;
}

/// A top-level `(head …)` form — i.e. one in a sidecar, which has no
/// `(design-block …)` wrapper. Scans at depth zero only, so a `(stackup …)`
/// nested inside some other form is not mistaken for the design's own.
pub fn topLevelForm(source: []const u8, head: []const u8) ?Span {
    var cursor: usize = 0;
    while (cursor < source.len) {
        const ch = source[cursor];
        if (ch == '"' or ch == ';') {
            skipStringOrComment(source, &cursor, source.len);
            continue;
        }
        if (ch == '(') {
            const end = formEnd(source, cursor) orelse return null;
            if (std.mem.eql(u8, formHead(source, cursor, end), head)) return .{ .start = cursor, .end = end };
            cursor = end;
            continue;
        }
        cursor += 1;
    }
    return null;
}

/// The design file's `(design-block …)` form.
pub fn designBlockSpan(source: []const u8) ?Span {
    const open = std.mem.indexOf(u8, source, "(design-block") orelse return null;
    return .{ .start = open, .end = formEnd(source, open) orelse return null };
}

/// `source` with `span` replaced by `replacement` (caller frees).
pub fn replaceSpan(allocator: std.mem.Allocator, source: []const u8, span: Span, replacement: []const u8) PatchError![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(source[0..span.start]);
    try out.writer.writeAll(replacement);
    try out.writer.writeAll(source[span.end..]);
    return out.toOwnedSlice();
}

/// `source` with `text` appended as a new top-level form, newline-separated
/// from whatever the sidecar already holds (caller frees).
pub fn appendTopLevel(allocator: std.mem.Allocator, source: []const u8, text: []const u8) PatchError![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(source);
    if (source.len > 0 and source[source.len - 1] != '\n') try out.writer.writeByte('\n');
    if (source.len > 0) try out.writer.writeByte('\n');
    try out.writer.writeAll(text);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

// ── Where a form lives ─────────────────────────────────────────────────

/// How the file holding a design-scope form wants it written.
pub const Container = enum {
    /// A child of `(design-block …)` — the design file.
    design_block,
    /// A top-level form — a sidecar.
    top_level,

    /// Indentation of the form itself.
    pub fn indent(self: Container) []const u8 {
        return switch (self) {
            .design_block => "  ",
            .top_level => "",
        };
    }

    /// Indentation of a child written inside that form.
    pub fn childIndent(self: Container) []const u8 {
        return switch (self) {
            .design_block => "    ",
            .top_level => "  ",
        };
    }
};

/// The indentation of the line `span` opens on — the form's own indent, which
/// its children nest one step inside. `fallback` covers a form that shares its
/// line with something else (and the file that was never indented at all), so
/// the caller always has a usable string. A form lifted into a sidecar by
/// `split-design` keeps the indentation it had in the design file, so reading
/// it back beats assuming the container's default.
pub fn formIndent(source: []const u8, span: Span, fallback: []const u8) []const u8 {
    var line_start = span.start;
    while (line_start > 0 and source[line_start - 1] != '\n') line_start -= 1;
    for (source[line_start..span.start]) |c| if (!std.ascii.isWhitespace(c)) return fallback;
    return source[line_start..span.start];
}

/// `head`'s byte span in `source`, read the way `container` stores it.
pub fn formSpan(source: []const u8, container: Container, head: []const u8) ?Span {
    return switch (container) {
        .design_block => directChild(source, designBlockSpan(source) orelse return null, head),
        .top_level => topLevelForm(source, head),
    };
}

/// Replace (or author) a whole `(head …)` form at a sidecar's top level.
pub fn patchTopLevel(
    allocator: std.mem.Allocator,
    source: []const u8,
    head: []const u8,
    replacement: []const u8,
) PatchError![]u8 {
    if (topLevelForm(source, head)) |span| return replaceSpan(allocator, source, span, replacement);
    return appendTopLevel(allocator, source, replacement);
}

/// The one file that holds the form, and the shape it is stored in.
pub const Target = struct {
    /// The file to read and patch.
    path: []u8,
    /// The design source — what gets evaluated after the write, whether or not
    /// the bytes landed in it.
    design_path: []u8,
    container: Container,
    /// True when the form is already written in `path`; false when `path` is
    /// merely where a new one belongs.
    present: bool,

    /// True when the bytes belong in a sidecar rather than the design file.
    pub fn isSidecar(self: Target) bool {
        return !std.mem.eql(u8, self.path, self.design_path);
    }

    pub fn deinit(self: Target, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.design_path);
    }
};

/// The same head declared in two of a design's files. The loader refuses this
/// state; reporting it names both files so the author can delete one.
pub const Conflict = struct {
    first: []u8,
    second: []u8,
};

pub const Resolution = union(enum) {
    target: Target,
    conflict: Conflict,

    pub fn deinit(self: Resolution, allocator: std.mem.Allocator) void {
        switch (self) {
            .target => |t| t.deinit(allocator),
            .conflict => |c| {
                allocator.free(c.first);
                allocator.free(c.second);
            },
        }
    }
};

pub const ResolveError = std.mem.Allocator.Error || error{CannotReadDesign};

/// Locate the file that declares any of `heads` for design `name`.
///
/// `heads` is a preference list for ONE logical form — `diagram-layout` and its
/// legacy `layout` spelling, say. The first entry decides which sidecar an
/// absent form is authored into (via `sidecars.homeOf`).
///
/// Absent everywhere: the home sidecar when that file already exists, else the
/// design file — so a design nobody has split keeps the historical behaviour
/// exactly, and a split one never grows a second copy of a form it moved out.
pub fn resolve(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    heads: []const []const u8,
) ResolveError!Resolution {
    var scratch_state = std.heap.ArenaAllocator.init(allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    const design_path = paths.designSourcePath(scratch, project_dir, name) catch
        return error.CannotReadDesign;
    const design_src = infra_fs.cwd().readFileAlloc(scratch, design_path, max_source_bytes) catch
        return error.CannotReadDesign;

    var found: ?[]const u8 = null;
    var found_container: Container = .design_block;
    var duplicate: ?[]const u8 = null;
    for (heads) |head| {
        if (formSpan(design_src, .design_block, head) == null) continue;
        found = design_path;
        break;
    }

    // The sidecar a missing form would be authored into, when it exists.
    var home: ?[]const u8 = null;
    for (sidecars.kinds) |kind| {
        const path = paths.designSiblingPath(scratch, project_dir, name, kind.ext()) catch continue;
        const src = infra_fs.cwd().readFileAlloc(scratch, path, max_source_bytes) catch continue;
        if (heads.len > 0) if (sidecars.homeOf(heads[0])) |want| {
            if (want == kind) home = path;
        };
        var holds = false;
        for (heads) |head| {
            if (topLevelForm(src, head) == null) continue;
            holds = true;
            break;
        }
        if (!holds) continue;
        if (found != null) {
            if (duplicate == null) duplicate = path;
            continue;
        }
        found = path;
        found_container = .top_level;
    }

    if (duplicate) |second| return .{ .conflict = .{
        .first = try allocator.dupe(u8, found.?),
        .second = try allocator.dupe(u8, second),
    } };

    const write_path = found orelse home orelse design_path;
    const container: Container = if (found != null)
        found_container
    else if (home != null)
        .top_level
    else
        .design_block;

    const owned_path = try allocator.dupe(u8, write_path);
    errdefer allocator.free(owned_path);
    return .{ .target = .{
        .path = owned_path,
        .design_path = try allocator.dupe(u8, design_path),
        .container = container,
        .present = found != null,
    } };
}

/// The atom argument of a top-level `(head ATOM)` declared in one of `name`'s
/// sidecars, or null when no sidecar declares it. The splice appends sidecar
/// forms last, so a sidecar's copy is the one in force. Caller frees.
pub fn sidecarAtomArg(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    head: []const u8,
) ?[]u8 {
    for (sidecars.kinds) |kind| {
        const path = paths.designSiblingPath(allocator, project_dir, name, kind.ext()) catch continue;
        defer allocator.free(path);
        const src = infra_fs.cwd().readFileAlloc(allocator, path, max_source_bytes) catch continue;
        defer allocator.free(src);
        const span = topLevelForm(src, head) orelse continue;
        const body = src[span.start + 1 + head.len .. span.end - 1];
        const word = std.mem.trim(u8, body, " \t\r\n");
        if (word.len == 0) continue;
        return allocator.dupe(u8, word) catch null;
    }
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// A project holding `src/<files[i][0]>` with `files[i][1]` as its content.
fn fixture(arena: std.mem.Allocator, tmp: *std.testing.TmpDir, files: []const [2][]const u8) ![]const u8 {
    try tmp.dir.createDirPath(std.testing.io, "src");
    for (files) |f| {
        const sub = try std.fmt.allocPrint(arena, "src/{s}", .{f[0]});
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = sub, .data = f[1] });
    }
    return tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
}

// spec: Web Server - Design Settings locates a design-scope form in whichever of the design's files holds it, and authors a missing one into the layout sidecar when the design has been split
test "settings target follows a split form into its sidecar" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixture(arena, &tmp, &.{
        .{ "split.sexp", "(design-block \"Split\"\n  (section \"RF\"))\n" },
        .{
            "split.layout.sexp",
            "; Layout sidecar.\n(design-rules (clearance 0.15))\n",
        },
        .{ "whole.sexp", "(design-block \"Whole\"\n  (design-rules (clearance 0.2))\n  (section \"RF\"))\n" },
    });

    // Split: the sidecar holds it, so that is the file to patch.
    const split = try resolve(arena, root, "split", &.{"design-rules"});
    defer split.deinit(arena);
    try testing.expect(split == .target);
    try testing.expect(std.mem.endsWith(u8, split.target.path, "split.layout.sexp"));
    try testing.expectEqual(Container.top_level, split.target.container);
    try testing.expect(split.target.present);
    try testing.expect(split.target.isSidecar());

    // Absent everywhere, but the design HAS a layout sidecar: author it there,
    // never as a second copy in the design file.
    const absent = try resolve(arena, root, "split", &.{"stackup"});
    defer absent.deinit(arena);
    try testing.expect(std.mem.endsWith(u8, absent.target.path, "split.layout.sexp"));
    try testing.expectEqual(Container.top_level, absent.target.container);
    try testing.expect(!absent.target.present);

    // Unsplit design: unchanged behaviour, in the design file.
    const whole = try resolve(arena, root, "whole", &.{"design-rules"});
    defer whole.deinit(arena);
    try testing.expect(std.mem.endsWith(u8, whole.target.path, "whole.sexp"));
    try testing.expectEqual(Container.design_block, whole.target.container);
    try testing.expect(whole.target.present);
    try testing.expect(!whole.target.isSidecar());

    // Absent with no sidecar at all: the design file, as before.
    const fresh = try resolve(arena, root, "whole", &.{"stackup"});
    defer fresh.deinit(arena);
    try testing.expect(std.mem.endsWith(u8, fresh.target.path, "whole.sexp"));
    try testing.expectEqual(Container.design_block, fresh.target.container);
    try testing.expect(!fresh.target.present);

    try testing.expectError(error.CannotReadDesign, resolve(arena, root, "nosuch", &.{"stackup"}));
    try testing.expectError(error.CannotReadDesign, resolve(testing.failing_allocator, root, "whole", &.{"stackup"}));
}

// spec: Web Server - A design-scope form declared in both the design file and a sidecar is reported as a conflict naming both files instead of being patched in one of them
test "settings target reports the ambiguous two-file state" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixture(arena, &tmp, &.{
        .{ "two.sexp", "(design-block \"Two\"\n  (stackup 4 (thickness 1.6)))\n" },
        .{ "two.layout.sexp", "(stackup 2)\n" },
    });

    const got = try resolve(arena, root, "two", &.{"stackup"});
    defer got.deinit(arena);
    try testing.expect(got == .conflict);
    try testing.expect(std.mem.endsWith(u8, got.conflict.first, "two.sexp"));
    try testing.expect(std.mem.endsWith(u8, got.conflict.second, "two.layout.sexp"));
}

// spec: Web Server - A sidecar's copy of an atom-valued design-scope form is the value in force, because the splice appends sidecar forms last
test "sidecarAtomArg reads the declaration the splice leaves in force" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixture(arena, &tmp, &.{
        .{ "sub.sexp", "(design-block \"Sub\"\n  (board-role subcircuit))\n" },
        .{ "sub.layout.sexp", "(power-plane off)\n" },
        .{ "bare.sexp", "(design-block \"Bare\")\n" },
    });

    const word = sidecarAtomArg(arena, root, "sub", "power-plane").?;
    try testing.expectEqualStrings("off", word);
    try testing.expectEqual(@as(?[]u8, null), sidecarAtomArg(arena, root, "bare", "power-plane"));
    try testing.expectEqual(@as(?[]u8, null), sidecarAtomArg(arena, root, "sub", "stackup"));
}

// spec: Web Server - Design Settings writes a sidecar form at the top level and a design-file form as a design-block child, each with that file's own indentation
test "top-level authoring appends a separated form and keeps replacements surgical" {
    const a = testing.allocator;
    const authored = try patchTopLevel(a, "; banner\n(design-rules (clearance 0.1))\n", "power-plane", "(power-plane off)");
    defer a.free(authored);
    try testing.expectEqualStrings("; banner\n(design-rules (clearance 0.1))\n\n(power-plane off)\n", authored);

    const replaced = try patchTopLevel(a, authored, "power-plane", "(power-plane on)");
    defer a.free(replaced);
    try testing.expect(std.mem.indexOf(u8, replaced, "(power-plane on)") != null);
    try testing.expect(std.mem.indexOf(u8, replaced, "(power-plane off)") == null);
    try testing.expect(std.mem.indexOf(u8, replaced, "; banner") != null);

    const empty = try patchTopLevel(a, "", "stackup", "(stackup 4)");
    defer a.free(empty);
    try testing.expectEqualStrings("(stackup 4)\n", empty);

    try testing.expectEqualStrings("  ", Container.design_block.indent());
    try testing.expectEqualStrings("", Container.top_level.indent());
    try testing.expectEqualStrings("    ", Container.design_block.childIndent());
    try testing.expectEqualStrings("  ", Container.top_level.childIndent());

    // A comment or a nested form is never mistaken for the declaration.
    try testing.expect(topLevelForm("(board (stackup 4))", "stackup") == null);
    try testing.expect(topLevelForm("; (stackup 4)\n(design-rules)", "stackup") == null);
    try testing.expect(topLevelForm("(stackup 4)", "stackup") != null);

    // The two builders `patchTopLevel` composes, by name, including the
    // allocation failure each one propagates rather than swallowing.
    const spliced = try replaceSpan(a, "(a)(b)(c)", .{ .start = 3, .end = 6 }, "(B)");
    defer a.free(spliced);
    try testing.expectEqualStrings("(a)(B)(c)", spliced);
    // The allocating writer reports a failed allocation as `WriteFailed`; all
    // three builders propagate it rather than returning a truncated buffer.
    try testing.expectError(error.WriteFailed, replaceSpan(testing.failing_allocator, "(a)", .{ .start = 0, .end = 3 }, "(b)"));
    try testing.expectError(error.WriteFailed, appendTopLevel(testing.failing_allocator, "(a)\n", "(b)"));
    try testing.expectError(error.WriteFailed, patchTopLevel(testing.failing_allocator, "(a)\n", "b", "(b)"));
}
