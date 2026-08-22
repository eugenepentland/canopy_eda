// Auto-generated from mcp_docs.zt - do not edit
const std = @import("std");
const zt = @import("zt");

// MCP tool reference page. The data side lives in `mcp_docs.zig`
// (`buildToolDocs` parses `assets/tools_list_result.json` into a `[]ToolDoc`);
// this template just turns it into HTML. Reached at `GET /mcp-tools`.

const mcp_docs = @import("../mcp_docs.zig");
const assets_css = @import("../assets_css.zig");
const home_tmpl = @import("pages.zig");
const ToolDoc = mcp_docs.ToolDoc;
const ParamDoc = mcp_docs.ParamDoc;

const style_block: []const u8 = "<style>" ++
    assets_css.navbar_css ++
    @embedFile("../assets/mcp_docs.css") ++
    "</style>";

const script_block: []const u8 = "<script>" ++
    @embedFile("../assets/mcp_docs.js") ++
    "</script>";

pub const Mcp = struct {
    fn _render(tools: []const ToolDoc, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        _ = &tools;
        try writer.writeAll("<!DOCTYPE html>");
        // mcp_docs.zt:22
        try writer.writeAll("<html>");
        // mcp_docs.zt:23
        try writer.writeAll("<head>");
        // mcp_docs.zt:24
        try writer.writeAll("<title>");
        try writer.writeAll("MCP Tools");
        try writer.writeAll("</title>");
        // mcp_docs.zt:25
        try zt.writeRaw(writer, style_block);
        // mcp_docs.zt:26
        try writer.writeAll("</head>");
        // mcp_docs.zt:27
        try writer.writeAll("<body>");
        // mcp_docs.zt:28
        try zt.renderComponent(home_tmpl.Navbar, .{"mcp"}, writer);
        // mcp_docs.zt:29
        try writer.writeAll("<div class=\"mcp-content\">");
        // mcp_docs.zt:30
        try writer.writeAll("<h1>");
        try writer.writeAll("MCP Tools");
        try writer.writeAll("</h1>");
        // mcp_docs.zt:31
        try writer.writeAll("<p class=\"intro\">");
        try writer.writeAll("Every tool an MCP client (e.g. Claude Code) can call against this server's ");
        try writer.writeAll("<code>");
        try writer.writeAll("/mcp");
        try writer.writeAll("</code>");
        try writer.writeAll(" endpoint. Each entry shows the description, whether the tool mutates project files, its parameters, and an example call.");
        try writer.writeAll("</p>");
        // mcp_docs.zt:32
        try writer.writeAll("<div class=\"intro\">");
        try writer.writeAll("Generated from the same ");
        try writer.writeAll("<code>");
        try writer.writeAll("tools/list");
        try writer.writeAll("</code>");
        try writer.writeAll(" payload the server advertises, so it always matches what is callable.");
        try writer.writeAll("</div>");
        // mcp_docs.zt:33
        try writer.writeAll("<input type=\"text\" class=\"search-box\" id=\"mcp-search\" placeholder=\"Search tools by name or description...\" autofocus>");
        // mcp_docs.zt:36
        try writer.writeAll("<div class=\"count-info\" id=\"count-info\">");
        try writer.writeAll("</div>");
        // mcp_docs.zt:37
        for (tools) |tool| {
            // mcp_docs.zt:38
            try zt.renderComponent(ToolCard, .{tool}, writer);
        }
        // mcp_docs.zt:40
        try writer.writeAll("</div>");
        // mcp_docs.zt:41
        try zt.writeRaw(writer, script_block);
        // mcp_docs.zt:42
        try writer.writeAll("</body>");
        // mcp_docs.zt:43
        try writer.writeAll("</html>");
    }

    fn _signature(_: []const ToolDoc) void {}

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

pub const ToolCard = struct {
    fn _render(tool: ToolDoc, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        _ = &tool;
        // mcp_docs.zt:47
        try writer.writeAll("<div");
        try writer.writeAll(" class=\"tool\"");
        try zt.writeAttr(writer, "data-search", tool.search_text);
        try writer.writeAll(">");
        // mcp_docs.zt:48
        try writer.writeAll("<div class=\"tool-head\">");
        // mcp_docs.zt:49
        try writer.writeAll("<code class=\"tool-name\">");
        try zt.writeEscaped(writer, tool.name);
        try writer.writeAll("</code>");
        // mcp_docs.zt:50
        if (tool.is_mutation) {
            // mcp_docs.zt:51
            try writer.writeAll("<span class=\"badge badge-write\" title=\"Writes project files\">");
            try writer.writeAll("mutation");
            try writer.writeAll("</span>");
        } else {
            // mcp_docs.zt:53
            try writer.writeAll("<span class=\"badge badge-read\" title=\"Read-only\">");
            try writer.writeAll("read-only");
            try writer.writeAll("</span>");
        }
        // mcp_docs.zt:55
        try writer.writeAll("</div>");
        // mcp_docs.zt:56
        try writer.writeAll("<p class=\"tool-desc\">");
        try zt.writeEscaped(writer, tool.description);
        try writer.writeAll("</p>");
        // mcp_docs.zt:57
        if (tool.params.len > 0) {
            // mcp_docs.zt:58
            try writer.writeAll("<table class=\"params\">");
            // mcp_docs.zt:59
            try writer.writeAll("<thead>");
            // mcp_docs.zt:60
            try writer.writeAll("<tr>");
            try writer.writeAll("<th>");
            try writer.writeAll("Parameter");
            try writer.writeAll("</th>");
            try writer.writeAll("<th>");
            try writer.writeAll("Type");
            try writer.writeAll("</th>");
            try writer.writeAll("<th>");
            try writer.writeAll("</th>");
            try writer.writeAll("<th>");
            try writer.writeAll("Description");
            try writer.writeAll("</th>");
            try writer.writeAll("</tr>");
            // mcp_docs.zt:61
            try writer.writeAll("</thead>");
            // mcp_docs.zt:62
            try writer.writeAll("<tbody>");
            // mcp_docs.zt:63
            for (tool.params) |p| {
                // mcp_docs.zt:64
                try zt.renderComponent(ParamRow, .{p}, writer);
            }
            // mcp_docs.zt:66
            try writer.writeAll("</tbody>");
            // mcp_docs.zt:67
            try writer.writeAll("</table>");
        } else {
            // mcp_docs.zt:69
            try writer.writeAll("<p class=\"no-params\">");
            try writer.writeAll("No parameters.");
            try writer.writeAll("</p>");
        }
        // mcp_docs.zt:71
        try writer.writeAll("<div class=\"example-wrap\">");
        // mcp_docs.zt:72
        try writer.writeAll("<span class=\"example-label\">");
        try writer.writeAll("Example");
        try writer.writeAll("</span>");
        // mcp_docs.zt:73
        try writer.writeAll("<pre class=\"example\">");
        try zt.writeEscaped(writer, tool.example);
        try writer.writeAll("</pre>");
        // mcp_docs.zt:74
        try writer.writeAll("</div>");
        // mcp_docs.zt:75
        try writer.writeAll("</div>");
    }

    fn _signature(_: ToolDoc) void {}

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

pub const ParamRow = struct {
    fn _render(p: ParamDoc, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        _ = &p;
        // mcp_docs.zt:79
        try writer.writeAll("<tr>");
        // mcp_docs.zt:80
        try writer.writeAll("<td>");
        try writer.writeAll("<code class=\"param-name\">");
        try zt.writeEscaped(writer, p.name);
        try writer.writeAll("</code>");
        try writer.writeAll("</td>");
        // mcp_docs.zt:81
        try writer.writeAll("<td>");
        try writer.writeAll("<span class=\"param-type\">");
        try zt.writeEscaped(writer, p.type_str);
        try writer.writeAll("</span>");
        try writer.writeAll("</td>");
        // mcp_docs.zt:82
        try writer.writeAll("<td>");
        // mcp_docs.zt:83
        if (p.required) {
            // mcp_docs.zt:84
            try writer.writeAll("<span class=\"req\">");
            try writer.writeAll("required");
            try writer.writeAll("</span>");
        } else {
            // mcp_docs.zt:86
            try writer.writeAll("<span class=\"opt\">");
            try writer.writeAll("optional");
            try writer.writeAll("</span>");
        }
        // mcp_docs.zt:88
        try writer.writeAll("</td>");
        // mcp_docs.zt:89
        try writer.writeAll("<td>");
        // mcp_docs.zt:90
        try zt.writeEscaped(writer, p.description);
        // mcp_docs.zt:91
        if (p.enum_values.len > 0) {
            // mcp_docs.zt:92
            try writer.writeAll("<div class=\"enum\">");
            // mcp_docs.zt:93
            try writer.writeAll("<span class=\"enum-label\">");
            try writer.writeAll("one of:");
            try writer.writeAll("</span>");
            // mcp_docs.zt:94
            for (p.enum_values) |ev| {
                // mcp_docs.zt:95
                try writer.writeAll("<code>");
                try zt.writeEscaped(writer, ev);
                try writer.writeAll("</code>");
            }
            // mcp_docs.zt:97
            try writer.writeAll("</div>");
        }
        // mcp_docs.zt:100
        try writer.writeAll("</td>");
        // mcp_docs.zt:101
        try writer.writeAll("</tr>");
    }

    fn _signature(_: ParamDoc) void {}

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
