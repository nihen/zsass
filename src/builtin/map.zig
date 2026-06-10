//! sass:map builtins.
const std = @import("std");
const shared = @import("shared.zig");
const value_mod = @import("../runtime/value.zig");
const intern_pool_mod = @import("../runtime/intern_pool.zig");

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

/// "Naive string key" (no calc-arg marker / no named-color-literal bit / no quoted+escape)
/// Returns the raw key bytes if . Two keys that satisfy this are bytes equivalent  <=>  `valueEql` equivalent.
/// otherwise key (non-string, with marker, named-color literal, quoted with escape) is
/// Return null and do not put it in hash index, process it with linear scan bucket for special key.
fn plainStringKeyBytes(pool: *InternPool, v: Value) ?[]const u8 {
    if (v.kind() != .string) return null;
    if (v.stringNamedColorLiteral(value_mod.empty_string_flags_pool)) return null;
    const id = v.stringIntern();
    if (pool.hasCalcMarkerPrefix(id)) return null;
    if (v.stringQuoted(value_mod.empty_string_flags_pool) and pool.hasBackslash(id)) return null;
    return pool.get(id);
}

const pushListWithMeta = shared.pushListWithMeta;

fn pushMapPairs(ctx: *BuiltinContext, pairs: []const Value) BuiltinError!Value {
    const separator: ListSeparator = if (pairs.len == 0) .undecided else .comma;
    return pushListWithMeta(ctx, pairs, separator, false, true);
}

/// Push an exactly-sized owned pair buffer without re-duplicating it.
fn pushMapPairsOwned(ctx: *BuiltinContext, owned: []Value) BuiltinError!Value {
    const separator: ListSeparator = if (owned.len == 0) .undecided else .comma;
    return shared.pushListOwnedWithMeta(ctx, owned, separator, false, true);
}

/// Shrink an owned result buffer to its used length before handing it to the
/// pool, so a later `allocator.free(row)` sees the exact allocation.
fn shrinkOwned(ctx: *BuiltinContext, buf: []Value, used: usize) BuiltinError![]Value {
    if (used == buf.len) return buf;
    return ctx.allocator.realloc(buf, used) catch |err| {
        ctx.allocator.free(buf);
        return err;
    };
}

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

const calc_meta_mask: u8 = intern_pool_mod.meta_has_calc_paren | intern_pool_mod.meta_has_calc_marker;

/// Needle analysis hoisted out of map key scans. A "plain" needle is a
/// non-named-color string without calc marker/`calc(` text and without
/// quoted backslash escapes; for two such strings `valueEql` reduces to a
/// byte comparison, so the per-key compare can skip the generic equality
/// machinery. Everything else scans with `valueEql` unchanged.
const ScanNeedle = struct {
    plain: bool,
    id: InternId = .none,
    bytes: []const u8 = &.{},

    fn from(ctx: *BuiltinContext, key: Value) ScanNeedle {
        if (key.kind() != .string) return .{ .plain = false };
        if (key.stringNamedColorLiteral(value_mod.empty_string_flags_pool)) return .{ .plain = false };
        const id = key.stringIntern();
        if ((ctx.intern_pool.calcMetaByte(id) & calc_meta_mask) != 0) return .{ .plain = false };
        if (key.stringQuoted(value_mod.empty_string_flags_pool) and ctx.intern_pool.hasBackslash(id)) return .{ .plain = false };
        return .{ .plain = true, .id = id, .bytes = ctx.intern_pool.get(id) };
    }
};

/// First matching key's pair index in `pairs[0..len]`, or null.
/// Mirrors a `valueEql` linear scan exactly; the plain-needle branch only
/// short-circuits cases proven equivalent to a byte comparison.
fn scanPairsForKey(ctx: *BuiltinContext, pairs: []const Value, len: usize, key: Value, needle: ScanNeedle) ?usize {
    var i: usize = 0;
    if (needle.plain) {
        while (i + 1 < len) : (i += 2) {
            const cand = pairs[i];
            if (cand.kind() != .string) continue;
            // Same named-color-literal flag ordering as valueEqInner: flag
            // mismatch is unequal even for an identical intern id.
            if (cand.stringNamedColorLiteral(value_mod.empty_string_flags_pool)) continue;
            const cid = cand.stringIntern();
            if (cid == needle.id) return i;
            if ((ctx.intern_pool.calcMetaByte(cid) & calc_meta_mask) != 0 or
                (cand.stringQuoted(value_mod.empty_string_flags_pool) and ctx.intern_pool.hasBackslash(cid)))
            {
                // Non-plain candidate (calc text/marker or quoted escapes)
                // can still equal the needle after normalization.
                if (mapKeyEq(ctx, cand, key)) return i;
                continue;
            }
            const cb = ctx.intern_pool.get(cid);
            if (cb.len == needle.bytes.len and std.mem.eql(u8, cb, needle.bytes)) return i;
        }
        return null;
    }
    while (i + 1 < len) : (i += 2) {
        if (mapKeyEq(ctx, pairs[i], key)) return i;
    }
    return null;
}

fn lookupValue(ctx: *BuiltinContext, pairs: []const Value, key: Value) ?Value {
    const needle = ScanNeedle.from(ctx, key);
    const idx = scanPairsForKey(ctx, pairs, pairs.len, key, needle) orelse return null;
    return pairs[idx + 1];
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

    const out_buf = try ctx.allocator.alloc(Value, base.len + overlay.len);
    @memcpy(out_buf[0..base.len], base);
    var len: usize = base.len;

    var i: usize = 0;
    while (i + 1 < overlay.len) : (i += 2) {
        const key = overlay[i];
        const val = overlay[i + 1];
        const needle = ScanNeedle.from(ctx, key);
        if (scanPairsForKey(ctx, out_buf, len, key, needle)) |oi| {
            out_buf[oi + 1] = val;
        } else {
            out_buf[len] = key;
            out_buf[len + 1] = val;
            len += 2;
        }
    }
    return pushMapPairsOwned(ctx, try shrinkOwned(ctx, out_buf, len));
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
    const pair_region = pairs.len - (pairs.len % 2);
    const out_buf = try ctx.allocator.alloc(Value, pair_region + 2);
    @memcpy(out_buf[0..pair_region], pairs[0..pair_region]);
    var len: usize = pair_region;
    const needle = ScanNeedle.from(ctx, key);
    if (scanPairsForKey(ctx, out_buf, len, key, needle)) |i| {
        out_buf[i + 1] = new_val;
    } else {
        out_buf[len] = key;
        out_buf[len + 1] = new_val;
        len += 2;
    }
    return pushMapPairsOwned(ctx, try shrinkOwned(ctx, out_buf, len));
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
    return pushMapPairs(ctx, pairs[0 .. pairs.len - (pairs.len % 2)]);
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

    const out_buf = try ctx.allocator.alloc(Value, map_pairs.len - (map_pairs.len % 2));
    var len: usize = 0;
    var i: usize = 0;
    outer: while (i + 1 < map_pairs.len) : (i += 2) {
        for (keys_to_remove.items) |rk| {
            if (mapKeyEq(ctx, map_pairs[i], rk)) continue :outer;
        }
        out_buf[len] = map_pairs[i];
        out_buf[len + 1] = map_pairs[i + 1];
        len += 2;
    }
    return pushMapPairsOwned(ctx, try shrinkOwned(ctx, out_buf, len));
}

pub fn map_keys(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try expectArity(args, 1);
    const pairs = try expectMapArg(ctx, "map", args[0]);
    const out_buf = try ctx.allocator.alloc(Value, pairs.len / 2);
    var i: usize = 0;
    var j: usize = 0;
    while (i + 1 < pairs.len) : (i += 2) {
        out_buf[j] = pairs[i];
        j += 1;
    }
    return shared.pushListOwnedWithMeta(ctx, out_buf, .comma, false, false);
}

pub fn map_values(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    try expectArity(args, 1);
    const pairs = try expectMapArg(ctx, "map", args[0]);
    const out_buf = try ctx.allocator.alloc(Value, pairs.len / 2);
    var i: usize = 0;
    var j: usize = 0;
    while (i + 1 < pairs.len) : (i += 2) {
        out_buf[j] = pairs[i + 1];
        j += 1;
    }
    return shared.pushListOwnedWithMeta(ctx, out_buf, .comma, false, false);
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
