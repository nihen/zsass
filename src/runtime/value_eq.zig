const std = @import("std");
const color_mod = @import("../color/color.zig");
const value_mod = @import("value.zig");
const intern_pool_mod = @import("intern_pool.zig");
const calc_utils = @import("calc_utils.zig");
const units = @import("units.zig");

pub const Value = value_mod.Value;
const ColorPool = value_mod.ColorPool;
const InternPool = intern_pool_mod.InternPool;

const ComparableString = struct {
    bytes: []const u8,
    owned: ?[]u8 = null,

    fn deinit(self: ComparableString, alloc: std.mem.Allocator) void {
        if (self.owned) |buf| alloc.free(buf);
    }
};

fn unescapeSassString(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.find(u8, text, "\\") == null) return text;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\\' and i + 1 < text.len) {
            const next = text[i + 1];
            if (next == '\\') {
                try buf.append(allocator, '\\');
                i += 2;
            } else if (next == '"' or next == '\'') {
                try buf.append(allocator, next);
                i += 2;
            } else if (std.ascii.isHex(next)) {
                const hex_start = i + 1;
                var hex_end = hex_start;
                while (hex_end < text.len and hex_end - hex_start < 6 and std.ascii.isHex(text[hex_end])) {
                    hex_end += 1;
                }
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
                i += 2;
            } else if (next == '\r') {
                i += 2;
                if (i < text.len and text[i] == '\n') {
                    i += 1;
                }
            } else {
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

fn comparableStringBytes(pool: *InternPool, alloc: std.mem.Allocator, v: Value) ComparableString {
    const raw = calc_utils.stripCalcArgMarker(pool.get(v.stringIntern()));
    if (!v.stringQuoted(value_mod.empty_string_flags_pool)) {
        return .{ .bytes = raw };
    }
    if (!pool.hasBackslash(v.stringIntern())) {
        return .{ .bytes = raw };
    }
    const decoded = unescapeSassString(alloc, raw) catch return .{ .bytes = raw };
    if (decoded.ptr == raw.ptr) return .{ .bytes = raw };
    return .{
        .bytes = decoded,
        .owned = @constCast(decoded),
    };
}

fn comparableStringsEqualFast(pool: *InternPool, a: Value, b: Value) ?bool {
    const raw_a = calc_utils.stripCalcArgMarker(pool.get(a.stringIntern()));
    const raw_b = calc_utils.stripCalcArgMarker(pool.get(b.stringIntern()));
    if ((!a.stringQuoted(value_mod.empty_string_flags_pool) and std.mem.indexOf(u8, raw_a, "calc(") != null) or
        (!b.stringQuoted(value_mod.empty_string_flags_pool) and std.mem.indexOf(u8, raw_b, "calc(") != null))
        return null;

    // Unquoted strings compare as raw text. Quoted strings without escapes also
    // compare as raw text; only quoted backslash escapes need the slower decode
    // path below. This is hot in large map/list equality checks where many
    // distinct InternIds carry identical simple string bytes.
    const a_needs_decode = a.stringQuoted(value_mod.empty_string_flags_pool) and pool.hasBackslash(a.stringIntern());
    const b_needs_decode = b.stringQuoted(value_mod.empty_string_flags_pool) and pool.hasBackslash(b.stringIntern());
    if (a_needs_decode or b_needs_decode) return null;
    if (raw_a.len != raw_b.len) return false;
    return std.mem.eql(u8, raw_a, raw_b);
}

fn normalizedCalcStringEqual(alloc: std.mem.Allocator, raw_a: []const u8, raw_b: []const u8) ?bool {
    if (std.mem.indexOf(u8, raw_a, "calc(") == null and std.mem.indexOf(u8, raw_b, "calc(") == null) return null;
    const norm_a = calc_utils.normalizeCalcInDeclValueForMarkedInterpolation(alloc, raw_a) catch return null;
    defer if (!calc_utils.sameSliceStorage(norm_a, raw_a)) alloc.free(norm_a);
    const norm_b = calc_utils.normalizeCalcInDeclValueForMarkedInterpolation(alloc, raw_b) catch return null;
    defer if (!calc_utils.sameSliceStorage(norm_b, raw_b)) alloc.free(norm_b);
    return std.mem.eql(u8, norm_a, norm_b);
}

const convertComparableUnitValueRuntime = units.convertComparableUnitCi;

fn numberEq(pool: *InternPool, number_pool: *value_mod.NumberPool, a: Value, b: Value) bool {
    std.debug.assert(a.kind() == .number and b.kind() == .number);
    const ua = a.unitId(number_pool);
    const ub = b.unitId(number_pool);
    if (ua == ub) {
        return std.math.approxEqAbs(f64, a.asF64(number_pool), b.asF64(number_pool), 1e-11);
    }
    if (ua == .none or ub == .none) return false;

    const ua_text = pool.get(ua);
    const ub_text = pool.get(ub);
    if (convertComparableUnitValueRuntime(b.asF64(number_pool), ub_text, ua_text)) |converted| {
        return std.math.approxEqAbs(f64, a.asF64(number_pool), converted, 1e-9);
    }
    if (convertComparableUnitValueRuntime(a.asF64(number_pool), ua_text, ub_text)) |converted| {
        return std.math.approxEqAbs(f64, converted, b.asF64(number_pool), 1e-9);
    }
    return false;
}

fn colorEqApprox(color_pool: *const ColorPool, a: Value, b: Value) bool {
    std.debug.assert(a.kind() == .color and b.kind() == .color);
    const ae = a.colorEntry(color_pool);
    const be = b.colorEntry(color_pool);

    if (ae.space == be.space) {
        if (ae.missing != be.missing) return false;
        return std.math.approxEqAbs(f64, ae.channels[0], be.channels[0], 1e-6) and
            std.math.approxEqAbs(f64, ae.channels[1], be.channels[1], 1e-6) and
            std.math.approxEqAbs(f64, ae.channels[2], be.channels[2], 1e-6) and
            std.math.approxEqAbs(f64, ae.channels[3], be.channels[3], 1e-6);
    }

    if (value_mod.isLegacyColorSpace(ae.space) and value_mod.isLegacyColorSpace(be.space)) {
        const a0 = if ((ae.missing & 0x1) != 0) 0.0 else ae.channels[0];
        const a1 = if ((ae.missing & 0x2) != 0) 0.0 else ae.channels[1];
        const a2 = if ((ae.missing & 0x4) != 0) 0.0 else ae.channels[2];
        const a3 = if ((ae.missing & 0x8) != 0) 0.0 else ae.channels[3];
        const b0 = if ((be.missing & 0x1) != 0) 0.0 else be.channels[0];
        const b1 = if ((be.missing & 0x2) != 0) 0.0 else be.channels[1];
        const b2 = if ((be.missing & 0x4) != 0) 0.0 else be.channels[2];
        const b3 = if ((be.missing & 0x8) != 0) 0.0 else be.channels[3];
        const ca = color_mod.Color.init(
            a0,
            a1,
            a2,
            a3,
            ae.space,
        );
        const cb = color_mod.Color.init(
            b0,
            b1,
            b2,
            b3,
            be.space,
        );
        const as = if (ae.space == .srgb) ca else color_mod.convert(ca, .srgb);
        const bs = if (be.space == .srgb) cb else color_mod.convert(cb, .srgb);
        return std.math.approxEqAbs(f64, as.channels[0], bs.channels[0], 1e-6) and
            std.math.approxEqAbs(f64, as.channels[1], bs.channels[1], 1e-6) and
            std.math.approxEqAbs(f64, as.channels[2], bs.channels[2], 1e-6) and
            std.math.approxEqAbs(f64, as.channels[3], bs.channels[3], 1e-6);
    }

    return false;
}

fn namedColorLiteralEqColor(pool: *InternPool, color_pool: *const ColorPool, named: Value, color_value: Value) bool {
    std.debug.assert(named.kind() == .string and color_value.kind() == .color);
    if (!named.stringNamedColorLiteral(value_mod.empty_string_flags_pool) or named.stringQuoted(value_mod.empty_string_flags_pool)) return false;
    const raw_name = calc_utils.stripCalcArgMarker(pool.get(named.stringIntern()));
    const parsed = color_mod.lookupNamedColor(raw_name) orelse return false;

    const lhs = color_mod.Color.init(
        parsed.r / 255.0,
        parsed.g / 255.0,
        parsed.b / 255.0,
        parsed.a,
        .srgb,
    );

    const entry = color_value.colorEntry(color_pool);
    const c0 = if ((entry.missing & 0x1) != 0) 0.0 else entry.channels[0];
    const c1 = if ((entry.missing & 0x2) != 0) 0.0 else entry.channels[1];
    const c2 = if ((entry.missing & 0x4) != 0) 0.0 else entry.channels[2];
    const c3 = if ((entry.missing & 0x8) != 0) 0.0 else entry.channels[3];
    const rhs_src = color_mod.Color.init(c0, c1, c2, c3, entry.space);
    const rhs = if (entry.space == .srgb) rhs_src else color_mod.convert(rhs_src, .srgb);

    return std.math.approxEqAbs(f64, lhs.channels[0], rhs.channels[0], 1e-6) and
        std.math.approxEqAbs(f64, lhs.channels[1], rhs.channels[1], 1e-6) and
        std.math.approxEqAbs(f64, lhs.channels[2], rhs.channels[2], 1e-6) and
        std.math.approxEqAbs(f64, lhs.channels[3], rhs.channels[3], 1e-6);
}

fn mapListsEqual(env: anytype, a_items: []const Value, b_items: []const Value) bool {
    if (a_items.len != b_items.len or (a_items.len % 2) != 0) return false;
    var i: usize = 0;
    while (i + 1 < a_items.len) : (i += 2) {
        var found = false;
        var j: usize = 0;
        while (j + 1 < b_items.len) : (j += 2) {
            if (valueEqInner(env, a_items[i], b_items[j]) and valueEqInner(env, a_items[i + 1], b_items[j + 1])) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn valueEqInner(env: anytype, a: Value, b: Value) bool {
    if (a.kind() != b.kind()) {
        if (a.kind() == .string and b.kind() == .color) {
            const color_pool = env.colorPool() orelse return false;
            return namedColorLiteralEqColor(env.pool(), color_pool, a, b);
        }
        if (a.kind() == .color and b.kind() == .string) {
            const color_pool = env.colorPool() orelse return false;
            return namedColorLiteralEqColor(env.pool(), color_pool, b, a);
        }
        return false;
    }
    if (a.isNumber()) return numberEq(env.pool(), env.numberPool(), a, b);

    if (a.isString()) {
        if (a.stringNamedColorLiteral(env.stringFlagsPool().items) != b.stringNamedColorLiteral(env.stringFlagsPool().items)) return false;
        if (a.stringIntern() == b.stringIntern()) return true;
        if (comparableStringsEqualFast(env.pool(), a, b)) |fast| return fast;
        const ca = comparableStringBytes(env.pool(), env.allocator(), a);
        defer ca.deinit(env.allocator());
        const cb = comparableStringBytes(env.pool(), env.allocator(), b);
        defer cb.deinit(env.allocator());
        if (!a.stringQuoted(env.stringFlagsPool().items) and !b.stringQuoted(env.stringFlagsPool().items)) {
            if (normalizedCalcStringEqual(env.allocator(), ca.bytes, cb.bytes)) |eq| return eq;
        }
        return std.mem.eql(u8, ca.bytes, cb.bytes);
    }

    if (a.kind() == .boolean) return a.p64Of() == b.p64Of();
    if (a.kind() == .nil) return true;

    if (a.kind() == .color) {
        const color_pool = env.colorPool() orelse return false;
        return colorEqApprox(color_pool, a, b);
    }

    if (a.kind() == .list) {
        const a_items = env.getStaticList(a.listHandle()) orelse return false;
        const b_items = env.getStaticList(b.listHandle()) orelse return false;

        const lmp = env.listMetaPool().items;
        if (a.listBracketed(lmp) != b.listBracketed(lmp)) return false;
        if (a_items.len == 0 and b_items.len == 0) return true;

        if (a.listIsMap(lmp) or b.listIsMap(lmp)) {
            if (!(a.listIsMap(lmp) and b.listIsMap(lmp))) return false;
            return mapListsEqual(env, a_items, b_items);
        }

        if (a_items.len != b_items.len) return false;
        if (a_items.len > 1 and a.listSeparator(lmp) != b.listSeparator(lmp)) return false;
        for (a_items, b_items) |lhs, rhs| {
            if (!valueEqInner(env, lhs, rhs)) return false;
        }
        return true;
    }

    if (a.kind() == .calc_fragment or a.kind() == .interp_fragment) return a.p64Of() == b.p64Of();

    if (a.kind() == .callable) {
        if (a.callableIsMixin(env.callablePayloadPool()) != b.callableIsMixin(env.callablePayloadPool())) return false;
        if (a.callableIsBuiltin(env.callablePayloadPool()) != b.callableIsBuiltin(env.callablePayloadPool())) return false;
        if (a.callableIsCss(env.callablePayloadPool()) != b.callableIsCss(env.callablePayloadPool())) return false;
        if (a.callableHandle(env.callablePayloadPool()) != b.callableHandle(env.callablePayloadPool())) return false;
        if (a.callableIsCss(env.callablePayloadPool()) and a.callableNameIntern(env.callablePayloadPool()) != b.callableNameIntern(env.callablePayloadPool())) return false;
        if (!a.callableIsBuiltin(env.callablePayloadPool()) and (a.callableHasModule(env.callablePayloadPool()) or b.callableHasModule(env.callablePayloadPool())) and
            a.callableModuleId(env.callablePayloadPool()) != b.callableModuleId(env.callablePayloadPool())) return false;
        return true;
    }

    return false;
}

pub fn valueEqEnv(env: anytype, a: Value, b: Value) bool {
    return valueEqInner(env, a, b);
}
