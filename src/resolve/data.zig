const std = @import("std");
const origin_mod = @import("../runtime/origin.zig");
const value_mod = @import("../runtime/value.zig");
const intern_pool_mod = @import("../runtime/intern_pool.zig");
const source_cache_mod = @import("source_cache.zig");
const ast_cache_mod = @import("ast_cache.zig");
const deprecation_mod = @import("../runtime/deprecation.zig");
const preamble_checkpoint_mod = @import("preamble_checkpoint.zig");

const InternPool = intern_pool_mod.InternPool;
const InternId = intern_pool_mod.InternId;
const ListSeparator = value_mod.ListSeparator;
const CssOrigin = origin_mod.CssOrigin;
const OriginId = origin_mod.OriginId;

pub const SlotId = u32;
pub const MixinId = u32;
pub const FunctionId = u32;
pub const ExprIndex = u32;
pub const StmtIndex = u32;
/// Internal sentinel for `call_arg_names`.
/// `InternId.none` usually represents a positional arg, so use a different value to distinguish `$args...`.
pub const call_arg_splat_sentinel: InternId = @enumFromInt(std.math.maxInt(u32));
pub const media_prelude_has_interp_flag: u8 = 1;
pub const media_prelude_interp_at_start_flag: u8 = 2;
pub const media_prelude_compact_dynamic_feature_colon_flag: u8 = 4;

pub const Span = struct { start: u32, end: u32 };

pub const ResolveError = error{
    OutOfMemory,
    SassError,
    FatalDeprecation,
    /// Resolver internal invariant violation (safety net to use instead of assert even in Release build).
    InternalError,
    UnknownVar,
    UnknownMixin,
    /// Namespace-qualified call (e.g. `color.red(...)`) where namespace itself
    /// is not registered in `use_map` (no `@use "sass:color"` reached the resolver).
    UnknownFunctionNsMissing,
    /// Namespace resolves to a builtin module (sass:color etc.) but the function
    /// name is not exported by that module (alias missing / typo / not implemented).
    UnknownFunctionInBuiltinNs,
    /// Namespace resolves to a user module id but the loader cannot produce its exports
    /// (compile-phase failure of the referenced module).
    UnknownFunctionNoUserModule,
    /// Namespace resolves to a user module but the function name is not in its exports.
    UnknownFunctionInUserNs,
    /// Bare (unqualified) call where neither local fn, star-imported fn/builtin, nor
    /// legacy-global builtin registry resolved the name.
    UnknownFunctionGlobal,
    /// Cross-module static assignment encoding exceeded the 15-bit module / 16-bit slot budget.
    CrossAssignOverflow,
    /// User-module loader: `resolveUserModulePath` found no existing candidate file.
    UsermoduleNotFound,
    /// User-module loader: `@use`/`@forward` graph cycle (path already on the visiting stack).
    UsermoduleCircular,
    /// User-module loader: open/read of the resolved file failed (non-OOM).
    UsermoduleIoFailure,
    /// User-module loader: lexer failed on the child file source.
    UsermoduleLexFailure,
    /// User-module loader: parser failed on the child file.
    UsermoduleParseFailure,
    /// User-module loader: empty URL string for `@use`/`@forward`.
    UsermodulePathEmpty,
    /// Relative `@use` / `@forward` / Sass `@import` requires a caller file path.
    UsermoduleBasePathMissing,
    /// User-module loader: child parse succeeded but AST root is not `stylesheet_root`.
    UsermoduleRootMismatch,
    Unsupported,
};

pub fn spanStartLineColOneBased(source_len: usize, line_starts: []const u32, span_start: u32) struct { line: u32, col: u32 } {
    const offset: u32 = @min(span_start, @as(u32, @intCast(source_len)));
    if (line_starts.len == 0) {
        return .{ .line = 1, .col = offset + 1 };
    }
    var lo: usize = 0;
    var hi: usize = line_starts.len;
    while (lo + 1 < hi) {
        const mid = lo + (hi - lo) / 2;
        if (line_starts[mid] <= offset) lo = mid else hi = mid;
    }
    const line0: u32 = @intCast(lo);
    const col_base = line_starts[lo];
    const safe_offset = if (offset > source_len) @as(u32, @intCast(source_len)) else offset;
    const col0: u32 = if (safe_offset > col_base) safe_offset - col_base else 0;
    return .{ .line = line0 + 1, .col = col0 + 1 };
}
pub const CallableTarget = struct {
    module_id: u32,
    id: u32,
};
pub const VarTarget = struct {
    module_id: u32,
    slot: SlotId,
};

pub const BinOp = enum(u8) { add, sub, mul, div, mod, eq, neq, lt, gt, le, ge, and_op, or_op };
pub const UnaryOp = enum(u8) {
    neg,
    pos,
    slash_prefix,
    not_op,
};

pub const ExprKind = enum(u8) {
    literal_number,
    literal_string,
    literal_color,
    literal_bool,
    literal_null,
    var_ref,
    binary,
    unary,
    call,
    interp,
    list,
    if_builtin,
    builtin_call,
    cross_var_ref,
    sass_error,
};

pub const LiteralColor = struct {
    rgba: u32,
    /// Precise alpha for colors that came from evaluated Sass color values
    /// such as `rgba(0, 0, 0, .3)`. Hex literals intentionally leave this as
    /// NaN so their serialized alpha stays byte-derived.
    alpha: f64,
    /// parser `expr_color_hex` flags:
    /// bit0: long form (6/8 digits)
    /// bit1: uppercase hex digit was present
    /// bit2: alpha-bearing form (4/8 digits)
    flags: u8,
};

pub const PreboundCallableKind = enum(u2) {
    none,
    function,
    mixin,
};

pub const ResolvedExpr = struct {
    kind: ExprKind,
    payload: u32,
    span: Span,
};

pub const StmtKind = enum(u8) {
    rule,
    declaration,
    at_rule,
    comment,
    module_dep,
    if_chain,
    for_loop,
    each_loop,
    while_loop,
    include,
    content_call,
    extend,
    return_stmt,
    assign_var,
    debug_stmt,
    warn_stmt,
    error_stmt,
    noop,
};

pub const ResolvedStmt = struct {
    kind: StmtKind,
    payload: u32,
    span: Span,
    origin_id: OriginId = .invalid,
};

pub const SelectorRuleKind = enum { literal, dynamic };
pub const DeclPropKind = enum { literal, dynamic };

pub const RuleData = struct {
    selector_kind: SelectorRuleKind,
    /// `selector_kind == .literal`
    literal_intern: InternId,
    /// `%placeholder` single selector (minimal extend targetable form)
    is_placeholder: bool,
    /// selector helper syntax validation result for `selector_kind == .literal`.
    /// If `false`, compile continues and the runtime side refers to this result and returns SassError.
    literal_selector_syntax_valid: bool = true,
    /// Plain-CSS rule from `*.css` source. selector synthesis/child hoist
    /// Tell compile/runtime to separate it from Sass rules.
    is_plain_css: bool = false,
    /// Case where plain-CSS top-level rule is inlined in Sass parent selector context
    /// (such as `a {@import "plain"}`). Only when there is no `&` in raw selector, only one stage is combined with parent.
    plain_css_parent_selector_combine: bool = false,
    /// A true top-level rule for plain-CSS (such as directly under `@use "plain"`). direct child
    /// Hoist block at-rule into `@media { a { ... } }` form.
    plain_css_hoist_block_at_rules: bool = false,
    /// Selector prefix (literal case) that can be treated as `prop-namespace: ... { ... }`.
    /// `.none` if not applicable.
    prop_namespace_prefix: InternId = .none,
    /// `prop-namespace` prefix expression (`foo` / `#{$foo}`).
    /// Null if not applicable.
    prop_namespace_prefix_expr: ?ExprIndex = null,
    /// `<expr>` in `prop-namespace: <expr>`. Null if not applicable.
    prop_namespace_value_expr: ?ExprIndex = null,
    /// `selector_kind == .dynamic` -- index into `selector_part_exprs`
    dynamic_parts_start: u32,
    dynamic_parts_count: u32,
    /// Direct AST children only (decl / @for / nested rule as one stmt each).
    body_direct: []StmtIndex,
};

pub const AtRootBehavior = enum {
    none,
    without_media,
    without_layer,
    without_supports,
    without_media_supports,
    without_all,
    with_rule,
    with_media,
    with_layer,
    with_supports,
    with_media_supports,
    with_all,
};

pub const ResolvedContentBlock = struct {
    id: u32,
    param_names: []InternId,
    param_slots: []SlotId,
    defaults: []?ExprIndex,
    has_rest: bool = false,
    global_slot_base: u32 = 0,
    local_count: u32,
    body_roots: []StmtIndex,
};

pub const FlowLocalFallback = struct {
    slot: SlotId,
    fallback: SlotId,
};

pub const CommentData = struct {
    text_intern: InternId,
    text_expr: ?ExprIndex = null,
    /// source column (0-indexed) for `/*`. `@import` inline with `cb.module_id`
    /// Files in `span.start` are inconsistent, col calculation via `source_file_id`
    /// Calculate directly from the AST source at the resolver point, as it may be inaccurate.
    /// Save it. Used to determine the dedent width of loud comment continuation lines (rule_ir emitCommentNode).
    source_col: u32 = 0,
    /// Immediately before `/*` (immediately before span.start) there is a non-whitespace character in the same source line.
    /// Exists or not. true = same line as preceding token (`foo: bar; /* ... */` or
    /// `} /* ... */`), false = only whitespace at the beginning of the line (comment is on your own line)
    /// exists alone). Calculated by backward scanning ast.source at resolver point.
    /// In @import inline, parent module's line_starts has incorrect child file coordinates.
    /// Even if it is determined that they are the same line, the value given here is correct. inlineCommentAfter
    // Used to correct block-end same-line checks for inline @import chunks.
    leading_same_line: bool = false,
};

pub const DeclData = struct {
    prop_kind: DeclPropKind,
    prop_intern: InternId,
    prop_parts_start: u32,
    prop_parts_count: u32,
    value_expr: ExprIndex,
    important: bool,
    emit_decl_flags: u16 = 0,
    raw_value_source_intern: InternId = .none,
};

pub const ResolvedMixin = struct {
    id: MixinId,
    name: InternId,
    param_names: []InternId,
    param_slots: []SlotId,
    defaults: []?ExprIndex,
    has_rest: bool = false,
    global_slot_base: u32 = 0,
    local_count: u32,
    /// stmt root corresponding to each immediate AST child of the block (return value of `resolveStmt`). Not a continuous `prog.stmts` interval.
    body_roots: []StmtIndex,
    accepts_content: bool,
    captures_callers_locals: bool = false,
};

pub const ResolvedFunction = struct {
    id: FunctionId,
    name: InternId,
    param_names: []InternId,
    param_slots: []SlotId,
    defaults: []?ExprIndex,
    has_rest: bool = false,
    global_slot_base: u32 = 0,
    local_count: u32,
    body_roots: []StmtIndex,
    captures_callers_locals: bool = false,
};

pub const ResolvedProgram = struct {
    arena: std.heap.ArenaAllocator,
    exprs: std.ArrayListUnmanaged(ResolvedExpr) = .empty,
    binary_exprs: std.ArrayListUnmanaged(struct { lhs: ExprIndex, rhs: ExprIndex, op: BinOp }) = .empty,
    unary_exprs: std.ArrayListUnmanaged(struct { operand: ExprIndex, op: UnaryOp }) = .empty,
    call_exprs: std.ArrayListUnmanaged(struct {
        callee_module: u32,
        callee_id: u32,
        callee_name: InternId = .none,
        callee_is_css: bool = false,
        callee_css_late_sass_resolution: bool = false,
        callee_capture_callers_locals: bool = false,
        arg_start: u32,
        arg_count: u32,
    }) = .empty,
    builtin_calls: std.ArrayListUnmanaged(struct {
        builtin_id: u32,
        arg_start: u32,
        arg_count: u32,
        /// `meta.variable-exists($name)` Optimization: scoped local slot in call-site.
        /// `std.math.maxInt(u32)` when unresolved.
        local_slot_hint: u32 = std.math.maxInt(u32),
        prebound_kind: PreboundCallableKind = .none,
        prebound_module: u32 = std.math.maxInt(u32),
        prebound_id: u32 = 0,
        prebound_accepts_content: bool = false,
        prebound_capture_callers_locals: bool = false,
        prebound_name: InternId = .none,
    }) = .empty,
    cross_var_refs: std.ArrayListUnmanaged(struct { module_id: u32, slot: SlotId }) = .empty,
    list_exprs: std.ArrayListUnmanaged(struct {
        elem_start: u32,
        elem_count: u32,
        separator: ListSeparator,
        bracketed: bool,
        is_map: bool = false,
        slash_coercible: bool = false,
    }) = .empty,
    interp_exprs: std.ArrayListUnmanaged(struct {
        part_start: u32,
        part_count: u32,
        preserve_quote: bool = false,
        source_name_has_interp: bool = false,
        source_args_have_interp: bool = false,
        error_on_undeclared_var: bool = false,
    }) = .empty,
    call_args: std.ArrayListUnmanaged(ExprIndex) = .empty,
    /// Parallel to `call_args`:
    /// - `InternId.none` = positional
    /// - `call_arg_splat_sentinel` = positional splat (`$args...`)
    /// - otherwise keyword name
    call_arg_names: std.ArrayListUnmanaged(InternId) = .empty,
    list_elems: std.ArrayListUnmanaged(ExprIndex) = .empty,
    interp_parts: std.ArrayListUnmanaged(ExprIndex) = .empty,
    /// sidecar NumberPool for Static-eval Value (P4 stage 2 prep, c3 retry A.2).
    /// number Value generated by static evaluation when Value layout is converted to NaN-box in stage 3
    /// Hold f64+unit. In stage 2, pool is no-op (number is
    /// Ignore the pool argument and write it to in-Value bits).
    /// **shared pool**: pointer is ResolvedBundle (single-entry)/PersistentResolverState
    /// (multi-entry) Points to the owned `SharedValuePoolStorage`. All modules share the same pool
    /// Avoid cross-module Value handle collision (root cause of previous Step B failure) by sharing
    /// Structurally excluded. ResolvedProgram.deinit does not free pool storage.
    value_number_pool: *value_mod.NumberPool,
    /// sidecar ListMetaPool (shared pool, same as above) for Static-eval Value.
    value_list_meta_pool: *value_mod.ListMetaPool,
    /// sidecar StringFlagsPool (shared pool, same as above) for Static-eval Value.
    value_string_flags_pool: *value_mod.StringFlagsPool,
    /// sidecar CallablePayloadPool (shared pool, same as above) for Static-eval Value.
    /// Payload that callable Value holds via 32-bit handle in NaN-box stage 3.
    value_callable_payload_pool: *value_mod.CallablePayloadPool,
    /// literal_number: payload indexes here (f64 bits split + unit InternId).
    number_pool: std.ArrayListUnmanaged(struct { lo: u32, hi: u32, unit_id: InternId }) = .empty,
    /// literal_color: payload indexes here (rgba + literal representation hints).
    color_literals: std.ArrayListUnmanaged(LiteralColor) = .empty,
    /// resolve-time static evaluator cache (slot -> value).
    static_slot_values: std.ArrayListUnmanaged(struct { slot: SlotId, value: value_mod.Value }) = .empty,
    /// "Fallback when undeclared" (slot -> outer visible slot) when creating a new local with Flow-control.
    /// VM `.load_local` uses fallback only on the first read with `declared=false`.
    flow_local_fallbacks: std.ArrayListUnmanaged(FlowLocalFallback) = .empty,

    stmts: std.ArrayListUnmanaged(ResolvedStmt) = .empty,

    rule_stmts: std.ArrayListUnmanaged(RuleData) = .empty,
    /// Flat parts for dynamic selectors (literal_string + arbitrary expr per segment).
    selector_part_exprs: std.ArrayListUnmanaged(ExprIndex) = .empty,

    decl_stmts: std.ArrayListUnmanaged(DeclData) = .empty,
    at_rule_stmts: std.ArrayListUnmanaged(struct {
        name_intern: InternId,
        prelude_expr: ?ExprIndex,
        media_flags: u8 = 0,
        is_plain_css: bool = false,
        at_root_behavior: AtRootBehavior = .none,
        body_direct: []StmtIndex,
        had_block: bool,
    }) = .empty,
    comment_stmts: std.ArrayListUnmanaged(CommentData) = .empty,
    module_dep_stmts: std.ArrayListUnmanaged(struct {
        module_id: u32,
        /// true when emitted from an `@import`-expanded child context.
        /// Runtime should rerun this dependency at each callsite.
        rerun_each_call: bool = false,
        /// true when this dependency comes from `@forward` (vs `@use`).
        /// Usage: Specification to replay the preceding loud comment on the second visit
        /// (`@forward` only; via `@use` dep's preceding comment is module-local
        /// Since it is a context, if it leaks to the right path with the diamond pattern, it will violate the spec).
        is_forward: bool = false,
    }) = .empty,
    decl_prop_part_exprs: std.ArrayListUnmanaged(ExprIndex) = .empty,
    if_stmts: std.ArrayListUnmanaged(struct { branches_start: u32, branches_count: u32 }) = .empty,
    if_branches: std.ArrayListUnmanaged(struct { cond_expr: ?ExprIndex, body_start: StmtIndex, body_len: u32 }) = .empty,
    for_stmts: std.ArrayListUnmanaged(struct {
        slot: SlotId,
        cursor_slot: SlotId,
        to_slot: SlotId,
        step_slot: SlotId,
        from_expr: ExprIndex,
        to_expr: ExprIndex,
        through: bool,
        body_start: StmtIndex,
        body_len: u32,
    }) = .empty,
    each_stmts: std.ArrayListUnmanaged(struct {
        slot_start: u32,
        slot_count: u32,
        list_temp_slot: SlotId,
        index_slot: SlotId,
        list_expr: ExprIndex,
        body_start: StmtIndex,
        body_len: u32,
    }) = .empty,
    while_stmts: std.ArrayListUnmanaged(struct {
        cond_expr: ExprIndex,
        body_start: StmtIndex,
        body_len: u32,
    }) = .empty,
    each_slots: std.ArrayListUnmanaged(SlotId) = .empty,
    include_stmts: std.ArrayListUnmanaged(struct {
        callee_module: u32,
        mixin_id: MixinId,
        callee_name: InternId = .none,
        capture_callers_locals: bool = false,
        arg_start: u32,
        arg_count: u32,
        content_block: u32,
    }) = .empty,
    content_stmts: std.ArrayListUnmanaged(struct { arg_start: u32, arg_count: u32 }) = .empty,
    extend_stmts: std.ArrayListUnmanaged(struct {
        target_selector: InternId,
        target_module: u32,
        optional: bool,
        target_is_placeholder: bool,
        target_dynamic: bool = false,
        dynamic_parts_start: u32 = 0,
        dynamic_parts_count: u32 = 0,
    }) = .empty,
    content_blocks: std.ArrayListUnmanaged(ResolvedContentBlock) = .empty,
    return_stmts: std.ArrayListUnmanaged(struct { value_expr: ExprIndex }) = .empty,
    assign_stmts: std.ArrayListUnmanaged(struct { slot: SlotId, value_expr: ExprIndex, default: bool, global: bool }) = .empty,

    mixins: std.ArrayListUnmanaged(ResolvedMixin) = .empty,
    functions: std.ArrayListUnmanaged(ResolvedFunction) = .empty,
    mixin_names: std.StringHashMapUnmanaged(MixinId) = .empty,
    function_names: std.StringHashMapUnmanaged(FunctionId) = .empty,

    global_slots: std.StringHashMapUnmanaged(SlotId) = .empty,
    /// Canonical (all-dash) key -> slot for the global names that contain both
    /// `-` and `_`. Such keys are unreachable through the two spelling-variant
    /// probes, so `lookupGlobalSlot` resolves them with one hash probe here
    /// instead of scanning `global_slots`. Almost always empty.
    global_slots_mixed_alias: std.StringHashMapUnmanaged(SlotId) = .empty,
    /// Global variable name to be exposed as an actual module member.
    /// Do not include auxiliary slots created by unresolved references in callables.
    declared_global_names: std.StringHashMapUnmanaged(void) = .empty,
    /// Top-level `!default` variable (name -> slot).
    default_vars: std.StringHashMapUnmanaged(SlotId) = .empty,
    /// Set from `@use` (namespace string  ->  binding).
    use_map: std.StringHashMapUnmanaged(UseBinding) = .empty,
    /// Variable metadata (for runtime meta.*) included with `@use "...\" as *`.
    star_vars: std.StringHashMapUnmanaged(VarTarget) = .empty,
    /// Variable name that conflicted with `@use "...\" as *` (for meta.global-variable-exists conflict determination).
    ambiguous_star_vars: std.StringHashMapUnmanaged(void) = .empty,
    /// Callable metadata (for runtime meta.*) captured with `@use "...\" as *`.
    star_mixins: std.StringHashMapUnmanaged(CallableTarget) = .empty,
    /// Mixin name that conflicted with `@use "...\" as *`. Converts to a SassError only when actually referenced.
    ambiguous_star_mixins: std.StringHashMapUnmanaged(void) = .empty,
    star_functions: std.StringHashMapUnmanaged(CallableTarget) = .empty,
    /// Function name that conflicted with `@use "...\" as *`. Converts to a SassError only when actually referenced.
    ambiguous_star_functions: std.StringHashMapUnmanaged(void) = .empty,
    star_builtin_fns: std.StringHashMapUnmanaged(u32) = .empty,
    exported_mixins: std.StringHashMapUnmanaged(CallableTarget) = .empty,
    /// `@forward` Conflicted mixin name in export. Generates SassError only during namespaced lookup.
    ambiguous_export_mixins: std.StringHashMapUnmanaged(void) = .empty,
    exported_functions: std.StringHashMapUnmanaged(CallableTarget) = .empty,
    /// `@forward` Conflicted function name in export. Generates SassError only during namespaced lookup.
    ambiguous_export_functions: std.StringHashMapUnmanaged(void) = .empty,
    exported_builtin_fns: std.StringHashMapUnmanaged(u32) = .empty,
    /// Public variable name that can be referenced from this module -> entity variable slot.
    /// (Public name base including `@forward`, reverse lookup possible with module_id/slot)
    exported_vars: std.StringHashMapUnmanaged(VarTarget) = .empty,
    /// `@forward` Conflicted variable name in export. Generates SassError only during namespaced lookup.
    ambiguous_export_vars: std.StringHashMapUnmanaged(void) = .empty,
    /// Export name -> entity variable slot configurable from this module.
    /// (Public name base including `@forward`, reverse lookup possible with module_id/slot)
    exported_default_vars: std.StringHashMapUnmanaged(VarTarget) = .empty,
    /// Conflicting configurable export name in `@forward` export. Generates SassError only when with()/load-css.
    ambiguous_export_default_vars: std.StringHashMapUnmanaged(void) = .empty,
    next_global_slot: SlotId = 0,
    /// Highest used slot index + 1 (frame size for top-level chunk).
    max_slot: SlotId = 0,

    /// Direct children of the stylesheet root (indices into `stmts`). Nested bodies live in
    /// `stmts` too but are reached via `rule_stmts` / `each_stmts` / `for_stmts`, not this list.
    top_stmts: []StmtIndex = &.{},
    /// Source file path for this module (absolute path when entry path resolver is used).
    /// Runtime builtin mixins (meta.load-css) use this as the base directory for relative lookup.
    module_path: []const u8 = "",
    /// 0-indexed line start byte offsets in source text (first entry is always 0).
    line_starts: []u32 = &.{},
    /// Source byte length (for span clamping during source-map projection).
    source_len: u32 = 0,

    pub fn deinit(self: *ResolvedProgram) void {
        const alloc = self.arena.allocator();
        self.exprs.deinit(alloc);
        self.binary_exprs.deinit(alloc);
        self.unary_exprs.deinit(alloc);
        self.call_exprs.deinit(alloc);
        self.builtin_calls.deinit(alloc);
        self.cross_var_refs.deinit(alloc);
        self.list_exprs.deinit(alloc);
        self.interp_exprs.deinit(alloc);
        self.call_args.deinit(alloc);
        self.call_arg_names.deinit(alloc);
        self.list_elems.deinit(alloc);
        self.interp_parts.deinit(alloc);
        self.number_pool.deinit(alloc);
        // value_*_pool is shared owned by ResolvedBundle / PersistentResolverState
        // Since it is a pointer pointing to storage, it will not be freed on the ResolvedProgram side (P4 c3 retry A.2).
        self.color_literals.deinit(alloc);
        self.static_slot_values.deinit(alloc);
        self.flow_local_fallbacks.deinit(alloc);
        self.stmts.deinit(alloc);
        self.rule_stmts.deinit(alloc);
        self.selector_part_exprs.deinit(alloc);
        self.decl_stmts.deinit(alloc);
        self.at_rule_stmts.deinit(alloc);
        self.comment_stmts.deinit(alloc);
        self.module_dep_stmts.deinit(alloc);
        self.decl_prop_part_exprs.deinit(alloc);
        self.if_stmts.deinit(alloc);
        self.if_branches.deinit(alloc);
        self.for_stmts.deinit(alloc);
        self.each_stmts.deinit(alloc);
        self.while_stmts.deinit(alloc);
        self.each_slots.deinit(alloc);
        self.include_stmts.deinit(alloc);
        self.content_stmts.deinit(alloc);
        self.extend_stmts.deinit(alloc);
        self.content_blocks.deinit(alloc);
        self.return_stmts.deinit(alloc);
        self.assign_stmts.deinit(alloc);
        self.mixins.deinit(alloc);
        self.functions.deinit(alloc);
        self.mixin_names.deinit(alloc);
        self.function_names.deinit(alloc);
        self.global_slots.deinit(alloc);
        self.global_slots_mixed_alias.deinit(alloc);
        self.declared_global_names.deinit(alloc);
        self.default_vars.deinit(alloc);
        self.use_map.deinit(alloc);
        self.star_vars.deinit(alloc);
        self.ambiguous_star_vars.deinit(alloc);
        self.star_mixins.deinit(alloc);
        self.ambiguous_star_mixins.deinit(alloc);
        self.star_functions.deinit(alloc);
        self.ambiguous_star_functions.deinit(alloc);
        self.star_builtin_fns.deinit(alloc);
        self.exported_mixins.deinit(alloc);
        self.ambiguous_export_mixins.deinit(alloc);
        self.exported_functions.deinit(alloc);
        self.ambiguous_export_functions.deinit(alloc);
        self.exported_builtin_fns.deinit(alloc);
        self.exported_vars.deinit(alloc);
        self.ambiguous_export_vars.deinit(alloc);
        self.exported_default_vars.deinit(alloc);
        self.ambiguous_export_default_vars.deinit(alloc);
        self.arena.deinit();
    }
};

pub const UseBinding = union(enum) {
    /// `sass:math`  ->  slice `"math"` (from InternPool).
    builtin_module: []const u8,
    /// `@use "path" as ns`
    user_module: u32,
};

pub const local_module_id_sentinel: u32 = std.math.maxInt(u32);
pub const apply_mixin_sentinel: u32 = std.math.maxInt(u32) - 1;
pub const load_css_mixin_sentinel: u32 = std.math.maxInt(u32) - 2;

pub const ConfigSeed = struct {
    module_id: u32,
    slot: SlotId,
    value: value_mod.Value,
};

pub fn packConfigSeedKey(module_id: u32, slot: SlotId) u64 {
    return (@as(u64, module_id) << 32) | @as(u64, slot);
}

pub fn unpackConfigSeedKey(key: u64) struct { module_id: u32, slot: SlotId } {
    return .{
        .module_id = @intCast(key >> 32),
        .slot = @intCast(key & 0xffff_ffff),
    };
}

/// static-eval Value sidecar pool storage (P4 c3 retry A.2) shared by all modules.
/// Single owner (single-entry: ResolvedBundle, multi-entry persistent:
/// PersistentResolverState) has embed inline and ModuleResolver / ResolvedProgram
/// is referenced via pointer. The owner structure itself is heap-allocated for pointer stability.
/// (PersistentResolverState is caller heap, ResolvedBundle is field on heap).
pub const SharedValuePoolStorage = struct {
    number_pool: value_mod.NumberPool = .empty,
    list_meta_pool: value_mod.ListMetaPool = .empty,
    string_flags_pool: value_mod.StringFlagsPool = .empty,
    callable_payload_pool: value_mod.CallablePayloadPool = .empty,

    pub fn deinit(self: *SharedValuePoolStorage, alloc: std.mem.Allocator) void {
        self.number_pool.deinit(alloc);
        self.list_meta_pool.deinit(alloc);
        self.string_flags_pool.deinit(alloc);
        self.callable_payload_pool.deinit(alloc);
    }
};

pub const ResolvedBundle = struct {
    modules: []ResolvedProgram,
    root_index: u32,
    import_origins: []CssOrigin = &.{},
    /// Backing storage for `import_origins[*].source_path`. All entry paths are
    /// concatenated back-to-back; each origin holds a borrowed slice into this
    /// buffer. A single `free(import_origin_path_bytes)` releases every path.
    import_origin_path_bytes: []u8 = &.{},
    /// Backing storage for `import_origins[*].preamble_comment_ids`, sharing
    /// the same flat-buffer pattern as `import_origin_path_bytes`.
    import_origin_id_bytes: []u32 = &.{},
    config_seeds: []ConfigSeed = &.{},
    static_eval_lists: []const []const value_mod.Value = &.{},
    alloc: std.mem.Allocator,
    /// Reachable mask for cross-entry artifact reuse (plan C).
    /// Same length as modules.len. module reachable via BFS from root_index is true,
    /// Otherwise (relict from previous entry) false. VM prologue gates with mask.
    /// Null for non-persistent (single-entry) paths (VM side works without mask).
    /// Design: `.plans/ideal/20260502-cross-entry-resolve-reuse-design.md`
    reachable_mask: ?[]bool = null,
    /// Per-entry module ordinal for @extend module-group ordering. Maps module
    /// id -> the dependency post-order position a fresh single-entry resolve
    /// would assign, maxInt(u32) when the module is not reachable through
    /// module_dep_stmts. With cross-entry persistent records the raw module id
    /// order reflects the resolve history of earlier entries, so sorting by it
    /// is not deterministic per entry; this table restores the per-entry order.
    module_extend_group_order: []u32 = &.{},
    /// True if modules / reachable_mask is owned by persistent state (does not free on deinit).
    /// False for non-persistent (single-entry) (free on deinit).
    persistent_modules: bool = false,
    /// Shared static-eval Value pool (P4 c3 retry A.2). module everything
    /// Have a pointer to this pool (`ResolvedProgram.value_*_pool`).
    /// non-persistent: bundle owns storage on heap, free on deinit.
    /// persistent: Owns PersistentResolverState, bundle only keeps pointer and does not free on deinit.
    shared_value_pools: *SharedValuePoolStorage,
    /// Allocator used for deinit of `shared_value_pools`. Required if owner_pools is true.
    /// non-persistent: top-level allocator, persistent: PS.alloc (optional as it is not used in the deinit route).
    shared_value_pools_alloc: std.mem.Allocator,
    /// If true, bundle.deinit frees `shared_value_pools` (single-entry only).
    owns_shared_value_pools: bool = false,

    pub fn deinit(self: *ResolvedBundle) void {
        if (!self.persistent_modules) {
            for (self.modules) |*m| m.deinit();
        }
        // The modules slice itself is owned by the bundle (even when it is persistent, a new alloc is made for each entry).
        self.alloc.free(self.modules);
        if (self.reachable_mask) |mask| {
            self.alloc.free(mask);
            self.reachable_mask = null;
        }
        if (self.module_extend_group_order.len != 0) {
            self.alloc.free(self.module_extend_group_order);
            self.module_extend_group_order = &.{};
        }
        if (self.import_origins.len != 0) {
            self.alloc.free(self.import_origins);
        }
        if (self.import_origin_path_bytes.len != 0) {
            self.alloc.free(self.import_origin_path_bytes);
        }
        if (self.import_origin_id_bytes.len != 0) {
            self.alloc.free(self.import_origin_id_bytes);
        }
        if (self.config_seeds.len != 0) self.alloc.free(self.config_seeds);
        if (self.static_eval_lists.len != 0) self.alloc.free(self.static_eval_lists);
        self.import_origins = &.{};
        self.import_origin_path_bytes = &.{};
        self.import_origin_id_bytes = &.{};
        self.config_seeds = &.{};
        self.static_eval_lists = &.{};
        if (self.owns_shared_value_pools) {
            self.shared_value_pools.deinit(self.shared_value_pools_alloc);
            self.shared_value_pools_alloc.destroy(self.shared_value_pools);
            self.owns_shared_value_pools = false;
        }
    }
};

pub const ModuleResolver = struct {
    alloc: std.mem.Allocator,
    meta: std.mem.Allocator,
    pool: *InternPool,
    color_pool: ?*value_mod.ColorPool = null,
    /// User module search root column passed from embedder. `from_path` dir When relative and undiscovered
    /// Scan in order. Ownership is on the caller (spec_runner, etc.) side -- only retained within self.
    load_paths: []const []const u8 = &.{},
    /// official Sass CLI parity: `pkg:` URL resolution is rejected unless this is
    /// `true`. The CLI sets it via `--pkg-importer=node`; embedders set it
    /// through `CompileOptions.pkg_importer_enabled`. Defaults to `false`
    /// so an untrusted SCSS input cannot read host packages by default.
    pkg_importer_enabled: bool = false,
    /// Worker over source shared cache (optional). Multiple entries with the same partial using multi-entry CLI
    /// Eliminate disk IO duplication when `@import`. Allocate worker thread with driver.compileFiles
    // Expected to pass pointer to ///. null for single-entry / embedding routes.
    source_cache: ?*source_cache_mod.SharedSourceCache = null,
    /// parsed AST shared cache across workers (optional). Same partial lex/parse cost
    /// Aggregate all entries once. When a cache hit occurs, just borrow the AST of the entry.
    /// Go straight to the resolve stage. Secured in driver.compileFiles like source_cache.
    ast_cache: ?*ast_cache_mod.ParsedAstCache = null,
    /// When non-null, Sass `@import` and similar emit dart-compatible deprecation diagnostics.
    deprecation_opts: ?*deprecation_mod.DeprecationOpts = null,

    /// records / id_by_path / module path key dupe / allocator for alloc in ModuleExports.
    /// Same meta_arena as `self.meta` by default (single-entry).
    /// long-lived owned by PersistentResolverState when cross-entry artifact reuse
    /// Pass arena (because records are kept across entries).
    /// Design: `.plans/ideal/20260502-cross-entry-resolve-reuse-design.md`
    records_alloc: std.mem.Allocator,
    /// child_allocator in ResolvedProgram.arena. records[i].prog is reused across entries
    /// child_allocator must be long-lived. For single-entry, `self.alloc` (= usually c_allocator),
    /// PersistentResolverState.alloc (= c_allocator) for persistent.
    /// If you use `self.alloc` directly, multi-entry CLI's per-entry arena_alloc becomes child_allocator.
    /// This results in an accident where the backing buffer of prog.arena is wiped by arena.reset at the end of entry.
    prog_arena_alloc: std.mem.Allocator,
    /// A pointer to records storage. `&self.records_storage` for single-entry,
    /// For multi-entry persistent, point to records owned by PersistentResolverState.
    /// Initial value undefined. Always use `bindRecordsToSelf()` or
    /// Call `bindRecordsToPersistent()` to set.
    records_ptr: *std.ArrayListUnmanaged(ModuleRecord),
    /// Pointer to id_by_path storage (same owner as records_ptr).
    id_by_path_ptr: *std.StringHashMapUnmanaged(u32),
    /// Inline storage for default single-entry. Where records_ptr points to.
    records_storage: std.ArrayListUnmanaged(ModuleRecord) = .empty,
    id_by_path_storage: std.StringHashMapUnmanaged(u32) = .empty,
    /// If True, records / id_by_path is owned by self, so it is freed with deinitAll.
    /// If False, it is owned by PersistentResolverState, so keep it (used in Step 3 actual).
    records_owned: bool = true,
    /// records_ptr.items.len at the start of resolve for this entry. In cross-entry persistent mode
    /// Criteria for identifying "modules that were already loaded in the prior entry". module_id < entry_records_baseline
    /// is resolved in another entry, allowing `@use ... with (...)` (in the Sass specification
    /// Because each compilation is independent but shares persistent records).
    /// 0 for single entry/non-persistent.
    entry_records_baseline: u32 = 0,
    /// Access to import_origins via this pointer. In single-entry
    /// `&self.import_origins_storage`, owned by PersistentResolverState in multi-entry persistent.
    /// Initial value undefined. Always use `bindRecordsToSelf()` or
    /// Set with `bindRecordsToPersistent()`.
    import_origins_ptr: *std.ArrayListUnmanaged(CssOrigin),
    import_origins_storage: std.ArrayListUnmanaged(CssOrigin) = .empty,
    /// Per-worker import-preamble checkpoint store. Non-null only while
    /// resolving a non-persistent batch entry; consumed by the entry root's
    /// `resolveSingleAst` so child module resolves never see it.
    preamble_store: ?*preamble_checkpoint_mod.PreambleCheckpointStore = null,
    visiting: std.ArrayListUnmanaged([]const u8) = .empty,
    config_seed_accum: std.AutoHashMapUnmanaged(u64, ConfigSeedAccum) = .empty,
    /// Direct `@use ... with` / `@forward ... with` entries for the next module
    /// being resolved. This is consumed by module_loader when it enters that
    /// module, then exposed as `active_initial_config_entries` only while that
    /// module's AST is being resolved.
    pending_next_config_entries: []const WithConfigEntry = &.{},
    active_initial_config_entries: []const WithConfigEntry = &.{},
    static_eval_store: StaticEvalListStore,
    /// Static-eval Value sidecar pool storage pointer (P4 c3 retry A.2).
    /// ResolvedProgram.value_*_pool of all modules share the same storage.
    /// Ownership: In single-entry, MR heap allocation and transfer to bundle when building bundle,
    /// Persistent owns PersistentResolverState (MR/bundle is pointer only).
    shared_value_pools: *SharedValuePoolStorage,
    /// Allocator used for deinit of shared_value_pools. top-level allocator for single-entry.
    shared_value_pools_alloc: std.mem.Allocator,
    /// If True, MR.deinitAll is responsible for freeing shared_value_pools (for single-entry error path).
    /// After bundle construction is successful, switch to false and ownership is transferred to bundle. persistent is always false.
    owns_shared_value_pools: bool = false,
};

pub const WithConfigEntry = struct {
    name: []const u8,
    value: value_mod.Value,
    is_default: bool = false,
};

// Module resolver data records. Kept data-only so resolver logic can be split without
// dragging mutable loader algorithms into every module.
pub const ForwardRuleTarget = union(enum) {
    user_module: u32,
    builtin_module: []const u8,
};

pub const ForwardRuleResolved = struct {
    target: ForwardRuleTarget,
    prefix: ?[]const u8,
    show: ?[]const []const u8,
    hide: ?[]const []const u8,
    from_import: bool = false,
};

pub const ModuleExports = struct {
    vars: std.StringHashMapUnmanaged(VarTarget) = .empty,
    /// provenance source module id per export name.
    var_source_modules: std.StringHashMapUnmanaged(u32) = .empty,
    /// `@forward` Conflicted variable name in export.
    ambiguous_vars: std.StringHashMapUnmanaged(void) = .empty,
    /// `@forward` variable shadowed by local export.
    /// namespaced assign (`ns.$a: ...`) gives priority to write-through.
    shadowed_forward_vars: std.StringHashMapUnmanaged(VarTarget) = .empty,
    /// Configurable export for `@use ... with` / `meta.load-css(..., $with: ...)`.
    /// key is the public variable name (after applying prefix/show/hide), value is the entity variable slot.
    default_vars: std.StringHashMapUnmanaged(VarTarget) = .empty,
    default_var_source_modules: std.StringHashMapUnmanaged(u32) = .empty,
    /// Private top-level !default variables are not module members and must not be forwarded/exported,
    /// but explicit `with` configuration still accepts them for official Sass CLI 1.x compatibility.
    private_default_vars: std.StringHashMapUnmanaged(VarTarget) = .empty,
    /// Conflicting configurable export name in `@forward` export.
    ambiguous_default_vars: std.StringHashMapUnmanaged(void) = .empty,
    mixins: std.StringHashMapUnmanaged(CallableTarget) = .empty,
    mixin_source_modules: std.StringHashMapUnmanaged(u32) = .empty,
    /// `@forward` Conflicted mixin name in export.
    ambiguous_mixins: std.StringHashMapUnmanaged(void) = .empty,
    functions: std.StringHashMapUnmanaged(CallableTarget) = .empty,
    function_source_modules: std.StringHashMapUnmanaged(u32) = .empty,
    /// `@forward` Conflicted function name in export.
    ambiguous_functions: std.StringHashMapUnmanaged(void) = .empty,
    /// export name containing `@forward "sass:..."`  ->  VM builtin id.
    builtin_functions: std.StringHashMapUnmanaged(u32) = .empty,
    /// export name containing `@forward "sass:meta"` mixin-only builtins.
    builtin_mixins: std.StringHashMapUnmanaged(u32) = .empty,
    placeholders: std.StringHashMapUnmanaged(void) = .empty,
    /// Per-map: true once a stored key contains both `-` and `_`. While
    /// false, identifier-insensitive lookups against the map can skip the
    /// exhaustive mixed-key fallback (the two spelling variants are then
    /// provably sufficient). Large `@forward` aggregations otherwise turn
    /// the per-insert duplicate checks quadratic.
    vars_has_mixed_alias_keys: bool = false,
    default_vars_has_mixed_alias_keys: bool = false,
    private_default_vars_has_mixed_alias_keys: bool = false,
    mixins_has_mixed_alias_keys: bool = false,
    functions_has_mixed_alias_keys: bool = false,

    pub fn deinit(self: *ModuleExports, alloc: std.mem.Allocator) void {
        self.vars.deinit(alloc);
        self.var_source_modules.deinit(alloc);
        self.ambiguous_vars.deinit(alloc);
        self.shadowed_forward_vars.deinit(alloc);
        self.default_vars.deinit(alloc);
        self.default_var_source_modules.deinit(alloc);
        self.private_default_vars.deinit(alloc);
        self.ambiguous_default_vars.deinit(alloc);
        self.mixins.deinit(alloc);
        self.mixin_source_modules.deinit(alloc);
        self.ambiguous_mixins.deinit(alloc);
        self.functions.deinit(alloc);
        self.function_source_modules.deinit(alloc);
        self.ambiguous_functions.deinit(alloc);
        self.builtin_functions.deinit(alloc);
        self.builtin_mixins.deinit(alloc);
        self.placeholders.deinit(alloc);
    }
};

pub const ModuleRecord = struct {
    path: []const u8,
    prog: ResolvedProgram,
    exports: ModuleExports,
};

pub const PersistentResolveContext = struct {
    alloc: std.mem.Allocator,
    records_arena: *std.heap.ArenaAllocator,
    records: *std.ArrayListUnmanaged(ModuleRecord),
    id_by_path: *std.StringHashMapUnmanaged(u32),
    static_eval_lists: *std.ArrayListUnmanaged([]const value_mod.Value),
    import_origins: *std.ArrayListUnmanaged(CssOrigin),
    shared_value_pools: *SharedValuePoolStorage,
};

pub const PreambleCheckpointStore = preamble_checkpoint_mod.PreambleCheckpointStore;

pub const ConfigSeedAccum = struct {
    explicit_set: bool = false,
    explicit_value: value_mod.Value = value_mod.Value.nil_v,
    default_set: bool = false,
    default_value: value_mod.Value = value_mod.Value.nil_v,
};

pub const StaticEvalListStore = struct {
    alloc: std.mem.Allocator,
    /// `lists` is a pointer that borrows an external ArrayList. caller provides storage.
    /// In single-entry, caller passes ArrayListUnmanaged on the stack.
    /// For multi-entry persistent, pass lists owned by PersistentResolverState
    /// (Required to be shared to hold list handle (= index) in cross-entry).
    lists: *std.ArrayListUnmanaged([]const value_mod.Value),
    /// If True, release `lists` on deinit (single-entry/owned).
    /// If False, it is owned externally (persistent state) and will not be released.
    owns_lists: bool,

    pub fn initOwned(
        alloc: std.mem.Allocator,
        backing: *std.ArrayListUnmanaged([]const value_mod.Value),
    ) StaticEvalListStore {
        return .{ .alloc = alloc, .lists = backing, .owns_lists = true };
    }

    pub fn initBorrowed(
        alloc: std.mem.Allocator,
        external_lists: *std.ArrayListUnmanaged([]const value_mod.Value),
    ) StaticEvalListStore {
        return .{ .alloc = alloc, .lists = external_lists, .owns_lists = false };
    }

    pub fn deinit(self: *StaticEvalListStore) void {
        if (self.owns_lists) {
            self.lists.deinit(self.alloc);
        }
    }
};
