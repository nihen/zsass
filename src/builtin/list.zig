//! sass:list builtins.
const std = @import("std");
const shared = @import("shared.zig");
const intern_pool_mod = @import("../runtime/intern_pool.zig");
const error_format = @import("../runtime/error_format.zig");

const Value = shared.Value;
const ListSeparator = shared.ListSeparator;
const InternId = shared.InternId;
const BuiltinContext = shared.BuiltinContext;
const BuiltinError = shared.BuiltinError;
const ListIndexCacheKey = shared.ListIndexCacheKey;

const badArity = shared.badArity;
const internString = shared.internString;
const valueEql = shared.valueEql;
const bindNamedOrPositionalArgsStrict = shared.bindNamedOrPositionalArgsStrict;
const identifierEq = shared.identifierEq;
const listIndexNeedleIsCacheable = shared.listIndexNeedleIsCacheable;
const reportArgumentTypeMismatch = shared.reportArgumentTypeMismatch;

fn parseListSeparatorArg(ctx: *BuiltinContext, param_name: []const u8, value: Value) BuiltinError!?ListSeparator {
    if (value.kind() != .string) return reportArgumentTypeMismatch(ctx, param_name, value, "string");
    const raw = ctx.intern_pool.get(value.stringIntern());
    if (identifierEq(raw, "auto")) return null;
    if (identifierEq(raw, "space")) return .space;
    if (identifierEq(raw, "comma")) return .comma;
    if (identifierEq(raw, "slash")) return .slash;
    return error.BuiltinType;
}

const LogicalListView = struct {
    items: []const Value,
    separator: ListSeparator,
    bracketed: bool,
    is_map: bool,
};

fn logicalListView(ctx: *BuiltinContext, value: Value) ?LogicalListView {
    if (value.kind() != .list) return null;
    const items = ctx.list_pool.items[value.listHandle()];
    if (value.listBracketed(ctx.list_meta_pool.items) and value.listComma(ctx.list_meta_pool.items) and items.len == 1 and items[0].kind() == .list and !items[0].listBracketed(ctx.list_meta_pool.items) and !items[0].listIsMap(ctx.list_meta_pool.items)) {
        const inner_items = ctx.list_pool.items[items[0].listHandle()];
        return .{
            .items = inner_items,
            .separator = items[0].listSeparator(ctx.list_meta_pool.items),
            .bracketed = true,
            .is_map = false,
        };
    }
    return .{
        .items = items,
        .separator = value.listSeparator(ctx.list_meta_pool.items),
        .bracketed = value.listBracketed(ctx.list_meta_pool.items),
        .is_map = value.listIsMap(ctx.list_meta_pool.items),
    };
}

fn listAutoSeparatorCandidate(ctx: *BuiltinContext, value: Value) ?ListSeparator {
    const view = logicalListView(ctx, value) orelse return null;
    if (view.is_map) return if (view.items.len == 0) null else .comma;
    if (view.separator == .undecided) return null;
    return view.separator;
}

const pushListWithMeta = shared.pushListWithMeta;

fn pushPairList(ctx: *BuiltinContext, key: Value, value: Value) BuiltinError!Value {
    var pair: [2]Value = .{ key, value };
    return pushListWithMeta(ctx, pair[0..], .space, false, false);
}

fn appendListLikeItems(ctx: *BuiltinContext, out: *std.ArrayListUnmanaged(Value), value: Value) BuiltinError!void {
    if (logicalListView(ctx, value)) |view| {
        if (view.is_map) {
            var i: usize = 0;
            while (i + 1 < view.items.len) : (i += 2) {
                try out.append(ctx.allocator, try pushPairList(ctx, view.items[i], view.items[i + 1]));
            }
        } else {
            try out.appendSlice(ctx.allocator, view.items);
        }
        return;
    }
    switch (value.kind()) {
        .nil => {},
        else => try out.append(ctx.allocator, value),
    }
}

fn listEntryLen(ctx: *BuiltinContext, value: Value) usize {
    const view = logicalListView(ctx, value) orelse return 1;
    return if (view.is_map) view.items.len / 2 else view.items.len;
}

fn listItemTruthy(value: Value) bool {
    if (value.kind() == .nil) return false;
    if (value.kind() == .boolean) return value.p64Of() != 0;
    return true;
}

fn parseListIndexArg(ctx: *BuiltinContext, param_name: []const u8, value: Value) BuiltinError!i64 {
    if (value.kind() != .number) return reportArgumentTypeMismatch(ctx, param_name, value, "number");
    const raw = value.asF64(ctx.number_pool);
    if (!std.math.isFinite(raw)) return error.BuiltinType;
    return @intFromFloat(@trunc(raw));
}

fn reportInvalidListIndex(param_name: []const u8, index: i64, list_len: usize) BuiltinError {
    var buf: [192]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "${s}: Invalid index {d} for a list with {d} elements.", .{ param_name, index, list_len }) catch return error.BuiltinType;
    error_format.setContextMessage(msg);
    return error.BuiltinType;
}

/// Minimum compatibility equivalent to Legacy `Value.withoutSlash()`:
/// Revert the unpreserved `1/2`-derived slash-list (two-element unitless number) to number.
/// Note: Since there is currently no strict identifier for explicit `list.slash(1, 2)` on Value,
/// Limit the target to slash-free argument edges observed in core spec.
fn coerceSlashFreeNumberishTopLevel(ctx: *BuiltinContext, value: Value) Value {
    if (value.kind() != .list) return value;
    if (!value.listSlash(ctx.list_meta_pool.items) or value.listBracketed(ctx.list_meta_pool.items) or value.listComma(ctx.list_meta_pool.items) or value.listIsMap(ctx.list_meta_pool.items)) return value;

    const items = ctx.list_pool.items[value.listHandle()];
    if (items.len != 2) return value;
    if (items[0].kind() != .number or items[1].kind() != .number) return value;
    if (items[0].unitId(ctx.number_pool) != .none or items[1].unitId(ctx.number_pool) != .none) return value;

    return Value.numberUnitless(items[0].asF64(ctx.number_pool) / items[1].asF64(ctx.number_pool));
}

fn resolveOneBasedListIndex(len: usize, raw_idx: i64) ?usize {
    if (raw_idx == 0) return null;
    var resolved = raw_idx;
    if (resolved < 0) resolved = @as(i64, @intCast(len)) + resolved + 1;
    if (resolved <= 0 or resolved > len) return null;
    return @intCast(resolved - 1);
}

pub fn list_append(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    if (args.len > 3) return badArity(2, args.len);
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{ "list", "val", "separator" }, 2);
    const list_value = bound[0].?;
    const new_value = bound[1].?;

    var appended: std.ArrayListUnmanaged(Value) = .empty;
    defer appended.deinit(ctx.allocator);
    try appendListLikeItems(ctx, &appended, list_value);
    try appended.append(ctx.allocator, new_value);

    const view = logicalListView(ctx, list_value);
    var separator: ListSeparator = if (view) |v|
        (if (v.is_map)
            (if (v.items.len == 0) .space else .comma)
        else switch (v.separator) {
            .undecided => .space,
            else => v.separator,
        })
    else
        .space;
    const bracketed = if (view) |v| !v.is_map and v.bracketed else false;
    if (bound[2]) |separator_value| {
        if (try parseListSeparatorArg(ctx, "separator", separator_value)) |sep| separator = sep;
    }
    return pushListWithMeta(ctx, appended.items, separator, bracketed, false);
}

pub fn list_index(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{ "list", "value" }, 2);
    const list_value = bound[0].?;
    const needle = bound[1].?;
    if (logicalListView(ctx, list_value)) |view| {
        if (view.is_map) {
            var i: usize = 0;
            var pair_index: usize = 0;
            while (i + 1 < view.items.len) : (i += 2) {
                const pair = try pushPairList(ctx, view.items[i], view.items[i + 1]);
                if (valueEql(ctx, pair, needle)) return Value.numberUnitless(@floatFromInt(pair_index + 1));
                pair_index += 1;
            }
            return Value.nil_v;
        }
        const cache_key = if (ctx.list_index_cache != null and list_value.kind() == .list and listIndexNeedleIsCacheable(needle))
            ListIndexCacheKey{
                .list_handle = list_value.listHandle(),
                .needle_kind = @intFromEnum(needle.kind()),
                .needle_p32 = needle.p32Of(),
                .needle_p64 = needle.p64Of(),
            }
        else
            null;
        if (cache_key) |key| {
            if (ctx.list_index_cache.?.get(key)) |cached| return cached;
        }
        for (view.items, 0..) |it, i| {
            if (valueEql(ctx, it, needle)) {
                const out = Value.numberUnitless(@floatFromInt(i + 1));
                if (cache_key) |key| try ctx.list_index_cache.?.put(ctx.allocator, key, out);
                return out;
            }
        }
        if (cache_key) |key| try ctx.list_index_cache.?.put(ctx.allocator, key, Value.nil_v);
        return Value.nil_v;
    }
    if (valueEql(ctx, list_value, needle)) return Value.numberUnitless(1);
    return Value.nil_v;
}

pub fn list_join(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    if (args.len > 4) return badArity(2, args.len);
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{ "list1", "list2", "separator", "bracketed" }, 2);
    const list1_raw = bound[0].?;
    const list2_raw = bound[1].?;
    const list1 = coerceSlashFreeNumberishTopLevel(ctx, list1_raw);
    const list2 = coerceSlashFreeNumberishTopLevel(ctx, list2_raw);

    var joined: std.ArrayListUnmanaged(Value) = .empty;
    defer joined.deinit(ctx.allocator);
    try appendListLikeItems(ctx, &joined, list1);
    try appendListLikeItems(ctx, &joined, list2);

    const separator = blk: {
        if (bound[2]) |separator_value| {
            if (try parseListSeparatorArg(ctx, "separator", separator_value)) |sep| break :blk sep;
        }
        if (listAutoSeparatorCandidate(ctx, list1)) |sep| break :blk sep;
        break :blk listAutoSeparatorCandidate(ctx, list2) orelse .space;
    };

    var bracketed = list1.kind() == .list and list1.listBracketed(ctx.list_meta_pool.items);
    if (bound[3]) |bracketed_value| {
        if (bracketed_value.kind() == .string and identifierEq(ctx.intern_pool.get(bracketed_value.stringIntern()), "auto")) {
            // keep default from the first list
        } else {
            bracketed = listItemTruthy(bracketed_value);
        }
    }

    const out = try joined.toOwnedSlice(ctx.allocator);
    const handle: u32 = @intCast(ctx.list_pool.items.len);
    {
        errdefer ctx.allocator.free(out);
        try ctx.list_pool.append(ctx.allocator, out);
    }
    errdefer {
        _ = ctx.list_pool.pop();
        ctx.allocator.free(out);
    }
    try shared.maybeNoteListParentSelNoneHook(ctx, handle, out);
    return Value.listWith(handle, separator, bracketed);
}

const ZipExpandedEntry = struct {
    items: []const Value,
};

fn mapZipPairsInArena(
    ctx: *BuiltinContext,
    allocator: std.mem.Allocator,
    items: []const Value,
) BuiltinError![]Value {
    const pair_count = items.len / 2;
    const mapped = try allocator.alloc(Value, pair_count);
    var i: usize = 0;
    var pair_index: usize = 0;
    while (i + 1 < items.len) : (i += 2) {
        mapped[pair_index] = try pushPairList(ctx, items[i], items[i + 1]);
        pair_index += 1;
    }
    return mapped;
}

fn scalarZipSliceInArena(allocator: std.mem.Allocator, value: Value) BuiltinError![]Value {
    const owned = try allocator.alloc(Value, 1);
    owned[0] = value;
    return owned;
}

fn allocZipRow(ctx: *BuiltinContext, expanded: []const ZipExpandedEntry, row_index: usize) BuiltinError![]Value {
    const nested = try ctx.allocator.alloc(Value, expanded.len);
    for (expanded, 0..) |entry, j| {
        nested[j] = entry.items[row_index];
    }
    return nested;
}

pub fn list_length(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{"list"}, 1);
    const list_value = bound[0].?;
    if (list_value.kind() != .list) return Value.numberUnitless(1);
    return Value.numberUnitless(@floatFromInt(listEntryLen(ctx, list_value)));
}

pub fn list_nth(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{ "list", "n" }, 2);
    const list_value = bound[0].?;
    const index_value = bound[1].?;
    const idx = try parseListIndexArg(ctx, "n", index_value);

    if (list_value.kind() != .list) {
        if (idx == 1 or idx == -1) return coerceSlashFreeNumberishTopLevel(ctx, list_value);
        return reportInvalidListIndex("n", idx, 1);
    }

    const view = logicalListView(ctx, list_value).?;
    if (view.is_map) {
        const resolved_pair = resolveOneBasedListIndex(view.items.len / 2, idx) orelse return reportInvalidListIndex("n", idx, view.items.len / 2);
        return pushPairList(ctx, view.items[resolved_pair * 2], view.items[resolved_pair * 2 + 1]);
    }

    const resolved = resolveOneBasedListIndex(view.items.len, idx) orelse return reportInvalidListIndex("n", idx, view.items.len);
    return coerceSlashFreeNumberishTopLevel(ctx, view.items[resolved]);
}

pub fn list_set_nth(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{ "list", "n", "value" }, 3);
    const list_value = bound[0].?;
    const index_value = bound[1].?;
    const new_value = bound[2].?;
    const idx = try parseListIndexArg(ctx, "n", index_value);

    if (list_value.kind() != .list) {
        if (idx != 1 and idx != -1) return reportInvalidListIndex("n", idx, 1);
        const nl = try ctx.allocator.alloc(Value, 1);
        nl[0] = new_value;
        const h_single: u32 = @intCast(ctx.list_pool.items.len);
        {
            errdefer ctx.allocator.free(nl);
            try ctx.list_pool.append(ctx.allocator, nl);
        }
        errdefer {
            _ = ctx.list_pool.pop();
            ctx.allocator.free(nl);
        }
        try shared.maybeNoteListParentSelNoneHook(ctx, h_single, nl);
        return Value.listWithSpace(h_single, false);
    }

    const view = logicalListView(ctx, list_value).?;
    if (view.is_map) {
        const resolved_pair = resolveOneBasedListIndex(view.items.len / 2, idx) orelse return reportInvalidListIndex("n", idx, view.items.len / 2);
        var out: std.ArrayListUnmanaged(Value) = .empty;
        defer out.deinit(ctx.allocator);
        var i: usize = 0;
        var pair_index: usize = 0;
        while (i + 1 < view.items.len) : (i += 2) {
            if (pair_index == resolved_pair) {
                try out.append(ctx.allocator, new_value);
            } else {
                try out.append(ctx.allocator, try pushPairList(ctx, view.items[i], view.items[i + 1]));
            }
            pair_index += 1;
        }
        return pushListWithMeta(ctx, out.items, .comma, false, false);
    }

    const resolved = resolveOneBasedListIndex(view.items.len, idx) orelse return reportInvalidListIndex("n", idx, view.items.len);
    const nl = try ctx.allocator.alloc(Value, view.items.len);
    @memcpy(nl, view.items);
    nl[resolved] = new_value;
    const h: u32 = @intCast(ctx.list_pool.items.len);
    {
        errdefer ctx.allocator.free(nl);
        try ctx.list_pool.append(ctx.allocator, nl);
    }
    errdefer {
        _ = ctx.list_pool.pop();
        ctx.allocator.free(nl);
    }
    try shared.maybeNoteListParentSelNoneHook(ctx, h, nl);
    return Value.listWith(h, view.separator, view.bracketed);
}

pub fn list_slash(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    if (args.len < 2) return badArity(2, args.len);
    const named_len = @min(arg_names.len, args.len);
    for (arg_names[0..named_len]) |name_id| {
        if (name_id != .none) return error.BuiltinArity;
    }
    const nl = try ctx.allocator.dupe(Value, args);
    const h: u32 = @intCast(ctx.list_pool.items.len);
    {
        errdefer ctx.allocator.free(nl);
        try ctx.list_pool.append(ctx.allocator, nl);
    }
    errdefer {
        _ = ctx.list_pool.pop();
        ctx.allocator.free(nl);
    }
    try shared.maybeNoteListParentSelNoneHook(ctx, h, nl);
    return Value.listWithSlash(h, false).withBuiltinSlashList();
}

pub fn list_zip(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    if (args.len == 0) {
        const empty: [0]Value = .{};
        return pushListWithMeta(ctx, empty[0..], .comma, false, false);
    }

    var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
    defer scratch.deinit();
    const scratch_alloc = scratch.allocator();

    var expanded: std.ArrayListUnmanaged(ZipExpandedEntry) = .empty;
    defer expanded.deinit(scratch_alloc);
    try expanded.ensureTotalCapacity(scratch_alloc, args.len);

    for (args) |arg| {
        if (logicalListView(ctx, arg)) |view| {
            if (view.is_map) {
                const mapped = try mapZipPairsInArena(ctx, scratch_alloc, view.items);
                expanded.appendAssumeCapacity(.{ .items = mapped });
            } else {
                expanded.appendAssumeCapacity(.{ .items = view.items });
            }
        } else {
            const owned = try scalarZipSliceInArena(scratch_alloc, arg);
            expanded.appendAssumeCapacity(.{ .items = owned });
        }
    }

    var min_len: usize = expanded.items[0].items.len;
    for (expanded.items[1..]) |entry| {
        if (entry.items.len < min_len) min_len = entry.items.len;
    }

    const outer = try ctx.allocator.alloc(Value, min_len);
    const start_pool_len = ctx.list_pool.items.len;
    // After this point any failure must roll the pool back to its prior
    // state -- otherwise nested rows we appended below would dangle once
    // `outer` itself fails to land or the final hook errors out.
    errdefer {
        while (ctx.list_pool.items.len > start_pool_len) {
            const popped = ctx.list_pool.pop().?;
            ctx.allocator.free(popped);
        }
    }
    {
        errdefer ctx.allocator.free(outer);
        for (0..min_len) |i| {
            const nested = try allocZipRow(ctx, expanded.items, i);
            {
                errdefer ctx.allocator.free(nested);
                try ctx.list_pool.append(ctx.allocator, nested);
            }
            const nested_h: u32 = @intCast(ctx.list_pool.items.len - 1);
            try shared.maybeNoteListParentSelNoneHook(ctx, nested_h, nested);
            outer[i] = Value.listWithSpace(nested_h, false);
        }
    }

    const h: u32 = @intCast(ctx.list_pool.items.len);
    {
        errdefer ctx.allocator.free(outer);
        try ctx.list_pool.append(ctx.allocator, outer);
    }
    // `outer` is now the most recent entry in the pool; the outer
    // `errdefer` above will pop+free it (along with every nested row)
    // if the hook call fails.
    try shared.maybeNoteListParentSelNoneHook(ctx, h, outer);
    return Value.listWithComma(h, false);
}

pub fn list_is_bracketed(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{"list"}, 1);
    const list_value = bound[0].?;
    if (list_value.kind() != .list) return Value.false_v;
    return if (list_value.listBracketed(ctx.list_meta_pool.items)) Value.true_v else Value.false_v;
}

pub fn list_separator(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{"list"}, 1);
    const list_value = bound[0].?;
    const sep_name = blk: {
        if (list_value.kind() != .list) break :blk "space";
        const view = logicalListView(ctx, list_value).?;
        if (view.is_map) {
            break :blk if (view.items.len == 0) "space" else "comma";
        }
        break :blk switch (view.separator) {
            .comma => "comma",
            .slash => "slash",
            .space => "space",
            .undecided => "space",
        };
    };
    const id = try internString(ctx, sep_name);
    return Value.string(id, false);
}

const testing = std.testing;
const InternPool = intern_pool_mod.InternPool;
const ColorPool = shared.ColorPool;

const ListTestHarness = struct {
    allocator: std.mem.Allocator,
    intern_pool: InternPool,
    list_pool: std.ArrayListUnmanaged([]Value),
    color_pool: ColorPool,
    number_pool: shared.NumberPool,
    callable_payload_pool: shared.CallablePayloadPool,
    list_meta_pool: shared.ListMetaPool,
    string_flags_pool: shared.StringFlagsPool,
    random_state: u64,

    fn init(allocator: std.mem.Allocator) !ListTestHarness {
        return .{
            .allocator = allocator,
            .intern_pool = try InternPool.init(allocator),
            .list_pool = .empty,
            .color_pool = .empty,
            .number_pool = .empty,
            .callable_payload_pool = .empty,
            .list_meta_pool = .empty,
            .string_flags_pool = .empty,
            .random_state = 0x1234_5678_9abc_def0,
        };
    }

    fn deinit(self: *ListTestHarness) void {
        for (self.list_pool.items) |items| self.allocator.free(items);
        self.list_pool.deinit(self.allocator);
        self.color_pool.deinit(self.allocator);
        self.number_pool.deinit(self.allocator);
        self.callable_payload_pool.deinit(self.allocator);
        self.list_meta_pool.deinit(self.allocator);
        self.string_flags_pool.deinit(self.allocator);
        self.intern_pool.deinit(self.allocator);
    }

    fn context(self: *ListTestHarness) BuiltinContext {
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

fn pushTestList(ctx: *BuiltinContext, items: []const Value, separator: ListSeparator) !Value {
    const handle: u32 = @intCast(ctx.list_pool.items.len);
    const owned = try ctx.allocator.dupe(Value, items);
    try ctx.list_pool.append(ctx.allocator, owned);
    return Value.listWithMeta(handle, separator, false, false);
}

test "list.join coerces slash-free rest-like slash lists" {
    var harness = try ListTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();

    const slash_a_items = [_]Value{ Value.numberUnitless(1), Value.numberUnitless(2) };
    const slash_b_items = [_]Value{ Value.numberUnitless(3), Value.numberUnitless(4) };
    const slash_a = try pushTestList(&ctx, slash_a_items[0..], .slash);
    const slash_b = try pushTestList(&ctx, slash_b_items[0..], .slash);

    const args = [_]Value{ slash_a, slash_b };
    const names = [_]InternId{ .none, .none };
    const result = try list_join(&ctx, args[0..], names[0..]);

    try testing.expectEqual(@as(u8, @intFromEnum(ListSeparator.space)), @as(u8, @intFromEnum(result.listSeparator(ctx.list_meta_pool.items))));
    const out_items = ctx.list_pool.items[result.listHandle()];
    try testing.expectEqual(@as(usize, 2), out_items.len);
    try testing.expectEqual(.number, out_items[0].kind());
    try testing.expectEqual(.number, out_items[1].kind());
    try testing.expectApproxEqAbs(@as(f64, 0.5), out_items[0].asF64(ctx.number_pool), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.75), out_items[1].asF64(ctx.number_pool), 1e-12);
}

test "list.nth coerces slash-free slash-list element" {
    var harness = try ListTestHarness.init(testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();

    const slash_items = [_]Value{ Value.numberUnitless(1), Value.numberUnitless(2) };
    const slash_val = try pushTestList(&ctx, slash_items[0..], .slash);
    const outer_items = [_]Value{ slash_val, Value.numberUnitless(3) };
    const outer = try pushTestList(&ctx, outer_items[0..], .space);

    const args = [_]Value{ outer, Value.numberUnitless(1) };
    const names = [_]InternId{ .none, .none };
    const result = try list_nth(&ctx, args[0..], names[0..]);

    try testing.expectEqual(.number, result.kind());
    try testing.expectApproxEqAbs(@as(f64, 0.5), result.asF64(ctx.number_pool), 1e-12);
}
