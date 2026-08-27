//! Offline assembly artifact composition for fabrication releases.
//!
//! The live PCB renderer remains the single source of board geometry. This
//! module turns one already-rendered review page into a file://-safe document,
//! then embeds it in the Assembly workspace with the release identity.

const std = @import("std");
const httpz = @import("httpz");
const assembly_debug = @import("assembly_debug.zig");
const env_mod = @import("../eval/env.zig");
const fab_preview = @import("../fab_preview.zig");

/// Stable production identity displayed by an offline Assembly artifact.
pub const ReleaseIdentity = assembly_debug.ReleaseIdentity;

/// Inputs already resolved from the same physical view as the release ZIP.
pub const RenderRequest = struct {
    board_page: []const u8,
    cam: fab_preview.Request,
    identity: ReleaseIdentity,
};

/// Clone a live request into the fixed read-only PCB-review request used by an
/// offline release. Its query storage belongs to the source request arena.
pub fn boardRequest(source: *httpz.Request, layout: []const u8) std.mem.Allocator.Error!httpz.Request {
    const query = try source.arena.create(@TypeOf(source.qs.*));
    query.* = try @TypeOf(source.qs.*).init(source.arena, 8);
    query.add("embed", "1");
    query.add("review", "1");
    query.add("drc", "0");
    query.add("gpu", "0");
    if (layout.len > 0) query.add("layout", layout);
    var request = source.*;
    request.qs = query;
    request.qs_read = true;
    request.url = @TypeOf(source.url).parse("/pcb-layout/release-assembly");
    return request;
}

fn replaceAsset(
    arena: std.mem.Allocator,
    input: []const u8,
    needle: []const u8,
    replacement: []const u8,
) (std.mem.Allocator.Error || error{AssetMissing})![]const u8 {
    const at = std.mem.indexOf(u8, input, needle) orelse return error.AssetMissing;
    const out = try arena.alloc(u8, input.len - needle.len + replacement.len);
    @memcpy(out[0..at], input[0..at]);
    @memcpy(out[at..][0..replacement.len], replacement);
    @memcpy(out[at + replacement.len ..], input[at + needle.len ..]);
    return out;
}

fn inlineScript(arena: std.mem.Allocator, bytes: []const u8) (std.mem.Allocator.Error || error{AssetMissing})![]const u8 {
    if (std.mem.indexOf(u8, bytes, "</script") != null) return error.AssetMissing;
    return std.fmt.allocPrint(arena, "<script>{s}</script>", .{bytes});
}

fn injectBoardState(
    arena: std.mem.Allocator,
    page: []const u8,
    cam_json: []const u8,
) (std.mem.Allocator.Error || std.Io.Writer.Error || error{AssetMissing})![]const u8 {
    const start = std.mem.indexOf(u8, page, "<script>const PCB=") orelse return error.AssetMissing;
    const end_rel = std.mem.indexOf(u8, page[start..], ";</script>") orelse return error.AssetMissing;
    const end = start + end_rel + 1;
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll(page[0..end]);
    try out.writer.writeAll("PCB.standalone=true;PCB.physical_review=true;PCB.cam=");
    // JSON is valid JavaScript data. Escape markup bytes so authored strings
    // cannot terminate the inline script in a release opened from disk.
    for (cam_json) |byte| switch (byte) {
        '<' => try out.writer.writeAll("\\u003c"),
        '>' => try out.writer.writeAll("\\u003e"),
        '&' => try out.writer.writeAll("\\u0026"),
        else => try out.writer.writeByte(byte),
    };
    try out.writer.writeByte(';');
    try out.writer.writeAll(page[end..]);
    return out.written();
}

fn inlineBoardAssets(
    arena: std.mem.Allocator,
    page: []const u8,
    cam_json: []const u8,
) (std.mem.Allocator.Error || std.Io.Writer.Error || error{AssetMissing})![]const u8 {
    var html = try injectBoardState(arena, page, cam_json);
    const css = try std.fmt.allocPrint(arena, "<style>{s}</style>", .{@embedFile("assets/pcb_settings.css")});
    html = try replaceAsset(arena, html, "<link rel=\"stylesheet\" href=\"/static/pcb_settings.css\">", css);
    for ([_]struct { tag: []const u8, bytes: []const u8 }{
        .{ .tag = "<script src=\"/static/footprint_svg.js\"></script>", .bytes = @embedFile("assets/footprint_svg.js") },
        .{ .tag = "<script src=\"/static/pcb_gpu.js\"></script>", .bytes = @embedFile("assets/pcb_gpu.js") },
        .{ .tag = "<script src=\"/static/pcb_board.js\"></script>", .bytes = @embedFile("assets/pcb_board.js") },
    }) |asset| html = try replaceAsset(arena, html, asset.tag, try inlineScript(arena, asset.bytes));
    return html;
}

/// Finish one immutable Assembly HTML from the exact board review and CAM
/// documents generated for the surrounding release package.
pub fn render(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    block: *const env_mod.DesignBlock,
    request: RenderRequest,
) (fab_preview.Error || error{AssetMissing})![]const u8 {
    var cam_json: std.Io.Writer.Allocating = .init(arena);
    try fab_preview.writeJson(&cam_json.writer, arena, request.cam);
    const board_html = try inlineBoardAssets(arena, request.board_page, cam_json.written());
    return assembly_debug.renderReleasePage(arena, project_dir, name, block, board_html, request.identity);
}
