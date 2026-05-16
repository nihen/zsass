const std = @import("std");
const zsass_io = @import("../runtime/io.zig");
const token_mod = @import("../frontend/token.zig");
const Token = token_mod.Token;
const lookupAtKeyword = token_mod.lookupAtKeyword;

fn lexerStderrPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    var err_file = std.Io.File.stderr();
    var w = err_file.writer(zsass_io.io, buf[0..]);
    w.interface.print(fmt, args) catch return;
    w.interface.flush() catch return;
}

/// SCSS Lexer -- tokenizes source into a stream of tokens.
/// Phase 0: correctness-first, SIMD optimization deferred.
pub const Lexer = struct {
    const ErrorReason = enum {
        invalid_token,
        unterminated_string,
        unterminated_block_comment,
        trailing_dot_number,
    };

    const ErrorDetail = struct {
        span: token_mod.Span,
        reason: ErrorReason,
    };

    const SourceLocation = struct {
        line: usize,
        column: usize,
        line_start: usize,
        line_end: usize,
    };

    source: []const u8,
    pos: u32,
    tokens: std.ArrayList(Token),
    allocator: std.mem.Allocator,
    source_name: ?[]const u8 = null,
    last_error_detail: ?ErrorDetail = null,
    /// True when lexing indented-syntax `.sass` input.
    is_indented_syntax: bool = false,
    allow_silent_comments: bool = true,
    /// Depth of url(...) nesting. When > 0, "//" is not treated as a line comment.
    url_paren_depth: u32 = 0,
    /// Depth of CSS special function nesting (calc, element, expression, progid, etc.)
    /// When > 0, `//` is still lexed as a line-comment token so downstream
    /// raw-expression fallback can strip it with CSS special-function rules.
    css_special_paren_depth: u32 = 0,
    /// Depth of #{...} interpolation nesting.
    interp_depth: u32 = 0,
    /// Set to true when at least one `#{` interpolation start is emitted.
    /// Parser fast-path uses this to skip per-statement interp_depth tracking
    /// when it's known the source contains zero interpolations (typical for
    /// plain CSS / vendored .css files).
    saw_interpolation: bool = false,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Lexer {
        return .{
            .source = source,
            .pos = 0,
            .tokens = .empty,
            .allocator = allocator,
        };
    }

    pub fn initPlainCss(allocator: std.mem.Allocator, source: []const u8) Lexer {
        var lexer = init(allocator, source);
        lexer.allow_silent_comments = false;
        return lexer;
    }

    pub fn deinit(self: *Lexer) void {
        self.tokens.deinit(self.allocator);
    }

    /// Tokenize the entire source
    pub fn tokenize(self: *Lexer) ![]const Token {
        self.last_error_detail = null;
        // Heuristic: ~1 token per 4 bytes reduces ArrayList reallocations on large inputs.
        try self.tokens.ensureTotalCapacity(self.allocator, self.source.len / 4 + 8);
        // Skip UTF-8 BOM (EF BB BF) at start of file
        if (self.source.len >= 3 and
            self.source[0] == 0xEF and
            self.source[1] == 0xBB and
            self.source[2] == 0xBF)
        {
            self.pos = 3;
        }
        while (true) {
            const tok = self.nextToken();
            try self.tokens.append(self.allocator, tok);
            if (tok.tag == .eof) break;
            if (tok.tag == .invalid) {
                const text = tok.span.slice(self.source);
                // Unterminated string (raw newline inside quoted string) is a lex error
                if (text.len > 0 and (text[0] == '"' or text[0] == '\'')) {
                    self.captureError(tok, .unterminated_string);
                    return error.SyntaxError;
                }
                // Unterminated block comment is a lex error
                if (text.len >= 2 and text[0] == '/' and text[1] == '*') {
                    if (self.is_indented_syntax) continue;
                    self.captureError(tok, .unterminated_block_comment);
                    return error.SyntaxError;
                }
                // Trailing '.' on a number (`1.`, `+1.`, after sign `-.`) -- sass-spec values/numbers/error.hrx
                if (text.len == 1 and text[0] == '.') {
                    self.captureError(tok, .trailing_dot_number);
                    return error.SyntaxError;
                }
            }
        }
        return self.tokens.items;
    }

    pub fn printLastErrorDiagnostic(self: *const Lexer, err_name: []const u8) void {
        const detail = self.last_error_detail orelse return;
        const loc = self.offsetToLocation(detail.span.start);
        const file = self.source_name orelse "<input>";
        const line = self.source[loc.line_start..loc.line_end];

        var token_buf: [128]u8 = undefined;
        const token_sample = sanitizeSample(&token_buf, detail.span.slice(self.source));

        lexerStderrPrint("{s}: {s}\n", .{ err_name, reasonText(detail.reason) });
        lexerStderrPrint("  at {s}:{d}:{d}\n", .{ file, loc.line, loc.column });
        lexerStderrPrint("  token: {s}\n", .{token_sample});
        if (line.len != 0) {
            lexerStderrPrint("  {s}\n", .{line});
            var pad_buf: [256]u8 = undefined;
            const pad_len = @min(loc.column - 1, pad_buf.len);
            @memset(pad_buf[0..pad_len], ' ');
            lexerStderrPrint("  {s}^\n", .{pad_buf[0..pad_len]});
        }
    }

    fn captureError(self: *Lexer, tok: Token, reason: ErrorReason) void {
        self.last_error_detail = .{
            .span = tok.span,
            .reason = reason,
        };
    }

    fn offsetToLocation(self: *const Lexer, byte_pos: u32) SourceLocation {
        const target: usize = @min(@as(usize, @intCast(byte_pos)), self.source.len);
        var line: usize = 1;
        var line_start: usize = 0;
        var i: usize = 0;
        while (i < target) : (i += 1) {
            const c = self.source[i];
            switch (c) {
                '\n', '\x0c' => {
                    line += 1;
                    line_start = i + 1;
                },
                '\r' => {
                    line += 1;
                    if (i + 1 < target and self.source[i + 1] == '\n') i += 1;
                    line_start = i + 1;
                },
                else => {},
            }
        }

        var line_end = line_start;
        while (line_end < self.source.len) : (line_end += 1) {
            const c = self.source[line_end];
            if (c == '\n' or c == '\r' or c == '\x0c') break;
        }

        return .{
            .line = line,
            .column = target - line_start + 1,
            .line_start = line_start,
            .line_end = line_end,
        };
    }

    /// Get the next token
    fn nextToken(self: *Lexer) Token {
        // Skip whitespace (produce whitespace token)
        const ws_start = self.pos;
        var has_newline = false;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '\n' or c == '\r' or c == '\x0c') {
                has_newline = true;
                self.pos += 1;
                if (c == '\r' and self.pos < self.source.len and self.source[self.pos] == '\n') {
                    self.pos += 1;
                }
            } else if (c == ' ' or c == '\t') {
                self.pos += 1;
            } else {
                break;
            }
        }
        if (self.pos > ws_start) {
            return Token{
                .tag = if (has_newline) .newline else .whitespace,
                .span = .{ .start = ws_start, .end = self.pos },
            };
        }

        if (self.pos >= self.source.len) {
            return Token{
                .tag = .eof,
                .span = .{ .start = self.pos, .end = self.pos },
            };
        }

        const start = self.pos;
        const c = self.source[self.pos];

        switch (c) {
            '(' => {
                if (self.url_paren_depth > 0) {
                    self.url_paren_depth += 1;
                } else if (self.css_special_paren_depth > 0) {
                    self.css_special_paren_depth += 1;
                } else {
                    switch (parenFunctionKindBefore(self.source, self.pos)) {
                        .url => self.url_paren_depth = 1,
                        .css_special => self.css_special_paren_depth = 1,
                        .none => {},
                    }
                }
                return self.single(.lparen);
            },
            ')' => {
                if (self.url_paren_depth > 0) {
                    self.url_paren_depth -= 1;
                } else if (self.css_special_paren_depth > 0) {
                    self.css_special_paren_depth -= 1;
                }
                return self.single(.rparen);
            },
            '{' => return self.single(.lbrace),
            '}' => {
                if (self.interp_depth > 0) {
                    self.interp_depth -= 1;
                }
                return self.single(.rbrace);
            },
            '[' => return self.single(.lbracket),
            ']' => return self.single(.rbracket),
            ';' => return self.single(.semicolon),
            ',' => return self.single(.comma),
            '~' => return self.single(.tilde),
            '|' => return self.single(.pipe),
            '+' => {
                if (self.pos + 1 < self.source.len) {
                    const next = self.source[self.pos + 1];
                    if (isDigit(next)) return self.lexNumber();
                    if (next == '.') {
                        const after_dot = if (self.pos + 2 < self.source.len) self.source[self.pos + 2] else 0;
                        if (isDigit(after_dot)) return self.lexNumber();
                        if (!isClassSelectorLead(after_dot)) return self.lexNumber();
                    }
                }
                return self.single(.plus);
            },
            '*' => return self.single(.star),
            '%' => return self.single(.percent),
            '&' => return self.single(.ampersand),
            ':' => return self.single(.colon),
            '.' => {
                if (self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1])) {
                    return self.lexNumber();
                }
                return self.single(.dot);
            },
            '-' => {
                if (self.pos + 1 < self.source.len) {
                    const next = self.source[self.pos + 1];
                    if (isDigit(next)) return self.lexNumber();
                    if (next == '.') {
                        const after_dot = if (self.pos + 2 < self.source.len) self.source[self.pos + 2] else 0;
                        if (isDigit(after_dot)) return self.lexNumber();
                        if (!isClassSelectorLead(after_dot)) return self.lexNumber();
                    }
                    if (next == '-' or isIdentStart(next)) return self.lexIdent();
                }
                return self.single(.minus);
            },
            '!' => {
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '=') {
                    self.pos += 2;
                    return Token{ .tag = .bang_equal, .span = .{ .start = start, .end = self.pos } };
                }
                return self.single(.bang);
            },
            '=' => {
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '=') {
                    self.pos += 2;
                    return Token{ .tag = .equal_equal, .span = .{ .start = start, .end = self.pos } };
                }
                return self.single(.equal);
            },
            '<' => {
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '=') {
                    self.pos += 2;
                    return Token{ .tag = .less_than_equal, .span = .{ .start = start, .end = self.pos } };
                }
                return self.single(.less_than);
            },
            '>' => {
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '=') {
                    self.pos += 2;
                    return Token{ .tag = .greater_than_equal, .span = .{ .start = start, .end = self.pos } };
                }
                return self.single(.greater_than);
            },
            '/' => {
                if (self.pos + 1 < self.source.len) {
                    const next = self.source[self.pos + 1];
                    if (next == '/') {
                        if (self.url_paren_depth > 0) return self.single(.slash);
                        if (!self.allow_silent_comments) return self.single(.slash);
                        if (self.css_special_paren_depth > 0) return self.lexLineComment();
                        return self.lexLineComment();
                    }
                    if (next == '*') return self.lexBlockComment();
                }
                return self.single(.slash);
            },
            '#' => {
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '{') {
                    self.interp_depth += 1;
                    self.saw_interpolation = true;
                    self.pos += 2;
                    return Token{ .tag = .hash_lbrace, .span = .{ .start = start, .end = self.pos } };
                }
                self.pos += 1;
                // Continue past hex/ident body *and* CSS identifier escapes so
                // `#f00000\9\0` is one token (sass-spec issue_1098). Without this,
                // `#f00000` stops before `\`, becomes `expr_color_hex`, and the
                // following `\9` becomes a separate space-list item  ->  wrong
                // `#f00000 \9` emission.
                while (self.pos < self.source.len) {
                    if (self.source[self.pos] == '\\') {
                        self.skipIdentEscape();
                    } else if (isIdentChar(self.source[self.pos])) {
                        self.pos += 1;
                    } else break;
                }
                return Token{ .tag = .hash, .span = .{ .start = start, .end = self.pos } };
            },
            '$' => {
                self.pos += 1;
                while (self.pos < self.source.len) {
                    if (self.source[self.pos] == '\\') {
                        self.skipIdentEscape();
                    } else if (isIdentChar(self.source[self.pos]) or self.source[self.pos] == '-') {
                        self.pos += 1;
                    } else break;
                }
                return Token{ .tag = .dollar_ident, .span = .{ .start = start, .end = self.pos } };
            },
            '@' => {
                self.pos += 1;
                const name_start = self.pos;
                while (self.pos < self.source.len) {
                    if (self.source[self.pos] == '\\') {
                        self.skipIdentEscape();
                    } else if (isIdentChar(self.source[self.pos]) or self.source[self.pos] == '-') {
                        self.pos += 1;
                    } else break;
                }
                const raw_name = self.source[name_start..self.pos];
                const tag = if (std.mem.findScalar(u8, raw_name, '\\') != null) blk: {
                    const name = self.unescapeIdent(raw_name) catch break :blk .at_keyword;
                    defer self.allocator.free(name);
                    break :blk lookupAtKeyword(name);
                } else lookupAtKeyword(raw_name);
                return Token{ .tag = tag, .span = .{ .start = start, .end = self.pos } };
            },
            '\'' => return self.lexString('\''),
            '"' => return self.lexString('"'),
            '0'...'9' => return self.lexNumber(),
            else => {
                if ((c == 'U' or c == 'u')) {
                    if (self.tryLexUnicodeRange()) |tok| return tok;
                }
                if (c == '\\' and self.pos + 1 < self.source.len and
                    self.source[self.pos + 1] != '\n' and self.source[self.pos + 1] != '\r')
                    return self.lexIdent();
                if (isIdentStart(c)) return self.lexIdent();
                self.pos += 1;
                return Token{ .tag = .invalid, .span = .{ .start = start, .end = self.pos } };
            },
        }
    }

    fn single(self: *Lexer, tag: Token.Tag) Token {
        const start = self.pos;
        self.pos += 1;
        return Token{ .tag = tag, .span = .{ .start = start, .end = self.pos } };
    }

    fn lexIdent(self: *Lexer) Token {
        const start = self.pos;
        // When the immediately preceding token is a number (no whitespace
        // between), this ident is going to be consumed as a unit by the
        // expression parser.  `-<digit>` inside the unit must be split
        // off as a binary operator (`5px-5`  ->  `5px` + `-5`), so we
        // restrict ident continuation to stop at the first `-<digit>`
        // boundary in this special case.
        const prev_was_glued_number = self.tokens.items.len > 0 and
            self.tokens.items[self.tokens.items.len - 1].tag == .number and
            self.tokens.items[self.tokens.items.len - 1].span.end == start;

        while (self.pos < self.source.len and self.source[self.pos] == '-') self.pos += 1;
        if (self.pos < self.source.len and self.source[self.pos] == '\\') {
            self.skipIdentEscape();
        } else if (self.pos < self.source.len and isIdentStart(self.source[self.pos])) {
            self.pos += 1;
        }
        while (self.pos < self.source.len) {
            if (self.source[self.pos] == '\\') {
                self.skipIdentEscape();
            } else if (isIdentChar(self.source[self.pos])) {
                if (prev_was_glued_number and
                    self.source[self.pos] == '-' and
                    self.pos + 1 < self.source.len)
                {
                    const after = self.source[self.pos + 1];
                    if (isDigit(after)) break;
                    if (after == '.' and self.pos + 2 < self.source.len and
                        isDigit(self.source[self.pos + 2]))
                    {
                        break;
                    }
                }
                self.pos += 1;
            } else break;
        }
        return Token{ .tag = .ident, .span = .{ .start = start, .end = self.pos } };
    }

    /// Try to lex a CSS unicode-range token as a single identifier token.
    /// Accepts permissive forms so downstream validation can report errors.
    fn tryLexUnicodeRange(self: *Lexer) ?Token {
        const start = self.pos;
        if (start + 2 >= self.source.len) return null;
        const head = self.source[start];
        if (!(head == 'U' or head == 'u')) return null;
        if (self.source[start + 1] != '+') return null;

        const first = self.source[start + 2];
        if (!std.ascii.isHex(first) and first != '?') return null;

        var i: usize = start + 2;
        while (i < self.source.len and std.ascii.isHex(self.source[i])) : (i += 1) {}
        var saw_question = false;
        while (i < self.source.len and self.source[i] == '?') : (i += 1) {
            saw_question = true;
        }

        if (!saw_question and i < self.source.len and self.source[i] == '-') {
            i += 1;
            while (i < self.source.len and (std.ascii.isHex(self.source[i]) or self.source[i] == '?')) : (i += 1) {}
        }

        // Avoid stealing plain identifier math like `u+foo`.
        if (!saw_question and i < self.source.len and (isIdentChar(self.source[i]) or self.source[i] == '\\')) return null;

        self.pos = @intCast(i);
        return Token{ .tag = .ident, .span = .{ .start = start, .end = self.pos } };
    }

    fn skipIdentEscape(self: *Lexer) void {
        self.pos += 1;
        if (self.pos >= self.source.len) return;
        const ch = self.source[self.pos];
        if (std.ascii.isHex(ch)) {
            var count: u32 = 0;
            while (self.pos < self.source.len and count < 6 and std.ascii.isHex(self.source[self.pos])) {
                self.pos += 1;
                count += 1;
            }
            if (self.pos < self.source.len and isWhitespaceChar(self.source[self.pos])) self.pos += 1;
        } else if (ch != '\n' and ch != '\r') {
            self.pos += 1;
        }
    }

    fn unescapeIdent(self: *Lexer, text: []const u8) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] != '\\') {
                try buf.append(self.allocator, text[i]);
                i += 1;
                continue;
            }
            i += 1;
            if (i >= text.len) break;
            if (std.ascii.isHex(text[i])) {
                var value: u21 = 0;
                var count: u32 = 0;
                while (i < text.len and count < 6 and std.ascii.isHex(text[i])) : (count += 1) {
                    value = value * 16 + hexValue(text[i]);
                    i += 1;
                }
                if (i < text.len and isWhitespaceChar(text[i])) i += 1;
                if (value == 0 or value > 0x10FFFF) {
                    try buf.append(self.allocator, 0xEF);
                    try buf.append(self.allocator, 0xBF);
                    try buf.append(self.allocator, 0xBD);
                } else {
                    var tmp: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(@intCast(value), &tmp) catch 0;
                    try buf.appendSlice(self.allocator, tmp[0..len]);
                }
                continue;
            }
            if (text[i] == '\r') {
                i += 1;
                if (i < text.len and text[i] == '\n') i += 1;
                continue;
            }
            if (text[i] == '\n' or text[i] == '\x0c') {
                i += 1;
                continue;
            }
            try buf.append(self.allocator, text[i]);
            i += 1;
        }
        return buf.toOwnedSlice(self.allocator);
    }

    fn hexValue(ch: u8) u21 {
        return switch (ch) {
            '0'...'9' => @as(u21, ch - '0'),
            'a'...'f' => @as(u21, ch - 'a' + 10),
            'A'...'F' => @as(u21, ch - 'A' + 10),
            else => 0,
        };
    }

    fn lexNumber(self: *Lexer) Token {
        const start = self.pos;
        if (self.pos < self.source.len and (self.source[self.pos] == '-' or self.source[self.pos] == '+')) {
            self.pos += 1;
        }
        while (self.pos < self.source.len and isDigit(self.source[self.pos])) self.pos += 1;
        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            if (self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1])) {
                self.pos += 1;
                while (self.pos < self.source.len and isDigit(self.source[self.pos])) self.pos += 1;
            }
        }
        // `12.` / `+1.` / `1.}` -- '.' must be followed by a digit (official Sass CLI).
        // Allow `1...` (rest args): first '.' after the integer is followed by another '.'.
        // Inside url(), digits can be part of a path (e.g. url(404.png)), so skip this check.
        if (self.url_paren_depth == 0) {
            if (self.pos < self.source.len and self.source[self.pos] == '.') {
                const nd = if (self.pos + 1 < self.source.len) self.source[self.pos + 1] else 0;
                if (!isDigit(nd) and nd != '.') {
                    const dot_start = self.pos;
                    self.pos += 1;
                    return Token{ .tag = .invalid, .span = .{ .start = dot_start, .end = self.pos } };
                }
            }
        }
        if (self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
            // Peek at what follows `e` / `E`.  Only consume it as an
            // exponent when the next character is a digit (possibly
            // after `+` / `-`).  Otherwise leave `e` / `E` alone so
            // `2em` is tokenised as number `2` + ident `em`, not as
            // a malformed numeric literal `2e` + ident `m`.
            const after_e = self.pos + 1;
            var digit_pos = after_e;
            if (digit_pos < self.source.len and
                (self.source[digit_pos] == '+' or self.source[digit_pos] == '-'))
            {
                digit_pos += 1;
            }
            if (digit_pos < self.source.len and isDigit(self.source[digit_pos])) {
                self.pos = digit_pos + 1;
                while (self.pos < self.source.len and isDigit(self.source[self.pos])) self.pos += 1;
            }
        }
        return Token{ .tag = .number, .span = .{ .start = start, .end = self.pos } };
    }

    fn lexString(self: *Lexer, quote: u8) Token {
        const start = self.pos;
        self.pos += 1;
        var local_interp_depth: u32 = 0;
        while (self.pos < self.source.len) {
            const sc = self.source[self.pos];
            if (local_interp_depth > 0) {
                if (sc == '{') {
                    local_interp_depth += 1;
                    self.pos += 1;
                    continue;
                }
                if (sc == '}') {
                    local_interp_depth -= 1;
                    self.pos += 1;
                    continue;
                }
                if (sc == '/' and self.pos + 1 < self.source.len) {
                    if (self.source[self.pos + 1] == '*') {
                        var closed = false;
                        self.pos += 2;
                        while (self.pos + 1 < self.source.len) {
                            if (self.source[self.pos] == '*' and self.source[self.pos + 1] == '/') {
                                self.pos += 2;
                                closed = true;
                                break;
                            }
                            self.pos += 1;
                        }
                        if (!closed) {
                            return Token{ .tag = .invalid, .span = .{ .start = start, .end = self.pos } };
                        }
                        continue;
                    }
                    if (self.source[self.pos + 1] == '/') {
                        self.pos += 2;
                        while (self.pos < self.source.len and self.source[self.pos] != '\n' and self.source[self.pos] != '\r') {
                            self.pos += 1;
                        }
                        continue;
                    }
                }
                if (sc == '"' or sc == '\'') {
                    _ = self.lexString(sc);
                    continue;
                }
                if (sc == '\\' and self.pos + 1 < self.source.len) {
                    self.pos += 2;
                    continue;
                }
                self.pos += 1;
                continue;
            }
            if (sc == '\\') {
                self.pos += 1;
                if (self.pos >= self.source.len) break;
                const escaped = self.source[self.pos];
                if (escaped == '\n') {
                    self.pos += 1;
                    continue;
                }
                if (escaped == '\r') {
                    self.pos += 1;
                    if (self.pos < self.source.len and self.source[self.pos] == '\n') self.pos += 1;
                    continue;
                }
                if (escaped == 0x0c) {
                    self.pos += 1;
                    continue;
                }
                if (std.ascii.isHex(escaped)) {
                    var hex_count: u32 = 0;
                    while (self.pos < self.source.len and hex_count < 6 and std.ascii.isHex(self.source[self.pos])) {
                        self.pos += 1;
                        hex_count += 1;
                    }
                    if (self.pos < self.source.len and isWhitespaceChar(self.source[self.pos])) self.pos += 1;
                    continue;
                }
                self.pos += 1;
                continue;
            }
            if (sc == '#' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '{') {
                local_interp_depth += 1;
                self.pos += 2;
                continue;
            }
            if (sc == quote) {
                self.pos += 1;
                return Token{ .tag = .string, .span = .{ .start = start, .end = self.pos } };
            }
            if (sc == '\n' or sc == '\r' or sc == 0x0c) return Token{ .tag = .invalid, .span = .{ .start = start, .end = self.pos } };
            self.pos += 1;
        }
        if (local_interp_depth > 0) {
            return Token{ .tag = .invalid, .span = .{ .start = start, .end = self.pos } };
        }
        return Token{ .tag = .string, .span = .{ .start = start, .end = self.pos } };
    }

    fn lexLineComment(self: *Lexer) Token {
        const start = self.pos;
        self.pos += 2;
        while (self.pos < self.source.len and
            self.source[self.pos] != '\n' and
            self.source[self.pos] != '\r' and
            self.source[self.pos] != '\x0c')
        {
            self.pos += 1;
        }
        if (self.is_indented_syntax and self.isIndentedLoudCommentLineStart(start)) {
            const base_indent = self.lineIndentAtByte(start);
            var i: usize = self.pos;
            while (i < self.source.len) {
                const c = self.source[i];
                if (c != '\n' and c != '\r' and c != 0x0c) break;

                var line_start = i + 1;
                if (c == '\r' and line_start < self.source.len and self.source[line_start] == '\n') {
                    line_start += 1;
                }

                var probe = line_start;
                while (probe < self.source.len and (self.source[probe] == ' ' or self.source[probe] == '\t')) : (probe += 1) {}
                if (probe >= self.source.len) {
                    self.pos = @intCast(self.source.len);
                    return Token{ .tag = .comment, .span = .{ .start = start, .end = self.pos } };
                }

                const nc = self.source[probe];
                if (nc == '\n' or nc == '\r' or nc == 0x0c) {
                    i = probe;
                    continue;
                }

                const indent: u32 = @intCast(probe - line_start);
                if (indent <= base_indent) {
                    self.pos = @intCast(line_start);
                    return Token{ .tag = .comment, .span = .{ .start = start, .end = self.pos } };
                }

                i = probe;
                while (i < self.source.len and
                    self.source[i] != '\n' and
                    self.source[i] != '\r' and
                    self.source[i] != '\x0c')
                {
                    i += 1;
                }
            }
            self.pos = @intCast(i);
        }
        return Token{ .tag = .comment, .span = .{ .start = start, .end = self.pos } };
    }

    fn lexBlockComment(self: *Lexer) Token {
        const start = self.pos;
        self.pos += 2;

        if (self.is_indented_syntax and self.isIndentedLoudCommentLineStart(start)) {
            var same_line = self.pos;
            while (same_line + 1 < self.source.len and
                self.source[same_line] != '\n' and
                self.source[same_line] != '\r' and
                self.source[same_line] != '\x0c')
            {
                if (self.source[same_line] == '*' and self.source[same_line + 1] == '/') {
                    self.pos = @intCast(same_line + 2);
                    return Token{ .tag = .comment, .span = .{ .start = start, .end = self.pos } };
                }
                same_line += 1;
            }

            // Indented `.sass` loud comments can omit the closing `*/` and end
            // at dedent/EOF. Recover by consuming until the first dedented line.
            // If a continuation line contains an explicit `*/`, stop there.
            const base_indent = self.lineIndentAtByte(start);
            var i: usize = self.pos;
            while (i < self.source.len) : (i += 1) {
                if (i + 1 < self.source.len and self.source[i] == '*' and self.source[i + 1] == '/') {
                    self.pos = @intCast(i + 2);
                    return Token{ .tag = .comment, .span = .{ .start = start, .end = self.pos } };
                }

                const c = self.source[i];
                if (c == '\n' or c == '\r' or c == 0x0c) {
                    var line_start = i + 1;
                    if (c == '\r' and line_start < self.source.len and self.source[line_start] == '\n') {
                        line_start += 1;
                    }

                    var probe = line_start;
                    while (probe < self.source.len and (self.source[probe] == ' ' or self.source[probe] == '\t')) : (probe += 1) {}
                    if (probe >= self.source.len) {
                        self.pos = @intCast(self.source.len);
                        return Token{ .tag = .comment, .span = .{ .start = start, .end = self.pos } };
                    }

                    const nc = self.source[probe];
                    if (nc == '\n' or nc == '\r' or nc == 0x0c) continue; // blank line

                    const indent: u32 = @intCast(probe - line_start);
                    if (indent <= base_indent) {
                        self.pos = @intCast(line_start);
                        return Token{ .tag = .comment, .span = .{ .start = start, .end = self.pos } };
                    }
                }
            }

            self.pos = @intCast(self.source.len);
            return Token{ .tag = .comment, .span = .{ .start = start, .end = self.pos } };
        }

        while (self.pos + 1 < self.source.len) {
            if (self.source[self.pos] == '*' and self.source[self.pos + 1] == '/') {
                self.pos += 2;
                return Token{ .tag = .comment, .span = .{ .start = start, .end = self.pos } };
            }
            self.pos += 1;
        }

        self.pos = @intCast(self.source.len);
        return Token{ .tag = .invalid, .span = .{ .start = start, .end = self.pos } };
    }

    fn lineStartAtByte(self: *const Lexer, byte_pos: u32) u32 {
        return token_mod.lineStartAtByte(self.source, byte_pos);
    }

    fn lineIndentAtByte(self: *const Lexer, byte_pos: u32) u32 {
        return token_mod.lineIndentAtByte(self.source, byte_pos);
    }

    fn isIndentedLoudCommentLineStart(self: *const Lexer, byte_pos: u32) bool {
        const line_start = self.lineStartAtByte(byte_pos);
        var i: usize = line_start;
        const target: usize = @intCast(byte_pos);
        while (i < target) : (i += 1) {
            const c = self.source[i];
            if (c != ' ' and c != '\t') return false;
        }
        return true;
    }
};

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}
fn isWhitespaceChar(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == '\x0c';
}
fn isClassSelectorLead(ch: u8) bool {
    return isIdentStart(ch) or ch == '-' or ch == '\\';
}
fn isIdentStart(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_' or ch >= 0x80;
}
fn isIdentChar(ch: u8) bool {
    return isIdentStart(ch) or isDigit(ch) or ch == '-';
}

const ParenFunctionKind = enum { none, url, css_special };

fn parenFunctionKindBefore(source: []const u8, paren_pos: u32) ParenFunctionKind {
    if (paren_pos == 0) return .none;
    var i: usize = @intCast(paren_pos);

    // Allow horizontal whitespace between the function name and `(`.
    while (i > 0 and (source[i - 1] == ' ' or source[i - 1] == '\t')) : (i -= 1) {}
    const end = i;
    if (end == 0) return .none;

    // First inspect just the nearest identifier-ish segment before `(` so
    // `background-image:url(` resolves to `url`, not `background-image:url`.
    var start = end;
    while (start > 0) {
        const ch = source[start - 1];
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') {
            start -= 1;
            continue;
        }
        break;
    }
    if (start < end) {
        const base_name = source[start..end];
        if (isUrlFuncName(base_name)) return .url;
        if (isCssSpecialFuncName(base_name)) return .css_special;
    }

    i = start;
    while (i > 0) {
        const ch = source[i - 1];
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == ':' or ch == '.') {
            i -= 1;
            continue;
        }
        break;
    }
    if (i >= end) return .none;

    const name = source[i..end];
    if (isUrlFuncName(name)) return .url;
    if (isCssSpecialFuncName(name)) return .css_special;
    return .none;
}

fn isCssSpecialFuncName(name: []const u8) bool {
    var base = name;
    if (base.len > 1 and base[0] == '-') {
        if (std.mem.findScalarPos(u8, base, 1, '-')) |dash| {
            base = base[dash + 1 ..];
        }
    }
    if (base.len >= 7 and std.ascii.eqlIgnoreCase(base[0..6], "progid") and base[6] == ':') {
        return true;
    }
    const special_names = [_][]const u8{ "calc", "element", "expression", "progid" };
    for (special_names) |sn| {
        if (std.ascii.eqlIgnoreCase(base, sn)) return true;
    }
    return false;
}

fn isUrlFuncName(name: []const u8) bool {
    var base = name;
    if (base.len > 1 and base[0] == '-') {
        if (std.mem.findScalarPos(u8, base, 1, '-')) |dash| {
            base = base[dash + 1 ..];
        }
    }
    const url_names = [_][]const u8{ "url", "url-prefix", "domain", "regexp" };
    for (url_names) |un| {
        if (std.ascii.eqlIgnoreCase(base, un)) return true;
    }
    return false;
}

fn reasonText(reason: Lexer.ErrorReason) []const u8 {
    return switch (reason) {
        .invalid_token => "invalid token",
        .unterminated_string => "unterminated string",
        .unterminated_block_comment => "unterminated block comment",
        .trailing_dot_number => "number cannot end with '.'",
    };
}

fn sanitizeSample(buf: []u8, text: []const u8) []const u8 {
    if (text.len == 0) {
        const empty = "<empty>";
        @memcpy(buf[0..empty.len], empty);
        return buf[0..empty.len];
    }

    const max_bytes = @min(text.len, 40);
    var out: usize = 0;
    for (text[0..max_bytes]) |c| {
        const escaped: ?[]const u8 = switch (c) {
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            '\x0c' => "\\f",
            else => null,
        };
        if (escaped) |e| {
            if (out + e.len > buf.len) break;
            @memcpy(buf[out .. out + e.len], e);
            out += e.len;
            continue;
        }
        if (out == buf.len) break;
        buf[out] = if (std.ascii.isPrint(c)) c else '?';
        out += 1;
    }

    if (text.len > max_bytes and out + 3 <= buf.len) {
        @memcpy(buf[out .. out + 3], "...");
        out += 3;
    }
    return buf[0..out];
}

test "empty input" {
    var lexer = Lexer.init(std.testing.allocator, "");
    defer lexer.deinit();
    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try std.testing.expectEqual(Token.Tag.eof, tokens[0].tag);
}

test "simple selector and property" {
    const source = "body { color: red; }";
    var lexer = Lexer.init(std.testing.allocator, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();
    var i: usize = 0;
    try std.testing.expectEqual(Token.Tag.ident, tokens[i].tag);
    i += 1;
    try std.testing.expectEqual(Token.Tag.whitespace, tokens[i].tag);
    i += 1;
    try std.testing.expectEqual(Token.Tag.lbrace, tokens[i].tag);
    i += 1;
    try std.testing.expectEqual(Token.Tag.whitespace, tokens[i].tag);
    i += 1;
    try std.testing.expectEqual(Token.Tag.ident, tokens[i].tag);
    i += 1;
    try std.testing.expectEqual(Token.Tag.colon, tokens[i].tag);
    i += 1;
    try std.testing.expectEqual(Token.Tag.whitespace, tokens[i].tag);
    i += 1;
    try std.testing.expectEqual(Token.Tag.ident, tokens[i].tag);
    i += 1;
    try std.testing.expectEqual(Token.Tag.semicolon, tokens[i].tag);
    i += 1;
    try std.testing.expectEqual(Token.Tag.whitespace, tokens[i].tag);
    i += 1;
    try std.testing.expectEqual(Token.Tag.rbrace, tokens[i].tag);
    i += 1;
    try std.testing.expectEqual(Token.Tag.eof, tokens[i].tag);
}

test "interpolation" {
    const source = "#{$var}";
    var lexer = Lexer.init(std.testing.allocator, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(Token.Tag.hash_lbrace, tokens[0].tag);
    try std.testing.expectEqual(Token.Tag.dollar_ident, tokens[1].tag);
    try std.testing.expectEqual(Token.Tag.rbrace, tokens[2].tag);
}

test "escaped variable names stay in one dollar_ident token" {
    const source = "$foo\\bar: 1;";
    var lexer = Lexer.init(std.testing.allocator, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    try std.testing.expectEqual(Token.Tag.dollar_ident, tokens[0].tag);
    try std.testing.expectEqualStrings("$foo\\bar", tokens[0].span.slice(source));
    try std.testing.expectEqual(Token.Tag.colon, tokens[1].tag);
}

test "string interpolation ignores block comment quotes" {
    const source = "\"#{ a /*#{\\\"}*/ }\"";
    var lexer = Lexer.init(std.testing.allocator, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expectEqual(Token.Tag.string, tokens[0].tag);
    try std.testing.expectEqual(Token.Tag.eof, tokens[1].tag);
}

test "comments" {
    const source = "/* block */ // line\na {}";
    var lexer = Lexer.init(std.testing.allocator, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(Token.Tag.comment, tokens[0].tag);
    try std.testing.expectEqual(Token.Tag.comment, tokens[2].tag);
}

test "indented loud comment without closing */ accepts CR newline" {
    const source = "/*\n  foo\r  bar\n";
    var lexer = Lexer.init(std.testing.allocator, source);
    lexer.is_indented_syntax = true;
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    try std.testing.expectEqual(Token.Tag.comment, tokens[0].tag);
    try std.testing.expectEqual(Token.Tag.eof, tokens[tokens.len - 1].tag);
    for (tokens) |tok| {
        try std.testing.expect(tok.tag != .invalid);
    }
}

test "indented loud comment without closing */ accepts FF newline" {
    const source = "/*\n  foo\x0c  bar\n";
    var lexer = Lexer.init(std.testing.allocator, source);
    lexer.is_indented_syntax = true;
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    try std.testing.expectEqual(Token.Tag.comment, tokens[0].tag);
    try std.testing.expectEqual(Token.Tag.eof, tokens[tokens.len - 1].tag);
    for (tokens) |tok| {
        try std.testing.expect(tok.tag != .invalid);
    }
}

test "indented silent sassdoc comment consumes indented metadata" {
    const source = "///\n  @overload f($x)\n///\n@function f($x)\n";
    var lexer = Lexer.init(std.testing.allocator, source);
    lexer.is_indented_syntax = true;
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    try std.testing.expectEqual(Token.Tag.comment, tokens[0].tag);
    try std.testing.expectEqual(Token.Tag.comment, tokens[1].tag);
    try std.testing.expectEqual(Token.Tag.at_function, tokens[2].tag);
    try std.testing.expectEqualStrings("@function", tokens[2].span.slice(source));
}

test "unterminated string captures diagnostic span" {
    const source = "a {\n  content: \"broken\n}\n";
    var lexer = Lexer.init(std.testing.allocator, source);
    defer lexer.deinit();

    try std.testing.expectError(error.SyntaxError, lexer.tokenize());
    const detail = lexer.last_error_detail orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(Lexer.ErrorReason.unterminated_string, detail.reason);
    try std.testing.expectEqualStrings("\"broken", detail.span.slice(source));
}

test "adjacent sibling before class is not lexed as number" {
    const source = ".foo+.bar { color: red; }";
    var lexer = Lexer.init(std.testing.allocator, source);
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(Token.Tag.dot, tokens[0].tag);
    try std.testing.expectEqual(Token.Tag.ident, tokens[1].tag);
    try std.testing.expectEqual(Token.Tag.plus, tokens[2].tag);
    try std.testing.expectEqual(Token.Tag.dot, tokens[3].tag);
    try std.testing.expectEqual(Token.Tag.ident, tokens[4].tag);
}

test "plus dot without class or digit stays syntax error" {
    const source = "a { b: +.; c: -.; }";
    var lexer = Lexer.init(std.testing.allocator, source);
    defer lexer.deinit();

    try std.testing.expectError(error.SyntaxError, lexer.tokenize());
}

test "signed decimal still lexes as number" {
    const source = ".foo { opacity: +.5; margin: -.25rem; }";
    var lexer = Lexer.init(std.testing.allocator, source);
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    var saw_pos = false;
    var saw_neg = false;
    for (tokens) |tok| {
        if (tok.tag != .number) continue;
        const text = tok.span.slice(source);
        if (std.mem.eql(u8, text, "+.5")) saw_pos = true;
        if (std.mem.eql(u8, text, "-.25")) saw_neg = true;
    }
    try std.testing.expect(saw_pos);
    try std.testing.expect(saw_neg);
}
