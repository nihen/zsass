//! sass:math builtins.
const std = @import("std");
const shared = @import("shared.zig");
const deprecation_mod = @import("../runtime/deprecation.zig");
const intern_pool_mod = @import("../runtime/intern_pool.zig");

const Value = shared.Value;
const InternId = shared.InternId;
const BuiltinContext = shared.BuiltinContext;
const BuiltinError = shared.BuiltinError;

const badArity = shared.badArity;
const expectArity = shared.expectArity;
const numberLike = shared.numberLike;
const internString = shared.internString;
const valueToCssString = shared.valueToCssString;
const bindNamedOrPositionalArgsStrict = shared.bindNamedOrPositionalArgsStrict;
const reportArgumentTypeMismatch = shared.reportArgumentTypeMismatch;

const random_seed_default: u64 = 0xdead_beef_cafe_babe;
const calc_arg_marker = "\x01zsass-calc-arg:";

const RoundMode = enum {
    floor,
    ceil,
    nearest,
};

const RoundStrategy = enum {
    nearest,
    up,
    down,
    to_zero,
    from_zero,
};

const RoundKeywordParam = enum {
    strategy,
    number,
    step,
    offset,
};

const UnitCategory = enum {
    length,
    angle,
    time,
    frequency,
    resolution,
    unknown,
};

fn canonicalizeSignedZero(value: f64) f64 {
    return if (std.math.isNegativeZero(value)) 0 else value;
}

fn roundNearestAwayFromZero(value: f64) f64 {
    const lower = @floor(value);
    const upper = @ceil(value);
    const dist_lower = value - lower;
    const dist_upper = upper - value;
    const midpoint = lower + 0.5;
    const tol = 8.0 * std.math.floatEps(f64) * @max(1.0, @abs(midpoint));
    if (@abs(value - midpoint) <= tol) return if (value < 0) lower else upper;
    return if (dist_lower < dist_upper) lower else upper;
}

fn roundStrategyEquals(candidate: []const u8, expected: []const u8) bool {
    if (candidate.len != expected.len) return false;
    for (candidate, expected) |c, e| {
        var ch = c;
        if (ch == '_') ch = '-';
        if (std.ascii.toLower(ch) != e) return false;
    }
    return true;
}

fn parseRoundStrategyRaw(strategy_raw: []const u8) ?RoundStrategy {
    if (roundStrategyEquals(strategy_raw, "nearest")) return .nearest;
    if (roundStrategyEquals(strategy_raw, "up")) return .up;
    if (roundStrategyEquals(strategy_raw, "down")) return .down;
    if (roundStrategyEquals(strategy_raw, "to-zero") or
        roundStrategyEquals(strategy_raw, "toward-zero") or
        roundStrategyEquals(strategy_raw, "towards-zero"))
    {
        return .to_zero;
    }
    if (roundStrategyEquals(strategy_raw, "from-zero") or
        roundStrategyEquals(strategy_raw, "away-from-zero"))
    {
        return .from_zero;
    }
    return null;
}

fn stripMatchingQuotes(text: []const u8) []const u8 {
    if (text.len >= 2 and
        ((text[0] == '"' and text[text.len - 1] == '"') or
            (text[0] == '\'' and text[text.len - 1] == '\'')))
    {
        return text[1 .. text.len - 1];
    }
    return text;
}

fn parseRoundStrategyText(raw: []const u8) ?RoundStrategy {
    const trimmed = std.mem.trim(u8, raw, " \t\n\r");
    if (trimmed.len == 0) return null;
    if (parseRoundStrategyRaw(trimmed)) |parsed| return parsed;

    const maybe_unquoted = stripMatchingQuotes(trimmed);
    if (maybe_unquoted.ptr == trimmed.ptr and maybe_unquoted.len == trimmed.len) return null;
    const inner = std.mem.trim(u8, maybe_unquoted, " \t\n\r");
    if (inner.len == 0) return null;
    return parseRoundStrategyRaw(inner);
}

fn parseRoundStrategyValue(ctx: *BuiltinContext, value: Value) BuiltinError!?RoundStrategy {
    if (value.isString()) {
        if (value.stringQuoted(ctx.string_flags_pool.items)) return null;
        const raw = ctx.intern_pool.get(value.stringIntern());
        return parseRoundStrategyText(raw);
    }
    if (value.kind() == .calc_fragment or value.kind() == .interp_fragment) {
        const rendered = try valueToCssString(ctx, value);
        defer ctx.allocator.free(rendered);
        return parseRoundStrategyText(rendered);
    }
    return null;
}

fn normalizeRoundKeywordName(raw_key: []const u8, buf: *[32]u8) []const u8 {
    if (raw_key.len == 0) return raw_key;
    var start: usize = if (raw_key[0] == '$') 1 else 0;
    var out_len: usize = 0;
    while (start < raw_key.len and out_len < buf.len) : (start += 1) {
        var ch = raw_key[start];
        if (ch == '_') ch = '-';
        buf[out_len] = std.ascii.toLower(ch);
        out_len += 1;
    }
    return buf[0..out_len];
}

fn classifyRoundKeyword(norm: []const u8) ?RoundKeywordParam {
    if (norm.len == 0) return null;
    if (std.mem.eql(u8, norm, "strategy") or std.mem.eql(u8, norm, "rounding-strategy")) {
        return .strategy;
    }
    if (std.mem.eql(u8, norm, "number") or std.mem.eql(u8, norm, "value")) {
        return .number;
    }
    if (std.mem.eql(u8, norm, "step")) {
        return .step;
    }
    if (std.mem.eql(u8, norm, "offset")) {
        return .offset;
    }
    return null;
}

fn roundWithStrategy(number: f64, step: f64, strategy: RoundStrategy) f64 {
    if (std.math.isNan(number) or std.math.isNan(step)) return std.math.nan(f64);
    if (step == 0) return std.math.nan(f64);
    if (std.math.isInf(number)) {
        return if (std.math.isInf(step)) std.math.nan(f64) else number;
    }
    if (std.math.isInf(step)) {
        const signed_zero = if (std.math.signbit(number)) -@as(f64, 0.0) else @as(f64, 0.0);
        switch (strategy) {
            .nearest, .to_zero => return signed_zero,
            .up => {
                if (number > 0) return std.math.inf(f64);
                return signed_zero;
            },
            .down => {
                if (number < 0) return -std.math.inf(f64);
                return signed_zero;
            },
            .from_zero => {
                if (number == 0) return signed_zero;
                if (number > 0 or (number == 0 and !std.math.signbit(number))) {
                    return std.math.inf(f64);
                }
                return -std.math.inf(f64);
            },
        }
    }
    const abs_step = @abs(step);
    const ratio = number / abs_step;
    return switch (strategy) {
        .nearest => roundNearestAwayFromZero(ratio) * abs_step,
        .up => @ceil(ratio) * abs_step,
        .down => @floor(ratio) * abs_step,
        .to_zero => if (std.math.signbit(step)) @floor(ratio) * abs_step else @trunc(ratio) * abs_step,
        .from_zero => if (ratio >= 0) @ceil(ratio) * abs_step else @floor(ratio) * abs_step,
    };
}

fn roundToSignificantDigits(value: f64, digits: u8) f64 {
    if (!std.math.isFinite(value) or value == 0 or digits == 0) return value;
    const magnitude = @floor(@log10(@abs(value)));
    const scale_exp = @as(f64, @floatFromInt(digits - 1)) - magnitude;
    const scale = std.math.pow(f64, 10.0, scale_exp);
    if (!std.math.isFinite(scale) or scale == 0) return value;
    return @round(value * scale) / scale;
}

fn roundPowResult(value: f64) f64 {
    if (!std.math.isFinite(value) or value == 0) return value;

    const rounded = roundToSignificantDigits(value, 10);
    const magnitude = @floor(@log10(@abs(rounded)));
    const pow10 = std.math.pow(f64, 10.0, magnitude);
    if (std.math.isFinite(pow10) and pow10 != 0) {
        const normalized = rounded / pow10;
        if (@abs(@abs(normalized) - 10.0) <= 1e-12) {
            return std.math.copysign(pow10 * 10.0, rounded);
        }
        if (@abs(@abs(normalized) - 1.0) <= 1e-12) {
            return std.math.copysign(pow10, rounded);
        }
    }

    return rounded;
}

fn applyPrecisionRound(value: f64, digits: i32, mode: RoundMode) f64 {
    const factor = std.math.pow(f64, 10.0, @as(f64, @floatFromInt(digits)));
    if (factor == 0 or !std.math.isFinite(factor)) return canonicalizeSignedZero(value);

    const scaled = value * factor;
    if (!std.math.isFinite(scaled)) {
        if (std.math.isFinite(value)) return canonicalizeSignedZero(value);
        return canonicalizeSignedZero(scaled / factor);
    }

    const rounded = switch (mode) {
        .floor => @floor(scaled),
        .ceil => @ceil(scaled),
        .nearest => roundNearestAwayFromZero(scaled),
    };
    return canonicalizeSignedZero(rounded / factor);
}

fn unitSlice(ctx: *BuiltinContext, id: InternId) ?[]const u8 {
    return if (id == .none) null else ctx.intern_pool.get(id);
}

fn unitCategory(unit: []const u8) UnitCategory {
    if (std.ascii.eqlIgnoreCase(unit, "px") or
        std.ascii.eqlIgnoreCase(unit, "cm") or
        std.ascii.eqlIgnoreCase(unit, "mm") or
        std.ascii.eqlIgnoreCase(unit, "in") or
        std.ascii.eqlIgnoreCase(unit, "pt") or
        std.ascii.eqlIgnoreCase(unit, "pc") or
        std.ascii.eqlIgnoreCase(unit, "q")) return .length;

    if (std.ascii.eqlIgnoreCase(unit, "deg") or
        std.ascii.eqlIgnoreCase(unit, "rad") or
        std.ascii.eqlIgnoreCase(unit, "grad") or
        std.ascii.eqlIgnoreCase(unit, "turn")) return .angle;

    if (std.ascii.eqlIgnoreCase(unit, "s") or std.ascii.eqlIgnoreCase(unit, "ms")) return .time;

    if (std.ascii.eqlIgnoreCase(unit, "hz") or std.ascii.eqlIgnoreCase(unit, "khz")) return .frequency;

    if (std.ascii.eqlIgnoreCase(unit, "dpi") or
        std.ascii.eqlIgnoreCase(unit, "dpcm") or
        std.ascii.eqlIgnoreCase(unit, "dppx")) return .resolution;

    return .unknown;
}

fn isGeneratedUnitDescription(unit: []const u8) bool {
    return std.mem.findAny(u8, unit, "*/^()") != null;
}

fn knownCalculationUnitsIncompatible(unit_a: ?[]const u8, unit_b: ?[]const u8) bool {
    if ((unit_a == null) != (unit_b == null)) return true;
    if (unit_a == null and unit_b == null) return false;
    const a = unit_a.?;
    const b = unit_b.?;
    if (std.ascii.eqlIgnoreCase(a, b)) return false;
    const cat_a = unitCategory(a);
    const cat_b = unitCategory(b);
    if (cat_a == .unknown or cat_b == .unknown) return false;
    return cat_a != cat_b;
}

fn toCanonical(value: f64, unit: []const u8) ?f64 {
    if (std.ascii.eqlIgnoreCase(unit, "px")) return value;
    if (std.ascii.eqlIgnoreCase(unit, "in")) return value * 96.0;
    if (std.ascii.eqlIgnoreCase(unit, "cm")) return value * 96.0 / 2.54;
    if (std.ascii.eqlIgnoreCase(unit, "mm")) return value * 96.0 / 25.4;
    if (std.ascii.eqlIgnoreCase(unit, "pt")) return value * 96.0 / 72.0;
    if (std.ascii.eqlIgnoreCase(unit, "pc")) return value * 96.0 / 6.0;
    if (std.ascii.eqlIgnoreCase(unit, "q")) return value * 96.0 / 101.6;

    if (std.ascii.eqlIgnoreCase(unit, "deg")) return value;
    if (std.ascii.eqlIgnoreCase(unit, "rad")) return value * 180.0 / std.math.pi;
    if (std.ascii.eqlIgnoreCase(unit, "grad")) return value * 0.9;
    if (std.ascii.eqlIgnoreCase(unit, "turn")) return value * 360.0;

    if (std.ascii.eqlIgnoreCase(unit, "s")) return value;
    if (std.ascii.eqlIgnoreCase(unit, "ms")) return value / 1000.0;

    if (std.ascii.eqlIgnoreCase(unit, "hz")) return value;
    if (std.ascii.eqlIgnoreCase(unit, "khz")) return value * 1000.0;

    if (std.ascii.eqlIgnoreCase(unit, "dppx")) return value;
    if (std.ascii.eqlIgnoreCase(unit, "dpi")) return value / 96.0;
    if (std.ascii.eqlIgnoreCase(unit, "dpcm")) return value * 2.54 / 96.0;

    return null;
}

fn fromCanonical(value: f64, unit: []const u8) ?f64 {
    if (std.ascii.eqlIgnoreCase(unit, "px")) return value;
    if (std.ascii.eqlIgnoreCase(unit, "in")) return value / 96.0;
    if (std.ascii.eqlIgnoreCase(unit, "cm")) return value * 2.54 / 96.0;
    if (std.ascii.eqlIgnoreCase(unit, "mm")) return value * 25.4 / 96.0;
    if (std.ascii.eqlIgnoreCase(unit, "pt")) return value * 72.0 / 96.0;
    if (std.ascii.eqlIgnoreCase(unit, "pc")) return value * 6.0 / 96.0;
    if (std.ascii.eqlIgnoreCase(unit, "q")) return value * 101.6 / 96.0;

    if (std.ascii.eqlIgnoreCase(unit, "deg")) return value;
    if (std.ascii.eqlIgnoreCase(unit, "rad")) return value * std.math.pi / 180.0;
    if (std.ascii.eqlIgnoreCase(unit, "grad")) return value / 0.9;
    if (std.ascii.eqlIgnoreCase(unit, "turn")) return value / 360.0;

    if (std.ascii.eqlIgnoreCase(unit, "s")) return value;
    if (std.ascii.eqlIgnoreCase(unit, "ms")) return value * 1000.0;

    if (std.ascii.eqlIgnoreCase(unit, "hz")) return value;
    if (std.ascii.eqlIgnoreCase(unit, "khz")) return value / 1000.0;

    if (std.ascii.eqlIgnoreCase(unit, "dppx")) return value;
    if (std.ascii.eqlIgnoreCase(unit, "dpi")) return value * 96.0;
    if (std.ascii.eqlIgnoreCase(unit, "dpcm")) return value * 96.0 / 2.54;

    return null;
}

fn convertUnit(value: f64, from: ?[]const u8, to: ?[]const u8) ?f64 {
    if (from == null and to == null) return value;
    if (from == null or to == null) return null;

    const from_u = from.?;
    const to_u = to.?;
    if (std.ascii.eqlIgnoreCase(from_u, to_u)) return value;

    const from_cat = unitCategory(from_u);
    const to_cat = unitCategory(to_u);
    if (from_cat == .unknown or to_cat == .unknown or from_cat != to_cat) return null;

    const canonical = toCanonical(value, from_u) orelse return null;
    return fromCanonical(canonical, to_u);
}

fn convertNumberToTargetUnit(ctx: *BuiltinContext, value: Value, target_unit: InternId) BuiltinError!f64 {
    if (value.kind() != .number) return error.BuiltinType;
    const from_unit = value.unitId(ctx.number_pool);
    if (from_unit == target_unit) return value.asF64(ctx.number_pool);

    const from_slice = unitSlice(ctx, from_unit);
    const to_slice = unitSlice(ctx, target_unit);
    return convertUnit(value.asF64(ctx.number_pool), from_slice, to_slice) orelse error.BuiltinType;
}

fn convertAngleToRadians(value: f64, unit: ?[]const u8) f64 {
    if (unit) |u| {
        if (std.ascii.eqlIgnoreCase(u, "deg")) return value * std.math.pi / 180.0;
        if (std.ascii.eqlIgnoreCase(u, "grad")) return value * std.math.pi / 200.0;
        if (std.ascii.eqlIgnoreCase(u, "turn")) return value * 2.0 * std.math.pi;
        if (std.ascii.eqlIgnoreCase(u, "rad")) return value;
    }
    return value;
}

fn numberToDeg(ctx: *BuiltinContext, value: f64) BuiltinError!Value {
    const deg = try internString(ctx, "deg");
    return numberLike(ctx, value, deg);
}

fn minMaxComparableValue(ctx: *BuiltinContext, source: Value, target_unit: InternId) BuiltinError!f64 {
    if (source.kind() != .number) return error.BuiltinType;
    if (source.unitId(ctx.number_pool) == .none or target_unit == .none) return source.asF64(ctx.number_pool);
    return convertNumberToTargetUnit(ctx, source, target_unit) catch return error.BuiltinArity;
}

fn unitsCompatibleForComparable(ctx: *BuiltinContext, a: Value, b: Value) bool {
    const unit_a = unitSlice(ctx, a.unitId(ctx.number_pool));
    const unit_b = unitSlice(ctx, b.unitId(ctx.number_pool));
    if (unit_a == null or unit_b == null) return true;
    return convertUnit(1.0, unit_a, unit_b) != null;
}

fn sassModulo(a: f64, b: f64) f64 {
    if (std.math.isInf(b)) {
        if (std.math.isInf(a)) return std.math.nan(f64);
        if (std.math.signbit(a) == std.math.signbit(b)) return a;
        return std.math.nan(f64);
    }

    const result = a - b * @floor(a / b);
    if (result == 0) {
        return if (std.math.signbit(b)) -@as(f64, 0) else @as(f64, 0);
    }
    return result;
}

fn randomNext(state: *u64) u64 {
    var s = state.*;
    if (s == 0) s = random_seed_default;
    s ^= s << 13;
    s ^= s >> 7;
    s ^= s << 17;
    state.* = s;
    return s;
}

fn randomUnitless(state: *u64) f64 {
    const s = randomNext(state);
    const mantissa_mask: u64 = (@as(u64, 1) << 53) - 1;
    const mantissa: f64 = @floatFromInt(s & mantissa_mask);
    const denominator: f64 = @floatFromInt(@as(u64, 1) << 53);
    return mantissa / denominator;
}

fn ensureNoNamedArgs(args: []const Value, arg_names: []const InternId) BuiltinError!void {
    const named_len = @min(args.len, arg_names.len);
    for (arg_names[0..named_len]) |name_id| {
        if (name_id != .none) return error.BuiltinArity;
    }
}

fn valueLooksLikeCssMathArg(ctx: *BuiltinContext, value: Value) bool {
    if (value.isString()) {
        if (value.stringQuoted(ctx.string_flags_pool.items)) return false;
        const raw = ctx.intern_pool.get(value.stringIntern());
        if (std.mem.startsWith(u8, raw, calc_arg_marker)) return true;
        return std.mem.findScalar(u8, raw, '(') != null or
            std.mem.findScalar(u8, raw, '%') != null;
    }
    if (value.kind() == .calc_fragment or value.kind() == .interp_fragment) return true;
    if (value.kind() == .list) {
        if (value.listComma(ctx.list_meta_pool.items) or value.listBracketed(ctx.list_meta_pool.items)) return false;
        for (ctx.list_pool.items[value.listHandle()]) |item| {
            if (valueLooksLikeCssMathArg(ctx, item)) return true;
        }
    }
    return false;
}

fn stringLikeContainsComma(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\n\r");
    if (trimmed.len == 0) return false;
    const content = std.mem.trim(u8, stripMatchingQuotes(trimmed), " \t\n\r");
    return std.mem.findScalar(u8, content, ',') != null;
}

fn roundSingleArgShouldPreserveCssCall(ctx: *BuiltinContext, value: Value) BuiltinError!bool {
    if (value.isString()) return stringLikeContainsComma(ctx.intern_pool.get(value.stringIntern()));
    if (value.kind() == .calc_fragment or value.kind() == .interp_fragment) {
        const rendered = try valueToCssString(ctx, value);
        defer ctx.allocator.free(rendered);
        return stringLikeContainsComma(rendered);
    }
    return false;
}

fn parseCssMathConstantIdent(text: []const u8) ?f64 {
    const trimmed = std.mem.trim(u8, text, " \t\n\r");
    if (trimmed.len == 0) return null;

    var sign: f64 = 1;
    var ident = trimmed;
    if (trimmed[0] == '+' or trimmed[0] == '-') {
        sign = if (trimmed[0] == '-') -1 else 1;
        ident = std.mem.trimStart(u8, trimmed[1..], " \t\n\r");
        if (ident.len == 0) return null;
    }

    if (shared.identifierEq(ident, "pi")) return sign * std.math.pi;
    if (shared.identifierEq(ident, "e")) return sign * std.math.e;
    if (shared.identifierEq(ident, "infinity")) return if (sign < 0) -std.math.inf(f64) else std.math.inf(f64);
    if (shared.identifierEq(ident, "nan")) return std.math.nan(f64);
    return null;
}

fn valueHasPercentUnit(ctx: *BuiltinContext, value: Value) bool {
    if (value.kind() != .number) return false;
    const unit = unitSlice(ctx, value.unitId(ctx.number_pool)) orelse return false;
    return std.ascii.eqlIgnoreCase(unit, "%");
}

fn valueContainsPercentToken(ctx: *BuiltinContext, value: Value) BuiltinError!bool {
    if (value.isNumber()) return valueHasPercentUnit(ctx, value);
    if (value.isString()) return std.mem.findScalar(u8, ctx.intern_pool.get(value.stringIntern()), '%') != null;
    if (value.kind() == .calc_fragment or value.kind() == .interp_fragment) {
        const rendered = try valueToCssString(ctx, value);
        defer ctx.allocator.free(rendered);
        return std.mem.findScalar(u8, rendered, '%') != null;
    }
    if (value.kind() == .list) {
        const items = ctx.list_pool.items[value.listHandle()];
        for (items) |item| {
            if (try valueContainsPercentToken(ctx, item)) return true;
        }
        return false;
    }
    return false;
}

fn shouldPreserveCssMathCall(ctx: *BuiltinContext, args: []const Value) bool {
    for (args) |arg| {
        if (valueLooksLikeCssMathArg(ctx, arg)) return true;
        if (valueHasPercentUnit(ctx, arg)) return true;
    }
    return false;
}

fn cssMathUnitsNeedPassthrough(unit_a: ?[]const u8, unit_b: ?[]const u8, preserve_mixed_unitless: bool) bool {
    if ((unit_a == null) != (unit_b == null)) return preserve_mixed_unitless;
    if (unit_a == null and unit_b == null) return false;
    const a = unit_a.?;
    const b = unit_b.?;
    if (std.ascii.eqlIgnoreCase(a, b)) return false;
    if (convertUnit(1.0, a, b) != null) return false;
    return !knownCalculationUnitsIncompatible(unit_a, unit_b);
}

fn isMathBinaryOperator(c: u8) bool {
    return c == '+' or c == '-' or c == '*' or c == '/' or c == '%' or c == ',';
}

fn previousNonWhitespaceIndex(text: []const u8, index: usize) ?usize {
    var i = index;
    while (i > 0) {
        i -= 1;
        if (!std.ascii.isWhitespace(text[i])) return i;
    }
    return null;
}

fn isCssIdentCharByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '\\' or c >= 0x80;
}

fn startsCssFunctionAt(text: []const u8, i: usize, name: []const u8) bool {
    if (i + name.len + 1 > text.len) return false;
    if (i > 0 and isCssIdentCharByte(text[i - 1])) return false;
    if (!std.ascii.eqlIgnoreCase(text[i .. i + name.len], name)) return false;
    return text[i + name.len] == '(';
}

fn findFunctionClose(text: []const u8, open_idx: usize) ?usize {
    var depth: u32 = 0;
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

fn cssVarOrEnvCallEnd(text: []const u8, i: usize) ?usize {
    if (startsCssFunctionAt(text, i, "var")) return findFunctionClose(text, i + 3);
    if (startsCssFunctionAt(text, i, "env")) return findFunctionClose(text, i + 3);
    return null;
}

fn cssVarOrEnvCallEndAtOperandStart(text: []const u8, i: usize) ?usize {
    if (i + 4 <= text.len and std.ascii.eqlIgnoreCase(text[i .. i + 3], "var") and text[i + 3] == '(') {
        return findFunctionClose(text, i + 3);
    }
    if (i + 4 <= text.len and std.ascii.eqlIgnoreCase(text[i .. i + 3], "env") and text[i + 3] == '(') {
        return findFunctionClose(text, i + 3);
    }
    return null;
}

fn hasOuterWrappingParens(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len < 2 or t[0] != '(' or t[t.len - 1] != ')') return false;
    var depth: u32 = 0;
    var in_string: u8 = 0;
    for (t, 0..) |c, i| {
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
            if (depth == 0 and i != t.len - 1) return false;
        }
    }
    return depth == 0;
}

fn unwrapOuterParensForCssMathArg(ctx: *BuiltinContext, text: []const u8) BuiltinError![]u8 {
    var t = std.mem.trim(u8, text, " \t\r\n");
    var changed = false;
    while (hasOuterWrappingParens(t)) {
        const inner = std.mem.trim(u8, t[1 .. t.len - 1], " \t\r\n");
        if (isSingleVarOrEnvCall(inner)) break;
        t = inner;
        changed = true;
    }
    if (changed) return ctx.allocator.dupe(u8, t);
    return ctx.allocator.dupe(u8, text);
}

fn normalizeCssMathArgText(ctx: *BuiltinContext, text: []const u8) BuiltinError![]u8 {
    var stage1: std.ArrayListUnmanaged(u8) = .empty;
    defer stage1.deinit(ctx.allocator);

    var i: usize = 0;
    while (i < text.len) {
        if (cssVarOrEnvCallEnd(text, i)) |end_i| {
            try stage1.appendSlice(ctx.allocator, text[i .. end_i + 1]);
            i = end_i + 1;
            continue;
        }

        const c = text[i];
        if (c == '+' or c == '-') {
            const prev_i = previousNonWhitespaceIndex(text, i);
            var next_i = i + 1;
            while (next_i < text.len and std.ascii.isWhitespace(text[next_i])) : (next_i += 1) {}
            if (prev_i != null and next_i < text.len) {
                const prev = text[prev_i.?];
                const next = text[next_i];
                const prev_is_opener = isMathBinaryOperator(prev) or prev == '(';
                const next_is_closer = isMathBinaryOperator(next) or next == ')';
                if (!prev_is_opener and !next_is_closer) {
                    while (stage1.items.len != 0 and std.ascii.isWhitespace(stage1.items[stage1.items.len - 1])) {
                        _ = stage1.pop();
                    }
                    if (stage1.items.len != 0 and stage1.items[stage1.items.len - 1] != ' ') {
                        try stage1.append(ctx.allocator, ' ');
                    }
                    try stage1.append(ctx.allocator, c);
                    try stage1.append(ctx.allocator, ' ');
                    i = next_i;
                    if (cssVarOrEnvCallEndAtOperandStart(text, i)) |end_i| {
                        try stage1.appendSlice(ctx.allocator, text[i .. end_i + 1]);
                        i = end_i + 1;
                    }
                    continue;
                }
            }
        }
        try stage1.append(ctx.allocator, c);
        i += 1;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(ctx.allocator);

    i = 0;
    while (i < stage1.items.len) {
        if (i + 4 <= stage1.items.len and
            std.ascii.eqlIgnoreCase(stage1.items[i .. i + 3], "var") and
            stage1.items[i + 3] == '(')
        {
            const prev = previousNonWhitespaceIndex(stage1.items, i);
            if (prev) |p| {
                const pc = stage1.items[p];
                const needs_plus = !(isMathBinaryOperator(pc) or pc == '(');
                if (needs_plus) {
                    if (out.items.len != 0 and out.items[out.items.len - 1] != ' ') {
                        try out.append(ctx.allocator, ' ');
                    }
                    try out.appendSlice(ctx.allocator, "+ ");
                }
            }
            try out.appendSlice(ctx.allocator, stage1.items[i .. i + 4]);
            i += 4;
            continue;
        }
        try out.append(ctx.allocator, stage1.items[i]);
        i += 1;
    }

    const rendered = try out.toOwnedSlice(ctx.allocator);
    defer ctx.allocator.free(rendered);
    return unwrapOuterParensForCssMathArg(ctx, rendered);
}

fn renderCssMathArg(ctx: *BuiltinContext, arg: Value) BuiltinError![]u8 {
    if (coerceMathNumberValue(ctx, arg)) |coerced| {
        const coerced_text = try valueToCssString(ctx, coerced);
        defer ctx.allocator.free(coerced_text);
        return normalizeCssMathArgText(ctx, coerced_text);
    } else |err| switch (err) {
        error.BuiltinType => {},
        else => return err,
    }

    const rendered = try valueToCssString(ctx, arg);
    defer ctx.allocator.free(rendered);
    const unwrapped = try unwrapCalcWrapperForMathArg(ctx.allocator, rendered);
    defer if (unwrapped.ptr != rendered.ptr) ctx.allocator.free(unwrapped);
    return normalizeCssMathArgText(ctx, unwrapped);
}

/// When a math-builtin (min/max/clamp/abs/etc.) arg is a single `calc(X)` call
/// string, Dart Sass unwraps the outer `calc(`...`)` at serialization.
///   calc(1 + 2px)      -> 1 + 2px
///   calc(var(--x))     -> (var(--x))   [single var/env keeps parens]
///   calc(1 * 2) + 3px  -> unchanged    (not a single top-level calc call)
fn unwrapCalcWrapperForMathArg(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const u8 {
    var end: usize = text.len;
    while (end > 0 and std.ascii.isWhitespace(text[end - 1])) : (end -= 1) {}
    var start: usize = 0;
    while (start < end and std.ascii.isWhitespace(text[start])) : (start += 1) {}
    const t = text[start..end];
    if (t.len < 6) return text;
    if (!(t[0] == 'c' or t[0] == 'C') or
        !(t[1] == 'a' or t[1] == 'A') or
        !(t[2] == 'l' or t[2] == 'L') or
        !(t[3] == 'c' or t[3] == 'C') or
        t[4] != '(') return text;
    if (t[t.len - 1] != ')') return text;
    var depth: u32 = 1;
    var i: usize = 5;
    while (i < t.len - 1) : (i += 1) {
        if (t[i] == '(') depth += 1;
        if (t[i] == ')') {
            depth -= 1;
            if (depth == 0) return text;
        }
    }
    if (depth != 1) return text;
    const inner = std.mem.trim(u8, t[5 .. t.len - 1], " \t\r\n");
    if (inner.len == 0) return text;
    if (isSingleVarOrEnvCall(inner)) {
        const buf = try allocator.alloc(u8, inner.len + 2);
        buf[0] = '(';
        @memcpy(buf[1 .. inner.len + 1], inner);
        buf[inner.len + 1] = ')';
        return buf;
    }
    return allocator.dupe(u8, inner);
}

fn isSingleVarOrEnvCall(text: []const u8) bool {
    if (text.len < 5) return false;
    var name_end: usize = 0;
    while (name_end < text.len and (std.ascii.isAlphabetic(text[name_end]) or text[name_end] == '-' or text[name_end] == '_')) : (name_end += 1) {}
    if (name_end == 0 or name_end >= text.len or text[name_end] != '(') return false;
    const name = text[0..name_end];
    if (!std.ascii.eqlIgnoreCase(name, "var") and !std.ascii.eqlIgnoreCase(name, "env")) return false;
    if (text[text.len - 1] != ')') return false;
    var depth: u32 = 1;
    var i: usize = name_end + 1;
    while (i < text.len - 1) : (i += 1) {
        if (text[i] == '(') depth += 1;
        if (text[i] == ')') {
            depth -= 1;
            if (depth == 0) return false;
        }
    }
    return depth == 1;
}

fn buildCssMathCall(ctx: *BuiltinContext, name: []const u8, args: []const Value) BuiltinError!Value {
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(ctx.allocator);

    try text.appendSlice(ctx.allocator, name);
    try text.append(ctx.allocator, '(');
    for (args, 0..) |arg, i| {
        if (i != 0) try text.appendSlice(ctx.allocator, ", ");
        const rendered = try renderCssMathArg(ctx, arg);
        defer ctx.allocator.free(rendered);
        try text.appendSlice(ctx.allocator, rendered);
    }
    try text.append(ctx.allocator, ')');

    const id = try internString(ctx, text.items);
    return Value.string(id, false);
}

fn consumeNumberPrefix(text: []const u8) ?usize {
    var i: usize = 0;
    if (text.len == 0) return null;
    if (text[i] == '+' or text[i] == '-') i += 1;

    var int_digits: usize = 0;
    while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
        int_digits += 1;
    }

    var frac_digits: usize = 0;
    if (i < text.len and text[i] == '.') {
        i += 1;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
            frac_digits += 1;
        }
    }

    if (int_digits == 0 and frac_digits == 0) return null;

    if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
        var j = i + 1;
        if (j < text.len and (text[j] == '+' or text[j] == '-')) j += 1;

        var exp_digits: usize = 0;
        while (j < text.len and std.ascii.isDigit(text[j])) : (j += 1) {
            exp_digits += 1;
        }
        if (exp_digits > 0) i = j;
    }

    return i;
}

fn hasTopLevelMulOrDiv(text: []const u8) bool {
    var depth: usize = 0;
    var in_string: u8 = 0;
    var escaped = false;

    for (text) |c| {
        if (in_string != 0) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (c == in_string) {
                in_string = 0;
            }
            continue;
        }

        switch (c) {
            '\'', '"' => in_string = c,
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                if (depth > 0) depth -= 1;
            },
            '*', '/' => if (depth == 0) return true,
            else => {},
        }
    }
    return false;
}

fn previousNonWhitespace(text: []const u8, index: usize) ?u8 {
    var i = index;
    while (i > 0) {
        i -= 1;
        if (!std.ascii.isWhitespace(text[i])) return text[i];
    }
    return null;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphabetic(c) or std.ascii.isDigit(c) or c == '_' or c == '-';
}

fn hasTopLevelModulo(text: []const u8) bool {
    var depth: usize = 0;
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
        if (c == '(' or c == '[' or c == '{') {
            depth += 1;
            continue;
        }
        if ((c == ')' or c == ']' or c == '}') and depth > 0) {
            depth -= 1;
            continue;
        }
        if (depth != 0 or c != '%') continue;

        const prev = previousNonWhitespace(text, i) orelse continue;
        var j = i + 1;
        while (j < text.len and std.ascii.isWhitespace(text[j])) : (j += 1) {}
        if (j >= text.len) continue;
        const next = text[j];

        const prev_is_operand = std.ascii.isDigit(prev) or
            prev == ')' or prev == ']' or prev == '}' or
            prev == '.' or isIdentChar(prev);
        const next_is_operand = std.ascii.isDigit(next) or
            next == '$' or next == '(' or next == '[' or next == '{' or
            next == '.' or next == '-' or isIdentChar(next);
        if (prev_is_operand and next_is_operand) return true;
    }
    return false;
}

fn valueHasComplexCalculationText(ctx: *BuiltinContext, value: Value) BuiltinError!bool {
    if (value.kind() == .calc_fragment or value.kind() == .interp_fragment) {
        const rendered = try valueToCssString(ctx, value);
        defer ctx.allocator.free(rendered);
        const trimmed = std.mem.trim(u8, rendered, " \t\n\r");
        return hasTopLevelMulOrDiv(trimmed);
    }
    if (value.isString()) {
        if (value.stringQuoted(ctx.string_flags_pool.items)) return false;
        const raw = std.mem.trim(u8, ctx.intern_pool.get(value.stringIntern()), " \t\n\r");
        return hasTopLevelMulOrDiv(raw);
    }
    return false;
}

fn valueHasTopLevelModulo(ctx: *BuiltinContext, value: Value) BuiltinError!bool {
    if (value.kind() == .calc_fragment or value.kind() == .interp_fragment) {
        const rendered = try valueToCssString(ctx, value);
        defer ctx.allocator.free(rendered);
        const trimmed = std.mem.trim(u8, rendered, " \t\n\r");
        return hasTopLevelModulo(trimmed);
    }
    if (value.isString()) {
        if (value.stringQuoted(ctx.string_flags_pool.items)) return false;
        const raw = std.mem.trim(u8, ctx.intern_pool.get(value.stringIntern()), " \t\n\r");
        return hasTopLevelModulo(raw);
    }
    return false;
}

fn coerceMathNumberStringValue(ctx: *BuiltinContext, value: Value) BuiltinError!?Value {
    if (value.kind() != .string or value.stringQuoted(ctx.string_flags_pool.items)) return null;

    const raw = ctx.intern_pool.get(value.stringIntern());
    const trimmed = std.mem.trim(u8, raw, " \t\n\r");
    if (trimmed.len == 0) return null;
    const token = std.mem.trim(u8, stripMatchingQuotes(trimmed), " \t\n\r");
    if (token.len == 0) return null;

    if (parseCssMathConstantIdent(token)) |constant| {
        return Value.numberUnitless(constant);
    }

    const number_end = consumeNumberPrefix(token) orelse return null;
    const number_text = token[0..number_end];
    const rest = std.mem.trim(u8, token[number_end..], " \t\n\r");

    const parsed = std.fmt.parseFloat(f64, number_text) catch return null;
    if (rest.len == 0) return Value.numberUnitless(parsed);

    if (std.mem.findAny(u8, rest, " \t\n\r()*/+") != null) return null;
    const unit_id = try internString(ctx, rest);
    return try Value.number(parsed, unit_id, ctx.number_pool, ctx.allocator);
}

fn coerceSimpleAddSubNumberExpression(ctx: *BuiltinContext, value: Value) BuiltinError!?Value {
    if (value.kind() == .number) return try normalizeGeneratedNumberUnit(ctx, value);
    if (try coerceMathNumberStringValue(ctx, value)) |parsed| return try normalizeGeneratedNumberUnit(ctx, parsed);

    var rendered_owned: ?[]const u8 = null;
    defer if (rendered_owned) |owned| ctx.allocator.free(owned);
    const raw0: []const u8 = switch (value.kind()) {
        .string => blk: {
            if (value.stringQuoted(ctx.string_flags_pool.items)) return null;
            break :blk ctx.intern_pool.get(value.stringIntern());
        },
        .calc_fragment, .interp_fragment => blk: {
            const rendered = try valueToCssString(ctx, value);
            rendered_owned = rendered;
            break :blk rendered;
        },
        else => return null,
    };

    var raw = std.mem.trim(u8, shared.stripCalcArgMarker(raw0), " \t\n\r");
    while (raw.len >= 2 and raw[0] == '(' and raw[raw.len - 1] == ')') {
        raw = std.mem.trim(u8, raw[1 .. raw.len - 1], " \t\n\r");
    }
    if (raw.len == 0 or std.mem.findAny(u8, raw, "*/(),") != null) return null;

    var i: usize = 0;
    var total: f64 = 0.0;
    var base_unit: ?[]const u8 = null;
    var saw_term = false;
    var saw_op = false;
    var sign: f64 = 1.0;

    while (true) {
        while (i < raw.len and std.ascii.isWhitespace(raw[i])) : (i += 1) {}
        if (i >= raw.len) break;
        if (raw[i] == '+' or raw[i] == '-') {
            sign = if (raw[i] == '-') -1.0 else 1.0;
            saw_op = true;
            i += 1;
            while (i < raw.len and std.ascii.isWhitespace(raw[i])) : (i += 1) {}
        } else if (saw_term) {
            return null;
        }

        const term_start = i;
        const number_end_rel = consumeNumberPrefix(raw[term_start..]) orelse return null;
        const number_end = term_start + number_end_rel;
        const parsed = std.fmt.parseFloat(f64, raw[term_start..number_end]) catch return null;
        i = number_end;

        const unit_start = i;
        while (i < raw.len and raw[i] != '+' and raw[i] != '-') : (i += 1) {}
        const unit = std.mem.trim(u8, raw[unit_start..i], " \t\n\r");
        if (std.mem.findAny(u8, unit, " \t\n\r()") != null) return null;
        const value_num = sign * parsed;
        if (!saw_term) {
            base_unit = if (unit.len == 0) null else unit;
            total = value_num;
            saw_term = true;
        } else if (base_unit) |base| {
            if (unit.len == 0) return null;
            total += sign * (convertUnit(parsed, unit, base) orelse return null);
        } else {
            if (unit.len != 0) return null;
            total += value_num;
        }
        sign = 1.0;
    }

    if (!saw_term or !saw_op) return null;
    const unit_id = if (base_unit) |unit| try internString(ctx, unit) else InternId.none;
    return try Value.number(total, unit_id, ctx.number_pool, ctx.allocator);
}

fn unwrapLegacyRoundNumberishExpr(text: []const u8) []const u8 {
    var t = std.mem.trim(u8, shared.stripCalcArgMarker(text), " \t\n\r");
    while (hasOuterWrappingParens(t)) {
        t = std.mem.trim(u8, t[1 .. t.len - 1], " \t\n\r");
    }
    if (t.len > 5 and std.ascii.startsWithIgnoreCase(t, "calc(") and t[t.len - 1] == ')') {
        const inner = t[5 .. t.len - 1];
        if (hasOuterWrappingParens(t)) {
            return std.mem.trim(u8, inner, " \t\n\r");
        }
    }
    return t;
}

fn parseLegacyRoundNumberToken(ctx: *BuiltinContext, raw: []const u8) BuiltinError!?Value {
    var token = std.mem.trim(u8, raw, " \t\n\r");
    while (hasOuterWrappingParens(token)) {
        token = std.mem.trim(u8, token[1 .. token.len - 1], " \t\n\r");
    }
    if (token.len == 0) return null;
    const id = try internString(ctx, token);
    return coerceMathNumberStringValue(ctx, Value.string(id, false));
}

const LegacyRoundNumericParser = struct {
    text: []const u8,
    pos: usize = 0,

    fn skipWs(self: *LegacyRoundNumericParser) void {
        while (self.pos < self.text.len and switch (self.text[self.pos]) {
            ' ', '\t', '\n', '\r' => true,
            else => false,
        }) : (self.pos += 1) {}
    }

    fn startsWithIgnoreCaseAt(self: *const LegacyRoundNumericParser, needle: []const u8) bool {
        if (self.pos + needle.len > self.text.len) return false;
        return std.ascii.eqlIgnoreCase(self.text[self.pos .. self.pos + needle.len], needle);
    }

    fn parse(self: *LegacyRoundNumericParser) ?f64 {
        const value = self.parseAddSub() orelse return null;
        self.skipWs();
        if (self.pos != self.text.len) return null;
        return value;
    }

    fn parseAddSub(self: *LegacyRoundNumericParser) ?f64 {
        var value = self.parseMulDiv() orelse return null;
        while (true) {
            self.skipWs();
            if (self.pos >= self.text.len) return value;
            const op = self.text[self.pos];
            if (op != '+' and op != '-') return value;
            self.pos += 1;
            const rhs = self.parseMulDiv() orelse return null;
            if (op == '+') {
                value += rhs;
            } else {
                value -= rhs;
            }
        }
    }

    fn parseMulDiv(self: *LegacyRoundNumericParser) ?f64 {
        var value = self.parseUnary() orelse return null;
        while (true) {
            self.skipWs();
            if (self.pos >= self.text.len) return value;
            const op = self.text[self.pos];
            if (op != '*' and op != '/') return value;
            self.pos += 1;
            const rhs = self.parseUnary() orelse return null;
            if (op == '*') {
                value *= rhs;
            } else {
                value /= rhs;
            }
        }
    }

    fn parseUnary(self: *LegacyRoundNumericParser) ?f64 {
        self.skipWs();
        if (self.pos < self.text.len and (self.text[self.pos] == '+' or self.text[self.pos] == '-')) {
            const neg = self.text[self.pos] == '-';
            self.pos += 1;
            const value = self.parseUnary() orelse return null;
            return if (neg) -value else value;
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *LegacyRoundNumericParser) ?f64 {
        self.skipWs();
        if (self.pos >= self.text.len) return null;

        if (self.text[self.pos] == '(') {
            self.pos += 1;
            const value = self.parseAddSub() orelse return null;
            self.skipWs();
            if (self.pos >= self.text.len or self.text[self.pos] != ')') return null;
            self.pos += 1;
            return value;
        }

        if (self.startsWithIgnoreCaseAt("calc(")) {
            self.pos += "calc(".len;
            const value = self.parseAddSub() orelse return null;
            self.skipWs();
            if (self.pos >= self.text.len or self.text[self.pos] != ')') return null;
            self.pos += 1;
            return value;
        }

        const start = self.pos;
        const num_end = consumeNumberPrefix(self.text[start..]) orelse return null;
        self.pos = start + num_end;
        const value = std.fmt.parseFloat(f64, self.text[start..self.pos]) catch return null;
        if (self.pos < self.text.len) {
            const c = self.text[self.pos];
            if (std.ascii.isAlphabetic(c) or c == '%' or c == '_' or c == '-') return null;
        }
        return value;
    }
};

fn parseLegacyRoundUnitlessNumericExpr(raw: []const u8) ?Value {
    var parser: LegacyRoundNumericParser = .{ .text = raw };
    const value = parser.parse() orelse return null;
    return Value.numberUnitless(value);
}

fn combineLegacyRoundAddSub(
    ctx: *BuiltinContext,
    lhs: Value,
    rhs: Value,
    is_sub: bool,
) BuiltinError!?Value {
    if (lhs.kind() != .number or rhs.kind() != .number) return null;

    const rhs_value = if (is_sub) -rhs.asF64(ctx.number_pool) else rhs.asF64(ctx.number_pool);
    const lhs_unit = unitSlice(ctx, lhs.unitId(ctx.number_pool));
    const rhs_unit = unitSlice(ctx, rhs.unitId(ctx.number_pool));

    if (lhs_unit == null and rhs_unit == null) {
        return Value.numberUnitless(lhs.asF64(ctx.number_pool) + rhs_value);
    }
    if (lhs_unit == null) {
        return try numberLike(ctx, lhs.asF64(ctx.number_pool) + rhs_value, rhs.unitId(ctx.number_pool));
    }
    if (rhs_unit == null) {
        return try numberLike(ctx, lhs.asF64(ctx.number_pool) + rhs_value, lhs.unitId(ctx.number_pool));
    }
    if (std.ascii.eqlIgnoreCase(lhs_unit.?, rhs_unit.?)) {
        return try numberLike(ctx, lhs.asF64(ctx.number_pool) + rhs_value, lhs.unitId(ctx.number_pool));
    }
    if (knownCalculationUnitsIncompatible(lhs_unit, rhs_unit)) {
        return error.SassError;
    }
    const converted_rhs = convertUnit(rhs_value, rhs_unit, lhs_unit) orelse return null;
    return try numberLike(ctx, lhs.asF64(ctx.number_pool) + converted_rhs, lhs.unitId(ctx.number_pool));
}

fn parseLegacyRoundAdditiveExpr(ctx: *BuiltinContext, raw_text: []const u8) BuiltinError!?Value {
    const text = unwrapLegacyRoundNumberishExpr(raw_text);
    if (text.len == 0) return null;
    if (try parseLegacyRoundNumberToken(ctx, text)) |single| return single;
    if (parseLegacyRoundUnitlessNumericExpr(text)) |numeric| return numeric;

    var result: ?Value = null;
    var seg_start: usize = 0;
    var pending_sub = false;
    var depth: usize = 0;
    var in_string: u8 = 0;
    var escaped = false;
    var saw_op = false;

    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        const at_end = i == text.len;
        if (!at_end) {
            const c = text[i];
            if (in_string != 0) {
                if (escaped) {
                    escaped = false;
                } else if (c == '\\') {
                    escaped = true;
                } else if (c == in_string) {
                    in_string = 0;
                }
                continue;
            }
            switch (c) {
                '"', '\'' => {
                    in_string = c;
                    continue;
                },
                '(' => {
                    depth += 1;
                    continue;
                },
                ')' => {
                    if (depth == 0) return null;
                    depth -= 1;
                    continue;
                },
                '+', '-' => {
                    if (depth != 0) continue;
                    if (i == seg_start) continue;
                    const prev = text[i - 1];
                    if (prev == 'e' or prev == 'E') continue;
                },
                else => continue,
            }
        }

        if (depth != 0) return null;
        const raw_segment = std.mem.trim(u8, text[seg_start..i], " \t\n\r");
        const segment = parseLegacyRoundNumberToken(ctx, raw_segment) catch |err| switch (err) {
            error.SassError => return err,
            else => return err,
        } orelse return null;
        const signed_segment = if (pending_sub)
            try numberLike(ctx, -segment.asF64(ctx.number_pool), segment.unitId(ctx.number_pool))
        else
            segment;
        if (result) |current| {
            result = (try combineLegacyRoundAddSub(ctx, current, signed_segment, false)) orelse return null;
        } else {
            result = signed_segment;
        }

        if (at_end) break;
        saw_op = true;
        pending_sub = text[i] == '-';
        seg_start = i + 1;
    }

    if (!saw_op) return null;
    return result;
}

fn simplifyUnitFactors(
    numerators: *std.ArrayListUnmanaged([]const u8),
    denominators: *std.ArrayListUnmanaged([]const u8),
) void {
    var i: usize = 0;
    while (i < numerators.items.len) {
        var removed = false;
        var j: usize = 0;
        while (j < denominators.items.len) : (j += 1) {
            if (std.ascii.eqlIgnoreCase(numerators.items[i], denominators.items[j])) {
                _ = numerators.orderedRemove(i);
                _ = denominators.orderedRemove(j);
                removed = true;
                break;
            }
        }
        if (!removed) i += 1;
    }
}

fn appendJoinedUnits(
    buf: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    units: []const []const u8,
) BuiltinError!void {
    var total: usize = 0;
    for (units, 0..) |unit, i| {
        if (i != 0) total += 1;
        total += unit.len;
    }
    try buf.ensureUnusedCapacity(alloc, total);
    for (units, 0..) |unit, i| {
        if (i != 0) buf.appendAssumeCapacity('*');
        buf.appendSliceAssumeCapacity(unit);
    }
}

fn splitAndAppendUnitFactors(
    alloc: std.mem.Allocator,
    target: *std.ArrayListUnmanaged([]const u8),
    raw_text: []const u8,
) BuiltinError!void {
    const text = std.mem.trim(u8, raw_text, " \t\n\r");
    if (text.len == 0) return;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i != text.len and text[i] != '*') continue;
        const raw_part = std.mem.trim(u8, text[start..i], " \t\n\r");
        if (raw_part.len == 0) return error.BuiltinType;

        var part = raw_part;
        if (consumeNumberPrefix(raw_part)) |num_end| {
            const maybe_unit = std.mem.trim(u8, raw_part[num_end..], " \t\n\r");
            if (maybe_unit.len == 0) {
                start = i + 1;
                continue;
            }
            part = maybe_unit;
        }
        try target.append(alloc, part);
        start = i + 1;
    }
}

fn appendUnitTextFactors(
    alloc: std.mem.Allocator,
    unit_text: []const u8,
    numerators: *std.ArrayListUnmanaged([]const u8),
    denominators: *std.ArrayListUnmanaged([]const u8),
    divide: bool,
) BuiltinError!void {
    const text = std.mem.trim(u8, unit_text, " \t\n\r");
    if (text.len == 0) return;

    if (std.mem.endsWith(u8, text, "^-1")) {
        const base = std.mem.trim(u8, text[0 .. text.len - 3], " \t\n\r");
        if (base.len == 0) return error.BuiltinType;
        if (base[0] == '(' and base[base.len - 1] == ')') {
            const inner = base[1 .. base.len - 1];
            if (divide) {
                try splitAndAppendUnitFactors(alloc, numerators, inner);
            } else {
                try splitAndAppendUnitFactors(alloc, denominators, inner);
            }
        } else {
            if (divide) {
                try numerators.append(alloc, base);
            } else {
                try denominators.append(alloc, base);
            }
        }
        return;
    }

    if (std.mem.findScalar(u8, text, '/')) |slash_idx| {
        const left = std.mem.trim(u8, text[0..slash_idx], " \t\n\r");
        const right_raw = std.mem.trim(u8, text[slash_idx + 1 ..], " \t\n\r");
        if (left.len == 0 or right_raw.len == 0) return error.BuiltinType;
        const right = if (right_raw[0] == '(' and right_raw[right_raw.len - 1] == ')')
            right_raw[1 .. right_raw.len - 1]
        else
            right_raw;
        if (divide) {
            try splitAndAppendUnitFactors(alloc, denominators, left);
            try splitAndAppendUnitFactors(alloc, numerators, right);
        } else {
            try splitAndAppendUnitFactors(alloc, numerators, left);
            try splitAndAppendUnitFactors(alloc, denominators, right);
        }
        return;
    }

    if (divide) {
        try splitAndAppendUnitFactors(alloc, denominators, text);
    } else {
        try splitAndAppendUnitFactors(alloc, numerators, text);
    }
}

fn buildUnitDescriptionFromFactors(
    ctx: *BuiltinContext,
    numerators: []const []const u8,
    denominators: []const []const u8,
) BuiltinError![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(ctx.allocator);

    if (numerators.len == 0 and denominators.len == 0) {
        return ctx.allocator.dupe(u8, "") catch error.OutOfMemory;
    }

    if (numerators.len == 0) {
        if (denominators.len == 1) {
            try out.appendSlice(ctx.allocator, denominators[0]);
            try out.appendSlice(ctx.allocator, "^-1");
            return out.toOwnedSlice(ctx.allocator);
        }
        try out.append(ctx.allocator, '(');
        try appendJoinedUnits(&out, ctx.allocator, denominators);
        try out.appendSlice(ctx.allocator, ")^-1");
        return out.toOwnedSlice(ctx.allocator);
    }

    try appendJoinedUnits(&out, ctx.allocator, numerators);
    if (denominators.len == 0) return out.toOwnedSlice(ctx.allocator);

    try out.append(ctx.allocator, '/');
    if (denominators.len > 1) try out.append(ctx.allocator, '(');
    try appendJoinedUnits(&out, ctx.allocator, denominators);
    if (denominators.len > 1) try out.append(ctx.allocator, ')');
    return out.toOwnedSlice(ctx.allocator);
}

fn normalizeGeneratedNumberUnit(ctx: *BuiltinContext, value: Value) BuiltinError!Value {
    if (value.kind() != .number) return value;

    const unit_id = value.unitId(ctx.number_pool);
    if (unit_id == .none) return value;

    const unit_text = ctx.intern_pool.get(unit_id);
    if (!isGeneratedUnitDescription(unit_text)) return value;

    var numerators: std.ArrayListUnmanaged([]const u8) = .empty;
    defer numerators.deinit(ctx.allocator);
    var denominators: std.ArrayListUnmanaged([]const u8) = .empty;
    defer denominators.deinit(ctx.allocator);

    appendUnitTextFactors(ctx.allocator, unit_text, &numerators, &denominators, false) catch |err| switch (err) {
        error.BuiltinType => return value,
        else => return err,
    };
    simplifyUnitFactors(&numerators, &denominators);

    const normalized = buildUnitDescriptionFromFactors(ctx, numerators.items, denominators.items) catch |err| switch (err) {
        error.BuiltinType => return value,
        else => return err,
    };
    defer ctx.allocator.free(normalized);

    if (normalized.len == 0) return Value.numberUnitless(value.asF64(ctx.number_pool));
    if (std.ascii.eqlIgnoreCase(normalized, unit_text)) return value;

    const normalized_id = try internString(ctx, normalized);
    return try Value.number(value.asF64(ctx.number_pool), normalized_id, ctx.number_pool, ctx.allocator);
}

fn coerceMathNumberValue(ctx: *BuiltinContext, value: Value) BuiltinError!Value {
    if (value.kind() == .number) return normalizeGeneratedNumberUnit(ctx, value);
    if (try coerceMathNumberStringValue(ctx, value)) |parsed| return normalizeGeneratedNumberUnit(ctx, parsed);
    if (value.kind() == .calc_fragment or value.kind() == .interp_fragment) {
        const rendered = try valueToCssString(ctx, value);
        defer ctx.allocator.free(rendered);
        const text_id = try internString(ctx, rendered);
        if (try coerceMathNumberStringValue(ctx, Value.string(text_id, false))) |parsed| {
            return normalizeGeneratedNumberUnit(ctx, parsed);
        }
    }
    if (value.kind() != .list or value.listComma(ctx.list_meta_pool.items) or value.listBracketed(ctx.list_meta_pool.items) or !value.listSlash(ctx.list_meta_pool.items)) return error.BuiltinType;

    const items = ctx.list_pool.items[value.listHandle()];
    if (items.len < 2) return error.BuiltinType;

    const first = try coerceMathNumberValue(ctx, items[0]);
    var numeric = first.asF64(ctx.number_pool);

    var numerators: std.ArrayListUnmanaged([]const u8) = .empty;
    defer numerators.deinit(ctx.allocator);
    var denominators: std.ArrayListUnmanaged([]const u8) = .empty;
    defer denominators.deinit(ctx.allocator);

    if (first.unitId(ctx.number_pool) != .none) {
        try appendUnitTextFactors(ctx.allocator, ctx.intern_pool.get(first.unitId(ctx.number_pool)), &numerators, &denominators, false);
    }

    for (items[1..]) |item| {
        const divisor = try coerceMathNumberValue(ctx, item);
        numeric /= divisor.asF64(ctx.number_pool);
        if (divisor.unitId(ctx.number_pool) != .none) {
            try appendUnitTextFactors(ctx.allocator, ctx.intern_pool.get(divisor.unitId(ctx.number_pool)), &numerators, &denominators, true);
        }
    }

    simplifyUnitFactors(&numerators, &denominators);
    const desc = try buildUnitDescriptionFromFactors(ctx, numerators.items, denominators.items);
    defer ctx.allocator.free(desc);
    if (desc.len == 0) return Value.numberUnitless(numeric);
    const unit_id = try internString(ctx, desc);
    return normalizeGeneratedNumberUnit(ctx, try Value.number(numeric, unit_id, ctx.number_pool, ctx.allocator));
}

fn parseUnitDescriptionFromExpression(ctx: *BuiltinContext, expr: []const u8) BuiltinError![]u8 {
    var numerators: std.ArrayListUnmanaged([]const u8) = .empty;
    defer numerators.deinit(ctx.allocator);
    var denominators: std.ArrayListUnmanaged([]const u8) = .empty;
    defer denominators.deinit(ctx.allocator);

    var start: usize = 0;
    var op: u8 = '*';
    var i: usize = 0;
    while (true) {
        const at_end = i == expr.len;
        const is_op = !at_end and (expr[i] == '*' or expr[i] == '/');
        if (at_end or is_op) {
            const term = std.mem.trim(u8, expr[start..i], " \t\n\r");
            if (term.len == 0) return error.BuiltinType;
            const number_end = consumeNumberPrefix(term) orelse return error.BuiltinType;
            const unit = std.mem.trim(u8, term[number_end..], " \t\n\r");
            if (unit.len != 0) {
                if (op == '/') {
                    try denominators.append(ctx.allocator, unit);
                } else {
                    try numerators.append(ctx.allocator, unit);
                }
            }

            if (at_end) break;
            op = expr[i];
            start = i + 1;
        }
        i += 1;
    }

    simplifyUnitFactors(&numerators, &denominators);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(ctx.allocator);

    if (numerators.items.len == 0 and denominators.items.len == 0) {
        return ctx.allocator.dupe(u8, "") catch error.OutOfMemory;
    }

    if (numerators.items.len == 0) {
        if (denominators.items.len == 1) {
            try out.appendSlice(ctx.allocator, denominators.items[0]);
            try out.appendSlice(ctx.allocator, "^-1");
            return out.toOwnedSlice(ctx.allocator);
        }
        try out.append(ctx.allocator, '(');
        try appendJoinedUnits(&out, ctx.allocator, denominators.items);
        try out.appendSlice(ctx.allocator, ")^-1");
        return out.toOwnedSlice(ctx.allocator);
    }

    try appendJoinedUnits(&out, ctx.allocator, numerators.items);
    if (denominators.items.len == 0) return out.toOwnedSlice(ctx.allocator);

    try out.append(ctx.allocator, '/');
    if (denominators.items.len > 1) try out.append(ctx.allocator, '(');
    try appendJoinedUnits(&out, ctx.allocator, denominators.items);
    if (denominators.items.len > 1) try out.append(ctx.allocator, ')');

    return out.toOwnedSlice(ctx.allocator);
}

fn unitDescriptionFromValue(ctx: *BuiltinContext, value: Value) BuiltinError![]u8 {
    if (value.isNumber()) {
        const unit = value.unitId(ctx.number_pool);
        if (unit == .none) return try ctx.allocator.dupe(u8, "");
        return try ctx.allocator.dupe(u8, ctx.intern_pool.get(unit));
    }
    if (value.kind() == .list) {
        const coerced = try coerceMathNumberValue(ctx, value);
        const unit = coerced.unitId(ctx.number_pool);
        if (unit == .none) return try ctx.allocator.dupe(u8, "");
        return try ctx.allocator.dupe(u8, ctx.intern_pool.get(unit));
    }
    if (value.isString()) {
        if (value.stringQuoted(ctx.string_flags_pool.items)) return error.BuiltinType;
        const expr = ctx.intern_pool.get(value.stringIntern());
        return try parseUnitDescriptionFromExpression(ctx, expr);
    }
    return error.BuiltinType;
}

fn minmaxVariadic(ctx: *BuiltinContext, args: []const Value, is_min: bool, css_name: []const u8) BuiltinError!Value {
    if (args.len == 0) return badArity(1, args.len);
    const preserve_css = shouldPreserveCssMathCall(ctx, args);

    const values = try ctx.allocator.alloc(Value, args.len);
    defer ctx.allocator.free(values);
    for (args, 0..) |arg, idx| {
        values[idx] = (try coerceSimpleAddSubNumberExpression(ctx, arg)) orelse arg;
    }

    var first_unknown_unit: ?[]const u8 = null;
    var saw_multiple_unknown_units = false;
    var saw_unitless_after_unknown_pair = false;

    for (values) |arg| {
        if (arg.kind() != .number) {
            if (preserve_css) return buildCssMathCall(ctx, css_name, args);
            return error.BuiltinType;
        }
        const arg_unit = unitSlice(ctx, arg.unitId(ctx.number_pool));
        if (arg_unit != null and isGeneratedUnitDescription(arg_unit.?)) return error.SassError;
        if (arg_unit) |unit| {
            if (unitCategory(unit) == .unknown) {
                if (first_unknown_unit) |prev_unit| {
                    if (!std.ascii.eqlIgnoreCase(prev_unit, unit)) saw_multiple_unknown_units = true;
                } else {
                    first_unknown_unit = unit;
                }
            }
        } else if (saw_multiple_unknown_units) {
            saw_unitless_after_unknown_pair = true;
        }
    }
    if (saw_unitless_after_unknown_pair) return error.SassError;

    const first = values[0];

    var best = first;
    var best_converted = first.asF64(ctx.number_pool);

    if (std.math.isNan(best_converted)) {
        return numberLike(ctx, std.math.nan(f64), first.unitId(ctx.number_pool));
    }

    for (values[1..]) |arg| {
        const best_unit = unitSlice(ctx, best.unitId(ctx.number_pool));
        const arg_unit = unitSlice(ctx, arg.unitId(ctx.number_pool));
        if (cssMathUnitsNeedPassthrough(best_unit, arg_unit, false)) {
            return buildCssMathCall(ctx, css_name, args);
        }
        const converted = minMaxComparableValue(ctx, arg, best.unitId(ctx.number_pool)) catch |e| switch (e) {
            error.BuiltinArity => {
                if (preserve_css) return buildCssMathCall(ctx, css_name, args);
                return error.BuiltinArity;
            },
            else => return e,
        };
        if (std.math.isNan(converted)) {
            return numberLike(ctx, std.math.nan(f64), arg.unitId(ctx.number_pool));
        }

        if ((is_min and converted < best_converted) or (!is_min and converted > best_converted)) {
            best = arg;
            best_converted = best.asF64(ctx.number_pool);
        }
    }

    return best;
}

pub fn math_abs(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{"number"}, 1);
    const arg = bound[0].?;
    const named = arg_names.len > 0 and arg_names[0] != .none;

    const number = coerceMathNumberValue(ctx, arg) catch |err| switch (err) {
        error.BuiltinType => {
            if (!named and valueLooksLikeCssMathArg(ctx, arg)) return buildCssMathCall(ctx, "abs", args);
            return reportArgumentTypeMismatch(ctx, "number", arg, "number");
        },
        else => return err,
    };
    if (number.kind() == .number) {
        const unit = if (number.unitId(ctx.number_pool) == .none) null else ctx.intern_pool.get(number.unitId(ctx.number_pool));
        if (unit != null and std.ascii.eqlIgnoreCase(unit.?, "%")) {
            if (ctx.deprecation_opts) |opts| {
                try deprecation_mod.emitDeprecation(opts, .abs_percent, "abs() with percentage is deprecated", "", 0, 0);
            }
        }
    }
    return numberLike(ctx, @abs(number.asF64(ctx.number_pool)), number.unitId(ctx.number_pool));
}

pub fn math_floor(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{"number"}, 1);
    const arg = bound[0].?;
    const number = coerceMathNumberValue(ctx, arg) catch |err| switch (err) {
        error.BuiltinType => {
            if (valueLooksLikeCssMathArg(ctx, arg)) return buildCssMathCall(ctx, "floor", args);
            return reportArgumentTypeMismatch(ctx, "number", arg, "number");
        },
        else => return err,
    };
    return numberLike(ctx, canonicalizeSignedZero(@floor(number.asF64(ctx.number_pool))), number.unitId(ctx.number_pool));
}

pub fn math_ceil(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{"number"}, 1);
    const arg = bound[0].?;
    const number = coerceMathNumberValue(ctx, arg) catch |err| switch (err) {
        error.BuiltinType => {
            if (valueLooksLikeCssMathArg(ctx, arg)) return buildCssMathCall(ctx, "ceil", args);
            return reportArgumentTypeMismatch(ctx, "number", arg, "number");
        },
        else => return err,
    };
    return numberLike(ctx, canonicalizeSignedZero(@ceil(number.asF64(ctx.number_pool))), number.unitId(ctx.number_pool));
}

pub fn math_round(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    if (args.len == 0 or args.len > 3) return error.SassError;

    var first_named: ?usize = null;
    var has_named = false;
    for (0..args.len) |idx| {
        const name_id: InternId = if (idx < arg_names.len) arg_names[idx] else .none;
        if (name_id == .none) {
            if (first_named != null) return error.SassError;
            continue;
        }
        has_named = true;
        if (first_named == null) first_named = idx;
    }

    var strategy: RoundStrategy = .nearest;
    var has_strategy = false;
    var number_idx: ?usize = null;
    var step_idx: ?usize = null;
    var offset_idx: ?usize = null;

    if (!has_named) {
        if (args.len == 1) {
            number_idx = 0;
        } else if (args.len == 2) {
            if (try parseRoundStrategyValue(ctx, args[0])) |parsed| {
                strategy = parsed;
                has_strategy = true;
                number_idx = 1;
            } else {
                number_idx = 0;
                step_idx = 1;
            }
        } else {
            std.debug.assert(args.len == 3);
            var strategy_slot: ?usize = null;
            var multiple_strategies = false;
            for (args, 0..) |arg, idx| {
                if (try parseRoundStrategyValue(ctx, arg)) |_| {
                    if (strategy_slot != null) {
                        multiple_strategies = true;
                        break;
                    }
                    strategy_slot = idx;
                }
            }
            if (multiple_strategies) return error.SassError;
            if (strategy_slot) |sidx| {
                strategy = (try parseRoundStrategyValue(ctx, args[sidx])).?;
                has_strategy = true;
                var remaining: [2]usize = undefined;
                var ri: usize = 0;
                for (0..3) |idx| {
                    if (idx == sidx) continue;
                    remaining[ri] = idx;
                    ri += 1;
                }
                number_idx = remaining[0];
                step_idx = remaining[1];
            } else {
                if (shouldPreserveCssMathCall(ctx, args)) return buildCssMathCall(ctx, "round", args);
                return error.SassError;
            }
        }
    } else {
        const keyword_start = first_named orelse args.len;
        var positional_numeric: [3]usize = undefined;
        var positional_numeric_count: usize = 0;
        for (0..keyword_start) |idx| {
            if (try parseRoundStrategyValue(ctx, args[idx])) |parsed| {
                if (has_strategy) return error.SassError;
                has_strategy = true;
                strategy = parsed;
                continue;
            }
            if (positional_numeric_count >= positional_numeric.len) return error.SassError;
            positional_numeric[positional_numeric_count] = idx;
            positional_numeric_count += 1;
        }
        if (positional_numeric_count > 0) number_idx = positional_numeric[0];
        if (positional_numeric_count > 1) step_idx = positional_numeric[1];
        if (positional_numeric_count > 2) offset_idx = positional_numeric[2];

        for (keyword_start..args.len) |idx| {
            const name_id: InternId = if (idx < arg_names.len) arg_names[idx] else .none;
            if (name_id == .none) return error.SassError;
            var key_buf: [32]u8 = undefined;
            const norm = normalizeRoundKeywordName(ctx.intern_pool.get(name_id), &key_buf);
            const param = classifyRoundKeyword(norm) orelse return error.SassError;
            if (param == .strategy) {
                if (has_strategy) return error.SassError;
                const parsed = (try parseRoundStrategyValue(ctx, args[idx])) orelse return error.SassError;
                strategy = parsed;
                has_strategy = true;
            } else if (param == .number) {
                if (number_idx != null) return error.SassError;
                number_idx = idx;
            } else if (param == .step) {
                if (step_idx != null) return error.SassError;
                step_idx = idx;
            } else if (param == .offset) {
                if (offset_idx != null) return error.SassError;
                offset_idx = idx;
            }
        }
    }

    const num_idx = number_idx orelse return error.SassError;
    const named_single_number = args.len == 1 and has_named;

    if (has_strategy and step_idx == null) {
        if (valueLooksLikeCssMathArg(ctx, args[num_idx])) return buildCssMathCall(ctx, "round", args);
        return error.SassError;
    }

    const number = parsed_number: {
        break :parsed_number coerceMathNumberValue(ctx, args[num_idx]) catch |err| switch (err) {
            error.BuiltinType => {
                if (!named_single_number and args.len == 1) {
                    const raw_arg = args[num_idx];
                    const rendered = if (raw_arg.isString() and !raw_arg.stringQuoted(ctx.string_flags_pool.items))
                        try ctx.allocator.dupe(u8, ctx.intern_pool.get(raw_arg.stringIntern()))
                    else if (raw_arg.kind() == .calc_fragment or raw_arg.kind() == .interp_fragment)
                        try valueToCssString(ctx, raw_arg)
                    else
                        null;
                    if (rendered) |text| {
                        defer ctx.allocator.free(text);
                        if (try parseLegacyRoundAdditiveExpr(ctx, text)) |parsed| {
                            break :parsed_number parsed;
                        }
                        return buildCssMathCall(ctx, "round", args);
                    }
                }
                const preserve_single = args.len == 1 and (try roundSingleArgShouldPreserveCssCall(ctx, args[num_idx]));
                if (!named_single_number and (valueLooksLikeCssMathArg(ctx, args[num_idx]) or preserve_single)) {
                    return buildCssMathCall(ctx, "round", args);
                }
                return if (args.len == 1) error.BuiltinType else error.SassError;
            },
            else => return err,
        };
    };

    if (!has_strategy and step_idx == null and offset_idx == null) {
        return numberLike(ctx, applyPrecisionRound(number.asF64(ctx.number_pool), 0, .nearest), number.unitId(ctx.number_pool));
    }

    const num_unit = unitSlice(ctx, number.unitId(ctx.number_pool));

    const step_value: f64 = if (step_idx) |idx| blk: {
        const step_number = coerceMathNumberValue(ctx, args[idx]) catch |err| switch (err) {
            error.BuiltinType => {
                if (valueLooksLikeCssMathArg(ctx, args[idx])) return buildCssMathCall(ctx, "round", args);
                return error.SassError;
            },
            else => return err,
        };

        const step_unit_id = step_number.unitId(ctx.number_pool);
        const step_unit = unitSlice(ctx, step_unit_id);

        if ((num_unit != null and isGeneratedUnitDescription(num_unit.?)) or
            (step_unit != null and isGeneratedUnitDescription(step_unit.?)))
        {
            return error.SassError;
        }

        if ((num_unit != null) != (step_unit != null)) return error.SassError;

        if (num_unit != null and step_unit != null and
            !unitsCompatibleForComparable(ctx, number, step_number))
        {
            if (knownCalculationUnitsIncompatible(num_unit, step_unit)) return error.SassError;
            return buildCssMathCall(ctx, "round", args);
        }

        if (num_unit != null and step_unit != null) {
            break :blk convertUnit(step_number.asF64(ctx.number_pool), step_unit, num_unit) orelse return error.SassError;
        }
        break :blk step_number.asF64(ctx.number_pool);
    } else 1.0;

    if (step_value == 0) return numberLike(ctx, std.math.nan(f64), number.unitId(ctx.number_pool));
    const offset_value: f64 = if (offset_idx) |idx| blk: {
        const offset_number = coerceMathNumberValue(ctx, args[idx]) catch |err| switch (err) {
            error.BuiltinType => {
                if (valueLooksLikeCssMathArg(ctx, args[idx])) return buildCssMathCall(ctx, "round", args);
                return error.SassError;
            },
            else => return err,
        };

        const offset_unit_id = offset_number.unitId(ctx.number_pool);
        const offset_unit = unitSlice(ctx, offset_unit_id);

        if ((num_unit != null and isGeneratedUnitDescription(num_unit.?)) or
            (offset_unit != null and isGeneratedUnitDescription(offset_unit.?)))
        {
            return error.SassError;
        }

        if ((num_unit != null) != (offset_unit != null)) return error.SassError;

        if (num_unit != null and offset_unit != null and
            !unitsCompatibleForComparable(ctx, number, offset_number))
        {
            if (knownCalculationUnitsIncompatible(num_unit, offset_unit)) return error.SassError;
            return buildCssMathCall(ctx, "round", args);
        }

        if (num_unit != null and offset_unit != null) {
            break :blk convertUnit(offset_number.asF64(ctx.number_pool), offset_unit, num_unit) orelse return error.SassError;
        }
        break :blk offset_number.asF64(ctx.number_pool);
    } else 0.0;

    const rounded_base = roundWithStrategy(number.asF64(ctx.number_pool) - offset_value, step_value, strategy);
    const rounded = if (offset_idx == null) rounded_base else rounded_base + offset_value;
    return numberLike(ctx, rounded, number.unitId(ctx.number_pool));
}

pub fn math_round_namespaced(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    if (args.len != 1) return error.SassError;
    const bound = bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{"number"}, 1) catch |err| switch (err) {
        error.BuiltinArity => return error.SassError,
        else => return err,
    };
    const arg = bound[0].?;
    const number = coerceMathNumberValue(ctx, arg) catch |err| switch (err) {
        error.BuiltinType => return reportArgumentTypeMismatch(ctx, "number", arg, "number"),
        else => return err,
    };
    return numberLike(ctx, applyPrecisionRound(number.asF64(ctx.number_pool), 0, .nearest), number.unitId(ctx.number_pool));
}

pub fn math_min(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    ensureNoNamedArgs(args, arg_names) catch return error.SassError;
    return minmaxVariadic(ctx, args, true, "min") catch |err| switch (err) {
        error.BuiltinArity => error.SassError,
        else => err,
    };
}

pub fn math_max(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    ensureNoNamedArgs(args, arg_names) catch return error.SassError;
    return minmaxVariadic(ctx, args, false, "max") catch |err| switch (err) {
        error.BuiltinArity => error.SassError,
        else => err,
    };
}

pub fn math_div(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{ "number1", "number2" }, 2);
    const lhs = bound[0].?;
    const rhs = bound[1].?;

    if (lhs.kind() == .number and rhs.kind() == .number) {
        const a = lhs.asF64(ctx.number_pool);
        const b = rhs.asF64(ctx.number_pool);
        const ua = lhs.unitId(ctx.number_pool);
        const ub = rhs.unitId(ctx.number_pool);

        var numerator = a;
        var out_unit: InternId = .none;

        if (ua != .none and ub != .none) {
            const ua_slice = unitSlice(ctx, ua).?;
            const ub_slice = unitSlice(ctx, ub).?;
            if (std.ascii.eqlIgnoreCase(ua_slice, ub_slice)) {
                out_unit = .none;
            } else if (convertUnit(1.0, ub_slice, ua_slice) != null) {
                if (convertUnit(a, ua_slice, ub_slice)) |converted| numerator = converted;
                out_unit = .none;
            } else {
                var numerators: std.ArrayListUnmanaged([]const u8) = .empty;
                defer numerators.deinit(ctx.allocator);
                var denominators: std.ArrayListUnmanaged([]const u8) = .empty;
                defer denominators.deinit(ctx.allocator);
                try appendUnitTextFactors(ctx.allocator, ua_slice, &numerators, &denominators, false);
                try appendUnitTextFactors(ctx.allocator, ub_slice, &numerators, &denominators, true);
                simplifyUnitFactors(&numerators, &denominators);
                const desc = try buildUnitDescriptionFromFactors(ctx, numerators.items, denominators.items);
                defer ctx.allocator.free(desc);
                if (desc.len != 0) out_unit = try internString(ctx, desc);
            }
        } else if (ua == .none and ub != .none) {
            const ub_slice = unitSlice(ctx, ub).?;
            var numerators: std.ArrayListUnmanaged([]const u8) = .empty;
            defer numerators.deinit(ctx.allocator);
            var denominators: std.ArrayListUnmanaged([]const u8) = .empty;
            defer denominators.deinit(ctx.allocator);
            try appendUnitTextFactors(ctx.allocator, ub_slice, &numerators, &denominators, true);
            simplifyUnitFactors(&numerators, &denominators);
            const desc = try buildUnitDescriptionFromFactors(ctx, numerators.items, denominators.items);
            defer ctx.allocator.free(desc);
            if (desc.len != 0) out_unit = try internString(ctx, desc);
        } else if (ua != .none and ub == .none) {
            out_unit = ua;
        }

        const value = try numberLike(ctx, numerator / b, out_unit);
        return normalizeGeneratedNumberUnit(ctx, value);
    }
    const sa = try valueToCssString(ctx, lhs);
    defer ctx.allocator.free(sa);
    const sb = try valueToCssString(ctx, rhs);
    defer ctx.allocator.free(sb);
    const text = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ sa, sb });
    defer ctx.allocator.free(text);
    const id = try internString(ctx, text);
    return Value.string(id, false);
}

pub fn math_percentage(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try expectArity(args, 1);
    if (args[0].kind() != .number) return reportArgumentTypeMismatch(ctx, "number", args[0], "number");
    if (args[0].unitId(ctx.number_pool) != .none) return error.BuiltinType;
    const n = args[0].asF64(ctx.number_pool);
    const pct = try internString(ctx, "%");
    return try Value.number(n * 100.0, pct, ctx.number_pool, ctx.allocator);
}

pub fn math_unit(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try expectArity(args, 1);
    const desc = unitDescriptionFromValue(ctx, args[0]) catch |err| switch (err) {
        error.BuiltinType => return reportArgumentTypeMismatch(ctx, "number", args[0], "number"),
        else => return err,
    };
    defer ctx.allocator.free(desc);
    const id = try internString(ctx, desc);
    return Value.string(id, true);
}

pub fn math_is_unitless(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try expectArity(args, 1);
    const desc = unitDescriptionFromValue(ctx, args[0]) catch |err| switch (err) {
        error.BuiltinType => return reportArgumentTypeMismatch(ctx, "number", args[0], "number"),
        else => return err,
    };
    defer ctx.allocator.free(desc);
    return if (desc.len == 0) Value.true_v else Value.false_v;
}

pub fn math_compatible(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try expectArity(args, 2);
    const a = coerceMathNumberValue(ctx, args[0]) catch |err| switch (err) {
        error.BuiltinType => return reportArgumentTypeMismatch(ctx, "number1", args[0], "number"),
        else => return err,
    };
    const b = coerceMathNumberValue(ctx, args[1]) catch |err| switch (err) {
        error.BuiltinType => return reportArgumentTypeMismatch(ctx, "number2", args[1], "number"),
        else => return err,
    };
    return if (unitsCompatibleForComparable(ctx, a, b)) Value.true_v else Value.false_v;
}

pub fn math_exp(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try expectArity(args, 1);
    const arg = args[0];
    if (try valueHasTopLevelModulo(ctx, arg)) return error.SassError;

    const number = coerceMathNumberValue(ctx, arg) catch |err| switch (err) {
        error.BuiltinType => {
            if (valueLooksLikeCssMathArg(ctx, arg)) return buildCssMathCall(ctx, "exp", args);
            return error.SassError;
        },
        else => return err,
    };

    if (number.unitId(ctx.number_pool) != .none) return error.SassError;
    return Value.numberUnitless(canonicalizeSignedZero(@exp(number.asF64(ctx.number_pool))));
}

pub fn math_sign(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try expectArity(args, 1);
    const arg = args[0];
    if (try valueHasTopLevelModulo(ctx, arg)) return error.SassError;
    const complex = try valueHasComplexCalculationText(ctx, arg);

    const number = coerceMathNumberValue(ctx, arg) catch |err| switch (err) {
        error.BuiltinType => {
            if (valueLooksLikeCssMathArg(ctx, arg)) return buildCssMathCall(ctx, "sign", args);
            if (complex) return error.SassError;
            return error.SassError;
        },
        else => return err,
    };

    const raw = number.asF64(ctx.number_pool);
    const result: f64 = if (std.math.isNan(raw))
        std.math.nan(f64)
    else if (raw > 0)
        1.0
    else if (raw < 0)
        -1.0
    else if (std.math.isNegativeZero(raw))
        -0.0
    else
        0.0;

    return numberLike(ctx, result, number.unitId(ctx.number_pool));
}

pub fn math_mod(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    if (args.len != 2) return error.SassError;
    const bound = bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{ "y", "x" }, 2) catch return error.SassError;
    const y_arg = bound[0] orelse return error.SassError;
    const x_arg = bound[1] orelse return error.SassError;

    const preserve_css = shouldPreserveCssMathCall(ctx, args);
    const y = coerceMathNumberValue(ctx, y_arg) catch |err| switch (err) {
        error.BuiltinType => {
            if (preserve_css or valueLooksLikeCssMathArg(ctx, y_arg) or
                y_arg.kind() == .list or
                (y_arg.kind() == .string and !y_arg.stringQuoted(ctx.string_flags_pool.items)))
            {
                return buildCssMathCall(ctx, "mod", args);
            }
            return error.SassError;
        },
        else => return err,
    };
    const x = coerceMathNumberValue(ctx, x_arg) catch |err| switch (err) {
        error.BuiltinType => {
            if (preserve_css or valueLooksLikeCssMathArg(ctx, x_arg) or
                x_arg.kind() == .list or
                (x_arg.kind() == .string and !x_arg.stringQuoted(ctx.string_flags_pool.items)))
            {
                return buildCssMathCall(ctx, "mod", args);
            }
            return error.SassError;
        },
        else => return err,
    };

    const y_unit = unitSlice(ctx, y.unitId(ctx.number_pool));
    const x_unit = unitSlice(ctx, x.unitId(ctx.number_pool));
    if ((y_unit != null and isGeneratedUnitDescription(y_unit.?)) or
        (x_unit != null and isGeneratedUnitDescription(x_unit.?)))
    {
        return error.SassError;
    }
    if ((y_unit == null) != (x_unit == null)) return error.SassError;

    if (y_unit != null and x_unit != null and !unitsCompatibleForComparable(ctx, y, x)) {
        if (knownCalculationUnitsIncompatible(y_unit, x_unit)) return error.SassError;
        return buildCssMathCall(ctx, "mod", args);
    }

    const y_value = y.asF64(ctx.number_pool);
    const x_value = if (y.unitId(ctx.number_pool) == .none)
        x.asF64(ctx.number_pool)
    else
        convertNumberToTargetUnit(ctx, x, y.unitId(ctx.number_pool)) catch {
            if (knownCalculationUnitsIncompatible(y_unit, x_unit)) return error.SassError;
            return buildCssMathCall(ctx, "mod", args);
        };
    if (x_value == 0) return numberLike(ctx, std.math.nan(f64), y.unitId(ctx.number_pool));

    if (std.math.isInf(y_value)) {
        return numberLike(ctx, std.math.nan(f64), y.unitId(ctx.number_pool));
    }

    if (std.math.isInf(x_value)) {
        if (y_value == 0 or (std.math.signbit(y_value) != std.math.signbit(x_value))) {
            return numberLike(ctx, std.math.nan(f64), y.unitId(ctx.number_pool));
        }
        return numberLike(ctx, y_value, y.unitId(ctx.number_pool));
    }

    const raw = if (y_value == 0 and std.math.signbit(y_value))
        -@as(f64, 0)
    else
        sassModulo(y_value, x_value);

    const result = if (raw == 0 and !(y_value == 0 and std.math.signbit(y_value))) @as(f64, 0) else raw;
    return numberLike(ctx, result, y.unitId(ctx.number_pool));
}

pub fn math_rem(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    if (args.len != 2) return error.SassError;
    const bound = bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{ "y", "x" }, 2) catch return error.SassError;
    const y_arg = bound[0] orelse return error.SassError;
    const x_arg = bound[1] orelse return error.SassError;

    const preserve_css = shouldPreserveCssMathCall(ctx, args);
    const y = coerceMathNumberValue(ctx, y_arg) catch |err| switch (err) {
        error.BuiltinType => {
            if (preserve_css or valueLooksLikeCssMathArg(ctx, y_arg) or
                y_arg.kind() == .list or
                (y_arg.kind() == .string and !y_arg.stringQuoted(ctx.string_flags_pool.items)))
            {
                return buildCssMathCall(ctx, "rem", args);
            }
            return error.SassError;
        },
        else => return err,
    };
    const x = coerceMathNumberValue(ctx, x_arg) catch |err| switch (err) {
        error.BuiltinType => {
            if (preserve_css or valueLooksLikeCssMathArg(ctx, x_arg) or
                x_arg.kind() == .list or
                (x_arg.kind() == .string and !x_arg.stringQuoted(ctx.string_flags_pool.items)))
            {
                return buildCssMathCall(ctx, "rem", args);
            }
            return error.SassError;
        },
        else => return err,
    };

    const y_unit = unitSlice(ctx, y.unitId(ctx.number_pool));
    const x_unit = unitSlice(ctx, x.unitId(ctx.number_pool));
    if ((y_unit != null and isGeneratedUnitDescription(y_unit.?)) or
        (x_unit != null and isGeneratedUnitDescription(x_unit.?)))
    {
        return error.SassError;
    }
    if ((y_unit == null) != (x_unit == null)) return error.SassError;

    if (y_unit != null and x_unit != null and !unitsCompatibleForComparable(ctx, y, x)) {
        if (knownCalculationUnitsIncompatible(y_unit, x_unit)) return error.SassError;
        return buildCssMathCall(ctx, "rem", args);
    }

    const y_value = y.asF64(ctx.number_pool);
    const x_value = if (y.unitId(ctx.number_pool) == .none)
        x.asF64(ctx.number_pool)
    else
        convertNumberToTargetUnit(ctx, x, y.unitId(ctx.number_pool)) catch {
            if (knownCalculationUnitsIncompatible(y_unit, x_unit)) return error.SassError;
            return buildCssMathCall(ctx, "rem", args);
        };
    if (x_value == 0) return numberLike(ctx, std.math.nan(f64), y.unitId(ctx.number_pool));

    if (std.math.isInf(x_value)) {
        if (!std.math.isInf(y_value) and !std.math.isNan(y_value)) {
            return numberLike(ctx, y_value, y.unitId(ctx.number_pool));
        }
        return numberLike(ctx, std.math.nan(f64), y.unitId(ctx.number_pool));
    }

    if (std.math.isInf(y_value)) {
        return numberLike(ctx, std.math.nan(f64), y.unitId(ctx.number_pool));
    }

    const raw = y_value - @trunc(y_value / x_value) * x_value;
    const result = if (raw == 0 and std.math.signbit(y_value)) -@as(f64, 0) else raw;
    return numberLike(ctx, result, y.unitId(ctx.number_pool));
}

pub fn math_random(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    if (args.len > 1) return badArity(1, args.len);
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{"limit"}, 0);

    if (bound[0]) |limit_value| {
        if (limit_value.kind() == .nil) {
            return Value.numberUnitless(randomUnitless(ctx.random_state));
        }

        if (limit_value.kind() != .number) return reportArgumentTypeMismatch(ctx, "limit", limit_value, "number");
        const raw = limit_value.asF64(ctx.number_pool);
        if (!std.math.isFinite(raw)) return error.BuiltinType;

        const rounded = @round(raw);
        if (@abs(raw - rounded) > 1e-10) return error.BuiltinType;
        if (rounded <= 0) return error.BuiltinType;

        const max_u64_f: f64 = @floatFromInt(std.math.maxInt(u64));
        if (rounded > max_u64_f) return error.BuiltinType;

        const limit: u64 = @intFromFloat(rounded);
        if (limit == 1) return Value.numberUnitless(1);

        const rand = randomNext(ctx.random_state);
        const value: f64 = @floatFromInt((rand % limit) + 1);
        return Value.numberUnitless(value);
    }

    return Value.numberUnitless(randomUnitless(ctx.random_state));
}

pub fn math_clamp(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    var has_named = false;
    const named_len = @min(args.len, arg_names.len);
    for (arg_names[0..named_len]) |name_id| {
        if (name_id != .none) {
            has_named = true;
            break;
        }
    }

    if (args.len == 1) {
        if (has_named) return error.SassError;
        const single = args[0];
        if ((single.kind() == .string and !single.stringQuoted(ctx.string_flags_pool.items)) or valueLooksLikeCssMathArg(ctx, single)) {
            return buildCssMathCall(ctx, "clamp", args);
        }
        return error.SassError;
    }
    if (args.len != 3) return error.SassError;

    const bound = bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{ "min", "number", "max" }, 3) catch return error.SassError;

    const min_raw = bound[0] orelse return error.SassError;
    const number_raw = bound[1] orelse return error.SassError;
    const max_raw = bound[2] orelse return error.SassError;
    if (try valueHasComplexCalculationText(ctx, min_raw) or
        try valueHasComplexCalculationText(ctx, number_raw) or
        try valueHasComplexCalculationText(ctx, max_raw))
    {
        return error.SassError;
    }
    const preserve_css = shouldPreserveCssMathCall(ctx, args);

    const min_value = coerceMathNumberValue(ctx, min_raw) catch |err| switch (err) {
        error.BuiltinType => {
            if (preserve_css or valueLooksLikeCssMathArg(ctx, min_raw) or
                (min_raw.kind() == .string and !min_raw.stringQuoted(ctx.string_flags_pool.items)))
            {
                return buildCssMathCall(ctx, "clamp", args);
            }
            return error.SassError;
        },
        else => return err,
    };
    const number = coerceMathNumberValue(ctx, number_raw) catch |err| switch (err) {
        error.BuiltinType => {
            if (preserve_css or valueLooksLikeCssMathArg(ctx, number_raw) or
                (number_raw.kind() == .string and !number_raw.stringQuoted(ctx.string_flags_pool.items)))
            {
                return buildCssMathCall(ctx, "clamp", args);
            }
            return error.SassError;
        },
        else => return err,
    };
    const max_value = coerceMathNumberValue(ctx, max_raw) catch |err| switch (err) {
        error.BuiltinType => {
            if (preserve_css or valueLooksLikeCssMathArg(ctx, max_raw) or
                (max_raw.kind() == .string and !max_raw.stringQuoted(ctx.string_flags_pool.items)))
            {
                return buildCssMathCall(ctx, "clamp", args);
            }
            return error.SassError;
        },
        else => return err,
    };

    const min_unit = min_value.unitId(ctx.number_pool);
    const number_unit = number.unitId(ctx.number_pool);
    const max_unit = max_value.unitId(ctx.number_pool);
    const min_unit_slice = unitSlice(ctx, min_unit);
    const number_unit_slice = unitSlice(ctx, number_unit);
    const max_unit_slice = unitSlice(ctx, max_unit);

    if ((min_unit_slice != null and isGeneratedUnitDescription(min_unit_slice.?)) or
        (number_unit_slice != null and isGeneratedUnitDescription(number_unit_slice.?)) or
        (max_unit_slice != null and isGeneratedUnitDescription(max_unit_slice.?)))
    {
        return error.SassError;
    }

    if ((min_unit == .none) != (number_unit == .none) or
        (min_unit == .none) != (max_unit == .none) or
        (number_unit == .none) != (max_unit == .none))
    {
        return error.SassError;
    }

    if (cssMathUnitsNeedPassthrough(min_unit_slice, number_unit_slice, false) or
        cssMathUnitsNeedPassthrough(min_unit_slice, max_unit_slice, false) or
        cssMathUnitsNeedPassthrough(number_unit_slice, max_unit_slice, false))
    {
        return buildCssMathCall(ctx, "clamp", args);
    }

    if (min_unit != .none and number_unit != .none) {
        _ = convertNumberToTargetUnit(ctx, min_value, number_unit) catch {
            if (!knownCalculationUnitsIncompatible(min_unit_slice, number_unit_slice)) {
                return buildCssMathCall(ctx, "clamp", args);
            }
            return error.SassError;
        };
    }
    if (min_unit != .none and max_unit != .none) {
        _ = convertNumberToTargetUnit(ctx, max_value, min_unit) catch {
            if (!knownCalculationUnitsIncompatible(min_unit_slice, max_unit_slice)) {
                return buildCssMathCall(ctx, "clamp", args);
            }
            return error.SassError;
        };
    }
    if (number_unit != .none and max_unit != .none) {
        _ = convertNumberToTargetUnit(ctx, max_value, number_unit) catch {
            if (!knownCalculationUnitsIncompatible(number_unit_slice, max_unit_slice)) {
                return buildCssMathCall(ctx, "clamp", args);
            }
            return error.SassError;
        };
    }

    const min_converted = if (number_unit == .none)
        min_value.asF64(ctx.number_pool)
    else
        convertNumberToTargetUnit(ctx, min_value, number_unit) catch {
            if (preserve_css) return buildCssMathCall(ctx, "clamp", args);
            return error.SassError;
        };
    const max_converted = if (number_unit == .none)
        max_value.asF64(ctx.number_pool)
    else
        convertNumberToTargetUnit(ctx, max_value, number_unit) catch {
            if (preserve_css) return buildCssMathCall(ctx, "clamp", args);
            return error.SassError;
        };
    const raw_value = number.asF64(ctx.number_pool);

    if (std.math.isNan(min_converted) or std.math.isNan(raw_value) or std.math.isNan(max_converted)) {
        return numberLike(ctx, std.math.nan(f64), number_unit);
    }

    const clamped = @max(min_converted, @min(raw_value, max_converted));
    if (clamped <= min_converted) return min_value;
    if (clamped >= max_converted) return max_value;
    return numberLike(ctx, clamped, number_unit);
}

pub fn math_sqrt(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try expectArity(args, 1);
    const arg = args[0];
    if (try valueHasTopLevelModulo(ctx, arg)) return error.SassError;
    const complex = try valueHasComplexCalculationText(ctx, arg);

    const number = coerceMathNumberValue(ctx, arg) catch |err| switch (err) {
        error.BuiltinType => {
            if (valueLooksLikeCssMathArg(ctx, arg)) return buildCssMathCall(ctx, "sqrt", args);
            if (complex) return error.SassError;
            return error.SassError;
        },
        else => return err,
    };

    if (number.unitId(ctx.number_pool) != .none) return error.SassError;
    return Value.numberUnitless(canonicalizeSignedZero(@sqrt(number.asF64(ctx.number_pool))));
}

pub fn math_pow(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{ "base", "exponent" }, 2);
    const base_arg = bound[0].?;
    const exponent_arg = bound[1].?;
    if (try valueHasTopLevelModulo(ctx, base_arg) or try valueHasTopLevelModulo(ctx, exponent_arg)) {
        return error.SassError;
    }

    const base = coerceMathNumberValue(ctx, base_arg) catch |err| switch (err) {
        error.BuiltinType => {
            if (valueLooksLikeCssMathArg(ctx, base_arg) or valueLooksLikeCssMathArg(ctx, exponent_arg)) {
                return buildCssMathCall(ctx, "pow", args);
            }
            return error.SassError;
        },
        else => return err,
    };
    const exponent = coerceMathNumberValue(ctx, exponent_arg) catch |err| switch (err) {
        error.BuiltinType => {
            if (valueLooksLikeCssMathArg(ctx, base_arg) or valueLooksLikeCssMathArg(ctx, exponent_arg)) {
                return buildCssMathCall(ctx, "pow", args);
            }
            return error.SassError;
        },
        else => return err,
    };

    if (base.unitId(ctx.number_pool) != .none or exponent.unitId(ctx.number_pool) != .none) return error.SassError;

    const base_v = base.asF64(ctx.number_pool);
    const exp_v = exponent.asF64(ctx.number_pool);
    var result = std.math.pow(f64, base_v, exp_v);
    if (@abs(base_v) <= 1e-9 or base_v == 0 or std.math.isInf(base_v)) {
        result = roundPowResult(result);
    }
    if (@abs(result) < 1e-12) result = 0;
    return Value.numberUnitless(canonicalizeSignedZero(result));
}

pub fn math_log(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    if (args.len < 1 or args.len > 2) return error.SassError;
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{ "number", "base" }, 1);
    const number_arg = bound[0].?;
    const base_arg = bound[1];
    if (try valueHasTopLevelModulo(ctx, number_arg)) return error.SassError;
    if (base_arg) |base| {
        if (base.kind() != .nil and try valueHasTopLevelModulo(ctx, base)) return error.SassError;
    }

    const number_complex = try valueHasComplexCalculationText(ctx, number_arg);
    const number_value = coerceMathNumberValue(ctx, number_arg) catch |err| switch (err) {
        error.BuiltinType => {
            if (valueLooksLikeCssMathArg(ctx, number_arg)) return buildCssMathCall(ctx, "log", args);
            if (number_complex) return error.SassError;
            return error.SassError;
        },
        else => return err,
    };
    if (number_value.unitId(ctx.number_pool) != .none) return error.SassError;
    const number = number_value.asF64(ctx.number_pool);

    if (base_arg) |base| {
        if (base.kind() == .nil) return Value.numberUnitless(canonicalizeSignedZero(@log(number)));

        const base_value = coerceMathNumberValue(ctx, base) catch |err| switch (err) {
            error.BuiltinType => {
                if (valueLooksLikeCssMathArg(ctx, number_arg) or valueLooksLikeCssMathArg(ctx, base)) {
                    return buildCssMathCall(ctx, "log", args);
                }
                return error.SassError;
            },
            else => return err,
        };
        if (base_value.unitId(ctx.number_pool) != .none) return error.SassError;
        return Value.numberUnitless(canonicalizeSignedZero(@log(number) / @log(base_value.asF64(ctx.number_pool))));
    }

    return Value.numberUnitless(canonicalizeSignedZero(@log(number)));
}

fn forwardTrig(
    ctx: *BuiltinContext,
    args: []const Value,
    comptime name: []const u8,
    comptime op: fn (f64) f64,
) BuiltinError!Value {
    try expectArity(args, 1);
    const arg = args[0];
    if (try valueHasTopLevelModulo(ctx, arg)) return error.SassError;
    const complex = try valueHasComplexCalculationText(ctx, arg);

    const number = coerceMathNumberValue(ctx, arg) catch |err| switch (err) {
        error.BuiltinType => {
            if (valueLooksLikeCssMathArg(ctx, arg)) return buildCssMathCall(ctx, name, args);
            if (complex) return error.SassError;
            return error.SassError;
        },
        else => return err,
    };
    if (number.unitId(ctx.number_pool) != .none) {
        const unit = unitSlice(ctx, number.unitId(ctx.number_pool)).?;
        if (unitCategory(unit) != .angle) return error.SassError;
    }
    const radians = convertAngleToRadians(number.asF64(ctx.number_pool), unitSlice(ctx, number.unitId(ctx.number_pool)));
    var result = op(radians);
    if (@abs(result) < 1e-10) result = 0;
    return Value.numberUnitless(canonicalizeSignedZero(result));
}

fn inverseTrig(
    ctx: *BuiltinContext,
    args: []const Value,
    comptime name: []const u8,
    comptime op: fn (f64) f64,
) BuiltinError!Value {
    try expectArity(args, 1);
    const arg = args[0];
    if (try valueHasTopLevelModulo(ctx, arg)) return error.SassError;
    const complex = try valueHasComplexCalculationText(ctx, arg);

    const number = coerceMathNumberValue(ctx, arg) catch |err| switch (err) {
        error.BuiltinType => {
            if (valueLooksLikeCssMathArg(ctx, arg)) return buildCssMathCall(ctx, name, args);
            if (complex) return error.SassError;
            return error.SassError;
        },
        else => return err,
    };
    if (number.unitId(ctx.number_pool) != .none) return error.SassError;
    const value = canonicalizeSignedZero(op(number.asF64(ctx.number_pool)) * 180.0 / std.math.pi);
    return numberToDeg(ctx, value);
}

fn fSin(x: f64) f64 {
    return @sin(x);
}
fn fCos(x: f64) f64 {
    return @cos(x);
}
fn fTan(x: f64) f64 {
    return @tan(x);
}
fn fAsin(x: f64) f64 {
    return std.math.asin(x);
}
fn fAcos(x: f64) f64 {
    return std.math.acos(x);
}
fn fAtan(x: f64) f64 {
    return std.math.atan(x);
}

pub fn math_sin(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    return forwardTrig(ctx, args, "sin", fSin);
}

pub fn math_cos(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    return forwardTrig(ctx, args, "cos", fCos);
}

pub fn math_tan(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    return forwardTrig(ctx, args, "tan", fTan);
}

pub fn math_asin(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    return inverseTrig(ctx, args, "asin", fAsin);
}

pub fn math_acos(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    return inverseTrig(ctx, args, "acos", fAcos);
}

pub fn math_atan(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    return inverseTrig(ctx, args, "atan", fAtan);
}

pub fn math_atan2(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    if (args.len != 2) return error.SassError;
    const bound = bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{ "y", "x" }, 2) catch return error.SassError;
    const y_arg = bound[0] orelse return error.SassError;
    const x_arg = bound[1] orelse return error.SassError;
    if (try valueHasTopLevelModulo(ctx, y_arg) or try valueHasTopLevelModulo(ctx, x_arg)) return error.SassError;

    const y_complex = try valueHasComplexCalculationText(ctx, y_arg);
    const x_complex = try valueHasComplexCalculationText(ctx, x_arg);
    if ((y_complex and try valueContainsPercentToken(ctx, x_arg)) or
        (x_complex and try valueContainsPercentToken(ctx, y_arg)))
    {
        return error.SassError;
    }

    const y_calc_like = valueLooksLikeCssMathArg(ctx, y_arg);
    const x_calc_like = valueLooksLikeCssMathArg(ctx, x_arg);

    const y = coerceMathNumberValue(ctx, y_arg) catch |err| switch (err) {
        error.BuiltinType => {
            if (y_calc_like or x_calc_like) return buildCssMathCall(ctx, "atan2", args);
            return error.SassError;
        },
        else => return err,
    };
    const x = coerceMathNumberValue(ctx, x_arg) catch |err| switch (err) {
        error.BuiltinType => {
            if (y_calc_like or x_calc_like) return buildCssMathCall(ctx, "atan2", args);
            return error.SassError;
        },
        else => return err,
    };

    const y_unit = y.unitId(ctx.number_pool);
    const x_unit = x.unitId(ctx.number_pool);
    const y_unit_slice = unitSlice(ctx, y_unit);
    const x_unit_slice = unitSlice(ctx, x_unit);

    if ((y_unit_slice != null and isGeneratedUnitDescription(y_unit_slice.?)) or
        (x_unit_slice != null and isGeneratedUnitDescription(x_unit_slice.?)))
    {
        return error.SassError;
    }

    if ((y_unit_slice != null and std.ascii.eqlIgnoreCase(y_unit_slice.?, "%")) or
        (x_unit_slice != null and std.ascii.eqlIgnoreCase(x_unit_slice.?, "%")))
    {
        return buildCssMathCall(ctx, "atan2", args);
    }

    if ((y_unit == .none) != (x_unit == .none)) return error.SassError;

    var x_value = x.asF64(ctx.number_pool);
    if (y_unit != .none and x_unit != y_unit) {
        x_value = convertNumberToTargetUnit(ctx, x, y_unit) catch {
            if (knownCalculationUnitsIncompatible(y_unit_slice, x_unit_slice)) return error.SassError;
            return buildCssMathCall(ctx, "atan2", args);
        };
    }

    const value = canonicalizeSignedZero(std.math.atan2(y.asF64(ctx.number_pool), x_value) * 180.0 / std.math.pi);
    return numberToDeg(ctx, value);
}

pub fn math_hypot(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    ensureNoNamedArgs(args, arg_names) catch return error.SassError;
    if (args.len == 0) return error.SassError;

    var preserve_css = shouldPreserveCssMathCall(ctx, args);
    var sum: f64 = 0;
    var result_unit: InternId = .none;
    var first = true;
    for (args) |arg| {
        if (try valueHasComplexCalculationText(ctx, arg)) return error.SassError;

        const number = coerceMathNumberValue(ctx, arg) catch |err| switch (err) {
            error.BuiltinType => {
                if (preserve_css or valueLooksLikeCssMathArg(ctx, arg) or
                    arg.kind() == .list or
                    (arg.kind() == .string and !arg.stringQuoted(ctx.string_flags_pool.items)))
                {
                    return buildCssMathCall(ctx, "hypot", args);
                }
                return error.SassError;
            },
            else => return err,
        };

        const number_unit_slice = unitSlice(ctx, number.unitId(ctx.number_pool));
        if (number_unit_slice != null and isGeneratedUnitDescription(number_unit_slice.?)) {
            return error.SassError;
        }

        if (!preserve_css and number_unit_slice != null and std.ascii.eqlIgnoreCase(number_unit_slice.?, "%")) {
            preserve_css = true;
        }
        if (preserve_css) continue;

        if (first) {
            first = false;
            result_unit = number.unitId(ctx.number_pool);
            const x = number.asF64(ctx.number_pool);
            sum += x * x;
            continue;
        }

        const arg_unit = number.unitId(ctx.number_pool);
        if ((arg_unit == .none) != (result_unit == .none)) {
            if (preserve_css) return buildCssMathCall(ctx, "hypot", args);
            return error.SassError;
        }

        const converted = if (result_unit == .none)
            number.asF64(ctx.number_pool)
        else
            convertNumberToTargetUnit(ctx, number, result_unit) catch {
                const result_unit_slice = unitSlice(ctx, result_unit);
                if (knownCalculationUnitsIncompatible(result_unit_slice, number_unit_slice)) return error.SassError;
                preserve_css = true;
                continue;
            };
        sum += converted * converted;
    }
    if (preserve_css) return buildCssMathCall(ctx, "hypot", args);
    return numberLike(ctx, canonicalizeSignedZero(@sqrt(sum)), result_unit);
}

const testing = std.testing;
const InternPool = intern_pool_mod.InternPool;
const ColorPool = shared.ColorPool;

const MathTestHarness = struct {
    allocator: std.mem.Allocator,
    intern_pool: InternPool,
    list_pool: std.ArrayListUnmanaged([]Value),
    color_pool: ColorPool,
    number_pool: shared.NumberPool,
    callable_payload_pool: shared.CallablePayloadPool,
    list_meta_pool: shared.ListMetaPool,
    string_flags_pool: shared.StringFlagsPool,
    random_state: u64,

    fn init(allocator: std.mem.Allocator) !MathTestHarness {
        return .{
            .allocator = allocator,
            .intern_pool = try InternPool.init(allocator),
            .list_pool = .empty,
            .color_pool = .empty,
            .number_pool = .empty,
            .callable_payload_pool = .empty,
            .list_meta_pool = .empty,
            .string_flags_pool = .empty,
            .random_state = random_seed_default,
        };
    }

    fn deinit(self: *MathTestHarness) void {
        for (self.list_pool.items) |items| self.allocator.free(items);
        self.list_pool.deinit(self.allocator);
        self.color_pool.deinit(self.allocator);
        self.number_pool.deinit(self.allocator);
        self.callable_payload_pool.deinit(self.allocator);
        self.list_meta_pool.deinit(self.allocator);
        self.string_flags_pool.deinit(self.allocator);
        self.intern_pool.deinit(self.allocator);
    }

    fn context(self: *MathTestHarness) BuiltinContext {
        return .{
            .allocator = self.allocator,
            .intern_pool = &self.intern_pool,
            .list_pool = &self.list_pool,
            .color_pool = &self.color_pool,
            .number_pool = &self.number_pool,
            .callable_payload_pool = &self.callable_payload_pool,
            .list_meta_pool = &self.list_meta_pool,
            .string_flags_pool = &self.string_flags_pool,
            .random_state = &self.random_state,
            .vm = @ptrFromInt(1),
        };
    }
};

test "math.round rejects quoted strategy value" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const strategy_id = try internString(&ctx, "nearest");
    const args = [_]Value{
        Value.string(strategy_id, true),
        Value.numberUnitless(0),
        Value.numberUnitless(0),
    };
    const names = [_]InternId{ .none, .none, .none };
    try testing.expectError(error.SassError, math_round(&ctx, &args, &names));
}

test "math.round nearest ties round away from zero" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const args = [_]Value{Value.numberUnitless(-2.5)};
    const names = [_]InternId{.none};
    const result = try math_round(&ctx, &args, &names);
    try testing.expectEqual(.number, result.kind());
    try testing.expectEqual(@as(f64, -3), result.asF64(ctx.number_pool));
}

test "css round nearest ties round away from zero" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const strategy_id = try internString(&ctx, "nearest");
    const args = [_]Value{
        Value.string(strategy_id, false),
        Value.numberUnitless(-2.5),
        Value.numberUnitless(1),
    };
    const names = [_]InternId{ .none, .none, .none };
    const result = try math_round(&ctx, &args, &names);
    try testing.expectEqual(.number, result.kind());
    try testing.expectEqual(@as(f64, -3), result.asF64(ctx.number_pool));
}

test "math.round preserves negative zero for infinite step" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const args = [_]Value{
        Value.numberUnitless(-5),
        Value.numberUnitless(std.math.inf(f64)),
    };
    const names = [_]InternId{ .none, .none };
    const result = try math_round(&ctx, &args, &names);
    try testing.expectEqual(.number, result.kind());
    try testing.expect(result.asF64(ctx.number_pool) == 0);
    try testing.expect(std.math.signbit(result.asF64(ctx.number_pool)));
}

test "math.round up strategy keeps negative-zero sign with infinite step" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const strategy_id = try internString(&ctx, "up");
    const args = [_]Value{
        Value.string(strategy_id, false),
        Value.numberUnitless(-10),
        Value.numberUnitless(std.math.inf(f64)),
    };
    const names = [_]InternId{ .none, .none, .none };
    const result = try math_round(&ctx, &args, &names);
    try testing.expectEqual(.number, result.kind());
    try testing.expect(result.asF64(ctx.number_pool) == 0);
    try testing.expect(std.math.signbit(result.asF64(ctx.number_pool)));
}

test "math.mod parses infinity identifier" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const infinity_id = try internString(&ctx, "infinity");
    const args = [_]Value{
        Value.numberUnitless(-10),
        Value.string(infinity_id, false),
    };
    const names = [_]InternId{ .none, .none };
    const result = try math_mod(&ctx, &args, &names);
    try testing.expectEqual(.number, result.kind());
    try testing.expect(std.math.isNan(result.asF64(ctx.number_pool)));
}

test "math.rem parses negative infinity identifier" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const neg_infinity_id = try internString(&ctx, "-infinity");
    const args = [_]Value{
        Value.numberUnitless(10),
        Value.string(neg_infinity_id, false),
    };
    const names = [_]InternId{ .none, .none };
    const result = try math_rem(&ctx, &args, &names);
    try testing.expectEqual(.number, result.kind());
    try testing.expectEqual(@as(f64, 10), result.asF64(ctx.number_pool));
}

test "math.clamp keeps single unquoted argument as css call" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const token_id = try internString(&ctx, "b");
    const args = [_]Value{Value.string(token_id, false)};
    const names = [_]InternId{.none};
    const result = try math_clamp(&ctx, &args, &names);
    try testing.expectEqual(.string, result.kind());
    try testing.expect(!result.stringQuoted(ctx.string_flags_pool.items));
    try testing.expectEqualStrings("clamp(b)", ctx.intern_pool.get(result.stringIntern()));
}

test "math.max zero args returns SassError" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    try testing.expectError(error.SassError, math_max(&ctx, &.{}, &.{}));
}

test "math.min incompatible units returns SassError" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const px = try internString(&ctx, "px");
    const s = try internString(&ctx, "s");
    const args = [_]Value{
        try Value.number(1, px, &harness.number_pool, harness.allocator),
        try Value.number(2, s, &harness.number_pool, harness.allocator),
    };
    const names = [_]InternId{ .none, .none };
    try testing.expectError(error.SassError, math_min(&ctx, &args, &names));
}

test "math.min preserves unknown unit mix as css call" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const em = try internString(&ctx, "em");
    const vw = try internString(&ctx, "vw");
    const args = [_]Value{
        try Value.number(14, em, &harness.number_pool, harness.allocator),
        try Value.number(35, vw, &harness.number_pool, harness.allocator),
    };
    const names = [_]InternId{ .none, .none };
    const result = try math_min(&ctx, &args, &names);
    try testing.expectEqual(.string, result.kind());
    try testing.expect(!result.stringQuoted(ctx.string_flags_pool.items));
    try testing.expectEqualStrings("min(14em, 35vw)", ctx.intern_pool.get(result.stringIntern()));
}

test "math.hypot zero args returns SassError" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    try testing.expectError(error.SassError, math_hypot(&ctx, &.{}, &.{}));
}

test "math.clamp rejects complex calculation text arguments" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const complex_id = try internString(&ctx, "1px * 1px");
    const args = [_]Value{
        Value.string(complex_id, false),
        Value.numberUnitless(2),
        Value.numberUnitless(3),
    };
    const names = [_]InternId{ .none, .none, .none };
    try testing.expectError(error.SassError, math_clamp(&ctx, &args, &names));
}

test "math.clamp preserves mixed viewport units as css call" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const px = try internString(&ctx, "px");
    const vh = try internString(&ctx, "vh");
    const args = [_]Value{
        try Value.number(200, px, &harness.number_pool, harness.allocator),
        try Value.number(50, vh, &harness.number_pool, harness.allocator),
        try Value.number(350, px, &harness.number_pool, harness.allocator),
    };
    const names = [_]InternId{ .none, .none, .none };
    const result = try math_clamp(&ctx, &args, &names);
    try testing.expectEqual(.string, result.kind());
    try testing.expect(!result.stringQuoted(ctx.string_flags_pool.items));
    try testing.expectEqualStrings("clamp(200px, 50vh, 350px)", ctx.intern_pool.get(result.stringIntern()));
}

test "math.hypot rejects complex calculation text arguments" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const complex_id = try internString(&ctx, "-7px / 4em");
    const args = [_]Value{
        Value.string(complex_id, false),
        Value.numberUnitless(1),
    };
    const names = [_]InternId{ .none, .none };
    try testing.expectError(error.SassError, math_hypot(&ctx, &args, &names));
}

test "math.exp preserves unresolved calculation as css function" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const expr_id = try internString(&ctx, "3px - var(--c)");
    const args = [_]Value{Value.string(expr_id, false)};
    const result = try math_exp(&ctx, &args);
    try testing.expectEqual(.string, result.kind());
    try testing.expect(!result.stringQuoted(ctx.string_flags_pool.items));
    try testing.expectEqualStrings("exp(3px - var(--c))", ctx.intern_pool.get(result.stringIntern()));
}

test "math.exp normalizes compact subtraction in css fallback" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const expr_id = try internString(&ctx, "3px-var(--c)");
    const args = [_]Value{Value.string(expr_id, false)};
    const result = try math_exp(&ctx, &args);
    try testing.expectEqual(.string, result.kind());
    try testing.expectEqualStrings("exp(3px - var(--c))", ctx.intern_pool.get(result.stringIntern()));
}

test "math.abs keeps named-argument type errors for css-like values" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const var_id = try internString(&ctx, "var(--c)");
    const number_name = try internString(&ctx, "$number");
    const args = [_]Value{Value.string(var_id, false)};
    const names = [_]InternId{number_name};
    try testing.expectError(error.BuiltinType, math_abs(&ctx, &args, &names));
}

test "math.sign supports NaN identifier and preserves units" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const nan_id = try internString(&ctx, "NaN");
    const nan_args = [_]Value{Value.string(nan_id, false)};
    const nan_result = try math_sign(&ctx, &nan_args);
    try testing.expectEqual(.number, nan_result.kind());
    try testing.expect(std.math.isNan(nan_result.asF64(ctx.number_pool)));

    const px = try internString(&ctx, "px");
    const unit_args = [_]Value{try Value.number(10, px, &harness.number_pool, harness.allocator)};
    const unit_result = try math_sign(&ctx, &unit_args);
    try testing.expectEqual(@as(f64, 1), unit_result.asF64(ctx.number_pool));
    try testing.expectEqual(px, unit_result.unitId(ctx.number_pool));
}

test "math.sqrt preserves unresolved calculation as css function" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const expr_id = try internString(&ctx, "3px - var(--c)");
    const args = [_]Value{Value.string(expr_id, false)};
    const result = try math_sqrt(&ctx, &args);
    try testing.expectEqual(.string, result.kind());
    try testing.expect(!result.stringQuoted(ctx.string_flags_pool.items));
    try testing.expectEqualStrings("sqrt(3px - var(--c))", ctx.intern_pool.get(result.stringIntern()));
}

test "math.pow preserves unresolved calculation as css function" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const expr_id = try internString(&ctx, "2px + var(--c)");
    const px = try internString(&ctx, "px");
    const args = [_]Value{
        Value.string(expr_id, false),
        try Value.number(14, px, &harness.number_pool, harness.allocator),
    };
    const names = [_]InternId{ .none, .none };
    const result = try math_pow(&ctx, &args, &names);
    try testing.expectEqual(.string, result.kind());
    try testing.expect(!result.stringQuoted(ctx.string_flags_pool.items));
    try testing.expectEqualStrings("pow(2px + var(--c), 14px)", ctx.intern_pool.get(result.stringIntern()));
}

test "math.log preserves unresolved arguments as css function" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const base_id = try internString(&ctx, "var(--e)");
    const args = [_]Value{
        Value.numberUnitless(2),
        Value.string(base_id, false),
    };
    const names = [_]InternId{ .none, .none };
    const result = try math_log(&ctx, &args, &names);
    try testing.expectEqual(.string, result.kind());
    try testing.expect(!result.stringQuoted(ctx.string_flags_pool.items));
    try testing.expectEqualStrings("log(2, var(--e))", ctx.intern_pool.get(result.stringIntern()));
}

test "math.sin evaluates angle values" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const deg = try internString(&ctx, "deg");
    const args = [_]Value{try Value.number(1, deg, &harness.number_pool, harness.allocator)};
    const result = try math_sin(&ctx, &args);
    try testing.expectEqual(.number, result.kind());
    try testing.expectApproxEqAbs(@as(f64, 0.0174524064), result.asF64(ctx.number_pool), 1e-10);
    try testing.expectEqual(.none, result.unitId(ctx.number_pool));
}

test "math.cos preserves unresolved calculation as css function" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const expr_id = try internString(&ctx, "2px + var(--c)");
    const args = [_]Value{Value.string(expr_id, false)};
    const result = try math_cos(&ctx, &args);
    try testing.expectEqual(.string, result.kind());
    try testing.expect(!result.stringQuoted(ctx.string_flags_pool.items));
    try testing.expectEqualStrings("cos(2px + var(--c))", ctx.intern_pool.get(result.stringIntern()));
}

test "math.cos normalizes compact var adjacency in css fallback" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const expr_id = try internString(&ctx, "2pxvar(--c)");
    const args = [_]Value{Value.string(expr_id, false)};
    const result = try math_cos(&ctx, &args);
    try testing.expectEqual(.string, result.kind());
    try testing.expectEqualStrings("cos(2px + var(--c))", ctx.intern_pool.get(result.stringIntern()));
}

test "math.tan rejects complex unit expressions" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const expr_id = try internString(&ctx, "-7px / 4em");
    const args = [_]Value{Value.string(expr_id, false)};
    try testing.expectError(error.SassError, math_tan(&ctx, &args));
}

test "math.asin returns degrees for unitless numbers" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const args = [_]Value{Value.numberUnitless(1)};
    const result = try math_asin(&ctx, &args);
    try testing.expectEqual(.number, result.kind());
    try testing.expectApproxEqAbs(@as(f64, 90), result.asF64(ctx.number_pool), 1e-9);
    try testing.expectEqualStrings("deg", ctx.intern_pool.get(result.unitId(ctx.number_pool)));
}

test "math.acos preserves unresolved calculation as css function" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const expr_id = try internString(&ctx, "2px + var(--c)");
    const args = [_]Value{Value.string(expr_id, false)};
    const result = try math_acos(&ctx, &args);
    try testing.expectEqual(.string, result.kind());
    try testing.expect(!result.stringQuoted(ctx.string_flags_pool.items));
    try testing.expectEqualStrings("acos(2px + var(--c))", ctx.intern_pool.get(result.stringIntern()));
}

test "math.atan preserves unresolved calculation as css function" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const expr_id = try internString(&ctx, "2px + var(--c)");
    const args = [_]Value{Value.string(expr_id, false)};
    const result = try math_atan(&ctx, &args);
    try testing.expectEqual(.string, result.kind());
    try testing.expect(!result.stringQuoted(ctx.string_flags_pool.items));
    try testing.expectEqualStrings("atan(2px + var(--c))", ctx.intern_pool.get(result.stringIntern()));
}

test "math.atan2 converts compatible units to degrees" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const cm = try internString(&ctx, "cm");
    const mm = try internString(&ctx, "mm");
    const args = [_]Value{
        try Value.number(1, cm, &harness.number_pool, harness.allocator),
        try Value.number(-10, mm, &harness.number_pool, harness.allocator),
    };
    const names = [_]InternId{ .none, .none };
    const result = try math_atan2(&ctx, &args, &names);
    try testing.expectEqual(.number, result.kind());
    try testing.expectApproxEqAbs(@as(f64, 135), result.asF64(ctx.number_pool), 1e-9);
    try testing.expectEqualStrings("deg", ctx.intern_pool.get(result.unitId(ctx.number_pool)));
}

test "math.atan2 preserves unresolved calculation as css function" {
    var harness = try MathTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const expr_id = try internString(&ctx, "2px + var(--c)");
    const px = try internString(&ctx, "px");
    const args = [_]Value{
        Value.string(expr_id, false),
        try Value.number(-1.75, px, &harness.number_pool, harness.allocator),
    };
    const names = [_]InternId{ .none, .none };
    const result = try math_atan2(&ctx, &args, &names);
    try testing.expectEqual(.string, result.kind());
    try testing.expect(!result.stringQuoted(ctx.string_flags_pool.items));
    try testing.expectEqualStrings("atan2(2px + var(--c), -1.75px)", ctx.intern_pool.get(result.stringIntern()));
}
