//! Regression coverage for the HTTP source and notes revision contracts.
const std = @import("std");
const httpz = @import("httpz");
const server = @import("../serve.zig");
const edit = @import("edit.zig");
const notes = @import("notes.zig");
const transaction = @import("../infra/source_transaction.zig");

// spec: Web Server - HTTP source saves reject missing or stale revisions and return the exact committed source revision
test "edit HTTP source revision rejects stale and unversioned writes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "src", .default_dir);
    const original = "(design-block \"Before\")";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/board.sexp", .data = original });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var state = server.ServerState{};
    var srv = server.Server{ .allocator = a, .project_dir = root, .auth_dir = root, .state = &state };
    for ([_][]const u8{ "{\"source\":\"(design-block \\\"After\\\")\"}", "{\"source\":\"(design-block \\\"After\\\")\",\"sourceRevision\":\"stale\"}" }) |body| {
        var request = httpz.testing.init(.{});
        defer request.deinit();
        request.param("name", "board");
        request.body(body);
        try edit.saveSourceApi(&srv, request.req, request.res);
        try std.testing.expectEqual(@as(u16, 409), request.res.status);
    }
    try std.testing.expectEqualStrings(original, try tmp.dir.readFileAlloc(std.testing.io, "src/board.sexp", a, .limited(4096)));
    var request = httpz.testing.init(.{});
    defer request.deinit();
    request.param("name", "board");
    request.json(.{ .source = "(design-block \"After\")", .sourceRevision = &transaction.revision(original) });
    try edit.saveSourceApi(&srv, request.req, request.res);
    try std.testing.expectEqual(@as(u16, 200), request.res.status);
    const response = try std.json.parseFromSliceLeaky(std.json.Value, a, request.res.body, .{});
    const committed = try tmp.dir.readFileAlloc(std.testing.io, "src/board.sexp", a, .limited(4096));
    try std.testing.expectEqualStrings(&transaction.revision(committed), response.object.get("sourceRevision").?.string);
    // The exact same browser save now carries an obsolete revision.
    request.res.status = 200;
    try edit.saveSourceApi(&srv, request.req, request.res);
    try std.testing.expectEqual(@as(u16, 409), request.res.status);
}

// spec: Web Server - Notes replacement requires the revision of the exact file read so concurrent task changes survive stale scratchpad saves
test "edit HTTP notes revision prevents lost updates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "src", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/board.sexp", .data = "(design-block \"D\")" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var state = server.ServerState{};
    var srv = server.Server{ .allocator = a, .project_dir = root, .auth_dir = root, .state = &state };
    var request = httpz.testing.init(.{});
    defer request.deinit();
    request.param("name", "board");
    request.json(.{ .text = "first edit", .revision = &transaction.revision("") });
    try notes.saveNotesApi(&srv, request.req, request.res);
    try std.testing.expectEqual(@as(u16, 200), request.res.status);
    try notes.saveNotesApi(&srv, request.req, request.res);
    try std.testing.expectEqual(@as(u16, 409), request.res.status);
    try std.testing.expectEqualStrings("first edit", try tmp.dir.readFileAlloc(std.testing.io, "src/board.notes.md", a, .limited(1024)));
}
