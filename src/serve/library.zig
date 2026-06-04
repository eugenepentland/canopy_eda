const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const export_kicad = @import("../export_kicad.zig");
const footprint_mod = @import("../export_kicad_footprint.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;
const library_template = @import("templates/library.zig");
const footprint_preview = @import("footprint_preview.zig");

// ── Constants ─────────────────────────────────────────────────────
const SEXP_EXT_LEN: usize = ".sexp".len;
const PIN_FORM_LEN: usize = "(pin ".len;
const MAX_LIB_FILE_BYTES: usize = 256 * 1024;

/// Error set for HTTP handlers and writers in this module.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error || std.fs.Dir.Iterator.Error;

/// One row in the `/library` table. Components and families share most
/// fields; pinouts use `pin_count`; footprints are name-only. `search_text`
/// is pre-concatenated whitespace-separated metadata that the client-side
/// search box matches against.
pub const LibraryRow = struct {
    name: []const u8,
    kind: Kind,
    search_text: []const u8,
    description: ?[]const u8 = null,
    footprint: ?[]const u8 = null,
    has_3d_model: bool = false,
    pinout: ?[]const u8 = null,
    manufacturer: ?[]const u8 = null,
    mpn: ?[]const u8 = null,
    pin_count: ?usize = null,
    requirements: []const []const u8 = &.{},
    /// PDF documents declared by the component via `(datasheet "…")`, rendered
    /// as links to `/datasheets/<name>` on the library page. Empty when the
    /// component declares none.
    datasheets: []const Datasheet = &.{},

    pub const Kind = enum { family, component, pinout, footprint };

    /// One declared datasheet. `present` is false when the PDF is referenced
    /// but not actually in `lib/datasheets/`, so the template can flag it as
    /// missing instead of rendering a dead link.
    pub const Datasheet = struct {
        name: []const u8,
        present: bool,
    };
};

const RowWithMtime = struct {
    row: LibraryRow,
    mtime: i128,
    fn newerFirst(_: void, a: RowWithMtime, b: RowWithMtime) bool {
        return a.mtime > b.mtime;
    }
};

/// Walk `lib/components/`, `lib/pinouts/`, `lib/footprints/` and return
/// a flat slice of `LibraryRow`s sorted newest-first by mtime, ready to
/// feed the `library.zt` template. Strings are allocator-owned.
fn collectRows(allocator: std.mem.Allocator, project_dir: []const u8) HandlerError![]LibraryRow {
    var buf: std.ArrayListUnmanaged(RowWithMtime) = .empty;
    var referenced_pinouts = std.StringHashMap(void).init(allocator);
    var referenced_footprints = std.StringHashMap(void).init(allocator);
    const model_cfg = export_kicad.loadModelConfig(allocator, project_dir);

    // Components / families.
    const comp_dir_path = try std.fmt.allocPrint(allocator, "{s}/lib/components", .{project_dir});
    defer allocator.free(comp_dir_path);
    if (infra_fs.cwd().openDir(comp_dir_path, .{ .iterate = true })) |dir_val| {
        var dir = dir_val;
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".sexp")) continue;
            const base = try allocator.dupe(u8, entry.name[0 .. entry.name.len - SEXP_EXT_LEN]);
            const content = dir.readFileAlloc(allocator, entry.name, MAX_LIB_FILE_BYTES) catch continue;
            const mtime = if (dir.statFile(entry.name)) |s| s.mtime else |_| 0;

            const description = extractField(content, "description");
            const footprint = extractField(content, "footprint");
            const pinout = extractField(content, "pinout");
            const manufacturer = extractField(content, "manufacturer");
            const mpn = extractField(content, "mpn");
            const datasheets = try extractDatasheets(allocator, project_dir, content);
            const is_family = std.mem.indexOf(u8, content, "(component-family ") != null;

            if (footprint) |fp| try referenced_footprints.put(fp, {});
            if (pinout) |po| try referenced_pinouts.put(po, {});

            const has_model = if (footprint) |fp| blk: {
                if (model_cfg.get(fp)) |c| {
                    if (c.model != null) break :blk true;
                }
                break :blk footprint_mod.findModelFile(allocator, project_dir, fp, fp) != null;
            } else false;

            try buf.append(allocator, .{
                .mtime = mtime,
                .row = .{
                    .name = base,
                    .kind = if (is_family) .family else .component,
                    .search_text = try buildSearchText(allocator, base, description, footprint, pinout, manufacturer, mpn, datasheets),
                    .description = description,
                    .footprint = footprint,
                    .has_3d_model = has_model,
                    .pinout = pinout,
                    .manufacturer = manufacturer,
                    .mpn = mpn,
                    .requirements = try extractRequirements(allocator, content),
                    .datasheets = datasheets,
                },
            });
        }
    } else |_| {}

    // Standalone pinouts (not referenced).
    const pinout_path = try std.fmt.allocPrint(allocator, "{s}/lib/pinouts", .{project_dir});
    defer allocator.free(pinout_path);
    if (infra_fs.cwd().openDir(pinout_path, .{ .iterate = true })) |dir_val| {
        var dir = dir_val;
        defer dir.close();
        var liter = dir.iterate();
        while (try liter.next()) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".sexp")) continue;
            const lname_local = entry.name[0 .. entry.name.len - SEXP_EXT_LEN];
            if (referenced_pinouts.contains(lname_local)) continue;
            const lname = try allocator.dupe(u8, lname_local);
            const content = dir.readFileAlloc(allocator, entry.name, MAX_LIB_FILE_BYTES) catch continue;
            const mtime = if (dir.statFile(entry.name)) |s| s.mtime else |_| 0;
            var pin_count: usize = 0;
            var pos: usize = 0;
            while (std.mem.indexOfPos(u8, content, pos, "(pin ")) |idx| {
                pin_count += 1;
                pos = idx + PIN_FORM_LEN;
            }
            try buf.append(allocator, .{
                .mtime = mtime,
                .row = .{
                    .name = lname,
                    .kind = .pinout,
                    .search_text = try std.fmt.allocPrint(allocator, "{s} pinout", .{lname}),
                    .pin_count = pin_count,
                },
            });
        }
    } else |_| {}

    // Standalone footprints (not referenced).
    const fp_path = try std.fmt.allocPrint(allocator, "{s}/lib/footprints", .{project_dir});
    defer allocator.free(fp_path);
    if (infra_fs.cwd().openDir(fp_path, .{ .iterate = true })) |dir_val| {
        var dir = dir_val;
        defer dir.close();
        var fiter = dir.iterate();
        while (try fiter.next()) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".sexp")) continue;
            const fname_local = entry.name[0 .. entry.name.len - SEXP_EXT_LEN];
            if (referenced_footprints.contains(fname_local)) continue;
            const fname = try allocator.dupe(u8, fname_local);
            const mtime = if (dir.statFile(entry.name)) |s| s.mtime else |_| 0;
            const fp_has_model = blk: {
                if (model_cfg.get(fname_local)) |c| {
                    if (c.model != null) break :blk true;
                }
                break :blk footprint_mod.findModelFile(allocator, project_dir, fname_local, fname_local) != null;
            };
            try buf.append(allocator, .{
                .mtime = mtime,
                .row = .{
                    .name = fname,
                    .kind = .footprint,
                    .search_text = try std.fmt.allocPrint(allocator, "{s} footprint", .{fname}),
                    .has_3d_model = fp_has_model,
                },
            });
        }
    } else |_| {}

    std.sort.heap(RowWithMtime, buf.items, {}, RowWithMtime.newerFirst);

    var rows: std.ArrayListUnmanaged(LibraryRow) = .empty;
    for (buf.items) |wm| try rows.append(allocator, wm.row);
    return rows.toOwnedSlice(allocator);
}

fn buildSearchText(
    allocator: std.mem.Allocator,
    base: []const u8,
    description: ?[]const u8,
    footprint: ?[]const u8,
    pinout: ?[]const u8,
    manufacturer: ?[]const u8,
    mpn: ?[]const u8,
    datasheets: []const LibraryRow.Datasheet,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);
    try w.writeAll(base);
    if (description) |d| try w.print(" {s}", .{d});
    if (footprint) |fp| try w.print(" {s}", .{fp});
    if (pinout) |po| try w.print(" {s}", .{po});
    if (manufacturer) |m| try w.print(" {s}", .{m});
    if (mpn) |m| try w.print(" {s}", .{m});
    for (datasheets) |ds| try w.print(" {s}", .{ds.name});
    return buf.items;
}

/// GET /library — render the component-library browser: a searchable
/// listing of every symbol/family/footprint/pinout under `lib/` plus a
/// drag-drop upload box that posts to the `/api/upload-*` endpoints.
pub fn libraryPage(ctx: *Handler, _: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const rows = try collectRows(ctx.allocator, ctx.project_dir);

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    try library_template.Library.render(.{rows}, &aw.writer);
    res.body = aw.written();
    res.content_type = .HTML;
}

/// POST /api/cse-fetch — body `{part_number, manufacturer?}`. Fetches the
/// part's footprint (ECAD model → library entries) and datasheet from
/// Component Search Engine in one shot by proxying the MCP `download_footprint`
/// and `download_datasheet` tools (which read CSE_CONNECT_SID from env/.env).
/// Returns `{"footprint":<tool result>,"datasheet":<tool result>}`,
/// each the tool's own JSON (or null on a non-JSON internal error). The heavy
/// allocations (zip + PDF, several MB) go through a dedicated arena freed at
/// return, mirroring the `/mcp` POST handler.
pub fn cseFetchApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const mcp_tools = @import("mcp_tools.zig");
    res.content_type = .JSON;
    const body = req.body() orelse {
        res.status = 400;
        res.body = "{\"error\":\"missing body\"}";
        return;
    };

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, aa, body, .{}) catch {
        res.status = 400;
        res.body = "{\"error\":\"invalid JSON body\"}";
        return;
    };
    const args = parsed.value;

    var fp_buf: std.ArrayListUnmanaged(u8) = .empty;
    _ = mcp_tools.call(aa, ctx.project_dir, "download_footprint", args, &fp_buf);
    var ds_buf: std.ArrayListUnmanaged(u8) = .empty;
    _ = mcp_tools.call(aa, ctx.project_dir, "download_datasheet", args, &ds_buf);

    // download_footprint creates the component and download_datasheet saves the
    // PDF, but neither links them — so splice the datasheet into the new
    // component's .sexp, the same link the drag-to-card flow performs.
    const linked = linkCseDatasheet(aa, ctx.project_dir, fp_buf.items, ds_buf.items);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    const w = out.writer(aa);
    try w.writeAll("{\"footprint\":");
    try w.writeAll(if (fp_buf.items.len > 0 and fp_buf.items[0] == '{') fp_buf.items else "null");
    try w.writeAll(",\"datasheet\":");
    try w.writeAll(if (ds_buf.items.len > 0 and ds_buf.items[0] == '{') ds_buf.items else "null");
    try w.print(",\"linked\":{s}}}", .{if (linked) "true" else "false"});

    res.body = try req.arena.dupe(u8, out.items);
}

/// After a CSE fetch, splice the just-downloaded datasheet into the
/// just-created component's `.sexp` so the part and its PDF are linked the same
/// way the drag-a-PDF-onto-a-card flow does. Returns true when linked (or it was
/// already linked); false when either download failed or the result fields are
/// absent. Best-effort: a failure here never fails the fetch.
fn linkCseDatasheet(allocator: std.mem.Allocator, project_dir: []const u8, fp_json: []const u8, ds_json: []const u8) bool {
    const edit_mod = @import("edit.zig");
    const fp = jsonObj(allocator, fp_json) orelse return false;
    const ds = jsonObj(allocator, ds_json) orelse return false;
    if (!objBool(fp, "ok") or !objBool(ds, "ok")) return false;
    const comp = objStr(fp, "component") orelse return false;
    const file = objStr(ds, "file") orelse return false;
    _ = edit_mod.addComponentDatasheetCore(allocator, project_dir, comp, file) catch |err| {
        return err == error.DuplicateImport;
    };
    return true;
}

fn jsonObj(allocator: std.mem.Allocator, json: []const u8) ?std.json.ObjectMap {
    if (json.len == 0 or json[0] != '{') return null;
    const v = std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{}) catch return null;
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

fn objBool(obj: std.json.ObjectMap, key: []const u8) bool {
    const f = obj.get(key) orelse return false;
    return switch (f) {
        .bool => |b| b,
        else => false,
    };
}

fn objStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const f = obj.get(key) orelse return null;
    return switch (f) {
        .string => |s| s,
        else => null,
    };
}

/// Scan `content` for `(requirement "...")` forms and return a slice of the
/// quoted text strings (slices into `content` — no allocation per string).
fn extractRequirements(allocator: std.mem.Allocator, content: []const u8) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    const needle = "(requirement ";
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, content, pos, needle)) |idx| {
        pos = idx + needle.len;
        if (pos >= content.len or content[pos] != '"') continue;
        pos += 1; // skip opening quote
        const end = findClosingQuote(content, pos) orelse break;
        try list.append(allocator, content[pos..end]);
        pos = end + 1;
    }
    return list.toOwnedSlice(allocator);
}

/// Scan `content` for `(datasheet "...")` forms and return the quoted PDF
/// filenames (slices into `content`) paired with whether the file actually
/// exists in `lib/datasheets/`. A component may declare several, so this
/// collects every match rather than stopping at the first like `extractField`.
fn extractDatasheets(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    content: []const u8,
) ![]const LibraryRow.Datasheet {
    var list: std.ArrayListUnmanaged(LibraryRow.Datasheet) = .empty;
    const needle = "(datasheet ";
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, content, pos, needle)) |idx| {
        pos = idx + needle.len;
        if (pos >= content.len or content[pos] != '"') continue;
        pos += 1; // skip opening quote
        const end = findClosingQuote(content, pos) orelse break;
        const name = content[pos..end];
        pos = end + 1;
        try list.append(allocator, .{ .name = name, .present = datasheetExists(allocator, project_dir, name) });
    }
    return list.toOwnedSlice(allocator);
}

/// True when `lib/datasheets/<name>` exists on disk — lets the library page
/// flag a declared-but-unuploaded PDF instead of rendering a 404 link.
fn datasheetExists(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) bool {
    const path = std.fmt.allocPrint(allocator, "{s}/lib/datasheets/{s}", .{ project_dir, name }) catch return false;
    defer allocator.free(path);
    _ = infra_fs.cwd().statFile(path) catch return false;
    return true;
}

fn findClosingQuote(content: []const u8, start: usize) ?usize {
    var i = start;
    while (i < content.len) : (i += 1) {
        if (content[i] == '\\') {
            i += 1;
            continue;
        }
        if (content[i] == '"') return i;
    }
    return null;
}

/// Extract a field value from sexp content, e.g. (footprint abc) -> "abc" or (description "foo bar") -> "foo bar"
fn extractField(content: []const u8, field: []const u8) ?[]const u8 {
    // Search for (field followed by space
    var pos: usize = 0;
    while (pos < content.len) {
        const needle_start = std.mem.indexOfPos(u8, content, pos, "(") orelse return null;
        const after_paren = needle_start + 1;
        if (after_paren >= content.len) return null;
        if (std.mem.startsWith(u8, content[after_paren..], field)) {
            const after_field = after_paren + field.len;
            if (after_field < content.len and content[after_field] == ' ') {
                const val_start = after_field + 1;
                if (val_start >= content.len) return null;
                if (content[val_start] == '"') {
                    // Quoted value
                    const quote_end = std.mem.indexOfPos(u8, content, val_start + 1, "\"") orelse return null;
                    return content[val_start + 1 .. quote_end];
                } else {
                    // Unquoted value - ends at ) or space
                    var end = val_start;
                    while (end < content.len and content[end] != ')' and content[end] != ' ' and content[end] != '\n') : (end += 1) {}
                    if (end > val_start) return content[val_start..end];
                }
            }
        }
        pos = needle_start + 1;
    }
    return null;
}

test "linkCseDatasheet splices the downloaded datasheet into the component" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("lib/components");
    try tmp.dir.writeFile(.{ .sub_path = "lib/components/foo.sexp", .data = "(component \"foo\"\n  (footprint x))\n" });
    const proj = try tmp.dir.realpathAlloc(aa, ".");

    // Both downloads ok → the datasheet is spliced into the component.
    try std.testing.expect(linkCseDatasheet(aa, proj, "{\"ok\":true,\"component\":\"foo\"}", "{\"ok\":true,\"file\":\"foo.pdf\"}"));
    const after = try tmp.dir.readFileAlloc(alloc, "lib/components/foo.sexp", 1 << 20);
    defer alloc.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "(datasheet \"foo.pdf\")") != null);

    // Re-linking the same PDF is idempotent (DuplicateImport still counts as linked).
    try std.testing.expect(linkCseDatasheet(aa, proj, "{\"ok\":true,\"component\":\"foo\"}", "{\"ok\":true,\"file\":\"foo.pdf\"}"));

    // A failed footprint download links nothing.
    try std.testing.expect(!linkCseDatasheet(aa, proj, "{\"ok\":false}", "{\"ok\":true,\"file\":\"foo.pdf\"}"));
}
