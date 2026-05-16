/// parser.zig -- rewrite parser targeting ast_flat.Ast.
///
/// Imported by `src/runtime/vm.zig` and `src/resolve/resolver.zig` on the
/// rewrite path.
/// The file coexists with legacy `src/parser.zig` during migration while
/// parser/resolver/runtime behaviour is converged behind tests and spec runs.
const std = @import("std");
const token_mod = @import("../frontend/token.zig");
const lexer_mod = @import("lexer.zig");
const Token = token_mod.Token;
const Span = token_mod.Span;
const ast_flat = @import("ast_flat.zig");
const Ast = ast_flat.Ast;
const NodeIndex = ast_flat.NodeIndex;
const AstTag = ast_flat.AstTag;
const ExtraIndex = ast_flat.ExtraIndex;
const LIST_FLAG_TRAILING_COMMA = ast_flat.LIST_FLAG_TRAILING_COMMA;
const intern_pool_mod = @import("../runtime/intern_pool.zig");
const InternPool = intern_pool_mod.InternPool;
const InternId = intern_pool_mod.InternId;
const BinOp = ast_flat.BinOp;
const UnaryOp = ast_flat.UnaryOp;
const error_format = @import("../runtime/error_format.zig");

const ParseError = error{ UnexpectedEof, OutOfMemory, SyntaxError, HardSyntaxError };

/// Identifier tokens that leave the parser in unary-operator context when they
/// appear immediately before `+` / `-` / `/`. Covers logical operators
/// (`or` / `and` / `not`) and the `@for` / `@each` loop keywords that
/// introduce a value slot (`through` / `to` / `from` / `in`).
const unary_context_keywords = std.StaticStringMap(void).initComptime(.{
    .{ "or", {} },
    .{ "and", {} },
    .{ "not", {} },
    .{ "through", {} },
    .{ "to", {} },
    .{ "from", {} },
    .{ "in", {} },
});

/// SCSS Parser -- emits ast_flat.Ast.
///
/// `tokens` and `pos` are public so compiler.zig's syntax-diagnostic helper
/// can point at the failing token after a parse error, mirroring the existing
/// parser.zig contract.
pub const Parser = struct {
    tokens: []const Token,
    source: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,
    intern_pool: *InternPool,

    /// True when parsing inside a CSS Custom Function (`@function --name`)
    /// body. Mirrors the legacy parser.zig flag: used by future sub-commits
    /// to treat `result: {}` as a declaration rather than a propset.
    in_css_custom_function: bool = false,

    /// Queue of extra statement nodes produced while parsing one logical
    /// statement.  Currently used by `parseImportRule` to emit additional
    /// `stmt_import` nodes for comma-separated `@import "a", "b";` lists.
    /// The parse loops (top-level `parse` and `parseBlockBody`) drain this
    /// queue after every `parseStatement` call.
    pending_statements: std.ArrayListUnmanaged(NodeIndex) = .empty,

    /// True when a comma-separated `@import "a", "b";` list was encountered.
    /// Used by the plain-CSS `@import` path to reject Sass-only features
    /// when the imported file is being parsed as plain CSS (plain CSS
    /// forbids multiple URLs in a single `@import`).  Silent comments are
    /// detected by scanning the token stream directly.
    had_multi_import: bool = false,

    /// Nesting depth of function-call argument parsing.  Incremented in
    /// `parseCallArgsListRaw` and decremented on exit.  Used by
    /// `parseIdentAtom` to decide whether a bare `ns.name` (without
    /// parentheses) should be tolerated as a CSS-like joined identifier
    /// (inside `url(blah.css)` etc.) or rejected as an ill-formed Sass
    /// namespace reference (top-level value position).
    call_arg_depth: u32 = 0,

    /// True when parsing indented-syntax `.sass` input.
    ///
    /// Default is SCSS (`false`) so existing parser unit tests keep their
    /// behavior unless they explicitly opt in.
    is_indented_syntax: bool = false,

    /// Set by the caller when the token stream is known to contain zero
    /// `hash_lbrace` (`#{`) tokens -- i.e. there's no Sass interpolation in
    /// this source. Enables `parseRuleOrDeclaration` to take a streamlined
    /// fast path that omits interp_depth tracking and the `--name`
    /// interpolation-aware lookahead. Default `false` keeps the safe path
    /// for sub-parsers that don't have the lexer's `saw_interpolation` flag
    /// available (interpolation body re-parse, expression-only parses).
    no_interpolation: bool = false,

    /// True while re-parsing the body of a `#{...}` interpolation.
    ///
    /// Interpolation uses Sass "unquoted" semantics for nested strings, so
    /// parser-side quote-preservation helpers are disabled in this mode.
    in_interpolation_body: bool = false,
    /// True while parsing a declaration value (`prop: <value>`).
    ///
    /// Used to keep CSS special/url-like function calls in opaque raw form
    /// so evaluator-side CSS normalization handles escapes/comments.
    in_declaration_value_context: bool = false,

    /// True when an expression parse consumed a binary operator and then hit a
    /// declaration terminator before finding any right-hand operand token.
    /// Declaration value parsing uses this to fatal (`Expected expression.`)
    /// instead of silently rewinding to raw passthrough.
    saw_incomplete_binary_rhs: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        intern_pool: *InternPool,
        tokens: []const Token,
        source: []const u8,
    ) Parser {
        return .{
            .tokens = tokens,
            .source = source,
            .pos = 0,
            .allocator = allocator,
            .intern_pool = intern_pool,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.pending_statements.deinit(self.allocator);
    }

    /// Build a sub-Parser over `tokens` (typically `self.tokens[a..b]`) that
    /// inherits the contextual flags relevant for nested expression/value
    /// parsing. The interpolation-body sub-parser at the bottom of this file
    /// has different rules and does not use this helper.
    fn createSubParser(self: *const Parser, tokens: []const Token) Parser {
        var sub = Parser.init(self.allocator, self.intern_pool, tokens, self.source);
        sub.in_css_custom_function = self.in_css_custom_function;
        sub.call_arg_depth = self.call_arg_depth;
        sub.is_indented_syntax = self.is_indented_syntax;
        sub.in_interpolation_body = self.in_interpolation_body;
        return sub;
    }

    /// CLI-FIX-E Step 2b: Call from errdefer and return "the span of the token that was most recently processed".
    /// The case that reaches the EOF token (= the end of source) is compatible with official Sass CLI and is "before the newline at the end of source"
    // Returns /// as a point (= the position of "I read this far but there is no }").
    fn currentTokenSpan(self: *const Parser) Span {
        if (self.tokens.len == 0) {
            const end: u32 = @intCast(self.source.len);
            return .{ .start = end, .end = end };
        }
        const idx: usize = if (self.pos < self.tokens.len) self.pos else self.tokens.len - 1;
        const tok = self.tokens[idx];
        if (tok.tag == .eof) {
            // Skip the trailing newline (\n / \r) and return the position at the end of the previous line as point.
            // Because official Sass CLI's `expected "}"` outputs the col just before the line break as 1-indexed.
            var p = tok.span.start;
            while (p > 0) {
                const c = self.source[p - 1];
                if (c == '\n' or c == '\r') {
                    p -= 1;
                } else break;
            }
            return .{ .start = p, .end = p };
        }
        return tok.span;
    }

    /// Consume the token stream and return a fully populated `Ast`.
    ///
    /// Reserve the `stylesheet_root` slot, walk the top-level statement
    /// stream, and patch the root's payload with the resulting child
    /// list once parsing is done.
    pub fn parse(self: *Parser) ParseError!Ast {
        var ast = Ast.init(self.allocator, self.source, .none);
        errdefer ast.deinit();
        // CLI-FIX-E Step 2b: When parse error occurs, record the span of the most recent token in thread-local.
        // Points to source_end for EOF token. If it is already set in a deep frame, it will not be overwritten.
        errdefer |err| {
            const span = self.currentTokenSpan();
            error_format.recordErrorSpanIfUnset(span.start, span.end, 0);
            error_format.recordErrorTag(err);
        }

        const source_end: u32 = @intCast(self.source.len);

        const root_idx = try ast.addNode(.{
            .tag = .stylesheet_root,
            .flags = 0,
            .payload = 0,
            .span_start = 0,
            .span_end = source_end,
        });

        var children: std.ArrayListUnmanaged(NodeIndex) = .empty;
        defer children.deinit(self.allocator);

        while (true) {
            self.skipTrivia();
            if (self.isAtEnd()) break;
            // Tolerate stray top-level semicolons (matches legacy
            // parser.zig -- some files end a statement with `};`).
            while (!self.isAtEnd() and self.current().tag == .semicolon) {
                self.advance();
                self.skipTrivia();
            }
            if (self.isAtEnd()) break;

            const stmt = try self.parseStatement(&ast);
            try children.ensureUnusedCapacity(self.allocator, 1 + self.pending_statements.items.len);
            children.appendAssumeCapacity(stmt);
            // Drain any additional nodes queued during parseStatement.
            for (self.pending_statements.items) |extra| {
                children.appendAssumeCapacity(extra);
            }
            self.pending_statements.clearRetainingCapacity();
        }

        // Patch the root node with the assembled children list:
        //   extra = [child_count: u32, child_idx_0, child_idx_1, ...]
        const extra_off = try ast.appendExtraU32(@intCast(children.items.len));
        for (children.items) |c| {
            _ = try ast.appendExtraU32(c.toU32());
        }
        ast.setPayload(root_idx, extra_off);
        ast.root = root_idx;

        return ast;
    }

    // -- statement parsing (R.2c.3: simple statements) ------------------------

    /// Dispatch one statement based on the current (non-trivia) token.
    /// The default branch routes to `parseRuleOrDeclaration`, which
    /// decides between a style rule and a property declaration by
    /// scanning ahead for the first `{` / `;` / `}` at depth zero.
    fn parseStatement(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        self.skipTrivia();
        if (self.isAtEnd()) return error.UnexpectedEof;

        const tok = self.current();
        return switch (tok.tag) {
            .comment => self.parseCommentStmt(ast),
            .dollar_ident => self.parseVariableDeclStmt(ast),
            .at_return => self.parseSimpleAtRuleValue(ast, .stmt_return),
            .at_debug => self.parseSimpleAtRuleValue(ast, .stmt_debug),
            .at_warn => self.parseSimpleAtRuleValue(ast, .stmt_warn),
            .at_error => self.parseSimpleAtRuleValue(ast, .stmt_error),
            .at_if => self.parseIfRule(ast),
            .at_else => return error.SyntaxError,
            .at_each => self.parseEachRule(ast),
            .at_for => self.parseForRule(ast),
            .at_while => self.parseWhileRule(ast),
            .at_use => self.parseUseRule(ast),
            .at_forward => self.parseForwardRule(ast),
            .at_import => self.parseImportRule(ast),
            .at_content => self.parseContentRule(ast),
            .at_extend => self.parseExtendRule(ast),
            .at_at_root => self.parseAtRootRule(ast),
            .at_mixin => self.parseMixinDecl(ast),
            .at_function => self.parseFunctionDecl(ast),
            .at_include => self.parseIncludeRule(ast),
            .equal => if (self.is_indented_syntax) self.parseSassEqualsMixinDecl(ast) else self.parseRuleOrDeclaration(ast),
            .plus => if (self.isSassPlusIncludeStart()) self.parseSassPlusIncludeRule(ast) else self.parseRuleOrDeclaration(ast),
            .bang => error.SyntaxError,
            .at_media,
            .at_supports,
            .at_keyframes,
            .at_font_face,
            .at_charset,
            .at_keyword,
            => self.parseAtRule(ast),
            else => self.parseRuleOrDeclaration(ast),
        };
    }

    fn isSassPlusIncludeStart(self: *const Parser) bool {
        if (!self.is_indented_syntax) return false;
        if (self.pos >= self.tokens.len or self.tokens[self.pos].tag != .plus) return false;
        const plus_tok = self.tokens[self.pos];
        const next_pos = self.pos + 1;
        if (next_pos >= self.tokens.len) return false;
        const next_tok = self.tokens[next_pos];
        if (next_tok.tag != .ident) return false;
        // `+mixin` shorthand only. Keep `+ <selector>` as selector combinator.
        return next_tok.span.start == plus_tok.span.end;
    }

    // -- style rules + declarations (R.2c.6a) --------------------------------

    /// Lookahead dispatch: inspect the forthcoming token stream to
    /// decide whether we are parsing a style rule (selector + block)
    /// or a declaration (`property: value;`).  Simplified from legacy
    /// parser.zig:parseRuleOrDeclaration -- scan forward at depth zero
    /// (tracking paren / bracket / interp) and check whichever of
    /// `{` / `;` / `}` / EOF arrives first: `{`  =>  style rule,
    /// anything else  =>  declaration.
    ///
    /// Pseudo-class colons inside selectors (`:hover`, `::before`,
    /// `:not(...)`) are handled implicitly: the first `{` after such
    /// a selector still comes before any `;`, so the style-rule branch
    /// is selected correctly.
    fn parseRuleOrDeclaration(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        // A statement cannot start with a bare `,` -- that only happens
        // when a previous `}` was followed by `,` in the source
        // (libsass-closed-issues/issue_2365), which is invalid Sass.
        if (self.pos < self.tokens.len and self.tokens[self.pos].tag == .comma) {
            return error.SyntaxError;
        }
        if (self.startsBareCommentCloseLine(self.pos)) return error.SyntaxError;

        // CSS Custom Property declarations (`--name: ...`) are always
        // declarations, even when the value begins with `{` -- parser
        // would otherwise treat `--name: { a: b }` as a style rule
        // selector `--name:` followed by a block.  Detect the `--`
        // prefix early and dispatch to parseDeclaration only when a
        // colon follows (otherwise `--selector { ... }` -- a nested rule
        // using a custom property name as the selector -- would be
        // mis-classified; see issue_2358).
        //
        // Interpolation inside the property name (e.g. `--#{foo}: {...}`)
        // is supported by skipping balanced `#{...}` runs in the scan; the
        // final token before the colon is then inside an interp, so the
        // post-interp `:` still wins the lookahead over any later `{`.
        if (self.pos < self.tokens.len and self.tokens[self.pos].tag == .ident) {
            const first_text = self.tokens[self.pos].slice(self.source);
            if (first_text.len >= 2 and first_text[0] == '-' and first_text[1] == '-') {
                var p = self.pos + 1;
                var scan_interp: u32 = 0;
                while (p < self.tokens.len) {
                    const pt = self.tokens[p].tag;
                    if (pt == .hash_lbrace) {
                        scan_interp += 1;
                        p += 1;
                        continue;
                    }
                    if (pt == .rbrace and scan_interp > 0) {
                        scan_interp -= 1;
                        p += 1;
                        continue;
                    }
                    if (scan_interp > 0) {
                        p += 1;
                        continue;
                    }
                    if (pt == .whitespace or pt == .newline or pt == .comment) {
                        p += 1;
                        continue;
                    }
                    break;
                }
                if (p < self.tokens.len and self.tokens[p].tag == .colon) {
                    return self.parseDeclaration(ast);
                }
            }
        }

        // Inside a CSS Custom Function body, the specific pattern
        // `<plain ident>:  { ... }` is a declaration whose value is a
        // raw `{...}` run (e.g. `result: {}#&%^*;`).  Interpolated
        // property names (`#{result}: { ... }`) remain propset candidates
        // and fall through to the normal lookahead below.
        if (self.in_css_custom_function and self.pos < self.tokens.len and
            self.tokens[self.pos].tag == .ident)
        {
            var p = self.pos + 1;
            while (p < self.tokens.len) {
                const pt = self.tokens[p].tag;
                if (pt == .whitespace or pt == .newline or pt == .comment) {
                    p += 1;
                    continue;
                }
                break;
            }
            if (p < self.tokens.len and self.tokens[p].tag == .colon) {
                p += 1;
                while (p < self.tokens.len) {
                    const pt = self.tokens[p].tag;
                    if (pt == .whitespace or pt == .newline or pt == .comment) {
                        p += 1;
                        continue;
                    }
                    break;
                }
                if (p < self.tokens.len and self.tokens[p].tag == .lbrace) {
                    return self.parseDeclaration(ast);
                }
            }
        }

        // Fast path: when the lexer reported zero `#{` interpolations and the
        // input is not indented `.sass`, the lookahead reduces to balanced
        // paren/bracket tracking + first `{`/`;`/`}` at depth zero. This
        // skips per-token `hash_lbrace`/`rbrace`-interp pair tracking and the
        // indented-syntax deep-line `{` check, both of which are dead code
        // for plain CSS / interp-free SCSS sources.
        if (self.no_interpolation and !self.is_indented_syntax) {
            var scan_fp = self.pos;
            var depth_fp: u32 = 0;
            var found_brace_fp = false;
            fp_loop: while (scan_fp < self.tokens.len) : (scan_fp += 1) {
                const t = self.tokens[scan_fp].tag;
                if (t == .eof) break;
                if (t == .lparen or t == .lbracket) {
                    depth_fp += 1;
                } else if (t == .rparen or t == .rbracket) {
                    if (depth_fp > 0) depth_fp -= 1;
                } else if (depth_fp == 0) {
                    if (t == .lbrace) {
                        found_brace_fp = true;
                        break :fp_loop;
                    }
                    if (t == .semicolon or t == .rbrace) break :fp_loop;
                }
            }
            if (found_brace_fp) return self.parseStyleRule(ast);
            return self.parseDeclaration(ast);
        }

        const stmt_start_tok = self.tokens[self.pos];
        const stmt_line_start = self.lineStartAtByte(stmt_start_tok.span.start);
        const stmt_indent = self.lineIndentAtByte(stmt_start_tok.span.start);

        var scan = self.pos;
        var depth: u32 = 0;
        var interp_depth: u32 = 0;
        var found_brace = false;

        while (scan < self.tokens.len) {
            const t = self.tokens[scan].tag;
            if (t == .eof) break;

            if (t == .hash_lbrace) {
                interp_depth += 1;
                scan += 1;
                continue;
            }
            if (t == .rbrace and interp_depth > 0) {
                interp_depth -= 1;
                scan += 1;
                continue;
            }
            if (interp_depth > 0) {
                scan += 1;
                continue;
            }

            if (t == .lparen or t == .lbracket) {
                depth += 1;
                scan += 1;
                continue;
            }
            if ((t == .rparen or t == .rbracket) and depth > 0) {
                depth -= 1;
                scan += 1;
                continue;
            }
            if (depth > 0) {
                scan += 1;
                continue;
            }

            if (t == .lbrace) {
                if (self.is_indented_syntax) {
                    const brace_tok = self.tokens[scan];
                    const brace_line_start = self.lineStartAtByte(brace_tok.span.start);
                    const brace_indent = self.lineIndentAtByte(brace_tok.span.start);
                    if (brace_line_start > stmt_line_start and brace_indent > stmt_indent) {
                        // `.sass`: a `{` that appears only on a deeper line
                        // belongs to a nested value (`--x: { ... }`) rather
                        // than this statement's block opener.
                        scan += 1;
                        continue;
                    }
                }
                found_brace = true;
                break;
            }
            if (t == .semicolon or t == .rbrace) break;
            scan += 1;
        }

        if (found_brace) return self.parseStyleRule(ast);

        if (!self.is_indented_syntax) return self.parseDeclaration(ast);

        // Indented syntax has no `{}` block marker for style rules.
        // Try declaration first (most common inside rule bodies), and when
        // that clearly fails (`expected ":"`), reinterpret as an indented
        // style rule (`selector` + nested body).
        const saved_pos = self.pos;
        // In indented syntax, a top-level `:` with no following whitespace is
        // a selector-like header (`baz:bam`, `&:hover`, `::before`) rather
        // than a property declaration, so parse it as a nested style rule
        // before declaration parsing can incorrectly succeed.
        if (self.shouldFallbackIndentedStyleRuleOnHardDeclError(saved_pos)) {
            return self.parseIndentedStyleRule(ast);
        }
        if (self.parseDeclaration(ast)) |decl| {
            return decl;
        } else |err| switch (err) {
            error.SyntaxError => {
                if (self.lineContainsTopLevelColon(saved_pos) and
                    !self.shouldFallbackIndentedStyleRuleOnHardDeclError(saved_pos))
                {
                    return error.SyntaxError;
                }
                self.pos = saved_pos;
                return self.parseIndentedStyleRule(ast);
            },
            error.HardSyntaxError => {
                if (!self.shouldFallbackIndentedStyleRuleOnHardDeclError(saved_pos) and
                    !self.shouldFallbackIndentedPropertyNamespaceOnHardDeclError(saved_pos))
                {
                    return error.SyntaxError;
                }
                self.pos = saved_pos;
                return self.parseIndentedStyleRule(ast);
            },
            else => return err,
        }
    }

    fn startsBareCommentCloseLine(self: *const Parser, start_pos: usize) bool {
        if (!self.is_indented_syntax) return false;
        if (start_pos + 1 >= self.tokens.len) return false;

        const first = self.tokens[start_pos];
        if (first.tag != .star) return false;

        const second = self.tokens[start_pos + 1];
        if (second.tag != .slash) return false;
        if (second.span.start != first.span.end) return false;
        return self.lineStartAtByte(first.span.start) == self.lineStartAtByte(second.span.start);
    }

    fn shouldFallbackIndentedStyleRuleOnHardDeclError(self: *const Parser, start_pos: usize) bool {
        if (!self.is_indented_syntax) return false;
        if (start_pos >= self.tokens.len) return false;

        const start_tok = self.tokens[start_pos];
        const header_has_interp = self.lineHasInterpolationBeforeColon(start_pos);
        if (self.in_css_custom_function and !header_has_interp) return false;
        if (start_tok.tag == .ident) {
            const text = start_tok.slice(self.source);
            if (text.len >= 2 and text[0] == '-' and text[1] == '-') {
                // Custom properties must stay declaration errors.
                return false;
            }
        }

        // Reinterpret as selector only for pseudo-selector-like headers where
        // the top-level `:` is immediately followed by the next token
        // (`a:b(...)`).  Ordinary declarations (`a: b`) keep the declaration
        // error path.
        var p = start_pos;
        var depth: u32 = 0;
        var interp_depth: u32 = 0;
        while (p < self.tokens.len) : (p += 1) {
            const tok = self.tokens[p];
            if (tok.tag == .hash_lbrace) {
                interp_depth += 1;
                continue;
            }
            if (tok.tag == .rbrace and interp_depth > 0) {
                interp_depth -= 1;
                continue;
            }
            if (interp_depth > 0) continue;

            if (tok.tag == .lparen or tok.tag == .lbracket) {
                depth += 1;
                continue;
            }
            if ((tok.tag == .rparen or tok.tag == .rbracket) and depth > 0) {
                depth -= 1;
                continue;
            }
            if (depth > 0) continue;

            if (tok.tag == .colon) {
                if (self.in_css_custom_function and header_has_interp) return true;
                var q = p + 1;
                while (q < self.tokens.len) : (q += 1) {
                    const qt = self.tokens[q].tag;
                    if (qt == .whitespace or qt == .newline or qt == .comment) continue;
                    break;
                }
                if (q >= self.tokens.len) return false;
                return self.tokens[q].span.start == tok.span.end;
            }
            if (tok.tag == .newline or tok.tag == .semicolon or tok.tag == .rbrace or tok.tag == .eof) break;
        }

        return false;
    }

    fn lineHasInterpolationBeforeColon(self: *const Parser, start_pos: usize) bool {
        if (start_pos >= self.tokens.len) return false;

        var p = start_pos;
        var depth: u32 = 0;
        var interp_depth: u32 = 0;
        while (p < self.tokens.len) : (p += 1) {
            const tok = self.tokens[p];
            if (tok.tag == .hash_lbrace) {
                if (interp_depth == 0) return true;
                interp_depth += 1;
                continue;
            }
            if (tok.tag == .rbrace and interp_depth > 0) {
                interp_depth -= 1;
                continue;
            }
            if (interp_depth > 0) continue;

            if (tok.tag == .lparen or tok.tag == .lbracket) {
                depth += 1;
                continue;
            }
            if ((tok.tag == .rparen or tok.tag == .rbracket) and depth > 0) {
                depth -= 1;
                continue;
            }
            if (depth > 0) continue;

            if (tok.tag == .colon or tok.tag == .newline or tok.tag == .semicolon or tok.tag == .rbrace or tok.tag == .eof) break;
        }
        return false;
    }

    fn lineContainsTopLevelColon(self: *const Parser, start_pos: usize) bool {
        if (start_pos >= self.tokens.len) return false;

        var p = start_pos;
        var depth: u32 = 0;
        var interp_depth: u32 = 0;
        while (p < self.tokens.len) : (p += 1) {
            const tok = self.tokens[p];
            if (tok.tag == .hash_lbrace) {
                interp_depth += 1;
                continue;
            }
            if (tok.tag == .rbrace and interp_depth > 0) {
                interp_depth -= 1;
                continue;
            }
            if (interp_depth > 0) continue;

            if (tok.tag == .lparen or tok.tag == .lbracket) {
                depth += 1;
                continue;
            }
            if ((tok.tag == .rparen or tok.tag == .rbracket) and depth > 0) {
                depth -= 1;
                continue;
            }
            if (depth > 0) continue;

            if (tok.tag == .colon) return true;
            if (tok.tag == .newline or tok.tag == .semicolon or tok.tag == .rbrace or tok.tag == .eof) break;
        }
        return false;
    }

    fn nextIndentedFollowerToken(self: *const Parser, start_pos: usize) ?usize {
        if (!self.is_indented_syntax) return null;
        if (start_pos >= self.tokens.len) return null;

        const header_tok = self.tokens[start_pos];
        const header_line_start = self.lineStartAtByte(header_tok.span.start);
        const header_indent = self.lineIndentAtByte(header_tok.span.start);

        var p = start_pos;
        while (p < self.tokens.len) : (p += 1) {
            const t = self.tokens[p].tag;
            if (t == .newline) break;
            if (t == .semicolon or t == .rbrace or t == .eof) return null;
        }
        if (p >= self.tokens.len or self.tokens[p].tag != .newline) return null;

        var q = p + 1;
        while (q < self.tokens.len) : (q += 1) {
            const t = self.tokens[q].tag;
            if (t == .whitespace or t == .newline or t == .comment) continue;
            break;
        }
        if (q >= self.tokens.len) return null;

        const follower = self.tokens[q];
        if (self.lineStartAtByte(follower.span.start) <= header_line_start) return null;
        if (self.lineIndentAtByte(follower.span.start) <= header_indent) return null;
        return q;
    }

    fn shouldFallbackIndentedPropertyNamespaceOnHardDeclError(self: *const Parser, start_pos: usize) bool {
        if (!self.is_indented_syntax) return false;
        // CSS custom function bodies (`@function --x`) must preserve
        // declaration HardSyntaxError for nested `result:` lines.
        if (self.in_css_custom_function) return false;
        if (!self.lineContainsTopLevelColon(start_pos)) return false;
        const follower = self.nextIndentedFollowerToken(start_pos) orelse return false;
        if (!self.lineContainsTopLevelColon(follower)) return false;
        return true;
    }

    /// Walk tokens from the current position up to the opening `{` of
    /// a style rule, respecting paren / bracket / interpolation depth.
    /// Returns the raw byte span of the selector text (trailing
    /// trivia trimmed).  On successful return, `self.pos` points at
    /// the `{` token.
    fn collectSelectorSpan(self: *Parser) ParseError!Span {
        if (self.isAtEnd()) return error.SyntaxError;
        const start = self.current().span.start;
        // Track opening bracket kinds on a small stack so `)` only
        // closes `(` and `]` only closes `[` -- otherwise an unbalanced
        // `[a#{"..."}) {...}` would silently pop the outer `[` and treat
        // the following `{` as the style-rule body.
        var stack: [32]u8 = undefined;
        var depth: usize = 0;
        var interp_depth: u32 = 0;
        var last_significant_end: u32 = start;

        while (!self.isAtEnd()) {
            const tok = self.current();
            if (tok.tag == .hash_lbrace) {
                interp_depth += 1;
                last_significant_end = tok.span.end;
                self.advance();
                continue;
            }
            if (tok.tag == .rbrace and interp_depth > 0) {
                interp_depth -= 1;
                last_significant_end = tok.span.end;
                self.advance();
                continue;
            }
            if (interp_depth > 0) {
                last_significant_end = tok.span.end;
                self.advance();
                continue;
            }

            if (tok.tag == .lparen) {
                if (depth < stack.len) {
                    stack[depth] = '(';
                    depth += 1;
                }
                last_significant_end = tok.span.end;
                self.advance();
                continue;
            }
            if (tok.tag == .lbracket) {
                if (depth < stack.len) {
                    stack[depth] = '[';
                    depth += 1;
                }
                last_significant_end = tok.span.end;
                self.advance();
                continue;
            }
            if (tok.tag == .rparen) {
                if (depth > 0 and stack[depth - 1] == '(') {
                    depth -= 1;
                    last_significant_end = tok.span.end;
                    self.advance();
                    continue;
                }
                return error.SyntaxError;
            }
            if (tok.tag == .rbracket) {
                if (depth > 0 and stack[depth - 1] == '[') {
                    depth -= 1;
                    last_significant_end = tok.span.end;
                    self.advance();
                    continue;
                }
                return error.SyntaxError;
            }
            if (depth > 0) {
                last_significant_end = tok.span.end;
                self.advance();
                continue;
            }

            if (tok.tag == .lbrace) break;
            if (tok.tag == .eof) return error.SyntaxError;

            if (tok.tag != .whitespace and tok.tag != .newline and tok.tag != .comment) {
                last_significant_end = tok.span.end;
            }
            self.advance();
        }

        if (self.isAtEnd() or self.current().tag != .lbrace) {
            return error.SyntaxError;
        }
        return .{ .start = start, .end = last_significant_end };
    }

    /// Parse a style rule: `selector { body }`.  The selector text is
    /// captured as a raw source slice, interned, and emitted as an
    /// `expr_unquoted_ident` node (placeholder -- Phase S replaces it
    /// with a structured `sel_*` tree).
    ///
    /// stmt_style_rule extra: `[selector_node, body_extra]`.
    fn parseStyleRule(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const sel_span = try self.collectSelectorSpan();
        const sel_text = self.source[sel_span.start..sel_span.end];
        // Reject a bare `%` placeholder selector -- Sass requires an
        // identifier to follow (`%foo`, not `%`).  The trimmed span is
        // checked against the single-byte `%` and against forms like
        // `% ` where the `%` has no trailing ident at all.
        {
            const trimmed = std.mem.trim(u8, sel_text, " \t\n\r");
            if (trimmed.len == 1 and trimmed[0] == '%') return error.SyntaxError;
        }
        const sel_id = try self.intern_pool.intern(sel_text);

        const sel_node = try ast.addNode(.{
            .tag = .expr_unquoted_ident,
            .flags = 0,
            .payload = @intFromEnum(sel_id),
            .span_start = sel_span.start,
            .span_end = sel_span.end,
        });

        const body = try self.parseBlockBody(ast);

        const extra_off = try ast.appendExtraU32(sel_node.toU32());
        _ = try ast.appendExtraU32(body.extra);

        return try ast.addNode(.{
            .tag = .stmt_style_rule,
            .flags = 0,
            .payload = extra_off,
            .span_start = sel_span.start,
            .span_end = body.span_end,
        });
    }

    /// Parse an indented-syntax style rule (`selector` on one line, body on
    /// deeper-indented following lines).
    ///
    /// Selector collection mirrors `collectSelectorSpan`, but terminates at
    /// the first depth-zero newline instead of requiring `{`.
    fn normalizeIndentedSelectorText(self: *Parser, raw: []const u8) ParseError![]const u8 {
        if (std.mem.findAny(u8, raw, "\r\n") == null and std.mem.find(u8, raw, "\\:") == null) return raw;

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);

        var paren_depth: u32 = 0;
        var bracket_depth: u32 = 0;
        var interp_depth: u32 = 0;
        var in_string: u8 = 0;
        var i: usize = 0;
        var changed = false;

        while (i < raw.len) {
            const c = raw[i];

            if (in_string != 0) {
                try out.append(self.allocator, c);
                if (c == '\\' and i + 1 < raw.len) {
                    i += 1;
                    try out.append(self.allocator, raw[i]);
                } else if (c == in_string) {
                    in_string = 0;
                }
                i += 1;
                continue;
            }

            if (c == '\\' and i + 1 < raw.len and raw[i + 1] == ':') {
                const prev = if (out.items.len > 0) out.items[out.items.len - 1] else 0;
                const starts_pseudo = out.items.len == 0 or
                    prev == ' ' or prev == '\t' or prev == '\n' or prev == '\r' or
                    prev == ',' or prev == '>' or prev == '+' or prev == '~' or
                    prev == '(';
                if (starts_pseudo) {
                    try out.append(self.allocator, ':');
                    i += 2;
                    changed = true;
                    continue;
                }
            }

            if (c == '"' or c == '\'') {
                in_string = c;
                try out.append(self.allocator, c);
                i += 1;
                continue;
            }
            if (c == '#' and i + 1 < raw.len and raw[i + 1] == '{') {
                interp_depth += 1;
                try out.appendSlice(self.allocator, raw[i .. i + 2]);
                i += 2;
                continue;
            }
            if (interp_depth > 0) {
                try out.append(self.allocator, c);
                if (c == '{') interp_depth += 1;
                if (c == '}') interp_depth -= 1;
                i += 1;
                continue;
            }

            switch (c) {
                '(' => paren_depth += 1,
                '[' => bracket_depth += 1,
                ')' => {
                    if (paren_depth > 0) paren_depth -= 1;
                },
                ']' => {
                    if (bracket_depth > 0) bracket_depth -= 1;
                },
                '\r', '\n' => {
                    if (paren_depth > 0 or bracket_depth > 0) {
                        changed = true;
                        if (c == '\r' and i + 1 < raw.len and raw[i + 1] == '\n') i += 1;
                        i += 1;
                        while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t')) i += 1;
                        continue;
                    }
                },
                else => {},
            }

            try out.append(self.allocator, c);
            i += 1;
        }

        if (!changed) {
            out.deinit(self.allocator);
            return raw;
        }
        return try out.toOwnedSlice(self.allocator);
    }

    fn parseIndentedStyleRule(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        if (self.isAtEnd()) return error.SyntaxError;
        const start = self.current().span.start;
        var last_significant_end: u32 = start;
        var last_significant_tag: ?Token.Tag = null;

        var stack: [32]u8 = undefined;
        var depth: usize = 0;
        var interp_depth: u32 = 0;

        while (!self.isAtEnd()) {
            const tok = self.current();
            if (tok.tag == .hash_lbrace) {
                interp_depth += 1;
                last_significant_end = tok.span.end;
                last_significant_tag = tok.tag;
                self.advance();
                continue;
            }
            if (tok.tag == .rbrace and interp_depth > 0) {
                interp_depth -= 1;
                last_significant_end = tok.span.end;
                last_significant_tag = tok.tag;
                self.advance();
                continue;
            }
            if (interp_depth > 0) {
                last_significant_end = tok.span.end;
                last_significant_tag = tok.tag;
                self.advance();
                continue;
            }

            if (tok.tag == .lparen) {
                if (depth < stack.len) {
                    stack[depth] = '(';
                    depth += 1;
                }
                last_significant_end = tok.span.end;
                last_significant_tag = tok.tag;
                self.advance();
                continue;
            }
            if (tok.tag == .lbracket) {
                if (depth < stack.len) {
                    stack[depth] = '[';
                    depth += 1;
                }
                last_significant_end = tok.span.end;
                last_significant_tag = tok.tag;
                self.advance();
                continue;
            }
            if (tok.tag == .rparen) {
                if (depth > 0 and stack[depth - 1] == '(') {
                    depth -= 1;
                    last_significant_end = tok.span.end;
                    last_significant_tag = tok.tag;
                    self.advance();
                    continue;
                }
                return error.SyntaxError;
            }
            if (tok.tag == .rbracket) {
                if (depth > 0 and stack[depth - 1] == '[') {
                    depth -= 1;
                    last_significant_end = tok.span.end;
                    last_significant_tag = tok.tag;
                    self.advance();
                    continue;
                }
                return error.SyntaxError;
            }
            if (depth > 0) {
                last_significant_end = tok.span.end;
                last_significant_tag = tok.tag;
                self.advance();
                continue;
            }

            if (tok.tag == .newline) {
                // `.sass` multiline selectors continue across depth-0 newlines
                // only when the previous significant token is a comma.
                if (last_significant_tag != null and last_significant_tag.? == .comma) {
                    self.advance();
                    continue;
                }
                break;
            }
            if (tok.tag == .semicolon or tok.tag == .eof) break;
            if (tok.tag == .lbrace) return error.SyntaxError;

            if (tok.tag != .whitespace and tok.tag != .comment) {
                last_significant_end = tok.span.end;
                last_significant_tag = tok.tag;
            }
            self.advance();
        }

        if (last_significant_end <= start) return error.SyntaxError;

        const sel_text = self.source[start..last_significant_end];
        const normalized_sel_text = try self.normalizeIndentedSelectorText(sel_text);
        defer if (normalized_sel_text.ptr != sel_text.ptr) self.allocator.free(normalized_sel_text);

        const trimmed = std.mem.trim(u8, normalized_sel_text, " \t\n\r");
        if (trimmed.len == 0 or trimmed[0] == ',') return error.SyntaxError;
        if (trimmed.len == 1 and trimmed[0] == '%') return error.SyntaxError;

        const sel_id = try self.intern_pool.intern(normalized_sel_text);
        const sel_node = try ast.addNode(.{
            .tag = .expr_unquoted_ident,
            .flags = 0,
            .payload = @intFromEnum(sel_id),
            .span_start = start,
            .span_end = last_significant_end,
        });

        const body = try self.parseBlockBodyAnchored(ast, start);
        const extra_off = try ast.appendExtraU32(sel_node.toU32());
        _ = try ast.appendExtraU32(body.extra);

        return try ast.addNode(.{
            .tag = .stmt_style_rule,
            .flags = 0,
            .payload = extra_off,
            .span_start = start,
            .span_end = body.span_end,
        });
    }

    /// Parse a declaration: `property: value [!important] [;]`.
    ///
    /// The property name is captured as a raw source slice so that
    /// `#{...}` interpolation within property names round-trips via
    /// Phase S.  The value is a full Sass expression.  `--` prefixed
    /// properties set flags bit 0; a trailing `!important` sets bit 1.
    ///
    /// stmt_declaration extra: `[property_node, value_node]`.
    fn parseDeclaration(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        if (self.isAtEnd()) return error.SyntaxError;
        const start_tok = self.current();
        const prop_start = start_tok.span.start;

        // Walk until the property-separator colon, tracking `#{...}`
        // interpolation depth so a colon inside an interp does not
        // terminate the name.  Custom-property detection (`--` prefix) is
        // delayed until after the walk so interpolated names like
        // `--#{foo}` (which start with a `.minus` token, not `.ident`) are
        // still recognized -- the check is performed on the final property
        // slice, mirroring the legacy parser behaviour.
        var interp_depth: u32 = 0;
        var group_depth: u32 = 0;
        var last_significant_end: u32 = prop_start;
        // CSS hack allowance: a declaration may begin with a bare `:`
        // (e.g. `:x: y;` inside a plain CSS ruleset).  The legacy parser
        // consumed the leading colon as part of the property name so the
        // name becomes `:x`.  Mirror that behaviour: if the first token is
        // a colon, include it in the name span before the property-reader
        // loop would otherwise break at it.
        if (start_tok.tag == .colon) {
            last_significant_end = start_tok.span.end;
            self.advance();
        }
        while (!self.isAtEnd()) {
            const tok = self.current();
            if (tok.tag == .hash_lbrace) {
                interp_depth += 1;
                last_significant_end = tok.span.end;
                self.advance();
                continue;
            }
            if (tok.tag == .rbrace and interp_depth > 0) {
                interp_depth -= 1;
                last_significant_end = tok.span.end;
                self.advance();
                continue;
            }
            if (interp_depth > 0) {
                last_significant_end = tok.span.end;
                self.advance();
                continue;
            }
            if (tok.tag == .lparen or tok.tag == .lbracket) {
                group_depth += 1;
                last_significant_end = tok.span.end;
                self.advance();
                continue;
            }
            if ((tok.tag == .rparen or tok.tag == .rbracket) and group_depth > 0) {
                group_depth -= 1;
                last_significant_end = tok.span.end;
                self.advance();
                continue;
            }
            if (self.is_indented_syntax and group_depth == 0 and tok.tag == .newline) {
                return error.SyntaxError;
            }
            if (tok.tag == .colon) break;
            if (tok.tag == .semicolon or tok.tag == .rbrace or
                tok.tag == .lbrace or tok.tag == .eof)
            {
                return error.SyntaxError;
            }
            if (tok.tag != .whitespace and tok.tag != .newline) {
                if (tok.tag == .comment) {
                    // A block comment immediately adjacent to the property
                    // name stays part of the name span (`foo/*foo*/:`).
                    // When preceded by whitespace, it's separate trivia.
                    const text = tok.slice(self.source);
                    const is_block = text.len >= 2 and text[0] == '/' and text[1] == '*';
                    if (is_block and tok.span.start == last_significant_end) {
                        last_significant_end = tok.span.end;
                    }
                } else {
                    last_significant_end = tok.span.end;
                }
            }
            self.advance();
        }
        if (self.isAtEnd() or self.current().tag != .colon) return error.SyntaxError;
        const prop_end = last_significant_end;
        self.advance(); // skip :

        const prop_text = self.source[prop_start..prop_end];
        const is_custom = prop_text.len >= 2 and prop_text[0] == '-' and prop_text[1] == '-';
        // Custom properties capture raw text including leading whitespace
        // (the legacy evaluator preserves it).  Regular declarations trim
        // trivia before the value.
        if (!is_custom) self.skipWhitespaceAndComments();

        const prop_id = try self.intern_pool.intern(prop_text);
        const prop_node = try ast.addNode(.{
            .tag = .expr_unquoted_ident,
            .flags = 0,
            .payload = @intFromEnum(prop_id),
            .span_start = prop_start,
            .span_end = prop_end,
        });

        const value_node = if (is_custom)
            if (self.is_indented_syntax)
                try self.parseCustomPropertyValueRawAnchored(ast, prop_start)
            else
                try self.parseCustomPropertyValueRaw(ast)
        else if (self.is_indented_syntax)
            try self.parseDeclarationValueExprOrRawAnchored(ast, prop_start)
        else
            try self.parseDeclarationValueExprOrRaw(ast);

        // Optional `!important` suffix.
        var is_important = false;
        const value_line_start = if (self.is_indented_syntax)
            self.lineStartAtByte(ast.getNode(value_node).span_end)
        else
            0;
        if (self.is_indented_syntax)
            self.skipInlineWhitespaceAndComments()
        else
            self.skipWhitespaceAndComments();
        if (!self.isAtEnd() and self.current().tag == .plus) {
            const saved = self.pos;
            self.advance();
            if (self.is_indented_syntax)
                self.skipInlineWhitespaceAndComments()
            else
                self.skipWhitespaceAndComments();
            if (!self.isAtEnd() and self.current().tag == .bang) {
                self.advance();
                self.skipWhitespaceAndComments();
                if (!self.isAtEnd() and self.current().tag == .ident and
                    std.ascii.eqlIgnoreCase(self.current().slice(self.source), "important"))
                {
                    is_important = true;
                    self.advance();
                } else {
                    self.pos = saved;
                }
            } else {
                self.pos = saved;
            }
        }
        if (!self.isAtEnd() and self.current().tag == .bang) {
            if (self.is_indented_syntax and
                self.lineStartAtByte(self.current().span.start) != value_line_start)
            {
                return error.SyntaxError;
            }
            const saved = self.pos;
            self.advance();
            self.skipWhitespaceAndComments();
            if (!self.isAtEnd() and self.current().tag == .ident and
                std.ascii.eqlIgnoreCase(self.current().slice(self.source), "important"))
            {
                is_important = true;
                self.advance();
            } else {
                self.pos = saved;
            }
        }

        var end_pos: u32 = ast.getNode(value_node).span_end;
        self.skipWhitespaceAndComments();
        if (!self.isAtEnd() and self.current().tag == .semicolon) {
            const semi_tok = self.current();
            end_pos = semi_tok.span.end;
            self.advance();
            if (self.is_indented_syntax) {
                const semi_line_start = self.lineStartAtByte(semi_tok.span.start);
                while (self.pos < self.tokens.len) {
                    const tok = self.tokens[self.pos];
                    if (tok.tag == .newline or tok.tag == .eof or tok.tag == .rbrace) break;
                    if (self.lineStartAtByte(tok.span.start) != semi_line_start) break;

                    const t = tok.tag;
                    if (t == .whitespace or t == .comment) {
                        // `.sass`: inline comments after a declaration
                        // semicolon are swallowed (`a\n  b: c; /* d */`).
                        self.pos += 1;
                        continue;
                    }
                    return error.SyntaxError;
                }
            }
        }
        if (self.is_indented_syntax) {
            while (self.pos < self.tokens.len) {
                const tok = self.tokens[self.pos];
                if (tok.tag == .whitespace or tok.tag == .comment) {
                    self.pos += 1;
                    continue;
                }
                if (tok.tag == .newline or tok.tag == .eof or tok.tag == .rbrace) break;
                if (self.lineStartAtByte(tok.span.start) == value_line_start) return error.SyntaxError;
                break;
            }
        }

        const extra_off = try ast.appendExtraU32(prop_node.toU32());
        _ = try ast.appendExtraU32(value_node.toU32());

        var flags: u8 = 0;
        if (is_custom) flags |= 0b0000_0001;
        if (is_important) flags |= 0b0000_0010;

        return try ast.addNode(.{
            .tag = .stmt_declaration,
            .flags = flags,
            .payload = extra_off,
            .span_start = prop_start,
            .span_end = end_pos,
        });
    }

    /// Parse a declaration value.  Tries the Sass expression parser first;
    /// on failure (or when the parser stops before a valid declaration
    /// terminator), rewinds and materializes the byte slice as an unquoted
    /// text-template expr (`expr_text_template`).
    /// This preserves CSS-native constructs such as `if(cond: val)`,
    /// `var(--x, fallback)`, or `progid:DXImageTransform.Microsoft...`
    /// without collapsing them into an identifier placeholder.
    fn parseDeclarationValueExprOrRaw(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        if (self.isAtEnd()) return error.UnexpectedEof;
        const saved_pos = self.pos;
        const value_start_byte: u32 = self.current().span.start;

        // CSS unicode-range literals (`U+XXXX`, `U+XX??`, `U+XXXX-YYYY`) must
        // stay as raw declaration text so downstream validation/normalization can
        // distinguish valid ranges from syntax errors (e.g. too many digits).
        if (self.declarationValueStartsWithUnicodeRangeLiteral(value_start_byte)) {
            return self.parseDeclarationValueRaw(ast, value_start_byte);
        }
        if (self.declarationValueStartsWithVendorProgidCall(value_start_byte)) {
            return self.parseDeclarationValueRaw(ast, value_start_byte);
        }

        const prev_decl_ctx = self.in_declaration_value_context;
        self.in_declaration_value_context = true;
        defer self.in_declaration_value_context = prev_decl_ctx;
        const prev_incomplete_binary = self.saw_incomplete_binary_rhs;
        self.saw_incomplete_binary_rhs = false;
        defer self.saw_incomplete_binary_rhs = prev_incomplete_binary;

        const parse_result = self.parseExpression(ast);
        if (parse_result) |node| {
            // parseExpression may stop before end-of-value when it hits a
            // token the grammar does not understand (e.g. `:` separating
            // clauses of CSS `if(cond: val)`).  Peek past trivia and verify
            // the next token is a valid declaration terminator; otherwise
            // rewind and fall back to raw capture.
            const save_pos = self.pos;
            self.skipWhitespaceAndComments();
            var ok = false;
            if (self.isAtEnd()) {
                ok = true;
            } else {
                const t = self.current().tag;
                if (t == .semicolon or t == .rbrace or t == .eof) {
                    ok = true;
                } else if (t == .bang) {
                    // `!important` is a valid trailing flag when it
                    // ends the declaration (`!important;`, `!important}`).
                    // It is also valid mid-value (`foo !important bar`)
                    // -- but in that case parseSpaceListOrSingle should
                    // have consumed it as part of the value.  If we hit
                    // a bang here, treat it as a flag only when the
                    // chain reaches a terminator.
                    ok = bangFollowedByTerminator(self);
                }
            }
            if (ok) {
                self.pos = save_pos;
                return node;
            }
            self.pos = saved_pos;
        } else |err| switch (err) {
            error.SyntaxError => {
                if (self.saw_incomplete_binary_rhs) {
                    error_format.setContextMessage("Expected expression.");
                    return err;
                }
                self.pos = saved_pos;
            },
            // HardSyntaxError must propagate -- these are constructs
            // (e.g. `ns.member`, `$.foo`, `ns.$_priv`) where official Sass CLI
            // rejects rather than treating as raw CSS.
            error.HardSyntaxError => return error.SyntaxError,
            else => return err,
        }

        self.pos = saved_pos;
        const raw_end = try self.consumeDeclarationValueRawEnd(value_start_byte);
        const raw_text = self.source[value_start_byte..raw_end];
        const allow_invalid_tokens = rawDeclarationValueAllowsInvalidTokens(raw_text);
        var scan_idx = saved_pos;
        while (scan_idx < self.tokens.len) : (scan_idx += 1) {
            const tok = self.tokens[scan_idx];
            if (tok.span.start >= raw_end) break;
            if (tok.tag == .invalid and !self.in_css_custom_function and !allow_invalid_tokens) return error.SyntaxError;
        }
        if (rawDeclarationValueHasMalformedSassArglist(raw_text)) return error.SyntaxError;
        if (rawDeclarationValueHasFatalCalcSyntax(raw_text)) return error.SyntaxError;

        return try self.emitUnquotedTextExprFromSlice(
            ast,
            raw_text,
            value_start_byte,
            value_start_byte,
            raw_end,
        );
    }

    fn declarationValueStartsWithUnicodeRangeLiteral(self: *const Parser, value_start_byte: u32) bool {
        const start: usize = @intCast(value_start_byte);
        if (start + 2 >= self.source.len) return false;
        const head = self.source[start];
        if (head != 'U' and head != 'u') return false;
        if (self.source[start + 1] != '+') return false;
        const after_plus = self.source[start + 2];
        return (after_plus >= '0' and after_plus <= '9') or
            (after_plus >= 'a' and after_plus <= 'f') or
            (after_plus >= 'A' and after_plus <= 'F') or
            after_plus == '?';
    }

    fn declarationValueStartsWithVendorProgidCall(self: *const Parser, value_start_byte: u32) bool {
        var start: usize = @intCast(value_start_byte);
        while (start < self.source.len and (self.source[start] == ' ' or self.source[start] == '\t')) : (start += 1) {}
        const rest = self.source[start..];
        if (std.ascii.startsWithIgnoreCase(rest, "progid:")) return !declarationValuePrefixContainsLineComment(rest);
        if (rest.len == 0 or rest[0] != '-') return false;
        const colon = std.mem.findScalar(u8, rest, ':') orelse return false;
        const prefix = rest[0..colon];
        return prefix.len >= 6 and std.ascii.eqlIgnoreCase(prefix[prefix.len - 6 ..], "progid") and
            !declarationValuePrefixContainsLineComment(rest);
    }

    fn declarationValuePrefixContainsLineComment(text: []const u8) bool {
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == ';' or text[i] == '}') return false;
            if (text[i] == '/' and i + 1 < text.len and text[i + 1] == '/') return true;
        }
        return false;
    }

    /// Indented-syntax declaration values must stop at the first depth-zero
    /// newline whose next significant token is at the same or shallower
    /// indentation than the declaration header line.
    ///
    /// Reuses the same limiter as `@return` / `@debug` value parsing.
    fn parseDeclarationValueExprOrRawAnchored(
        self: *Parser,
        ast: *Ast,
        header_start: u32,
    ) ParseError!NodeIndex {
        return self.parseDeclarationValueExprOrRawAnchoredWithOptions(ast, header_start, false);
    }

    fn parseDeclarationValueExprOrRawAnchoredAllowIndentedFirstLine(
        self: *Parser,
        ast: *Ast,
        header_start: u32,
    ) ParseError!NodeIndex {
        return self.parseDeclarationValueExprOrRawAnchoredWithOptions(ast, header_start, true);
    }

    fn parseDeclarationValueExprOrRawAnchoredWithOptions(
        self: *Parser,
        ast: *Ast,
        header_start: u32,
        allow_indented_first_line: bool,
    ) ParseError!NodeIndex {
        if (!self.is_indented_syntax) return self.parseDeclarationValueExprOrRaw(ast);

        const value_start_pos = self.pos;
        const header_indent = self.lineIndentAtByte(header_start);
        const header_line_start = self.lineStartAtByte(header_start);
        if (value_start_pos < self.tokens.len) {
            const first_tok = self.tokens[value_start_pos];
            if (first_tok.tag != .eof) {
                const first_line_start = self.lineStartAtByte(first_tok.span.start);
                if (!allow_indented_first_line and
                    first_line_start > header_line_start and
                    self.lineIndentAtByte(first_tok.span.start) > header_indent)
                {
                    return error.HardSyntaxError;
                }
            }
        }
        const limit = self.findDeclarationValueLimit(value_start_pos, header_indent, header_line_start);
        if (limit <= value_start_pos) return self.parseDeclarationValueExprOrRaw(ast);

        var sub = self.createSubParser(self.tokens[value_start_pos..limit]);
        defer sub.deinit();

        const node = try sub.parseDeclarationValueExprOrRaw(ast);
        self.pos = value_start_pos + sub.pos;
        var next_pos = self.pos;
        while (next_pos < self.tokens.len) : (next_pos += 1) {
            const t = self.tokens[next_pos].tag;
            if (t == .whitespace or t == .newline or t == .comment) continue;
            break;
        }
        if (next_pos < self.tokens.len) {
            const next_tok = self.tokens[next_pos];
            if (self.lineStartAtByte(next_tok.span.start) > header_line_start and
                self.lineIndentAtByte(next_tok.span.start) > header_indent)
            {
                return error.HardSyntaxError;
            }
        }
        return node;
    }

    fn parseCustomPropertyValueRawAnchored(
        self: *Parser,
        ast: *Ast,
        header_start: u32,
    ) ParseError!NodeIndex {
        if (!self.is_indented_syntax) return self.parseCustomPropertyValueRaw(ast);
        if (self.isAtEnd()) return error.UnexpectedEof;

        const value_start_pos = self.pos;
        const header_indent = self.lineIndentAtByte(header_start);
        const header_line_start = self.lineStartAtByte(header_start);
        if (value_start_pos < self.tokens.len) {
            const first_tok = self.tokens[value_start_pos];
            if (first_tok.tag != .eof) {
                const first_line_start = self.lineStartAtByte(first_tok.span.start);
                if (first_line_start > header_line_start and
                    self.lineIndentAtByte(first_tok.span.start) > header_indent)
                {
                    return error.HardSyntaxError;
                }
            }
        }
        const limit = self.findCustomPropertyValueLimit(value_start_pos, header_indent, header_line_start);
        if (limit <= value_start_pos) return self.parseCustomPropertyValueRaw(ast);

        var trimmed_limit = limit;
        var saw_terminating_newline = false;
        while (trimmed_limit > value_start_pos) {
            const prev = self.tokens[trimmed_limit - 1].tag;
            if (prev == .whitespace or prev == .comment) {
                trimmed_limit -= 1;
                continue;
            }
            if (prev == .newline) {
                saw_terminating_newline = true;
                trimmed_limit -= 1;
            }
            break;
        }
        const sub_limit = if (saw_terminating_newline) trimmed_limit else limit;
        if (sub_limit <= value_start_pos) return self.parseCustomPropertyValueRaw(ast);

        var sub = self.createSubParser(self.tokens[value_start_pos..sub_limit]);
        defer sub.deinit();

        const node = try sub.parseCustomPropertyValueRaw(ast);
        self.pos = value_start_pos + sub.pos;
        var next_pos = self.pos;
        while (next_pos < self.tokens.len) : (next_pos += 1) {
            const t = self.tokens[next_pos].tag;
            if (t == .whitespace or t == .newline or t == .comment or t == .eof) continue;
            break;
        }
        if (next_pos < self.tokens.len) {
            const next_tok = self.tokens[next_pos];
            if (self.lineStartAtByte(next_tok.span.start) > header_line_start and
                self.lineIndentAtByte(next_tok.span.start) > header_indent)
            {
                if (self.customPropertyValueHasOpenGrouping(value_start_pos, next_pos)) {
                    self.pos = value_start_pos;
                    return self.parseCustomPropertyValueRaw(ast);
                }
                return error.HardSyntaxError;
            }
        }
        return node;
    }

    fn customPropertyValueHasOpenGrouping(
        self: *const Parser,
        start_pos: usize,
        end_pos: usize,
    ) bool {
        var stack: [64]u8 = undefined;
        var depth: usize = 0;
        var p = start_pos;
        while (p < end_pos and p < self.tokens.len) : (p += 1) {
            const t = self.tokens[p].tag;
            switch (t) {
                .lparen => {
                    if (depth < stack.len) {
                        stack[depth] = '(';
                        depth += 1;
                    }
                },
                .lbracket => {
                    if (depth < stack.len) {
                        stack[depth] = '[';
                        depth += 1;
                    }
                },
                .lbrace, .hash_lbrace => {
                    if (depth < stack.len) {
                        stack[depth] = '{';
                        depth += 1;
                    }
                },
                .rparen => {
                    if (depth > 0 and stack[depth - 1] == '(') depth -= 1;
                },
                .rbracket => {
                    if (depth > 0 and stack[depth - 1] == '[') depth -= 1;
                },
                .rbrace => {
                    if (depth > 0 and stack[depth - 1] == '{') depth -= 1;
                },
                else => {},
            }
        }
        return depth != 0;
    }

    /// Indented-syntax variable declarations that already started their value on
    /// the declaration line must not swallow deeper-indented following lines as
    /// value continuation.
    fn parseDeclarationValueExprOrRawSingleLine(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        if (!self.is_indented_syntax) return self.parseDeclarationValueExprOrRaw(ast);
        if (self.isAtEnd()) return error.UnexpectedEof;

        const value_start_pos = self.pos;
        const value_line_start = self.lineStartAtByte(self.tokens[value_start_pos].span.start);
        const limit = self.findDeclarationValueLimit(
            value_start_pos,
            std.math.maxInt(u32),
            value_line_start,
        );
        if (limit <= value_start_pos) return self.parseDeclarationValueExprOrRaw(ast);

        var sub = self.createSubParser(self.tokens[value_start_pos..limit]);
        defer sub.deinit();

        const node = try sub.parseDeclarationValueExprOrRaw(ast);
        self.pos = value_start_pos + sub.pos;
        return node;
    }

    /// Peek past a `.bang` token and the following flag ident (`important`
    /// / `default` / `global`) to decide whether the `!` begins a valid
    /// suffix clause. Accepts chains like `!default !global` -- the whole
    /// chain must end at a declaration terminator (`;` / `}` / EOF) with
    /// only trivia between flags.  Returns false when any follow-up token
    /// breaks the pattern, so `foo !important hux` stays a raw value.
    fn bangFollowedByTerminator(self: *const Parser) bool {
        var p = self.pos;
        while (true) {
            if (p >= self.tokens.len or self.tokens[p].tag != .bang) return false;
            p += 1;
            while (p < self.tokens.len) {
                const t = self.tokens[p].tag;
                if (t == .whitespace or t == .newline or t == .comment) {
                    p += 1;
                    continue;
                }
                break;
            }
            if (p >= self.tokens.len or self.tokens[p].tag != .ident) return false;
            const text = self.tokens[p].slice(self.source);
            if (!(std.ascii.eqlIgnoreCase(text, "important") or
                std.ascii.eqlIgnoreCase(text, "default") or
                std.ascii.eqlIgnoreCase(text, "global"))) return false;
            p += 1;
            while (p < self.tokens.len) {
                const t = self.tokens[p].tag;
                if (t == .whitespace or t == .newline or t == .comment) {
                    p += 1;
                    continue;
                }
                break;
            }
            if (p >= self.tokens.len) return true;
            const t = self.tokens[p].tag;
            if (t == .semicolon or t == .rbrace or t == .eof) return true;
            if (t == .bang) continue; // chain another flag
            return false;
        }
    }

    /// Raw capture for CSS custom property values (`--name: <value>`).
    ///
    /// Mirrors the permissive grammar of legacy `parseCustomPropertyValue`:
    /// whitespace and newlines are preserved; `{`, `(`, `[` (and `#{`) open
    /// matched brackets that allow `;` / `}` inside the value; a top-level
    /// `;` terminates (consumed) and a top-level `}` terminates without
    /// being consumed.  An empty value (e.g. `--empty: ;`) is allowed.
    fn parseCustomPropertyValueRaw(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const val_start: u32 = if (self.isAtEnd())
            @intCast(self.source.len)
        else
            self.current().span.start;
        var val_end: u32 = val_start;

        var bracket_stack: [64]u8 = undefined;
        var bracket_depth: usize = 0;

        outer: while (!self.isAtEnd()) {
            const tok = self.current();
            switch (tok.tag) {
                .semicolon => {
                    if (bracket_depth == 0) break :outer;
                    val_end = tok.span.end;
                    self.advance();
                },
                .rbrace => {
                    if (bracket_depth == 0) break :outer;
                    if (bracket_stack[bracket_depth - 1] == '{') {
                        bracket_depth -= 1;
                        val_end = tok.span.end;
                        self.advance();
                    } else return error.SyntaxError;
                },
                .rparen => {
                    if (bracket_depth == 0) return error.SyntaxError;
                    if (bracket_stack[bracket_depth - 1] == '(') {
                        bracket_depth -= 1;
                        val_end = tok.span.end;
                        self.advance();
                    } else return error.SyntaxError;
                },
                .rbracket => {
                    if (bracket_depth == 0) return error.SyntaxError;
                    if (bracket_stack[bracket_depth - 1] == '[') {
                        bracket_depth -= 1;
                        val_end = tok.span.end;
                        self.advance();
                    } else return error.SyntaxError;
                },
                .lbrace, .hash_lbrace => {
                    if (bracket_depth < bracket_stack.len) {
                        bracket_stack[bracket_depth] = '{';
                        bracket_depth += 1;
                    }
                    val_end = tok.span.end;
                    self.advance();
                },
                .lparen => {
                    if (bracket_depth < bracket_stack.len) {
                        bracket_stack[bracket_depth] = '(';
                        bracket_depth += 1;
                    }
                    val_end = tok.span.end;
                    self.advance();
                },
                .lbracket => {
                    if (bracket_depth < bracket_stack.len) {
                        bracket_stack[bracket_depth] = '[';
                        bracket_depth += 1;
                    }
                    val_end = tok.span.end;
                    self.advance();
                },
                .comment => {
                    // A line comment's text can include raw `(` / `[` /
                    // `{` characters that contribute to the bracket
                    // balance of the enclosing custom property value --
                    // Sass treats `// (` as a real open paren at the
                    // block level (matches legacy parser.zig).  Walk the
                    // comment body and adjust bracket_depth accordingly.
                    const text = tok.slice(self.source);
                    if (text.len >= 2 and text[0] == '/' and text[1] == '/') {
                        for (text[2..]) |ch| {
                            switch (ch) {
                                '(' => if (bracket_depth < bracket_stack.len) {
                                    bracket_stack[bracket_depth] = '(';
                                    bracket_depth += 1;
                                },
                                '[' => if (bracket_depth < bracket_stack.len) {
                                    bracket_stack[bracket_depth] = '[';
                                    bracket_depth += 1;
                                },
                                '{' => if (bracket_depth < bracket_stack.len) {
                                    bracket_stack[bracket_depth] = '{';
                                    bracket_depth += 1;
                                },
                                ')' => if (bracket_depth > 0 and
                                    bracket_stack[bracket_depth - 1] == '(')
                                {
                                    bracket_depth -= 1;
                                },
                                ']' => if (bracket_depth > 0 and
                                    bracket_stack[bracket_depth - 1] == '[')
                                {
                                    bracket_depth -= 1;
                                },
                                '}' => if (bracket_depth > 0 and
                                    bracket_stack[bracket_depth - 1] == '{')
                                {
                                    bracket_depth -= 1;
                                },
                                else => {},
                            }
                        }
                        // A trailing `;` inside a `// ...` comment acts as
                        // the value terminator -- the Sass evaluator would
                        // otherwise emit the comment and then append its
                        // own `;` yielding `value; ;`.  Include the comment
                        // up to (but not including) that `;`.
                        if (bracket_depth == 0) {
                            const trimmed = std.mem.trimEnd(u8, text, " \t\r");
                            if (trimmed.len > 0 and trimmed[trimmed.len - 1] == ';') {
                                val_end = tok.span.start + @as(u32, @intCast(trimmed.len - 1));
                                self.advance();
                                break :outer;
                            }
                        }
                    }
                    val_end = tok.span.end;
                    self.advance();
                },
                else => {
                    val_end = tok.span.end;
                    self.advance();
                },
            }
        }

        // Custom properties may be empty -- emit an empty unquoted text node.
        const raw_text = self.source[val_start..val_end];
        return try self.emitUnquotedTextExprFromSlice(ast, raw_text, val_start, val_start, val_end);
    }

    /// Capture a declaration value as an unquoted text-template expr.
    /// Consumes tokens up to the first top-level `;` / `}` / `!` / EOF
    /// (tracking paren / bracket / brace / interpolation depth).
    /// `{` inside the value is treated as a matched brace (closed by `}`),
    /// so constructs like `result: {}#&%^*;` inside a CSS Custom Function
    /// body are preserved verbatim instead of prematurely terminating on
    /// the inner `}`.
    fn parseDeclarationValueRaw(
        self: *Parser,
        ast: *Ast,
        value_start_byte: u32,
    ) ParseError!NodeIndex {
        const raw_end = try self.consumeDeclarationValueRawEnd(value_start_byte);
        const raw_text = self.source[value_start_byte..raw_end];
        return try self.emitUnquotedTextExprFromSlice(
            ast,
            raw_text,
            value_start_byte,
            value_start_byte,
            raw_end,
        );
    }

    fn consumeDeclarationValueRawEnd(
        self: *Parser,
        value_start_byte: u32,
    ) ParseError!u32 {
        var depth: u32 = 0;
        var interp_depth: u32 = 0;
        var last_sig: u32 = value_start_byte;
        while (!self.isAtEnd()) {
            const tok = self.current();
            const t = tok.tag;
            if (t == .hash_lbrace) {
                interp_depth += 1;
                last_sig = tok.span.end;
                self.advance();
                continue;
            }
            if (t == .rbrace and interp_depth > 0) {
                interp_depth -= 1;
                last_sig = tok.span.end;
                self.advance();
                continue;
            }
            if (interp_depth > 0) {
                // A `;` inside `#{...}` is invalid -- the interp body must
                // be a single expression (libsass-closed-issues/issue_2081).
                if (t == .semicolon) return error.SyntaxError;
                last_sig = tok.span.end;
                self.advance();
                continue;
            }
            if (t == .lparen or t == .lbracket or t == .lbrace) {
                depth += 1;
                last_sig = tok.span.end;
                self.advance();
                continue;
            }
            if ((t == .rparen or t == .rbracket or t == .rbrace) and depth > 0) {
                depth -= 1;
                last_sig = tok.span.end;
                self.advance();
                continue;
            }
            if (t == .rparen or t == .rbracket) {
                // Raw fallback must not swallow unmatched closing delimiters.
                return error.SyntaxError;
            }
            if (depth == 0) {
                if (t == .semicolon or t == .rbrace or t == .eof) break;
                if (t == .bang and bangFollowedByTerminator(self)) break;
            }
            if (t != .whitespace and t != .newline and t != .comment) {
                last_sig = tok.span.end;
            }
            self.advance();
        }
        const raw_end = last_sig;
        if (raw_end <= value_start_byte) return error.SyntaxError;
        return raw_end;
    }

    fn rawDeclarationValueAllowsInvalidTokens(text: []const u8) bool {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len < 4) return false;
        if (rawValueLooksLikeCssIfCall(trimmed)) return true;
        return rawValueLooksLikeVendorProgidCall(trimmed);
    }

    fn rawValueLooksLikeCssIfCall(text: []const u8) bool {
        if (!std.mem.startsWith(u8, text, "if(")) return false;
        if (text[text.len - 1] != ')') return false;
        return std.mem.findScalar(u8, text, ':') != null;
    }

    fn rawValueLooksLikeVendorProgidCall(text: []const u8) bool {
        if (text[text.len - 1] != ')') return false;
        const open = std.mem.findScalar(u8, text, '(') orelse return false;
        const head = std.mem.trim(u8, text[0..open], " \t\r\n");
        const colon = std.mem.lastIndexOfScalar(u8, head, ':') orelse return false;
        const fn_head = std.mem.trim(u8, head[0..colon], " \t\r\n");
        const method = std.mem.trim(u8, head[colon + 1 ..], " \t\r\n");
        if (method.len == 0) return false;
        return std.ascii.eqlIgnoreCase(cssFunctionBaseName(fn_head), "progid");
    }

    fn rawDeclarationValueHasMalformedSassArglist(text: []const u8) bool {
        const ArgContext = struct {
            expect_value: bool = true,
            saw_sass_syntax: bool = false,
            saw_single_equals: bool = false,
        };

        var ctx_stack: [64]ArgContext = undefined;
        var ctx_len: usize = 0;
        var in_string: u8 = 0;
        var in_block_comment = false;
        var i: usize = 0;

        while (i < text.len) : (i += 1) {
            const c = text[i];

            if (in_block_comment) {
                if (c == '*' and i + 1 < text.len and text[i + 1] == '/') {
                    in_block_comment = false;
                    i += 1;
                }
                continue;
            }

            if (in_string != 0) {
                if (c == '\\' and i + 1 < text.len) {
                    i += 1;
                    continue;
                }
                if (c == in_string) in_string = 0;
                continue;
            }

            if (c == '/' and i + 1 < text.len and text[i + 1] == '*') {
                in_block_comment = true;
                i += 1;
                continue;
            }

            if (c == '"' or c == '\'') {
                in_string = c;
                if (ctx_len > 0) ctx_stack[ctx_len - 1].expect_value = false;
                continue;
            }

            switch (c) {
                '$' => {
                    if (ctx_len > 0) {
                        ctx_stack[ctx_len - 1].saw_sass_syntax = true;
                        ctx_stack[ctx_len - 1].expect_value = false;
                    }
                },
                '#' => {
                    if (ctx_len > 0 and i + 1 < text.len and text[i + 1] == '{') {
                        ctx_stack[ctx_len - 1].saw_sass_syntax = true;
                        ctx_stack[ctx_len - 1].expect_value = false;
                    } else if (ctx_len > 0) {
                        ctx_stack[ctx_len - 1].expect_value = false;
                    }
                },
                '(' => {
                    if (ctx_len > 0) ctx_stack[ctx_len - 1].expect_value = false;
                    if (ctx_len == ctx_stack.len) return false;
                    ctx_stack[ctx_len] = .{};
                    ctx_len += 1;
                },
                ')' => {
                    if (ctx_len > 0) {
                        if (ctx_stack[ctx_len - 1].saw_single_equals and ctx_stack[ctx_len - 1].expect_value) {
                            return true;
                        }
                        ctx_len -= 1;
                    }
                },
                ',' => {
                    if (ctx_len > 0) {
                        const ctx = &ctx_stack[ctx_len - 1];
                        if (ctx.saw_sass_syntax and ctx.expect_value) return true;
                        ctx.expect_value = true;
                    }
                },
                '=' => {
                    if (ctx_len > 0) {
                        const ctx = &ctx_stack[ctx_len - 1];
                        // `foo(=bar)` / `foo(=)` => missing lhs.
                        if (ctx.expect_value) return true;
                        ctx.saw_sass_syntax = true;
                        ctx.saw_single_equals = true;
                        // Require a rhs before `,` or `)`.
                        ctx.expect_value = true;
                    }
                },
                ' ', '\t', '\n', '\r' => {},
                else => {
                    if (ctx_len > 0) ctx_stack[ctx_len - 1].expect_value = false;
                },
            }
        }

        return false;
    }

    fn findMatchingParenInRaw(text: []const u8, open_idx: usize) ?usize {
        if (open_idx >= text.len or text[open_idx] != '(') return null;
        var depth: i32 = 0;
        var in_string: u8 = 0;
        var i: usize = open_idx;
        while (i < text.len) : (i += 1) {
            const c = text[i];
            if (in_string != 0) {
                if (c == '\\' and i + 1 < text.len) {
                    i += 1;
                    continue;
                }
                if (c == in_string) in_string = 0;
                continue;
            }
            if (c == '"' or c == '\'') {
                in_string = c;
                continue;
            }
            if (c == '(') depth += 1;
            if (c == ')') {
                depth -= 1;
                if (depth == 0) return i;
            }
        }
        return null;
    }

    fn calcContainsPatternOutsideSkips(text: []const u8, pattern: []const u8) bool {
        if (pattern.len == 0 or text.len < pattern.len) return false;
        var in_string: u8 = 0;
        var in_block_comment = false;
        var interp_depth: i32 = 0;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            const c = text[i];

            if (in_block_comment) {
                if (c == '*' and i + 1 < text.len and text[i + 1] == '/') {
                    in_block_comment = false;
                    i += 1;
                }
                continue;
            }
            if (in_string != 0) {
                if (c == '\\' and i + 1 < text.len) {
                    i += 1;
                    continue;
                }
                if (c == in_string) in_string = 0;
                continue;
            }
            if (interp_depth > 0) {
                if (c == '#') {
                    if (i + 1 < text.len and text[i + 1] == '{') {
                        interp_depth += 1;
                        i += 1;
                    }
                    continue;
                }
                if (c == '}') {
                    interp_depth -= 1;
                }
                continue;
            }

            if (c == '"' or c == '\'') {
                in_string = c;
                continue;
            }
            if (c == '/' and i + 1 < text.len and text[i + 1] == '*') {
                in_block_comment = true;
                i += 1;
                continue;
            }
            if (c == '#' and i + 1 < text.len and text[i + 1] == '{') {
                interp_depth = 1;
                i += 1;
                continue;
            }
            if (i + pattern.len <= text.len and std.mem.eql(u8, text[i .. i + pattern.len], pattern)) return true;
        }
        return false;
    }

    fn rawDeclarationValueHasFatalCalcSyntax(text: []const u8) bool {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len < 6) return false;
        if (!std.ascii.startsWithIgnoreCase(trimmed, "calc(")) return false;
        const close_idx = findMatchingParenInRaw(trimmed, 4) orelse return false;
        if (close_idx != trimmed.len - 1) return false;

        const inner = std.mem.trim(u8, trimmed[5..close_idx], " \t\r\n");
        if (inner.len == 0) return false;
        const last = inner[inner.len - 1];
        if (last == '+' or last == '-' or last == '*' or last == '/') return true;
        if (calcContainsPatternOutsideSkips(inner, "**")) return true;
        if (calcContainsPatternOutsideSkips(inner, "~#{")) return true;
        return false;
    }

    // -- @extend / @at-root (R.2c.6b) ----------------------------------------

    /// Parse `@extend <selector> [!optional] [;]`.
    ///
    /// The selector is captured as a raw source slice (terminated by
    /// `;`, `}`, `!optional`, or EOF) and emitted as an
    /// `expr_unquoted_ident` placeholder -- Phase S will re-parse it.
    ///
    /// stmt_extend extra: `[selector_node]`.
    /// flags bit 0: optional.
    fn parseExtendRule(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const at_tok = self.current();
        std.debug.assert(at_tok.tag == .at_extend);
        self.advance();
        self.skipWhitespaceAndComments();

        if (self.isAtEnd()) return error.SyntaxError;
        const start = self.current().span.start;
        var last_significant_end: u32 = start;
        var last_significant_tag: ?Token.Tag = null;
        var depth: u32 = 0;
        var interp_depth: u32 = 0;
        var is_optional = false;
        const header_indent = if (self.is_indented_syntax) self.lineIndentAtByte(at_tok.span.start) else 0;
        const header_line_start = if (self.is_indented_syntax) self.lineStartAtByte(at_tok.span.start) else 0;

        while (!self.isAtEnd()) {
            const tok = self.current();
            if (tok.tag == .hash_lbrace) {
                interp_depth += 1;
                last_significant_end = tok.span.end;
                last_significant_tag = tok.tag;
                self.advance();
                continue;
            }
            if (tok.tag == .rbrace and interp_depth > 0) {
                interp_depth -= 1;
                last_significant_end = tok.span.end;
                last_significant_tag = tok.tag;
                self.advance();
                continue;
            }
            if (interp_depth > 0) {
                last_significant_end = tok.span.end;
                if (tok.tag != .whitespace and tok.tag != .newline and tok.tag != .comment) {
                    last_significant_tag = tok.tag;
                }
                self.advance();
                continue;
            }
            if (tok.tag == .lparen or tok.tag == .lbracket) {
                depth += 1;
                last_significant_end = tok.span.end;
                last_significant_tag = tok.tag;
                self.advance();
                continue;
            }
            if ((tok.tag == .rparen or tok.tag == .rbracket) and depth > 0) {
                depth -= 1;
                last_significant_end = tok.span.end;
                last_significant_tag = tok.tag;
                self.advance();
                continue;
            }
            if (depth > 0) {
                last_significant_end = tok.span.end;
                if (tok.tag != .whitespace and tok.tag != .newline and tok.tag != .comment) {
                    last_significant_tag = tok.tag;
                }
                self.advance();
                continue;
            }

            if (self.is_indented_syntax and tok.tag == .newline) {
                // `.sass` allows:
                //   @extend
                //     a
                // but once the selector body started, a following indented
                // line must not be absorbed into this @extend statement.
                if (last_significant_end == start) {
                    self.advance();
                    continue;
                }
                var q = self.pos + 1;
                while (q < self.tokens.len) : (q += 1) {
                    const qt = self.tokens[q].tag;
                    if (qt == .whitespace or qt == .newline or qt == .comment) continue;
                    break;
                }
                if (q < self.tokens.len) {
                    const qtok = self.tokens[q];
                    const q_line_start = self.lineStartAtByte(qtok.span.start);
                    if (q_line_start > header_line_start) {
                        const q_indent = self.lineIndentAtByte(qtok.span.start);
                        if (q_indent > header_indent) return error.SyntaxError;
                    }
                }
                break;
            }

            if (tok.tag == .semicolon or tok.tag == .rbrace or tok.tag == .eof) break;
            if (tok.tag == .lbrace) return error.SyntaxError;

            // `!optional` trailing flag -- only recognized at depth 0.
            if (tok.tag == .bang) {
                const saved = self.pos;
                self.advance();
                if (self.is_indented_syntax) {
                    self.skipInlineWhitespaceAndComments();
                } else {
                    self.skipWhitespaceAndComments();
                }
                if (!self.isAtEnd() and self.current().tag == .ident and
                    std.mem.eql(u8, self.current().slice(self.source), "optional"))
                {
                    is_optional = true;
                    self.advance();
                    break;
                }
                self.pos = saved;
                last_significant_end = tok.span.end;
                last_significant_tag = tok.tag;
                self.advance();
                continue;
            }

            if (tok.tag != .whitespace and tok.tag != .newline and tok.tag != .comment) {
                last_significant_end = tok.span.end;
                last_significant_tag = tok.tag;
            }
            self.advance();
        }

        if (last_significant_end == start) return error.SyntaxError;

        const sel_text = self.source[start..last_significant_end];
        const sel_id = try self.intern_pool.intern(sel_text);
        const sel_node = try ast.addNode(.{
            .tag = .expr_unquoted_ident,
            .flags = 0,
            .payload = @intFromEnum(sel_id),
            .span_start = start,
            .span_end = last_significant_end,
        });

        var end_pos: u32 = last_significant_end;
        self.skipWhitespaceAndComments();
        if (!self.isAtEnd() and self.current().tag == .semicolon) {
            end_pos = self.current().span.end;
            self.advance();
        }

        const extra_off = try ast.appendExtraU32(sel_node.toU32());

        var flags: u8 = 0;
        if (is_optional) flags |= 0b0000_0001;

        return try ast.addNode(.{
            .tag = .stmt_extend,
            .flags = flags,
            .payload = extra_off,
            .span_start = at_tok.span.start,
            .span_end = end_pos,
        });
    }

    /// Parse `@at-root [(with: ...)|selector] { body }`.
    ///
    /// When a selector (or `(with: ...)` modifier) is present, it is
    /// collected via `collectSelectorSpan` and emitted as an
    /// `expr_unquoted_ident` placeholder node.  When the rule is
    /// `@at-root { ... }` with no selector, the selector slot holds
    /// `u32.max` (sentinel for "none").
    ///
    /// stmt_at_root extra: `[selector_node_or_max, body_extra]`.
    fn parseAtRootRule(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const at_tok = self.current();
        std.debug.assert(at_tok.tag == .at_at_root);
        self.advance();
        self.skipWhitespaceAndComments();

        var selector_slot: u32 = std.math.maxInt(u32);
        if (!self.isAtEnd() and
            self.current().tag != .lbrace and
            self.current().tag != .semicolon and
            self.current().tag != .rbrace and
            self.current().tag != .eof)
        {
            // In indented syntax (`.sass`), `@at-root` may omit braces and
            // have either:
            //   * no query (`@at-root`)
            //   * query/prelude only (`@at-root (with: media)`)
            //   * an indented body on the following line.
            //
            // collectSelectorSpan() hard-requires `{ ... }`, so use a
            // permissive collector that also stops at indented body start.
            const header_indent = self.lineIndentAtByte(at_tok.span.start);
            const header_line_start = self.lineStartAtByte(at_tok.span.start);
            const sel_span = try self.collectAtRootPreludeSpan(header_indent, header_line_start);
            if (sel_span.end > sel_span.start) {
                const sel_text = self.source[sel_span.start..sel_span.end];
                const sel_id = try self.intern_pool.intern(sel_text);
                const sel_node = try ast.addNode(.{
                    .tag = .expr_unquoted_ident,
                    .flags = 0,
                    .payload = @intFromEnum(sel_id),
                    .span_start = sel_span.start,
                    .span_end = sel_span.end,
                });
                selector_slot = sel_node.toU32();
            }
        }

        const body = try self.parseBlockBody(ast);

        const extra_off = try ast.appendExtraU32(selector_slot);
        _ = try ast.appendExtraU32(body.extra);

        return try ast.addNode(.{
            .tag = .stmt_at_root,
            .flags = 0,
            .payload = extra_off,
            .span_start = at_tok.span.start,
            .span_end = body.span_end,
        });
    }

    /// Collect `@at-root` prelude/query text up to one of:
    ///   * `{` / `;` / `}` / EOF
    ///   * start of an indented body line (`.sass`)
    ///
    /// Returns a possibly-empty span.  On return, `self.pos` is left at the
    /// terminator/body-start token (not consumed).
    fn collectAtRootPreludeSpan(self: *Parser, header_indent: u32, header_line_start: u32) ParseError!Span {
        if (self.isAtEnd()) return .{ .start = 0, .end = 0 };

        const start = self.current().span.start;
        var depth: u32 = 0;
        var interp_depth: u32 = 0;
        var last_significant_end: u32 = start;

        while (!self.isAtEnd()) {
            const tok = self.current();

            if (self.is_indented_syntax and interp_depth == 0 and depth == 0 and
                tok.tag != .whitespace and tok.tag != .newline and tok.tag != .comment)
            {
                const tok_line_start = self.lineStartAtByte(tok.span.start);
                const tok_indent = self.lineIndentAtByte(tok.span.start);
                if (tok_line_start > header_line_start and tok_indent > header_indent) {
                    // Start of an indented body line: prelude ends before it.
                    break;
                }
            }

            if (tok.tag == .hash_lbrace) {
                interp_depth += 1;
                last_significant_end = tok.span.end;
                self.advance();
                continue;
            }
            if (tok.tag == .rbrace and interp_depth > 0) {
                interp_depth -= 1;
                last_significant_end = tok.span.end;
                self.advance();
                continue;
            }
            if (interp_depth > 0) {
                last_significant_end = tok.span.end;
                self.advance();
                continue;
            }

            if (tok.tag == .lparen or tok.tag == .lbracket) {
                depth += 1;
                last_significant_end = tok.span.end;
                self.advance();
                continue;
            }
            if ((tok.tag == .rparen or tok.tag == .rbracket) and depth > 0) {
                depth -= 1;
                last_significant_end = tok.span.end;
                self.advance();
                continue;
            }
            if (depth > 0) {
                last_significant_end = tok.span.end;
                self.advance();
                continue;
            }

            if (tok.tag == .lbrace or tok.tag == .semicolon or tok.tag == .rbrace or tok.tag == .eof) {
                break;
            }

            if (tok.tag != .whitespace and tok.tag != .newline and tok.tag != .comment) {
                last_significant_end = tok.span.end;
            }
            self.advance();
        }

        return .{ .start = start, .end = last_significant_end };
    }

    // -- @mixin / @function / @include / generic at-rule (R.2c.7) -----------

    /// Parse a `($name [: default], $more..., ...)` parameter list.
    ///
    /// On entry, `self.pos` must index the opening `(`.  On success,
    /// `self.pos` is past the matching `)`.  Returns an ExtraIndex
    /// pointing at:
    ///
    ///   [count: u32,
    ///    has_splat: u32 (0 or 1),
    ///    name_0: InternId, default_0_or_max: u32,
    ///    name_1: InternId, default_1_or_max: u32,
    ///    ...]
    ///
    /// Defaults are stored as a NodeIndex (cast to u32) or `u32.max`
    /// when the parameter has no default.  `has_splat == 1` means the
    /// **last** declared parameter carries a trailing `...` (Sass
    /// grammar requires splat to be last).
    fn parseParamList(self: *Parser, ast: *Ast) ParseError!ExtraIndex {
        if (self.isAtEnd() or self.current().tag != .lparen) return error.SyntaxError;
        self.advance(); // skip (
        self.skipWhitespaceAndComments();

        var names: std.ArrayListUnmanaged(InternId) = .empty;
        defer names.deinit(self.allocator);
        var defaults: std.ArrayListUnmanaged(u32) = .empty;
        defer defaults.deinit(self.allocator);
        var has_splat = false;

        while (!self.isAtEnd() and self.current().tag != .rparen) {
            if (has_splat) return error.SyntaxError;
            if (self.current().tag != .dollar_ident) return error.SyntaxError;
            const var_tok = self.current();
            const var_text = var_tok.slice(self.source);
            std.debug.assert(var_text.len >= 1 and var_text[0] == '$');
            const name_id = try self.intern_pool.intern(var_text[1..]);
            self.advance();
            self.skipWhitespaceAndComments();

            var default_slot: u32 = std.math.maxInt(u32);

            // Splat `$name...`
            if (self.pos + 2 < self.tokens.len and
                self.tokens[self.pos].tag == .dot and
                self.tokens[self.pos + 1].tag == .dot and
                self.tokens[self.pos + 2].tag == .dot)
            {
                has_splat = true;
                self.advance();
                self.advance();
                self.advance();
                self.skipWhitespaceAndComments();
            } else if (!self.isAtEnd() and self.current().tag == .colon) {
                // Default value: `$name: expr`
                self.advance();
                self.skipWhitespaceAndComments();
                const def_node = try self.parseSpaceListOrSingle(ast);
                default_slot = def_node.toU32();
                self.skipWhitespaceAndComments();
            }

            try names.append(self.allocator, name_id);
            try defaults.append(self.allocator, default_slot);

            if (!self.isAtEnd() and self.current().tag == .comma) {
                self.advance();
                self.skipWhitespaceAndComments();
                continue;
            }
            break;
        }

        if (self.isAtEnd() or self.current().tag != .rparen) return error.SyntaxError;
        self.advance(); // skip )

        const extra_off = try ast.appendExtraU32(@intCast(names.items.len));
        _ = try ast.appendExtraU32(if (has_splat) @as(u32, 1) else 0);
        for (names.items, defaults.items) |n, d| {
            _ = try ast.appendExtraU32(@intFromEnum(n));
            _ = try ast.appendExtraU32(d);
        }
        return extra_off;
    }

    /// Parse `@mixin name [(params)] { body }`.
    ///
    /// stmt_mixin_decl extra: `[name_id, params_extra_or_max, body_extra]`.
    fn parseMixinDecl(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const at_tok = self.current();
        std.debug.assert(at_tok.tag == .at_mixin);
        self.advance();
        self.skipWhitespaceAndComments();

        if (self.isAtEnd() or self.current().tag != .ident) return error.SyntaxError;
        const name_tok = self.current();
        // `@mixin --name` is an error per Sass ("Sass @mixin names
        // beginning with -- are forbidden").  Emit it as a normal
        // `stmt_mixin_decl` here so the evaluator reports the error with
        // its usual diagnostic rather than silently passing it through.
        const name_id = try self.intern_pool.intern(name_tok.slice(self.source));
        self.advance();
        self.skipWhitespaceAndComments();

        var params_extra: u32 = std.math.maxInt(u32);
        if (!self.isAtEnd() and self.current().tag == .lparen) {
            params_extra = try self.parseParamList(ast);
            self.skipWhitespaceAndComments();
        }

        const body = try self.parseBlockBody(ast);

        const extra_off = try ast.appendExtraU32(@intFromEnum(name_id));
        _ = try ast.appendExtraU32(params_extra);
        _ = try ast.appendExtraU32(body.extra);

        return try ast.addNode(.{
            .tag = .stmt_mixin_decl,
            .flags = 0,
            .payload = extra_off,
            .span_start = at_tok.span.start,
            .span_end = body.span_end,
        });
    }

    /// Parse indented-syntax shorthand mixin declaration:
    /// `=name` / `=\n  name` [(params)] <indented body>.
    ///
    /// Emits the same AST shape as `@mixin`: `stmt_mixin_decl` with
    /// extra `[name_id, params_extra_or_max, body_extra]`.
    fn parseSassEqualsMixinDecl(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const eq_tok = self.current();
        std.debug.assert(eq_tok.tag == .equal);
        self.advance(); // skip `=`
        self.skipWhitespaceAndComments();

        if (self.isAtEnd() or self.current().tag != .ident) return error.SyntaxError;
        const name_tok = self.current();
        const name_id = try self.intern_pool.intern(name_tok.slice(self.source));
        self.advance();
        self.skipWhitespaceAndComments();

        var params_extra: u32 = std.math.maxInt(u32);
        if (!self.isAtEnd() and self.current().tag == .lparen) {
            params_extra = try self.parseParamList(ast);
            self.skipWhitespaceAndComments();
        }

        const body = try self.parseBlockBody(ast);

        const extra_off = try ast.appendExtraU32(@intFromEnum(name_id));
        _ = try ast.appendExtraU32(params_extra);
        _ = try ast.appendExtraU32(body.extra);

        return try ast.addNode(.{
            .tag = .stmt_mixin_decl,
            .flags = 0,
            .payload = extra_off,
            .span_start = eq_tok.span.start,
            .span_end = body.span_end,
        });
    }

    /// Parse indented-syntax shorthand mixin include:
    /// `+name` / `+ns.name` [(args)] [using(params)] [indented body].
    fn parseSassPlusIncludeRule(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const plus_tok = self.current();
        std.debug.assert(plus_tok.tag == .plus);
        self.advance(); // skip `+`
        self.skipInlineWhitespaceAndComments();

        if (self.isAtEnd() or self.current().tag != .ident) return error.SyntaxError;
        const first_tok = self.current();
        const first_text = first_tok.slice(self.source);
        self.advance();

        var name_id: InternId = .none;
        var namespace_id: InternId = .none;
        if (!self.isAtEnd() and self.current().tag == .dot) {
            self.advance();
            if (self.isAtEnd() or self.current().tag != .ident) return error.SyntaxError;
            const sub_text = self.current().slice(self.source);
            self.advance();
            namespace_id = try self.intern_pool.intern(first_text);
            name_id = try self.intern_pool.intern(sub_text);
        } else {
            name_id = try self.intern_pool.intern(first_text);
        }

        self.skipInlineWhitespaceAndComments();

        var args_extra: u32 = std.math.maxInt(u32);
        if (!self.isAtEnd() and self.current().tag == .lparen) {
            var depth: u32 = 0;
            var expect_value: bool = true;
            while (!self.isAtEnd()) {
                const tok = self.current();
                if (tok.tag == .lparen) {
                    depth += 1;
                    self.advance();
                    if (depth == 1) expect_value = true;
                    continue;
                }
                if (tok.tag == .rparen) {
                    depth -= 1;
                    self.advance();
                    if (depth == 0) break;
                    if (depth == 1) expect_value = false;
                    continue;
                }
                if (tok.tag == .eof) return error.SyntaxError;
                if (depth == 1 and tok.tag == .comma) {
                    if (expect_value) return error.SyntaxError;
                    expect_value = true;
                    self.advance();
                    continue;
                }
                if (depth == 1 and tok.tag != .whitespace and
                    tok.tag != .newline and tok.tag != .comment)
                {
                    expect_value = false;
                }
                self.advance();
            }
            // Sentinel marker: args were present.
            args_extra = try ast.appendExtraU32(0);
        }

        self.skipInlineWhitespaceAndComments();

        var using_extra: u32 = std.math.maxInt(u32);
        var had_using_clause = false;
        if (!self.isAtEnd() and self.current().tag == .ident and
            std.ascii.eqlIgnoreCase(self.current().slice(self.source), "using"))
        {
            self.advance();
            self.skipInlineWhitespaceAndComments();
            using_extra = try self.parseParamList(ast);
            self.skipInlineWhitespaceAndComments();
            had_using_clause = true;
        }

        if (self.is_indented_syntax) {
            self.skipWhitespaceAndComments();
        }

        var body_extra: u32 = std.math.maxInt(u32);
        var end_pos: u32 = self.tokens[self.pos - 1].span.end;
        if (!self.isAtEnd() and self.current().tag == .lbrace) {
            const body = try self.parseBlockBody(ast);
            body_extra = body.extra;
            end_pos = body.span_end;
        } else if (self.startsIndentedBodyAfterHeader(plus_tok.span.start)) {
            const body = try self.parseBlockBody(ast);
            body_extra = body.extra;
            end_pos = body.span_end;
        } else if (!self.isAtEnd() and self.current().tag == .semicolon) {
            if (had_using_clause) return error.SyntaxError;
            end_pos = self.current().span.end;
            self.advance();
        } else if (had_using_clause) {
            return error.SyntaxError;
        }

        const outer_off = try ast.appendExtraU32(@intFromEnum(name_id));
        _ = try ast.appendExtraU32(@intFromEnum(namespace_id));
        _ = try ast.appendExtraU32(args_extra);
        _ = try ast.appendExtraU32(using_extra);
        _ = try ast.appendExtraU32(body_extra);

        return try ast.addNode(.{
            .tag = .stmt_include_rule,
            .flags = 0,
            .payload = outer_off,
            .span_start = plus_tok.span.start,
            .span_end = end_pos,
        });
    }

    /// Parse `@function name(params) { body }`.  A parameter list is
    /// **required** (Sass spec).
    ///
    /// stmt_function_decl extra: `[name_id, params_extra, body_extra]`.
    fn parseFunctionDecl(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const at_tok = self.current();
        std.debug.assert(at_tok.tag == .at_function);
        const saved_pos = self.pos;
        self.advance();
        self.skipWhitespaceAndComments();

        // The name can be `#{...}` interpolation (CSS Functions Module
        // allows any CSS ident here).  Accept `ident` or a `hash_lbrace`
        // prefix by rewinding to a generic at-rule when the token isn't
        // a plain Sass ident.
        if (!self.isAtEnd() and self.current().tag == .hash_lbrace) {
            self.pos = saved_pos;
            const saved_flag = self.in_css_custom_function;
            defer self.in_css_custom_function = saved_flag;
            self.in_css_custom_function = true;
            return self.parseAtRule(ast);
        }
        if (self.isAtEnd() or self.current().tag != .ident) return error.SyntaxError;
        const name_tok = self.current();
        // CSS Custom Function (`@function --name`) -- emit as a generic
        // at-rule so the legacy evaluator passes it through verbatim.
        // Set `in_css_custom_function` so parseRuleOrDeclaration treats
        // `result: {...}` inside the body as a declaration (raw value)
        // rather than a selector + block.
        const name_text_for_check = name_tok.slice(self.source);
        if (name_text_for_check.len >= 2 and
            name_text_for_check[0] == '-' and name_text_for_check[1] == '-')
        {
            self.pos = saved_pos;
            const saved_flag = self.in_css_custom_function;
            defer self.in_css_custom_function = saved_flag;
            self.in_css_custom_function = true;
            return self.parseAtRule(ast);
        }
        const name_id = try self.intern_pool.intern(name_tok.slice(self.source));
        self.advance();
        self.skipWhitespaceAndComments();

        if (self.isAtEnd() or self.current().tag != .lparen) return error.SyntaxError;
        const params_extra = try self.parseParamList(ast);
        self.skipWhitespaceAndComments();

        const body = try self.parseBlockBody(ast);

        const extra_off = try ast.appendExtraU32(@intFromEnum(name_id));
        _ = try ast.appendExtraU32(params_extra);
        _ = try ast.appendExtraU32(body.extra);

        return try ast.addNode(.{
            .tag = .stmt_function_decl,
            .flags = 0,
            .payload = extra_off,
            .span_start = at_tok.span.start,
            .span_end = body.span_end,
        });
    }

    /// Parse `@include [ns.]name[(args)] [using (params)] [{ content }] [;]`.
    ///
    /// stmt_include_rule extra:
    ///   `[name_id, namespace_id, args_extra_or_max,
    ///     using_extra_or_max, body_extra_or_max]`
    ///
    /// Diverges from design Section 2.3 by storing `namespace_id` explicitly
    /// (matching the `expr_func_call` precedent set in R.2c.2c).
    fn parseIncludeRule(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const at_tok = self.current();
        const include_line_start = self.lineStartAtByte(at_tok.span.start);
        std.debug.assert(at_tok.tag == .at_include);
        self.advance();
        self.skipWhitespaceAndComments();

        if (self.isAtEnd() or self.current().tag != .ident) return error.SyntaxError;
        const first_tok = self.current();
        const first_text = first_tok.slice(self.source);
        self.advance();

        var name_id: InternId = .none;
        var namespace_id: InternId = .none;

        // Namespaced: `ns.name`
        if (!self.isAtEnd() and self.current().tag == .dot) {
            self.advance();
            if (self.isAtEnd() or self.current().tag != .ident) return error.SyntaxError;
            const sub_text = self.current().slice(self.source);
            self.advance();
            namespace_id = try self.intern_pool.intern(first_text);
            name_id = try self.intern_pool.intern(sub_text);
        } else {
            name_id = try self.intern_pool.intern(first_text);
        }

        // Optional `(args)`.  parser does not semantically interpret the
        // argument list -- evaluator-side include decoding re-scans the raw
        // source span and legacy argument parsing handles CSS-native forms
        // the Sass grammar cannot model (e.g.
        // `lab(attr(c, %) 2 3 / 0.4)` inside `inspect(...)`).  Just skip
        // over a balanced-paren run when present.  Whitespace between
        // the name and the `(` is allowed (`@include foo () { ... }`).
        self.skipWhitespaceAndComments();
        var args_extra: u32 = std.math.maxInt(u32);
        if (!self.isAtEnd() and self.current().tag == .lparen) {
            var depth: u32 = 0;
            // Guard against `(,)` / `(,a)` / `(a,,b)` at depth 1 -- the
            // Sass grammar requires every comma at the top level of an
            // arglist to be preceded by a value.  We track whether the
            // previous "significant" top-level token was a comma or the
            // opening `(`; another comma in that state is a syntax error.
            var expect_value: bool = true;
            while (!self.isAtEnd()) {
                const tok = self.current();
                if (tok.tag == .lparen) {
                    depth += 1;
                    self.advance();
                    if (depth == 1) expect_value = true;
                    continue;
                }
                if (tok.tag == .rparen) {
                    depth -= 1;
                    self.advance();
                    if (depth == 0) break;
                    // Dropping back to depth 1 means the enclosed
                    // `(...)` filled the current arg slot, so the next
                    // top-level token after the `)` is allowed to be
                    // either `,` or `)` (matching Sass arglist rules).
                    if (depth == 1) expect_value = false;
                    continue;
                }
                if (tok.tag == .eof) return error.SyntaxError;
                if (depth == 1 and tok.tag == .comma) {
                    if (expect_value) return error.SyntaxError;
                    expect_value = true;
                    self.advance();
                    continue;
                }
                if (depth == 1 and tok.tag != .whitespace and
                    tok.tag != .newline and tok.tag != .comment)
                {
                    expect_value = false;
                }
                self.advance();
            }
            // Sentinel marker (not u32.max) so evaluator-side include
            // decoding knows args were present and can re-derive the span.
            args_extra = try ast.appendExtraU32(0);
        }

        self.skipWhitespaceAndComments();

        // Optional `using (params)` clause -- case-insensitive per Sass
        // grammar (`using`, `Using`, `USING`, `UsInG` all parse).
        var using_extra: u32 = std.math.maxInt(u32);
        var had_using_clause = false;
        if (!self.isAtEnd() and self.current().tag == .ident and
            (!self.is_indented_syntax or self.lineStartAtByte(self.current().span.start) == include_line_start) and
            std.ascii.eqlIgnoreCase(self.current().slice(self.source), "using"))
        {
            self.advance();
            self.skipWhitespaceAndComments();
            using_extra = try self.parseParamList(ast);
            self.skipWhitespaceAndComments();
            had_using_clause = true;
        }

        // Optional content block or semicolon terminator.
        //
        // SCSS: content block must be braced.
        // Sass: content block may be an indented block.
        //
        // For indented syntax, `@include ... using (...)` with no content
        // block is accepted as an implicit empty block (matches sass-spec
        // `directives/mixin/whitespace.hrx::include/after_using/sass`).
        var body_extra: u32 = std.math.maxInt(u32);
        var end_pos: u32 = self.tokens[self.pos - 1].span.end;
        if (!self.isAtEnd() and self.current().tag == .lbrace) {
            const body = try self.parseBlockBody(ast);
            body_extra = body.extra;
            end_pos = body.span_end;
        } else if (self.is_indented_syntax and self.startsIndentedBodyAfterHeader(at_tok.span.start)) {
            const body = try self.parseBlockBody(ast);
            body_extra = body.extra;
            end_pos = body.span_end;
        } else if (!self.isAtEnd() and self.current().tag == .semicolon) {
            if (had_using_clause) return error.SyntaxError;
            end_pos = self.current().span.end;
            self.advance();
        } else if (had_using_clause) {
            if (!self.is_indented_syntax) return error.SyntaxError;
        } else if (!self.isAtEnd()) {
            // Anything else after the optional `(args)` (and absent a
            // valid terminator above) is a syntax error.  The only
            // legitimate way for an `@include` to end implicitly is at
            // the end of file or just before the `}` that closes the
            // enclosing block -- match those, but reject things like
            // `@include mixin() () {}` (extra paren) which official Sass CLI
            // rejects with `expected ";"`.
            if (self.is_indented_syntax) {
                // In indented syntax, the statement ends implicitly at a
                // sibling/dedent line. Leave the next token untouched.
            } else {
                const next_tag = self.current().tag;
                if (next_tag != .rbrace) return error.SyntaxError;
            }
        }

        const outer_off = try ast.appendExtraU32(@intFromEnum(name_id));
        _ = try ast.appendExtraU32(@intFromEnum(namespace_id));
        _ = try ast.appendExtraU32(args_extra);
        _ = try ast.appendExtraU32(using_extra);
        _ = try ast.appendExtraU32(body_extra);

        return try ast.addNode(.{
            .tag = .stmt_include_rule,
            .flags = 0,
            .payload = outer_off,
            .span_start = at_tok.span.start,
            .span_end = end_pos,
        });
    }

    /// Parse a generic at-rule: `@name [prelude] { body }` or
    /// `@name [prelude] ;`.
    ///
    /// This handler owns `@media`, `@supports`, `@keyframes`,
    /// `@font-face`, `@charset`, and any unknown `@custom` -- the
    /// latter comes through the lexer as `.at_keyword`.  Known Sass
    /// at-rules (`@use`, `@mixin`, etc.) have dedicated parsers and
    /// never reach this function.
    ///
    /// The at-rule name is interned **without** the leading `@`.
    /// The prelude is captured as a raw source slice from just after
    /// the name up to the terminating `{` or `;`, with paren /
    /// bracket / interpolation depth tracked.  An empty prelude sets
    /// `prelude_slot = u32.max`.  The statement form (`@foo ;`)
    /// yields `body_extra = u32.max`.
    ///
    /// stmt_at_rule extra: `[name_id, prelude_slot_or_max, body_extra_or_max]`.
    fn parseAtRule(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const at_tok = self.current();
        const at_text = at_tok.slice(self.source);
        const name_text = if (at_text.len > 0 and at_text[0] == '@') at_text[1..] else at_text;
        const is_supports_at_rule = std.mem.eql(u8, name_text, "supports");
        const is_media_at_rule = std.mem.eql(u8, name_text, "media");
        const preserve_line_comments_in_prelude = is_media_at_rule or
            is_supports_at_rule or
            std.mem.eql(u8, name_text, "layer") or
            std.mem.eql(u8, name_text, "container");
        const header_line_start = self.lineStartAtByte(at_tok.span.start);
        const header_indent = self.lineIndentAtByte(at_tok.span.start);
        // `@` followed by whitespace (e.g. `@ unknown` / `@ #{"x"}`) is a
        // syntax error -- Sass requires the at-rule name to immediately
        // follow `@` with no separating whitespace.  `@#{...}` (interp
        // glued to `@`) is allowed: the next token is `hash_lbrace` whose
        // span starts exactly at the end of the `@` token.
        if (name_text.len == 0) {
            const next_idx = self.pos + 1;
            const allowed_glued_interp = next_idx < self.tokens.len and
                self.tokens[next_idx].tag == .hash_lbrace and
                self.tokens[next_idx].span.start == at_tok.span.end;
            if (!allowed_glued_interp) return error.SyntaxError;
        }
        // Standalone `@elseif` (outside an `@if` chain) is invalid Sass.
        // Parser-level reject so the evaluator does not try to treat it
        // as a generic at-rule.
        if (std.mem.eql(u8, name_text, "elseif") or std.mem.eql(u8, name_text, "else if")) {
            return error.SyntaxError;
        }
        // The at-rule name may continue across adjacent (no-whitespace)
        // `#{...}` interpolation tokens and subsequent ident / number
        // tokens -- e.g. `@interopl#{"x"}dle` is a single rule whose
        // name evaluates to `interoplated-middle`.  Only extend the
        // name capture when the very next token is `hash_lbrace` glued
        // to the at-keyword; otherwise keep the narrow (plain-ident)
        // name so dedicated builtin dispatch (e.g. `elseif` check) and
        // existing tests are unaffected.
        var name_span_end: u32 = at_tok.span.end;
        const next_after_at = self.pos + 1;
        const has_glued_interp = next_after_at < self.tokens.len and
            self.tokens[next_after_at].tag == .hash_lbrace and
            self.tokens[next_after_at].span.start == at_tok.span.end;
        if (has_glued_interp) {
            var name_probe: usize = next_after_at;
            while (name_probe < self.tokens.len) {
                const nt = self.tokens[name_probe];
                if (nt.span.start != name_span_end) break;
                if (nt.tag == .ident or nt.tag == .number) {
                    name_span_end = nt.span.end;
                    name_probe += 1;
                    continue;
                }
                if (nt.tag == .hash_lbrace) {
                    var depth: usize = 1;
                    var p2 = name_probe + 1;
                    var closed = false;
                    while (p2 < self.tokens.len) : (p2 += 1) {
                        const t2 = self.tokens[p2].tag;
                        if (t2 == .hash_lbrace or t2 == .lbrace) {
                            depth += 1;
                        } else if (t2 == .rbrace) {
                            depth -= 1;
                            if (depth == 0) {
                                name_span_end = self.tokens[p2].span.end;
                                name_probe = p2 + 1;
                                closed = true;
                                break;
                            }
                        }
                    }
                    if (!closed) return error.SyntaxError;
                    continue;
                }
                break;
            }
        }
        const full_name_text = if (name_span_end > at_tok.span.end)
            self.source[at_tok.span.start + 1 .. name_span_end]
        else
            name_text;
        const name_id = try self.intern_pool.intern(full_name_text);
        // Advance past the whole name run (the at-keyword token plus
        // any adjacent interpolation/ident tokens we folded in).
        self.advance();
        while (self.pos < self.tokens.len and self.tokens[self.pos].span.end <= name_span_end) {
            self.advance();
        }
        self.skipWhitespaceAndComments();
        if (self.is_indented_syntax and atRuleRequiresSameLinePreludeInIndented(name_text) and !self.isAtEnd()) {
            const next_tok = self.current();
            if (next_tok.tag != .lbrace and next_tok.tag != .semicolon and next_tok.tag != .eof and next_tok.tag != .rbrace and
                self.lineStartAtByte(next_tok.span.start) > header_line_start)
            {
                return error.SyntaxError;
            }
        }

        // Collect prelude tokens up to `{` / `;` / `}` / EOF / `.sass`
        // statement boundary. In indented syntax, a deeper-indented line
        // starts the at-rule body; same/shallow indentation ends the
        // statement.
        const prelude_start_idx: usize = self.pos;
        const prelude_start: u32 = if (!self.isAtEnd()) self.current().span.start else at_tok.span.end;
        var last_significant_idx: ?usize = null;
        var last_significant: u32 = prelude_start;
        var depth: u32 = 0;
        var interp_depth: u32 = 0;
        var last_significant_line_start: u32 = header_line_start;
        var last_supports_logic_keyword = false;

        while (!self.isAtEnd()) {
            const tok = self.current();
            if (self.is_indented_syntax and is_media_at_rule and depth == 0 and interp_depth == 0 and
                tok.tag != .whitespace and tok.tag != .newline and tok.tag != .comment)
            {
                const tok_line_start = self.lineStartAtByte(tok.span.start);
                if (tok_line_start > header_line_start and
                    self.lineIndentAtByte(tok.span.start) > header_indent and
                    self.tokenIsSupportsLogicKeyword(tok))
                {
                    var probe = self.pos + 1;
                    while (probe < self.tokens.len) : (probe += 1) {
                        const pt = self.tokens[probe].tag;
                        if (pt == .whitespace or pt == .newline or pt == .comment) continue;
                        if (pt == .lparen) return error.SyntaxError;
                        break;
                    }
                }
            }
            if (self.is_indented_syntax and is_supports_at_rule and depth == 0 and interp_depth == 0 and
                tok.tag != .whitespace and tok.tag != .newline and tok.tag != .comment)
            {
                const tok_line_start = self.lineStartAtByte(tok.span.start);
                if (tok_line_start > last_significant_line_start and
                    (last_supports_logic_keyword or tok.tag == .lparen or self.tokenIsSupportsLogicKeyword(tok)))
                {
                    return error.SyntaxError;
                }
            }
            if (self.is_indented_syntax and depth == 0 and interp_depth == 0 and
                tok.tag != .whitespace and tok.tag != .newline and tok.tag != .comment)
            {
                const tok_line_start = self.lineStartAtByte(tok.span.start);
                if (tok_line_start > header_line_start) {
                    const tok_indent = self.lineIndentAtByte(tok.span.start);
                    if (tok_indent > header_indent) {
                        // Start of indented body.
                        break;
                    }
                    // Sibling/dedent line => end of this at-rule statement.
                    break;
                }
            }
            if (tok.tag == .hash_lbrace) {
                interp_depth += 1;
                last_significant_idx = self.pos;
                last_significant = tok.span.end;
                last_significant_line_start = self.lineStartAtByte(tok.span.start);
                last_supports_logic_keyword = false;
                self.advance();
                continue;
            }
            if (tok.tag == .rbrace and interp_depth > 0) {
                interp_depth -= 1;
                last_significant_idx = self.pos;
                last_significant = tok.span.end;
                last_significant_line_start = self.lineStartAtByte(tok.span.start);
                last_supports_logic_keyword = false;
                self.advance();
                continue;
            }
            if (interp_depth > 0) {
                last_significant_idx = self.pos;
                last_significant = tok.span.end;
                last_significant_line_start = self.lineStartAtByte(tok.span.start);
                last_supports_logic_keyword = false;
                self.advance();
                continue;
            }
            if (tok.tag == .lparen or tok.tag == .lbracket) {
                depth += 1;
                last_significant_idx = self.pos;
                last_significant = tok.span.end;
                last_significant_line_start = self.lineStartAtByte(tok.span.start);
                last_supports_logic_keyword = false;
                self.advance();
                continue;
            }
            if ((tok.tag == .rparen or tok.tag == .rbracket) and depth > 0) {
                depth -= 1;
                last_significant_idx = self.pos;
                last_significant = tok.span.end;
                last_significant_line_start = self.lineStartAtByte(tok.span.start);
                last_supports_logic_keyword = false;
                self.advance();
                continue;
            }
            if (depth > 0) {
                last_significant_idx = self.pos;
                last_significant = tok.span.end;
                last_significant_line_start = self.lineStartAtByte(tok.span.start);
                last_supports_logic_keyword = false;
                self.advance();
                continue;
            }

            if (tok.tag == .lbrace or tok.tag == .semicolon or tok.tag == .eof or tok.tag == .rbrace) break;

            if (tok.tag != .whitespace and tok.tag != .newline) {
                // Block comments inside the prelude are preserved so that
                // `@a b /**/;` round-trips with the trailing `/**/`.  Line
                // comments (`// ...`) are dropped because they cannot appear
                // in CSS output at all.
                if (tok.tag == .comment) {
                    const text = tok.slice(self.source);
                    if (text.len >= 2 and text[0] == '/' and text[1] == '*') {
                        last_significant_idx = self.pos;
                        last_significant = tok.span.end;
                        last_significant_line_start = self.lineStartAtByte(tok.span.start);
                        last_supports_logic_keyword = false;
                    }
                } else {
                    last_significant_idx = self.pos;
                    last_significant = tok.span.end;
                    last_significant_line_start = self.lineStartAtByte(tok.span.start);
                    last_supports_logic_keyword = self.tokenIsSupportsLogicKeyword(tok);
                }
            }
            self.advance();
        }

        var prelude_slot: u32 = std.math.maxInt(u32);
        if (try self.emitUnquotedTextExprFromTokenRange(
            ast,
            prelude_start_idx,
            self.pos,
            last_significant_idx,
            preserve_line_comments_in_prelude,
            false,
            0,
        )) |p_node| {
            prelude_slot = p_node.toU32();
        }

        var body_extra: u32 = std.math.maxInt(u32);
        var end_pos: u32 = last_significant;
        if (!self.isAtEnd() and self.current().tag == .lbrace) {
            const body = try self.parseBlockBody(ast);
            body_extra = body.extra;
            end_pos = body.span_end;
        } else if (self.is_indented_syntax and self.startsIndentedBodyAfterHeader(at_tok.span.start)) {
            const body = try self.parseBlockBodyAnchored(ast, at_tok.span.start);
            body_extra = body.extra;
            end_pos = body.span_end;
        } else if (!self.isAtEnd() and self.current().tag == .semicolon) {
            end_pos = self.current().span.end;
            self.advance();
        }

        const extra_off = try ast.appendExtraU32(@intFromEnum(name_id));
        _ = try ast.appendExtraU32(prelude_slot);
        _ = try ast.appendExtraU32(body_extra);

        return try ast.addNode(.{
            .tag = .stmt_at_rule,
            .flags = 0,
            .payload = extra_off,
            .span_start = at_tok.span.start,
            .span_end = end_pos,
        });
    }

    fn tokenIsSupportsLogicKeyword(self: *const Parser, tok: Token) bool {
        if (tok.tag != .ident) return false;
        const text = tok.slice(self.source);
        return std.ascii.eqlIgnoreCase(text, "and") or
            std.ascii.eqlIgnoreCase(text, "or") or
            std.ascii.eqlIgnoreCase(text, "not");
    }

    fn tokenIsLineComment(self: *const Parser, tok: Token) bool {
        if (tok.tag != .comment) return false;
        const text = tok.slice(self.source);
        return text.len >= 2 and text[0] == '/' and text[1] == '/';
    }

    fn advancePastCommentText(_: *const Parser, text: []const u8, index: *usize) bool {
        const i = index.*;
        if (i + 1 >= text.len or text[i] != '/') return false;

        if (text[i + 1] == '*') {
            var j = i + 2;
            while (j + 1 < text.len) : (j += 1) {
                if (text[j] == '*' and text[j + 1] == '/') {
                    index.* = j + 2;
                    return true;
                }
            }
            index.* = text.len;
            return true;
        }

        if (text[i + 1] == '/') {
            var j = i + 2;
            while (j < text.len and text[j] != '\n' and text[j] != '\r') : (j += 1) {}
            index.* = j;
            return true;
        }

        return false;
    }

    fn appendTextLiteralPart(
        self: *Parser,
        parts: *std.ArrayListUnmanaged(u32),
        text: []const u8,
    ) ParseError!void {
        if (text.len == 0) return;
        const id = try self.intern_pool.intern(text);
        try parts.append(self.allocator, 0);
        try parts.append(self.allocator, @intFromEnum(id));
    }

    fn flushPendingTextLiteral(
        self: *Parser,
        parts: *std.ArrayListUnmanaged(u32),
        lit_buf: *std.ArrayListUnmanaged(u8),
    ) ParseError!void {
        if (lit_buf.items.len == 0) return;
        try self.appendTextLiteralPart(parts, lit_buf.items);
        lit_buf.clearRetainingCapacity();
    }

    fn appendTextPartsFromSlice(
        self: *Parser,
        ast: *Ast,
        parts: *std.ArrayListUnmanaged(u32),
        text: []const u8,
        byte_offset: u32,
        lowercase_prefix_remaining: *usize,
        saw_interp: *bool,
    ) ParseError!void {
        var i: usize = 0;
        var lit_start: usize = 0;
        while (i < text.len) {
            const c = text[i];
            if (c == '\\' and i + 1 < text.len) {
                i += 2;
                continue;
            }
            if (self.advancePastCommentText(text, &i)) continue;
            if (c == '#' and i + 1 < text.len and text[i + 1] == '{') {
                if (i > lit_start) {
                    const lit = text[lit_start..i];
                    if (lowercase_prefix_remaining.* == 0) {
                        try self.appendTextLiteralPart(parts, lit);
                    } else {
                        var transformed: std.ArrayListUnmanaged(u8) = .empty;
                        defer transformed.deinit(self.allocator);
                        try self.appendLiteralSliceWithLowercasePrefix(
                            &transformed,
                            lit,
                            lowercase_prefix_remaining,
                        );
                        try self.appendTextLiteralPart(parts, transformed.items);
                    }
                }

                const expr_start = i + 2;
                var depth: u32 = 1;
                var j: usize = expr_start;
                var in_str: u8 = 0;
                while (j < text.len and depth > 0) {
                    const ch = text[j];
                    if (in_str != 0) {
                        if (ch == '\\' and j + 1 < text.len) {
                            j += 2;
                            continue;
                        }
                        if (ch == in_str) in_str = 0;
                        j += 1;
                        continue;
                    }
                    if (ch == '\\' and j + 1 < text.len) {
                        j += 2;
                        continue;
                    }
                    if (self.advancePastCommentText(text, &j)) continue;
                    if (ch == '"' or ch == '\'') {
                        in_str = ch;
                        j += 1;
                        continue;
                    }
                    if (ch == '#' and j + 1 < text.len and text[j + 1] == '{') {
                        depth += 1;
                        j += 2;
                        continue;
                    }
                    if (ch == '}') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                    j += 1;
                }
                if (depth != 0) return error.SyntaxError;

                const expr_bytes = text[expr_start..j];
                const sub_node = try self.parseInterpolationSubExpr(
                    ast,
                    expr_bytes,
                    byte_offset + @as(u32, @intCast(expr_start)),
                );
                self.unquoteNodeForInterpolation(ast, sub_node);
                saw_interp.* = true;
                try parts.append(self.allocator, 1);
                try parts.append(self.allocator, sub_node.toU32());

                i = j + 1;
                lit_start = i;
                continue;
            }
            i += 1;
        }

        if (lit_start < text.len) {
            const lit = text[lit_start..];
            if (lowercase_prefix_remaining.* == 0) {
                try self.appendTextLiteralPart(parts, lit);
            } else {
                var transformed: std.ArrayListUnmanaged(u8) = .empty;
                defer transformed.deinit(self.allocator);
                try self.appendLiteralSliceWithLowercasePrefix(
                    &transformed,
                    lit,
                    lowercase_prefix_remaining,
                );
                try self.appendTextLiteralPart(parts, transformed.items);
            }
        }
    }

    fn emitUnquotedTextExprFromSlice(
        self: *Parser,
        ast: *Ast,
        text: []const u8,
        byte_offset: u32,
        span_start: u32,
        span_end: u32,
    ) ParseError!NodeIndex {
        var parts: std.ArrayListUnmanaged(u32) = .empty;
        defer parts.deinit(self.allocator);

        var saw_interp = false;
        var lowercase_prefix_remaining: usize = 0;
        try self.appendTextPartsFromSlice(
            ast,
            &parts,
            text,
            byte_offset,
            &lowercase_prefix_remaining,
            &saw_interp,
        );
        if (parts.items.len == 0) {
            try self.appendTextLiteralPart(&parts, text);
        }

        const extra_off = try ast.appendExtraU32(@intCast(parts.items.len / 2));
        for (parts.items) |v| {
            _ = try ast.appendExtraU32(v);
        }
        return try ast.addNode(.{
            .tag = .expr_text_template,
            .flags = 0,
            .payload = extra_off,
            .span_start = span_start,
            .span_end = span_end,
        });
    }

    fn appendLiteralSliceWithLowercasePrefix(
        self: *Parser,
        lit_buf: *std.ArrayListUnmanaged(u8),
        slice: []const u8,
        lowercase_prefix_remaining: *usize,
    ) ParseError!void {
        if (slice.len == 0) return;
        const lower_len = @min(slice.len, lowercase_prefix_remaining.*);
        var i: usize = 0;
        while (i < lower_len) : (i += 1) {
            try lit_buf.append(self.allocator, std.ascii.toLower(slice[i]));
        }
        if (slice.len > lower_len) {
            try lit_buf.appendSlice(self.allocator, slice[lower_len..]);
        }
        lowercase_prefix_remaining.* -= lower_len;
    }

    fn emitUnquotedTextExprFromTokenRange(
        self: *Parser,
        ast: *Ast,
        start_idx: usize,
        end_idx: usize,
        last_significant_idx: ?usize,
        preserve_line_comments: bool,
        collapse_dropped_line_comment_whitespace: bool,
        lowercase_prefix_len: usize,
    ) ParseError!?NodeIndex {
        const last = last_significant_idx orelse return null;
        if (start_idx >= end_idx or last < start_idx) return null;

        const stop = @min(end_idx, last + 1);
        var parts: std.ArrayListUnmanaged(u32) = .empty;
        defer parts.deinit(self.allocator);
        var lit_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer lit_buf.deinit(self.allocator);
        var saw_interp = false;
        var span_start_opt: ?u32 = null;
        var span_end: u32 = 0;
        var lowercase_prefix_remaining = lowercase_prefix_len;
        var pending_dropped_line_comment_space = false;
        var i = start_idx;
        while (i < stop) : (i += 1) {
            const tok = self.tokens[i];
            if (!preserve_line_comments and self.tokenIsLineComment(tok)) {
                pending_dropped_line_comment_space = collapse_dropped_line_comment_whitespace;
                continue;
            }
            if (span_start_opt == null) span_start_opt = tok.span.start;
            span_end = tok.span.end;
            const tok_text = tok.slice(self.source);

            if (pending_dropped_line_comment_space) {
                try self.appendLiteralSliceWithLowercasePrefix(
                    &lit_buf,
                    " ",
                    &lowercase_prefix_remaining,
                );
                pending_dropped_line_comment_space = false;
                if (tok.tag == .newline) continue;
                if (tok.tag == .whitespace and std.mem.findAny(u8, tok_text, "\n\r") != null) continue;
            }

            if (tok.tag == .hash_lbrace) {
                try self.flushPendingTextLiteral(&parts, &lit_buf);

                const expr_start = tok.span.end;
                var depth: u32 = 1;
                i += 1;
                while (i < stop) : (i += 1) {
                    const t = self.tokens[i].tag;
                    if (t == .hash_lbrace) {
                        depth += 1;
                    } else if (t == .rbrace) {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                }
                if (depth != 0 or i >= stop) return error.SyntaxError;

                const close_tok = self.tokens[i];
                span_end = close_tok.span.end;
                const expr_bytes = self.source[expr_start..close_tok.span.start];
                const sub_node = try self.parseInterpolationSubExpr(ast, expr_bytes, expr_start);
                self.unquoteNodeForInterpolation(ast, sub_node);
                saw_interp = true;
                try parts.append(self.allocator, 1);
                try parts.append(self.allocator, sub_node.toU32());
                continue;
            }
            if (std.mem.find(u8, tok_text, "#{") != null) {
                try self.flushPendingTextLiteral(&parts, &lit_buf);
                try self.appendTextPartsFromSlice(
                    ast,
                    &parts,
                    tok_text,
                    tok.span.start,
                    &lowercase_prefix_remaining,
                    &saw_interp,
                );
            } else {
                try self.appendLiteralSliceWithLowercasePrefix(
                    &lit_buf,
                    tok_text,
                    &lowercase_prefix_remaining,
                );
            }
        }

        if (pending_dropped_line_comment_space) {
            try self.appendLiteralSliceWithLowercasePrefix(
                &lit_buf,
                " ",
                &lowercase_prefix_remaining,
            );
        }

        try self.flushPendingTextLiteral(&parts, &lit_buf);

        const span_start = span_start_opt orelse return null;
        if (parts.items.len == 0 and saw_interp) return null;
        if (parts.items.len == 0) try self.appendTextLiteralPart(&parts, "");

        const extra_off = try ast.appendExtraU32(@intCast(parts.items.len / 2));
        for (parts.items) |v| {
            _ = try ast.appendExtraU32(v);
        }
        return try ast.addNode(.{
            .tag = .expr_text_template,
            .flags = 0,
            .payload = extra_off,
            .span_start = span_start,
            .span_end = span_end,
        });
    }

    fn atRuleRequiresSameLinePreludeInIndented(name_text: []const u8) bool {
        return std.mem.eql(u8, name_text, "media") or
            std.mem.eql(u8, name_text, "supports") or
            std.mem.eql(u8, name_text, "charset") or
            std.mem.eql(u8, name_text, "-moz-document");
    }

    /// Consume a `.string` token and return its interned content
    /// (surrounding quotes stripped).  Used by @use / @forward /
    /// @import which accept only quoted-string URLs.
    fn parseStringUrl(self: *Parser) ParseError!InternId {
        if (self.isAtEnd() or self.current().tag != .string) return error.SyntaxError;
        const tok = self.current();
        self.advance();

        const text = tok.slice(self.source);
        var content: []const u8 = text;
        if (text.len >= 2 and
            (text[0] == '"' or text[0] == '\'') and
            text[text.len - 1] == text[0])
        {
            content = text[1 .. text.len - 1];
        }
        return try self.intern_pool.intern(content);
    }

    /// Parse a `with ($var1: expr, $var2: expr !default, ...)` configuration
    /// clause.
    ///
    /// Extra layout:
    /// `[count,
    ///   var_id_0, expr_node_0, flags_0,
    ///   var_id_1, expr_node_1, flags_1,
    ///   ...]`
    ///
    /// flags bit 0: `!default`
    fn parseWithConfig(self: *Parser, ast: *Ast) ParseError!ExtraIndex {
        if (self.isAtEnd() or self.current().tag != .lparen) return error.SyntaxError;
        self.advance();
        self.skipWhitespaceAndComments();

        var entries: std.ArrayListUnmanaged(u32) = .empty;
        defer entries.deinit(self.allocator);
        var count: u32 = 0;

        while (!self.isAtEnd()) {
            if (self.current().tag == .rparen) {
                self.advance();
                break;
            }
            if (self.current().tag != .dollar_ident) return error.SyntaxError;

            const name_tok = self.current();
            const name_text = name_tok.slice(self.source);
            if (name_text.len <= 1) return error.SyntaxError;
            const name_id = try self.intern_pool.intern(name_text[1..]);
            self.advance();

            self.skipWhitespaceAndComments();
            if (self.isAtEnd() or self.current().tag != .colon) return error.SyntaxError;
            self.advance();
            self.skipWhitespaceAndComments();

            const value_node = try self.parseSpaceListOrSingle(ast);

            var flags: u32 = 0;
            while (true) {
                self.skipWhitespaceAndComments();
                if (self.isAtEnd() or self.current().tag != .bang) break;
                const saved = self.pos;
                self.advance();
                self.skipWhitespaceAndComments();
                if (self.isAtEnd() or self.current().tag != .ident) {
                    self.pos = saved;
                    break;
                }
                const flag_text = self.current().slice(self.source);
                if (std.mem.eql(u8, flag_text, "default")) {
                    flags |= 0b0000_0001;
                    self.advance();
                    continue;
                }
                self.pos = saved;
                break;
            }

            try entries.append(self.allocator, @intFromEnum(name_id));
            try entries.append(self.allocator, value_node.toU32());
            try entries.append(self.allocator, flags);
            count += 1;

            self.skipWhitespaceAndComments();
            if (self.isAtEnd()) return error.SyntaxError;
            if (self.current().tag == .comma) {
                self.advance();
                self.skipWhitespaceAndComments();
                if (!self.isAtEnd() and self.current().tag == .rparen) {
                    self.advance();
                    break;
                }
                continue;
            }
            if (self.current().tag == .rparen) {
                self.advance();
                break;
            }
            return error.SyntaxError;
        }

        const extra_off = try ast.appendExtraU32(count);
        for (entries.items) |entry| {
            _ = try ast.appendExtraU32(entry);
        }
        return extra_off;
    }

    /// Parse a `show` / `hide` list: comma-separated identifiers or
    /// `$variable` references.  Variables are interned **with** their
    /// leading `$` so the resolver can distinguish them from
    /// function/mixin names.  Returns an `ExtraIndex` pointing at a
    /// `[count, id_0, ..., id_{N-1}]` block.
    fn parseShowHideList(self: *Parser, ast: *Ast) ParseError!ExtraIndex {
        var ids: std.ArrayListUnmanaged(InternId) = .empty;
        defer ids.deinit(self.allocator);

        self.skipWhitespaceAndComments();
        while (!self.isAtEnd()) {
            const tok = self.current();
            var item_line_start: u32 = 0;
            if (tok.tag == .dollar_ident or tok.tag == .ident) {
                const id = try self.intern_pool.intern(tok.slice(self.source));
                try ids.append(self.allocator, id);
                item_line_start = self.lineStartAtByte(tok.span.start);
                self.advance();
            } else {
                break;
            }
            self.skipWhitespaceAndComments();
            if (!self.isAtEnd() and self.current().tag == .comma) {
                if (self.is_indented_syntax and
                    self.lineStartAtByte(self.current().span.start) > item_line_start)
                {
                    return error.SyntaxError;
                }
                self.advance();
                self.skipWhitespaceAndComments();
                continue;
            }
            break;
        }

        const extra_off = try ast.appendExtraU32(@intCast(ids.items.len));
        for (ids.items) |id| {
            _ = try ast.appendExtraU32(@intFromEnum(id));
        }
        return extra_off;
    }

    // -- @use / @forward / @import / @content (R.2c.5) ------------------------

    /// Parse `@use "url" [as ident|*] [with (...)] [;]`.
    ///
    /// Extra layout: `[url_id, namespace_id, config_extra_or_none]`.
    /// flags bit 0: `as_star` (the `as *` form).
    /// `config_extra_or_none` = u32.max when there is no `with`.
    fn parseUseRule(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const at_tok = self.current();
        std.debug.assert(at_tok.tag == .at_use);
        self.advance();
        self.skipWhitespaceAndComments();

        const url_id = try self.parseStringUrl();
        var end_pos: u32 = self.tokens[self.pos - 1].span.end;

        self.skipWhitespaceAndComments();
        if (self.currentTokenStartsIndentedBodyAfterHeader(at_tok.span.start) and
            !self.isAtEnd() and self.current().tag == .ident)
        {
            const text = self.current().slice(self.source);
            if (std.mem.eql(u8, text, "as") or std.mem.eql(u8, text, "with")) {
                return error.SyntaxError;
            }
        }

        var namespace_id: InternId = .none;
        var as_star = false;
        if (!self.isAtEnd() and self.current().tag == .ident and
            std.mem.eql(u8, self.current().slice(self.source), "as"))
        {
            self.advance();
            self.skipWhitespaceAndComments();
            if (self.isAtEnd()) return error.SyntaxError;
            const c = self.current();
            if (c.tag == .star) {
                as_star = true;
                self.advance();
                end_pos = c.span.end;
            } else if (c.tag == .ident) {
                namespace_id = try self.intern_pool.intern(c.slice(self.source));
                self.advance();
                end_pos = c.span.end;
            } else {
                return error.SyntaxError;
            }
            self.skipWhitespaceAndComments();
        }

        var config_extra: u32 = std.math.maxInt(u32);
        if (!self.isAtEnd() and self.current().tag == .ident and
            std.mem.eql(u8, self.current().slice(self.source), "with"))
        {
            self.advance();
            self.skipWhitespaceAndComments();
            config_extra = try self.parseWithConfig(ast);
            end_pos = self.tokens[self.pos - 1].span.end;
            self.skipWhitespaceAndComments();
        }

        if (self.currentTokenStartsIndentedBodyAfterHeader(at_tok.span.start)) {
            return error.SyntaxError;
        }

        if (!self.isAtEnd() and self.current().tag == .semicolon) {
            end_pos = self.current().span.end;
            self.advance();
        }

        const outer_off = try ast.appendExtraU32(@intFromEnum(url_id));
        _ = try ast.appendExtraU32(@intFromEnum(namespace_id));
        _ = try ast.appendExtraU32(config_extra);

        var flags: u8 = 0;
        if (as_star) flags |= 0b0000_0001;

        return try ast.addNode(.{
            .tag = .stmt_use,
            .flags = flags,
            .payload = outer_off,
            .span_start = at_tok.span.start,
            .span_end = end_pos,
        });
    }

    /// Parse `@forward "url" [as prefix-*] [show ...] [hide ...] [with (...)] [;]`.
    ///
    /// Extra layout:
    /// `[url_id, prefix_id, show_extra_or_none, hide_extra_or_none,
    ///   config_extra_or_none]`
    ///
    /// All of `prefix_id`, `show_extra`, `hide_extra`, and
    /// `config_extra` are `u32.max` (alias `.none` for InternId when
    /// applicable) when the corresponding clause is absent.
    fn parseForwardRule(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const at_tok = self.current();
        std.debug.assert(at_tok.tag == .at_forward);
        self.advance();
        self.skipWhitespaceAndComments();

        const url_id = try self.parseStringUrl();
        var end_pos: u32 = self.tokens[self.pos - 1].span.end;
        self.skipWhitespaceAndComments();

        var prefix_id: InternId = .none;
        var show_extra: u32 = std.math.maxInt(u32);
        var hide_extra: u32 = std.math.maxInt(u32);
        var config_extra: u32 = std.math.maxInt(u32);

        clauses: while (!self.isAtEnd()) {
            if (self.current().tag != .ident) break :clauses;
            const text = self.current().slice(self.source);
            if (self.currentTokenStartsIndentedBodyAfterHeader(at_tok.span.start) and
                (std.mem.eql(u8, text, "as") or
                    std.mem.eql(u8, text, "show") or
                    std.mem.eql(u8, text, "hide") or
                    std.mem.eql(u8, text, "with")))
            {
                return error.SyntaxError;
            }

            if (std.mem.eql(u8, text, "as")) {
                self.advance();
                self.skipWhitespaceAndComments();
                // Collect the `prefix-` portion as a raw source slice
                // stopping at `*`.
                if (self.isAtEnd()) return error.SyntaxError;
                const pref_start = self.current().span.start;
                while (!self.isAtEnd()) {
                    const t = self.current().tag;
                    if (t == .star) break;
                    if (t == .whitespace or t == .newline or t == .comment) break;
                    self.advance();
                }
                if (self.isAtEnd() or self.current().tag != .star) return error.SyntaxError;
                const pref_end = self.current().span.start;
                if (pref_end > pref_start) {
                    prefix_id = try self.intern_pool.intern(self.source[pref_start..pref_end]);
                }
                end_pos = self.current().span.end;
                self.advance(); // consume *
                self.skipWhitespaceAndComments();
                continue :clauses;
            }

            if (std.mem.eql(u8, text, "show")) {
                self.advance();
                self.skipWhitespaceAndComments();
                show_extra = try self.parseShowHideList(ast);
                end_pos = self.tokens[self.pos - 1].span.end;
                self.skipWhitespaceAndComments();
                continue :clauses;
            }

            if (std.mem.eql(u8, text, "hide")) {
                self.advance();
                self.skipWhitespaceAndComments();
                hide_extra = try self.parseShowHideList(ast);
                end_pos = self.tokens[self.pos - 1].span.end;
                self.skipWhitespaceAndComments();
                continue :clauses;
            }

            if (std.mem.eql(u8, text, "with")) {
                self.advance();
                self.skipWhitespaceAndComments();
                config_extra = try self.parseWithConfig(ast);
                end_pos = self.tokens[self.pos - 1].span.end;
                self.skipWhitespaceAndComments();
                continue :clauses;
            }

            break :clauses;
        }

        if (self.currentTokenStartsIndentedBodyAfterHeader(at_tok.span.start)) {
            return error.SyntaxError;
        }

        if (!self.isAtEnd() and self.current().tag == .semicolon) {
            end_pos = self.current().span.end;
            self.advance();
        }

        const outer_off = try ast.appendExtraU32(@intFromEnum(url_id));
        _ = try ast.appendExtraU32(@intFromEnum(prefix_id));
        _ = try ast.appendExtraU32(show_extra);
        _ = try ast.appendExtraU32(hide_extra);
        _ = try ast.appendExtraU32(config_extra);

        return try ast.addNode(.{
            .tag = .stmt_forward,
            .flags = 0,
            .payload = outer_off,
            .span_start = at_tok.span.start,
            .span_end = end_pos,
        });
    }

    /// Parse `@import <url> [conditions] [, <url2> [conditions2]]... [;]`.
    ///
    /// Supports:
    /// * quoted string URLs (`@import "foo"`) -- url node covers the full
    ///     quoted token text.
    /// * functional `url(...)` form -- url node covers the full `url(...)`
    ///     token run.
    ///   * trailing media / supports conditions after the URL (CSS-only form).
    /// * comma-separated multi-URL lists -- the first import is returned as
    ///     the caller's NodeIndex and any extras are pushed onto
    ///     `self.pending_statements` to be drained by the parse loop.
    ///
    /// Extra layout:
    ///   `[url_node, cond_node_or_max]`
    fn parseImportRule(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const at_tok = self.current();
        std.debug.assert(at_tok.tag == .at_import);
        const at_start = at_tok.span.start;
        self.advance();
        self.skipWhitespaceAndComments();
        if (self.currentTokenStartsIndentedBodyAfterHeader(at_start)) {
            return error.SyntaxError;
        }

        const first = try self.parseOneImportEntry(ast, at_start);
        var last_end = first.node_end;
        const first_node = try self.emitImportNode(ast, first);

        // Handle comma-separated additional imports.
        while (!self.isAtEnd() and self.current().tag == .comma) {
            if (!self.nextNonTriviaIsImportUrl(self.pos + 1)) break;
            self.advance(); // consume comma
            self.skipWhitespaceAndComments();
            if (self.isAtEnd() or self.current().tag == .semicolon or self.current().tag == .rbrace) break;
            const entry = try self.parseOneImportEntry(ast, at_start);
            last_end = entry.node_end;
            const extra_node = try self.emitImportNode(ast, entry);
            try self.pending_statements.append(self.allocator, extra_node);
            self.had_multi_import = true;
        }

        if (!self.isAtEnd() and self.current().tag == .semicolon) {
            last_end = self.current().span.end;
            self.advance();
        }

        // Patch the first node's span_end to cover the terminator.
        ast.setSpanEnd(first_node, last_end);
        for (self.pending_statements.items) |n| ast.setSpanEnd(n, last_end);
        return first_node;
    }

    const ImportEntry = struct {
        node_start: u32,
        node_end: u32,
        url_start_idx: usize,
        url_end_idx: usize,
        cond_start_idx: ?usize,
        cond_end_idx: usize,
        cond_last_sig_idx: ?usize,
    };

    /// Parse one URL + optional conditions pair (shared between the leading
    /// import and any multi-URL extras). Does NOT emit the node -- the caller
    /// uses `emitImportNode` so it can distinguish primary / pending nodes.
    fn parseOneImportEntry(self: *Parser, ast: *Ast, stmt_start: u32) ParseError!ImportEntry {
        _ = ast;
        self.skipWhitespaceAndComments();
        if (self.isAtEnd()) return error.UnexpectedEof;

        var entry_end: u32 = 0;
        const url_start_idx = self.pos;
        var url_end_idx = self.pos;

        const tok = self.current();
        if (tok.tag == .string) {
            entry_end = tok.span.end;
            self.advance();
            url_end_idx = self.pos;
        } else if (tok.tag == .ident and std.ascii.eqlIgnoreCase(tok.slice(self.source), "url")) {
            // `url(...)` functional form -- consume balanced parens.
            const next_pos = self.pos + 1;
            if (next_pos >= self.tokens.len or self.tokens[next_pos].tag != .lparen) {
                return error.SyntaxError;
            }
            self.advance(); // skip `url`
            var url_end: u32 = 0;
            entry_end = try self.consumeBalancedParens(&url_end);
            url_end_idx = self.pos;
        } else if (tok.tag == .ident or (self.is_indented_syntax and tok.tag == .tilde)) {
            // Unquoted CSS import target (`@import other.css`), accepted in
            // indented syntax and normalized by the evaluator.  Indented Sass
            // also accepts unquoted Sass import paths, including bundler-style
            // tilde prefixes (`@import ~pkg/path`).
            //
            // Capture one contiguous non-trivia token run and require it to
            // end with `.css` (case-insensitive), so Sass imports like
            // `@import other` still route through the Sass-only path.
            var run_end = tok.span.end;
            self.advance();
            while (!self.isAtEnd()) {
                const ct = self.current().tag;
                if (ct == .whitespace or ct == .newline or ct == .comment or
                    ct == .semicolon or ct == .rbrace or ct == .eof or ct == .comma)
                {
                    break;
                }
                run_end = self.current().span.end;
                self.advance();
            }
            url_end_idx = self.pos;
            const run = self.source[tok.span.start..run_end];
            const is_css_import = run.len >= 4 and std.ascii.eqlIgnoreCase(run[run.len - 4 ..], ".css");
            if (!is_css_import and !self.is_indented_syntax) {
                return error.SyntaxError;
            }
            entry_end = run_end;
        } else {
            return error.SyntaxError;
        }

        if (self.is_indented_syntax)
            self.skipInlineWhitespaceAndComments()
        else
            self.skipWhitespaceAndComments();

        // Optional conditions / media query list up to `;` / `}` / comma-that-
        // starts-new-import.
        var cond_start_idx: ?usize = null;
        var cond_end_idx: usize = self.pos;
        var cond_last_sig_idx: ?usize = null;
        if (!self.isAtEnd()) {
            const c = self.current().tag;
            if (c != .semicolon and c != .rbrace and c != .eof and
                !(c == .comma and self.nextNonTriviaIsImportUrl(self.pos + 1)))
            {
                cond_start_idx = self.pos;
                var cur_end = self.current().span.start;
                var paren_depth: u32 = 0;
                var brace_depth: u32 = 0;
                var interp_depth: u32 = 0;
                while (!self.isAtEnd()) {
                    const ct = self.current().tag;
                    if (self.is_indented_syntax and paren_depth == 0 and brace_depth == 0 and interp_depth == 0 and
                        ct == .newline)
                    {
                        break;
                    }
                    if (paren_depth == 0 and brace_depth == 0 and interp_depth == 0 and
                        (ct == .semicolon or ct == .rbrace or ct == .eof)) break;
                    if (ct == .comma and paren_depth == 0 and brace_depth == 0 and
                        interp_depth == 0)
                    {
                        if (self.nextNonTriviaIsImportUrl(self.pos + 1)) break;
                    }
                    if (ct == .hash_lbrace) {
                        interp_depth += 1;
                    } else if (ct == .rbrace) {
                        if (interp_depth > 0) {
                            interp_depth -= 1;
                        } else if (brace_depth > 0) {
                            brace_depth -= 1;
                        } else break;
                    } else if (ct == .lbrace) {
                        // Literal `{` inside conditions (e.g. inside a
                        // CSS unknown function's arg list) is allowed
                        // at paren_depth > 0 -- treat it as a balanced
                        // brace run rather than a block starter.
                        if (paren_depth > 0) brace_depth += 1 else break;
                    } else if (ct == .lparen) {
                        paren_depth += 1;
                    } else if (ct == .rparen) {
                        if (paren_depth > 0) paren_depth -= 1;
                    }
                    if (ct != .whitespace and ct != .newline and ct != .comment) {
                        cond_last_sig_idx = self.pos;
                        cur_end = self.current().span.end;
                    }
                    self.advance();
                }
                cond_end_idx = self.pos;
                if (cond_last_sig_idx != null) {
                    entry_end = @max(entry_end, cur_end);
                }
            }
        }
        if (self.is_indented_syntax and cond_last_sig_idx == null and self.nextSignificantTokenStartsIndentedBodyAfterHeader(stmt_start)) {
            return error.SyntaxError;
        }

        return .{
            .node_start = stmt_start,
            .node_end = entry_end,
            .url_start_idx = url_start_idx,
            .url_end_idx = url_end_idx,
            .cond_start_idx = cond_start_idx,
            .cond_end_idx = cond_end_idx,
            .cond_last_sig_idx = cond_last_sig_idx,
        };
    }

    fn emitImportNode(self: *Parser, ast: *Ast, entry: ImportEntry) ParseError!NodeIndex {
        const url_node = (try self.emitUnquotedTextExprFromTokenRange(
            ast,
            entry.url_start_idx,
            entry.url_end_idx,
            if (entry.url_end_idx > entry.url_start_idx) entry.url_end_idx - 1 else null,
            true,
            false,
            0,
        )) orelse return error.SyntaxError;
        const cond_slot: u32 = if (entry.cond_start_idx) |cond_start_idx| blk: {
            const cond_node = try self.emitUnquotedTextExprFromTokenRange(
                ast,
                cond_start_idx,
                entry.cond_end_idx,
                entry.cond_last_sig_idx,
                true,
                false,
                0,
            );
            break :blk if (cond_node) |cn| cn.toU32() else std.math.maxInt(u32);
        } else std.math.maxInt(u32);
        const outer_off = try ast.appendExtraU32(url_node.toU32());
        _ = try ast.appendExtraU32(cond_slot);
        return try ast.addNode(.{
            .tag = .stmt_import,
            .flags = 0,
            .payload = outer_off,
            .span_start = entry.node_start,
            .span_end = entry.node_end,
        });
    }

    /// Consume `( ... )` starting at the current token (which must be `lparen`
    /// or immediately followed by `lparen`).  Writes the end position of the
    /// full `url(...)` run into `url_end_out` and returns the same value as
    /// the entry end.  Tracks nested parens, quoted strings, and `#{...}`.
    fn consumeBalancedParens(self: *Parser, url_end_out: *u32) ParseError!u32 {
        if (self.isAtEnd() or self.current().tag != .lparen) return error.SyntaxError;
        var depth: u32 = 0;
        var last_end: u32 = self.current().span.end;
        while (!self.isAtEnd()) {
            const tok = self.current();
            switch (tok.tag) {
                .lparen => depth += 1,
                .rparen => {
                    depth -= 1;
                    last_end = tok.span.end;
                    self.advance();
                    if (depth == 0) {
                        url_end_out.* = last_end;
                        return last_end;
                    }
                    continue;
                },
                else => {},
            }
            if (tok.tag != .whitespace and tok.tag != .newline and tok.tag != .comment) {
                last_end = tok.span.end;
            }
            self.advance();
        }
        return error.SyntaxError;
    }

    /// Does the token stream starting at `start_pos` begin with an import URL
    /// (after trivia)?  Used by the import parser to decide whether a comma
    /// introduces a new URL or belongs to a media-query list.
    fn nextNonTriviaIsImportUrl(self: *Parser, start_pos: usize) bool {
        var p = start_pos;
        while (p < self.tokens.len) {
            const t = self.tokens[p].tag;
            if (t == .whitespace or t == .newline or t == .comment) {
                p += 1;
                continue;
            }
            break;
        }
        if (p >= self.tokens.len) return false;
        const t = self.tokens[p].tag;
        if (t == .string) return true;
        if (t == .ident) {
            const text = self.tokens[p].span.slice(self.source);
            if (std.ascii.eqlIgnoreCase(text, "url")) {
                const next = p + 1;
                if (next < self.tokens.len and self.tokens[next].tag == .lparen) return true;
            }
            if (self.is_indented_syntax) return true;
        }
        return false;
    }

    /// Parse `@content [(args)] [;]`.
    ///
    /// Extra layout: `[arg_count, arg_node_0..{N-1}, arg_name_id_0..{N-1}]`.
    /// When there is no `(...)` clause the layout is just `[0]`.
    fn parseContentRule(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const at_tok = self.current();
        std.debug.assert(at_tok.tag == .at_content);
        self.advance();
        var end_pos: u32 = at_tok.span.end;
        self.skipWhitespaceAndComments();

        var arg_nodes: std.ArrayListUnmanaged(NodeIndex) = .empty;
        defer arg_nodes.deinit(self.allocator);
        var arg_names: std.ArrayListUnmanaged(InternId) = .empty;
        defer arg_names.deinit(self.allocator);

        if (!self.isAtEnd() and self.current().tag == .lparen) {
            var rp_end: u32 = 0;
            try self.parseCallArgsListRaw(ast, &arg_nodes, &arg_names, &rp_end, false, false);
            end_pos = rp_end;
            self.skipWhitespaceAndComments();
        }

        if (!self.isAtEnd() and self.current().tag == .semicolon) {
            end_pos = self.current().span.end;
            self.advance();
        }

        const extra_off = try ast.appendExtraU32(@intCast(arg_nodes.items.len));
        for (arg_nodes.items) |n| {
            _ = try ast.appendExtraU32(n.toU32());
        }
        for (arg_names.items) |id| {
            _ = try ast.appendExtraU32(@intFromEnum(id));
        }

        return try ast.addNode(.{
            .tag = .stmt_content,
            .flags = 0,
            .payload = extra_off,
            .span_start = at_tok.span.start,
            .span_end = end_pos,
        });
    }

    // -- block body helper (used by control flow + future block stmts) -------

    const BlockBodyResult = struct {
        /// Offset in `ast.extra` at which the child list begins.
        /// Layout: `[child_count: u32, child_idx_0, ..., child_idx_{N-1}]`.
        extra: ExtraIndex,
        /// Byte position just past the closing `}`.
        span_end: u32,
    };

    /// Parse `{ ... }` where the children are zero or more top-level
    /// statements.  On entry, `self.pos` must index `.lbrace`.  Returns
    /// an extra-pool offset pointing at a len-prefixed NodeIndex list.
    fn parseBlockBody(self: *Parser, ast: *Ast) ParseError!BlockBodyResult {
        if (!self.isAtEnd() and self.current().tag == .lbrace) {
            if (self.is_indented_syntax) return error.SyntaxError;
            return self.parseBraceBlockBody(ast);
        }
        return self.parseIndentedBlockBody(ast);
    }

    /// Same as `parseBlockBody`, but with indented syntax body judgment
    /// Anchor to the line indentation of `header_start`.
    fn parseBlockBodyAnchored(self: *Parser, ast: *Ast, header_start: u32) ParseError!BlockBodyResult {
        if (!self.isAtEnd() and self.current().tag == .lbrace) {
            if (self.is_indented_syntax) return error.SyntaxError;
            return self.parseBraceBlockBody(ast);
        }
        return self.parseIndentedBlockBodyWithAnchor(ast, header_start);
    }

    fn parseBraceBlockBody(self: *Parser, ast: *Ast) ParseError!BlockBodyResult {
        std.debug.assert(!self.isAtEnd() and self.current().tag == .lbrace);
        self.advance(); // skip {

        var children: std.ArrayListUnmanaged(NodeIndex) = .empty;
        defer children.deinit(self.allocator);

        while (true) {
            self.skipTrivia();
            if (self.isAtEnd()) return error.SyntaxError;
            if (self.current().tag == .rbrace) break;
            while (!self.isAtEnd() and self.current().tag == .semicolon) {
                self.advance();
                self.skipTrivia();
            }
            if (self.isAtEnd()) return error.SyntaxError;
            if (self.current().tag == .rbrace) break;

            const stmt = try self.parseStatement(ast);
            try children.ensureUnusedCapacity(self.allocator, 1 + self.pending_statements.items.len);
            children.appendAssumeCapacity(stmt);
            for (self.pending_statements.items) |extra| {
                children.appendAssumeCapacity(extra);
            }
            self.pending_statements.clearRetainingCapacity();
        }

        std.debug.assert(self.current().tag == .rbrace);
        const close_end = self.current().span.end;
        self.advance(); // skip }

        const extra_off = try ast.appendExtraU32(@intCast(children.items.len));
        for (children.items) |c| {
            _ = try ast.appendExtraU32(c.toU32());
        }
        return .{ .extra = extra_off, .span_end = close_end };
    }

    /// Parse a `.sass` indented body.
    ///
    /// Behavior:
    ///   * first statement line must be on a later line and indented deeper
    ///     than the header line
    ///   * block ends on dedent (indent < first statement indent)
    ///   * when no indented statement follows, body is empty
    fn parseIndentedBlockBody(self: *Parser, ast: *Ast) ParseError!BlockBodyResult {
        return self.parseIndentedBlockBodyWithAnchor(ast, null);
    }

    fn parseIndentedBlockBodyWithAnchor(
        self: *Parser,
        ast: *Ast,
        header_anchor: ?u32,
    ) ParseError!BlockBodyResult {
        var children: std.ArrayListUnmanaged(NodeIndex) = .empty;
        defer children.deinit(self.allocator);

        const header_idx = self.prevSignificantTokenIndex(self.pos);
        const header_point = header_anchor orelse if (header_idx) |idx| self.tokens[idx].span.start else 0;
        const header_indent: u32 = self.lineIndentAtByte(header_point);
        const header_line_start: u32 = self.lineStartAtByte(header_point);

        var body_indent: u32 = 0;
        var have_body_indent = false;
        var end_pos: u32 = if (header_idx) |idx| self.tokens[idx].span.end else 0;

        while (true) {
            self.skipTrivia();
            if (self.isAtEnd()) break;
            if (self.current().tag == .rbrace) break;
            while (!self.isAtEnd() and self.current().tag == .semicolon) {
                self.advance();
                self.skipTrivia();
            }
            if (self.isAtEnd()) break;
            if (self.current().tag == .rbrace) break;

            const cur_tok = self.current();
            const cur_indent = self.lineIndentAtByte(cur_tok.span.start);
            const cur_line_start = self.lineStartAtByte(cur_tok.span.start);

            if (!have_body_indent) {
                if (cur_line_start <= header_line_start) {
                    // Same-line token after a block-introducing statement is
                    // still a hard syntax error (`@if $x color: red`).
                    return error.SyntaxError;
                }
                if (cur_indent <= header_indent) {
                    // No indented children => empty body.
                    break;
                }
                body_indent = cur_indent;
                have_body_indent = true;
            } else if (cur_indent < body_indent) {
                break;
            } else if (cur_indent <= body_indent and cur_tok.tag == .at_else) {
                break;
            }

            const stmt = try self.parseStatement(ast);
            try children.ensureUnusedCapacity(self.allocator, 1 + self.pending_statements.items.len);
            children.appendAssumeCapacity(stmt);
            end_pos = @max(end_pos, ast.getNode(stmt).span_end);
            for (self.pending_statements.items) |extra| {
                children.appendAssumeCapacity(extra);
                end_pos = @max(end_pos, ast.getNode(extra).span_end);
            }
            self.pending_statements.clearRetainingCapacity();
        }

        const extra_off = try ast.appendExtraU32(@intCast(children.items.len));
        for (children.items) |c| {
            _ = try ast.appendExtraU32(c.toU32());
        }
        return .{ .extra = extra_off, .span_end = end_pos };
    }

    fn prevSignificantTokenIndex(self: *const Parser, from: usize) ?usize {
        var i = from;
        while (i > 0) {
            i -= 1;
            const t = self.tokens[i].tag;
            if (t != .whitespace and t != .newline and t != .comment) return i;
        }
        return null;
    }

    fn lineStartAtByte(self: *const Parser, byte_pos: u32) u32 {
        return token_mod.lineStartAtByte(self.source, byte_pos);
    }

    fn lineIndentAtByte(self: *const Parser, byte_pos: u32) u32 {
        return token_mod.lineIndentAtByte(self.source, byte_pos);
    }

    /// Does `self.current()` start an indented child block of the statement
    /// whose header starts at `header_start`?
    fn startsIndentedBodyAfterHeader(self: *const Parser, header_start: u32) bool {
        if (self.pos >= self.tokens.len) return false;
        const tok = self.tokens[self.pos];
        if (tok.tag == .semicolon or tok.tag == .rbrace or tok.tag == .eof) return false;

        const header_line_start = self.lineStartAtByte(header_start);
        const header_indent = self.lineIndentAtByte(header_start);
        const tok_line_start = self.lineStartAtByte(tok.span.start);
        if (tok_line_start <= header_line_start) return false;
        const tok_indent = self.lineIndentAtByte(tok.span.start);
        return tok_indent > header_indent;
    }

    fn currentTokenStartsIndentedBodyAfterHeader(self: *const Parser, header_start: u32) bool {
        return self.is_indented_syntax and self.startsIndentedBodyAfterHeader(header_start);
    }

    fn nextSignificantTokenStartsIndentedBodyAfterHeader(self: *const Parser, header_start: u32) bool {
        if (!self.is_indented_syntax) return false;
        var copy = self.*;
        while (copy.pos < copy.tokens.len) {
            const t = copy.tokens[copy.pos].tag;
            if (t == .whitespace or t == .newline or t == .comment) {
                copy.pos += 1;
                continue;
            }
            break;
        }
        return copy.startsIndentedBodyAfterHeader(header_start);
    }

    // -- control flow statements (R.2c.4) ------------------------------------

    /// Parse `@if cond { body } (@else if cond2 { body })* (@else { body })?`.
    ///
    /// Legacy `@elseif` (single at-keyword) is accepted alongside the
    /// canonical `@else if` (two tokens).
    ///
    /// extra layout:
    ///   [cond_node: u32,
    ///    then_body_extra: ExtraIndex,
    ///    elseif_count: u32,
    /// (elseif_cond: u32, elseif_body_extra: ExtraIndex) x elseif_count,
    ///    else_body_extra: ExtraIndex  (u32 max = no else clause)]
    fn parseIfRule(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const at_tok = self.current();
        std.debug.assert(at_tok.tag == .at_if);
        self.advance(); // skip @if
        self.skipWhitespaceAndComments();

        const cond_node = if (self.is_indented_syntax)
            try self.parseIndentedHeaderExpr(ast)
        else
            try self.parseExpression(ast);
        self.skipWhitespaceAndComments();
        const then_body = try self.parseBlockBodyAnchored(ast, at_tok.span.start);

        var elseif_conds: std.ArrayListUnmanaged(NodeIndex) = .empty;
        defer elseif_conds.deinit(self.allocator);
        var elseif_bodies: std.ArrayListUnmanaged(ExtraIndex) = .empty;
        defer elseif_bodies.deinit(self.allocator);

        var else_body_extra: ?ExtraIndex = null;
        var end_pos: u32 = then_body.span_end;

        chain: while (true) {
            const save_pos = self.pos;
            self.skipWhitespaceAndComments();
            if (self.isAtEnd()) {
                self.pos = save_pos;
                break :chain;
            }
            const cur = self.current();

            if (self.is_indented_syntax and self.lineIndentAtByte(cur.span.start) != self.lineIndentAtByte(at_tok.span.start)) {
                self.pos = save_pos;
                break :chain;
            }

            if (cur.tag == .at_else) {
                self.advance(); // skip @else
                self.skipWhitespaceAndComments();
                if (!self.isAtEnd() and self.current().tag == .ident and
                    std.mem.eql(u8, self.current().slice(self.source), "if"))
                {
                    self.advance(); // consume `if`
                    self.skipWhitespaceAndComments();
                    const ec = if (self.is_indented_syntax)
                        try self.parseIndentedHeaderExpr(ast)
                    else
                        try self.parseExpression(ast);
                    self.skipWhitespaceAndComments();
                    const eb = try self.parseBlockBodyAnchored(ast, cur.span.start);
                    try elseif_conds.append(self.allocator, ec);
                    try elseif_bodies.append(self.allocator, eb.extra);
                    end_pos = eb.span_end;
                    continue :chain;
                }
                // Bare `@else { ... }` -- no more chain after this.
                self.skipWhitespaceAndComments();
                const eb = try self.parseBlockBodyAnchored(ast, cur.span.start);
                else_body_extra = eb.extra;
                end_pos = eb.span_end;
                break :chain;
            }

            // Legacy `@elseif` as a single at-keyword.
            if (cur.tag == .at_keyword and
                std.mem.eql(u8, cur.slice(self.source), "@elseif"))
            {
                self.advance();
                self.skipWhitespaceAndComments();
                const ec = if (self.is_indented_syntax)
                    try self.parseIndentedHeaderExpr(ast)
                else
                    try self.parseExpression(ast);
                self.skipWhitespaceAndComments();
                const eb = try self.parseBlockBodyAnchored(ast, cur.span.start);
                try elseif_conds.append(self.allocator, ec);
                try elseif_bodies.append(self.allocator, eb.extra);
                end_pos = eb.span_end;
                continue :chain;
            }

            // Anything else terminates the chain -- rewind past any
            // trivia we consumed so the outer loop can see it.
            self.pos = save_pos;
            break :chain;
        }

        const extra_off = try ast.appendExtraU32(cond_node.toU32());
        _ = try ast.appendExtraU32(then_body.extra);
        _ = try ast.appendExtraU32(@intCast(elseif_conds.items.len));
        for (elseif_conds.items, elseif_bodies.items) |c, b| {
            _ = try ast.appendExtraU32(c.toU32());
            _ = try ast.appendExtraU32(b);
        }
        _ = try ast.appendExtraU32(else_body_extra orelse std.math.maxInt(u32));

        return try ast.addNode(.{
            .tag = .stmt_if,
            .flags = 0,
            .payload = extra_off,
            .span_start = at_tok.span.start,
            .span_end = end_pos,
        });
    }

    /// Parse `@each $var [, $var2, ...] in list_expr { body }`.
    ///
    /// extra layout:
    ///   [var_count: u32,
    ///    var_id_0: InternId, ..., var_id_{N-1}: InternId,
    ///    list_node: u32,
    ///    body_extra: ExtraIndex]
    fn parseEachRule(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const at_tok = self.current();
        std.debug.assert(at_tok.tag == .at_each);
        self.advance(); // skip @each
        self.skipWhitespaceAndComments();

        // Collect comma-separated `$var` tokens until `in` ident.
        var vars: std.ArrayListUnmanaged(InternId) = .empty;
        defer vars.deinit(self.allocator);

        while (true) {
            if (self.isAtEnd() or self.current().tag != .dollar_ident) {
                return error.SyntaxError;
            }
            const v_tok = self.current();
            const v_text = v_tok.slice(self.source);
            std.debug.assert(v_text.len >= 1 and v_text[0] == '$');
            try vars.append(self.allocator, try self.intern_pool.intern(v_text[1..]));
            self.advance();
            self.skipWhitespaceAndComments();
            if (!self.isAtEnd() and self.current().tag == .comma) {
                self.advance();
                self.skipWhitespaceAndComments();
                continue;
            }
            break;
        }

        // Expect the `in` keyword.
        if (self.isAtEnd() or self.current().tag != .ident or
            !std.mem.eql(u8, self.current().slice(self.source), "in"))
        {
            return error.SyntaxError;
        }
        self.advance(); // skip `in`
        self.skipWhitespaceAndComments();

        const list_node = try self.parseEachListExpr(ast);
        self.skipWhitespaceAndComments();
        // To allow `.sass` multiline header, set the base line of indented body to
        // Fix `@each` to its own line.
        const body = try self.parseBlockBodyAnchored(ast, at_tok.span.start);

        const extra_off = try ast.appendExtraU32(@intCast(vars.items.len));
        for (vars.items) |id| {
            _ = try ast.appendExtraU32(@intFromEnum(id));
        }
        _ = try ast.appendExtraU32(list_node.toU32());
        _ = try ast.appendExtraU32(body.extra);

        return try ast.addNode(.{
            .tag = .stmt_each,
            .flags = 0,
            .payload = extra_off,
            .span_start = at_tok.span.start,
            .span_end = body.span_end,
        });
    }

    fn parseEachListExpr(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        if (!self.is_indented_syntax) {
            const value_start_pos = self.pos;
            const block_pos = self.findEachBlockStart(value_start_pos) orelse return self.parseExpression(ast);
            var expr_limit = block_pos;
            if (self.prevSignificantTokenIndex(block_pos)) |prev_sig| {
                if (prev_sig >= value_start_pos and self.tokens[prev_sig].tag == .comma) {
                    expr_limit = prev_sig;
                }
            }
            if (expr_limit <= value_start_pos) return error.SyntaxError;

            var sub = self.createSubParser(self.tokens[value_start_pos..expr_limit]);
            defer sub.deinit();

            const node = try sub.parseExpression(ast);
            self.pos = block_pos;
            return node;
        }

        const value_start_pos = self.pos;
        if (value_start_pos >= self.tokens.len) return self.parseExpression(ast);

        const value_line_start = self.lineStartAtByte(self.tokens[value_start_pos].span.start);
        const limit = self.findEachIndentedListValueLimit(value_start_pos, value_line_start);
        if (limit <= value_start_pos) return self.parseExpression(ast);

        var sub = self.createSubParser(self.tokens[value_start_pos..limit]);
        defer sub.deinit();

        const node = try sub.parseExpression(ast);
        self.pos = value_start_pos + sub.pos;
        return node;
    }

    fn findEachIndentedListValueLimit(
        self: *const Parser,
        start_pos: usize,
        header_line_start: u32,
    ) usize {
        var p = start_pos;
        var paren_depth: u32 = 0;
        var bracket_depth: u32 = 0;
        var interp_depth: u32 = 0;
        var last_significant_idx: ?usize = null;

        while (p < self.tokens.len) : (p += 1) {
            const tok = self.tokens[p];
            const t = tok.tag;

            if (t == .hash_lbrace) {
                interp_depth += 1;
                last_significant_idx = p;
                continue;
            }
            if (t == .rbrace and interp_depth > 0) {
                interp_depth -= 1;
                last_significant_idx = p;
                continue;
            }
            if (interp_depth > 0) {
                last_significant_idx = p;
                continue;
            }

            if (t == .lparen) {
                paren_depth += 1;
                last_significant_idx = p;
                continue;
            }
            if (t == .rparen and paren_depth > 0) {
                paren_depth -= 1;
                last_significant_idx = p;
                continue;
            }
            if (t == .lbracket) {
                bracket_depth += 1;
                last_significant_idx = p;
                continue;
            }
            if (t == .rbracket and bracket_depth > 0) {
                bracket_depth -= 1;
                last_significant_idx = p;
                continue;
            }

            if (paren_depth == 0 and bracket_depth == 0) {
                if (t == .semicolon or t == .rbrace or t == .eof) return p;
                if (t == .newline) {
                    var q = p + 1;
                    while (q < self.tokens.len) : (q += 1) {
                        const qt = self.tokens[q].tag;
                        if (qt == .whitespace or qt == .newline or qt == .comment) continue;
                        break;
                    }
                    if (q >= self.tokens.len) return q;
                    const qtok = self.tokens[q];
                    const q_line_start = self.lineStartAtByte(qtok.span.start);
                    if (q_line_start > header_line_start) {
                        if (last_significant_idx) |si| {
                            if (self.tokens[si].tag != .comma and self.tokenAllowsIndentedLineContinuation(si, qtok)) continue;
                        }
                        return q;
                    }
                }
            }

            if (t != .whitespace and t != .newline and t != .comment) {
                last_significant_idx = p;
            }
        }
        return self.tokens.len;
    }

    fn parseIndentedHeaderExpr(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        return self.parseIndentedHeaderExprWithMode(ast, .expression);
    }

    fn parseIndentedHeaderBinaryExpr(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        return self.parseIndentedHeaderExprWithMode(ast, .binary);
    }

    const IndentedHeaderExprMode = enum { expression, binary };

    fn parseIndentedHeaderExprWithMode(
        self: *Parser,
        ast: *Ast,
        mode: IndentedHeaderExprMode,
    ) ParseError!NodeIndex {
        if (!self.is_indented_syntax) {
            return switch (mode) {
                .expression => self.parseExpression(ast),
                .binary => self.parseBinaryExpr(ast, 0),
            };
        }

        const value_start_pos = self.pos;
        if (value_start_pos >= self.tokens.len) {
            return switch (mode) {
                .expression => self.parseExpression(ast),
                .binary => self.parseBinaryExpr(ast, 0),
            };
        }

        const value_line_start = self.lineStartAtByte(self.tokens[value_start_pos].span.start);
        const limit = self.findSimpleAtRuleValueLimit(value_start_pos, std.math.maxInt(u32), value_line_start);
        if (limit <= value_start_pos) {
            return switch (mode) {
                .expression => self.parseExpression(ast),
                .binary => self.parseBinaryExpr(ast, 0),
            };
        }

        var sub = self.createSubParser(self.tokens[value_start_pos..limit]);
        defer sub.deinit();

        const node = switch (mode) {
            .expression => try sub.parseExpression(ast),
            .binary => try sub.parseBinaryExpr(ast, 0),
        };
        self.pos = value_start_pos + sub.pos;
        return node;
    }

    fn findEachBlockStart(self: *const Parser, start_pos: usize) ?usize {
        var p = start_pos;
        var paren_depth: u32 = 0;
        var bracket_depth: u32 = 0;
        var brace_depth: u32 = 0;
        var interp_depth: u32 = 0;

        while (p < self.tokens.len) : (p += 1) {
            const t = self.tokens[p].tag;
            if (t == .hash_lbrace) {
                interp_depth += 1;
                continue;
            }
            if (t == .rbrace and interp_depth > 0) {
                interp_depth -= 1;
                continue;
            }
            if (interp_depth > 0) continue;

            if (t == .lparen) {
                paren_depth += 1;
                continue;
            }
            if (t == .rparen and paren_depth > 0) {
                paren_depth -= 1;
                continue;
            }
            if (t == .lbracket) {
                bracket_depth += 1;
                continue;
            }
            if (t == .rbracket and bracket_depth > 0) {
                bracket_depth -= 1;
                continue;
            }
            if (t == .lbrace) {
                if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) return p;
                brace_depth += 1;
                continue;
            }
            if (t == .rbrace) {
                if (brace_depth > 0) {
                    brace_depth -= 1;
                    continue;
                }
                return null;
            }
            if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0 and
                (t == .semicolon or t == .eof))
            {
                return null;
            }
        }
        return null;
    }

    /// Parse `@for $var from expr (to|through) expr { body }`.
    ///
    /// extra layout: `[var_id, from_node, to_node, body_extra]`.
    /// flags bit 0: 1 = exclusive (`to`), 0 = inclusive (`through`).
    fn parseForRule(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const at_tok = self.current();
        std.debug.assert(at_tok.tag == .at_for);
        self.advance(); // skip @for
        self.skipWhitespaceAndComments();

        if (self.isAtEnd() or self.current().tag != .dollar_ident) {
            return error.SyntaxError;
        }
        const v_tok = self.current();
        const v_text = v_tok.slice(self.source);
        std.debug.assert(v_text.len >= 1 and v_text[0] == '$');
        const var_id = try self.intern_pool.intern(v_text[1..]);
        self.advance();
        self.skipWhitespaceAndComments();

        if (self.isAtEnd() or self.current().tag != .ident or
            !std.mem.eql(u8, self.current().slice(self.source), "from"))
        {
            return error.SyntaxError;
        }
        self.advance(); // skip `from`
        self.skipWhitespaceAndComments();

        // Use parseBinaryExpr directly so that the `through` / `to`
        // keyword that follows is NOT swallowed as a space-list
        // continuation (parseSpaceListOrSingle would collect the
        // keyword as an unquoted ident item).
        const from_node = if (self.is_indented_syntax)
            try self.parseIndentedHeaderBinaryExpr(ast)
        else
            try self.parseBinaryExpr(ast, 0);
        self.skipWhitespaceAndComments();

        // Discriminator: `to`  ->  exclusive, `through`  ->  inclusive.
        var exclusive: bool = false;
        if (self.isAtEnd() or self.current().tag != .ident) {
            return error.SyntaxError;
        }
        const kw = self.current().slice(self.source);
        if (std.mem.eql(u8, kw, "to")) {
            exclusive = true;
        } else if (std.mem.eql(u8, kw, "through")) {
            exclusive = false;
        } else {
            return error.SyntaxError;
        }
        self.advance();
        self.skipWhitespaceAndComments();

        const to_node = if (self.is_indented_syntax)
            try self.parseIndentedHeaderBinaryExpr(ast)
        else
            try self.parseBinaryExpr(ast, 0);
        self.skipWhitespaceAndComments();
        const body = try self.parseBlockBodyAnchored(ast, at_tok.span.start);

        const extra_off = try ast.appendExtraU32(@intFromEnum(var_id));
        _ = try ast.appendExtraU32(from_node.toU32());
        _ = try ast.appendExtraU32(to_node.toU32());
        _ = try ast.appendExtraU32(body.extra);

        var flags: u8 = 0;
        if (exclusive) flags |= 0b0000_0001;

        return try ast.addNode(.{
            .tag = .stmt_for,
            .flags = flags,
            .payload = extra_off,
            .span_start = at_tok.span.start,
            .span_end = body.span_end,
        });
    }

    /// Parse `@while cond { body }`.
    ///
    /// extra layout: `[cond_node, body_extra]`.
    fn parseWhileRule(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const at_tok = self.current();
        std.debug.assert(at_tok.tag == .at_while);
        self.advance(); // skip @while
        self.skipWhitespaceAndComments();

        const cond_node = if (self.is_indented_syntax)
            try self.parseIndentedHeaderExpr(ast)
        else
            try self.parseExpression(ast);
        self.skipWhitespaceAndComments();
        const body = try self.parseBlockBody(ast);

        const extra_off = try ast.appendExtraU32(cond_node.toU32());
        _ = try ast.appendExtraU32(body.extra);

        return try ast.addNode(.{
            .tag = .stmt_while,
            .flags = 0,
            .payload = extra_off,
            .span_start = at_tok.span.start,
            .span_end = body.span_end,
        });
    }

    /// Emit a `stmt_comment` node for the block comment at `self.pos`.
    /// Line comments are stripped by `skipTrivia`, so only block
    /// comments ever reach this helper.
    fn parseCommentStmt(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const tok = self.current();
        std.debug.assert(tok.tag == .comment);
        const comment_token_index = self.pos;
        const comment_line_start = self.lineStartAtByte(tok.span.start);
        const comment_indent = self.lineIndentAtByte(tok.span.start);
        const prev_sig = self.prevSignificantTokenIndex(comment_token_index);
        self.advance();

        if (self.is_indented_syntax) {
            // `.sass`: consume same-line trailing comments after a loud comment
            // (`/* */ /* */`, `/* */ //`), but reject other trailing text.
            while (self.pos < self.tokens.len) {
                const cur = self.tokens[self.pos];
                const cur_line_start = self.lineStartAtByte(cur.span.start);
                if (cur_line_start != comment_line_start) break;
                switch (cur.tag) {
                    .whitespace, .comment => self.pos += 1,
                    .newline, .eof => break,
                    else => return error.SyntaxError,
                }
            }

            // Top-level indented text immediately after a loud comment is
            // invalid (`/* ... */` followed by an indented selector/value).
            var q = self.pos;
            while (q < self.tokens.len) : (q += 1) {
                const t = self.tokens[q].tag;
                if (t == .whitespace or t == .newline or t == .comment) continue;
                break;
            }
            if (q < self.tokens.len) {
                const next_tok = self.tokens[q];
                if (self.lineStartAtByte(next_tok.span.start) > comment_line_start and
                    self.lineIndentAtByte(next_tok.span.start) > comment_indent and
                    prev_sig == null)
                {
                    return error.SyntaxError;
                }
            }
        }

        return try ast.addNode(.{
            .tag = .stmt_comment,
            .flags = 0,
            .payload = 0,
            .span_start = tok.span.start,
            .span_end = tok.span.end,
        });
    }

    /// Parse `$name: value [!default] [!global] [;]`.
    /// Emits `stmt_variable_decl` with extra layout
    /// `[name_id, value_node, flags_u32]` where
    /// `flags_u32` bit 0 = `!default`, bit 1 = `!global`.
    fn parseVariableDeclStmt(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const name_tok = self.current();
        std.debug.assert(name_tok.tag == .dollar_ident);
        const name_text = name_tok.slice(self.source);
        std.debug.assert(name_text.len >= 1 and name_text[0] == '$');
        const name_id = try self.intern_pool.intern(name_text[1..]);
        self.advance(); // skip $name

        self.skipWhitespaceAndComments();
        if (self.isAtEnd() or self.current().tag != .colon) {
            return error.SyntaxError;
        }
        self.advance(); // skip :
        var saw_newline_after_colon = false;
        if (self.is_indented_syntax) {
            while (self.pos < self.tokens.len) {
                const t = self.tokens[self.pos].tag;
                if (t == .whitespace or t == .comment) {
                    self.pos += 1;
                    continue;
                }
                if (t == .newline) {
                    saw_newline_after_colon = true;
                    self.pos += 1;
                    continue;
                }
                break;
            }
        } else {
            self.skipWhitespaceAndComments();
        }

        const value_node = if (self.is_indented_syntax)
            if (saw_newline_after_colon)
                try self.parseDeclarationValueExprOrRawAnchoredAllowIndentedFirstLine(ast, name_tok.span.start)
            else
                try self.parseDeclarationValueExprOrRawSingleLine(ast)
        else
            try self.parseDeclarationValueExprOrRaw(ast);

        // Flag loop: `!default` / `!global` may appear in any order.
        // Indented syntax (`.sass`) keeps this on the same logical line:
        //   $a: b !default
        // A deeper-indented follow-up line is not a continuation and must
        // be rejected later ("Nothing may be indented beneath a variable declaration.").
        var flags_u32: u32 = 0;
        var end_pos: u32 = ast.getNode(value_node).span_end;
        const value_span = ast.getNode(value_node);
        const value_line_anchor = if (value_span.span_end > value_span.span_start) value_span.span_end - 1 else value_span.span_start;
        const flag_line_start = if (self.is_indented_syntax) self.lineStartAtByte(value_line_anchor) else 0;
        while (true) {
            if (self.is_indented_syntax) {
                self.skipInlineWhitespaceAndComments();
            } else {
                self.skipWhitespaceAndComments();
            }
            if (self.isAtEnd()) break;
            if (self.current().tag != .bang) break;
            if (self.is_indented_syntax and self.lineStartAtByte(self.current().span.start) != flag_line_start) break;

            const saved = self.pos;
            const bang_tok = self.current();
            self.advance(); // skip !
            if (self.is_indented_syntax) {
                self.skipInlineWhitespaceAndComments();
            } else {
                self.skipWhitespaceAndComments();
            }
            if (self.isAtEnd() or self.current().tag != .ident) {
                self.pos = saved;
                break;
            }
            const text = self.current().slice(self.source);
            if (std.mem.eql(u8, text, "default")) {
                flags_u32 |= 0b0000_0001;
                end_pos = self.current().span.end;
                self.advance();
                continue;
            }
            if (std.mem.eql(u8, text, "global")) {
                flags_u32 |= 0b0000_0010;
                end_pos = self.current().span.end;
                self.advance();
                continue;
            }
            _ = bang_tok;
            self.pos = saved;
            break;
        }

        if (self.is_indented_syntax) {
            self.skipInlineWhitespaceAndComments();
        } else {
            self.skipWhitespaceAndComments();
        }
        if (!self.isAtEnd() and self.current().tag == .semicolon) {
            end_pos = self.current().span.end;
            self.advance();
        }
        // If the next token is `}` or EOF, leave the terminator for the
        // outer block parser / main loop -- the variable decl itself is
        // complete without an explicit `;`.

        if (self.is_indented_syntax) {
            const decl_indent = self.lineIndentAtByte(name_tok.span.start);
            const decl_line_start = self.lineStartAtByte(name_tok.span.start);
            var look = self.pos;
            while (look < self.tokens.len) {
                const tok = self.tokens[look];
                switch (tok.tag) {
                    .whitespace, .newline => {
                        look += 1;
                        continue;
                    },
                    .comment => {
                        const text = tok.slice(self.source);
                        if (text.len >= 2 and text[0] == '/' and text[1] == '/') {
                            look += 1;
                            continue;
                        }
                        break;
                    },
                    else => {},
                }
                break;
            }
            if (look < self.tokens.len and self.tokens[look].tag != .eof) {
                const next_tok = self.tokens[look];
                const next_line_start = self.lineStartAtByte(next_tok.span.start);
                const next_indent = self.lineIndentAtByte(next_tok.span.start);
                if (next_line_start > decl_line_start and next_indent > decl_indent) {
                    return error.SyntaxError;
                }
            }
        }

        const extra_off = try ast.appendExtraU32(@intFromEnum(name_id));
        _ = try ast.appendExtraU32(value_node.toU32());
        _ = try ast.appendExtraU32(flags_u32);

        return try ast.addNode(.{
            .tag = .stmt_variable_decl,
            .flags = 0,
            .payload = extra_off,
            .span_start = name_tok.span.start,
            .span_end = end_pos,
        });
    }

    /// Parse an at-rule whose body is a single expression followed by
    /// an optional `;`: `@return`, `@debug`, `@warn`, `@error`.
    /// These all use the same payload layout (NodeIndex of the value
    /// expression) and share span handling.
    fn parseSimpleAtRuleValue(self: *Parser, ast: *Ast, tag: AstTag) ParseError!NodeIndex {
        std.debug.assert(tag == .stmt_return or tag == .stmt_debug or
            tag == .stmt_warn or tag == .stmt_error);
        const at_tok = self.current();
        self.advance(); // skip @name keyword token
        self.skipWhitespaceAndComments();

        const value_node = blk: {
            if (!self.is_indented_syntax) break :blk try self.parseExpression(ast);

            const value_start_pos = self.pos;
            const header_indent = self.lineIndentAtByte(at_tok.span.start);
            const header_line_start = self.lineStartAtByte(at_tok.span.start);
            const limit = self.findSimpleAtRuleValueLimit(value_start_pos, header_indent, header_line_start);

            if (limit <= value_start_pos) break :blk try self.parseExpression(ast);

            var sub = Parser.init(
                self.allocator,
                self.intern_pool,
                self.tokens[value_start_pos..limit],
                self.source,
            );
            sub.in_css_custom_function = self.in_css_custom_function;
            sub.call_arg_depth = self.call_arg_depth;
            sub.is_indented_syntax = self.is_indented_syntax;
            defer sub.deinit();

            const node = try sub.parseExpression(ast);
            self.pos = value_start_pos + sub.pos;
            break :blk node;
        };

        var end_pos: u32 = ast.getNode(value_node).span_end;
        self.skipWhitespaceAndComments();
        if (!self.isAtEnd() and self.current().tag == .semicolon) {
            end_pos = self.current().span.end;
            self.advance();
        }

        return try ast.addNode(.{
            .tag = tag,
            .flags = 0,
            .payload = value_node.toU32(),
            .span_start = at_tok.span.start,
            .span_end = end_pos,
        });
    }

    /// Parse an indented-syntax control-rule header expression (`@if` /
    /// `@else if` / `@while`) with the same newline+d edent limiter as
    /// simple at-rules. In SCSS this is just `parseExpression()`.
    fn parseAtRuleConditionExprAnchored(
        self: *Parser,
        ast: *Ast,
        header_start: u32,
    ) ParseError!NodeIndex {
        if (!self.is_indented_syntax) return self.parseExpression(ast);

        const value_start_pos = self.pos;
        const header_indent = self.lineIndentAtByte(header_start);
        const header_line_start = self.lineStartAtByte(header_start);
        const limit = self.findControlConditionLimit(value_start_pos, header_indent, header_line_start);
        if (limit <= value_start_pos) return self.parseExpression(ast);

        var sub = self.createSubParser(self.tokens[value_start_pos..limit]);
        defer sub.deinit();

        const node = try sub.parseExpression(ast);
        self.pos = value_start_pos + sub.pos;
        return node;
    }

    fn isConditionContinuationToken(self: *const Parser, tok: Token) bool {
        if (infixBindingPower(tok.tag) != null) return true;
        if (tok.tag == .ident) {
            const text = tok.slice(self.source);
            if (std.mem.eql(u8, text, "and") or std.mem.eql(u8, text, "or")) return true;
        }
        return switch (tok.tag) {
            .comma, .lparen, .lbracket, .colon => true,
            else => false,
        };
    }

    /// Expression end search for `.sass` control header (`@if` / `@else if` / `@while`).
    ///
    /// Tracks parenthesis depth like `findSimpleAtRuleValueLimit()`, but deeper
    /// When you encounter an indented line, the message "The previous significant token is an operator, etc.
    /// Determine continuation based on whether it is a continuation token.
    fn findControlConditionLimit(
        self: *const Parser,
        start_pos: usize,
        header_indent: u32,
        header_line_start: u32,
    ) usize {
        var p = start_pos;
        var paren_depth: u32 = 0;
        var bracket_depth: u32 = 0;
        var interp_depth: u32 = 0;

        while (p < self.tokens.len) : (p += 1) {
            const tok = self.tokens[p];
            const t = tok.tag;

            if (t == .hash_lbrace) {
                interp_depth += 1;
                continue;
            }
            if (t == .rbrace and interp_depth > 0) {
                interp_depth -= 1;
                continue;
            }
            if (interp_depth > 0) continue;

            if (t == .lparen) {
                paren_depth += 1;
                continue;
            }
            if (t == .rparen and paren_depth > 0) {
                paren_depth -= 1;
                continue;
            }
            if (t == .lbracket) {
                bracket_depth += 1;
                continue;
            }
            if (t == .rbracket and bracket_depth > 0) {
                bracket_depth -= 1;
                continue;
            }

            if (paren_depth == 0 and bracket_depth == 0) {
                if (t == .semicolon or t == .rbrace or t == .eof) return p;
                if (t == .newline) {
                    var q = p + 1;
                    while (q < self.tokens.len) : (q += 1) {
                        const qt = self.tokens[q].tag;
                        if (qt == .whitespace or qt == .newline or qt == .comment) continue;
                        break;
                    }
                    if (q >= self.tokens.len) return q;

                    const qtok = self.tokens[q];
                    const q_line_start = self.lineStartAtByte(qtok.span.start);
                    if (q_line_start > header_line_start) {
                        const q_indent = self.lineIndentAtByte(qtok.span.start);
                        if (q_indent <= header_indent) return q;
                        if (self.prevSignificantTokenIndex(p)) |prev_idx| {
                            if (!self.isConditionContinuationToken(self.tokens[prev_idx])) return q;
                        } else {
                            return q;
                        }
                    }
                }
            }
        }
        return self.tokens.len;
    }

    /// Declaration-value limiter for indented syntax.
    ///
    /// Compared to `findSimpleAtRuleValueLimit`, deeper-indented lines do not
    /// continue unconditionally. They continue only when the previous
    /// significant token is a continuation marker (`+`, `,`, `(`, ...).
    fn findDeclarationValueLimit(
        self: *const Parser,
        start_pos: usize,
        header_indent: u32,
        header_line_start: u32,
    ) usize {
        var p = start_pos;
        var paren_depth: u32 = 0;
        var bracket_depth: u32 = 0;
        var interp_depth: u32 = 0;
        var last_significant_idx: ?usize = null;

        while (p < self.tokens.len) : (p += 1) {
            const tok = self.tokens[p];
            const t = tok.tag;

            if (t == .hash_lbrace) {
                interp_depth += 1;
                last_significant_idx = p;
                continue;
            }
            if (t == .rbrace and interp_depth > 0) {
                interp_depth -= 1;
                last_significant_idx = p;
                continue;
            }
            if (interp_depth > 0) {
                last_significant_idx = p;
                continue;
            }

            if (t == .lparen) {
                paren_depth += 1;
                last_significant_idx = p;
                continue;
            }
            if (t == .rparen and paren_depth > 0) {
                paren_depth -= 1;
                last_significant_idx = p;
                continue;
            }
            if (t == .lbracket) {
                bracket_depth += 1;
                last_significant_idx = p;
                continue;
            }
            if (t == .rbracket and bracket_depth > 0) {
                bracket_depth -= 1;
                last_significant_idx = p;
                continue;
            }

            if (paren_depth == 0 and bracket_depth == 0) {
                if (t == .semicolon or t == .rbrace or t == .eof) return p;
                if (t == .newline) {
                    var q = p + 1;
                    while (q < self.tokens.len) : (q += 1) {
                        const qt = self.tokens[q].tag;
                        if (qt == .whitespace or qt == .newline or qt == .comment) continue;
                        break;
                    }
                    if (q >= self.tokens.len) return q;

                    const qtok = self.tokens[q];
                    const q_line_start = self.lineStartAtByte(qtok.span.start);
                    if (q_line_start > header_line_start) {
                        const q_indent = self.lineIndentAtByte(qtok.span.start);
                        const allows_continuation = if (last_significant_idx) |si|
                            self.tokenAllowsIndentedLineContinuation(si, qtok)
                        else
                            false;

                        if (q_indent <= header_indent) {
                            const continuation_indent_ok = if (header_indent == std.math.maxInt(u32))
                                q_indent == self.lineIndentAtByte(header_line_start)
                            else
                                true;
                            if (continuation_indent_ok and allows_continuation) continue;
                            return q;
                        }

                        // Single-line variable mode never continues to deeper indentation.
                        if (header_indent == std.math.maxInt(u32)) return q;
                        if (!allows_continuation) return q;
                    }
                }
            }

            if (t != .whitespace and t != .newline and t != .comment) {
                last_significant_idx = p;
            }
        }
        return self.tokens.len;
    }

    /// Custom-property value limiter for indented syntax.
    ///
    /// Allows multiline continuation while grouped by `()`, `[]`, `{}` or
    /// interpolation `#{...}`. At top level, the statement ends on the first
    /// following line (same or deeper indentation), leaving nested lines to be
    /// diagnosed as "Nothing may be indented beneath a custom property."
    fn findCustomPropertyValueLimit(
        self: *const Parser,
        start_pos: usize,
        header_indent: u32,
        header_line_start: u32,
    ) usize {
        var p = start_pos;
        var stack: [64]u8 = undefined;
        var depth: usize = 0;
        var interp_depth: u32 = 0;

        while (p < self.tokens.len) : (p += 1) {
            const tok = self.tokens[p];
            const t = tok.tag;

            if (t == .hash_lbrace) {
                interp_depth += 1;
                continue;
            }
            if (t == .rbrace and interp_depth > 0) {
                interp_depth -= 1;
                continue;
            }
            if (interp_depth > 0) continue;

            if (t == .lparen) {
                if (depth < stack.len) {
                    stack[depth] = '(';
                    depth += 1;
                }
                continue;
            }
            if (t == .lbracket) {
                if (depth < stack.len) {
                    stack[depth] = '[';
                    depth += 1;
                }
                continue;
            }
            if (t == .lbrace) {
                if (depth < stack.len) {
                    stack[depth] = '{';
                    depth += 1;
                }
                continue;
            }
            if (t == .rparen and depth > 0 and stack[depth - 1] == '(') {
                depth -= 1;
                continue;
            }
            if (t == .rbracket and depth > 0 and stack[depth - 1] == '[') {
                depth -= 1;
                continue;
            }
            if (t == .rbrace and depth > 0 and stack[depth - 1] == '{') {
                depth -= 1;
                continue;
            }

            if (depth == 0) {
                if (t == .semicolon or t == .rbrace or t == .eof) return p;
                if (t == .newline) {
                    var q = p + 1;
                    while (q < self.tokens.len) : (q += 1) {
                        const qt = self.tokens[q].tag;
                        if (qt == .whitespace or qt == .newline or qt == .comment) continue;
                        break;
                    }
                    if (q >= self.tokens.len) return q;

                    const qtok = self.tokens[q];
                    const q_line_start = self.lineStartAtByte(qtok.span.start);
                    if (q_line_start > header_line_start) {
                        const q_indent = self.lineIndentAtByte(qtok.span.start);
                        if (q_indent <= header_indent) return q;
                        return q;
                    }
                }
            }
        }
        return self.tokens.len;
    }

    /// For indented-syntax simple at-rules (`@return`, `@debug`, ...), find
    /// the token index at which the value expression must stop.
    ///
    /// The value may continue across newlines while grouped by `()`, `[]`,
    /// or interpolation `#{...}`. Outside grouping, same/shallow indentation
    /// terminates the statement unless the previous significant token is a
    /// continuation operator. Deeper indentation usually continues the value,
    /// but `1%`-style glued percent units still terminate so the following
    /// line is rejected as invalid syntax.
    fn findSimpleAtRuleValueLimit(
        self: *const Parser,
        start_pos: usize,
        header_indent: u32,
        header_line_start: u32,
    ) usize {
        var p = start_pos;
        var paren_depth: u32 = 0;
        var bracket_depth: u32 = 0;
        var interp_depth: u32 = 0;
        var last_significant_idx: ?usize = null;

        while (p < self.tokens.len) : (p += 1) {
            const tok = self.tokens[p];
            const t = tok.tag;

            if (t == .hash_lbrace) {
                interp_depth += 1;
                last_significant_idx = p;
                continue;
            }
            if (t == .rbrace and interp_depth > 0) {
                interp_depth -= 1;
                last_significant_idx = p;
                continue;
            }
            if (interp_depth > 0) {
                last_significant_idx = p;
                continue;
            }

            if (t == .lparen) {
                paren_depth += 1;
                last_significant_idx = p;
                continue;
            }
            if (t == .rparen and paren_depth > 0) {
                paren_depth -= 1;
                last_significant_idx = p;
                continue;
            }
            if (t == .lbracket) {
                bracket_depth += 1;
                last_significant_idx = p;
                continue;
            }
            if (t == .rbracket and bracket_depth > 0) {
                bracket_depth -= 1;
                last_significant_idx = p;
                continue;
            }

            if (paren_depth == 0 and bracket_depth == 0) {
                if (t == .semicolon or t == .rbrace or t == .eof) return p;
                if (t == .newline) {
                    var q = p + 1;
                    while (q < self.tokens.len) : (q += 1) {
                        const qt = self.tokens[q].tag;
                        if (qt == .whitespace or qt == .newline or qt == .comment) continue;
                        break;
                    }
                    if (q >= self.tokens.len) return q;

                    const qtok = self.tokens[q];
                    const q_line_start = self.lineStartAtByte(qtok.span.start);
                    if (q_line_start > header_line_start) {
                        const q_indent = self.lineIndentAtByte(qtok.span.start);
                        if (last_significant_idx) |si| {
                            if (q_indent > header_indent and self.percentTokenIsGluedUnit(si, qtok)) {
                                return q;
                            }
                        }
                        if (header_indent == std.math.maxInt(u32)) {
                            if (last_significant_idx) |si| {
                                if (self.tokenAllowsIndentedLineContinuation(si, qtok)) continue;
                            }
                        }
                        if (q_indent <= header_indent) {
                            const continuation_indent_ok = if (header_indent == std.math.maxInt(u32))
                                q_indent == self.lineIndentAtByte(header_line_start)
                            else
                                true;
                            if (continuation_indent_ok) {
                                if (last_significant_idx) |si| {
                                    if (self.tokenAllowsIndentedLineContinuation(si, qtok)) continue;
                                }
                            }
                            return q;
                        }
                        // Single-line variable-declaration mode (`header_indent == maxInt`) must
                        // still stop at deeper indentation to preserve
                        // "Nothing may be indented beneath a variable declaration." behavior.
                        if (header_indent == std.math.maxInt(u32)) return q;
                    }
                }
            }

            if (t != .whitespace and t != .newline and t != .comment) {
                last_significant_idx = p;
            }
        }
        return self.tokens.len;
    }

    fn percentTokenIsGluedUnit(self: *const Parser, tok_idx: usize, _: Token) bool {
        const tok = self.tokens[tok_idx];
        if (tok.tag != .percent) return false;
        const prev_idx = self.prevSignificantTokenIndex(tok_idx) orelse return false;
        const prev_tok = self.tokens[prev_idx];
        return prev_tok.tag == .number and prev_tok.span.end == tok.span.start;
    }

    fn tokenAllowsIndentedLineContinuation(self: *const Parser, tok_idx: usize, next_tok: Token) bool {
        const tok = self.tokens[tok_idx];
        return switch (tok.tag) {
            .plus,
            .minus,
            .star,
            .slash,
            .equal,
            .equal_equal,
            .bang_equal,
            .less_than,
            .less_than_equal,
            .greater_than,
            .greater_than_equal,
            .comma,
            .lparen,
            .lbracket,
            .hash_lbrace,
            => true,
            .percent => if (self.percentTokenIsGluedUnit(tok_idx, next_tok))
                false
            else switch (next_tok.tag) {
                .number, .dollar_ident, .lparen, .plus, .minus => true,
                else => false,
            },
            .bang => switch (next_tok.tag) {
                .ident => blk: {
                    const text = next_tok.slice(self.source);
                    break :blk std.ascii.eqlIgnoreCase(text, "important") or
                        std.ascii.eqlIgnoreCase(text, "default") or
                        std.ascii.eqlIgnoreCase(text, "global");
                },
                else => false,
            },
            .ident => blk: {
                const text = tok.slice(self.source);
                break :blk std.mem.eql(u8, text, "and") or
                    std.mem.eql(u8, text, "or") or
                    std.mem.eql(u8, text, "not");
            },
            else => false,
        };
    }

    // -- expression parsing ------------------------------------------------

    /// Parse one expression starting at the current token.
    ///
    /// R.2c.2d scope: top-level form is a comma list, wrapping a space
    /// list, wrapping the Pratt binary-expression core.  Interpolation
    /// and splat come in R.2c.2e.
    ///
    /// Returns the `NodeIndex` of the root expression node.  Leading
    /// whitespace is consumed; trailing trivia is left for the caller.
    pub fn parseExpression(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        return self.parseCommaListOrSingle(ast);
    }

    /// Parse a comma-separated expression list.  If only one item is
    /// present, the single expression is returned directly (no wrapping
    /// `expr_comma_list` node).
    ///
    /// Trailing commas are tolerated.  Block comments between list
    /// elements are skipped so a value like `1, /* c */ 2` parses as
    /// a 2-item comma list.
    fn parseCommaListOrSingle(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const first = try self.parseSpaceListOrSingle(ast);
        self.skipWhitespaceAndComments();
        if (self.isAtEnd() or self.current().tag != .comma) return first;

        var items: std.ArrayListUnmanaged(NodeIndex) = .empty;
        defer items.deinit(self.allocator);
        try items.append(self.allocator, first);

        while (!self.isAtEnd() and self.current().tag == .comma) {
            self.advance(); // skip comma
            self.skipWhitespaceAndComments();
            if (self.isAtEnd()) break;
            if (isExpressionTerminator(self.current().tag)) break;
            const next = try self.parseSpaceListOrSingle(ast);
            try items.append(self.allocator, next);
            self.skipWhitespaceAndComments();
        }

        const span_start = ast.getNode(items.items[0]).span_start;
        const span_end = ast.getNode(items.items[items.items.len - 1]).span_end;
        return try emitListNode(ast, .expr_comma_list, 0, items.items, span_start, span_end);
    }

    /// Parse a space-separated expression list.  If only one item is
    /// present, the single expression is returned directly (no wrapping
    /// `expr_space_list` node).  Block comments between items are
    /// skipped.
    fn parseSpaceListOrSingle(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const first = if (self.isImportantFlag())
            try self.consumeImportantFlag(ast)
        else
            try self.parseBinaryExpr(ast, 0);
        self.skipWhitespaceAndComments();
        if (self.isAtEnd()) return first;
        if (isExpressionTerminator(self.current().tag)) return first;
        if (self.current().tag == .comma) return first;
        if (self.isInfixOp()) return first;
        if (!canStartAtom(self.current().tag) and !self.isImportantFlag()) return first;

        var items: std.ArrayListUnmanaged(NodeIndex) = .empty;
        defer items.deinit(self.allocator);
        try items.append(self.allocator, first);

        while (!self.isAtEnd()) {
            if (isExpressionTerminator(self.current().tag)) break;
            if (self.current().tag == .comma) break;
            if (self.isInfixOp()) break;
            if (self.isImportantFlag()) {
                const node = try self.consumeImportantFlag(ast);
                try items.append(self.allocator, node);
                self.skipWhitespaceAndComments();
                continue;
            }
            if (!canStartAtom(self.current().tag)) break;
            const next = try self.parseBinaryExpr(ast, 0);
            try items.append(self.allocator, next);
            self.skipWhitespaceAndComments();
        }

        if (items.items.len == 1) return first;

        const span_start = ast.getNode(items.items[0]).span_start;
        const span_end = ast.getNode(items.items[items.items.len - 1]).span_end;
        return try emitListNode(ast, .expr_space_list, 0, items.items, span_start, span_end);
    }

    /// True if the current token is `!` followed by ident `important`
    /// (with optional whitespace/comment between).  Used to splice
    /// `!important` into a space-list as a literal value rather than
    /// terminating the value expression.
    fn isImportantFlag(self: *const Parser) bool {
        if (self.pos >= self.tokens.len) return false;
        if (self.tokens[self.pos].tag != .bang) return false;
        var p = self.pos + 1;
        while (p < self.tokens.len) : (p += 1) {
            const t = self.tokens[p].tag;
            if (t == .whitespace or t == .newline or t == .comment) continue;
            if (t == .ident and std.ascii.eqlIgnoreCase(self.tokens[p].slice(self.source), "important")) return true;
            return false;
        }
        return false;
    }

    /// Consume `! important` and emit an unquoted-ident node holding
    /// the literal text `!important` (Sass treats this as an unquoted
    /// string value when it appears mid-expression / mid-list).
    fn consumeImportantFlag(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const bang_tok = self.current();
        std.debug.assert(bang_tok.tag == .bang);
        self.advance();
        self.skipWhitespaceAndComments();
        const ident_tok = self.current();
        std.debug.assert(ident_tok.tag == .ident);
        std.debug.assert(std.ascii.eqlIgnoreCase(ident_tok.slice(self.source), "important"));
        self.advance();
        const id = try self.intern_pool.intern("!important");
        return try ast.addNode(.{
            .tag = .expr_unquoted_ident,
            .flags = 0,
            .payload = @intFromEnum(id),
            .span_start = bang_tok.span.start,
            .span_end = ident_tok.span.end,
        });
    }

    /// True if the current token is any infix operator (symbol or
    /// `and`/`or` keyword).
    ///
    /// Asymmetric-`-` exception: when `-` has whitespace on its left
    /// and is immediately followed by `#{...}` interpolation, it
    /// attaches to the interp as a string-schema prefix rather than
    /// acting as a binary subtract.  Returning `false` here lets
    /// `parseSpaceListOrSingle` keep collecting the next atom (the
    /// unary-prefixed schema chunk).  See `isUnaryContext` and
    /// `parseBinaryExpr` for the matching break in the Pratt loop.
    fn isInfixOp(self: *const Parser) bool {
        if (self.pos >= self.tokens.len) return false;
        const tok = self.tokens[self.pos];
        if (tok.tag == .minus and self.pos + 1 < self.tokens.len) {
            const next_tok = self.tokens[self.pos + 1];
            if (next_tok.tag == .hash_lbrace and
                next_tok.span.start == tok.span.end)
            {
                return false;
            }
            if (self.minusStartsInterpolatedSchema(self.pos) and
                self.previousSignificantTokenTag(self.pos) == .string)
            {
                return false;
            }
        }
        if (infixBindingPower(tok.tag) != null) return true;
        if (tok.tag == .ident) {
            const text = tok.slice(self.source);
            if (std.mem.eql(u8, text, "or") or std.mem.eql(u8, text, "and")) return true;
        }
        return false;
    }

    /// Infix operator binding powers.  Left-associative (left < right).
    /// Values match the legacy parser.zig table:
    ///   or:                 2 / 3
    ///   and:                4 / 5
    ///   ==, !=:             6 / 7
    ///   <, <=, >, >=:       8 / 9
    ///   +, -:              10 / 11
    ///   *, /, %:           12 / 13
    ///   unary not/-/+:     14 (right binding power for the atom)
    const BindingPower = struct { left: u8, right: u8 };

    fn infixBindingPower(tag: Token.Tag) ?BindingPower {
        return switch (tag) {
            .equal_equal, .bang_equal => .{ .left = 6, .right = 7 },
            .greater_than, .less_than, .greater_than_equal, .less_than_equal => .{ .left = 8, .right = 9 },
            .plus, .minus => .{ .left = 10, .right = 11 },
            .star, .slash, .percent => .{ .left = 12, .right = 13 },
            else => null,
        };
    }

    const KeywordOp = enum { k_or, k_and };

    /// Recognise the keyword infix operators `or` and `and`.  Returns
    /// `null` for any other ident (including `not`, which is unary only).
    fn identInfixOp(self: *const Parser, tok: Token) ?KeywordOp {
        if (tok.tag != .ident) return null;
        const text = tok.slice(self.source);
        if (std.mem.eql(u8, text, "or")) return .k_or;
        if (std.mem.eql(u8, text, "and")) return .k_and;
        return null;
    }

    fn nextSignificantTokenIndex(self: *const Parser, start: usize) ?usize {
        var i = start;
        while (i < self.tokens.len) : (i += 1) {
            const t = self.tokens[i].tag;
            if (t == .whitespace or t == .newline or t == .comment) continue;
            return i;
        }
        return null;
    }

    fn infixMissingRightOperandShouldFatal(self: *const Parser, op_tag: Token.Tag, rhs_start_pos: usize) bool {
        // `%` is recoverable as raw declaration CSS (`c %`, `c(d %)`) and must
        // keep the existing raw fallback behavior from sass-spec.
        if (op_tag == .percent) return false;

        const rhs_idx = self.nextSignificantTokenIndex(rhs_start_pos) orelse return true;
        return isExpressionTerminator(self.tokens[rhs_idx].tag);
    }

    fn noteIncompleteBinaryRhsOnError(self: *Parser, op_tag: Token.Tag, rhs_start_pos: usize, err: ParseError) void {
        if (err != error.SyntaxError and err != error.UnexpectedEof) return;
        if (self.infixMissingRightOperandShouldFatal(op_tag, rhs_start_pos)) {
            self.saw_incomplete_binary_rhs = true;
        }
    }

    /// Pratt loop.  Given the minimum binding power, keep folding infix
    /// operators whose left binding power is >= min_bp.
    fn parseBinaryExpr(self: *Parser, ast: *Ast, min_bp: u8) ParseError!NodeIndex {
        const left = try self.parseUnaryOrAtom(ast);
        return self.parseBinaryExprRest(ast, left, min_bp);
    }

    fn parseBinaryExprRest(self: *Parser, ast: *Ast, initial_left: NodeIndex, min_bp: u8) ParseError!NodeIndex {
        var left = initial_left;
        while (true) {
            // Comments between operands behave as whitespace for operator
            // parsing -- `c/**/-(d)` parses as binary subtract just like
            // `c -(d)` does.  Block comments survive only when they sit
            // outside an expression; inside, official Sass CLI collapses them to
            // a single space which has no semantic effect on operator
            // recognition.  See `operators/minus.hrx::syntax/comment/*`.
            self.skipWhitespaceAndComments();
            if (self.isAtEnd()) break;
            if (isExpressionTerminator(self.current().tag)) break;

            const cur = self.current();

            // Keyword infix: `or` / `and`.  `not` is unary-only.
            if (self.identInfixOp(cur)) |kw| {
                const bp: BindingPower = switch (kw) {
                    .k_or => .{ .left = 2, .right = 3 },
                    .k_and => .{ .left = 4, .right = 5 },
                };
                if (bp.left < min_bp) break;
                self.advance();
                const rhs_start_pos = self.pos;
                const right = self.parseBinaryExpr(ast, bp.right) catch |err| {
                    self.noteIncompleteBinaryRhsOnError(cur.tag, rhs_start_pos, err);
                    return err;
                };
                const op: BinOp = switch (kw) {
                    .k_or => .log_or,
                    .k_and => .log_and,
                };
                left = try emitBinaryOp(ast, op, left, right);
                continue;
            }

            // Symbol infix operators from the binding power table.
            if (infixBindingPower(cur.tag)) |bp| {
                if (bp.left < min_bp) break;

                // `/` produces an `expr_slash_expr` -- the division-vs-literal
                // decision is deferred to the evaluator (context dependent).
                if (cur.tag == .slash) {
                    self.advance();
                    const rhs_start_pos = self.pos;
                    const right = self.parseBinaryExpr(ast, bp.right) catch |err| {
                        self.noteIncompleteBinaryRhsOnError(cur.tag, rhs_start_pos, err);
                        return err;
                    };
                    left = try emitSlashExpr(ast, left, right);
                    continue;
                }

                // `-` immediately followed by `#{...}` (no whitespace
                // between) attaches to the following interpolation as a
                // string-schema prefix rather than acting as binary
                // subtract.  The historical Sass behaviour emits a
                // space-list of the left value and the `-`-prefixed
                // schema; see
                // `non_conformant/parser/operations/subtract/...`.
                //
                // We do NOT require whitespace on the left here: the
                // ident-leading or interp-leading head atom has already
                // had the chance to absorb a leading `-` via
                // `parseTrailingSchema`, so reaching this point with a
                // `-` immediately before `#{...}` means the right
                // operand is unary-prefixed.
                if (cur.tag == .minus and self.pos + 1 < self.tokens.len) {
                    const next_tok = self.tokens[self.pos + 1];
                    if (next_tok.tag == .hash_lbrace and
                        next_tok.span.start == cur.span.end)
                    {
                        break;
                    }
                    if (self.minusStartsInterpolatedSchema(self.pos) and
                        self.previousSignificantTokenTag(self.pos) == .string)
                    {
                        break;
                    }
                }

                const op: BinOp = switch (cur.tag) {
                    .equal_equal => .eq,
                    .bang_equal => .ne,
                    .greater_than => .gt,
                    .less_than => .lt,
                    .greater_than_equal => .ge,
                    .less_than_equal => .le,
                    .plus => .add,
                    .minus => .sub,
                    .star => .mul,
                    .percent => .mod,
                    else => break, // unreachable (filtered by bp table)
                };
                self.advance();
                const rhs_start_pos = self.pos;
                const right = self.parseBinaryExpr(ast, bp.right) catch |err| {
                    self.noteIncompleteBinaryRhsOnError(cur.tag, rhs_start_pos, err);
                    return err;
                };
                left = try emitBinaryOp(ast, op, left, right);
                continue;
            }

            // Implicit addition: `1+2` may arrive as [number("1"), number("+2")]
            // because the lexer folds the sign into the number token.  If the
            // *very next* token (no preceding trivia) is a signed number, treat
            // it as binary `+` on the current left.
            //
            // The `+` sign also folds when the *previous* token is whitespace
            // (i.e. `A +B`) -- official Sass CLI parses this as binary `+` and emits a
            // strict-unary deprecation.  The `-` sign does NOT fold across
            // whitespace: `A -B` is a space-list of `A` and the unary-negated
            // `-B`, which is the historically correct behaviour.
            if (cur.tag == .number and self.pos > 0) {
                const num_text = cur.slice(self.source);
                if (num_text.len >= 2 and (num_text[0] == '+' or num_text[0] == '-')) {
                    const prev_tag = self.tokens[self.pos - 1].tag;
                    const prev_is_trivia = prev_tag == .whitespace or
                        prev_tag == .newline or
                        prev_tag == .comment;
                    const allow_fold = !prev_is_trivia or num_text[0] == '+';
                    if (allow_fold) {
                        const add_bp = infixBindingPower(.plus).?;
                        if (add_bp.left >= min_bp) {
                            // Consume the signed number as an implicit binary
                            // operator.  For `-N`, build a positive-magnitude
                            // right operand and emit `sub`; string subtraction
                            // preserves the hyphen (`U + 0000-00ff`  ->
                            // `U0-0ff`), while numeric subtraction still
                            // computes normally.  Then let tighter operators
                            // bind to the right (`1-2*3`).
                            const op: BinOp = if (num_text[0] == '-') .sub else .add;
                            const right_head = if (num_text[0] == '-')
                                try self.parseSignedNumberMagnitudeAtom(ast)
                            else
                                try self.parseUnaryOrAtom(ast);
                            const right = try self.parseBinaryExprRest(ast, right_head, add_bp.right);
                            left = try emitBinaryOp(ast, op, left, right);
                            continue;
                        }
                    }
                }
            }

            break;
        }

        return left;
    }

    /// Unary prefix handling: `not`, `-`, `+`.  Falls through to
    /// `parsePrimary` when no prefix matches.
    fn parseUnaryOrAtom(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        // Block comments before an expression atom are treated as
        // whitespace, so `1 +/**/2` parses with `2` as the right
        // operand of `+`.  See `operators/minus.hrx::syntax/comment/right`.
        self.skipWhitespaceAndComments();
        if (self.isAtEnd()) return error.UnexpectedEof;
        const tok = self.current();

        // `not <expr>` -- keyword unary.
        if (tok.tag == .ident and std.mem.eql(u8, tok.slice(self.source), "not")) {
            const op_span = tok.span;
            self.advance();
            const operand = try self.parseBinaryExpr(ast, 14);
            const end = ast.getNode(operand).span_end;
            return try emitUnaryOp(ast, .not, operand, op_span.start, end);
        }

        // Unary `-` / `+` -- only when context allows (start or after an
        // operator/delimiter that can't terminate an expression).
        if ((tok.tag == .minus or tok.tag == .plus) and self.isUnaryContext()) {
            const op_span = tok.span;
            const op: UnaryOp = if (tok.tag == .minus) .negate else .positive;
            self.advance();
            // Unary binds tightly -- don't pre-skip whitespace (matches legacy).
            const operand = try self.parseBinaryExpr(ast, 14);
            const end = ast.getNode(operand).span_end;
            return try emitUnaryOp(ast, op, operand, op_span.start, end);
        }

        // Unary `/` only in narrow positions (e.g. `(1, / 2)`  ->  second item `/2`).
        // Avoid treating `/` after `+` / `*` etc. as unary -- those must stay binary.
        if (tok.tag == .slash and self.isSlashUnaryPrefixContext()) {
            const op_span = tok.span;
            self.advance();
            const operand = try self.parseBinaryExpr(ast, 14);
            const end = ast.getNode(operand).span_end;
            return try emitUnaryOp(ast, .slash_prefix, operand, op_span.start, end);
        }

        return self.parsePrimary(ast);
    }

    /// Check whether the current `-` / `+` token should be parsed as a
    /// unary prefix.  Mirrors the legacy parser.zig heuristic: unary when
    /// at stream start, or when the previous non-trivia token cannot
    /// end an expression.
    ///
    /// Additional rule for asymmetric `-` directly attached to a
    /// `#{...}` interpolation:
    /// `<value> <whitespace> -#{...}` is parsed as space-list
    /// `<value>` and a `-`-prefixed string-schema, matching the
    /// historical Sass behaviour exercised by
    /// `non_conformant/parser/operations/subtract/.../pairs.hrx`.
    fn isUnaryContext(self: *const Parser) bool {
        if (self.pos == 0) return true;

        // `-` immediately before `#{...}` (no whitespace between)
        // is unary-on-right regardless of the prefix context -- the
        // schema fold on ident/interp heads has already absorbed any
        // adjacent `-` it could attach to.
        const cur = self.tokens[self.pos];
        if (cur.tag == .minus and self.pos + 1 < self.tokens.len) {
            const next_tok = self.tokens[self.pos + 1];
            if (next_tok.tag == .hash_lbrace and
                next_tok.span.start == cur.span.end)
            {
                return true;
            }
            if (self.minusStartsInterpolatedSchema(self.pos) and
                self.previousSignificantTokenTag(self.pos) == .string)
            {
                return true;
            }
        }

        var prev = self.pos - 1;
        while (prev > 0) : (prev -= 1) {
            const t = self.tokens[prev].tag;
            if (t != .whitespace and t != .newline and t != .comment) break;
        }
        return switch (self.tokens[prev].tag) {
            .lparen,
            .lbracket,
            .comma,
            .colon,
            .semicolon,
            .plus,
            .minus,
            .star,
            .slash,
            .percent,
            .equal_equal,
            .bang_equal,
            .less_than,
            .less_than_equal,
            .greater_than,
            .greater_than_equal,
            .hash_lbrace,
            // At-keywords that introduce a value expression: @return,
            // @debug, @warn, @error, plus the condition/expression slots
            // of @if / @each / @for / @while.  Without these, the parser
            // mis-classifies `@return -$x` as a binary operator context
            // and parsePrimary then rejects the bare `-`.
            .at_return,
            .at_debug,
            .at_warn,
            .at_error,
            .at_if,
            .at_each,
            .at_for,
            .at_while,
            => true,
            .ident => blk: {
                const text = self.tokens[prev].slice(self.source);
                break :blk unary_context_keywords.has(text);
            },
            else => false,
        };
    }

    /// True when a leading `/` should parse as unary `slash_prefix` (not as
    /// the start of an infix slash expression).  Restricted to the same
    /// unary-operator contexts as `+`/`-`, but only when the previous
    /// non-trivia token is `(`, `,`, or another `/` produced by an
    /// enclosing slash expression.
    fn isSlashUnaryPrefixContext(self: *const Parser) bool {
        if (!self.isUnaryContext()) return false;
        if (self.pos == 0) return false;
        var prev = self.pos - 1;
        while (prev > 0) : (prev -= 1) {
            const t = self.tokens[prev].tag;
            if (t != .whitespace and t != .newline and t != .comment) break;
        }
        return switch (self.tokens[prev].tag) {
            .lparen, .comma, .slash => true,
            else => false,
        };
    }

    /// Tokens that cannot start or continue an expression -- the Pratt
    /// loop must not consume these.
    fn isExpressionTerminator(tag: Token.Tag) bool {
        return switch (tag) {
            .eof,
            .semicolon,
            .rbrace,
            .rparen,
            .rbracket,
            .comma,
            => true,
            else => false,
        };
    }

    fn parsePrimary(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        self.skipWhitespaceAndComments();
        if (self.isAtEnd()) return error.UnexpectedEof;
        const tok = self.current();
        const head = switch (tok.tag) {
            .number => try self.parseNumberAtom(ast),
            .string => try self.parseStringAtom(ast),
            .ident => try self.parseIdentAtom(ast),
            .dollar_ident => try self.parseVariableAtom(ast),
            .lparen => try self.parseParenOrMap(ast),
            .lbracket => try self.parseBracketedList(ast),
            .hash_lbrace => try self.parseStandaloneInterp(ast),
            .hash => try self.parseHashAtom(ast),
            .ampersand => {
                // `&` in value context is the parent selector and must NOT
                // fold with an adjacent ident (`&bar`  ->  `& bar`, not `"&bar"`).
                return try self.parseAmpersandAtom(ast);
            },
            .percent => try self.parsePercentIdentAtom(ast),
            // A leading `.` in expression position is only valid as the
            // start of a number literal (e.g. `.5`), and the lexer emits
            // `.number` for that case.  A bare `.dot` is otherwise
            // ambiguous -- it could be the leading dot of a no-namespace
            // member call (`.member()` -- ill-formed Sass that official Sass CLI
            // rejects with `Expected digit.`), or it could be a CSS-ish
            // construct like `url(../test.png)` that the surrounding
            // declaration-value capture path can recover via raw text.
            //
            // Disambiguate with a narrow look-ahead: when the next two
            // tokens are `ident` then `lparen` glued to it, this is a
            // `.member(` member-call shape -- emit a HardSyntaxError so
            // the value path does not fall back to raw text.  Otherwise
            // return a regular SyntaxError so the existing recovery
            // (raw declaration capture / outer-expression fallback)
            // continues to work.
            .dot => {
                if (self.pos + 2 < self.tokens.len and
                    self.tokens[self.pos + 1].tag == .ident and
                    self.tokens[self.pos + 2].tag == .lparen and
                    self.tokens[self.pos + 1].span.start == tok.span.end and
                    self.tokens[self.pos + 2].span.start == self.tokens[self.pos + 1].span.end)
                {
                    return error.HardSyntaxError;
                }
                return error.SyntaxError;
            },
            else => return error.SyntaxError,
        };
        return self.parseTrailingSchema(ast, head);
    }

    /// Sass identifier-schema folding for expression context.
    ///
    /// When a primary atom is followed (with no intervening whitespace)
    /// by another schema-eligible token -- `ident`, `number`, or
    /// `#{...}` interpolation -- fold the run into a single
    /// `expr_string_interp` (unquoted) node.  This matches official Sass CLI
    /// behaviour for cases like `lschema_#{ritlp}` (ident + adjacent
    /// interp) and `#{1}0` (interp + adjacent number) which together
    /// form a single string-schema value.
    ///
    /// Only ident-leading and interp-leading heads start a schema.
    /// Number heads do NOT fold a trailing interp (the trailing `#{...}`
    /// becomes a separate space-list element), matching the historical
    /// non-conformant Sass behaviour exercised by
    /// `non_conformant/parser/operations/.../pairs.hrx`.
    fn parseTrailingSchema(
        self: *Parser,
        ast: *Ast,
        head_node: NodeIndex,
    ) ParseError!NodeIndex {
        const head = ast.getNode(head_node);
        const head_starts_schema = switch (head.tag) {
            .expr_unquoted_ident, .expr_interp => true,
            else => false,
        };
        if (!head_starts_schema) return head_node;

        // Adjacency: the next token must start exactly where the head
        // ended -- no whitespace, newline, or comment in between.
        if (self.pos >= self.tokens.len) return head_node;
        const next = self.tokens[self.pos];
        if (next.span.start != head.span_end) return head_node;
        if (!isSchemaContinuation(next.tag)) return head_node;

        // Build the schema parts list.  Start with the head itself.
        var parts: std.ArrayListUnmanaged(u32) = .empty;
        defer parts.deinit(self.allocator);

        switch (head.tag) {
            .expr_unquoted_ident => {
                // Head is a literal: payload is the InternId of the text.
                try parts.append(self.allocator, 0); // kind = literal
                try parts.append(self.allocator, head.payload);
            },
            .expr_interp => {
                try parts.append(self.allocator, 1); // kind = interp
                try parts.append(self.allocator, head_node.toU32());
            },
            else => unreachable,
        }

        var span_end = head.span_end;
        var prev_end = head.span_end;
        while (self.pos < self.tokens.len) {
            const tok = self.tokens[self.pos];
            if (tok.span.start != prev_end) break;
            switch (tok.tag) {
                .ident => {
                    self.advance();
                    const id = try self.intern_pool.intern(tok.slice(self.source));
                    try parts.append(self.allocator, 0);
                    try parts.append(self.allocator, @intFromEnum(id));
                    prev_end = tok.span.end;
                    span_end = tok.span.end;
                },
                .number => {
                    // Numbers fold into schemas as their lexical text.
                    // Signed numbers split out their sign character as
                    // a separate literal joiner -- the lexer eagerly
                    // combines `-1` into one signed-number token, but
                    // inside a schema such as `#{10}-1#{0}` the `-`
                    // logically belongs to the schema joiner and `1`
                    // is the next chunk.  The split applies only when
                    // the sign is `-`: `+1` after an interp/ident is
                    // the start of a binary expression (`#{X}+1`)
                    // because `+` does not have an identifier-like
                    // role in schemas.
                    const num_text = tok.slice(self.source);
                    if (num_text.len > 0 and num_text[0] == '+') break;
                    if (num_text.len > 0 and num_text[0] == '-') {
                        // Split the leading `-` off as a separate
                        // literal part, then fall through and consume
                        // the unsigned digits.  We re-intern the two
                        // pieces so each part keeps its own offset
                        // for source-map purposes.
                        const dash_id = try self.intern_pool.intern(num_text[0..1]);
                        try parts.append(self.allocator, 0);
                        try parts.append(self.allocator, @intFromEnum(dash_id));
                        const digits_id = try self.intern_pool.intern(num_text[1..]);
                        try parts.append(self.allocator, 0);
                        try parts.append(self.allocator, @intFromEnum(digits_id));
                        self.advance();
                        prev_end = tok.span.end;
                        span_end = tok.span.end;
                        continue;
                    }
                    self.advance();
                    const id = try self.intern_pool.intern(num_text);
                    try parts.append(self.allocator, 0);
                    try parts.append(self.allocator, @intFromEnum(id));
                    prev_end = tok.span.end;
                    span_end = tok.span.end;
                },
                .hash_lbrace => {
                    const interp_node = try self.parseStandaloneInterp(ast);
                    const interp = ast.getNode(interp_node);
                    try parts.append(self.allocator, 1);
                    try parts.append(self.allocator, interp_node.toU32());
                    prev_end = interp.span_end;
                    span_end = interp.span_end;
                },
                .minus => {
                    // `-` joins schema parts when it sits between two
                    // adjacent schema-eligible chunks (`#{X}-#{Y}`,
                    // `lschema-#{Y}`, `#{X}-name`).  When the token
                    // following `-` is whitespace / EOF / a statement
                    // terminator, keep it as a trailing literal in the
                    // schema (`#{X}- ` becomes `"X-"` followed by
                    // space-list continuation).  When the next token
                    // is something a schema cannot absorb (function
                    // call paren, signed number, etc.), back off and
                    // let the caller re-process the `-`.
                    if (self.pos + 1 >= self.tokens.len) {
                        // Trailing `-` at EOF -- absorb.
                        self.advance();
                        const id = try self.intern_pool.intern(tok.slice(self.source));
                        try parts.append(self.allocator, 0);
                        try parts.append(self.allocator, @intFromEnum(id));
                        prev_end = tok.span.end;
                        span_end = tok.span.end;
                        break;
                    }
                    const after = self.tokens[self.pos + 1];
                    const consume_dash = switch (after.tag) {
                        // Whitespace / newline / comment after `-`  ->
                        // schema ends at the `-` (next atom is
                        // space-list separated).
                        .whitespace, .newline, .comment => true,
                        // Statement / list / call terminators  ->  schema
                        // ends at the `-`.
                        .semicolon, .rbrace, .rparen, .rbracket, .comma, .eof => true,
                        // Adjacent ident or interpolation  ->  continue
                        // schema with `-` joiner.
                        .ident, .hash_lbrace => true,
                        // Adjacent number: only unsigned (signed
                        // numbers belong to a binary expression).
                        .number => blk: {
                            const t = after.slice(self.source);
                            if (t.len > 0 and (t[0] == '+' or t[0] == '-')) break :blk false;
                            break :blk true;
                        },
                        else => false,
                    };
                    if (!consume_dash) break;

                    self.advance();
                    const id = try self.intern_pool.intern(tok.slice(self.source));
                    try parts.append(self.allocator, 0);
                    try parts.append(self.allocator, @intFromEnum(id));
                    prev_end = tok.span.end;
                    span_end = tok.span.end;
                },
                else => break,
            }
        }

        // No actual fold happened (only the head part) -- return head as-is.
        if (parts.items.len <= 2) return head_node;

        // Emit expr_string_interp with quoted=false.
        const part_count: u32 = @intCast(parts.items.len / 2);
        const extra_off = try ast.appendExtraU32(part_count);
        for (parts.items) |v| {
            _ = try ast.appendExtraU32(v);
        }
        return try ast.addNode(.{
            .tag = .expr_string_interp,
            .flags = 0, // unquoted schema
            .payload = extra_off,
            .span_start = head.span_start,
            .span_end = span_end,
        });
    }

    /// Tokens that may continue an identifier-schema fold when adjacent
    /// (no whitespace/comment) to the previous schema part.  `.minus`
    /// is included because a `-` between two adjacent schema chunks
    /// (`#{X}-#{Y}`) becomes part of the schema string.  The fold
    /// loop applies further checks to decide whether to actually
    /// consume the `-`.
    fn isSchemaContinuation(tag: Token.Tag) bool {
        return switch (tag) {
            .ident, .number, .hash_lbrace, .minus => true,
            else => false,
        };
    }

    fn minusStartsInterpolatedSchema(self: *const Parser, minus_pos: usize) bool {
        if (minus_pos + 2 >= self.tokens.len) return false;
        const minus_tok = self.tokens[minus_pos];
        if (minus_tok.tag != .minus) return false;
        const ident_tok = self.tokens[minus_pos + 1];
        const interp_tok = self.tokens[minus_pos + 2];
        if (ident_tok.tag != .ident or interp_tok.tag != .hash_lbrace) return false;
        if (ident_tok.span.start != minus_tok.span.end) return false;
        if (interp_tok.span.start != ident_tok.span.end) return false;
        return true;
    }

    fn previousSignificantTokenTag(self: *const Parser, pos: usize) ?Token.Tag {
        if (pos == 0) return null;
        var i = pos;
        while (i > 0) {
            i -= 1;
            const t = self.tokens[i].tag;
            if (t != .whitespace and t != .newline and t != .comment) return t;
        }
        return null;
    }

    /// Parse a bare `&` parent-selector reference.  Emits an
    /// `expr_unquoted_ident` whose span covers the `&` token; the
    /// legacy evaluator's text-based fallback resolves it to the
    /// current parent selector value.
    fn parseAmpersandAtom(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const tok = self.current();
        std.debug.assert(tok.tag == .ampersand);
        self.advance();
        const id = try self.intern_pool.intern("&");
        return try ast.addNode(.{
            .tag = .expr_unquoted_ident,
            .flags = 0,
            .payload = @intFromEnum(id),
            .span_start = tok.span.start,
            .span_end = tok.span.end,
        });
    }

    fn parsePercentIdentAtom(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const tok = self.current();
        std.debug.assert(tok.tag == .percent);
        self.advance();
        const id = try self.intern_pool.intern("%");
        return try ast.addNode(.{
            .tag = .expr_unquoted_ident,
            .flags = 0,
            .payload = @intFromEnum(id),
            .span_start = tok.span.start,
            .span_end = tok.span.end,
        });
    }

    /// Tokens that can start a primary atom.  Used by
    /// `parseSpaceListOrSingle` to decide whether a space-separated
    /// continuation is available. Conservative -- must stay in sync
    /// with `parsePrimary`'s accepted dispatch set.
    fn canStartAtom(tag: Token.Tag) bool {
        return switch (tag) {
            .number,
            .string,
            .ident,
            .dollar_ident,
            .lparen,
            .lbracket,
            .hash_lbrace,
            .hash,
            .minus,
            .plus,
            .ampersand,
            .percent,
            => true,
            else => false,
        };
    }

    /// Parse a standalone `#{expr}` interpolation.  Emits `expr_interp`
    /// wrapping the inner expression.  The inner expression is parsed
    /// as a full comma-list expression (Sass allows lists and maps
    /// inside interpolation).
    fn parseStandaloneInterp(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const open_tok = self.current();
        std.debug.assert(open_tok.tag == .hash_lbrace);
        self.advance(); // skip #{
        self.skipWhitespaceAndComments();

        // `#{}` (empty interpolation) is a syntax error in Sass.
        if (!self.isAtEnd() and self.current().tag == .rbrace) {
            return error.SyntaxError;
        }

        const prev_interp_mode = self.in_interpolation_body;
        self.in_interpolation_body = true;
        defer self.in_interpolation_body = prev_interp_mode;
        const inner = try self.parseCommaListOrSingle(ast);
        self.unquoteNodeForInterpolation(ast, inner);

        self.skipWhitespaceAndComments();
        if (self.isAtEnd() or self.current().tag != .rbrace) {
            return error.SyntaxError;
        }
        const close_end = self.current().span.end;
        self.advance(); // skip }

        // If the `#{...}` is immediately followed (no source-byte gap) by
        // another ident, number, or `#{...}`, treat the whole sequence as
        // a single interpolated identifier.  Emit `expr_unquoted_ident`
        // covering the joined source span -- eval2 will run
        // `interpolateHashBracesOnly2` on the raw text and produce a
        // single concatenated string value.
        var span_end_total: u32 = close_end;
        var has_adjacent_tail = false;
        while (self.pos < self.tokens.len) {
            const next = self.tokens[self.pos];
            if (next.span.start != span_end_total) break;
            if (next.tag == .hash_lbrace) {
                self.advance();
                var depth: usize = 1;
                while (self.pos < self.tokens.len) {
                    const t = self.tokens[self.pos];
                    if (t.tag == .lbrace or t.tag == .hash_lbrace) {
                        depth += 1;
                    } else if (t.tag == .rbrace) {
                        depth -= 1;
                        if (depth == 0) {
                            span_end_total = t.span.end;
                            self.advance();
                            break;
                        }
                    }
                    self.advance();
                }
                if (depth != 0) return error.SyntaxError;
                has_adjacent_tail = true;
            } else if (next.tag == .ident or next.tag == .number) {
                // Signed numbers (`+1` / `-1`) are binary operator
                // right operands, not schema continuations.  Letting
                // them attach here turns `#{10}+1#{0}` into a raw
                // `#{10}+1#{0}` unquoted-ident, which loses the
                // binary-add semantics (official Sass CLI evaluates `#{10}+1`
                // as string concat  ->  `"101"`). Bail and let the
                // outer Pratt loop pick the sign up as implicit add /
                // sub.  The lexer preserves the sign inside the number
                // token text, so a bare digit only appears here when
                // the user wrote no sign.
                if (next.tag == .number) {
                    const ntxt = next.slice(self.source);
                    if (ntxt.len > 0 and (ntxt[0] == '+' or ntxt[0] == '-')) break;
                }
                span_end_total = next.span.end;
                self.advance();
                has_adjacent_tail = true;
            } else {
                break;
            }
        }

        // Interpolated function call: `#{...}(args)` or
        // `#{...}name(args)` -- when the joined ident is immediately
        // followed by `(`, treat it as a function call whose name is
        // the joined source text (with `#{}` resolved at eval time).
        if (self.pos < self.tokens.len and
            self.tokens[self.pos].tag == .lparen and
            self.tokens[self.pos].span.start == span_end_total)
        {
            const joined = self.source[open_tok.span.start..span_end_total];
            const name_id = try self.intern_pool.intern(joined);
            return try self.parseFunctionCallBody(ast, name_id, .none, open_tok.span.start);
        }

        if (has_adjacent_tail) {
            const joined = self.source[open_tok.span.start..span_end_total];
            const id = try self.intern_pool.intern(joined);
            return try ast.addNode(.{
                .tag = .expr_unquoted_ident,
                .flags = 0,
                .payload = @intFromEnum(id),
                .span_start = open_tok.span.start,
                .span_end = span_end_total,
            });
        }

        return try ast.addNode(.{
            .tag = .expr_interp,
            .flags = 0,
            .payload = inner.toU32(),
            .span_start = open_tok.span.start,
            .span_end = close_end,
        });
    }

    /// Sass interpolation (`#{...}`) evaluates nested strings in
    /// unquoted context.  Normalize string nodes recursively so the
    /// VM doesn't carry quote flags across the interpolation boundary.
    fn unquoteNodeForInterpolation(
        self: *Parser,
        ast: *Ast,
        node: NodeIndex,
    ) void {
        if (node == .none) return;
        const n = ast.getNode(node);

        switch (n.tag) {
            .expr_string_literal, .expr_string_interp => {
                if (!self.nodeContainsStringBackslash(ast, node)) {
                    ast.setFlags(node, n.flags & ~@as(u8, 0b0000_0001));
                }
            },
            else => {},
        }

        switch (n.tag) {
            .expr_interp, .expr_paren => {
                const child: NodeIndex = @enumFromInt(n.payload);
                unquoteNodeForInterpolation(self, ast, child);
            },
            .expr_unary_op => {
                const off: ExtraIndex = n.payload;
                const child: NodeIndex = @enumFromInt(ast.getExtraU32(off));
                unquoteNodeForInterpolation(self, ast, child);
            },
            .expr_binary_op, .expr_slash_expr => {
                const off: ExtraIndex = n.payload;
                const lhs: NodeIndex = @enumFromInt(ast.getExtraU32(off));
                const rhs: NodeIndex = @enumFromInt(ast.getExtraU32(off + 1));
                unquoteNodeForInterpolation(self, ast, lhs);
                unquoteNodeForInterpolation(self, ast, rhs);
            },
            .expr_comma_list, .expr_space_list, .expr_bracketed_list => {
                const off: ExtraIndex = n.payload;
                const count = ast.getExtraU32(off);
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const child: NodeIndex = @enumFromInt(ast.getExtraU32(off + 1 + i));
                    unquoteNodeForInterpolation(self, ast, child);
                }
            },
            .expr_map_literal => {
                const off: ExtraIndex = n.payload;
                const pair_count = ast.getExtraU32(off);
                const key_start: ExtraIndex = off + 1;
                const val_start: ExtraIndex = key_start + pair_count;
                var i: u32 = 0;
                while (i < pair_count) : (i += 1) {
                    const key_node: NodeIndex = @enumFromInt(ast.getExtraU32(key_start + i));
                    const val_node: NodeIndex = @enumFromInt(ast.getExtraU32(val_start + i));
                    unquoteNodeForInterpolation(self, ast, key_node);
                    unquoteNodeForInterpolation(self, ast, val_node);
                }
            },
            .expr_func_call => {
                // Preserve quoted-string semantics while evaluating function
                // arguments. Interpolation unquotes the final value when it is
                // stringified, but builtins such as color.channel($channel)
                // observe whether their string arguments were quoted.
            },
            else => {},
        }
    }

    fn nodeContainsStringBackslash(
        self: *Parser,
        ast: *Ast,
        node: NodeIndex,
    ) bool {
        if (node == .none) return false;
        const n = ast.getNode(node);

        switch (n.tag) {
            .expr_string_literal => {
                const id: InternId = @enumFromInt(ast.getExtraU32(n.payload));
                return std.mem.findScalar(u8, self.intern_pool.get(id), '\\') != null;
            },
            .expr_string_interp => {
                const off: ExtraIndex = n.payload;
                const part_count = ast.getExtraU32(off);
                var i: u32 = 0;
                while (i < part_count) : (i += 1) {
                    const kind = ast.getExtraU32(off + 1 + i * 2);
                    const val = ast.getExtraU32(off + 2 + i * 2);
                    if (kind == 0) {
                        const id: InternId = @enumFromInt(val);
                        if (std.mem.findScalar(u8, self.intern_pool.get(id), '\\') != null) return true;
                    } else if (kind == 1) {
                        const child: NodeIndex = @enumFromInt(val);
                        if (self.nodeContainsStringBackslash(ast, child)) return true;
                    }
                }
                return false;
            },
            .expr_interp, .expr_paren => {
                const child: NodeIndex = @enumFromInt(n.payload);
                return self.nodeContainsStringBackslash(ast, child);
            },
            .expr_unary_op => {
                const off: ExtraIndex = n.payload;
                const child: NodeIndex = @enumFromInt(ast.getExtraU32(off));
                return self.nodeContainsStringBackslash(ast, child);
            },
            .expr_binary_op, .expr_slash_expr => {
                const off: ExtraIndex = n.payload;
                const lhs: NodeIndex = @enumFromInt(ast.getExtraU32(off));
                const rhs: NodeIndex = @enumFromInt(ast.getExtraU32(off + 1));
                return self.nodeContainsStringBackslash(ast, lhs) or self.nodeContainsStringBackslash(ast, rhs);
            },
            .expr_comma_list, .expr_space_list, .expr_bracketed_list => {
                const off: ExtraIndex = n.payload;
                const count = ast.getExtraU32(off);
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const child: NodeIndex = @enumFromInt(ast.getExtraU32(off + 1 + i));
                    if (self.nodeContainsStringBackslash(ast, child)) return true;
                }
                return false;
            },
            .expr_map_literal => {
                const off: ExtraIndex = n.payload;
                const pair_count = ast.getExtraU32(off);
                const key_start: ExtraIndex = off + 1;
                const val_start: ExtraIndex = key_start + pair_count;
                var i: u32 = 0;
                while (i < pair_count) : (i += 1) {
                    const key: NodeIndex = @enumFromInt(ast.getExtraU32(key_start + i));
                    const val: NodeIndex = @enumFromInt(ast.getExtraU32(val_start + i));
                    if (self.nodeContainsStringBackslash(ast, key) or self.nodeContainsStringBackslash(ast, val)) return true;
                }
                return false;
            },
            .expr_func_call => {
                const off: ExtraIndex = n.payload;
                const arg_count = ast.getExtraU32(off + 2);
                const arg_nodes_start: ExtraIndex = off + 3;
                var i: u32 = 0;
                while (i < arg_count) : (i += 1) {
                    const arg_node: NodeIndex = @enumFromInt(ast.getExtraU32(arg_nodes_start + i));
                    if (self.nodeContainsStringBackslash(ast, arg_node)) return true;
                }
                return false;
            },
            else => return false,
        }
    }

    /// Re-lex and parse a slice of source text as an expression.
    /// Used for string-interpolation content like `"a#{b + 1}c"`,
    /// where the interp body lives inside a `.string` token and is
    /// not directly represented in `self.tokens`.
    ///
    /// All nodes added during the sub-parse have their span
    /// coordinates (which are relative to `expr_source`) offset by
    /// `byte_offset` so they reference the outer `self.source`
    /// correctly -- otherwise source-map / diagnostic output would
    /// point at the wrong place.
    fn parseInterpolationSubExpr(
        self: *Parser,
        ast: *Ast,
        expr_source: []const u8,
        byte_offset: u32,
    ) ParseError!NodeIndex {
        var lexer = lexer_mod.Lexer.init(self.allocator, expr_source);
        defer lexer.deinit();
        const sub_tokens = lexer.tokenize() catch return error.SyntaxError;

        var sub = Parser.init(self.allocator, self.intern_pool, sub_tokens, expr_source);
        sub.is_indented_syntax = self.is_indented_syntax;
        sub.in_interpolation_body = true;
        defer sub.deinit();

        const nodes_before = ast.nodes.len;
        const result = try sub.parseExpression(ast);
        const nodes_after = ast.nodes.len;

        if (byte_offset > 0) {
            const starts = ast.nodes.items(.span_start);
            const ends = ast.nodes.items(.span_end);
            var i = nodes_before;
            while (i < nodes_after) : (i += 1) {
                starts[i] += byte_offset;
                ends[i] += byte_offset;
            }
        }

        return result;
    }

    /// Parse `( ... )`.  The opening paren at `self.pos` disambiguates
    /// as one of:
    ///   - empty:        `()`           ->   empty `expr_comma_list`
    ///   - single:       `(x)`          ->   `expr_paren` wrapping `x`
    ///   - comma list:   `(x, y, ...)`  ->   `expr_comma_list` (no paren wrap)
    ///   - space list:   `(x y z)`      ->   `expr_space_list` (no paren wrap)
    ///   - map literal:  `(k: v, ...)`  ->   `expr_map_literal`
    ///
    /// The map-vs-list discriminator is the token that follows the
    /// first parsed element: `:`  =>  map, otherwise list.
    fn parseParenOrMap(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const open_tok = self.current();
        std.debug.assert(open_tok.tag == .lparen);
        self.advance(); // skip (
        self.skipWhitespaceAndComments();

        // Empty parens: `()`  ->  empty comma_list.
        if (!self.isAtEnd() and self.current().tag == .rparen) {
            const close_end = self.current().span.end;
            self.advance();
            return try emitListNode(
                ast,
                .expr_comma_list,
                0,
                &.{},
                open_tok.span.start,
                close_end,
            );
        }

        // Parse the first element as a space list (but not a comma
        // list -- commas separate paren elements, not join them).
        const first = try self.parseSpaceListOrSingle(ast);
        self.skipWhitespaceAndComments();

        // Map literal: first element is a key, next token is `:`.
        if (!self.isAtEnd() and self.current().tag == .colon) {
            return try self.parseMapTail(ast, first, open_tok.span.start);
        }

        // Comma list: `(first, ...)`
        if (!self.isAtEnd() and self.current().tag == .comma) {
            var items: std.ArrayListUnmanaged(NodeIndex) = .empty;
            defer items.deinit(self.allocator);
            try items.append(self.allocator, first);

            while (!self.isAtEnd() and self.current().tag == .comma) {
                self.advance();
                self.skipWhitespaceAndComments();
                if (self.isAtEnd()) break;
                if (self.current().tag == .rparen) break; // trailing comma
                const next = try self.parseSpaceListOrSingle(ast);
                try items.append(self.allocator, next);
                self.skipWhitespaceAndComments();
            }

            if (self.isAtEnd() or self.current().tag != .rparen) {
                // `(a, b: c)` -- once we have committed to a comma list
                // (i.e. saw a comma), subsequent `:` cannot retroactively
                // turn this into a map.  official Sass CLI: "expected ')'.".
                // Hard error: do not let the declaration-value fallback
                // swallow this as a raw CSS value.
                if (!self.isAtEnd() and self.current().tag == .colon) {
                    return error.HardSyntaxError;
                }
                return error.SyntaxError;
            }
            const close_end = self.current().span.end;
            self.advance();
            return try emitListNode(
                ast,
                .expr_comma_list,
                0,
                items.items,
                open_tok.span.start,
                close_end,
            );
        }

        // Otherwise: single expression wrapped in `expr_paren`.
        if (self.isAtEnd() or self.current().tag != .rparen) {
            return error.SyntaxError;
        }
        const close_end = self.current().span.end;
        self.advance();
        return try ast.addNode(.{
            .tag = .expr_paren,
            .flags = 0,
            .payload = first.toU32(),
            .span_start = open_tok.span.start,
            .span_end = close_end,
        });
    }

    /// Continuation of `parseParenOrMap` once a map has been detected.
    /// `first_key` is the already-parsed first key; the current token
    /// must be `:`.
    fn parseMapTail(
        self: *Parser,
        ast: *Ast,
        first_key: NodeIndex,
        span_start: u32,
    ) ParseError!NodeIndex {
        std.debug.assert(self.current().tag == .colon);
        self.advance(); // skip :
        self.skipWhitespaceAndComments();

        const first_val = try self.parseSpaceListOrSingle(ast);

        var keys: std.ArrayListUnmanaged(NodeIndex) = .empty;
        defer keys.deinit(self.allocator);
        var vals: std.ArrayListUnmanaged(NodeIndex) = .empty;
        defer vals.deinit(self.allocator);
        try keys.append(self.allocator, first_key);
        try vals.append(self.allocator, first_val);

        self.skipWhitespaceAndComments();
        while (!self.isAtEnd() and self.current().tag == .comma) {
            self.advance();
            self.skipWhitespaceAndComments();
            if (self.isAtEnd()) break;
            if (self.current().tag == .rparen) break; // trailing comma
            const k = try self.parseSpaceListOrSingle(ast);
            self.skipWhitespaceAndComments();
            if (self.isAtEnd() or self.current().tag != .colon) {
                return error.SyntaxError;
            }
            self.advance(); // skip :
            self.skipWhitespaceAndComments();
            const v = try self.parseSpaceListOrSingle(ast);
            try keys.append(self.allocator, k);
            try vals.append(self.allocator, v);
            self.skipWhitespaceAndComments();
        }

        if (self.isAtEnd() or self.current().tag != .rparen) {
            return error.SyntaxError;
        }
        const close_end = self.current().span.end;
        self.advance();

        // emit expr_map_literal with layout:
        //   [len: u32, key_nodes..., value_nodes...]
        const n: u32 = @intCast(keys.items.len);
        const extra_off = try ast.appendExtraU32(n);
        for (keys.items) |k| {
            _ = try ast.appendExtraU32(k.toU32());
        }
        for (vals.items) |v| {
            _ = try ast.appendExtraU32(v.toU32());
        }

        return try ast.addNode(.{
            .tag = .expr_map_literal,
            .flags = 0,
            .payload = extra_off,
            .span_start = span_start,
            .span_end = close_end,
        });
    }

    /// Parse `[ ... ]`.  Always emits an `expr_bracketed_list`, even
    /// when the list has zero or one item (the brackets themselves
    /// carry the list information).
    fn parseBracketedList(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const open_tok = self.current();
        std.debug.assert(open_tok.tag == .lbracket);
        self.advance(); // skip [
        self.skipWhitespaceAndComments();

        var items: std.ArrayListUnmanaged(NodeIndex) = .empty;
        defer items.deinit(self.allocator);
        var flags: u8 = 0;

        if (!self.isAtEnd() and self.current().tag != .rbracket) {
            // Collect comma-separated items.  Inside brackets, commas
            // separate list elements; each element is a space list.
            while (true) {
                const item = try self.parseSpaceListOrSingle(ast);
                try items.append(self.allocator, item);
                self.skipWhitespaceAndComments();
                if (self.isAtEnd()) break;
                if (self.current().tag != .comma) break;
                self.advance();
                self.skipWhitespaceAndComments();
                // After the comma, either the list is closed or there
                // is another item.  EOF here means the bracket was
                // never closed -- the outer rbracket check will report
                // the error.
                if (self.isAtEnd()) break;
                if (self.current().tag == .rbracket) {
                    flags |= LIST_FLAG_TRAILING_COMMA;
                    break;
                }
            }
        }

        if (self.isAtEnd() or self.current().tag != .rbracket) {
            return error.SyntaxError;
        }
        const close_end = self.current().span.end;
        self.advance();

        return try emitListNode(
            ast,
            .expr_bracketed_list,
            flags,
            items.items,
            open_tok.span.start,
            close_end,
        );
    }

    /// Parse a `.number` token plus an optional adjacent unit token
    /// (no whitespace between them).  Emits `expr_number_literal`.
    ///
    /// extra layout: `{ value_f64_lo: u32, value_f64_hi: u32, unit_id: u32 }`
    fn parseNumberAtom(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const num_tok = self.current();
        std.debug.assert(num_tok.tag == .number);
        self.advance();

        // Adjacency check: the unit token must be immediately next with no
        // whitespace/newline between.  The lexer does not synthesise a
        // trivia token when the unit is glued, so self.tokens[self.pos]
        // *is* the unit candidate.
        //
        // CSS custom property names (`--foo`) and SCSS dash-only idents
        // (`---`) are NOT valid number units -- `1--em` parses as the
        // space-list `1 --em`, not as a number with unit `--em`.
        // official Sass CLI excludes idents that start with `--` from the
        // unit slot here.  See `libsass-closed-issues/issue_1526.hrx`.
        var unit_id: InternId = .none;
        var end: u32 = num_tok.span.end;
        if (self.pos < self.tokens.len) {
            const next = self.tokens[self.pos];
            if (next.tag == .ident) {
                const unit_text = next.slice(self.source);
                if (!std.mem.startsWith(u8, unit_text, "--")) {
                    unit_id = try self.intern_pool.intern(unit_text);
                    end = next.span.end;
                    self.advance();
                }
            } else if (next.tag == .percent) {
                unit_id = try self.intern_pool.intern("%");
                end = next.span.end;
                self.advance();
            }
        }

        // Parse the numeric text into f64.  Zig's parseFloat handles signs,
        // decimal points, and scientific notation.
        const num_text = num_tok.slice(self.source);
        const value = std.fmt.parseFloat(f64, num_text) catch return error.SyntaxError;

        // extra pool: [f64 lo, f64 hi, unit_id u32]
        const extra_off = try ast.appendExtraF64(value);
        _ = try ast.appendExtraU32(@intFromEnum(unit_id));

        return try ast.addNode(.{
            .tag = .expr_number_literal,
            .flags = 0,
            .payload = extra_off,
            .span_start = num_tok.span.start,
            .span_end = end,
        });
    }

    fn parseSignedNumberMagnitudeAtom(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const num_tok = self.current();
        std.debug.assert(num_tok.tag == .number);
        const num_text = num_tok.slice(self.source);
        std.debug.assert(num_text.len >= 2 and (num_text[0] == '+' or num_text[0] == '-'));
        self.advance();

        var unit_id: InternId = .none;
        var end: u32 = num_tok.span.end;
        if (self.pos < self.tokens.len) {
            const next = self.tokens[self.pos];
            if (next.tag == .ident) {
                const unit_text = next.slice(self.source);
                if (!std.mem.startsWith(u8, unit_text, "--")) {
                    unit_id = try self.intern_pool.intern(unit_text);
                    end = next.span.end;
                    self.advance();
                }
            } else if (next.tag == .percent) {
                unit_id = try self.intern_pool.intern("%");
                end = next.span.end;
                self.advance();
            }
        }

        const value = std.fmt.parseFloat(f64, num_text[1..]) catch return error.SyntaxError;
        const extra_off = try ast.appendExtraF64(value);
        _ = try ast.appendExtraU32(@intFromEnum(unit_id));

        return try ast.addNode(.{
            .tag = .expr_number_literal,
            .flags = 0,
            .payload = extra_off,
            .span_start = num_tok.span.start,
            .span_end = end,
        });
    }

    /// Parse a `.string` token.  Emits `expr_string_literal` if there
    /// is no `#{...}` interpolation, otherwise dispatches to
    /// `parseStringWithInterp` which emits `expr_string_interp`.
    fn parseStringAtom(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const tok = self.current();
        std.debug.assert(tok.tag == .string);
        self.advance();

        const text = tok.slice(self.source);

        // Fast path: no interpolation  ->  simple string literal.
        if (std.mem.find(u8, text, "#{") == null) {
            var content: []const u8 = text;
            var quoted: bool = false;
            if (text.len >= 2 and
                (text[0] == '"' or text[0] == '\'') and
                text[text.len - 1] == text[0])
            {
                content = text[1 .. text.len - 1];
                quoted = true;
            }

            const str_id = try self.intern_pool.intern(content);
            const extra_off = try ast.appendExtraU32(@intFromEnum(str_id));
            var flags: u8 = 0;
            if (quoted) flags |= 0b0000_0001; // bit 0 = quoted

            return try ast.addNode(.{
                .tag = .expr_string_literal,
                .flags = flags,
                .payload = extra_off,
                .span_start = tok.span.start,
                .span_end = tok.span.end,
            });
        }

        // Slow path: scan the string body for `#{...}` and build an
        // `expr_string_interp` node with alternating literal/interp parts.
        return try self.parseStringWithInterp(ast, tok.span);
    }

    /// Walk a string-token's content to split out literal and
    /// interpolation segments.  Each interpolation body is re-lexed
    /// and parsed as a full expression via `parseInterpolationSubExpr`.
    ///
    /// Extra layout (matches design Section 2.3):
    ///   [part_count: u32,
    ///    kind_0: u32, value_0: u32,
    ///    kind_1: u32, value_1: u32,
    ///    ...]
    /// where kind 0 = literal (value is InternId) and kind 1 = interp
    /// (value is NodeIndex).
    fn parseStringWithInterp(
        self: *Parser,
        ast: *Ast,
        str_span: Span,
    ) ParseError!NodeIndex {
        // Determine the quote style and the content slice.
        const raw = str_span.slice(self.source);
        var quoted: bool = false;
        var content_start_off: u32 = 0;
        var content_end_off: u32 = @intCast(raw.len);
        if (raw.len >= 2 and
            (raw[0] == '"' or raw[0] == '\'') and
            raw[raw.len - 1] == raw[0])
        {
            quoted = true;
            content_start_off = 1;
            content_end_off = @intCast(raw.len - 1);
        }
        const content_start: u32 = str_span.start + content_start_off;
        const content_end: u32 = str_span.start + content_end_off;
        const content = self.source[content_start..content_end];

        // Collect parts as flat (kind, value) u32 pairs.
        var parts: std.ArrayListUnmanaged(u32) = .empty;
        defer parts.deinit(self.allocator);
        var saw_interp = false;

        var i: usize = 0;
        var lit_start: usize = 0;
        const clen = content.len;

        while (i < clen) {
            const c = content[i];

            // Escape: `\X` -- skip both characters.  Preserves the
            // escape byte so that `\#{...}` does not start an interp.
            if (c == '\\' and i + 1 < clen) {
                i += 2;
                continue;
            }

            // Interpolation start: `#{`
            if (c == '#' and i + 1 < clen and content[i + 1] == '{') {
                // Emit the accumulated literal part.
                if (i > lit_start) {
                    const lit_bytes = content[lit_start..i];
                    const lit_id = try self.intern_pool.intern(lit_bytes);
                    try parts.append(self.allocator, 0); // kind = literal
                    try parts.append(self.allocator, @intFromEnum(lit_id));
                }

                // Scan for the matching `}`, tracking nested braces
                // and embedded strings.
                const expr_start = i + 2;
                var depth: u32 = 1;
                var j: usize = expr_start;
                var in_str: u8 = 0;
                while (j < clen and depth > 0) {
                    const ch = content[j];
                    if (in_str != 0) {
                        if (ch == '\\' and j + 1 < clen) {
                            j += 2;
                            continue;
                        }
                        if (ch == in_str) in_str = 0;
                        j += 1;
                        continue;
                    }
                    // Outside any string: a `\X` escape (e.g. `\"` or `\'`)
                    // forms part of the expression's identifier and must
                    // not be mistaken for a string opener or close brace.
                    if (ch == '\\' and j + 1 < clen) {
                        j += 2;
                        continue;
                    }
                    if (self.advancePastCommentText(content, &j)) continue;
                    if (ch == '"' or ch == '\'') {
                        in_str = ch;
                        j += 1;
                        continue;
                    }
                    if (ch == '#' and j + 1 < clen and content[j + 1] == '{') {
                        depth += 1;
                        j += 2;
                        continue;
                    }
                    if (ch == '}') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                    j += 1;
                }

                if (depth != 0) return error.SyntaxError;

                // Parse the interpolation body as a sub-expression.
                const expr_bytes = content[expr_start..j];
                const sub_offset: u32 = content_start + @as(u32, @intCast(expr_start));
                const sub_node = try self.parseInterpolationSubExpr(
                    ast,
                    expr_bytes,
                    sub_offset,
                );
                self.unquoteNodeForInterpolation(ast, sub_node);
                saw_interp = true;
                try parts.append(self.allocator, 1); // kind = interp
                try parts.append(self.allocator, sub_node.toU32());

                i = j + 1; // step past the closing `}`
                lit_start = i;
                continue;
            }

            i += 1;
        }

        // Final literal part after the last interpolation.
        if (lit_start < clen) {
            const lit_bytes = content[lit_start..clen];
            const lit_id = try self.intern_pool.intern(lit_bytes);
            try parts.append(self.allocator, 0);
            try parts.append(self.allocator, @intFromEnum(lit_id));
        }

        // If every `#{...}` in the source turned out to be escaped,
        // fall back to a plain string literal (the fast path's simple
        // `indexOf("#{")` cannot distinguish escaped vs real starts).
        if (!saw_interp) {
            const lit_id = try self.intern_pool.intern(content);
            const fallback_off = try ast.appendExtraU32(@intFromEnum(lit_id));
            var lit_flags: u8 = 0;
            if (quoted) lit_flags |= 0b0000_0001;
            return try ast.addNode(.{
                .tag = .expr_string_literal,
                .flags = lit_flags,
                .payload = fallback_off,
                .span_start = str_span.start,
                .span_end = str_span.end,
            });
        }
        const part_count: u32 = @intCast(parts.items.len / 2);
        const extra_off = try ast.appendExtraU32(part_count);
        for (parts.items) |v| {
            _ = try ast.appendExtraU32(v);
        }

        var flags: u8 = 0;
        if (quoted) flags |= 0b0000_0001;

        return try ast.addNode(.{
            .tag = .expr_string_interp,
            .flags = flags,
            .payload = extra_off,
            .span_start = str_span.start,
            .span_end = str_span.end,
        });
    }

    /// Parse an `.ident` token.  Dispatches in priority order:
    ///   1. `true` / `false` / `null` keyword literals.
    ///   2. `ident(` -- function call (no namespace).
    ///   3. `ident . dollar_ident` -- namespaced variable. Bare `$` and
    ///      private (`_`-prefixed) members are syntax errors.
    ///   4. `ident . ident (` -- namespaced function call.
    ///   5. `ident . <other>` -- syntax error (official Sass CLI: "expected '('"
    ///      or "Expected identifier", depending on what follows the dot).
    ///   6. plain `expr_unquoted_ident` (with adjacent-token folding).
    ///
    /// Sass keywords are case-sensitive lowercase-only.
    fn parseIdentAtom(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const tok = self.current();
        std.debug.assert(tok.tag == .ident);
        const text = tok.slice(self.source);
        const ident_pos = self.pos;

        if (self.in_declaration_value_context and identHasTooHighUnicodeEscape(text)) {
            return error.HardSyntaxError;
        }

        if (std.mem.eql(u8, text, "true")) {
            self.advance();
            return try ast.addNode(.{
                .tag = .expr_bool_true,
                .flags = 0,
                .payload = 0,
                .span_start = tok.span.start,
                .span_end = tok.span.end,
            });
        }
        if (std.mem.eql(u8, text, "false")) {
            self.advance();
            return try ast.addNode(.{
                .tag = .expr_bool_false,
                .flags = 0,
                .payload = 0,
                .span_start = tok.span.start,
                .span_end = tok.span.end,
            });
        }
        if (std.mem.eql(u8, text, "null")) {
            self.advance();
            return try ast.addNode(.{
                .tag = .expr_null,
                .flags = 0,
                .payload = 0,
                .span_start = tok.span.start,
                .span_end = tok.span.end,
            });
        }

        // Consume the head ident.
        self.advance();

        // Function call: `ident(` -- no whitespace between.  The opening
        // paren must be the very next token.
        if (self.pos < self.tokens.len and self.tokens[self.pos].tag == .lparen) {
            if ((self.in_declaration_value_context and shouldTreatAsOpaqueCssFunctionInDecl(text)) or
                shouldTreatAsOpaqueCssFunctionInScript(text, self.hasInterpolationInCurrentCallParens()) or
                self.shouldTreatUrlRawPathAsOpaque(text))
            {
                return try self.parseOpaqueCssFunctionCallAsTextExpr(ast, ident_pos, text);
            }
            const name_id = try self.intern_pool.intern(text);
            return try self.parseFunctionCallBody(ast, name_id, .none, tok.span.start);
        }

        // Legacy CSS special form: progid:foo(...)
        // Treat as unquoted CSS function text in declaration values so silent
        // comments inside the arg list normalize the same way as other special
        // functions.
        if (self.in_declaration_value_context and std.ascii.eqlIgnoreCase(cssFunctionBaseName(text), "progid")) {
            if (self.pos < self.tokens.len and
                self.tokens[self.pos].tag == .colon and
                tok.span.end == self.tokens[self.pos].span.start)
            {
                var p = self.pos + 1;
                var prev_end = self.tokens[self.pos].span.end;
                var saw_ident = false;
                var expect_ident = true;
                scan_progid_chain: while (p < self.tokens.len and self.tokens[p].span.start == prev_end) : (p += 1) {
                    const chain_tok = self.tokens[p];
                    switch (chain_tok.tag) {
                        .ident => {
                            saw_ident = true;
                            expect_ident = false;
                            prev_end = chain_tok.span.end;
                        },
                        .dot => {
                            if (expect_ident) break :scan_progid_chain;
                            expect_ident = true;
                            prev_end = chain_tok.span.end;
                        },
                        .lparen => {
                            if (!saw_ident or expect_ident) break :scan_progid_chain;
                            self.pos = p; // now at '('
                            return try self.parseOpaqueCssFunctionCallAsTextExpr(ast, ident_pos, text);
                        },
                        else => break :scan_progid_chain,
                    }
                }
            }
        }

        // Namespaced reference: `ident . <something>` -- no whitespace
        // between the ident and the dot (the lexer emits `.dot` as its
        // own token).
        //
        // Splat carve-out: `ident...` (three consecutive dots) is the
        // spread argument syntax (e.g. `foo(one...)`).  Stop at the
        // bare ident here so the call-args parser sees the dots and
        // wraps the value in `expr_splat`.
        if (self.pos + 2 < self.tokens.len and
            self.tokens[self.pos].tag == .dot and
            self.tokens[self.pos + 1].tag == .dot and
            self.tokens[self.pos + 2].tag == .dot)
        {
            const id = try self.intern_pool.intern(text);
            return try ast.addNode(.{
                .tag = .expr_unquoted_ident,
                .flags = 0,
                .payload = @intFromEnum(id),
                .span_start = tok.span.start,
                .span_end = tok.span.end,
            });
        }
        if (self.pos < self.tokens.len and self.tokens[self.pos].tag == .dot) {
            const dot_pos = self.pos;
            self.advance(); // skip dot

            if (self.pos < self.tokens.len) {
                const after = self.tokens[self.pos];

                // ns.$var   ->   expr_namespaced_var
                if (after.tag == .dollar_ident) {
                    const var_text = after.slice(self.source);
                    std.debug.assert(var_text.len >= 1 and var_text[0] == '$');
                    // Bare `$` (no body)  ->  "Expected identifier".
                    // Hard error: don't fall back to raw capture.
                    if (var_text.len == 1) return error.HardSyntaxError;
                    // Private member access via namespace is a syntax
                    // error: `ns.$_member` (decl-time / parse-time).
                    if (var_text.len >= 2 and var_text[1] == '_') return error.HardSyntaxError;
                    const ns_id = try self.intern_pool.intern(text);
                    const name_id = try self.intern_pool.intern(var_text[1..]);
                    self.advance(); // consume dollar_ident

                    const extra_off = try ast.appendExtraU32(@intFromEnum(ns_id));
                    _ = try ast.appendExtraU32(@intFromEnum(name_id));

                    return try ast.addNode(.{
                        .tag = .expr_namespaced_var,
                        .flags = 0,
                        .payload = extra_off,
                        .span_start = tok.span.start,
                        .span_end = after.span.end,
                    });
                }

                // ns.name ... -- sub-ident after the dot.
                if (after.tag == .ident) {
                    const sub_text = after.slice(self.source);
                    self.advance(); // consume sub ident

                    // ns.name(   ->   namespaced function call.
                    if (self.pos < self.tokens.len and self.tokens[self.pos].tag == .lparen) {
                        const name_id = try self.intern_pool.intern(sub_text);
                        const ns_id = try self.intern_pool.intern(text);
                        return try self.parseFunctionCallBody(ast, name_id, ns_id, tok.span.start);
                    }

                    // Plain `ns.name` without parens.  Two cases:
                    //   * Inside a function-call argument list (e.g.
                    //     `url(blah.css)`) -- emit a joined
                    //     `expr_unquoted_ident` covering the full span
                    //     so CSS-like values keep working.
                    //   * At top-level value position -- this is a
                    //     malformed Sass namespace reference (official Sass CLI
                    //     reports `expected "("`). Hard error so the
                    //     declaration text node path does not absorb it.
                    if (self.call_arg_depth == 0) {
                        return error.HardSyntaxError;
                    }
                    const joined = self.source[tok.span.start..after.span.end];
                    const id = try self.intern_pool.intern(joined);
                    return try ast.addNode(.{
                        .tag = .expr_unquoted_ident,
                        .flags = 0,
                        .payload = @intFromEnum(id),
                        .span_start = tok.span.start,
                        .span_end = after.span.end,
                    });
                }

                // ns. followed by something other than ident or dollar
                // (e.g. `ns.()`, `ns..foo`, `ns. x`) -- clearly malformed
                // Sass member syntax.  Hard error: "Expected identifier".
                if (after.tag == .lparen or after.tag == .dot or
                    after.tag == .whitespace or after.tag == .newline)
                {
                    return error.HardSyntaxError;
                }
            }

            // Lone dot after ident with nothing consumable after --
            // backtrack so the dot is available to the caller.
            self.pos = dot_pos;
        }

        // Adjacency-driven concatenation: `ident#{expr}` or
        // `ident#{expr}foo` are a single Sass identifier (whose
        // interpolation is evaluated at value time).  Walk forward as
        // long as the next token is an ident or `#{...}` immediately
        // adjacent (no source byte gap) to the previous token.
        var span_end: u32 = tok.span.end;
        while (self.pos < self.tokens.len) {
            const next = self.tokens[self.pos];
            if (next.span.start != span_end) break;
            if (next.tag == .hash_lbrace) {
                // Skip past matching `}` (taking nesting into account).
                self.advance(); // consume #{
                var depth: usize = 1;
                while (self.pos < self.tokens.len) {
                    const t = self.tokens[self.pos];
                    if (t.tag == .lbrace or t.tag == .hash_lbrace) {
                        depth += 1;
                    } else if (t.tag == .rbrace) {
                        depth -= 1;
                        if (depth == 0) {
                            span_end = t.span.end;
                            self.advance();
                            break;
                        }
                    }
                    self.advance();
                }
                if (depth != 0) return error.SyntaxError;
            } else if (next.tag == .ident or next.tag == .number) {
                span_end = next.span.end;
                self.advance();
            } else {
                break;
            }
        }

        // Interpolated function call: `un#{quo}te(args)` -- when the
        // adjacency-driven concatenation produced a span longer than
        // the head ident (i.e. it picked up a `#{}`), and the next
        // token is `(` glued to the joined span, parse as a function
        // call whose name is the joined source text.
        if (span_end != tok.span.end and
            self.pos < self.tokens.len and
            self.tokens[self.pos].tag == .lparen and
            self.tokens[self.pos].span.start == span_end)
        {
            const joined = self.source[tok.span.start..span_end];
            const name_id = try self.intern_pool.intern(joined);
            return try self.parseFunctionCallBody(ast, name_id, .none, tok.span.start);
        }

        const joined = self.source[tok.span.start..span_end];
        const id = try self.intern_pool.intern(joined);
        return try ast.addNode(.{
            .tag = .expr_unquoted_ident,
            .flags = 0,
            .payload = @intFromEnum(id),
            .span_start = tok.span.start,
            .span_end = span_end,
        });
    }

    fn parseOpaqueCssFunctionCallAsTextExpr(
        self: *Parser,
        ast: *Ast,
        start_pos: usize,
        fn_name: []const u8,
    ) ParseError!NodeIndex {
        if (self.isAtEnd() or self.current().tag != .lparen) return error.SyntaxError;

        var paren_depth: u32 = 0;
        var interp_depth: u32 = 0;
        while (!self.isAtEnd()) {
            const tok = self.current();
            const t = tok.tag;

            if (t == .hash_lbrace) {
                interp_depth += 1;
                self.advance();
                continue;
            }
            if (t == .rbrace and interp_depth > 0) {
                interp_depth -= 1;
                self.advance();
                continue;
            }
            if (interp_depth > 0) {
                self.advance();
                continue;
            }

            if (t == .lparen) {
                paren_depth += 1;
                self.advance();
                continue;
            }
            if (t == .rparen) {
                if (paren_depth == 0) return error.SyntaxError;
                paren_depth -= 1;
                self.advance();
                if (paren_depth == 0) break;
                continue;
            }

            self.advance();
        }

        const stop_idx = self.pos;
        const base_name = cssFunctionBaseName(fn_name);
        const drop_silent_comments =
            std.ascii.eqlIgnoreCase(base_name, "calc") or
            std.ascii.eqlIgnoreCase(base_name, "element") or
            std.ascii.eqlIgnoreCase(base_name, "expression") or
            std.ascii.eqlIgnoreCase(base_name, "progid");
        const lowercase_name_len: usize = if (!isVendorPrefixedCssFunction(fn_name) and
            std.ascii.eqlIgnoreCase(base_name, "type"))
            fn_name.len
        else
            0;
        return (try self.emitUnquotedTextExprFromTokenRange(
            ast,
            start_pos,
            stop_idx,
            if (stop_idx > start_pos) stop_idx - 1 else null,
            !drop_silent_comments,
            drop_silent_comments,
            lowercase_name_len,
        )) orelse return error.SyntaxError;
    }

    fn internOpaqueCssSpecialWithSilentCommentsStripped(
        self: *Parser,
        raw: []const u8,
    ) !InternId {
        if (std.mem.find(u8, raw, "//") == null) return try self.intern_pool.intern(raw);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        var i: usize = 0;
        var in_string: u8 = 0;

        while (i < raw.len) {
            const c = raw[i];
            if (in_string != 0) {
                try buf.append(self.allocator, c);
                if (c == '\\' and i + 1 < raw.len) {
                    i += 1;
                    try buf.append(self.allocator, raw[i]);
                    i += 1;
                    continue;
                }
                if (c == in_string) in_string = 0;
                i += 1;
                continue;
            }
            if (c == '"' or c == '\'') {
                in_string = c;
                try buf.append(self.allocator, c);
                i += 1;
                continue;
            }
            if (c == '/' and i + 1 < raw.len and raw[i + 1] == '/') {
                i += 2;
                while (i < raw.len and raw[i] != '\n' and raw[i] != '\r') : (i += 1) {}
                if (i < raw.len and raw[i] == '\r') {
                    i += 1;
                    if (i < raw.len and raw[i] == '\n') i += 1;
                } else if (i < raw.len and raw[i] == '\n') {
                    i += 1;
                }
                while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t')) : (i += 1) {}
                try buf.append(self.allocator, ' ');
                continue;
            }
            try buf.append(self.allocator, c);
            i += 1;
        }

        return try self.intern_pool.intern(buf.items);
    }

    fn internOpaqueCssCallWithLowercasedName(
        self: *Parser,
        raw: []const u8,
    ) !InternId {
        const lparen = std.mem.findScalar(u8, raw, '(') orelse return try self.intern_pool.intern(raw);
        if (lparen == 0) return try self.intern_pool.intern(raw);

        const owned = try self.allocator.dupe(u8, raw);
        defer self.allocator.free(owned);
        for (owned[0..lparen]) |*ch| {
            ch.* = std.ascii.toLower(ch.*);
        }
        return try self.intern_pool.intern(owned);
    }

    fn isUrlLikeCssFunctionName(name: []const u8) bool {
        const base = cssFunctionBaseName(name);
        const url_like = [_][]const u8{ "url", "url-prefix", "domain", "regexp" };
        for (url_like) |u| {
            if (std.ascii.eqlIgnoreCase(base, u)) return true;
        }
        return false;
    }

    fn shouldTreatAsOpaqueCssFunctionInScript(name: []const u8, has_interpolation: bool) bool {
        // SassScript treats `url(...)` as an unquoted string. Keep the normal
        // function-call parser for plain `url(foo.css)` so existing Sass/CSS
        // function handling and parser tests stay intact, but switch to the raw
        // text-template path when interpolation is present. This is required
        // for values such as `url(#{$stem}.woff2)`, where normal call-arg
        // parsing rejects the CSS filename suffix after interpolation.
        return has_interpolation and std.ascii.eqlIgnoreCase(cssFunctionBaseName(name), "url");
    }

    fn shouldTreatUrlRawPathAsOpaque(self: *Parser, name: []const u8) bool {
        if (!std.ascii.eqlIgnoreCase(cssFunctionBaseName(name), "url")) return false;
        if (self.isAtEnd() or self.current().tag != .lparen) return false;
        var p = self.pos;
        var paren_depth: i32 = 0;
        var saw_url_path_token = false;
        while (p < self.tokens.len) : (p += 1) {
            const t = self.tokens[p].tag;
            switch (t) {
                .lparen => paren_depth += 1,
                .rparen => {
                    paren_depth -= 1;
                    if (paren_depth == 0) return saw_url_path_token;
                },
                .dollar_ident, .hash_lbrace => return false,
                .slash, .colon => {
                    if (paren_depth == 1) saw_url_path_token = true;
                },
                else => {},
            }
        }
        return false;
    }

    fn hasInterpolationInCurrentCallParens(self: *Parser) bool {
        if (self.isAtEnd() or self.current().tag != .lparen) return false;
        var p = self.pos;
        var paren_depth: i32 = 0;
        var interp_depth: i32 = 0;
        while (p < self.tokens.len) : (p += 1) {
            const t = self.tokens[p].tag;
            if (t == .hash_lbrace) {
                interp_depth += 1;
                return true;
            }
            if (interp_depth > 0) {
                if (t == .lbrace) interp_depth += 1;
                if (t == .rbrace) interp_depth -= 1;
                continue;
            }
            if (t == .lparen) {
                paren_depth += 1;
                continue;
            }
            if (t == .rparen) {
                paren_depth -= 1;
                if (paren_depth == 0) return false;
            }
        }
        return false;
    }

    fn shouldTreatAsOpaqueCssFunctionInDecl(name: []const u8) bool {
        if (std.ascii.startsWithIgnoreCase(name, "progid:")) return true;
        if (name.len > 0 and name[0] == '-') {
            if (std.mem.findScalar(u8, name, ':')) |colon| {
                const prefix = name[0..colon];
                if (prefix.len >= 6 and std.ascii.eqlIgnoreCase(prefix[prefix.len - 6 ..], "progid")) return true;
            }
        }

        const base = cssFunctionBaseName(name);
        const vendor_prefixed = isVendorPrefixedCssFunction(name);

        if (isUrlLikeCssFunctionName(name)) return true;

        // CSS special functions that stay as unquoted text in declaration values.
        const opaque_specials = [_][]const u8{ "element", "expression" };
        for (opaque_specials) |s| {
            if (std.ascii.eqlIgnoreCase(base, s)) return true;
        }
        if (!vendor_prefixed and std.ascii.eqlIgnoreCase(base, "type")) return true;

        // Vendor-prefixed calc() must be treated as opaque CSS.
        if (vendor_prefixed and std.ascii.eqlIgnoreCase(base, "calc")) return true;

        return false;
    }

    fn isVendorPrefixedCssFunction(name: []const u8) bool {
        if (name.len <= 1 or name[0] != '-') return false;
        return std.mem.findScalarPos(u8, name, 1, '-') != null;
    }

    fn cssFunctionBaseName(name: []const u8) []const u8 {
        if (!isVendorPrefixedCssFunction(name)) return name;
        const dash = std.mem.findScalarPos(u8, name, 1, '-') orelse return name;
        return name[dash + 1 ..];
    }

    fn identHasTooHighUnicodeEscape(text: []const u8) bool {
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] != '\\') {
                i += 1;
                continue;
            }
            i += 1;
            if (i >= text.len) break;

            if (std.ascii.isHex(text[i])) {
                const start = i;
                var count: usize = 0;
                while (i < text.len and count < 6 and std.ascii.isHex(text[i])) : (count += 1) {
                    i += 1;
                }
                const digits = text[start..i];
                const code_point = std.fmt.parseInt(u32, digits, 16) catch return true;
                if (code_point > 0x10FFFF) return true;
                if (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r' or text[i] == '\x0c')) {
                    i += 1;
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
            i += 1;
        }
        return false;
    }

    /// Parse the argument list of a function call and emit
    /// `expr_func_call`.  On entry, `self.pos` must index the opening
    /// `(` token.  `name_start` is the start byte of the whole call
    /// (the leading ident's `span_start`) for span tracking.
    ///
    /// extra layout (inlined after the fixed header):
    ///   [name_id, namespace_id, arg_count,
    ///    arg_node_0, ..., arg_node_{N-1},
    ///    arg_name_id_0, ..., arg_name_id_{N-1}]
    /// Parse a `( arg0, $kw: arg1, $sp... )` argument list into the
    /// caller-supplied output buffers.
    ///
    /// On entry, `self.pos` must index the opening `(` token.  On
    /// successful return, `self.pos` is past the matching `)`, and
    /// `rparen_end_out` holds its end byte offset for span tracking.
    ///
    /// Keyword arguments start with `$name:`; splat arguments are
    /// detected via a trailing `...` token triple and wrapped in
    /// `expr_splat`.  Positional args have `kw_name == .none`.
    fn parseCallArgsListRaw(
        self: *Parser,
        ast: *Ast,
        nodes_out: *std.ArrayListUnmanaged(NodeIndex),
        names_out: *std.ArrayListUnmanaged(InternId),
        rparen_end_out: *u32,
        treat_var_call: bool,
        allow_plain_equals_named_args: bool,
    ) ParseError!void {
        std.debug.assert(self.pos < self.tokens.len);
        std.debug.assert(self.tokens[self.pos].tag == .lparen);
        self.advance(); // skip (
        self.skipWhitespaceAndComments();

        // Track call-arg depth so `parseIdentAtom` can permit bare
        // `ns.name` joined idents (e.g. `blah.css` inside `url(...)`)
        // while rejecting them at top-level value position (where they
        // would be a malformed Sass namespace reference).
        self.call_arg_depth += 1;
        defer self.call_arg_depth -= 1;

        var var_custom_first_positional = false;

        while (!self.isAtEnd() and self.current().tag != .rparen) {
            if (treat_var_call and var_custom_first_positional and nodes_out.items.len >= 1) {
                const t0 = self.current().tag;
                if (t0 == .lbrace or t0 == .comma) return error.HardSyntaxError;
            }

            var kw_name: InternId = .none;
            if (self.current().tag == .dollar_ident) {
                const saved = self.pos;
                const var_tok = self.current();
                self.advance();
                self.skipWhitespaceAndComments();
                if (!self.isAtEnd() and self.current().tag == .colon) {
                    const var_text = var_tok.slice(self.source);
                    std.debug.assert(var_text.len >= 1 and var_text[0] == '$');
                    kw_name = try self.intern_pool.intern(var_text[1..]);
                    self.advance(); // skip :
                    self.skipWhitespaceAndComments();
                } else {
                    self.pos = saved;
                }
            }

            // SAFETY: initialized before first read in this scope.
            var value_node: NodeIndex = undefined;
            var parsed_value_node = false;
            if (kw_name == .none and self.current().tag == .ident) {
                const saved = self.pos;
                const key_tok = self.current();
                const key_text = key_tok.slice(self.source);
                self.advance();
                self.skipWhitespaceAndComments();
                if (!self.isAtEnd() and self.current().tag == .equal) {
                    const eq_tok = self.current();
                    self.advance(); // skip =
                    self.skipWhitespaceAndComments();
                    if (self.isAtEnd() or self.current().tag == .comma or self.current().tag == .rparen) {
                        return error.SyntaxError;
                    }

                    if (self.in_declaration_value_context) {
                        // CSS declaration value call-args: treat `name=expr`
                        // as a single positional value (`name=<evaluated expr>`),
                        // not as a Sass keyword argument.
                        const rhs_node = try self.parseSpaceListOrSingle(ast);
                        var prefix_buf: [256]u8 = undefined;
                        const prefix_id = blk: {
                            if (key_text.len + 1 <= prefix_buf.len) {
                                @memcpy(prefix_buf[0..key_text.len], key_text);
                                prefix_buf[key_text.len] = '=';
                                break :blk try self.intern_pool.intern(prefix_buf[0 .. key_text.len + 1]);
                            }
                            const prefix = try self.allocator.alloc(u8, key_text.len + 1);
                            defer self.allocator.free(prefix);
                            @memcpy(prefix[0..key_text.len], key_text);
                            prefix[key_text.len] = '=';
                            break :blk try self.intern_pool.intern(prefix);
                        };
                        const prefix_node = try ast.addNode(.{
                            .tag = .expr_unquoted_ident,
                            .flags = 0,
                            .payload = @intFromEnum(prefix_id),
                            .span_start = key_tok.span.start,
                            .span_end = eq_tok.span.end,
                        });
                        value_node = try emitBinaryOp(ast, .add, prefix_node, rhs_node);
                        parsed_value_node = true;
                    } else if (allow_plain_equals_named_args) {
                        // Sass-script context legacy compatibility (namespaced
                        // color.alpha()/opacity()) keeps plain `=` as named arg.
                        kw_name = try self.intern_pool.intern(key_text);
                        value_node = try self.parseSpaceListOrSingle(ast);
                        parsed_value_node = true;
                    } else {
                        self.pos = saved;
                    }
                } else {
                    self.pos = saved;
                }
            }

            if (!parsed_value_node) {
                value_node = try self.parseSpaceListOrSingle(ast);
            }

            var final_value = value_node;
            if (self.pos + 2 < self.tokens.len and
                self.tokens[self.pos].tag == .dot and
                self.tokens[self.pos + 1].tag == .dot and
                self.tokens[self.pos + 2].tag == .dot)
            {
                const splat_end = self.tokens[self.pos + 2].span.end;
                self.advance();
                self.advance();
                self.advance();
                const inner = ast.getNode(value_node);
                final_value = try ast.addNode(.{
                    .tag = .expr_splat,
                    .flags = 0,
                    .payload = value_node.toU32(),
                    .span_start = inner.span_start,
                    .span_end = splat_end,
                });
            }

            if (treat_var_call and
                nodes_out.items.len == 0 and
                kw_name == .none and
                self.nodeIsCustomPropertyLikeIdent(ast, final_value))
            {
                var_custom_first_positional = true;
            }

            try nodes_out.append(self.allocator, final_value);
            try names_out.append(self.allocator, kw_name);

            self.skipWhitespaceAndComments();
            if (!self.isAtEnd() and self.current().tag == .comma) {
                self.advance();
                self.skipWhitespaceAndComments();
                if (!self.isAtEnd() and self.current().tag == .rparen) {
                    if (treat_var_call and var_custom_first_positional and nodes_out.items.len == 1) {
                        const empty_start = self.current().span.start;
                        const empty_id = try self.intern_pool.intern("");
                        const empty_node = try ast.addNode(.{
                            .tag = .expr_unquoted_ident,
                            .flags = 0,
                            .payload = @intFromEnum(empty_id),
                            .span_start = empty_start,
                            .span_end = empty_start,
                        });
                        try nodes_out.append(self.allocator, empty_node);
                        try names_out.append(self.allocator, .none);
                    }
                    break;
                }
                if (!self.isAtEnd() and self.current().tag == .comma) {
                    if (treat_var_call and var_custom_first_positional and nodes_out.items.len == 1) {
                        return error.HardSyntaxError;
                    }
                    return error.SyntaxError;
                }
            } else {
                break;
            }
        }

        if (self.isAtEnd() or self.current().tag != .rparen) {
            return error.SyntaxError;
        }
        rparen_end_out.* = self.current().span.end;
        self.advance(); // skip )
    }

    fn sassIdentEqNormalized(raw: []const u8, expected: []const u8) bool {
        var i: usize = 0;
        var j: usize = 0;
        while (i < raw.len and j < expected.len) {
            var rc = raw[i];
            if (rc == '_') rc = '-';
            rc = std.ascii.toLower(rc);
            const ec = std.ascii.toLower(expected[j]);
            if (rc != ec) return false;
            i += 1;
            j += 1;
        }
        return i == raw.len and j == expected.len;
    }

    fn shouldAllowPlainEqualsNamedArgs(raw_name: []const u8, namespace_id: InternId, raw_namespace: []const u8) bool {
        if (namespace_id == .none) return false;
        if (!sassIdentEqNormalized(raw_namespace, "color")) return false;
        return sassIdentEqNormalized(raw_name, "alpha") or sassIdentEqNormalized(raw_name, "opacity");
    }

    fn shouldEscalateCallSyntaxError(raw_name: []const u8, namespace_id: InternId, raw_namespace: []const u8) bool {
        if (sassIdentEqNormalized(raw_name, "mix")) return true;
        if (namespace_id != .none and sassIdentEqNormalized(raw_namespace, "color")) {
            return sassIdentEqNormalized(raw_name, "alpha") or
                sassIdentEqNormalized(raw_name, "opacity") or
                sassIdentEqNormalized(raw_name, "is-in-gamut") or
                sassIdentEqNormalized(raw_name, "mix");
        }
        return false;
    }

    /// The CSS syntax for `if(...)` (`cond: value; ...`) is
    /// Since it cannot be parsed, consume everything from `(` to the corresponding `)` as raw.
    ///
    /// Return value true: consumed (`self.pos` follows `)`).
    /// Return value false: Not applicable to CSS if raw fallback.
    fn tryConsumeCssIfRawArgs(self: *Parser, rparen_end_out: *u32) bool {
        if (self.isAtEnd() or self.current().tag != .lparen) return false;

        const lparen_tok = self.current();
        var depth: i32 = 0;
        var p: usize = self.pos;
        while (p < self.tokens.len) : (p += 1) {
            const tok = self.tokens[p];
            switch (tok.tag) {
                .lparen => depth += 1,
                .rparen => {
                    depth -= 1;
                    if (depth == 0) {
                        const inner_start: usize = lparen_tok.span.end;
                        const inner_end: usize = tok.span.start;
                        if (inner_end < inner_start or inner_end > self.source.len) return false;
                        const inner = std.mem.trim(u8, self.source[inner_start..inner_end], " \t\r\n");
                        if (inner.len == 0) return false;
                        if (std.mem.findScalar(u8, inner, ':') == null) return false;

                        self.pos = p + 1;
                        rparen_end_out.* = tok.span.end;
                        return true;
                    }
                },
                else => {},
            }
        }
        return false;
    }

    /// Parse the argument list of a function call and emit
    /// `expr_func_call`.  On entry, `self.pos` must index the opening
    /// `(` token.  `name_start` is the start byte of the whole call
    /// (the leading ident's `span_start`) for span tracking.
    ///
    /// extra layout (inlined after the fixed header):
    ///   [name_id, namespace_id, arg_count,
    ///    arg_node_0, ..., arg_node_{N-1},
    ///    arg_name_id_0, ..., arg_name_id_{N-1}]
    fn parseFunctionCallBody(
        self: *Parser,
        ast: *Ast,
        name_id: InternId,
        namespace_id: InternId,
        name_start: u32,
    ) ParseError!NodeIndex {
        var arg_nodes: std.ArrayListUnmanaged(NodeIndex) = .empty;
        defer arg_nodes.deinit(self.allocator);
        var arg_names: std.ArrayListUnmanaged(InternId) = .empty;
        defer arg_names.deinit(self.allocator);

        var rparen_end: u32 = 0;
        const raw_name = self.intern_pool.get(name_id);
        const raw_namespace = if (namespace_id == .none) "" else self.intern_pool.get(namespace_id);
        const is_var_call = namespace_id == .none and std.ascii.eqlIgnoreCase(raw_name, "var");
        const allow_plain_equals_named_args = shouldAllowPlainEqualsNamedArgs(raw_name, namespace_id, raw_namespace);
        const escalate_call_syntax_error = shouldEscalateCallSyntaxError(raw_name, namespace_id, raw_namespace);
        const saved_pos_before_args = self.pos;
        self.parseCallArgsListRaw(
            ast,
            &arg_nodes,
            &arg_names,
            &rparen_end,
            is_var_call,
            allow_plain_equals_named_args,
        ) catch |err| switch (err) {
            error.SyntaxError, error.HardSyntaxError => {
                self.pos = saved_pos_before_args;
                if (namespace_id == .none and sassIdentEqNormalized(raw_name, "if") and
                    self.tryConsumeCssIfRawArgs(&rparen_end))
                {
                    // CSS if() raw fallback: args is reparsed from source span on the resolver side.
                } else if (err == error.HardSyntaxError or escalate_call_syntax_error) {
                    return error.HardSyntaxError;
                } else {
                    return err;
                }
            },
            else => return err,
        };

        const extra_off = try ast.appendExtraU32(@intFromEnum(name_id));
        _ = try ast.appendExtraU32(@intFromEnum(namespace_id));
        _ = try ast.appendExtraU32(@intCast(arg_nodes.items.len));
        for (arg_nodes.items) |n| {
            _ = try ast.appendExtraU32(n.toU32());
        }
        for (arg_names.items) |id| {
            _ = try ast.appendExtraU32(@intFromEnum(id));
        }

        return try ast.addNode(.{
            .tag = .expr_func_call,
            .flags = 0,
            .payload = extra_off,
            .span_start = name_start,
            .span_end = rparen_end,
        });
    }

    fn nodeIsCustomPropertyLikeIdent(self: *const Parser, ast: *const Ast, idx: NodeIndex) bool {
        const n = ast.getNode(idx);
        if (n.tag != .expr_unquoted_ident) return false;
        const text = std.mem.trim(u8, self.source[n.span_start..n.span_end], " \t\n\r");
        return text.len >= 2 and text[0] == '-' and text[1] == '-';
    }

    /// Parse a `.dollar_ident` token ($name).  Emits `expr_variable`
    /// with the leading `$` stripped from the interned name.
    fn parseVariableAtom(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const tok = self.current();
        std.debug.assert(tok.tag == .dollar_ident);

        const text = tok.slice(self.source);
        std.debug.assert(text.len >= 1 and text[0] == '$');
        // Bare `$` (no identifier body, e.g. `$.member` or `$,`) is a
        // syntax error -- official Sass CLI reports "Expected identifier".
        // Hard error: must NOT fall back to raw declaration capture.
        if (text.len == 1) return error.HardSyntaxError;
        self.advance();

        const name_id = try self.intern_pool.intern(text[1..]);

        return try ast.addNode(.{
            .tag = .expr_variable,
            .flags = 0,
            .payload = @intFromEnum(name_id),
            .span_start = tok.span.start,
            .span_end = tok.span.end,
        });
    }

    /// Parse a `.hash` token (e.g. `#ff0000`, `#fff`, `#abc123de`).
    ///
    /// When the content after `#` is a valid hex colour literal (3,
    /// 4, 6, or 8 hex digits), emit `expr_color_hex` with the packed
    /// `rgba` u32 in extra and flags describing short/long + case.
    /// When the content is not a valid hex literal (e.g. `#foo` used
    /// in a non-expression context like an id selector), fall back to
    /// `expr_unquoted_ident` holding the raw interned text so the
    /// evaluator can still round-trip it.
    ///
    /// flags bit 0: 1 = long form (6 or 8 digits)
    /// flags bit 1: 1 = any uppercase hex digit was present in source
    /// flags bit 2: 1 = alpha-bearing form (4 or 8 digits)
    fn parseHashAtom(self: *Parser, ast: *Ast) ParseError!NodeIndex {
        const tok = self.current();
        std.debug.assert(tok.tag == .hash);
        self.advance();

        const raw = tok.slice(self.source);
        std.debug.assert(raw.len >= 1 and raw[0] == '#');
        const hex = raw[1..];

        const is_hex = blk: {
            if (hex.len != 3 and hex.len != 4 and hex.len != 6 and hex.len != 8) break :blk false;
            for (hex) |c| {
                const valid = (c >= '0' and c <= '9') or
                    (c >= 'a' and c <= 'f') or
                    (c >= 'A' and c <= 'F');
                if (!valid) break :blk false;
            }
            break :blk true;
        };

        if (!is_hex) {
            const id = try self.intern_pool.intern(raw);
            return try ast.addNode(.{
                .tag = .expr_unquoted_ident,
                .flags = 0,
                .payload = @intFromEnum(id),
                .span_start = tok.span.start,
                .span_end = tok.span.end,
            });
        }

        var r: u32 = 0;
        var g: u32 = 0;
        var b: u32 = 0;
        var a: u32 = 0xff;
        var is_long = false;
        var is_upper = false;

        for (hex) |c| {
            if (c >= 'A' and c <= 'F') {
                is_upper = true;
                break;
            }
        }

        if (hex.len == 3) {
            r = hexPairDup(hex[0]);
            g = hexPairDup(hex[1]);
            b = hexPairDup(hex[2]);
        } else if (hex.len == 4) {
            r = hexPairDup(hex[0]);
            g = hexPairDup(hex[1]);
            b = hexPairDup(hex[2]);
            a = hexPairDup(hex[3]);
        } else if (hex.len == 6) {
            r = hexPair(hex[0..2].*);
            g = hexPair(hex[2..4].*);
            b = hexPair(hex[4..6].*);
            is_long = true;
        } else if (hex.len == 8) {
            r = hexPair(hex[0..2].*);
            g = hexPair(hex[2..4].*);
            b = hexPair(hex[4..6].*);
            a = hexPair(hex[6..8].*);
            is_long = true;
        }

        const rgba = (r << 24) | (g << 16) | (b << 8) | a;
        const extra_off = try ast.appendExtraU32(rgba);

        var flags: u8 = 0;
        if (is_long) flags |= 0b0000_0001;
        if (is_upper) flags |= 0b0000_0010;
        if (hex.len == 4 or hex.len == 8) flags |= 0b0000_0100;

        return try ast.addNode(.{
            .tag = .expr_color_hex,
            .flags = flags,
            .payload = extra_off,
            .span_start = tok.span.start,
            .span_end = tok.span.end,
        });
    }

    // -- token helpers --------------------------------------------------------

    fn current(self: *Parser) Token {
        if (self.pos >= self.tokens.len) {
            return .{
                .tag = .eof,
                .span = .{
                    .start = @intCast(self.source.len),
                    .end = @intCast(self.source.len),
                },
            };
        }
        return self.tokens[self.pos];
    }

    fn advance(self: *Parser) void {
        if (self.pos < self.tokens.len) self.pos += 1;
    }

    fn isAtEnd(self: *Parser) bool {
        return self.pos >= self.tokens.len or self.tokens[self.pos].tag == .eof;
    }

    /// Skip only whitespace and newline tokens.  Comments are preserved.
    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.tokens.len) {
            const tag = self.tokens[self.pos].tag;
            if (tag != .whitespace and tag != .newline) break;
            self.pos += 1;
        }
    }

    /// Skip whitespace, newlines, and every comment.  Matches the legacy
    /// parser.zig's `skipWhitespaceAndComments` semantics.
    fn skipWhitespaceAndComments(self: *Parser) void {
        while (self.pos < self.tokens.len) {
            const tag = self.tokens[self.pos].tag;
            if (tag != .whitespace and tag != .newline and tag != .comment) break;
            self.pos += 1;
        }
    }

    /// Skip inline whitespace/comments without crossing a newline.
    /// This is used where `.sass` grammar allows continuation only on the
    /// same logical line.
    fn skipInlineWhitespaceAndComments(self: *Parser) void {
        while (self.pos < self.tokens.len) {
            const tok = self.tokens[self.pos];
            switch (tok.tag) {
                .whitespace => self.pos += 1,
                .comment => {
                    const text = tok.slice(self.source);
                    const is_line_comment = text.len >= 2 and text[0] == '/' and text[1] == '/';
                    if (is_line_comment or std.mem.findAny(u8, text, "\n\r\x0c") != null) break;
                    self.pos += 1;
                },
                else => break,
            }
        }
    }

    /// Skip whitespace, newlines, and **line comments only** (`// ...`).
    /// Block comments (`/* ... */`) are preserved so a future `stmt_comment`
    /// emit can pick them up.  Mirrors legacy parser.zig behaviour.
    fn skipTrivia(self: *Parser) void {
        while (self.pos < self.tokens.len) {
            const tok = self.tokens[self.pos];
            switch (tok.tag) {
                .whitespace, .newline => self.pos += 1,
                .comment => {
                    const slice = tok.slice(self.source);
                    // Line comments start with `//` and never span multiple
                    // lines.  Block comments start with `/*`.
                    if (slice.len >= 2 and slice[0] == '/' and slice[1] == '/') {
                        self.pos += 1;
                    } else {
                        break;
                    }
                },
                else => break,
            }
        }
    }
};

// -- Node emit helpers (file scope -- no *Parser receiver needed) --------------

/// Emit an `expr_binary_op` node.  The operand spans fully bracket the
/// resulting node's span.  Extra layout: `[lhs u32, rhs u32, op u8 | 0]`.
fn emitBinaryOp(
    ast: *Ast,
    op: BinOp,
    lhs: NodeIndex,
    rhs: NodeIndex,
) !NodeIndex {
    const lhs_node = ast.getNode(lhs);
    const rhs_node = ast.getNode(rhs);

    const extra_off = try ast.appendExtraU32(lhs.toU32());
    _ = try ast.appendExtraU32(rhs.toU32());
    _ = try ast.appendExtraU32(@as(u32, @intFromEnum(op)));

    return try ast.addNode(.{
        .tag = .expr_binary_op,
        .flags = 0,
        .payload = extra_off,
        .span_start = lhs_node.span_start,
        .span_end = rhs_node.span_end,
    });
}

/// Emit an `expr_unary_op` node.  Extra layout: `[operand u32, op u8 | 0]`.
fn emitUnaryOp(
    ast: *Ast,
    op: UnaryOp,
    operand: NodeIndex,
    span_start: u32,
    span_end: u32,
) !NodeIndex {
    const extra_off = try ast.appendExtraU32(operand.toU32());
    _ = try ast.appendExtraU32(@as(u32, @intFromEnum(op)));

    return try ast.addNode(.{
        .tag = .expr_unary_op,
        .flags = 0,
        .payload = extra_off,
        .span_start = span_start,
        .span_end = span_end,
    });
}

/// Emit an `expr_slash_expr` node (the parse-time representation of a
/// `/` -- the evaluator decides division vs. literal pair).  Extra
/// layout: `[lhs u32, rhs u32]`.
fn emitSlashExpr(ast: *Ast, lhs: NodeIndex, rhs: NodeIndex) !NodeIndex {
    const lhs_node = ast.getNode(lhs);
    const rhs_node = ast.getNode(rhs);

    const extra_off = try ast.appendExtraU32(lhs.toU32());
    _ = try ast.appendExtraU32(rhs.toU32());

    return try ast.addNode(.{
        .tag = .expr_slash_expr,
        .flags = 0,
        .payload = extra_off,
        .span_start = lhs_node.span_start,
        .span_end = rhs_node.span_end,
    });
}

/// Return the numeric value (0..15) of a single hex digit.
/// Caller must guarantee that `c` is a valid hex digit.
inline fn hexDigit(c: u8) u32 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    return c - 'A' + 10;
}

/// Parse two hex digits into a u8 (0..255).
inline fn hexPair(bytes: [2]u8) u32 {
    return (hexDigit(bytes[0]) << 4) | hexDigit(bytes[1]);
}

/// Short-form expansion: a single hex digit `f` becomes byte `0xff`.
inline fn hexPairDup(c: u8) u32 {
    const d = hexDigit(c);
    return (d << 4) | d;
}

/// Emit a list node (`expr_comma_list`, `expr_space_list`, or
/// `expr_bracketed_list`).  All three share the same extra layout:
/// `[len: u32, child_0, child_1, ..., child_{N-1}]`.
fn emitListNode(
    ast: *Ast,
    tag: AstTag,
    flags: u8,
    items: []const NodeIndex,
    span_start: u32,
    span_end: u32,
) !NodeIndex {
    std.debug.assert(tag == .expr_comma_list or tag == .expr_space_list or tag == .expr_bracketed_list);
    const extra_off = try ast.appendExtraU32(@intCast(items.len));
    for (items) |idx| {
        _ = try ast.appendExtraU32(idx.toU32());
    }
    return try ast.addNode(.{
        .tag = tag,
        .flags = flags,
        .payload = extra_off,
        .span_start = span_start,
        .span_end = span_end,
    });
}

// -- Tests ---------------------------------------------------------------------

test "parse empty source \u{2014} stylesheet_root with 0 children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const source = "";
    var lexer = lexer_mod.Lexer.init(alloc, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    var parser = Parser.init(alloc, &pool, tokens, source);
    defer parser.deinit();

    var ast = try parser.parse();
    defer ast.deinit();

    // Root exists and is a stylesheet_root.
    const root = ast.getNode(ast.root);
    try std.testing.expectEqual(AstTag.stylesheet_root, root.tag);
    try std.testing.expectEqual(@as(u32, 0), root.span_start);
    try std.testing.expectEqual(@as(u32, 0), root.span_end);

    // extra payload: [child_count = 0]
    try std.testing.expectEqual(@as(u32, 0), ast.getExtraU32(root.payload));
}

test "parse whitespace-only source \u{2014} stylesheet_root with 0 children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const source = "   \n\t  \n";
    var lexer = lexer_mod.Lexer.init(alloc, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    var parser = Parser.init(alloc, &pool, tokens, source);
    defer parser.deinit();

    var ast = try parser.parse();
    defer ast.deinit();

    const root = ast.getNode(ast.root);
    try std.testing.expectEqual(AstTag.stylesheet_root, root.tag);
    try std.testing.expectEqual(@as(u32, 0), ast.getExtraU32(root.payload));
    try std.testing.expectEqual(source.len, root.span_end);
}

test "parse: block comment at top level becomes one stmt_comment child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const source = "/* block comment */";
    var lexer = lexer_mod.Lexer.init(alloc, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    var parser = Parser.init(alloc, &pool, tokens, source);
    defer parser.deinit();

    var ast = try parser.parse();
    defer ast.deinit();

    const root = ast.getNode(ast.root);
    try std.testing.expectEqual(AstTag.stylesheet_root, root.tag);
    try std.testing.expectEqual(@as(u32, 1), ast.getExtraU32(root.payload));
    const child: NodeIndex = @enumFromInt(ast.getExtraU32(root.payload + 1));
    try std.testing.expectEqual(AstTag.stmt_comment, ast.getNode(child).tag);
}

test "Parser init sets pos to 0 and records intern pool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const source = "a";
    var lexer = lexer_mod.Lexer.init(alloc, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    var parser = Parser.init(alloc, &pool, tokens, source);
    defer parser.deinit();

    try std.testing.expectEqual(@as(usize, 0), parser.pos);
    try std.testing.expectEqual(&pool, parser.intern_pool);
    try std.testing.expectEqual(tokens.ptr, parser.tokens.ptr);
    try std.testing.expectEqual(source.ptr, parser.source.ptr);
}

test "token helpers \u{2014} current / advance / isAtEnd on simple token stream" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const source = "a b";
    var lexer = lexer_mod.Lexer.init(alloc, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    var parser = Parser.init(alloc, &pool, tokens, source);
    defer parser.deinit();

    // At start, not at end.
    try std.testing.expect(!parser.isAtEnd());
    const first = parser.current();
    // Lexer should emit `ident` as the first non-trivia; but the stream can
    // start with whitespace.  Just verify `current()` matches `tokens[0]`.
    try std.testing.expectEqual(tokens[0].tag, first.tag);

    // advance should move pos forward.
    parser.advance();
    try std.testing.expectEqual(@as(usize, 1), parser.pos);

    // Walk to EOF.
    while (!parser.isAtEnd()) parser.advance();
    try std.testing.expect(parser.isAtEnd());

    // Once past the last token, `current()` returns a synthetic EOF token.
    const eof = parser.current();
    try std.testing.expectEqual(Token.Tag.eof, eof.tag);
    try std.testing.expectEqual(@as(u32, @intCast(source.len)), eof.span.start);
}

test "skipWhitespace consumes whitespace and newline only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    // " \n/* block */a"
    const source = " \n/* block */a";
    var lexer = lexer_mod.Lexer.init(alloc, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    var parser = Parser.init(alloc, &pool, tokens, source);
    defer parser.deinit();

    parser.skipWhitespace();
    // skipWhitespace preserves comments, so the next token should be the
    // block comment (not the ident).
    try std.testing.expectEqual(Token.Tag.comment, parser.current().tag);
}

test "skipWhitespaceAndComments consumes block comments too" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const source = " /* block */ // line\na";
    var lexer = lexer_mod.Lexer.init(alloc, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    var parser = Parser.init(alloc, &pool, tokens, source);
    defer parser.deinit();

    parser.skipWhitespaceAndComments();
    // Should land on the ident token.
    try std.testing.expectEqual(Token.Tag.ident, parser.current().tag);
}

test "skipTrivia preserves block comments but consumes line comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    // Line comment first, then block comment, then ident.
    const source = "// line\n/* block */a";
    var lexer = lexer_mod.Lexer.init(alloc, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    var parser = Parser.init(alloc, &pool, tokens, source);
    defer parser.deinit();

    parser.skipTrivia();
    // skipTrivia consumes the line comment but stops at the block comment.
    try std.testing.expectEqual(Token.Tag.comment, parser.current().tag);
    const tok_slice = parser.current().slice(source);
    try std.testing.expect(tok_slice.len >= 2 and tok_slice[0] == '/' and tok_slice[1] == '*');
}

test "parse leaves the parser in an at-end state after consuming a variable decl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const source = "$x: 1;";
    var lexer = lexer_mod.Lexer.init(alloc, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    var parser = Parser.init(alloc, &pool, tokens, source);
    defer parser.deinit();

    var ast = try parser.parse();
    defer ast.deinit();

    // The exact token count depends on lexer emission (e.g. whether
    // a trailing `.eof` token is produced); `isAtEnd()` encodes the
    // logical "we're done with input" condition.
    try std.testing.expect(parser.isAtEnd());
}

// -- expression primary atom tests (R.2c.2a) ----------------------------------

/// Helper: lex `source`, build a Parser + empty Ast, and invoke
/// `parseExpression` once.  The returned (parser, ast, node_idx) tuple
/// lives in the caller's arena.
const ExprTestCtx = struct {
    parser: Parser,
    ast: Ast,
    node: NodeIndex,
};

fn parseOneExpr(alloc: std.mem.Allocator, pool: *InternPool, source: []const u8) !ExprTestCtx {
    var lexer = lexer_mod.Lexer.init(alloc, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    var parser = Parser.init(alloc, pool, tokens, source);
    var ast = Ast.init(alloc, source, .none);
    errdefer ast.deinit();

    const node = try parser.parseExpression(&ast);
    return .{ .parser = parser, .ast = ast, .node = node };
}

test "parsePrimary: unitless integer number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "42");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_number_literal, n.tag);
    try std.testing.expectEqual(@as(u32, 0), n.span_start);
    try std.testing.expectEqual(@as(u32, 2), n.span_end);

    // extra: [f64 lo, f64 hi, unit_id]
    const value = ctx.ast.getExtraF64(n.payload);
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), value, 0.0);
    const unit_id: InternId = @enumFromInt(ctx.ast.getExtraU32(n.payload + 2));
    try std.testing.expectEqual(InternId.none, unit_id);
}

test "parsePrimary: decimal number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "1.5");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_number_literal, n.tag);
    const value = ctx.ast.getExtraF64(n.payload);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), value, 1e-12);
}

test "parsePrimary: number with px unit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "3px");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_number_literal, n.tag);
    try std.testing.expectEqual(@as(u32, 0), n.span_start);
    try std.testing.expectEqual(@as(u32, 3), n.span_end);

    const value = ctx.ast.getExtraF64(n.payload);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), value, 0.0);
    const unit_id: InternId = @enumFromInt(ctx.ast.getExtraU32(n.payload + 2));
    try std.testing.expect(unit_id != .none);
    try std.testing.expectEqualStrings("px", pool.get(unit_id));
}

test "parsePrimary: number with percent unit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "50%");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_number_literal, n.tag);
    try std.testing.expectEqual(@as(u32, 0), n.span_start);
    try std.testing.expectEqual(@as(u32, 3), n.span_end);

    const unit_id: InternId = @enumFromInt(ctx.ast.getExtraU32(n.payload + 2));
    try std.testing.expect(unit_id != .none);
    try std.testing.expectEqualStrings("%", pool.get(unit_id));
}

test "parsePrimary: double-quoted string literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "\"hello\"");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_string_literal, n.tag);
    try std.testing.expectEqual(@as(u8, 1), n.flags); // bit 0 = quoted

    const str_id: InternId = @enumFromInt(ctx.ast.getExtraU32(n.payload));
    try std.testing.expectEqualStrings("hello", pool.get(str_id));
}

test "parsePrimary: single-quoted string literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "'world'");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_string_literal, n.tag);
    try std.testing.expectEqual(@as(u8, 1), n.flags);

    const str_id: InternId = @enumFromInt(ctx.ast.getExtraU32(n.payload));
    try std.testing.expectEqualStrings("world", pool.get(str_id));
}

test "parsePrimary: true / false / null keywords" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    {
        var ctx = try parseOneExpr(alloc, &pool, "true");
        defer ctx.ast.deinit();
        try std.testing.expectEqual(AstTag.expr_bool_true, ctx.ast.getNode(ctx.node).tag);
    }
    {
        var ctx = try parseOneExpr(alloc, &pool, "false");
        defer ctx.ast.deinit();
        try std.testing.expectEqual(AstTag.expr_bool_false, ctx.ast.getNode(ctx.node).tag);
    }
    {
        var ctx = try parseOneExpr(alloc, &pool, "null");
        defer ctx.ast.deinit();
        try std.testing.expectEqual(AstTag.expr_null, ctx.ast.getNode(ctx.node).tag);
    }
}

test "parsePrimary: unquoted identifier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "solid");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_unquoted_ident, n.tag);
    const id: InternId = @enumFromInt(n.payload);
    try std.testing.expectEqualStrings("solid", pool.get(id));
}

test "parsePrimary: variable reference strips leading $" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "$color");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_variable, n.tag);
    const id: InternId = @enumFromInt(n.payload);
    try std.testing.expectEqualStrings("color", pool.get(id));
}

test "parsePrimary: unsupported token at start returns SyntaxError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    // A lone `:` has no atom interpretation -- parsePrimary falls to
    // the else branch and raises SyntaxError.
    const source = ":";
    var lexer = lexer_mod.Lexer.init(alloc, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    var parser = Parser.init(alloc, &pool, tokens, source);
    var ast = Ast.init(alloc, source, .none);
    defer ast.deinit();

    try std.testing.expectError(error.SyntaxError, parser.parseExpression(&ast));
}

test "parsePrimary: empty input returns UnexpectedEof" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const source = "";
    var lexer = lexer_mod.Lexer.init(alloc, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    var parser = Parser.init(alloc, &pool, tokens, source);
    var ast = Ast.init(alloc, source, .none);
    defer ast.deinit();

    try std.testing.expectError(error.UnexpectedEof, parser.parseExpression(&ast));
}

test "parsePrimary: leading whitespace is skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "   42");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_number_literal, n.tag);
    const value = ctx.ast.getExtraF64(n.payload);
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), value, 0.0);
}

// -- binary/unary operator tests (R.2c.2b) ------------------------------------

/// Read the packed binary_op extra layout: `[lhs u32, rhs u32, op u8|0]`.
const BinaryPayload = struct {
    lhs: NodeIndex,
    rhs: NodeIndex,
    op: BinOp,
};

fn readBinary(ast: *const Ast, node: NodeIndex) BinaryPayload {
    const n = ast.getNode(node);
    std.debug.assert(n.tag == .expr_binary_op);
    return .{
        .lhs = @enumFromInt(ast.getExtraU32(n.payload + 0)),
        .rhs = @enumFromInt(ast.getExtraU32(n.payload + 1)),
        .op = @enumFromInt(@as(u8, @truncate(ast.getExtraU32(n.payload + 2)))),
    };
}

const UnaryPayload = struct {
    operand: NodeIndex,
    op: UnaryOp,
};

fn readUnary(ast: *const Ast, node: NodeIndex) UnaryPayload {
    const n = ast.getNode(node);
    std.debug.assert(n.tag == .expr_unary_op);
    return .{
        .operand = @enumFromInt(ast.getExtraU32(n.payload + 0)),
        .op = @enumFromInt(@as(u8, @truncate(ast.getExtraU32(n.payload + 1)))),
    };
}

const SlashPayload = struct { lhs: NodeIndex, rhs: NodeIndex };

fn readSlash(ast: *const Ast, node: NodeIndex) SlashPayload {
    const n = ast.getNode(node);
    std.debug.assert(n.tag == .expr_slash_expr);
    return .{
        .lhs = @enumFromInt(ast.getExtraU32(n.payload + 0)),
        .rhs = @enumFromInt(ast.getExtraU32(n.payload + 1)),
    };
}

/// Assert that `node` is an `expr_number_literal` with `expected` f64 value.
fn expectNumberValue(ast: *const Ast, node: NodeIndex, expected: f64) !void {
    const n = ast.getNode(node);
    try std.testing.expectEqual(AstTag.expr_number_literal, n.tag);
    const v = ast.getExtraF64(n.payload);
    try std.testing.expectApproxEqAbs(expected, v, 1e-12);
}

test "parseBinaryExpr: 1 + 2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "1 + 2");
    defer ctx.ast.deinit();

    const bin = readBinary(&ctx.ast, ctx.node);
    try std.testing.expectEqual(BinOp.add, bin.op);
    try expectNumberValue(&ctx.ast, bin.lhs, 1.0);
    try expectNumberValue(&ctx.ast, bin.rhs, 2.0);
}

test "parseBinaryExpr: 1 * 2 + 3 \u{2014} mul binds tighter than add" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "1 * 2 + 3");
    defer ctx.ast.deinit();

    // Expected shape: add(mul(1, 2), 3)
    const add = readBinary(&ctx.ast, ctx.node);
    try std.testing.expectEqual(BinOp.add, add.op);
    const mul = readBinary(&ctx.ast, add.lhs);
    try std.testing.expectEqual(BinOp.mul, mul.op);
    try expectNumberValue(&ctx.ast, mul.lhs, 1.0);
    try expectNumberValue(&ctx.ast, mul.rhs, 2.0);
    try expectNumberValue(&ctx.ast, add.rhs, 3.0);
}

test "parseBinaryExpr: 1 + 2 * 3 \u{2014} mul binds right of add" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "1 + 2 * 3");
    defer ctx.ast.deinit();

    // Expected shape: add(1, mul(2, 3))
    const add = readBinary(&ctx.ast, ctx.node);
    try std.testing.expectEqual(BinOp.add, add.op);
    try expectNumberValue(&ctx.ast, add.lhs, 1.0);
    const mul = readBinary(&ctx.ast, add.rhs);
    try std.testing.expectEqual(BinOp.mul, mul.op);
    try expectNumberValue(&ctx.ast, mul.lhs, 2.0);
    try expectNumberValue(&ctx.ast, mul.rhs, 3.0);
}

test "parseBinaryExpr: left-associativity of +" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "1 + 2 + 3");
    defer ctx.ast.deinit();

    // Expected shape: add(add(1, 2), 3)
    const outer = readBinary(&ctx.ast, ctx.node);
    try std.testing.expectEqual(BinOp.add, outer.op);
    const inner = readBinary(&ctx.ast, outer.lhs);
    try std.testing.expectEqual(BinOp.add, inner.op);
    try expectNumberValue(&ctx.ast, inner.lhs, 1.0);
    try expectNumberValue(&ctx.ast, inner.rhs, 2.0);
    try expectNumberValue(&ctx.ast, outer.rhs, 3.0);
}

test "parseBinaryExpr: comparison eq / ne / lt / gt / le / ge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const cases = [_]struct { src: []const u8, op: BinOp }{
        .{ .src = "1 == 2", .op = .eq },
        .{ .src = "1 != 2", .op = .ne },
        .{ .src = "1 < 2", .op = .lt },
        .{ .src = "1 > 2", .op = .gt },
        .{ .src = "1 <= 2", .op = .le },
        .{ .src = "1 >= 2", .op = .ge },
    };
    for (cases) |c| {
        var ctx = try parseOneExpr(alloc, &pool, c.src);
        defer ctx.ast.deinit();
        const b = readBinary(&ctx.ast, ctx.node);
        try std.testing.expectEqual(c.op, b.op);
    }
}

test "parseBinaryExpr: $a and $b or $c \u{2014} `or` binds lower than `and`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "$a and $b or $c");
    defer ctx.ast.deinit();

    // Expected shape: or(and($a, $b), $c)
    const outer = readBinary(&ctx.ast, ctx.node);
    try std.testing.expectEqual(BinOp.log_or, outer.op);
    const inner = readBinary(&ctx.ast, outer.lhs);
    try std.testing.expectEqual(BinOp.log_and, inner.op);
    try std.testing.expectEqual(AstTag.expr_variable, ctx.ast.getNode(inner.lhs).tag);
    try std.testing.expectEqual(AstTag.expr_variable, ctx.ast.getNode(inner.rhs).tag);
    try std.testing.expectEqual(AstTag.expr_variable, ctx.ast.getNode(outer.rhs).tag);
}

test "parseBinaryExpr: `/` produces expr_slash_expr (not div)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "1 / 2");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_slash_expr, n.tag);
    const s = readSlash(&ctx.ast, ctx.node);
    try expectNumberValue(&ctx.ast, s.lhs, 1.0);
    try expectNumberValue(&ctx.ast, s.rhs, 2.0);
}

test "parseUnaryOrAtom: -5 at start" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "-5");
    defer ctx.ast.deinit();

    const root = ctx.ast.getNode(ctx.node);
    // `-5` may be either (a) a single signed number literal (if the lexer
    // folds the sign) or (b) expr_unary_op(.negate, 5).  Accept both.
    switch (root.tag) {
        .expr_number_literal => {
            const v = ctx.ast.getExtraF64(root.payload);
            try std.testing.expectApproxEqAbs(@as(f64, -5.0), v, 0.0);
        },
        .expr_unary_op => {
            const u = readUnary(&ctx.ast, ctx.node);
            try std.testing.expectEqual(UnaryOp.negate, u.op);
            try expectNumberValue(&ctx.ast, u.operand, 5.0);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseUnaryOrAtom: unary minus on variable \u{2014} -$x" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "-$x");
    defer ctx.ast.deinit();

    const root = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_unary_op, root.tag);
    const u = readUnary(&ctx.ast, ctx.node);
    try std.testing.expectEqual(UnaryOp.negate, u.op);
    try std.testing.expectEqual(AstTag.expr_variable, ctx.ast.getNode(u.operand).tag);
}

test "parseUnaryOrAtom: not true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "not true");
    defer ctx.ast.deinit();

    const root = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_unary_op, root.tag);
    const u = readUnary(&ctx.ast, ctx.node);
    try std.testing.expectEqual(UnaryOp.not, u.op);
    try std.testing.expectEqual(AstTag.expr_bool_true, ctx.ast.getNode(u.operand).tag);
}

test "parseBinaryExpr: unary minus inside binary \u{2014} 1 + -2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "1 + -2");
    defer ctx.ast.deinit();

    const add = readBinary(&ctx.ast, ctx.node);
    try std.testing.expectEqual(BinOp.add, add.op);
    try expectNumberValue(&ctx.ast, add.lhs, 1.0);
    // The right side should evaluate to -2 -- either as a unary_op or a
    // signed number literal (accept both).
    const rhs_tag = ctx.ast.getNode(add.rhs).tag;
    try std.testing.expect(rhs_tag == .expr_unary_op or rhs_tag == .expr_number_literal);
}

test "parseBinaryExpr: span_end of root covers full expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const source = "1 + 2 * 3";
    var ctx = try parseOneExpr(alloc, &pool, source);
    defer ctx.ast.deinit();

    const root = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(@as(u32, 0), root.span_start);
    try std.testing.expectEqual(@as(u32, @intCast(source.len)), root.span_end);
}

// -- function call + namespaced tests (R.2c.2c) -------------------------------

/// Read expr_func_call's inlined extra layout.
const FuncCallPayload = struct {
    name_id: InternId,
    namespace_id: InternId,
    arg_count: u32,
    /// Slice of arg NodeIndex values (borrowed view into ast.extra).
    arg_nodes_start: u32,
    /// Slice of arg name InternId values (borrowed view into ast.extra).
    arg_names_start: u32,
};

fn readFuncCall(ast: *const Ast, node: NodeIndex) FuncCallPayload {
    const n = ast.getNode(node);
    std.debug.assert(n.tag == .expr_func_call);
    const off = n.payload;
    const name_id: InternId = @enumFromInt(ast.getExtraU32(off + 0));
    const ns_id: InternId = @enumFromInt(ast.getExtraU32(off + 1));
    const count = ast.getExtraU32(off + 2);
    return .{
        .name_id = name_id,
        .namespace_id = ns_id,
        .arg_count = count,
        .arg_nodes_start = off + 3,
        .arg_names_start = off + 3 + count,
    };
}

test "parseFuncCall: foo() \u{2014} zero args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "foo()");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_func_call, n.tag);
    try std.testing.expectEqual(@as(u32, 0), n.span_start);
    try std.testing.expectEqual(@as(u32, 5), n.span_end);

    const fc = readFuncCall(&ctx.ast, ctx.node);
    try std.testing.expectEqualStrings("foo", pool.get(fc.name_id));
    try std.testing.expectEqual(InternId.none, fc.namespace_id);
    try std.testing.expectEqual(@as(u32, 0), fc.arg_count);
}

test "parseFuncCall: foo(1) \u{2014} single positional arg" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "foo(1)");
    defer ctx.ast.deinit();

    const fc = readFuncCall(&ctx.ast, ctx.node);
    try std.testing.expectEqual(@as(u32, 1), fc.arg_count);

    const arg0: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(fc.arg_nodes_start));
    try expectNumberValue(&ctx.ast, arg0, 1.0);

    const name0: InternId = @enumFromInt(ctx.ast.getExtraU32(fc.arg_names_start));
    try std.testing.expectEqual(InternId.none, name0);
}

test "parseFuncCall: foo(1, 2) \u{2014} two positional args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "foo(1, 2)");
    defer ctx.ast.deinit();

    const fc = readFuncCall(&ctx.ast, ctx.node);
    try std.testing.expectEqual(@as(u32, 2), fc.arg_count);

    const a0: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(fc.arg_nodes_start));
    const a1: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(fc.arg_nodes_start + 1));
    try expectNumberValue(&ctx.ast, a0, 1.0);
    try expectNumberValue(&ctx.ast, a1, 2.0);

    const n0: InternId = @enumFromInt(ctx.ast.getExtraU32(fc.arg_names_start));
    const n1: InternId = @enumFromInt(ctx.ast.getExtraU32(fc.arg_names_start + 1));
    try std.testing.expectEqual(InternId.none, n0);
    try std.testing.expectEqual(InternId.none, n1);
}

test "parseFuncCall: foo($x: 1) \u{2014} single named arg" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "foo($x: 1)");
    defer ctx.ast.deinit();

    const fc = readFuncCall(&ctx.ast, ctx.node);
    try std.testing.expectEqual(@as(u32, 1), fc.arg_count);

    const v0: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(fc.arg_nodes_start));
    try expectNumberValue(&ctx.ast, v0, 1.0);

    const name0: InternId = @enumFromInt(ctx.ast.getExtraU32(fc.arg_names_start));
    try std.testing.expect(name0 != .none);
    try std.testing.expectEqualStrings("x", pool.get(name0));
}

test "parseFuncCall: foo(1, $y: 2) \u{2014} mixed positional + named" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "foo(1, $y: 2)");
    defer ctx.ast.deinit();

    const fc = readFuncCall(&ctx.ast, ctx.node);
    try std.testing.expectEqual(@as(u32, 2), fc.arg_count);

    const v0: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(fc.arg_nodes_start));
    const v1: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(fc.arg_nodes_start + 1));
    try expectNumberValue(&ctx.ast, v0, 1.0);
    try expectNumberValue(&ctx.ast, v1, 2.0);

    const n0: InternId = @enumFromInt(ctx.ast.getExtraU32(fc.arg_names_start));
    const n1: InternId = @enumFromInt(ctx.ast.getExtraU32(fc.arg_names_start + 1));
    try std.testing.expectEqual(InternId.none, n0);
    try std.testing.expect(n1 != .none);
    try std.testing.expectEqualStrings("y", pool.get(n1));
}

test "parseFuncCall: math.sqrt(4) \u{2014} namespaced function call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "math.sqrt(4)");
    defer ctx.ast.deinit();

    const fc = readFuncCall(&ctx.ast, ctx.node);
    try std.testing.expectEqualStrings("sqrt", pool.get(fc.name_id));
    try std.testing.expect(fc.namespace_id != .none);
    try std.testing.expectEqualStrings("math", pool.get(fc.namespace_id));
    try std.testing.expectEqual(@as(u32, 1), fc.arg_count);
}

test "parseFuncCall: arg can contain a binary expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "foo(1 + 2)");
    defer ctx.ast.deinit();

    const fc = readFuncCall(&ctx.ast, ctx.node);
    try std.testing.expectEqual(@as(u32, 1), fc.arg_count);

    const arg0: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(fc.arg_nodes_start));
    try std.testing.expectEqual(AstTag.expr_binary_op, ctx.ast.getNode(arg0).tag);
}

test "parseNamespacedVar: colors.$primary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "colors.$primary");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_namespaced_var, n.tag);

    const ns_id: InternId = @enumFromInt(ctx.ast.getExtraU32(n.payload));
    const name_id: InternId = @enumFromInt(ctx.ast.getExtraU32(n.payload + 1));
    try std.testing.expectEqualStrings("colors", pool.get(ns_id));
    try std.testing.expectEqualStrings("primary", pool.get(name_id));
}

test "parseIdent: ns.name without parens is a HardSyntaxError at top level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    // A bare `ns.name` at top-level value position is ill-formed Sass
    // (official Sass CLI reports `expected "("`). Parser must reject it hard so
    // the declaration-value fallback does not swallow it as raw text.
    try std.testing.expectError(error.HardSyntaxError, parseOneExpr(alloc, &pool, "abc.def"));
}

test "parseIdent: ns.name inside function-call arg stays joined unquoted_ident" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    // Inside a call-arg list (e.g. `url(blah.css)`) the parser cannot
    // tell if this is a Sass namespace reference or a CSS-style joined
    // identifier, so we fall back to a joined `expr_unquoted_ident`.
    var ctx = try parseOneExpr(alloc, &pool, "url(blah.css)");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_func_call, n.tag);
    // payload = extra_off  ->  [name_id, namespace_id, arg_count, arg0, ...]
    const extra_off = n.payload;
    const name_id: InternId = @enumFromInt(ctx.ast.getExtraU32(extra_off));
    try std.testing.expectEqualStrings("url", pool.get(name_id));
    const arg_count = ctx.ast.getExtraU32(extra_off + 2);
    try std.testing.expectEqual(@as(u32, 1), arg_count);
    const arg_idx_raw = ctx.ast.getExtraU32(extra_off + 3);
    const arg_node = ctx.ast.getNode(@enumFromInt(arg_idx_raw));
    try std.testing.expectEqual(AstTag.expr_unquoted_ident, arg_node.tag);
    const arg_id: InternId = @enumFromInt(arg_node.payload);
    try std.testing.expectEqualStrings("blah.css", pool.get(arg_id));
}

test "parseFuncCall: unterminated \u{2014} no closing paren \u{2192} SyntaxError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const source = "foo(1,";
    var lexer = lexer_mod.Lexer.init(alloc, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    var parser = Parser.init(alloc, &pool, tokens, source);
    var ast = Ast.init(alloc, source, .none);
    defer ast.deinit();

    try std.testing.expectError(error.SyntaxError, parser.parseExpression(&ast));
}

test "parseIdent: whitespace between ident and `(` breaks function-call adjacency" {
    // `foo (1)` should NOT be parsed as a function call -- whitespace
    // separates the ident from the paren.  After R.2c.2d, the paren
    // is recognised as a primary atom, so `foo (1)` parses as a
    // space-separated list of two items: [foo, (1)]. The key point
    // for this test is that the root is *not* an expr_func_call.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const source = "foo (1)";
    var lexer = lexer_mod.Lexer.init(alloc, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    var parser = Parser.init(alloc, &pool, tokens, source);
    var ast = Ast.init(alloc, source, .none);
    defer ast.deinit();

    const node = try parser.parseExpression(&ast);
    const n = ast.getNode(node);
    try std.testing.expect(n.tag != .expr_func_call);
    try std.testing.expectEqual(AstTag.expr_space_list, n.tag);
    const list = readList(&ast, node);
    try std.testing.expectEqual(@as(u32, 2), list.len);
    const first: NodeIndex = @enumFromInt(ast.getExtraU32(list.items_off + 0));
    try std.testing.expectEqual(AstTag.expr_unquoted_ident, ast.getNode(first).tag);
}

// -- list / map / paren tests (R.2c.2d) ---------------------------------------

/// Read a list node (`expr_comma_list` / `expr_space_list` /
/// `expr_bracketed_list`).  Returns `(len, first_item_offset)`.
const ListPayload = struct {
    len: u32,
    /// Offset of the first item NodeIndex in ast.extra.
    items_off: u32,
};

fn readList(ast: *const Ast, node: NodeIndex) ListPayload {
    const n = ast.getNode(node);
    std.debug.assert(n.tag == .expr_comma_list or n.tag == .expr_space_list or n.tag == .expr_bracketed_list);
    return .{
        .len = ast.getExtraU32(n.payload),
        .items_off = n.payload + 1,
    };
}

test "parseParen: single element wraps in expr_paren" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "(42)");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_paren, n.tag);
    try std.testing.expectEqual(@as(u32, 0), n.span_start);
    try std.testing.expectEqual(@as(u32, 4), n.span_end);

    const inner: NodeIndex = @enumFromInt(n.payload);
    try expectNumberValue(&ctx.ast, inner, 42.0);
}

test "parseParen: empty parens emit empty comma_list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "()");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_comma_list, n.tag);
    const list = readList(&ctx.ast, ctx.node);
    try std.testing.expectEqual(@as(u32, 0), list.len);
}

test "parseParen: comma list (1, 2, 3)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "(1, 2, 3)");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_comma_list, n.tag);
    const list = readList(&ctx.ast, ctx.node);
    try std.testing.expectEqual(@as(u32, 3), list.len);

    const v0: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(list.items_off + 0));
    const v1: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(list.items_off + 1));
    const v2: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(list.items_off + 2));
    try expectNumberValue(&ctx.ast, v0, 1.0);
    try expectNumberValue(&ctx.ast, v1, 2.0);
    try expectNumberValue(&ctx.ast, v2, 3.0);
}

test "parseParen: space list (1 2 3)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "(1 2 3)");
    defer ctx.ast.deinit();

    // Inside the parens, `1 2 3` is a space list.  The paren wraps a
    // single expression -- the space_list -- via expr_paren.
    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_paren, n.tag);
    const inner: NodeIndex = @enumFromInt(n.payload);
    try std.testing.expectEqual(AstTag.expr_space_list, ctx.ast.getNode(inner).tag);
    const list = readList(&ctx.ast, inner);
    try std.testing.expectEqual(@as(u32, 3), list.len);
}

test "parseMap: (a: 1, b: 2)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "(a: 1, b: 2)");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_map_literal, n.tag);

    const len = ctx.ast.getExtraU32(n.payload);
    try std.testing.expectEqual(@as(u32, 2), len);

    // Layout: [len, key_0, key_1, val_0, val_1]
    const k0: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(n.payload + 1));
    const k1: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(n.payload + 2));
    const v0: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(n.payload + 3));
    const v1: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(n.payload + 4));

    try std.testing.expectEqual(AstTag.expr_unquoted_ident, ctx.ast.getNode(k0).tag);
    try std.testing.expectEqual(AstTag.expr_unquoted_ident, ctx.ast.getNode(k1).tag);
    try expectNumberValue(&ctx.ast, v0, 1.0);
    try expectNumberValue(&ctx.ast, v1, 2.0);
}

test "parseBracketedList: [1, 2, 3]" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "[1, 2, 3]");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_bracketed_list, n.tag);
    const list = readList(&ctx.ast, ctx.node);
    try std.testing.expectEqual(@as(u32, 3), list.len);
}

test "parseBracketedList: empty [] \u{2192} zero-length bracketed_list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "[]");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_bracketed_list, n.tag);
    const list = readList(&ctx.ast, ctx.node);
    try std.testing.expectEqual(@as(u32, 0), list.len);
}

test "parseBracketedList: [1,] preserves trailing comma flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "[1,]");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_bracketed_list, n.tag);
    try std.testing.expectEqual(LIST_FLAG_TRAILING_COMMA, n.flags & LIST_FLAG_TRAILING_COMMA);
    const list = readList(&ctx.ast, ctx.node);
    try std.testing.expectEqual(@as(u32, 1), list.len);
}

test "parseExpression: top-level comma list `1, 2, 3`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "1, 2, 3");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_comma_list, n.tag);
    const list = readList(&ctx.ast, ctx.node);
    try std.testing.expectEqual(@as(u32, 3), list.len);
}

test "parseExpression: top-level space list `1 2 3`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "1 2 3");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_space_list, n.tag);
    const list = readList(&ctx.ast, ctx.node);
    try std.testing.expectEqual(@as(u32, 3), list.len);
}

test "parseExpression: `1 + 2, 3 * 4` \u{2014} comma wraps two binary exprs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "1 + 2, 3 * 4");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_comma_list, n.tag);
    const list = readList(&ctx.ast, ctx.node);
    try std.testing.expectEqual(@as(u32, 2), list.len);

    const lhs_item: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(list.items_off + 0));
    const rhs_item: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(list.items_off + 1));
    try std.testing.expectEqual(AstTag.expr_binary_op, ctx.ast.getNode(lhs_item).tag);
    try std.testing.expectEqual(AstTag.expr_binary_op, ctx.ast.getNode(rhs_item).tag);
}

test "parseFuncCall still uses space-list args after R.2c.2d refactor" {
    // Regression check: even though parseExpression is now comma-aware,
    // parseFunctionCallBody must use parseSpaceListOrSingle so commas
    // still separate arguments.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "foo(1 2, 3 4)");
    defer ctx.ast.deinit();

    const fc = readFuncCall(&ctx.ast, ctx.node);
    try std.testing.expectEqual(@as(u32, 2), fc.arg_count);

    const a0: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(fc.arg_nodes_start + 0));
    const a1: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(fc.arg_nodes_start + 1));
    // Each arg is a 2-item space_list.
    try std.testing.expectEqual(AstTag.expr_space_list, ctx.ast.getNode(a0).tag);
    try std.testing.expectEqual(AstTag.expr_space_list, ctx.ast.getNode(a1).tag);
}

test "parseParen: unterminated `(1,` \u{2192} SyntaxError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const source = "(1,";
    var lexer = lexer_mod.Lexer.init(alloc, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    var parser = Parser.init(alloc, &pool, tokens, source);
    var ast = Ast.init(alloc, source, .none);
    defer ast.deinit();

    try std.testing.expectError(error.SyntaxError, parser.parseExpression(&ast));
}

test "parseBracketedList: unterminated `[1,` \u{2192} SyntaxError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const source = "[1,";
    var lexer = lexer_mod.Lexer.init(alloc, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    var parser = Parser.init(alloc, &pool, tokens, source);
    var ast = Ast.init(alloc, source, .none);
    defer ast.deinit();

    try std.testing.expectError(error.SyntaxError, parser.parseExpression(&ast));
}

// -- interpolation + splat tests (R.2c.2e) ------------------------------------

test "parseStandaloneInterp: #{42}" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "#{42}");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_interp, n.tag);
    try std.testing.expectEqual(@as(u32, 0), n.span_start);
    try std.testing.expectEqual(@as(u32, 5), n.span_end);

    const inner: NodeIndex = @enumFromInt(n.payload);
    try expectNumberValue(&ctx.ast, inner, 42.0);
}

test "parseStandaloneInterp: #{$x + 1} with binary expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "#{$x + 1}");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_interp, n.tag);
    const inner: NodeIndex = @enumFromInt(n.payload);
    try std.testing.expectEqual(AstTag.expr_binary_op, ctx.ast.getNode(inner).tag);
}

test "parseStandaloneInterp: #{\"quoted\"} unquotes nested string literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "#{\"quoted\"}");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_interp, n.tag);
    const inner: NodeIndex = @enumFromInt(n.payload);
    const inner_n = ctx.ast.getNode(inner);
    try std.testing.expectEqual(AstTag.expr_string_literal, inner_n.tag);
    try std.testing.expectEqual(@as(u8, 0), inner_n.flags & 0b0000_0001);
}

test "parseStandaloneInterp: unterminated `#{expr` \u{2192} SyntaxError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const source = "#{expr";
    var lexer = lexer_mod.Lexer.init(alloc, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    var parser = Parser.init(alloc, &pool, tokens, source);
    var ast = Ast.init(alloc, source, .none);
    defer ast.deinit();

    try std.testing.expectError(error.SyntaxError, parser.parseExpression(&ast));
}

test "parseString: plain string without interpolation remains expr_string_literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "\"no interp here\"");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_string_literal, n.tag);
}

test "parseString: \"hello #{$x} world\" splits into literal + interp + literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "\"hello #{$x} world\"");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_string_interp, n.tag);
    // `quoted` bit should be set.
    try std.testing.expectEqual(@as(u8, 1), n.flags);

    const part_count = ctx.ast.getExtraU32(n.payload);
    try std.testing.expectEqual(@as(u32, 3), part_count);

    // parts layout: [count, kind_0, val_0, kind_1, val_1, kind_2, val_2]
    const kind0 = ctx.ast.getExtraU32(n.payload + 1);
    const val0 = ctx.ast.getExtraU32(n.payload + 2);
    const kind1 = ctx.ast.getExtraU32(n.payload + 3);
    const val1 = ctx.ast.getExtraU32(n.payload + 4);
    const kind2 = ctx.ast.getExtraU32(n.payload + 5);
    const val2 = ctx.ast.getExtraU32(n.payload + 6);

    // Part 0: literal "hello "
    try std.testing.expectEqual(@as(u32, 0), kind0);
    const lit0: InternId = @enumFromInt(val0);
    try std.testing.expectEqualStrings("hello ", pool.get(lit0));

    // Part 1: interp  ->  expr_variable($x)
    try std.testing.expectEqual(@as(u32, 1), kind1);
    const node1: NodeIndex = @enumFromInt(val1);
    try std.testing.expectEqual(AstTag.expr_variable, ctx.ast.getNode(node1).tag);

    // Part 2: literal " world"
    try std.testing.expectEqual(@as(u32, 0), kind2);
    const lit2: InternId = @enumFromInt(val2);
    try std.testing.expectEqualStrings(" world", pool.get(lit2));
}

test "parseString: \"#{$x}\" \u{2014} single interp, no surrounding literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "\"#{$x}\"");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_string_interp, n.tag);
    const part_count = ctx.ast.getExtraU32(n.payload);
    try std.testing.expectEqual(@as(u32, 1), part_count);
    try std.testing.expectEqual(@as(u32, 1), ctx.ast.getExtraU32(n.payload + 1)); // kind = interp
}

test "parseString: \"\\#{notinterp}\" \u{2014} escaped `#` does not start interpolation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "\"\\#{notinterp}\"");
    defer ctx.ast.deinit();

    // No interpolation was detected (escaped `\#`), so this should
    // remain a simple string literal.
    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_string_literal, n.tag);
}

test "parseString: \"a#{ (1 + 2) * 3 }b\" \u{2014} interp with nested parens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "\"a#{ (1 + 2) * 3 }b\"");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_string_interp, n.tag);

    const part_count = ctx.ast.getExtraU32(n.payload);
    try std.testing.expectEqual(@as(u32, 3), part_count);

    // Part 1 should be the interp node: a multiplication.
    const kind1 = ctx.ast.getExtraU32(n.payload + 3);
    try std.testing.expectEqual(@as(u32, 1), kind1);
    const node1: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(n.payload + 4));
    try std.testing.expectEqual(AstTag.expr_binary_op, ctx.ast.getNode(node1).tag);
    const bin = readBinary(&ctx.ast, node1);
    try std.testing.expectEqual(BinOp.mul, bin.op);
}

test "parseString: interpolation body string is unquoted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "\"#{\"inner\"}\"");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_string_interp, n.tag);
    const part_count = ctx.ast.getExtraU32(n.payload);
    try std.testing.expectEqual(@as(u32, 1), part_count);

    const interp_kind = ctx.ast.getExtraU32(n.payload + 1);
    try std.testing.expectEqual(@as(u32, 1), interp_kind);
    const interp_node: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(n.payload + 2));
    const interp_inner = ctx.ast.getNode(interp_node);
    try std.testing.expectEqual(AstTag.expr_string_literal, interp_inner.tag);
    try std.testing.expectEqual(@as(u8, 0), interp_inner.flags & 0b0000_0001);
}

test "parseFuncCall: foo($args...) \u{2014} splat wraps a variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "foo($args...)");
    defer ctx.ast.deinit();

    const fc = readFuncCall(&ctx.ast, ctx.node);
    try std.testing.expectEqual(@as(u32, 1), fc.arg_count);

    const arg0: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(fc.arg_nodes_start));
    try std.testing.expectEqual(AstTag.expr_splat, ctx.ast.getNode(arg0).tag);

    // The wrapped inner expression is expr_variable.
    const inner: NodeIndex = @enumFromInt(ctx.ast.getNode(arg0).payload);
    try std.testing.expectEqual(AstTag.expr_variable, ctx.ast.getNode(inner).tag);
}

test "parseSpaceList: #{$x} is a valid atom in a space list" {
    // `a #{$x} b` should parse as a 3-item space list.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "a #{$x} b");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_space_list, n.tag);
    const list = readList(&ctx.ast, ctx.node);
    try std.testing.expectEqual(@as(u32, 3), list.len);

    const mid: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(list.items_off + 1));
    try std.testing.expectEqual(AstTag.expr_interp, ctx.ast.getNode(mid).tag);
}

// -- simple statement tests (R.2c.3) ------------------------------------------

/// Helper: lex `source`, build a Parser, run parse(), and return the
/// populated Ast.  Leaves ownership to the caller.
const ParseFullSourceResult = struct { parser: Parser, ast: Ast };

fn parseFullSource(alloc: std.mem.Allocator, pool: *InternPool, source: []const u8) !ParseFullSourceResult {
    return parseFullSourceWithSyntax(alloc, pool, source, false);
}

/// Same as `parseFullSource`, but lets tests opt into indented `.sass`
/// semantics explicitly.
fn parseFullSourceWithSyntax(
    alloc: std.mem.Allocator,
    pool: *InternPool,
    source: []const u8,
    is_indented_syntax: bool,
) !ParseFullSourceResult {
    var lexer = lexer_mod.Lexer.init(alloc, source);
    lexer.is_indented_syntax = is_indented_syntax;
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    var parser = Parser.init(alloc, pool, tokens, source);
    parser.is_indented_syntax = is_indented_syntax;
    var ast = try parser.parse();
    errdefer ast.deinit();

    return .{ .parser = parser, .ast = ast };
}

/// Read the stylesheet_root children array and return the NodeIndex
/// of the i-th top-level statement.
fn rootChild(ast: *const Ast, i: u32) NodeIndex {
    const root = ast.getNode(ast.root);
    std.debug.assert(root.tag == .stylesheet_root);
    return @enumFromInt(ast.getExtraU32(root.payload + 1 + i));
}

fn rootChildCount(ast: *const Ast) u32 {
    const root = ast.getNode(ast.root);
    std.debug.assert(root.tag == .stylesheet_root);
    return ast.getExtraU32(root.payload);
}

fn textTemplateLiteralId(ast: *const Ast, node: NodeIndex) InternId {
    const n = ast.getNode(node);
    std.debug.assert(n.tag == .expr_text_template);
    const off: ExtraIndex = n.payload;
    std.debug.assert(ast.getExtraU32(off) == 1);
    std.debug.assert(ast.getExtraU32(off + 1) == 0);
    return @enumFromInt(ast.getExtraU32(off + 2));
}

test "parse: simple variable decl `$x: 1;`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "$x: 1;");
    defer result.ast.deinit();

    try std.testing.expectEqual(@as(u32, 1), rootChildCount(&result.ast));
    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(AstTag.stmt_variable_decl, n.tag);

    // Extra layout: [name_id, value_node, flags_u32]
    const name_id: InternId = @enumFromInt(result.ast.getExtraU32(n.payload + 0));
    const value_node: NodeIndex = @enumFromInt(result.ast.getExtraU32(n.payload + 1));
    const flags = result.ast.getExtraU32(n.payload + 2);

    try std.testing.expectEqualStrings("x", pool.get(name_id));
    try std.testing.expectEqual(@as(u32, 0), flags);
    try expectNumberValue(&result.ast, value_node, 1.0);
}

test "parse: variable decl with !default flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "$color: red !default;");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(AstTag.stmt_variable_decl, n.tag);
    const flags = result.ast.getExtraU32(n.payload + 2);
    try std.testing.expectEqual(@as(u32, 0b01), flags);
}

test "parse: variable decl with !global flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "$y: 2 !global;");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const flags = result.ast.getExtraU32(result.ast.getNode(stmt).payload + 2);
    try std.testing.expectEqual(@as(u32, 0b10), flags);
}

test "parse: variable decl with both !default !global" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "$z: 3 !default !global;");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const flags = result.ast.getExtraU32(result.ast.getNode(stmt).payload + 2);
    try std.testing.expectEqual(@as(u32, 0b11), flags);
}

test "parse: variable decl without trailing semicolon (tolerated)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "$x: 42");
    defer result.ast.deinit();

    try std.testing.expectEqual(@as(u32, 1), rootChildCount(&result.ast));
    const stmt = rootChild(&result.ast, 0);
    try std.testing.expectEqual(AstTag.stmt_variable_decl, result.ast.getNode(stmt).tag);
}

test "parse: @return expression;" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@return 1 + 2;");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(AstTag.stmt_return, n.tag);

    const value: NodeIndex = @enumFromInt(n.payload);
    try std.testing.expectEqual(AstTag.expr_binary_op, result.ast.getNode(value).tag);
}

test "parse: @debug \"msg\"" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@debug \"hello\";");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    try std.testing.expectEqual(AstTag.stmt_debug, result.ast.getNode(stmt).tag);
    const value: NodeIndex = @enumFromInt(result.ast.getNode(stmt).payload);
    try std.testing.expectEqual(AstTag.expr_string_literal, result.ast.getNode(value).tag);
}

test "parse: @warn $x;" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@warn $x;");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    try std.testing.expectEqual(AstTag.stmt_warn, result.ast.getNode(stmt).tag);
    const value: NodeIndex = @enumFromInt(result.ast.getNode(stmt).payload);
    try std.testing.expectEqual(AstTag.expr_variable, result.ast.getNode(value).tag);
}

test "parse: @error \"oops\";" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@error \"oops\";");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    try std.testing.expectEqual(AstTag.stmt_error, result.ast.getNode(stmt).tag);
}

test "parse: multiple top-level statements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "$x: 1; @debug $x; @warn \"w\";");
    defer result.ast.deinit();

    try std.testing.expectEqual(@as(u32, 3), rootChildCount(&result.ast));

    const a = result.ast.getNode(rootChild(&result.ast, 0)).tag;
    const b = result.ast.getNode(rootChild(&result.ast, 1)).tag;
    const c = result.ast.getNode(rootChild(&result.ast, 2)).tag;
    try std.testing.expectEqual(AstTag.stmt_variable_decl, a);
    try std.testing.expectEqual(AstTag.stmt_debug, b);
    try std.testing.expectEqual(AstTag.stmt_warn, c);
}

test "parse: block comment at top level becomes stmt_comment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "/* outer comment */ $x: 1;");
    defer result.ast.deinit();

    try std.testing.expectEqual(@as(u32, 2), rootChildCount(&result.ast));
    try std.testing.expectEqual(AstTag.stmt_comment, result.ast.getNode(rootChild(&result.ast, 0)).tag);
    try std.testing.expectEqual(AstTag.stmt_variable_decl, result.ast.getNode(rootChild(&result.ast, 1)).tag);
}

test "parse: line comment is skipped (not emitted as stmt_comment)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "// gone\n$x: 1;");
    defer result.ast.deinit();

    try std.testing.expectEqual(@as(u32, 1), rootChildCount(&result.ast));
    try std.testing.expectEqual(AstTag.stmt_variable_decl, result.ast.getNode(rootChild(&result.ast, 0)).tag);
}

test "parse: stray top-level semicolons are tolerated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, ";;$x: 1;;;$y: 2;;");
    defer result.ast.deinit();

    try std.testing.expectEqual(@as(u32, 2), rootChildCount(&result.ast));
}

test "parse: variable decl with block comment inside value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "$x: 1 /* c */ 2;");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const value: NodeIndex = @enumFromInt(result.ast.getExtraU32(result.ast.getNode(stmt).payload + 1));
    try std.testing.expectEqual(AstTag.expr_space_list, result.ast.getNode(value).tag);
    const list = readList(&result.ast, value);
    try std.testing.expectEqual(@as(u32, 2), list.len);
}

test "parse: variable decl value is a comma list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "$list: 1, 2, 3;");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const value: NodeIndex = @enumFromInt(result.ast.getExtraU32(result.ast.getNode(stmt).payload + 1));
    try std.testing.expectEqual(AstTag.expr_comma_list, result.ast.getNode(value).tag);
}

test "parse: missing colon in variable decl \u{2192} SyntaxError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const source = "$x 1;";
    var lexer = lexer_mod.Lexer.init(alloc, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    var parser = Parser.init(alloc, &pool, tokens, source);
    defer parser.deinit();
    try std.testing.expectError(error.SyntaxError, parser.parse());
}

test "parse: empty source emits zero children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "");
    defer result.ast.deinit();
    try std.testing.expectEqual(@as(u32, 0), rootChildCount(&result.ast));
}

// -- control flow tests (R.2c.4) ----------------------------------------------

/// Read a len-prefixed child list and return `len` + offset of first
/// child NodeIndex.
fn readBlockBody(ast: *const Ast, extra_off: u32) struct { len: u32, first: u32 } {
    return .{ .len = ast.getExtraU32(extra_off), .first = extra_off + 1 };
}

test "parse: @if cond { debug cond }" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@if true { @debug 1; }");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(AstTag.stmt_if, n.tag);

    // extra: [cond_node, then_extra, elseif_count=0, else_extra=maxInt]
    const cond_node: NodeIndex = @enumFromInt(result.ast.getExtraU32(n.payload + 0));
    const then_extra = result.ast.getExtraU32(n.payload + 1);
    const elseif_count = result.ast.getExtraU32(n.payload + 2);
    const else_extra = result.ast.getExtraU32(n.payload + 3);

    try std.testing.expectEqual(AstTag.expr_bool_true, result.ast.getNode(cond_node).tag);
    try std.testing.expectEqual(@as(u32, 0), elseif_count);
    try std.testing.expectEqual(std.math.maxInt(u32), else_extra);

    const then_body = readBlockBody(&result.ast, then_extra);
    try std.testing.expectEqual(@as(u32, 1), then_body.len);
    const debug_idx: NodeIndex = @enumFromInt(result.ast.getExtraU32(then_body.first));
    try std.testing.expectEqual(AstTag.stmt_debug, result.ast.getNode(debug_idx).tag);
}

test "parse: @if / @else if / @else chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@if $a { @debug 1; } @else if $b { @debug 2; } @else { @debug 3; }");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(AstTag.stmt_if, n.tag);

    const elseif_count = result.ast.getExtraU32(n.payload + 2);
    try std.testing.expectEqual(@as(u32, 1), elseif_count);

    // elseif_0 cond_node is at payload + 3, body_extra at payload + 4.
    const ec0: NodeIndex = @enumFromInt(result.ast.getExtraU32(n.payload + 3));
    try std.testing.expectEqual(AstTag.expr_variable, result.ast.getNode(ec0).tag);

    // else_body_extra is after the elseif pairs: payload + 3 + 2*count
    const else_slot = n.payload + 3 + 2;
    const else_extra = result.ast.getExtraU32(else_slot);
    try std.testing.expect(else_extra != std.math.maxInt(u32));

    const else_body = readBlockBody(&result.ast, else_extra);
    try std.testing.expectEqual(@as(u32, 1), else_body.len);
}

test "parse: @if with two elseifs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@if $a { @debug 1; } @else if $b { @debug 2; } @else if $c { @debug 3; }");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    const elseif_count = result.ast.getExtraU32(n.payload + 2);
    try std.testing.expectEqual(@as(u32, 2), elseif_count);

    // No else clause  ->  else_extra is maxInt.
    const else_slot = n.payload + 3 + 2 * 2;
    try std.testing.expectEqual(std.math.maxInt(u32), result.ast.getExtraU32(else_slot));
}

test "parse: legacy @elseif single keyword" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@if $a { @debug 1; } @elseif $b { @debug 2; }");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    const elseif_count = result.ast.getExtraU32(n.payload + 2);
    try std.testing.expectEqual(@as(u32, 1), elseif_count);
}

test "parse: indented @if keeps body after single-line condition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const src =
        \\@if true
        \\  a
        \\    b: c
    ;
    var result = try parseFullSourceWithSyntax(alloc, &pool, src, true);
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(AstTag.stmt_if, n.tag);

    const then_extra = result.ast.getExtraU32(n.payload + 1);
    const then_body = readBlockBody(&result.ast, then_extra);
    try std.testing.expectEqual(@as(u32, 1), then_body.len);

    const body_stmt: NodeIndex = @enumFromInt(result.ast.getExtraU32(then_body.first));
    try std.testing.expectEqual(AstTag.stmt_style_rule, result.ast.getNode(body_stmt).tag);
}

test "parse: indented @if multiline condition keeps body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const src =
        \\@if
        \\  true and
        \\  true
        \\  a
        \\    b: c
    ;
    var result = try parseFullSourceWithSyntax(alloc, &pool, src, true);
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(AstTag.stmt_if, n.tag);

    const cond_node: NodeIndex = @enumFromInt(result.ast.getExtraU32(n.payload + 0));
    try std.testing.expectEqual(AstTag.expr_binary_op, result.ast.getNode(cond_node).tag);

    const then_extra = result.ast.getExtraU32(n.payload + 1);
    const then_body = readBlockBody(&result.ast, then_extra);
    try std.testing.expectEqual(@as(u32, 1), then_body.len);

    const body_stmt: NodeIndex = @enumFromInt(result.ast.getExtraU32(then_body.first));
    try std.testing.expectEqual(AstTag.stmt_style_rule, result.ast.getNode(body_stmt).tag);
}

test "parse: @each $color in red, blue { @debug $color; }" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@each $color in red, blue { @debug $color; }");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(AstTag.stmt_each, n.tag);

    // extra: [var_count, var_id_0, ..., list_node, body_extra]
    const var_count = result.ast.getExtraU32(n.payload + 0);
    try std.testing.expectEqual(@as(u32, 1), var_count);

    const var_id: InternId = @enumFromInt(result.ast.getExtraU32(n.payload + 1));
    try std.testing.expectEqualStrings("color", pool.get(var_id));

    const list_node: NodeIndex = @enumFromInt(result.ast.getExtraU32(n.payload + 1 + var_count));
    try std.testing.expectEqual(AstTag.expr_comma_list, result.ast.getNode(list_node).tag);

    const body_extra = result.ast.getExtraU32(n.payload + 1 + var_count + 1);
    const body = readBlockBody(&result.ast, body_extra);
    try std.testing.expectEqual(@as(u32, 1), body.len);
}

test "parse: @each allows trailing comma before block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@each $x in (a), (b), { .#{$x} { y: z; } }");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(AstTag.stmt_each, n.tag);

    const var_count = result.ast.getExtraU32(n.payload + 0);
    try std.testing.expectEqual(@as(u32, 1), var_count);

    const list_node: NodeIndex = @enumFromInt(result.ast.getExtraU32(n.payload + 1 + var_count));
    try std.testing.expectEqual(AstTag.expr_comma_list, result.ast.getNode(list_node).tag);
}

test "parse: @each $k, $v in $map { body }" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@each $k, $v in $map { @debug $k; }");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(AstTag.stmt_each, n.tag);
    const var_count = result.ast.getExtraU32(n.payload + 0);
    try std.testing.expectEqual(@as(u32, 2), var_count);

    const v0: InternId = @enumFromInt(result.ast.getExtraU32(n.payload + 1));
    const v1: InternId = @enumFromInt(result.ast.getExtraU32(n.payload + 2));
    try std.testing.expectEqualStrings("k", pool.get(v0));
    try std.testing.expectEqualStrings("v", pool.get(v1));
}

test "parse: indented @each multiline header keeps body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const src =
        \\@each
        \\  $a in b, c
        \\  .#{$a}
        \\    d: $a
    ;
    var result = try parseFullSource(alloc, &pool, src);
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(AstTag.stmt_each, n.tag);
    const var_count = result.ast.getExtraU32(n.payload + 0);
    try std.testing.expectEqual(@as(u32, 1), var_count);
    const body_extra = result.ast.getExtraU32(n.payload + 1 + var_count + 1);
    const body = readBlockBody(&result.ast, body_extra);
    try std.testing.expectEqual(@as(u32, 1), body.len);
}

test "parse: @for $i from 1 through 5 { @debug $i; }" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@for $i from 1 through 5 { @debug $i; }");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(AstTag.stmt_for, n.tag);
    try std.testing.expectEqual(@as(u8, 0), n.flags); // `through` = inclusive

    const var_id: InternId = @enumFromInt(result.ast.getExtraU32(n.payload + 0));
    try std.testing.expectEqualStrings("i", pool.get(var_id));
    const from_node: NodeIndex = @enumFromInt(result.ast.getExtraU32(n.payload + 1));
    const to_node: NodeIndex = @enumFromInt(result.ast.getExtraU32(n.payload + 2));
    try expectNumberValue(&result.ast, from_node, 1.0);
    try expectNumberValue(&result.ast, to_node, 5.0);
}

test "parse: @for $i from 1 to 5 { ... } \u{2014} `to` sets exclusive flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@for $i from 1 to 5 { @debug $i; }");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(@as(u8, 1), n.flags); // exclusive
}

test "parse: @for with binary-expr endpoints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@for $i from 1 + 1 through 2 * 5 { @debug $i; }");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    const from_node: NodeIndex = @enumFromInt(result.ast.getExtraU32(n.payload + 1));
    const to_node: NodeIndex = @enumFromInt(result.ast.getExtraU32(n.payload + 2));
    try std.testing.expectEqual(AstTag.expr_binary_op, result.ast.getNode(from_node).tag);
    try std.testing.expectEqual(AstTag.expr_binary_op, result.ast.getNode(to_node).tag);
}

test "parse: indented @for keeps body after header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const src =
        \\@for $i from 1 through 2
        \\  .n-#{$i}
        \\    x: y
    ;
    var result = try parseFullSource(alloc, &pool, src);
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(AstTag.stmt_for, n.tag);
    const body_extra = result.ast.getExtraU32(n.payload + 3);
    const body = readBlockBody(&result.ast, body_extra);
    try std.testing.expectEqual(@as(u32, 1), body.len);
}

test "parse: @while $x > 0 { $x: $x - 1; }" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@while $x > 0 { $x: $x - 1; }");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(AstTag.stmt_while, n.tag);

    const cond_node: NodeIndex = @enumFromInt(result.ast.getExtraU32(n.payload + 0));
    try std.testing.expectEqual(AstTag.expr_binary_op, result.ast.getNode(cond_node).tag);
    const cond_bin = readBinary(&result.ast, cond_node);
    try std.testing.expectEqual(BinOp.gt, cond_bin.op);

    const body_extra = result.ast.getExtraU32(n.payload + 1);
    const body = readBlockBody(&result.ast, body_extra);
    try std.testing.expectEqual(@as(u32, 1), body.len);
    const decl_idx: NodeIndex = @enumFromInt(result.ast.getExtraU32(body.first));
    try std.testing.expectEqual(AstTag.stmt_variable_decl, result.ast.getNode(decl_idx).tag);
}

test "parse: nested @if inside @each" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@each $x in 1, 2, 3 { @if $x > 1 { @debug $x; } }");
    defer result.ast.deinit();

    const each_stmt = rootChild(&result.ast, 0);
    const each_n = result.ast.getNode(each_stmt);
    try std.testing.expectEqual(AstTag.stmt_each, each_n.tag);

    // body children: one stmt_if
    const var_count = result.ast.getExtraU32(each_n.payload + 0);
    const body_extra = result.ast.getExtraU32(each_n.payload + 1 + var_count + 1);
    const body = readBlockBody(&result.ast, body_extra);
    try std.testing.expectEqual(@as(u32, 1), body.len);
    const inner_if: NodeIndex = @enumFromInt(result.ast.getExtraU32(body.first));
    try std.testing.expectEqual(AstTag.stmt_if, result.ast.getNode(inner_if).tag);
}

test "parse: @if with unterminated block \u{2192} SyntaxError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const source = "@if true { @debug 1; ";
    var lexer = lexer_mod.Lexer.init(alloc, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    var parser = Parser.init(alloc, &pool, tokens, source);
    defer parser.deinit();
    try std.testing.expectError(error.SyntaxError, parser.parse());
}

test "parse: @for missing `from` keyword \u{2192} SyntaxError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const source = "@for $i 1 through 5 { }";
    var lexer = lexer_mod.Lexer.init(alloc, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    var parser = Parser.init(alloc, &pool, tokens, source);
    defer parser.deinit();
    try std.testing.expectError(error.SyntaxError, parser.parse());
}

test "parse: @each missing `in` keyword \u{2192} SyntaxError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const source = "@each $x 1, 2 { }";
    var lexer = lexer_mod.Lexer.init(alloc, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    var parser = Parser.init(alloc, &pool, tokens, source);
    defer parser.deinit();
    try std.testing.expectError(error.SyntaxError, parser.parse());
}

// -- module + content tests (R.2c.5) ------------------------------------------

test "parse: @use \"sass:math\";" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@use \"sass:math\";");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(AstTag.stmt_use, n.tag);

    // extra: [url_id, namespace_id, config_extra]
    const url_id: InternId = @enumFromInt(result.ast.getExtraU32(n.payload + 0));
    const ns_id: InternId = @enumFromInt(result.ast.getExtraU32(n.payload + 1));
    const config_extra = result.ast.getExtraU32(n.payload + 2);

    try std.testing.expectEqualStrings("sass:math", pool.get(url_id));
    try std.testing.expectEqual(InternId.none, ns_id);
    try std.testing.expectEqual(std.math.maxInt(u32), config_extra);
    try std.testing.expectEqual(@as(u8, 0), n.flags); // not as_star
}

test "parse: @use \"colors\" as c;" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@use \"colors\" as c;");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(AstTag.stmt_use, n.tag);

    const ns_id: InternId = @enumFromInt(result.ast.getExtraU32(n.payload + 1));
    try std.testing.expectEqualStrings("c", pool.get(ns_id));
    try std.testing.expectEqual(@as(u8, 0), n.flags);
}

test "parse: @use \"colors\" as *;" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@use \"colors\" as *;");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(@as(u8, 1), n.flags); // as_star bit set
    const ns_id: InternId = @enumFromInt(result.ast.getExtraU32(n.payload + 1));
    try std.testing.expectEqual(InternId.none, ns_id);
}

test "parse: @use with ($primary: red, $secondary: blue);" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@use \"theme\" with ($primary: red, $secondary: blue);");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(AstTag.stmt_use, n.tag);

    const config_extra = result.ast.getExtraU32(n.payload + 2);
    try std.testing.expect(config_extra != std.math.maxInt(u32));
    try std.testing.expectEqual(@as(u32, 2), result.ast.getExtraU32(config_extra + 0));

    const name0: InternId = @enumFromInt(result.ast.getExtraU32(config_extra + 1));
    const expr0 = result.ast.getNode(@enumFromInt(result.ast.getExtraU32(config_extra + 2)));
    const flags0 = result.ast.getExtraU32(config_extra + 3);
    const name1: InternId = @enumFromInt(result.ast.getExtraU32(config_extra + 4));
    const expr1 = result.ast.getNode(@enumFromInt(result.ast.getExtraU32(config_extra + 5)));
    const flags1 = result.ast.getExtraU32(config_extra + 6);

    try std.testing.expectEqualStrings("primary", pool.get(name0));
    try std.testing.expectEqual(AstTag.expr_unquoted_ident, expr0.tag);
    try std.testing.expectEqual(@as(u32, 0), flags0);
    try std.testing.expectEqualStrings("secondary", pool.get(name1));
    try std.testing.expectEqual(AstTag.expr_unquoted_ident, expr1.tag);
    try std.testing.expectEqual(@as(u32, 0), flags1);
}

test "parse: @forward \"colors\";" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@forward \"colors\";");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(AstTag.stmt_forward, n.tag);

    const url_id: InternId = @enumFromInt(result.ast.getExtraU32(n.payload + 0));
    try std.testing.expectEqualStrings("colors", pool.get(url_id));
    // prefix / show / hide / config all absent
    try std.testing.expectEqual(InternId.none, @as(InternId, @enumFromInt(result.ast.getExtraU32(n.payload + 1))));
    try std.testing.expectEqual(std.math.maxInt(u32), result.ast.getExtraU32(n.payload + 2));
    try std.testing.expectEqual(std.math.maxInt(u32), result.ast.getExtraU32(n.payload + 3));
    try std.testing.expectEqual(std.math.maxInt(u32), result.ast.getExtraU32(n.payload + 4));
}

test "parse: @forward with as prefix-*" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@forward \"colors\" as theme-*;");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    const prefix_id: InternId = @enumFromInt(result.ast.getExtraU32(n.payload + 1));
    try std.testing.expect(prefix_id != .none);
    try std.testing.expectEqualStrings("theme-", pool.get(prefix_id));
}

test "parse: @forward with show / hide clauses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@forward \"utils\" show $primary, my-func hide $hidden;");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    const show_extra = result.ast.getExtraU32(n.payload + 2);
    const hide_extra = result.ast.getExtraU32(n.payload + 3);
    try std.testing.expect(show_extra != std.math.maxInt(u32));
    try std.testing.expect(hide_extra != std.math.maxInt(u32));

    // show list: [count, $primary, my-func]
    try std.testing.expectEqual(@as(u32, 2), result.ast.getExtraU32(show_extra));
    const s0: InternId = @enumFromInt(result.ast.getExtraU32(show_extra + 1));
    const s1: InternId = @enumFromInt(result.ast.getExtraU32(show_extra + 2));
    try std.testing.expectEqualStrings("$primary", pool.get(s0));
    try std.testing.expectEqualStrings("my-func", pool.get(s1));

    // hide list: [count, $hidden]
    try std.testing.expectEqual(@as(u32, 1), result.ast.getExtraU32(hide_extra));
    const h0: InternId = @enumFromInt(result.ast.getExtraU32(hide_extra + 1));
    try std.testing.expectEqualStrings("$hidden", pool.get(h0));
}

test "parse: @forward with (...) config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@forward \"theme\" with ($primary: red !default);");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    const config_extra = result.ast.getExtraU32(n.payload + 4);
    try std.testing.expect(config_extra != std.math.maxInt(u32));
    try std.testing.expectEqual(@as(u32, 1), result.ast.getExtraU32(config_extra + 0));
    const name0: InternId = @enumFromInt(result.ast.getExtraU32(config_extra + 1));
    const expr0 = result.ast.getNode(@enumFromInt(result.ast.getExtraU32(config_extra + 2)));
    const flags0 = result.ast.getExtraU32(config_extra + 3);
    try std.testing.expectEqualStrings("primary", pool.get(name0));
    try std.testing.expectEqual(AstTag.expr_unquoted_ident, expr0.tag);
    try std.testing.expectEqual(@as(u32, 1), flags0 & 1);
}

test "parse: @import \"vars\";" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const source = "@import \"vars\";";
    var result = try parseFullSource(alloc, &pool, source);
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(AstTag.stmt_import, n.tag);
    const url_expr = result.ast.getNode(@enumFromInt(result.ast.getExtraU32(n.payload + 0)));
    try std.testing.expectEqual(AstTag.expr_text_template, url_expr.tag);
    const url_id = textTemplateLiteralId(&result.ast, @enumFromInt(result.ast.getExtraU32(n.payload + 0)));
    try std.testing.expectEqualStrings("\"vars\"", pool.get(url_id));
    try std.testing.expectEqual(std.math.maxInt(u32), result.ast.getExtraU32(n.payload + 1));
}

test "parse: @import url(foo.css);" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const source = "@import url(\"foo.css\");";
    var result = try parseFullSource(alloc, &pool, source);
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(AstTag.stmt_import, n.tag);
    const url_expr = result.ast.getNode(@enumFromInt(result.ast.getExtraU32(n.payload + 0)));
    try std.testing.expectEqual(AstTag.expr_text_template, url_expr.tag);
    const url_id = textTemplateLiteralId(&result.ast, @enumFromInt(result.ast.getExtraU32(n.payload + 0)));
    try std.testing.expectEqualStrings("url(\"foo.css\")", pool.get(url_id));
}

test "parse: @import \"a\" screen;" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const source = "@import \"a\" screen;";
    var result = try parseFullSource(alloc, &pool, source);
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(AstTag.stmt_import, n.tag);
    const cond_idx: NodeIndex = @enumFromInt(result.ast.getExtraU32(n.payload + 1));
    const cond_node = result.ast.getNode(cond_idx);
    try std.testing.expectEqual(AstTag.expr_text_template, cond_node.tag);
    const cond_id = textTemplateLiteralId(&result.ast, cond_idx);
    try std.testing.expectEqualStrings("screen", pool.get(cond_id));
}

test "parse: multi-URL @import emits one stmt_import per URL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const source = "@import \"a\", \"b\";";
    var result = try parseFullSource(alloc, &pool, source);
    defer result.ast.deinit();

    // Expect 2 stylesheet children, both stmt_import.
    const root_node = result.ast.getNode(result.ast.root);
    const extra_off = root_node.payload;
    try std.testing.expectEqual(@as(u32, 2), result.ast.getExtraU32(extra_off));

    const first = rootChild(&result.ast, 0);
    const first_n = result.ast.getNode(first);
    try std.testing.expectEqual(AstTag.stmt_import, first_n.tag);
    const first_url_idx: NodeIndex = @enumFromInt(result.ast.getExtraU32(first_n.payload + 0));
    const first_url = result.ast.getNode(first_url_idx);
    try std.testing.expectEqual(AstTag.expr_text_template, first_url.tag);
    const first_id = textTemplateLiteralId(&result.ast, first_url_idx);
    try std.testing.expectEqualStrings("\"a\"", pool.get(first_id));

    const second = rootChild(&result.ast, 1);
    const second_n = result.ast.getNode(second);
    try std.testing.expectEqual(AstTag.stmt_import, second_n.tag);
    const second_url_idx: NodeIndex = @enumFromInt(result.ast.getExtraU32(second_n.payload + 0));
    const second_url = result.ast.getNode(second_url_idx);
    try std.testing.expectEqual(AstTag.expr_text_template, second_url.tag);
    const second_id = textTemplateLiteralId(&result.ast, second_url_idx);
    try std.testing.expectEqualStrings("\"b\"", pool.get(second_id));
}

test "parse: @content with no args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@content;");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(AstTag.stmt_content, n.tag);
    try std.testing.expectEqual(@as(u32, 0), result.ast.getExtraU32(n.payload));
}

test "parse: @content(1, $x: 2)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@content(1, $x: 2);");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(AstTag.stmt_content, n.tag);

    // Layout: [count, arg_node_0, arg_node_1, name_0, name_1]
    const count = result.ast.getExtraU32(n.payload);
    try std.testing.expectEqual(@as(u32, 2), count);

    const a0: NodeIndex = @enumFromInt(result.ast.getExtraU32(n.payload + 1));
    try expectNumberValue(&result.ast, a0, 1.0);

    const name0: InternId = @enumFromInt(result.ast.getExtraU32(n.payload + 3));
    const name1: InternId = @enumFromInt(result.ast.getExtraU32(n.payload + 4));
    try std.testing.expectEqual(InternId.none, name0);
    try std.testing.expect(name1 != .none);
    try std.testing.expectEqualStrings("x", pool.get(name1));
}

// -- style rule + declaration tests (R.2c.6a) ---------------------------------

/// Read the `[selector_node, body_extra]` fixed header of a
/// stmt_style_rule.
const StyleRulePayload = struct {
    selector_node: NodeIndex,
    body_extra: u32,
};

fn readStyleRule(ast: *const Ast, node: NodeIndex) StyleRulePayload {
    const n = ast.getNode(node);
    std.debug.assert(n.tag == .stmt_style_rule);
    return .{
        .selector_node = @enumFromInt(ast.getExtraU32(n.payload)),
        .body_extra = ast.getExtraU32(n.payload + 1),
    };
}

test "parse: simple style rule `.foo { color: red; }`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, ".foo { color: red; }");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    try std.testing.expectEqual(AstTag.stmt_style_rule, result.ast.getNode(stmt).tag);

    const sr = readStyleRule(&result.ast, stmt);
    const sel_n = result.ast.getNode(sr.selector_node);
    try std.testing.expectEqual(AstTag.expr_unquoted_ident, sel_n.tag);
    const sel_id: InternId = @enumFromInt(sel_n.payload);
    try std.testing.expectEqualStrings(".foo", pool.get(sel_id));

    const body = readBlockBody(&result.ast, sr.body_extra);
    try std.testing.expectEqual(@as(u32, 1), body.len);

    const decl: NodeIndex = @enumFromInt(result.ast.getExtraU32(body.first));
    try std.testing.expectEqual(AstTag.stmt_declaration, result.ast.getNode(decl).tag);
}

test "parse: declaration property and value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, ".box { font-size: 14px; }");
    defer result.ast.deinit();

    const rule = rootChild(&result.ast, 0);
    const sr = readStyleRule(&result.ast, rule);
    const body = readBlockBody(&result.ast, sr.body_extra);
    const decl: NodeIndex = @enumFromInt(result.ast.getExtraU32(body.first));
    const dn = result.ast.getNode(decl);
    try std.testing.expectEqual(AstTag.stmt_declaration, dn.tag);

    // extra: [prop_node, value_node]
    const prop: NodeIndex = @enumFromInt(result.ast.getExtraU32(dn.payload));
    const val: NodeIndex = @enumFromInt(result.ast.getExtraU32(dn.payload + 1));

    try std.testing.expectEqual(AstTag.expr_unquoted_ident, result.ast.getNode(prop).tag);
    const prop_id: InternId = @enumFromInt(result.ast.getNode(prop).payload);
    try std.testing.expectEqualStrings("font-size", pool.get(prop_id));

    try std.testing.expectEqual(AstTag.expr_number_literal, result.ast.getNode(val).tag);
}

test "parse: custom property `--accent: red` sets flags bit 0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, ".a { --accent: red; }");
    defer result.ast.deinit();

    const rule = rootChild(&result.ast, 0);
    const body = readBlockBody(&result.ast, readStyleRule(&result.ast, rule).body_extra);
    const decl: NodeIndex = @enumFromInt(result.ast.getExtraU32(body.first));
    try std.testing.expectEqual(@as(u8, 0b01), result.ast.getNode(decl).flags);
}

test "parse: nested style rule inside a style rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, ".parent { .child { color: red; } }");
    defer result.ast.deinit();

    const parent = rootChild(&result.ast, 0);
    try std.testing.expectEqual(AstTag.stmt_style_rule, result.ast.getNode(parent).tag);

    const body = readBlockBody(&result.ast, readStyleRule(&result.ast, parent).body_extra);
    try std.testing.expectEqual(@as(u32, 1), body.len);
    const child: NodeIndex = @enumFromInt(result.ast.getExtraU32(body.first));
    try std.testing.expectEqual(AstTag.stmt_style_rule, result.ast.getNode(child).tag);
}

test "parse: multiple declarations in one style rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, ".card { color: red; background: blue; padding: 10px; }");
    defer result.ast.deinit();

    const rule = rootChild(&result.ast, 0);
    const body = readBlockBody(&result.ast, readStyleRule(&result.ast, rule).body_extra);
    try std.testing.expectEqual(@as(u32, 3), body.len);
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const d: NodeIndex = @enumFromInt(result.ast.getExtraU32(body.first + i));
        try std.testing.expectEqual(AstTag.stmt_declaration, result.ast.getNode(d).tag);
    }
}

test "parse: pseudo-class selector :hover is a style rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "a:hover { color: red; }");
    defer result.ast.deinit();

    const rule = rootChild(&result.ast, 0);
    try std.testing.expectEqual(AstTag.stmt_style_rule, result.ast.getNode(rule).tag);

    const sel_n = result.ast.getNode(readStyleRule(&result.ast, rule).selector_node);
    const sel_id: InternId = @enumFromInt(sel_n.payload);
    try std.testing.expectEqualStrings("a:hover", pool.get(sel_id));
}

test "parse: double-colon pseudo-element ::before" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, ".x::before { content: \"\"; }");
    defer result.ast.deinit();

    const rule = rootChild(&result.ast, 0);
    try std.testing.expectEqual(AstTag.stmt_style_rule, result.ast.getNode(rule).tag);
}

test "parse: functional pseudo :not(.inner)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "div:not(.inner) { color: red; }");
    defer result.ast.deinit();

    const rule = rootChild(&result.ast, 0);
    try std.testing.expectEqual(AstTag.stmt_style_rule, result.ast.getNode(rule).tag);
}

test "parse: attribute selector [type=\"text\"]" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "input[type=\"text\"] { border: 1px; }");
    defer result.ast.deinit();

    const rule = rootChild(&result.ast, 0);
    try std.testing.expectEqual(AstTag.stmt_style_rule, result.ast.getNode(rule).tag);
}

test "parse: parent selector `&`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, ".foo { &:hover { color: red; } }");
    defer result.ast.deinit();

    const outer = rootChild(&result.ast, 0);
    const body = readBlockBody(&result.ast, readStyleRule(&result.ast, outer).body_extra);
    try std.testing.expectEqual(@as(u32, 1), body.len);
    const inner: NodeIndex = @enumFromInt(result.ast.getExtraU32(body.first));
    try std.testing.expectEqual(AstTag.stmt_style_rule, result.ast.getNode(inner).tag);
}

test "parse: comma-separated selector list `.a, .b { }`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, ".a, .b { color: red; }");
    defer result.ast.deinit();

    const rule = rootChild(&result.ast, 0);
    try std.testing.expectEqual(AstTag.stmt_style_rule, result.ast.getNode(rule).tag);
    const sel_n = result.ast.getNode(readStyleRule(&result.ast, rule).selector_node);
    const sel_id: InternId = @enumFromInt(sel_n.payload);
    try std.testing.expectEqualStrings(".a, .b", pool.get(sel_id));
}

test "parse: declaration without trailing semicolon (soft terminator)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, ".x { color: red }");
    defer result.ast.deinit();

    const rule = rootChild(&result.ast, 0);
    const body = readBlockBody(&result.ast, readStyleRule(&result.ast, rule).body_extra);
    try std.testing.expectEqual(@as(u32, 1), body.len);
}

test "parse: declaration with interpolation in property name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, ".box { #{$prop}: 10px; }");
    defer result.ast.deinit();

    const rule = rootChild(&result.ast, 0);
    const body = readBlockBody(&result.ast, readStyleRule(&result.ast, rule).body_extra);
    try std.testing.expectEqual(@as(u32, 1), body.len);
    const decl: NodeIndex = @enumFromInt(result.ast.getExtraU32(body.first));
    try std.testing.expectEqual(AstTag.stmt_declaration, result.ast.getNode(decl).tag);
}

test "parse: declaration with nested @if" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, ".box { @if true { color: red; } }");
    defer result.ast.deinit();

    const rule = rootChild(&result.ast, 0);
    const body = readBlockBody(&result.ast, readStyleRule(&result.ast, rule).body_extra);
    try std.testing.expectEqual(@as(u32, 1), body.len);
    const if_stmt: NodeIndex = @enumFromInt(result.ast.getExtraU32(body.first));
    try std.testing.expectEqual(AstTag.stmt_if, result.ast.getNode(if_stmt).tag);
}

test "parse: declaration missing colon \u{2192} SyntaxError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const source = ".a { color red; }";
    var lexer = lexer_mod.Lexer.init(alloc, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    var parser = Parser.init(alloc, &pool, tokens, source);
    defer parser.deinit();
    try std.testing.expectError(error.SyntaxError, parser.parse());
}

// -- @extend + @at-root tests (R.2c.6b) --------------------------------------

test "parse: @extend .foo;" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, ".a { @extend .foo; }");
    defer result.ast.deinit();

    const rule = rootChild(&result.ast, 0);
    const body = readBlockBody(&result.ast, readStyleRule(&result.ast, rule).body_extra);
    const ext_node: NodeIndex = @enumFromInt(result.ast.getExtraU32(body.first));
    const ext = result.ast.getNode(ext_node);
    try std.testing.expectEqual(AstTag.stmt_extend, ext.tag);
    try std.testing.expectEqual(@as(u8, 0), ext.flags);

    const sel_node: NodeIndex = @enumFromInt(result.ast.getExtraU32(ext.payload));
    const sel_n = result.ast.getNode(sel_node);
    const sel_id: InternId = @enumFromInt(sel_n.payload);
    try std.testing.expectEqualStrings(".foo", pool.get(sel_id));
}

test "parse: @extend .foo !optional;" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, ".a { @extend .foo !optional; }");
    defer result.ast.deinit();

    const rule = rootChild(&result.ast, 0);
    const body = readBlockBody(&result.ast, readStyleRule(&result.ast, rule).body_extra);
    const ext_node: NodeIndex = @enumFromInt(result.ast.getExtraU32(body.first));
    const ext = result.ast.getNode(ext_node);
    try std.testing.expectEqual(AstTag.stmt_extend, ext.tag);
    try std.testing.expectEqual(@as(u8, 0b0000_0001), ext.flags);

    const sel_node: NodeIndex = @enumFromInt(result.ast.getExtraU32(ext.payload));
    const sel_id: InternId = @enumFromInt(result.ast.getNode(sel_node).payload);
    try std.testing.expectEqualStrings(".foo", pool.get(sel_id));
}

test "parse: indented @extend keeps inline !optional on same line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSourceWithSyntax(
        alloc,
        &pool,
        ".a\n  @extend .foo !optional\n",
        true,
    );
    defer result.ast.deinit();

    const rule = rootChild(&result.ast, 0);
    const body = readBlockBody(&result.ast, readStyleRule(&result.ast, rule).body_extra);
    const ext_node: NodeIndex = @enumFromInt(result.ast.getExtraU32(body.first));
    const ext = result.ast.getNode(ext_node);
    try std.testing.expectEqual(AstTag.stmt_extend, ext.tag);
    try std.testing.expectEqual(@as(u8, 0b0000_0001), ext.flags);

    const sel_node: NodeIndex = @enumFromInt(result.ast.getExtraU32(ext.payload));
    const sel_id: InternId = @enumFromInt(result.ast.getNode(sel_node).payload);
    try std.testing.expectEqualStrings(".foo", pool.get(sel_id));
}

test "parse: indented @extend with sibling !optional line is syntax error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    try std.testing.expectError(
        error.SyntaxError,
        parseFullSourceWithSyntax(
            alloc,
            &pool,
            ".a\n  @extend .foo\n  !optional\n",
            true,
        ),
    );
}

test "parse: @extend with compound selector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, ".a { @extend .btn.primary; }");
    defer result.ast.deinit();

    const rule = rootChild(&result.ast, 0);
    const body = readBlockBody(&result.ast, readStyleRule(&result.ast, rule).body_extra);
    const ext_node: NodeIndex = @enumFromInt(result.ast.getExtraU32(body.first));
    const ext = result.ast.getNode(ext_node);
    const sel_node: NodeIndex = @enumFromInt(result.ast.getExtraU32(ext.payload));
    const sel_id: InternId = @enumFromInt(result.ast.getNode(sel_node).payload);
    try std.testing.expectEqualStrings(".btn.primary", pool.get(sel_id));
}

test "parse: @at-root { body } with no selector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, ".foo { @at-root { .bar { color: red; } } }");
    defer result.ast.deinit();

    const outer = rootChild(&result.ast, 0);
    const outer_body = readBlockBody(&result.ast, readStyleRule(&result.ast, outer).body_extra);
    const at_root_node: NodeIndex = @enumFromInt(result.ast.getExtraU32(outer_body.first));
    const at_root = result.ast.getNode(at_root_node);
    try std.testing.expectEqual(AstTag.stmt_at_root, at_root.tag);

    // Selector slot is u32.max (no selector)
    const sel_slot = result.ast.getExtraU32(at_root.payload);
    try std.testing.expectEqual(std.math.maxInt(u32), sel_slot);

    // Body has one child (the nested .bar rule).
    const at_root_body_extra = result.ast.getExtraU32(at_root.payload + 1);
    const at_root_body = readBlockBody(&result.ast, at_root_body_extra);
    try std.testing.expectEqual(@as(u32, 1), at_root_body.len);
}

test "parse: @at-root .foo { ... } with selector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, ".parent { @at-root .foo { color: red; } }");
    defer result.ast.deinit();

    const outer = rootChild(&result.ast, 0);
    const outer_body = readBlockBody(&result.ast, readStyleRule(&result.ast, outer).body_extra);
    const at_root_node: NodeIndex = @enumFromInt(result.ast.getExtraU32(outer_body.first));
    const at_root = result.ast.getNode(at_root_node);
    try std.testing.expectEqual(AstTag.stmt_at_root, at_root.tag);

    // Selector is `.foo`
    const sel_slot = result.ast.getExtraU32(at_root.payload);
    try std.testing.expect(sel_slot != std.math.maxInt(u32));
    const sel_node: NodeIndex = @enumFromInt(sel_slot);
    const sel_id: InternId = @enumFromInt(result.ast.getNode(sel_node).payload);
    try std.testing.expectEqualStrings(".foo", pool.get(sel_id));
}

test "parse: @at-root (with: media) { ... } modifier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, ".parent { @at-root (with: media) { .inner { color: red; } } }");
    defer result.ast.deinit();

    const outer = rootChild(&result.ast, 0);
    const outer_body = readBlockBody(&result.ast, readStyleRule(&result.ast, outer).body_extra);
    const at_root_node: NodeIndex = @enumFromInt(result.ast.getExtraU32(outer_body.first));
    const at_root = result.ast.getNode(at_root_node);
    try std.testing.expectEqual(AstTag.stmt_at_root, at_root.tag);

    // The modifier `(with: media)` is captured as part of the
    // selector span.
    const sel_slot = result.ast.getExtraU32(at_root.payload);
    try std.testing.expect(sel_slot != std.math.maxInt(u32));
    const sel_node: NodeIndex = @enumFromInt(sel_slot);
    const sel_id: InternId = @enumFromInt(result.ast.getNode(sel_node).payload);
    try std.testing.expectEqualStrings("(with: media)", pool.get(sel_id));
}

// -- mixin / function / include / at-rule tests (R.2c.7) ---------------------

test "parse: @mixin flex { display: flex; }" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@mixin flex { display: flex; }");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(AstTag.stmt_mixin_decl, n.tag);

    // extra: [name_id, params_extra_or_max, body_extra]
    const name_id: InternId = @enumFromInt(result.ast.getExtraU32(n.payload));
    const params_slot = result.ast.getExtraU32(n.payload + 1);
    const body_extra = result.ast.getExtraU32(n.payload + 2);

    try std.testing.expectEqualStrings("flex", pool.get(name_id));
    try std.testing.expectEqual(std.math.maxInt(u32), params_slot);

    const body = readBlockBody(&result.ast, body_extra);
    try std.testing.expectEqual(@as(u32, 1), body.len);
}

test "parse: @mixin with positional params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@mixin box($w, $h) { width: $w; height: $h; }");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    const params_slot = result.ast.getExtraU32(n.payload + 1);
    try std.testing.expect(params_slot != std.math.maxInt(u32));

    // Params layout: [count, has_splat, name_0, default_0, name_1, default_1]
    const count = result.ast.getExtraU32(params_slot);
    try std.testing.expectEqual(@as(u32, 2), count);
    const has_splat = result.ast.getExtraU32(params_slot + 1);
    try std.testing.expectEqual(@as(u32, 0), has_splat);

    const name_0: InternId = @enumFromInt(result.ast.getExtraU32(params_slot + 2));
    const default_0 = result.ast.getExtraU32(params_slot + 3);
    const name_1: InternId = @enumFromInt(result.ast.getExtraU32(params_slot + 4));
    try std.testing.expectEqualStrings("w", pool.get(name_0));
    try std.testing.expectEqual(std.math.maxInt(u32), default_0);
    try std.testing.expectEqualStrings("h", pool.get(name_1));
}

test "parse: @mixin with default + splat params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@mixin grid($cols: 3, $args...) { display: grid; }");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const params_slot = result.ast.getExtraU32(result.ast.getNode(stmt).payload + 1);
    const count = result.ast.getExtraU32(params_slot);
    const has_splat = result.ast.getExtraU32(params_slot + 1);
    try std.testing.expectEqual(@as(u32, 2), count);
    try std.testing.expectEqual(@as(u32, 1), has_splat);

    // Second param "args" with no default (splat doesn't use default slot).
    const name_1: InternId = @enumFromInt(result.ast.getExtraU32(params_slot + 4));
    try std.testing.expectEqualStrings("args", pool.get(name_1));

    // First param "cols" has a default expression.
    const default_0 = result.ast.getExtraU32(params_slot + 3);
    try std.testing.expect(default_0 != std.math.maxInt(u32));
    const def_node: NodeIndex = @enumFromInt(default_0);
    try expectNumberValue(&result.ast, def_node, 3.0);
}

test "parse: @mixin rejects rest param before final param" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    try std.testing.expectError(
        error.SyntaxError,
        parseFullSource(alloc, &pool, "@mixin a($args..., $tail) {}"),
    );
}

test "parse: @function rejects rest param before final param" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    try std.testing.expectError(
        error.SyntaxError,
        parseFullSource(alloc, &pool, "@function a($args..., $tail) { @return null; }"),
    );
}

test "parse: @function double($n) { @return $n * 2; }" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@function double($n) { @return $n * 2; }");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(AstTag.stmt_function_decl, n.tag);

    const name_id: InternId = @enumFromInt(result.ast.getExtraU32(n.payload));
    try std.testing.expectEqualStrings("double", pool.get(name_id));

    const body_extra = result.ast.getExtraU32(n.payload + 2);
    const body = readBlockBody(&result.ast, body_extra);
    try std.testing.expectEqual(@as(u32, 1), body.len);
    const ret_stmt: NodeIndex = @enumFromInt(result.ast.getExtraU32(body.first));
    try std.testing.expectEqual(AstTag.stmt_return, result.ast.getNode(ret_stmt).tag);
}

test "parse: @include flex;" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, ".a { @include flex; }");
    defer result.ast.deinit();

    const rule = rootChild(&result.ast, 0);
    const body = readBlockBody(&result.ast, readStyleRule(&result.ast, rule).body_extra);
    const inc_node: NodeIndex = @enumFromInt(result.ast.getExtraU32(body.first));
    const inc = result.ast.getNode(inc_node);
    try std.testing.expectEqual(AstTag.stmt_include_rule, inc.tag);

    // Layout: [name_id, namespace_id, args, using, body]
    const name_id: InternId = @enumFromInt(result.ast.getExtraU32(inc.payload));
    try std.testing.expectEqualStrings("flex", pool.get(name_id));
    try std.testing.expectEqual(InternId.none, @as(InternId, @enumFromInt(result.ast.getExtraU32(inc.payload + 1))));
    try std.testing.expectEqual(std.math.maxInt(u32), result.ast.getExtraU32(inc.payload + 2));
    try std.testing.expectEqual(std.math.maxInt(u32), result.ast.getExtraU32(inc.payload + 3));
    try std.testing.expectEqual(std.math.maxInt(u32), result.ast.getExtraU32(inc.payload + 4));
}

test "parse: @include box(10px, 20px);" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, ".a { @include box(10px, 20px); }");
    defer result.ast.deinit();

    const rule = rootChild(&result.ast, 0);
    const body = readBlockBody(&result.ast, readStyleRule(&result.ast, rule).body_extra);
    const inc_node: NodeIndex = @enumFromInt(result.ast.getExtraU32(body.first));
    const inc = result.ast.getNode(inc_node);
    // parser no longer parses include args structurally -- it skips the
    // balanced `(...)` run.  Later-stage include decoding recovers the
    // raw args span from source.
    const args_extra = result.ast.getExtraU32(inc.payload + 2);
    try std.testing.expect(args_extra != std.math.maxInt(u32));
}

test "parse: @include namespaced theme.button;" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, ".a { @include theme.button; }");
    defer result.ast.deinit();

    const rule = rootChild(&result.ast, 0);
    const body = readBlockBody(&result.ast, readStyleRule(&result.ast, rule).body_extra);
    const inc_node: NodeIndex = @enumFromInt(result.ast.getExtraU32(body.first));
    const inc = result.ast.getNode(inc_node);
    const name_id: InternId = @enumFromInt(result.ast.getExtraU32(inc.payload));
    const ns_id: InternId = @enumFromInt(result.ast.getExtraU32(inc.payload + 1));
    try std.testing.expectEqualStrings("button", pool.get(name_id));
    try std.testing.expectEqualStrings("theme", pool.get(ns_id));
}

test "parse: @include with content block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, ".a { @include hover { color: red; } }");
    defer result.ast.deinit();

    const rule = rootChild(&result.ast, 0);
    const body = readBlockBody(&result.ast, readStyleRule(&result.ast, rule).body_extra);
    const inc_node: NodeIndex = @enumFromInt(result.ast.getExtraU32(body.first));
    const inc = result.ast.getNode(inc_node);
    const body_extra = result.ast.getExtraU32(inc.payload + 4);
    try std.testing.expect(body_extra != std.math.maxInt(u32));
    const content = readBlockBody(&result.ast, body_extra);
    try std.testing.expectEqual(@as(u32, 1), content.len);
}

test "parse: @include with `using ($var)` clause" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, ".a { @include loop using ($color) { color: $color; } }");
    defer result.ast.deinit();

    const rule = rootChild(&result.ast, 0);
    const body = readBlockBody(&result.ast, readStyleRule(&result.ast, rule).body_extra);
    const inc_node: NodeIndex = @enumFromInt(result.ast.getExtraU32(body.first));
    const inc = result.ast.getNode(inc_node);
    const using_extra = result.ast.getExtraU32(inc.payload + 3);
    try std.testing.expect(using_extra != std.math.maxInt(u32));
    try std.testing.expectEqual(@as(u32, 1), result.ast.getExtraU32(using_extra));
}

test "parse: @media screen and (max-width: 768px) { body }" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@media screen and (max-width: 768px) { .box { color: red; } }");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(AstTag.stmt_at_rule, n.tag);

    const name_id: InternId = @enumFromInt(result.ast.getExtraU32(n.payload));
    try std.testing.expectEqualStrings("media", pool.get(name_id));

    const prelude_slot = result.ast.getExtraU32(n.payload + 1);
    try std.testing.expect(prelude_slot != std.math.maxInt(u32));
    const prelude_node: NodeIndex = @enumFromInt(prelude_slot);
    try std.testing.expectEqual(AstTag.expr_text_template, result.ast.getNode(prelude_node).tag);
    const prelude_id = textTemplateLiteralId(&result.ast, prelude_node);
    try std.testing.expectEqualStrings("screen and (max-width: 768px)", pool.get(prelude_id));

    const body_extra = result.ast.getExtraU32(n.payload + 2);
    try std.testing.expect(body_extra != std.math.maxInt(u32));
    const body = readBlockBody(&result.ast, body_extra);
    try std.testing.expectEqual(@as(u32, 1), body.len);
}

test "parse: @charset \"UTF-8\"; (statement form, no body)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@charset \"UTF-8\";");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(AstTag.stmt_at_rule, n.tag);
    const body_extra = result.ast.getExtraU32(n.payload + 2);
    try std.testing.expectEqual(std.math.maxInt(u32), body_extra);
}

test "parse: @keyframes slide { 0% {...} 100% {...} }" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@keyframes slide { 0% { left: 0; } 100% { left: 100%; } }");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(AstTag.stmt_at_rule, n.tag);
    const body_extra = result.ast.getExtraU32(n.payload + 2);
    try std.testing.expect(body_extra != std.math.maxInt(u32));
    const body = readBlockBody(&result.ast, body_extra);
    try std.testing.expectEqual(@as(u32, 2), body.len);
}

test "parse: @supports (display: flex) { body }" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@supports (display: flex) { .grid { display: flex; } }");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    try std.testing.expectEqual(AstTag.stmt_at_rule, result.ast.getNode(stmt).tag);
}

test "parse: @page :first { margin: 0; } (unknown at-rule via .at_keyword)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, "@page :first { margin: 0; }");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    const n = result.ast.getNode(stmt);
    try std.testing.expectEqual(AstTag.stmt_at_rule, n.tag);
    const name_id: InternId = @enumFromInt(result.ast.getExtraU32(n.payload));
    try std.testing.expectEqualStrings("page", pool.get(name_id));
}

test "parse: @at-root multiline query in SCSS (no SyntaxError)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const src =
        \\@at-root (without:
        \\  media) {}
    ;
    var result = try parseFullSource(alloc, &pool, src);
    defer result.ast.deinit();

    try std.testing.expectEqual(@as(u32, 1), rootChildCount(&result.ast));
    try std.testing.expectEqual(AstTag.stmt_at_root, result.ast.getNode(rootChild(&result.ast, 0)).tag);
}

test "parse: indented @return doesn't swallow following statements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const src =
        \\@function a($b, $c)
        \\  @return null
        \\$d: a(e,
        \\  f)
    ;
    var result = try parseFullSourceWithSyntax(alloc, &pool, src, true);
    defer result.ast.deinit();

    try std.testing.expectEqual(@as(u32, 2), rootChildCount(&result.ast));
    try std.testing.expectEqual(AstTag.stmt_function_decl, result.ast.getNode(rootChild(&result.ast, 0)).tag);
    try std.testing.expectEqual(AstTag.stmt_variable_decl, result.ast.getNode(rootChild(&result.ast, 1)).tag);
}

test "parse: indented include using() without body is accepted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const src =
        \\@mixin a
        \\  @content
        \\@include a() using
        \\  ()
    ;
    var result = try parseFullSourceWithSyntax(alloc, &pool, src, true);
    defer result.ast.deinit();

    try std.testing.expectEqual(@as(u32, 2), rootChildCount(&result.ast));
    try std.testing.expectEqual(AstTag.stmt_include_rule, result.ast.getNode(rootChild(&result.ast, 1)).tag);
}

test "parse: indented @use keyword on nested line is syntax error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const src =
        \\@use "other"
        \\  as a
    ;

    try std.testing.expectError(error.SyntaxError, parseFullSourceWithSyntax(alloc, &pool, src, true));
}

test "parse: indented @forward trailing nested member is syntax error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const src =
        \\@forward "other" show a
        \\  c
    ;

    try std.testing.expectError(error.SyntaxError, parseFullSourceWithSyntax(alloc, &pool, src, true));
}

test "parse: incomplete binary operator in declaration is syntax error (no raw fallback)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const src = ".x { color: 1px +; }";
    try std.testing.expectError(error.SyntaxError, parseFullSourceWithSyntax(alloc, &pool, src, false));
    const msg = error_format.currentContextMessage() orelse "";
    try std.testing.expect(std.mem.indexOf(u8, msg, "Expected expression") != null);
    error_format.clearContextMessage();
}

test "parse: trailing percent in declaration keeps raw fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSourceWithSyntax(alloc, &pool, ".x { color: c %; }", false);
    defer result.ast.deinit();

    const rule = rootChild(&result.ast, 0);
    const body = readBlockBody(&result.ast, readStyleRule(&result.ast, rule).body_extra);
    const decl: NodeIndex = @enumFromInt(result.ast.getExtraU32(body.first));
    const decl_node = result.ast.getNode(decl);
    const value_node: NodeIndex = @enumFromInt(result.ast.getExtraU32(decl_node.payload + 1));
    try std.testing.expectEqual(AstTag.expr_text_template, result.ast.getNode(value_node).tag);
    const lit_id = textTemplateLiteralId(&result.ast, value_node);
    try std.testing.expectEqualStrings("c %", pool.get(lit_id));
}

test "parse: indented `=` shorthand mixin with newline before name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const src =
        \\=
        \\  a
        \\d
        \\  @include a
    ;
    var result = try parseFullSourceWithSyntax(alloc, &pool, src, true);
    defer result.ast.deinit();

    try std.testing.expectEqual(@as(u32, 2), rootChildCount(&result.ast));
    try std.testing.expectEqual(AstTag.stmt_mixin_decl, result.ast.getNode(rootChild(&result.ast, 0)).tag);
}

test "parse: indented unquoted @import other.css" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSourceWithSyntax(alloc, &pool, "@import other.css", true);
    defer result.ast.deinit();

    try std.testing.expectEqual(@as(u32, 1), rootChildCount(&result.ast));
    try std.testing.expectEqual(AstTag.stmt_import, result.ast.getNode(rootChild(&result.ast, 0)).tag);
}

test "parse: indented unquoted tilde @import" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSourceWithSyntax(alloc, &pool, "@import ~pkg/app/styles/main", true);
    defer result.ast.deinit();

    try std.testing.expectEqual(@as(u32, 1), rootChildCount(&result.ast));
    try std.testing.expectEqual(AstTag.stmt_import, result.ast.getNode(rootChild(&result.ast, 0)).tag);
}

test "parse: indented custom property with multiline brace value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    const src =
        \\a
        \\  --b: {c
        \\    d}
    ;
    var result = try parseFullSourceWithSyntax(alloc, &pool, src, true);
    defer result.ast.deinit();

    try std.testing.expect(rootChildCount(&result.ast) >= 1);
}

// -- hash color literal tests (R.2c.8) --------------------------------------

test "parseHashAtom: #fff short form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "#fff");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_color_hex, n.tag);
    try std.testing.expectEqual(@as(u8, 0), n.flags); // short + lowercase
    const rgba = ctx.ast.getExtraU32(n.payload);
    try std.testing.expectEqual(@as(u32, 0xffffffff), rgba);
}

test "parseHashAtom: #ff0000 long form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "#ff0000");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_color_hex, n.tag);
    try std.testing.expectEqual(@as(u8, 0b01), n.flags); // long form bit set
    const rgba = ctx.ast.getExtraU32(n.payload);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), rgba);
}

test "parseHashAtom: #FF0000 uppercase flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "#FF0000");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_color_hex, n.tag);
    try std.testing.expectEqual(@as(u8, 0b11), n.flags); // long + upper
}

test "parseHashAtom: #abcd 4-digit short with alpha" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "#abcd");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_color_hex, n.tag);
    try std.testing.expectEqual(@as(u8, 0b100), n.flags); // short + alpha
    const rgba = ctx.ast.getExtraU32(n.payload);
    // 0xaa 0xbb 0xcc 0xdd packed
    try std.testing.expectEqual(@as(u32, 0xaabbccdd), rgba);
}

test "parseHashAtom: #12345678 8-digit long with alpha" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var ctx = try parseOneExpr(alloc, &pool, "#12345678");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_color_hex, n.tag);
    try std.testing.expectEqual(@as(u8, 0b101), n.flags); // long + alpha
    const rgba = ctx.ast.getExtraU32(n.payload);
    try std.testing.expectEqual(@as(u32, 0x12345678), rgba);
}

test "parseHashAtom: #foo falls back to expr_unquoted_ident" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    // `#foo` is 3 characters but `o` isn't a hex digit  ->  not a colour.
    // Parser falls back to unquoted_ident with the raw `#foo` text
    // (this is what an id selector reference looks like in an
    // expression context -- unusual but the old parser accepts it).
    var ctx = try parseOneExpr(alloc, &pool, "#foo");
    defer ctx.ast.deinit();

    const n = ctx.ast.getNode(ctx.node);
    try std.testing.expectEqual(AstTag.expr_unquoted_ident, n.tag);
    const id: InternId = @enumFromInt(n.payload);
    try std.testing.expectEqualStrings("#foo", pool.get(id));
}

test "parse: declaration value with hex colour `color: #abc;`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    var result = try parseFullSource(alloc, &pool, ".a { color: #abc; }");
    defer result.ast.deinit();

    const rule = rootChild(&result.ast, 0);
    const body = readBlockBody(&result.ast, readStyleRule(&result.ast, rule).body_extra);
    const decl: NodeIndex = @enumFromInt(result.ast.getExtraU32(body.first));
    const dn = result.ast.getNode(decl);
    const val: NodeIndex = @enumFromInt(result.ast.getExtraU32(dn.payload + 1));
    try std.testing.expectEqual(AstTag.expr_color_hex, result.ast.getNode(val).tag);
}

test "parse: id selector `#foo { ... }` still parses as a style rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pool = try InternPool.init(alloc);
    defer pool.deinit(alloc);

    // `#foo` at the top level hits parseRuleOrDeclaration, which
    // scans forward for `{` and dispatches to parseStyleRule.  The
    // colour-hex path is only reached inside expression context.
    var result = try parseFullSource(alloc, &pool, "#foo { color: red; }");
    defer result.ast.deinit();

    const stmt = rootChild(&result.ast, 0);
    try std.testing.expectEqual(AstTag.stmt_style_rule, result.ast.getNode(stmt).tag);
    const sr = readStyleRule(&result.ast, stmt);
    const sel_id: InternId = @enumFromInt(result.ast.getNode(sr.selector_node).payload);
    try std.testing.expectEqualStrings("#foo", pool.get(sel_id));
}
