//! Deterministic PDF rendering for the authored system-review document.
//!
//! Board-level schematic PDFs keep using `export_pdf.zig`. This composer is
//! intentionally document-oriented: it paginates the safe Markdown text that
//! also ships in the package, adds release furniture and a draft watermark,
//! and leaves high-resolution PCB images as adjacent package evidence rather
//! than rasterising them into an unreadably small page cell.

const std = @import("std");
const pdf = @import("pdf.zig");
const review_md = @import("system_review_md.zig");

const page_w = pdf.a4_landscape_w;
const page_h = pdf.a4_landscape_h;
const margin: f64 = 42;
const content_bottom: f64 = page_h - 34;

fn utf8WrapBoundary(text: []const u8, proposed: usize) usize {
    if (proposed >= text.len) return text.len;
    var boundary = proposed;
    while (boundary > 0 and text[boundary] & 0xc0 == 0x80) boundary -= 1;
    // Malformed input beginning with a continuation byte still has to make
    // progress. Normal package input has already passed UTF-8 validation.
    return if (boundary == 0) proposed else boundary;
}

/// Cover identity and release state for the system-review PDF.
pub const Options = struct {
    title: []const u8,
    identity: []const u8,
    generated_at: []const u8,
    build_id: []const u8,
    draft: bool,
    timestamp: ?[]const u8 = null,
};

/// Errors emitted while composing or structurally validating the review PDF.
pub const Error = pdf.Error || pdf.ValidateError;

const Composer = struct {
    allocator: std.mem.Allocator,
    doc: pdf.Doc,
    page: *pdf.Page,
    opts: Options,
    page_number: usize = 1,
    y: f64 = margin,

    fn nextPage(self: *Composer) !void {
        try self.footer();
        self.page_number += 1;
        self.page = try self.doc.beginPage(page_w, page_h);
        self.y = margin;
        try self.header();
    }

    fn header(self: *Composer) !void {
        try self.page.text(.{ .x = margin, .y = 23 }, self.opts.identity, .{
            .font = .helvetica_bold,
            .size = 8,
            .color = .{ .r = 0.28, .g = 0.31, .b = 0.36 },
        });
        try self.page.line(
            .{ .x = margin, .y = 29 },
            .{ .x = page_w - margin, .y = 29 },
            .{ .color = .{ .r = 0.78, .g = 0.80, .b = 0.83 }, .width = 0.7 },
        );
        self.y = 45;
    }

    fn footer(self: *Composer) !void {
        var number: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&number, "Page {d}", .{self.page_number}) catch "Page";
        try self.page.line(
            .{ .x = margin, .y = page_h - 27 },
            .{ .x = page_w - margin, .y = page_h - 27 },
            .{ .color = .{ .r = 0.82, .g = 0.84, .b = 0.87 }, .width = 0.6 },
        );
        try self.page.text(.{ .x = margin, .y = page_h - 15 }, self.opts.build_id, .{
            .size = 7,
            .color = .{ .r = 0.42, .g = 0.44, .b = 0.48 },
        });
        try self.page.text(.{ .x = page_w - margin, .y = page_h - 15 }, label, .{
            .size = 7,
            .anchor = .end,
            .color = .{ .r = 0.42, .g = 0.44, .b = 0.48 },
        });
    }

    fn ensure(self: *Composer, height: f64) !void {
        if (self.y + height <= content_bottom) return;
        try self.nextPage();
    }

    fn textLine(self: *Composer, raw: []const u8, style: pdf.TextStyle, indent: f64, leading: f64) !void {
        const max_width = page_w - 2 * margin - indent;
        const approx_chars: usize = @max(16, @as(usize, @intFromFloat(max_width / @max(3.8, style.size * 0.53))));
        var rest = std.mem.trim(u8, raw, " \t\r");
        if (rest.len == 0) {
            self.y += leading * 0.55;
            return;
        }
        while (rest.len > 0) {
            var take = utf8WrapBoundary(rest, @min(rest.len, approx_chars));
            if (take < rest.len) {
                if (std.mem.lastIndexOfScalar(u8, rest[0..take], ' ')) |space| {
                    if (space > approx_chars / 3) take = space;
                }
            }
            const line = std.mem.trimEnd(u8, rest[0..take], " \t");
            try self.ensure(leading);
            try self.page.text(.{ .x = margin + indent, .y = self.y }, line, style);
            self.y += leading;
            rest = std.mem.trimStart(u8, rest[take..], " \t");
        }
    }
};

/// Compose the safe, expanded Markdown representation into a searchable PDF.
pub fn compose(allocator: std.mem.Allocator, markdown: []const u8, opts: Options) Error![]u8 {
    var document = pdf.Doc.init(allocator, .{ .title = opts.title, .timestamp = opts.timestamp });
    errdefer document.deinit();
    const first = try document.beginPage(page_w, page_h);
    var c = Composer{ .allocator = allocator, .doc = document, .page = first, .opts = opts };

    try first.text(.{ .x = margin, .y = 82 }, if (opts.draft) "DRAFT - NOT FOR FABRICATION" else "APPROVED RELEASE", .{
        .font = .helvetica_bold,
        .size = 14,
        .color = if (opts.draft) .{ .r = 0.72, .g = 0.10, .b = 0.10 } else .{ .r = 0.06, .g = 0.46, .b = 0.22 },
    });
    try first.text(.{ .x = margin, .y = 125 }, opts.title, .{
        .font = .helvetica_bold,
        .size = 27,
        .color = .{ .r = 0.08, .g = 0.10, .b = 0.14 },
    });
    try first.text(.{ .x = margin, .y = 158 }, opts.identity, .{
        .font = .helvetica,
        .size = 15,
        .color = .{ .r = 0.25, .g = 0.28, .b = 0.33 },
    });
    try first.text(.{ .x = margin, .y = 191 }, opts.generated_at, .{
        .size = 9,
        .color = .{ .r = 0.40, .g = 0.43, .b = 0.48 },
    });
    c.y = 235;

    // This composer lays out Markdown text, not the inline AST, and its text
    // runs carry a single font each — so emphasis is flattened to plain words
    // rather than switched mid-line. What it must never do is print the
    // markers themselves. Fenced code keeps its bytes verbatim.
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(allocator);
    var in_fence = false;

    var lines = std.mem.splitScalar(u8, markdown, '\n');
    while (lines.next()) |raw| {
        const source_line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, std.mem.trim(u8, source_line, " \t"), "```")) in_fence = !in_fence;
        var line = source_line;
        if (!in_fence) {
            plain.clearRetainingCapacity();
            try review_md.stripEmphasis(allocator, &plain, source_line);
            line = plain.items;
        }
        if (std.mem.startsWith(u8, line, "<!--")) continue;
        if (std.mem.startsWith(u8, line, "### ")) {
            c.y += 5;
            try c.textLine(line[4..], .{ .font = .helvetica_bold, .size = 11, .color = .{ .r = 0.10, .g = 0.20, .b = 0.36 } }, 0, 16);
        } else if (std.mem.startsWith(u8, line, "## ")) {
            c.y += 8;
            try c.textLine(line[3..], .{ .font = .helvetica_bold, .size = 14, .color = .{ .r = 0.08, .g = 0.16, .b = 0.30 } }, 0, 20);
        } else if (std.mem.startsWith(u8, line, "# ")) {
            c.y += 9;
            try c.textLine(line[2..], .{ .font = .helvetica_bold, .size = 17, .color = .{ .r = 0.06, .g = 0.12, .b = 0.24 } }, 0, 23);
        } else if (std.mem.startsWith(u8, line, "```")) {
            try c.textLine(line, .{ .font = .courier, .size = 7.5, .color = .{ .r = 0.28, .g = 0.30, .b = 0.34 } }, 12, 10);
        } else if (std.mem.startsWith(u8, line, "|")) {
            try c.textLine(line, .{ .font = .courier, .size = 6.8, .color = .{ .r = 0.18, .g = 0.20, .b = 0.24 } }, 3, 9);
        } else if (std.mem.startsWith(u8, line, "- ") or std.mem.startsWith(u8, line, "* ")) {
            try c.textLine(line, .{ .font = .helvetica, .size = 8.7, .color = .{ .r = 0.12, .g = 0.13, .b = 0.16 } }, 10, 12);
        } else {
            try c.textLine(line, .{ .font = .helvetica, .size = 8.7, .color = .{ .r = 0.12, .g = 0.13, .b = 0.16 } }, 0, 12);
        }
    }
    try c.footer();
    const bytes = try c.doc.finish();
    c.doc.deinit();
    try pdf.validate(bytes);
    return bytes;
}

// spec: system-review - system Markdown becomes a structurally valid searchable PDF with draft marking
test "system review PDF renders draft status and authored text" {
    const allocator = std.testing.allocator;
    const bytes = try compose(allocator, "# Architecture\n\n- RF board\n- Base board\n", .{
        .title = "Barracuda System Review",
        .identity = "OC-303-1-01 / B3",
        .generated_at = "2026-08-29T00:00:00Z",
        .build_id = "test-build",
        .draft = true,
    });
    defer allocator.free(bytes);
    try pdf.validate(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "DRAFT - NOT FOR FABRICATION") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "Architecture") != null);
}

// spec: system-review - the review PDF lays emphasised Markdown out as plain words, printing no emphasis markers outside fenced code
test "system review PDF flattens emphasis and keeps fenced code verbatim" {
    const markdown =
        "# Release **blocked**\n\n" ++
        "- **Item** one and *item* two\n\n" ++
        "```text\n**verbatim**\n```\n";
    const bytes = try compose(std.testing.allocator, markdown, .{
        .title = "Emphasis flattening",
        .identity = "SYS / A",
        .generated_at = "2026-08-29T00:00:00Z",
        .build_id = "test-build",
        .draft = true,
    });
    defer std.testing.allocator.free(bytes);
    try pdf.validate(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "Release blocked") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "Item one and item two") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "**Release") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "**Item") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "**verbatim**") != null);
}

// spec: system-review - long UTF-8 review lines wrap only between complete codepoints in the generated PDF
test "system review PDF wraps long UTF-8 text only between codepoints" {
    var markdown: [166]u8 = undefined;
    @memset(markdown[0..163], 'a');
    markdown[163] = 0xc3;
    markdown[164] = 0xa9;
    markdown[165] = '\n';
    const bytes = try compose(std.testing.allocator, &markdown, .{
        .title = "UTF-8 wrapping",
        .identity = "SYS / A",
        .generated_at = "2026-08-29T00:00:00Z",
        .build_id = "test-build",
        .draft = true,
    });
    defer std.testing.allocator.free(bytes);
    try pdf.validate(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\\351") != null);
}
