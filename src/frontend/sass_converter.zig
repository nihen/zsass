const std = @import("std");

/// Conversion failures produced while normalizing indented `.sass` syntax into `.scss`.
pub const SassConvertError = error{SassSyntaxError};

/// Convert .sass (indented syntax) source to .scss source.
/// The returned slice is owned by the caller.
pub fn convert(allocator: std.mem.Allocator, source: []const u8) (SassConvertError || std.mem.Allocator.Error)![]const u8 {
    // All `LogicalLine.owned_content` strings -- and the `lines` ArrayList
    // itself -- are scoped to this function. Pin them to a per-call arena
    // so the per-line dupe-in-loop calls collapse into a single bulk free.
    var lines_arena = std.heap.ArenaAllocator.init(allocator);
    defer lines_arena.deinit();
    const lines_alloc = lines_arena.allocator();

    var lines: std.ArrayList(LogicalLine) = .empty;

    // Phase 1: Split into logical lines, joining multi-line continuations.
    try splitLogicalLines(lines_alloc, source, &lines);

    // Phase 1.5: Validate .sass-specific constraints on logical lines.
    try validateSassConstraints(lines.items);

    // Phase 2: Emit SCSS with {, }, ; based on indentation.
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var indent_stack: std.ArrayList(usize) = .empty;
    defer indent_stack.deinit(allocator);

    // Track whether each indent level was opened by a selector (true) or directive (false)
    var selector_stack: std.ArrayList(bool) = .empty;
    defer selector_stack.deinit(allocator);

    var function_stack: std.ArrayList(bool) = .empty;
    defer function_stack.deinit(allocator);

    try buf.ensureTotalCapacity(allocator, source.len);
    try indent_stack.ensureTotalCapacity(allocator, lines.items.len);
    try selector_stack.ensureTotalCapacity(allocator, lines.items.len);
    try function_stack.ensureTotalCapacity(allocator, lines.items.len);
    for (lines.items, 0..) |line, i| {
        if (line.is_blank or line.is_comment_only) {
            if (line.is_comment_only) {
                if (std.mem.startsWith(u8, line.content, "///")) {
                    try buf.appendSlice(allocator, "//");
                    try buf.appendSlice(allocator, line.content[3..]);
                } else {
                    try buf.appendSlice(allocator, line.content);
                }
                try buf.append(allocator, '\n');
            }
            continue;
        }

        const indent = line.indent;
        const trimmed = line.content;

        // Close blocks for decreased indentation
        while (indent_stack.items.len > 0 and indent_stack.items[indent_stack.items.len - 1] >= indent) {
            _ = indent_stack.pop();
            if (selector_stack.items.len > 0) _ = selector_stack.pop();
            if (function_stack.items.len > 0) _ = function_stack.pop();
            try buf.appendSlice(allocator, "}\n");
        }

        //Check if this line is @else / @else if -- merge with preceding }
        if (isElseLine(trimmed)) {
            if (buf.items.len >= 2 and buf.items[buf.items.len - 1] == '\n' and buf.items[buf.items.len - 2] == '}') {
                buf.items.len -= 1; // remove \n, keep }
                try buf.append(allocator, ' ');
            }
        }

        // Lines ending with comma are selector/list continuations.
        // Emit them as-is (no ; or {). SCSS parser handles multi-line selectors natively.
        //But @import lines with trailing comma are NOT continuations -- they are leaf statements.
        const stripped = stripAllTrailingComments(trimmed);
        if (stripped.len > 0 and stripped[stripped.len - 1] == ',' and
            !std.mem.startsWith(u8, trimmed, "@import "))
        {
            try buf.appendSlice(allocator, trimmed);
            try buf.append(allocator, '\n');
            continue;
        }

        // Determine if this line opens a block (next non-blank line has higher indent)
        //But certain bare directives should NOT open blocks -- they are leaf statements
        // that require their arguments on the same line.
        // Variable declarations ($var: value) never open blocks.
        const is_var_decl = trimmed.len > 0 and trimmed[0] == '$' and std.mem.findScalar(u8, trimmed, ':') != null;
        // Statement-only directives like @forward, @use, @import never open blocks.
        const opens_block = !is_var_decl and nextContentLineHasHigherIndent(lines.items, i, indent) and
            !isLeafDirective(trimmed) and !isStatementOnlyDirective(trimmed);

        // Check if this line is a selector (for {} vs ; decision and stack tracking)
        const is_selector = isSelectorLine(trimmed);

        // In @function context, "result:" with indented content is an error
        if (opens_block and isInsideFunction(function_stack.items) and isFunctionResultLine(trimmed)) {
            return error.SassSyntaxError;
        }

        // @forward and @use must not have indented children in .sass
        if (opens_block and isNoChildDirective(trimmed)) {
            return error.SassSyntaxError;
        }

        // `@at-root` queries/selectors must stay on the same logical line in
        // indented syntax. A nested line beginning with `(` after bare
        // `@at-root` is parsed as a child selector, not a query modifier.
        if (opens_block and std.mem.eql(u8, trimmed, "@at-root")) {
            var j = i + 1;
            while (j < lines.items.len) : (j += 1) {
                if (lines.items[j].is_blank or lines.items[j].is_comment_only) continue;
                const next_trimmed = std.mem.trimStart(u8, lines.items[j].content, " \t");
                if (next_trimmed.len > 0 and next_trimmed[0] == '(') {
                    return error.SassSyntaxError;
                }
                break;
            }
        }

        const is_function = isFunctionDirective(trimmed);
        const in_function = is_function or isInsideFunction(function_stack.items);

        if (opens_block) {
            // Strip inline // comments before emitting block opener
            // (in SCSS, // comments would hide the { })
            const block_content = stripInlineCommentForEmit(trimmed);
            try buf.appendSlice(allocator, block_content);
            try buf.appendSlice(allocator, " {\n");
            try indent_stack.append(allocator, indent);
            try selector_stack.append(allocator, is_selector);
            try function_stack.append(allocator, in_function);
        } else {
            // Check if previous line ends with comma BEFORE appending current line
            const prev_comma = prevLineEndsWithComma(buf.items);
            // Strip inline // comments before emitting terminators
            const emit_content = stripInlineCommentForEmit(trimmed);
            try buf.appendSlice(allocator, emit_content);
            if (!std.mem.startsWith(u8, trimmed, "//") and !std.mem.startsWith(u8, trimmed, "/*") and !std.mem.startsWith(u8, trimmed, "*/")) {
                // Determine if this standalone line needs {} (selector) or ; (declaration)
                // Only treat as selector in selector context (top-level or inside another selector)
                const in_selector_context = selector_stack.items.len == 0 or
                    (selector_stack.items.len > 0 and selector_stack.items[selector_stack.items.len - 1]);
                // Selector-like lines (e.g., "+ c", "> .foo") get {} only when they're
                //at a valid nesting level -- not orphaned under a non-block line.
                const is_orphaned_indent = indent > 0 and (indent_stack.items.len == 0 or indent > indent_stack.items[indent_stack.items.len - 1]);
                if (isBlockDirective(trimmed) or (is_selector and in_selector_context) or isSassSelector(trimmed) or (isSelectorLikeLine(trimmed) and !is_orphaned_indent)) {
                    try buf.appendSlice(allocator, " {}");
                } else if (looksLikeSelector(trimmed) and indent_stack.items.len > 0 and !prev_comma) {
                    // Inside a block context, a leaf line without : is a selector
                    // Needs {} to be valid SCSS. Skip if previous line ended with comma.
                    try buf.appendSlice(allocator, " {}");
                } else {
                    try buf.append(allocator, ';');
                }
            }
            try buf.append(allocator, '\n');
        }
    }

    // Close remaining blocks
    while (indent_stack.items.len > 0) {
        _ = indent_stack.pop();
        if (selector_stack.items.len > 0) _ = selector_stack.pop();
        if (function_stack.items.len > 0) _ = function_stack.pop();
        try buf.appendSlice(allocator, "}\n");
    }

    // Remove trailing whitespace/newlines
    while (buf.items.len > 0 and (buf.items[buf.items.len - 1] == '\n' or buf.items[buf.items.len - 1] == ' ')) {
        buf.items.len -= 1;
    }
    if (buf.items.len > 0) {
        try buf.append(allocator, '\n');
    }

    return buf.toOwnedSlice(allocator);
}

const LogicalLine = struct {
    content: []const u8,
    indent: usize,
    is_blank: bool,
    is_comment_only: bool,
    // `owned_content` is allocated from the `lines_arena` arena owned by
    // `convert`, so individual entries never need a per-line `free`; the
    // arena is released in bulk at the end of `convert`.
    owned_content: ?[]u8,
};

/// Copy current continuation bytes to an owned slice and clear the work buffer while
/// retaining capacity for the next continuation (avoids per-segment `toOwnedSlice` churn).
fn continuationBufferTakeOwned(allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) std.mem.Allocator.Error![]u8 {
    const owned = try allocator.dupe(u8, buf.items);
    buf.clearRetainingCapacity();
    return owned;
}

fn splitLogicalLines(
    allocator: std.mem.Allocator,
    source: []const u8,
    out: *std.ArrayList(LogicalLine),
) !void {
    var pos: usize = 0;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var interp_depth: i32 = 0;
    var brace_depth: i32 = 0; // Only tracked for custom property values
    var in_string_continuation: bool = false;
    var continuation_work: std.ArrayList(u8) = .empty;
    defer continuation_work.deinit(allocator);
    var in_continuation: bool = false;
    var continuation_indent: usize = 0;

    while (pos < source.len) {
        const line_start = pos;
        while (pos < source.len and source[pos] != '\n' and source[pos] != '\r' and source[pos] != '\x0c') {
            pos += 1;
        }
        const line_end = pos;
        if (pos < source.len) {
            if (source[pos] == '\r' and pos + 1 < source.len and source[pos + 1] == '\n') {
                pos += 2;
            } else {
                pos += 1;
            }
        }

        const raw_line = source[line_start..line_end];
        const indent = computeIndent(raw_line);
        const trimmed_r = std.mem.trimEnd(u8, std.mem.trimStart(u8, raw_line, " \t"), " \t\r");

        const depth_delta = countParenDepthDelta(trimmed_r);

        // Detect .sass-specific syntax errors (when NOT inside paren/bracket continuation)
        if (!in_continuation or (paren_depth <= 0 and bracket_depth <= 0 and interp_depth <= 0)) {
            // SCSS block syntax `{` in .sass (mixed syntax error)
            if (trimmed_r.len > 0 and hasBareOpenBrace(trimmed_r)) {
                return error.SassSyntaxError;
            }
            // Multiple statements on one line (`;` in the middle of a line)
            if (trimmed_r.len > 0 and hasMiddleSemicolon(trimmed_r)) {
                return error.SassSyntaxError;
            }
        }

        // Handle continuation (paren/bracket depth OR keyword/operator trigger)
        if (in_continuation) {
            const in_paren_cont = paren_depth > 0 or bracket_depth > 0 or interp_depth > 0 or brace_depth > 0 or in_string_continuation;

            // Blank line: skip in paren continuation, end keyword continuation
            if (trimmed_r.len == 0) {
                if (in_paren_cont) {
                    continue;
                }
                const owned = try continuationBufferTakeOwned(allocator, &continuation_work);
                try out.append(allocator, .{
                    .content = owned,
                    .indent = continuation_indent,
                    .is_blank = false,
                    .is_comment_only = false,
                    .owned_content = owned,
                });
                in_continuation = false;
                paren_depth = 0;
                bracket_depth = 0;
                interp_depth = 0;
                brace_depth = 0;
                in_string_continuation = false;
                try out.append(allocator, .{
                    .content = "",
                    .indent = 0,
                    .is_blank = true,
                    .is_comment_only = false,
                    .owned_content = null,
                });
                continue;
            }

            // Silent comment during keyword-only continuation: emit separately, keep continuation
            if (!in_paren_cont and std.mem.startsWith(u8, trimmed_r, "//")) {
                try out.append(allocator, .{
                    .content = trimmed_r,
                    .indent = indent,
                    .is_blank = false,
                    .is_comment_only = true,
                    .owned_content = null,
                });
                continue;
            }

            // For keyword-only continuation:
            // - Lower indent: always end
            // - Same indent with comma ending (not incomplete directive): end
            //(multi-line selectors: a,\nb at same indent  ->  lines separate)
            // - Same indent with non-comma: continue (operators/keywords join at same level)
            const end_keyword_cont = blk: {
                if (!in_paren_cont and indent < continuation_indent) break :blk true;
                if (!in_paren_cont and indent == continuation_indent) {
                    const cb_items = continuation_work.items;
                    const stripped_buf = stripTrailingComment(cb_items);
                    const trimmed_buf = std.mem.trimEnd(u8, stripped_buf, " \t");
                    if (trimmed_buf.len > 0 and trimmed_buf[trimmed_buf.len - 1] == ',' and !isIncompleteDirective(cb_items)) {
                        break :blk true;
                    }
                }
                break :blk false;
            };
            if (end_keyword_cont) {
                const owned = try continuationBufferTakeOwned(allocator, &continuation_work);
                try out.append(allocator, .{
                    .content = owned,
                    .indent = continuation_indent,
                    .is_blank = false,
                    .is_comment_only = false,
                    .owned_content = owned,
                });
                in_continuation = false;
                paren_depth = 0;
                bracket_depth = 0;
                interp_depth = 0;
                brace_depth = 0;
                in_string_continuation = false;
                // Fall through to process this line normally
            } else {
                // Join line to continuation buffer
                const cb = &continuation_work;
                if (in_paren_cont and !in_string_continuation) {
                    if (isInvalidImportSupportsFunctionSplit(cb.items, trimmed_r)) {
                        return error.SassSyntaxError;
                    }
                    const selector_paren_cont = isSelectorLine(cb.items);
                    const prev_non_ws = lastNonWhitespaceByte(cb.items);
                    // Paren continuation: preserve newlines and indentation.
                    // Special case 1: when the continuation line starts with ','
                    // normalize whitespace so "d\n      ,e" becomes "d, e" not "d ,e".
                    if (trimmed_r.len > 0 and trimmed_r[0] == ',') {
                        // Strip trailing whitespace from buffer before appending comma
                        while (cb.items.len > 0 and (cb.items[cb.items.len - 1] == ' ' or cb.items[cb.items.len - 1] == '\t' or cb.items[cb.items.len - 1] == '\n')) {
                            cb.items.len -= 1;
                        }
                        try cb.appendSlice(allocator, ", ");
                        // Append rest after comma (trimmed)
                        const after_comma = std.mem.trimStart(u8, trimmed_r[1..], " \t");
                        try cb.appendSlice(allocator, after_comma);
                    } else if (trimmed_r.len > 0 and trimmed_r[0] == ')') {
                        // For selector pseudos, surrounding newlines should not become
                        // literal whitespace inside the argument.
                        if (selector_paren_cont) {
                            while (cb.items.len > 0 and (cb.items[cb.items.len - 1] == ' ' or cb.items[cb.items.len - 1] == '\t' or cb.items[cb.items.len - 1] == '\n')) {
                                cb.items.len -= 1;
                            }
                            try cb.appendSlice(allocator, trimmed_r);
                        } else {
                            // Special case 2: closing paren right after opening paren
                            //"css(\n)"  ->  "css()" -- only when the last non-whitespace in buffer is '('
                            var buf_scan = cb.items.len;
                            while (buf_scan > 0 and (cb.items[buf_scan - 1] == ' ' or cb.items[buf_scan - 1] == '\t' or cb.items[buf_scan - 1] == '\n')) {
                                buf_scan -= 1;
                            }
                            if (buf_scan > 0 and cb.items[buf_scan - 1] == '(') {
                                if (isBareEmptyParenthesizedPropertyValue(cb.items[0..buf_scan])) {
                                    return error.SassSyntaxError;
                                }
                                // Empty paren: strip whitespace/newline between ( and )
                                cb.items.len = buf_scan;
                                try cb.appendSlice(allocator, trimmed_r);
                            } else {
                                // Non-empty paren: preserve newline + indent
                                try cb.append(allocator, '\n');
                                const ws_end = getLeadingWhitespaceEnd(raw_line);
                                try cb.appendSlice(allocator, raw_line[0..ws_end]);
                                try cb.appendSlice(allocator, trimmed_r);
                            }
                        }
                    } else if (selector_paren_cont and prev_non_ws != null and prev_non_ws.? == '(') {
                        try cb.appendSlice(allocator, trimmed_r);
                    } else {
                        // SCSS handles whitespace within parens correctly
                        try cb.append(allocator, '\n');
                        const ws_end = getLeadingWhitespaceEnd(raw_line);
                        try cb.appendSlice(allocator, raw_line[0..ws_end]);
                        try cb.appendSlice(allocator, trimmed_r);
                    }
                } else if (in_string_continuation) {
                    // String continuation: preserve newlines and indentation exactly
                    try cb.append(allocator, '\n');
                    const ws_end = getLeadingWhitespaceEnd(raw_line);
                    try cb.appendSlice(allocator, raw_line[0..ws_end]);
                    try cb.appendSlice(allocator, trimmed_r);
                } else {
                    // Keyword continuation: join with space, or \n for selector commas
                    const join_stripped = stripAllTrailingComments(trimmed_r);
                    const join_content = std.mem.trimEnd(u8, join_stripped, " \t");
                    // For selector comma continuation, join with \n to preserve SCSS multi-line selectors
                    const cb_trimmed = std.mem.trimEnd(u8, cb.items, " \t");
                    const is_selector_comma = cb_trimmed.len > 0 and cb_trimmed[cb_trimmed.len - 1] == ',' and isSelectorLine(cb.items);
                    if (is_selector_comma) {
                        try cb.append(allocator, '\n');
                    } else if (join_content.len > 0 and join_content[0] != ':') {
                        try cb.append(allocator, ' ');
                    }
                    try cb.appendSlice(allocator, join_content);
                }
                paren_depth += depth_delta.parens;
                bracket_depth += depth_delta.brackets;
                interp_depth += depth_delta.interps;
                if (brace_depth > 0) {
                    brace_depth += countBraceDepth(trimmed_r, false);
                }
                // Update string continuation: if previous line was in escaped string,
                // check if this line closes/continues it
                if (in_string_continuation) {
                    in_string_continuation = depth_delta.ends_in_escaped_string;
                } else {
                    in_string_continuation = depth_delta.ends_in_escaped_string;
                }

                if (paren_depth <= 0 and bracket_depth <= 0 and interp_depth <= 0 and brace_depth <= 0 and !in_string_continuation and !endsWithStatementContinuation(cb.items) and !isIncompleteDirective(cb.items)) {
                    //Strip trailing commas in function calls: "f(a, )"  ->  "f(a)"
                    stripTrailingCommaInBuffer(cb);

                    const owned = try continuationBufferTakeOwned(allocator, &continuation_work);
                    try out.append(allocator, .{
                        .content = owned,
                        .indent = continuation_indent,
                        .is_blank = false,
                        .is_comment_only = false,
                        .owned_content = owned,
                    });
                    in_continuation = false;
                    paren_depth = 0;
                    bracket_depth = 0;
                    interp_depth = 0;
                    brace_depth = 0;
                    in_string_continuation = false;
                }
                continue;
            }
        }

        if (trimmed_r.len == 0) {
            try out.append(allocator, .{
                .content = "",
                .indent = 0,
                .is_blank = true,
                .is_comment_only = false,
                .owned_content = null,
            });
            continue;
        }

        // Handle loud comments: /* ... spanning multiple lines
        if (std.mem.startsWith(u8, trimmed_r, "/*")) {
            if (std.mem.find(u8, trimmed_r[2..], "*/") != null) {
                // Self-closing comment on one line.
                const close_offset = std.mem.find(u8, trimmed_r[2..], "*/").?;
                const comment_end = 2 + close_offset + 2; // past */
                const after_close = std.mem.trimStart(u8, trimmed_r[comment_end..], " \t");
                if (after_close.len == 0 or std.mem.startsWith(u8, after_close, "/*") or std.mem.startsWith(u8, after_close, "//")) {
                    //Only whitespace or comments after close -- strip and emit just the comment
                    const comment_text = std.mem.trimEnd(u8, trimmed_r[0..comment_end], " \t");
                    const owned_comment = try allocator.dupe(u8, comment_text);
                    try out.append(allocator, .{
                        .content = owned_comment,
                        .indent = indent,
                        .is_blank = false,
                        .is_comment_only = true,
                        .owned_content = owned_comment,
                    });
                    continue;
                }
                //Non-comment text after close -- pass through as-is for compiler to handle
            } else {
                const after_open = std.mem.trimStart(u8, trimmed_r[2..], " \t");
                const has_initial_content = after_open.len > 0;
                const interp_mode = has_initial_content and hasUnclosedInterpolation(trimmed_r);

                // Check if next non-blank line has higher indent (multi-line comment with first-line content)
                const next_has_higher = blk: {
                    var peek_pos = pos;
                    while (peek_pos < source.len) {
                        const pk_start = peek_pos;
                        while (peek_pos < source.len and source[peek_pos] != '\n' and source[peek_pos] != '\r' and source[peek_pos] != '\x0c') {
                            peek_pos += 1;
                        }
                        const pk_line_end = peek_pos;
                        if (peek_pos < source.len) {
                            if (source[peek_pos] == '\r' and peek_pos + 1 < source.len and source[peek_pos + 1] == '\n') {
                                peek_pos += 2;
                            } else {
                                peek_pos += 1;
                            }
                        }
                        const pk_raw = source[pk_start..pk_line_end];
                        const pk_trimmed = std.mem.trimEnd(u8, std.mem.trimStart(u8, pk_raw, " \t"), " \t\r");
                        if (pk_trimmed.len == 0) continue; // skip blank lines
                        break :blk computeIndent(pk_raw) > indent;
                    }
                    break :blk false;
                };

                if (has_initial_content and !interp_mode and !next_has_higher) {
                    //Content after /* with no unclosed interpolation and no indented continuation -- auto-close on same line
                    var auto_buf: std.ArrayList(u8) = .empty;
                    errdefer auto_buf.deinit(allocator);
                    try auto_buf.appendSlice(allocator, trimmed_r);
                    try auto_buf.appendSlice(allocator, " */");
                    const owned = try auto_buf.toOwnedSlice(allocator);
                    try out.append(allocator, .{
                        .content = owned,
                        .indent = indent,
                        .is_blank = false,
                        .is_comment_only = true,
                        .owned_content = owned,
                    });
                    continue;
                }

                // Multi-line: /* alone, /* with unclosed interpolation, or /* with content and indented continuation
                const ContentLine = struct { raw: []const u8, indent_val: usize, is_blank: bool };
                var content_lines: std.ArrayList(ContentLine) = .empty;
                defer content_lines.deinit(allocator);
                var found_close = false;
                var min_content_indent: usize = std.math.maxInt(usize);

                while (pos < source.len) {
                    const cl_start = pos;
                    while (pos < source.len and source[pos] != '\n' and source[pos] != '\r' and source[pos] != '\x0c') {
                        pos += 1;
                    }
                    const cl_end = pos;
                    if (pos < source.len) {
                        if (source[pos] == '\r' and pos + 1 < source.len and source[pos + 1] == '\n') {
                            pos += 2;
                        } else {
                            pos += 1;
                        }
                    }
                    const cl_raw = source[cl_start..cl_end];
                    const cl_indent = computeIndent(cl_raw);
                    const cl_left_trimmed = std.mem.trimStart(u8, cl_raw, " \t");
                    const cl_trimmed = std.mem.trimEnd(u8, cl_left_trimmed, "\r");

                    if (std.mem.trimEnd(u8, cl_trimmed, " \t").len == 0) {
                        if (interp_mode) continue;
                        // Blank line: peek ahead to see if there are more indented lines
                        const has_more_indented = peekHasMoreIndentedContent(source, pos, indent);
                        if (has_more_indented) {
                            // Preserve blank line
                            try content_lines.append(allocator, .{ .raw = "", .indent_val = 0, .is_blank = true });
                            continue;
                        }
                        break; // blank line ends regular comment
                    }

                    if (cl_indent <= indent) {
                        pos = cl_start; // push back
                        break;
                    }

                    if (cl_indent < min_content_indent) {
                        min_content_indent = cl_indent;
                    }

                    const cl_stripped = std.mem.trimEnd(u8, cl_trimmed, " \t");
                    if (std.mem.find(u8, cl_stripped, "*/") != null) {
                        try content_lines.append(allocator, .{ .raw = cl_raw, .indent_val = cl_indent, .is_blank = false });
                        found_close = true;
                        break;
                    }

                    try content_lines.append(allocator, .{ .raw = cl_raw, .indent_val = cl_indent, .is_blank = false });
                }

                // Build formatted comment
                var comment_buf: std.ArrayList(u8) = .empty;
                errdefer comment_buf.deinit(allocator);

                if (interp_mode) {
                    // Interpolation: join with spaces
                    try comment_buf.appendSlice(allocator, trimmed_r);
                    try comment_buf.ensureUnusedCapacity(allocator, content_lines.items.len * 8);
                    for (content_lines.items) |cl| {
                        if (cl.is_blank) continue;
                        const cl_trimmed_r = std.mem.trimEnd(u8, std.mem.trimStart(u8, cl.raw, " \t"), " \t\r");
                        try comment_buf.append(allocator, ' ');
                        try comment_buf.appendSlice(allocator, cl_trimmed_r);
                    }
                } else if (has_initial_content) {
                    // Content on the /* line with indented continuation lines.
                    // Preserve original column positions: " *" (2 chars) replaces the
                    // indent prefix, and (raw_indent - comment_indent - 2) extra spaces
                    // maintain the original visual alignment.
                    try comment_buf.appendSlice(allocator, trimmed_r);
                    for (content_lines.items) |cl| {
                        if (cl.is_blank) {
                            try comment_buf.appendSlice(allocator, "\n *");
                        } else {
                            try comment_buf.appendSlice(allocator, "\n *");
                            const extra = if (cl.indent_val > indent + 2) cl.indent_val - indent - 2 else 0;
                            const num_spaces = @max(1, extra);
                            try comment_buf.appendNTimes(allocator, ' ', num_spaces);
                            const cl_trimmed_content = std.mem.trimStart(u8, cl.raw, " \t");
                            try comment_buf.appendSlice(allocator, std.mem.trimEnd(u8, cl_trimmed_content, "\r"));
                        }
                    }
                } else {
                    // Regular: /* alone, content on subsequent lines.
                    // Same column-preserving logic as has_initial_content.
                    try comment_buf.appendSlice(allocator, "/*");
                    if (content_lines.items.len > 0) {
                        var first = true;
                        for (content_lines.items) |cl| {
                            if (cl.is_blank) {
                                // Preserved blank line
                                try comment_buf.appendSlice(allocator, "\n *");
                                continue;
                            }
                            const cl_trimmed_content = std.mem.trimStart(u8, cl.raw, " \t");
                            const cl_content = std.mem.trimEnd(u8, cl_trimmed_content, "\r");
                            if (first) {
                                try comment_buf.appendSlice(allocator, " ");
                                try comment_buf.appendSlice(allocator, cl_content);
                                first = false;
                            } else {
                                try comment_buf.appendSlice(allocator, "\n *");
                                const extra = if (cl.indent_val > indent + 2) cl.indent_val - indent - 2 else 0;
                                const num_spaces = @max(1, extra);
                                try comment_buf.appendNTimes(allocator, ' ', num_spaces);
                                try comment_buf.appendSlice(allocator, cl_content);
                            }
                        }
                    }
                }

                // Auto-close if needed
                if (!found_close and !std.mem.endsWith(u8, comment_buf.items, "*/")) {
                    try comment_buf.appendSlice(allocator, " */");
                }

                const owned = try comment_buf.toOwnedSlice(allocator);
                try out.append(allocator, .{
                    .content = owned,
                    .indent = indent,
                    .is_blank = false,
                    .is_comment_only = true,
                    .owned_content = owned,
                });
                continue;
            }
        }

        if (std.mem.startsWith(u8, trimmed_r, "//")) {
            try out.append(allocator, .{
                .content = trimmed_r,
                .indent = indent,
                .is_blank = false,
                .is_comment_only = true,
                .owned_content = null,
            });
            // Skip indented continuation lines (they're part of the silent comment in .sass)
            while (pos < source.len) {
                const peek_start = pos;
                while (pos < source.len and source[pos] != '\n' and source[pos] != '\r' and source[pos] != '\x0c') {
                    pos += 1;
                }
                if (pos < source.len) {
                    if (source[pos] == '\r' and pos + 1 < source.len and source[pos + 1] == '\n') {
                        pos += 2;
                    } else {
                        pos += 1;
                    }
                }
                const peek_raw = source[peek_start..pos];
                const peek_trimmed = std.mem.trimEnd(u8, std.mem.trimStart(u8, peek_raw, " \t"), " \t\r");
                if (peek_trimmed.len == 0) continue; // blank lines are skipped
                const peek_indent = computeIndent(peek_raw);
                if (peek_indent > indent) {
                    continue; // indented line -- part of the comment, skip
                } else {
                    pos = peek_start; // not part of comment, push back
                    break;
                }
            }
            continue;
        }

        // Handle inline multi-line /* ... */ comments within expressions.
        // When /* appears mid-line (not at start) and has no matching */ on the same line,
        // read continuation lines until */ is found, strip the comment, and join the parts.
        // If */ is never found, leave the line as-is so the compiler can report unterminated comment.
        var inline_comment_owned: ?[]u8 = null;
        var effective_trimmed: []const u8 = trimmed_r;
        if (!std.mem.startsWith(u8, trimmed_r, "/*")) {
            if (findInlineUnclosedComment(trimmed_r)) |comment_start| {
                // Found unclosed /* in the middle of the line
                const before_comment = std.mem.trimEnd(u8, trimmed_r[0..comment_start], " \t");
                var after_close: []const u8 = "";
                var inline_found_close = false;
                const saved_pos = pos;
                // Read continuation lines to find */
                while (pos < source.len) {
                    const cl_start = pos;
                    while (pos < source.len and source[pos] != '\n' and source[pos] != '\r' and source[pos] != '\x0c') {
                        pos += 1;
                    }
                    const cl_end = pos;
                    if (pos < source.len) {
                        if (source[pos] == '\r' and pos + 1 < source.len and source[pos + 1] == '\n') {
                            pos += 2;
                        } else {
                            pos += 1;
                        }
                    }
                    const cl_raw = source[cl_start..cl_end];
                    const cl_trimmed = std.mem.trimEnd(u8, std.mem.trimStart(u8, cl_raw, " \t"), " \t\r");
                    if (std.mem.find(u8, cl_trimmed, "*/")) |close_idx| {
                        //Found the close -- get content after */
                        const rest = cl_trimmed[close_idx + 2 ..];
                        after_close = std.mem.trimStart(u8, rest, " \t");
                        inline_found_close = true;
                        break;
                    }
                    // No */ on this line, continue reading
                }
                if (inline_found_close) {
                    // Build the line with comment stripped: before_comment + after_close
                    var join_buf: std.ArrayList(u8) = .empty;
                    errdefer join_buf.deinit(allocator);
                    try join_buf.appendSlice(allocator, before_comment);
                    if (after_close.len > 0) {
                        if (before_comment.len > 0) {
                            try join_buf.append(allocator, ' ');
                        }
                        try join_buf.appendSlice(allocator, after_close);
                    }
                    inline_comment_owned = try join_buf.toOwnedSlice(allocator);
                    effective_trimmed = inline_comment_owned.?;
                } else {
                    //No close found -- leave line as-is for unterminated comment error
                    pos = saved_pos;
                }
            }
        }

        //Apply mixin shorthands: =name  ->  @mixin name, +name  ->  @include name
        var effective_content: []const u8 = effective_trimmed;
        var shorthand_owned: ?[]u8 = null;

        if (std.mem.eql(u8, trimmed_r, "=")) {
            //Bare = is @mixin shorthand without name -- name on next line
            shorthand_owned = try allocator.dupe(u8, "@mixin");
            effective_content = shorthand_owned.?;
        } else if (trimmed_r.len > 1 and trimmed_r[0] == '=' and isIdentStart(trimmed_r[1])) {
            shorthand_owned = try std.mem.concat(allocator, u8, &.{ "@mixin ", trimmed_r[1..] });
            effective_content = shorthand_owned.?;
        } else if (trimmed_r.len > 2 and trimmed_r[0] == '=' and trimmed_r[1] == ' ') {
            //"= name" with space -- @mixin shorthand with space after =
            shorthand_owned = try std.mem.concat(allocator, u8, &.{ "@mixin ", std.mem.trimStart(u8, trimmed_r[1..], " \t") });
            effective_content = shorthand_owned.?;
        } else if (trimmed_r.len > 1 and trimmed_r[0] == '+' and isIdentStart(trimmed_r[1])) {
            shorthand_owned = try std.mem.concat(allocator, u8, &.{ "@include ", trimmed_r[1..] });
            effective_content = shorthand_owned.?;
        }

        // Strip leading \: escape in .sass (used to prevent : from being interpreted as property separator)
        //e.g., \:hover  ->  :hover, \:-webkit-selection  ->  :-webkit-selection
        if (shorthand_owned == null and effective_content.len >= 2 and effective_content[0] == '\\' and effective_content[1] == ':') {
            effective_content = effective_content[1..];
        }

        // In .sass, @import can use unquoted filenames: @import foo, bar/baz
        // SCSS requires quoted strings for Sass imports: @import "foo", "bar/baz"
        // Skip quoting for CSS imports (url(...), already-quoted, etc.)
        if (shorthand_owned == null and std.mem.startsWith(u8, effective_content, "@import ")) {
            const import_args = std.mem.trimStart(u8, effective_content["@import ".len..], " \t");
            if (import_args.len > 0 and import_args[0] != '"' and import_args[0] != '\'' and
                !std.mem.startsWith(u8, import_args, "url(") and
                !std.mem.startsWith(u8, import_args, "http://") and
                !std.mem.startsWith(u8, import_args, "https://"))
            {
                var import_buf: std.ArrayList(u8) = .empty;
                errdefer import_buf.deinit(allocator);
                try import_buf.appendSlice(allocator, "@import ");
                var first = true;
                var it = std.mem.splitScalar(u8, import_args, ',');
                while (it.next()) |part| {
                    const trimmed_part = std.mem.trim(u8, part, " \t");
                    if (trimmed_part.len == 0) continue;
                    if (!first) try import_buf.appendSlice(allocator, ", ");
                    first = false;
                    if ((trimmed_part.len >= 2 and (trimmed_part[0] == '"' or trimmed_part[0] == '\'')) or
                        std.mem.startsWith(u8, trimmed_part, "url("))
                    {
                        try import_buf.appendSlice(allocator, trimmed_part);
                    } else {
                        try import_buf.append(allocator, '"');
                        try import_buf.appendSlice(allocator, trimmed_part);
                        try import_buf.append(allocator, '"');
                    }
                }
                shorthand_owned = try import_buf.toOwnedSlice(allocator);
                effective_content = shorthand_owned.?;
            }
        }

        // Strip optional trailing ; in .sass (it's an optional terminator, converter adds ; itself)
        // Must strip trailing comments first so we can see the ; (e.g. "b: c; /* f */")
        {
            const sans_comments = stripAllTrailingComments(effective_content);
            const sans_semi = stripTrailingSemicolon(sans_comments);
            if (sans_semi.len != sans_comments.len) {
                //Semicolon was stripped -- use the shorter content (sans comments AND semicolon)
                effective_content = sans_semi;
            }
        }

        // Strip trailing comma from property value lines in .sass
        //In .sass, trailing commas in value lists are stripped (e.g., "b: c, d,"  ->  "b: c, d")
        // Only strip for property values (contains :, doesn't start with @)
        // Don't strip if inside unclosed parens (function argument comma)
        // Must be done BEFORE continuation check since , triggers continuation
        {
            const check = std.mem.trimEnd(u8, effective_content, " \t");
            if (check.len > 0 and check[check.len - 1] == ',' and check[0] != '@') {
                const dd = countParenDepthDelta(check);
                if (dd.parens <= 0 and dd.brackets <= 0) {
                    var has_colon = false;
                    var in_str: u8 = 0;
                    for (check) |ch| {
                        if (in_str != 0) {
                            if (ch == in_str) in_str = 0;
                            continue;
                        }
                        if (ch == '\'' or ch == '"') {
                            in_str = ch;
                            continue;
                        }
                        if (ch == ':') {
                            has_colon = true;
                            break;
                        }
                    }
                    if (has_colon and !isSelectorLine(check)) {
                        effective_content = std.mem.trimEnd(u8, check[0 .. check.len - 1], " \t");
                    }
                }
            }
        }

        // For @each with complete 'in' clause, strip trailing comma
        // (it's a trailing comma in the value list, not a continuation marker)
        if (std.mem.startsWith(u8, effective_content, "@each ") and std.mem.find(u8, effective_content, " in ") != null) {
            const ec_trimmed = std.mem.trimEnd(u8, effective_content, " \t");
            if (ec_trimmed.len > 0 and ec_trimmed[ec_trimmed.len - 1] == ',') {
                effective_content = std.mem.trimEnd(u8, ec_trimmed[0 .. ec_trimmed.len - 1], " \t");
            }
        }

        //For @extend with trailing comma, strip it -- @extend takes a single selector,
        // and trailing comma should not trigger continuation to the next line
        if (std.mem.startsWith(u8, effective_content, "@extend ")) {
            const ext_trimmed = std.mem.trimEnd(u8, effective_content, " \t");
            if (ext_trimmed.len > 0 and ext_trimmed[ext_trimmed.len - 1] == ',') {
                effective_content = std.mem.trimEnd(u8, ext_trimmed[0 .. ext_trimmed.len - 1], " \t");
            }
        }

        paren_depth += depth_delta.parens;
        bracket_depth += depth_delta.brackets;
        interp_depth += depth_delta.interps;
        in_string_continuation = depth_delta.ends_in_escaped_string;
        // Track { } depth for custom property values (only start tracking for -- properties)
        if (isCustomPropLine(effective_content)) {
            brace_depth += countBraceDepth(effective_content, true);
        }

        // Check for keyword continuation, but suppress for certain directives
        const keyword_cont = if (paren_depth <= 0 and bracket_depth <= 0 and interp_depth <= 0 and brace_depth <= 0 and !in_string_continuation)
            ((endsWithStatementContinuation(effective_content) and
                !isSuppressedContinuation(effective_content) and
                !shouldSuppressSelectorKeywordContinuation(effective_content) and
                !isSelectorLineEndingWithCombinator(effective_content)) or
                isIncompleteDirective(effective_content) or
                isBareDollarVariable(effective_content))
        else
            false;

        if (paren_depth > 0 or bracket_depth > 0 or interp_depth > 0 or brace_depth > 0 or in_string_continuation or keyword_cont) {
            continuation_work.clearRetainingCapacity();
            in_continuation = true;
            continuation_indent = indent;
            if (paren_depth <= 0 and bracket_depth <= 0 and interp_depth <= 0 and brace_depth <= 0 and !in_string_continuation) {
                // Keyword continuation: strip trailing comments to prevent pollution of joined content
                const stripped_eff = stripAllTrailingComments(effective_content);
                try continuation_work.appendSlice(allocator, std.mem.trimEnd(u8, stripped_eff, " \t"));
            } else {
                try continuation_work.appendSlice(allocator, effective_content);
            }
            // `shorthand_owned` / `inline_comment_owned` come from the
            // caller-supplied arena, so dropping them here is a no-op.
            continue;
        }

        paren_depth = 0;
        bracket_depth = 0;
        interp_depth = 0;
        brace_depth = 0;

        try out.append(allocator, .{
            .content = effective_content,
            .indent = indent,
            .is_blank = false,
            .is_comment_only = false,
            .owned_content = shorthand_owned orelse inline_comment_owned,
        });
        // The caller-supplied allocator is an arena, so the rare double-set
        // case (shorthand + inline comment both populated) does not need an
        // explicit free; the unused buffer is reclaimed by `arena.deinit`.
    }

    if (in_continuation) {
        const owned = try continuationBufferTakeOwned(allocator, &continuation_work);
        try out.append(allocator, .{
            .content = owned,
            .indent = continuation_indent,
            .is_blank = false,
            .is_comment_only = false,
            .owned_content = owned,
        });
        in_continuation = false;
    }
}

/// Validate .sass-specific constraints on logical lines.
/// Detects patterns that should produce errors in the indented syntax.
fn validateSassConstraints(lines: []const LogicalLine) SassConvertError!void {
    var prev_was_leaf: bool = false;
    var prev_leaf_indent: usize = 0;
    var prev_was_comment_close: bool = false;
    var prev_comment_indent: usize = 0;

    // Track indent stack for inconsistency detection
    var indent_levels: [64]usize = undefined;
    var indent_level_count: usize = 0;
    indent_levels[0] = 0;
    indent_level_count = 1;

    for (lines, 0..) |line, i| {
        if (line.is_blank) continue;
        if (line.is_comment_only) {
            // Track if this comment is a closing */ (for multi-line comment error detection)
            prev_was_comment_close = std.mem.endsWith(u8, std.mem.trimEnd(u8, line.content, " \t"), "*/");
            prev_comment_indent = line.indent;
            prev_was_leaf = false;
            continue;
        }

        const trimmed = line.content;

        // Check for content after closed comment at same indent level.
        // In .sass, after a multi-line /* ... */ block that closes with */,
        // content at the same indent level is not allowed if the comment
        // started at that indent (it looks like it's "inside" the comment).
        if (prev_was_comment_close and line.indent > prev_comment_indent) {
            //Content indented deeper than the closed comment -- error
            return error.SassSyntaxError;
        }
        prev_was_comment_close = false;

        // Inconsistent indentation detection:
        // When indent increases, push onto the indent stack.
        // When indent decreases, it must match a previously seen indent level.
        // An indent that falls between two known levels is inconsistent.
        if (indent_level_count > 0) {
            const cur_top = indent_levels[indent_level_count - 1];
            if (line.indent > cur_top) {
                //Indent increased -- push new level
                if (indent_level_count < indent_levels.len) {
                    indent_levels[indent_level_count] = line.indent;
                    indent_level_count += 1;
                }
            } else if (line.indent < cur_top) {
                //Indent decreased -- must match a known indent level
                var found = false;
                while (indent_level_count > 0) {
                    indent_level_count -= 1;
                    if (indent_levels[indent_level_count] == line.indent) {
                        found = true;
                        indent_level_count += 1; // keep this level
                        break;
                    }
                    if (indent_levels[indent_level_count] < line.indent) {
                        //We've gone past -- this indent doesn't match any known level
                        break;
                    }
                }
                if (!found and line.indent > 0) {
                    // Non-zero indent that doesn't match any known level
                    return error.SassSyntaxError;
                }
                if (!found and line.indent == 0) {
                    // Back to root
                    indent_level_count = 1;
                    indent_levels[0] = 0;
                }
            }
        }

        // Check for content indented under leaf statements.
        // Leaf statements include: variable declarations, @charset, @import (with trailing comma),
        // custom properties, bare @media.
        if (prev_was_leaf and line.indent > prev_leaf_indent) {
            return error.SassSyntaxError;
        }
        prev_was_leaf = false;

        // Determine if this line is a leaf statement (nothing may be indented beneath it)
        const is_var_decl = trimmed.len > 0 and trimmed[0] == '$' and std.mem.findScalar(u8, trimmed, ':') != null;
        const is_charset = std.mem.startsWith(u8, trimmed, "@charset");
        const is_import_with_comma = std.mem.startsWith(u8, trimmed, "@import ") and blk: {
            const imp_trimmed = std.mem.trimEnd(u8, trimmed, " \t");
            break :blk imp_trimmed.len > 0 and imp_trimmed[imp_trimmed.len - 1] == ',';
        };
        const is_custom_prop = std.mem.startsWith(u8, trimmed, "--") and std.mem.find(u8, trimmed, ":") != null;
        // Bare @media without args (e.g., "@media" with nothing after)
        const is_bare_media = std.mem.eql(u8, trimmed, "@media");

        if (is_var_decl or is_charset or is_import_with_comma or is_custom_prop or is_bare_media) {
            prev_was_leaf = true;
            prev_leaf_indent = line.indent;
        }

        // Indented syntax: `@-moz-document` must not end the logical line without
        //its prelude -- an indented continuation line is invalid (see sass-spec
        // `css/moz_document/whitespace/error/before_arg/sass`).
        if (isBareMozDocumentLine(trimmed)) {
            if (findNextContentLine(lines, i)) |nl| {
                if (nl.indent > line.indent) return error.SassSyntaxError;
            }
        }

        // `@include foo()` with a *closed* argument list cannot be followed by an
        //indented `using (...)` line -- `using` must continue the same logical
        // line as `@include` before the closing `)` (sass-spec
        // `directives/mixin/whitespace/error/include/before_using/sass`).
        if (isCompleteClosedIncludeLine(trimmed)) {
            if (findNextContentLine(lines, i)) |nl| {
                if (nl.indent > line.indent and isUsingClauseLineWithParen(nl.content)) {
                    return error.SassSyntaxError;
                }
            }
        }

        // Selector followed by comma-prefixed line at lower or same indent
        // In .sass, a line starting with "," at indent 0 after "a" at indent 0 is a syntax error
        if (i + 1 < lines.len) {
            const next = findNextContentLine(lines, i);
            if (next) |next_line| {
                if (next_line.content.len > 0 and next_line.content[0] == ',' and
                    next_line.indent <= line.indent and
                    !std.mem.startsWith(u8, trimmed, "@") and
                    trimmed[0] != '$' and
                    !std.mem.startsWith(u8, trimmed, "//") and
                    !std.mem.startsWith(u8, trimmed, "/*") and
                    std.mem.findScalar(u8, trimmed, ':') == null)
                {
                    //Selector "a" followed by ",b" at same or lower indent  ->  error
                    return error.SassSyntaxError;
                }
            }
        }
    }
}

/// Find the next non-blank, non-comment line.
fn findNextContentLine(lines: []const LogicalLine, current: usize) ?LogicalLine {
    var j = current + 1;
    while (j < lines.len) : (j += 1) {
        if (!lines[j].is_blank and !lines[j].is_comment_only) return lines[j];
    }
    return null;
}

fn stripForSassDirectiveCheck(content: []const u8) []const u8 {
    const t = std.mem.trimStart(u8, content, " \t");
    return std.mem.trimEnd(u8, stripAllTrailingComments(t), " \t");
}

fn isBareMozDocumentLine(content: []const u8) bool {
    return std.mem.eql(u8, stripForSassDirectiveCheck(content), "@-moz-document");
}

/// `@include ...)` with balanced parens and a closing `)` at end of line.
fn isCompleteClosedIncludeLine(content: []const u8) bool {
    const t = stripForSassDirectiveCheck(content);
    if (!std.mem.startsWith(u8, t, "@include ")) return false;
    const delta = countParenDepthDelta(t);
    if (delta.parens != 0) return false;
    return t.len > 0 and t[t.len - 1] == ')';
}

/// True when `content` begins with the `using` keyword and contains `(` on
/// that same line after the keyword (e.g. `using ()`, `using ($x)`).
/// A lone `using` line (continuation before `($x)` on the next line) returns false.
fn isUsingClauseLineWithParen(content: []const u8) bool {
    const t = std.mem.trimStart(u8, content, " \t");
    if (!std.mem.startsWith(u8, t, "using")) return false;
    if (t.len > 5) {
        const ch = t[5];
        if (ch != ' ' and ch != '\t' and ch != '(') return false;
    }
    const after_kw = std.mem.trimStart(u8, t[5..], " \t");
    return std.mem.findScalar(u8, after_kw, '(') != null;
}

/// Peek ahead in source from `start_pos` to see if there are more indented content lines
/// (used to determine if blank lines within comments should be preserved).
fn peekHasMoreIndentedContent(source: []const u8, start_pos: usize, base_indent: usize) bool {
    var peek_pos = start_pos;
    while (peek_pos < source.len) {
        const pk_start = peek_pos;
        while (peek_pos < source.len and source[peek_pos] != '\n' and source[peek_pos] != '\r' and source[peek_pos] != '\x0c') {
            peek_pos += 1;
        }
        const pk_line_end = peek_pos;
        if (peek_pos < source.len) {
            if (source[peek_pos] == '\r' and peek_pos + 1 < source.len and source[peek_pos + 1] == '\n') {
                peek_pos += 2;
            } else {
                peek_pos += 1;
            }
        }
        const pk_raw = source[pk_start..pk_line_end];
        const pk_trimmed = std.mem.trimEnd(u8, std.mem.trimStart(u8, pk_raw, " \t"), " \t\r");
        if (pk_trimmed.len == 0) continue; // skip blank lines
        return computeIndent(pk_raw) > base_indent;
    }
    return false;
}

fn computeIndent(line: []const u8) usize {
    var cols: usize = 0;
    for (line) |ch| {
        switch (ch) {
            ' ' => cols += 1,
            '\t' => cols += 2,
            else => break,
        }
    }
    return cols;
}

/// Get the index of the first non-whitespace character in a line.
fn getLeadingWhitespaceEnd(line: []const u8) usize {
    for (line, 0..) |ch, i| {
        if (ch != ' ' and ch != '\t') return i;
    }
    return line.len;
}

/// Check if a line is a custom property declaration (starts with --)
fn isCustomPropLine(line: []const u8) bool {
    if (!isCustomPropertyLine(line)) return false;
    const trimmed = std.mem.trimStart(u8, line, " \t");
    return std.mem.find(u8, trimmed, ":") != null;
}

/// Shared state machine for scanning text while skipping string literals.
/// Handles quote pairing and backslash escapes inside strings so callers
/// only see characters outside of string content.
const LineScanner = struct {
    text: []const u8,
    pos: usize,
    in_string: u8,
    trailing_string_backslash: bool,

    fn init(text: []const u8) LineScanner {
        return .{ .text = text, .pos = 0, .in_string = 0, .trailing_string_backslash = false };
    }

    /// Advance to the next character outside of string literals.
    /// Returns null at end of input or when a // line comment is reached.
    fn next(self: *LineScanner) ?u8 {
        return self.advance(true);
    }

    /// Like next(), but does not treat // as a line comment terminator.
    fn nextRaw(self: *LineScanner) ?u8 {
        return self.advance(false);
    }

    fn advance(self: *LineScanner, comptime detect_comment: bool) ?u8 {
        while (self.pos < self.text.len) {
            const ch = self.text[self.pos];
            self.pos += 1;

            if (self.in_string != 0) {
                if (ch == '\\') {
                    if (self.pos < self.text.len) {
                        self.pos += 1;
                        self.trailing_string_backslash = false;
                    } else {
                        self.trailing_string_backslash = true;
                    }
                } else if (ch == self.in_string) {
                    self.in_string = 0;
                    self.trailing_string_backslash = false;
                } else {
                    self.trailing_string_backslash = false;
                }
                continue;
            }

            self.trailing_string_backslash = false;

            switch (ch) {
                '\'', '"' => self.in_string = ch,
                '/' => {
                    if (detect_comment and self.pos < self.text.len and self.text[self.pos] == '/') {
                        self.pos = self.text.len;
                        return null;
                    }
                    return '/';
                },
                else => return ch,
            }
        }
        return null;
    }
};

/// Count the brace { } depth change in a line.
/// When `after_colon` is true, only count braces after the first `:`.
fn countBraceDepth(line: []const u8, after_colon: bool) i32 {
    var depth: i32 = 0;
    var past_colon = !after_colon;
    var scanner = LineScanner.init(line);
    while (scanner.next()) |ch| {
        switch (ch) {
            ':' => past_colon = true,
            '#' => {
                if (scanner.pos < scanner.text.len and scanner.text[scanner.pos] == '{') {
                    scanner.pos += 1;
                }
            },
            '{' => {
                if (past_colon) depth += 1;
            },
            '}' => {
                if (past_colon) depth -= 1;
            },
            else => {},
        }
    }
    return depth;
}

const DepthDelta = struct {
    parens: i32,
    brackets: i32,
    interps: i32,
    /// True when the line ends inside an unclosed string with a trailing backslash
    /// (escaped newline continuation, e.g. 'line1 \<newline>      line2')
    ends_in_escaped_string: bool = false,
};

fn countParenDepthDelta(line: []const u8) DepthDelta {
    var parens: i32 = 0;
    var brackets: i32 = 0;
    var interps: i32 = 0;
    var scanner = LineScanner.init(line);
    while (scanner.next()) |ch| {
        switch (ch) {
            '(' => parens += 1,
            ')' => parens -= 1,
            '[' => brackets += 1,
            ']' => brackets -= 1,
            '#' => {
                if (scanner.pos < scanner.text.len and scanner.text[scanner.pos] == '{') {
                    interps += 1;
                    scanner.pos += 1;
                }
            },
            '}' => {
                if (interps > 0) interps -= 1;
            },
            else => {},
        }
    }
    return .{
        .parens = parens,
        .brackets = brackets,
        .interps = interps,
        .ends_in_escaped_string = scanner.in_string != 0 and scanner.trailing_string_backslash,
    };
}

/// Strip trailing // comment from a line, preserving content before it.
fn stripTrailingComment(line: []const u8) []const u8 {
    var in_str: u8 = 0;
    var in_block_comment = false;
    var i: usize = 0;
    while (i + 1 < line.len) {
        const ch = line[i];
        if (in_str != 0) {
            if (ch == '\\' and i + 1 < line.len) {
                i += 2;
                continue;
            }
            if (ch == in_str) in_str = 0;
            i += 1;
            continue;
        }
        if (in_block_comment) {
            if (ch == '*' and line[i + 1] == '/') {
                in_block_comment = false;
                i += 2;
                continue;
            }
            i += 1;
            continue;
        }
        if (ch == '\'' or ch == '"') {
            in_str = ch;
            i += 1;
            continue;
        }
        if (ch == '/' and line[i + 1] == '*') {
            in_block_comment = true;
            i += 2;
            continue;
        }
        if (ch == '/' and line[i + 1] == '/') {
            const prev_non_space = blk: {
                var j = i;
                while (j > 0) {
                    j -= 1;
                    if (line[j] != ' ' and line[j] != '\t') break :blk line[j];
                }
                break :blk @as(u8, 0);
            };
            if (prev_non_space == ':' or prev_non_space == '/') {
                i += 2;
                continue;
            }
            return std.mem.trimEnd(u8, line[0..i], " \t");
        }
        i += 1;
    }
    return line;
}

/// Check if a line has an unclosed `#{` interpolation.
fn hasUnclosedInterpolation(line: []const u8) bool {
    var depth: i32 = 0;
    var in_string: u8 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (in_string != 0) {
            if (ch == '\\' and i + 1 < line.len) {
                i += 1;
            } else if (ch == in_string) {
                in_string = 0;
            }
            continue;
        }
        switch (ch) {
            '\'' => in_string = '\'',
            '"' => in_string = '"',
            '#' => {
                if (i + 1 < line.len and line[i + 1] == '{') {
                    depth += 1;
                    i += 1;
                }
            },
            '}' => {
                if (depth > 0) depth -= 1;
            },
            else => {},
        }
    }
    return depth > 0;
}

/// Find an unclosed /* comment that starts mid-line (not at position 0).
/// Returns the byte offset of the /* if found, or null.
fn findInlineUnclosedComment(line: []const u8) ?usize {
    var in_string: u8 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (in_string != 0) {
            if (ch == '\\' and i + 1 < line.len) {
                i += 1;
            } else if (ch == in_string) {
                in_string = 0;
            }
            continue;
        }
        switch (ch) {
            '\'' => in_string = '\'',
            '"' => in_string = '"',
            '/' => {
                if (i + 1 < line.len and line[i + 1] == '*') {
                    // Found /*, check if there's a matching */ later on this line
                    if (std.mem.find(u8, line[i + 2 ..], "*/") != null) {
                        //Self-closing on same line -- skip past it
                        const close_off = std.mem.find(u8, line[i + 2 ..], "*/").?;
                        i = i + 2 + close_off + 1; // will be incremented by loop
                        continue;
                    }
                    // Unclosed /* found mid-line
                    if (i > 0) return i;
                    return null; // at position 0, not inline
                }
                if (i + 1 < line.len and line[i + 1] == '/') {
                    //Silent comment -- rest of line is comment, no unclosed /*
                    return null;
                }
            },
            else => {},
        }
    }
    return null;
}

/// Strip all trailing comments (both // and self-closing /* */) from a line.
fn stripAllTrailingComments(line: []const u8) []const u8 {
    var result = stripTrailingComment(line); // strip //
    // Now strip trailing self-closing /* ... */
    while (true) {
        const trimmed = std.mem.trimEnd(u8, result, " \t");
        if (trimmed.len >= 4 and std.mem.endsWith(u8, trimmed, "*/")) {
            // Find the matching /* by searching from the start
            const close_pos = trimmed.len - 2;
            var search_from: usize = 0;
            var found: ?usize = null;
            while (search_from < close_pos) {
                if (std.mem.find(u8, trimmed[search_from..close_pos], "/*")) |offset| {
                    found = search_from + offset;
                    search_from = search_from + offset + 2;
                } else {
                    break;
                }
            }
            if (found) |open_pos| {
                result = std.mem.trimEnd(u8, trimmed[0..open_pos], " \t");
                continue; // Check for more trailing comments
            }
        }
        break;
    }
    return result;
}

/// In .sass, ; is an optional statement terminator. Strip trailing ; from lines.
fn stripTrailingSemicolon(line: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, line, " \t");
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == ';') {
        // Don't strip ; if inside unbalanced parens (e.g., if(css(): c;)
        const delta = countParenDepthDelta(trimmed);
        if (delta.parens > 0 or delta.brackets > 0) return line;
        return std.mem.trimEnd(u8, trimmed[0 .. trimmed.len - 1], " \t");
    }
    return line;
}

/// Check if a line is a bare directive that should remain a leaf statement
/// (should NOT open a block even if the next line has higher indent).
/// These directives require their arguments on the same line in .sass.
fn isLeafDirective(line: []const u8) bool {
    // @charset must have its string argument on the same line
    if (std.mem.eql(u8, line, "@charset")) return true;

    // @import with a trailing comma: it's a complete statement, not a block opener.
    // The trailing comma means "end of import list" in .sass context.
    if (std.mem.startsWith(u8, line, "@import ")) {
        const trimmed_import = std.mem.trimEnd(u8, line, " \t");
        if (trimmed_import.len > 0 and trimmed_import[trimmed_import.len - 1] == ',') return true;
    }

    return false;
}

/// Check if continuation should be suppressed for a given directive line.
/// In .sass, certain directives should NOT have their arguments joined from the next line
/// via keyword/comma continuation when the paren balance is zero.
fn isSuppressedContinuation(line: []const u8) bool {
    const stripped = stripAllTrailingComments(line);
    const trimmed = std.mem.trimEnd(u8, stripped, " \t");
    if (trimmed.len == 0) return false;

    // @import lines: don't allow comma or keyword continuation at paren depth 0
    // In .sass, @import "a.css", is NOT a continuation to the next line
    if (std.mem.startsWith(u8, trimmed, "@import ") or std.mem.eql(u8, trimmed, "@import")) {
        return true;
    }

    // @media and @supports: don't allow `and`, `or`, `not` keyword continuation
    // when the query is complete (paren balance is 0)
    // e.g., `@media (a: b) and` should NOT continue to next line
    if (std.mem.startsWith(u8, trimmed, "@media ") or std.mem.startsWith(u8, trimmed, "@supports ")) {
        const last = trimmed[trimmed.len - 1];
        // Suppress if ending with keyword like `and`, `or`, `not`, or comma
        if (last == ',' or last == ')') return false; // comma after ) might be valid in certain contexts
        // Check for keyword endings
        if (endsWithKeyword(trimmed, "and") or endsWithKeyword(trimmed, "or") or endsWithKeyword(trimmed, "not")) {
            return true;
        }
    }

    return false;
}

/// Strip trailing comma patterns in a parenthesized continuation buffer.
/// Handles patterns like "f(a, )"  ->  "f(a)" and "f(a,\n )"  ->  "f(a)".
fn stripTrailingCommaInBuffer(cb: *std.ArrayList(u8)) void {
    if (cb.items.len < 3) return;
    //Find the last ')' -- it should be at the end
    if (cb.items[cb.items.len - 1] != ')') return;
    // Scan backwards from before ')' to find comma, skipping whitespace/newlines
    var scan: usize = cb.items.len - 2;
    while (scan > 0 and (cb.items[scan] == ' ' or cb.items[scan] == '\t' or cb.items[scan] == '\n' or cb.items[scan] == '\r')) {
        if (scan == 0) return;
        scan -= 1;
    }
    if (cb.items[scan] == ',') {
        // Found trailing comma pattern: remove everything from comma to before ')'
        // Keep content before comma, then append ')'
        cb.items[scan] = ')';
        cb.items.len = scan + 1;
    }
}

fn isIdentStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_' or ch == '-' or ch >= 0x80;
}

/// Check if a line has a `;` in the middle (not at the end), which indicates
/// multiple statements on one line -- not allowed in .sass.
fn hasMiddleSemicolon(line: []const u8) bool {
    var paren_d: i32 = 0;
    var scanner = LineScanner.init(line);
    while (scanner.next()) |ch| {
        switch (ch) {
            '(' => paren_d += 1,
            ')' => paren_d -= 1,
            ';' => {
                if (paren_d <= 0) {
                    const rest = std.mem.trimStart(u8, line[scanner.pos..], " \t");
                    if (rest.len > 0 and !std.mem.startsWith(u8, rest, "//") and !std.mem.startsWith(u8, rest, "/*")) {
                        return true;
                    }
                }
            },
            else => {},
        }
    }
    return false;
}

/// Check if a line ends with a bare `{` that is NOT part of `#{` interpolation
/// and NOT inside a string. This detects SCSS block syntax in .sass files.
/// Only triggers when `{` is at the end of the line (after stripping comments and whitespace).
fn hasBareOpenBrace(line: []const u8) bool {
    const effective = stripAllTrailingComments(line);
    const trimmed = std.mem.trimEnd(u8, effective, " \t");
    if (trimmed.len == 0) return false;
    if (trimmed[trimmed.len - 1] != '{') return false;
    if (trimmed.len >= 2 and trimmed[trimmed.len - 2] == '#') return false;

    var scanner = LineScanner.init(trimmed[0 .. trimmed.len - 1]);
    while (scanner.nextRaw()) |_| {}
    return scanner.in_string == 0;
}

/// Check if a line ends with a keyword (with word boundary before it).
fn endsWithKeyword(line: []const u8, keyword: []const u8) bool {
    if (line.len < keyword.len) return false;
    if (!std.mem.eql(u8, line[line.len - keyword.len ..], keyword)) return false;
    if (line.len == keyword.len) return true;
    const before = line[line.len - keyword.len - 1];
    return before == ' ' or before == '\t' or before == '(' or before == ',';
}

/// Check if a line ends with a keyword/operator that indicates the statement
/// continues on the next line (for .sass multi-line statements without parens).
fn endsWithStatementContinuation(line: []const u8) bool {
    const stripped = stripAllTrailingComments(line);
    const trimmed = std.mem.trimEnd(u8, stripped, " \t");
    if (trimmed.len == 0) return false;

    // Lines like "> *" or "+ .foo" are nested selectors, not expression
    // continuations. In particular, "> *" must not be joined with the next
    // indented line just because it ends in "*".
    if (isSelectorLikeLine(trimmed)) return false;

    const last = trimmed[trimmed.len - 1];

    // Comma and ! are always continuation triggers
    // ! is for multi-line !important (e.g., "b: c!\n    important")
    if (last == ',' or last == '!') return true;

    // Arithmetic operators (+, *, /, %) are continuation ONLY when preceded by space
    // (i.e., they're binary operators like "1 +" or "a *").
    // This prevents treating CSS values like "10%" or selectors like "*" or "+" as continuations.
    //Exception: "/*" at end -- unclosed comment, treat as continuation.
    if (last == '+' or last == '*' or last == '/' or last == '%') {
        if (trimmed.len >= 2 and trimmed[trimmed.len - 2] == ' ') return true;
        if (last == '*' and trimmed.len >= 2 and trimmed[trimmed.len - 2] == '/') return true;
        return false;
    }

    // - only when preceded by space (operator, not part of identifier like font-)
    if (last == '-' and trimmed.len >= 2 and trimmed[trimmed.len - 2] == ' ') return true;

    // > only when preceded by space (standalone ">" is a selector combinator, not continuation)
    if (last == '>' and trimmed.len >= 2 and trimmed[trimmed.len - 2] == ' ') return true;
    // < always (comparison operator, not a CSS combinator)
    if (last == '<') return true;

    //: at end of variable declaration ($var:) -- triggers value continuation
    if (last == ':' and trimmed.len >= 2) {
        const before_colon = std.mem.trimEnd(u8, trimmed[0 .. trimmed.len - 1], " \t");
        if (before_colon.len > 0 and before_colon[0] == '$') return true;
    }

    // Two-char operators: == != >= <=
    if (trimmed.len >= 2) {
        const last2 = trimmed[trimmed.len - 2 ..];
        if (std.mem.eql(u8, last2, "==") or
            std.mem.eql(u8, last2, "!=") or
            std.mem.eql(u8, last2, ">=") or
            std.mem.eql(u8, last2, "<=")) return true;
    }

    // Keyword endings (with word boundary check)
    const keywords = [_][]const u8{
        "from", "through", "to",   "in",   "and", "or",    "not",
        "as",   "with",    "show", "hide", "if",  "using",
    };
    for (&keywords) |kw| {
        if (endsWithKeyword(trimmed, kw)) return true;
    }

    //Bare directives at end of line (NOT @else -- it opens a block, not a continuation)
    const directives = [_][]const u8{
        "@for",    "@each",    "@if",      "@while", "@return",
        "@extend", "@use",     "@forward", "@debug", "@warn",
        "@error",  "@include", "@mixin",
    };
    for (&directives) |dir| {
        if (endsWithKeyword(trimmed, dir)) return true;
    }

    return false;
}

fn isSelectorLineEndingWithCombinator(line: []const u8) bool {
    const stripped = stripAllTrailingComments(line);
    const trimmed = std.mem.trimEnd(u8, stripped, " \t");
    if (trimmed.len < 2) return false;

    const last = trimmed[trimmed.len - 1];
    if (last != '+' and last != '>' and last != '~') return false;
    if (trimmed[trimmed.len - 2] != ' ' and trimmed[trimmed.len - 2] != '\t') return false;

    return isSelectorLine(trimmed);
}

fn shouldSuppressSelectorKeywordContinuation(line: []const u8) bool {
    if (!isSelectorLine(line)) return false;
    const stripped = stripAllTrailingComments(line);
    const trimmed = std.mem.trimEnd(u8, stripped, " \t");
    if (trimmed.len == 0) return false;
    if (trimmed[trimmed.len - 1] == ',') return false;
    return true;
}

fn isInvalidImportSupportsFunctionSplit(current: []const u8, next_trimmed: []const u8) bool {
    if (next_trimmed.len == 0 or next_trimmed[0] != '(') return false;

    const current_trimmed = std.mem.trimEnd(u8, current, " \t");
    if (!std.mem.startsWith(u8, current_trimmed, "@import ")) return false;
    if (std.mem.find(u8, current_trimmed, "supports(") == null) return false;
    if (current_trimmed.len == 0) return false;

    var token_start = current_trimmed.len;
    while (token_start > 0) {
        const ch = current_trimmed[token_start - 1];
        if (!(isIdentStart(ch) or std.ascii.isDigit(ch))) break;
        token_start -= 1;
    }
    if (token_start == current_trimmed.len) return false;

    const token = current_trimmed[token_start..];
    if (std.mem.eql(u8, token, "and") or std.mem.eql(u8, token, "or") or std.mem.eql(u8, token, "not")) {
        return false;
    }

    return true;
}

fn lastNonWhitespaceByte(text: []const u8) ?u8 {
    var i = text.len;
    while (i > 0) {
        i -= 1;
        const ch = text[i];
        if (ch != ' ' and ch != '\t' and ch != '\n' and ch != '\r') return ch;
    }
    return null;
}

fn isBareEmptyParenthesizedPropertyValue(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\n\r");
    if (trimmed.len < 2 or trimmed[trimmed.len - 1] != '(' or trimmed[0] == '$' or trimmed[0] == '@') {
        return false;
    }

    var in_str: u8 = 0;
    var paren_depth: i32 = 0;
    var interp_depth: i32 = 0;
    var colon_idx: ?usize = null;
    for (trimmed, 0..) |ch, i| {
        if (in_str != 0) {
            if (ch == '\\' and i + 1 < trimmed.len) continue;
            if (ch == in_str) in_str = 0;
            continue;
        }
        switch (ch) {
            '\'' => in_str = '\'',
            '"' => in_str = '"',
            '#' => if (i + 1 < trimmed.len and trimmed[i + 1] == '{') {
                interp_depth += 1;
            },
            '}' => {
                if (interp_depth > 0) interp_depth -= 1;
            },
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            ':' => if (paren_depth == 0 and interp_depth == 0) {
                if (i + 1 < trimmed.len and (trimmed[i + 1] == ' ' or trimmed[i + 1] == '\t')) {
                    colon_idx = i;
                    break;
                }
            },
            else => {},
        }
    }

    const idx = colon_idx orelse return false;
    const after_colon = std.mem.trim(u8, trimmed[idx + 1 ..], " \t\n\r");
    return std.mem.eql(u8, after_colon, "(");
}

/// Check if a line contains a directive that is syntactically incomplete
/// (e.g., @each without 'in', @for without 'from').
fn isIncompleteDirective(line: []const u8) bool {
    const stripped = stripTrailingComment(line);
    const trimmed = std.mem.trimEnd(u8, stripped, " \t");

    if (std.mem.startsWith(u8, trimmed, "@each ")) {
        return std.mem.find(u8, trimmed, " in ") == null;
    }
    if (std.mem.startsWith(u8, trimmed, "@for ")) {
        if (std.mem.find(u8, trimmed, " from ") == null) return true;
        // Has 'from' but needs 'through' or 'to'
        return std.mem.find(u8, trimmed, " through ") == null and
            std.mem.find(u8, trimmed, " to ") == null;
    }
    // `@function` / `@mixin` need a name + param list before the body
    // indentation.  `@function` (no name) and `@function a` (name but no
    // `(`) should continue onto the next line.  `@mixin` allows a name-
    // only form (`@mixin foo`) so only flag the bare-keyword case.
    if (std.mem.eql(u8, trimmed, "@function") or std.mem.eql(u8, trimmed, "@mixin")) {
        return true;
    }
    if (std.mem.startsWith(u8, trimmed, "@function ")) {
        // `@function a` (no `(`) is incomplete; `@function a()` is fine.
        return std.mem.findScalar(u8, trimmed, '(') == null;
    }
    return false;
}

/// Check if a line is a bare $variable name without : (needs value on next line).
fn isBareDollarVariable(line: []const u8) bool {
    if (line.len < 2 or line[0] != '$') return false;
    var in_str: u8 = 0;
    var i: usize = 1;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (in_str != 0) {
            if (ch == '\\' and i + 1 < line.len) {
                i += 1;
                continue;
            }
            if (ch == in_str) in_str = 0;
            continue;
        }
        switch (ch) {
            '\'' => in_str = '\'',
            '"' => in_str = '"',
            ':' => return false,
            else => {},
        }
    }
    return true;
}

/// In .sass, lines are categorized as properties or selectors:
/// - `:` followed by space/tab -> property (gets `;`)
/// - `:` not followed by space -> selector pseudo-class (gets `{}`)
/// - No `:` and not a directive/variable -> selector (gets `{}`)
/// This only applies to non-variable, non-directive leaf lines.
fn isSassSelector(line: []const u8) bool {
    if (line.len == 0) return false;
    if (line[0] == '$' or line[0] == '@') return false;

    var paren_depth: i32 = 0;
    var scanner = LineScanner.init(line);
    while (scanner.nextRaw()) |ch| {
        switch (ch) {
            '(' => paren_depth += 1,
            ')' => paren_depth -= 1,
            '#' => {
                if (scanner.pos < scanner.text.len and scanner.text[scanner.pos] == '{') {
                    paren_depth += 1;
                    scanner.pos += 1;
                }
            },
            '}' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            ':' => {
                if (paren_depth > 0) continue;
                if (scanner.pos >= line.len) return true;
                const next_ch = line[scanner.pos];
                if (next_ch == ' ' or next_ch == '\t') return false;
                return true;
            },
            else => {},
        }
    }
    return false;
}

/// Check if a line is a block-opening directive that requires {} even when body is empty.
fn isBlockDirective(line: []const u8) bool {
    const prefixes = [_][]const u8{
        "@for ",       "@each ",  "@while ", "@if ",       "@else",
        "@function ",  "@mixin ", "@media ", "@supports ", "@at-root",
        "@keyframes ",
    };
    for (&prefixes) |prefix| {
        if (std.mem.startsWith(u8, line, prefix)) return true;
        // Exact match for bare directives (e.g., "@at-root")
        if (std.mem.eql(u8, line, prefix)) return true;
    }
    // @include with "using" requires a content block
    if (std.mem.startsWith(u8, line, "@include ")) {
        if (std.mem.find(u8, line, " using")) |_| return true;
    }
    return false;
}

/// Check if a leaf line looks like a CSS selector (not a property declaration,
/// directive, or variable). Used in Phase 2 to decide between {} and ;.
fn looksLikeSelector(line: []const u8) bool {
    if (line.len == 0) return false;
    if (line[0] == '@' or line[0] == '$') return false;
    if (line[0] == ',') return false;

    var paren_depth_sel: i32 = 0;
    var scanner = LineScanner.init(line);
    while (scanner.nextRaw()) |ch| {
        switch (ch) {
            '(' => paren_depth_sel += 1,
            ')' => paren_depth_sel -= 1,
            ':' => {
                if (paren_depth_sel == 0) return false;
            },
            else => {},
        }
    }
    return true;
}

/// Check if the previous line in the buffer (before the current line being processed)
/// ends with a comma, indicating a multi-line continuation.
fn prevLineEndsWithComma(buf: []const u8) bool {
    // Find the last newline in the buffer to get the previous line
    if (buf.len == 0) return false;
    // The buffer currently contains all previously emitted content.
    // The last character should be '\n' from the previous line.
    var end = buf.len;
    if (end > 0 and buf[end - 1] == '\n') end -= 1;
    // Now find the character before any trailing whitespace on the previous line
    while (end > 0 and (buf[end - 1] == ' ' or buf[end - 1] == '\t')) end -= 1;
    if (end > 0 and buf[end - 1] == ',') return true;
    return false;
}

/// Check if a directive is statement-only (never opens a block).
/// These directives don't allow indented children in .sass.
fn isStatementOnlyDirective(line: []const u8) bool {
    // Only truly statement-only directives that NEVER have blocks.
    // @forward/@use/@import are NOT included because indented content after them
    // should produce parser errors (the block opening triggers the error).
    const prefixes = [_][]const u8{
        "@debug ", "@warn ", "@error ", "@return ",
    };
    for (&prefixes) |prefix| {
        if (std.mem.startsWith(u8, line, prefix)) return true;
    }
    return false;
}

/// Check if a childless line looks like a selector (should get {} instead of ;).
/// This handles lines starting with combinators like "+ c", "> .foo", "~ div".
fn isSelectorLikeLine(line: []const u8) bool {
    if (line.len < 2) return false;
    // Lines starting with a combinator followed by space are selectors
    if ((line[0] == '+' or line[0] == '>' or line[0] == '~') and line[1] == ' ') return true;
    return false;
}

fn isFunctionDirective(line: []const u8) bool {
    if (line.len < 10) return false;
    const prefix = "@function ";
    for (prefix, 0..) |expected, idx| {
        if (std.ascii.toLower(line[idx]) != expected) return false;
    }
    return true;
}

fn isInsideFunction(function_stack_items: []const bool) bool {
    for (function_stack_items) |in_func| {
        if (in_func) return true;
    }
    return false;
}

fn isFunctionResultLine(line: []const u8) bool {
    if (line.len < 7) return false;
    if (std.mem.startsWith(u8, line, "#{")) return false;
    const lower = [7]u8{
        std.ascii.toLower(line[0]), std.ascii.toLower(line[1]),
        std.ascii.toLower(line[2]), std.ascii.toLower(line[3]),
        std.ascii.toLower(line[4]), std.ascii.toLower(line[5]),
        line[6],
    };
    return std.mem.eql(u8, &lower, "result:");
}

fn isNoChildDirective(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "@forward ") or std.mem.startsWith(u8, line, "@forward\t") or
        std.mem.eql(u8, line, "@forward"))
        return true;
    if (std.mem.startsWith(u8, line, "@use ") or std.mem.startsWith(u8, line, "@use\t") or
        std.mem.eql(u8, line, "@use"))
        return true;
    return false;
}

fn isElseLine(trimmed: []const u8) bool {
    return std.mem.startsWith(u8, trimmed, "@else");
}

/// Check if a line is a selector (not a property declaration, not a directive).
/// Selectors don't start with @ or $ and don't have a property-like `: ` separator.
fn isSelectorLine(line: []const u8) bool {
    if (line.len == 0) return false;
    // Directives and variables are not selectors
    if (line[0] == '@' or line[0] == '$') return false;
    // Check for property separator `:` (not pseudo-selector `::` or `:hover`)
    var in_str: u8 = 0;
    var in_interp: i32 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (in_str != 0) {
            if (ch == '\\' and i + 1 < line.len) {
                i += 1;
                continue;
            }
            if (ch == in_str) in_str = 0;
            continue;
        }
        switch (ch) {
            '\'' => in_str = '\'',
            '"' => in_str = '"',
            '#' => {
                if (i + 1 < line.len and line[i + 1] == '{') {
                    in_interp += 1;
                    i += 1;
                }
            },
            '}' => {
                if (in_interp > 0) in_interp -= 1;
            },
            '/' => {
                if (i + 1 < line.len and line[i + 1] == '/') return true; // comment; no colon found
            },
            ':' => {
                //`:` followed by space/tab is a property separator  ->  not a selector
                //`:` followed by ident with no space is a pseudo-class/element  ->  selector
                //`::` is a pseudo-element  ->  selector
                if (i + 1 < line.len and line[i + 1] == ':') {
                    i += 1; // skip :: pseudo-element
                    continue;
                }
                if (i + 1 < line.len and (line[i + 1] == ' ' or line[i + 1] == '\t')) {
                    return false; // property separator
                }
                //`:` at end of line or followed by non-space  ->  pseudo-class, continue
            },
            else => {},
        }
    }
    return true; // no property colon found -- selector
}

/// Strip inline // comment from a line for SCSS emission.
/// In .sass, lines like "a // comment," have the comment as part of the original text.
/// In SCSS, // starts a line comment that would swallow any trailing ; or {}.
fn stripInlineCommentForEmit(line: []const u8) []const u8 {
    // Don't strip from pure comments
    if (std.mem.startsWith(u8, line, "//") or std.mem.startsWith(u8, line, "/*")) return line;
    //Don't strip // from custom property values -- // is literal content there
    if (isCustomPropertyLine(line)) return line;
    return stripTrailingComment(line);
}

/// Check if a line starts with a custom property head (`--`).
fn isCustomPropertyLine(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    return std.mem.startsWith(u8, trimmed, "--");
}

fn nextContentLineHasHigherIndent(lines: []const LogicalLine, current_idx: usize, current_indent: usize) bool {
    var j = current_idx + 1;
    while (j < lines.len) : (j += 1) {
        if (lines[j].is_blank or lines[j].is_comment_only) continue;
        return lines[j].indent > current_indent;
    }
    return false;
}

test "basic nesting" {
    const source =
        \\a
        \\  b: c
        \\  d: e
        \\
    ;
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a {\nb: c;\nd: e;\n}\n", result);
}

test "nested selectors" {
    const source =
        \\a
        \\  b
        \\    c: d
        \\  e
        \\    f: g
        \\
    ;
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a {\nb {\nc: d;\n}\ne {\nf: g;\n}\n}\n", result);
}

test "nested child combinator selector" {
    const source =
        \\.pointer-pass-through
        \\  pointer-events: none !important
        \\  > *
        \\    pointer-events: auto !important
        \\
    ;
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(
        \\.pointer-pass-through {
        \\pointer-events: none !important;
        \\> * {
        \\pointer-events: auto !important;
        \\}
        \\}
        \\
    , result);
}

test "bare @at-root followed by nested query line is syntax error" {
    const source =
        \\@at-root
        \\  (without: media)
        \\
    ;

    try std.testing.expectError(error.SassSyntaxError, convert(std.testing.allocator, source));
}

test "if-else" {
    const source =
        \\a
        \\  @if true
        \\    b: c
        \\  @else
        \\    d: e
        \\
    ;
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a {\n@if true {\nb: c;\n} @else {\nd: e;\n}\n}\n", result);
}

test "mixin shorthand" {
    const source =
        \\=my-mixin($a)
        \\  color: $a
        \\
        \\a
        \\  +my-mixin(red)
        \\
    ;
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("@mixin my-mixin($a) {\ncolor: $a;\n}\na {\n@include my-mixin(red);\n}\n", result);
}

test "multi-line paren continuation" {
    const source =
        \\a
        \\  b: (
        \\    c,
        \\    d
        \\  )
        \\
    ;
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a {\nb: (\n    c,\n    d\n  );\n}\n", result);
}

test "multi-line @for without parens" {
    const source =
        \\@for $i from
        \\  1 through 5
        \\  a: $i
        \\
    ;
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("@for $i from 1 through 5 {\na: $i;\n}\n", result);
}

test "multi-line @each with comma continuation" {
    const source =
        \\@each $a,
        \\  $b in (1, 2), (3, 4)
        \\  c: $a $b
        \\
    ;
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("@each $a, $b in (1, 2), (3, 4) {\nc: $a $b;\n}\n", result);
}

test "multi-line @if with operator" {
    const source =
        \\@if $a ==
        \\  b
        \\  c: d
        \\
    ;
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("@if $a == b {\nc: d;\n}\n", result);
}

test "operator continuation at end of line" {
    const source =
        \\a
        \\  b: 1 +
        \\    2
        \\
    ;
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a {\nb: 1 + 2;\n}\n", result);
}

test "multi-level keyword continuation" {
    const source =
        \\@if $a ==
        \\  b and
        \\  $c != d
        \\  color: red
        \\
    ;
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("@if $a == b and $c != d {\ncolor: red;\n}\n", result);
}

test "bare directive continuation" {
    const source =
        \\@use
        \\  "library"
        \\
    ;
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("@use \"library\";\n", result);
}

test "trailing comment in continuation" {
    const source = "@for $i from //\n  1 through 10\n";
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("@for $i from 1 through 10 {}\n", result);
}

test "incomplete @each without in" {
    const source = "@each $a \n  in b, c\n  .x\n    d: e\n";
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("@each $a in b, c {\n.x {\nd: e;\n}\n}\n", result);
}

test "incomplete @for without from" {
    const source = "@for $i\n  from 1 through 10\n";
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("@for $i from 1 through 10 {}\n", result);
}

test "comma continuation same indent no join" {
    const source =
        \\a,
        \\b
        \\  color: red
        \\
    ;
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a,\nb {\ncolor: red;\n}\n", result);
}

test "keyframe selector keyword opens block" {
    const source =
        \\@keyframes spinAround
        \\  from
        \\    transform: rotate(0deg)
        \\  to
        \\    transform: rotate(359deg)
        \\
    ;
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(
        \\@keyframes spinAround {
        \\from {
        \\transform: rotate(0deg);
        \\}
        \\to {
        \\transform: rotate(359deg);
        \\}
        \\}
        \\
    , result);
}

test "pseudo selector comma continuation keeps selector comma" {
    const source =
        \\.button
        \\  &:hover,
        \\  &.is-hovered
        \\    color: red
        \\
    ;
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(
        \\.button {
        \\&:hover,
        \\&.is-hovered {
        \\color: red;
        \\}
        \\}
        \\
    , result);
}

test "operator continuation same indent" {
    const source = "$a: b +\nc\nd\n  e: $a\n";
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("$a: b + c;\nd {\ne: $a;\n}\n", result);
}

test "variable colon continuation" {
    const source = "$a:\n  b\n";
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("$a: b;\n", result);
}

test "bare debug same indent" {
    const source = "@debug\na\n";
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("@debug a;\n", result);
}

test "loud comment auto-close inline" {
    const source = "/* a\n\n";
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/* a */\n", result);
}

test "loud comment indented open" {
    const source = "/* \n  a\n";
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/* a */\n", result);
}

test "loud comment indented closed" {
    const source = "/* \n  a */\n";
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/* a */\n", result);
}

test "loud comment indented closed after" {
    const source = "/* \n  a \n  */\n";
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/* a \n * */\n", result);
}

test "loud comment interpolation" {
    const source = "/* #{a \n  + b} */\n";
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/* #{a + b} */\n", result);
}

test "silent comment indented skip" {
    const source = "// \n  a \n";
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("//\n", result);
}

test "trailing semicolon stripped" {
    const source = "a\n  b: c;\n";
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a {\nb: c;\n}\n", result);
}

test "trailing semicolon with loud comment" {
    const source = "a\n  b: c; /* f */\n  d: e;\n";
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a {\nb: c;\nd: e;\n}\n", result);
}

test "selector inline loud comment stripped for continuation" {
    const source = "a, /* comment */\nb\n  x: y\n";
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a,\nb {\nx: y;\n}\n", result);
}

test "inline loud comment with url keeps scheme slashes" {
    const source =
        \\.visually-hidden /* https://snook.ca/archives/html_and_css/hiding-content-for-accessibility */
        \\  position: absolute !important
        \\
    ;
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(
        \\.visually-hidden /* https://snook.ca/archives/html_and_css/hiding-content-for-accessibility */ {
        \\position: absolute !important;
        \\}
        \\
    , result);
}

test "bare mixin shorthand" {
    const source = "=\n  a\n\nd\n  @include a\n";
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("@mixin a {}\nd {\n@include a;\n}\n", result);
}

test "bare @include continuation" {
    const source = "@mixin a\n@include\n  a\n";
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("@mixin a {}\n@include a;\n", result);
}

test "variable colon on next line" {
    const source = "$a\n  : b\n";
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("$a: b;\n", result);
}

test "using keyword continuation" {
    const source = "@mixin a\n  @content\n@include a() using\n  ($b)\n  c: $b\n";
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("@mixin a {\n@content;\n}\n@include a() using ($b) {\nc: $b;\n}\n", result);
}

test "error: @include closed before indented using clause" {
    const source =
        \\@mixin a
        \\  @content
        \\@include a()
        \\  using ()
        \\
    ;
    try std.testing.expectError(error.SassSyntaxError, convert(std.testing.allocator, source));
}

test "error: bare @-moz-document then indented prelude" {
    const source =
        \\@-moz-document
        \\  url-prefix(a)
        \\
    ;
    try std.testing.expectError(error.SassSyntaxError, convert(std.testing.allocator, source));
}

test "paren continuation preserves newlines" {
    const source = "@supports (a\n  b)\n    c\n      d: e\n";
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("@supports (a\n  b) {\nc {\nd: e;\n}\n}\n", result);
}

test "css function comma before newline" {
    // css/functions/newlines.hrx::comma/before
    // In .sass, "c(d\n      ,e)" should normalize to "c(d, e)"
    const source = "a\n  b: c(d\n      ,e)\n";
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a {\nb: c(d, e);\n}\n", result);
}

test "css function trailing_comma before" {
    // css/functions/newlines.hrx::trailing_comma/before
    //In .sass, "c(d\n ,)" trailing comma is stripped  ->  "c(d)"
    const source = "a\n  b: c(d\n      ,)\n";
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a {\nb: c(d);\n}\n", result);
}

test "css function trailing_comma after" {
    // css/functions/newlines.hrx::trailing_comma/after
    //In .sass, "c(d,\n )" trailing comma is stripped  ->  "c(d)"
    const source = "a\n  b: c(d,\n      )\n";
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a {\nb: c(d);\n}\n", result);
}

test "operator binary before not joined" {
    // operators/newlines.hrx::binary/before
    // "+ c" at the top level is a selector (combinator), gets {} not ;
    const source = "$a: b\n+ c\nd\n  e: $a\n";
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("$a: b;\n+ c {}\nd {\ne: $a;\n}\n", result);
}

test "operator error binary before_indent" {
    // operators/newlines.hrx::error/binary/before_indent
    // Note: trailing space after 'b' on first line
    //"+ c" at indent 2 is indented under a variable declaration  ->  .sass syntax error
    const source = "$a: b \n  + c\n";
    const result = convert(std.testing.allocator, source);
    try std.testing.expectError(error.SassSyntaxError, result);
}

test "if css function newline" {
    // expressions/if/syntax.hrx::newline/in_css_function
    //css(\n) becomes css() -- empty paren, newline stripped
    const source = "a\n  b: if(css(\n): c)\n";
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a {\nb: if(css(): c);\n}\n", result);
}

test "error: empty parenthesized property value with only whitespace between lines" {
    const source =
        \\a
        \\  b: (
        \\  )
        \\
    ;
    const result = convert(std.testing.allocator, source);
    try std.testing.expectError(error.SassSyntaxError, result);
}

test "escaped newline in string" {
    // values/strings.hrx::new-line/sass/escaped
    const source = "a \n  b: 'line1 \\\n      line2'\n";
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a {\nb: 'line1 \\\n      line2';\n}\n", result);
}

test "error: variable with indented !default" {
    // variables/whitespace.hrx::error/before_default/sass
    const result = convert(std.testing.allocator, "$a: b\n  !default\n");
    try std.testing.expectError(error.SassSyntaxError, result);
}

test "error: variable with indented !global" {
    // variables/whitespace.hrx::error/before_global/sass
    const result = convert(std.testing.allocator, "$a: b\n  !global\n");
    try std.testing.expectError(error.SassSyntaxError, result);
}

test "error: @charset with indented arg" {
    // css/charset.hrx::error/whitespace/sass
    const result = convert(std.testing.allocator, "@charset\n  \"a\"\n");
    try std.testing.expectError(error.SassSyntaxError, result);
}

test "error: bare @media with indented query" {
    // css/media/whitespace.hrx::error/before_query/sass
    const result = convert(std.testing.allocator, "@media\n  screen\n");
    try std.testing.expectError(error.SassSyntaxError, result);
}

test "error: custom property with nested content" {
    // css/custom_properties/error.hrx::nested
    const result = convert(std.testing.allocator, ".no-nesting\n  --foo: bar\n    baz: qux\n");
    try std.testing.expectError(error.SassSyntaxError, result);
}

test "error: inconsistent indentation" {
    // non_conformant/sass/indentation.hrx::error/inconsistent
    const result = convert(std.testing.allocator, "a\n    b: c\n d: e\n");
    try std.testing.expectError(error.SassSyntaxError, result);
}

test "error: content after closed comment" {
    // css/comment.hrx::error/loud/sass/content_after_close/multi_line
    const result = convert(std.testing.allocator, "/*\n  */\n  a\n");
    try std.testing.expectError(error.SassSyntaxError, result);
}

test "error: selector followed by comma line" {
    // parser/selector.hrx::error/newline/before_comma
    const result = convert(std.testing.allocator, "a\n,b\n  c: d\n");
    try std.testing.expectError(error.SassSyntaxError, result);
}

test "error: @import comma with indented continuation" {
    // css/plain/import/whitespace.hrx::error/supports/declaration/followed_by_import_arg/after_comma/sass
    const result = convert(std.testing.allocator, "@import \"a\" supports(b: c),\n  \"d.css\"\n");
    try std.testing.expectError(error.SassSyntaxError, result);
}

test "error: @import supports function split before paren" {
    // css/plain/import/whitespace.hrx::error/supports/condition_function/before_paren/sass
    const result = convert(std.testing.allocator, "@import \"a.css\" supports(a\n  (b))\n");
    try std.testing.expectError(error.SassSyntaxError, result);
}

test "selector trailing combinator does not continue to next line" {
    // css/selector/combinator/newline.hrx::child/after
    const source = "a >\nb\n  c: d\n";
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a > {}\nb {\nc: d;\n}\n", result);
}

test "selector pseudo multiline arg trims opening whitespace" {
    const source = "a:b(\n  c)\n  d: e\n";
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a:b(c) {\nd: e;\n}\n", result);
}

test "selector pseudo multiline arg trims closing whitespace" {
    const source = "a:b(c\n  )\n  d: e\n";
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a:b(c) {\nd: e;\n}\n", result);
}

test "sassdoc silent comments normalize before function after use" {
    const source =
        \\@use 'sass:meta'
        \\
        \\///
        \\  @overload f($x)
        \\///
        \\@function f($x)
        \\  @if meta.type-of($x) != 'number'
        \\    @return 1
        \\  @return 2
        \\
    ;
    const result = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(
        "@use 'sass:meta';\n//\n//\n@function f($x) {\n@if meta.type-of($x) != 'number' {\n@return 1;\n}\n@return 2;\n}\n",
        result,
    );
}
