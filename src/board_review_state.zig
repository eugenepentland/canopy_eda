//! Persisted reviewer/agent dispositions for the generated board checklist.

const std = @import("std");
const atomic_write = @import("infra/atomic_write.zig");
const catalog = @import("board_review_catalog.zig");
const infra_fs = @import("infra/fs.zig");
const json_writer = @import("json_writer.zig");
const paths = @import("paths.zig");

const max_state_bytes: usize = 2 * 1024 * 1024;
/// Maximum evidence text accepted for one saved decision.
pub const max_evidence_bytes: usize = 2048;
/// Maximum reviewer/agent note accepted for one saved decision.
pub const max_note_bytes: usize = 4096;
const max_entries: usize = catalog.item_count;

/// Persisted checklist state values.
pub const Status = enum { open, pass, fail, na, needs_info };
/// Actor class that last wrote a persisted decision.
pub const Origin = enum { human, agent };

/// One bounded, attributable saved checklist override.
pub const Entry = struct {
    id: []const u8,
    status: Status = .open,
    evidence: []const u8 = "",
    note: []const u8 = "",
    updated_by: []const u8 = "",
    updated_at: []const u8 = "",
    origin: Origin = .human,
};

/// Parse an allowlisted persisted checklist status.
pub fn statusFromString(raw: []const u8) ?Status {
    return std.meta.stringToEnum(Status, raw);
}

fn originFromString(raw: []const u8) ?Origin {
    return std.meta.stringToEnum(Origin, raw);
}

fn statePath(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) ![]u8 {
    return paths.designSiblingPath(allocator, project_dir, name, ".review.json");
}

fn jsonStringField(object: std.json.ObjectMap, key: []const u8, max_len: usize) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string or value.string.len > max_len) return null;
    return value.string;
}

fn loadEntriesImpl(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) ![]const Entry {
    const path = try statePath(allocator, project_dir, name);
    defer allocator.free(path);
    const bytes = infra_fs.cwd().readFileAlloc(allocator, path, max_state_bytes) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidState;
    const entries_value = parsed.value.object.get("entries") orelse return &.{};
    if (entries_value != .array or entries_value.array.items.len > max_entries) return error.InvalidState;

    var entries: std.ArrayList(Entry) = .empty;
    for (entries_value.array.items) |value| {
        if (value != .object) continue;
        const id = jsonStringField(value.object, "id", 16) orelse continue;
        if (!catalog.validItemId(id)) continue;
        const status_raw = jsonStringField(value.object, "status", 24) orelse "open";
        const status = statusFromString(status_raw) orelse continue;
        const origin_raw = jsonStringField(value.object, "origin", 24) orelse "human";
        const origin = originFromString(origin_raw) orelse continue;
        const evidence = jsonStringField(value.object, "evidence", max_evidence_bytes) orelse "";
        const note = jsonStringField(value.object, "note", max_note_bytes) orelse "";
        const updated_by = jsonStringField(value.object, "updated_by", 256) orelse "";
        const updated_at = jsonStringField(value.object, "updated_at", 64) orelse "";
        try entries.append(allocator, .{
            .id = try allocator.dupe(u8, id),
            .status = status,
            .evidence = try allocator.dupe(u8, evidence),
            .note = try allocator.dupe(u8, note),
            .updated_by = try allocator.dupe(u8, updated_by),
            .updated_at = try allocator.dupe(u8, updated_at),
            .origin = origin,
        });
    }
    return try entries.toOwnedSlice(allocator);
}

const LoadEntriesError = @typeInfo(@typeInfo(@TypeOf(loadEntriesImpl)).@"fn".return_type.?).error_union.error_set;

/// Load valid saved decisions; a missing sidecar is the empty state.
pub fn loadEntries(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) LoadEntriesError![]const Entry {
    return loadEntriesImpl(allocator, project_dir, name);
}

/// Serialize one saved decision using the canonical JSON string writer.
pub fn writeEntryJson(w: *std.Io.Writer, entry: Entry) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    try w.writeAll("{\"id\":");
    try json_writer.writeString(w, entry.id);
    try w.writeAll(",\"status\":");
    try json_writer.writeString(w, @tagName(entry.status));
    try w.writeAll(",\"evidence\":");
    try json_writer.writeString(w, entry.evidence);
    try w.writeAll(",\"note\":");
    try json_writer.writeString(w, entry.note);
    try w.writeAll(",\"updated_by\":");
    try json_writer.writeString(w, entry.updated_by);
    try w.writeAll(",\"updated_at\":");
    try json_writer.writeString(w, entry.updated_at);
    try w.writeAll(",\"origin\":");
    try json_writer.writeString(w, @tagName(entry.origin));
    try w.writeByte('}');
}

fn renderStateImpl(allocator: std.mem.Allocator, entries: []const Entry) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"schema\":\"netlisp-board-review-v2\",\"entries\":[");
    for (entries, 0..) |entry, index| {
        if (index > 0) try out.writer.writeByte(',');
        try writeEntryJson(&out.writer, entry);
    }
    try out.writer.writeAll("]}");
    return try out.toOwnedSlice();
}

const RenderStateError = @typeInfo(@typeInfo(@TypeOf(renderStateImpl)).@"fn".return_type.?).error_union.error_set;

/// Render the complete versioned sidecar document.
pub fn renderState(allocator: std.mem.Allocator, entries: []const Entry) RenderStateError![]const u8 {
    return renderStateImpl(allocator, entries);
}

fn saveEntriesImpl(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8, entries: []const Entry) !void {
    const path = try statePath(allocator, project_dir, name);
    defer allocator.free(path);
    const bytes = try renderState(allocator, entries);
    defer allocator.free(bytes);
    try atomic_write.writeFile(path, bytes);
}

const SaveEntriesError = @typeInfo(@typeInfo(@TypeOf(saveEntriesImpl)).@"fn".return_type.?).error_union.error_set;

/// Atomically replace a design's board-review sidecar.
pub fn saveEntries(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8, entries: []const Entry) SaveEntriesError!void {
    return saveEntriesImpl(allocator, project_dir, name, entries);
}

fn persistEntryImpl(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    mutex: *infra_fs.Mutex,
    replacement: Entry,
) !void {
    mutex.lock();
    defer mutex.unlock();
    const old = try loadEntries(allocator, project_dir, name);
    var next: std.ArrayList(Entry) = .empty;
    var replaced = false;
    for (old) |entry| {
        if (std.mem.eql(u8, entry.id, replacement.id)) {
            if (!replaced) try next.append(allocator, replacement);
            replaced = true;
        } else try next.append(allocator, entry);
    }
    if (!replaced) {
        if (next.items.len >= max_entries) return error.ReviewStateFull;
        try next.append(allocator, replacement);
    }
    try saveEntries(allocator, project_dir, name, next.items);
}

const PersistEntryError = @typeInfo(@typeInfo(@TypeOf(persistEntryImpl)).@"fn".return_type.?).error_union.error_set;

/// Serialize a read-modify-write and atomically persist one replacement entry.
pub fn persistEntry(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    mutex: *infra_fs.Mutex,
    replacement: Entry,
) PersistEntryError!void {
    return persistEntryImpl(allocator, project_dir, name, mutex, replacement);
}
