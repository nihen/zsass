//! Value  ->  format helper for CSS strings. `formatNumberCore` / which was duplicated in vm.zig and builtin.zig
//! Unify `formatNumberCoreCss`.
//!
//! official Sass CLI number output rule:
//! - Integer value is `{d}` as is (up to about 1e18)
//! - Output decimals with 10-digit precision and drop trailing zero (`1.500000`  ->  `1.5`)
//! - `.5` / `-.5` pad leading zero (`0.5` / `-0.5`)
//! - `-0` is normalized to `0`

const std = @import("std");
const color_mod = @import("../color/color.zig");
const perf = @import("perf.zig");

fn roundToSignificantDigits(value: f64, digits: u8) f64 {
    if (!std.math.isFinite(value) or value == 0 or digits == 0) return value;
    const magnitude = @floor(@log10(@abs(value)));
    const scale_exp = @as(f64, @floatFromInt(digits - 1)) - magnitude;
    const scale = std.math.pow(f64, 10.0, scale_exp);
    if (!std.math.isFinite(scale) or scale == 0) return value;
    return @round(value * scale) / scale;
}

fn normalizeLargeInteger(val: f64) ?f64 {
    if (!std.math.isFinite(val) or @abs(val) < 1e15 or @abs(val) > 1e40) return null;
    const rounded = roundToSignificantDigits(val, 10);
    if (rounded != @floor(rounded)) return null;
    const rel_err = @abs(val - rounded) / @abs(rounded);
    if (rel_err > 1e-12) return null;
    return rounded;
}

fn formatNormalizedLargeInteger(alloc: std.mem.Allocator, val: f64) std.mem.Allocator.Error!?[]u8 {
    const normalized = normalizeLargeInteger(val) orelse return null;

    var sci_buf: [64]u8 = undefined;
    const sci = std.fmt.bufPrint(&sci_buf, "{e:.9}", .{normalized}) catch return null;
    const e_idx = std.mem.findScalar(u8, sci, 'e') orelse return null;
    const mantissa = sci[0..e_idx];
    const exponent = std.fmt.parseInt(i32, sci[e_idx + 1 ..], 10) catch return null;

    var digits: [32]u8 = undefined;
    var digits_len: usize = 0;
    var frac_digits: i32 = 0;
    var seen_dot = false;

    for (mantissa) |c| {
        if (c == '-') continue;
        if (c == '.') {
            seen_dot = true;
            continue;
        }
        digits[digits_len] = c;
        digits_len += 1;
        if (seen_dot) frac_digits += 1;
    }

    const zeros_to_append = exponent - frac_digits;
    if (zeros_to_append < 0) return null;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);

    if (mantissa.len > 0 and mantissa[0] == '-') try out.append(alloc, '-');
    try out.appendSlice(alloc, digits[0..digits_len]);
    var i: i32 = 0;
    while (i < zeros_to_append) : (i += 1) {
        try out.append(alloc, '0');
    }
    return @as(?[]u8, try out.toOwnedSlice(alloc));
}

fn formatDegenerateWithUnit(
    alloc: std.mem.Allocator,
    keyword: []const u8,
    unit: ?[]const u8,
) std.mem.Allocator.Error![]u8 {
    if (unit) |u| {
        if (u.len != 0) return std.fmt.allocPrint(alloc, "calc({s} * 1{s})", .{ keyword, u });
    }
    return std.fmt.allocPrint(alloc, "calc({s})", .{keyword});
}

/// Return value comes from `alloc`, caller is `alloc.free`.
pub fn formatNumberCore(alloc: std.mem.Allocator, v: f64) std.mem.Allocator.Error![]u8 {
    perf.note(.format_number);
    if (std.math.isNan(v)) return alloc.dupe(u8, "calc(NaN)");
    if (std.math.isInf(v)) return alloc.dupe(u8, if (v < 0) "calc(-infinity)" else "calc(infinity)");
    if (v == 0) return alloc.dupe(u8, "0");

    if (try formatNormalizedLargeInteger(alloc, v)) |normalized| return normalized;

    const t = @trunc(v);
    if (v == t and @abs(v) < 1e20 and v >= -9223372036854775808.0 and v <= 9223372036854775807.0) {
        var int_buf: [32]u8 = undefined;
        const int_text = std.fmt.bufPrint(&int_buf, "{d}", .{@as(i64, @intFromFloat(t))}) catch {
            return try std.fmt.allocPrint(alloc, "{d}", .{@as(i64, @intFromFloat(t))});
        };
        return try alloc.dupe(u8, int_text);
    }

    var fixed_buf: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&fixed_buf, "{d:.10}", .{v}) catch blk: {
        break :blk try std.fmt.allocPrint(alloc, "{d:.10}", .{v});
    };
    const must_free_s = @intFromPtr(s.ptr) != @intFromPtr(&fixed_buf[0]);
    defer if (must_free_s) alloc.free(s);

    var end: usize = s.len;
    while (end > 0 and s[end - 1] == '0') end -= 1;
    if (end > 0 and s[end - 1] == '.') end -= 1;
    const out = s[0..end];
    if (std.mem.eql(u8, out, "-0")) return try alloc.dupe(u8, "0");
    if (std.mem.startsWith(u8, out, "-.")) {
        var prefixed = try alloc.alloc(u8, out.len + 1);
        prefixed[0] = '-';
        prefixed[1] = '0';
        @memcpy(prefixed[2..], out[1..]);
        return prefixed;
    }
    if (std.mem.startsWith(u8, out, ".")) {
        var prefixed = try alloc.alloc(u8, out.len + 1);
        prefixed[0] = '0';
        @memcpy(prefixed[1..], out);
        return prefixed;
    }
    return try alloc.dupe(u8, out);
}

fn isDigitByte(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn asciiSliceEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[i])) return false;
    }
    return true;
}

fn hasDotDigitCandidate(input: []const u8) bool {
    if (input.len < 2) return false;
    var i: usize = 0;
    while (i + 1 < input.len) : (i += 1) {
        if (input[i] == '.' and isDigitByte(input[i + 1])) return true;
    }
    return false;
}

fn hasMathFunctionCallCandidate(input: []const u8) bool {
    const math_names = [_][]const u8{
        "calc",  "min",   "max",   "clamp",
        "mod",   "rem",   "round", "abs",
        "sign",  "hypot", "sqrt",  "pow",
        "log",   "exp",   "sin",   "cos",
        "tan",   "asin",  "acos",  "atan",
        "atan2",
    };

    var i: usize = 0;
    while (i + 1 < input.len) : (i += 1) {
        if (input[i] != '(') continue;
        if (i == 0) continue;
        var name_start = i;
        while (name_start > 0) {
            const prev = input[name_start - 1];
            if (std.ascii.isAlphanumeric(prev) or prev == '-' or prev == '_') {
                name_start -= 1;
            } else break;
        }
        if (name_start == i) continue;
        if (name_start > 0) {
            const prev = input[name_start - 1];
            if (std.ascii.isAlphanumeric(prev) or prev == '-' or prev == '_' or prev >= 0x80 or prev == '\\') continue;
        }
        const ident = input[name_start..i];
        for (math_names) |name| {
            if (asciiSliceEqlIgnoreCase(ident, name)) return true;
        }
    }
    return false;
}

/// Fill in leading zero in token units of CSS value. `.5`  ->  `0.5`, `-.5`  ->  `-0.5`,
/// Normalize the decimal shorthand in decl value to be compatible with official Sass CLI, like `all .2s`  ->  `all 0.2s`.
/// Do not touch the contents of quoted string (`content: "foo .5"`). Parts of identifier (`.foo`, `a.5`) are also not touched.
/// Return value comes from `alloc`, caller is `alloc.free`. If the input does not need to be changed, dupe the input and return it as is.
pub fn normalizeLeadingZeros(alloc: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, input.len);

    var in_double_quote = false;
    var in_single_quote = false;
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (in_double_quote) {
            try out.append(alloc, c);
            if (c == '\\' and i + 1 < input.len) {
                try out.append(alloc, input[i + 1]);
                i += 2;
                continue;
            }
            if (c == '"') in_double_quote = false;
            i += 1;
            continue;
        }
        if (in_single_quote) {
            try out.append(alloc, c);
            if (c == '\\' and i + 1 < input.len) {
                try out.append(alloc, input[i + 1]);
                i += 2;
                continue;
            }
            if (c == '\'') in_single_quote = false;
            i += 1;
            continue;
        }
        if (c == '"') {
            in_double_quote = true;
            try out.append(alloc, c);
            i += 1;
            continue;
        }
        if (c == '\'') {
            in_single_quote = true;
            try out.append(alloc, c);
            i += 1;
            continue;
        }
        if (c == '.' and i + 1 < input.len and isDigitByte(input[i + 1])) {
            const prev: u8 = if (i == 0) 0 else input[i - 1];
            // Skip if digit / '.' / identifier-tail byte immediately precedes (does not touch existing `1.5` / `a.5` / `..5`).
            const prev_blocks = isDigitByte(prev) or prev == '.' or
                (prev >= 'a' and prev <= 'z') or (prev >= 'A' and prev <= 'Z') or
                prev == '_' or prev == '\\' or prev >= 0x80;
            if (!prev_blocks) {
                try out.append(alloc, '0');
            }
            try out.append(alloc, c);
            i += 1;
            continue;
        }
        try out.append(alloc, c);
        i += 1;
    }
    return try out.toOwnedSlice(alloc);
}

/// CSS math function (`calc()` / `min()` / `max()` / `clamp()` / `mod()` / `rem()` /
/// Supplement leading zero only within the body of `round()` / `abs()` / `sign()` / trigonometric functions, etc.).
/// official Sass CLI does not touch the numerical representation of the top-level unquoted string value (from interp),
/// Post-process on the rule emit side to normalize to `0.5` only if the math function is directly parsed
/// uses this function.
/// Return value comes from `alloc`, caller is `alloc.free`. If the input does not need to be changed, dupe the input and return it as is.
fn normalizeLeadingZerosInMathFunctions(alloc: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]u8 {
    perf.note(.format_string);
    if (std.mem.indexOfAny(u8, input, ".(") == null) return alloc.dupe(u8, input);
    if (!hasDotDigitCandidate(input)) return alloc.dupe(u8, input);
    perf.note(.format_string_dot_digit_candidate);
    if (!hasMathFunctionCallCandidate(input)) return alloc.dupe(u8, input);
    perf.note(.format_string_math_function_detected);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, input.len);

    const math_names = [_][]const u8{
        "calc",  "min",   "max",   "clamp",
        "mod",   "rem",   "round", "abs",
        "sign",  "hypot", "sqrt",  "pow",
        "log",   "exp",   "sin",   "cos",
        "tan",   "asin",  "acos",  "atan",
        "atan2",
    };

    // Perform leading zero padding only while math_depth > 0. Nest (`calc(min(.5px))`) is
    // Accumulate math_depth, put optional paren on the stack, and pop the latest is_math at `)`.
    var math_depth: u32 = 0;
    var paren_is_math: std.ArrayListUnmanaged(bool) = .empty;
    defer paren_is_math.deinit(alloc);

    var in_double_quote = false;
    var in_single_quote = false;
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (in_double_quote) {
            try out.append(alloc, c);
            if (c == '\\' and i + 1 < input.len) {
                perf.note(.format_string_escape_path);
                try out.append(alloc, input[i + 1]);
                i += 2;
                continue;
            }
            if (c == '"') in_double_quote = false;
            i += 1;
            continue;
        }
        if (in_single_quote) {
            try out.append(alloc, c);
            if (c == '\\' and i + 1 < input.len) {
                perf.note(.format_string_escape_path);
                try out.append(alloc, input[i + 1]);
                i += 2;
                continue;
            }
            if (c == '\'') in_single_quote = false;
            i += 1;
            continue;
        }
        if (c == '"') {
            in_double_quote = true;
            try out.append(alloc, c);
            i += 1;
            continue;
        }
        if (c == '\'') {
            in_single_quote = true;
            try out.append(alloc, c);
            i += 1;
            continue;
        }

        // math function name (+ '(') Detection: Exclude `-calc(` etc. that starts in the middle of identifier.
        if (std.ascii.isAlphabetic(c)) {
            const prev: u8 = if (i == 0) 0 else input[i - 1];
            const is_ident_continuation = std.ascii.isAlphanumeric(prev) or
                prev == '-' or prev == '_' or prev >= 0x80 or prev == '\\';
            if (!is_ident_continuation) {
                var matched: ?usize = null;
                for (math_names) |name| {
                    if (i + name.len < input.len and
                        std.ascii.eqlIgnoreCase(input[i .. i + name.len], name) and
                        input[i + name.len] == '(')
                    {
                        matched = name.len;
                        break;
                    }
                }
                if (matched) |nlen| {
                    perf.note(.format_string_math_function_detected);
                    try out.appendSlice(alloc, input[i .. i + nlen + 1]);
                    i += nlen + 1;
                    try paren_is_math.append(alloc, true);
                    math_depth += 1;
                    continue;
                }
            }
        }

        if (c == '(') {
            try out.append(alloc, c);
            try paren_is_math.append(alloc, false);
            i += 1;
            continue;
        }

        if (c == ')') {
            try out.append(alloc, c);
            if (paren_is_math.pop()) |was_math| {
                if (was_math) math_depth -= 1;
            }
            i += 1;
            continue;
        }

        if (math_depth > 0 and c == '.' and i + 1 < input.len and isDigitByte(input[i + 1])) {
            const prev: u8 = if (i == 0) 0 else input[i - 1];
            const prev_blocks = isDigitByte(prev) or prev == '.' or
                (prev >= 'a' and prev <= 'z') or (prev >= 'A' and prev <= 'Z') or
                prev == '_' or prev == '\\' or prev >= 0x80;
            if (!prev_blocks) {
                try out.append(alloc, '0');
                perf.note(.format_string_zero_filled);
            }
            try out.append(alloc, c);
            i += 1;
            continue;
        }

        if (c == '/' and i + 1 < input.len and (input[i + 1] == '*' or input[i + 1] == '/')) {
            perf.note(.format_string_comment_path);
        }

        try out.append(alloc, c);
        i += 1;
    }
    if (out.items.len == input.len and std.mem.eql(u8, out.items, input)) {
        return alloc.dupe(u8, input);
    }
    return try out.toOwnedSlice(alloc);
}

/// For hot-path of `normalizeLeadingZerosInMathFunctions`.
/// Return `null` if there is no change, avoiding unnecessary alloc/free on the caller.
pub fn normalizeLeadingZerosInMathFunctionsMaybeAlloc(
    alloc: std.mem.Allocator,
    input: []const u8,
) std.mem.Allocator.Error!?[]u8 {
    const normalized = try normalizeLeadingZerosInMathFunctions(alloc, input);
    if (std.mem.eql(u8, normalized, input)) {
        alloc.free(normalized);
        return null;
    }
    return normalized;
}

fn hexDigitVal(c: u8) u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    return c - 'A' + 10;
}

fn isIdentByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '\\' or c >= 0x80;
}

/// official Sass CLI plain CSS path: `#rrggbbaa` (8-digit) and `#rgba` (4-digit) hex colors
/// Expand. If alpha is 1.0 (=ff/f), shorten with named color or 6-digit hex,
/// If alpha is less than 1.0, output `rgba(R, G, B, alpha)` (alpha is 10-digit precision).
/// 3-digit `#rgb` / 6-digit `#rrggbb` (without alpha) is verbatim.
/// Do not touch the contents of quoted string (`"..."` / `'...'`) and url(...).
/// Return value comes from `alloc`, caller is `alloc.free`.
pub fn expandHexAlphaColors(alloc: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, input.len);

    var in_double_quote = false;
    var in_single_quote = false;
    var url_depth: u32 = 0;
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (in_double_quote) {
            try out.append(alloc, c);
            if (c == '\\' and i + 1 < input.len) {
                try out.append(alloc, input[i + 1]);
                i += 2;
                continue;
            }
            if (c == '"') in_double_quote = false;
            i += 1;
            continue;
        }
        if (in_single_quote) {
            try out.append(alloc, c);
            if (c == '\\' and i + 1 < input.len) {
                try out.append(alloc, input[i + 1]);
                i += 2;
                continue;
            }
            if (c == '\'') in_single_quote = false;
            i += 1;
            continue;
        }
        if (c == '"') {
            in_double_quote = true;
            try out.append(alloc, c);
            i += 1;
            continue;
        }
        if (c == '\'') {
            in_single_quote = true;
            try out.append(alloc, c);
            i += 1;
            continue;
        }
        if (url_depth > 0) {
            if (c == '(') url_depth += 1;
            if (c == ')') url_depth -= 1;
            try out.append(alloc, c);
            i += 1;
            continue;
        }
        if ((c == 'u' or c == 'U') and i + 3 < input.len and
            (input[i + 1] == 'r' or input[i + 1] == 'R') and
            (input[i + 2] == 'l' or input[i + 2] == 'L') and
            input[i + 3] == '(')
        {
            const at_ident_start = i == 0 or !isIdentByte(input[i - 1]);
            if (at_ident_start) {
                try out.appendSlice(alloc, input[i .. i + 4]);
                url_depth = 1;
                i += 4;
                continue;
            }
        }

        if (c == '#') {
            // Determine the maximum run of hex digits that follows.
            var j: usize = i + 1;
            while (j < input.len and std.ascii.isHex(input[j])) : (j += 1) {}
            const len = j - (i + 1);
            // Only 4-digit and 8-digit forms get expanded (alpha-bearing).
            // 3 / 6 digit hex (no alpha) is kept verbatim by sass.
            if (len == 8 or len == 4) {
                var r: u8 = 0;
                var g: u8 = 0;
                var b: u8 = 0;
                var a: u8 = 0;
                if (len == 8) {
                    r = (hexDigitVal(input[i + 1]) << 4) | hexDigitVal(input[i + 2]);
                    g = (hexDigitVal(input[i + 3]) << 4) | hexDigitVal(input[i + 4]);
                    b = (hexDigitVal(input[i + 5]) << 4) | hexDigitVal(input[i + 6]);
                    a = (hexDigitVal(input[i + 7]) << 4) | hexDigitVal(input[i + 8]);
                } else {
                    const dr = hexDigitVal(input[i + 1]);
                    const dg = hexDigitVal(input[i + 2]);
                    const db = hexDigitVal(input[i + 3]);
                    const da = hexDigitVal(input[i + 4]);
                    r = (dr << 4) | dr;
                    g = (dg << 4) | dg;
                    b = (db << 4) | db;
                    a = (da << 4) | da;
                }
                if (a == 0xff) {
                    if (color_mod.namedColorForRgb(r, g, b)) |name| {
                        try out.appendSlice(alloc, name);
                    } else {
                        var hex_buf: [7]u8 = undefined;
                        // SAFETY: #rrggbb for u8 r,g,b always fits in 7 bytes.
                        const s = std.fmt.bufPrint(&hex_buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ r, g, b }) catch |err| {
                            std.debug.panic("format color hex: {s}", .{@errorName(err)});
                        };
                        try out.appendSlice(alloc, s);
                    }
                } else {
                    const alpha_f: f64 = @as(f64, @floatFromInt(a)) / 255.0;
                    const alpha_str = try formatNumberCore(alloc, alpha_f);
                    defer alloc.free(alpha_str);
                    var component_buf: [3]u8 = undefined;
                    // SAFETY: Decimal string for u8 channel fits in [3]u8 (max "255").
                    const r_str = std.fmt.bufPrint(&component_buf, "{d}", .{r}) catch |err| {
                        std.debug.panic("format color component: {s}", .{@errorName(err)});
                    };
                    try out.ensureUnusedCapacity(alloc, "rgba(".len + r_str.len + 2 + 3 + 2 + 3 + 2 + alpha_str.len + 1);
                    out.appendSliceAssumeCapacity("rgba(");
                    out.appendSliceAssumeCapacity(r_str);
                    out.appendSliceAssumeCapacity(", ");
                    // SAFETY: Decimal string for u8 channel fits in [3]u8 (max "255").
                    const g_str = std.fmt.bufPrint(&component_buf, "{d}", .{g}) catch |err| {
                        std.debug.panic("format color component: {s}", .{@errorName(err)});
                    };
                    out.appendSliceAssumeCapacity(g_str);
                    out.appendSliceAssumeCapacity(", ");
                    // SAFETY: Decimal string for u8 channel fits in [3]u8 (max "255").
                    const b_str = std.fmt.bufPrint(&component_buf, "{d}", .{b}) catch |err| {
                        std.debug.panic("format color component: {s}", .{@errorName(err)});
                    };
                    out.appendSliceAssumeCapacity(b_str);
                    out.appendSliceAssumeCapacity(", ");
                    out.appendSliceAssumeCapacity(alpha_str);
                    out.appendAssumeCapacity(')');
                }
                i = j;
                continue;
            }
        }

        try out.append(alloc, c);
        i += 1;
    }
    return try out.toOwnedSlice(alloc);
}

/// If `unit` is present, format it as `value + unit`, and degenerate values that cannot be directly output to CSS as `calc(...)`.
pub fn formatNumberWithUnit(
    alloc: std.mem.Allocator,
    value: f64,
    unit: ?[]const u8,
) std.mem.Allocator.Error![]u8 {
    if (std.math.isNan(value)) return formatDegenerateWithUnit(alloc, "NaN", unit);
    if (std.math.isInf(value)) return formatDegenerateWithUnit(alloc, if (value < 0) "-infinity" else "infinity", unit);

    const core = try formatNumberCore(alloc, value);
    errdefer alloc.free(core);
    if (unit == null or unit.?.len == 0) return core;
    defer alloc.free(core);
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ core, unit.? });
}

test "formatNumberCore: integers" {
    const alloc = std.testing.allocator;
    const s1 = try formatNumberCore(alloc, 42.0);
    defer alloc.free(s1);
    try std.testing.expectEqualStrings("42", s1);
    const s2 = try formatNumberCore(alloc, 0.0);
    defer alloc.free(s2);
    try std.testing.expectEqualStrings("0", s2);
    const s3 = try formatNumberCore(alloc, -3.0);
    defer alloc.free(s3);
    try std.testing.expectEqualStrings("-3", s3);
}

test "formatNumberCore: fractions trim and zero-pad" {
    const alloc = std.testing.allocator;
    const s1 = try formatNumberCore(alloc, 0.5);
    defer alloc.free(s1);
    try std.testing.expectEqualStrings("0.5", s1);
    const s2 = try formatNumberCore(alloc, -0.5);
    defer alloc.free(s2);
    try std.testing.expectEqualStrings("-0.5", s2);
    const s3 = try formatNumberCore(alloc, 1.5);
    defer alloc.free(s3);
    try std.testing.expectEqualStrings("1.5", s3);
    const s4 = try formatNumberCore(alloc, 1.25);
    defer alloc.free(s4);
    try std.testing.expectEqualStrings("1.25", s4);
}

test "formatNumberCore: negative zero normalizes" {
    const alloc = std.testing.allocator;
    const s = try formatNumberCore(alloc, -0.0);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("0", s);
}

test "formatNumberWithUnit: degenerate values" {
    const alloc = std.testing.allocator;
    const n1 = try formatNumberWithUnit(alloc, std.math.nan(f64), null);
    defer alloc.free(n1);
    try std.testing.expectEqualStrings("calc(NaN)", n1);

    const n2 = try formatNumberWithUnit(alloc, std.math.inf(f64), "deg");
    defer alloc.free(n2);
    try std.testing.expectEqualStrings("calc(infinity * 1deg)", n2);
}

test "normalizeLeadingZeros: fills missing zero on decimals" {
    const alloc = std.testing.allocator;

    const s1 = try normalizeLeadingZeros(alloc, ".7");
    defer alloc.free(s1);
    try std.testing.expectEqualStrings("0.7", s1);

    const s2 = try normalizeLeadingZeros(alloc, "-.5");
    defer alloc.free(s2);
    try std.testing.expectEqualStrings("-0.5", s2);

    const s3 = try normalizeLeadingZeros(alloc, "all .2s ease-in");
    defer alloc.free(s3);
    try std.testing.expectEqualStrings("all 0.2s ease-in", s3);

    const s4 = try normalizeLeadingZeros(alloc, "calc(var(--x) * .5)");
    defer alloc.free(s4);
    try std.testing.expectEqualStrings("calc(var(--x) * 0.5)", s4);
}

test "normalizeLeadingZeros: preserves non-decimal dots" {
    const alloc = std.testing.allocator;

    const s1 = try normalizeLeadingZeros(alloc, "1.5");
    defer alloc.free(s1);
    try std.testing.expectEqualStrings("1.5", s1);

    const s2 = try normalizeLeadingZeros(alloc, "0.7");
    defer alloc.free(s2);
    try std.testing.expectEqualStrings("0.7", s2);

    const s3 = try normalizeLeadingZeros(alloc, ".foo");
    defer alloc.free(s3);
    try std.testing.expectEqualStrings(".foo", s3);

    const s4 = try normalizeLeadingZeros(alloc, "a.5b");
    defer alloc.free(s4);
    try std.testing.expectEqualStrings("a.5b", s4);
}

test "normalizeLeadingZeros: does not touch quoted strings" {
    const alloc = std.testing.allocator;

    const s1 = try normalizeLeadingZeros(alloc, "\"foo .5 bar\"");
    defer alloc.free(s1);
    try std.testing.expectEqualStrings("\"foo .5 bar\"", s1);

    const s2 = try normalizeLeadingZeros(alloc, "content: \".5\" .5em");
    defer alloc.free(s2);
    try std.testing.expectEqualStrings("content: \".5\" 0.5em", s2);

    const s3 = try normalizeLeadingZeros(alloc, "'.5'");
    defer alloc.free(s3);
    try std.testing.expectEqualStrings("'.5'", s3);
}

test "normalizeLeadingZeros: preserves empty input" {
    const alloc = std.testing.allocator;
    const s = try normalizeLeadingZeros(alloc, "");
    defer alloc.free(s);
    try std.testing.expectEqualStrings("", s);
}

test "expandHexAlphaColors: 8-digit hex expands to rgba" {
    const alloc = std.testing.allocator;

    const s1 = try expandHexAlphaColors(alloc, "#00000040");
    defer alloc.free(s1);
    try std.testing.expectEqualStrings("rgba(0, 0, 0, 0.2509803922)", s1);

    const s2 = try expandHexAlphaColors(alloc, "#ff000080");
    defer alloc.free(s2);
    try std.testing.expectEqualStrings("rgba(255, 0, 0, 0.5019607843)", s2);
}

test "expandHexAlphaColors: 4-digit hex expands to rgba" {
    const alloc = std.testing.allocator;

    const s1 = try expandHexAlphaColors(alloc, "#000c");
    defer alloc.free(s1);
    try std.testing.expectEqualStrings("rgba(0, 0, 0, 0.8)", s1);

    const s2 = try expandHexAlphaColors(alloc, "#0000");
    defer alloc.free(s2);
    try std.testing.expectEqualStrings("rgba(0, 0, 0, 0)", s2);
}

test "expandHexAlphaColors: opaque alpha collapses to named or hex" {
    const alloc = std.testing.allocator;

    const s1 = try expandHexAlphaColors(alloc, "#000000ff");
    defer alloc.free(s1);
    try std.testing.expectEqualStrings("black", s1);

    const s2 = try expandHexAlphaColors(alloc, "#ffffffff");
    defer alloc.free(s2);
    try std.testing.expectEqualStrings("white", s2);

    const s3 = try expandHexAlphaColors(alloc, "#1234ffff");
    defer alloc.free(s3);
    try std.testing.expectEqualStrings("#1234ff", s3);

    const s4 = try expandHexAlphaColors(alloc, "#f00f");
    defer alloc.free(s4);
    try std.testing.expectEqualStrings("red", s4);
}

test "expandHexAlphaColors: 3 / 6 digit hex without alpha kept verbatim" {
    const alloc = std.testing.allocator;

    const s1 = try expandHexAlphaColors(alloc, "#abc");
    defer alloc.free(s1);
    try std.testing.expectEqualStrings("#abc", s1);

    const s2 = try expandHexAlphaColors(alloc, "#aaccee");
    defer alloc.free(s2);
    try std.testing.expectEqualStrings("#aaccee", s2);

    const s3 = try expandHexAlphaColors(alloc, "#000000");
    defer alloc.free(s3);
    try std.testing.expectEqualStrings("#000000", s3);
}

test "expandHexAlphaColors: invalid hex lengths kept verbatim" {
    const alloc = std.testing.allocator;

    // 5, 7, 2 hex digit forms are not recognized
    for ([_][]const u8{ "#abcde", "#aabbccd", "#ab", "#1" }) |input| {
        const s = try expandHexAlphaColors(alloc, input);
        defer alloc.free(s);
        try std.testing.expectEqualStrings(input, s);
    }
}

test "expandHexAlphaColors: hex inside quoted strings kept verbatim" {
    const alloc = std.testing.allocator;

    const s1 = try expandHexAlphaColors(alloc, "\"#00000040\"");
    defer alloc.free(s1);
    try std.testing.expectEqualStrings("\"#00000040\"", s1);

    const s2 = try expandHexAlphaColors(alloc, "'#f00f'");
    defer alloc.free(s2);
    try std.testing.expectEqualStrings("'#f00f'", s2);
}

test "expandHexAlphaColors: hex inside url() kept verbatim" {
    const alloc = std.testing.allocator;
    const s = try expandHexAlphaColors(alloc, "url(#aabbccdd)");
    defer alloc.free(s);
    try std.testing.expectEqualStrings("url(#aabbccdd)", s);
}

test "expandHexAlphaColors: mid-token hex expansion" {
    const alloc = std.testing.allocator;
    const s = try expandHexAlphaColors(alloc, "0 6px 30px #0000001a");
    defer alloc.free(s);
    try std.testing.expectEqualStrings("0 6px 30px rgba(0, 0, 0, 0.1019607843)", s);
}
