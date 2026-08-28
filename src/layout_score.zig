//! Score a hand- or CLI-saved layout with the optimizer's own objective.
//!
//! Both surfaces that persist a snapshot need this and neither owns it: the
//! editor's save endpoint (`serve/pcb_layout_page.saveNamedLayoutApi`) and the
//! sub-circuit capture (`serve/pcb_subseeds.saveSubcircuitLayoutApi`). It is
//! the same objective `/api/pcb-score` reports, which is what makes a saved
//! board directly comparable to the auto baseline rather than to a second,
//! privately-defined metric.
//!
//! It lives at the top level rather than under `src/serve/` because the whole
//! reason it moved out of `pcb_layout_page.zig` is that file's size ceiling,
//! and because scoring a placement is not a web concern — the two handlers are
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

/// Score `parts` as a saved layout of design `name`, and hand back the
/// block's layer rules in the same pass (the save path validates a submitted
/// pour against them). For a `?sub` circuit the score is against the scoped
/// sub-block. A resolve or score failure just leaves the entry unscored —
/// a board that cannot be evaluated is still a board the user may save.
///
/// `stages`, when supplied, closes two phases here: `score_resolve` (the
/// whole-design re-evaluation, which FEEDBACK.md measured at ~3.5 s on
/// barracuda and which every autosave pays) and `score_poses` (the objective
/// itself). Splitting them is the entire reason the sink exists — an
/// `ms_total` on the save endpoint cannot tell a slow evaluator from a slow
/// optimizer, and those are opposite fixes.
pub fn scoreSavedLayout(
    ctx: *Server,
    req: *httpz.Request,
    name: []const u8,
    sub: ?[]const u8,
    parts: []const page.PartPose,
    stages: ?*request_log.StageTimer,
) page.HandlerError!sidecar_json.SavedLayoutCheck {
    var out: sidecar_json.SavedLayoutCheck = .{};
    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        ctx.allocator.destroy(mr.eval);
    };
    const resolved = page.resolveBlock(ctx.allocator, ctx.project_dir, name, &eval, &module_res);
    // Closed whether or not the block resolved, so a design that fails to
    // evaluate still reports where its time went.
    if (stages) |t| t.lap("score_resolve");
    if (resolved) |block| {
        // For a sub circuit, score against the scoped sub-block (its parts),
        // not the whole parent design — null when the slug no longer resolves.
        const score_block: ?*env_mod.DesignBlock = if (sub) |s| blk: {
            const sb = page.descendToSub(ctx.allocator, block, s) orelse break :blk null;
            break :blk sb.block;
        } else block;
        if (score_block) |sblk| {
            out.layers = sidecar_json.stackupLayerRules(req.arena, sblk) catch null;
            const params = page.readAutoParams(ctx.allocator, ctx.project_dir, name) orelse optimizer.Params{};
            const poses = try page.refPosesFromPartPoses(req.arena, parts);
            if (optimizer.scorePoses(ctx.allocator, sblk, ctx.project_dir, poses, params)) |bd| {
                out.score = .{ .hpwl = bd.hpwl, .loop = bd.loop_raw, .caps = 0, .objective = bd.objective };
            } else |_| {}
        }
    }
    if (stages) |t| t.lap("score_poses");
    return out;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// The smallest design the save endpoint can actually score: two capacitors
/// on one net, with the footprint and component the evaluator has to resolve.
fn writeScoreFixture(dir: std.Io.Dir) !void {
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
        \\(design-block "Score Fixture"
        \\  (import cap)
        \\  (board (size 20 10))
        \\  (instance "C1" (cap "10nF") (pin 1 "SIG") (pin 2 "GND"))
        \\  (instance "C2" (cap "10nF") (pin 1 "SIG") (pin 2 "GND")))
    });
}

/// The five phases `saveNamedLayoutApi` names, as they appear inside a
/// `"stages":{…}` object. `score_resolve` and `score_poses` are this module's
/// two, and separating them is what tells a slow evaluator from a slow solver.
const save_stage_keys = [_][]const u8{
    "\"parse\":", "\"score_resolve\":", "\"score_poses\":", "\"snapshot\":", "\"write\":",
};

/// Whether `line` names every phase the save endpoint promises to report.
fn namesEverySaveStage(line: []const u8) bool {
    for (save_stage_keys) |key| {
        if (std.mem.indexOf(u8, line, key) == null) return false;
    }
    return true;
}

// spec: Web Server - The layout-save endpoint reports its design-resolve and objective phases separately, so an autosave's cost is attributable
test "the layout save endpoint separates its resolve and score phases in the log" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    try writeScoreFixture(tmp.dir);

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

    // The score really was computed — otherwise `score_resolve` would be timing
    // a failure and the phase split would prove nothing.
    const sidecar = try infra_fs.cwd().readFileAlloc(alloc, try std.fmt.allocPrint(alloc, "{s}/src/scored.layouts.json", .{project}), 1 << 20);
    try testing.expect(std.mem.indexOf(u8, sidecar, "\"objective\"") != null);
}
