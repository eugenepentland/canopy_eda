// Auto-generated from pdf_viewer.zt - do not edit
const std = @import("std");
const zt = @import("zt");

// PDF.js datasheet viewer. The actual CSS, viewer JS, pinned PDF.js runtime,
// and worker all live in the embedded same-origin `/static` registry, so this
// template only carries the bare HTML skeleton and a `data-pdf="…"` hook the
// script reads on load.
pub const Page = struct {
    fn _render(filename: []const u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        _ = &filename;
        try writer.writeAll("<!DOCTYPE html>");
        // pdf_viewer.zt:8
        try writer.writeAll("<html lang=\"en\">");
        // pdf_viewer.zt:9
        try writer.writeAll("<head>");
        // pdf_viewer.zt:10
        try writer.writeAll("<meta charset=\"utf-8\">");
        // pdf_viewer.zt:11
        try writer.writeAll("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">");
        // pdf_viewer.zt:12
        try writer.writeAll("<title>");
        try zt.writeEscaped(writer, filename);
        try writer.writeAll("</title>");
        // pdf_viewer.zt:13
        try writer.writeAll("<link rel=\"stylesheet\" href=\"/static/pdf_viewer.css\">");
        // pdf_viewer.zt:14
        try writer.writeAll("</head>");
        // pdf_viewer.zt:15
        try writer.writeAll("<body");
        try zt.writeAttr(writer, "data-pdf", filename);
        try writer.writeAll(">");
        // pdf_viewer.zt:16
        try writer.writeAll("<div id=\"toolbar\">");
        // pdf_viewer.zt:17
        try writer.writeAll("<a id=\"back\" href=\"javascript:history.back()\">");
        try writer.writeAll("← back");
        try writer.writeAll("</a>");
        // pdf_viewer.zt:18
        try writer.writeAll("<span class=\"filename\" id=\"filenameLabel\">");
        try writer.writeAll("</span>");
        // pdf_viewer.zt:19
        try writer.writeAll("<span id=\"quoteLabel\" class=\"quote-label\" hidden>");
        try writer.writeAll("</span>");
        // pdf_viewer.zt:20
        try writer.writeAll("<span id=\"matchCtrls\" hidden>");
        // pdf_viewer.zt:21
        try writer.writeAll("<button id=\"prev\" title=\"Previous match\">");
        try writer.writeAll("▲");
        try writer.writeAll("</button>");
        // pdf_viewer.zt:22
        try writer.writeAll("<button id=\"next\" title=\"Next match\">");
        try writer.writeAll("▼");
        try writer.writeAll("</button>");
        // pdf_viewer.zt:23
        try writer.writeAll("<span id=\"count\" class=\"match-count\">");
        try writer.writeAll("</span>");
        // pdf_viewer.zt:24
        try writer.writeAll("</span>");
        // pdf_viewer.zt:25
        try writer.writeAll("<span class=\"spacer\">");
        try writer.writeAll("</span>");
        // pdf_viewer.zt:26
        try writer.writeAll("<a id=\"rawLink\" target=\"_blank\" rel=\"noopener\">");
        try writer.writeAll("Open raw PDF ↗");
        try writer.writeAll("</a>");
        // pdf_viewer.zt:27
        try writer.writeAll("</div>");
        // pdf_viewer.zt:28
        try writer.writeAll("<div id=\"viewer\">");
        try writer.writeAll("</div>");
        // pdf_viewer.zt:29
        try writer.writeAll("<div id=\"status\">");
        try writer.writeAll("Loading…");
        try writer.writeAll("</div>");
        // pdf_viewer.zt:30
        try writer.writeAll("<script type=\"module\" src=\"/static/pdf_viewer.js\">");
        try writer.writeAll("</script>");
        // pdf_viewer.zt:31
        try writer.writeAll("</body>");
        // pdf_viewer.zt:32
        try writer.writeAll("</html>");
    }

    fn _signature(_: []const u8) void {}

    pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));

    pub fn render(args: Args, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return @call(.always_inline, _render, args ++ .{writer});
    }

    pub fn bind(args: *const Args) zt.Component {
        return .{
            .ptr = @ptrCast(args),
            .renderFn = struct {
                fn f(ptr: *const anyopaque, writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, writer);
                }
            }.f,
        };
    }
};
