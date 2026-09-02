//! The `/library` page and its APIs: list library parts, fetch an ECAD model
//! from Component Search Engine, and upload or delete a library entry.
//! Mutations write under the project's `lib/` tree (traversal-safe); the HTML
//! rendering itself lives in the `library.zt` template.

const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const log = @import("../infra/log.zig");
const export_kicad = @import("../export_kicad.zig");
const footprint_mod = @import("../export_kicad_footprint.zig");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;
const library_template = @import("templates/library.zig");
const autocommit = @import("autocommit.zig");
const footprint_preview = @import("footprint_preview.zig");
const upload = @import("upload.zig");
const lib_limits = @import("../lib_limits.zig");
const datasheet_ref = @import("datasheet_ref.zig");

// ── Constants ─────────────────────────────────────────────────────
const sexp_ext_len: usize = ".sexp".len;
/// The `(footprint …)` field name / the `footprint` card kind — same token.
const footprint_label = "footprint";
const pin_form_len: usize = "(pin ".len;

/// A combined browser fetch may create the ECAD package, the datasheet, or
/// both. Commit whenever either mutation succeeded; two failed provider calls
/// must not create an empty/noise commit.
fn cseFetchNeedsCommit(footprint_ok: bool, datasheet_ok: bool) bool {
    return footprint_ok or datasheet_ok;
}

/// Error set for HTTP handlers and writers in this module.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error || infra_fs.Iterator.Error;

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
    /// Documents declared by the component via `(datasheet "…")`. Local PDFs
    /// link through `/datasheets/<name>`; HTTP(S) references link directly.
    datasheets: []const Datasheet = &.{},

    pub const Kind = enum { family, component, pinout, footprint };

    /// One declared datasheet. Remote HTTP(S) references are always available;
    /// `present` distinguishes uploaded and missing local PDFs.
    pub const Datasheet = struct {
        name: []const u8,
        present: bool,
        remote: bool,
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
    var buf: std.ArrayList(RowWithMtime) = .empty;
    var referenced_pinouts = std.StringHashMapUnmanaged(void).empty;
    var referenced_footprints = std.StringHashMapUnmanaged(void).empty;
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
            const base = try allocator.dupe(u8, entry.name[0 .. entry.name.len - sexp_ext_len]);
            const content = dir.readFileAlloc(allocator, entry.name, lib_limits.max_lib_file_bytes) catch continue;
            const mtime = if (dir.statFile(entry.name)) |s| s.mtime.nanoseconds else |_| 0;

            const description = extractField(content, "description");
            const footprint = extractField(content, footprint_label);
            const pinout = extractField(content, "pinout");
            const manufacturer = extractField(content, "manufacturer");
            const mpn = extractField(content, "mpn");
            const datasheets = try extractDatasheets(allocator, project_dir, content);
            const is_family = std.mem.indexOf(u8, content, "(component-family ") != null;

            if (footprint) |fp| try referenced_footprints.put(allocator, fp, {});
            if (pinout) |po| try referenced_pinouts.put(allocator, po, {});

            const has_model = if (footprint) |fp| footprintHasModel(allocator, project_dir, model_cfg, fp) else false;

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
            const lname_local = entry.name[0 .. entry.name.len - sexp_ext_len];
            if (referenced_pinouts.contains(lname_local)) continue;
            const lname = try allocator.dupe(u8, lname_local);
            const content = dir.readFileAlloc(allocator, entry.name, lib_limits.max_lib_file_bytes) catch continue;
            const mtime = if (dir.statFile(entry.name)) |s| s.mtime.nanoseconds else |_| 0;
            var pin_count: usize = 0;
            var pos: usize = 0;
            while (std.mem.indexOfPos(u8, content, pos, "(pin ")) |idx| {
                pin_count += 1;
                pos = idx + pin_form_len;
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
            const fname_local = entry.name[0 .. entry.name.len - sexp_ext_len];
            if (referenced_footprints.contains(fname_local)) continue;
            const fname = try allocator.dupe(u8, fname_local);
            const mtime = if (dir.statFile(entry.name)) |s| s.mtime.nanoseconds else |_| 0;
            const fp_has_model = footprintHasModel(allocator, project_dir, model_cfg, fname_local);
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

    var rows: std.ArrayList(LibraryRow) = .empty;
    for (buf.items) |wm| try rows.append(allocator, wm.row);
    return rows.toOwnedSlice(allocator);
}

/// True when the footprint resolves to a STEP model: the model-config map
/// names one explicitly (model ≠ null), else `lib/models/<fp>.step` (or a
/// partial-name scan) finds a file.
fn footprintHasModel(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    model_cfg: export_kicad.ModelConfigMap,
    fp: []const u8,
) bool {
    if (model_cfg.get(fp)) |c| {
        if (c.model != null) return true;
    }
    return footprint_mod.findModelFile(allocator, project_dir, fp, fp) != null;
}

/// Build the single library card for `name` — `lib/components/<name>.sexp`
/// first (the richer card: description, datasheets, manufacturer, MPN,
/// requirements), else `lib/footprints/<name>.sexp`. Returns null when
/// neither exists. All strings are allocator-owned; `content` slices stay
/// valid only as long as the allocator does (callers use an arena).
fn rowForName(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) ?LibraryRow {
    const model_cfg = export_kicad.loadModelConfig(allocator, project_dir);

    // Component / family first.
    const comp_path = std.fmt.allocPrint(allocator, "{s}/lib/components/{s}.sexp", .{ project_dir, name }) catch return null;
    if (infra_fs.cwd().readFileAlloc(allocator, comp_path, lib_limits.max_lib_file_bytes)) |content| {
        const description = extractField(content, "description");
        const footprint = extractField(content, footprint_label);
        const pinout = extractField(content, "pinout");
        const manufacturer = extractField(content, "manufacturer");
        const mpn = extractField(content, "mpn");
        const datasheets = extractDatasheets(allocator, project_dir, content) catch return null;
        const is_family = std.mem.indexOf(u8, content, "(component-family ") != null;
        return .{
            .name = name,
            .kind = if (is_family) .family else .component,
            .search_text = buildSearchText(allocator, name, description, footprint, pinout, manufacturer, mpn, datasheets) catch return null,
            .description = description,
            .footprint = footprint,
            .has_3d_model = if (footprint) |fp| footprintHasModel(allocator, project_dir, model_cfg, fp) else false,
            .pinout = pinout,
            .manufacturer = manufacturer,
            .mpn = mpn,
            .requirements = extractRequirements(allocator, content) catch return null,
            .datasheets = datasheets,
        };
    } else |_| {}

    // Standalone footprint.
    const fp_path = std.fmt.allocPrint(allocator, "{s}/lib/footprints/{s}.sexp", .{ project_dir, name }) catch return null;
    infra_fs.cwd().access(fp_path, .{}) catch return null;
    return .{
        .name = name,
        .kind = .footprint,
        .search_text = std.fmt.allocPrint(allocator, "{s} footprint", .{name}) catch return null,
        .has_3d_model = footprintHasModel(allocator, project_dir, model_cfg, name),
    };
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
    var buf: std.Io.Writer.Allocating = .init(allocator);
    const w = &buf.writer;
    try w.writeAll(base);
    if (description) |d| try w.print(" {s}", .{d});
    if (footprint) |fp| try w.print(" {s}", .{fp});
    if (pinout) |po| try w.print(" {s}", .{po});
    if (manufacturer) |m| try w.print(" {s}", .{m});
    if (mpn) |m| try w.print(" {s}", .{m});
    for (datasheets) |ds| try w.print(" {s}", .{ds.name});
    return buf.written();
}

/// GET /library — render the component-library browser: a searchable
/// listing of every symbol/family/footprint/pinout under `lib/` plus a
/// drag-drop upload box that posts to the `/api/upload-*` endpoints.
pub fn libraryPage(ctx: *Server, _: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const rows = try collectRows(ctx.allocator, ctx.project_dir);

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    try library_template.Library.render(.{rows}, &aw.writer);
    res.body = aw.written();
    res.content_type = .HTML;
}

/// GET /api/library-card/:name — render the library page's `Card` for ONE
/// entry (component preferred, else footprint) as an HTML fragment. The PCB
/// editor's sidebar footprint button embeds this card, so the datasheet
/// links, footprint editor, 3D-model drag-in and 3D alignment are reachable
/// straight from the layout.
pub fn libraryCardApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const raw_name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    // Build the row on a short-lived arena (the template only writes); the
    // response body is duped onto the request arena before it is freed.
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const name = urlDecode(aa, raw_name) catch return sendErr(res, 400, err_invalid_name);
    if (!isSafeLibName(name)) return sendErr(res, 400, err_invalid_name);
    const row = rowForName(aa, ctx.project_dir, name) orelse {
        res.status = 404;
        res.body = "not found";
        return;
    };

    var aw: std.Io.Writer.Allocating = .init(aa);
    try library_template.Card.render(.{row}, &aw.writer);
    res.body = try req.arena.dupe(u8, aw.written());
    res.content_type = .HTML;
}

/// POST /api/cse-fetch — body `{part_number, manufacturer?}`. Fetches the
/// part's footprint (ECAD model → library entries) and datasheet from
/// Component Search Engine in one shot by proxying the CLI `download_footprint`
/// and `download_datasheet` tools (footprint download reads CSE_EMAIL /
/// CSE_PASSWORD from env/.env; the datasheet path needs no CSE auth).
/// Returns `{"footprint":<tool result>,"datasheet":<tool result>}`,
/// each the tool's own JSON (or null on a non-JSON internal error). The heavy
/// allocations (zip + PDF, several MB) go through a dedicated arena freed at
/// return, mirroring the structured CLI dispatcher.
pub fn cseFetchApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
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

    // The CLI dispatcher wraps download_footprint/download_datasheet in the
    // per-mutation auto-commit seam, but this browser convenience endpoint
    // calls the shared handlers directly. Snapshot once around the combined
    // import so its component, pinout, footprint, model, source archive,
    // datasheet, and component-link edit land in one narrow commit. Existing
    // dirty work is protected by autocommit's before/after path-set diff.
    var ac_session = autocommit.begin(aa, ctx.project_dir);
    defer if (ac_session) |*s| s.deinit();

    var fp_buf: std.ArrayList(u8) = .empty;
    const fp_result = mcp_tools.call(aa, ctx.project_dir, "download_footprint", args, &fp_buf);
    var ds_buf: std.ArrayList(u8) = .empty;
    const ds_result = mcp_tools.call(aa, ctx.project_dir, "download_datasheet", args, &ds_buf);

    // download_footprint creates the component and download_datasheet saves the
    // PDF, but neither links them — so splice the datasheet into the new
    // component's .sexp, the same link the drag-to-card flow performs.
    const linked = linkCseDatasheet(aa, ctx.project_dir, fp_buf.items, ds_buf.items);

    // Browser Component Search Engine imports auto-commit exactly the library
    // files created by the combined footprint/datasheet fetch.
    if (cseFetchNeedsCommit(fp_result.ok, ds_result.ok)) autocommit.commit(ac_session, null, "cse_fetch");

    var out: std.Io.Writer.Allocating = .init(aa);
    const w = &out.writer;
    try w.writeAll("{\"footprint\":");
    try w.writeAll(if (fp_buf.items.len > 0 and fp_buf.items[0] == '{') fp_buf.items else "null");
    try w.writeAll(",\"datasheet\":");
    try w.writeAll(if (ds_buf.items.len > 0 and ds_buf.items[0] == '{') ds_buf.items else "null");
    try w.print(",\"linked\":{s}}}", .{if (linked) "true" else "false"});

    res.body = try req.arena.dupe(u8, out.written());
}

// ── 3D-model attach + library delete ───────────────────────────────

/// True when `name` is a safe single library basename — rejects path traversal
/// and separators so the model/delete endpoints can't escape `lib/` via a
/// crafted `:name`/`:kind` param, and rejects `< > " ' &` so a rejected name
/// can also never be reflected into markup. `,`, `+`, and `#` are allowed:
/// manufacturer part numbers embed these in packaging/series suffixes (e.g.
/// `74ahct1g125gm,132`, `yat-5a+`, and `lt3045edd#pbf`); none is a path
/// separator nor part of a `..` traversal. Names arrive percent-decoded, so
/// `%` is still rejected (a stray `%` is never a legitimate basename char).
///
/// This is the ONE library-basename allowlist. `library_3d`'s footprint route
/// params share it: the library already carries `+` basenames on disk
/// (`lib/models/yat-6a+.step`, `lib/components/yat-5a+.sexp`), so a second,
/// stricter copy that rejected `+` was a latent 404 on a real Mini-Circuits
/// part while buying no safety — `+` is neither a separator, nor part of
/// `..`, nor markup.
pub fn isSafeLibName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '.' or c == '-' or c == '_' or c == ',' or c == '+' or c == '#';
        if (!ok) return false;
    }
    return true;
}

/// `{"ok":false}` JSON for a `:name`/`:kind` param that fails `isSafeLibName`
/// (or can't be percent-decoded).
const err_invalid_name = "{\"ok\":false,\"error\":\"invalid name\"}";

/// Percent-decode a URL path param. httpz hands params back verbatim, so
/// `encodeURIComponent`'d reserved chars (a comma → `%2C`) arrive encoded;
/// decode before mapping the name to a file on disk.
fn urlDecode(allocator: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]u8 {
    const buf = try allocator.dupe(u8, raw);
    return std.Uri.percentDecodeInPlace(buf);
}

fn sendErr(res: *httpz.Response, status: u16, json_body: []const u8) void {
    res.status = status;
    res.content_type = .JSON;
    res.body = json_body;
}

/// POST /api/upload-model/:name — body is a raw zip (filename in `X-Filename`).
/// Pulls the first STEP out of the zip and writes it as
/// `lib/models/<footprint>.step`, so `findModelFile` resolves it for that part
/// (add-or-replace). The drop target is a component or footprint card: for a
/// component, the footprint is read from its `.sexp`; for a footprint card,
/// `:name` is itself the footprint.
pub fn uploadModelApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .JSON;
    const name_raw = req.param("name") orelse return sendErr(res, 400, "{\"ok\":false,\"error\":\"missing name\"}");
    const body = req.body() orelse return sendErr(res, 400, "{\"ok\":false,\"error\":\"missing body\"}");

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Decode so part numbers like `74ahct1g125gm,132` (sent as `%2C`) map to the
    // right file on disk, then validate the decoded name.
    const name = urlDecode(aa, name_raw) catch return sendErr(res, 400, err_invalid_name);
    if (!isSafeLibName(name)) return sendErr(res, 400, err_invalid_name);

    const filename = req.header("x-filename") orelse "model.zip";
    // Accept either a raw .step/.stp file (the body IS the model) or a .zip
    // containing one (extract it). Case-insensitive, so .STEP/.STP/.ZIP work.
    const is_raw = std.ascii.endsWithIgnoreCase(filename, ".step") or std.ascii.endsWithIgnoreCase(filename, ".stp");
    const step: []const u8 = if (is_raw)
        body
    else
        (upload.extractStepBytes(aa, body, filename) orelse
            return sendErr(res, 400, "{\"ok\":false,\"error\":\"no .step/.stp model found in the zip\"}"));

    const fp = resolveFootprintName(aa, ctx.project_dir, name);
    if (!isSafeLibName(fp)) return sendErr(res, 400, "{\"ok\":false,\"error\":\"resolved footprint name is invalid\"}");
    writeModelStep(aa, ctx.project_dir, fp, step) catch |e| {
        log.warn("upload-model {s}: {s}", .{ fp, @errorName(e) });
        return sendErr(res, 500, "{\"ok\":false,\"error\":\"failed to write model file\"}");
    };
    // Return the active transform so an already-open PCB page can register the
    // new body immediately without reloading (and losing in-progress edits).
    const cfg = export_kicad.loadModelConfig(aa, ctx.project_dir);
    const tf = cfg.get(fp);
    const offset = if (tf) |t| t.offset else [3]f64{ 0, 0, 0 };
    const rotation = if (tf) |t| t.rotation else [3]f64{ 0, 0, 0 };
    res.body = try std.fmt.allocPrint(
        req.arena,
        "{{\"ok\":true,\"footprint\":\"{s}\",\"bytes\":{d},\"offset\":[{d},{d},{d}],\"rotation\":[{d},{d},{d}]}}",
        .{ fp, step.len, offset[0], offset[1], offset[2], rotation[0], rotation[1], rotation[2] },
    );
}

/// Resolve the footprint a model should be keyed under: if
/// `lib/components/<name>.sexp` exists and declares `(footprint X)`, return X;
/// otherwise `name` is itself a footprint (the drop landed on a footprint card).
fn resolveFootprintName(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) []const u8 {
    const path = std.fmt.allocPrint(allocator, "{s}/lib/components/{s}.sexp", .{ project_dir, name }) catch return name;
    const content = infra_fs.cwd().readFileAlloc(allocator, path, lib_limits.max_lib_file_bytes) catch return name;
    return extractField(content, footprint_label) orelse name;
}

/// Write raw STEP bytes to `lib/models/<fp>.step` (creating the dir), replacing
/// any existing file of that name.
fn writeModelStep(allocator: std.mem.Allocator, project_dir: []const u8, fp: []const u8, data: []const u8) !void {
    const dir = try std.fmt.allocPrint(allocator, "{s}/lib/models", .{project_dir});
    try infra_fs.cwd().makePath(dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.step", .{ dir, fp });
    const f = try infra_fs.cwd().createFile(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(data);
}

/// POST /api/library-delete/:kind/:name — soft-delete a library entry by moving
/// `lib/<subdir>/<name>.sexp` into `lib/<subdir>/.deleted/` (recoverable, and
/// not scanned by the listing). `kind` ∈ component|family|footprint|pinout.
pub fn deleteLibraryEntryApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .JSON;
    const kind = req.param("kind") orelse return sendErr(res, 400, "{\"ok\":false,\"error\":\"missing kind\"}");
    const name = req.param("name") orelse return sendErr(res, 400, "{\"ok\":false,\"error\":\"missing name\"}");
    if (!isSafeLibName(name)) return sendErr(res, 400, err_invalid_name);
    const subdir = subdirForKind(kind) orelse return sendErr(res, 400, "{\"ok\":false,\"error\":\"invalid kind\"}");

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const src = try std.fmt.allocPrint(aa, "{s}/lib/{s}/{s}.sexp", .{ ctx.project_dir, subdir, name });
    const trash_dir = try std.fmt.allocPrint(aa, "{s}/lib/{s}/.deleted", .{ ctx.project_dir, subdir });
    infra_fs.cwd().makePath(trash_dir) catch return sendErr(res, 500, "{\"ok\":false,\"error\":\"failed to prepare trash\"}");
    const dst = try std.fmt.allocPrint(aa, "{s}/{s}.sexp", .{ trash_dir, name });
    infra_fs.cwd().rename(src, dst) catch |e| {
        if (e == error.FileNotFound) return sendErr(res, 404, "{\"ok\":false,\"error\":\"not found\"}");
        log.warn("delete {s}: {s}", .{ src, @errorName(e) });
        return sendErr(res, 500, "{\"ok\":false,\"error\":\"delete failed\"}");
    };
    res.body = "{\"ok\":true}";
}

/// Map a library card `kind` to its `lib/` subdir. Families live alongside
/// components. Unknown kinds return null (rejected as a 400).
fn subdirForKind(kind: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, kind, "component") or std.mem.eql(u8, kind, "family")) return "components";
    if (std.mem.eql(u8, kind, footprint_label)) return "footprints";
    if (std.mem.eql(u8, kind, "pinout")) return "pinouts";
    return null;
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
    var list: std.ArrayList([]const u8) = .empty;
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

/// Scan `content` for `(datasheet "...")` forms. HTTP(S) references are
/// available directly; local filenames are paired with their on-disk state.
fn extractDatasheets(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    content: []const u8,
) ![]const LibraryRow.Datasheet {
    var list: std.ArrayList(LibraryRow.Datasheet) = .empty;
    const needle = "(datasheet ";
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, content, pos, needle)) |idx| {
        pos = idx + needle.len;
        if (pos >= content.len or content[pos] != '"') continue;
        pos += 1; // skip opening quote
        const end = findClosingQuote(content, pos) orelse break;
        const name = content[pos..end];
        pos = end + 1;
        const remote = datasheet_ref.isRemote(name);
        try list.append(allocator, .{
            .name = name,
            .present = remote or datasheetExists(allocator, project_dir, name),
            .remote = remote,
        });
    }
    return list.toOwnedSlice(allocator);
}

/// True when `lib/datasheets/<name>` exists on disk — lets the library page
/// flag a declared-but-unuploaded PDF instead of rendering a 404 link.
fn datasheetExists(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) bool {
    if (!datasheet_ref.isLocal(name)) return false;
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

test "isSafeLibName allows part-number commas and + series suffixes but still rejects traversal + separators" {
    // Manufacturer packaging suffixes embed a comma (74AHC1G125GM,132).
    try std.testing.expect(isSafeLibName("74ahct1g125gm,132"));
    try std.testing.expect(isSafeLibName("plain-name_1.0"));
    // Mini-Circuits series suffixes embed a `+` (YAT-5A+).
    try std.testing.expect(isSafeLibName("yat-5a+"));
    try std.testing.expect(isSafeLibName("yat-3a+"));
    // Analog Devices part numbers use `#` for ordering codes (LT3045EDD#PBF).
    try std.testing.expect(isSafeLibName("lt3045edd#pbf"));
    // Separators / traversal / stray percent stay rejected.
    try std.testing.expect(!isSafeLibName("../etc/passwd"));
    try std.testing.expect(!isSafeLibName("a/b"));
    try std.testing.expect(!isSafeLibName("a%2Cb"));
    try std.testing.expect(!isSafeLibName(""));
}

test "browser CSE fetch auto-commits every successful mutation outcome" {
    // spec: Web Server - Browser Component Search Engine imports auto-commit the combined generated library changes
    try std.testing.expect(cseFetchNeedsCommit(true, true));
    try std.testing.expect(cseFetchNeedsCommit(true, false));
    try std.testing.expect(cseFetchNeedsCommit(false, true));
    try std.testing.expect(!cseFetchNeedsCommit(false, false));
}

test "linkCseDatasheet splices the downloaded datasheet into the component" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/components");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/foo.sexp", .data = "(component \"foo\"\n  (footprint x))\n" });
    const proj = try tmp.dir.realPathFileAlloc(std.testing.io, ".", aa);

    // Both downloads ok → the datasheet is spliced into the component.
    try std.testing.expect(linkCseDatasheet(aa, proj, "{\"ok\":true,\"component\":\"foo\"}", "{\"ok\":true,\"file\":\"foo.pdf\"}"));
    const after = try tmp.dir.readFileAlloc(std.testing.io, "lib/components/foo.sexp", alloc, .limited64(1 << 20));
    defer alloc.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "(datasheet \"foo.pdf\")") != null);

    // Re-linking the same PDF is idempotent (DuplicateImport still counts as linked).
    try std.testing.expect(linkCseDatasheet(aa, proj, "{\"ok\":true,\"component\":\"foo\"}", "{\"ok\":true,\"file\":\"foo.pdf\"}"));

    // A failed footprint download links nothing.
    try std.testing.expect(!linkCseDatasheet(aa, proj, "{\"ok\":false}", "{\"ok\":true,\"file\":\"foo.pdf\"}"));
}

// spec: Web Server - Library previews edit footprint courtyards with PCB-style controls
test "library footprint preview exposes courtyard editing controls" {
    const library_js = @embedFile("assets/library.js");
    const modal_html = @embedFile("assets/library_courtyard.html");
    try std.testing.expect(std.mem.indexOf(u8, library_js, "/api/library-courtyard/") != null);
    try std.testing.expect(std.mem.indexOf(u8, library_js, "data-cedge") != null);
    try std.testing.expect(std.mem.indexOf(u8, library_js, "Edit courtyard") != null);
    try std.testing.expect(std.mem.indexOf(u8, modal_html, "id=\"lib-court-modal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, modal_html, "value=\"offset\"") != null);
}

// spec: Web Server - The PCB editor's sidebar footprint button opens the part's library card (datasheet links, footprint editor, 3D-model drag-in and alignment) instead of only the courtyard modal
test "library card resolves a component before a footprint and carries datasheets" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/components");
    try tmp.dir.createDirPath(std.testing.io, "lib/footprints");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/components/dup.sexp",
        .data = "(component \"dup\"\n  (description \"the component card\")\n  (footprint dup-fp)\n  (manufacturer \"Acme\")\n  (datasheet \"dup.pdf\"))\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/footprints/dup.sexp", .data = "(footprint dup)\n" });
    const proj = try tmp.dir.realPathFileAlloc(std.testing.io, ".", aa);

    // A same-named footprint exists, but the component wins — its card carries
    // the datasheet + manufacturer the PCB editor needs.
    const row = rowForName(aa, proj, "dup") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(LibraryRow.Kind.component, row.kind);
    try std.testing.expectEqualStrings("dup-fp", row.footprint.?);
    try std.testing.expectEqualStrings("Acme", row.manufacturer.?);
    try std.testing.expectEqual(@as(usize, 1), row.datasheets.len);
    try std.testing.expectEqualStrings("dup.pdf", row.datasheets[0].name);
    try std.testing.expect(!row.datasheets[0].remote);

    // Footprint-only name still resolves to a footprint card.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/footprints/only-fp.sexp", .data = "(footprint only-fp)\n" });
    const fp_row = rowForName(aa, proj, "only-fp") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(LibraryRow.Kind.footprint, fp_row.kind);

    // Unknown names resolve to nothing.
    try std.testing.expect(rowForName(aa, proj, "nope") == null);
}

test "library card treats HTTP datasheets as available external links" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/components");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/components/remote.sexp",
        .data = "(component \"remote\" (datasheet \"https" ++ "://example.com/part.pdf\"))\n",
    });
    const proj = try tmp.dir.realPathFileAlloc(std.testing.io, ".", aa);

    const row = rowForName(aa, proj, "remote") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), row.datasheets.len);
    try std.testing.expect(row.datasheets[0].remote);
    try std.testing.expect(row.datasheets[0].present);

    var rendered: std.Io.Writer.Allocating = .init(aa);
    try library_template.Card.render(.{row}, &rendered.writer);
    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered.written(),
        "href=\"https" ++ "://example.com/part.pdf\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.written(), "/datasheets/https") == null);
}

// The PCB editor's sidebar footprint button opens the part's library card; this
// test covers the client wiring that fetches and shows that card.
test "pcb board js opens the library card modal from the footprint button" {
    const board_js = @embedFile("assets/pcb_board.js");
    const viewer_js = @embedFile("assets/pcb_3d_viewer.js");
    try std.testing.expect(std.mem.indexOf(u8, board_js, "openFpCard") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "/api/library-card/") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "fp-card-modal") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "fpCardAttachModel") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "PCB.models[fp]=tf") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "PCB3D.modelAdded(fp,tf)") != null);
    try std.testing.expect(std.mem.indexOf(u8, viewer_js, "modelAdded: function (fp, transform)") != null);
    try std.testing.expect(std.mem.indexOf(u8, viewer_js, "pose.userData.footprint !== p.fp") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "loadFpCardPreview") != null);
}
