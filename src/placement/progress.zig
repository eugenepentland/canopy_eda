//! PCB-completion progress ladder (the "how done is this board" model). Six
//! ordered rungs — schematic → sub-circuits → board-setup → placement →
//! routing → fab-ready — each with a done/total tally and a ledger of the
//! open work still on it.
//!
//! Like `src/fab_readiness.zig` (its architectural template) this is a PURE
//! function of a caller-assembled `Inputs` struct — no disk, no server, no
//! re-solve — so it is unit-testable in isolation and every read surface
//! (home-page chip, `/pcb-layout` scorebar, a CLI tool) computes the same
//! `Report` from the same facts. The serve layer gathers the inputs (ERC count,
//! per-net connectivity via `fab_readiness.netConnectivity`, the blessed
//! placement, the fab gate's blocking errors already mirrored into ladder
//! items) and calls `compute`.
//!
//! Every input arrives in a shape this module declares — `NetConn` for
//! connectivity, `Item` for the fab gate's errors — so the ladder never names
//! the fab/export layer that produced them. That is what keeps `src/placement/`
//! from importing `src/fab_readiness.zig` (the `[[boundary]]` rule in
//! `guardian.toml`), and it is the same seam `NetConn` has always used.
//!
//! A rung is `done` the instant its predicate holds, INDEPENDENTLY of the rungs
//! before it, so out-of-order work (a routed net before every part is locked)
//! reads honestly; `current` is the first not-done rung.
//!
//! The placement and routing rungs are split into the ordered WAVES of the
//! resolved `(pcb-plan …)` (see `plan_resolve.zig`): each place wave is done
//! when every member part is locked, each route wave when every routable member
//! net is connected. The stage tally sums its waves; `current_wave` is the
//! first incomplete wave of the current stage, and a `plan-out-of-order`
//! advisory flags a later wave that progressed before an earlier one finished.
//! When `Inputs.plan` carries no waves (the default) each rung keeps its old
//! single implicit "All parts" / "All nets" bucket, so the JSON is unchanged
//! for callers that don't supply a plan.

const std = @import("std");
const json_writer = @import("../json_writer.zig");
const optimizer = @import("optimizer.zig");
const plan_resolve = @import("plan_resolve.zig");

const Allocator = std.mem.Allocator;

/// FNV-1a offset basis and prime — the same 32-bit constants
/// `src/serve/drc_json.zig` folds a DRC id with, so a progress finding's id is
/// minted by the identical scheme.
const fnv_offset: u32 = 0x811c9dc5;
const fnv_prime: u32 = 0x01000193;

/// The six ordered rungs of the completion ladder. Declaration order IS the
/// ladder order — `Report.stages` is index-aligned with `@intFromEnum`.
pub const StageId = enum {
    schematic,
    sub_circuits,
    board_setup,
    placement,
    routing,
    fab_ready,
};

/// A rung's state relative to the whole ladder: `done` (predicate holds),
/// `current` (the first not-done rung), or `pending` (a later not-done rung).
pub const StageStatus = enum { done, current, pending };

/// Number of rungs — the fixed length of `Report.stages`, derived from the
/// enum so the two can never drift.
const stage_count = @typeInfo(StageId).@"enum".field_names.len;

/// One open ledger entry on a rung. `id` is a stable 4-hex hash of the finding
/// (drc_json's scheme) so a given finding keeps its id across recomputation;
/// The kind is the machine key (e.g. "unlocked-part", "open-net"); ref/net
/// point at the offending part or net; pcb_target names a design/module whose
/// PCB editor resolves the finding; count (0 = omit) carries a tally.
pub const Item = struct {
    id: []const u8,
    kind: []const u8,
    message: []const u8,
    ref: ?[]const u8 = null,
    net: ?[]const u8 = null,
    meta: ItemMeta = .{},
};

/// Optional action and tally metadata kept together so the core finding stays
/// small while its flat JSON representation remains backwards-compatible.
const ItemMeta = struct {
    pcb_target: ?[]const u8 = null,
    count: usize = 0,
    /// The plan wave this open item belongs to, when the stage is wave-split.
    wave: ?[]const u8 = null,
};

/// One place/route wave's tally within a wave-split stage: its name, the
/// done/total member count, and its status (`done`, `current` = the first
/// incomplete wave, `pending` = a later incomplete wave).
pub const WaveTally = struct {
    name: []const u8,
    done: usize,
    total: usize,
    status: StageStatus,
};

/// One rung: its id, computed status, a `done`/`total` tally (the fraction of
/// the rung's work finished), the still-open `items` (empty when done), and —
/// on the placement/routing rungs — the per-`waves` breakdown (empty on the
/// other rungs and when no plan was supplied).
pub const Stage = struct {
    id: StageId,
    status: StageStatus,
    done: usize,
    total: usize,
    items: []const Item,
    waves: []const WaveTally = &.{},
};

/// The whole ladder plus `current` — the first not-done rung (or `fab_ready`
/// when the entire ladder is done, so the pointer sits on the finish line) —
/// the current stage's first incomplete `current_wave`, and the plan's
/// unresolved-name `warnings` surfaced for the caller's lint.
pub const Report = struct {
    stages: [stage_count]Stage,
    current: StageId,
    current_wave: ?[]const u8 = null,
    warnings: []const Item = &.{},
};

/// One sub-block's layout status: a sub-block whose `lib/module` carries parts
/// (`needs_layout`) must have a starred module layout to reuse (`starred`).
pub const SubCircuitStatus = struct {
    name: []const u8,
    /// Bare design/module name to open in /pcb-layout/:name for completion.
    pcb_target: ?[]const u8 = null,
    needs_layout: bool,
    starred: bool,
};

/// One net's plane-aware connectivity verdict — the shape the serve layer maps
/// from `fab_readiness.netConnectivity`: `routable` (pads in ≥2 board locations,
/// so it needs copper) and `connected` (that copper/plane joins them).
pub const NetConn = struct {
    name: []const u8,
    routable: bool,
    connected: bool,
    /// Actual retained via count; null means the caller did not inspect copper.
    vias: ?usize = null,
};

/// Everything the ladder needs, assembled by the caller so this module stays a
/// pure, testable function. `fab` is null until the fab-readiness gate has run;
/// `from_saved_layout` is false when the layout is the optimizer cache.
pub const Inputs = struct {
    erc_error_count: usize,
    sub_circuits: []const SubCircuitStatus,
    has_outline: bool,
    placement: optimizer.Placement,
    net_conn: []const NetConn,
    /// The fab-readiness gate's BLOCKING errors, already mirrored into ladder
    /// items by the caller (`serve/pcb_progress.zig`, beside its `NetConn`
    /// mapping). `null` = the gate has not run; an empty slice = it ran and
    /// passed. Warnings never block the rung, so they are not carried.
    fab_errors: ?[]const Item,
    from_saved_layout: bool,
    /// The resolved `(pcb-plan …)` splitting the placement/routing rungs into
    /// ordered waves. The default (empty place/route) keeps each rung on its
    /// single implicit "All parts" / "All nets" wave — today's behaviour — so
    /// callers that don't resolve a plan are unaffected. `place` members index
    /// `placement.parts`; `route` members index `net_conn`.
    plan: plan_resolve.ResolvedPlan = .{},
};

/// Compute the completion ladder from the assembled inputs. Builds each rung's
/// tally + open items, then assigns every rung's status in one pass (done where
/// the predicate holds, `current` on the first not-done rung, else `pending`).
/// All output is arena-owned.
pub fn compute(arena: Allocator, in: Inputs) Allocator.Error!Report {
    var stages = [stage_count]Stage{
        try schematicStage(arena, in),
        try subCircuitsStage(arena, in),
        try boardSetupStage(arena, in),
        try placementStage(arena, in),
        try routingStage(arena, in),
        try fabReadyStage(arena, in),
    };
    var report = assignStatuses(&stages);
    report.warnings = try planWarnings(arena, in.plan.warnings);
    report.current_wave = currentWaveName(report);
    return report;
}

/// The name of the first `current`-status wave on the current stage — the wave
/// the user should be working. Null when the current stage isn't wave-split.
fn currentWaveName(report: Report) ?[]const u8 {
    const st = report.stages[@backingInt(report.current)];
    for (st.waves) |w| {
        if (w.status == .current) return w.name;
    }
    return null;
}

/// Re-express the plan's unresolved-name warnings as ladder items so the caller
/// can surface them in its lint, preserving each warning's stable id + wave.
fn planWarnings(arena: Allocator, warns: []const plan_resolve.Warning) Allocator.Error![]const Item {
    const out = try arena.alloc(Item, warns.len);
    for (warns, 0..) |w, i| {
        out[i] = .{ .id = w.id, .kind = w.kind, .message = w.message, .meta = .{ .wave = w.wave } };
    }
    return out;
}

/// Rung 1 — the schematic is settled once ERC reports no errors. The lone open
/// item carries the error count.
fn schematicStage(arena: Allocator, in: Inputs) Allocator.Error!Stage {
    var items: std.ArrayList(Item) = .empty;
    if (in.erc_error_count > 0) {
        const msg = try std.fmt.allocPrint(
            arena,
            "{d} ERC error(s) — resolve them in the schematic before layout",
            .{in.erc_error_count},
        );
        try items.append(arena, try mkItem(arena, "erc-errors", msg, .{ .count = in.erc_error_count }));
    }
    const done: usize = if (in.erc_error_count == 0) 1 else 0;
    return finishStage(arena, .schematic, done, 1, &items);
}

/// Rung 2 — every sub-block that needs its own layout must have a starred
/// module layout to reuse. One open item per offender (tally counts only the
/// needs-layout sub-blocks).
fn subCircuitsStage(arena: Allocator, in: Inputs) Allocator.Error!Stage {
    var items: std.ArrayList(Item) = .empty;
    var total: usize = 0;
    var done: usize = 0;
    for (in.sub_circuits) |sc| {
        if (!sc.needs_layout) continue;
        total += 1;
        if (sc.starred) {
            done += 1;
            continue;
        }
        const msg = try std.fmt.allocPrint(
            arena,
            "sub-circuit {s} has no starred module layout — star one to reuse it",
            .{sc.name},
        );
        try items.append(arena, try mkItem(arena, "module-not-starred", msg, .{
            .ref = sc.name,
            .pcb_target = sc.pcb_target,
        }));
    }
    return finishStage(arena, .sub_circuits, done, total, &items);
}

/// Rung 3 — the board needs an authored/drawn outline before placement means
/// anything. A missing stackup is deliberately NOT modelled here (not blocking).
fn boardSetupStage(arena: Allocator, in: Inputs) Allocator.Error!Stage {
    var items: std.ArrayList(Item) = .empty;
    if (!in.has_outline) {
        const msg = "no board outline — draw or author a (board …) rectangle first";
        try items.append(arena, try mkItem(arena, "missing-outline", msg, .{}));
    }
    const done: usize = if (in.has_outline) 1 else 0;
    return finishStage(arena, .board_setup, done, 1, &items);
}

/// Rung 4 — placement is finished once every part is locked. Splits into the
/// plan's place waves when one is supplied, else keeps the single implicit
/// "All parts" wave.
fn placementStage(arena: Allocator, in: Inputs) Allocator.Error!Stage {
    if (in.plan.place.len == 0) return placementStageAll(arena, in);
    return placementStageWaves(arena, in);
}

/// The single-implicit-wave placement rung: locked/total parts, one open item
/// per unlocked part. An empty board is vacuously done.
fn placementStageAll(arena: Allocator, in: Inputs) Allocator.Error!Stage {
    var items: std.ArrayList(Item) = .empty;
    var done: usize = 0;
    for (in.placement.parts) |p| {
        if (p.locked) {
            done += 1;
            continue;
        }
        const msg = try std.fmt.allocPrint(arena, "Place + lock {s}", .{p.ref_des});
        try items.append(arena, try mkItem(arena, "unlocked-part", msg, .{ .ref = p.ref_des }));
    }
    return finishStage(arena, .placement, done, in.placement.parts.len, &items);
}

/// The wave-split placement rung: each place wave is done when every member
/// part is locked; the stage tally sums the waves, items are wave-tagged, and a
/// `plan-out-of-order` advisory flags a later wave that began before an earlier.
fn placementStageWaves(arena: Allocator, in: Inputs) Allocator.Error!Stage {
    var items: std.ArrayList(Item) = .empty;
    const tallies = try arena.alloc(WaveTally, in.plan.place.len);
    var stage_done: usize = 0;
    for (in.plan.place, 0..) |w, wi| {
        var wd: usize = 0;
        for (w.members) |pi| {
            if (pi >= in.placement.parts.len) continue;
            const p = in.placement.parts[pi];
            if (p.locked) {
                wd += 1;
                continue;
            }
            const msg = try std.fmt.allocPrint(arena, "Place + lock {s}", .{p.ref_des});
            try items.append(arena, try mkItem(arena, "unlocked-part", msg, .{ .ref = p.ref_des, .wave = w.name }));
        }
        tallies[wi] = .{ .name = w.name, .done = wd, .total = w.members.len, .status = .pending };
        stage_done += wd;
    }
    return try finishWaveStage(arena, .placement, stage_done, tallies, &items);
}

/// Rung 5 — routing is finished once every routable net is connected. Splits
/// into the plan's route waves when one is supplied, else keeps the single
/// implicit "All nets" wave.
fn routingStage(arena: Allocator, in: Inputs) Allocator.Error!Stage {
    if (in.plan.route.len == 0) return routingStageAll(arena, in);
    return routingStageWaves(arena, in);
}

/// The single-implicit-wave routing rung: connected/routable nets, one open
/// item per net with an airwire remaining (non-routable nets are ignored).
fn routingStageAll(arena: Allocator, in: Inputs) Allocator.Error!Stage {
    var items: std.ArrayList(Item) = .empty;
    var total: usize = 0;
    var done: usize = 0;
    for (in.net_conn) |nc| {
        if (!nc.routable) continue;
        total += 1;
        if (nc.connected) {
            done += 1;
            continue;
        }
        const msg = try std.fmt.allocPrint(arena, "net {s} still has an open airwire — route it", .{nc.name});
        try items.append(arena, try mkItem(arena, "open-net", msg, .{ .net = nc.name }));
    }
    return finishStage(arena, .routing, done, total, &items);
}

/// The wave-split routing rung: each route wave is done when every ROUTABLE
/// member net is connected (a non-routable member — single-location or
/// plane-carried — counts as satisfied and is left out of the tally, so a wave
/// of only non-routable members is done).
fn routingStageWaves(arena: Allocator, in: Inputs) Allocator.Error!Stage {
    var items: std.ArrayList(Item) = .empty;
    const tallies = try arena.alloc(WaveTally, in.plan.route.len);
    var stage_done: usize = 0;
    for (in.plan.route, 0..) |w, wi| {
        var wd: usize = 0;
        var wt: usize = 0;
        for (w.members) |ni| {
            if (ni >= in.net_conn.len) continue;
            const nc = in.net_conn[ni];
            if (try viaBudgetItem(arena, nc, w)) |item| {
                wt += 1;
                try items.append(arena, item);
                continue;
            }
            if (!nc.routable) continue;
            wt += 1;
            if (nc.connected) {
                wd += 1;
                continue;
            }
            const msg = try std.fmt.allocPrint(arena, "net {s} still has an open airwire — route it", .{nc.name});
            try items.append(arena, try mkItem(arena, "open-net", msg, .{ .net = nc.name, .wave = w.name }));
        }
        tallies[wi] = .{ .name = w.name, .done = wd, .total = wt, .status = .pending };
        stage_done += wd;
    }
    return try finishWaveStage(arena, .routing, stage_done, tallies, &items);
}

/// Connectivity alone cannot satisfy an authored total via cap.
fn viaBudgetItem(arena: Allocator, nc: NetConn, wave: plan_resolve.ResolvedWave) Allocator.Error!?Item {
    const limit = wave.max_vias orelse return null;
    const count = nc.vias orelse {
        const msg = try std.fmt.allocPrint(arena, "net {s} via count is unverified against its limit of {d}", .{ nc.name, limit });
        return try mkItem(arena, "via-budget-unverified", msg, .{ .net = nc.name, .wave = wave.name });
    };
    if (count <= limit) return null;
    const msg = try std.fmt.allocPrint(arena, "net {s} has {d} vias; its authored total limit is {d}", .{ nc.name, count, limit });
    return try mkItem(arena, "via-budget-exceeded", msg, .{ .net = nc.name, .wave = wave.name, .count = count });
}

/// Assign wave statuses, add the out-of-order advisory, and freeze a wave-split
/// stage: its done/total are the summed wave tallies.
fn finishWaveStage(
    arena: Allocator,
    id: StageId,
    stage_done: usize,
    tallies: []WaveTally,
    items: *std.ArrayList(Item),
) Allocator.Error!Stage {
    assignWaveStatuses(tallies);
    try appendOutOfOrder(arena, items, tallies);
    var stage_total: usize = 0;
    for (tallies) |t| stage_total += t.total;
    return .{
        .id = id,
        .status = .pending,
        .done = stage_done,
        .total = stage_total,
        .items = try items.toOwnedSlice(arena),
        .waves = tallies,
    };
}

/// Set each wave's status: `done` where its tally is complete, `current` on the
/// FIRST incomplete wave, `pending` on any later incomplete wave — the same
/// first-not-done rule the stages use.
fn assignWaveStatuses(tallies: []WaveTally) void {
    var found = false;
    for (tallies) |*t| {
        if (t.done == t.total) {
            t.status = .done;
        } else if (!found) {
            t.status = .current;
            found = true;
        } else t.status = .pending;
    }
}

/// Emit one `plan-out-of-order` advisory when a wave AFTER the first incomplete
/// wave already shows progress — informational, never blocking. Keyed on the
/// later wave so placement's and routing's advisories keep distinct ids.
fn appendOutOfOrder(arena: Allocator, items: *std.ArrayList(Item), tallies: []const WaveTally) Allocator.Error!void {
    var first: ?usize = null;
    for (tallies, 0..) |t, i| {
        if (t.status == .current) {
            first = i;
            break;
        }
    }
    const fi = first orelse return;
    for (tallies[fi + 1 ..]) |t| {
        if (t.done == 0) continue;
        const msg = try std.fmt.allocPrint(
            arena,
            "wave \"{s}\" has progress while the earlier wave \"{s}\" is still incomplete",
            .{ t.name, tallies[fi].name },
        );
        try items.append(arena, try mkItem(arena, "plan-out-of-order", msg, .{ .wave = t.name }));
        return;
    }
}

/// Rung 6 — the board is fab-ready once the fab-readiness gate has run, passed,
/// and did so on a saved (blessed) layout. Open items mirror the gate's errors,
/// or flag that the gate never ran / the layout is unsaved.
fn fabReadyStage(arena: Allocator, in: Inputs) Allocator.Error!Stage {
    const ready = in.fab_errors != null and in.fab_errors.?.len == 0 and in.from_saved_layout;
    var items: std.ArrayList(Item) = try fabItems(arena, in);
    return finishStage(arena, .fab_ready, if (ready) 1 else 0, 1, &items);
}

/// The open items for the fab-ready rung: gate-not-run when no report exists,
/// the gate's own errors when it failed, else an unsaved-layout nudge.
fn fabItems(arena: Allocator, in: Inputs) Allocator.Error!std.ArrayList(Item) {
    var items: std.ArrayList(Item) = .empty;
    const errors = in.fab_errors orelse {
        const msg = "the fab-readiness gate has not run — run it on a saved layout";
        try items.append(arena, try mkItem(arena, "fab-gate-not-run", msg, .{}));
        return items;
    };
    if (errors.len > 0) {
        for (errors) |fe| try items.append(arena, fe);
    } else if (!in.from_saved_layout) {
        const msg = "the fab gate passed on the optimizer cache — save/star the layout to finish";
        try items.append(arena, try mkItem(arena, "layout-not-saved", msg, .{}));
    }
    return items;
}

/// Freeze a rung's open items into a `Stage` with a placeholder status (the
/// real status is assigned once every rung is built — see `assignStatuses`).
fn finishStage(
    arena: Allocator,
    id: StageId,
    done: usize,
    total: usize,
    items: *std.ArrayList(Item),
) Allocator.Error!Stage {
    return .{ .id = id, .status = .pending, .done = done, .total = total, .items = try items.toOwnedSlice(arena) };
}

/// Assign every rung's status: `done` where the tally is complete, `current` on
/// the FIRST not-done rung, `pending` on any later not-done rung. `current` is
/// independent of order — a later done rung stays `done` even past the current
/// one. When the whole ladder is done, `current` is the terminal `fab_ready`.
fn assignStatuses(stages: *[stage_count]Stage) Report {
    var current: StageId = .fab_ready;
    var found = false;
    for (stages) |*st| {
        if (st.done == st.total) {
            st.status = .done;
        } else if (!found) {
            st.status = .current;
            current = st.id;
            found = true;
        } else {
            st.status = .pending;
        }
    }
    return .{ .stages = stages.*, .current = current };
}

/// Extra fields an `Item` may carry — kept in a small options struct so `mkItem`
/// stays a low-arity constructor.
const ItemOpts = struct {
    ref: ?[]const u8 = null,
    net: ?[]const u8 = null,
    pcb_target: ?[]const u8 = null,
    count: usize = 0,
    wave: ?[]const u8 = null,
};

/// Build an `Item`, minting its stable id from the kind + the finding's key
/// (its ref, else its net, else its wave, else empty) so the same finding keeps
/// the same id.
fn mkItem(arena: Allocator, kind: []const u8, message: []const u8, opts: ItemOpts) Allocator.Error!Item {
    const key = opts.ref orelse opts.net orelse opts.wave orelse "";
    return .{
        .id = try hashId(arena, kind, key),
        .kind = kind,
        .message = message,
        .ref = opts.ref,
        .net = opts.net,
        .meta = .{ .pcb_target = opts.pcb_target, .count = opts.count, .wave = opts.wave },
    };
}

/// FNV-1a over the kind, a `0x1f` separator, and the finding key, folded to 16
/// bits → a 4-hex string. Mirrors `src/serve/drc_json.zig`'s id scheme so a
/// finding's id is stable across recomputations of the same board state.
fn hashId(arena: Allocator, kind: []const u8, key: []const u8) Allocator.Error![]const u8 {
    var h: u32 = fnv_offset;
    for (kind) |c| h = (h ^ c) *% fnv_prime;
    h = (h ^ 0x1f) *% fnv_prime;
    for (key) |c| h = (h ^ c) *% fnv_prime;
    const folded: u16 = @truncate(h ^ (h >> 16));
    return std.fmt.allocPrint(arena, "{x:0>4}", .{folded});
}

/// Serialize a report to
/// `{"current":"…","stages":[…],"current_wave":"…","warnings":[…]}` — mirroring
/// `fab_readiness.writeJson`'s style. `current_wave` is emitted only when the
/// current stage is wave-split; `warnings` only when the plan had unresolved
/// names, so a caller supplying no plan gets the exact pre-wave JSON.
// not the json-escaper-def idiom: this is the report emitter, not a string
/// escaper — every free string goes through `json_writer.writeScriptString`,
/// and the `{s}` slots here are `@tagName` enum spellings.
pub fn writeJson(w: *std.Io.Writer, report: Report) std.Io.Writer.Error!void {
    try w.print("{{\"current\":\"{s}\",\"stages\":[", .{@tagName(report.current)});
    for (report.stages, 0..) |st, i| {
        if (i > 0) try w.writeAll(",");
        try writeStage(w, st);
    }
    try w.writeAll("]");
    if (report.current_wave) |cw| {
        try w.writeAll(",\"current_wave\":");
        try json_writer.writeScriptString(w, cw);
    }
    if (report.warnings.len > 0) {
        try w.writeAll(",\"warnings\":[");
        for (report.warnings, 0..) |it, i| {
            if (i > 0) try w.writeAll(",");
            try writeItem(w, it);
        }
        try w.writeAll("]");
    }
    try w.writeAll("}");
}

/// One stage object: its tally, the per-`waves` breakdown (only when wave-split),
/// and its open `items`.
fn writeStage(w: *std.Io.Writer, st: Stage) std.Io.Writer.Error!void {
    try w.print("{{\"id\":\"{s}\",\"status\":\"{s}\",\"done\":{d},\"total\":{d}", .{
        @tagName(st.id), @tagName(st.status), st.done, st.total,
    });
    if (st.waves.len > 0) {
        try w.writeAll(",\"waves\":[");
        for (st.waves, 0..) |wv, i| {
            if (i > 0) try w.writeAll(",");
            try writeWave(w, wv);
        }
        try w.writeAll("]");
    }
    try w.writeAll(",\"items\":[");
    for (st.items, 0..) |it, i| {
        if (i > 0) try w.writeAll(",");
        try writeItem(w, it);
    }
    try w.writeAll("]}");
}

/// One wave tally as `{"name","done","total","status"}`.
fn writeWave(w: *std.Io.Writer, wv: WaveTally) std.Io.Writer.Error!void {
    try w.writeAll("{\"name\":");
    try json_writer.writeScriptString(w, wv.name);
    try w.print(",\"done\":{d},\"total\":{d},\"status\":\"{s}\"}}", .{ wv.done, wv.total, @tagName(wv.status) });
}

/// One ledger item as a JSON object, id first; optional action/context fields
/// are omitted when unset (mirroring fab_readiness's convention).
fn writeItem(w: *std.Io.Writer, it: Item) std.Io.Writer.Error!void {
    try w.writeAll("{\"id\":");
    try json_writer.writeScriptString(w, it.id);
    try w.writeAll(",\"kind\":");
    try json_writer.writeScriptString(w, it.kind);
    try w.writeAll(",\"message\":");
    try json_writer.writeScriptString(w, it.message);
    if (it.ref) |r| {
        try w.writeAll(",\"ref\":");
        try json_writer.writeScriptString(w, r);
    }
    if (it.net) |n| {
        try w.writeAll(",\"net\":");
        try json_writer.writeScriptString(w, n);
    }
    if (it.meta.pcb_target) |target| {
        try w.writeAll(",\"pcb_target\":");
        try json_writer.writeScriptString(w, target);
    }
    if (it.meta.wave) |wv| {
        try w.writeAll(",\"wave\":");
        try json_writer.writeScriptString(w, wv);
    }
    if (it.meta.count > 0) try w.print(",\"count\":{d}", .{it.meta.count});
    try w.writeAll("}");
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A minimal `Placement` with the given parts and no nets/copper — enough to
/// exercise the ladder rungs that only read parts.
fn fixturePlacement(parts: []optimizer.Part) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 1,
        .maxy = 1,
        .generated = false,
    };
}

/// A clean baseline: no ERC errors, an outline, no sub-circuits/nets, fab gate
/// not yet run. Individual tests flip the one field they exercise.
fn baseInputs(pl: optimizer.Placement) Inputs {
    return .{
        .erc_error_count = 0,
        .sub_circuits = &.{},
        .has_outline = true,
        .placement = pl,
        .net_conn = &.{},
        .fab_errors = null,
        .from_saved_layout = true,
    };
}

fn stageById(r: Report, id: StageId) Stage {
    return r.stages[@backingInt(id)];
}

fn stageDone(r: Report, id: StageId) bool {
    return stageById(r, id).status == .done;
}

fn stageHasKind(s: Stage, kind: []const u8) bool {
    for (s.items) |it| if (std.mem.eql(u8, it.kind, kind)) return true;
    return false;
}

fn firstItem(s: Stage, kind: []const u8) ?Item {
    for (s.items) |it| if (std.mem.eql(u8, it.kind, kind)) return it;
    return null;
}

// spec: placement/progress - the schematic rung is done exactly when there are no ERC errors
test "schematic rung tracks the ERC error count" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var in = baseInputs(fixturePlacement(&.{}));
    in.erc_error_count = 0;
    try testing.expect(stageDone(try compute(arena, in), .schematic));

    in.erc_error_count = 3;
    const r = try compute(arena, in);
    try testing.expect(!stageDone(r, .schematic));
    try testing.expect(stageHasKind(stageById(r, .schematic), "erc-errors"));
}

// spec: placement/progress - the sub-circuits rung is done exactly when every needs-layout module is starred
test "sub-circuits rung requires every needs-layout module starred" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const mixed = [_]SubCircuitStatus{
        .{ .name = "adc1", .needs_layout = true, .starred = true },
        .{ .name = "amp", .needs_layout = true, .starred = false },
        .{ .name = "shunt", .needs_layout = false, .starred = false },
    };
    var in = baseInputs(fixturePlacement(&.{}));
    in.sub_circuits = &mixed;
    const r = try compute(arena, in);
    try testing.expect(!stageDone(r, .sub_circuits));
    try testing.expectEqual(@as(usize, 2), stageById(r, .sub_circuits).total);
    try testing.expectEqual(@as(usize, 1), stageById(r, .sub_circuits).done);
    try testing.expect(stageHasKind(stageById(r, .sub_circuits), "module-not-starred"));

    const all_starred = [_]SubCircuitStatus{.{ .name = "adc1", .needs_layout = true, .starred = true }};
    in.sub_circuits = &all_starred;
    try testing.expect(stageDone(try compute(arena, in), .sub_circuits));
}

// spec: placement/progress - a missing starred module layout carries its module PCB target for one-click completion
test "missing starred module exposes its PCB target" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const sub_circuits = [_]SubCircuitStatus{.{
        .name = "ldo_6v",
        .pcb_target = "ldo-6v",
        .needs_layout = true,
        .starred = false,
    }};
    var in = baseInputs(fixturePlacement(&.{}));
    in.sub_circuits = &sub_circuits;
    const report = try compute(arena, in);
    const item = firstItem(stageById(report, .sub_circuits), "module-not-starred").?;
    try testing.expectEqualStrings("ldo-6v", item.meta.pcb_target.?);

    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeJson(&aw.writer, report);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"pcb_target\":\"ldo-6v\"") != null);
}

// spec: placement/progress - the board-setup rung is done exactly when the board has an outline
test "board-setup rung tracks the board outline" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var in = baseInputs(fixturePlacement(&.{}));
    in.has_outline = true;
    try testing.expect(stageDone(try compute(arena, in), .board_setup));

    in.has_outline = false;
    const r = try compute(arena, in);
    try testing.expect(!stageDone(r, .board_setup));
    try testing.expect(stageHasKind(stageById(r, .board_setup), "missing-outline"));
}

// spec: placement/progress - the placement rung is done exactly when every part is locked
test "placement rung tracks locked parts" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .locked = true },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .locked = false },
    };
    const in = baseInputs(fixturePlacement(&parts));
    const r = try compute(arena, in);
    try testing.expect(!stageDone(r, .placement));
    try testing.expectEqual(@as(usize, 2), stageById(r, .placement).total);
    try testing.expectEqual(@as(usize, 1), stageById(r, .placement).done);
    const item = firstItem(stageById(r, .placement), "unlocked-part") orelse return error.TestExpectedItem;
    try testing.expectEqualStrings("C1", item.ref.?);

    parts[1].locked = true;
    try testing.expect(stageDone(try compute(arena, in), .placement));
}

// spec: placement/progress - the routing rung is done exactly when every routable net is connected
test "routing rung tracks connected routable nets" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const nets = [_]NetConn{
        .{ .name = "VBUS", .routable = true, .connected = true },
        .{ .name = "SIG", .routable = true, .connected = false },
        .{ .name = "TP", .routable = false, .connected = false },
    };
    var in = baseInputs(fixturePlacement(&.{}));
    in.net_conn = &nets;
    const r = try compute(arena, in);
    try testing.expect(!stageDone(r, .routing));
    try testing.expectEqual(@as(usize, 2), stageById(r, .routing).total);
    try testing.expectEqual(@as(usize, 1), stageById(r, .routing).done);
    try testing.expect(stageHasKind(stageById(r, .routing), "open-net"));

    const routed = [_]NetConn{.{ .name = "VBUS", .routable = true, .connected = true }};
    in.net_conn = &routed;
    try testing.expect(stageDone(try compute(arena, in), .routing));
}

// spec: placement/progress - the fab-ready rung is done exactly when the fab gate passed on a saved layout
test "fab-ready rung requires a passed gate on a saved layout" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var in = baseInputs(fixturePlacement(&.{}));

    // No report yet → not done, gate-not-run item.
    const r0 = try compute(arena, in);
    try testing.expect(!stageDone(r0, .fab_ready));
    try testing.expect(stageHasKind(stageById(r0, .fab_ready), "fab-gate-not-run"));

    // Clean report on a saved layout → done.
    in.fab_errors = &.{};
    in.from_saved_layout = true;
    try testing.expect(stageDone(try compute(arena, in), .fab_ready));

    // Clean report but the layout is the cache → not done, layout-not-saved.
    in.from_saved_layout = false;
    const r1 = try compute(arena, in);
    try testing.expect(!stageDone(r1, .fab_ready));
    try testing.expect(stageHasKind(stageById(r1, .fab_ready), "layout-not-saved"));

    // A failing gate → not done, the caller-mirrored fab-error items carried
    // onto the rung verbatim.
    const errs = [_]Item{.{ .id = "no-outline", .kind = "fab-error", .message = "no board outline" }};
    in.fab_errors = &errs;
    in.from_saved_layout = true;
    const r2 = try compute(arena, in);
    try testing.expect(!stageDone(r2, .fab_ready));
    try testing.expect(stageHasKind(stageById(r2, .fab_ready), "fab-error"));
}

// spec: placement/progress - the current stage is the first not-done rung even when a later rung is done
test "current is the first not-done rung despite a later done rung" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // Schematic blocked by ERC, yet the fab gate already passed on a saved
    // layout: out-of-order work.
    var in = baseInputs(fixturePlacement(&.{}));
    in.erc_error_count = 2;
    in.fab_errors = &.{};
    in.from_saved_layout = true;
    const r = try compute(arena, in);
    try testing.expect(r.current == .schematic);
    try testing.expect(stageById(r, .schematic).status == .current);
    try testing.expect(stageById(r, .fab_ready).status == .done);
}

// spec: placement/progress - ledger items carry stable ids across two recomputations of the same finding
test "ledger item ids are stable and finding-specific" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var parts = [_]optimizer.Part{
        .{ .ref_des = "U7", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .locked = false },
    };
    var in = baseInputs(fixturePlacement(&parts));
    const a = try compute(arena, in);
    const b = try compute(arena, in);
    const ia = firstItem(stageById(a, .placement), "unlocked-part") orelse return error.TestExpectedItem;
    const ib = firstItem(stageById(b, .placement), "unlocked-part") orelse return error.TestExpectedItem;
    try testing.expectEqualStrings(ia.id, ib.id);
    try testing.expectEqual(@as(usize, 4), ia.id.len);

    // A different part is a different finding → a different id.
    var other = [_]optimizer.Part{
        .{ .ref_des = "U8", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .locked = false },
    };
    in.placement = fixturePlacement(&other);
    const c = try compute(arena, in);
    const ic = firstItem(stageById(c, .placement), "unlocked-part") orelse return error.TestExpectedItem;
    try testing.expect(!std.mem.eql(u8, ia.id, ic.id));
}

// spec: placement/progress - writeJson emits all six stages with status, done, total, and open items
test "writeJson renders every stage and its open items" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var in = baseInputs(fixturePlacement(&.{}));
    in.erc_error_count = 1;
    const r = try compute(arena, in);
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeJson(&aw.writer, r);
    const out = aw.written();

    // All six stages present (one "status" key each), current is schematic.
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, out, "\"status\":"));
    try testing.expect(std.mem.indexOf(u8, out, "\"current\":\"schematic\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"id\":\"schematic\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"id\":\"fab_ready\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"status\":\"current\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"done\":0,\"total\":1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"erc-errors\"") != null);
}

// spec: placement/progress - an empty placement leaves the placement and routing rungs vacuously done
test "an empty placement has vacuously done placement and routing rungs" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // No parts, no nets: nothing to place or route, so both rungs are done.
    const in = baseInputs(fixturePlacement(&.{}));
    const r = try compute(arena, in);
    try testing.expect(stageDone(r, .placement));
    try testing.expect(stageDone(r, .routing));
    try testing.expectEqual(@as(usize, 0), stageById(r, .placement).total);
    try testing.expectEqual(@as(usize, 0), stageById(r, .placement).items.len);
}

// ── Wave-split (pcb-plan) tests ───────────────────────────────────────────────

/// A part fixture with the given ref-des and lock state.
fn partLocked(ref: []const u8, locked: bool) optimizer.Part {
    return .{ .ref_des = ref, .kind = .passive, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .locked = locked };
}

fn placeWave(name: []const u8, members: []const usize) plan_resolve.ResolvedWave {
    return .{ .name = name, .members = members };
}

fn waveByName(st: Stage, name: []const u8) ?WaveTally {
    for (st.waves) |wv| if (std.mem.eql(u8, wv.name, name)) return wv;
    return null;
}

// spec: placement/progress - a place wave is done only when every member part is locked
test "a place wave completes only when all its members are locked" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var parts = [_]optimizer.Part{ partLocked("U1", true), partLocked("C1", false) };
    const waves = [_]plan_resolve.ResolvedWave{placeWave("core", &.{ 0, 1 })};
    var in = baseInputs(fixturePlacement(&parts));
    in.plan = .{ .place = &waves };

    const r = try compute(arena, in);
    const core = waveByName(stageById(r, .placement), "core") orelse return error.TestExpectedWave;
    try testing.expectEqual(@as(usize, 2), core.total);
    try testing.expectEqual(@as(usize, 1), core.done);
    try testing.expect(!stageDone(r, .placement));

    parts[1].locked = true;
    const r2 = try compute(arena, in);
    try testing.expect(stageDone(r2, .placement));
    try testing.expect(waveByName(stageById(r2, .placement), "core").?.status == .done);
}

// spec: placement/progress - a route wave counts only its routable members toward done and total
test "a route wave ignores non-routable members" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const nets = [_]NetConn{
        .{ .name = "VBUS", .routable = true, .connected = true },
        .{ .name = "SIG", .routable = true, .connected = false },
        .{ .name = "TP", .routable = false, .connected = false },
    };
    const waves = [_]plan_resolve.ResolvedWave{placeWave("all", &.{ 0, 1, 2 })};
    var in = baseInputs(fixturePlacement(&.{}));
    in.net_conn = &nets;
    in.plan = .{ .route = &waves };

    const r = try compute(arena, in);
    const all = waveByName(stageById(r, .routing), "all") orelse return error.TestExpectedWave;
    // TP (non-routable) is excluded from the tally entirely.
    try testing.expectEqual(@as(usize, 2), all.total);
    try testing.expectEqual(@as(usize, 1), all.done);

    // A wave of only non-routable members is trivially done.
    const tp_only = [_]plan_resolve.ResolvedWave{placeWave("tp", &.{2})};
    in.plan = .{ .route = &tp_only };
    const r2 = try compute(arena, in);
    try testing.expect(stageDone(r2, .routing));
    try testing.expectEqual(@as(usize, 0), waveByName(stageById(r2, .routing), "tp").?.total);
}

// spec: placement/progress - the current wave is the first incomplete wave of the current stage
test "current_wave is the first incomplete wave of the current stage" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var parts = [_]optimizer.Part{ partLocked("U1", true), partLocked("C1", false) };
    const waves = [_]plan_resolve.ResolvedWave{ placeWave("a", &.{0}), placeWave("b", &.{1}) };
    var in = baseInputs(fixturePlacement(&parts));
    in.plan = .{ .place = &waves };

    const r = try compute(arena, in);
    try testing.expect(r.current == .placement);
    try testing.expectEqualStrings("b", r.current_wave.?);
    try testing.expect(waveByName(stageById(r, .placement), "a").?.status == .done);
    try testing.expect(waveByName(stageById(r, .placement), "b").?.status == .current);
}

// spec: placement/progress - an out-of-order advisory fires when a later wave progresses before an earlier one finishes
test "out-of-order advisory tracks wave order" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // Earlier wave "a" open (U1 unlocked), later wave "b" done (C1 locked).
    var parts = [_]optimizer.Part{ partLocked("U1", false), partLocked("C1", true) };
    const waves = [_]plan_resolve.ResolvedWave{ placeWave("a", &.{0}), placeWave("b", &.{1}) };
    var in = baseInputs(fixturePlacement(&parts));
    in.plan = .{ .place = &waves };
    const r = try compute(arena, in);
    try testing.expect(stageHasKind(stageById(r, .placement), "plan-out-of-order"));

    // Order respected — "a" done, "b" not started — no advisory.
    parts[0].locked = true;
    parts[1].locked = false;
    const r2 = try compute(arena, in);
    try testing.expect(!stageHasKind(stageById(r2, .placement), "plan-out-of-order"));
}

// spec: placement/progress - writeJson renders the per-wave tallies and tags open items with their wave
test "writeJson renders waves and wave-tagged items" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var parts = [_]optimizer.Part{partLocked("U1", false)};
    const waves = [_]plan_resolve.ResolvedWave{placeWave("core", &.{0})};
    var in = baseInputs(fixturePlacement(&parts));
    in.plan = .{ .place = &waves };
    const r = try compute(arena, in);

    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeJson(&aw.writer, r);
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "\"waves\":[") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"name\":\"core\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"wave\":\"core\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"current_wave\":\"core\"") != null);
}

// spec: placement/progress - plan warnings surface in the report and in its JSON
test "plan warnings surface in the report" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const warns = [_]plan_resolve.Warning{
        .{
            .id = "abcd",
            .kind = "plan-unknown-name",
            .message = "wave \"core\" names unknown ref \"NOPE\"",
            .wave = "core",
            .name = "NOPE",
        },
    };
    var in = baseInputs(fixturePlacement(&.{}));
    in.plan = .{ .warnings = &warns };
    const r = try compute(arena, in);
    try testing.expectEqual(@as(usize, 1), r.warnings.len);
    try testing.expectEqualStrings("plan-unknown-name", r.warnings[0].kind);

    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeJson(&aw.writer, r);
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "\"warnings\":[") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"plan-unknown-name\"") != null);
}

// spec: placement/progress - connected nets with exceeded or unverified authored via budgets keep their routing wave incomplete
test "routing via budget blocks connected copper until the total is verified" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    var parts = [_]optimizer.Part{partLocked("U1", true)};
    var in = baseInputs(fixturePlacement(&parts));
    var nets = [_]NetConn{.{ .name = "SIG", .routable = true, .connected = true, .vias = 3 }};
    const waves = [_]plan_resolve.ResolvedWave{.{ .name = "control", .members = &.{0}, .max_vias = 2 }};
    in.net_conn = &nets;
    in.plan.route = &waves;
    const over = try routingStageWaves(arena, in);
    try testing.expectEqual(@as(usize, 0), over.done);
    try testing.expectEqualStrings("via-budget-exceeded", over.items[0].kind);
    try testing.expectEqualStrings("SIG", over.items[0].net.?);
    try testing.expectEqual(@as(usize, 3), over.items[0].meta.count);
    nets[0].vias = null;
    const unknown = try routingStageWaves(arena, in);
    try testing.expectEqualStrings("via-budget-unverified", unknown.items[0].kind);
    nets[0].vias = 2;
    const met = try routingStageWaves(arena, in);
    try testing.expectEqual(@as(usize, 1), met.done);
    try testing.expectEqual(@as(usize, 0), met.items.len);
}
