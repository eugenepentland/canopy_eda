//! The Board Review Audit, generated: every machine-derivable cell of the
//! release standard's per-board audit form, from the same evidence the gates
//! use — the release-profile check run, ERC, the component-class profile
//! evaluation, the layout completion ladder, the fabrication-readiness gate
//! and the design notes. Disposition cells are left for the reviewer. The
//! document is composed to parse under the system-review Markdown rules, so
//! it can be registered as a board-scoped review document as it is.

const std = @import("std");
const bom = @import("bom.zig");
const clock = @import("infra/clock.zig");
const review = @import("review.zig");
const component_classification = @import("component_classification.zig");
const env = @import("eval/env.zig");
const erc_mod = @import("erc.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;
const fab_service = @import("serve/fab_release_service.zig");
const infra_fs = @import("infra/fs.zig");
const notes = @import("serve/notes.zig");
const paths = @import("paths.zig");
const pcb_describe = @import("serve/pcb_describe.zig");
const preflight = @import("preflight.zig");
const review_profiles = @import("review_profiles.zig");

/// Which saved layout to audit; null means the starred one.
pub const Options = struct {
    layout: ?[]const u8 = null,
};

/// Everything `render` can fail with beyond allocation.
pub const RenderError = std.mem.Allocator.Error || error{ EvaluateFailed, NotADesign, InvalidName };

/// The board and the run the audit describes.
pub const Identity = struct {
    name: []const u8,
    revision: []const u8,
    part_number: []const u8,
    layout: []const u8,
    project_status: []const u8,
    tool_commit: []const u8,
    generated_at: []const u8,
};

/// The content digests the fabrication gate bound the evidence to.
pub const Digests = struct {
    layout_sha256: []const u8 = "",
    source_sha256: []const u8 = "",
    release_token: []const u8 = "",
    fab_id: []const u8 = "",
    project_commit: []const u8 = "",
};

/// Schematic-side tallies from the release-profile check run.
pub const Schematic = struct {
    preflight_errors: usize = 0,
    preflight_warnings: usize = 0,
    preflight_infos: usize = 0,
    erc_errors: usize = 0,
    erc_warnings: usize = 0,
    build_warnings: []const []const u8 = &.{},
    notes_open: usize = 0,
};

/// One rung of the layout completion ladder.
pub const StageRow = struct {
    id: []const u8,
    status: []const u8,
    done: usize,
    total: usize,
};

/// One DRC warning kind and how many the release run reported.
pub const KindCount = struct {
    kind: []const u8,
    count: usize,
};

/// Layout-side evidence: the ladder and the DRC tallies.
pub const Layout = struct {
    available: bool = false,
    ladder: []const StageRow = &.{},
    drc_errors: usize = 0,
    drc_warnings: usize = 0,
    by_kind: []const KindCount = &.{},
};

/// The fabrication gate's board statistics.
pub const FabStats = struct {
    parts: usize = 0,
    nets: usize = 0,
    routable: usize = 0,
    connected: usize = 0,
    tracks: usize = 0,
    vias: usize = 0,
    dnp: usize = 0,
};

/// The fabrication gate verdict and its finding ids.
pub const Fab = struct {
    available: bool = false,
    ok: bool = false,
    needs_waiver: bool = false,
    error_ids: []const []const u8 = &.{},
    warning_ids: []const []const u8 = &.{},
    stats: FabStats = .{},
};

/// One active part's row in the per-component profile table.
pub const PartRow = struct {
    ref: []const u8,
    component: []const u8,
    class: []const u8,
    review: []const u8,
    checks: []const u8,
    data: []const u8,
    unmet: []const u8,
};

/// One error- or warning-severity finding for the register.
pub const FindingRow = struct {
    source: []const u8,
    severity: []const u8,
    ref: []const u8,
    message: []const u8,
};

/// Every fact the audit renders, collected once and rendered purely.
pub const Facts = struct {
    identity: Identity,
    digests: Digests = .{},
    schematic: Schematic = .{},
    layout: Layout = .{},
    fab: Fab = .{},
    parts: []const PartRow = &.{},
    findings: []const FindingRow = &.{},
};

const max_finding_rows: usize = 400;
const max_cell_bytes: usize = 200;

// ── Rendering ─────────────────────────────────────────────────────────────

/// Write `text` as one safe table cell: pipes, angle brackets, backticks,
/// emphasis markers, link brackets and control bytes are replaced so no
/// engine text can open Markdown or HTML structure, and long text is clipped
/// on a codepoint boundary.
fn writeCell(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    var written: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(text.len, i + len);
        if (written + (end - i) > max_cell_bytes) {
            try w.writeAll("…");
            return;
        }
        const slice = text[i..end];
        if (slice.len == 1) {
            switch (slice[0]) {
                '|' => try w.writeAll("/"),
                '<' => try w.writeAll("‹"),
                '>' => try w.writeAll("›"),
                '`' => try w.writeAll("'"),
                '*' => try w.writeAll("·"),
                '[' => try w.writeAll("("),
                ']' => try w.writeAll(")"),
                '\n', '\r', '\t' => try w.writeAll(" "),
                else => |c| if (c < 0x20) try w.writeAll(" ") else try w.writeByte(c),
            }
        } else try w.writeAll(slice);
        written += end - i;
        i = end;
    }
}

fn row(w: *std.Io.Writer, cols: []const []const u8) std.Io.Writer.Error!void {
    try w.writeAll("|");
    for (cols) |col| {
        try w.writeAll(" ");
        try writeCell(w, col);
        try w.writeAll(" |");
    }
    try w.writeAll("\n");
}

fn header(w: *std.Io.Writer, cols: []const []const u8) std.Io.Writer.Error!void {
    try row(w, cols);
    try w.writeAll("|");
    for (cols) |_| try w.writeAll(" --- |");
    try w.writeAll("\n");
}

fn fmtBuf(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch "…";
}

fn ladderCell(buf: []u8, ladder: []const StageRow, id: []const u8) []const u8 {
    for (ladder) |stage| if (std.mem.eql(u8, stage.id, id)) {
        return fmtBuf(buf, "{s}: {s} {d}/{d}", .{ id, stage.status, stage.done, stage.total });
    };
    return fmtBuf(buf, "{s}: not run", .{id});
}

fn joinIds(allocator: std.mem.Allocator, ids: []const []const u8) std.mem.Allocator.Error![]const u8 {
    if (ids.len == 0) return try allocator.dupe(u8, "none");
    return try std.mem.join(allocator, ", ", ids);
}

/// Render the audit from already-collected facts. Pure, so a fixture can
/// prove the output parses under the package's Markdown rules.
pub fn renderFacts(allocator: std.mem.Allocator, facts: Facts) std.mem.Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var buf: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;
    var buf3: [256]u8 = undefined;

    renderInner(w, arena, facts, &buf, &buf2, &buf3) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return try out.toOwnedSlice();
}

fn renderInner(
    w: *std.Io.Writer,
    arena: std.mem.Allocator,
    facts: Facts,
    buf: []u8,
    buf2: []u8,
    buf3: []u8,
) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
    const id = facts.identity;
    try w.writeAll("# ");
    try writeCell(w, id.name);
    try w.writeAll(" Board Review Audit\n\n");
    try w.writeAll("Generated by netlisp review-audit on ");
    try writeCell(w, id.generated_at);
    try w.writeAll(" from generated evidence, per docs/design-review-standard.md. Every Result is a value the tool returned; the reviewer fills each Disposition with fixed, waived (link the record), blocking (link the checklist item), or escalated (what a person must decide).\n\n");

    try w.writeAll("## Identity\n\n");
    try header(w, &.{ "Field", "Value" });
    try row(w, &.{ "Design", id.name });
    try row(w, &.{ "Board revision / part number", fmtBuf(buf, "{s} / {s}", .{ id.revision, id.part_number }) });
    try row(w, &.{ "Released layout", id.layout });
    try row(w, &.{ "layout_sha256", facts.digests.layout_sha256 });
    try row(w, &.{ "source_sha256", facts.digests.source_sha256 });
    try row(w, &.{ "release_token", facts.digests.release_token });
    try row(w, &.{ "fab_id", facts.digests.fab_id });
    try row(w, &.{ "project_commit / tool_commit", fmtBuf(buf, "{s} / {s}", .{ facts.digests.project_commit, id.tool_commit }) });
    try row(w, &.{ "Audit date / auditor", fmtBuf(buf, "{s} / netlisp review-audit", .{id.generated_at}) });
    try row(w, &.{ "Tree state", id.project_status });
    try w.writeAll("\n");

    const audit_cols = [_][]const u8{ "Check", "Result", "Evidence", "Disposition" };
    try w.writeAll("## Stage 0 — Identity and source closure\n\n");
    try header(w, &audit_cols);
    try row(w, &.{ "Clean tree", id.project_status, "run_fab_readiness.project_status", "" });
    try row(w, &.{ "(revision …) declared", if (id.revision.len > 0) id.revision else "missing", "board source", "" });
    const build_warnings = fmtBuf(buf, "{d} evaluator warning(s)", .{facts.schematic.build_warnings.len});
    try row(w, &.{ "Build warnings", build_warnings, if (facts.schematic.build_warnings.len > 0) facts.schematic.build_warnings[0] else "netlisp build", "" });
    if (facts.layout.available) {
        const placement = ladderCell(buf, facts.layout.ladder, "placement");
        const subs = ladderCell(buf2, facts.layout.ladder, "sub_circuits");
        try row(w, &.{ "Layout frozen: parts locked, sub-blocks starred", fmtBuf(buf3, "{s}; {s}", .{ placement, subs }), "get_layout_progress", "" });
    } else {
        try row(w, &.{ "Layout frozen: parts locked, sub-blocks starred", "layout progress unavailable", "get_layout_progress", "" });
    }
    try row(w, &.{ "Stable identities and gate errors", try joinIds(arena, facts.fab.error_ids), "run_fab_readiness.errors", "" });
    try w.writeAll("\n");

    try w.writeAll("## Stage 1 — Schematic\n\n");
    try header(w, &audit_cols);
    const s = facts.schematic;
    try row(w, &.{ "Release-profile check: errors / warnings / infos", fmtBuf(buf, "{d} / {d} / {d}", .{ s.preflight_errors, s.preflight_warnings, s.preflight_infos }), "netlisp check --profile release", "" });
    try row(w, &.{ "ERC errors / warnings", fmtBuf(buf, "{d} / {d}", .{ s.erc_errors, s.erc_warnings }), "netlisp check", "" });
    var reviewed: usize = 0;
    var unmet_parts: usize = 0;
    for (facts.parts) |part| {
        if (std.mem.eql(u8, part.review, "pass")) reviewed += 1;
        if (!std.mem.eql(u8, part.unmet, "none")) unmet_parts += 1;
    }
    try row(w, &.{ "Active parts with a complete datasheet review / total", fmtBuf(buf, "{d} / {d}", .{ reviewed, facts.parts.len }), "run_checks datasheet_review", "" });
    try row(w, &.{ "Active parts with unmet class-profile items / total", fmtBuf(buf, "{d} / {d}", .{ unmet_parts, facts.parts.len }), "run_checks profile_incomplete", "" });
    try row(w, &.{ "Open design notes", fmtBuf(buf, "{d}", .{s.notes_open}), "list_design_notes", "" });
    try w.writeAll("\n");

    try w.writeAll("## Stage 1b — Per-component profile compliance\n\n");
    try header(w, &.{ "Ref", "Component", "Class profile", "Review", "Checks", "Electrical / currents", "Unmet items", "Disposition" });
    for (facts.parts) |part| {
        try row(w, &.{ part.ref, part.component, part.class, part.review, part.checks, part.data, part.unmet, "" });
    }
    if (facts.parts.len == 0) try row(w, &.{ "none", "no active parts", "", "", "", "", "", "" });
    try w.writeAll("\n");

    try w.writeAll("## Stage 2 and 3 — Analyses and BOM (run by hand)\n\n");
    try w.writeAll("- Thermal at the maximum rated ambient in the release cooling scenario: netlisp tool describe_thermal, the Thermal tab on the release layout.\n");
    try w.writeAll("- Power budget and sequencing: the review PDF's Power budget and Power sequencing sheets; every rail's consumers annotated with (i-typ …)(i-max …).\n");
    try w.writeAll("- Ratings: component-rating findings in run_fab_readiness; net envelopes authored where derivation stops.\n");
    try w.writeAll("- Domain analyses in gate mode: pll-loop, frequency-plan, pdn, and the RF level budget as assert rows.\n");
    try w.writeAll("- BOM: identities, authored passive specs (the bom-spec findings), lifecycle and dated stock via resolve_mpn and check_stock, DC-bias effective capacitance, the DNP list.\n\n");

    try w.writeAll("## Stage 4 — Layout\n\n");
    try header(w, &audit_cols);
    if (facts.layout.available) {
        for (facts.layout.ladder) |stage| {
            try row(w, &.{ fmtBuf(buf, "Ladder rung {s}", .{stage.id}), fmtBuf(buf2, "{s} {d}/{d}", .{ stage.status, stage.done, stage.total }), "get_layout_progress", "" });
        }
    } else {
        try row(w, &.{ "Completion ladder", "unavailable", "get_layout_progress", "" });
    }
    try row(w, &.{ "DRC errors / warnings on the release layout", fmtBuf(buf, "{d} / {d}", .{ facts.layout.drc_errors, facts.layout.drc_warnings }), "run_fab_readiness.raw_drc", "" });
    for (facts.layout.by_kind) |kind| {
        try row(w, &.{ fmtBuf(buf, "DRC warnings: {s}", .{kind.kind}), fmtBuf(buf2, "{d}", .{kind.count}), "docs/drc-waivers.md must list this count", "" });
    }
    try w.writeAll("\n");

    try w.writeAll("## Stage 5 — Fabrication package\n\n");
    try header(w, &audit_cols);
    const f = facts.fab;
    try row(w, &.{ "run_fab_readiness", if (!f.available) "unavailable" else if (f.ok) "ok" else "blocked", "run_fab_readiness.ok", "" });
    try row(w, &.{ "Gate errors", try joinIds(arena, f.error_ids), "run_fab_readiness.errors", "" });
    try row(w, &.{ "Gate warnings", try joinIds(arena, f.warning_ids), "run_fab_readiness.warnings", "" });
    try row(w, &.{ "needs_waiver explained by the register", if (f.needs_waiver) "needs waiver" else "no waiver needed", "docs/drc-waivers.md", "" });
    try row(w, &.{ "Parts / nets / routable / connected", fmtBuf(buf, "{d} / {d} / {d} / {d}", .{ f.stats.parts, f.stats.nets, f.stats.routable, f.stats.connected }), "run_fab_readiness.stats", "" });
    try row(w, &.{ "Tracks / vias / DNP parts", fmtBuf(buf, "{d} / {d} / {d}", .{ f.stats.tracks, f.stats.vias, f.stats.dnp }), "run_fab_readiness.stats", "" });
    try row(w, &.{ "Differential vs previous release", "run gerber-dump --digest and netlist-dump on both commits", "diff -I '^#'", "" });
    try w.writeAll("\n");

    try w.writeAll("## Findings register\n\n");
    try header(w, &.{ "Source", "Severity", "Ref", "Finding", "Disposition", "Owner", "Date" });
    var shown: usize = 0;
    for (facts.findings) |finding| {
        if (shown == max_finding_rows) break;
        try row(w, &.{ finding.source, finding.severity, finding.ref, finding.message, "", "", "" });
        shown += 1;
    }
    if (facts.findings.len > shown) {
        try row(w, &.{ "…", "", "", fmtBuf(buf, "{d} further findings not listed; read run_checks", .{facts.findings.len - shown}), "", "", "" });
    }
    if (facts.findings.len == 0) try row(w, &.{ "none", "", "", "no error or warning findings", "", "", "" });
    try w.writeAll("\n## Open questions for a human\n\n- (state the question, the options, and what each costs)\n");
}

// ── Collection ────────────────────────────────────────────────────────────

fn jsonStr(value: std.json.Value, key: []const u8) []const u8 {
    if (value != .object) return "";
    const field = value.object.get(key) orelse return "";
    return if (field == .string) field.string else "";
}

fn jsonInt(value: std.json.Value, key: []const u8) usize {
    if (value != .object) return 0;
    const field = value.object.get(key) orelse return 0;
    return switch (field) {
        .integer => |n| if (n < 0) 0 else @intCast(n),
        else => 0,
    };
}

fn idList(arena: std.mem.Allocator, value: std.json.Value, key: []const u8) std.mem.Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (value != .object) return &.{};
    const list = value.object.get(key) orelse return &.{};
    if (list != .array) return &.{};
    for (list.array.items) |item| {
        const id = jsonStr(item, "id");
        if (id.len > 0) try out.append(arena, try arena.dupe(u8, id));
    }
    return try out.toOwnedSlice(arena);
}

/// Walks the design tree collecting one `PartRow` per active part.
const PartCollector = struct {
    arena: std.mem.Allocator,
    project_dir: []const u8,
    forms: review_profiles.Forms,
    report: preflight.Report,
    parts: *std.ArrayList(PartRow),

    fn collect(self: PartCollector, block: *const env.DesignBlock, prefix: []const u8) std.mem.Allocator.Error!void {
        return collectParts(self, block, prefix);
    }
};

fn collectParts(self: PartCollector, block: *const env.DesignBlock, prefix: []const u8) std.mem.Allocator.Error!void {
    const arena = self.arena;
    const project_dir = self.project_dir;
    const forms = self.forms;
    const report = self.report;
    const parts = self.parts;
    for (block.instances) |inst| {
        if (inst.placeholder or !component_classification.isActiveSemiconductor(inst)) continue;
        const ref = if (prefix.len == 0) inst.ref_des else try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, inst.ref_des });
        const resolved = review_profiles.resolve(arena, project_dir, inst);
        const class = if (resolved.declared) resolved.class.key() else try std.fmt.allocPrint(arena, "{s} (inferred)", .{resolved.class.key()});
        var review_status: []const u8 = "missing";
        var checks_ok: usize = 0;
        var checks_unmet: usize = 0;
        for (report.findings) |finding| {
            if (!std.mem.eql(u8, finding.ref_des, inst.ref_des) or !std.mem.eql(u8, finding.component, inst.component)) continue;
            switch (finding.kind) {
                .datasheet_review => review_status = @tagName(finding.status),
                .requirement => if (finding.status == .pass or finding.status == .verified) {
                    checks_ok += 1;
                } else {
                    checks_unmet += 1;
                },
                else => {},
            }
        }
        const items = try review_profiles.evaluate(arena, arena, inst, .{ .block = block, .project_dir = project_dir, .forms = forms, .require_requirements = true });
        var codes: std.ArrayList([]const u8) = .empty;
        var currents_missing = false;
        for (items) |item| {
            if (std.mem.eql(u8, item.code, "supply-current")) currents_missing = true;
            var seen = false;
            for (codes.items) |code| if (std.mem.eql(u8, code, item.code)) {
                seen = true;
            };
            if (!seen) try codes.append(arena, item.code);
        }
        try parts.append(arena, .{
            .ref = ref,
            .component = inst.component,
            .class = class,
            .review = review_status,
            .checks = try std.fmt.allocPrint(arena, "{d} ok / {d} unmet", .{ checks_ok, checks_unmet }),
            .data = try std.fmt.allocPrint(arena, "{d} electrical decl(s); supply-current item {s}", .{ inst.electrical.len, if (currents_missing) "open" else "closed" }),
            .unmet = if (codes.items.len == 0) "none" else try std.mem.join(arena, ", ", codes.items),
        });
    }
    for (block.sub_blocks) |sub| {
        const sub_prefix = if (prefix.len == 0) sub.name else try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, sub.name });
        try self.collect(sub.block, sub_prefix);
    }
}

fn collectFab(arena: std.mem.Allocator, project_dir: []const u8, name: []const u8, layout: ?[]const u8, facts: *Facts) std.mem.Allocator.Error!void {
    const result = fab_service.readiness(arena, project_dir, name, .{ .layout = layout }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    facts.fab.available = true;
    facts.fab.ok = !result.readiness.blocked;
    facts.fab.needs_waiver = result.readiness.needs_waiver;
    facts.identity.revision = result.identity.revision;
    facts.identity.part_number = result.identity.part_number;
    facts.identity.layout = result.identity.layout;
    facts.identity.project_status = @tagName(result.lock.project_status);
    facts.digests.project_commit = result.lock.project_commit;
    facts.digests.release_token = try arena.dupe(u8, &result.lock.release_token);
    facts.digests.fab_id = try arena.dupe(u8, &result.lock.fab_id);
    facts.digests.layout_sha256 = try arena.dupe(u8, &result.digests.layout);
    facts.digests.source_sha256 = try arena.dupe(u8, &result.digests.source);
    var parsed = std.json.parseFromSlice(std.json.Value, arena, result.readiness.json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer parsed.deinit();
    const root = parsed.value;
    facts.identity.tool_commit = try arena.dupe(u8, jsonStr(root, "tool_commit"));
    facts.fab.error_ids = try idList(arena, root, "errors");
    facts.fab.warning_ids = try idList(arena, root, "warnings");
    if (root == .object) if (root.object.get("stats")) |stats| {
        facts.fab.stats = .{
            .parts = jsonInt(stats, "parts"),
            .nets = jsonInt(stats, "nets"),
            .routable = jsonInt(stats, "routable_nets"),
            .connected = jsonInt(stats, "connected_nets"),
            .tracks = jsonInt(stats, "tracks"),
            .vias = jsonInt(stats, "vias"),
            .dnp = jsonInt(stats, "dnp_parts"),
        };
    };
    var counts: std.StringArrayHashMapUnmanaged(usize) = .empty;
    if (root == .object) if (root.object.get("raw_drc")) |raw| if (raw == .array) {
        for (raw.array.items) |item| {
            const severity = jsonStr(item, "severity");
            if (std.mem.eql(u8, severity, "err")) {
                facts.layout.drc_errors += 1;
                continue;
            }
            facts.layout.drc_warnings += 1;
            const kind = try arena.dupe(u8, jsonStr(item, "kind"));
            const gop = try counts.getOrPut(arena, kind);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
    };
    var by_kind: std.ArrayList(KindCount) = .empty;
    var it = counts.iterator();
    while (it.next()) |entry| try by_kind.append(arena, .{ .kind = entry.key_ptr.*, .count = entry.value_ptr.* });
    facts.layout.by_kind = try by_kind.toOwnedSlice(arena);
}

fn collectLadder(arena: std.mem.Allocator, project_dir: []const u8, name: []const u8, layout: ?[]const u8, facts: *Facts) std.mem.Allocator.Error!void {
    const body = pcb_describe.describeProgress(arena, project_dir, name, .{ .layout = layout }, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    var parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const stages = parsed.value.object.get("stages") orelse return;
    if (stages != .array) return;
    var ladder: std.ArrayList(StageRow) = .empty;
    for (stages.array.items) |stage| {
        try ladder.append(arena, .{
            .id = try arena.dupe(u8, jsonStr(stage, "id")),
            .status = try arena.dupe(u8, jsonStr(stage, "status")),
            .done = jsonInt(stage, "done"),
            .total = jsonInt(stage, "total"),
        });
    }
    facts.layout.ladder = try ladder.toOwnedSlice(arena);
    facts.layout.available = true;
}

fn collectNotes(arena: std.mem.Allocator, board_path: []const u8, name: []const u8) std.mem.Allocator.Error!usize {
    const dir = std.fs.path.dirname(board_path) orelse return 0;
    const path = try std.fmt.allocPrint(arena, "{s}/{s}.notes.md", .{ dir, name });
    const raw = infra_fs.cwd().readFileAlloc(arena, path, 1024 * 1024) catch return 0;
    const parsed = try notes.parseNotes(arena, raw);
    var open: usize = 0;
    for (parsed.tasks) |task| if (task.completed == null) {
        open += 1;
    };
    return open;
}

/// Collect every fact and render the audit. The returned Markdown is owned
/// by `allocator`.
pub fn render(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    options: Options,
) RenderError![]u8 {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    var eval = Evaluator.init(arena, project_dir);
    defer eval.deinit();
    const board_path = try paths.designSourcePath(arena, project_dir, name);
    const result = eval.evalFile(board_path) catch return error.EvaluateFailed;
    const block = switch (result) {
        .design_block => |b| b,
        else => return error.NotADesign,
    };
    const bom_path = try paths.designSiblingPath(arena, project_dir, name, ".bom");
    var bom_warning: ?[]const u8 = null;
    bom.applyExisting(arena, block, bom_path, project_dir) catch |err| {
        bom_warning = try std.fmt.allocPrint(arena, "existing BOM identity merge skipped: {s}", .{@errorName(err)});
    };

    var facts = Facts{ .identity = .{
        .name = name,
        .revision = if (block.revision.present) block.revision.id else "",
        .part_number = "",
        .layout = options.layout orelse "starred",
        .project_status = "unknown",
        .tool_commit = "",
        .generated_at = try review.isoTimestamp(arena, clock.timestamp()),
    } };

    const violations = try erc_mod.runErc(arena, block, project_dir);
    const report = try preflight.run(arena, &eval, block, project_dir, .release);
    var forms: review_profiles.Forms = .{};
    for (eval.pll_reports.items) |pll| {
        forms.pll_any = true;
        forms.pll_gate = pll.mode == .gate;
    }
    for (eval.frequency_plan_reports.items) |plan| {
        forms.plan_any = true;
        forms.plan_gate = plan.mode == .gate;
    }

    var build_warnings: std.ArrayList([]const u8) = .empty;
    if (bom_warning) |warning| try build_warnings.append(arena, warning);
    var findings: std.ArrayList(FindingRow) = .empty;
    for (report.findings) |finding| {
        switch (finding.severity) {
            .@"error" => facts.schematic.preflight_errors += 1,
            .warning => facts.schematic.preflight_warnings += 1,
            .info => facts.schematic.preflight_infos += 1,
        }
        if (finding.kind == .eval_warning) try build_warnings.append(arena, finding.message);
        if (finding.severity == .info) continue;
        try findings.append(arena, .{
            .source = @tagName(finding.kind),
            .severity = @tagName(finding.severity),
            .ref = finding.ref_des,
            .message = finding.message,
        });
    }
    for (violations) |violation| {
        switch (violation.severity) {
            .@"error" => facts.schematic.erc_errors += 1,
            .warning => facts.schematic.erc_warnings += 1,
            .info => {},
        }
        if (violation.severity == .info) continue;
        try findings.append(arena, .{
            .source = @tagName(violation.kind),
            .severity = @tagName(violation.severity),
            .ref = if (violation.ref_des.len > 0) violation.ref_des else violation.net,
            .message = violation.message,
        });
    }
    facts.schematic.build_warnings = try build_warnings.toOwnedSlice(arena);
    facts.findings = try findings.toOwnedSlice(arena);
    facts.schematic.notes_open = try collectNotes(arena, board_path, name);

    var parts: std.ArrayList(PartRow) = .empty;
    const collector = PartCollector{ .arena = arena, .project_dir = project_dir, .forms = forms, .report = report, .parts = &parts };
    try collector.collect(block, "");
    facts.parts = try parts.toOwnedSlice(arena);

    try collectFab(arena, project_dir, name, options.layout, &facts);
    try collectLadder(arena, project_dir, name, options.layout, &facts);

    return try renderFacts(allocator, facts);
}

// ── Tests ─────────────────────────────────────────────────────────────────

const system_review_md = @import("system_review_md.zig");

// spec: review-audit - the rendered audit parses as safe review Markdown with no raw HTML
test "rendered audit survives the package Markdown rules with hostile cells" {
    const allocator = std.testing.allocator;
    const facts = Facts{
        .identity = .{
            .name = "demo",
            .revision = "B4",
            .part_number = "PN-1",
            .layout = "Layout | one",
            .project_status = "clean",
            .tool_commit = "abc123",
            .generated_at = "2026-09-01",
        },
        .digests = .{ .layout_sha256 = "aa", .source_sha256 = "bb", .release_token = "cc", .fab_id = "dd", .project_commit = "ee" },
        .schematic = .{ .preflight_errors = 1, .preflight_warnings = 2, .build_warnings = &.{"unknown sub-form (placement-order …) in (design-block …)"}, .notes_open = 3 },
        .layout = .{ .available = true, .ladder = &.{.{ .id = "placement", .status = "current", .done = 0, .total = 224 }}, .drc_warnings = 2, .by_kind = &.{.{ .kind = "land_transit", .count = 2 }} },
        .fab = .{ .available = true, .ok = true, .needs_waiver = true, .warning_ids = &.{"drc-warn"} },
        .parts = &.{.{ .ref = "adf/U1", .component = "adf4159", .class = "pll-loop (inferred)", .review = "pass", .checks = "3 ok / 1 unmet", .data = "0 electrical decl(s); supply-current item open", .unmet = "control-levels, supply-current" }},
        .findings = &.{
            .{ .source = "layout_class_inferred", .severity = "warning", .ref = "V_24V", .message = "pin it with (module-policy (net-class \"V_24V\" <class>)) `now` **bold** [x]" },
            .{ .source = "eval_warning", .severity = "error", .ref = "", .message = "<script>alert(1)</script>" },
        },
    };
    const markdown = try renderFacts(allocator, facts);
    defer allocator.free(markdown);
    var parsed = try system_review_md.parse(allocator, markdown, .{});
    defer parsed.deinit();
    try std.testing.expect(std.mem.indexOf(u8, markdown, "<class>") == null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "<script") == null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "Layout / one") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "## Stage 1b") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "pll-loop (inferred)") != null);
}
