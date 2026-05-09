const std = @import("std");
const prelude = @import("prelude.zig");
const css_utils = @import("../runtime/css_utils.zig");

const collapseImportSupportsWhitespace = prelude.collapseImportSupportsWhitespace;

/// Closing `}` for `#{ ... }`, honoring nested `#{`, strings, and `//` / `/* */` comments.
fn findInterpExprEnd(text: []const u8, inner_start: usize) ?usize {
    var depth: u32 = 1;
    var p = inner_start;
    while (p < text.len) {
        if (p + 1 < text.len and text[p] == '#' and text[p + 1] == '{') {
            depth += 1;
            p += 2;
            continue;
        }
        if (text[p] == '}') {
            depth -= 1;
            if (depth == 0) return p;
            p += 1;
            continue;
        }
        if (text[p] == '"' or text[p] == '\'') {
            const quote = text[p];
            p += 1;
            while (p < text.len) {
                if (text[p] == '\\' and p + 1 < text.len) {
                    p += 2;
                    continue;
                }
                if (text[p] == quote) {
                    p += 1;
                    break;
                }
                p += 1;
            }
            continue;
        }
        if (p + 1 < text.len and text[p] == '/' and text[p + 1] == '/') {
            p += 2;
            while (p < text.len and text[p] != '\n') p += 1;
            continue;
        }
        if (p + 1 < text.len and text[p] == '/' and text[p + 1] == '*') {
            p += 2;
            while (p + 1 < text.len) {
                if (text[p] == '*' and text[p + 1] == '/') {
                    p += 2;
                    break;
                }
                p += 1;
            }
            continue;
        }
        p += 1;
    }
    return null;
}

fn cssIdentEquals(name: []const u8, expected_lower: []const u8) bool {
    if (name.len != expected_lower.len) return false;
    for (name, expected_lower) |raw, want| {
        var c = raw;
        if (c == '_') c = '-';
        if (std.ascii.toLower(c) != want) return false;
    }
    return true;
}

fn findMatchingParenSimple(text: []const u8, open_idx: usize) ?usize {
    if (open_idx >= text.len or text[open_idx] != '(') return null;
    var depth: i32 = 0;
    var in_string: u8 = 0;
    var i = open_idx;
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
        if (c == '\\' and i + 1 < text.len) {
            i += 1;
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

fn isImportIdentStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_' or ch == '-';
}

fn isImportIdentContinue(ch: u8) bool {
    return isImportIdentStart(ch) or std.ascii.isDigit(ch);
}

fn firstNonWhitespaceIndex(text: []const u8, start: usize) ?usize {
    var i = start;
    while (i < text.len) : (i += 1) {
        if (!std.ascii.isWhitespace(text[i])) return i;
    }
    return null;
}

fn importLogicKeywordLen(text: []const u8, start: usize) usize {
    if (start >= text.len) return 0;
    if (start > 0 and isImportIdentContinue(text[start - 1])) return 0;
    const rem = text[start..];
    if (rem.len >= 3 and std.ascii.eqlIgnoreCase(rem[0..3], "and") and (rem.len == 3 or !isImportIdentContinue(rem[3]))) return 3;
    if (rem.len >= 2 and std.ascii.eqlIgnoreCase(rem[0..2], "or") and (rem.len == 2 or !isImportIdentContinue(rem[2]))) return 2;
    if (rem.len >= 3 and std.ascii.eqlIgnoreCase(rem[0..3], "not") and (rem.len == 3 or !isImportIdentContinue(rem[3]))) return 3;
    return 0;
}

fn normalizeImportLogicKeywordSpacing(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var changed = false;
    var i: usize = 0;
    var in_string: u8 = 0;
    while (i < text.len) {
        const c = text[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < text.len) {
                try out.append(allocator, c);
                i += 1;
                try out.append(allocator, text[i]);
                i += 1;
                continue;
            }
            if (c == in_string) in_string = 0;
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            try out.append(allocator, c);
            i += 1;
            continue;
        }

        const kw_len = importLogicKeywordLen(text, i);
        if (kw_len != 0) {
            const after_kw = i + kw_len;
            if (after_kw < text.len and text[after_kw] == '(') {
                try out.appendSlice(allocator, text[i..after_kw]);
                try out.append(allocator, ' ');
                changed = true;
                i = after_kw;
                continue;
            }
        }

        try out.append(allocator, c);
        i += 1;
    }

    if (!changed) {
        out.deinit(allocator);
        return text;
    }
    return out.toOwnedSlice(allocator);
}

fn findTopLevelComma(text: []const u8) ?usize {
    var depth: u32 = 0;
    var in_string: u8 = 0;
    var i: usize = 0;
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
        if (c == '(') {
            depth += 1;
            continue;
        }
        if (c == ')') {
            if (depth > 0) depth -= 1;
            continue;
        }
        if (c == ',' and depth == 0) return i;
    }
    return null;
}

fn startsWithImportLogicKeyword(text: []const u8) bool {
    const idx = firstNonWhitespaceIndex(text, 0) orelse return false;
    return importLogicKeywordLen(text, idx) != 0;
}

fn startsWithImportIdentifier(text: []const u8) bool {
    const idx = firstNonWhitespaceIndex(text, 0) orelse return false;
    return isImportIdentStart(text[idx]);
}

fn startsWithImportFunctionCall(text: []const u8, name: []const u8) bool {
    const idx = firstNonWhitespaceIndex(text, 0) orelse return false;
    if (!isImportIdentStart(text[idx])) return false;
    var end = idx + 1;
    while (end < text.len and isImportIdentContinue(text[end])) : (end += 1) {}
    const ident = text[idx..end];
    if (!cssIdentEquals(ident, name)) return false;
    const after_ident = firstNonWhitespaceIndex(text, end) orelse return false;
    if (text[after_ident] != '(') return false;
    return css_utils.findMatchingParen(text, after_ident) != null;
}

fn startsWithAnyImportFunctionCall(text: []const u8) bool {
    const idx = firstNonWhitespaceIndex(text, 0) orelse return false;
    if (!isImportIdentStart(text[idx])) return false;
    var end = idx + 1;
    while (end < text.len and isImportIdentContinue(text[end])) : (end += 1) {}
    const after_ident = firstNonWhitespaceIndex(text, end) orelse return false;
    if (text[after_ident] != '(') return false;
    return css_utils.findMatchingParen(text, after_ident) != null;
}

fn tryUnwrapSupportsDeclParenInner(allocator: std.mem.Allocator, inner: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, inner, " \t\n\r");
    if (trimmed.len < 2 or trimmed[0] != '(' or trimmed[trimmed.len - 1] != ')') return null;
    const close = css_utils.findMatchingParen(trimmed, 0) orelse return null;
    if (close != trimmed.len - 1) return null;
    const decl = trimmed[1..close];
    if (css_utils.findDeclarationColon(decl) == null) return null;
    return allocator.dupe(u8, decl) catch null;
}

pub fn normalizeImportConditionText(allocator: std.mem.Allocator, cond: []const u8) ![]const u8 {
    var work = try normalizeImportLogicKeywordSpacing(allocator, cond);
    errdefer if (!(work.ptr == cond.ptr and work.len == cond.len)) allocator.free(work);

    const media_normalized = try normalizeImportMediaFeatureSpacing(allocator, work);
    if (media_normalized.ptr != work.ptr and !(work.ptr == cond.ptr and work.len == cond.len)) allocator.free(work);
    work = media_normalized;

    if (std.ascii.indexOfIgnoreCase(work, "supports(") == null) return work;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var copy_from: usize = 0;
    var i: usize = 0;
    while (i < work.len) {
        if (i + 8 < work.len and
            std.ascii.eqlIgnoreCase(work[i .. i + 8], "supports") and
            work[i + 8] == '(' and
            (i == 0 or !css_utils.isIdentChar(work[i - 1])))
        {
            const open_paren = i + 8;
            const close = css_utils.findMatchingParen(work, open_paren) orelse {
                i += 1;
                continue;
            };
            try out.appendSlice(allocator, work[copy_from..i]);
            const inner_raw = work[open_paren + 1 .. close];
            const inner = try collapseImportSupportsWhitespace(allocator, inner_raw);
            defer if (!(inner.ptr == inner_raw.ptr and inner.len == inner_raw.len)) allocator.free(inner);
            const trimmed_inner = std.mem.trim(u8, inner, " \t\n\r");
            const use_custom_prop_spacing = std.mem.startsWith(u8, trimmed_inner, "--");
            const normalized_inner = if (use_custom_prop_spacing) inner else trimmed_inner;
            try out.appendSlice(allocator, work[i .. open_paren + 1]);
            if (tryUnwrapSupportsDeclParenInner(allocator, normalized_inner)) |uw| {
                defer allocator.free(uw);
                try out.appendSlice(allocator, uw);
            } else {
                try out.appendSlice(allocator, normalized_inner);
            }
            try out.append(allocator, ')');
            i = close + 1;
            copy_from = i;
            continue;
        }
        i += 1;
    }
    try out.appendSlice(allocator, work[copy_from..]);
    const normalized = try out.toOwnedSlice(allocator);
    if (!(work.ptr == cond.ptr and work.len == cond.len)) allocator.free(work);
    return normalized;
}

pub fn importConditionParenIsFunctionCall(text: []const u8, open_idx: usize) bool {
    if (open_idx == 0 or open_idx > text.len or text[open_idx] != '(') return false;
    var end = open_idx;
    while (end > 0 and std.ascii.isWhitespace(text[end - 1])) : (end -= 1) {}
    if (end == 0 or !isImportIdentContinue(text[end - 1])) return false;

    var start = end - 1;
    while (start > 0 and isImportIdentContinue(text[start - 1])) : (start -= 1) {}
    const word = text[start..end];
    return !(cssIdentEquals(word, "and") or cssIdentEquals(word, "or") or cssIdentEquals(word, "not"));
}

pub fn isSingleInterpolationBlockText(text: []const u8) bool {
    if (text.len < 3 or text[0] != '#' or text[1] != '{') return false;
    const close = findInterpExprEnd(text, 2) orelse return false;
    return close == text.len - 1;
}

fn normalizeImportMediaFeatureSpacing(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '(') == null) return text;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var changed = false;
    var i: usize = 0;
    var in_string: u8 = 0;
    while (i < text.len) {
        const c = text[i];
        if (in_string != 0) {
            try out.append(allocator, c);
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                try out.append(allocator, text[i]);
            } else if (c == in_string) {
                in_string = 0;
            }
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        if (c == '(' and !importConditionParenIsFunctionCall(text, i)) {
            const close = findMatchingParenSimple(text, i) orelse {
                try out.append(allocator, c);
                i += 1;
                continue;
            };
            const inner = text[i + 1 .. close];
            const trimmed_inner = std.mem.trim(u8, inner, " \t\r\n");

            try out.append(allocator, '(');
            if (isSingleInterpolationBlockText(trimmed_inner)) {
                try out.appendSlice(allocator, trimmed_inner);
                if (trimmed_inner.ptr != inner.ptr or trimmed_inner.len != inner.len) changed = true;
            } else if (css_utils.findDeclarationColon(trimmed_inner)) |colon_pos| {
                const lhs = std.mem.trim(u8, trimmed_inner[0..colon_pos], " \t\r\n");
                const rhs = std.mem.trim(u8, trimmed_inner[colon_pos + 1 ..], " \t\r\n");
                try out.appendSlice(allocator, lhs);
                try out.appendSlice(allocator, ": ");
                try out.appendSlice(allocator, rhs);
                const normalized_len = lhs.len + 2 + rhs.len;
                if (normalized_len != inner.len or
                    !std.mem.eql(u8, trimmed_inner[0..lhs.len], lhs) or
                    !std.mem.eql(u8, trimmed_inner[trimmed_inner.len - rhs.len ..], rhs) or
                    std.mem.indexOfScalar(u8, inner, ' ') != null or
                    std.mem.indexOfAny(u8, inner, "\t\r\n") != null)
                {
                    changed = true;
                }
            } else {
                try out.appendSlice(allocator, trimmed_inner);
                if (trimmed_inner.ptr != inner.ptr or trimmed_inner.len != inner.len) changed = true;
            }
            try out.append(allocator, ')');
            i = close + 1;
            continue;
        }

        try out.append(allocator, c);
        i += 1;
    }

    if (!changed and std.mem.eql(u8, out.items, text)) {
        out.deinit(allocator);
        return text;
    }
    return out.toOwnedSlice(allocator);
}

fn validateImportSupportsCustomPropertyClauses(cond: []const u8) !void {
    var i: usize = 0;
    while (i < cond.len) {
        if (i + 8 < cond.len and
            std.ascii.eqlIgnoreCase(cond[i .. i + 8], "supports") and
            cond[i + 8] == '(' and
            (i == 0 or !css_utils.isIdentChar(cond[i - 1])))
        {
            const open = i + 8;
            const close = css_utils.findMatchingParen(cond, open) orelse return error.SassError;
            const inner = cond[open + 1 .. close];
            const start = firstNonWhitespaceIndex(inner, 0) orelse return error.SassError;
            const inner_trim_left = inner[start..];
            if (std.mem.startsWith(u8, inner_trim_left, "--")) {
                if (css_utils.findDeclarationColon(inner_trim_left)) |colon_idx| {
                    if (colon_idx + 1 >= inner_trim_left.len) return error.SassError;
                }
            }
            i = close + 1;
            continue;
        }
        i += 1;
    }
}

pub fn validateImportConditionText(cond: []const u8) !void {
    const trimmed = std.mem.trim(u8, cond, " \t\n\r");
    if (trimmed.len == 0) return;

    try validateImportSupportsCustomPropertyClauses(trimmed);

    if (findTopLevelComma(trimmed)) |comma_idx| {
        const after_comma = std.mem.trimStart(u8, trimmed[comma_idx + 1 ..], " \t\n\r");
        if (after_comma.len == 0) return error.SassError;
        if (after_comma[0] == '"' or after_comma[0] == '\'') return error.SassError;
        if (std.ascii.startsWithIgnoreCase(after_comma, "url(")) return error.SassError;
        if (startsWithImportFunctionCall(after_comma, "supports")) return error.SassError;
        if (startsWithAnyImportFunctionCall(after_comma)) return error.SassError;
    }

    const first = firstNonWhitespaceIndex(trimmed, 0) orelse return;
    if (trimmed[first] != '(') return;
    const close = css_utils.findMatchingParen(trimmed, first) orelse return error.SassError;
    if (close + 1 >= trimmed.len) return;
    const tail = std.mem.trimStart(u8, trimmed[close + 1 ..], " \t\n\r");
    if (tail.len == 0 or tail[0] == ',') return;
    if (startsWithImportLogicKeyword(tail)) return;
    if (tail[0] == '(' or tail[0] == ')') return;
    if (startsWithImportFunctionCall(tail, "supports")) return error.SassError;
    if (startsWithAnyImportFunctionCall(tail)) return error.SassError;
    if (startsWithImportIdentifier(tail)) return error.SassError;
}

pub fn importConditionStartsOnNewLine(raw: []const u8) bool {
    var saw_newline = false;
    var i: usize = 0;
    while (i < raw.len and std.ascii.isWhitespace(raw[i])) : (i += 1) {
        if (raw[i] == '\n' or raw[i] == '\r') saw_newline = true;
    }
    return saw_newline and i < raw.len;
}

pub fn importConditionHasIdentifierParenLineBreak(raw: []const u8) bool {
    var i: usize = 0;
    var in_string: u8 = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < raw.len) {
                i += 2;
                continue;
            }
            if (c == in_string) in_string = 0;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            i += 1;
            continue;
        }
        if (!isImportIdentStart(c)) {
            i += 1;
            continue;
        }
        const start = i;
        i += 1;
        while (i < raw.len and isImportIdentContinue(raw[i])) : (i += 1) {}
        const ident = raw[start..i];
        var j = i;
        var saw_newline = false;
        while (j < raw.len and std.ascii.isWhitespace(raw[j])) : (j += 1) {
            if (raw[j] == '\n' or raw[j] == '\r') saw_newline = true;
        }
        if (saw_newline and j < raw.len and raw[j] == '(' and
            !cssIdentEquals(ident, "and") and
            !cssIdentEquals(ident, "or") and
            !cssIdentEquals(ident, "not"))
        {
            return true;
        }
    }
    return false;
}
