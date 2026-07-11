//! Suggestion engine for unbound-name diagnostics. When an atom lookup
//! fails, the evaluator asks this module for a better message than a bare
//! "UnboundVariable": either an import hint (the name exists as a library
//! file that just wasn't `(import …)`ed) or a did-you-mean nearest-name
//! suggestion (Levenshtein distance ≤ 2 over env bindings, cached
//! components, and library file stems). Only runs on the error path, so
//! the directory scans are not a hot-path cost.

const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const env_mod = @import("env.zig");
const Evaluator = @import("evaluator.zig").Evaluator;
const Env = env_mod.Env;

/// Maximum edit distance for a did-you-mean candidate.
const max_edit_distance: usize = 2;
/// Names longer than this skip the Levenshtein scan (cost cap; real
/// component names are far shorter).
const max_name_len: usize = 64;
/// Library sub-directories searched for both the import hint and the
/// did-you-mean stem candidates — the same paths `modules.resolveImport`
/// walks.
const lib_prefixes = [_][]const u8{ "lib/components/", "lib/modules/" };

/// Build the diagnostic message for an unbound name. Returns an allocated
/// slice (never freed — project memory convention):
///   • `'x' is in the library — add (import x)` when a library file exists
///   • `unknown name 'x' — did you mean 'y'?` for a close candidate
///   • `unknown name 'x'` otherwise
pub fn unboundMessage(self: *Evaluator, name: []const u8, env: *const Env) []const u8 {
    if (existsInLibrary(self, name)) {
        return std.fmt.allocPrint(self.allocator, "'{s}' is in the library — add (import {s})", .{ name, name }) catch name;
    }
    if (nearestName(self, name, env)) |candidate| {
        return std.fmt.allocPrint(self.allocator, "unknown name '{s}' — did you mean '{s}'?", .{ name, candidate }) catch name;
    }
    return std.fmt.allocPrint(self.allocator, "unknown name '{s}'", .{name}) catch name;
}

/// True when `lib/components/<name>.sexp` or `lib/modules/<name>.sexp`
/// exists under the project dir or the shared lib dir — the exact search
/// path `(import …)` resolution uses.
fn existsInLibrary(self: *Evaluator, name: []const u8) bool {
    for (libRoots(self)) |root| {
        for (lib_prefixes) |prefix| {
            const path = std.fmt.allocPrint(self.allocator, "{s}/{s}{s}.sexp", .{ root, prefix, name }) catch return false;
            defer self.allocator.free(path);
            infra_fs.cwd().access(path, .{}) catch continue;
            return true;
        }
    }
    return false;
}

fn libRoots(self: *Evaluator) []const []const u8 {
    if (std.mem.eql(u8, self.project_dir, self.lib_dir)) {
        return (&self.project_dir)[0..1];
    }
    // Both fields live on the evaluator, but they aren't adjacent — return
    // a small allocated pair instead of relying on field layout.
    const pair = self.allocator.alloc([]const u8, 2) catch return (&self.project_dir)[0..1];
    pair[0] = self.project_dir;
    pair[1] = self.lib_dir;
    return pair;
}

/// Best candidate within `MAX_EDIT_DISTANCE` of `name`, drawn from env
/// bindings (walking the scope chain), the component cache, and library
/// file stems. Ties resolve to the smallest distance, first seen.
fn nearestName(self: *Evaluator, name: []const u8, env: *const Env) ?[]const u8 {
    if (name.len > max_name_len) return null;
    var best: ?[]const u8 = null;
    var best_dist: usize = max_edit_distance + 1;

    var scope: ?*const Env = env;
    while (scope) |e| : (scope = e.parent) {
        var it = e.bindings.keyIterator();
        while (it.next()) |key| considerCandidate(name, key.*, &best, &best_dist);
    }
    var comp_it = self.component_cache.keyIterator();
    while (comp_it.next()) |key| considerCandidate(name, key.*, &best, &best_dist);

    considerLibraryStems(self, name, &best, &best_dist);
    return best;
}

/// Scan the library directories and feed each `.sexp` file stem into the
/// candidate ranking. Stems are duped (directory iteration reuses its name
/// buffer, and the winning candidate must outlive the scan).
fn considerLibraryStems(self: *Evaluator, name: []const u8, best: *?[]const u8, best_dist: *usize) void {
    for (libRoots(self)) |root| {
        for (lib_prefixes) |prefix| {
            const dir_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ root, prefix }) catch continue;
            defer self.allocator.free(dir_path);
            var dir = infra_fs.cwd().openDir(dir_path, .{ .iterate = true }) catch continue;
            defer dir.close();
            var it = dir.iterate();
            while (it.next() catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".sexp")) continue;
                const stem = entry.name[0 .. entry.name.len - ".sexp".len];
                const before = best_dist.*;
                considerCandidate(name, stem, best, best_dist);
                if (best_dist.* < before) {
                    // The stem slice points into the iterator's buffer —
                    // dupe the winner so it survives the loop.
                    best.* = self.allocator.dupe(u8, stem) catch null;
                    if (best.* == null) best_dist.* = before;
                }
            }
        }
    }
}

/// Update the running best candidate with `candidate` if it is closer.
fn considerCandidate(name: []const u8, candidate: []const u8, best: *?[]const u8, best_dist: *usize) void {
    if (candidate.len > max_name_len) return;
    if (std.mem.eql(u8, name, candidate)) return;
    const len_diff = if (name.len > candidate.len) name.len - candidate.len else candidate.len - name.len;
    if (len_diff > max_edit_distance) return;
    const d = editDistance(name, candidate);
    if (d < best_dist.*) {
        best_dist.* = d;
        best.* = candidate;
    }
}

/// Classic two-row Levenshtein distance, sized for component-name-length
/// strings (`MAX_NAME_LEN` cap enforced by the callers).
fn editDistance(a: []const u8, b: []const u8) usize {
    var rows: [2][max_name_len + 1]usize = undefined;
    var prev = &rows[0];
    var curr = &rows[1];
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ac, i| {
        curr[0] = i + 1;
        for (b, 0..) |bc, j| {
            const cost: usize = if (ac == bc) 0 else 1;
            curr[j + 1] = @min(
                @min(curr[j] + 1, prev[j + 1] + 1),
                prev[j] + cost,
            );
        }
        const tmp = prev;
        prev = curr;
        curr = tmp;
    }
    return prev[b.len];
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: eval/suggest - editDistance computes the Levenshtein distance between names
test "editDistance basic cases" {
    try testing.expectEqual(@as(usize, 0), editDistance("cap-0402", "cap-0402"));
    try testing.expectEqual(@as(usize, 1), editDistance("cap-0402", "cap-0403"));
    try testing.expectEqual(@as(usize, 2), editDistance("cap-0420", "cap-0402"));
    try testing.expectEqual(@as(usize, 3), editDistance("abc", "xyz"));
    try testing.expectEqual(@as(usize, 4), editDistance("", "abcd"));
}

// spec: eval/suggest - unbound library name yields an import hint naming the missing import
test "unboundMessage suggests import for a library file" {
    // page_allocator: evaluator allocations are never freed (project convention).
    const alloc = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("lib/components");
    try tmp.dir.writeFile(.{ .sub_path = "lib/components/mx66uw-flash.sexp", .data = "(component \"mx66uw-flash\")" });
    const root = try tmp.dir.realpathAlloc(alloc, ".");

    var eval = Evaluator.init(alloc, root);
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();

    const msg = unboundMessage(&eval, "mx66uw-flash", &env);
    try testing.expectEqualStrings("'mx66uw-flash' is in the library — add (import mx66uw-flash)", msg);
}

// spec: eval/suggest - a near-miss name yields a did-you-mean suggestion from env and cache candidates
test "unboundMessage suggests nearest known name" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    try eval.component_cache.put(alloc, "cap-0402", .{
        .name = "cap-0402",
        .symbol_name = "",
        .footprint_name = "",
        .is_family = true,
        .param_type = "",
    });
    var env = Env.init(alloc, null);
    defer env.deinit();

    const msg = unboundMessage(&eval, "cap-0420", &env);
    try testing.expectEqualStrings("unknown name 'cap-0420' — did you mean 'cap-0402'?", msg);
}

// spec: eval/suggest - a name with no close candidate reports a plain unknown-name message
test "unboundMessage falls back to plain unknown name" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();

    const msg = unboundMessage(&eval, "zzz-not-a-thing", &env);
    try testing.expectEqualStrings("unknown name 'zzz-not-a-thing'", msg);
}
