//! sass:map builtins.
const std = @import("std");
const shared = @import("shared.zig");
const value_mod = @import("../runtime/value.zig");

const Value = shared.Value;
const BuiltinContext = shared.BuiltinContext;
const BuiltinError = shared.BuiltinError;
const InternId = shared.InternId;
const InternPool = shared.InternPool;
const ListSeparator = shared.ListSeparator;

const badArity = shared.badArity;
const expectArity = shared.expectArity;
const valueEql = shared.valueEql;
const bindNamedOrPositionalArgsStrict = shared.bindNamedOrPositionalArgsStrict;
const reportArgumentTypeMismatch = shared.reportArgumentTypeMismatch;
const argNameMatches = shared.argNameMatches;

const calc_arg_marker = "\x01zsass-calc-arg:";
const calc_interp_marker = "\x01zsass-calc-interp:";

/// "Naive string key" (no calc-arg marker / no named-color-literal bit / no quoted+escape)
/// Returns the raw key bytes if . Two keys that satisfy this are bytes equivalent  <=>  `valueEql` equivalent.
/// otherwise key (non-string, with marker, named-color literal, quoted with escape) is
/// Return null and do not put it in hash index, process it with linear scan bucket for special key.
fn plainStringKeyBytes(pool: *const InternPool, v: Value) ?[]const u8 {
    if (v.kind() != .string) return null;
    if (v.stringNamedColorLiteral(value_mod.empty_string_flags_pool)) return null;
    const raw = pool.get(v.stringIntern());
    if (std.mem.startsWith(u8, raw, calc_arg_marker) or std.mem.startsWith(u8, raw, calc_interp_marker)) return null;
    if (v.stringQuoted(value_mod.empty_string_flags_pool) and pool.hasBackslash(v.stringIntern())) return null;
    return raw;
}

const pushListWithMeta = shared.pushListWithMeta;

fn pushMapPairs(ctx: *BuiltinContext, pairs: []const Value) BuiltinError!Value {
    const separator: ListSeparator = if (pairs.len == 0) .undecided else .comma;
    return pushListWithMeta(ctx, pairs, separator, false, true);
}

const pushCommaList = shared.pushCommaList;

fn mapPairsStrict(ctx: *BuiltinContext, v: Value) BuiltinError![]const Value {
    if (v.kind() != .list) return error.BuiltinType;
    return ctx.list_pool.items[v.listHandle()];
}

fn expectMapArg(ctx: *BuiltinContext, param_name: []const u8, v: Value) BuiltinError![]const Value {
    return mapPairsStrict(ctx, v) catch |err| switch (err) {
        error.BuiltinType => reportArgumentTypeMismatch(ctx, param_name, v, "map"),
        else => err,
    };
}

fn mapKeyEq(ctx: *BuiltinContext, a: Value, b: Value) bool {
    return valueEql(ctx, a, b);
}

fn lookupValue(ctx: *BuiltinContext, pairs: []const Value, key: Value) ?Value {
    var i: usize = 0;
    while (i + 1 < pairs.len) : (i += 2) {
        if (mapKeyEq(ctx, pairs[i], key)) return pairs[i + 1];
    }
    return null;
}

/// O(1) lookup using hash index associated with list_handle (fallback is linear).
/// Create an index only when map is large enough (>= 16 pairs) and all keys are simple strings.
fn lookupValueHandled(ctx: *BuiltinContext, map_handle: u32, pairs: []const Value, key: Value) ?Value {
    // For small maps, linear scan is cheaper than hash construction
    if (pairs.len < 32) return lookupValue(ctx, pairs, key);

    const idx_opt = ensureMapLookupIndex(ctx, map_handle, pairs);
    if (idx_opt) |idx| {
        // Cannot be retrieved with hash unless overlay key is a simple string (fallback: linear)
        if (plainStringKeyBytes(ctx.intern_pool, key)) |canon| {
            if (idx.get(canon)) |pair_idx| {
                const pi: usize = @intCast(pair_idx);
                if (pi + 1 < pairs.len) return pairs[pi + 1];
            }
            return null;
        }
    }
    //index creation failure or non-naive key  ->  linear
    return lookupValue(ctx, pairs, key);
}

fn ensureMapLookupIndex(
    ctx: *BuiltinContext,
    map_handle: u32,
    pairs: []const Value,
) ?*std.StringHashMapUnmanaged(u32) {
    const cache = ctx.map_lookup_index_cache orelse return null;
    const gop = cache.getOrPut(ctx.allocator, map_handle) catch return null;
    if (gop.found_existing) return gop.value_ptr.*;

    // First time. Assemble the index while checking that all keys are simple strings.
    // If even one non-naive key is mixed in, give up on building the index and record null in the cache
    // From then on, process in linear manner.
    const idx_heap = ctx.allocator.create(std.StringHashMapUnmanaged(u32)) catch {
        gop.value_ptr.* = null;
        return null;
    };
    idx_heap.* = .empty;
    var ok = true;
    var i: usize = 0;
    while (i + 1 < pairs.len) : (i += 2) {
        const canon = plainStringKeyBytes(ctx.intern_pool, pairs[i]) orelse {
            ok = false;
            break;
        };
        // It is assumed that key duplication (duplicate key in map) is eliminated when constructing the map, but
        // The semantics of linear scan is to overwrite it with the last index inserted just in case
        //Different from (lookupValue returns the first matching index). linear is "first match"
        // Therefore, if there is a duplicate, index is registered only the first time (getOrPut, not put).
        idx_heap.put(ctx.allocator, canon, @intCast(i)) catch {
            ok = false;
            break;
        };
    }
    if (!ok) {
        idx_heap.deinit(ctx.allocator);
        ctx.allocator.destroy(idx_heap);
        gop.value_ptr.* = null;
        return null;
    }
    gop.value_ptr.* = idx_heap;
    return idx_heap;
}

fn hasKey(ctx: *BuiltinContext, pairs: []const Value, key: Value) bool {
    return lookupValue(ctx, pairs, key) != null;
}

fn cloneValueDeep(ctx: *BuiltinContext, v: Value) BuiltinError!Value {
    _ = ctx;
    // Sass values are immutable.  Map builtins only need to allocate the new
    // list/map nodes on the modified path; unchanged subtrees can be shared
    // by handle instead of deep-cloned into list_pool on every operation.
    return v;
}

fn isMapLike(v: Value) bool {
    return v.kind() == .list;
}

fn mergeTwoMapsShallowPairs(ctx: *BuiltinContext, base: []const Value, overlay: []const Value) BuiltinError!Value {
    // If you create a hash every time with a small overlay + a large base, the construction cost will exceed the gain
    // (map-set pattern: overlay=1, base=thousands repeated).
    // Create a hash index only if the number of keys in overlay >= 4 and base is large enough.
    const overlay_pairs = overlay.len / 2;
    const base_pairs_count = base.len / 2;
    const use_hash = overlay_pairs >= 4 and base_pairs_count >= 16;
    if (use_hash) {
        return mergeTwoMapsShallowPairsHashed(ctx, base, overlay);
    }

    var out: std.ArrayListUnmanaged(Value) = .empty;
    defer out.deinit(ctx.allocator);
    try out.ensureTotalCapacity(ctx.allocator, base.len + overlay.len);
    try out.appendSlice(ctx.allocator, base);

    var i: usize = 0;
    while (i + 1 < overlay.len) : (i += 2) {
        const key = overlay[i];
        const val = overlay[i + 1];
        var replaced = false;
        var oi: usize = 0;
        while (oi + 1 < out.items.len) : (oi += 2) {
            if (mapKeyEq(ctx, out.items[oi], key)) {
                out.items[oi + 1] = try cloneValueDeep(ctx, val);
                replaced = true;
                break;
            }
        }
        if (!replaced) {
            try out.append(ctx.allocator, key);
            try out.append(ctx.allocator, try cloneValueDeep(ctx, val));
        }
    }
    return pushMapPairs(ctx, out.items);
}

fn mergeTwoMapsShallowPairsHashed(ctx: *BuiltinContext, base: []const Value, overlay: []const Value) BuiltinError!Value {
    var out: std.ArrayListUnmanaged(Value) = .empty;
    defer out.deinit(ctx.allocator);
    try out.ensureTotalCapacity(ctx.allocator, base.len + overlay.len);
    try out.appendSlice(ctx.allocator, base);

    //plain_index: key position of bytes  ->  out of "plain string key" (pair first index).
    // special_indices: key position for non-naive keys (non-string / marker / named-color / escape).
    var plain_index: std.StringHashMapUnmanaged(usize) = .empty;
    defer plain_index.deinit(ctx.allocator);
    var special_indices: std.ArrayListUnmanaged(usize) = .empty;
    defer special_indices.deinit(ctx.allocator);

    {
        var bi: usize = 0;
        while (bi + 1 < base.len) : (bi += 2) {
            if (plainStringKeyBytes(ctx.intern_pool, base[bi])) |canon| {
                try plain_index.put(ctx.allocator, canon, bi);
            } else {
                try special_indices.append(ctx.allocator, bi);
            }
        }
    }

    var i: usize = 0;
    while (i + 1 < overlay.len) : (i += 2) {
        const key = overlay[i];
        const val = overlay[i + 1];
        var replace_idx: ?usize = null;

        if (plainStringKeyBytes(ctx.intern_pool, key)) |canon| {
            // Naive overlay key: specials linear scan compared to non-naive base (rare),
            // O(1) lookup of plain_index if not found.
            for (special_indices.items) |si| {
                if (mapKeyEq(ctx, out.items[si], key)) {
                    replace_idx = si;
                    break;
                }
            }
            if (replace_idx == null) {
                if (plain_index.get(canon)) |idx| {
                    replace_idx = idx;
                }
            }
        } else {
            // Non-naive overlay key: entire linear scan.
            var oi: usize = 0;
            while (oi + 1 < out.items.len) : (oi += 2) {
                if (mapKeyEq(ctx, out.items[oi], key)) {
                    replace_idx = oi;
                    break;
                }
            }
        }

        if (replace_idx) |idx| {
            out.items[idx + 1] = try cloneValueDeep(ctx, val);
        } else {
            const new_idx = out.items.len;
            try out.append(ctx.allocator, key);
            try out.append(ctx.allocator, try cloneValueDeep(ctx, val));
            if (plainStringKeyBytes(ctx.intern_pool, key)) |canon| {
                try plain_index.put(ctx.allocator, canon, new_idx);
            } else {
                try special_indices.append(ctx.allocator, new_idx);
            }
        }
    }
    return pushMapPairs(ctx, out.items);
}

fn deepMergeTwoMaps(ctx: *BuiltinContext, base: []const Value, overlay: []const Value) BuiltinError!Value {
    var out: std.ArrayListUnmanaged(Value) = .empty;
    defer out.deinit(ctx.allocator);

    var bi: usize = 0;
    while (bi + 1 < base.len) : (bi += 2) {
        const bk = base[bi];
        const bv = base[bi + 1];
        if (lookupOverlayValue(ctx, overlay, bk)) |ov| {
            if (isMapLike(bv) and isMapLike(ov)) {
                const binner = ctx.list_pool.items[bv.listHandle()];
                const oinner = ctx.list_pool.items[ov.listHandle()];
                const merged = try deepMergeTwoMaps(ctx, binner, oinner);
                try out.append(ctx.allocator, bk);
                try out.append(ctx.allocator, merged);
            } else {
                try out.append(ctx.allocator, bk);
                try out.append(ctx.allocator, try cloneValueDeep(ctx, ov));
            }
        } else {
            try out.append(ctx.allocator, bk);
            try out.append(ctx.allocator, try cloneValueDeep(ctx, bv));
        }
    }

    var oi: usize = 0;
    while (oi + 1 < overlay.len) : (oi += 2) {
        const ok = overlay[oi];
        const ov = overlay[oi + 1];
        if (!hasKey(ctx, base, ok)) {
            try out.append(ctx.allocator, ok);
            try out.append(ctx.allocator, try cloneValueDeep(ctx, ov));
        }
    }

    return pushMapPairs(ctx, out.items);
}

fn lookupOverlayValue(ctx: *BuiltinContext, overlay: []const Value, key: Value) ?Value {
    return lookupValue(ctx, overlay, key);
}

fn coerceBasePairsForNestedMerge(ctx: *BuiltinContext, base: Value) BuiltinError![]const Value {
    if (base.kind() == .list) {
        return ctx.list_pool.items[base.listHandle()];
    }
    return &[_]Value{};
}

fn nestedMapMerge(ctx: *BuiltinContext, base: Value, keys: []const Value, overlay: Value) BuiltinError!Value {
    const base_pairs = try coerceBasePairsForNestedMerge(ctx, base);

    if (keys.len == 0) {
        const overlay_pairs: []const Value = if (overlay.kind() == .list)
            ctx.list_pool.items[overlay.listHandle()]
        else
            return cloneValueDeep(ctx, overlay);
        return mergeTwoMapsShallowPairs(ctx, base_pairs, overlay_pairs);
    }

    var out: std.ArrayListUnmanaged(Value) = .empty;
    defer out.deinit(ctx.allocator);
    try out.ensureTotalCapacity(ctx.allocator, base_pairs.len + 2);

    var found_key = false;
    var i: usize = 0;
    while (i + 1 < base_pairs.len) : (i += 2) {
        const k = base_pairs[i];
        const v = base_pairs[i + 1];
        if (mapKeyEq(ctx, k, keys[0])) {
            found_key = true;
            const sub = try nestedMapMerge(ctx, v, keys[1..], overlay);
            try out.append(ctx.allocator, k);
            try out.append(ctx.allocator, sub);
        } else {
            try out.append(ctx.allocator, k);
            try out.append(ctx.allocator, try cloneValueDeep(ctx, v));
        }
    }

    if (!found_key) {
        const nested: Value = blk: {
            if (keys.len > 1) {
                const empty = try pushMapPairs(ctx, &[_]Value{});
                break :blk try nestedMapMerge(ctx, empty, keys[1..], overlay);
            } else {
                break :blk try cloneValueDeep(ctx, overlay);
            }
        };
        try out.append(ctx.allocator, keys[0]);
        try out.append(ctx.allocator, nested);
    }

    return pushMapPairs(ctx, out.items);
}

fn replaceOrInsertKey(ctx: *BuiltinContext, pairs: []const Value, key: Value, new_val: Value) BuiltinError!Value {
    var out: std.ArrayListUnmanaged(Value) = .empty;
    defer out.deinit(ctx.allocator);
    var replaced = false;
    var i: usize = 0;
    while (i + 1 < pairs.len) : (i += 2) {
        if (!replaced and mapKeyEq(ctx, pairs[i], key)) {
            try out.append(ctx.allocator, pairs[i]);
            try out.append(ctx.allocator, try cloneValueDeep(ctx, new_val));
            replaced = true;
        } else {
            try out.append(ctx.allocator, pairs[i]);
            try out.append(ctx.allocator, try cloneValueDeep(ctx, pairs[i + 1]));
        }
    }
    if (!replaced) {
        try out.append(ctx.allocator, key);
        try out.append(ctx.allocator, try cloneValueDeep(ctx, new_val));
    }
    return pushMapPairs(ctx, out.items);
}

fn mapSetPathImmutable(
    ctx: *BuiltinContext,
    base: Value,
    keys: []const Value,
    new_val: Value,
    allow_replace_non_map: bool,
) BuiltinError!Value {
    std.debug.assert(keys.len > 0);

    const base_pairs: []const Value = blk: {
        if (base.kind() != .list) {
            if (!allow_replace_non_map) return error.BuiltinType;
            break :blk &[_]Value{};
        }
        break :blk ctx.list_pool.items[base.listHandle()];
    };

    if (keys.len == 1) {
        return replaceOrInsertKey(ctx, base_pairs, keys[0], new_val);
    }

    var out: std.ArrayListUnmanaged(Value) = .empty;
    defer out.deinit(ctx.allocator);
    try out.ensureTotalCapacity(ctx.allocator, base_pairs.len + 2);

    var found_key = false;
    var i: usize = 0;
    while (i + 1 < base_pairs.len) : (i += 2) {
        const k = base_pairs[i];
        const v = base_pairs[i + 1];
        if (valueEql(ctx, k, keys[0])) {
            found_key = true;
            const sub = try mapSetPathImmutable(ctx, v, keys[1..], new_val, true);
            try out.append(ctx.allocator, k);
            try out.append(ctx.allocator, sub);
        } else {
            try out.append(ctx.allocator, k);
            try out.append(ctx.allocator, try cloneValueDeep(ctx, v));
        }
    }

    if (!found_key) {
        const empty = try pushMapPairs(ctx, &[_]Value{});
        const nested = try mapSetPathImmutable(ctx, empty, keys[1..], new_val, true);
        try out.append(ctx.allocator, keys[0]);
        try out.append(ctx.allocator, nested);
    }

    return pushMapPairs(ctx, out.items);
}

fn clonePairsContent(ctx: *BuiltinContext, pairs: []const Value) BuiltinError!Value {
    var out: std.ArrayListUnmanaged(Value) = .empty;
    defer out.deinit(ctx.allocator);
    var i: usize = 0;
    while (i + 1 < pairs.len) : (i += 2) {
        try out.append(ctx.allocator, pairs[i]);
        try out.append(ctx.allocator, try cloneValueDeep(ctx, pairs[i + 1]));
    }
    return pushMapPairs(ctx, out.items);
}

fn mapDeepRemovePathImmutable(ctx: *BuiltinContext, base_pairs: []const Value, keys: []const Value) BuiltinError!Value {
    std.debug.assert(keys.len > 0);

    if (keys.len == 1) {
        var out: std.ArrayListUnmanaged(Value) = .empty;
        defer out.deinit(ctx.allocator);
        var i: usize = 0;
        while (i + 1 < base_pairs.len) : (i += 2) {
            if (valueEql(ctx, base_pairs[i], keys[0])) continue;
            try out.append(ctx.allocator, base_pairs[i]);
            try out.append(ctx.allocator, base_pairs[i + 1]);
        }
        return pushMapPairs(ctx, out.items);
    }

    const inner_val = lookupValue(ctx, base_pairs, keys[0]) orelse {
        return clonePairsContent(ctx, base_pairs);
    };
    if (!isMapLike(inner_val)) {
        return clonePairsContent(ctx, base_pairs);
    }
    const inner_pairs = ctx.list_pool.items[inner_val.listHandle()];
    const new_inner = try mapDeepRemovePathImmutable(ctx, inner_pairs, keys[1..]);

    var out: std.ArrayListUnmanaged(Value) = .empty;
    defer out.deinit(ctx.allocator);
    var i: usize = 0;
    while (i + 1 < base_pairs.len) : (i += 2) {
        const k = base_pairs[i];
        const v = base_pairs[i + 1];
        if (valueEql(ctx, k, keys[0])) {
            try out.append(ctx.allocator, k);
            try out.append(ctx.allocator, new_inner);
        } else {
            try out.append(ctx.allocator, k);
            try out.append(ctx.allocator, try cloneValueDeep(ctx, v));
        }
    }
    return pushMapPairs(ctx, out.items);
}

pub fn map_get(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    if (args.len < 2) return badArity(2, args.len);
    const pairs = try expectMapArg(ctx, "map", args[0]);
    if (pairs.len == 0) return Value.nil_v;

    var cur: []const Value = pairs;
    var cur_handle: u32 = args[0].listHandle();
    for (args[1 .. args.len - 1]) |key| {
        const next = lookupValueHandled(ctx, cur_handle, cur, key) orelse return Value.nil_v;
        if (next.kind() != .list) return Value.nil_v;
        cur = ctx.list_pool.items[next.listHandle()];
        cur_handle = next.listHandle();
    }
    return lookupValueHandled(ctx, cur_handle, cur, args[args.len - 1]) orelse Value.nil_v;
}

pub fn map_has_key(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    if (args.len < 2) return badArity(2, args.len);
    const pairs = try expectMapArg(ctx, "map", args[0]);
    if (pairs.len == 0) return Value.false_v;

    var cur: []const Value = pairs;
    var cur_handle: u32 = args[0].listHandle();
    for (args[1 .. args.len - 1]) |key| {
        const next = lookupValueHandled(ctx, cur_handle, cur, key) orelse return Value.false_v;
        if (next.kind() != .list) return Value.false_v;
        cur = ctx.list_pool.items[next.listHandle()];
        cur_handle = next.listHandle();
    }
    return if (lookupValueHandled(ctx, cur_handle, cur, args[args.len - 1]) != null) Value.true_v else Value.false_v;
}

pub fn map_merge(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    if (args.len < 2) return badArity(2, args.len);

    if (args.len == 2) {
        const first = try expectMapArg(ctx, "map1", args[0]);
        const second = try expectMapArg(ctx, "map2", args[1]);
        return mergeTwoMapsShallowPairs(ctx, first, second);
    }

    _ = try expectMapArg(ctx, "map1", args[0]);
    _ = try expectMapArg(ctx, "map2", args[args.len - 1]);
    return nestedMapMerge(ctx, args[0], args[1 .. args.len - 1], args[args.len - 1]);
}

pub fn map_remove(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    if (args.len < 1) return badArity(1, args.len);

    const map_pairs = try expectMapArg(ctx, "map", args[0]);

    if (args.len == 1) {
        return clonePairsContent(ctx, map_pairs);
    }

    var keys_to_remove: std.ArrayListUnmanaged(Value) = .empty;
    defer keys_to_remove.deinit(ctx.allocator);
    try keys_to_remove.ensureTotalCapacity(ctx.allocator, args.len - 1);

    var saw_positional = false;
    for (args[1..], 0..) |arg, j| {
        const arg_idx = j + 1;
        const name_id: InternId = if (arg_idx < arg_names.len) arg_names[arg_idx] else .none;
        if (name_id != .none) {
            if (argNameMatches(ctx, name_id, "key")) {
                if (saw_positional) return error.BuiltinArity;
                try keys_to_remove.append(ctx.allocator, arg);
            } else if (argNameMatches(ctx, name_id, "map")) {
                return error.BuiltinArity;
            } else {
                return error.BuiltinArity;
            }
        } else {
            saw_positional = true;
            try keys_to_remove.append(ctx.allocator, arg);
        }
    }

    var tmp: std.ArrayListUnmanaged(Value) = .empty;
    defer tmp.deinit(ctx.allocator);

    var i: usize = 0;
    outer: while (i + 1 < map_pairs.len) : (i += 2) {
        for (keys_to_remove.items) |rk| {
            if (mapKeyEq(ctx, map_pairs[i], rk)) continue :outer;
        }
        try tmp.append(ctx.allocator, map_pairs[i]);
        try tmp.append(ctx.allocator, map_pairs[i + 1]);
    }
    return pushMapPairs(ctx, tmp.items);
}

pub fn map_keys(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try expectArity(args, 1);
    const pairs = try expectMapArg(ctx, "map", args[0]);
    var keys_out: std.ArrayListUnmanaged(Value) = .empty;
    defer keys_out.deinit(ctx.allocator);
    var i: usize = 0;
    while (i + 1 < pairs.len) : (i += 2) {
        try keys_out.append(ctx.allocator, pairs[i]);
    }
    return pushCommaList(ctx, keys_out.items);
}

pub fn map_values(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try expectArity(args, 1);
    const pairs = try expectMapArg(ctx, "map", args[0]);
    var vals: std.ArrayListUnmanaged(Value) = .empty;
    defer vals.deinit(ctx.allocator);
    var i: usize = 0;
    while (i + 1 < pairs.len) : (i += 2) {
        try vals.append(ctx.allocator, pairs[i + 1]);
    }
    return pushCommaList(ctx, vals.items);
}

pub fn map_deep_merge(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try expectArity(args, 2);
    const first = try expectMapArg(ctx, "map1", args[0]);
    const second = try expectMapArg(ctx, "map2", args[1]);
    return deepMergeTwoMaps(ctx, first, second);
}

pub fn map_deep_remove(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    if (args.len < 2) return badArity(2, args.len);
    const base_pairs = try expectMapArg(ctx, "map", args[0]);
    return mapDeepRemovePathImmutable(ctx, base_pairs, args[1..]);
}

pub fn map_set(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    if (args.len < 3) return badArity(3, args.len);

    if (args.len == 3) {
        const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{ "map", "key", "value" }, 3);
        const m = bound[0].?;
        const k = bound[1].?;
        const v = bound[2].?;
        _ = try expectMapArg(ctx, "map", m);
        return mapSetPathImmutable(ctx, m, &[_]Value{k}, v, false);
    }

    const key_count = args.len - 2;
    const allow_replace = key_count > 1;
    _ = try expectMapArg(ctx, "map", args[0]);
    return mapSetPathImmutable(ctx, args[0], args[1 .. args.len - 1], args[args.len - 1], allow_replace);
}
