//! Shared types and helpers for vm builtin modules.
const std = @import("std");
const value_mod = @import("../runtime/value.zig");
const intern_pool_mod = @import("../runtime/intern_pool.zig");
const color_mod = @import("../color/color.zig");
const deprecation_mod = @import("../runtime/deprecation.zig");
const value_eq = @import("../runtime/value_eq.zig");
const value_format = @import("../runtime/value_format.zig");
const value_inspect = @import("../runtime/value_inspect.zig");
const color_format = @import("../color/color_format.zig");
const error_format = @import("../runtime/error_format.zig");
const calc_arg_marker = "\x01zsass-calc-arg:";
const calc_interp_marker = "\x01zsass-calc-interp:";
const color_preserve_slash_marker = "\x01zsass-color-preserve-slash:";

pub const Value = value_mod.Value;
pub const ListSeparator = value_mod.ListSeparator;
pub const ColorEntry = value_mod.ColorEntry;
pub const ColorPool = value_mod.ColorPool;
pub const ColorMissingMask = value_mod.ColorMissingMask;
pub const NumberPool = value_mod.NumberPool;
pub const CallablePayloadPool = value_mod.CallablePayloadPool;
pub const ListMetaPool = value_mod.ListMetaPool;
pub const StringFlagsPool = value_mod.StringFlagsPool;
pub const InternPool = intern_pool_mod.InternPool;
pub const InternId = intern_pool_mod.InternId;

pub const BuiltinError = error{
    OutOfMemory,
    BuiltinArity,
    BuiltinType,
    BuiltinUnsupported,
    SassError,
    FatalDeprecation,
};

pub const BuiltinContext = struct {
    allocator: std.mem.Allocator,
    intern_pool: *InternPool,
    list_pool: *std.ArrayListUnmanaged([]Value),
    color_pool: *ColorPool,
    /// Sidecar pool for unit-bearing number payloads (NaN-box stage 3).
    number_pool: *NumberPool,
    /// Sidecar pool for callable payloads (NaN-box stage 3).
    callable_payload_pool: *CallablePayloadPool,
    /// Sidecar pool for list metadata flags (stage 2 prep, P4 commit 3).
    list_meta_pool: *ListMetaPool,
    /// Sidecar pool for string flags (stage 2 prep, P4 commit 3).
    string_flags_pool: *StringFlagsPool,
    random_state: *u64,
    vm: *anyopaque,
    /// Hook called immediately after appending a new handle to list_pool. look at elements
    /// If all known no-`&`, set bit of sidecar bitset. The VM has a `BuiltinContext`
    /// Set with `ListSidecarSetter.from(vm)` during construction. test via `dummy_vm` is null
    /// (vm is a fake pointer such as `@ptrFromInt(1)`, so it will never be dispatched).
    list_parent_sel_none_hook: ?ListSidecarHook = null,
    /// list_handle is "a map with only a naive string key (no calc-marker / no named-color / no escape)"
    /// If it is determined, the hash index of the first index of that key bytes  ->  pair is retained.
    /// Replace linear scan of `map.get` / `map.has-key` with O(1) for hot
    /// paths where the same lookup is called thousands of times for a large map.
    /// If the value is `null`, "cache has been determined to be non-plain" (= linear every time).
    /// The lifetime matches the VM since it is owned by the VM. If you pass `null` for test
    /// Bypass cache and use only linear scan.
    map_lookup_index_cache: ?*std.AutoHashMapUnmanaged(u32, ?*std.StringHashMapUnmanaged(u32)) = null,
    /// Repeated linear scan cache for `list.index($list, $needle)`.
    /// list_pool item slices are immutable after creation, so `(list handle, raw needle)`
    /// is a stable key within one VM execution.
    list_index_cache: ?*std.AutoHashMapUnmanaged(ListIndexCacheKey, Value) = null,
    slash_list_preserve: ?*const std.AutoHashMapUnmanaged(u32, void) = null,
    deprecation_opts: ?*deprecation_mod.DeprecationOpts = null,
};

pub const ListIndexCacheKey = struct {
    list_handle: u32,
    needle_kind: u8,
    needle_p32: u32,
    needle_p64: u64,
};

pub fn listIndexNeedleIsCacheable(v: Value) bool {
    return switch (v.kind()) {
        .nil, .boolean, .number, .string => true,
        else => false,
    };
}

pub fn stripCalcArgMarker(raw: []const u8) []const u8 {
    if (std.mem.startsWith(u8, raw, calc_arg_marker)) return raw[calc_arg_marker.len..];
    if (std.mem.startsWith(u8, raw, calc_interp_marker)) return raw[calc_interp_marker.len..];
    return raw;
}

/// Opaque id assigned at resolve time (dense 0..N-1).
pub const Id = u32;

pub fn badArity(expected: usize, got: usize) BuiltinError {
    if (got > expected) {
        var buf: [128]u8 = undefined;
        const msg = error_format.formatTooManyArguments(&buf, expected, got) catch return error.BuiltinArity;
        error_format.setContextMessage(msg);
    } else if (got < expected) {
        error_format.setContextMessage(error_format.missingArgumentMessage());
    }
    return error.BuiltinArity;
}

pub fn expectArity(args: []const Value, n: usize) BuiltinError!void {
    if (args.len != n) return badArity(n, args.len);
}

pub fn reportMissingArgument(param_name: []const u8) BuiltinError {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Missing argument ${s}.", .{param_name}) catch return error.BuiltinArity;
    error_format.setContextMessage(msg);
    return error.BuiltinArity;
}

/// After `bindNamedOrPositionalArgs`, require the first `required_count` slots to be non-null
/// and emit `Missing argument $name.` for the first missing required parameter.
pub fn validateRequiredBound(
    comptime names: []const []const u8,
    bound: *const [names.len]?Value,
    comptime required_count: usize,
) BuiltinError!void {
    comptime std.debug.assert(required_count <= names.len);
    inline for (0..required_count) |i| {
        if (bound[i] == null) {
            return reportMissingArgument(names[i]);
        }
    }
}

pub fn reportArgumentTypeMismatch(ctx: *BuiltinContext, param_name: []const u8, value: Value, expected_kind: []const u8) BuiltinError {
    const val_str = valueToInspectionString(ctx, value) catch return error.BuiltinType;
    defer ctx.allocator.free(val_str);
    const article = value_inspect.indefiniteArticle(expected_kind);
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "${s}: {s} is not {s} {s}.", .{ param_name, val_str, article, expected_kind }) catch return error.BuiltinType;
    error_format.setContextMessage(msg);
    return error.BuiltinType;
}

fn valueToInspectionString(ctx: *BuiltinContext, v: Value) BuiltinError![]const u8 {
    var inspect_ctx: value_inspect.Context = .{
        .allocator = ctx.allocator,
        .intern_pool = ctx.intern_pool,
        .number_pool = ctx.number_pool,
        .list_pool = ctx.list_pool,
        .list_meta_pool = ctx.list_meta_pool,
        .color_pool = ctx.color_pool,
        .callable_payload_pool = ctx.callable_payload_pool,
    };
    return value_inspect.formatValueForArgMismatch(&inspect_ctx, v) catch error.OutOfMemory;
}

pub fn expectNumber(ctx: *BuiltinContext, v: Value) BuiltinError!f64 {
    if (v.kind() != .number) return error.BuiltinType;
    return v.asF64(ctx.number_pool);
}

pub fn numberLike(ctx: *BuiltinContext, value: f64, unit: InternId) BuiltinError!Value {
    if (unit == .none) return Value.numberUnitless(value);
    return Value.number(value, unit, ctx.number_pool, ctx.allocator) catch error.OutOfMemory;
}

pub fn internString(ctx: *BuiltinContext, s: []const u8) BuiltinError!InternId {
    return ctx.intern_pool.intern(s) catch error.OutOfMemory;
}

pub fn pushList(ctx: *BuiltinContext, items: []const Value) BuiltinError!Value {
    const h: u32 = @intCast(ctx.list_pool.items.len);
    const owned = try ctx.allocator.dupe(Value, items);
    {
        errdefer ctx.allocator.free(owned);
        try ctx.list_pool.append(ctx.allocator, owned);
    }
    // After `append` succeeds, `owned` is borrowed by `list_pool[h]`. If
    // the hook fails we must pop+free in lockstep so the pool never holds
    // a dangling pointer.
    errdefer {
        _ = ctx.list_pool.pop();
        ctx.allocator.free(owned);
    }
    try maybeNoteListParentSelNoneHook(ctx, h, owned);
    return Value.listWithSpace(h, false);
}

pub fn pushListWithMeta(
    ctx: *BuiltinContext,
    items: []const Value,
    separator: ListSeparator,
    bracketed: bool,
    is_map: bool,
) BuiltinError!Value {
    const handle: u32 = @intCast(ctx.list_pool.items.len);
    const owned = try ctx.allocator.dupe(Value, items);
    {
        errdefer ctx.allocator.free(owned);
        try ctx.list_pool.append(ctx.allocator, owned);
    }
    errdefer {
        _ = ctx.list_pool.pop();
        ctx.allocator.free(owned);
    }
    try maybeNoteListParentSelNoneHook(ctx, handle, owned);
    return Value.listWithMeta(handle, separator, bracketed, is_map);
}

pub fn pushCommaList(ctx: *BuiltinContext, items: []const Value) BuiltinError!Value {
    return pushListWithMeta(ctx, items, .comma, false, false);
}

/// Like `pushListWithMeta`, but takes ownership of `owned` (an exactly-sized
/// slice allocated with `ctx.allocator`) instead of duplicating it. Hot map
/// builtins build their result buffer once and hand it to the pool directly.
/// On error the slice is freed; the caller must not touch it afterwards.
pub fn pushListOwnedWithMeta(
    ctx: *BuiltinContext,
    owned: []Value,
    separator: ListSeparator,
    bracketed: bool,
    is_map: bool,
) BuiltinError!Value {
    const handle: u32 = @intCast(ctx.list_pool.items.len);
    {
        errdefer ctx.allocator.free(owned);
        try ctx.list_pool.append(ctx.allocator, owned);
    }
    errdefer {
        _ = ctx.list_pool.pop();
        ctx.allocator.free(owned);
    }
    try maybeNoteListParentSelNoneHook(ctx, handle, owned);
    return Value.listWithMeta(handle, separator, bracketed, is_map);
}

/// Called immediately after builtin appends a new handle to list_pool.
/// All elements are known no-`&` (number / quoted-string / preserved-`&` string /
/// non-`&` unquoted string / color / boolean / nil / list with bits already set, etc.)
/// If so, set the sidecar bitset bit. Even if 1 element is less than the condition, do nothing
/// (= defer to existing lazy walk, safe default).
///
/// Importing a VM type into builtin/shared creates a circular reference, so the VM
/// Set the `list_parent_sel_none_hook` field when building the `BuiltinContext`.
/// No-op if hook is not installed (via test's dummy_vm, etc.).
pub fn maybeNoteListParentSelNoneHook(
    ctx: *BuiltinContext,
    handle: u32,
    items: []const Value,
) BuiltinError!void {
    const hook = ctx.list_parent_sel_none_hook orelse return;
    hook(ctx.vm, handle, items) catch return error.OutOfMemory;
}

pub const ListSidecarHook = *const fn (*anyopaque, u32, []const Value) std.mem.Allocator.Error!void;

pub fn pushColorEntry(ctx: *BuiltinContext, entry: ColorEntry) BuiltinError!Value {
    const handle = value_mod.pushColorEntry(ctx.color_pool, ctx.allocator, entry) catch return error.OutOfMemory;
    return Value.colorWithHandle(handle);
}

pub fn colorValueFromPrimitive(
    ctx: *BuiltinContext,
    primitive: color_mod.Color,
    declared_space: color_mod.ColorSpace,
    missing: ColorMissingMask,
    legacy: bool,
) BuiltinError!Value {
    return pushColorEntry(ctx, .{
        .channels = .{
            primitive.channels[0],
            primitive.channels[1],
            primitive.channels[2],
            primitive.channels[3],
        },
        .space = declared_space,
        .missing = missing,
        .legacy = legacy,
    });
}

pub fn colorEntryOf(ctx: *BuiltinContext, c: Value) *const ColorEntry {
    return c.colorEntry(ctx.color_pool);
}

pub fn colorPrimitiveOf(ctx: *BuiltinContext, c: Value) color_mod.Color {
    const entry = colorEntryOf(ctx, c);
    return color_mod.Color.init(
        entry.channels[0],
        entry.channels[1],
        entry.channels[2],
        entry.channels[3],
        entry.space,
    );
}

pub fn argNameMatches(ctx: *BuiltinContext, name_id: InternId, expected: []const u8) bool {
    if (name_id == .none) return false;
    const raw0 = ctx.intern_pool.get(name_id);
    const raw = if (raw0.len > 0 and raw0[0] == '$') raw0[1..] else raw0;
    var i: usize = 0;
    var j: usize = 0;
    while (i < raw.len and j < expected.len) {
        var rc = raw[i];
        if (rc == '_') rc = '-';
        rc = std.ascii.toLower(rc);
        const ec = std.ascii.toLower(expected[j]);
        if (rc != ec) return false;
        i += 1;
        j += 1;
    }
    return i == raw.len and j == expected.len;
}

pub inline fn bindNamedOrPositionalArgs(
    ctx: *BuiltinContext,
    args: []const Value,
    arg_names: []const InternId,
    comptime names: []const []const u8,
) [names.len]?Value {
    var out: [names.len]?Value = [_]?Value{null} ** names.len;
    var positional: usize = 0;

    for (args, 0..) |arg, i| {
        const name_id: InternId = if (i < arg_names.len) arg_names[i] else .none;
        if (name_id != .none) {
            var matched = false;
            inline for (names, 0..) |expected, idx| {
                if (argNameMatches(ctx, name_id, expected)) {
                    out[idx] = arg;
                    matched = true;
                    break;
                }
            }
            if (matched) continue;
        }

        while (positional < names.len and out[positional] != null) : (positional += 1) {}
        if (positional < names.len) {
            out[positional] = arg;
            positional += 1;
        }
    }

    return out;
}

pub inline fn bindNamedOrPositionalArgsStrict(
    ctx: *BuiltinContext,
    args: []const Value,
    arg_names: []const InternId,
    comptime names: []const []const u8,
    comptime required_count: usize,
) BuiltinError![names.len]?Value {
    comptime std.debug.assert(required_count <= names.len);
    var out: [names.len]?Value = [_]?Value{null} ** names.len;
    var positional: usize = 0;

    for (args, 0..) |arg, i| {
        const name_id: InternId = if (i < arg_names.len) arg_names[i] else .none;
        if (name_id != .none) {
            var matched = false;
            inline for (names, 0..) |expected, idx| {
                if (argNameMatches(ctx, name_id, expected)) {
                    if (out[idx] != null) return error.BuiltinArity;
                    out[idx] = arg;
                    matched = true;
                    break;
                }
            }
            if (!matched) return error.BuiltinArity;
            continue;
        }

        while (positional < names.len and out[positional] != null) : (positional += 1) {}
        if (positional >= names.len) return error.BuiltinArity;
        out[positional] = arg;
        positional += 1;
    }

    inline for (0..required_count) |i| {
        if (out[i] == null) {
            return reportMissingArgument(names[i]);
        }
    }
    return out;
}

pub fn identifierEq(raw: []const u8, expected: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < raw.len and j < expected.len) {
        var rc = raw[i];
        var ec = expected[j];
        if (rc == '_') rc = '-';
        if (ec == '_') ec = '-';
        rc = std.ascii.toLower(rc);
        ec = std.ascii.toLower(ec);
        if (rc != ec) return false;
        i += 1;
        j += 1;
    }
    return i == raw.len and j == expected.len;
}

fn formatNumberWithUnitCss(
    ctx: *BuiltinContext,
    value: f64,
    unit_id: InternId,
) BuiltinError![]const u8 {
    const unit = if (unit_id == .none) null else ctx.intern_pool.get(unit_id);
    return value_format.formatNumberWithUnit(ctx.allocator, value, unit) catch error.OutOfMemory;
}

const ListStringContext = enum {
    normal,
    map_value,
};

fn isImplicitMapList(v: Value, items: []const Value, mode: ListStringContext) bool {
    if (mode != .map_value) return false;
    if (v.listBracketed(value_mod.empty_list_meta_pool)) return false;
    if (v.listSeparator(value_mod.empty_list_meta_pool) != .comma) return false;
    return items.len % 2 == 0;
}

pub fn valueToCssString(ctx: *BuiltinContext, v: Value) BuiltinError![]const u8 {
    return valueToCssStringWithMode(ctx, v, .normal);
}

fn valueToCssStringWithMode(ctx: *BuiltinContext, v: Value, mode: ListStringContext) BuiltinError![]const u8 {
    if (v.isString()) {
        const raw = stripCalcArgMarker(ctx.intern_pool.get(v.stringIntern()));
        const visible = if (std.mem.startsWith(u8, raw, color_preserve_slash_marker)) raw[color_preserve_slash_marker.len..] else raw;
        return try ctx.allocator.dupe(u8, visible);
    }
    if (v.isNumber()) {
        return try formatNumberWithUnitCss(ctx, v.asF64(ctx.number_pool), v.unitId(ctx.number_pool));
    }
    if (v.kind() == .color) {
        return color_format.formatColorCss(ctx.allocator, colorEntryOf(ctx, v).*) catch error.OutOfMemory;
    }
    if (v.kind() == .list) {
        const items = ctx.list_pool.items[v.listHandle()];
        const render_as_map = (v.listIsMap(ctx.list_meta_pool.items) or isImplicitMapList(v, items, mode)) and (items.len % 2 == 0);
        var acc: std.ArrayListUnmanaged(u8) = .empty;
        defer acc.deinit(ctx.allocator);

        if (render_as_map) {
            try acc.append(ctx.allocator, '(');
            var i: usize = 0;
            var wrote = false;
            while (i + 1 < items.len) : (i += 2) {
                if (wrote) try acc.appendSlice(ctx.allocator, ", ");
                const key = try valueToCssStringWithMode(ctx, items[i], .normal);
                defer ctx.allocator.free(key);
                const val = try valueToCssStringWithMode(ctx, items[i + 1], .map_value);
                defer ctx.allocator.free(val);
                try acc.appendSlice(ctx.allocator, key);
                try acc.appendSlice(ctx.allocator, ": ");
                try acc.appendSlice(ctx.allocator, val);
                wrote = true;
            }
            try acc.append(ctx.allocator, ')');
            return acc.toOwnedSlice(ctx.allocator);
        }

        if (items.len == 0) {
            try acc.appendSlice(ctx.allocator, "()");
            return acc.toOwnedSlice(ctx.allocator);
        }

        const sep = v.listSeparatorCss(ctx.list_meta_pool.items);
        var wrote = false;
        for (items) |item| {
            if (item.kind() == .nil) continue;
            const part = try valueToCssStringWithMode(ctx, item, .normal);
            defer ctx.allocator.free(part);
            if (part.len == 0) continue;
            if (wrote) try acc.appendSlice(ctx.allocator, sep);
            try acc.appendSlice(ctx.allocator, part);
            wrote = true;
        }
        return acc.toOwnedSlice(ctx.allocator);
    }
    if (v.kind() == .boolean) {
        return try ctx.allocator.dupe(u8, if (v.p64Of() != 0) "true" else "false");
    }
    if (v.kind() == .nil) {
        return try ctx.allocator.dupe(u8, "null");
    }
    return try std.fmt.allocPrint(ctx.allocator, "()", .{});
}

pub fn valueEql(ctx: *BuiltinContext, a: Value, b: Value) bool {
    var env: BuiltinValueEqEnv = .{ .ctx = ctx };
    return value_eq.valueEqEnv(&env, a, b);
}

const BuiltinValueEqEnv = struct {
    ctx: *BuiltinContext,

    pub fn allocator(self: *const BuiltinValueEqEnv) std.mem.Allocator {
        return self.ctx.allocator;
    }

    pub fn pool(self: *const BuiltinValueEqEnv) *InternPool {
        return self.ctx.intern_pool;
    }

    pub fn numberPool(self: *const BuiltinValueEqEnv) *value_mod.NumberPool {
        return self.ctx.number_pool;
    }

    pub fn listMetaPool(self: *const BuiltinValueEqEnv) *value_mod.ListMetaPool {
        return self.ctx.list_meta_pool;
    }

    pub fn stringFlagsPool(self: *const BuiltinValueEqEnv) *value_mod.StringFlagsPool {
        return self.ctx.string_flags_pool;
    }

    pub fn callablePayloadPool(self: *const BuiltinValueEqEnv) *value_mod.CallablePayloadPool {
        return self.ctx.callable_payload_pool;
    }

    pub fn colorPool(self: *const BuiltinValueEqEnv) ?*const ColorPool {
        return self.ctx.color_pool;
    }

    pub fn getStaticList(self: *const BuiltinValueEqEnv, handle: value_mod.ListHandle) ?[]const Value {
        const idx: usize = @intCast(handle);
        if (idx >= self.ctx.list_pool.items.len) return null;
        return self.ctx.list_pool.items[idx];
    }
};
