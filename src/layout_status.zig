//! Read-only summary of a design/module's PCB-layout progress, drawn from its
//! `<name>.layouts.json` sidecar. The schematic page's "Module layouts" panel
//! uses this to show, per sub-module, whether a rough placement has been seeded
//! (`?rough=1`) and whether a finished layout has been starred (the layout
//! panel's ★ — i.e. the sidecar's top-level `"default"` entry, reused as the
//! human-finished marker). The full sidecar shape lives in
//! `serve/pcb_layout_page.zig`; this is a deliberately tiny, dependency-light
//! reader so the renderer needn't pull in the whole PCB-layout page module.
const std = @import("std");
const paths = @import("paths.zig");
const infra_fs = @import("infra/fs.zig");

/// At-a-glance state of a design/module's saved layouts.
pub const ModuleLayoutStatus = struct {
    /// At least one saved layout exists in the sidecar.
    present: bool = false,
    /// A Rough-seed layout has been recorded (an entry with `"rough":true`).
    rough: bool = false,
    /// A layout has been starred: the sidecar's top-level `"default"` names an
    /// existing entry (the ★ in the `/pcb-layout` panel, reused here as the
    /// "human finished it" marker).
    starred: bool = false,
    /// Number of saved layouts in the sidecar.
    count: usize = 0,
};

/// Read the layout status for `name` (a design under `src/` or a module under
/// `lib/modules/`). Returns an all-false status when the sidecar is missing or
/// unparseable. Allocation is on `alloc` (caller's arena); nothing is retained
/// past the call.
pub fn read(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) ModuleLayoutStatus {
    const path = paths.designSiblingPath(alloc, project_dir, name, ".layouts.json") catch return .{};
    defer alloc.free(path);
    const data = infra_fs.cwd().readFileAlloc(alloc, path, 1 << 20) catch return .{};
    return parse(alloc, data);
}

/// Summarize a `.layouts.json` body into a `ModuleLayoutStatus`. Split from
/// `read` so the JSON handling is exercised without touching the filesystem.
fn parse(alloc: std.mem.Allocator, data: []const u8) ModuleLayoutStatus {
    var st = ModuleLayoutStatus{};
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, data, .{}) catch return st;
    if (root != .object) return st;
    const arr = root.object.get("layouts") orelse return st;
    if (arr != .array) return st;

    st.count = arr.array.items.len;
    st.present = st.count > 0;
    for (arr.array.items) |it| {
        if (it != .object) continue;
        const rv = it.object.get("rough") orelse continue;
        if (rv == .bool and rv.bool) st.rough = true;
    }

    // Starred = the sidecar names a default layout that still exists.
    const dv = root.object.get("default") orelse return st;
    if (dv != .string or dv.string.len == 0) return st;
    for (arr.array.items) |it| {
        if (it != .object) continue;
        const nm = it.object.get("name") orelse continue;
        if (nm == .string and std.mem.eql(u8, nm.string, dv.string)) {
            st.starred = true;
            break;
        }
    }
    return st;
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: Web Server - Module-layout status reads rough and starred flags from the layouts sidecar
test "parse reads rough and starred flags" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const body =
        \\{"default":"hand","layouts":[
        \\ {"name":"rough seed","kind":"auto","ts":1,"rough":true,"parts":[]},
        \\ {"name":"hand","kind":"manual","ts":2,"parts":[]}
        \\]}
    ;
    const st = parse(alloc, body);
    try std.testing.expect(st.present);
    try std.testing.expect(st.rough);
    try std.testing.expect(st.starred);
    try std.testing.expectEqual(@as(usize, 2), st.count);
}

// spec: Web Server - Module-layout status reports neither rough nor starred when none recorded
test "parse with no rough and no default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const body =
        \\{"layouts":[{"name":"a","kind":"auto","ts":1,"parts":[]}]}
    ;
    const st = parse(alloc, body);
    try std.testing.expect(st.present);
    try std.testing.expect(!st.rough);
    try std.testing.expect(!st.starred);
    try std.testing.expectEqual(@as(usize, 1), st.count);
}

// spec: Web Server - Module-layout status of a missing sidecar is all-false
test "parse of empty or malformed body is all-false" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const st = parse(alloc, "not json");
    try std.testing.expect(!st.present);
    try std.testing.expect(!st.rough);
    try std.testing.expect(!st.starred);
    try std.testing.expectEqual(@as(usize, 0), st.count);
}
