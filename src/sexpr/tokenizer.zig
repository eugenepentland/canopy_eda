const std = @import("std");
const ast = @import("ast.zig");
const Span = ast.Span;

/// Lexical category of an S-expression token. `unit_val` covers dimension
/// numbers with a trailing `mm`/`mil`; `si_val` covers SI-scaled electrical
/// literals (`220k`, `100nF`, `3.3V`, `10mA`) whose text keeps the suffix so
/// the parser can apply the scale; `int` and `float` are plain numerics.
pub const TokenTag = enum {
    lparen,
    rparen,
    atom,
    string,
    int,
    float,
    unit_val,
    si_val,
    eof,
};

/// One lexed token: the classification (`tag`), the verbatim source slice
/// (`text`), and the byte/line span carried through to the AST so error
/// messages can point at the original location.
pub const Token = struct {
    tag: TokenTag,
    text: []const u8,
    span: Span,
};

/// One SI scale suffix: the letter and its multiplier. Single source of
/// truth for the tokenizer's suffix recognition, the parser's value
/// conversion (`parseSiValue`), and the generated language reference
/// (`src/docgen.zig`). `bare` = the letter is a scale even with no unit
/// letter following — `m` is not, so bare `3m`, `mm`, and `mil` keep
/// their existing dimension/atom meanings.
pub const SiScale = struct { letter: u8, multiplier: f64, bare: bool };

pub const si_scales = [_]SiScale{
    .{ .letter = 'k', .multiplier = 1e3, .bare = true },
    .{ .letter = 'M', .multiplier = 1e6, .bare = true },
    .{ .letter = 'G', .multiplier = 1e9, .bare = true },
    .{ .letter = 'm', .multiplier = 1e-3, .bare = false },
    .{ .letter = 'u', .multiplier = 1e-6, .bare = true },
    .{ .letter = 'n', .multiplier = 1e-9, .bare = true },
    .{ .letter = 'p', .multiplier = 1e-12, .bare = true },
};

/// Unit letters accepted after a scale letter (or alone): they carry no
/// scale, only readability (`100nF` == `100n`, `3.3V` == `3.3`).
pub const si_unit_letters: []const u8 = "VAFHR";

/// S-expression tokenizer. Holds a non-owning reference to `source` plus
/// the cursor (`pos`, `line`, `col`) used for span reporting; instantiate
/// with `init(source)` then call `next()` to walk tokens until `eof`.
pub const Tokenizer = struct {
    source: []const u8,
    pos: u32,
    line: u32,
    col: u32,

    pub fn init(source: []const u8) Tokenizer {
        return .{
            .source = source,
            .pos = 0,
            .line = 1,
            .col = 1,
        };
    }

    fn peek(self: *const Tokenizer) ?u8 {
        if (self.pos >= self.source.len) return null;
        return self.source[self.pos];
    }

    fn advance(self: *Tokenizer) void {
        if (self.pos < self.source.len) {
            if (self.source[self.pos] == '\n') {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
            self.pos += 1;
        }
    }

    fn span(self: *const Tokenizer) Span {
        return .{ .line = self.line, .col = self.col, .offset = self.pos };
    }

    fn skipWhitespaceAndComments(self: *Tokenizer) void {
        while (true) {
            // Skip whitespace
            while (self.peek()) |c| {
                if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                    self.advance();
                } else break;
            }
            // Skip ; comments to end of line
            if (self.peek()) |c| {
                if (c == ';') {
                    while (self.peek()) |cc| {
                        if (cc == '\n') break;
                        self.advance();
                    }
                    continue; // loop back to skip more whitespace
                }
            }
            break;
        }
    }

    pub fn next(self: *Tokenizer) !Token {
        self.skipWhitespaceAndComments();

        const s = self.span();

        const c = self.peek() orelse return Token{
            .tag = .eof,
            .text = "",
            .span = s,
        };

        // Parens
        if (c == '(') {
            self.advance();
            return Token{ .tag = .lparen, .text = "(", .span = s };
        }
        if (c == ')') {
            self.advance();
            return Token{ .tag = .rparen, .text = ")", .span = s };
        }

        // String
        if (c == '"') return self.readString(s);

        // Number (or negative number)
        if (isDigit(c) or (c == '-' and self.peekAt(1) != null and isDigit(self.peekAt(1).?))) {
            return self.readNumber(s);
        }

        // Atom
        if (isAtomStart(c)) return self.readAtom(s);

        // Operators that are atoms: +, -, *, /, %, >, <, =, !
        if (isOperatorChar(c)) return self.readOperator(s);

        return error.UnexpectedCharacter;
    }

    fn peekAt(self: *const Tokenizer, offset: u32) ?u8 {
        const idx = self.pos + offset;
        if (idx >= self.source.len) return null;
        return self.source[idx];
    }

    fn readString(self: *Tokenizer, s: Span) !Token {
        self.advance(); // skip opening "
        const start = self.pos;
        while (self.peek()) |ch| {
            if (ch == '\\') {
                self.advance(); // skip backslash
                self.advance(); // skip escaped char
                continue;
            }
            if (ch == '"') {
                const text = self.source[start..self.pos];
                self.advance(); // skip closing "
                return Token{ .tag = .string, .text = text, .span = s };
            }
            self.advance();
        }
        return error.UnterminatedString;
    }

    fn readNumber(self: *Tokenizer, s: Span) Token {
        const start = self.pos;
        // Optional leading minus
        if (self.peek()) |ch| {
            if (ch == '-') self.advance();
        }
        // Integer part
        while (self.peek()) |ch| {
            if (isDigit(ch)) self.advance() else break;
        }
        // Check for decimal point
        var is_float = false;
        if (self.peek()) |ch| {
            if (ch == '.' and self.peekAt(1) != null and isDigit(self.peekAt(1).?)) {
                is_float = true;
                self.advance(); // skip .
                while (self.peek()) |d| {
                    if (isDigit(d)) self.advance() else break;
                }
            }
        }
        // Check for unit suffix (mm or mil)
        const num_end = self.pos;
        if (self.peek()) |ch| {
            if (ch == 'm') {
                if (self.peekAt(1)) |ch2| {
                    if (ch2 == 'm' and !isAtomContinue(self.peekAt(2))) {
                        // mm suffix
                        self.advance();
                        self.advance();
                        return Token{ .tag = .unit_val, .text = self.source[start..num_end], .span = s };
                    }
                    if (ch2 == 'i') {
                        if (self.peekAt(2)) |ch3| {
                            if (ch3 == 'l' and !isAtomContinue(self.peekAt(3))) {
                                // mil suffix — convert to mm (1 mil = 0.0254 mm)
                                self.advance();
                                self.advance();
                                self.advance();
                                return Token{ .tag = .unit_val, .text = self.source[start..num_end], .span = s };
                            }
                        }
                    }
                }
            }
        }
        // SI scale suffix (k/M/G/u/n/p — or m only when a unit letter
        // follows, so `3m`/`mm`/`mil` keep their existing meanings),
        // optionally followed by ONE unit letter from {V,A,F,H,R} that is
        // ignored for the value (`100nF` == `100n`); or a bare unit letter
        // (`3.3V` → 3.3). The suffix must end the token — `100kHz` and
        // `204928-0301.stp` keep falling through to the atom path below.
        if (self.siSuffixLen()) |suffix_len| {
            var k: u2 = 0;
            while (k < suffix_len) : (k += 1) self.advance();
            return Token{ .tag = .si_val, .text = self.source[start..self.pos], .span = s };
        }
        // If followed by an atom-continuation char, this wasn't a number at
        // all — it's an identifier like "204928-0301.stp" or "12.5abc".
        // Slurp the rest as an atom.
        if (self.peek()) |ch| {
            if (isAtomContinue(ch)) {
                while (self.peek()) |c2| {
                    if (isAtomContinue(c2)) self.advance() else break;
                }
                return Token{ .tag = .atom, .text = self.source[start..self.pos], .span = s };
            }
        }
        const text = self.source[start..self.pos];
        if (is_float) {
            return Token{ .tag = .float, .text = text, .span = s };
        }
        return Token{ .tag = .int, .text = text, .span = s };
    }

    /// Length (1 or 2 chars) of an SI value suffix starting at the cursor,
    /// or null when the upcoming chars aren't one. Accepted shapes:
    ///   • scale letter alone:        `4.7k`, `10M`, `1n`
    ///   • scale letter + unit letter: `100nF`, `10mA`, `100mV`
    ///   • unit letter alone:          `3.3V`, `0.5A`
    /// `m` is only a scale when a unit letter follows — bare `3m`, `mm`,
    /// and `mil` keep their existing dimension/atom behavior.
    fn siSuffixLen(self: *const Tokenizer) ?u2 {
        const c0 = self.peek() orelse return null;
        if (isScaleLetter(c0)) {
            const c1 = self.peekAt(1);
            if (!isAtomContinue(c1)) return 1;
            if (c1) |u| {
                if (isUnitLetter(u) and !isAtomContinue(self.peekAt(2))) return 2;
            }
            return null;
        }
        if (isUnitRequiredScale(c0)) {
            if (self.peekAt(1)) |u| {
                if (isUnitLetter(u) and !isAtomContinue(self.peekAt(2))) return 2;
            }
            return null;
        }
        if (isUnitLetter(c0) and !isAtomContinue(self.peekAt(1))) return 1;
        return null;
    }

    /// Scale letters that stand on their own (`4.7k`). Consults
    /// `si_scales` so recognition, conversion, and docs share one table.
    fn isScaleLetter(c: u8) bool {
        for (si_scales) |s| {
            if (s.bare and s.letter == c) return true;
        }
        return false;
    }

    /// Scale letters that are only a scale when a unit letter follows
    /// (`10mA` yes; bare `3m` stays a dimension/atom). Today just `m`.
    fn isUnitRequiredScale(c: u8) bool {
        for (si_scales) |s| {
            if (!s.bare and s.letter == c) return true;
        }
        return false;
    }

    fn isUnitLetter(c: u8) bool {
        return std.mem.indexOfScalar(u8, si_unit_letters, c) != null;
    }

    fn readAtom(self: *Tokenizer, s: Span) Token {
        const start = self.pos;
        while (self.peek()) |ch| {
            if (isAtomContinue(ch)) self.advance() else break;
        }
        return Token{ .tag = .atom, .text = self.source[start..self.pos], .span = s };
    }

    fn readOperator(self: *Tokenizer, s: Span) Token {
        const start = self.pos;
        self.advance();
        // Allow two-char operators: >=, <=, ==, !=
        if (self.peek()) |ch2| {
            if (ch2 == '=') self.advance();
        }
        return Token{ .tag = .atom, .text = self.source[start..self.pos], .span = s };
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn isAtomStart(c: ?u8) bool {
        const ch = c orelse return false;
        return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_' or ch == '~' or ch == '*';
    }

    fn isAtomContinue(c: ?u8) bool {
        const ch = c orelse return false;
        // `+` is included so KiCad's unquoted model paths (e.g.
        // `PMA3-24323LN+.stp` from Mini-Circuits part libraries) tokenize
        // as a single atom. `+` standalone is still picked up by
        // `readOperator` since it isn't an atom *start* char, so
        // arithmetic forms like `(+ 1 2)` are unaffected.
        return isAtomStart(ch) or isDigit(ch) or ch == '-' or ch == '/' or ch == '.' or ch == '*' or ch == '#' or ch == '@' or ch == ':' or ch == '+';
    }

    fn isOperatorChar(c: u8) bool {
        return c == '+' or c == '-' or c == '/' or c == '%' or c == '>' or c == '<' or c == '=' or c == '!';
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

// spec: sexpr/tokenizer - Tokenizes parentheses and atoms from S-expression input
test "tokenize parens and atoms" {
    var t = Tokenizer.init("(footprint \"QFN9\" pad-1)");
    const t1 = try t.next();
    try std.testing.expectEqual(TokenTag.lparen, t1.tag);
    const t2 = try t.next();
    try std.testing.expectEqual(TokenTag.atom, t2.tag);
    try std.testing.expectEqualStrings("footprint", t2.text);
    const t3 = try t.next();
    try std.testing.expectEqual(TokenTag.string, t3.tag);
    try std.testing.expectEqualStrings("QFN9", t3.text);
    const t4 = try t.next();
    try std.testing.expectEqual(TokenTag.atom, t4.tag);
    try std.testing.expectEqualStrings("pad-1", t4.text);
    const t5 = try t.next();
    try std.testing.expectEqual(TokenTag.rparen, t5.tag);
    const t6 = try t.next();
    try std.testing.expectEqual(TokenTag.eof, t6.tag);
}

// spec: sexpr/tokenizer - Tokenizes KiCad-style unquoted filenames containing +
test "tokenize unquoted filename with plus" {
    // (model PMA3-24323LN+.stp …) — Mini-Circuits' Samacsys export uses
    // unquoted model paths with `+` in the part name. Regression: previously
    // this split the atom at `+` and then choked on the leading `.`.
    var t = Tokenizer.init("(model PMA3-24323LN+.stp)");
    _ = try t.next(); // (
    const t2 = try t.next();
    try std.testing.expectEqual(TokenTag.atom, t2.tag);
    try std.testing.expectEqualStrings("model", t2.text);
    const t3 = try t.next();
    try std.testing.expectEqual(TokenTag.atom, t3.tag);
    try std.testing.expectEqualStrings("PMA3-24323LN+.stp", t3.text);
    const t4 = try t.next();
    try std.testing.expectEqual(TokenTag.rparen, t4.tag);
}

test "tokenize standalone plus stays as operator atom" {
    // Make sure the atom-continue change doesn't break arithmetic forms.
    var t = Tokenizer.init("(+ 1 2)");
    _ = try t.next(); // (
    const plus = try t.next();
    try std.testing.expectEqual(TokenTag.atom, plus.tag);
    try std.testing.expectEqualStrings("+", plus.text);
    const one = try t.next();
    try std.testing.expectEqual(TokenTag.int, one.tag);
    try std.testing.expectEqualStrings("1", one.text);
}

// spec: sexpr/tokenizer - Tokenizes integer and float numbers with optional unit suffixes
test "tokenize numbers" {
    var t = Tokenizer.init("42 3.3 -5 1.0mm 10mil");
    const t1 = try t.next();
    try std.testing.expectEqual(TokenTag.int, t1.tag);
    try std.testing.expectEqualStrings("42", t1.text);

    const t2 = try t.next();
    try std.testing.expectEqual(TokenTag.float, t2.tag);
    try std.testing.expectEqualStrings("3.3", t2.text);

    const t3 = try t.next();
    try std.testing.expectEqual(TokenTag.int, t3.tag);
    try std.testing.expectEqualStrings("-5", t3.text);

    const t4 = try t.next();
    try std.testing.expectEqual(TokenTag.unit_val, t4.tag);
    try std.testing.expectEqualStrings("1.0", t4.text);

    const t5 = try t.next();
    try std.testing.expectEqual(TokenTag.unit_val, t5.tag);
    try std.testing.expectEqualStrings("10", t5.text);
}

// spec: sexpr/tokenizer - Tokenizes SI-scaled literals (220k, 100nF, 3.3V, 10mA) as si_val with the suffix in the token text
test "tokenize si suffixed numbers" {
    var t = Tokenizer.init("220k 4.7M 1G 10u 100n 22p 100nF 10mA 100mV 3.3V 0.5A 10R 1uH");
    const expected = [_][]const u8{ "220k", "4.7M", "1G", "10u", "100n", "22p", "100nF", "10mA", "100mV", "3.3V", "0.5A", "10R", "1uH" };
    for (expected) |want| {
        const tok = try t.next();
        try std.testing.expectEqual(TokenTag.si_val, tok.tag);
        try std.testing.expectEqualStrings(want, tok.text);
    }
    const eof = try t.next();
    try std.testing.expectEqual(TokenTag.eof, eof.tag);
}

// spec: sexpr/tokenizer - SI suffix rules leave mm/mil dimensions, bare milli, and longer identifiers untouched
test "tokenize si suffix boundary cases" {
    // mm/mil stay unit_val dimension tokens; bare `3m` stays an atom;
    // a suffix followed by more atom chars falls through to an atom
    // (`100kHz`, `5V3`, `204928-0301.stp`); plain ints/floats unchanged.
    var t = Tokenizer.init("1.0mm 10mil 3m 100kHz 5V3 204928-0301.stp 42 3.3");
    const cases = [_]struct { tag: TokenTag, text: []const u8 }{
        .{ .tag = .unit_val, .text = "1.0" },
        .{ .tag = .unit_val, .text = "10" },
        .{ .tag = .atom, .text = "3m" },
        .{ .tag = .atom, .text = "100kHz" },
        .{ .tag = .atom, .text = "5V3" },
        .{ .tag = .atom, .text = "204928-0301.stp" },
        .{ .tag = .int, .text = "42" },
        .{ .tag = .float, .text = "3.3" },
    };
    for (cases) |case| {
        const tok = try t.next();
        try std.testing.expectEqual(case.tag, tok.tag);
        try std.testing.expectEqualStrings(case.text, tok.text);
    }
}

// spec: sexpr/tokenizer - SI literal at a paren boundary ends the token
test "tokenize si suffix before rparen" {
    var t = Tokenizer.init("(let r 4.7k)");
    _ = try t.next(); // (
    _ = try t.next(); // let
    _ = try t.next(); // r
    const tok = try t.next();
    try std.testing.expectEqual(TokenTag.si_val, tok.tag);
    try std.testing.expectEqualStrings("4.7k", tok.text);
    const rp = try t.next();
    try std.testing.expectEqual(TokenTag.rparen, rp.tag);
}

// spec: sexpr/tokenizer - Skips line comments starting with semicolon
test "tokenize comments" {
    var t = Tokenizer.init(
        \\; this is a comment
        \\(hello)
    );
    const t1 = try t.next();
    try std.testing.expectEqual(TokenTag.lparen, t1.tag);
    const t2 = try t.next();
    try std.testing.expectEqual(TokenTag.atom, t2.tag);
    try std.testing.expectEqualStrings("hello", t2.text);
}

// spec: sexpr/tokenizer - Tokenizes arithmetic operators as distinct tokens
test "tokenize operators" {
    var t = Tokenizer.init("(+ a (* b c))");
    const t1 = try t.next();
    try std.testing.expectEqual(TokenTag.lparen, t1.tag);
    const t2 = try t.next();
    try std.testing.expectEqual(TokenTag.atom, t2.tag);
    try std.testing.expectEqualStrings("+", t2.text);
    _ = try t.next(); // a
    const t4 = try t.next();
    try std.testing.expectEqual(TokenTag.lparen, t4.tag);
    const t5 = try t.next();
    try std.testing.expectEqualStrings("*", t5.text);
}

// spec: sexpr/tokenizer - Tokenizes comparison operators as distinct tokens
test "tokenize comparison operators" {
    var t = Tokenizer.init(">= <= == !=");
    const t1 = try t.next();
    try std.testing.expectEqualStrings(">=", t1.text);
    const t2 = try t.next();
    try std.testing.expectEqualStrings("<=", t2.text);
    const t3 = try t.next();
    try std.testing.expectEqualStrings("==", t3.text);
    const t4 = try t.next();
    try std.testing.expectEqualStrings("!=", t4.text);
}

// spec: sexpr/tokenizer - Tracks line and column position for each token
test "tracks line and column" {
    var t = Tokenizer.init("(a\n  b)");
    const t1 = try t.next();
    try std.testing.expectEqual(@as(u32, 1), t1.span.line);
    try std.testing.expectEqual(@as(u32, 1), t1.span.col);
    _ = try t.next(); // a at line 1, col 2
    const t3 = try t.next(); // b at line 2, col 3
    try std.testing.expectEqual(@as(u32, 2), t3.span.line);
    try std.testing.expectEqual(@as(u32, 3), t3.span.col);
}
