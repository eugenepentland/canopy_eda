//! Output sinks for the page templates in this directory.
//!
//! `pages.zig`, `library.zig` and `pdf_viewer.zig` write their markup straight
//! to the response writer: a run of literal HTML is one `writer.writeAll`, and
//! everything that comes from data goes through one of the three sinks here.
//! That split is the whole point — a template never decides *how* to escape,
//! only *which context* it is writing into:
//!
//! * `writeEscaped` — an HTML text node (`<h1>{title}</h1>`).
//! * `writeAttr` — one complete attribute, quoting included (`<div {attr}>`).
//! * `writeRaw` — markup this repository itself produced, passed through.
//!
//! Escaping is not a formality on these pages. Component descriptions, MPNs,
//! manufacturer names, datasheet URLs, design titles and file names all reach
//! them from `.sexp` sources, uploaded library files and request paths, so the
//! text is genuinely attacker-influenced. `writeRaw` is the one sink that
//! trusts its argument, and every call site passes an `@embedFile`d asset.
//!
//! The entity table lives in `src/escape.zig` with the rest of the repository's
//! escaping; these sinks add the surrounding syntax and the argument handling
//! (integers, optionals) that a template expression needs.

const std = @import("std");
const escape = @import("../../escape.zig");

/// Templates render straight into the response writer — no buffering, no
/// allocation — so a write failure is the only way one can fail.
pub const Error = std.Io.Writer.Error;

/// Write `value` into an HTML text node, escaping `& < > " '`. Bytes outside
/// that set, including every multi-byte UTF-8 sequence, pass through unchanged.
///
/// `value` is whatever the template expression evaluated to: a string, an
/// integer (rendered in base 10), or an optional of either — a null optional
/// renders as nothing at all, which is what makes an optional field legal
/// straight out of a struct. A struct that declares
/// `formatHtml(self, *std.Io.Writer)` renders itself instead: it receives this
/// writer directly and therefore owns any escaping its own output needs, which
/// is how a value whose rendering is a small computation ("3d ago") avoids
/// being formatted into a temporary buffer first. Anything else is a compile
/// error at the call site.
pub fn writeEscaped(writer: *std.Io.Writer, value: anytype) Error!void {
    const Value = @TypeOf(value);
    switch (@typeInfo(Value)) {
        .null => return,
        .optional => return if (value) |present| writeEscaped(writer, present),
        .int, .comptime_int => return writer.print("{d}", .{value}),
        .@"struct" => {
            if (!@hasDecl(Value, "formatHtml")) @compileError(
                "template value of type " ++ @typeName(Value) ++
                    " has no formatHtml(self, *std.Io.Writer): render it to a string first," ++
                    " or give the type a formatHtml method that writes its own markup",
            );
            return value.formatHtml(writer);
        },
        else => {},
    }
    return escape.writeXmlHexApos(writer, value);
}

/// Write one complete attribute — leading space, name, `="`, escaped value,
/// closing quote — so the caller emits `<div` and `>` and never has to get the
/// quoting right itself.
///
/// A null `value` writes NOTHING: no name, no `=""`, not even the space. That
/// is what lets a template say `writeAttr(w, "aria-current", if (active)
/// "page" else null)` and get a bare `<a href="/x">` when the page is not the
/// active one. `value` otherwise follows `writeEscaped`'s rules.
pub fn writeAttr(writer: *std.Io.Writer, name: []const u8, value: anytype) Error!void {
    switch (@typeInfo(@TypeOf(value))) {
        .null => return,
        .optional => return if (value) |present| writeAttr(writer, name, present),
        else => {},
    }
    try writer.writeAll(" ");
    try writer.writeAll(name);
    try writer.writeAll("=\"");
    try writeEscaped(writer, value);
    try writer.writeAll("\"");
}

/// Write `markup` with no escaping whatsoever.
///
/// Reserved for markup this repository produced: the `@embedFile`d `<style>`
/// blocks and HTML partials the templates splice into their heads and bodies.
/// It takes `[]const u8` rather than `anytype` on purpose — a raw sink should
/// be the one place a reader has to look at, and a narrow signature keeps a
/// stray integer or optional from quietly acquiring a raw rendering.
pub fn writeRaw(writer: *std.Io.Writer, markup: []const u8) Error!void {
    try writer.writeAll(markup);
}

/// A template and its arguments captured as one renderable value, so a page
/// can take "some other page fragment" as a parameter without knowing which
/// template it is. Build one with a template's `bind`, which owns the cast back
/// to the concrete argument tuple.
pub const Component = struct {
    /// The bound argument tuple. Borrowed — it has to outlive the render.
    ptr: *const anyopaque,
    /// Restores `ptr`'s real type and renders. Supplied by `bind`.
    renderFn: *const fn (*const anyopaque, *std.Io.Writer) Error!void,

    /// Render the captured template with the arguments it was bound to.
    pub fn render(self: Component, writer: *std.Io.Writer) Error!void {
        return self.renderFn(self.ptr, writer);
    }
};

/// Render template `Template` with `args` at this point in the output.
///
/// This is the one call a template makes to nest another template, and it is a
/// named function rather than a direct `Template.render(...)` so that every
/// nesting site in this directory reads the same and can grow shared behaviour
/// (a depth guard, a render trace) in exactly one place. Naming `Template.Args`
/// rather than taking `anytype` is what makes a wrong argument tuple an error
/// at the call site instead of somewhere inside the nested template.
pub fn renderComponent(comptime Template: type, args: Template.Args, writer: *std.Io.Writer) Error!void {
    return Template.render(args, writer);
}

// spec: Web Server - A page template escapes every interpolated value for the context it lands in, so a component description carrying markup renders as text and cannot open a tag or close an attribute
test "writeEscaped replaces the five markup characters and nothing else" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeEscaped(&out.writer, "&<>\"'");
    try std.testing.expectEqualStrings("&amp;&lt;&gt;&quot;&#x27;", out.written());
}

test "writeEscaped passes non-ASCII, punctuation and the empty string through byte for byte" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeEscaped(&out.writer, "");
    try std.testing.expectEqualStrings("", out.written());

    // Component descriptions carry em dashes, accents and check marks; a page
    // that escaped or dropped them would be visibly wrong, not merely verbose.
    try writeEscaped(&out.writer, "ünïcøde — ✓ 🔧 a`b=c;{d}%e");
    try std.testing.expectEqualStrings("ünïcøde — ✓ 🔧 a`b=c;{d}%e", out.written());
}

test "writeEscaped neutralizes a tag and re-escapes text that already looks like an entity" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeEscaped(&out.writer, "<script>alert(1)</script>");
    // Nothing that could open or close a tag survives.
    try std.testing.expect(std.mem.indexOfScalar(u8, out.written(), '<') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, out.written(), '>') == null);

    // Escaping is not idempotent, and must not be: text that literally reads
    // `&amp;` has to render as `&amp;`, so its ampersand escapes again.
    var second: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer second.deinit();
    try writeEscaped(&second.writer, "&amp;");
    try std.testing.expectEqualStrings("&amp;amp;", second.written());
}

test "writeEscaped renders an integer in base ten and an optional by its presence" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const count: usize = 1207;
    try writeEscaped(&out.writer, count);
    try std.testing.expectEqualStrings("1207", out.written());

    var some: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer some.deinit();
    const present: ?[]const u8 = "a&b";
    try writeEscaped(&some.writer, present);
    try std.testing.expectEqualStrings("a&amp;b", some.written());

    var none: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer none.deinit();
    const absent: ?[]const u8 = null;
    try writeEscaped(&none.writer, absent);
    try std.testing.expectEqualStrings("", none.written());
}

// spec: Web Server - A page value that renders itself writes its own markup straight into the page, in a text node and in an attribute alike
test "writeEscaped lets a value with formatHtml write its own markup" {
    const Age = struct {
        days: u32,
        pub fn formatHtml(self: @This(), w: *std.Io.Writer) Error!void {
            if (self.days == 0) return w.writeAll("today");
            try w.print("<b>{d}</b>d ago", .{self.days});
        }
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeEscaped(&out.writer, Age{ .days = 3 });
    // The method owns its output: the tags it wrote are NOT escaped on the way
    // out, which is exactly why only trusted types may declare it.
    try std.testing.expectEqualStrings("<b>3</b>d ago", out.written());

    // It also reaches through an attribute, which routes values through here.
    var attr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer attr.deinit();
    try writeAttr(&attr.writer, "title", Age{ .days = 0 });
    try std.testing.expectEqualStrings(" title=\"today\"", attr.written());
}

test "writeAttr quotes the value and escapes the quote that would end it" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeAttr(&out.writer, "data-pdf", "a\"b");
    try std.testing.expectEqualStrings(" data-pdf=\"a&quot;b\"", out.written());

    // The breakout an unescaped attribute writer hands an attacker.
    var breakout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer breakout.deinit();
    try writeAttr(&breakout.writer, "data-name", "x\" onload=\"alert(1)");
    try std.testing.expectEqualStrings(
        " data-name=\"x&quot; onload=&quot;alert(1)\"",
        breakout.written(),
    );
}

// spec: Web Server - A page attribute whose value is null is omitted whole rather than emitted empty, so a navigation link that is not the current page carries no current-page marking at all
test "writeAttr omits the whole attribute for a null value and renders an integer" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const absent: ?[]const u8 = null;
    try writeAttr(&out.writer, "aria-current", absent);
    // Not ` aria-current=""`, and not a stray space: nothing at all, because
    // the navbar's inactive links must render as bare `<a href="/x">`.
    try std.testing.expectEqualStrings("", out.written());

    const errors: usize = 2;
    try writeAttr(&out.writer, "data-erc-errors", errors);
    try std.testing.expectEqualStrings(" data-erc-errors=\"2\"", out.written());
}

// spec: Web Server - An embedded style or script block passes through a page unescaped, exactly as it was compiled in
test "writeRaw passes embedded markup through untouched" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeRaw(&out.writer, "<style>a{content:\"&<>\"}</style>");
    try std.testing.expectEqualStrings("<style>a{content:\"&<>\"}</style>", out.written());
}

// spec: Web Server - One page template nests another through a single render call, and the same template bound as a component renders byte for byte what the direct call renders
test "renderComponent and a bound Component render the same nested markup" {
    const Greeting = struct {
        fn _render(name: []const u8, writer: *std.Io.Writer) Error!void {
            try writer.writeAll("<b>");
            try writeEscaped(writer, name);
            try writer.writeAll("</b>");
        }
        fn _signature(_: []const u8) void {}
        pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));
        pub fn render(args: Args, writer: *std.Io.Writer) Error!void {
            return @call(.always_inline, _render, args ++ .{writer});
        }
        pub fn bind(args: *const Args) Component {
            return .{
                .ptr = @ptrCast(args),
                .renderFn = struct {
                    fn f(ptr: *const anyopaque, writer: *std.Io.Writer) Error!void {
                        return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, writer);
                    }
                }.f,
            };
        }
    };

    var direct: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer direct.deinit();
    try renderComponent(Greeting, .{"R&D"}, &direct.writer);
    try std.testing.expectEqualStrings("<b>R&amp;D</b>", direct.written());

    var erased: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer erased.deinit();
    const args: Greeting.Args = .{"R&D"};
    try Greeting.bind(&args).render(&erased.writer);
    try std.testing.expectEqualStrings(direct.written(), erased.written());
}
