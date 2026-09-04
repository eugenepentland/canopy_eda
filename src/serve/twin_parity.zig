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
const pcb_layout_page = @import("pcb_layout_page.zig");
const modules_page = @import("modules.zig");

const Server = serve_root.Server;
const testing = std.testing;

/// Whether the fixture's ★ layout ships with copper already on it. `routed`
/// gives the read surfaces something to describe; `bare` leaves the autorouter
/// something to do, which is what the two routing surfaces are compared on.
const Copper = enum { routed, bare };

// ── Fixture ────────────────────────────────────────────────────────────────

/// A two-cap board with a `SIG` net and one ★ saved layout — the smallest
/// project on which the PCB read surfaces (facts, ladder, image, per-net
/// diagnosis, match) all have something real to say. Deliberately the same
/// shape as `pcb_fence.zig`'s fence fixture, because the surfaces under test
/// are the ones that fixture already proved reachable. `lib/modules/` carries
/// one fully-defaulted module and one that needs an argument, for the
/// standalone-module surfaces.
fn writeTwinFixture(dir: std.Io.Dir, copper: Copper) !void {
    try dir.createDirPath(std.testing.io, "lib/components");
    try dir.createDirPath(std.testing.io, "lib/footprints");
    try dir.createDirPath(std.testing.io, "lib/modules");
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
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/modules/twinmod.sexp", .data =
        \\(import cap)
        \\
        \\(defmodule twinmod ((val "10nF"))
        \\  (design-block "Twin Module"
        \\    (instance "C1" (cap val) (pin 1 "MSIG") (pin 2 "MGND"))
        \\    (instance "C2" (cap val) (pin 1 "MSIG") (pin 2 "MGND"))))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/modules/twinarg.sexp", .data =
        \\(import cap)
        \\
        \\(defmodule twinarg (val)
        \\  (design-block "Twin Arg"
        \\    (instance "C1" (cap val) (pin 1 "MSIG") (pin 2 "MGND"))))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "src/twinfx.layouts.json", .data = layoutsSidecar(copper) });
}

/// The ★ layout sidecar in the requested copper state. One text per state
/// rather than a patched one, so a reader sees exactly what each test starts
/// from; the poses are identical, which is what makes the routing surfaces
/// comparable at all.
fn layoutsSidecar(copper: Copper) []const u8 {
    return switch (copper) {
        .routed =>
        \\{"default":"routed","layouts":[
        \\ {"name":"routed","kind":"manual","ts":2,"default":true,"parts":[
        \\   {"ref":"C1","x":5,"y":5,"rot":0},{"ref":"C2","x":10,"y":5,"rot":0}],
        \\  "routes":{"tracks":[
        \\   {"x1":4.52,"y1":5,"x2":4.52,"y2":3,"l":0,"w":0.2,"net":"SIG"},
        \\   {"x1":4.52,"y1":3,"x2":9.52,"y2":3,"l":0,"w":0.2,"net":"SIG"},
        \\   {"x1":9.52,"y1":3,"x2":9.52,"y2":5,"l":0,"w":0.2,"net":"SIG"}],"vias":[]}}]}
        ,
        .bare =>
        \\{"default":"routed","layouts":[
        \\ {"name":"routed","kind":"manual","ts":2,"default":true,"parts":[
        \\   {"ref":"C1","x":5,"y":5,"rot":0},{"ref":"C2","x":10,"y":5,"rot":0}]}]}
        ,
    };
}

/// The fixture project written into a fresh temp dir, as an absolute path owned
/// by `alloc`. The caller keeps `tmp` alive for the length of the test.
fn fixtureProject(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir, copper: Copper) ![]const u8 {
    try writeTwinFixture(tmp.dir, copper);
    return tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
}

/// The poses the fixture's ★ layout carries, as the `parts` array the route
/// endpoint takes in its request body — the same board the `route_pcb` tool
/// loads off disk, so the two routing surfaces route identical geometry.
const fixture_route_body =
    \\{"parts":[{"ref":"C1","x":5,"y":5,"rot":0},{"ref":"C2","x":10,"y":5,"rot":0}]}
;

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

// ── Comparing two answers ──────────────────────────────────────────────────

/// `body` parsed as a JSON object. Every surface compared here answers JSON.
fn asObject(alloc: std.mem.Allocator, body: []const u8) !std.json.ObjectMap {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{});
    return root.object;
}

/// `obj.key` as an integer, or -1 when the field is missing or not a number —
/// a value no count can take, so a silently absent field fails a comparison
/// instead of matching another absent one.
fn intField(obj: std.json.ObjectMap, key: []const u8) i64 {
    const v = obj.get(key) orelse return -1;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => -1,
    };
}

/// `obj.key`'s array length, or -1 when the field is missing or not an array.
fn arrayLen(obj: std.json.ObjectMap, key: []const u8) i64 {
    const v = obj.get(key) orelse return -1;
    return switch (v) {
        .array => |a| @intCast(a.items.len),
        else => -1,
    };
}

/// What both routing surfaces say about one route of one board. The endpoint
/// answers with the copper itself and the tool with counts over the copper it
/// persisted, so the comparable facts are the counts — plus the connectivity
/// pair, which is the answer an agent and the viewer both act on.
const RouteFacts = struct {
    routed: i64,
    total: i64,
    tracks: i64,
    vias: i64,
    drc: i64,
    unrouted: i64,
};

/// `POST /api/pcb-route/:name`'s body reduced to the shared facts: it carries
/// the copper as arrays and the DRC findings as objects.
fn httpRouteFacts(obj: std.json.ObjectMap) RouteFacts {
    return .{
        .routed = intField(obj, "routed"),
        .total = intField(obj, "total"),
        .tracks = arrayLen(obj, "tracks"),
        .vias = arrayLen(obj, "vias"),
        .drc = arrayLen(obj, "drc"),
        .unrouted = arrayLen(obj, "unrouted"),
    };
}

/// `route_pcb`'s body reduced to the same facts: it persisted the copper and
/// reports counts over it.
fn mcpRouteFacts(obj: std.json.ObjectMap) RouteFacts {
    return .{
        .routed = intField(obj, "routed"),
        .total = intField(obj, "total"),
        .tracks = intField(obj, "tracks"),
        .vias = intField(obj, "vias"),
        .drc = intField(obj, "drc"),
        .unrouted = arrayLen(obj, "unrouted"),
    };
}

/// The first instance ref-des or net name a summary reports that `html` does
/// NOT contain, else `""`. Walked in a helper so the comparison stays one
/// assertion with no branching in the test body.
fn firstUndrawn(alloc: std.mem.Allocator, summary: std.json.ObjectMap, html: []const u8) ![]const u8 {
    for (summary.get("instances").?.array.items) |inst| {
        const ref = inst.object.get("ref_des").?.string;
        if (std.mem.indexOf(u8, html, ref) == null)
            return std.fmt.allocPrint(alloc, "instance {s}", .{ref});
    }
    for (summary.get("nets").?.array.items) |net| {
        const name = net.object.get("name").?.string;
        if (std.mem.indexOf(u8, html, name) == null)
            return std.fmt.allocPrint(alloc, "net {s}", .{name});
    }
    return "";
}

// ── Tests ──────────────────────────────────────────────────────────────────

// spec: Web Server - The describe_pcb_layout MCP tool and the pcb-describe endpoint share one implementation, so a no-argument read returns the same spatial-facts document on both surfaces
test "describe_pcb_layout returns the same facts document as the pcb-describe endpoint" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try fixtureProject(alloc, &tmp, .routed);

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
    const project = try fixtureProject(alloc, &tmp, .routed);

    const http = try httpCall(alloc, project, pcb_describe.layoutProgressApi, "twinfx", &.{}, null);
    try testing.expectEqual(@as(u16, 200), http.status);
    const tool = try mcpCall(alloc, project, "get_layout_progress", "{\"name\":\"twinfx\"}");
    try testing.expect(tool.ok);
    try testing.expectEqualStrings(http.body, tool.body);
    try testing.expect(std.mem.indexOf(u8, http.body, "\"stages\":") != null);
}

// spec: Web Server - The route_pcb MCP tool and the pcb-route endpoint route the same poses to the same copper, reporting the same connectivity, track, via and DRC counts
test "route_pcb routes the same board to the same copper as the pcb-route endpoint" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try fixtureProject(alloc, &tmp, .bare);

    // The endpoint first: it persists nothing, so the tool below still starts
    // from the bare sidecar this fixture wrote.
    const http = try httpCall(alloc, project, pcb_layout_page.pcbRouteApi, "twinfx", &.{}, fixture_route_body);
    try testing.expectEqual(@as(u16, 200), http.status);

    // `effort` is pinned because the two surfaces DEFAULT it differently, and
    // that is deliberate rather than drift: the endpoint forces `one_shot` so a
    // browser tab left open across a deploy cannot start a multi-minute route
    // (`prepareRouteFromJson`'s `default_effort`), while `route_pcb` leaves
    // `route_policy.Options.effort` at `.standard` because an agent's batch
    // route wants the full authored rescue. Pinning it is what makes the two
    // runs the same experiment; what is being compared is the copper.
    const tool = try mcpCall(alloc, project, "route_pcb", "{\"name\":\"twinfx\",\"effort\":\"one_shot\"}");
    try testing.expect(tool.ok);

    const http_facts = httpRouteFacts(try asObject(alloc, http.body));
    const tool_facts = mcpRouteFacts(try asObject(alloc, tool.body));
    try testing.expectEqualDeep(http_facts, tool_facts);

    // …and the agreement is over a real route, not two identical empties.
    try testing.expect(http_facts.total > 0);
    try testing.expect(http_facts.tracks > 0);
}

// spec: Web Server - The preview_module MCP tool and the standalone module page instantiate a module the same way, so both draw the same instances and nets and both refuse a module whose parameters have no defaults
test "preview_module and the standalone module page resolve one module identically" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try fixtureProject(alloc, &tmp, .routed);

    // A fully-defaulted module: the page instantiates it through
    // `resolveModuleBlock` → `evalNamedBlock` → `instantiateStandalone`, the
    // tool through a synthesized `(sub-block …)` wrapper. Different code, one
    // `callModule` with zero arguments underneath — so the inventory must match.
    const page = try httpCall(alloc, project, modules_page.moduleViewPage, "twinmod", &.{}, null);
    try testing.expectEqual(@as(u16, 200), page.status);
    const tool = try mcpCall(alloc, project, "preview_module", "{\"module\":\"twinmod\"}");
    try testing.expect(tool.ok);
    const summary = try asObject(alloc, tool.body);
    try testing.expectEqualStrings("", try firstUndrawn(alloc, summary, page.body));
    try testing.expectEqualStrings("Twin Module", summary.get("title").?.string);
    try testing.expectEqual(@as(i64, 2), arrayLen(summary, "instances"));
    // Pinned by name, not just by agreement: both surfaces must report the
    // ref-des the module SOURCE declares. The tool used to answer C3/C4 here,
    // because it instantiated the module inside a synthesized host design whose
    // sub-block renumbering made the module's own C1/C2 "globally unique".
    try testing.expectEqualStrings("C1", summary.get("instances").?.array.items[0].object.get("ref_des").?.string);
    try testing.expectEqualStrings("C2", summary.get("instances").?.array.items[1].object.get("ref_des").?.string);

    // …and both surfaces refuse the module whose parameter has no default,
    // rather than one of them quietly rendering an under-specified board: the
    // page falls back to its source-only view and the tool reports a failure.
    const bare_page = try httpCall(alloc, project, modules_page.moduleViewPage, "twinarg", &.{}, null);
    try testing.expect(std.mem.indexOf(u8, bare_page.body, "mod-src-pre") != null);
    const bare_tool = try mcpCall(alloc, project, "preview_module", "{\"module\":\"twinarg\"}");
    try testing.expect(!bare_tool.ok);
    try testing.expect(std.mem.indexOf(u8, bare_tool.body, "\"ok\":false") != null);
}
