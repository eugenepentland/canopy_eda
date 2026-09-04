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
const layout_match = @import("layout_match.zig");
const route_analyze_api = @import("route_analyze_api.zig");
const design_diff = @import("design_diff.zig");
const infra_fs = @import("../infra/fs.zig");
const query_cli = @import("../query.zig");
const api = @import("api.zig");
const commands = @import("../commands.zig");
const kicad_sch_export = @import("kicad_sch_export.zig");

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

/// Two snapshot directories under `history/twinfx/`, one carrying a `.note`
/// and one without — the second is the case the two history surfaces used to
/// spell differently, so a fixture that only ever had notes would prove
/// nothing.
fn writeHistoryFixture(dir: std.Io.Dir) !void {
    try dir.createDirPath(std.testing.io, "history/twinfx/20260101-000001");
    try dir.createDirPath(std.testing.io, "history/twinfx/20260102-000002");
    try dir.writeFile(std.testing.io, .{
        .sub_path = "history/twinfx/20260101-000001/.note",
        .data = "before the fence run",
    });
}

/// `<project>/src/twinfx.layouts.json` parsed — what a save surface actually
/// left on disk, read back the way the next page load would read it.
fn readSidecar(alloc: std.mem.Allocator, project: []const u8) !std.json.Value {
    const path = try std.fmt.allocPrint(alloc, "{s}/src/twinfx.layouts.json", .{project});
    const text = try infra_fs.cwd().readFileAlloc(alloc, path, 1 << 20);
    return std.json.parseFromSliceLeaky(std.json.Value, alloc, text, .{});
}

/// The saved-layout row named `want`, or a null value when the sidecar has no
/// such row (which fails the comparison rather than skipping it).
fn rowNamed(sidecar: std.json.Value, want: []const u8) std.json.Value {
    for (sidecar.object.get("layouts").?.array.items) |row| {
        const nm = row.object.get("name") orelse continue;
        if (nm == .string and std.mem.eql(u8, nm.string, want)) return row;
    }
    return .null;
}

/// The first way two saved rows' persisted GEOMETRY differs — part poses in
/// order, then copper counts — else `""`. Name, timestamp and score are
/// deliberately not compared: the two surfaces are asked to save under
/// different names, and only one of them stamps a clock.
fn firstSavedDifference(alloc: std.mem.Allocator, a: std.json.Value, b: std.json.Value) ![]const u8 {
    const pa = a.object.get("parts").?.array.items;
    const pb = b.object.get("parts").?.array.items;
    if (pa.len != pb.len)
        return std.fmt.allocPrint(alloc, "part count {d} vs {d}", .{ pa.len, pb.len });
    for (pa, pb) |x, y| {
        for ([_][]const u8{ "ref", "x", "y", "rot" }) |field| {
            const sx = try std.json.Stringify.valueAlloc(alloc, x.object.get(field) orelse std.json.Value.null, .{});
            const sy = try std.json.Stringify.valueAlloc(alloc, y.object.get(field) orelse std.json.Value.null, .{});
            if (!std.mem.eql(u8, sx, sy))
                return std.fmt.allocPrint(alloc, "part {s}: {s} vs {s}", .{ field, sx, sy });
        }
    }
    for ([_][]const u8{ "tracks", "vias" }) |field| {
        const ca = copperCount(a, field);
        const cb = copperCount(b, field);
        if (ca != cb) return std.fmt.allocPrint(alloc, "{s} {d} vs {d}", .{ field, ca, cb });
    }
    return "";
}

/// How many `routes.<field>` entries a saved row carries (-1 when it has no
/// routes object at all, so "no copper" and "empty copper" cannot match).
fn copperCount(row: std.json.Value, field: []const u8) i64 {
    const routes = row.object.get("routes") orelse return -1;
    if (routes != .object) return -1;
    return arrayLen(routes.object, field);
}

/// `name` → `title` for every row of a design listing, whatever the listing's
/// shape: the CLI answers `{"designs":[…]}` and the two server surfaces answer
/// a bare array, so the comparison is over the pairs, not the bytes.
fn designTitles(alloc: std.mem.Allocator, listing: std.json.Value) !std.StringArrayHashMapUnmanaged([]const u8) {
    var out: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    const rows = switch (listing) {
        .array => |a| a.items,
        .object => |o| o.get("designs").?.array.items,
        else => &[_]std.json.Value{},
    };
    for (rows) |row| {
        try out.put(alloc, row.object.get("name").?.string, row.object.get("title").?.string);
    }
    return out;
}

/// Every ERC violation in a JSON array, one `severity kind ref net message`
/// line each — the comparable projection of a findings list, whatever document
/// carried it. Order is preserved: two surfaces running one checker over one
/// design have no licence to report the same set in a different order.
fn ercLines(alloc: std.mem.Allocator, arr: []const std.json.Value) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    for (arr) |v| {
        try out.writer.print("{s} {s} {s} {s} {s}\n", .{
            v.object.get("severity").?.string,
            v.object.get("kind").?.string,
            strField(v.object, "ref"),
            strField(v.object, "net"),
            v.object.get("message").?.string,
        });
    }
    return out.written();
}

/// `obj.key` as a string, or `-` when absent (both writers omit an empty ref
/// or net rather than emitting `""`).
fn strField(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = obj.get(key) orelse return "-";
    return if (v == .string) v.string else "-";
}

/// The first ERC finding a report does not mention, else `""`. The CLI renders
/// a fixed-width text table rather than JSON, so it is compared by content:
/// every violation the JSON surfaces name must appear there with its kind and
/// its message.
fn firstUnreported(alloc: std.mem.Allocator, arr: []const std.json.Value, report: []const u8) ![]const u8 {
    for (arr) |v| {
        for ([_][]const u8{ "kind", "message" }) |field| {
            const text = v.object.get(field).?.string;
            if (std.mem.indexOf(u8, report, text) == null)
                return std.fmt.allocPrint(alloc, "{s} {s}", .{ field, text });
        }
    }
    return "";
}

/// The regular files directly inside `dir_path`, sorted by name — what an
/// export surface actually left on disk.
fn dirFiles(alloc: std.mem.Allocator, dir_path: []const u8) ![]const []const u8 {
    var dir = try infra_fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        try names.append(alloc, try alloc.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThanStr);
    return names.items;
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// `<dir>/<name>`, read whole.
fn fileIn(alloc: std.mem.Allocator, dir_path: []const u8, name: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path, name });
    return infra_fs.cwd().readFileAlloc(alloc, path, 4 << 20);
}

/// The first way two export directories differ — a file only one of them
/// wrote, or one whose bytes disagree — else `""`.
fn firstExportDifference(alloc: std.mem.Allocator, a_dir: []const u8, b_dir: []const u8) ![]const u8 {
    const a = try dirFiles(alloc, a_dir);
    const b = try dirFiles(alloc, b_dir);
    if (a.len != b.len)
        return std.fmt.allocPrint(alloc, "file count {d} vs {d}", .{ a.len, b.len });
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y))
            return std.fmt.allocPrint(alloc, "name {s} vs {s}", .{ x, y });
        if (!std.mem.eql(u8, try fileIn(alloc, a_dir, x), try fileIn(alloc, b_dir, y)))
            return std.fmt.allocPrint(alloc, "bytes of {s}", .{x});
    }
    return "";
}

/// The first exported file whose name or bytes are missing from `zip`, else
/// `""`. The archive is store-only, so every file's content is in it verbatim.
fn firstMissingFromZip(alloc: std.mem.Allocator, dir_path: []const u8, zip: []const u8) ![]const u8 {
    for (try dirFiles(alloc, dir_path)) |name| {
        if (std.mem.indexOf(u8, zip, name) == null)
            return std.fmt.allocPrint(alloc, "name {s}", .{name});
        if (std.mem.indexOf(u8, zip, try fileIn(alloc, dir_path, name)) == null)
            return std.fmt.allocPrint(alloc, "bytes of {s}", .{name});
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

// spec: Web Server - The get_pcb_layout_image MCP tool and the pcb-png endpoint render one board through one renderer, so the tool's base64 payload decodes to the endpoint's exact PNG bytes
test "get_pcb_layout_image decodes to the same PNG the pcb-png endpoint serves" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try fixtureProject(alloc, &tmp, .routed);

    const http = try httpCall(alloc, project, pcb_layout_page.pcbPngApi, "twinfx", &.{}, null);
    try testing.expectEqual(@as(u16, 200), http.status);
    const tool = try mcpCall(alloc, project, "get_pcb_layout_image", "{\"name\":\"twinfx\"}");
    try testing.expect(tool.ok);

    // The tool's only framing is base64 (the CLI layer emits it as an image
    // content block); strip it and the two surfaces must be the same picture.
    const dec = std.base64.standard.Decoder;
    const raw = try alloc.alloc(u8, try dec.calcSizeForSlice(tool.body));
    try dec.decode(raw, tool.body);
    try testing.expectEqualSlices(u8, http.body, raw);
    try testing.expectEqualSlices(u8, "\x89PNG", raw[0..4]);
}

// spec: Web Server - The diagnose_net MCP tool and the pcb-route-analyze endpoint run one diagnosis, so a named net reads identically on both surfaces
test "diagnose_net returns the same per-net analysis as the pcb-route-analyze endpoint" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try fixtureProject(alloc, &tmp, .routed);

    const http = try httpCall(alloc, project, route_analyze_api.pcbRouteAnalyzeApi, "twinfx", &.{}, "{\"net\":\"SIG\"}");
    try testing.expectEqual(@as(u16, 200), http.status);
    const tool = try mcpCall(alloc, project, "diagnose_net", "{\"name\":\"twinfx\",\"net\":\"SIG\"}");
    try testing.expect(tool.ok);
    try testing.expectEqualStrings(http.body, tool.body);
    try testing.expect(std.mem.indexOf(u8, http.body, "\"net\":\"SIG\"") != null);

    // A net neither surface can find is a refusal on both, not a 200 on one of
    // them: the endpoint answers 404 and the tool flags its result an error.
    const gone = try httpCall(alloc, project, route_analyze_api.pcbRouteAnalyzeApi, "twinfx", &.{}, "{\"net\":\"NOPE\"}");
    try testing.expectEqual(@as(u16, 404), gone.status);
    const gone_tool = try mcpCall(alloc, project, "diagnose_net", "{\"name\":\"twinfx\",\"net\":\"NOPE\"}");
    try testing.expect(!gone_tool.ok);
}

// spec: Web Server - The compare_layout_to_starred MCP tool and the layout-match endpoint share one scorer, so both report the same agreement against the starred layout
test "compare_layout_to_starred returns the same score as the layout-match endpoint" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try fixtureProject(alloc, &tmp, .routed);

    const http = try httpCall(alloc, project, layout_match.layoutMatchApi, "twinfx", &.{}, null);
    try testing.expectEqual(@as(u16, 200), http.status);
    const tool = try mcpCall(alloc, project, "compare_layout_to_starred", "{\"name\":\"twinfx\"}");
    try testing.expect(tool.ok);
    try testing.expectEqualStrings(http.body, tool.body);
    try testing.expect(std.mem.indexOf(u8, http.body, "\"starred\":\"routed\"") != null);
    try testing.expect(std.mem.indexOf(u8, http.body, "\"coverage\":") != null);
}

// spec: Web Server - The list_history MCP tool and the history endpoint write one snapshot list through one serializer, so a snapshot with no note reads the same on both
test "list_history returns the same snapshot list as the history endpoint" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try fixtureProject(alloc, &tmp, .routed);
    try writeHistoryFixture(tmp.dir);

    const http = try httpCall(alloc, project, design_diff.historyApi, "twinfx", &.{}, null);
    const tool = try mcpCall(alloc, project, "list_history", "{\"name\":\"twinfx\"}");
    try testing.expect(tool.ok);
    try testing.expectEqualStrings(http.body, tool.body);

    // The field the two hand-written copies disagreed on until they were made
    // to share `history.writeSnapshotsJson`: a snapshot with no `.note` was
    // `"description":""` from the endpoint and `"description":null` from the
    // tool. Both now say null, and a snapshot WITH a note still carries it.
    try testing.expect(std.mem.indexOf(u8, http.body, "\"description\":null") != null);
    try testing.expect(std.mem.indexOf(u8, http.body, "before the fence run") != null);
}

// spec: Web Server - The save_pcb_layout MCP tool and the pcb-layouts save endpoint persist the same board, so a layout saved through either surface carries identical poses and copper
test "save_pcb_layout persists the same board as the pcb-layouts save endpoint" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try fixtureProject(alloc, &tmp, .routed);

    // The tool forks the working (★) layout under a new name; the endpoint is
    // handed the same poses and copper in its request body. Two different
    // writers, one board — what lands in the sidecar must not depend on which
    // surface asked.
    const tool = try mcpCall(alloc, project, "save_pcb_layout", "{\"name\":\"twinfx\",\"layout_name\":\"from-tool\"}");
    try testing.expect(tool.ok);
    const http = try httpCall(alloc, project, pcb_layout_page.saveNamedLayoutApi, "twinfx", &.{},
        \\{"name":"from-http","parts":[{"ref":"C1","x":5,"y":5,"rot":0},{"ref":"C2","x":10,"y":5,"rot":0}],
        \\ "routes":{"tracks":[
        \\  {"x1":4.52,"y1":5,"x2":4.52,"y2":3,"l":0,"w":0.2,"net":"SIG"},
        \\  {"x1":4.52,"y1":3,"x2":9.52,"y2":3,"l":0,"w":0.2,"net":"SIG"},
        \\  {"x1":9.52,"y1":3,"x2":9.52,"y2":5,"l":0,"w":0.2,"net":"SIG"}],"vias":[]}}
    );
    try testing.expectEqual(@as(u16, 200), http.status);

    const sidecar = try readSidecar(alloc, project);
    const from_tool = rowNamed(sidecar, "from-tool");
    const from_http = rowNamed(sidecar, "from-http");
    try testing.expectEqualStrings("", try firstSavedDifference(alloc, from_tool, from_http));
    try testing.expectEqual(@as(i64, 3), copperCount(from_tool, "tracks"));
}

// spec: Web Server - The designs CLI listing, the designs endpoint and the list_designs MCP tool name the same designs with the same titles, and all three skip a design's sidecar .sexp files
test "the three design listings agree on which designs exist and what they are called" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try fixtureProject(alloc, &tmp, .routed);
    // A sidecar .sexp beside the design: the CLI skips any stem containing a
    // dot, the summaries skip `.checks.sexp` by name. Two different rules for
    // one expectation, so the fixture has to carry the file that exercises it.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/twinfx.checks.sexp",
        .data = "(design-block \"Not A Design\")",
    });

    const cli = try designTitles(alloc, try std.json.parseFromSliceLeaky(std.json.Value, alloc, try query_cli.designsJson(alloc, project), .{}));
    const http = try httpCall(alloc, project, api.designsApi, "", &.{}, null);
    const from_http = try designTitles(alloc, try std.json.parseFromSliceLeaky(std.json.Value, alloc, http.body, .{}));
    const tool = try mcpCall(alloc, project, "list_designs", "{}");
    try testing.expect(tool.ok);
    const from_tool = try designTitles(alloc, try std.json.parseFromSliceLeaky(std.json.Value, alloc, tool.body, .{}));

    // The endpoint and the tool are hand-copied loops over one summary set, so
    // they must be byte-identical; the CLI walks src/ itself and reads titles
    // out of the source text, so it is compared pair-by-pair.
    try testing.expectEqualStrings(http.body, tool.body);
    try testing.expectEqual(from_http.count(), cli.count());
    try testing.expectEqual(@as(usize, 1), cli.count());
    try testing.expectEqualStrings("Twin Fixture", cli.get("twinfx").?);
    try testing.expectEqualStrings("Twin Fixture", from_http.get("twinfx").?);
    try testing.expectEqualStrings("Twin Fixture", from_tool.get("twinfx").?);
}

// spec: Web Server - The instances CLI subcommand and the list_instances MCP tool emit one payload at one default scope, so a flattened or top-level listing reads the same on both
test "the instances CLI and list_instances emit the same payload at the same scopes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try fixtureProject(alloc, &tmp, .routed);

    // The payload is one `pub fn`, so the two surfaces can only disagree by
    // asking it for a different scope — which is exactly what an argv default
    // and a JSON-argument default are free to do independently.
    var flat: std.Io.Writer.Allocating = .init(alloc);
    try testing.expect(try mcp_tools.listInstances(alloc, project, "twinfx", query_cli.scopeOf(&.{}), &flat.writer));
    const flat_tool = try mcpCall(alloc, project, "list_instances", "{\"name\":\"twinfx\"}");
    try testing.expect(flat_tool.ok);
    try testing.expectEqualStrings(flat.written(), flat_tool.body);

    var top: std.Io.Writer.Allocating = .init(alloc);
    try testing.expect(try mcp_tools.listInstances(alloc, project, "twinfx", query_cli.scopeOf(&.{"--top-level"}), &top.writer));
    const top_tool = try mcpCall(alloc, project, "list_instances", "{\"name\":\"twinfx\",\"flatten\":false}");
    try testing.expect(top_tool.ok);
    try testing.expectEqualStrings(top.written(), top_tool.body);

    try testing.expect(std.mem.indexOf(u8, flat.written(), "C1") != null);
}

// spec: Web Server - The check CLI subcommand, the erc endpoint and the run_checks MCP tool run one electrical-rule check over one design, so all three report the same violations in the same order
test "the three check surfaces report the same ERC violations" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try fixtureProject(alloc, &tmp, .routed);

    // A design with something WRONG with it: a one-pin net on each side of a
    // lone cap. Three surfaces agreeing on an empty finding list would prove
    // nothing about how they render a finding.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/twinerc.sexp", .data =
        \\(design-block "Twin ERC"
        \\  (import cap)
        \\  (instance "C1" (cap "10nF") (pin 1 "LONELY") (pin 2 "ALSOLONELY")))
    });

    const http = try httpCall(alloc, project, api.ercApi, "twinerc", &.{}, null);
    try testing.expectEqual(@as(u16, 200), http.status);
    const from_http = try std.json.parseFromSliceLeaky(std.json.Value, alloc, http.body, .{});

    const tool = try mcpCall(alloc, project, "run_checks", "{\"name\":\"twinerc\"}");
    try testing.expect(tool.ok);
    const from_tool = (try asObject(alloc, tool.body)).get("erc").?;

    // The endpoint and the tool serialize a violation through two hand-copied
    // writers (`erc.writeViolationsJson` and `mcp_checks.writeErcViolationJson`),
    // so this compares the rendered fields, not just the count.
    try testing.expectEqualStrings(
        try ercLines(alloc, from_http.array.items),
        try ercLines(alloc, from_tool.array.items),
    );

    // The CLI is a third implementation with a text table instead of JSON; it
    // must still name every finding the other two report.
    const cli = try commands.checkReport(alloc, &.{ "--project-dir", project, "twinerc" });
    try testing.expectEqualStrings("", try firstUnreported(alloc, from_http.array.items, cli.text));

    // …over a real finding set, so the three-way agreement is not three empties.
    try testing.expect(from_http.array.items.len > 0);
}

// spec: Web Server - The export-kicad-sch CLI subcommand, the kicad-sch endpoint and the export_kicad_sch MCP tool run one exporter, so all three produce the same sheet files byte for byte
test "the three KiCad schematic exports produce the same files" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try fixtureProject(alloc, &tmp, .routed);

    // The tool refuses an `output_dir` inside the project (it is an export, not
    // a design edit), so both writing surfaces aim at a separate tree.
    var out_tmp = testing.tmpDir(.{});
    defer out_tmp.cleanup();
    const out_root = try out_tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    const from_cli = try std.fmt.allocPrint(alloc, "{s}/cli", .{out_root});
    const from_tool = try std.fmt.allocPrint(alloc, "{s}/tool", .{out_root});

    try commands.cmdExportKicadSch(alloc, &.{ "--project-dir", project, "--output-dir", from_cli, "twinfx" });
    const args = try std.fmt.allocPrint(alloc, "{{\"name\":\"twinfx\",\"output_dir\":\"{s}\"}}", .{from_tool});
    const tool = try mcpCall(alloc, project, "export_kicad_sch", args);
    try testing.expect(tool.ok);
    try testing.expectEqualStrings("", try firstExportDifference(alloc, from_cli, from_tool));

    // The endpoint ships the same export as a store-only ZIP, so every file's
    // name and its whole content sit in the archive verbatim.
    const http = try httpCall(alloc, project, kicad_sch_export.kicadSchApi, "twinfx", &.{}, null);
    try testing.expectEqual(@as(u16, 200), http.status);
    try testing.expectEqualStrings("", try firstMissingFromZip(alloc, from_cli, http.body));
    try testing.expect((try dirFiles(alloc, from_cli)).len > 1);
}
