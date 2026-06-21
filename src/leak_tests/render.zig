//! Leak-regression tests for the HTML/JSON/PNG rendering area — the
//! prod-OOM-prone request path.
//!
//! Two allocation contracts live here, and each gets the matching idiom:
//!
//!   * OWNED-RETURN (idiom 1): `png.encodeRgb`, `raster.Canvas.toPng`, and
//!     `render_html.computeSubBlockAttachments` return an owned slice and free
//!     all of their internal scratch (the DEFLATE hash tables, the Up-filtered
//!     scanline buffer, the supersample downscale buffer, the per-sub-block
//!     hash maps). Driving them straight through `std.testing.allocator` proves
//!     the returned slice is the *only* live allocation when they return — any
//!     forgotten scratch panics the leak detector at test end. HIGHEST VALUE.
//!
//!   * ARENA-CONTRACT (idiom 2): `render_html.setupRenderCtx`,
//!     `render_json.renderSceneGraph`, and `render_pcb_png.render` are the
//!     request-path entry points that allocate-and-forget into the caller's
//!     `res.arena` (RenderCtx has no `deinit`; the PCB renderer's uppercased
//!     highlight/pin keys are never individually freed — see the source test
//!     `render with origin labels …`). Backing a `std.heap.ArenaAllocator` with
//!     `std.testing.allocator` exercises the real allocator paths, catches any
//!     crash / double-free / escape to a *different* testing-backed allocator,
//!     and documents the contract — without false-failing on the intentional
//!     allocate-and-forget.
//!
//!   * STORE-LIFECYCLE (idiom 3): `raster.Canvas` owns its RGB buffer and frees
//!     it in `deinit`; the >64-vertex `fillPoly` path heap-allocates two
//!     scratch buffers and frees them in a `defer`. Both are driven through
//!     `std.testing.allocator`.

const std = @import("std");
const env_mod = @import("../eval/env.zig");
const render_html = @import("../render_html.zig");
const membership = @import("../diagram/membership.zig");
const render_json = @import("../render_json.zig");
const render_pcb_png = @import("../render_pcb_png.zig");
const raster = @import("../raster.zig");
const png = @import("../png.zig");
const optimizer = @import("../placement/optimizer.zig");
const geometry = @import("../placement/geometry.zig");
const export_kicad = @import("../export_kicad.zig");

const Rgb = raster.Rgb;

// ── png.zig — OWNED-RETURN (idiom 1) ───────────────────────────────────────

// leak-audit: encodeRgb allocates the Up-filtered scanline buffer, the zlib
// Allocating writer, and the DEFLATE head/prev hash tables — all freed via
// `defer`/`errdefer` — and returns one owned PNG slice. testing.allocator
// catches any of that scratch left live. Odd width forces a non-aligned
// stride through the filter + LZ77 path.
test "leak: png.encodeRgb frees all scratch but the owned PNG slice" {
    const alloc = std.testing.allocator;
    const w: u32 = 7;
    const h: u32 = 5;
    const rgb = try alloc.alloc(u8, @as(usize, w) * h * 3);
    defer alloc.free(rgb);
    for (rgb, 0..) |*b, i| b.* = @truncate(i * 31);

    const bytes = try png.encodeRgb(alloc, w, h, rgb);
    defer alloc.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x89, 0x50, 0x4E, 0x47 }, bytes[0..4]);
}

// ── raster.zig — STORE-LIFECYCLE + OWNED-RETURN ────────────────────────────

// leak-audit: Canvas owns `buf` (allocated in init) and frees it in deinit;
// toPng allocates a downscale `out` buffer and frees it via `defer` before
// handing back the owned PNG. ss=2 exercises the supersample-averaging branch.
test "leak: raster.Canvas init/deinit and toPng own their buffers" {
    const alloc = std.testing.allocator;
    var cv = try raster.Canvas.init(alloc, 12, 9, 2, Rgb.hex("#0d1117"));
    defer cv.deinit();
    cv.fillRect(1, 1, 6, 6, Rgb.hex("#58a6ff"), 1.0);
    cv.disc(8, 6, 2, Rgb.hex("#ea580c"), 1.0);
    cv.text(6, 0, "U1", 6, Rgb.hex("#ffffff"), 1.0, .middle);

    const bytes = try cv.toPng(alloc);
    defer alloc.free(bytes);
    try std.testing.expect(bytes.len > 50);
}

// leak-audit: fillPoly spills to two heap scratch buffers (ip/xs) only when the
// vertex count exceeds the 64-slot stack buffer, freeing both in a `defer`. A
// 160-vertex polygon forces that branch; testing.allocator proves both spill
// allocations are released.
test "leak: raster.Canvas.fillPoly frees its >64-vertex heap scratch" {
    const alloc = std.testing.allocator;
    var cv = try raster.Canvas.init(alloc, 40, 40, 1, Rgb.hex("#000000"));
    defer cv.deinit();
    const N = 160;
    var pts: [N][2]f32 = undefined;
    for (0..N) |i| {
        const t = @as(f32, @floatFromInt(i)) / N * 2.0 * std.math.pi;
        pts[i] = .{ 20 + 15 * @cos(t), 20 + 15 * @sin(t) };
    }
    cv.fillPoly(&pts, Rgb.hex("#b08d57"), 1.0);
    // The polygon center (20,20) is well inside the disc, so its red channel
    // must have been painted away from the black background — proves the fill
    // ran (and, with the defer above, that its heap spill was reclaimed).
    try std.testing.expect(cv.buf[(20 * cv.iw + 20) * 3] > 0);
}

// ── render_pcb_png.zig — ARENA-CONTRACT (idiom 2) ──────────────────────────

// leak-audit: render() builds a canvas (freed via defer) and returns owned PNG
// bytes, but its renderCanvas/buildHighlightSets pass allocates uppercased
// highlight/pin keys into the passed allocator and never frees them (the
// documented req.arena contract). Backing an arena with testing.allocator
// exercises the full focus-mode + pad-label + spec-status path and catches any
// crash / escape without false-failing on the intentional forget.
test "leak: render_pcb_png.render runs clean under an arena (focus + labels)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pads = [_]geometry.Pad{
        .{ .number = "1", .x = -0.5, .y = 0, .w = 0.6, .h = 0.6 },
        .{ .number = "2", .x = 0.5, .y = 0, .w = 0.6, .h = 0.6 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 5, .y = 5 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 0.6, .pads = &pads, .fallback = false, .x = 9, .y = 5 },
    };
    const instances = [_]export_kicad.FlatInstance{
        .{ .ref_des = "U1", .component = "ic", .value = "", .footprint = "", .properties = &.{}, .uuid = "", .origin_key = "U1" },
        .{ .ref_des = "C1", .component = "cap", .value = "100nF", .footprint = "", .properties = &.{}, .uuid = "", .origin_key = "C_BYP1" },
    };
    const net_pins = [_]export_kicad.FlatPin{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "C1", .pin = "1" },
    };
    const nets = [_]export_kicad.FlatNet{.{ .name = "VIN", .pins = &net_pins }};
    const p = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &instances,
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 12,
        .maxy = 10,
        .generated = true,
    };
    const highlight_nets = [_][]const u8{"VIN"};
    const pin_refs = [_][]const u8{"hubs"};
    const png_bytes = try render_pcb_png.render(alloc, p, .{
        .width = 600,
        .title = "leak-test",
        .names = .both,
        .highlight_nets = &highlight_nets,
        .pin_refs = &pin_refs,
    });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x89, 0x50, 0x4E, 0x47 }, png_bytes[0..4]);
}

// ── render_html.zig ────────────────────────────────────────────────────────

// leak-audit: computeSubBlockAttachments returns an owned `[]?usize` and frees
// its internal net→sub-block / name-index / power-net hash maps before
// returning (OWNED-RETURN, idiom 1). testing.allocator panics if any of those
// maps escape. Mirrors the source test's DesignBlock construction. (Lives in
// diagram/membership since the diagram graph builders share it.)
test "leak: membership.computeSubBlockAttachments frees its scratch maps" {
    const ldo_ports = [_]env_mod.SectionPort{
        .{ .name = "V_RF_3P3", .direction = .in, .signal_type = .power, .voltage = 3.3 },
    };
    const usb_ports = [_]env_mod.SectionPort{
        .{ .name = "USB_DP", .direction = .io, .signal_type = .differential },
    };
    const sections = [_]env_mod.Section{
        .{ .name = "TPS7A2018 1.8 V LDO", .ports = &ldo_ports },
        .{ .name = "USB", .ports = &usb_ports },
    };

    var buck_design = emptyBlock("tps63806-rail");
    var usb_design = emptyBlock("usb-c-hs");
    const sub_blocks = [_]env_mod.SubBlock{
        .{ .name = "buck33", .block = &buck_design },
        .{ .name = "usb", .block = &usb_design },
    };
    const net_ties = [_]env_mod.NetTie{
        .{ .a = "buck33/VOUT", .b = "V_RF_3P3" },
        .{ .a = "usb/DP", .b = "USB_DP" },
    };

    var block = emptyBlock("cyclops-analog");
    block.sections = &sections;
    block.sub_blocks = &sub_blocks;
    block.net_ties = &net_ties;

    const attachments = try membership.computeSubBlockAttachments(std.testing.allocator, &block);
    defer std.testing.allocator.free(attachments);
    try std.testing.expectEqual(@as(usize, 2), attachments.len);
}

// leak-audit: setupRenderCtx builds a RenderCtx that has NO deinit — every
// flattened-instance list, net index, adjacency list and per-pin map is
// allocated into the passed allocator and never individually freed (the
// req.arena contract). Backing an arena with testing.allocator runs the whole
// flatten → classify → adjacency → spoke-synthesis pipeline and catches any
// escape / crash without false-failing on the intentional forget.
test "leak: render_html.setupRenderCtx runs clean under an arena" {
    const insts = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "ic", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "R1", .component = "res", .value = "10k", .footprint = "", .symbol = "" },
        .{ .ref_des = "C1", .component = "cap", .value = "100nF", .footprint = "", .symbol = "" },
    };
    const sig_pins = [_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "R1", .pin = "1" } };
    const vdd_pins = [_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "2" }, .{ .ref_des = "R1", .pin = "2" },
        .{ .ref_des = "C1", .pin = "1" },
    };
    const gnd_pins = [_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "3" }, .{ .ref_des = "C1", .pin = "2" } };
    const nets = [_]env_mod.Net{
        .{ .name = "SIG", .pins = &sig_pins },
        .{ .name = "VDD", .pins = &vdd_pins },
        .{ .name = "GND", .pins = &gnd_pins },
    };

    var block = emptyBlock("ctx-leak-test");
    block.instances = &insts;
    block.nets = &nets;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = try render_html.setupRenderCtx(arena.allocator(), &block);
    try std.testing.expect(ctx.instances.items.len == 3);
}

// ── render_json.zig — ARENA-CONTRACT (idiom 2) ─────────────────────────────

// leak-audit: renderSceneGraph builds a RenderCtx + SceneGraph (neither
// deinit'd) and a pile of per-spoke `visited` hash maps / allocPrint keys, all
// into the passed allocator, returning an owned serialized JSON slice — the
// req.arena allocate-and-forget contract. An arena over testing.allocator runs
// the full collect → classify → serialize pipeline and catches a crash /
// escape without false-failing. project_dir is "" so no file is read (hermetic).
test "leak: render_json.renderSceneGraph runs clean under an arena" {
    const insts = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "ic", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "C1", .component = "cap", .value = "100nF", .footprint = "", .symbol = "" },
    };
    const vdd_pins = [_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const gnd_pins = [_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "2" }, .{ .ref_des = "C1", .pin = "2" } };
    const nets = [_]env_mod.Net{
        .{ .name = "VDD", .pins = &vdd_pins },
        .{ .name = "GND", .pins = &gnd_pins },
    };

    var block = emptyBlock("scene-leak-test");
    block.instances = &insts;
    block.nets = &nets;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json = try render_json.renderSceneGraph(arena.allocator(), &block, "");
    try std.testing.expect(json.len > 0);
}

/// Minimal DesignBlock with all required slices empty — mirrors
/// `render_html.emptyAttachBlock` (private), kept local so these tests stay
/// in one file.
fn emptyBlock(name: []const u8) env_mod.DesignBlock {
    return .{
        .name = name,
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
}
