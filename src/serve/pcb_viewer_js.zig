/// Pixi.js PCB viewer JavaScript.
/// Renders footprints, pads, silkscreen, courtyard, ratsnest, and board outline.
/// Supports zoom/pan, layer toggles, component selection, and drag placement.
///
/// Source lives in assets/pcb_viewer.js — edit there and rebuild. This module
/// just embeds the file into the binary so the deploy is still a single exe.
pub const PCB_VIEWER_JS = @embedFile("assets/pcb_viewer.js");
