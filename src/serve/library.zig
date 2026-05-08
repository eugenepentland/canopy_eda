const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const export_kicad = @import("../export_kicad.zig");
const footprint_mod = @import("../export_kicad_footprint.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;
const assets_css = @import("assets_css.zig");
const footprint_preview = @import("footprint_preview.zig");

// ── Constants ─────────────────────────────────────────────────────
const SEXP_EXT_LEN: usize = ".sexp".len;
const PIN_FORM_LEN: usize = "(pin ".len;
const MAX_LIB_FILE_BYTES: usize = 256 * 1024;

/// Error set for HTTP handlers and writers in this module.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error || std.fs.Dir.Iterator.Error;

/// Scan lib/components/ for passive families and write a JSON object
/// mapping type prefixes (cap, res, ind, led) to arrays of family names.
pub fn writeFamiliesJson(w: anytype, allocator: std.mem.Allocator, project_dir: []const u8) HandlerError!void {
    const comp_dir_path = try std.fmt.allocPrint(allocator, "{s}/lib/components", .{project_dir});
    defer allocator.free(comp_dir_path);

    var dir = infra_fs.cwd().openDir(comp_dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    const prefixes = [_][]const u8{ "cap", "res", "ind", "led" };
    var lists: [4]std.ArrayListUnmanaged([]const u8) = .{ .empty, .empty, .empty, .empty };

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        const fname = entry.name;
        if (!std.mem.endsWith(u8, fname, ".sexp")) continue;
        const base = fname[0 .. fname.len - SEXP_EXT_LEN];
        for (prefixes, 0..) |pfx, pi| {
            if (std.mem.startsWith(u8, base, pfx) and base.len > pfx.len and base[pfx.len] == '-') {
                try lists[pi].append(allocator, try allocator.dupe(u8, base));
                break;
            }
        }
    }

    var first_prefix = true;
    for (prefixes, 0..) |pfx, pi| {
        if (lists[pi].items.len == 0) continue;
        if (!first_prefix) try w.writeAll(",");
        first_prefix = false;
        try w.writeAll("\"");
        try w.writeAll(pfx);
        try w.writeAll("\":[");
        std.mem.sort([]const u8, lists[pi].items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
        for (lists[pi].items, 0..) |fam, fi| {
            if (fi > 0) try w.writeAll(",");
            try w.writeAll("\"");
            try w.writeAll(fam);
            try w.writeAll("\"");
        }
        try w.writeAll("]");
    }
}

/// GET /library — render the component-library browser: a searchable
/// listing of every symbol/family/footprint/pinout under `lib/` plus a
/// drag-drop upload box that posts to the `/api/upload-*` endpoints.
pub fn libraryPage(ctx: *Handler, _: *httpz.Request, res: *httpz.Response) HandlerError!void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);

    try w.writeAll(
        \\<!DOCTYPE html><html><head><title>Component Library</title><style>
    );
    try w.writeAll(assets_css.NAVBAR_CSS);
    try w.writeAll(LIBRARY_CSS);
    try w.writeAll("</style></head><body>");
    try assets_css.writeNavbar(w, "library");
    try w.writeAll("<div class=\"lib-content\"><h1>Component Library</h1>");

    // Upload section (at top)
    try w.writeAll(LIBRARY_UPLOAD_HTML);

    try w.writeAll(
        "<input type=\"text\" class=\"search-box\" id=\"lib-search\" " ++
            "placeholder=\"Search components, footprints, pinouts...\" autofocus>",
    );
    try w.writeAll("<div class=\"count-info\" id=\"count-info\"></div>");

    // Main results table
    try w.writeAll("<table id=\"lib-table\"><thead><tr><th>Name</th><th>Type</th><th>Details</th></tr></thead><tbody>");

    // Track which pinouts/footprints are referenced by components
    var referenced_pinouts = std.StringHashMap(void).init(ctx.allocator);
    var referenced_footprints = std.StringHashMap(void).init(ctx.allocator);

    // Load model config once for 3D model checks
    const model_cfg = export_kicad.loadModelConfig(ctx.allocator, ctx.project_dir);

    // Collect all component entries
    const comp_dir_path = try std.fmt.allocPrint(ctx.allocator, "{s}/lib/components", .{ctx.project_dir});
    defer ctx.allocator.free(comp_dir_path);
    if (infra_fs.cwd().openDir(comp_dir_path, .{ .iterate = true })) |dir_val| {
        var dir = dir_val;
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".sexp")) continue;
            const base = entry.name[0 .. entry.name.len - SEXP_EXT_LEN];
            const content = dir.readFileAlloc(ctx.allocator, entry.name, MAX_LIB_FILE_BYTES) catch continue;

            // Parse fields from sexp content
            const description = extractField(content, "description");
            const footprint = extractField(content, "footprint");
            const pinout = extractField(content, "pinout");
            const manufacturer = extractField(content, "manufacturer");
            const mpn = extractField(content, "mpn");
            const is_family = std.mem.indexOf(u8, content, "(component-family ") != null;

            if (footprint) |fp| try referenced_footprints.put(fp, {});
            if (pinout) |po| try referenced_pinouts.put(po, {});

            // Write row with data attributes for search
            try w.print("<tr data-search=\"{s}", .{base});
            if (description) |d| try w.print(" {s}", .{d});
            if (footprint) |fp| try w.print(" {s}", .{fp});
            if (pinout) |po| try w.print(" {s}", .{po});
            if (manufacturer) |m| try w.print(" {s}", .{m});
            if (mpn) |m| try w.print(" {s}", .{m});
            try w.writeAll("\">");

            // Name column
            try w.print("<td>{s}</td>", .{base});

            // Type column
            if (is_family) {
                try w.writeAll("<td><span class=\"tag tag-family\">family</span></td>");
            } else {
                try w.writeAll("<td><span class=\"tag tag-component\">component</span></td>");
            }

            // Details column
            try w.writeAll("<td>");
            if (description) |d| try w.print("<span class=\"desc\">{s}</span><br>", .{d});
            if (footprint) |fp| {
                try w.print("<span class=\"meta\">footprint: </span><span class=\"tag tag-footprint\">{s}</span> ", .{fp});
                const has_model = blk: {
                    if (model_cfg.get(fp)) |c| {
                        if (c.model != null) break :blk true;
                    }
                    break :blk footprint_mod.findModelFile(ctx.allocator, ctx.project_dir, fp, fp) != null;
                };
                if (has_model) {
                    try w.writeAll("<span class=\"meta\" style=\"font-size:0.8rem;\">3D</span> ");
                }
            }
            if (pinout) |po| try w.print("<span class=\"meta\">pinout: </span><span class=\"tag tag-pinout\">{s}</span> ", .{po});
            if (manufacturer) |m| {
                try w.print("<span class=\"meta\">mfr: {s}</span> ", .{m});
            }
            if (mpn) |m| {
                try w.print("<span class=\"meta\">mpn: {s}</span>", .{m});
            }
            try w.writeAll("</td></tr>");
        }
    } else |_| {}

    // Add standalone pinouts (not referenced by any component)
    {
        const pinout_path = try std.fmt.allocPrint(ctx.allocator, "{s}/lib/pinouts", .{ctx.project_dir});
        defer ctx.allocator.free(pinout_path);
        if (infra_fs.cwd().openDir(pinout_path, .{ .iterate = true })) |dir_val| {
            var dir = dir_val;
            defer dir.close();
            var liter = dir.iterate();
            while (try liter.next()) |entry| {
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".sexp")) continue;
                const lname = entry.name[0 .. entry.name.len - SEXP_EXT_LEN];
                if (referenced_pinouts.contains(lname)) continue;
                const content = dir.readFileAlloc(ctx.allocator, entry.name, MAX_LIB_FILE_BYTES) catch continue;
                var pin_count: usize = 0;
                var pos: usize = 0;
                while (std.mem.indexOfPos(u8, content, pos, "(pin ")) |idx| {
                    pin_count += 1;
                    pos = idx + PIN_FORM_LEN;
                }
                try w.print("<tr data-search=\"{s} pinout\"><td>{s}</td>", .{ lname, lname });
                try w.writeAll("<td><span class=\"tag tag-pinout\">pinout</span></td>");
                try w.print("<td><span class=\"meta\">{d} pins</span></td></tr>", .{pin_count});
            }
        } else |_| {}
    }

    // Add standalone footprints (not referenced by any component)
    {
        const fp_path = try std.fmt.allocPrint(ctx.allocator, "{s}/lib/footprints", .{ctx.project_dir});
        defer ctx.allocator.free(fp_path);
        if (infra_fs.cwd().openDir(fp_path, .{ .iterate = true })) |dir_val| {
            var dir = dir_val;
            defer dir.close();
            var fiter = dir.iterate();
            while (try fiter.next()) |entry| {
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".sexp")) continue;
                const fname = entry.name[0 .. entry.name.len - SEXP_EXT_LEN];
                if (referenced_footprints.contains(fname)) continue;
                try w.print("<tr data-search=\"{s} footprint\"><td>{s}</td>", .{ fname, fname });
                try w.writeAll("<td><span class=\"tag tag-footprint\">footprint</span></td>");
                try w.writeAll("<td></td></tr>");
            }
        } else |_| {}
    }

    try w.writeAll("</tbody></table>");

    // Pagination controls
    try w.writeAll(
        \\<div class="pagination" id="pagination">
        \\<button id="page-prev">&larr; Prev</button>
        \\<span class="page-info" id="page-info"></span>
        \\<button id="page-next">Next &rarr;</button>
        \\</div>
    );

    // JS: search + upload
    try w.writeAll("<script>");
    try w.writeAll(LIBRARY_JS);
    try w.writeAll("</script>");

    try w.writeAll("</div></body></html>");
    res.body = buf.items;
    res.content_type = .HTML;
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

const LIBRARY_CSS = @embedFile("assets/library.css");
const LIBRARY_UPLOAD_HTML = @embedFile("assets/library_upload.html");
const LIBRARY_JS = @embedFile("assets/library.js");
