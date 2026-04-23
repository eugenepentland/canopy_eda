/// Pixi.js schematic canvas viewer JavaScript.
///
/// Source lives in assets/canvas_viewer.js — edit there and rebuild. This
/// module just embeds the file into the binary so the deploy is still a
/// single exe.
pub const CANVAS_VIEWER_JS = @embedFile("assets/canvas_viewer.js");
