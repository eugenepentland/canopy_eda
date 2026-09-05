//! Suggestion engine for unbound-name diagnostics. When an atom lookup
//! fails, the evaluator asks this module for a better message than a bare
//! "UnboundVariable": either an import hint (the name exists as a library
//! file that just wasn't `(import …)`ed) or a did-you-mean nearest-name
//! suggestion (Levenshtein distance ≤ 2 over env bindings, cached
//! components, and library file stems). Only runs on the error path, so
//! the directory scans are not a hot-path cost.

const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const stdlib = @import("../stdlib.zig");
const env_mod = @import("env.zig");
const Evaluator = @import("evaluator.zig").Evaluator;
const Env = env_mod.Env;

/// Maximum edit distance for a did-you-mean candidate.
pub const max_edit_distance: usize = 2;
/// Names longer than this skip the Levenshtein scan (cost cap; real
/// component names are far shorter). `editDistance` sizes its row buffers
/// from this constant, so every caller must reject longer inputs first.
pub const max_name_len: usize = 64;
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
/// resolves — under the project dir, the shared lib dir, or the bundled
/// standard library. The exact search `(import …)` resolution uses, so the
/// hint never promises a file the resolver would then fail to find.
fn existsInLibrary(self: *Evaluator, name: []const u8) bool {
    for (libRoots(self)) |root| {
        for (lib_prefixes) |prefix| {
            const path = std.fmt.allocPrint(self.allocator, "{s}/{s}{s}.sexp", .{ root, prefix, name }) catch return false;
            defer self.allocator.free(path);
            infra_fs.cwd().access(path, .{}) catch continue;
            return true;
        }
    }
    for (lib_prefixes) |prefix| {
        const sub_path = std.fmt.allocPrint(self.allocator, "{s}{s}.sexp", .{ prefix, name }) catch return false;
        defer self.allocator.free(sub_path);
        if (stdlib.bundled(sub_path) != null) return true;
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
    // The bundled standard library first: its stems are static strings, so a
    // winner needs no dup, and a project that carries the same name simply
    // ties at the same distance.
    for (lib_prefixes) |prefix| {
        var it = stdlib.stems(prefix);
        while (it.next()) |stem| considerCandidate(name, stem, best, best_dist);
    }
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

/// How much editing may still count as the same word. The two settings exist
/// because a suggestion's cost depends entirely on what the caller does with
/// it — see each variant.
pub const Budget = enum {
    /// Two edits regardless of length. For a hint attached to a diagnostic
    /// that has already fired on other grounds, where an off-target
    /// suggestion costs the reader a glance and nothing else.
    advisory,
    /// One edit while either spelling is short, two once both reach
    /// `min_len_for_two_edits`. For a check whose verdict IS the error: at
    /// three or four characters a two-edit budget spans unrelated words —
    /// `mpn` is two edits from `pin` and `color` two from `col`, and both are
    /// real property keys that must keep working.
    strict,
};

/// Shortest spelling for which two edits still mean "the same word".
const min_len_for_two_edits: usize = 5;

/// Best candidate within `budget` of `name` drawn from a FIXED vocabulary —
/// the caller's own list of legal spellings, rather than the evaluator's
/// env/library universe `nearestName` walks. Used by the `(instance …)` body
/// parser to tell a typo'd sub-form (`decuples`) apart from a deliberate
/// inline property key. An exact match is never a suggestion, so a legal
/// spelling can never suggest itself.
pub fn nearestOf(name: []const u8, candidates: []const []const u8, budget: Budget) ?[]const u8 {
    if (name.len > max_name_len) return null;
    var best: ?[]const u8 = null;
    var best_dist: usize = max_edit_distance + 1;
    for (candidates) |candidate| {
        var found: ?[]const u8 = null;
        var dist: usize = max_edit_distance + 1;
        considerCandidate(name, candidate, &found, &dist);
        if (found == null or dist > allowedDistance(budget, name, candidate)) continue;
        if (dist >= best_dist) continue;
        best_dist = dist;
        best = found;
    }
    return best;
}

/// The edit budget for one (name, candidate) pair under `budget`.
fn allowedDistance(budget: Budget, name: []const u8, candidate: []const u8) usize {
    if (budget == .advisory) return max_edit_distance;
    return if (@min(name.len, candidate.len) < min_len_for_two_edits) 1 else max_edit_distance;
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
/// strings (`max_name_len` cap enforced by the callers). Shared with the
/// net-name did-you-mean in `net_suggest.zig`; both inputs must already be
/// `max_name_len` bytes or shorter.
pub fn editDistance(a: []const u8, b: []const u8) usize {
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
    try tmp.dir.createDirPath(std.testing.io, "lib/components");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/mx66uw-flash.sexp", .data = "(component \"mx66uw-flash\")" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

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

// spec: eval/suggest - a fixed vocabulary yields the nearest spelling and never suggests an exact match
test "nearestOf ranks a fixed vocabulary" {
    const vocab = [_][]const u8{ "pin", "part", "note", "col", "decouples", "strap-ok" };
    try testing.expectEqualStrings("decouples", nearestOf("decuples", &vocab, .strict).?);
    try testing.expectEqualStrings("strap-ok", nearestOf("strapok", &vocab, .strict).?);
    try testing.expectEqualStrings("pin", nearestOf("pins", &vocab, .strict).?);
    // An exact spelling never suggests itself, and a distant key is untouched.
    try testing.expect(nearestOf("pin", &vocab, .strict) == null);
    try testing.expect(nearestOf("module-bypass", &vocab, .strict) == null);
    // Two edits on a short word reach unrelated real property keys, so the
    // strict budget stops at one — the advisory budget still offers them.
    try testing.expect(nearestOf("mpn", &vocab, .strict) == null);
    try testing.expect(nearestOf("color", &vocab, .strict) == null);
    try testing.expectEqualStrings("pin", nearestOf("mpn", &vocab, .advisory).?);
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
