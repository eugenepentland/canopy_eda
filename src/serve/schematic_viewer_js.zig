/// HTML schematic viewer JavaScript: sidebar search, click handlers, live reload.
///
/// Source lives in assets/schematic_viewer.js — edit there and rebuild. This
/// module just embeds the file into the binary so the deploy is still a
/// single exe (mirrors canvas_viewer_js.zig).
pub const schematic_viewer_js_asset = @embedFile("assets/schematic_viewer.js");
