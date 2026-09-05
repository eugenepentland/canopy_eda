//! Resolve a saved layout's board block far enough to judge what it may hold.
//!
//! Both surfaces that persist a snapshot need this and neither owns it: the
//! editor's save endpoint (`serve/pcb_layout_page.saveNamedLayoutApi`) and the
//! sub-circuit capture (`serve/pcb_subseeds.saveSubcircuitLayoutApi`). Each
//! writes a submitted board, and each must first know which copper layers that
//! board actually declares, because a pour naming a layer the stackup has not
//! got would persist as a zone that silently never fills.
//!
//! A save deliberately computes NOTHING else — in particular it does not score
//! what it stores. That objective is the auto-placer's own, it is not what a
//! saved board is judged by (DRC findings and routed-trace counts are, from
//! their own endpoints), and re-running it here cost 27.2 s of a 27.7 s
//! board-a autosave. Saved entries are therefore written score-less; the
//! panel renders "—", and `/api/pcb-rescore` still fills scores in on demand.
//!
//! It lives at the top level rather than under `src/serve/` because the whole
//! reason it moved out of `pcb_layout_page.zig` is that file's size ceiling,
//! and because resolving a design is not a web concern — the two handlers are
//! its callers, not its subject.

const std = @import("std");
const httpz = @import("httpz");

const infra_fs = @import("infra/fs.zig");
const paths = @import("paths.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;
const env_mod = @import("eval/env.zig");
const optimizer = @import("placement/optimizer.zig");
const modules_mod = @import("serve/modules.zig");
const page = @import("serve/pcb_layout_page.zig");
const request_log = @import("serve/request_log.zig");
const sidecar_json = @import("serve/layout_sidecar_json.zig");
const serve_root = @import("serve.zig");

const Server = serve_root.Server;

/// The layer rules of design `name` — for a `?sub` circuit, of the scoped
/// sub-block — which the save path checks a submitted pour against. Null when
/// the block does not resolve, which switches that check off rather than
/// judging a zone against a stackup nobody could read: a board that cannot be
/// evaluated is still a board the user may save.
///
/// `stages`, when supplied, closes the `resolve` phase here — the whole-design
/// re-evaluation, which FEEDBACK.md measured at ~3.5 s on board-a and which
/// every autosave pays. It is named separately from the endpoint's own work
/// because a slow evaluator and a slow endpoint are opposite fixes.
pub fn savedLayoutLayers(
    ctx: *Server,
    arena: std.mem.Allocator,
    name: []const u8,
    sub: ?[]const u8,
    stages: ?*request_log.StageTimer,
) ?optimizer.BoardRules {
    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        ctx.allocator.destroy(mr.eval);
    };
    var out: ?optimizer.BoardRules = null;
    if (page.resolveBlock(ctx.allocator, ctx.project_dir, name, &eval, &module_res)) |block| {
        // For a sub circuit the pour belongs to the scoped sub-block, so its
        // stackup rules — not the whole parent design's — are the ones to
        // judge it by; null when the slug no longer resolves.
        const rules_block: ?*env_mod.DesignBlock = if (sub) |s| blk: {
            const sb = page.descendToSub(ctx.allocator, block, s) orelse break :blk null;
            break :blk sb.block;
        } else block;
        if (rules_block) |rblk| out = sidecar_json.stackupLayerRules(arena, rblk) catch null;
    }
    // Closed whether or not the block resolved, so a design that fails to
    // evaluate still reports where its time went.
    if (stages) |t| t.lap("resolve");
    return out;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// The smallest design the save endpoint has to resolve: two capacitors on one
/// net, with the footprint and component the evaluator has to load.
fn writeSaveFixture(dir: std.Io.Dir) !void {
    try dir.createDirPath(testing.io, "lib/components");
    try dir.createDirPath(testing.io, "lib/footprints");
    try dir.createDirPath(testing.io, "src");
    try dir.writeFile(testing.io, .{ .sub_path = "lib/components/cap.sexp", .data =
        \\(component-family cap
        \\  (param-type capacitance)
        \\  (footprint "0402"))
    });
    try dir.writeFile(testing.io, .{ .sub_path = "lib/footprints/0402.sexp", .data =
        \\(footprint "0402"
        \\  (pad 1 smd roundrect (pos -0.48 0.00) (size 0.56 0.62))
        \\  (pad 2 smd roundrect (pos 0.48 0.00) (size 0.56 0.62))
        \\  (courtyard (rect -0.91 -0.46 0.91 0.46)))
    });
    try dir.writeFile(testing.io, .{ .sub_path = "src/scored.sexp", .data =
        \\(design-block "Save Fixture"
        \\  (import cap)
        \\  (board (size 20 10))
        \\  (instance "C1" (cap "10nF") (pin 1 "SIG") (pin 2 "GND"))
        \\  (instance "C2" (cap "10nF") (pin 1 "SIG") (pin 2 "GND")))
    });
}

/// The four phases `saveNamedLayoutApi` names, as they appear inside a
/// `"stages":{…}` object. `resolve` is this module's, and naming it apart from
/// the endpoint's own work is what tells a slow evaluator from a slow handler.
const save_stage_keys = [_][]const u8{
    "\"parse\":", "\"resolve\":", "\"snapshot\":", "\"write\":",
};

/// Whether `line` names every phase the save endpoint promises to report.
fn namesEverySaveStage(line: []const u8) bool {
    for (save_stage_keys) |key| {
        if (std.mem.indexOf(u8, line, key) == null) return false;
    }
    return true;
}

// spec: Web Server - The layout-save endpoint reports its design-resolve phase separately from the rest of the write, so an autosave's cost is attributable
test "the layout save endpoint names its resolve phase in the log" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    try writeSaveFixture(tmp.dir);

    var state = serve_root.ServerState{ .request_log = .{ .project_dir = project } };
    var srv = Server{ .allocator = alloc, .project_dir = project, .auth_dir = project, .state = &state };
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/api/pcb-layouts/scored");
    ht.param("name", "scored");
    ht.body(
        \\{"name":"hand","parts":[{"ref":"C1","x":5,"y":5,"rot":0},{"ref":"C2","x":10,"y":5,"rot":0}]}
    );
    paths.beginRequest();
    try page.saveNamedLayoutApi(&srv, ht.req, ht.res);
    try testing.expectEqual(@as(u16, 200), ht.res.status);
    try testing.expectEqualStrings("{\"ok\":true,\"rev\":1}", ht.res.body);

    const log_path = request_log.currentPath(&state.request_log, alloc, null).?;
    const logged = try infra_fs.cwd().readFileAlloc(alloc, log_path, 1 << 20);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, logged, "\n"));
    try testing.expect(std.mem.indexOf(u8, logged, "\"src\":\"server\",\"evt\":\"stages\"") != null);
    // The line names the request it describes, so a log holding several designs
    // still attributes each cost to one board.
    try testing.expect(std.mem.indexOf(u8, logged, "\"path\":\"/api/pcb-layouts/scored\",\"design\":\"scored\"") != null);
    try testing.expect(std.mem.indexOf(u8, logged, "\"ms_total\":") != null);
    try testing.expect(namesEverySaveStage(logged));
    // The retired objective phase must not come back under its old name.
    try testing.expect(std.mem.indexOf(u8, logged, "\"score_poses\":") == null);
}

// spec: Web Server - A saved layout is persisted without an objective score, and an identically placed auto run is left alone rather than promoted into it
test "saving a layout stores no score and promotes no auto row" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    try writeSaveFixture(tmp.dir);
    // A recorded auto run of the very arrangement the save posts. Its score used
    // to be matched against a freshly computed one and the row absorbed into the
    // named keeper; with the save score-less there is nothing to compare against,
    // so the duplicate must survive untouched rather than be promoted.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/scored.layouts.json", .data =
        \\{"layouts":[{"name":"auto 01-01 00:00","kind":"auto","ts":1,
        \\"hpwl":5,"loop":0,"caps":0,"objective":5,
        \\"parts":[{"ref":"C1","x":5,"y":5,"rot":0},{"ref":"C2","x":10,"y":5,"rot":0}]}]}
    });

    var state = serve_root.ServerState{ .request_log = .{ .project_dir = project } };
    var srv = Server{ .allocator = alloc, .project_dir = project, .auth_dir = project, .state = &state };
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/api/pcb-layouts/scored");
    ht.param("name", "scored");
    ht.body(
        \\{"name":"hand","parts":[{"ref":"C1","x":5,"y":5,"rot":0},{"ref":"C2","x":10,"y":5,"rot":0}]}
    );
    paths.beginRequest();
    try page.saveNamedLayoutApi(&srv, ht.req, ht.res);
    try testing.expectEqual(@as(u16, 200), ht.res.status);

    const saved = page.readLayouts(alloc, project, "scored");
    try testing.expectEqual(@as(usize, 2), saved.len);
    try testing.expectEqualStrings("hand", saved[0].name);
    try testing.expect(saved[0].score == null);
    // The auto row is still there, still scored — nothing was promoted away.
    try testing.expectEqualStrings("auto 01-01 00:00", saved[1].name);
    try testing.expect(saved[1].score != null);

    // And the sidecar itself carries no score keys for the saved board.
    const sidecar = try infra_fs.cwd().readFileAlloc(alloc, try std.fmt.allocPrint(alloc, "{s}/src/scored.layouts.json", .{project}), 1 << 20);
    const hand = std.mem.indexOf(u8, sidecar, "\"hand\"").?;
    const auto = std.mem.indexOf(u8, sidecar, "\"auto 01-01 00:00\"").?;
    try testing.expect(std.mem.indexOf(u8, sidecar[hand..auto], "\"objective\"") == null);
}
