const std = @import("std");
const json_writer = @import("../json_writer.zig");
const infra_fs = @import("../infra/fs.zig");
const clock = @import("../infra/clock.zig");
const log = @import("../infra/log.zig");
const auth_store = @import("auth_store.zig");

const pwhash = std.crypto.pwhash;
const scrypt = pwhash.scrypt;

/// Maximum length the scrypt PHC string can ever take with our chosen
/// parameters. Generous enough that future tuning won't blow this out.
const MAX_HASH_LEN: usize = 256;

/// One row of `auth/passwords.json`: the email it belongs to, the scrypt
/// PHC-encoded hash, and the unix timestamp at which it was last set.
const PasswordRow = struct {
    email: []const u8,
    hash: []const u8,
    updated_at: i64,
};

const MIN_PASSWORD_LEN: usize = 8;

const PasswordsError = error{
    PasswordTooShort,
};

var mu: std.Thread.Mutex = .{};
var rows: std.ArrayListUnmanaged(PasswordRow) = .empty;
var loaded_auth_dir: ?[]const u8 = null;

fn passwordsPath(allocator: std.mem.Allocator, auth_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/passwords.json", .{auth_dir});
}

const ensureAuthDir = auth_store.ensureAuthDir;

fn ensureLoaded(allocator: std.mem.Allocator, auth_dir: []const u8) void {
    if (loaded_auth_dir) |d| {
        if (std.mem.eql(u8, d, auth_dir)) return;
    }
    loaded_auth_dir = auth_dir;
    load(allocator, auth_dir);
}

fn load(allocator: std.mem.Allocator, auth_dir: []const u8) void {
    const path = passwordsPath(allocator, auth_dir) catch return;
    defer allocator.free(path);
    const data = infra_fs.cwd().readFileAlloc(allocator, path, 1 * 1024 * 1024) catch return;
    const Entry = struct {
        email: []const u8,
        hash: []const u8,
        updated_at: i64 = 0,
    };
    const parsed = std.json.parseFromSlice([]const Entry, allocator, data, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    for (parsed.value) |e| {
        rows.append(allocator, .{
            .email = allocator.dupe(u8, e.email) catch continue,
            .hash = allocator.dupe(u8, e.hash) catch continue,
            .updated_at = e.updated_at,
        }) catch continue;
    }
}

fn save(allocator: std.mem.Allocator, auth_dir: []const u8) void {
    ensureAuthDir(auth_dir);
    const path = passwordsPath(allocator, auth_dir) catch return;
    defer allocator.free(path);
    const file = infra_fs.cwd().createFile(path, .{}) catch return;
    defer file.close();
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll("[") catch return;
    for (rows.items, 0..) |r, i| {
        if (i > 0) w.writeAll(",") catch return;
        w.writeAll("{\"email\":") catch return;
        json_writer.writeString(w, r.email) catch return;
        w.writeAll(",\"hash\":") catch return;
        json_writer.writeString(w, r.hash) catch return;
        w.print(",\"updated_at\":{d}}}", .{r.updated_at}) catch return;
    }
    w.writeAll("]") catch return;
    file.writeAll(buf.items) catch return;
}

fn indexOfEmailLocked(email: []const u8) ?usize {
    for (rows.items, 0..) |r, i| {
        if (std.mem.eql(u8, r.email, email)) return i;
    }
    return null;
}

/// Set or replace the password for `email`. The plaintext is hashed with
/// scrypt (interactive params, ~100ms on a modern desktop) and only the
/// PHC-encoded hash is persisted. Returns `PasswordTooShort` if the
/// plaintext is below `MIN_PASSWORD_LEN`.
pub fn set(
    allocator: std.mem.Allocator,
    auth_dir: []const u8,
    email: []const u8,
    password: []const u8,
) (std.mem.Allocator.Error || PasswordsError || pwhash.Error)!void {
    if (password.len < MIN_PASSWORD_LEN) return PasswordsError.PasswordTooShort;

    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, auth_dir);

    var hash_buf: [MAX_HASH_LEN]u8 = undefined;
    const hash_str = try scrypt.strHash(password, .{
        .allocator = allocator,
        .params = scrypt.Params.interactive,
        .encoding = .phc,
    }, &hash_buf);
    const hash_dup = try allocator.dupe(u8, hash_str);
    const now = clock.timestamp();

    if (indexOfEmailLocked(email)) |idx| {
        // Replace existing hash in place; the previous one is leaked into
        // the long-lived allocator (matches the rest of this codebase: file
        // contents and credential strings are never freed).
        rows.items[idx].hash = hash_dup;
        rows.items[idx].updated_at = now;
    } else {
        try rows.append(allocator, .{
            .email = try allocator.dupe(u8, email),
            .hash = hash_dup,
            .updated_at = now,
        });
    }
    save(allocator, auth_dir);
}

/// Verify `password` against the stored hash for `email`. Returns true on
/// match, false for unknown email or wrong password. Constant-ish time:
/// scrypt itself dominates for valid emails; unknown emails skip the
/// hash compute and short-circuit, which is acceptable here because the
/// email-existence is also revealed by the invite/passkey flow.
pub fn verify(
    allocator: std.mem.Allocator,
    auth_dir: []const u8,
    email: []const u8,
    password: []const u8,
) bool {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, auth_dir);
    const idx = indexOfEmailLocked(email) orelse return false;
    const stored = rows.items[idx].hash;
    scrypt.strVerify(stored, password, .{ .allocator = allocator }) catch return false;
    return true;
}

/// True when a password is set for `email`. Used by the manage page to
/// label the button "Set password" vs "Change password".
pub fn isSet(allocator: std.mem.Allocator, auth_dir: []const u8, email: []const u8) bool {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, auth_dir);
    return indexOfEmailLocked(email) != null;
}

/// Remove the password for `email` (no-op when none is set). Called by
/// the admin delete-user purge so a deleted user cannot retain a password.
pub fn purge(allocator: std.mem.Allocator, auth_dir: []const u8, email: []const u8) void {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, auth_dir);
    var i: usize = 0;
    while (i < rows.items.len) {
        if (std.mem.eql(u8, rows.items[i].email, email)) {
            _ = rows.orderedRemove(i);
            continue;
        }
        i += 1;
    }
    save(allocator, auth_dir);
}
