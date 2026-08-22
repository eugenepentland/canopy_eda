// Auto-generated from library.zt - do not edit
const std = @import("std");
const zt = @import("zt");

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

pub const Library = struct {
    fn _render(rows: []const LibraryRow, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        _ = &rows;
        try writer.writeAll("<!DOCTYPE html>");
        // library.zt:20
        try writer.writeAll("<html>");
        // library.zt:21
        try writer.writeAll("<head>");
        // library.zt:22
        try writer.writeAll("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1,viewport-fit=cover\">");
        // library.zt:23
        try writer.writeAll("<title>");
        try writer.writeAll("Component Library");
        try writer.writeAll("</title>");
        // library.zt:24
        try zt.writeRaw(writer, style_block);
        // library.zt:25
        try writer.writeAll("</head>");
        // library.zt:26
        try writer.writeAll("<body>");
        // library.zt:27
        try zt.renderComponent(home_tmpl.Navbar, .{"library"}, writer);
        // library.zt:28
        try writer.writeAll("<div class=\"lib-content\">");
        // library.zt:29
        try writer.writeAll("<h1>");
        try writer.writeAll("Component Library");
        try writer.writeAll("</h1>");
        // library.zt:30
        try zt.writeRaw(writer, upload_block);
        // library.zt:31
        try writer.writeAll("<input type=\"text\" class=\"search-box\" id=\"lib-search\" placeholder=\"Search components, footprints, pinouts...\">");
        // library.zt:34
        try writer.writeAll("<div class=\"count-info\" id=\"count-info\">");
        try writer.writeAll("</div>");
        // library.zt:35
        try writer.writeAll("<div class=\"card-grid\" id=\"lib-grid\">");
        // library.zt:36
        for (rows) |row| {
            // library.zt:37
            try zt.renderComponent(Card, .{row}, writer);
        }
        // library.zt:39
        try writer.writeAll("</div>");
        // library.zt:40
        try writer.writeAll("<div class=\"pagination\" id=\"pagination\">");
        // library.zt:41
        try writer.writeAll("<button id=\"page-prev\">");
        try writer.writeAll("&larr; Prev");
        try writer.writeAll("</button>");
        // library.zt:42
        try writer.writeAll("<span class=\"page-info\" id=\"page-info\">");
        try writer.writeAll("</span>");
        // library.zt:43
        try writer.writeAll("<button id=\"page-next\">");
        try writer.writeAll("Next &rarr;");
        try writer.writeAll("</button>");
        // library.zt:44
        try writer.writeAll("</div>");
        // library.zt:45
        try writer.writeAll("<datalist id=\"lib-ds-options\">");
        try writer.writeAll("</datalist>");
        // library.zt:46
        try writer.writeAll("</div>");
        // library.zt:47
        try zt.writeRaw(writer, courtyard_modal_block);
        // library.zt:48
        try writer.writeAll("<script src=\"/static/footprint_svg.js\">");
        try writer.writeAll("</script>");
        // library.zt:49
        try writer.writeAll("<script src=\"/static/library.js\">");
        try writer.writeAll("</script>");
        // library.zt:50
        try writer.writeAll("</body>");
        // library.zt:51
        try writer.writeAll("</html>");
    }

    fn _signature(_: []const LibraryRow) void {}

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

pub const Card = struct {
    fn _render(row: LibraryRow, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        _ = &row;
        // library.zt:55
        try writer.writeAll("<div");
        try writer.writeAll(" class=\"comp-card\"");
        try zt.writeAttr(writer, "data-search", row.search_text);
        try zt.writeAttr(writer, "data-kind", @tagName(row.kind));
        try zt.writeAttr(writer, "data-name", row.name);
        try zt.writeAttr(writer, "data-component", if (row.kind == .component or row.kind == .family) row.name else null);
        try writer.writeAll(">");
        // library.zt:56
        try writer.writeAll("<div class=\"card-head\">");
        // library.zt:57
        try writer.writeAll("<span class=\"card-name\">");
        try zt.writeEscaped(writer, row.name);
        try writer.writeAll("</span>");
        // library.zt:58
        switch (row.kind) {
            .component => {
                // library.zt:59
                try writer.writeAll("<span class=\"tag tag-component\">");
                try writer.writeAll("component");
                try writer.writeAll("</span>");
            },
            .family => {
                // library.zt:60
                try writer.writeAll("<span class=\"tag tag-family\">");
                try writer.writeAll("family");
                try writer.writeAll("</span>");
            },
            .pinout => {
                // library.zt:61
                try writer.writeAll("<span class=\"tag tag-pinout\">");
                try writer.writeAll("pinout");
                try writer.writeAll("</span>");
            },
            .footprint => {
                // library.zt:62
                try writer.writeAll("<span class=\"tag tag-footprint\">");
                try writer.writeAll("footprint");
                try writer.writeAll("</span>");
            },
        }
        // library.zt:64
        try writer.writeAll("<span class=\"card-del\" title=\"Delete from library\">");
        try writer.writeAll("×");
        try writer.writeAll("</span>");
        // library.zt:65
        try writer.writeAll("</div>");
        // library.zt:66
        switch (row.kind) {
            .family, .component => {
                // library.zt:68
                try zt.renderComponent(ComponentDetails, .{row}, writer);
            },
            .pinout => {
                // library.zt:71
                if (row.pin_count) |pc| {
                    // library.zt:72
                    try writer.writeAll("<div class=\"card-desc\">");
                    try zt.writeEscaped(writer, pc);
                    try writer.writeAll(" pins");
                    try writer.writeAll("</div>");
                }
            },
            .footprint => {
                // library.zt:77
                try writer.writeAll("<span");
                try writer.writeAll(" class=\"tag tag-footprint fp-toggle\"");
                try zt.writeAttr(writer, "data-fp", row.name);
                try writer.writeAll(" title=\"Show footprint preview\"");
                try writer.writeAll(">");
                try writer.writeAll("show preview ›");
                try writer.writeAll("</span>");
                // library.zt:78
                if (row.has_3d_model) {
                    // library.zt:79
                    try writer.writeAll("<a");
                    try writer.writeAll(" class=\"badge-3d\"");
                    try writer.writeAll(" href=\"");
                    try writer.writeAll("/library/3d/");
                    try zt.writeEscaped(writer, row.name);
                    try writer.writeAll("\"");
                    try writer.writeAll(" title=\"Align 3D model orientation\"");
                    try writer.writeAll(">");
                    try writer.writeAll("3D");
                    try writer.writeAll("</a>");
                }
                // library.zt:82
                try writer.writeAll("<div");
                try writer.writeAll(" class=\"fp-preview\"");
                try zt.writeAttr(writer, "data-fp", row.name);
                try writer.writeAll(">");
                try writer.writeAll("</div>");
            },
        }
        // library.zt:85
        if (row.requirements.len > 0) {
            // library.zt:86
            try writer.writeAll("<span class=\"req-toggle\">");
            try writer.writeAll("⚑ ");
            try zt.writeEscaped(writer, row.requirements.len);
            try writer.writeAll(" requirements ›");
            try writer.writeAll("</span>");
            // library.zt:87
            try writer.writeAll("<div class=\"req-cards\">");
            // library.zt:88
            for (row.requirements) |req| {
                // library.zt:89
                try writer.writeAll("<div class=\"req-item\">");
                try zt.writeEscaped(writer, req);
                try writer.writeAll("</div>");
            }
            // library.zt:91
            try writer.writeAll("</div>");
        }
        // library.zt:94
        try writer.writeAll("</div>");
    }

    fn _signature(_: LibraryRow) void {}

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

pub const ComponentDetails = struct {
    fn _render(row: LibraryRow, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        _ = &row;
        // library.zt:98
        if (row.description) |d| {
            // library.zt:99
            try writer.writeAll("<div class=\"card-desc\">");
            try zt.writeEscaped(writer, d);
            try writer.writeAll("</div>");
        }
        // library.zt:102
        try writer.writeAll("<div class=\"card-tags\">");
        // library.zt:103
        if (row.footprint) |fp| {
            // library.zt:104
            try writer.writeAll("<span");
            try writer.writeAll(" class=\"tag tag-footprint fp-toggle\"");
            try zt.writeAttr(writer, "data-fp", fp);
            try writer.writeAll(" title=\"Show footprint preview\"");
            try writer.writeAll(">");
            try zt.writeEscaped(writer, fp);
            try writer.writeAll("</span>");
            // library.zt:105
            if (row.has_3d_model) {
                // library.zt:106
                try writer.writeAll("<a");
                try writer.writeAll(" class=\"badge-3d\"");
                try writer.writeAll(" href=\"");
                try writer.writeAll("/library/3d/");
                try zt.writeEscaped(writer, fp);
                try writer.writeAll("\"");
                try writer.writeAll(" title=\"Align 3D model orientation\"");
                try writer.writeAll(">");
                try writer.writeAll("3D");
                try writer.writeAll("</a>");
            }
        }
        // library.zt:111
        if (row.pinout) |po| {
            // library.zt:112
            try writer.writeAll("<span class=\"tag tag-pinout\">");
            try zt.writeEscaped(writer, po);
            try writer.writeAll("</span>");
        }
        // library.zt:115
        try writer.writeAll("</div>");
        // library.zt:116
        if (row.manufacturer) |m| {
            // library.zt:117
            try writer.writeAll("<div class=\"card-meta\">");
            try zt.writeEscaped(writer, m);
            try writer.writeAll("</div>");
        }
        // library.zt:120
        if (row.mpn) |m| {
            // library.zt:121
            try writer.writeAll("<div class=\"card-meta\">");
            try zt.writeEscaped(writer, m);
            try writer.writeAll("</div>");
        }
        // library.zt:124
        if (row.datasheets.len > 0) {
            // library.zt:125
            try writer.writeAll("<div class=\"card-tags\">");
            // library.zt:126
            for (row.datasheets) |ds| {
                // library.zt:127
                if (ds.present) {
                    // library.zt:128
                    try writer.writeAll("<a");
                    try writer.writeAll(" class=\"tag tag-datasheet\"");
                    try writer.writeAll(" href=\"");
                    try writer.writeAll("/datasheets/");
                    try zt.writeEscaped(writer, ds.name);
                    try writer.writeAll("\"");
                    try writer.writeAll(" target=\"_blank\"");
                    try writer.writeAll(" rel=\"noopener\"");
                    try writer.writeAll(" title=\"Open PDF\"");
                    try writer.writeAll(">");
                    try writer.writeAll("📄 ");
                    try zt.writeEscaped(writer, ds.name);
                    try writer.writeAll("</a>");
                } else {
                    // library.zt:130
                    try writer.writeAll("<span class=\"tag tag-datasheet-missing\" title=\"PDF declared but not uploaded\">");
                    try writer.writeAll("📄 ");
                    try zt.writeEscaped(writer, ds.name);
                    try writer.writeAll(" (missing)");
                    try writer.writeAll("</span>");
                }
            }
            // library.zt:133
            try writer.writeAll("</div>");
        }
        // library.zt:136
        try writer.writeAll("<div class=\"ds-attach\">");
        // library.zt:137
        try writer.writeAll("<span class=\"ds-attach-toggle\" title=\"Link an already-uploaded PDF (lib/datasheets/) to this part\">");
        try writer.writeAll("📎 attach datasheet");
        try writer.writeAll("</span>");
        // library.zt:138
        try writer.writeAll("<span class=\"ds-attach-row\" hidden>");
        // library.zt:139
        try writer.writeAll("<input type=\"text\" class=\"ds-attach-input\" list=\"lib-ds-options\" placeholder=\"uploaded PDF…\">");
        // library.zt:140
        try writer.writeAll("<button class=\"ds-attach-btn\" type=\"button\">");
        try writer.writeAll("Attach");
        try writer.writeAll("</button>");
        // library.zt:141
        try writer.writeAll("</span>");
        // library.zt:142
        try writer.writeAll("</div>");
        // library.zt:143
        if (row.footprint) |fp| {
            // library.zt:144
            try writer.writeAll("<div");
            try writer.writeAll(" class=\"fp-preview\"");
            try zt.writeAttr(writer, "data-fp", fp);
            try writer.writeAll(">");
            try writer.writeAll("</div>");
        }
    }

    fn _signature(_: LibraryRow) void {}

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
