//! Virtual filesystem surface for the MCP server. Lets an AI agent treat
//! the project directory the way a human treats a local checkout: read,
//! write, edit, list, glob — same shape as Claude Code's local toolset.
//!
//! All paths are project-relative. Path validation rejects `..` traversal,
//! absolute paths, NUL/backslash bytes, and dotfiles. An allow/deny table
//! confines mutations to design + library directories and blocks any
//! access to `auth/`, OAuth state, or credentials.
//!
//! Each public function writes a JSON response into `out` and returns
//! `true` on success, `false` on a user-facing error (with the error
//! message already in `out`). System errors (allocation, etc.) bubble up
//! via the `!bool` signature so the MCP dispatcher can wrap them.

const std = @import("std");
const json_writer = @import("../json_writer.zig");
const infra_fs = @import("../infra/fs.zig");

const MAX_FILE_BYTES: usize = 10 * 1024 * 1024;
const MAX_PATH_BYTES: usize = 1024;
const MAX_GLOB_RESULTS: usize = 4096;
const DEFAULT_LIST_ENTRIES: usize = 1024;

// Repeated JSON / error fragments — extracted so the same literal isn't
// duplicated across handlers.
const JSON_PATH_OPEN = "{\"path\":";
const JSON_LIBRARY_CHANGES_KEY = ",\"library_changes\":";
const ERR_NOT_FOUND = "not found";
const ERR_ACCESS_DENIED = "access denied";
const ERR_FILE_TOO_LARGE = "file too large";
const ERR_REFUSE_SYMLINK = "refusing to write through symlink";

// Library subdirectory prefixes — shared between READ_PREFIXES, WRITE_PREFIXES,
// `denialHint`, and `libraryEntityFor` so a new subdir or rename only touches
// one place.
const LIB_COMPONENTS = "lib/components/";
const LIB_MODULES = "lib/modules/";
const LIB_PINOUTS = "lib/pinouts/";
const LIB_FOOTPRINTS = "lib/footprints/";
const LIB_DATASHEETS = "lib/datasheets/";
const LIB_MODELS = "lib/models/";
const LIB_SOURCES = "lib/sources/";
const LIB_PARTS = "lib/parts/";

const Mode = enum { read, write };

/// Whether `listDir` walks into subdirectories. Two named methods would be
/// the cleaner API but doubles the dispatch surface; the enum keeps the
/// `bool` argument out of the public signature.
pub const ListMode = enum { flat, recursive };

/// Whether `editFile` requires `old_string` to occur exactly once or
/// replaces every occurrence. Same reasoning as `ListMode`.
pub const ReplaceMode = enum { single, all };

const SandboxError = error{
    EmptyPath,
    PathTooLong,
    AbsolutePath,
    InvalidByte,
    DotSegment,
    ParentTraversal,
    PermissionDenied,
    OutsideSandbox,
    SymlinkEscapes,
} || std.mem.Allocator.Error;

/// Errors returned by VFS operations. Wide enough to cover allocation,
/// JSON writer failures, and the filesystem operations the inner code
/// reaches for via `infra_fs.cwd()`. System errors (real I/O failures)
/// bubble up as `error.X`; user-facing errors (path denied, file not
/// found) get JSON-encoded into `out` and the function returns `false`.
pub const VfsError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    std.fs.File.OpenError || std.fs.File.ReadError || std.fs.File.WriteError ||
    std.fs.Dir.MakeError || std.fs.Dir.StatFileError ||
    std.fs.Dir.OpenError || std.fs.Dir.Iterator.Error ||
    std.fs.Dir.RenameError || std.fs.Dir.DeleteFileError ||
    std.fs.Dir.AccessError || std.fs.AtomicFile.InitError ||
    std.fs.AtomicFile.FinishError ||
    error{ FileTooBig, StreamTooLong };

/// Top-level prefixes that may be read. A path is OK if it starts with one
/// of these followed by '/'. The empty prefix `""` matches the project root
/// itself (for `list_dir ""`).
const READ_PREFIXES = [_][]const u8{
    "src/",
    // Bare `lib/` is readable so `list_dir lib` works. Reads of files
    // *under* `lib/` still need to match a more specific subdir prefix
    // — listing the parent shouldn't grant access to its children.
    "lib/",
    LIB_COMPONENTS,
    LIB_MODULES,
    LIB_PINOUTS,
    LIB_FOOTPRINTS,
    LIB_DATASHEETS,
    LIB_MODELS,
    LIB_SOURCES,
    LIB_PARTS,
    "blocks/",
    "out/",
    "reviews/",
    "history/",
};

/// Top-level prefixes that may be written. Stricter than reads — `history/`
/// is read-only (use the `restore_version` tool); `out/` is build output;
/// `lib/datasheets/` is read-only via MCP (PDFs are added by hand or
/// through the browser library page); 3D models and curated parts are
/// imported by humans.
///
/// `lib/sources/` is writable so agents can correct upstream KiCad symbol or
/// footprint files before re-running `regenerate_pinout` — the
/// `;; DO NOT EDIT` header on auto-generated pinouts only stays honest if
/// the *source* of those pinouts can be edited too.
const WRITE_PREFIXES = [_][]const u8{
    "src/",
    LIB_COMPONENTS,
    LIB_MODULES,
    LIB_PINOUTS,
    LIB_FOOTPRINTS,
    LIB_SOURCES,
    "blocks/",
};

/// Files matching any of these patterns are denied for both read and write.
/// Anything OAuth-related, credentials, or `.env` files are blocked even
/// though they live under directories that would otherwise be readable.
const DENY_BASENAMES = [_][]const u8{
    "oauth_clients.json",
    "oauth_tokens.json",
    "sessions.json",
    "credentials.json",
    "users.json",
    "invites.json",
    "plugin_tokens.json",
};

const DENY_PREFIXES = [_][]const u8{
    "auth/",
    ".guardian/",
    ".git/",
    ".claude/",
};

const DENY_SUFFIXES = [_][]const u8{
    ".key",
    ".pem",
    ".env",
};

/// Extensions that always come back as base64 rather than UTF-8 text.
const BINARY_EXTS = [_][]const u8{
    ".pdf", ".step", ".stp", ".png", ".jpg",           ".jpeg", ".gif",
    ".zip", ".gz",   ".tar", ".bin", ".kicad_pcb_bin",
};

/// Extensions regenerated by `build` — read-only via the agent surface.
const READ_ONLY_EXTS = [_][]const u8{
    ".bom",
};

fn isBinaryExt(rel_path: []const u8) bool {
    for (BINARY_EXTS) |ext| {
        if (std.mem.endsWith(u8, rel_path, ext)) return true;
    }
    return false;
}

fn isReadOnlyExt(rel_path: []const u8) bool {
    for (READ_ONLY_EXTS) |ext| {
        if (std.mem.endsWith(u8, rel_path, ext)) return true;
    }
    return false;
}

/// Validate a project-relative path. Rejects absolute paths, NUL/backslash
/// bytes, `..` segments, and segments starting with `.`. Returns the
/// trimmed canonical relative path on success — caller must NOT free it
/// (it's a sub-slice of `rel_path`).
fn validateRel(rel_path: []const u8) SandboxError![]const u8 {
    if (rel_path.len == 0) return error.EmptyPath;
    if (rel_path.len > MAX_PATH_BYTES) return error.PathTooLong;
    if (rel_path[0] == '/') return error.AbsolutePath;

    var trimmed = rel_path;
    while (trimmed.len > 1 and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];
    if (trimmed.len == 0) return error.EmptyPath;

    for (trimmed) |c| {
        if (c == 0 or c == '\\') return error.InvalidByte;
    }

    var it = std.mem.splitScalar(u8, trimmed, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) return error.InvalidByte;
        if (std.mem.eql(u8, seg, "..")) return error.ParentTraversal;
        if (seg[0] == '.') return error.DotSegment;
    }

    return trimmed;
}

/// Apply allow/deny rules. `mode` selects read vs write prefix tables.
/// The empty path "" (the project root) is allowed for read only — used
/// by `list_dir ""`. All other paths must match a prefix and miss every
/// deny rule.
fn checkAcl(rel_path: []const u8, mode: Mode) SandboxError!void {
    if (rel_path.len == 0 and mode == .read) return;

    for (DENY_PREFIXES) |p| {
        if (std.mem.startsWith(u8, rel_path, p)) return error.PermissionDenied;
    }
    for (DENY_SUFFIXES) |s| {
        if (std.mem.endsWith(u8, rel_path, s)) return error.PermissionDenied;
    }
    const basename = std.fs.path.basename(rel_path);
    for (DENY_BASENAMES) |d| {
        if (std.mem.eql(u8, basename, d)) return error.PermissionDenied;
    }

    const prefixes = if (mode == .write) &WRITE_PREFIXES else &READ_PREFIXES;
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, rel_path, p) or std.mem.eql(u8, rel_path, p[0 .. p.len - 1])) {
            if (mode == .write and isReadOnlyExt(rel_path)) {
                if (!std.mem.endsWith(u8, rel_path, ".bom")) return error.PermissionDenied;
            }
            return;
        }
    }
    return error.PermissionDenied;
}

/// Validate `rel_path` and join it onto `project_dir`. Caller owns the
/// returned slice. Does not touch the filesystem; symlink-escape check
/// runs after open in `readFile`.
fn resolveSandboxed(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    rel_path: []const u8,
    mode: Mode,
) SandboxError![]u8 {
    const validated = try validateRel(rel_path);
    try checkAcl(validated, mode);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, validated });
}

/// Same as `resolveSandboxed` but returns the canonical relative path too.
fn resolveSandboxedWithRel(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    rel_path: []const u8,
    mode: Mode,
) SandboxError!struct { abs: []u8, rel: []const u8 } {
    const validated = try validateRel(rel_path);
    try checkAcl(validated, mode);
    const abs = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, validated });
    return .{ .abs = abs, .rel = validated };
}

fn sandboxErrorMsg(err: SandboxError) []const u8 {
    return switch (err) {
        error.EmptyPath => "empty path",
        error.PathTooLong => "path too long",
        error.AbsolutePath => "absolute path not allowed",
        error.InvalidByte => "invalid byte in path (NUL, backslash, or empty segment)",
        error.DotSegment => "dot-prefixed segment not allowed",
        error.ParentTraversal => "'..' segment not allowed",
        error.PermissionDenied => "permission denied",
        error.OutsideSandbox => "path resolved outside project sandbox",
        error.SymlinkEscapes => "symlink target escapes sandbox",
        error.OutOfMemory => "out of memory",
    };
}

/// Return a human-readable hint when the agent hits a denial that has a
/// well-known workaround. Keeps the generic "permission denied" message in
/// the `error` field and adds the redirection in `hint`. Common cases:
///   - `list_dir lib` / `lib/`      → suggest list_library / list_dir on a subdir
///   - write to lib/datasheets/*    → point at the disk / browser route
///   - write to history/, out/      → explain why these are read-only
/// Returns null when no specific guidance applies; caller emits no hint.
///
/// Trailing slashes and `./` prefixes are normalised here because the catch
/// path passes the agent's raw input (un-validated), so `"lib/"` and `"lib"`
/// must both produce the same hint.
fn denialHint(rel_path: []const u8, mode: Mode) ?[]const u8 {
    if (rel_path.len == 0) return null;
    const norm = normalizePathForHint(rel_path);
    if (norm.len == 0) return null;

    if (mode == .read) {
        // Bare "lib" — not in READ_PREFIXES (which require trailing slash + content).
        // Also catch attempts to read sub-paths of `lib/` that aren't a known
        // subdir (e.g. `list_dir lib/widgets`) — the right answer is still
        // "use list_library to see which subdirs exist."
        if (std.mem.eql(u8, norm, "lib") or
            (std.mem.startsWith(u8, norm, "lib/") and !isKnownLibSubdir(norm)))
        {
            return "use list_library, or list_dir on a known subdir " ++
                "(components/, modules/, pinouts/, footprints/, " ++
                "datasheets/, sources/, models/, parts/) under lib/";
        }
        return null;
    }

    // mode == .write
    if (matchesPrefix(norm, LIB_DATASHEETS) or std.mem.eql(u8, norm, "lib/datasheets")) {
        return "lib/datasheets/ is read-only from MCP — ask the user to " ++
            "drop the PDF on disk or upload via the browser library page";
    }
    if (matchesPrefix(norm, "history/") or std.mem.eql(u8, norm, "history")) {
        return "history/ is read-only; use restore_version to revert a design to a prior snapshot";
    }
    if (matchesPrefix(norm, "out/") or std.mem.eql(u8, norm, "out")) {
        return "out/ holds build outputs and is regenerated by the build tool; nothing to write there directly";
    }
    if (matchesPrefix(norm, LIB_MODELS) or std.mem.eql(u8, norm, "lib/models")) {
        return "lib/models/ holds 3D STEP models imported by humans; not currently writable from MCP";
    }
    if (matchesPrefix(norm, LIB_PARTS) or std.mem.eql(u8, norm, "lib/parts")) {
        return "lib/parts/ holds curated part data imported by humans; not currently writable from MCP";
    }
    if (isReadOnlyExt(norm)) {
        return "this extension is regenerated by build (e.g. .bom) and not directly writable";
    }
    return null;
}

/// True if `rel_path` is exactly the directory `prefix` (with or without
/// trailing slash) or any path under it. Used by `denialHint` to map a
/// denied path to a single subtree without repeating the literal twice.
fn matchesPrefix(rel_path: []const u8, prefix: []const u8) bool {
    if (std.mem.startsWith(u8, rel_path, prefix)) return true;
    if (prefix.len > 0 and prefix[prefix.len - 1] == '/') {
        const stripped = prefix[0 .. prefix.len - 1];
        return std.mem.eql(u8, rel_path, stripped);
    }
    return false;
}

/// Normalise the kind of small variations the agent might pass in so the
/// hint matchers don't need a case for each. Strips a leading `./` and any
/// trailing `/`. Slice into the input — caller must NOT free.
fn normalizePathForHint(rel_path: []const u8) []const u8 {
    var p = rel_path;
    if (std.mem.startsWith(u8, p, "./")) p = p[2..];
    while (p.len > 1 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
    return p;
}

/// True iff `norm` (a `lib/`-prefixed path) is rooted at one of the
/// directories `list_library` actually exposes. Used to decide whether to
/// hint at `list_library` for an unknown subdir or stay quiet.
fn isKnownLibSubdir(norm: []const u8) bool {
    const known = [_][]const u8{
        LIB_COMPONENTS, LIB_MODULES, LIB_PINOUTS, LIB_FOOTPRINTS,
        LIB_DATASHEETS, LIB_SOURCES, LIB_MODELS,  LIB_PARTS,
    };
    for (known) |p| if (matchesPrefix(norm, p)) return true;
    return false;
}

/// Write a sandbox error response with an optional hint. Drop-in replacement
/// for `writeError(out, allocator, sandboxErrorMsg(e))` at sites where the
/// agent benefits from a redirection (list_dir on lib, write to datasheets).
fn writeSandboxError(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    err: SandboxError,
    rel_path: []const u8,
    mode: Mode,
) !bool {
    out.clearRetainingCapacity();
    const w = out.writer(allocator);
    try w.writeAll("{\"error\":");
    try json_writer.writeString(w, sandboxErrorMsg(err));
    if (err == error.PermissionDenied) {
        if (denialHint(rel_path, mode)) |hint| {
            try w.writeAll(",\"hint\":");
            try json_writer.writeString(w, hint);
        }
    }
    try w.writeAll("}");
    return false;
}

fn writeError(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, msg: []const u8) !bool {
    out.clearRetainingCapacity();
    const w = out.writer(allocator);
    try w.writeAll("{\"error\":");
    try json_writer.writeString(w, msg);
    try w.writeAll("}");
    return false;
}

fn sha256Hex(content: []const u8, out_buf: *[64]u8) void {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &hash, .{});
    const hex = "0123456789abcdef";
    for (hash, 0..) |b, i| {
        out_buf[i * 2] = hex[b >> 4];
        out_buf[i * 2 + 1] = hex[b & 0xf];
    }
}

/// Read a file under the sandbox. Text files come back as `content`
/// (string). Binary files (by extension) come back as `base64`. Optional
/// `offset` and `limit` carve a window — handy for chunking large files.
/// Always emits `sha256` of the full content so callers can use CAS on
/// follow-up writes.
pub fn readFile(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    rel_path: []const u8,
    offset: ?u64,
    limit: ?u64,
    out: *std.ArrayListUnmanaged(u8),
) VfsError!bool {
    const resolved = resolveSandboxedWithRel(allocator, project_dir, rel_path, .read) catch |e| {
        return writeSandboxError(out, allocator, e, rel_path, .read);
    };
    defer allocator.free(resolved.abs);

    const content = infra_fs.cwd().readFileAlloc(allocator, resolved.abs, MAX_FILE_BYTES) catch |e| switch (e) {
        error.FileNotFound => return writeError(out, allocator, ERR_NOT_FOUND),
        error.IsDir => return writeError(out, allocator, "is a directory"),
        error.AccessDenied => return writeError(out, allocator, ERR_ACCESS_DENIED),
        error.FileTooBig => return writeError(out, allocator, ERR_FILE_TOO_LARGE),
        else => return e,
    };
    defer allocator.free(content);

    var hash_hex: [64]u8 = undefined;
    sha256Hex(content, &hash_hex);

    const off: usize = if (offset) |o| @intCast(@min(o, content.len)) else 0;
    const requested_end: usize = blk: {
        if (limit) |l| {
            const want: u64 = @as(u64, off) + l;
            break :blk @intCast(@min(want, content.len));
        }
        break :blk content.len;
    };
    const slice = content[off..requested_end];
    const truncated = requested_end < content.len;

    const w = out.writer(allocator);
    try w.writeAll(JSON_PATH_OPEN);
    try json_writer.writeString(w, resolved.rel);
    try w.print(",\"size\":{d},\"sha256\":\"{s}\",\"truncated\":{s}", .{
        content.len,
        hash_hex[0..],
        if (truncated) "true" else "false",
    });

    if (isBinaryExt(resolved.rel)) {
        try w.writeAll(",\"binary\":true,\"base64\":\"");
        const Encoder = std.base64.standard.Encoder;
        const max_encoded = Encoder.calcSize(slice.len);
        const buf = try allocator.alloc(u8, max_encoded);
        defer allocator.free(buf);
        const encoded = Encoder.encode(buf, slice);
        try w.writeAll(encoded);
        try w.writeAll("\"}");
    } else {
        try w.writeAll(",\"binary\":false,\"content\":");
        try json_writer.writeString(w, slice);
        try w.writeAll("}");
    }
    return true;
}

/// Atomically write `content` to a sandboxed path. Optional
/// `expected_sha256` enables CAS — the write fails if the file has
/// changed since the agent last read it. Refuses to overwrite an
/// existing symlink so the human-managed link stays intact.
pub fn writeFile(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    rel_path: []const u8,
    content: []const u8,
    expected_sha256: ?[]const u8,
    out: *std.ArrayListUnmanaged(u8),
) VfsError!bool {
    if (content.len > MAX_FILE_BYTES) {
        return writeError(out, allocator, "content too large");
    }
    const resolved = resolveSandboxedWithRel(allocator, project_dir, rel_path, .write) catch |e| {
        return writeSandboxError(out, allocator, e, rel_path, .write);
    };
    defer allocator.free(resolved.abs);

    if (infra_fs.cwd().statFile(resolved.abs)) |stat| {
        if (stat.kind == .sym_link) {
            return writeError(out, allocator, ERR_REFUSE_SYMLINK);
        }
        if (expected_sha256) |expected| {
            const existing = infra_fs.cwd().readFileAlloc(allocator, resolved.abs, MAX_FILE_BYTES) catch |e| switch (e) {
                error.FileNotFound => return writeStaleSha(out, allocator, ""),
                else => return e,
            };
            defer allocator.free(existing);
            var hash_hex: [64]u8 = undefined;
            sha256Hex(existing, &hash_hex);
            if (!std.mem.eql(u8, expected, hash_hex[0..])) {
                return writeStaleSha(out, allocator, hash_hex[0..]);
            }
        }
    } else |_| {}

    if (std.fs.path.dirname(resolved.abs)) |parent| {
        infra_fs.cwd().makePath(parent) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
    }

    {
        var write_buf: [4096]u8 = undefined;
        var atomic = infra_fs.cwd().atomicFile(resolved.abs, .{ .write_buffer = &write_buf }) catch |e| switch (e) {
            error.AccessDenied => return writeError(out, allocator, ERR_ACCESS_DENIED),
            else => return e,
        };
        defer atomic.deinit();
        atomic.file_writer.interface.writeAll(content) catch |e| switch (e) {
            error.WriteFailed => return atomic.file_writer.err.?,
        };
        try atomic.finish();
    }

    var hash_hex: [64]u8 = undefined;
    sha256Hex(content, &hash_hex);

    const w = out.writer(allocator);
    try w.writeAll(JSON_PATH_OPEN);
    try json_writer.writeString(w, resolved.rel);
    try w.print(",\"bytes_written\":{d},\"sha256\":\"{s}\",\"dirty_designs\":", .{ content.len, hash_hex[0..] });
    try writeDirtyDesigns(w, allocator, project_dir, resolved.rel);
    try w.writeAll(JSON_LIBRARY_CHANGES_KEY);
    try writeLibraryChanges(w, resolved.rel);
    try w.writeAll("}");
    return true;
}

const ReadForEditError = std.fs.File.OpenError || std.fs.File.ReadError ||
    std.fs.Dir.StatFileError || std.mem.Allocator.Error ||
    error{ NotFound, IsSymlink, TooLarge };

/// Stat-then-read helper for the edit path. Maps file-not-found and
/// existing-symlink into named errors so the caller can branch once
/// instead of nesting two stat/read pairs (which pushed `editFile` over
/// the returns-per-function cap).
fn readForEdit(allocator: std.mem.Allocator, abs: []const u8) ReadForEditError![]u8 {
    const stat = infra_fs.cwd().statFile(abs) catch |e| switch (e) {
        error.FileNotFound => return error.NotFound,
        else => return e,
    };
    if (stat.kind == .sym_link) return error.IsSymlink;
    return infra_fs.cwd().readFileAlloc(allocator, abs, MAX_FILE_BYTES) catch |e| switch (e) {
        error.FileNotFound => return error.NotFound,
        error.FileTooBig => return error.TooLarge,
        else => return e,
    };
}

fn writeStaleSha(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, current: []const u8) VfsError!bool {
    out.clearRetainingCapacity();
    const w = out.writer(allocator);
    try w.print("{{\"error\":\"stale\",\"stale\":true,\"current_sha256\":\"{s}\"}}", .{current});
    return false;
}

/// Find `old_string` once in the file and replace it with `new_string`.
/// Mirrors Claude Code's local Edit tool: 0 matches → NotFound; >1 matches
/// → AmbiguousMatch (unless `replace_all=true`). Optional CAS via
/// `expected_sha256`.
pub fn editFile(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    rel_path: []const u8,
    old_string: []const u8,
    new_string: []const u8,
    expected_sha256: ?[]const u8,
    replace_mode: ReplaceMode,
    out: *std.ArrayListUnmanaged(u8),
) VfsError!bool {
    if (old_string.len == 0) {
        return writeError(out, allocator, "old_string must be non-empty");
    }
    const replace_all = replace_mode == .all;
    const resolved = resolveSandboxedWithRel(allocator, project_dir, rel_path, .write) catch |e| {
        return writeSandboxError(out, allocator, e, rel_path, .write);
    };
    defer allocator.free(resolved.abs);

    const existing = readForEdit(allocator, resolved.abs) catch |e| switch (e) {
        error.NotFound => return writeError(out, allocator, ERR_NOT_FOUND),
        error.IsSymlink => return writeError(out, allocator, ERR_REFUSE_SYMLINK),
        error.TooLarge => return writeError(out, allocator, ERR_FILE_TOO_LARGE),
        else => |real| return real,
    };
    defer allocator.free(existing);

    if (expected_sha256) |expected| {
        var hash_hex: [64]u8 = undefined;
        sha256Hex(existing, &hash_hex);
        if (!std.mem.eql(u8, expected, hash_hex[0..])) {
            return writeStaleSha(out, allocator, hash_hex[0..]);
        }
    }

    var match_count: usize = 0;
    var search_pos: usize = 0;
    while (std.mem.indexOfPos(u8, existing, search_pos, old_string)) |idx| {
        match_count += 1;
        search_pos = idx + old_string.len;
        if (!replace_all and match_count > 1) break;
    }

    if (match_count == 0) return writeError(out, allocator, "old_string not found");
    if (match_count > 1 and !replace_all) {
        return writeError(out, allocator, "ambiguous match (old_string occurs more than once; pass replace_all=true or expand context)");
    }

    var new_content: std.ArrayListUnmanaged(u8) = .empty;
    defer new_content.deinit(allocator);
    const cw = new_content.writer(allocator);

    var pos: usize = 0;
    var replacements: usize = 0;
    while (std.mem.indexOfPos(u8, existing, pos, old_string)) |idx| {
        try cw.writeAll(existing[pos..idx]);
        try cw.writeAll(new_string);
        pos = idx + old_string.len;
        replacements += 1;
        if (!replace_all) break;
    }
    try cw.writeAll(existing[pos..]);

    {
        var write_buf: [4096]u8 = undefined;
        var atomic = infra_fs.cwd().atomicFile(resolved.abs, .{ .write_buffer = &write_buf }) catch |e| return e;
        defer atomic.deinit();
        atomic.file_writer.interface.writeAll(new_content.items) catch |e| switch (e) {
            error.WriteFailed => return atomic.file_writer.err.?,
        };
        try atomic.finish();
    }

    var hash_hex: [64]u8 = undefined;
    sha256Hex(new_content.items, &hash_hex);

    const w = out.writer(allocator);
    try w.writeAll(JSON_PATH_OPEN);
    try json_writer.writeString(w, resolved.rel);
    try w.print(",\"replacements\":{d},\"sha256\":\"{s}\",\"dirty_designs\":", .{ replacements, hash_hex[0..] });
    try writeDirtyDesigns(w, allocator, project_dir, resolved.rel);
    try w.writeAll(JSON_LIBRARY_CHANGES_KEY);
    try writeLibraryChanges(w, resolved.rel);
    try w.writeAll("}");
    return true;
}

const ListEntry = struct {
    path: []const u8,
    kind: []const u8,
    size: u64,
    mtime_sec: i64,
};

fn dirEntryKind(entry: std.fs.Dir.Entry) []const u8 {
    return switch (entry.kind) {
        .directory => "dir",
        .file => "file",
        .sym_link => "symlink",
        else => "other",
    };
}

/// List entries directly under `rel_path`. Pass `recursive=true` to walk
/// the subtree. `max_entries` caps output (defaults to 1024). Empty
/// `rel_path` lists the project root.
pub fn listDir(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    rel_path: []const u8,
    list_mode: ListMode,
    max_entries: ?u64,
    out: *std.ArrayListUnmanaged(u8),
) VfsError!bool {
    const cap_u64 = max_entries orelse DEFAULT_LIST_ENTRIES;
    const cap: usize = @intCast(@min(cap_u64, @as(u64, std.math.maxInt(usize))));

    var canonical: []const u8 = "";
    var abs: []u8 = undefined;
    var owned_abs = false;
    if (rel_path.len == 0) {
        abs = try allocator.dupe(u8, project_dir);
        owned_abs = true;
    } else {
        const r = resolveSandboxedWithRel(allocator, project_dir, rel_path, .read) catch |e| {
            return writeSandboxError(out, allocator, e, rel_path, .read);
        };
        abs = r.abs;
        canonical = r.rel;
        owned_abs = true;
    }
    defer if (owned_abs) allocator.free(abs);

    var dir = infra_fs.cwd().openDir(abs, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return writeError(out, allocator, ERR_NOT_FOUND),
        error.NotDir => return writeError(out, allocator, "not a directory"),
        error.AccessDenied => return writeError(out, allocator, ERR_ACCESS_DENIED),
        else => return e,
    };
    defer dir.close();

    const w = out.writer(allocator);
    try w.writeAll(JSON_PATH_OPEN);
    try json_writer.writeString(w, canonical);
    try w.writeAll(",\"entries\":[");

    var emitted: usize = 0;
    var truncated = false;

    if (list_mode == .recursive) {
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (emitted >= cap) {
                truncated = true;
                break;
            }
            const child_rel = if (canonical.len == 0)
                try allocator.dupe(u8, entry.path)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ canonical, entry.path });
            defer allocator.free(child_rel);
            // Skip denied entries silently — keep the listing useful but
            // never leak a denied path.
            checkAcl(child_rel, .read) catch continue;
            const stat = entry.dir.statFile(entry.basename) catch continue;
            if (emitted > 0) try w.writeAll(",");
            emitted += 1;
            try emitListEntry(w, child_rel, switch (entry.kind) {
                .directory => "dir",
                .file => "file",
                .sym_link => "symlink",
                else => "other",
            }, stat.size, @as(i64, @intCast(@divTrunc(stat.mtime, std.time.ns_per_s))));
        }
    } else {
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (emitted >= cap) {
                truncated = true;
                break;
            }
            const child_rel = if (canonical.len == 0)
                try allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ canonical, entry.name });
            defer allocator.free(child_rel);
            checkAcl(child_rel, .read) catch continue;
            const stat = dir.statFile(entry.name) catch continue;
            if (emitted > 0) try w.writeAll(",");
            emitted += 1;
            try emitListEntry(w, child_rel, dirEntryKind(entry), stat.size, @as(i64, @intCast(@divTrunc(stat.mtime, std.time.ns_per_s))));
        }
    }

    try w.print("],\"count\":{d},\"truncated\":{s}}}", .{ emitted, if (truncated) "true" else "false" });
    return true;
}

fn emitListEntry(w: anytype, path: []const u8, kind: []const u8, size: u64, mtime_sec: i64) !void {
    try w.writeAll("{\"path\":");
    try json_writer.writeString(w, path);
    try w.print(",\"kind\":\"{s}\",\"size\":{d},\"mtime\":{d}}}", .{ kind, size, mtime_sec });
}

/// Find files matching `pattern` (glob) starting at `base` (default: project
/// root). Supports `*` (any chars in segment), `?` (one char), and `**`
/// (any depth). Output paths are project-relative.
pub fn glob(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    pattern: []const u8,
    base: ?[]const u8,
    out: *std.ArrayListUnmanaged(u8),
) VfsError!bool {
    if (pattern.len == 0) return writeError(out, allocator, "empty pattern");

    const base_rel = base orelse "";
    var base_abs: []u8 = undefined;
    var base_canonical: []const u8 = "";
    if (base_rel.len == 0) {
        base_abs = try allocator.dupe(u8, project_dir);
    } else {
        const r = resolveSandboxedWithRel(allocator, project_dir, base_rel, .read) catch |e| {
            return writeSandboxError(out, allocator, e, base_rel, .read);
        };
        base_abs = r.abs;
        base_canonical = r.rel;
    }
    defer allocator.free(base_abs);

    var dir = infra_fs.cwd().openDir(base_abs, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return writeError(out, allocator, "base not found"),
        error.NotDir => return writeError(out, allocator, "base not a directory"),
        else => return e,
    };
    defer dir.close();

    var matches: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (matches.items) |m| allocator.free(m);
        matches.deinit(allocator);
    }

    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind == .directory) continue;
        if (matches.items.len >= MAX_GLOB_RESULTS) break;
        if (!matchGlob(pattern, entry.path)) continue;
        const full = if (base_canonical.len == 0)
            try allocator.dupe(u8, entry.path)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_canonical, entry.path });
        checkAcl(full, .read) catch {
            allocator.free(full);
            continue;
        };
        try matches.append(allocator, full);
    }

    const w = out.writer(allocator);
    try w.writeAll("{\"matches\":[");
    for (matches.items, 0..) |m, i| {
        if (i > 0) try w.writeAll(",");
        try json_writer.writeString(w, m);
    }
    try w.print("],\"count\":{d}}}", .{matches.items.len});
    return true;
}

/// Glob matcher supporting `*`, `?`, and `**`. Match is anchored to the
/// full string. `**` matches any number of segments (including zero).
fn matchGlob(pattern: []const u8, name: []const u8) bool {
    return matchGlobInner(pattern, 0, name, 0);
}

fn matchGlobInner(pattern: []const u8, pi_in: usize, name: []const u8, ni_in: usize) bool {
    var pi = pi_in;
    var ni = ni_in;
    while (pi < pattern.len) {
        const pc = pattern[pi];
        if (pc == '*') {
            const is_double = pi + 1 < pattern.len and pattern[pi + 1] == '*';
            if (is_double) {
                pi += 2;
                if (pi < pattern.len and pattern[pi] == '/') pi += 1;
                if (pi >= pattern.len) return true;
                while (ni <= name.len) : (ni += 1) {
                    if (matchGlobInner(pattern, pi, name, ni)) return true;
                }
                return false;
            } else {
                pi += 1;
                if (pi >= pattern.len) {
                    while (ni < name.len) : (ni += 1) {
                        if (name[ni] == '/') return false;
                    }
                    return true;
                }
                while (ni <= name.len) : (ni += 1) {
                    if (matchGlobInner(pattern, pi, name, ni)) return true;
                    if (ni < name.len and name[ni] == '/') return false;
                }
                return false;
            }
        } else if (pc == '?') {
            if (ni >= name.len or name[ni] == '/') return false;
            pi += 1;
            ni += 1;
        } else {
            if (ni >= name.len or name[ni] != pc) return false;
            pi += 1;
            ni += 1;
        }
    }
    return ni == name.len;
}

/// Delete a single file. Refuses to delete directories (use a separate
/// step if that's ever needed) and refuses symlinks (the link is human-
/// managed). Returns `dirty_designs` so the agent knows which design to
/// rebuild.
pub fn deleteFile(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    rel_path: []const u8,
    out: *std.ArrayListUnmanaged(u8),
) VfsError!bool {
    const resolved = resolveSandboxedWithRel(allocator, project_dir, rel_path, .write) catch |e| {
        return writeSandboxError(out, allocator, e, rel_path, .write);
    };
    defer allocator.free(resolved.abs);

    const stat = infra_fs.cwd().statFile(resolved.abs) catch |e| switch (e) {
        error.FileNotFound => return writeError(out, allocator, ERR_NOT_FOUND),
        else => return e,
    };
    if (stat.kind == .directory) return writeError(out, allocator, "is a directory");
    if (stat.kind == .sym_link) return writeError(out, allocator, "refusing to delete symlink");

    infra_fs.cwd().deleteFile(resolved.abs) catch |e| switch (e) {
        error.AccessDenied => return writeError(out, allocator, ERR_ACCESS_DENIED),
        else => return e,
    };

    const w = out.writer(allocator);
    try w.writeAll(JSON_PATH_OPEN);
    try json_writer.writeString(w, resolved.rel);
    try w.writeAll(",\"deleted\":true,\"dirty_designs\":");
    try writeDirtyDesigns(w, allocator, project_dir, resolved.rel);
    try w.writeAll(JSON_LIBRARY_CHANGES_KEY);
    try writeLibraryChanges(w, resolved.rel);
    try w.writeAll("}");
    return true;
}

/// Rename `from` → `to`. Both paths are sandbox-checked under the write
/// allowlist. POSIX `rename` is atomic on the same filesystem.
pub fn moveFile(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    from_rel: []const u8,
    to_rel: []const u8,
    out: *std.ArrayListUnmanaged(u8),
) VfsError!bool {
    const from = resolveSandboxedWithRel(allocator, project_dir, from_rel, .write) catch |e| {
        return writeSandboxError(out, allocator, e, from_rel, .write);
    };
    defer allocator.free(from.abs);
    const to = resolveSandboxedWithRel(allocator, project_dir, to_rel, .write) catch |e| {
        return writeSandboxError(out, allocator, e, to_rel, .write);
    };
    defer allocator.free(to.abs);

    if (std.fs.path.dirname(to.abs)) |parent| {
        infra_fs.cwd().makePath(parent) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
    }

    infra_fs.cwd().rename(from.abs, to.abs) catch |e| switch (e) {
        error.FileNotFound => return writeError(out, allocator, "source not found"),
        error.AccessDenied => return writeError(out, allocator, ERR_ACCESS_DENIED),
        error.PathAlreadyExists => return writeError(out, allocator, "destination already exists"),
        else => return e,
    };

    const w = out.writer(allocator);
    try w.writeAll("{\"from\":");
    try json_writer.writeString(w, from.rel);
    try w.writeAll(",\"to\":");
    try json_writer.writeString(w, to.rel);
    try w.writeAll(",\"dirty_designs\":");
    try writeDirtyDesigns(w, allocator, project_dir, to.rel);
    try w.writeAll(JSON_LIBRARY_CHANGES_KEY);
    try writeLibraryChanges(w, to.rel);
    try w.writeAll("}");
    return true;
}

/// Write a `library_changes` JSON array describing which library entity (if
/// any) was touched by the write. Computed purely from `rel_path` — no file
/// content parsing — so it remains accurate even if the agent edited the
/// file into something unparsable. Empty array for paths outside `lib/`.
///
/// Why this exists: when an agent edits `lib/components/foo.sexp` and no
/// design currently imports `foo`, `dirty_designs` is correctly `[]` but the
/// empty array reads as "nothing happened." `library_changes` is the
/// unambiguous "the write landed at this library entity" signal so the agent
/// doesn't second-guess and re-write.
fn writeLibraryChanges(w: anytype, rel_path: []const u8) !void {
    try w.writeAll("[");
    if (libraryEntityFor(rel_path)) |entity| {
        try w.writeAll("{\"kind\":\"");
        try w.writeAll(entity.kind);
        try w.writeAll("\",\"name\":");
        try json_writer.writeString(w, entity.name);
        try w.writeAll(",\"path\":");
        try json_writer.writeString(w, rel_path);
        try w.writeAll("}");
    }
    try w.writeAll("]");
}

const LibraryEntity = struct {
    kind: []const u8,
    name: []const u8,
};

/// Map `lib/<sub>/<name>.<ext>` to `{kind, name}`. Returns null for paths
/// outside the library or for files in unknown subdirs. The `name` is the
/// basename stripped of its extension; library-aware tools key on this.
fn libraryEntityFor(rel_path: []const u8) ?LibraryEntity {
    const Map = struct { prefix: []const u8, kind: []const u8 };
    const known = [_]Map{
        .{ .prefix = LIB_COMPONENTS, .kind = "component" },
        .{ .prefix = LIB_MODULES, .kind = "module" },
        .{ .prefix = LIB_PINOUTS, .kind = "pinout" },
        .{ .prefix = LIB_FOOTPRINTS, .kind = "footprint" },
        .{ .prefix = LIB_DATASHEETS, .kind = "datasheet" },
        .{ .prefix = LIB_SOURCES, .kind = "source" },
        .{ .prefix = LIB_MODELS, .kind = "model" },
        .{ .prefix = LIB_PARTS, .kind = "part" },
    };
    for (known) |m| {
        if (!std.mem.startsWith(u8, rel_path, m.prefix)) continue;
        const tail = rel_path[m.prefix.len..];
        if (tail.len == 0 or std.mem.indexOfScalar(u8, tail, '/') != null) return null;
        // Strip trailing extension (last '.'). Datasheets keep the .pdf
        // suffix off the name, sources lose .kicad_sym, etc.
        const dot_idx = std.mem.lastIndexOfScalar(u8, tail, '.');
        const base = if (dot_idx) |di| tail[0..di] else tail;
        if (base.len == 0) return null;
        return .{ .kind = m.kind, .name = base };
    }
    return null;
}

/// Compute which design names are made dirty by a write to `rel_path`.
/// `src/<name>.sexp` and `src/<name>.bom` map to `[name]`. Library /
/// blocks edits scan `src/*.sexp` for an `(import <basename>)` of the
/// modified file — that's the cheapest correct approximation.
fn writeDirtyDesigns(
    w: anytype,
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    rel_path: []const u8,
) !void {
    const dirty = try dirtyDesignsForPath(allocator, project_dir, rel_path);
    defer {
        for (dirty) |d| allocator.free(d);
        allocator.free(dirty);
    }
    try w.writeAll("[");
    for (dirty, 0..) |d, i| {
        if (i > 0) try w.writeAll(",");
        try json_writer.writeString(w, d);
    }
    try w.writeAll("]");
}

/// Return the set of design names (basenames under src/) that should be
/// rebuilt after a write to `rel_path`. Caller owns the slice and each
/// element.
pub fn dirtyDesignsForPath(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    rel_path: []const u8,
) (std.mem.Allocator.Error || std.fs.Dir.OpenError || std.fs.Dir.Iterator.Error)![][]const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }

    if (std.mem.startsWith(u8, rel_path, "src/")) {
        const tail = rel_path["src/".len..];
        const base = if (std.mem.endsWith(u8, tail, ".sexp"))
            tail[0 .. tail.len - ".sexp".len]
        else if (std.mem.endsWith(u8, tail, ".bom"))
            tail[0 .. tail.len - ".bom".len]
        else
            return out.toOwnedSlice(allocator);
        if (std.mem.indexOfScalar(u8, base, '/') != null) return out.toOwnedSlice(allocator);
        try out.append(allocator, try allocator.dupe(u8, base));
        return out.toOwnedSlice(allocator);
    }

    // For lib/ and blocks/ edits, scan every src/*.sexp for an import of
    // the modified file's basename. Cheaper than a full evaluator pass and
    // doesn't require any caching (a project has tens of designs at most).
    const basename_with_ext = std.fs.path.basename(rel_path);
    if (!std.mem.endsWith(u8, basename_with_ext, ".sexp")) return out.toOwnedSlice(allocator);
    const basename = basename_with_ext[0 .. basename_with_ext.len - ".sexp".len];

    const src_dir = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    defer allocator.free(src_dir);
    var dir = infra_fs.cwd().openDir(src_dir, .{ .iterate = true }) catch return out.toOwnedSlice(allocator);
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sexp")) continue;
        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src_dir, entry.name });
        defer allocator.free(full);
        const src = infra_fs.cwd().readFileAlloc(allocator, full, MAX_FILE_BYTES) catch continue;
        defer allocator.free(src);
        if (!importsName(src, basename)) continue;
        const design = entry.name[0 .. entry.name.len - ".sexp".len];
        try out.append(allocator, try allocator.dupe(u8, design));
    }
    return out.toOwnedSlice(allocator);
}

/// Word-boundary check: `name` appears in `src` as a standalone token
/// inside (or after) an `(import ...)` form. Cheaper than full sexpr
/// parsing and good enough for the dirty-tracking heuristic.
fn importsName(src: []const u8, name: []const u8) bool {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, src, pos, name)) |idx| {
        const before_ok = idx == 0 or !isAtomChar(src[idx - 1]);
        const after_idx = idx + name.len;
        const after_ok = after_idx >= src.len or !isAtomChar(src[after_idx]);
        if (before_ok and after_ok) return true;
        pos = idx + 1;
    }
    return false;
}

fn isAtomChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_' or c == '-';
}

// ── Tests ─────────────────────────────────────────────────────────────

test "validateRel rejects parent traversal" {
    // spec: serve/vfs - rejects parent traversal
    try std.testing.expectError(error.ParentTraversal, validateRel("../etc/passwd"));
    try std.testing.expectError(error.ParentTraversal, validateRel("src/../auth/x"));
}

test "validateRel rejects absolute paths" {
    // spec: serve/vfs - rejects absolute paths
    try std.testing.expectError(error.AbsolutePath, validateRel("/etc/passwd"));
}

test "validateRel rejects dot segments" {
    // spec: serve/vfs - rejects dot-prefixed segments
    try std.testing.expectError(error.DotSegment, validateRel(".guardian/baselines/x"));
    try std.testing.expectError(error.DotSegment, validateRel("src/.hidden"));
}

test "validateRel rejects nul and backslash" {
    // spec: serve/vfs - rejects NUL and backslash bytes
    try std.testing.expectError(error.InvalidByte, validateRel("src/foo\x00bar"));
    try std.testing.expectError(error.InvalidByte, validateRel("src\\foo"));
}

test "checkAcl allows src and lib paths" {
    // spec: serve/vfs - allows project source and library paths
    try std.testing.expectEqual({}, try checkAcl("src/foo.sexp", .write));
    try std.testing.expectEqual({}, try checkAcl("lib/components/cap-0402.sexp", .write));
    try std.testing.expectEqual({}, try checkAcl("blocks/buck-boost.sexp", .write));
    try std.testing.expectEqual({}, try checkAcl("lib/datasheets/foo.pdf", .read));
    try std.testing.expectEqual({}, try checkAcl("lib/sources/foo.kicad_sym", .write));
}

test "checkAcl denies writes to lib/datasheets via write_file" {
    // spec: serve/vfs - denies write_file on lib/datasheets (PDFs are read-only via MCP)
    try std.testing.expectError(error.PermissionDenied, checkAcl("lib/datasheets/foo.pdf", .write));
}

test "checkAcl denies auth and oauth paths" {
    // spec: serve/vfs - denies auth and oauth paths
    try std.testing.expectError(error.PermissionDenied, checkAcl("auth/sessions.json", .read));
    try std.testing.expectError(error.PermissionDenied, checkAcl("oauth_clients.json", .read));
    try std.testing.expectError(error.PermissionDenied, checkAcl("oauth_clients.json", .write));
}

test "checkAcl denies writes to history and out" {
    // spec: serve/vfs - denies writes to history and out
    try std.testing.expectError(error.PermissionDenied, checkAcl("history/foo/2026/file.sexp", .write));
    try std.testing.expectError(error.PermissionDenied, checkAcl("out/board.kicad_pcb", .write));
}

test "matchGlob basic patterns" {
    // spec: serve/vfs - matches basic glob patterns
    try std.testing.expect(matchGlob("*.sexp", "foo.sexp"));
    try std.testing.expect(!matchGlob("*.sexp", "foo.bom"));
    try std.testing.expect(matchGlob("src/*.sexp", "src/foo.sexp"));
    try std.testing.expect(!matchGlob("src/*.sexp", "src/sub/foo.sexp"));
    try std.testing.expect(matchGlob("**/*.sexp", "lib/components/foo.sexp"));
    try std.testing.expect(matchGlob("**/*.sexp", "foo.sexp"));
}

test "importsName word boundary" {
    // spec: serve/vfs - import detection respects word boundaries
    try std.testing.expect(importsName("(import cap-0402)", "cap-0402"));
    try std.testing.expect(!importsName("(import cap-0402-special)", "cap-0402"));
    try std.testing.expect(importsName("(import foo)\n(import bar)", "bar"));
}

test "denialHint surfaces lib redirection on read for slash variants" {
    // spec: serve/vfs - denialHint redirects bare lib listing to list_library
    // The catch path passes the agent's raw input; both `lib` and `lib/` must hint.
    try std.testing.expect(denialHint("lib", .read) != null);
    try std.testing.expect(denialHint("lib/", .read) != null);
    try std.testing.expect(denialHint("./lib", .read) != null);
    try std.testing.expect(denialHint("./lib/", .read) != null);
    // Unknown subdir under lib/ also hints — the agent should run list_library first.
    try std.testing.expect(denialHint("lib/widgets", .read) != null);
    // Known subdirs aren't actually denied, but if they were we'd not hint.
    try std.testing.expect(denialHint("lib/components/foo.sexp", .read) == null);
}

test "denialHint redirects writes to lib/datasheets/" {
    // spec: serve/vfs - denialHint redirects PDF writes to the disk/browser route
    try std.testing.expect(denialHint("lib/datasheets/foo.pdf", .write) != null);
    try std.testing.expect(denialHint("lib/datasheets", .write) != null);
    try std.testing.expect(denialHint("lib/datasheets/", .write) != null);
    try std.testing.expect(denialHint("lib/components/foo.sexp", .write) == null);
}

test "libraryEntityFor maps lib paths to entity descriptors" {
    // spec: serve/vfs - libraryEntityFor classifies library subdirs
    const c = libraryEntityFor("lib/components/adar2004accz.sexp").?;
    try std.testing.expectEqualStrings("component", c.kind);
    try std.testing.expectEqualStrings("adar2004accz", c.name);

    const p = libraryEntityFor("lib/pinouts/foo.sexp").?;
    try std.testing.expectEqualStrings("pinout", p.kind);

    const d = libraryEntityFor("lib/datasheets/example.pdf").?;
    try std.testing.expectEqualStrings("datasheet", d.kind);
    try std.testing.expectEqualStrings("example", d.name);

    try std.testing.expect(libraryEntityFor("src/foo.sexp") == null);
    try std.testing.expect(libraryEntityFor("lib/components/sub/nested.sexp") == null);
}
