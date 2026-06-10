//! CSS text scanning/escaping helpers shared by resolver, IR, selector, and VM.

const std = @import("std");
const expr_scan = @import("expr_scan.zig");

const isDigit = expr_scan.isDigit;
const tokenStartsWithDoubleHyphenIdentifier = expr_scan.tokenStartsWithDoubleHyphenIdentifier;
const EvalError = anyerror;

/// Strip `/*...*/` comments from a plain-CSS decl value.
/// official Sass CLI drops inline comments inside decl values (non-custom properties).
/// Whitespace around the comment is collapsed: if both sides had whitespace,
/// one is kept; if neither, a single space is inserted to keep tokens apart.
/// Quoted segments are passed through verbatim.
/// Returns the input slice unchanged when no comment is present; otherwise
/// returns a newly allocated buffer owned by the caller.
pub fn stripPlainCssDeclComments(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, raw, "/*") == null) return raw;
    const isOpaqueCssFnName = struct {
        fn f(name: []const u8) bool {
            if (name.len == 0) return false;
            if (name[0] == '-') {
                if (std.mem.findScalarPos(u8, name, 1, '-')) |dash| {
                    const base = name[dash + 1 ..];
                    return std.ascii.eqlIgnoreCase(base, "calc") or
                        std.ascii.eqlIgnoreCase(base, "element") or
                        std.ascii.eqlIgnoreCase(base, "expression");
                }
                return false;
            }
            return std.ascii.eqlIgnoreCase(name, "element") or
                std.ascii.eqlIgnoreCase(name, "expression") or
                std.ascii.eqlIgnoreCase(name, "type") or
                std.ascii.eqlIgnoreCase(name, "url");
        }
    }.f;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, raw.len);
    var i: usize = 0;
    var changed = false;
    var paren_depth: u32 = 0;
    var opaque_active = false;
    var opaque_enter_depth: u32 = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c == '"' or c == '\'') {
            const q = c;
            try out.append(alloc, c);
            i += 1;
            while (i < raw.len) {
                if (raw[i] == '\\' and i + 1 < raw.len) {
                    try out.append(alloc, raw[i]);
                    try out.append(alloc, raw[i + 1]);
                    i += 2;
                    continue;
                }
                const b = raw[i];
                try out.append(alloc, b);
                i += 1;
                if (b == q) break;
            }
            continue;
        }
        if (c == '(') {
            var start = out.items.len;
            while (start > 0 and isIdentChar(out.items[start - 1])) : (start -= 1) {}
            const fn_name = out.items[start..];
            if (!opaque_active) {
                if (fn_name.len > 0 and isOpaqueCssFnName(fn_name)) {
                    opaque_active = true;
                    opaque_enter_depth = paren_depth;
                } else {
                    var k = out.items.len;
                    while (k > 0) {
                        const b = out.items[k - 1];
                        if (isIdentChar(b) or b == '.' or b == ':') {
                            k -= 1;
                        } else break;
                    }
                    const chain = out.items[k..];
                    if (chain.len >= 7 and containsAsciiIgnoreCase(chain, "progid:")) {
                        opaque_active = true;
                        opaque_enter_depth = paren_depth;
                    }
                }
            }
            paren_depth += 1;
            try out.append(alloc, c);
            i += 1;
            continue;
        }
        if (c == ')') {
            if (paren_depth > 0) paren_depth -= 1;
            if (opaque_active and paren_depth <= opaque_enter_depth) {
                opaque_active = false;
            }
            try out.append(alloc, c);
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < raw.len and raw[i + 1] == '*') {
            if (opaque_active) {
                try out.append(alloc, c);
                i += 1;
                continue;
            }
            var j = i + 2;
            while (j + 1 < raw.len and !(raw[j] == '*' and raw[j + 1] == '/')) : (j += 1) {}
            if (j + 1 >= raw.len) {
                try out.appendSlice(alloc, raw[i..]);
                i = raw.len;
                break;
            }
            i = j + 2;
            changed = true;
            const is_ws = struct {
                fn f(b: u8) bool {
                    return b == ' ' or b == '\t' or b == '\n' or b == '\r' or b == '\x0c';
                }
            }.f;
            const prev_is_ws = out.items.len > 0 and is_ws(out.items[out.items.len - 1]);
            const next_is_ws = i < raw.len and is_ws(raw[i]);
            if (prev_is_ws and next_is_ws) {
                i += 1;
            } else if (!prev_is_ws and !next_is_ws and out.items.len > 0 and i < raw.len) {
                try out.append(alloc, ' ');
            }
            continue;
        }
        try out.append(alloc, c);
        i += 1;
    }
    if (!changed) {
        out.deinit(alloc);
        return raw;
    }
    return out.toOwnedSlice(alloc);
}

pub fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var hi: usize = 0;
    while (hi + needle.len <= haystack.len) : (hi += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[hi .. hi + needle.len], needle)) return true;
    }
    return false;
}

pub fn normalizeAttributeSelectors(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.find(u8, text, "[") == null) return text;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var i: usize = 0;
    var in_str: u8 = 0;
    while (i < text.len) {
        if (in_str != 0) {
            try buf.append(allocator, text[i]);
            if (text[i] == '\\' and i + 1 < text.len) {
                i += 1;
                try buf.append(allocator, text[i]);
            } else if (text[i] == in_str) {
                in_str = 0;
            }
            i += 1;
            continue;
        }
        if (text[i] == '"' or text[i] == '\'') {
            in_str = text[i];
            try buf.append(allocator, text[i]);
            i += 1;
            continue;
        }
        if (text[i] == '[') {
            var bend: ?usize = null;
            var depth: u32 = 1;
            var j = i + 1;
            var bq: u8 = 0;
            while (j < text.len and depth > 0) {
                if (bq != 0) {
                    if (text[j] == '\\' and j + 1 < text.len) {
                        j += 1;
                    } else if (text[j] == bq) {
                        bq = 0;
                    }
                } else {
                    if (text[j] == '"' or text[j] == '\'') bq = text[j];
                    if (text[j] == '[') depth += 1;
                    if (text[j] == ']') {
                        depth -= 1;
                        if (depth == 0) {
                            bend = j;
                            break;
                        }
                    }
                }
                j += 1;
            }
            if (bend) |be| {
                const ac = text[i + 1 .. be];
                const norm = try normalizeOneAttr(allocator, ac);
                try buf.append(allocator, '[');
                try buf.appendSlice(allocator, norm);
                if (norm.ptr != ac.ptr) allocator.free(norm);
                try buf.append(allocator, ']');
                i = be + 1;
            } else {
                try buf.append(allocator, text[i]);
                i += 1;
            }
        } else {
            try buf.append(allocator, text[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice(allocator);
}

fn normalizeOneAttr(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var op_end: usize = 0;
    var found_op = false;
    var ci: usize = 0;
    while (ci < content.len) {
        const ch = content[ci];
        if ((ch == '~' or ch == '|' or ch == '^' or ch == '$' or ch == '*') and
            ci + 1 < content.len and content[ci + 1] == '=')
        {
            op_end = ci + 2;
            found_op = true;
            break;
        }
        if (ch == '=') {
            op_end = ci + 1;
            found_op = true;
            break;
        }
        ci += 1;
    }
    if (!found_op) {
        const trimmed = std.mem.trim(u8, content, " \t\r\n");
        if (trimmed.len == 0) return content;
        var seen_ident = false;
        var i: usize = 0;
        while (i < trimmed.len) : (i += 1) {
            if (trimmed[i] == ' ' or trimmed[i] == '\t') {
                if (seen_ident) {
                    while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t')) : (i += 1) {}
                    if (i < trimmed.len) return EvalError.SassError;
                    break;
                }
            } else {
                seen_ident = true;
            }
        }
        return content;
    }
    const after_op = content[op_end..];
    const tr_after = std.mem.trimStart(u8, after_op, " \t\r\n");
    if (tr_after.len == 0) return content;

    var value_text: []const u8 = tr_after;
    var modifier_text: []const u8 = "";
    var value_was_quoted = false;

    if (tr_after[0] == '"' or tr_after[0] == '\'') {
        const quote = tr_after[0];
        var qi: usize = 1;
        while (qi < tr_after.len) {
            if (tr_after[qi] == '\\' and qi + 1 < tr_after.len) {
                qi += 2;
                continue;
            }
            if (tr_after[qi] == quote) break;
            qi += 1;
        }
        if (qi >= tr_after.len) return content;
        value_text = tr_after[1..qi];
        modifier_text = std.mem.trim(u8, tr_after[qi + 1 ..], " \t\r\n");
        value_was_quoted = true;
    } else {
        var value_end: usize = 0;
        while (value_end < tr_after.len and tr_after[value_end] != ' ' and tr_after[value_end] != '\t' and tr_after[value_end] != '\r' and tr_after[value_end] != '\n') : (value_end += 1) {}
        value_text = tr_after[0..value_end];
        modifier_text = std.mem.trim(u8, tr_after[value_end..], " \t\r\n");
    }

    if (modifier_text.len > 0) {
        if (modifier_text.len != 1 or !std.ascii.isAlphabetic(modifier_text[0])) {
            return EvalError.SassError;
        }
    }

    if (!value_was_quoted) {
        if (tr_after.ptr != after_op.ptr and isValidCssIdent(value_text)) {
            var rb: std.ArrayList(u8) = .empty;
            errdefer rb.deinit(allocator);
            try rb.appendSlice(allocator, content[0..op_end]);
            try rb.appendSlice(allocator, value_text);
            if (modifier_text.len > 0) {
                try rb.append(allocator, ' ');
                try rb.appendSlice(allocator, modifier_text);
            }
            return rb.toOwnedSlice(allocator);
        }
        return content;
    }
    const decoded_value = try decodeSimpleQuotedAttributeEscapes(allocator, value_text);
    defer if (decoded_value.ptr != value_text.ptr) allocator.free(decoded_value);
    if (decoded_value.ptr != value_text.ptr and
        std.mem.findScalar(u8, decoded_value, '"') == null and
        std.mem.findScalar(u8, decoded_value, '\\') == null)
    {
        var rb: std.ArrayList(u8) = .empty;
        errdefer rb.deinit(allocator);
        try rb.appendSlice(allocator, content[0..op_end]);
        try rb.append(allocator, '"');
        try rb.appendSlice(allocator, decoded_value);
        try rb.append(allocator, '"');
        if (modifier_text.len > 0) {
            try rb.append(allocator, ' ');
            try rb.appendSlice(allocator, modifier_text);
        }
        return rb.toOwnedSlice(allocator);
    }
    if (std.mem.find(u8, value_text, "--") != null) return content;
    if (!isValidCssIdent(value_text)) return content;

    var rb: std.ArrayList(u8) = .empty;
    errdefer rb.deinit(allocator);
    try rb.appendSlice(allocator, content[0..op_end]);
    try rb.appendSlice(allocator, value_text);
    if (modifier_text.len > 0) {
        try rb.append(allocator, ' ');
        try rb.appendSlice(allocator, modifier_text);
    }
    return rb.toOwnedSlice(allocator);
}

fn isValidCssIdent(text: []const u8) bool {
    if (text.len == 0) return false;
    if (text[0] >= '0' and text[0] <= '9') return false;
    if (text[0] == '-' and text.len == 1) return false;
    if (text[0] == '-' and text.len > 1 and text[1] >= '0' and text[1] <= '9') return false;
    for (text) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c < 0x80) return false;
    }
    return true;
}

fn decodeSimpleQuotedAttributeEscapes(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (std.mem.findScalar(u8, value, '\\') == null) return value;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var changed = false;
    var i: usize = 0;
    while (i < value.len) {
        if (value[i] != '\\' or i + 1 >= value.len) {
            try out.append(allocator, value[i]);
            i += 1;
            continue;
        }

        const next = value[i + 1];
        if (next == '\n' or next == '\r' or next == '"' or next == '\\' or isHexDigit(next)) {
            try out.append(allocator, value[i]);
            try out.append(allocator, next);
            i += 2;
            continue;
        }

        try out.append(allocator, next);
        i += 2;
        changed = true;
    }

    if (!changed) {
        out.deinit(allocator);
        return value;
    }
    return out.toOwnedSlice(allocator);
}

pub fn findMatchingParen(text: []const u8, start: usize) ?usize {
    var depth: u32 = 0;
    var in_string: u8 = 0;
    var interpolation_depth: u32 = 0;
    var i = start;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_string != 0) {
            if (ch == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (ch == '#' and i + 1 < text.len and text[i + 1] == '{') {
                interpolation_depth += 1;
                i += 1;
                continue;
            }
            if (interpolation_depth > 0) {
                if (ch == '{') {
                    interpolation_depth += 1;
                } else if (ch == '}') {
                    interpolation_depth -= 1;
                }
                continue;
            }
            if (ch == in_string) in_string = 0;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            in_string = ch;
            continue;
        }
        if (ch == '\\' and i + 1 < text.len) {
            i += 1;
            continue;
        }
        if (ch == '(') depth += 1;
        if (ch == ')') {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

pub const UrlEvalMode = enum {
    basic,
    structured,
};

fn urlContentHasStructuredEval(content: []const u8) bool {
    if (content.len >= 3 and
        (content[0] == 'i' or content[0] == 'I') and
        (content[1] == 'f' or content[1] == 'F') and
        content[2] == '(') return true;

    var depth: i32 = 0;
    var in_string: u8 = 0;
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        const c = content[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < content.len) {
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
        if (c == '(' or c == '[') {
            depth += 1;
            continue;
        }
        if (c == ')' or c == ']') {
            depth -= 1;
            continue;
        }
        if (c == '+' and depth == 0 and i > 0 and i + 1 < content.len and
            (content[i - 1] == ' ' or content[i - 1] == '\t') and
            (content[i + 1] == ' ' or content[i + 1] == '\t')) return true;
    }
    return false;
}

/// Returns true if the URL content (inside url()) contains Sass expression
/// constructs that should be evaluated.
pub fn urlContentNeedsEval(content: []const u8, mode: UrlEvalMode) bool {
    const t = std.mem.trim(u8, content, " \t\n\r");
    if (t.len == 0) return false;
    switch (mode) {
        .basic => {
            if (std.mem.findScalar(u8, t, '$') != null) return true;
            if (std.mem.find(u8, t, "#{") != null) return true;
        },
        .structured => {},
    }
    if (mode == .structured and textIsFunctionCall(t)) return true;
    return urlContentHasStructuredEval(t);
}

fn textIsFunctionCall(text: []const u8) bool {
    const lparen = std.mem.findScalar(u8, text, '(') orelse return false;
    if (lparen == 0 or text[text.len - 1] != ')') return false;
    if (!isIdentStart(text[0])) return false;
    var i: usize = 1;
    while (i < lparen) : (i += 1) {
        if (!isIdentChar(text[i]) and text[i] != '-') return false;
    }
    var depth: i32 = 0;
    var in_string: u8 = 0;
    i = lparen;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string != 0) {
            if (c == '\\') {
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
            if (depth == 0) return i == text.len - 1;
        }
    }
    return false;
}
pub fn containsArithmeticOp(text: []const u8) bool {
    // Leading unary + on a number literal or with whitespace before ident:
    //   "+10", "+0.5px"  ->  need evaluation (unary + normalizes to the number)
    //   "+ hello"  ->  need evaluation (normalizes "+ hello" to "+hello")
    // Note: "+hello" (no space) is NOT returned true; it's a plain CSS ident prefix,
    // already emitted correctly as "+hello" by evalExpressionString without evaluation.
    if (text.len > 1 and text[0] == '+') {
        // +digit or +. (unary plus on number)
        if (isDigit(text[1]) or text[1] == '.') return true;
        // + whitespace (unary plus with space before ident or number)
        if (text[1] == ' ' or text[1] == '\t') {
            const after = std.mem.trimStart(u8, text[1..], " \t");
            if (after.len > 0 and (isDigit(after[0]) or after[0] == '.' or isIdentStart(after[0]))) {
                return true;
            }
        }
    }
    var depth: i32 = 0;
    var in_string: u8 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string != 0) {
            if (c == '\\') {
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
        if (c == ')') depth -= 1;
        if (depth == 0 and i > 0) {
            // Two-character operators: ==, !=, >=, <=
            if (i + 1 < text.len) {
                const next = text[i + 1];
                if ((c == '=' and next == '=') or
                    (c == '!' and next == '=') or
                    (c == '>' and next == '=') or
                    (c == '<' and next == '='))
                {
                    return true;
                }
            }
            // Single-character comparison: > <
            if (c == '>' or c == '<') return true;
            const prev = text[i - 1];
            const prev_is_ws = (prev == ' ' or prev == '\t' or prev == '\n' or prev == '\r');
            // Arithmetic with whitespace before
            if ((c == '+' or c == '*' or c == '/' or c == '%') and prev_is_ws) return true;
            // Binary + with whitespace only after (e.g. c+ d, 10+ 10)
            if (c == '+' and !prev_is_ws and i + 1 < text.len) {
                const next_c = text[i + 1];
                if (next_c == ' ' or next_c == '\t' or next_c == '\n' or next_c == '\r') {
                    const after = std.mem.trimStart(u8, text[i + 1 ..], " \t\n\r");
                    if (after.len > 0 and
                        (isDigit(after[0]) or after[0] == '.' or after[0] == '$' or after[0] == '(' or
                            after[0] == '"' or after[0] == '\'' or after[0] == '#' or isIdentStart(after[0])))
                    {
                        return true;
                    }
                }
            }
            // * between non-whitespace is always arithmetic (e.g. 1*1/2)
            if (c == '*' and (isDigit(prev) or isIdentChar(prev) or prev == ')' or prev == '%')) return true;
            // / preceded by ) is slash-free division (e.g. (1)/2, func()/2)
            if (c == '/' and prev == ')') return true;
            // / followed by ( is slash-free division (e.g. 1/(2))
            if (c == '/' and i + 1 < text.len and text[i + 1] == '(') return true;
            // / after ident when the expression contains $ (variable division, e.g. -$bwidth/3)
            if (c == '/' and isIdentChar(prev) and std.mem.find(u8, text, "$") != null) return true;
            // / after digit/ident/]/% (unit suffix) followed by space:
            // binary division (e.g., "10/ 20", "10%/ 20")
            // ']' included for CSS grid syntax: [line-name]/ size
            // Note: " and ' are NOT included here -- "quoted"/ "quoted" is a CSS
            // slash pair handled by evalExpressionString's slash pair detection.
            {
                const pct_unit = prev == '%' and i >= 2 and (isDigit(text[i - 2]) or text[i - 2] == ')');
                if (c == '/' and (isDigit(prev) or isIdentChar(prev) or prev == ']' or pct_unit) and i + 1 < text.len and
                    (text[i + 1] == ' ' or text[i + 1] == '\t'))
                {
                    return true;
                }
            }
            // For -, require whitespace on both sides (binary subtraction)
            // or whitespace before and (/$/quote after (unary-looking but parsed as binary).
            // `a -b` remains a space list, while `a -"b"` is subtraction.
            if (c == '-' and prev_is_ws and i + 1 < text.len) {
                const next_c = text[i + 1];
                if (next_c == ' ' or next_c == '\t' or next_c == '\n' or next_c == '\r' or
                    next_c == '(' or next_c == '$' or next_c == '"' or next_c == '\'')
                    return true;
            }
            // + without space: identifier/number adjacency still needs Sass evaluation.
            if (c == '+' and i + 1 < text.len) {
                const next_c = text[i + 1];
                const prev_can_participate = isIdentChar(prev) or isDigit(prev) or prev == ')' or prev == ']' or prev == '%';
                const next_can_participate = isIdentStart(next_c) or isDigit(next_c) or next_c == '.' or next_c == '$' or next_c == '(' or next_c == '"' or next_c == '\'';
                if (prev_can_participate and next_can_participate) return true;
            }
            // - as binary op: when preceded by ) or ident and has something after
            if (c == '-') {
                if (prev == ')' and i + 1 < text.len) return true;
                if (prev_is_ws and i + 1 < text.len and text[i + 1] == '(') return true;
                // ident-( pattern
                if ((isIdentChar(prev) or isDigit(prev) or prev == '%') and i + 1 < text.len) {
                    // Exclude scientific notation exponent (e.g., 5e-2px, 1.5E-3em)
                    // where the '-' is part of the number literal, not a binary op.
                    const is_sci_exp = (prev == 'e' or prev == 'E') and i >= 2 and
                        (isDigit(text[i - 2]) or text[i - 2] == '.');
                    if (!is_sci_exp) {
                        const next_c = text[i + 1];
                        // Space after - with no space before: binary subtraction
                        // (e.g., "2- 3"  ->  subtraction, because unary minus needs
                        // immediate adjacency to operand)
                        if (next_c == ' ' or next_c == '\t' or next_c == '\n' or next_c == '\r') return true;
                        if (next_c == '(' or next_c == '$' or isDigit(next_c) or next_c == '.') {
                            if (isIdentChar(prev) and !isDigit(prev)) {
                                var k: usize = i - 1;
                                while (k > 0) : (k -= 1) {
                                    const ch = text[k];
                                    if (!isIdentChar(ch) and ch != '-') break;
                                }
                                const token_start = if (k == 0 and (isDigit(text[0]) or text[0] == '.' or isIdentChar(text[0]) or text[0] == '-')) 0 else k + 1;
                                if (tokenStartsWithDoubleHyphenIdentifier(text[token_start..i])) continue;
                            }
                            return true;
                        }
                    }
                }
            }
            // Keyword operators: and, or -- match from current position
            if (prev_is_ws) {
                const rest = text[i..];
                if (rest.len >= 4 and (std.mem.startsWith(u8, rest, "and ") or std.mem.startsWith(u8, rest, "and\t"))) return true;
                if (rest.len >= 3 and (std.mem.startsWith(u8, rest, "or ") or std.mem.startsWith(u8, rest, "or\t"))) return true;
            }
        }
    }
    return false;
}

pub fn containsTopLevelSlash(text: []const u8) bool {
    var depth: i32 = 0;
    var in_string: u8 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string != 0) {
            if (c == '\\') {
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
        if (c == ')') depth -= 1;
        if (depth == 0 and c == '/') return true;
    }
    return false;
}
pub fn supportsInnerHasTopLevelAndOr(text: []const u8) bool {
    var depth: i32 = 0;
    var in_string: u8 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < text.len) {
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
        if (c == '(') {
            depth += 1;
            i += 1;
            continue;
        }
        if (c == ')') {
            depth -= 1;
            i += 1;
            continue;
        }
        if (depth == 0) {
            if (text.len >= i + 5 and
                isWhitespaceChar(text[i]) and text[i + 1] == 'a' and text[i + 2] == 'n' and
                text[i + 3] == 'd' and isWhitespaceChar(text[i + 4])) return true;
            if (text.len >= i + 4 and
                isWhitespaceChar(text[i]) and text[i + 1] == 'o' and text[i + 2] == 'r' and
                isWhitespaceChar(text[i + 3])) return true;
        }
        i += 1;
    }
    return false;
}

fn isWhitespaceChar(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

/// Check if a @supports condition inner text starts with "not " (negation).
pub fn supportsInnerStartsWithNot(text: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, text, " \t\n\r");
    return trimmed.len >= 5 and trimmed[0] == 'n' and trimmed[1] == 'o' and trimmed[2] == 't' and isWhitespaceChar(trimmed[3]);
}

/// Unescape Sass string escape sequences.
/// In Sass quoted strings:
/// - \\ -> \ (literal backslash)
/// - \XX (hex digits) -> Unicode character
/// - \<newline> -> line continuation (both consumed)
/// - \n, \t, etc. are NOT special (unlike many languages)
/// If no escapes found, returns the original slice.
pub fn unescapeSassString(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.find(u8, text, "\\") == null) return text;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\\' and i + 1 < text.len) {
            const next = text[i + 1];
            if (next == '\\') {
                // \\ -> single backslash
                try buf.append(allocator, '\\');
                i += 2;
            } else if (next == '"' or next == '\'') {
                try buf.append(allocator, next);
                i += 2;
            } else if (isHexDigit(next)) {
                // Hex escape: \XX -> Unicode character
                const hex_start = i + 1;
                var hex_end = hex_start;
                while (hex_end < text.len and hex_end - hex_start < 6 and isHexDigit(text[hex_end])) {
                    hex_end += 1;
                }
                // Optional trailing whitespace
                var after_hex = hex_end;
                if (after_hex < text.len and (text[after_hex] == ' ' or text[after_hex] == '\t')) {
                    after_hex += 1;
                }
                const hex_str = text[hex_start..hex_end];
                const raw_code_point = std.fmt.parseInt(u21, hex_str, 16) catch {
                    try buf.append(allocator, text[i]);
                    i += 1;
                    continue;
                };
                // U+0000 is replaced with U+FFFD (replacement character) per CSS spec
                const code_point = if (raw_code_point == 0) @as(u21, 0xFFFD) else raw_code_point;
                if (code_point < 0x80) {
                    try buf.append(allocator, @intCast(code_point));
                } else {
                    var utf8_buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(code_point, &utf8_buf) catch {
                        try buf.append(allocator, text[i]);
                        i += 1;
                        continue;
                    };
                    try buf.appendSlice(allocator, utf8_buf[0..len]);
                }
                i = after_hex;
            } else if (next == '\n' or next == 0x0c) {
                // Line continuation: backslash-newline/FF consumed (skip both)
                i += 2;
            } else if (next == '\r') {
                // Line continuation: backslash-CR (optionally followed by LF)
                i += 2;
                if (i < text.len and text[i] == '\n') {
                    i += 1;
                }
            } else {
                // Other non-hex, non-special escapes: produce just the character.
                // e.g., \#  ->  #, \!  ->  !, etc.
                try buf.append(allocator, next);
                i += 2;
            }
        } else {
            try buf.append(allocator, text[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// Unescape Sass identifier escape sequences while preserving control escapes.
pub fn unescapeSassIdentifier(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.find(u8, text, "\\") == null) return text;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '\\') {
            try buf.append(allocator, text[i]);
            i += 1;
            continue;
        }

        // Trailing backslash: preserve as-is.
        if (i + 1 >= text.len) {
            try buf.append(allocator, '\\');
            break;
        }
        i += 1;

        if (isHexDigit(text[i])) {
            var value: u21 = 0;
            var count: u32 = 0;
            while (i < text.len and count < 6 and isHexDigit(text[i])) : (count += 1) {
                value = value * 16 + hexDigitValue(text[i]);
                i += 1;
            }
            if (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r' or text[i] == '\x0c')) {
                i += 1;
            }

            // Identifier contexts preserve control/NUL escapes as escaped text
            // rather than decoding to raw control bytes.
            if (value == 0 or value <= 0x1F or value == 0x7F) {
                try buf.append(allocator, '\\');
                var hex_buf: [6]u8 = undefined;
                const hex = std.fmt.bufPrint(&hex_buf, "{x}", .{value}) catch "0";
                try buf.appendSlice(allocator, hex);
                // Keep one delimiter space so the escape cannot absorb following hex.
                try buf.append(allocator, ' ');
            } else if (value > 0x10FFFF) {
                try buf.appendSlice(allocator, "\xEF\xBF\xBD");
            } else {
                var utf8_buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(@intCast(value), &utf8_buf) catch 0;
                try buf.appendSlice(allocator, utf8_buf[0..len]);
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

        try buf.append(allocator, text[i]);
        i += 1;
    }

    return buf.toOwnedSlice(allocator);
}

pub fn hexDigitValue(c: u8) u21 {
    return switch (c) {
        '0'...'9' => @as(u21, c - '0'),
        'a'...'f' => @as(u21, c - 'a' + 10),
        'A'...'F' => @as(u21, c - 'A' + 10),
        else => 0,
    };
}
pub fn normalizeCssValueEscapes(allocator: std.mem.Allocator, text: []const u8) EvalError![]const u8 {
    // Check if text contains backslash escapes that need normalization.
    const needs_processing = blk: {
        for (text) |ch| {
            if (ch == '\\') break :blk true;
        }
        break :blk false;
    };
    if (!needs_processing) return text;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var in_string: u8 = 0;
    var i: usize = 0;
    var changed = false;

    while (i < text.len) {
        const c = text[i];
        if (in_string != 0) {
            try buf.append(allocator, c);
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                try buf.append(allocator, text[i]);
                i += 1;
                continue;
            }
            if (c == in_string) in_string = 0;
            i += 1;
            continue;
        }

        if (c == '"' or c == '\'') {
            in_string = c;
            try buf.append(allocator, c);
            i += 1;
            continue;
        }

        if (c == '\\') {
            if (i + 1 >= text.len) {
                // A trailing backslash in a raw CSS value commonly comes from an
                // escaped trailing whitespace token (`\ `) after outer trimming.
                // Preserve it as an escaped space instead of emitting `\;`.
                try buf.appendSlice(allocator, "\\ ");
                changed = true;
                break;
            }

            var hex_end = i + 1;
            while (hex_end < text.len and hex_end - (i + 1) < 6 and isHexDigit(text[hex_end])) {
                hex_end += 1;
            }

            if (hex_end > i + 1) {
                const code_point = std.fmt.parseInt(u32, text[i + 1 .. hex_end], 16) catch {
                    return EvalError.SassError;
                };
                if (code_point > 0x10FFFF) return EvalError.SassError;
                changed = true;
                i = hex_end;
                // Skip optional whitespace separator after hex escape
                if (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r' or text[i] == '\x0c')) {
                    i += 1;
                }
                if (code_point == 0x20) {
                    try buf.appendSlice(allocator, "\\ ");
                    continue;
                }
                // Non-printable / control characters (including U+0000): keep as minimal hex escape
                if (code_point <= 0x1F or code_point == 0x7F) {
                    try buf.append(allocator, '\\');
                    // Output minimal lowercase hex
                    var hex_buf: [6]u8 = undefined;
                    const hex_str = std.fmt.bufPrint(&hex_buf, "{x}", .{code_point}) catch "0";
                    try buf.appendSlice(allocator, hex_str);
                    // Always add trailing space (CSS hex escape delimiter)
                    try buf.append(allocator, ' ');
                    // When a quote follows immediately, preserve an additional
                    // space so adjacent token reparsing matches official Sass CLI for
                    // escaped interpolation literals like `\\#{"\\9"}`.
                    if (i < text.len and (text[i] == '"' or text[i] == '\'')) {
                        try buf.append(allocator, ' ');
                    }
                    continue;
                }
                // Printable character: check if it needs escaping based on position
                if (code_point < 0x80) {
                    const ch: u8 = @intCast(code_point);
                    // Digits at identifier start need to stay escaped
                    if (std.ascii.isDigit(ch)) {
                        const prev_is_ident = buf.items.len > 0 and isIdentCharByte(buf.items[buf.items.len - 1]);
                        if (!prev_is_ident) {
                            // At start of identifier: keep as hex escape
                            try buf.append(allocator, '\\');
                            var digit_hex_buf: [6]u8 = undefined;
                            const digit_hex_str = std.fmt.bufPrint(&digit_hex_buf, "{x}", .{code_point}) catch "0";
                            try buf.appendSlice(allocator, digit_hex_str);
                            try buf.append(allocator, ' ');
                            continue;
                        }
                    }
                    // Hyphen at identifier start needs to stay escaped
                    if (ch == '-') {
                        const prev_is_ident = buf.items.len > 0 and isIdentCharByte(buf.items[buf.items.len - 1]);
                        if (!prev_is_ident) {
                            // At start of identifier: keep as escaped hyphen
                            try buf.append(allocator, '\\');
                            try buf.append(allocator, '-');
                            continue;
                        }
                    }
                    if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') {
                        try buf.append(allocator, '\\');
                        try buf.append(allocator, ch);
                        continue;
                    }
                }
                if (isPrivateUseCodePoint(@intCast(code_point))) {
                    // Keep Unicode private-use escapes as hex escapes to avoid
                    // emitting raw control glyphs in unquoted output.
                    try buf.append(allocator, '\\');
                    var private_use_hex_buf: [6]u8 = undefined;
                    const private_use_hex_str = std.fmt.bufPrint(&private_use_hex_buf, "{x}", .{code_point}) catch "0";
                    try buf.appendSlice(allocator, private_use_hex_str);
                    // Preserve separation when the next char is a hex digit.
                    if (i < text.len and isHexDigit(text[i])) {
                        try buf.append(allocator, ' ');
                    }
                    continue;
                }
                // Decode to UTF-8
                var utf8_buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(@intCast(code_point), &utf8_buf) catch return EvalError.SassError;
                try buf.appendSlice(allocator, utf8_buf[0..len]);
                continue;
            }

            // Non-hex escape: \x where x is not a hex digit.
            // If the escaped character is a plain identifier character
            // (letter, digit, hyphen, underscore) that doesn't need escaping,
            // decode it (strip the backslash). Otherwise preserve the escape.
            const next_ch = text[i + 1];
            if (next_ch == '\\') {
                // \\  ->  keep as \\ (escaped backslash)
                try buf.append(allocator, '\\');
                try buf.append(allocator, '\\');
                changed = true;
            } else if (next_ch == '-') {
                // \-  ->  context-dependent: strip if in middle of identifier, keep if at start
                const prev_is_ident = buf.items.len > 0 and isIdentCharByte(buf.items[buf.items.len - 1]);
                if (prev_is_ident) {
                    // In middle of identifier: decode to plain '-'
                    try buf.append(allocator, '-');
                    changed = true;
                } else {
                    // At start of identifier: keep the escape \-
                    try buf.append(allocator, '\\');
                    try buf.append(allocator, '-');
                }
            } else if (next_ch <= 0x1F or next_ch == 0x7F) {
                // Control character (e.g., \<tab>)  ->  normalize to hex escape
                try buf.append(allocator, '\\');
                var ctrl_hex_buf: [6]u8 = undefined;
                const ctrl_hex_str = std.fmt.bufPrint(&ctrl_hex_buf, "{x}", .{@as(u32, next_ch)}) catch "0";
                try buf.appendSlice(allocator, ctrl_hex_str);
                try buf.append(allocator, ' ');
                changed = true;
            } else if (std.ascii.isAlphanumeric(next_ch) or next_ch == '_' or next_ch >= 0x80) {
                // \g, \h, etc.  ->  decode to plain character
                try buf.append(allocator, next_ch);
                changed = true;
            } else {
                // Special characters (\!, \#, etc.)  ->  keep the escape
                try buf.append(allocator, '\\');
                try buf.append(allocator, next_ch);
            }
            i += 2;
            continue;
        }

        try buf.append(allocator, c);
        i += 1;
    }

    if (!changed) {
        buf.deinit(allocator);
        return text;
    }

    return try buf.toOwnedSlice(allocator);
}
pub fn isPrivateUseCodePoint(code_point: u21) bool {
    return (code_point >= 0xE000 and code_point <= 0xF8FF) or
        (code_point >= 0xF0000 and code_point <= 0xFFFFD) or
        (code_point >= 0x100000 and code_point <= 0x10FFFD);
}

/// Normalize only `\-` escapes in an interpolated CSS value result.
/// When `\-` appears in a mid-identifier position (preceded by an ident
/// character), the backslash is stripped because `-` is a valid name-char.
/// At identifier-start position the escape is preserved (`\-foo` stays).
///
/// This is intentionally narrow: full `normalizeCssValueEscapes` would also
/// decode hex escapes like `\ba` that may have originated from interpolation
/// output (e.g. `#{"\\"}#{"baz"}`  ->  `\baz`), which must stay as-is.
/// Non-consuming: when there is no `\-` to rewrite the function returns the
/// input slice unchanged (caller still owns it); when a rewrite is needed it
/// returns a freshly-allocated slice that the caller owns separately. The
/// caller must keep ownership of `text` regardless and may compare `.ptr` to
/// decide whether to free the new allocation.
pub fn normalizeInterpolatedEscapedHyphens(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.find(u8, text, "\\-") == null) return text;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\\' and i + 1 < text.len and text[i + 1] == '-') {
            const prev_is_ident = buf.items.len > 0 and isIdentCharByte(buf.items[buf.items.len - 1]);
            if (prev_is_ident) {
                try buf.append(allocator, '-');
            } else {
                try buf.append(allocator, '\\');
                try buf.append(allocator, '-');
            }
            i += 2;
        } else {
            try buf.append(allocator, text[i]);
            i += 1;
        }
    }
    return try buf.toOwnedSlice(allocator);
}

/// Trim trailing whitespace from a string, but preserve a single trailing space
/// that serves as a hex escape delimiter (e.g., `\9 `  ->  keep the space), or that
/// completes a direct CSS escape (`\ `) when the `\` is not itself escaped.
pub fn trimRightPreservingHexEscape(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0 and (text[end - 1] == ' ' or text[end - 1] == '\t' or text[end - 1] == '\n' or text[end - 1] == '\r')) {
        if (text[end - 1] == ' ' and end >= 2 and text[end - 2] == '\\' and
            !expr_scan.isEscapedCharacter(text, end - 2))
        {
            break;
        }
        end -= 1;
    }
    if (end == text.len) return text; // no trailing whitespace
    // Check if the non-whitespace part ends with a hex escape (`\XXXX`).
    // If so, preserve exactly one trailing space as the hex escape delimiter.
    if (end >= 2) {
        var hex_j = end - 1;
        var hex_count: usize = 0;
        while (hex_count < 6 and isHexDigit(text[hex_j])) {
            hex_count += 1;
            if (hex_j == 0) break;
            hex_j -= 1;
        }
        if (hex_count > 0 and text[hex_j] == '\\') {
            // Trailing space is a hex escape delimiter; preserve one space
            return text[0 .. end + 1];
        }
    }
    return text[0..end];
}

/// Check if text is a CSS unicode-range: U+XXXX, U+XX??, U+XXXX-YYYY
/// Returns the length of the unicode-range token (0 if not a unicode range)
pub fn unicodeRangeLen(text: []const u8) usize {
    if (text.len < 3) return 0;
    if (text[0] != 'U' and text[0] != 'u') return 0;
    if (text[1] != '+') return 0;
    var i: usize = 2;
    // Must start with hex digit or ?
    if (i >= text.len) return 0;
    if (!isHexDigit(text[i]) and text[i] != '?') return 0;
    // Consume hex digits first
    while (i < text.len and isHexDigit(text[i])) : (i += 1) {}
    // Then consume ? (once ? appears, only ? is allowed, no more hex)
    while (i < text.len and text[i] == '?') : (i += 1) {}
    // If we had ?, no range allowed
    const had_question = (i > 2 and text[i - 1] == '?');
    if (had_question) return i;
    // Optional range: -YYYY (only when no ? was used)
    if (i < text.len and text[i] == '-') {
        const dash_pos = i;
        i += 1;
        if (i >= text.len or !isHexDigit(text[i])) return dash_pos;
        while (i < text.len and isHexDigit(text[i])) : (i += 1) {}
    }
    return i;
}
fn isIdentCharByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c >= 0x80;
}

fn stripVendorPrefixFromFunctionName(name: []const u8) []const u8 {
    if (name.len > 1 and name[0] == '-') {
        if (std.mem.find(u8, name[1..], "-")) |dash_pos| {
            return name[dash_pos + 2 ..];
        }
    }
    return name;
}

fn isCssCalculationFunctionName(name: []const u8) bool {
    const stripped = stripVendorPrefixFromFunctionName(name);
    const calc_names = [_][]const u8{ "calc", "min", "max", "clamp", "round" };
    for (calc_names) |cn| {
        if (stripped.len == cn.len and std.ascii.eqlIgnoreCase(stripped, cn)) return true;
    }
    return false;
}

/// Check if a value string contains CSS calculation functions (calc, min, max, clamp)
/// that should not be evaluated as Sass expressions.
pub fn containsCalcFunction(text: []const u8) bool {
    // A calculation function requires `name(`; no parenthesis, no match.
    if (std.mem.findScalar(u8, text, '(') == null) return false;
    var i: usize = 0;
    while (i < text.len) {
        // Skip strings
        if (text[i] == '"' or text[i] == '\'') {
            const quote = text[i];
            i += 1;
            while (i < text.len) {
                if (text[i] == '\\' and i + 1 < text.len) {
                    i += 2;
                    continue;
                }
                if (text[i] == quote) break;
                i += 1;
            }
            if (i < text.len) i += 1;
            continue;
        }
        // Check for function name followed by '('
        if (std.ascii.isAlphabetic(text[i]) or text[i] == '-') {
            const start = i;
            while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '-' or text[i] == '_')) {
                i += 1;
            }
            // Skip whitespace between name and '('
            var j = i;
            while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
            if (j < text.len and text[j] == '(') {
                if (isCssCalculationFunctionName(text[start..i])) return true;
            }
            continue;
        }
        i += 1;
    }
    return false;
}
pub const isIdentStart = expr_scan.isIdentStart;
pub const isIdentChar = expr_scan.isIdentChar;
pub const isEscapedCharacter = expr_scan.isEscapedCharacter;
pub const isHexDigit = expr_scan.isHexDigit;

/// Find the first top-level colon in `text` (not inside parens or strings).
/// Returns the index of the colon, or null if none found.
pub fn findDeclarationColon(text: []const u8) ?usize {
    var depth: i32 = 0;
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
        if (c == '(') depth += 1;
        if (c == ')') depth -= 1;
        if (c == ':' and depth == 0) return i;
    }
    return null;
}

/// Returns true if the CSS if() argument string contains a sass() condition.
/// Scans for `sass(` as a word boundary (not preceded by an identifier char).
pub fn containsSassCondition(args: []const u8) bool {
    var i: usize = 0;
    while (i + 5 <= args.len) : (i += 1) {
        if (std.mem.startsWith(u8, args[i..], "sass(")) {
            if (i > 0 and isIdentChar(args[i - 1])) continue;
            return true;
        }
    }
    return false;
}

test "normalizeAttributeSelectors decodes unnecessary escapes in quoted values" {
    const normalized = try normalizeAttributeSelectors(std.testing.allocator, ".row [class*='\\:col-']");
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings(".row [class*=\":col-\"]", normalized);
}

test "normalizeAttributeSelectors keeps lone hyphen value quoted" {
    const normalized = try normalizeAttributeSelectors(std.testing.allocator, "li[data-task=\"-\"]");
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings("li[data-task=\"-\"]", normalized);
}

test "normalizeAttributeSelectors trims whitespace before unquoted values" {
    const normalized = try normalizeAttributeSelectors(std.testing.allocator, "[data-theme= dark] .x");
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings("[data-theme=dark] .x", normalized);
}
