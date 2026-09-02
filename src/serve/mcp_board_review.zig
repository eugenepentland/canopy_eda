//! Agent-facing board-review queue and disposition recorder.
//!
//! `review_checklist` returns all 258 generated item packets. An agent inspects
//! only entries whose method is `agent`, then records evidence through
//! `record_review_item`; it never edits the sidecar by hand.

const std = @import("std");
const catalog = @import("../board_review_catalog.zig");
const review_assessment = @import("../review_assessment.zig");
const review_audit = @import("../review_audit.zig");
const review_datasheets = @import("../review_datasheet_inventory.zig");
const review_state = @import("../board_review_state.zig");
const clock = @import("../infra/clock.zig");
const infra_fs = @import("../infra/fs.zig");
const json_writer = @import("../json_writer.zig");
const paths = @import("../paths.zig");
const review = @import("../review.zig");

/// Allocation and JSON-output failures exposed by the MCP implementations.
pub const RunError = std.mem.Allocator.Error || std.Io.Writer.Error;
var mutation_mutex: infra_fs.Mutex = .{};

fn argString(args: ?std.json.Value, key: []const u8, max_len: usize) ?[]const u8 {
    const root = args orelse return null;
    if (root != .object) return null;
    const value = root.object.get(key) orelse return null;
    if (value != .string or value.string.len > max_len) return null;
    return value.string;
}

fn designExists(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) bool {
    const source = paths.designSourcePath(allocator, project_dir, name) catch return false;
    defer allocator.free(source);
    infra_fs.cwd().access(source, .{}) catch return false;
    return true;
}

fn fail(out: *std.ArrayList(u8), allocator: std.mem.Allocator, message: []const u8) RunError!bool {
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();
    try buffer.writer.writeAll("{\"ok\":false,\"error\":");
    try json_writer.writeString(&buffer.writer, message);
    try buffer.writer.writeByte('}');
    try out.appendSlice(allocator, buffer.written());
    return false;
}

/// Full generated checklist plus any saved human/agent overrides.
pub fn runChecklist(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    args: ?std.json.Value,
    out: *std.ArrayList(u8),
) RunError!bool {
    const name = argString(args, "name", 256) orelse return fail(out, allocator, "missing required name");
    const layout = argString(args, "layout", 256);
    var scratch_state = std.heap.ArenaAllocator.init(allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const facts = review_audit.collectFacts(scratch, project_dir, name, .{ .layout = layout }) catch |err|
        return fail(out, allocator, @errorName(err));
    const items = review_assessment.build(scratch, facts) catch |err|
        return fail(out, allocator, @errorName(err));
    const entries = review_state.loadEntries(scratch, project_dir, name) catch |err|
        return fail(out, allocator, @errorName(err));
    const datasheets = review_datasheets.collect(scratch, project_dir, name) catch |err|
        return fail(out, allocator, @errorName(err));

    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();
    try buffer.writer.writeAll("{\"ok\":true,\"name\":");
    try json_writer.writeString(&buffer.writer, name);
    try buffer.writer.writeAll(",\"layout\":");
    try json_writer.writeString(&buffer.writer, facts.identity.layout);
    try buffer.writer.writeAll(",\"scope\":{\"sourcing\":false,\"fabrication_documents\":false,\"fabrication_rules\":\"configured DRC profile\"}");
    try buffer.writer.writeAll(",\"agent_contract\":{\"rule\":\"Do not record needs_info for evidence obtainable from the BOM, library, datasheets, schematic, layout, or built-in analyses. Exhaust those tools first.\",\"datasheet_sequence\":[\"review_datasheet_inventory\",\"read_datasheet when local\",\"download_datasheet when missing\",\"fetch_datasheet from the manufacturer URL when catalogue download fails; include source_page when the vendor requires a product-page referrer\",\"read_datasheet and calculate at the board operating point\"],\"needs_info_requires\":\"The attempted field must name the tools, exact MPNs, and concrete failure or genuinely external input.\"}");
    try buffer.writer.writeAll(",\"datasheets\":");
    try review_datasheets.writeInventory(&buffer.writer, datasheets);
    try buffer.writer.writeAll(",\"generated\":");
    try review_assessment.writeAssessmentJson(&buffer.writer, items);
    try buffer.writer.writeAll(",\"overrides\":[");
    for (entries, 0..) |entry, index| {
        if (index > 0) try buffer.writer.writeByte(',');
        try review_state.writeEntryJson(&buffer.writer, entry);
    }
    try buffer.writer.writeAll("]}");
    try out.appendSlice(allocator, buffer.written());
    return true;
}

/// Exact fitted-MPN datasheet coverage and mandatory acquisition actions.
pub fn runDatasheetInventory(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    args: ?std.json.Value,
    out: *std.ArrayList(u8),
) RunError!bool {
    const name = argString(args, "name", 256) orelse return fail(out, allocator, "missing required name");
    if (!designExists(allocator, project_dir, name)) return fail(out, allocator, "no design by that name");
    var scratch_state = std.heap.ArenaAllocator.init(allocator);
    defer scratch_state.deinit();
    const rows = review_datasheets.collect(scratch_state.allocator(), project_dir, name) catch |err|
        return fail(out, allocator, @errorName(err));
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();
    try buffer.writer.writeAll("{\"ok\":true,\"name\":");
    try json_writer.writeString(&buffer.writer, name);
    try buffer.writer.writeAll(",\"datasheets\":");
    try review_datasheets.writeInventory(&buffer.writer, rows);
    try buffer.writer.writeByte('}');
    try out.appendSlice(allocator, buffer.written());
    return true;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) return true;
    }
    return false;
}

fn datasheetBlocker(evidence: []const u8, note: []const u8) bool {
    const words = [_][]const u8{ "datasheet", "manufacturer", "vendor", "mpn", "part number", "rating curve", "dc-bias" };
    for (words) |word| if (containsIgnoreCase(evidence, word) or containsIgnoreCase(note, word)) return true;
    return false;
}

fn attemptedDatasheetTools(attempted: []const u8) bool {
    return containsIgnoreCase(attempted, "read_datasheet") and
        (containsIgnoreCase(attempted, "download_datasheet") or containsIgnoreCase(attempted, "fetch_datasheet") or
            containsIgnoreCase(attempted, "local pdf"));
}

/// Record one evidence-backed agent disposition. Pass/fail/N-A decisions
/// require evidence; `needs_info` may name the missing evidence in either the
/// evidence or note field. `open` clears an agent override back to generated.
pub fn recordItem(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    args: ?std.json.Value,
    out: *std.ArrayList(u8),
) RunError!bool {
    const name = argString(args, "name", 256) orelse return fail(out, allocator, "missing required name");
    const id = argString(args, "id", 16) orelse return fail(out, allocator, "missing required id");
    if (!catalog.validItemId(id)) return fail(out, allocator, "unknown checklist item id");
    const raw_status = argString(args, "status", 24) orelse return fail(out, allocator, "missing required status");
    const status = review_state.statusFromString(raw_status) orelse return fail(out, allocator, "invalid status");
    const evidence = argString(args, "evidence", review_state.max_evidence_bytes) orelse "";
    const note = argString(args, "note", review_state.max_note_bytes) orelse "";
    const attempted = argString(args, "attempted", review_state.max_attempted_bytes) orelse "";
    const agent = argString(args, "agent", 256) orelse "netlisp-agent";
    if (status != .open and evidence.len == 0 and note.len == 0)
        return fail(out, allocator, "an agent disposition requires evidence or a note");
    if (status == .needs_info and attempted.len == 0)
        return fail(out, allocator, "needs_info requires attempted tools and outcomes; exhaust retrievable evidence first");
    if (status == .needs_info and datasheetBlocker(evidence, note) and !attemptedDatasheetTools(attempted))
        return fail(out, allocator, "datasheet-related needs_info requires read_datasheet plus download_datasheet, fetch_datasheet, or an identified local PDF");
    if (!designExists(allocator, project_dir, name)) return fail(out, allocator, "no design by that name");
    const updated_at = review.isoTimestamp(allocator, clock.timestamp()) catch |err|
        return fail(out, allocator, @errorName(err));
    defer allocator.free(updated_at);
    const entry = review_state.Entry{
        .id = id,
        .status = status,
        .evidence = evidence,
        .note = note,
        .attempted = attempted,
        .updated_by = agent,
        .updated_at = updated_at,
        .origin = .agent,
    };
    review_state.persistEntry(allocator, project_dir, name, &mutation_mutex, entry) catch |err|
        return fail(out, allocator, @errorName(err));
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();
    try buffer.writer.writeAll("{\"ok\":true,\"entry\":");
    try review_state.writeEntryJson(&buffer.writer, entry);
    try buffer.writer.writeByte('}');
    try out.appendSlice(allocator, buffer.written());
    return true;
}

test "agent recorder rejects evidence-free closure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.sexp", .data = "(design-block \"Demo\")" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"name\":\"demo\",\"id\":\"1.1\",\"status\":\"pass\"}", .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try std.testing.expect(!try recordItem(std.testing.allocator, root, parsed.value, &out));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "requires evidence") != null);
}

// spec: serve/board-review - an agent cannot record Needs info without a concrete tool-attempt ledger, and a datasheet blocker requires both acquisition and reading attempts; legacy agent deferrals without that ledger reopen for review
test "agent recorder refuses datasheet needs-info before acquisition attempts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.sexp", .data = "(design-block \"Demo\")" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var missing_attempt = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"name\":\"demo\",\"id\":\"3.2.1\",\"status\":\"needs_info\",\"note\":\"vendor datasheet missing\"}", .{});
    defer missing_attempt.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try std.testing.expect(!try recordItem(std.testing.allocator, root, missing_attempt.value, &out));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "requires attempted tools") != null);
}

test "agent recorder persists attributed evidence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.sexp", .data = "(design-block \"Demo\")" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"name\":\"demo\",\"id\":\"1.1\",\"status\":\"pass\",\"evidence\":\"src/demo.sexp:1\",\"agent\":\"review-agent\"}", .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(arena);
    try std.testing.expect(try recordItem(arena, root, parsed.value, &out));
    const entries = try review_state.loadEntries(arena, root, "demo");
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(review_state.Status.pass, entries[0].status);
    try std.testing.expectEqual(review_state.Origin.agent, entries[0].origin);
    try std.testing.expectEqualStrings("review-agent", entries[0].updated_by);
    try std.testing.expectEqualStrings("src/demo.sexp:1", entries[0].evidence);
}
