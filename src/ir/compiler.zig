//!ResolvedProgram  ->  bytecode Program (Stage 1a Step 5).

const std = @import("std");
const zsass_io = @import("../runtime/io.zig");
const opcode_mod = @import("opcode.zig");
const rule_ir_mod = @import("rule_ir.zig");
const media_prelude = @import("../resolve/media_prelude.zig");
const lexer_mod = @import("../frontend/lexer.zig");
const parser_mod = @import("../frontend/parser.zig");
const value_mod = @import("../runtime/value.zig");
const observe_mod = @import("../runtime/observe.zig");
const perf = @import("../runtime/perf.zig");
const origin_mod = @import("../runtime/origin.zig");
const resolver = @import("../resolve/resolver.zig");
const deprecation_mod = @import("../runtime/deprecation.zig");
const source_cache_mod = @import("../resolve/source_cache.zig");
const ast_cache_mod = @import("../resolve/ast_cache.zig");
const builtin_mod = @import("../builtin/mod.zig");
const meta_helpers = @import("../builtin/meta_helpers.zig");
const css_utils = @import("../runtime/css_utils.zig");
const calc_utils = @import("../runtime/calc_utils.zig");
const value_format = @import("../runtime/value_format.zig");
const intern_pool_mod = @import("../runtime/intern_pool.zig");
const InternPool = intern_pool_mod.InternPool;
const InternId = intern_pool_mod.InternId;

const Opcode = opcode_mod.Opcode;
const Instruction = opcode_mod.Instruction;
const Value = value_mod.Value;
const ColorPool = value_mod.ColorPool;
const ColorEntry = value_mod.ColorEntry;
const ListSeparator = value_mod.ListSeparator;
const CssOrigin = origin_mod.CssOrigin;
const OriginId = origin_mod.OriginId;

const ResolvedProgram = resolver.ResolvedProgram;
const ResolvedExpr = resolver.ResolvedExpr;
const ExprIndex = resolver.ExprIndex;
const StmtIndex = resolver.StmtIndex;
const MixinId = resolver.MixinId;
const BinOp = resolver.BinOp;
const UnaryOp = resolver.UnaryOp;
const StmtKind = resolver.StmtKind;
const RuleData = resolver.RuleData;
const ResolvedBundle = resolver.ResolvedBundle;
const AtRootBehavior = resolver.AtRootBehavior;
pub const CompileError = error{ OutOfMemory, Unsupported, ProgramTooLarge };
const meta_call_builtin_id: u32 = 77;
const meta_apply_builtin_id: u32 = 78;
const rule_flag_plain_css_preserve: u16 = 1 << 0;
const rule_flag_plain_css_combine_parent: u16 = 1 << 1;
const rule_flag_selector_validation_failed: u16 = 1 << 2;
const calc_interp_marker = calc_utils.calc_interp_marker;
const calc_interp_preserve_start = calc_utils.calc_interp_preserve_start;
const at_root_bubble_media_mask: u8 = rule_ir_mod.at_root_bubble_media_mask;
const at_root_bubble_supports_mask: u8 = rule_ir_mod.at_root_bubble_supports_mask;
const at_root_bubble_layer_mask: u8 = rule_ir_mod.at_root_bubble_layer_mask;

fn checkedU16(value: u32, comptime what: []const u8) CompileError!u16 {
    if (value > std.math.maxInt(u16)) {
        _ = what;
        return error.ProgramTooLarge;
    }
    return @intCast(value);
}

fn checkedU16FromUsize(value: usize, comptime what: []const u8) CompileError!u16 {
    if (value > std.math.maxInt(u16)) {
        _ = what;
        return error.ProgramTooLarge;
    }
    return @intCast(value);
}

pub const Chunk = struct {
    pub const SourceLoc = struct {
        module_id: u32,
        start: u32,
        end: u32,
    };

    pub const BuiltinCallMeta = struct {
        argc: u32,
        arg_names_start: u32,
        /// Scoped local slot hint for `meta.variable-exists($name)` call-site.
        /// If not set, `std.math.maxInt(u32)`.
        local_slot_hint: u32 = std.math.maxInt(u32),
    };

    pub const max_param_default_call_args: usize = 8;

    pub const ParamDefaultBinaryOperand = union(enum) {
        value: Value,
        local_slot: resolver.SlotId,
        cross_slot: resolver.VarTarget,
    };

    pub const ParamDefaultBinary = struct {
        op: BinOp,
        lhs: ParamDefaultBinaryOperand,
        rhs: ParamDefaultBinaryOperand,
    };

    pub const ParamDefaultUnary = struct {
        op: UnaryOp,
        operand: ParamDefaultBinaryOperand,
    };

    pub const ParamDefaultAtomExpr = union(enum) {
        value: Value,
        local_slot: resolver.SlotId,
        cross_slot: resolver.VarTarget,
        binary: ParamDefaultBinary,
        unary: ParamDefaultUnary,
    };

    pub const max_param_default_interp_parts: usize = 16;

    /// Keep Interpolation literal (`#{...}` concatenation) as default value.
    /// Each part is limited to the atom level (var/const/binary), and in the VM it is simply
    /// Stringization  ->  Concatenate and return String Value. preserve_quote=true
    /// is treated as a quoted string.
    pub const ParamDefaultInterp = struct {
        preserve_quote: bool,
        part_count: u8,
        parts: [max_param_default_interp_parts]ParamDefaultAtomExpr,
    };

    pub const ParamDefaultLeafBuiltinCall = struct {
        builtin_id: u32,
        argc: u8,
        args: [max_param_default_call_args]ParamDefaultAtomExpr,
        arg_names: [max_param_default_call_args]InternId,
    };

    pub const ParamDefaultLeafCall = struct {
        callee_module: u32,
        callee_id: u32,
        callee_name: InternId,
        callee_is_css: bool,
        argc: u8,
        args: [max_param_default_call_args]ParamDefaultAtomExpr,
        arg_names: [max_param_default_call_args]InternId,
    };

    pub const ParamDefaultExpr = union(enum) {
        value: Value,
        local_slot: resolver.SlotId,
        cross_slot: resolver.VarTarget,
        binary: ParamDefaultBinary,
        unary: ParamDefaultUnary,
        builtin_call: ParamDefaultLeafBuiltinCall,
        call: ParamDefaultLeafCall,
        interp: ParamDefaultInterp,
    };

    pub const ParamDefaultBuiltinCall = struct {
        builtin_id: u32,
        argc: u8,
        args: [max_param_default_call_args]ParamDefaultExpr,
        arg_names: [max_param_default_call_args]InternId,
    };

    pub const ParamDefaultCall = struct {
        callee_module: u32,
        callee_id: u32,
        callee_name: InternId,
        callee_is_css: bool,
        argc: u8,
        args: [max_param_default_call_args]ParamDefaultExpr,
        arg_names: [max_param_default_call_args]InternId,
    };

    pub const ParamDefaultIfBuiltin = struct {
        condition: ParamDefaultExpr,
        if_true: ParamDefaultExpr,
        if_false: ParamDefaultExpr,
    };

    pub const max_param_default_list_items: usize = 8;

    pub const ParamDefaultListElem = union(enum) {
        expr: ParamDefaultExpr,
        if_builtin: ParamDefaultIfBuiltin,
    };

    pub const ParamDefaultList = struct {
        separator: ListSeparator,
        bracketed: bool,
        is_map: bool,
        elem_count: u8,
        elems: [max_param_default_list_items]ParamDefaultListElem,
    };

    pub const ParamDefault = union(enum) {
        none,
        value: Value,
        local_slot: resolver.SlotId,
        cross_slot: resolver.VarTarget,
        binary: ParamDefaultBinary,
        unary: ParamDefaultUnary,
        if_builtin: ParamDefaultIfBuiltin,
        builtin_call: ParamDefaultBuiltinCall,
        call: ParamDefaultCall,
        list: ParamDefaultList,
        interp: ParamDefaultInterp,
    };

    code: []Instruction,
    code_origin: []OriginId,
    const_pool: []Value,
    string_pool: []InternId,
    builtin_call_meta: []BuiltinCallMeta,
    builtin_call_arg_names: []InternId,
    source_locs: []SourceLoc = &.{},
    param_names: []InternId,
    /// formal parameter defaults (len = argc).
    /// - `.none`: default None / currently unsupported expression kind
    /// - `.value`: compile-time constant
    /// - `.local_slot` / `.cross_slot`: call-time lazy lookup
    /// - `.builtin_call`: call-time builtin evaluation (literal/var/binary args only)
    /// - `.interp`: `#{...}` string value concatenated with interpolation (parts is only atoms)
    param_defaults: []ParamDefault,
    local_count: u16,
    argc: u16,
    arg_base: u16,
    has_rest: bool = false,
    name: []const u8,
    has_content: bool = false,
    captures_callers_locals: bool = false,
    global_slot_base: u32 = 0,
};

pub const ModuleChunks = struct {
    /// Absolute source path of this module (module_path of resolver).
    module_path: []const u8 = "",
    top: Chunk,
    mixins: []Chunk,
    functions: []Chunk,
    content_blocks: []Chunk,
    placeholder_blocks: []Chunk,
    /// placeholder selector intern ids (parallel to `placeholder_blocks`)
    placeholder_targets: []InternId,
    /// Caller copies `caller.locals[0..global_slot_count)` into each mixin/function frame.
    global_slot_count: u32,
    /// Root `enter_frame` / `mod_globals` row size (`resolved.max_slot`).
    max_slot: u32,
    /// 0-indexed line start byte offsets in original source (first entry is always 0).
    line_starts: []u32 = &.{},
    /// Source byte length (for source-map offset clamping).
    source_len: u32 = 0,
    /// local slot undeclared Fallback slot when reading (no fallback if index=slot, value=maxInt(u32)).
    local_fallback_slots: []u32 = &.{},

    /// introspection metadata: name -> slot
    global_slots: std.StringHashMapUnmanaged(u32) = .empty,
    /// introspection metadata: name -> mixin index
    mixin_names: std.StringHashMapUnmanaged(u32) = .empty,
    /// introspection metadata: name -> function index
    function_names: std.StringHashMapUnmanaged(u32) = .empty,
    /// introspection metadata: namespace -> binding
    use_map: std.StringHashMapUnmanaged(resolver.UseBinding) = .empty,
    /// introspection metadata: `@use ... as *` variable exports
    star_vars: std.StringHashMapUnmanaged(resolver.VarTarget) = .empty,
    /// introspection metadata: conflicting `@use ... as *` variable names
    ambiguous_star_vars: std.StringHashMapUnmanaged(void) = .empty,
    star_mixins: std.StringHashMapUnmanaged(resolver.CallableTarget) = .empty,
    ambiguous_star_mixins: std.StringHashMapUnmanaged(void) = .empty,
    star_functions: std.StringHashMapUnmanaged(resolver.CallableTarget) = .empty,
    ambiguous_star_functions: std.StringHashMapUnmanaged(void) = .empty,
    star_builtin_fns: std.StringHashMapUnmanaged(u32) = .empty,
    exported_mixins: std.StringHashMapUnmanaged(resolver.CallableTarget) = .empty,
    ambiguous_export_mixins: std.StringHashMapUnmanaged(void) = .empty,
    exported_functions: std.StringHashMapUnmanaged(resolver.CallableTarget) = .empty,
    ambiguous_export_functions: std.StringHashMapUnmanaged(void) = .empty,
    exported_builtin_fns: std.StringHashMapUnmanaged(u32) = .empty,
    /// introspection metadata: exported variable name -> module/slot target
    exported_vars: std.StringHashMapUnmanaged(resolver.VarTarget) = .empty,
    ambiguous_export_vars: std.StringHashMapUnmanaged(void) = .empty,
    /// Public variable name -> entity slot that can be set with load-css `$with`.
    exported_default_vars: std.StringHashMapUnmanaged(resolver.VarTarget) = .empty,
    ambiguous_export_default_vars: std.StringHashMapUnmanaged(void) = .empty,
};

pub const Program = struct {
    arena: std.heap.ArenaAllocator,
    modules: []ModuleChunks,
    root_index: u32,
    origins: []CssOrigin = &.{},
    module_config_seeds: []resolver.ConfigSeed = &.{},
    static_eval_lists: []const []const Value = &.{},
    /// User module fallback search paths (from embedder). Referenced by runtime `meta.load-css`.
    load_paths: []const []const u8 = &.{},
    /// official Sass CLI parity: `pkg:` URL resolution is rejected at runtime
    /// `meta.load-css` unless this is `true`. Set from
    /// `RunOpts.pkg_importer_enabled` / `CompileOptions.pkg_importer_enabled`
    /// at compile entry; the VM consults it before delegating to
    /// pkg_importer.
    pkg_importer_enabled: bool = false,
    /// Reachable mask for cross-entry artifact reuse (plan C).
    /// Same length as modules.len. from root_index with run_dependency / load_mod_global
    /// True if the module is reachable, false otherwise (relict from previous entry).
    /// VM prologue gates with mask. If it is null, treat it as all true.
    /// Design: `.plans/ideal/20260502-cross-entry-resolve-reuse-design.md`
    reachable_mask: ?[]bool = null,
    /// P4 commit 3 Step B (NaN-box layout) prep: created at compile-time
    /// sidecar pool for unit-bearing number Value. whole program (= all modules
    /// common handle space in compile-time const_pool). vm.number_pool at VM startup
    // Scheduled to be handover (clone or share) at ///. In stage 2 (16-byte layout)
    /// Leave empty -- because Value.number(v, unit, pool) ignores the pool argument.
    value_number_pool: value_mod.NumberPool = .empty,
    /// P4 commit 3 Step B prep: for callable Value created at compile-time
    /// sidecar pool. 96-bit payload of callable in NaN-boxed Value
    /// Hold (flags:16 / module_id:16 / name:32) via 32-bit handle.
    /// Unused in stage 2.
    value_callable_payload_pool: value_mod.CallablePayloadPool = .empty,
    /// P4 commit 3 Step B prep: sidecar pool for list metadata (with NaN-box layout
    /// Reserved for overflow that cannot be directly packed into aux bytes). Not used in stage 2.
    value_list_meta_pool: value_mod.ListMetaPool = .empty,
    /// P4 commit 3 Step B prep: sidecar pool for string flags (same as above).
    value_string_flags_pool: value_mod.StringFlagsPool = .empty,
    /// NaN-box stage 3: pointer to SharedValuePoolStorage owned by bundle.
    /// All compile-time callable / unit-bearing number handle indexing for this storage.
    /// When the VM starts, vm.callable_payload_pool / vm.number_pool are cloned from here.
    shared_value_pools: ?*resolver.SharedValuePoolStorage = null,

    pub fn deinit(self: *Program) void {
        self.arena.deinit();
    }

    pub fn rootMod(self: *const Program) *const ModuleChunks {
        return &self.modules[self.root_index];
    }
};

const ChunkBuilder = struct {
    alloc: std.mem.Allocator,
    /// Allocator for pushColorEntry. With cross-entry persistent, color_pool crosses entry
    /// Long-lived (c_allocator) required to be retained. Normally, it is the same as alloc.
    color_alloc: std.mem.Allocator = std.heap.c_allocator,
    /// `value_number_pool` / `value_callable_payload_pool` etc. to shared sidecar pool
    /// append-only allocator. pool itself is ResolvedBundle.shared_value_pools_alloc
    /// alloc with (persistent: ps.alloc=c_allocator, single-entry: top-level allocator)
    /// Therefore, if the subsequent append is not performed using the same allocator, the realloc route will be used.
    /// Allocator mismatch (= heap corruption) occurs. In multi-entry batch
    /// ChunkBuilder.alloc is suitable for per-entry arena, so don't pass it there.
    shared_pool_alloc: std.mem.Allocator = std.heap.c_allocator,
    module_id: u32 = 0,
    current_origin: OriginId = .invalid,
    current_span: resolver.Span = .{ .start = 0, .end = 0 },
    code: std.ArrayListUnmanaged(Instruction) = .empty,
    code_origin: std.ArrayListUnmanaged(OriginId) = .empty,
    const_pool: std.ArrayListUnmanaged(Value) = .empty,
    string_pool: std.ArrayListUnmanaged(InternId) = .empty,
    builtin_call_meta: std.ArrayListUnmanaged(Chunk.BuiltinCallMeta) = .empty,
    builtin_call_arg_names: std.ArrayListUnmanaged(InternId) = .empty,
    source_locs: std.ArrayListUnmanaged(Chunk.SourceLoc) = .empty,

    fn deinit(self: *ChunkBuilder, alloc: std.mem.Allocator) void {
        self.code.deinit(alloc);
        self.code_origin.deinit(alloc);
        self.const_pool.deinit(alloc);
        self.string_pool.deinit(alloc);
        self.builtin_call_meta.deinit(alloc);
        self.builtin_call_arg_names.deinit(alloc);
        self.source_locs.deinit(alloc);
    }

    /// Reset for reuse across chunks (reduce alloc/zero init cost by maintaining capacity).
    fn resetForReuse(self: *ChunkBuilder, module_id: u32) void {
        self.module_id = module_id;
        self.current_origin = .invalid;
        self.current_span = .{ .start = 0, .end = 0 };
        self.code.clearRetainingCapacity();
        self.code_origin.clearRetainingCapacity();
        self.const_pool.clearRetainingCapacity();
        self.string_pool.clearRetainingCapacity();
        self.builtin_call_meta.clearRetainingCapacity();
        self.builtin_call_arg_names.clearRetainingCapacity();
        self.source_locs.clearRetainingCapacity();
    }

    fn setSourceSpan(cb: *ChunkBuilder, span: resolver.Span) void {
        cb.current_span = span;
    }

    fn emit(cb: *ChunkBuilder, op: Opcode, arg_a: u16, arg_b: u32) !void {
        try cb.code.append(cb.alloc, Instruction.make(op, arg_a, arg_b));
        const origin_id = if (cb.current_origin.isValid()) cb.current_origin else @as(OriginId, @enumFromInt(cb.module_id + 1));
        try cb.code_origin.append(cb.alloc, origin_id);
        try cb.source_locs.append(cb.alloc, .{
            .module_id = cb.module_id,
            .start = cb.current_span.start,
            .end = cb.current_span.end,
        });
    }

    fn noteIntern(cb: *ChunkBuilder, id: InternId) !void {
        try cb.string_pool.append(cb.alloc, id);
    }

    fn addConst(cb: *ChunkBuilder, v: Value) CompileError!u32 {
        const idx: u32 = std.math.cast(u32, cb.const_pool.items.len) orelse return error.ProgramTooLarge;
        try cb.const_pool.append(cb.alloc, v);
        return idx;
    }

    fn patchJmp(cb: *ChunkBuilder, jmp_pc: usize, target_pc: usize) void {
        const offset: i32 = @intCast(@as(i64, @intCast(target_pc)) - @as(i64, @intCast(jmp_pc)) - 1);
        cb.code.items[jmp_pc].arg_b = @bitCast(offset);
    }

    fn toChunk(
        cb: *ChunkBuilder,
        arena: std.mem.Allocator,
        name: []const u8,
        local_count: u16,
        argc: u16,
        arg_base: u16,
        param_names: []const InternId,
        param_defaults: []const Chunk.ParamDefault,
        has_rest: bool,
    ) !Chunk {
        const code = try arena.dupe(Instruction, cb.code.items);
        const code_origin = try arena.dupe(OriginId, cb.code_origin.items);
        const const_pool = try arena.dupe(Value, cb.const_pool.items);
        const string_pool = try arena.dupe(InternId, cb.string_pool.items);
        const builtin_call_meta = try arena.dupe(Chunk.BuiltinCallMeta, cb.builtin_call_meta.items);
        const builtin_call_arg_names = try arena.dupe(InternId, cb.builtin_call_arg_names.items);
        const source_locs = try arena.dupe(Chunk.SourceLoc, cb.source_locs.items);
        const chunk_param_names = try arena.dupe(InternId, param_names);
        const defaults = try arena.dupe(Chunk.ParamDefault, param_defaults);
        return .{
            .code = code,
            .code_origin = code_origin,
            .const_pool = const_pool,
            .string_pool = string_pool,
            .builtin_call_meta = builtin_call_meta,
            .builtin_call_arg_names = builtin_call_arg_names,
            .source_locs = source_locs,
            .param_names = chunk_param_names,
            .param_defaults = defaults,
            .local_count = local_count,
            .argc = argc,
            .arg_base = arg_base,
            .has_rest = has_rest,
            .name = name,
        };
    }
};

/// Stage 1b-B1: fuse frequent opcode sequences; remap JMP offsets after size change.
/// `temp_alloc` holds scratch; `arena` stores the returned `[]Instruction` for the program lifetime.
const PeepholeFuseResult = struct {
    code: []Instruction,
    new_to_old: []u32,
};

const LocalSlotUse = struct {
    max_exclusive: u32 = 0,

    fn note(self: *LocalSlotUse, slot: u32) void {
        if (slot == std.math.maxInt(u32)) return;
        const next = slot +| 1;
        if (next > self.max_exclusive) self.max_exclusive = next;
    }
};

fn noteFallbackLocalSlotUse(resolved: *const ResolvedProgram, used: *LocalSlotUse, slot: u32) void {
    var current = slot;
    var guard: usize = 0;
    while (guard < 1024) : (guard += 1) {
        var found = false;
        for (resolved.flow_local_fallbacks.items) |entry| {
            if (entry.slot != current) continue;
            used.note(entry.fallback);
            current = entry.fallback;
            found = true;
            break;
        }
        if (!found) return;
    }
}

fn noteFrameLocalSlotUse(resolved: *const ResolvedProgram, used: *LocalSlotUse, slot: u32) void {
    used.note(slot);
    noteFallbackLocalSlotUse(resolved, used, slot);
}

fn noteParamDefaultBinaryOperandLocalUse(
    resolved: *const ResolvedProgram,
    used: *LocalSlotUse,
    operand: Chunk.ParamDefaultBinaryOperand,
) void {
    switch (operand) {
        .local_slot => |slot| noteFrameLocalSlotUse(resolved, used, slot),
        else => {},
    }
}

fn noteParamDefaultBinaryLocalUse(
    resolved: *const ResolvedProgram,
    used: *LocalSlotUse,
    binary: Chunk.ParamDefaultBinary,
) void {
    noteParamDefaultBinaryOperandLocalUse(resolved, used, binary.lhs);
    noteParamDefaultBinaryOperandLocalUse(resolved, used, binary.rhs);
}

fn noteParamDefaultUnaryLocalUse(
    resolved: *const ResolvedProgram,
    used: *LocalSlotUse,
    unary: Chunk.ParamDefaultUnary,
) void {
    noteParamDefaultBinaryOperandLocalUse(resolved, used, unary.operand);
}

fn noteParamDefaultAtomLocalUse(
    resolved: *const ResolvedProgram,
    used: *LocalSlotUse,
    atom: Chunk.ParamDefaultAtomExpr,
) void {
    switch (atom) {
        .local_slot => |slot| noteFrameLocalSlotUse(resolved, used, slot),
        .binary => |binary| noteParamDefaultBinaryLocalUse(resolved, used, binary),
        .unary => |unary| noteParamDefaultUnaryLocalUse(resolved, used, unary),
        else => {},
    }
}

fn noteParamDefaultExprLocalUse(
    resolved: *const ResolvedProgram,
    used: *LocalSlotUse,
    expr: Chunk.ParamDefaultExpr,
) void {
    switch (expr) {
        .local_slot => |slot| noteFrameLocalSlotUse(resolved, used, slot),
        .binary => |binary| noteParamDefaultBinaryLocalUse(resolved, used, binary),
        .unary => |unary| noteParamDefaultUnaryLocalUse(resolved, used, unary),
        .builtin_call => |call| {
            var i: usize = 0;
            while (i < call.argc) : (i += 1) {
                noteParamDefaultAtomLocalUse(resolved, used, call.args[i]);
            }
        },
        .call => |call| {
            var i: usize = 0;
            while (i < call.argc) : (i += 1) {
                noteParamDefaultAtomLocalUse(resolved, used, call.args[i]);
            }
        },
        .interp => |interp| {
            var i: usize = 0;
            while (i < interp.part_count) : (i += 1) {
                noteParamDefaultAtomLocalUse(resolved, used, interp.parts[i]);
            }
        },
        else => {},
    }
}

fn noteParamDefaultIfLocalUse(
    resolved: *const ResolvedProgram,
    used: *LocalSlotUse,
    if_builtin: Chunk.ParamDefaultIfBuiltin,
) void {
    noteParamDefaultExprLocalUse(resolved, used, if_builtin.condition);
    noteParamDefaultExprLocalUse(resolved, used, if_builtin.if_true);
    noteParamDefaultExprLocalUse(resolved, used, if_builtin.if_false);
}

fn noteParamDefaultLocalUse(
    resolved: *const ResolvedProgram,
    used: *LocalSlotUse,
    default: Chunk.ParamDefault,
) void {
    switch (default) {
        .local_slot => |slot| noteFrameLocalSlotUse(resolved, used, slot),
        .binary => |binary| noteParamDefaultBinaryLocalUse(resolved, used, binary),
        .unary => |unary| noteParamDefaultUnaryLocalUse(resolved, used, unary),
        .if_builtin => |if_builtin| noteParamDefaultIfLocalUse(resolved, used, if_builtin),
        .builtin_call => |call| {
            var i: usize = 0;
            while (i < call.argc) : (i += 1) {
                noteParamDefaultExprLocalUse(resolved, used, call.args[i]);
            }
        },
        .call => |call| {
            var i: usize = 0;
            while (i < call.argc) : (i += 1) {
                noteParamDefaultExprLocalUse(resolved, used, call.args[i]);
            }
        },
        .list => |list| {
            var i: usize = 0;
            while (i < list.elem_count) : (i += 1) {
                switch (list.elems[i]) {
                    .expr => |expr| noteParamDefaultExprLocalUse(resolved, used, expr),
                    .if_builtin => |if_builtin| noteParamDefaultIfLocalUse(resolved, used, if_builtin),
                }
            }
        },
        .interp => |interp| {
            var i: usize = 0;
            while (i < interp.part_count) : (i += 1) {
                noteParamDefaultAtomLocalUse(resolved, used, interp.parts[i]);
            }
        },
        else => {},
    }
}

fn trimCallableLocalCount(resolved: *const ResolvedProgram, chunk: *Chunk, allow_zero: bool) void {
    for (chunk.code) |inst| {
        switch (inst.opcode()) {
            // These opcodes can pass the current frame as a capture to a callee
            // or content block.  The callee may read caller slots that are not
            // syntactically referenced by this chunk, so trimming here would
            // change closure visibility.
            .call_indirect, .set_content => return,
            else => {},
        }
    }

    var used: LocalSlotUse = .{};
    if (chunk.argc != 0) used.note(@as(u32, chunk.arg_base) + @as(u32, chunk.argc) - 1);

    for (chunk.param_defaults) |default| {
        noteParamDefaultLocalUse(resolved, &used, default);
    }
    for (chunk.builtin_call_meta) |meta| {
        noteFrameLocalSlotUse(resolved, &used, meta.local_slot_hint);
    }

    for (chunk.code) |inst| {
        switch (inst.opcode()) {
            .load_local,
            .load_local_strict,
            .store_local,
            .store_local_writeback,
            .clear_local,
            => {
                if (resolver.decodeCrossAssignSlot(inst.arg_b) == null) {
                    noteFrameLocalSlotUse(resolved, &used, inst.arg_b);
                }
            },
            .load_local_add_const,
            .load_local_mul_const,
            .load_local_ge_const,
            .load_const_add_local,
            .load_emit_decl,
            .branch_if_false_local,
            => noteFrameLocalSlotUse(resolved, &used, inst.arg_a),
            .load_arg => noteFrameLocalSlotUse(resolved, &used, @as(u32, chunk.arg_base) + inst.arg_a),
            else => {},
        }
    }

    if (used.max_exclusive == 0 and !allow_zero) return;
    if (used.max_exclusive >= chunk.local_count) return;
    const trimmed: u16 = @intCast(used.max_exclusive);
    chunk.local_count = trimmed;
    if (chunk.code.len > 0 and chunk.code[0].opcode() == .enter_frame) {
        chunk.code[0].arg_a = trimmed;
    }
}

fn peepholeFuseSuperinstructions(
    temp_alloc: std.mem.Allocator,
    arena: std.mem.Allocator,
    code: []const Instruction,
) CompileError!PeepholeFuseResult {
    const n = code.len;
    var is_target = try temp_alloc.alloc(bool, n);
    defer temp_alloc.free(is_target);
    @memset(is_target, false);

    for (code, 0..) |inst, i| {
        switch (inst.opcode()) {
            .jmp, .jmp_if_false, .jmp_if_true => {
                const off: i32 = @bitCast(inst.arg_b);
                const dst: i64 = @as(i64, @intCast(i)) + 1 + @as(i64, off);
                if (dst >= 0 and dst < n) {
                    is_target[@intCast(dst)] = true;
                }
            },
            else => {},
        }
    }

    var out: std.ArrayListUnmanaged(Instruction) = .empty;
    defer out.deinit(temp_alloc);
    try out.ensureTotalCapacity(temp_alloc, n);
    var new_to_old: std.ArrayListUnmanaged(u32) = .empty;
    defer new_to_old.deinit(temp_alloc);
    try new_to_old.ensureTotalCapacity(temp_alloc, n);

    //All old index in [0, n) must be in each iteration of the while loop below
    // Written in the form `old_to_new[i..i+step] = new_pc` (for any branch with i += 1/2/3).
    // Omit memset as no initialization value is required. jmp remap pass relies on this guarantee.
    const old_to_new = try temp_alloc.alloc(u32, n);
    defer temp_alloc.free(old_to_new);

    var i: usize = 0;
    while (i < n) {
        const can_triple = i + 2 < n;
        const can_double = i + 1 < n;

        if (can_triple) {
            const a = code[i];
            const b = code[i + 1];
            const c = code[i + 2];
            // LOAD_LOCAL + LOAD_CONST + ADD
            // Fused form stores slot in u16 arg_a; skip fusion when slot
            // exceeds u16 (cross-assign-encoded slots carry bit 31 and must
            // stay in the u32 arg_b of plain load_local).
            if (a.opcode() == .load_local and b.opcode() == .load_const and c.opcode() == .add and
                a.arg_a == 0 and b.arg_a == 0 and
                c.arg_a == 0 and c.arg_b == 0 and
                a.arg_b <= std.math.maxInt(u16) and
                !is_target[i + 1] and !is_target[i + 2])
            {
                const slot: u16 = @truncate(a.arg_b);
                const ci: u32 = b.arg_b;
                const new_pc: u32 = std.math.cast(u32, out.items.len) orelse return error.ProgramTooLarge;
                old_to_new[i] = new_pc;
                old_to_new[i + 1] = new_pc;
                old_to_new[i + 2] = new_pc;
                try out.append(temp_alloc, Instruction.make(.load_local_add_const, slot, ci));
                try new_to_old.append(temp_alloc, @intCast(i));
                i += 3;
                continue;
            }
            // LOAD_LOCAL + LOAD_CONST + MUL
            if (a.opcode() == .load_local and b.opcode() == .load_const and c.opcode() == .mul and
                a.arg_a == 0 and b.arg_a == 0 and
                c.arg_a == 0 and c.arg_b == 0 and
                a.arg_b <= std.math.maxInt(u16) and
                !is_target[i + 1] and !is_target[i + 2])
            {
                const slot: u16 = @truncate(a.arg_b);
                const ci: u32 = b.arg_b;
                const new_pc: u32 = std.math.cast(u32, out.items.len) orelse return error.ProgramTooLarge;
                old_to_new[i] = new_pc;
                old_to_new[i + 1] = new_pc;
                old_to_new[i + 2] = new_pc;
                try out.append(temp_alloc, Instruction.make(.load_local_mul_const, slot, ci));
                try new_to_old.append(temp_alloc, @intCast(i));
                i += 3;
                continue;
            }
            // LOAD_LOCAL + LOAD_CONST + GE
            if (a.opcode() == .load_local and b.opcode() == .load_const and c.opcode() == .ge and
                a.arg_a == 0 and b.arg_a == 0 and
                c.arg_a == 0 and c.arg_b == 0 and
                a.arg_b <= std.math.maxInt(u16) and
                !is_target[i + 1] and !is_target[i + 2])
            {
                const slot: u16 = @truncate(a.arg_b);
                const ci: u32 = b.arg_b;
                const new_pc: u32 = std.math.cast(u32, out.items.len) orelse return error.ProgramTooLarge;
                old_to_new[i] = new_pc;
                old_to_new[i + 1] = new_pc;
                old_to_new[i + 2] = new_pc;
                try out.append(temp_alloc, Instruction.make(.load_local_ge_const, slot, ci));
                try new_to_old.append(temp_alloc, @intCast(i));
                i += 3;
                continue;
            }
            // LOAD_CONST + LOAD_LOCAL + ADD
            if (a.opcode() == .load_const and b.opcode() == .load_local and c.opcode() == .add and
                a.arg_a == 0 and b.arg_a == 0 and
                c.arg_a == 0 and c.arg_b == 0 and
                b.arg_b <= std.math.maxInt(u16) and
                !is_target[i + 1] and !is_target[i + 2])
            {
                const ci: u32 = a.arg_b;
                const slot: u16 = @truncate(b.arg_b);
                const new_pc: u32 = std.math.cast(u32, out.items.len) orelse return error.ProgramTooLarge;
                old_to_new[i] = new_pc;
                old_to_new[i + 1] = new_pc;
                old_to_new[i + 2] = new_pc;
                try out.append(temp_alloc, Instruction.make(.load_const_add_local, slot, ci));
                try new_to_old.append(temp_alloc, @intCast(i));
                i += 3;
                continue;
            }
        }

        if (can_double) {
            const d0 = code[i];
            const d1 = code[i + 1];
            // LOAD_LOCAL + JMP_IF_FALSE
            // Fused form keeps jump remapping correct because old_to_new maps the
            // original jump PC to this instruction PC.
            if (d0.opcode() == .load_local and d1.opcode() == .jmp_if_false and
                d0.arg_a == 0 and d1.arg_a == 0 and
                d0.arg_b <= std.math.maxInt(u16) and
                !is_target[i + 1])
            {
                const slot: u16 = @truncate(d0.arg_b);
                const off_bits: u32 = d1.arg_b;
                const new_pc: u32 = std.math.cast(u32, out.items.len) orelse return error.ProgramTooLarge;
                old_to_new[i] = new_pc;
                old_to_new[i + 1] = new_pc;
                try out.append(temp_alloc, Instruction.make(.branch_if_false_local, slot, off_bits));
                try new_to_old.append(temp_alloc, @intCast(i));
                i += 2;
                continue;
            }
            // LOAD_LOCAL + EMIT_DECL
            if (d0.opcode() == .load_local and d1.opcode() == .emit_decl and
                d0.arg_a == 0 and d1.arg_a == 0 and
                d0.arg_b <= std.math.maxInt(u16) and
                !is_target[i + 1])
            {
                const slot: u16 = @truncate(d0.arg_b);
                const prop: u32 = d1.arg_b;
                const new_pc: u32 = std.math.cast(u32, out.items.len) orelse return error.ProgramTooLarge;
                old_to_new[i] = new_pc;
                old_to_new[i + 1] = new_pc;
                try out.append(temp_alloc, Instruction.make(.load_emit_decl, slot, prop));
                try new_to_old.append(temp_alloc, @intCast(i));
                i += 2;
                continue;
            }
            // EMIT_RULE_END + POP_RULE_SCOPE
            if (d0.opcode() == .emit_rule_end and d1.opcode() == .pop_rule_scope and
                d0.arg_a == 0 and d0.arg_b == 0 and d1.arg_a == 0 and d1.arg_b == 0 and
                !is_target[i + 1])
            {
                const new_pc: u32 = std.math.cast(u32, out.items.len) orelse return error.ProgramTooLarge;
                old_to_new[i] = new_pc;
                old_to_new[i + 1] = new_pc;
                try out.append(temp_alloc, Instruction.make(.emit_rule_end_pop, 0, 0));
                try new_to_old.append(temp_alloc, @intCast(i));
                i += 2;
                continue;
            }
        }

        const new_pc: u32 = std.math.cast(u32, out.items.len) orelse return error.ProgramTooLarge;
        old_to_new[i] = new_pc;
        try out.append(temp_alloc, code[i]);
        try new_to_old.append(temp_alloc, @intCast(i));
        i += 1;
    }

    for (code, 0..) |inst, j| {
        switch (inst.opcode()) {
            .jmp, .jmp_if_false, .jmp_if_true => {
                const new_j: usize = @intCast(old_to_new[j]);
                const off_old: i32 = @bitCast(inst.arg_b);
                const dst_old: i64 = @as(i64, @intCast(j)) + 1 + @as(i64, off_old);
                std.debug.assert(dst_old >= 0 and dst_old < n);
                const dst_u: usize = @intCast(dst_old);
                const new_dst: usize = @intCast(old_to_new[dst_u]);
                const new_off: i32 = @intCast(@as(i64, @intCast(new_dst)) - @as(i64, @intCast(new_j)) - 1);
                out.items[new_j].arg_b = @bitCast(new_off);
            },
            else => {},
        }
    }

    return .{
        .code = try arena.dupe(Instruction, out.items),
        .new_to_old = try arena.dupe(u32, new_to_old.items),
    };
}

fn applySuperinstructionPeephole(temp_alloc: std.mem.Allocator, arena: std.mem.Allocator, chunk: *Chunk) CompileError!void {
    const old_code_len = chunk.code.len;
    const old_source_locs = chunk.source_locs;
    const fused = try peepholeFuseSuperinstructions(temp_alloc, arena, chunk.code);
    chunk.code = fused.code;

    if (old_source_locs.len == old_code_len and fused.new_to_old.len == fused.code.len) {
        const mapped = try arena.alloc(Chunk.SourceLoc, fused.code.len);
        for (fused.new_to_old, 0..) |old_idx, i| {
            mapped[i] = if (old_idx < old_source_locs.len)
                old_source_locs[old_idx]
            else
                .{ .module_id = 0, .start = 0, .end = 0 };
        }
        chunk.source_locs = mapped;
    } else {
        chunk.source_locs = &.{};
    }
}

const CompileCtx = struct {
    resolved: *const ResolvedProgram,
    cb: *ChunkBuilder,
    module_id: u32,
    modules: []const ResolvedProgram,
    color_pool: *ColorPool,
    pool: *InternPool,
    at_rule_depth: u32 = 0,
    has_selector_context: bool = false,
    in_keyframes_context: bool = false,
    keyframe_block_depth: u32 = 0,
    emit_comments: bool = true,
    callable_local_slot_base: u32 = std.math.maxInt(u32),
    callable_local_slot_bias: u32 = 0,
    /// Flag for outer interpolation of loud comment text. While set, `.interp`
    /// compiles with preserve_empty_separators so `#{""}` cannot collapse an
    /// intentional separator. Reset for nested expressions so selectors and
    /// declarations keep their normal whitespace collapse.
    in_loud_comment_text_outer: bool = false,
    skip_decimal_normalize: bool = false,
};

fn selectorContextChildCtx(ctx: CompileCtx) CompileCtx {
    var child = ctx;
    child.has_selector_context = true;
    return child;
}

fn resolvedHasGlobalSlot(resolved: *const ResolvedProgram, slot: u32) bool {
    var it = resolved.global_slots.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == slot) return true;
    }
    return false;
}

fn remapLocalSlot(ctx: CompileCtx, slot: u32) u32 {
    if (ctx.callable_local_slot_bias == 0) return slot;
    if (slot < ctx.callable_local_slot_base) return slot;
    if (resolvedHasGlobalSlot(ctx.resolved, slot)) return slot;
    return slot + ctx.callable_local_slot_bias;
}

fn remapLocalSlotHint(ctx: CompileCtx, slot: u32) u32 {
    if (slot == std.math.maxInt(u32)) return slot;
    return remapLocalSlot(ctx, slot);
}

fn moduleIsPlainCss(ctx: CompileCtx) bool {
    if (std.mem.endsWith(u8, ctx.resolved.module_path, ".css")) return true;
    return ctx.module_id < ctx.modules.len and std.mem.endsWith(u8, ctx.modules[ctx.module_id].module_path, ".css");
}

fn effectivePlainCssRuleForModule(module_path: []const u8, r: RuleData) RuleData {
    if (r.is_plain_css or !std.mem.endsWith(u8, module_path, ".css")) return r;
    var out = r;
    out.is_plain_css = true;
    out.plain_css_parent_selector_combine = false;
    out.plain_css_hoist_block_at_rules = false;
    return out;
}

fn effectiveRuleDataForCompile(ctx: CompileCtx, r: RuleData) RuleData {
    if (r.is_plain_css or !moduleIsPlainCss(ctx)) return r;
    var out = r;
    out.is_plain_css = true;
    out.plain_css_parent_selector_combine = false;
    out.plain_css_hoist_block_at_rules = !ctx.has_selector_context;
    return out;
}

fn atRuleNameRaw(name: []const u8) []const u8 {
    return if (name.len > 0 and name[0] == '@') name[1..] else name;
}

fn shouldPreserveEmptyConditionalAtRule(name: []const u8) bool {
    // preserve_empty is conditional and targets only a specific route of @layer.
    // VM compile reduces information, so preserve empty block only for @layer.
    return std.mem.eql(u8, atRuleNameRaw(name), "layer");
}

fn simpleAtRuleStaysInOpenBlock(
    pool: *InternPool,
    resolved: *const ResolvedProgram,
    si: StmtIndex,
) bool {
    if (si >= resolved.stmts.items.len) return false;
    const st = resolved.stmts.items[si];
    if (st.kind != .at_rule or st.payload >= resolved.at_rule_stmts.items.len) return false;
    const ar = resolved.at_rule_stmts.items[st.payload];
    if (ar.body_direct.len != 0 or ar.had_block) return false;

    // `@charset` is only valid at the stylesheet root.
    const raw_name = atRuleNameRaw(pool.get(ar.name_intern));
    return !std.mem.eql(u8, raw_name, "charset");
}

fn mediaArgFlags(raw_media_flags: u8) u16 {
    return @as(u16, raw_media_flags) << 8;
}

fn staticPreludeText(resolved: *const ResolvedProgram, pool: *InternPool, maybe_expr: ?ExprIndex) ?[]const u8 {
    const expr_idx = maybe_expr orelse return null;
    if (expr_idx >= resolved.exprs.items.len) return null;
    const ex = resolved.exprs.items[expr_idx];
    if (ex.kind != .literal_string) return null;
    const lit = resolver.unpackLiteralStringPayload(ex.payload);
    if (lit.quoted) return null;
    return pool.get(lit.id);
}

fn staticLiteralStringPayload(resolved: *const ResolvedProgram, expr_idx: ExprIndex) ?u32 {
    if (expr_idx >= resolved.exprs.items.len) return null;
    const ex = resolved.exprs.items[expr_idx];
    if (ex.kind != .literal_string) return null;
    return ex.payload;
}

fn mediaPreludeStartsOnNewLine(text: []const u8) bool {
    var i: usize = 0;
    var saw_newline = false;
    while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {
        if (text[i] == '\n' or text[i] == '\r') saw_newline = true;
    }
    return saw_newline and i < text.len;
}

fn unquotedLiteralLooksLikeIdentifierText(raw: []const u8) bool {
    if (raw.len == 0) return false;
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c == '\\') {
            if (i + 1 >= raw.len) return false;
            i += 2;
            continue;
        }
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') {
            i += 1;
            continue;
        }
        return false;
    }
    return true;
}

fn literalStringHasLeadingDotDecimal(raw: []const u8) bool {
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] != '.') continue;
        if (i + 1 >= raw.len) continue;
        const next = raw[i + 1];
        if (!(next >= '0' and next <= '9')) continue;
        const prev: u8 = if (i == 0) 0 else raw[i - 1];
        const prev_blocks = (prev >= '0' and prev <= '9') or prev == '.' or
            (prev >= 'a' and prev <= 'z') or (prev >= 'A' and prev <= 'Z') or
            prev == '_' or prev == '\\' or prev >= 0x80;
        if (!prev_blocks) return true;
    }
    return false;
}

fn normalizeLiteralStringIntern(
    pool: *InternPool,
    alloc: std.mem.Allocator,
    id: InternId,
    quoted: bool,
    apply_decimal_normalize: bool,
) CompileError!InternId {
    const raw = pool.get(id);
    if (!quoted and !unquotedLiteralLooksLikeIdentifierText(raw)) {
        // Unquoted strings that are not identifier-like (such as interp CSS value fragments) are
        // escape does not pass normalization, but in decl value context leading-zero like `.5`
        // Fill in the gaps. literal inside quoted-interp (`url("data:...#{x}...")`) is
        // Apply_decimal_normalize=false because SVG's `-.4` etc. should not be touched.
        if (!apply_decimal_normalize or !literalStringHasLeadingDotDecimal(raw)) return id;
        const normalized = value_format.normalizeLeadingZeros(alloc, raw) catch return error.OutOfMemory;
        defer alloc.free(normalized);
        return pool.intern(normalized) catch return error.OutOfMemory;
    }
    const normalized = if (quoted) blk: {
        break :blk css_utils.unescapeSassString(alloc, raw) catch return error.OutOfMemory;
    } else blk: {
        break :blk css_utils.normalizeCssValueEscapes(alloc, raw) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => raw,
        };
    };
    defer if (normalized.ptr != raw.ptr) alloc.free(normalized);
    return pool.intern(normalized) catch return error.OutOfMemory;
}

fn literalRawNeedsDeclBypass(raw: []const u8) bool {
    if (literalStartsWithUnicodeRange(raw)) return true;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '\\') {
            i += 1;
            continue;
        }
        if (i + 1 >= raw.len) return true; // trailing backslash

        if (raw[i + 1] == '\\') {
            i += 2;
            continue;
        }

        if (std.ascii.isHex(raw[i + 1])) {
            var j: usize = i + 1;
            var value: u21 = 0;
            var count: u32 = 0;
            while (j < raw.len and count < 6 and std.ascii.isHex(raw[j])) : (count += 1) {
                value = value * 16 + css_utils.hexDigitValue(raw[j]);
                j += 1;
            }
            if (j < raw.len and (raw[j] == ' ' or raw[j] == '\t' or raw[j] == '\n' or raw[j] == '\r' or raw[j] == '\x0c')) {
                j += 1;
            }
            if (value <= 0x1F or value == 0x7F) return true;
            i = j;
            continue;
        }

        i += 2;
    }
    return false;
}

fn literalStartsWithUnicodeRange(raw: []const u8) bool {
    if (raw.len < 3) return false;
    if (raw[0] != 'U' and raw[0] != 'u') return false;
    if (raw[1] != '+') return false;
    const c = raw[2];
    return std.ascii.isHex(c) or c == '?';
}

fn shouldEmitRawDeclForValue(resolved: *const ResolvedProgram, pool: *InternPool, expr_idx: ExprIndex) bool {
    return shouldEmitRawDeclForValueInfo(resolved, pool, expr_idx).enabled;
}

/// Determine whether subtree of value expression contains `.interp` node. If it contains source `/* */`
/// may be derived from interpolation (e.g. `#{"/* rtl: ..."}`), so strip on the writer side
/// should be skipped. If it is not included, it can be safely stripped using plain CSS literal.
fn exprContainsInterp(resolved: *const ResolvedProgram, expr_idx: ExprIndex) bool {
    const ex = exprAt(resolved, expr_idx);
    switch (ex.kind) {
        .interp => return true,
        .list => {
            const l = resolved.list_exprs.items[ex.payload];
            var i: u32 = 0;
            while (i < l.elem_count) : (i += 1) {
                const ei = resolved.list_elems.items[l.elem_start + i];
                if (exprContainsInterp(resolved, ei)) return true;
            }
            return false;
        },
        else => return false,
    }
}

const RawDeclEmitInfo = struct {
    enabled: bool,
    /// Does value source come from interp (including `#{...}`)? strip Suppression flag Used for judgment.
    has_interp: bool,
};

fn shouldEmitRawDeclForValueInfo(
    resolved: *const ResolvedProgram,
    pool: *InternPool,
    expr_idx: ExprIndex,
) RawDeclEmitInfo {
    const ex = exprAt(resolved, expr_idx);
    switch (ex.kind) {
        .literal_string => {
            const s = resolver.unpackLiteralStringPayload(ex.payload);
            if (s.quoted) return .{ .enabled = false, .has_interp = false };
            const raw = pool.get(s.id);
            return .{ .enabled = literalRawNeedsDeclBypass(raw), .has_interp = false };
        },
        .interp => {
            const ip = resolved.interp_exprs.items[ex.payload];
            // Quoted interpolation relies on declaration serializer to
            // emit outer quotes.
            return .{ .enabled = !ip.preserve_quote, .has_interp = true };
        },
        else => return .{ .enabled = false, .has_interp = false },
    }
}

fn makeSelectorInterpFlags(ip: anytype) u32 {
    var flags: u32 = 0;
    if (ip.source_name_has_interp) flags |= opcode_mod.make_selector_flag_source_name_interp;
    if (ip.source_args_have_interp) flags |= opcode_mod.make_selector_flag_source_args_interp;
    return flags;
}

fn tryCompileDeclSpaceListRawBypass(ctx: CompileCtx, prop_intern: InternId, value_expr: ExprIndex) CompileError!bool {
    const resolved = ctx.resolved;
    const ex = exprAt(resolved, value_expr);
    if (ex.kind != .list) return false;
    const l = resolved.list_exprs.items[ex.payload];
    if (l.separator != .space or l.bracketed or l.is_map or l.elem_count != 2) return false;

    const first_expr = resolved.list_elems.items[l.elem_start];
    const tail_expr = resolved.list_elems.items[l.elem_start + 1];
    const first_ex = exprAt(resolved, first_expr);
    switch (first_ex.kind) {
        .literal_string => {
            const payload = staticLiteralStringPayload(resolved, first_expr) orelse return false;
            if (resolver.unpackLiteralStringPayload(payload).quoted) return false;
        },
        .literal_number => {},
        else => return false,
    }
    if (!shouldEmitRawDeclForValue(resolved, ctx.pool, tail_expr)) return false;

    const spacer_id = try ctx.pool.intern(" ");
    const spacer_idx = try ctx.cb.addConst(Value.string(spacer_id, false));

    try compileExpr(ctx, first_expr);
    try ctx.cb.emit(.load_const, 0, spacer_idx);
    try compileExpr(ctx, tail_expr);
    try ctx.cb.emit(.make_selector, 3, 0);
    try ctx.cb.noteIntern(prop_intern);
    try ctx.cb.emit(.emit_raw_decl, 0, @intFromEnum(prop_intern));
    return true;
}

fn atRootPreludeLooksLikeQuery(resolved: *const ResolvedProgram, pool: *InternPool, maybe_expr: ?ExprIndex) bool {
    const raw = staticPreludeText(resolved, pool, maybe_expr) orelse return false;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return trimmed.len > 0 and trimmed[0] == '(';
}

fn atRootPreludeIsWithoutAllQuery(resolved: *const ResolvedProgram, pool: *InternPool, maybe_expr: ?ExprIndex) bool {
    const raw = staticPreludeText(resolved, pool, maybe_expr) orelse return false;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '(' or trimmed[trimmed.len - 1] != ')') return false;

    const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
    if (!std.mem.startsWith(u8, inner, "without:")) return false;

    var rest = std.mem.trim(u8, inner["without:".len..], " \t\r\n");
    while (rest.len > 0) {
        // SAFETY: both branches below assign `token` before it is read.
        var token: []const u8 = undefined;
        if (rest[0] == '"' or rest[0] == '\'') {
            const quote = rest[0];
            const end = std.mem.findScalarPos(u8, rest, 1, quote) orelse return false;
            token = rest[1..end];
            rest = if (end + 1 < rest.len) std.mem.trimStart(u8, rest[end + 1 ..], " \t\r\n") else "";
        } else {
            const end = std.mem.findAny(u8, rest, " \t\r\n") orelse rest.len;
            token = rest[0..end];
            rest = if (end < rest.len) std.mem.trimStart(u8, rest[end..], " \t\r\n") else "";
        }
        if (std.mem.eql(u8, token, "all")) return true;
    }
    return false;
}

fn atRootBehaviorKeepsRule(behavior: AtRootBehavior) bool {
    return switch (behavior) {
        .without_media,
        .without_layer,
        .without_supports,
        .without_media_supports,
        .with_rule,
        .with_all,
        => true,
        else => false,
    };
}

fn atRootBehaviorBubbleMask(behavior: AtRootBehavior) u8 {
    return switch (behavior) {
        .without_media => at_root_bubble_media_mask,
        .without_layer => at_root_bubble_layer_mask,
        .without_supports => at_root_bubble_supports_mask,
        .without_media_supports => at_root_bubble_media_mask | at_root_bubble_supports_mask,
        .without_all, .with_rule => at_root_bubble_media_mask | at_root_bubble_supports_mask | at_root_bubble_layer_mask,
        .with_media => at_root_bubble_supports_mask | at_root_bubble_layer_mask,
        .with_layer => at_root_bubble_media_mask | at_root_bubble_supports_mask,
        .with_supports => at_root_bubble_media_mask | at_root_bubble_layer_mask,
        .with_media_supports => at_root_bubble_layer_mask,
        .with_all, .none => 0,
    };
}

fn tryCompileFilteredAtRoot(ctx: CompileCtx, ar: anytype) CompileError!bool {
    const raw_name = atRuleNameRaw(ctx.pool.get(ar.name_intern));
    if (!std.mem.eql(u8, raw_name, "at-root")) return false;
    if (ar.at_root_behavior == .none) return false;

    const keep_rule = atRootBehaviorKeepsRule(ar.at_root_behavior);
    const bubble_mask = atRootBehaviorBubbleMask(ar.at_root_behavior);

    if (!keep_rule) {
        try ctx.cb.emit(.push_at_root_scope, 1, 0);
        errdefer ctx.cb.emit(.pop_at_root_scope, 0, 0) catch |err| {
            std.debug.panic("tryCompileFilteredAtRoot: failed to unwind at-root scope: {s}", .{@errorName(err)});
        };
    }
    if (bubble_mask != 0) {
        try ctx.cb.emit(.push_at_root_bubble, bubble_mask, 0);
        errdefer ctx.cb.emit(.pop_at_root_bubble, 0, 0) catch |err| {
            std.debug.panic("tryCompileFilteredAtRoot: failed to unwind at-root bubble: {s}", .{@errorName(err)});
        };
    }

    if (keep_rule and stmtSliceCanUseSimpleSourceOrderLowering(ctx.resolved, ar.body_direct)) {
        try compileCurrentSelectorSourceOrderedMaybe(ctx, ar.body_direct);
    } else {
        for (ar.body_direct) |child_si| {
            try compileStmt(ctx, child_si);
        }
    }

    if (bubble_mask != 0) {
        try ctx.cb.emit(.pop_at_root_bubble, 0, 0);
    }
    if (!keep_rule) {
        try ctx.cb.emit(.pop_at_root_scope, 0, 0);
    }
    return true;
}

fn tryCompileHoistedAtRoot(ctx: CompileCtx, ar: anytype) CompileError!bool {
    const raw_name = atRuleNameRaw(ctx.pool.get(ar.name_intern));
    if (!std.mem.eql(u8, raw_name, "at-root")) return false;
    if (atRootPreludeLooksLikeQuery(ctx.resolved, ctx.pool, ar.prelude_expr)) return false;

    try ctx.cb.emit(.push_at_root_scope, 0, 0);
    errdefer ctx.cb.emit(.pop_at_root_scope, 0, 0) catch |err| {
        std.debug.panic("tryCompileHoistedAtRoot: failed to unwind at-root scope: {s}", .{@errorName(err)});
    };

    if (ar.prelude_expr) |prelude_expr| {
        try compileHoistedAtRootDynamicBody(ctx, prelude_expr, ar.body_direct);
    } else {
        for (ar.body_direct) |child_si| {
            try compileStmt(ctx, child_si);
        }
    }

    try ctx.cb.emit(.pop_at_root_scope, 0, 0);
    return true;
}

fn compileHoistedAtRootDynamicBody(
    ctx: CompileCtx,
    prelude_expr: ExprIndex,
    body_direct: []const StmtIndex,
) CompileError!void {
    const dummy_rule = RuleData{
        .selector_kind = .dynamic,
        .literal_intern = .none,
        .is_placeholder = false,
        .dynamic_parts_start = 0,
        .dynamic_parts_count = 0,
        .body_direct = @constCast(body_direct),
    };
    const use_push_only = ruleUsesPushOnlyOuter(ctx.resolved, ctx.modules, ctx.pool, ctx.module_id, dummy_rule);
    const inner_ctx = selectorContextChildCtx(ctx);

    try compileExpr(ctx, prelude_expr);
    try ctx.cb.emit(.push_selector_scope_dynamic, 0, 0);
    if (stmtSliceCanUseSimpleSourceOrderLowering(ctx.resolved, body_direct)) {
        if (use_push_only or stmtSliceHasDirectContentCall(ctx.resolved, body_direct)) {
            try compileCurrentSelectorSourceOrderedMaybe(inner_ctx, body_direct);
        } else {
            try compileCurrentSelectorSourceOrdered(inner_ctx, body_direct);
        }
        try inner_ctx.cb.emit(.pop_rule_scope, 0, 0);
        return;
    }

    if (use_push_only) {
        for (body_direct) |child_si| {
            try compileStmt(inner_ctx, child_si);
        }
        try inner_ctx.cb.emit(.pop_rule_scope, 0, 0);
    } else {
        try inner_ctx.cb.emit(.emit_rule_begin_current, 0, 0);
        for (body_direct) |child_si| {
            try compileStmt(inner_ctx, child_si);
        }
        try inner_ctx.cb.emit(.emit_rule_end_pop, 0, 0);
    }
}

fn emitSassErrorMessage(ctx: CompileCtx, msg: []const u8) CompileError!void {
    const msg_id = try ctx.pool.intern(msg);
    const ci = try ctx.cb.addConst(Value.string(msg_id, false));
    try ctx.cb.emit(.load_const, 0, ci);
    try ctx.cb.emit(.emit_error, 0, 0);
}

fn atRuleStmtIsMedia(resolved: *const ResolvedProgram, pool: *InternPool, si: StmtIndex) bool {
    if (si >= resolved.stmts.items.len) return false;
    const st = resolved.stmts.items[si];
    if (st.kind != .at_rule or st.payload >= resolved.at_rule_stmts.items.len) return false;
    const ar = resolved.at_rule_stmts.items[st.payload];
    const raw_name = atRuleNameRaw(pool.get(ar.name_intern));
    return std.mem.eql(u8, raw_name, "media");
}

fn normalizeKeyframeSelectorIntern(pool: *InternPool, alloc: std.mem.Allocator, selector_id: InternId) CompileError!InternId {
    const text = pool.get(selector_id);
    if (std.mem.findScalar(u8, text, '%') == null) return selector_id;
    if (std.mem.findScalar(u8, text, 'E') == null) return selector_id;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, text.len);

    var changed = false;
    for (text, 0..) |ch, i| {
        if (ch == 'E' and i > 0 and std.ascii.isDigit(text[i - 1])) {
            const has_exponent_digits = if (i + 1 < text.len and (text[i + 1] == '+' or text[i + 1] == '-'))
                (i + 2 < text.len and std.ascii.isDigit(text[i + 2]))
            else
                (i + 1 < text.len and std.ascii.isDigit(text[i + 1]));
            if (has_exponent_digits) {
                out.appendAssumeCapacity('e');
                changed = true;
                continue;
            }
        }
        out.appendAssumeCapacity(ch);
    }

    if (!changed) return selector_id;
    return pool.intern(out.items) catch error.OutOfMemory;
}

fn atRuleIsKeyframes(raw_name: []const u8) bool {
    return std.mem.eql(u8, raw_name, "keyframes") or
        std.mem.eql(u8, raw_name, "-webkit-keyframes") or
        std.mem.eql(u8, raw_name, "-moz-keyframes") or
        std.mem.eql(u8, raw_name, "-o-keyframes") or
        std.mem.eql(u8, raw_name, "-ms-keyframes");
}

fn atRuleClearsParentSelectorContext(raw_name: []const u8) bool {
    return std.mem.eql(u8, raw_name, "font-face") or atRuleIsKeyframes(raw_name);
}

fn exprAt(resolved: *const ResolvedProgram, idx: ExprIndex) ResolvedExpr {
    return resolved.exprs.items[idx];
}

fn numberExprValue(resolved: *const ResolvedProgram, payload: u32, alloc: std.mem.Allocator) CompileError!Value {
    const n = resolved.number_pool.items[payload];
    const bits: u64 = (@as(u64, n.hi) << 32) | @as(u64, n.lo);
    const v: f64 = @bitCast(bits);
    return if (n.unit_id == .none)
        Value.numberUnitless(v)
    else
        // shared pool (P4 c3 retry A.2): pointer passed directly, @constCast unnecessary.
        try Value.number(v, n.unit_id, resolved.value_number_pool, alloc);
}

fn literalColorValue(ctx: CompileCtx, payload: u32) CompileError!Value {
    if (payload >= ctx.resolved.color_literals.items.len) return error.Unsupported;
    const lit = ctx.resolved.color_literals.items[payload];
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
        .legacy = true,
        .prefer_long_hex = alpha_bearing,
        .inspect_repr = if (alpha_bearing)
            .auto
        else if ((lit.flags & 0b0000_1000) != 0)
            .legacy_rgb_function
        else if ((lit.flags & 0b0000_0001) != 0)
            .literal_long_hex
        else
            .literal_short_hex,
        .inspect_uppercase_hex = (lit.flags & 0b0000_0010) != 0,
    };
    const handle = value_mod.pushColorEntry(ctx.color_pool, ctx.cb.color_alloc, entry) catch return error.OutOfMemory;
    return Value.colorWithHandle(handle);
}

fn compileParamDefaultConstValue(ctx: CompileCtx, ex: ResolvedExpr) CompileError!?Value {
    return switch (ex.kind) {
        .literal_number => try numberExprValue(ctx.resolved, ex.payload, ctx.cb.shared_pool_alloc),
        .literal_string => blk: {
            const s = resolver.unpackLiteralStringPayload(ex.payload);
            const normalized_id = try normalizeLiteralStringIntern(ctx.pool, ctx.cb.alloc, s.id, s.quoted, true);
            break :blk Value.stringWithFlagsEx(normalized_id, s.quoted, false, s.named_color_literal);
        },
        .literal_color => try literalColorValue(ctx, ex.payload),
        .literal_bool => if (ex.payload != 0) Value.true_v else Value.false_v,
        .literal_null => Value.nil_v,
        .list => blk: {
            const l = ctx.resolved.list_exprs.items[ex.payload];
            if (l.separator != .slash or l.bracketed or l.is_map or l.elem_count != 2) {
                break :blk null;
            }
            const lhs_idx = ctx.resolved.list_elems.items[l.elem_start];
            const rhs_idx = ctx.resolved.list_elems.items[l.elem_start + 1];
            const lhs_ex = exprAt(ctx.resolved, lhs_idx);
            const rhs_ex = exprAt(ctx.resolved, rhs_idx);
            if (lhs_ex.kind != .literal_number or rhs_ex.kind != .literal_number) {
                break :blk null;
            }
            const lhs = try numberExprValue(ctx.resolved, lhs_ex.payload, ctx.cb.shared_pool_alloc);
            const rhs = try numberExprValue(ctx.resolved, rhs_ex.payload, ctx.cb.shared_pool_alloc);
            if (lhs.kind() != .number or rhs.kind() != .number) break :blk null;
            const np = ctx.resolved.value_number_pool;
            if (lhs.unitId(np) != .none or rhs.unitId(np) != .none) break :blk null;
            break :blk Value.numberUnitless(lhs.asF64(np) / rhs.asF64(np));
        },
        else => null,
    };
}

fn compileParamDefaultOperand(ctx: CompileCtx, expr_idx: ExprIndex) CompileError!?Chunk.ParamDefaultBinaryOperand {
    const ex = exprAt(ctx.resolved, expr_idx);
    if (try compileParamDefaultConstValue(ctx, ex)) |const_v| {
        return .{ .value = const_v };
    }
    return switch (ex.kind) {
        .var_ref => .{ .local_slot = try checkedU16(remapLocalSlot(ctx, ex.payload), "param default local slot") },
        .cross_var_ref => blk: {
            const cross = ctx.resolved.cross_var_refs.items[ex.payload];
            break :blk .{
                .cross_slot = .{
                    .module_id = cross.module_id,
                    .slot = cross.slot,
                },
            };
        },
        else => null,
    };
}

fn compileParamDefaultAtomExpr(ctx: CompileCtx, expr_idx: ExprIndex) CompileError!?Chunk.ParamDefaultAtomExpr {
    const ex = exprAt(ctx.resolved, expr_idx);
    if (try compileParamDefaultConstValue(ctx, ex)) |const_v| {
        return .{ .value = const_v };
    }
    return switch (ex.kind) {
        .var_ref => .{ .local_slot = try checkedU16(remapLocalSlot(ctx, ex.payload), "param default atom local slot") },
        .cross_var_ref => blk: {
            const cross = ctx.resolved.cross_var_refs.items[ex.payload];
            break :blk .{
                .cross_slot = .{
                    .module_id = cross.module_id,
                    .slot = cross.slot,
                },
            };
        },
        .binary => blk: {
            const b = ctx.resolved.binary_exprs.items[ex.payload];
            switch (b.op) {
                .add, .sub, .mul, .div, .mod, .eq, .neq, .lt, .gt, .le, .ge => {},
                else => break :blk null,
            }
            const lhs = (try compileParamDefaultOperand(ctx, b.lhs)) orelse break :blk null;
            const rhs = (try compileParamDefaultOperand(ctx, b.rhs)) orelse break :blk null;
            break :blk .{
                .binary = .{
                    .op = b.op,
                    .lhs = lhs,
                    .rhs = rhs,
                },
            };
        },
        .unary => blk: {
            const u = ctx.resolved.unary_exprs.items[ex.payload];
            const operand = (try compileParamDefaultOperand(ctx, u.operand)) orelse break :blk null;
            break :blk .{
                .unary = .{
                    .op = u.op,
                    .operand = operand,
                },
            };
        },
        else => null,
    };
}

fn compileParamDefaultLeafBuiltinCallExpr(ctx: CompileCtx, payload: u32) CompileError!?Chunk.ParamDefaultExpr {
    if (payload >= ctx.resolved.builtin_calls.items.len) return null;
    const call = ctx.resolved.builtin_calls.items[payload];
    if (call.prebound_kind != .none) return null;
    if (call.arg_count > Chunk.max_param_default_call_args) return null;

    var out: Chunk.ParamDefaultLeafBuiltinCall = .{
        .builtin_id = call.builtin_id,
        .argc = @intCast(call.arg_count),
        // SAFETY: slots 0..argc are assigned in the following loop; only those slots are ever read.
        .args = undefined,
        .arg_names = [_]InternId{.none} ** Chunk.max_param_default_call_args,
    };

    var i: u32 = 0;
    while (i < call.arg_count) : (i += 1) {
        const arg_idx = call.arg_start + i;
        if (arg_idx >= ctx.resolved.call_args.items.len or arg_idx >= ctx.resolved.call_arg_names.items.len) {
            return null;
        }
        const arg_name = ctx.resolved.call_arg_names.items[arg_idx];
        if (arg_name == resolver.call_arg_splat_sentinel) return null;
        out.arg_names[i] = arg_name;
        out.args[i] = (try compileParamDefaultAtomExpr(ctx, ctx.resolved.call_args.items[arg_idx])) orelse return null;
    }
    return .{ .builtin_call = out };
}

fn compileParamDefaultLeafCallExpr(ctx: CompileCtx, payload: u32) CompileError!?Chunk.ParamDefaultExpr {
    if (payload >= ctx.resolved.call_exprs.items.len) return null;
    const call = ctx.resolved.call_exprs.items[payload];
    if (call.callee_capture_callers_locals) return null;
    if (call.arg_count > Chunk.max_param_default_call_args) return null;

    var out: Chunk.ParamDefaultLeafCall = .{
        .callee_module = if (call.callee_is_css) 0 else call.callee_module,
        .callee_id = call.callee_id,
        .callee_name = call.callee_name,
        .callee_is_css = call.callee_is_css,
        .argc = @intCast(call.arg_count),
        // SAFETY: slots 0..argc are assigned in the following loop; only those slots are ever read.
        .args = undefined,
        .arg_names = [_]InternId{.none} ** Chunk.max_param_default_call_args,
    };

    var i: u32 = 0;
    while (i < call.arg_count) : (i += 1) {
        const arg_idx = call.arg_start + i;
        if (arg_idx >= ctx.resolved.call_args.items.len or arg_idx >= ctx.resolved.call_arg_names.items.len) {
            return null;
        }
        const arg_name = ctx.resolved.call_arg_names.items[arg_idx];
        if (arg_name == resolver.call_arg_splat_sentinel) return null;
        out.arg_names[i] = arg_name;
        out.args[i] = (try compileParamDefaultAtomExpr(ctx, ctx.resolved.call_args.items[arg_idx])) orelse return null;
    }
    return .{ .call = out };
}

fn compileParamDefaultInterp(ctx: CompileCtx, expr_idx: ExprIndex) CompileError!?Chunk.ParamDefaultInterp {
    const ex = exprAt(ctx.resolved, expr_idx);
    if (ex.kind != .interp) return null;
    const ip = ctx.resolved.interp_exprs.items[ex.payload];
    if (ip.part_count == 0) return null;
    if (ip.part_count > Chunk.max_param_default_interp_parts) return null;

    var out: Chunk.ParamDefaultInterp = .{
        .preserve_quote = ip.preserve_quote,
        .part_count = @intCast(ip.part_count),
        // SAFETY: slots 0..part_count are assigned in the following loop; only those slots are ever read.
        .parts = undefined,
    };

    var i: u32 = 0;
    while (i < ip.part_count) : (i += 1) {
        const part_idx = ctx.resolved.interp_parts.items[ip.part_start + i];
        out.parts[i] = (try compileParamDefaultAtomExpr(ctx, part_idx)) orelse return null;
    }
    return out;
}

fn compileParamDefaultExpr(ctx: CompileCtx, expr_idx: ExprIndex) CompileError!?Chunk.ParamDefaultExpr {
    if (try compileParamDefaultAtomExpr(ctx, expr_idx)) |expr| {
        return switch (expr) {
            .value => |v| .{ .value = v },
            .local_slot => |slot| .{ .local_slot = slot },
            .cross_slot => |target| .{ .cross_slot = target },
            .binary => |binary| .{ .binary = binary },
            .unary => |unary| .{ .unary = unary },
        };
    }

    const ex = exprAt(ctx.resolved, expr_idx);
    if (ex.kind == .interp) {
        const ip = ctx.resolved.interp_exprs.items[ex.payload];
        if (!ip.preserve_quote and ip.part_count == 1) {
            return try compileParamDefaultExpr(ctx, ctx.resolved.interp_parts.items[ip.part_start]);
        }
        if (try compileParamDefaultInterp(ctx, expr_idx)) |interp| {
            return .{ .interp = interp };
        }
    }

    return switch (ex.kind) {
        .builtin_call => try compileParamDefaultLeafBuiltinCallExpr(ctx, ex.payload),
        .call => try compileParamDefaultLeafCallExpr(ctx, ex.payload),
        else => null,
    };
}

fn paramDefaultFromExpr(expr: Chunk.ParamDefaultAtomExpr) Chunk.ParamDefault {
    return switch (expr) {
        .value => |v| .{ .value = v },
        .local_slot => |slot| .{ .local_slot = slot },
        .cross_slot => |target| .{ .cross_slot = target },
        .binary => |binary| .{ .binary = binary },
        .unary => |unary| .{ .unary = unary },
    };
}

fn compileParamDefaultBuiltinCall(ctx: CompileCtx, payload: u32) CompileError!?Chunk.ParamDefault {
    if (payload >= ctx.resolved.builtin_calls.items.len) return null;
    const call = ctx.resolved.builtin_calls.items[payload];
    if (call.prebound_kind != .none) return null;
    if (call.arg_count > Chunk.max_param_default_call_args) return null;

    var out: Chunk.ParamDefaultBuiltinCall = .{
        .builtin_id = call.builtin_id,
        .argc = @intCast(call.arg_count),
        // SAFETY: slots 0..argc are assigned in the following loop; only those slots are ever read.
        .args = undefined,
        .arg_names = [_]InternId{.none} ** Chunk.max_param_default_call_args,
    };

    var i: u32 = 0;
    while (i < call.arg_count) : (i += 1) {
        const arg_idx = call.arg_start + i;
        if (arg_idx >= ctx.resolved.call_args.items.len or arg_idx >= ctx.resolved.call_arg_names.items.len) {
            return null;
        }
        const arg_name = ctx.resolved.call_arg_names.items[arg_idx];
        if (arg_name == resolver.call_arg_splat_sentinel) return null;
        out.arg_names[i] = arg_name;
        out.args[i] = (try compileParamDefaultExpr(ctx, ctx.resolved.call_args.items[arg_idx])) orelse return null;
    }
    return .{ .builtin_call = out };
}

fn compileParamDefaultCall(ctx: CompileCtx, payload: u32) CompileError!?Chunk.ParamDefault {
    if (payload >= ctx.resolved.call_exprs.items.len) return null;
    const call = ctx.resolved.call_exprs.items[payload];
    if (call.callee_capture_callers_locals) return null;
    if (call.arg_count > Chunk.max_param_default_call_args) return null;

    var out: Chunk.ParamDefaultCall = .{
        .callee_module = if (call.callee_is_css) 0 else call.callee_module,
        .callee_id = call.callee_id,
        .callee_name = call.callee_name,
        .callee_is_css = call.callee_is_css,
        .argc = @intCast(call.arg_count),
        // SAFETY: slots 0..argc are assigned in the following loop; only those slots are ever read.
        .args = undefined,
        .arg_names = [_]InternId{.none} ** Chunk.max_param_default_call_args,
    };

    var i: u32 = 0;
    while (i < call.arg_count) : (i += 1) {
        const arg_idx = call.arg_start + i;
        if (arg_idx >= ctx.resolved.call_args.items.len or arg_idx >= ctx.resolved.call_arg_names.items.len) {
            return null;
        }
        const arg_name = ctx.resolved.call_arg_names.items[arg_idx];
        if (arg_name == resolver.call_arg_splat_sentinel) return null;
        out.arg_names[i] = arg_name;
        out.args[i] = (try compileParamDefaultExpr(ctx, ctx.resolved.call_args.items[arg_idx])) orelse return null;
    }
    return .{ .call = out };
}

fn compileParamDefaultIfBuiltin(ctx: CompileCtx, payload: u32) CompileError!?Chunk.ParamDefault {
    if (payload >= ctx.resolved.call_exprs.items.len) return null;
    const call = ctx.resolved.call_exprs.items[payload];
    if (call.arg_count != 3) return null;
    const condition_idx = call.arg_start;
    const if_true_idx = call.arg_start + 1;
    const if_false_idx = call.arg_start + 2;
    if (if_false_idx >= ctx.resolved.call_args.items.len or if_false_idx >= ctx.resolved.call_arg_names.items.len) return null;
    if (ctx.resolved.call_arg_names.items[condition_idx] != .none or
        ctx.resolved.call_arg_names.items[if_true_idx] != .none or
        ctx.resolved.call_arg_names.items[if_false_idx] != .none)
    {
        return null;
    }
    return .{
        .if_builtin = .{
            .condition = (try compileParamDefaultExpr(ctx, ctx.resolved.call_args.items[condition_idx])) orelse return null,
            .if_true = (try compileParamDefaultExpr(ctx, ctx.resolved.call_args.items[if_true_idx])) orelse return null,
            .if_false = (try compileParamDefaultExpr(ctx, ctx.resolved.call_args.items[if_false_idx])) orelse return null,
        },
    };
}

fn compileParamDefault(ctx: CompileCtx, maybe_e: ?ExprIndex) CompileError!Chunk.ParamDefault {
    const e = maybe_e orelse return .none;
    const ex = exprAt(ctx.resolved, e);
    if (try compileParamDefaultAtomExpr(ctx, e)) |expr| {
        return paramDefaultFromExpr(expr);
    }
    if (ex.kind == .interp) {
        const ip = ctx.resolved.interp_exprs.items[ex.payload];
        if (!ip.preserve_quote and ip.part_count == 1) {
            return try compileParamDefault(ctx, ctx.resolved.interp_parts.items[ip.part_start]);
        }
        if (try compileParamDefaultInterp(ctx, e)) |interp| {
            return .{ .interp = interp };
        }
    }
    return switch (ex.kind) {
        .if_builtin => (try compileParamDefaultIfBuiltin(ctx, ex.payload)) orelse .none,
        .builtin_call => (try compileParamDefaultBuiltinCall(ctx, ex.payload)) orelse .none,
        .call => (try compileParamDefaultCall(ctx, ex.payload)) orelse .none,
        .list => (try compileParamDefaultList(ctx, ex.payload)) orelse .none,
        else => .none,
    };
}

fn compileParamDefaultList(ctx: CompileCtx, payload: u32) CompileError!?Chunk.ParamDefault {
    if (payload >= ctx.resolved.list_exprs.items.len) return null;
    const l = ctx.resolved.list_exprs.items[payload];
    if (l.elem_count > Chunk.max_param_default_list_items) return null;

    var out: Chunk.ParamDefaultList = .{
        .separator = l.separator,
        .bracketed = l.bracketed,
        .is_map = l.is_map,
        .elem_count = @intCast(l.elem_count),
        // SAFETY: slots 0..elem_count are assigned below.
        .elems = undefined,
    };

    var i: u32 = 0;
    while (i < l.elem_count) : (i += 1) {
        const elem_abs_idx = l.elem_start + i;
        if (elem_abs_idx >= ctx.resolved.list_elems.items.len) return null;
        const elem_idx = ctx.resolved.list_elems.items[elem_abs_idx];
        const elem_ex = exprAt(ctx.resolved, elem_idx);
        if (elem_ex.kind == .if_builtin) {
            const compiled_if = (try compileParamDefaultIfBuiltin(ctx, elem_ex.payload)) orelse return null;
            out.elems[i] = switch (compiled_if) {
                .if_builtin => |if_builtin| .{ .if_builtin = if_builtin },
                else => return null,
            };
        } else {
            const compiled = (try compileParamDefaultExpr(ctx, elem_idx)) orelse return null;
            out.elems[i] = .{ .expr = compiled };
        }
    }
    return .{ .list = out };
}

fn mapBinOpcode(op: BinOp) Opcode {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .eq => .eq,
        .neq => .neq,
        .lt => .lt,
        .gt => .gt,
        .le => .le,
        .ge => .ge,
        .and_op => .and_op,
        .or_op => .or_op,
    };
}

fn emitForcedSassError(ctx: CompileCtx) CompileError!void {
    const nil_idx = try ctx.cb.addConst(Value.nil_v);
    try ctx.cb.emit(.load_const, 0, nil_idx);
    try ctx.cb.emit(.emit_error, 0, 0);
}

fn builtinRejectsSassScriptModulo(builtin_id: u32) bool {
    return switch (builtin_id) {
        // global round() must still prefer Sass builtin dispatch for SassScript `%`
        // so `round(7 % 3, 1)` errors as a two-arg builtin call rather than
        // lowering as CSS round().
        3 => true,
        // math.sqrt / pow / log / trig / atan2 / hypot / exp / sign / mod / rem
        11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 105, 106, 107, 108 => true,
        else => false,
    };
}

fn exprContainsModulo(resolved: *const ResolvedProgram, idx: ExprIndex) bool {
    const ex = exprAt(resolved, idx);
    return switch (ex.kind) {
        .binary => blk: {
            const b = resolved.binary_exprs.items[ex.payload];
            if (b.op == .mod) break :blk true;
            break :blk exprContainsModulo(resolved, b.lhs) or exprContainsModulo(resolved, b.rhs);
        },
        .unary => blk: {
            const u = resolved.unary_exprs.items[ex.payload];
            break :blk exprContainsModulo(resolved, u.operand);
        },
        .call => blk: {
            const c = resolved.call_exprs.items[ex.payload];
            var i: u32 = 0;
            while (i < c.arg_count) : (i += 1) {
                if (exprContainsModulo(resolved, resolved.call_args.items[c.arg_start + i])) break :blk true;
            }
            break :blk false;
        },
        .builtin_call => blk: {
            const c = resolved.builtin_calls.items[ex.payload];
            var i: u32 = 0;
            while (i < c.arg_count) : (i += 1) {
                if (exprContainsModulo(resolved, resolved.call_args.items[c.arg_start + i])) break :blk true;
            }
            break :blk false;
        },
        .if_builtin => blk: {
            const c = resolved.call_exprs.items[ex.payload];
            var i: u32 = 0;
            while (i < c.arg_count) : (i += 1) {
                if (exprContainsModulo(resolved, resolved.call_args.items[c.arg_start + i])) break :blk true;
            }
            break :blk false;
        },
        .list => blk: {
            const l = resolved.list_exprs.items[ex.payload];
            var i: u32 = 0;
            while (i < l.elem_count) : (i += 1) {
                if (exprContainsModulo(resolved, resolved.list_elems.items[l.elem_start + i])) break :blk true;
            }
            break :blk false;
        },
        .interp => blk: {
            const ip = resolved.interp_exprs.items[ex.payload];
            var i: u32 = 0;
            while (i < ip.part_count) : (i += 1) {
                if (exprContainsModulo(resolved, resolved.interp_parts.items[ip.part_start + i])) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn mapUnaryOpcode(op: UnaryOp) Opcode {
    return switch (op) {
        .neg => .neg,
        .pos => .pos,
        .slash_prefix => .slash_prefix,
        .not_op => .not_op,
    };
}

fn addBuiltinCallMeta(ctx: CompileCtx, arg_start: u32, arg_count: u32, local_slot_hint: u32) CompileError!u32 {
    const meta_idx: u32 = std.math.cast(u32, ctx.cb.builtin_call_meta.items.len) orelse return error.ProgramTooLarge;
    const names_start: u32 = std.math.cast(u32, ctx.cb.builtin_call_arg_names.items.len) orelse return error.ProgramTooLarge;
    try ctx.cb.builtin_call_arg_names.ensureUnusedCapacity(ctx.cb.alloc, @intCast(arg_count));
    var i: u32 = 0;
    while (i < arg_count) : (i += 1) {
        ctx.cb.builtin_call_arg_names.appendAssumeCapacity(ctx.resolved.call_arg_names.items[arg_start + i]);
    }
    try ctx.cb.builtin_call_meta.append(ctx.cb.alloc, .{
        .argc = arg_count,
        .arg_names_start = names_start,
        .local_slot_hint = local_slot_hint,
    });
    return meta_idx;
}

fn addBuiltinCallMetaFromIndices(ctx: CompileCtx, indices: []const u32, local_slot_hint: u32) CompileError!u32 {
    const meta_idx: u32 = std.math.cast(u32, ctx.cb.builtin_call_meta.items.len) orelse return error.ProgramTooLarge;
    const names_start: u32 = std.math.cast(u32, ctx.cb.builtin_call_arg_names.items.len) orelse return error.ProgramTooLarge;
    try ctx.cb.builtin_call_arg_names.ensureUnusedCapacity(ctx.cb.alloc, indices.len);
    for (indices) |idx| {
        ctx.cb.builtin_call_arg_names.appendAssumeCapacity(ctx.resolved.call_arg_names.items[idx]);
    }
    try ctx.cb.builtin_call_meta.append(ctx.cb.alloc, .{
        .argc = @intCast(indices.len),
        .arg_names_start = names_start,
        .local_slot_hint = local_slot_hint,
    });
    return meta_idx;
}

fn findMetaControlArgIndex(
    ctx: CompileCtx,
    arg_start: u32,
    arg_count: u32,
    control_name: []const u8,
) ?u32 {
    const start: usize = @intCast(arg_start);
    const count: usize = @intCast(arg_count);
    const window = ctx.resolved.call_arg_names.items[start..][0..count];
    const off = meta_helpers.findMetaControlArgOffset(ctx.pool, window, count, control_name) orelse return null;
    return arg_start + @as(u32, @intCast(off));
}

fn findMetaControlArgIndexResolved(
    pool: *InternPool,
    resolved: *const ResolvedProgram,
    arg_start: u32,
    arg_count: u32,
    control_name: []const u8,
) ?u32 {
    const start: usize = @intCast(arg_start);
    const count: usize = @intCast(arg_count);
    const window = resolved.call_arg_names.items[start..][0..count];
    const off = meta_helpers.findMetaControlArgOffset(pool, window, count, control_name) orelse return null;
    return arg_start + @as(u32, @intCast(off));
}

fn appendForwardedMetaArgIndices(
    ctx: CompileCtx,
    arg_start: u32,
    arg_count: u32,
    control_idx: ?u32,
    out: *std.ArrayListUnmanaged(u32),
) CompileError!void {
    try out.ensureUnusedCapacity(ctx.cb.alloc, @intCast(arg_count));
    var i: u32 = 0;
    while (i < arg_count) : (i += 1) {
        const idx = arg_start + i;
        if (control_idx != null and idx == control_idx.?) continue;
        out.appendAssumeCapacity(idx);
    }
}

fn compileExpr(ctx: CompileCtx, e: ExprIndex) CompileError!void {
    const resolved = ctx.resolved;
    const ex = exprAt(resolved, e);
    const prev_span = ctx.cb.current_span;
    defer ctx.cb.current_span = prev_span;
    ctx.cb.setSourceSpan(ex.span);
    switch (ex.kind) {
        .literal_number => {
            const n = resolved.number_pool.items[ex.payload];
            const bits: u64 = (@as(u64, n.hi) << 32) | @as(u64, n.lo);
            const v: f64 = @bitCast(bits);
            const val = if (n.unit_id == .none)
                Value.numberUnitless(v)
            else
                try Value.number(v, n.unit_id, resolved.value_number_pool, ctx.cb.shared_pool_alloc);
            const idx = try ctx.cb.addConst(val);
            try ctx.cb.emit(.load_const, 0, idx);
        },
        .literal_string => {
            const s = resolver.unpackLiteralStringPayload(ex.payload);
            const normalized_id = try normalizeLiteralStringIntern(ctx.pool, ctx.cb.alloc, s.id, s.quoted, !ctx.skip_decimal_normalize);
            if (!s.quoted and !s.named_color_literal and !s.raw_text) {
                const raw = ctx.pool.get(normalized_id);
                if (raw.len == 1 and raw[0] == '&') {
                    try ctx.cb.emit(.load_parent_selector, 0, 0);
                    return;
                }
            }
            const val = if (s.raw_text and !s.quoted)
                Value.stringPreservingAmpersand(normalized_id, false).withPreserveDeclText()
            else
                Value.stringWithFlagsEx(normalized_id, s.quoted, false, s.named_color_literal);
            const idx = try ctx.cb.addConst(val);
            try ctx.cb.emit(.load_const, 0, idx);
        },
        .literal_color => {
            const val = try literalColorValue(ctx, ex.payload);
            const idx = try ctx.cb.addConst(val);
            try ctx.cb.emit(.load_const, 0, idx);
        },
        .literal_bool => {
            const val = if (ex.payload != 0) Value.true_v else Value.false_v;
            const idx = try ctx.cb.addConst(val);
            try ctx.cb.emit(.load_const, 0, idx);
        },
        .literal_null => {
            const idx = try ctx.cb.addConst(Value.nil_v);
            try ctx.cb.emit(.load_const, 0, idx);
        },
        .sass_error => {
            try emitForcedSassError(ctx);
        },
        .var_ref => {
            try ctx.cb.emit(.load_local, 0, remapLocalSlot(ctx, ex.payload));
        },
        .binary => {
            const b = resolved.binary_exprs.items[ex.payload];
            if (b.op == .and_op) {
                // Sass `and` returns short-circuit + value (no boolean coercion).
                // stack: [lhs]
                try compileExpr(ctx, b.lhs);
                // stack: [lhs, lhs]
                try ctx.cb.emit(.dup, 0, 0);
                const jmp_false_pc = ctx.cb.code.items.len;
                // If false, pop duplicate and jump. Returns the original lhs as is.
                try ctx.cb.emit(.jmp_if_false, 0, 0);
                // true side: discard the original lhs and evaluate rhs and return it.
                try ctx.cb.emit(.pop, 0, 0);
                try compileExpr(ctx, b.rhs);
                const end_pc = ctx.cb.code.items.len;
                ctx.cb.patchJmp(jmp_false_pc, end_pc);
                return;
            }
            if (b.op == .or_op) {
                // Sass `or` returns short-circuit + value.
                try compileExpr(ctx, b.lhs);
                try ctx.cb.emit(.dup, 0, 0);
                const jmp_true_pc = ctx.cb.code.items.len;
                // If true, pop duplicate and jump. Return the original lhs as is.
                try ctx.cb.emit(.jmp_if_true, 0, 0);
                // False side: Discard the original lhs and evaluate rhs and return it.
                try ctx.cb.emit(.pop, 0, 0);
                try compileExpr(ctx, b.rhs);
                const end_pc = ctx.cb.code.items.len;
                ctx.cb.patchJmp(jmp_true_pc, end_pc);
                return;
            }
            try compileExpr(ctx, b.lhs);
            try compileExpr(ctx, b.rhs);
            try ctx.cb.emit(mapBinOpcode(b.op), 0, 0);
        },
        .unary => {
            const u = resolved.unary_exprs.items[ex.payload];
            try compileExpr(ctx, u.operand);
            try ctx.cb.emit(mapUnaryOpcode(u.op), 0, 0);
        },
        .call => {
            const c = resolved.call_exprs.items[ex.payload];
            if (c.callee_is_css and c.arg_count >= 2 and c.callee_name != .none) {
                const call_name = ctx.pool.get(c.callee_name);
                if (std.ascii.eqlIgnoreCase(call_name, "calc-size")) {
                    const second = resolved.call_args.items[c.arg_start + 1];
                    if (exprContainsModulo(resolved, second)) {
                        try emitForcedSassError(ctx);
                        return;
                    }
                }
            }
            var flags: u16 = 0;
            var module_bits: u16 = 0;
            var handle: u32 = c.callee_id;
            var name: InternId = .none;
            if (c.callee_is_css) {
                flags |= value_mod.callable_flag_is_css;
                if (c.callee_css_late_sass_resolution) flags |= value_mod.callable_flag_css_late_sass_resolution;
                handle = 0;
                name = c.callee_name;
            } else {
                if (c.callee_capture_callers_locals) flags |= value_mod.callable_flag_capture_callers_locals;
                const callee_mod: u32 = if (c.callee_module == resolver.local_module_id_sentinel) ctx.module_id else c.callee_module;
                name = c.callee_name;
                if (c.callee_module != resolver.local_module_id_sentinel) {
                    flags |= value_mod.callable_flag_has_module;
                    module_bits = try checkedU16(callee_mod, "call callee module");
                }
            }
            const target = try Value.callableMake(handle, flags, module_bits, name, ctx.resolved.value_callable_payload_pool, ctx.cb.shared_pool_alloc);
            const target_idx = try ctx.cb.addConst(target);
            try ctx.cb.emit(.load_const, 0, target_idx);
            var i: u32 = 0;
            while (i < c.arg_count) : (i += 1) {
                const ai = resolved.call_args.items[c.arg_start + i];
                try compileExpr(ctx, ai);
            }
            const meta_idx = try addBuiltinCallMeta(ctx, c.arg_start, c.arg_count, std.math.maxInt(u32));
            try ctx.cb.emit(.call_indirect, 0, meta_idx);
        },
        .builtin_call => {
            const c = resolved.builtin_calls.items[ex.payload];
            if (c.prebound_kind != .none) {
                var flags: u16 = 0;
                if (c.prebound_kind == .mixin) {
                    flags |= value_mod.callable_flag_is_mixin;
                    if (c.prebound_accepts_content) flags |= value_mod.callable_flag_accepts_content;
                }
                if (c.prebound_capture_callers_locals) flags |= value_mod.callable_flag_capture_callers_locals;
                const target_module: u32 = if (c.prebound_module == resolver.local_module_id_sentinel) ctx.module_id else c.prebound_module;
                flags |= value_mod.callable_flag_has_module | value_mod.callable_flag_prebound;
                const module_bits: u16 = try checkedU16(target_module, "prebound module");
                const target = try Value.callableMake(c.prebound_id, flags, module_bits, c.prebound_name, ctx.resolved.value_callable_payload_pool, ctx.cb.shared_pool_alloc);
                const idx = try ctx.cb.addConst(target);
                try ctx.cb.emit(.load_const, 0, idx);
                return;
            }
            if (builtinRejectsSassScriptModulo(c.builtin_id)) {
                var i: u32 = 0;
                while (i < c.arg_count) : (i += 1) {
                    const ai = resolved.call_args.items[c.arg_start + i];
                    if (exprContainsModulo(resolved, ai)) {
                        try emitForcedSassError(ctx);
                        return;
                    }
                }
            }
            if (c.builtin_id == meta_call_builtin_id) {
                const control_idx = findMetaControlArgIndex(ctx, c.arg_start, c.arg_count, "function");
                if (control_idx) |idx| {
                    try compileExpr(ctx, resolved.call_args.items[idx]);
                } else {
                    const nil_idx = try ctx.cb.addConst(Value.nil_v);
                    try ctx.cb.emit(.load_const, 0, nil_idx);
                }
                var forwarded: std.ArrayListUnmanaged(u32) = .empty;
                defer forwarded.deinit(ctx.cb.alloc);
                try appendForwardedMetaArgIndices(ctx, c.arg_start, c.arg_count, control_idx, &forwarded);
                for (forwarded.items) |idx| {
                    try compileExpr(ctx, resolved.call_args.items[idx]);
                }
                const meta_idx = try addBuiltinCallMetaFromIndices(ctx, forwarded.items, std.math.maxInt(u32));
                try ctx.cb.emit(.call_indirect, 0, meta_idx);
                return;
            }
            var i: u32 = 0;
            while (i < c.arg_count) : (i += 1) {
                const ai = resolved.call_args.items[c.arg_start + i];
                try compileExpr(ctx, ai);
            }
            const meta_idx = try addBuiltinCallMeta(ctx, c.arg_start, c.arg_count, remapLocalSlotHint(ctx, c.local_slot_hint));
            try ctx.cb.emit(.call_builtin, try checkedU16(c.builtin_id, "builtin id"), meta_idx);
        },
        .cross_var_ref => {
            const c = resolved.cross_var_refs.items[ex.payload];
            try ctx.cb.emit(.load_mod_global, try checkedU16(c.module_id, "cross var module"), c.slot);
        },
        .if_builtin => {
            const c = resolved.call_exprs.items[ex.payload];
            std.debug.assert(c.arg_count == 3);
            const cond = resolved.call_args.items[c.arg_start];
            const a = resolved.call_args.items[c.arg_start + 1];
            const b = resolved.call_args.items[c.arg_start + 2];

            try compileExpr(ctx, cond);
            const jmp_false = ctx.cb.code.items.len;
            try ctx.cb.emit(.jmp_if_false, 0, 0);
            try compileExpr(ctx, a);
            const jmp_end = ctx.cb.code.items.len;
            try ctx.cb.emit(.jmp, 0, 0);
            const else_pc = ctx.cb.code.items.len;
            ctx.cb.patchJmp(jmp_false, else_pc);
            try compileExpr(ctx, b);
            const end_pc = ctx.cb.code.items.len;
            ctx.cb.patchJmp(jmp_end, end_pc);
        },
        .list => {
            const l = resolved.list_exprs.items[ex.payload];
            var i: u32 = 0;
            while (i < l.elem_count) : (i += 1) {
                const ei = resolved.list_elems.items[l.elem_start + i];
                try compileExpr(ctx, ei);
            }
            const flags: u32 = Value.packListFlagsMetaEx(l.separator, l.bracketed, l.is_map, l.slash_coercible);
            try ctx.cb.emit(.make_list, try checkedU16(l.elem_count, "list element count"), flags);
        },
        .interp => {
            const ip = resolved.interp_exprs.items[ex.payload];
            if (ip.part_count == 0) return error.Unsupported;
            const apply_preserve_empty_seps = ctx.in_loud_comment_text_outer;
            var inner_ctx = ctx;
            inner_ctx.in_loud_comment_text_outer = false;
            if (ip.preserve_quote) {
                const empty_id = try ctx.pool.intern("");
                const quoted_empty_idx = try ctx.cb.addConst(Value.string(empty_id, true));
                try ctx.cb.emit(.load_const, 0, quoted_empty_idx);
            }
            var p: u32 = 0;
            while (p < ip.part_count) : (p += 1) {
                const part = resolved.interp_parts.items[ip.part_start + p];
                const part_ex = exprAt(resolved, part);
                var preserve_calc_slash_text = false;
                if (part_ex.kind == .literal_string) {
                    // literal interval of Interpolation is SVG data URL (`url("...#{x}...")`)
                    // may contain raw data such as, official Sass CLI will not parse it as a value
                    // Pass through. This also does not apply leading-zero normalize.
                    const s = resolver.unpackLiteralStringPayload(part_ex.payload);
                    const raw_lit = ctx.pool.get(s.id);
                    preserve_calc_slash_text = std.mem.indexOf(u8, raw_lit, calc_interp_preserve_start) != null or
                        std.mem.indexOf(u8, raw_lit, calc_interp_marker) != null;
                    const normalized_id = if (preserve_calc_slash_text)
                        s.id
                    else
                        try normalizeLiteralStringIntern(
                            ctx.pool,
                            ctx.cb.alloc,
                            s.id,
                            s.quoted,
                            false,
                        );
                    const val = Value.stringWithFlagsEx(normalized_id, s.quoted, false, s.named_color_literal);
                    const idx = try ctx.cb.addConst(val);
                    try ctx.cb.emit(.load_const, 0, idx);
                } else if (ip.error_on_undeclared_var) {
                    try compileStrictInterpPart(inner_ctx, part);
                } else {
                    try compileExpr(inner_ctx, part);
                }
                if (!preserve_calc_slash_text and !resolver.isDirectSlashListValueExpr(resolved, part)) {
                    try ctx.cb.emit(.coerce_slash_free, 0, 0);
                }
            }
            var make_sel_flags: u32 = makeSelectorInterpFlags(ip) | opcode_mod.make_selector_flag_interpolation_context;
            if (apply_preserve_empty_seps) make_sel_flags |= opcode_mod.make_selector_flag_preserve_empty_separators;
            try ctx.cb.emit(.make_selector, try checkedU16(ip.part_count, "interp part count"), make_sel_flags);
            if (ip.preserve_quote) {
                try ctx.cb.emit(.add, 0, 0);
            }
        },
    }
}

fn compileStrictInterpPart(ctx: CompileCtx, e: ExprIndex) CompileError!void {
    const ex = ctx.resolved.exprs.items[e];
    switch (ex.kind) {
        .var_ref => {
            try ctx.cb.emit(.load_local_strict, 0, remapLocalSlot(ctx, ex.payload));
        },
        .cross_var_ref => {
            const c = ctx.resolved.cross_var_refs.items[ex.payload];
            try ctx.cb.emit(.load_mod_global_strict, try checkedU16(c.module_id, "strict cross var module"), c.slot);
        },
        else => try compileExpr(ctx, e),
    }
}

fn compileDeclValueExpr(ctx: CompileCtx, expr_idx: ExprIndex) CompileError!void {
    const ex = ctx.resolved.exprs.items[expr_idx];
    if (ex.kind != .list) {
        try compileExpr(ctx, expr_idx);
        return;
    }

    const l = ctx.resolved.list_exprs.items[ex.payload];
    var i: u32 = 0;
    while (i < l.elem_count) : (i += 1) {
        const ei = ctx.resolved.list_elems.items[l.elem_start + i];
        try compileExpr(ctx, ei);
        if (!resolver.isDirectSlashListValueExpr(ctx.resolved, ei)) {
            try ctx.cb.emit(.coerce_slash_free, 0, 0);
        }
    }
    const flags: u32 = Value.packListFlagsMetaEx(l.separator, l.bracketed, l.is_map, l.slash_coercible);
    try ctx.cb.emit(.make_list, try checkedU16(l.elem_count, "list element count"), flags);
}

fn compileExprOrNil(ctx: CompileCtx, maybe_e: ?ExprIndex) CompileError!void {
    if (maybe_e) |e| {
        try compileExpr(ctx, e);
    } else {
        const ni = try ctx.cb.addConst(Value.nil_v);
        try ctx.cb.emit(.load_const, 0, ni);
    }
}

fn compileAtRuleBody(
    ctx: CompileCtx,
    name_intern: InternId,
    prelude_expr: ?ExprIndex,
    prelude_override: ?InternId,
    media_flags: u8,
    body_direct: []const StmtIndex,
    had_block: bool,
    skip_media_merge: bool,
) CompileError!void {
    const raw_name = atRuleNameRaw(ctx.pool.get(name_intern));
    var retained_body_direct = body_direct;
    var hoisted_keyframe_at_root_children: std.ArrayListUnmanaged(StmtIndex) = .empty;
    defer hoisted_keyframe_at_root_children.deinit(ctx.cb.alloc);
    var retained_storage: std.ArrayListUnmanaged(StmtIndex) = .empty;
    defer retained_storage.deinit(ctx.cb.alloc);

    if (atRuleIsKeyframes(raw_name) and body_direct.len > 0) {
        try retained_storage.ensureTotalCapacity(ctx.cb.alloc, body_direct.len);
        try hoisted_keyframe_at_root_children.ensureTotalCapacity(ctx.cb.alloc, body_direct.len);
        for (body_direct) |child_si| {
            if (child_si < ctx.resolved.stmts.items.len) {
                const child_st = ctx.resolved.stmts.items[child_si];
                if (child_st.kind == .at_rule and child_st.payload < ctx.resolved.at_rule_stmts.items.len) {
                    const child_ar = ctx.resolved.at_rule_stmts.items[child_st.payload];
                    const child_name = atRuleNameRaw(ctx.pool.get(child_ar.name_intern));
                    if (std.mem.eql(u8, child_name, "at-root") and
                        atRootPreludeIsWithoutAllQuery(ctx.resolved, ctx.pool, child_ar.prelude_expr))
                    {
                        hoisted_keyframe_at_root_children.appendAssumeCapacity(child_si);
                        continue;
                    }
                }
            }
            retained_storage.appendAssumeCapacity(child_si);
        }
        if (hoisted_keyframe_at_root_children.items.len > 0) {
            retained_body_direct = retained_storage.items;
        }
    }

    if (std.mem.eql(u8, raw_name, "media") and retained_body_direct.len == 0 and !had_block) {
        const raw_prelude = if (prelude_override) |override_id| ctx.pool.get(override_id) else staticPreludeText(ctx.resolved, ctx.pool, prelude_expr);
        if (raw_prelude) |raw| {
            if (mediaPreludeStartsOnNewLine(raw) or
                media_prelude.mediaPreludeHasLineBreakBeforeLogicKeyword(raw) or
                media_prelude.mediaPreludeHasLineBreakAfterLogicKeyword(raw))
            {
                try emitSassErrorMessage(ctx, "invalid media query");
                return;
            }
        }
        return;
    }

    if (!skip_media_merge) {
        if (try tryCompileMergedMediaBody(
            ctx,
            name_intern,
            prelude_expr,
            prelude_override,
            media_flags,
            retained_body_direct,
            had_block,
        )) return;
    }

    if (prelude_override) |override_id| {
        const ci = try ctx.cb.addConst(Value.string(override_id, false));
        try ctx.cb.emit(.load_const, 0, ci);
    } else {
        try compileExprOrNil(ctx, prelude_expr);
    }

    try ctx.cb.noteIntern(name_intern);
    var arg_flags = mediaArgFlags(media_flags);
    if (moduleIsPlainCss(ctx)) {
        arg_flags |= opcode_mod.at_rule_flag_plain_css_preserve;
    }
    if (retained_body_direct.len == 0 and !had_block) {
        try ctx.cb.emit(.emit_at_rule_simple, arg_flags, @intFromEnum(name_intern));
        return;
    }

    const keep_empty_flag: u16 = blk: {
        if (!(retained_body_direct.len == 0 and had_block)) break :blk 0;
        const at_rule_name = ctx.pool.get(name_intern);
        break :blk if (shouldPreserveEmptyConditionalAtRule(at_rule_name)) 0x8000 else 0;
    };
    try ctx.cb.emit(.emit_at_rule_begin, keep_empty_flag | arg_flags, @intFromEnum(name_intern));
    const child_ctx = CompileCtx{
        .resolved = ctx.resolved,
        .cb = ctx.cb,
        .module_id = ctx.module_id,
        .modules = ctx.modules,
        .color_pool = ctx.color_pool,
        .pool = ctx.pool,
        .at_rule_depth = ctx.at_rule_depth + 1,
        .has_selector_context = ctx.has_selector_context,
        .in_keyframes_context = ctx.in_keyframes_context or atRuleIsKeyframes(raw_name),
        .emit_comments = ctx.emit_comments,
        .callable_local_slot_base = ctx.callable_local_slot_base,
        .callable_local_slot_bias = ctx.callable_local_slot_bias,
    };
    const clears_parent_selector_context = atRuleClearsParentSelectorContext(raw_name) or
        (std.mem.eql(u8, raw_name, "at-root") and atRootPreludeLooksLikeQuery(ctx.resolved, ctx.pool, prelude_expr));
    if (clears_parent_selector_context) {
        try ctx.cb.emit(.push_at_root_scope, 1, 0);
    }
    if (!moduleIsPlainCss(ctx) and stmtSliceCanUseSimpleSourceOrderLowering(ctx.resolved, retained_body_direct)) {
        try compileCurrentSelectorSourceOrderedMaybe(child_ctx, retained_body_direct);
    } else {
        for (retained_body_direct) |child_si| {
            try compileStmt(child_ctx, child_si);
        }
    }
    if (clears_parent_selector_context) {
        try ctx.cb.emit(.pop_at_root_scope, 0, 0);
    }
    try ctx.cb.emit(.emit_at_rule_end, 0, 0);

    if (hoisted_keyframe_at_root_children.items.len > 0) {
        try ctx.cb.emit(.push_at_root_scope, 1, 0);
        defer ctx.cb.emit(.pop_at_root_scope, 0, 0) catch |err| {
            std.debug.panic("compileAtRuleBody: failed to unwind hoisted keyframe @at-root scope: {s}", .{@errorName(err)});
        };
        for (hoisted_keyframe_at_root_children.items) |child_si| {
            const child_st = ctx.resolved.stmts.items[child_si];
            const child_ar = ctx.resolved.at_rule_stmts.items[child_st.payload];
            for (child_ar.body_direct) |grandchild_si| {
                try compileStmt(ctx, grandchild_si);
            }
        }
    }
}

fn tryCompileMergedMediaBody(
    ctx: CompileCtx,
    name_intern: InternId,
    prelude_expr: ?ExprIndex,
    prelude_override: ?InternId,
    media_flags: u8,
    body_direct: []const StmtIndex,
    had_block: bool,
) CompileError!bool {
    const raw_name = atRuleNameRaw(ctx.pool.get(name_intern));
    if (!std.mem.eql(u8, raw_name, "media")) return false;
    if (moduleIsPlainCss(ctx)) return false;
    if (body_direct.len == 0) return false;

    const parent_prelude = if (prelude_override) |override_id|
        ctx.pool.get(override_id)
    else
        staticPreludeText(ctx.resolved, ctx.pool, prelude_expr) orelse return false;

    var retained: std.ArrayListUnmanaged(StmtIndex) = .empty;
    defer retained.deinit(ctx.cb.alloc);
    try retained.ensureTotalCapacity(ctx.cb.alloc, body_direct.len);
    var changed = false;
    var merge_arena = std.heap.ArenaAllocator.init(ctx.cb.alloc);
    defer merge_arena.deinit();

    for (body_direct) |child_si| {
        _ = merge_arena.reset(.retain_capacity);
        const merge_alloc = merge_arena.allocator();
        if (child_si >= ctx.resolved.stmts.items.len) {
            retained.appendAssumeCapacity(child_si);
            continue;
        }
        const child_st = ctx.resolved.stmts.items[child_si];
        if (child_st.kind != .at_rule or child_st.payload >= ctx.resolved.at_rule_stmts.items.len) {
            retained.appendAssumeCapacity(child_si);
            continue;
        }

        const child_ar = ctx.resolved.at_rule_stmts.items[child_st.payload];
        if (!std.mem.eql(u8, atRuleNameRaw(ctx.pool.get(child_ar.name_intern)), "media")) {
            retained.appendAssumeCapacity(child_si);
            continue;
        }

        const child_prelude = staticPreludeText(ctx.resolved, ctx.pool, child_ar.prelude_expr) orelse {
            retained.appendAssumeCapacity(child_si);
            continue;
        };

        const merge_result = try media_prelude.mergeMediaQueryLists(merge_alloc, parent_prelude, child_prelude);

        if (merge_result) |merged| {
            if (merged.ptr == media_prelude.MEDIA_MERGE_UNRESOLVABLE.ptr) {
                retained.appendAssumeCapacity(child_si);
                continue;
            }
            changed = true;

            if (retained.items.len > 0) {
                try compileAtRuleBody(
                    ctx,
                    name_intern,
                    prelude_expr,
                    prelude_override,
                    media_flags,
                    retained.items,
                    had_block,
                    true,
                );
                retained.items.len = 0;
            }

            const merged_id = try ctx.pool.intern(merged);
            try compileAtRuleBody(
                ctx,
                child_ar.name_intern,
                child_ar.prelude_expr,
                merged_id,
                media_flags | child_ar.media_flags,
                child_ar.body_direct,
                child_ar.had_block,
                false,
            );
        } else {
            changed = true;
            // Empty intersection: drop only the child branch.
        }
    }

    if (!changed) return false;
    if (retained.items.len > 0) {
        try compileAtRuleBody(
            ctx,
            name_intern,
            prelude_expr,
            prelude_override,
            media_flags,
            retained.items,
            had_block,
            true,
        );
    }
    return true;
}

fn tryCompileMergedMediaAtRule(ctx: CompileCtx, ar: anytype) CompileError!bool {
    return try tryCompileMergedMediaBody(
        ctx,
        ar.name_intern,
        ar.prelude_expr,
        null,
        ar.media_flags,
        ar.body_direct,
        ar.had_block,
    );
}

fn ruleCanCompileAsPropertyNamespace(resolved: *const ResolvedProgram, si: StmtIndex) bool {
    if (si >= resolved.stmts.items.len) return false;
    const st = resolved.stmts.items[si];
    if (st.kind != .rule) return false;
    if (st.payload >= resolved.rule_stmts.items.len) return false;
    const r = resolved.rule_stmts.items[st.payload];
    if (r.prop_namespace_prefix_expr == null) return false;
    if (r.is_placeholder) return false;
    return true;
}

fn compilePropertyNamespaceRule(ctx: CompileCtx, si: StmtIndex) CompileError!void {
    const resolved = ctx.resolved;
    const st = resolved.stmts.items[si];
    const rule = resolved.rule_stmts.items[st.payload];
    const prefix_expr = rule.prop_namespace_prefix_expr orelse return error.Unsupported;

    const prev_span = ctx.cb.current_span;
    defer ctx.cb.current_span = prev_span;
    ctx.cb.setSourceSpan(st.span);

    if (rule.prop_namespace_value_expr) |base_expr| {
        try compileExpr(ctx, prefix_expr);
        try compileExpr(ctx, base_expr);
        try ctx.cb.emit(.emit_decl_dynamic, 0, 0);
    }

    try compileExpr(ctx, prefix_expr);
    try ctx.cb.emit(.push_prop_namespace, 0, 0);
    for (rule.body_direct) |child_si| {
        try compileStmt(ctx, child_si);
    }
    try ctx.cb.emit(.pop_prop_namespace, 0, 0);
}

fn compileStmt(ctx: CompileCtx, si: StmtIndex) CompileError!void {
    const resolved = ctx.resolved;
    const st = resolved.stmts.items[si];
    if (st.origin_id.isValid()) {
        const import_base: u32 = @intCast(ctx.modules.len + 1);
        const local_import_id: u32 = @intFromEnum(st.origin_id);
        ctx.cb.current_origin = @enumFromInt(import_base + local_import_id);
    } else {
        ctx.cb.current_origin = @enumFromInt(ctx.module_id + 1);
    }
    const prev_span = ctx.cb.current_span;
    defer ctx.cb.current_span = prev_span;
    ctx.cb.setSourceSpan(st.span);
    switch (st.kind) {
        .noop => {},
        .comment => {
            if (!ctx.emit_comments) return;
            const c = resolved.comment_stmts.items[st.payload];
            // Put the `/*` source column (AST source standard) calculated by the resolver into arg_a.
            // Used in determining the dedent width of loud comment continuation lines (rule_ir emitCommentNode).
            // Situation where module_id of compile chunk and actual file differ with @import inline
            // (for example, a root stylesheet importing a partial),
            // `sourceOffsetToLineCol(source_file_id, source_start)` returns wrong col
            // Defenses for. truncate to u15 (32767) and set bit 15 to leading_same_line
            // Reserved for the resolver-calculated leading_same_line flag.
            const col_raw: u32 = c.source_col;
            const col_trunc: u16 = if (col_raw <= 0x7FFF)
                @intCast(col_raw)
            else
                0x7FFF;
            const leading_bit: u16 = if (c.leading_same_line) 0x8000 else 0;
            const col_arg: u16 = col_trunc | leading_bit;
            if (c.text_expr) |expr_idx| {
                var comment_ctx = ctx;
                comment_ctx.in_loud_comment_text_outer = true;
                try compileExpr(comment_ctx, expr_idx);
                try ctx.cb.emit(.emit_comment_dynamic, col_arg, 0);
            } else {
                try ctx.cb.noteIntern(c.text_intern);
                try ctx.cb.emit(.emit_comment, col_arg, @intFromEnum(c.text_intern));
            }
        },
        .module_dep => {
            const dep = resolved.module_dep_stmts.items[st.payload];
            // arg_b bit 0: rerun_each_call, bit 1: is_forward
            // A dependency reached through @forward is module-universal with
            // its preceding loud comment, so replay it on the second visit. A
            // dependency reached through @use remains module-local and is not
            // replayed.
            var arg_b: u16 = if (dep.rerun_each_call) @as(u16, 1) else 0;
            if (dep.is_forward) arg_b |= 0b10;
            try ctx.cb.emit(.run_dependency, try checkedU16(dep.module_id, "dependency module"), arg_b);
        },
        .declaration => {
            const d = resolved.decl_stmts.items[st.payload];
            switch (d.prop_kind) {
                .literal => {
                    const prop_name = ctx.pool.get(d.prop_intern);
                    if (std.mem.startsWith(u8, prop_name, "--")) {
                        if (d.raw_value_source_intern != .none) {
                            const raw_const = try ctx.cb.addConst(Value.string(d.raw_value_source_intern, false));
                            var raw_flags: u16 = 0;
                            if ((d.emit_decl_flags & opcode_mod.emit_decl_flag_custom_property_leading_space) != 0) {
                                raw_flags |= opcode_mod.emit_raw_decl_flag_custom_property_leading_space;
                            }
                            try ctx.cb.noteIntern(d.prop_intern);
                            try ctx.cb.emit(.load_const, 0, raw_const);
                            try ctx.cb.emit(.emit_raw_decl, raw_flags, @intFromEnum(d.prop_intern));
                            return;
                        }
                        if (staticLiteralStringPayload(resolved, d.value_expr)) |payload| {
                            const lit = resolver.unpackLiteralStringPayload(payload);
                            if (!lit.quoted) {
                                const raw_const = try ctx.cb.addConst(Value.string(lit.id, false));
                                var raw_flags: u16 = 0;
                                if ((d.emit_decl_flags & opcode_mod.emit_decl_flag_custom_property_leading_space) != 0) {
                                    raw_flags |= opcode_mod.emit_raw_decl_flag_custom_property_leading_space;
                                }
                                try ctx.cb.noteIntern(d.prop_intern);
                                try ctx.cb.emit(.load_const, 0, raw_const);
                                try ctx.cb.emit(.emit_raw_decl, raw_flags, @intFromEnum(d.prop_intern));
                                return;
                            }
                        }
                    }
                    if (try tryCompileDeclSpaceListRawBypass(ctx, d.prop_intern, d.value_expr)) return;
                    try compileDeclValueExpr(ctx, d.value_expr);
                    try ctx.cb.noteIntern(d.prop_intern);
                    const raw_info = shouldEmitRawDeclForValueInfo(resolved, ctx.pool, d.value_expr);
                    if (raw_info.enabled) {
                        // Pure literals strip source `/* */`; interpolation
                        // preserves the authored comment text.
                        var flag: u16 = if (!raw_info.has_interp) opcode_mod.emit_raw_decl_flag_strip_source_comments else 0;
                        if (raw_info.has_interp) flag |= opcode_mod.emit_raw_decl_flag_value_has_interp;
                        if ((d.emit_decl_flags & opcode_mod.emit_decl_flag_custom_property_leading_space) != 0) {
                            flag |= opcode_mod.emit_raw_decl_flag_custom_property_leading_space;
                        }
                        try ctx.cb.emit(.emit_raw_decl, flag, @intFromEnum(d.prop_intern));
                        return;
                    }
                    // `arg_a = 1` tells the VM to preserve a slash list value
                    // at the declaration boundary (for direct literals like
                    // `a {b: 1/2}`). Indirect slash values (via function
                    // return / variable ref) still coerce to division.
                    var emit_decl_flags = d.emit_decl_flags;
                    if (resolver.isDirectSlashListValueExpr(resolved, d.value_expr)) {
                        emit_decl_flags |= opcode_mod.emit_decl_flag_preserve_slash;
                    }
                    // If there is no interpolation in the value subtree, source
                    // `/* */` comments are plain CSS comments and may be stripped.
                    if (!exprContainsInterp(resolved, d.value_expr)) {
                        emit_decl_flags |= opcode_mod.emit_decl_flag_strip_source_comments;
                    } else {
                        emit_decl_flags |= opcode_mod.emit_decl_flag_value_has_interp;
                    }
                    // If the source file is `.css` (plain CSS), nested calc literals
                    // are simplified at VM stage. From SCSS source, runtime-built
                    // nested calc values are preserved.
                    if (moduleIsPlainCss(ctx)) {
                        emit_decl_flags |= opcode_mod.emit_decl_flag_plain_css_origin;
                    }
                    try ctx.cb.emit(.emit_decl, emit_decl_flags, @intFromEnum(d.prop_intern));
                },
                .dynamic => {
                    var is_custom_prop = false;
                    if (d.prop_parts_count > 0) {
                        const first_ei = resolved.decl_prop_part_exprs.items[d.prop_parts_start];
                        const first_ex = resolved.exprs.items[first_ei];
                        if (first_ex.kind == .literal_string) {
                            const s = resolver.unpackLiteralStringPayload(first_ex.payload);
                            const text = ctx.pool.get(s.id);
                            if (std.mem.startsWith(u8, text, "--")) is_custom_prop = true;
                        }
                    }
                    var pi: u32 = 0;
                    while (pi < d.prop_parts_count) : (pi += 1) {
                        const ei = resolved.decl_prop_part_exprs.items[d.prop_parts_start + pi];
                        try compileExpr(ctx, ei);
                    }
                    try ctx.cb.emit(.make_selector, try checkedU16(d.prop_parts_count, "decl prop parts"), 0);
                    if (is_custom_prop) {
                        var custom_ctx = ctx;
                        custom_ctx.skip_decimal_normalize = true;
                        try compileDeclValueExpr(custom_ctx, d.value_expr);
                    } else {
                        try compileDeclValueExpr(ctx, d.value_expr);
                    }
                    try ctx.cb.emit(.emit_decl_dynamic, d.emit_decl_flags, 0);
                },
            }
        },
        .at_rule => {
            const ar = resolved.at_rule_stmts.items[st.payload];
            if (!ar.is_plain_css and try tryCompileMergedMediaAtRule(ctx, ar)) return;
            if (try tryCompileFilteredAtRoot(ctx, ar)) return;
            if (try tryCompileHoistedAtRoot(ctx, ar)) return;
            try compileAtRuleBody(ctx, ar.name_intern, ar.prelude_expr, null, ar.media_flags, ar.body_direct, ar.had_block, false);
        },
        .rule => {
            const r = effectiveRuleDataForCompile(ctx, resolved.rule_stmts.items[st.payload]);
            const is_keyframe_selector_rule = ctx.in_keyframes_context and ctx.keyframe_block_depth == 0;
            if (ctx.in_keyframes_context and ctx.keyframe_block_depth > 0) {
                try emitSassErrorMessage(ctx, "Style rules may not be used within keyframe blocks.");
                return;
            }
            if (r.is_plain_css) {
                try compilePlainCssRule(ctx, r);
                return;
            }
            if (ruleCanCompileAsPropertyNamespace(resolved, si)) {
                try compilePropertyNamespaceRule(ctx, si);
                return;
            }
            var use_push_only = ruleUsesPushOnlyOuter(resolved, ctx.modules, ctx.pool, ctx.module_id, r);
            if (is_keyframe_selector_rule) use_push_only = false;
            if (!is_keyframe_selector_rule and ruleCanUseSimpleSourceOrderLowering(resolved, r)) {
                if (use_push_only or stmtSliceHasDirectContentCall(resolved, r.body_direct)) {
                    try compileRuleSourceOrderedMaybe(ctx, r);
                } else {
                    try compileRuleSourceOrdered(ctx, r);
                }
                return;
            }
            var inner_ctx = selectorContextChildCtx(ctx);
            if (is_keyframe_selector_rule) inner_ctx.keyframe_block_depth += 1;
            // nest_depth (for blank insertion) is determined by the VM at runtime from the `selector_stack` depth, so
            // arg_a is fixed to 0 on the compile side.
            switch (r.selector_kind) {
                .literal => {
                    const selector_intern = if (is_keyframe_selector_rule)
                        try normalizeKeyframeSelectorIntern(ctx.pool, ctx.cb.alloc, r.literal_intern)
                    else
                        r.literal_intern;
                    try ctx.cb.noteIntern(selector_intern);
                    if (use_push_only) {
                        try ctx.cb.emit(.push_selector_scope, 0, @intFromEnum(selector_intern));
                    } else {
                        try ctx.cb.emit(.emit_rule_begin, 0, @intFromEnum(selector_intern));
                    }
                },
                .dynamic => {
                    var pi: u32 = 0;
                    while (pi < r.dynamic_parts_count) : (pi += 1) {
                        const ei = resolved.selector_part_exprs.items[r.dynamic_parts_start + pi];
                        try compileExpr(ctx, ei);
                    }
                    try ctx.cb.emit(.make_selector, try checkedU16(r.dynamic_parts_count, "rule dynamic parts"), 0);
                    if (use_push_only) {
                        try ctx.cb.emit(.push_selector_scope_dynamic, 0, 0);
                    } else {
                        try ctx.cb.emit(.emit_rule_begin_dynamic, 0, 0);
                    }
                },
            }
            const opened_rule_block = !use_push_only;
            const body_direct = try sortedStmtIndicesBySource(ctx.cb.alloc, resolved, r.body_direct);
            defer ctx.cb.alloc.free(body_direct);
            var outer_rule_closed = false;
            // Properties and @includes in source order. Close parent `{...}` only before mixins that contain nests
            //(`.col { grid; @include wrap }`  ->  put only grid in `.col` block).
            var mixin_closed_outer_block = false;
            var have_decl_in_open_block = false;
            // Determine whether there is an "element that should be output after closing the parent block" on the second pass side using shape analysis.
            // Example: `.sm-l1 { @if { padding } }` does not require close, `.a { color:red; @for ... { .b {...} } }` requires close.
            var second_pass_closes_after_decls = false;
            for (body_direct) |child_si| {
                const child_stays_in_open =
                    ruleChildStaysInOpenBlock(ctx.modules, ctx.pool, resolved, ctx.module_id, child_si) or
                    (is_keyframe_selector_rule and atRuleStmtIsMedia(resolved, ctx.pool, child_si));
                if (child_stays_in_open) continue;
                if (resolved.stmts.items[child_si].kind == .comment) continue;
                const shape = analyzeStmtShape(ctx.modules, ctx.pool, resolved, ctx.module_id, child_si, no_content_analysis, 0);
                if (shape.needs_mid_close) {
                    second_pass_closes_after_decls = true;
                    break;
                }
            }
            var saw_true_second_pass_stmt = false;
            var defer_open_block_children_after_leading_second_pass = false;
            for (body_direct) |child_si| {
                const ch = resolved.stmts.items[child_si];
                const child_is_prop_ns = ruleCanCompileAsPropertyNamespace(resolved, child_si);
                const comment_belongs_to_open_block = ch.kind == .comment and !saw_true_second_pass_stmt;
                const child_stays_in_open =
                    ruleChildStaysInOpenBlock(ctx.modules, ctx.pool, resolved, ctx.module_id, child_si) or
                    (is_keyframe_selector_rule and atRuleStmtIsMedia(resolved, ctx.pool, child_si));
                if (child_stays_in_open or comment_belongs_to_open_block) {
                    if (child_is_prop_ns) {
                        try compilePropertyNamespaceRule(inner_ctx, child_si);
                        have_decl_in_open_block = true;
                    } else if (ch.kind == .declaration) {
                        // If a rule starts with a nested second-pass construct and
                        // only then emits declarations, official Sass CLI keeps the nested
                        // rule before the later declarations. The same source-order
                        // split applies after a mixin has already closed/reopened the
                        // outer block: nested rules that occur before later
                        // declarations must stay before those declarations.
                        if (!defer_open_block_children_after_leading_second_pass and
                            !saw_true_second_pass_stmt)
                        {
                            try compileStmt(inner_ctx, child_si);
                            have_decl_in_open_block = true;
                        }
                    } else if (ch.kind == .comment) {
                        try compileStmt(inner_ctx, child_si);
                        have_decl_in_open_block = true;
                    } else if (ch.kind == .content_call) {
                        mixin_closed_outer_block = true;
                        if (have_decl_in_open_block) {
                            try inner_ctx.cb.emit(.emit_rule_end, 0, 0);
                            have_decl_in_open_block = false;
                            outer_rule_closed = true;
                        }
                        try compileStmt(inner_ctx, child_si);
                        have_decl_in_open_block = true;
                    } else if (ch.kind == .assign_var or ch.kind == .noop) {
                        // assign_var that appears after a true-second-pass stmt
                        // (e.g. nested rule / @while that contains nested rules)
                        // must execute in source order at runtime, so defer it
                        // to the second pass. Otherwise `$i: 99` reordered in
                        // front of earlier rule emits reads the wrong value.
                        if (ch.kind == .assign_var and saw_true_second_pass_stmt) {
                            // skip in first pass; second pass will emit it
                        } else {
                            try compileStmt(inner_ctx, child_si);
                        }
                    } else if (ch.kind == .module_dep) {
                        // run_dependency must execute before subsequent decls
                        // can call upstream functions or read upstream vars.
                        // Upstream's body may emit nested rules at the @import
                        // location (the VM auto-closes/reopens parent via
                        // selector_stack); slot init happens regardless.
                        try compileStmt(inner_ctx, child_si);
                    } else if (ch.kind == .rule) {
                        try compileStmt(inner_ctx, child_si);
                        have_decl_in_open_block = true;
                    } else if (ch.kind == .at_rule) {
                        try compileStmt(inner_ctx, child_si);
                        have_decl_in_open_block = true;
                    } else if (ch.kind == .if_chain or ch.kind == .for_loop or ch.kind == .each_loop or ch.kind == .while_loop) {
                        const shape = analyzeStmtShape(ctx.modules, ctx.pool, resolved, ctx.module_id, child_si, no_content_analysis, 0);
                        if (saw_true_second_pass_stmt) {
                            // skip in first pass; second pass will emit it
                        } else {
                            try compileStmt(inner_ctx, child_si);
                            if (shape.may_emit_decl) have_decl_in_open_block = true;
                        }
                    } else {
                        const inc = resolved.include_stmts.items[ch.payload];
                        const inc_analysis = analyzeIncludeCall(
                            ctx.modules,
                            resolved,
                            ctx.pool,
                            ctx.module_id,
                            inc.callee_module,
                            inc.mixin_id,
                            inc.arg_start,
                            inc.arg_count,
                            inc.content_block,
                            no_content_analysis,
                            0,
                        );
                        if (saw_true_second_pass_stmt and
                            (inc_analysis.may_emit_decl or inc_analysis.needs_mid_close))
                        {
                            // Defer to second pass to preserve source order
                            // with preceding nested rules/at-rules/control flow that
                            // also need mid-close. A mixin that emits only bubbled
                            // at-rules may not emit declarations directly, but it
                            // still produces CSS outside the open parent block and
                            // must not leap ahead of an earlier second-pass stmt.
                        } else {
                            if (inc_analysis.needs_mid_close) {
                                mixin_closed_outer_block = true;
                                if (have_decl_in_open_block) {
                                    try inner_ctx.cb.emit(.emit_rule_end, 0, 0);
                                    have_decl_in_open_block = false;
                                    outer_rule_closed = true;
                                }
                            }
                            try compileStmt(inner_ctx, child_si);
                            // Since include can issue a declaration, it is assumed that there is an unflushed declaration in the outer block.
                            // Actual `}` insertion is determined at the later stage (second pass boundary/end).
                            if (inc_analysis.may_emit_decl) {
                                have_decl_in_open_block = true;
                            }
                        }
                    }
                } else {
                    const shape = analyzeStmtShape(ctx.modules, ctx.pool, resolved, ctx.module_id, child_si, no_content_analysis, 0);
                    if (!saw_true_second_pass_stmt and !have_decl_in_open_block and shape.needs_mid_close) {
                        defer_open_block_children_after_leading_second_pass = true;
                    }
                    saw_true_second_pass_stmt = true;
                }
            }
            if (!mixin_closed_outer_block) {
                if (second_pass_closes_after_decls) {
                    if (have_decl_in_open_block) {
                        try inner_ctx.cb.emit(.emit_rule_end, 0, 0);
                    } else {
                        try inner_ctx.cb.emit(.emit_rule_end_if_open, 0, 0);
                    }
                    have_decl_in_open_block = false;
                    outer_rule_closed = true;
                }
            } else if (have_decl_in_open_block) {
                // mixin_closed_outer_block=true inside include/content_call
                // Situation where `emit_rule_end_if_open` has already closed outer. may_emit_decl
                // Even if you set have_decl_in_open_block=true because of this, subsequent decl/include
                // outer remains closed unless parent is reopened, leaving plain emit_rule_end
                // yields `rule_end span=0..0` twice.
                // Relax to "close if open", flush if reopened, otherwise no-op.
                try inner_ctx.cb.emit(.emit_rule_end_if_open, 0, 0);
                outer_rule_closed = true;
            }
            var prev_in_second_pass: ?StmtKind = null;
            var prev_second_pass_may_emit_decl = false;
            var saw_second_pass_stmt = false;
            for (body_direct) |child_si| {
                const child_stays_in_open =
                    ruleChildStaysInOpenBlock(ctx.modules, ctx.pool, resolved, ctx.module_id, child_si) or
                    (is_keyframe_selector_rule and atRuleStmtIsMedia(resolved, ctx.pool, child_si));
                const ch = resolved.stmts.items[child_si];
                // assign_var / non-emitting control flow deferred from first pass
                // (once we saw a true second-pass stmt in source) must be emitted
                // here in source order so subsequent rule emits read the right
                // variable value.
                const deferred_include_after_second_pass = ch.kind == .include and
                    ch.payload < resolved.include_stmts.items.len and
                    blk: {
                        const inc = resolved.include_stmts.items[ch.payload];
                        const analysis = analyzeIncludeCall(
                            ctx.modules,
                            resolved,
                            ctx.pool,
                            ctx.module_id,
                            inc.callee_module,
                            inc.mixin_id,
                            inc.arg_start,
                            inc.arg_count,
                            inc.content_block,
                            no_content_analysis,
                            0,
                        );
                        break :blk analysis.may_emit_decl or analysis.needs_mid_close;
                    };
                const deferred_stmt = child_stays_in_open and saw_second_pass_stmt and (ch.kind == .declaration or
                    ch.kind == .assign_var or
                    ch.kind == .if_chain or
                    ch.kind == .for_loop or
                    ch.kind == .each_loop or
                    ch.kind == .while_loop or
                    deferred_include_after_second_pass);
                if (child_stays_in_open and !deferred_stmt) continue;
                if (ch.kind == .comment and !saw_second_pass_stmt) continue;
                // If there is `&.active` immediately after `@if { padding }` like in `group`, dart closes the block with only padding and then creates another rule.
                if (prev_in_second_pass == .if_chain and prev_second_pass_may_emit_decl and ch.kind == .rule) {
                    try inner_ctx.cb.emit(.emit_rule_end, 0, 0);
                    outer_rule_closed = true;
                }
                const ch_shape = switch (ch.kind) {
                    .if_chain, .for_loop, .each_loop, .while_loop => analyzeStmtShape(ctx.modules, ctx.pool, resolved, ctx.module_id, child_si, no_content_analysis, 0),
                    else => MixinAnalysis{
                        .may_emit_decl = false,
                        .needs_mid_close = false,
                    },
                };
                const is_control_flow = ch.kind == .if_chain or ch.kind == .for_loop or ch.kind == .each_loop or ch.kind == .while_loop;
                if (deferred_stmt and is_control_flow and ch_shape.may_emit_decl) {
                    try inner_ctx.cb.emit(.emit_rule_begin_current_maybe, 1, 0);
                    try compileStmt(inner_ctx, child_si);
                    try inner_ctx.cb.emit(.emit_rule_end_maybe, 0, 0);
                } else {
                    try compileStmt(inner_ctx, child_si);
                }
                if (ch.kind != .comment) saw_second_pass_stmt = true;
                prev_in_second_pass = ch.kind;
                prev_second_pass_may_emit_decl = ch_shape.may_emit_decl;
            }
            if (opened_rule_block and !outer_rule_closed) {
                // in @if/loop branch by `compileStmtRangeHoistNested`
                // emit_rule_end_if_open is fired and the outer block may have already been closed.
                // Use _if_open to avoid double close (close if block is open, no-op if it is closed).
                try inner_ctx.cb.emit(.emit_rule_end_if_open, 0, 0);
            }
            try inner_ctx.cb.emit(.pop_rule_scope, 0, 0);
        },
        .if_chain => {
            const ifs = resolved.if_stmts.items[st.payload];
            const branches = resolved.if_branches.items[ifs.branches_start..][0..ifs.branches_count];
            var end_jmps: std.ArrayListUnmanaged(usize) = .empty;
            defer end_jmps.deinit(ctx.cb.alloc);
            if (branches.len > 1) {
                try end_jmps.ensureTotalCapacity(ctx.cb.alloc, branches.len - 1);
            }

            var pending_false: ?usize = null;
            for (branches, 0..) |br, bi| {
                if (br.cond_expr) |ce| {
                    if (pending_false) |p| {
                        ctx.cb.patchJmp(p, ctx.cb.code.items.len);
                        pending_false = null;
                    }
                    try compileExpr(ctx, ce);
                    const jf = ctx.cb.code.items.len;
                    try ctx.cb.emit(.jmp_if_false, 0, 0);
                    pending_false = jf;
                } else {
                    if (pending_false) |p| {
                        ctx.cb.patchJmp(p, ctx.cb.code.items.len);
                        pending_false = null;
                    }
                }

                try ctx.cb.emit(.push_flow_scope, 0, 0);
                try compileStmtRangeHoistNested(ctx, br.body_start, br.body_len);
                try ctx.cb.emit(.pop_flow_scope, 0, 0);

                if (br.cond_expr != null and bi + 1 < branches.len) {
                    const je = ctx.cb.code.items.len;
                    try ctx.cb.emit(.jmp, 0, 0);
                    end_jmps.appendAssumeCapacity(je);
                }
            }
            if (pending_false) |p| {
                ctx.cb.patchJmp(p, ctx.cb.code.items.len);
            }
            const end_pc = ctx.cb.code.items.len;
            for (end_jmps.items) |jmp_pc| {
                ctx.cb.patchJmp(jmp_pc, end_pc);
            }
        },
        .for_loop => {
            const f = resolved.for_stmts.items[st.payload];
            try compileExpr(ctx, f.from_expr);
            try ctx.cb.emit(.store_local, 0, remapLocalSlot(ctx, f.cursor_slot));
            try compileExpr(ctx, f.to_expr);
            try ctx.cb.emit(.store_local, 0, remapLocalSlot(ctx, f.to_slot));

            // Fix loop direction to initial value:
            //   from <= to -> +1, from > to -> -1
            try ctx.cb.emit(.load_local, 0, remapLocalSlot(ctx, f.cursor_slot));
            try ctx.cb.emit(.load_local, 0, remapLocalSlot(ctx, f.to_slot));
            try ctx.cb.emit(.le, 0, 0);
            const j_desc_init = ctx.cb.code.items.len;
            try ctx.cb.emit(.jmp_if_false, 0, 0);
            const plus_one = try ctx.cb.addConst(Value.numberUnitless(1));
            try ctx.cb.emit(.load_const, 0, plus_one);
            try ctx.cb.emit(.store_local, 0, remapLocalSlot(ctx, f.step_slot));
            const j_init_done = ctx.cb.code.items.len;
            try ctx.cb.emit(.jmp, 0, 0);
            const desc_init_pc = ctx.cb.code.items.len;
            ctx.cb.patchJmp(j_desc_init, desc_init_pc);
            const minus_one = try ctx.cb.addConst(Value.numberUnitless(-1));
            try ctx.cb.emit(.load_const, 0, minus_one);
            try ctx.cb.emit(.store_local, 0, remapLocalSlot(ctx, f.step_slot));
            const init_done_pc = ctx.cb.code.items.len;
            ctx.cb.patchJmp(j_init_done, init_done_pc);

            // Push once before the condition head so the loop body has a single
            // flow scope spanning all iterations. Previously the push lived
            // inside the body, producing N pushes vs 1 pop and leaking
            // orphan scopes onto flow_scope_stack that corrupted later
            // top-chunk pop_flow_scope ops (docs.scss FAIL).
            try ctx.cb.emit(.push_flow_scope, 0, 0);

            const head_pc = ctx.cb.code.items.len;
            // Switch the termination condition according to direction (+1 / -1).
            // step > 0: through ? i <= to : i < to
            // step < 0: through ? i >= to : i > to
            const zero = try ctx.cb.addConst(Value.numberUnitless(0));
            try ctx.cb.emit(.load_local, 0, remapLocalSlot(ctx, f.step_slot));
            try ctx.cb.emit(.load_const, 0, zero);
            try ctx.cb.emit(.gt, 0, 0);
            const j_desc_cond = ctx.cb.code.items.len;
            try ctx.cb.emit(.jmp_if_false, 0, 0);

            // ascending cond
            try ctx.cb.emit(.load_local, 0, remapLocalSlot(ctx, f.cursor_slot));
            try ctx.cb.emit(.load_local, 0, remapLocalSlot(ctx, f.to_slot));
            if (f.through) try ctx.cb.emit(.le, 0, 0) else try ctx.cb.emit(.lt, 0, 0);
            const j_cond_done = ctx.cb.code.items.len;
            try ctx.cb.emit(.jmp, 0, 0);

            // descending cond
            const desc_cond_pc = ctx.cb.code.items.len;
            ctx.cb.patchJmp(j_desc_cond, desc_cond_pc);
            try ctx.cb.emit(.load_local, 0, remapLocalSlot(ctx, f.cursor_slot));
            try ctx.cb.emit(.load_local, 0, remapLocalSlot(ctx, f.to_slot));
            if (f.through) try ctx.cb.emit(.ge, 0, 0) else try ctx.cb.emit(.gt, 0, 0);

            const cond_done_pc = ctx.cb.code.items.len;
            ctx.cb.patchJmp(j_cond_done, cond_done_pc);
            const j_end = ctx.cb.code.items.len;
            try ctx.cb.emit(.jmp_if_false, 0, 0);
            try ctx.cb.emit(.load_local, 0, remapLocalSlot(ctx, f.cursor_slot));
            try ctx.cb.emit(.store_local, 0, remapLocalSlot(ctx, f.slot));
            // Top-level direct loop leaves stmt_gap marker for each iter (first time has_output=false
            // treats the writer as no-op, and inserts a blank from the second time onwards). The loop inside the rule body is hoisted
            // Do not include as it will generate a nested rule.
            // Place marker at the beginning of each iter. When the VM looks at the `selector_stack` depth at runtime,
            //Actually loaded into rule_ir only in top-level context (depth 0).
            try ctx.cb.emit(.emit_stmt_gap, 0, 0);
            try compileStmtRange(ctx, f.body_start, f.body_len);
            try ctx.cb.emit(.load_local, 0, remapLocalSlot(ctx, f.cursor_slot));
            try ctx.cb.emit(.load_local, 0, remapLocalSlot(ctx, f.step_slot));
            try ctx.cb.emit(.add, 0, 0);
            try ctx.cb.emit(.store_local, 0, remapLocalSlot(ctx, f.cursor_slot));
            const j_back = ctx.cb.code.items.len;
            try ctx.cb.emit(.jmp, 0, 0);
            const pop_pc = ctx.cb.code.items.len;
            try ctx.cb.emit(.pop_flow_scope, 0, 0);
            // Return synthetic iter holders and exposed loop variables to undeclared.
            // Otherwise a later read in the same lexical hierarchy can observe
            // stale cursor bounds after the flow scope closes.
            try ctx.cb.emit(.clear_local, 0, remapLocalSlot(ctx, f.cursor_slot));
            try ctx.cb.emit(.clear_local, 0, remapLocalSlot(ctx, f.to_slot));
            try ctx.cb.emit(.clear_local, 0, remapLocalSlot(ctx, f.step_slot));
            try ctx.cb.emit(.clear_local, 0, remapLocalSlot(ctx, f.slot));
            ctx.cb.patchJmp(j_end, pop_pc);
            ctx.cb.patchJmp(j_back, head_pc);
        },
        .each_loop => {
            const e = resolved.each_stmts.items[st.payload];
            // Space / comma list both iterate over the "elements of the outer list" (isomorphic to for-loop).
            try compileExpr(ctx, e.list_expr);
            try ctx.cb.emit(.store_local, 0, remapLocalSlot(ctx, e.list_temp_slot));
            const zc = try ctx.cb.addConst(Value.numberUnitless(0));
            try ctx.cb.emit(.load_const, 0, zc);
            try ctx.cb.emit(.store_local, 0, remapLocalSlot(ctx, e.index_slot));

            // Push once before the head so iterations share a single scope
            // matched by a single pop at exit (see @for comment above).
            try ctx.cb.emit(.push_flow_scope, 0, 0);

            const head_pc = ctx.cb.code.items.len;
            try ctx.cb.emit(.load_local, 0, remapLocalSlot(ctx, e.index_slot));
            try ctx.cb.emit(.load_local, 0, remapLocalSlot(ctx, e.list_temp_slot));
            const row_arity: u16 = if (e.slot_count > 1) try checkedU16(e.slot_count, "each row arity") else 0;
            try ctx.cb.emit(.list_len, row_arity, 0);
            try ctx.cb.emit(.lt, 0, 0);
            const j_end = ctx.cb.code.items.len;
            try ctx.cb.emit(.jmp_if_false, 0, 0);

            try ctx.cb.emit(.load_local, 0, remapLocalSlot(ctx, e.list_temp_slot));
            try ctx.cb.emit(.load_local, 0, remapLocalSlot(ctx, e.index_slot));
            try ctx.cb.emit(.list_item, row_arity, 0);

            if (e.slot_count == 1) {
                try ctx.cb.emit(.store_local, 0, remapLocalSlot(ctx, resolved.each_slots.items[e.slot_start]));
            } else {
                try ctx.cb.emit(.unpack, try checkedU16(e.slot_count, "each slot count"), 0);
                var uj: u32 = e.slot_count;
                while (uj > 0) {
                    uj -= 1;
                    try ctx.cb.emit(.store_local, 0, remapLocalSlot(ctx, resolved.each_slots.items[e.slot_start + uj]));
                }
            }

            // Place marker at the beginning of each iter. When the VM looks at the `selector_stack` depth at runtime,
            //Actually loaded into rule_ir only in top-level context (depth 0).
            try ctx.cb.emit(.emit_stmt_gap, 0, 0);
            try compileStmtRange(ctx, e.body_start, e.body_len);

            try ctx.cb.emit(.load_local, 0, remapLocalSlot(ctx, e.index_slot));
            const one = try ctx.cb.addConst(Value.numberUnitless(1));
            try ctx.cb.emit(.load_const, 0, one);
            try ctx.cb.emit(.add, 0, 0);
            try ctx.cb.emit(.store_local, 0, remapLocalSlot(ctx, e.index_slot));

            const j_back = ctx.cb.code.items.len;
            try ctx.cb.emit(.jmp, 0, 0);
            const pop_pc = ctx.cb.code.items.len;
            try ctx.cb.emit(.pop_flow_scope, 0, 0);
            // Reset synthetic loop slots and user-visible loop vars to undeclared
            // before leaving the flow scope so later reads cannot observe stale
            // list/index values from the previous iteration.
            try ctx.cb.emit(.clear_local, 0, remapLocalSlot(ctx, e.list_temp_slot));
            try ctx.cb.emit(.clear_local, 0, remapLocalSlot(ctx, e.index_slot));
            {
                var ci: u32 = 0;
                while (ci < e.slot_count) : (ci += 1) {
                    try ctx.cb.emit(.clear_local, 0, remapLocalSlot(ctx, resolved.each_slots.items[e.slot_start + ci]));
                }
            }
            ctx.cb.patchJmp(j_end, pop_pc);
            ctx.cb.patchJmp(j_back, head_pc);
        },
        .while_loop => {
            const w = resolved.while_stmts.items[st.payload];
            try ctx.cb.emit(.push_flow_scope, 0, 0);
            const head_pc = ctx.cb.code.items.len;
            try compileExpr(ctx, w.cond_expr);
            const j_end = ctx.cb.code.items.len;
            try ctx.cb.emit(.jmp_if_false, 0, 0);
            // Place marker at the beginning of each iter. When the VM looks at the `selector_stack` depth at runtime,
            //Actually loaded into rule_ir only in top-level context (depth 0).
            try ctx.cb.emit(.emit_stmt_gap, 0, 0);
            try compileStmtRange(ctx, w.body_start, w.body_len);
            const j_back = ctx.cb.code.items.len;
            try ctx.cb.emit(.jmp, 0, 0);
            const pop_pc = ctx.cb.code.items.len;
            try ctx.cb.emit(.pop_flow_scope, 0, 0);
            ctx.cb.patchJmp(j_end, pop_pc);
            ctx.cb.patchJmp(j_back, head_pc);
        },
        .include => {
            const inc = resolved.include_stmts.items[st.payload];
            if (inc.content_block == std.math.maxInt(u32)) {
                try ctx.cb.emit(.set_content, 0, std.math.maxInt(u32));
            } else {
                try ctx.cb.emit(.set_content, try checkedU16(ctx.module_id, "content module id"), inc.content_block);
            }
            if (inc.mixin_id == resolver.apply_mixin_sentinel) {
                const control_idx = findMetaControlArgIndex(ctx, inc.arg_start, inc.arg_count, "mixin");
                const control_is_splat = if (control_idx) |idx|
                    resolved.call_arg_names.items[idx] == resolver.call_arg_splat_sentinel
                else
                    false;
                if (control_is_splat) {
                    const target = try Value.callableMake(
                        meta_apply_builtin_id,
                        value_mod.callable_flag_is_mixin |
                            value_mod.callable_flag_is_builtin |
                            value_mod.callable_flag_accepts_content,
                        0,
                        .none,
                        ctx.resolved.value_callable_payload_pool,
                        ctx.cb.shared_pool_alloc,
                    );
                    const target_idx = try ctx.cb.addConst(target);
                    try ctx.cb.emit(.load_const, 0, target_idx);
                    var i: u32 = 0;
                    while (i < inc.arg_count) : (i += 1) {
                        const ai = resolved.call_args.items[inc.arg_start + i];
                        try compileExpr(ctx, ai);
                    }
                    const meta_idx = try addBuiltinCallMeta(ctx, inc.arg_start, inc.arg_count, std.math.maxInt(u32));
                    try ctx.cb.emit(.call_indirect, 1, meta_idx);
                } else {
                    if (control_idx) |idx| {
                        try compileExpr(ctx, resolved.call_args.items[idx]);
                    } else {
                        const nil_idx = try ctx.cb.addConst(Value.nil_v);
                        try ctx.cb.emit(.load_const, 0, nil_idx);
                    }
                    var forwarded: std.ArrayListUnmanaged(u32) = .empty;
                    defer forwarded.deinit(ctx.cb.alloc);
                    try appendForwardedMetaArgIndices(ctx, inc.arg_start, inc.arg_count, control_idx, &forwarded);
                    for (forwarded.items) |idx| {
                        try compileExpr(ctx, resolved.call_args.items[idx]);
                    }
                    const meta_idx = try addBuiltinCallMetaFromIndices(ctx, forwarded.items, std.math.maxInt(u32));
                    try ctx.cb.emit(.call_indirect, 1, meta_idx);
                }
            } else if (inc.mixin_id == resolver.load_css_mixin_sentinel) {
                const target = try Value.callableMake(
                    builtin_mod.meta_load_css_mixin_id,
                    value_mod.callable_flag_is_mixin | value_mod.callable_flag_is_builtin,
                    0,
                    .none,
                    ctx.resolved.value_callable_payload_pool,
                    ctx.cb.shared_pool_alloc,
                );
                const target_idx = try ctx.cb.addConst(target);
                try ctx.cb.emit(.load_const, 0, target_idx);
                var i: u32 = 0;
                while (i < inc.arg_count) : (i += 1) {
                    const ai = resolved.call_args.items[inc.arg_start + i];
                    try compileExpr(ctx, ai);
                }
                const meta_idx = try addBuiltinCallMeta(ctx, inc.arg_start, inc.arg_count, std.math.maxInt(u32));
                try ctx.cb.emit(.call_indirect, 1, meta_idx);
            } else {
                const callee_mod: u32 = if (inc.callee_module == resolver.local_module_id_sentinel) ctx.module_id else inc.callee_module;
                if (inc.callee_module == resolver.local_module_id_sentinel and
                    (inc.mixin_id >= resolved.mixins.items.len or resolved.mixins.items[inc.mixin_id].name == .none))
                {
                    const msg_id = try ctx.pool.intern("Undefined mixin.");
                    const msg_idx = try ctx.cb.addConst(Value.string(msg_id, false));
                    try ctx.cb.emit(.load_const, 0, msg_idx);
                    try ctx.cb.emit(.emit_error, 0, 0);
                    return;
                }
                var flags: u16 = value_mod.callable_flag_is_mixin | value_mod.callable_flag_accepts_content;
                if (inc.capture_callers_locals) flags |= value_mod.callable_flag_capture_callers_locals;
                var module_bits: u16 = 0;
                if (inc.callee_module != resolver.local_module_id_sentinel) {
                    flags |= value_mod.callable_flag_has_module;
                    module_bits = try checkedU16(callee_mod, "include callee module");
                }
                const target = try Value.callableMake(inc.mixin_id, flags, module_bits, inc.callee_name, ctx.resolved.value_callable_payload_pool, ctx.cb.shared_pool_alloc);
                const target_idx = try ctx.cb.addConst(target);
                try ctx.cb.emit(.load_const, 0, target_idx);
                var i: u32 = 0;
                while (i < inc.arg_count) : (i += 1) {
                    const ai = resolved.call_args.items[inc.arg_start + i];
                    try compileExpr(ctx, ai);
                }
                const meta_idx = try addBuiltinCallMeta(ctx, inc.arg_start, inc.arg_count, std.math.maxInt(u32));
                try ctx.cb.emit(.call_indirect, 1, meta_idx);
            }
        },
        .content_call => {
            const c = resolved.content_stmts.items[st.payload];
            var i: u32 = 0;
            while (i < c.arg_count) : (i += 1) {
                const ai = resolved.call_args.items[c.arg_start + i];
                try compileExpr(ctx, ai);
            }
            const meta_idx = try addBuiltinCallMeta(ctx, c.arg_start, c.arg_count, std.math.maxInt(u32));
            try ctx.cb.emit(.call_content, 0, meta_idx);
        },
        .extend => {
            const e = resolved.extend_stmts.items[st.payload];
            var flags: u16 = 0;
            if (e.optional) flags |= 0x1;
            if (e.target_is_placeholder) flags |= 0x2;
            if (e.target_dynamic) {
                var pi: u32 = 0;
                while (pi < e.dynamic_parts_count) : (pi += 1) {
                    const ei = resolved.selector_part_exprs.items[e.dynamic_parts_start + pi];
                    try compileExpr(ctx, ei);
                }
                try ctx.cb.emit(.make_selector, try checkedU16(e.dynamic_parts_count, "extend dynamic parts"), 0);
                flags |= 0x4;
                try ctx.cb.emit(.record_extend, flags, 0);
            } else {
                try ctx.cb.emit(.record_extend, flags, @intFromEnum(e.target_selector));
            }
        },
        .return_stmt => {
            const r = resolved.return_stmts.items[st.payload];
            try compileExpr(ctx, r.value_expr);
            try ctx.cb.emit(.ret_value, 0, 0);
        },
        .assign_var => {
            const a = resolved.assign_stmts.items[st.payload];
            const store_op: Opcode = if (a.global) .store_local_writeback else .store_local;
            if (a.default) {
                try ctx.cb.emit(.load_local, 0, remapLocalSlot(ctx, a.slot));
                const nil_idx = try ctx.cb.addConst(Value.nil_v);
                try ctx.cb.emit(.load_const, 0, nil_idx);
                try ctx.cb.emit(.eq, 0, 0);
                const j_else = ctx.cb.code.items.len;
                try ctx.cb.emit(.jmp_if_false, 0, 0);
                try compileExpr(ctx, a.value_expr);
                try ctx.cb.emit(store_op, 0, remapLocalSlot(ctx, a.slot));
                const j_after = ctx.cb.code.items.len;
                try ctx.cb.emit(.jmp, 0, 0);

                const else_pc = ctx.cb.code.items.len;
                // Must be "declared" even if !default is skipped, so
                // Self-assign the existing value and pass it through store_local.
                try ctx.cb.emit(.load_local, 0, remapLocalSlot(ctx, a.slot));
                try ctx.cb.emit(store_op, 0, remapLocalSlot(ctx, a.slot));

                const after_pc = ctx.cb.code.items.len;
                ctx.cb.patchJmp(j_else, else_pc);
                ctx.cb.patchJmp(j_after, after_pc);
            } else {
                try compileExpr(ctx, a.value_expr);
                try ctx.cb.emit(store_op, 0, remapLocalSlot(ctx, a.slot));
            }
        },
        .debug_stmt => {
            const value_expr: ExprIndex = st.payload;
            try compileExpr(ctx, value_expr);
            try ctx.cb.emit(.emit_debug, 0, 0);
        },
        .warn_stmt => {
            const value_expr: ExprIndex = st.payload;
            try compileExpr(ctx, value_expr);
            try ctx.cb.emit(.emit_warn, 0, 0);
        },
        .error_stmt => {
            const value_expr: ExprIndex = st.payload;
            try compileExpr(ctx, value_expr);
            try ctx.cb.emit(.emit_error, 0, 0);
        },
    }
}

fn ruleOpenFlags(r: RuleData) u16 {
    var flags: u16 = 0;
    if (r.is_plain_css) {
        flags |= if (r.plain_css_parent_selector_combine)
            rule_flag_plain_css_combine_parent
        else
            rule_flag_plain_css_preserve;
    }
    if (r.selector_kind == .literal and !r.literal_selector_syntax_valid) {
        flags |= rule_flag_selector_validation_failed;
    }
    return flags;
}

fn emitRuleOpen(ctx: CompileCtx, r: RuleData, use_push_only: bool) CompileError!void {
    const flags = ruleOpenFlags(r);
    switch (r.selector_kind) {
        .literal => {
            try ctx.cb.noteIntern(r.literal_intern);
            if (use_push_only) {
                try ctx.cb.emit(.push_selector_scope, flags, @intFromEnum(r.literal_intern));
            } else {
                try ctx.cb.emit(.emit_rule_begin, flags, @intFromEnum(r.literal_intern));
            }
        },
        .dynamic => {
            var pi: u32 = 0;
            while (pi < r.dynamic_parts_count) : (pi += 1) {
                const ei = ctx.resolved.selector_part_exprs.items[r.dynamic_parts_start + pi];
                try compileExpr(ctx, ei);
            }
            try ctx.cb.emit(.make_selector, try checkedU16(r.dynamic_parts_count, "at-rule dynamic parts"), 0);
            if (use_push_only) {
                try ctx.cb.emit(.push_selector_scope_dynamic, flags, 0);
            } else {
                try ctx.cb.emit(.emit_rule_begin_dynamic, flags, 0);
            }
        },
    }
}

fn stmtSliceCanUseSimpleSourceOrderLowering(resolved: *const ResolvedProgram, body_direct: []const StmtIndex) bool {
    for (body_direct) |child_si| {
        if (child_si >= resolved.stmts.items.len) return false;
        const ch = resolved.stmts.items[child_si];
        switch (ch.kind) {
            .declaration,
            .comment,
            .rule,
            .at_rule,
            .include,
            .content_call,
            .assign_var,
            .noop,
            .extend,
            .debug_stmt,
            .warn_stmt,
            .error_stmt,
            .module_dep,
            => {},
            .if_chain, .for_loop, .each_loop, .while_loop => return false,
            else => return false,
        }
    }
    return true;
}

fn ruleCanUseSimpleSourceOrderLowering(resolved: *const ResolvedProgram, r: RuleData) bool {
    return stmtSliceCanUseSimpleSourceOrderLowering(resolved, r.body_direct);
}

fn stmtSliceHasDirectContentCall(resolved: *const ResolvedProgram, body_direct: []const StmtIndex) bool {
    for (body_direct) |child_si| {
        if (child_si >= resolved.stmts.items.len) continue;
        if (resolved.stmts.items[child_si].kind == .content_call) return true;
    }
    return false;
}

const SourceOrderLoweringMode = enum {
    maybe,
    direct,

    fn openOpcode(self: @This()) Opcode {
        return switch (self) {
            .maybe => .emit_rule_begin_current_maybe,
            .direct => .emit_rule_begin_current,
        };
    }

    fn closeOpcode(self: @This()) Opcode {
        return switch (self) {
            .maybe => .emit_rule_end_maybe,
            .direct => .emit_rule_end,
        };
    }

    fn emitsCloseOnMidClose(self: @This()) bool {
        return self == .maybe;
    }

    fn forceSuppressAfterRuleBoundary(self: @This()) bool {
        return self == .direct;
    }
};

const SourceOrderLoweringState = struct {
    parent_block_open: bool = false,
    suppress_blank_on_next_parent_open: bool = false,

    fn openParentBlock(self: *@This(), mode: SourceOrderLoweringMode, ctx: CompileCtx) CompileError!void {
        if (self.parent_block_open) return;
        try ctx.cb.emit(mode.openOpcode(), if (self.suppress_blank_on_next_parent_open) 1 else 0, 0);
        self.parent_block_open = true;
        self.suppress_blank_on_next_parent_open = false;
    }

    fn closeParentBlock(self: *@This(), mode: SourceOrderLoweringMode, ctx: CompileCtx) CompileError!void {
        if (!self.parent_block_open) return;
        try ctx.cb.emit(mode.closeOpcode(), 0, 0);
        self.parent_block_open = false;
        self.suppress_blank_on_next_parent_open = true;
    }

    fn closeForMidClose(self: *@This(), mode: SourceOrderLoweringMode, ctx: CompileCtx) CompileError!void {
        if (mode.emitsCloseOnMidClose()) {
            try self.closeParentBlock(mode, ctx);
            self.suppress_blank_on_next_parent_open = true;
            return;
        }
        self.parent_block_open = false;
        self.suppress_blank_on_next_parent_open = true;
    }
};

fn compileSourceOrderedBody(
    ctx: CompileCtx,
    body_direct: []const StmtIndex,
    mode: SourceOrderLoweringMode,
) CompileError!void {
    const resolved = ctx.resolved;
    const ordered_body = try sortedStmtIndicesBySource(ctx.cb.alloc, resolved, body_direct);
    defer ctx.cb.alloc.free(ordered_body);
    var state: SourceOrderLoweringState = .{};

    for (ordered_body) |child_si| {
        const ch = resolved.stmts.items[child_si];
        const child_is_prop_ns = ruleCanCompileAsPropertyNamespace(resolved, child_si);
        const child_plain_css_stays = ch.kind == .rule and ch.payload < resolved.rule_stmts.items.len and blk: {
            const child_rule = effectivePlainCssRuleForModule(resolved.module_path, resolved.rule_stmts.items[ch.payload]);
            break :blk plainCssRuleStaysInParentBlock(ctx.pool, child_rule);
        };
        const child_simple_at_rule = simpleAtRuleStaysInOpenBlock(ctx.pool, resolved, child_si);
        const ensure_parent_block = child_is_prop_ns or ch.kind == .declaration or ch.kind == .comment or child_plain_css_stays or child_simple_at_rule;

        if (ensure_parent_block) {
            try state.openParentBlock(mode, ctx);
            if (child_is_prop_ns) {
                try compilePropertyNamespaceRule(ctx, child_si);
            } else {
                try compileStmt(ctx, child_si);
            }
            continue;
        }

        switch (ch.kind) {
            .include => {
                const inc = resolved.include_stmts.items[ch.payload];
                const analysis = analyzeIncludeCall(
                    ctx.modules,
                    resolved,
                    ctx.pool,
                    ctx.module_id,
                    inc.callee_module,
                    inc.mixin_id,
                    inc.arg_start,
                    inc.arg_count,
                    inc.content_block,
                    no_content_analysis,
                    0,
                );
                if (analysis.may_emit_decl) {
                    try state.openParentBlock(mode, ctx);
                } else {
                    try state.closeParentBlock(mode, ctx);
                }
                try compileStmt(ctx, child_si);
                if (analysis.needs_mid_close) {
                    try state.closeForMidClose(mode, ctx);
                }
            },
            .content_call => {
                try state.openParentBlock(mode, ctx);
                try compileStmt(ctx, child_si);
                try state.closeForMidClose(mode, ctx);
            },
            .rule, .at_rule => {
                try state.closeParentBlock(mode, ctx);
                if (mode == .maybe) {
                    try ctx.cb.emit(.emit_rule_end_if_open, 0, 0);
                }
                try compileStmt(ctx, child_si);
                // Any nested-rule split (direct or maybe mode) is a parent-block
                // boundary. The next parent-open (e.g. a loud-comment wrapper rule)
                // is a reopen and must suppress the top-level fallback blank.
                state.suppress_blank_on_next_parent_open = true;
            },
            .assign_var, .noop, .extend, .debug_stmt, .warn_stmt, .error_stmt => {
                try compileStmt(ctx, child_si);
            },
            .module_dep => {
                // run_dependency runs upstream module body. Upstream may emit
                // nested rules at this location (closing/reopening parent
                // automatically via VM selector_stack), but importantly slot
                // initialization happens immediately so subsequent decls can
                // call upstream functions / read upstream vars.
                try compileStmt(ctx, child_si);
            },
            else => return error.Unsupported,
        }
    }

    try state.closeParentBlock(mode, ctx);
}

fn compileCurrentSelectorSourceOrderedMaybe(ctx: CompileCtx, body_direct: []const StmtIndex) CompileError!void {
    try compileSourceOrderedBody(ctx, body_direct, .maybe);
}

fn sortedStmtIndicesBySource(
    alloc: std.mem.Allocator,
    resolved: *const ResolvedProgram,
    items: []const StmtIndex,
) CompileError![]StmtIndex {
    const ordered = try alloc.dupe(StmtIndex, items);
    var i: usize = 1;
    while (i < ordered.len) : (i += 1) {
        const key = ordered[i];
        var j = i;
        while (j > 0 and stmtComesAfterSource(resolved, ordered[j - 1], key)) : (j -= 1) {
            ordered[j] = ordered[j - 1];
        }
        ordered[j] = key;
    }
    return ordered;
}

fn stmtComesAfterSource(resolved: *const ResolvedProgram, lhs: StmtIndex, rhs: StmtIndex) bool {
    if (lhs >= resolved.stmts.items.len or rhs >= resolved.stmts.items.len) return lhs > rhs;
    const lhs_stmt = resolved.stmts.items[lhs];
    const rhs_stmt = resolved.stmts.items[rhs];
    if (lhs_stmt.origin_id != rhs_stmt.origin_id) return lhs > rhs;
    const lhs_span = lhs_stmt.span;
    const rhs_span = rhs_stmt.span;
    if (lhs_span.start != rhs_span.start) return lhs_span.start > rhs_span.start;
    if (lhs_span.end != rhs_span.end) return lhs_span.end > rhs_span.end;
    return lhs > rhs;
}

fn compileRuleSourceOrdered(ctx: CompileCtx, r: RuleData) CompileError!void {
    const inner_ctx = selectorContextChildCtx(ctx);
    try emitRuleOpen(ctx, r, true);
    try compileSourceOrderedBody(inner_ctx, r.body_direct, .direct);
    try inner_ctx.cb.emit(.pop_rule_scope, 0, 0);
}

fn compileRuleSourceOrderedMaybe(ctx: CompileCtx, r: RuleData) CompileError!void {
    const inner_ctx = selectorContextChildCtx(ctx);
    try emitRuleOpen(ctx, r, true);
    try compileCurrentSelectorSourceOrderedMaybe(inner_ctx, r.body_direct);
    try inner_ctx.cb.emit(.pop_rule_scope, 0, 0);
}

fn compileCurrentSelectorSourceOrdered(ctx: CompileCtx, body_direct: []const StmtIndex) CompileError!void {
    try compileSourceOrderedBody(ctx, body_direct, .direct);
}

fn plainCssRuleHasAmp(pool: *InternPool, r: RuleData) bool {
    if (!r.is_plain_css) return false;
    if (r.selector_kind != .literal) return false;
    return std.mem.findScalar(u8, pool.get(r.literal_intern), '&') != null;
}

fn plainCssRuleStaysInParentBlock(pool: *InternPool, r: RuleData) bool {
    if (!r.is_plain_css) return false;
    if (r.plain_css_parent_selector_combine) {
        return plainCssRuleHasAmp(pool, r);
    }
    return true;
}

fn plainCssDirectBlockAtRule(resolved: *const ResolvedProgram, child_si: StmtIndex) bool {
    if (child_si >= resolved.stmts.items.len) return false;
    const st = resolved.stmts.items[child_si];
    if (st.kind != .at_rule) return false;
    if (st.payload >= resolved.at_rule_stmts.items.len) return false;
    const ar = resolved.at_rule_stmts.items[st.payload];
    return ar.had_block;
}

fn plainCssRuleHasVisibleKeptChildren(resolved: *const ResolvedProgram, r: RuleData) bool {
    for (r.body_direct) |child_si| {
        if (r.plain_css_hoist_block_at_rules and plainCssDirectBlockAtRule(resolved, child_si)) continue;
        if (child_si >= resolved.stmts.items.len) continue;
        const st = resolved.stmts.items[child_si];
        switch (st.kind) {
            .noop, .assign_var => {},
            else => return true,
        }
    }
    return false;
}

fn compilePlainCssRule(ctx: CompileCtx, r: RuleData) CompileError!void {
    const resolved = ctx.resolved;
    const child_ctx = selectorContextChildCtx(ctx);
    const emit_outer = plainCssRuleHasVisibleKeptChildren(resolved, r);
    if (emit_outer) {
        try emitRuleOpen(ctx, r, false);
        for (r.body_direct) |child_si| {
            if (r.plain_css_hoist_block_at_rules and plainCssDirectBlockAtRule(resolved, child_si)) continue;
            try compileStmt(child_ctx, child_si);
        }
        try child_ctx.cb.emit(.emit_rule_end, 0, 0);
        try child_ctx.cb.emit(.pop_rule_scope, 0, 0);
    }

    if (!r.plain_css_hoist_block_at_rules) return;

    for (r.body_direct) |child_si| {
        if (!plainCssDirectBlockAtRule(resolved, child_si)) continue;
        const st = resolved.stmts.items[child_si];
        const ar = resolved.at_rule_stmts.items[st.payload];
        try compileExprOrNil(ctx, ar.prelude_expr);
        try ctx.cb.noteIntern(ar.name_intern);
        var arg_flags = mediaArgFlags(ar.media_flags);
        if (moduleIsPlainCss(ctx)) {
            arg_flags |= opcode_mod.at_rule_flag_plain_css_preserve;
        }
        const keep_empty_flag: u16 = blk: {
            if (!(ar.body_direct.len == 0 and ar.had_block)) break :blk 0;
            const at_rule_name = ctx.pool.get(ar.name_intern);
            break :blk if (shouldPreserveEmptyConditionalAtRule(at_rule_name)) 0x8000 else 0;
        };
        try ctx.cb.emit(.emit_at_rule_begin, keep_empty_flag | arg_flags, @intFromEnum(ar.name_intern));
        if (ar.body_direct.len > 0) {
            try emitRuleOpen(child_ctx, .{
                .selector_kind = r.selector_kind,
                .literal_intern = r.literal_intern,
                .is_placeholder = r.is_placeholder,
                .is_plain_css = true,
                .plain_css_parent_selector_combine = false,
                .plain_css_hoist_block_at_rules = false,
                .prop_namespace_prefix = .none,
                .prop_namespace_prefix_expr = null,
                .prop_namespace_value_expr = null,
                .dynamic_parts_start = r.dynamic_parts_start,
                .dynamic_parts_count = r.dynamic_parts_count,
                .body_direct = &.{},
            }, false);
            for (ar.body_direct) |grandchild_si| {
                try compileStmt(child_ctx, grandchild_si);
            }
            try child_ctx.cb.emit(.emit_rule_end, 0, 0);
            try child_ctx.cb.emit(.pop_rule_scope, 0, 0);
        }
        try ctx.cb.emit(.emit_at_rule_end, 0, 0);
    }
}

fn ruleChildStaysInOpenBlock(
    modules: []const ResolvedProgram,
    pool: *InternPool,
    resolved: *const ResolvedProgram,
    module_id: u32,
    child_si: StmtIndex,
) bool {
    if (ruleCanCompileAsPropertyNamespace(resolved, child_si)) return true;
    if (child_si >= resolved.stmts.items.len) return false;
    const ch = resolved.stmts.items[child_si];
    if (ch.kind == .rule and ch.payload < resolved.rule_stmts.items.len) {
        const child_rule = effectivePlainCssRuleForModule(resolved.module_path, resolved.rule_stmts.items[ch.payload]);
        if (plainCssRuleStaysInParentBlock(pool, child_rule)) return true;
    }
    if (simpleAtRuleStaysInOpenBlock(pool, resolved, child_si)) return true;
    switch (ch.kind) {
        .declaration, .include, .content_call, .assign_var, .noop, .module_dep => return true,
        .if_chain, .for_loop, .each_loop, .while_loop => {
            const shape = analyzeStmtShape(modules, pool, resolved, module_id, child_si, no_content_analysis, 0);
            return !shape.needs_mid_close;
        },
        else => return false,
    }
}

fn callableStmtCompilesInOpenParentFirstPass(
    resolved: *const ResolvedProgram,
    pool: *InternPool,
    si: StmtIndex,
) bool {
    if (ruleCanCompileAsPropertyNamespace(resolved, si)) return true;
    if (si >= resolved.stmts.items.len) return false;
    if (simpleAtRuleStaysInOpenBlock(pool, resolved, si)) return true;

    return switch (resolved.stmts.items[si].kind) {
        .declaration, .include, .content_call, .assign_var, .noop, .module_dep => true,
        else => false,
    };
}

fn compileStmtRange(ctx: CompileCtx, start: StmtIndex, len: u32) CompileError!void {
    if (len == 0) return;
    const end: StmtIndex = start + len;

    // The resolver's stmt ranges are flattened in post-order (child first, parent last).
    // If you run forward as it is, the branch body of if/loop will be executed twice with the parent, so
    // Run backwards to extract only the "direct root stmt" and then execute in source order.
    var roots: std.ArrayListUnmanaged(StmtIndex) = .empty;
    defer roots.deinit(ctx.cb.alloc);
    try roots.ensureTotalCapacity(ctx.cb.alloc, @intCast(len));

    var cursor: StmtIndex = end;
    while (cursor > start) {
        const root_si: StmtIndex = cursor - 1;
        roots.appendAssumeCapacity(root_si);
        const subtree_start = stmtSubtreeStart(ctx.resolved, root_si, 0);
        cursor = if (subtree_start < start) start else subtree_start;
    }

    var i: usize = roots.items.len;
    var emitted: usize = 0;
    while (i > 0) {
        i -= 1;
        const root = roots.items[i];
        // @each/@for/@while also emit_stmt_gap between sibling statements in the body.
        // Insert to reproduce the blank retention behavior of the official Sass CLI. VM has selector_stack depth 0 and
        // Load into rule_ir only when open_block_depth 0, so in loop inside rule/at-rule
        // no-op. hoisted nested rule (`&:hover`) has writer fallback because nest_depth>0
        // blank does not fire and blank falls if there is no pending_blank derived from this gap
        // Matches an observable CLI blank-retention case for loop body siblings.
        if (emitted != 0) {
            ctx.cb.setSourceSpan(ctx.resolved.stmts.items[root].span);
            try ctx.cb.emit(.emit_stmt_gap, 0, 0);
        }
        try compileStmt(ctx, root);
        emitted += 1;
    }
}

/// `@if` / Compile the branch body of loop. The nested rule (needs_mid_close) inside the branch
/// When exiting, insert `emit_rule_end_if_open` just before it to close the outer rule block.
/// No-op if the parent rule is not open in the first place (top level). This
/// prevents `.a { @if { decl; .b {...} } }` from being nested as
/// `.a { decl; .a .b {...} }`.
/// The final close on the outer rule side uses emit_rule_end_if_open to avoid double closes in runtime.
fn compileStmtRangeHoistNested(ctx: CompileCtx, start: StmtIndex, len: u32) CompileError!void {
    if (len == 0) return;
    const end: StmtIndex = start + len;

    var roots: std.ArrayListUnmanaged(StmtIndex) = .empty;
    defer roots.deinit(ctx.cb.alloc);
    try roots.ensureTotalCapacity(ctx.cb.alloc, @intCast(len));

    var cursor: StmtIndex = end;
    while (cursor > start) {
        const root_si: StmtIndex = cursor - 1;
        roots.appendAssumeCapacity(root_si);
        const subtree_start = stmtSubtreeStart(ctx.resolved, root_si, 0);
        cursor = if (subtree_start < start) start else subtree_start;
    }

    var i: usize = roots.items.len;
    var emitted: usize = 0;
    while (i > 0) {
        i -= 1;
        const root = roots.items[i];
        const shape = analyzeStmtShape(ctx.modules, ctx.pool, ctx.resolved, ctx.module_id, root, no_content_analysis, 0);
        if (shape.needs_mid_close) {
            try ctx.cb.emit(.emit_rule_end_if_open, 0, 0);
        }
        // Insert blank line marker between stmt hoisted to top-level. The VM is
        // Stack into rule_ir only if selector_stack depth is 0 and open_block_depth is 0.
        // When a branch emits multiple top-level rules, preserve the blank
        // line that the official Sass CLI emits between adjacent rules.
        if (emitted != 0) {
            ctx.cb.setSourceSpan(ctx.resolved.stmts.items[root].span);
            try ctx.cb.emit(.emit_stmt_gap, 0, 0);
        }
        try compileStmt(ctx, root);
        emitted += 1;
    }
}

fn stmtRangeSubtreeStart(
    resolved: *const ResolvedProgram,
    start: StmtIndex,
    len: u32,
    depth: u8,
) StmtIndex {
    if (len == 0 or depth >= 64) return start;
    const end: StmtIndex = start + len;
    var min_si: StmtIndex = end;
    var cursor: StmtIndex = end;
    while (cursor > start) {
        const root_si: StmtIndex = cursor - 1;
        const sub = stmtSubtreeStart(resolved, root_si, depth + 1);
        if (sub < min_si) min_si = sub;
        cursor = if (sub < start) start else sub;
    }
    return if (min_si < end) min_si else start;
}

fn stmtSubtreeStart(resolved: *const ResolvedProgram, si: StmtIndex, depth: u8) StmtIndex {
    if (depth >= 64) return si;
    if (si >= resolved.stmts.items.len) return si;
    const st = resolved.stmts.items[si];
    var min_si: StmtIndex = si;
    switch (st.kind) {
        .rule => {
            if (st.payload >= resolved.rule_stmts.items.len) return min_si;
            const r = resolved.rule_stmts.items[st.payload];
            for (r.body_direct) |child_root| {
                const sub = stmtSubtreeStart(resolved, child_root, depth + 1);
                if (sub < min_si) min_si = sub;
            }
            return min_si;
        },
        .at_rule => {
            if (st.payload >= resolved.at_rule_stmts.items.len) return min_si;
            const ar = resolved.at_rule_stmts.items[st.payload];
            for (ar.body_direct) |child_root| {
                const sub = stmtSubtreeStart(resolved, child_root, depth + 1);
                if (sub < min_si) min_si = sub;
            }
            return min_si;
        },
        .include => {
            if (st.payload >= resolved.include_stmts.items.len) return min_si;
            const inc = resolved.include_stmts.items[st.payload];
            if (inc.content_block == std.math.maxInt(u32)) return min_si;
            if (inc.content_block >= resolved.content_blocks.items.len) return min_si;
            const cb = resolved.content_blocks.items[inc.content_block];
            for (cb.body_roots) |child_root| {
                const sub = stmtSubtreeStart(resolved, child_root, depth + 1);
                if (sub < min_si) min_si = sub;
            }
            return min_si;
        },
        .if_chain => {
            if (st.payload >= resolved.if_stmts.items.len) return min_si;
            const ifs = resolved.if_stmts.items[st.payload];
            if (ifs.branches_start + ifs.branches_count > resolved.if_branches.items.len) return min_si;
            const branches = resolved.if_branches.items[ifs.branches_start..][0..ifs.branches_count];
            for (branches) |br| {
                if (br.body_len == 0) continue;
                const sub = stmtRangeSubtreeStart(resolved, br.body_start, br.body_len, depth + 1);
                if (sub < min_si) min_si = sub;
            }
            return min_si;
        },
        .for_loop => {
            if (st.payload >= resolved.for_stmts.items.len) return min_si;
            const f = resolved.for_stmts.items[st.payload];
            if (f.body_len != 0) {
                const sub = stmtRangeSubtreeStart(resolved, f.body_start, f.body_len, depth + 1);
                if (sub < min_si) min_si = sub;
            }
            return min_si;
        },
        .each_loop => {
            if (st.payload >= resolved.each_stmts.items.len) return min_si;
            const e = resolved.each_stmts.items[st.payload];
            if (e.body_len != 0) {
                const sub = stmtRangeSubtreeStart(resolved, e.body_start, e.body_len, depth + 1);
                if (sub < min_si) min_si = sub;
            }
            return min_si;
        },
        .while_loop => {
            if (st.payload >= resolved.while_stmts.items.len) return min_si;
            const w = resolved.while_stmts.items[st.payload];
            if (w.body_len != 0) {
                const sub = stmtRangeSubtreeStart(resolved, w.body_start, w.body_len, depth + 1);
                if (sub < min_si) min_si = sub;
            }
            return min_si;
        },
        else => return min_si,
    }
}

/// When the @mixin body contains anything other than properties/@include (such as @for or nested rules), it is necessary to insert the parent rule's `}`.
const MixinAnalysis = struct {
    may_emit_decl: bool,
    needs_mid_close: bool,
};

const no_content_analysis = MixinAnalysis{
    .may_emit_decl = false,
    .needs_mid_close = false,
};

fn conservativeMixinAnalysis() MixinAnalysis {
    return .{
        .may_emit_decl = true,
        .needs_mid_close = false,
    };
}

fn mergeMixinAnalysis(dst: *MixinAnalysis, src: MixinAnalysis) void {
    dst.may_emit_decl = dst.may_emit_decl or src.may_emit_decl;
    dst.needs_mid_close = dst.needs_mid_close or src.needs_mid_close;
}

fn resolveCalleeModule(current_module: u32, callee_module: u32) u32 {
    return if (callee_module == resolver.local_module_id_sentinel) current_module else callee_module;
}

fn analyzeIncludeCall(
    modules: []const ResolvedProgram,
    resolved: *const ResolvedProgram,
    pool: *InternPool,
    current_module: u32,
    callee_module: u32,
    mixin_id: MixinId,
    arg_start: u32,
    arg_count: u32,
    content_block: u32,
    content_analysis: MixinAnalysis,
    depth: u8,
) MixinAnalysis {
    if (depth >= 64) return conservativeMixinAnalysis();
    const attached_content_analysis = if (content_block == std.math.maxInt(u32))
        no_content_analysis
    else
        analyzeContentBlock(modules, pool, resolved, current_module, content_block, content_analysis, depth + 1);
    if (mixin_id == resolver.load_css_mixin_sentinel) {
        return .{
            .may_emit_decl = false,
            .needs_mid_close = true,
        };
    }
    if (mixin_id == resolver.apply_mixin_sentinel) {
        const control_idx = findMetaControlArgIndexResolved(pool, resolved, arg_start, arg_count, "mixin") orelse return conservativeMixinAnalysis();
        if (control_idx >= resolved.call_arg_names.items.len or control_idx >= resolved.call_args.items.len) {
            return conservativeMixinAnalysis();
        }
        if (resolved.call_arg_names.items[control_idx] == resolver.call_arg_splat_sentinel) {
            return conservativeMixinAnalysis();
        }
        const target_expr = resolved.call_args.items[control_idx];
        if (target_expr >= resolved.exprs.items.len) return conservativeMixinAnalysis();
        const ex = resolved.exprs.items[target_expr];
        if (ex.kind != .builtin_call) return conservativeMixinAnalysis();
        if (ex.payload >= resolved.builtin_calls.items.len) return conservativeMixinAnalysis();
        const bc = resolved.builtin_calls.items[ex.payload];
        if (bc.prebound_kind != .mixin) return conservativeMixinAnalysis();
        const target_module = if (bc.prebound_module == resolver.local_module_id_sentinel)
            current_module
        else
            bc.prebound_module;
        return analyzeMixinCall(modules, pool, current_module, target_module, bc.prebound_id, attached_content_analysis, depth + 1);
    }
    return analyzeMixinCall(modules, pool, current_module, callee_module, mixin_id, attached_content_analysis, depth + 1);
}

fn analyzeMixinCall(
    modules: []const ResolvedProgram,
    pool: *InternPool,
    current_module: u32,
    callee_module: u32,
    mixin_id: MixinId,
    content_analysis: MixinAnalysis,
    depth: u8,
) MixinAnalysis {
    if (depth >= 64) return conservativeMixinAnalysis();
    const target_module = resolveCalleeModule(current_module, callee_module);
    const module_index: usize = @intCast(target_module);
    if (module_index >= modules.len) return conservativeMixinAnalysis();
    const target_prog = &modules[module_index];
    const mixin_index: usize = @intCast(mixin_id);
    if (mixin_index >= target_prog.mixins.items.len) return conservativeMixinAnalysis();
    const mix = target_prog.mixins.items[mixin_index];
    if (mixinHasDirectRecursiveInclude(target_prog, target_module, mixin_id)) {
        return conservativeMixinAnalysis();
    }
    return analyzeStmtRange(modules, pool, target_prog, target_module, mix.body_roots, content_analysis, depth + 1);
}

fn analyzeContentBlock(
    modules: []const ResolvedProgram,
    pool: *InternPool,
    resolved: *const ResolvedProgram,
    module_id: u32,
    content_block: u32,
    content_analysis: MixinAnalysis,
    depth: u8,
) MixinAnalysis {
    if (depth >= 64) return conservativeMixinAnalysis();
    const content_index: usize = @intCast(content_block);
    if (content_index >= resolved.content_blocks.items.len) return no_content_analysis;
    const cb = resolved.content_blocks.items[content_index];
    return analyzeStmtRange(modules, pool, resolved, module_id, cb.body_roots, content_analysis, depth + 1);
}

fn stmtRangeHasDirectRecursiveInclude(
    resolved: *const ResolvedProgram,
    module_id: u32,
    body_roots: []const StmtIndex,
    target_module: u32,
    target_mixin: MixinId,
    depth: u8,
) bool {
    if (depth >= 64) return false;
    for (body_roots) |si| {
        if (stmtHasDirectRecursiveInclude(resolved, module_id, si, target_module, target_mixin, depth + 1)) return true;
    }
    return false;
}

fn stmtSliceHasDirectRecursiveInclude(
    resolved: *const ResolvedProgram,
    module_id: u32,
    start: StmtIndex,
    len: u32,
    target_module: u32,
    target_mixin: MixinId,
    depth: u8,
) bool {
    if (depth >= 64 or len == 0) return false;
    const start_usize: usize = @intCast(start);
    const len_usize: usize = @intCast(len);
    if (start_usize > resolved.stmts.items.len) return false;
    if (len_usize > resolved.stmts.items.len - start_usize) return false;
    const end = start + len;
    var si = start;
    while (si < end) : (si += 1) {
        if (stmtHasDirectRecursiveInclude(resolved, module_id, si, target_module, target_mixin, depth + 1)) return true;
    }
    return false;
}

fn stmtHasDirectRecursiveInclude(
    resolved: *const ResolvedProgram,
    module_id: u32,
    si: StmtIndex,
    target_module: u32,
    target_mixin: MixinId,
    depth: u8,
) bool {
    if (depth >= 64 or si >= resolved.stmts.items.len) return false;
    const st = resolved.stmts.items[si];
    switch (st.kind) {
        .include => {
            if (st.payload >= resolved.include_stmts.items.len) return false;
            const inc = resolved.include_stmts.items[st.payload];
            const callee_module = resolveCalleeModule(module_id, inc.callee_module);
            return callee_module == target_module and inc.mixin_id == target_mixin;
        },
        .rule => {
            if (st.payload >= resolved.rule_stmts.items.len) return false;
            const r = resolved.rule_stmts.items[st.payload];
            return stmtRangeHasDirectRecursiveInclude(resolved, module_id, r.body_direct, target_module, target_mixin, depth + 1);
        },
        .at_rule => {
            if (st.payload >= resolved.at_rule_stmts.items.len) return false;
            const ar = resolved.at_rule_stmts.items[st.payload];
            return stmtRangeHasDirectRecursiveInclude(resolved, module_id, ar.body_direct, target_module, target_mixin, depth + 1);
        },
        .if_chain => {
            if (st.payload >= resolved.if_stmts.items.len) return false;
            const ifs = resolved.if_stmts.items[st.payload];
            if (ifs.branches_start + ifs.branches_count > resolved.if_branches.items.len) return false;
            const branches = resolved.if_branches.items[ifs.branches_start..][0..ifs.branches_count];
            for (branches) |br| {
                if (stmtSliceHasDirectRecursiveInclude(resolved, module_id, br.body_start, br.body_len, target_module, target_mixin, depth + 1)) return true;
            }
            return false;
        },
        .for_loop => {
            if (st.payload >= resolved.for_stmts.items.len) return false;
            const loop = resolved.for_stmts.items[st.payload];
            return stmtSliceHasDirectRecursiveInclude(resolved, module_id, loop.body_start, loop.body_len, target_module, target_mixin, depth + 1);
        },
        .each_loop => {
            if (st.payload >= resolved.each_stmts.items.len) return false;
            const loop = resolved.each_stmts.items[st.payload];
            return stmtSliceHasDirectRecursiveInclude(resolved, module_id, loop.body_start, loop.body_len, target_module, target_mixin, depth + 1);
        },
        .while_loop => {
            if (st.payload >= resolved.while_stmts.items.len) return false;
            const loop = resolved.while_stmts.items[st.payload];
            return stmtSliceHasDirectRecursiveInclude(resolved, module_id, loop.body_start, loop.body_len, target_module, target_mixin, depth + 1);
        },
        else => return false,
    }
}

fn mixinHasDirectRecursiveInclude(
    resolved: *const ResolvedProgram,
    module_id: u32,
    mixin_id: MixinId,
) bool {
    const mixin_index: usize = @intCast(mixin_id);
    if (mixin_index >= resolved.mixins.items.len) return false;
    const mix = resolved.mixins.items[mixin_index];
    return stmtRangeHasDirectRecursiveInclude(resolved, module_id, mix.body_roots, module_id, mixin_id, 0);
}

fn analyzeStmtRange(
    modules: []const ResolvedProgram,
    pool: *InternPool,
    resolved: *const ResolvedProgram,
    module_id: u32,
    body_roots: []const StmtIndex,
    content_analysis: MixinAnalysis,
    depth: u8,
) MixinAnalysis {
    var out: MixinAnalysis = .{
        .may_emit_decl = false,
        .needs_mid_close = false,
    };
    for (body_roots) |si| {
        mergeMixinAnalysis(&out, analyzeStmtShape(modules, pool, resolved, module_id, si, content_analysis, depth));
    }
    return out;
}

fn analyzeStmtSlice(
    modules: []const ResolvedProgram,
    pool: *InternPool,
    resolved: *const ResolvedProgram,
    module_id: u32,
    start: StmtIndex,
    len: u32,
    depth: u8,
) MixinAnalysis {
    if (depth >= 64) return conservativeMixinAnalysis();
    if (len == 0) {
        return .{
            .may_emit_decl = false,
            .needs_mid_close = false,
        };
    }

    const start_usize: usize = @intCast(start);
    const len_usize: usize = @intCast(len);
    if (start_usize > resolved.stmts.items.len) return conservativeMixinAnalysis();
    if (len_usize > resolved.stmts.items.len - start_usize) return conservativeMixinAnalysis();

    var out: MixinAnalysis = .{
        .may_emit_decl = false,
        .needs_mid_close = false,
    };
    const end: StmtIndex = start + len;
    var cursor: StmtIndex = end;
    while (cursor > start) {
        const root_si: StmtIndex = cursor - 1;
        mergeMixinAnalysis(&out, analyzeStmtShape(modules, pool, resolved, module_id, root_si, no_content_analysis, depth));
        const subtree_start = stmtSubtreeStart(resolved, root_si, depth);
        cursor = if (subtree_start < start) start else subtree_start;
    }
    return out;
}

fn resolvedLiteralBool(resolved: *const ResolvedProgram, expr_idx: ExprIndex) ?bool {
    if (expr_idx >= resolved.exprs.items.len) return null;
    const expr = resolved.exprs.items[expr_idx];
    if (expr.kind != .literal_bool) return null;
    return expr.payload != 0;
}

fn analyzeAtRootStmtShape(
    modules: []const ResolvedProgram,
    pool: *InternPool,
    resolved: *const ResolvedProgram,
    module_id: u32,
    at_rule: anytype,
    content_analysis: MixinAnalysis,
    depth: u8,
) MixinAnalysis {
    if (at_rule.at_root_behavior != .none) {
        if (atRootBehaviorKeepsRule(at_rule.at_root_behavior)) {
            return analyzeStmtRange(modules, pool, resolved, module_id, at_rule.body_direct, content_analysis, depth + 1);
        }
        return .{
            .may_emit_decl = false,
            .needs_mid_close = true,
        };
    }

    if (!atRootPreludeLooksLikeQuery(resolved, pool, at_rule.prelude_expr)) {
        return .{
            .may_emit_decl = false,
            .needs_mid_close = true,
        };
    }

    return conservativeMixinAnalysis();
}

fn analyzeStmtShape(
    modules: []const ResolvedProgram,
    pool: *InternPool,
    resolved: *const ResolvedProgram,
    module_id: u32,
    si: StmtIndex,
    content_analysis: MixinAnalysis,
    depth: u8,
) MixinAnalysis {
    if (depth >= 64) return conservativeMixinAnalysis();
    if (si >= resolved.stmts.items.len) return conservativeMixinAnalysis();
    const st = resolved.stmts.items[si];
    switch (st.kind) {
        .declaration => return .{
            .may_emit_decl = true,
            .needs_mid_close = false,
        },
        .rule => {
            if (st.payload >= resolved.rule_stmts.items.len) return conservativeMixinAnalysis();
            const r = effectivePlainCssRuleForModule(resolved.module_path, resolved.rule_stmts.items[st.payload]);
            if (plainCssRuleStaysInParentBlock(pool, r)) {
                return .{
                    .may_emit_decl = true,
                    .needs_mid_close = false,
                };
            }
            if (ruleCanCompileAsPropertyNamespace(resolved, si)) {
                return .{
                    .may_emit_decl = true,
                    .needs_mid_close = false,
                };
            }
            return .{
                .may_emit_decl = false,
                .needs_mid_close = true,
            };
        },
        .at_rule => {
            if (simpleAtRuleStaysInOpenBlock(pool, resolved, si)) {
                return .{
                    .may_emit_decl = true,
                    .needs_mid_close = false,
                };
            }
            if (st.payload >= resolved.at_rule_stmts.items.len) return conservativeMixinAnalysis();
            const ar = resolved.at_rule_stmts.items[st.payload];
            if (std.mem.eql(u8, atRuleNameRaw(pool.get(ar.name_intern)), "at-root")) {
                return analyzeAtRootStmtShape(modules, pool, resolved, module_id, ar, content_analysis, depth);
            }
            return .{
                .may_emit_decl = false,
                .needs_mid_close = true,
            };
        },
        .content_call => return content_analysis,
        .module_dep => return .{
            .may_emit_decl = false,
            .needs_mid_close = true,
        },
        .include => {
            if (st.payload >= resolved.include_stmts.items.len) return conservativeMixinAnalysis();
            const inc = resolved.include_stmts.items[st.payload];
            return analyzeIncludeCall(
                modules,
                resolved,
                pool,
                module_id,
                inc.callee_module,
                inc.mixin_id,
                inc.arg_start,
                inc.arg_count,
                inc.content_block,
                content_analysis,
                depth + 1,
            );
        },
        .for_loop => {
            if (st.payload >= resolved.for_stmts.items.len) return conservativeMixinAnalysis();
            const loop = resolved.for_stmts.items[st.payload];
            return analyzeStmtSlice(modules, pool, resolved, module_id, loop.body_start, loop.body_len, depth + 1);
        },
        .each_loop => {
            if (st.payload >= resolved.each_stmts.items.len) return conservativeMixinAnalysis();
            const loop = resolved.each_stmts.items[st.payload];
            return analyzeStmtSlice(modules, pool, resolved, module_id, loop.body_start, loop.body_len, depth + 1);
        },
        .while_loop => {
            if (st.payload >= resolved.while_stmts.items.len) return conservativeMixinAnalysis();
            const loop = resolved.while_stmts.items[st.payload];
            return analyzeStmtSlice(modules, pool, resolved, module_id, loop.body_start, loop.body_len, depth + 1);
        },
        .if_chain => {
            if (st.payload >= resolved.if_stmts.items.len) return conservativeMixinAnalysis();
            const ifs = resolved.if_stmts.items[st.payload];
            if (ifs.branches_start + ifs.branches_count > resolved.if_branches.items.len) return conservativeMixinAnalysis();
            var out: MixinAnalysis = .{
                .may_emit_decl = false,
                .needs_mid_close = false,
            };
            const branches = resolved.if_branches.items[ifs.branches_start..][0..ifs.branches_count];
            var saw_dynamic_branch = false;
            var short_circuit_taken = false;
            for (branches) |br| {
                if (short_circuit_taken) break;
                if (!saw_dynamic_branch) {
                    if (br.cond_expr) |ce| {
                        if (resolvedLiteralBool(resolved, ce)) |cond| {
                            if (!cond) continue;
                            mergeMixinAnalysis(&out, analyzeStmtSlice(modules, pool, resolved, module_id, br.body_start, br.body_len, depth + 1));
                            short_circuit_taken = true;
                            continue;
                        }
                        saw_dynamic_branch = true;
                    }
                }
                mergeMixinAnalysis(&out, analyzeStmtSlice(modules, pool, resolved, module_id, br.body_start, br.body_len, depth + 1));
            }
            return out;
        },
        else => return .{
            .may_emit_decl = false,
            .needs_mid_close = false,
        },
    }
}

/// If there is no property directly below and there is no `@if` / `@for` / `@each`, do not output the outer empty block and use only `push_selector_scope`
/// (Example: `.box-sm { @include group; .inner { ... } }`). Mixins cannot issue root declarations (such as the width of `@mixin box`).
fn ruleUsesPushOnlyOuter(
    resolved: *const ResolvedProgram,
    modules: []const ResolvedProgram,
    pool: *InternPool,
    module_id: u32,
    r: RuleData,
) bool {
    for (r.body_direct) |child_si| {
        if (ruleCanCompileAsPropertyNamespace(resolved, child_si)) return false;
        const ch = resolved.stmts.items[child_si];
        if (ch.kind == .rule and ch.payload < resolved.rule_stmts.items.len) {
            const child_rule = effectivePlainCssRuleForModule(resolved.module_path, resolved.rule_stmts.items[ch.payload]);
            if (plainCssRuleStaysInParentBlock(pool, child_rule)) return false;
        }
        switch (ch.kind) {
            .declaration => return false,
            .at_rule => {
                const shape = analyzeStmtShape(modules, pool, resolved, module_id, child_si, no_content_analysis, 0);
                if (shape.may_emit_decl) return false;
            },
            .if_chain, .for_loop, .each_loop, .while_loop => {
                const shape = analyzeStmtShape(modules, pool, resolved, module_id, child_si, no_content_analysis, 0);
                if (shape.may_emit_decl) return false;
            },
            .include => {
                const inc = resolved.include_stmts.items[ch.payload];
                const analysis = analyzeIncludeCall(
                    modules,
                    resolved,
                    pool,
                    module_id,
                    inc.callee_module,
                    inc.mixin_id,
                    inc.arg_start,
                    inc.arg_count,
                    inc.content_block,
                    no_content_analysis,
                    0,
                );
                if (analysis.may_emit_decl) return false;
            },
            else => {},
        }
    }
    return true;
}

fn compileChunkIntoArena(
    parent_alloc: std.mem.Allocator,
    arena: std.mem.Allocator,
    modules: []const ResolvedProgram,
    resolved: *const ResolvedProgram,
    module_id: u32,
    color_pool: *ColorPool,
    pool: *InternPool,
    name: []const u8,
    global_slot_base: u32,
    local_count: u16,
    argc: u16,
    arg_base: u16,
    param_names: []const InternId,
    defaults: []const ?ExprIndex,
    has_rest: bool,
    body_roots: []const StmtIndex,
    ret: enum { void_ret, value_ret },
    mixin_close_parent: bool,
    cb_scratch: *ChunkBuilder,
) CompileError!Chunk {
    cb_scratch.resetForReuse(module_id);
    const cb = cb_scratch;

    const slot_bias: u32 = if (resolved.next_global_slot > global_slot_base)
        resolved.next_global_slot - global_slot_base
    else
        0;
    const adjusted_local_count_u32: u32 = @as(u32, local_count) + slot_bias;
    const adjusted_local_count: u16 = try checkedU16(adjusted_local_count_u32, "adjusted local count");
    const adjusted_arg_base: u16 = if (argc == 0)
        arg_base
    else
        try checkedU16(remapLocalSlot(.{
            .resolved = resolved,
            .cb = cb,
            .module_id = module_id,
            .modules = modules,
            .color_pool = color_pool,
            .pool = pool,
            .callable_local_slot_base = global_slot_base,
            .callable_local_slot_bias = slot_bias,
        }, arg_base), "adjusted arg base");

    try cb.emit(.enter_frame, adjusted_local_count, 0);
    const ctx = CompileCtx{
        .resolved = resolved,
        .cb = cb,
        .module_id = module_id,
        .modules = modules,
        .color_pool = color_pool,
        .pool = pool,
        .at_rule_depth = 0,
        .emit_comments = ret == .void_ret,
        .callable_local_slot_base = global_slot_base,
        .callable_local_slot_bias = slot_bias,
    };
    if (mixin_close_parent) {
        const effective_first_pass = try parent_alloc.alloc(bool, body_roots.len);
        defer parent_alloc.free(effective_first_pass);
        var seen_non_first_pass_stmt = false;
        var has_comment_body_stmt = false;
        for (body_roots, 0..) |si, body_idx| {
            const st = resolved.stmts.items[si];
            if (st.kind == .comment) has_comment_body_stmt = true;
            const candidate = callableStmtCompilesInOpenParentFirstPass(resolved, pool, si);
            effective_first_pass[body_idx] = switch (st.kind) {
                // If declaration / include comes after nested rule,
                // official Sass CLI puts `.a { rule; decl; }` after `.a { rule; }`
                // Reopen and output as `.a { decl; }`. The same goes for @include,
                // Since decl/rule is emitted internally, if the source order is changed, the output will be swapped
                // This includes cases where @include comes immediately after a declaration.
                // Preceded like assign_var to maintain the same order within the mixin body
                // first-pass is not possible if there is a non-first-pass stmt.
                .assign_var, .declaration, .include, .content_call => candidate and !seen_non_first_pass_stmt,
                else => candidate,
            };
            if (st.kind != .comment and !candidate) {
                seen_non_first_pass_stmt = true;
            }
        }

        const comment_emitted_in_first_pass: []bool = if (has_comment_body_stmt) blk: {
            const flags = try parent_alloc.alloc(bool, body_roots.len);
            @memset(flags, false);
            break :blk flags;
        } else &.{};
        defer if (comment_emitted_in_first_pass.len != 0) parent_alloc.free(comment_emitted_in_first_pass);

        var has_second_pass_stmt_requiring_mid_close = false;
        for (body_roots, 0..) |si, body_idx| {
            const st = resolved.stmts.items[si];
            if (effective_first_pass[body_idx]) continue;
            if (st.kind == .comment) continue;
            const shape = analyzeStmtShape(modules, pool, resolved, module_id, si, no_content_analysis, 0);
            if (shape.needs_mid_close) {
                has_second_pass_stmt_requiring_mid_close = true;
                break;
            }
        }

        var saw_true_second_pass_stmt = false;
        var saw_first_pass_mid_close_boundary = false;
        var emitted_mid_close_in_first_pass = false;
        for (body_roots, 0..) |si, body_idx| {
            const st = resolved.stmts.items[si];
            const comment_belongs_to_open_block = st.kind == .comment and !saw_true_second_pass_stmt;
            if (effective_first_pass[body_idx] or comment_belongs_to_open_block) {
                // Z11: callee body uses mid-close with first-pass classification include etc.
                // If necessary (including @media, etc.), add parent rule before include while preserving source order.
                // Close. Otherwise, @media will bubble inside the parent rule and the selector will be duplicated.
                // Cause import of sibling rule (callee-block include reproducer).
                if (st.kind != .comment) {
                    const inline_shape = analyzeStmtShape(modules, pool, resolved, module_id, si, no_content_analysis, 0);
                    if (inline_shape.needs_mid_close) {
                        if (emitted_mid_close_in_first_pass) {
                            cb.setSourceSpan(st.span);
                            try cb.emit(.emit_stmt_gap, 0, 0);
                        }
                        try cb.emit(.emit_rule_end_if_open, 0, 0);
                    }
                }
                try compileStmt(ctx, si);
                if (comment_belongs_to_open_block) {
                    comment_emitted_in_first_pass[body_idx] = true;
                }
                if (st.kind != .comment) {
                    const shape = analyzeStmtShape(modules, pool, resolved, module_id, si, no_content_analysis, 0);
                    if (shape.needs_mid_close) {
                        saw_true_second_pass_stmt = true;
                        saw_first_pass_mid_close_boundary = true;
                        emitted_mid_close_in_first_pass = true;
                    }
                }
            } else if (st.kind != .comment) {
                saw_true_second_pass_stmt = true;
            }
        }
        // When there is a rule / block at-rule etc. in the second pass, if there is a currently open parent rule,
        // Close first. Root calls result in runtime no-op.
        if (has_second_pass_stmt_requiring_mid_close) {
            try cb.emit(.emit_rule_end_if_open, 0, 0);
        }

        var saw_second_pass_stmt = saw_first_pass_mid_close_boundary;
        var reopened_parent_for_second_pass_comments = false;
        // If the declaration that came after the nested rule is deferred to second-pass,
        // Re-open the consecutive declarations as a `.parent { decls... }` block
        // It is necessary. reopened_parent_for_second_pass_comments for comments and
        // Prepare a similar mechanism for decl.
        var reopened_parent_for_second_pass_decls = false;
        // Insert emit_stmt_gap between top-level rule-like stmt in mixin body.
        // The VM fills the gap when the caller is top-level, and blank insertion between sibling rules works.
        // comment / declaration is not covered because it is wrapped by parent re-open.
        var emitted_rule_like_in_second_pass = false;
        for (body_roots, 0..) |si, body_idx| {
            const st = resolved.stmts.items[si];
            if (effective_first_pass[body_idx]) continue;
            if (st.kind == .comment and comment_emitted_in_first_pass.len != 0 and comment_emitted_in_first_pass[body_idx]) continue;
            if (st.kind == .comment and !saw_second_pass_stmt) continue;

            if (st.kind == .comment) {
                if (!reopened_parent_for_second_pass_comments and !reopened_parent_for_second_pass_decls) {
                    try cb.emit(.emit_rule_begin_current_maybe, 1, 0);
                    reopened_parent_for_second_pass_comments = true;
                }
                try compileStmt(ctx, si);
                continue;
            }

            if (st.kind == .declaration) {
                if (!reopened_parent_for_second_pass_decls and !reopened_parent_for_second_pass_comments) {
                    try cb.emit(.emit_rule_begin_current_maybe, 1, 0);
                    reopened_parent_for_second_pass_decls = true;
                }
                try compileStmt(ctx, si);
                saw_second_pass_stmt = true;
                continue;
            }

            if (reopened_parent_for_second_pass_comments) {
                try cb.emit(.emit_rule_end_maybe, 0, 0);
                reopened_parent_for_second_pass_comments = false;
            }
            if (reopened_parent_for_second_pass_decls) {
                try cb.emit(.emit_rule_end_maybe, 0, 0);
                reopened_parent_for_second_pass_decls = false;
            }

            if (emitted_rule_like_in_second_pass) {
                cb.setSourceSpan(st.span);
                try cb.emit(.emit_stmt_gap, 0, 0);
            }
            try compileStmt(ctx, si);
            saw_second_pass_stmt = true;
            emitted_rule_like_in_second_pass = true;
        }
        if (reopened_parent_for_second_pass_comments) {
            try cb.emit(.emit_rule_end_maybe, 0, 0);
        }
        if (reopened_parent_for_second_pass_decls) {
            try cb.emit(.emit_rule_end_maybe, 0, 0);
        }
    } else {
        // Insert emit_stmt_gap between top-level stmt in mixin body.
        // VM looks at selector_stack / open_block_depth and stacks gap only at top-level.
        // Now if caller is top-level, blank insertion between sibling rules will work.
        // Do not output gap in function body (value_ret) (because it does not involve CSS output).
        for (body_roots, 0..) |si, idx| {
            if (idx != 0 and ret == .void_ret) {
                cb.setSourceSpan(resolved.stmts.items[si].span);
                try cb.emit(.emit_stmt_gap, 0, 0);
            }
            try compileStmt(ctx, si);
        }
    }
    switch (ret) {
        .void_ret => try cb.emit(.ret_void, 0, 0),
        .value_ret => {
            if (body_roots.len == 0) {
                const ni = try cb.addConst(Value.nil_v);
                try cb.emit(.load_const, 0, ni);
                try cb.emit(.ret_value, 0, 0);
            } else {
                const last = resolved.stmts.items[body_roots[body_roots.len - 1]];
                if (last.kind != .return_stmt) {
                    const ni = try cb.addConst(Value.nil_v);
                    try cb.emit(.load_const, 0, ni);
                    try cb.emit(.ret_value, 0, 0);
                }
            }
        },
    }
    var default_vals = try parent_alloc.alloc(Chunk.ParamDefault, argc);
    defer parent_alloc.free(default_vals);
    var di: usize = 0;
    while (di < argc) : (di += 1) {
        default_vals[di] = if (di < defaults.len)
            try compileParamDefault(ctx, defaults[di])
        else
            .none;
    }
    return cb.toChunk(arena, name, adjusted_local_count, argc, adjusted_arg_base, param_names, default_vals, has_rest);
}

fn compileTopIntoArena(
    arena: std.mem.Allocator,
    modules: []const ResolvedProgram,
    resolved: *const ResolvedProgram,
    module_id: u32,
    color_pool: *ColorPool,
    pool: *InternPool,
    cb_scratch: *ChunkBuilder,
) CompileError!Chunk {
    cb_scratch.resetForReuse(module_id);
    const cb = cb_scratch;

    const lc: u16 = try checkedU16(resolved.max_slot, "top max slot");
    try cb.emit(.enter_frame, lc, 0);
    const ctx = CompileCtx{
        .resolved = resolved,
        .cb = cb,
        .module_id = module_id,
        .modules = modules,
        .color_pool = color_pool,
        .pool = pool,
        .at_rule_depth = 0,
    };
    // Insert `emit_stmt_gap` marker between top-level stmt. writer recognizes stmt boundaries and
    // Insert a blank line just before the next rule_begin/at_rule_begin. It cannot be placed before the first stmt.
    for (resolved.top_stmts, 0..) |si, idx| {
        if (idx != 0) {
            cb.setSourceSpan(resolved.stmts.items[si].span);
            try cb.emit(.emit_stmt_gap, 0, 0);
        }
        try compileStmt(ctx, si);
    }
    try cb.emit(.halt, 0, 0);
    return cb.toChunk(arena, "top", lc, 0, 0, &.{}, &.{}, false);
}

fn compileOneModule(
    parent_alloc: std.mem.Allocator,
    arena: std.mem.Allocator,
    modules: []const ResolvedProgram,
    resolved: *const ResolvedProgram,
    module_id: u32,
    color_pool: *ColorPool,
    color_pool_alloc: std.mem.Allocator,
    pool: *InternPool,
    shared_pool_alloc: std.mem.Allocator,
) CompileError!ModuleChunks {
    // Do not alloc/deinit ChunkBuilder per-chunk, reuse one per module.
    //Empty the internal ArrayList with clearRetainingCapacity at the start of each chunk and set the capacity to
    // Reduce zero-init / alloc cost per chunk by maintaining (with ReleaseSafe profile)
    // memset's `ChunkBuilder.toChunk` route 5%, compileChunkIntoArena even with ReleaseFast
    // Partly due to the immediate memset hotspot).
    var cb_scratch: ChunkBuilder = .{
        .alloc = parent_alloc,
        .color_alloc = color_pool_alloc,
        .shared_pool_alloc = shared_pool_alloc,
    };
    defer cb_scratch.deinit(parent_alloc);

    var mixin_chunks: std.ArrayListUnmanaged(Chunk) = .empty;
    defer mixin_chunks.deinit(arena);
    try mixin_chunks.ensureTotalCapacity(arena, resolved.mixins.items.len);
    const mixin_names = try cloneCallableNames(arena, pool, resolved.mixins.items, "mixin");
    for (resolved.mixins.items, 0..) |m, idx| {
        const mixin_analysis = analyzeStmtRange(modules, pool, resolved, module_id, m.body_roots, no_content_analysis, 0);
        const name = mixin_names[idx];
        var ch = try compileChunkIntoArena(
            parent_alloc,
            arena,
            modules,
            resolved,
            module_id,
            color_pool,
            pool,
            name,
            if (m.accepts_content) m.global_slot_base else resolved.next_global_slot,
            try checkedU16(m.local_count, "mixin local count"),
            try checkedU16FromUsize(m.param_slots.len, "mixin param slot length"),
            if (m.param_slots.len == 0) 0 else try checkedU16(m.param_slots[0], "mixin param slot base"),
            m.param_names,
            m.defaults,
            m.has_rest,
            m.body_roots,
            .void_ret,
            mixin_analysis.needs_mid_close,
            &cb_scratch,
        );
        ch.has_content = m.accepts_content;
        ch.captures_callers_locals = m.captures_callers_locals;
        ch.global_slot_base = m.global_slot_base;
        if (!ch.has_content and !ch.captures_callers_locals) {
            trimCallableLocalCount(resolved, &ch, false);
        }
        try mixin_chunks.append(arena, ch);
    }

    var fn_chunks: std.ArrayListUnmanaged(Chunk) = .empty;
    defer fn_chunks.deinit(arena);
    try fn_chunks.ensureTotalCapacity(arena, resolved.functions.items.len);
    const function_names = try cloneCallableNames(arena, pool, resolved.functions.items, "fn");
    for (resolved.functions.items, 0..) |f, idx| {
        const name = function_names[idx];
        var ch = try compileChunkIntoArena(
            parent_alloc,
            arena,
            modules,
            resolved,
            module_id,
            color_pool,
            pool,
            name,
            resolved.next_global_slot,
            try checkedU16(f.local_count, "function local count"),
            try checkedU16FromUsize(f.param_slots.len, "function param slot length"),
            if (f.param_slots.len == 0) 0 else try checkedU16(f.param_slots[0], "function param slot base"),
            f.param_names,
            f.defaults,
            f.has_rest,
            f.body_roots,
            .value_ret,
            false,
            &cb_scratch,
        );
        ch.captures_callers_locals = f.captures_callers_locals;
        ch.global_slot_base = f.global_slot_base;
        if (!ch.captures_callers_locals) {
            trimCallableLocalCount(resolved, &ch, false);
        }
        try fn_chunks.append(arena, ch);
    }

    var content_chunks: std.ArrayListUnmanaged(Chunk) = .empty;
    defer content_chunks.deinit(arena);
    try content_chunks.ensureTotalCapacity(arena, resolved.content_blocks.items.len);
    for (resolved.content_blocks.items) |c| {
        const name = try std.fmt.allocPrint(arena, "content_{d}", .{c.id});
        const content_analysis = analyzeStmtRange(modules, pool, resolved, module_id, c.body_roots, no_content_analysis, 0);
        var ch = try compileChunkIntoArena(
            parent_alloc,
            arena,
            modules,
            resolved,
            module_id,
            color_pool,
            pool,
            name,
            c.global_slot_base,
            try checkedU16(c.local_count, "content local count"),
            try checkedU16FromUsize(c.param_slots.len, "content param slot length"),
            if (c.param_slots.len == 0) 0 else try checkedU16(c.param_slots[0], "content param slot base"),
            c.param_names,
            c.defaults,
            c.has_rest,
            c.body_roots,
            .void_ret,
            content_analysis.needs_mid_close,
            &cb_scratch,
        );
        ch.global_slot_base = c.global_slot_base;
        trimCallableLocalCount(resolved, &ch, true);
        try content_chunks.append(arena, ch);
    }

    var placeholder_chunks: std.ArrayListUnmanaged(Chunk) = .empty;
    defer placeholder_chunks.deinit(arena);
    var placeholder_targets: std.ArrayListUnmanaged(InternId) = .empty;
    defer placeholder_targets.deinit(arena);
    var placeholder_count: usize = 0;
    for (resolved.rule_stmts.items) |r| {
        if (r.selector_kind == .literal and r.is_placeholder) placeholder_count += 1;
    }
    try placeholder_chunks.ensureTotalCapacity(arena, placeholder_count);
    try placeholder_targets.ensureTotalCapacity(arena, placeholder_count);
    for (resolved.rule_stmts.items) |r| {
        if (r.selector_kind != .literal or !r.is_placeholder) continue;
        const rule_analysis = analyzeStmtRange(modules, pool, resolved, module_id, r.body_direct, no_content_analysis, 0);
        const name = try std.fmt.allocPrint(arena, "placeholder_{d}", .{placeholder_chunks.items.len});
        const ch = try compileChunkIntoArena(
            parent_alloc,
            arena,
            modules,
            resolved,
            module_id,
            color_pool,
            pool,
            name,
            resolved.next_global_slot,
            try checkedU16(resolved.max_slot, "placeholder local count"),
            0,
            0,
            &.{},
            &.{},
            false,
            r.body_direct,
            .void_ret,
            rule_analysis.needs_mid_close,
            &cb_scratch,
        );
        try placeholder_chunks.append(arena, ch);
        try placeholder_targets.append(arena, r.literal_intern);
    }

    for (mixin_chunks.items) |*ch| {
        try applySuperinstructionPeephole(parent_alloc, arena, ch);
    }
    for (fn_chunks.items) |*ch| {
        try applySuperinstructionPeephole(parent_alloc, arena, ch);
    }
    for (content_chunks.items) |*ch| {
        try applySuperinstructionPeephole(parent_alloc, arena, ch);
    }
    for (placeholder_chunks.items) |*ch| {
        try applySuperinstructionPeephole(parent_alloc, arena, ch);
    }

    var top = try compileTopIntoArena(arena, modules, resolved, module_id, color_pool, pool, &cb_scratch);
    top.global_slot_base = resolved.next_global_slot;
    try applySuperinstructionPeephole(parent_alloc, arena, &top);

    const local_fallback_slots: []u32 = blk: {
        if (resolved.flow_local_fallbacks.items.len == 0) break :blk &.{};
        // Array length is actually max slot+1 with fallback. If you reserve the max_slot total length
        //Number of modules x max_slot * 4B memset rides linearly (~8% memset origin observed in profiles).
        var max_used: u32 = 0;
        for (resolved.flow_local_fallbacks.items) |entry| {
            if (entry.slot >= resolved.max_slot) continue;
            if (entry.slot > max_used) max_used = entry.slot;
        }
        const fallback_len: usize = @as(usize, max_used) + 1;
        const slots = try arena.alloc(u32, fallback_len);
        @memset(slots, std.math.maxInt(u32));
        for (resolved.flow_local_fallbacks.items) |entry| {
            const slot: usize = @intCast(entry.slot);
            if (slot >= slots.len) continue;
            slots[slot] = entry.fallback;
        }
        break :blk slots;
    };

    var res = ModuleChunks{
        .module_path = try arena.dupe(u8, resolved.module_path),
        .top = top,
        .mixins = try mixin_chunks.toOwnedSlice(arena),
        .functions = try fn_chunks.toOwnedSlice(arena),
        .content_blocks = try content_chunks.toOwnedSlice(arena),
        .placeholder_blocks = try placeholder_chunks.toOwnedSlice(arena),
        .placeholder_targets = try placeholder_targets.toOwnedSlice(arena),
        .global_slot_count = resolved.next_global_slot,
        .max_slot = resolved.max_slot,
        .line_starts = try arena.dupe(u32, resolved.line_starts),
        .source_len = resolved.source_len,
        .local_fallback_slots = local_fallback_slots,
    };

    // Copy metadata maps
    {
        try cloneStringHashMapOwnedKeys(u32, arena, &resolved.global_slots, &res.global_slots);
        try cloneStringHashMapOwnedKeys(u32, arena, &resolved.mixin_names, &res.mixin_names);
        try cloneStringHashMapOwnedKeys(u32, arena, &resolved.function_names, &res.function_names);
        try cloneStringHashMapOwnedKeys(resolver.UseBinding, arena, &resolved.use_map, &res.use_map);
        try cloneStringHashMapOwnedKeys(resolver.VarTarget, arena, &resolved.star_vars, &res.star_vars);
        try cloneStringHashMapOwnedKeys(void, arena, &resolved.ambiguous_star_vars, &res.ambiguous_star_vars);
        try cloneStringHashMapOwnedKeys(resolver.CallableTarget, arena, &resolved.star_mixins, &res.star_mixins);
        try cloneStringHashMapOwnedKeys(void, arena, &resolved.ambiguous_star_mixins, &res.ambiguous_star_mixins);
        try cloneStringHashMapOwnedKeys(resolver.CallableTarget, arena, &resolved.star_functions, &res.star_functions);
        try cloneStringHashMapOwnedKeys(void, arena, &resolved.ambiguous_star_functions, &res.ambiguous_star_functions);
        try cloneStringHashMapOwnedKeys(u32, arena, &resolved.star_builtin_fns, &res.star_builtin_fns);
        try cloneStringHashMapOwnedKeys(resolver.CallableTarget, arena, &resolved.exported_mixins, &res.exported_mixins);
        try cloneStringHashMapOwnedKeys(void, arena, &resolved.ambiguous_export_mixins, &res.ambiguous_export_mixins);
        try cloneStringHashMapOwnedKeys(resolver.CallableTarget, arena, &resolved.exported_functions, &res.exported_functions);
        try cloneStringHashMapOwnedKeys(void, arena, &resolved.ambiguous_export_functions, &res.ambiguous_export_functions);
        try cloneStringHashMapOwnedKeys(u32, arena, &resolved.exported_builtin_fns, &res.exported_builtin_fns);
        try cloneStringHashMapOwnedKeys(resolver.VarTarget, arena, &resolved.exported_vars, &res.exported_vars);
        try cloneStringHashMapOwnedKeys(void, arena, &resolved.ambiguous_export_vars, &res.ambiguous_export_vars);
        try cloneStringHashMapOwnedKeys(resolver.VarTarget, arena, &resolved.exported_default_vars, &res.exported_default_vars);
        try cloneStringHashMapOwnedKeys(void, arena, &resolved.ambiguous_export_default_vars, &res.ambiguous_export_default_vars);
    }

    return res;
}

fn cloneCallableNames(
    arena: std.mem.Allocator,
    pool: *InternPool,
    callables: anytype,
    comptime fallback_prefix: []const u8,
) CompileError![]const []const u8 {
    const out = try arena.alloc([]const u8, callables.len);

    var named_bytes: usize = 0;
    for (callables) |entry| {
        if (entry.name != .none) {
            named_bytes += pool.get(entry.name).len;
        }
    }

    const named_storage = try arena.alloc(u8, named_bytes);
    var cursor: usize = 0;
    for (callables, 0..) |entry, idx| {
        if (entry.name == .none) {
            out[idx] = try std.fmt.allocPrint(arena, fallback_prefix ++ "_{d}", .{entry.id});
            continue;
        }
        const raw = pool.get(entry.name);
        const end = cursor + raw.len;
        const owned = named_storage[cursor..end];
        @memcpy(owned, raw);
        out[idx] = owned;
        cursor = end;
    }
    return out;
}

fn cloneStringHashMapOwnedKeys(
    comptime V: type,
    arena: std.mem.Allocator,
    src: *const std.StringHashMapUnmanaged(V),
    dst: *std.StringHashMapUnmanaged(V),
) CompileError!void {
    const count = src.count();
    if (count == 0) return;
    try dst.ensureTotalCapacity(arena, count);

    var total_key_bytes: usize = 0;
    var count_it = src.iterator();
    while (count_it.next()) |entry| {
        total_key_bytes += entry.key_ptr.*.len;
    }

    const key_storage = try arena.alloc(u8, total_key_bytes);
    var key_cursor: usize = 0;
    var it = src.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const key_end = key_cursor + key.len;
        const owned_key = key_storage[key_cursor..key_end];
        @memcpy(owned_key, key);
        key_cursor = key_end;
        dst.putAssumeCapacityNoClobber(owned_key, entry.value_ptr.*);
    }
}

fn cloneSliceOfSlices(
    comptime T: type,
    arena: std.mem.Allocator,
    src: []const []const T,
) CompileError![]const []const T {
    if (src.len == 0) return &.{};

    const out = try arena.alloc([]const T, src.len);
    var total: usize = 0;
    for (src) |items| total += items.len;

    const storage = try arena.alloc(T, total);
    var cursor: usize = 0;
    for (src, 0..) |items, i| {
        const end = cursor + items.len;
        const owned = storage[cursor..end];
        @memcpy(owned, items);
        out[i] = owned;
        cursor = end;
    }
    return out;
}

fn cloneValueSliceArray(arena: std.mem.Allocator, src: []const []const Value) CompileError![]const []const Value {
    return cloneSliceOfSlices(Value, arena, src);
}

fn cloneStringSliceArray(arena: std.mem.Allocator, src: []const []const u8) CompileError![]const []const u8 {
    return cloneSliceOfSlices(u8, arena, src);
}

fn buildOrigins(arena: std.mem.Allocator, bundle: *const ResolvedBundle) CompileError![]CssOrigin {
    const total = bundle.modules.len + 1 + bundle.import_origins.len;
    const origins = try arena.alloc(CssOrigin, total);
    origins[0] = .{
        .kind = .root,
        .source_path = bundle.modules[bundle.root_index].module_path,
        .module_id = bundle.root_index,
        .parent_import_origin = .invalid,
        .preamble_comment_ids = &.{},
    };
    for (bundle.modules, 0..) |*rp, mid| {
        origins[mid + 1] = .{
            .kind = .module,
            .source_path = rp.module_path,
            .module_id = @intCast(mid),
            .parent_import_origin = .invalid,
            .preamble_comment_ids = &.{},
        };
    }
    const import_base: u32 = @intCast(bundle.modules.len + 1);
    for (bundle.import_origins, 0..) |origin, i| {
        const parent_import_origin = if (origin.parent_import_origin.isValid())
            @as(OriginId, @enumFromInt(import_base + @intFromEnum(origin.parent_import_origin)))
        else
            OriginId.invalid;
        origins[bundle.modules.len + 1 + i] = .{
            .kind = origin.kind,
            .source_path = origin.source_path,
            .module_id = origin.module_id,
            .parent_import_origin = parent_import_origin,
            .preamble_comment_ids = origin.preamble_comment_ids,
        };
    }
    return origins;
}

pub fn compile(allocator: std.mem.Allocator, pool: *InternPool, bundle: *const ResolvedBundle, color_pool: *ColorPool) CompileError!Program {
    return compileWithColorAllocAndCache(allocator, allocator, pool, bundle, color_pool, null, null, allocator);
}

/// Step 6: cross-entry compile chunks reuse. If chunks_cache is non-null, then for each module_id
/// If it has already been compiled, reuse it with struct-copy, otherwise compile a new one in chunks_arena.
/// chunks_cache.items.len is ensured by caller to match bundle.modules.len.
fn compileWithColorAllocAndCache(
    arena_parent_alloc: std.mem.Allocator,
    color_pool_alloc: std.mem.Allocator,
    pool: *InternPool,
    bundle: *const ResolvedBundle,
    color_pool: *ColorPool,
    chunks_cache: ?*std.ArrayListUnmanaged(?ModuleChunks),
    chunks_arena: ?std.mem.Allocator,
    cache_backing_alloc: std.mem.Allocator,
) CompileError!Program {
    const t = perf.timeBegin();
    defer perf.timeEnd(.phase_compile_ns, t);
    var arena = std.heap.ArenaAllocator.init(arena_parent_alloc);
    errdefer arena.deinit();
    const a = arena.allocator();

    const mods = try a.alloc(ModuleChunks, bundle.modules.len);
    // Expand to bundle.modules.len (null padding) if chunks_cache is specified.
    if (chunks_cache) |cache| {
        while (cache.items.len < bundle.modules.len) {
            try cache.append(cache_backing_alloc, null);
        }
    }
    // chunks body alloc allocator: chunks_arena (long-lived) if persistent, otherwise
    // per-entry `a`.
    const chunks_data_alloc: std.mem.Allocator = chunks_arena orelse a;
    for (bundle.modules, 0..) |*rp, i| {
        // Plan C: In cross-entry persistent mode, the cumulative records of the previous entry are stored in bundle.modules.
        // If included, modules that cannot be reached from root are filled with stubs without being compiled.
        // Since the VM side skips with reachable_mask, the stub will not be executed.
        if (bundle.reachable_mask) |mask| {
            if (i < mask.len and !mask[i]) {
                mods[i] = makeStubModuleChunks();
                continue;
            }
        }
        //chunks_cache hit  ->  Reuse existing compile results with struct-copy (effective since it is on a long-lived arena).
        if (chunks_cache) |cache| {
            if (i < cache.items.len) {
                if (cache.items[i]) |cached| {
                    mods[i] = cached;
                    continue;
                }
            }
        }
        perf.note(.ir_compile_module);
        const compiled = try compileOneModule(arena_parent_alloc, chunks_data_alloc, bundle.modules, rp, @intCast(i), color_pool, color_pool_alloc, pool, bundle.shared_value_pools_alloc);
        mods[i] = compiled;
        if (chunks_cache) |cache| {
            if (i < cache.items.len) {
                cache.items[i] = compiled;
            }
        }
    }
    const seeds = try a.dupe(resolver.ConfigSeed, bundle.config_seeds);
    const static_eval_lists = try cloneValueSliceArray(a, bundle.static_eval_lists);
    const origins = try buildOrigins(a, bundle);

    // Plan C: reachable_mask has already been built from the resolve dep information on the bundle side, so clone it.
    // If bundle.reachable_mask is null (old route), build from byte code in post-compile.
    const reachable_mask: ?[]bool = if (bundle.reachable_mask) |mask|
        try a.dupe(bool, mask)
    else
        try buildReachableMask(a, mods, bundle.root_index);

    return .{
        .arena = arena,
        .modules = mods,
        .root_index = bundle.root_index,
        .origins = origins,
        .module_config_seeds = seeds,
        .static_eval_lists = static_eval_lists,
        .reachable_mask = reachable_mask,
        .shared_value_pools = bundle.shared_value_pools,
    };
}

/// stub ModuleChunks for unreachable modules. All fields are empty.
/// The VM skips reachable_mask so the stub is never executed.
fn makeStubModuleChunks() ModuleChunks {
    return .{
        .top = makeStubChunk(),
        .mixins = &.{},
        .functions = &.{},
        .content_blocks = &.{},
        .placeholder_blocks = &.{},
        .placeholder_targets = &.{},
        .global_slot_count = 0,
        .max_slot = 0,
    };
}

fn makeStubChunk() Chunk {
    return .{
        .code = &.{},
        .code_origin = &.{},
        .const_pool = &.{},
        .string_pool = &.{},
        .builtin_call_meta = &.{},
        .builtin_call_arg_names = &.{},
        .param_names = &.{},
        .param_defaults = &.{},
        .local_count = 0,
        .argc = 0,
        .arg_base = 0,
        .name = "",
    };
}

/// Scan the byte code after Compile with BFS to determine the reachable module.
/// Plan C (cross-entry artifact reuse): module from previous entry is mixed in bundle.modules
/// There is a possibility, but byte code that cannot be reached from root will be skipped by VM prologue.
fn buildReachableMask(arena: std.mem.Allocator, modules: []const ModuleChunks, root_index: u32) CompileError![]bool {
    const n = modules.len;
    const mask = try arena.alloc(bool, n);
    @memset(mask, false);
    if (n == 0) return mask;
    if (root_index >= n) return mask;

    // BFS: Follow module_id reference opcode in top.code of module on stack.
    var stack: std.ArrayListUnmanaged(u32) = .empty;
    defer stack.deinit(arena);
    try stack.ensureTotalCapacity(arena, n);
    stack.appendAssumeCapacity(root_index);
    mask[root_index] = true;

    while (stack.pop()) |cur| {
        const chunk = &modules[cur].top;
        for (chunk.code) |inst| {
            const dep_id: u32 = switch (inst.opcode()) {
                .run_dependency, .load_mod_global, .load_mod_global_strict => inst.arg_a,
                else => continue,
            };
            if (dep_id >= n) continue;
            if (mask[dep_id]) continue;
            mask[dep_id] = true;
            try stack.append(arena, dep_id);
        }
    }
    return mask;
}

pub const ParseResolveCompileResult = struct {
    pool: InternPool,
    color_pool: ColorPool,
    resolved: ResolvedBundle,
    program: Program,
};

pub const ParseResolveCompileBorrowedPoolResult = struct {
    color_pool: ColorPool,
    resolved: ResolvedBundle,
    program: Program,
    /// If True, color_pool is owned by persistent_state (does not deinit).
    /// If False, caller must deinit (default, single-entry/non-persistent).
    borrowed_color_pool: bool = false,
};

pub const PersistentCompileContext = struct {
    resolve_ctx: resolver.PersistentResolveContext,
    color_pool: *ColorPool,
    alloc: std.mem.Allocator,
    compiled_chunks: *std.ArrayListUnmanaged(?ModuleChunks),
    compile_arena: std.mem.Allocator,
};

const syntax_override_mod = @import("../runtime/syntax_override.zig");

pub fn parseResolveCompile(allocator: std.mem.Allocator, source: []const u8) !ParseResolveCompileResult {
    return parseResolveCompileWithPathAndPhaseTimer(allocator, source, null, &.{}, null, null);
}

const error_format = @import("../runtime/error_format.zig");

fn compileStderrPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    var err_file = std.Io.File.stderr();
    var w = err_file.writer(zsass_io.io, buf[0..]);
    w.interface.print(fmt, args) catch return;
    w.interface.flush() catch return;
}

/// CLI-FIX-E Step 1: Add debug line by phase (`zsass-compile phase=...`) to ZSASS_VERBOSE_ERRORS env
/// Gate with var. Default suppress for official Sass CLI compatibility. See src/runtime/error_format.zig.
inline fn verboseCompileErrorsEnabled() bool {
    return error_format.verboseErrorsEnabled();
}

pub fn parseResolveCompileWithPath(
    allocator: std.mem.Allocator,
    source: []const u8,
    source_path: []const u8,
    load_paths: []const []const u8,
) !ParseResolveCompileResult {
    return parseResolveCompileWithPathAndPhaseTimer(allocator, source, source_path, load_paths, null, null);
}

pub fn parseResolveCompileWithPathAndPhaseTimer(
    allocator: std.mem.Allocator,
    source: []const u8,
    source_path: ?[]const u8,
    load_paths: []const []const u8,
    phase_timer: ?*observe_mod.PhaseTimer,
    deprecation_opts: ?*deprecation_mod.DeprecationOpts,
) !ParseResolveCompileResult {
    var pool = try InternPool.init(allocator);
    errdefer pool.deinit(allocator);

    var borrowed = try parseResolveCompileWithPoolAndPhaseTimer(allocator, source, source_path, load_paths, phase_timer, &pool, deprecation_opts);
    errdefer borrowed.color_pool.deinit(allocator);
    errdefer borrowed.resolved.deinit();
    errdefer borrowed.program.deinit();

    return .{
        .pool = pool,
        .color_pool = borrowed.color_pool,
        .resolved = borrowed.resolved,
        .program = borrowed.program,
    };
}

fn parseResolveCompileWithPoolAndPhaseTimer(
    allocator: std.mem.Allocator,
    source: []const u8,
    source_path: ?[]const u8,
    load_paths: []const []const u8,
    phase_timer: ?*observe_mod.PhaseTimer,
    pool: *InternPool,
    deprecation_opts: ?*deprecation_mod.DeprecationOpts,
) !ParseResolveCompileBorrowedPoolResult {
    return parseResolveCompileWithPoolPhaseTimerAndCaches(allocator, source, source_path, load_paths, phase_timer, pool, null, null, deprecation_opts);
}

/// `parseResolveCompileWithPoolAndPhaseTimer` equivalent + worker over source_cache / ast_cache.
/// Passed from `compileFiles` in multi-entry CLI.
fn parseResolveCompileWithPoolPhaseTimerAndCaches(
    allocator: std.mem.Allocator,
    source: []const u8,
    source_path: ?[]const u8,
    load_paths: []const []const u8,
    phase_timer: ?*observe_mod.PhaseTimer,
    pool: *InternPool,
    source_cache: ?*source_cache_mod.SharedSourceCache,
    ast_cache: ?*ast_cache_mod.ParsedAstCache,
    deprecation_opts: ?*deprecation_mod.DeprecationOpts,
) !ParseResolveCompileBorrowedPoolResult {
    return parseResolveCompileWithPoolPhaseTimerCachesAndPersistent(allocator, source, source_path, load_paths, phase_timer, pool, source_cache, ast_cache, null, deprecation_opts);
}

/// Plan C: Final entry point for cross-entry resolve/compile artifact reuse.
/// If persistent_ctx is non-null, share records / id_by_path across workers,
/// At the resolve stage, hit the module with the same canonical path and skip re-resolve.
pub fn parseResolveCompileWithPoolPhaseTimerCachesAndPersistent(
    allocator: std.mem.Allocator,
    source: []const u8,
    source_path: ?[]const u8,
    load_paths: []const []const u8,
    phase_timer: ?*observe_mod.PhaseTimer,
    pool: *InternPool,
    source_cache: ?*source_cache_mod.SharedSourceCache,
    ast_cache: ?*ast_cache_mod.ParsedAstCache,
    persistent_ctx: ?PersistentCompileContext,
    deprecation_opts: ?*deprecation_mod.DeprecationOpts,
) !ParseResolveCompileBorrowedPoolResult {
    //Has persistent_ctx  ->  color_pool owns persistent state (retains color index across entries).
    //None  ->  alloc with per-call and free with errdefer.
    var owned_color_pool: ColorPool = .empty;
    errdefer if (persistent_ctx == null) owned_color_pool.deinit(allocator);
    const color_pool_ptr: *ColorPool = if (persistent_ctx) |ctx| ctx.color_pool else &owned_color_pool;

    const is_indented_syntax = if (syntax_override_mod.get()) |over|
        over == .sass
    else if (source_path) |p| blk: {
        if (p.len < 5) break :blk false;
        break :blk std.ascii.eqlIgnoreCase(p[p.len - 5 ..], ".sass");
    } else false;

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const parse_start: i128 = if (phase_timer != null) observe_mod.PhaseTimer.begin() else 0;
    const perf_parse_start = perf.timeBegin();
    var lexer = lexer_mod.Lexer.init(sa, source);
    lexer.source_name = source_path;
    lexer.is_indented_syntax = is_indented_syntax;
    defer lexer.deinit();
    const tokens = lexer.tokenize() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => {
            lexer.printLastErrorDiagnostic("SyntaxError");
            return error.SyntaxError;
        },
    };

    var parser = parser_mod.Parser.init(sa, pool, tokens, source);
    parser.is_indented_syntax = is_indented_syntax;
    parser.no_interpolation = !lexer.saw_interpolation;
    defer parser.deinit();
    var ast = parser.parse() catch |err| {
        if (verboseCompileErrorsEnabled()) {
            compileStderrPrint("zsass-compile phase=parse path={s} err={}\n", .{ source_path orelse "<anon>", err });
        }
        return err;
    };
    ast.is_indented_syntax = is_indented_syntax;
    defer ast.deinit();
    perf.timeEnd(.phase_parse_ns, perf_parse_start);
    if (phase_timer) |pt| pt.record(.parse, parse_start);

    const resolve_start: i128 = if (phase_timer != null) observe_mod.PhaseTimer.begin() else 0;
    var resolved = (if (source_path) |p|
        resolver.resolveWithEntryPathColorPoolCachesAndPersistent(allocator, &ast, pool, p, load_paths, color_pool_ptr, source_cache, ast_cache, if (persistent_ctx) |ctx| ctx.resolve_ctx else null, deprecation_opts)
    else
        resolver.resolveWithColorPool(allocator, &ast, pool, color_pool_ptr)) catch |err| {
        if (verboseCompileErrorsEnabled()) {
            compileStderrPrint("zsass-compile phase=resolve path={s} err={}\n", .{ source_path orelse "<anon>", err });
        }
        return err;
    };
    errdefer resolved.deinit();
    if (phase_timer) |pt| pt.record(.resolve, resolve_start);

    const compile_start: i128 = if (phase_timer != null) observe_mod.PhaseTimer.begin() else 0;
    //With persistent_ctx  ->  color_pool is shared across entries and grown with c_allocator.
    //None  ->  grow with per-entry allocator (same as compile arena).
    const compile_color_alloc: std.mem.Allocator = if (persistent_ctx) |ctx| ctx.alloc else allocator;
    // Step 6: With persistent, compilation results are also reused across entries.
    const chunks_cache_ptr: ?*std.ArrayListUnmanaged(?ModuleChunks) = if (persistent_ctx) |ctx|
        ctx.compiled_chunks
    else
        null;
    // long-lived arena for data in chunks (guaranteed slice lifetime of reused ModuleChunks).
    const chunks_arena_alloc: ?std.mem.Allocator = if (persistent_ctx) |ctx|
        ctx.compile_arena
    else
        null;
    //ArrayList backing alloc for chunks_cache is persistent alloc (c_allocator) -- for realloc efficiency.
    const cache_backing_alloc: std.mem.Allocator = if (persistent_ctx) |ctx| ctx.alloc else allocator;
    var program = compileWithColorAllocAndCache(allocator, compile_color_alloc, pool, &resolved, color_pool_ptr, chunks_cache_ptr, chunks_arena_alloc, cache_backing_alloc) catch |err| {
        if (verboseCompileErrorsEnabled()) {
            compileStderrPrint("zsass-compile phase=compile path={s} err={}\n", .{ source_path orelse "<anon>", err });
        }
        return err;
    };
    errdefer program.deinit();
    const pa = program.arena.allocator();
    program.load_paths = try cloneStringSliceArray(pa, load_paths);
    if (phase_timer) |pt| pt.record(.compile, compile_start);

    // If persistent, owned_color_pool is not used and remains empty (.empty).
    // Put SHALLOW COPY of persistent.color_pool into result.color_pool (copy only header).
    // Skip deinit with borrowed_color_pool=true.
    const out_color_pool: ColorPool = if (persistent_ctx) |ctx| ctx.color_pool.* else owned_color_pool;
    return .{
        .color_pool = out_color_pool,
        .resolved = resolved,
        .program = program,
        .borrowed_color_pool = persistent_ctx != null,
    };
}

test "compile: 1 + 2" {
    const src = "a { x: 1 + 2; }";
    var r = try parseResolveCompile(std.testing.allocator, src);
    defer r.pool.deinit(std.testing.allocator);
    defer r.color_pool.deinit(std.testing.allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    const code = r.program.rootMod().top.code;
    var saw_add = false;
    var saw_halt = false;
    var const1 = false;
    var const2 = false;
    for (code) |inst| {
        switch (inst.opcode()) {
            .add => saw_add = true,
            .halt => saw_halt = true,
            .load_const => {
                const idx: usize = @intCast(inst.arg_b);
                const v = r.program.rootMod().top.const_pool[idx];
                if (v.kind() == .number and @as(f64, @bitCast(v.p64Of())) == 1) const1 = true;
                if (v.kind() == .number and @as(f64, @bitCast(v.p64Of())) == 2) const2 = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_add);
    try std.testing.expect(saw_halt);
    try std.testing.expect(const1);
    try std.testing.expect(const2);
}

test "compile: mixin + include yields CALL_INDIRECT with mixin callable" {
    const src =
        \\@mixin m() { color: red; }
        \\.a { @include m; }
    ;
    var r = try parseResolveCompile(std.testing.allocator, src);
    defer r.pool.deinit(std.testing.allocator);
    defer r.color_pool.deinit(std.testing.allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    try std.testing.expectEqual(@as(usize, 1), r.program.rootMod().mixins.len);
    var saw_target = false;
    var saw_call = false;
    for (r.program.rootMod().top.code) |inst| {
        if (inst.opcode() == .load_const) {
            const idx: usize = @intCast(inst.arg_b);
            const v = r.program.rootMod().top.const_pool[idx];
            if (v.kind() == .callable and v.callableIsMixin(&r.program.shared_value_pools.?.callable_payload_pool) and v.callableHandle(&r.program.shared_value_pools.?.callable_payload_pool) == 0) {
                saw_target = true;
            }
        }
        if (inst.opcode() == .call_indirect and inst.arg_a == 1) {
            saw_call = true;
        }
    }
    try std.testing.expect(saw_target);
    try std.testing.expect(saw_call);
}

test "compile: recursive mixin in if-chain analysis terminates" {
    const src =
        \\@mixin btn-size($size, $min-width: null) {
        \\  @if $size == xxs {
        \\    font-size: 12px;
        \\    @include btn-size(20px);
        \\  } @else if $size == xs {
        \\    font-size: 12px;
        \\    @include btn-size(30px);
        \\  } @else if $size == sm {
        \\    font-size: 14px;
        \\    @include btn-size(40px);
        \\  }
        \\}
    ;
    var r = try parseResolveCompile(std.testing.allocator, src);
    defer r.pool.deinit(std.testing.allocator);
    defer r.color_pool.deinit(std.testing.allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    try std.testing.expectEqual(@as(usize, 1), r.program.rootMod().mixins.len);
}

test "compile: @if @else @return patches jmp offsets" {
    const src =
        \\@function f($x) {
        \\  @if $x {
        \\    @return 1;
        \\  } @else {
        \\    @return 2;
        \\  }
        \\}
    ;
    var r = try parseResolveCompile(std.testing.allocator, src);
    defer r.pool.deinit(std.testing.allocator);
    defer r.color_pool.deinit(std.testing.allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    try std.testing.expectEqual(@as(usize, 1), r.program.rootMod().functions.len);
    const code = r.program.rootMod().functions[0].code;
    for (code, 0..) |inst, pc| {
        switch (inst.opcode()) {
            .jmp, .jmp_if_false => {
                const off: i32 = @bitCast(inst.arg_b);
                const dst = @as(i64, @intCast(pc)) + 1 + @as(i64, off);
                try std.testing.expect(dst >= 0);
                try std.testing.expect(@as(usize, @intCast(dst)) < code.len);
            },
            else => {},
        }
    }
}
