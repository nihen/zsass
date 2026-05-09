const std = @import("std");

/// Source location span
pub const Span = struct {
    start: u32,
    end: u32,

    pub fn len(self: Span) u32 {
        return self.end - self.start;
    }

    pub fn slice(self: Span, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

/// A single token produced by the lexer
pub const Token = struct {
    tag: Tag,
    span: Span,

    pub fn slice(self: Token, source: []const u8) []const u8 {
        return self.span.slice(source);
    }

    pub const Tag = enum(u8) {
        // Literals
        ident,
        number,
        string,
        hash, // #foo (id selector or color)
        at_keyword, // @something (unknown at-rule)

        // Known at-keywords
        at_use,
        at_forward,
        at_import,
        at_mixin,
        at_include,
        at_function,
        at_return,
        at_extend,
        at_if,
        at_else,
        at_each,
        at_for,
        at_while,
        at_debug,
        at_warn,
        at_error,
        at_at_root,
        at_media,
        at_supports,
        at_charset,
        at_keyframes,
        at_font_face,
        at_content,

        // Variable
        dollar_ident, // $variable

        // Interpolation
        hash_lbrace, // #{
        // } closes interpolation (use rbrace)

        // Delimiters
        lparen,
        rparen,
        lbrace,
        rbrace,
        lbracket,
        rbracket,
        semicolon,
        comma,
        colon,

        // Operators
        plus,
        minus,
        star,
        slash,
        percent,
        equal, // =
        equal_equal, // ==
        bang_equal, // !=
        less_than,
        less_than_equal,
        greater_than,
        greater_than_equal,
        ampersand, // & (parent selector)
        tilde, // ~ (general sibling combinator)
        pipe, // | (namespace separator)
        dot, // . (class selector)
        bang, // ! (as in !important, !default, !global, !optional)

        // Special tokens
        whitespace,
        newline,
        comment, // /* ... */ or //...
        eof,

        // Error
        invalid,

        pub fn symbol(self: Tag) ?[]const u8 {
            return switch (self) {
                .lparen => "(",
                .rparen => ")",
                .lbrace => "{",
                .rbrace => "}",
                .lbracket => "[",
                .rbracket => "]",
                .semicolon => ";",
                .comma => ",",
                .colon => ":",
                .plus => "+",
                .minus => "-",
                .star => "*",
                .slash => "/",
                .percent => "%",
                .equal => "=",
                .equal_equal => "==",
                .bang_equal => "!=",
                .less_than => "<",
                .less_than_equal => "<=",
                .greater_than => ">",
                .greater_than_equal => ">=",
                .ampersand => "&",
                .tilde => "~",
                .pipe => "|",
                .dot => ".",
                .bang => "!",
                .hash_lbrace => "#{",
                .eof => "<eof>",
                else => null,
            };
        }
    };
};

/// Lookup table for at-keyword tokens.  Sass treats at-keywords case-
/// insensitively (`@FUNCTION`, `@Function`, `@function` all designate
/// the Sass `@function` rule), so the comparison is lower-cased.
pub fn lookupAtKeyword(name: []const u8) Token.Tag {
    const map = std.StaticStringMap(Token.Tag).initComptime(.{
        .{ "use", .at_use },
        .{ "forward", .at_forward },
        .{ "import", .at_import },
        .{ "mixin", .at_mixin },
        .{ "include", .at_include },
        .{ "function", .at_function },
        .{ "return", .at_return },
        .{ "extend", .at_extend },
        .{ "if", .at_if },
        .{ "else", .at_else },
        .{ "each", .at_each },
        .{ "for", .at_for },
        .{ "while", .at_while },
        .{ "debug", .at_debug },
        .{ "warn", .at_warn },
        .{ "error", .at_error },
        .{ "at-root", .at_at_root },
        .{ "media", .at_media },
        .{ "supports", .at_supports },
        .{ "charset", .at_charset },
        .{ "keyframes", .at_keyframes },
        .{ "font-face", .at_font_face },
        .{ "content", .at_content },
    });
    // Fast path: names in the map are already lowercase.  Try direct hit
    // first to avoid the allocation for the common case.
    if (map.get(name)) |tag| return tag;
    // Case-insensitive fallback: copy into a small stack buffer, lowercase,
    // and re-query.  Keywords are short so a fixed buffer is enough.
    var buf: [32]u8 = undefined;
    if (name.len > buf.len) return .at_keyword;
    for (name, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return map.get(buf[0..name.len]) orelse .at_keyword;
}

/// Return the byte offset of the start of the line containing `byte_pos`.
pub fn lineStartAtByte(source: []const u8, byte_pos: u32) u32 {
    var i: usize = @intCast(@min(byte_pos, @as(u32, @intCast(source.len))));
    while (i > 0) : (i -= 1) {
        const c = source[i - 1];
        if (c == '\n' or c == '\r' or c == '\x0c') break;
    }
    return @intCast(i);
}

/// Return the indentation width (count of leading spaces/tabs) of the line
/// containing `byte_pos`.
pub fn lineIndentAtByte(source: []const u8, byte_pos: u32) u32 {
    const line_start = lineStartAtByte(source, byte_pos);
    var i: usize = line_start;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        if (c != ' ' and c != '\t') break;
    }
    return @intCast(i - line_start);
}

test "lookupAtKeyword" {
    try std.testing.expectEqual(Token.Tag.at_use, lookupAtKeyword("use"));
    try std.testing.expectEqual(Token.Tag.at_mixin, lookupAtKeyword("mixin"));
    try std.testing.expectEqual(Token.Tag.at_keyword, lookupAtKeyword("unknown"));
    try std.testing.expectEqual(Token.Tag.at_at_root, lookupAtKeyword("at-root"));
}

test "Token.Tag.symbol" {
    try std.testing.expectEqualStrings("{", Token.Tag.lbrace.symbol().?);
    try std.testing.expect(Token.Tag.ident.symbol() == null);
}

test "Span.slice" {
    const source = "hello world";
    const span = Span{ .start = 6, .end = 11 };
    try std.testing.expectEqualStrings("world", span.slice(source));
}
