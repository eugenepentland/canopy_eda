//! Strict translator from the schematic renderer's closed SVG subset to a flat
//! display list of resolved `DrawOp`s — the WP-B half of the PDF export
//! (`docs/archive/pdf-export-plan.md`). It deliberately does NOT depend on `pdf.zig`:
//! the output is pure data, so the writer and the translator stay independently
//! testable and the composer (WP-C) is the only place that maps one onto the
//! other.
//!
//! The input is not general SVG — it is exactly what `src/render_svg/*.zig`
//! emits through `render_html.renderHubSvg` (elements `svg`/`g`/`line`/
//! `polyline`/`polygon`/`rect`/`circle`/`path`/`text`/`title`, plus the exact
//! `rotate(angle cx cy)` group transform used for vertical passives; no tspan
//! or rotated text). Everything else is a hard error carrying the byte
//! offset, so a renderer change outside the subset breaks the build loudly
//! instead of silently rendering wrong — the same philosophy as docgen's
//! `requireAllDocumented`.
//!
//! Styling is resolved here: the class table below mirrors the nine rules of
//! `render_html.static_svg_css` (a test parses that string and asserts the two
//! agree) with two palettes — `.screen` reproduces the dark web colours
//! verbatim, `.print` assumes a white page. Inline `stroke=`/`fill=`/
//! `font-size=`/`text-anchor=` attributes override the class style. No classes
//! or CSS survive into a `DrawOp`.
//!
//! ARENA-CONTRACT: every `DrawOp` payload (point arrays, decoded text) is
//! allocated from the caller's allocator and never individually freed. Pass an
//! arena and drop it — that is the pattern the render/review paths already use.

const std = @import("std");
const Allocator = std.mem.Allocator;
const escape = @import("escape.zig");

/// Expand the entity set `escape.writeXml` produces — the exact inverse of the
/// escaper the SVG this module reads was written with.
const decodeEntities = escape.decodeXmlAlloc;

// ── Display list ──────────────────────────────────────────────────────────

/// A resolved 8-bit-per-channel colour. No named colours or CSS survive here.
pub const Rgb = struct { r: u8, g: u8, b: u8 };

/// A point in the SVG user-space frame the document's viewBox declares (y grows
/// down — the composer converts to PDF's y-up frame).
pub const Pt = struct { x: f64, y: f64 };

/// A resolved stroke: colour plus width in user-space units.
pub const Stroke = struct { color: Rgb, width: f64 };

/// Horizontal text alignment about the anchor point. `start` is SVG's default
/// (an absent `text-anchor`).
pub const Anchor = enum { start, middle, end };

/// Which palette the class table resolves to: the dark web colours, or a
/// light-page print palette.
pub const Theme = enum { screen, print };

/// A CSS `fill` slot: never declared, explicitly `none`/`transparent`, or a
/// colour. `unset` and `none` differ during resolution (an inline `fill` can
/// override a class `fill:none`, and an element with neither gets its
/// per-element default).
pub const Fill = union(enum) { unset, none, color: Rgb };

/// A straight segment from `a` to `b`.
pub const Line = struct { a: Pt, b: Pt, stroke: Stroke };

/// An open stroked path through `points` (the Manhattan H-V-H wire form).
pub const Polyline = struct { points: []const Pt, stroke: Stroke };

/// A closed shape: filled, stroked, or both.
pub const Polygon = struct { points: []const Pt, fill: ?Rgb, stroke: ?Stroke };

/// An axis-aligned box with optional corner radius `rx` (0 = square corners).
pub const Rect = struct { x: f64, y: f64, w: f64, h: f64, rx: f64, fill: ?Rgb, stroke: ?Stroke };

/// A circle of radius `r` centred on `c`.
pub const Circle = struct { c: Pt, r: f64, fill: ?Rgb, stroke: ?Stroke };

/// The single emitted arc form (`draw.zig` inductor bump):
/// `M x1 y1 A rx ry 0 0 1 x2 y2`. The parameters are preserved verbatim;
/// downstream approximates the sweep with Béziers.
pub const Arc = struct { from: Pt, to: Pt, rx: f64, ry: f64, sweep_cw: bool, stroke: Stroke };

/// A run of text with everything resolved: absolute anchor point, decoded
/// content (XML entities expanded), colour, size in user-space units.
pub const Text = struct { at: Pt, s: []const u8, fill: Rgb, size: f64, anchor: Anchor, bold: bool };

/// One resolved drawing primitive. Absolute coordinates, resolved colours — no
/// classes, no inheritance, nothing left for a consumer to interpret.
pub const DrawOp = union(enum) {
    line: Line,
    polyline: Polyline,
    polygon: Polygon,
    rect: Rect,
    circle: Circle,
    arc: Arc,
    text: Text,
};

/// One translated `<svg>` element: its viewBox frame plus the display list.
pub const Document = struct {
    min_x: f64,
    min_y: f64,
    width: f64,
    height: f64,
    ops: []const DrawOp,
    /// The `<h4 class="hub-group-label">` heading `renderHubSvg` writes above
    /// this document's `<svg>` in a multi-group hub render — entity-decoded,
    /// or "" for a document with no preceding label.
    title: []const u8 = "",
};

/// Translator options. `theme` picks which palette the class table resolves to.
pub const Options = struct { theme: Theme = .print };

/// Where a strict-mode rejection happened: the byte offset into the input and
/// the offending token (a slice of the input, or a static description).
pub const Diagnostic = struct { offset: usize = 0, token: []const u8 = "" };

/// Strict-mode rejections. Every one is a renderer-drift signal, not a
/// recoverable condition — the caller's job is to report it, not to patch over
/// it.
pub const Error = error{
    /// An element outside the subset (`use`, `tspan`, a comment, a doctype…).
    UnknownElement,
    /// A `class=` naming something the style table doesn't know.
    UnknownClass,
    /// An attribute the element is not allowed to carry, or a `style=` whose
    /// content isn't one of the two emitted forms.
    UnknownAttribute,
    /// A colour that is neither `#rgb`/`#rrggbb` nor a supported keyword.
    UnknownColor,
    /// A coordinate/length that doesn't parse, or isn't finite.
    BadNumber,
    /// Path data outside the single emitted `M … A …` arc form.
    BadPathData,
    /// Group transform outside the emitted `rotate(angle cx cy)` form.
    BadTransform,
    /// Malformed markup: an unterminated tag, a stray close, a missing `</text>`.
    BadTag,
    /// The input's first element isn't `<svg>`.
    NoSvgRoot,
    /// `<g>` nesting deeper than the subset ever produces.
    TooDeep,
    /// A required attribute (`viewBox`, `points`, `d`, a coordinate) is absent.
    MissingAttribute,
} || Allocator.Error;

// ── Style table (mirrors render_html.static_svg_css) ──────────────────────

/// The paint properties one CSS rule contributes. `null`/`unset` means the rule
/// says nothing about that property, so resolution falls through to the inline
/// attributes and then to the per-element default.
const Paint = struct {
    fill: Fill = .unset,
    stroke: ?Rgb = null,
    stroke_width: ?f64 = null,
    font_size: ?f64 = null,
};

fn rgb(r: u8, g: u8, b: u8) Rgb {
    return .{ .r = r, .g = g, .b = b };
}

/// One `static_svg_css` rule, mirrored. `selector` is the rule's selector list
/// verbatim (the sync test compares it against the CSS text); `class` +
/// `elements` are the parsed form resolution uses; `screen`/`print` are the two
/// palettes. A rule with no paint in either palette (the `svg.hub-inset` layout
/// rule) contributes nothing but must still be listed so the sync test's
/// rule-for-rule walk lines up.
const Rule = struct {
    selector: []const u8,
    class: []const u8,
    elements: []const []const u8,
    screen: Paint,
    print: Paint,
};

/// The nine rules of `render_html.static_svg_css`, in source order. The print
/// palette keeps every semantic distinction the screen palette draws — a
/// component box still reads as a tinted box with a blue border, net wires stay
/// a neutral grey, net labels stay blue, pin labels stay near-black — but
/// assumes a white page, so fills lighten and strokes/text darken.
const rules = [_]Rule{
    // Layout only (display/width/max-width/height): contributes no paint.
    .{ .selector = "svg.hub-inset", .class = "hub-inset", .elements = &.{""}, .screen = .{}, .print = .{} },
    .{
        .selector = "svg .component rect",
        .class = "component",
        .elements = &.{"rect"},
        .screen = .{
            .fill = .{ .color = rgb(0x16, 0x21, 0x3e) },
            .stroke = rgb(0x4a, 0x9e, 0xff),
            .stroke_width = 1.5,
        },
        .print = .{
            .fill = .{ .color = rgb(0xf2, 0xf6, 0xfc) },
            .stroke = rgb(0x0b, 0x4f, 0x9e),
            .stroke_width = 1.5,
        },
    },
    .{
        .selector = "svg .component text",
        .class = "component",
        .elements = &.{"text"},
        .screen = .{ .fill = .{ .color = rgb(0xe6, 0xe6, 0xe6) } },
        .print = .{ .fill = .{ .color = rgb(0x11, 0x11, 0x11) } },
    },
    .{
        .selector = "svg .pin-stub line",
        .class = "pin-stub",
        .elements = &.{"line"},
        .screen = .{ .stroke = rgb(0x6e, 0x76, 0x81), .stroke_width = 1 },
        .print = .{ .stroke = rgb(0x44, 0x44, 0x44), .stroke_width = 1 },
    },
    .{
        .selector = "svg .pin-stub text",
        .class = "pin-stub",
        .elements = &.{"text"},
        .screen = .{ .fill = .{ .color = rgb(0xc9, 0xd1, 0xd9) }, .font_size = 11 },
        .print = .{ .fill = .{ .color = rgb(0x22, 0x22, 0x22) }, .font_size = 11 },
    },
    .{
        .selector = "svg .net line,svg .net polyline",
        .class = "net",
        .elements = &.{ "line", "polyline" },
        .screen = .{ .fill = .none, .stroke = rgb(0x8b, 0x94, 0x9e), .stroke_width = 1.2 },
        .print = .{ .fill = .none, .stroke = rgb(0x33, 0x33, 0x33), .stroke_width = 1.2 },
    },
    .{
        .selector = "svg .net text",
        .class = "net",
        .elements = &.{"text"},
        .screen = .{ .fill = .{ .color = rgb(0x79, 0xc0, 0xff) }, .font_size = 10 },
        .print = .{ .fill = .{ .color = rgb(0x0b, 0x4f, 0x9e) }, .font_size = 10 },
    },
    .{
        .selector = "svg .passive rect,svg .passive circle,svg .passive line",
        .class = "passive",
        .elements = &.{ "rect", "circle", "line" },
        .screen = .{ .fill = .none, .stroke = rgb(0x8b, 0x94, 0x9e) },
        .print = .{ .fill = .none, .stroke = rgb(0x33, 0x33, 0x33) },
    },
    .{
        .selector = "svg .passive text",
        .class = "passive",
        .elements = &.{"text"},
        .screen = .{ .fill = .{ .color = rgb(0xc9, 0xd1, 0xd9) }, .font_size = 10 },
        .print = .{ .fill = .{ .color = rgb(0x22, 0x22, 0x22) }, .font_size = 10 },
    },
};

/// Classes the subset uses that carry no style rule: the two skip markers.
const skip_classes = [_][]const u8{ "hit-area", "debug-pin" };

/// Print equivalents for the inline colour literals the emitters hardcode. The
/// mapping is by literal so each keeps its meaning on paper (the GND/label
/// amber stays amber, just dark enough to read); anything unlisted falls back to
/// `darkenForPrint`.
const print_colors = [_]struct { screen: Rgb, print: Rgb }{
    .{ .screen = rgb(0x44, 0xaa, 0x99), .print = rgb(0x1f, 0x5f, 0x54) }, // #4a9 net wire
    .{ .screen = rgb(0x88, 0x88, 0xcc), .print = rgb(0x33, 0x33, 0x6e) }, // passive symbol
    .{ .screen = rgb(0xe8, 0xc5, 0x47), .print = rgb(0x8a, 0x63, 0x00) }, // GND / net label
    .{ .screen = rgb(0x4a, 0x9e, 0xff), .print = rgb(0x0b, 0x4f, 0x9e) }, // port label / hub border
    .{ .screen = rgb(0x16, 0x21, 0x3e), .print = rgb(0xf2, 0xf6, 0xfc) }, // hub box fill
    .{ .screen = rgb(0x3a, 0x3a, 0x5a), .print = rgb(0xe4, 0xe4, 0xf2) }, // ferrite body fill
    .{ .screen = rgb(0x2a, 0x2a, 0x4a), .print = rgb(0xec, 0xec, 0xf7) }, // default symbol fill
    .{ .screen = rgb(0x6e, 0x76, 0x81), .print = rgb(0x44, 0x44, 0x44) }, // stub bus
    .{ .screen = rgb(0x66, 0x66, 0x66), .print = rgb(0x55, 0x55, 0x55) }, // #666 stub line / pin no.
    .{ .screen = rgb(0xaa, 0xaa, 0xaa), .print = rgb(0x22, 0x22, 0x22) }, // #aaa pin label
    .{ .screen = rgb(0x88, 0x88, 0x88), .print = rgb(0x44, 0x44, 0x44) }, // #888 passive value
    .{ .screen = rgb(0x55, 0x55, 0x55), .print = rgb(0x66, 0x66, 0x66) }, // #555 no-connect X
    .{ .screen = rgb(0xff, 0x00, 0x00), .print = rgb(0xcc, 0x00, 0x00) }, // `red` debug pin
};

/// Colour keywords the subset uses. `transparent` is the hit-area marker and is
/// handled as a skip before it reaches colour resolution.
const named_colors = [_]struct { name: []const u8, value: Rgb }{
    .{ .name = "red", .value = rgb(0xff, 0x00, 0x00) },
    .{ .name = "black", .value = rgb(0x00, 0x00, 0x00) },
    .{ .name = "white", .value = rgb(0xff, 0xff, 0xff) },
};

/// Perceptual-ish luminance above which a colour is too light for a white page.
const print_lum_ceiling: f64 = 0.5;
/// Luminance an over-light colour is scaled down to.
const print_lum_target: f64 = 0.28;

/// Fallback print mapping for a colour the literal table doesn't name: a light
/// colour is scaled down to a legible luminance (hue preserved), a dark one is
/// already fine on a white page and passes through.
fn darkenForPrint(c: Rgb) Rgb {
    const lum = (0.2126 * @as(f64, @floatFromInt(c.r)) +
        0.7152 * @as(f64, @floatFromInt(c.g)) +
        0.0722 * @as(f64, @floatFromInt(c.b))) / 255.0;
    if (lum <= print_lum_ceiling or lum == 0) return c;
    const k = print_lum_target / lum;
    return .{ .r = scaleChannel(c.r, k), .g = scaleChannel(c.g, k), .b = scaleChannel(c.b, k) };
}

fn scaleChannel(v: u8, k: f64) u8 {
    const scaled = @as(f64, @floatFromInt(v)) * k;
    return @intFromFloat(std.math.clamp(scaled, 0, 255));
}

/// Map a colour parsed off an inline attribute into the active palette.
fn themeColor(theme: Theme, c: Rgb) Rgb {
    if (theme == .screen) return c;
    for (print_colors) |m| {
        if (std.meta.eql(m.screen, c)) return m.print;
    }
    return darkenForPrint(c);
}

/// Per-element fallbacks for a shape/text with neither a class rule nor an
/// inline colour. Text falls back to the theme's body colour; shapes to its
/// line colour.
fn defaultInk(theme: Theme) Rgb {
    return switch (theme) {
        .screen => rgb(0xc9, 0xd1, 0xd9),
        .print => rgb(0x22, 0x22, 0x22),
    };
}

/// Font size used when neither a class rule nor a `font-size=` attribute says.
const default_font_size: f64 = 10;
/// Stroke width used when nothing declares one.
const default_stroke_width: f64 = 1;

// ── Public entry points ───────────────────────────────────────────────────

/// Translate one `<svg>` document. `svg` must start (after leading whitespace)
/// with the root `<svg>` tag; trailing bytes after `</svg>` are ignored.
/// On error, `diag` (when given) receives the byte offset and offending token.
pub fn translate(gpa: Allocator, svg: []const u8, opts: Options, diag: ?*Diagnostic) Error!Document {
    var p: Parser = .{ .src = svg, .gpa = gpa, .theme = opts.theme, .diag = diag };
    return p.run();
}

/// Translate every `<svg>` element in `markup`, ignoring whatever sits between
/// them. `render_html.renderHubSvg` wraps a multi-group hub's SVGs in
/// `<div class="hub-group-block">`/`<h4>` HTML, so a per-hub render is a
/// sequence of documents, not one.
pub fn translateAll(gpa: Allocator, markup: []const u8, opts: Options, diag: ?*Diagnostic) Error![]Document {
    var out: std.ArrayList(Document) = .empty;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, markup, at, "<svg")) |start| {
        const end = std.mem.indexOfPos(u8, markup, start, "</svg>") orelse {
            if (diag) |d| d.* = .{ .offset = start, .token = "svg" };
            return error.BadTag;
        };
        const stop = end + "</svg>".len;
        var p: Parser = .{ .src = markup[start..stop], .gpa = gpa, .theme = opts.theme, .diag = diag, .base = start };
        var doc = try p.run();
        doc.title = try groupTitle(gpa, markup[at..start]);
        try out.append(gpa, doc);
        at = stop;
    }
    return out.toOwnedSlice(gpa);
}

/// The pin-group label sitting in the HTML `gap` between the previous
/// document and the next `<svg>` — the `<h4 class="hub-group-label">` heading
/// `renderHubSvg` writes above each block of a multi-group hub. Returns the
/// entity-decoded text of the LAST such heading in the gap (the one adjacent
/// to the svg), or "" when the gap carries none.
fn groupTitle(gpa: Allocator, gap: []const u8) Allocator.Error![]const u8 {
    const open = "<h4 class=\"hub-group-label\">";
    const start = std.mem.lastIndexOf(u8, gap, open) orelse return "";
    const from = start + open.len;
    const close = std.mem.indexOfPos(u8, gap, from, "</h4>") orelse return "";
    return decodeEntities(gpa, gap[from..close]);
}

// ── Scanner ───────────────────────────────────────────────────────────────

const max_attrs = 16;
const max_class_depth = 8;

/// One attribute as scanned: name, raw (still-escaped) value, and the byte
/// offset of the name for diagnostics.
const Attr = struct { name: []const u8 = "", value: []const u8 = "", at: usize = 0 };

/// One scanned start/end tag. The attribute slots are zero-initialised rather
/// than `undefined` so a scanner bug can never read uninitialised memory.
const Tag = struct {
    name: []const u8,
    attrs: [max_attrs]Attr = @splat(.{}),
    n: usize = 0,
    self_close: bool = false,
    closing: bool = false,
    at: usize = 0,
};

/// Enclosing `<g class=…>` classes, innermost last.
const ClassStack = struct {
    items: [max_class_depth][]const u8 = @splat(""),
    n: usize = 0,
};

const Transform = struct {
    a: f64 = 1,
    b: f64 = 0,
    c: f64 = 0,
    d: f64 = 1,
    e: f64 = 0,
    f: f64 = 0,

    fn point(self: Transform, p: Pt) Pt {
        return .{
            .x = self.a * p.x + self.c * p.y + self.e,
            .y = self.b * p.x + self.d * p.y + self.f,
        };
    }

    fn isIdentity(self: Transform) bool {
        return self.a == 1 and self.b == 0 and self.c == 0 and self.d == 1 and self.e == 0 and self.f == 0;
    }
};

/// Compose two affine transforms so `local` is applied first and `parent`
/// second, matching nested SVG group semantics.
fn compose(parent: Transform, local: Transform) Transform {
    return .{
        .a = parent.a * local.a + parent.c * local.b,
        .b = parent.b * local.a + parent.d * local.b,
        .c = parent.a * local.c + parent.c * local.d,
        .d = parent.b * local.c + parent.d * local.d,
        .e = parent.a * local.e + parent.c * local.f + parent.e,
        .f = parent.b * local.e + parent.d * local.f + parent.f,
    };
}

fn transformPoints(points: []Pt, xf: Transform) void {
    if (xf.isIdentity()) return;
    for (points) |*point| point.* = xf.point(point.*);
}

const Parser = struct {
    src: []const u8,
    i: usize = 0,
    gpa: Allocator,
    theme: Theme,
    diag: ?*Diagnostic,
    /// Offset of `src` inside the caller's buffer, so diagnostics from
    /// `translateAll` point at the original markup.
    base: usize = 0,
    ops: std.ArrayList(DrawOp) = .empty,
    classes: ClassStack = .{},
    transforms: [max_class_depth]Transform = @splat(.{}),

    fn fail(self: *Parser, e: Error, at: usize, token: []const u8) Error {
        if (self.diag) |d| d.* = .{ .offset = self.base + at, .token = token };
        return e;
    }

    fn skipSpace(self: *Parser) void {
        while (self.i < self.src.len and std.ascii.isWhitespace(self.src[self.i])) self.i += 1;
    }

    /// Scan forward to the next tag, ignoring inter-element text (the emitters
    /// only put newlines and indentation there). Returns null at end of input.
    fn nextTag(self: *Parser) Error!?Tag {
        const lt = std.mem.indexOfScalarPos(u8, self.src, self.i, '<') orelse {
            self.i = self.src.len;
            return null;
        };
        self.i = lt + 1;
        var t: Tag = .{ .name = "", .at = lt };
        if (self.i < self.src.len and self.src[self.i] == '/') {
            t.closing = true;
            self.i += 1;
        }
        t.name = self.scanName();
        if (t.name.len == 0) return self.fail(error.BadTag, lt, "<");
        try self.scanAttrs(&t);
        return t;
    }

    fn scanName(self: *Parser) []const u8 {
        const start = self.i;
        while (self.i < self.src.len and isNameChar(self.src[self.i])) self.i += 1;
        return self.src[start..self.i];
    }

    fn scanAttrs(self: *Parser, t: *Tag) Error!void {
        while (true) {
            self.skipSpace();
            if (self.i >= self.src.len) return self.fail(error.BadTag, t.at, t.name);
            const c = self.src[self.i];
            if (c == '>') {
                self.i += 1;
                return;
            }
            if (c == '/') {
                self.i += 1;
                if (self.i >= self.src.len or self.src[self.i] != '>') return self.fail(error.BadTag, t.at, t.name);
                self.i += 1;
                t.self_close = true;
                return;
            }
            try self.scanOneAttr(t);
        }
    }

    fn scanOneAttr(self: *Parser, t: *Tag) Error!void {
        const name_at = self.i;
        const name = self.scanName();
        if (name.len == 0) return self.fail(error.BadTag, name_at, "attribute");
        self.skipSpace();
        if (self.i >= self.src.len or self.src[self.i] != '=') return self.fail(error.BadTag, name_at, name);
        self.i += 1;
        self.skipSpace();
        if (self.i >= self.src.len or self.src[self.i] != '"') return self.fail(error.BadTag, name_at, name);
        self.i += 1;
        const vstart = self.i;
        const vend = std.mem.indexOfScalarPos(u8, self.src, self.i, '"') orelse
            return self.fail(error.BadTag, name_at, name);
        self.i = vend + 1;
        if (t.n >= max_attrs) return self.fail(error.UnknownAttribute, name_at, name);
        t.attrs[t.n] = .{ .name = name, .value = self.src[vstart..vend], .at = name_at };
        t.n += 1;
    }

    fn attrOf(_: *Parser, t: Tag, name: []const u8) ?[]const u8 {
        for (t.attrs[0..t.n]) |a| {
            if (std.mem.eql(u8, a.name, name)) return a.value;
        }
        return null;
    }

    // ── Driver ────────────────────────────────────────────────────────────

    fn run(self: *Parser) Error!Document {
        const root = (try self.nextTag()) orelse return self.fail(error.NoSvgRoot, 0, "");
        if (root.closing or !std.mem.eql(u8, root.name, "svg")) {
            return self.fail(error.NoSvgRoot, root.at, root.name);
        }
        try self.checkAttrs(root);
        if (self.attrOf(root, "class")) |c| try self.checkClass(c, root.at);
        const vb = self.attrOf(root, "viewBox") orelse
            return self.fail(error.MissingAttribute, root.at, "viewBox");
        var box: [4]f64 = @splat(0);
        try self.numberList(vb, root.at, &box);
        try self.body();
        return .{
            .min_x = box[0],
            .min_y = box[1],
            .width = box[2],
            .height = box[3],
            .ops = try self.ops.toOwnedSlice(self.gpa),
        };
    }

    /// Walk the root's children until `</svg>`.
    fn body(self: *Parser) Error!void {
        while (try self.nextTag()) |t| {
            if (!t.closing) {
                try self.element(t);
                continue;
            }
            if (std.mem.eql(u8, t.name, "svg")) return;
            if (std.mem.eql(u8, t.name, "g")) {
                if (self.classes.n == 0) return self.fail(error.BadTag, t.at, t.name);
                self.classes.n -= 1;
                continue;
            }
            return self.fail(error.BadTag, t.at, t.name);
        }
        return self.fail(error.BadTag, self.src.len, "svg");
    }

    fn element(self: *Parser, t: Tag) Error!void {
        if (std.mem.eql(u8, t.name, "title")) return self.skipTitle(t);
        try self.checkAttrs(t);
        if (self.attrOf(t, "class")) |c| try self.checkClass(c, t.at);
        // Evaluated before the `<g>` branch so a container's `style=` is
        // validated too, not just a shape's.
        const skip = try self.shouldSkip(t);
        if (std.mem.eql(u8, t.name, "g")) return self.openGroup(t, skip);
        if (std.mem.eql(u8, t.name, "text")) return self.textElement(t, skip);
        if (skip) return;
        try self.shape(t);
    }

    fn skipTitle(self: *Parser, t: Tag) Error!void {
        if (t.self_close) return;
        const end = std.mem.indexOfPos(u8, self.src, self.i, "</title>") orelse
            return self.fail(error.BadTag, t.at, t.name);
        self.i = end + "</title>".len;
    }

    /// Push a `<g>`'s class onto the resolution stack. A *hidden* or skip-marked
    /// group has no meaning in the subset — its children would still be drawn —
    /// so it is drift rather than something to silently interpret.
    fn openGroup(self: *Parser, t: Tag, skip: bool) Error!void {
        if (skip) return self.fail(error.UnknownAttribute, t.at, t.name);
        if (t.self_close) return;
        if (self.classes.n >= max_class_depth) return self.fail(error.TooDeep, t.at, t.name);
        const parent: Transform = if (self.classes.n > 0) self.transforms[self.classes.n - 1] else .{};
        const local = if (self.attrOf(t, "transform")) |raw| try self.rotateTransform(raw, t.at) else Transform{};
        self.classes.items[self.classes.n] = self.attrOf(t, "class") orelse "";
        self.transforms[self.classes.n] = compose(parent, local);
        self.classes.n += 1;
    }

    fn rotateTransform(self: *Parser, raw: []const u8, at: usize) Error!Transform {
        if (!std.mem.startsWith(u8, raw, "rotate(") or !std.mem.endsWith(u8, raw, ")")) {
            return self.fail(error.BadTransform, at, raw);
        }
        const inner = raw["rotate(".len .. raw.len - 1];
        var it = std.mem.tokenizeAny(u8, inner, " ,\t\r\n");
        const degrees = try self.number(it.next() orelse return self.fail(error.BadTransform, at, raw), at);
        const cx = try self.number(it.next() orelse return self.fail(error.BadTransform, at, raw), at);
        const cy = try self.number(it.next() orelse return self.fail(error.BadTransform, at, raw), at);
        if (it.next() != null) return self.fail(error.BadTransform, at, raw);
        const angle = degrees * std.math.pi / 180.0;
        const cos = @cos(angle);
        const sin = @sin(angle);
        return .{
            .a = cos,
            .b = sin,
            .c = -sin,
            .d = cos,
            .e = cx - cos * cx + sin * cy,
            .f = cy - sin * cx - cos * cy,
        };
    }

    fn transform(self: *Parser) Transform {
        return if (self.classes.n > 0) self.transforms[self.classes.n - 1] else .{};
    }

    fn shape(self: *Parser, t: Tag) Error!void {
        const p = try self.resolve(t);
        if (std.mem.eql(u8, t.name, "line")) return self.lineOp(t, p);
        if (std.mem.eql(u8, t.name, "polyline")) return self.polylineOp(t, p);
        if (std.mem.eql(u8, t.name, "polygon")) return self.polygonOp(t, p);
        if (std.mem.eql(u8, t.name, "rect")) return self.rectOp(t, p);
        if (std.mem.eql(u8, t.name, "circle")) return self.circleOp(t, p);
        if (std.mem.eql(u8, t.name, "path")) return self.pathOp(t, p);
        return self.fail(error.UnknownElement, t.at, t.name);
    }

    // ── Skips ─────────────────────────────────────────────────────────────

    /// True for markup that exists only for the live page: `stroke="transparent"`
    /// hit areas, `class="hit-area"`/`"debug-pin"` markers, and anything hidden
    /// by `display:none`.
    fn shouldSkip(self: *Parser, t: Tag) Error!bool {
        if (try self.styleHidden(t)) return true;
        if (self.attrOf(t, "class")) |list| {
            var it = std.mem.tokenizeAny(u8, list, " \t");
            while (it.next()) |c| {
                if (nameIn(&skip_classes, c)) return true;
            }
        }
        if (self.attrOf(t, "stroke")) |s| {
            if (std.mem.eql(u8, s, "transparent")) return true;
        }
        return false;
    }

    /// Validate the `style=` attribute — the subset emits exactly two forms —
    /// and report whether it hides the element.
    fn styleHidden(self: *Parser, t: Tag) Error!bool {
        const style = self.attrOf(t, "style") orelse return false;
        if (std.mem.indexOf(u8, style, "display:none") != null) return true;
        if (std.mem.eql(u8, style, "cursor:pointer")) return false;
        return self.fail(error.UnknownAttribute, t.at, style);
    }

    // ── Style resolution ──────────────────────────────────────────────────

    /// Class rules first (innermost enclosing `<g>` wins), then this element's
    /// own class, then inline attributes.
    fn resolve(self: *Parser, t: Tag) Error!Paint {
        var p: Paint = .{};
        var k = self.classes.n;
        while (k > 0) {
            k -= 1;
            if (ruleFor(self.classes.items[k], t.name)) |r| {
                mergePaint(&p, if (self.theme == .print) r.print else r.screen);
                break;
            }
        }
        if (self.attrOf(t, "class")) |c| {
            if (ruleFor(c, t.name)) |r| mergePaint(&p, if (self.theme == .print) r.print else r.screen);
        }
        try self.inlinePaint(t, &p);
        return p;
    }

    fn inlinePaint(self: *Parser, t: Tag, p: *Paint) Error!void {
        if (self.attrOf(t, "fill")) |v| p.fill = try self.color(v, t.at);
        if (self.attrOf(t, "stroke")) |v| {
            p.stroke = switch (try self.color(v, t.at)) {
                .color => |c| c,
                else => null,
            };
        }
        if (self.attrOf(t, "stroke-width")) |v| p.stroke_width = try self.number(v, t.at);
        if (self.attrOf(t, "font-size")) |v| p.font_size = try self.number(v, t.at);
    }

    /// Parse a colour attribute into the active palette. `none`/`transparent`
    /// resolve to `.none`; a keyword outside the supported set is drift.
    fn color(self: *Parser, v: []const u8, at: usize) Error!Fill {
        if (std.mem.eql(u8, v, "none") or std.mem.eql(u8, v, "transparent")) return .none;
        if (v.len > 0 and v[0] == '#') {
            const c = parseHex(v[1..]) orelse return self.fail(error.UnknownColor, at, v);
            return .{ .color = themeColor(self.theme, c) };
        }
        for (named_colors) |n| {
            if (std.mem.eql(u8, v, n.name)) return .{ .color = themeColor(self.theme, n.value) };
        }
        return self.fail(error.UnknownColor, at, v);
    }

    fn strokeOf(self: *Parser, p: Paint) ?Stroke {
        const c = p.stroke orelse return null;
        _ = self;
        return .{ .color = c, .width = p.stroke_width orelse default_stroke_width };
    }

    /// A stroke for an element that must have one (line/polyline/path): falls
    /// back to the theme's ink so a stroke-less wire is still drawn.
    fn requiredStroke(self: *Parser, p: Paint) Stroke {
        return self.strokeOf(p) orelse .{
            .color = defaultInk(self.theme),
            .width = p.stroke_width orelse default_stroke_width,
        };
    }

    fn fillOf(_: *Parser, p: Paint) ?Rgb {
        return switch (p.fill) {
            .color => |c| c,
            else => null,
        };
    }

    // ── Numbers ───────────────────────────────────────────────────────────

    fn number(self: *Parser, v: []const u8, at: usize) Error!f64 {
        const n = std.fmt.parseFloat(f64, std.mem.trim(u8, v, " \t\r\n")) catch
            return self.fail(error.BadNumber, at, v);
        if (!std.math.isFinite(n)) return self.fail(error.BadNumber, at, v);
        return n;
    }

    /// A required numeric attribute.
    fn numAttr(self: *Parser, t: Tag, name: []const u8) Error!f64 {
        const v = self.attrOf(t, name) orelse return self.fail(error.MissingAttribute, t.at, name);
        return self.number(v, t.at);
    }

    /// An optional numeric attribute.
    fn numAttrOr(self: *Parser, t: Tag, name: []const u8, fallback: f64) Error!f64 {
        const v = self.attrOf(t, name) orelse return fallback;
        return self.number(v, t.at);
    }

    /// Parse exactly `out.len` whitespace/comma-separated numbers.
    fn numberList(self: *Parser, v: []const u8, at: usize, out: []f64) Error!void {
        var it = std.mem.tokenizeAny(u8, v, " ,\t\r\n");
        for (out) |*slot| {
            const tok = it.next() orelse return self.fail(error.BadNumber, at, v);
            slot.* = try self.number(tok, at);
        }
        if (it.next() != null) return self.fail(error.BadNumber, at, v);
    }

    /// Parse a `points="x,y x,y …"` list. At least two points are required —
    /// a one-point polyline draws nothing and signals a broken emitter.
    fn points(self: *Parser, t: Tag) Error![]Pt {
        const v = self.attrOf(t, "points") orelse return self.fail(error.MissingAttribute, t.at, "points");
        var it = std.mem.tokenizeAny(u8, v, " \t\r\n");
        var list: std.ArrayList(Pt) = .empty;
        while (it.next()) |pair| {
            var xy = std.mem.tokenizeScalar(u8, pair, ',');
            const xs = xy.next() orelse return self.fail(error.BadNumber, t.at, pair);
            const ys = xy.next() orelse return self.fail(error.BadNumber, t.at, pair);
            if (xy.next() != null) return self.fail(error.BadNumber, t.at, pair);
            try list.append(self.gpa, .{ .x = try self.number(xs, t.at), .y = try self.number(ys, t.at) });
        }
        if (list.items.len < 2) return self.fail(error.BadNumber, t.at, v);
        return list.toOwnedSlice(self.gpa);
    }

    // ── Shape emitters ────────────────────────────────────────────────────

    fn lineOp(self: *Parser, t: Tag, p: Paint) Error!void {
        const xf = self.transform();
        try self.ops.append(self.gpa, .{ .line = .{
            .a = xf.point(.{ .x = try self.numAttr(t, "x1"), .y = try self.numAttr(t, "y1") }),
            .b = xf.point(.{ .x = try self.numAttr(t, "x2"), .y = try self.numAttr(t, "y2") }),
            .stroke = self.requiredStroke(p),
        } });
    }

    fn polylineOp(self: *Parser, t: Tag, p: Paint) Error!void {
        const pts = try self.points(t);
        transformPoints(pts, self.transform());
        try self.ops.append(self.gpa, .{ .polyline = .{
            .points = pts,
            .stroke = self.requiredStroke(p),
        } });
    }

    fn polygonOp(self: *Parser, t: Tag, p: Paint) Error!void {
        const pts = try self.points(t);
        transformPoints(pts, self.transform());
        try self.ops.append(self.gpa, .{ .polygon = .{
            .points = pts,
            .fill = self.fillOf(p),
            .stroke = self.strokeOf(p),
        } });
    }

    fn rectOp(self: *Parser, t: Tag, p: Paint) Error!void {
        const x = try self.numAttr(t, "x");
        const y = try self.numAttr(t, "y");
        const w = try self.numAttr(t, "width");
        const h = try self.numAttr(t, "height");
        const xf = self.transform();
        if (!xf.isIdentity()) {
            const pts = try self.gpa.alloc(Pt, 4);
            pts[0] = xf.point(.{ .x = x, .y = y });
            pts[1] = xf.point(.{ .x = x + w, .y = y });
            pts[2] = xf.point(.{ .x = x + w, .y = y + h });
            pts[3] = xf.point(.{ .x = x, .y = y + h });
            try self.ops.append(self.gpa, .{ .polygon = .{
                .points = pts,
                .fill = self.fillOf(p),
                .stroke = self.strokeOf(p),
            } });
            return;
        }
        try self.ops.append(self.gpa, .{ .rect = .{
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .rx = try self.numAttrOr(t, "rx", 0),
            .fill = self.fillOf(p),
            .stroke = self.strokeOf(p),
        } });
    }

    fn circleOp(self: *Parser, t: Tag, p: Paint) Error!void {
        const center = self.transform().point(.{ .x = try self.numAttr(t, "cx"), .y = try self.numAttr(t, "cy") });
        try self.ops.append(self.gpa, .{ .circle = .{
            .c = center,
            .r = try self.numAttr(t, "r"),
            .fill = self.fillOf(p),
            .stroke = self.strokeOf(p),
        } });
    }

    /// The one emitted path form: `M x1 y1 A rx ry 0 0 1 x2 y2`. Rotation and
    /// the large-arc flag must be 0; the sweep flag may be 0 or 1.
    fn pathOp(self: *Parser, t: Tag, p: Paint) Error!void {
        const d = self.attrOf(t, "d") orelse return self.fail(error.MissingAttribute, t.at, "d");
        var it = std.mem.tokenizeAny(u8, d, " ,\t\r\n");
        try self.expectCmd(&it, 'M', t.at, d);
        const from = try self.pathPoint(&it, t.at, d);
        try self.expectCmd(&it, 'A', t.at, d);
        var a: [5]f64 = @splat(0);
        for (&a) |*slot| slot.* = try self.number(it.next() orelse
            return self.fail(error.BadPathData, t.at, d), t.at);
        const to = try self.pathPoint(&it, t.at, d);
        if (it.next() != null) return self.fail(error.BadPathData, t.at, d);
        if (a[2] != 0 or a[3] != 0 or (a[4] != 0 and a[4] != 1)) return self.fail(error.BadPathData, t.at, d);
        const xf = self.transform();
        const swaps_axes = @abs(xf.b) > @abs(xf.a);
        try self.ops.append(self.gpa, .{ .arc = .{
            .from = xf.point(from),
            .to = xf.point(to),
            .rx = if (swaps_axes) a[1] else a[0],
            .ry = if (swaps_axes) a[0] else a[1],
            .sweep_cw = a[4] == 1,
            .stroke = self.requiredStroke(p),
        } });
    }

    fn expectCmd(self: *Parser, it: *std.mem.TokenIterator(u8, .any), c: u8, at: usize, d: []const u8) Error!void {
        const tok = it.next() orelse return self.fail(error.BadPathData, at, d);
        if (tok.len != 1 or tok[0] != c) return self.fail(error.BadPathData, at, d);
    }

    fn pathPoint(self: *Parser, it: *std.mem.TokenIterator(u8, .any), at: usize, d: []const u8) Error!Pt {
        const xs = it.next() orelse return self.fail(error.BadPathData, at, d);
        const ys = it.next() orelse return self.fail(error.BadPathData, at, d);
        return .{ .x = try self.number(xs, at), .y = try self.number(ys, at) };
    }

    // ── Text ──────────────────────────────────────────────────────────────

    fn textElement(self: *Parser, t: Tag, skip: bool) Error!void {
        if (t.self_close) return;
        const start = self.i;
        const end = std.mem.indexOfPos(u8, self.src, self.i, "</text>") orelse
            return self.fail(error.BadTag, t.at, t.name);
        self.i = end + "</text>".len;
        if (skip) return;
        const raw = self.src[start..end];
        if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return;
        const p = try self.resolve(t);
        try self.ops.append(self.gpa, .{ .text = .{
            .at = self.transform().point(.{ .x = try self.numAttr(t, "x"), .y = try self.numAttr(t, "y") }),
            .s = try decodeEntities(self.gpa, raw),
            .fill = self.fillOf(p) orelse defaultInk(self.theme),
            .size = p.font_size orelse default_font_size,
            .anchor = try self.anchorOf(t),
            .bold = self.isBold(t),
        } });
    }

    fn anchorOf(self: *Parser, t: Tag) Error!Anchor {
        const v = self.attrOf(t, "text-anchor") orelse return .start;
        if (std.mem.eql(u8, v, "start")) return .start;
        if (std.mem.eql(u8, v, "middle")) return .middle;
        if (std.mem.eql(u8, v, "end")) return .end;
        return self.fail(error.UnknownAttribute, t.at, v);
    }

    fn isBold(self: *Parser, t: Tag) bool {
        const v = self.attrOf(t, "font-weight") orelse return false;
        if (std.mem.eql(u8, v, "bold")) return true;
        return std.fmt.parseInt(u16, v, 10) catch 400 >= 600;
    }

    // ── Strict validation ─────────────────────────────────────────────────

    fn checkClass(self: *Parser, list: []const u8, at: usize) Error!void {
        var it = std.mem.tokenizeAny(u8, list, " \t");
        while (it.next()) |c| {
            if (!isKnownClass(c)) return self.fail(error.UnknownClass, at, c);
        }
    }

    fn checkAttrs(self: *Parser, t: Tag) Error!void {
        const allowed = allowedAttrs(t.name) orelse return self.fail(error.UnknownElement, t.at, t.name);
        const paint = takesPaint(t.name);
        for (t.attrs[0..t.n]) |a| {
            if (nameIn(allowed, a.name)) continue;
            if (paint and nameIn(&paint_attrs, a.name)) continue;
            return self.fail(error.UnknownAttribute, a.at, a.name);
        }
    }
};

/// Characters an element or attribute name may contain. `-` covers `data-net`
/// and `stroke-width`, `:` an `xmlns:`-style prefix.
fn isNameChar(c: u8) bool {
    if (std.ascii.isAlphanumeric(c)) return true;
    return switch (c) {
        '-', '_', ':' => true,
        else => false,
    };
}

/// The class rule for `class`/`element`, or null when the class styles no such
/// element (a `<g class="net">` around a `<rect>`, say).
fn ruleFor(class: []const u8, element: []const u8) ?Rule {
    for (rules) |r| {
        if (!std.mem.eql(u8, r.class, class)) continue;
        for (r.elements) |e| {
            if (std.mem.eql(u8, e, element)) return r;
        }
    }
    return null;
}

/// Overlay `src` onto `dst`, leaving `dst`'s already-set properties alone
/// (nearest rule wins, inline attributes win over both).
fn mergePaint(dst: *Paint, src: Paint) void {
    if (dst.fill == .unset) dst.fill = src.fill;
    if (dst.stroke == null) dst.stroke = src.stroke;
    if (dst.stroke_width == null) dst.stroke_width = src.stroke_width;
    if (dst.font_size == null) dst.font_size = src.font_size;
}

/// A class is known when the style table styles it or it is a skip marker.
/// Anything else is renderer drift.
fn isKnownClass(class: []const u8) bool {
    for (rules) |r| {
        if (std.mem.eql(u8, r.class, class)) return true;
    }
    return nameIn(&skip_classes, class);
}

/// True when `name` is one of `list`.
fn nameIn(list: []const []const u8, name: []const u8) bool {
    for (list) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Paint attributes any drawable element may carry. `opacity` is accepted and
/// ignored: the only emitters using it are the (currently unreachable)
/// block-icon glyphs and the skipped debug pin.
const paint_attrs = [_][]const u8{ "fill", "stroke", "stroke-width", "class", "opacity" };

/// Containers style their children but are never painted themselves, so they do
/// NOT get the shared paint set — a `fill=` on a `<g>` is drift.
fn takesPaint(element: []const u8) bool {
    const containers = [_][]const u8{ "svg", "g", "title" };
    for (containers) |c| {
        if (std.mem.eql(u8, c, element)) return false;
    }
    return true;
}

/// Element-specific attributes (geometry plus one-off decorations); the shared
/// `paint_attrs` are allowed on top for every non-container. Anything else is
/// drift — this is the check that makes a new `transform=` fail loudly.
fn allowedAttrs(element: []const u8) ?[]const []const u8 {
    const table = [_]struct { name: []const u8, attrs: []const []const u8 }{
        .{ .name = "svg", .attrs = &.{ "class", "viewBox", "preserveAspectRatio", "xmlns", "data-ref" } },
        .{ .name = "g", .attrs = &.{ "class", "style", "data-net", "data-ref", "data-pin", "data-passive-count", "transform" } },
        .{ .name = "title", .attrs = &.{} },
        .{ .name = "line", .attrs = &.{ "x1", "y1", "x2", "y2" } },
        .{ .name = "polyline", .attrs = &.{ "points", "stroke-linejoin" } },
        .{ .name = "polygon", .attrs = &.{"points"} },
        .{ .name = "rect", .attrs = &.{ "x", "y", "width", "height", "rx" } },
        .{ .name = "circle", .attrs = &.{ "cx", "cy", "r", "style" } },
        .{ .name = "path", .attrs = &.{"d"} },
        .{ .name = "text", .attrs = &.{
            "x",           "y",     "text-anchor",
            "font-size",   "style", "font-weight",
            "font-family",
        } },
    };
    for (table) |e| {
        if (std.mem.eql(u8, e.name, element)) return e.attrs;
    }
    return null;
}

/// `#rgb` / `#rrggbb`. Returns null on any other length or a non-hex digit.
fn parseHex(s: []const u8) ?Rgb {
    if (s.len == 3) {
        const r = hexDigit(s[0]) orelse return null;
        const g = hexDigit(s[1]) orelse return null;
        const b = hexDigit(s[2]) orelse return null;
        return .{ .r = r * 17, .g = g * 17, .b = b * 17 };
    }
    if (s.len != 6) return null;
    return .{
        .r = hexByte(s[0..2]) orelse return null,
        .g = hexByte(s[2..4]) orelse return null,
        .b = hexByte(s[4..6]) orelse return null,
    };
}

fn hexDigit(c: u8) ?u8 {
    return std.fmt.charToDigit(c, 16) catch null;
}

fn hexByte(s: []const u8) ?u8 {
    const hi = hexDigit(s[0]) orelse return null;
    const lo = hexDigit(s[1]) orelse return null;
    return hi * 16 + lo;
}

// ── tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A minimal well-formed stroked line, reused where a test needs one valid
/// element alongside the invalid markup under test.
const a_line = "<line x1=\"0\" y1=\"0\" x2=\"1\" y2=\"1\" stroke=\"#555\"/>";
/// A root open tag with the smallest legal viewBox.
const svg_open = "<svg viewBox=\"0 0 4 4\">";

/// Translate `svg` under an arena (the module's allocation contract) and return
/// the ops. The arena must outlive the returned slice.
fn opsOf(arena: Allocator, svg: []const u8, theme: Theme) Error![]const DrawOp {
    const doc = try translate(arena, svg, .{ .theme = theme }, null);
    return doc.ops;
}

fn countOps(ops: []const DrawOp, comptime tag: std.meta.Tag(DrawOp)) usize {
    var n: usize = 0;
    for (ops) |op| {
        if (op == tag) n += 1;
    }
    return n;
}

// spec: svg2pdf - Translates the emitted line/polyline/rect/text subset into resolved DrawOps
test "translate resolves the core shape and text subset" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const svg =
        \\<svg class="hub-inset" viewBox="0 0 400 200" xmlns="http://www.w3.org/2000/svg">
        \\<g class="net" data-net="VDD"><line x1="1.0" y1="2.0" x2="3.0" y2="2.0" stroke="#4a9" stroke-width="1.5"/>
        \\<polyline points="1.0,2.0 5.0,2.0 5.0,9.0 8.0,9.0" fill="none" stroke="#4a9" stroke-width="1.5"/></g>
        \\<g data-ref="U1" data-passive-count="1" class="component"><rect x="10.0" y="20.0" width="30" height="40.5"
        \\  fill="#16213e" stroke="#4a9eff" stroke-width="2" rx="6"/>
        \\<text x="25.0" y="38.0" text-anchor="middle"
        \\  font-size="12" font-weight="bold" fill="#4a9eff">U1 &amp; more</text></g>
        \\</svg>
    ;
    const doc = try translate(arena.allocator(), svg, .{ .theme = .screen }, null);
    try testing.expectEqual(@as(f64, 400), doc.width);
    try testing.expectEqual(@as(f64, 200), doc.height);
    try testing.expectEqual(@as(usize, 4), doc.ops.len);

    try testing.expectEqual(@as(f64, 1.0), doc.ops[0].line.a.x);
    try testing.expectEqual(@as(f64, 1.5), doc.ops[0].line.stroke.width);
    try testing.expectEqual(rgb(0x44, 0xaa, 0x99), doc.ops[0].line.stroke.color);
    try testing.expectEqual(@as(usize, 4), doc.ops[1].polyline.points.len);
    try testing.expectEqual(@as(f64, 9.0), doc.ops[1].polyline.points[3].y);

    const r = doc.ops[2].rect;
    try testing.expectEqual(@as(f64, 40.5), r.h);
    try testing.expectEqual(@as(f64, 6), r.rx);
    try testing.expectEqual(rgb(0x16, 0x21, 0x3e), r.fill.?);
    try testing.expectEqual(rgb(0x4a, 0x9e, 0xff), r.stroke.?.color);

    const tx = doc.ops[3].text;
    try testing.expectEqualStrings("U1 & more", tx.s);
    try testing.expectEqual(Anchor.middle, tx.anchor);
    try testing.expectEqual(@as(f64, 12), tx.size);
    try testing.expect(tx.bold);
}

// spec: svg2pdf - Resolves a class style when no inline attribute overrides it
test "class rules supply stroke, fill and font-size when no attribute does" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // No inline stroke/fill/font-size anywhere: every value must come from the
    // .pin-stub and .net class rules.
    const svg =
        \\<svg viewBox="0 0 10 10"><g class="pin-stub"><line x1="0" y1="0" x2="5" y2="0"/></g>
        \\<g class="net"><text x="1" y="2">GND</text></g></svg>
    ;
    const ops = try opsOf(arena.allocator(), svg, .screen);
    try testing.expectEqual(rgb(0x6e, 0x76, 0x81), ops[0].line.stroke.color);
    try testing.expectEqual(@as(f64, 1), ops[0].line.stroke.width);
    try testing.expectEqual(rgb(0x79, 0xc0, 0xff), ops[1].text.fill);
    try testing.expectEqual(@as(f64, 10), ops[1].text.size);
}

// spec: svg2pdf - The print palette darkens strokes and text for a white page
test "print theme maps class and inline colours to page-legible ink" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const svg =
        \\<svg viewBox="0 0 10 10"><g class="component"><rect x="0" y="0" width="4" height="4"/>
        \\<text x="1" y="2">U1</text></g>
        \\<text x="3" y="4" fill="#aaa" font-size="9">C1 100nF</text></svg>
    ;
    const ops = try opsOf(arena.allocator(), svg, .print);
    // Class-driven: light box fill, dark border, near-black label.
    try testing.expectEqual(rgb(0xf2, 0xf6, 0xfc), ops[0].rect.fill.?);
    try testing.expectEqual(rgb(0x0b, 0x4f, 0x9e), ops[0].rect.stroke.?.color);
    try testing.expectEqual(rgb(0x11, 0x11, 0x11), ops[1].text.fill);
    // Inline #aaa (unreadable on white) maps through the literal table.
    try testing.expectEqual(rgb(0x22, 0x22, 0x22), ops[2].text.fill);
    // The screen palette leaves the same input untouched.
    const screen = try opsOf(arena.allocator(), svg, .screen);
    try testing.expectEqual(rgb(0xaa, 0xaa, 0xaa), screen[2].text.fill);
}

// spec: svg2pdf - An unlisted light colour is darkened rather than passed through to a white page
test "print theme darkens an unmapped light colour and leaves a dark one alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const svg =
        \\<svg viewBox="0 0 10 10"><line x1="0" y1="0" x2="1" y2="1" stroke="#fff"/>
        \\<line x1="0" y1="0" x2="1" y2="1" stroke="#101010"/></svg>
    ;
    const ops = try opsOf(arena.allocator(), svg, .print);
    const light = ops[0].line.stroke.color;
    try testing.expect(light.r < 0x80 and light.g < 0x80 and light.b < 0x80);
    try testing.expectEqual(rgb(0x10, 0x10, 0x10), ops[1].line.stroke.color);
}

// spec: svg2pdf - Preserves the single emitted arc path form with its radii and sweep
test "the inductor arc path becomes an arc DrawOp with its parameters intact" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const svg =
        \\<svg viewBox="0 0 10 10">
        \\<path d="M 12.0 30.0 A 4.0 4.0 0 0 1 20.0 30.0" fill="none" stroke="#8888cc" stroke-width="1.5"/></svg>
    ;
    const ops = try opsOf(arena.allocator(), svg, .screen);
    const a = ops[0].arc;
    try testing.expectEqual(@as(f64, 12), a.from.x);
    try testing.expectEqual(@as(f64, 20), a.to.x);
    try testing.expectEqual(@as(f64, 4), a.rx);
    try testing.expectEqual(@as(f64, 4), a.ry);
    try testing.expect(a.sweep_cw);
    try testing.expectEqual(@as(f64, 1.5), a.stroke.width);
}

// spec: Web Server - The schematic display-list translator applies the renderer's rotate group transform to vertical passives
test "rotate group transforms its child geometry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const svg =
        \\<svg viewBox="0 0 20 20">
        \\<g transform="rotate(90 10 10)"><line x1="10" y1="5" x2="10" y2="15" stroke="#888"/></g>
        \\</svg>
    ;
    const ops = try opsOf(arena.allocator(), svg, .screen);
    try testing.expectApproxEqAbs(@as(f64, 15), ops[0].line.a.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 10), ops[0].line.a.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 5), ops[0].line.b.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 10), ops[0].line.b.y, 0.0001);
}

// spec: svg2pdf - Rejects path data outside the single arc form with the offending byte offset
test "a cubic or multi-segment path is rejected as unparseable path data" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const svg =
        \\<svg viewBox="0 0 10 10"><path d="M 0 0 C 1 1, 2 2, 3 3" stroke="#555"/></svg>
    ;
    var diag: Diagnostic = .{};
    try testing.expectError(error.BadPathData, translate(arena.allocator(), svg, .{}, &diag));
    try testing.expect(diag.offset > 0);
    try testing.expect(std.mem.indexOf(u8, diag.token, "C 1 1") != null);
    // A malformed arc (bad flag) is rejected too.
    const bad_flag = "<svg viewBox=\"0 0 1 1\"><path d=\"M 0 0 A 1 1 0 1 1 2 2\" stroke=\"#555\"/></svg>";
    try testing.expectError(error.BadPathData, translate(arena.allocator(), bad_flag, .{}, null));
}

// spec: svg2pdf - Drops hit-area, debug-pin, display-none and transparent-stroke markup
test "live-page-only markup produces no ops and no error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const svg =
        \\<svg viewBox="0 0 10 10"><g class="net" data-net="X" style="cursor:pointer">
        \\<line x1="0" y1="0" x2="9" y2="0" stroke="transparent" stroke-width="12" class="hit-area"/>
        \\<line x1="0" y1="0" x2="9" y2="0" stroke="#4a9" stroke-width="1.5"/></g>
        \\<rect x="0" y="0" width="4" height="4" fill="transparent" class="hit-area"/>
        \\<circle class="debug-pin" cx="1.0" cy="2.0" r="3" fill="red" opacity="0.8" style="display:none"/>
        \\<title>tooltip &lt;here&gt;</title>
        \\<text x="1" y="1" class="hit-area">dropped</text></svg>
    ;
    const ops = try opsOf(arena.allocator(), svg, .screen);
    try testing.expectEqual(@as(usize, 1), ops.len);
    try testing.expectEqual(@as(usize, 1), countOps(ops, .line));
}

// spec: svg2pdf - Rejects an element outside the subset with its byte offset
test "an unknown element is a strict error naming the tag and offset" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const svg = "<svg viewBox=\"0 0 4 4\">" ++ a_line ++ "<ellipse cx=\"1\" cy=\"1\"/></svg>";
    var diag: Diagnostic = .{};
    try testing.expectError(error.UnknownElement, translate(arena.allocator(), svg, .{}, &diag));
    try testing.expectEqualStrings("ellipse", diag.token);
    try testing.expectEqual(std.mem.indexOf(u8, svg, "<ellipse").?, diag.offset);
}

// spec: svg2pdf - Rejects an unsupported group transform or an unstyled style
test "an unsupported group transform and an unrecognised style are both rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const with_transform = svg_open ++ "<g transform=\"scale(2)\"></g></svg>";
    var diag: Diagnostic = .{};
    try testing.expectError(error.BadTransform, translate(a, with_transform, .{}, &diag));
    try testing.expectEqualStrings("scale(2)", diag.token);

    const bad = [_][]const u8{
        svg_open ++ "<text x=\"0\" y=\"0\" style=\"opacity:.2\">x</text></svg>", // style form
        svg_open ++ "<text x=\"0\" y=\"0\" text-anchor=\"inherit\">x</text></svg>", // anchor word
        svg_open ++ "<g fill=\"#fff\"></g></svg>", // paint on a container
        svg_open ++ "<g style=\"display:none\"><line/></g></svg>", // hidden group
    };
    for (bad) |src| try testing.expectError(error.UnknownAttribute, translate(a, src, .{}, null));
}

// spec: svg2pdf - Rejects a class the style table does not know
test "an unknown class is a strict error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // `dg-node` is deliberate: it is the block-diagram renderer's own class
    // family (`src/diagram/render.zig` `css`, a second and much larger style
    // authority with cubic-Bézier paths, `<a>` wrappers and `font:` shorthand).
    // The diagram is OUTSIDE this translator's subset, and this is the error a
    // caller gets — a named class at a byte offset — rather than a silently
    // unstyled page. Teaching the table that family is a follow-up, not drift.
    const svg = svg_open ++ "<g class=\"dg-node\"></g></svg>";
    var diag: Diagnostic = .{};
    try testing.expectError(error.UnknownClass, translate(arena.allocator(), svg, .{}, &diag));
    try testing.expectEqualStrings("dg-node", diag.token);
}

// spec: svg2pdf - Rejects a non-finite or unparseable coordinate rather than saturating it
test "an overflowing or garbage coordinate is a bad number, never a saturated one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // 1e400 overflows f64 to infinity; parseFloat succeeds, so the finiteness
    // guard is what catches it.
    const huge = "<svg viewBox=\"0 0 4 4\"><line x1=\"1e400\" y1=\"0\" x2=\"1\" y2=\"1\" stroke=\"#555\"/></svg>";
    try testing.expectError(error.BadNumber, translate(arena.allocator(), huge, .{}, null));
    const junk = "<svg viewBox=\"0 0 4 4\"><line x1=\"12px\" y1=\"0\" x2=\"1\" y2=\"1\" stroke=\"#555\"/></svg>";
    try testing.expectError(error.BadNumber, translate(arena.allocator(), junk, .{}, null));
    const bad_box = "<svg viewBox=\"0 0 4\"><line x1=\"0\" y1=\"0\" x2=\"1\" y2=\"1\" stroke=\"#555\"/></svg>";
    try testing.expectError(error.BadNumber, translate(arena.allocator(), bad_box, .{}, null));
}

// spec: svg2pdf - Rejects an unsupported colour keyword
test "an unsupported colour keyword is rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const svg = "<svg viewBox=\"0 0 4 4\"><line x1=\"0\" y1=\"0\" x2=\"1\" y2=\"1\" stroke=\"rebeccapurple\"/></svg>";
    var diag: Diagnostic = .{};
    try testing.expectError(error.UnknownColor, translate(arena.allocator(), svg, .{}, &diag));
    try testing.expectEqualStrings("rebeccapurple", diag.token);
}

// spec: svg2pdf - An empty or root-less input is rejected instead of yielding an empty document
test "empty and root-less inputs are rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.NoSvgRoot, translate(arena.allocator(), "", .{}, null));
    try testing.expectError(error.NoSvgRoot, translate(arena.allocator(), "   \n", .{}, null));
    try testing.expectError(error.NoSvgRoot, translate(arena.allocator(), "<div>x</div>", .{}, null));
    // A missing viewBox is a missing required attribute, not a silent 0x0 page.
    try testing.expectError(error.MissingAttribute, translate(arena.allocator(), "<svg></svg>", .{}, null));
    // An svg with no children is a legal empty document.
    const doc = try translate(arena.allocator(), "<svg viewBox=\"0 0 8 9\"></svg>", .{}, null);
    try testing.expectEqual(@as(usize, 0), doc.ops.len);
    try testing.expectEqual(@as(f64, 9), doc.height);
}

// spec: svg2pdf - Rejects malformed or unterminated markup rather than reading past the end of the input
test "unterminated tags and text runs are rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const truncated = [_][]const u8{
        "<svg viewBox=\"0 0 4 4\"", // tag never closed
        svg_open ++ "<text x=\"0\" y=\"0\">no end", // text run never closed
        svg_open ++ "<g></g>", // root never closed
        svg_open ++ "</g></svg>", // stray group close
    };
    for (truncated) |src| try testing.expectError(error.BadTag, translate(a, src, .{}, null));
}

// spec: svg2pdf - Translates a multi-SVG hub render as a sequence of documents
test "translateAll walks every svg in a markup blob and ignores the HTML around them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const markup =
        \\<div class="hub-group-block"><h4 class="hub-group-label">VDD Power</h4>
        \\<svg viewBox="0 0 10 10"><line x1="0" y1="0" x2="1" y2="1" stroke="#555"/></svg></div>
        \\<div class="hub-group-block"><h4 class="hub-group-label">USB</h4>
        \\<svg viewBox="0 0 20 30"><text x="1" y="2">USB_DP</text></svg></div>
    ;
    const docs = try translateAll(arena.allocator(), markup, .{}, null);
    try testing.expectEqual(@as(usize, 2), docs.len);
    try testing.expectEqual(@as(f64, 10), docs[0].width);
    try testing.expectEqual(@as(f64, 30), docs[1].height);
    try testing.expectEqualStrings("USB_DP", docs[1].ops[0].text.s);
    // Markup with no svg at all yields no documents rather than an error.
    try testing.expectEqual(@as(usize, 0), (try translateAll(arena.allocator(), "<p>nothing</p>", .{}, null)).len);
}

// spec: svg2pdf - Each document carries the pin-group heading written above its svg, entity-decoded
test "translateAll captures the h4 group label preceding each svg" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const markup =
        \\<div class="hub-group-block"><h4 class="hub-group-label">VDD Power</h4>
        \\<svg viewBox="0 0 10 10"><line x1="0" y1="0" x2="1" y2="1" stroke="#555"/></svg></div>
        \\<div class="hub-group-block"><h4 class="hub-group-label">USB &amp; Debug</h4>
        \\<svg viewBox="0 0 20 30"><text x="1" y="2">USB_DP</text></svg></div>
        \\<div class="hub-group-block">
        \\<svg viewBox="0 0 15 15"><line x1="0" y1="0" x2="2" y2="2" stroke="#555"/></svg></div>
    ;
    const docs = try translateAll(arena.allocator(), markup, .{}, null);
    try testing.expectEqual(@as(usize, 3), docs.len);
    try testing.expectEqualStrings("VDD Power", docs[0].title);
    // The heading is HTML-escaped by the renderer, so it arrives decoded.
    try testing.expectEqualStrings("USB & Debug", docs[1].title);
    // A single-group hub writes no heading at all: an empty title, never the
    // previous block's label carried forward.
    try testing.expectEqualStrings("", docs[2].title);
}

/// `n` copies of a two-op hub SVG wrapped in the page's group-block HTML — the
/// shape `renderHubSvg` produces for a many-group hub, scaled up.
fn repeatedHubMarkup(a: Allocator, n: usize) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (0..n) |_| {
        try buf.appendSlice(a,
            \\<div><svg viewBox="0 0 10 10"><g class="net"><polyline points="0,0 1,1 2,2 3,3"/>
            \\<text x="1" y="2">NET_LABEL</text></g></svg></div>
        );
    }
    return buf.toOwnedSlice(a);
}

fn totalOps(docs: []const Document) usize {
    var n: usize = 0;
    for (docs) |d| n += d.ops.len;
    return n;
}

// spec: svg2pdf - A bulk render of many hub SVGs translates without error or quadratic blowup
test "translateAll handles a large multi-hub markup blob" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const docs = try translateAll(a, try repeatedHubMarkup(a, 400), .{}, null);
    try testing.expectEqual(@as(usize, 400), docs.len);
    try testing.expectEqual(@as(usize, 800), totalOps(docs));
}

// ── Style-table sync gate (validation item 4) ─────────────────────────────

/// One rule parsed out of the `static_svg_css` string: selector list plus the
/// paint properties it declares, so the table can be compared value-for-value.
const CssRule = struct { selector: []const u8, paint: Paint, font_family: []const u8, layout_only: bool };

/// Parse one `selector{decls}` line of `static_svg_css`. Returns null for a
/// blank line. Errors when a declaration is neither a known paint property nor
/// a layout property — a new property is drift the table must be taught.
fn parseCssRule(line: []const u8) !?CssRule {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;
    const open = std.mem.indexOfScalar(u8, trimmed, '{') orelse return error.BadCss;
    const close = std.mem.lastIndexOfScalar(u8, trimmed, '}') orelse return error.BadCss;
    var out: CssRule = .{ .selector = trimmed[0..open], .paint = .{}, .font_family = "", .layout_only = true };
    var it = std.mem.tokenizeScalar(u8, trimmed[open + 1 .. close], ';');
    while (it.next()) |decl| {
        const colon = std.mem.indexOfScalar(u8, decl, ':') orelse return error.BadCss;
        try applyCssDecl(&out, std.mem.trim(u8, decl[0..colon], " "), std.mem.trim(u8, decl[colon + 1 ..], " "));
    }
    return out;
}

fn applyCssDecl(out: *CssRule, prop: []const u8, val: []const u8) !void {
    if (std.mem.eql(u8, prop, "fill")) {
        out.paint.fill = try cssFill(val);
    } else if (std.mem.eql(u8, prop, "stroke")) {
        out.paint.stroke = parseHex(std.mem.trimStart(u8, val, "#")) orelse return error.BadCss;
    } else if (std.mem.eql(u8, prop, "stroke-width")) {
        out.paint.stroke_width = std.fmt.parseFloat(f64, val) catch return error.BadCss;
    } else if (std.mem.eql(u8, prop, "font-size")) {
        out.paint.font_size = std.fmt.parseFloat(f64, std.mem.trimEnd(u8, val, "px")) catch return error.BadCss;
    } else if (std.mem.eql(u8, prop, "font-family")) {
        out.font_family = val;
        return;
    } else if (isLayoutProp(prop)) {
        return;
    } else {
        return error.UnknownCssProperty;
    }
    out.layout_only = false;
}

fn cssFill(val: []const u8) !Fill {
    if (std.mem.eql(u8, val, "none")) return .none;
    return .{ .color = parseHex(std.mem.trimStart(u8, val, "#")) orelse return error.BadCss };
}

fn isLayoutProp(prop: []const u8) bool {
    const layout = [_][]const u8{ "display", "width", "max-width", "height" };
    for (layout) |l| {
        if (std.mem.eql(u8, l, prop)) return true;
    }
    return false;
}

fn expectPaintEq(want: Paint, got: Paint) !void {
    try testing.expectEqual(std.meta.activeTag(want.fill), std.meta.activeTag(got.fill));
    if (want.fill == .color) try testing.expectEqual(want.fill.color, got.fill.color);
    try testing.expectEqual(want.stroke, got.stroke);
    try testing.expectEqual(want.stroke_width, got.stroke_width);
    try testing.expectEqual(want.font_size, got.font_size);
}

/// Compare one parsed CSS rule against the table entry at `idx`: same selector
/// text, same screen paint, the one known monospace family, and paint present
/// on every rule but the layout-only first one.
fn expectRuleMatchesCss(idx: usize, parsed: CssRule) !void {
    try testing.expect(idx < rules.len);
    try testing.expectEqualStrings(rules[idx].selector, parsed.selector);
    try expectPaintEq(rules[idx].screen, parsed.paint);
    if (parsed.font_family.len > 0) {
        try testing.expectEqualStrings("\"SF Mono\",monospace", parsed.font_family);
    }
    try testing.expectEqual(idx == 0, parsed.layout_only);
}

/// Walk `static_svg_css` line by line against the table; returns the rule count
/// so the caller can assert neither side has extra rules.
fn syncCssAgainstTable(css: []const u8) !usize {
    var it = std.mem.tokenizeScalar(u8, css, '\n');
    var n: usize = 0;
    while (it.next()) |line| {
        const parsed = (try parseCssRule(line)) orelse continue;
        try expectRuleMatchesCss(n, parsed);
        n += 1;
    }
    return n;
}

// spec: svg2pdf - The Zig style table agrees rule-for-rule with render_html.static_svg_css
test "style table stays in sync with the static_svg_css authority" {
    // Single-authority drift gate: `static_svg_css` is the only place the static
    // export's SVG colours are declared, so the screen palette here must be a
    // faithful mirror. Any CSS edit — a colour, a width, a new rule, a new
    // property — fails this test rather than silently diverging in the PDF.
    const css = @import("render_html.zig").static_svg_css;
    try testing.expectEqual(rules.len, try syncCssAgainstTable(css));
}

/// A rule's parsed `class`/`elements` must be derivable from its own selector
/// text, and must resolve back through `ruleFor` — so the two halves of a rule
/// cannot drift apart.
fn expectRuleSelfConsistent(r: Rule) !void {
    try testing.expect(std.mem.indexOf(u8, r.selector, r.class) != null);
    for (r.elements) |e| {
        if (e.len == 0) continue; // the root-selector rule styles no element
        try testing.expect(std.mem.indexOf(u8, r.selector, e) != null);
        try testing.expect(ruleFor(r.class, e) != null);
    }
}

// spec: svg2pdf - Every style-table rule names classes and elements the emitters actually use
test "style table selectors parse into the class and element names resolution uses" {
    for (rules) |r| try expectRuleSelfConsistent(r);
    // A class/element pair no rule covers resolves to null, not to a wrong rule.
    try testing.expect(ruleFor("net", "rect") == null);
    try testing.expect(ruleFor("nope", "line") == null);
}

// ── Strictness against the real renderer (validation item 5) ─────────────

const env_mod = @import("eval/env.zig");
const rails_mod = @import("eval/rails.zig");
const render_html = @import("render_html.zig");

/// A synthetic board that drives every shape in the subset through the real
/// renderer: a hub IC with three labelled pin groups, a decoupling cap (plate
/// symbol) terminating on GND (ground glyph), a series inductor (the `path` arc),
/// a resistor (box symbol), a ferrite bead (filled body), and named nets on the
/// far side of each chain (net-label `text`).
fn fixtureBlock() env_mod.DesignBlock {
    return .{
        .name = "svg2pdf-fixture",
        .instances = &fixture_instances,
        .nets = &fixture_nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
}

const fixture_instances = [_]env_mod.Instance{
    .{ .ref_des = "U1", .component = "acme-mcu", .value = "", .footprint = "", .symbol = "" },
    .{ .ref_des = "C1", .component = "cap-0402", .value = "100nF", .footprint = "", .symbol = "generic-cap" },
    .{ .ref_des = "L1", .component = "ind-0603", .value = "4.7uH", .footprint = "", .symbol = "generic-ind" },
    .{ .ref_des = "R1", .component = "res-0402", .value = "10k", .footprint = "", .symbol = "generic-res" },
    .{ .ref_des = "FB1", .component = "ferrite-0402", .value = "600R", .footprint = "", .symbol = "generic-res" },
    .{ .ref_des = "J1", .component = "hdr-1x2", .value = "", .footprint = "", .symbol = "" },
};

const fixture_nets = [_]env_mod.Net{
    .{ .name = "VDD3V3", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "U1", .pin = "2" },
        .{ .ref_des = "C1", .pin = "1" }, .{ .ref_des = "L1", .pin = "2" },
    } },
    .{ .name = "GND", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "3" }, .{ .ref_des = "U1", .pin = "4" },
        .{ .ref_des = "C1", .pin = "2" },
    } },
    .{ .name = "SIG", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "5" }, .{ .ref_des = "R1", .pin = "1" },
    } },
    .{ .name = "SIG_PULLUP", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "R1", .pin = "2" }, .{ .ref_des = "J1", .pin = "1" },
    } },
    .{ .name = rails_mod.system_rail, .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "L1", .pin = "1" }, .{ .ref_des = "FB1", .pin = "1" },
    } },
    .{ .name = "V_IN", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "FB1", .pin = "2" }, .{ .ref_des = "J1", .pin = "2" },
    } },
};

const fixture_pin_groups = [_]env_mod.PinGroup{.{
    .ref_des = "U1",
    .pins = &[_]env_mod.PartPin{
        .{ .pin = "1", .net = "VDD3V3", .pin_name = "VDD_1", .group = "VDD Power" },
        .{ .pin = "2", .net = "VDD3V3", .pin_name = "VDD_2", .group = "VDD Power" },
        .{ .pin = "3", .net = "GND", .pin_name = "VSS_1", .group = "VDD Power" },
        .{ .pin = "4", .net = "GND", .pin_name = "VSS_2", .group = "VDD Power" },
        .{ .pin = "5", .net = "SIG", .pin_name = "PA3", .group = "GPIO" },
    },
}};

/// Render the fixture hub through the live per-hub renderer, exactly as
/// `review_md.zig` composes the static export.
fn renderFixtureHub(a: Allocator, buf: *std.Io.Writer.Allocating) ![]const u8 {
    const block = fixtureBlock();
    var ctx = try render_html.setupRenderCtx(a, &block);
    const w = &buf.writer;
    const rendered = try render_html.renderHubSvg(&ctx, w, a, &fixture_pin_groups, "U1");
    try testing.expect(rendered);
    return buf.written();
}

fn countKinds(ops: []const DrawOp, out: *std.EnumArray(std.meta.Tag(DrawOp), usize)) void {
    for (ops) |op| out.getPtr(op).* += 1;
}

// spec: svg2pdf - A real per-hub render of passives, an inductor arc, a ground glyph and net labels translates strictly
test "the live per-hub renderer's output translates strictly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: std.Io.Writer.Allocating = .init(a);
    const svg = try renderFixtureHub(a, &buf);

    var diag: Diagnostic = .{};
    const docs = try translateAll(a, svg, .{ .theme = .print }, &diag);
    // Two `(group …)` buckets on U1 ⇒ two `<svg>` documents wrapped in the
    // page's group-block HTML, so this also exercises the multi-document path.
    try testing.expectEqual(@as(usize, 2), docs.len);

    var kinds = std.EnumArray(std.meta.Tag(DrawOp), usize).initFill(0);
    for (docs) |d| countKinds(d.ops, &kinds);
    // The hub box + passive bodies, the wires, the inductor bump, and every
    // label must all have survived into the display list.
    try testing.expect(kinds.get(.rect) >= 2);
    try testing.expect(kinds.get(.line) >= 8);
    try testing.expect(kinds.get(.arc) == 3); // three bumps per generic-ind
    try testing.expect(kinds.get(.text) >= 6);
}

/// True when some text op in `docs` renders exactly `want`.
fn hasLabel(docs: []const Document, want: []const u8) bool {
    for (docs) |d| {
        for (d.ops) |op| {
            if (op == .text and std.mem.eql(u8, op.text.s, want)) return true;
        }
    }
    return false;
}

// spec: svg2pdf - Ref-des, pin-function and net labels survive translation as text ops
test "the rendered hub's labels reach the display list verbatim" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: std.Io.Writer.Allocating = .init(a);
    const docs = try translateAll(a, try renderFixtureHub(a, &buf), .{}, null);
    try testing.expect(hasLabel(docs, "U1 acme-mcu")); // hub title
    try testing.expect(hasLabel(docs, "5")); // pin-stub number tag
    try testing.expect(hasLabel(docs, "C1 100nF")); // passive ref + value
    try testing.expect(hasLabel(docs, "L1 4.7uH"));
    try testing.expect(hasLabel(docs, "SIG_PULLUP")); // far-side net label
    try testing.expect(hasLabel(docs, "V_IN"));
}

/// Evaluate one design file and strict-translate every hub SVG the schematic
/// page would render for it. Returns false when the file doesn't evaluate to a
/// design-block (a library or include file swept up by the directory walk);
/// propagates a translation error, which is the point of the sweep.
fn sweepOneDesign(a: Allocator, project_dir: []const u8, path: []const u8) !bool {
    var eval = @import("eval/evaluator.zig").Evaluator.init(a, project_dir);
    const value = eval.evalFile(path) catch return false;
    const block = switch (value) {
        .design_block => |b| b,
        else => return false,
    };
    var ctx = try render_html.setupRenderCtx(a, block);
    for (block.instances) |inst| {
        var buf: std.Io.Writer.Allocating = .init(a);
        const rendered = render_html.renderHubSvg(&ctx, &buf.writer, a, &.{}, inst.ref_des) catch continue;
        if (!rendered) continue;
        _ = try translateAll(a, buf.written(), .{}, null);
    }
    return true;
}

/// Strict-translate every design under `dir`. Returns how many design files
/// were swept — zero when the tree isn't checked out or can't be read, which is
/// the case in a worktree (`projects/designs` is a separate repo, empty here).
fn sweepProjectDesigns(a: Allocator, project_dir: []const u8, dir_path: []const u8) !usize {
    var dir = @import("infra/fs.zig").cwd().openDir(dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close();
    var n: usize = 0;
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".sexp")) continue;
        const path = try std.fs.path.join(a, &.{ dir_path, entry.name });
        if (try sweepOneDesign(a, project_dir, path)) n += 1;
    }
    return n;
}

// spec: svg2pdf - The full-project sweep skips gracefully when the design tree read fails or is not checked out
test "the projects/designs strictness sweep runs where designs exist and skips where they do not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Plan validation item 5: every checked-out design must translate in strict
    // mode. `projects/designs` is a SEPARATE repo, so in a worktree it is empty —
    // the sweep then reports zero rather than failing the suite. Where designs do
    // exist (a full checkout, CI) any renderer drift surfaces as a translation
    // error propagated out of here.
    const dirs = [_][]const u8{ "projects/designs/src/boards", "projects/designs/src", "no/such/dir" };
    for (dirs) |d| _ = try sweepProjectDesigns(a, "projects/designs", d);
    // An unreadable directory is the graceful-skip case, asserted explicitly.
    try testing.expectEqual(@as(usize, 0), try sweepProjectDesigns(a, "projects/designs", "no/such/dir"));
}

// spec: svg2pdf - Translates the block-icon polygon glyph the draw layer can emit
test "a block-icon polygon glyph translates into filled and stroked polygons" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // drawBlockIcon is the subset's only polygon emitter, so drive it directly:
    // it is currently unreachable from renderHubSvg, and the translator must not
    // be the thing that breaks when it is wired back up.
    var buf: std.Io.Writer.Allocating = .init(a);
    const w = &buf.writer;
    try w.writeAll("<svg viewBox=\"0 0 200 120\">\n");
    try @import("render_svg/draw.zig").drawBlockIcon(w, "amplifier", 60, 40, "#4a9eff");
    try @import("render_svg/draw.zig").drawBlockIcon(w, "ldo", 140, 40, "#e8c547");
    try w.writeAll("</svg>");

    const ops = try opsOf(a, buf.written(), .print);
    var kinds = std.EnumArray(std.meta.Tag(DrawOp), usize).initFill(0);
    countKinds(ops, &kinds);
    try testing.expectEqual(@as(usize, 3), kinds.get(.polygon)); // amp triangle + 2 LDO arrows
    try testing.expect(kinds.get(.text) >= 3);
    // The amplifier triangle is stroked, not filled; the LDO arrows are filled.
    try testing.expect(ops[0].polygon.fill == null and ops[0].polygon.stroke != null);
}

// ── Fuzz harness (validation item 6) ─────────────────────────────────────

const fuzz_corpus = [_][]const u8{
    "",
    "<svg viewBox=\"0 0 4 4\"></svg>",
    "<svg viewBox=\"0 0 4 4\"><line x1=\"0\" y1=\"0\" x2=\"1\" y2=\"1\" stroke=\"#4a9\"/></svg>",
    "<svg viewBox=\"0 0 4 4\"><path d=\"M 0 0 A 1 1 0 0 1 2 0\" stroke=\"#8888cc\"/></svg>",
    "<svg viewBox=\"0 0 4 4\"><g class=\"net\"><text x=\"1\" y=\"1\">&amp;&lt;&#39;</text></g></svg>",
    "<svg viewBox=\"0 0 4 4\"><polyline points=\"0,0 1,1\"/>",
};

/// A rejection is the expected outcome for arbitrary bytes, so no particular
/// error is demanded. What must hold is that the reported offset stays inside
/// the input — an out-of-range offset would mean the scanner walked past the end
/// of the buffer, which is the bug class this harness exists to catch.
fn rejected(err: Error, diag: Diagnostic, len: usize) void {
    if (err == error.OutOfMemory) return; // allocator pressure, not a parse verdict
    std.debug.assert(diag.offset <= len);
}

/// Run both entry points over `src` and assert only the rejection invariant.
fn fuzzOne(a: Allocator, src: []const u8, theme: Theme) void {
    var diag: Diagnostic = .{};
    if (translate(a, src, .{ .theme = theme }, &diag)) |_| {} else |err| rejected(err, diag, src.len);
    diag = .{};
    if (translateAll(a, src, .{ .theme = theme }, &diag)) |_| {} else |err| rejected(err, diag, src.len);
}

/// One fuzz iteration: arbitrary bytes — raw, and wrapped in a well-formed root
/// so the mutator reaches the element scanner — must never crash the translator.
/// The arena reclaims every display list, so `testing.allocator` stays leak-free.
fn fuzzTranslate(allocator: Allocator, smith: *std.testing.Smith) anyerror!void {
    var generated: [64 * 1024]u8 = undefined;
    const input = smith.in orelse generated[0..smith.slice(&generated)];
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    fuzzOne(a, input, .print);
    fuzzOne(a, input, .screen);
    fuzzOne(a, try std.fmt.allocPrint(a, "<svg viewBox=\"0 0 9 9\">{s}</svg>", .{input}), .print);
}

// spec: svg2pdf - Fuzzing the translator with arbitrary bytes never panics and never leaks
test "fuzz: arbitrary bytes translate or error, never panic" {
    try std.testing.fuzz(std.testing.allocator, fuzzTranslate, .{ .corpus = &fuzz_corpus });
}
