//! Process-lifetime allocator port. The ONE place this tree names a global
//! allocator, so the decision "this memory outlives every request" is made once
//! and is greppable, rather than being re-made by each of the two dozen sites
//! that used to write `std.heap.page_allocator` inline.
//!
//! Why the server needs one at all: every handler runs on a per-request arena
//! that httpz frees when the response is written. State that must survive the
//! response — the live scene-graph slot, the per-design version counters, the
//! background PCB-regen jobs, the page/summary/module/DRC-rule caches, the
//! plugin-token table, the route sessions, the fill and impedance memos —
//! cannot live there. Handing those an arena is exactly how the 11.7 GB server
//! RSS leak of `1359ae6c` happened: the store kept pointers into memory the
//! request had already released, so every fix has to re-answer "whose is this?"
//! and the answer must not be a literal buried in a handler.
//!
//! What this is NOT: a licence to allocate without an owner. `durable` memory
//! is never reclaimed by scope exit, so every store that uses it still has to
//! free what it replaces or bound what it retains — the caches here all do one
//! or the other (replace-and-free per key, or an LRU with a byte budget), and a
//! new caller that can do neither wants the caller's allocator instead.
//!
//! Usage:
//!     const process_alloc = @import("../infra/process_alloc.zig");
//!     const durable = process_alloc.durable;

const std = @import("std");

/// The allocator for state whose lifetime is the process.
///
/// `page_allocator` rather than a GPA: these stores are long-lived and
/// coarse-grained (page-sized bodies, cache entries, job frames), there is no
/// single owner to run a leak check against at shutdown — the server exits by
/// signal — and a shared GPA would put every cache behind one mutex.
// This declaration IS the decision, and every other site in the tree imports
// it (or threads a caller's allocator) instead of naming a global of its own —
// which is what makes the waiver below a single reviewable line rather than a
// per-file habit.
// allocator-ok: the tree's one sanctioned process-lifetime allocator.
pub const durable: std.mem.Allocator = std.heap.page_allocator;

// ── tests ──────────────────────────────────────────────────────────

// spec: infra/process-allocator - durable memory survives the teardown of a request arena allocated beside it
test "durable memory survives the teardown of a request arena allocated beside it" {
    // Stands in for a handler: httpz hands the route an arena and frees it once
    // the response is written.
    var request_arena = std.heap.ArenaAllocator.init(durable);
    const request = request_arena.allocator();
    const rendered = try request.dupe(u8, "{\"scene\":\"graph\"}");

    // What a cross-request store has to do with those bytes: copy them out.
    // Retaining `rendered` itself is the shape of the RSS leak this module is
    // named after — the pointer stays live while its arena does not.
    const retained = try durable.dupe(u8, rendered);
    defer durable.free(retained);

    request_arena.deinit();

    try std.testing.expectEqualStrings("{\"scene\":\"graph\"}", retained);
}
