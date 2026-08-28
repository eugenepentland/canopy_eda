//! The background full-board DRC sweep — the thing that makes a scoped answer
//! trustworthy.
//!
//! `POST /api/pcb-drc/:name` answers a routing edit by re-checking only what the
//! edit can reach (`drc_reconcile.zig`, `placement/drc_scope.zig`). That is a
//! CLAIM: that a scoped pass and a full pass over the same board agree for every
//! kind except the three the scoped path deliberately defers. `drc-dump
//! --scoped` tests the claim on the corpus before the code ships. This tests it
//! on the board the user is actually editing, continuously, while they edit it.
//!
//! A few seconds after the edits stop, a detached thread runs the FULL reporting
//! seam — `drc_rules.checkFilteredZonesTally`, the same function `?full=1`
//! takes — over the state the session last accepted, and compares its findings
//! against the ones the session answered with. It does two jobs at once:
//!
//!   • It REFRESHES the deferred kinds. `reference_plane_gap`,
//!     `reference_transition` and `loop_area` are carried forward by a scoped
//!     pass rather than recomputed, so until now they only ever moved when
//!     something forced a full pass. The sweep is their update path, and the
//!     next reconcile response carries the fresh ones out with no protocol
//!     change: they flow through `Prior.deferred` exactly as the carried ones
//!     always did.
//!
//!   • It CHECKS everything else. Any finding the sweep has and the ledger does
//!     not, or the other way round, is a discrepancy — the scoped path missed or
//!     over-retired a finding. The sweep wins: its findings become the ledger,
//!     the session is retired so the next request re-primes from a full pass,
//!     the disagreement is logged with its coordinates, and a counter the
//!     `/api/pcb-drc` response carries goes up. That number is expected to be
//!     zero forever, which is exactly why it must be visible.
//!
//! ## What it costs the editor
//!
//! Nothing on the response path. The sweep never takes the design's
//! single-flight reservation, so a reconcile issued mid-sweep is answered
//! immediately; it holds the store lock only to pin its inputs and to publish
//! its answer. It runs at most two at a time across the whole server (the cap
//! `serve/pcb_derived.zig` uses, for the same reason: this is seconds of pour
//! rasterisation, and a burst of edits must not put one on every core).
//!
//! ## Lifetimes
//!
//! The editor keeps replacing the state the sweep is reading. So the sweep
//! never holds a pointer into a session; it holds REFERENCES — one per session
//! arena, plus a claim on the session — taken under the store lock by
//! `drc_reconcile.snapshotFor` and handed back by `publish`. W3's two
//! use-after-frees were both "session memory crossed a boundary by value"; this
//! module is written so that cannot happen here.

const std = @import("std");
const drc = @import("placement/drc.zig");
const drc_scope = @import("placement/drc_scope.zig");
const drc_rules = @import("serve/drc_rules.zig");
const drc_reconcile = @import("drc_reconcile.zig");
const clock = @import("infra/clock.zig");
const log = @import("infra/log.zig");
const serve_root = @import("serve.zig");

/// The longest a waiting thread sleeps before looking at the world again. The
/// debounce is served in slices this size so a re-arm, an eviction or a store
/// shutdown is noticed promptly rather than at the end of a full debounce.
const slice_ns: u64 = 50 * std.time.ns_per_ms;

/// Let `store` start sweep threads. Called once, where the server builds its
/// state; a store this was never called on arms sweeps and starts none, which
/// is what every committed test relies on to run `sweepOnce` in line.
pub fn install(store: *drc_reconcile.Store) void {
    store.sweep.starter = start;
}

/// One design's sweep thread: everything it needs, owned by it.
///
/// The strings are process-lifetime copies because the names it was armed with
/// point into a request URL, and into a session that may be evicted, long
/// before this thread is done with them — the same reason `pcb_derived.Warm`
/// copies its name.
const Job = struct {
    store: *drc_reconcile.Store,
    project_dir: []const u8,
    name: []const u8,
    sub: ?[]const u8,

    fn deinit(self: Job) void {
        // allocator-ok: releasing the process-lifetime copies `own` made.
        const alloc = std.heap.page_allocator;
        alloc.free(self.project_dir);
        alloc.free(self.name);
        if (self.sub) |sub| alloc.free(sub);
    }

    fn run(self: Job) void {
        defer {
            drc_reconcile.endSweep(self.store, self.name, self.sub);
            self.deinit();
        }
        while (true) {
            switch (drc_reconcile.sweepTurn(self.store, self.name, self.sub, clock.nanoTimestamp())) {
                .exit => return,
                .wait => |ns| {
                    clock.sleep(@min(ns, slice_ns)) catch return;
                    continue;
                },
                .go => {},
            }
            _ = sweepOnce(self.store, self.project_dir, self.name, self.sub);
        }
    }
};

/// Start one design's sweep thread. This is the `drc_reconcile.Starter` the
/// store calls once it has taken the registration out; false means it could
/// not be started and the registration must go back.
fn start(store: *drc_reconcile.Store, project_dir: []const u8, name: []const u8, sub: ?[]const u8) bool {
    const job = own(store, project_dir, name, sub) orelse return false;
    const thread = std.Thread.spawn(.{}, Job.run, .{job}) catch |e| {
        log.warn("drc sweep: not started for {s} ({s})", .{ name, @errorName(e) });
        job.deinit();
        return false;
    };
    thread.detach();
    return true;
}

fn own(store: *drc_reconcile.Store, project_dir: []const u8, name: []const u8, sub: ?[]const u8) ?Job {
    // allocator-ok: process-lifetime by necessity — this outlives the request.
    const alloc = std.heap.page_allocator;
    const dir = alloc.dupe(u8, project_dir) catch return null;
    const owned = alloc.dupe(u8, name) catch {
        alloc.free(dir);
        return null;
    };
    var slug: ?[]const u8 = null;
    if (sub) |s| slug = alloc.dupe(u8, s) catch {
        alloc.free(dir);
        alloc.free(owned);
        return null;
    };
    return .{ .store = store, .project_dir = dir, .name = owned, .sub = slug };
}

/// One sweep's outcome, for a test and for the run loop.
pub const Outcome = struct {
    /// Nothing to sweep (no session, nothing accepted yet), or the answer was
    /// dropped as stale.
    ran: bool = false,
    published: bool = false,
    /// Findings the full pass produced for the three deferred kinds.
    deferred: usize = 0,
    /// Non-deferred findings the full pass and the ledger disagreed about.
    discrepancies: usize = 0,
    /// The full reporting pass's wall time.
    ns: i128 = 0,
};

/// Run ONE sweep of `name`, in line, on the calling thread.
///
/// This is the whole sweep body: the run loop calls it, and so does every test
/// — which is why the tests need no sleeps and no threads to assert what a
/// sweep does. It takes no reservation and blocks no reconcile.
pub fn sweepOnce(
    store: *drc_reconcile.Store,
    project_dir: []const u8,
    name: []const u8,
    sub: ?[]const u8,
) Outcome {
    const snap = drc_reconcile.snapshotFor(store, name, sub, serve_root.getLiveVersion(name)) orelse return .{};
    // The sweep's own arena, released before it returns: a barracuda-class
    // reporting pass holds hundreds of megabytes, and none of it may be kept
    // past the comparison it exists to make.
    // allocator-ok: detached sweep-thread scratch, released at the end of this call.
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const started = clock.nanoTimestamp();
    const truth = drc_rules.checkFilteredZonesTally(alloc, project_dir, name, snap.check);
    const elapsed = clock.nanoTimestamp() - started;

    const verdict = compare(alloc, snap.ledger, truth.violations);
    const published = drc_reconcile.publish(store, snap, .{
        .deferred = verdict.deferred,
        .violations = truth.violations,
        .discrepancies = verdict.discrepancies.len,
    }, clock.nanoTimestamp(), serve_root.getLiveVersion(name));
    if (published == .published) for (verdict.discrepancies) |d| report(name, d);
    return .{
        .ran = true,
        .published = published == .published,
        .deferred = verdict.deferred.len,
        .discrepancies = if (published == .published) verdict.discrepancies.len else 0,
        .ns = elapsed,
    };
}

/// Which side of the comparison a finding was missing from.
pub const Direction = enum {
    /// The full pass found it and the scoped answer did not: a MISSED finding,
    /// the dangerous direction — the editor was shown a clean board that is not.
    missing,
    /// The scoped answer carried it and the full pass does not: a STALE
    /// finding the scoped path should have retired.
    extra,
};

/// One disagreement between a scoped answer and the full pass behind it.
pub const Discrepancy = struct {
    direction: Direction,
    violation: drc.Violation,
};

/// What a sweep concluded about one session's ledger.
pub const Verdict = struct {
    /// The full pass's deferred-kind findings, which replace the carried ones.
    deferred: []const drc.Violation = &.{},
    discrepancies: []const Discrepancy = &.{},
};

/// Compare a sweep's findings against the ledger the scoped path produced.
///
/// The deferred kinds are split off FIRST and never compared: a scoped pass
/// carries them rather than recomputing them, so a difference there is the
/// refresh this sweep exists to deliver, not a fault. Everything else is
/// compared as a MULTISET keyed on the violation's full identity
/// (`drc_scope.violationKey`) — the same "exact content, whatever the array
/// order" rule the copper diff uses, and for the same reason: two rules can
/// legitimately produce the same finding twice, and a set would hide one of
/// them going missing.
pub fn compare(
    alloc: std.mem.Allocator,
    ledger: []const drc.Violation,
    swept: []const drc.Violation,
) Verdict {
    var deferred: std.ArrayList(drc.Violation) = .empty;
    var balance: std.AutoHashMapUnmanaged(u64, i32) = .empty;
    for (swept) |v| {
        if (drc_rules.isDeferredKind(v.kind)) {
            deferred.append(alloc, v) catch return .{ .deferred = deferred.items };
            continue;
        }
        const gop = balance.getOrPutValue(alloc, drc_scope.violationKey(v), 0) catch
            return .{ .deferred = deferred.items };
        gop.value_ptr.* += 1;
    }
    for (ledger) |v| {
        if (drc_rules.isDeferredKind(v.kind)) continue;
        const gop = balance.getOrPutValue(alloc, drc_scope.violationKey(v), 0) catch
            return .{ .deferred = deferred.items };
        gop.value_ptr.* -= 1;
    }
    if (balance.count() == 0) return .{ .deferred = deferred.items };

    var out: std.ArrayList(Discrepancy) = .empty;
    // Both directions, from the side that actually carries the geometry: a
    // report has to name WHERE the finding is, and only the list it came from
    // knows.
    for (swept) |v| {
        if (drc_rules.isDeferredKind(v.kind)) continue;
        const slot = balance.getPtr(drc_scope.violationKey(v)) orelse continue;
        if (slot.* <= 0) continue;
        slot.* -= 1;
        out.append(alloc, .{ .direction = .missing, .violation = v }) catch break;
    }
    for (ledger) |v| {
        if (drc_rules.isDeferredKind(v.kind)) continue;
        const slot = balance.getPtr(drc_scope.violationKey(v)) orelse continue;
        if (slot.* >= 0) continue;
        slot.* += 1;
        out.append(alloc, .{ .direction = .extra, .violation = v }) catch break;
    }
    return .{ .deferred = deferred.items, .discrepancies = out.items };
}

/// One structured line per disagreement. Deliberately one line each rather than
/// a count: a scoped-path bug is diagnosed from WHICH finding moved and where,
/// and a number would send the next reader back to a board they can no longer
/// reproduce.
fn report(name: []const u8, d: Discrepancy) void {
    const v = d.violation;
    log.warn("drc sweep discrepancy: design={s} kind={s} dir={s} sev={s} x={d:.4} y={d:.4} gap={d:.4} clr={d:.4} net_a={d} net_b={d}", .{
        name,
        @tagName(v.kind),
        @tagName(d.direction),
        @tagName(v.severity),
        v.x,
        v.y,
        v.gap,
        v.clearance,
        v.who.net_a,
        v.who.net_b,
    });
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn at(x: f64, kind: drc.Kind) drc.Violation {
    return .{ .x = x, .y = 1, .gap = 0.1, .clearance = 0.2, .kind = kind };
}

// spec: Web Server - A background DRC sweep refreshes the deferred kinds and treats a difference in them as the refresh, never as a discrepancy
test "a sweep splits the deferred kinds off before it compares anything" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // The ledger carries a STALE loop_area; the sweep found a different one.
    const ledger = [_]drc.Violation{ at(1, .track_track), at(5, .loop_area) };
    const swept = [_]drc.Violation{ at(1, .track_track), at(9, .loop_area) };
    const verdict = compare(alloc, &ledger, &swept);
    try testing.expectEqual(@as(usize, 1), verdict.deferred.len);
    try testing.expectEqual(@as(f64, 9), verdict.deferred[0].x);
    // …and that is a refresh, not a disagreement.
    try testing.expectEqual(@as(usize, 0), verdict.discrepancies.len);

    // All three deferred kinds ride that path.
    for ([_]drc.Kind{ .reference_plane_gap, .reference_transition, .loop_area }) |kind| {
        const one = [_]drc.Violation{at(2, kind)};
        const only = compare(alloc, &.{}, &one);
        try testing.expectEqual(@as(usize, 1), only.deferred.len);
        try testing.expectEqual(@as(usize, 0), only.discrepancies.len);
    }
}

// spec: Web Server - A background DRC sweep reports every non-deferred finding the scoped answer and a full pass disagree about, in both directions
test "a sweep reports a missed finding and a stale one, and counts duplicates" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // Same findings, different order: no disagreement. Order is not identity.
    const a = at(1, .track_track);
    const b = at(2, .via_pad);
    try testing.expectEqual(@as(usize, 0), compare(alloc, &.{ a, b }, &.{ b, a }).discrepancies.len);

    // The scoped answer missed one the full pass found.
    const missed = compare(alloc, &.{a}, &.{ a, b });
    try testing.expectEqual(@as(usize, 1), missed.discrepancies.len);
    try testing.expectEqual(Direction.missing, missed.discrepancies[0].direction);
    try testing.expectEqual(drc.Kind.via_pad, missed.discrepancies[0].violation.kind);
    try testing.expectEqual(@as(f64, 2), missed.discrepancies[0].violation.x);

    // …and one it kept that is no longer there.
    const stale = compare(alloc, &.{ a, b }, &.{a});
    try testing.expectEqual(@as(usize, 1), stale.discrepancies.len);
    try testing.expectEqual(Direction.extra, stale.discrepancies[0].direction);
    try testing.expectEqual(drc.Kind.via_pad, stale.discrepancies[0].violation.kind);

    // A multiset, not a set: losing one of two identical findings is a
    // disagreement, and only one of the two is reported.
    const twice = compare(alloc, &.{ a, a }, &.{a});
    try testing.expectEqual(@as(usize, 1), twice.discrepancies.len);
    try testing.expectEqual(Direction.extra, twice.discrepancies[0].direction);

    // Severity is part of the identity: the same geometry escalated is a
    // different finding, so it reads as one of each direction.
    var escalated = a;
    escalated.severity = .warn;
    const resev = compare(alloc, &.{a}, &.{escalated});
    try testing.expectEqual(@as(usize, 2), resev.discrepancies.len);
}

// spec: Web Server - A background DRC sweep of a design with nothing accepted does nothing
test "a store with nothing accepted sweeps nothing" {
    var store = drc_reconcile.Store{};
    defer store.deinit();
    try testing.expect(!sweepOnce(&store, "p", "board", null).ran);

    // A live store with no session for that design is the same answer: there is
    // nothing accepted to sweep.
    var live = drc_reconcile.Store{ .allocator = testing.allocator };
    defer live.deinit();
    try testing.expect(!sweepOnce(&live, "p", "board", null).ran);
    // …and installing the starter on it neither runs nor arms anything by
    // itself: arming is what an accepted answer does.
    install(&live);
    try testing.expect(!sweepOnce(&live, "p", "board", null).ran);
}
