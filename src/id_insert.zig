//! Source-file ID insertion: writes auto-minted part and sub-block `id`s back
//! into the `.sexp` at the byte spans the evaluator recorded, so a first build
//! persists stable identities without reformatting the rest of the file. A
//! read-modify-write of the design source.

const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const log = @import("infra/log.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;

/// Error set for source-file ID insertion. Combines file IO (read & write)
/// with the allocator failures that can come out of `ArrayList`/dupe, plus
/// `IdCollision` for the duplicate-token guard.
pub const IdInsertError = std.mem.Allocator.Error ||
    std.fs.File.OpenError ||
    std.fs.File.ReadError ||
    std.fs.File.WriteError ||
    std.fs.Dir.MakeError ||
    std.fs.Dir.OpenError ||
    std.fs.Dir.StatFileError ||
    std.posix.RenameError ||
    error{ FileTooBig, StreamTooLong, EndOfStream, IdCollision, WriteFailed };

/// One text insertion against the ORIGINAL source. `order` breaks ties when two
/// edits target the same byte: lower order ends up left of higher order (we want
/// `(id …)` before `(ids …)` on the same parent form).
const Edit = struct {
    pos: usize,
    order: u8,
    text: []const u8,
};

const order_id: u8 = 0;
const order_ids: u8 = 1;

/// Insert pending `(id …)` forms and `(ids ("key" token) …)` child sidecars into
/// a source file in a single pass. Both kinds reference byte offsets in the
/// ORIGINAL source; collecting every edit up front and applying them in
/// descending position order keeps the offsets valid (and lets a decouple/series
/// parent receive its own `(id …)` and its children's `(ids …)` together).
pub fn insertPendingIds(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    pending: []const Evaluator.PendingId,
    pending_child: []const Evaluator.PendingChildId,
) IdInsertError!void {
    if (pending.len == 0 and pending_child.len == 0) return;

    const source = try infra_fs.cwd().readFileAlloc(allocator, source_path, 10 * 1024 * 1024);
    defer allocator.free(source);

    const result = try applyInserts(allocator, source, pending, pending_child);
    defer allocator.free(result);

    // Atomic write: tmp → rename. This is the one path here that mutates a
    // *hand-authored* source file (`src/<design>.sexp`), so a crash mid-write
    // must not truncate/destroy it. Mirrors the tmp→rename idiom in
    // serve/auth_store.zig (no serve/ import — replicated locally).
    var write_buf: [4096]u8 = undefined;
    var atomic = try infra_fs.cwd().atomicFile(source_path, .{ .write_buffer = &write_buf });
    defer atomic.deinit();
    try atomic.file_writer.interface.writeAll(result);
    try atomic.finish();
}

/// Persist an evaluator's auto-minted `(id …)` / `(ids …)` forms back into the
/// design source at `source_path`, exactly as the CLI `netlisp build`
/// (`commands.cmdBuild`) does after eval. The trigger is the same non-empty
/// `pending_ids` / `pending_child_ids` condition `cmdBuild` uses, so a design
/// whose ids are already pinned mints nothing and the file is never rewritten
/// (its sha stays stable — a no-op build must not churn the source). Returns
/// true iff a write happened. Errors are logged and swallowed — id persistence
/// is best-effort, mirroring the CLI's non-fatal handling.
pub fn persistMintedIds(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    eval: *const Evaluator,
) bool {
    if (eval.pending_ids.items.len == 0 and eval.pending_child_ids.items.len == 0) return false;
    insertPendingIds(allocator, source_path, eval.pending_ids.items, eval.pending_child_ids.items) catch |err| {
        log.warn("[id-insert] persist failed for {s}: {s}", .{ source_path, @errorName(err) });
        return false;
    };
    return true;
}

/// Pure core of `insertPendingIds`: given the original `source` bytes, return a
/// freshly allocated copy with all `(id …)` and `(ids …)` insertions applied.
/// Factored out so the edit logic is testable without touching the filesystem.
pub fn applyInserts(
    allocator: std.mem.Allocator,
    source: []const u8,
    pending: []const Evaluator.PendingId,
    pending_child: []const Evaluator.PendingChildId,
) IdInsertError![]u8 {
    try assertTokensUnique(allocator, source, pending, pending_child);

    var edits: std.ArrayList(Edit) = .empty;
    defer {
        for (edits.items) |e| allocator.free(e.text);
        edits.deinit(allocator);
    }

    for (pending) |pid| {
        const close = findMatchingClose(source, pid.form_offset) orelse continue;
        const text = try std.fmt.allocPrint(allocator, " (id {s})", .{pid.id});
        try edits.append(allocator, .{ .pos = close, .order = order_id, .text = text });
    }
    try collectChildIdEdits(allocator, source, pending_child, &edits);

    // Apply largest position first so earlier offsets stay valid; at equal
    // position, higher order first so `(id …)` (order 0) lands left of `(ids …)`.
    std.mem.sort(Edit, edits.items, {}, editBefore);

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, source);
    for (edits.items) |e| {
        if (e.pos > result.items.len) continue;
        try result.insertSlice(allocator, e.pos, e.text);
    }
    return result.toOwnedSlice(allocator);
}

/// Sort predicate: descending position, then descending order.
fn editBefore(_: void, a: Edit, b: Edit) bool {
    if (a.pos != b.pos) return a.pos > b.pos;
    return a.order > b.order;
}

/// Guard: every pending token (both `(id …)` and child-sidecar) must be unique
/// across the pending set AND absent from the source as a delimited atom.
/// `generateId` already guarantees this design-wide, so a hit means a bug or an
/// unsanctioned id rewrite — fail loud rather than splice a duplicate.
fn assertTokensUnique(
    allocator: std.mem.Allocator,
    source: []const u8,
    pending: []const Evaluator.PendingId,
    pending_child: []const Evaluator.PendingChildId,
) IdInsertError!void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    for (pending) |pid| try checkToken(allocator, &seen, source, pid.id, pid.form_offset);
    for (pending_child) |pc| try checkToken(allocator, &seen, source, pc.id, pc.parent_form_offset);
}

fn checkToken(
    allocator: std.mem.Allocator,
    seen: *std.StringHashMapUnmanaged(void),
    source: []const u8,
    id: []const u8,
    offset: u32,
) IdInsertError!void {
    if (seen.contains(id)) {
        reportIdCollision(source, offset, id, "duplicate pending id");
        return IdInsertError.IdCollision;
    }
    try seen.put(allocator, id, {});
    if (sourceHasToken(source, id)) {
        reportIdCollision(source, offset, id, "id already present in source");
        return IdInsertError.IdCollision;
    }
}

/// Group child sidecars by parent and emit one `(ids …)` edit per parent:
/// extend an existing `(ids …)` form when present, otherwise create a fresh one
/// before the parent's closing paren.
fn collectChildIdEdits(
    allocator: std.mem.Allocator,
    source: []const u8,
    pending_child: []const Evaluator.PendingChildId,
    edits: *std.ArrayList(Edit),
) IdInsertError!void {
    if (pending_child.len == 0) return;
    var groups = std.AutoHashMapUnmanaged(u32, std.ArrayList(Evaluator.PendingChildId)).empty;
    defer {
        var dit = groups.valueIterator();
        while (dit.next()) |list| list.deinit(allocator);
        groups.deinit(allocator);
    }
    for (pending_child) |pc| {
        const gop = try groups.getOrPut(allocator, pc.parent_form_offset);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, pc);
    }

    var it = groups.iterator();
    while (it.next()) |entry| {
        const parent_offset = entry.key_ptr.*;
        const group = entry.value_ptr.items;
        const parent_close = findMatchingClose(source, parent_offset) orelse continue;
        if (findExistingIdsForm(source, parent_offset, parent_close)) |ids_close| {
            for (group) |pc| {
                const text = try std.fmt.allocPrint(allocator, " (\"{s}\" {s})", .{ pc.key, pc.id });
                try edits.append(allocator, .{ .pos = ids_close, .order = order_ids, .text = text });
            }
        } else {
            const text = try buildIdsForm(allocator, group);
            try edits.append(allocator, .{ .pos = parent_close, .order = order_ids, .text = text });
        }
    }
}

/// Build a fresh ` (ids ("k1" t1) ("k2" t2) …)` string for a parent's children.
fn buildIdsForm(allocator: std.mem.Allocator, group: []const Evaluator.PendingChildId) IdInsertError![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, " (ids");
    for (group) |pc| {
        const pair = try std.fmt.allocPrint(allocator, " (\"{s}\" {s})", .{ pc.key, pc.id });
        defer allocator.free(pair);
        try buf.appendSlice(allocator, pair);
    }
    try buf.appendSlice(allocator, ")");
    return buf.toOwnedSlice(allocator);
}

/// Within a parent form's span, return the closing-paren position of a direct
/// child `(ids …)` form, or null if none exists yet.
fn findExistingIdsForm(source: []const u8, parent_open: usize, parent_close: usize) ?usize {
    var i = parent_open + 1;
    while (i + 4 <= parent_close) : (i += 1) {
        if (source[i] != '(') continue;
        if (!std.mem.eql(u8, source[i + 1 .. i + 4], "ids")) continue;
        const after = source[i + 4];
        if (isDelim(after)) return findMatchingClose(source, i);
    }
    return null;
}

/// True if `token` appears in `source` as a whole delimited atom (not merely a
/// substring of a longer atom or string), avoiding spurious collision aborts.
fn sourceHasToken(source: []const u8, token: []const u8) bool {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, source, start, token)) |pos| {
        const before_ok = pos == 0 or isDelim(source[pos - 1]);
        const after = pos + token.len;
        const after_ok = after >= source.len or isDelim(source[after]);
        if (before_ok and after_ok) return true;
        start = pos + 1;
    }
    return false;
}

fn isDelim(c: u8) bool {
    return c == '(' or c == ')' or c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '"';
}

/// Log a span-pointed warning when a pending token collides. `offset` is the
/// byte position of the offending form's opening paren; we count newlines up to
/// it to render a 1-based line number.
fn reportIdCollision(source: []const u8, offset: u32, id: []const u8, reason: []const u8) void {
    var line: usize = 1;
    const limit = @min(@as(usize, offset), source.len);
    for (source[0..limit]) |c| {
        if (c == '\n') line += 1;
    }
    log.warn("id-insert collision ({s}): token '{s}' near line {d}", .{ reason, id, line });
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

// spec: id_insert - insertPendingIds aborts on a duplicate pending token
test "applyInserts aborts on duplicate pending token" {
    const alloc = std.testing.allocator;
    const src = "(instance \"R1\" comp)(instance \"R2\" comp)";
    const pending = [_]Evaluator.PendingId{
        .{ .form_offset = 0, .id = "a1b2c3d4" },
        .{ .form_offset = 20, .id = "a1b2c3d4" },
    };
    try std.testing.expectError(IdInsertError.IdCollision, applyInserts(alloc, src, &pending, &.{}));
}

// spec: id_insert - insertPendingIds aborts when a pending id already exists in the source
test "applyInserts aborts when a pending id already exists in the source" {
    const alloc = std.testing.allocator;
    // The source already carries `a1b2c3d4` as a delimited atom (a prior id), so
    // re-minting the same token onto another form must fail rather than splice a
    // duplicate — the checkToken `sourceHasToken` collision path.
    const src = "(instance \"R1\" comp (id a1b2c3d4))(instance \"R2\" comp)";
    const pending = [_]Evaluator.PendingId{
        .{ .form_offset = 34, .id = "a1b2c3d4" },
    };
    try std.testing.expectError(IdInsertError.IdCollision, applyInserts(alloc, src, &pending, &.{}));
}

// spec: id_insert - insertPendingIds writes a child (ids …) sidecar and stays idempotent
test "applyInserts writes child sidecar idempotently" {
    const alloc = std.testing.allocator;
    const src = "(decouple \"VDD\")";
    const child = [_]Evaluator.PendingChildId{
        .{ .parent_form_offset = 0, .key = "100nF@P7#0", .id = "a1b2c3d4" },
    };
    const r1 = try applyInserts(alloc, src, &.{}, &child);
    defer alloc.free(r1);
    try std.testing.expect(std.mem.indexOf(u8, r1, "(ids (\"100nF@P7#0\" a1b2c3d4))") != null);
    const r2 = try applyInserts(alloc, r1, &.{}, &.{});
    defer alloc.free(r2);
    try std.testing.expectEqualStrings(r1, r2);
}

test "applyInserts extends an existing ids sidecar" {
    const alloc = std.testing.allocator;
    const src = "(decouple \"VDD\" (ids (\"a\" b1c2d3e4)))";
    const child = [_]Evaluator.PendingChildId{
        .{ .parent_form_offset = 0, .key = "b", .id = "f5061728" },
    };
    const r1 = try applyInserts(alloc, src, &.{}, &child);
    defer alloc.free(r1);
    try std.testing.expect(std.mem.indexOf(u8, r1, "(\"a\" b1c2d3e4)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1, "(\"b\" f5061728)") != null);
}

test "sourceHasToken matches only a whole delimited atom" {
    // A whole atom mid-string (delimiter before and after) is a match. The
    // `or`→`and` flip would additionally demand pos==0, missing this one.
    try std.testing.expect(sourceHasToken("(ids abcd1234)", "abcd1234"));
    // A whole atom at the very start (pos == 0) matches without reading before it.
    try std.testing.expect(sourceHasToken("abcd1234 tail", "abcd1234"));
    // A mere substring of a longer atom must not match.
    try std.testing.expect(!sourceHasToken("(ids abcd12345)", "abcd1234"));
}

// spec: id_insert - persistMintedIds writes minted ids back like the CLI and is a no-op when nothing is pending
test "persistMintedIds pins hierarchical sub-block ids, stays idempotent, and skips pinned designs" {
    // page_allocator: the evaluator allocates from it and never frees (AST slices
    // reference source buffers), so testing.allocator would flag intentional leaks.
    const alloc = std.heap.page_allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(project_dir);

    try tmp.dir.makePath("lib/components");
    try tmp.dir.makePath("lib/modules");
    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{
        .sub_path = "lib/components/cap.sexp",
        .data =
        \\(component-family cap
        \\  (param-type capacitance)
        \\  (footprint "0402"))
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "lib/components/0402.sexp",
        .data = "(component 0402 (footprint \"0402.kicad_mod\"))",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "lib/modules/mymod.sexp",
        .data =
        \\(defmodule mymod ()
        \\  (design-block "M"
        \\    (import cap)
        \\    (instance "C1" (cap "100nF")
        \\      (pin 1 "VDD")
        \\      (pin 2 "GND"))))
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "src/hier.sexp",
        .data =
        \\(design-block "Hier"
        \\  (hierarchical-ids)
        \\  (import mymod)
        \\  (sub-block "a" (mymod))
        \\  (sub-block "b" (mymod)))
        ,
    });

    const hier_path = try std.fmt.allocPrint(alloc, "{s}/src/hier.sexp", .{project_dir});
    defer alloc.free(hier_path);
    const before = try infra_fs.cwd().readFileAlloc(alloc, hier_path, 1 << 20);
    defer alloc.free(before);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, before, "(id "));

    // First rebuild: the two sub-blocks lack (id …), so persist mints + writes them.
    {
        var eval = Evaluator.init(alloc, project_dir);
        defer eval.deinit();
        _ = try eval.evalFile(hier_path);
        try std.testing.expect(persistMintedIds(alloc, hier_path, &eval));
    }
    const after1 = try infra_fs.cwd().readFileAlloc(alloc, hier_path, 1 << 20);
    defer alloc.free(after1);
    try std.testing.expect(!std.mem.eql(u8, before, after1));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, after1, "(id "));

    // Second rebuild: ids are now pinned, nothing pending → no write, bytes stable.
    {
        var eval = Evaluator.init(alloc, project_dir);
        defer eval.deinit();
        _ = try eval.evalFile(hier_path);
        try std.testing.expect(!persistMintedIds(alloc, hier_path, &eval));
    }
    const after2 = try infra_fs.cwd().readFileAlloc(alloc, hier_path, 1 << 20);
    defer alloc.free(after2);
    try std.testing.expectEqualStrings(after1, after2);

    // A flat design whose instance already carries an (id …) mints nothing — the
    // trigger matches the CLI's, so an already-pinned flat/legacy file is untouched.
    try tmp.dir.writeFile(.{
        .sub_path = "src/flat.sexp",
        .data =
        \\(design-block "Flat"
        \\  (import cap)
        \\  (instance "C9" (cap "100nF") (id aabbccdd)
        \\    (pin 1 "VDD")
        \\    (pin 2 "GND")))
        ,
    });
    const flat_path = try std.fmt.allocPrint(alloc, "{s}/src/flat.sexp", .{project_dir});
    defer alloc.free(flat_path);
    const flat_before = try infra_fs.cwd().readFileAlloc(alloc, flat_path, 1 << 20);
    defer alloc.free(flat_before);
    {
        var eval = Evaluator.init(alloc, project_dir);
        defer eval.deinit();
        _ = try eval.evalFile(flat_path);
        try std.testing.expect(!persistMintedIds(alloc, flat_path, &eval));
    }
    const flat_after = try infra_fs.cwd().readFileAlloc(alloc, flat_path, 1 << 20);
    defer alloc.free(flat_after);
    try std.testing.expectEqualStrings(flat_before, flat_after);
}
