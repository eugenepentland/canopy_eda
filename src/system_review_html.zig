//! Deterministic, fully offline HTML dossier for a system review package.
//!
//! This is the third face of one document. `system_review_package.zig` expands
//! every generated region exactly once; the combined Markdown member, the
//! searchable PDF, and this page are then rendered from that same expanded
//! text, so no reader can be shown a different system than another reader.
//!
//! The page is a single file with no external request of any kind: no webfont,
//! no CDN and no remote image. The only scripts are the inlined read-only
//! Assembly board documents and the small shell that selects a face and installs
//! cached model sprites, so the dossier works from an air-gapped extracted ZIP.
//!
//! Two kinds of markup reach the page. Document bodies go through
//! `system_review_md.renderHtml`, which is the bounded, sanitising renderer
//! that already refuses raw HTML and remote URLs at parse time. Everything
//! else this module interpolates — identity fields, roles, filenames, titles —
//! is XML-escaped at the point of use. The only exceptions are the two
//! tool-rendered SVG figures (the system-of-boards fragment and each board's
//! block diagram), which this process emits itself from evaluated designs and
//! which carry no script and no `id` that could collide with the page. The
//! physical gallery is likewise tool-rendered here: PNG bytes become data URLs
//! and cached component pictures are placed in numeric, generated SVG shells.
//!
//! Rendering is a pure function of its inputs: no clock, no RNG, no hash-map
//! iteration. The timestamp shown is the package's own `generated_at`.

const std = @import("std");
const escape = @import("escape.zig");
const json_writer = @import("json_writer.zig");
const review_md = @import("system_review_md.zig");
const system_review = @import("system_review.zig");
const system_of_boards = @import("diagram/system_of_boards.zig");

const Writer = std.Io.Writer;

/// Ceiling for the rendered page: expanded documents, inline board renders,
/// cached component-model sprites, escaping, figures, and page chrome.
pub const max_html_bytes: usize = 128 * 1024 * 1024;

/// One numbered document section: an authored manifest document whose body is
/// the already-expanded, canonical Markdown that the combined member carries.
pub const Section = struct {
    title: []const u8,
    /// Manifest classification, rendered as the section's provenance label.
    classification: []const u8,
    markdown: []const u8,
    /// Checklist counts from the package's bounded document inspection.
    checklist: system_review.ChecklistSummary = .{},
};

/// Fabrication decision for one board, including the release-significant
/// middle state that requires an explicit waiver.
const FabState = enum { ready, waiver, blocked };

/// One board's evidence block, grouped the way
/// `board_review_snapshot.Snapshot` groups the facts it comes from.
pub const Board = struct {
    identity: Identity,
    review: Review,
    fabrication: FabState,
    visual: Visual = .{},

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

    /// Fully inline Assembly viewer document and its cached model pictures.
    pub const Visual = struct {
        board_html: []const u8 = "",
        sprites: []const Sprite = &.{},

        /// One reusable transparent picture of a top-down component model.
        pub const Sprite = struct {
            footprint: []const u8,
            x: f64,
            y: f64,
            w: f64,
            h: f64,
            png: []const u8,
        };
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

/// Individual release gates copied from the authoritative readiness analysis.
const Gates = struct {
    identity_ok: bool,
    interface_ok: bool,
    board_review_ok: bool,
    fab_ok: bool,
    checklists_ok: bool,
};

/// Whether the analyzed inputs need no waiver, still need explicit
/// acceptance, or were packaged with that acceptance recorded.
const WaiverState = enum { none, required, accepted };

/// Aggregate release decision plus the individual evidence gates exactly as
/// `readiness.json` reports them.
pub const State = struct {
    blocked: bool,
    waiver: WaiverState,
    attested: bool,
    gates: Gates,
};

/// Identity, readiness state, and evidence for one composed dossier.
pub const Options = struct {
    /// Manifest identity and the source of the system-of-boards figure.
    spec: *const system_review.SystemSpec,
    /// Draft mode stamps the hatched non-fabrication band across the masthead.
    draft: bool,
    provenance: Provenance,
    state: State,
    /// Aggregate counts from every inspected active checklist, including
    /// supporting documents that are not inlined below.
    checklist: system_review.ChecklistSummary,
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

    try writeMasthead(w, sections, opts);
    try w.writeAll("<div class=\"workspace\">\n");
    try writeSectionIndex(w, sections, opts, nodes.items);
    try w.writeAll("<main class=\"document\" id=\"review-document\">\n");
    try writeBoardGallery(allocator, w, opts);
    try writeExecutiveSummary(w, sections, opts);
    try w.print("<section class=\"evidence\" id=\"review-evidence\" aria-labelledby=\"evidence-title\">\n" ++
        "<div class=\"evidence-head\"><div><p class=\"kicker\">Complete evidence record</p>" ++
        "<h2 id=\"evidence-title\">Review sections</h2><p>One continuous engineering record, with every section indexed at left.</p>" ++
        "</div><span class=\"evidence-count\">{d} sections</span></div>\n", .{nodes.items.len});
    for (nodes.items, 0..) |node, index| {
        try writeLinearSection(allocator, w, sections, opts, node, index + 1);
        try ensureSize(&out);
    }
    try w.writeAll("</section>\n</main>\n</div>\n");
    try writeColophon(w, opts);
    if (hasBoardViewer(opts.boards)) try writeBoardViewerScript(w);
    try w.writeAll("</body>\n</html>\n");
    try ensureSize(&out);
    return out.toOwnedSlice();
}

fn ensureSize(out: *Writer.Allocating) Error!void {
    if (out.written().len > max_html_bytes) return error.DocumentTooLarge;
}

fn hasBoardViewer(boards: []const Board) bool {
    for (boards) |board| if (board.visual.board_html.len > 0) return true;
    return false;
}

const ReleaseDecision = enum { blocked, waiver_required, waiver_accepted, ready };

fn releaseDecision(state: State) ReleaseDecision {
    if (state.blocked) return .blocked;
    return switch (state.waiver) {
        .required => .waiver_required,
        .accepted => .waiver_accepted,
        .none => .ready,
    };
}

fn decisionClass(decision: ReleaseDecision) []const u8 {
    return switch (decision) {
        .blocked => "is-blocked",
        .waiver_required, .waiver_accepted => "is-waiver",
        .ready => "is-ready",
    };
}

fn decisionHeadline(decision: ReleaseDecision) []const u8 {
    return switch (decision) {
        .blocked => "BLOCKED",
        .waiver_required => "WAIVER REQUIRED",
        .waiver_accepted => "APPROVED WITH WAIVER",
        .ready => "READY",
    };
}

fn decisionPill(decision: ReleaseDecision) []const u8 {
    return switch (decision) {
        .blocked => "Action required",
        .waiver_required => "Waiver required",
        .waiver_accepted => "Waiver accepted",
        .ready => "Release ready",
    };
}

fn decisionTone(decision: ReleaseDecision) Tone {
    return switch (decision) {
        .blocked => .bad,
        .waiver_required, .waiver_accepted => .warn,
        .ready => .good,
    };
}

fn writeMasthead(w: *Writer, sections: []const Section, opts: Options) Error!void {
    const spec = opts.spec;
    const passed = passingGateCount(opts.state);
    const decision = releaseDecision(opts.state);
    const included_documents = sections.len + opts.supporting.len;
    try w.writeAll("<a class=\"skip-link\" href=\"#executive-summary\">Skip to executive summary</a>\n" ++
        "<header class=\"masthead\">\n<div class=\"mh-inner\">\n<div class=\"mh-topline\">" ++
        "<p class=\"mh-eyebrow\"><span>netlisp system review</span><span>·</span><span>");
    try escape.writeXml(w, spec.schema);
    try w.writeAll("</span></p><span class=\"mode-pill\">");
    try w.writeAll(if (opts.draft) "Draft dossier" else "Approved release");
    try w.writeAll("</span></div>\n<div class=\"mh-lead\"><div class=\"mh-copy\"><h1 class=\"mh-title\">");
    try escape.writeXml(w, spec.title);
    try w.writeAll("</h1>\n<p class=\"mh-sub\">Decision-focused system review with the complete engineering record available below.</p>\n" ++
        "<div class=\"mh-identity\"><span><b>System</b>");
    try escape.writeXml(w, spec.name);
    try w.writeAll("</span><span><b>Part</b>");
    try escape.writeXml(w, spec.part_number);
    try w.writeAll("</span><span><b>Revision</b>");
    try escape.writeXml(w, spec.revision);
    try w.print("</span><span><b>Scope</b>{d} boards · {d} interface{s}</span><span><b>Documents</b>{d} included</span></div>" ++
        "</div><div class=\"mh-status {s}\"><span>Release readiness</span><strong>{s}</strong>" ++
        "<small>{d} of 6 gates clear</small></div></div>\n", .{
        spec.boards.len,
        spec.interfaces.len,
        if (spec.interfaces.len == 1) "" else "s",
        included_documents,
        decisionClass(decision),
        decisionHeadline(decision),
        passed,
    });

    if (opts.draft) {
        try w.writeAll("<div class=\"mh-notice is-draft\"><strong>" ++ draft_marker ++ "</strong>" ++
            "<span>Review evidence only · no Gerber, drill, centroid, or board fabrication archive.</span></div>\n");
    } else {
        try w.writeAll("<div class=\"mh-notice is-release\"><strong>" ++ release_marker ++ "</strong>" ++
            "<span>Content lock is attested and every board release gate passed.</span></div>\n");
    }
    try w.writeAll("</div>\n</header>\n");
}

fn passingGateCount(state: State) usize {
    const gates = [_]bool{
        state.gates.identity_ok,
        state.gates.interface_ok,
        state.gates.board_review_ok,
        state.gates.fab_ok,
        state.gates.checklists_ok,
        state.attested,
    };
    var passed: usize = 0;
    for (gates) |ok| if (ok) {
        passed += 1;
    };
    return passed;
}

fn writePngDataUri(allocator: std.mem.Allocator, w: *Writer, png: []const u8) Error!void {
    const encoder = std.base64.standard.Encoder;
    const encoded = try allocator.alloc(u8, encoder.calcSize(png.len));
    defer allocator.free(encoded);
    try w.writeAll("data:image/png;base64,");
    try w.writeAll(encoder.encode(encoded, png));
}

fn writeBoardGallery(allocator: std.mem.Allocator, w: *Writer, opts: Options) Error!void {
    if (opts.boards.len == 0) return;
    try w.print("<section class=\"board-gallery\" id=\"board-views\" aria-labelledby=\"board-views-title\">" ++
        "<header class=\"gallery-head\"><div><p class=\"kicker\">Physical overview</p>" ++
        "<h2 id=\"board-views-title\">Board views</h2><p>Interactive physical assembly views for every board in the system. Scroll to zoom and drag to pan.</p>" ++
        "</div><span>{d} board{s}</span></header><div class=\"gallery-list\">\n", .{
        opts.boards.len,
        if (opts.boards.len == 1) "" else "s",
    });
    for (opts.boards) |board| {
        try w.writeAll("<article class=\"board-visual\"><header><div><span class=\"board-role\">");
        try escape.writeXml(w, board.identity.role);
        try w.writeAll("</span><h3>");
        try escape.writeXml(w, board.identity.title);
        try w.writeAll("</h3></div><p>");
        try escape.writeXml(w, board.identity.part_number);
        try w.writeAll(" · Rev ");
        try escape.writeXml(w, board.identity.revision);
        try w.writeAll(" · ");
        try escape.writeXml(w, board.identity.layout);
        try w.writeAll("</p></header><div class=\"assembly-viewer\" data-assembly-viewer><div class=\"assembly-toolbar\"><div class=\"side-switch\" role=\"group\" aria-label=\"Board side\">");
        try w.writeAll("<button type=\"button\" data-side=\"top\" aria-pressed=\"true\">Top</button><button type=\"button\" data-side=\"bottom\" aria-pressed=\"false\">Bottom</button></div>");
        try w.print("<span>{d} cached model{s} · scroll to zoom · drag to pan</span></div>", .{ board.visual.sprites.len, if (board.visual.sprites.len == 1) "" else "s" });
        if (board.visual.board_html.len == 0) {
            try w.writeAll("<div class=\"visual-empty\">Assembly viewer unavailable</div>");
        } else {
            try w.writeAll("<iframe class=\"assembly-frame\" title=\"");
            try escape.writeXml(w, board.identity.title);
            try w.writeAll(" assembly viewer\" loading=\"eager\"></iframe><script type=\"application/json\" class=\"assembly-document\">");
            try json_writer.writeScriptString(w, board.visual.board_html);
            try w.writeAll("</script><template class=\"assembly-sprites\">");
            for (board.visual.sprites) |sprite| {
                try w.writeAll("<img alt=\"\" data-footprint=\"");
                try escape.writeXml(w, sprite.footprint);
                try w.print("\" data-x=\"{d}\" data-y=\"{d}\" data-w=\"{d}\" data-h=\"{d}\" src=\"", .{ sprite.x, sprite.y, sprite.w, sprite.h });
                try writePngDataUri(allocator, w, sprite.png);
                try w.writeAll("\">");
            }
            try w.writeAll("</template>");
        }
        try w.writeAll("</div></article>\n");
    }
    try w.writeAll("</div></section>\n");
}

fn writeBoardViewerScript(w: *Writer) Error!void {
    try w.writeAll(
        "<script>(function(){function side(root,value){root.querySelectorAll('[data-side]').forEach(function(b){b.setAttribute('aria-pressed',String(b.dataset.side===value));});" ++
            "var f=root.querySelector('iframe');if(f&&f.contentWindow)f.contentWindow.postMessage({type:'netlisp-pcb-orientation',side:value,rotation:0},'*');}" ++
            "document.querySelectorAll('[data-assembly-viewer]').forEach(function(root){var f=root.querySelector('iframe'),d=root.querySelector('.assembly-document');if(!f||!d)return;" ++
            "f.addEventListener('load',function(){side(root,'top');var t=root.querySelector('.assembly-sprites');if(!t||!f.contentWindow.PCBSetAssemblySprite)return;" ++
            "t.content.querySelectorAll('img').forEach(function(source){var image=new Image();image.onload=function(){if(f.contentWindow&&f.contentWindow.PCBSetAssemblySprite)f.contentWindow.PCBSetAssemblySprite(source.dataset.footprint,{image:image,x:Number(source.dataset.x),y:Number(source.dataset.y),w:Number(source.dataset.w),h:Number(source.dataset.h)});};image.src=source.getAttribute('src');});});" ++
            "root.querySelectorAll('[data-side]').forEach(function(b){b.addEventListener('click',function(){side(root,b.dataset.side);});});f.srcdoc=JSON.parse(d.textContent||'\"\"');});})();</script>\n",
    );
}

fn writeSectionIndex(
    w: *Writer,
    sections: []const Section,
    opts: Options,
    nodes: []const Node,
) Error!void {
    const decision = releaseDecision(opts.state);
    try w.print("<aside class=\"section-index\" aria-labelledby=\"section-index-title\">" ++
        "<div class=\"index-status {s}\"><span>Release readiness</span><strong>{s}</strong>" ++
        "<small>{d} of 6 gates clear</small></div><nav aria-labelledby=\"section-index-title\">" ++
        "<p class=\"kicker\">On this page</p><h2 id=\"section-index-title\">Sections</h2><ol>" ++
        "<li><a href=\"#board-views\"><span>Top</span>Board views</a></li>" ++
        "<li><a href=\"#executive-summary\"><span>Sum</span>Executive summary</a></li>", .{
        decisionClass(decision),
        decisionHeadline(decision),
        passingGateCount(opts.state),
    });
    for (nodes, 0..) |node, index| {
        try w.print("<li><a href=\"#s{d}\"><span>{d:0>2}</span>", .{ index + 1, index + 1 });
        try writeNodeTitle(w, sections, opts, node);
        try w.writeAll("</a></li>");
    }
    try w.writeAll("</ol></nav></aside>\n");
}

fn interfaceContacts(spec: *const system_review.SystemSpec) usize {
    var contacts: usize = 0;
    for (spec.interfaces) |contract| contacts += contract.contact_count;
    return contacts;
}

const Tone = enum { neutral, good, warn, bad };

fn toneClass(tone: Tone) []const u8 {
    return switch (tone) {
        .neutral => "tone-neutral",
        .good => "tone-good",
        .warn => "tone-warn",
        .bad => "tone-bad",
    };
}

fn statusTone(value: []const u8) Tone {
    if (std.ascii.eqlIgnoreCase(value, "pass") or
        std.ascii.eqlIgnoreCase(value, "ready") or
        std.ascii.eqlIgnoreCase(value, "approved") or
        std.ascii.eqlIgnoreCase(value, "complete")) return .good;
    if (std.ascii.eqlIgnoreCase(value, "blocked") or
        std.ascii.eqlIgnoreCase(value, "fail") or
        std.ascii.eqlIgnoreCase(value, "failed") or
        std.ascii.eqlIgnoreCase(value, "error")) return .bad;
    if (std.ascii.eqlIgnoreCase(value, "warn") or
        std.ascii.eqlIgnoreCase(value, "warning") or
        std.ascii.eqlIgnoreCase(value, "open") or
        std.ascii.eqlIgnoreCase(value, "pending")) return .warn;
    return .neutral;
}

fn writePill(w: *Writer, value: []const u8, tone: Tone) Error!void {
    try w.print("<span class=\"pill {s}\">", .{toneClass(tone)});
    try escape.writeXml(w, value);
    try w.writeAll("</span>");
}

fn writeExecutiveSummary(w: *Writer, sections: []const Section, opts: Options) Error!void {
    const spec = opts.spec;
    const decision = releaseDecision(opts.state);
    const included_documents = sections.len + opts.supporting.len;
    var fab_ready: usize = 0;
    var open_notes: usize = 0;
    for (opts.boards) |board| {
        if (board.fabrication == .ready) fab_ready += 1;
        open_notes += board.review.open_notes;
    }

    try w.writeAll("<section class=\"executive\" id=\"executive-summary\" aria-labelledby=\"executive-title\">\n" ++
        "<div class=\"executive-head\"><div><p class=\"kicker\">Decision snapshot</p>" ++
        "<h2 id=\"executive-title\">Executive summary</h2></div>");
    try writePill(w, decisionPill(decision), decisionTone(decision));
    try w.writeAll("</div>\n<p class=\"executive-lede\">Review the release decision and exceptions here, then expand the supporting evidence alongside it.</p>\n" ++
        "<dl class=\"metrics\">\n");
    try w.print("<div><dt>Boards</dt><dd>{d}</dd><dd class=\"metric-note\">{d} fabrication-ready</dd></div>\n", .{ spec.boards.len, fab_ready });
    try w.print("<div><dt>Interface contacts</dt><dd>{d}</dd><dd class=\"metric-note\">{d} contract{s}</dd></div>\n", .{
        interfaceContacts(spec),
        spec.interfaces.len,
        if (spec.interfaces.len == 1) "" else "s",
    });
    try w.print("<div><dt>Included documents</dt><dd>{d}</dd><dd class=\"metric-note\">{d} inlined · {d} supporting</dd></div>\n", .{
        included_documents,
        sections.len,
        opts.supporting.len,
    });
    try w.print("<div><dt>Open checks</dt><dd>{d}</dd><dd class=\"metric-note\">{d}/{d} complete · {d} board note{s}</dd></div>\n", .{
        opts.checklist.open,
        opts.checklist.complete,
        opts.checklist.total,
        open_notes,
        if (open_notes == 1) "" else "s",
    });
    try w.writeAll("</dl>\n<section class=\"summary-panel gates-panel\" aria-labelledby=\"gates-title\">" ++
        "<div class=\"panel-head\"><h3 id=\"gates-title\">Release gates</h3>");
    try w.print("<span>{d}/6 clear</span></div><ul class=\"gate-list\">\n", .{passingGateCount(opts.state)});
    try writeGate(w, "Identity and layouts", opts.state.gates.identity_ok, "Blocked");
    try writeGate(w, "Interface contract", opts.state.gates.interface_ok, "Blocked");
    try writeGate(w, "Board reviews", opts.state.gates.board_review_ok, "Blocked");
    try writeGate(w, "Fabrication readiness", opts.state.gates.fab_ok, "Blocked");
    try writeGate(w, "Release checklist", opts.state.gates.checklists_ok, "Blocked");
    try writeGate(w, "Content attestation", opts.state.attested, "Pending");
    try w.writeAll("</ul>");
    try writeWaiverNote(w, opts.state.waiver);
    try w.writeAll("</section>\n");

    if (opts.boards.len > 0) {
        try w.writeAll("<section class=\"summary-panel boards-panel\" aria-labelledby=\"boards-title\">" ++
            "<div class=\"panel-head\"><h3 id=\"boards-title\">Board readiness</h3>");
        try w.print("<span>{d} boards</span></div><div class=\"board-list\">\n", .{opts.boards.len});
        for (opts.boards, 0..) |board, index| try writeBoardSummary(w, board, opts.state.waiver, sections.len + index + 2);
        try w.writeAll("</div></section>\n");
    }

    try w.writeAll("<details class=\"provenance\"><summary><span>Package provenance</span><span class=\"provenance-when\">");
    try escape.writeXml(w, opts.provenance.generated_at);
    try w.writeAll("</span><span class=\"chevron\" aria-hidden=\"true\"></span></summary>" ++
        "<dl class=\"provenance-body\">\n");
    try writeProvenanceFact(w, "Generated", opts.provenance.generated_at, false);
    try writeProvenanceFact(w, "Tool build", opts.provenance.build_id, false);
    try writeProvenanceFact(w, "Content lock · SHA-256", opts.provenance.content_lock, true);
    try writeProvenanceFact(w, "Release token · SHA-256", opts.provenance.release_token, true);
    try w.writeAll("</dl></details>\n</section>\n");
}

fn writeWaiverNote(w: *Writer, waiver: WaiverState) Error!void {
    switch (waiver) {
        .none => {},
        .required => try w.writeAll("<p class=\"waiver-note\"><span aria-hidden=\"true\">!</span> Waiver acceptance is required for release.</p>"),
        .accepted => try w.writeAll("<p class=\"waiver-note is-accepted\"><span aria-hidden=\"true\">✓</span> This release records accepted waiver evidence.</p>"),
    }
}

fn writeGate(w: *Writer, label: []const u8, ok: bool, failed_label: []const u8) Error!void {
    try w.print("<li class=\"{s}\"><span class=\"gate-dot\" aria-hidden=\"true\"></span><span>", .{
        if (ok) "gate-clear" else "gate-blocked",
    });
    try escape.writeXml(w, label);
    try w.writeAll("</span><strong>");
    try escape.writeXml(w, if (ok) "Clear" else failed_label);
    try w.writeAll("</strong></li>\n");
}

fn fabricationLabel(fabrication: FabState, waiver: WaiverState) []const u8 {
    return switch (fabrication) {
        .blocked => "Fab blocked",
        .waiver => if (waiver == .accepted) "Fab waiver accepted" else "Fab waiver required",
        .ready => "Fab ready",
    };
}

fn fabricationTone(fabrication: FabState) Tone {
    return switch (fabrication) {
        .blocked => .bad,
        .waiver => .warn,
        .ready => .good,
    };
}

fn writeBoardSummary(w: *Writer, board: Board, waiver: WaiverState, section_number: usize) Error!void {
    const identity = board.identity;
    try w.writeAll("<article class=\"board-card\"><div class=\"board-card-top\"><span class=\"board-role\">");
    try escape.writeXml(w, identity.role);
    try w.writeAll("</span>");
    try writePill(w, board.review.status, statusTone(board.review.status));
    try w.writeAll("</div><strong class=\"board-name\">");
    try escape.writeXml(w, identity.title);
    try w.writeAll("</strong><p>");
    try escape.writeXml(w, identity.part_number);
    try w.writeAll(" · Rev ");
    try escape.writeXml(w, identity.revision);
    try w.writeAll("</p><div class=\"board-signals\">");
    try writePill(w, fabricationLabel(board.fabrication, waiver), fabricationTone(board.fabrication));
    try w.print("<span class=\"pill {s}\">{d} open note{s}</span></div>", .{
        toneClass(if (board.review.open_notes == 0) .good else .warn),
        board.review.open_notes,
        if (board.review.open_notes == 1) "" else "s",
    });
    try w.print("<a class=\"board-jump\" href=\"#s{d}\">Jump to board evidence <span aria-hidden=\"true\">→</span></a></article>\n", .{section_number});
}

fn writeProvenanceFact(w: *Writer, key: []const u8, value: []const u8, hash: bool) Error!void {
    try w.writeAll(if (hash) "<div class=\"hash\"><dt>" else "<div><dt>");
    try escape.writeXml(w, key);
    try w.writeAll("</dt><dd>");
    try escape.writeXml(w, value);
    try w.writeAll("</dd></div>\n");
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

fn writeLinearSection(
    allocator: std.mem.Allocator,
    w: *Writer,
    sections: []const Section,
    opts: Options,
    node: Node,
    number: usize,
) Error!void {
    try w.print("<section class=\"sec\" id=\"s{d}\"><header class=\"sec-head\">" ++
        "<span class=\"sec-n\">{d:0>2}</span><div><h3 class=\"sec-title\">", .{ number, number });
    try writeNodeTitle(w, sections, opts, node);
    try w.writeAll("</h3><div class=\"sec-labels\">");
    switch (node) {
        .document => |index| {
            try w.writeAll("<span class=\"tag\">");
            try escape.writeXml(w, sections[index].classification);
            try w.writeAll("</span>");
        },
        .system_diagram, .board, .supporting => try w.writeAll("<span class=\"tag tag-gen\">generated</span>"),
    }
    try writeNodeMeta(allocator, w, sections, opts, node);
    try w.writeAll("</div></div><a class=\"back-to-index\" href=\"#section-index-title\">Index ↑</a></header><div class=\"sec-body\">\n");
    try writeNodeBody(allocator, w, sections, opts, node);
    try w.writeAll("</div></section>\n");
}

fn writeNodeBody(
    allocator: std.mem.Allocator,
    w: *Writer,
    sections: []const Section,
    opts: Options,
    node: Node,
) Error!void {
    switch (node) {
        .document => |index| try writeMarkdownBody(allocator, w, sections[index].title, sections[index].markdown),
        .system_diagram => try writeSystemDiagram(allocator, w, opts),
        .board => |index| try writeBoard(w, opts.boards[index], opts.state.waiver),
        .supporting => try writeSupporting(w, opts.supporting),
    }
}

fn writeNodeMeta(
    allocator: std.mem.Allocator,
    w: *Writer,
    sections: []const Section,
    opts: Options,
    node: Node,
) Error!void {
    try w.writeAll("<span class=\"sec-meta\">");
    switch (node) {
        .document => |index| {
            const checklist = sections[index].checklist;
            if (checklist.total > 0) {
                try w.print("{d} open · {d}/{d} checks complete", .{
                    checklist.open,
                    checklist.complete,
                    checklist.total,
                });
            } else {
                const topics = try documentTopicCount(allocator, sections[index]);
                try w.print("{d} topic{s}", .{ topics, if (topics == 1) "" else "s" });
            }
        },
        .system_diagram => try w.print("{d} boards · {d} interfaces · {d} contacts", .{
            opts.spec.boards.len,
            opts.spec.interfaces.len,
            interfaceContacts(opts.spec),
        }),
        .board => |index| {
            const board = opts.boards[index];
            try escape.writeXml(w, board.review.status);
            try w.print(" · {d} open note{s} · {s}", .{
                board.review.open_notes,
                if (board.review.open_notes == 1) "" else "s",
                fabricationLabel(board.fabrication, opts.state.waiver),
            });
        },
        .supporting => try w.print("{d} active document{s}", .{
            opts.supporting.len,
            if (opts.supporting.len == 1) "" else "s",
        }),
    }
    try w.writeAll("</span>");
}

fn documentTopicCount(allocator: std.mem.Allocator, section: Section) Error!usize {
    var options: review_md.Options = .{};
    options.limits.source_bytes = max_html_bytes;
    var parsed = try review_md.parse(allocator, section.markdown, options);
    defer parsed.deinit();
    var topics: usize = 0;
    for (parsed.blocks) |block| if (block == .heading) {
        topics += 1;
    };
    if (topics > 0 and duplicateTitleHeading(parsed.blocks[0], section.title)) topics -= 1;
    return topics;
}

fn writeMarkdownBody(
    allocator: std.mem.Allocator,
    w: *Writer,
    section_title: []const u8,
    markdown: []const u8,
) Error!void {
    var options: review_md.Options = .{};
    options.limits.source_bytes = max_html_bytes;
    var parsed = try review_md.parse(allocator, markdown, options);
    defer parsed.deinit();
    const all_blocks = parsed.blocks;
    const removed_title = all_blocks.len > 0 and duplicateTitleHeading(all_blocks[0], section_title);
    if (removed_title)
        parsed.blocks = all_blocks[1..];
    const shifted = try shiftedHeadings(allocator, parsed.blocks, if (removed_title) 2 else 3);
    defer allocator.free(shifted);
    parsed.blocks = shifted;
    try w.writeAll("<div class=\"prose\">\n");
    try review_md.renderHtml(w, &parsed);
    try w.writeAll("</div>\n");
}

fn shiftedHeadings(
    allocator: std.mem.Allocator,
    blocks: []const review_md.Block,
    offset: u3,
) ![]review_md.Block {
    const shifted = try allocator.dupe(review_md.Block, blocks);
    for (shifted) |*block| switch (block.*) {
        .heading => |*heading| heading.level = shiftedHeadingLevel(heading.level, offset),
        else => {},
    };
    return shifted;
}

fn shiftedHeadingLevel(level: u3, offset: u3) u3 {
    const value: u4 = @as(u4, level) + @as(u4, offset);
    return @intCast(@min(value, 6));
}

fn duplicateTitleHeading(block: review_md.Block, section_title: []const u8) bool {
    if (block != .heading) return false;
    const heading = block.heading;
    if (heading.level != 1 or heading.content.len != 1) return false;
    return switch (heading.content[0]) {
        .text => |text| std.mem.eql(u8, text, section_title),
        else => false,
    };
}

fn writeSystemDiagram(allocator: std.mem.Allocator, w: *Writer, opts: Options) Error!void {
    try w.writeAll("<p class=\"lede\">Boards as blocks, each board-to-board contract as a labeled spine. " ++
        "Contacts are grouped into signal lanes; the ground lane collapses to a count.</p>\n" ++
        "<figure class=\"fig\"><span class=\"scroll-hint\">Scroll horizontally to inspect the diagram →</span>\n");
    // Tool-rendered in this process from the parsed manifest: static, scriptless,
    // and free of any `id` that could collide with the surrounding page.
    try system_of_boards.renderSystemSvg(allocator, opts.spec, .{}, w);
    try w.writeAll("\n<figcaption>System-of-boards block diagram · also archived per board under <code>boards/</code>.</figcaption>\n</figure>\n");
}

fn writeBoard(w: *Writer, board: Board, waiver: WaiverState) Error!void {
    try w.writeAll("<dl class=\"facts\">\n");
    const identity = board.identity;
    try writeFact(w, "Design", identity.design);
    try writeFact(w, "Title", identity.title);
    try writeFact(w, "Part number", identity.part_number);
    try writeFact(w, "Revision", identity.revision);
    try writeFact(w, "Layout", identity.layout);
    try writeFact(w, "Review", board.review.status);
    try w.print("<div class=\"fact\"><dt>Open notes</dt><dd>{d}</dd></div>\n", .{board.review.open_notes});
    try writeFact(w, "Fabrication gate", fabricationLabel(board.fabrication, waiver));
    try writeFact(w, "Evidence generated", identity.generated_at);
    try w.writeAll("</dl>\n");

    if (board.review.diagram_svg.len > 0) {
        try w.writeAll("<figure class=\"fig dark\"><span class=\"scroll-hint\">Scroll horizontally to inspect the diagram →</span>\n");
        // Same provenance argument as the archived `boards/<role>/diagram.svg`
        // member: these bytes were written by the diagram renderer inside this
        // process, and its own `<style>` block is `.dg-*`-scoped throughout.
        try w.writeAll(board.review.diagram_svg);
        try w.writeAll("\n<figcaption>Block diagram · <code>");
        try writeMemberPath(w, identity.role, "diagram.svg");
        try w.writeAll("</code></figcaption>\n</figure>\n");
    }

    try w.writeAll("<h4>Archived evidence</h4>\n<ul class=\"members\">\n");
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
    \\--paper:#0a0f12;--paper-deep:#070b0d;--sheet:#11181d;--sheet-2:#172128;--sheet-3:#1d2931;
    \\--ink:#edf4f5;--ink-2:#a8b8bd;--ink-3:#75888f;
    \\--rule:#26343d;--rule-2:#344650;--band:#080d10;--panel:#0d1117;
    \\--accent:#58cbd0;--accent-soft:#102a2e;--good:#7bd49a;--good-soft:#10281d;
    \\--warn:#f2bd66;--warn-soft:#302411;--crit:#ff8585;--crit-soft:#321719;
    \\--sans:ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
    \\--mono:ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,"Liberation Mono",monospace;
    \\}
    \\*{box-sizing:border-box;}
    \\html{scroll-behavior:smooth;}
    \\body{margin:0;background:linear-gradient(180deg,var(--paper-deep) 0,var(--paper) 440px);
    \\color:var(--ink);font-family:var(--sans);font-size:15px;line-height:1.55;overflow-x:hidden;
    \\-webkit-text-size-adjust:100%;min-height:100vh;}
    \\a{color:var(--accent);text-underline-offset:2px;}
    \\a:focus-visible{outline:2px solid var(--accent);outline-offset:2px;}
    \\code,kbd{font-family:var(--mono);font-size:.88em;overflow-wrap:anywhere;}
    \\code{background:var(--sheet-2);border:1px solid var(--rule);border-radius:4px;padding:.06em .34em;}
    \\.skip-link{position:fixed;z-index:20;left:16px;top:12px;padding:9px 13px;background:var(--ink);
    \\color:var(--paper);border-radius:7px;font-weight:700;transform:translateY(-160%);transition:transform .15s;}
    \\.skip-link:focus{transform:translateY(0);}
    \\.masthead{background:rgba(8,13,16,.96);border-bottom:1px solid var(--rule);}
    \\.mh-inner{max-width:1480px;margin:0 auto;padding:26px 30px 0;}
    \\.mh-topline{display:flex;justify-content:space-between;align-items:center;gap:16px;}
    \\.mh-eyebrow{font-family:var(--mono);font-size:10px;letter-spacing:.16em;text-transform:uppercase;
    \\color:var(--ink-3);display:flex;flex-wrap:wrap;gap:6px 12px;margin:0;}
    \\.mode-pill,.pill{display:inline-flex;align-items:center;width:max-content;border:1px solid var(--rule-2);
    \\border-radius:999px;padding:4px 9px;font-family:var(--mono);font-size:9.5px;font-weight:700;
    \\letter-spacing:.08em;text-transform:uppercase;line-height:1.25;color:var(--ink-2);background:var(--sheet-2);}
    \\.mode-pill{color:var(--warn);border-color:rgba(242,189,102,.38);background:var(--warn-soft);}
    \\.mh-lead{display:grid;grid-template-columns:minmax(0,1fr) 220px;align-items:end;gap:36px;padding:22px 0 24px;}
    \\.mh-title{font-size:clamp(32px,5vw,58px);font-weight:720;letter-spacing:-.035em;line-height:1.02;
    \\margin:0 0 10px;text-wrap:balance;}
    \\.mh-sub{font-size:clamp(14px,1.3vw,17px);color:var(--ink-2);max-width:68ch;margin:0 0 18px;}
    \\.mh-identity{display:flex;flex-wrap:wrap;gap:8px;}
    \\.mh-identity span{display:inline-flex;gap:7px;align-items:center;border:1px solid var(--rule);
    \\background:var(--sheet);border-radius:7px;padding:6px 9px;font-family:var(--mono);font-size:11px;color:var(--ink-2);}
    \\.mh-identity b{font-size:9px;letter-spacing:.12em;text-transform:uppercase;color:var(--ink-3);}
    \\.mh-status{min-height:124px;border:1px solid var(--rule-2);border-radius:12px;padding:18px 20px;
    \\display:flex;flex-direction:column;justify-content:center;background:var(--sheet);box-shadow:0 16px 45px rgba(0,0,0,.18);}
    \\.mh-status span{font-family:var(--mono);font-size:9px;letter-spacing:.15em;text-transform:uppercase;color:var(--ink-3);}
    \\.mh-status strong{font-size:26px;letter-spacing:.03em;line-height:1.15;margin:7px 0 3px;}
    \\.mh-status small{font-family:var(--mono);font-size:11px;color:var(--ink-2);}
    \\.mh-status.is-blocked{border-color:rgba(255,133,133,.38);background:linear-gradient(145deg,var(--crit-soft),var(--sheet) 72%);}
    \\.mh-status.is-blocked strong{color:var(--crit);}
    \\.mh-status.is-waiver{border-color:rgba(242,189,102,.38);background:linear-gradient(145deg,var(--warn-soft),var(--sheet) 72%);}
    \\.mh-status.is-waiver strong{color:var(--warn);font-size:21px;}
    \\.mh-status.is-ready{border-color:rgba(123,212,154,.38);background:linear-gradient(145deg,var(--good-soft),var(--sheet) 72%);}
    \\.mh-status.is-ready strong{color:var(--good);}
    \\.mh-notice{display:flex;align-items:center;flex-wrap:wrap;gap:8px 18px;margin:0 -30px;padding:10px 30px;
    \\border-top:1px solid var(--rule);font-family:var(--mono);}
    \\.mh-notice strong{font-size:10.5px;letter-spacing:.16em;white-space:nowrap;}
    \\.mh-notice span{font-size:10.5px;color:var(--ink-3);}
    \\.mh-notice.is-draft{background:linear-gradient(90deg,rgba(242,189,102,.12),transparent 70%);}
    \\.mh-notice.is-draft strong{color:var(--warn);}
    \\.mh-notice.is-release{background:linear-gradient(90deg,rgba(123,212,154,.12),transparent 70%);}
    \\.mh-notice.is-release strong{color:var(--good);}
    \\.board-gallery{width:100%;margin:0 0 28px;padding:0;scroll-margin-top:18px;}
    \\.gallery-head{display:flex;align-items:flex-end;justify-content:space-between;gap:24px;margin-bottom:15px;}
    \\.gallery-head h2{font-size:24px;letter-spacing:-.025em;margin:0;}
    \\.gallery-head p:last-child{font-size:13px;color:var(--ink-2);margin:6px 0 0;}
    \\.gallery-head>span{font-family:var(--mono);font-size:10px;color:var(--ink-3);border:1px solid var(--rule);border-radius:999px;padding:5px 10px;}
    \\.gallery-list{display:grid;gap:14px;}
    \\.board-visual{border:1px solid var(--rule);border-radius:14px;background:var(--sheet);padding:14px;box-shadow:0 18px 50px rgba(0,0,0,.14);}
    \\.board-visual>header{display:flex;align-items:flex-end;justify-content:space-between;gap:18px;padding:0 2px 11px;}
    \\.board-visual h3{font-size:17px;line-height:1.25;margin:2px 0 0;}
    \\.board-visual>header p{font-family:var(--mono);font-size:9.5px;color:var(--ink-3);margin:0;text-align:right;}
    \\.assembly-viewer{min-width:0;border:1px solid var(--rule);border-radius:10px;background:var(--panel);overflow:hidden;}
    \\.assembly-toolbar{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:8px 10px;border-bottom:1px solid var(--rule);background:var(--sheet-2);}
    \\.assembly-toolbar>span{font-family:var(--mono);font-size:8.5px;color:var(--ink-3);text-align:right;}
    \\.side-switch{display:flex;gap:3px;padding:3px;border:1px solid var(--rule);border-radius:8px;background:var(--paper);}
    \\.side-switch button{appearance:none;border:0;border-radius:5px;padding:5px 13px;background:transparent;color:var(--ink-2);font:650 10.5px/1 var(--sans);cursor:pointer;}
    \\.side-switch button[aria-pressed=\"true\"]{background:var(--accent-soft);color:var(--accent);box-shadow:inset 0 0 0 1px rgba(88,214,255,.25);}
    \\.assembly-frame{display:block;width:100%;height:clamp(420px,60vw,760px);border:0;background:#101815;}
    \\.visual-empty{display:grid;place-items:center;min-height:180px;padding:20px;font-family:var(--mono);font-size:10px;color:var(--ink-3);}
    \\.workspace{width:min(1480px,100%);margin:0 auto;padding:18px 30px 72px;display:grid;
    \\grid-template-columns:minmax(230px,270px) minmax(0,1fr);gap:24px;align-items:start;}
    \\.section-index{position:sticky;top:18px;max-height:calc(100vh - 36px);overflow-y:auto;scrollbar-color:var(--rule-2) transparent;
    \\background:rgba(17,24,29,.94);border:1px solid var(--rule);border-radius:14px;padding:13px;
    \\box-shadow:0 18px 50px rgba(0,0,0,.18);}
    \\.index-status{border:1px solid var(--rule-2);border-radius:9px;padding:11px 12px;margin-bottom:15px;background:var(--paper);display:grid;}
    \\.index-status>span{font-family:var(--mono);font-size:8px;letter-spacing:.13em;text-transform:uppercase;color:var(--ink-3);}
    \\.index-status strong{font-size:15px;line-height:1.2;margin:4px 0 2px;}
    \\.index-status small{font-family:var(--mono);font-size:9px;color:var(--ink-3);}
    \\.index-status.is-blocked strong{color:var(--crit);}
    \\.index-status.is-waiver strong{color:var(--warn);}
    \\.index-status.is-ready strong{color:var(--good);}
    \\.section-index nav h2{font-size:18px;margin:0 4px 9px;}
    \\.section-index nav>.kicker{margin-left:4px;}
    \\.section-index ol{list-style:none;margin:0;padding:0;display:grid;gap:2px;}
    \\.section-index li{min-width:0;}
    \\.section-index a{display:grid;grid-template-columns:24px minmax(0,1fr);gap:7px;align-items:start;padding:7px 8px;border-radius:7px;color:var(--ink-2);font-size:11.5px;line-height:1.35;text-decoration:none;}
    \\.section-index a:hover{color:var(--ink);background:var(--sheet-2);}
    \\.section-index a span{font-family:var(--mono);font-size:9px;color:var(--accent);padding-top:2px;}
    \\.document{min-width:0;}
    \\.executive{background:rgba(17,24,29,.94);border:1px solid var(--rule);border-radius:14px;padding:20px;
    \\box-shadow:0 18px 50px rgba(0,0,0,.18);scroll-margin-top:18px;margin-bottom:28px;}
    \\.executive-head,.panel-head{display:flex;align-items:center;justify-content:space-between;gap:12px;}
    \\.kicker{font-family:var(--mono);font-size:9.5px;letter-spacing:.16em;text-transform:uppercase;color:var(--accent);margin:0 0 5px;}
    \\.executive h2{font-size:20px;letter-spacing:-.02em;margin:0;white-space:nowrap;}
    \\.evidence-head h2{font-size:22px;letter-spacing:-.02em;margin:0;}
    \\.executive-lede{color:var(--ink-2);font-size:13.5px;line-height:1.5;margin:12px 0 17px;}
    \\.metrics{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;margin:0 0 14px;}
    \\.metrics>div{min-width:0;background:var(--sheet-2);border:1px solid var(--rule);border-radius:9px;padding:10px 11px;}
    \\.metrics dt{font-family:var(--mono);font-size:8.5px;letter-spacing:.12em;text-transform:uppercase;color:var(--ink-3);}
    \\.metrics dd{font-size:23px;font-weight:720;letter-spacing:-.03em;margin:2px 0 0;color:var(--ink);font-variant-numeric:tabular-nums;}
    \\.metrics .metric-note{display:block;font-size:10.5px;font-weight:400;color:var(--ink-3);white-space:normal;margin:0;}
    \\.summary-panel{background:var(--paper);border:1px solid var(--rule);border-radius:10px;padding:13px;margin-top:10px;}
    \\.panel-head h3{font-size:12px;letter-spacing:.02em;margin:0;}
    \\.panel-head>span{font-family:var(--mono);font-size:9.5px;color:var(--ink-3);}
    \\.gate-list{list-style:none;margin:10px 0 0;padding:0;display:grid;gap:2px;}
    \\.gate-list li{display:grid;grid-template-columns:12px minmax(0,1fr) auto;align-items:center;gap:8px;
    \\min-height:29px;color:var(--ink-2);font-size:12px;border-bottom:1px solid rgba(38,52,61,.55);}
    \\.gate-list li:last-child{border-bottom:none;}
    \\.gate-list strong{font-family:var(--mono);font-size:9px;letter-spacing:.06em;text-transform:uppercase;}
    \\.gate-dot{width:7px;height:7px;border-radius:50%;background:var(--ink-3);box-shadow:0 0 0 3px rgba(117,136,143,.12);}
    \\.gate-clear .gate-dot{background:var(--good);box-shadow:0 0 0 3px rgba(123,212,154,.12);}
    \\.gate-clear strong{color:var(--good);}
    \\.gate-blocked .gate-dot{background:var(--crit);box-shadow:0 0 0 3px rgba(255,133,133,.12);}
    \\.gate-blocked strong{color:var(--crit);}
    \\.waiver-note{margin:10px 0 0;padding:8px 10px;border-radius:7px;background:var(--warn-soft);color:var(--warn);font-size:11px;}
    \\.waiver-note span{display:inline-grid;place-items:center;width:17px;height:17px;margin-right:4px;border:1px solid currentColor;border-radius:50%;font-weight:800;}
    \\.waiver-note.is-accepted{background:var(--accent-soft);color:var(--accent);}
    \\.board-list{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:7px;margin-top:10px;}
    \\.board-card{border:1px solid var(--rule);border-radius:8px;background:var(--sheet);padding:9px 10px;}
    \\.board-card-top{display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:4px;}
    \\.board-role{font-family:var(--mono);font-size:9px;letter-spacing:.14em;text-transform:uppercase;color:var(--accent);}
    \\.board-name{display:block;font-size:13px;line-height:1.3;}
    \\.board-card p{font-family:var(--mono);font-size:9.5px;color:var(--ink-3);margin:2px 0 6px;}
    \\.board-signals{display:flex;flex-wrap:wrap;gap:5px;}
    \\.pill.tone-good{color:var(--good);border-color:rgba(123,212,154,.34);background:var(--good-soft);}
    \\.pill.tone-warn{color:var(--warn);border-color:rgba(242,189,102,.34);background:var(--warn-soft);}
    \\.pill.tone-bad{color:var(--crit);border-color:rgba(255,133,133,.34);background:var(--crit-soft);}
    \\.board-jump{display:inline-flex;align-items:center;gap:5px;margin-top:6px;font-size:11px;text-decoration:none;}
    \\.board-jump:hover{text-decoration:underline;}
    \\.provenance{margin-top:10px;border:1px solid var(--rule);border-radius:9px;background:var(--paper);}
    \\.provenance>summary{display:grid;grid-template-columns:minmax(0,1fr) auto 13px;align-items:center;gap:8px;
    \\min-height:42px;padding:8px 11px;cursor:pointer;list-style:none;font-size:11.5px;font-weight:650;}
    \\.provenance>summary::-webkit-details-marker,.sec-head::-webkit-details-marker{display:none;}
    \\.provenance-when{font-family:var(--mono);font-size:8.5px;color:var(--ink-3);font-weight:400;}
    \\.chevron{width:8px;height:8px;border-right:1.5px solid currentColor;border-bottom:1.5px solid currentColor;
    \\transform:rotate(45deg);transition:transform .16s;color:var(--ink-3);}
    \\details[open]>summary .chevron{transform:rotate(225deg);}
    \\.provenance-body{display:grid;gap:8px;margin:0;padding:11px;border-top:1px solid var(--rule);}
    \\.provenance-body>div{min-width:0;}
    \\.provenance-body dt{font-family:var(--mono);font-size:8.5px;letter-spacing:.11em;text-transform:uppercase;color:var(--ink-3);}
    \\.provenance-body dd{font-family:var(--mono);font-size:10px;color:var(--ink-2);margin:2px 0 0;overflow-wrap:anywhere;}
    \\.provenance-body .hash dd{font-size:9px;}
    \\.evidence{min-width:0;}
    \\.evidence-head{display:flex;align-items:flex-end;justify-content:space-between;gap:20px;margin:2px 2px 16px;padding:0 2px 15px;border-bottom:1px solid var(--rule);}
    \\.evidence-head p:last-child{font-size:13px;color:var(--ink-2);margin:7px 0 0;max-width:66ch;}
    \\.evidence-count{flex:none;border:1px solid var(--rule);border-radius:999px;padding:5px 10px;font-family:var(--mono);font-size:10px;color:var(--ink-3);}
    \\.sec{min-width:0;margin:0 0 20px;border:1px solid var(--rule);border-radius:11px;background:var(--sheet);scroll-margin-top:18px;overflow:clip;}
    \\.sec:target{border-color:var(--accent);box-shadow:0 0 0 3px rgba(88,203,208,.1);}
    \\.sec-head{display:grid;grid-template-columns:38px minmax(0,1fr) auto;align-items:center;gap:12px;min-height:76px;padding:14px 18px;background:var(--sheet);}
    \\.sec-head>div{min-width:0;}
    \\.provenance>summary:focus-visible{outline:2px solid var(--accent);outline-offset:-3px;border-radius:9px;}
    \\.sec-n{font-family:var(--mono);font-size:11px;font-weight:700;letter-spacing:.08em;color:var(--accent);font-variant-numeric:tabular-nums;}
    \\.sec-title{font-size:17px;font-weight:680;letter-spacing:-.012em;line-height:1.25;text-wrap:balance;margin:0 0 5px;}
    \\.sec-labels{display:flex;align-items:center;flex-wrap:wrap;gap:7px 10px;}
    \\.tag{font-family:var(--mono);font-size:8.5px;font-weight:700;letter-spacing:.11em;text-transform:uppercase;
    \\padding:3px 7px 2px;border-radius:999px;border:1px solid var(--rule-2);color:var(--ink-2);background:var(--sheet-2);}
    \\.tag-gen{color:var(--accent);border-color:rgba(88,203,208,.35);background:var(--accent-soft);}
    \\.sec-meta{font-family:var(--mono);font-size:9.5px;line-height:1.35;color:var(--ink-3);}
    \\.back-to-index{font-family:var(--mono);font-size:9px;letter-spacing:.07em;text-transform:uppercase;color:var(--ink-3);text-decoration:none;}
    \\.back-to-index:hover{color:var(--accent);}
    \\.sec-body{padding:26px 28px 32px;border-top:1px solid var(--rule);background:var(--paper);min-width:0;}
    \\.lede{color:var(--ink-2);max-width:72ch;margin:10px 0 18px;}
    \\.prose{min-width:0;}
    \\.prose h1,.prose h2,.prose h3,.prose h4{font-size:18px;font-weight:650;margin:28px 0 10px;padding-bottom:7px;border-bottom:1px solid var(--rule);}
    \\.prose h5{font-size:15px;font-weight:650;margin:22px 0 8px;}
    \\.prose h6{font-family:var(--mono);font-size:11px;letter-spacing:.13em;
    \\text-transform:uppercase;color:var(--ink-3);margin:20px 0 8px;font-weight:600;}
    \\.prose p{margin:0 0 13px;max-width:76ch;color:var(--ink-2);}
    \\.prose strong{color:var(--ink);font-weight:600;}
    \\.prose ul,.prose ol{margin:0 0 14px;padding-left:22px;color:var(--ink-2);max-width:76ch;}
    \\.prose li{margin:0 0 5px;}
    \\.prose li.task{list-style:none;margin:0 0 6px -22px;padding:8px 10px;border:1px solid var(--rule);border-radius:7px;background:var(--sheet);}
    \\.prose li.unchecked{color:var(--ink);border-left:3px solid var(--crit);}
    \\.prose li.checked{opacity:.75;border-left:3px solid var(--good);}
    \\.prose input[type=checkbox]{accent-color:var(--accent);margin:0 7px 0 0;vertical-align:-1px;}
    \\pre{background:var(--sheet);border:1px solid var(--rule);border-radius:8px;padding:13px 15px;
    \\overflow-x:auto;margin:0 0 14px;max-width:100%;}
    \\pre code{background:none;border:none;padding:0;font-size:12.5px;line-height:1.5;white-space:pre;}
    \\table{display:block;width:max-content;max-width:100%;overflow-x:auto;border-collapse:collapse;
    \\border:1px solid var(--rule);border-radius:7px;background:var(--sheet);margin:12px 0 18px;font-size:13px;
    \\scrollbar-color:var(--rule-2) var(--sheet);box-shadow:inset -14px 0 16px -19px rgba(168,184,189,.42);}
    \\th,td{border-bottom:1px solid var(--rule);padding:8px 12px;text-align:left;vertical-align:top;}
    \\th{font-family:var(--mono);font-size:10.5px;letter-spacing:.09em;text-transform:uppercase;
    \\color:var(--ink-3);background:var(--sheet-2);white-space:nowrap;}
    \\td{color:var(--ink-2);}
    \\th:first-child,td:first-child{position:sticky;left:0;z-index:1;background:var(--sheet);box-shadow:1px 0 var(--rule);}
    \\th:first-child{z-index:2;background:var(--sheet-2);}
    \\td.status-good{color:var(--good);font-weight:700;}
    \\td.status-warn{color:var(--warn);font-weight:700;}
    \\td.status-bad{color:var(--crit);font-weight:700;}
    \\tbody tr:last-child td{border-bottom:none;}
    \\.align-right{text-align:right;}
    \\.align-center{text-align:center;}
    \\.netlisp-directive{display:none;}
    \\.fig{margin:14px 0 18px;padding:0;overflow-x:auto;max-width:100%;scrollbar-color:var(--rule-2) var(--paper);}
    \\.fig.dark{background:var(--panel);border:1px solid var(--rule);border-radius:10px;padding:10px;}
    \\.fig svg{display:block;max-width:100%;height:auto;}
    \\.fig figcaption{font-family:var(--mono);font-size:11px;color:var(--ink-3);margin-top:8px;}
    \\.scroll-hint{display:none;}
    \\.facts{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:0;margin:12px 0 16px;
    \\border:1px solid var(--rule);border-radius:8px;background:var(--sheet);overflow:hidden;}
    \\.fact{padding:10px 14px 12px;border-right:1px solid var(--rule);border-bottom:1px solid var(--rule);min-width:0;}
    \\.fact dt{font-family:var(--mono);font-size:9.5px;letter-spacing:.15em;text-transform:uppercase;
    \\color:var(--ink-3);margin-bottom:4px;}
    \\.fact dd{margin:0;font-family:var(--mono);font-size:13px;color:var(--ink);overflow-wrap:anywhere;}
    \\.sec-body>h3,.sec-body>h4{font-family:var(--mono);font-size:11px;letter-spacing:.13em;text-transform:uppercase;
    \\color:var(--ink-3);margin:22px 0 8px;font-weight:500;}
    \\.members{list-style:none;margin:0;padding:0;display:grid;gap:1px;background:var(--rule);
    \\border:1px solid var(--rule);border-radius:8px;overflow:hidden;}
    \\.members li{display:flex;flex-wrap:wrap;gap:4px 16px;justify-content:space-between;
    \\background:var(--sheet);padding:9px 14px;font-size:13px;}
    \\.members a{font-weight:600;text-decoration:none;}
    \\.members a:hover{text-decoration:underline;}
    \\.members span{color:var(--ink-3);}
    \\.colophon{max-width:1480px;margin:0 auto;padding:18px 30px 40px;display:flex;flex-wrap:wrap;
    \\gap:6px 24px;border-top:1px solid var(--rule);font-family:var(--mono);font-size:10.5px;color:var(--ink-3);}
    \\@media(max-width:1080px){
    \\.workspace{grid-template-columns:minmax(210px,240px) minmax(0,1fr);gap:18px;}
    \\.metrics{grid-template-columns:1fr 1fr;}
    \\}
    \\@media(max-width:900px){
    \\.workspace{grid-template-columns:minmax(0,1fr);padding-top:20px;}
    \\.section-index{position:static;max-height:none;overflow:visible;}
    \\.section-index ol{grid-template-columns:1fr 1fr;}
    \\.index-status{grid-template-columns:minmax(0,1fr) auto;column-gap:12px;align-items:center;}
    \\.index-status strong{grid-row:1/3;grid-column:2;}
    \\.summary-panel{display:inline-block;vertical-align:top;width:calc(50% - 6px);margin-right:7px;}
    \\.provenance{clear:both;}
    \\}
    \\@media(max-width:700px){
    \\.mh-inner{padding:20px 18px 0;}
    \\.mh-topline{align-items:flex-start;}
    \\.mh-lead{grid-template-columns:minmax(0,1fr);gap:18px;padding:20px 0;}
    \\.mh-title{font-size:clamp(30px,10vw,42px);}
    \\.mh-status{min-height:0;padding:14px 16px;}
    \\.mh-status strong{font-size:22px;}
    \\.mh-notice{margin:0 -18px;padding:10px 18px;}
    \\.gallery-head,.board-visual>header{align-items:flex-start;}
    \\.assembly-toolbar{align-items:flex-start;flex-direction:column;}
    \\.assembly-toolbar>span{text-align:left;}
    \\.assembly-frame{height:440px;}
    \\.workspace{padding:16px 14px 52px;}
    \\.section-index ol{grid-template-columns:minmax(0,1fr);}
    \\.executive{padding:17px;border-radius:12px;}
    \\.metrics{grid-template-columns:1fr 1fr;}
    \\.summary-panel{display:block;width:auto;margin-right:0;}
    \\.evidence-head{align-items:flex-start;}
    \\.evidence-count{margin-top:1px;}
    \\.sec-head{grid-template-columns:27px minmax(0,1fr);gap:7px 9px;min-height:76px;padding:12px;}
    \\.sec-n{align-self:start;padding-top:3px;}
    \\.sec-title{font-size:14.5px;}
    \\.back-to-index{grid-column:2;justify-self:start;}
    \\.sec-body{padding:20px 16px 26px;}
    \\.scroll-hint{display:block;position:sticky;left:0;width:max-content;margin:0 0 8px;padding:4px 7px;
    \\border:1px solid var(--rule);border-radius:999px;background:var(--sheet);font-family:var(--mono);font-size:9px;color:var(--ink-3);}
    \\.fig svg{max-width:none;min-width:700px;}
    \\.colophon{padding:16px 18px 32px;}
    \\}
    \\@media(max-width:440px){
    \\.mh-topline{display:block;}
    \\.mode-pill{margin-top:9px;}
    \\.mh-identity{display:grid;grid-template-columns:1fr 1fr;}
    \\.mh-identity span{display:block;}
    \\.mh-identity b{display:block;margin-bottom:2px;}
    \\.executive-head{align-items:flex-start;}
    \\.provenance>summary{grid-template-columns:minmax(0,1fr) 13px;}
    \\.provenance-when{display:none;}
    \\.members li{display:block;}
    \\.members span{display:block;margin-top:4px;}
    \\.gallery-head,.board-visual>header{display:block;}
    \\.gallery-head>span{display:inline-block;margin-top:10px;}
    \\.board-visual>header p{text-align:left;margin-top:5px;}
    \\}
    \\@media(prefers-reduced-motion:reduce){
    \\html{scroll-behavior:auto;}
    \\*,*::before,*::after{transition-duration:.01ms!important;}
    \\}
    \\@media print{
    \\:root{color-scheme:light;--paper:#fff;--paper-deep:#fff;--sheet:#fff;--sheet-2:#f3f5f6;--sheet-3:#eef1f2;
    \\--ink:#101617;--ink-2:#374347;--ink-3:#58676c;--rule:#c8d0d3;--rule-2:#aab6ba;--band:#fff;--panel:#0d1117;}
    \\body{background:#fff;}
    \\.masthead{background:#fff;}
    \\.board-gallery{padding-top:18px;}
    \\.board-visual{break-inside:avoid;box-shadow:none;}
    \\.workspace{display:block;padding-top:18px;}
    \\.section-index{display:none;}
    \\.executive{box-shadow:none;margin-bottom:20px;}
    \\.summary-panel{display:inline-block;vertical-align:top;width:48%;}
    \\.sec{break-before:page;}
    \\.sec:first-of-type{break-before:auto;}
    \\.back-to-index{display:none;}
    \\.provenance-body,.provenance:not([open])>.provenance-body{display:block!important;}
    \\.evidence table{display:table!important;width:100%!important;max-width:100%!important;table-layout:fixed;overflow:visible;box-shadow:none;font-size:8px;}
    \\.evidence th,.evidence td{position:static!important;white-space:normal!important;overflow-wrap:anywhere;padding:4px 5px;box-shadow:none!important;}
    \\.evidence pre{white-space:pre-wrap;overflow-wrap:anywhere;}
    \\.fig svg{min-width:0;max-width:100%;}
    \\a{color:inherit;}
    \\}
;

const testing = std.testing;

fn testSpec(allocator: std.mem.Allocator, source: []const u8) !std.json.Parsed(system_review.SystemSpec) {
    return std.json.parseFromSlice(system_review.SystemSpec, allocator, source, .{});
}

const one_board_manifest =
    \\{"schema":"netlisp-system-review-v1","name":"demo","title":"Demo System","part_number":"SYS-1","revision":"A","boards":[{"name":"one","role":"main","source":"src/one.sexp","part_number":"ONE","revision":"A"}]}
;

const blocked_test_gates: Gates = .{
    .identity_ok = false,
    .interface_ok = false,
    .board_review_ok = false,
    .fab_ok = false,
    .checklists_ok = false,
};

const ready_test_gates: Gates = .{
    .identity_ok = true,
    .interface_ok = true,
    .board_review_ok = true,
    .fab_ok = true,
    .checklists_ok = true,
};

// spec: system-review - the offline HTML dossier is one self-contained file with no external request; its only executable content is the inlined read-only Assembly board viewer and the small shell that installs cached model sprites and drives board-side selection
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
        .state = .{ .blocked = true, .waiver = .none, .attested = false, .gates = blocked_test_gates },
        .checklist = .{},
    });
    try testing.expect(std.mem.startsWith(u8, html, "<!DOCTYPE html>"));
    try testing.expect(std.mem.indexOf(u8, html, "</html>") != null);
    // This board-free fixture needs no viewer script, and no construct can
    // fetch anything. The only absolute
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
    try testing.expect(std.mem.indexOf(u8, html, "<h4>Overview</h4>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "1 topic") != null);
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
        .state = .{ .blocked = true, .waiver = .none, .attested = false, .gates = blocked_test_gates },
        .checklist = .{},
    };
    const draft_html = try compose(allocator, &sections, options);
    try testing.expect(std.mem.indexOf(u8, draft_html, draft_marker) != null);
    try testing.expect(std.mem.indexOf(u8, draft_html, "System overview") != null);
    try testing.expect(std.mem.indexOf(u8, draft_html, "Interface control") != null);
    // Two documents, one system diagram, no boards, no supporting list.
    try testing.expect(std.mem.indexOf(u8, draft_html, "id=\"s3\"") != null);
    try testing.expect(std.mem.indexOf(u8, draft_html, "id=\"s4\"") == null);

    options.draft = false;
    options.state = .{ .blocked = false, .waiver = .none, .attested = true, .gates = ready_test_gates };
    const release_html = try compose(allocator, &sections, options);
    try testing.expect(std.mem.indexOf(u8, release_html, draft_marker) == null);
    try testing.expect(std.mem.indexOf(u8, release_html, release_marker) != null);
}

// spec: system-review - the dossier places its sticky section index beside the leading board gallery so the sidebar remains visible throughout the interactive board views and the one continuous evidence document, without repeating section titles
test "system review HTML is indexed and linear" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parsed = try testSpec(allocator, one_board_manifest);
    defer parsed.deinit();
    const sections = [_]Section{.{
        .title = "Release checklist",
        .classification = "checklist",
        .markdown = "# Release checklist\n\n```md\n- [ ] Example only\n```\n\n- [ ] Confirm identity\n+ [ ] Confirm fabrication\n",
        .checklist = .{ .total = 2, .open = 2 },
    }};
    const boards = [_]Board{.{
        .identity = .{
            .role = "main",
            .design = "one",
            .title = "One",
            .part_number = "ONE",
            .revision = "A",
            .layout = "layout-a",
            .generated_at = "2026-08-30T00:00:00Z",
        },
        .review = .{ .status = "pass", .open_notes = 0 },
        .fabrication = .ready,
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
        .state = .{
            .blocked = true,
            .waiver = .required,
            .attested = false,
            .gates = .{
                .identity_ok = true,
                .interface_ok = true,
                .board_review_ok = true,
                .fab_ok = false,
                .checklists_ok = false,
            },
        },
        .checklist = .{ .total = 2, .open = 2 },
        .boards = &boards,
    });
    try testing.expect(std.mem.indexOf(u8, html, "Executive summary") != null);
    try testing.expect(std.mem.indexOf(u8, html, "3 of 6 gates clear") != null);
    try testing.expect(std.mem.indexOf(u8, html, "2 open · 0/2 checks complete") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<aside class=\"section-index\"") != null);
    const aside = std.mem.indexOf(u8, html, "<aside class=\"section-index\"").?;
    const document = std.mem.indexOf(u8, html, "<main class=\"document\"").?;
    const gallery = std.mem.indexOf(u8, html, "<section class=\"board-gallery\"").?;
    try testing.expect(aside < document and document < gallery);
    try testing.expect(std.mem.indexOf(u8, html, ".section-index{position:sticky;top:18px") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<li><a href=\"#s1\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<section class=\"sec\" id=\"s1\">") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<details class=\"sec\"") == null);
    try testing.expect(std.mem.indexOf(u8, html, "<h3 class=\"sec-title\">Release checklist</h3>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<div class=\"prose\">\n<h1>Release checklist</h1>") == null);
    try testing.expect(std.mem.indexOf(u8, html, "<section class=\"print-evidence\">") == null);
}

// spec: system-review - the dossier leads with a structured gate summary and distinguishes waiver-required evidence from an accepted release waiver
test "system review HTML keeps waiver decisions explicit at system and board level" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parsed = try testSpec(allocator, one_board_manifest);
    defer parsed.deinit();
    const boards = [_]Board{.{
        .identity = .{
            .role = "main",
            .design = "one",
            .title = "One",
            .part_number = "ONE",
            .revision = "A",
            .layout = "layout-a",
            .generated_at = "2026-08-30T00:00:00Z",
        },
        .review = .{ .status = "warn", .open_notes = 0 },
        .fabrication = .waiver,
    }};
    var options: Options = .{
        .spec = &parsed.value,
        .draft = true,
        .provenance = .{
            .generated_at = "2026-08-30T00:00:00Z",
            .build_id = "test-build",
            .content_lock = "lock",
            .release_token = "token",
        },
        .state = .{ .blocked = false, .waiver = .required, .attested = true, .gates = ready_test_gates },
        .checklist = .{},
        .boards = &boards,
    };
    const required = try compose(allocator, &.{}, options);
    try testing.expect(std.mem.indexOf(u8, required, "WAIVER REQUIRED") != null);
    try testing.expect(std.mem.indexOf(u8, required, "Fab waiver required") != null);
    try testing.expect(std.mem.indexOf(u8, required, "href=\"#s2\"") != null);

    options.draft = false;
    options.state.waiver = .accepted;
    const accepted = try compose(allocator, &.{}, options);
    try testing.expect(std.mem.indexOf(u8, accepted, "APPROVED WITH WAIVER") != null);
    try testing.expect(std.mem.indexOf(u8, accepted, "Fab waiver accepted") != null);
    try testing.expect(std.mem.indexOf(u8, accepted, "accepted waiver evidence") != null);
}

// spec: system-review - every board leads the dossier with one Assembly physical-review viewer, defaulted to top and offering top/bottom selection plus the shared wheel/pinch zoom and drag-pan behavior; the viewer uses solder mask/exposed-copper rendering and deduplicated cached 3D-model sprites, no PCB-editor Layout figure is integrated, and the sidebar contains section navigation rather than interface-contact metrics
test "system review HTML leads with interactive physical board viewers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parsed = try testSpec(allocator, one_board_manifest);
    defer parsed.deinit();
    const png = "\x89PNG\r\n\x1a\nfixture";
    const sprites = [_]Board.Visual.Sprite{.{
        .footprint = "qfn-demo",
        .x = -1,
        .y = -1,
        .w = 2,
        .h = 2,
        .png = png,
    }};
    const boards = [_]Board{.{
        .identity = .{
            .role = "main",
            .design = "one",
            .title = "One",
            .part_number = "ONE",
            .revision = "A",
            .layout = "layout-a",
            .generated_at = "2026-08-30T00:00:00Z",
        },
        .review = .{ .status = "pass", .open_notes = 0 },
        .fabrication = .ready,
        .visual = .{
            .board_html = "<!doctype html><script>PCB.physical_review=true</script>",
            .sprites = &sprites,
        },
    }};
    const html = try compose(allocator, &.{.{
        .title = "System overview",
        .classification = "design",
        .markdown = "Overview.\n",
    }}, .{
        .spec = &parsed.value,
        .draft = true,
        .provenance = .{
            .generated_at = "2026-08-30T00:00:00Z",
            .build_id = "test-build",
            .content_lock = "lock",
            .release_token = "token",
        },
        .state = .{ .blocked = false, .waiver = .none, .attested = true, .gates = ready_test_gates },
        .checklist = .{},
        .boards = &boards,
    });
    const workspace = std.mem.indexOf(u8, html, "<div class=\"workspace\">").?;
    const aside = std.mem.indexOf(u8, html, "<aside class=\"section-index\"").?;
    const document = std.mem.indexOf(u8, html, "<main class=\"document\"").?;
    const gallery = std.mem.indexOf(u8, html, "<section class=\"board-gallery\"").?;
    try testing.expect(workspace < aside and aside < document and document < gallery);
    try testing.expect(std.mem.indexOf(u8, html, ".section-index{position:sticky;top:18px") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, html, "data:image/png;base64,"));
    try testing.expect(std.mem.indexOf(u8, html, "class=\"assembly-frame\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "data-side=\"top\" aria-pressed=\"true\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "data-side=\"bottom\" aria-pressed=\"false\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "netlisp-pcb-orientation") != null);
    try testing.expect(std.mem.indexOf(u8, html, "PCBSetAssemblySprite") != null);
    try testing.expect(std.mem.indexOf(u8, html, "\\u003cscript>PCB.physical_review=true\\u003c/script>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "PCB Layout</span>") == null);
    try testing.expect(std.mem.indexOf(u8, html, "class=\"layout-view\"") == null);
    const aside_start = aside;
    const aside_end_rel = std.mem.indexOf(u8, html[aside_start..], "</aside>").?;
    try testing.expect(std.mem.indexOf(u8, html[aside_start .. aside_start + aside_end_rel], "Interface contacts") == null);
    try testing.expect(std.mem.indexOf(u8, html, "href=\"#board-views\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "href=\"#executive-summary\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "href=\"#s1\"") != null);
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
        .fabrication = .ready,
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
        .state = .{ .blocked = true, .waiver = .none, .attested = false, .gates = blocked_test_gates },
        .checklist = .{},
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
        .fabrication = .ready,
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
        .state = .{ .blocked = true, .waiver = .none, .attested = false, .gates = blocked_test_gates },
        .checklist = .{},
        .boards = &drawn_boards,
    };
    const with_diagram = try compose(allocator, &[_]Section{}, options);
    try testing.expect(std.mem.indexOf(u8, with_diagram, drawn) != null);
    try testing.expect(std.mem.indexOf(u8, with_diagram, "class=\"fig dark\"") != null);
    try testing.expect(std.mem.indexOf(u8, with_diagram, "<h4>Archived evidence</h4>") != null);
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
        .state = .{ .blocked = true, .waiver = .required, .attested = false, .gates = blocked_test_gates },
        .checklist = .{},
        .supporting = &supporting,
    };
    const first = try compose(allocator, &sections, options);
    const second = try compose(allocator, &sections, options);
    try testing.expectEqualStrings(first, second);
    try testing.expect(std.mem.indexOf(u8, first, "../review/demo/icd.md") != null);
}
