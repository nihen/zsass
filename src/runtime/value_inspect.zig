const std = @import("std");
const value_mod = @import("value.zig");
const intern_pool_mod = @import("intern_pool.zig");
const value_format = @import("value_format.zig");
const color_format = @import("../color/color_format.zig");
const calc_utils = @import("calc_utils.zig");

pub const Value = value_mod.Value;
pub const NumberPool = value_mod.NumberPool;
pub const ListMetaPool = value_mod.ListMetaPool;
pub const ColorPool = value_mod.ColorPool;
pub const CallablePayloadPool = value_mod.CallablePayloadPool;
pub const InternPool = intern_pool_mod.InternPool;

pub const Context = struct {
    allocator: std.mem.Allocator,
    intern_pool: *InternPool,
    number_pool: *NumberPool,
    list_pool: *const std.ArrayListUnmanaged([]Value),
    list_meta_pool: *const ListMetaPool,
    color_pool: *const ColorPool,
    callable_payload_pool: *const CallablePayloadPool,
};

pub fn indefiniteArticle(expected_kind: []const u8) []const u8 {
    if (expected_kind.len == 0) return "a";
    return switch (std.ascii.toLower(expected_kind[0])) {
        'a', 'e', 'i', 'o', 'u' => "an",
        else => "a",
    };
}

pub fn formatValueForArgMismatch(ctx: *const Context, value: Value) std.mem.Allocator.Error![]const u8 {
    return switch (value.kind()) {
        .nil => ctx.allocator.dupe(u8, "null"),
        .boolean => ctx.allocator.dupe(u8, if (value.p64Of() != 0) "true" else "false"),
        .number => formatNumberValue(ctx, value),
        .string => formatStringValue(ctx, value),
        .list => formatListValue(ctx, value),
        .color => color_format.formatColorCss(ctx.allocator, value.colorEntry(ctx.color_pool).*) catch error.OutOfMemory,
        .callable => formatCallableValue(ctx, value),
        else => ctx.allocator.dupe(u8, "()"),
    };
}

fn formatNumberValue(ctx: *const Context, value: Value) std.mem.Allocator.Error![]const u8 {
    std.debug.assert(value.kind() == .number);
    const unit_id = value.unitId(ctx.number_pool);
    const unit = if (unit_id == .none) null else ctx.intern_pool.get(unit_id);
    return value_format.formatNumberWithUnit(ctx.allocator, value.asF64(ctx.number_pool), unit) catch error.OutOfMemory;
}

fn formatStringValue(ctx: *const Context, value: Value) std.mem.Allocator.Error![]const u8 {
    std.debug.assert(value.kind() == .string);
    const raw = calc_utils.stripCalcArgMarker(ctx.intern_pool.get(value.stringIntern()));
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(ctx.allocator);

    try out.ensureTotalCapacity(ctx.allocator, raw.len * 2 + 2);
    out.appendAssumeCapacity('"');
    for (raw) |ch| {
        if (ch == '"' or ch == '\\') out.appendAssumeCapacity('\\');
        out.appendAssumeCapacity(ch);
    }
    out.appendAssumeCapacity('"');
    return out.toOwnedSlice(ctx.allocator);
}

fn formatCallableValue(ctx: *const Context, value: Value) std.mem.Allocator.Error![]const u8 {
    std.debug.assert(value.kind() == .callable);
    const name_id = value.callableNameIntern(ctx.callable_payload_pool);
    if (name_id == .none) return ctx.allocator.dupe(u8, "()");

    const name = ctx.intern_pool.get(name_id);
    const display = if (value.callableIsMixin(ctx.callable_payload_pool)) "get-mixin" else "get-function";

    if (value.callableIsCss(ctx.callable_payload_pool)) {
        return std.fmt.allocPrint(ctx.allocator, "{s}(\"{s}\", $css: true)", .{ display, name }) catch error.OutOfMemory;
    }
    if (!value.callableIsBuiltin(ctx.callable_payload_pool)) {
        if (std.mem.findScalar(u8, name, '.')) |dot| {
            return std.fmt.allocPrint(ctx.allocator, "{s}(\"{s}\", $module: \"{s}\")", .{
                display,
                name[dot + 1 ..],
                name[0..dot],
            }) catch error.OutOfMemory;
        }
    }
    return std.fmt.allocPrint(ctx.allocator, "{s}(\"{s}\")", .{ display, name }) catch error.OutOfMemory;
}

fn formatListValue(ctx: *const Context, value: Value) std.mem.Allocator.Error![]const u8 {
    std.debug.assert(value.kind() == .list);

    const view = value_mod.inspectLogicalListView(ctx.list_pool.items, value) orelse return ctx.allocator.dupe(u8, "()");
    const items = view.items;

    if (view.is_map and items.len % 2 == 0) {
        return formatMapListValue(ctx, items);
    }

    if (items.len == 0) {
        return ctx.allocator.dupe(u8, if (view.bracketed) "[]" else "()");
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(ctx.allocator);

    const open_bracket: u8 = if (view.bracketed) '[' else '(';
    const close_bracket: u8 = if (view.bracketed) ']' else ')';

    try out.append(ctx.allocator, open_bracket);

    if (items.len == 1 and (view.separator == .comma or view.separator == .slash)) {
        const inner = try formatValueForArgMismatch(ctx, items[0]);
        defer ctx.allocator.free(inner);

        try out.appendSlice(ctx.allocator, inner);
        if (view.separator == .comma) {
            try out.append(ctx.allocator, ',');
        } else if (view.bracketed) {
            try out.appendSlice(ctx.allocator, " /");
        } else {
            try out.append(ctx.allocator, '/');
        }
        try out.append(ctx.allocator, close_bracket);
        return out.toOwnedSlice(ctx.allocator);
    }

    const sep = value_mod.listSeparatorCssFrom(view.separator);
    try out.ensureUnusedCapacity(ctx.allocator, items.len * (sep.len + 2) + 1);
    for (items, 0..) |item, i| {
        if (i > 0) try out.appendSlice(ctx.allocator, sep);
        const part = try formatValueForArgMismatch(ctx, item);
        defer ctx.allocator.free(part);
        const needs_parens = value_mod.inspectNestedListNeedsParens(ctx.list_pool.items, item, view.separator);
        if (needs_parens) try out.append(ctx.allocator, '(');
        try out.appendSlice(ctx.allocator, part);
        if (needs_parens) try out.append(ctx.allocator, ')');
    }

    try out.append(ctx.allocator, close_bracket);
    return out.toOwnedSlice(ctx.allocator);
}

fn formatMapListValue(ctx: *const Context, items: []const Value) std.mem.Allocator.Error![]const u8 {
    if (items.len == 0) return ctx.allocator.dupe(u8, "()");

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(ctx.allocator);

    try out.append(ctx.allocator, '(');
    var i: usize = 0;
    var wrote_any = false;
    while (i + 1 < items.len) : (i += 2) {
        if (wrote_any) try out.appendSlice(ctx.allocator, ", ");

        const key_raw = items[i];
        const val_raw = items[i + 1];
        const key = try formatValueForArgMismatch(ctx, key_raw);
        defer ctx.allocator.free(key);
        const val = try formatValueForArgMismatch(ctx, val_raw);
        defer ctx.allocator.free(val);

        const wrap_key = value_mod.inspectMapListNeedsParens(ctx.list_pool.items, key_raw, .key);
        const wrap_val = value_mod.inspectMapListNeedsParens(ctx.list_pool.items, val_raw, .value);

        if (wrap_key) try out.append(ctx.allocator, '(');
        try out.appendSlice(ctx.allocator, key);
        if (wrap_key) try out.append(ctx.allocator, ')');

        try out.appendSlice(ctx.allocator, ": ");

        if (wrap_val) try out.append(ctx.allocator, '(');
        try out.appendSlice(ctx.allocator, val);
        if (wrap_val) try out.append(ctx.allocator, ')');

        wrote_any = true;
    }

    try out.append(ctx.allocator, ')');
    return out.toOwnedSlice(ctx.allocator);
}
