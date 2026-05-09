//! NaN-boxed Value (P4 commit 3 Step B fused implementation, 8-byte u64).
//!
//! Layout:
//!   unitless number:
//! bits[63:48] != 0xFFFC (i.e. high 16 bit is not NaN-box signature)
//! bits = @bitCast(f64) directly pack
//!
//!   tagged value (non-number / unit-bearing number / callable / etc.):
//!     bits[63:48] = 0xFFFC                    (NaN signature, negative quiet NaN
//!                                              with mantissa[50]=1; zig f64
//! arithmetic is 0x7FF8 / 0xFFF8 series
//! because it only generates canonical NaNs
//! Assuming no collision with 0xFFFC)
//! bits[47:40] = kind tag (8 bits, ValueKind enum value)
//! bits[39:32] = aux byte (8 bits, directly pack string flags / list meta)
//!     bits[31:0]  = handle / payload (32 bits)
//!
//! Kind-specific aux/handle usage:
//!   nil:               aux=0, handle=0
//!   boolean:           aux=0, handle=0/1
//! number (with unit): aux=0, handle=index into NumberPool (sidecar)
//!   string:            aux=StringFlags (5 bit), handle=InternId
//!   color:             aux=0, handle=index into ColorPool
//!   list:              aux=ListMeta (5 bit) + parent_selector_none (1 bit),
//!                      handle=index into ListPool
//! calc_fragment: aux=0, handle (existing meaning)
//! interp_fragment: aux=0, handle (existing meaning)
//!   callable:          aux=0, handle=index into CallablePayloadPool (sidecar)
//!
//! callable / unit-bearing number is a 32-bit handle and spills to sidecar.
//! String / list flags are packed directly into aux byte, so sidecar is not necessary.

const std = @import("std");
const intern_pool_mod = @import("../runtime/intern_pool.zig");
const color_mod = @import("../color/color.zig");

const InternId = intern_pool_mod.InternId;

pub const ColorMissingMask = u4;

pub const InspectColorRepr = enum(u2) {
    auto = 0,
    literal_short_hex = 1,
    literal_long_hex = 2,
    legacy_rgb_function = 3,
};

pub const ColorEntry = struct {
    channels: [4]f64,
    space: color_mod.ColorSpace,
    missing: ColorMissingMask = 0,
    legacy: bool,
    refcount: u32 = 1,
    prefer_long_hex: bool = false,
    inspect_repr: InspectColorRepr = .auto,
    inspect_uppercase_hex: bool = false,
};

pub const ColorPool = std.ArrayListUnmanaged(ColorEntry);

/// Sidecar payload for unit-bearing numbers (NaN-box stage 3).
const NumberPayload = struct {
    value: f64,
    unit: InternId,
};

pub const NumberPool = std.ArrayListUnmanaged(NumberPayload);

/// Sidecar payload for callable values (NaN-box stage 3).
/// Hold 96-bit (handle:32 / flags:16 / module_id:16 / name:32).
const CallablePayload = struct {
    handle: u32,
    flags: u16,
    module_id: u16,
    name: InternId,
};

pub const CallablePayloadPool = std.ArrayListUnmanaged(CallablePayload);

pub const ListSeparator = enum(u2) {
    space = 0,
    comma = 1,
    slash = 2,
    undecided = 3,
};

/// In the stage 3 layout, pool is not used because it packs directly into aux byte, but
/// Leave type itself for compatibility with existing API (empty pool placeholder).
pub const ListMeta = packed struct {
    separator: ListSeparator,
    bracketed: bool,
    is_map: bool,
    coerce_slash: bool,
    _pad: u3 = 0,
};

pub const ListMetaPool = std.ArrayListUnmanaged(ListMeta);
pub const empty_list_meta_pool: []const ListMeta = &.{};

pub const StringFlags = packed struct {
    quoted: bool,
    from_inspect: bool,
    named_color_literal: bool,
    preserve_ampersand: bool,
    preserve_literal_text: bool,
    _pad: u3 = 0,
};

pub const StringFlagsPool = std.ArrayListUnmanaged(StringFlags);
pub const empty_string_flags_pool: []const StringFlags = &.{};

pub const ValueKind = enum(u8) {
    nil = 0,
    boolean = 1,
    number = 2,
    string = 3,
    color = 4,
    list = 5,
    calc_fragment = 6,
    interp_fragment = 7,
    callable = 8,
    _count,
};

pub const ListHandle = u32;

// aux byte bit positions (inline flag pack for string/list).
const string_quoted_bit: u8 = 1 << 0;
const string_from_inspect_bit: u8 = 1 << 1;
const string_named_color_literal_bit: u8 = 1 << 2;
const string_preserve_ampersand_bit: u8 = 1 << 3;
const string_preserve_literal_text_bit: u8 = 1 << 4;
const string_preserve_decl_text_bit: u8 = 1 << 5;

const list_separator_mask: u8 = 0b11;
const list_bracketed_bit: u8 = 0b100;
const list_map_bit: u8 = 0b1000;
const list_slash_coerce_bit: u8 = 0b1_0000;
const list_parent_selector_none_bit: u8 = 0b10_0000;
const list_builtin_slash_bit: u8 = 0b100_0000;

pub const callable_flag_is_mixin: u16 = 1 << 0;
pub const callable_flag_is_builtin: u16 = 1 << 1;
pub const callable_flag_has_module: u16 = 1 << 2;
pub const callable_flag_is_css: u16 = 1 << 3;
pub const callable_flag_accepts_content: u16 = 1 << 4;
pub const callable_flag_capture_callers_locals: u16 = 1 << 5;
pub const callable_flag_css_late_sass_resolution: u16 = 1 << 6;
pub const callable_flag_prebound: u16 = 1 << 7;

// NaN-box signature (high 16 bits). zig f64 operations usually use the 0x7FF8 / 0xFFF8 series.
// Since only canonical NaN is generated, no collision with 0xFFFC is assumed.
const nan_signature: u64 = 0xFFFC;
const nan_signature_shift: u6 = 48;
const tag_shift: u6 = 40;
const aux_shift: u6 = 32;
const handle_mask: u64 = 0xFFFF_FFFF;
const aux_mask: u64 = 0xFF;
const tag_mask: u64 = 0xFF;
const sig_mask: u64 = 0xFFFF_0000_0000_0000;
const sig_value: u64 = nan_signature << nan_signature_shift;

inline fn packTagged(tag: ValueKind, aux: u8, handle: u32) u64 {
    return sig_value |
        (@as(u64, @intFromEnum(tag)) << tag_shift) |
        (@as(u64, aux) << aux_shift) |
        @as(u64, handle);
}

pub inline fn isLegacyColorSpace(space: color_mod.ColorSpace) bool {
    return space == .srgb or space == .hsl or space == .hwb;
}

pub fn pushColorEntry(
    pool: *ColorPool,
    allocator: std.mem.Allocator,
    entry: ColorEntry,
) std.mem.Allocator.Error!u32 {
    const handle: u32 = std.math.cast(u32, pool.items.len) orelse
        std.debug.panic("ColorPool index overflow (exceeds u32)", .{});
    try pool.append(allocator, entry);
    return handle;
}

pub const Value = extern struct {
    bits: u64,

    pub const nil_v: Value = .{ .bits = packTagged(.nil, 0, 0) };
    pub const true_v: Value = .{ .bits = packTagged(.boolean, 0, 1) };
    pub const false_v: Value = .{ .bits = packTagged(.boolean, 0, 0) };

    inline fn isNanBoxed(self: Value) bool {
        return (self.bits & sig_mask) == sig_value;
    }

    inline fn rawTag(self: Value) u8 {
        return @truncate((self.bits >> tag_shift) & tag_mask);
    }

    inline fn auxByte(self: Value) u8 {
        return @truncate((self.bits >> aux_shift) & aux_mask);
    }

    pub inline fn kind(self: Value) ValueKind {
        if (!self.isNanBoxed()) return .number;
        return @enumFromInt(self.rawTag());
    }

    /// Raw 32-bit payload accessor. Returns the low 32 bits of the aux+handle part in tagged Value.
    /// Calls to unitless numbers have no meaning and are only used for legacy compatibility.
    pub inline fn p32Of(self: Value) u32 {
        return @truncate(self.bits & handle_mask);
    }

    /// Raw 64-bit payload accessor. Legacy `_p64` Returns equivalent value.
    /// Handle bit (0/1) for boolean, 0 for calc/interp_fragment
    /// (In legacy, `_p64=0` was fixed and used for eq).
    pub inline fn p64Of(self: Value) u64 {
        if (!self.isNanBoxed()) return self.bits;
        return switch (self.rawTag()) {
            @intFromEnum(ValueKind.boolean) => self.bits & handle_mask,
            @intFromEnum(ValueKind.string) => @as(u64, self.auxByte()),
            @intFromEnum(ValueKind.list) => @as(u64, self.auxByte()),
            @intFromEnum(ValueKind.calc_fragment),
            @intFromEnum(ValueKind.interp_fragment),
            => 0,
            // For other kinds, fallback to low-32 handle bits.
            else => self.bits & handle_mask,
        };
    }

    pub inline fn numberUnitless(v: f64) Value {
        const bits: u64 = @bitCast(v);
        // SAFETY: unitless numbers are distinguished from tagged values by
        // bits[63:48] != nan_signature. Non-canonical NaN patterns could collide.
        std.debug.assert((bits >> nan_signature_shift) != nan_signature);
        return .{ .bits = bits };
    }

    pub fn number(
        v: f64,
        unit: InternId,
        pool: *NumberPool,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!Value {
        if (unit == .none) return numberUnitless(v);
        const handle: u32 = std.math.cast(u32, pool.items.len) orelse
            std.debug.panic("NumberPool index overflow (exceeds u32)", .{});
        try pool.append(allocator, .{ .value = v, .unit = unit });
        return .{ .bits = packTagged(.number, 0, handle) };
    }

    pub inline fn asF64(self: Value, pool: *const NumberPool) f64 {
        if (!self.isNanBoxed()) return @bitCast(self.bits);
        std.debug.assert(self.rawTag() == @intFromEnum(ValueKind.number));
        const handle: u32 = @truncate(self.bits & handle_mask);
        return pool.items[handle].value;
    }

    pub inline fn unitId(self: Value, pool: *const NumberPool) InternId {
        if (!self.isNanBoxed()) return .none;
        std.debug.assert(self.rawTag() == @intFromEnum(ValueKind.number));
        const handle: u32 = @truncate(self.bits & handle_mask);
        return pool.items[handle].unit;
    }

    pub inline fn isNumber(self: Value) bool {
        if (!self.isNanBoxed()) return true; // unitless number
        return self.rawTag() == @intFromEnum(ValueKind.number);
    }

    pub inline fn isString(self: Value) bool {
        return self.isNanBoxed() and self.rawTag() == @intFromEnum(ValueKind.string);
    }

    pub inline fn isTruthy(self: Value) bool {
        if (!self.isNanBoxed()) return true; // any unitless number is truthy
        return switch (self.rawTag()) {
            @intFromEnum(ValueKind.nil) => false,
            @intFromEnum(ValueKind.boolean) => (self.bits & handle_mask) != 0,
            else => true,
        };
    }

    pub inline fn string(intern: InternId, quoted: bool) Value {
        return stringWithFlags(intern, quoted, false);
    }

    pub inline fn stringPreservingAmpersand(intern: InternId, quoted: bool) Value {
        var aux: u8 = 0;
        if (quoted) aux |= string_quoted_bit;
        aux |= string_preserve_ampersand_bit;
        return .{ .bits = packTagged(.string, aux, @intFromEnum(intern)) };
    }

    pub inline fn stringWithFlags(intern: InternId, quoted: bool, from_inspect: bool) Value {
        return stringWithFlagsEx(intern, quoted, from_inspect, false);
    }

    pub inline fn stringWithFlagsEx(
        intern: InternId,
        quoted: bool,
        from_inspect: bool,
        named_color_literal: bool,
    ) Value {
        var aux: u8 = 0;
        if (quoted) aux |= string_quoted_bit;
        if (from_inspect) aux |= string_from_inspect_bit;
        if (named_color_literal) aux |= string_named_color_literal_bit;
        return .{ .bits = packTagged(.string, aux, @intFromEnum(intern)) };
    }

    pub inline fn stringIntern(self: Value) InternId {
        std.debug.assert(self.kind() == .string);
        return @enumFromInt(@as(u32, @truncate(self.bits & handle_mask)));
    }

    pub inline fn stringQuoted(self: Value, pool: []const StringFlags) bool {
        _ = pool;
        std.debug.assert(self.kind() == .string);
        return (self.auxByte() & string_quoted_bit) != 0;
    }

    pub inline fn stringFromInspect(self: Value, pool: []const StringFlags) bool {
        _ = pool;
        std.debug.assert(self.kind() == .string);
        return (self.auxByte() & string_from_inspect_bit) != 0;
    }

    pub inline fn stringNamedColorLiteral(self: Value, pool: []const StringFlags) bool {
        _ = pool;
        std.debug.assert(self.kind() == .string);
        return (self.auxByte() & string_named_color_literal_bit) != 0;
    }

    pub inline fn stringPreservesAmpersand(self: Value, pool: []const StringFlags) bool {
        _ = pool;
        std.debug.assert(self.kind() == .string);
        return (self.auxByte() & string_preserve_ampersand_bit) != 0;
    }

    pub inline fn stringPreserveLiteralText(self: Value, pool: []const StringFlags) bool {
        _ = pool;
        std.debug.assert(self.kind() == .string);
        return (self.auxByte() & string_preserve_literal_text_bit) != 0;
    }

    pub inline fn stringPreserveDeclText(self: Value, pool: []const StringFlags) bool {
        _ = pool;
        std.debug.assert(self.kind() == .string);
        return (self.auxByte() & string_preserve_decl_text_bit) != 0;
    }

    pub inline fn withPreserveLiteralText(self: Value) Value {
        std.debug.assert(self.kind() == .string);
        return .{ .bits = self.bits | (@as(u64, string_preserve_literal_text_bit) << aux_shift) };
    }

    pub inline fn withPreserveDeclText(self: Value) Value {
        std.debug.assert(self.kind() == .string);
        return .{ .bits = self.bits | (@as(u64, string_preserve_decl_text_bit) << aux_shift) };
    }

    pub inline fn list(handle: ListHandle) Value {
        return listWithSpace(handle, false);
    }

    pub inline fn packListFlagsMetaEx(separator: ListSeparator, is_bracketed: bool, is_map: bool, slash_coercible: bool) u32 {
        const bracketed: u32 = if (is_bracketed) 0b100 else 0;
        const map_flag: u32 = if (is_map) 0b1000 else 0;
        const slash_flag: u32 = if (slash_coercible) 0b1_0000 else 0;
        return @as(u32, @intFromEnum(separator)) | bracketed | map_flag | slash_flag;
    }

    pub inline fn packListFlagsMeta(separator: ListSeparator, is_bracketed: bool, is_map: bool) u32 {
        return packListFlagsMetaEx(separator, is_bracketed, is_map, false);
    }

    pub inline fn packListFlags(separator: ListSeparator, is_bracketed: bool) u32 {
        return packListFlagsMeta(separator, is_bracketed, false);
    }

    pub inline fn unpackListSeparator(flags: u32) ListSeparator {
        return switch (flags & 0b11) {
            0 => .space,
            1 => .comma,
            2 => .slash,
            else => .undecided,
        };
    }

    pub inline fn unpackListBracketed(flags: u32) bool {
        return (flags & 0b100) != 0;
    }

    pub inline fn unpackListMap(flags: u32) bool {
        return (flags & 0b1000) != 0;
    }

    pub inline fn unpackListSlashCoerce(flags: u32) bool {
        return (flags & 0b1_0000) != 0;
    }

    pub inline fn listWith(handle: ListHandle, separator: ListSeparator, is_bracketed: bool) Value {
        return listWithMeta(handle, separator, is_bracketed, false);
    }

    pub inline fn listWithPool(handle: ListHandle, separator: ListSeparator, is_bracketed: bool, pool: *ListMetaPool) Value {
        _ = pool;
        return listWithMeta(handle, separator, is_bracketed, false);
    }

    pub inline fn listWithMetaEx(handle: ListHandle, separator: ListSeparator, is_bracketed: bool, is_map: bool, slash_coercible: bool) Value {
        const aux: u8 = @truncate(packListFlagsMetaEx(separator, is_bracketed, is_map, slash_coercible));
        return .{ .bits = packTagged(.list, aux, handle) };
    }

    pub inline fn listWithMetaExPool(handle: ListHandle, separator: ListSeparator, is_bracketed: bool, is_map: bool, slash_coercible: bool, pool: *ListMetaPool) Value {
        _ = pool;
        return listWithMetaEx(handle, separator, is_bracketed, is_map, slash_coercible);
    }

    pub inline fn listWithMeta(handle: ListHandle, separator: ListSeparator, is_bracketed: bool, is_map: bool) Value {
        return listWithMetaEx(handle, separator, is_bracketed, is_map, false);
    }

    pub inline fn listWithMetaPool(handle: ListHandle, separator: ListSeparator, is_bracketed: bool, is_map: bool, pool: *ListMetaPool) Value {
        _ = pool;
        return listWithMetaEx(handle, separator, is_bracketed, is_map, false);
    }

    pub inline fn listWithComma(handle: ListHandle, is_bracketed: bool) Value {
        return listWith(handle, .comma, is_bracketed);
    }

    pub inline fn listWithCommaPool(handle: ListHandle, is_bracketed: bool, pool: *ListMetaPool) Value {
        _ = pool;
        return listWith(handle, .comma, is_bracketed);
    }

    pub inline fn listWithSpace(handle: ListHandle, is_bracketed: bool) Value {
        return listWith(handle, .space, is_bracketed);
    }

    pub inline fn listWithSpacePool(handle: ListHandle, is_bracketed: bool, pool: *ListMetaPool) Value {
        _ = pool;
        return listWith(handle, .space, is_bracketed);
    }

    pub inline fn listWithSlash(handle: ListHandle, is_bracketed: bool) Value {
        return listWith(handle, .slash, is_bracketed);
    }

    pub inline fn listWithSlashPool(handle: ListHandle, is_bracketed: bool, pool: *ListMetaPool) Value {
        _ = pool;
        return listWith(handle, .slash, is_bracketed);
    }

    pub inline fn listHandle(self: Value) ListHandle {
        std.debug.assert(self.kind() == .list);
        return @truncate(self.bits & handle_mask);
    }

    pub inline fn listSeparator(self: Value, pool: []const ListMeta) ListSeparator {
        _ = pool;
        std.debug.assert(self.kind() == .list);
        return switch (self.auxByte() & list_separator_mask) {
            0 => .space,
            1 => .comma,
            2 => .slash,
            else => .undecided,
        };
    }

    pub inline fn listBracketed(self: Value, pool: []const ListMeta) bool {
        _ = pool;
        std.debug.assert(self.kind() == .list);
        return (self.auxByte() & list_bracketed_bit) != 0;
    }

    pub inline fn listIsMap(self: Value, pool: []const ListMeta) bool {
        _ = pool;
        std.debug.assert(self.kind() == .list);
        return (self.auxByte() & list_map_bit) != 0;
    }

    pub inline fn listCoerceSlash(self: Value, pool: []const ListMeta) bool {
        _ = pool;
        std.debug.assert(self.kind() == .list);
        return (self.auxByte() & list_slash_coerce_bit) != 0;
    }

    pub inline fn listParentSelectorNone(self: Value) bool {
        std.debug.assert(self.kind() == .list);
        return (self.auxByte() & list_parent_selector_none_bit) != 0;
    }

    pub inline fn listFromBuiltinSlash(self: Value) bool {
        std.debug.assert(self.kind() == .list);
        return (self.auxByte() & list_builtin_slash_bit) != 0;
    }

    pub inline fn withListParentSelectorNone(self: Value) Value {
        std.debug.assert(self.kind() == .list);
        return .{ .bits = self.bits | (@as(u64, list_parent_selector_none_bit) << aux_shift) };
    }

    pub inline fn withBuiltinSlashList(self: Value) Value {
        std.debug.assert(self.kind() == .list);
        return .{ .bits = self.bits | (@as(u64, list_builtin_slash_bit) << aux_shift) };
    }

    pub inline fn listComma(self: Value, pool: []const ListMeta) bool {
        return self.listSeparator(pool) == .comma;
    }

    pub inline fn listSpace(self: Value, pool: []const ListMeta) bool {
        return self.listSeparator(pool) == .space;
    }

    pub inline fn listSlash(self: Value, pool: []const ListMeta) bool {
        return self.listSeparator(pool) == .slash;
    }

    pub inline fn listSeparatorCss(self: Value, pool: []const ListMeta) []const u8 {
        return listSeparatorCssFrom(self.listSeparator(pool));
    }

    pub inline fn listItems(self: Value, ctx: *const ValueContext) []const Value {
        if (self.kind() != .list) return &.{};
        const h = self.listHandle();
        if (h >= ctx.list_pool.items.len) return &.{};
        return ctx.list_pool.items[h].items;
    }

    pub inline fn calcFragment(handle: u32) Value {
        return .{ .bits = packTagged(.calc_fragment, 0, handle) };
    }

    pub inline fn calcHandle(self: Value) u32 {
        std.debug.assert(self.kind() == .calc_fragment);
        return @truncate(self.bits & handle_mask);
    }

    pub inline fn interpFragment(handle: u32) Value {
        return .{ .bits = packTagged(.interp_fragment, 0, handle) };
    }

    pub inline fn interpHandle(self: Value) u32 {
        std.debug.assert(self.kind() == .interp_fragment);
        return @truncate(self.bits & handle_mask);
    }

    /// Legacy callable constructor for tests / debug paths.
    /// `flags` uses the low 16 bits stored in CallablePayload (module_id=0 / name=.none).
    pub fn callable(
        h: u32,
        flags: u16,
        pool: *CallablePayloadPool,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!Value {
        return callableMake(h, flags, 0, .none, pool, allocator);
    }

    pub fn callableMake(
        handle: u32,
        flags: u16,
        module_id: u16,
        name: InternId,
        pool: *CallablePayloadPool,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!Value {
        const pool_handle: u32 = std.math.cast(u32, pool.items.len) orelse
            std.debug.panic("CallablePayloadPool index overflow (exceeds u32)", .{});
        try pool.append(allocator, .{
            .handle = handle,
            .flags = flags,
            .module_id = module_id,
            .name = name,
        });
        return .{ .bits = packTagged(.callable, 0, pool_handle) };
    }

    pub inline fn callablePoolHandle(self: Value) u32 {
        std.debug.assert(self.kind() == .callable);
        return @truncate(self.bits & handle_mask);
    }

    pub inline fn callableHandle(self: Value, pool: *const CallablePayloadPool) u32 {
        std.debug.assert(self.kind() == .callable);
        const ph: u32 = @truncate(self.bits & handle_mask);
        return pool.items[ph].handle;
    }

    pub inline fn callableFlags(self: Value, pool: *const CallablePayloadPool) u32 {
        std.debug.assert(self.kind() == .callable);
        const ph: u32 = @truncate(self.bits & handle_mask);
        const flags: u32 = pool.items[ph].flags;
        return flags;
    }

    pub inline fn callableRawFlags(self: Value, pool: *const CallablePayloadPool) u16 {
        std.debug.assert(self.kind() == .callable);
        const ph: u32 = @truncate(self.bits & handle_mask);
        return pool.items[ph].flags;
    }

    pub inline fn callableIsMixin(self: Value, pool: *const CallablePayloadPool) bool {
        return (self.callableRawFlags(pool) & callable_flag_is_mixin) != 0;
    }

    pub inline fn callableIsBuiltin(self: Value, pool: *const CallablePayloadPool) bool {
        return (self.callableRawFlags(pool) & callable_flag_is_builtin) != 0;
    }

    pub inline fn callableHasModule(self: Value, pool: *const CallablePayloadPool) bool {
        return (self.callableRawFlags(pool) & callable_flag_has_module) != 0;
    }

    pub inline fn callableIsCss(self: Value, pool: *const CallablePayloadPool) bool {
        return (self.callableRawFlags(pool) & callable_flag_is_css) != 0;
    }

    pub inline fn callableAcceptsContent(self: Value, pool: *const CallablePayloadPool) bool {
        return (self.callableRawFlags(pool) & callable_flag_accepts_content) != 0;
    }

    pub inline fn callableCapturesCallersLocals(self: Value, pool: *const CallablePayloadPool) bool {
        return (self.callableRawFlags(pool) & callable_flag_capture_callers_locals) != 0;
    }

    pub inline fn callableCssLateSassResolution(self: Value, pool: *const CallablePayloadPool) bool {
        return (self.callableRawFlags(pool) & callable_flag_css_late_sass_resolution) != 0;
    }

    pub inline fn callablePrebound(self: Value, pool: *const CallablePayloadPool) bool {
        return (self.callableRawFlags(pool) & callable_flag_prebound) != 0;
    }

    pub inline fn callableModuleId(self: Value, pool: *const CallablePayloadPool) u16 {
        std.debug.assert(self.kind() == .callable);
        const ph: u32 = @truncate(self.bits & handle_mask);
        return pool.items[ph].module_id;
    }

    pub inline fn callableNameIntern(self: Value, pool: *const CallablePayloadPool) InternId {
        std.debug.assert(self.kind() == .callable);
        const ph: u32 = @truncate(self.bits & handle_mask);
        return pool.items[ph].name;
    }

    pub inline fn colorWithHandle(handle: u32) Value {
        return .{ .bits = packTagged(.color, 0, handle) };
    }

    pub inline fn colorHandle(self: Value) u32 {
        std.debug.assert(self.kind() == .color);
        return @truncate(self.bits & handle_mask);
    }

    pub inline fn colorEntry(self: Value, pool: *const ColorPool) *const ColorEntry {
        std.debug.assert(self.kind() == .color);
        const h: u32 = @truncate(self.bits & handle_mask);
        std.debug.assert(h < pool.items.len);
        return &pool.items[h];
    }

    pub inline fn colorEntryMut(self: Value, pool: *ColorPool) *ColorEntry {
        std.debug.assert(self.kind() == .color);
        const h: u32 = @truncate(self.bits & handle_mask);
        std.debug.assert(h < pool.items.len);
        return &pool.items[h];
    }

    pub inline fn colorAsPrimitive(self: Value, pool: *const ColorPool) color_mod.Color {
        const entry = self.colorEntry(pool);
        return color_mod.Color.init(
            entry.channels[0],
            entry.channels[1],
            entry.channels[2],
            entry.channels[3],
            entry.space,
        );
    }
};

pub fn listSeparatorCssFrom(separator: ListSeparator) []const u8 {
    return switch (separator) {
        .comma => ", ",
        .space => " ",
        .slash => " / ",
        .undecided => " ",
    };
}

const KeywordMapHandle = u32;

const KeywordPair = struct {
    key: InternId,
    value: Value,
};

const KeywordEntry = struct {
    pairs: []KeywordPair,
    refcount: u32 = 1,
};

const KeywordPool = std.ArrayListUnmanaged(KeywordEntry);

const ListPoolEntry = struct {
    items: []Value,
    separator: ListSeparator,
    bracketed: bool,
    is_map: bool = false,
    is_arg_list: bool = false,
    slash_coercible: bool = false,
    keywords: ?KeywordMapHandle = null,
    refcount: u32 = 1,
};

const ListPool = std.ArrayListUnmanaged(ListPoolEntry);
const SlashListPreserve = std.AutoHashMapUnmanaged(u32, void);

const ValueContext = struct {
    allocator: std.mem.Allocator,
    intern_pool: *intern_pool_mod.InternPool,
    list_pool: *ListPool,
    color_pool: *ColorPool,
    keyword_pool: *KeywordPool,
    number_pool: *NumberPool,
    slash_list_preserve: ?*const SlashListPreserve = null,
};

pub const InspectLogicalListView = struct {
    items: []const Value,
    separator: ListSeparator,
    bracketed: bool,
    is_map: bool,
};

/// Returns a logical list view for inspect/list semantics.
/// Bracketed comma singletons that wrap an unbracketed non-map list
/// (e.g. resolver output for `[1 2]`) are flattened to the inner list while
/// preserving `bracketed=true`.
pub fn inspectLogicalListView(list_pool: []const []const Value, value: Value) ?InspectLogicalListView {
    if (value.kind() != .list) return null;
    std.debug.assert(value.listHandle() < list_pool.len);
    const items = list_pool[value.listHandle()];
    if (value.listBracketed(empty_list_meta_pool) and value.listComma(empty_list_meta_pool) and items.len == 1 and items[0].kind() == .list and !items[0].listBracketed(empty_list_meta_pool) and !items[0].listIsMap(empty_list_meta_pool) and items[0].listSeparator(empty_list_meta_pool) == .space) {
        std.debug.assert(items[0].listHandle() < list_pool.len);
        const inner_items = list_pool[items[0].listHandle()];
        if (inner_items.len <= 1) {
            return .{
                .items = items,
                .separator = value.listSeparator(empty_list_meta_pool),
                .bracketed = value.listBracketed(empty_list_meta_pool),
                .is_map = value.listIsMap(empty_list_meta_pool),
            };
        }
        return .{
            .items = inner_items,
            .separator = items[0].listSeparator(empty_list_meta_pool),
            .bracketed = true,
            .is_map = false,
        };
    }
    return .{
        .items = items,
        .separator = value.listSeparator(empty_list_meta_pool),
        .bracketed = value.listBracketed(empty_list_meta_pool),
        .is_map = value.listIsMap(empty_list_meta_pool),
    };
}

pub fn inspectNestedListNeedsParens(
    list_pool: []const []const Value,
    item: Value,
    parent_separator: ListSeparator,
) bool {
    const view = inspectLogicalListView(list_pool, item) orelse return false;
    if (view.bracketed) return false;
    if (view.items.len < 2) return false;
    if (view.separator == .slash) return true;
    if (view.separator == .comma) return true;
    if (view.separator == .space and parent_separator == .space) return true;
    return false;
}

pub const InspectMapListSide = enum {
    key,
    value,
};

pub fn inspectMapListNeedsParens(
    list_pool: []const []const Value,
    candidate: Value,
    side: InspectMapListSide,
) bool {
    const view = inspectLogicalListView(list_pool, candidate) orelse return false;
    if (view.bracketed or view.is_map) return false;
    return switch (side) {
        .key => view.separator == .comma and view.items.len > 1,
        .value => view.separator == .comma or view.separator == .slash,
    };
}

comptime {
    if (@sizeOf(Value) != 8) @compileError("NaN-boxed Value must be 8 bytes");
}
