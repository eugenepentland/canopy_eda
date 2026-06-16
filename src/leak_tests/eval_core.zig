//! Leak-regression tests for the evaluator core + types area.
//!
//! These run under `std.testing.allocator`, which panics at test end if
//! anything allocated *through it* was not freed. The functions exercised
//! here are the ones that genuinely own/return heap and are expected to be
//! leak-clean through whatever allocator the caller hands them:
//!
//!   • `fmt.format`            — returns an owned slice, frees its own scratch
//!                               (incl. the mid-template error path, where an
//!                               `errdefer buf.deinit` must reclaim the partial
//!                               buffer).
//!   • `env.requirementIdForText` — pure owned-return, no internal scratch.
//!   • `env.parseCheck`        — allocates a pins slice into the caller's
//!                               allocator (arena-contract on the serve path).
//!   • `Env` / `Evaluator`     — init/deinit store lifecycle.
//!
//! Deliberately NOT tested against testing.allocator: the DesignBlock / Net /
//! Port graph, `Evaluator`'s internal caches (loaded_files / component_cache /
//! symbol_pin_cache / design_ids / pending_ids), and every `generateId` /
//! `deriveChildId` result. Those are allocated from the evaluator's allocator
//! and intentionally never freed (page_allocator-by-convention; on the serve
//! path the request arena reclaims them). A testing.allocator test expecting
//! them freed would false-fail. Where such a path is touched here it is wrapped
//! in an arena (idiom 2) so testing.allocator only verifies nothing escaped to
//! a *different* allocator.

const std = @import("std");
const env = @import("../eval/env.zig");
const fmt = @import("../eval/fmt.zig");
const evaluator = @import("../eval/evaluator.zig");
const parser = @import("../sexpr/parser.zig");

const Value = env.Value;
const Env = env.Env;
const Evaluator = evaluator.Evaluator;

// ── fmt.format: owned-return + internal-scratch (idiom 1) ──────────────

// leak-audit: format() returns an owned slice and frees its ArrayList scratch;
// testing.allocator flags any internal buffer it forgot to release.
test "leak: fmt.format owned-return frees internal scratch" {
    const alloc = std.testing.allocator;
    const args = [_]Value{ .{ .number = 220000.0 }, .{ .number = 47000.0 } };
    const out = try fmt.format(alloc, "RFBT = ~R, RFBB = ~R; tilde ~~ done", &args);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("RFBT = 220k, RFBB = 47k; tilde ~ done", out);
}

// leak-audit: the mid-template error path — bytes already written to `buf`,
// then `~V` with no argument errors out. The `errdefer buf.deinit(allocator)`
// in format() must reclaim that partial buffer or testing.allocator panics.
test "leak: fmt.format error path frees partial buffer" {
    const alloc = std.testing.allocator;
    // "prefix " is written, then ~V consumes a (missing) numeric arg → NotEnoughArgs.
    try std.testing.expectError(
        fmt.FmtError.NotEnoughArgs,
        fmt.format(alloc, "prefix ~V suffix", &[_]Value{}),
    );
}

// leak-audit: a type-mismatch mid-template (string arg where ~V wants a number)
// is the other early-return through the errdefer; same partial-buffer reclaim.
test "leak: fmt.format type-error path frees partial buffer" {
    const alloc = std.testing.allocator;
    const args = [_]Value{.{ .string = "not-a-number" }};
    try std.testing.expectError(
        fmt.FmtError.TypeError,
        fmt.format(alloc, "leading text ~V trailing", &args),
    );
}

// ── env.requirementIdForText: pure owned-return (idiom 1) ──────────────

// leak-audit: returns an allocPrint'd 8-hex slice the caller owns; no scratch.
// testing.allocator confirms the single allocation is exactly the one we free.
test "leak: requirementIdForText owned-return is leak-clean" {
    const alloc = std.testing.allocator;
    const id = try env.requirementIdForText(alloc, "VDD must be decoupled with 100nF within 3mm");
    defer alloc.free(id);
    try std.testing.expectEqual(@as(usize, 8), id.len);
    // CRC32 hex is deterministic — a second call yields the same string and is
    // independently freed, proving no shared/aliased allocation lingers.
    const id2 = try env.requirementIdForText(alloc, "VDD must be decoupled with 100nF within 3mm");
    defer alloc.free(id2);
    try std.testing.expectEqualStrings(id, id2);
}

// ── env.parseCheck: caller-allocator pins slice (idiom 1) ──────────────

// leak-audit: parseCheck builds the pins list via the passed allocator and
// hands back an owned slice. AST inputs are built in a separate arena so the
// ONLY testing.allocator allocation is the returned `pins` slice, which we free
// — catching any extra scratch toOwnedSlice might have left behind.
test "leak: parseCheck pins-on-same-net owned slice frees clean" {
    var ia = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ia.deinit();

    const src =
        \\(check (pins-on-same-net (pins "VSS_1" "VSS_2" "EP")))
    ;
    const nodes = try parser.parse(ia.allocator(), src);

    const check = env.parseCheck(std.testing.allocator, nodes[0]) orelse
        return error.TestExpectedCheck;
    try std.testing.expect(std.meta.activeTag(check) == .pins_on_same_net);
    const c = check.pins_on_same_net;
    defer std.testing.allocator.free(c.pins);
    try std.testing.expectEqual(@as(usize, 3), c.pins.len);
    try std.testing.expectEqualStrings("EP", c.pins[2]);
}

// leak-audit: the decoupling-per-pin variant also toOwnedSlice's a pins list
// through the caller allocator — same ownership contract, freed here.
test "leak: parseCheck decoupling-per-pin owned slice frees clean" {
    var ia = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ia.deinit();

    const src =
        \\(check (decoupling-per-pin (return-pin "GND") (pins "VDD_1" "VDD_2") (min-uf 0.1) (count 2)))
    ;
    const nodes = try parser.parse(ia.allocator(), src);

    const check = env.parseCheck(std.testing.allocator, nodes[0]) orelse
        return error.TestExpectedCheck;
    try std.testing.expect(std.meta.activeTag(check) == .decoupling_per_pin);
    const c = check.decoupling_per_pin;
    defer std.testing.allocator.free(c.pins);
    try std.testing.expectEqual(@as(usize, 2), c.pins.len);
    try std.testing.expectEqual(@as(u32, 2), c.count);
}

// ── Env store lifecycle (idiom 3) ──────────────────────────────────────

// leak-audit: Env.deinit must release the bindings map even after overwrites
// and a nested child scope. Keys/values are borrowed (no per-entry free), so
// the only tracked allocation is the map's backing storage.
test "leak: Env init/deinit releases bindings after overwrite + child scope" {
    const alloc = std.testing.allocator;
    var parent = Env.init(alloc, null);
    defer parent.deinit();
    try parent.put("x", .{ .number = 1.0 });
    try parent.put("x", .{ .number = 2.0 }); // overwrite — must not grow leaked entries
    try parent.put("y", .{ .string = "hi" });

    var child = Env.init(alloc, &parent);
    defer child.deinit();
    try child.put("z", .{ .boolean = true });

    try std.testing.expectEqual(@as(f64, 2.0), child.get("x").?.asNumber().?);
    try std.testing.expect(child.get("z").?.asBool().?);
}

// ── Evaluator store lifecycle, no internal allocations (idiom 3) ───────

// leak-audit: a bare Evaluator.init/deinit with no evaluation populates none
// of the by-convention-leaked caches, so its container teardown is leak-clean
// under testing.allocator. This pins that deinit() frees every container field
// it owns (assertions, warnings, module_stack, the six caches, the two pending
// lists, design_ids) — a missed field would surface here as a leak.
test "leak: Evaluator init/deinit with no eval is leak-clean" {
    const alloc = std.testing.allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    // Touch only container metadata — nothing that dups keys/values in.
    try std.testing.expectEqual(@as(usize, 0), eval.assertions.items.len);
    try std.testing.expectEqual(@as(usize, 0), eval.pending_ids.items.len);
}

// leak-audit: assert-range appends one assertion whose message is dup'd via the
// evaluator allocator. Here that allocator IS testing.allocator, so freeing the
// message and deinit'ing the evaluator must leave nothing behind. Mirrors the
// existing evaluator.zig "eval assert-range pass" test's cleanup contract,
// pinned as a leak regression for the one allocate-and-store path that uses the
// passed allocator directly (not the page_allocator convention).
test "leak: assert-range message + assertions list freed clean" {
    const alloc = std.testing.allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var scope = Env.init(alloc, null);
    defer scope.deinit();

    const src = "(let v 3.3) (assert-range v 0.6 16.0 \"VOUT\")";
    const nodes = try parser.parse(alloc, src);
    defer parser.freeNodes(alloc, nodes);

    _ = try eval.evalNodes(nodes, &scope);
    try std.testing.expectEqual(@as(usize, 1), eval.assertions.items.len);
    // The assert-range message is the lone evaluator-allocated owned string on
    // this path; free it so testing.allocator sees a balanced ledger.
    alloc.free(eval.assertions.items[0].message);
}

// ── Module call path, arena-wrapped (idiom 2) ──────────────────────────

// leak-audit: callModule allocs a `bound` scratch array (freed via defer) and a
// child Env (deinit'd via defer), plus argument Values that follow the
// page_allocator convention. Wrapping the whole evaluation in an arena lets
// testing.allocator verify (a) no crash/double-free on this path and (b)
// nothing escaped to a DIFFERENT testing-backed allocator. The by-convention
// allocations are reclaimed wholesale by the arena, exactly as the request
// arena does on the serve path.
test "leak: module call path is arena-contained" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var eval = Evaluator.init(a, ".");
    // No eval.deinit() — the arena owns everything the evaluator allocated.
    var scope = Env.init(a, null);

    const src =
        \\(defmodule fb (rfbt rfbb) (* 0.6 (+ 1.0 (/ rfbt rfbb))))
        \\(fb 220k 47k)
    ;
    const nodes = try parser.parse(a, src);
    const result = try eval.evalNodes(nodes, &scope);
    try std.testing.expectApproxEqAbs(@as(f64, 3.4085), result.asNumber().?, 0.001);
}

// leak-audit: the defmodule default-fill path evaluates an omitted parameter's
// default inside the module scope — another alloc-and-forget path covered by
// the request arena in production. Arena-wrapped here to prove no escape.
test "leak: module default-fill path is arena-contained" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var eval = Evaluator.init(a, ".");
    var scope = Env.init(a, null);

    const src =
        \\(defmodule m (a (b 4)) (- a b))
        \\(m 10)
    ;
    const nodes = try parser.parse(a, src);
    const result = try eval.evalNodes(nodes, &scope);
    try std.testing.expectEqual(@as(f64, 6.0), result.asNumber().?);
}
