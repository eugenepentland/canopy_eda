const std = @import("std");
const review = @import("review.zig");

/// Mutex protecting on-disk state writes from concurrent checklist edits
/// arriving via HTTP or MCP. Loads stay outside the lock — a stale read
/// just gets the pre-mutation snapshot, which the browser's version poll
/// will refresh.
var save_mutex: std.Thread.Mutex = .{};

/// Load the review-state JSON for a design. Returns an empty state if the
/// file is absent or malformed — a corrupt file shouldn't 500 the review
/// page, the user can re-create it by checking items again.
pub fn loadState(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) !review.ReviewState {
    if (!safeName(name)) return error.InvalidName;
    const path = try statePath(allocator, project_dir, name);
    defer allocator.free(path);
    const data = std.fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return .{ .sections = &.{} },
        else => return err,
    };
    defer allocator.free(data);
    return parseState(allocator, data) catch .{ .sections = &.{} };
}

/// Save the state to disk. Creates `reviews/` on first write. Atomic via
/// temp-file + rename so a crash mid-write leaves the prior file intact.
pub fn saveState(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    state: review.ReviewState,
) !void {
    if (!safeName(name)) return error.InvalidName;
    save_mutex.lock();
    defer save_mutex.unlock();

    try ensureReviewsDir(allocator, project_dir);
    const path = try statePath(allocator, project_dir, name);
    defer allocator.free(path);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    const json = try renderState(allocator, state);
    defer allocator.free(json);

    {
        const file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(json);
    }
    try std.fs.cwd().rename(tmp_path, path);
}

/// Drop any section state entries whose slug is no longer in `live_slugs`,
/// and synthesise empty entries for slugs that have no prior state. When
/// `live_hashes` is provided, compare each section's stored content hash
/// against the current build's hash and flip `approval_stale` so the UI can
/// prompt a re-approval without clobbering the historical `approved_by` /
/// `approved_at` stamp.
pub fn reconcile(
    allocator: std.mem.Allocator,
    stored: review.ReviewState,
    live_slugs: []const []const u8,
    live_hashes: ?[]const []const u8,
) !review.ReviewState {
    var out: std.ArrayListUnmanaged(review.SectionReviewState) = .empty;
    for (live_slugs, 0..) |slug, i| {
        const found = findSection(stored, slug);
        const live_hash: []const u8 = if (live_hashes) |hashes| (if (i < hashes.len) hashes[i] else "") else "";
        if (found) |s| {
            const stale = s.approved and s.content_hash.len > 0 and live_hash.len > 0 and !std.mem.eql(u8, s.content_hash, live_hash);
            try out.append(allocator, .{
                .section_slug = s.section_slug,
                .items = s.items,
                .approved = s.approved,
                .approved_by = s.approved_by,
                .approved_at = s.approved_at,
                .content_hash = s.content_hash,
                .approval_stale = stale,
            });
        } else {
            try out.append(allocator, .{
                .section_slug = slug,
                .items = &.{},
                .approved = false,
                .approved_by = "",
                .approved_at = "",
                .content_hash = "",
                .approval_stale = false,
            });
        }
    }
    return .{ .sections = out.items };
}

/// Append a new checklist item to a section. Server-allocated id so the
/// client never has to invent one. Returns the id so the browser can
/// render the new <li> without a full refetch.
pub fn addItem(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    slug: []const u8,
    text: []const u8,
) ![]const u8 {
    var state = try loadState(allocator, project_dir, name);
    const id = try randomHex(allocator, 8);

    var sections = std.ArrayListUnmanaged(review.SectionReviewState){};
    var found = false;
    for (state.sections) |s| {
        if (std.mem.eql(u8, s.section_slug, slug)) {
            found = true;
            const items = try appendItem(allocator, s.items, .{
                .id = id,
                .text = try allocator.dupe(u8, text),
                .checked = false,
            });
            try sections.append(allocator, .{
                .section_slug = s.section_slug,
                .items = items,
                .approved = s.approved,
                .approved_by = s.approved_by,
                .approved_at = s.approved_at,
            });
        } else {
            try sections.append(allocator, s);
        }
    }
    if (!found) {
        const items = try allocator.dupe(review.ChecklistItem, &.{.{
            .id = id,
            .text = try allocator.dupe(u8, text),
            .checked = false,
        }});
        try sections.append(allocator, .{
            .section_slug = try allocator.dupe(u8, slug),
            .items = items,
            .approved = false,
            .approved_by = "",
            .approved_at = "",
        });
    }
    state.sections = sections.items;
    try saveState(allocator, project_dir, name, state);
    return id;
}

/// Set the `checked` bit on one checklist item. Silently no-ops if the
/// slug or id are gone (e.g. the user deleted the item in another tab).
pub fn toggleItem(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    slug: []const u8,
    id: []const u8,
    checked: bool,
) !void {
    var state = try loadState(allocator, project_dir, name);
    var sections = std.ArrayListUnmanaged(review.SectionReviewState){};
    for (state.sections) |s| {
        if (!std.mem.eql(u8, s.section_slug, slug)) {
            try sections.append(allocator, s);
            continue;
        }
        var items = std.ArrayListUnmanaged(review.ChecklistItem){};
        for (s.items) |it| {
            if (std.mem.eql(u8, it.id, id)) {
                try items.append(allocator, .{ .id = it.id, .text = it.text, .checked = checked });
            } else {
                try items.append(allocator, it);
            }
        }
        try sections.append(allocator, .{
            .section_slug = s.section_slug,
            .items = items.items,
            .approved = s.approved,
            .approved_by = s.approved_by,
            .approved_at = s.approved_at,
        });
    }
    state.sections = sections.items;
    try saveState(allocator, project_dir, name, state);
}

/// Remove one checklist item by id. No-ops on missing slug/id.
pub fn deleteItem(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    slug: []const u8,
    id: []const u8,
) !void {
    var state = try loadState(allocator, project_dir, name);
    var sections = std.ArrayListUnmanaged(review.SectionReviewState){};
    for (state.sections) |s| {
        if (!std.mem.eql(u8, s.section_slug, slug)) {
            try sections.append(allocator, s);
            continue;
        }
        var items = std.ArrayListUnmanaged(review.ChecklistItem){};
        for (s.items) |it| {
            if (!std.mem.eql(u8, it.id, id)) try items.append(allocator, it);
        }
        try sections.append(allocator, .{
            .section_slug = s.section_slug,
            .items = items.items,
            .approved = s.approved,
            .approved_by = s.approved_by,
            .approved_at = s.approved_at,
        });
    }
    state.sections = sections.items;
    try saveState(allocator, project_dir, name, state);
}

/// Stamp or clear the section-level approval. When `approved` flips true,
/// we write the reviewer name, current UTC timestamp, and the live content
/// hash; when it flips false, approval fields are cleared but the stored
/// hash remains irrelevant (re-computed on next approval).
pub fn setApproval(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    slug: []const u8,
    approved: bool,
    reviewer: []const u8,
    content_hash: []const u8,
) !void {
    var state = try loadState(allocator, project_dir, name);
    const stamp: []const u8 = if (approved) try review.isoTimestamp(allocator, std.time.timestamp()) else "";
    const who: []const u8 = if (approved) try allocator.dupe(u8, reviewer) else "";
    const stored_hash: []const u8 = if (approved) try allocator.dupe(u8, content_hash) else "";

    var sections = std.ArrayListUnmanaged(review.SectionReviewState){};
    var found = false;
    for (state.sections) |s| {
        if (!std.mem.eql(u8, s.section_slug, slug)) {
            try sections.append(allocator, s);
            continue;
        }
        found = true;
        try sections.append(allocator, .{
            .section_slug = s.section_slug,
            .items = s.items,
            .approved = approved,
            .approved_by = who,
            .approved_at = stamp,
            .content_hash = stored_hash,
        });
    }
    if (!found) {
        try sections.append(allocator, .{
            .section_slug = try allocator.dupe(u8, slug),
            .items = &.{},
            .approved = approved,
            .approved_by = who,
            .approved_at = stamp,
            .content_hash = stored_hash,
        });
    }
    state.sections = sections.items;
    try saveState(allocator, project_dir, name, state);
}

// ── Internals ───────────────────────────────────────────────────────────

fn findSection(state: review.ReviewState, slug: []const u8) ?review.SectionReviewState {
    for (state.sections) |s| {
        if (std.mem.eql(u8, s.section_slug, slug)) return s;
    }
    return null;
}

fn appendItem(
    allocator: std.mem.Allocator,
    items: []const review.ChecklistItem,
    new_item: review.ChecklistItem,
) ![]const review.ChecklistItem {
    var out = try allocator.alloc(review.ChecklistItem, items.len + 1);
    @memcpy(out[0..items.len], items);
    out[items.len] = new_item;
    return out;
}

fn statePath(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/reviews/{s}.state.json", .{ project_dir, name });
}

fn ensureReviewsDir(allocator: std.mem.Allocator, project_dir: []const u8) !void {
    const dir = try std.fmt.allocPrint(allocator, "{s}/reviews", .{project_dir});
    defer allocator.free(dir);
    try std.fs.cwd().makePath(dir);
}

/// Reject design names containing path separators or `..` — the name is
/// interpolated into a filesystem path, so a compromised client could
/// otherwise escape the reviews/ dir.
fn safeName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return false;
    return true;
}

fn randomHex(allocator: std.mem.Allocator, n_chars: usize) ![]u8 {
    const n_bytes = (n_chars + 1) / 2;
    const bytes = try allocator.alloc(u8, n_bytes);
    defer allocator.free(bytes);
    std.crypto.random.bytes(bytes);
    var out = try allocator.alloc(u8, n_chars);
    const hex = "0123456789abcdef";
    var i: usize = 0;
    while (i < n_chars) : (i += 1) {
        const byte = bytes[i / 2];
        out[i] = if (i % 2 == 0) hex[byte >> 4] else hex[byte & 0x0f];
    }
    return out;
}

// ── JSON (de)serialisation ──────────────────────────────────────────────

const ItemEntry = struct {
    id: []const u8,
    text: []const u8,
    checked: bool = false,
};

const SectionEntry = struct {
    section_slug: []const u8,
    items: []const ItemEntry = &.{},
    approved: bool = false,
    approved_by: []const u8 = "",
    approved_at: []const u8 = "",
    content_hash: []const u8 = "",
};

const StateFile = struct {
    sections: []const SectionEntry = &.{},
};

fn parseState(allocator: std.mem.Allocator, data: []const u8) !review.ReviewState {
    const parsed = try std.json.parseFromSlice(StateFile, allocator, data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var sections = try allocator.alloc(review.SectionReviewState, parsed.value.sections.len);
    for (parsed.value.sections, 0..) |s, i| {
        var items = try allocator.alloc(review.ChecklistItem, s.items.len);
        for (s.items, 0..) |it, j| {
            items[j] = .{
                .id = try allocator.dupe(u8, it.id),
                .text = try allocator.dupe(u8, it.text),
                .checked = it.checked,
            };
        }
        sections[i] = .{
            .section_slug = try allocator.dupe(u8, s.section_slug),
            .items = items,
            .approved = s.approved,
            .approved_by = try allocator.dupe(u8, s.approved_by),
            .approved_at = try allocator.dupe(u8, s.approved_at),
            .content_hash = try allocator.dupe(u8, s.content_hash),
        };
    }
    return .{ .sections = sections };
}

/// Serialize a ReviewState to JSON. Same shape consumed by the browser
/// and parsed on load — keep the field set stable.
pub fn renderState(allocator: std.mem.Allocator, state: review.ReviewState) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);
    try w.writeAll("{\"sections\":[");
    for (state.sections, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"section_slug\":");
        try writeJsonString(w, s.section_slug);
        try w.writeAll(",\"items\":[");
        for (s.items, 0..) |it, j| {
            if (j > 0) try w.writeAll(",");
            try w.writeAll("{\"id\":");
            try writeJsonString(w, it.id);
            try w.writeAll(",\"text\":");
            try writeJsonString(w, it.text);
            try w.print(",\"checked\":{}}}", .{it.checked});
        }
        try w.print("],\"approved\":{}", .{s.approved});
        try w.writeAll(",\"approved_by\":");
        try writeJsonString(w, s.approved_by);
        try w.writeAll(",\"approved_at\":");
        try writeJsonString(w, s.approved_at);
        try w.writeAll(",\"content_hash\":");
        try writeJsonString(w, s.content_hash);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
    return buf.items;
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeAll("\"");
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: review_state - saveState then loadState round-trips a checklist
test "saveState then loadState round-trips" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);

    const items = [_]review.ChecklistItem{
        .{ .id = "abc12345", .text = "Power pins wired", .checked = true },
        .{ .id = "def67890", .text = "Ground connected", .checked = false },
    };
    const secs = [_]review.SectionReviewState{.{
        .section_slug = "usb",
        .items = &items,
        .approved = true,
        .approved_by = "Eugene",
        .approved_at = "2026-04-24T00:00:00Z",
    }};
    const state = review.ReviewState{ .sections = &secs };
    try saveState(alloc, dir_path, "demo", state);

    const loaded = try loadState(alloc, dir_path, "demo");
    try std.testing.expectEqual(@as(usize, 1), loaded.sections.len);
    try std.testing.expectEqualStrings("usb", loaded.sections[0].section_slug);
    try std.testing.expectEqual(@as(usize, 2), loaded.sections[0].items.len);
    try std.testing.expectEqualStrings("abc12345", loaded.sections[0].items[0].id);
    try std.testing.expect(loaded.sections[0].items[0].checked);
    try std.testing.expect(loaded.sections[0].approved);
}

// spec: review_state - loadState returns empty state when file is missing
test "loadState returns empty state when file missing" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);

    const loaded = try loadState(alloc, dir_path, "nonexistent");
    try std.testing.expectEqual(@as(usize, 0), loaded.sections.len);
}

// spec: review_state - reconcile drops stale slugs and synthesises empty entries
test "reconcile drops stale slugs and adds empty entries" {
    const alloc = std.testing.allocator;
    const stored_items = [_]review.ChecklistItem{.{ .id = "a", .text = "t", .checked = true }};
    const stored_sections = [_]review.SectionReviewState{
        .{ .section_slug = "usb", .items = &stored_items, .approved = false, .approved_by = "", .approved_at = "" },
        .{ .section_slug = "removed", .items = &.{}, .approved = false, .approved_by = "", .approved_at = "" },
    };
    const stored = review.ReviewState{ .sections = &stored_sections };
    const live = [_][]const u8{ "usb", "power" };

    const out = try reconcile(alloc, stored, &live);
    try std.testing.expectEqual(@as(usize, 2), out.sections.len);
    try std.testing.expectEqualStrings("usb", out.sections[0].section_slug);
    try std.testing.expectEqual(@as(usize, 1), out.sections[0].items.len); // preserved
    try std.testing.expectEqualStrings("power", out.sections[1].section_slug);
    try std.testing.expectEqual(@as(usize, 0), out.sections[1].items.len); // synthesised
}

// spec: review_state - safeName rejects path-traversal attempts
test "safeName rejects path traversal" {
    try std.testing.expect(safeName("stm32n6"));
    try std.testing.expect(!safeName(""));
    try std.testing.expect(!safeName("../etc/passwd"));
    try std.testing.expect(!safeName("sub/design"));
    try std.testing.expect(!safeName("a\\b"));
}

// spec: review_state - addItem appends a new checklist item with a fresh id
test "addItem appends new item" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);

    const id = try addItem(alloc, dir_path, "demo", "usb", "Ground connected");
    try std.testing.expectEqual(@as(usize, 8), id.len);

    const state = try loadState(alloc, dir_path, "demo");
    try std.testing.expectEqual(@as(usize, 1), state.sections.len);
    try std.testing.expectEqual(@as(usize, 1), state.sections[0].items.len);
    try std.testing.expectEqualStrings("Ground connected", state.sections[0].items[0].text);
    try std.testing.expect(!state.sections[0].items[0].checked);
}
