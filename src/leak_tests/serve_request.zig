//! Leak-regression tests for the serve request-handler area
//! (api/edit/sync/vfs/mcp/misc).
//!
//! Background: HTTP route handlers receive `ctx.allocator = res.arena`, an
//! httpz per-request arena that is reset after the response is written. The
//! leak class that OOM'd prod was request-path code allocating from
//! `std.heap.page_allocator` (or stashing arena memory into a global) and
//! never freeing — those allocations are invisible to the arena reset and
//! accumulate per request.
//!
//! These tests exercise the area's allocator-taking helpers through
//! `std.testing.allocator` (the leak-detecting allocator). Two idioms are
//! used per the function's ownership contract:
//!
//!   * OWNED-RETURN — the fn returns an owned slice the caller frees AND
//!     frees its own scratch. We call it on `testing.allocator` directly and
//!     free the result; testing.allocator then panics at test-end if the fn
//!     forgot to free any internal scratch. Highest value.
//!   * ARENA-CONTRACT — the fn allocates-and-forgets, relying on the caller's
//!     arena reset (it returns `.items` rather than `toOwnedSlice`, or borrows
//!     across stored scratch). We wrap a `std.heap.ArenaAllocator` backed by
//!     `testing.allocator`; the arena reclaims everything on deinit, so the
//!     test catches crashes/double-frees and any escape to a *different*
//!     allocator (page_allocator / a stored global) while documenting the
//!     contract.
//!
//! All tests are hermetic — no network; filesystem access only through
//! `std.testing.tmpDir` with an absolute project path (so they work
//! regardless of the process cwd, mirroring design_diff.zig's own tests).

const std = @import("std");

const diag_format = @import("../serve/diag_format.zig");
const datasheet_attach = @import("../serve/datasheet_attach.zig");
const design_diff = @import("../serve/design_diff.zig");
const notes = @import("../serve/notes.zig");
const history = @import("../serve/history.zig");
const modules = @import("../serve/modules.zig");
const vfs = @import("../serve/vfs.zig");

const env_mod = @import("../eval/env.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const evaluator_mod = @import("../eval/evaluator.zig");

// A minimal cap family so the evaluator-backed tests can place a passive
// without pulling a real library off disk. Mirrors design_diff.zig's fixture.
const test_cap_family =
    \\(component-family "cap-0402"
    \\  (description "test cap")
    \\  (symbol generic-cap)
    \\  (footprint c-0402)
    \\  (parameter "value" capacitance))
;

// ── diag_format (OWNED-RETURN) ─────────────────────────────────────────────

// leak-audit: build() dupes file/message/source_line into the allocator; the
// caller frees all three. formatText() returns an owned slice and frees its
// own caret scratch (diag_format.zig:115-116). testing.allocator catches a
// forgotten caret free or an over/under-dupe.
test "leak: diag_format build + formatText frees caret scratch" {
    const a = std.testing.allocator;
    const source = "(design-block \"X\"\n  (port 42 in))\n";
    const le = evaluator_mod.EvalDiagnostic{
        .span = .{ .line = 2, .col = 3, .offset = 20 },
        .message = "port name must be a string",
    };
    const d = try diag_format.build(a, "src/x.sexp", source, "InvalidForm", le);
    defer {
        a.free(d.file);
        a.free(d.message);
        a.free(d.source_line);
    }
    const text = try diag_format.formatText(a, d);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "src/x.sexp:2:3") != null);
}

// leak-audit: renderErrorPage builds an ArrayList and frees the interior caret
// slice (diag_format.zig:167-168) before returning the owned page. A leaked
// caret would trip testing.allocator here.
test "leak: diag_format renderErrorPage owns page, frees caret" {
    const a = std.testing.allocator;
    const d = diag_format.Diagnostic{
        .file = "src/x.sexp",
        .line = 4,
        .col = 7,
        .message = "boom",
        .source_line = "  (bad form)",
    };
    const page = try diag_format.renderErrorPage(a, "My Design", d);
    defer a.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "Build error") != null);
}

// ── datasheet_attach (OWNED-RETURN) ────────────────────────────────────────

// leak-audit: spliceDatasheet builds an ArrayList, deinits it on the defer
// (datasheet_attach.zig:52), and returns toOwnedSlice. The caller owns the
// result. testing.allocator catches a missing buf.deinit or a double-free of
// the owned slice.
test "leak: datasheet_attach spliceDatasheet owns result, frees buffer" {
    const a = std.testing.allocator;
    const source =
        \\(component "lt3045"
        \\  (description "LDO")
        \\  (footprint msop-12))
    ;
    const out = try datasheet_attach.spliceDatasheet(a, source, "lt3045.pdf");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "(datasheet \"lt3045.pdf\")") != null);
}

// leak-audit: the error paths (MalformedSource / DuplicateImport) must still
// free the interior ArrayList. A leak on the early-return error path is a
// classic alloc-then-fallible-try miss; testing.allocator catches it.
test "leak: datasheet_attach spliceDatasheet error paths free scratch" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.MalformedSource, datasheet_attach.spliceDatasheet(a, "(design-block \"x\")", "a.pdf"));
    const linked =
        \\(component "lt3045"
        \\  (datasheet "lt3045.pdf"))
    ;
    try std.testing.expectError(error.DuplicateImport, datasheet_attach.spliceDatasheet(a, linked, "lt3045.pdf"));
}

// ── notes (ARENA-CONTRACT) ─────────────────────────────────────────────────

// leak-audit: parseNotes toOwnedSlice's `tasks` but returns the scratchpad as
// a *trimmed view* into an un-deinit'd ArrayList buffer (notes.zig:99-104) —
// when scratchpad content exists that buffer is heap-backed and never freed by
// callers (the request path runs on the arena). We therefore wrap an arena so
// the scratch buffer is reclaimed; testing.allocator still catches any escape
// to page_allocator or a stored global, plus crashes in the parse/render round
// trip.
test "leak: notes parseNotes + renderNotes round-trip under arena contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw =
        \\- [ ] 2026-05-15 (a1b2c3d4) swap PE5 and PE6
        \\- [x] 2026-05-13 -> 2026-05-15 (e5f6a7b8) decoupling rebalanced
        \\
        \\Free-form scratchpad note here.
    ;
    const parsed = try notes.parseNotes(a, raw);
    try std.testing.expectEqual(@as(usize, 2), parsed.tasks.len);
    const rendered = try notes.renderNotes(a, parsed);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "swap PE5 and PE6") != null);
    try std.testing.expect(std.mem.endsWith(u8, rendered, "Free-form scratchpad note here.\n"));
}

// leak-audit: the no-scratchpad path keeps the scratch ArrayList `.empty` (no
// allocation), so renderNotes' only allocation is the owned output slice —
// safe to leak-check directly on testing.allocator (idiom 1).
test "leak: notes renderNotes owns output (no-scratch path)" {
    const a = std.testing.allocator;
    const parsed = try notes.parseNotes(a, "- [ ] 2026-05-15 (a1b2c3d4) tasks only, no scratch\n");
    defer a.free(parsed.tasks);
    try std.testing.expectEqual(@as(usize, 1), parsed.tasks.len);
    const rendered = try notes.renderNotes(a, parsed);
    defer a.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "tasks only") != null);
}

// ── history (OWNED-RETURN, hermetic tmpDir) ────────────────────────────────

// leak-audit: listSnapshots on a project with no history/ dir hits the
// FileNotFound branch and returns an empty toOwnedSlice (history.zig:108) —
// it must still free `dir_path`. testing.allocator catches a leaked dir_path
// on that early-return path.
test "leak: history listSnapshots empty-history path frees dir_path" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(project);

    const snaps = try history.listSnapshots(a, project, "nope");
    defer a.free(snaps);
    try std.testing.expectEqual(@as(usize, 0), snaps.len);
}

// leak-audit: with a populated history/<name>/<id>/ dir, listSnapshots dupes
// each id and reads the optional .note (history.zig:116-120). The caller owns
// the slice AND each id/description. We free them all; a leaked id or note
// buffer trips testing.allocator.
test "leak: history listSnapshots dupes ids + notes, caller frees each" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("history/widget/2026-06-16T10-00-00");
    try tmp.dir.writeFile(.{
        .sub_path = "history/widget/2026-06-16T10-00-00/.note",
        .data = "manual save",
    });
    const project = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(project);

    const snaps = try history.listSnapshots(a, project, "widget");
    defer {
        for (snaps) |s| {
            a.free(s.id);
            if (s.description) |dsc| a.free(dsc);
        }
        a.free(snaps);
    }
    try std.testing.expectEqual(@as(usize, 1), snaps.len);
    try std.testing.expectEqualStrings("2026-06-16T10-00-00", snaps[0].id);
}

// ── vfs (OWNED-RETURN, hermetic) ───────────────────────────────────────────

// leak-audit: dirtyDesignsForPath's src/ branch never touches the filesystem;
// it dupes the basename and toOwnedSlice's a one-element list, with an errdefer
// that frees every element on the error path (vfs.zig:1069-1083). The caller
// owns the slice and each element. testing.allocator catches a leaked element
// or a missing errdefer.
test "leak: vfs dirtyDesignsForPath src branch owns slice + elements" {
    const a = std.testing.allocator;
    const out = try vfs.dirtyDesignsForPath(a, "/unused-project-dir", "src/stm32n6.sexp");
    defer {
        for (out) |d| a.free(d);
        a.free(out);
    }
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("stm32n6", out[0]);
}

// leak-audit: the .bom variant and the sub-path-rejection variant both take
// early `toOwnedSlice` returns; exercising them confirms no scratch escapes
// before the return.
test "leak: vfs dirtyDesignsForPath bom + nested-path early returns" {
    const a = std.testing.allocator;
    const bom = try vfs.dirtyDesignsForPath(a, "/unused", "src/stm32n6.bom");
    defer {
        for (bom) |d| a.free(d);
        a.free(bom);
    }
    try std.testing.expectEqual(@as(usize, 1), bom.len);

    // A nested src path (basename contains '/') returns empty.
    const nested = try vfs.dirtyDesignsForPath(a, "/unused", "src/sub/dir.sexp");
    defer a.free(nested);
    try std.testing.expectEqual(@as(usize, 0), nested.len);
}

// ── modules (ARENA-CONTRACT, hermetic tmpDir) ──────────────────────────────

// leak-audit: collectModules dupes each module base name and renders params via
// moduleMeta → parser_mod.parse (all on the passed allocator) and returns
// `entries.items` *without* toOwnedSlice — an allocate-and-forget that relies
// on the request arena. We wrap an arena so it's reclaimed; testing.allocator
// catches any escape to page_allocator/a global and exercises the dir-scan +
// defmodule-parse path end to end.
test "leak: modules collectModules under arena contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("lib/modules");
    try tmp.dir.writeFile(.{
        .sub_path = "lib/modules/buck.sexp",
        .data =
        \\(defmodule buck (rfbt rfbb)
        \\  "A test buck module"
        \\  (design-block "Buck"))
        ,
    });
    const project = try tmp.dir.realpathAlloc(a, ".");

    const entries = try modules.collectModules(a, project);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("buck", entries[0].name);
}

// leak-audit: collectModules on a project with no lib/modules/ dir returns the
// static empty slice (modules.zig:236) — confirms the missing-dir branch
// allocates nothing that could escape.
test "leak: modules collectModules missing-dir returns empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realpathAlloc(a, ".");
    const entries = try modules.collectModules(a, project);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

// ── design_diff (ARENA-CONTRACT around the pure diff) ──────────────────────

// leak-audit: diffBlocks builds two flattened HashMaps + per-pin "REF.PIN"
// strings as scratch and never frees them (design_diff.zig:127-132 — relies on
// the caller's arena), while its output slices come from the same allocator.
// The input DesignBlocks come from an Evaluator, which by convention never
// frees its AST/component allocations. We run the whole thing on ONE arena
// backed by testing.allocator: the arena reclaims the evaluator AST, the diff
// scratch, AND the diff output on deinit, so testing.allocator verifies every
// byte was freed and catches any escape to page_allocator or a stored global.
test "leak: design_diff diffBlocks scratch reclaimed by arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("lib/components");
    try tmp.dir.writeFile(.{ .sub_path = "lib/components/cap-0402.sexp", .data = test_cap_family });
    const project = try tmp.dir.realpathAlloc(a, ".");

    var old_eval = Evaluator.init(a, project);
    defer old_eval.deinit();
    const old_block = try evalDesign(&old_eval,
        \\(design-block "Rev A"
        \\  (instance "C1" (cap-0402 "100nF")
        \\    (pin 1 "VDD")
        \\    (pin 2 "GND"))
        \\  (instance "C2" (cap-0402 "1uF")
        \\    (pin 1 "VDD")
        \\    (pin 2 "GND")))
    );

    var new_eval = Evaluator.init(a, project);
    defer new_eval.deinit();
    const new_block = try evalDesign(&new_eval,
        \\(design-block "Rev B"
        \\  (instance "C1" (cap-0402 "220nF")
        \\    (pin 1 "VDD")
        \\    (pin 2 "GND"))
        \\  (instance "C3" (cap-0402 "10nF")
        \\    (pin 1 "VIN")
        \\    (pin 2 "GND")))
    );

    const diff = try design_diff.diffBlocks(a, old_block, new_block);
    try std.testing.expectEqual(@as(usize, 1), diff.instances_added.len);
    try std.testing.expectEqual(@as(usize, 1), diff.instances_removed.len);
    try std.testing.expectEqual(@as(usize, 1), diff.value_changes.len);
}

fn evalDesign(eval: *Evaluator, source: []const u8) !*env_mod.DesignBlock {
    const result = try eval.evalSource(source);
    return switch (result) {
        .design_block => |b| b,
        else => error.TestNotADesign,
    };
}
