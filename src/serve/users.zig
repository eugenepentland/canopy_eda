//! User records and role store: the `Role` enum and the JSON-file-backed user
//! table under the auth dir (`ensureUser`, `getRole`, `setRole`, `deleteUser`,
//! `listUsers`). A user is created on first passkey sign-in; the role gates the
//! admin APIs in `account_page.zig`.

const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const clock = @import("../infra/clock.zig");
const log = @import("../infra/log.zig");
const auth_store = @import("auth_store.zig");
const oauth_store = @import("oauth_store.zig");

/// Permission tier assigned to a user. Drives the canWrite/canAdmin gates
/// the auth middleware and MCP dispatcher consult before accepting a
/// mutation; the first registered user is bootstrapped as admin.
pub const Role = enum {
    admin,
    writer,
    reader,

    pub fn toString(self: Role) []const u8 {
        return switch (self) {
            .admin => "admin",
            .writer => "writer",
            .reader => "reader",
        };
    }

    pub fn fromString(s: []const u8) ?Role {
        if (std.mem.eql(u8, s, "admin")) return .admin;
        if (std.mem.eql(u8, s, "writer")) return .writer;
        if (std.mem.eql(u8, s, "reader")) return .reader;
        return null;
    }

    /// Can this role mutate designs via MCP / HTTP edit endpoints?
    pub fn canWrite(self: Role) bool {
        return self == .admin or self == .writer;
    }

    /// Can this role manage other users and mint invites?
    pub fn canAdmin(self: Role) bool {
        return self == .admin;
    }
};

/// One row from `auth/users.json`: a registered email, its current Role,
/// and the unix timestamp at which the account was first created. Owned
/// strings are duped from the project allocator on load.
pub const User = struct {
    email: []const u8,
    role: Role,
    created_at: i64,
};

var mu = std.Thread.Mutex{};
var users_list: std.ArrayListUnmanaged(User) = .empty;
var loaded_auth_dir: ?[]const u8 = null;

// Everything stored in the module-global `users_list` must outlive any single
// request — handlers call in with a per-request arena, so persistent rows are
// allocated from the process allocator instead of the caller's.
const store_alloc = std.heap.page_allocator;

fn usersPath(allocator: std.mem.Allocator, auth_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/users.json", .{auth_dir});
}

const ensureAuthDir = auth_store.ensureAuthDir;

fn ensureLoaded(allocator: std.mem.Allocator, auth_dir: []const u8) void {
    if (loaded_auth_dir) |d| {
        if (std.mem.eql(u8, d, auth_dir)) return;
    }
    loaded_auth_dir = auth_dir;
    loadUsers(allocator, auth_dir);
    backfillFromCredentials(allocator, auth_dir);
}

fn loadUsers(allocator: std.mem.Allocator, auth_dir: []const u8) void {
    const path = usersPath(allocator, auth_dir) catch return;
    defer allocator.free(path);
    const data = infra_fs.cwd().readFileAlloc(allocator, path, 1 * 1024 * 1024) catch return;
    const Entry = struct { email: []const u8, role: []const u8, created_at: i64 };
    const parsed = std.json.parseFromSlice([]const Entry, allocator, data, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    for (parsed.value) |e| {
        const role = Role.fromString(e.role) orelse .reader;
        users_list.append(store_alloc, .{
            .email = store_alloc.dupe(u8, e.email) catch continue,
            .role = role,
            .created_at = e.created_at,
        }) catch continue;
    }
}

fn saveUsers(allocator: std.mem.Allocator, auth_dir: []const u8) void {
    ensureAuthDir(auth_dir);
    const path = usersPath(allocator, auth_dir) catch return;
    defer allocator.free(path);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll("[") catch return;
    for (users_list.items, 0..) |u, i| {
        if (i > 0) w.writeAll(",") catch return;
        w.print("{{\"email\":\"{s}\",\"role\":\"{s}\",\"created_at\":{d}}}", .{ u.email, u.role.toString(), u.created_at }) catch return;
    }
    w.writeAll("]") catch return;
    oauth_store.writeFileAtomicWithBackup(allocator, path, buf.items);
}

/// On first migration (users.json doesn't exist yet but credentials do),
/// seed user records from credentials — the first credential's email becomes
/// admin, the rest become writer.
fn backfillFromCredentials(allocator: std.mem.Allocator, auth_dir: []const u8) void {
    const path = std.fmt.allocPrint(allocator, "{s}/credentials.json", .{auth_dir}) catch return;
    defer allocator.free(path);
    const data = infra_fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024) catch return;
    const Cred = struct { email: []const u8, created_at: i64 };
    const parsed = std.json.parseFromSlice([]const Cred, allocator, data, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();

    var dirty = false;
    for (parsed.value) |c| {
        if (c.email.len == 0) continue;
        if (indexOfEmailLocked(c.email) != null) continue;
        const role: Role = if (users_list.items.len == 0) .admin else .writer;
        users_list.append(store_alloc, .{
            .email = store_alloc.dupe(u8, c.email) catch continue,
            .role = role,
            .created_at = c.created_at,
        }) catch continue;
        dirty = true;
    }
    if (dirty) saveUsers(allocator, auth_dir);
}

fn indexOfEmailLocked(email: []const u8) ?usize {
    for (users_list.items, 0..) |u, i| {
        if (std.mem.eql(u8, u.email, email)) return i;
    }
    return null;
}

// ── Public API ─────────────────────────────────────────────────────────

/// Create a user with the given role if one doesn't already exist. Returns
/// the role actually recorded (either the new one or the existing one).
pub fn ensureUser(
    allocator: std.mem.Allocator,
    auth_dir: []const u8,
    email: []const u8,
    requested_role: Role,
) std.mem.Allocator.Error!Role {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, auth_dir);

    if (indexOfEmailLocked(email)) |idx| return users_list.items[idx].role;

    // First-ever user becomes admin regardless of requested_role (bootstrap).
    const role: Role = if (users_list.items.len == 0) .admin else requested_role;
    try users_list.append(store_alloc, .{
        .email = try store_alloc.dupe(u8, email),
        .role = role,
        .created_at = clock.timestamp(),
    });
    saveUsers(allocator, auth_dir);
    return role;
}

/// Resolve a user's role, defaulting to reader for unknown users. For
/// localhost dev identity we return admin so dev flows are unblocked.
pub fn getRole(allocator: std.mem.Allocator, auth_dir: []const u8, email: []const u8) Role {
    if (std.mem.eql(u8, email, "dev@localhost")) return .admin;
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, auth_dir);
    if (indexOfEmailLocked(email)) |idx| return users_list.items[idx].role;
    return .reader;
}

/// Return a duped slice of every registered user record. Used by the
/// admin page to render the user-management table; caller owns the slice
/// (the inner `email` strings are still backed by the loaded data).
pub fn listUsers(allocator: std.mem.Allocator, auth_dir: []const u8) std.mem.Allocator.Error![]User {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, auth_dir);
    return allocator.dupe(User, users_list.items);
}

/// Promote or demote `target_email` to `new_role`, persisting the change.
/// Returns false when the target user is unknown; returns
/// `error.LastAdmin` if the change would leave the system with no admins.
pub fn setRole(
    allocator: std.mem.Allocator,
    auth_dir: []const u8,
    target_email: []const u8,
    new_role: Role,
    acting_email: []const u8,
) (std.mem.Allocator.Error || error{LastAdmin})!bool {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, auth_dir);
    const idx = indexOfEmailLocked(target_email) orelse return false;

    // Prevent demoting the last admin.
    if (users_list.items[idx].role == .admin and new_role != .admin) {
        var admin_count: usize = 0;
        for (users_list.items) |u| if (u.role == .admin) {
            admin_count += 1;
        };
        if (admin_count <= 1) return error.LastAdmin;
    }

    _ = acting_email;
    users_list.items[idx].role = new_role;
    saveUsers(allocator, auth_dir);
    return true;
}

/// Remove `target_email` from the user list. Refuses to delete the
/// caller themselves (`error.CannotDeleteSelf`) or the last admin
/// (`error.LastAdmin`). Returns false when the user does not exist.
pub fn deleteUser(
    allocator: std.mem.Allocator,
    auth_dir: []const u8,
    target_email: []const u8,
    acting_email: []const u8,
) (std.mem.Allocator.Error || error{ CannotDeleteSelf, LastAdmin })!bool {
    if (std.mem.eql(u8, target_email, acting_email)) return error.CannotDeleteSelf;

    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, auth_dir);
    const idx = indexOfEmailLocked(target_email) orelse return false;

    // Prevent deleting the last admin.
    if (users_list.items[idx].role == .admin) {
        var admin_count: usize = 0;
        for (users_list.items) |u| if (u.role == .admin) {
            admin_count += 1;
        };
        if (admin_count <= 1) return error.LastAdmin;
    }

    _ = users_list.orderedRemove(idx);
    saveUsers(allocator, auth_dir);
    return true;
}

// ── Tests ──────────────────────────────────────────────────────────────

// Locks the invariant the account-page and MCP role checks rely on: every
// caller must pass `auth_dir` to read the same data that was written there.
// spec: serve/users - The user/role store persists to and resolves from auth_dir, not the project dir (users.json lives at <auth_dir>/users.json)
test "user store reads and writes under auth_dir" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const auth_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(auth_dir);

    // Reset the process-global store so this test is order-independent.
    users_list.clearRetainingCapacity();
    loaded_auth_dir = null;

    // First user is bootstrapped as admin and persisted under auth_dir.
    const role = try ensureUser(alloc, auth_dir, "admin@example.com", .writer);
    try std.testing.expectEqual(Role.admin, role);

    // The store file must live at `<auth_dir>/users.json`.
    var f = try tmp.dir.openFile("users.json", .{});
    f.close();

    // Reading the role back from the same auth_dir resolves the admin.
    try std.testing.expectEqual(Role.admin, getRole(alloc, auth_dir, "admin@example.com"));
    // An unknown email defaults to reader.
    try std.testing.expectEqual(Role.reader, getRole(alloc, auth_dir, "stranger@example.com"));
}
