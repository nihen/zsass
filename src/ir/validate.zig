/// CSS validation functions for plain-CSS passthrough, media queries,
/// @supports, and unicode ranges.
const std = @import("std");
const css_utils = @import("../runtime/css_utils.zig");

const EvalError = anyerror;

const isIdentChar = css_utils.isIdentChar;
const isHexDigit = css_utils.isHexDigit;
const findDeclarationColon = css_utils.findDeclarationColon;
const containsSassCondition = css_utils.containsSassCondition;

/// Scan forward from `start` (one past the opening paren) to find the
/// matching close paren, respecting string literals and nested parens.
/// Returns the index one past the closing ')'.
fn scanMatchingParen(s: []const u8, start: usize) usize {
    var pos = start;
    var depth: u32 = 1;
    var in_str: u8 = 0;
    while (pos < s.len and depth > 0) : (pos += 1) {
        const c = s[pos];
        if (in_str != 0) {
            if (c == '\\' and pos + 1 < s.len) {
                pos += 1;
                continue;
            }
            if (c == in_str) in_str = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_str = c;
            continue;
        }
        if (c == '(') depth += 1;
        if (c == ')') depth -= 1;
    }
    return pos;
}

fn isWhitespace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

/// Returns true if the given function name is Sass-only (not valid in plain CSS).
/// Sass spec: only these built-in functions are allowed in plain CSS mode.
/// All other known Sass built-in functions are rejected.
/// Unknown/CSS-native functions (calc, var, env, min, max, clamp, etc.)
/// are allowed since they are valid CSS.
fn isCssAllowedBuiltinFunction(name: []const u8) bool {
    const allowed = comptime std.StaticStringMap(void).initComptime(.{
        .{ "rgb", {} },       .{ "rgba", {} },
        .{ "hsl", {} },       .{ "hsla", {} },
        .{ "grayscale", {} }, .{ "invert", {} },
        .{ "alpha", {} },     .{ "opacity", {} },
        .{ "saturate", {} },  .{ "if", {} },
    });
    return allowed.has(name);
}

/// Returns true if `name` is a known Sass built-in function (not a CSS function).
fn isKnownSassBuiltinFunction(name: []const u8) bool {
    const sass_funcs = comptime std.StaticStringMap(void).initComptime(.{
        // Color
        .{ "red", {} },             .{ "green", {} },            .{ "blue", {} },
        .{ "hue", {} },             .{ "saturation", {} },       .{ "lightness", {} },
        .{ "alpha", {} },           .{ "opacity", {} },          .{ "adjust-hue", {} },
        .{ "darken", {} },          .{ "lighten", {} },          .{ "saturate", {} },
        .{ "desaturate", {} },      .{ "opacify", {} },          .{ "fade-in", {} },
        .{ "transparentize", {} },  .{ "fade-out", {} },         .{ "mix", {} },
        .{ "complement", {} },      .{ "grayscale", {} },        .{ "invert", {} },
        .{ "adjust-color", {} },    .{ "scale-color", {} },      .{ "change-color", {} },
        .{ "ie-hex-str", {} },      .{ "blackness", {} },        .{ "whiteness", {} },
        .{ "rgb", {} },             .{ "rgba", {} },             .{ "hsl", {} },
        .{ "hsla", {} },            .{ "hwb", {} },
        // List
                     .{ "index", {} },
        .{ "length", {} },          .{ "nth", {} },              .{ "set-nth", {} },
        .{ "append", {} },          .{ "join", {} },             .{ "zip", {} },
        .{ "list-separator", {} },  .{ "is-bracketed", {} },
        // String
            .{ "quote", {} },
        .{ "unquote", {} },         .{ "str-length", {} },       .{ "str-insert", {} },
        .{ "str-index", {} },       .{ "str-slice", {} },        .{ "to-upper-case", {} },
        .{ "to-lower-case", {} },   .{ "unique-id", {} },
        // Type/inspection
               .{ "type-of", {} },
        .{ "unit", {} },            .{ "unitless", {} },         .{ "comparable", {} },
        .{ "inspect", {} },
        // Selector
                .{ "is-superselector", {} }, .{ "simple-selectors", {} },
        // Map
        .{ "map-get", {} },         .{ "map-merge", {} },        .{ "map-remove", {} },
        .{ "map-keys", {} },        .{ "map-values", {} },       .{ "map-has-key", {} },
        // Math
        .{ "percentage", {} },      .{ "random", {} },           .{ "abs", {} },
        .{ "ceil", {} },            .{ "floor", {} },            .{ "round", {} },
        // Meta
        .{ "feature-exists", {} },  .{ "variable-exists", {} },  .{ "global-variable-exists", {} },
        .{ "function-exists", {} }, .{ "mixin-exists", {} },     .{ "content-exists", {} },
        .{ "call", {} },            .{ "get-function", {} },
        // if()
            .{ "if", {} },
    });
    return sass_funcs.has(name);
}

/// Returns true if `name` is a Sass built-in function not allowed in plain CSS.
fn isSassOnlyFunction(name: []const u8) bool {
    return isKnownSassBuiltinFunction(name) and !isCssAllowedBuiltinFunction(name);
}

// ---------------------------------------------------------------------------
// Plain CSS value validation
// ---------------------------------------------------------------------------

/// Validate a property value in a plain CSS passthrough context.
/// Returns SassError if Sass-specific syntax is detected.
///
/// Detects:
/// - Parent selector & in value
/// - Sass spread operator (...)
/// - Sass variables ($foo)
/// - Namespace function calls (ns.func())
/// - Sass-only functions (index(), length(), etc.)
/// - sass() conditions inside CSS if()
/// - Parentheses used as Sass lists (not function calls)
/// - Sass binary operators (y + z, y * z, y == z, etc.)
pub fn validatePlainCssValue(val: []const u8) EvalError!void {
    const s = std.mem.trim(u8, val, " \t\n\r");
    if (s.len == 0) return;

    // Parent selector & in value
    if (std.mem.findScalar(u8, s, '&') != null) {
        return EvalError.SassError;
    }

    // Sass spread operator: "..."
    if (std.mem.find(u8, s, "...") != null) {
        return EvalError.SassError;
    }

    var si: usize = 0;
    var in_str: u8 = 0;
    var paren_depth: u32 = 0;
    while (si < s.len) {
        const c = s[si];
        // Inside a string: skip until closing quote
        if (in_str != 0) {
            if (c == '\\' and si + 1 < s.len) {
                si += 2;
                continue;
            }
            if (c == in_str) in_str = 0;
            si += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_str = c;
            si += 1;
            continue;
        }

        // Check parentheses BEFORE incrementing depth so we can inspect the function name.
        if (c == '(') {
            // At any depth: detect "ns.func(" (namespace function call)
            {
                var fe = si;
                while (fe > 0 and (s[fe - 1] == ' ' or s[fe - 1] == '\t')) : (fe -= 1) {}
                var fs = fe;
                while (fs > 0 and isIdentChar(s[fs - 1])) : (fs -= 1) {}
                if (fs > 0 and s[fs - 1] == '.') {
                    return EvalError.SassError;
                }
            }
            if (paren_depth == 0) {
                // Top-level parens must be a function call
                if (si == 0) {
                    return EvalError.SassError;
                }
                var func_end = si;
                while (func_end > 0 and (s[func_end - 1] == ' ' or s[func_end - 1] == '\t')) : (func_end -= 1) {}
                var func_start = func_end;
                while (func_start > 0 and isIdentChar(s[func_start - 1])) : (func_start -= 1) {}
                const func_name = s[func_start..func_end];
                const prev_nonws: u8 = if (func_end > 0) s[func_end - 1] else 0;
                if (prev_nonws == 0 or
                    (!isIdentChar(prev_nonws) and prev_nonws != ')'))
                {
                    return EvalError.SassError;
                }
                // Sass-only function names are not allowed in plain CSS
                if (isSassOnlyFunction(func_name)) {
                    return EvalError.SassError;
                }
                if (std.ascii.eqlIgnoreCase(func_name, "var")) {
                    const args_end = scanMatchingParen(s, si + 1);
                    try validatePlainCssVarArgs(s[si + 1 .. args_end - 1]);
                }
                // For CSS if(), detect sass() conditions inside the argument list
                if (std.ascii.eqlIgnoreCase(func_name, "if")) {
                    const args_end = scanMatchingParen(s, si + 1);
                    const if_args = s[si + 1 .. args_end - 1];
                    // CSS if() has a colon at depth 0 separating condition from value
                    var has_colon_depth0 = false;
                    {
                        var cd: u32 = 0;
                        var ci2: usize = 0;
                        while (ci2 < if_args.len) : (ci2 += 1) {
                            const ac = if_args[ci2];
                            if (ac == '(') {
                                cd += 1;
                                continue;
                            }
                            if (ac == ')') {
                                if (cd > 0) cd -= 1;
                                continue;
                            }
                            if (ac == ':' and cd == 0) {
                                has_colon_depth0 = true;
                                break;
                            }
                        }
                    }
                    if (has_colon_depth0 and containsSassCondition(if_args)) {
                        return EvalError.SassError;
                    }
                }
                // Math functions with empty args are invalid in plain CSS
                if (si + 1 < s.len and s[si + 1] == ')') {
                    if (std.ascii.eqlIgnoreCase(func_name, "calc") or
                        std.ascii.eqlIgnoreCase(func_name, "min") or
                        std.ascii.eqlIgnoreCase(func_name, "max") or
                        std.ascii.eqlIgnoreCase(func_name, "clamp"))
                    {
                        return EvalError.SassError;
                    }
                }
            }
            paren_depth += 1;
            si += 1;
            continue;
        }
        if (c == ')') {
            if (paren_depth > 0) paren_depth -= 1;
            si += 1;
            continue;
        }

        if (c == '$') {
            return EvalError.SassError;
        }

        // Only check operators at top level (paren_depth == 0)
        if (paren_depth == 0) {
            if ((c == '+' or c == '-' or c == '*' or c == '%') and
                si > 0 and si + 1 < s.len)
            {
                const prev = s[si - 1];
                const next = s[si + 1];
                if ((prev == ' ' or prev == '\t') and (next == ' ' or next == '\t')) {
                    return EvalError.SassError;
                }
            }
            if ((c == '<' or c == '>') and si > 0) {
                const prev = s[si - 1];
                if (prev == ' ' or prev == '\t') {
                    return EvalError.SassError;
                }
            }
            if (c == '=' and si > 0 and si + 1 < s.len) {
                const prev = s[si - 1];
                const next = s[si + 1];
                if (next == '=' and (prev == ' ' or prev == '\t')) {
                    return EvalError.SassError;
                }
                if (si >= 1 and prev == '!' and si >= 2) {
                    const pprev = s[si - 2];
                    if (pprev == ' ' or pprev == '\t') {
                        return EvalError.SassError;
                    }
                }
            }
        }

        si += 1;
    }
}

fn validatePlainCssVarArgs(args: []const u8) EvalError!void {
    var first_comma: ?usize = null;
    var depth: u32 = 0;
    var in_string: u8 = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const c = args[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < args.len) {
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
        if ((c == ')' or c == ']') and depth > 0) {
            depth -= 1;
            continue;
        }
        if (c == ',' and depth == 0) {
            first_comma = i;
            break;
        }
    }

    if (first_comma) |comma_pos| {
        const prop_name = std.mem.trim(u8, args[0..comma_pos], " \t\n\r");
        if (prop_name.len == 0) return EvalError.SassError;

        const fallback = std.mem.trim(u8, args[comma_pos + 1 ..], " \t\n\r");
        if (fallback.len == 0) return;
        if (fallback[0] == ',') return EvalError.SassError;

        depth = 0;
        in_string = 0;
        i = 0;
        while (i < fallback.len) : (i += 1) {
            const c = fallback[i];
            if (in_string != 0) {
                if (c == '\\' and i + 1 < fallback.len) {
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
            if ((c == ')' or c == ']') and depth > 0) {
                depth -= 1;
                continue;
            }
            if (depth == 0 and (c == '{' or c == '}')) return EvalError.SassError;
        }
    }
}

fn selectorCharIsEscaped(sel: []const u8, idx: usize) bool {
    if (idx == 0 or idx >= sel.len) return false;
    var backslash_count: usize = 0;
    var cursor = idx;
    while (cursor > 0) {
        cursor -= 1;
        if (sel[cursor] != '\\') break;
        backslash_count += 1;
    }
    return (backslash_count & 1) == 1;
}

/// Validate a CSS selector in a plain CSS passthrough context.
/// Returns SassError if any SCSS-specific syntax is detected.
/// is_top_level: true if the selector is at the top level of the CSS file.
/// Leading combinators are only errors at the top level.
pub fn validatePlainCssSelector(sel: []const u8, is_top_level: bool) EvalError!void {
    const s = std.mem.trim(u8, sel, " \t\n\r");
    if (s.len == 0) return;

    // Interpolation is not allowed in plain CSS selectors.
    if (std.mem.find(u8, s, "#{") != null) {
        return EvalError.SassError;
    }

    // Placeholder selectors (%foo) are not allowed in plain CSS.
    // Check each comma-separated part.
    var part_start: usize = 0;
    while (part_start < s.len) {
        var part_end = part_start;
        while (part_end < s.len and s[part_end] != ',') : (part_end += 1) {}
        const part = std.mem.trim(u8, s[part_start..part_end], " \t\n\r");
        if (part.len > 0 and part[0] == '%') {
            return EvalError.SassError;
        }
        // Leading combinator at top level only: selector starts with >, ~, +
        if (is_top_level and part.len > 0 and (part[0] == '>' or part[0] == '~' or part[0] == '+')) {
            return EvalError.SassError;
        }
        part_start = part_end + 1;
    }

    // Check for "nested property" pattern: selector contains a colon that is
    // followed by a space (not part of a pseudo-class like `:hover`).
    //This catches both `x: {` (colon at end  ->  selector = "x:") and
    //`b: c {` (colon with space  ->  selector = "b: c").
    // In valid CSS, pseudo-classes have `:identifier` with no space after colon.
    {
        var ci: usize = 0;
        while (ci < s.len) {
            if (s[ci] == ':') {
                //Colon at end  ->  nested property
                if (ci + 1 >= s.len) {
                    return EvalError.SassError;
                }
                // Colon followed by space or another colon (::pseudo-element is ok,
                // but `: ` is a nested property indicator)
                if (s[ci + 1] == ' ' or s[ci + 1] == '\t') {
                    return EvalError.SassError;
                }
            }
            ci += 1;
        }
    }

    // Check for trailing combinator: selector ends with >, ~, + (possibly
    // preceded by whitespace). This is `a > ` before `{`.
    const last_non_ws = blk: {
        var i = s.len;
        while (i > 0) {
            i -= 1;
            if (s[i] != ' ' and s[i] != '\t' and s[i] != '\n' and s[i] != '\r') {
                break :blk s[i];
            }
        }
        break :blk @as(u8, 0);
    };
    if (last_non_ws == '>' or last_non_ws == '~' or last_non_ws == '+') {
        return EvalError.SassError;
    }

    // Parent selector with suffix: `&foo` (& followed by non-whitespace/non-special)
    // This is an SCSS-specific extension not allowed in plain CSS.
    var si: usize = 0;
    while (si < s.len) {
        if (s[si] == '&') {
            if (selectorCharIsEscaped(s, si)) {
                si += 1;
                continue;
            }
            si += 1;
            // Skip over whitespace
            while (si < s.len and (s[si] == ' ' or s[si] == '\t')) : (si += 1) {}
            // If followed by a non-{ non-space non-end char, it's a suffix
            if (si < s.len and s[si] != '{' and s[si] != ',' and s[si] != ' ' and
                s[si] != '\t' and s[si] != '\n' and s[si] != '\r' and
                s[si] != ':' and s[si] != '.' and s[si] != '#' and
                s[si] != '[' and s[si] != '>' and s[si] != '~' and s[si] != '+')
            {
                return EvalError.SassError;
            }
            continue;
        }
        si += 1;
    }
}

test "validate: plain css selector allows escaped ampersand literal" {
    try validatePlainCssSelector(".\\[\\.histoire-story-list-folder-button\\:hover_\\&\\]\\:htw-opacity-100", true);
}

// ---------------------------------------------------------------------------
// Media query validation
// ---------------------------------------------------------------------------

/// Validate a single parenthesized media feature for range syntax errors.
/// Checks:
/// - More than 2 comparison operators (invalid triple-range)
/// - Mismatched direction (e.g., (1px > width < 2px))
/// - Spaced operators like "< =" (should be "<=")
fn validateMediaRangeFeature(inner: []const u8) EvalError!void {
    const s = std.mem.trim(u8, inner, " \t\r\n");
    if (s.len == 0) return;

    // Count comparison operators at top level (not inside nested parens)
    const Op = enum { lt, lte, gt, gte, eq };
    var ops: [4]Op = undefined;
    var op_count: usize = 0;
    var i: usize = 0;
    var depth: u32 = 0;
    var saw_comparison = false;

    while (i < s.len) {
        if (s[i] == '(') {
            depth += 1;
            i += 1;
            continue;
        }
        if (s[i] == ')') {
            if (depth > 0) depth -= 1;
            i += 1;
            continue;
        }
        if (depth > 0) {
            i += 1;
            continue;
        }

        if (s[i] == ':' and saw_comparison) {
            return EvalError.SassError;
        }

        // Check for spaced operator: "< =" or "> ="
        if ((s[i] == '<' or s[i] == '>') and i + 2 < s.len) {
            const next = std.mem.trimStart(u8, s[i + 1 ..], " \t");
            if (next.len > 0 and next[0] == '=' and
                (s[i + 1] == ' ' or s[i + 1] == '\t'))
            {
                return EvalError.SassError;
            }
        }

        var op: ?Op = null;
        if (s[i] == '<') {
            if (i + 1 < s.len and s[i + 1] == '=') {
                op = .lte;
                i += 2;
            } else {
                op = .lt;
                i += 1;
            }
        } else if (s[i] == '>') {
            if (i + 1 < s.len and s[i + 1] == '=') {
                op = .gte;
                i += 2;
            } else {
                op = .gt;
                i += 1;
            }
        } else if (s[i] == '=') {
            op = .eq;
            i += 1;
        } else {
            i += 1;
            continue;
        }

        if (op) |o| {
            if (op_count >= 4) return EvalError.SassError;
            ops[op_count] = o;
            op_count += 1;
            saw_comparison = true;
        }
    }

    // More than 2 comparison operators is invalid
    if (op_count > 2) return EvalError.SassError;

    // 2 operators: check they are in the same direction (both < family or both > family)
    if (op_count == 2) {
        const is_lt = ops[0] == .lt or ops[0] == .lte;
        const is_gt = ops[0] == .gt or ops[0] == .gte;
        const second_lt = ops[1] == .lt or ops[1] == .lte;
        const second_gt = ops[1] == .gt or ops[1] == .gte;
        // Both must be in the same direction (or second is eq which is error anyway)
        if (is_lt and !second_lt) return EvalError.SassError;
        if (is_gt and !second_gt) return EvalError.SassError;
        // eq = eq is also invalid (two = operators)
        if (ops[0] == .eq or ops[1] == .eq) return EvalError.SassError;
    }
}

/// Validate @media query prelude for invalid syntax patterns.
/// Called after normalization (lowercase keywords, whitespace collapse).
pub fn validateMediaQueryPrelude(prelude: []const u8, had_interpolation: bool) EvalError!void {
    const t = std.mem.trim(u8, prelude, " \t\n\r");
    if (t.len == 0) return;

    // Check for missing space: not(, and(, or( without space between keyword and paren
    var vi: usize = 0;
    while (vi < t.len) {
        if (t[vi] == '"' or t[vi] == '\'') {
            const q = t[vi];
            vi += 1;
            while (vi < t.len and t[vi] != q) : (vi += 1) {
                if (t[vi] == '\\') vi += 1;
            }
            vi += 1;
            continue;
        }
        if (t[vi] == '(') {
            // Find the matching closing paren
            var depth: u32 = 1;
            const paren_start = vi;
            vi += 1;
            while (vi < t.len and depth > 0) : (vi += 1) {
                if (t[vi] == '(') depth += 1 else if (t[vi] == ')') depth -= 1;
            }
            // Validate the content of this paren group as a potential
            // range-format media feature (e.g., (value < ident < value))
            if (paren_start + 1 < vi and vi <= t.len) {
                const paren_inner = t[paren_start + 1 .. vi - 1];
                try validateMediaRangeFeature(paren_inner);
            }
            continue;
        }
        const before_ok = vi == 0 or !isIdentChar(t[vi - 1]);
        if (before_ok) {
            if (vi + 4 <= t.len and
                t[vi] == 'n' and t[vi + 1] == 'o' and t[vi + 2] == 't' and t[vi + 3] == '(')
            {
                return EvalError.SassError;
            }
            if (vi + 4 <= t.len and
                t[vi] == 'a' and t[vi + 1] == 'n' and t[vi + 2] == 'd' and t[vi + 3] == '(')
            {
                return EvalError.SassError;
            }
            if (vi + 3 <= t.len and
                t[vi] == 'o' and t[vi + 1] == 'r' and t[vi + 2] == '(')
            {
                return EvalError.SassError;
            }
        }
        vi += 1;
    }
    try validateMediaQueryLogic(t, had_interpolation);
}

fn skipParenGroupMedia(text: []const u8) []const u8 {
    if (text.len == 0) return text;
    if (text[0] != '(') {
        var j: usize = 0;
        while (j < text.len and text[j] != ' ' and text[j] != '\t' and
            text[j] != '(' and text[j] != ')') : (j += 1)
        {}
        return text[j..];
    }
    var depth: u32 = 1;
    var idx: usize = 1;
    while (idx < text.len and depth > 0) : (idx += 1) {
        if (text[idx] == '(') depth += 1 else if (text[idx] == ')') depth -= 1;
    }
    return text[idx..];
}

/// Validate @media query logic: detect and/or mixing, trailing keywords, etc.
/// had_interpolation: true when the prelude contained #{...} interpolation.
fn validateMediaQueryLogic(t: []const u8, had_interpolation: bool) EvalError!void {
    const s = std.mem.trim(u8, t, " \t\n\r");
    if (s.len == 0) return;

    // Split by top-level commas and validate each media query independently.
    // Media query lists are comma-separated, and each query is independent
    // (e.g., "@media screen and (foo: 1), not print" has two queries).
    {
        var start: usize = 0;
        var depth: u32 = 0;
        var in_string: u8 = 0;
        var ci: usize = 0;
        while (ci < s.len) : (ci += 1) {
            const ch = s[ci];
            if (in_string != 0) {
                if (ch == '\\' and ci + 1 < s.len) {
                    ci += 1;
                    continue;
                }
                if (ch == in_string) in_string = 0;
                continue;
            }
            if (ch == '"' or ch == '\'') {
                in_string = ch;
                continue;
            }
            if (ch == '(') {
                depth += 1;
                continue;
            }
            if (ch == ')' and depth > 0) {
                depth -= 1;
                continue;
            }
            if (ch == ',' and depth == 0) {
                const part = std.mem.trim(u8, s[start..ci], " \t\n\r");
                if (part.len > 0) {
                    try validateSingleMediaQuery(part, had_interpolation);
                }
                start = ci + 1;
            }
        }
        // Validate last part
        const last = std.mem.trim(u8, s[start..], " \t\n\r");
        if (last.len > 0) {
            try validateSingleMediaQuery(last, had_interpolation);
        }
        return;
    }
}

fn validateSingleMediaQuery(t: []const u8, had_interpolation: bool) EvalError!void {
    const s = std.mem.trim(u8, t, " \t\n\r");
    if (s.len == 0) return;

    // Standalone "not" without anything - invalid (e.g. @media not {...})
    if (s.len == 3 and s[0] == 'n' and s[1] == 'o' and s[2] == 't') {
        return EvalError.SassError;
    }

    var pos: usize = 0;
    var found_and: bool = false;
    var found_or: bool = false;
    var has_type_query: bool = false;
    //Whether we just consumed a "not (cond)" -- any following and/or is invalid.
    var after_not_cond: bool = false;
    // Whether the immediately preceding token was from interpolation.
    // "or" after interpolation is disallowed in Sass.
    // True when had_interpolation and the query starts with a paren (the interp result).
    var prev_was_interp: bool = had_interpolation and (s.len > 0 and s[0] == '(');

    const first_tok = std.mem.trimStart(u8, s, " \t");
    if (first_tok.len > 0 and first_tok[0] != '(') {
        has_type_query = true;
    }

    pos = 0;
    while (pos < s.len) {
        if (s[pos] == ' ' or s[pos] == '\t') {
            pos += 1;
            continue;
        }
        if (s[pos] == '(') {
            const rest_slice = skipParenGroupMedia(s[pos..]);
            pos = s.len - rest_slice.len;
            after_not_cond = false;
            // When the paren group is the result of an interpolation (prev_was_interp),
            // keep the flag so that "or"/"and" after it is detected as an error.
            // Otherwise clear the flag.
            if (!prev_was_interp) {
                prev_was_interp = false;
            }
            // Note: prev_was_interp stays true until consumed by or/and check
            continue;
        }
        const rem = s[pos..];
        if (rem.len >= 3 and rem[0] == 'a' and rem[1] == 'n' and rem[2] == 'd' and
            (rem.len == 3 or rem[3] == ' ' or rem[3] == '(' or rem[3] == '{'))
        {
            const after = if (rem.len > 3) std.mem.trimStart(u8, rem[3..], " \t") else "";
            if (after.len == 0) return EvalError.SassError;
            if (found_or) return EvalError.SassError;
            // "and" after "not (cond)" is not valid
            if (after_not_cond) return EvalError.SassError;
            found_and = true;
            after_not_cond = false;
            prev_was_interp = false;
            pos += 3;
            continue;
        }
        if (rem.len >= 2 and rem[0] == 'o' and rem[1] == 'r' and
            (rem.len == 2 or rem[2] == ' ' or rem[2] == '(' or rem[2] == '{'))
        {
            const after = if (rem.len > 2) std.mem.trimStart(u8, rem[2..], " \t") else "";
            if (after.len == 0) return EvalError.SassError;
            if (found_and) return EvalError.SassError;
            if (has_type_query) return EvalError.SassError;
            // "or" after interpolation is not allowed
            if (prev_was_interp) return EvalError.SassError;
            // "or" after "not (cond)" is not valid
            if (after_not_cond) return EvalError.SassError;
            found_or = true;
            after_not_cond = false;
            prev_was_interp = false;
            pos += 2;
            continue;
        }
        if (rem.len >= 3 and rem[0] == 'n' and rem[1] == 'o' and rem[2] == 't' and
            (rem.len == 3 or rem[3] == ' ' or rem[3] == '{'))
        {
            // "not" after "and" is valid: "a and not (b)"
            // "not" after "or" is NOT valid (Sass restriction)
            if (found_or) return EvalError.SassError;
            // Check what follows "not":
            // - If followed by ( then it's "not (...)" - valid
            // - If followed by a word then it's "not media-type" which is valid at top level
            //   (e.g. "not print") but not after "and"
            const after_nt = if (rem.len > 3) std.mem.trimStart(u8, rem[3..], " \t") else "";
            if (after_nt.len == 0) return EvalError.SassError; // trailing "not"
            if (after_nt[0] != '(' and found_and) return EvalError.SassError;
            // If "not (cond)" pattern: consume the paren group now so the
            // subsequent paren-handling code does not reset after_not_cond.
            if (after_nt.len > 0 and after_nt[0] == '(') {
                const paren_rest = skipParenGroupMedia(after_nt);
                const after_cond = std.mem.trimStart(u8, paren_rest, " \t");
                if (after_cond.len > 0 and after_cond[0] != '{') {
                    after_not_cond = true;
                }
                // Advance pos past "not" and the paren group
                // after_nt starts at rem[3..] trimmed, so compute its offset in s
                const after_nt_start = pos + 3 + (rem[3..].len - after_nt.len);
                // paren_rest is after the paren group in after_nt
                const consumed = after_nt.len - paren_rest.len;
                pos = after_nt_start + consumed;
            } else {
                pos += 3;
            }
            prev_was_interp = false;
            continue;
        }
        after_not_cond = false;
        prev_was_interp = false;
        while (pos < s.len and s[pos] != ' ' and s[pos] != '\t' and
            s[pos] != '(' and s[pos] != ')')
        {
            pos += 1;
        }
    }
}

// ---------------------------------------------------------------------------
// @supports validation
// ---------------------------------------------------------------------------

/// Validate @supports prelude for invalid syntax.
pub fn validateSupportsPrelude(prelude: []const u8) EvalError!void {
    const t = std.mem.trim(u8, prelude, " \t\n\r");
    if (t.len == 0) return EvalError.SassError;

    if (t[0] == '(') {
        try validateSupportsConditionList(t);
        return;
    }

    // "not " - valid start if followed by ( group or function call
    if (t.len >= 4 and t[0] == 'n' and t[1] == 'o' and t[2] == 't' and t[3] == ' ') {
        const after = std.mem.trimStart(u8, t[4..], " \t");
        if (after.len == 0) return EvalError.SassError;
        if (after[0] == '(') {
            // "not" takes exactly one condition - no trailing and/or
            var not_depth: u32 = 1;
            var not_idx: usize = 1;
            while (not_idx < after.len and not_depth > 0) : (not_idx += 1) {
                if (after[not_idx] == '(') not_depth += 1 else if (after[not_idx] == ')') not_depth -= 1;
            }
            const not_rest = std.mem.trim(u8, after[not_idx..], " \t\n\r");
            if (not_rest.len > 0) return EvalError.SassError;
            try validateSupportsParenCondition(after[0..not_idx]);
            return;
        }
        // "not ident(...)" - function call form
        var not_ident_end: usize = 0;
        while (not_ident_end < after.len and (isIdentChar(after[not_ident_end]) or after[not_ident_end] == '-')) : (not_ident_end += 1) {}
        if (not_ident_end > 0 and not_ident_end < after.len and after[not_ident_end] == '(') {
            return;
        }
        return EvalError.SassError;
    }

    // "not(" without space - invalid
    if (t.len >= 4 and t[0] == 'n' and t[1] == 'o' and t[2] == 't' and t[3] == '(') {
        return EvalError.SassError;
    }

    // Could be a function call: ident(...)
    var ident_end: usize = 0;
    while (ident_end < t.len and (isIdentChar(t[ident_end]) or t[ident_end] == '-')) : (ident_end += 1) {}
    if (ident_end > 0 and ident_end < t.len and t[ident_end] == '(') {
        return;
    }

    return EvalError.SassError;
}

/// Validate the content inside a @supports paren group.
fn validateSupportsParenCondition(text: []const u8) EvalError!void {
    if (text.len < 2 or text[0] != '(' or text[text.len - 1] != ')') return EvalError.SassError;
    const inner_raw = text[1 .. text.len - 1];
    const inner = std.mem.trim(u8, inner_raw, " \t\n\r");
    if (inner.len == 0) return EvalError.SassError;

    if (inner[0] == '(') {
        try validateSupportsConditionList(inner);
        return;
    }

    // "not " inside parens
    if (inner.len >= 4 and inner[0] == 'n' and inner[1] == 'o' and inner[2] == 't' and inner[3] == ' ') {
        const after_not = std.mem.trimStart(u8, inner[4..], " \t");
        if (after_not.len == 0 or after_not[0] != '(') {
            return EvalError.SassError;
        }
        return;
    }

    // "not(" without space - invalid
    if (inner.len >= 4 and inner[0] == 'n' and inner[1] == 'o' and inner[2] == 't' and inner[3] == '(') {
        return EvalError.SassError;
    }

    // Declaration conditions need a syntactically valid property/value pair.
    // This intentionally allows dynamic property names like `(1 + 1: b)` while
    // still rejecting malformed forms such as `(a !:$)` and `(--a:)`.
    if (findDeclarationColon(inner_raw) != null) {
        try validateSupportsDeclarationText(inner_raw);
        return;
    }

    // CSS @supports accepts "general-enclosed" which is any non-empty content
    // in parens, EXCEPT content that starts with a digit (not a valid identifier).
    if (std.ascii.isDigit(inner[0])) {
        return EvalError.SassError;
    }
}

fn validateSupportsDeclarationText(inner: []const u8) EvalError!void {
    const colon_pos = findDeclarationColon(inner) orelse return EvalError.SassError;
    const prop = std.mem.trim(u8, inner[0..colon_pos], " \t\n\r");
    const value_raw = inner[colon_pos + 1 ..];

    if (prop.len == 0) return EvalError.SassError;

    const is_custom = prop.len >= 2 and prop[0] == '-' and prop[1] == '-';
    if (is_custom) {
        if (value_raw.len == 0) return EvalError.SassError;
        return;
    }

    for (prop) |c| {
        if (isWhitespace(c)) return EvalError.SassError;
    }

    const value = std.mem.trim(u8, value_raw, " \t\n\r");
    if (value.len == 0) return EvalError.SassError;
}

/// Validate a @supports condition list.
fn validateSupportsConditionList(t: []const u8) EvalError!void {
    return validateSupportsConditionListOp(t, 0); // 0 = no operator seen yet
}

fn validateSupportsConditionListOp(t: []const u8, prev_op: u8) EvalError!void {
    const s = std.mem.trim(u8, t, " \t\n\r");
    if (s.len == 0) return EvalError.SassError;

    if (s[0] != '(') {
        var ident_end: usize = 0;
        while (ident_end < s.len and isIdentChar(s[ident_end])) : (ident_end += 1) {}
        if (ident_end == 0 or ident_end >= s.len or s[ident_end] != '(') {
            return EvalError.SassError;
        }
        return;
    }

    var depth: u32 = 1;
    var idx: usize = 1;
    while (idx < s.len and depth > 0) : (idx += 1) {
        if (s[idx] == '(') depth += 1 else if (s[idx] == ')') depth -= 1;
    }
    if (depth != 0) return EvalError.SassError;

    try validateSupportsParenCondition(s[0..idx]);

    const rest = std.mem.trim(u8, s[idx..], " \t\n\r");
    if (rest.len == 0) return;

    if (rest.len >= 4 and rest[0] == 'a' and rest[1] == 'n' and rest[2] == 'd' and isWhitespace(rest[3])) {
        if (prev_op == 'r') return EvalError.SassError; // or before and
        const rest_after = std.mem.trimStart(u8, rest[4..], " \t\n\r");
        if (rest_after.len >= 4 and rest_after[0] == 'n' and rest_after[1] == 'o' and
            rest_after[2] == 't' and rest_after[3] == '(')
        {
            return EvalError.SassError;
        }
        try validateSupportsConditionListOp(rest_after, 'a');
        return;
    }
    if (rest.len >= 3 and rest[0] == 'o' and rest[1] == 'r' and isWhitespace(rest[2])) {
        if (prev_op == 'a') return EvalError.SassError; // and before or
        const rest_after = std.mem.trimStart(u8, rest[3..], " \t\n\r");
        try validateSupportsConditionListOp(rest_after, 'r');
        return;
    }

    return EvalError.SassError;
}

// ---------------------------------------------------------------------------
// Unicode range validation
// ---------------------------------------------------------------------------

/// Validate a unicode range token (U+XXXX, U+XXXX-YYYY, U+XX??).
pub fn validateUnicodeRange(text: []const u8) EvalError!void {
    if (text.len < 3) return EvalError.SassError;
    if (text[0] != 'U' and text[0] != 'u') return EvalError.SassError;
    if (text[1] != '+') return EvalError.SassError;

    var uri: usize = 2;
    if (uri >= text.len) return EvalError.SassError;
    if (!isHexDigit(text[uri]) and text[uri] != '?') return EvalError.SassError;

    var hex_count: usize = 0;
    while (uri < text.len and isHexDigit(text[uri])) : (uri += 1) {
        hex_count += 1;
    }
    var q_count: usize = 0;
    while (uri < text.len and text[uri] == '?') : (uri += 1) {
        q_count += 1;
    }
    const total_first = hex_count + q_count;
    if (total_first > 6) return EvalError.SassError;
    if (total_first == 0) return EvalError.SassError;

    if (uri >= text.len) return;

    if (q_count > 0) {
        return EvalError.SassError;
    }

    if (text[uri] != '-') return EvalError.SassError;
    uri += 1;

    if (uri >= text.len or !isHexDigit(text[uri])) return EvalError.SassError;

    var hex2_count: usize = 0;
    while (uri < text.len and isHexDigit(text[uri])) : (uri += 1) {
        hex2_count += 1;
    }
    if (hex2_count > 6) return EvalError.SassError;

    if (uri < text.len) return EvalError.SassError;
}
