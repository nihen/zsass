const std = @import("std");

fn fuzzyNumberOrder(a: f64, b: f64) std.math.Order {
    if (std.math.approxEqAbs(f64, a, b, 1e-11)) return .eq;
    return std.math.order(a, b);
}
const builtin_mod = @import("../builtin/mod.zig");
const meta_dispatch_abi = @import("../builtin/meta_dispatch_abi.zig");
const color_mod = @import("../color/color.zig");
const color_format = @import("../color/color_format.zig");
const value_mod = @import("../runtime/value.zig");
const value_format = @import("../runtime/value_format.zig");
const css_utils = @import("../runtime/css_utils.zig");
const intern_pool_mod = @import("../runtime/intern_pool.zig");
const value_eq = @import("../runtime/value_eq.zig");
const InternId = intern_pool_mod.InternId;
const InternPool = intern_pool_mod.InternPool;

pub const Value = value_mod.Value;
const ColorEntry = value_mod.ColorEntry;

pub const Error = error{
    OutOfMemory,
    NonStaticExpr,
    SassError,
    InternalError,
};

const literal_string_quoted_bit: u32 = 0x8000_0000;
const literal_string_named_color_bit: u32 = 0x4000_0000;
const literal_string_raw_text_bit: u32 = 0x2000_0000;
const literal_string_flag_mask: u32 =
    literal_string_quoted_bit | literal_string_named_color_bit | literal_string_raw_text_bit;
const calc_arg_marker = "\x01zsass-calc-arg:";

const LiteralStringPayload = struct {
    id: InternId,
    quoted: bool,
    named_color_literal: bool,
    raw_text: bool,
};

fn unpackLiteralStringPayload(payload: u32) LiteralStringPayload {
    return .{
        .id = @enumFromInt(payload & ~literal_string_flag_mask),
        .quoted = (payload & literal_string_quoted_bit) != 0,
        .named_color_literal = (payload & literal_string_named_color_bit) != 0,
        .raw_text = (payload & literal_string_raw_text_bit) != 0,
    };
}

pub fn eval(env: anytype, prog: anytype, expr_idx: anytype) Error!Value {
    const ex = prog.exprs.items[expr_idx];
    return switch (ex.kind) {
        .literal_number => blk: {
            const n = prog.number_pool.items[ex.payload];
            const bits: u64 = (@as(u64, n.hi) << 32) | @as(u64, n.lo);
            const v: f64 = @bitCast(bits);
            break :blk try Value.number(v, n.unit_id, env.numberPool(), env.poolAlloc());
        },
        .literal_string => blk: {
            const lit = unpackLiteralStringPayload(ex.payload);
            break :blk Value.stringWithFlagsEx(lit.id, lit.quoted, false, lit.named_color_literal);
        },
        .literal_color => try evalLiteralColor(env, prog, ex.payload),
        .literal_bool => if (ex.payload != 0) Value.true_v else Value.false_v,
        .literal_null => Value.nil_v,
        .var_ref => env.lookupVar(ex.payload) orelse return error.NonStaticExpr,
        .cross_var_ref => blk: {
            const cross = prog.cross_var_refs.items[ex.payload];
            break :blk env.lookupCrossVar(cross.module_id, cross.slot) orelse return error.NonStaticExpr;
        },
        .binary => try evalBinary(env, prog, ex.payload),
        .unary => try evalUnary(env, prog, ex.payload),
        .interp => try evalInterp(env, prog, ex.payload),
        .list => try evalList(env, prog, ex.payload),
        .if_builtin => try evalIfBuiltin(env, prog, ex.payload),
        .builtin_call => try evalBuiltinCall(env, prog, ex.payload),
        .call => try evalCssCall(env, prog, ex.payload),
        else => error.NonStaticExpr,
    };
}

pub fn valueToInterpolationTextOwned(env: anytype, v: Value) Error![]const u8 {
    return valueToInterpolationText(env, v);
}

pub fn valueEq(env: anytype, a: Value, b: Value) bool {
    return value_eq.valueEqEnv(env, a, b);
}

fn evalLiteralColor(env: anytype, prog: anytype, payload: u32) Error!Value {
    const color_pool = env.colorPool() orelse return error.NonStaticExpr;
    const lit = prog.color_literals.items[payload];
    const rgba = lit.rgba;
    const r: u8 = @intCast((rgba >> 24) & 0xff);
    const g: u8 = @intCast((rgba >> 16) & 0xff);
    const b: u8 = @intCast((rgba >> 8) & 0xff);
    const a: u8 = @intCast(rgba & 0xff);
    const alpha = if (std.math.isNan(lit.alpha))
        @as(f64, @floatFromInt(a)) / 255.0
    else
        std.math.clamp(lit.alpha, 0.0, 1.0);
    const alpha_bearing = (lit.flags & 0b0000_0100) != 0;
    const entry: ColorEntry = .{
        .channels = .{
            @as(f64, @floatFromInt(r)) / 255.0,
            @as(f64, @floatFromInt(g)) / 255.0,
            @as(f64, @floatFromInt(b)) / 255.0,
            alpha,
        },
        .space = .srgb,
        .missing = 0,
        // `legacy` is the legacy color-space classification flag, not the old/new implementation generation.
        .legacy = true,
        .prefer_long_hex = alpha_bearing,
        .inspect_repr = if (alpha_bearing)
            .auto
        else if ((lit.flags & 0b0000_0001) != 0)
            .literal_long_hex
        else
            .literal_short_hex,
        .inspect_uppercase_hex = (lit.flags & 0b0000_0010) != 0,
    };
    const handle = value_mod.pushColorEntry(color_pool, env.colorAllocator(), entry) catch return error.OutOfMemory;
    return Value.colorWithHandle(handle);
}

fn evalBinary(env: anytype, prog: anytype, payload: u32) Error!Value {
    const b = prog.binary_exprs.items[payload];
    const lhs = try eval(env, prog, b.lhs);
    const rhs = try eval(env, prog, b.rhs);
    return switch (b.op) {
        .add => try addValues(env, lhs, rhs),
        .sub => try subValues(env, lhs, rhs),
        .mul => try mulValues(env, lhs, rhs),
        .div => try divValues(env, lhs, rhs),
        .mod => try modValues(env, lhs, rhs),
        .eq => if (valueEq(env, lhs, rhs)) Value.true_v else Value.false_v,
        .neq => if (!valueEq(env, lhs, rhs)) Value.true_v else Value.false_v,
        .lt, .gt, .le, .ge => blk: {
            if (lhs.kind() != .number or rhs.kind() != .number) return error.SassError;
            const pair = try comparableNumbers(env.pool(), env.numberPool(), env.allocator(), lhs, rhs);
            const ord = fuzzyNumberOrder(pair.a, pair.b);
            break :blk switch (b.op) {
                .lt => if (ord == .lt) Value.true_v else Value.false_v,
                .gt => if (ord == .gt) Value.true_v else Value.false_v,
                .le => if (ord == .lt or ord == .eq) Value.true_v else Value.false_v,
                .ge => if (ord == .gt or ord == .eq) Value.true_v else Value.false_v,
                else => unreachable,
            };
        },
        .and_op => if (lhs.isTruthy() and rhs.isTruthy()) Value.true_v else Value.false_v,
        .or_op => if (lhs.isTruthy() or rhs.isTruthy()) Value.true_v else Value.false_v,
    };
}

fn evalUnary(env: anytype, prog: anytype, payload: u32) Error!Value {
    const u = prog.unary_exprs.items[payload];
    const operand = try eval(env, prog, u.operand);
    return switch (u.op) {
        .neg => if (operand.kind() == .number)
            try Value.number(-operand.asF64(env.numberPool()), operand.unitId(env.numberPool()), env.numberPool(), env.poolAlloc())
        else
            try unaryPrefixValue(env, "-", operand, .require_non_calc),
        .pos => if (operand.kind() == .number)
            operand
        else
            try unaryPrefixValue(env, "+", operand, .require_non_calc),
        .slash_prefix => try unaryPrefixValue(env, "/", operand, .allow_calc),
        .not_op => if (operand.isTruthy()) Value.false_v else Value.true_v,
    };
}

fn evalInterp(env: anytype, prog: anytype, payload: u32) Error!Value {
    const interp = prog.interp_exprs.items[payload];
    const parts = prog.interp_parts.items[interp.part_start .. interp.part_start + interp.part_count];
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(env.allocator());
    var contains_calc_text = false;
    for (parts) |part_idx| {
        const part = try eval(env, prog, part_idx);
        const text = try valueToInterpolationText(env, part);
        defer env.allocator().free(text);
        if (std.mem.indexOf(u8, text, "calc(") != null) contains_calc_text = true;
        try out.appendSlice(env.allocator(), text);
    }
    const id = try env.pool().intern(out.items);
    const result = Value.string(id, interp.preserve_quote);
    if (!interp.preserve_quote and contains_calc_text) return result.withPreserveLiteralText();
    return result;
}

fn evalList(env: anytype, prog: anytype, payload: u32) Error!Value {
    const list = prog.list_exprs.items[payload];
    const exprs = prog.list_elems.items[list.elem_start .. list.elem_start + list.elem_count];
    var items: std.ArrayListUnmanaged(Value) = .empty;
    defer items.deinit(env.allocator());
    try items.ensureTotalCapacity(env.allocator(), exprs.len);
    for (exprs) |item_expr| {
        try items.append(env.allocator(), try eval(env, prog, item_expr));
    }
    return try env.pushStaticList(items.items, list.separator, list.bracketed, list.is_map, list.slash_coercible);
}

fn evalIfBuiltin(env: anytype, prog: anytype, payload: u32) Error!Value {
    const call = prog.call_exprs.items[payload];
    if (call.arg_count != 3) return error.NonStaticExpr;
    const cond_expr = prog.call_args.items[call.arg_start];
    const true_expr = prog.call_args.items[call.arg_start + 1];
    const false_expr = prog.call_args.items[call.arg_start + 2];
    const cond = try eval(env, prog, cond_expr);
    return if (cond.isTruthy())
        try eval(env, prog, true_expr)
    else
        try eval(env, prog, false_expr);
}

fn evalCssCall(env: anytype, prog: anytype, payload: u32) Error!Value {
    const call = prog.call_exprs.items[payload];
    if (!call.callee_is_css) return error.NonStaticExpr;
    if (call.callee_name == .none) return error.NonStaticExpr;

    const arg_exprs = prog.call_args.items[call.arg_start .. call.arg_start + call.arg_count];
    const arg_names = prog.call_arg_names.items[call.arg_start .. call.arg_start + call.arg_count];
    const name = env.pool().get(call.callee_name);

    if (std.ascii.eqlIgnoreCase(name, "calc") and arg_exprs.len == 1 and arg_names[0] == .none) {
        const arg = try eval(env, prog, arg_exprs[0]);
        if (arg.kind() == .number) return arg;
        const text = try valueToCssCallArgText(env, arg);
        defer env.allocator().free(text);
        const rendered = try std.fmt.allocPrint(env.allocator(), "calc({s})", .{text});
        defer env.allocator().free(rendered);
        const id = try env.pool().intern(rendered);
        const out = Value.string(id, false);
        if (std.mem.indexOf(u8, text, "calc(") != null) return out.withPreserveLiteralText();
        return out;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(env.allocator());
    try out.appendSlice(env.allocator(), name);
    try out.append(env.allocator(), '(');
    for (arg_exprs, 0..) |arg_expr, i| {
        if (i >= arg_names.len or arg_names[i] != .none) return error.NonStaticExpr;
        if (i != 0) try out.appendSlice(env.allocator(), ", ");
        const arg = try eval(env, prog, arg_expr);
        const text = try valueToCssCallArgText(env, arg);
        defer env.allocator().free(text);
        try out.appendSlice(env.allocator(), text);
    }
    try out.append(env.allocator(), ')');
    const id = try env.pool().intern(out.items);
    return Value.string(id, false).withPreserveLiteralText();
}

fn evalBuiltinCall(env: anytype, prog: anytype, payload: u32) Error!Value {
    const call = prog.builtin_calls.items[payload];

    // Meta-dispatch builtins (meta.call, meta.apply, etc.) require VM context
    if (meta_dispatch_abi.isDispatchId(call.builtin_id)) return error.NonStaticExpr;

    const arg_exprs = prog.call_args.items[call.arg_start .. call.arg_start + call.arg_count];
    const arg_names = prog.call_arg_names.items[call.arg_start .. call.arg_start + call.arg_count];

    const alloc = env.allocator();
    const pool_alloc = env.poolAlloc();

    // Evaluate arguments statically
    var args_buf: [16]Value = undefined;
    var args_heap: ?[]Value = null;
    defer if (args_heap) |h| alloc.free(h);

    const args: []Value = if (call.arg_count <= args_buf.len)
        args_buf[0..call.arg_count]
    else blk: {
        args_heap = alloc.alloc(Value, call.arg_count) catch return error.OutOfMemory;
        break :blk args_heap.?;
    };

    for (arg_exprs, 0..) |arg_expr, i| {
        args[i] = eval(env, prog, arg_expr) catch return error.NonStaticExpr;
    }

    // Build a temporary list pool seeded from the static eval store's lists.
    // BuiltinContext needs `[][]Value`, but the static store hands out
    // `[][]const Value` (the static lists are immutable for everyone else).
    // Duplicate each entry into `pool_alloc`-owned mutable storage so the
    // builtin call can write into its `list_pool` view without violating the
    // static store's const contract. The defer below frees every entry --
    // including these duplicates -- in one pass.
    const static_lists = env.getStaticListPool();
    const base_count = static_lists.len;
    // The ArrayList's backing storage and its entries must share an
    // allocator: the builtin call below grows the list through
    // `ctx.allocator` (== `pool_alloc`), so `ensureTotalCapacity` and
    // `deinit` must use the same allocator. Otherwise a grow past
    // `base_count + 4` would pair a `pool_alloc` realloc with an `alloc`
    // free at deinit time.
    var tmp_list_pool: std.ArrayListUnmanaged([]Value) = .empty;
    defer {
        for (tmp_list_pool.items) |slice| pool_alloc.free(slice);
        tmp_list_pool.deinit(pool_alloc);
    }
    tmp_list_pool.ensureTotalCapacity(pool_alloc, base_count + 4) catch return error.OutOfMemory;
    for (static_lists) |const_slice| {
        const owned = pool_alloc.alloc(Value, const_slice.len) catch return error.OutOfMemory;
        @memcpy(owned, const_slice);
        tmp_list_pool.appendAssumeCapacity(owned);
    }

    var random_state: u64 = 0;
    var bctx = builtin_mod.BuiltinContext{
        .allocator = pool_alloc,
        .intern_pool = env.pool(),
        .list_pool = &tmp_list_pool,
        .color_pool = env.colorPool() orelse return error.NonStaticExpr,
        .number_pool = env.numberPool(),
        .callable_payload_pool = env.callablePayloadPool(),
        .list_meta_pool = env.listMetaPool(),
        .string_flags_pool = env.stringFlagsPool(),
        .random_state = &random_state,
        .vm = @ptrFromInt(1), // dummy, never dereferenced
        .list_parent_sel_none_hook = null,
        .map_lookup_index_cache = null,
        .list_index_cache = null,
        .deprecation_opts = null,
    };

    const result = builtin_mod.dispatch(&bctx, call.builtin_id, args, arg_names) catch {
        return error.NonStaticExpr;
    };

    // If the result is a list with a handle beyond the base, migrate to static store
    if (result.kind() == .list) {
        const handle = result.listHandle();
        if (handle >= base_count) {
            return migrateListToStaticStore(env, &tmp_list_pool, base_count, result);
        }
    }

    return result;
}

/// Recursively migrate list values from a temporary builtin list pool to the static eval store.
fn migrateListToStaticStore(env: anytype, tmp_pool: *std.ArrayListUnmanaged([]Value), base_count: usize, v: Value) Error!Value {
    if (v.kind() != .list) return v;

    const handle = v.listHandle();
    if (handle < base_count) return v; // already in static store
    if (handle >= tmp_pool.items.len) return error.NonStaticExpr;
    const items = tmp_pool.items[handle];

    // Recursively migrate child list items
    var migrated_items: std.ArrayListUnmanaged(Value) = .empty;
    defer migrated_items.deinit(env.allocator());
    migrated_items.ensureTotalCapacity(env.allocator(), items.len) catch return error.OutOfMemory;
    for (items) |item| {
        migrated_items.appendAssumeCapacity(try migrateListToStaticStore(env, tmp_pool, base_count, item));
    }

    const lmp = env.listMetaPool().items;
    var out = try env.pushStaticList(
        migrated_items.items,
        v.listSeparator(lmp),
        v.listBracketed(lmp),
        v.listIsMap(lmp),
        v.listCoerceSlash(lmp),
    );
    if (v.listFromBuiltinSlash()) out = out.withBuiltinSlashList();
    return out;
}

const UnaryCalcPolicy = enum {
    require_non_calc,
    allow_calc,
};

fn unaryPrefixValue(env: anytype, prefix: []const u8, v: Value, calc_policy: UnaryCalcPolicy) Error!Value {
    const raw = try valueToOpString(env, v);
    defer env.allocator().free(raw);

    if (calc_policy == .require_non_calc and css_utils.containsCalcFunction(raw)) {
        return error.SassError;
    }
    if (!std.mem.eql(u8, prefix, "/") and std.mem.eql(u8, raw, ".")) {
        return error.SassError;
    }

    const merged = try std.fmt.allocPrint(env.allocator(), "{s}{s}", .{ prefix, raw });
    defer env.allocator().free(merged);
    const id = try env.pool().intern(merged);
    return Value.string(id, false);
}

fn calcArgMarkedText(env: anytype, v: Value) ?[]const u8 {
    if (v.kind() != .string or v.stringQuoted(env.stringFlagsPool().items)) return null;
    const raw = env.pool().get(v.stringIntern());
    if (!std.mem.startsWith(u8, raw, calc_arg_marker)) return null;
    return raw[calc_arg_marker.len..];
}

fn valueToCssCallArgText(env: anytype, v: Value) Error![]const u8 {
    if (calcArgMarkedText(env, v)) |text| {
        return try env.allocator().dupe(u8, text);
    }
    return valueToOpString(env, v);
}

fn calcBinaryIfMarked(env: anytype, lhs: Value, rhs: Value, op: []const u8) Error!?Value {
    if (calcArgMarkedText(env, lhs) == null and calcArgMarkedText(env, rhs) == null) return null;

    const lhs_text = try valueToCssCallArgText(env, lhs);
    defer env.allocator().free(lhs_text);
    const rhs_text = try valueToCssCallArgText(env, rhs);
    defer env.allocator().free(rhs_text);
    const merged = try std.fmt.allocPrint(env.allocator(), "{s}{s} {s} {s}", .{ calc_arg_marker, lhs_text, op, rhs_text });
    defer env.allocator().free(merged);
    const id = try env.pool().intern(merged);
    return Value.string(id, false);
}

fn addValues(env: anytype, a: Value, b: Value) Error!Value {
    const lhs = try coerceCalcStringToNumberish(env, a);
    const rhs = try coerceCalcStringToNumberish(env, b);
    if (colorArithmeticShouldError(env.pool(), lhs, rhs)) {
        return error.SassError;
    }

    if (lhs.kind() == .number and rhs.kind() == .number) {
        if (combineAddUnits(env.pool(), env.numberPool(), lhs, rhs)) |resolved| {
            return try Value.number(lhs.asF64(env.numberPool()) + resolved.rhs, resolved.unit, env.numberPool(), env.poolAlloc());
        } else |err| switch (err) {
            error.NonStaticExpr => {
                const ua = lhs.unitId(env.numberPool());
                const ub = rhs.unitId(env.numberPool());
                if (shouldPreserveCssMathAdd(env.pool(), ua, ub)) {
                    const sa = try formatNumberValue(env.pool(), env.numberPool(), env.allocator(), lhs);
                    defer env.allocator().free(sa);
                    const sb = try formatNumberValue(env.pool(), env.numberPool(), env.allocator(), rhs);
                    defer env.allocator().free(sb);
                    const merged = try std.fmt.allocPrint(env.allocator(), "{s} + {s}", .{ sa, sb });
                    defer env.allocator().free(merged);
                    const id = try env.pool().intern(merged);
                    return Value.string(id, false);
                }
                return error.SassError;
            },
            else => return err,
        }
    }
    if (try calcBinaryIfMarked(env, lhs, rhs, "+")) |v| return v;
    if (lhs.kind() == .string and rhs.kind() == .string) {
        const sa = env.pool().get(lhs.stringIntern());
        const sb = env.pool().get(rhs.stringIntern());
        const merged = try std.fmt.allocPrint(env.allocator(), "{s}{s}", .{ sa, sb });
        defer env.allocator().free(merged);
        const id = try env.pool().intern(merged);
        return Value.string(id, lhs.stringQuoted(env.stringFlagsPool().items));
    }
    if (lhs.kind() == .number and rhs.kind() == .string) {
        const num_s = try formatNumberValue(env.pool(), env.numberPool(), env.allocator(), lhs);
        defer env.allocator().free(num_s);
        const sb = env.pool().get(rhs.stringIntern());
        const merged = try std.fmt.allocPrint(env.allocator(), "{s}{s}", .{ num_s, sb });
        defer env.allocator().free(merged);
        const id = try env.pool().intern(merged);
        return Value.string(id, rhs.stringQuoted(env.stringFlagsPool().items));
    }
    if (lhs.kind() == .string and rhs.kind() == .number) {
        const sb = try formatNumberValue(env.pool(), env.numberPool(), env.allocator(), rhs);
        defer env.allocator().free(sb);
        const sa = env.pool().get(lhs.stringIntern());
        const merged = try std.fmt.allocPrint(env.allocator(), "{s}{s}", .{ sa, sb });
        defer env.allocator().free(merged);
        const id = try env.pool().intern(merged);
        return Value.string(id, lhs.stringQuoted(env.stringFlagsPool().items));
    }
    const sa = try valueToOpString(env, lhs);
    defer env.allocator().free(sa);
    const sb = try valueToOpString(env, rhs);
    defer env.allocator().free(sb);
    const merged = try std.fmt.allocPrint(env.allocator(), "{s}{s}", .{ sa, sb });
    defer env.allocator().free(merged);
    const id = try env.pool().intern(merged);
    const quoted = (lhs.kind() == .string and lhs.stringQuoted(env.stringFlagsPool().items)) or (rhs.kind() == .string and rhs.stringQuoted(env.stringFlagsPool().items));
    return Value.string(id, quoted);
}

fn subValues(env: anytype, a: Value, b: Value) Error!Value {
    const lhs = try coerceCalcStringToNumberish(env, a);
    const rhs = try coerceCalcStringToNumberish(env, b);
    if (colorArithmeticShouldError(env.pool(), lhs, rhs)) {
        return error.SassError;
    }

    if (lhs.kind() == .number and rhs.kind() == .number) {
        if (combineAddUnits(env.pool(), env.numberPool(), lhs, rhs)) |resolved| {
            return try Value.number(lhs.asF64(env.numberPool()) - resolved.rhs, resolved.unit, env.numberPool(), env.poolAlloc());
        } else |_| return error.SassError;
    }
    if (try calcBinaryIfMarked(env, lhs, rhs, "-")) |v| return v;
    const sa = try valueToArithmeticOperandText(env, lhs);
    defer env.allocator().free(sa);
    const sb = try valueToArithmeticOperandText(env, rhs);
    defer env.allocator().free(sb);
    const merged = try std.fmt.allocPrint(env.allocator(), "{s}-{s}", .{ sa, sb });
    defer env.allocator().free(merged);
    const id = try env.pool().intern(merged);
    return Value.string(id, false);
}

fn mulValues(env: anytype, a: Value, b: Value) Error!Value {
    const lhs = try coerceCalcStringToNumberish(env, a);
    const rhs = try coerceCalcStringToNumberish(env, b);
    if (colorArithmeticShouldError(env.pool(), lhs, rhs)) {
        return error.SassError;
    }

    if (lhs.kind() == .number and rhs.kind() == .number) {
        const ua = lhs.unitId(env.numberPool());
        const ub = rhs.unitId(env.numberPool());
        const lf = lhs.asF64(env.numberPool());
        const rf = rhs.asF64(env.numberPool());
        if (ua == .none and ub == .none) return try Value.number(lf * rf, .none, env.numberPool(), env.poolAlloc());
        if (ua == .none) return try Value.number(lf * rf, ub, env.numberPool(), env.poolAlloc());
        if (ub == .none) return try Value.number(lf * rf, ua, env.numberPool(), env.poolAlloc());
        if (try combineUnitIdsForMul(env.pool(), env.allocator(), ua, ub)) |combined| {
            return try Value.number(lf * rf * combined.factor, combined.unit, env.numberPool(), env.poolAlloc());
        }
    }
    if (try calcBinaryIfMarked(env, lhs, rhs, "*")) |v| return v;
    return error.SassError;
}

fn divValues(env: anytype, a: Value, b: Value) Error!Value {
    const lhs = try coerceCalcStringToNumberish(env, a);
    const rhs = try coerceCalcStringToNumberish(env, b);
    if (colorArithmeticShouldError(env.pool(), lhs, rhs)) {
        return error.SassError;
    }

    if (lhs.kind() == .number and rhs.kind() == .number) {
        const ua = lhs.unitId(env.numberPool());
        const ub = rhs.unitId(env.numberPool());

        const numerator = lhs.asF64(env.numberPool());
        var denominator = rhs.asF64(env.numberPool());
        var factor: f64 = 1.0;
        var out_unit: InternId = .none;

        if (ua == .none and ub == .none) {
            out_unit = .none;
        } else if (ub == .none) {
            out_unit = ua;
        } else if (ua != .none and std.ascii.eqlIgnoreCase(env.pool().get(ua), env.pool().get(ub))) {
            out_unit = .none;
        } else if (ua != .none) {
            if (convertComparableUnitValueRuntime(denominator, env.pool().get(ub), env.pool().get(ua))) |converted| {
                denominator = converted;
                out_unit = .none;
            } else if (try combineUnitIdsForOp(env.pool(), env.allocator(), ua, ub)) |combined| {
                factor = combined.factor;
                out_unit = combined.unit;
            } else {
                out_unit = ua;
            }
        } else {
            var numerators: std.ArrayListUnmanaged([]const u8) = .empty;
            defer numerators.deinit(env.allocator());
            var denominators: std.ArrayListUnmanaged([]const u8) = .empty;
            defer denominators.deinit(env.allocator());
            appendUnitTextFactors(env.allocator(), env.pool().get(ub), &numerators, &denominators, true) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    const sa_raw = try valueToArithmeticOperandText(env, lhs);
                    defer env.allocator().free(sa_raw);
                    const sb_raw = try valueToArithmeticOperandText(env, rhs);
                    defer env.allocator().free(sb_raw);
                    const sa = try simplifySlashOperandText(env.pool(), env.numberPool(), env.allocator(), sa_raw);
                    defer env.allocator().free(sa);
                    const sb = try simplifySlashOperandText(env.pool(), env.numberPool(), env.allocator(), sb_raw);
                    defer env.allocator().free(sb);
                    const merged = try std.fmt.allocPrint(env.allocator(), "{s}/{s}", .{ sa, sb });
                    defer env.allocator().free(merged);
                    const id = try env.pool().intern(merged);
                    return Value.string(id, false);
                },
            };
            factor = simplifyUnitFactorsCaseInsensitive(&numerators, &denominators);
            const combined_text = try buildUnitDescriptionFromFactors(env.allocator(), numerators.items, denominators.items);
            if (combined_text) |text| {
                defer env.allocator().free(text);
                out_unit = try env.pool().intern(text);
            } else {
                out_unit = .none;
            }
        }

        if (denominator == 0) {
            return try Value.number(numerator / denominator, out_unit, env.numberPool(), env.poolAlloc());
        }
        return try Value.number((numerator / denominator) * factor, out_unit, env.numberPool(), env.poolAlloc());
    }

    if (try calcBinaryIfMarked(env, lhs, rhs, "/")) |v| return v;
    const sa_raw = try valueToArithmeticOperandText(env, lhs);
    defer env.allocator().free(sa_raw);
    const sb_raw = try valueToArithmeticOperandText(env, rhs);
    defer env.allocator().free(sb_raw);
    const sa = try simplifySlashOperandText(env.pool(), env.numberPool(), env.allocator(), sa_raw);
    defer env.allocator().free(sa);
    const sb = try simplifySlashOperandText(env.pool(), env.numberPool(), env.allocator(), sb_raw);
    defer env.allocator().free(sb);
    const merged = try std.fmt.allocPrint(env.allocator(), "{s}/{s}", .{ sa, sb });
    defer env.allocator().free(merged);
    const id = try env.pool().intern(merged);
    return Value.string(id, false);
}

fn modValues(env: anytype, a: Value, b: Value) Error!Value {
    const lhs = try coerceCalcStringToNumberish(env, a);
    const rhs = try coerceCalcStringToNumberish(env, b);
    if (colorArithmeticShouldError(env.pool(), lhs, rhs)) {
        return error.SassError;
    }

    if (lhs.kind() == .number and rhs.kind() == .number) {
        const ua = lhs.unitId(env.numberPool());
        const ub = rhs.unitId(env.numberPool());
        if (ua == ub or ua == .none or ub == .none) {
            const unit = if (ua != .none) ua else ub;
            const av = lhs.asF64(env.numberPool());
            const bv = rhs.asF64(env.numberPool());
            if (std.math.isInf(bv)) {
                if (std.math.isNan(av)) return try Value.number(std.math.nan(f64), unit, env.numberPool(), env.poolAlloc());
                if (std.math.signbit(av) == std.math.signbit(bv)) return try Value.number(av, unit, env.numberPool(), env.poolAlloc());
                return try Value.number(std.math.nan(f64), unit, env.numberPool(), env.poolAlloc());
            }
            return try Value.number(@mod(av, bv), unit, env.numberPool(), env.poolAlloc());
        }
    }
    return error.SassError;
}

fn valueToInterpolationText(env: anytype, v: Value) Error![]const u8 {
    return switch (v.kind()) {
        .nil => try env.allocator().dupe(u8, ""),
        .string => try env.allocator().dupe(u8, env.pool().get(v.stringIntern())),
        else => valueToOpString(env, v),
    };
}

fn valueToArithmeticOperandText(env: anytype, v: Value) Error![]const u8 {
    return valueToOpString(env, v);
}

fn valueToOpString(env: anytype, v: Value) Error![]const u8 {
    return switch (v.kind()) {
        .nil => try env.allocator().dupe(u8, ""),
        .boolean => try env.allocator().dupe(u8, if (v.p64Of() != 0) "true" else "false"),
        .number => try formatNumberValue(env.pool(), env.numberPool(), env.allocator(), v),
        .string => try env.allocator().dupe(u8, env.pool().get(v.stringIntern())),
        .list => blk: {
            const items = env.getStaticList(v.listHandle()) orelse return error.NonStaticExpr;
            const lmp = env.listMetaPool().items;
            if (items.len == 0) {
                break :blk try env.allocator().dupe(u8, if (v.listBracketed(lmp)) "[]" else "()");
            }
            var out: std.ArrayListUnmanaged(u8) = .empty;
            defer out.deinit(env.allocator());
            if (v.listBracketed(lmp)) try out.append(env.allocator(), '[');
            const sep = switch (v.listSeparator(lmp)) {
                .slash => "/",
                .comma => ", ",
                .space, .undecided => " ",
            };
            var wrote_any = false;
            for (items) |item| {
                if (item.kind() == .nil) continue;
                if (wrote_any) try out.appendSlice(env.allocator(), sep);
                const item_text = try valueToOpString(env, item);
                defer env.allocator().free(item_text);
                try out.appendSlice(env.allocator(), item_text);
                wrote_any = true;
            }
            if (v.listBracketed(lmp)) try out.append(env.allocator(), ']');
            break :blk try out.toOwnedSlice(env.allocator());
        },
        .color => blk: {
            const color_pool = env.colorPool() orelse return error.NonStaticExpr;
            const entry = v.colorEntry(color_pool).*;
            break :blk color_format.formatColorCss(env.allocator(), entry) catch error.OutOfMemory;
        },
        else => error.NonStaticExpr,
    };
}

fn isColorLikeValue(pool: *InternPool, v: Value) bool {
    return switch (v.kind()) {
        .color => true,
        .string => !v.stringQuoted(value_mod.empty_string_flags_pool) and color_mod.lookupNamedColor(pool.get(v.stringIntern())) != null,
        else => false,
    };
}

fn colorArithmeticShouldError(pool: *InternPool, lhs: Value, rhs: Value) bool {
    const lhs_color = isColorLikeValue(pool, lhs);
    const rhs_color = isColorLikeValue(pool, rhs);
    if (!lhs_color and !rhs_color) return false;
    if (lhs_color and rhs_color) return true;
    if (lhs_color) return rhs.kind() != .string or rhs_color;
    return lhs.kind() != .string or lhs_color;
}

const AddUnitsResolved = struct {
    unit: InternId,
    rhs: f64,
};

fn combineAddUnits(pool: *InternPool, number_pool: *value_mod.NumberPool, lhs: Value, rhs: Value) Error!AddUnitsResolved {
    std.debug.assert(lhs.kind() == .number and rhs.kind() == .number);
    const ua = lhs.unitId(number_pool);
    const ub = rhs.unitId(number_pool);

    if (ua == .none and ub == .none) {
        return .{ .unit = .none, .rhs = rhs.asF64(number_pool) };
    }
    if (ua == .none) {
        return .{ .unit = ub, .rhs = rhs.asF64(number_pool) };
    }
    if (ub == .none) {
        return .{ .unit = ua, .rhs = rhs.asF64(number_pool) };
    }
    if (std.ascii.eqlIgnoreCase(pool.get(ua), pool.get(ub))) {
        return .{ .unit = ua, .rhs = rhs.asF64(number_pool) };
    }
    if (convertComparableUnitValueRuntime(rhs.asF64(number_pool), pool.get(ub), pool.get(ua))) |converted_rhs| {
        return .{ .unit = ua, .rhs = converted_rhs };
    }
    return error.NonStaticExpr;
}

fn shouldPreserveCssMathAdd(pool: *const InternPool, ua: InternId, ub: InternId) bool {
    if (ua == .none or ub == .none or ua == ub) return false;
    return isPercentUnit(pool, ua) != isPercentUnit(pool, ub);
}

fn isPercentUnit(pool: *const InternPool, unit: InternId) bool {
    if (unit == .none) return false;
    return std.mem.eql(u8, pool.get(unit), "%");
}

fn comparableNumbers(pool: *InternPool, number_pool: *value_mod.NumberPool, alloc: std.mem.Allocator, a: Value, b: Value) Error!struct { a: f64, b: f64 } {
    std.debug.assert(a.kind() == .number and b.kind() == .number);
    const ua = a.unitId(number_pool);
    const ub = b.unitId(number_pool);
    if (ua == ub or ua == .none or ub == .none) {
        return .{ .a = a.asF64(number_pool), .b = b.asF64(number_pool) };
    }

    const ua_text = pool.get(ua);
    const ub_text = pool.get(ub);
    if (convertComparableUnitRuntime(b.asF64(number_pool), ub_text, ua_text)) |b_conv| {
        return .{ .a = a.asF64(number_pool), .b = b_conv };
    }
    if (convertComparableUnitRuntime(a.asF64(number_pool), ua_text, ub_text)) |a_conv| {
        return .{ .a = a_conv, .b = b.asF64(number_pool) };
    }

    const ca = canonicalizeComparableNumberRuntime(alloc, a.asF64(number_pool), ua_text) catch return error.SassError;
    defer if (ca.desc) |desc| alloc.free(desc);
    const cb = canonicalizeComparableNumberRuntime(alloc, b.asF64(number_pool), ub_text) catch return error.SassError;
    defer if (cb.desc) |desc| alloc.free(desc);

    if (ca.desc == null and cb.desc == null) {
        return .{ .a = ca.value, .b = cb.value };
    }
    if (ca.desc != null and cb.desc != null and std.ascii.eqlIgnoreCase(ca.desc.?, cb.desc.?)) {
        return .{ .a = ca.value, .b = cb.value };
    }
    return error.SassError;
}

const ComparableUnitInfo = struct {
    family: enum { length, angle, time, frequency, resolution },
    factor: f64,
};

fn convertComparableUnitRuntime(value: f64, from: []const u8, to: []const u8) ?f64 {
    if (std.ascii.eqlIgnoreCase(from, to)) return value;
    const from_u = comparableUnitInfo(from) orelse return null;
    const to_u = comparableUnitInfo(to) orelse return null;
    if (from_u.family != to_u.family) return null;
    return value * from_u.factor / to_u.factor;
}

fn comparableUnitInfo(unit: []const u8) ?ComparableUnitInfo {
    if (std.ascii.eqlIgnoreCase(unit, "px")) return .{ .family = .length, .factor = 1.0 };
    if (std.ascii.eqlIgnoreCase(unit, "in")) return .{ .family = .length, .factor = 96.0 };
    if (std.ascii.eqlIgnoreCase(unit, "cm")) return .{ .family = .length, .factor = 96.0 / 2.54 };
    if (std.ascii.eqlIgnoreCase(unit, "mm")) return .{ .family = .length, .factor = 96.0 / 25.4 };
    if (std.ascii.eqlIgnoreCase(unit, "pt")) return .{ .family = .length, .factor = 96.0 / 72.0 };
    if (std.ascii.eqlIgnoreCase(unit, "pc")) return .{ .family = .length, .factor = 16.0 };
    if (std.ascii.eqlIgnoreCase(unit, "q")) return .{ .family = .length, .factor = 96.0 / 101.6 };

    if (std.ascii.eqlIgnoreCase(unit, "deg")) return .{ .family = .angle, .factor = 1.0 };
    if (std.ascii.eqlIgnoreCase(unit, "rad")) return .{ .family = .angle, .factor = 180.0 / std.math.pi };
    if (std.ascii.eqlIgnoreCase(unit, "grad")) return .{ .family = .angle, .factor = 0.9 };
    if (std.ascii.eqlIgnoreCase(unit, "turn")) return .{ .family = .angle, .factor = 360.0 };

    if (std.ascii.eqlIgnoreCase(unit, "s")) return .{ .family = .time, .factor = 1.0 };
    if (std.ascii.eqlIgnoreCase(unit, "ms")) return .{ .family = .time, .factor = 0.001 };

    if (std.ascii.eqlIgnoreCase(unit, "hz")) return .{ .family = .frequency, .factor = 1.0 };
    if (std.ascii.eqlIgnoreCase(unit, "khz")) return .{ .family = .frequency, .factor = 1000.0 };

    if (std.ascii.eqlIgnoreCase(unit, "dppx")) return .{ .family = .resolution, .factor = 1.0 };
    if (std.ascii.eqlIgnoreCase(unit, "dpi")) return .{ .family = .resolution, .factor = 1.0 / 96.0 };
    if (std.ascii.eqlIgnoreCase(unit, "dpcm")) return .{ .family = .resolution, .factor = 2.54 / 96.0 };
    return null;
}

const CanonicalComparableFactorRuntime = struct {
    name: []const u8,
    factor: f64,
};

fn canonicalComparableFactorRuntime(unit: []const u8) ?CanonicalComparableFactorRuntime {
    if (std.ascii.eqlIgnoreCase(unit, "px")) return .{ .name = "px", .factor = 1.0 };
    if (std.ascii.eqlIgnoreCase(unit, "in")) return .{ .name = "px", .factor = 96.0 };
    if (std.ascii.eqlIgnoreCase(unit, "cm")) return .{ .name = "px", .factor = 96.0 / 2.54 };
    if (std.ascii.eqlIgnoreCase(unit, "mm")) return .{ .name = "px", .factor = 96.0 / 25.4 };
    if (std.ascii.eqlIgnoreCase(unit, "pt")) return .{ .name = "px", .factor = 96.0 / 72.0 };
    if (std.ascii.eqlIgnoreCase(unit, "pc")) return .{ .name = "px", .factor = 16.0 };
    if (std.ascii.eqlIgnoreCase(unit, "q")) return .{ .name = "px", .factor = 96.0 / 101.6 };

    if (std.ascii.eqlIgnoreCase(unit, "deg")) return .{ .name = "deg", .factor = 1.0 };
    if (std.ascii.eqlIgnoreCase(unit, "rad")) return .{ .name = "deg", .factor = 180.0 / std.math.pi };
    if (std.ascii.eqlIgnoreCase(unit, "grad")) return .{ .name = "deg", .factor = 0.9 };
    if (std.ascii.eqlIgnoreCase(unit, "turn")) return .{ .name = "deg", .factor = 360.0 };

    if (std.ascii.eqlIgnoreCase(unit, "s")) return .{ .name = "s", .factor = 1.0 };
    if (std.ascii.eqlIgnoreCase(unit, "ms")) return .{ .name = "s", .factor = 0.001 };

    if (std.ascii.eqlIgnoreCase(unit, "Hz")) return .{ .name = "Hz", .factor = 1.0 };
    if (std.ascii.eqlIgnoreCase(unit, "kHz")) return .{ .name = "Hz", .factor = 1000.0 };

    if (std.ascii.eqlIgnoreCase(unit, "dppx")) return .{ .name = "dppx", .factor = 1.0 };
    if (std.ascii.eqlIgnoreCase(unit, "dpi")) return .{ .name = "dppx", .factor = 1.0 / 96.0 };
    if (std.ascii.eqlIgnoreCase(unit, "dpcm")) return .{ .name = "dppx", .factor = 2.54 / 96.0 };
    return null;
}

fn unitFactorLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.ascii.orderIgnoreCase(lhs, rhs) == .lt;
}

const CanonicalComparableNumberRuntime = struct {
    value: f64,
    desc: ?[]u8,
};

fn canonicalizeComparableNumberRuntime(
    alloc: std.mem.Allocator,
    value: f64,
    unit_text: []const u8,
) !CanonicalComparableNumberRuntime {
    var numerators: std.ArrayListUnmanaged([]const u8) = .empty;
    defer numerators.deinit(alloc);
    var denominators: std.ArrayListUnmanaged([]const u8) = .empty;
    defer denominators.deinit(alloc);

    try appendUnitTextFactors(alloc, unit_text, &numerators, &denominators, false);

    var scaled = value;
    for (numerators.items) |*unit| {
        if (canonicalComparableFactorRuntime(unit.*)) |canon| {
            scaled *= canon.factor;
            unit.* = canon.name;
        }
    }
    for (denominators.items) |*unit| {
        if (canonicalComparableFactorRuntime(unit.*)) |canon| {
            scaled /= canon.factor;
            unit.* = canon.name;
        }
    }

    _ = simplifyUnitFactorsCaseInsensitive(&numerators, &denominators);
    std.mem.sortUnstable([]const u8, numerators.items, {}, unitFactorLessThan);
    std.mem.sortUnstable([]const u8, denominators.items, {}, unitFactorLessThan);

    return .{
        .value = scaled,
        .desc = try buildUnitDescriptionFromFactors(alloc, numerators.items, denominators.items),
    };
}

fn comparableUnitInfoRuntime(unit: []const u8) ?ComparableUnitInfo {
    return comparableUnitInfo(unit);
}

fn convertComparableUnitValueRuntime(value: f64, from: []const u8, to: []const u8) ?f64 {
    if (std.ascii.eqlIgnoreCase(from, to)) return value;
    const from_u = comparableUnitInfoRuntime(from) orelse return null;
    const to_u = comparableUnitInfoRuntime(to) orelse return null;
    if (from_u.family != to_u.family) return null;
    return value * from_u.factor / to_u.factor;
}

fn parseSimpleNumberish(pool: *InternPool, number_pool: *value_mod.NumberPool, alloc: std.mem.Allocator, text: []const u8) Error!?Value {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return null;

    if (std.ascii.eqlIgnoreCase(t, "pi") or std.ascii.eqlIgnoreCase(t, "+pi")) return try Value.number(std.math.pi, .none, number_pool, alloc);
    if (std.ascii.eqlIgnoreCase(t, "-pi")) return try Value.number(-std.math.pi, .none, number_pool, alloc);
    if (std.ascii.eqlIgnoreCase(t, "e") or std.ascii.eqlIgnoreCase(t, "+e")) return try Value.number(std.math.e, .none, number_pool, alloc);
    if (std.ascii.eqlIgnoreCase(t, "-e")) return try Value.number(-std.math.e, .none, number_pool, alloc);
    if (std.ascii.eqlIgnoreCase(t, "infinity")) return try Value.number(std.math.inf(f64), .none, number_pool, alloc);
    if (std.ascii.eqlIgnoreCase(t, "+infinity")) return try Value.number(std.math.inf(f64), .none, number_pool, alloc);
    if (std.ascii.eqlIgnoreCase(t, "-infinity")) return try Value.number(-std.math.inf(f64), .none, number_pool, alloc);
    if (std.ascii.eqlIgnoreCase(t, "nan") or std.ascii.eqlIgnoreCase(t, "-nan")) return try Value.number(std.math.nan(f64), .none, number_pool, alloc);

    var idx: usize = 0;
    if (t[idx] == '+' or t[idx] == '-') idx += 1;
    var int_digits: usize = 0;
    while (idx < t.len and std.ascii.isDigit(t[idx])) : (idx += 1) int_digits += 1;
    var frac_digits: usize = 0;
    if (idx < t.len and t[idx] == '.') {
        idx += 1;
        while (idx < t.len and std.ascii.isDigit(t[idx])) : (idx += 1) frac_digits += 1;
    }
    if (int_digits == 0 and frac_digits == 0) return null;

    const exp_idx = idx;
    if (exp_idx < t.len and (t[exp_idx] == 'e' or t[exp_idx] == 'E')) {
        var j = exp_idx + 1;
        if (j < t.len and (t[j] == '+' or t[j] == '-')) j += 1;
        const exp_start = j;
        while (j < t.len and std.ascii.isDigit(t[j])) : (j += 1) {}
        if (j > exp_start) idx = j;
    }

    const num_part = t[0..idx];
    const value = std.fmt.parseFloat(f64, num_part) catch return null;
    const unit_part = t[idx..];
    if (unit_part.len == 0) return try Value.number(value, .none, number_pool, alloc);
    for (unit_part) |c| {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') return null;
    }
    const unit_id = try pool.intern(unit_part);
    return try Value.number(value, unit_id, number_pool, alloc);
}

fn parseCalcNumberish(pool: *InternPool, number_pool: *value_mod.NumberPool, alloc: std.mem.Allocator, text: []const u8) Error!?Value {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, t, "calc(") or t.len < 6 or t[t.len - 1] != ')') return null;

    const inner = std.mem.trim(u8, t[5 .. t.len - 1], " \t\r\n");
    if (try parseSimpleNumberish(pool, number_pool, alloc, inner)) |value| return value;

    const star_idx = std.mem.indexOfScalar(u8, inner, '*') orelse return null;
    const lhs = std.mem.trim(u8, inner[0..star_idx], " \t\r\n");
    const rhs = std.mem.trim(u8, inner[star_idx + 1 ..], " \t\r\n");
    if (rhs.len < 2 or rhs[0] != '1') return null;
    const unit_text = rhs[1..];
    if (unit_text.len == 0) return null;
    for (unit_text) |c| {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') return null;
    }

    const scalar: f64 = blk: {
        if (std.ascii.eqlIgnoreCase(lhs, "infinity")) break :blk std.math.inf(f64);
        if (std.ascii.eqlIgnoreCase(lhs, "-infinity")) break :blk -std.math.inf(f64);
        if (std.ascii.eqlIgnoreCase(lhs, "nan") or std.ascii.eqlIgnoreCase(lhs, "-nan")) break :blk std.math.nan(f64);
        return null;
    };
    const unit_id = try pool.intern(unit_text);
    return try Value.number(scalar, unit_id, number_pool, alloc);
}

fn coerceSlashListToNumberish(env: anytype, v: Value) Error!?Value {
    const lmp = env.listMetaPool().items;
    if (v.kind() != .list or !v.listSlash(lmp) or !v.listCoerceSlash(lmp) or v.listBracketed(lmp) or v.listComma(lmp)) return null;
    const items = env.getStaticList(v.listHandle()) orelse return null;
    if (items.len < 2) return null;

    const first = try coerceCalcStringToNumberish(env, items[0]);
    if (first.kind() != .number) return null;

    var numeric = first.asF64(env.numberPool());
    var numerators: std.ArrayListUnmanaged([]const u8) = .empty;
    defer numerators.deinit(env.allocator());
    var denominators: std.ArrayListUnmanaged([]const u8) = .empty;
    defer denominators.deinit(env.allocator());

    const first_unit = first.unitId(env.numberPool());
    if (first_unit != .none) {
        try appendUnitTextFactors(env.allocator(), env.pool().get(first_unit), &numerators, &denominators, false);
    }

    for (items[1..]) |item| {
        const divisor = try coerceCalcStringToNumberish(env, item);
        if (divisor.kind() != .number) return null;
        numeric /= divisor.asF64(env.numberPool());
        const divisor_unit = divisor.unitId(env.numberPool());
        if (divisor_unit != .none) {
            try appendUnitTextFactors(env.allocator(), env.pool().get(divisor_unit), &numerators, &denominators, true);
        }
    }

    const factor = simplifyUnitFactorsCaseInsensitive(&numerators, &denominators);
    const desc = try buildUnitDescriptionFromFactors(env.allocator(), numerators.items, denominators.items);
    var out_unit: InternId = .none;
    if (desc) |text| {
        defer env.allocator().free(text);
        out_unit = try env.pool().intern(text);
    }
    return try Value.number(numeric * factor, out_unit, env.numberPool(), env.poolAlloc());
}

fn coerceCalcStringToNumberish(env: anytype, v: Value) Error!Value {
    if (v.kind() == .string and !v.stringQuoted(env.stringFlagsPool().items)) {
        if (try parseCalcNumberish(env.pool(), env.numberPool(), env.poolAlloc(), env.pool().get(v.stringIntern()))) |parsed| return parsed;
    }
    if (try coerceSlashListToNumberish(env, v)) |parsed| return parsed;
    return v;
}

fn simplifySlashOperandText(pool: *InternPool, number_pool: *value_mod.NumberPool, alloc: std.mem.Allocator, raw: []const u8) Error![]const u8 {
    if (try parseCalcNumberish(pool, number_pool, alloc, raw)) |parsed| {
        if (parsed.kind() == .number and parsed.unitId(number_pool) == .none and std.math.isFinite(parsed.asF64(number_pool))) {
            return value_format.formatNumberWithUnit(alloc, parsed.asF64(number_pool), null) catch error.OutOfMemory;
        }
    }
    return try alloc.dupe(u8, raw);
}

fn unitLooksCompound(unit_text: []const u8) bool {
    const trimmed = std.mem.trim(u8, unit_text, " \t\r\n");
    if (trimmed.len == 0) return false;
    return std.mem.indexOfScalar(u8, trimmed, '*') != null or
        std.mem.indexOfScalar(u8, trimmed, '/') != null or
        std.mem.endsWith(u8, trimmed, "^-1");
}

fn appendCalcWithCompoundUnit(
    alloc: std.mem.Allocator,
    value: f64,
    numerators: []const []const u8,
    denominators: []const []const u8,
) Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);

    if (std.math.isNan(value)) {
        try out.appendSlice(alloc, "calc(NaN");
        for (numerators) |unit| {
            try out.appendSlice(alloc, " * 1");
            try out.appendSlice(alloc, unit);
        }
        for (denominators) |unit| {
            try out.appendSlice(alloc, " / 1");
            try out.appendSlice(alloc, unit);
        }
        try out.append(alloc, ')');
        return out.toOwnedSlice(alloc);
    }

    if (std.math.isInf(value)) {
        try out.appendSlice(alloc, if (value < 0) "calc(-infinity" else "calc(infinity");
        for (numerators) |unit| {
            try out.appendSlice(alloc, " * 1");
            try out.appendSlice(alloc, unit);
        }
        for (denominators) |unit| {
            try out.appendSlice(alloc, " / 1");
            try out.appendSlice(alloc, unit);
        }
        try out.append(alloc, ')');
        return out.toOwnedSlice(alloc);
    }

    const core = value_format.formatNumberCore(alloc, value) catch return error.OutOfMemory;
    defer alloc.free(core);

    try out.appendSlice(alloc, "calc(");
    try out.appendSlice(alloc, core);

    if (numerators.len > 0) {
        try out.appendSlice(alloc, numerators[0]);
        for (numerators[1..]) |unit| {
            try out.appendSlice(alloc, " * 1");
            try out.appendSlice(alloc, unit);
        }
    }
    for (denominators) |unit| {
        try out.appendSlice(alloc, " / 1");
        try out.appendSlice(alloc, unit);
    }
    try out.append(alloc, ')');
    return out.toOwnedSlice(alloc);
}

fn formatNumberValue(pool: *const InternPool, number_pool: *value_mod.NumberPool, alloc: std.mem.Allocator, v: Value) Error![]const u8 {
    std.debug.assert(v.kind() == .number);
    const n = v.asF64(number_pool);
    const unit_id = v.unitId(number_pool);
    const unit_text = if (unit_id == .none) null else pool.get(unit_id);
    if (unit_text) |unit| {
        if (unitLooksCompound(unit)) {
            var numerators: std.ArrayListUnmanaged([]const u8) = .empty;
            defer numerators.deinit(alloc);
            var denominators: std.ArrayListUnmanaged([]const u8) = .empty;
            defer denominators.deinit(alloc);

            appendUnitTextFactors(alloc, unit, &numerators, &denominators, false) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return value_format.formatNumberWithUnit(alloc, n, unit_text) catch error.OutOfMemory,
            };

            var formatted_value = n;
            const scale = simplifyUnitFactorsCaseInsensitive(&numerators, &denominators);
            if (std.math.isFinite(formatted_value)) {
                formatted_value *= scale;
            }

            if (numerators.items.len == 0 and denominators.items.len == 0) {
                return value_format.formatNumberWithUnit(alloc, formatted_value, null) catch error.OutOfMemory;
            }
            return appendCalcWithCompoundUnit(alloc, formatted_value, numerators.items, denominators.items);
        }
    }
    return value_format.formatNumberWithUnit(alloc, n, unit_text) catch error.OutOfMemory;
}

fn appendUnitTermFactors(
    alloc: std.mem.Allocator,
    raw_term: []const u8,
    numerators: *std.ArrayListUnmanaged([]const u8),
    denominators: *std.ArrayListUnmanaged([]const u8),
    divide: bool,
) Error!void {
    const term = std.mem.trim(u8, raw_term, " \t\r\n");
    if (term.len == 0) return error.NonStaticExpr;

    var idx: usize = 0;
    if (idx < term.len and (term[idx] == '+' or term[idx] == '-')) idx += 1;
    while (idx < term.len and std.ascii.isDigit(term[idx])) : (idx += 1) {}
    if (idx < term.len and term[idx] == '.') {
        idx += 1;
        while (idx < term.len and std.ascii.isDigit(term[idx])) : (idx += 1) {}
    }
    if (idx < term.len and (term[idx] == 'e' or term[idx] == 'E')) {
        var eidx = idx + 1;
        if (eidx < term.len and (term[eidx] == '+' or term[eidx] == '-')) eidx += 1;
        var had_exp_digit = false;
        while (eidx < term.len and std.ascii.isDigit(term[eidx])) : (eidx += 1) {
            had_exp_digit = true;
        }
        if (had_exp_digit) idx = eidx;
    }

    var unit = std.mem.trim(u8, term[idx..], " \t\r\n");
    if (unit.len == 0) return;

    var invert = false;
    if (std.mem.endsWith(u8, unit, "^-1")) {
        unit = std.mem.trimEnd(u8, unit[0 .. unit.len - 3], " \t\r\n");
        invert = true;
    }
    if (unit.len == 0) return;

    if (divide != invert) {
        try denominators.append(alloc, unit);
    } else {
        try numerators.append(alloc, unit);
    }
}

fn appendUnitTextFactors(
    alloc: std.mem.Allocator,
    unit_text: []const u8,
    numerators: *std.ArrayListUnmanaged([]const u8),
    denominators: *std.ArrayListUnmanaged([]const u8),
    divide: bool,
) Error!void {
    var text = std.mem.trim(u8, unit_text, " \t\r\n");
    if (text.len == 0) return;

    if (text[0] == '(' and text[text.len - 1] == ')') {
        text = std.mem.trim(u8, text[1 .. text.len - 1], " \t\r\n");
        if (text.len == 0) return;
    }

    if (std.mem.indexOfScalar(u8, text, '/')) |slash_idx| {
        const left = std.mem.trim(u8, text[0..slash_idx], " \t\r\n");
        const right = std.mem.trim(u8, text[slash_idx + 1 ..], " \t\r\n");
        if (left.len == 0 or right.len == 0) return error.NonStaticExpr;
        try appendUnitTextFactors(alloc, left, numerators, denominators, divide);
        try appendUnitTextFactors(alloc, right, numerators, denominators, !divide);
        return;
    }

    var start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i < text.len and text[i] != '*') continue;
        const part = text[start..i];
        try appendUnitTermFactors(alloc, part, numerators, denominators, divide);
        start = i + 1;
    }
}

fn simplifyUnitFactorsCaseInsensitive(
    numerators: *std.ArrayListUnmanaged([]const u8),
    denominators: *std.ArrayListUnmanaged([]const u8),
) f64 {
    var scale: f64 = 1.0;
    var i: usize = 0;
    while (i < numerators.items.len) {
        const n = numerators.items[i];
        var matched = false;
        var j: usize = 0;
        while (j < denominators.items.len) : (j += 1) {
            if (!std.ascii.eqlIgnoreCase(n, denominators.items[j])) continue;
            _ = numerators.swapRemove(i);
            _ = denominators.swapRemove(j);
            matched = true;
            break;
        }
        if (!matched) {
            j = 0;
            while (j < denominators.items.len) : (j += 1) {
                if (convertComparableUnitValueRuntime(1.0, n, denominators.items[j])) |factor| {
                    _ = numerators.swapRemove(i);
                    _ = denominators.swapRemove(j);
                    scale *= factor;
                    matched = true;
                    break;
                }
            }
        }
        if (!matched) i += 1;
    }
    return scale;
}

fn appendJoinedUnitFactors(
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    items: []const []const u8,
) Error!void {
    var total: usize = 0;
    for (items, 0..) |unit, idx| {
        if (idx != 0) total += 1;
        total += unit.len;
    }
    try out.ensureUnusedCapacity(alloc, total);
    for (items, 0..) |unit, idx| {
        if (idx != 0) out.appendAssumeCapacity('*');
        out.appendSliceAssumeCapacity(unit);
    }
}

fn buildUnitDescriptionFromFactors(
    alloc: std.mem.Allocator,
    numerators: []const []const u8,
    denominators: []const []const u8,
) Error!?[]u8 {
    if (numerators.len == 0 and denominators.len == 0) return null;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);

    if (numerators.len == 0) {
        if (denominators.len == 1) {
            try out.appendSlice(alloc, denominators[0]);
            try out.appendSlice(alloc, "^-1");
            return try out.toOwnedSlice(alloc);
        }
        try out.append(alloc, '(');
        try appendJoinedUnitFactors(&out, alloc, denominators);
        try out.appendSlice(alloc, ")^-1");
        return try out.toOwnedSlice(alloc);
    }

    try appendJoinedUnitFactors(&out, alloc, numerators);
    if (denominators.len == 0) return try out.toOwnedSlice(alloc);

    try out.append(alloc, '/');
    if (denominators.len > 1) try out.append(alloc, '(');
    try appendJoinedUnitFactors(&out, alloc, denominators);
    if (denominators.len > 1) try out.append(alloc, ')');
    return try out.toOwnedSlice(alloc);
}

const CombinedUnitsRuntime = struct {
    unit: InternId,
    factor: f64,
};

fn combineUnitIdsForOp(
    pool: *InternPool,
    alloc: std.mem.Allocator,
    ua: InternId,
    ub: InternId,
) Error!?CombinedUnitsRuntime {
    var numerators: std.ArrayListUnmanaged([]const u8) = .empty;
    defer numerators.deinit(alloc);
    var denominators: std.ArrayListUnmanaged([]const u8) = .empty;
    defer denominators.deinit(alloc);

    appendUnitTextFactors(alloc, pool.get(ua), &numerators, &denominators, false) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    appendUnitTextFactors(alloc, pool.get(ub), &numerators, &denominators, true) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };

    const scale = simplifyUnitFactorsCaseInsensitive(&numerators, &denominators);
    const combined_text = try buildUnitDescriptionFromFactors(alloc, numerators.items, denominators.items);
    if (combined_text == null) {
        return .{ .unit = .none, .factor = scale };
    }
    defer alloc.free(combined_text.?);
    return .{ .unit = try pool.intern(combined_text.?), .factor = scale };
}

fn combineUnitIdsForMul(
    pool: *InternPool,
    alloc: std.mem.Allocator,
    ua: InternId,
    ub: InternId,
) Error!?CombinedUnitsRuntime {
    var numerators: std.ArrayListUnmanaged([]const u8) = .empty;
    defer numerators.deinit(alloc);
    var denominators: std.ArrayListUnmanaged([]const u8) = .empty;
    defer denominators.deinit(alloc);

    appendUnitTextFactors(alloc, pool.get(ua), &numerators, &denominators, false) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    appendUnitTextFactors(alloc, pool.get(ub), &numerators, &denominators, false) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };

    const scale = simplifyUnitFactorsCaseInsensitive(&numerators, &denominators);
    const combined_text = try buildUnitDescriptionFromFactors(alloc, numerators.items, denominators.items);
    if (combined_text == null) {
        return .{ .unit = .none, .factor = scale };
    }
    defer alloc.free(combined_text.?);
    return .{ .unit = try pool.intern(combined_text.?), .factor = scale };
}
