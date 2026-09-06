//! Does `src/test_shards.zig` still claim every named test in `src/`?
//!
//! The shard manifest is a hand-maintained list of `--test-filter` substrings.
//! A new test-bearing module needs an entry there as well as an import in
//! `src/test_root.zig`, and the two failures look nothing alike:
//!
//!   * Missing from `test_root.zig` — the module is never analyzed, so its
//!     tests compile into no binary. Guardian's `test-reachability` check
//!     catches this on every `zig build`, in seconds.
//!   * Missing from `test_shards.zig` — the module compiles, its tests exist,
//!     and no shard's filter selects them. Every shard reports PASS while the
//!     tests never run. `zig build` was GREEN for this; only a full or affected
//!     test run reached the invariant test that catches it, which is how a
//!     release gate once spent 118 seconds to report five missing registrations
//!     and cancelled its concurrent build.
//!
//! That asymmetry is what this module removes. The scan is pure — source text
//! plus the manifest's own literals, no compiler and no test binary — so
//! `netlisp check-test-manifest` answers in the time a directory walk takes and
//! `zig build` runs it beside the generated-docs check.
//!
//! There is exactly ONE implementation of the claim rule. `src/test_root.zig`'s
//! invariant test calls the functions here rather than carrying its own copy:
//! a build-time check that disagreed with the test-time check would be worse
//! than neither.
//!
//! The scan is deliberately raw source text, not a Zig parse. The compiler's
//! own list of tests is exactly what a shard filter already produced, so
//! deriving the expectation from it would check the manifest against itself.

const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const test_shards = @import("test_shards.zig");

/// Largest Zig source file the scan will read. Deliberately not the 10 MiB
/// DESIGN-source limit the `.sexp` readers share: a different fact about a
/// different kind of file, and the largest .zig in this tree is a fraction of it.
const max_zig_source_bytes: usize = 4 * 1024 * 1024;

/// What the scan can fail with: the caller's allocator, and reading `src/`.
pub const ScanError = std.mem.Allocator.Error ||
    infra_fs.Dir.OpenError ||
    std.Io.Dir.ReadFileAllocError ||
    infra_fs.Walker.Error;

/// Below this, the scan found so little that every assertion over it would be
/// vacuous — a wrong working directory, not a clean tree.
pub const min_expected_tests: usize = 2000;

/// One fully-qualified test name, spelled the way Zig names it for
/// `--test-filter`: the source path relative to `src/` with separators as dots,
/// then `.test.`, then the declared name.
pub const QualifiedName = []const u8;

/// A test the manifest does not claim exactly once.
pub const Unclaimed = struct {
    name: QualifiedName,
    /// How many shards would compile it: 0 = never runs, >1 = runs twice.
    claims: usize,
};

pub const Report = struct {
    /// Every named test found in `src/`.
    scanned: usize = 0,
    /// The ones no shard claims, or more than one shard claims.
    problems: []const Unclaimed = &.{},
    /// Filters in the manifest that name no test at all — a renamed or deleted
    /// test leaves one behind, and it silently claims nothing.
    dead_filters: []const []const u8 = &.{},
    /// Modules whose tests exist but which `src/test_root.zig` does not import
    /// EXPLICITLY. A module reachable only through another module's test body
    /// stops being analyzed the moment that body is filtered into a different
    /// shard, and its own tests then compile into no binary at all.
    missing_imports: []const []const u8 = &.{},

    pub fn ok(self: Report) bool {
        return self.problems.len == 0 and self.dead_filters.len == 0 and
            self.missing_imports.len == 0 and self.scanned >= min_expected_tests;
    }
};

/// Read every named test in `src/` into `arena`.
///
/// Unnamed `test { }` blocks are skipped: the compiler links them into every
/// filtered binary whatever the filters say, so no shard has to claim them.
pub fn collectQualifiedNames(
    arena: std.mem.Allocator,
    out: *std.ArrayList(QualifiedName),
) ScanError!void {
    return collectQualifiedNamesIn(arena, infra_fs.cwd(), out);
}

/// `collectQualifiedNames` against an explicit root, so a test can point the
/// scan at a directory with no `src/` and see the failure it would report.
pub fn collectQualifiedNamesIn(
    arena: std.mem.Allocator,
    root: infra_fs.Dir,
    out: *std.ArrayList(QualifiedName),
) ScanError!void {
    var src = try root.openDir("src", .{ .iterate = true });
    defer src.close();
    var walker = try src.walk(arena);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const source = try src.readFileAlloc(arena, entry.path, max_zig_source_bytes);
        const prefix = try qualifiedPrefix(arena, entry.path);
        try appendNamedTests(arena, out, prefix, source);
    }
}

/// `placement/router.zig` → `placement.router.test.`
pub fn qualifiedPrefix(arena: std.mem.Allocator, rel_path: []const u8) std.mem.Allocator.Error![]const u8 {
    const stem = rel_path[0 .. rel_path.len - ".zig".len];
    const dotted = try arena.dupe(u8, stem);
    std.mem.replaceScalar(u8, dotted, std.fs.path.sep, '.');
    return std.mem.concat(arena, u8, &.{ dotted, ".test." });
}

/// Append `prefix ++ <declared name>` for every `test "..." {` in `source`.
///
/// Only a declaration at the START of a line counts, which is what makes the
/// scan agree with the compiler on this tree: the same rule reproduces the
/// suite's test count exactly, and it is why a `test "` inside a string literal
/// or a comment is not collected.
///
/// Line-oriented rather than byte-oriented on purpose. The form this replaced
/// walked ~30 MB of Zig source one index at a time, which cost seconds in a
/// Debug build — too much for a check that runs on every `zig build`.
/// Splitting on newlines and testing the prefix is the same rule at a
/// fraction of the work.
pub fn appendNamedTests(
    arena: std.mem.Allocator,
    out: *std.ArrayList(QualifiedName),
    prefix: []const u8,
    source: []const u8,
) std.mem.Allocator.Error!void {
    const opener = "test \"";
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, opener)) continue;
        const body = line[opener.len..];
        const end = std.mem.indexOfScalar(u8, body, '"') orelse continue;
        try out.append(arena, try std.mem.concat(arena, u8, &.{ prefix, body[0..end] }));
    }
}

/// A shard filter, split once at its `.test.` on the way in.
///
/// Every filter in the manifest has the shape `<module>.test.<name prefix>`,
/// and so does every qualified test name — and a name contains `.test.` exactly
/// once. So `indexOf(name, filter) != null` is equivalent to: the name's module
/// part ENDS WITH the filter's module part, and the name's test part STARTS
/// WITH the filter's. That equivalence is what preserves the manifest's
/// documented unanchored matching, where `exit.test.` also selects
/// `placement.pad_exit.test.*`.
///
/// Splitting once turns 3.1 million `indexOf` scans (5,036 names × 621 filters,
/// ~2.7 s in a Debug build) into the same number of `endsWith`/`startsWith`
/// comparisons that fail on their first byte. A filter that somehow lacks
/// `.test.` keeps the literal `indexOf`, so the shape is an optimisation, never
/// an assumption the answer depends on. `the split match agrees with a literal
/// substring search` holds the two forms together.
const Filter = struct {
    literal: []const u8,
    /// Which shard declared it.
    shard: usize = 0,
    /// Text before `.test.`, or null when the filter has no `.test.`.
    module: ?[]const u8 = null,
    /// Text after `.test.`.
    name_prefix: []const u8 = "",

    fn init(literal: []const u8, shard: usize) Filter {
        const at = std.mem.indexOf(u8, literal, test_infix) orelse
            return .{ .literal = literal, .shard = shard };
        return .{
            .literal = literal,
            .shard = shard,
            .module = literal[0..at],
            .name_prefix = literal[at + test_infix.len ..],
        };
    }

    /// The half of the match a whole source file shares.
    fn acceptsModule(self: Filter, module: []const u8) bool {
        const own = self.module orelse return true; // decided per name instead
        return std.mem.endsWith(u8, module, own);
    }

    /// The half that varies test by test. Only asked of a filter whose module
    /// already accepted.
    fn acceptsName(self: Filter, name: QualifiedName) bool {
        const own = self.module orelse return std.mem.indexOf(u8, name, self.literal) != null;
        _ = own;
        const at = std.mem.indexOf(u8, name, test_infix) orelse
            return std.mem.indexOf(u8, name, self.literal) != null;
        return std.mem.startsWith(u8, name[at + test_infix.len ..], self.name_prefix);
    }

    fn matches(self: Filter, name: QualifiedName) bool {
        return self.acceptsModule(moduleOf(name)) and self.acceptsName(name);
    }
};

/// The per-name set of shards that claimed it, one flag per shard. Sized well
/// above the dozen the manifest declares; `the shard count fits the claim set`
/// fails loudly if a future split ever outgrows it.
const ShardSet = [max_shards]bool;
const max_shards: usize = 64;

const test_infix = ".test.";

/// How many shards would compile `name` into their binary.
pub fn claimingShards(name: QualifiedName) usize {
    var claims: usize = 0;
    for (test_shards.shards) |shard| {
        for (shard) |filter| {
            if (Filter.init(filter, 0).matches(name)) {
                claims += 1;
                break;
            }
        }
    }
    return claims;
}

/// Scan `src/` and check it against the manifest. Everything returned is owned
/// by `arena`.
pub fn audit(arena: std.mem.Allocator) ScanError!Report {
    return auditIn(arena, infra_fs.cwd());
}

/// `audit` against an explicit root.
///
/// ONE pass over names × filters, not two. The obvious shape — count each
/// name's claims, then ask separately whether each filter still names any test
/// — sweeps the same 5,000 × 600 product twice, and this runs on every
/// `zig build`. Recording which filters matched while counting claims makes the
/// dead-filter answer free, and a filter already known to match is not tested
/// again once its shard has claimed the name: there is nothing left to learn
/// from it, and after the first few hundred names that is nearly all of them.
pub fn auditIn(arena: std.mem.Allocator, root: infra_fs.Dir) ScanError!Report {
    var names: std.ArrayList(QualifiedName) = .empty;
    try collectQualifiedNamesIn(arena, root, &names);

    var filters: std.ArrayList(Filter) = .empty;
    for (test_shards.shards, 0..) |shard, shard_index| {
        for (shard) |filter| try filters.append(arena, .init(filter, shard_index));
    }
    const matched = try arena.alloc(bool, filters.items.len);
    @memset(matched, false);

    // Names arrive grouped by source file, so consecutive names share a module,
    // and which filters can possibly match is decided by the MODULE alone. The
    // candidate list is therefore computed once per file (~640 times) instead of
    // once per test (~5,000): the naive form is 3.1 million module comparisons
    // and this is under 400,000, with only a handful of name-prefix checks left
    // per test.
    var problems: std.ArrayList(Unclaimed) = .empty;
    var module: ?[]const u8 = null;
    var candidates: std.ArrayList(usize) = .empty;
    for (names.items) |name| {
        const this_module = moduleOf(name);
        if (module == null or !std.mem.eql(u8, module.?, this_module)) {
            module = this_module;
            candidates.clearRetainingCapacity();
            for (filters.items, 0..) |filter, i| {
                if (filter.acceptsModule(this_module)) try candidates.append(arena, i);
            }
        }
        // A shard claims a name once, however many of its filters match it, so
        // the claim count is over SHARDS, not over matching filters.
        var claimed_shards: ShardSet = @splat(false);
        for (candidates.items) |i| {
            if (!filters.items[i].acceptsName(name)) continue;
            matched[i] = true;
            claimed_shards[filters.items[i].shard] = true;
        }
        var claims: usize = 0;
        for (claimed_shards) |claimed| claims += @intFromBool(claimed);
        if (claims != 1) try problems.append(arena, .{ .name = name, .claims = claims });
    }

    var dead: std.ArrayList([]const u8) = .empty;
    for (filters.items, matched) |filter, seen| {
        if (!seen) try dead.append(arena, filter.literal);
    }

    return .{
        .scanned = names.items.len,
        .problems = problems.items,
        .dead_filters = dead.items,
        .missing_imports = try missingImports(arena, root, names.items),
    };
}

/// The `<module>` half of a qualified test name, or the whole name when it
/// somehow carries no `.test.`.
fn moduleOf(name: QualifiedName) []const u8 {
    const at = std.mem.indexOf(u8, name, test_infix) orelse return name;
    return name[0..at];
}

/// Modules with named tests that `src/test_root.zig` does not import outright.
///
/// The THIRD registration a new test-bearing module needs, after the test-root
/// import and the shard filter — and the one that is invisible until a full run:
/// a module reachable only through some other module's test body is analyzed
/// today and silently dropped the moment that body moves to a different shard.
/// This was found the hard way, by a commit in this same session that added
/// tests to a module already reachable transitively; `zig build` was green and
/// only the whole suite caught it.
fn missingImports(
    arena: std.mem.Allocator,
    root: infra_fs.Dir,
    names: []const QualifiedName,
) ScanError![]const []const u8 {
    const source = root.readFileAlloc(arena, test_root_path, max_zig_source_bytes) catch return &.{};
    var missing: std.ArrayList([]const u8) = .empty;
    var checked: std.StringHashMapUnmanaged(void) = .empty;
    for (names) |name| {
        const module = moduleOf(name);
        // The root IS the compilation's root file, never an import of itself.
        if (std.mem.eql(u8, module, test_root_module)) continue;
        if (checked.contains(module)) continue;
        try checked.put(arena, module, {});
        const rel = try arena.dupe(u8, module);
        std.mem.replaceScalar(u8, rel, '.', '/');
        const import = try std.mem.concat(arena, u8, &.{ "_ = @import(\"", rel, ".zig\");" });
        if (std.mem.indexOf(u8, source, import) == null) try missing.append(arena, import);
    }
    return missing.items;
}

const test_root_path = "src/test_root.zig";
const test_root_module = "test_root";

/// Render a report for a human, and say what to do about it. Returns true when
/// the manifest is intact.
pub fn writeReport(w: *std.Io.Writer, report: Report) std.Io.Writer.Error!bool {
    if (report.scanned < min_expected_tests) {
        try w.print(
            "test-manifest: scanned only {d} named test(s) — run from the repository root\n",
            .{report.scanned},
        );
        return false;
    }
    for (report.problems) |problem| {
        try w.print("test-manifest: {d} shard(s) claim \"{s}\" (want exactly 1)\n", .{ problem.claims, problem.name });
    }
    for (report.dead_filters) |filter| {
        try w.print("test-manifest: filter \"{s}\" names no test\n", .{filter});
    }
    for (report.missing_imports) |import| {
        try w.print("test-manifest: src/test_root.zig is missing {s}\n", .{import});
    }
    if (!report.ok()) {
        try w.print(
            "test-manifest: FAIL — {d} unclaimed/duplicated, {d} dead filter(s), {d} missing import(s) of {d} named test(s).\n" ++
                "  A new test-bearing module needs BOTH an explicit import in src/test_root.zig\n" ++
                "  and a filter in src/test_shards.zig. Without the import its tests are dropped\n" ++
                "  as soon as whatever reached it moves shards; without the filter they compile\n" ++
                "  and never run.\n",
            .{ report.problems.len, report.dead_filters.len, report.missing_imports.len, report.scanned },
        );
        return false;
    }
    try w.print("test-manifest OK: {d} named test(s), each claimed by exactly one shard\n", .{report.scanned});
    return true;
}

/// Scan, check, and write the verdict. Returns true when the manifest is
/// intact. This is the whole `netlisp check-test-manifest` command: the scan's
/// own failure is reported HERE, as a usage error rather than as a manifest
/// verdict, so the caller has one bool and no error to interpret.
pub fn checkAndReport(arena: std.mem.Allocator, w: *std.Io.Writer) std.Io.Writer.Error!bool {
    return checkAndReportIn(arena, infra_fs.cwd(), w);
}

/// `checkAndReport` against an explicit root.
pub fn checkAndReportIn(
    arena: std.mem.Allocator,
    root: infra_fs.Dir,
    w: *std.Io.Writer,
) std.Io.Writer.Error!bool {
    const report = auditIn(arena, root) catch |err| {
        try w.print(
            "test-manifest: cannot scan src/ ({s}) — run from the repository root\n",
            .{@errorName(err)},
        );
        return false;
    };
    return writeReport(w, report);
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: test manifest - only a test declaration at the start of a line is collected, and an unnamed test block is not
test "the scan collects named tests and skips unnamed blocks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(QualifiedName) = .empty;
    try appendNamedTests(arena, &out,
        \\demo.test.
    , "test \"alpha\" {}\ntest {\n    _ = @import(\"x.zig\");\n}\ntest \"beta\" {}\n");
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("demo.test.alpha", out.items[0]);
    try testing.expectEqualStrings("demo.test.beta", out.items[1]);

    // A `test "` that is not at the start of a line — inside a string literal
    // or a comment — is not a declaration and must not be collected.
    var indented: std.ArrayList(QualifiedName) = .empty;
    try appendNamedTests(arena, &indented, "demo.test.", "const s = \"test \\\"gamma\\\"\";\n// test \"delta\" {}\n");
    try testing.expectEqual(@as(usize, 0), indented.items.len);
}

// spec: test manifest - a source path becomes the dotted prefix the compiler names its tests with
test "a source path becomes its dotted test-name prefix" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("placement.router.test.", try qualifiedPrefix(arena, "placement/router.zig"));
    try testing.expectEqualStrings("main.test.", try qualifiedPrefix(arena, "main.zig"));
}

// spec: test manifest - this tree's shard manifest claims every named test exactly once and carries no dead filter
test "the committed manifest claims every named test exactly once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const report = try audit(arena_state.allocator());
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    _ = try writeReport(&out.writer, report);
    // Asserted on the TEXT, not on the bool: a failure then names the module
    // that was forgotten instead of printing `expected true, found false`.
    try testing.expectStringStartsWith(out.written(), "test-manifest OK:");
    // A scan that found almost nothing would make the assertion above vacuous.
    try testing.expect(report.scanned >= min_expected_tests);
}

// spec: test manifest - a test no shard claims is reported as unclaimed rather than passing silently
test "an unclaimed test is reported, and a report with problems is not ok" {
    // `claimingShards` against a name no filter can match: the exact shape of a
    // module registered in test_root.zig and forgotten in test_shards.zig.
    try testing.expectEqual(@as(usize, 0), claimingShards("zz_no_such_module.test.a test nothing claims"));
    const failing: Report = .{
        .scanned = min_expected_tests + 1,
        .problems = &.{.{ .name = "zz_no_such_module.test.x", .claims = 0 }},
    };
    try testing.expect(!failing.ok());
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    try testing.expect(!try writeReport(&out.writer, failing));
    try testing.expect(std.mem.indexOf(u8, out.written(), "zz_no_such_module.test.x") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "src/test_shards.zig") != null);
}

// spec: test manifest - a scan that found almost no tests fails rather than reporting a vacuous pass
test "a near-empty scan fails instead of passing vacuously" {
    const empty: Report = .{ .scanned = 3 };
    try testing.expect(!empty.ok());
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    try testing.expect(!try writeReport(&out.writer, empty));
    try testing.expect(std.mem.indexOf(u8, out.written(), "repository root") != null);
}

// spec: test manifest - a scan pointed at a tree with no src directory reports the read failure as a usage error rather than an empty pass
test "a missing src directory is a reported usage error, not an empty scan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var names: std.ArrayList(QualifiedName) = .empty;
    try testing.expectError(
        error.FileNotFound,
        collectQualifiedNamesIn(arena, .{ .d = tmp.dir }, &names),
    );
    // …and the command turns that into a usage message and a failing verdict,
    // never into "0 problems found".
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    try testing.expect(!try checkAndReportIn(arena, .{ .d = tmp.dir }, &out.writer));
    try testing.expect(std.mem.indexOf(u8, out.written(), "cannot scan src/") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "FileNotFound") != null);
}

// spec: test manifest - the shard count fits the per-name claim set
test "the shard count fits the claim set" {
    try testing.expect(test_shards.shards.len <= max_shards);
}

// spec: test manifest - the split module/name match agrees with a literal substring search over the real manifest
test "the split match agrees with a literal substring search" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var names: std.ArrayList(QualifiedName) = .empty;
    try collectQualifiedNames(arena, &names);
    try testing.expect(names.items.len >= min_expected_tests);

    // The fast path exists only because it is EQUIVALENT to `indexOf`. Checked
    // against every filter in the committed manifest, over a bounded slice of
    // real names — including the unanchored case the manifest documents, where
    // `exit.test.` also selects `placement.pad_exit.test.*`.
    const sample = names.items[0..@min(names.items.len, 400)];
    for (test_shards.shards) |shard| {
        for (shard) |literal| {
            const filter: Filter = .init(literal, 0);
            for (sample) |name| {
                try testing.expectEqual(std.mem.indexOf(u8, name, literal) != null, filter.matches(name));
            }
        }
    }
    const unanchored: Filter = .init("exit.test.", 0);
    try testing.expect(unanchored.matches("placement.pad_exit.test.a corner"));
    try testing.expect(!unanchored.matches("placement.pad_exit.other.a corner"));
    // A filter with no `.test.` at all keeps the literal substring rule.
    const literal_only: Filter = .init("router", 0);
    try testing.expect(literal_only.matches("placement.router.test.x"));
    try testing.expect(!literal_only.matches("placement.drc.test.x"));
}

// spec: test manifest - a module whose tests exist but which the test root does not import outright is reported
test "a module the test root does not import outright is reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The real tree is intact, and every module it declares tests for is bridged.
    const report = try audit(arena);
    try testing.expectEqual(@as(usize, 0), report.missing_imports.len);

    // A module nothing imports is reported by its exact import line — the third
    // registration a new test-bearing module needs, and the one that stays
    // invisible until a whole-suite run.
    const invented = try missingImports(arena, infra_fs.cwd(), &.{"zz_not_a_module.test.some test"});
    try testing.expectEqual(@as(usize, 1), invented.len);
    try testing.expectEqualStrings("_ = @import(\"zz_not_a_module.zig\");", invented[0]);

    const failing: Report = .{
        .scanned = min_expected_tests + 1,
        .missing_imports = &.{"_ = @import(\"zz_not_a_module.zig\");"},
    };
    try testing.expect(!failing.ok());
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    try testing.expect(!try writeReport(&out.writer, failing));
    try testing.expect(std.mem.indexOf(u8, out.written(), "zz_not_a_module.zig") != null);
}
