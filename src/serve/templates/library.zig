//! Server-rendered markup for the component-library browser: the page shell,
//! one card per library row, and the detail block a component card expands to.
//!
//! HAND-MAINTAINED. This file was first emitted by a template compiler that no
//! longer exists; it is ordinary Zig source now and the only source of truth
//! for this markup. To edit it safely, keep the shape the three template files
//! share: one `writer.writeAll(...)` per run of literal markup, every value
//! that comes from data through `html.writeEscaped` (text) or `html.writeAttr`
//! (a whole attribute), and `html.writeRaw` reserved for markup this repository
//! produced. Pages are asserted against exact substrings in tests, so
//! whitespace between tags is meaningful — `zig fmt` is safe, reflowing markup
//! is not. See `html.zig` for the sinks.

const std = @import("std");
const html = @import("html.zig");

// Component-library browser. The data side stays in `library.zig`
// (`collectRows` walks `lib/components/`, `lib/pinouts/`, `lib/footprints/`
// and yields a `LibraryRow` slice); this template just turns it into HTML.

const library_mod = @import("../library.zig");
const assets_css = @import("../assets_css.zig");
const home_tmpl = @import("pages.zig");
const LibraryRow = library_mod.LibraryRow;

const style_block: []const u8 = "<style>" ++
    assets_css.navbar_css ++
    @embedFile("../assets/library.css") ++
    "</style>";

const upload_block: []const u8 = @embedFile("../assets/library_upload.html");
const courtyard_modal_block: []const u8 = @embedFile("../assets/library_courtyard.html");

/// The component-library page: search box, upload panel, one `Card` per
/// library row, and the pagination the client script drives.
pub const Library = struct {
    /// Write this template's markup to `writer`.
    fn write(rows: []const LibraryRow, writer: *std.Io.Writer) html.Error!void {
        try writer.writeAll("<!DOCTYPE html>");
        try writer.writeAll("<html>");
        try writer.writeAll("<head>");
        try writer.writeAll("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1,viewport-fit=cover\">");
        try writer.writeAll("<title>");
        try writer.writeAll("Component Library");
        try writer.writeAll("</title>");
        try html.writeRaw(writer, style_block);
        try writer.writeAll("</head>");
        try writer.writeAll("<body>");
        try html.renderComponent(home_tmpl.Navbar, .{"library"}, writer);
        try writer.writeAll("<div class=\"lib-content\">");
        try writer.writeAll("<h1>");
        try writer.writeAll("Component Library");
        try writer.writeAll("</h1>");
        try writer.writeAll("<p><a href=\"/library/package\">＋ New IC package</a> — create a footprint and STEP model from datasheet dimensions</p>");
        try html.writeRaw(writer, upload_block);
        try writer.writeAll("<input type=\"text\" class=\"search-box\" id=\"lib-search\" placeholder=\"Search components, footprints, pinouts...\">");
        try writer.writeAll("<div class=\"count-info\" id=\"count-info\">");
        try writer.writeAll("</div>");
        try writer.writeAll("<div class=\"card-grid\" id=\"lib-grid\">");
        for (rows) |row| {
            try html.renderComponent(Card, .{row}, writer);
        }
        try writer.writeAll("</div>");
        try writer.writeAll("<div class=\"pagination\" id=\"pagination\">");
        try writer.writeAll("<button id=\"page-prev\">");
        try writer.writeAll("&larr; Prev");
        try writer.writeAll("</button>");
        try writer.writeAll("<span class=\"page-info\" id=\"page-info\">");
        try writer.writeAll("</span>");
        try writer.writeAll("<button id=\"page-next\">");
        try writer.writeAll("Next &rarr;");
        try writer.writeAll("</button>");
        try writer.writeAll("</div>");
        try writer.writeAll("<datalist id=\"lib-ds-options\">");
        try writer.writeAll("</datalist>");
        try writer.writeAll("</div>");
        try html.writeRaw(writer, courtyard_modal_block);
        try writer.writeAll("<script src=\"/static/footprint_svg.js\">");
        try writer.writeAll("</script>");
        try writer.writeAll("<script src=\"/static/library.js\">");
        try writer.writeAll("</script>");
        try writer.writeAll("</body>");
        try writer.writeAll("</html>");
    }

    /// `write`'s parameter list, spelled as a function so `std.meta.ArgsTuple`
    /// can lift it into the tuple type `render` and `bind` accept.
    fn argList(_: []const LibraryRow) void {}

    /// The positional arguments this template renders from.
    pub const Args = std.meta.ArgsTuple(@TypeOf(argList));

    /// Render the template to `writer`.
    pub fn render(args: Args, writer: *std.Io.Writer) html.Error!void {
        return @call(.always_inline, write, args ++ .{writer});
    }

    /// Capture this template together with `args` as a type-erased component,
    /// so another template can render it without naming its type. `args` is
    /// borrowed and has to outlive every render of the returned component.
    pub fn bind(args: *const Args) html.Component {
        return .{ .ptr = @ptrCast(args), .renderFn = &renderErased };
    }

    fn renderErased(ptr: *const anyopaque, writer: *std.Io.Writer) html.Error!void {
        return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, writer);
    }
};

/// One library entry — component, family, pinout or footprint — as a card.
/// Its `data-*` attributes are what the page's search and filter read.
pub const Card = struct {
    /// Write this template's markup to `writer`.
    fn write(row: LibraryRow, writer: *std.Io.Writer) html.Error!void {
        try writer.writeAll("<div");
        try writer.writeAll(" class=\"comp-card\"");
        try html.writeAttr(writer, "data-search", row.search_text);
        try html.writeAttr(writer, "data-kind", @tagName(row.kind));
        try html.writeAttr(writer, "data-name", row.name);
        try html.writeAttr(writer, "data-component", if (row.kind == .component or row.kind == .family) row.name else null);
        try writer.writeAll(">");
        try writer.writeAll("<div class=\"card-head\">");
        try writer.writeAll("<span class=\"card-name\">");
        try html.writeEscaped(writer, row.name);
        try writer.writeAll("</span>");
        switch (row.kind) {
            .component => {
                try writer.writeAll("<span class=\"tag tag-component\">");
                try writer.writeAll("component");
                try writer.writeAll("</span>");
            },
            .family => {
                try writer.writeAll("<span class=\"tag tag-family\">");
                try writer.writeAll("family");
                try writer.writeAll("</span>");
            },
            .pinout => {
                try writer.writeAll("<span class=\"tag tag-pinout\">");
                try writer.writeAll("pinout");
                try writer.writeAll("</span>");
            },
            .footprint => {
                try writer.writeAll("<span class=\"tag tag-footprint\">");
                try writer.writeAll("footprint");
                try writer.writeAll("</span>");
            },
        }
        try writer.writeAll("<span class=\"card-del\" title=\"Delete from library\">");
        try writer.writeAll("×");
        try writer.writeAll("</span>");
        try writer.writeAll("</div>");
        switch (row.kind) {
            .family, .component => {
                try html.renderComponent(ComponentDetails, .{row}, writer);
            },
            .pinout => {
                if (row.pin_count) |pc| {
                    try writer.writeAll("<div class=\"card-desc\">");
                    try html.writeEscaped(writer, pc);
                    try writer.writeAll(" pins");
                    try writer.writeAll("</div>");
                }
            },
            .footprint => {
                try writer.writeAll("<span");
                try writer.writeAll(" class=\"tag tag-footprint fp-toggle\"");
                try html.writeAttr(writer, "data-fp", row.name);
                try writer.writeAll(" title=\"Show footprint preview\"");
                try writer.writeAll(">");
                try writer.writeAll("show preview ›");
                try writer.writeAll("</span>");
                if (row.has_3d_model) {
                    try writer.writeAll("<a");
                    try writer.writeAll(" class=\"badge-3d\"");
                    try writer.writeAll(" href=\"");
                    try writer.writeAll("/library/3d/");
                    try html.writeEscaped(writer, row.name);
                    try writer.writeAll("\"");
                    try writer.writeAll(" title=\"Align 3D model orientation\"");
                    try writer.writeAll(">");
                    try writer.writeAll("3D");
                    try writer.writeAll("</a>");
                }
                try writer.writeAll("<div");
                try writer.writeAll(" class=\"fp-preview\"");
                try html.writeAttr(writer, "data-fp", row.name);
                try writer.writeAll(">");
                try writer.writeAll("</div>");
            },
        }
        if (row.has_package) {
            try writer.writeAll("<a href=\"/library/package?name=");
            try (std.Uri.Component{ .raw = row.footprint orelse row.name }).formatEscaped(writer);
            try writer.writeAll("\">Edit package ↗</a>");
        }
        if (row.requirements.len > 0) {
            try writer.writeAll("<span class=\"req-toggle\">");
            try writer.writeAll("⚑ ");
            try html.writeEscaped(writer, row.requirements.len);
            try writer.writeAll(" requirements ›");
            try writer.writeAll("</span>");
            try writer.writeAll("<div class=\"req-cards\">");
            for (row.requirements) |req| {
                try writer.writeAll("<div class=\"req-item\">");
                try html.writeEscaped(writer, req);
                try writer.writeAll("</div>");
            }
            try writer.writeAll("</div>");
        }
        try writer.writeAll("</div>");
    }

    /// `write`'s parameter list, spelled as a function so `std.meta.ArgsTuple`
    /// can lift it into the tuple type `render` and `bind` accept.
    fn argList(_: LibraryRow) void {}

    /// The positional arguments this template renders from.
    pub const Args = std.meta.ArgsTuple(@TypeOf(argList));

    /// Render the template to `writer`.
    pub fn render(args: Args, writer: *std.Io.Writer) html.Error!void {
        return @call(.always_inline, write, args ++ .{writer});
    }

    /// Capture this template together with `args` as a type-erased component,
    /// so another template can render it without naming its type. `args` is
    /// borrowed and has to outlive every render of the returned component.
    pub fn bind(args: *const Args) html.Component {
        return .{ .ptr = @ptrCast(args), .renderFn = &renderErased };
    }

    fn renderErased(ptr: *const anyopaque, writer: *std.Io.Writer) html.Error!void {
        return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, writer);
    }
};

/// The part-specific body of a component or family card: description,
/// footprint and pinout tags, identity, datasheets and requirements.
pub const ComponentDetails = struct {
    /// Write this template's markup to `writer`.
    fn write(row: LibraryRow, writer: *std.Io.Writer) html.Error!void {
        if (row.description) |d| {
            try writer.writeAll("<div class=\"card-desc\">");
            try html.writeEscaped(writer, d);
            try writer.writeAll("</div>");
        }
        try writer.writeAll("<div class=\"card-tags\">");
        if (row.footprint) |fp| {
            try writer.writeAll("<span");
            try writer.writeAll(" class=\"tag tag-footprint fp-toggle\"");
            try html.writeAttr(writer, "data-fp", fp);
            try writer.writeAll(" title=\"Show footprint preview\"");
            try writer.writeAll(">");
            try html.writeEscaped(writer, fp);
            try writer.writeAll("</span>");
            if (row.has_3d_model) {
                try writer.writeAll("<a");
                try writer.writeAll(" class=\"badge-3d\"");
                try writer.writeAll(" href=\"");
                try writer.writeAll("/library/3d/");
                try html.writeEscaped(writer, fp);
                try writer.writeAll("\"");
                try writer.writeAll(" title=\"Align 3D model orientation\"");
                try writer.writeAll(">");
                try writer.writeAll("3D");
                try writer.writeAll("</a>");
            }
        }
        if (row.pinout) |po| {
            try writer.writeAll("<span class=\"tag tag-pinout\">");
            try html.writeEscaped(writer, po);
            try writer.writeAll("</span>");
        }
        try writer.writeAll("</div>");
        if (row.manufacturer) |m| {
            try writer.writeAll("<div class=\"card-meta\">");
            try html.writeEscaped(writer, m);
            try writer.writeAll("</div>");
        }
        if (row.mpn) |m| {
            try writer.writeAll("<div class=\"card-meta\">");
            try html.writeEscaped(writer, m);
            try writer.writeAll("</div>");
        }
        if (row.datasheets.len > 0) {
            try writer.writeAll("<div class=\"card-tags\">");
            for (row.datasheets) |ds| {
                if (ds.present) {
                    if (ds.remote) {
                        try writer.writeAll("<a");
                        try writer.writeAll(" class=\"tag tag-datasheet\"");
                        try html.writeAttr(writer, "href", ds.name);
                        try writer.writeAll(" target=\"_blank\"");
                        try writer.writeAll(" rel=\"noopener noreferrer\"");
                        try writer.writeAll(" title=\"Open datasheet URL\"");
                        try writer.writeAll(">");
                        try writer.writeAll("🔗 ");
                        try html.writeEscaped(writer, ds.name);
                        try writer.writeAll("</a>");
                    } else {
                        try writer.writeAll("<a");
                        try writer.writeAll(" class=\"tag tag-datasheet\"");
                        try writer.writeAll(" href=\"");
                        try writer.writeAll("/datasheets/");
                        try html.writeEscaped(writer, ds.name);
                        try writer.writeAll("\"");
                        try writer.writeAll(" target=\"_blank\"");
                        try writer.writeAll(" rel=\"noopener\"");
                        try writer.writeAll(" title=\"Open PDF\"");
                        try writer.writeAll(">");
                        try writer.writeAll("📄 ");
                        try html.writeEscaped(writer, ds.name);
                        try writer.writeAll("</a>");
                    }
                } else {
                    try writer.writeAll("<span class=\"tag tag-datasheet-missing\" title=\"PDF declared but not uploaded\">");
                    try writer.writeAll("📄 ");
                    try html.writeEscaped(writer, ds.name);
                    try writer.writeAll(" (missing)");
                    try writer.writeAll("</span>");
                }
            }
            try writer.writeAll("</div>");
        }
        try writer.writeAll("<div class=\"ds-attach\">");
        try writer.writeAll("<span class=\"ds-attach-toggle\" title=\"Link an uploaded PDF or an HTTP(S) datasheet URL to this part\">");
        try writer.writeAll("📎 attach datasheet");
        try writer.writeAll("</span>");
        try writer.writeAll("<span class=\"ds-attach-row\" hidden>");
        try writer.writeAll("<input type=\"text\" class=\"ds-attach-input\" list=\"lib-ds-options\" placeholder=\"uploaded PDF or https:// URL…\">");
        try writer.writeAll("<button class=\"ds-attach-btn\" type=\"button\">");
        try writer.writeAll("Attach");
        try writer.writeAll("</button>");
        try writer.writeAll("</span>");
        try writer.writeAll("</div>");
        if (row.footprint) |fp| {
            try writer.writeAll("<div");
            try writer.writeAll(" class=\"fp-preview\"");
            try html.writeAttr(writer, "data-fp", fp);
            try writer.writeAll(">");
            try writer.writeAll("</div>");
        }
    }

    /// `write`'s parameter list, spelled as a function so `std.meta.ArgsTuple`
    /// can lift it into the tuple type `render` and `bind` accept.
    fn argList(_: LibraryRow) void {}

    /// The positional arguments this template renders from.
    pub const Args = std.meta.ArgsTuple(@TypeOf(argList));

    /// Render the template to `writer`.
    pub fn render(args: Args, writer: *std.Io.Writer) html.Error!void {
        return @call(.always_inline, write, args ++ .{writer});
    }

    /// Capture this template together with `args` as a type-erased component,
    /// so another template can render it without naming its type. `args` is
    /// borrowed and has to outlive every render of the returned component.
    pub fn bind(args: *const Args) html.Component {
        return .{ .ptr = @ptrCast(args), .renderFn = &renderErased };
    }

    fn renderErased(ptr: *const anyopaque, writer: *std.Io.Writer) html.Error!void {
        return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, writer);
    }
};
