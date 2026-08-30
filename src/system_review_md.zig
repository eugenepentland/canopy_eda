//! Safe, bounded Markdown for authored system-review documents.
//!
//! This is intentionally not a general CommonMark implementation. Review
//! packages need a small, deterministic vocabulary that renders the same way
//! in the browser, in the exported Markdown, and in a later native PDF writer:
//! headings, paragraphs, flat lists/checklists, pipe tables, fenced code,
//! local links/images, and whole-line `{{netlisp:...}}` expansion markers.
//!
//! Parsing performs every security decision. Renderers therefore consume an
//! inert AST: raw HTML, active/remote URLs, non-canonical paths, traversal,
//! malformed or unapproved directives, and unbounded inputs never reach an
//! output writer. Package-owned generated-region HTML comments must be removed
//! or expanded before parsing; if leaked through, they are rejected as raw
//! HTML. Directive blocks remain in the public AST so a higher layer can
//! replace them with generated engineering evidence before rendering PDF.

const std = @import("std");
const escape = @import("escape.zig");

const Allocator = std.mem.Allocator;
const directive_prefix = "{{netlisp:";

/// Resource ceilings applied before or during parsing.
pub const Limits = struct {
    source_bytes: usize = 2 * 1024 * 1024,
    line_bytes: usize = 32 * 1024,
    blocks: usize = 4096,
    inlines: usize = 64 * 1024,
    list_items: usize = 8192,
    table_rows: usize = 4096,
    table_columns: usize = 32,
};

/// Parser policy: a directive allowlist plus bounded resource ceilings.
pub const Options = struct {
    /// The only directive names accepted by this document. Empty means no
    /// directives are permitted; package policy owns the allowlist.
    allowed_directives: []const []const u8 = &.{},
    limits: Limits = .{},
};

/// Allocation, syntax, structural, and safety failures returned by `parse`.
pub const ParseError = Allocator.Error || error{
    DocumentTooLarge,
    LineTooLong,
    LimitExceeded,
    InvalidUtf8,
    InvalidControlCharacter,
    InvalidHeading,
    InvalidList,
    InvalidChecklist,
    InvalidTable,
    InvalidFence,
    UnclosedFence,
    UnclosedCodeSpan,
    RawHtml,
    RemoteUrl,
    UnsafePath,
    UnsafeImage,
    MalformedDirective,
    UnknownDirective,
};

/// Per-column table alignment supported by the bounded profile.
pub const Alignment = enum { none, left, center, right };

/// A plain-text label and validated package-relative target.
pub const Link = struct {
    label: []const u8,
    target: []const u8,
};

/// A plain-text alternative and validated package-relative image target.
pub const Image = struct {
    alt: []const u8,
    target: []const u8,
};

/// Inline content is deliberately flat. Link labels, image alt text, and
/// emphasis bodies are plain strings; nested markup is outside the
/// review-document profile.
pub const Inline = union(enum) {
    text: []const u8,
    code: []const u8,
    /// `**strong**` body, already unescaped and free of further markup.
    strong: []const u8,
    /// `*em*` body, already unescaped and free of further markup.
    em: []const u8,
    link: Link,
    image: Image,
};

/// One parsed heading with its level and inline content.
pub const Heading = struct {
    level: u3,
    content: []const Inline,
};

/// One paragraph; source soft lines are normalized to spaces.
pub const Paragraph = struct {
    content: []const Inline,
};

/// Flat ordered and unordered list styles.
pub const ListKind = enum { unordered, ordered };

/// One ordinary list item or checklist task.
pub const ListItem = struct {
    /// Null is an ordinary item; false/true are unchecked/checked tasks.
    checked: ?bool = null,
    content: []const Inline,
};

/// A flat list with a stable ordered-list start value.
pub const List = struct {
    kind: ListKind,
    start: usize = 1,
    items: []const ListItem,
};

/// One table cell containing flat inline content.
pub const Cell = struct {
    content: []const Inline,
};

/// A rectangular pipe table with explicit column alignments.
pub const Table = struct {
    header: []const Cell,
    alignments: []const Alignment,
    rows: []const []const Cell,
};

/// Literal fenced-code content and its optional language token.
pub const CodeBlock = struct {
    language: ?[]const u8 = null,
    text: []const u8,
};

/// A line-only tool expansion marker. `argument` is an uninterpreted, safe
/// string; the package layer owns each directive's argument grammar.
pub const Directive = struct {
    name: []const u8,
    argument: []const u8 = "",
};

/// Top-level nodes accepted by the review-document profile.
pub const Block = union(enum) {
    heading: Heading,
    paragraph: Paragraph,
    list: List,
    table: Table,
    code: CodeBlock,
    directive: Directive,
};

/// Arena-owned document. Every string and nested slice in `blocks` remains
/// valid until `deinit`; callers may walk this AST directly for PDF layout.
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    blocks: []const Block,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }

    /// Count tasks that still require explicit review completion.
    pub fn uncheckedChecklistCount(self: *const Document) usize {
        var count: usize = 0;
        for (self.blocks) |block| switch (block) {
            .list => |list| for (list.items) |item| {
                if (item.checked != null and !item.checked.?) count += 1;
            },
            else => {},
        };
        return count;
    }
};

const LocatedInline = struct {
    node: Inline,
    next: usize,
};

const Parser = struct {
    allocator: Allocator,
    options: Options,
    inline_count: usize = 0,
    list_item_count: usize = 0,
    table_row_count: usize = 0,

    fn takeInline(self: *Parser) ParseError!void {
        self.inline_count += 1;
        if (self.inline_count > self.options.limits.inlines) return error.LimitExceeded;
    }

    fn appendText(
        self: *Parser,
        nodes: *std.ArrayList(Inline),
        scratch: *std.ArrayList(u8),
    ) ParseError!void {
        if (scratch.items.len == 0) return;
        if (containsRemoteReference(scratch.items)) return error.RemoteUrl;
        try self.takeInline();
        try nodes.append(self.allocator, .{ .text = try self.allocator.dupe(u8, scratch.items) });
        scratch.clearRetainingCapacity();
    }

    fn plainLabel(self: *Parser, raw: []const u8) ParseError![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '\\' and i + 1 < raw.len) {
                i += 1;
                try out.append(self.allocator, raw[i]);
                continue;
            }
            if (raw[i] == '<' and beginsRawHtml(raw, i)) return error.RawHtml;
            try out.append(self.allocator, raw[i]);
        }
        if (containsRemoteReference(out.items)) return error.RemoteUrl;
        return out.toOwnedSlice(self.allocator);
    }

    fn parseLink(
        self: *Parser,
        source: []const u8,
        at: usize,
        next_label_end: *usize,
    ) ParseError!?LocatedInline {
        const image = source[at] == '!' and at + 1 < source.len and source[at + 1] == '[';
        if (!image and source[at] != '[') return null;

        const label_start = at + @as(usize, if (image) 2 else 1);
        if (next_label_end.* < label_start) {
            next_label_end.* = findUnescaped(source, label_start, ']') orelse source.len;
        }
        if (next_label_end.* == source.len) return null;
        const label_end = next_label_end.*;
        if (label_end + 1 >= source.len or source[label_end + 1] != '(') return null;

        const target_start = label_end + 2;
        const target_end = findUnescaped(source, target_start, ')') orelse return error.UnsafePath;
        const raw_target = std.mem.trim(u8, source[target_start..target_end], " \t");
        try validateLocalTarget(raw_target, image);
        const label = try self.plainLabel(source[label_start..label_end]);
        const target = try self.allocator.dupe(u8, raw_target);
        return .{
            .node = if (image)
                .{ .image = .{ .alt = label, .target = target } }
            else
                .{ .link = .{ .label = label, .target = target } },
            .next = target_end + 1,
        };
    }

    fn parseInlines(self: *Parser, source: []const u8) ParseError![]const Inline {
        var nodes: std.ArrayList(Inline) = .empty;
        var text: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        var next_label_end: usize = 0;
        while (i < source.len) {
            const c = source[i];
            if (c == '\\' and i + 1 < source.len) {
                try text.append(self.allocator, source[i + 1]);
                i += 2;
                continue;
            }
            if (c == '<' and beginsRawHtml(source, i)) return error.RawHtml;

            if (c == '`') {
                const close = std.mem.indexOfScalarPos(u8, source, i + 1, '`') orelse
                    return error.UnclosedCodeSpan;
                try self.appendText(&nodes, &text);
                try self.takeInline();
                try nodes.append(self.allocator, .{ .code = try self.allocator.dupe(u8, source[i + 1 .. close]) });
                i = close + 1;
                continue;
            }

            if (c == '*') {
                if (emphasisSpan(source, i)) |span| {
                    try self.appendText(&nodes, &text);
                    try self.takeInline();
                    const body = try self.plainLabel(span.body);
                    try nodes.append(self.allocator, switch (span.kind) {
                        .strong => Inline{ .strong = body },
                        .em => Inline{ .em = body },
                    });
                    i = span.next;
                    continue;
                }
            }

            if (try self.parseLink(source, i, &next_label_end)) |located| {
                try self.appendText(&nodes, &text);
                try self.takeInline();
                try nodes.append(self.allocator, located.node);
                i = located.next;
                continue;
            }

            try text.append(self.allocator, c);
            i += 1;
        }
        try self.appendText(&nodes, &text);
        return nodes.toOwnedSlice(self.allocator);
    }

    fn directive(self: *Parser, line: []const u8) ParseError!Directive {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, directive_prefix) or
            !std.mem.endsWith(u8, trimmed, "}}")) return error.MalformedDirective;
        const body = std.mem.trim(u8, trimmed[directive_prefix.len .. trimmed.len - 2], " \t");
        if (body.len == 0) return error.MalformedDirective;

        var split = body.len;
        for (body, 0..) |c, index| if (c == ' ' or c == '\t') {
            split = index;
            break;
        };
        const name = body[0..split];
        if (!validDirectiveName(name)) return error.MalformedDirective;
        if (!self.directiveAllowed(name)) return error.UnknownDirective;
        const argument = std.mem.trim(u8, body[split..], " \t");
        if (std.mem.indexOfAny(u8, argument, "{}<>\r\n\x00") != null) return error.MalformedDirective;
        if (containsRemoteReference(argument)) return error.RemoteUrl;
        return .{
            .name = try self.allocator.dupe(u8, name),
            .argument = try self.allocator.dupe(u8, argument),
        };
    }

    fn directiveAllowed(self: *const Parser, name: []const u8) bool {
        for (self.options.allowed_directives) |allowed| {
            if (std.mem.eql(u8, name, allowed)) return true;
        }
        return false;
    }
};

const ListLead = struct {
    kind: ListKind,
    start: usize,
    body: []const u8,
};

/// Parse one bounded review document. The returned document owns all of its
/// storage, while `options.allowed_directives` is consulted only during this
/// call and may be temporary.
pub fn parse(parent: Allocator, source: []const u8, options: Options) ParseError!Document {
    if (source.len > options.limits.source_bytes) return error.DocumentTooLarge;
    if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidUtf8;
    try validateControls(source);

    var arena = std.heap.ArenaAllocator.init(parent);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    const normalized = try normalizeNewlines(allocator, source);

    var lines: std.ArrayList([]const u8) = .empty;
    var iter = std.mem.splitScalar(u8, normalized, '\n');
    const line_limit = std.math.mul(usize, options.limits.blocks, 16) catch return error.LimitExceeded;
    while (iter.next()) |line| {
        if (lines.items.len >= line_limit) return error.LimitExceeded;
        if (line.len > options.limits.line_bytes) return error.LineTooLong;
        try lines.append(allocator, line);
    }

    var parser = Parser{ .allocator = allocator, .options = options };
    var blocks: std.ArrayList(Block) = .empty;
    var index: usize = 0;
    while (index < lines.items.len) {
        const line = lines.items[index];
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) {
            index += 1;
            continue;
        }

        if (blocks.items.len >= options.limits.blocks) return error.LimitExceeded;

        if (std.mem.indexOf(u8, line, directive_prefix) != null) {
            try blocks.append(allocator, .{ .directive = try parser.directive(line) });
            index += 1;
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "```")) {
            try blocks.append(allocator, .{ .code = try parseFence(&parser, lines.items, &index) });
            continue;
        }

        if (trimmed[0] == '#') {
            try blocks.append(allocator, .{ .heading = try parseHeading(&parser, trimmed) });
            index += 1;
            continue;
        }

        if (nestedListMarker(line)) return error.InvalidList;
        if (listLead(line) != null) {
            try blocks.append(allocator, .{ .list = try parseList(&parser, lines.items, &index) });
            continue;
        }

        if (index + 1 < lines.items.len and hasUnescapedPipe(line) and
            delimiterLooksValid(lines.items[index + 1]))
        {
            try blocks.append(allocator, .{ .table = try parseTable(&parser, lines.items, &index) });
            continue;
        }

        try blocks.append(allocator, .{ .paragraph = try parseParagraph(&parser, lines.items, &index) });
    }

    return .{ .arena = arena, .blocks = try blocks.toOwnedSlice(allocator) };
}

fn validateControls(source: []const u8) ParseError!void {
    for (source) |c| {
        if (c < 0x20 and c != '\t' and c != '\n' and c != '\r')
            return error.InvalidControlCharacter;
        if (c == 0x7f) return error.InvalidControlCharacter;
    }
}

fn normalizeNewlines(allocator: Allocator, source: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\r') {
            if (i + 1 < source.len and source[i + 1] == '\n') i += 1;
            try out.append(allocator, '\n');
        } else {
            try out.append(allocator, source[i]);
        }
    }
    return out.toOwnedSlice(allocator);
}

const EmphasisKind = enum { strong, em };

const EmphasisSpan = struct {
    kind: EmphasisKind,
    /// Still-escaped source body; `plainLabel` owns unescaping and safety.
    body: []const u8,
    next: usize,
};

/// Recognise one balanced `**strong**` or `*em*` run beginning at `at`.
///
/// The grammar is deliberately flat and single-pass, matching the rest of this
/// profile: the body must be non-empty, must not begin or end with a space or
/// tab, and must contain no further unescaped `*`. Anything else — an unclosed
/// marker, an empty or space-padded run, or nested emphasis — is not a span,
/// so the caller keeps the asterisks as ordinary literal text instead of
/// failing the document. `_`/`__` are deliberately NOT emphasis markers:
/// review prose is full of net and identifier names such as `VCC_3V3_SENSE`,
/// and silently emphasising them would change how existing authored documents
/// canonicalize.
fn emphasisSpan(source: []const u8, at: usize) ?EmphasisSpan {
    if (source[at] != '*') return null;
    const strong = at + 1 < source.len and source[at + 1] == '*';
    const marker: usize = if (strong) 2 else 1;
    var i = at + marker;
    const start = i;
    const close = while (i < source.len) : (i += 1) {
        if (source[i] == '\\') {
            i += @intFromBool(i + 1 < source.len);
            continue;
        }
        if (source[i] != '*') continue;
        if (!strong) break i;
        // A lone `*` inside a `**` run is nested emphasis, which this profile
        // does not model; the whole run degrades to literal text.
        if (i + 1 >= source.len or source[i + 1] != '*') return null;
        break i;
    } else return null;

    const body = source[start..close];
    if (body.len == 0) return null;
    if (body[0] == ' ' or body[0] == '\t') return null;
    if (body[body.len - 1] == ' ' or body[body.len - 1] == '\t') return null;
    return .{
        .kind = if (strong) .strong else .em,
        .body = body,
        .next = close + marker,
    };
}

/// Rewrite one already-rendered canonical Markdown line with its balanced
/// emphasis markers removed, appending to `out`. Unpaired markers and
/// backslash-escaped asterisks are preserved exactly. Consumers that lay out
/// Markdown text rather than the AST — the PDF composer — use this so a
/// `**strong**` run reads as words instead of literal asterisks.
pub fn stripEmphasis(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    line: []const u8,
) Allocator.Error!void {
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '\\' and i + 1 < line.len) {
            try out.appendSlice(allocator, line[i .. i + 2]);
            i += 2;
            continue;
        }
        if (line[i] == '*') {
            if (emphasisSpan(line, i)) |span| {
                try out.appendSlice(allocator, span.body);
                i = span.next;
                continue;
            }
        }
        try out.append(allocator, line[i]);
        i += 1;
    }
}

fn beginsRawHtml(source: []const u8, at: usize) bool {
    if (at + 1 >= source.len or source[at] != '<') return false;
    const next = source[at + 1];
    return std.ascii.isAlphabetic(next) or next == '/' or next == '!' or next == '?';
}

fn findUnescaped(source: []const u8, start: usize, needle: u8) ?usize {
    var i = start;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\\') {
            i += @intFromBool(i + 1 < source.len);
            continue;
        }
        if (source[i] == needle) return i;
    }
    return null;
}

fn containsRemoteReference(text: []const u8) bool {
    const hierarchical = [_][]const u8{ "http", "https", "ftp", "file" };
    const opaque_schemes = [_][]const u8{ "mailto", "javascript" };
    for (text, 0..) |_, at| {
        for (hierarchical) |scheme| {
            if (!matchesIgnoreCase(text, at, scheme)) continue;
            const suffix = at + scheme.len;
            if (suffix + 3 <= text.len and std.mem.eql(u8, text[suffix .. suffix + 3], "://")) return true;
        }
        for (opaque_schemes) |scheme| {
            if (!matchesIgnoreCase(text, at, scheme)) continue;
            const suffix = at + scheme.len;
            if (suffix < text.len and text[suffix] == ':') return true;
        }
        if (matchesIgnoreCase(text, at, "data")) {
            const suffix = at + "data".len;
            if (suffix + 1 < text.len and text[suffix] == ':' and
                !std.ascii.isWhitespace(text[suffix + 1])) return true;
        }
    }
    return false;
}

fn matchesIgnoreCase(text: []const u8, at: usize, prefix: []const u8) bool {
    if (at + prefix.len > text.len) return false;
    return std.ascii.eqlIgnoreCase(text[at .. at + prefix.len], prefix);
}

fn validDirectiveName(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isLower(name[0])) return false;
    for (name[1..]) |c| {
        if (std.ascii.isLower(c)) continue;
        if (std.ascii.isDigit(c)) continue;
        if (c == '-') continue;
        return false;
    }
    return true;
}

fn validateLocalTarget(target: []const u8, image: bool) ParseError!void {
    if (target.len == 0) return error.UnsafePath;
    if (std.mem.startsWith(u8, target, "//")) return error.RemoteUrl;
    if (target[0] == '/') return error.UnsafePath;
    if (std.mem.indexOfScalar(u8, target, ':') != null) return error.RemoteUrl;
    if (std.mem.indexOfAny(u8, target, "\\%?\x00\r\n\t <>\"'()") != null)
        return error.UnsafePath;

    const hash = std.mem.indexOfScalar(u8, target, '#');
    const path = if (hash) |at| target[0..at] else target;
    const fragment = if (hash) |at| target[at + 1 ..] else "";
    if (hash != null and fragment.len == 0) return error.UnsafePath;
    if (path.len == 0) {
        if (image) return error.UnsafeImage;
        return;
    }

    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or
            std.mem.eql(u8, segment, "..")) return error.UnsafePath;
    }

    if (image and !hasImageExtension(path)) return error.UnsafeImage;
}

fn hasImageExtension(path: []const u8) bool {
    const extensions = [_][]const u8{ ".png", ".jpg", ".jpeg", ".svg" };
    for (extensions) |extension| {
        if (path.len >= extension.len and
            std.ascii.eqlIgnoreCase(path[path.len - extension.len ..], extension)) return true;
    }
    return false;
}

fn parseHeading(parser: *Parser, line: []const u8) ParseError!Heading {
    var level: usize = 0;
    while (level < line.len and line[level] == '#') level += 1;
    if (level == 0 or level > 6 or level >= line.len or line[level] != ' ')
        return error.InvalidHeading;
    const body = std.mem.trim(u8, line[level + 1 ..], " \t");
    if (body.len == 0) return error.InvalidHeading;
    return .{ .level = @intCast(level), .content = try parser.parseInlines(body) };
}

fn listLead(line: []const u8) ?ListLead {
    if (line.len >= 2) {
        const bullet = line[0] == '-' or line[0] == '*' or line[0] == '+';
        if (bullet and line[1] == ' ')
            return .{ .kind = .unordered, .start = 1, .body = line[2..] };
    }

    var digits: usize = 0;
    while (digits < line.len and std.ascii.isDigit(line[digits])) digits += 1;
    if (digits == 0 or digits + 1 >= line.len or line[digits] != '.' or line[digits + 1] != ' ')
        return null;
    const start = std.fmt.parseInt(usize, line[0..digits], 10) catch return null;
    if (start == 0) return null;
    return .{ .kind = .ordered, .start = start, .body = line[digits + 2 ..] };
}

fn nestedListMarker(line: []const u8) bool {
    if (line.len == 0 or (line[0] != ' ' and line[0] != '\t')) return false;
    return listLead(std.mem.trimStart(u8, line, " \t")) != null;
}

const ChecklistLead = struct {
    checked: bool,
    body: []const u8,
};

fn checklistLead(body: []const u8) ParseError!?ChecklistLead {
    if (body.len < 3) return null;
    if (body[0] != '[' or body[2] != ']') return null;
    const checked = switch (body[1]) {
        ' ' => false,
        'x', 'X' => true,
        else => return null,
    };
    if (body.len < 4 or body[3] != ' ') return error.InvalidChecklist;
    return .{ .checked = checked, .body = body[4..] };
}

fn parseList(parser: *Parser, lines: []const []const u8, index: *usize) ParseError!List {
    const first = listLead(lines[index.*]) orelse return error.InvalidList;
    var items: std.ArrayList(ListItem) = .empty;
    var at = index.*;
    while (at < lines.len) {
        if (nestedListMarker(lines[at])) return error.InvalidList;
        const lead = listLead(lines[at]) orelse break;
        if (lead.kind != first.kind) break;
        var body = std.mem.trim(u8, lead.body, " \t");
        var checked: ?bool = null;
        if (try checklistLead(body)) |task| {
            checked = task.checked;
            body = std.mem.trim(u8, task.body, " \t");
        }
        if (body.len == 0) return error.InvalidList;
        at += 1;

        // A wrapped item keeps its continuation lines. Anything that opens a
        // block of its own — a blank line, a new marker, a heading, fence,
        // table, or directive — ends the item, and a blank line ends the list.
        var joined: std.ArrayList(u8) = .empty;
        try joined.appendSlice(parser.allocator, body);
        while (at < lines.len and !startsBlock(lines, at)) : (at += 1) {
            const piece = std.mem.trim(u8, lines[at], " \t");
            try joined.append(parser.allocator, ' ');
            try joined.appendSlice(parser.allocator, piece);
        }

        parser.list_item_count += 1;
        if (parser.list_item_count > parser.options.limits.list_items) return error.LimitExceeded;
        try items.append(parser.allocator, .{
            .checked = checked,
            .content = try parser.parseInlines(joined.items),
        });
    }
    index.* = at;
    if (first.kind == .ordered and items.items.len > 0 and
        items.items.len - 1 > std.math.maxInt(usize) - first.start)
        return error.InvalidList;
    return .{ .kind = first.kind, .start = first.start, .items = try items.toOwnedSlice(parser.allocator) };
}

fn hasUnescapedPipe(line: []const u8) bool {
    var escaped = false;
    for (line) |c| {
        if (escaped) {
            escaped = false;
        } else if (c == '\\') {
            escaped = true;
        } else if (c == '|') {
            return true;
        }
    }
    return false;
}

fn splitTableCells(allocator: Allocator, line: []const u8) Allocator.Error![]const []const u8 {
    var body = std.mem.trim(u8, line, " \t");
    if (body.len > 0 and body[0] == '|') body = body[1..];
    body = std.mem.trimEnd(u8, body, " \t");
    if (body.len > 0 and body[body.len - 1] == '|' and
        (body.len < 2 or body[body.len - 2] != '\\')) body = body[0 .. body.len - 1];

    var cells: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var escaped = false;
    for (body, 0..) |c, at| {
        if (escaped) {
            escaped = false;
        } else if (c == '\\') {
            escaped = true;
        } else if (c == '|') {
            try cells.append(allocator, std.mem.trim(u8, body[start..at], " \t"));
            start = at + 1;
        }
    }
    try cells.append(allocator, std.mem.trim(u8, body[start..], " \t"));
    return cells.toOwnedSlice(allocator);
}

fn delimiterAlignment(cell: []const u8) ?Alignment {
    const trimmed = std.mem.trim(u8, cell, " \t");
    if (trimmed.len < 3) return null;
    const left = trimmed[0] == ':';
    const right = trimmed[trimmed.len - 1] == ':';
    const start: usize = @intFromBool(left);
    const end = trimmed.len - @as(usize, @intFromBool(right));
    if (end - start < 3) return null;
    for (trimmed[start..end]) |c| if (c != '-') return null;
    return if (left and right) .center else if (left) .left else if (right) .right else .none;
}

fn delimiterLooksValid(line: []const u8) bool {
    var body = std.mem.trim(u8, line, " \t");
    if (body.len > 0 and body[0] == '|') body = body[1..];
    if (body.len > 0 and body[body.len - 1] == '|') body = body[0 .. body.len - 1];
    var cells = std.mem.splitScalar(u8, body, '|');
    var count: usize = 0;
    while (cells.next()) |cell| {
        if (delimiterAlignment(cell) == null) return false;
        count += 1;
    }
    return count > 0;
}

fn parseCells(parser: *Parser, raw: []const []const u8) ParseError![]const Cell {
    var cells: std.ArrayList(Cell) = .empty;
    for (raw) |source| try cells.append(parser.allocator, .{ .content = try parser.parseInlines(source) });
    return cells.toOwnedSlice(parser.allocator);
}

fn parseTable(parser: *Parser, lines: []const []const u8, index: *usize) ParseError!Table {
    const header_raw = try splitTableCells(parser.allocator, lines[index.*]);
    const delimiter_raw = try splitTableCells(parser.allocator, lines[index.* + 1]);
    if (header_raw.len == 0 or header_raw.len != delimiter_raw.len or
        header_raw.len > parser.options.limits.table_columns) return error.InvalidTable;

    var alignments: std.ArrayList(Alignment) = .empty;
    for (delimiter_raw) |cell| {
        try alignments.append(parser.allocator, delimiterAlignment(cell) orelse return error.InvalidTable);
    }

    var rows: std.ArrayList([]const Cell) = .empty;
    var at = index.* + 2;
    while (at < lines.len) : (at += 1) {
        const trimmed = std.mem.trim(u8, lines[at], " \t");
        if (trimmed.len == 0 or !hasUnescapedPipe(lines[at])) break;
        const raw = try splitTableCells(parser.allocator, lines[at]);
        if (raw.len != header_raw.len) return error.InvalidTable;
        parser.table_row_count += 1;
        if (parser.table_row_count > parser.options.limits.table_rows) return error.LimitExceeded;
        try rows.append(parser.allocator, try parseCells(parser, raw));
    }
    index.* = at;
    return .{
        .header = try parseCells(parser, header_raw),
        .alignments = try alignments.toOwnedSlice(parser.allocator),
        .rows = try rows.toOwnedSlice(parser.allocator),
    };
}

fn validLanguage(language: []const u8) bool {
    for (language) |c| {
        if (std.ascii.isAlphanumeric(c)) continue;
        if (c == '_' or c == '+' or c == '-') continue;
        return false;
    }
    return true;
}

fn parseFence(parser: *Parser, lines: []const []const u8, index: *usize) ParseError!CodeBlock {
    const opener = std.mem.trim(u8, lines[index.*], " \t");
    if (!std.mem.startsWith(u8, opener, "```") or
        (opener.len > 3 and opener[3] == '`')) return error.InvalidFence;
    const language = std.mem.trim(u8, opener[3..], " \t");
    if (!validLanguage(language)) return error.InvalidFence;

    var text: std.ArrayList(u8) = .empty;
    var at = index.* + 1;
    var first = true;
    while (at < lines.len) : (at += 1) {
        if (std.mem.eql(u8, std.mem.trim(u8, lines[at], " \t"), "```")) {
            index.* = at + 1;
            return .{
                .language = if (language.len == 0) null else try parser.allocator.dupe(u8, language),
                .text = try text.toOwnedSlice(parser.allocator),
            };
        }
        if (!first) try text.append(parser.allocator, '\n');
        first = false;
        try text.appendSlice(parser.allocator, lines[at]);
    }
    return error.UnclosedFence;
}

fn startsBlock(lines: []const []const u8, at: usize) bool {
    if (at >= lines.len) return false;
    const line = lines[at];
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return true;
    if (std.mem.indexOf(u8, line, directive_prefix) != null) return true;
    if (std.mem.startsWith(u8, trimmed, "```") or trimmed[0] == '#') return true;
    if (listLead(line) != null or nestedListMarker(line)) return true;
    return at + 1 < lines.len and hasUnescapedPipe(line) and delimiterLooksValid(lines[at + 1]);
}

fn parseParagraph(parser: *Parser, lines: []const []const u8, index: *usize) ParseError!Paragraph {
    var joined: std.ArrayList(u8) = .empty;
    var at = index.*;
    while (at < lines.len and (at == index.* or !startsBlock(lines, at))) : (at += 1) {
        const piece = std.mem.trim(u8, lines[at], " \t");
        if (piece.len == 0) break;
        if (std.mem.indexOf(u8, piece, directive_prefix) != null) return error.MalformedDirective;
        if (joined.items.len > 0) try joined.append(parser.allocator, ' ');
        try joined.appendSlice(parser.allocator, piece);
    }
    index.* = at;
    return .{ .content = try parser.parseInlines(joined.items) };
}

/// Allocation or output failures returned by allocating render helpers.
pub const RenderError = Allocator.Error || std.Io.Writer.Error;

/// Emit one canonical Markdown representation. Re-parsing this output with the
/// same directive allowlist produces an equivalent AST.
pub fn renderMarkdown(writer: *std.Io.Writer, document: *const Document) std.Io.Writer.Error!void {
    for (document.blocks, 0..) |block, block_index| {
        if (block_index > 0) try writer.writeByte('\n');
        try writeMarkdownBlock(writer, block);
    }
}

fn writeMarkdownBlock(writer: *std.Io.Writer, block: Block) std.Io.Writer.Error!void {
    switch (block) {
        .heading => |heading| {
            try writer.writeAll("######"[0..heading.level]);
            try writer.writeByte(' ');
            try writeMarkdownInlines(writer, heading.content, false, false);
            try writer.writeByte('\n');
        },
        .paragraph => |paragraph| {
            try writeMarkdownInlines(writer, paragraph.content, true, false);
            try writer.writeByte('\n');
        },
        .list => |list| try writeMarkdownList(writer, list),
        .table => |table| try writeMarkdownTable(writer, table),
        .code => |code| {
            try writer.writeAll("```");
            if (code.language) |language| try writer.writeAll(language);
            try writer.writeByte('\n');
            if (code.text.len > 0) {
                try writer.writeAll(code.text);
                try writer.writeByte('\n');
            }
            try writer.writeAll("```\n");
        },
        .directive => |directive| {
            try writer.print("{{{{netlisp:{s}", .{directive.name});
            if (directive.argument.len > 0) try writer.print(" {s}", .{directive.argument});
            try writer.writeAll("}}\n");
        },
    }
}

fn writeMarkdownList(writer: *std.Io.Writer, list: List) std.Io.Writer.Error!void {
    for (list.items, 0..) |item, item_index| {
        if (list.kind == .ordered) {
            const number = std.math.add(usize, list.start, item_index) catch return error.WriteFailed;
            try writer.print("{d}. ", .{number});
        } else {
            try writer.writeAll("- ");
        }
        if (item.checked) |checked| try writer.writeAll(if (checked) "[x] " else "[ ] ");
        try writeMarkdownInlines(writer, item.content, false, false);
        try writer.writeByte('\n');
    }
}

fn writeMarkdownTable(writer: *std.Io.Writer, table: Table) std.Io.Writer.Error!void {
    try writeMarkdownRow(writer, table.header);
    try writer.writeAll("| ");
    for (table.alignments, 0..) |alignment, index| {
        if (index > 0) try writer.writeAll(" | ");
        try writer.writeAll(switch (alignment) {
            .none => "---",
            .left => ":---",
            .center => ":---:",
            .right => "---:",
        });
    }
    try writer.writeAll(" |\n");
    for (table.rows) |row| try writeMarkdownRow(writer, row);
}

fn writeMarkdownRow(writer: *std.Io.Writer, row: []const Cell) std.Io.Writer.Error!void {
    try writer.writeAll("| ");
    for (row, 0..) |cell, index| {
        if (index > 0) try writer.writeAll(" | ");
        try writeMarkdownInlines(writer, cell.content, false, true);
    }
    try writer.writeAll(" |\n");
}

const MarkdownPrefix = enum { start, digits, other };

fn writeMarkdownText(
    writer: *std.Io.Writer,
    text: []const u8,
    table_cell: bool,
    prefix: *MarkdownPrefix,
) std.Io.Writer.Error!void {
    for (text) |c| {
        var escape_character = switch (c) {
            '!', '$', '&', '*', '[', '\\', ']', '^', '_', '`', '{', '|', '}', '~', '<', '>' => true,
            else => false,
        };
        if (!table_cell and c == '|') escape_character = false;
        const block_marker = switch (c) {
            '#', '+', '-', '>' => true,
            else => false,
        };
        if (prefix.* == .start and block_marker) escape_character = true;
        if (prefix.* == .digits and (c == '.' or c == ')')) escape_character = true;
        if (escape_character) try writer.writeByte('\\');
        try writer.writeByte(c);

        prefix.* = switch (prefix.*) {
            .start => if (std.ascii.isDigit(c)) .digits else .other,
            .digits => if (std.ascii.isDigit(c)) .digits else .other,
            .other => .other,
        };
    }
}

fn writeMarkdownInlines(
    writer: *std.Io.Writer,
    nodes: []const Inline,
    block_start: bool,
    table_cell: bool,
) std.Io.Writer.Error!void {
    var prefix: MarkdownPrefix = if (block_start) .start else .other;
    for (nodes) |node| switch (node) {
        .text => |text| try writeMarkdownText(writer, text, table_cell, &prefix),
        .code => |code| {
            try writer.print("`{s}`", .{code});
            prefix = .other;
        },
        .strong, .em => |body, tag| {
            const marker = if (tag == .strong) "**" else "*";
            try writer.writeAll(marker);
            // The body escaper turns every `*` back into `\*`, so the closing
            // marker below is always the first unescaped one on re-parse.
            var body_prefix: MarkdownPrefix = .other;
            try writeMarkdownText(writer, body, table_cell, &body_prefix);
            try writer.writeAll(marker);
            prefix = .other;
        },
        .link => |link| {
            try writer.writeByte('[');
            var label_prefix: MarkdownPrefix = .other;
            try writeMarkdownText(writer, link.label, table_cell, &label_prefix);
            try writer.print("]({s})", .{link.target});
            prefix = .other;
        },
        .image => |image| {
            try writer.writeAll("![");
            var alt_prefix: MarkdownPrefix = .other;
            try writeMarkdownText(writer, image.alt, table_cell, &alt_prefix);
            try writer.print("]({s})", .{image.target});
            prefix = .other;
        },
    };
}

/// Emit an inert HTML fragment. It contains no style/script elements and no
/// remote references; unresolved directives become empty, data-only markers.
pub fn renderHtml(writer: *std.Io.Writer, document: *const Document) std.Io.Writer.Error!void {
    for (document.blocks) |block| switch (block) {
        .heading => |heading| {
            try writer.print("<h{d}>", .{heading.level});
            try writeHtmlInlines(writer, heading.content);
            try writer.print("</h{d}>\n", .{heading.level});
        },
        .paragraph => |paragraph| {
            try writer.writeAll("<p>");
            try writeHtmlInlines(writer, paragraph.content);
            try writer.writeAll("</p>\n");
        },
        .list => |list| {
            if (list.kind == .ordered) {
                if (list.start == 1) {
                    try writer.writeAll("<ol>\n");
                } else {
                    try writer.print("<ol start=\"{d}\">\n", .{list.start});
                }
            } else try writer.writeAll("<ul>\n");
            for (list.items) |item| {
                if (item.checked) |checked| {
                    try writer.writeAll(if (checked)
                        "<li class=\"task checked\"><input type=\"checkbox\" disabled checked> "
                    else
                        "<li class=\"task unchecked\"><input type=\"checkbox\" disabled> ");
                } else try writer.writeAll("<li>");
                try writeHtmlInlines(writer, item.content);
                try writer.writeAll("</li>\n");
            }
            try writer.writeAll(if (list.kind == .ordered) "</ol>\n" else "</ul>\n");
        },
        .table => |table| {
            try writer.writeAll("<table>\n<thead><tr>");
            for (table.header, 0..) |cell, index| {
                try writer.writeAll("<th");
                try writeAlignmentClass(writer, table.alignments[index]);
                try writer.writeByte('>');
                try writeHtmlInlines(writer, cell.content);
                try writer.writeAll("</th>");
            }
            try writer.writeAll("</tr></thead>\n<tbody>\n");
            for (table.rows) |row| {
                try writer.writeAll("<tr>");
                for (row, 0..) |cell, index| {
                    try writer.writeAll("<td");
                    try writeAlignmentClass(writer, table.alignments[index]);
                    try writer.writeByte('>');
                    try writeHtmlInlines(writer, cell.content);
                    try writer.writeAll("</td>");
                }
                try writer.writeAll("</tr>\n");
            }
            try writer.writeAll("</tbody>\n</table>\n");
        },
        .code => |code| {
            try writer.writeAll("<pre><code");
            if (code.language) |language| {
                try writer.writeAll(" class=\"language-");
                try writeHtmlEscaped(writer, language);
                try writer.writeByte('"');
            }
            try writer.writeByte('>');
            try writeHtmlEscaped(writer, code.text);
            try writer.writeAll("</code></pre>\n");
        },
        .directive => |directive| {
            try writer.writeAll("<div class=\"netlisp-directive\" data-name=\"");
            try writeHtmlEscaped(writer, directive.name);
            try writer.writeByte('"');
            if (directive.argument.len > 0) {
                try writer.writeAll(" data-argument=\"");
                try writeHtmlEscaped(writer, directive.argument);
                try writer.writeByte('"');
            }
            try writer.writeAll("></div>\n");
        },
    };
}

fn writeAlignmentClass(writer: *std.Io.Writer, alignment: Alignment) std.Io.Writer.Error!void {
    if (alignment == .none) return;
    try writer.print(" class=\"align-{s}\"", .{@tagName(alignment)});
}

fn writeHtmlInlines(writer: *std.Io.Writer, nodes: []const Inline) std.Io.Writer.Error!void {
    for (nodes) |node| switch (node) {
        .text => |text| try writeHtmlEscaped(writer, text),
        .code => |code| {
            try writer.writeAll("<code>");
            try writeHtmlEscaped(writer, code);
            try writer.writeAll("</code>");
        },
        .strong => |body| {
            try writer.writeAll("<strong>");
            try writeHtmlEscaped(writer, body);
            try writer.writeAll("</strong>");
        },
        .em => |body| {
            try writer.writeAll("<em>");
            try writeHtmlEscaped(writer, body);
            try writer.writeAll("</em>");
        },
        .link => |link| {
            try writer.writeAll("<a href=\"");
            try writeHtmlEscaped(writer, link.target);
            try writer.writeAll("\">");
            try writeHtmlEscaped(writer, link.label);
            try writer.writeAll("</a>");
        },
        .image => |image| {
            try writer.writeAll("<img src=\"");
            try writeHtmlEscaped(writer, image.target);
            try writer.writeAll("\" alt=\"");
            try writeHtmlEscaped(writer, image.alt);
            try writer.writeAll("\">");
        },
    };
}

fn writeHtmlEscaped(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try escape.writeXml(writer, text);
}

/// Allocate and return the canonical Markdown representation.
pub fn renderMarkdownAlloc(allocator: Allocator, document: *const Document) RenderError![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try renderMarkdown(&out.writer, document);
    return out.toOwnedSlice();
}

/// Allocate and return an inert HTML fragment for the document.
pub fn renderHtmlAlloc(allocator: Allocator, document: *const Document) RenderError![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try renderHtml(&out.writer, document);
    return out.toOwnedSlice();
}

const testing = std.testing;

// spec: system_review_md - parses the complete bounded authoring profile into a public AST and renders stable Markdown and inert HTML
test "bounded profile parses and renders deterministically" {
    const source =
        \\# Barracuda review
        \\
        \\Engineering paragraph with `RSET`, a [local note](notes/rf.md#loop), and ![overview](assets/system.svg).
        \\
        \\- ordinary item
        \\- [ ] Confirm stackup
        \\- [X] Confirm connector map
        \\
        \\3. RF board
        \\4. Base board
        \\
        \\| Board | Status |
        \\| :--- | ---: |
        \\| RF | Ready |
        \\
        \\```zig
        \\const threshold = "<not html>";
        \\```
        \\
        \\{{netlisp:board-summary rf}}
    ;
    var document = try parse(testing.allocator, source, .{ .allowed_directives = &.{"board-summary"} });
    defer document.deinit();

    try testing.expectEqual(@as(usize, 7), document.blocks.len);
    try testing.expectEqual(@as(usize, 1), document.uncheckedChecklistCount());
    try testing.expect(document.blocks[0] == .heading);
    try testing.expect(document.blocks[2] == .list);
    try testing.expect(document.blocks[4] == .table);
    try testing.expect(document.blocks[6] == .directive);

    const markdown = try renderMarkdownAlloc(testing.allocator, &document);
    defer testing.allocator.free(markdown);
    const html = try renderHtmlAlloc(testing.allocator, &document);
    defer testing.allocator.free(html);

    try testing.expect(std.mem.indexOf(u8, markdown, "- [x] Confirm connector map") != null);
    try testing.expect(std.mem.indexOf(u8, markdown, "{{netlisp:board-summary rf}}") != null);
    try testing.expect(std.mem.indexOf(u8, html, "href=\"notes/rf.md#loop\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "src=\"assets/system.svg\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "&lt;not html&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, html, "data-name=\"board-summary\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<script") == null);

    var reparsed = try parse(testing.allocator, markdown, .{ .allowed_directives = &.{"board-summary"} });
    defer reparsed.deinit();
    const markdown_again = try renderMarkdownAlloc(testing.allocator, &reparsed);
    defer testing.allocator.free(markdown_again);
    try testing.expectEqualStrings(markdown, markdown_again);
}

// spec: system_review_md - renders paired asterisk emphasis as strong and em in both the Markdown and the HTML face, and canonicalizes back to the same source on re-parse
test "paired asterisk emphasis renders in every face" {
    const source =
        \\# Release **status**
        \\
        \\Release is **BLOCKED** and the *loop filter* is marginal. Bodies keep
        \\their own escaping, as in **A & B** and *R\*SET*.
        \\
        \\- [ ] Confirm the **stackup**
        \\
        \\| Board | Verdict |
        \\| --- | --- |
        \\| RF | **fail** |
    ;
    var document = try parse(testing.allocator, source, .{});
    defer document.deinit();

    const markdown = try renderMarkdownAlloc(testing.allocator, &document);
    defer testing.allocator.free(markdown);
    const html = try renderHtmlAlloc(testing.allocator, &document);
    defer testing.allocator.free(html);

    const expected_markdown =
        "# Release **status**\n" ++
        "\nRelease is **BLOCKED** and the *loop filter* is marginal. Bodies keep " ++
        "their own escaping, as in **A \\& B** and *R\\*SET*.\n" ++
        "\n- [ ] Confirm the **stackup**\n" ++
        "\n| Board | Verdict |\n| --- | --- |\n| RF | **fail** |\n";
    try testing.expectEqualStrings(expected_markdown, markdown);

    try testing.expect(std.mem.indexOf(u8, html, "<h1>Release <strong>status</strong></h1>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "is <strong>BLOCKED</strong> and the <em>loop filter</em>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<strong>A &amp; B</strong>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<em>R*SET</em>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "Confirm the <strong>stackup</strong>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<td><strong>fail</strong></td>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "**") == null);

    // Canonical Markdown is a fixed point: re-parsing and re-rendering it, and
    // rendering the same document twice, both reproduce these exact bytes.
    var reparsed = try parse(testing.allocator, markdown, .{});
    defer reparsed.deinit();
    const markdown_again = try renderMarkdownAlloc(testing.allocator, &reparsed);
    defer testing.allocator.free(markdown_again);
    try testing.expectEqualStrings(markdown, markdown_again);

    const html_again = try renderHtmlAlloc(testing.allocator, &reparsed);
    defer testing.allocator.free(html_again);
    try testing.expectEqualStrings(html, html_again);
}

// spec: system_review_md - keeps unpaired, empty, space-padded and nested asterisk runs as literal text instead of failing the document
test "degenerate asterisk runs stay literal text" {
    // Nested emphasis is deliberately not modelled: the outer `**` of
    // `**outer *inner* run**` degrades to literal asterisks while the inner
    // single-marker run still emphasises, and neither outcome is an error.
    const source =
        \\Multiply 3 * 4 * 5 and leave **unclosed strong and *unclosed em alone.
        \\
        \\Empty **** and padded ** ** runs, plus **outer *inner* run**.
    ;
    var document = try parse(testing.allocator, source, .{});
    defer document.deinit();
    try testing.expectEqual(@as(usize, 2), document.blocks.len);

    const html = try renderHtmlAlloc(testing.allocator, &document);
    defer testing.allocator.free(html);
    try testing.expect(std.mem.indexOf(u8, html, "Multiply 3 * 4 * 5 and leave **unclosed strong and *unclosed em alone.") != null);
    try testing.expect(std.mem.indexOf(u8, html, "Empty **** and padded ** ** runs, plus **outer <em>inner</em> run**.") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<strong>") == null);

    const markdown = try renderMarkdownAlloc(testing.allocator, &document);
    defer testing.allocator.free(markdown);
    var reparsed = try parse(testing.allocator, markdown, .{});
    defer reparsed.deinit();
    const markdown_again = try renderMarkdownAlloc(testing.allocator, &reparsed);
    defer testing.allocator.free(markdown_again);
    try testing.expectEqualStrings(markdown, markdown_again);
}

// spec: system_review_md - folds a wrapped list item's continuation lines into that item, ending the item at any new block and the list at a blank line
test "wrapped list items fold their continuation lines" {
    const source =
        \\- [ ] Confirm the stackup matches
        \\  the fabricator's stated capability
        \\- [x] Second task wraps
        \\unindented as well
        \\  and once more
        \\- Third item stands alone
        \\
        \\Trailing paragraph.
    ;
    var document = try parse(testing.allocator, source, .{});
    defer document.deinit();

    try testing.expectEqual(@as(usize, 2), document.blocks.len);
    try testing.expect(document.blocks[1] == .paragraph);
    const list = document.blocks[0].list;
    try testing.expectEqual(@as(usize, 3), list.items.len);
    try testing.expectEqual(@as(usize, 1), document.uncheckedChecklistCount());
    try testing.expectEqualStrings(
        "Confirm the stackup matches the fabricator's stated capability",
        list.items[0].content[0].text,
    );
    try testing.expectEqualStrings(
        "Second task wraps unindented as well and once more",
        list.items[1].content[0].text,
    );

    const markdown = try renderMarkdownAlloc(testing.allocator, &document);
    defer testing.allocator.free(markdown);
    try testing.expectEqualStrings(
        "- [ ] Confirm the stackup matches the fabricator's stated capability\n" ++
            "- [x] Second task wraps unindented as well and once more\n" ++
            "- Third item stands alone\n" ++
            "\nTrailing paragraph.\n",
        markdown,
    );

    var reparsed = try parse(testing.allocator, markdown, .{});
    defer reparsed.deinit();
    const markdown_again = try renderMarkdownAlloc(testing.allocator, &reparsed);
    defer testing.allocator.free(markdown_again);
    try testing.expectEqualStrings(markdown, markdown_again);

    // A heading, table, fence or directive still ends the item it follows, and
    // an indented marker remains the nested-list error it always was.
    var interrupted = try parse(testing.allocator, "- item\n# Heading\n", .{});
    defer interrupted.deinit();
    try testing.expectEqual(@as(usize, 2), interrupted.blocks.len);
    try testing.expect(interrupted.blocks[1] == .heading);
    try expectParseError(error.InvalidList, "- item\n  - nested\n", .{});
}

fn expectParseError(expected: ParseError, source: []const u8, options: Options) !void {
    if (parse(testing.allocator, source, options)) |document_value| {
        var document = document_value;
        document.deinit();
        return error.TestExpectedError;
    } else |actual| try testing.expectEqual(expected, actual);
}

// spec: system_review_md - rejects active markup, external targets, traversal, encoded paths, and unsafe image types before rendering
test "unsafe markup and targets fail closed" {
    var ordinary_prose = try parse(testing.allocator, "Data: ready for review", .{});
    defer ordinary_prose.deinit();
    try testing.expectEqual(@as(usize, 1), ordinary_prose.blocks.len);

    try expectParseError(error.RawHtml, "A <script>alert(1)</script>.", .{});
    try expectParseError(error.RawHtml, "<!-- hidden -->", .{});
    try expectParseError(error.RawHtml, "<!-- netlisp:generated checklist -->", .{});
    try expectParseError(error.RawHtml, "<!-- /netlisp:generated -->", .{});
    try expectParseError(error.RemoteUrl, "[web](https://example.com)", .{});
    try expectParseError(error.RemoteUrl, "Visit https://example.com", .{});
    try expectParseError(error.RemoteUrl, "Visit https\\://example.com", .{});
    try expectParseError(error.RemoteUrl, "[mail](mailto:a@example.com)", .{});
    try expectParseError(error.RemoteUrl, "![x](//example.com/x.png)", .{});
    try expectParseError(error.UnsafePath, "[up](../secret.md)", .{});
    try expectParseError(error.UnsafePath, "[absolute](/etc/passwd)", .{});
    try expectParseError(error.UnsafePath, "[encoded](assets/%2e%2e/secret.md)", .{});
    try expectParseError(error.UnsafeImage, "![not image](assets/page.html)", .{});
}

// spec: system_review_md - accepts only approved, syntactically valid netlisp directives occupying their whole source line
test "directives are line-only and allowlisted" {
    try expectParseError(error.UnknownDirective, "{{netlisp:board-summary rf}}", .{});
    const board_summary = Options{ .allowed_directives = &.{"board-summary"} };
    try expectParseError(error.UnknownDirective, "{{netlisp:nope}}", board_summary);
    try expectParseError(error.MalformedDirective, "prefix {{netlisp:board-summary rf}}", board_summary);
    try expectParseError(error.MalformedDirective, "{{netlisp:board-summary <rf>}}", board_summary);
    try expectParseError(
        error.MalformedDirective,
        "{{netlisp:Board_summary}}",
        .{ .allowed_directives = &.{"Board_summary"} },
    );

    var document = try parse(testing.allocator, "  {{netlisp:board-summary base}}  \r\n", board_summary);
    defer document.deinit();
    const directive = document.blocks[0].directive;
    try testing.expectEqualStrings("board-summary", directive.name);
    try testing.expectEqualStrings("base", directive.argument);
}

// spec: system_review_md - treats fenced code as literal text while escaping it in HTML and refuses unterminated fences and code spans
test "code is literal and structurally bounded" {
    const source =
        \\```text
        \\<script src="https://example.com/x.js"></script>
        \\{{netlisp:not-a-directive}}
        \\```
    ;
    var document = try parse(testing.allocator, source, .{});
    defer document.deinit();
    const html = try renderHtmlAlloc(testing.allocator, &document);
    defer testing.allocator.free(html);
    try testing.expect(std.mem.indexOf(u8, html, "&lt;script src=&quot;https://example.com/x.js&quot;&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<script") == null);

    try expectParseError(error.UnclosedFence, "```text\nno close", .{});
    try expectParseError(error.UnclosedCodeSpan, "A `broken span", .{});
    try expectParseError(error.InvalidFence, "````text\nx\n````", .{});
}

test "line indexing and ordered list numbering are bounded before rendering" {
    const too_many_blank_lines: [17]u8 = @splat('\n');
    try expectParseError(error.LimitExceeded, &too_many_blank_lines, .{ .limits = .{ .blocks = 1 } });

    const overflowing = try std.fmt.allocPrint(
        std.testing.allocator,
        "{d}. first\n{d}. second\n",
        .{ std.math.maxInt(usize), std.math.maxInt(usize) },
    );
    defer std.testing.allocator.free(overflowing);
    try expectParseError(error.InvalidList, overflowing, .{});
}

test "unmatched link openers are parsed with linear bounded lookahead" {
    var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    const openers: [8192]u8 = @splat('[');
    for (0..4) |index| {
        if (index > 0) try source.writer.writeByte('\n');
        try source.writer.writeAll(&openers);
    }
    var document = try parse(std.testing.allocator, source.written(), .{});
    defer document.deinit();
    try std.testing.expectEqual(@as(usize, 1), document.blocks.len);
}

// spec: system_review_md - enforces source, line, structural, table, and list bounds without partial output
test "malformed structures and configured limits are rejected" {
    try expectParseError(error.DocumentTooLarge, "12345", .{ .limits = .{ .source_bytes = 4 } });
    try expectParseError(error.LineTooLong, "12345", .{ .limits = .{ .line_bytes = 4 } });
    try expectParseError(error.LimitExceeded, "# A\n\n# B", .{ .limits = .{ .blocks = 1 } });
    try expectParseError(error.InvalidTable, "| A | B |\n| --- | --- |\n| only one |", .{});
    try expectParseError(error.InvalidChecklist, "- [ ]missing space", .{});
    try expectParseError(error.InvalidList, "  - nested", .{});
    try expectParseError(error.InvalidHeading, "####### too deep", .{});
}

// spec: system_review_md - normalizes line endings and escapes authored text and attributes in deterministic output
test "line ending normalization and output escaping are deterministic" {
    const source = "# A & B\rParagraph with \\<safe> and [quote \\\" here](docs/a.md).\r\n";
    var document = try parse(testing.allocator, source, .{});
    defer document.deinit();
    const markdown = try renderMarkdownAlloc(testing.allocator, &document);
    defer testing.allocator.free(markdown);
    const html = try renderHtmlAlloc(testing.allocator, &document);
    defer testing.allocator.free(html);

    const expected_markdown =
        "# A \\& B\n\n" ++
        "Paragraph with \\<safe\\> and [quote \" here](docs/a.md).\n";
    try testing.expectEqualStrings(expected_markdown, markdown);
    try testing.expect(std.mem.indexOf(u8, html, "<h1>A &amp; B</h1>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "&lt;safe&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, html, "quote &quot; here") != null);
}
