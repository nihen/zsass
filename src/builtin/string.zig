//! sass:string builtins.
const std = @import("std");
const shared = @import("shared.zig");
const css_utils = @import("../runtime/css_utils.zig");

const Value = shared.Value;
const BuiltinContext = shared.BuiltinContext;
const BuiltinError = shared.BuiltinError;
const InternId = shared.InternId;

const badArity = shared.badArity;
const expectArity = shared.expectArity;
const internString = shared.internString;
const valueToCssString = shared.valueToCssString;
const bindNamedOrPositionalArgsStrict = shared.bindNamedOrPositionalArgsStrict;
const reportArgumentTypeMismatch = shared.reportArgumentTypeMismatch;

var unique_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

const DecodedString = struct {
    bytes: []const u8,
    needs_free: bool = false,

    fn deinit(self: DecodedString, alloc: std.mem.Allocator) void {
        if (self.needs_free) {
            alloc.free(@constCast(self.bytes));
        }
    }
};

fn unescapeStringForStringOps(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
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
                const raw_code_point = std.fmt.parseInt(u21, text[hex_start..hex_end], 16) catch {
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
                if (i < text.len and text[i] == '\n') i += 1;
            } else {
                try buf.append(allocator, '\\');
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

fn decodeQuotedStringForOps(ctx: *BuiltinContext, value: Value) BuiltinError!DecodedString {
    if (!value.isString()) return error.BuiltinType;
    const raw = ctx.intern_pool.get(value.stringIntern());
    if (!value.stringQuoted(ctx.string_flags_pool.items)) {
        if (std.mem.find(u8, raw, "\\") == null) {
            return .{ .bytes = raw };
        }
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(ctx.allocator);

        var changed = false;
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] != '\\') {
                try buf.append(ctx.allocator, raw[i]);
                i += 1;
                continue;
            }

            if (i + 1 >= raw.len) {
                try buf.append(ctx.allocator, '\\');
                break;
            }
            i += 1;

            if (std.ascii.isHex(raw[i])) {
                var value_cp: u21 = 0;
                var count: u32 = 0;
                while (i < raw.len and count < 6 and std.ascii.isHex(raw[i])) : (count += 1) {
                    value_cp = value_cp * 16 + css_utils.hexDigitValue(raw[i]);
                    i += 1;
                }
                if (i < raw.len and (raw[i] == ' ' or raw[i] == '\t' or raw[i] == '\n' or raw[i] == '\r' or raw[i] == '\x0c')) {
                    i += 1;
                }

                if (value_cp == 0 or value_cp <= 0x1F or value_cp == 0x7F) {
                    try buf.append(ctx.allocator, '\\');
                    var hex_buf: [6]u8 = undefined;
                    const hex = std.fmt.bufPrint(&hex_buf, "{x}", .{value_cp}) catch "0";
                    try buf.appendSlice(ctx.allocator, hex);
                    try buf.append(ctx.allocator, ' ');
                } else if (value_cp > 0x10FFFF) {
                    try buf.appendSlice(ctx.allocator, "\xEF\xBF\xBD");
                    changed = true;
                } else {
                    var utf8_buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(@intCast(value_cp), &utf8_buf) catch 0;
                    try buf.appendSlice(ctx.allocator, utf8_buf[0..len]);
                    changed = true;
                }
                continue;
            }

            if (raw[i] == '\r') {
                i += 1;
                if (i < raw.len and raw[i] == '\n') i += 1;
                changed = true;
                continue;
            }
            if (raw[i] == '\n' or raw[i] == '\x0c') {
                i += 1;
                changed = true;
                continue;
            }

            if (raw[i] == '/') {
                try buf.append(ctx.allocator, '\\');
                try buf.append(ctx.allocator, raw[i]);
            } else if (raw[i] == '"' or raw[i] == '\'' or raw[i] == '\\') {
                try buf.append(ctx.allocator, '\\');
                try buf.append(ctx.allocator, raw[i]);
            } else {
                try buf.append(ctx.allocator, raw[i]);
                changed = true;
            }
            i += 1;
        }

        if (!changed and std.mem.eql(u8, buf.items, raw)) {
            buf.deinit(ctx.allocator);
            return .{ .bytes = raw };
        }
        const decoded = try buf.toOwnedSlice(ctx.allocator);
        if (decoded.ptr == raw.ptr) {
            return .{ .bytes = raw };
        }
        return .{
            .bytes = decoded,
            .needs_free = true,
        };
    }
    if (std.mem.find(u8, raw, "\\") == null) {
        return .{ .bytes = raw };
    }
    const decoded = unescapeStringForStringOps(ctx.allocator, raw) catch return error.OutOfMemory;
    if (decoded.ptr == raw.ptr) {
        return .{ .bytes = raw };
    }
    return .{
        .bytes = decoded,
        .needs_free = true,
    };
}

fn decodeStringArgForOps(ctx: *BuiltinContext, param_name: []const u8, value: Value) BuiltinError!DecodedString {
    if (!value.isString()) return reportArgumentTypeMismatch(ctx, param_name, value, "string");
    return decodeQuotedStringForOps(ctx, value) catch |err| switch (err) {
        error.BuiltinType => return reportArgumentTypeMismatch(ctx, param_name, value, "string"),
        else => return err,
    };
}

fn pushListWithMeta(
    ctx: *BuiltinContext,
    items: []const Value,
    separator: shared.ListSeparator,
    bracketed: bool,
) BuiltinError!Value {
    return shared.pushListWithMeta(ctx, items, separator, bracketed, false);
}

fn isHexEscapeDelimiterWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0c';
}

fn normalizeHexEscapesForQuotedOutput(alloc: std.mem.Allocator, raw: []const u8) BuiltinError!?[]u8 {
    if (std.mem.find(u8, raw, "\\") == null) return null;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    var changed = false;
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c == '\\' and i + 1 < raw.len and std.ascii.isHex(raw[i + 1])) {
            try out.append(alloc, '\\');
            i += 1;

            var digits: usize = 0;
            while (i < raw.len and digits < 6 and std.ascii.isHex(raw[i])) : (digits += 1) {
                try out.append(alloc, raw[i]);
                i += 1;
            }

            if (i < raw.len and isHexEscapeDelimiterWhitespace(raw[i])) {
                try out.append(alloc, raw[i]);
                i += 1;
            } else {
                const needs_delimiter = i == raw.len or std.ascii.isHex(raw[i]) or raw[i] == '"' or raw[i] == '\'';
                if (needs_delimiter) {
                    try out.append(alloc, ' ');
                    changed = true;
                }
            }
            continue;
        }

        try out.append(alloc, c);
        i += 1;
    }

    if (!changed) return null;
    return out.toOwnedSlice(alloc) catch error.OutOfMemory;
}

fn quotedUnquoteShouldPreserveRawEscapes(raw: []const u8) bool {
    var i: usize = 0;
    while (i + 1 < raw.len) : (i += 1) {
        if (raw[i] != '\\') continue;
        const next = raw[i + 1];
        if (std.ascii.isHex(next)) return true;
        // string.unquote() preserves CSS escapes that would otherwise be
        // reparsed as punctuation in the resulting unquoted CSS token
        // (`unquote("\"\$\"")` -> `"\$"`).  Quote/backslash escapes are
        // string-syntax escapes, not CSS identifier escapes, so those continue
        // through the normal string decoder.
        if (next != '\'' and next != '"' and next != '\\' and
            next != '\n' and next != '\r' and next != '\x0c')
        {
            return true;
        }
    }
    return false;
}

fn utf8CodepointCount(s: []const u8) usize {
    if (std.unicode.Utf8View.init(s)) |view| {
        var it = view.iterator();
        var count: usize = 0;
        while (it.nextCodepointSlice() != null) : (count += 1) {}
        return count;
    } else |_| {
        var count: usize = 0;
        var i: usize = 0;
        while (i < s.len) {
            const byte_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const actual_len = if (i + byte_len > s.len) 1 else byte_len;
            count += 1;
            i += actual_len;
        }
        return count;
    }
}

fn utf8OffsetForCodepoint(s: []const u8, cp_index: usize) ?usize {
    if (std.unicode.Utf8View.init(s)) |view| {
        var it = view.iterator();
        var count: usize = 0;
        var offset: usize = 0;
        while (it.nextCodepointSlice()) |cp| {
            if (count == cp_index) return offset;
            offset += cp.len;
            count += 1;
        }
        if (count == cp_index) return offset;
        return null;
    } else |_| {
        var count: usize = 0;
        var i: usize = 0;
        while (i < s.len) {
            if (count == cp_index) return i;
            const byte_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const actual_len = if (i + byte_len > s.len) 1 else byte_len;
            i += actual_len;
            count += 1;
        }
        if (count == cp_index) return i;
        return null;
    }
}

fn parseIntIndex(ctx: *BuiltinContext, v: Value) BuiltinError!i64 {
    if (!v.isNumber()) return error.BuiltinType;
    if (v.unitId(ctx.number_pool) != .none) return error.BuiltinType;
    const raw = v.asF64(ctx.number_pool);
    if (!std.math.isFinite(raw)) return error.BuiltinType;
    const truncated = @trunc(raw);
    if (truncated != raw) return error.BuiltinType;
    const max_i64_f: f64 = @floatFromInt(std.math.maxInt(i64));
    const min_i64_f: f64 = @floatFromInt(std.math.minInt(i64));
    if (truncated < min_i64_f or truncated > max_i64_f) return error.BuiltinType;
    return @intFromFloat(truncated);
}

fn parseIntIndexNamed(ctx: *BuiltinContext, param_name: []const u8, v: Value) BuiltinError!i64 {
    return parseIntIndex(ctx, v) catch |err| switch (err) {
        error.BuiltinType => {
            if (!v.isNumber()) return reportArgumentTypeMismatch(ctx, param_name, v, "number");
            return error.BuiltinType;
        },
        else => return err,
    };
}

fn resolveIndex(len: usize, index: i64) usize {
    const slen: i64 = @intCast(len);
    // SAFETY: initialized before first read in this scope.
    var resolved: i64 = undefined;
    if (index >= 0) {
        resolved = index - 1;
    } else {
        resolved = slen + index;
    }
    if (resolved < 0) return 0;
    if (resolved > slen) return len;
    return @intCast(resolved);
}

pub fn string_index(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{ "string", "substring" }, 2);
    const hay_v = bound[0].?;
    const needle_v = bound[1].?;
    var hay_decoded = try decodeStringArgForOps(ctx, "string", hay_v);
    defer hay_decoded.deinit(ctx.allocator);
    var needle_decoded = try decodeStringArgForOps(ctx, "substring", needle_v);
    defer needle_decoded.deinit(ctx.allocator);
    const hay = hay_decoded.bytes;
    const needle = needle_decoded.bytes;
    const byte_idx = std.mem.find(u8, hay, needle) orelse return Value.nil_v;
    const cp_idx = utf8CodepointCount(hay[0..byte_idx]) + 1;
    return Value.numberUnitless(@floatFromInt(cp_idx));
}

pub fn string_replace(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{ "string", "substring", "replacement" }, 3);
    const source_v = bound[0].?;
    const needle_v = bound[1].?;
    const replacement_v = bound[2].?;

    var source_decoded = try decodeStringArgForOps(ctx, "string", source_v);
    defer source_decoded.deinit(ctx.allocator);
    var needle_decoded = try decodeStringArgForOps(ctx, "substring", needle_v);
    defer needle_decoded.deinit(ctx.allocator);
    var replacement_decoded = try decodeStringArgForOps(ctx, "replacement", replacement_v);
    defer replacement_decoded.deinit(ctx.allocator);

    const source = source_decoded.bytes;
    const needle = needle_decoded.bytes;
    const replacement = replacement_decoded.bytes;
    if (needle.len == 0) {
        return source_v;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(ctx.allocator);

    var start: usize = 0;
    while (std.mem.findPos(u8, source, start, needle)) |pos| {
        try out.appendSlice(ctx.allocator, source[start..pos]);
        try out.appendSlice(ctx.allocator, replacement);
        start = pos + needle.len;
    }
    try out.appendSlice(ctx.allocator, source[start..]);

    const replaced = try out.toOwnedSlice(ctx.allocator);
    defer ctx.allocator.free(replaced);
    const id = try internString(ctx, replaced);
    return Value.string(id, source_v.stringQuoted(ctx.string_flags_pool.items));
}

pub fn string_insert(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{ "string", "insert", "index" }, 3);
    const base_v = bound[0].?;
    const ins_v = bound[1].?;
    const idx_v = bound[2].?;
    const idx = try parseIntIndexNamed(ctx, "index", idx_v);
    var base_decoded = try decodeStringArgForOps(ctx, "string", base_v);
    defer base_decoded.deinit(ctx.allocator);
    var ins_decoded = try decodeStringArgForOps(ctx, "insert", ins_v);
    defer ins_decoded.deinit(ctx.allocator);
    const base = base_decoded.bytes;
    const ins = ins_decoded.bytes;

    const cp_len = utf8CodepointCount(base);
    const slen: i64 = @intCast(cp_len);
    // SAFETY: initialized before first read in this scope.
    var cp_pos_i: i64 = undefined;
    if (idx >= 0) {
        cp_pos_i = idx - 1;
    } else {
        cp_pos_i = slen + idx + 1;
    }
    if (cp_pos_i < 0) cp_pos_i = 0;
    if (cp_pos_i > slen) cp_pos_i = slen;
    const cp_pos: usize = @intCast(cp_pos_i);
    const byte_offset = utf8OffsetForCodepoint(base, cp_pos) orelse base.len;

    const out = try ctx.allocator.alloc(u8, base.len + ins.len);
    defer ctx.allocator.free(out);
    @memcpy(out[0..byte_offset], base[0..byte_offset]);
    @memcpy(out[byte_offset .. byte_offset + ins.len], ins);
    @memcpy(out[byte_offset + ins.len ..], base[byte_offset..]);

    const id = try internString(ctx, out);
    return Value.string(id, base_v.stringQuoted(ctx.string_flags_pool.items));
}

pub fn string_length(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try expectArity(args, 1);
    var decoded = try decodeStringArgForOps(ctx, "string", args[0]);
    defer decoded.deinit(ctx.allocator);
    const s = decoded.bytes;
    return Value.numberUnitless(@floatFromInt(utf8CodepointCount(s)));
}

pub fn string_slice(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    if (args.len > 3) return badArity(2, args.len);
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{ "string", "start-at", "end-at" }, 2);
    const str_v = bound[0].?;
    const start_v = bound[1].?;
    const end_v = bound[2];
    var decoded = try decodeStringArgForOps(ctx, "string", str_v);
    defer decoded.deinit(ctx.allocator);
    const s = decoded.bytes;
    const quoted = str_v.stringQuoted(ctx.string_flags_pool.items);
    const start_raw = try parseIntIndexNamed(ctx, "start-at", start_v);
    const end_raw: ?i64 = if (end_v) |v| try parseIntIndexNamed(ctx, "end-at", v) else null;

    const cp_len = utf8CodepointCount(s);
    if (cp_len == 0) {
        const id = try internString(ctx, "");
        return Value.string(id, quoted);
    }

    var start_idx = resolveIndex(cp_len, start_raw);
    var end_idx: usize = blk: {
        if (end_raw) |raw| {
            if (raw == 0) {
                const id = try internString(ctx, "");
                return Value.string(id, quoted);
            }
            if (raw < 0) {
                const slen: i64 = @intCast(cp_len);
                if (slen + raw < 0) {
                    const id = try internString(ctx, "");
                    return Value.string(id, quoted);
                }
            }
            break :blk resolveIndex(cp_len, raw);
        }
        break :blk cp_len - 1;
    };

    if (start_idx >= cp_len) start_idx = cp_len;
    if (end_idx >= cp_len) end_idx = cp_len - 1;
    if (start_idx > end_idx) {
        const id = try internString(ctx, "");
        return Value.string(id, quoted);
    }

    const byte_start = utf8OffsetForCodepoint(s, start_idx) orelse s.len;
    const byte_end = utf8OffsetForCodepoint(s, end_idx + 1) orelse s.len;
    if (byte_start >= byte_end) {
        const id = try internString(ctx, "");
        return Value.string(id, quoted);
    }

    const id = try internString(ctx, s[byte_start..byte_end]);
    return Value.string(id, quoted);
}

fn parseSplitLimit(ctx: *BuiltinContext, v: Value) BuiltinError!usize {
    if (!v.isNumber()) return error.BuiltinType;
    if (v.unitId(ctx.number_pool) != .none) return error.BuiltinType;
    const raw = v.asF64(ctx.number_pool);
    if (!std.math.isFinite(raw)) return error.BuiltinType;
    const truncated = @trunc(raw);
    if (truncated != raw) return error.BuiltinArity;
    if (truncated < 1) return error.BuiltinArity;
    const max_usize_f: f64 = @floatFromInt(std.math.maxInt(usize));
    if (truncated > max_usize_f) return error.BuiltinArity;
    return @intFromFloat(truncated);
}

fn parseSplitLimitNamed(ctx: *BuiltinContext, param_name: []const u8, v: Value) BuiltinError!usize {
    return parseSplitLimit(ctx, v) catch |err| switch (err) {
        error.BuiltinType => {
            if (!v.isNumber()) return reportArgumentTypeMismatch(ctx, param_name, v, "number");
            return error.BuiltinType;
        },
        else => return err,
    };
}

pub fn string_split(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    if (args.len > 3) return badArity(2, args.len);
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{ "string", "separator", "limit" }, 2);
    const str_v = bound[0].?;
    const separator_v = bound[1].?;
    const limit_v = bound[2];
    var hay_decoded = try decodeStringArgForOps(ctx, "string", str_v);
    defer hay_decoded.deinit(ctx.allocator);
    var needle_decoded = try decodeStringArgForOps(ctx, "separator", separator_v);
    defer needle_decoded.deinit(ctx.allocator);
    const hay = hay_decoded.bytes;
    const needle = needle_decoded.bytes;
    const quoted = str_v.stringQuoted(ctx.string_flags_pool.items);
    const limit: ?usize = if (limit_v) |v| try parseSplitLimitNamed(ctx, "limit", v) else null;

    var parts: std.ArrayListUnmanaged(Value) = .empty;
    defer parts.deinit(ctx.allocator);

    if (needle.len == 0) {
        const cp_len = utf8CodepointCount(hay);
        var cp_i: usize = 0;
        var split_count: usize = 0;
        while (cp_i < cp_len) {
            if (limit) |lim| {
                if (split_count >= lim) {
                    const byte_start = utf8OffsetForCodepoint(hay, cp_i) orelse hay.len;
                    const id = try internString(ctx, hay[byte_start..]);
                    try parts.append(ctx.allocator, Value.string(id, quoted));
                    break;
                }
            }
            const byte_start = utf8OffsetForCodepoint(hay, cp_i) orelse hay.len;
            const byte_end = utf8OffsetForCodepoint(hay, cp_i + 1) orelse hay.len;
            const id = try internString(ctx, hay[byte_start..byte_end]);
            try parts.append(ctx.allocator, Value.string(id, quoted));
            cp_i += 1;
            split_count += 1;
        }
    } else if (hay.len != 0) {
        var start: usize = 0;
        var split_count: usize = 0;
        while (start <= hay.len) {
            if (limit) |lim| {
                if (split_count >= lim) {
                    const id = try internString(ctx, hay[start..]);
                    try parts.append(ctx.allocator, Value.string(id, quoted));
                    break;
                }
            }
            if (std.mem.findPos(u8, hay, start, needle)) |pos| {
                const id = try internString(ctx, hay[start..pos]);
                try parts.append(ctx.allocator, Value.string(id, quoted));
                start = pos + needle.len;
                split_count += 1;
            } else {
                const id = try internString(ctx, hay[start..]);
                try parts.append(ctx.allocator, Value.string(id, quoted));
                break;
            }
        }
    }

    return pushListWithMeta(ctx, parts.items, .comma, true);
}

pub fn string_to_lower(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try expectArity(args, 1);
    var decoded = try decodeStringArgForOps(ctx, "string", args[0]);
    defer decoded.deinit(ctx.allocator);
    const s = decoded.bytes;
    const out = try ctx.allocator.alloc(u8, s.len);
    defer ctx.allocator.free(out);
    for (s, 0..) |c, i| {
        out[i] = std.ascii.toLower(c);
    }
    const id = try internString(ctx, out);
    return Value.string(id, args[0].stringQuoted(ctx.string_flags_pool.items));
}

pub fn string_to_upper(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try expectArity(args, 1);
    var decoded = try decodeStringArgForOps(ctx, "string", args[0]);
    defer decoded.deinit(ctx.allocator);
    const s = decoded.bytes;
    const out = try ctx.allocator.alloc(u8, s.len);
    defer ctx.allocator.free(out);
    for (s, 0..) |c, i| {
        out[i] = std.ascii.toUpper(c);
    }
    const id = try internString(ctx, out);
    return Value.string(id, args[0].stringQuoted(ctx.string_flags_pool.items));
}

pub fn string_quote(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try expectArity(args, 1);
    if (!args[0].isString()) return reportArgumentTypeMismatch(ctx, "string", args[0], "string");
    if (args[0].stringQuoted(ctx.string_flags_pool.items)) return Value.string(args[0].stringIntern(), true);
    const raw = ctx.intern_pool.get(args[0].stringIntern());
    if (try normalizeHexEscapesForQuotedOutput(ctx.allocator, raw)) |normalized| {
        defer ctx.allocator.free(normalized);
        const id = try internString(ctx, normalized);
        return Value.string(id, true);
    }
    return Value.string(args[0].stringIntern(), true);
}

pub fn string_unquote(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try expectArity(args, 1);
    if (!args[0].isString()) return reportArgumentTypeMismatch(ctx, "string", args[0], "string");
    // unquote() is a SassScript-computed string -> declaration serialize
    // plain CSS normalization (space after comma / space before !important / ' / ' in color function)
    // Add a marker to skip.
    if (!args[0].stringQuoted(ctx.string_flags_pool.items)) return args[0].withPreserveLiteralText();
    const raw = ctx.intern_pool.get(args[0].stringIntern());
    if (quotedUnquoteShouldPreserveRawEscapes(raw)) {
        return Value.string(args[0].stringIntern(), false).withPreserveLiteralText();
    }
    var decoded = try decodeStringArgForOps(ctx, "string", args[0]);
    defer decoded.deinit(ctx.allocator);
    const id = try internString(ctx, decoded.bytes);
    return Value.string(id, false).withPreserveLiteralText();
}

pub fn string_unique_id(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try expectArity(args, 0);
    const n = unique_counter.fetchAdd(1, .monotonic);
    var buf: [24]u8 = undefined;
    const raw = std.fmt.bufPrint(&buf, "u{x}", .{n}) catch |err| {
        std.debug.panic("string.unique-id formatting failed: {s}", .{@errorName(err)});
    };
    const id = try internString(ctx, raw);
    return Value.string(id, false);
}

pub fn string_string(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try expectArity(args, 1);
    const css = try valueToCssString(ctx, args[0]);
    defer ctx.allocator.free(css);
    const id = try internString(ctx, css);
    return Value.string(id, true);
}

pub fn string_contains(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    if (args.len < 2) return Value.false_v;
    if (!args[0].isString() or !args[1].isString()) return Value.false_v;
    const hay = ctx.intern_pool.get(args[0].stringIntern());
    const needle = ctx.intern_pool.get(args[1].stringIntern());
    return if (std.mem.find(u8, hay, needle) != null) Value.true_v else Value.false_v;
}

test "utf8 helpers count and offsets for multibyte scalars" {
    const s = "\u{1F46D}a";
    try std.testing.expectEqual(@as(usize, 2), utf8CodepointCount(s));
    try std.testing.expectEqual(@as(?usize, 0), utf8OffsetForCodepoint(s, 0));
    try std.testing.expectEqual(@as(?usize, 4), utf8OffsetForCodepoint(s, 1));
    try std.testing.expectEqual(@as(?usize, 5), utf8OffsetForCodepoint(s, 2));
}

test "utf8 helpers fallback on invalid utf8 bytes" {
    const invalid = [_]u8{0xf0};
    try std.testing.expectEqual(@as(usize, 1), utf8CodepointCount(invalid[0..]));
    try std.testing.expectEqual(@as(?usize, 1), utf8OffsetForCodepoint(invalid[0..], 1));
}

test "normalizeHexEscapesForQuotedOutput inserts explicit delimiters" {
    const allocator = std.testing.allocator;
    const raw = "\\61\"";
    const normalized = (try normalizeHexEscapesForQuotedOutput(allocator, raw)).?;
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings("\\61 \"", normalized);
}

test "quotedUnquoteShouldPreserveRawEscapes detects css hex escapes" {
    try std.testing.expect(quotedUnquoteShouldPreserveRawEscapes("\\0 "));
    try std.testing.expect(quotedUnquoteShouldPreserveRawEscapes("\\61"));
    try std.testing.expect(!quotedUnquoteShouldPreserveRawEscapes("\\\"c\\\""));
}
