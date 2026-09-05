//! Server-rendered markup for the datasheet viewer shell.
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

// PDF.js datasheet viewer. The actual CSS, viewer JS, pinned PDF.js runtime,
// and worker all live in the embedded same-origin `/static` registry, so this
// template only carries the bare HTML skeleton and a `data-pdf="…"` hook the
// script reads on load.

const home_tmpl = @import("pages.zig");

const navbar_style: []const u8 = "<style>" ++ @embedFile("../assets/navbar.css") ++ "</style>";

/// The datasheet viewer page: a toolbar, an empty viewer element and the
/// `data-pdf` hook `/static/pdf_viewer.js` reads on load to fetch the file.
pub const Page = struct {
    /// Write this template's markup to `writer`.
    fn write(filename: []const u8, writer: *std.Io.Writer) html.Error!void {
        try writer.writeAll("<!DOCTYPE html>");
        try writer.writeAll("<html lang=\"en\">");
        try writer.writeAll("<head>");
        try writer.writeAll("<meta charset=\"utf-8\">");
        try writer.writeAll("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">");
        try writer.writeAll("<title>");
        try html.writeEscaped(writer, filename);
        try writer.writeAll("</title>");
        try writer.writeAll("<link rel=\"stylesheet\" href=\"/static/pdf_viewer.css\">");
        try html.writeRaw(writer, navbar_style);
        try writer.writeAll("</head>");
        try writer.writeAll("<body");
        try html.writeAttr(writer, "data-pdf", filename);
        try writer.writeAll(">");
        try html.renderComponent(home_tmpl.Navbar, .{""}, writer);
        try writer.writeAll("<div id=\"toolbar\">");
        try writer.writeAll("<a id=\"back\" href=\"javascript:history.back()\">");
        try writer.writeAll("← back");
        try writer.writeAll("</a>");
        try writer.writeAll("<span class=\"filename\" id=\"filenameLabel\">");
        try writer.writeAll("</span>");
        try writer.writeAll("<span id=\"quoteLabel\" class=\"quote-label\" hidden>");
        try writer.writeAll("</span>");
        try writer.writeAll("<span id=\"matchCtrls\" hidden>");
        try writer.writeAll("<button id=\"prev\" title=\"Previous match\">");
        try writer.writeAll("▲");
        try writer.writeAll("</button>");
        try writer.writeAll("<button id=\"next\" title=\"Next match\">");
        try writer.writeAll("▼");
        try writer.writeAll("</button>");
        try writer.writeAll("<span id=\"count\" class=\"match-count\">");
        try writer.writeAll("</span>");
        try writer.writeAll("</span>");
        try writer.writeAll("<span class=\"spacer\">");
        try writer.writeAll("</span>");
        try writer.writeAll("<a id=\"rawLink\" target=\"_blank\" rel=\"noopener\">");
        try writer.writeAll("Open raw PDF ↗");
        try writer.writeAll("</a>");
        try writer.writeAll("</div>");
        try writer.writeAll("<div id=\"viewer\">");
        try writer.writeAll("</div>");
        try writer.writeAll("<div id=\"status\">");
        try writer.writeAll("Loading…");
        try writer.writeAll("</div>");
        try writer.writeAll("<script type=\"module\" src=\"/static/pdf_viewer.js\">");
        try writer.writeAll("</script>");
        try writer.writeAll("</body>");
        try writer.writeAll("</html>");
    }

    /// `write`'s parameter list, spelled as a function so `std.meta.ArgsTuple`
    /// can lift it into the tuple type `render` and `bind` accept.
    fn argList(_: []const u8) void {}

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
