const std = @import("std");

/// HTML schematic viewer JavaScript: sidebar search, click handlers, live reload.
///
/// Source lives in assets/schematic_viewer.js — edit there and rebuild. This
/// module just embeds the file into the binary so the deploy is still a
/// single exe; static_assets.zig registers the bytes for HTTP serving.
pub const schematic_viewer_js_asset = @embedFile("assets/schematic_viewer.js");

// Regression guard: sidebar pin re-wires preserve the current page and
// component inspector for subsequent edits.
test "sidebar pin re-wire updates in place without a full-page reload" {
    const js = schematic_viewer_js_asset;
    try std.testing.expect(std.mem.indexOf(u8, js, "function updatePinNet(ref, pin, newNet)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "{ ref: ref, pin: pin, net: nn, srcOff: c.src }, false,") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "updatePinNet(ref, pin, nn); showComponent(ref, false);") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if (pendingEdits) return;") != null);
}

test "sidebar delete carries source identity for auto-numbered parts" {
    const js = schematic_viewer_js_asset;
    try std.testing.expect(std.mem.indexOf(u8, js, "{ ref: ref, srcOff: c.src }, true,") != null);
}

// spec: Web Server - A standalone module opened through the schematic page exposes direct pin-net editing and deletion for source-backed parts
test "standalone module schematic exposes structured part edits" {
    const js = schematic_viewer_js_asset;
    try std.testing.expect(std.mem.indexOf(u8, js, "var canEditSrc = !!c.src;") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "var canEditSrc = c.src && (typeof SCH_VIEW") == null);
    try std.testing.expect(std.mem.indexOf(u8, js, "Click ✎ to edit a net") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "Delete part") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "var del = box.querySelector('.sb-insp-del');") != null);
}
