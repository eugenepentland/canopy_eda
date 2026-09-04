//! Review-document PDF composer — the WP-C half of the schematic PDF export
//! (`docs/pdf-export-plan.md`). It is the *only* place `pdf.zig` (the byte
//! writer) and `svg2pdf.zig` (the SVG-subset translator) meet: the translator
//! hands back a flat `DrawOp` display list, and `drawOp` below maps each one
//! onto a page helper. That decoupling is deliberate — neither half knows the
//! other exists, so both stay independently testable.
//!
//! The document is `review_md.zig`'s markdown report in a second medium, built
//! from the same `review.ReviewDoc` and the same `render_html.renderHubSvg`
//! per-hub renders. Page order puts the verdict before the visuals, matching the
//! markdown:
//!
//!   1. cover — title, revision, generation stamp + build hash, status roll-up
//!   2. one or more pages per `(section …)`, the section's hub schematics flowed
//!      top-to-bottom
//!   3. validation appendix — ERC, assertions, requirement checks
//!   4. power budget, power sequencing, test points
//!
//! The system-overview block diagram the plan listed second is **deferred**: the
//! `diagram/` SVG carries its own ~80-rule stylesheet, which is outside the
//! translator's closed subset (feeding it in errors with `UnknownClass`). See
//! the Amendments note at the bottom of the plan.
//!
//! Two composition invariants:
//!
//! * **Pagination unit is one section — one sheet.** A section's hub blocks are
//!   shelf-packed left-to-right, top-to-bottom onto a single page by
//!   `gridBlocks`, at one uniform scale bisected down to `grid_min_scale`, each
//!   cell captioned with the pin-group label its `<h4>` carried. That is the
//!   hand-drawn-schematic reading: one sheet holds a whole subsystem. Only when
//!   even the floor cannot pack the section does the flow fall back to the
//!   older sequential ladder — one block per row, scaled DOWN to fit one page
//!   no further than `min_block_scale`, and a document still taller than a page
//!   at that floor sliced by clipping a horizontal band and translating the
//!   content up, with the section header repeated on each continuation page. A
//!   section whose hubs draw nothing at all claims no page: it flows inline as
//!   a compact heading-plus-notes entry.
//! * **Determinism.** Nothing here reads a clock. The visible generation stamp
//!   arrives through `Options.generated_at` (or `ReviewDoc.generated_at`) and
//!   the PDF `/CreationDate` only through `Options.timestamp`, so a fixed
//!   injected stamp yields byte-identical output.

const std = @import("std");
const pdf = @import("pdf.zig");
const svg2pdf = @import("svg2pdf.zig");
const env_mod = @import("eval/env.zig");
const rails_mod = @import("eval/rails.zig");
const review = @import("review.zig");
const req_checks = @import("req_checks.zig");
const erc_mod = @import("erc.zig");
const power_budget = @import("eval/power_budget.zig");
const power_sequencing = @import("eval/power_sequencing.zig");
const review_thermal = @import("review_thermal.zig");
const thermal = @import("eval/thermal.zig");
const thermal_scenarios = @import("thermal_scenarios.zig");
const render_html = @import("render_html.zig");
const membership = @import("diagram/membership.zig");
const draw = @import("render_svg/draw.zig");

const Allocator = std.mem.Allocator;
const DesignBlock = env_mod.DesignBlock;
const Section = env_mod.Section;
const RenderCtx = @import("render_svg/context.zig").RenderCtx;

/// Everything the composer needs that isn't derivable from the block or the
/// review document. Every field is injectable so a test can pin the output.
pub const Options = struct {
    /// Which `svg2pdf` palette the schematic pages resolve to. `.screen`
    /// (default) reproduces the dark web viewer — page background included —
    /// and `.print` is the light palette for paper.
    theme: svg2pdf.Theme = .screen,
    /// Human-visible generation stamp on the cover. Null falls back to
    /// `ReviewDoc.generated_at` (which is a wall-clock read, so tests pass a
    /// fixed string here).
    generated_at: ?[]const u8 = null,
    /// Short build stamp (the netlisp git hash) printed on the cover and in
    /// every page footer, so a saved PDF self-identifies its build.
    build_id: []const u8 = "",
    /// PDF `/CreationDate`. Null (the default) omits it, keeping the file
    /// byte-reproducible.
    timestamp: ?[]const u8 = null,
    /// Open entries in the design's `<design>.notes.md` sidecar. Passed in
    /// rather than read here: the composer touches no filesystem.
    open_notes: usize = 0,
};

/// Errors composing can produce: allocation and content-buffer failures from the
/// writer, plus every strict-mode rejection from the translator (renderer drift
/// outside the SVG subset, which must fail loudly rather than render wrong).
pub const Error = pdf.Error || svg2pdf.Error;

/// How many pages a finished document declares, counted off its page objects.
/// Matches on `/Parent` as well, so the `/Type /Pages` tree node is never
/// miscounted as a page. The CLI reports this; the tests assert on it.
pub fn pageCount(bytes: []const u8) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, at, "/Type /Page /Parent")) |i| : (at = i + 1) n += 1;
    return n;
}

// ── Page geometry (A4 landscape throughout, per the plan) ─────────────────

const page_w: f64 = pdf.a4_landscape_w;
const page_h: f64 = pdf.a4_landscape_h;
const margin: f64 = 36;
/// Usable content width — ~770 pt, which scales a 900 px hub SVG to ~0.86.
const usable_w: f64 = page_w - 2 * margin;
/// Top of the running-header text.
const header_top: f64 = 24;
/// Top of the first content row on a page that carries a running header.
const content_top: f64 = 62;
/// Bottom limit for content; below this is footer territory.
const content_bottom: f64 = page_h - 30;
const usable_h: f64 = content_bottom - content_top;
/// Top of the footer text row.
const footer_top: f64 = page_h - 20;
/// Vertical gap between two flowed schematic blocks.
const block_gap: f64 = 14;

const title_size: f64 = 26;
const h1_size: f64 = 14;
const h2_size: f64 = 11;
const body_size: f64 = 9;
const small_size: f64 = 7.5;
const body_leading: f64 = 12.5;
const row_leading: f64 = 11.5;

/// Page-furniture ink set — everything the composer draws itself (headers,
/// tables, footers, rules), as opposed to the schematic ink svg2pdf resolves.
/// One set per theme, so a dark page carries light furniture and vice versa.
const Furniture = struct {
    /// Painted over the whole page before any content; null leaves PDF white.
    bg: ?pdf.Rgb,
    ink: pdf.Rgb,
    muted: pdf.Rgb,
    rule: pdf.Rgb,
};
/// Light print furniture: black ink on the reader's white page.
const print_furniture: Furniture = .{
    .bg = null,
    .ink = .{ .r = 0, .g = 0, .b = 0 },
    .muted = .{ .r = 0.40, .g = 0.40, .b = 0.42 },
    .rule = .{ .r = 0.72, .g = 0.72, .b = 0.74 },
};
/// Dark screen furniture: the web viewer's #0d1117 page with its light inks.
const screen_furniture: Furniture = .{
    .bg = .{ .r = 0.051, .g = 0.067, .b = 0.090 },
    .ink = .{ .r = 0.788, .g = 0.820, .b = 0.851 },
    .muted = .{ .r = 0.545, .g = 0.580, .b = 0.620 },
    .rule = .{ .r = 0.188, .g = 0.212, .b = 0.239 },
};

/// Text truncated by `fit` gets this ASCII marker rather than an ellipsis
/// glyph, so a column overflow can never introduce a non-WinAnsi codepoint.
const cut_marker = "..";

// ── Entry point ──────────────────────────────────────────────────────────

/// Compose the whole review PDF and return its bytes, owned by the caller.
///
/// `block` and `doc` are the same pair `review_md.renderToMarkdown` consumes —
/// `doc` from `review.buildReview`, so the PDF and the markdown report always
/// agree. `project_dir` is only handed to the render context (library lookups
/// for pinouts and symbols); nothing here writes to it.
pub fn compose(
    gpa: Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    design_name: []const u8,
    doc: review.ReviewDoc,
    opts: Options,
) Error![]u8 {
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();

    var ctx = try render_html.setupRenderCtx(gpa, block);
    ctx.project_dir = project_dir;

    var c: Composer = .{
        .gpa = gpa,
        .scratch = scratch.allocator(),
        .out = pdf.Doc.init(gpa, .{ .title = design_name, .timestamp = opts.timestamp }),
        .opts = opts,
        .fur = if (opts.theme == .screen) screen_furniture else print_furniture,
        .design_name = design_name,
        .pages = .empty,
        .y = content_top,
    };
    defer c.deinit();

    try coverPage(&c, block, doc);
    try schematicPages(&c, &ctx, block);
    try appendixPages(&c, block, doc);
    try c.footers();

    return c.out.finish();
}

// ── Composer ─────────────────────────────────────────────────────────────

/// Page-flow state: the document being written, the page currently accepting
/// content, and the y-down cursor marking the TOP of the next content row.
const Composer = struct {
    gpa: Allocator,
    /// Short-lived formatting buffers (truncated cells, `allocPrint` rows).
    /// Backed by an arena `compose` drops on return.
    scratch: Allocator,
    out: pdf.Doc,
    opts: Options,
    fur: Furniture,
    design_name: []const u8,
    pages: std.ArrayList(*pdf.Page),
    y: f64,
    /// Running header redrawn at the top of each page. Empty on the cover.
    header: []const u8 = "",
    /// Second header line (a section's subtitle). Empty when there is none.
    sub: []const u8 = "",

    fn deinit(c: *Composer) void {
        c.pages.deinit(c.gpa);
        c.out.deinit();
    }

    /// The page currently accepting content — always the most recently begun
    /// one, so no placeholder handle is ever stored.
    fn cur(c: *Composer) *pdf.Page {
        return c.pages.items[c.pages.items.len - 1];
    }

    /// Start a fresh page, reset the cursor, paint the theme's page
    /// background, and draw the running header.
    fn beginPage(c: *Composer) Error!void {
        const p = try c.out.beginPage(page_w, page_h);
        try c.pages.append(c.gpa, p);
        c.y = content_top;
        if (c.fur.bg) |bg| {
            try p.rect(.{ .x = 0, .y = 0, .w = page_w, .h = page_h }, .{ .fill = bg });
        }
        try c.drawHeader();
    }

    /// Hairline rule stroke in this theme's rule ink.
    fn hairline(c: *const Composer) pdf.Stroke {
        return .{ .color = c.fur.rule, .width = 0.5 };
    }

    /// Draw the running header (title, optional subtitle, and the rule beneath)
    /// on the current page. A headerless page — the cover — gets nothing.
    fn drawHeader(c: *Composer) Error!void {
        if (c.header.len == 0) return;
        try c.put(margin, header_top, c.header, .{ .font = .helvetica_bold, .size = h1_size });
        if (c.sub.len > 0) {
            const st: pdf.TextStyle = .{ .size = body_size, .color = c.fur.muted };
            try c.put(margin, header_top + h1_size + 3, try c.fit(c.sub, st, usable_w), st);
        }
        try c.cur().line(
            .{ .x = margin, .y = content_top - 10 },
            .{ .x = page_w - margin, .y = content_top - 10 },
            c.hairline(),
        );
    }

    /// Move to a new page unless `h` points still fit below the cursor.
    fn ensure(c: *Composer, h: f64) Error!void {
        if (c.y + h <= content_bottom) return;
        try c.beginPage();
    }

    /// Draw `s` with its text block's TOP edge at `y_top`, converting to the
    /// baseline the writer wants. Keeps every caller in top-edge coordinates.
    /// A style left at the default black is re-inked for the theme, so every
    /// furniture caller follows the palette without naming a colour.
    fn put(c: *Composer, x: f64, y_top: f64, s: []const u8, st: pdf.TextStyle) Error!void {
        var style = st;
        const default_black = style.color.r == 0 and style.color.g == 0 and style.color.b == 0;
        if (default_black) style.color = c.fur.ink;
        try c.cur().text(.{ .x = x, .y = y_top + style.size * 0.78 }, s, style);
    }

    /// Emit one full-width line of body text and advance the cursor.
    fn line(c: *Composer, s: []const u8, st: pdf.TextStyle, leading: f64) Error!void {
        try c.ensure(leading);
        try c.put(margin, c.y, try c.fit(s, st, usable_w), st);
        c.y += leading;
    }

    /// `s` shortened until it fits `max_w` when set in `st`. Returns `s` itself
    /// when it already fits; otherwise a `cut_marker`-suffixed copy from the
    /// scratch arena. Never splits a UTF-8 sequence.
    fn fit(c: *Composer, s: []const u8, st: pdf.TextStyle, max_w: f64) Error![]const u8 {
        if (pdf.textWidth(st.font, st.size, s) <= max_w) return s;
        const marker_w = pdf.textWidth(st.font, st.size, cut_marker);
        var n = s.len;
        while (n > 0) {
            n -= 1;
            while (n > 0 and s[n] & 0xC0 == 0x80) n -= 1;
            if (pdf.textWidth(st.font, st.size, s[0..n]) + marker_w <= max_w) break;
        }
        return std.fmt.allocPrint(c.scratch, "{s}" ++ cut_marker, .{s[0..n]});
    }

    /// A section heading inside a flowing text page.
    fn heading(c: *Composer, s: []const u8) Error!void {
        try c.ensure(h2_size + 10);
        c.y += 4;
        try c.put(margin, c.y, s, .{ .font = .helvetica_bold, .size = h2_size });
        c.y += h2_size + 5;
    }

    /// Footer band on every page except the cover: design name, page N of M,
    /// and the build stamp. Written last, once the page count is known.
    fn footers(c: *Composer) Error!void {
        const total = c.pages.items.len;
        for (c.pages.items[@min(1, total)..], 0..) |p, i| {
            const st: pdf.TextStyle = .{ .size = small_size, .color = c.fur.muted };
            const s = try std.fmt.allocPrint(c.scratch, "{s} " ++ mid ++ " page {d}/{d}", .{
                c.design_name, i + 2, total,
            });
            try p.text(.{ .x = margin, .y = footer_top + st.size * 0.78 }, s, st);
            if (c.opts.build_id.len == 0) continue;
            const b = try std.fmt.allocPrint(c.scratch, "build {s}", .{c.opts.build_id});
            try p.text(
                .{ .x = page_w - margin, .y = footer_top + st.size * 0.78 },
                b,
                .{ .size = small_size, .color = c.fur.muted, .anchor = .end },
            );
        }
    }
};

/// WinAnsi-safe separator (U+00B7 MIDDLE DOT encodes to a single byte).
const mid = "\u{00B7}";

// ── Cover page ───────────────────────────────────────────────────────────

/// Title, revision, generation stamp, and the status roll-up — the same
/// verdict-first block `review_md.writeSummary` opens the markdown with.
fn coverPage(c: *Composer, block: *const DesignBlock, doc: review.ReviewDoc) Error!void {
    c.header = "";
    c.sub = "";
    try c.beginPage();
    c.y = 150;

    const title = if (block.name.len > 0) block.name else c.design_name;
    try c.put(margin, c.y, try c.fit(title, .{ .font = .helvetica_bold, .size = title_size }, usable_w), .{
        .font = .helvetica_bold,
        .size = title_size,
    });
    c.y += title_size + 8;
    try c.put(margin, c.y, c.design_name, .{ .size = h2_size, .color = c.fur.muted });
    c.y += h2_size + 14;
    try c.cur().line(.{ .x = margin, .y = c.y }, .{ .x = page_w - margin, .y = c.y }, c.hairline());
    c.y += 16;

    try coverStamp(c, doc);
    try coverRevision(c, doc.revision);
    try coverStatus(c, doc.summary, c.opts.open_notes);
}

/// "Generated <stamp> · build <hash>" — both injected, never read from a clock.
fn coverStamp(c: *Composer, doc: review.ReviewDoc) Error!void {
    const stamp = c.opts.generated_at orelse doc.generated_at;
    const build_id = if (c.opts.build_id.len > 0) c.opts.build_id else "unknown";
    const s = try std.fmt.allocPrint(c.scratch, "Generated {s} " ++ mid ++ " build {s}", .{ stamp, build_id });
    try c.line(s, .{ .size = body_size, .color = c.fur.muted }, body_leading + 6);
}

/// The declared `(revision …)` block. Unversioned designs get nothing at all,
/// matching the markdown report.
fn coverRevision(c: *Composer, rev: env_mod.Revision) Error!void {
    if (!rev.present) return;
    const head = if (rev.date.len > 0)
        try std.fmt.allocPrint(c.scratch, "Revision {s} " ++ mid ++ " {s}", .{ rev.id, rev.date })
    else
        try std.fmt.allocPrint(c.scratch, "Revision {s}", .{rev.id});
    try c.line(head, .{ .font = .helvetica_bold, .size = h2_size }, body_leading + 3);
    for (rev.changes) |ch| {
        const s = try std.fmt.allocPrint(c.scratch, "  {s} - {s}", .{ ch.id, ch.summary });
        try c.line(s, .{ .size = body_size }, body_leading);
    }
    c.y += 8;
}

/// The status roll-up: overall verdict plus the ERC / assertion / coverage /
/// open-note counts a reviewer reads before opening a single schematic.
fn coverStatus(c: *Composer, s: review.Summary, open_notes: usize) Error!void {
    try c.heading("Status");
    const verdict: []const u8 = switch (s.status) {
        .pass => "PASS",
        .warn => "WARN",
        .fail => "FAIL",
    };
    const oc = s.overall_coverage;
    try c.line(try std.fmt.allocPrint(c.scratch, "Status: {s}", .{verdict}), .{
        .font = .helvetica_bold,
        .size = h2_size,
    }, body_leading + 3);
    const rows = [_][]const u8{
        try std.fmt.allocPrint(c.scratch, "Sections: {d}   Instances: {d}   Nets: {d}", .{
            s.section_count, s.instance_count, s.net_count,
        }),
        try std.fmt.allocPrint(c.scratch, "ERC: {d} error(s), {d} warning(s), {d} info", .{
            s.violation_error, s.violation_warning, s.violation_info,
        }),
        try std.fmt.allocPrint(c.scratch, "Assertions: {d} pass, {d} warn, {d} fail", .{
            s.assertion_pass, s.assertion_warn, s.assertion_fail,
        }),
        try std.fmt.allocPrint(c.scratch, "Coverage: {d}% complete ({d}/{d} components filled in, {d} missing)", .{
            oc.percent, oc.complete, oc.checked, oc.missing_total,
        }),
        try std.fmt.allocPrint(c.scratch, "Open design notes: {d}", .{open_notes}),
    };
    for (rows) |r| try c.line(r, .{ .size = body_size }, body_leading);
}

// ── Schematic pages ──────────────────────────────────────────────────────

/// One schematic entry — a `(section …)` or a distinct sub-block module — with
/// its drawable blocks already collected. Collection is a single pass in
/// declaration order because it MUTATES `ctx.rendered_spokes` (a spoke draws
/// once, on the first hub that reaches it), so a throwaway look-ahead pass would
/// poison the real render. Holding the collected documents instead is what lets
/// the composer see what follows a sheet before it decides how much of that sheet
/// to hold back.
const Entry = struct {
    /// Sheet header (or flowed bold heading) and its subtitle row.
    name: []const u8,
    sub: []const u8,
    /// The section this entry came from — its status line and notes. Null for a
    /// sub-block module entry, which has neither.
    sec: ?Section,
    /// Drawable blocks; empty means a COMPACT entry (no schematic to draw).
    docs: []const svg2pdf.Document,
    /// The modules whose circuits this entry draws — a section's attached
    /// sub-blocks, or the one module an appendix entry is about. Their own
    /// `(note …)` entries render here, under the grid, because this is where
    /// their circuit is.
    mods: []const env_mod.SubBlock = &.{},
    /// Prose rows flowing under the schematic, resolved by `finishEntries`.
    prose: []const Prose = &.{},
};

/// Which modules a section owns, and the shared claim flags the appendix reads.
/// Bundled rather than passed loose because a sub-section never adopts a module,
/// so the whole thing is optional at the call site.
const Claim = struct {
    /// Indices into `subs` of the modules attached to this section — resolved by
    /// `membership.attachedSubBlocks`, the authority the schematic page uses.
    attached: []const usize,
    /// The design's top-level sub-blocks.
    subs: []const env_mod.SubBlock,
    /// Set when a section actually DREW a module, which is what makes the
    /// appendix skip it. Shared across every section in one pass.
    drawn: []bool,
};

/// Every section, then every sub-block module no section drew: collected first,
/// laid out second. `docs` is arena-backed for the whole pass, so an entry can be
/// measured long before it is drawn.
///
/// A section's attached modules are collected INTO the section's entry, so name,
/// subtitle, status, the module's schematic and the section's notes end up on one
/// self-contained sheet — the section's prose describing the circuit next to it
/// rather than several pages away.
fn schematicPages(c: *Composer, ctx: *RenderCtx, block: *const DesignBlock) Error!void {
    var arena = std.heap.ArenaAllocator.init(c.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const attachments = try membership.computeSubBlockAttachments(a, block);
    const drawn = try a.alloc(bool, block.sub_blocks.len);
    @memset(drawn, false);

    var entries: std.ArrayList(Entry) = .empty;
    for (block.sections, 0..) |sec, sec_idx| {
        const attached = try membership.attachedSubBlocks(a, block, attachments, sec_idx);
        try collectSection(c, ctx, a, &entries, sec, .{
            .attached = attached,
            .subs = block.sub_blocks,
            .drawn = drawn,
        });
        // Sub-sections are detail inside a section, never a module's host: the
        // attachment map keys on top-level sections only.
        for (sec.sub_sections) |sub| try collectSection(c, ctx, a, &entries, sub, null);
    }
    try collectSubBlocks(c, ctx, a, &entries, block, drawn);
    try finishEntries(a, entries.items, block.notes);

    for (entries.items, 0..) |e, i| try composeEntry(c, a, e, entries.items[i + 1 ..]);
}

/// Whether `sec` declares `ref` — as an inline instance or a `(pins …)` group.
/// This is the ownership test for a ref-anchored note: the section's own
/// declarations, never a module's internal ref-des (those live in the module's
/// namespace and are addressed by the module's own notes).
fn sectionDeclares(sec: Section, ref: []const u8) bool {
    for (sec.instances) |inst| if (std.mem.eql(u8, inst.ref_des, ref)) return true;
    for (sec.pin_groups) |pg| if (std.mem.eql(u8, pg.ref_des, ref)) return true;
    for (sec.sub_sections) |ss| if (sectionDeclares(ss, ref)) return true;
    return false;
}

/// Collect one section's hub schematics the way the markdown report collects
/// them — `(pins …)`-attached parts first, then inline instances —
/// deduplicated by ref-des, with passives skipped (they draw as spokes on the
/// hubs they wire into). An empty result is what makes the entry compact: a
/// section whose hardware is sealed in sub-blocks, or one that is pure notes,
/// flows inline instead of spending a page on a header and a status line.
fn collectSection(
    c: *Composer,
    ctx: *RenderCtx,
    a: Allocator,
    out: *std.ArrayList(Entry),
    sec: Section,
    claim: ?Claim,
) Error!void {
    var docs: std.ArrayList(svg2pdf.Document) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(c.gpa);
    for (sec.pin_groups) |pg| {
        if ((try seen.fetchPut(c.gpa, pg.ref_des, {})) != null) continue;
        try collectHubDocs(c, ctx, a, &docs, sec.pin_groups, pg.ref_des);
    }
    for (sec.instances) |inst| {
        if ((try seen.fetchPut(c.gpa, inst.ref_des, {})) != null) continue;
        try collectHubDocs(c, ctx, a, &docs, sec.pin_groups, inst.ref_des);
    }
    const mods = try claimModules(c, ctx, a, &docs, claim);
    try out.append(a, .{
        .name = sec.name,
        .sub = sec.description,
        .sec = sec,
        .docs = docs.items,
        .mods = mods,
    });
}

/// Draw this section's attached modules onto the section's own sheet: collect
/// each one's hub schematics into the section's block list and record it as
/// drawn, so the appendix no longer repeats it.
///
/// Only a SINGLE-instance module is adopted. A module instantiated more than once
/// (render-identical repeats, per `render_html.sameSubBlockShape`) stays in the
/// appendix with its `x N` caption — drawing it into each of N sections would
/// duplicate one circuit N times, which is exactly what that collapse exists to
/// prevent. A module that draws nothing (a passive network) is likewise left
/// alone, so it keeps its own inline appendix entry instead of vanishing.
fn claimModules(
    c: *Composer,
    ctx: *RenderCtx,
    a: Allocator,
    docs: *std.ArrayList(svg2pdf.Document),
    claim: ?Claim,
) Error![]const env_mod.SubBlock {
    const cl = claim orelse return &.{};
    var mods: std.ArrayList(env_mod.SubBlock) = .empty;
    for (cl.attached) |si| {
        if (copiesOf(cl.subs, si) > 1) continue;
        const sb = cl.subs[si];
        const before = docs.items.len;
        for (sb.block.instances) |inst| try collectHubDocs(c, ctx, a, docs, &.{}, inst.ref_des);
        if (docs.items.len == before) continue;
        try labelModuleDocs(c, docs.items[before..], sb);
        cl.drawn[si] = true;
        try mods.append(a, sb);
    }
    return mods.items;
}

/// Caption an adopted module's cells so a reader can tell whose circuit they are.
/// A block the renderer already labelled (`<h4 class="hub-group-label">`, one per
/// pin group of a multi-group hub) keeps that label; an unlabelled one takes the
/// sub-block's instance name plus the module's title, e.g. `bss1 - BSS138 BPSK
/// Gate`.
fn labelModuleDocs(c: *Composer, docs: []svg2pdf.Document, sb: env_mod.SubBlock) Error!void {
    const title = if (sb.block.name.len > 0)
        try std.fmt.allocPrint(c.scratch, "{s} - {s}", .{ sb.name, sb.block.name })
    else
        sb.name;
    for (docs) |*d| {
        if (d.title.len == 0) d.title = title;
    }
}

/// Lay one entry out: its own sheet when it has blocks to draw, flowed inline
/// when it does not. `rest` is everything still to come, which is what sizes the
/// sheet's tail reserve.
fn composeEntry(c: *Composer, a: Allocator, e: Entry, rest: []const Entry) Error!void {
    if (e.docs.len == 0) return compactEntry(c, e);
    c.header = e.name;
    c.sub = e.sub;
    try c.beginPage();
    if (e.sec) |sec| try sectionStatus(c, sec);
    try blocksOnSheet(c, a, e.docs, tailReserve(proseHeight(e), tailLookahead(rest)));
    try entryProse(c, e);
}

/// The inline form of a schematic-less entry: name, subtitle, and (for a
/// section) its status and notes, packed onto the page the flow is already on.
fn compactEntry(c: *Composer, e: Entry) Error!void {
    try flowHeading(c, e.name, e.sub);
    if (e.sec) |sec| try sectionStatus(c, sec);
    try entryProse(c, e);
    c.y += block_gap;
}

/// Everything that flows UNDER an entry's schematic, drawn from the row list
/// `buildProse` already resolved: each row's heading appears once, when it
/// changes. Measuring and drawing walk the SAME list, so the reserve the grid
/// held back above can never disagree with what lands below it.
fn entryProse(c: *Composer, e: Entry) Error!void {
    var head: []const u8 = "";
    for (e.prose) |p| {
        if (!std.mem.eql(u8, p.head, head)) {
            try c.heading(p.head);
            head = p.head;
        }
        try c.line(p.text, .{ .size = body_size }, body_leading);
    }
}

/// Measured height of everything `entryProse` will draw, so the grid above it can
/// hold back exactly that much of the sheet.
fn proseHeight(e: Entry) f64 {
    var h: f64 = 0;
    var head: []const u8 = "";
    for (e.prose) |p| {
        if (!std.mem.eql(u8, p.head, head)) {
            h += h2_size + 9;
            head = p.head;
        }
        h += body_leading;
    }
    return h;
}

/// The muted "Section status: implemented" line under a section's header.
fn sectionStatus(c: *Composer, sec: Section) Error!void {
    try c.line(
        try std.fmt.allocPrint(c.scratch, "Section status: {s}", .{@tagName(sec.status)}),
        .{ .size = small_size, .color = c.fur.muted },
        body_leading,
    );
}

/// Every block of one section or module: the grid first, and the sequential
/// shrink-then-slice flow only when the grid cannot pack them at any legible
/// scale. `reserve_h` is the band the grid must leave clear under itself.
///
/// The reserve is a courtesy to the prose below, never a reason to give up the
/// grid: it is first trimmed to what the sheet can actually spare
/// (`grantableReserve`). Without that trim a lone tall hub on a note-bearing sheet
/// failed the reserved pack, fell to the sequential flow, and that flow's first
/// `ensure` opened a fresh page — leaving the sheet holding nothing but its header.
fn blocksOnSheet(
    c: *Composer,
    a: Allocator,
    docs: []const svg2pdf.Document,
    reserve_h: f64,
) Error!void {
    const granted = grantableReserve(docs, content_bottom - c.y, reserve_h);
    if (try gridBlocks(c, a, docs, granted)) return;
    for (docs) |d| try placeDoc(c, a, d);
}

/// Bold flowed heading opening a COMPACT entry — a section or module with no
/// drawable schematic — on the CURRENT page, never a page of its own. The
/// running header is cleared so an overflow continuation stays headerless, and
/// the cover never hosts entries (the first one after the cover starts page 2).
/// A sheet-owning section sets `c.header` and calls `beginPage` instead; this is
/// only the no-schematic path.
fn flowHeading(c: *Composer, name: []const u8, subtitle: []const u8) Error!void {
    c.header = "";
    c.sub = "";
    if (c.pages.items.len <= 1) try c.beginPage();
    try c.ensure(h1_size + body_leading * 3);
    c.y += 4;
    try c.put(margin, c.y, name, .{ .font = .helvetica_bold, .size = h1_size });
    c.y += h1_size + 4;
    if (subtitle.len > 0) {
        try c.line(subtitle, .{ .size = body_size, .color = c.fur.muted }, body_leading);
    }
}

/// Fraction of the usable page height the grid may leave for everything that flows
/// BELOW it. Two thirds, because on a unified sheet the prose IS the deliverable —
/// a section's notes and its adopted module's notes describe the drawing right
/// above them, and a sheet that spills its last note onto a page of its own is the
/// disassociation unified sheets exist to end. The drawing is protected from the
/// other side instead: `grantableReserve` never hands out more than the sheet can
/// spare above the grid's floor-scale footprint. Prose past the reserve continues
/// on a headered next page, which stays the acceptable overflow.
const tail_reserve_frac: f64 = 0.65;

/// How many following compact entries a sheet will hold back space for. Two,
/// because a design routinely declares stub sections in pairs (two rails whose
/// hardware is sealed in sub-blocks, back to back) and budgeting for exactly one
/// spilled the second onto a page holding nothing else. Past two the grid would
/// give up more of the sheet than the stubs are worth; the overflow continues on
/// a headered next page, which is the acceptable failure.
const tail_lookahead: usize = 2;

/// The `ensure` floor `flowHeading` demands before it will open a compact entry
/// on the page the flow is already on. Reserve less than this and the entry
/// claims a page of its own no matter how much of it would have fitted.
const flow_open_h: f64 = h1_size + body_leading * 3;

/// The height a COMPACT entry consumes once opened: its bold name, its subtitle
/// row when it has one, a section's status row and measured notes, and the gap it
/// leaves behind. Measured per entry rather than assumed, so a sheet holds back
/// what its followers will actually draw.
fn compactHeight(e: Entry) f64 {
    var h: f64 = (4 + h1_size + 4) + block_gap;
    if (e.sub.len > 0) h += body_leading;
    if (e.sec != null) h += body_leading;
    return h + proseHeight(e);
}

/// Space to hold back for the compact entries immediately following a sheet: each
/// one's measured height, never below the `ensure` floor that decides whether it
/// opens here at all. ZERO when the next entry claims a sheet of its own —
/// reserving for a follower that will never flow onto this page only shrinks the
/// drawing.
fn tailLookahead(rest: []const Entry) f64 {
    var h: f64 = 0;
    for (rest[0..@min(rest.len, tail_lookahead)]) |e| {
        if (e.docs.len > 0) break;
        h += @max(compactHeight(e), flow_open_h);
    }
    return h;
}

/// Height to hold back from a sheet's grid: `below_h` (the sheet's own following
/// content — its measured prose) plus `tail_h` (the compact entries that actually
/// follow), capped at `tail_reserve_frac` of the usable page.
///
/// A non-empty reserve also covers the `block_gap` the grid leaves behind itself
/// plus a point of float slack: without that gap the prose starts one gap lower
/// than the reserve assumed, and its last row spilled onto a page of its own.
fn tailReserve(below_h: f64, tail_h: f64) f64 {
    const want = below_h + tail_h;
    if (want <= 0) return 0;
    return @min(want + block_gap + 1, usable_h * tail_reserve_frac);
}

// ── Sheet prose (notes) ──────────────────────────────────────────────────

/// Heading a section's own `(note …)` entries file under.
const notes_head = "Notes";
/// Heading the notes of the modules drawn on this sheet file under.
const module_notes_head = "Module notes";
/// Heading ref-anchored `(note "REF" …)` entries file under.
const design_notes_head = "Design notes";

/// One resolved prose row under a sheet's schematic: the heading it belongs to
/// plus its finished bullet text (owner prefix and datasheet citation included).
/// Resolving the rows once, at collection time, is what keeps `proseHeight` and
/// `entryProse` in agreement — a measurement that walks different logic than the
/// renderer is how a sheet's last note ends up alone on a page of its own.
const Prose = struct {
    head: []const u8,
    text: []const u8,
};

/// Build every entry's prose rows and file the ref-anchored design notes, now
/// that the whole entry list exists. Runs after collection because a ref-anchored
/// note's home is decided across entries, not within one.
fn finishEntries(a: Allocator, entries: []Entry, notes: []const env_mod.Note) Allocator.Error!void {
    const filed = try fileRefNotes(a, entries, notes);
    for (entries, 0..) |*e, i| try buildProse(a, e, filed[i].items);
}

/// File each ref-anchored `(note "REF" …)` under the FIRST entry whose section
/// declares that ref — or, failing that, whose DRAWN modules hold an instance
/// with that ref-des — so it draws on the sheet holding its part. A note whose
/// ref matches neither (including `slug/ref` flattened spellings, which stay
/// out of scope deliberately) stays unfiled and surfaces in the appendix
/// instead (`orphanNotes` mirrors this predicate), so none is silently dropped.
fn fileRefNotes(
    a: Allocator,
    entries: []const Entry,
    notes: []const env_mod.Note,
) Allocator.Error![]std.ArrayList(env_mod.Note) {
    const filed = try a.alloc(std.ArrayList(env_mod.Note), entries.len);
    for (filed) |*l| l.* = .empty;
    for (notes) |n| {
        for (entries, 0..) |e, i| {
            const declared = if (e.sec) |sec| sectionDeclares(sec, n.ref_des) else false;
            if (!declared and !moduleDrawsRef(e, n.ref_des)) continue;
            try filed[i].append(a, n);
            break;
        }
    }
    return filed;
}

/// Whether one of the modules DRAWN on this entry's sheet holds an instance
/// with `ref` as its module-local ref-des. Lets a `(note "U2" …)` about a part
/// inside a drawn module land next to that module's schematic instead of in
/// the appendix. Flattened `slug/ref` spellings are deliberately not matched —
/// a ×N module's later copies have no single home sheet to name.
fn moduleDrawsRef(e: Entry, ref: []const u8) bool {
    for (e.mods) |sb| {
        for (sb.block.instances) |inst| {
            if (std.mem.eql(u8, inst.ref_des, ref)) return true;
        }
    }
    return false;
}

/// One entry's prose: its section's own notes, then the notes carried by the
/// modules drawn here, then the ref-anchored design notes whose parts it holds.
///
/// A module note repeating a SECTION note's visible text is dropped. Boards
/// routinely copy a module's rationale into the section that wraps it (every
/// cyclops-kband RF section does), and before unified sheets the two lived pages
/// apart so the duplication was invisible; on one sheet it would read twice.
/// Two scoping rules, both review findings: the comparison is against the
/// section's own notes ONLY (module rows never join the seen-set — a sibling
/// module's identical rationale is that module's own fact, not a repeat), and
/// it matches on the VISIBLE prefix, because boards paraphrase late in the
/// string while `fit` truncates the printed row — two notes identical for the
/// whole printable length read as the same paragraph regardless of a word
/// changed at char 233.
fn buildProse(a: Allocator, e: *Entry, refs: []const env_mod.Note) Allocator.Error!void {
    var rows: std.ArrayList(Prose) = .empty;
    var sec_texts: std.ArrayList([]const u8) = .empty;
    if (e.sec) |sec| {
        for (sec.notes) |n| {
            try sec_texts.append(a, n.text);
            try rows.append(a, .{ .head = notes_head, .text = try noteText(a, "", n.text, n.ref) });
        }
    }
    for (e.mods) |sb| try moduleProse(a, &rows, sec_texts.items, sb);
    for (refs) |n| {
        try rows.append(a, .{ .head = design_notes_head, .text = try noteText(a, n.ref_des, n.text, null) });
    }
    e.prose = rows.items;
}

/// Bytes two notes must share before print stops distinguishing them: a prose
/// row truncates at roughly this many characters (`fit` at body size across the
/// sheet), so agreement this deep reads as the same paragraph to a reviewer.
const note_dedup_prefix: usize = 160;

/// Test filler longer than any printable prose row (Zig master has no `**`).
const note_dedup_pad: [note_dedup_prefix + 40]u8 = @splat('p');

/// Whether two note texts are the same note TO A READER: exactly equal, or —
/// when both outrun the printable row — identical for the entire visible prefix.
fn sameVisibleNote(a_text: []const u8, b_text: []const u8) bool {
    if (std.mem.eql(u8, a_text, b_text)) return true;
    if (a_text.len < note_dedup_prefix or b_text.len < note_dedup_prefix) return false;
    return std.mem.eql(u8, a_text[0..note_dedup_prefix], b_text[0..note_dedup_prefix]);
}

/// The `(note …)` entries one drawn module contributes — its sections' notes and
/// its ref-anchored ones. Before unified sheets these rendered NOWHERE in the PDF:
/// a module's design rationale lived only in its `.sexp`. Each row names its owning
/// sub-block, so a sheet holding several modules stays unambiguous.
fn moduleProse(
    a: Allocator,
    rows: *std.ArrayList(Prose),
    sec_texts: []const []const u8,
    sb: env_mod.SubBlock,
) Allocator.Error!void {
    for (sb.block.sections) |sec| try moduleSectionProse(a, rows, sec_texts, sb.name, sec);
    for (sb.block.notes) |n| {
        const owner = try std.fmt.allocPrint(a, "{s}/{s}", .{ sb.name, n.ref_des });
        try moduleRow(a, rows, sec_texts, owner, n.text, null);
    }
}

/// One module section's notes (and its sub-sections'), owned by `name`.
fn moduleSectionProse(
    a: Allocator,
    rows: *std.ArrayList(Prose),
    sec_texts: []const []const u8,
    name: []const u8,
    sec: Section,
) Allocator.Error!void {
    for (sec.notes) |n| try moduleRow(a, rows, sec_texts, name, n.text, n.ref);
    for (sec.sub_sections) |ss| try moduleSectionProse(a, rows, sec_texts, name, ss);
}

/// Append one module note row unless the SECTION's own notes already state its
/// visible text (see `sameVisibleNote`; module rows never suppress each other).
fn moduleRow(
    a: Allocator,
    rows: *std.ArrayList(Prose),
    sec_texts: []const []const u8,
    owner: []const u8,
    text: []const u8,
    ref: ?env_mod.NoteRef,
) Allocator.Error!void {
    for (sec_texts) |t| {
        if (sameVisibleNote(t, text)) return;
    }
    try rows.append(a, .{ .head = module_notes_head, .text = try noteText(a, owner, text, ref) });
}

/// One row's finished text: `- text`, or `- owner: text` when the note belongs to
/// a module or a named part rather than to the sheet's own section, plus the
/// datasheet citation when the note carries one.
fn noteText(
    a: Allocator,
    owner: []const u8,
    text: []const u8,
    ref: ?env_mod.NoteRef,
) Allocator.Error![]const u8 {
    const body = if (owner.len > 0)
        try std.fmt.allocPrint(a, "- {s}: {s}", .{ owner, text })
    else
        try std.fmt.allocPrint(a, "- {s}", .{text});
    if (ref) |r| return std.fmt.allocPrint(a, "{s} ({s} p.{d})", .{ body, r.pdf, r.page });
    return body;
}

/// One appendix entry per DISTINCT sub-block no section drew. Render-identical
/// repeats of one module (a folded channel instantiated chN times) draw once,
/// captioned with the count — the same collapse the schematic page applies, off
/// the same predicate (`render_html.sameSubBlockShape`), so the two surfaces never
/// disagree about what counts as a repeat. A module with no hub (a passive
/// network) collects no documents and so becomes a compact entry, never a blank
/// page.
///
/// `drawn` is what unified sheets leave behind: a module already drawn on its
/// section's sheet is skipped here, so the appendix keeps exactly what no section
/// claimed — the unattached modules and the multi-instance ones.
fn collectSubBlocks(
    c: *Composer,
    ctx: *RenderCtx,
    a: Allocator,
    out: *std.ArrayList(Entry),
    block: *const DesignBlock,
    drawn: []const bool,
) Error!void {
    for (block.sub_blocks, 0..) |sb, i| {
        if (drawn[i]) continue;
        if (drawnEarlier(block.sub_blocks[0..i], sb)) continue;
        var docs: std.ArrayList(svg2pdf.Document) = .empty;
        for (sb.block.instances) |inst| try collectHubDocs(c, ctx, a, &docs, &.{}, inst.ref_des);
        try out.append(a, .{
            .name = try std.fmt.allocPrint(c.scratch, "{s} (sub-block)", .{sb.name}),
            .sub = try subBlockCaption(c, sb.block.name, copiesOf(block.sub_blocks, i)),
            .sec = null,
            .docs = docs.items,
            .mods = try a.dupe(env_mod.SubBlock, &.{sb}),
        });
    }
}

/// Whether an earlier sub-block already rendered `sb`'s shape.
fn drawnEarlier(before: []const env_mod.SubBlock, sb: env_mod.SubBlock) bool {
    for (before) |p| {
        if (render_html.sameSubBlockShape(p, sb)) return true;
    }
    return false;
}

/// How many sub-blocks render identically to `all[at]`, counting itself. A
/// source-less sub-block never matches anything (not even itself), so it
/// always reports 1.
fn copiesOf(all: []const env_mod.SubBlock, at: usize) usize {
    var n: usize = 1;
    for (all, 0..) |o, i| {
        if (i == at) continue;
        if (render_html.sameSubBlockShape(all[at], o)) n += 1;
    }
    return n;
}

/// The sub-block page's subtitle: the module's own title, plus a repeat count
/// when the same module is instantiated more than once.
fn subBlockCaption(c: *Composer, name: []const u8, repeats: usize) Error![]const u8 {
    if (repeats <= 1) return name;
    return std.fmt.allocPrint(c.scratch, "{s} (sub-block x{d})", .{ name, repeats });
}

/// Render one hub's SVG(s) and append the translated, drawable documents to
/// `docs` (arena-owned — `a` must outlive the caller's placement pass).
/// Passives never produce a block of their own. A hub that renders nothing (no
/// pin groupings) is silently skipped, matching the markdown report; a *render*
/// failure degrades the same way, but a TRANSLATION failure propagates — that
/// is renderer drift outside the subset, and it must fail loudly.
fn collectHubDocs(
    c: *Composer,
    ctx: *RenderCtx,
    a: Allocator,
    docs: *std.ArrayList(svg2pdf.Document),
    pin_groups: []const env_mod.PinGroup,
    ref: []const u8,
) Error!void {
    if (!draw.isHubRef(ref)) return;
    var buf: std.Io.Writer.Allocating = .init(a);
    const rendered = render_html.renderHubSvg(ctx, &buf.writer, a, pin_groups, ref) catch false;
    if (!rendered) return;

    const translated = try svg2pdf.translateAll(a, buf.written(), .{ .theme = c.opts.theme }, null);
    for (translated) |d| {
        if (drawable(d)) try docs.append(a, d);
    }
}

// ── Sheet grid ───────────────────────────────────────────────────────────

/// Gap between two grid cells, horizontally and between shelves.
const grid_gap: f64 = 10;
/// Point size of a grid cell's group label — the `<h4 class="hub-group-label">`
/// heading `renderHubSvg` wrote above that block's `<svg>`.
const grid_label_size: f64 = 8;
/// Height a labelled cell reserves above its block for that label row.
const grid_label_h: f64 = grid_label_size + 3;
/// Scale floor for the grid packer. Well below `min_block_scale` on purpose:
/// cramming a whole subsystem small onto one readable-in-a-viewer sheet is the
/// point, and a section that cannot pack even here falls back to the sequential
/// flow rather than being drawn as a row of stamps.
const grid_min_scale: f64 = 0.10;
/// Bisection steps between a scale that packs and one that does not — 20 halvings
/// of the 0.1…1.0 interval resolve the scale to well under a thousandth.
const grid_bisect_steps: usize = 20;

/// One packed cell's box, relative to the grid's top-left corner.
const Cell = struct { x: f64, y: f64, w: f64, h: f64 };

/// Left-to-right, top-to-bottom shelf packer over a `usable_w`-wide strip:
/// `place` returns each cell's box and wraps to a fresh shelf when the cell
/// would overrun the strip. Declaration order is preserved, so a sheet reads in
/// the order the design declares its hubs.
const Shelf = struct {
    x: f64 = 0,
    y: f64 = 0,
    /// Tallest cell on the shelf currently being filled.
    row_h: f64 = 0,

    fn place(sh: *Shelf, w: f64, h: f64) Cell {
        if (sh.x > 0 and sh.x + w > usable_w) {
            sh.y += sh.row_h + grid_gap;
            sh.x = 0;
            sh.row_h = 0;
        }
        const at: Cell = .{ .x = sh.x, .y = sh.y, .w = w, .h = h };
        sh.x += w + grid_gap;
        sh.row_h = @max(sh.row_h, h);
        return at;
    }

    /// Total height consumed, the shelf in progress included.
    fn height(sh: Shelf) f64 {
        return sh.y + sh.row_h;
    }
};

/// A document's cell height at scale `s`: the scaled block plus the label row
/// when it carries a group label.
fn cellHeight(d: svg2pdf.Document, s: f64) f64 {
    const label_h: f64 = if (d.title.len > 0) grid_label_h else 0;
    return d.height * s + label_h;
}

/// Dry run of the pack: whether every document fits the strip at scale `s`
/// within `avail_h`. Monotone in `s` — shrinking a cell never pushes a later one
/// onto a new shelf — which is what makes the bisection in `gridScale` valid.
fn packsAt(docs: []const svg2pdf.Document, s: f64, avail_h: f64) bool {
    var sh: Shelf = .{};
    for (docs) |d| {
        const w = d.width * s;
        if (w > usable_w) return false;
        _ = sh.place(w, cellHeight(d, s));
    }
    return sh.height() <= avail_h;
}

/// Scale floor the packer may shrink to: a grid of several blocks may go all the
/// way to `grid_min_scale`, while a LONE document stops at `min_block_scale` —
/// it has nothing to pack against, so shrinking it past legibility buys no
/// density, and the sequential flow's shrink-then-slice ladder serves it better.
fn scaleFloor(docs: []const svg2pdf.Document) f64 {
    return if (docs.len > 1) grid_min_scale else min_block_scale;
}

/// Height the grid needs at its floor scale — the least it can ever occupy, and so
/// the boundary on what a sheet can hold back for the prose below.
fn floorHeight(docs: []const svg2pdf.Document) f64 {
    const s = scaleFloor(docs);
    var sh: Shelf = .{};
    for (docs) |d| _ = sh.place(d.width * s, cellHeight(d, s));
    return sh.height();
}

/// The part of a requested reserve the grid can actually spare: whatever is left of
/// `avail_h` once the grid's floor-scale footprint is accounted for. Trimming here
/// rather than failing the pack is what keeps a sheet whole — the drawing shrinks
/// to make room for its own notes instead of the notes taking a page of their own.
/// A grid that cannot fit even at zero reserve still fails, which is the sequential
/// fallback's cue.
fn grantableReserve(docs: []const svg2pdf.Document, avail_h: f64, want: f64) f64 {
    return @max(0, @min(want, avail_h - floorHeight(docs)));
}

/// The largest uniform scale the whole grid packs at, or null when even the
/// floor (`scaleFloor`) cannot fit it. Natural size is tried first (a small
/// section needs no shrink at all), then the interval between the floor and 1.0
/// is bisected.
fn gridScale(docs: []const svg2pdf.Document, avail_h: f64) ?f64 {
    if (packsAt(docs, 1.0, avail_h)) return 1.0;
    const floor = scaleFloor(docs);
    if (!packsAt(docs, floor, avail_h)) return null;
    var lo = floor;
    var hi: f64 = 1.0;
    for (0..grid_bisect_steps) |_| {
        const probe = (lo + hi) / 2;
        if (packsAt(docs, probe, avail_h)) lo = probe else hi = probe;
    }
    return lo;
}

/// Pack every document of one section or module onto the CURRENT page as a 2D
/// grid at one uniform scale, each cell captioned with its group label, and
/// advance the cursor past the grid. Returns false — leaving the page
/// untouched — when the grid cannot pack at any legible scale, so the caller
/// can fall back to the sequential flow.
fn gridBlocks(
    c: *Composer,
    a: Allocator,
    docs: []const svg2pdf.Document,
    reserve_h: f64,
) Error!bool {
    if (docs.len == 0) return true;
    const s = gridScale(docs, content_bottom - c.y - reserve_h) orelse return false;
    var sh: Shelf = .{};
    for (docs) |d| try gridCell(c, a, d, s, sh.place(d.width * s, cellHeight(d, s)));
    c.y += sh.height() + block_gap;
    return true;
}

/// One grid cell: the group label above (when the document carries one), then
/// the block clipped to its own box so a stray op can never bleed into a
/// neighbouring cell.
fn gridCell(c: *Composer, a: Allocator, d: svg2pdf.Document, s: f64, cell: Cell) Error!void {
    const x = margin + cell.x;
    var top = c.y + cell.y;
    if (d.title.len > 0) {
        const st: pdf.TextStyle = .{
            .font = .helvetica_bold,
            .size = grid_label_size,
            .color = c.fur.muted,
        };
        try c.put(x, top, try c.fit(d.title, st, cell.w), st);
        top += grid_label_h;
    }
    try drawDocAt(c, a, d, s, .{ .x = x, .y = top, .w = cell.w, .h = d.height * s }, 0);
}

// ── Sequential fallback flow ─────────────────────────────────────────────

/// Scale floor for shrink-to-fit: a tall document scales down until it fits
/// one page, but never below this — smaller and the pin labels stop being
/// readable, so the block slices across pages instead.
const min_block_scale: f64 = 0.35;
/// Height budget for a single shrunk-to-fit block: the usable page height
/// less the inter-block gap and a point of float slack, so a block scaled to
/// exactly this budget always passes `ensure` on a fresh page.
const block_fit_h: f64 = usable_h - block_gap - 1.0;

/// Flow one translated document as a single block, scaled to fit the page —
/// width always, height down to `min_block_scale` — so a tall hub shrinks
/// onto one page rather than splitting. It moves to a fresh page rather than
/// straddling a break; only a document still taller than a whole page at the
/// scale floor is sliced across pages.
fn placeDoc(c: *Composer, a: Allocator, d: svg2pdf.Document) Error!void {
    if (!drawable(d)) return;
    const w_fit = @min(1.0, usable_w / d.width);
    const h_fit = @min(1.0, block_fit_h / d.height);
    const s = @min(w_fit, @max(min_block_scale, h_fit));
    const full = d.height * s;
    if (full <= usable_h) {
        try c.ensure(full + block_gap);
        try drawSlice(c, a, d, s, 0, full);
        c.y += full + block_gap;
        return;
    }
    var off: f64 = 0;
    while (off < full) {
        if (c.y > content_top) try c.beginPage();
        const h = @min(usable_h, full - off);
        try drawSlice(c, a, d, s, off, h);
        off += h;
        c.y += h;
    }
    c.y += block_gap;
}

/// Whether a translated document is worth a block: it has ops, and a positive
/// extent to scale into. A degenerate viewBox would divide by zero otherwise.
fn drawable(d: svg2pdf.Document) bool {
    if (d.ops.len == 0) return false;
    if (!(d.width > 0)) return false;
    return d.height > 0;
}

/// Paint the horizontal band `[off, off+h)` of `d` (already scaled by `s`) into
/// the full content width with its top edge at the cursor — the flow's own
/// placement, and the grid's `box` generalised to one column.
fn drawSlice(c: *Composer, a: Allocator, d: svg2pdf.Document, s: f64, off: f64, h: f64) Error!void {
    try drawDocAt(c, a, d, s, .{ .x = margin, .y = c.y, .w = usable_w, .h = h }, off);
}

/// Paint `d` scaled by `s` into the page-space rectangle `box`, starting `off`
/// points down from the document's own top edge. `clipRect` runs in page space
/// *before* the translate, so the content is bounded by `box` no matter how far
/// the document extends — that is what makes both a page-tall slice and a small
/// grid cell safe to draw.
fn drawDocAt(
    c: *Composer,
    a: Allocator,
    d: svg2pdf.Document,
    s: f64,
    box: pdf.Rect,
    off: f64,
) Error!void {
    const p = c.cur();
    try p.save();
    try p.clipRect(box);
    try p.translate(box.x - d.min_x * s, box.y - d.min_y * s - off);
    for (d.ops) |op| try drawOp(p, a, op, s);
    try p.restore();
}

// ── DrawOp → pdf.Page mapping ────────────────────────────────────────────
//
// The two type sets are deliberately distinct (see the module header), so this
// is the whole bridge between them.

/// Scale a translator point into page space. The enclosing `translate` supplies
/// the offset, so this is pure scaling.
fn xf(p: svg2pdf.Pt, s: f64) pdf.Point {
    return .{ .x = p.x * s, .y = p.y * s };
}

/// 8-bit-per-channel colour to the writer's 0…1 floats.
fn toRgb(v: svg2pdf.Rgb) pdf.Rgb {
    return .{
        .r = @as(f64, @floatFromInt(v.r)) / 255.0,
        .g = @as(f64, @floatFromInt(v.g)) / 255.0,
        .b = @as(f64, @floatFromInt(v.b)) / 255.0,
    };
}

/// Stroke width scales with the block, so a fit-to-width shrink thins the lines
/// proportionally instead of leaving them heavy.
fn toStroke(v: svg2pdf.Stroke, s: f64) pdf.Stroke {
    return .{ .color = toRgb(v.color), .width = v.width * s };
}

fn toPaint(fill: ?svg2pdf.Rgb, stroke: ?svg2pdf.Stroke, s: f64) pdf.Paint {
    return .{
        .fill = if (fill) |f| toRgb(f) else null,
        .stroke = if (stroke) |st| toStroke(st, s) else null,
    };
}

fn toAnchor(v: svg2pdf.Anchor) pdf.Anchor {
    return switch (v) {
        .start => .start,
        .middle => .middle,
        .end => .end,
    };
}

/// Scale a point list into a page-space array owned by `a`.
fn toPoints(a: Allocator, pts: []const svg2pdf.Pt, s: f64) Allocator.Error![]pdf.Point {
    const out = try a.alloc(pdf.Point, pts.len);
    for (pts, 0..) |p, i| out[i] = xf(p, s);
    return out;
}

/// Map one display-list op onto its page helper. Schematic text is monospace in
/// every emitter, so it sets in Courier — a fixed 600/1000 em, which makes the
/// anchor arithmetic exact.
fn drawOp(p: *pdf.Page, a: Allocator, op: svg2pdf.DrawOp, s: f64) Error!void {
    switch (op) {
        .line => |v| try p.line(xf(v.a, s), xf(v.b, s), toStroke(v.stroke, s)),
        .polyline => |v| try p.polyline(try toPoints(a, v.points, s), toStroke(v.stroke, s)),
        .polygon => |v| try p.polygon(try toPoints(a, v.points, s), toPaint(v.fill, v.stroke, s)),
        // `pdf.rect` has no corner radius; `rx` rounds to square corners.
        .rect => |v| try p.rect(
            .{ .x = v.x * s, .y = v.y * s, .w = v.w * s, .h = v.h * s },
            toPaint(v.fill, v.stroke, s),
        ),
        .circle => |v| try p.circle(xf(v.c, s), v.r * s, toPaint(v.fill, v.stroke, s)),
        .arc => |v| try p.arc(.{
            .start = xf(v.from, s),
            .end = xf(v.to, s),
            .rx = v.rx * s,
            .ry = v.ry * s,
            .sweep = v.sweep_cw,
        }, toStroke(v.stroke, s)),
        .text => |v| try p.text(xf(v.at, s), v.s, .{
            .font = if (v.bold) .courier_bold else .courier,
            .size = v.size * s,
            .color = toRgb(v.fill),
            .anchor = toAnchor(v.anchor),
        }),
    }
}

// ── Validation appendix + engineering tables ─────────────────────────────

/// One column of a text table: heading plus its width in points.
const Col = struct { title: []const u8, w: f64 };

/// The appendix pages: ERC, assertions, requirement checks, then the power and
/// test-point tables — the same content and order as the markdown report's
/// validation block.
fn appendixPages(c: *Composer, block: *const DesignBlock, doc: review.ReviewDoc) Error!void {
    c.header = "Validation";
    c.sub = "Electrical rule checks, design assertions, and per-IC requirements";
    try c.beginPage();
    try ercTable(c, doc.unresolved);
    try assertionTable(c, doc.assertions);
    try requirementList(c, doc);
    try orphanNotes(c, block);

    c.header = "Power & Bring-Up";
    c.sub = "Rail budget, power-up sequence, thermal screen, and declared test points";
    try c.beginPage();
    try powerBudgetTable(c, doc.power.budget);
    try powerSequenceTable(c, doc.power.sequence);
    try thermalTable(c, doc.power.thermal, doc.power.scenarios);
    try testPointTable(c, doc.test_points);
}

/// Ref-anchored `(note "REF" …)` entries no schematic sheet claimed — a note on
/// a part declared outside every `(section …)` and outside every drawn module.
/// They land here rather than being silently dropped; `fileRefNotes` filed the
/// rest onto their parts' sheets using the mirrored predicate. Nothing is drawn
/// when every note found a home.
fn orphanNotes(c: *Composer, block: *const DesignBlock) Error!void {
    var opened = false;
    for (block.notes) |n| {
        if (hostedByASection(block, n.ref_des)) continue;
        if (!opened) try c.heading(design_notes_head);
        opened = true;
        try c.line(
            try noteText(c.scratch, n.ref_des, n.text, null),
            .{ .size = body_size },
            body_leading,
        );
    }
}

/// Whether some schematic entry hosts a note anchored to `ref`: a section (or
/// sub-section) declares it, or a sub-block module holds an instance with that
/// module-local ref-des (every module draws on exactly one sheet — a claimed
/// section's or its own appendix entry — so a plain module ref always has a
/// home; the mirror of `fileRefNotes` + `moduleDrawsRef`). Flattened
/// `slug/ref` spellings match neither side and stay appendix orphans.
fn hostedByASection(block: *const DesignBlock, ref: []const u8) bool {
    for (block.sections) |sec| if (sectionDeclares(sec, ref)) return true;
    for (block.sub_blocks) |sb| {
        for (sb.block.instances) |inst| {
            if (std.mem.eql(u8, inst.ref_des, ref)) return true;
        }
    }
    return false;
}

/// Column headings plus the rule beneath them.
fn tableHead(c: *Composer, cols: []const Col) Error!void {
    try c.ensure(row_leading * 3);
    var x = margin;
    for (cols) |col| {
        try c.put(x, c.y, col.title, .{ .font = .helvetica_bold, .size = small_size });
        x += col.w;
    }
    c.y += row_leading;
    try c.cur().line(.{ .x = margin, .y = c.y - 2 }, .{ .x = page_w - margin, .y = c.y - 2 }, c.hairline());
    c.y += 2;
}

/// One row, each cell truncated to its column. `cells` shorter than `cols`
/// leaves the remaining columns blank.
fn tableRow(c: *Composer, cols: []const Col, cells: []const []const u8) Error!void {
    try c.ensure(row_leading);
    const st: pdf.TextStyle = .{ .size = small_size };
    var x = margin;
    for (cols, 0..) |col, i| {
        if (i < cells.len and cells[i].len > 0) {
            try c.put(x, c.y, try c.fit(cells[i], st, col.w - 6), st);
        }
        x += col.w;
    }
    c.y += row_leading;
}

/// `s`, or a lone hyphen when it is empty — the table's "not applicable" cell.
fn dashIfEmpty(s: []const u8) []const u8 {
    return if (s.len > 0) s else "-";
}

/// Body text for a table with no rows, matching the markdown's italic note.
fn emptyNote(c: *Composer, s: []const u8) Error!void {
    try c.line(s, .{ .size = body_size, .color = c.fur.muted }, body_leading + 4);
}

fn ercTable(c: *Composer, violations: []const erc_mod.Violation) Error!void {
    try c.heading("ERC");
    if (violations.len == 0) return emptyNote(c, "0 violations.");
    const cols = [_]Col{
        .{ .title = "Severity", .w = 56 },
        .{ .title = "Kind", .w = 150 },
        .{ .title = "Ref", .w = 78 },
        .{ .title = "Net", .w = 92 },
        .{ .title = "Message", .w = usable_w - 376 },
    };
    try tableHead(c, &cols);
    for (violations) |v| {
        try tableRow(c, &cols, &.{
            @tagName(v.severity),
            @tagName(v.kind),
            dashIfEmpty(v.ref_des),
            dashIfEmpty(v.net),
            v.message,
        });
    }
}

fn assertionTable(c: *Composer, asserts: []const review.AssertionReport) Error!void {
    try c.heading("Assertions");
    if (asserts.len == 0) return emptyNote(c, "No design assertions declared.");
    const cols = [_]Col{
        .{ .title = "Status", .w = 56 },
        .{ .title = "Message", .w = usable_w - 56 },
    };
    try tableHead(c, &cols);
    for (asserts) |v| try tableRow(c, &cols, &.{ @tagName(v.status), v.message });
}

/// Per-IC requirement checks, one component per heading. Deduplicated by
/// ref-des the way the markdown report does — a multi-section IC otherwise
/// repeats its library requirements once per section.
fn requirementList(c: *Composer, doc: review.ReviewDoc) Error!void {
    try c.heading("Requirement Checks (per IC)");
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(c.gpa);
    var emitted = false;
    for (doc.sections) |sec| {
        for (sec.component_requirements) |e| {
            if (try requirementEntry(c, &seen, e)) emitted = true;
        }
    }
    for (doc.subblock_requirements) |e| {
        if (try requirementEntry(c, &seen, e)) emitted = true;
    }
    if (!emitted) try emptyNote(c, "No requirement-bearing components in this design.");
}

/// One component's requirement block. Returns false when it declares none or
/// was already emitted under another section.
fn requirementEntry(
    c: *Composer,
    seen: *std.StringHashMapUnmanaged(void),
    e: review.ComponentRequirementEntry,
) Error!bool {
    if (e.requirements.len == 0) return false;
    if ((try seen.fetchPut(c.gpa, e.ref_des, {})) != null) return false;
    const head = try std.fmt.allocPrint(c.scratch, "{s} - {s}", .{ e.ref_des, e.component });
    try c.line(head, .{ .font = .helvetica_bold, .size = body_size }, body_leading);
    for (e.requirements, 0..) |r, i| {
        const res: ?req_checks.Result = if (i < e.req_results.len) e.req_results[i] else null;
        const status: req_checks.Status = if (res) |v| v.status else .na;
        const s = try std.fmt.allocPrint(c.scratch, "   [{s}] {s}", .{ badge(status), r.text });
        try c.line(s, .{ .size = small_size }, row_leading);
    }
    c.y += 3;
    return true;
}

/// ASCII verdict word for a requirement result. Deliberately not the markdown's
/// check/cross glyphs: those have no WinAnsi code, so they would encode as `?`.
fn badge(status: req_checks.Status) []const u8 {
    return switch (status) {
        .pass => "PASS",
        .verified => "VERIFIED",
        .na => "PENDING",
        .fail => "FAIL",
        .unproven => "UNPROVEN",
        .layout_deferred => "LAYOUT",
    };
}

fn powerBudgetTable(c: *Composer, rails: []const power_budget.Rail) Error!void {
    try c.heading("Power Budget");
    if (rails.len == 0) return emptyNote(c, "No power rails detected.");
    const cols = [_]Col{
        .{ .title = "Rail", .w = 110 },
        .{ .title = "Source", .w = 150 },
        .{ .title = "Src typ (A)", .w = 70 },
        .{ .title = "Src max (A)", .w = 70 },
        .{ .title = "Load typ (A)", .w = 74 },
        .{ .title = "Load max (A)", .w = 74 },
        .{ .title = "Margin", .w = 60 },
        .{ .title = "Status", .w = usable_w - 608 },
    };
    try tableHead(c, &cols);
    for (rails) |r| {
        try tableRow(c, &cols, &.{
            r.net,
            dashIfEmpty(r.source_label),
            try optAmps(c, r.source_typ_a),
            try optAmps(c, r.source_max_a),
            try std.fmt.allocPrint(c.scratch, "{d:.4}", .{r.load_typ_a}),
            try std.fmt.allocPrint(c.scratch, "{d:.4}", .{r.load_max_a}),
            try optPct(c, r.margin_pct),
            @tagName(r.status),
        });
    }
}

/// An optional current formatted for a cell, or a hyphen when unknown.
fn optAmps(c: *Composer, v: ?f64) Error![]const u8 {
    const x = v orelse return "-";
    return std.fmt.allocPrint(c.scratch, "{d:.4}", .{x});
}

/// An optional margin percentage formatted for a cell.
fn optPct(c: *Composer, v: ?f64) Error![]const u8 {
    const x = v orelse return "-";
    return std.fmt.allocPrint(c.scratch, "{d:.0}%", .{x});
}

fn powerSequenceTable(c: *Composer, rows: []const power_sequencing.SequenceRow) Error!void {
    try c.heading("Power Sequencing");
    if (rows.len == 0) return emptyNote(c, "No power-up dependencies detected.");
    const cols = [_]Col{
        .{ .title = "#", .w = 30 },
        .{ .title = "Rail", .w = 110 },
        .{ .title = "Source", .w = 130 },
        .{ .title = "Enable", .w = 110 },
        .{ .title = "Depends on", .w = 110 },
        .{ .title = "Via", .w = 130 },
        .{ .title = "Status", .w = usable_w - 620 },
    };
    try tableHead(c, &cols);
    for (rows) |r| {
        try tableRow(c, &cols, &.{
            try std.fmt.allocPrint(c.scratch, "{d}", .{r.order}),
            r.rail,
            dashIfEmpty(r.source),
            dashIfEmpty(r.enable),
            dashIfEmpty(r.depends_on),
            dashIfEmpty(r.via),
            @tagName(r.status),
        });
    }
}

/// The thermal screen: the verdict sentence, the ambient window, one row per
/// screened part, then the coverage line (and, when nothing could be judged,
/// the hint naming the forms to add). The prose comes from the same
/// `review_thermal` builder the web panel and the markdown report print, so the
/// three documents state the same verdict in the same words.
fn thermalTable(
    c: *Composer,
    bt: thermal.BoardThermal,
    scenarios: thermal_scenarios.Answer,
) Error!void {
    try c.heading("Thermal");
    const lines = try review_thermal.summaryLines(c.scratch, bt, scenarios);
    try c.line(lines.verdict, .{ .font = .helvetica_bold, .size = body_size }, body_leading);
    // Kept, demoted and labelled — see review_thermal.summaryLines.
    if (lines.package.len > 0) {
        try c.line(lines.package, .{ .size = body_size, .color = c.fur.muted }, body_leading);
    }
    if (lines.ambient.len > 0) {
        const range = try std.fmt.allocPrint(c.scratch, "Board ambient range: {s}", .{lines.ambient});
        try c.line(range, .{ .size = body_size, .color = c.fur.muted }, body_leading);
    }
    if (bt.parts.len > 0) try thermalRows(c, bt.parts);
    try coolingScenarios(c, scenarios);
    const cover = try std.fmt.allocPrint(c.scratch, "Coverage: {s}.", .{lines.coverage});
    try c.line(cover, .{ .size = body_size, .color = c.fur.muted }, body_leading);
    if (lines.hint.len > 0) try emptyNote(c, lines.hint);
}

fn thermalRows(c: *Composer, parts: []const thermal.PartThermal) Error!void {
    const cols = [_]Col{
        .{ .title = "Ref", .w = 110 },
        .{ .title = "Component", .w = 150 },
        .{ .title = "P (W)", .w = 100 },
        .{ .title = "Theta-JA (C/W)", .w = 90 },
        .{ .title = "Tj (C)", .w = 60 },
        .{ .title = "Margin (C)", .w = 70 },
        .{ .title = "Max amb (C)", .w = usable_w - 580 },
    };
    try tableHead(c, &cols);
    for (parts) |row| {
        const cell = try review_thermal.cells(c.scratch, row);
        try tableRow(c, &cols, &.{
            cell.ref_des,
            cell.component,
            cell.power,
            cell.theta,
            cell.tj,
            cell.margin,
            cell.max_ambient,
        });
    }
}

/// The cooling-scenario table: what still air, forced air and a heatsink each
/// buy this board once the heat is spread over the placement it actually has.
/// A document built without a layout prints the reason instead — the same
/// sentence the web panel and the markdown report print.
fn coolingScenarios(c: *Composer, scenarios: thermal_scenarios.Answer) Error!void {
    const ladder = scenarios.ladder orelse
        return emptyNote(c, review_thermal.scenarioNote(scenarios));
    const intro = try std.fmt.allocPrint(
        c.scratch,
        "Cooling scenarios, layout-aware: each part's heat spread over the placed board, read at {d} C ambient.",
        .{ladder.ambient_c},
    );
    try c.line(intro, .{ .size = body_size, .color = c.fur.muted }, body_leading);
    const cols = [_]Col{
        .{ .title = "Scenario", .w = 150 },
        .{ .title = "Hottest part", .w = 140 },
        .{ .title = "Tj (C)", .w = 70 },
        .{ .title = "Max amb (C)", .w = 90 },
        .{ .title = "Limited by", .w = usable_w - 450 },
    };
    try tableHead(c, &cols);
    for (ladder.rows) |row| {
        const cell = try review_thermal.scenarioCells(c.scratch, ladder, row);
        try tableRow(c, &cols, &.{ cell.scenario, cell.hottest, cell.tj, cell.max_ambient, cell.limiting });
    }
}

fn testPointTable(c: *Composer, tps: []const review.TestPointEntry) Error!void {
    try c.heading("Test Points (Bring-Up)");
    if (tps.len == 0) return emptyNote(c, "No test points declared.");
    const cols = [_]Col{
        .{ .title = "Ref", .w = 90 },
        .{ .title = "Net", .w = 140 },
        .{ .title = "Purpose", .w = usable_w - 230 },
    };
    try tableHead(c, &cols);
    for (tps) |tp| try tableRow(c, &cols, &.{ tp.ref_des, tp.net, dashIfEmpty(tp.purpose) });
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Every `(…) Tj` string in `bytes`, decoded out of PDF literal-string syntax.
/// The writer emits uncompressed content streams, so the drawn text is right
/// there in the file — this is the content oracle the plan calls for.
///
/// Public because it is also the only way to compare the two review-PDF
/// surfaces (`netlisp export-pdf` and `/api/schematic-pdf`) by CONTENT: the two
/// files legitimately differ in metadata, so the twin-parity test compares the
/// text they actually draw.
pub fn extractTj(a: Allocator, bytes: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, at, ") Tj")) |end| {
        at = end + 4;
        const open = literalStart(bytes, end) orelse continue;
        try out.append(a, try decodeLiteral(a, bytes[open + 1 .. end]));
    }
    return out.toOwnedSlice(a);
}

/// The Tj strings of each page, in page order. The writer emits exactly one
/// uncompressed content stream per page and nothing else, so the stream sequence
/// IS the page sequence — which is what lets a test ask what a single page holds.
fn extractPageTexts(a: Allocator, bytes: []const u8) Allocator.Error![]const []const []const u8 {
    const open = "stream\n";
    const close = "endstream";
    var out: std.ArrayList([]const []const u8) = .empty;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, at, open)) |s| {
        const body = s + open.len;
        const e = std.mem.indexOfPos(u8, bytes, body, close) orelse break;
        at = e + close.len;
        try out.append(a, try extractTj(a, bytes[body..e]));
    }
    return out.toOwnedSlice(a);
}

/// Byte offset of the `(` opening the literal that ends at `close`, skipping
/// escaped parens. Scans backwards from the closer.
fn literalStart(bytes: []const u8, close: usize) ?usize {
    var i = close;
    while (i > 0) {
        i -= 1;
        if (bytes[i] != '(') continue;
        var back = i;
        var slashes: usize = 0;
        while (back > 0 and bytes[back - 1] == '\\') : (back -= 1) slashes += 1;
        if (slashes % 2 == 0) return i;
    }
    return null;
}

/// Undo `writeLiteral`'s escaping: `\(`, `\)`, `\\`, and `\ooo` octal.
fn decodeLiteral(a: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '\\') {
            try out.append(a, raw[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= raw.len) break;
        if (raw[i] >= '0' and raw[i] <= '7' and i + 3 <= raw.len) {
            try out.append(a, std.fmt.parseInt(u8, raw[i .. i + 3], 8) catch 0);
            i += 3;
            continue;
        }
        try out.append(a, raw[i]);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

/// True when some `Tj` string equals `want`.
fn hasText(strings: []const []const u8, want: []const u8) bool {
    for (strings) |s| if (std.mem.eql(u8, s, want)) return true;
    return false;
}

/// True when some `Tj` string contains `want`.
fn someTextContains(strings: []const []const u8, want: []const u8) bool {
    for (strings) |s| if (std.mem.indexOf(u8, s, want) != null) return true;
    return false;
}

const fixture_instances = [_]env_mod.Instance{
    .{ .ref_des = "U1", .component = "acme-mcu", .value = "", .footprint = "", .symbol = "" },
    .{ .ref_des = "C1", .component = "cap-0402", .value = "100nF", .footprint = "", .symbol = "generic-cap" },
    .{ .ref_des = "R1", .component = "res-0402", .value = "10k", .footprint = "", .symbol = "generic-res" },
    // The inductor's symbol is the subset's only `path` arc emitter, so keeping
    // it in the fixture puts the arc DrawOp through the mapping layer too.
    .{ .ref_des = "L1", .component = "ind-0603", .value = "4.7uH", .footprint = "", .symbol = "generic-ind" },
    .{ .ref_des = "FB1", .component = "ferrite-0402", .value = "600R", .footprint = "", .symbol = "generic-res" },
    .{ .ref_des = "J1", .component = "hdr-1x2", .value = "", .footprint = "", .symbol = "" },
};

const fixture_nets = [_]env_mod.Net{
    .{ .name = "VDD3V3", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "U1", .pin = "2" },
        .{ .ref_des = "C1", .pin = "1" },
        .{ .ref_des = "L1", .pin = "2" },
    } },
    .{ .name = "GND", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "3" },
        .{ .ref_des = "C1", .pin = "2" },
    } },
    .{ .name = "SIG", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "5" },
        .{ .ref_des = "R1", .pin = "1" },
    } },
    .{ .name = "SIG_PULLUP", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "R1", .pin = "2" },
        .{ .ref_des = "J1", .pin = "1" },
    } },
    // A two-hop L1 → FB1 chain off pin 2, so V_IN lands as a far-side net label
    // rather than terminating on a hub pad the way VDD3V3/GND do.
    .{ .name = rails_mod.system_rail, .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "L1", .pin = "1" },
        .{ .ref_des = "FB1", .pin = "1" },
    } },
    .{ .name = "V_IN", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "FB1", .pin = "2" },
        .{ .ref_des = "J1", .pin = "2" },
    } },
};

/// Pin-group label the fixture's supply pads share.
const power_group = "VDD Power";

const fixture_pins = [_]env_mod.PartPin{
    .{ .pin = "1", .net = "VDD3V3", .pin_name = "VDD_1", .group = power_group },
    .{ .pin = "2", .net = "VDD3V3", .pin_name = "VDD_2", .group = power_group },
    .{ .pin = "3", .net = "GND", .pin_name = "VSS_1", .group = power_group },
    .{ .pin = "5", .net = "SIG", .pin_name = "PA3", .group = "GPIO" },
};

const fixture_pin_groups = [_]env_mod.PinGroup{.{ .ref_des = "U1", .pins = &fixture_pins }};

const fixture_sections = [_]Section{.{
    .name = "Core System",
    .description = "acme-mcu supply rails and one GPIO strap",
    .pin_groups = &fixture_pin_groups,
    .instances = &[_]env_mod.Instance{fixture_instances[fixture_instances.len - 1]},
}};

/// A synthetic design built in memory — no `projects/designs` dependency (that
/// tree is a separate repo and is empty in a worktree).
fn fixtureBlock() DesignBlock {
    return .{
        .name = "Acme Reference Board",
        .instances = &fixture_instances,
        .nets = &fixture_nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .sections = &fixture_sections,
    };
}

/// A module fixture's own parts: one hub plus a bypass cap, on ref-deses the
/// parent design does not use, so the module's rendered hub is distinguishable
/// from the design's own in the output text.
const module_instances = [_]env_mod.Instance{
    .{ .ref_des = "U2", .component = "gate-ic", .value = "", .footprint = "", .symbol = "" },
    .{ .ref_des = "C9", .component = "cap-0402", .value = "22nF", .footprint = "", .symbol = "generic-cap" },
};

const module_nets = [_]env_mod.Net{
    .{ .name = "GATE_IN", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "U2", .pin = "1" },
        .{ .ref_des = "C9", .pin = "1" },
    } },
    .{ .name = "GATE_OUT", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "U2", .pin = "2" },
    } },
    .{ .name = "MOD_GND", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "U2", .pin = "3" },
        .{ .ref_des = "C9", .pin = "2" },
    } },
};

/// The module's own `(note …)` entries: one inside a `(section …)` of the module,
/// one anchored to a ref-des. Neither reached the PDF before unified sheets.
const module_section_notes = [_]env_mod.SectionNote{
    .{ .text = "gate holds the loop filter shorted while the PLL re-locks" },
};
const module_sections = [_]Section{.{ .name = "Gate", .notes = &module_section_notes }};
const module_ref_notes = [_]env_mod.Note{
    .{ .ref_des = "U2", .text = "gate-ic is the SOT-23 part, not the SC-70 twin" },
};

/// A module block a `(sub-block …)` can instantiate: hub, passive, and both note
/// classes. `with_notes = false` gives the same circuit with nothing to say.
fn moduleBlock(with_notes: bool) DesignBlock {
    return .{
        .name = "Gate Module",
        .instances = &module_instances,
        .nets = &module_nets,
        .ports = &.{},
        .notes = if (with_notes) &module_ref_notes else &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .sections = if (with_notes) &module_sections else &.{},
    };
}

/// A section that explicitly `(hosts …)` the named sub-blocks — the authoritative
/// branch of `membership.computeSubBlockAttachments`, so a fixture pins attachment
/// without having to reproduce the net-affinity heuristic's inputs.
fn hostingSection(hosts: []const []const u8, notes: []const env_mod.SectionNote) Section {
    return .{
        .name = "Gate Control",
        .description = "loop-filter gate - chip details sealed in the gate module",
        .notes = notes,
        .hosts = hosts,
    };
}

/// Compose the fixture design with a pinned generation stamp.
fn composeFixture(a: Allocator, block: *const DesignBlock) ![]u8 {
    const doc = try review.buildReview(a, "acme", block, &.{}, &.{}, null);
    return compose(a, block, "projects/designs", "acme", doc, .{
        .generated_at = "2026-07-30T00:00:00Z",
        .build_id = "deadbee",
        .open_notes = 2,
    });
}

// spec: export-pdf - The composed document carries the design title, every rendered ref-des and net label as extractable text
test "the composed PDF's text contains the design title, ref-deses and net labels" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const block = fixtureBlock();
    const bytes = try composeFixture(a, &block);
    const strings = try extractTj(a, bytes);

    try testing.expect(hasText(strings, "Acme Reference Board"));
    try testing.expect(hasText(strings, "Core System"));
    // Hub title, passive labels, and the far-side net label all come from the
    // translated schematic display list, tying the PDF to the DesignBlock.
    try testing.expect(hasText(strings, "U1 acme-mcu"));
    try testing.expect(someTextContains(strings, "C1 100nF"));
    try testing.expect(someTextContains(strings, "R1 10k"));
    try testing.expect(someTextContains(strings, "L1 4.7uH"));
    // Far-side net labels — the end of each passive chain. A rail that lands
    // only on the hub's own pads (VDD3V3, GND) is drawn as a pin stub, not a
    // label, so those are deliberately not asserted here.
    try testing.expect(hasText(strings, "SIG_PULLUP"));
    try testing.expect(hasText(strings, "V_IN"));
}

// spec: export-pdf - No text in the composed document falls back to an unmappable question mark
test "the composed PDF encodes every glyph without a question-mark fallback" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const block = fixtureBlock();
    const strings = try extractTj(a, try composeFixture(a, &block));
    for (strings) |s| {
        // A literal '?' never appears in the composer's own strings or in the
        // fixture's data, so any '?' here is an encoder fallback.
        try testing.expect(std.mem.indexOfScalar(u8, s, '?') == null);
    }
}

// spec: export-pdf - A composed document passes the writer's structural self-check
test "the composed PDF passes the structural self-check" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const block = fixtureBlock();
    try pdf.validate(try composeFixture(a, &block));
}

// spec: export-pdf - A fixed injected timestamp makes two composes byte-identical
test "two composes of the same design with a fixed stamp are byte-identical" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const block = fixtureBlock();
    const first = try composeFixture(a, &block);
    const second = try composeFixture(a, &block);
    try testing.expectEqualSlices(u8, first, second);
}

// spec: export-pdf - The cover page carries the injected generation stamp, build hash and status roll-up
test "the cover page states the generation stamp, build hash and status counts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const block = fixtureBlock();
    const strings = try extractTj(a, try composeFixture(a, &block));
    try testing.expect(someTextContains(strings, "2026-07-30T00:00:00Z"));
    try testing.expect(someTextContains(strings, "deadbee"));
    try testing.expect(someTextContains(strings, "ERC:"));
    try testing.expect(someTextContains(strings, "Assertions:"));
    try testing.expect(someTextContains(strings, "Open design notes: 2"));
}

// spec: export-pdf - Every page after the cover carries a footer naming the design and its page number
test "each page after the cover carries a design name and page-of-total footer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const block = fixtureBlock();
    const bytes = try composeFixture(a, &block);
    const strings = try extractTj(a, bytes);
    const total = pageCount(bytes);
    try testing.expect(total >= 4); // cover + a section page + two appendix pages
    // Footers run from page 2 to the last page; the cover has none.
    for (2..total + 1) |page| {
        const want = try std.fmt.allocPrint(a, "page {d}/{d}", .{ page, total });
        try testing.expect(someTextContains(strings, want));
    }
    try testing.expect(!someTextContains(strings, "page 1/"));
}

/// A one-`<svg>` document `translateAll` accepts, `h` user-space units tall,
/// with a labelled text op near the bottom so a slice can be detected.
fn tallSvg(a: Allocator, h: usize) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(a);
    const w = &buf.writer;
    try w.print("<svg viewBox=\"0 0 400 {d}\">\n", .{h});
    try w.writeAll("<text x=\"10\" y=\"20\" font-size=\"10\">TOPMARK</text>\n");
    try w.print("<text x=\"10\" y=\"{d}\" font-size=\"10\">BOTMARK</text>\n", .{h - 10});
    try w.print("<line x1=\"0\" y1=\"0\" x2=\"400\" y2=\"{d}\" stroke=\"#000\"/>\n", .{h});
    try w.writeAll("</svg>\n");
    return buf.written();
}

/// A group-labelled hub block for the grid tests: an `<h4>` heading over a
/// `<svg>` `h` user-space units tall carrying one marker string, so each cell
/// is individually detectable in the output text.
fn labelledSvg(a: Allocator, label: []const u8, mark: []const u8, h: usize) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(a);
    const w = &buf.writer;
    try w.print("<div class=\"hub-group-block\">", .{});
    if (label.len > 0) try w.print("<h4 class=\"hub-group-label\">{s}</h4>\n", .{label});
    try w.print("<svg viewBox=\"0 0 400 {d}\">\n", .{h});
    try w.print("<text x=\"10\" y=\"20\" font-size=\"10\">{s}</text>\n", .{mark});
    try w.print("<line x1=\"0\" y1=\"0\" x2=\"400\" y2=\"{d}\" stroke=\"#000\"/>\n", .{h});
    try w.writeAll("</svg></div>\n");
    return buf.written();
}

/// The grid fixture: `n` group-labelled blocks each `h` user-space units tall,
/// captioned `GROUP0…` and marked `MARK0…` so every cell is identifiable.
fn gridFixture(a: Allocator, n: usize, h: usize) ![]svg2pdf.Document {
    var docs: std.ArrayList(svg2pdf.Document) = .empty;
    for (0..n) |i| {
        const label = try std.fmt.allocPrint(a, "GROUP{d}", .{i});
        const mark = try std.fmt.allocPrint(a, "MARK{d}", .{i});
        try docs.appendSlice(a, try svg2pdf.translateAll(a, try labelledSvg(a, label, mark, h), .{}, null));
    }
    return docs.toOwnedSlice(a);
}

/// Height the sequential one-block-per-row flow would need for `docs`.
fn stackedHeight(docs: []const svg2pdf.Document) f64 {
    var total: f64 = 0;
    for (docs) |d| total += d.height + block_gap;
    return total;
}

/// A clip rectangle recovered from a content stream, in PDF user space (y grows
/// UP from the page's bottom-left, so `y` is the box's BOTTOM edge).
const ClipRect = struct { x: f64, y: f64, w: f64, h: f64 };

/// Every `x y w h re W n` clip the document sets. `drawDocAt` is the only clip
/// emitter, so these are exactly the placed blocks' boxes — recovered from the
/// bytes so a geometry test pins what the writer actually wrote rather than
/// re-running the packer's own arithmetic.
fn extractClips(a: Allocator, bytes: []const u8) Allocator.Error![]const ClipRect {
    var out: std.ArrayList(ClipRect) = .empty;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, at, "re\nW\nn")) |end| {
        at = end + 1;
        const from = (std.mem.lastIndexOfScalar(u8, bytes[0..end], '\n') orelse continue) + 1;
        var it = std.mem.tokenizeScalar(u8, bytes[from..end], ' ');
        var v: [4]f64 = undefined;
        var n: usize = 0;
        while (it.next()) |tok| {
            if (n == v.len) break;
            v[n] = std.fmt.parseFloat(f64, tok) catch break;
            n += 1;
        }
        if (n != v.len) continue;
        try out.append(a, .{ .x = v[0], .y = v[1], .w = v[2], .h = v[3] });
    }
    return out.toOwnedSlice(a);
}

/// Whether two clip rectangles share any area. Grid cells tile the sheet, so any
/// overlap means the packer stacked two blocks on top of each other.
fn clipsOverlap(p: ClipRect, q: ClipRect) bool {
    const ix = @min(p.x + p.w, q.x + q.w) - @max(p.x, q.x);
    const iy = @min(p.y + p.h, q.y + q.h) - @max(p.y, q.y);
    return ix > geom_eps and iy > geom_eps;
}

/// Slack for comparing recovered coordinates, which the writer rounds to 2dp.
const geom_eps: f64 = 0.02;

/// Assert `clips` tile a genuine 2D grid: no two boxes overlap, at least two
/// share a shelf (equal top edge), and not every pair does — so the packer both
/// filled shelves and wrapped between them. A shelf packer that wrapped after
/// every cell, or one that never advanced, fails here while a marker census
/// still passes.
fn expectTiledGrid(clips: []const ClipRect) !void {
    var shelf_mates: usize = 0;
    for (clips, 0..) |p, i| {
        for (clips[i + 1 ..]) |q| {
            if (@abs((p.y + p.h) - (q.y + q.h)) <= geom_eps) shelf_mates += 1;
            try testing.expect(!clipsOverlap(p, q));
        }
    }
    try testing.expect(shelf_mates >= 1);
    try testing.expect(shelf_mates < clips.len * (clips.len - 1) / 2);
}

/// A fresh single-page composer for the block-placement tests.
fn gridComposer(a: Allocator, name: []const u8) Composer {
    return .{
        .gpa = a,
        .scratch = a,
        .out = pdf.Doc.init(a, .{}),
        .opts = .{},
        .fur = print_furniture,
        .design_name = name,
        .pages = .empty,
        .y = content_top,
        .header = "Grid Section",
    };
}

// spec: export-pdf - A section's blocks pack onto one sheet as a 2D grid rather than one block per row
test "six blocks that could never stack on one page grid onto a single sheet" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Six 300-unit-tall blocks stacked one per row need ~1880 pt — four pages of
    // the ~503 pt usable height, even before the shrink floor is considered.
    const docs = try gridFixture(a, 6, 300);
    try testing.expectEqual(@as(usize, 6), docs.len);
    try testing.expect(stackedHeight(docs) > usable_h * 3);

    var c = gridComposer(a, "grid");
    defer c.deinit();
    try c.beginPage();
    try testing.expect(try gridBlocks(&c, a, docs, 0));
    try c.footers();
    const bytes = try c.out.finish();

    try pdf.validate(bytes);
    // One sheet holds the whole section, the grid stayed inside it, and no cell
    // was dropped or clipped away: every marker survives.
    try testing.expectEqual(@as(usize, 1), c.pages.items.len);
    try testing.expectEqual(@as(usize, 1), pageCount(bytes));
    try testing.expect(c.y > content_top and c.y <= content_bottom + block_gap);
    const strings = try extractTj(a, bytes);
    for (0..docs.len) |i| {
        try testing.expect(hasText(strings, try std.fmt.allocPrint(a, "MARK{d}", .{i})));
    }

    // Genuine 2D packing, not a tall single column dressed up as a grid: every
    // block got its own clip box, and those boxes tile the sheet.
    const clips = try extractClips(a, bytes);
    try testing.expectEqual(docs.len, clips.len);
    try expectTiledGrid(clips);
}

// spec: export-pdf - A grid cell carrying a pin-group label draws that label above its block
test "a labelled grid cell captions its block and an unlabelled one does not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const labelled = try svg2pdf.translateAll(a, try labelledSvg(a, "VDD Power", "PWRMARK", 200), .{}, null);
    const bare = try svg2pdf.translateAll(a, try labelledSvg(a, "", "BAREMARK", 200), .{}, null);
    try testing.expectEqualStrings("VDD Power", labelled[0].title);
    try testing.expectEqualStrings("", bare[0].title);

    var c = gridComposer(a, "label");
    defer c.deinit();
    try c.beginPage();
    try testing.expect(try gridBlocks(&c, a, &.{ labelled[0], bare[0] }, 0));
    const bytes = try c.out.finish();

    try pdf.validate(bytes);
    const strings = try extractTj(a, bytes);
    // The label is drawn as page furniture above its cell, alongside both
    // blocks' own content.
    try testing.expect(hasText(strings, "VDD Power"));
    try testing.expect(hasText(strings, "PWRMARK"));
    try testing.expect(hasText(strings, "BAREMARK"));
    // Only the labelled cell reserves a label row, so its box is taller.
    try testing.expectApproxEqAbs(grid_label_h, cellHeight(labelled[0], 1) - cellHeight(bare[0], 1), 0.01);
}

// spec: export-pdf - A very large schematic document taller than one page slices across pages with the section header repeated
test "a hub taller than one page slices across pages and repeats the section header" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 400 user-space units wide fits the page width at natural size, but 4500
    // tall is far past the shrink floor: the block clamps at min_block_scale
    // and still spans several pages, so it slices.
    const docs = try svg2pdf.translateAll(a, try tallSvg(a, 4500), .{}, null);
    try testing.expectEqual(@as(usize, 1), docs.len);
    const want_slices: usize = @intFromFloat(@ceil(docs[0].height * min_block_scale / usable_h));
    try testing.expect(want_slices >= 3);

    var c: Composer = .{
        .gpa = a,
        .scratch = a,
        .out = pdf.Doc.init(a, .{}),
        .opts = .{},
        .fur = print_furniture,
        .design_name = "slice",
        .pages = .empty,
        .y = content_top,
        .header = "Tall Section",
    };
    defer c.deinit();
    try c.beginPage();
    try placeDoc(&c, a, docs[0]);
    try c.footers();
    const bytes = try c.out.finish();

    try pdf.validate(bytes);
    try testing.expectEqual(want_slices, c.pages.items.len);
    try testing.expectEqual(want_slices, pageCount(bytes));
    // The header repeats on every continuation page, and both ends of the
    // document survive the slicing rather than being clipped away.
    const strings = try extractTj(a, bytes);
    var headers: usize = 0;
    for (strings) |s| {
        if (std.mem.eql(u8, s, "Tall Section")) headers += 1;
    }
    try testing.expectEqual(want_slices, headers);
    try testing.expect(hasText(strings, "TOPMARK"));
    try testing.expect(hasText(strings, "BOTMARK"));
}

// spec: export-pdf - A document taller than the page scales down to fit one page before it is ever sliced
test "a moderately tall document shrinks onto a single page instead of splitting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 900 units tall overflows the ~503 pt usable height at natural size but
    // fits one page at ~0.54 — comfortably above the shrink floor, so the old
    // behaviour (two slices) must not happen.
    const docs = try svg2pdf.translateAll(a, try tallSvg(a, 900), .{}, null);
    try testing.expectEqual(@as(usize, 1), docs.len);

    var c: Composer = .{
        .gpa = a,
        .scratch = a,
        .out = pdf.Doc.init(a, .{}),
        .opts = .{},
        .fur = print_furniture,
        .design_name = "shrink",
        .pages = .empty,
        .y = content_top,
        .header = "Tall Section",
    };
    defer c.deinit();
    try c.beginPage();
    try placeDoc(&c, a, docs[0]);
    try c.footers();
    const bytes = try c.out.finish();

    try pdf.validate(bytes);
    // One page, with both extremes of the document present: shrunk, not sliced.
    try testing.expectEqual(@as(usize, 1), pageCount(bytes));
    const strings = try extractTj(a, bytes);
    try testing.expect(hasText(strings, "TOPMARK"));
    try testing.expect(hasText(strings, "BOTMARK"));
}

// spec: export-pdf - A document that fits the page flows as one block without being split
test "a document shorter than a page is placed whole and advances the cursor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const docs = try svg2pdf.translateAll(a, try tallSvg(a, 120), .{}, null);

    var c: Composer = .{
        .gpa = a,
        .scratch = a,
        .out = pdf.Doc.init(a, .{}),
        .opts = .{},
        .fur = print_furniture,
        .design_name = "one",
        .pages = .empty,
        .y = content_top,
    };
    defer c.deinit();
    try c.beginPage();
    const before = c.y;
    try placeDoc(&c, a, docs[0]);
    try testing.expectEqual(@as(usize, 1), c.pages.items.len);
    try testing.expectApproxEqAbs(before + docs[0].height + block_gap, c.y, 0.01);
}

// spec: export-pdf - An empty design with no sections, sub-blocks or findings still composes a valid document
test "an empty design composes a valid cover-plus-appendix document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var block: DesignBlock = .{
        .name = "",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const doc = try review.buildReview(a, "bare", &block, &.{}, &.{}, null);
    const bytes = try compose(a, &block, "projects/designs", "bare", doc, .{ .generated_at = "T" });
    try pdf.validate(bytes);
    // Cover + the two appendix pages, with the design name standing in for an
    // absent title.
    try testing.expectEqual(@as(usize, 3), pageCount(bytes));
    const strings = try extractTj(a, bytes);
    try testing.expect(hasText(strings, "bare"));
    try testing.expect(someTextContains(strings, "No power rails detected."));
    try testing.expect(someTextContains(strings, "No test points declared."));
}

// spec: export-pdf - A section with no drawable schematic flows inline instead of claiming its own page
test "a notes-only section flows inline and adds no page" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = fixtureBlock();
    const base_bytes = try composeFixture(a, &base);

    const sparse_notes = [_]env_mod.SectionNote{
        .{ .text = "chip details sealed in the usb-c-hs module" },
    };
    var secs = [_]Section{ fixture_sections[0], .{
        .name = "USB",
        .description = "USB 2.0 HS via USB-C",
        .notes = &sparse_notes,
    } };
    var block = fixtureBlock();
    block.sections = &secs;
    const bytes = try composeFixture(a, &block);
    try pdf.validate(bytes);

    // The stub section rides an existing page: same page count as without it,
    // yet its name, subtitle, and note text all survive into the document.
    try testing.expectEqual(pageCount(base_bytes), pageCount(bytes));
    const strings = try extractTj(a, bytes);
    try testing.expect(hasText(strings, "USB"));
    try testing.expect(someTextContains(strings, "usb-c-hs"));
}

// spec: export-pdf - Two schematic-less sections in a row share the preceding sheet instead of the second claiming a page
test "two consecutive stub sections land on the same page" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = fixtureBlock();
    const base_bytes = try composeFixture(a, &base);

    // Two schematic-less sections back to back after a section that owns a sheet.
    // The sheet's tail reserve budgeted for exactly ONE following compact entry,
    // so the second spilled onto a page holding nothing but its own name, status
    // line and notes — a stub page, which is what the compact flow exists to
    // avoid. The reserve now looks ahead and holds back both entries' measured
    // heights.
    const usb_notes = [_]env_mod.SectionNote{.{ .text = "sealed in the usb-c-hs module" }};
    const led_notes = [_]env_mod.SectionNote{.{ .text = "sealed in the status-led module" }};
    var secs = [_]Section{
        fixture_sections[0],
        .{ .name = "USB", .description = "USB 2.0 HS via USB-C", .notes = &usb_notes },
        .{ .name = "Power Status LED", .description = "green 3V3 present", .notes = &led_notes },
    };
    var block = fixtureBlock();
    block.sections = &secs;
    const bytes = try composeFixture(a, &block);
    try pdf.validate(bytes);

    // Neither stub costs a page…
    try testing.expectEqual(pageCount(base_bytes), pageCount(bytes));
    // …and they share one, so no page holds only the second.
    const pages = try extractPageTexts(a, bytes);
    try testing.expectEqual(pageCount(bytes), pages.len);
    var together = false;
    for (pages) |texts| {
        if (hasText(texts, "USB") and hasText(texts, "Power Status LED")) together = true;
    }
    try testing.expect(together);
}

// spec: export-pdf - A sub-block whose module draws no hub schematic becomes an inline entry, not a blank page
test "a passive-only sub-block module is an inline entry rather than a page" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = fixtureBlock();
    const base_bytes = try composeFixture(a, &base);

    // A module of passives only (C1/R1/L1, no U-prefix hub), so there is no
    // hub-and-spoke drawing to make.
    var inner: DesignBlock = .{
        .name = "Pi Attenuator",
        .instances = fixture_instances[1..4],
        .nets = &fixture_nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const subs = [_]env_mod.SubBlock{
        .{ .name = "pad20db", .block = &inner, .source = "pi-pad" },
    };
    var block = fixtureBlock();
    block.sub_blocks = &subs;
    const bytes = try composeFixture(a, &block);
    try pdf.validate(bytes);

    try testing.expectEqual(pageCount(base_bytes), pageCount(bytes));
    const strings = try extractTj(a, bytes);
    try testing.expect(hasText(strings, "pad20db (sub-block)"));
    try testing.expect(hasText(strings, "Pi Attenuator"));
}

// spec: export-pdf - A repeated sub-block module renders once with its instantiation count
test "a module instantiated twice draws one page captioned with its repeat count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var inner: DesignBlock = .{
        .name = "LDO Rail",
        .instances = &fixture_instances,
        .nets = &fixture_nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const subs = [_]env_mod.SubBlock{
        .{ .name = "ldo1", .block = &inner, .source = "adp7118-ldo" },
        .{ .name = "ldo2", .block = &inner, .source = "adp7118-ldo" },
    };
    var block = fixtureBlock();
    block.sub_blocks = &subs;

    const doc = try review.buildReview(a, "dup", &block, &.{}, &.{}, null);
    const bytes = try compose(a, &block, "projects/designs", "dup", doc, .{ .generated_at = "T" });
    try pdf.validate(bytes);
    const strings = try extractTj(a, bytes);
    // One page for the module, captioned with the count — not two pages.
    try testing.expect(someTextContains(strings, "LDO Rail (sub-block x2)"));
    try testing.expect(!someTextContains(strings, "ldo2 (sub-block)"));
    try testing.expect(someTextContains(strings, "ldo1 (sub-block)"));
}

/// The page holding `want`, or null when no page does. The writer emits exactly one
/// content stream per page, so this asks what a single SHEET carries — the question
/// a unified-sheet test has to ask.
fn pageWith(pages: []const []const []const u8, want: []const u8) ?[]const []const u8 {
    for (pages) |texts| {
        if (hasText(texts, want)) return texts;
    }
    return null;
}

/// How many `Tj` strings equal `want` across the whole document.
fn countText(strings: []const []const u8, want: []const u8) usize {
    var n: usize = 0;
    for (strings) |s| {
        if (std.mem.eql(u8, s, want)) n += 1;
    }
    return n;
}

// spec: export-pdf - A section's attached single-instance sub-block draws on the section's own sheet, and the sub-block appendix does not repeat it
test "an attached module draws on its section's sheet instead of its own appendix page" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var inner = moduleBlock(false);
    const subs = [_]env_mod.SubBlock{.{ .name = "gate1", .block = &inner, .source = "gate-module" }};
    var secs = [_]Section{ fixture_sections[0], hostingSection(&.{"gate1"}, &.{}) };
    var block = fixtureBlock();
    block.sections = &secs;
    block.sub_blocks = &subs;

    const bytes = try composeFixture(a, &block);
    try pdf.validate(bytes);
    const pages = try extractPageTexts(a, bytes);

    // The section's own sheet carries the module's hub, captioned with the
    // sub-block name plus the module title…
    const sheet = pageWith(pages, "Gate Control") orelse return error.SectionSheetMissing;
    try testing.expect(hasText(sheet, "U2 gate-ic"));
    try testing.expect(hasText(sheet, "gate1 - Gate Module"));
    // …and nothing repeats it in the sub-block appendix.
    const strings = try extractTj(a, bytes);
    try testing.expect(!someTextContains(strings, "(sub-block)"));
    try testing.expectEqual(@as(usize, 1), countText(strings, "U2 gate-ic"));
}

// spec: export-pdf - A module instantiated more than once stays an appendix entry with its repeat count rather than being drawn into every section hosting it
test "a twice-instantiated hosted module stays one appendix entry with its count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var inner = moduleBlock(false);
    const subs = [_]env_mod.SubBlock{
        .{ .name = "gate1", .block = &inner, .source = "gate-module" },
        .{ .name = "gate2", .block = &inner, .source = "gate-module" },
    };
    var secs = [_]Section{ fixture_sections[0], hostingSection(&.{ "gate1", "gate2" }, &.{}) };
    var block = fixtureBlock();
    block.sections = &secs;
    block.sub_blocks = &subs;

    const bytes = try composeFixture(a, &block);
    try pdf.validate(bytes);
    const strings = try extractTj(a, bytes);
    // Drawing it into each hosting section would duplicate one circuit twice, so
    // the repeat collapse wins: one appendix entry, captioned with the count.
    try testing.expect(hasText(strings, "gate1 (sub-block)"));
    try testing.expect(!hasText(strings, "gate2 (sub-block)"));
    try testing.expect(someTextContains(strings, "Gate Module (sub-block x2)"));
    try testing.expectEqual(@as(usize, 1), countText(strings, "U2 gate-ic"));
}

// spec: export-pdf - A module's own notes render on the sheet that draws its circuit
test "a module's section and ref-anchored notes render where its circuit draws" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var inner = moduleBlock(true);
    const subs = [_]env_mod.SubBlock{.{ .name = "gate1", .block = &inner, .source = "gate-module" }};
    var secs = [_]Section{ fixture_sections[0], hostingSection(&.{"gate1"}, &.{}) };
    var block = fixtureBlock();
    block.sections = &secs;
    block.sub_blocks = &subs;

    const attached = try composeFixture(a, &block);
    try pdf.validate(attached);
    const sheet = pageWith(try extractPageTexts(a, attached), "U2 gate-ic") orelse
        return error.ModuleSheetMissing;
    // Both note classes land on the sheet drawing the module, each naming its owner.
    try testing.expect(hasText(sheet, "Module notes"));
    try testing.expect(someTextContains(sheet, "gate1: gate holds the loop filter"));
    try testing.expect(someTextContains(sheet, "gate1/U2: gate-ic is the SOT-23"));

    // Unhosted, the same module keeps its appendix entry — and its notes follow the
    // circuit there rather than staying invisible, which is where they used to end.
    var loose = fixtureBlock();
    loose.sub_blocks = &subs;
    const appendix = try composeFixture(a, &loose);
    try pdf.validate(appendix);
    const page = pageWith(try extractPageTexts(a, appendix), "gate1 (sub-block)") orelse
        return error.AppendixPageMissing;
    try testing.expect(someTextContains(page, "gate1: gate holds the loop filter"));
}

// spec: export-pdf - A ref-anchored design note draws on the sheet holding its part, and one whose ref no section declares surfaces in the appendix
test "a ref-anchored note follows its part's sheet and an unmatched one reaches the appendix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const notes = [_]env_mod.Note{
        // U1 is the Core System section's `(pins …)` hub, so this note has a sheet.
        .{ .ref_des = "U1", .text = "acme-mcu needs the 32 kHz crystal populated" },
        // Nothing declares ZZ99, so this one has none.
        .{ .ref_des = "ZZ99", .text = "part removed in rev C but its note survived" },
    };
    var block = fixtureBlock();
    block.notes = &notes;

    const bytes = try composeFixture(a, &block);
    try pdf.validate(bytes);
    const pages = try extractPageTexts(a, bytes);

    const sheet = pageWith(pages, "Core System") orelse return error.SectionSheetMissing;
    try testing.expect(someTextContains(sheet, "U1: acme-mcu needs the 32 kHz"));
    try testing.expect(!someTextContains(sheet, "ZZ99"));
    // The orphan is not dropped: it surfaces under the validation appendix.
    const appendix = pageWith(pages, "Validation") orelse return error.AppendixPageMissing;
    try testing.expect(someTextContains(appendix, "ZZ99: part removed in rev C"));
}

// spec: export-pdf - A sheet trims its notes reserve to what it can spare rather than abandoning the grid, so a lone tall hub never leaves the sheet holding only its header
test "a lone tall block keeps its sheet when the reserve exceeds what the sheet can spare" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const docs = try svg2pdf.translateAll(a, try tallSvg(a, 900), .{}, null);

    var c = gridComposer(a, "reserve");
    defer c.deinit();
    try c.beginPage();
    // A live sheet's cursor sits BELOW content_top when the grid runs (the
    // status line advanced it). At content_top the sequential fallback happens
    // to fit one page too, which made the first version of this test vacuous.
    c.y += body_leading;
    // A reserve larger than anything the sheet could give back: the grid must still
    // pack here. Failing it dropped to the sequential flow, whose first `ensure`
    // opened a new page and left this one holding nothing but its header.
    try blocksOnSheet(&c, a, docs, usable_h);
    const bytes = try c.out.finish();

    try pdf.validate(bytes);
    try testing.expectEqual(@as(usize, 1), c.pages.items.len);
    const strings = try extractTj(a, bytes);
    try testing.expect(hasText(strings, "TOPMARK"));
    try testing.expect(hasText(strings, "BOTMARK"));
    // The grid genuinely granted a reserve: its clip box is materially shorter
    // than the unreserved budget, not merely squeaking through the fallback.
    const clip_h = maxClipHeight(bytes);
    try testing.expect(clip_h > 100);
    try testing.expect(clip_h < block_fit_h - 40);
}

/// The largest height component among the clip rects (`… re` + `W`) in `bytes` —
/// the byte-level hook tests use to prove a grid honoured its reserve.
fn maxClipHeight(bytes: []const u8) f64 {
    var best: f64 = 0;
    var prev: []const u8 = "";
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, line, "W") and std.mem.endsWith(u8, prev, " re")) {
            best = @max(best, clipRectHeight(prev[0 .. prev.len - " re".len]));
        }
        prev = line;
    }
    return best;
}

/// The fourth number of one `x y w h` clip-rect operand line, or 0 on any
/// malformed shape (the caller compares against a floor, so 0 is safely inert).
fn clipRectHeight(operands: []const u8) f64 {
    var toks = std.mem.splitScalar(u8, operands, ' ');
    var last: []const u8 = "";
    var n: usize = 0;
    while (toks.next()) |t| : (n += 1) last = t;
    if (n != 4) return 0;
    return std.fmt.parseFloat(f64, last) catch 0;
}

// spec: export-pdf - A module note repeating a section note's visible text is dropped while an identical note from a sibling module is kept
test "note dedup is scoped to the section and matches the visible prefix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Longer than any printable prose row, so the paraphrase below diverges
    // only past what a reader can see.
    const prefix: []const u8 = &note_dedup_pad;
    const sec_notes = [_]env_mod.SectionNote{.{ .text = prefix ++ " (RF-feed block)" }};
    const mod_notes_a = [_]env_mod.SectionNote{
        .{ .text = prefix ++ " (see RF Feed Matching)" },
        .{ .text = "bias detail lives in the module" },
    };
    const mod_notes_b = [_]env_mod.SectionNote{
        .{ .text = "bias detail lives in the module" },
    };
    const secs_a = [_]Section{.{ .name = "MA", .notes = &mod_notes_a }};
    const secs_b = [_]Section{.{ .name = "MB", .notes = &mod_notes_b }};
    var inner_a: DesignBlock = .{
        .name = "Mod A",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .sections = &secs_a,
    };
    var inner_b: DesignBlock = .{
        .name = "Mod B",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .sections = &secs_b,
    };
    const mods = [_]env_mod.SubBlock{
        .{ .name = "ma", .block = &inner_a, .source = "mod-a" },
        .{ .name = "mb", .block = &inner_b, .source = "mod-b" },
    };
    var e: Entry = .{
        .name = "RF",
        .sub = "",
        .sec = .{ .name = "RF", .notes = &sec_notes },
        .docs = &.{},
        .mods = &mods,
    };
    try buildProse(a, &e, &.{});

    var bias_rows: usize = 0;
    var kept_section = false;
    var dropped_paraphrase = true;
    for (e.prose) |row| {
        if (std.mem.indexOf(u8, row.text, "see RF Feed Matching") != null) dropped_paraphrase = false;
        if (std.mem.indexOf(u8, row.text, "(RF-feed block)") != null) kept_section = true;
        if (std.mem.indexOf(u8, row.text, "bias detail lives in the module") != null) bias_rows += 1;
    }
    // The paraphrase that diverges only past the printable prefix reads as the
    // same paragraph, so it is dropped; the section's own row stays.
    try testing.expect(dropped_paraphrase);
    try testing.expect(kept_section);
    // Sibling modules' identical notes are each module's own fact: both stay.
    try testing.expectEqual(@as(usize, 2), bias_rows);
}

// spec: export-pdf - Long table cells truncate to their column instead of overrunning the page
test "a table cell wider than its column truncates with a marker" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c: Composer = .{
        .gpa = a,
        .scratch = a,
        .out = pdf.Doc.init(a, .{}),
        .opts = .{},
        .fur = print_furniture,
        .design_name = "fit",
        .pages = .empty,
        .y = content_top,
    };
    defer c.deinit();
    const st: pdf.TextStyle = .{ .size = small_size };
    const long = "a-very-long-net-name-that-cannot-possibly-fit-in-forty-points";
    const cut = try c.fit(long, st, 40);
    try testing.expect(cut.len < long.len);
    try testing.expect(std.mem.endsWith(u8, cut, cut_marker));
    try testing.expect(pdf.textWidth(st.font, st.size, cut) <= 40);
    // A string that already fits is returned untouched, not copied.
    try testing.expectEqual(long.ptr, (try c.fit(long, st, 400)).ptr);
}

// spec: export-pdf - The light theme resolves the print palette while the default resolves the screen palette
test "the theme option reaches the translated schematic colours" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const block = fixtureBlock();
    const doc = try review.buildReview(a, "acme", &block, &.{}, &.{}, null);
    const dark = try compose(a, &block, "projects/designs", "acme", doc, .{ .generated_at = "T" });
    const light = try compose(a, &block, "projects/designs", "acme", doc, .{
        .generated_at = "T",
        .theme = .print,
    });
    try pdf.validate(light);
    try pdf.validate(dark);
    // Same structure, different ink: the palettes must not produce equal bytes.
    try testing.expectEqual(pageCount(light), pageCount(dark));
    try testing.expect(!std.mem.eql(u8, light, dark));
}

// spec: export-pdf - The default dark theme paints every page with the web background while the print theme leaves pages white
test "the dark page background is painted once per page and never in print" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const block = fixtureBlock();
    const doc = try review.buildReview(a, "acme", &block, &.{}, &.{}, null);
    const dark = try compose(a, &block, "projects/designs", "acme", doc, .{ .generated_at = "T" });
    const light = try compose(a, &block, "projects/designs", "acme", doc, .{
        .generated_at = "T",
        .theme = .print,
    });
    // The writer emits fill colours as three fixed 3-decimal components + `rg`.
    const bg_fill = "0.051 0.067 0.090 rg";
    try testing.expectEqual(pageCount(dark), std.mem.count(u8, dark, bg_fill));
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, light, bg_fill));
}

// spec: export-pdf - The Tj extractor decodes escaped parens, backslashes and octal escapes
test "the text extractor decodes every literal-string escape the writer emits" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = pdf.Doc.init(a, .{});
    defer d.deinit();
    const p = try d.beginPage(200, 100);
    // Parens, a backslash, and a high byte that writeLiteral escapes as octal.
    try p.text(.{ .x = 5, .y = 20 }, "a(b)c\\d\u{00B5}F", .{});
    const strings = try extractTj(a, try d.finish());
    try testing.expectEqual(@as(usize, 1), strings.len);
    try testing.expectEqualStrings("a(b)c\\d\xB5F", strings[0]);
}

/// One part that dissipates a watt into a declared 50 °C/W package — enough
/// for the thermal screen to reach a verdict without any project files.
const thermal_instances = [_]env_mod.Instance{.{
    .ref_des = "U1",
    .component = "acme-mcu",
    .value = "",
    .footprint = "",
    .symbol = "",
    .thermal = .{
        .decl = .{ .theta_ja = 50, .tj_max = 125, .operating_min = -40, .operating_max = 85 },
        .power = .{ .typ = 1.0 },
    },
}};

// spec: export-pdf - The thermal screen reaches the Power & Bring-Up sheet with its verdict sentence, ambient range and per-part row
test "the thermal screen draws on the power sheet with its verdict and row" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var block: DesignBlock = .{
        .name = "Hot Board",
        .instances = &thermal_instances,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const doc = try review.buildReview(a, "hot", &block, &.{}, &.{}, null);
    const bytes = try compose(a, &block, "projects/designs", "hot", doc, .{ .generated_at = "T" });
    try pdf.validate(bytes);

    const page = pageWith(try extractPageTexts(a, bytes), "Thermal") orelse
        return error.ThermalSectionMissing;
    // 1 W into 50 °C/W is a 50 °C rise: 75 °C junction at bench ambient, well
    // inside the derated limit, so the board passes in still air.
    try testing.expect(someTextContains(page, "Passive cooling OK at 25"));
    // The window's cold end is the declared (operating -40 ...); its hot end is
    // the junction-derived 125 - 50, tighter than the declared 85. Asserted on
    // the ASCII head of the line: extractTj hands back the WinAnsi bytes the
    // page actually draws, in which the ellipsis and the degree sign are single
    // bytes rather than their UTF-8 spellings.
    try testing.expect(someTextContains(page, "Board ambient range: -40"));
    try testing.expect(hasText(page, "U1"));
    try testing.expect(hasText(page, "1.000 (declared)"));
    try testing.expect(hasText(page, "75.0"));
    try testing.expect(someTextContains(page, "Coverage: power known for 1 parts"));

    // Every drawn glyph still encodes: the shared sentences are deliberately
    // WinAnsi-safe, so the PDF never falls back to a question mark for them.
    for (try extractTj(a, bytes)) |s| try testing.expect(std.mem.indexOfScalar(u8, s, '?') == null);
}
