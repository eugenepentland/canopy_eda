//! CLI query commands — the agent-facing read surface of `netlisp`.
//!
//! These subcommands let an agent inspect designs and the library without a
//! running server: list designs, list a design's instances, walk a net, find
//! an IC's free pins, dump the scene graph, describe a library component,
//! search the library, and print the DSL grammar reference.
//!
//! Single source of truth: the structural emitters (`instances`, `net`,
//! `free-pins`, `schematic`, `library`, `describe`) call the very same `pub`
//! functions the MCP server's tools call (`serve/mcp_tools.zig`,
//! `serve/component_info.zig`), so the CLI and MCP outputs never diverge.
//! `designs` and `reference` are CLI-only conveniences built here.
//!
//! Output is the JSON the MCP tools already emit (agents parse it directly);
//! `reference` prints Markdown. Every command resolves designs relative to
//! `--project-dir` (default `.`), so an agent rooted in `projects/designs/`
//! omits it.

const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const json_writer = @import("json_writer.zig");
const docgen = @import("docgen.zig");
const mcp_tools = @import("serve/mcp_tools.zig");
const component_info = @import("serve/component_info.zig");

const MAX_DESIGN_BYTES: usize = 4 * 1024 * 1024;
const DESIGN_BLOCK_MARKER = "(design-block";

/// Error set for the public CLI handlers. Each `cmd*` catches the wide,
/// caller-dependent errors of the shared emitters (which take `w: anytype`)
/// and only propagates these concrete IO/allocation errors — the heavy
/// `ToolError`/`DescribeError` paths are handled in-line with a message + exit.
pub const QueryError = std.mem.Allocator.Error ||
    std.Io.Writer.Error ||
    std.fs.File.WriteError ||
    std.fs.Dir.Iterator.Error;

// ── Arg parsing ──────────────────────────────────────────────────────

/// Return the value following `--<flag>` anywhere in `args`, else null.
fn optArg(args: []const []const u8, flag: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag)) return args[i + 1];
    }
    return null;
}

/// Flags that consume the following token as their value — skipped (with
/// their value) when collecting positionals.
fn isValueFlag(a: []const u8) bool {
    return std.mem.eql(u8, a, "--project-dir") or
        std.mem.eql(u8, a, "--category") or
        std.mem.eql(u8, a, "--section");
}

/// Return the n-th (0-based) positional argument, skipping flags and their
/// values. Boolean flags (`--json`) and value-flag pairs are passed over.
fn nthPositional(args: []const []const u8, n: usize) ?[]const u8 {
    var count: usize = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (isValueFlag(a)) {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--")) continue;
        if (count == n) return a;
        count += 1;
    }
    return null;
}

fn projectDir(args: []const []const u8) []const u8 {
    return optArg(args, "--project-dir") orelse ".";
}

/// Print a usage line and exit non-zero.
fn usage(line: []const u8) noreturn {
    std.debug.print("Usage: netlisp {s}\n", .{line});
    std.process.exit(1);
}

/// Write `bytes` to stdout followed by a newline.
fn emit(bytes: []const u8) !void {
    const stdout = std.fs.File.stdout();
    try stdout.writeAll(bytes);
    try stdout.writeAll("\n");
}

// ── Structural queries (delegate to the shared MCP emitters) ─────────

/// `netlisp instances <design>` — every placed part as JSON.
pub fn cmdInstances(allocator: std.mem.Allocator, args: []const []const u8) QueryError!void {
    const name = nthPositional(args, 0) orelse usage("instances [--project-dir <d>] <design>");
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(allocator);
    const ok = mcp_tools.listInstances(allocator, projectDir(args), name, w) catch |e| {
        std.debug.print("instances: {s}: {s}\n", .{ name, @errorName(e) });
        std.process.exit(1);
    };
    try emit(buf.items);
    if (!ok) std.process.exit(1);
}

/// `netlisp net <design> <net>` — every pin + passive on a net, as JSON.
pub fn cmdNet(allocator: std.mem.Allocator, args: []const []const u8) QueryError!void {
    const name = nthPositional(args, 0) orelse usage("net [--project-dir <d>] <design> <net>");
    const net = nthPositional(args, 1) orelse usage("net [--project-dir <d>] <design> <net>");
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(allocator);
    const ok = mcp_tools.getNet(allocator, projectDir(args), name, net, w) catch |e| {
        std.debug.print("net: {s}/{s}: {s}\n", .{ name, net, @errorName(e) });
        std.process.exit(1);
    };
    try emit(buf.items);
    if (!ok) std.process.exit(1);
}

/// `netlisp free-pins <design> <ref> [--category gpio|power|clock|analog|other]`
/// — unassigned pins on an instance, with function names + classification.
pub fn cmdFreePins(allocator: std.mem.Allocator, args: []const []const u8) QueryError!void {
    const spec = "free-pins [--project-dir <d>] <design> <ref> [--category gpio|power|clock|analog|other]";
    const name = nthPositional(args, 0) orelse usage(spec);
    const ref = nthPositional(args, 1) orelse usage(spec);
    const category = optArg(args, "--category");
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(allocator);
    const ok = mcp_tools.listFreePins(allocator, projectDir(args), name, ref, category, w) catch |e| {
        std.debug.print("free-pins: {s}/{s}: {s}\n", .{ name, ref, @errorName(e) });
        std.process.exit(1);
    };
    try emit(buf.items);
    if (!ok) std.process.exit(1);
}

/// `netlisp schematic <design>` — the full scene-graph JSON (instances, nets,
/// sub-blocks, ports, ERC) — the same document the browser viewer consumes.
pub fn cmdSchematic(allocator: std.mem.Allocator, args: []const []const u8) QueryError!void {
    const name = nthPositional(args, 0) orelse usage("schematic [--project-dir <d>] <design>");
    const json = mcp_tools.renderSceneGraph(allocator, projectDir(args), name) catch |e| {
        std.debug.print("schematic: {s}: {s}\n", .{ name, @errorName(e) });
        std.process.exit(1);
    };
    defer allocator.free(json);
    try emit(json);
}

/// `netlisp describe <component>` — a library component's full definition:
/// pinout, footprint, MPN, datasheets, and datasheet `(requirement …)` rules.
pub fn cmdDescribe(allocator: std.mem.Allocator, args: []const []const u8) QueryError!void {
    const name = nthPositional(args, 0) orelse usage("describe [--project-dir <d>] <component>");
    var out: std.ArrayList(u8) = .empty;
    const ok = component_info.describeComponent(allocator, projectDir(args), name, &out) catch |e| {
        std.debug.print("describe: {s}: {s}\n", .{ name, @errorName(e) });
        std.process.exit(1);
    };
    try emit(out.items);
    if (!ok) std.process.exit(1);
}

/// `netlisp library [query]` — fuzzy-search the library across components,
/// modules, part families, and footprints. With no query, lists everything.
pub fn cmdLibrary(allocator: std.mem.Allocator, args: []const []const u8) QueryError!void {
    const query = nthPositional(args, 0);
    const pdir = projectDir(args);
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(allocator);
    try w.writeAll("{\"components\":");
    try mcp_tools.listLibrarySubdir(allocator, pdir, "components", query, w);
    try w.writeAll(",\"modules\":");
    try mcp_tools.listLibrarySubdir(allocator, pdir, "modules", query, w);
    try w.writeAll(",\"parts\":");
    try mcp_tools.listLibrarySubdir(allocator, pdir, "parts", query, w);
    try w.writeAll(",\"footprints\":");
    try mcp_tools.listLibrarySubdir(allocator, pdir, "footprints", query, w);
    try w.writeAll("}");
    try emit(buf.items);
}

// ── DSL grammar reference ────────────────────────────────────────────

/// `netlisp reference [section]` — print the machine-generated DSL grammar
/// (identical to docs/language-forms.md). With a section name (or
/// `--section`), prints just that `## ` section; an unknown name lists the
/// available section headers.
pub fn cmdReference(allocator: std.mem.Allocator, args: []const []const u8) QueryError!void {
    const full = try docgen.renderLanguageReference(allocator);
    defer allocator.free(full);

    const section = optArg(args, "--section") orelse nthPositional(args, 0);
    if (section == null) {
        try emit(full);
        return;
    }

    if (extractSection(full, section.?)) |slice| {
        try emit(slice);
        return;
    }
    std.debug.print("reference: no section matching '{s}'. Available sections:\n", .{section.?});
    printSectionHeaders(full);
    std.process.exit(1);
}

/// Return the `## ` section whose title contains `query` (case-insensitive),
/// spanning to the next `## ` header or end of document. Null if none match.
fn extractSection(md: []const u8, query: []const u8) ?[]const u8 {
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, md, idx, "\n## ")) |h| {
        const title_start = h + "\n## ".len;
        const title_end = std.mem.indexOfScalarPos(u8, md, title_start, '\n') orelse md.len;
        const title = md[title_start..title_end];
        if (containsIgnoreCase(title, query)) {
            const next = std.mem.indexOfPos(u8, md, title_end, "\n## ") orelse md.len;
            return md[title_start - "## ".len .. next];
        }
        idx = title_end;
    }
    return null;
}

fn printSectionHeaders(md: []const u8) void {
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, md, idx, "\n## ")) |h| {
        const title_start = h + "\n## ".len;
        const title_end = std.mem.indexOfScalarPos(u8, md, title_start, '\n') orelse md.len;
        std.debug.print("  {s}\n", .{md[title_start..title_end]});
        idx = title_end;
    }
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// ── Design listing ───────────────────────────────────────────────────

const DesignRow = struct { name: []const u8, title: []const u8 };

fn designRowLess(_: void, a: DesignRow, b: DesignRow) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// `netlisp designs` — list every design under `src/` (name + title) as JSON.
/// A design is any `*.sexp` whose body contains a `(design-block …)`; sidecar
/// `.sexp` files (`.checks.sexp`) are skipped.
pub fn cmdDesigns(allocator: std.mem.Allocator, args: []const []const u8) QueryError!void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const src_path = try std.fmt.allocPrint(a, "{s}/src", .{projectDir(args)});
    var dir = infra_fs.cwd().openDir(src_path, .{ .iterate = true }) catch {
        try emit("{\"designs\":[]}");
        return;
    };
    defer dir.close();

    var rows: std.ArrayList(DesignRow) = .empty;
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (walker.next() catch null) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".sexp")) continue;
        const stem = entry.basename[0 .. entry.basename.len - ".sexp".len];
        if (std.mem.indexOfScalar(u8, stem, '.') != null) continue; // skip `.checks.sexp` etc.

        const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ src_path, entry.path });
        const src = infra_fs.cwd().readFileAlloc(a, full, MAX_DESIGN_BYTES) catch continue;
        const db = std.mem.indexOf(u8, src, DESIGN_BLOCK_MARKER) orelse continue;
        try rows.append(a, .{
            .name = try a.dupe(u8, stem),
            .title = try extractTitle(a, src, db),
        });
    }
    std.mem.sort(DesignRow, rows.items, {}, designRowLess);

    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(a);
    try w.writeAll("{\"designs\":[");
    for (rows.items, 0..) |r, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try json_writer.writeString(w, r.name);
        try w.writeAll(",\"title\":");
        try json_writer.writeString(w, r.title);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
    try emit(buf.items);
}

/// Extract the quoted title immediately after `(design-block` at `db_idx`.
/// Returns "" when the title is not a bare string (e.g. `(design-block (fmt …))`).
fn extractTitle(allocator: std.mem.Allocator, src: []const u8, db_idx: usize) ![]const u8 {
    var i = db_idx + DESIGN_BLOCK_MARKER.len;
    while (i < src.len and std.ascii.isWhitespace(src[i])) : (i += 1) {}
    if (i >= src.len or src[i] != '"') return allocator.dupe(u8, "");
    i += 1;
    const start = i;
    while (i < src.len and src[i] != '"') : (i += 1) {}
    return allocator.dupe(u8, src[start..i]);
}
