//! Calc normalization and arithmetic text helpers shared by VM and resolver.

const std = @import("std");
const calculation = @import("../color/calculation.zig");
const expr_scan = @import("expr_scan.zig");
const css_utils = @import("css_utils.zig");

pub const calc_arg_marker = "\x01zsass-calc-arg:";
pub const calc_interp_marker = "\x01zsass-calc-interp:";

pub const calc_interp_preserve_start = "\x01zsass-calc-preserve:";
pub const calc_interp_preserve_end = "\x02";
pub const calc_interp_preserve_slash = '\x03';

pub fn stripCalcArgMarker(text: []const u8) []const u8 {
    if (std.mem.startsWith(u8, text, calc_arg_marker)) return text[calc_arg_marker.len..];
    if (std.mem.startsWith(u8, text, calc_interp_marker)) return text[calc_interp_marker.len..];
    return text;
}

const isDigit = expr_scan.isDigit;
const isIdentStart = expr_scan.isIdentStart;
const isIdentChar = expr_scan.isIdentChar;
const CalcUnitCategory = enum(u4) {
    unknown = 0,
    abs_length = 1,
    rel_length = 2,
    percent = 3,
    angle = 4,
    time = 5,
    frequency = 6,
    resolution = 7,
    unitless = 8,
    other_unit = 9,
};

fn classifyCalcUnit(unit: []const u8) CalcUnitCategory {
    if (unit.len == 0) return .unitless;
    if (std.mem.eql(u8, unit, "%")) return .percent;

    const abs_lengths = [_][]const u8{ "px", "cm", "mm", "in", "pt", "pc", "q", "Q" };
    for (abs_lengths) |l| {
        if (std.mem.eql(u8, unit, l)) return .abs_length;
    }

    const rel_lengths = [_][]const u8{
        "em",    "ex",    "ch",  "rem", "vh",  "vw",  "vmin", "vmax",
        "svw",   "svh",   "lvw", "lvh", "dvw", "dvh", "svi",  "svb",
        "lvi",   "lvb",   "dvi", "dvb", "cqw", "cqh", "cqi",  "cqb",
        "cqmin", "cqmax", "lh",  "rlh", "cap", "ic",
    };
    for (rel_lengths) |l| {
        if (std.mem.eql(u8, unit, l)) return .rel_length;
    }

    if (std.mem.eql(u8, unit, "deg") or std.mem.eql(u8, unit, "grad") or
        std.mem.eql(u8, unit, "rad") or std.mem.eql(u8, unit, "turn"))
        return .angle;
    if (std.mem.eql(u8, unit, "s") or std.mem.eql(u8, unit, "ms"))
        return .time;
    if (std.ascii.eqlIgnoreCase(unit, "hz") or std.ascii.eqlIgnoreCase(unit, "khz"))
        return .frequency;
    if (std.mem.eql(u8, unit, "dpi") or std.mem.eql(u8, unit, "dpcm") or
        std.mem.eql(u8, unit, "dppx") or std.mem.eql(u8, unit, "x"))
        return .resolution;
    return .other_unit;
}

fn areCategoriesKnownIncompatible(cat_a: CalcUnitCategory, cat_b: CalcUnitCategory) bool {
    if (cat_a == cat_b) return false;
    if (cat_a == .unknown or cat_b == .unknown) return false;
    if ((cat_a == .other_unit and cat_b == .unitless) or
        (cat_a == .unitless and cat_b == .other_unit))
        return true;
    if (cat_a == .other_unit or cat_b == .other_unit) return false;
    if (cat_a == .percent or cat_b == .percent) return false;
    if (cat_a == .unitless or cat_b == .unitless) return true;
    if (cat_a == .rel_length and cat_b == .rel_length) return false;
    if ((cat_a == .abs_length and cat_b == .rel_length) or
        (cat_a == .rel_length and cat_b == .abs_length)) return false;
    return true;
}
pub fn calcHasBadWhitespace(expr: []const u8) bool {
    var boundary = std.mem.trim(u8, expr, " \t\n\r");
    while (boundary.len >= 2 and boundary[0] == '/' and boundary[1] == '*') {
        const end_rel = std.mem.indexOf(u8, boundary[2..], "*/") orelse break;
        boundary = std.mem.trim(u8, boundary[end_rel + 4 ..], " \t\n\r");
    }
    while (boundary.len >= 2 and boundary[boundary.len - 2] == '*' and boundary[boundary.len - 1] == '/') {
        const start = std.mem.lastIndexOf(u8, boundary[0 .. boundary.len - 2], "/*") orelse break;
        boundary = std.mem.trim(u8, boundary[0..start], " \t\n\r");
    }

    if (boundary.len > 0) {
        const first = boundary[0];
        if (first == '*' or first == '/') return true;
        if ((first == '+' or first == '-') and boundary.len > 1 and std.ascii.isWhitespace(boundary[1])) return true;
        const last = boundary[boundary.len - 1];
        if (last == '+' or last == '-' or last == '*' or last == '/') return true;
        if (std.mem.find(u8, boundary, "**") != null) return true;
        if (std.mem.find(u8, boundary, "~#{") != null) return true;
    }

    var i: usize = 0;
    var in_string: u8 = 0;
    var interp_depth: u32 = 0;
    var paren_depth: u32 = 0;
    var in_var_name_depth: ?u32 = null;
    while (i < expr.len) : (i += 1) {
        const c = expr[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < expr.len) {
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
        // Track #{...} interpolation blocks - skip their contents
        if (c == '#' and i + 1 < expr.len and expr[i + 1] == '{') {
            interp_depth += 1;
            i += 1; // skip '{'
            continue;
        }
        if (interp_depth > 0) {
            if (c == '{') interp_depth += 1;
            if (c == '}') interp_depth -= 1;
            continue;
        }
        if (c == '(') {
            paren_depth += 1;
            if (in_var_name_depth == null and i >= 3 and std.ascii.eqlIgnoreCase(expr[i - 3 .. i], "var")) {
                const prev = if (i >= 4) expr[i - 4] else 0;
                const prev_is_fn_char = std.ascii.isAlphanumeric(prev) or prev == '-' or prev == '_' or prev == '.' or prev == ':';
                if (i < 4 or !prev_is_fn_char) {
                    in_var_name_depth = paren_depth;
                }
            }
            continue;
        }
        if (c == ',' and in_var_name_depth != null and paren_depth == in_var_name_depth.?) {
            in_var_name_depth = null;
            continue;
        }
        if (c == ')' and paren_depth > 0) {
            if (in_var_name_depth != null and paren_depth == in_var_name_depth.?) {
                in_var_name_depth = null;
            }
            paren_depth -= 1;
            continue;
        }
        if (in_var_name_depth != null and paren_depth == in_var_name_depth.?) {
            continue;
        }
        if (c == '+' or c == '-') {
            if (c == '-') {
                const prev_char = if (i > 0) expr[i - 1] else 0;
                const next_char = if (i + 1 < expr.len) expr[i + 1] else 0;
                const prev_is_ws = prev_char == ' ' or prev_char == '\t' or prev_char == '\n' or prev_char == '\r';
                if (next_char == '-' and (i == 0 or prev_char == '(' or prev_char == ',' or prev_is_ws)) {
                    i += 1;
                    continue;
                }
                if (i > 0 and i + 1 < expr.len and
                    isIdentChar(prev_char) and isIdentChar(next_char) and
                    !isDigit(prev_char) and !isDigit(next_char))
                {
                    continue;
                }
            }
            // Skip if at the very start (unary -/+, e.g., -1px)
            if (i == 0) continue;
            const prev_sig = previousNonWhitespace(expr, i) orelse continue;
            if (prev_sig == '*' or prev_sig == '/' or prev_sig == '+' or prev_sig == '-' or
                prev_sig == '(' or prev_sig == ',')
                continue;
            // Check: must have space before AND after
            const has_space_before = i > 0 and std.ascii.isWhitespace(expr[i - 1]);
            const has_space_after = i + 1 < expr.len and std.ascii.isWhitespace(expr[i + 1]);
            if (!has_space_before or !has_space_after) {
                // But don't flag if it's actually a negative number/constant
                // (e.g., + -1px or + -infinity).
                if (c == '-' and has_space_before and i + 1 < expr.len and
                    (prev_sig == '*' or prev_sig == '/' or prev_sig == '+' or prev_sig == '-' or
                        prev_sig == '(' or prev_sig == ',') and
                    (std.ascii.isDigit(expr[i + 1]) or expr[i + 1] == '.' or isIdentStart(expr[i + 1])))
                    continue;
                return true;
            }
        }
    }
    return false;
}
fn previousNonWhitespace(expr: []const u8, index: usize) ?u8 {
    var i = index;
    while (i > 0) {
        i -= 1;
        if (expr[i] != ' ' and expr[i] != '\t' and expr[i] != '\n' and expr[i] != '\r') {
            return expr[i];
        }
    }
    return null;
}
pub fn replaceAllLiteral(
    allocator: std.mem.Allocator,
    text: []const u8,
    needle: []const u8,
    replacement: []const u8,
) ![]const u8 {
    if (needle.len == 0) return allocator.dupe(u8, text);
    if (std.mem.find(u8, text, needle) == null) return allocator.dupe(u8, text);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var start: usize = 0;
    while (std.mem.findPos(u8, text, start, needle)) |idx| {
        try buf.appendSlice(allocator, text[start..idx]);
        try buf.appendSlice(allocator, replacement);
        start = idx + needle.len;
    }
    try buf.appendSlice(allocator, text[start..]);
    return buf.toOwnedSlice(allocator);
}

pub fn sameSliceStorage(a: []const u8, b: []const u8) bool {
    return a.ptr == b.ptr and a.len == b.len;
}

fn isTopLevelBinaryAdditive(text: []const u8, pos: usize) bool {
    const c = text[pos];
    if (c != '+' and c != '-') return false;

    var prev: ?u8 = null;
    var p = pos;
    while (p > 0) {
        p -= 1;
        const pc = text[p];
        if (pc == ' ' or pc == '\t' or pc == '\n' or pc == '\r') continue;
        prev = pc;
        break;
    }
    if (prev == null) return false;
    if (!calcOperandCanEndWith(prev.?)) return false;

    var n = pos + 1;
    while (n < text.len) : (n += 1) {
        const nc = text[n];
        if (nc == ' ' or nc == '\t' or nc == '\n' or nc == '\r') continue;
        return true;
    }
    return false;
}

fn calcOperandCanEndWith(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '%' or c == ')' or c == '_' or c == '-';
}

fn simplifyCompleteCalcTerm(allocator: std.mem.Allocator, term: []const u8) !?[]const u8 {
    const start = std.mem.indexOfNone(u8, term, " \t\n\r") orelse return null;
    const end = (std.mem.lastIndexOfNone(u8, term, " \t\n\r") orelse return null) + 1;
    var trimmed = term[start..end];
    var leading_binary_op: ?u8 = null;
    var leading_op_end: usize = start;
    if (trimmed.len >= 2 and (trimmed[0] == '+' or trimmed[0] == '-') and
        (trimmed[1] == ' ' or trimmed[1] == '\t' or trimmed[1] == '\n' or trimmed[1] == '\r'))
    {
        leading_binary_op = trimmed[0];
        leading_op_end = start + 1;
        const rhs_start_rel = std.mem.indexOfNone(u8, trimmed[1..], " \t\n\r") orelse return null;
        trimmed = trimmed[1 + rhs_start_rel ..];
    }
    if (trimmed.len == 0) return null;
    if (trimmed[0] == '*' or trimmed[0] == '/' or trimmed[trimmed.len - 1] == '*' or trimmed[trimmed.len - 1] == '/') return null;
    if (!calcExprHasMultiplicativeOp(trimmed)) return null;

    const parsed = calculation.parseCalc(allocator, trimmed) catch return null;
    defer allocator.destroy(parsed);
    defer calculation.freeCalcValue(allocator, parsed);

    const simplified = calculation.simplify(allocator, parsed) catch return null;
    defer allocator.destroy(simplified);
    defer calculation.freeCalcValue(allocator, simplified);

    const css = calculation.toCss(allocator, simplified) catch return null;
    errdefer allocator.free(css);
    if (std.mem.eql(u8, css, trimmed)) {
        allocator.free(css);
        return null;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, term[0..start]);
    if (leading_binary_op) |op| {
        try out.append(allocator, op);
        try out.appendSlice(allocator, term[leading_op_end .. @intFromPtr(trimmed.ptr) - @intFromPtr(term.ptr)]);
    }
    try out.appendSlice(allocator, css);
    try out.appendSlice(allocator, term[end..]);
    allocator.free(css);
    return try out.toOwnedSlice(allocator);
}

/// Normalize the literal (non-`#{...}`) pieces of an interpolated `calc()`
/// argument. Dart Sass still evaluates complete static multiplicative terms
/// around interpolation, e.g. `calc(#{$x} + 4px * 2)` serializes as
/// `calc(8px + 8px)`, while terms whose operand is produced by interpolation
/// such as `calc(#{$x} * 2)` keep their surface form.
pub fn simplifyInterpolatedCalcLiteralChunk(allocator: std.mem.Allocator, text: []const u8) !?[]const u8 {
    if (!calcExprHasMultiplicativeOp(text)) return null;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var changed = false;
    var depth: i32 = 0;
    var in_string: u8 = 0;
    var term_start: usize = 0;
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
        if (depth == 0 and isTopLevelBinaryAdditive(text, i)) {
            const term = text[term_start..i];
            if (try simplifyCompleteCalcTerm(allocator, term)) |simplified| {
                defer allocator.free(simplified);
                try out.appendSlice(allocator, simplified);
                changed = true;
            } else {
                try out.appendSlice(allocator, term);
            }
            try out.append(allocator, c);
            term_start = i + 1;
        }
    }

    const tail = text[term_start..];
    if (try simplifyCompleteCalcTerm(allocator, tail)) |simplified| {
        defer allocator.free(simplified);
        try out.appendSlice(allocator, simplified);
        changed = true;
    } else {
        try out.appendSlice(allocator, tail);
    }

    if (!changed) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSlice(allocator);
}
fn containsSpecialVariableString(args: []const u8) bool {
    var i: usize = 0;
    var in_string: u8 = 0;
    while (i < args.len) {
        const c = args[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < args.len) {
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
        if (c == '/' and i + 1 < args.len and args[i + 1] == '*') {
            i += 2;
            while (i + 1 < args.len) {
                if (args[i] == '*' and args[i + 1] == '/') {
                    i += 2;
                    break;
                }
                i += 1;
            }
            continue;
        }
        if (c == '/' and i + 1 < args.len and args[i + 1] == '/') {
            while (i < args.len and args[i] != '\n') i += 1;
            continue;
        }
        if (!std.ascii.isAlphabetic(c)) {
            i += 1;
            continue;
        }
        if (i > 0 and (std.ascii.isAlphanumeric(args[i - 1]) or args[i - 1] == '-' or args[i - 1] == '_')) {
            i += 1;
            continue;
        }
        if (i + 4 <= args.len and args[i + 3] == '(') {
            const word3 = args[i .. i + 3];
            if (std.ascii.eqlIgnoreCase(word3, "var") or
                std.ascii.eqlIgnoreCase(word3, "env"))
            {
                return true;
            }
        }
        if (i + 5 <= args.len and args[i + 4] == '(') {
            const word4 = args[i .. i + 4];
            if (std.ascii.eqlIgnoreCase(word4, "attr")) {
                return true;
            }
        }
        if (i + 3 <= args.len and args[i + 2] == '(' and
            std.ascii.eqlIgnoreCase(args[i .. i + 2], "if"))
        {
            var if_depth: u32 = 0;
            var j = i + 2;
            while (j < args.len) {
                if (args[j] == '(') if_depth += 1 else if (args[j] == ')') {
                    if (if_depth <= 1) break;
                    if_depth -= 1;
                } else if (args[j] == ':' and if_depth == 1) {
                    return true;
                }
                j += 1;
            }
        }
        i += 1;
    }
    return false;
}

/// Remove unnecessary parentheses in calc() expressions based on operator precedence.
/// CSS calc() follows standard math precedence: * and / bind tighter than + and -.
/// So `a + (b * c)` can be simplified to `a + b * c`, but `a * (b + c)` cannot.
/// Also handles associative cases: `a + (b + c)`  ->  `a + b + c`, `a + (b - c)`  ->  `a + b - c`.
pub fn removeUnnecessaryCalcParens(allocator: std.mem.Allocator, expr: []const u8) ![]const u8 {
    // Scan for parenthesized groups and check if they can be removed
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var i: usize = 0;
    var in_string: u8 = 0;
    while (i < expr.len) {
        const c = expr[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < expr.len) {
                try result.append(allocator, c);
                i += 1;
                try result.append(allocator, expr[i]);
                i += 1;
                continue;
            }
            if (c == in_string) in_string = 0;
            try result.append(allocator, c);
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            try result.append(allocator, c);
            i += 1;
            continue;
        }
        if (c == '(') {
            // Check if this is a function call (preceded by an identifier char)
            const is_func = i > 0 and (std.ascii.isAlphanumeric(expr[i - 1]) or expr[i - 1] == '-' or expr[i - 1] == '_');
            if (is_func) {
                // Function call -- keep parens, copy until matching close
                try result.append(allocator, c);
                i += 1;
                var depth: u32 = 1;
                while (i < expr.len and depth > 0) {
                    if (expr[i] == '(') depth += 1;
                    if (expr[i] == ')') depth -= 1;
                    if (depth > 0) try result.append(allocator, expr[i]);
                    i += 1;
                }
                // Append closing paren
                try result.append(allocator, ')');
                continue;
            }
            // Non-function parens -- find matching close
            var depth: u32 = 1;
            var j = i + 1;
            while (j < expr.len and depth > 0) : (j += 1) {
                if (expr[j] == '(') depth += 1;
                if (expr[j] == ')') depth -= 1;
            }
            const inner = expr[i + 1 .. j - 1];
            // Determine the operator context surrounding this paren group
            const preceding_op = blk: {
                var k: usize = i;
                while (k > 0) {
                    k -= 1;
                    if (std.ascii.isWhitespace(expr[k])) continue;
                    if (expr[k] == '+' or expr[k] == '-' or expr[k] == '*' or expr[k] == '/') {
                        break :blk expr[k];
                    }
                    break;
                }
                break :blk @as(u8, 0); // No preceding operator (start of expression)
            };
            const following_op = blk: {
                var k: usize = j;
                while (k < expr.len) {
                    if (std.ascii.isWhitespace(expr[k])) {
                        k += 1;
                        continue;
                    }
                    if (expr[k] == '+' or expr[k] == '-' or expr[k] == '*' or expr[k] == '/') {
                        break :blk expr[k];
                    }
                    break;
                }
                break :blk @as(u8, 0); // No following operator (end of expression)
            };
            // Check if inner expression has + or - at depth 0
            const inner_has_additive = calcExprHasAdditiveOp(inner);
            // Determine if parens can be removed
            const can_remove = blk: {
                // If there's no operator on either side, the entire expression
                // is wrapped in parens: calc((expr)). Preserve these.
                if (preceding_op == 0 and following_op == 0) {
                    break :blk false;
                }
                if (!inner_has_additive) {
                    // Inner expr has only * / -- but still needed if
                    // preceded by / (a / (b * c) != a / b * c)
                    if (preceding_op == '/') break :blk false;
                    const trimmed_inner = std.mem.trim(u8, inner, " \t\n\r");
                    // Preserve explicit parens around a single calc-like function
                    // call to match Dart Sass serialization for cases like
                    // calc(100vh - (calc(3.5rem + 1px))).
                    if (isSingleCalcLikeFunctionCall(trimmed_inner)) break :blk false;
                    // Preserve parens around bare var()/env() calls
                    if (containsSpecialVariableString(trimmed_inner)) {
                        // Check if inner is just a single function call
                        if (isSingleFunctionCall(trimmed_inner)) break :blk false;
                    }
                    // Dart Sass preserves explicit parens around signed numeric
                    // operands after additive operators: calc(100% + (-4px)).
                    if ((preceding_op == '+' or preceding_op == '-') and isSignedNumberLikeToken(trimmed_inner)) break :blk false;
                    break :blk true;
                }
                // Inner has + or -; check if surrounding context allows removal
                const pre_is_multiplicative = (preceding_op == '*' or preceding_op == '/');
                const fol_is_multiplicative = (following_op == '*' or following_op == '/');
                if (pre_is_multiplicative or fol_is_multiplicative) {
                    // a * (b + c) or (b + c) * a  ->  NOT safe
                    break :blk false;
                }
                if (preceding_op == '-') {
                    // a - (b + c)  ->  NOT safe
                    break :blk false;
                }
                // a + (b + c)  ->  safe
                break :blk true;
            };
            if (can_remove) {
                // Recursively remove parens from trimmed inner content, then append
                // without the wrapper. Surrounding whitespace is insignificant once
                // the parentheses are gone and should not leak into the result.
                const trimmed_inner = std.mem.trim(u8, inner, " \t\n\r");
                const optimized_inner = try removeUnnecessaryCalcParens(allocator, trimmed_inner);
                defer if (optimized_inner.ptr != trimmed_inner.ptr) allocator.free(optimized_inner);
                try result.appendSlice(allocator, optimized_inner);
            } else {
                const has_leading = inner.len > 0 and (inner[0] == ' ' or inner[0] == '\t');
                const has_trailing = inner.len > 0 and (inner[inner.len - 1] == ' ' or inner[inner.len - 1] == '\t');
                const trimmed_inner = if (has_leading and has_trailing)
                    std.mem.trim(u8, inner, " \t\n\r")
                else if (has_leading)
                    std.mem.trimStart(u8, inner, " \t\n\r")
                else
                    inner;
                const optimized_inner = try removeUnnecessaryCalcParens(allocator, trimmed_inner);
                defer if (optimized_inner.ptr != trimmed_inner.ptr) allocator.free(optimized_inner);
                try result.append(allocator, '(');
                try result.appendSlice(allocator, optimized_inner);
                try result.append(allocator, ')');
            }
            i = j;
            continue;
        }
        try result.append(allocator, c);
        i += 1;
    }
    // Only allocate if we changed something
    if (result.items.len == expr.len and std.mem.eql(u8, result.items, expr)) {
        result.deinit(allocator);
        return expr;
    }
    return result.toOwnedSlice(allocator);
}

/// For calc text assembled through interpolation, Dart Sass keeps explicit
/// parentheses around additive groups such as `(0.5rem + 2px)`, but still
/// drops wrappers around purely multiplicative terms like `(30px / 2)`.
pub fn removeNonAdditiveCalcParens(allocator: std.mem.Allocator, expr: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var i: usize = 0;
    var in_string: u8 = 0;
    while (i < expr.len) {
        const c = expr[i];
        if (in_string != 0) {
            try result.append(allocator, c);
            if (c == '\\' and i + 1 < expr.len) {
                i += 1;
                try result.append(allocator, expr[i]);
            } else if (c == in_string) {
                in_string = 0;
            }
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            try result.append(allocator, c);
            i += 1;
            continue;
        }
        if (c != '(') {
            try result.append(allocator, c);
            i += 1;
            continue;
        }

        const is_func = i > 0 and (std.ascii.isAlphanumeric(expr[i - 1]) or expr[i - 1] == '-' or expr[i - 1] == '_');
        if (is_func) {
            try result.append(allocator, c);
            i += 1;
            continue;
        }

        var depth: u32 = 1;
        var j = i + 1;
        while (j < expr.len and depth > 0) : (j += 1) {
            if (expr[j] == '(') depth += 1;
            if (expr[j] == ')') depth -= 1;
        }
        if (depth != 0) {
            try result.append(allocator, c);
            i += 1;
            continue;
        }

        const inner = expr[i + 1 .. j - 1];
        const trimmed_inner = std.mem.trim(u8, inner, " \t\n\r");
        const inner_has_interpolation_preserve = std.mem.indexOf(u8, trimmed_inner, calc_interp_preserve_start) != null;
        const preceding_op = blk: {
            var k = i;
            while (k > 0) {
                k -= 1;
                if (std.ascii.isWhitespace(expr[k])) continue;
                if (expr[k] == '+' or expr[k] == '-' or expr[k] == '*' or expr[k] == '/') break :blk expr[k];
                break;
            }
            break :blk @as(u8, 0);
        };
        const following_op = blk: {
            var k = j;
            while (k < expr.len) : (k += 1) {
                if (std.ascii.isWhitespace(expr[k])) continue;
                if (expr[k] == '+' or expr[k] == '-' or expr[k] == '*' or expr[k] == '/') break :blk expr[k];
                break;
            }
            break :blk @as(u8, 0);
        };
        const inner_has_additive = calcExprHasAdditiveOp(inner);
        const can_remove =
            !inner_has_additive and
            !inner_has_interpolation_preserve and
            !(preceding_op == 0 and following_op == 0) and
            preceding_op != '/' and
            !(preceding_op == '-' and !calcExprHasMultiplicativeOp(inner)) and
            !((preceding_op == '+' or preceding_op == '-') and isSignedNumberLikeToken(trimmed_inner)) and
            !isSingleCalcLikeFunctionCall(trimmed_inner) and
            !(containsSpecialVariableString(trimmed_inner) and isSingleFunctionCall(trimmed_inner));
        if (can_remove) {
            const optimized_inner = try removeNonAdditiveCalcParens(allocator, trimmed_inner);
            defer if (!sameSliceStorage(optimized_inner, trimmed_inner)) allocator.free(optimized_inner);
            try result.appendSlice(allocator, optimized_inner);
        } else {
            const optimized_inner = try removeNonAdditiveCalcParens(allocator, inner);
            defer if (!sameSliceStorage(optimized_inner, inner)) allocator.free(optimized_inner);
            try result.append(allocator, '(');
            try result.appendSlice(allocator, optimized_inner);
            try result.append(allocator, ')');
        }
        i = j;
    }
    if (result.items.len == expr.len and std.mem.eql(u8, result.items, expr)) {
        result.deinit(allocator);
        return expr;
    }
    return result.toOwnedSlice(allocator);
}

fn isSignedNumberLikeToken(expr: []const u8) bool {
    const t = std.mem.trim(u8, expr, " \t\n\r");
    if (t.len < 2 or (t[0] != '-' and t[0] != '+')) return false;
    var i: usize = 1;
    var saw_digit = false;
    while (i < t.len and isDigit(t[i])) : (i += 1) saw_digit = true;
    if (i < t.len and t[i] == '.') {
        i += 1;
        while (i < t.len and isDigit(t[i])) : (i += 1) saw_digit = true;
    }
    if (!saw_digit) return false;
    while (i < t.len and (isIdentChar(t[i]) or t[i] == '%')) : (i += 1) {}
    return i == t.len;
}

/// Check if an expression is a single function call like "var(--c)" or "env(x)".
fn isSingleFunctionCall(expr: []const u8) bool {
    // Find the opening paren
    const paren_pos = std.mem.find(u8, expr, "(") orelse return false;
    if (paren_pos == 0) return false;
    // Check that everything before ( is an identifier
    for (expr[0..paren_pos]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    // Check that the closing paren is at the end
    if (expr[expr.len - 1] != ')') return false;
    // Check that the parens are balanced (matching)
    var depth: u32 = 0;
    for (expr[paren_pos..]) |c| {
        if (c == '(') depth += 1;
        if (c == ')') depth -= 1;
    }
    return depth == 0;
}

fn isSingleCalcLikeFunctionCall(expr: []const u8) bool {
    const paren_pos = std.mem.find(u8, expr, "(") orelse return false;
    if (!isSingleFunctionCall(expr)) return false;
    const name = expr[0..paren_pos];
    return std.ascii.eqlIgnoreCase(name, "calc") or
        std.ascii.eqlIgnoreCase(name, "min") or
        std.ascii.eqlIgnoreCase(name, "max") or
        std.ascii.eqlIgnoreCase(name, "clamp");
}

/// Return true if `c` can terminate an operand (ident/number/closing paren).
fn isOperandTail(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '%' or c == ')' or c == calc_interp_preserve_end[0];
}

fn isCssIdentCharByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '\\' or c >= 0x80;
}

fn isCssIdentStartByte(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '-' or c == '_' or c == '\\' or c >= 0x80;
}

fn startsFunctionAt(expr: []const u8, i: usize, name: []const u8) bool {
    if (i + name.len + 1 > expr.len) return false;
    if (i > 0 and isCssIdentCharByte(expr[i - 1])) return false;
    if (!std.ascii.eqlIgnoreCase(expr[i .. i + name.len], name)) return false;
    return expr[i + name.len] == '(';
}

fn findFunctionClose(expr: []const u8, open_idx: usize) ?usize {
    var depth: u32 = 0;
    var in_str: u8 = 0;
    var i = open_idx;
    while (i < expr.len) : (i += 1) {
        const c = expr[i];
        if (in_str != 0) {
            if (c == '\\' and i + 1 < expr.len) {
                i += 1;
                continue;
            }
            if (c == in_str) in_str = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_str = c;
            continue;
        }
        if (c == '(') {
            depth += 1;
        } else if (c == ')') {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn cssVarOrEnvCallEnd(expr: []const u8, i: usize) ?usize {
    if (startsFunctionAt(expr, i, "var")) return findFunctionClose(expr, i + 3);
    if (startsFunctionAt(expr, i, "env")) return findFunctionClose(expr, i + 3);
    return null;
}

fn normalizeCssSpecialFunctionWhitespace(allocator: std.mem.Allocator, call: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, call, "/*") != null or std.mem.indexOf(u8, call, "//") != null) return call;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, call.len);

    var i: usize = 0;
    var in_string: u8 = 0;
    var pending_ws = false;
    while (i < call.len) {
        const c = call[i];
        if (in_string != 0) {
            if (pending_ws and out.items.len > 0 and out.items[out.items.len - 1] != '(') {
                try out.append(allocator, ' ');
                pending_ws = false;
            }
            try out.append(allocator, c);
            if (c == '\\' and i + 1 < call.len) {
                i += 1;
                try out.append(allocator, call[i]);
            } else if (c == in_string) {
                in_string = 0;
            }
            i += 1;
            continue;
        }

        if (c == '"' or c == '\'') {
            if (pending_ws and out.items.len > 0 and out.items[out.items.len - 1] != '(') {
                try out.append(allocator, ' ');
            }
            pending_ws = false;
            in_string = c;
            try out.append(allocator, c);
            i += 1;
            continue;
        }

        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0c') {
            pending_ws = true;
            i += 1;
            continue;
        }

        if (c == ',') {
            while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
            try out.append(allocator, ',');
            i += 1;
            var j = i;
            while (j < call.len and (call[j] == ' ' or call[j] == '\t' or call[j] == '\n' or call[j] == '\r' or call[j] == '\x0c')) : (j += 1) {}
            if (j < call.len and call[j] != ',' and call[j] != ']' and call[j] != '}') {
                try out.append(allocator, ' ');
            }
            i = j;
            pending_ws = false;
            continue;
        }

        if (c == '(') {
            if (pending_ws and out.items.len > 0 and out.items[out.items.len - 1] != '(') {
                try out.append(allocator, ' ');
            }
            pending_ws = false;
            try out.append(allocator, '(');
            i += 1;
            while (i < call.len and (call[i] == ' ' or call[i] == '\t' or call[i] == '\n' or call[i] == '\r' or call[i] == '\x0c')) : (i += 1) {}
            continue;
        }

        if (c == ')') {
            while (out.items.len > 0 and out.items[out.items.len - 1] == ' ' and
                !(out.items.len >= 2 and out.items[out.items.len - 2] == ','))
            {
                _ = out.pop();
            }
            try out.append(allocator, ')');
            i += 1;
            pending_ws = false;
            continue;
        }

        if (pending_ws and out.items.len > 0 and out.items[out.items.len - 1] != '(') {
            try out.append(allocator, ' ');
        }
        pending_ws = false;
        try out.append(allocator, c);
        i += 1;
    }

    const owned = try out.toOwnedSlice(allocator);
    if (std.mem.eql(u8, owned, call)) {
        allocator.free(owned);
        return call;
    }
    return owned;
}

/// Normalize whitespace around binary operators (+ - * /) inside a calc-like
/// expression. Unary +/- attached to a number or identifier (e.g. `-1px`,
/// after `(`, `,`, or another operator) is preserved without inserting space.
/// Scientific notation `3e-5` / `3e+2` and CSS custom property idents
/// (`--name`) are left intact. Strings/comments are passed through unchanged.
fn normalizeCalcOperatorSpacing(allocator: std.mem.Allocator, expr: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    var in_str: u8 = 0;
    while (i < expr.len) {
        const c = expr[i];
        if (in_str != 0) {
            if (c == '\\' and i + 1 < expr.len) {
                try out.append(allocator, c);
                try out.append(allocator, expr[i + 1]);
                i += 2;
                continue;
            }
            if (c == in_str) in_str = 0;
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_str = c;
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, expr[i..], calc_interp_preserve_start)) {
            const body_start = i + calc_interp_preserve_start.len;
            const end_rel = std.mem.indexOf(u8, expr[body_start..], calc_interp_preserve_end) orelse {
                try out.append(allocator, c);
                i += 1;
                continue;
            };
            const end = body_start + end_rel + calc_interp_preserve_end.len;
            try out.appendSlice(allocator, expr[i..end]);
            i = end;
            continue;
        }
        if (i + 5 <= expr.len and std.ascii.eqlIgnoreCase(expr[i .. i + 4], "calc") and expr[i + 4] == '(') {
            const prev_is_ident = i > 0 and
                (std.ascii.isAlphanumeric(expr[i - 1]) or expr[i - 1] == '-' or expr[i - 1] == '_');
            if (!prev_is_ident) {
                var depth: u32 = 1;
                var j: usize = i + 5;
                var nested_string: u8 = 0;
                while (j < expr.len and depth > 0) : (j += 1) {
                    const b = expr[j];
                    if (nested_string != 0) {
                        if (b == '\\' and j + 1 < expr.len) {
                            j += 1;
                            continue;
                        }
                        if (b == nested_string) nested_string = 0;
                        continue;
                    }
                    if (b == '"' or b == '\'') {
                        nested_string = b;
                        continue;
                    }
                    if (b == '(') depth += 1;
                    if (b == ')') depth -= 1;
                }
                if (depth == 0) {
                    const inner = std.mem.trim(u8, expr[i + 5 .. j - 1], " \t\r\n");
                    const normalized_inner = try normalizeCalcOperatorSpacing(allocator, inner);
                    defer if (!sameSliceStorage(normalized_inner, inner)) allocator.free(normalized_inner);
                    try out.appendSlice(allocator, "calc(");
                    try out.appendSlice(allocator, normalized_inner);
                    try out.append(allocator, ')');
                    i = j;
                    continue;
                }
            }
        }
        // var()/env() arguments are CSS special-function text, not Sass math.
        // In particular, `env(safe-area-inset-bottom)` must not become
        // `env(safe - area - inset - bottom)` when nested in calc().
        if (cssVarOrEnvCallEnd(expr, i)) |end_i| {
            const raw_call = expr[i .. end_i + 1];
            const normalized_call = try normalizeCssSpecialFunctionWhitespace(allocator, raw_call);
            defer if (!sameSliceStorage(normalized_call, raw_call)) allocator.free(normalized_call);
            try out.appendSlice(allocator, normalized_call);
            i = end_i + 1;
            continue;
        }
        // Preserve CSS custom property `--ident`
        if (c == '-' and i + 1 < expr.len and expr[i + 1] == '-') {
            var j = i + 2;
            while (j < expr.len and (std.ascii.isAlphanumeric(expr[j]) or expr[j] == '-' or expr[j] == '_')) : (j += 1) {}
            try out.appendSlice(allocator, expr[i..j]);
            i = j;
            continue;
        }
        // Preserve hyphens that are part of a CSS identifier inside plain
        // calc() text (`calc(flow-space * 2)`). A dimension such as
        // `1px-2px` is still treated as a subtraction boundary because the
        // token before the hyphen starts with a digit.
        if (c == '-' and i > 0 and i + 1 < expr.len and isCssIdentCharByte(expr[i + 1])) {
            var start = i;
            while (start > 0 and isCssIdentCharByte(expr[start - 1])) : (start -= 1) {}
            if (start < i and isCssIdentStartByte(expr[start])) {
                try out.append(allocator, c);
                i += 1;
                continue;
            }
        }
        // Scientific notation: digit 'e' ('+'|'-') digit
        if ((c == '+' or c == '-') and i > 0 and i + 1 < expr.len) {
            const prev = expr[i - 1];
            const next = expr[i + 1];
            if ((prev == 'e' or prev == 'E') and std.ascii.isDigit(next) and i >= 2 and std.ascii.isDigit(expr[i - 2])) {
                try out.append(allocator, c);
                i += 1;
                continue;
            }
        }
        if (c == '+' or c == '-' or c == '*' or c == '/') {
            var is_binary: bool = false;
            var k = out.items.len;
            while (k > 0) {
                k -= 1;
                const b = out.items[k];
                if (std.ascii.isWhitespace(b)) continue;
                is_binary = isOperandTail(b);
                break;
            }
            if (c == '*' or c == '/') is_binary = true;
            if (is_binary) {
                var peek = i + 1;
                while (peek < expr.len and std.ascii.isWhitespace(expr[peek])) peek += 1;
                if (peek >= expr.len or expr[peek] == ')') {
                    try out.append(allocator, c);
                    i += 1;
                    continue;
                }
                if (c == '+' and peek + 1 < expr.len and expr[peek] == '-' and
                    (std.ascii.isDigit(expr[peek + 1]) or expr[peek + 1] == '.'))
                {
                    while (out.items.len > 0 and std.ascii.isWhitespace(out.items[out.items.len - 1])) {
                        _ = out.pop();
                    }
                    try out.appendSlice(allocator, " - ");
                    i = peek + 1;
                    while (i < expr.len and std.ascii.isWhitespace(expr[i])) i += 1;
                    continue;
                }
                while (out.items.len > 0 and std.ascii.isWhitespace(out.items[out.items.len - 1])) {
                    _ = out.pop();
                }
                try out.append(allocator, ' ');
                try out.append(allocator, c);
                i += 1;
                while (i < expr.len and std.ascii.isWhitespace(expr[i])) i += 1;
                try out.append(allocator, ' ');
                continue;
            }
            try out.append(allocator, c);
            i += 1;
            while (i < expr.len and std.ascii.isWhitespace(expr[i])) i += 1;
            continue;
        }
        try out.append(allocator, c);
        i += 1;
    }
    if (out.items.len == expr.len and std.mem.eql(u8, out.items, expr)) {
        out.deinit(allocator);
        return expr;
    }
    return out.toOwnedSlice(allocator);
}

pub fn stripCalcInterpolationPreserveMarkers(allocator: std.mem.Allocator, expr: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, expr, calc_interp_preserve_start) == null) return expr;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, expr.len);
    var i: usize = 0;
    while (i < expr.len) {
        if (std.mem.startsWith(u8, expr[i..], calc_interp_preserve_start)) {
            const body_start = i + calc_interp_preserve_start.len;
            const end_rel = std.mem.indexOf(u8, expr[body_start..], calc_interp_preserve_end) orelse {
                try out.append(allocator, expr[i]);
                i += 1;
                continue;
            };
            const body_end = body_start + end_rel;
            for (expr[body_start..body_end]) |c| {
                try out.append(allocator, if (c == calc_interp_preserve_slash) '/' else c);
            }
            i = body_end + calc_interp_preserve_end.len;
            continue;
        }
        try out.append(allocator, expr[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// Flatten nested calc() calls within a calc expression.
/// calc(1px * calc(2 / var(--c)))  ->  calc(1px * (2 / var(--c)))
/// The inner calc() is replaced with parentheses.
/// Normalize calc() expressions embedded in a plain-CSS decl value.
/// For each top-level `calc(X)` occurrence, flatten nested `calc(Y)`  ->  `(Y)`
/// inside X and remove unnecessary parens, mirroring dart-sass's serialization
/// of calc-only values. Outer calc() wrappers are preserved.
/// Returns the input slice unchanged when no normalization was needed;
/// otherwise returns a newly allocated buffer owned by the caller.
pub fn normalizeCalcInDeclValue(allocator: std.mem.Allocator, expr: []const u8) ![]const u8 {
    return normalizeCalcInDeclValueImpl(allocator, expr, true, false);
}

pub fn normalizeCalcInDeclValueNoFlatten(allocator: std.mem.Allocator, expr: []const u8) ![]const u8 {
    return normalizeCalcInDeclValueImpl(allocator, expr, false, false);
}

pub fn normalizeCalcInDeclValueForMarkedInterpolation(allocator: std.mem.Allocator, expr: []const u8) ![]const u8 {
    return normalizeCalcInDeclValueImpl(allocator, expr, false, true);
}

fn isWholeWrappedParens(expr: []const u8) bool {
    const t = std.mem.trim(u8, expr, " \t\n\r");
    if (t.len < 2 or t[0] != '(' or t[t.len - 1] != ')') return false;
    var depth: u32 = 0;
    var in_string: u8 = 0;
    for (t, 0..) |c, idx| {
        if (in_string != 0) {
            if (c == '\\') continue;
            if (c == in_string) in_string = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            continue;
        }
        if (c == '(') {
            depth += 1;
        } else if (c == ')') {
            if (depth == 0) return false;
            depth -= 1;
            if (depth == 0 and idx != t.len - 1) return false;
        }
    }
    return depth == 0;
}

fn nextTokenIsIeHack(expr: []const u8, idx: usize) bool {
    var k = idx;
    while (k < expr.len and std.ascii.isWhitespace(expr[k])) : (k += 1) {}
    return k + 2 <= expr.len and expr[k] == '\\' and expr[k + 1] == '0';
}

fn normalizeCalcInDeclValueImpl(allocator: std.mem.Allocator, expr: []const u8, flatten: bool, unwrap_interpolated_outer_parens: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    var changed = false;
    while (i < expr.len) {
        const c = expr[i];
        if (c == '"' or c == '\'') {
            const q = c;
            try out.append(allocator, q);
            i += 1;
            while (i < expr.len) {
                if (expr[i] == '\\' and i + 1 < expr.len) {
                    try out.append(allocator, expr[i]);
                    try out.append(allocator, expr[i + 1]);
                    i += 2;
                    continue;
                }
                const b = expr[i];
                try out.append(allocator, b);
                i += 1;
                if (b == q) break;
            }
            continue;
        }
        if (i + 5 <= expr.len and std.mem.eql(u8, expr[i .. i + 5], "calc(")) {
            const prev_is_ident = i > 0 and
                (std.ascii.isAlphanumeric(expr[i - 1]) or expr[i - 1] == '-' or expr[i - 1] == '_');
            if (!prev_is_ident) {
                var depth: u32 = 1;
                var j: usize = i + 5;
                while (j < expr.len and depth > 0) : (j += 1) {
                    if (expr[j] == '(') depth += 1;
                    if (expr[j] == ')') depth -= 1;
                }
                if (depth == 0) {
                    const inner_raw = expr[i + 5 .. j - 1];
                    const inner = std.mem.trim(u8, inner_raw, " \t\n\r");
                    const ie_hack_suffix = nextTokenIsIeHack(expr, j);
                    const inner_wrapped = isWholeWrappedParens(inner);
                    const inner_unwrapped = if (inner_wrapped) std.mem.trim(u8, inner[1 .. inner.len - 1], " \t\n\r") else inner;
                    const unwrap_for_interp = unwrap_interpolated_outer_parens and inner_wrapped and
                        (calcExprHasAdditiveOp(inner_unwrapped) or calcExprHasMultiplicativeOp(inner_unwrapped));
                    const inner_for_norm = if ((ie_hack_suffix and inner_wrapped and calcExprHasAdditiveOp(inner_unwrapped)) or unwrap_for_interp)
                        std.mem.trim(u8, inner[1 .. inner.len - 1], " \t\n\r")
                    else
                        inner;
                    const after_flatten = if (flatten)
                        try flattenNestedCalc(allocator, inner_for_norm)
                    else if (unwrap_interpolated_outer_parens)
                        try flattenNestedCalcForInterpolated(allocator, inner_for_norm)
                    else
                        inner_for_norm;
                    defer if ((flatten or unwrap_interpolated_outer_parens) and !sameSliceStorage(after_flatten, inner_for_norm)) allocator.free(after_flatten);
                    const optimized = if (!flatten and unwrap_interpolated_outer_parens)
                        try removeNonAdditiveCalcParens(allocator, after_flatten)
                    else
                        try removeUnnecessaryCalcParens(allocator, after_flatten);
                    defer if (!sameSliceStorage(optimized, after_flatten)) allocator.free(optimized);
                    const spaced = try normalizeCalcOperatorSpacing(allocator, optimized);
                    defer if (!sameSliceStorage(spaced, optimized)) allocator.free(spaced);
                    const unmarked = try stripCalcInterpolationPreserveMarkers(allocator, spaced);
                    defer if (!sameSliceStorage(unmarked, spaced)) allocator.free(unmarked);
                    try out.appendSlice(allocator, "calc(");
                    try out.appendSlice(allocator, unmarked);
                    try out.append(allocator, ')');
                    if (unmarked.len != inner_raw.len or !std.mem.eql(u8, unmarked, inner_raw)) changed = true;
                    i = j;
                    continue;
                }
            }
        }
        try out.append(allocator, c);
        i += 1;
    }
    if (!changed) {
        out.deinit(allocator);
        return expr;
    }
    return out.toOwnedSlice(allocator);
}

pub fn flattenNestedCalc(allocator: std.mem.Allocator, expr: []const u8) ![]const u8 {
    // Search for "calc(" (not preceded by an identifier char)
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var i: usize = 0;
    var changed = false;
    while (i < expr.len) {
        // Check for "calc(" at current position
        if (i + 5 <= expr.len and std.mem.eql(u8, expr[i .. i + 5], "calc(")) {
            // Make sure it's not part of a larger identifier
            if (i > 0 and (std.ascii.isAlphanumeric(expr[i - 1]) or expr[i - 1] == '-' or expr[i - 1] == '_')) {
                try result.append(allocator, expr[i]);
                i += 1;
                continue;
            }
            // Find matching close paren
            var depth: u32 = 1;
            var j: usize = i + 5;
            while (j < expr.len and depth > 0) : (j += 1) {
                if (expr[j] == '(') depth += 1;
                if (expr[j] == ')') depth -= 1;
            }
            const inner = expr[i + 5 .. j - 1];
            const inner_trimmed = std.mem.trim(u8, inner, " \t\n\r");
            const inner_mult_only = !calcExprHasAdditiveOp(inner_trimmed) and calcExprHasMultiplicativeOp(inner_trimmed);
            if (inner_mult_only) {
                var preceding_op: u8 = 0;
                const preceding = std.mem.trimEnd(u8, result.items, " \t\n\r");
                if (preceding.len > 0) {
                    const last = preceding[preceding.len - 1];
                    if (last == '+' or last == '-' or last == '*' or last == '/') preceding_op = last;
                }
                if (preceding_op == '/') {
                    try result.append(allocator, '(');
                    const flattened_inner = try flattenNestedCalc(allocator, inner);
                    defer if (flattened_inner.ptr != inner.ptr) allocator.free(flattened_inner);
                    try result.appendSlice(allocator, flattened_inner);
                    try result.append(allocator, ')');
                    i = j;
                    changed = true;
                    continue;
                }
                const flattened_inner = try flattenNestedCalc(allocator, inner);
                defer if (flattened_inner.ptr != inner.ptr) allocator.free(flattened_inner);
                try result.appendSlice(allocator, flattened_inner);
                i = j;
                changed = true;
                continue;
            }
            if (calcExprHasAdditiveOp(inner_trimmed)) {
                var preceding_op: u8 = 0;
                const before = std.mem.trimEnd(u8, result.items, " \t\n\r");
                if (before.len > 0) {
                    const ch = before[before.len - 1];
                    if (ch == '+' or ch == '-' or ch == '*' or ch == '/') preceding_op = ch;
                }
                var following_op: u8 = 0;
                var lookahead = j;
                while (lookahead < expr.len and std.ascii.isWhitespace(expr[lookahead])) : (lookahead += 1) {}
                if (lookahead < expr.len) {
                    const ch = expr[lookahead];
                    if (ch == '+' or ch == '-' or ch == '*' or ch == '/') following_op = ch;
                }

                const needs_parens =
                    preceding_op == '*' or preceding_op == '/' or preceding_op == '-' or
                    following_op == '*' or following_op == '/';
                const flattened_inner = try flattenNestedCalc(allocator, inner);
                defer if (flattened_inner.ptr != inner.ptr) allocator.free(flattened_inner);
                if (needs_parens) try result.append(allocator, '(');
                try result.appendSlice(allocator, flattened_inner);
                if (needs_parens) try result.append(allocator, ')');
                i = j;
                changed = true;
                continue;
            }
            try result.append(allocator, '(');
            const flattened_inner = try flattenNestedCalc(allocator, inner);
            defer if (flattened_inner.ptr != inner.ptr) allocator.free(flattened_inner);
            try result.appendSlice(allocator, flattened_inner);
            try result.append(allocator, ')');
            i = j;
            changed = true;
            continue;
        }
        try result.append(allocator, expr[i]);
        i += 1;
    }
    if (!changed) {
        result.deinit(allocator);
        return expr;
    }
    return result.toOwnedSlice(allocator);
}

/// Interpolated-decl variant: only flatten inner calc() to parens when the
/// inner expression has NO top-level binary operators (e.g. `calc(var(--x))`  ->
/// `(var(--x))`).  When the inner expression contains operators (e.g.
/// `calc(0.75em - 1px)`) it is preserved as `calc(...)` because the `calc`
/// keyword came from an interpolated variable and Dart Sass preserves it.
fn flattenNestedCalcForInterpolated(allocator: std.mem.Allocator, expr: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var i: usize = 0;
    var changed = false;
    while (i < expr.len) {
        if (i + 5 <= expr.len and std.mem.eql(u8, expr[i .. i + 5], "calc(")) {
            if (i > 0 and (std.ascii.isAlphanumeric(expr[i - 1]) or expr[i - 1] == '-' or expr[i - 1] == '_')) {
                try result.append(allocator, expr[i]);
                i += 1;
                continue;
            }
            var depth: u32 = 1;
            var j: usize = i + 5;
            while (j < expr.len and depth > 0) : (j += 1) {
                if (expr[j] == '(') depth += 1;
                if (expr[j] == ')') depth -= 1;
            }
            const inner = expr[i + 5 .. j - 1];
            const inner_trimmed = std.mem.trim(u8, inner, " \t\n\r");
            const has_additive = calcExprHasAdditiveOp(inner_trimmed);
            const has_multiplicative = calcExprHasMultiplicativeOp(inner_trimmed);
            const has_css_runtime_value =
                css_utils.containsAsciiIgnoreCase(inner_trimmed, "var(") or
                css_utils.containsAsciiIgnoreCase(inner_trimmed, "env(");
            if (has_additive or (has_multiplicative and has_css_runtime_value)) {
                try result.appendSlice(allocator, expr[i..j]);
                i = j;
                continue;
            }
            if (has_multiplicative) {
                const flattened_inner = try flattenNestedCalcForInterpolated(allocator, inner);
                defer if (!sameSliceStorage(flattened_inner, inner)) allocator.free(flattened_inner);
                try result.appendSlice(allocator, flattened_inner);
            } else {
                try result.append(allocator, '(');
                try result.appendSlice(allocator, inner);
                try result.append(allocator, ')');
            }
            i = j;
            changed = true;
            continue;
        }
        try result.append(allocator, expr[i]);
        i += 1;
    }
    if (!changed) {
        result.deinit(allocator);
        return expr;
    }
    return result.toOwnedSlice(allocator);
}

pub fn normalizeCalcInDeclValueForInterpolated(allocator: std.mem.Allocator, expr: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    var any_changed = false;
    while (i < expr.len) {
        const c = expr[i];
        if (c == '"' or c == '\'') {
            const q = c;
            try out.append(allocator, q);
            i += 1;
            while (i < expr.len) {
                if (expr[i] == '\\' and i + 1 < expr.len) {
                    try out.append(allocator, expr[i]);
                    try out.append(allocator, expr[i + 1]);
                    i += 2;
                    continue;
                }
                const b = expr[i];
                try out.append(allocator, b);
                i += 1;
                if (b == q) break;
            }
            continue;
        }
        if (i + 5 <= expr.len and std.mem.eql(u8, expr[i .. i + 5], "calc(")) {
            const prev_is_ident = i > 0 and
                (std.ascii.isAlphanumeric(expr[i - 1]) or expr[i - 1] == '-' or expr[i - 1] == '_');
            if (!prev_is_ident) {
                var depth: u32 = 1;
                var j: usize = i + 5;
                while (j < expr.len and depth > 0) : (j += 1) {
                    if (expr[j] == '(') depth += 1;
                    if (expr[j] == ')') depth -= 1;
                }
                if (depth == 0) {
                    const inner_raw = expr[i + 5 .. j - 1];
                    const inner = std.mem.trim(u8, inner_raw, " \t\n\r");
                    const after_flatten = try flattenNestedCalcForInterpolated(allocator, inner);
                    defer if (!sameSliceStorage(after_flatten, inner)) allocator.free(after_flatten);
                    const optimized = try removeNonAdditiveCalcParens(allocator, after_flatten);
                    defer if (!sameSliceStorage(optimized, after_flatten)) allocator.free(optimized);
                    const spaced = try normalizeCalcOperatorSpacing(allocator, optimized);
                    defer if (!sameSliceStorage(spaced, optimized)) allocator.free(spaced);
                    try out.appendSlice(allocator, "calc(");
                    try out.appendSlice(allocator, spaced);
                    try out.append(allocator, ')');
                    if (spaced.len != inner_raw.len or !std.mem.eql(u8, spaced, inner_raw)) any_changed = true;
                    i = j;
                    continue;
                }
            }
        }
        try out.append(allocator, c);
        i += 1;
    }
    if (!any_changed) {
        out.deinit(allocator);
        return expr;
    }
    return out.toOwnedSlice(allocator);
}

pub fn calcExprHasAdditiveOp(expr: []const u8) bool {
    var depth: u32 = 0;
    var in_str: u8 = 0;
    var i: usize = 0;
    while (i < expr.len) : (i += 1) {
        const c = expr[i];
        if (in_str != 0) {
            if (c == '\\' and i + 1 < expr.len) {
                i += 1;
                continue;
            }
            if (c == in_str) in_str = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_str = c;
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
        if (depth == 0 and (c == '+' or c == '-') and i > 0 and i + 1 < expr.len and
            expr[i - 1] == ' ' and expr[i + 1] == ' ')
        {
            return true;
        }
    }
    return false;
}

fn calcExprHasMultiplicativeOp(expr: []const u8) bool {
    var depth: u32 = 0;
    var in_str: u8 = 0;
    var i: usize = 0;
    while (i < expr.len) : (i += 1) {
        const c = expr[i];
        if (in_str != 0) {
            if (c == '\\' and i + 1 < expr.len) {
                i += 1;
                continue;
            }
            if (c == in_str) in_str = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_str = c;
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
        if (depth == 0 and (c == '*' or c == '/')) {
            return true;
        }
    }
    return false;
}

pub fn calcHasKnownIncompatibleUnits(expr: []const u8) bool {
    // Collect all terms and the operators between them at depth 0
    // A term is a number+unit token, an operator is + or -
    // We scan for ` + ` and ` - ` patterns at paren depth 0
    var i: usize = 0;
    var depth: u32 = 0;
    var in_string: u8 = 0;
    // Track all unit categories found in terms connected by +/- at depth 0
    var categories: [16]CalcUnitCategory = undefined;
    var cat_count: usize = 0;

    // Parse terms separated by + and - at depth 0
    var term_start: usize = 0;
    while (i < expr.len) {
        const c = expr[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < expr.len) {
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
            if (depth > 0) depth -= 1;
            i += 1;
            continue;
        }
        // Check for ` + ` or ` - ` at depth 0
        if (depth == 0 and (c == '+' or c == '-') and i > 0 and i + 1 < expr.len and
            expr[i - 1] == ' ' and expr[i + 1] == ' ')
        {
            // Found operator at depth 0, extract term before it
            const term = std.mem.trim(u8, expr[term_start..i], " \t\n\r");
            if (term.len > 0) {
                const cat = extractTermUnitCategory(term);
                if (cat_count < categories.len) {
                    categories[cat_count] = cat;
                    cat_count += 1;
                }
            }
            term_start = i + 1;
            i += 2;
            continue;
        }
        i += 1;
    }
    // Last term
    const last_term = std.mem.trim(u8, expr[term_start..], " \t\n\r");
    if (last_term.len > 0) {
        const cat = extractTermUnitCategory(last_term);
        if (cat_count < categories.len) {
            categories[cat_count] = cat;
            cat_count += 1;
        }
    }

    // Check all pairs of categories for known incompatibility
    if (cat_count < 2) return false;
    for (0..cat_count) |a| {
        for (a + 1..cat_count) |b| {
            if (areCategoriesKnownIncompatible(categories[a], categories[b])) {
                return true;
            }
        }
    }
    return false;
}

/// Extract the unit category from a calc term expression.
/// A term can be a simple number+unit (e.g., "1px"), a multiplication/division
/// expression (e.g., "2 * 1px"), or a sub-expression in parens.
fn extractTermUnitCategory(term: []const u8) CalcUnitCategory {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    if (calculation.parseCalc(arena.allocator(), term)) |parsed| {
        if (calculation.simplify(arena.allocator(), parsed)) |simplified| {
            switch (simplified.*) {
                .number => |n| return if (n.unit) |unit| classifyCalcUnit(unit) else .unitless,
                else => {},
            }
        } else |_| {}
    } else |_| {}

    // For parenthesized expressions, skip (we can't easily determine)
    if (term.len > 0 and term[0] == '(') return .unknown;
    // For function calls (e.g., var(--c)), skip
    if (std.mem.find(u8, term, "(") != null) return .unknown;

    // Find the last number+unit in the term (for simple cases like "1px", "-3deg")
    // For multiplication/division terms, the resulting unit depends on the operation,
    // but for simple single-token terms we can extract the unit directly.

    // Scan backwards from end to find unit
    var end = term.len;
    // Skip trailing whitespace
    while (end > 0 and term[end - 1] == ' ') end -= 1;
    if (end == 0) return .unknown;

    // Check if it ends with a unit
    var unit_start = end;
    while (unit_start > 0 and (std.ascii.isAlphabetic(term[unit_start - 1]) or term[unit_start - 1] == '%')) {
        unit_start -= 1;
    }
    if (unit_start == 0) {
        // Bare identifiers such as relative-color channels (`r`, `g`, `b`, `l`, `a`)
        // are not unit tokens. Treat them as unknown so calc() unit compatibility
        // checks remain passthrough.
        return .unknown;
    }
    if (unit_start == end) {
        // No unit suffix -- check if it's a number
        // Could be "1" (unitless) or a variable/keyword
        // Check if the whole term looks numeric
        const trimmed = std.mem.trim(u8, term[0..end], " \t\n\r");
        if (trimmed.len > 0) {
            var is_num = true;
            var j: usize = 0;
            if (j < trimmed.len and (trimmed[j] == '-' or trimmed[j] == '+')) j += 1;
            if (j < trimmed.len and trimmed[j] == '.') j += 1;
            while (j < trimmed.len and (std.ascii.isDigit(trimmed[j]) or trimmed[j] == '.')) : (j += 1) {}
            if (j < trimmed.len and (trimmed[j] == 'e' or trimmed[j] == 'E')) {
                j += 1;
                if (j < trimmed.len and (trimmed[j] == '+' or trimmed[j] == '-')) j += 1;
                while (j < trimmed.len and std.ascii.isDigit(trimmed[j])) : (j += 1) {}
            }
            if (j == trimmed.len and j > 0) return .unitless;
            _ = &is_num;
        }
        return .unknown;
    }

    const unit = term[unit_start..end];
    // Skip keywords that aren't units
    if (std.ascii.eqlIgnoreCase(unit, "infinity") or
        std.ascii.eqlIgnoreCase(unit, "nan") or
        std.ascii.eqlIgnoreCase(unit, "pi") or
        std.ascii.eqlIgnoreCase(unit, "e"))
        return .unknown;

    // Check that the character before the unit is a digit or dot (it's a number+unit)
    if (unit_start > 0) {
        const before = term[unit_start - 1];
        if (!std.ascii.isDigit(before) and before != '.') return .unknown;
    }

    return classifyCalcUnit(unit);
}
