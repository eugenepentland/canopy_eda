//! Deterministic fabrication identity for a manufactured PCB.
//!
//! The digest covers the timestamp-free Gerber and Excellon geometry plus an
//! authored board part number before the generated mark is added. That
//! deliberate two-pass scheme avoids a self-referential hash: the short prefix
//! and part number can be printed on the PCB while the complete SHA-256 remains
//! available in the fabrication package.

const std = @import("std");
const export_fab = @import("export_fab.zig");
const export_gerber = @import("export_gerber.zig");
const gerber_verify = @import("gerber_verify.zig");
const font = @import("font5x7.zig");
const mask_relief = @import("placement/mask_relief.zig");
const optimizer = @import("placement/optimizer.zig");
const pour = @import("placement/pour.zig");
const subcircuit_silkscreen = @import("subcircuit_silkscreen.zig");
const testpoint_silkscreen = @import("testpoint_silkscreen.zig");

pub const Error = export_gerber.Error || gerber_verify.IntegrityError || error{NoSilkscreenSpace};

/// The compact board mark and its complete lookup digest. `text`, when the
/// placement is a complete board, and all slices are owned by the allocator
/// passed to `build`.
pub const Mark = struct {
    short_hex: [8]u8,
    digest_hex: [64]u8,
    part_number: []const u8 = "",
    /// False for reusable sub-circuits: the digest still identifies the CAM
    /// package, but no generated `ID XXXXXXXX` text is added to board silk.
    printed: bool = true,
    text: ?font.BoardText,
};

/// Return the board texts to fabricate: every user-authored label plus exactly
/// one current identity mark when `mark.printed` is true. An adopted identity
/// lives in the saved layout so the editor can move it, but it is only a
/// placement preference for `build`; carrying that stale entry into a Gerber
/// alongside `mark.text` would print both strings on top of each other. For an
/// unprinted mark, stale adopted identity text is removed and not replaced.
pub fn replaceAdoptedText(
    arena: std.mem.Allocator,
    user_texts: []const font.BoardText,
    mark: Mark,
) std.mem.Allocator.Error![]const font.BoardText {
    var authored_count: usize = 0;
    for (user_texts) |text| {
        if (!text.fabrication_id) authored_count += 1;
    }
    const result = try arena.alloc(font.BoardText, authored_count + @intFromBool(mark.text != null));
    var index: usize = 0;
    for (user_texts) |text| {
        if (text.fabrication_id) continue;
        result[index] = text;
        index += 1;
    }
    if (mark.text) |text| result[index] = text;
    return result;
}

fn hashMember(hash: *std.crypto.hash.sha2.Sha256, suffix: []const u8, bytes: []const u8) void {
    hash.update(suffix);
    hash.update(&.{0});
    hash.update(bytes);
}

/// Derive and place the fabrication identity from the exact deterministic
/// manufacturing geometry. The returned mark is not part of its own digest.
pub fn build(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: export_gerber.Copper,
    user_texts: []const font.BoardText,
    frame: export_fab.Frame,
    base_edge: ?pour.EdgeField,
) Error!Mark {
    var authored_texts: std.ArrayList(font.BoardText) = .empty;
    var preferred_id: ?font.BoardText = null;
    for (user_texts) |text| {
        if (text.fabrication_id) {
            if (preferred_id == null) preferred_id = text;
        } else try authored_texts.append(arena, text);
    }
    const identity_texts = authored_texts.items;

    // The silkscreen solve is side-independent and is what the fab-ID search
    // below needs anyway, so it is done ONCE here and threaded into both silk
    // files rather than re-solved per consumer (three full label-vs-pad sweeps
    // on a dense board — most of the cost of building the package).
    const silk = try export_gerber.planSilk(arena, placement, copper, identity_texts);
    defer subcircuit_silkscreen.deinitCollected(arena, silk.annotations);
    defer testpoint_silkscreen.deinitCollected(arena, silk.testpoint_labels);

    // Likewise the board-edge margin field: every poured layer in the package
    // (both outer pours, each inner plane, every user zone on every face) fills
    // the same outline on the same lattice, so seed it once for all of them.
    // `base_edge` is the caller's shared field when the whole render pours the
    // same board (the page render builds this package only for the fab-ID text).
    const edge = if (base_edge) |b| b else try pour.sharedEdgeField(arena, placement);

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    const layers = try export_gerber.planLayers(arena, placement);
    for (layers) |layer| {
        var bytes: std.Io.Writer.Allocating = .init(arena);
        try export_gerber.writeLayer(&bytes.writer, arena, placement, copper, identity_texts, frame, layer.layer, .{ .function = layer.function, .silk = &silk, .edge = edge });
        switch (layer.layer) {
            .copper, .plane, .inner_signal => try gerber_verify.verifyRegionIntegrity(arena, bytes.written()),
            else => {},
        }
        hashMember(&hash, layer.suffix, bytes.written());
    }

    const copper_layers = placement.rules.layerStack().stackCount();
    for ([_]struct { class: export_fab.DrillClass, suffix: []const u8 }{
        .{ .class = .plated, .suffix = export_gerber.plated_drill_suffix },
        .{ .class = .non_plated, .suffix = export_gerber.non_plated_drill_suffix },
    }) |drill| {
        var bytes: std.Io.Writer.Allocating = .init(arena);
        try export_fab.excellonDrill(&bytes.writer, arena, placement.parts, copper.vias, .{ .class = drill.class, .copper_layers = copper_layers }, frame);
        hashMember(&hash, drill.suffix, bytes.written());
    }
    const part_number = std.mem.trim(u8, placement.rules.physical.part_number, " \t\r\n");
    // Preserve every existing geometry-only identity when no part number was
    // authored. Once present, the stable shop-floor number is physical board
    // identity: changing it must never leave the same printed lookup hash.
    if (part_number.len > 0) hashMember(&hash, "board-part-number", part_number);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    var short_hex: [8]u8 = undefined;
    @memcpy(&short_hex, digest_hex[0..short_hex.len]);
    if (placement.rules.physical.role == .subcircuit) return .{
        .short_hex = short_hex,
        .digest_hex = digest_hex,
        .part_number = part_number,
        .printed = false,
        .text = null,
    };
    const printed_short = try arena.dupe(u8, &short_hex);
    _ = std.ascii.upperString(printed_short, &short_hex);
    const printed = if (part_number.len > 0)
        try std.fmt.allocPrint(arena, "PN {s}  ID {s}", .{ part_number, printed_short })
    else
        try std.fmt.allocPrint(arena, "ID {s}", .{printed_short});

    const text = try subcircuit_silkscreen.placeFabricationIdWithPreferred(
        arena,
        placement,
        .{
            .keepouts = copper.silk_keepouts,
            .relief = silk.relief,
            .annotations = silk.annotations,
            .reserved_texts = silk.reserved_texts,
        },
        printed,
        preferred_id,
    ) orelse return error.NoSilkscreenSpace;
    return .{ .short_hex = short_hex, .digest_hex = digest_hex, .part_number = part_number, .text = text };
}

fn testPlacement(width: f64) optimizer.Placement {
    return .{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = width,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = width, .h = 10 },
    };
}

// spec: export_gerber - fabrication identity is the deterministic eight-hex prefix of the full pre-mark Gerber and Excellon SHA-256
test "fabrication identity is deterministic and retains its full digest" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = testPlacement(20);
    const a = try build(arena, p, .{}, &.{}, export_fab.frameFor(p), null);
    const b = try build(arena, p, .{}, &.{}, export_fab.frameFor(p), null);
    try std.testing.expectEqualSlices(u8, &a.digest_hex, &b.digest_hex);
    try std.testing.expectEqualSlices(u8, &a.short_hex, a.digest_hex[0..a.short_hex.len]);
    try std.testing.expectEqualStrings(a.text.?.text, b.text.?.text);
    try std.testing.expectEqual(@as(usize, 64), a.digest_hex.len);
    try std.testing.expectEqual(@as(usize, 8), a.short_hex.len);
    try std.testing.expect(std.mem.startsWith(u8, a.text.?.text, "ID "));
}

// spec: export_gerber - a physical fabrication-geometry change produces a different printed identity
test "fabrication identity changes with manufactured board geometry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a_placement = testPlacement(20);
    const b_placement = testPlacement(21);
    const a = try build(arena, a_placement, .{}, &.{}, export_fab.frameFor(a_placement), null);
    const b = try build(arena, b_placement, .{}, &.{}, export_fab.frameFor(b_placement), null);
    try std.testing.expect(!std.mem.eql(u8, &a.digest_hex, &b.digest_hex));
    try std.testing.expect(!std.mem.eql(u8, &a.short_hex, &b.short_hex));
    try std.testing.expect(!std.mem.eql(u8, a.text.?.text, b.text.?.text));
}

test "fabrication identity prints and binds the board part number" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var a = testPlacement(60);
    var b = testPlacement(60);
    a.rules.physical.part_number = "CTRL-1001";
    b.rules.physical.part_number = "CTRL-1002";

    const mark_a = try build(arena, a, .{}, &.{}, export_fab.frameFor(a), null);
    const mark_b = try build(arena, b, .{}, &.{}, export_fab.frameFor(b), null);
    try std.testing.expectEqualStrings("CTRL-1001", mark_a.part_number);
    try std.testing.expect(std.mem.startsWith(u8, mark_a.text.?.text, "PN CTRL-1001  ID "));
    try std.testing.expect(!std.mem.eql(u8, &mark_a.digest_hex, &mark_b.digest_hex));
    try std.testing.expect(!std.mem.eql(u8, &mark_a.short_hex, &mark_b.short_hex));
}

// spec: export_gerber - an adopted fabrication identity keeps its editable position without entering the identity digest
test "adopted fabrication identity preserves position and digest" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = testPlacement(40);
    const auto = try build(arena, p, .{}, &.{}, export_fab.frameFor(p), null);
    var preferred = auto.text.?;
    preferred.x -= 5;
    preferred.text = "stale";
    const adopted = try build(arena, p, .{}, &.{preferred}, export_fab.frameFor(p), null);
    try std.testing.expectEqualSlices(u8, &auto.digest_hex, &adopted.digest_hex);
    try std.testing.expectEqual(preferred.x, adopted.text.?.x);
    try std.testing.expectEqual(preferred.y, adopted.text.?.y);
    try std.testing.expectEqual(preferred.rot, adopted.text.?.rot);
    try std.testing.expectEqual(preferred.bottom, adopted.text.?.bottom);
    try std.testing.expectEqual(preferred.size, adopted.text.?.size);
    try std.testing.expect(adopted.text.?.fabrication_id);
    try std.testing.expectEqualStrings(auto.text.?.text, adopted.text.?.text);

    var numbered = p;
    numbered.rules.physical.part_number = "CTRL-1001";
    const relocated = try build(arena, numbered, .{}, &.{preferred}, export_fab.frameFor(numbered), null);
    try std.testing.expect(relocated.text.?.x != preferred.x or relocated.text.?.y != preferred.y or relocated.text.?.rot != preferred.rot);
}

// spec: export_gerber - an adopted fabrication identity is replaced, not duplicated, when composing the final silkscreen texts
test "fabricated texts replace adopted identity with one current mark" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = testPlacement(20);
    const saved = [_]font.BoardText{
        .{ .x = 2, .y = 2, .text = "REV A" },
        .{ .x = 4, .y = 3, .text = "ID STALE", .fabrication_id = true },
    };
    const mark = try build(arena, p, .{}, &saved, export_fab.frameFor(p), null);
    const texts = try replaceAdoptedText(arena, &saved, mark);

    try std.testing.expectEqual(@as(usize, 2), texts.len);
    try std.testing.expectEqualStrings("REV A", texts[0].text);
    try std.testing.expect(!texts[0].fabrication_id);
    try std.testing.expectEqualStrings(mark.text.?.text, texts[1].text);
    try std.testing.expect(texts[1].fabrication_id);
}

// Regression: reusable sub-circuit CAM keeps its digest without generated or
// stale adopted fabrication-ID silk.
test "unprinted fabrication identity strips generated board text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var p = testPlacement(20);
    p.rules.physical.role = .subcircuit;
    const saved = [_]font.BoardText{
        .{ .x = 2, .y = 2, .text = "REV A" },
        .{ .x = 4, .y = 3, .text = "ID STALE", .fabrication_id = true },
    };
    const mark = try build(arena, p, .{}, &saved, export_fab.frameFor(p), null);
    const texts = try replaceAdoptedText(arena, &saved, mark);

    try std.testing.expect(!mark.printed);
    try std.testing.expect(mark.text == null);
    try std.testing.expectEqual(@as(usize, 64), mark.digest_hex.len);
    try std.testing.expectEqual(@as(usize, 8), mark.short_hex.len);
    try std.testing.expectEqual(@as(usize, 1), texts.len);
    try std.testing.expectEqualStrings("REV A", texts[0].text);
    try std.testing.expect(!texts[0].fabrication_id);
}
