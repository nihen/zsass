const std = @import("std");
const comment_strip = @import("../frontend/comment_strip.zig");
const css_utils = @import("../runtime/css_utils.zig");
const ir_validate = @import("../ir/validate.zig");

pub const Error = error{
    OutOfMemory,
    SassError,
};

const findMatchingParen = css_utils.findMatchingParen;
const findDeclarationColon = css_utils.findDeclarationColon;
const supportsInnerHasTopLevelAndOr = css_utils.supportsInnerHasTopLevelAndOr;
const supportsInnerStartsWithNot = css_utils.supportsInnerStartsWithNot;

pub fn prepare(
    allocator: std.mem.Allocator,
    text: []const u8,
    normalize_parens: bool,
) Error![]const u8 {
    const stripped = comment_strip.stripSupportsComments(allocator, text) catch
        return error.OutOfMemory;
    defer if (stripped.ptr != text.ptr) allocator.free(stripped);

    const normalized = try normalizeSupportsPreludeInner(allocator, stripped, normalize_parens);
    defer allocator.free(normalized);

    const collapsed = try collapseTopLevelSupportsParens(allocator, normalized, normalize_parens);
    defer allocator.free(collapsed);

    const trimmed = std.mem.trim(u8, collapsed, " \t\n\r");
    if (trimmed.len == 0) return error.SassError;

    const owned = allocator.dupe(u8, trimmed) catch return error.OutOfMemory;
    errdefer allocator.free(owned);

    ir_validate.validateSupportsPrelude(owned) catch return error.SassError;
    return owned;
}

fn normalizeSupportsPreludeInner(
    allocator: std.mem.Allocator,
    text: []const u8,
    normalize_parens: bool,
) Error![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    var in_string: u8 = 0;
    while (i < text.len) {
        const c = text[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < text.len) {
                result.append(allocator, c) catch return error.OutOfMemory;
                i += 1;
                result.append(allocator, text[i]) catch return error.OutOfMemory;
                i += 1;
                continue;
            }
            if (c == in_string) in_string = 0;
            result.append(allocator, c) catch return error.OutOfMemory;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            result.append(allocator, c) catch return error.OutOfMemory;
            i += 1;
            continue;
        }
        if (c == '(') {
            const is_func = blk: {
                if (result.items.len == 0) break :blk false;
                const last = result.items[result.items.len - 1];
                break :blk std.ascii.isAlphanumeric(last) or last == '-' or last == '_';
            };
            if (!is_func) {
                if (findMatchingParen(text, i)) |close| {
                    const inner = text[i + 1 .. close];
                    if (findDeclarationColon(inner)) |colon_pos| {
                        const decl = try normalizeSupportsDeclarationAfterEval(allocator, inner, colon_pos);
                        defer allocator.free(decl);
                        result.append(allocator, '(') catch return error.OutOfMemory;
                        result.appendSlice(allocator, decl) catch return error.OutOfMemory;
                        result.append(allocator, ')') catch return error.OutOfMemory;
                        i = close + 1;
                        continue;
                    }

                    const trimmed_inner = std.mem.trim(u8, inner, " \t\n\r");
                    if (trimmed_inner.len >= 2 and trimmed_inner[0] == '(') {
                        if (findMatchingParen(trimmed_inner, 0)) |inner_close| {
                            if (inner_close == trimmed_inner.len - 1) {
                                const recursed = try normalizeSupportsPreludeInner(allocator, trimmed_inner, normalize_parens);
                                defer allocator.free(recursed);
                                if (normalize_parens) {
                                    const rec_trimmed = std.mem.trim(u8, recursed, " \t\n\r");
                                    if (rec_trimmed.len >= 2 and
                                        rec_trimmed[0] == '(' and
                                        rec_trimmed[rec_trimmed.len - 1] == ')')
                                    {
                                        const rec_inner = rec_trimmed[1 .. rec_trimmed.len - 1];
                                        if (findDeclarationColon(rec_inner) != null) {
                                            result.appendSlice(allocator, rec_trimmed) catch return error.OutOfMemory;
                                            i = close + 1;
                                            continue;
                                        }
                                    }
                                }
                                result.append(allocator, '(') catch return error.OutOfMemory;
                                result.appendSlice(allocator, recursed) catch return error.OutOfMemory;
                                result.append(allocator, ')') catch return error.OutOfMemory;
                                i = close + 1;
                                continue;
                            }
                        }
                    }

                    const inner_has_logic = supportsInnerHasTopLevelAndOr(inner) or
                        supportsInnerStartsWithNot(inner);
                    const at_outermost = std.mem.trim(u8, result.items, " \t\n\r").len == 0;
                    const nothing_after = std.mem.trim(u8, text[close + 1 ..], " \t\n\r").len == 0;
                    if (inner_has_logic and at_outermost and nothing_after) {
                        const evaled_inner = try normalizeSupportsPreludeInner(allocator, inner, normalize_parens);
                        defer allocator.free(evaled_inner);
                        result.appendSlice(allocator, evaled_inner) catch return error.OutOfMemory;
                        i = close + 1;
                        continue;
                    }
                }
            }
        }

        result.append(allocator, c) catch return error.OutOfMemory;
        i += 1;
    }

    return result.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn collapseTopLevelSupportsParens(
    allocator: std.mem.Allocator,
    text: []const u8,
    normalize_parens: bool,
) Error![]const u8 {
    if (!normalize_parens) {
        return allocator.dupe(u8, text) catch return error.OutOfMemory;
    }

    var current = std.mem.trim(u8, text, " \t\n\r");
    while (current.len >= 2 and current[0] == '(') {
        const close = findMatchingParen(current, 0) orelse break;
        if (close != current.len - 1) break;

        const inner = std.mem.trim(u8, current[1..close], " \t\n\r");
        if (inner.len == 0) break;

        if (supportsInnerHasTopLevelAndOr(inner) or supportsInnerStartsWithNot(inner)) {
            current = inner;
            continue;
        }
        if (findDeclarationColon(inner) != null) break;
        if (inner[0] == '(') {
            current = inner;
            continue;
        }
        break;
    }

    return allocator.dupe(u8, current) catch return error.OutOfMemory;
}

fn normalizeSupportsDeclarationAfterEval(
    allocator: std.mem.Allocator,
    inner: []const u8,
    colon_pos: usize,
) Error![]const u8 {
    const prop = std.mem.trim(u8, inner[0..colon_pos], " \t\n\r");
    const val_raw = inner[colon_pos + 1 ..];

    if (prop.len == 0) return error.SassError;

    const is_custom = prop.len >= 2 and prop[0] == '-' and prop[1] == '-';
    if (is_custom) {
        if (val_raw.len == 0) return error.SassError;
        return allocator.dupe(u8, inner) catch return error.OutOfMemory;
    }

    if (containsWhitespace(prop)) return error.SassError;

    const val = std.mem.trim(u8, val_raw, " \t\n\r");
    if (val.len == 0) return error.SassError;

    return std.mem.concat(allocator, u8, &.{ prop, ": ", val }) catch
        return error.OutOfMemory;
}

fn containsWhitespace(text: []const u8) bool {
    for (text) |c| {
        if (std.ascii.isWhitespace(c)) return true;
    }
    return false;
}
