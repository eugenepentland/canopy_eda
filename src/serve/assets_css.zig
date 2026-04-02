const std = @import("std");

// ── Shared navbar ─────────────────────────────────────────────────────

pub const NAVBAR_CSS =
    \\.navbar{background:#161b22;border-bottom:1px solid #21262d;padding:0 1.5rem;display:flex;align-items:center;gap:1.5rem;height:42px;font-family:system-ui,sans-serif;font-size:0.85rem;}
    \\.navbar a{color:#8b949e;text-decoration:none;padding:0.4rem 0;border-bottom:2px solid transparent;}
    \\.navbar a:hover{color:#e0e0e0;}
    \\.navbar a.active{color:#e0e0e0;border-bottom-color:#58a6ff;}
    \\.navbar .brand{color:#58a6ff;font-weight:600;font-size:0.9rem;margin-right:0.5rem;}
;

pub fn writeNavbar(w: anytype, active: []const u8) !void {
    try w.writeAll("<div class=\"navbar\"><span class=\"brand\">Canopy EDA</span>");
    if (std.mem.eql(u8, active, "designs")) {
        try w.writeAll("<a href=\"/\" class=\"active\">Designs</a>");
    } else {
        try w.writeAll("<a href=\"/\">Designs</a>");
    }
    if (std.mem.eql(u8, active, "library")) {
        try w.writeAll("<a href=\"/library\" class=\"active\">Library</a>");
    } else {
        try w.writeAll("<a href=\"/library\">Library</a>");
    }
    try w.writeAll("</div>");
}

// ── CSS for index page ────────────────────────────────────────────────

pub const INDEX_CSS =
    \\* { margin: 0; padding: 0; box-sizing: border-box; }
    \\body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    \\  max-width: 960px; margin: 0 auto; padding: 2rem; background: #0d1117; color: #c9d1d9; }
    \\a { color: #58a6ff; text-decoration: none; }
    \\a:hover { text-decoration: underline; }
    \\h1 { margin-bottom: 1rem; color: #f0f6fc; }
    \\h2 { margin: 1.5rem 0 0.5rem; color: #f0f6fc; border-bottom: 1px solid #21262d; padding-bottom: 0.3rem; }
    \\.design-list { list-style: none; }
    \\.design-list li { padding: 0.75rem 1rem; border: 1px solid #21262d; border-radius: 6px;
    \\  margin-bottom: 0.5rem; background: #161b22; }
    \\.design-list li:hover { border-color: #58a6ff; }
    \\.design-list a { font-size: 1.1rem; display: block; }
    \\table { width: 100%; border-collapse: collapse; margin-bottom: 1rem; }
    \\th, td { text-align: left; padding: 0.4rem 0.75rem; border-bottom: 1px solid #21262d; }
    \\th { background: #161b22; color: #8b949e; font-weight: 600; font-size: 0.85rem; text-transform: uppercase; }
    \\td { font-family: "SF Mono", "Fira Code", monospace; font-size: 0.9rem; }
    \\.assertions { margin: 1rem 0; }
    \\.pass { color: #3fb950; font-family: monospace; }
    \\.fail { color: #f85149; font-family: monospace; font-weight: bold; }
    \\.warn { color: #d29922; font-family: monospace; }
    \\.schematic { margin: 1rem 0; border: 1px solid #21262d; border-radius: 8px; overflow: hidden; }
    \\.schematic svg { display: block; }
    \\details { margin: 0.5rem 0; }
    \\summary { cursor: pointer; color: #58a6ff; }
    \\pre { background: #161b22; padding: 1rem; border-radius: 6px; overflow-x: auto;
    \\  font-size: 0.85rem; line-height: 1.5; margin-top: 0.5rem; }
;

// ── CSS for design page (embedded in <style>) ─────────────────────────

pub const DESIGN_CSS =
    \\body { font-family: system-ui, sans-serif; margin: 0; padding: 0; color: #e0e0e0; background: #121212; }
    \\.page { max-width: 900px; margin: 2rem auto; padding: 0 1rem; transition: margin-right 0.2s; }
    \\.page.sidebar-open { margin-right: 340px; }
    \\h1, h2, h3 { color: #fff; }
    \\.schematic-canvas { margin: 1rem 0; border: 1px solid #2a2a4a; border-radius: 8px; overflow: hidden; height: 70vh; position: relative; background: #1a1a2e; }
    \\.schematic-canvas svg { width: 100%; height: 100%; cursor: grab; display: block; }
    \\.schematic-canvas svg:active { cursor: grabbing; }
    \\.edit-mode .hub-group > .component { cursor: move !important; }
    \\.hub-group.dragging { opacity: 0.8; }
    \\.canvas-controls { position: absolute; top: 0.5rem; right: 0.5rem; display: flex; gap: 0.3rem; z-index: 10; }
    \\.canvas-btn { background: #2a2a4a; color: #888; border: 1px solid #444; border-radius: 4px; padding: 0.2rem 0.5rem; font-size: 0.75rem; cursor: pointer; }
    \\.canvas-btn:hover { color: #fff; border-color: #888; }
    \\.canvas-btn.active { color: #4a9eff; border-color: #4a9eff; }
    \\.canvas-toggle { display: inline-flex; align-items: center; gap: 0.3rem; font-size: 0.75rem; color: #888; cursor: pointer; margin-left: 0.2rem; }
    \\.canvas-toggle input { accent-color: #4a9eff; }
    \\#nodes-toggle.active { color: #e55; border-color: #e55; }
    \\.sidebar { position: fixed; top: 0; right: -320px; width: 320px; height: 100vh; background: #1a1a2e; border-left: 1px solid #333; padding: 1.5rem; overflow-y: auto; transition: right 0.2s; z-index: 100; box-sizing: border-box; }
    \\.sidebar.open { right: 0; }
    \\.sidebar-close { position: absolute; top: 0.8rem; right: 0.8rem; background: none; border: none; color: #888; font-size: 1.2rem; cursor: pointer; }
    \\.sidebar-close:hover { color: #fff; }
    \\.sidebar h3 { margin-top: 0; color: #4a9eff; }
    \\.sidebar-section { margin-bottom: 1.2rem; }
    \\.sidebar-label { color: #888; font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 0.3rem; }
    \\.sidebar-value { color: #e0e0e0; font-family: monospace; font-size: 0.85rem; }
    \\.sidebar-pins { list-style: none; padding: 0; margin: 0; }
    \\.sidebar-pins .pin-header { display: flex; padding: 0.3rem 0; border-bottom: 1px solid #444; font-size: 0.7rem; color: #666; text-transform: uppercase; letter-spacing: 0.05em; }
    \\.sidebar-pins .pin-header span:first-child { min-width: 3.5rem; }
    \\.sidebar-pins li { display: flex; align-items: baseline; padding: 0.25rem 0; border-bottom: 1px solid #2a2a4a; font-size: 0.8rem; font-family: monospace; }
    \\.sidebar-pins li.part-header { display: block; }
    \\.sidebar-pins .pin-num { color: #888; min-width: 3.5rem; flex-shrink: 0; }
    \\.sidebar-pins .pin-name { color: #e0e0e0; }
    \\.sidebar-pins .pin-type { color: #6a6; margin-left: 0.5rem; font-size: 0.75rem; }
    \\.sidebar-pins .pin-net { color: #e8c547; }
    \\.sidebar-note { color: #bbb; font-size: 0.8rem; line-height: 1.5; background: #16213e; padding: 0.6rem; border-radius: 4px; }
    \\.search-input { background: #1a1a2e; border: 1px solid #444; border-radius: 4px; color: #e0e0e0; padding: 0.3rem 0.6rem; font-size: 0.8rem; font-family: monospace; width: 200px; outline: none; }
    \\.search-input:focus { border-color: #4a9eff; }
    \\.search-input::placeholder { color: #555; }
    \\.search-results { display: none; position: absolute; top: 100%; left: 0; width: 260px; max-height: 300px; overflow-y: auto; background: #1a1a2e; border: 1px solid #444; border-radius: 0 0 4px 4px; z-index: 200; }
    \\.search-results.open { display: block; }
    \\.search-result { padding: 0.4rem 0.6rem; cursor: pointer; font-size: 0.8rem; font-family: monospace; color: #e0e0e0; border-bottom: 1px solid #2a2a4a; display: flex; justify-content: space-between; }
    \\.search-result:hover,.search-result.selected { background: #2a2a4a; }
    \\.search-result-type { font-size: 0.7rem; color: #888; text-transform: uppercase; }
    \\.search-result-type.net { color: #e8c547; }
    \\.search-result-type.comp { color: #4a9eff; }
    \\.search-result-type.section { color: #3fb950; }
    \\.search-result-type.pin { color: #c084fc; }
    \\table { width: 100%; border-collapse: collapse; margin-bottom: 1rem; }
    \\th,td { text-align: left; padding: 0.4rem 0.75rem; border-bottom: 1px solid #333; }
    \\th { background: #1a1a2e; color: #888; font-size: 0.85rem; text-transform: uppercase; }
    \\td { font-family: monospace; font-size: 0.9rem; }
    \\details { margin: 0.5rem 0; }
    \\summary { cursor: pointer; color: #6699ff; }
    \\pre { background: #1e1e1e; padding: 1rem; border-radius: 6px; overflow-x: auto; font-size: 0.85rem; }
    \\.assertions { margin: 1rem 0; }
    \\.pass { color: #3fb950; font-family: monospace; }
    \\.fail { color: #f85149; font-family: monospace; font-weight: bold; }
    \\.warn { color: #d29922; font-family: monospace; }
    \\svg .component:hover rect:not(.hit-area),svg .component:hover line,svg .component:hover path { filter: brightness(1.3); }
    \\svg .component.comp-active rect:not(.hit-area) { stroke: #e55 !important; }
    \\svg .component.comp-active line { stroke: #e55 !important; }
    \\svg .component.comp-active path { stroke: #e55 !important; }
    \\svg .component.comp-active polyline { stroke: #e55 !important; }
    \\svg .component.comp-active text { fill: #e55 !important; }
    \\.bom-section { margin: 2rem 0; }
    \\.bom-section h2 { font-size: 1.1rem; margin-bottom: 0.5rem; }
    \\.bom-table { width: 100%; border-collapse: collapse; font-size: 0.8rem; }
    \\.bom-table th { background: #161b22; color: #8b949e; font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.05em; padding: 0.5rem 0.6rem; text-align: left; border-bottom: 2px solid #30363d; white-space: nowrap; }
    \\.bom-table td { padding: 0.35rem 0.6rem; border-bottom: 1px solid #21262d; font-family: monospace; font-size: 0.8rem; color: #e0e0e0; }
    \\.bom-table tr:hover td { background: #161b22; }
    \\.bom-table .bom-refs { color: #79c0ff; max-width: 300px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    \\.bom-table .bom-attrs { max-width: 400px; }
    \\.bom-table .bom-pkg { color: #8b949e; }
    \\.bom-tag { display: inline-block; padding: 0.1rem 0.4rem; border-radius: 3px; font-size: 0.7rem; margin: 1px 2px; white-space: nowrap; }
    \\.bom-tag-attr { background: #2d1b69; color: #d2a8ff; }
    \\.bom-tag-prop { background: #1b2d3d; color: #79c0ff; }
    \\.bom-fp-select { background: #161b22; border: 1px solid #30363d; border-radius: 4px; color: #8b949e; padding: 0.2rem 0.4rem; font-family: monospace; font-size: 0.75rem; cursor: pointer; outline: none; }
    \\.bom-fp-select:hover { border-color: #4a9eff; color: #e0e0e0; }
    \\.bom-total { color: #6e7681; font-size: 0.8rem; margin-top: 0.5rem; }
    \\svg .net:hover { filter: brightness(1.5); }
    \\svg .net.net-active line:not(.hit-area),svg .net.net-active polyline:not(.hit-area) { stroke: #e55 !important; }
    \\svg .net.net-active text { fill: #e55 !important; }
;
