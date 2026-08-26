//! The resolved board-rules half of the `/pcb-layout` page blob: the per-net
//! `(net-class …)` table and the declared `(stackup … (plane …))` net list.
//!
//! Both describe the same thing — what the DESIGN asked for, after resolution —
//! and both are read back by the client: `pcb_settings.js` renders the class
//! table, and `drc_marshal.js` feeds the geometry plus the plane list into the
//! WASM DRC engine so the browser judges a board by the same rules the server
//! does. Split out of `pcb_layout_page.zig` (at its hard file-size cap) so the
//! blob's rule serialization has one home instead of being buried in the page.

const std = @import("std");
const optimizer = @import("../placement/optimizer.zig");
const na = @import("../eval/net_analysis.zig");
const router = @import("../placement/router.zig");
const mask_relief = @import("../placement/mask_relief.zig");
const via_fence = @import("../placement/via_fence.zig");
const export_gerber = @import("../export_gerber.zig");

fn rfCorridorMm(rule: optimizer.NetRule, design: optimizer.DesignRules) f64 {
    if (!via_fence.fenceable(rule)) return rule.rf.keepout_mm;
    const fence = via_fence.resolvedGapMm(rule, design) + via_fence.resolvedFenceVia(rule, design).dia;
    return @max(rule.rf.keepout_mm, fence);
}

/// Emit `,"netclasses":[…]` — one entry per net that resolved to an authored
/// class, carrying its class identity/provenance and every resolved geometry
/// field the client needs. `keepout_mm` / `keepout_escape_mm` are load-bearing
/// for the client DRC: without them the browser's engine would report zero
/// `keepout_violation` findings on a board the server flags.
pub fn writeNetClasses(w: *std.Io.Writer, p: optimizer.Placement) std.Io.Writer.Error!void {
    try w.writeAll(",\"netclasses\":[");
    var first = true;
    for (p.nets, 0..) |net, i| {
        if (i >= p.rules.net.len) break;
        const rule = p.rules.net[i];
        if (rule.class.name.len == 0) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"net\":");
        try writeJsonStr(w, net.name);
        try w.writeAll(",\"class\":");
        try writeJsonStr(w, rule.class.name);
        try w.writeAll(",\"source\":");
        try writeJsonStr(w, rule.class.source);
        try w.print(
            ",\"width\":{d},\"power_branch_width\":{d},\"clearance\":{d},\"via_dia\":{d},\"via_drill\":{d}," ++
                "\"priority\":{d},\"diff_gap\":{d},\"band_start_hz\":{d},\"max_freq_hz\":{d}," ++
                "\"pad_neck_width\":{d},\"pad_neck_max_length\":{d},\"pad_neck_taper_length\":{d}," ++
                "\"keepout_mm\":{d},\"rf_corridor_mm\":{d},\"keepout_escape_mm\":{d},\"impedance_ohms\":{d}," ++
                "\"diff_impedance_ohms\":{d},\"impedance_layer\":{d},\"ground_gap_mm\":{d},\"ground_gap_max_mm\":{d}," ++
                "\"width_derived\":{},\"return_loss_target_db\":{d}," ++
                "\"mask_relief_mm\":{d},\"fence_reach_mm\":{d},\"fence_net\":",
            .{
                rule.width,
                rule.pad_neck.power_branch_width,
                rule.clearance,
                rule.via_dia,
                rule.via_drill,
                rule.priority,
                rule.diff_gap,
                rule.rf.electrical.band_start_hz,
                rule.rf.max_freq_hz,
                rule.pad_neck.width,
                rule.pad_neck.max_length,
                rule.pad_neck.taper_length,
                rule.rf.keepout_mm,
                rfCorridorMm(rule, p.rules.design),
                rule.rf.keepout_escape_mm,
                rule.rf.impedance.ohms,
                rule.rf.impedance.diff_ohms,
                rule.rf.impedance.layer,
                rule.rf.impedance.ground_gap_mm,
                rule.rf.impedance.ground_gap_max_mm,
                rule.rf.impedance.width_derived,
                rule.rf.electrical.return_loss_target_db,
                // The CONCRETE mask policy the Gerber applies — resolved here so
                // the assembly view never re-derives (and never disagrees).
                mask_relief.reliefMm(rule, p.rules.design),
                if (via_fence.fenceable(rule)) via_fence.maskUntentReachMm(rule, p.rules.design) else 0,
            },
        );
        try writeJsonStr(w, rule.rf.fence.net);
        try w.print(",\"conflict\":{s}}}", .{if (rule.class.conflict) "true" else "false"});
    }
    try w.writeByte(']');
}

/// Emit `"plane_nets":[…],` — the declared plane/pour nets, reference copper the
/// client DRC's RF keepout check must never treat as an aggressor. Writes
/// NOTHING when the design authors no `(stackup …)`: an ABSENT key is what tells
/// the engine to fall back to the ground-name predicate (`plane_nets == null`),
/// whereas an empty array would claim a stackup that pours nothing. Trailing
/// comma included, matching its neighbours in the blob.
///
/// In that no-form case it emits `"implicit_rail":"…",` INSTEAD, when the
/// implicit model planed a supply rail (`implicit_plane`): the client engine
/// needs the same plane-carried verdict the server has, and the two keys are
/// mutually exclusive by construction — exactly as `BoardRules` holds them.
pub fn writePlaneNets(w: *std.Io.Writer, p: optimizer.Placement) std.Io.Writer.Error!void {
    const planes = p.rules.plane_nets orelse {
        const rail = p.rules.planes.implicit_rail orelse return;
        try w.writeAll("\"implicit_rail\":");
        try writeJsonStr(w, rail);
        try w.writeAll(",");
        return;
    };
    try w.writeAll("\"plane_nets\":[");
    for (planes, 0..) |pn, i| {
        if (i > 0) try w.writeByte(',');
        try writeJsonStr(w, pn);
    }
    try w.writeAll("],");
}

/// Emit `"ground_names":[…],` — the ground-name token vocabulary
/// (`eval/net_analysis.ground_tokens`) the server judges a board by. The
/// viewer's RF-keepout exemption asks the same question the plane stitcher
/// does, and used to answer it with a hand-ported regex spelling all eight
/// tokens again; carrying the list means the browser cannot drift from the
/// server about what is ground.
///
/// ALWAYS emitted, unlike `writePlaneNets`: the client builds its matcher from
/// this key alone, so an absent key would silently read every ground net as an
/// ordinary signal. Trailing comma included, matching its neighbours.
pub fn writeGroundNames(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("\"ground_names\":[");
    for (na.ground_tokens, 0..) |token, i| {
        if (i > 0) try w.writeByte(',');
        try writeJsonStr(w, token);
    }
    try w.writeAll("],");
}

/// Emit the shared continuous mask-opening polygons plus their construction
/// strokes. Each opening is one closed boundary; `a` retains the
/// exact circular fillets while `p` is their bounded-sagitta fill polygon.
/// the mask-relief geometry of the shown copper (key included, as a blob
/// field), from the same `mask_relief` computation the Gerber mask writer
/// draws (exposure runs merged across joints, sub-1 mm stretches tented,
/// fence-target bands widened over the stitch row). Empty sets when nothing
/// is routed or no net is relieved, so the viewer's relief pass is a no-op
/// exactly when the Gerber's is.
pub fn writeMaskRelief(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    p: optimizer.Placement,
    routed: ?router.RouteResult,
) std.Io.Writer.Error!void {
    try w.writeAll(",\"mask_relief\":");
    const empty = "{\"openings\":[],\"strokes\":[],\"joints\":[]}";
    const r = routed orelse {
        try w.writeAll(empty);
        return writeMaskMerges(w, alloc, p);
    };
    const copper = export_gerber.physicalCopper(alloc, .{
        .tracks = r.tracks,
        .vias = r.vias,
        .arcs = r.arcs,
        .rf_paths = r.rf_port_outcomes,
    }) catch {
        try w.writeAll(empty);
        return writeMaskMerges(w, alloc, p);
    };
    const relief = mask_relief.computeRouted(alloc, p, .{
        .tracks = copper.tracks,
        .arcs = copper.arcs,
    }, copper.vias) catch {
        try w.writeAll(empty);
        return writeMaskMerges(w, alloc, p);
    };
    try w.writeAll("{\"openings\":[");
    for (relief.openings, 0..) |opening, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"l\":{d},\"p\":[", .{opening.layer});
        for (opening.poly, 0..) |point, point_index| {
            if (point_index > 0) try w.writeByte(',');
            try w.print("[{d:.4},{d:.4}]", .{ point[0], point[1] });
        }
        try w.writeAll("],\"a\":[");
        for (opening.arcs, 0..) |arc, arc_index| {
            if (arc_index > 0) try w.writeByte(',');
            try w.print("[{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4}]", .{
                arc.p1[0], arc.p1[1], arc.pm[0], arc.pm[1], arc.p2[0], arc.p2[1],
            });
        }
        try w.writeAll("]}");
    }
    try w.writeAll("],\"strokes\":[");
    for (relief.strokes, 0..) |s, i| {
        if (i > 0) try w.writeByte(',');
        try w.print(
            "{{\"x1\":{d:.3},\"y1\":{d:.3},\"x2\":{d:.3},\"y2\":{d:.3},\"l\":{d},\"w\":{d:.3},\"cu\":{d:.3},\"ts\":{},\"te\":{},\"r\":{d:.3}}}",
            .{ s.x1, s.y1, s.x2, s.y2, s.layer, s.widths.opening, s.widths.copper, s.terminal.trim_start, s.terminal.trim_end, s.terminal.radius },
        );
    }
    try w.writeAll("],\"joints\":[");
    for (relief.joints, 0..) |joint, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"x\":{d:.3},\"y\":{d:.3},\"l\":{d},\"d\":{d:.3}}}", .{ joint.x, joint.y, joint.layer, joint.dia });
    }
    try w.writeAll("]}");
    try writeMaskMerges(w, alloc, p);
}

/// Emit the automatic sub-minimum mask-web joins used by the Gerber writer.
/// The physical 2D/3D previews punch these exact strokes out of their mask, so
/// review shows the same merged apertures the fabrication package ships.
fn writeMaskMerges(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    p: optimizer.Placement,
) std.Io.Writer.Error!void {
    try w.writeAll(",\"mask_merges\":[");
    const merges = mask_relief.collectMerges(alloc, p) catch return w.writeByte(']');
    for (merges, 0..) |merge, i| {
        if (i > 0) try w.writeByte(',');
        try w.print(
            "{{\"x1\":{d:.4},\"y1\":{d:.4},\"x2\":{d:.4},\"y2\":{d:.4},\"l\":{d},\"w\":{d:.4}}}",
            .{ merge.x1, merge.y1, merge.x2, merge.y2, merge.layer, merge.width },
        );
    }
    try w.writeByte(']');
}

/// A JSON string literal with the page blob's escaping: JSON's own escapes plus
/// `<` and U+2028/U+2029, so the value is safe inside the `<script>` tag the
/// blob is embedded in.
fn writeJsonStr(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            '<' => try w.writeAll("\\u003c"),
            0xE2 => {
                if (i + 2 < s.len and s[i + 1] == 0x80 and (s[i + 2] == 0xA8 or s[i + 2] == 0xA9)) {
                    try w.writeAll(if (s[i + 2] == 0xA8) "\\u2028" else "\\u2029");
                    i += 2;
                } else try w.writeByte(c);
            },
            else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A two-net placement: one in an `rf` class declaring a keepout, one unclassed.
fn fixture(planes: ?[]const []const u8, rules: []const optimizer.NetRule) optimizer.Placement {
    return .{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &fixture_nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 0,
        .maxy = 0,
        .generated = true,
        .rules = .{ .net = rules, .plane_nets = planes },
    };
}

const fixture_nets = [_]optimizer.FlatNet{
    .{ .name = "RF_IN", .pins = &.{} },
    .{ .name = "SPI_SCK", .pins = &.{} },
};

// spec: Web Server - The PCB page blob carries both the authored keepout halo and the full RF fence corridor through the far edge of its vias
test "the net-class blob carries keepout and impedance geometry" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const rules = [_]optimizer.NetRule{
        .{ .class = .{ .name = "rf" }, .width = 0.3, .pad_neck = .{
            .width = 0.1524,
            .max_length = 0.75,
            .taper_length = 0.35,
            .power_branch_width = 0.1524,
        }, .rf = .{
            .keepout_mm = 0.5,
            .keepout_escape_mm = 1.0,
            .impedance = .{ .ohms = 50, .ground_gap_mm = 0.127, .ground_gap_max_mm = 1.75 },
        } },
        .{},
    };
    try writeNetClasses(&aw.writer, fixture(null, &rules));
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "\"keepout_mm\":0.5") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"rf_corridor_mm\":0.5") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"keepout_escape_mm\":1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"impedance_ohms\":50") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"ground_gap_mm\":0.127") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"ground_gap_max_mm\":1.75") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"pad_neck_width\":0.1524") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"pad_neck_max_length\":0.75") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"pad_neck_taper_length\":0.35") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"power_branch_width\":0.1524") != null);
    // The class IDENTITY is load-bearing for the same rule: the client waives the
    // halo between one class's own members, and cannot without this name.
    try testing.expect(std.mem.indexOf(u8, out, "\"class\":\"rf\"") != null);
    // Only the classed net is listed.
    try testing.expect(std.mem.indexOf(u8, out, "RF_IN") != null);
    try testing.expect(std.mem.indexOf(u8, out, "SPI_SCK") == null);
}

// spec: Web Server - The PCB page blob carries each net class's resolved mask relief and fence untent reach so the assembly view shows the shipped mask
test "the net-class blob resolves mask relief and fence reach" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const rules = [_]optimizer.NetRule{
        // Undeclared (mask-relief …) on a max-freq class: the blob ships the
        // CONCRETE Gerber policy — the board's mask margin — not the sentinel.
        .{ .class = .{ .name = "rf" }, .width = 0.3124, .rf = .{
            .max_freq_hz = 12e9,
            .fence = .{ .declared = true },
        } },
        .{},
    };
    try writeNetClasses(&aw.writer, fixture(null, &rules));
    const out = aw.written();
    // Fenced max-freq default: gap (0.127 + 0.1) + fence via 0.4 + margin 0.05.
    try testing.expect(std.mem.indexOf(u8, out, "\"mask_relief_mm\":0.67") != null);
    // The RF corridor reaches from the signal copper edge through the derived
    // 0.227 mm fence gap and the full 0.4 mm ground-via diameter.
    try testing.expect(std.mem.indexOf(u8, out, "\"rf_corridor_mm\":0.62") != null);
    // clearance default 0.127 + 0.1 offset margin + 0.4/2 via + 0.3 slack ≈ 0.727.
    try testing.expect(std.mem.indexOf(u8, out, "\"fence_reach_mm\":0.7") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"fence_net\":\"\"") != null);

    // An explicit (mask-relief 0) crosses as a concrete 0 — the TRACE band is
    // tented — but the class is still a fence target, so the viewer still ships
    // its fence-via untent reach: the two are independent, exactly as for a
    // declared fence with an authored tented band.
    var tw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer tw.deinit();
    const tented = [_]optimizer.NetRule{
        .{ .class = .{ .name = "rf" }, .rf = .{ .max_freq_hz = 12e9, .mask_relief_mm = 0 } },
        .{},
    };
    try writeNetClasses(&tw.writer, fixture(null, &tented));
    try testing.expect(std.mem.indexOf(u8, tw.written(), "\"mask_relief_mm\":0,") != null);
    try testing.expect(std.mem.indexOf(u8, tw.written(), "\"fence_reach_mm\":0.7") != null);
}

// spec: Web Server - The PCB page blob serves each continuous mask-relief run as one closed filleted polygon so the assembly view draws the shipped mask
test "the blob serves mask-relief geometry for the shown copper" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(arena);

    const rules = [_]optimizer.NetRule{
        .{ .class = .{ .name = "rf" }, .rf = .{ .max_freq_hz = 12e9 } },
        .{},
    };
    const tracks = [_]router.Track{
        .{ .x1 = 2, .y1 = 5, .x2 = 8, .y2 = 5, .layer = 0, .width = 0.2, .net = 0 },
    };
    const vias = [_]router.Via{.{ .x = 5, .y = 5, .dia = 0.4, .drill = 0.2, .net = 0 }};
    const routed = router.RouteResult{ .tracks = &tracks, .vias = &vias, .routed = 1, .total = 1 };
    var placement = fixture(null, &rules);
    placement.rules.design.mask.relief_corner_radius = 0.2;
    try writeMaskRelief(&aw.writer, arena, placement, routed);
    const out = aw.written();
    // The relieved RF_IN track ships as one continuous opening polygon and
    // its connected via transition as a second antipad-sized polygon. Exact
    // trace corner arcs and construction strokes remain available for
    // fence/copper logic: 0.2 + 2×0.677 mm for this fence-target class.
    try testing.expect(std.mem.indexOf(u8, out, "\"openings\":[{\"l\":0,\"p\":[") != null);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "{\"l\":0,\"p\":["));
    try testing.expect(std.mem.indexOf(u8, out, "\"a\":[[") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"w\":1.554") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"cu\":0.2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"x1\":2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"vias\"") == null);

    // RF-only saved copper has no ordinary track to serialize. The physical
    // adapter must still give the browser the wide portal collar's relief,
    // including the max endpoint width used by the Gerber/DRC consumers.
    const RfOutcome = @typeInfo(@FieldType(router.RouteResult, "rf_port_outcomes")).pointer.child;
    const RfPhysical = @FieldType(RfOutcome, "physical");
    const RfSample = @typeInfo(@FieldType(RfPhysical, "samples")).pointer.child;
    const samples = [_]RfSample{
        .{ .at = .{ 2, 5 }, .s_mm = 0, .curvature = 0, .width_mm = 0.4 },
        .{ .at = .{ 5, 5 }, .s_mm = 3, .curvature = 0, .width_mm = 0.4 },
        .{ .at = .{ 8, 5 }, .s_mm = 6, .curvature = 0, .width_mm = 0.2 },
    };
    const paths = [_]RfOutcome{.{
        .net = 0,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = samples.len, .samples = &samples, .layer = 0 },
    }};
    const sampled = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .rf_port_outcomes = &paths, .routed = 1, .total = 1 };
    var sw: std.Io.Writer.Allocating = .init(arena);
    try writeMaskRelief(&sw.writer, arena, placement, sampled);
    try testing.expect(std.mem.indexOf(u8, sw.written(), "\"cu\":0.4") != null);

    // Nothing routed ⇒ the explicit empty shape, so the viewer's relief pass
    // is a no-op exactly when the Gerber's is.
    var ew: std.Io.Writer.Allocating = .init(arena);
    try writeMaskRelief(&ew.writer, arena, fixture(null, &rules), null);
    try testing.expectEqualStrings(",\"mask_relief\":{\"openings\":[],\"strokes\":[],\"joints\":[]},\"mask_merges\":[]", ew.written());
}

// spec: Web Server - The PCB page blob names the declared plane nets, and omits the key entirely when the design declares no stackup
test "plane_nets is emitted for a declared stackup and omitted without one" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const planes = [_][]const u8{ "GND", "V_3V3" };
    try writePlaneNets(&aw.writer, fixture(&planes, &.{}));
    try testing.expectEqualStrings("\"plane_nets\":[\"GND\",\"V_3V3\"],", aw.written());

    // No `(stackup …)` form: the key is absent, which is how the client knows to
    // fall back to the ground-name predicate rather than "pours nothing".
    var none: std.Io.Writer.Allocating = .init(testing.allocator);
    defer none.deinit();
    try writePlaneNets(&none.writer, fixture(null, &.{}));
    try testing.expectEqualStrings("", none.written());

    // A stackup that declares no plane is an EMPTY array, not an absent key.
    var empty: std.Io.Writer.Allocating = .init(testing.allocator);
    defer empty.deinit();
    try writePlaneNets(&empty.writer, fixture(&.{}, &.{}));
    try testing.expectEqualStrings("\"plane_nets\":[],", empty.written());
}

// spec: Web Server - The PCB page blob always carries the ground-name token vocabulary so the browser's ground test cannot drift from the server's
test "ground_names carries the server's ground vocabulary into the blob" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeGroundNames(&aw.writer);
    // The literal the viewer's own matcher used to spell as a regex. Longest
    // token first, so the client's first-match loop cannot let `GND` shadow
    // `GNDA` — the ordering is part of the contract, not incidental.
    try testing.expectEqualStrings(
        "\"ground_names\":[\"GNDA\",\"GNDD\",\"AGND\",\"PGND\",\"DGND\",\"VSSA\",\"GND\",\"VSS\"],",
        aw.written(),
    );
}

// spec: Web Server - The PCB page blob names the implicit model's supply-rail plane so the client DRC shares the server's plane-carried verdict
test "implicit_rail crosses the blob when no stackup is declared" {
    var railed: std.Io.Writer.Allocating = .init(testing.allocator);
    defer railed.deinit();
    var p = fixture(null, &.{});
    p.rules.planes.implicit_rail = "V_3V3";
    try writePlaneNets(&railed.writer, p);
    try testing.expectEqualStrings("\"implicit_rail\":\"V_3V3\",", railed.written());

    // A DECLARED stackup owns its planes outright — the implicit field is
    // meaningless there and must never reach the client alongside them.
    var declared: std.Io.Writer.Allocating = .init(testing.allocator);
    defer declared.deinit();
    const planes = [_][]const u8{"GND"};
    var d = fixture(&planes, &.{});
    d.rules.planes.implicit_rail = "V_3V3";
    try writePlaneNets(&declared.writer, d);
    try testing.expectEqualStrings("\"plane_nets\":[\"GND\"],", declared.written());
}
