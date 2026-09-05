//! Minimal deterministic PDF 1.4 writer — the output backend for the schematic
//! PDF export (`docs/archive/pdf-export-plan.md`, WP-A). Hand-rolled for the same
//! reason `png.zig` / `deflate.zig` / `export_gerber.zig` are: a single Zig
//! binary with no image or PDF library, and no prod deployment dependency for
//! one export feature.
//!
//! Scope is deliberately the smallest thing the composer needs: an object table
//! with a cross-reference table and trailer, a pages tree with a per-page
//! `MediaBox` (so page sizes may differ), one **uncompressed** content stream
//! per page, and the base-14 fonts (nothing embedded). Uncompressed streams
//! keep the bytes greppable in tests and the goldens diffable; a `FlateDecode`
//! toggle over `deflate.zig` is Phase 2.
//!
//! Two invariants shape the API:
//!
//! * **y-down callers.** SVG, the schematic renderers, and the composer all
//!   measure y downward from the top; PDF user space measures it upward from
//!   the bottom. Every page helper converts arithmetically (`y' = height − y`)
//!   as it writes each coordinate. It never installs a `scale(1,-1)` CTM flip —
//!   that mirrors glyphs, and is the classic trap this module is written to
//!   avoid. `translate` negates its dy for the same reason.
//! * **Determinism.** No `/CreationDate` unless the caller injects one through
//!   `Options.timestamp`; fixed object numbering; fixed 2-decimal number
//!   formatting; non-finite and out-of-range values saturate rather than
//!   printing an exponent. Two identical build runs produce byte-identical
//!   files.
//!
//! Every drawing operator wraps itself in `q … Q`, so graphics state (colour,
//! line width, dash) can never leak from one operation into the next and the
//! stream is balanced by construction. `validate` re-proves that on the emitted
//! bytes.

const std = @import("std");
const afm = @import("pdf_afm.zig");
const numeric = @import("numeric.zig");
const pdf_verify = @import("pdf_verify.zig");

/// The base-14 faces a page can select (see `pdf_afm.Font`).
pub const Font = afm.Font;

/// Advance width of `s` in points when set in `font` at `size`, measured over
/// the WinAnsi bytes the page would actually draw. Anchor math uses this.
pub const textWidth = afm.textWidth;

/// UTF-8 → WinAnsi encoding, exposed for callers that need to inspect what a
/// string will become (fallback expansions, `?` substitutions).
pub const encodeWinAnsi = afm.encodeWinAnsi;

/// Structural self-check over finished document bytes (see `pdf_verify`).
pub const validate = pdf_verify.validate;

/// Errors `validate` reports, one per structural invariant.
pub const ValidateError = pdf_verify.ValidateError;

/// A4 landscape width in points — the page size the composer uses throughout.
pub const a4_landscape_w: f64 = 841.89;

/// A4 landscape height in points.
pub const a4_landscape_h: f64 = 595.28;

/// Largest coordinate magnitude, in points, the writer will print. Anything
/// beyond (including infinities) saturates here, so a runaway or hostile value
/// can never emit an exponent-notation token or a megabyte-long number.
const coord_limit: f64 = 1.0e6;

/// Cap on dash-array entries actually written, bounding output size.
const max_dash_entries: usize = 16;

/// Bézier control-point distance for a quarter circle, as a fraction of the
/// radius (`4/3 · tan(π/8)`).
const quarter_kappa: f64 = 0.5522847498307933;

/// Errors every writer entry point can produce. `WriteFailed` (from
/// `std.Io.Writer`) is how allocation failure surfaces out of the content
/// buffers, matching `png.zig`'s convention.
pub const Error = std.mem.Allocator.Error || std.Io.Writer.Error;

/// A point in the caller's y-down page space, in PDF points (1/72 inch).
pub const Point = struct { x: f64, y: f64 };

/// An axis-aligned rectangle in y-down page space; `x`,`y` is the TOP-left
/// corner and `h` grows downward.
pub const Rect = struct { x: f64, y: f64, w: f64, h: f64 };

/// A device-RGB colour; each channel is clamped to 0…1 when written.
pub const Rgb = struct { r: f64, g: f64, b: f64 };

/// Black, the default for strokes and text.
pub const black: Rgb = .{ .r = 0, .g = 0, .b = 0 };

/// How an outline is stroked. `dash` is an on/off length sequence in points; an
/// empty (or all-zero) sequence means solid.
pub const Stroke = struct {
    color: Rgb = black,
    width: f64 = 1.0,
    dash: []const f64 = &.{},
    dash_phase: f64 = 0,
};

/// How a closed shape is painted. Either side may be omitted: stroke only,
/// fill only, or both (fill first, then stroke, as PDF's `B` operator does).
pub const Paint = struct { stroke: ?Stroke = null, fill: ?Rgb = null };

/// Horizontal placement of a text run about its anchor point, matching SVG's
/// `text-anchor`.
pub const Anchor = enum { start, middle, end };

/// How a text run is drawn. `size` is the em size in points.
pub const TextStyle = struct {
    font: Font = .helvetica,
    size: f64 = 10,
    color: Rgb = black,
    anchor: Anchor = .start,
};

/// A single elliptical arc in SVG's endpoint parameterization (the one form the
/// schematic emitters produce: `M x y A rx ry 0 0 1 x y`). The x-axis rotation
/// is always 0 — no emitter uses it — so it is not a field.
pub const Arc = struct {
    start: Point,
    end: Point,
    rx: f64,
    ry: f64,
    large_arc: bool = false,
    sweep: bool = true,
};

/// Document metadata. `timestamp` is the ONLY source of a `/CreationDate`: pass
/// null (the default) for a byte-reproducible file, or a PDF date string such as
/// `"D:20260729120000Z"` when a human-visible stamp is wanted.
pub const Options = struct { title: []const u8 = "", timestamp: ?[]const u8 = null };

/// One page and its content stream. Obtained from `Doc.beginPage`; owned by the
/// `Doc` and stable in memory for the document's lifetime. Every method takes
/// y-down coordinates.
pub const Page = struct {
    /// Page width in points (the `MediaBox` upper x).
    width: f64,
    /// Page height in points; the pivot for the y-down → y-up conversion.
    height: f64,
    content: std.Io.Writer.Allocating,
    /// Unmatched `save` calls. `Doc.finish` closes any that remain so the
    /// stream is balanced even after a caller mistake.
    depth: u32,

    /// Convert a caller-space (y-down) ordinate to PDF user space (y-up).
    fn flip(p: *const Page, y: f64) f64 {
        return p.height - y;
    }

    /// Draw a straight segment from `a` to `b`.
    pub fn line(p: *Page, a: Point, b: Point, s: Stroke) Error!void {
        try p.polyline(&.{ a, b }, s);
    }

    /// Stroke an open polyline through `pts`. Fewer than 2 points draws nothing.
    pub fn polyline(p: *Page, pts: []const Point, s: Stroke) Error!void {
        if (pts.len < 2) return;
        try p.beginState(.{ .stroke = s });
        try p.emitPolyPath(pts);
        try p.endState("S\n");
    }

    /// Paint a closed polygon through `pts`. Fewer than 3 points draws nothing.
    pub fn polygon(p: *Page, pts: []const Point, paint: Paint) Error!void {
        if (pts.len < 3) return;
        try p.beginState(paint);
        try p.emitPolyPath(pts);
        try p.content.writer.writeAll("h\n");
        try p.endState(paintOp(paint));
    }

    /// Paint an axis-aligned rectangle. `r.y` is its top edge.
    pub fn rect(p: *Page, r: Rect, paint: Paint) Error!void {
        try p.beginState(paint);
        try p.emitRe(r);
        try p.endState(paintOp(paint));
    }

    /// Paint a circle of radius `r` about `center`, as four cubic Béziers.
    pub fn circle(p: *Page, center: Point, r: f64, paint: Paint) Error!void {
        if (!(r > 0)) return;
        try p.beginState(paint);
        try p.emitCirclePath(center, r);
        try p.content.writer.writeAll("h\n");
        try p.endState(paintOp(paint));
    }

    /// Stroke a single elliptical arc, approximated by up to four cubic
    /// Béziers. A degenerate arc (zero radius, coincident endpoints) strokes
    /// the chord instead, which is what SVG specifies.
    pub fn arc(p: *Page, a: Arc, s: Stroke) Error!void {
        try p.beginState(.{ .stroke = s });
        try p.emitArcPath(a);
        try p.endState("S\n");
    }

    /// Draw `s` (UTF-8; encoded to WinAnsi on the way out) with its baseline at
    /// `at`, aligned about `at.x` per `st.anchor`.
    pub fn text(p: *Page, at: Point, s: []const u8, st: TextStyle) Error!void {
        const gpa = p.content.allocator;
        const enc = try afm.encodeWinAnsi(gpa, s);
        defer gpa.free(enc);
        const size = clampCoord(st.size);
        const advance = afm.widthOfEncoded(st.font, size, enc);
        const x = switch (st.anchor) {
            .start => at.x,
            .middle => at.x - advance / 2.0,
            .end => at.x - advance,
        };
        const w = &p.content.writer;
        try w.writeAll("q\nBT\n");
        try w.print("/{s} ", .{fontResource(st.font)});
        try num(w, size);
        try w.writeAll(" Tf\n");
        try emitRgb(w, st.color, "rg");
        try emitPair(w, x, p.flip(at.y));
        try w.writeAll("Td\n");
        try writeLiteral(w, enc);
        try w.writeAll(" Tj\nET\nQ\n");
    }

    /// Push the graphics state (`q`) so a clip or translation can be unwound.
    pub fn save(p: *Page) Error!void {
        p.depth += 1;
        try p.content.writer.writeAll("q\n");
    }

    /// Pop the graphics state (`Q`). A `restore` with no matching `save` is
    /// ignored rather than emitting an unbalanced stream.
    pub fn restore(p: *Page) Error!void {
        if (p.depth == 0) return;
        p.depth -= 1;
        try p.content.writer.writeAll("Q\n");
    }

    /// Intersect the clip path with `r` (y-down). Persists until the enclosing
    /// `save` is restored — the mechanism for slicing tall content across pages.
    pub fn clipRect(p: *Page, r: Rect) Error!void {
        try p.emitRe(r);
        try p.content.writer.writeAll("W\nn\n");
    }

    /// Shift the coordinate system by `dx` right and `dy` DOWN (caller space),
    /// which is `-dy` in PDF user space. Pair with `save`/`restore`.
    pub fn translate(p: *Page, dx: f64, dy: f64) Error!void {
        const w = &p.content.writer;
        try w.writeAll("1 0 0 1 ");
        try emitPair(w, dx, -dy);
        try w.writeAll("cm\n");
    }

    /// Open a `q` block and set the colour / line-width / dash state the
    /// operation needs.
    fn beginState(p: *Page, paint: Paint) Error!void {
        const w = &p.content.writer;
        try w.writeAll("q\n");
        if (paint.fill) |c| try emitRgb(w, c, "rg");
        if (paint.stroke) |s| {
            try emitRgb(w, s.color, "RG");
            try num(w, @abs(clampCoord(s.width)));
            try w.writeAll(" w\n");
            try emitDash(w, s);
        }
    }

    /// Write the paint operator and close the `q` block.
    fn endState(p: *Page, op: []const u8) Error!void {
        try p.content.writer.writeAll(op);
        try p.content.writer.writeAll("Q\n");
    }

    /// `x y m` — start a subpath (y flipped).
    fn moveTo(p: *Page, a: Point) Error!void {
        const w = &p.content.writer;
        try emitPair(w, a.x, p.flip(a.y));
        try w.writeAll("m\n");
    }

    /// `x y l` — extend the subpath (y flipped).
    fn lineTo(p: *Page, a: Point) Error!void {
        const w = &p.content.writer;
        try emitPair(w, a.x, p.flip(a.y));
        try w.writeAll("l\n");
    }

    /// `x1 y1 x2 y2 x3 y3 c` — cubic Bézier (all three points y flipped, which
    /// mirrors the curve exactly as it mirrors its endpoints).
    fn curveTo(p: *Page, c1: Point, c2: Point, to: Point) Error!void {
        const w = &p.content.writer;
        try emitPair(w, c1.x, p.flip(c1.y));
        try emitPair(w, c2.x, p.flip(c2.y));
        try emitPair(w, to.x, p.flip(to.y));
        try w.writeAll("c\n");
    }

    /// `x y w h re` — a rectangle primitive, converted from top-left y-down to
    /// bottom-left y-up.
    fn emitRe(p: *Page, r: Rect) Error!void {
        const w = &p.content.writer;
        try emitPair(w, r.x, p.flip(r.y + r.h));
        try emitPair(w, r.w, r.h);
        try w.writeAll("re\n");
    }

    /// Move to the first point then line to the rest.
    fn emitPolyPath(p: *Page, pts: []const Point) Error!void {
        try p.moveTo(pts[0]);
        for (pts[1..]) |pt| try p.lineTo(pt);
    }

    /// Four-Bézier circle, starting at the rightmost point.
    fn emitCirclePath(p: *Page, center: Point, r: f64) Error!void {
        const k = quarter_kappa * r;
        const cx = center.x;
        const cy = center.y;
        try p.moveTo(.{ .x = cx + r, .y = cy });
        try p.curveTo(.{ .x = cx + r, .y = cy + k }, .{ .x = cx + k, .y = cy + r }, .{ .x = cx, .y = cy + r });
        try p.curveTo(.{ .x = cx - k, .y = cy + r }, .{ .x = cx - r, .y = cy + k }, .{ .x = cx - r, .y = cy });
        try p.curveTo(.{ .x = cx - r, .y = cy - k }, .{ .x = cx - k, .y = cy - r }, .{ .x = cx, .y = cy - r });
        try p.curveTo(.{ .x = cx + k, .y = cy - r }, .{ .x = cx + r, .y = cy - k }, .{ .x = cx + r, .y = cy });
    }

    /// Move to the arc's start then approximate its sweep with cubic segments.
    fn emitArcPath(p: *Page, a: Arc) Error!void {
        try p.moveTo(a.start);
        const e = ellipseFor(a) orelse {
            try p.lineTo(a.end);
            return;
        };
        const segs = segmentCount(e.sweep);
        var i: u32 = 0;
        while (i < segs) : (i += 1) {
            const t0 = e.angleAt(i, segs);
            const t1 = e.angleAt(i + 1, segs);
            const seg = bezierFor(e, t0, t1);
            try p.curveTo(seg[0], seg[1], seg[2]);
        }
    }
};

/// A PDF document under construction: `init`, `beginPage` … draw …, `finish`,
/// `deinit`. Pages are heap-allocated so the `*Page` handles stay valid as more
/// pages are added.
pub const Doc = struct {
    gpa: std.mem.Allocator,
    opts: Options,
    pages: std.ArrayList(*Page),

    /// Start an empty document. `opts.timestamp` decides whether the output
    /// carries a `/CreationDate` at all.
    pub fn init(gpa: std.mem.Allocator, opts: Options) Doc {
        return .{ .gpa = gpa, .opts = opts, .pages = .empty };
    }

    /// Release every page's content buffer. Bytes handed back by `finish` are
    /// owned by the caller and survive this.
    pub fn deinit(d: *Doc) void {
        for (d.pages.items) |p| {
            p.content.deinit();
            d.gpa.destroy(p);
        }
        d.pages.deinit(d.gpa);
    }

    /// Append a page of `w_pt` × `h_pt` (saturated into 1…1e6 pt) and return a
    /// handle whose helpers take y-down coordinates.
    pub fn beginPage(d: *Doc, w_pt: f64, h_pt: f64) Error!*Page {
        const p = try d.gpa.create(Page);
        errdefer d.gpa.destroy(p);
        p.* = .{
            .width = clampSize(w_pt),
            .height = clampSize(h_pt),
            .content = .init(d.gpa),
            .depth = 0,
        };
        errdefer p.content.deinit();
        try d.pages.append(d.gpa, p);
        return p;
    }

    /// Serialize the whole file. The returned bytes are owned by the caller.
    /// Object numbering is fixed — catalog, pages tree, the four fonts, then
    /// each page with its content stream, then the optional info dictionary —
    /// so two identical documents serialize identically.
    pub fn finish(d: *Doc) Error![]u8 {
        for (d.pages.items) |p| {
            while (p.depth > 0) try p.restore();
        }
        var out: std.Io.Writer.Allocating = .init(d.gpa);
        errdefer out.deinit();
        var e: Emit = .{ .gpa = d.gpa, .out = &out };
        defer e.offsets.deinit(d.gpa);

        try out.writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");
        try d.writeCatalog(&e);
        try writeFonts(&e);
        try d.writePages(&e);
        const info = try d.writeInfo(&e);
        try e.writeXref(info);
        return out.toOwnedSlice();
    }

    /// Object 1 (catalog) and object 2 (the pages tree).
    fn writeCatalog(d: *Doc, e: *Emit) Error!void {
        try e.beginObj(1);
        try e.out.writer.writeAll("<< /Type /Catalog /Pages 2 0 R >>\n");
        try e.endObj();

        try e.beginObj(2);
        try e.out.writer.writeAll("<< /Type /Pages /Kids [");
        for (d.pages.items, 0..) |_, i| try e.out.writer.print(" {d} 0 R", .{pageObj(i)});
        try e.out.writer.print(" ] /Count {d} >>\n", .{d.pages.items.len});
        try e.endObj();
    }

    /// One page object plus its content stream per page.
    fn writePages(d: *Doc, e: *Emit) Error!void {
        for (d.pages.items, 0..) |p, i| {
            try e.beginObj(pageObj(i));
            try e.out.writer.writeAll("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ");
            try num(&e.out.writer, p.width);
            try e.out.writer.writeAll(" ");
            try num(&e.out.writer, p.height);
            try e.out.writer.writeAll("] /Resources << /Font << ");
            for (std.enums.values(Font), 0..) |f, k| {
                try e.out.writer.print("/{s} {d} 0 R ", .{ fontResource(f), first_font_obj + k });
            }
            try e.out.writer.print(">> >> /Contents {d} 0 R >>\n", .{contentObj(i)});
            try e.endObj();

            const body = p.content.written();
            try e.beginObj(contentObj(i));
            try e.out.writer.print("<< /Length {d} >>\nstream\n", .{body.len});
            try e.out.writer.writeAll(body);
            try e.out.writer.writeAll("\nendstream\n");
            try e.endObj();
        }
    }

    /// Optional info dictionary. Returns its object number, or null when the
    /// caller supplied neither a title nor a timestamp.
    fn writeInfo(d: *Doc, e: *Emit) Error!?u32 {
        if (d.opts.title.len == 0 and d.opts.timestamp == null) return null;
        const n = infoObj(d.pages.items.len);
        try e.beginObj(n);
        try e.out.writer.writeAll("<< /Producer (netlisp)");
        if (d.opts.title.len > 0) {
            const enc = try afm.encodeWinAnsi(d.gpa, d.opts.title);
            defer d.gpa.free(enc);
            try e.out.writer.writeAll(" /Title ");
            try writeLiteral(&e.out.writer, enc);
        }
        if (d.opts.timestamp) |ts| {
            const enc = try afm.encodeWinAnsi(d.gpa, ts);
            defer d.gpa.free(enc);
            try e.out.writer.writeAll(" /CreationDate ");
            try writeLiteral(&e.out.writer, enc);
        }
        try e.out.writer.writeAll(" >>\n");
        try e.endObj();
        return n;
    }
};

/// Object number of the first font; the four fonts occupy 3…6 in `Font` order.
const first_font_obj: u32 = 3;

/// Object number of page `i`'s page dictionary.
fn pageObj(i: usize) u32 {
    return @intCast(first_font_obj + std.enums.values(Font).len + i * 2);
}

/// Object number of page `i`'s content stream.
fn contentObj(i: usize) u32 {
    return pageObj(i) + 1;
}

/// Object number of the info dictionary for a document of `n_pages` pages.
fn infoObj(n_pages: usize) u32 {
    return @intCast(first_font_obj + std.enums.values(Font).len + n_pages * 2);
}

/// The four base-14 font objects, in `Font` declaration order.
fn writeFonts(e: *Emit) Error!void {
    for (std.enums.values(Font), 0..) |f, i| {
        try e.beginObj(@intCast(first_font_obj + i));
        try e.out.writer.print(
            "<< /Type /Font /Subtype /Type1 /BaseFont /{s} /Encoding /WinAnsiEncoding >>\n",
            .{baseFontName(f)},
        );
        try e.endObj();
    }
}

/// PDF base-14 name of a font.
fn baseFontName(f: Font) []const u8 {
    return switch (f) {
        .courier => "Courier",
        .courier_bold => "Courier-Bold",
        .helvetica => "Helvetica",
        .helvetica_bold => "Helvetica-Bold",
    };
}

/// Page-resource name of a font (`/F1` … `/F4`), matching `writeFonts` order.
fn fontResource(f: Font) []const u8 {
    return switch (f) {
        .courier => "F1",
        .courier_bold => "F2",
        .helvetica => "F3",
        .helvetica_bold => "F4",
    };
}

/// Serialization scratch: the output buffer plus the byte offset of each
/// object, indexed by object number − 1, for the cross-reference table.
const Emit = struct {
    gpa: std.mem.Allocator,
    out: *std.Io.Writer.Allocating,
    offsets: std.ArrayList(usize) = .empty,

    /// Record `n`'s offset and write its `N 0 obj` header.
    fn beginObj(e: *Emit, n: u32) Error!void {
        while (e.offsets.items.len < n) try e.offsets.append(e.gpa, 0);
        e.offsets.items[n - 1] = e.out.written().len;
        try e.out.writer.print("{d} 0 obj\n", .{n});
    }

    /// Close the current object.
    fn endObj(e: *Emit) Error!void {
        try e.out.writer.writeAll("endobj\n");
    }

    /// The cross-reference table, trailer, and `startxref`. Entry 0 is the
    /// free-list head; each later entry is exactly 20 bytes, so a reader can
    /// index straight to object `n`.
    fn writeXref(e: *Emit, info: ?u32) Error!void {
        const xref_at = e.out.written().len;
        const count = e.offsets.items.len + 1;
        const w = &e.out.writer;
        try w.print("xref\n0 {d}\n0000000000 65535 f \n", .{count});
        for (e.offsets.items) |off| try w.print("{d:0>10} 00000 n \n", .{off});
        try w.print("trailer\n<< /Size {d} /Root 1 0 R", .{count});
        if (info) |n| try w.print(" /Info {d} 0 R", .{n});
        try w.print(" >>\nstartxref\n{d}\n%%EOF\n", .{xref_at});
    }
};

/// The path-painting operator matching a `Paint`: fill and stroke, fill only,
/// stroke only, or `n` (no paint) when neither is set.
fn paintOp(paint: Paint) []const u8 {
    if (paint.fill != null and paint.stroke != null) return "B\n";
    if (paint.fill != null) return "f\n";
    if (paint.stroke != null) return "S\n";
    return "n\n";
}

/// Clamp a page dimension into 1…`coord_limit` points, mapping NaN to A4's
/// short side so a garbage size still yields a usable page.
fn clampSize(v: f64) f64 {
    if (std.math.isNan(v)) return a4_landscape_h;
    return std.math.clamp(v, 1.0, coord_limit);
}

/// Round `v` to the 2 decimals the writer prints, saturating non-finite and
/// out-of-range values and normalising `-0` to `0`.
fn clampCoord(v: f64) f64 {
    if (std.math.isNan(v)) return 0;
    const c = std.math.clamp(v, -coord_limit, coord_limit);
    const r = @round(c * 100.0) / 100.0;
    return if (r == 0) 0 else r;
}

/// Write one PDF real: fixed 2 decimals, never exponent notation.
fn num(w: *std.Io.Writer, v: f64) Error!void {
    try w.print("{d:.2}", .{clampCoord(v)});
}

/// Write `x y ` — the coordinate pair every path operator is prefixed with.
fn emitPair(w: *std.Io.Writer, x: f64, y: f64) Error!void {
    try num(w, x);
    try w.writeAll(" ");
    try num(w, y);
    try w.writeAll(" ");
}

/// Write a colour and its selector (`rg` for fill, `RG` for stroke).
fn emitRgb(w: *std.Io.Writer, c: Rgb, op: []const u8) Error!void {
    try channel(w, c.r);
    try channel(w, c.g);
    try channel(w, c.b);
    try w.print("{s}\n", .{op});
}

/// Write one colour channel clamped to 0…1 at 3 decimals.
fn channel(w: *std.Io.Writer, v: f64) Error!void {
    const c = if (std.math.isNan(v)) 0 else std.math.clamp(v, 0.0, 1.0);
    try w.print("{d:.3} ", .{c});
}

/// Write the dash pattern, if any. An empty pattern, or one whose lengths all
/// round to zero (which some readers divide by), is left solid.
fn emitDash(w: *std.Io.Writer, s: Stroke) Error!void {
    if (s.dash.len == 0) return;
    const n = @min(s.dash.len, max_dash_entries);
    var total: f64 = 0;
    for (s.dash[0..n]) |v| total += @abs(clampCoord(v));
    if (total <= 0) return;
    try w.writeAll("[");
    for (s.dash[0..n], 0..) |v, i| {
        if (i > 0) try w.writeAll(" ");
        try num(w, @abs(v));
    }
    try w.writeAll("] ");
    try num(w, @abs(s.dash_phase));
    try w.writeAll(" d\n");
}

/// Write already-encoded WinAnsi bytes as a PDF literal string. Everything
/// outside printable ASCII becomes a `\ddd` octal escape, so the file stays
/// 7-bit and no byte can be mistaken for a delimiter.
fn writeLiteral(w: *std.Io.Writer, enc: []const u8) Error!void {
    try w.writeAll("(");
    for (enc) |b| {
        switch (b) {
            '(', ')', '\\' => try w.print("\\{c}", .{b}),
            0x20...0x27, 0x2A...0x5B, 0x5D...0x7E => try w.writeByte(b),
            else => try w.print("\\{o:0>3}", .{b}),
        }
    }
    try w.writeAll(")");
}

/// Centre parameterization of an arc: centre, radii, and the start/sweep angles
/// (radians, in the caller's y-down frame).
const Ellipse = struct {
    cx: f64,
    cy: f64,
    rx: f64,
    ry: f64,
    start: f64,
    sweep: f64,

    /// Angle at subdivision `i` of `segs` across the sweep.
    fn angleAt(e: Ellipse, i: u32, segs: u32) f64 {
        const t: f64 = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(segs));
        return e.start + e.sweep * t;
    }

    /// Point on the ellipse at angle `t`.
    fn at(e: Ellipse, t: f64) Point {
        return .{ .x = e.cx + e.rx * @cos(t), .y = e.cy + e.ry * @sin(t) };
    }

    /// Derivative of `at` with respect to `t`.
    fn tangent(e: Ellipse, t: f64) Point {
        return .{ .x = -e.rx * @sin(t), .y = e.ry * @cos(t) };
    }
};

/// Convert SVG endpoint-parameterized arc data to centre form, following the
/// SVG 1.1 implementation notes with the x-axis rotation fixed at 0. Returns
/// null for a degenerate arc, whose defined behaviour is a straight chord.
fn ellipseFor(a: Arc) ?Ellipse {
    var rx = @abs(clampCoord(a.rx));
    var ry = @abs(clampCoord(a.ry));
    const x1 = clampCoord(a.start.x);
    const y1 = clampCoord(a.start.y);
    const x2 = clampCoord(a.end.x);
    const y2 = clampCoord(a.end.y);
    const dx = (x1 - x2) / 2.0;
    const dy = (y1 - y2) / 2.0;
    if (rx < 1e-9 or ry < 1e-9) return null;
    if (@abs(dx) < 1e-12 and @abs(dy) < 1e-12) return null;

    const lam = (dx * dx) / (rx * rx) + (dy * dy) / (ry * ry);
    if (lam > 1.0) {
        const k = @sqrt(lam);
        rx *= k;
        ry *= k;
    }
    const den = rx * rx * dy * dy + ry * ry * dx * dx;
    if (!(den > 0)) return null;
    const ratio = (rx * rx * ry * ry - den) / den;
    const sign: f64 = if (a.large_arc != a.sweep) 1.0 else -1.0;
    const co = sign * @sqrt(@max(0.0, ratio));
    const cxp = co * rx * dy / ry;
    const cyp = co * -ry * dx / rx;
    const t0 = std.math.atan2((dy - cyp) / ry, (dx - cxp) / rx);
    const t1 = std.math.atan2((-dy - cyp) / ry, (-dx - cxp) / rx);
    var sweep = t1 - t0;
    if (!a.sweep and sweep > 0) sweep -= 2.0 * std.math.pi;
    if (a.sweep and sweep < 0) sweep += 2.0 * std.math.pi;
    return .{
        .cx = cxp + (x1 + x2) / 2.0,
        .cy = cyp + (y1 + y2) / 2.0,
        .rx = rx,
        .ry = ry,
        .start = t0,
        .sweep = sweep,
    };
}

/// How many cubic segments a sweep needs — one per quarter turn, so the
/// worst-case error stays well under a printer dot.
fn segmentCount(sweep: f64) u32 {
    const quarters = @abs(sweep) / (std.math.pi / 2.0);
    const n = numeric.checkedInt(u32, @ceil(quarters)) orelse 1;
    return @max(1, @min(4, n));
}

/// Control points and endpoint of the cubic that approximates `e` from angle
/// `t0` to `t1` (the standard `4/3·tan(Δ/4)` tangent scaling).
fn bezierFor(e: Ellipse, t0: f64, t1: f64) [3]Point {
    const alpha = (4.0 / 3.0) * @tan((t1 - t0) / 4.0);
    const p0 = e.at(t0);
    const p1 = e.at(t1);
    const d0 = e.tangent(t0);
    const d1 = e.tangent(t1);
    return .{
        .{ .x = p0.x + alpha * d0.x, .y = p0.y + alpha * d0.y },
        .{ .x = p1.x - alpha * d1.x, .y = p1.y - alpha * d1.y },
        p1,
    };
}

test {
    _ = @import("pdf_afm.zig");
    _ = @import("pdf_verify.zig");
}

/// Draw one of everything onto `p`, so a single call covers the whole operator
/// surface in the structural tests.
fn drawEverything(p: *Page) Error!void {
    const teal: Rgb = .{ .r = 0.1, .g = 0.6, .b = 0.6 };
    try p.line(.{ .x = 10, .y = 10 }, .{ .x = 120, .y = 44 }, .{});
    try p.polyline(&.{
        .{ .x = 20, .y = 60 },
        .{ .x = 60, .y = 60 },
        .{ .x = 60, .y = 90 },
    }, .{ .color = teal, .width = 0.6, .dash = &.{ 3, 2 }, .dash_phase = 1 });
    try p.rect(.{ .x = 140, .y = 20, .w = 90, .h = 40 }, .{ .stroke = .{}, .fill = teal });
    try p.circle(.{ .x = 260, .y = 40 }, 9, .{ .fill = black });
    try p.polygon(&.{
        .{ .x = 300, .y = 20 },
        .{ .x = 330, .y = 55 },
        .{ .x = 280, .y = 55 },
    }, .{ .stroke = .{ .width = 1.4 } });
    try p.arc(.{ .start = .{ .x = 360, .y = 50 }, .end = .{ .x = 396, .y = 50 }, .rx = 18, .ry = 18 }, .{});
    try p.text(.{ .x = 40, .y = 120 }, "U1 STM32N657", .{ .font = .courier_bold, .size = 11 });
    try p.text(.{ .x = 200, .y = 120 }, "3.3 V / 470 mA", .{ .anchor = .middle });
    try p.text(.{ .x = 400, .y = 120 }, "\u{03A9} \u{00B5}F \u{00B1}1 %", .{ .font = .helvetica_bold, .anchor = .end });
}

/// Assert `want` appears in `bytes`; on failure, diff it against the whole
/// document so the emitted content stream is visible in the test output.
fn expectContains(bytes: []const u8, want: []const u8) !void {
    if (std.mem.indexOf(u8, bytes, want) == null) {
        return std.testing.expectEqualStrings(want, bytes);
    }
}

/// Copy `bytes` and change the decimal digit immediately after `needle` to a
/// different digit. The mutation preserves the file length, so every other
/// offset stays valid and only the invariant under test breaks.
fn bumpDigitAfter(gpa: std.mem.Allocator, bytes: []const u8, needle: []const u8) ![]u8 {
    const copy = try gpa.dupe(u8, bytes);
    errdefer gpa.free(copy);
    const found = std.mem.indexOf(u8, copy, needle) orelse return error.TestNeedleMissing;
    const at = found + needle.len;
    copy[at] = if (copy[at] == '1') '2' else '1';
    return copy;
}

// spec: pdf - a multi-page document exercising every drawing operation passes the structural self-check
test "pdf writer: a mixed-size multi-page document with every operation validates" {
    const alloc = std.testing.allocator;
    var doc: Doc = .init(alloc, .{ .title = "Netlisp Review", .timestamp = "D:20260729120000Z" });
    defer doc.deinit();

    const wide = try doc.beginPage(a4_landscape_w, a4_landscape_h);
    try drawEverything(wide);
    const tall = try doc.beginPage(a4_landscape_h, a4_landscape_w);
    try tall.save();
    try tall.clipRect(.{ .x = 0, .y = 0, .w = 300, .h = 300 });
    try tall.translate(12, 24);
    try drawEverything(tall);
    try tall.restore();

    const bytes = try doc.finish();
    defer alloc.free(bytes);
    try validate(bytes);
    // Per-page MediaBox: the two pages really carry different sizes.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/MediaBox [0 0 841.89 595.28]") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/MediaBox [0 0 595.28 841.89]") != null);
    // Base-14 fonts only, WinAnsi-encoded, nothing embedded.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/BaseFont /Courier-Bold /Encoding /WinAnsiEncoding") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/FontFile") == null);
}

// spec: pdf - page helpers take y-down coordinates and emit them flipped by the page height, never a mirroring transform
test "pdf writer: y-down coordinates flip arithmetically, not by a mirror transform" {
    const alloc = std.testing.allocator;
    var doc: Doc = .init(alloc, .{});
    defer doc.deinit();
    const page_h: f64 = 600;
    const p = try doc.beginPage(400, page_h);
    try p.text(.{ .x = 50, .y = 100 }, "Ref", .{});
    try p.line(.{ .x = 5, .y = 200 }, .{ .x = 6, .y = 210 }, .{});
    try p.rect(.{ .x = 8, .y = 300, .w = 40, .h = 20 }, .{ .stroke = .{} });

    const bytes = try doc.finish();
    defer alloc.free(bytes);
    try validate(bytes);

    var buf: [96]u8 = undefined;
    // Text baseline, path start, and rect edge all read `page_h - y`.
    try expectContains(bytes, try std.fmt.bufPrint(&buf, "50.00 {d:.2} Td", .{page_h - 100}));
    try expectContains(bytes, try std.fmt.bufPrint(&buf, "5.00 {d:.2} m", .{page_h - 200}));
    try expectContains(bytes, try std.fmt.bufPrint(
        &buf,
        "8.00 {d:.2} 40.00 20.00 re",
        .{page_h - (300 + 20)},
    ));
    // No CTM carries a negative vertical scale — that would mirror glyphs.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "-1.00 cm") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "-1 cm") == null);
}

// spec: pdf - Courier advances a fixed 600/1000 em and the Helvetica tables give per-glyph widths
test "pdf writer: textWidth is exact for Courier and table-driven for Helvetica" {
    // Courier: four glyphs at 600/1000 em, 10 pt.
    try std.testing.expectApproxEqAbs(@as(f64, 24.0), textWidth(.courier, 10, "VDD3"), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 24.0), textWidth(.courier_bold, 10, "VDD3"), 1e-9);
    // Helvetica AFM spot checks: I=278, W=944, space=278, i=222, l=222.
    try std.testing.expectApproxEqAbs(@as(f64, 1222.0 * 12.0 / 1000.0), textWidth(.helvetica, 12, "IW"), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 722.0 * 10.0 / 1000.0), textWidth(.helvetica, 10, " il"), 1e-9);
    // Helvetica-Bold is wider than Helvetica for the same lowercase run.
    try std.testing.expect(textWidth(.helvetica_bold, 10, "mono") > textWidth(.helvetica, 10, "mono"));
}

// spec: pdf - middle and end text anchors shift the origin by half and all of the measured width
test "pdf writer: text anchors offset the origin by the measured width" {
    const alloc = std.testing.allocator;
    const style: TextStyle = .{ .font = .courier, .size = 10 };
    const advance = textWidth(style.font, style.size, "AB");
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), advance, 1e-9);

    // start keeps the anchor, middle backs off half the advance, end all of it.
    for ([_]Anchor{ .start, .middle, .end }, [_]f64{ 0, 0.5, 1.0 }) |anchor, share| {
        var doc: Doc = .init(alloc, .{});
        defer doc.deinit();
        const p = try doc.beginPage(300, 300);
        var st = style;
        st.anchor = anchor;
        try p.text(.{ .x = 100, .y = 50 }, "AB", st);
        const bytes = try doc.finish();
        defer alloc.free(bytes);
        var buf: [96]u8 = undefined;
        const want = try std.fmt.bufPrint(&buf, "{d:.2} 250.00 Td", .{100 - advance * share});
        try expectContains(bytes, want);
    }
}

// spec: pdf - a non-WinAnsi glyph encodes through the fallback table and an unmappable one becomes a question mark
test "pdf writer: WinAnsi encoding falls back explicitly and substitutes the rest" {
    const alloc = std.testing.allocator;
    const enc = try encodeWinAnsi(alloc, "10\u{03A9} \u{2192} \u{2264}\u{2265} 4\u{00D7} \u{4E2D}");
    defer alloc.free(enc);
    try std.testing.expectEqualStrings("10ohm -> <=>= 4x ?", enc);
    // Latin-1 glyphs WinAnsi does have survive as single bytes.
    const latin = try encodeWinAnsi(alloc, "\u{00B5}F \u{00B0}C \u{00B1}5%");
    defer alloc.free(latin);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xB5, 'F', ' ', 0xB0, 'C', ' ', 0xB1, '5', '%' }, latin);
}

// spec: pdf - malformed UTF-8 input encodes to question marks rather than raising
test "pdf writer: malformed UTF-8 becomes question marks and still writes a valid page" {
    const alloc = std.testing.allocator;
    const enc = try encodeWinAnsi(alloc, "A\xFFB\xC3");
    defer alloc.free(enc);
    try std.testing.expectEqualStrings("A?B?", enc);

    var doc: Doc = .init(alloc, .{});
    defer doc.deinit();
    const p = try doc.beginPage(200, 200);
    try p.text(.{ .x = 10, .y = 20 }, "\xC3\x28\xF0\x9F", .{});
    const bytes = try doc.finish();
    defer alloc.free(bytes);
    try validate(bytes);
}

// spec: pdf - two identical builds produce byte-identical output and a caller timestamp is the only variable
test "pdf writer: output is byte-reproducible unless the caller injects a timestamp" {
    const alloc = std.testing.allocator;
    const plain = try buildFixture(alloc, .{ .title = "Board" });
    defer alloc.free(plain);
    const again = try buildFixture(alloc, .{ .title = "Board" });
    defer alloc.free(again);
    try std.testing.expectEqualSlices(u8, plain, again);
    try std.testing.expect(std.mem.indexOf(u8, plain, "/CreationDate") == null);

    const stamped = try buildFixture(alloc, .{ .title = "Board", .timestamp = "D:20260729120000Z" });
    defer alloc.free(stamped);
    try std.testing.expect(std.mem.indexOf(u8, stamped, "/CreationDate (D:20260729120000Z)") != null);
    try std.testing.expect(!std.mem.eql(u8, plain, stamped));
}

/// Build the same small document twice-over fixture used by the determinism test.
fn buildFixture(gpa: std.mem.Allocator, opts: Options) Error![]u8 {
    var doc: Doc = .init(gpa, opts);
    defer doc.deinit();
    const p = try doc.beginPage(a4_landscape_w, a4_landscape_h);
    try drawEverything(p);
    return doc.finish();
}

// spec: pdf - an empty document and a page with no operations still emit a structurally valid file
test "pdf writer: an empty document and an empty page are structurally valid" {
    const alloc = std.testing.allocator;
    var empty: Doc = .init(alloc, .{});
    defer empty.deinit();
    const no_pages = try empty.finish();
    defer alloc.free(no_pages);
    try validate(no_pages);
    try std.testing.expect(std.mem.indexOf(u8, no_pages, "/Kids [ ] /Count 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_pages, "/Info") == null);

    var blank: Doc = .init(alloc, .{});
    defer blank.deinit();
    _ = try blank.beginPage(200, 200);
    const one_page = try blank.finish();
    defer alloc.free(one_page);
    try validate(one_page);
    try std.testing.expect(std.mem.indexOf(u8, one_page, "/Length 0") != null);
    // Degenerate shapes draw nothing rather than emitting a broken path.
    var degenerate: Doc = .init(alloc, .{});
    defer degenerate.deinit();
    const p = try degenerate.beginPage(100, 100);
    try p.polyline(&.{}, .{});
    try p.polygon(&.{.{ .x = 1, .y = 1 }}, .{ .fill = black });
    try p.circle(.{ .x = 5, .y = 5 }, 0, .{ .fill = black });
    try p.text(.{ .x = 5, .y = 5 }, "", .{});
    const bytes = try degenerate.finish();
    defer alloc.free(bytes);
    try validate(bytes);
}

// spec: pdf - a non-finite or out-of-range coordinate saturates to the writable range
test "pdf writer: non-finite and out-of-range values saturate instead of overflowing" {
    const alloc = std.testing.allocator;
    var doc: Doc = .init(alloc, .{});
    defer doc.deinit();
    const p = try doc.beginPage(std.math.nan(f64), std.math.inf(f64));
    try std.testing.expectApproxEqAbs(a4_landscape_h, p.width, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0e6), p.height, 1e-9);
    try p.line(
        .{ .x = 0, .y = 0 },
        .{ .x = std.math.inf(f64), .y = 1.0e300 },
        .{ .width = std.math.nan(f64), .color = .{ .r = 9, .g = -3, .b = std.math.nan(f64) } },
    );
    try p.arc(.{
        .start = .{ .x = std.math.nan(f64), .y = 0 },
        .end = .{ .x = 0, .y = 0 },
        .rx = std.math.inf(f64),
        .ry = 0,
    }, .{});
    const bytes = try doc.finish();
    defer alloc.free(bytes);
    try validate(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "1000000.00") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "0.00 w") != null);
    // Colour channels clamp into 0…1 rather than emitting an out-of-gamut real.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "1.000 0.000 0.000 RG") != null);
    // No exponent-notation real ever reaches the file.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "e+") == null);
}

// spec: pdf - a very large page count keeps one xref entry per object with matching offsets
test "pdf writer: a very large page count keeps the xref table consistent" {
    const alloc = std.testing.allocator;
    const pages: usize = 200;
    var doc: Doc = .init(alloc, .{});
    defer doc.deinit();
    for (0..pages) |_| {
        const p = try doc.beginPage(200, 120);
        try p.text(.{ .x = 8, .y = 20 }, "page", .{ .size = 8 });
    }
    const bytes = try doc.finish();
    defer alloc.free(bytes);
    // validate() re-derives every object offset from the table, so a passing
    // run proves all 406 entries point at their own `N 0 obj` header.
    try validate(bytes);
    const objects = 2 + std.enums.values(Font).len + pages * 2;
    var want: [32]u8 = undefined;
    const needle = try std.fmt.bufPrint(&want, "/Size {d} ", .{objects + 1});
    try std.testing.expect(std.mem.indexOf(u8, bytes, needle) != null);
}

// spec: pdf - the self-check rejects a corrupted stream length, xref offset, and unbalanced content stream
test "pdf writer: the self-check rejects corrupted lengths, offsets, and nesting" {
    const alloc = std.testing.allocator;
    const good = try buildFixture(alloc, .{ .title = "Board" });
    defer alloc.free(good);
    try validate(good);

    // Same-length mutations, so only the invariant under test breaks.
    const bad_len = try bumpDigitAfter(alloc, good, "/Length ");
    defer alloc.free(bad_len);
    try std.testing.expectError(error.StreamLengthMismatch, validate(bad_len));

    const bad_off = try bumpDigitAfter(alloc, good, "0000000000 65535 f \n");
    defer alloc.free(bad_off);
    try std.testing.expectError(error.ObjectOffsetMismatch, validate(bad_off));

    const unbalanced = try alloc.dupe(u8, good);
    defer alloc.free(unbalanced);
    const q_at = std.mem.indexOf(u8, unbalanced, "\nQ\n") orelse return error.TestNoRestoreOp;
    unbalanced[q_at + 1] = 'q';
    try std.testing.expectError(error.UnbalancedGraphicsState, validate(unbalanced));

    const header: ValidateError!void = validate("not a pdf");
    try std.testing.expectError(error.BadHeader, header);
    try std.testing.expectError(error.MissingStartxref, validate("%PDF-1.4\n1 0 obj\n"));
}

// spec: pdf - dash patterns, clip rectangles, and translation nest and unwind with the graphics-state stack
test "pdf writer: dash, clip, and translate nest and unwind with the state stack" {
    const alloc = std.testing.allocator;
    var doc: Doc = .init(alloc, .{});
    defer doc.deinit();
    const p = try doc.beginPage(400, 400);
    try p.save();
    try p.clipRect(.{ .x = 10, .y = 20, .w = 100, .h = 50 });
    try p.translate(10, 20);
    try p.line(.{ .x = 0, .y = 0 }, .{ .x = 30, .y = 0 }, .{ .dash = &.{ 3, 2 }, .dash_phase = 1 });
    try p.restore();
    // An unmatched restore is ignored rather than unbalancing the stream.
    try p.restore();
    // An all-zero dash pattern stays solid (readers divide by the period).
    try p.line(.{ .x = 0, .y = 8 }, .{ .x = 9, .y = 8 }, .{ .dash = &.{ 0, 0 } });
    // A page left with an open save is closed by finish().
    const open = try doc.beginPage(100, 100);
    try open.save();
    try open.translate(5, 5);
    try open.circle(.{ .x = 10, .y = 10 }, 4, .{ .fill = black });

    const bytes = try doc.finish();
    defer alloc.free(bytes);
    try validate(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "[3.00 2.00] 1.00 d") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "10.00 330.00 100.00 50.00 re\nW\nn\n") != null);
    // Downward translation is negated for PDF's y-up user space.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "1 0 0 1 10.00 -20.00 cm") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "[0.00 0.00]") == null);
    try std.testing.expectEqual(@as(u32, 0), open.depth);
}

/// Deterministic operation feed over fuzz input: every accessor consumes at
/// least one byte, so the driving loop always terminates.
const OpFeed = struct {
    bytes: []const u8,
    i: usize = 0,

    fn byte(f: *OpFeed) u8 {
        if (f.i >= f.bytes.len) return 0;
        defer f.i += 1;
        return f.bytes[f.i];
    }

    fn coord(f: *OpFeed) f64 {
        return @as(f64, @floatFromInt(f.byte())) * 6.0 - 300.0;
    }

    fn point(f: *OpFeed) Point {
        return .{ .x = f.coord(), .y = f.coord() };
    }

    fn done(f: *OpFeed) bool {
        return f.i >= f.bytes.len;
    }
};

/// Apply one fuzz-derived operation to `p`.
fn fuzzStep(p: *Page, f: *OpFeed, label: []const u8) Error!void {
    const dash = [_]f64{ 3, 2 };
    const paint: Paint = .{ .stroke = .{ .width = f.coord(), .dash = &dash }, .fill = black };
    switch (f.byte() % 10) {
        0 => try p.line(f.point(), f.point(), .{ .width = f.coord() }),
        1 => try p.polyline(&.{ f.point(), f.point(), f.point() }, .{ .dash = &dash }),
        2 => try p.polygon(&.{ f.point(), f.point(), f.point() }, paint),
        3 => try p.rect(.{ .x = f.coord(), .y = f.coord(), .w = f.coord(), .h = f.coord() }, paint),
        4 => try p.circle(f.point(), f.coord(), paint),
        5 => try p.arc(.{
            .start = f.point(),
            .end = f.point(),
            .rx = f.coord(),
            .ry = f.coord(),
            .large_arc = f.byte() & 1 == 1,
            .sweep = f.byte() & 2 == 2,
        }, .{}),
        6 => try p.text(f.point(), label, .{ .anchor = .middle, .size = f.coord() }),
        7 => try p.save(),
        8 => try p.restore(),
        else => try p.clipRect(.{ .x = f.coord(), .y = f.coord(), .w = f.coord(), .h = f.coord() }),
    }
}

/// One fuzz iteration: derive a page set and an operation sequence from `input`,
/// serialize, and require the structural self-check to pass. Runs under
/// `testing.allocator`, so a leak on any path fails too.
fn fuzzDocument(allocator: std.mem.Allocator, smith: *std.testing.Smith) anyerror!void {
    var generated: [64 * 1024]u8 = undefined;
    const input = smith.in orelse generated[0..smith.slice(&generated)];
    var f: OpFeed = .{ .bytes = input };
    var doc: Doc = .init(allocator, .{});
    defer doc.deinit();
    const pages: usize = 1 + (f.byte() % 3);
    var n: usize = 0;
    while (n < pages) : (n += 1) {
        const p = try doc.beginPage(f.coord(), f.coord());
        while (!f.done()) try fuzzStep(p, &f, input);
        f.i = 0;
        _ = f.byte();
    }
    const bytes = try doc.finish();
    defer allocator.free(bytes);
    try validate(bytes);
}

const pdf_fuzz_corpus = [_][]const u8{
    "",
    "\x00",
    "\x06(Q q BT \\) label",
    &[_]u8{ 2, 7, 1, 200, 3, 9, 8, 8, 8, 4, 5, 250, 6, 6, 0, 0 },
};

// spec: pdf - fuzzing an arbitrary operation sequence never crashes and always passes the structural self-check
test "pdf writer: fuzzing an arbitrary operation sequence stays structurally valid" {
    try std.testing.fuzz(std.testing.allocator, fuzzDocument, .{ .corpus = &pdf_fuzz_corpus });
}
