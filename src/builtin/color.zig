//! sass:color builtins.
const std = @import("std");
const calculation = @import("../color/calculation.zig");
const color_mod = @import("../color/color.zig");
const value_mod = @import("../runtime/value.zig");
const deprecation_mod = @import("../runtime/deprecation.zig");
const intern_pool_mod = @import("../runtime/intern_pool.zig");
const shared = @import("shared.zig");
const error_format = @import("../runtime/error_format.zig");
const value_format = @import("../runtime/value_format.zig");

const Value = shared.Value;
const ColorMissingMask = shared.ColorMissingMask;
const InternId = shared.InternId;
const BuiltinContext = shared.BuiltinContext;
const BuiltinError = shared.BuiltinError;
const color_preserve_slash_marker = "\x01zsass-color-preserve-slash:";

const badArity = shared.badArity;
const expectArity = shared.expectArity;
const expectNumber = shared.expectNumber;
const argNameMatches = shared.argNameMatches;
const bindNamedOrPositionalArgs = shared.bindNamedOrPositionalArgs;
const bindNamedOrPositionalArgsStrict = shared.bindNamedOrPositionalArgsStrict;
const validateRequiredBound = shared.validateRequiredBound;
const reportMissingArgument = shared.reportMissingArgument;
const reportArgumentTypeMismatch = shared.reportArgumentTypeMismatch;
const identifierEq = shared.identifierEq;
const internString = shared.internString;
const pushList = shared.pushList;
const pushColorEntry = shared.pushColorEntry;
const colorValueFromPrimitive = shared.colorValueFromPrimitive;
const colorEntryOf = shared.colorEntryOf;
const colorPrimitiveOf = shared.colorPrimitiveOf;
const valueToCssString = shared.valueToCssString;

fn rgbaToValue(ctx: *BuiltinContext, r: u8, g: u8, b: u8, a: u8) BuiltinError!Value {
    return rgbaToValuePrecise(ctx, r, g, b, @as(f64, @floatFromInt(a)) / 255.0);
}

fn rgbaToValuePrecise(ctx: *BuiltinContext, r: u8, g: u8, b: u8, alpha: f64) BuiltinError!Value {
    return pushColorEntry(ctx, .{
        .channels = .{
            @as(f64, @floatFromInt(r)) / 255.0,
            @as(f64, @floatFromInt(g)) / 255.0,
            @as(f64, @floatFromInt(b)) / 255.0,
            std.math.clamp(alpha, 0.0, 1.0),
        },
        .space = .srgb,
        .missing = 0,
        .legacy = true,
    });
}

inline fn hexDigit(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

inline fn hexPair(a: u8, b: u8) ?u8 {
    const hi = hexDigit(a) orelse return null;
    const lo = hexDigit(b) orelse return null;
    return (hi << 4) | lo;
}

inline fn hexPairDup(c: u8) ?u8 {
    const digit = hexDigit(c) orelse return null;
    return (digit << 4) | digit;
}

fn tryCoerceHexColorLiteral(ctx: *BuiltinContext, raw: []const u8) ?Value {
    const trimmed = std.mem.trim(u8, raw, " \t\n\r");
    if (trimmed.len < 4 or trimmed[0] != '#') return null;
    const digits = trimmed[1..];
    return switch (digits.len) {
        3 => blk: {
            const r = hexPairDup(digits[0]) orelse break :blk null;
            const g = hexPairDup(digits[1]) orelse break :blk null;
            const b = hexPairDup(digits[2]) orelse break :blk null;
            break :blk rgbaToValue(ctx, r, g, b, 0xff) catch null;
        },
        4 => blk: {
            const r = hexPairDup(digits[0]) orelse break :blk null;
            const g = hexPairDup(digits[1]) orelse break :blk null;
            const b = hexPairDup(digits[2]) orelse break :blk null;
            const a = hexPairDup(digits[3]) orelse break :blk null;
            break :blk rgbaToValue(ctx, r, g, b, a) catch null;
        },
        6 => blk: {
            const r = hexPair(digits[0], digits[1]) orelse break :blk null;
            const g = hexPair(digits[2], digits[3]) orelse break :blk null;
            const b = hexPair(digits[4], digits[5]) orelse break :blk null;
            break :blk rgbaToValue(ctx, r, g, b, 0xff) catch null;
        },
        8 => blk: {
            const r = hexPair(digits[0], digits[1]) orelse break :blk null;
            const g = hexPair(digits[2], digits[3]) orelse break :blk null;
            const b = hexPair(digits[4], digits[5]) orelse break :blk null;
            const a = hexPair(digits[6], digits[7]) orelse break :blk null;
            break :blk rgbaToValue(ctx, r, g, b, a) catch null;
        },
        else => null,
    };
}

fn tryCoerceColorArg(ctx: *BuiltinContext, v: Value) ?Value {
    if (v.kind() == .color) return v;
    if (v.kind() != .string) return null;
    if (v.stringQuoted(ctx.string_flags_pool.items)) return null;
    const raw = ctx.intern_pool.get(v.stringIntern());
    if (tryCoerceHexColorLiteral(ctx, raw)) |hex| return hex;
    const named = color_mod.lookupNamedColor(raw) orelse return null;
    const out = rgbaToValue(
        ctx,
        color_mod.clampByte(named.r),
        color_mod.clampByte(named.g),
        color_mod.clampByte(named.b),
        alphaToByte(named.a),
    ) catch null;
    if (out) |coerced| {
        coerced.colorEntryMut(ctx.color_pool).prefer_long_hex = true;
    }
    return out;
}

fn isLegacyAlphaFilterName(name: []const u8) bool {
    if (name.len == 0) return false;
    const first = name[0];
    if (!std.ascii.isAlphabetic(first) and first != '_' and first != '-') return false;
    for (name[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return false;
    }
    return true;
}

fn isLegacyAlphaFilterSyntax(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\n\r");
    if (trimmed.len == 0) return false;
    if (std.mem.findAny(u8, trimmed, "\"'") != null) return false;
    const eq_idx = std.mem.findScalar(u8, trimmed, '=') orelse return false;
    const name = std.mem.trim(u8, trimmed[0..eq_idx], " \t\n\r");
    const value = std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t\n\r");
    return isLegacyAlphaFilterName(name) and value.len > 0;
}

fn clampUnit(v: f64) f64 {
    return std.math.clamp(v, 0.0, 1.0);
}

fn alphaToByte(a_raw: f64) u8 {
    var a = a_raw;
    if (a > 1.0 and a <= 100.0) a /= 100.0;
    return color_mod.clampByte(std.math.clamp(a, 0.0, 1.0) * 255.0);
}

fn colorCompatSrgb(ctx: *BuiltinContext, c: Value) color_mod.Color {
    const entry = colorEntryOf(ctx, c);
    const source = color_mod.Color.init(
        entry.channels[0],
        entry.channels[1],
        entry.channels[2],
        entry.channels[3],
        entry.space,
    );
    return if (entry.space == .srgb) source else color_mod.convert(source, .srgb);
}

fn colorCompatRgbBytes(ctx: *BuiltinContext, c: Value) [3]u8 {
    const srgb = colorCompatSrgb(ctx, c);
    return .{
        color_mod.clampByte(clampUnit(srgb.channels[0]) * 255.0),
        color_mod.clampByte(clampUnit(srgb.channels[1]) * 255.0),
        color_mod.clampByte(clampUnit(srgb.channels[2]) * 255.0),
    };
}

fn colorCompatAlphaByte(ctx: *BuiltinContext, c: Value) u8 {
    const srgb = colorCompatSrgb(ctx, c);
    return color_mod.clampByte(clampUnit(srgb.channels[3]) * 255.0);
}

fn hslToSrgbFloat(h: f64, s: f64, l: f64) [3]f64 {
    const sf = std.math.clamp(s, 0.0, 100.0) / 100.0;
    const lf = l / 100.0;
    const q = if (lf < 0.5) lf * (1.0 + sf) else lf + sf - lf * sf;
    const p = 2.0 * lf - q;
    const hf = h / 360.0;
    return .{
        color_mod.hueToRgb(p, q, hf + 1.0 / 3.0),
        color_mod.hueToRgb(p, q, hf),
        color_mod.hueToRgb(p, q, hf - 1.0 / 3.0),
    };
}

fn colorToHsl(ctx: *BuiltinContext, c: Value) [3]f64 {
    const entry = colorEntryOf(ctx, c);
    if (entry.space == .hsl) {
        return .{ entry.channels[0], entry.channels[1], entry.channels[2] };
    }
    const hsl = color_mod.convert(colorPrimitiveOf(ctx, c), .hsl);
    return .{ hsl.channels[0], hsl.channels[1], hsl.channels[2] };
}

const ColorArgBind = struct {
    values: [4]?Value = [_]?Value{null} ** 4,
    count: u8 = 0,
};

fn colorSlotIndex(ctx: *BuiltinContext, name_id: InternId, slot_names: []const []const u8) ?usize {
    for (slot_names, 0..) |slot_name, idx| {
        if (argNameMatches(ctx, name_id, slot_name)) return idx;
    }
    return null;
}

fn setColorBoundValue(values: *[4]?Value, idx: usize, v: Value) BuiltinError!void {
    if (idx >= values.len) return error.BuiltinArity;
    if (values[idx] != null) return error.BuiltinArity;
    values[idx] = v;
}

const SplitTopLevelSlash = struct { left: []const u8, right: []const u8 };
const SplitSlashValues = struct { left: Value, right: Value };

fn splitTopLevelSlash(text: []const u8) ?SplitTopLevelSlash {
    var depth: u32 = 0;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (quote != 0) {
            if (ch == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (ch == quote) quote = 0;
            continue;
        }
        switch (ch) {
            '"', '\'' => quote = ch,
            '(' => depth += 1,
            ')' => {
                if (depth > 0) depth -= 1;
            },
            '/' => {
                if (depth == 0) {
                    return .{
                        .left = std.mem.trim(u8, text[0..i], " \t\n\r"),
                        .right = std.mem.trim(u8, text[i + 1 ..], " \t\n\r"),
                    };
                }
            },
            else => {},
        }
    }
    return null;
}

fn splitSlashValue(ctx: *BuiltinContext, v: Value) BuiltinError!?SplitSlashValues {
    var owned: ?[]const u8 = null;
    defer if (owned) |buf| ctx.allocator.free(buf);

    const raw: []const u8 = blk: {
        if (v.isString()) {
            if (v.stringQuoted(ctx.string_flags_pool.items)) return null;
            break :blk std.mem.trim(u8, ctx.intern_pool.get(v.stringIntern()), " \t\n\r");
        }
        if (v.kind() == .calc_fragment or v.kind() == .interp_fragment) {
            const css = try valueToCssString(ctx, v);
            owned = css;
            break :blk std.mem.trim(u8, css, " \t\n\r");
        }
        return null;
    };

    if (splitTopLevelSlash(raw)) |parts| {
        if (parts.left.len == 0 or parts.right.len == 0) return null;
        return .{
            .left = try parseInlineColorToken(ctx, parts.left),
            .right = try parseInlineColorToken(ctx, parts.right),
        };
    }
    return null;
}

fn bindColorListArg(
    ctx: *BuiltinContext,
    values: *[4]?Value,
    slot_count: usize,
    list_value: Value,
    allow_slash: bool,
) BuiltinError!void {
    if (list_value.kind() != .list) return error.BuiltinArity;
    if (list_value.listBracketed(ctx.list_meta_pool.items)) return error.BuiltinArity;
    if (list_value.listComma(ctx.list_meta_pool.items)) return error.BuiltinArity;
    const items = ctx.list_pool.items[list_value.listHandle()];

    if (list_value.listSpace(ctx.list_meta_pool.items) and items.len == 3) {
        if (allow_slash and slot_count >= 4 and items[2].kind() == .list and items[2].listSlash(ctx.list_meta_pool.items) and !items[2].listBracketed(ctx.list_meta_pool.items)) {
            const tail = ctx.list_pool.items[items[2].listHandle()];
            if (tail.len != 2) return error.BuiltinArity;
            try setColorBoundValue(values, 0, items[0]);
            try setColorBoundValue(values, 1, items[1]);
            try setColorBoundValue(values, 2, tail[0]);
            try setColorBoundValue(values, 3, tail[1]);
            return;
        }
        if (allow_slash and slot_count >= 4 and items[2].kind() == .string and !items[2].stringQuoted(ctx.string_flags_pool.items)) {
            const raw = std.mem.trim(u8, ctx.intern_pool.get(items[2].stringIntern()), " \t\n\r");
            if (splitTopLevelSlash(raw)) |parts| {
                if (parts.left.len == 0 or parts.right.len == 0) return error.BuiltinArity;
                try setColorBoundValue(values, 0, items[0]);
                try setColorBoundValue(values, 1, items[1]);
                try setColorBoundValue(values, 2, try parseInlineColorToken(ctx, parts.left));
                try setColorBoundValue(values, 3, try parseInlineColorToken(ctx, parts.right));
                return;
            }
        }
        if (allow_slash and slot_count >= 4) {
            if (try splitSlashValue(ctx, items[2])) |parts| {
                try setColorBoundValue(values, 0, items[0]);
                try setColorBoundValue(values, 1, items[1]);
                try setColorBoundValue(values, 2, parts.left);
                try setColorBoundValue(values, 3, parts.right);
                return;
            }
        }
        if (slot_count < 3) return error.BuiltinArity;
        try setColorBoundValue(values, 0, items[0]);
        try setColorBoundValue(values, 1, items[1]);
        try setColorBoundValue(values, 2, items[2]);
        return;
    }

    if (allow_slash and list_value.listSlash(ctx.list_meta_pool.items) and items.len == 2 and items[0].kind() == .list) {
        const channels = items[0];
        if (slot_count < 4 or channels.listComma(ctx.list_meta_pool.items) or channels.listSlash(ctx.list_meta_pool.items) or channels.listBracketed(ctx.list_meta_pool.items)) return error.BuiltinArity;
        const nested = ctx.list_pool.items[channels.listHandle()];
        if (nested.len == 3) {
            try setColorBoundValue(values, 0, nested[0]);
            try setColorBoundValue(values, 1, nested[1]);
            try setColorBoundValue(values, 2, nested[2]);
        } else {
            return error.BuiltinArity;
        }
        try setColorBoundValue(values, 3, items[1]);
        return;
    }

    if (allow_slash and list_value.listSlash(ctx.list_meta_pool.items) and items.len == 2 and slot_count >= 4) {
        // Modern syntax passthrough: `rgb(var(--foo) / 0.4)` etc.
        try setColorBoundValue(values, 0, items[0]);
        try setColorBoundValue(values, 1, Value.nil_v);
        try setColorBoundValue(values, 2, Value.nil_v);
        try setColorBoundValue(values, 3, items[1]);
        return;
    }

    return error.BuiltinArity;
}

fn bindColorArgs(
    ctx: *BuiltinContext,
    args: []const Value,
    arg_names: []const InternId,
    slot_names: []const []const u8,
    allow_slash: bool,
) BuiltinError!ColorArgBind {
    if (slot_names.len == 0 or slot_names.len > 4) return error.BuiltinArity;

    var out: [4]?Value = [_]?Value{null} ** 4;
    var positional: usize = 0;

    for (args, 0..) |arg, i| {
        const name_id: InternId = if (i < arg_names.len) arg_names[i] else .none;
        if (name_id != .none) {
            if (argNameMatches(ctx, name_id, "channels")) {
                try bindColorListArg(ctx, &out, slot_names.len, arg, allow_slash);
                continue;
            }
            const slot_idx = colorSlotIndex(ctx, name_id, slot_names) orelse return error.BuiltinArity;
            try setColorBoundValue(&out, slot_idx, arg);
            continue;
        }

        if (arg.kind() == .list and !arg.listComma(ctx.list_meta_pool.items)) {
            try bindColorListArg(ctx, &out, slot_names.len, arg, allow_slash);
            continue;
        }

        while (positional < slot_names.len and out[positional] != null) : (positional += 1) {}
        if (positional >= slot_names.len) return error.BuiltinArity;
        out[positional] = arg;
        positional += 1;
    }

    if (allow_slash and slot_names.len >= 4 and out[2] != null and out[3] == null) {
        if (out[2].?.kind() == .list and out[2].?.listSlash(ctx.list_meta_pool.items) and !out[2].?.listBracketed(ctx.list_meta_pool.items) and !out[2].?.listComma(ctx.list_meta_pool.items)) {
            const tail = ctx.list_pool.items[out[2].?.listHandle()];
            if (tail.len == 2) {
                out[2] = tail[0];
                out[3] = tail[1];
            }
        }
        if (out[3] == null) {
            if (try splitSlashValue(ctx, out[2].?)) |parts| {
                out[2] = parts.left;
                out[3] = parts.right;
            }
        }
    }

    const has_default_alpha = slot_names.len >= 4 and std.ascii.eqlIgnoreCase(slot_names[slot_names.len - 1], "alpha");
    if (has_default_alpha and out[slot_names.len - 1] == null) {
        out[slot_names.len - 1] = Value.numberUnitless(1.0);
    }

    const required_count: usize = if (has_default_alpha) slot_names.len - 1 else slot_names.len;
    for (0..required_count) |idx| {
        if (out[idx] == null) return error.BuiltinArity;
    }

    var count: u8 = 0;
    var idx = slot_names.len;
    while (idx > 0) {
        idx -= 1;
        if (out[idx] != null) {
            count = @intCast(idx + 1);
            break;
        }
    }
    return .{ .values = out, .count = count };
}

fn bindColorOverrideAlphaArgs(
    ctx: *BuiltinContext,
    args: []const Value,
    arg_names: []const InternId,
) BuiltinError!?struct { color: Value, alpha: Value } {
    if (args.len != 2) return null;

    var color_v: ?Value = null;
    var alpha_v: ?Value = null;
    var positional: usize = 0;

    for (args, 0..) |arg, i| {
        const name_id: InternId = if (i < arg_names.len) arg_names[i] else .none;
        if (name_id != .none) {
            if (argNameMatches(ctx, name_id, "color")) {
                if (color_v != null) return error.BuiltinArity;
                color_v = arg;
                continue;
            }
            if (argNameMatches(ctx, name_id, "alpha")) {
                if (alpha_v != null) return error.BuiltinArity;
                alpha_v = arg;
                continue;
            }
            return null;
        }

        while (positional < 2 and ((positional == 0 and color_v != null) or (positional == 1 and alpha_v != null))) : (positional += 1) {}
        if (positional >= 2) return error.BuiltinArity;
        if (positional == 0) {
            color_v = arg;
        } else {
            alpha_v = arg;
        }
        positional += 1;
    }

    const color_arg = color_v orelse return null;
    const alpha_arg = alpha_v orelse return null;
    return .{ .color = color_arg, .alpha = alpha_arg };
}

fn valueLooksLikeColorPassthrough(ctx: *BuiltinContext, v: Value) bool {
    if (v.isString()) {
        const raw = ctx.intern_pool.get(v.stringIntern());
        if (!v.stringQuoted(ctx.string_flags_pool.items) and identifierEq(raw, "from")) return true;
        if (std.mem.find(u8, raw, "#{") != null) return true;
        if (std.mem.findScalar(u8, raw, '(') != null) {
            if (!v.stringQuoted(ctx.string_flags_pool.items) and parseCalcSpecialNumber(ctx, v) != null) return false;
            if (!v.stringQuoted(ctx.string_flags_pool.items)) return true;
        }
        return false;
    }
    if (v.kind() == .list) {
        if (isRelativeColorDescription(ctx, v)) return true;
        const items = ctx.list_pool.items[v.listHandle()];
        for (items) |item| {
            if (valueLooksLikeColorPassthrough(ctx, item)) return true;
        }
        return false;
    }
    return v.kind() == .calc_fragment or v.kind() == .interp_fragment;
}

fn shouldSerializeColorFallback(ctx: *BuiltinContext, args: []const Value) bool {
    if (args.len == 0 or args.len > 4) return false;
    for (args) |arg| {
        if (valueLooksLikeColorPassthrough(ctx, arg)) return true;
    }
    return false;
}

fn valueContainsQuotedString(ctx: *BuiltinContext, v: Value) bool {
    if (v.isString()) return v.stringQuoted(ctx.string_flags_pool.items);
    if (v.kind() == .list) {
        const items = ctx.list_pool.items[v.listHandle()];
        for (items) |item| {
            if (valueContainsQuotedString(ctx, item)) return true;
        }
    }
    return false;
}

fn shouldSerializeConstructorFallback(ctx: *BuiltinContext, args: []const Value) bool {
    if (!shouldSerializeColorFallback(ctx, args)) return false;
    for (args) |arg| {
        if (valueContainsQuotedString(ctx, arg)) return false;
    }
    return true;
}

fn coerceModernConstructorArityToType(space: color_mod.ColorSpace, args: []const Value) bool {
    if (space != .lch and space != .oklab and space != .oklch) return false;
    if (args.len != 1) return false;
    return args[0].kind() == .list;
}

fn normalizeColorUserError(err: BuiltinError) BuiltinError {
    return switch (err) {
        error.BuiltinType, error.BuiltinArity => error.SassError,
        else => err,
    };
}

fn markLegacyRgbFunctionResult(ctx: *BuiltinContext, value: Value) Value {
    if (value.kind() != .color) return value;
    const entry = value.colorEntryMut(ctx.color_pool);
    if (entry.space != .srgb or !entry.legacy) return value;
    entry.inspect_repr = .legacy_rgb_function;
    return value;
}

fn serializeColorAlphaPassthrough(
    ctx: *BuiltinContext,
    function_name: []const u8,
    coerced_color: Value,
    alpha_arg: Value,
) BuiltinError!Value {
    const srgb = colorCompatSrgb(ctx, coerced_color);
    const r = try value_format.formatNumberCore(ctx.allocator, clampUnit(srgb.channels[0]) * 255.0);
    defer ctx.allocator.free(r);
    const g = try value_format.formatNumberCore(ctx.allocator, clampUnit(srgb.channels[1]) * 255.0);
    defer ctx.allocator.free(g);
    const b = try value_format.formatNumberCore(ctx.allocator, clampUnit(srgb.channels[2]) * 255.0);
    defer ctx.allocator.free(b);
    const alpha_s = try valueToCssString(ctx, alpha_arg);
    defer ctx.allocator.free(alpha_s);
    const text = try std.fmt.allocPrint(ctx.allocator, "{s}({s}, {s}, {s}, {s})", .{
        function_name,
        r,
        g,
        b,
        alpha_s,
    });
    defer ctx.allocator.free(text);
    const id = try internString(ctx, text);
    return Value.string(id, false);
}

fn rgbaFromCoercedColorAndAlpha(
    ctx: *BuiltinContext,
    function_name: []const u8,
    coerced_color: Value,
    alpha_arg: Value,
) BuiltinError!Value {
    const alpha = parseRgbAlphaOrMissing(ctx, alpha_arg) orelse {
        if (valueLooksLikeColorPassthrough(ctx, alpha_arg) and !valueContainsQuotedString(ctx, alpha_arg)) {
            return serializeColorAlphaPassthrough(ctx, function_name, coerced_color, alpha_arg);
        }
        return error.BuiltinType;
    };
    if (alpha.missing) return error.BuiltinType;
    // official Sass CLI maintains channel precision of original color in 2-arg format of `rgba($color, $alpha)`
    // (byte rounding prohibited). Keeps f64 channel in srgb space and returns legacy rgb color.
    const srgb = colorCompatSrgb(ctx, coerced_color);
    const out = try pushColorEntry(ctx, .{
        .channels = .{
            srgb.channels[0],
            srgb.channels[1],
            srgb.channels[2],
            std.math.clamp(alpha.value, 0.0, 1.0),
        },
        .space = .srgb,
        .missing = 0,
        .legacy = true,
    });
    if (coerced_color.kind() == .color and coerced_color.colorEntry(ctx.color_pool).prefer_long_hex) {
        maybePreferLongHexResult(ctx, out, true);
    }
    return out;
}

fn color_rgbImpl(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId, fallback_name: []const u8) BuiltinError!Value {
    if (args.len == 1 and (arg_names.len == 0 or arg_names[0] == .none)) {
        if (args[0].kind() == .color) return args[0];
        if (tryCoerceColorArg(ctx, args[0])) |single_color| return single_color;

        if (try splitSlashValue(ctx, args[0])) |parts| {
            if (tryCoerceColorArg(ctx, parts.left)) |coerced_color| {
                return rgbaFromCoercedColorAndAlpha(ctx, fallback_name, coerced_color, parts.right);
            }
        }

        if (args[0].kind() == .list and args[0].listSpace(ctx.list_meta_pool.items) and !args[0].listBracketed(ctx.list_meta_pool.items)) {
            const items = ctx.list_pool.items[args[0].listHandle()];
            if (items.len == 3 and items[1].kind() == .string and !items[1].stringQuoted(ctx.string_flags_pool.items)) {
                const mid = std.mem.trim(u8, ctx.intern_pool.get(items[1].stringIntern()), " \t\n\r");
                if (std.mem.eql(u8, mid, "/")) {
                    if (tryCoerceColorArg(ctx, items[0])) |coerced_color| {
                        return rgbaFromCoercedColorAndAlpha(ctx, fallback_name, coerced_color, items[2]);
                    }
                }
            }
        }

        if (args[0].kind() == .list and args[0].listSlash(ctx.list_meta_pool.items) and !args[0].listBracketed(ctx.list_meta_pool.items)) {
            const slash_items = ctx.list_pool.items[args[0].listHandle()];
            if (slash_items.len == 2) {
                if (tryCoerceColorArg(ctx, slash_items[0])) |coerced_color| {
                    return rgbaFromCoercedColorAndAlpha(ctx, fallback_name, coerced_color, slash_items[1]);
                }
            }
        }
    }

    if (try bindColorOverrideAlphaArgs(ctx, args, arg_names)) |override| {
        const c = tryCoerceColorArg(ctx, override.color) orelse {
            if (shouldSerializeConstructorFallback(ctx, args)) return serializeLegacyConstructorFallback(ctx, fallback_name, args);
            return error.BuiltinType;
        };
        if (valueLooksLikeColorPassthrough(ctx, override.alpha) and !valueContainsQuotedString(ctx, override.alpha)) {
            return serializeColorAlphaPassthrough(ctx, fallback_name, c, override.alpha);
        }
        const alpha = parseRgbAlphaOrMissing(ctx, override.alpha) orelse {
            if (valueLooksLikeColorPassthrough(ctx, override.alpha) and !valueContainsQuotedString(ctx, override.alpha)) {
                return serializeColorAlphaPassthrough(ctx, fallback_name, c, override.alpha);
            }
            return error.BuiltinType;
        };
        if (alpha.missing) return error.BuiltinType;
        // rgba(color, alpha) 2-arg format maintains channel precision of original color (byte rounding prohibited).
        const srgb = colorCompatSrgb(ctx, c);
        const out = try pushColorEntry(ctx, .{
            .channels = .{
                srgb.channels[0],
                srgb.channels[1],
                srgb.channels[2],
                std.math.clamp(alpha.value, 0.0, 1.0),
            },
            .space = .srgb,
            .missing = 0,
            .legacy = true,
        });
        const override_color = override.color;
        if (override_color.kind() == .color) {
            const source_entry = override_color.colorEntry(ctx.color_pool);
            if (source_entry.inspect_repr == .literal_short_hex or source_entry.inspect_repr == .literal_long_hex) {
                maybePreferLongHexResult(ctx, out, true);
            }
            if (source_entry.prefer_long_hex) {
                maybePreferLongHexResult(ctx, out, true);
            }
        }
        if (c.kind() == .color and c.colorEntry(ctx.color_pool).prefer_long_hex) {
            maybePreferLongHexResult(ctx, out, true);
        }
        return out;
    }

    const bound = bindColorArgs(ctx, args, arg_names, &.{ "red", "green", "blue", "alpha" }, true) catch |err| {
        if (err == error.BuiltinArity and shouldSerializeConstructorFallback(ctx, args)) {
            return serializeLegacyConstructorFallback(ctx, fallback_name, args);
        }
        return err;
    };
    if (shouldSerializeConstructorFallback(ctx, args)) {
        return serializeLegacyConstructorFallback(ctx, fallback_name, args);
    }
    const red = parseRgbColorChannelOrMissing(ctx, bound.values[0].?) orelse {
        if (shouldSerializeConstructorFallback(ctx, args)) return serializeLegacyConstructorFallback(ctx, fallback_name, args);
        return error.BuiltinType;
    };
    const green = parseRgbColorChannelOrMissing(ctx, bound.values[1].?) orelse {
        if (shouldSerializeConstructorFallback(ctx, args)) return serializeLegacyConstructorFallback(ctx, fallback_name, args);
        return error.BuiltinType;
    };
    const blue = parseRgbColorChannelOrMissing(ctx, bound.values[2].?) orelse {
        if (shouldSerializeConstructorFallback(ctx, args)) return serializeLegacyConstructorFallback(ctx, fallback_name, args);
        return error.BuiltinType;
    };
    const alpha = parseRgbAlphaOrMissing(ctx, bound.values[3].?) orelse {
        if (shouldSerializeConstructorFallback(ctx, args)) return serializeLegacyConstructorFallback(ctx, fallback_name, args);
        return error.BuiltinType;
    };

    var missing: ColorMissingMask = 0;
    if (red.missing) missing |= 0x1;
    if (green.missing) missing |= 0x2;
    if (blue.missing) missing |= 0x4;
    if (alpha.missing) missing |= 0x8;

    const primitive = color_mod.Color.init(red.value, green.value, blue.value, alpha.value, .srgb);
    // Sass constructor output keeps rgb()/rgba() in legacy function form
    // even when the alpha channel is explicitly missing with `/ none`.
    const legacy_rgb_fn = true;
    const out = try colorValueFromDeclaredColor(ctx, primitive, .srgb, missing, legacy_rgb_fn);
    return markLegacyRgbFunctionResult(ctx, out);
}

pub fn color_rgb(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    return color_rgbImpl(ctx, args, arg_names, "rgb") catch |err| normalizeColorUserError(err);
}

pub fn color_rgba(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    return color_rgbImpl(ctx, args, arg_names, "rgba") catch |err| normalizeColorUserError(err);
}

fn serializeFallbackFunction(ctx: *BuiltinContext, name: []const u8, args: []const Value) BuiltinError!Value {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(ctx.allocator);
    try buf.appendSlice(ctx.allocator, name);
    try buf.append(ctx.allocator, '(');
    for (args, 0..) |arg, i| {
        if (i != 0) try buf.appendSlice(ctx.allocator, ", ");
        const part = try valueToCssString(ctx, arg);
        defer ctx.allocator.free(part);
        try buf.appendSlice(ctx.allocator, part);
    }
    try buf.append(ctx.allocator, ')');
    const id = try internString(ctx, buf.items);
    return Value.string(id, false).withPreserveLiteralText();
}

fn isCalcOperator(ch: u8) bool {
    return ch == '+' or ch == '-' or ch == '*' or ch == '/';
}

fn isRawCalcString(raw: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw, " \t\n\r");
    return std.ascii.startsWithIgnoreCase(trimmed, "calc(") and trimmed.len >= 6 and trimmed[trimmed.len - 1] == ')';
}

fn maybeNormalizeCalcFallbackText(ctx: *BuiltinContext, css: []const u8) BuiltinError!?[]u8 {
    const trimmed = std.mem.trim(u8, css, " \t\n\r");
    if (!(std.ascii.startsWithIgnoreCase(trimmed, "calc(") and trimmed.len >= 6 and trimmed[trimmed.len - 1] == ')')) {
        return null;
    }

    const inner = std.mem.trim(u8, trimmed[5 .. trimmed.len - 1], " \t\n\r");
    if (inner.len == 0) return null;

    var normalized_inner = inner;
    var owned_inner: ?[]u8 = null;
    defer if (owned_inner) |buf| ctx.allocator.free(buf);

    // With relative color fallback like `calc(h180deg)` / `calc(l0.2)`
    // Correct the path that `+` falls on.
    var has_operator = false;
    var has_space = false;
    for (inner) |ch| {
        if (isCalcOperator(ch)) has_operator = true;
        if (std.ascii.isWhitespace(ch)) has_space = true;
    }
    if (!has_operator and !has_space and std.ascii.isAlphabetic(inner[0])) {
        var head_end: usize = 1;
        while (head_end < inner.len and std.ascii.isAlphabetic(inner[head_end])) : (head_end += 1) {}
        if (head_end < inner.len) {
            const marker = inner[head_end];
            if (std.ascii.isDigit(marker) or marker == '.' or marker == '+' or marker == '-') {
                const head = inner[0..head_end];
                const tail = inner[head_end..];
                const rebuilt = if (tail[0] == '-')
                    try std.fmt.allocPrint(ctx.allocator, "{s} - {s}", .{ head, tail[1..] })
                else if (tail[0] == '+')
                    try std.fmt.allocPrint(ctx.allocator, "{s} + {s}", .{ head, tail[1..] })
                else
                    try std.fmt.allocPrint(ctx.allocator, "{s} + {s}", .{ head, tail });
                owned_inner = rebuilt;
                normalized_inner = rebuilt;
            }
        }
    }

    // Normalize stuck `/` like `calc(var(--a)/2)` to `/`.
    var tight_slash = false;
    if (std.mem.findScalar(u8, normalized_inner, '/')) |_| {
        for (normalized_inner, 0..) |ch, i| {
            if (ch != '/') continue;
            const prev = if (i == 0) ' ' else normalized_inner[i - 1];
            const next = if (i + 1 >= normalized_inner.len) ' ' else normalized_inner[i + 1];
            if (!std.ascii.isWhitespace(prev) and !std.ascii.isWhitespace(next)) {
                tight_slash = true;
                break;
            }
        }
    }

    if (!tight_slash and owned_inner == null) return null;

    var slash_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer slash_buf.deinit(ctx.allocator);
    if (tight_slash) {
        var extra: usize = 0;
        for (normalized_inner, 0..) |ch, i| {
            if (ch != '/') continue;
            const prev = if (i == 0) ' ' else normalized_inner[i - 1];
            const next = if (i + 1 >= normalized_inner.len) ' ' else normalized_inner[i + 1];
            if (!std.ascii.isWhitespace(prev) and !std.ascii.isWhitespace(next)) {
                extra += 2;
            }
        }
        try slash_buf.ensureTotalCapacity(ctx.allocator, normalized_inner.len + extra);
        for (normalized_inner, 0..) |ch, i| {
            if (ch == '/') {
                const prev = if (i == 0) ' ' else normalized_inner[i - 1];
                const next = if (i + 1 >= normalized_inner.len) ' ' else normalized_inner[i + 1];
                if (!std.ascii.isWhitespace(prev) and !std.ascii.isWhitespace(next)) {
                    try slash_buf.appendSlice(ctx.allocator, " / ");
                    continue;
                }
            }
            try slash_buf.append(ctx.allocator, ch);
        }
    } else {
        try slash_buf.ensureTotalCapacity(ctx.allocator, normalized_inner.len);
        try slash_buf.appendSlice(ctx.allocator, normalized_inner);
    }

    return try std.fmt.allocPrint(ctx.allocator, "calc({s})", .{slash_buf.items});
}

fn appendValueCss(buf: *std.ArrayListUnmanaged(u8), ctx: *BuiltinContext, v: Value) BuiltinError!void {
    const part = try valueToCssString(ctx, v);
    defer ctx.allocator.free(part);
    if (try maybeNormalizeCalcFallbackText(ctx, part)) |normalized| {
        defer ctx.allocator.free(normalized);
        try buf.appendSlice(ctx.allocator, normalized);
        return;
    }
    try buf.appendSlice(ctx.allocator, part);
}

fn valueLooksNumericForCompactSlash(ctx: *BuiltinContext, v: Value) bool {
    if (v.kind() == .number) return true;
    if (v.kind() != .string or v.stringQuoted(ctx.string_flags_pool.items)) return false;
    const raw = std.mem.trim(u8, ctx.intern_pool.get(v.stringIntern()), " \t\n\r");
    if (raw.len == 0) return false;
    _ = std.fmt.parseFloat(f64, raw) catch return false;
    return true;
}

fn serializeConstructorListFallback(
    ctx: *BuiltinContext,
    name: []const u8,
    args: []const Value,
    prefer_legacy_commas: bool,
) BuiltinError!Value {
    if (args.len != 1 or args[0].kind() != .list or args[0].listBracketed(ctx.list_meta_pool.items) or args[0].listComma(ctx.list_meta_pool.items)) {
        if (!prefer_legacy_commas and (args.len == 3 or args.len == 4)) {
            const compact_modern_slash_non_list = std.mem.eql(u8, name, "hsl") or
                std.mem.eql(u8, name, "lab") or
                std.mem.eql(u8, name, "lch") or
                std.mem.eql(u8, name, "oklab") or
                std.mem.eql(u8, name, "oklch");
            const modern_alpha_sep_non_list = if (compact_modern_slash_non_list) "/" else " / ";
            var buf_non_list: std.ArrayListUnmanaged(u8) = .empty;
            defer buf_non_list.deinit(ctx.allocator);
            try buf_non_list.ensureTotalCapacity(ctx.allocator, name.len + 2 + args.len * 4);
            try buf_non_list.appendSlice(ctx.allocator, name);
            try buf_non_list.append(ctx.allocator, '(');
            for (args[0..3], 0..) |ch, i| {
                if (i != 0) try buf_non_list.append(ctx.allocator, ' ');
                try appendValueCss(&buf_non_list, ctx, ch);
            }
            if (args.len == 4) {
                try buf_non_list.appendSlice(ctx.allocator, modern_alpha_sep_non_list);
                try appendValueCss(&buf_non_list, ctx, args[3]);
            }
            try buf_non_list.append(ctx.allocator, ')');
            const id_non_list = try internString(ctx, buf_non_list.items);
            return Value.string(id_non_list, false).withPreserveLiteralText();
        }
        return serializeFallbackFunction(ctx, name, args);
    }

    const top = args[0];
    const top_was_slash = top.listSlash(ctx.list_meta_pool.items);
    const top_items = ctx.list_pool.items[top.listHandle()];
    var channels: []const Value = top_items;
    var alpha: ?Value = null;

    if (top_was_slash) {
        if (top_items.len != 2) return serializeFallbackFunction(ctx, name, args);
        alpha = top_items[1];
        if (top_items[0].kind() == .list and !top_items[0].listComma(ctx.list_meta_pool.items) and !top_items[0].listSlash(ctx.list_meta_pool.items) and !top_items[0].listBracketed(ctx.list_meta_pool.items)) {
            channels = ctx.list_pool.items[top_items[0].listHandle()];
        } else {
            channels = top_items[0..1];
        }
    }

    if (channels.len == 0) return serializeFallbackFunction(ctx, name, args);

    var render_channels = channels;
    var render_alpha = alpha;
    var expanded_channels: [4]Value = undefined;
    if (render_alpha == null and render_channels.len > 0 and render_channels.len <= expanded_channels.len) {
        const tail_idx = render_channels.len - 1;
        const tail_value = render_channels[tail_idx];
        if (tail_value.kind() == .list and tail_value.listSlash(ctx.list_meta_pool.items) and !tail_value.listBracketed(ctx.list_meta_pool.items) and !tail_value.listComma(ctx.list_meta_pool.items)) {
            const tail_items = ctx.list_pool.items[tail_value.listHandle()];
            if (tail_items.len == 2) {
                for (render_channels[0..tail_idx], 0..) |item, i| {
                    expanded_channels[i] = item;
                }
                expanded_channels[tail_idx] = tail_items[0];
                render_channels = expanded_channels[0 .. tail_idx + 1];
                render_alpha = tail_items[1];
            }
        }
        if (render_alpha == null and tail_value.kind() == .string and !tail_value.stringQuoted(ctx.string_flags_pool.items)) {
            const tail_raw = std.mem.trim(u8, ctx.intern_pool.get(tail_value.stringIntern()), " \t\n\r");
            if (splitTopLevelSlash(tail_raw)) |parts| {
                if (parts.left.len > 0 and parts.right.len > 0) {
                    for (render_channels[0..tail_idx], 0..) |item, i| {
                        expanded_channels[i] = item;
                    }
                    expanded_channels[tail_idx] = Value.string(try internString(ctx, parts.left), false);
                    render_channels = expanded_channels[0 .. tail_idx + 1];
                    render_alpha = Value.string(try internString(ctx, parts.right), false);
                }
            }
        }
    }

    const relative_color_slash = args.len == 1 and isRelativeColorDescription(ctx, args[0]);
    const compact_modern_slash_name = (std.mem.eql(u8, name, "hsl") or
        std.mem.eql(u8, name, "hwb") or
        std.mem.eql(u8, name, "lab") or
        std.mem.eql(u8, name, "lch") or
        std.mem.eql(u8, name, "oklab") or
        std.mem.eql(u8, name, "oklch")) and !top_was_slash and !relative_color_slash;
    const compact_modern_slash_color = blk: {
        if (!std.mem.eql(u8, name, "color")) break :blk false;
        if (relative_color_slash) break :blk false;
        const a = render_alpha orelse break :blk false;
        if (render_channels.len == 0) break :blk false;
        const left = render_channels[render_channels.len - 1];
        if (!valueLooksNumericForCompactSlash(ctx, left)) break :blk false;
        if (a.kind() == .number) break :blk false;
        break :blk true;
    };
    const compact_modern_slash_rgb_partial = std.mem.eql(u8, name, "rgb") and
        !top_was_slash and
        render_alpha != null and
        render_channels.len < 3;
    const modern_alpha_sep = if (compact_modern_slash_color or compact_modern_slash_name or compact_modern_slash_rgb_partial) "/" else " / ";

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(ctx.allocator);
    const alpha_hint: usize = if (render_alpha != null) 4 else 0;
    try buf.ensureTotalCapacity(ctx.allocator, name.len + 2 + render_channels.len * 4 + alpha_hint);
    try buf.appendSlice(ctx.allocator, name);
    try buf.append(ctx.allocator, '(');

    if (prefer_legacy_commas and render_channels.len == 3) {
        for (render_channels, 0..) |ch, i| {
            if (i != 0) try buf.appendSlice(ctx.allocator, ", ");
            try appendValueCss(&buf, ctx, ch);
        }
        if (render_alpha) |a| {
            try buf.appendSlice(ctx.allocator, ", ");
            try appendValueCss(&buf, ctx, a);
        }
    } else {
        for (render_channels, 0..) |ch, i| {
            if (i != 0) try buf.append(ctx.allocator, ' ');
            try appendValueCss(&buf, ctx, ch);
        }
        if (render_alpha) |a| {
            try buf.appendSlice(ctx.allocator, modern_alpha_sep);
            try appendValueCss(&buf, ctx, a);
        }
    }

    try buf.append(ctx.allocator, ')');
    const preserve_relative_slash_text = top_was_slash and top.listFromBuiltinSlash();
    const rendered = if (preserve_relative_slash_text)
        try normalizeRelativeColorSlashSpacing(ctx, buf.items)
    else
        buf.items;
    defer if (rendered.ptr != buf.items.ptr) ctx.allocator.free(rendered);
    const marked_rendered = if (preserve_relative_slash_text)
        try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ color_preserve_slash_marker, rendered })
    else
        rendered;
    defer if (marked_rendered.ptr != rendered.ptr) ctx.allocator.free(marked_rendered);
    const id = try internString(ctx, marked_rendered);
    return Value.string(id, false).withPreserveLiteralText().withPreserveDeclText();
}

fn normalizeRelativeColorSlashSpacing(ctx: *BuiltinContext, text: []const u8) BuiltinError![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    var changed = false;
    var depth: u32 = 0;
    var in_string: u8 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string != 0) {
            try out.append(ctx.allocator, c);
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                try out.append(ctx.allocator, text[i]);
                continue;
            }
            if (c == in_string) in_string = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            try out.append(ctx.allocator, c);
            continue;
        }
        if (c == '(') depth += 1;
        if (c == ')' and depth > 0) depth -= 1;
        if (c == '/' and depth == 1) {
            if (out.items.len > 0 and out.items[out.items.len - 1] != ' ') {
                try out.append(ctx.allocator, ' ');
                changed = true;
            }
            try out.append(ctx.allocator, '/');
            if (i + 1 < text.len and text[i + 1] != ' ') {
                try out.append(ctx.allocator, ' ');
                changed = true;
            }
            continue;
        }
        try out.append(ctx.allocator, c);
    }
    if (!changed) {
        out.deinit(ctx.allocator);
        return text;
    }
    return out.toOwnedSlice(ctx.allocator) catch error.OutOfMemory;
}

fn serializeLegacyConstructorFallback(ctx: *BuiltinContext, name: []const u8, args: []const Value) BuiltinError!Value {
    return serializeConstructorListFallback(ctx, name, args, true);
}

fn serializeModernConstructorFallback(ctx: *BuiltinContext, name: []const u8, args: []const Value) BuiltinError!Value {
    return serializeConstructorListFallback(ctx, name, args, false);
}

fn color_hslImpl(
    ctx: *BuiltinContext,
    args: []const Value,
    arg_names: []const InternId,
    fallback_name: []const u8,
) BuiltinError!Value {
    if (args.len == 1 and args[0].kind() == .color and (arg_names.len == 0 or arg_names[0] == .none)) return args[0];

    const bound = bindColorArgs(ctx, args, arg_names, &.{ "hue", "saturation", "lightness", "alpha" }, true) catch |err| {
        if (err == error.BuiltinArity and shouldSerializeConstructorFallback(ctx, args)) {
            return serializeLegacyConstructorFallback(ctx, fallback_name, args);
        }
        return err;
    };
    if (shouldSerializeConstructorFallback(ctx, args)) {
        return serializeLegacyConstructorFallback(ctx, fallback_name, args);
    }

    var named_saturation = false;
    var named_lightness = false;
    for (arg_names) |name_id| {
        if (name_id == .none) continue;
        if (argNameMatches(ctx, name_id, "saturation")) named_saturation = true;
        if (argNameMatches(ctx, name_id, "lightness")) named_lightness = true;
    }
    if (named_saturation and bound.values[1].?.kind() == .number) {
        const unit_id = bound.values[1].?.unitId(ctx.number_pool);
        if (unit_id == .none or !std.ascii.eqlIgnoreCase(ctx.intern_pool.get(unit_id), "%")) return error.BuiltinType;
    }
    if (named_lightness and bound.values[2].?.kind() == .number) {
        const unit_id = bound.values[2].?.unitId(ctx.number_pool);
        if (unit_id == .none or !std.ascii.eqlIgnoreCase(ctx.intern_pool.get(unit_id), "%")) return error.BuiltinType;
    }

    const h = parseLegacyHueOrMissing(ctx, bound.values[0].?) orelse {
        if (shouldSerializeConstructorFallback(ctx, args)) return serializeLegacyConstructorFallback(ctx, fallback_name, args);
        return error.BuiltinType;
    };
    const s = parseLegacySaturationOrMissing(ctx, bound.values[1].?) orelse {
        if (shouldSerializeConstructorFallback(ctx, args)) return serializeLegacyConstructorFallback(ctx, fallback_name, args);
        return error.BuiltinType;
    };
    const l = parseLegacyLightnessOrMissing(ctx, bound.values[2].?) orelse {
        if (shouldSerializeConstructorFallback(ctx, args)) return serializeLegacyConstructorFallback(ctx, fallback_name, args);
        return error.BuiltinType;
    };
    const alpha = parseLegacyAlphaOrMissing(ctx, bound.values[3].?) orelse {
        if (shouldSerializeConstructorFallback(ctx, args)) return serializeLegacyConstructorFallback(ctx, fallback_name, args);
        return error.BuiltinType;
    };

    var missing: ColorMissingMask = 0;
    if (h.missing) missing |= 0x1;
    if (s.missing) missing |= 0x2;
    if (l.missing) missing |= 0x4;
    if (alpha.missing) missing |= 0x8;

    const constructed = normalizeChannelColor(color_mod.Color.init(h.value, s.value, l.value, alpha.value, .hsl));
    // HSL with a missing channel serializes as modern color syntax.
    return colorValueFromDeclaredColor(ctx, constructed, .hsl, missing, missing == 0);
}

pub fn color_hsl(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    return color_hslImpl(ctx, args, arg_names, "hsl") catch |err| normalizeColorUserError(err);
}

pub fn color_hsla(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    return color_hslImpl(ctx, args, arg_names, "hsla") catch |err| normalizeColorUserError(err);
}

fn parseLegacyHueOrMissing(ctx: *BuiltinContext, arg: Value) ?ParsedColorComponent {
    if (isNoneColorToken(ctx, arg)) return .{ .value = 0.0, .missing = true };
    if (arg.kind() == .number) {
        const unit = if (arg.unitId(ctx.number_pool) == .none) null else ctx.intern_pool.get(arg.unitId(ctx.number_pool));
        if (unit) |u| {
            if (isAngleUnit(u)) return .{ .value = angleToDegrees(arg.asF64(ctx.number_pool), u), .missing = false };
        }
        return .{ .value = arg.asF64(ctx.number_pool), .missing = false };
    }
    if (parseCalcSpecialNumber(ctx, arg)) |raw| {
        return .{ .value = raw, .missing = false };
    }
    return null;
}

fn parseLegacySaturationOrMissing(ctx: *BuiltinContext, arg: Value) ?ParsedColorComponent {
    if (isNoneColorToken(ctx, arg)) return .{ .value = 0.0, .missing = true };
    if (arg.kind() == .number) {
        const raw = arg.asF64(ctx.number_pool);
        if (std.math.isNan(raw)) return .{ .value = 0.0, .missing = false };
        if (std.math.isPositiveInf(raw)) return .{ .value = raw, .missing = false };
        if (std.math.isNegativeInf(raw)) return .{ .value = 0.0, .missing = false };
        return .{ .value = @max(0.0, raw), .missing = false };
    }
    if (parseCalcSpecialNumber(ctx, arg)) |raw| {
        if (std.math.isNan(raw)) return .{ .value = 0.0, .missing = false };
        if (std.math.isInf(raw)) {
            if (raw < 0) return .{ .value = 0.0, .missing = false };
            return .{ .value = raw, .missing = false };
        }
        return .{ .value = @max(0.0, raw), .missing = false };
    }
    return null;
}

fn parseLegacyLightnessOrMissing(ctx: *BuiltinContext, arg: Value) ?ParsedColorComponent {
    if (isNoneColorToken(ctx, arg)) return .{ .value = 0.0, .missing = true };
    if (arg.kind() == .number) {
        return .{ .value = arg.asF64(ctx.number_pool), .missing = false };
    }
    if (parseCalcSpecialNumber(ctx, arg)) |raw| {
        return .{ .value = raw, .missing = false };
    }
    return null;
}

fn parseHwbChannelOrMissing(ctx: *BuiltinContext, arg: Value) ?ParsedColorComponent {
    if (isNoneColorToken(ctx, arg)) return .{ .value = 0.0, .missing = true };
    if (arg.kind() == .number) {
        const unit = if (arg.unitId(ctx.number_pool) == .none) null else ctx.intern_pool.get(arg.unitId(ctx.number_pool));
        const raw = if (unit) |u| blk: {
            if (!std.ascii.eqlIgnoreCase(u, "%")) return null;
            break :blk arg.asF64(ctx.number_pool);
        } else return null;
        return .{ .value = raw, .missing = false };
    }
    if (parseCalcSpecialNumber(ctx, arg)) |raw| {
        const clamped = if (std.math.isNan(raw)) 0.0 else std.math.clamp(raw, 0.0, 100.0);
        return .{ .value = clamped, .missing = false };
    }
    return null;
}

fn parseLegacyAlphaOrMissing(ctx: *BuiltinContext, arg: Value) ?ParsedColorComponent {
    if (isNoneColorToken(ctx, arg)) return .{ .value = 0.0, .missing = true };
    const raw = if (arg.kind() == .number) blk: {
        const unit = if (arg.unitId(ctx.number_pool) == .none) null else ctx.intern_pool.get(arg.unitId(ctx.number_pool));
        break :blk if (unit) |u| blk2: {
            if (!std.ascii.eqlIgnoreCase(u, "%")) return null;
            break :blk2 arg.asF64(ctx.number_pool) / 100.0;
        } else arg.asF64(ctx.number_pool);
    } else parseCalcSpecialNumber(ctx, arg) orelse return null;
    const clamped = if (std.math.isNan(raw)) 0.0 else std.math.clamp(raw, 0.0, 1.0);
    return .{ .value = clamped, .missing = false };
}

fn parseRgbColorChannelOrMissing(ctx: *BuiltinContext, arg: Value) ?ParsedColorComponent {
    if (isNoneColorToken(ctx, arg)) return .{ .value = 0.0, .missing = true };
    const raw = if (arg.kind() == .number) blk: {
        const unit = if (arg.unitId(ctx.number_pool) == .none) null else ctx.intern_pool.get(arg.unitId(ctx.number_pool));
        break :blk if (unit) |u| blk2: {
            if (!std.ascii.eqlIgnoreCase(u, "%")) return null;
            break :blk2 std.math.clamp(arg.asF64(ctx.number_pool), 0.0, 100.0) * 255.0 / 100.0;
        } else arg.asF64(ctx.number_pool);
    } else parseCalcSpecialNumber(ctx, arg) orelse return null;
    const clamped = if (std.math.isNan(raw)) 0.0 else std.math.clamp(raw, 0.0, 255.0);
    return .{ .value = clamped / 255.0, .missing = false };
}

fn parseRgbAlphaOrMissing(ctx: *BuiltinContext, arg: Value) ?ParsedColorComponent {
    if (isNoneColorToken(ctx, arg)) return .{ .value = 0.0, .missing = true };
    const raw = if (arg.kind() == .number) blk: {
        const unit = if (arg.unitId(ctx.number_pool) == .none) null else ctx.intern_pool.get(arg.unitId(ctx.number_pool));
        break :blk if (unit) |u| blk2: {
            if (!std.ascii.eqlIgnoreCase(u, "%")) return null;
            break :blk2 arg.asF64(ctx.number_pool) / 100.0;
        } else arg.asF64(ctx.number_pool);
    } else parseCalcSpecialNumber(ctx, arg) orelse return null;
    const clamped = if (std.math.isNan(raw)) 0.0 else std.math.clamp(raw, 0.0, 1.0);
    return .{ .value = clamped, .missing = false };
}

fn parseHwbRawChannelForLegacyDegenerate(ctx: *BuiltinContext, arg: Value) ?f64 {
    if (isNoneColorToken(ctx, arg)) return null;
    if (arg.kind() == .number) {
        const unit = if (arg.unitId(ctx.number_pool) == .none) null else ctx.intern_pool.get(arg.unitId(ctx.number_pool));
        const raw = if (unit) |u| blk: {
            if (!std.ascii.eqlIgnoreCase(u, "%")) return null;
            break :blk arg.asF64(ctx.number_pool);
        } else return null;
        return raw;
    }
    return parseCalcSpecialNumber(ctx, arg);
}

fn parseHwbAlphaForLegacyDegenerate(ctx: *BuiltinContext, arg: Value) ?f64 {
    if (isNoneColorToken(ctx, arg)) return 0.0;
    const raw = if (arg.kind() == .number) blk: {
        const unit = if (arg.unitId(ctx.number_pool) == .none) null else ctx.intern_pool.get(arg.unitId(ctx.number_pool));
        break :blk if (unit) |u| blk2: {
            if (!std.ascii.eqlIgnoreCase(u, "%")) return null;
            break :blk2 arg.asF64(ctx.number_pool) / 100.0;
        } else arg.asF64(ctx.number_pool);
    } else parseCalcSpecialNumber(ctx, arg) orelse return null;
    if (std.math.isNan(raw)) return 0.0;
    if (std.math.isInf(raw)) return if (raw < 0.0) 0.0 else 1.0;
    return std.math.clamp(raw, 0.0, 1.0);
}

fn constructorArgsIncludeAlphaForHwb(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) bool {
    for (arg_names) |name_id| {
        if (name_id != .none and argNameMatches(ctx, name_id, "alpha")) return true;
    }
    if (args.len >= 4) return true;
    if (args.len == 1 and args[0].kind() == .list and args[0].listSlash(ctx.list_meta_pool.items) and !args[0].listBracketed(ctx.list_meta_pool.items)) return true;
    return false;
}

fn hwbLegacyDegeneratePassthrough(ctx: *BuiltinContext, alpha: f64, has_alpha: bool) BuiltinError!Value {
    const alpha_css = if (has_alpha) blk: {
        const css = try valueToCssString(ctx, Value.numberUnitless(std.math.clamp(alpha, 0.0, 1.0)));
        break :blk css;
    } else "";
    defer if (has_alpha) ctx.allocator.free(alpha_css);

    const text = if (has_alpha)
        try std.fmt.allocPrint(ctx.allocator, "hsla(calc(NaN), calc(NaN * 1%), calc(NaN * 1%), {s})", .{alpha_css})
    else
        try ctx.allocator.dupe(u8, "hsl(calc(NaN), calc(NaN * 1%), calc(NaN * 1%))");
    defer ctx.allocator.free(text);
    const id = try internString(ctx, text);
    return Value.string(id, false);
}

fn color_hwbImpl(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const bound = bindColorArgs(ctx, args, arg_names, &.{ "hue", "whiteness", "blackness", "alpha" }, true) catch |err| {
        if (err == error.BuiltinArity and shouldSerializeConstructorFallback(ctx, args)) {
            return serializeConstructorListFallback(ctx, "hwb", args, false);
        }
        return err;
    };
    const hue_nan = blk: {
        const hue_arg = bound.values[0].?;
        if (hue_arg.kind() == .number and std.math.isNan(hue_arg.asF64(ctx.number_pool))) break :blk true;
        if (parseCalcSpecialNumber(ctx, hue_arg)) |raw_hue| {
            if (std.math.isNan(raw_hue)) break :blk true;
        }
        break :blk false;
    };
    if (hue_nan and isNoneColorToken(ctx, bound.values[3].?)) {
        if (args.len == 1) {
            const rendered = try valueToCssString(ctx, args[0]);
            defer ctx.allocator.free(rendered);
            const trimmed = std.mem.trim(u8, rendered, " \t\n\r");
            if (splitTopLevelSlash(trimmed)) |parts| {
                const text = try std.fmt.allocPrint(ctx.allocator, "hwb({s} / {s})", .{ parts.left, parts.right });
                defer ctx.allocator.free(text);
                const id = try internString(ctx, text);
                return Value.string(id, false);
            }
        }
        return serializeFallbackFunction(ctx, "hwb", args);
    }
    const h = parseLegacyHueOrMissing(ctx, bound.values[0].?) orelse blk: {
        if (parseCalcSpecialNumber(ctx, bound.values[0].?)) |raw| {
            if (std.math.isNan(raw)) break :blk ParsedColorComponent{ .value = 0.0, .missing = false };
        }
        if (shouldSerializeConstructorFallback(ctx, args)) return serializeConstructorListFallback(ctx, "hwb", args, false);
        return error.BuiltinType;
    };
    const w = parseHwbChannelOrMissing(ctx, bound.values[1].?) orelse {
        if (shouldSerializeConstructorFallback(ctx, args)) return serializeConstructorListFallback(ctx, "hwb", args, false);
        return error.BuiltinType;
    };
    const b = parseHwbChannelOrMissing(ctx, bound.values[2].?) orelse {
        if (shouldSerializeConstructorFallback(ctx, args)) return serializeConstructorListFallback(ctx, "hwb", args, false);
        return error.BuiltinType;
    };
    const alpha = parseLegacyAlphaOrMissing(ctx, bound.values[3].?) orelse {
        if (shouldSerializeConstructorFallback(ctx, args)) return serializeConstructorListFallback(ctx, "hwb", args, false);
        return error.BuiltinType;
    };

    if (!w.missing and !b.missing) {
        const w_raw = parseHwbRawChannelForLegacyDegenerate(ctx, bound.values[1].?);
        const b_raw = parseHwbRawChannelForLegacyDegenerate(ctx, bound.values[2].?);
        if ((w_raw != null and !std.math.isFinite(w_raw.?)) or (b_raw != null and !std.math.isFinite(b_raw.?))) {
            const alpha_raw = parseHwbAlphaForLegacyDegenerate(ctx, bound.values[3].?) orelse alpha.value;
            return hwbLegacyDegeneratePassthrough(ctx, alpha_raw, constructorArgsIncludeAlphaForHwb(ctx, args, arg_names));
        }
    }

    var missing: ColorMissingMask = 0;
    if (h.missing) missing |= 0x1;
    if (w.missing) missing |= 0x2;
    if (b.missing) missing |= 0x4;
    if (alpha.missing) missing |= 0x8;

    const constructed = normalizeChannelColor(color_mod.Color.init(h.value, w.value, b.value, alpha.value, .hwb));
    // HWB with a missing channel serializes as modern color syntax.
    return colorValueFromDeclaredColor(ctx, constructed, .hwb, missing, missing == 0);
}

pub fn color_hwb(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    return color_hwbImpl(ctx, args, arg_names) catch |err| normalizeColorUserError(err);
}

const MixHueMethod = enum {
    shorter,
    longer,
    increasing,
    decreasing,
};

const ParsedMixMethod = struct {
    space: color_mod.ColorSpace,
    hue: MixHueMethod = .shorter,
};

fn normalizeHue(hue: f64) f64 {
    var out = @mod(hue, 360.0);
    if (out < 0.0) out += 360.0;
    return out;
}

fn hueChannelIndex(space: color_mod.ColorSpace) ?usize {
    return switch (space) {
        .hsl, .hwb => 0,
        .lch, .oklch => 2,
        else => null,
    };
}

fn interpolateHueWithMethod(h1: f64, h2: f64, t: f64, method: MixHueMethod) f64 {
    var hue1 = normalizeHue(h1);
    var hue2 = normalizeHue(h2);
    const delta = hue2 - hue1;

    switch (method) {
        .shorter => {
            if (delta > 180.0) hue1 += 360.0 else if (delta < -180.0) hue2 += 360.0;
        },
        .longer => {
            if (delta > 0.0 and delta < 180.0) {
                hue2 += 360.0;
            } else if (delta > -180.0 and delta <= 0.0) {
                hue1 += 360.0;
            }
        },
        .increasing => {
            if (hue2 < hue1) hue2 += 360.0;
        },
        .decreasing => {
            if (hue1 < hue2) hue1 += 360.0;
        },
    }

    return normalizeHue(hue1 * t + hue2 * (1.0 - t));
}

fn powerlessChannelMask(color: color_mod.Color) ColorMissingMask {
    return switch (color.space) {
        .hsl => if (@abs(color.channels[1]) <= 1e-10) 0x1 else 0,
        .hwb => if (color.channels[1] + color.channels[2] >= 100.0 - 1e-10) 0x1 else 0,
        .lch, .oklch => if (@abs(color.channels[1]) <= 1e-10) 0x4 else 0,
        else => 0,
    };
}

fn parseMixMethodValue(ctx: *BuiltinContext, method_value: Value) BuiltinError!ParsedMixMethod {
    var tokens: [3][]const u8 = undefined;
    var token_count: usize = 0;

    if (method_value.isString()) {
        if (method_value.stringQuoted(ctx.string_flags_pool.items)) return error.BuiltinType;
        tokens[0] = ctx.intern_pool.get(method_value.stringIntern());
        token_count = 1;
    } else if (method_value.kind() == .list) {
        if (method_value.listBracketed(ctx.list_meta_pool.items) or method_value.listComma(ctx.list_meta_pool.items) or method_value.listSlash(ctx.list_meta_pool.items)) return error.BuiltinType;
        const items = ctx.list_pool.items[method_value.listHandle()];
        if (items.len == 0 or items.len > 3) return error.BuiltinType;
        for (items, 0..) |item, i| {
            if (!item.isString() or item.stringQuoted(ctx.string_flags_pool.items)) return error.BuiltinType;
            tokens[i] = ctx.intern_pool.get(item.stringIntern());
        }
        token_count = items.len;
    } else {
        return error.BuiltinType;
    }

    if (token_count == 0) return error.BuiltinType;

    var total_bytes: usize = 0;
    for (0..token_count) |i| {
        const raw = tokens[i];
        if (raw.len == 0) return error.BuiltinType;
        total_bytes += raw.len;
    }

    const normalized_storage = try ctx.allocator.alloc(u8, total_bytes);
    defer ctx.allocator.free(normalized_storage);

    var normalized: [3][]u8 = undefined;
    var cursor: usize = 0;
    for (0..token_count) |i| {
        const raw = tokens[i];
        const next = cursor + raw.len;
        const slot = normalized_storage[cursor..next];
        for (raw, 0..) |ch, j| {
            const lower = std.ascii.toLower(ch);
            slot[j] = if (lower == '_') '-' else lower;
        }
        normalized[i] = slot;
        cursor = next;
    }

    const space = parseColorSpaceName(normalized[0]) orelse return error.BuiltinType;
    var parsed = ParsedMixMethod{ .space = space };
    if (token_count == 1) return parsed;
    if (token_count != 3 or !space.isPolar() or !std.mem.eql(u8, normalized[2], "hue")) return error.BuiltinType;

    parsed.hue = if (std.mem.eql(u8, normalized[1], "shorter"))
        .shorter
    else if (std.mem.eql(u8, normalized[1], "longer"))
        .longer
    else if (std.mem.eql(u8, normalized[1], "increasing"))
        .increasing
    else if (std.mem.eql(u8, normalized[1], "decreasing"))
        .decreasing
    else
        return error.BuiltinType;
    return parsed;
}

fn mixLegacyColors(ctx: *BuiltinContext, c1: Value, c2: Value, weight_percent: f64) BuiltinError!Value {
    const c1_srgb = color_mod.convert(localChannelColor(ctx, c1), .srgb);
    const c2_srgb = color_mod.convert(localChannelColor(ctx, c2), .srgb);

    const r1 = c1_srgb.channels[0] * 255.0;
    const g1 = c1_srgb.channels[1] * 255.0;
    const b1 = c1_srgb.channels[2] * 255.0;
    const a1 = c1_srgb.channels[3];
    const r2 = c2_srgb.channels[0] * 255.0;
    const g2 = c2_srgb.channels[1] * 255.0;
    const b2 = c2_srgb.channels[2] * 255.0;
    const a2 = c2_srgb.channels[3];

    const w_raw = weight_percent / 100.0;
    const a_diff = a1 - a2;
    const combined = w_raw * 2.0 - 1.0;
    const w1 = if (@abs(combined * a_diff + 1.0) < 1e-10)
        (combined + 1.0) / 2.0
    else
        ((combined + a_diff) / (1.0 + combined * a_diff) + 1.0) / 2.0;
    const w2 = 1.0 - w1;

    const out = try pushColorEntry(ctx, .{
        .channels = .{
            (r1 * w1 + r2 * w2) / 255.0,
            (g1 * w1 + g2 * w2) / 255.0,
            (b1 * w1 + b2 * w2) / 255.0,
            std.math.clamp(a1 * w_raw + a2 * (1.0 - w_raw), 0.0, 1.0),
        },
        .space = .srgb,
        .missing = 0,
        .legacy = true,
    });
    maybePreferLongHexResult(ctx, out, true);
    return out;
}

fn mixModernColors(ctx: *BuiltinContext, c1: Value, c2: Value, weight_percent: f64, method: ParsedMixMethod) BuiltinError!Value {
    const output_space = declaredColorSpaceFromValue(ctx, c1);
    const left = color_mod.convert(localChannelColor(ctx, c1), method.space);
    const right = color_mod.convert(localChannelColor(ctx, c2), method.space);

    const left_missing = mapMissingChannels(colorMissingMaskFromValue(ctx, c1), declaredColorSpaceFromValue(ctx, c1), method.space) | powerlessChannelMask(left);
    const right_missing = mapMissingChannels(colorMissingMaskFromValue(ctx, c2), declaredColorSpaceFromValue(ctx, c2), method.space) | powerlessChannelMask(right);

    const w1 = std.math.clamp(weight_percent / 100.0, 0.0, 1.0);
    const w2 = 1.0 - w1;

    var result_channels = left.channels;
    var result_missing: ColorMissingMask = 0;
    const hue_idx = hueChannelIndex(method.space);
    const alpha_bit: ColorMissingMask = 0x8;

    const left_alpha_missing = (left_missing & alpha_bit) != 0;
    const right_alpha_missing = (right_missing & alpha_bit) != 0;
    const alpha1 = if (left_alpha_missing) right.channels[3] else left.channels[3];
    const alpha2 = if (right_alpha_missing) left.channels[3] else right.channels[3];
    const mixed_alpha_missing = left_alpha_missing and right_alpha_missing;
    const mixed_alpha = if (mixed_alpha_missing) 0.0 else alpha1 * w1 + alpha2 * w2;
    const left_multiplier = alpha1 * w1;
    const right_multiplier = alpha2 * w2;

    for (0..3) |i| {
        const bit: ColorMissingMask = @as(ColorMissingMask, 1) << @intCast(i);
        var lv = left.channels[i];
        var rv = right.channels[i];
        const l_missing = (left_missing & bit) != 0;
        const r_missing = (right_missing & bit) != 0;

        if (l_missing and r_missing) {
            result_missing |= bit;
            result_channels[i] = 0.0;
            continue;
        }
        if (l_missing) lv = rv;
        if (r_missing) rv = lv;

        if (hue_idx != null and i == hue_idx.?) {
            result_channels[i] = interpolateHueWithMethod(lv, rv, w1, method.hue);
        } else {
            result_channels[i] = if (mixed_alpha_missing)
                lv * w1 + rv * w2
            else if (@abs(mixed_alpha) <= 1e-10)
                0.0
            else
                (lv * left_multiplier + rv * right_multiplier) / mixed_alpha;
        }
    }

    if (mixed_alpha_missing) {
        result_missing |= alpha_bit;
        result_channels[3] = 0.0;
    } else {
        result_channels[3] = mixed_alpha;
    }

    const mixed_in_method = color_mod.Color{
        .channels = result_channels,
        .space = method.space,
    };
    var mixed_output = if (method.space == output_space) mixed_in_method else color_mod.convert(mixed_in_method, output_space);
    var output_missing = mapMissingChannels(result_missing, method.space, output_space);

    if (method.space != output_space and output_missing != 0 and colorLegacyFlagFromValue(ctx, c1) and isLegacyColorSpace(output_space)) {
        for (0..4) |i| {
            const bit: ColorMissingMask = @as(ColorMissingMask, 1) << @intCast(i);
            if ((output_missing & bit) != 0) mixed_output.channels[i] = 0.0;
        }
        output_missing = 0;
    }

    const output_legacy = colorLegacyFlagFromValue(ctx, c1) and isLegacyColorSpace(output_space);
    return colorValueFromDeclaredColor(ctx, mixed_output, output_space, output_missing, output_legacy);
}

fn color_mixImpl(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    if (args.len > 4) return badArity(2, args.len);
    const bound = bindNamedOrPositionalArgs(ctx, args, arg_names, &.{ "color1", "color2", "weight", "method" });
    try validateRequiredBound(&.{ "color1", "color2", "weight", "method" }, &bound, 2);
    const a = tryCoerceColorArg(ctx, bound[0].?) orelse return error.BuiltinType;
    const b = tryCoerceColorArg(ctx, bound[1].?) orelse return error.BuiltinType;
    const weight = if (bound[2]) |wv| try expectNumber(ctx, wv) else 50.0;
    if (weight < 0.0 or weight > 100.0) return error.BuiltinType;

    if (bound[3]) |method_value| {
        const parsed = try parseMixMethodValue(ctx, method_value);
        return mixModernColors(ctx, a, b, weight, parsed);
    }

    if (!colorLegacyFlagFromValue(ctx, a) or !colorLegacyFlagFromValue(ctx, b)) return error.BuiltinType;
    return mixLegacyColors(ctx, a, b, weight);
}

pub fn color_mix(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    try emitColorDeprecation(ctx, "mix() is deprecated; use color.mix() instead");
    return color_mixImpl(ctx, args, arg_names) catch |err| normalizeColorUserError(err);
}

fn hslAdjustedColor(ctx: *BuiltinContext, c: Value, dh: f64, ds: f64, dl: f64) BuiltinError!Value {
    if (!colorLegacyFlagFromValue(ctx, c)) return error.BuiltinType;
    var hsl = colorToHsl(ctx, c);
    hsl[0] = @mod(hsl[0] + dh, 360.0);
    if (hsl[0] < 0) hsl[0] += 360.0;
    hsl[1] = std.math.clamp(hsl[1] + ds, 0.0, 100.0);
    hsl[2] = std.math.clamp(hsl[2] + dl, 0.0, 100.0);
    const source_entry = colorEntryOf(ctx, c);
    const alpha = std.math.clamp(source_entry.channels[3], 0.0, 1.0);
    if ((source_entry.space == .hsl or source_entry.space == .hwb) and source_entry.missing == 0) {
        return colorValueFromDeclaredColor(
            ctx,
            color_mod.Color.init(hsl[0], hsl[1], hsl[2], alpha, .hsl),
            .hsl,
            0,
            true,
        );
    }
    const rgb = hslToSrgbFloat(hsl[0], hsl[1], hsl[2]);
    const out = try colorValueFromDeclaredColor(
        ctx,
        color_mod.Color.init(rgb[0], rgb[1], rgb[2], alpha, .srgb),
        .srgb,
        0,
        true,
    );
    maybePreferLongHexResult(ctx, out, true);
    return out;
}

fn parseLegacyPercentAmount(ctx: *BuiltinContext, arg: Value) BuiltinError!f64 {
    if (arg.kind() != .number) return error.BuiltinType;
    const unit_id = arg.unitId(ctx.number_pool);
    if (unit_id != .none) {
        const unit_name = ctx.intern_pool.get(unit_id);
        if (!std.ascii.eqlIgnoreCase(unit_name, "%")) return error.BuiltinType;
    }
    const value = arg.asF64(ctx.number_pool);
    if (std.math.isNan(value) or value < 0.0 or value > 100.0) return error.BuiltinType;
    return value;
}

fn emitColorDeprecation(ctx: *BuiltinContext, func_name: []const u8) BuiltinError!void {
    const opts = ctx.deprecation_opts orelse return;
    try deprecation_mod.emitDeprecation(opts, .color_functions, func_name, "", 0, 0);
}

pub fn color_lighten(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try emitColorDeprecation(ctx, "lighten() is deprecated; use color.adjust() with $lightness instead");
    try expectArity(args, 2);
    const c = tryCoerceColorArg(ctx, args[0]) orelse return reportArgumentTypeMismatch(ctx, "color", args[0], "color");
    const amt = parseLegacyPercentAmount(ctx, args[1]) catch |err| switch (err) {
        error.BuiltinType => return reportArgumentTypeMismatch(ctx, "amount", args[1], "number"),
        else => return err,
    };
    return hslAdjustedColor(ctx, c, 0.0, 0.0, amt);
}

pub fn color_darken(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try emitColorDeprecation(ctx, "darken() is deprecated; use color.adjust() with $lightness instead");
    try expectArity(args, 2);
    const c = tryCoerceColorArg(ctx, args[0]) orelse return reportArgumentTypeMismatch(ctx, "color", args[0], "color");
    const amt = parseLegacyPercentAmount(ctx, args[1]) catch |err| switch (err) {
        error.BuiltinType => return reportArgumentTypeMismatch(ctx, "amount", args[1], "number"),
        else => return err,
    };
    return hslAdjustedColor(ctx, c, 0.0, 0.0, -amt);
}

pub fn color_saturate(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    if (args.len == 1) {
        const single = args[0];
        if (single.isNumber() or single.kind() == .calc_fragment or single.kind() == .interp_fragment) {
            return serializeFallbackFunction(ctx, "saturate", args);
        }
        if (single.isString()) {
            const raw = shared.stripCalcArgMarker(ctx.intern_pool.get(single.stringIntern()));
            if (single.stringQuoted(ctx.string_flags_pool.items)) {
                if (!isRawCalcString(raw)) return error.BuiltinType;
                const trimmed = std.mem.trim(u8, raw, " \t\n\r");
                const text = try std.fmt.allocPrint(ctx.allocator, "saturate({s})", .{trimmed});
                defer ctx.allocator.free(text);
                const id = try internString(ctx, text);
                return Value.string(id, false);
            }
            if (std.mem.findScalar(u8, raw, '(') == null) return error.BuiltinType;
            if (isRawCalcString(raw)) {
                const trimmed = std.mem.trim(u8, raw, " \t\n\r");
                const text = try std.fmt.allocPrint(ctx.allocator, "saturate({s})", .{trimmed});
                defer ctx.allocator.free(text);
                const id = try internString(ctx, text);
                return Value.string(id, false);
            }
            return serializeFallbackFunction(ctx, "saturate", args);
        }
        return error.BuiltinType;
    }
    try emitColorDeprecation(ctx, "saturate() is deprecated; use color.adjust() with $saturation instead");
    try expectArity(args, 2);
    const c = tryCoerceColorArg(ctx, args[0]) orelse return reportArgumentTypeMismatch(ctx, "color", args[0], "color");
    const amt = parseLegacyPercentAmount(ctx, args[1]) catch |err| switch (err) {
        error.BuiltinType => return reportArgumentTypeMismatch(ctx, "amount", args[1], "number"),
        else => return err,
    };
    return hslAdjustedColor(ctx, c, 0.0, amt, 0.0);
}

pub fn color_desaturate(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try emitColorDeprecation(ctx, "desaturate() is deprecated; use color.adjust() with $saturation instead");
    try expectArity(args, 2);
    const c = tryCoerceColorArg(ctx, args[0]) orelse return reportArgumentTypeMismatch(ctx, "color", args[0], "color");
    const amt = parseLegacyPercentAmount(ctx, args[1]) catch |err| switch (err) {
        error.BuiltinType => return reportArgumentTypeMismatch(ctx, "amount", args[1], "number"),
        else => return err,
    };
    return hslAdjustedColor(ctx, c, 0.0, -amt, 0.0);
}

pub fn color_adjust_hue(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try emitColorDeprecation(ctx, "adjust-hue() is deprecated; use color.adjust() with $hue instead");
    try expectArity(args, 2);
    const c = tryCoerceColorArg(ctx, args[0]) orelse return reportArgumentTypeMismatch(ctx, "color", args[0], "color");
    const parsed_delta = parseLegacyHueOrMissing(ctx, args[1]) orelse return reportArgumentTypeMismatch(ctx, "degrees", args[1], "number");
    if (parsed_delta.missing) return reportArgumentTypeMismatch(ctx, "degrees", args[1], "number");
    const delta = parsed_delta.value;
    return hslAdjustedColor(ctx, c, delta, 0.0, 0.0);
}

const ColorOpKind = enum {
    adjust,
    scale,
    change,
};

const WorkingColorFamily = enum {
    rgb,
    hsl,
    hwb,
    lab,
    lch,
    xyz,
};

const ColorOpChannel = enum {
    red,
    green,
    blue,
    hue,
    saturation,
    lightness,
    whiteness,
    blackness,
    a,
    b,
    chroma,
    x,
    y,
    z,
    alpha,
};

const ParsedColorOpEntry = struct {
    key: ColorOpChannel,
    value: Value,
    is_none: bool = false,
    number: ?f64 = null,
};

const ParsedColorOpArgs = struct {
    color: ?Value = null,
    entries: []ParsedColorOpEntry = &.{},
    has_space_arg: bool = false,
    space: ?color_mod.ColorSpace = null,
    legacy_rgb_channels: bool = false,
    first_channel: ?ColorOpChannel = null,
    has_rgb_channel: bool = false,
    has_hsl_channel: bool = false,
    has_hwb_channel: bool = false,

    fn deinit(self: *ParsedColorOpArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        self.entries = &.{};
    }
};

fn parseColorOpChannel(ctx: *BuiltinContext, name_id: InternId) ?ColorOpChannel {
    if (argNameMatches(ctx, name_id, "red")) return .red;
    if (argNameMatches(ctx, name_id, "green")) return .green;
    if (argNameMatches(ctx, name_id, "blue")) return .blue;
    if (argNameMatches(ctx, name_id, "hue")) return .hue;
    if (argNameMatches(ctx, name_id, "saturation")) return .saturation;
    if (argNameMatches(ctx, name_id, "lightness")) return .lightness;
    if (argNameMatches(ctx, name_id, "whiteness")) return .whiteness;
    if (argNameMatches(ctx, name_id, "blackness")) return .blackness;
    if (argNameMatches(ctx, name_id, "a")) return .a;
    if (argNameMatches(ctx, name_id, "b")) return .b;
    if (argNameMatches(ctx, name_id, "chroma")) return .chroma;
    if (argNameMatches(ctx, name_id, "x")) return .x;
    if (argNameMatches(ctx, name_id, "y")) return .y;
    if (argNameMatches(ctx, name_id, "z")) return .z;
    if (argNameMatches(ctx, name_id, "alpha")) return .alpha;
    return null;
}

fn familyForSpace(space: color_mod.ColorSpace) WorkingColorFamily {
    return switch (space) {
        .srgb, .srgb_linear, .display_p3, .display_p3_linear, .a98_rgb, .prophoto_rgb, .rec2020 => .rgb,
        .hsl => .hsl,
        .hwb => .hwb,
        .lab, .oklab => .lab,
        .lch, .oklch => .lch,
        .xyz_d50, .xyz_d65 => .xyz,
    };
}

fn familyForLegacyChannel(channel: ColorOpChannel) ?WorkingColorFamily {
    return switch (channel) {
        .red, .green, .blue => .rgb,
        .hue, .saturation, .lightness => .hsl,
        .whiteness, .blackness => .hwb,
        else => null,
    };
}

fn defaultWorkingSpace(ctx: *BuiltinContext, c: Value, first_channel: ?ColorOpChannel) color_mod.ColorSpace {
    const declared_space = declaredColorSpaceFromValue(ctx, c);

    if (colorLegacyFlagFromValue(ctx, c)) {
        if (first_channel) |channel| {
            if (channel == .hue) {
                return if (declared_space == .hwb) .hwb else .hsl;
            }
            if (familyForLegacyChannel(channel)) |family| {
                return switch (family) {
                    .rgb => .srgb,
                    .hsl => .hsl,
                    .hwb => .hwb,
                    else => declared_space,
                };
            }
        }
        return declared_space;
    }

    return declared_space;
}

fn colorOpChannelIndex(space: color_mod.ColorSpace, key: ColorOpChannel) ?usize {
    if (key == .alpha) return 3;
    return switch (familyForSpace(space)) {
        .rgb => switch (key) {
            .red => 0,
            .green => 1,
            .blue => 2,
            else => null,
        },
        .hsl => switch (key) {
            .hue => 0,
            .saturation => 1,
            .lightness => 2,
            else => null,
        },
        .hwb => switch (key) {
            .hue => 0,
            .whiteness => 1,
            .blackness => 2,
            else => null,
        },
        .lab => switch (key) {
            .lightness => 0,
            .a => 1,
            .b => 2,
            else => null,
        },
        .lch => switch (key) {
            .lightness => 0,
            .chroma => 1,
            .hue => 2,
            else => null,
        },
        .xyz => switch (key) {
            .x => 0,
            .y => 1,
            .z => 2,
            else => null,
        },
    };
}

fn parseColorOpArgs(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!ParsedColorOpArgs {
    var out: ParsedColorOpArgs = .{};
    var entries: std.ArrayListUnmanaged(ParsedColorOpEntry) = .empty;
    errdefer entries.deinit(ctx.allocator);
    try entries.ensureTotalCapacity(ctx.allocator, args.len);

    for (args, 0..) |arg, i| {
        const name_id: InternId = if (i < arg_names.len) arg_names[i] else .none;
        if (name_id == .none) {
            if (out.color == null) {
                out.color = tryCoerceColorArg(ctx, arg) orelse return error.BuiltinType;
            } else {
                return error.BuiltinType;
            }
            continue;
        }

        if (argNameMatches(ctx, name_id, "color")) {
            if (out.color != null) return error.BuiltinType;
            out.color = tryCoerceColorArg(ctx, arg) orelse return error.BuiltinType;
            continue;
        }

        if (argNameMatches(ctx, name_id, "space")) {
            if (out.has_space_arg) return error.BuiltinType;
            out.has_space_arg = true;
            if (arg.kind() == .nil) {
                out.space = null;
                out.legacy_rgb_channels = false;
            } else if (arg.isString()) {
                if (arg.stringQuoted(ctx.string_flags_pool.items)) return error.BuiltinType;
                const parsed_space = try parseColorSpaceArgString(ctx.intern_pool.get(arg.stringIntern()));
                out.space = parsed_space.space;
                out.legacy_rgb_channels = parsed_space.legacy_rgb_alias;
            } else {
                return error.BuiltinType;
            }
            continue;
        }

        const key = parseColorOpChannel(ctx, name_id) orelse return error.BuiltinType;
        for (entries.items) |existing| {
            if (existing.key == key) return error.BuiltinType;
        }
        try entries.append(ctx.allocator, .{
            .key = key,
            .value = arg,
            .is_none = isNoneColorToken(ctx, arg),
            .number = if (arg.kind() == .number) arg.asF64(ctx.number_pool) else null,
        });
        if (out.first_channel == null and key != .alpha) out.first_channel = key;
        switch (key) {
            .red, .green, .blue => out.has_rgb_channel = true,
            .saturation, .lightness => out.has_hsl_channel = true,
            .whiteness, .blackness => out.has_hwb_channel = true,
            else => {},
        }
    }

    if (out.color == null) return error.BuiltinType;
    if (out.has_rgb_channel and (out.has_hsl_channel or out.has_hwb_channel)) return colorOpSemanticError();
    if (out.has_hwb_channel and out.has_hsl_channel) return colorOpSemanticError();
    out.entries = try entries.toOwnedSlice(ctx.allocator);
    return out;
}

const ColorScaleRange = struct {
    min: f64,
    max: f64,
};

fn colorOpSemanticError() BuiltinError {
    // evalGenericColorOperation* in legacy src/builtin/color.zig is
    // Handle channel mismatch, invalid range, and space mismatch as SassError.
    // If you set this to BuiltinUnsupported, it will be recorded as "unimplemented".
    // Returns the same semantic error.
    return error.SassError;
}

fn wrapHueDeg(h: f64) f64 {
    var out = @mod(h, 360.0);
    if (out < 0.0) out += 360.0;
    return out;
}

fn normalizeColorOpChannel(space: color_mod.ColorSpace, idx: usize, value: f64) f64 {
    return switch (space) {
        .hsl, .hwb => switch (idx) {
            0 => wrapHueDeg(value),
            else => value,
        },
        .lch, .oklch => if (idx == 2) wrapHueDeg(value) else value,
        else => value,
    };
}

fn boundColorOpChannel(space: color_mod.ColorSpace, idx: usize, value: f64) f64 {
    return switch (space) {
        .lab => if (idx == 0) std.math.clamp(value, 0.0, 100.0) else value,
        .lch => switch (idx) {
            0 => std.math.clamp(value, 0.0, 100.0),
            1 => @max(0.0, value),
            else => value,
        },
        .oklab => if (idx == 0) std.math.clamp(value, 0.0, 1.0) else value,
        .oklch => switch (idx) {
            0 => std.math.clamp(value, 0.0, 1.0),
            1 => @max(0.0, value),
            else => value,
        },
        else => value,
    };
}

fn colorScaleRange(space: color_mod.ColorSpace, idx: usize, legacy_rgb_channels: bool) ColorScaleRange {
    return switch (space) {
        .srgb => if (legacy_rgb_channels) .{ .min = 0.0, .max = 255.0 } else .{ .min = 0.0, .max = 1.0 },
        .srgb_linear, .display_p3, .display_p3_linear, .a98_rgb, .prophoto_rgb, .rec2020, .xyz_d50, .xyz_d65 => .{ .min = 0.0, .max = 1.0 },
        .hsl, .hwb => if (idx == 0) .{ .min = 0.0, .max = 360.0 } else .{ .min = 0.0, .max = 100.0 },
        .lab => if (idx == 0) .{ .min = 0.0, .max = 100.0 } else .{ .min = -125.0, .max = 125.0 },
        .lch => switch (idx) {
            0 => .{ .min = 0.0, .max = 100.0 },
            1 => .{ .min = 0.0, .max = 150.0 },
            else => .{ .min = 0.0, .max = 360.0 },
        },
        .oklab => if (idx == 0) .{ .min = 0.0, .max = 1.0 } else .{ .min = -0.4, .max = 0.4 },
        .oklch => switch (idx) {
            0 => .{ .min = 0.0, .max = 1.0 },
            1 => .{ .min = 0.0, .max = 0.4 },
            else => .{ .min = 0.0, .max = 360.0 },
        },
    };
}

fn normalizeHwbChannels(channels: *[3]f64) void {
    channels[0] = wrapHueDeg(channels[0]);
    const total = channels[1] + channels[2];
    if (total > 100.0) {
        const scale = 100.0 / total;
        channels[1] *= scale;
        channels[2] *= scale;
    }
}

fn colorOpChannelParamLabel(key: ColorOpChannel) []const u8 {
    return switch (key) {
        .red => "red",
        .green => "green",
        .blue => "blue",
        .hue => "hue",
        .saturation => "saturation",
        .lightness => "lightness",
        .whiteness => "whiteness",
        .blackness => "blackness",
        .a => "a",
        .b => "b",
        .chroma => "chroma",
        .x => "x",
        .y => "y",
        .z => "z",
        .alpha => "alpha",
    };
}

fn setColorOpScalePercentRangeError(ctx: *BuiltinContext, key: ColorOpChannel, number: Value) void {
    const raw = number.asF64(ctx.number_pool);
    const unit_id = number.unitId(ctx.number_pool);
    const unit = if (unit_id == .none) null else ctx.intern_pool.get(unit_id);
    const val_s = value_format.formatNumberWithUnit(ctx.allocator, raw, unit) catch return;
    defer ctx.allocator.free(val_s);
    const pname = colorOpChannelParamLabel(key);
    const msg = std.fmt.allocPrint(ctx.allocator, "${s}: Expected {s} to be within -100% and 100%.", .{ pname, val_s }) catch return;
    defer ctx.allocator.free(msg);
    error_format.setContextMessage(msg);
}

fn validateColorOpNumber(
    ctx: *BuiltinContext,
    kind: ColorOpKind,
    space: color_mod.ColorSpace,
    key: ColorOpChannel,
    number: Value,
    legacy_rgb_channels: bool,
) BuiltinError!f64 {
    if (number.kind() != .number) return error.BuiltinType;

    const raw = number.asF64(ctx.number_pool);
    const unit = if (number.unitId(ctx.number_pool) == .none) null else ctx.intern_pool.get(number.unitId(ctx.number_pool));

    if (key == .alpha) {
        if (kind == .scale) {
            if (unit == null or !std.mem.eql(u8, unit.?, "%")) return colorOpSemanticError();
            if (raw < -100.0 or raw > 100.0) {
                setColorOpScalePercentRangeError(ctx, key, number);
                return colorOpSemanticError();
            }
            return raw / 100.0;
        }
        if (kind == .adjust) {
            return raw;
        }
        const alpha_value = if (unit) |u|
            if (std.mem.eql(u8, u, "%")) raw / 100.0 else raw
        else
            raw;
        if (alpha_value < 0.0 or alpha_value > 1.0) return colorOpSemanticError();
        return alpha_value;
    }

    const idx = colorOpChannelIndex(space, key) orelse return colorOpSemanticError();
    const family = familyForSpace(space);
    const is_hue_channel = (((family == .hsl or family == .hwb) and idx == 0) or
        (family == .lch and idx == 2));
    if (is_hue_channel) {
        if (kind == .scale) return colorOpSemanticError();
        if (unit) |u| {
            if (std.mem.eql(u8, u, "%")) return colorOpSemanticError();
        }
        return color_mod.convertAngleToDeg(raw, unit);
    }

    if (kind != .scale and family == .hsl and idx != 0) {
        return raw;
    }

    const accepts_legacy_percentless = kind == .change and family == .hsl and idx != 0;
    const require_percent = switch (family) {
        .hsl, .hwb => idx != 0 and !accepts_legacy_percentless,
        else => kind == .scale,
    };

    if (require_percent) {
        if (unit == null or !std.mem.eql(u8, unit.?, "%")) return colorOpSemanticError();
    } else if (!accepts_legacy_percentless and unit != null and !std.mem.eql(u8, unit.?, "%")) {
        return colorOpSemanticError();
    }

    if (kind == .scale) {
        if (raw < -100.0 or raw > 100.0) {
            setColorOpScalePercentRangeError(ctx, key, number);
            return colorOpSemanticError();
        }
        return raw / 100.0;
    }

    if (unit != null and std.mem.eql(u8, unit.?, "%")) {
        return switch (space) {
            .srgb => if (legacy_rgb_channels) raw * 255.0 / 100.0 else raw / 100.0,
            .srgb_linear, .display_p3, .display_p3_linear, .a98_rgb, .prophoto_rgb, .rec2020 => raw / 100.0,
            .lab => if (idx == 0) raw else raw * 1.25,
            .lch => if (idx == 0) raw else if (idx == 1) raw * 1.5 else raw,
            .oklab => if (idx == 0) raw / 100.0 else raw * 0.004,
            .oklch => if (idx == 0) raw / 100.0 else if (idx == 1) raw * 0.004 else raw,
            .xyz_d50, .xyz_d65 => raw / 100.0,
            .hsl, .hwb => raw,
        };
    }

    return raw;
}

fn ensureColorOpChannelPresent(
    kind: ColorOpKind,
    working_space: color_mod.ColorSpace,
    key: ColorOpChannel,
    missing: ColorMissingMask,
) BuiltinError!void {
    if (kind == .change) return;
    const idx = colorOpChannelIndex(working_space, key) orelse return colorOpSemanticError();
    const bit: ColorMissingMask = @as(ColorMissingMask, 1) << @intCast(idx);
    if ((missing & bit) != 0) return colorOpSemanticError();
}

fn applyColorOpEntry(
    ctx: *BuiltinContext,
    kind: ColorOpKind,
    working_space: color_mod.ColorSpace,
    legacy_rgb_channels: bool,
    entry: ParsedColorOpEntry,
    projected_channels: *[3]f64,
    projected_alpha: *f64,
    projected_missing: *ColorMissingMask,
) BuiltinError!void {
    const idx = colorOpChannelIndex(working_space, entry.key) orelse return colorOpSemanticError();

    if (entry.is_none) {
        if (kind != .change) return colorOpSemanticError();
        if (idx < 3) {
            projected_missing.* |= @as(ColorMissingMask, 1) << @intCast(idx);
            projected_channels[idx] = 0.0;
        } else {
            projected_missing.* |= 0x8;
            projected_alpha.* = 0.0;
        }
    } else {
        const value = try validateColorOpNumber(ctx, kind, working_space, entry.key, entry.value, legacy_rgb_channels);
        switch (kind) {
            .adjust => {
                if (idx < 3) {
                    projected_channels[idx] = boundColorOpChannel(
                        working_space,
                        idx,
                        normalizeColorOpChannel(working_space, idx, projected_channels[idx] + value),
                    );
                } else {
                    projected_alpha.* += value;
                }
            },
            .scale => {
                if (idx < 3) {
                    const range = colorScaleRange(working_space, idx, legacy_rgb_channels);
                    projected_channels[idx] = boundColorOpChannel(
                        working_space,
                        idx,
                        color_mod.scaleValueInRange(projected_channels[idx], range.min, range.max, value),
                    );
                } else {
                    projected_alpha.* = color_mod.scaleValueInRange(projected_alpha.*, 0.0, 1.0, value);
                }
            },
            .change => {
                if (idx < 3) {
                    projected_channels[idx] = normalizeColorOpChannel(working_space, idx, value);
                    projected_missing.* &= ~(@as(ColorMissingMask, 1) << @intCast(idx));
                } else {
                    projected_alpha.* = value;
                    projected_missing.* &= ~@as(ColorMissingMask, 0x8);
                }
            },
        }
    }

    if (working_space == .hwb) normalizeHwbChannels(projected_channels);
}

fn postValidateColorOpChannel(
    kind: ColorOpKind,
    working_space: color_mod.ColorSpace,
    key: ColorOpChannel,
    projected_channels: [3]f64,
    projected_missing: ColorMissingMask,
) BuiltinError!void {
    try ensureColorOpChannelPresent(kind, working_space, key, projected_missing);
    if (kind == .change) return;

    const idx = colorOpChannelIndex(working_space, key) orelse return colorOpSemanticError();
    if (idx < 3 and isPowerlessInSpace(working_space, projected_channels, idx)) {
        return colorOpSemanticError();
    }
}

fn applyColorOperation(
    ctx: *BuiltinContext,
    kind: ColorOpKind,
    args: []const Value,
    arg_names: []const InternId,
) BuiltinError!Value {
    if (args.len < 1) return badArity(1, args.len);

    var parsed = try parseColorOpArgs(ctx, args, arg_names);
    defer parsed.deinit(ctx.allocator);

    const c = parsed.color orelse return error.BuiltinType;
    const source_declared_space = declaredColorSpaceFromValue(ctx, c);
    const source_missing = colorMissingMaskFromValue(ctx, c);
    const source_legacy = colorLegacyCompatFlagFromValue(ctx, c);
    const source_generated_hsl_from_legacy_srgb = c.kind() == .color and
        c.colorEntry(ctx.color_pool).prefer_long_hex and
        source_legacy and
        source_declared_space == .hsl;

    if (parsed.entries.len == 0) {
        if (!parsed.has_space_arg) return c;
        const explicit_space = parsed.space orelse return c;
        if (explicit_space == source_declared_space) return c;

        var working = color_mod.convert(localChannelColor(ctx, c), explicit_space);
        working = normalizeChannelColor(working);

        var projected_missing = mapMissingChannels(source_missing, source_declared_space, explicit_space);
        if (source_legacy and source_missing != 0) {
            // Equivalent to legacy side `evalGenericColorOperation`:
            // No-op with explicit space conversion of legacy color with missing is
            // Don't keep missing and drop it to actual color.
            projected_missing = 0;
        }

        const output_color = color_mod.convert(working, source_declared_space);
        var output_missing = mapMissingChannels(projected_missing, explicit_space, source_declared_space);
        if (!source_legacy) {
            if (hueChannelIndex(source_declared_space)) |hue_idx| {
                const channels3 = [3]f64{ output_color.channels[0], output_color.channels[1], output_color.channels[2] };
                if (isPowerlessInSpace(source_declared_space, channels3, hue_idx)) {
                    output_missing |= @as(ColorMissingMask, 1) << @intCast(hue_idx);
                }
            }
        }
        return colorValueFromDeclaredColor(ctx, output_color, source_declared_space, output_missing, source_legacy);
    }

    const default_space = defaultWorkingSpace(ctx, c, parsed.first_channel);
    const implicit_space = if (parsed.has_hwb_channel and source_legacy) color_mod.ColorSpace.hwb else default_space;
    const working_space = if (parsed.has_space_arg) (parsed.space orelse implicit_space) else implicit_space;
    const legacy_rgb_channels = working_space == .srgb and
        (parsed.legacy_rgb_channels or (parsed.space == null and source_legacy));

    const working = color_mod.convert(localChannelColor(ctx, c), working_space);
    var projected_channels = [3]f64{ working.channels[0], working.channels[1], working.channels[2] };
    if (legacy_rgb_channels) {
        projected_channels[0] *= 255.0;
        projected_channels[1] *= 255.0;
        projected_channels[2] *= 255.0;
    }
    var projected_alpha = working.channels[3];
    var projected_missing = mapMissingChannels(source_missing, source_declared_space, working_space);

    for (parsed.entries) |entry| {
        try applyColorOpEntry(
            ctx,
            kind,
            working_space,
            legacy_rgb_channels,
            entry,
            &projected_channels,
            &projected_alpha,
            &projected_missing,
        );
    }

    if ((working_space == .lch or working_space == .oklch) and projected_channels[1] < 0.0) {
        projected_channels[1] = -projected_channels[1];
        projected_channels[2] = normalizeColorOpChannel(working_space, 2, projected_channels[2] + 180.0);
    }

    for (parsed.entries) |entry| {
        try postValidateColorOpChannel(kind, working_space, entry.key, projected_channels, projected_missing);
    }

    const clamped_alpha = std.math.clamp(projected_alpha, 0.0, 1.0);
    if (kind == .adjust and source_legacy and source_declared_space == .srgb and working_space == .srgb and legacy_rgb_channels) {
        const out = try colorValueFromDeclaredColor(
            ctx,
            color_mod.Color.init(
                std.math.clamp(projected_channels[0], 0.0, 255.0) / 255.0,
                std.math.clamp(projected_channels[1], 0.0, 255.0) / 255.0,
                std.math.clamp(projected_channels[2], 0.0, 255.0) / 255.0,
                clamped_alpha,
                .srgb,
            ),
            .srgb,
            projected_missing,
            true,
        );
        maybePreferLongHexResult(ctx, out, true);
        return out;
    }
    if (kind == .adjust and source_legacy and source_declared_space == .srgb and working_space == .hsl and projected_missing == 0) {
        if (projected_channels[1] < 0.0) {
            var srgb = color_mod.convert(
                color_mod.Color.init(projected_channels[0], 0.0, projected_channels[2], clamped_alpha, .hsl),
                .srgb,
            );
            srgb.channels[0] = std.math.clamp(srgb.channels[0], 0.0, 1.0);
            srgb.channels[1] = std.math.clamp(srgb.channels[1], 0.0, 1.0);
            srgb.channels[2] = std.math.clamp(srgb.channels[2], 0.0, 1.0);
            const out = try colorValueFromDeclaredColor(ctx, srgb, .srgb, 0, true);
            maybePreferLongHexResult(ctx, out, true);
            return out;
        }
        if (projected_channels[1] > 100.0 or projected_channels[2] < 0.0 or projected_channels[2] > 100.0) {
            const out = try colorValueFromDeclaredColor(
                ctx,
                color_mod.Color.init(projected_channels[0], projected_channels[1], projected_channels[2], clamped_alpha, .hsl),
                .hsl,
                0,
                true,
            );
            out.colorEntryMut(ctx.color_pool).prefer_long_hex = true;
            return out;
        }
    }
    if (kind == .adjust and source_generated_hsl_from_legacy_srgb and working_space == .hsl and projected_missing == 0 and
        projected_channels[1] >= 0.0 and projected_channels[1] <= 100.0 and
        projected_channels[2] >= 0.0 and projected_channels[2] <= 100.0)
    {
        const srgb = color_mod.convert(
            color_mod.Color.init(projected_channels[0], projected_channels[1], projected_channels[2], clamped_alpha, .hsl),
            .srgb,
        );
        return colorValueFromDeclaredColor(ctx, srgb, .srgb, 0, true);
    }
    if (kind == .change and source_legacy and source_declared_space == .srgb and working_space == .hsl and projected_missing == 0) {
        if (projected_channels[1] > 100.0 or projected_channels[2] < 0.0 or projected_channels[2] > 100.0) {
            return colorValueFromDeclaredColor(
                ctx,
                color_mod.Color.init(projected_channels[0], projected_channels[1], projected_channels[2], clamped_alpha, .hsl),
                .hsl,
                0,
                true,
            );
        }
    }

    var result_working = color_mod.Color.init(
        if (legacy_rgb_channels) projected_channels[0] / 255.0 else projected_channels[0],
        if (legacy_rgb_channels) projected_channels[1] / 255.0 else projected_channels[1],
        if (legacy_rgb_channels) projected_channels[2] / 255.0 else projected_channels[2],
        clamped_alpha,
        working_space,
    );
    if (!legacy_rgb_channels) {
        result_working = normalizeChannelColor(result_working);
    }

    var output_color = if (working_space == source_declared_space)
        result_working
    else
        color_mod.convert(result_working, source_declared_space);
    var output_missing = if (working_space == source_declared_space)
        projected_missing
    else
        mapMissingChannels(projected_missing, working_space, source_declared_space);
    // Processing a legacy rgb/hsl value through another color space normalizes
    // the result as an actual color rather than preserving missing channels.
    const had_mapped_missing = output_missing != 0;
    if (source_legacy and working_space != source_declared_space) {
        output_missing = 0;
        if (source_declared_space == .srgb and had_mapped_missing) {
            output_color.channels[0] = std.math.clamp(output_color.channels[0], 0.0, 1.0);
            output_color.channels[1] = std.math.clamp(output_color.channels[1], 0.0, 1.0);
            output_color.channels[2] = std.math.clamp(output_color.channels[2], 0.0, 1.0);
        }
    }

    var output_legacy = source_legacy and output_missing == 0;
    if (source_legacy and source_declared_space == .srgb and output_missing != 0) {
        output_legacy = true;
    }
    const prefer_long_hex = output_legacy and source_declared_space == .srgb and
        (kind == .change or
            working_space == .hwb or
            (kind == .adjust and working_space == .hsl));
    const out = try colorValueFromDeclaredColor(ctx, output_color, source_declared_space, output_missing, output_legacy);
    maybePreferLongHexResult(ctx, out, prefer_long_hex);
    return out;
}

pub fn color_scale(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    return applyColorOperation(ctx, .scale, args, arg_names);
}

pub fn color_adjust(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    return applyColorOperation(ctx, .adjust, args, arg_names);
}

pub fn color_change(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    return applyColorOperation(ctx, .change, args, arg_names);
}

fn isNoneColorToken(ctx: *BuiltinContext, v: Value) bool {
    if (v.kind() != .string or v.stringQuoted(ctx.string_flags_pool.items)) return false;
    return std.ascii.eqlIgnoreCase(ctx.intern_pool.get(v.stringIntern()), "none");
}

const ParsedColorComponent = struct { value: f64, missing: bool };

fn parseColorFunctionChannel(ctx: *BuiltinContext, v: Value) BuiltinError!ParsedColorComponent {
    if (isNoneColorToken(ctx, v)) return .{ .value = 0.0, .missing = true };
    if (v.kind() != .number) return error.BuiltinType;
    const unit = if (v.unitId(ctx.number_pool) == .none) null else ctx.intern_pool.get(v.unitId(ctx.number_pool));
    if (unit) |u| {
        if (!std.ascii.eqlIgnoreCase(u, "%")) return error.BuiltinType;
        return .{ .value = v.asF64(ctx.number_pool) / 100.0, .missing = false };
    }
    return .{ .value = v.asF64(ctx.number_pool), .missing = false };
}

fn parseCalcSpecialNumber(ctx: *BuiltinContext, v: Value) ?f64 {
    var owned: ?[]const u8 = null;
    defer if (owned) |buf| ctx.allocator.free(buf);

    const raw: []const u8 = blk: {
        if (v.isString()) {
            if (v.stringQuoted(ctx.string_flags_pool.items)) return null;
            break :blk std.mem.trim(u8, ctx.intern_pool.get(v.stringIntern()), " \t\n\r");
        }
        if (v.kind() == .calc_fragment or v.kind() == .interp_fragment) {
            const css = valueToCssString(ctx, v) catch return null;
            owned = css;
            break :blk std.mem.trim(u8, css, " \t\n\r");
        }
        return null;
    };

    if (!(std.ascii.startsWithIgnoreCase(raw, "calc(") and raw.len >= 6 and raw[raw.len - 1] == ')')) return null;
    const inner = std.mem.trim(u8, raw[5 .. raw.len - 1], " \t\n\r");

    var compact_buf: [96]u8 = undefined;
    var compact_len: usize = 0;
    for (inner) |ch| {
        if (std.ascii.isWhitespace(ch)) continue;
        if (compact_len >= compact_buf.len) return null;
        compact_buf[compact_len] = std.ascii.toLower(ch);
        compact_len += 1;
    }
    const compact = compact_buf[0..compact_len];
    if (compact.len == 0) return null;

    if (std.mem.eql(u8, compact, "infinity") or std.mem.eql(u8, compact, "+infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, compact, "-infinity")) return -std.math.inf(f64);
    if (std.mem.eql(u8, compact, "nan") or std.mem.eql(u8, compact, "+nan") or std.mem.eql(u8, compact, "-nan")) return std.math.nan(f64);

    const mul = std.mem.findScalar(u8, compact, '*') orelse return null;
    const lhs = compact[0..mul];
    const rhs = compact[mul + 1 ..];
    if (!(std.mem.eql(u8, rhs, "1%") or std.mem.eql(u8, rhs, "1deg") or std.mem.eql(u8, rhs, "1grad") or std.mem.eql(u8, rhs, "1rad") or std.mem.eql(u8, rhs, "1turn"))) {
        return null;
    }

    if (std.mem.eql(u8, lhs, "infinity") or std.mem.eql(u8, lhs, "+infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, lhs, "-infinity")) return -std.math.inf(f64);
    if (std.mem.eql(u8, lhs, "nan") or std.mem.eql(u8, lhs, "+nan") or std.mem.eql(u8, lhs, "-nan")) return std.math.nan(f64);
    return null;
}

fn parseColorFunctionAlpha(ctx: *BuiltinContext, v: Value) BuiltinError!ParsedColorComponent {
    if (isNoneColorToken(ctx, v)) return .{ .value = 0.0, .missing = true };
    const raw = if (v.kind() == .number) blk: {
        const unit = if (v.unitId(ctx.number_pool) == .none) null else ctx.intern_pool.get(v.unitId(ctx.number_pool));
        break :blk if (unit) |u| blk2: {
            if (!std.ascii.eqlIgnoreCase(u, "%")) return error.BuiltinType;
            break :blk2 v.asF64(ctx.number_pool) / 100.0;
        } else v.asF64(ctx.number_pool);
    } else parseCalcSpecialNumber(ctx, v) orelse return error.BuiltinType;
    const clamped = if (std.math.isNan(raw)) 0.0 else std.math.clamp(raw, 0.0, 1.0);
    return .{ .value = clamped, .missing = false };
}

fn isRelativeColorDescription(ctx: *BuiltinContext, list_value: Value) bool {
    if (list_value.kind() != .list or list_value.listBracketed(ctx.list_meta_pool.items) or list_value.listComma(ctx.list_meta_pool.items)) return false;
    const items = ctx.list_pool.items[list_value.listHandle()];
    if (items.len == 0) return false;
    if (items[0].kind() == .string and !items[0].stringQuoted(ctx.string_flags_pool.items)) {
        return std.ascii.eqlIgnoreCase(ctx.intern_pool.get(items[0].stringIntern()), "from");
    }
    if (list_value.listSlash(ctx.list_meta_pool.items) and items.len == 2 and items[0].kind() == .list and !items[0].listComma(ctx.list_meta_pool.items) and !items[0].listBracketed(ctx.list_meta_pool.items)) {
        const head = ctx.list_pool.items[items[0].listHandle()];
        if (head.len == 0) return false;
        if (head[0].kind() != .string or head[0].stringQuoted(ctx.string_flags_pool.items)) return false;
        return std.ascii.eqlIgnoreCase(ctx.intern_pool.get(head[0].stringIntern()), "from");
    }
    return false;
}

fn parseColorConstructorSlots(
    ctx: *BuiltinContext,
    description: Value,
) BuiltinError!struct {
    space: color_mod.ColorSpace,
    c0: Value,
    c1: Value,
    c2: Value,
    alpha: ?Value,
} {
    if (description.kind() != .list or description.listComma(ctx.list_meta_pool.items) or description.listBracketed(ctx.list_meta_pool.items)) return error.BuiltinType;
    const items = ctx.list_pool.items[description.listHandle()];
    if (items.len < 2) return error.BuiltinType;

    if (description.listSlash(ctx.list_meta_pool.items) and items.len == 2 and items[0].kind() == .list and !items[0].listComma(ctx.list_meta_pool.items) and !items[0].listBracketed(ctx.list_meta_pool.items)) {
        const head = ctx.list_pool.items[items[0].listHandle()];
        if (head.len < 4 or head[0].kind() != .string) return error.BuiltinType;
        const head_space_name = ctx.intern_pool.get(head[0].stringIntern());
        const head_space = parseColorSpaceName(head_space_name) orelse return error.BuiltinType;
        return .{
            .space = head_space,
            .c0 = head[1],
            .c1 = head[2],
            .c2 = head[3],
            .alpha = items[1],
        };
    }

    if (items.len < 4) return error.BuiltinType;
    if (items[0].kind() != .string) return error.BuiltinType;

    const space_name = ctx.intern_pool.get(items[0].stringIntern());
    const space = parseColorSpaceName(space_name) orelse return error.BuiltinType;

    const c0_arg = items[1];
    const c1_arg = items[2];
    // SAFETY: initialized before first read in this scope.
    var c2_arg: Value = undefined;
    var alpha_arg: ?Value = null;

    if (items.len == 4) {
        if (items[3].kind() == .list and items[3].listSlash(ctx.list_meta_pool.items) and !items[3].listBracketed(ctx.list_meta_pool.items)) {
            const tail = ctx.list_pool.items[items[3].listHandle()];
            if (tail.len != 2) return error.BuiltinType;
            c2_arg = tail[0];
            alpha_arg = tail[1];
        } else {
            c2_arg = items[3];
        }
    } else {
        return error.BuiltinType;
    }

    if (c2_arg.kind() == .list and c2_arg.listSlash(ctx.list_meta_pool.items) and !c2_arg.listBracketed(ctx.list_meta_pool.items)) {
        const tail = ctx.list_pool.items[c2_arg.listHandle()];
        if (tail.len == 2) {
            c2_arg = tail[0];
            if (alpha_arg == null) {
                alpha_arg = tail[1];
            } else {
                return error.BuiltinType;
            }
        }
    }

    if (alpha_arg == null) {
        if (try splitSlashValue(ctx, c2_arg)) |parts| {
            c2_arg = parts.left;
            alpha_arg = parts.right;
        }
    }

    return .{
        .space = space,
        .c0 = c0_arg,
        .c1 = c1_arg,
        .c2 = c2_arg,
        .alpha = alpha_arg,
    };
}

fn parseInlineColorToken(ctx: *BuiltinContext, token: []const u8) BuiltinError!Value {
    const t = std.mem.trim(u8, token, " \t\n\r");
    if (t.len == 0) return error.BuiltinType;
    if (t.len > 1 and std.mem.endsWith(u8, t, "%")) {
        const num_text = std.mem.trim(u8, t[0 .. t.len - 1], " \t\n\r");
        const n = std.fmt.parseFloat(f64, num_text) catch {
            const id = try internString(ctx, t);
            return Value.string(id, false);
        };
        return try Value.number(n, try internString(ctx, "%"), ctx.number_pool, ctx.allocator);
    }

    const known_units = [_][]const u8{ "deg", "rad", "grad", "turn" };
    inline for (known_units) |unit| {
        if (t.len > unit.len and std.ascii.endsWithIgnoreCase(t, unit)) {
            const num_text = std.mem.trim(u8, t[0 .. t.len - unit.len], " \t\n\r");
            const n = std.fmt.parseFloat(f64, num_text) catch {
                const id = try internString(ctx, t);
                return Value.string(id, false);
            };
            return try Value.number(n, try internString(ctx, unit), ctx.number_pool, ctx.allocator);
        }
    }
    const n = std.fmt.parseFloat(f64, t) catch {
        const id = try internString(ctx, t);
        return Value.string(id, false);
    };
    return Value.numberUnitless(n);
}

fn hasColorPassthroughArgument(ctx: *BuiltinContext, description: Value) bool {
    if (description.kind() != .list) return valueLooksLikeColorPassthrough(ctx, description);
    const items = ctx.list_pool.items[description.listHandle()];
    if (items.len == 0) return false;
    for (items, 0..) |item, idx| {
        if (idx == 0 and item.kind() == .string and !item.stringQuoted(ctx.string_flags_pool.items)) continue;
        if (valueLooksLikeColorPassthrough(ctx, item)) return true;
    }
    return false;
}

fn color_colorImpl(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    if (args.len == 0) return badArity(1, args.len);
    if (args.len == 1 and (arg_names.len == 0 or arg_names[0] == .none) and args[0].kind() == .color) return args[0];

    var has_named = false;
    for (arg_names) |name_id| {
        if (name_id != .none) {
            has_named = true;
            break;
        }
    }

    var description_opt: ?Value = null;
    if (has_named) {
        const bound = bindNamedOrPositionalArgs(ctx, args, arg_names, &.{ "description", "space", "channels", "alpha" });
        if (bound[0] != null and (bound[1] != null or bound[2] != null or bound[3] != null)) return error.BuiltinArity;
        if (bound[0]) |desc| {
            description_opt = desc;
        } else {
            const space_v = bound[1] orelse return reportMissingArgument("space");
            const channels_v = bound[2] orelse return reportMissingArgument("channels");
            if (space_v.kind() != .string) return error.BuiltinType;
            if (channels_v.kind() != .list or channels_v.listComma(ctx.list_meta_pool.items) or channels_v.listBracketed(ctx.list_meta_pool.items)) return error.BuiltinType;
            const channels = ctx.list_pool.items[channels_v.listHandle()];
            if (channels.len < 3 or channels.len > 4) return error.BuiltinType;
            var items_buf: [5]Value = undefined;
            items_buf[0] = space_v;
            items_buf[1] = channels[0];
            items_buf[2] = channels[1];
            items_buf[3] = channels[2];
            var item_count: usize = 4;
            if (channels.len == 4) {
                items_buf[4] = channels[3];
                item_count = 5;
            }
            if (bound[3]) |alpha_v| {
                if (item_count != 4) return error.BuiltinArity;
                const head = try pushList(ctx, items_buf[0..item_count]);
                const slash_items = try ctx.allocator.dupe(Value, &.{ head, alpha_v });
                const slash_handle: u32 = @intCast(ctx.list_pool.items.len);
                {
                    errdefer ctx.allocator.free(slash_items);
                    try ctx.list_pool.append(ctx.allocator, slash_items);
                }
                errdefer {
                    _ = ctx.list_pool.pop();
                    ctx.allocator.free(slash_items);
                }
                try shared.maybeNoteListParentSelNoneHook(ctx, slash_handle, slash_items);
                description_opt = Value.listWithSlash(slash_handle, false);
            } else {
                description_opt = try pushList(ctx, items_buf[0..item_count]);
            }
        }
    } else if (args.len == 1) {
        description_opt = args[0];
    } else {
        return error.BuiltinType;
    }

    const description = description_opt orelse return error.BuiltinType;
    if (isRelativeColorDescription(ctx, description)) {
        return serializeConstructorListFallback(ctx, "color", &.{description}, false);
    }

    const slots = parseColorConstructorSlots(ctx, description) catch |err| switch (err) {
        error.BuiltinType => {
            if (hasColorPassthroughArgument(ctx, description)) {
                return serializeFallbackFunction(ctx, "color", args);
            }
            return error.BuiltinType;
        },
        else => return err,
    };
    switch (slots.space) {
        .hsl, .hwb, .lab, .lch, .oklab, .oklch => return error.BuiltinType,
        else => {},
    }
    if (slots.alpha != null) {
        if (parseCalcSpecialNumber(ctx, slots.c2)) |raw| {
            if (!std.math.isFinite(raw)) {
                return serializeConstructorListFallback(ctx, "color", &.{description}, false);
            }
        }
    }

    const c0 = parseColorFunctionChannel(ctx, slots.c0) catch |err| {
        if (err == error.BuiltinType and slots.c0.kind() == .string and !slots.c0.stringQuoted(ctx.string_flags_pool.items) and std.mem.findScalar(u8, ctx.intern_pool.get(slots.c0.stringIntern()), '(') != null) {
            return serializeConstructorListFallback(ctx, "color", &.{description}, false);
        }
        return err;
    };
    const c1 = parseColorFunctionChannel(ctx, slots.c1) catch |err| {
        if (err == error.BuiltinType and slots.c1.kind() == .string and !slots.c1.stringQuoted(ctx.string_flags_pool.items) and std.mem.findScalar(u8, ctx.intern_pool.get(slots.c1.stringIntern()), '(') != null) {
            return serializeConstructorListFallback(ctx, "color", &.{description}, false);
        }
        return err;
    };
    const c2 = parseColorFunctionChannel(ctx, slots.c2) catch |err| {
        if (err == error.BuiltinType and slots.c2.kind() == .string and !slots.c2.stringQuoted(ctx.string_flags_pool.items) and std.mem.findScalar(u8, ctx.intern_pool.get(slots.c2.stringIntern()), '(') != null) {
            return serializeConstructorListFallback(ctx, "color", &.{description}, false);
        }
        return err;
    };
    const alpha: ParsedColorComponent = if (slots.alpha) |a|
        parseColorFunctionAlpha(ctx, a) catch |err| {
            if (err == error.BuiltinType and valueLooksLikeColorPassthrough(ctx, a)) {
                return serializeConstructorListFallback(ctx, "color", &.{description}, false);
            }
            return err;
        }
    else
        .{ .value = 1.0, .missing = false };

    var missing: ColorMissingMask = 0;
    if (c0.missing) missing |= 0b0001;
    if (c1.missing) missing |= 0b0010;
    if (c2.missing) missing |= 0b0100;
    if (alpha.missing) missing |= 0b1000;

    const primitive = normalizeChannelColor(color_mod.Color.init(c0.value, c1.value, c2.value, alpha.value, slots.space));
    return colorValueFromDeclaredColor(ctx, primitive, slots.space, missing, false);
}

pub fn color_color(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    return color_colorImpl(ctx, args, arg_names) catch |err| normalizeColorUserError(err);
}

fn colorSpaceNameEq(name: []const u8, canonical: []const u8) bool {
    if (name.len != canonical.len) return false;
    for (name, canonical) |actual, expected| {
        const normalized = if (actual == '_') '-' else actual;
        if (std.ascii.toLower(normalized) != std.ascii.toLower(expected)) return false;
    }
    return true;
}

fn parseColorSpaceName(name: []const u8) ?color_mod.ColorSpace {
    const t = std.mem.trim(u8, shared.stripCalcArgMarker(name), " \t\n\r");
    if (colorSpaceNameEq(t, "rgb")) return .srgb;
    if (colorSpaceNameEq(t, "srgb")) return .srgb;
    if (colorSpaceNameEq(t, "srgb-linear")) return .srgb_linear;
    if (colorSpaceNameEq(t, "display-p3")) return .display_p3;
    if (colorSpaceNameEq(t, "display-p3-linear")) return .display_p3_linear;
    if (colorSpaceNameEq(t, "a98-rgb")) return .a98_rgb;
    if (colorSpaceNameEq(t, "prophoto-rgb")) return .prophoto_rgb;
    if (colorSpaceNameEq(t, "rec2020")) return .rec2020;
    if (colorSpaceNameEq(t, "xyz-d50")) return .xyz_d50;
    if (colorSpaceNameEq(t, "xyz")) return .xyz_d65;
    if (colorSpaceNameEq(t, "xyz-d65")) return .xyz_d65;
    if (colorSpaceNameEq(t, "lab")) return .lab;
    if (colorSpaceNameEq(t, "lch")) return .lch;
    if (colorSpaceNameEq(t, "oklab")) return .oklab;
    if (colorSpaceNameEq(t, "oklch")) return .oklch;
    if (colorSpaceNameEq(t, "hsl")) return .hsl;
    if (colorSpaceNameEq(t, "hwb")) return .hwb;
    return null;
}

fn colorSpaceCssName(space: color_mod.ColorSpace) []const u8 {
    return switch (space) {
        .srgb => "rgb",
        .srgb_linear => "srgb-linear",
        .hsl => "hsl",
        .hwb => "hwb",
        .lab => "lab",
        .lch => "lch",
        .oklab => "oklab",
        .oklch => "oklch",
        .display_p3 => "display-p3",
        .display_p3_linear => "display-p3-linear",
        .a98_rgb => "a98-rgb",
        .prophoto_rgb => "prophoto-rgb",
        .rec2020 => "rec2020",
        .xyz_d50 => "xyz-d50",
        .xyz_d65 => "xyz",
    };
}

fn isLegacyColorSpace(space: color_mod.ColorSpace) bool {
    return value_mod.isLegacyColorSpace(space);
}

fn declaredColorSpaceFromValue(ctx: *BuiltinContext, c: Value) color_mod.ColorSpace {
    return colorEntryOf(ctx, c).space;
}

fn colorMissingMaskFromValue(ctx: *BuiltinContext, c: Value) ColorMissingMask {
    return colorEntryOf(ctx, c).missing;
}

fn colorLegacyFlagFromValue(ctx: *BuiltinContext, c: Value) bool {
    return colorEntryOf(ctx, c).legacy;
}

fn colorLegacyCompatFlagFromValue(ctx: *BuiltinContext, c: Value) bool {
    const entry = colorEntryOf(ctx, c);
    if (entry.legacy) return true;
    // hsl()/hwb() with missing channels serialize with modern syntax, while
    // later legacy-compatible routes still treat them as legacy-capable colors.
    return entry.missing != 0 and (entry.space == .hsl or entry.space == .hwb);
}

fn mapMissingChannels(
    missing: ColorMissingMask,
    src_space: color_mod.ColorSpace,
    target_space: color_mod.ColorSpace,
) ColorMissingMask {
    if (src_space == target_space) return missing;

    var result: ColorMissingMask = 0;
    if ((missing & 0x8) != 0) result |= 0x8;

    const ChannelKind = enum { rgb, hsl, hwb, lab, lch, xyz };
    const src_kind: ChannelKind = switch (src_space) {
        .srgb, .srgb_linear, .display_p3, .display_p3_linear, .a98_rgb, .prophoto_rgb, .rec2020 => .rgb,
        .hsl => .hsl,
        .hwb => .hwb,
        .lab, .oklab => .lab,
        .lch, .oklch => .lch,
        .xyz_d50, .xyz_d65 => .xyz,
    };
    const target_kind: ChannelKind = switch (target_space) {
        .srgb, .srgb_linear, .display_p3, .display_p3_linear, .a98_rgb, .prophoto_rgb, .rec2020 => .rgb,
        .hsl => .hsl,
        .hwb => .hwb,
        .lab, .oklab => .lab,
        .lch, .oklch => .lch,
        .xyz_d50, .xyz_d65 => .xyz,
    };

    if (src_kind == target_kind or
        (src_kind == .rgb and target_kind == .xyz) or
        (src_kind == .xyz and target_kind == .rgb))
    {
        result |= (missing & 0x7);
        return result;
    }

    const src_l_bit: ?ColorMissingMask = switch (src_kind) {
        .hsl => 0x4,
        .lab, .lch => 0x1,
        else => null,
    };
    const target_l_bit: ?ColorMissingMask = switch (target_kind) {
        .hsl => 0x4,
        .lab, .lch => 0x1,
        else => null,
    };
    if (src_l_bit != null and target_l_bit != null and (missing & src_l_bit.?) != 0) {
        result |= target_l_bit.?;
    }

    const src_h_bit: ?ColorMissingMask = switch (src_kind) {
        .hsl, .hwb => 0x1,
        .lch => 0x4,
        else => null,
    };
    const target_h_bit: ?ColorMissingMask = switch (target_kind) {
        .hsl, .hwb => 0x1,
        .lch => 0x4,
        else => null,
    };
    if (src_h_bit != null and target_h_bit != null and (missing & src_h_bit.?) != 0) {
        result |= target_h_bit.?;
    }

    const src_c_bit: ?ColorMissingMask = switch (src_kind) {
        .hsl => 0x2,
        .lch => 0x2,
        else => null,
    };
    const target_c_bit: ?ColorMissingMask = switch (target_kind) {
        .hsl => 0x2,
        .lch => 0x2,
        else => null,
    };
    if (src_c_bit != null and target_c_bit != null and (missing & src_c_bit.?) != 0) {
        result |= target_c_bit.?;
    }

    return result;
}

fn isTargetLabLikeLightnessMissing(target_space: color_mod.ColorSpace, missing: ColorMissingMask) bool {
    return switch (target_space) {
        .lab, .lch, .oklab, .oklch => (missing & 0x1) != 0,
        else => false,
    };
}

fn hasMissingPolarHueEntry(entry: *const value_mod.ColorEntry) bool {
    return switch (entry.space) {
        .lch, .oklch => (entry.missing & 0x4) != 0,
        .hsl, .hwb => (entry.missing & 0x1) != 0,
        else => false,
    };
}

fn isSemanticHslSourceEntry(entry: *const value_mod.ColorEntry) bool {
    return entry.space == .hsl;
}

fn hasMissingLightnessEntry(entry: *const value_mod.ColorEntry) bool {
    return switch (entry.space) {
        .lab, .oklab, .lch, .oklch => (entry.missing & 0x1) != 0,
        .hsl => (entry.missing & 0x4) != 0,
        else => false,
    };
}

const ProjectedChannelRead = struct {
    color: color_mod.Color,
    missing: ColorMissingMask,
};

fn projectChannelReadForSpace(
    source_entry: *const value_mod.ColorEntry,
    source: color_mod.Color,
    target_space: color_mod.ColorSpace,
) ProjectedChannelRead {
    var converted = normalizeChannelColor(color_mod.convert(source, target_space));
    const source_declared_space = source_entry.space;
    const source_missing = source_entry.missing;

    var mapped_missing = mapMissingChannels(source_missing, source_declared_space, target_space);
    if (target_space == .lab and source_declared_space == .lch) {
        if ((source_missing & 0x1) != 0) {
            mapped_missing |= 0x7;
        } else if ((source_missing & 0x2) == 0 and
            @abs(source.channels[0]) <= 1e-10 and
            @abs(source.channels[1]) <= 1e-10)
        {
            mapped_missing |= 0x6;
        }
    }
    if ((target_space == .lch or target_space == .oklch) and source_declared_space != target_space and
        (source_declared_space == .hsl or source_declared_space == .lch or source_declared_space == .oklch) and
        (source_missing & 0x2) != 0)
    {
        mapped_missing |= 0x4;
    }
    if (((target_space == .hsl and source_declared_space != .hsl) or target_space == .hwb) and
        (mapped_missing & 0x1) != 0)
    {
        mapped_missing &= ~@as(ColorMissingMask, 0x1);
    }
    if (target_space == .hsl and source_declared_space != .hsl) {
        mapped_missing = 0;
    }
    if (target_space == .hsl and source_declared_space == .hwb) mapped_missing &= 0x8;
    if (target_space == .hwb and source_declared_space == .hsl) mapped_missing &= 0x8;
    if ((target_space == .lch or target_space == .oklch) and
        (mapped_missing & 0x2) == 0 and
        @abs(converted.channels[1]) <= 1e-10)
    {
        mapped_missing |= 0x4;
    }

    if (((target_space == .hsl and !isSemanticHslSourceEntry(source_entry)) or target_space == .hwb) and
        hasMissingPolarHueEntry(source_entry))
    {
        converted.channels[0] = 0.0;
        mapped_missing &= ~@as(ColorMissingMask, 0x1);
    }
    if (target_space == .hsl and hasMissingLightnessEntry(source_entry)) {
        converted.channels[2] = 0.0;
    }

    return .{
        .color = converted,
        .missing = mapped_missing,
    };
}

fn shouldPreferLongHexForToSpaceLegacyRgbTarget(source_entry: *const value_mod.ColorEntry, source_declared_space: color_mod.ColorSpace) bool {
    if (source_declared_space != .srgb) return true;
    return switch (source_entry.inspect_repr) {
        .literal_short_hex => false,
        .literal_long_hex => true,
        .legacy_rgb_function => false,
        .auto => true,
    };
}

fn maybePreferLongHexHwbResult(ctx: *BuiltinContext, value: Value) void {
    if (value.kind() != .color) return;
    const entry = value.colorEntryMut(ctx.color_pool);
    if (!entry.legacy or entry.space != .hwb or entry.missing != 0) return;
    if (@abs(entry.channels[3] - 1.0) > 1e-10) return;
    entry.prefer_long_hex = true;
}

fn appendFixedFloat(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    value: f64,
) BuiltinError!void {
    if (@abs(value) <= 1e-12) {
        try out.appendSlice(allocator, "0");
        return;
    }

    if (@abs(value - @round(value)) <= 5e-10 and @abs(value) >= 1e4) {
        var tmp_int: [512]u8 = undefined;
        const rounded: i128 = @intFromFloat(@round(value));
        const formatted = std.fmt.bufPrint(&tmp_int, "{}", .{rounded}) catch |err| {
            std.debug.panic("appendFixedFloat integer formatting failed: {s}", .{@errorName(err)});
        };
        try out.appendSlice(allocator, formatted);
        return;
    }

    var formatted_buf: [128]u8 = undefined;
    const formatted = std.fmt.bufPrint(&formatted_buf, "{d:.10}", .{value}) catch |err| {
        std.debug.panic("appendFixedFloat decimal formatting failed: {s}", .{@errorName(err)});
    };
    if (std.mem.findScalar(u8, formatted, '.')) |dot_idx| {
        var end = formatted.len;
        while (end > dot_idx + 1 and formatted[end - 1] == '0') : (end -= 1) {}
        if (end == dot_idx + 1) end = dot_idx;
        if (std.mem.eql(u8, formatted[0..end], "-0")) {
            try out.append(allocator, '0');
            return;
        }
        try out.appendSlice(allocator, formatted[0..end]);
        return;
    }
    try out.appendSlice(allocator, formatted);
}

fn serializeLabLikeOutOfRange(
    ctx: *BuiltinContext,
    updated: color_mod.Color,
    working_space: color_mod.ColorSpace,
) BuiltinError!Value {
    return serializeLabLikeOutOfRangeXyz(ctx, color_mod.convert(updated, .xyz_d65), working_space);
}

fn serializeToSpaceLabLikeOutOfRange(
    ctx: *BuiltinContext,
    updated: color_mod.Color,
    working_space: color_mod.ColorSpace,
    source_space: color_mod.ColorSpace,
) BuiltinError!Value {
    var xyz = color_mod.convert(updated, .xyz_d65);
    switch (source_space) {
        .hsl => if (working_space == .lch) {
            xyz.channels[1] = std.math.nextAfter(f64, xyz.channels[1], std.math.inf(f64));
        },
        else => {},
    }
    return serializeLabLikeOutOfRangeXyz(ctx, xyz, working_space);
}

fn serializeLabLikeOutOfRangeXyz(
    ctx: *BuiltinContext,
    xyz: color_mod.Color,
    working_space: color_mod.ColorSpace,
) BuiltinError!Value {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(ctx.allocator);

    try buf.appendSlice(ctx.allocator, "color-mix(in ");
    try buf.appendSlice(ctx.allocator, colorSpaceCssName(working_space));
    try buf.appendSlice(ctx.allocator, ", color(xyz ");
    try appendFixedFloat(ctx.allocator, &buf, xyz.channels[0]);
    try buf.append(ctx.allocator, ' ');
    try appendFixedFloat(ctx.allocator, &buf, xyz.channels[1]);
    try buf.append(ctx.allocator, ' ');
    try appendFixedFloat(ctx.allocator, &buf, xyz.channels[2]);
    try buf.appendSlice(ctx.allocator, ") 100%, black)");

    const id = try internString(ctx, buf.items);
    return Value.string(id, false);
}

fn parseLabLikeFallbackXyz(css: []const u8) ?color_mod.Color {
    const prefix = "color-mix(in ";
    const xyz_prefix = ", color(xyz ";
    const suffix = ") 100%, black)";
    if (!std.mem.startsWith(u8, css, prefix)) return null;
    const xyz_start = std.mem.find(u8, css, xyz_prefix) orelse return null;
    const values_start = xyz_start + xyz_prefix.len;
    const suffix_start = std.mem.findLast(u8, css, suffix) orelse return null;
    if (suffix_start <= values_start) return null;

    var it = std.mem.tokenizeScalar(u8, css[values_start..suffix_start], ' ');
    const x_text = it.next() orelse return null;
    const y_text = it.next() orelse return null;
    const z_text = it.next() orelse return null;
    if (it.next() != null) return null;

    const x = std.fmt.parseFloat(f64, x_text) catch return null;
    const y = std.fmt.parseFloat(f64, y_text) catch return null;
    const z = std.fmt.parseFloat(f64, z_text) catch return null;
    return color_mod.Color.init(x, y, z, 1.0, .xyz_d65);
}

fn colorValueFromDeclaredColor(
    ctx: *BuiltinContext,
    color: color_mod.Color,
    declared_space: color_mod.ColorSpace,
    missing: ColorMissingMask,
    legacy: bool,
) BuiltinError!Value {
    const normalized = normalizeChannelColor(color);
    return colorValueFromPrimitive(ctx, normalized, declared_space, missing, legacy);
}

fn normalizeChannelColor(color: color_mod.Color) color_mod.Color {
    var normalized = color;
    switch (normalized.space) {
        .hsl => normalized.channels[0] = @mod(normalized.channels[0], 360.0),
        .hwb => {
            normalized.channels[0] = @mod(normalized.channels[0], 360.0);
            const total = normalized.channels[1] + normalized.channels[2];
            if (total > 100.0) {
                const scale = 100.0 / total;
                normalized.channels[1] *= scale;
                normalized.channels[2] *= scale;
            }
        },
        .lch, .oklch => normalized.channels[2] = @mod(normalized.channels[2], 360.0),
        else => {},
    }
    return normalized;
}

fn localChannelColor(ctx: *BuiltinContext, c: Value) color_mod.Color {
    return normalizeChannelColor(colorPrimitiveOf(ctx, c));
}

fn colorSameComparisonColor(ctx: *BuiltinContext, c: Value) color_mod.Color {
    var source = localChannelColor(ctx, c);
    const missing = colorMissingMaskFromValue(ctx, c);

    for (0..4) |i| {
        const bit: ColorMissingMask = @as(ColorMissingMask, 1) << @intCast(i);
        if ((missing & bit) != 0) {
            source.channels[i] = 0.0;
        }
    }

    return source;
}

fn numberWithUnit(ctx: *BuiltinContext, value: f64, comptime unit: ?[]const u8) BuiltinError!Value {
    if (unit) |u| {
        const uid = comptime intern_pool_mod.wellKnownId(u);
        return try Value.number(value, uid, ctx.number_pool, ctx.allocator);
    }
    return Value.numberUnitless(value);
}

fn getColorChannel(
    ctx: *BuiltinContext,
    c: Value,
    ch_name: []const u8,
    target_space: ?color_mod.ColorSpace,
    legacy_rgb_space: bool,
) BuiltinError!Value {
    return getColorChannelImpl(ctx, c, ch_name, target_space, legacy_rgb_space, false);
}

fn getColorChannelImpl(
    ctx: *BuiltinContext,
    c: Value,
    ch_name: []const u8,
    target_space: ?color_mod.ColorSpace,
    legacy_rgb_space: bool,
    round_legacy_byte: bool,
) BuiltinError!Value {
    const source = localChannelColor(ctx, c);
    const source_entry = colorEntryOf(ctx, c);
    const projected = if (target_space) |sp|
        projectChannelReadForSpace(source_entry, source, sp)
    else
        ProjectedChannelRead{
            .color = source,
            .missing = source_entry.missing,
        };
    const in_space = projected.color;
    const projected_missing = projected.missing;
    const channels = in_space.channels;
    const declared = declaredColorSpaceFromValue(ctx, c);
    const legacy_rgb_default = (target_space == null and declared == .srgb and colorLegacyFlagFromValue(ctx, c)) or legacy_rgb_space;

    if (std.ascii.eqlIgnoreCase(ch_name, "alpha")) {
        return numberWithUnit(ctx, if ((projected_missing & 0x8) != 0) 0.0 else channels[3], null);
    }

    // legacy `red()/green()/blue()` rounds to 0-255, but `color.channel($c, ch, $space: rgb)` does not.
    const rgb_byte_scale = legacy_rgb_default;
    const rgb_round = round_legacy_byte;
    return switch (in_space.space) {
        .srgb, .srgb_linear, .display_p3, .display_p3_linear, .a98_rgb, .prophoto_rgb, .rec2020 => blk: {
            if (std.ascii.eqlIgnoreCase(ch_name, "red")) break :blk try numberWithUnit(ctx, rgbChannelValue(channels[0], (projected_missing & 0x1) != 0, rgb_byte_scale, rgb_round), null);
            if (std.ascii.eqlIgnoreCase(ch_name, "green")) break :blk try numberWithUnit(ctx, rgbChannelValue(channels[1], (projected_missing & 0x2) != 0, rgb_byte_scale, rgb_round), null);
            if (std.ascii.eqlIgnoreCase(ch_name, "blue")) break :blk try numberWithUnit(ctx, rgbChannelValue(channels[2], (projected_missing & 0x4) != 0, rgb_byte_scale, rgb_round), null);
            break :blk error.BuiltinType;
        },
        .hsl => blk: {
            if (std.ascii.eqlIgnoreCase(ch_name, "hue")) break :blk try numberWithUnit(ctx, if ((projected_missing & 0x1) != 0) 0.0 else channels[0], "deg");
            if (std.ascii.eqlIgnoreCase(ch_name, "saturation")) break :blk try numberWithUnit(ctx, if ((projected_missing & 0x2) != 0) 0.0 else channels[1], "%");
            if (std.ascii.eqlIgnoreCase(ch_name, "lightness")) break :blk try numberWithUnit(ctx, if ((projected_missing & 0x4) != 0) 0.0 else channels[2], "%");
            break :blk error.BuiltinType;
        },
        .hwb => blk: {
            if (std.ascii.eqlIgnoreCase(ch_name, "hue")) break :blk try numberWithUnit(ctx, if ((projected_missing & 0x1) != 0) 0.0 else channels[0], "deg");
            if (std.ascii.eqlIgnoreCase(ch_name, "whiteness")) break :blk try numberWithUnit(ctx, if ((projected_missing & 0x2) != 0) 0.0 else channels[1], "%");
            if (std.ascii.eqlIgnoreCase(ch_name, "blackness")) {
                var blackness = channels[2];
                if (source_entry.hwb_blackness_channel_next_up and blackness < 0.0) {
                    blackness = std.math.nextAfter(f64, blackness, std.math.inf(f64));
                }
                break :blk try numberWithUnit(ctx, if ((projected_missing & 0x4) != 0) 0.0 else blackness, "%");
            }
            break :blk error.BuiltinType;
        },
        .lab => blk: {
            if (std.ascii.eqlIgnoreCase(ch_name, "lightness")) break :blk try numberWithUnit(ctx, if ((projected_missing & 0x1) != 0) 0.0 else channels[0], "%");
            if (std.ascii.eqlIgnoreCase(ch_name, "a")) break :blk try numberWithUnit(ctx, if ((projected_missing & 0x2) != 0) 0.0 else channels[1], null);
            if (std.ascii.eqlIgnoreCase(ch_name, "b")) break :blk try numberWithUnit(ctx, if ((projected_missing & 0x4) != 0) 0.0 else channels[2], null);
            break :blk error.BuiltinType;
        },
        .lch => blk: {
            if (std.ascii.eqlIgnoreCase(ch_name, "lightness")) break :blk try numberWithUnit(ctx, if ((projected_missing & 0x1) != 0) 0.0 else channels[0], "%");
            if (std.ascii.eqlIgnoreCase(ch_name, "chroma")) break :blk try numberWithUnit(ctx, if ((projected_missing & 0x2) != 0) 0.0 else channels[1], null);
            if (std.ascii.eqlIgnoreCase(ch_name, "hue")) break :blk try numberWithUnit(ctx, if ((projected_missing & 0x4) != 0) 0.0 else channels[2], "deg");
            break :blk error.BuiltinType;
        },
        .oklab => blk: {
            if (std.ascii.eqlIgnoreCase(ch_name, "lightness")) break :blk try numberWithUnit(ctx, if ((projected_missing & 0x1) != 0) 0.0 else channels[0] * 100.0, "%");
            if (std.ascii.eqlIgnoreCase(ch_name, "a")) break :blk try numberWithUnit(ctx, if ((projected_missing & 0x2) != 0) 0.0 else channels[1], null);
            if (std.ascii.eqlIgnoreCase(ch_name, "b")) break :blk try numberWithUnit(ctx, if ((projected_missing & 0x4) != 0) 0.0 else channels[2], null);
            break :blk error.BuiltinType;
        },
        .oklch => blk: {
            if (std.ascii.eqlIgnoreCase(ch_name, "lightness")) break :blk try numberWithUnit(ctx, if ((projected_missing & 0x1) != 0) 0.0 else channels[0] * 100.0, "%");
            if (std.ascii.eqlIgnoreCase(ch_name, "chroma")) break :blk try numberWithUnit(ctx, if ((projected_missing & 0x2) != 0) 0.0 else channels[1], null);
            if (std.ascii.eqlIgnoreCase(ch_name, "hue")) break :blk try numberWithUnit(ctx, if ((projected_missing & 0x4) != 0) 0.0 else channels[2], "deg");
            break :blk error.BuiltinType;
        },
        .xyz_d50, .xyz_d65 => blk: {
            if (std.ascii.eqlIgnoreCase(ch_name, "x")) break :blk try numberWithUnit(ctx, if ((projected_missing & 0x1) != 0) 0.0 else channels[0], null);
            if (std.ascii.eqlIgnoreCase(ch_name, "y")) break :blk try numberWithUnit(ctx, if ((projected_missing & 0x2) != 0) 0.0 else channels[1], null);
            if (std.ascii.eqlIgnoreCase(ch_name, "z")) break :blk try numberWithUnit(ctx, if ((projected_missing & 0x4) != 0) 0.0 else channels[2], null);
            break :blk error.BuiltinType;
        },
    };
}

fn rgbChannelValue(channel: f64, missing: bool, byte_scale: bool, round_byte: bool) f64 {
    if (missing) return 0.0;
    if (!byte_scale) return channel;
    const scaled = channel * 255.0;
    return if (round_byte) @round(scaled) else scaled;
}

fn reportLegacyColorGetterBuiltin(_: *BuiltinContext, basename: []const u8) BuiltinError {
    var buf: [384]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "color.{s}() is only supported for legacy colors. Please use color.channel() instead with an explicit $space argument.", .{basename}) catch return error.BuiltinType;
    error_format.setContextMessage(msg);
    return error.BuiltinType;
}

fn reportLegacyColorAlphaBuiltin(_: *BuiltinContext) BuiltinError {
    var buf: [384]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "color.alpha() is only supported for legacy colors. Please use color.channel() instead.", .{}) catch return error.BuiltinType;
    error_format.setContextMessage(msg);
    return error.BuiltinType;
}

pub fn color_red(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try expectArity(args, 1);
    const c = tryCoerceColorArg(ctx, args[0]) orelse return reportArgumentTypeMismatch(ctx, "color", args[0], "color");
    if (!colorLegacyFlagFromValue(ctx, c)) return reportLegacyColorGetterBuiltin(ctx, "red");
    return getColorChannelImpl(ctx, c, "red", .srgb, true, true);
}

pub fn color_green(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try expectArity(args, 1);
    const c = tryCoerceColorArg(ctx, args[0]) orelse return reportArgumentTypeMismatch(ctx, "color", args[0], "color");
    if (!colorLegacyFlagFromValue(ctx, c)) return reportLegacyColorGetterBuiltin(ctx, "green");
    return getColorChannelImpl(ctx, c, "green", .srgb, true, true);
}

pub fn color_blue(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try expectArity(args, 1);
    const c = tryCoerceColorArg(ctx, args[0]) orelse return reportArgumentTypeMismatch(ctx, "color", args[0], "color");
    if (!colorLegacyFlagFromValue(ctx, c)) return reportLegacyColorGetterBuiltin(ctx, "blue");
    return getColorChannelImpl(ctx, c, "blue", .srgb, true, true);
}

pub fn color_hue(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try expectArity(args, 1);
    const c = tryCoerceColorArg(ctx, args[0]) orelse return reportArgumentTypeMismatch(ctx, "color", args[0], "color");
    if (!colorLegacyFlagFromValue(ctx, c)) return reportLegacyColorGetterBuiltin(ctx, "hue");
    return getColorChannel(ctx, c, "hue", .hsl, false);
}

pub fn color_saturation(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try expectArity(args, 1);
    const c = tryCoerceColorArg(ctx, args[0]) orelse return reportArgumentTypeMismatch(ctx, "color", args[0], "color");
    if (!colorLegacyFlagFromValue(ctx, c)) return reportLegacyColorGetterBuiltin(ctx, "saturation");
    return getColorChannel(ctx, c, "saturation", .hsl, false);
}

pub fn color_lightness(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try expectArity(args, 1);
    const c = tryCoerceColorArg(ctx, args[0]) orelse return reportArgumentTypeMismatch(ctx, "color", args[0], "color");
    if (!colorLegacyFlagFromValue(ctx, c)) return reportLegacyColorGetterBuiltin(ctx, "lightness");
    return getColorChannel(ctx, c, "lightness", .hsl, false);
}

fn isAlphaFilterNamedArgSet(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) bool {
    if (args.len == 0 or args.len != arg_names.len) return false;
    for (arg_names) |name_id| {
        if (name_id == .none) return false;
        if (argNameMatches(ctx, name_id, "color")) return false;
    }
    return true;
}

fn serializeAlphaFilterNamedArgs(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(ctx.allocator);
    try out.ensureTotalCapacity(ctx.allocator, 8 + args.len * 6);
    try out.appendSlice(ctx.allocator, "alpha(");
    for (args, 0..) |arg, i| {
        if (i != 0) try out.appendSlice(ctx.allocator, ", ");
        try out.appendSlice(ctx.allocator, ctx.intern_pool.get(arg_names[i]));
        try out.append(ctx.allocator, '=');
        const css = try valueToCssString(ctx, arg);
        defer ctx.allocator.free(css);
        try out.appendSlice(ctx.allocator, css);
    }
    try out.append(ctx.allocator, ')');
    const id = try internString(ctx, out.items);
    return Value.string(id, false);
}

fn isAlphaFilterPositionalArgSet(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) bool {
    if (args.len <= 1) return false;
    for (args, 0..) |arg, i| {
        const name_id: InternId = if (i < arg_names.len) arg_names[i] else .none;
        if (name_id != .none) return false;
        if (!arg.isString() or arg.stringQuoted(ctx.string_flags_pool.items)) return false;
        if (!isLegacyAlphaFilterSyntax(ctx.intern_pool.get(arg.stringIntern()))) return false;
    }
    return true;
}

fn serializeAlphaFilterPositionalArgs(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(ctx.allocator);
    try out.appendSlice(ctx.allocator, "alpha(");
    for (args, 0..) |arg, i| {
        if (i != 0) try out.appendSlice(ctx.allocator, ", ");
        const css = try valueToCssString(ctx, arg);
        defer ctx.allocator.free(css);
        try out.appendSlice(ctx.allocator, css);
    }
    try out.append(ctx.allocator, ')');
    const id = try internString(ctx, out.items);
    return Value.string(id, false);
}

const AlphaLikeMode = enum {
    module_alpha,
    module_opacity,
    global_alpha,
    global_opacity,
};

fn alphaLikeName(mode: AlphaLikeMode) []const u8 {
    return switch (mode) {
        .module_alpha, .global_alpha => "alpha",
        .module_opacity, .global_opacity => "opacity",
    };
}

fn alphaLikeIsModule(mode: AlphaLikeMode) bool {
    return switch (mode) {
        .module_alpha, .module_opacity => true,
        .global_alpha, .global_opacity => false,
    };
}

fn rawCalcNeedsNumericSimplification(raw: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw, " \t\n\r");
    if (!(std.ascii.startsWithIgnoreCase(trimmed, "calc(") and trimmed.len >= 6 and trimmed[trimmed.len - 1] == ')')) {
        return false;
    }
    const inner = std.mem.trim(u8, trimmed[5 .. trimmed.len - 1], " \t\n\r");
    var saw_nonspace = false;
    for (inner) |ch| {
        if (ch == '+' or ch == '*' or ch == '/') return true;
        if (ch == '-') {
            if (saw_nonspace) return true;
            continue;
        }
        if (!std.ascii.isWhitespace(ch)) saw_nonspace = true;
    }
    return false;
}

fn trySimplifyCalcFilterText(ctx: *BuiltinContext, raw: []const u8, allow_simple_numeric: bool) BuiltinError!?Value {
    if (!allow_simple_numeric and !rawCalcNeedsNumericSimplification(raw)) return null;
    const trimmed = std.mem.trim(u8, raw, " \t\n\r");
    const inner = std.mem.trim(u8, trimmed[5 .. trimmed.len - 1], " \t\n\r");
    const parsed = calculation.parseCalc(ctx.allocator, inner) catch return null;
    defer {
        calculation.freeCalcValue(ctx.allocator, parsed);
        ctx.allocator.destroy(parsed);
    }

    const simplified = calculation.simplify(ctx.allocator, parsed) catch return null;
    defer {
        calculation.freeCalcValue(ctx.allocator, simplified);
        ctx.allocator.destroy(simplified);
    }

    if (simplified.* == .number) {
        const n = simplified.number;
        const unit_id = if (n.unit) |unit| try internString(ctx, unit) else InternId.none;
        return if (unit_id == .none)
            Value.numberUnitless(n.value)
        else
            try Value.number(n.value, unit_id, ctx.number_pool, ctx.allocator);
    }
    return null;
}

fn trySimplifyCalcFilterArg(ctx: *BuiltinContext, value: Value) BuiltinError!?Value {
    if (value.isString()) {
        if (value.stringQuoted(ctx.string_flags_pool.items)) return null;
        return trySimplifyCalcFilterText(ctx, ctx.intern_pool.get(value.stringIntern()), false);
    }
    if (value.kind() == .calc_fragment or value.kind() == .interp_fragment) {
        const raw = try valueToCssString(ctx, value);
        defer ctx.allocator.free(raw);
        return trySimplifyCalcFilterText(ctx, raw, true);
    }
    return null;
}

fn serializeFilterFunction(ctx: *BuiltinContext, name: []const u8, value: Value, simplify_calc: bool) BuiltinError!Value {
    const css = blk: {
        if (simplify_calc) {
            if (try trySimplifyCalcFilterArg(ctx, value)) |simplified| {
                break :blk try valueToCssString(ctx, simplified);
            }
        }
        break :blk try valueToCssString(ctx, value);
    };
    defer ctx.allocator.free(css);
    const text = try std.fmt.allocPrint(ctx.allocator, "{s}({s})", .{ name, css });
    defer ctx.allocator.free(text);
    const id = try internString(ctx, text);
    return Value.string(id, false);
}

fn alphaLikeImpl(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId, mode: AlphaLikeMode) BuiltinError!Value {
    const fn_name = alphaLikeName(mode);
    if (std.mem.eql(u8, fn_name, "alpha") and isAlphaFilterNamedArgSet(ctx, args, arg_names)) {
        return serializeAlphaFilterNamedArgs(ctx, args, arg_names);
    }
    if (std.mem.eql(u8, fn_name, "alpha") and isAlphaFilterPositionalArgSet(ctx, args, arg_names)) {
        return serializeAlphaFilterPositionalArgs(ctx, args);
    }
    try expectArity(args, 1);
    if (tryCoerceColorArg(ctx, args[0])) |c| {
        if (!colorLegacyFlagFromValue(ctx, c)) return reportLegacyColorAlphaBuiltin(ctx);
        return getColorChannel(ctx, c, "alpha", null, false);
    }

    const arg0 = args[0];
    if (arg0.isString()) {
        if (arg0.stringQuoted(ctx.string_flags_pool.items)) {
            if (alphaLikeIsModule(mode)) return error.BuiltinType;
            return serializeFilterFunction(ctx, fn_name, arg0, false);
        }

        const raw = std.mem.trim(u8, ctx.intern_pool.get(arg0.stringIntern()), " \t\n\r");
        if (std.mem.eql(u8, fn_name, "alpha") and isLegacyAlphaFilterSyntax(raw)) {
            return serializeFilterFunction(ctx, "alpha", arg0, false);
        }

        if (alphaLikeIsModule(mode)) return error.BuiltinType;
        return serializeFilterFunction(ctx, fn_name, arg0, std.mem.eql(u8, fn_name, "opacity"));
    }
    if (arg0.isNumber()) {
        if (mode == .module_alpha) return error.BuiltinType;
        return serializeFilterFunction(ctx, fn_name, arg0, false);
    }
    if (arg0.kind() == .calc_fragment or arg0.kind() == .interp_fragment) {
        if (alphaLikeIsModule(mode)) return error.BuiltinType;
        return serializeFilterFunction(ctx, fn_name, arg0, true);
    }
    if (alphaLikeIsModule(mode)) return error.BuiltinType;
    return serializeFilterFunction(ctx, fn_name, arg0, false);
}

pub fn color_alpha(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    return alphaLikeImpl(ctx, args, arg_names, .module_alpha) catch |err| normalizeColorUserError(err);
}

pub fn color_opacity(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    return alphaLikeImpl(ctx, args, arg_names, .module_opacity) catch |err| normalizeColorUserError(err);
}

pub fn global_alpha(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    return alphaLikeImpl(ctx, args, arg_names, .global_alpha) catch |err| normalizeColorUserError(err);
}

pub fn global_opacity(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    return alphaLikeImpl(ctx, args, arg_names, .global_opacity) catch |err| normalizeColorUserError(err);
}

fn hwbChannelPercent(ctx: *BuiltinContext, c: Value, idx: usize) BuiltinError!Value {
    const hwb = normalizeChannelColor(color_mod.convert(localChannelColor(ctx, c), .hwb));
    return numberWithUnit(ctx, hwb.channels[idx], "%");
}

pub fn color_whiteness(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try expectArity(args, 1);
    const c = tryCoerceColorArg(ctx, args[0]) orelse return error.BuiltinType;
    if (!colorLegacyFlagFromValue(ctx, c)) return reportLegacyColorGetterBuiltin(ctx, "whiteness");
    return hwbChannelPercent(ctx, c, 1);
}

pub fn color_blackness(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try expectArity(args, 1);
    const c = tryCoerceColorArg(ctx, args[0]) orelse return error.BuiltinType;
    if (!colorLegacyFlagFromValue(ctx, c)) return reportLegacyColorGetterBuiltin(ctx, "blackness");
    return hwbChannelPercent(ctx, c, 2);
}

fn complementInSpace(ctx: *BuiltinContext, c: Value, working_space: color_mod.ColorSpace) BuiltinError!Value {
    const hue_idx = hueChannelIndex(working_space) orelse return error.BuiltinType;
    const source_declared_space = declaredColorSpaceFromValue(ctx, c);
    const source_missing = colorMissingMaskFromValue(ctx, c);
    const source_legacy = colorLegacyCompatFlagFromValue(ctx, c);
    var working = normalizeChannelColor(color_mod.convert(localChannelColor(ctx, c), working_space));
    const base_missing = mapMissingChannels(source_missing, source_declared_space, working_space);
    var projected_missing = base_missing;
    if (working_space != source_declared_space) {
        projected_missing |= powerlessChannelMask(working);
    }
    const hue_bit: ColorMissingMask = @as(ColorMissingMask, 1) << @intCast(hue_idx);
    if ((projected_missing & hue_bit) != 0) return error.BuiltinType;

    var updated_channels = [3]f64{ working.channels[0], working.channels[1], working.channels[2] };
    for (0..3) |i| {
        const bit: ColorMissingMask = @as(ColorMissingMask, 1) << @intCast(i);
        if ((projected_missing & bit) != 0) updated_channels[i] = 0.0;
    }
    updated_channels[hue_idx] = normalizeHue(updated_channels[hue_idx] + 180.0);
    working = color_mod.Color.init(updated_channels[0], updated_channels[1], updated_channels[2], working.channels[3], working_space);

    const output_space: color_mod.ColorSpace = if (source_legacy and working_space == .hsl and source_declared_space != .srgb)
        .hsl
    else
        source_declared_space;
    const output_color = if (working_space == output_space)
        working
    else
        normalizeChannelColor(color_mod.convert(working, output_space));
    var output_missing = if (working_space == output_space)
        projected_missing
    else
        mapMissingChannels(projected_missing, working_space, output_space);
    if (working_space != output_space) if (hueChannelIndex(output_space)) |output_hue_idx| {
        const channels3 = [3]f64{ output_color.channels[0], output_color.channels[1], output_color.channels[2] };
        if (isPowerlessInSpace(output_space, channels3, output_hue_idx)) {
            output_missing |= @as(ColorMissingMask, 1) << @intCast(output_hue_idx);
        }
    };
    var output_legacy = source_legacy and isLegacyColorSpace(output_space);
    if (output_space == .hsl and output_missing != 0) output_legacy = false;
    return colorValueFromDeclaredColor(ctx, output_color, output_space, output_missing, output_legacy);
}

fn color_complementImpl(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    if (args.len > 2) return badArity(1, args.len);
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{ "color", "space" }, 1);
    const color_arg = bound[0].?;
    const c = tryCoerceColorArg(ctx, color_arg) orelse return error.BuiltinType;
    const explicit_space = try parseOptionalSpaceArgValue(ctx, bound[1]);
    if (explicit_space) |space_arg| {
        if (!space_arg.space.isPolar()) return error.BuiltinType;
        return complementInSpace(ctx, c, space_arg.space);
    }
    const source_declared_space = declaredColorSpaceFromValue(ctx, c);
    const source_missing = colorMissingMaskFromValue(ctx, c);
    if (!colorLegacyCompatFlagFromValue(ctx, c)) return error.BuiltinType;
    if (source_declared_space != .srgb or source_missing != 0) {
        return complementInSpace(ctx, c, .hsl);
    }
    return hslAdjustedColor(ctx, c, 180.0, 0.0, 0.0);
}

pub fn color_complement(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    try emitColorDeprecation(ctx, "complement() is deprecated; use color.channel() with color.channel() instead");
    return color_complementImpl(ctx, args, arg_names) catch |err| normalizeColorUserError(err);
}

fn invertModifiedChannelsMask(space: color_mod.ColorSpace) ColorMissingMask {
    return switch (space) {
        .srgb, .srgb_linear, .display_p3, .display_p3_linear, .a98_rgb, .prophoto_rgb, .rec2020, .lab, .oklab, .xyz_d50, .xyz_d65 => 0x7,
        .hsl, .lch, .oklch => 0x5,
        .hwb => 0x7,
    };
}

fn invertedChannelsForSpace(
    space: color_mod.ColorSpace,
    channels: [3]f64,
    legacy_rgb_channels: bool,
) [3]f64 {
    return switch (space) {
        .srgb => blk: {
            const max: f64 = if (legacy_rgb_channels) 255.0 else 1.0;
            break :blk .{
                max - channels[0],
                max - channels[1],
                max - channels[2],
            };
        },
        .srgb_linear, .display_p3, .display_p3_linear, .a98_rgb, .prophoto_rgb, .rec2020, .xyz_d50, .xyz_d65 => .{
            1.0 - channels[0],
            1.0 - channels[1],
            1.0 - channels[2],
        },
        .hsl => .{
            normalizeHue(channels[0] + 180.0),
            channels[1],
            100.0 - channels[2],
        },
        .hwb => .{
            normalizeHue(channels[0] + 180.0),
            channels[2],
            channels[1],
        },
        .lab => .{
            100.0 - channels[0],
            -channels[1],
            -channels[2],
        },
        .lch => .{
            100.0 - channels[0],
            channels[1],
            normalizeHue(channels[2] + 180.0),
        },
        .oklab => .{
            1.0 - channels[0],
            -channels[1],
            -channels[2],
        },
        .oklch => .{
            1.0 - channels[0],
            channels[1],
            normalizeHue(channels[2] + 180.0),
        },
    };
}

fn interpolateInvertHue(original: f64, inverted: f64, weight: f64) f64 {
    var delta = normalizeHue(inverted - original);
    if (delta >= 180.0) delta -= 360.0;
    return normalizeHue(original + delta * weight);
}

fn color_invertImpl(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    if (args.len > 3) return badArity(1, args.len);
    const bound = bindNamedOrPositionalArgs(ctx, args, arg_names, &.{ "color", "weight", "space" });
    try validateRequiredBound(&.{ "color", "weight", "space" }, &bound, 1);
    const color_arg = bound[0].?;
    const weight_arg = bound[1];
    const space_arg = bound[2];

    const maybe_color = tryCoerceColorArg(ctx, color_arg);
    if (maybe_color == null) {
        if (weight_arg != null or space_arg != null) return error.BuiltinType;
        if (color_arg.isNumber() or color_arg.kind() == .calc_fragment or color_arg.kind() == .interp_fragment) {
            const css = try valueToCssString(ctx, color_arg);
            defer ctx.allocator.free(css);
            const text = try std.fmt.allocPrint(ctx.allocator, "invert({s})", .{css});
            defer ctx.allocator.free(text);
            const id = try internString(ctx, text);
            return Value.string(id, false);
        }
        if (color_arg.isString()) {
            const raw = shared.stripCalcArgMarker(ctx.intern_pool.get(color_arg.stringIntern()));
            if (color_arg.stringQuoted(ctx.string_flags_pool.items)) {
                if (!isRawCalcString(raw)) return error.BuiltinType;
                const trimmed = std.mem.trim(u8, raw, " \t\n\r");
                const text = try std.fmt.allocPrint(ctx.allocator, "invert({s})", .{trimmed});
                defer ctx.allocator.free(text);
                const id = try internString(ctx, text);
                return Value.string(id, false);
            }
            if (std.mem.findScalar(u8, raw, '(') == null) return error.BuiltinType;
            if (isRawCalcString(raw)) {
                const trimmed = std.mem.trim(u8, raw, " \t\n\r");
                const text = try std.fmt.allocPrint(ctx.allocator, "invert({s})", .{trimmed});
                defer ctx.allocator.free(text);
                const id = try internString(ctx, text);
                return Value.string(id, false);
            }
            const css = try valueToCssString(ctx, color_arg);
            defer ctx.allocator.free(css);
            const text = try std.fmt.allocPrint(ctx.allocator, "invert({s})", .{css});
            defer ctx.allocator.free(text);
            const id = try internString(ctx, text);
            return Value.string(id, false);
        }
        return error.BuiltinType;
    }

    const c = maybe_color.?;
    const weight_percent = if (weight_arg) |w| try expectNumber(ctx, w) else 100.0;
    if (weight_percent < 0.0 or weight_percent > 100.0) return error.BuiltinType;
    const weight = weight_percent / 100.0;

    const source_declared_space = declaredColorSpaceFromValue(ctx, c);
    const source_missing = colorMissingMaskFromValue(ctx, c);
    const source_legacy = colorLegacyCompatFlagFromValue(ctx, c);
    const explicit_space = try parseOptionalSpaceArgValue(ctx, space_arg);

    if (explicit_space == null and !source_legacy) return error.BuiltinType;

    const working_space = if (explicit_space) |sp| sp.space else source_declared_space;
    const working = color_mod.convert(localChannelColor(ctx, c), working_space);
    const projected_missing = mapMissingChannels(source_missing, source_declared_space, working_space) |
        (if (working_space != source_declared_space) powerlessChannelMask(working) else 0);
    const blocked_missing = if (working_space == .hwb)
        projected_missing & ~@as(ColorMissingMask, 0x6)
    else
        projected_missing;
    if ((blocked_missing & invertModifiedChannelsMask(working_space)) != 0) return error.BuiltinType;

    const legacy_rgb_channels = source_legacy and working_space == .srgb;
    const original_channels = if (legacy_rgb_channels)
        [3]f64{
            working.channels[0] * 255.0,
            working.channels[1] * 255.0,
            working.channels[2] * 255.0,
        }
    else
        [3]f64{ working.channels[0], working.channels[1], working.channels[2] };
    const inverted_channels = invertedChannelsForSpace(working_space, original_channels, legacy_rgb_channels);

    var projected_channels = original_channels;
    for (0..3) |i| {
        const bit: ColorMissingMask = @as(ColorMissingMask, 1) << @intCast(i);
        if ((projected_missing & bit) != 0 and !(working_space == .hwb and (bit == 0x2 or bit == 0x4))) continue;
        const is_hue = switch (working_space) {
            .hsl, .hwb => i == 0,
            .lch, .oklch => i == 2,
            else => false,
        };
        projected_channels[i] = if (is_hue)
            interpolateInvertHue(original_channels[i], inverted_channels[i], weight)
        else
            original_channels[i] + (inverted_channels[i] - original_channels[i]) * weight;
    }

    var result_working = color_mod.Color.init(
        if (legacy_rgb_channels) projected_channels[0] / 255.0 else projected_channels[0],
        if (legacy_rgb_channels) projected_channels[1] / 255.0 else projected_channels[1],
        if (legacy_rgb_channels) projected_channels[2] / 255.0 else projected_channels[2],
        working.channels[3],
        working_space,
    );
    result_working = normalizeChannelColor(result_working);

    const output_missing_working = if (working_space == .hwb)
        (projected_missing & ~@as(ColorMissingMask, 0x6)) |
            (if ((projected_missing & 0x2) != 0) @as(ColorMissingMask, 0x4) else 0) |
            (if ((projected_missing & 0x4) != 0) @as(ColorMissingMask, 0x2) else 0)
    else
        projected_missing;

    if (explicit_space) |space_spec| {
        switch (space_spec.space) {
            .hsl => {
                const output_legacy = source_legacy and output_missing_working == 0;
                return colorValueFromDeclaredColor(ctx, result_working, .hsl, output_missing_working, output_legacy);
            },
            .hwb => {
                if (output_missing_working == 0 and @abs(result_working.channels[3] - 1.0) <= 1e-10) {
                    const srgb_hex = normalizeChannelColor(color_mod.convert(result_working, .srgb));
                    const out = try colorValueFromDeclaredColor(ctx, srgb_hex, .srgb, 0, true);
                    maybePreferLongHexResult(ctx, out, true);
                    return out;
                }
                return colorValueFromDeclaredColor(ctx, result_working, .hwb, output_missing_working, false);
            },
            else => {},
        }
    }

    const converted_back = if (working_space == source_declared_space)
        result_working
    else
        color_mod.convert(result_working, source_declared_space);
    var output_missing = mapMissingChannels(output_missing_working, working_space, source_declared_space);
    if (!source_legacy and working_space != source_declared_space) {
        if (hueChannelIndex(source_declared_space)) |idx| {
            const channels3 = [3]f64{ converted_back.channels[0], converted_back.channels[1], converted_back.channels[2] };
            if (isPowerlessInSpace(source_declared_space, channels3, idx)) {
                output_missing |= @as(ColorMissingMask, 1) << @intCast(idx);
            }
        }
    }

    var output_legacy = source_legacy and isLegacyColorSpace(source_declared_space);
    if ((source_declared_space == .hsl or source_declared_space == .hwb) and output_missing != 0) {
        output_legacy = false;
    }
    const out = try colorValueFromDeclaredColor(ctx, converted_back, source_declared_space, output_missing, output_legacy);
    maybePreferLongHexResult(ctx, out, output_legacy and source_declared_space == .srgb);
    return out;
}

pub fn color_invert(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    try emitColorDeprecation(ctx, "invert() is deprecated; use color.invert() or color.channel() instead");
    return color_invertImpl(ctx, args, arg_names) catch |err| normalizeColorUserError(err);
}

const GrayscaleMode = enum { module, global };

fn grayscaleImpl(ctx: *BuiltinContext, args: []const Value, mode: GrayscaleMode) BuiltinError!Value {
    try expectArity(args, 1);
    if (tryCoerceColorArg(ctx, args[0])) |c| {
        const source_declared_space = declaredColorSpaceFromValue(ctx, c);
        const source_missing = colorMissingMaskFromValue(ctx, c);
        const source_legacy = colorLegacyFlagFromValue(ctx, c);
        const source = localChannelColor(ctx, c);

        if (source_declared_space == .hsl) {
            var hsl = normalizeChannelColor(color_mod.convert(source, .hsl));
            hsl.channels[1] = 0.0;
            const output_missing = source_missing & ~@as(ColorMissingMask, 0x2);
            const output_legacy = source_legacy and output_missing == 0;
            return colorValueFromDeclaredColor(ctx, hsl, .hsl, output_missing, output_legacy);
        }

        if (source_declared_space == .hwb and source_legacy) {
            var hsl = normalizeChannelColor(color_mod.convert(source, .hsl));
            hsl.channels[0] = 0.0;
            hsl.channels[1] = 0.0;
            var output_missing = mapMissingChannels(source_missing, .hwb, .hsl);
            output_missing &= ~@as(ColorMissingMask, 0x2);
            return colorValueFromDeclaredColor(ctx, hsl, .hsl, output_missing, output_missing == 0);
        }

        if (source_legacy) {
            var hsl = normalizeChannelColor(color_mod.convert(source, .hsl));
            hsl.channels[1] = 0.0;
            const rgb = normalizeChannelColor(color_mod.convert(hsl, .srgb));
            return colorValueFromDeclaredColor(ctx, rgb, .srgb, 0, true);
        }

        var oklch = normalizeChannelColor(color_mod.convert(source, .oklch));
        oklch.channels[1] = 0.0;
        const grayscale = if (source_declared_space == .oklch)
            oklch
        else
            normalizeChannelColor(color_mod.convert(oklch, source_declared_space));

        var output_missing = source_missing;
        switch (source_declared_space) {
            .hsl, .lch, .oklch => output_missing &= ~@as(ColorMissingMask, 0x2),
            .lab, .oklab => output_missing &= ~@as(ColorMissingMask, 0x6),
            else => {},
        }
        if (source_declared_space != .oklch) {
            if (hueChannelIndex(source_declared_space)) |hue_idx| {
                const channels3 = [3]f64{ grayscale.channels[0], grayscale.channels[1], grayscale.channels[2] };
                if (isPowerlessInSpace(source_declared_space, channels3, hue_idx)) {
                    output_missing |= @as(ColorMissingMask, 1) << @intCast(hue_idx);
                }
            }
        }
        return colorValueFromDeclaredColor(ctx, grayscale, source_declared_space, output_missing, false);
    }

    const arg0 = args[0];
    if (arg0.isNumber()) return serializeFilterFunction(ctx, "grayscale", arg0, false);
    if (arg0.kind() == .calc_fragment or arg0.kind() == .interp_fragment) {
        if (mode == .module) return error.BuiltinType;
        return serializeFilterFunction(ctx, "grayscale", arg0, true);
    }
    if (arg0.isString()) {
        if (mode == .module) return error.BuiltinType;
        if (arg0.stringQuoted(ctx.string_flags_pool.items)) return error.BuiltinType;
        return serializeFilterFunction(ctx, "grayscale", arg0, false);
    }
    return error.BuiltinType;
}

pub fn color_grayscale(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    return grayscaleImpl(ctx, args, .module) catch |err| normalizeColorUserError(err);
}

pub fn global_grayscale(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try emitColorDeprecation(ctx, "grayscale() is deprecated; use color.channel() or color.to-space() instead");
    return grayscaleImpl(ctx, args, .global) catch |err| normalizeColorUserError(err);
}

fn maybePreferLongHexResult(ctx: *BuiltinContext, value: Value, prefer_long_hex: bool) void {
    if (!prefer_long_hex or value.kind() != .color) return;
    const entry = value.colorEntryMut(ctx.color_pool);
    if (!entry.legacy or entry.space != .srgb or entry.missing != 0) return;
    if (@abs(entry.channels[3] - 1.0) > 1e-10) return;
    if (entry.inspect_repr == .literal_short_hex) {
        entry.inspect_repr = .auto;
    }
    entry.prefer_long_hex = true;
}

fn preserveLegacyRgbTargetSourceRepr(ctx: *BuiltinContext, value: Value, source_entry: *const value_mod.ColorEntry, source_legacy: bool) void {
    if (!source_legacy or source_entry.space != .srgb or value.kind() != .color) return;
    const entry = value.colorEntryMut(ctx.color_pool);
    if (!entry.legacy or entry.space != .srgb) return;
    switch (source_entry.inspect_repr) {
        .literal_short_hex, .literal_long_hex, .legacy_rgb_function => {
            entry.inspect_repr = source_entry.inspect_repr;
            entry.inspect_uppercase_hex = source_entry.inspect_uppercase_hex;
            entry.prefer_long_hex = source_entry.prefer_long_hex;
        },
        .auto => {},
    }
}

fn opacifyImpl(ctx: *BuiltinContext, args: []const Value, comptime alpha_sign: f64) BuiltinError!Value {
    try expectArity(args, 2);
    const c = tryCoerceColorArg(ctx, args[0]) orelse return error.BuiltinType;
    if (!colorLegacyFlagFromValue(ctx, c)) return error.BuiltinType;
    if (args[1].kind() != .number) return error.BuiltinType;
    const amount = args[1].asF64(ctx.number_pool);
    if (std.math.isNan(amount) or amount < 0.0 or amount > 1.0) return error.BuiltinType;
    const source_entry = colorEntryOf(ctx, c);
    const alpha = std.math.clamp(source_entry.channels[3] + alpha_sign * amount, 0.0, 1.0);
    if ((source_entry.space == .hsl or source_entry.space == .hwb) and source_entry.missing == 0) {
        const hsl = colorToHsl(ctx, c);
        return pushColorEntry(ctx, .{
            .channels = .{ hsl[0], hsl[1], hsl[2], alpha },
            .space = .hsl,
            .missing = 0,
            .legacy = true,
        });
    }
    // Preserve fractional srgb channels: round-tripping through
    // `colorCompatRgbBytes` (u8) loses the decimal part that official Sass CLI emits
    // in legacy `rgba(R.XXX, ...)` for colors produced by lighten/adjust/etc.
    const srgb = colorCompatSrgb(ctx, c);
    return pushColorEntry(ctx, .{
        .channels = .{ srgb.channels[0], srgb.channels[1], srgb.channels[2], alpha },
        .space = .srgb,
        .missing = 0,
        .legacy = true,
    });
}

pub fn color_opacify(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try emitColorDeprecation(ctx, "opacify()/fade-in() is deprecated; use color.adjust() with $alpha instead");
    return opacifyImpl(ctx, args, 1.0);
}

pub fn color_transparentize(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try emitColorDeprecation(ctx, "transparentize()/fade-out() is deprecated; use color.adjust() with $alpha instead");
    return opacifyImpl(ctx, args, -1.0);
}

pub fn color_ie_hex_str(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try emitColorDeprecation(ctx, "ie-hex-str() is deprecated; use color.to-space() instead");
    try expectArity(args, 1);
    const c = tryCoerceColorArg(ctx, args[0]) orelse return error.BuiltinType;
    const rgb = colorCompatRgbBytes(ctx, c);
    const a256 = colorCompatAlphaByte(ctx, c);
    const hex = try std.fmt.allocPrint(ctx.allocator, "#{X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{
        a256,
        rgb[0],
        rgb[1],
        rgb[2],
    });
    defer ctx.allocator.free(hex);
    const id = try internString(ctx, hex);
    return Value.string(id, false).withPreserveLiteralText().withPreserveDeclText();
}

pub fn color_channel(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    if (args.len < 2 or args.len > 3) return badArity(2, args.len);
    var color_v: ?Value = null;
    var channel_v: ?Value = null;
    var space_v: ?Value = null;
    var positional: usize = 0;

    for (args, 0..) |arg, i| {
        const name_id: InternId = if (i < arg_names.len) arg_names[i] else .none;
        if (name_id != .none) {
            if (argNameMatches(ctx, name_id, "color")) {
                color_v = arg;
                continue;
            }
            if (argNameMatches(ctx, name_id, "channel")) {
                channel_v = arg;
                continue;
            }
            if (argNameMatches(ctx, name_id, "space")) {
                space_v = arg;
                continue;
            }
        }
        switch (positional) {
            0 => {
                if (color_v == null) color_v = arg;
            },
            1 => {
                if (channel_v == null) channel_v = arg;
            },
            2 => {
                if (space_v == null) space_v = arg;
            },
            else => {},
        }
        positional += 1;
    }

    const c_in = color_v orelse return error.BuiltinType;
    const ch = channel_v orelse return error.BuiltinType;
    const c = tryCoerceColorArg(ctx, c_in) orelse return error.BuiltinType;
    if (ch.kind() != .string or !ch.stringQuoted(ctx.string_flags_pool.items)) return error.BuiltinType;

    const ch_name = ctx.intern_pool.get(ch.stringIntern());
    const known_channel_name = switch (ch_name.len) {
        1 => switch (ch_name[0]) {
            'a', 'b', 'x', 'y', 'z' => true,
            else => false,
        },
        3 => std.mem.eql(u8, ch_name, "red") or std.mem.eql(u8, ch_name, "hue"),
        4 => std.mem.eql(u8, ch_name, "blue"),
        5 => std.mem.eql(u8, ch_name, "green") or std.mem.eql(u8, ch_name, "alpha"),
        6 => std.mem.eql(u8, ch_name, "chroma"),
        9 => std.mem.eql(u8, ch_name, "lightness") or
            std.mem.eql(u8, ch_name, "whiteness") or
            std.mem.eql(u8, ch_name, "blackness"),
        10 => std.mem.eql(u8, ch_name, "saturation"),
        else => false,
    };
    if (!known_channel_name) return error.BuiltinType;
    var target_space: ?color_mod.ColorSpace = null;
    var legacy_rgb_space = false;
    if (space_v) |sv| {
        if (sv.kind() == .nil) {
            // keep defaults
        } else if (sv.isString()) {
            if (sv.stringQuoted(ctx.string_flags_pool.items)) return error.BuiltinType;
            const raw = shared.stripCalcArgMarker(ctx.intern_pool.get(sv.stringIntern()));
            if (colorSpaceNameEq(raw, "rgb")) legacy_rgb_space = true;
            target_space = parseColorSpaceName(raw) orelse return error.BuiltinType;
        } else {
            return error.BuiltinType;
        }
    }
    return getColorChannel(ctx, c, ch_name, target_space, legacy_rgb_space);
}

const ParsedColorSpaceArg = struct {
    space: color_mod.ColorSpace,
    legacy_rgb_alias: bool = false,
};

fn parseColorSpaceArgString(raw: []const u8) BuiltinError!ParsedColorSpaceArg {
    const space = parseColorSpaceName(raw) orelse return error.BuiltinType;
    return .{
        .space = space,
        .legacy_rgb_alias = colorSpaceNameEq(raw, "rgb"),
    };
}

fn parseOptionalSpaceValue(ctx: *BuiltinContext, maybe_value: ?Value) BuiltinError!?color_mod.ColorSpace {
    const value = maybe_value orelse return null;
    if (value.kind() == .nil) return null;
    if (value.isString()) {
        if (value.stringQuoted(ctx.string_flags_pool.items)) return error.BuiltinType;
        const raw = ctx.intern_pool.get(value.stringIntern());
        return (try parseColorSpaceArgString(raw)).space;
    }
    return error.BuiltinType;
}

fn parseOptionalSpaceArgValue(ctx: *BuiltinContext, maybe_value: ?Value) BuiltinError!?ParsedColorSpaceArg {
    const value = maybe_value orelse return null;
    if (value.kind() == .nil) return null;
    if (value.isString()) {
        if (value.stringQuoted(ctx.string_flags_pool.items)) return error.BuiltinType;
        return try parseColorSpaceArgString(ctx.intern_pool.get(value.stringIntern()));
    }
    return error.BuiltinType;
}

fn parseRequiredSpaceArgValue(ctx: *BuiltinContext, value: Value) BuiltinError!ParsedColorSpaceArg {
    if (value.isString()) {
        if (value.stringQuoted(ctx.string_flags_pool.items)) return error.BuiltinType;
        return parseColorSpaceArgString(ctx.intern_pool.get(value.stringIntern()));
    }
    return error.BuiltinType;
}

fn parseMethodValue(ctx: *BuiltinContext, maybe_value: ?Value) BuiltinError![]const u8 {
    const value = maybe_value orelse return error.BuiltinType;
    if (value.kind() != .string) return error.BuiltinType;
    if (value.stringQuoted(ctx.string_flags_pool.items)) return error.BuiltinType;
    const raw = ctx.intern_pool.get(value.stringIntern());
    if (raw.len == 0 or raw.len > 32) return error.BuiltinType;
    var lowered_buf: [32]u8 = undefined;
    for (raw, 0..) |ch, i| {
        lowered_buf[i] = if (ch == '_') '-' else std.ascii.toLower(ch);
    }
    const lowered = lowered_buf[0..raw.len];
    if (std.mem.eql(u8, lowered, "clip") or std.mem.eql(u8, lowered, "local-minde")) {
        const id = try internString(ctx, lowered);
        return ctx.intern_pool.get(id);
    }
    return error.BuiltinType;
}

fn parseOptionalSpaceValueSassError(ctx: *BuiltinContext, maybe_value: ?Value) BuiltinError!?color_mod.ColorSpace {
    return parseOptionalSpaceValue(ctx, maybe_value) catch |err| switch (err) {
        error.BuiltinType => error.SassError,
        else => err,
    };
}

fn parseMethodValueForToGamut(ctx: *BuiltinContext, maybe_value: ?Value) BuiltinError![]const u8 {
    const value = maybe_value orelse return error.SassError;
    if (value.kind() == .nil) return error.SassError;
    return parseMethodValue(ctx, value) catch |err| switch (err) {
        error.BuiltinType => error.SassError,
        else => err,
    };
}

fn isAngleUnit(unit: []const u8) bool {
    return std.ascii.eqlIgnoreCase(unit, "deg") or
        std.ascii.eqlIgnoreCase(unit, "rad") or
        std.ascii.eqlIgnoreCase(unit, "grad") or
        std.ascii.eqlIgnoreCase(unit, "turn");
}

fn modernColorChannelUnitAllowed(unit: ?[]const u8, space: color_mod.ColorSpace, ch_idx: usize) bool {
    const u = unit orelse return true;
    if (std.ascii.eqlIgnoreCase(u, "%")) {
        return switch (space) {
            .lch, .oklch => ch_idx != 2,
            .hwb => ch_idx != 0,
            else => true,
        };
    }
    return switch (space) {
        .lch, .oklch => ch_idx == 2 and isAngleUnit(u),
        .hwb => ch_idx == 0 and isAngleUnit(u),
        else => false,
    };
}

fn angleToDegrees(value: f64, unit: ?[]const u8) f64 {
    if (unit) |u| {
        if (std.ascii.eqlIgnoreCase(u, "rad")) return value * 180.0 / std.math.pi;
        if (std.ascii.eqlIgnoreCase(u, "grad")) return value * 0.9;
        if (std.ascii.eqlIgnoreCase(u, "turn")) return value * 360.0;
    }
    return value;
}

fn extractModernConstructorChannel(
    ctx: *BuiltinContext,
    arg: Value,
    space: color_mod.ColorSpace,
    ch_idx: usize,
) BuiltinError!f64 {
    const raw, const unit = if (arg.isNumber())
        .{ arg.asF64(ctx.number_pool), if (arg.unitId(ctx.number_pool) == .none) null else ctx.intern_pool.get(arg.unitId(ctx.number_pool)) }
    else
        .{ parseCalcSpecialNumber(ctx, arg) orelse return error.BuiltinType, @as(?[]const u8, null) };
    if (!modernColorChannelUnitAllowed(unit, space, ch_idx)) return error.BuiltinType;

    const is_hue_channel = switch (space) {
        .lch, .oklch => ch_idx == 2,
        else => false,
    };

    if (is_hue_channel) {
        const deg = angleToDegrees(raw, unit);
        if (std.math.isFinite(deg)) {
            return normalizeColorOpChannel(space, ch_idx, deg);
        }
        return switch (space) {
            .lch, .oklch => std.math.nan(f64),
            else => deg,
        };
    }

    var value = if (unit != null and std.ascii.eqlIgnoreCase(unit.?, "%"))
        switch (space) {
            .lab => switch (ch_idx) {
                0 => raw,
                else => raw * 1.25,
            },
            .lch => switch (ch_idx) {
                0 => raw,
                1 => raw * 1.5,
                else => raw,
            },
            .oklab => switch (ch_idx) {
                0 => raw / 100.0,
                else => raw * 0.004,
            },
            .oklch => switch (ch_idx) {
                0 => raw / 100.0,
                1 => raw * 0.004,
                else => raw,
            },
            else => raw / 100.0,
        }
    else
        raw;

    if (!std.math.isFinite(value)) {
        value = switch (space) {
            .lab => switch (ch_idx) {
                0 => if (std.math.isInf(value) and value > 0.0) 100.0 else 0.0,
                else => value,
            },
            .lch => switch (ch_idx) {
                0 => if (std.math.isInf(value) and value > 0.0) 100.0 else 0.0,
                1 => if (std.math.isInf(value) and value > 0.0) value else 0.0,
                2 => std.math.nan(f64),
                else => value,
            },
            .oklab => switch (ch_idx) {
                0 => if (std.math.isInf(value) and value > 0.0) 1.0 else 0.0,
                else => value,
            },
            .oklch => switch (ch_idx) {
                0 => if (std.math.isInf(value) and value > 0.0) 1.0 else 0.0,
                1 => if (std.math.isInf(value) and value > 0.0) value else 0.0,
                2 => std.math.nan(f64),
                else => value,
            },
            else => value,
        };
    }

    if (std.math.isFinite(value)) {
        return boundColorOpChannel(space, ch_idx, normalizeColorOpChannel(space, ch_idx, value));
    }
    return value;
}

fn extractModernConstructorAlpha(ctx: *BuiltinContext, arg: Value) BuiltinError!f64 {
    const raw, const unit = if (arg.isNumber())
        .{ arg.asF64(ctx.number_pool), if (arg.unitId(ctx.number_pool) == .none) null else ctx.intern_pool.get(arg.unitId(ctx.number_pool)) }
    else
        .{ parseCalcSpecialNumber(ctx, arg) orelse return error.BuiltinType, @as(?[]const u8, null) };
    const normalized = if (unit) |u| blk: {
        if (!std.ascii.eqlIgnoreCase(u, "%")) return error.BuiltinType;
        break :blk raw / 100.0;
    } else raw;
    if (std.math.isNan(normalized)) return 0.0;
    if (std.math.isInf(normalized)) return if (normalized < 0.0) 0.0 else 1.0;
    return std.math.clamp(normalized, 0.0, 1.0);
}

fn extractModernConstructorComponent(
    ctx: *BuiltinContext,
    arg: Value,
    space: color_mod.ColorSpace,
    ch_idx: usize,
) ?ParsedColorComponent {
    if (isNoneColorToken(ctx, arg)) return .{ .value = 0.0, .missing = true };
    const value = extractModernConstructorChannel(ctx, arg, space, ch_idx) catch return null;
    return .{ .value = value, .missing = false };
}

fn extractModernConstructorAlphaComponent(ctx: *BuiltinContext, arg: Value) ?ParsedColorComponent {
    if (isNoneColorToken(ctx, arg)) return .{ .value = 0.0, .missing = true };
    const value = extractModernConstructorAlpha(ctx, arg) catch return null;
    return .{ .value = value, .missing = false };
}

fn colorModernConstructor(
    ctx: *BuiltinContext,
    args: []const Value,
    arg_names: []const InternId,
    fn_name: []const u8,
    space: color_mod.ColorSpace,
) BuiltinError!Value {
    if ((space == .lab or space == .lch or space == .oklab or space == .oklch) and args.len > 1) {
        var all_positional = true;
        for (args, 0..) |_, i| {
            const name_id: InternId = if (i < arg_names.len) arg_names[i] else .none;
            if (name_id != .none) {
                all_positional = false;
                break;
            }
        }
        if (all_positional) return error.BuiltinArity;
    }

    const slot_names: []const []const u8 = switch (space) {
        .lab, .oklab => &.{ "lightness", "a", "b", "alpha" },
        .lch, .oklch => &.{ "lightness", "chroma", "hue", "alpha" },
        else => &.{ "channel0", "channel1", "channel2", "alpha" },
    };
    const bound = bindColorArgs(ctx, args, arg_names, slot_names, true) catch |err| {
        if (err == error.BuiltinArity) {
            if (shouldSerializeColorFallback(ctx, args)) {
                return serializeModernConstructorFallback(ctx, fn_name, args);
            }
            if (coerceModernConstructorArityToType(space, args)) {
                return error.BuiltinType;
            }
        }
        return err;
    };

    const c0 = extractModernConstructorComponent(ctx, bound.values[0].?, space, 0) orelse {
        if (valueLooksLikeColorPassthrough(ctx, bound.values[0].?)) return serializeModernConstructorFallback(ctx, fn_name, args);
        return error.BuiltinType;
    };
    const c1 = extractModernConstructorComponent(ctx, bound.values[1].?, space, 1) orelse {
        if (valueLooksLikeColorPassthrough(ctx, bound.values[1].?)) return serializeModernConstructorFallback(ctx, fn_name, args);
        return error.BuiltinType;
    };
    const c2 = extractModernConstructorComponent(ctx, bound.values[2].?, space, 2) orelse {
        if (valueLooksLikeColorPassthrough(ctx, bound.values[2].?)) return serializeModernConstructorFallback(ctx, fn_name, args);
        return error.BuiltinType;
    };
    const alpha = extractModernConstructorAlphaComponent(ctx, bound.values[3].?) orelse {
        if (valueLooksLikeColorPassthrough(ctx, bound.values[3].?)) return serializeModernConstructorFallback(ctx, fn_name, args);
        return error.BuiltinType;
    };

    var missing: ColorMissingMask = 0;
    if (c0.missing) missing |= 0x1;
    if (c1.missing) missing |= 0x2;
    if (c2.missing) missing |= 0x4;
    if (alpha.missing) missing |= 0x8;

    const constructed = normalizeChannelColor(color_mod.Color.init(c0.value, c1.value, c2.value, alpha.value, space));
    return colorValueFromDeclaredColor(ctx, constructed, space, missing, missing == 0 and isLegacyColorSpace(space));
}

pub fn color_lab(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    return colorModernConstructor(ctx, args, arg_names, "lab", .lab) catch |err| normalizeColorUserError(err);
}

pub fn color_lch(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    return colorModernConstructor(ctx, args, arg_names, "lch", .lch) catch |err| normalizeColorUserError(err);
}

pub fn color_oklab(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    return colorModernConstructor(ctx, args, arg_names, "oklab", .oklab) catch |err| normalizeColorUserError(err);
}

pub fn color_oklch(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    return colorModernConstructor(ctx, args, arg_names, "oklch", .oklch) catch |err| normalizeColorUserError(err);
}

fn channelIndexForSpaceStrict(space: color_mod.ColorSpace, ch_name: []const u8) ?usize {
    return switch (space) {
        .srgb, .srgb_linear, .display_p3, .display_p3_linear, .a98_rgb, .prophoto_rgb, .rec2020 => if (std.mem.eql(u8, ch_name, "red")) 0 else if (std.mem.eql(u8, ch_name, "green")) 1 else if (std.mem.eql(u8, ch_name, "blue")) 2 else if (std.mem.eql(u8, ch_name, "alpha")) 3 else null,
        .hsl => if (std.mem.eql(u8, ch_name, "hue")) 0 else if (std.mem.eql(u8, ch_name, "saturation")) 1 else if (std.mem.eql(u8, ch_name, "lightness")) 2 else if (std.mem.eql(u8, ch_name, "alpha")) 3 else null,
        .hwb => if (std.mem.eql(u8, ch_name, "hue")) 0 else if (std.mem.eql(u8, ch_name, "whiteness")) 1 else if (std.mem.eql(u8, ch_name, "blackness")) 2 else if (std.mem.eql(u8, ch_name, "alpha")) 3 else null,
        .lab, .oklab => if (std.mem.eql(u8, ch_name, "lightness")) 0 else if (std.mem.eql(u8, ch_name, "a")) 1 else if (std.mem.eql(u8, ch_name, "b")) 2 else if (std.mem.eql(u8, ch_name, "alpha")) 3 else null,
        .lch, .oklch => if (std.mem.eql(u8, ch_name, "lightness")) 0 else if (std.mem.eql(u8, ch_name, "chroma")) 1 else if (std.mem.eql(u8, ch_name, "hue")) 2 else if (std.mem.eql(u8, ch_name, "alpha")) 3 else null,
        .xyz_d50, .xyz_d65 => if (std.mem.eql(u8, ch_name, "x")) 0 else if (std.mem.eql(u8, ch_name, "y")) 1 else if (std.mem.eql(u8, ch_name, "z")) 2 else if (std.mem.eql(u8, ch_name, "alpha")) 3 else null,
    };
}

fn isPowerlessInSpace(space: color_mod.ColorSpace, channels: [3]f64, channel_idx: usize) bool {
    return switch (space) {
        .hsl => channel_idx == 0 and @abs(channels[1]) < 1e-6,
        .hwb => channel_idx == 0 and channels[1] + channels[2] >= 100.0 - 1e-6,
        .lch => channel_idx == 2 and @abs(channels[1]) < 0.05,
        .oklch => channel_idx == 2 and @abs(channels[1]) < 1e-4,
        else => false,
    };
}

pub fn color_is_legacy(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    if (args.len > 1) return badArity(1, args.len);
    const bound = bindNamedOrPositionalArgs(ctx, args, arg_names, &.{"color"});
    try validateRequiredBound(&.{"color"}, &bound, 1);
    const color_arg = bound[0].?;
    const c = tryCoerceColorArg(ctx, color_arg) orelse return error.BuiltinType;
    return if (colorLegacyFlagFromValue(ctx, c)) Value.true_v else Value.false_v;
}

pub fn color_is_in_gamut(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    if (args.len > 2) return badArity(1, args.len);
    const bound = bindNamedOrPositionalArgs(ctx, args, arg_names, &.{ "color", "space" });
    try validateRequiredBound(&.{ "color", "space" }, &bound, 1);
    const color_arg = bound[0].?;
    const c = tryCoerceColorArg(ctx, color_arg) orelse return error.BuiltinType;
    const target_space = try parseOptionalSpaceValue(ctx, bound[1]);
    const source = localChannelColor(ctx, c);
    const in_space = if (target_space) |sp|
        normalizeChannelColor(color_mod.convert(source, sp))
    else
        source;
    return if (color_mod.isInGamut(in_space)) Value.true_v else Value.false_v;
}

pub fn color_is_missing(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    if (args.len != 2) return badArity(2, args.len);
    const bound = bindNamedOrPositionalArgs(ctx, args, arg_names, &.{ "color", "channel" });
    try validateRequiredBound(&.{ "color", "channel" }, &bound, 2);
    const color_arg = bound[0].?;
    const channel_arg = bound[1].?;
    const c = tryCoerceColorArg(ctx, color_arg) orelse return error.BuiltinType;
    if (channel_arg.kind() != .string or !channel_arg.stringQuoted(ctx.string_flags_pool.items)) return error.BuiltinType;
    const channel_name = ctx.intern_pool.get(channel_arg.stringIntern());
    const idx = channelIndexForSpaceStrict(declaredColorSpaceFromValue(ctx, c), channel_name) orelse return error.BuiltinType;
    const mask: ColorMissingMask = @as(ColorMissingMask, 1) << @intCast(idx);
    return if ((colorMissingMaskFromValue(ctx, c) & mask) != 0) Value.true_v else Value.false_v;
}

pub fn color_is_powerless(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    if (args.len > 3) return badArity(2, args.len);
    const bound = bindNamedOrPositionalArgs(ctx, args, arg_names, &.{ "color", "channel", "space" });
    try validateRequiredBound(&.{ "color", "channel", "space" }, &bound, 2);
    const color_arg = bound[0].?;
    const channel_arg = bound[1].?;
    const c = tryCoerceColorArg(ctx, color_arg) orelse return error.SassError;
    if (channel_arg.kind() != .string or !channel_arg.stringQuoted(ctx.string_flags_pool.items)) return error.SassError;
    const channel_name = ctx.intern_pool.get(channel_arg.stringIntern());
    const target_space = try parseOptionalSpaceValueSassError(ctx, bound[2]);

    const source = localChannelColor(ctx, c);
    const in_space = normalizeChannelColor(if (target_space) |sp| color_mod.convert(source, sp) else source);
    const idx = channelIndexForSpaceStrict(in_space.space, channel_name) orelse return error.SassError;
    if (idx >= 3) return Value.false_v;
    const channels3 = [3]f64{ in_space.channels[0], in_space.channels[1], in_space.channels[2] };
    return if (isPowerlessInSpace(in_space.space, channels3, idx)) Value.true_v else Value.false_v;
}

pub fn color_space(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    if (args.len > 1) return badArity(1, args.len);
    const bound = bindNamedOrPositionalArgs(ctx, args, arg_names, &.{"color"});
    try validateRequiredBound(&.{"color"}, &bound, 1);
    const color_arg = bound[0].?;
    const c = tryCoerceColorArg(ctx, color_arg) orelse return error.BuiltinType;
    const declared = declaredColorSpaceFromValue(ctx, c);
    const name = if (declared == .srgb and !colorLegacyFlagFromValue(ctx, c))
        "srgb"
    else
        colorSpaceCssName(declared);
    const id = try internString(ctx, name);
    return Value.string(id, false);
}

pub fn color_same(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    if (args.len > 2) return badArity(2, args.len);
    const bound = bindNamedOrPositionalArgs(ctx, args, arg_names, &.{ "color1", "color2" });
    try validateRequiredBound(&.{ "color1", "color2" }, &bound, 2);
    const left_arg = bound[0].?;
    const right_arg = bound[1].?;
    const c1 = tryCoerceColorArg(ctx, left_arg) orelse return error.BuiltinType;
    const c2 = tryCoerceColorArg(ctx, right_arg) orelse return error.BuiltinType;
    const xyz1 = color_mod.convert(colorSameComparisonColor(ctx, c1), .xyz_d65);
    const xyz2 = color_mod.convert(colorSameComparisonColor(ctx, c2), .xyz_d65);
    return if (xyz1.eql(xyz2, 1e-11)) Value.true_v else Value.false_v;
}

pub fn color_to_gamut(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    if (args.len > 3) return badArity(1, args.len);
    const bound = bindNamedOrPositionalArgs(ctx, args, arg_names, &.{ "color", "space", "method" });
    try validateRequiredBound(&.{ "color", "space", "method" }, &bound, 1);
    const color_arg = bound[0].?;
    const c = tryCoerceColorArg(ctx, color_arg) orelse return error.SassError;
    const source_space = declaredColorSpaceFromValue(ctx, c);
    const source = localChannelColor(ctx, c);
    const source_missing = colorMissingMaskFromValue(ctx, c);
    const source_legacy = colorLegacyCompatFlagFromValue(ctx, c);
    const target_space = (try parseOptionalSpaceValueSassError(ctx, bound[1])) orelse source.space;
    const method = try parseMethodValueForToGamut(ctx, bound[2]);

    if (target_space.gamutBounds() == null) {
        // Lab-like spaces without gamut bounds still fall back to color-mix
        // serialization when lightness is outside the representable range.
        const lightness_missing = switch (source_space) {
            .lab, .lch, .oklab, .oklch => (source_missing & 0x1) != 0,
            else => false,
        };
        if (!lightness_missing) {
            const lab_tol = 1e-10;
            if ((source_space == .lab and (source.channels[0] < -lab_tol or source.channels[0] > 100.0 + lab_tol)) or
                (source_space == .lch and (source.channels[0] < -lab_tol or source.channels[0] > 100.0 + lab_tol)) or
                (source_space == .oklab and (source.channels[0] < -lab_tol or source.channels[0] > 1.0 + lab_tol)) or
                (source_space == .oklch and (source.channels[0] < -lab_tol or source.channels[0] > 1.0 + lab_tol)))
            {
                return serializeLabLikeOutOfRange(ctx, source, source_space);
            }
        }
        return c;
    }

    const target_color = if (target_space == source.space) source else color_mod.convert(source, target_space);
    const target_was_in_gamut = color_mod.isInGamut(target_color);
    const mapped_in_target = if (std.mem.eql(u8, method, "clip"))
        color_mod.clipToGamut(target_color)
    else
        color_mod.toGamut(target_color);
    var mapped = if (target_space == source.space) mapped_in_target else color_mod.convert(mapped_in_target, source.space);
    var output_missing: ColorMissingMask = if (target_space == source_space)
        source_missing
    else
        mapMissingChannels(source_missing, source_space, target_space);
    if (target_space != source_space) {
        output_missing = mapMissingChannels(output_missing, target_space, source_space);
    }

    if (source_legacy and source_missing != 0 and target_space != source_space) {
        output_missing = 0;
    }
    // Once local-minde gamut mapping actually runs, missing RGB channels are
    // no longer retained in the mapped result.
    if (std.mem.eql(u8, method, "local-minde") and source_space == target_space and source_missing != 0 and !target_was_in_gamut) {
        output_missing = 0;
    }

    // Lab-like lightness endpoints snap to their black/white extremes, while
    // values outside the endpoint range use color-mix fallback serialization.
    switch (source_space) {
        .lab => {
            if (@abs(source.channels[0]) <= 1e-12 and mapped.channels[0] <= 2.0) {
                mapped.channels[0] = 0.0;
                mapped.channels[1] = 0.0;
                mapped.channels[2] = 0.0;
            } else if (@abs(source.channels[0] - 100.0) <= 1e-12 and mapped.channels[0] >= 98.0) {
                mapped.channels[0] = 100.0;
                mapped.channels[1] = 0.0;
                mapped.channels[2] = 0.0;
            }
        },
        .lch => {
            if (@abs(source.channels[0]) <= 1e-12 and mapped.channels[0] <= 2.0) {
                mapped.channels[0] = 0.0;
                mapped.channels[1] = 0.0;
            } else if (@abs(source.channels[0] - 100.0) <= 1e-12 and mapped.channels[0] >= 98.0) {
                mapped.channels[0] = 100.0;
                mapped.channels[1] = 0.0;
            }
        },
        .oklab => {
            if (@abs(source.channels[0]) <= 1e-12 and mapped.channels[0] <= 0.02) {
                mapped.channels[0] = 0.0;
                mapped.channels[1] = 0.0;
                mapped.channels[2] = 0.0;
            } else if (@abs(source.channels[0] - 1.0) <= 1e-12 and mapped.channels[0] >= 0.98) {
                mapped.channels[0] = 1.0;
                mapped.channels[1] = 0.0;
                mapped.channels[2] = 0.0;
            }
        },
        .oklch => {
            if (@abs(source.channels[0]) <= 1e-12 and mapped.channels[0] <= 0.02) {
                mapped.channels[0] = 0.0;
                mapped.channels[1] = 0.0;
            } else if (@abs(source.channels[0] - 1.0) <= 1e-12 and mapped.channels[0] >= 0.98) {
                mapped.channels[0] = 1.0;
                mapped.channels[1] = 0.0;
            }
        },
        else => {},
    }

    const lab_tol = 1e-10;
    switch (source_space) {
        .lab, .lch => {
            if (@abs(mapped.channels[0]) <= lab_tol) mapped.channels[0] = 0.0;
            if (@abs(mapped.channels[0] - 100.0) <= lab_tol) mapped.channels[0] = 100.0;
        },
        .oklab, .oklch => {
            if (@abs(mapped.channels[0]) <= lab_tol) mapped.channels[0] = 0.0;
            if (@abs(mapped.channels[0] - 1.0) <= lab_tol) mapped.channels[0] = 1.0;
        },
        else => {},
    }
    if ((source_space == .lab and (mapped.channels[0] < -lab_tol or mapped.channels[0] > 100.0 + lab_tol)) or
        (source_space == .lch and (mapped.channels[0] < -lab_tol or mapped.channels[0] > 100.0 + lab_tol)) or
        (source_space == .oklab and (mapped.channels[0] < -lab_tol or mapped.channels[0] > 1.0 + lab_tol)) or
        (source_space == .oklch and (mapped.channels[0] < -lab_tol or mapped.channels[0] > 1.0 + lab_tol)))
    {
        return serializeLabLikeOutOfRange(ctx, mapped, source_space);
    }

    if (std.mem.eql(u8, method, "local-minde") and source_space == target_space) {
        if (hueChannelIndex(source_space)) |idx| {
            const channels3 = [3]f64{ mapped.channels[0], mapped.channels[1], mapped.channels[2] };
            if (isPowerlessInSpace(source_space, channels3, idx)) {
                output_missing |= @as(ColorMissingMask, 1) << @intCast(idx);
            }
        }
    }
    if (!source_legacy) {
        if (hueChannelIndex(source_space)) |idx| {
            const channels3 = [3]f64{ mapped.channels[0], mapped.channels[1], mapped.channels[2] };
            if (isPowerlessInSpace(source_space, channels3, idx)) {
                output_missing |= @as(ColorMissingMask, 1) << @intCast(idx);
            }
        }
    }
    var output_legacy = source_legacy and isLegacyColorSpace(source_space);
    if ((source_space == .hsl or source_space == .hwb) and output_missing != 0 and target_space == source_space) {
        output_legacy = false;
    }
    const out = try colorValueFromDeclaredColor(ctx, mapped, source_space, output_missing, output_legacy);
    maybePreferLongHexResult(ctx, out, output_legacy and source_space == .srgb);
    return out;
}

pub fn color_to_space(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    if (args.len > 2) return badArity(2, args.len);
    const bound = bindNamedOrPositionalArgs(ctx, args, arg_names, &.{ "color", "space" });
    try validateRequiredBound(&.{ "color", "space" }, &bound, 2);
    const color_arg = bound[0].?;
    const space_arg = bound[1].?;
    const target_spec = try parseRequiredSpaceArgValue(ctx, space_arg);
    const target_space = target_spec.space;

    if (tryCoerceColorArg(ctx, color_arg)) |c| {
        const source_entry = colorEntryOf(ctx, c).*;
        const source = localChannelColor(ctx, c);
        const source_declared_space = declaredColorSpaceFromValue(ctx, c);
        const source_missing = colorMissingMaskFromValue(ctx, c);
        const source_legacy = colorLegacyFlagFromValue(ctx, c);
        const converted = color_mod.convert(source, target_space);
        var mapped_missing = mapMissingChannels(source_missing, source_declared_space, target_space);
        if (target_space == .lab and source_declared_space == .lch) {
            if ((source_missing & 0x1) != 0) {
                mapped_missing |= 0x7;
            } else if ((source_missing & 0x2) == 0 and @abs(source.channels[0]) <= 1e-10 and @abs(source.channels[1]) <= 1e-10) {
                mapped_missing |= 0x6;
            }
        }
        if ((target_space == .lch or target_space == .oklch) and source_declared_space != target_space and
            (source_declared_space == .hsl or source_declared_space == .lch or source_declared_space == .oklch) and
            (source_missing & 0x2) != 0)
        {
            mapped_missing |= 0x4;
        }
        if (((target_space == .hsl and source_declared_space != .hsl) or target_space == .hwb) and (mapped_missing & 0x1) != 0) {
            mapped_missing &= ~@as(ColorMissingMask, 0x1);
        }
        if (target_space == .hsl and source_declared_space != .hsl) {
            mapped_missing = 0;
        }
        if (target_space == .hsl and source_declared_space == .hwb) mapped_missing &= 0x8;
        if (target_space == .hwb and source_declared_space == .hsl) mapped_missing &= 0x8;
        if ((target_space == .lch or target_space == .oklch) and (mapped_missing & 0x2) == 0 and @abs(converted.channels[1]) <= 1e-10) {
            mapped_missing |= 0x4;
        }

        const lab_tol = 1e-10;
        if (!isTargetLabLikeLightnessMissing(target_space, mapped_missing) and
            ((target_space == .lab and (converted.channels[0] < -lab_tol or converted.channels[0] > 100.0 + lab_tol)) or
                (target_space == .lch and (converted.channels[0] < -lab_tol or converted.channels[0] > 100.0 + lab_tol)) or
                (target_space == .oklab and (converted.channels[0] < -lab_tol or converted.channels[0] > 1.0 + lab_tol)) or
                (target_space == .oklch and (converted.channels[0] < -lab_tol or converted.channels[0] > 1.0 + lab_tol))))
        {
            return serializeToSpaceLabLikeOutOfRange(ctx, converted, target_space, source_declared_space);
        }

        if (target_space == .srgb and target_spec.legacy_rgb_alias) {
            var r255 = converted.channels[0] * 255.0;
            var g255 = converted.channels[1] * 255.0;
            var b255 = converted.channels[2] * 255.0;

            const preserve_rgb_missing = blk: {
                if ((mapped_missing & 0x7) == 0) break :blk false;
                if (source_declared_space != .srgb) break :blk false;
                break :blk source_entry.inspect_repr == .legacy_rgb_function;
            };

            var output_missing = mapped_missing;
            if (!preserve_rgb_missing) {
                if ((output_missing & 0x1) != 0) r255 = 0.0;
                if ((output_missing & 0x2) != 0) g255 = 0.0;
                if ((output_missing & 0x4) != 0) b255 = 0.0;
                output_missing &= ~@as(ColorMissingMask, 0x7);
            }

            const out_of_gamut = !std.math.isFinite(r255) or !std.math.isFinite(g255) or !std.math.isFinite(b255) or
                r255 < -1e-10 or r255 > 255.0 + 1e-10 or
                g255 < -1e-10 or g255 > 255.0 + 1e-10 or
                b255 < -1e-10 or b255 > 255.0 + 1e-10;

            if (out_of_gamut) {
                const hsl = if ((mapped_missing & 0x7) != 0)
                    color_mod.rgb255ToHsl(r255, g255, b255)
                else blk: {
                    const source_hsl = color_mod.convert(source, .hsl);
                    break :blk [3]f64{ source_hsl.channels[0], source_hsl.channels[1], source_hsl.channels[2] };
                };

                return colorValueFromDeclaredColor(
                    ctx,
                    color_mod.Color.init(hsl[0], hsl[1], hsl[2], converted.channels[3], .hsl),
                    .hsl,
                    output_missing & 0x8,
                    true,
                );
            }

            const rgb = color_mod.Color.init(r255 / 255.0, g255 / 255.0, b255 / 255.0, converted.channels[3], .srgb);
            const out = try colorValueFromDeclaredColor(ctx, rgb, .srgb, output_missing, true);
            preserveLegacyRgbTargetSourceRepr(ctx, out, &source_entry, source_legacy);
            if (out.kind() == .color and source_missing != 0 and source_declared_space == .srgb) {
                out.colorEntryMut(ctx.color_pool).inspect_repr = .legacy_rgb_function;
            }
            maybePreferLongHexResult(ctx, out, shouldPreferLongHexForToSpaceLegacyRgbTarget(&source_entry, source_declared_space));
            return out;
        }

        const target_legacy = switch (target_space) {
            // Legacy aliases keep legacy serialization only for the matching
            // target route: rgb aliases, hsl without missing channels, and hwb.
            // srgb itself remains modern syntax even for legacy-source colors.
            .srgb => target_spec.legacy_rgb_alias,
            .hsl => mapped_missing == 0,
            .hwb => true,
            else => false,
        };
        const out = try colorValueFromDeclaredColor(ctx, converted, target_space, mapped_missing, target_legacy);
        if (out.kind() == .color) {
            const entry = out.colorEntryMut(ctx.color_pool);
            if (((target_space == .hsl and !isSemanticHslSourceEntry(&source_entry)) or target_space == .hwb) and
                hasMissingPolarHueEntry(&source_entry))
            {
                entry.channels[0] = 0.0;
                entry.missing &= ~@as(ColorMissingMask, 0x1);
            }
            if (target_space == .hsl and hasMissingLightnessEntry(&source_entry)) {
                entry.channels[2] = 0.0;
            }
            if (target_space == .hwb and source_legacy and source_declared_space == .srgb and entry.channels[1] < 0.0) {
                entry.channels[1] = std.math.nextAfter(f64, entry.channels[1], -std.math.inf(f64));
            }
            if (target_space == .hwb and source_declared_space == .prophoto_rgb and entry.channels[2] < 0.0) {
                entry.hwb_blackness_channel_next_up = true;
            }
        }
        if (target_spec.legacy_rgb_alias) maybePreferLongHexResult(ctx, out, true);
        if (target_space == .hwb) maybePreferLongHexHwbResult(ctx, out);
        return out;
    }

    if (color_arg.kind() != .string or color_arg.stringQuoted(ctx.string_flags_pool.items)) return error.BuiltinType;
    const source = parseLabLikeFallbackXyz(ctx.intern_pool.get(color_arg.stringIntern())) orelse return error.BuiltinType;
    const converted = color_mod.convert(source, target_space);

    if (target_space == .srgb and target_spec.legacy_rgb_alias) {
        const r255 = converted.channels[0] * 255.0;
        const g255 = converted.channels[1] * 255.0;
        const b255 = converted.channels[2] * 255.0;
        const out_of_gamut = !std.math.isFinite(r255) or !std.math.isFinite(g255) or !std.math.isFinite(b255) or
            r255 < -1e-10 or r255 > 255.0 + 1e-10 or
            g255 < -1e-10 or g255 > 255.0 + 1e-10 or
            b255 < -1e-10 or b255 > 255.0 + 1e-10;
        if (out_of_gamut) {
            const hsl = color_mod.convert(source, .hsl);
            return colorValueFromDeclaredColor(
                ctx,
                color_mod.Color.init(hsl.channels[0], hsl.channels[1], hsl.channels[2], converted.channels[3], .hsl),
                .hsl,
                0,
                true,
            );
        }
        const rgb = color_mod.Color.init(r255 / 255.0, g255 / 255.0, b255 / 255.0, converted.channels[3], .srgb);
        const out = try colorValueFromDeclaredColor(ctx, rgb, .srgb, 0, true);
        maybePreferLongHexResult(ctx, out, true);
        return out;
    }

    const lab_tol = 1e-10;
    if ((target_space == .lab and (converted.channels[0] < -lab_tol or converted.channels[0] > 100.0 + lab_tol)) or
        (target_space == .lch and (converted.channels[0] < -lab_tol or converted.channels[0] > 100.0 + lab_tol)) or
        (target_space == .oklab and (converted.channels[0] < -lab_tol or converted.channels[0] > 1.0 + lab_tol)) or
        (target_space == .oklch and (converted.channels[0] < -lab_tol or converted.channels[0] > 1.0 + lab_tol)))
    {
        return serializeLabLikeOutOfRange(ctx, converted, target_space);
    }

    const target_legacy = switch (target_space) {
        .srgb => target_spec.legacy_rgb_alias,
        .hsl, .hwb => true,
        else => false,
    };
    const out = try colorValueFromDeclaredColor(ctx, converted, target_space, 0, target_legacy);
    if (target_spec.legacy_rgb_alias) maybePreferLongHexResult(ctx, out, true);
    if (target_space == .hwb) maybePreferLongHexHwbResult(ctx, out);
    return out;
}

const ColorOpTestHarness = struct {
    allocator: std.mem.Allocator,
    intern_pool: shared.InternPool,
    list_pool: std.ArrayListUnmanaged([]Value),
    color_pool: value_mod.ColorPool,
    number_pool: value_mod.NumberPool,
    callable_payload_pool: value_mod.CallablePayloadPool,
    list_meta_pool: value_mod.ListMetaPool,
    string_flags_pool: value_mod.StringFlagsPool,
    deprecation_opts: deprecation_mod.DeprecationOpts,
    random_state: u64,

    fn init(allocator: std.mem.Allocator) !ColorOpTestHarness {
        return .{
            .allocator = allocator,
            .intern_pool = try shared.InternPool.init(allocator),
            .list_pool = .empty,
            .color_pool = .empty,
            .number_pool = .empty,
            .callable_payload_pool = .empty,
            .list_meta_pool = .empty,
            .string_flags_pool = .empty,
            .deprecation_opts = .{ .quiet = true },
            .random_state = 0x5eedc0de,
        };
    }

    fn context(self: *ColorOpTestHarness) BuiltinContext {
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
            // The color builtins under test never dispatch through `vm`.
            // Use a non-null bogus address to make any accidental deref
            // crash loudly instead of silently dereferencing a misaligned
            // `&u8` -- which is what the older `dummy_vm: u8` field did.
            .vm = @ptrFromInt(0xdead_beef),
            .deprecation_opts = &self.deprecation_opts,
        };
    }

    fn deinit(self: *ColorOpTestHarness) void {
        for (self.list_pool.items) |items| self.allocator.free(items);
        self.list_pool.deinit(self.allocator);
        self.color_pool.deinit(self.allocator);
        self.number_pool.deinit(self.allocator);
        self.callable_payload_pool.deinit(self.allocator);
        self.list_meta_pool.deinit(self.allocator);
        self.string_flags_pool.deinit(self.allocator);
        self.intern_pool.deinit(self.allocator);
    }

    fn intern(self: *ColorOpTestHarness, text: []const u8) !InternId {
        return self.intern_pool.intern(text);
    }

    fn legacyHex(self: *ColorOpTestHarness, r: u8, g: u8, b: u8) !Value {
        const handle = try value_mod.pushColorEntry(&self.color_pool, self.allocator, .{
            .channels = .{
                @as(f64, @floatFromInt(r)) / 255.0,
                @as(f64, @floatFromInt(g)) / 255.0,
                @as(f64, @floatFromInt(b)) / 255.0,
                1.0,
            },
            .space = .srgb,
            .missing = 0,
            .legacy = true,
        });
        return Value.colorWithHandle(handle);
    }

    fn legacyHsl(self: *ColorOpTestHarness, h: f64, s: f64, l: f64, alpha: f64) !Value {
        const handle = try value_mod.pushColorEntry(&self.color_pool, self.allocator, .{
            .channels = .{ h, s, l, alpha },
            .space = .hsl,
            .missing = 0,
            .legacy = true,
        });
        return Value.colorWithHandle(handle);
    }

    fn legacyHwb(self: *ColorOpTestHarness, h: f64, w: f64, b: f64, alpha: f64) !Value {
        const handle = try value_mod.pushColorEntry(&self.color_pool, self.allocator, .{
            .channels = .{ h, w, b, alpha },
            .space = .hwb,
            .missing = 0,
            .legacy = true,
        });
        return Value.colorWithHandle(handle);
    }
};

test "color.scale scales legacy red channel by percentage" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const arg_names = [_]InternId{ .none, try h.intern("red") };
    const args = [_]Value{
        try h.legacyHex(0xab, 0xcd, 0xef),
        try Value.number(10.0, try h.intern("%"), &h.number_pool, h.allocator),
    };

    const out = try color_scale(&ctx, args[0..], arg_names[0..]);
    try std.testing.expectEqual(.color, out.kind());
    const entry = out.colorEntry(&h.color_pool);
    try std.testing.expectApproxEqAbs(@as(f64, 179.4 / 255.0), entry.channels[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0xcd) / 255.0, entry.channels[1], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0xef) / 255.0, entry.channels[2], 1e-12);
}

test "color.scale hue channel semantic failure is SassError" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const arg_names = [_]InternId{ .none, try h.intern("hue") };
    const args = [_]Value{
        try h.legacyHex(0xff, 0x00, 0x00),
        Value.numberUnitless(10.0),
    };

    try std.testing.expectError(error.SassError, color_scale(&ctx, args[0..], arg_names[0..]));
}

test "color.adjust adds legacy red channel delta" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const arg_names = [_]InternId{ .none, try h.intern("red") };
    const args = [_]Value{
        try h.legacyHex(0xab, 0xcd, 0xef),
        Value.numberUnitless(10.0),
    };

    const out = try color_adjust(&ctx, args[0..], arg_names[0..]);
    try std.testing.expectEqual(.color, out.kind());
    const entry = out.colorEntry(&h.color_pool);
    try std.testing.expectApproxEqAbs(@as(f64, 181.0 / 255.0), entry.channels[0], 1e-12);
}

test "color.adjust srgb result prefers long hex when channels are shortenable" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const arg_names = [_]InternId{ .none, try h.intern("alpha") };
    const args = [_]Value{
        try h.legacyHex(0x66, 0x66, 0x66),
        Value.numberUnitless(0.0),
    };

    const out = try color_adjust(&ctx, args[0..], arg_names[0..]);
    const entry = out.colorEntry(&h.color_pool);
    try std.testing.expect(entry.prefer_long_hex);
}

test "color.adjust generated hsl out-of-gamut result returns to srgb when in gamut" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const percent = try h.intern("%");
    const arg_names = [_]InternId{ .none, try h.intern("lightness") };
    const first_args = [_]Value{
        try h.legacyHex(0x16, 0x16, 0x16),
        try Value.number(84.0, percent, &h.number_pool, h.allocator),
    };
    const first = try color_adjust(&ctx, first_args[0..], arg_names[0..]);

    const second_args = [_]Value{ first, try Value.number(10.0, percent, &h.number_pool, h.allocator) };
    const second = try color_adjust(&ctx, second_args[0..], arg_names[0..]);
    try std.testing.expectEqual(color_mod.ColorSpace.hsl, second.colorEntry(&h.color_pool).space);

    const third_args = [_]Value{ second, try Value.number(-30.0, percent, &h.number_pool, h.allocator) };
    const third = try color_adjust(&ctx, third_args[0..], arg_names[0..]);
    try std.testing.expectEqual(color_mod.ColorSpace.srgb, third.colorEntry(&h.color_pool).space);
    try std.testing.expectApproxEqAbs(@as(f64, 185.2 / 255.0), third.colorEntry(&h.color_pool).channels[0], 1e-9);
}

test "color.change overwrites legacy red channel" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const arg_names = [_]InternId{ .none, try h.intern("red") };
    const args = [_]Value{
        try h.legacyHex(0xab, 0xcd, 0xef),
        Value.numberUnitless(10.0),
    };

    const out = try color_change(&ctx, args[0..], arg_names[0..]);
    try std.testing.expectEqual(.color, out.kind());
    const entry = out.colorEntry(&h.color_pool);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0 / 255.0), entry.channels[0], 1e-12);
}

test "color.lighten keeps fractional legacy channels" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const args = [_]Value{
        try h.legacyHex(0xff, 0x00, 0x00),
        Value.numberUnitless(14.0),
    };

    const out = try color_lighten(&ctx, args[0..]);
    try std.testing.expectEqual(.color, out.kind());
    const entry = out.colorEntry(&h.color_pool);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), entry.channels[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 71.4 / 255.0), entry.channels[1], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 71.4 / 255.0), entry.channels[2], 1e-9);
    try std.testing.expect(entry.legacy);
}

test "color.lighten preserves hsl-family legacy surface" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const amount = try Value.number(18.0, try h.intern("%"), &h.number_pool, h.allocator);
    const hsl_out = try color_lighten(&ctx, &.{
        try h.legacyHsl(210.0, 15.0, 16.0, 1.0),
        amount,
    });
    const hsl_css = try valueToCssString(&ctx, hsl_out);
    defer h.allocator.free(hsl_css);
    try std.testing.expectEqualStrings("hsl(210, 15%, 34%)", hsl_css);

    const hwb_out = try color_lighten(&ctx, &.{
        try h.legacyHwb(200.0, 20.0, 30.0, 1.0),
        try Value.number(10.0, try h.intern("%"), &h.number_pool, h.allocator),
    });
    const hwb_css = try valueToCssString(&ctx, hwb_out);
    defer h.allocator.free(hwb_css);
    try std.testing.expectEqualStrings("hsl(200, 55.5555555556%, 55%)", hwb_css);
}

test "color.lighten coerces unquoted hex string literal" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const amount = try Value.number(15.0, try h.intern("%"), &h.number_pool, h.allocator);
    const expected = try color_lighten(&ctx, &.{
        try h.legacyHex(0xee, 0x6e, 0x73),
        amount,
    });
    const actual = try color_lighten(&ctx, &.{
        Value.string(try h.intern("#ee6e73"), false),
        amount,
    });

    const expected_entry = expected.colorEntry(&h.color_pool);
    const actual_entry = actual.colorEntry(&h.color_pool);
    try std.testing.expectApproxEqAbs(expected_entry.channels[0], actual_entry.channels[0], 1e-12);
    try std.testing.expectApproxEqAbs(expected_entry.channels[1], actual_entry.channels[1], 1e-12);
    try std.testing.expectApproxEqAbs(expected_entry.channels[2], actual_entry.channels[2], 1e-12);
    try std.testing.expectApproxEqAbs(expected_entry.channels[3], actual_entry.channels[3], 1e-12);
    try std.testing.expect(actual_entry.legacy);
}

test "color.opacify rejects amount above one without percent normalization" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const rgba = try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 1.0, 0.0, 0.0, 0.5 },
        .space = .srgb,
        .missing = 0,
        .legacy = true,
    });
    const args = [_]Value{
        Value.colorWithHandle(rgba),
        Value.numberUnitless(1.001),
    };
    try std.testing.expectError(error.BuiltinType, color_opacify(&ctx, args[0..]));
}

test "color.opacify treats percent amount as raw bounds-checked number" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const pct = try h.intern("%");
    const args = [_]Value{
        try h.legacyHex(0xff, 0x00, 0x00),
        try Value.number(50.0, pct, &h.number_pool, h.allocator),
    };
    try std.testing.expectError(error.BuiltinType, color_opacify(&ctx, args[0..]));
}

test "color.transparentize treats percent amount as raw bounds-checked number" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const pct = try h.intern("%");
    const args = [_]Value{
        try h.legacyHex(0xff, 0x00, 0x00),
        try Value.number(50.0, pct, &h.number_pool, h.allocator),
    };
    try std.testing.expectError(error.BuiltinType, color_transparentize(&ctx, args[0..]));
}

test "color alpha adjust preserves hsl-family legacy surface" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const opacified = try color_opacify(&ctx, &.{
        try h.legacyHsl(195.0, 30.0, 90.0, 0.2),
        Value.numberUnitless(0.3),
    });
    const opacified_css = try valueToCssString(&ctx, opacified);
    defer h.allocator.free(opacified_css);
    try std.testing.expectEqualStrings("hsla(195, 30%, 90%, 0.5)", opacified_css);

    const transparent = try color_transparentize(&ctx, &.{
        try h.legacyHwb(200.0, 20.0, 30.0, 1.0),
        Value.numberUnitless(0.5),
    });
    const transparent_css = try valueToCssString(&ctx, transparent);
    defer h.allocator.free(transparent_css);
    try std.testing.expectEqualStrings("hsla(200, 55.5555555556%, 45%, 0.5)", transparent_css);
}

test "color.rgb user-facing failures are SassError" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const args = [_]Value{Value.numberUnitless(1.0)};
    try std.testing.expectError(error.SassError, color_rgb(&ctx, args[0..], &.{}));
}

test "color.hsl user-facing arity failures are SassError" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    try std.testing.expectError(error.SassError, color_hsl(&ctx, &.{}, &.{}));
}

test "color.color user-facing type failures are SassError" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const args = [_]Value{Value.numberUnitless(1.0)};
    try std.testing.expectError(error.SassError, color_color(&ctx, args[0..], &.{}));
}

test "color.mix user-facing type failures are SassError" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const args = [_]Value{
        Value.numberUnitless(1.0),
        Value.numberUnitless(2.0),
    };
    try std.testing.expectError(error.SassError, color_mix(&ctx, args[0..], &.{}));
}

test "legacy mix exact integer colors prefer long hex" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const percent = try h.intern("%");
    const args = [_]Value{
        try h.legacyHex(0x88, 0x88, 0x88),
        try h.legacyHex(0x00, 0x00, 0x00),
        try Value.number(25.0, percent, &h.number_pool, h.allocator),
    };

    const out = try color_mix(&ctx, args[0..], &.{});
    const css = try valueToCssString(&ctx, out);
    defer h.allocator.free(css);
    try std.testing.expectEqualStrings("#222222", css);
}

test "color.invert accepts calculation-like non-color passthrough values" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const calc_like = Value.string(try h.intern("calc(1 + 2)"), false);
    const args = [_]Value{calc_like};
    const out = try color_invert(&ctx, args[0..], &.{});
    try std.testing.expectEqual(.string, out.kind());
}

test "color.grayscale preserves missing lightness in legacy hsl as modern syntax" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const handle = try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 30.0, 40.0, 0.0, 1.0 },
        .space = .hsl,
        .missing = 0x4,
        .legacy = true,
    });
    const args = [_]Value{Value.colorWithHandle(handle)};
    const out = try color_grayscale(&ctx, args[0..]);
    try std.testing.expectEqual(.color, out.kind());
    const entry = out.colorEntry(&h.color_pool);
    try std.testing.expectEqual(color_mod.ColorSpace.hsl, entry.space);
    try std.testing.expectEqual(@as(ColorMissingMask, 0x4), entry.missing & 0x4);
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), entry.channels[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), entry.channels[1], 1e-12);
    try std.testing.expect(!entry.legacy);
}

test "color.complement explicit hsl rejects powerless legacy hue" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const args = [_]Value{
        try h.legacyHex(0x80, 0x80, 0x80),
        Value.string(try h.intern("hsl"), false),
    };
    try std.testing.expectError(error.SassError, color_complement(&ctx, args[0..], &.{ .none, .none }));
}

test "color.complement implicit legacy hsl keeps missing lightness" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const handle = try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 0.0, 50.0, 0.0, 1.0 },
        .space = .hsl,
        .missing = 0x4,
        .legacy = true,
    });
    const args = [_]Value{Value.colorWithHandle(handle)};
    const out = try color_complement(&ctx, args[0..], &.{.none});
    try std.testing.expectEqual(.color, out.kind());
    const entry = out.colorEntry(&h.color_pool);
    try std.testing.expectEqual(color_mod.ColorSpace.hsl, entry.space);
    try std.testing.expectEqual(@as(ColorMissingMask, 0x4), entry.missing & 0x4);
    try std.testing.expectApproxEqAbs(@as(f64, 180.0), normalizeHue(entry.channels[0]), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), entry.channels[1], 1e-12);
    try std.testing.expect(!entry.legacy);
}

test "color.to-space maps hsl target to legacy serialization mode" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const handle = try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 0.42, 0.07, 270.0, 0.8 },
        .space = .lch,
        .missing = 0,
        .legacy = false,
    });
    const source = Value.colorWithHandle(handle);
    const args = [_]Value{
        source,
        Value.string(try h.intern("hsl"), false),
    };

    const out = try color_to_space(&ctx, args[0..], &.{
        .none,
        .none,
    });
    try std.testing.expectEqual(.color, out.kind());
    const entry = out.colorEntry(&h.color_pool);
    try std.testing.expectEqual(color_mod.ColorSpace.hsl, entry.space);
    try std.testing.expect(entry.legacy);
}

test "color.to-space keeps srgb modern unless explicit rgb alias" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const legacy = try h.legacyHex(0x0a, 0x14, 0x1e);

    const modern_args = [_]Value{
        legacy,
        Value.string(try h.intern("srgb"), false),
    };
    const modern_out = try color_to_space(&ctx, modern_args[0..], &.{ .none, .none });
    try std.testing.expectEqual(.color, modern_out.kind());
    const modern_entry = modern_out.colorEntry(&h.color_pool);
    try std.testing.expectEqual(color_mod.ColorSpace.srgb, modern_entry.space);
    try std.testing.expect(!modern_entry.legacy);

    const legacy_args = [_]Value{
        legacy,
        Value.string(try h.intern("rgb"), false),
    };
    const legacy_out = try color_to_space(&ctx, legacy_args[0..], &.{ .none, .none });
    try std.testing.expectEqual(.color, legacy_out.kind());
    const legacy_entry = legacy_out.colorEntry(&h.color_pool);
    try std.testing.expectEqual(color_mod.ColorSpace.srgb, legacy_entry.space);
    try std.testing.expect(legacy_entry.legacy);
}

test "color.to-space rgb alias preserves missing rgb() function channels" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const source = try color_rgb(&ctx, &.{
        Value.string(try h.intern("none"), false),
        Value.numberUnitless(0.1),
        Value.numberUnitless(0.2),
    }, &.{ .none, .none, .none });
    const args = [_]Value{
        source,
        Value.string(try h.intern("rgb"), false),
    };

    const out = try color_to_space(&ctx, args[0..], &.{ .none, .none });
    const css = try valueToCssString(&ctx, out);
    defer ctx.allocator.free(css);
    try std.testing.expectEqualStrings("rgb(none 0.1 0.2)", css);
}

test "color.to-space rgb alias zero-fills modern srgb missing channels even when byte-like" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const handle = try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 10.0 / 255.0, 20.0 / 255.0, 30.0 / 255.0, 1.0 },
        .space = .srgb,
        .missing = 0x1,
        .legacy = false,
    });
    const args = [_]Value{
        Value.colorWithHandle(handle),
        Value.string(try h.intern("rgb"), false),
    };

    const out = try color_to_space(&ctx, args[0..], &.{ .none, .none });
    const css = try valueToCssString(&ctx, out);
    defer ctx.allocator.free(css);
    try std.testing.expectEqualStrings("rgb(0, 20, 30)", css);
}

test "color.to-space rgb alias zero-fills non-byte-like modern missing channels" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const handle = try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 0.2, 0.41, 0.63, 1.0 },
        .space = .srgb,
        .missing = 0x1,
        .legacy = false,
    });
    const args = [_]Value{
        Value.colorWithHandle(handle),
        Value.string(try h.intern("rgb"), false),
    };

    const out = try color_to_space(&ctx, args[0..], &.{ .none, .none });
    try std.testing.expectEqual(.color, out.kind());
    const entry = out.colorEntry(&h.color_pool);
    try std.testing.expectEqual(color_mod.ColorSpace.srgb, entry.space);
    try std.testing.expect(entry.legacy);
    try std.testing.expectEqual(@as(ColorMissingMask, 0), entry.missing & 0x7);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), entry.channels[0], 1e-12);
}

test "color.to-space hsl target with missing hue keeps modern serialization" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const handle = try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 0.0, 20.0, 30.0, 1.0 },
        .space = .hsl,
        .missing = 0x1,
        .legacy = true,
    });
    const args = [_]Value{
        Value.colorWithHandle(handle),
        Value.string(try h.intern("hsl"), false),
    };

    const out = try color_to_space(&ctx, args[0..], &.{ .none, .none });
    try std.testing.expectEqual(.color, out.kind());
    const entry = out.colorEntry(&h.color_pool);
    try std.testing.expectEqual(color_mod.ColorSpace.hsl, entry.space);
    try std.testing.expect(!entry.legacy);
    try std.testing.expectEqual(@as(ColorMissingMask, 0x1), entry.missing & 0x1);
}

test "color.to-space zeroes missing lch hue for legacy hsl targets" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const handle = try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 0.1, 0.1, 30.0, 1.0 },
        .space = .oklch,
        .missing = 0x4,
        .legacy = false,
    });
    const out = try color_to_space(&ctx, &.{
        Value.colorWithHandle(handle),
        Value.string(try h.intern("hsl"), false),
    }, &.{ .none, .none });
    const css = try valueToCssString(&ctx, out);
    defer ctx.allocator.free(css);
    try std.testing.expect(std.mem.startsWith(u8, css, "hsl(0, "));
    try std.testing.expect(std.mem.find(u8, css, "none") == null);
}

test "color.to-space zeroes missing lab-like lightness for legacy hsl targets" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const handle = try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 0.0, 0.1, 30.0, 1.0 },
        .space = .oklch,
        .missing = 0x1,
        .legacy = false,
    });
    const out = try color_to_space(&ctx, &.{
        Value.colorWithHandle(handle),
        Value.string(try h.intern("hsl"), false),
    }, &.{ .none, .none });
    const css = try valueToCssString(&ctx, out);
    defer ctx.allocator.free(css);
    try std.testing.expectEqualStrings("hsl(221.7487198664, 266.6061126985%, 0%)", css);
}

test "color.to-space propagates missing hsl saturation to lch hue" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const handle = try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 30.0, 0.0, 40.0, 1.0 },
        .space = .hsl,
        .missing = 0x2,
        .legacy = true,
    });
    const out = try color_to_space(&ctx, &.{
        Value.colorWithHandle(handle),
        Value.string(try h.intern("lch"), false),
    }, &.{ .none, .none });
    const css = try valueToCssString(&ctx, out);
    defer ctx.allocator.free(css);
    try std.testing.expect(std.mem.endsWith(u8, css, "% none none)"));
}

test "color.to-space converts oklch white through regular hsl path" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const handle = try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 1.0, 0.0, 0.0, 1.0 },
        .space = .oklch,
        .missing = 0,
        .legacy = false,
    });
    const out = try color_to_space(&ctx, &.{
        Value.colorWithHandle(handle),
        Value.string(try h.intern("hsl"), false),
    }, &.{ .none, .none });
    const css = try valueToCssString(&ctx, out);
    defer ctx.allocator.free(css);
    try std.testing.expectEqualStrings("hsl(161.8181818182, 266.6666666667%, 100%)", css);
}

test "color.to-space converts prophoto white through regular hsl path" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const handle = try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 1.0, 1.0, 1.0, 1.0 },
        .space = .prophoto_rgb,
        .missing = 0,
        .legacy = false,
    });
    const out = try color_to_space(&ctx, &.{
        Value.colorWithHandle(handle),
        Value.string(try h.intern("hsl"), false),
    }, &.{ .none, .none });
    const css = try valueToCssString(&ctx, out);
    defer ctx.allocator.free(css);
    try std.testing.expectEqualStrings("hsl(180, 50%, 100%)", css);
}

test "color.to-space rgb alias prefers long hex output" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const handle = try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 0.2, 0.4, 0.8, 1.0 },
        .space = .srgb,
        .missing = 0,
        .legacy = false,
    });
    const out = try color_to_space(&ctx, &.{
        Value.colorWithHandle(handle),
        Value.string(try h.intern("rgb"), false),
    }, &.{ .none, .none });
    const css = try valueToCssString(&ctx, out);
    defer ctx.allocator.free(css);
    try std.testing.expectEqualStrings("#3366cc", css);
}

test "color.to-space rgb alias preserves legacy srgb source spelling" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const cases = [_]struct {
        repr: value_mod.InspectColorRepr,
        channels: [4]f64,
        expected: []const u8,
    }{
        .{ .repr = .literal_long_hex, .channels = .{ 1.0, 1.0, 1.0, 1.0 }, .expected = "#ffffff" },
        .{ .repr = .literal_short_hex, .channels = .{ 1.0, 1.0, 1.0, 1.0 }, .expected = "#fff" },
        .{ .repr = .literal_long_hex, .channels = .{ 1.0, 0.0, 0.0, 1.0 }, .expected = "#ff0000" },
        .{ .repr = .legacy_rgb_function, .channels = .{ 1.0, 1.0, 1.0, 1.0 }, .expected = "rgb(255, 255, 255)" },
    };

    for (cases) |case| {
        const handle = try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
            .channels = case.channels,
            .space = .srgb,
            .missing = 0,
            .legacy = true,
            .inspect_repr = case.repr,
        });
        const out = try color_to_space(&ctx, &.{
            Value.colorWithHandle(handle),
            Value.string(try h.intern("rgb"), false),
        }, &.{ .none, .none });
        const css = try valueToCssString(&ctx, out);
        defer ctx.allocator.free(css);
        try std.testing.expectEqualStrings(case.expected, css);
    }
}

test "color.to-space hwb target prefers long hex output" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const handle = try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 0.2, 0.4, 0.8, 1.0 },
        .space = .srgb,
        .missing = 0,
        .legacy = false,
    });
    const out = try color_to_space(&ctx, &.{
        Value.colorWithHandle(handle),
        Value.string(try h.intern("hwb"), false),
    }, &.{ .none, .none });
    const css = try valueToCssString(&ctx, out);
    defer ctx.allocator.free(css);
    try std.testing.expectEqualStrings("#3366cc", css);
}

test "color.to-space lab out-of-range emits color-mix fallback string" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const handle = try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 1.0, 1.0, 1.0, 1.0 },
        .space = .xyz_d65,
        .missing = 0,
        .legacy = false,
    });
    const args = [_]Value{
        Value.colorWithHandle(handle),
        Value.string(try h.intern("lab"), false),
    };

    const out = try color_to_space(&ctx, args[0..], &.{ .none, .none });
    try std.testing.expectEqual(.string, out.kind());
    try std.testing.expect(!out.stringQuoted(ctx.string_flags_pool.items));
    const css = h.intern_pool.get(out.stringIntern());
    try std.testing.expect(std.mem.startsWith(u8, css, "color-mix(in lab, color(xyz "));
}

test "color.to-space rgb alias emits hsl entry for out-of-gamut rgb" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const handle = try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 1.2, 0.8, -0.4, 1.0 },
        .space = .xyz_d65,
        .missing = 0,
        .legacy = false,
    });
    const args = [_]Value{
        Value.colorWithHandle(handle),
        Value.string(try h.intern("rgb"), false),
    };

    const out = try color_to_space(&ctx, args[0..], &.{ .none, .none });
    try std.testing.expectEqual(.color, out.kind());
    const entry = out.colorEntry(&h.color_pool);
    try std.testing.expectEqual(color_mod.ColorSpace.hsl, entry.space);
    try std.testing.expect(entry.legacy);
}

test "color.rgb keeps legacy mode when rgb channels are missing" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const none = Value.string(try h.intern("none"), false);
    const args = [_]Value{ none, none, none };
    const out = try color_rgb(&ctx, args[0..], &.{ .none, .none, .none });
    try std.testing.expectEqual(.color, out.kind());
    const entry = out.colorEntry(&h.color_pool);
    try std.testing.expectEqual(color_mod.ColorSpace.srgb, entry.space);
    try std.testing.expect(entry.legacy);
    try std.testing.expectEqual(@as(ColorMissingMask, 0x7), entry.missing & 0x7);
}

test "color.change legacy hsl via hwb clears missing hue on output" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const handle = try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 100.0, 50.0, 50.0, 1.0 },
        .space = .hsl,
        .missing = 0,
        .legacy = true,
    });
    const args = [_]Value{
        Value.colorWithHandle(handle),
        Value.string(try h.intern("none"), false),
        Value.string(try h.intern("hwb"), false),
    };
    const out = try color_change(&ctx, args[0..], &.{ .none, try h.intern("hue"), try h.intern("space") });
    try std.testing.expectEqual(.color, out.kind());
    const entry = out.colorEntry(&h.color_pool);
    try std.testing.expectEqual(color_mod.ColorSpace.hsl, entry.space);
    try std.testing.expect(entry.legacy);
    try std.testing.expectEqual(@as(ColorMissingMask, 0), entry.missing & 0x1);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), entry.channels[0], 1e-12);
}

test "color.to-gamut local-minde clears missing channels when mapping occurs" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const handle = try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 0.0, 1.2, 0.0, 1.0 },
        .space = .srgb,
        .missing = 0x5,
        .legacy = false,
    });
    const args = [_]Value{
        Value.colorWithHandle(handle),
        Value.nil_v,
        Value.string(try h.intern("local-minde"), false),
    };
    const out = try color_to_gamut(&ctx, args[0..], &.{ .none, .none, .none });
    try std.testing.expectEqual(.color, out.kind());
    const entry = out.colorEntry(&h.color_pool);
    try std.testing.expectEqual(color_mod.ColorSpace.srgb, entry.space);
    try std.testing.expectEqual(@as(ColorMissingMask, 0), entry.missing & 0x7);
}

test "color.to-gamut explicit srgb target keeps legacy powerless hsl concrete" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const srgb = try h.intern("srgb");
    const clip = try h.intern("clip");
    const local_minde = try h.intern("local-minde");

    const gray = Value.colorWithHandle(try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 0.0, 0.0, 20.0, 1.0 },
        .space = .hsl,
        .missing = 0,
        .legacy = true,
    }));
    const white = Value.colorWithHandle(try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 0.0, 10.0, 1000.0, 1.0 },
        .space = .hsl,
        .missing = 0,
        .legacy = true,
    }));

    const clip_out = try color_to_gamut(&ctx, &.{ gray, Value.string(srgb, false), Value.string(clip, false) }, &.{ .none, .none, .none });
    const clip_css = try valueToCssString(&ctx, clip_out);
    defer ctx.allocator.free(clip_css);
    try std.testing.expectEqualStrings("hsl(0, 0%, 20%)", clip_css);

    const local_out = try color_to_gamut(&ctx, &.{ white, Value.string(srgb, false), Value.string(local_minde, false) }, &.{ .none, .none, .none });
    const local_css = try valueToCssString(&ctx, local_out);
    defer ctx.allocator.free(local_css);
    try std.testing.expectEqualStrings("hsl(0, 0%, 100%)", local_css);
}

test "color.channel preserves fractional hwb channels" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const handle = try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 0.123, 0.456, 0.789, 1.0 },
        .space = .srgb,
        .missing = 0,
        .legacy = false,
    });
    const color_v = Value.colorWithHandle(handle);
    const expected_hwb = color_mod.convert(localChannelColor(&ctx, color_v), .hwb);

    const hue = try getColorChannel(&ctx, color_v, "hue", .hwb, false);
    const white = try getColorChannel(&ctx, color_v, "whiteness", .hwb, false);

    try std.testing.expectEqual(.number, hue.kind());
    try std.testing.expectEqual(.number, white.kind());
    try std.testing.expectApproxEqAbs(expected_hwb.channels[0], hue.asF64(ctx.number_pool), 1e-10);
    try std.testing.expectApproxEqAbs(expected_hwb.channels[1], white.asF64(ctx.number_pool), 1e-10);
}

test "color.channel zeroes mapped missing hue in target space" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const handle = try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 50.0, 20.0, 270.0, 1.0 },
        .space = .lch,
        .missing = 0x4,
        .legacy = false,
    });
    const out = try color_channel(&ctx, &.{
        Value.colorWithHandle(handle),
        Value.string(try h.intern("hue"), true),
        Value.string(try h.intern("oklch"), false),
    }, &.{ .none, .none, .none });
    try std.testing.expectEqual(.number, out.kind());
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), out.asF64(ctx.number_pool), 1e-12);
    try std.testing.expectEqualStrings("deg", h.intern_pool.get(out.unitId(ctx.number_pool)));
}

test "color.channel zeroes derived missing lch channels" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const handle = try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 30.0, 0.0, 40.0, 1.0 },
        .space = .hsl,
        .missing = 0x2,
        .legacy = false,
    });
    const hue = try color_channel(&ctx, &.{
        Value.colorWithHandle(handle),
        Value.string(try h.intern("hue"), true),
        Value.string(try h.intern("lch"), false),
    }, &.{ .none, .none, .none });
    const chroma = try color_channel(&ctx, &.{
        Value.colorWithHandle(handle),
        Value.string(try h.intern("chroma"), true),
        Value.string(try h.intern("lch"), false),
    }, &.{ .none, .none, .none });
    try std.testing.expectEqual(.number, hue.kind());
    try std.testing.expectEqual(.number, chroma.kind());
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), hue.asF64(ctx.number_pool), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), chroma.asF64(ctx.number_pool), 1e-12);
    try std.testing.expectEqualStrings("deg", h.intern_pool.get(hue.unitId(ctx.number_pool)));
}

test "color.same treats polar missing hue as zero" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const missing_hue = Value.colorWithHandle(try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 50.0, 20.0, 270.0, 1.0 },
        .space = .lch,
        .missing = 0x4,
        .legacy = false,
    }));
    const zero_hue = Value.colorWithHandle(try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 50.0, 20.0, 0.0, 1.0 },
        .space = .lch,
        .missing = 0,
        .legacy = false,
    }));

    const out = try color_same(&ctx, &.{ missing_hue, zero_hue }, &.{ .none, .none });
    try std.testing.expectEqual(Value.true_v.kind(), out.kind());
    try std.testing.expect(out.isTruthy());
}

test "color.lab parses inline slash alpha-none in third slot text" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const pct = try h.intern("%");
    const inline_token = Value.string(try h.intern("3 / none"), false);
    const list_items = try h.allocator.dupe(Value, &.{
        try Value.number(1.0, pct, &h.number_pool, h.allocator),
        Value.numberUnitless(2.0),
        inline_token,
    });
    const list_handle: u32 = @intCast(h.list_pool.items.len);
    try h.list_pool.append(h.allocator, list_items);

    const args = [_]Value{Value.listWithSpace(list_handle, false)};
    const out = try color_lab(&ctx, args[0..], &.{.none});
    try std.testing.expectEqual(.color, out.kind());
    const entry = out.colorEntry(&h.color_pool);
    try std.testing.expectEqual(color_mod.ColorSpace.lab, entry.space);
    try std.testing.expectEqual(@as(ColorMissingMask, 0x8), entry.missing & 0x8);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), entry.channels[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), entry.channels[1], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), entry.channels[2], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), entry.channels[3], 1e-12);
}

test "color.lch parses inline slash hue-none in third slot text" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const pct = try h.intern("%");
    const inline_token = Value.string(try h.intern("none / 0.4"), false);
    const list_items = try h.allocator.dupe(Value, &.{
        try Value.number(1.0, pct, &h.number_pool, h.allocator),
        Value.numberUnitless(2.0),
        inline_token,
    });
    const list_handle: u32 = @intCast(h.list_pool.items.len);
    try h.list_pool.append(h.allocator, list_items);

    const args = [_]Value{Value.listWithSpace(list_handle, false)};
    const out = try color_lch(&ctx, args[0..], &.{.none});
    try std.testing.expectEqual(.color, out.kind());
    const entry = out.colorEntry(&h.color_pool);
    try std.testing.expectEqual(color_mod.ColorSpace.lch, entry.space);
    try std.testing.expectEqual(@as(ColorMissingMask, 0x4), entry.missing & 0x4);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), entry.channels[3], 1e-12);
}

test "color.lab parses inline slash calc nan alpha as zero" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const pct = try h.intern("%");
    const inline_token = Value.string(try h.intern("-3 / calc(NaN)"), false);
    const list_items = try h.allocator.dupe(Value, &.{
        try Value.number(1.0, pct, &h.number_pool, h.allocator),
        Value.numberUnitless(2.0),
        inline_token,
    });
    const list_handle: u32 = @intCast(h.list_pool.items.len);
    try h.list_pool.append(h.allocator, list_items);

    const args = [_]Value{Value.listWithSpace(list_handle, false)};
    const out = try color_lab(&ctx, args[0..], &.{.none});
    try std.testing.expectEqual(.color, out.kind());
    const entry = out.colorEntry(&h.color_pool);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), entry.channels[3], 1e-12);
}

test "color.hwb requires percent units for whiteness/blackness" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const args = [_]Value{
        Value.numberUnitless(0.0),
        Value.numberUnitless(30.0),
        try Value.number(40.0, try h.intern("%"), &h.number_pool, h.allocator),
        Value.numberUnitless(0.5),
    };
    try std.testing.expectError(error.SassError, color_hwb(&ctx, args[0..], &.{ .none, .none, .none, .none }));
}

test "color.channel invalid channel name is an error" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const args = [_]Value{
        try h.legacyHex(0xaa, 0xbb, 0xcc),
        Value.string(try h.intern("Red"), false),
    };
    try std.testing.expectError(error.BuiltinType, color_channel(&ctx, args[0..], &.{ .none, .none }));
}

test "color.channel returns zero for missing rgb channel" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const source = try color_rgb(&ctx, &.{
        Value.string(try h.intern("none"), false),
        Value.numberUnitless(0.0),
        Value.numberUnitless(0.0),
    }, &.{ .none, .none, .none });
    const out = try color_channel(&ctx, &.{
        source,
        Value.string(try h.intern("red"), true),
        Value.string(try h.intern("rgb"), false),
    }, &.{ .none, .none, try h.intern("space") });
    try std.testing.expectEqual(.number, out.kind());
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), out.asF64(ctx.number_pool), 1e-12);
}

test "color.channel coerces unquoted hex string literal" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const expected = try color_channel(&ctx, &.{
        try h.legacyHex(0xee, 0x6e, 0x73),
        Value.string(try h.intern("red"), true),
    }, &.{ .none, .none });
    const actual = try color_channel(&ctx, &.{
        Value.string(try h.intern("#ee6e73"), false),
        Value.string(try h.intern("red"), true),
    }, &.{ .none, .none });

    try std.testing.expectEqual(.number, actual.kind());
    try std.testing.expectApproxEqAbs(expected.asF64(ctx.number_pool), actual.asF64(ctx.number_pool), 1e-12);
}

test "color.channel accepts calc-marker-preserved unquoted space name" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const out = try color_channel(&ctx, &.{
        try h.legacyHex(0xaa, 0xbb, 0xcc),
        Value.string(try h.intern("red"), true),
        Value.string(try h.intern("\x01zsass-calc-arg:rgb"), false),
    }, &.{ .none, .none, try h.intern("space") });

    try std.testing.expectEqual(.number, out.kind());
    try std.testing.expectApproxEqAbs(@as(f64, 170.0), out.asF64(ctx.number_pool), 1e-12);
}

test "color.channel returns zero for projected missing lch hue" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const pct = try h.intern("%");
    const deg = try h.intern("deg");
    const source = try color_hsl(&ctx, &.{
        try Value.number(30.0, deg, &h.number_pool, h.allocator),
        Value.string(try h.intern("none"), false),
        try Value.number(40.0, pct, &h.number_pool, h.allocator),
    }, &.{ .none, .none, .none });
    const projected = try color_to_space(&ctx, &.{
        source,
        Value.string(try h.intern("lch"), false),
    }, &.{ .none, .none });
    const out = try color_channel(&ctx, &.{
        projected,
        Value.string(try h.intern("hue"), true),
    }, &.{ .none, .none });
    try std.testing.expectEqual(.number, out.kind());
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), out.asF64(ctx.number_pool), 1e-12);
    try std.testing.expectEqualStrings("deg", h.intern_pool.get(out.unitId(ctx.number_pool)));
}

test "color.same treats missing channels as zero" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const left = try color_rgb(&ctx, &.{
        Value.string(try h.intern("none"), false),
        Value.numberUnitless(0.0),
        Value.numberUnitless(0.0),
    }, &.{ .none, .none, .none });
    const right = try color_rgb(&ctx, &.{
        Value.numberUnitless(0.0),
        Value.numberUnitless(0.0),
        Value.numberUnitless(0.0),
    }, &.{ .none, .none, .none });
    const out = try color_same(&ctx, &.{ left, right }, &.{ .none, .none });
    try std.testing.expectEqual(Value.true_v, out);
}

test "color.red rejects non-legacy colors" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const handle = try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 0.1, 0.2, 0.3, 1.0 },
        .space = .display_p3,
        .missing = 0,
        .legacy = false,
    });
    const args = [_]Value{Value.colorWithHandle(handle)};
    try std.testing.expectError(error.BuiltinType, color_red(&ctx, args[0..]));
}

test "color.hsl one-arg fallback with three channels uses comma form" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const pct = try h.intern("%");
    const channels_items = try h.allocator.dupe(Value, &.{
        Value.string(try h.intern("var(--foo)"), false),
        try Value.number(2.0, pct, &h.number_pool, h.allocator),
        try Value.number(3.0, pct, &h.number_pool, h.allocator),
    });
    const channels_handle: u32 = @intCast(h.list_pool.items.len);
    try h.list_pool.append(h.allocator, channels_items);

    const slash_items = try h.allocator.dupe(Value, &.{
        Value.listWithSpace(channels_handle, false),
        Value.numberUnitless(0.4),
    });
    const slash_handle: u32 = @intCast(h.list_pool.items.len);
    try h.list_pool.append(h.allocator, slash_items);

    const args = [_]Value{Value.listWithSlash(slash_handle, false)};
    const out = try color_hsl(&ctx, args[0..], &.{.none});
    try std.testing.expectEqual(.string, out.kind());
    try std.testing.expectEqualStrings("hsl(var(--foo), 2%, 3%, 0.4)", h.intern_pool.get(out.stringIntern()));
}

test "color.hsl one-arg fallback preserves slash without spaces for multi-arg var" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const pct = try h.intern("%");
    const tail_items = try h.allocator.dupe(Value, &.{
        try Value.number(50.0, pct, &h.number_pool, h.allocator),
        Value.numberUnitless(0.4),
    });
    const tail_handle: u32 = @intCast(h.list_pool.items.len);
    try h.list_pool.append(h.allocator, tail_items);

    const channels_items = try h.allocator.dupe(Value, &.{
        Value.string(try h.intern("var(--foo)"), false),
        Value.listWithSlash(tail_handle, false),
    });
    const channels_handle: u32 = @intCast(h.list_pool.items.len);
    try h.list_pool.append(h.allocator, channels_items);

    const args = [_]Value{Value.listWithSpace(channels_handle, false)};
    const out = try color_hsl(&ctx, args[0..], &.{.none});
    try std.testing.expectEqual(.string, out.kind());
    try std.testing.expectEqualStrings("hsl(var(--foo) 50%/0.4)", h.intern_pool.get(out.stringIntern()));
}

test "color.lab one-arg fallback keeps spaced slash for top-level slash lists" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const channels_items = try h.allocator.dupe(Value, &.{
        Value.string(try h.intern("var(--foo)"), false),
        Value.numberUnitless(10.0),
        Value.numberUnitless(20.0),
    });
    const channels_handle: u32 = @intCast(h.list_pool.items.len);
    try h.list_pool.append(h.allocator, channels_items);

    const slash_items = try h.allocator.dupe(Value, &.{
        Value.listWithSpace(channels_handle, false),
        Value.numberUnitless(0.4),
    });
    const slash_handle: u32 = @intCast(h.list_pool.items.len);
    try h.list_pool.append(h.allocator, slash_items);

    const args = [_]Value{Value.listWithSlash(slash_handle, false)};
    const out = try color_lab(&ctx, args[0..], &.{.none});
    try std.testing.expectEqual(.string, out.kind());
    try std.testing.expectEqualStrings("lab(var(--foo) 10 20 / 0.4)", h.intern_pool.get(out.stringIntern()));
}

test "color.lab one-arg fallback preserves compact slash for inline tail slash list" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const tail_items = try h.allocator.dupe(Value, &.{
        Value.numberUnitless(20.0),
        Value.numberUnitless(0.4),
    });
    const tail_handle: u32 = @intCast(h.list_pool.items.len);
    try h.list_pool.append(h.allocator, tail_items);

    const channels_items = try h.allocator.dupe(Value, &.{
        Value.string(try h.intern("var(--foo)"), false),
        Value.numberUnitless(10.0),
        Value.listWithSlash(tail_handle, false),
    });
    const channels_handle: u32 = @intCast(h.list_pool.items.len);
    try h.list_pool.append(h.allocator, channels_items);

    const args = [_]Value{Value.listWithSpace(channels_handle, false)};
    const out = try color_lab(&ctx, args[0..], &.{.none});
    try std.testing.expectEqual(.string, out.kind());
    try std.testing.expectEqualStrings("lab(var(--foo) 10 20/0.4)", h.intern_pool.get(out.stringIntern()));
}

test "color.rgb clamps non-finite calc alpha" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const args = [_]Value{
        Value.numberUnitless(0.0),
        Value.numberUnitless(0.0),
        Value.numberUnitless(0.0),
        Value.string(try h.intern("calc(infinity * 1%)"), false),
    };
    const out = try color_rgb(&ctx, args[0..], &.{ .none, .none, .none, .none });
    try std.testing.expectEqual(.color, out.kind());
    const css = try valueToCssString(&ctx, out);
    defer h.allocator.free(css);
    try std.testing.expectEqualStrings("rgb(0, 0, 0)", css);
}

test "color.rgb clamps non-finite calc channels" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const args = [_]Value{
        Value.string(try h.intern("calc(infinity * 1%)"), false),
        Value.numberUnitless(0.0),
        Value.numberUnitless(0.0),
        Value.numberUnitless(0.5),
    };
    const out = try color_rgb(&ctx, args[0..], &.{ .none, .none, .none, .none });
    try std.testing.expectEqual(.color, out.kind());
    const css = try valueToCssString(&ctx, out);
    defer h.allocator.free(css);
    try std.testing.expectEqualStrings("rgba(255, 0, 0, 0.5)", css);
}

test "color.hwb uses legacy degenerate passthrough for non-finite whiteness" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const pct = try h.intern("%");
    const args = [_]Value{
        Value.numberUnitless(0.0),
        Value.string(try h.intern("calc(infinity * 1%)"), false),
        try Value.number(40.0, pct, &h.number_pool, h.allocator),
        Value.numberUnitless(0.5),
    };
    const out = try color_hwb(&ctx, args[0..], &.{ .none, .none, .none, .none });
    try std.testing.expectEqual(.string, out.kind());
    try std.testing.expectEqualStrings("hsla(calc(NaN), calc(NaN * 1%), calc(NaN * 1%), 0.5)", h.intern_pool.get(out.stringIntern()));
}

test "color.color splits inline slash text for explicit alpha" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const list_items = try h.allocator.dupe(Value, &.{
        Value.string(try h.intern("srgb"), false),
        Value.numberUnitless(0.0),
        Value.numberUnitless(0.0),
        Value.string(try h.intern("calc(-infinity) / 0.5"), false),
    });
    const handle: u32 = @intCast(h.list_pool.items.len);
    try h.list_pool.append(h.allocator, list_items);

    const out = try color_color(&ctx, &.{Value.listWithSpace(handle, false)}, &.{.none});
    const css = try valueToCssString(&ctx, out);
    defer ctx.allocator.free(css);
    try std.testing.expectEqualStrings("color(srgb 0 0 calc(-infinity) / 0.5)", css);
}

test "color.hsl keeps NaN lightness as calc percent" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const pct = try h.intern("%");
    const out = try color_hsl(&ctx, &.{
        Value.numberUnitless(0.0),
        try Value.number(100.0, pct, &h.number_pool, h.allocator),
        Value.numberUnitless(std.math.nan(f64)),
    }, &.{ .none, .none, .none });
    const css = try valueToCssString(&ctx, out);
    defer ctx.allocator.free(css);
    try std.testing.expectEqualStrings("hsl(0, 100%, calc(NaN * 1%))", css);
}

test "color.hsl keeps infinite saturation as calc percent" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const pct = try h.intern("%");
    const out = try color_hsl(&ctx, &.{
        Value.numberUnitless(0.0),
        Value.numberUnitless(std.math.inf(f64)),
        try Value.number(50.0, pct, &h.number_pool, h.allocator),
    }, &.{ .none, .none, .none });
    const css = try valueToCssString(&ctx, out);
    defer ctx.allocator.free(css);
    try std.testing.expectEqualStrings("hsl(0, calc(infinity * 1%), 50%)", css);
}

test "color.hsl marks missing-channel results as modern syntax" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const pct = try h.intern("%");
    const args = [_]Value{
        Value.string(try h.intern("none"), false),
        try Value.number(100.0, pct, &h.number_pool, h.allocator),
        try Value.number(50.0, pct, &h.number_pool, h.allocator),
    };
    const out = try color_hsl(&ctx, args[0..], &.{ .none, .none, .none });
    try std.testing.expectEqual(.color, out.kind());
    const entry = out.colorEntry(&h.color_pool);
    try std.testing.expect(!entry.legacy);
    try std.testing.expect((entry.missing & 0x1) != 0);
}

test "color.hwb marks missing-channel results as modern syntax" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const pct = try h.intern("%");
    const args = [_]Value{
        Value.numberUnitless(0.0),
        Value.string(try h.intern("none"), false),
        try Value.number(40.0, pct, &h.number_pool, h.allocator),
    };
    const out = try color_hwb(&ctx, args[0..], &.{ .none, .none, .none });
    try std.testing.expectEqual(.color, out.kind());
    const entry = out.colorEntry(&h.color_pool);
    try std.testing.expect(!entry.legacy);
    try std.testing.expect((entry.missing & 0x2) != 0);
}

test "color.adjust-hue converts angle units to degrees" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const rad = try h.intern("rad");
    const args = [_]Value{
        try h.legacyHex(0xff, 0x00, 0x00),
        try Value.number(60.0, rad, &h.number_pool, h.allocator),
    };
    const out = try color_adjust_hue(&ctx, args[0..]);
    const css = try valueToCssString(&ctx, out);
    defer ctx.allocator.free(css);
    try std.testing.expectEqualStrings("rgb(0, 179.576224164, 255)", css);
}

test "color.alpha named-argument filter fallback emits alpha() text" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const args = [_]Value{
        Value.string(try h.intern("d"), false),
        Value.string(try h.intern("f"), false),
    };
    const names = [_]InternId{
        try h.intern("c"),
        try h.intern("e"),
    };
    const out = try color_alpha(&ctx, args[0..], names[0..]);
    try std.testing.expectEqual(.string, out.kind());
    try std.testing.expectEqualStrings("alpha(c=d, e=f)", h.intern_pool.get(out.stringIntern()));
}

test "color.alpha positional filter fallback emits alpha() text for multiple args" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const args = [_]Value{
        Value.string(try h.intern("c=d"), false),
        Value.string(try h.intern("e=f"), false),
        Value.string(try h.intern("g=h"), false),
    };
    const out = try color_alpha(&ctx, args[0..], &.{ .none, .none, .none });
    try std.testing.expectEqual(.string, out.kind());
    try std.testing.expectEqualStrings("alpha(c=d, e=f, g=h)", h.intern_pool.get(out.stringIntern()));
}

test "global alpha positional filter fallback emits alpha() text for multiple args" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const args = [_]Value{
        Value.string(try h.intern("c=d"), false),
        Value.string(try h.intern("e=f"), false),
        Value.string(try h.intern("g=h"), false),
    };
    const out = try global_alpha(&ctx, args[0..], &.{ .none, .none, .none });
    try std.testing.expectEqual(.string, out.kind());
    try std.testing.expectEqualStrings("alpha(c=d, e=f, g=h)", h.intern_pool.get(out.stringIntern()));
}

test "color.rgb preserves calc string arguments via fallback" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const args = [_]Value{
        Value.string(try h.intern("calc(1)"), false),
        Value.numberUnitless(2.0),
        Value.numberUnitless(3.0),
    };
    const out = try color_rgb(&ctx, args[0..], &.{ .none, .none, .none });
    try std.testing.expectEqual(.string, out.kind());
    try std.testing.expectEqualStrings("rgb(calc(1), 2, 3)", h.intern_pool.get(out.stringIntern()));
}

test "color.hsl preserves calc string alpha via fallback" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const pct = try h.intern("%");
    const args = [_]Value{
        Value.numberUnitless(1.0),
        try Value.number(2.0, pct, &h.number_pool, h.allocator),
        try Value.number(3.0, pct, &h.number_pool, h.allocator),
        Value.string(try h.intern("calc(0.4)"), false),
    };
    const out = try color_hsl(&ctx, args[0..], &.{ .none, .none, .none, .none });
    try std.testing.expectEqual(.string, out.kind());
    try std.testing.expectEqualStrings("hsl(1, 2%, 3%, calc(0.4))", h.intern_pool.get(out.stringIntern()));
}

test "global opacity simplifies unquoted calc strings" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const args = [_]Value{Value.string(try h.intern("calc(1 + 2)"), false)};
    const out = try global_opacity(&ctx, args[0..], &.{.none});
    try std.testing.expectEqual(.string, out.kind());
    try std.testing.expectEqualStrings("opacity(3)", h.intern_pool.get(out.stringIntern()));
}

test "color.color rejects space-separated fourth srgb channel" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const list_items = try h.allocator.dupe(Value, &.{
        Value.string(try h.intern("srgb"), false),
        Value.numberUnitless(0.1),
        Value.numberUnitless(0.2),
        Value.numberUnitless(0.3),
        Value.numberUnitless(0.4),
    });
    const handle: u32 = @intCast(h.list_pool.items.len);
    try h.list_pool.append(h.allocator, list_items);

    try std.testing.expectError(error.SassError, color_color(&ctx, &.{Value.listWithSpace(handle, false)}, &.{.none}));
}

test "color.invert explicit hsl preserves missing output syntax" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const handle = try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 30.0, 0.0, 40.0, 1.0 },
        .space = .hsl,
        .missing = 0x2,
        .legacy = false,
    });
    const args = [_]Value{
        Value.colorWithHandle(handle),
        Value.string(try h.intern("hsl"), false),
    };
    const names = [_]InternId{ .none, try h.intern("space") };
    const out = try color_invert(&ctx, args[0..], names[0..]);
    const css = try valueToCssString(&ctx, out);
    defer ctx.allocator.free(css);
    try std.testing.expectEqualStrings("hsl(210deg none 60%)", css);
}

test "color.invert explicit hwb prefers long hex when fully resolved" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const handle = try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 30.0, 20.0, 40.0, 1.0 },
        .space = .hwb,
        .missing = 0,
        .legacy = true,
    });
    const args = [_]Value{
        Value.colorWithHandle(handle),
        Value.string(try h.intern("hwb"), false),
    };
    const names = [_]InternId{ .none, try h.intern("space") };
    const out = try color_invert(&ctx, args[0..], names[0..]);
    const css = try valueToCssString(&ctx, out);
    defer ctx.allocator.free(css);
    try std.testing.expectEqualStrings("#6699cc", css);
}

test "color.invert legacy srgb prefers long hex" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const args = [_]Value{
        try h.legacyHex(0x66, 0x33, 0x99),
    };

    const out = try color_invert(&ctx, args[0..], &.{});
    const css = try valueToCssString(&ctx, out);
    defer ctx.allocator.free(css);
    try std.testing.expectEqualStrings("#99cc66", css);
}

test "color.to-space srgb keeps color function syntax for missing modern srgb" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const handle = try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 10.0 / 255.0, 20.0 / 255.0, 30.0 / 255.0, 1.0 },
        .space = .srgb,
        .missing = 0x1,
        .legacy = true,
    });
    const args = [_]Value{
        Value.colorWithHandle(handle),
        Value.string(try h.intern("srgb"), false),
    };
    const out = try color_to_space(&ctx, args[0..], &.{ .none, .none });
    const css = try valueToCssString(&ctx, out);
    defer ctx.allocator.free(css);
    try std.testing.expectEqualStrings("color(srgb none 0.0784313725 0.1176470588)", css);
}

test "color.space returns srgb for modern srgb values" {
    var h = try ColorOpTestHarness.init(std.testing.allocator);
    defer h.deinit();
    var ctx = h.context();

    const modern_handle = try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 0.1, 0.2, 0.3, 1.0 },
        .space = .srgb,
        .missing = 0,
        .legacy = false,
    });
    const modern_args = [_]Value{Value.colorWithHandle(modern_handle)};
    const modern = try color_space(&ctx, modern_args[0..], &.{.none});
    try std.testing.expectEqual(.string, modern.kind());
    try std.testing.expectEqualStrings("srgb", h.intern_pool.get(modern.stringIntern()));

    const legacy_handle = try value_mod.pushColorEntry(&h.color_pool, h.allocator, .{
        .channels = .{ 0.1, 0.2, 0.3, 1.0 },
        .space = .srgb,
        .missing = 0,
        .legacy = true,
    });
    const legacy_args = [_]Value{Value.colorWithHandle(legacy_handle)};
    const legacy = try color_space(&ctx, legacy_args[0..], &.{.none});
    try std.testing.expectEqual(.string, legacy.kind());
    try std.testing.expectEqualStrings("rgb", h.intern_pool.get(legacy.stringIntern()));
}
