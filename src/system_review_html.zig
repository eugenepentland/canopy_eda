//! Deterministic, fully offline HTML dossier for a system review package.
//!
//! This is the third face of one document. `system_review_package.zig` expands
//! every generated region exactly once; the combined Markdown member, the
//! searchable PDF, and this page are then rendered from that same expanded
//! text, so no reader can be shown a different system than another reader.
//!
//! The page is a single file with no external request of any kind: no webfont,
//! no CDN, no remote image, no script. Every rule lives in one inline `<style>`
//! block over system font stacks, so the dossier renders identically from a ZIP
//! extracted onto an air-gapped review workstation.
//!
//! Two kinds of markup reach the page. Document bodies go through
//! `system_review_md.renderHtml`, which is the bounded, sanitising renderer
//! that already refuses raw HTML and remote URLs at parse time. Everything
//! else this module interpolates — identity fields, roles, filenames, titles —
//! is XML-escaped at the point of use. The only exceptions are the two
//! tool-rendered SVG figures (the system-of-boards fragment and each board's
//! block diagram), which this process emits itself from evaluated designs and
//! which carry no script and no `id` that could collide with the page.
//!
//! Rendering is a pure function of its inputs: no clock, no RNG, no hash-map
//! iteration. The timestamp shown is the package's own `generated_at`.

const std = @import("std");
const escape = @import("escape.zig");
const review_md = @import("system_review_md.zig");
const system_review = @import("system_review.zig");
const system_of_boards = @import("diagram/system_of_boards.zig");

const Writer = std.Io.Writer;

/// Ceiling for the rendered page, mirroring the package's other member limits.
pub const max_html_bytes: usize = 64 * 1024 * 1024;

/// One numbered document section: an authored manifest document whose body is
/// the already-expanded, canonical Markdown that the combined member carries.
pub const Section = struct {
    title: []const u8,
    /// Manifest classification, rendered as the section's provenance label.
    classification: []const u8,
    markdown: []const u8,
};

/// One board's evidence block, grouped the way
/// `board_review_snapshot.Snapshot` groups the facts it comes from.
pub const Board = struct {
    identity: Identity,
    review: Review,
    /// True when this board's fabrication gate is blocked.
    fab_blocked: bool,

    /// Manifest and snapshot identity, as shown in the board facts row.
    pub const Identity = struct {
        /// Archive role, which is also this board's `boards/<role>/` directory.
        role: []const u8,
        design: []const u8,
        title: []const u8,
        part_number: []const u8,
        revision: []const u8,
        layout: []const u8,
        generated_at: []const u8,
    };

    /// Board review state and the figure inlined for it.
    pub const Review = struct {
        status: []const u8,
        open_notes: usize,
        /// Standalone block-diagram SVG document, or empty when the design has
        /// nothing to draw — in which case the figure is omitted entirely.
        diagram_svg: []const u8 = "",
        /// True when `boards/<role>/design-notes.md` exists in the archive.
        has_notes: bool = false,
    };
};

/// An active document archived beside the dossier rather than inlined into it.
pub const Supporting = struct {
    title: []const u8,
    /// Archive-relative member path, for example `review/demo/icd.md`.
    path: []const u8,
};

/// Where this page came from and what it is bound to — the deterministic
/// timestamp the whole package shares, the tool build that wrote it, and the
/// two digests printed across the title block.
pub const Provenance = struct {
    generated_at: []const u8,
    build_id: []const u8,
    content_lock: []const u8,
    release_token: []const u8,
};

/// System gate state, exactly as `readiness.json` reports it.
pub const State = struct {
    blocked: bool,
    needs_waiver: bool,
    attested: bool,
};

/// Identity, readiness state, and evidence for one composed dossier.
pub const Options = struct {
    /// Manifest identity and the source of the system-of-boards figure.
    spec: *const system_review.SystemSpec,
    /// Draft mode stamps the hatched non-fabrication band across the masthead.
    draft: bool,
    provenance: Provenance,
    state: State,
    boards: []const Board = &.{},
    supporting: []const Supporting = &.{},
};

/// Allocation, writer, bounded-Markdown, and size failures.
pub const Error = review_md.ParseError || Writer.Error;

/// The loud draft marker. Byte-identical to the combined Markdown's banner so
/// a reviewer grepping either member finds the same string.
pub const draft_marker = "DRAFT — NOT FOR FABRICATION";

const release_marker = "APPROVED RELEASE";

/// What the reader is looking at, in TOC order. Titles are produced by one
/// function used by both the contents rail and the section heading, so the two
/// can never drift apart.
const Node = union(enum) {
    document: usize,
    system_diagram,
    board: usize,
    supporting,
};

/// Compose the complete offline dossier. `sections` are the manifest documents
/// in manifest order, already expanded and canonicalised by the package.
pub fn compose(allocator: std.mem.Allocator, sections: []const Section, opts: Options) Error![]u8 {
    var nodes: std.ArrayList(Node) = .empty;
    defer nodes.deinit(allocator);
    for (sections, 0..) |_, index| try nodes.append(allocator, .{ .document = index });
    if (opts.spec.boards.len > 0) try nodes.append(allocator, .system_diagram);
    for (opts.boards, 0..) |_, index| try nodes.append(allocator, .{ .board = index });
    if (opts.supporting.len > 0) try nodes.append(allocator, .supporting);

    var out: Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n" ++
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>");
    try escape.writeXml(w, opts.spec.title);
    try w.writeAll(" — System Review</title>\n<style>\n");
    try w.writeAll(stylesheet);
    try w.writeAll("\n</style>\n</head>\n<body>\n");

    try writeMasthead(w, opts);
    try w.writeAll("<div class=\"shell\">\n");
    try writeContents(w, sections, opts, nodes.items);
    try w.writeAll("<main>\n");
    for (nodes.items, 0..) |node, index| {
        try writeSection(allocator, w, sections, opts, node, index + 1);
        try ensureSize(&out);
    }
    try w.writeAll("</main>\n</div>\n");
    try writeColophon(w, opts);
    try w.writeAll("</body>\n</html>\n");
    try ensureSize(&out);
    return out.toOwnedSlice();
}

fn ensureSize(out: *Writer.Allocating) Error!void {
    if (out.written().len > max_html_bytes) return error.DocumentTooLarge;
}

fn writeMasthead(w: *Writer, opts: Options) Error!void {
    const spec = opts.spec;
    try w.writeAll("<header class=\"masthead\">\n<div class=\"mh-inner\">\n<p class=\"mh-eyebrow\">" ++
        "<span>netlisp system review package</span><span>·</span><span>");
    try escape.writeXml(w, spec.schema);
    try w.writeAll("</span><span>·</span><span>");
    try w.writeAll(if (opts.draft) "draft" else "release");
    try w.writeAll(" · html dossier</span></p>\n<h1 class=\"mh-title\">");
    try escape.writeXml(w, spec.title);
    try w.writeAll("</h1>\n<p class=\"mh-sub\">Combined system review for ");
    try w.print("{d} board(s) and {d} board-to-board interface(s), rendered from the same expanded document set as the package Markdown and PDF.</p>\n", .{
        spec.boards.len,
        spec.interfaces.len,
    });

    if (opts.draft) {
        try w.writeAll("<div class=\"mh-draft\"><strong>" ++ draft_marker ++ "</strong>" ++
            "<span>Review evidence only. Contains no Gerber, drill, centroid, or board fabrication archive.</span></div>\n");
    } else {
        try w.writeAll("<div class=\"mh-release\"><strong>" ++ release_marker ++ "</strong>" ++
            "<span>Content lock is attested and every board release gate passed.</span></div>\n");
    }

    try w.writeAll("<div class=\"mh-grid\">\n");
    try writeCell(w, "System", spec.name, .plain);
    try writeCell(w, "Part number", spec.part_number, .plain);
    try writeCell(w, "Revision", spec.revision, .plain);
    try writeCell(w, "Generated", opts.provenance.generated_at, .plain);
    try writeBoardsCell(w, spec.boards);
    try writeInterfaceCell(w, spec);
    try writeCell(
        w,
        "Release status",
        if (opts.state.blocked) "BLOCKED" else "READY",
        if (opts.state.blocked) .critical else .plain,
    );
    try writeCell(
        w,
        "Attestation",
        if (opts.state.attested) "attested" else "NOT ATTESTED",
        if (opts.state.attested) .plain else .critical,
    );
    try writeCell(
        w,
        "Waiver acceptance",
        if (opts.state.needs_waiver) "required" else "not required",
        if (opts.state.needs_waiver) .critical else .plain,
    );
    try writeCell(w, "Tool build", opts.provenance.build_id, .plain);
    try writeCell(w, "Content lock · sha-256", opts.provenance.content_lock, .hash);
    try writeCell(w, "Release token · sha-256", opts.provenance.release_token, .hash);
    try w.writeAll("</div>\n</div>\n</header>\n");
}

const CellStyle = enum { plain, hash, critical };

fn writeCell(w: *Writer, key: []const u8, value: []const u8, style: CellStyle) Error!void {
    try w.writeAll(switch (style) {
        .hash => "<div class=\"mh-cell mh-wide\"><span class=\"mh-k\">",
        else => "<div class=\"mh-cell\"><span class=\"mh-k\">",
    });
    try escape.writeXml(w, key);
    try w.writeAll(switch (style) {
        .plain => "</span><span class=\"mh-v\">",
        .hash => "</span><span class=\"mh-v hash\">",
        .critical => "</span><span class=\"mh-v crit\">",
    });
    try escape.writeXml(w, value);
    try w.writeAll("</span></div>\n");
}

fn writeBoardsCell(w: *Writer, boards: []const system_review.BoardMember) Error!void {
    try w.print("<div class=\"mh-cell\"><span class=\"mh-k\">Boards</span><span class=\"mh-v\">{d}", .{boards.len});
    for (boards, 0..) |board, index| {
        try w.writeAll(if (index == 0) " · " else " + ");
        try escape.writeXml(w, board.role);
    }
    try w.writeAll("</span></div>\n");
}

fn writeInterfaceCell(w: *Writer, spec: *const system_review.SystemSpec) Error!void {
    var contacts: usize = 0;
    for (spec.interfaces) |contract| contacts += contract.contact_count;
    try w.print(
        "<div class=\"mh-cell\"><span class=\"mh-k\">Interfaces</span><span class=\"mh-v\">{d} · {d} contacts</span></div>\n",
        .{ spec.interfaces.len, contacts },
    );
}

fn writeContents(
    w: *Writer,
    sections: []const Section,
    opts: Options,
    nodes: []const Node,
) Error!void {
    try w.writeAll("<nav class=\"rail\" aria-label=\"Document contents\">\n<p class=\"rail-h\">Contents</p>\n<ol class=\"toc\">\n");
    for (nodes, 0..) |node, index| {
        try w.print("<li><a href=\"#s{d}\"><span class=\"n\">{d}</span><span>", .{ index + 1, index + 1 });
        try writeNodeTitle(w, sections, opts, node);
        try w.writeAll("</span></a></li>\n");
    }
    try w.writeAll("</ol>\n</nav>\n");
}

fn writeNodeTitle(w: *Writer, sections: []const Section, opts: Options, node: Node) Error!void {
    switch (node) {
        .document => |index| try escape.writeXml(w, sections[index].title),
        .system_diagram => try w.writeAll("System diagram"),
        .board => |index| {
            try w.writeAll("Board · ");
            try escape.writeXml(w, opts.boards[index].identity.role);
        },
        .supporting => try w.writeAll("Supporting documents"),
    }
}

fn writeSection(
    allocator: std.mem.Allocator,
    w: *Writer,
    sections: []const Section,
    opts: Options,
    node: Node,
    number: usize,
) Error!void {
    try w.print("<section class=\"sec\" id=\"s{d}\">\n<div class=\"sec-head\"><span class=\"sec-n\">{d}</span><h2>", .{ number, number });
    try writeNodeTitle(w, sections, opts, node);
    try w.writeAll("</h2>");
    switch (node) {
        .document => |index| {
            try w.writeAll("<span class=\"tag\">");
            try escape.writeXml(w, sections[index].classification);
            try w.writeAll("</span>");
        },
        .system_diagram, .board, .supporting => try w.writeAll("<span class=\"tag tag-gen\">generated</span>"),
    }
    try w.writeAll("</div>\n");

    switch (node) {
        .document => |index| try writeMarkdownBody(allocator, w, sections[index].markdown),
        .system_diagram => try writeSystemDiagram(allocator, w, opts),
        .board => |index| try writeBoard(w, opts.boards[index]),
        .supporting => try writeSupporting(w, opts.supporting),
    }
    try w.writeAll("</section>\n");
}

fn writeMarkdownBody(allocator: std.mem.Allocator, w: *Writer, markdown: []const u8) Error!void {
    var options: review_md.Options = .{};
    options.limits.source_bytes = max_html_bytes;
    var parsed = try review_md.parse(allocator, markdown, options);
    defer parsed.deinit();
    try w.writeAll("<div class=\"prose\">\n");
    try review_md.renderHtml(w, &parsed);
    try w.writeAll("</div>\n");
}

fn writeSystemDiagram(allocator: std.mem.Allocator, w: *Writer, opts: Options) Error!void {
    try w.writeAll("<p class=\"lede\">Boards as blocks, each board-to-board contract as a labeled spine. " ++
        "Contacts are grouped into signal lanes; the ground lane collapses to a count.</p>\n" ++
        "<figure class=\"fig\">\n");
    // Tool-rendered in this process from the parsed manifest: static, scriptless,
    // and free of any `id` that could collide with the surrounding page.
    try system_of_boards.renderSystemSvg(allocator, opts.spec, .{}, w);
    try w.writeAll("\n<figcaption>System-of-boards block diagram · also archived per board under <code>boards/</code>.</figcaption>\n</figure>\n");
}

fn writeBoard(w: *Writer, board: Board) Error!void {
    try w.writeAll("<dl class=\"facts\">\n");
    const identity = board.identity;
    try writeFact(w, "Design", identity.design);
    try writeFact(w, "Title", identity.title);
    try writeFact(w, "Part number", identity.part_number);
    try writeFact(w, "Revision", identity.revision);
    try writeFact(w, "Layout", identity.layout);
    try writeFact(w, "Review", board.review.status);
    try w.print("<div class=\"fact\"><dt>Open notes</dt><dd>{d}</dd></div>\n", .{board.review.open_notes});
    try writeFact(w, "Fabrication gate", if (board.fab_blocked) "BLOCKED" else "ready");
    try writeFact(w, "Evidence generated", identity.generated_at);
    try w.writeAll("</dl>\n");

    if (board.review.diagram_svg.len > 0) {
        try w.writeAll("<figure class=\"fig dark\">\n");
        // Same provenance argument as the archived `boards/<role>/diagram.svg`
        // member: these bytes were written by the diagram renderer inside this
        // process, and its own `<style>` block is `.dg-*`-scoped throughout.
        try w.writeAll(board.review.diagram_svg);
        try w.writeAll("\n<figcaption>Block diagram · <code>");
        try writeMemberPath(w, identity.role, "diagram.svg");
        try w.writeAll("</code></figcaption>\n</figure>\n");
    }

    try w.writeAll("<h3>Archived evidence</h3>\n<ul class=\"members\">\n");
    const always = [_]struct { file: []const u8, label: []const u8 }{
        .{ .file = "review.md", .label = "Board engineering review (Markdown)" },
        .{ .file = "review.pdf", .label = "Board engineering review (PDF)" },
        .{ .file = "review.json", .label = "Board review data" },
        .{ .file = "bom.csv", .label = "Bill of materials" },
        .{ .file = "pcb.png", .label = "Layout render" },
        .{ .file = "fab-readiness.json", .label = "Fabrication readiness report" },
    };
    for (always) |member| try writeMember(w, identity.role, member.file, member.label);
    if (board.review.diagram_svg.len > 0)
        try writeMember(w, identity.role, "diagram.svg", "Block diagram");
    if (board.review.has_notes)
        try writeMember(w, identity.role, "design-notes.md", "Design notes sidecar");
    try w.writeAll("</ul>\n");
}

fn writeFact(w: *Writer, key: []const u8, value: []const u8) Error!void {
    try w.writeAll("<div class=\"fact\"><dt>");
    try escape.writeXml(w, key);
    try w.writeAll("</dt><dd>");
    try escape.writeXml(w, value);
    try w.writeAll("</dd></div>\n");
}

/// `boards/<role>/<file>` reached from this page's home in `review/`.
fn writeMemberPath(w: *Writer, role: []const u8, file: []const u8) Error!void {
    try w.writeAll("../boards/");
    try escape.writeXml(w, role);
    try w.writeByte('/');
    try escape.writeXml(w, file);
}

fn writeMember(w: *Writer, role: []const u8, file: []const u8, label: []const u8) Error!void {
    try w.writeAll("<li><a href=\"");
    try writeMemberPath(w, role, file);
    try w.writeAll("\"><code>");
    try writeMemberPath(w, role, file);
    try w.writeAll("</code></a><span>");
    try escape.writeXml(w, label);
    try w.writeAll("</span></li>\n");
}

fn writeSupporting(w: *Writer, supporting: []const Supporting) Error!void {
    try w.writeAll("<p class=\"lede\">Active documents archived beside this dossier rather than inlined into it.</p>\n<ul class=\"members\">\n");
    for (supporting) |document| {
        // Archive-relative, made relative to this page's home in `review/`.
        try w.writeAll("<li><a href=\"../");
        try escape.writeXml(w, document.path);
        try w.writeAll("\"><code>../");
        try escape.writeXml(w, document.path);
        try w.writeAll("</code></a><span>");
        try escape.writeXml(w, document.title);
        try w.writeAll("</span></li>\n");
    }
    try w.writeAll("</ul>\n");
}

fn writeColophon(w: *Writer, opts: Options) Error!void {
    try w.writeAll("<footer class=\"colophon\"><span>");
    try escape.writeXml(w, opts.spec.part_number);
    try w.writeAll(" · Rev ");
    try escape.writeXml(w, opts.spec.revision);
    try w.writeAll("</span><span>");
    try escape.writeXml(w, opts.provenance.generated_at);
    try w.writeAll("</span><span>");
    try escape.writeXml(w, opts.provenance.build_id);
    try w.writeAll("</span></footer>\n");
}

/// One inline stylesheet, no webfont, no remote asset. A single committed dark
/// palette: the tool-rendered figures paint their own `#0d1117` ground, and a
/// light page around a dark figure reads as a pasted screenshot rather than
/// part of the document.
const stylesheet =
    \\:root{
    \\color-scheme:dark;
    \\--paper:#0c1012;--sheet:#141a1c;--sheet-2:#1a2124;
    \\--ink:#e8eef0;--ink-2:#9fb0b6;--ink-3:#77878e;
    \\--rule:#242d31;--rule-2:#384549;
    \\--band:#05090a;--band-ink:#e8eef0;--band-ink-2:#8a9aa0;--band-rule:#222c2f;
    \\--accent:#4fbfc4;--accent-soft:#11292c;--crit:#f07070;--panel:#0d1117;
    \\--sans:ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
    \\--mono:ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,"Liberation Mono",monospace;
    \\}
    \\*{box-sizing:border-box;}
    \\html{scroll-behavior:smooth;}
    \\body{margin:0;background:var(--paper);color:var(--ink);font-family:var(--sans);
    \\font-size:15px;line-height:1.55;overflow-x:hidden;-webkit-text-size-adjust:100%;}
    \\a{color:var(--accent);text-underline-offset:2px;}
    \\a:focus-visible{outline:2px solid var(--accent);outline-offset:2px;}
    \\code,kbd{font-family:var(--mono);font-size:.88em;overflow-wrap:anywhere;}
    \\code{background:var(--sheet-2);border:1px solid var(--rule);border-radius:2px;padding:.04em .32em;}
    \\.masthead{background:var(--band);color:var(--band-ink);border-bottom:3px solid var(--band-rule);}
    \\.mh-inner{max-width:1500px;margin:0 auto;padding:30px 32px 0;}
    \\.mh-eyebrow{font-family:var(--mono);font-size:11px;letter-spacing:.16em;text-transform:uppercase;
    \\color:var(--band-ink-2);display:flex;flex-wrap:wrap;gap:6px 12px;margin:0;}
    \\.mh-title{font-size:clamp(28px,5vw,54px);font-weight:700;letter-spacing:-.022em;line-height:1.03;
    \\margin:14px 0 6px;text-wrap:balance;}
    \\.mh-sub{font-size:clamp(14px,1.5vw,17px);color:var(--band-ink-2);max-width:66ch;margin:0 0 22px;}
    \\.mh-draft,.mh-release{display:flex;align-items:center;flex-wrap:wrap;gap:8px 16px;
    \\margin:0 -32px;padding:11px 32px;border-top:1px solid var(--band-rule);border-bottom:1px solid var(--band-rule);}
    \\.mh-draft{background-image:repeating-linear-gradient(-45deg,rgba(208,59,59,.22) 0 10px,transparent 10px 22px);}
    \\.mh-release{background-image:repeating-linear-gradient(-45deg,rgba(76,201,76,.14) 0 10px,transparent 10px 22px);}
    \\.mh-draft strong,.mh-release strong{font-family:var(--mono);font-size:12px;letter-spacing:.18em;
    \\font-weight:600;white-space:nowrap;}
    \\.mh-draft strong{color:#f5a3a3;}
    \\.mh-release strong{color:#9fe0a4;}
    \\.mh-draft span,.mh-release span{font-family:var(--mono);font-size:11px;color:var(--band-ink-2);}
    \\.mh-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(168px,1fr));
    \\border-left:1px solid var(--band-rule);margin:0 -32px;}
    \\.mh-cell{padding:12px 16px 15px;border-right:1px solid var(--band-rule);
    \\border-bottom:1px solid var(--band-rule);min-width:0;}
    \\.mh-wide{grid-column:span 2;}
    \\.mh-k{font-family:var(--mono);font-size:9.5px;letter-spacing:.17em;text-transform:uppercase;
    \\color:var(--band-ink-2);display:block;margin-bottom:5px;}
    \\.mh-v{font-family:var(--mono);font-size:13px;font-weight:500;color:var(--band-ink);overflow-wrap:anywhere;}
    \\.mh-v.hash{font-size:10.5px;line-height:1.35;color:var(--band-ink-2);}
    \\.mh-v.crit{color:var(--crit);font-weight:600;letter-spacing:.05em;}
    \\.shell{max-width:1500px;margin:0 auto;display:grid;grid-template-columns:264px minmax(0,1fr);align-items:start;}
    \\.rail{position:sticky;top:0;max-height:100vh;overflow-y:auto;padding:28px 22px 40px 32px;
    \\border-right:1px solid var(--rule);}
    \\.rail-h{font-family:var(--mono);font-size:10px;letter-spacing:.17em;text-transform:uppercase;
    \\color:var(--ink-3);margin:0 0 12px;padding-bottom:8px;border-bottom:1px solid var(--rule);}
    \\.toc{list-style:none;margin:0;padding:0;}
    \\.toc a{display:grid;grid-template-columns:24px 1fr;gap:8px;padding:5px 8px 5px 4px;
    \\color:var(--ink-2);text-decoration:none;font-size:13.5px;line-height:1.3;border-left:2px solid transparent;}
    \\.toc a:hover{background:var(--sheet-2);color:var(--ink);border-left-color:var(--accent);}
    \\.toc .n{font-family:var(--mono);font-size:11px;color:var(--ink-3);font-variant-numeric:tabular-nums;}
    \\main{padding:0 32px 80px;min-width:0;}
    \\.sec{padding:40px 0 8px;border-top:1px solid var(--rule-2);scroll-margin-top:12px;min-width:0;}
    \\.sec:first-of-type{border-top:none;padding-top:32px;}
    \\.sec-head{display:flex;flex-wrap:wrap;align-items:baseline;gap:10px 14px;margin-bottom:8px;}
    \\.sec-n{font-family:var(--mono);font-size:12px;font-weight:600;letter-spacing:.1em;color:var(--accent);
    \\font-variant-numeric:tabular-nums;}
    \\.sec h2{font-size:clamp(21px,2.3vw,28px);font-weight:600;letter-spacing:-.018em;margin:0;text-wrap:balance;}
    \\.tag{font-family:var(--mono);font-size:9.5px;font-weight:600;letter-spacing:.12em;text-transform:uppercase;
    \\padding:3px 7px 2px;border-radius:2px;border:1px solid var(--rule-2);color:var(--ink-2);background:var(--sheet-2);}
    \\.tag-gen{border-style:dashed;color:var(--accent);border-color:var(--accent);background:var(--accent-soft);}
    \\.lede{color:var(--ink-2);max-width:72ch;margin:10px 0 18px;}
    \\.prose{min-width:0;}
    \\.prose h1{font-size:23px;font-weight:600;margin:26px 0 10px;letter-spacing:-.012em;}
    \\.prose h2{font-size:19px;font-weight:600;margin:26px 0 10px;padding-bottom:6px;border-bottom:1px solid var(--rule);}
    \\.prose h3{font-size:15.5px;font-weight:600;margin:22px 0 8px;}
    \\.prose h4,.prose h5,.prose h6{font-family:var(--mono);font-size:11px;letter-spacing:.13em;
    \\text-transform:uppercase;color:var(--ink-3);margin:20px 0 8px;font-weight:500;}
    \\.prose p{margin:0 0 13px;max-width:74ch;color:var(--ink-2);}
    \\.prose strong{color:var(--ink);font-weight:600;}
    \\.prose ul,.prose ol{margin:0 0 14px;padding-left:22px;color:var(--ink-2);max-width:74ch;}
    \\.prose li{margin:0 0 5px;}
    \\.prose li.task{list-style:none;margin-left:-22px;}
    \\.prose li.unchecked{color:var(--ink);}
    \\.prose input[type=checkbox]{accent-color:var(--accent);margin-right:6px;}
    \\pre{background:var(--sheet);border:1px solid var(--rule);border-radius:3px;padding:12px 14px;
    \\overflow-x:auto;margin:0 0 14px;max-width:100%;}
    \\pre code{background:none;border:none;padding:0;font-size:12.5px;line-height:1.5;white-space:pre;}
    \\table{display:block;width:max-content;max-width:100%;overflow-x:auto;border-collapse:collapse;
    \\border:1px solid var(--rule);border-radius:2px;background:var(--sheet);margin:12px 0 16px;font-size:13.5px;}
    \\th,td{border-bottom:1px solid var(--rule);padding:7px 12px;text-align:left;vertical-align:top;}
    \\th{font-family:var(--mono);font-size:10.5px;letter-spacing:.09em;text-transform:uppercase;
    \\color:var(--ink-3);background:var(--sheet-2);white-space:nowrap;}
    \\td{color:var(--ink-2);}
    \\tbody tr:last-child td{border-bottom:none;}
    \\.align-right{text-align:right;}
    \\.align-center{text-align:center;}
    \\.netlisp-directive{display:none;}
    \\.fig{margin:14px 0 18px;padding:0;overflow-x:auto;max-width:100%;}
    \\.fig.dark{background:var(--panel);border:1px solid #21262d;border-radius:8px;padding:10px;}
    \\.fig svg{display:block;max-width:100%;height:auto;}
    \\.fig figcaption{font-family:var(--mono);font-size:11px;color:var(--ink-3);margin-top:8px;}
    \\.facts{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:0;margin:12px 0 16px;
    \\border:1px solid var(--rule);border-radius:2px;background:var(--sheet);}
    \\.fact{padding:10px 14px 12px;border-right:1px solid var(--rule);border-bottom:1px solid var(--rule);min-width:0;}
    \\.fact dt{font-family:var(--mono);font-size:9.5px;letter-spacing:.15em;text-transform:uppercase;
    \\color:var(--ink-3);margin-bottom:4px;}
    \\.fact dd{margin:0;font-family:var(--mono);font-size:13px;color:var(--ink);overflow-wrap:anywhere;}
    \\.sec h3{font-family:var(--mono);font-size:11px;letter-spacing:.13em;text-transform:uppercase;
    \\color:var(--ink-3);margin:22px 0 8px;font-weight:500;}
    \\.members{list-style:none;margin:0;padding:0;display:grid;gap:1px;background:var(--rule);
    \\border:1px solid var(--rule);border-radius:2px;}
    \\.members li{display:flex;flex-wrap:wrap;gap:4px 16px;justify-content:space-between;
    \\background:var(--sheet);padding:8px 14px;font-size:13px;}
    \\.members span{color:var(--ink-3);}
    \\.colophon{max-width:1500px;margin:0 auto;padding:18px 32px 40px;display:flex;flex-wrap:wrap;
    \\gap:6px 24px;border-top:1px solid var(--rule);font-family:var(--mono);font-size:10.5px;color:var(--ink-3);}
    \\@media(max-width:900px){
    \\.shell{grid-template-columns:minmax(0,1fr);}
    \\.rail{position:static;max-height:none;border-right:none;border-bottom:1px solid var(--rule);padding:22px 24px;}
    \\main{padding:0 24px 60px;}
    \\.mh-inner{padding:24px 24px 0;}
    \\.mh-grid,.mh-draft,.mh-release{margin:0 -24px;}
    \\.mh-draft,.mh-release{padding:11px 24px;}
    \\.mh-wide{grid-column:span 1;}
    \\}
    \\@media print{
    \\.rail{display:none;}
    \\.shell{grid-template-columns:minmax(0,1fr);}
    \\}
;

const testing = std.testing;

fn testSpec(allocator: std.mem.Allocator, source: []const u8) !std.json.Parsed(system_review.SystemSpec) {
    return std.json.parseFromSlice(system_review.SystemSpec, allocator, source, .{});
}

const one_board_manifest =
    \\{"schema":"netlisp-system-review-v1","name":"demo","title":"Demo System","part_number":"SYS-1","revision":"A","boards":[{"name":"one","role":"main","source":"src/one.sexp","part_number":"ONE","revision":"A"}]}
;

// spec: system-review - the offline HTML dossier is one self-contained file with no external request and no script
test "system review HTML requests nothing off the machine" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parsed = try testSpec(allocator, one_board_manifest);
    defer parsed.deinit();
    const sections = [_]Section{.{
        .title = "System overview",
        .classification = "design",
        .markdown = "# Overview\n\n| Rail | Volts |\n| --- | ---: |\n| V_12V | 12 |\n",
    }};
    const html = try compose(allocator, &sections, .{
        .spec = &parsed.value,
        .draft = true,
        .provenance = .{
            .generated_at = "2026-08-30T00:00:00Z",
            .build_id = "test-build",
            .content_lock = "lock",
            .release_token = "token",
        },
        .state = .{ .blocked = true, .needs_waiver = false, .attested = false },
    });
    try testing.expect(std.mem.startsWith(u8, html, "<!DOCTYPE html>"));
    try testing.expect(std.mem.indexOf(u8, html, "</html>") != null);
    // No script, and no construct that could fetch anything. The only absolute
    // URL anywhere on the page is the SVG namespace, which is an identifier and
    // is never dereferenced.
    try testing.expect(std.mem.indexOf(u8, html, "<script") == null);
    try testing.expect(std.mem.indexOf(u8, html, "@import") == null);
    try testing.expect(std.mem.indexOf(u8, html, "url(") == null);
    try testing.expect(std.mem.indexOf(u8, html, "<link") == null);
    try testing.expect(std.mem.indexOf(u8, html, "src=\"http") == null);
    try testing.expect(std.mem.indexOf(u8, html, "href=\"http") == null);
    try testing.expect(std.mem.indexOf(u8, html, "//fonts.") == null);
    // The document body went through the sanitising Markdown renderer.
    try testing.expect(std.mem.indexOf(u8, html, "<h1>Overview</h1>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<td class=\"align-right\">12</td>") != null);
}

// spec: system-review - the HTML dossier carries the draft marker only in draft mode and numbers one section per manifest document
test "system review HTML marks draft state and numbers every section" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parsed = try testSpec(allocator, one_board_manifest);
    defer parsed.deinit();
    const sections = [_]Section{
        .{ .title = "System overview", .classification = "design", .markdown = "Overview text.\n" },
        .{ .title = "Interface control", .classification = "design", .markdown = "Contract text.\n" },
    };
    var options: Options = .{
        .spec = &parsed.value,
        .draft = true,
        .provenance = .{
            .generated_at = "2026-08-30T00:00:00Z",
            .build_id = "test-build",
            .content_lock = "lock",
            .release_token = "token",
        },
        .state = .{ .blocked = true, .needs_waiver = false, .attested = false },
    };
    const draft_html = try compose(allocator, &sections, options);
    try testing.expect(std.mem.indexOf(u8, draft_html, draft_marker) != null);
    try testing.expect(std.mem.indexOf(u8, draft_html, "System overview") != null);
    try testing.expect(std.mem.indexOf(u8, draft_html, "Interface control") != null);
    // Two documents, one system diagram, no boards, no supporting list.
    try testing.expect(std.mem.indexOf(u8, draft_html, "id=\"s3\"") != null);
    try testing.expect(std.mem.indexOf(u8, draft_html, "id=\"s4\"") == null);

    options.draft = false;
    options.state = .{ .blocked = false, .needs_waiver = false, .attested = true };
    const release_html = try compose(allocator, &sections, options);
    try testing.expect(std.mem.indexOf(u8, release_html, draft_marker) == null);
    try testing.expect(std.mem.indexOf(u8, release_html, release_marker) != null);
}

// spec: system-review - every identity string interpolated into the HTML dossier is escaped rather than emitted as markup
test "system review HTML escapes hostile identity strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parsed = try testSpec(allocator,
        \\{"schema":"netlisp-system-review-v1","name":"a&b","title":"<script>alert(1)</script>","part_number":"P<1","revision":"A\"B","boards":[{"name":"one","role":"m<n","source":"src/one.sexp","part_number":"ONE","revision":"A"}]}
    );
    defer parsed.deinit();
    const sections = [_]Section{.{
        .title = "<b>title</b>",
        .classification = "design & review",
        .markdown = "Body.\n",
    }};
    const boards = [_]Board{.{
        .identity = .{
            .role = "m<n",
            .design = "one&two",
            .title = "One",
            .part_number = "ONE",
            .revision = "A",
            .layout = "layout-a",
            .generated_at = "2026-08-30T00:00:00Z",
        },
        .review = .{ .status = "pass", .open_notes = 0 },
        .fab_blocked = false,
    }};
    const html = try compose(allocator, &sections, .{
        .spec = &parsed.value,
        .draft = true,
        .provenance = .{
            .generated_at = "2026-08-30T00:00:00Z",
            .build_id = "test-build",
            .content_lock = "lock",
            .release_token = "token",
        },
        .state = .{ .blocked = true, .needs_waiver = false, .attested = false },
        .boards = &boards,
    });
    try testing.expect(std.mem.indexOf(u8, html, "<script") == null);
    try testing.expect(std.mem.indexOf(u8, html, "&lt;script&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, html, "a&amp;b") != null);
    try testing.expect(std.mem.indexOf(u8, html, "&lt;b&gt;title&lt;/b&gt;") != null);
    // Escaped inside the href as well as the visible member path.
    try testing.expect(std.mem.indexOf(u8, html, "../boards/m&lt;n/bom.csv") != null);
}

// spec: system-review - the HTML dossier inlines each board's block diagram and omits the figure when the design has none
test "system review HTML inlines a board diagram only when one exists" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parsed = try testSpec(allocator, one_board_manifest);
    defer parsed.deinit();
    const drawn = "<svg viewBox=\"0 0 10 10\" class=\"dg-svg\" xmlns=\"http://www.w3.org/2000/svg\"></svg>";
    const base: Board = .{
        .identity = .{
            .role = "main",
            .design = "one",
            .title = "One",
            .part_number = "ONE",
            .revision = "A",
            .layout = "layout-a",
            .generated_at = "2026-08-30T00:00:00Z",
        },
        .review = .{ .status = "pass", .open_notes = 0, .diagram_svg = drawn },
        .fab_blocked = false,
    };
    var undrawn = base;
    undrawn.review.diagram_svg = "";
    const drawn_boards = [_]Board{base};
    const undrawn_boards = [_]Board{undrawn};
    var options: Options = .{
        .spec = &parsed.value,
        .draft = true,
        .provenance = .{
            .generated_at = "2026-08-30T00:00:00Z",
            .build_id = "test-build",
            .content_lock = "lock",
            .release_token = "token",
        },
        .state = .{ .blocked = true, .needs_waiver = false, .attested = false },
        .boards = &drawn_boards,
    };
    const with_diagram = try compose(allocator, &[_]Section{}, options);
    try testing.expect(std.mem.indexOf(u8, with_diagram, drawn) != null);
    try testing.expect(std.mem.indexOf(u8, with_diagram, "class=\"fig dark\"") != null);
    // The archived sibling is listed only when the figure exists.
    try testing.expect(std.mem.indexOf(u8, with_diagram, "../boards/main/diagram.svg") != null);
    // The system-of-boards figure is drawn from the manifest itself.
    try testing.expect(std.mem.indexOf(u8, with_diagram, "sob-wrap") != null);

    options.boards = &undrawn_boards;
    const without = try compose(allocator, &[_]Section{}, options);
    try testing.expect(std.mem.indexOf(u8, without, "class=\"fig dark\"") == null);
    try testing.expect(std.mem.indexOf(u8, without, "../boards/main/diagram.svg") == null);
    // Every other evidence link survives, so the omission is targeted.
    try testing.expect(std.mem.indexOf(u8, without, "../boards/main/review.md") != null);
}

// spec: system-review - the HTML dossier is a pure function of its inputs and renders byte-identically on repeat
test "system review HTML repeats byte for byte" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parsed = try testSpec(allocator, one_board_manifest);
    defer parsed.deinit();
    const sections = [_]Section{.{ .title = "Overview", .classification = "design", .markdown = "Text.\n" }};
    const supporting = [_]Supporting{.{ .title = "ICD", .path = "review/demo/icd.md" }};
    const options: Options = .{
        .spec = &parsed.value,
        .draft = true,
        .provenance = .{
            .generated_at = "2026-08-30T00:00:00Z",
            .build_id = "test-build",
            .content_lock = "lock",
            .release_token = "token",
        },
        .state = .{ .blocked = true, .needs_waiver = true, .attested = false },
        .supporting = &supporting,
    };
    const first = try compose(allocator, &sections, options);
    const second = try compose(allocator, &sections, options);
    try testing.expectEqualStrings(first, second);
    try testing.expect(std.mem.indexOf(u8, first, "../review/demo/icd.md") != null);
}
