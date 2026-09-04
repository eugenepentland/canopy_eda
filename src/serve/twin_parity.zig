//! Cross-surface parity tests for the `[[twin]]` registry in `guardian.toml`.
//!
//! A capability eda exposes on two or three surfaces — a `netlisp` subcommand,
//! an HTTP route, an MCP tool — is two or three implementations of one answer,
//! and nothing in the compiler can see that they are meant to agree. They share
//! no type, often no file, and each surface's own tests keep passing while the
//! answers drift apart. Guardian's `twin-parity` check names every such
//! capability and demands a test that actually compares them; this module is
//! where those comparisons live.
//!
//! Why one module rather than one test per owning file: the comparison belongs
//! to no single surface (that is the whole point), every one of them needs the
//! same fixture project on disk, and the alternative — a hand-copied fixture
//! writer in eighteen files — is exactly the duplication the drift checks
//! exist to catch.
//!
//! The shape of every test here is the same three steps: write ONE fixture
//! project, drive each surface against it in-process (the real HTTP handler
//! through `httpz.testing`, the real MCP tool through `mcp_tools.call`), and
//! assert the answers agree — byte-for-byte where the surfaces share a core and
//! add no framing, field-for-field where one of them wraps the other's bytes.

const std = @import("std");
const httpz = @import("httpz");
const serve_root = @import("../serve.zig");
const mcp_tools = @import("mcp_tools.zig");
const pcb_describe = @import("pcb_describe.zig");

const Server = serve_root.Server;
const testing = std.testing;

// ── Fixture ────────────────────────────────────────────────────────────────

/// A two-cap board with a `SIG` net and one ★ saved layout carrying a routed
/// `SIG` trace — the smallest project on which the PCB read surfaces (facts,
/// ladder, image, per-net diagnosis, match) all have something real to say.
/// Deliberately the same shape as `pcb_fence.zig`'s fence fixture, because the
/// surfaces under test are the ones that fixture already proved reachable.
fn writeTwinFixture(dir: std.Io.Dir) !void {
    try dir.createDirPath(std.testing.io, "lib/components");
    try dir.createDirPath(std.testing.io, "lib/footprints");
    try dir.createDirPath(std.testing.io, "src");
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/cap.sexp", .data =
        \\(component-family cap
        \\  (param-type capacitance)
        \\  (footprint "0402"))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/footprints/0402.sexp", .data =
        \\(footprint "0402"
        \\  (pad 1 smd roundrect (pos -0.48 0.00) (size 0.56 0.62))
        \\  (pad 2 smd roundrect (pos 0.48 0.00) (size 0.56 0.62))
        \\  (courtyard (rect -0.91 -0.46 0.91 0.46)))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "src/twinfx.sexp", .data =
        \\(design-block "Twin Fixture"
        \\  (import cap)
        \\  (board (size 20 10))
        \\  (instance "C1" (cap "10nF") (pin 1 "SIG") (pin 2 "GND"))
        \\  (instance "C2" (cap "10nF") (pin 1 "SIG") (pin 2 "GND")))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "src/twinfx.layouts.json", .data =
        \\{"default":"routed","layouts":[
        \\ {"name":"routed","kind":"manual","ts":2,"default":true,"parts":[
        \\   {"ref":"C1","x":5,"y":5,"rot":0},{"ref":"C2","x":10,"y":5,"rot":0}],
        \\  "routes":{"tracks":[
        \\   {"x1":4.52,"y1":5,"x2":4.52,"y2":3,"l":0,"w":0.2,"net":"SIG"},
        \\   {"x1":4.52,"y1":3,"x2":9.52,"y2":3,"l":0,"w":0.2,"net":"SIG"},
        \\   {"x1":9.52,"y1":3,"x2":9.52,"y2":5,"l":0,"w":0.2,"net":"SIG"}],"vias":[]}}]}
    });
}

/// The fixture project written into a fresh temp dir, as an absolute path owned
/// by `alloc`. The caller keeps `tmp` alive for the length of the test.
fn fixtureProject(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]const u8 {
    try writeTwinFixture(tmp.dir);
    return tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
}

/// One surface's answer: the bytes and, for HTTP, the status that framed them.
const Answer = struct { status: u16, body: []const u8 };

/// Drive one real HTTP handler in-process against `project` and return its
/// status and body duped onto `alloc` (httpz's own arena dies with the call).
/// `handler` is passed as `anytype` because each route's error set differs.
fn httpCall(
    alloc: std.mem.Allocator,
    project: []const u8,
    handler: anytype,
    name: []const u8,
    query: []const [2][]const u8,
    body: ?[]const u8,
) !Answer {
    var state = serve_root.ServerState{};
    var srv = Server{ .allocator = alloc, .project_dir = project, .auth_dir = project, .state = &state };
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("name", name);
    for (query) |kv| ht.query(kv[0], kv[1]);
    if (body) |b| ht.body(b);
    try handler(&srv, ht.req, ht.res);
    return .{ .status = ht.res.status, .body = try alloc.dupe(u8, ht.res.body) };
}

/// Drive one real MCP tool in-process through the same dispatcher the server
/// uses, with `args_json` parsed as the tool's arguments object.
fn mcpCall(
    alloc: std.mem.Allocator,
    project: []const u8,
    tool: []const u8,
    args_json: []const u8,
) !struct { ok: bool, body: []const u8 } {
    const args = try std.json.parseFromSliceLeaky(std.json.Value, alloc, args_json, .{});
    var out: std.ArrayList(u8) = .empty;
    const result = mcp_tools.call(alloc, project, tool, args, &out);
    return .{ .ok = result.ok, .body = out.items };
}

// ── Tests ──────────────────────────────────────────────────────────────────

// spec: Web Server - The describe_pcb_layout MCP tool and the pcb-describe endpoint share one implementation, so a no-argument read returns the same spatial-facts document on both surfaces
test "describe_pcb_layout returns the same facts document as the pcb-describe endpoint" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try fixtureProject(alloc, &tmp);

    const http = try httpCall(alloc, project, pcb_describe.pcbDescribeApi, "twinfx", &.{}, null);
    try testing.expectEqual(@as(u16, 200), http.status);
    const tool = try mcpCall(alloc, project, "describe_pcb_layout", "{\"name\":\"twinfx\"}");
    try testing.expect(tool.ok);
    try testing.expectEqualStrings(http.body, tool.body);

    // …and the shared document is the real one, not two identical failures.
    try testing.expect(std.mem.indexOf(u8, http.body, "\"progress\":") != null);
}

// spec: Web Server - The get_layout_progress MCP tool and the layout-progress endpoint share one implementation, so both report the same completion ladder
test "get_layout_progress returns the same ladder as the layout-progress endpoint" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try fixtureProject(alloc, &tmp);

    const http = try httpCall(alloc, project, pcb_describe.layoutProgressApi, "twinfx", &.{}, null);
    try testing.expectEqual(@as(u16, 200), http.status);
    const tool = try mcpCall(alloc, project, "get_layout_progress", "{\"name\":\"twinfx\"}");
    try testing.expect(tool.ok);
    try testing.expectEqualStrings(http.body, tool.body);
    try testing.expect(std.mem.indexOf(u8, http.body, "\"stages\":") != null);
}
