//! Stage 1b-A3 built-in Sass functions for zsass (split modules).
const std = @import("std");
const shared = @import("shared.zig");
const math = @import("math.zig");
const string = @import("string.zig");
const selector = @import("selector.zig");
const color = @import("color.zig");
const list = @import("list.zig");
const map = @import("map.zig");
const meta_dispatch_abi = @import("meta_dispatch_abi.zig");

const Value = shared.Value;
const InternId = shared.InternId;

/// Re-export: error set returned by all builtin implementations.
pub const BuiltinError = shared.BuiltinError;
/// Re-export: per-call context (allocator + intern/color pools + diagnostics).
pub const BuiltinContext = shared.BuiltinContext;
pub const ListIndexCacheKey = shared.ListIndexCacheKey;
/// Re-export: opaque builtin dispatch id (stable across a single build).
pub const Id = shared.Id;

/// Dispatch id for `meta.apply` (mixin).
pub const meta_apply_mixin_id: Id = meta_dispatch_abi.meta_apply_mixin_id;
/// Dispatch id for `meta.load-css` (mixin).
pub const meta_load_css_mixin_id: Id = meta_dispatch_abi.meta_load_css_mixin_id;
/// Dispatch id for `meta.get-function` (function).
pub const meta_get_function_id: Id = meta_dispatch_abi.meta_get_function_id;
/// Dispatch id for `meta.get-mixin` (function).
pub const meta_get_mixin_id: Id = meta_dispatch_abi.meta_get_mixin_id;

pub fn isCrossEntryStatefulFunction(id: Id) bool {
    return switch (id) {
        31, // string.unique-id
        109, // math.random
        => true,
        else => false,
    };
}

fn isMixinOnlyId(id: Id) bool {
    return meta_dispatch_abi.isMixinOnlyId(id);
}

/// Look up the builtin function `module.name` (e.g. `math.abs`) and return its
/// dispatch `Id`, or null if no such builtin exists. Mixin-only builtins are
/// excluded; see `resolveMixin`.
pub fn resolve(module: []const u8, name: []const u8) ?Id {
    const table = buildResolveTable();
    for (table) |row| {
        if (shared.identifierEq(row.m, module) and shared.identifierEq(row.n, name) and !isMixinOnlyId(row.id)) {
            return row.id;
        }
    }
    if (std.mem.eql(u8, module, "meta")) {
        for (meta_dispatch_abi.meta_builtin_specs) |spec| {
            if (shared.identifierEq(spec.name, name) and !isMixinOnlyId(spec.id)) {
                return spec.id;
            }
        }
    }
    return null;
}

/// Look up the builtin mixin `meta.name` (e.g. `meta.apply`, `meta.load-css`)
/// and return its dispatch `Id`, or null for non-meta modules / unknown names.
pub fn resolveMixin(module: []const u8, name: []const u8) ?Id {
    if (!std.mem.eql(u8, module, "meta")) return null;
    return meta_dispatch_abi.resolveMixinId(name);
}

/// For `@use "sass:<module>" as *`: use builtin functions under module
/// Add to lookup map without namespace (preserve existing keys).
pub fn addModuleToStarMap(
    module: []const u8,
    out: *std.StringHashMapUnmanaged(Id),
    alloc: std.mem.Allocator,
) !void {
    const table = buildResolveTable();
    const meta_extra = if (std.mem.eql(u8, module, "meta")) meta_dispatch_abi.meta_builtin_specs.len else 0;
    try out.ensureUnusedCapacity(alloc, @intCast(table.len + meta_extra));
    for (table) |row| {
        if (!std.mem.eql(u8, row.m, module)) continue;
        if (isMixinOnlyId(row.id)) continue;
        if (out.contains(row.n)) continue;
        out.putAssumeCapacity(row.n, row.id);
    }
    if (meta_extra != 0) {
        for (meta_dispatch_abi.meta_builtin_specs) |spec| {
            if (isMixinOnlyId(spec.id)) continue;
            if (out.contains(spec.name)) continue;
            out.putAssumeCapacity(spec.name, spec.id);
        }
    }
}

fn identifierEqSassCase(raw: []const u8, expected: []const u8) bool {
    if (raw.len != expected.len) return false;
    for (raw, expected) |rc, ec| {
        if (rc == ec) continue;
        if ((rc == '_' and ec == '-') or (rc == '-' and ec == '_')) continue;
        return false;
    }
    return true;
}

fn resolveCssMathLegacyGlobal(name: []const u8) ?Id {
    // CSS Values L4 math globals. `exp`/`sign`/`mod`/`rem` reach the dispatch
    // ids directly because they are deliberately not exposed as `sass:math`
    // members (matching official Sass CLI), so `resolve("math", ...)` cannot find them.
    const mappings = [_]struct { query: []const u8, id: Id }{
        .{ .query = "abs", .id = 0 },
        .{ .query = "min", .id = 4 },
        .{ .query = "max", .id = 5 },
        .{ .query = "clamp", .id = 110 },
        .{ .query = "hypot", .id = 21 },
        .{ .query = "sqrt", .id = 11 },
        .{ .query = "pow", .id = 12 },
        .{ .query = "log", .id = 13 },
        .{ .query = "sin", .id = 14 },
        .{ .query = "cos", .id = 15 },
        .{ .query = "tan", .id = 16 },
        .{ .query = "asin", .id = 17 },
        .{ .query = "acos", .id = 18 },
        .{ .query = "atan", .id = 19 },
        .{ .query = "atan2", .id = 20 },
        .{ .query = "exp", .id = 105 },
        .{ .query = "sign", .id = 106 },
        .{ .query = "mod", .id = 107 },
        .{ .query = "rem", .id = 108 },
    };
    inline for (mappings) |entry| {
        if (shared.identifierEq(name, entry.query)) return entry.id;
    }
    return null;
}

/// Fallback for non-namespaced calls for compatibility purposes.
pub fn resolveLegacyGlobal(name: []const u8) ?Id {
    // `scale()` is frequently used as a CSS transform function and is a Sass legacy global
    // Not builtin. Only `scale-color()` is builtin resolved.
    if (shared.identifierEq(name, "scale")) return null;
    if (resolveCssMathLegacyGlobal(name)) |id| return id;

    // Sass identifiers treat `_` and `-` equivalently and are ASCII case insensitive.
    // The legacy global alias below is a Sass-only name that does not conflict with CSS function names, so
    //Normalize comparison using `shared.identifierEq` (e.g. `map_get`  ->  `map.get`).
    if (shared.identifierEq(name, "index")) {
        return resolve("list", "index");
    }
    if (shared.identifierEq(name, "length")) {
        return resolve("list", "length");
    }
    if (shared.identifierEq(name, "comparable")) {
        return resolve("math", "compatible");
    }
    if (shared.identifierEq(name, "alpha")) return 185;
    if (shared.identifierEq(name, "opacity")) return 186;
    if (shared.identifierEq(name, "grayscale")) return 187;
    if (shared.identifierEq(name, "scale-color")) return 49;
    if (shared.identifierEq(name, "adjust-color")) return 50;
    if (shared.identifierEq(name, "change-color")) return 51;
    if (shared.identifierEq(name, "lighten")) return 44;
    if (shared.identifierEq(name, "darken")) return 45;
    if (shared.identifierEq(name, "saturate")) return 46;
    if (shared.identifierEq(name, "desaturate")) return 47;
    if (shared.identifierEq(name, "adjust-hue")) return 48;
    if (shared.identifierEq(name, "opacify")) return 88;
    if (shared.identifierEq(name, "fade-in")) return 88;
    if (shared.identifierEq(name, "transparentize")) return 89;
    if (shared.identifierEq(name, "fade-out")) return 89;
    if (shared.identifierEq(name, "unitless")) {
        return resolve("math", "is-unitless");
    }
    if (shared.identifierEq(name, "math-div")) return resolve("math", "div");
    if (shared.identifierEq(name, "round")) return resolve("math", "math-round");
    if (shared.identifierEq(name, "map-get")) return resolve("map", "get");
    if (shared.identifierEq(name, "map-merge")) return resolve("map", "merge");
    if (shared.identifierEq(name, "map-remove")) return resolve("map", "remove");
    if (shared.identifierEq(name, "map-keys")) return resolve("map", "keys");
    if (shared.identifierEq(name, "map-values")) return resolve("map", "values");
    if (shared.identifierEq(name, "map-has-key")) return resolve("map", "has-key");
    if (shared.identifierEq(name, "list-separator")) return resolve("list", "separator");
    if (shared.identifierEq(name, "list-slash")) return resolve("list", "slash");
    if (shared.identifierEq(name, "str-slice")) return resolve("string", "slice");
    if (shared.identifierEq(name, "str-length")) return resolve("string", "length");
    if (shared.identifierEq(name, "str-insert")) return resolve("string", "insert");
    if (shared.identifierEq(name, "str-index")) return resolve("string", "index");
    if (shared.identifierEq(name, "str-split")) return resolve("string", "split");
    if (shared.identifierEq(name, "selector-append")) return resolve("selector", "append");
    if (shared.identifierEq(name, "selector-nest")) return resolve("selector", "nest");
    if (shared.identifierEq(name, "selector-extend")) return resolve("selector", "extend");
    if (shared.identifierEq(name, "selector-replace")) return resolve("selector", "replace");
    if (shared.identifierEq(name, "selector-unify")) return resolve("selector", "unify");
    if (shared.identifierEq(name, "selector-parse")) return resolve("selector", "parse");
    if (shared.identifierEq(name, "is-superselector")) return resolve("selector", "is-superselector");
    if (shared.identifierEq(name, "simple-selectors")) return resolve("selector", "simple-selectors");
    if (shared.identifierEq(name, "color-space")) return resolve("color", "space");
    if (shared.identifierEq(name, "color-channel")) return resolve("color", "channel");
    if (shared.identifierEq(name, "color-is-missing")) return resolve("color", "is-missing");

    // Legacy global meta builtins are Sass identifiers: `_` and `-` are
    // equivalent, while ASCII case is significant. Keep `TYPE-OF()` as a
    // plain CSS function, but resolve `type_of()` like `type-of()`.
    for (meta_dispatch_abi.meta_builtin_specs) |spec| {
        if (isMixinOnlyId(spec.id)) continue;
        if (identifierEqSassCase(name, spec.name)) return spec.id;
    }

    const order = [_][]const u8{
        "color",
        "math",
        "string",
        "list",
        "map",
        "meta",
        "selector",
    };
    for (order) |mod| {
        if (resolveCaseSensitive(mod, name)) |id| {
            // Sass module-only functions (math.log/sin/...) do not resolve to legacy global.
            if (std.mem.eql(u8, mod, "math") and id >= 11 and id <= 21) continue;
            return id;
        }
    }
    return null;
}

/// A case-sensitive version of `resolve`. Legacy global lookup keeps CSS
/// builtin name conflicts (rgb/rgba/hsl/.../length/nth/append/...)
/// case-sensitive, so mixed-case calls remain plain CSS functions. CSS math
/// functions (min/max/abs/round/...) resolve case-insensitively through
/// `resolveCssMathLegacyGlobal` only.
fn resolveCaseSensitive(module: []const u8, name: []const u8) ?Id {
    const table = buildResolveTable();
    for (table) |row| {
        if (std.mem.eql(u8, row.m, module) and std.mem.eql(u8, row.n, name) and !isMixinOnlyId(row.id)) {
            return row.id;
        }
    }
    if (std.mem.eql(u8, module, "meta")) {
        for (meta_dispatch_abi.meta_builtin_specs) |spec| {
            if (std.mem.eql(u8, spec.name, name) and !isMixinOnlyId(spec.id)) {
                return spec.id;
            }
        }
    }
    return null;
}

/// Resolve plain (unnamespaced) legacy global mixin names (`apply`, `load-css`)
/// to their meta-module dispatch ids. Used when a `@include` has no module prefix.
pub fn resolveLegacyGlobalMixin(name: []const u8) ?Id {
    if (shared.identifierEq(name, "apply")) return meta_apply_mixin_id;
    if (shared.identifierEq(name, "load-css")) return meta_load_css_mixin_id;
    return null;
}

const ResolveRow = struct { m: []const u8, n: []const u8, id: Id };

fn buildResolveTable() []const ResolveRow {
    // zig fmt: off
    const rows: []const ResolveRow = &.{
        .{ .m = "math", .n = "abs", .id = 0 },
        .{ .m = "math", .n = "floor", .id = 1 },
        .{ .m = "math", .n = "ceil", .id = 2 },
        .{ .m = "math", .n = "round", .id = 113 },
        .{ .m = "math", .n = "min", .id = 4 },
        .{ .m = "math", .n = "max", .id = 5 },
        .{ .m = "math", .n = "div", .id = 6 },
        .{ .m = "math", .n = "percentage", .id = 7 },
        .{ .m = "math", .n = "unit", .id = 8 },
        .{ .m = "math", .n = "is-unitless", .id = 9 },
        .{ .m = "math", .n = "compatible", .id = 10 },
        .{ .m = "math", .n = "sqrt", .id = 11 },
        .{ .m = "math", .n = "pow", .id = 12 },
        .{ .m = "math", .n = "log", .id = 13 },
        .{ .m = "math", .n = "sin", .id = 14 },
        .{ .m = "math", .n = "cos", .id = 15 },
        .{ .m = "math", .n = "tan", .id = 16 },
        .{ .m = "math", .n = "asin", .id = 17 },
        .{ .m = "math", .n = "acos", .id = 18 },
        .{ .m = "math", .n = "atan", .id = 19 },
        .{ .m = "math", .n = "atan2", .id = 20 },
        .{ .m = "math", .n = "hypot", .id = 21 },
        .{ .m = "math", .n = "random", .id = 109 },
        .{ .m = "math", .n = "clamp", .id = 110 },
        // legacy global aliases (via resolveLegacyGlobal)
        .{ .m = "math", .n = "math-ceil", .id = 111 },
        .{ .m = "math", .n = "math-floor", .id = 112 },
        .{ .m = "math", .n = "math-round", .id = 3 },
        .{ .m = "math", .n = "math-min", .id = 114 },
        .{ .m = "math", .n = "math-max", .id = 115 },
        .{ .m = "string", .n = "index", .id = 22 },
        .{ .m = "string", .n = "insert", .id = 23 },
        .{ .m = "string", .n = "length", .id = 24 },
        .{ .m = "string", .n = "slice", .id = 25 },
        .{ .m = "string", .n = "split", .id = 26 },
        .{ .m = "string", .n = "to-lower-case", .id = 27 },
        .{ .m = "string", .n = "to-upper-case", .id = 28 },
        .{ .m = "string", .n = "quote", .id = 29 },
        .{ .m = "string", .n = "unquote", .id = 30 },
        .{ .m = "string", .n = "unique-id", .id = 31 },
        .{ .m = "selector", .n = "append", .id = 32 },
        .{ .m = "selector", .n = "nest", .id = 33 },
        .{ .m = "selector", .n = "parse", .id = 34 },
        .{ .m = "selector", .n = "unify", .id = 35 },
        .{ .m = "selector", .n = "is-superselector", .id = 36 },
        .{ .m = "selector", .n = "replace", .id = 37 },
        .{ .m = "selector", .n = "extend", .id = 38 },
        .{ .m = "selector", .n = "simple-selectors", .id = 140 },
        .{ .m = "color", .n = "rgb", .id = 39 },
        .{ .m = "color", .n = "rgba", .id = 40 },
        .{ .m = "color", .n = "hsl", .id = 41 },
        .{ .m = "color", .n = "hsla", .id = 42 },
        .{ .m = "color", .n = "mix", .id = 43 },
        .{ .m = "color", .n = "scale", .id = 49 },
        .{ .m = "color", .n = "adjust", .id = 50 },
        .{ .m = "color", .n = "change", .id = 51 },
        .{ .m = "color", .n = "color", .id = 52 },
        .{ .m = "color", .n = "red", .id = 53 },
        .{ .m = "color", .n = "green", .id = 54 },
        .{ .m = "color", .n = "blue", .id = 55 },
        .{ .m = "color", .n = "hue", .id = 56 },
        .{ .m = "color", .n = "saturation", .id = 57 },
        .{ .m = "color", .n = "lightness", .id = 58 },
        .{ .m = "color", .n = "alpha", .id = 59 },
        .{ .m = "color", .n = "opacity", .id = 184 },
        .{ .m = "color", .n = "whiteness", .id = 83 },
        .{ .m = "color", .n = "blackness", .id = 84 },
        .{ .m = "color", .n = "complement", .id = 85 },
        .{ .m = "color", .n = "invert", .id = 86 },
        .{ .m = "color", .n = "grayscale", .id = 87 },
        .{ .m = "color", .n = "ie-hex-str", .id = 90 },
        .{ .m = "color", .n = "hwb", .id = 91 },
        .{ .m = "color", .n = "lab", .id = 92 },
        .{ .m = "color", .n = "lch", .id = 93 },
        .{ .m = "color", .n = "oklab", .id = 94 },
        .{ .m = "color", .n = "oklch", .id = 95 },
        .{ .m = "color", .n = "is-legacy", .id = 96 },
        .{ .m = "color", .n = "is-in-gamut", .id = 97 },
        .{ .m = "color", .n = "is-missing", .id = 98 },
        .{ .m = "color", .n = "is-powerless", .id = 99 },
        .{ .m = "color", .n = "space", .id = 100 },
        .{ .m = "color", .n = "same", .id = 101 },
        .{ .m = "color", .n = "to-gamut", .id = 102 },
        .{ .m = "color", .n = "to-space", .id = 103 },
        .{ .m = "color", .n = "channel", .id = 81 },
        .{ .m = "list", .n = "append", .id = 60 },
        .{ .m = "list", .n = "index", .id = 61 },
        .{ .m = "list", .n = "join", .id = 62 },
        .{ .m = "list", .n = "length", .id = 63 },
        .{ .m = "list", .n = "nth", .id = 64 },
        .{ .m = "list", .n = "set-nth", .id = 65 },
        .{ .m = "list", .n = "slash", .id = 66 },
        .{ .m = "list", .n = "list-slash", .id = 66 },
        .{ .m = "list", .n = "zip", .id = 67 },
        .{ .m = "list", .n = "is-bracketed", .id = 68 },
        .{ .m = "list", .n = "list-separator", .id = 104 },
        .{ .m = "list", .n = "separator", .id = 104 },
        .{ .m = "map", .n = "get", .id = 69 },
        .{ .m = "map", .n = "has-key", .id = 70 },
        .{ .m = "map", .n = "merge", .id = 71 },
        .{ .m = "map", .n = "remove", .id = 72 },
        .{ .m = "map", .n = "keys", .id = 73 },
        .{ .m = "map", .n = "values", .id = 74 },
        .{ .m = "map", .n = "deep-merge", .id = 75 },
        .{ .m = "map", .n = "deep-remove", .id = 76 },
        .{ .m = "map", .n = "set", .id = 82 },
    };
    // zig fmt: on
    return rows;
}

/// `module` is `color` / `math` etc. (without `sass:`). Function name listed in resolve table  ->  Register builtin id.
pub fn fillBuiltinFunctionNameToIdMap(
    alloc: std.mem.Allocator,
    module: []const u8,
    out: *std.StringHashMapUnmanaged(Id),
) !void {
    const table = buildResolveTable();
    const meta_extra = if (std.mem.eql(u8, module, "meta")) meta_dispatch_abi.meta_builtin_specs.len else 0;
    try out.ensureUnusedCapacity(alloc, @intCast(table.len + meta_extra));
    for (table) |row| {
        if (!std.mem.eql(u8, row.m, module)) continue;
        if (isMixinOnlyId(row.id)) continue;
        if (out.contains(row.n)) continue;
        out.putAssumeCapacity(row.n, row.id);
    }
    if (meta_extra != 0) {
        for (meta_dispatch_abi.meta_builtin_specs) |spec| {
            if (isMixinOnlyId(spec.id)) continue;
            if (out.contains(spec.name)) continue;
            out.putAssumeCapacity(spec.name, spec.id);
        }
    }
}

/// `module` is `meta` etc. (without `sass:`). Mixin-only builtin name -> id.
pub fn fillBuiltinMixinNameToIdMap(
    alloc: std.mem.Allocator,
    module: []const u8,
    out: *std.StringHashMapUnmanaged(Id),
) !void {
    if (!std.mem.eql(u8, module, "meta")) return;
    try out.ensureUnusedCapacity(alloc, meta_dispatch_abi.meta_builtin_specs.len);
    for (meta_dispatch_abi.meta_builtin_specs) |spec| {
        if (!isMixinOnlyId(spec.id)) continue;
        if (out.contains(spec.name)) continue;
        out.putAssumeCapacity(spec.name, spec.id);
    }
}

/// Reverse lookup: builtin dispatch `Id`  ->  its registered name (for logging /
/// error messages). Returns null for unknown ids.
pub fn debugNameById(id: Id) ?[]const u8 {
    const table = buildResolveTable();
    for (table) |row| {
        if (row.id == id) {
            return row.n;
        }
    }
    for (meta_dispatch_abi.meta_builtin_specs) |spec| {
        if (spec.id == id) return spec.name;
    }
    return null;
}

extern fn zsass_builtin_meta_dispatch(
    ctx: *BuiltinContext,
    id: Id,
    args_ptr: [*]const Value,
    args_len: usize,
    arg_names_ptr: [*]const InternId,
    arg_names_len: usize,
    out_value: *Value,
) callconv(.c) meta_dispatch_abi.Status;

/// Unified entry for invoking a resolved builtin by `Id`. Dispatch-tier
/// builtins (meta module) trampoline through `zsass_builtin_meta_dispatch`;
/// the rest fan out to per-module inline tables. `arg_names` carries named
/// keyword arguments (interned); positional args come through `args`.
pub fn dispatch(ctx: *BuiltinContext, id: Id, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    if (meta_dispatch_abi.isDispatchId(id)) {
        var out: Value = Value.nil_v;
        const status = zsass_builtin_meta_dispatch(
            ctx,
            id,
            args.ptr,
            args.len,
            arg_names.ptr,
            arg_names.len,
            &out,
        );
        return switch (status) {
            .ok => out,
            else => meta_dispatch_abi.builtinErrorFromStatus(status),
        };
    }
    return switch (id) {
        0 => math.math_abs(ctx, args, arg_names),
        1 => math.math_floor(ctx, args, arg_names),
        2 => math.math_ceil(ctx, args, arg_names),
        3 => math.math_round(ctx, args, arg_names),
        4 => math.math_min(ctx, args, arg_names),
        5 => math.math_max(ctx, args, arg_names),
        6 => math.math_div(ctx, args, arg_names),
        7 => math.math_percentage(ctx, args),
        8 => math.math_unit(ctx, args),
        9 => math.math_is_unitless(ctx, args),
        10 => math.math_compatible(ctx, args),
        11 => math.math_sqrt(ctx, args),
        12 => math.math_pow(ctx, args, arg_names),
        13 => math.math_log(ctx, args, arg_names),
        14 => math.math_sin(ctx, args),
        15 => math.math_cos(ctx, args),
        16 => math.math_tan(ctx, args),
        17 => math.math_asin(ctx, args),
        18 => math.math_acos(ctx, args),
        19 => math.math_atan(ctx, args),
        20 => math.math_atan2(ctx, args, arg_names),
        21 => math.math_hypot(ctx, args, arg_names),
        105 => math.math_exp(ctx, args),
        106 => math.math_sign(ctx, args),
        107 => math.math_mod(ctx, args, arg_names),
        108 => math.math_rem(ctx, args, arg_names),
        109 => math.math_random(ctx, args, arg_names),
        110 => math.math_clamp(ctx, args, arg_names),
        111 => math.math_ceil(ctx, args, arg_names),
        112 => math.math_floor(ctx, args, arg_names),
        113 => math.math_round_namespaced(ctx, args, arg_names),
        114 => math.math_min(ctx, args, arg_names),
        115 => math.math_max(ctx, args, arg_names),
        22 => string.string_index(ctx, args, arg_names),
        23 => string.string_insert(ctx, args, arg_names),
        24 => string.string_length(ctx, args),
        25 => string.string_slice(ctx, args, arg_names),
        26 => string.string_split(ctx, args, arg_names),
        27 => string.string_to_lower(ctx, args),
        28 => string.string_to_upper(ctx, args),
        29 => string.string_quote(ctx, args),
        30 => string.string_unquote(ctx, args),
        31 => string.string_unique_id(ctx, args),
        32 => selector.selector_append(ctx, args),
        33 => selector.selector_nest(ctx, args),
        34 => selector.selector_parse(ctx, args, arg_names),
        35 => selector.selector_unify(ctx, args, arg_names),
        36 => selector.selector_is_super(ctx, args, arg_names),
        37 => selector.selector_replace(ctx, args, arg_names),
        38 => selector.selector_extend(ctx, args, arg_names),
        140 => selector.selector_simple_selectors(ctx, args, arg_names),
        39 => color.color_rgb(ctx, args, arg_names),
        40 => color.color_rgba(ctx, args, arg_names),
        41 => color.color_hsl(ctx, args, arg_names),
        42 => color.color_hsla(ctx, args, arg_names),
        43 => color.color_mix(ctx, args, arg_names),
        44 => color.color_lighten(ctx, args),
        45 => color.color_darken(ctx, args),
        46 => color.color_saturate(ctx, args),
        47 => color.color_desaturate(ctx, args),
        48 => color.color_adjust_hue(ctx, args),
        49 => color.color_scale(ctx, args, arg_names),
        50 => color.color_adjust(ctx, args, arg_names),
        51 => color.color_change(ctx, args, arg_names),
        52 => color.color_color(ctx, args, arg_names),
        53 => color.color_red(ctx, args),
        54 => color.color_green(ctx, args),
        55 => color.color_blue(ctx, args),
        56 => color.color_hue(ctx, args),
        57 => color.color_saturation(ctx, args),
        58 => color.color_lightness(ctx, args),
        59 => color.color_alpha(ctx, args, arg_names),
        184 => color.color_opacity(ctx, args, arg_names),
        185 => color.global_alpha(ctx, args, arg_names),
        186 => color.global_opacity(ctx, args, arg_names),
        83 => color.color_whiteness(ctx, args),
        84 => color.color_blackness(ctx, args),
        85 => color.color_complement(ctx, args, arg_names),
        86 => color.color_invert(ctx, args, arg_names),
        87 => color.color_grayscale(ctx, args),
        187 => color.global_grayscale(ctx, args),
        88 => color.color_opacify(ctx, args),
        89 => color.color_transparentize(ctx, args),
        90 => color.color_ie_hex_str(ctx, args),
        91 => color.color_hwb(ctx, args, arg_names),
        60 => list.list_append(ctx, args, arg_names),
        61 => list.list_index(ctx, args, arg_names),
        62 => list.list_join(ctx, args, arg_names),
        63 => list.list_length(ctx, args, arg_names),
        64 => list.list_nth(ctx, args, arg_names),
        65 => list.list_set_nth(ctx, args, arg_names),
        66 => list.list_slash(ctx, args, arg_names),
        67 => list.list_zip(ctx, args),
        68 => list.list_is_bracketed(ctx, args, arg_names),
        104 => list.list_separator(ctx, args, arg_names),
        69 => map.map_get(ctx, args),
        70 => map.map_has_key(ctx, args),
        71 => map.map_merge(ctx, args),
        72 => map.map_remove(ctx, args, arg_names),
        73 => map.map_keys(ctx, args),
        74 => map.map_values(ctx, args),
        75 => map.map_deep_merge(ctx, args),
        76 => map.map_deep_remove(ctx, args),
        82 => map.map_set(ctx, args, arg_names),
        81 => color.color_channel(ctx, args, arg_names),
        92 => color.color_lab(ctx, args, arg_names),
        93 => color.color_lch(ctx, args, arg_names),
        94 => color.color_oklab(ctx, args, arg_names),
        95 => color.color_oklch(ctx, args, arg_names),
        96 => color.color_is_legacy(ctx, args, arg_names),
        97 => color.color_is_in_gamut(ctx, args, arg_names),
        98 => color.color_is_missing(ctx, args, arg_names),
        99 => color.color_is_powerless(ctx, args, arg_names),
        100 => color.color_space(ctx, args, arg_names),
        101 => color.color_same(ctx, args, arg_names),
        102 => color.color_to_gamut(ctx, args, arg_names),
        103 => color.color_to_space(ctx, args, arg_names),
        else => error.BuiltinUnsupported,
    };
}

const testing = std.testing;

test "resolveLegacyGlobal: css math names are case-insensitive" {
    try testing.expectEqual(resolve("math", "abs"), resolveLegacyGlobal("AbS"));
    try testing.expectEqual(resolve("math", "min"), resolveLegacyGlobal("MiN"));
    try testing.expectEqual(resolve("math", "max"), resolveLegacyGlobal("MaX"));
    try testing.expectEqual(resolve("math", "clamp"), resolveLegacyGlobal("ClAmP"));
    try testing.expectEqual(resolve("math", "hypot"), resolveLegacyGlobal("hYpOt"));
    // mod/rem/exp/sign exist only as bare CSS L4 globals, not as sass:math members.
    try testing.expectEqual(@as(?Id, null), resolve("math", "mod"));
    try testing.expectEqual(@as(?Id, null), resolve("math", "rem"));
    try testing.expectEqual(@as(?Id, 107), resolveLegacyGlobal("MoD"));
    try testing.expectEqual(@as(?Id, 108), resolveLegacyGlobal("ReM"));
    try testing.expectEqual(@as(?Id, 105), resolveLegacyGlobal("ExP"));
    try testing.expectEqual(@as(?Id, 106), resolveLegacyGlobal("SiGn"));
}

test "resolveLegacyGlobal: scale keeps CSS transform passthrough" {
    try testing.expectEqual(@as(?Id, null), resolveLegacyGlobal("ScAlE"));
}

test "resolveLegacyGlobal: meta names accept underscores but keep case-sensitive CSS fallback" {
    try testing.expectEqual(resolve("meta", "type-of"), resolveLegacyGlobal("type_of"));
    try testing.expectEqual(resolve("meta", "feature-exists"), resolveLegacyGlobal("feature_exists"));
    try testing.expectEqual(@as(?Id, null), resolveLegacyGlobal("TYPE-OF"));
}
