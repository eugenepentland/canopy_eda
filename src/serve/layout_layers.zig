//! The LAYER semantics of a saved layout: reading its persisted layer indices
//! back against the board they are being shown on, and the optional via layer
//! span both the sidecar and `add_tracks` may carry.
//!
//! A `<design>.layouts.json` is user data with its own lifetime: the sidecar
//! stores each track's routable layer as a bare `"l"` integer, and nothing
//! stops the design's `(stackup …)` from later shrinking underneath it (or a
//! hand edit from writing a layer that never existed). The old reader clamped
//! the value into a `u8` and said nothing, so copper could sit on a layer the
//! board does not have and quietly render, route and DRC against whatever the
//! consumer happened to assume.
//!
//! The rule here is deliberate and one-way: such copper is **KEPT** — deleting
//! a user's tracks because a stackup edit narrowed the board is never the right
//! answer — and **REPORTED** twice: one `[W]` line on stderr as the layout
//! loads (`warn`), and a `track-layer-out-of-range` entry in
//! `/api/pcb-describe`'s `lint[]`, which is where an agent looks.
//!
//! A via's `"s":[from,to]` span is the other half of the same subject: it names
//! two routable indices, so it is resolved and validated by the rules the audit
//! judges tracks by. Nothing branches on a span yet — see `page.SavedVia` — it
//! round-trips so a later blind/buried-via phase needs no sidecar migration.
//!
//! Lives outside `pcb_layout_page.zig` (which is at its file-size cap) and
//! imports it only for the persisted `SavedRoutes` / `SavedVia` shapes, the
//! same leaf-module arrangement `layout_sidecar_json.zig` uses.

const std = @import("std");
const board_layers = @import("../board_layers.zig");
const log = @import("../infra/log.zig");
const optimizer = @import("../placement/optimizer.zig");
const page = @import("pcb_layout_page.zig");
const router = @import("../placement/router.zig");

/// The verdict itself — see `board_layers.LayerAudit`.
pub const Audit = board_layers.LayerAudit;

/// The shown layout's persisted copper as this request restored it, together
/// with how its persisted LAYER indices read against this board's stackup.
/// One value because they are one subject: the audit is a verdict on exactly
/// the copper `routes` carries, and a caller holding one without the other
/// could report copper whose layers it never checked.
pub const Restored = struct {
    /// The rebuilt copper, or null when `?route=1` was requested (the caller
    /// routes fresh instead) or the shown layout saved none.
    routes: ?router.RouteResult = null,
    /// Out-of-range persisted layers in that copper (`audit` below). Clean on
    /// every ordinary board; a non-clean audit is warned on stderr as the
    /// layout loads and mirrored into `/api/pcb-describe`'s `lint[]` as
    /// `track-layer-out-of-range`.
    layer_audit: board_layers.LayerAudit = .{},
};

/// Judge every persisted layer index in `sr` against `rules`' routable layers.
/// Covers tracks and RF path copper, the two persisted shapes that carry a
/// signal index (a via is a through barrel on every layer, so it has none to
/// be wrong about).
pub fn audit(sr: page.SavedRoutes, rules: optimizer.BoardRules) Audit {
    var out = Audit{ .signals = rules.signalLayerCount() };
    for (sr.tracks) |t| out.note(t.l, t.net);
    for (sr.rf_paths) |p| out.note(p.layer, p.net);
    return out;
}

/// One stderr line naming the design, the layout, the worst index and the net
/// that carried it — so an operator sees the drift without opening the describe
/// JSON. Silent on a clean audit, which is every ordinary board.
pub fn warn(a: Audit, design: []const u8, layout: []const u8) void {
    if (a.clean()) return;
    log.warn(
        "layout \"{s}\" of design \"{s}\": {d} saved track(s) name a copper layer this " ++
            "board does not have (worst l={d} on net \"{s}\"; the board has {d} routable " ++
            "layer(s)). The copper is kept as saved — widen the (stackup …) or move it.",
        .{ layout, design, a.over, a.worst, a.net, a.signals },
    );
}

/// The `lint[]` message for a non-clean audit — built here so the stderr line
/// and the describe entry can never describe different drift. Owned by `alloc`.
pub fn lintMessage(alloc: std.mem.Allocator, a: Audit) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{d} saved track(s) name copper layer l={d} (worst, on net \"{s}\") but this board " ++
            "has {d} routable layer(s); the copper is kept as saved — widen the (stackup …) " ++
            "or move those tracks onto a layer the board has",
        .{ a.over, a.worst, a.net, a.signals },
    );
}

/// The lint rule name, shared by the emitter and its test.
pub const lint_rule = "track-layer-out-of-range";

// spec: Web Server - a saved layout's track layer is validated against the board's routable layers on read, and out-of-range copper is kept and reported
test "reading a saved layout reports track layers the board does not have" {
    const tracks = [_]page.SavedTrack{
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .l = 1, .w = 0.2, .net = "GND" },
        .{ .x1 = 0, .y1 = 1, .x2 = 1, .y2 = 1, .l = 4, .w = 0.2, .net = "V_3V3" },
        .{ .x1 = 0, .y1 = 2, .x2 = 1, .y2 = 2, .l = 9, .w = 0.2, .net = "CLK" },
    };
    const saved = page.SavedRoutes{ .tracks = &tracks, .vias = &.{} };

    // An undeclared board routes only its two outer faces, so l=4 and l=9 name
    // no layer. Both are counted; the worst names the offending net.
    const a = audit(saved, .{});
    try std.testing.expectEqual(@as(u8, 2), a.signals);
    try std.testing.expectEqual(@as(usize, 2), a.over);
    try std.testing.expectEqual(@as(u8, 9), a.worst);
    try std.testing.expectEqualStrings("CLK", a.net);
    try std.testing.expect(!a.clean());

    // The copper itself is untouched: restoring keeps all three tracks on the
    // layers the file named, out-of-range included.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const restored = page.restoreRoutes(arena.allocator(), saved, &.{}).?;
    try std.testing.expectEqual(@as(usize, 3), restored.tracks.len);
    try std.testing.expectEqual(@as(u8, 9), restored.tracks[2].layer);

    // The reported message names the count, the worst index and its net.
    const msg = try lintMessage(arena.allocator(), a);
    try std.testing.expect(std.mem.indexOf(u8, msg, "2 saved track(s)") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "l=9") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"CLK\"") != null);

    // A six-layer stackup with one plane has four routable layers, so l=4 is
    // in range there and only l=9 is reported.
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    const wide = audit(saved, .{ .plane_nets = &.{"GND"}, .copper_layers = 6, .planes = .{ .declared = &planes } });
    try std.testing.expectEqual(@as(usize, 1), wide.over);
    try std.testing.expectEqual(@as(u8, 9), wide.worst);

    // Nothing is reported when every track names a layer the board has.
    const ok = page.SavedRoutes{ .tracks = tracks[0..1], .vias = &.{} };
    try std.testing.expect(audit(ok, .{}).clean());
}

/// Parse an `add_tracks` via request's optional `"span"`: a two-element array
/// of copper-layer NAMES. The OUTER optional is the parse verdict (null ⇒
/// malformed, which rejects the whole request like every other `add_tracks`
/// field); the INNER one is the absence of a span, i.e. a plain through via.
/// Names are resolved against the board separately, by `resolveSpan`.
pub fn parseSpanArg(v: ?std.json.Value) ??[2][]const u8 {
    const val = v orelse return @as(?[2][]const u8, null);
    if (val != .array or val.array.items.len != 2) return null;
    const a = val.array.items[0];
    const b = val.array.items[1];
    if (a != .string or b != .string) return null;
    return @as(?[2][]const u8, .{ a.string, b.string });
}

/// Resolve a parsed span's two layer NAMES to routable indices through THIS
/// board's stackup — the same table a track's `layer` argument resolves
/// through. Null when either name is not a routable copper layer here, which
/// the caller reports and rejects on (a span silently degraded to a through via
/// would land copper the requester did not ask for).
pub fn resolveSpan(rules: optimizer.BoardRules, names: [2][]const u8) ?[2]u8 {
    return .{
        rules.signalIndexOfName(names[0]) orelse return null,
        rules.signalIndexOfName(names[1]) orelse return null,
    };
}

// spec: Web Server - a saved via may declare its layer span, which round-trips through the sidecar and add_tracks while routing still treats every via as through
test "a via layer span round-trips through the saved layout and add_tracks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const vias = [_]page.SavedVia{
        .{ .x = 1, .y = 2, .d = 0.4, .drill = 0.2, .net = "GND" },
        .{ .x = 3, .y = 4, .d = 0.4, .drill = 0.2, .net = "CLK", .s = .{ 0, 2 } },
    };
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try page.writeSavedRoutesJson(&aw.writer, .{ .tracks = &.{}, .vias = &vias });
    const json = aw.written();
    // A through via gains no byte; the spanned one carries `[from,to]`.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, json, "\"s\":"));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"s\":[0,2]") != null);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});
    const back = page.parseSavedRoutes(alloc, parsed).?;
    try std.testing.expect(back.vias[0].s == null);
    try std.testing.expectEqual([2]u8{ 0, 2 }, back.vias[1].s.?);

    // A malformed span rejects the whole add_tracks request; a well-formed one
    // parses to its two layer NAMES and resolves against the board's stackup.
    const bad = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "[\"F.Cu\"]", .{});
    try std.testing.expect(parseSpanArg(bad) == null);
    // No span at all is a parse SUCCESS carrying "no span" — a through via.
    try std.testing.expect(parseSpanArg(null).? == null);
    const good = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "[\"F.Cu\",\"In2.Cu\"]", .{});
    const names = parseSpanArg(good).?.?;
    try std.testing.expectEqualStrings("F.Cu", names[0]);

    // In2.Cu is routable on a six-layer board whose only plane is In1, and
    // names nothing on the implicit two-signal-layer board.
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    const six = optimizer.BoardRules{ .plane_nets = &.{"GND"}, .copper_layers = 6, .planes = .{ .declared = &planes } };
    try std.testing.expectEqual([2]u8{ 0, 2 }, resolveSpan(six, names).?);
    try std.testing.expect(resolveSpan(.{}, names) == null);

    // The published CLI schema advertises the field, so a strict client may
    // send the very argument this parser accepts.
    try std.testing.expect(std.mem.indexOf(u8, @import("mcp_tools.zig").tools_list_result, "\"span\":{\"type\":\"array\"") != null);
}
