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

    pub const Kind = enum { family, component, pinout, footprint };
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
                    .search_text = try buildSearchText(allocator, base, description, footprint, pinout, manufacturer, mpn),
                    .description = description,
                    .footprint = footprint,
                    .has_3d_model = has_model,
                    .pinout = pinout,
                    .manufacturer = manufacturer,
                    .mpn = mpn,
                    .requirements = try extractRequirements(allocator, content),
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
            try buf.append(allocator, .{
                .mtime = mtime,
                .row = .{
                    .name = fname,
                    .kind = .footprint,
                    .search_text = try std.fmt.allocPrint(allocator, "{s} footprint", .{fname}),
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
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);
    try w.writeAll(base);
    if (description) |d| try w.print(" {s}", .{d});
    if (footprint) |fp| try w.print(" {s}", .{fp});
    if (pinout) |po| try w.print(" {s}", .{po});
    if (manufacturer) |m| try w.print(" {s}", .{m});
    if (mpn) |m| try w.print(" {s}", .{m});
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

    var out: std.ArrayListUnmanaged(u8) = .empty;
    const w = out.writer(aa);
    try w.writeAll("{\"footprint\":");
    try w.writeAll(if (fp_buf.items.len > 0 and fp_buf.items[0] == '{') fp_buf.items else "null");
    try w.writeAll(",\"datasheet\":");
    try w.writeAll(if (ds_buf.items.len > 0 and ds_buf.items[0] == '{') ds_buf.items else "null");
    try w.writeAll("}");

    res.body = try req.arena.dupe(u8, out.items);
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
