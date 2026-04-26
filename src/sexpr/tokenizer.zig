const std = @import("std");
const ast = @import("ast.zig");
const Span = ast.Span;

/// Lexical category of an S-expression token. `unit_val` covers numbers
/// with a trailing unit (`100k`, `3.3V`, `220nF`); `int` and `float` are
/// reserved for plain numerics.
pub const TokenTag = enum {
    lparen,
    rparen,
    atom,
    string,
    int,
    float,
    unit_val,
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
        return isAtomStart(ch) or isDigit(ch) or ch == '-' or ch == '/' or ch == '.' or ch == '*' or ch == '#' or ch == '@' or ch == ':';
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
