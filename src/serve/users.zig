const std = @import("std");

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

pub const User = struct {
    email: []const u8,
    role: Role,
    created_at: i64,
};

var mu = std.Thread.Mutex{};
var users_list: std.ArrayListUnmanaged(User) = .empty;
var loaded_project_dir: ?[]const u8 = null;

fn usersPath(allocator: std.mem.Allocator, project_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/auth/users.json", .{project_dir});
}

fn ensureAuthDir(project_dir: []const u8) void {
    var buf: [512]u8 = undefined;
    const dir = std.fmt.bufPrint(&buf, "{s}/auth", .{project_dir}) catch return;
    std.fs.cwd().makePath(dir) catch |e| {
        std.debug.print("warning: makePath {s} failed: {s}\n", .{ dir, @errorName(e) });
    };
}

fn ensureLoaded(allocator: std.mem.Allocator, project_dir: []const u8) void {
    if (loaded_project_dir) |d| {
        if (std.mem.eql(u8, d, project_dir)) return;
    }
    loaded_project_dir = project_dir;
    loadUsers(allocator, project_dir);
    backfillFromCredentials(allocator, project_dir);
}

fn loadUsers(allocator: std.mem.Allocator, project_dir: []const u8) void {
    const path = usersPath(allocator, project_dir) catch return;
    defer allocator.free(path);
    const data = std.fs.cwd().readFileAlloc(allocator, path, 1 * 1024 * 1024) catch return;
    const Entry = struct { email: []const u8, role: []const u8, created_at: i64 };
    const parsed = std.json.parseFromSlice([]const Entry, allocator, data, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    for (parsed.value) |e| {
        const role = Role.fromString(e.role) orelse .reader;
        users_list.append(allocator, .{
            .email = allocator.dupe(u8, e.email) catch continue,
            .role = role,
            .created_at = e.created_at,
        }) catch continue;
    }
}

fn saveUsers(allocator: std.mem.Allocator, project_dir: []const u8) void {
    ensureAuthDir(project_dir);
    const path = usersPath(allocator, project_dir) catch return;
    defer allocator.free(path);
    const file = std.fs.cwd().createFile(path, .{}) catch return;
    defer file.close();
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll("[") catch return;
    for (users_list.items, 0..) |u, i| {
        if (i > 0) w.writeAll(",") catch return;
        w.print("{{\"email\":\"{s}\",\"role\":\"{s}\",\"created_at\":{d}}}", .{ u.email, u.role.toString(), u.created_at }) catch return;
    }
    w.writeAll("]") catch return;
    file.writeAll(buf.items) catch return;
}

/// On first migration (users.json doesn't exist yet but credentials do),
/// seed user records from credentials — the first credential's email becomes
/// admin, the rest become writer.
fn backfillFromCredentials(allocator: std.mem.Allocator, project_dir: []const u8) void {
    const path = std.fmt.allocPrint(allocator, "{s}/auth/credentials.json", .{project_dir}) catch return;
    defer allocator.free(path);
    const data = std.fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024) catch return;
    const Cred = struct { email: []const u8, created_at: i64 };
    const parsed = std.json.parseFromSlice([]const Cred, allocator, data, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();

    var dirty = false;
    for (parsed.value) |c| {
        if (c.email.len == 0) continue;
        if (indexOfEmailLocked(c.email) != null) continue;
        const role: Role = if (users_list.items.len == 0) .admin else .writer;
        users_list.append(allocator, .{
            .email = allocator.dupe(u8, c.email) catch continue,
            .role = role,
            .created_at = c.created_at,
        }) catch continue;
        dirty = true;
    }
    if (dirty) saveUsers(allocator, project_dir);
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
    project_dir: []const u8,
    email: []const u8,
    requested_role: Role,
) !Role {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, project_dir);

    if (indexOfEmailLocked(email)) |idx| return users_list.items[idx].role;

    // First-ever user becomes admin regardless of requested_role (bootstrap).
    const role: Role = if (users_list.items.len == 0) .admin else requested_role;
    try users_list.append(allocator, .{
        .email = try allocator.dupe(u8, email),
        .role = role,
        .created_at = std.time.timestamp(),
    });
    saveUsers(allocator, project_dir);
    return role;
}

/// Resolve a user's role, defaulting to reader for unknown users. For
/// localhost dev identity we return admin so dev flows are unblocked.
pub fn getRole(allocator: std.mem.Allocator, project_dir: []const u8, email: []const u8) Role {
    if (std.mem.eql(u8, email, "dev@localhost")) return .admin;
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, project_dir);
    if (indexOfEmailLocked(email)) |idx| return users_list.items[idx].role;
    return .reader;
}

pub fn listUsers(allocator: std.mem.Allocator, project_dir: []const u8) ![]User {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, project_dir);
    return allocator.dupe(User, users_list.items);
}

pub fn setRole(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    target_email: []const u8,
    new_role: Role,
    acting_email: []const u8,
) !bool {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, project_dir);
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
    saveUsers(allocator, project_dir);
    return true;
}

pub fn deleteUser(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    target_email: []const u8,
    acting_email: []const u8,
) !bool {
    if (std.mem.eql(u8, target_email, acting_email)) return error.CannotDeleteSelf;

    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, project_dir);
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
    saveUsers(allocator, project_dir);
    return true;
}
