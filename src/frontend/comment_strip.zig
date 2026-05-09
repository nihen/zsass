const std = @import("std");
const string_scan = @import("string_scan.zig");

fn isWs(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}
/// Strip comments from @supports conditions while preserving expression separators.
pub fn stripSupportsComments(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var i: usize = 0;
    var in_string: u8 = 0;
    const Context = enum { normal, preserve_newline, preserve_space };
    var ctx_stack: [32]Context = undefined;
    var ctx_depth: u32 = 0;
    var cur_ctx: Context = .normal;

    while (i < text.len) {
        if (try string_scan.consumeStringQuoting(allocator, &buf, text, &i, &in_string)) continue;
        const c = text[i];
        if (c == '(') {
            if (ctx_depth < ctx_stack.len) {
                ctx_stack[ctx_depth] = cur_ctx;
                ctx_depth += 1;
            }
            const is_func = buf.items.len > 0 and
                (std.ascii.isAlphanumeric(buf.items[buf.items.len - 1]) or
                    buf.items[buf.items.len - 1] == '-' or
                    buf.items[buf.items.len - 1] == '_');
            if (is_func) {
                cur_ctx = .preserve_newline;
            } else {
                cur_ctx = .normal;
                // Look ahead to determine if anything condition (no colon) or custom prop
                var j = i + 1;
                while (j < text.len and (text[j] == ' ' or text[j] == '\t' or text[j] == '\n' or text[j] == '\r')) j += 1;
                // Skip comments while peeking
                while (j + 1 < text.len and text[j] == '/') {
                    if (text[j + 1] == '*') {
                        j += 2;
                        while (j + 1 < text.len) {
                            if (text[j] == '*' and text[j + 1] == '/') {
                                j += 2;
                                break;
                            }
                            j += 1;
                        }
                    } else if (text[j + 1] == '/') {
                        j += 2;
                        while (j < text.len and text[j] != '\n') j += 1;
                        if (j < text.len) j += 1;
                    } else break;
                    while (j < text.len and (text[j] == ' ' or text[j] == '\t' or text[j] == '\n' or text[j] == '\r')) j += 1;
                }
                const is_custom = (j + 1 < text.len and text[j] == '-' and text[j + 1] == '-');
                if (!is_custom) {
                    // Check for colon and top-level and/or at same depth
                    var pd: u32 = 0;
                    var has_colon = false;
                    var has_and_or = false;
                    var pk = j;
                    var ps: u8 = 0;
                    while (pk < text.len) {
                        if (ps != 0) {
                            if (text[pk] == '\\' and pk + 1 < text.len) {
                                pk += 2;
                                continue;
                            }
                            if (text[pk] == ps) ps = 0;
                            pk += 1;
                            continue;
                        }
                        if (text[pk] == '"' or text[pk] == '\'') {
                            ps = text[pk];
                            pk += 1;
                            continue;
                        }
                        if (text[pk] == '(') pd += 1 else if (text[pk] == ')') {
                            if (pd == 0) break;
                            pd -= 1;
                        } else if (text[pk] == ':' and pd == 0) {
                            has_colon = true;
                            break;
                        } else if (pd == 0 and !has_and_or) {
                            // Check for top-level 'and' or 'or' keyword
                            if (pk > 0 and isWs(text[pk - 1])) {
                                if (pk + 3 < text.len and text[pk] == 'a' and text[pk + 1] == 'n' and text[pk + 2] == 'd' and isWs(text[pk + 3])) {
                                    has_and_or = true;
                                } else if (pk + 2 < text.len and text[pk] == 'o' and text[pk + 1] == 'r' and isWs(text[pk + 2])) {
                                    has_and_or = true;
                                }
                            }
                        }
                        pk += 1;
                    }
                    // Preserve newlines only for "anything" conditions
                    // (no colon AND no top-level and/or AND not starting with "not").
                    // Condition lists with and/or/not use normal (collapsed) whitespace.
                    const starts_with_not = blk_not: {
                        const after_ws = std.mem.trimStart(u8, text[j..], " \t\n\r");
                        break :blk_not after_ws.len >= 4 and after_ws[0] == 'n' and after_ws[1] == 'o' and after_ws[2] == 't' and isWs(after_ws[3]);
                    };
                    if (!has_colon and !has_and_or and !starts_with_not) cur_ctx = .preserve_newline;
                }
            }
            try buf.append(allocator, c);
            i += 1;
            // For anything conditions (non-function, preserve_newline context),
            // skip whitespace/newlines immediately after '(' to normalize indentation.
            if (!is_func and cur_ctx == .preserve_newline) {
                while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r')) i += 1;
            }
            continue;
        }
        if (c == ')') {
            if (cur_ctx == .normal) {
                // Trim trailing spaces/tabs before )
                while (buf.items.len > 0 and (buf.items[buf.items.len - 1] == ' ' or buf.items[buf.items.len - 1] == '\t')) {
                    _ = buf.pop();
                }
            } else if (cur_ctx == .preserve_newline) {
                // In function args or anything conditions: preserve all content
                // before ), including trailing spaces. The newline trimming of
                // trailing spaces before newlines is handled in whitespace processing.
            }
            if (ctx_depth > 0) {
                ctx_depth -= 1;
                cur_ctx = ctx_stack[ctx_depth];
            }
            try buf.append(allocator, c);
            i += 1;
            continue;
        }
        if (c == ':' and ctx_depth > 0 and cur_ctx == .normal) {
            try buf.append(allocator, c);
            i += 1;
            var sp: usize = buf.items.len;
            while (sp > 0) {
                sp -= 1;
                if (buf.items[sp] == '(') {
                    const prop = std.mem.trim(u8, buf.items[sp + 1 .. buf.items.len - 1], " \t\n\r");
                    if (prop.len >= 2 and prop[0] == '-' and prop[1] == '-') {
                        cur_ctx = .preserve_space;
                    }
                    break;
                }
            }
            continue;
        }
        if (c == '/' and i + 1 < text.len) {
            if (text[i + 1] == '*') {
                if (cur_ctx != .normal) {
                    // Check if immediately after non-function ( - if so, strip the comment
                    const last_char = if (buf.items.len > 0) buf.items[buf.items.len - 1] else @as(u8, 0);
                    const is_after_func_paren = last_char == '(' and buf.items.len >= 2 and
                        (std.ascii.isAlphanumeric(buf.items[buf.items.len - 2]) or
                            buf.items[buf.items.len - 2] == '-' or
                            buf.items[buf.items.len - 2] == '_');
                    if (last_char == '(' and !is_after_func_paren) {
                        // Non-function paren: strip the comment
                        i += 2;
                        while (i + 1 < text.len) {
                            if (text[i] == '*' and text[i + 1] == '/') {
                                i += 2;
                                break;
                            }
                            i += 1;
                        }
                        while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r')) i += 1;
                        continue;
                    }
                    try buf.appendSlice(allocator, "/*");
                    i += 2;
                    while (i + 1 < text.len) {
                        if (text[i] == '*' and text[i + 1] == '/') {
                            try buf.appendSlice(allocator, "*/");
                            i += 2;
                            break;
                        }
                        try buf.append(allocator, text[i]);
                        i += 1;
                    }
                    continue;
                }
                while (buf.items.len > 0 and (buf.items[buf.items.len - 1] == ' ' or buf.items[buf.items.len - 1] == '\t' or buf.items[buf.items.len - 1] == '\n' or buf.items[buf.items.len - 1] == '\r')) {
                    _ = buf.pop();
                }
                i += 2;
                while (i + 1 < text.len) {
                    if (text[i] == '*' and text[i + 1] == '/') {
                        i += 2;
                        break;
                    }
                    i += 1;
                }
                while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r')) i += 1;
                if (i < text.len and buf.items.len > 0) {
                    const last = buf.items[buf.items.len - 1];
                    if (last != '(' and last != '[' and text[i] != ')' and text[i] != ']' and text[i] != ':') {
                        try buf.append(allocator, ' ');
                    }
                }
                continue;
            } else if (text[i + 1] == '/') {
                if (cur_ctx != .normal) {
                    const last_char = if (buf.items.len > 0) buf.items[buf.items.len - 1] else @as(u8, 0);
                    const is_func_open = last_char == '(' and buf.items.len >= 2 and
                        (std.ascii.isAlphanumeric(buf.items[buf.items.len - 2]) or
                            buf.items[buf.items.len - 2] == '-' or
                            buf.items[buf.items.len - 2] == '_');
                    i += 2;
                    while (i < text.len and text[i] != '\n') i += 1;
                    if (last_char == '(' and is_func_open) {
                        // After function ( : keep newline + indentation
                        if (i < text.len and text[i] == '\n') {
                            try buf.append(allocator, '\n');
                            i += 1;
                            while (i < text.len and (text[i] == ' ' or text[i] == '\t')) {
                                try buf.append(allocator, text[i]);
                                i += 1;
                            }
                        }
                    } else if (last_char == '(') {
                        // After non-function ( : skip comment entirely
                        if (i < text.len and text[i] == '\n') i += 1;
                        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
                    } else if (cur_ctx == .preserve_space) {
                        // Custom property value: replace with space
                        if (i < text.len and text[i] == '\n') i += 1;
                        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
                        try buf.append(allocator, ' ');
                    } else {
                        // preserve_newline: keep newline + indentation
                        if (i < text.len and text[i] == '\n') {
                            try buf.append(allocator, '\n');
                            i += 1;
                            while (i < text.len and (text[i] == ' ' or text[i] == '\t')) {
                                try buf.append(allocator, text[i]);
                                i += 1;
                            }
                        } else {
                            try buf.append(allocator, ' ');
                        }
                    }
                    continue;
                }
                while (buf.items.len > 0 and (buf.items[buf.items.len - 1] == ' ' or buf.items[buf.items.len - 1] == '\t')) {
                    _ = buf.pop();
                }
                i += 2;
                while (i < text.len and text[i] != '\n') i += 1;
                if (i < text.len and text[i] == '\n') i += 1;
                while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
                if (i < text.len and buf.items.len > 0) {
                    const last = buf.items[buf.items.len - 1];
                    if (last != '(' and last != '[' and text[i] != ')' and text[i] != ']' and text[i] != ':') {
                        try buf.append(allocator, ' ');
                    }
                }
                continue;
            }
        }
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0c') {
            if (cur_ctx != .normal) {
                if (c == '\n' or c == '\r') {
                    // Before adding newline, trim trailing spaces/tabs on current line
                    while (buf.items.len > 0 and (buf.items[buf.items.len - 1] == ' ' or buf.items[buf.items.len - 1] == '\t')) {
                        _ = buf.pop();
                    }
                }
                try buf.append(allocator, c);
                i += 1;
                continue;
            }
            while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r' or text[i] == '\x0c')) i += 1;
            if (buf.items.len > 0) {
                const last = buf.items[buf.items.len - 1];
                const nc = if (i < text.len) text[i] else @as(u8, 0);
                if (last != '(' and last != '[' and nc != ')' and nc != ']' and nc != ':') {
                    try buf.append(allocator, ' ');
                }
            }
            continue;
        }
        try buf.append(allocator, c);
        i += 1;
    }

    return buf.toOwnedSlice(allocator);
}

/// Strip comments from at-rule preludes.
/// - Silent comments (//) are always stripped.
/// - Loud comments (/* */) are stripped if followed by non-whitespace content,
///   but preserved if they are at the trailing end (just before ; or {).
/// Returns the original slice if no changes were needed (no allocation).
pub fn stripPreludeComments(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    // Quick check: if no comment markers, return as-is
    if (std.mem.find(u8, text, "/*") == null and std.mem.find(u8, text, "//") == null) return text;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var i: usize = 0;
    var in_string: u8 = 0;
    var paren_depth: u32 = 0;

    while (i < text.len) {
        if (try string_scan.consumeStringQuoting(allocator, &buf, text, &i, &in_string)) continue;
        const c = text[i];
        if (c == '(') {
            paren_depth += 1;
            try buf.append(allocator, c);
            i += 1;
            continue;
        }
        if (c == ')') {
            if (paren_depth > 0) paren_depth -= 1;
            try buf.append(allocator, c);
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < text.len and paren_depth == 0) {
            if (text[i + 1] == '*') {
                // Loud comment: preserve if there's content before it,
                // strip if it appears before any real content
                const comment_start = i;
                i += 2;
                while (i + 1 < text.len) {
                    if (text[i] == '*' and text[i + 1] == '/') {
                        i += 2;
                        break;
                    }
                    i += 1;
                }
                const comment_end = i;
                // Check if there's non-whitespace content before the comment
                const trimmed_buf = std.mem.trim(u8, buf.items, " \t\n\r");
                if (trimmed_buf.len > 0) {
                    // There's content before: preserve the comment
                    try buf.appendSlice(allocator, text[comment_start..comment_end]);
                } else {
                    // No content before: strip the comment
                    // Skip whitespace after comment
                    while (i < text.len and (text[i] == ' ' or text[i] == '\t' or
                        text[i] == '\n' or text[i] == '\r'))
                    {
                        i += 1;
                    }
                }
                continue;
            } else if (text[i + 1] == '/') {
                // Silent comment: strip the comment text.
                // EXCEPTION: if the '//' follows a ':' or '/', it's likely a URL
                // scheme separator (e.g., https://) or path component, not a comment.
                // In that case, treat it as regular content.
                const prev_non_space = blk: {
                    var j = buf.items.len;
                    while (j > 0) {
                        j -= 1;
                        if (buf.items[j] != ' ' and buf.items[j] != '\t') break :blk buf.items[j];
                    }
                    break :blk @as(u8, 0);
                };
                if (prev_non_space == ':' or prev_non_space == '/') {
                    // Treat as regular content (URL scheme separator)
                    try buf.append(allocator, c);
                    i += 1;
                    continue;
                }
                // Check if there's non-whitespace content before the comment.
                const has_content_before = std.mem.trim(u8, buf.items, " \t\n\r").len > 0;
                // Skip the // and rest of line content
                i += 2;
                while (i < text.len and text[i] != '\n') {
                    i += 1;
                }
                if (has_content_before) {
                    // Content before: preserve whitespace structure
                    // (newline and indentation will be emitted in next iteration)
                } else {
                    // No content before: collapse whitespace
                    if (i < text.len and text[i] == '\n') {
                        i += 1;
                    }
                    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) {
                        i += 1;
                    }
                }
                continue;
            }
        }
        try buf.append(allocator, c);
        i += 1;
    }

    return buf.toOwnedSlice(allocator);
}
