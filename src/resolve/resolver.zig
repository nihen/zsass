const std = @import("std");
const perf = @import("../runtime/perf.zig");
const syntax_override_mod = @import("../runtime/syntax_override.zig");
const builtin_mod = @import("../builtin/mod.zig");
const media_prelude = @import("media_prelude.zig");
const lexer_mod = @import("../frontend/lexer.zig");
const parser_mod = @import("../frontend/parser.zig");
const resolver_eval = @import("resolver_eval.zig");
const value_mod = @import("../runtime/value.zig");
const opcode_mod = @import("../ir/opcode.zig");
const color_mod = @import("../color/color.zig");
const ast_flat = @import("../frontend/ast_flat.zig");
const ir_validate = @import("../ir/validate.zig");
const prelude = @import("prelude.zig");
const data_mod = @import("data.zig");
const import_css = @import("import_css.zig");
const path_resolution = @import("path_resolution.zig");
const names = @import("names.zig");
const name_lookup = @import("name_lookup.zig");
const module_directive = @import("module_directive.zig");
const module_stmt = @import("module_stmt.zig");
const module_import_inline = @import("module_import_inline.zig");
const stmt_at_rule = @import("stmt_at_rule.zig");
const stmt_content = @import("stmt_content.zig");
const calc_utils = @import("../runtime/calc_utils.zig");
const css_utils = @import("../runtime/css_utils.zig");
const value_format = @import("../runtime/value_format.zig");
const error_format = @import("../runtime/error_format.zig");
const deprecation_mod = @import("../runtime/deprecation.zig");
const selector_helpers = @import("../selector/selector_helpers.zig");
const source_cache_mod = @import("source_cache.zig");
const ast_cache_mod = @import("ast_cache.zig");
const origin_mod = @import("../runtime/origin.zig");
const containsReferenceCombinator = selector_helpers.containsReferenceCombinator;
const validateSelectorDelimiters = selector_helpers.validateSelectorDelimiters;
const validateSelectorParentheses = selector_helpers.validateSelectorParentheses;
const validatePseudoClassArgs = selector_helpers.validatePseudoClassArgs;
const simplePlaceholderSelectorKey = selector_helpers.simplePlaceholderSelectorKey;
const AstNode = ast_flat.AstNode;
const NodeIndex = ast_flat.NodeIndex;
const ExtraIndex = ast_flat.ExtraIndex;
const AstBinOp = ast_flat.BinOp;
const AstUnaryOp = ast_flat.UnaryOp;
const intern_pool_mod = @import("../runtime/intern_pool.zig");
const InternPool = intern_pool_mod.InternPool;
const InternId = intern_pool_mod.InternId;
const zsass_io = @import("../runtime/io.zig");
const ListSeparator = value_mod.ListSeparator;
const OriginId = origin_mod.OriginId;
const validatePlainCssSelector = ir_validate.validatePlainCssSelector;
const validatePlainCssValue = ir_validate.validatePlainCssValue;
const isEscapedCharacter = css_utils.isEscapedCharacter;

fn resolverStderrPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    var err_file = std.Io.File.stderr();
    var w = err_file.writer(zsass_io.io, buf[0..]);
    w.interface.print(fmt, args) catch return;
    w.interface.flush() catch return;
}

fn validateAtRuleNameInterpolation(input: []const u8) anyerror!void {
    var i: usize = 0;
    while (i + 1 < input.len) : (i += 1) {
        if (input[i] != '#' or input[i + 1] != '{' or isEscapedCharacter(input, i)) continue;

        var depth: u32 = 1;
        var j = i + 2;
        while (j < input.len and depth > 0) {
            if (input[j] == '{') depth += 1;
            if (input[j] == '}') depth -= 1;
            if (depth > 0) j += 1;
        }
        if (depth > 0) return error.SassError;

        const expr = std.mem.trim(u8, input[i + 2 .. j], " \t\n\r");
        if (expr.len > 0 and startsWithUnbalancedAtRuleInterpolationDelimiter(expr)) {
            return error.SassError;
        }
        i = j;
    }
}

fn startsWithUnbalancedAtRuleInterpolationDelimiter(expr: []const u8) bool {
    const first = expr[0];
    if (first != '[' and first != '(') return false;

    var bracket_depth: i32 = 0;
    var paren_depth: i32 = 0;
    var in_string: u8 = 0;
    var i: usize = 0;
    while (i < expr.len) : (i += 1) {
        const c = expr[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < expr.len) {
                i += 1;
                continue;
            }
            if (c == in_string and !isEscapedCharacter(expr, i)) in_string = 0;
            continue;
        }
        if ((c == '"' or c == '\'') and !isEscapedCharacter(expr, i)) {
            in_string = c;
            continue;
        }
        switch (c) {
            '[' => bracket_depth += 1,
            ']' => bracket_depth -= 1,
            '(' => paren_depth += 1,
            ')' => paren_depth -= 1,
            else => {},
        }
    }

    return bracket_depth > 0 or paren_depth > 0;
}
const meta_variable_exists_builtin_id: u32 = 127;

pub const SlotId = data_mod.SlotId;
pub const MixinId = data_mod.MixinId;
pub const FunctionId = data_mod.FunctionId;
pub const ExprIndex = data_mod.ExprIndex;
pub const StmtIndex = data_mod.StmtIndex;
pub const call_arg_splat_sentinel = data_mod.call_arg_splat_sentinel;
pub const Span = data_mod.Span;
pub const CallableTarget = data_mod.CallableTarget;
pub const VarTarget = data_mod.VarTarget;
pub const BinOp = data_mod.BinOp;
pub const UnaryOp = data_mod.UnaryOp;
pub const ExprKind = data_mod.ExprKind;
pub const LiteralColor = data_mod.LiteralColor;
pub const PreboundCallableKind = data_mod.PreboundCallableKind;
pub const ResolvedExpr = data_mod.ResolvedExpr;
pub const StmtKind = data_mod.StmtKind;
pub const ResolvedStmt = data_mod.ResolvedStmt;
pub const SelectorRuleKind = data_mod.SelectorRuleKind;
pub const DeclPropKind = data_mod.DeclPropKind;
pub const RuleData = data_mod.RuleData;
pub const AtRootBehavior = data_mod.AtRootBehavior;
pub const ResolvedContentBlock = data_mod.ResolvedContentBlock;
pub const FlowLocalFallback = data_mod.FlowLocalFallback;
pub const CommentData = data_mod.CommentData;
pub const DeclData = data_mod.DeclData;
pub const ResolvedMixin = data_mod.ResolvedMixin;
pub const ResolvedFunction = data_mod.ResolvedFunction;
pub const ResolvedProgram = data_mod.ResolvedProgram;
pub const UseBinding = data_mod.UseBinding;
pub const local_module_id_sentinel = data_mod.local_module_id_sentinel;
pub const apply_mixin_sentinel = data_mod.apply_mixin_sentinel;
pub const load_css_mixin_sentinel = data_mod.load_css_mixin_sentinel;
pub const ConfigSeed = data_mod.ConfigSeed;
pub const SharedValuePoolStorage = data_mod.SharedValuePoolStorage;
pub const ResolvedBundle = data_mod.ResolvedBundle;
const ModuleResolver = data_mod.ModuleResolver;

fn builtinMixinIdToSentinel(bid: builtin_mod.Id) ?MixinId {
    if (bid == builtin_mod.meta_apply_mixin_id) return apply_mixin_sentinel;
    if (bid == builtin_mod.meta_load_css_mixin_id) return load_css_mixin_sentinel;
    return null;
}

fn appendNumberLiteral(prog: *ResolvedProgram, alloc: std.mem.Allocator, v: f64, unit_id: InternId, span: Span) !ExprIndex {
    const bits: u64 = @bitCast(v);
    const idx: u32 = @intCast(prog.number_pool.items.len);
    try prog.number_pool.append(alloc, .{
        .lo = @truncate(bits),
        .hi = @truncate(bits >> 32),
        .unit_id = unit_id,
    });
    return try appendExpr(prog, alloc, .{
        .kind = .literal_number,
        .payload = idx,
        .span = span,
    });
}

pub const ResolveError = data_mod.ResolveError;

const CrossVarTarget = VarTarget;

const CrossCallableTarget = CallableTarget;

fn MapEntry(comptime V: type) type {
    return struct {
        key: []const u8,
        value: V,
    };
}

// Use-map snapshot is callable default's use-bindings persistence (`@import`'s use_map
//rewind) is still required. In addition to scope push/pop, 9-13 map is replaced with undo log.
fn snapshotStringMap(
    comptime V: type,
    alloc: std.mem.Allocator,
    map: *const std.StringHashMapUnmanaged(V),
) ![]MapEntry(V) {
    const out = try alloc.alloc(MapEntry(V), map.count());
    var i: usize = 0;
    var it = map.iterator();
    while (it.next()) |entry| {
        out[i] = .{
            .key = entry.key_ptr.*,
            .value = entry.value_ptr.*,
        };
        i += 1;
    }
    return out;
}

fn restoreStringMap(
    comptime V: type,
    alloc: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(V),
    entries: []const MapEntry(V),
) (std.mem.Allocator.Error || error{SnapshotTooLarge})!void {
    map.clearRetainingCapacity();
    const capacity: u32 = std.math.cast(u32, entries.len) orelse
        return error.SnapshotTooLarge;
    try map.ensureTotalCapacity(alloc, capacity);
    for (entries) |entry| {
        try map.put(alloc, entry.key, entry.value);
    }
}

// =============================================================================
// scope undo log infrastructure
// =============================================================================
//
// In the old design, 9 to 13 types of StringHashMap were used during `pushScope` / `pushCallableScope`
// Clone all entries to create a snapshot and replace all with `popScope` (clearRetainingCapacity
//+ ensureTotalCapacity + put loop) to restore. The amount of calculation is scope depth x each map.
// In modules that use a large number of `@use ... as *` imports across many entries,
// nested-scope churn can dominate resolver time while those imports are active.
//
// undo log method: push one layer at scope start (entries start from zero),
// Every time a map mutation occurs within scope, the "state before change (was_present + prev value)"
// Append to log, apply in reverse order at pop and return to original state. The cost is proportional to the number of mutations,
// 0 cost if nothing is touched within scope.
//
// out of 13 maps
//   - 9 map (star_vars / star_mixins / star_functions / star_placeholders /
//     star_builtin_fns / import_star_vars / ambiguous_star_vars / ambiguous_star_mixins
// / ambiguous_star_functions): Revert target for all layers (= UndoMapId.isStarOnly == true)
//   - 4 extra map (prog.mixin_names / prog.function_names / seen_mixin_decls /
// seen_function_decls): callable layer / inline-import-star layer without revert
// propagate (pre-reserved mixin/function name in callable body) in parent layer
//Follows the semantics of leaving outside the scope)
const UndoMapId = enum(u8) {
    star_vars,
    star_mixins,
    star_functions,
    star_placeholders,
    star_builtin_fns,
    import_star_vars,
    ambiguous_star_vars,
    ambiguous_star_mixins,
    ambiguous_star_functions,
    prog_mixin_names,
    prog_function_names,
    seen_mixin_decls,
    seen_function_decls,

    fn isStarOnly(self: UndoMapId) bool {
        return switch (self) {
            .prog_mixin_names,
            .prog_function_names,
            .seen_mixin_decls,
            .seen_function_decls,
            => false,
            else => true,
        };
    }
};

const UndoPrev = union {
    var_target: CrossVarTarget,
    callable_target: CrossCallableTarget,
    u32_v: u32,
    bool_v: bool,
    void_v: void,
};

const UndoEntry = struct {
    map_id: UndoMapId,
    /// The previous state. If false, "key does not exist" = remove at pop, if true, "key exists in prev" = put at pop.
    was_present: bool,
    /// Key used for lookup at pop (value at mutation time, caller guarantees arena lifetime).
    key: []const u8,
    /// Meaningful only when was_present == true. The union variant is determined by map_id (untagged).
    prev: UndoPrev,
};

fn UndoMapMeta(comptime map_id: UndoMapId) type {
    const Value = switch (map_id) {
        .star_vars => CrossVarTarget,
        .star_mixins, .star_functions => CrossCallableTarget,
        .star_placeholders, .star_builtin_fns, .prog_mixin_names, .prog_function_names => u32,
        .import_star_vars => bool,
        .ambiguous_star_vars, .ambiguous_star_mixins, .ambiguous_star_functions, .seen_mixin_decls, .seen_function_decls => void,
    };
    return struct {
        const Map = std.StringHashMapUnmanaged(Value);

        inline fn getMap(ctx: *Ctx) *Map {
            return switch (map_id) {
                .prog_mixin_names => &ctx.prog.mixin_names,
                .prog_function_names => &ctx.prog.function_names,
                .star_vars => &ctx.star_vars,
                .star_mixins => &ctx.star_mixins,
                .star_functions => &ctx.star_functions,
                .star_placeholders => &ctx.star_placeholders,
                .star_builtin_fns => &ctx.star_builtin_fns,
                .import_star_vars => &ctx.import_star_vars,
                .ambiguous_star_vars => &ctx.ambiguous_star_vars,
                .ambiguous_star_mixins => &ctx.ambiguous_star_mixins,
                .ambiguous_star_functions => &ctx.ambiguous_star_functions,
                .seen_mixin_decls => &ctx.seen_mixin_decls,
                .seen_function_decls => &ctx.seen_function_decls,
            };
        }

        inline fn wrapPrev(val: Value) UndoPrev {
            return switch (map_id) {
                .star_vars => .{ .var_target = val },
                .star_mixins, .star_functions => .{ .callable_target = val },
                .star_placeholders, .star_builtin_fns, .prog_mixin_names, .prog_function_names => .{ .u32_v = val },
                .import_star_vars => .{ .bool_v = val },
                .ambiguous_star_vars, .ambiguous_star_mixins, .ambiguous_star_functions, .seen_mixin_decls, .seen_function_decls => .{ .void_v = {} },
            };
        }

        inline fn unwrapPrev(prev: UndoPrev) Value {
            return switch (map_id) {
                .star_vars => prev.var_target,
                .star_mixins, .star_functions => prev.callable_target,
                .star_placeholders, .star_builtin_fns, .prog_mixin_names, .prog_function_names => prev.u32_v,
                .import_star_vars => prev.bool_v,
                .ambiguous_star_vars, .ambiguous_star_mixins, .ambiguous_star_functions, .seen_mixin_decls, .seen_function_decls => {},
            };
        }
    };
}

const UndoLayerKind = enum(u8) {
    /// `pushScope`: Revert all 13 map entries in reverse order.
    full_scope,
    /// `pushCallableScope`: 9 star map only revert, 4 extra map propagate to parent layer.
    callable_scope,
    /// inline import-star snapshot in top-level `@import`. 9 star map only revert,
    /// 4 extra map propagate to parent (declare mixin/function remains on importer side).
    inline_import_star,
};

const UndoLayer = struct {
    kind: UndoLayerKind,
    entries: std.ArrayListUnmanaged(UndoEntry) = .empty,
    /// Length of `forward_rules` to save during `pushScope` / `pushCallableScope`.
    /// Not used in inline_import_star layer (caller manages import_forward_before with a separate variable).
    forward_rules_len: usize = 0,
};

const ForwardRuleResolved = data_mod.ForwardRuleResolved;
pub const ModuleRecord = data_mod.ModuleRecord;
pub const PersistentResolveContext = data_mod.PersistentResolveContext;
const StaticEvalListStore = data_mod.StaticEvalListStore;

const PendingCallableDefaultKind = enum(u1) {
    mixin,
    function,
};

const PendingUseBinding = MapEntry(UseBinding);

const PendingCallableDefault = struct {
    kind: PendingCallableDefaultKind,
    callable_id: u32,
    param_index: u32,
    expr_text: []const u8,
    use_bindings: []const PendingUseBinding,
};

const CallableDeclContext = enum(u2) {
    none,
    mixin,
    function,
};

const ScopeFlags = struct {
    is_flow_control: bool = false,
    is_callable_boundary: bool = false,
    needs_scope_restore: bool = false,
};

const calc_arg_marker = "\x01zsass-calc-arg:";
const calc_interp_marker = "\x01zsass-calc-interp:";
const calc_interp_preserve_start = "\x01zsass-calc-preserve:";
const calc_interp_preserve_end = "\x02";
const calc_interp_preserve_slash = "\x03";

const Ctx = struct {
    const StaticConfigVar = struct {
        name: []const u8,
        value: value_mod.Value,
    };

    ast: *const ast_flat.Ast,
    pool: *InternPool,
    prog: *ResolvedProgram,
    a: std.mem.Allocator,
    root_alloc: std.mem.Allocator,
    module_path: []const u8 = "",
    loader: ?*ModuleResolver = null,
    static_eval_store: *StaticEvalListStore,
    color_pool: ?*value_mod.ColorPool = null,

    scopes: std.ArrayListUnmanaged(std.StringHashMapUnmanaged(SlotId)) = .empty,
    scope_flags: std.ArrayListUnmanaged(ScopeFlags) = .empty,
    star_vars: std.StringHashMapUnmanaged(CrossVarTarget) = .empty,
    ambiguous_star_vars: std.StringHashMapUnmanaged(void) = .empty,
    star_mixins: std.StringHashMapUnmanaged(CrossCallableTarget) = .empty,
    ambiguous_star_mixins: std.StringHashMapUnmanaged(void) = .empty,
    star_functions: std.StringHashMapUnmanaged(CrossCallableTarget) = .empty,
    ambiguous_star_functions: std.StringHashMapUnmanaged(void) = .empty,
    /// True once a star-imported mixin key contains both `-` and `_` (same rule as `global_slots_have_mixed_alias_keys`).
    /// While false, star mixin lookups can skip the rare O(map) identifierEq fallback.
    star_mixins_have_mixed_alias_keys: bool = false,
    /// Same as `star_mixins_have_mixed_alias_keys` for `@use ... as *` function exports.
    star_functions_have_mixed_alias_keys: bool = false,
    star_placeholders: std.StringHashMapUnmanaged(u32) = .empty,
    star_builtin_fns: std.StringHashMapUnmanaged(u32) = .empty,
    /// Var name exposed from `@forward` via `@import`.
    /// value=true means that the original variable comes from the `!default` declaration, and the top-level bare assign is
    /// Used to determine whether to treat it as a local shadow without write-through.
    import_star_vars: std.StringHashMapUnmanaged(bool) = .empty,
    forward_rules: std.ArrayListUnmanaged(ForwardRuleResolved) = .empty,
    /// Undo log of map mutation to be undone by Scope push/pop.
    /// Replaced the old `scope_snapshots`(ScopedImportSnapshot) with a log proportional to the number of mutations (P5).
    undo_layers: std.ArrayListUnmanaged(UndoLayer) = .empty,
    next_local_slot: SlotId = 0,
    next_mixin_id: MixinId = 0,
    next_function_id: FunctionId = 0,
    /// True while resolving a mixin/function body (locals continue param slots).
    in_callable: bool = false,
    /// True only during the deferred callable-default resolution pass.
    /// Suppresses cross-module static value materialization of var refs so
    /// ParamDefault can hold a cross_slot entry (evaluated at call time)
    /// rather than a materialized .list/.literal expression that the
    /// compiler's compileParamDefault cannot encode.
    resolving_callable_default: bool = false,
    flow_control_depth: u32 = 0,
    while_body_depth: u32 = 0,
    callable_decl_context: CallableDeclContext = .none,
    seen_mixin_decls: std.StringHashMapUnmanaged(void) = .empty,
    seen_function_decls: std.StringHashMapUnmanaged(void) = .empty,
    /// bare `@include` in callable body becomes "next top-level mixin declaration"
    /// Reserved id for cases where you need to forward-bind.
    pending_next_mixin_bindings: std.StringHashMapUnmanaged(MixinId) = .empty,

    mixin_accepts_content: bool = false,

    /// Visiting stack while resolving Sass file `@import` (anti-circulation). Absolute path.
    visiting_imports: std.ArrayListUnmanaged([]const u8) = .empty,
    /// When `@import` inline expands child top stmts to parent, the caller of resolveStmt
    /// Top_list / Temporarily retain extra data to be included in body_roots.
    pending_extra_top: std.ArrayListUnmanaged(StmtIndex) = .empty,
    /// Static approximation of the most recent top-level variable. Used to resolve `$x` in `@use ... with ($a: $x)`.
    static_config_vars: std.ArrayListUnmanaged(StaticConfigVar) = .empty,
    /// Direct `@use ... with` / `@forward ... with` entries supplied by the
    /// parent while this module is being resolved. These entries must be
    /// visible to this module's own top-level `!default` variables before
    /// nested module directives are resolved.
    initial_config_entries: []const WithConfigEntry = &.{},
    /// Body depth such as `stmt_style_rule` / `stmt_at_rule` / `stmt_at_root`.
    /// top-level `!default` Used for collection judgment.
    nested_stmt_depth: u32 = 0,
    /// enclosing style-rule depth (common to plain-CSS / Sass).
    style_rule_depth: u32 = 0,
    /// enclosing plain-CSS style-rule depth.
    plain_css_style_rule_depth: u32 = 0,
    /// nested property-namespace depth (`foo: { ... }`).
    property_namespace_depth: u32 = 0,
    /// function/mixin parameter default expressions that must be resolved after the
    /// full module (including `@import` inline expansion) is known.
    pending_callable_defaults: std.ArrayListUnmanaged(PendingCallableDefault) = .empty,
    /// Namespace bindings captured at callable declaration time while resolving a
    /// deferred parameter default. This keeps `@import`ed callables independent of
    /// the importer's file-scoped `@use` namespace set.
    deferred_callable_default_use_bindings: []const PendingUseBinding = &.{},
    /// selector literal validation result cache (key: InternId).
    literal_selector_syntax_cache: std.AutoHashMapUnmanaged(InternId, bool) = .empty,
    user_function_lookup_cache: std.AutoHashMapUnmanaged(u64, CallableTarget) = .empty,
    user_mixin_lookup_cache: std.AutoHashMapUnmanaged(u64, CallableTarget) = .empty,
    /// `@use` / `@forward` is only allowed at the beginning of top-level.
    /// Maintain the leading rule even after crossing comment/var/import/mixin/function/@charset.
    module_directive_locked: bool = false,
    /// `@supports` / interpolated at-rule / custom CSS `@function --*` etc.
    /// In the context of plain-CSS treatment, make undefined `$var` literal instead of making it a hard error.
    allow_unknown_var_literal: bool = false,
    /// Resolving calc()/calc-size() argument expression while true.
    /// Keep bare identifier as literal_string with marker,
    /// Enable arithmetic preserving on the runtime side.
    calc_arg_mode: bool = false,
    /// `infinity` / `pi` etc. in CSS math call arguments such as clamp/hypot
    /// Use number-ish identifier for numerical resolution without turning it into a marker.
    calc_arg_allow_numberish_ident_literals: bool = false,
    /// Whether declaration value is being resolved.
    /// Used to determine the declaration context of slash ambiguity (`/`).
    in_declaration_value: bool = false,
    /// Declaration value validation in plain-CSS context. custom CSS `@function --*`
    /// Set it to false in the immediate body to maintain CSS text compatibility rules.
    plain_css_validate_values: bool = true,
    origin_stack: std.ArrayListUnmanaged(OriginId) = .empty,

    fn deinitScopes(self: *Ctx, alloc: std.mem.Allocator) void {
        for (self.scopes.items) |*m| {
            m.deinit(alloc);
        }
        self.scopes.deinit(alloc);
        self.scope_flags.deinit(alloc);
        self.star_vars.deinit(alloc);
        self.ambiguous_star_vars.deinit(alloc);
        self.star_mixins.deinit(alloc);
        self.ambiguous_star_mixins.deinit(alloc);
        self.star_functions.deinit(alloc);
        self.ambiguous_star_functions.deinit(alloc);
        self.star_placeholders.deinit(alloc);
        self.star_builtin_fns.deinit(alloc);
        self.import_star_vars.deinit(alloc);
        self.forward_rules.deinit(alloc);
        for (self.undo_layers.items) |*layer| {
            layer.entries.deinit(alloc);
        }
        self.undo_layers.deinit(alloc);
        self.seen_mixin_decls.deinit(alloc);
        self.seen_function_decls.deinit(alloc);
        self.pending_next_mixin_bindings.deinit(alloc);
        self.visiting_imports.deinit(alloc);
        self.pending_extra_top.deinit(alloc);
        for (self.static_config_vars.items) |entry| {
            alloc.free(entry.name);
        }
        self.static_config_vars.deinit(alloc);
        self.pending_callable_defaults.deinit(alloc);
        self.literal_selector_syntax_cache.deinit(alloc);
        self.user_function_lookup_cache.deinit(alloc);
        self.user_mixin_lookup_cache.deinit(alloc);
        self.origin_stack.deinit(alloc);
    }

    pub fn currentOrigin(self: *const Ctx) OriginId {
        if (self.origin_stack.items.len == 0) return .invalid;
        return self.origin_stack.items[self.origin_stack.items.len - 1];
    }

    pub fn markScopeRestoreDirty(self: *Ctx) void {
        if (self.scope_flags.items.len == 0) return;
        self.scope_flags.items[self.scope_flags.items.len - 1].needs_scope_restore = true;
    }

    /// Push one scope and also add one undo log layer. layer kind = full_scope.
    pub fn pushScope(self: *Ctx, alloc: std.mem.Allocator) !void {
        try self.undo_layers.append(alloc, .{
            .kind = .full_scope,
            .forward_rules_len = self.forward_rules.items.len,
        });
        errdefer {
            var popped = self.undo_layers.pop().?;
            popped.entries.deinit(alloc);
        }
        try self.scopes.append(alloc, .{});
        errdefer _ = self.scopes.pop();
        try self.scope_flags.append(alloc, .{});
    }

    /// Scope for callable body. 9 star map only revert when pop, 4 extra map (prog.mixin_names
    /// etc.) is propagated to the parent layer to maintain the "pre-order callable name" specification.
    fn pushCallableScope(self: *Ctx, alloc: std.mem.Allocator) !void {
        try self.undo_layers.append(alloc, .{
            .kind = .callable_scope,
            .forward_rules_len = self.forward_rules.items.len,
        });
        errdefer {
            var popped = self.undo_layers.pop().?;
            popped.entries.deinit(alloc);
        }
        try self.scopes.append(alloc, .{});
        errdefer _ = self.scopes.pop();
        try self.scope_flags.append(alloc, .{ .is_callable_boundary = true });
    }

    fn pushTransientExprScope(self: *Ctx, alloc: std.mem.Allocator) !void {
        try self.scopes.append(alloc, .{});
        errdefer _ = self.scopes.pop();
        try self.scope_flags.append(alloc, .{});
    }

    pub fn popScope(self: *Ctx, alloc: std.mem.Allocator) void {
        var m = self.scopes.pop().?;
        self.removeStaticValuesForScope(&m);
        m.deinit(alloc);
        const flags = self.scope_flags.pop().?;
        // Reproduction of old popScope semantics:
        //- needs_scope_restore == false  ->  don't rewind anything (entries discard, forward_rules truncate only)
        //- in_callable or is_callable_boundary  ->  9 star map only revert, 4 extra map propagate to parent
        // (= leave provisional name pre-reserved in callable body in outer)
        //- else  ->  all entries in reverse order revert
        self.popScopeUndoLayer(alloc, flags.needs_scope_restore, self.in_callable or flags.is_callable_boundary);
    }

    fn popTransientExprScope(self: *Ctx, alloc: std.mem.Allocator) void {
        var m = self.scopes.pop().?;
        self.removeStaticValuesForScope(&m);
        m.deinit(alloc);
        _ = self.scope_flags.pop().?;
    }

    fn removeStaticValuesForScope(self: *Ctx, scope: *const std.StringHashMapUnmanaged(SlotId)) void {
        var it = scope.iterator();
        while (it.next()) |entry| {
            const slot = entry.value_ptr.*;
            if (decodeCrossAssignSlot(slot) != null) continue;
            removeStaticSlotValue(self.prog, slot);
        }
    }

    /// Start a top-level inline import-star snapshot of the `@import` route.
    /// Don't touch scope/scope_flags, just add one layer to undo_layers.
    pub fn pushInlineImportStarLayer(self: *Ctx, alloc: std.mem.Allocator) !void {
        try self.undo_layers.append(alloc, .{
            .kind = .inline_import_star,
            // forward_rules is managed independently by the caller (resolveImportInline), so
            // Do not save here (do not truncate when layer.kind == inline_import_star even in popUndoLayer).
            .forward_rules_len = 0,
        });
    }

    pub fn popInlineImportStarLayer(self: *Ctx, alloc: std.mem.Allocator) void {
        std.debug.assert(self.undo_layers.items.len > 0);
        std.debug.assert(self.undo_layers.items[self.undo_layers.items.len - 1].kind == .inline_import_star);
        // inline_import_star means old `restoreImportStarOnly`: 9 revert map in reverse order, 4 leave extra map mutations in outer.
        // In the old code, top_level_star_snapshot was only taken with `import_is_top_level == true` (= scopes.items.len==0),
        // The outer scope to propagate does not exist. Therefore, 4 extra map entries are left in outer with **discard**.
        var layer = self.undo_layers.pop().?;
        defer layer.entries.deinit(alloc);
        var i: usize = layer.entries.items.len;
        while (i > 0) {
            i -= 1;
            const entry = layer.entries.items[i];
            if (entry.map_id.isStarOnly()) {
                self.applyUndoEntry(alloc, entry);
            }
            // 4 extra map entry: discard, mutations remain outside (top-level prog.mixin_names, etc.).
        }
    }

    /// pop for scope-stack. Reproduce the semantics of the old popScope.
    /// - needs_restore == false: forward_rules truncate only, all entries discard (mutation remains as is)
    /// - use_callable_semantics == true: only 9 star map is reverted in reverse order, 4 extra map is propagate to parent layer
    /// (= leave the provisional name pre-reserved in the callable body in the outer scope)
    /// - else (full revert): Revert all entries in reverse order
    fn popScopeUndoLayer(
        self: *Ctx,
        alloc: std.mem.Allocator,
        needs_restore: bool,
        use_callable_semantics: bool,
    ) void {
        std.debug.assert(self.undo_layers.items.len > 0);
        var layer = self.undo_layers.pop().?;
        defer layer.entries.deinit(alloc);
        // forward_rules truncate is always done (old popScope: snap.forward_rules_len restored)
        self.forward_rules.items.len = layer.forward_rules_len;

        if (!needs_restore) {
            // The mutation did not occur within scope, or the change was intended to be ``non-reversible.''
            // Ignore entries (matches old logic: `if (!flags.needs_scope_restore) return;`).
            return;
        }

        const has_parent = self.undo_layers.items.len > 0;
        var i: usize = layer.entries.items.len;
        while (i > 0) {
            i -= 1;
            const entry = layer.entries.items[i];
            const star_only = entry.map_id.isStarOnly();
            const revert_here = if (use_callable_semantics) star_only else true;
            if (revert_here) {
                self.applyUndoEntry(alloc, entry);
            } else if (has_parent) {
                const parent = &self.undo_layers.items[self.undo_layers.items.len - 1];
                parent.entries.append(alloc, entry) catch |err| {
                    std.debug.panic("undo log propagation OOM: {s}", .{@errorName(err)});
                };
            }
            // !revert_here && !has_parent: top-level commit, entry is discarded
            // (With old callable_boundary pop and without outer, 4 extra map mutation remains).
        }
    }

    fn applyUndoEntry(self: *Ctx, alloc: std.mem.Allocator, entry: UndoEntry) void {
        switch (entry.map_id) {
            inline else => |tag| {
                const Meta = UndoMapMeta(tag);
                const map = Meta.getMap(self);
                if (entry.was_present) {
                    map.put(alloc, entry.key, Meta.unwrapPrev(entry.prev)) catch |err|
                        std.debug.panic("undo restore " ++ @tagName(tag) ++ " OOM: {s}", .{@errorName(err)});
                    switch (tag) {
                        .star_mixins => noteStarMixinMapKey(self, entry.key),
                        .star_functions => noteStarFunctionMapKey(self, entry.key),
                        else => {},
                    }
                } else {
                    _ = map.remove(entry.key);
                }
            },
        }
    }

    inline fn recordMapMut(self: *Ctx, alloc: std.mem.Allocator, comptime map_id: UndoMapId, key: []const u8) !void {
        if (self.undo_layers.items.len == 0) return;
        const top = &self.undo_layers.items[self.undo_layers.items.len - 1];
        const Meta = UndoMapMeta(map_id);
        const map = Meta.getMap(self);
        if (map.getEntry(key)) |e| {
            try top.entries.append(alloc, .{
                .map_id = map_id,
                .was_present = true,
                .key = e.key_ptr.*,
                .prev = Meta.wrapPrev(e.value_ptr.*),
            });
        } else {
            try top.entries.append(alloc, .{
                .map_id = map_id,
                .was_present = false,
                .key = key,
                .prev = .{ .void_v = {} },
            });
        }
    }

    fn currentScope(self: *Ctx) *std.StringHashMapUnmanaged(SlotId) {
        return &self.scopes.items[self.scopes.items.len - 1];
    }

    fn currentScopeFlags(self: *Ctx) *ScopeFlags {
        return &self.scope_flags.items[self.scope_flags.items.len - 1];
    }

    fn lookupSlot(self: *Ctx, name_id: InternId) ?SlotId {
        const name = self.pool.get(name_id);
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (lookupSlotInsensitive(&self.scopes.items[i], name)) |s| return s;
        }
        return lookupGlobalSlot(self.prog, name);
    }

    fn lookupScopedSlot(self: *Ctx, name_id: InternId) ?SlotId {
        const name = self.pool.get(name_id);
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (lookupSlotInsensitive(&self.scopes.items[i], name)) |s| return s;
        }
        return null;
    }

    fn nearestPersistentScopeIndex(self: *Ctx) ?usize {
        var i: usize = self.scope_flags.items.len;
        while (i > 0) {
            i -= 1;
            if (!self.scope_flags.items[i].is_flow_control) return i;
        }
        return null;
    }

    fn lookupFlowControlAssignSlot(self: *Ctx, name_id: InternId) ?SlotId {
        const name = self.pool.get(name_id);
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (lookupSlotInsensitive(&self.scopes.items[i], name)) |s| return s;
            if (self.scope_flags.items[i].is_callable_boundary) break;
        }

        // The flow-control in the callable falls back to global to match legacy behavior.
        // (loop can now be stopped consistent with while condition re-evaluation)
        if (self.in_callable) {
            if (lookupGlobalSlot(self.prog, name)) |s| return s;
            return null;
        }

        // In the `@while` body, the same name global is used because the conditional expression is resolved first.
        // If not set to fallback, it may become an unstoppable loop.
        if (self.while_body_depth > 0) {
            if (lookupGlobalSlot(self.prog, name)) |s| return s;
        }

        // Assignments in flow-control are bound to the "nearest persistent scope".
        // If persistent scope exists, implicit global write will not be performed even if global has the same name
        // (passes global path only when `!global` is specified).
        if (self.nearestPersistentScopeIndex() == null) {
            if (lookupGlobalSlot(self.prog, name)) |s| return s;
        }
        return null;
    }

    fn lookupStarVar(self: *Ctx, name_id: InternId) ?CrossVarTarget {
        return lookupConfigVarTargetInsensitive(&self.star_vars, self.pool.get(name_id));
    }

    fn lookupStarMixin(self: *Ctx, name: []const u8) ?CrossCallableTarget {
        return lookupStarMixinMapInsensitive(self, name);
    }

    fn lookupStarFunction(self: *Ctx, name: []const u8) ?CrossCallableTarget {
        return lookupStarFunctionMapInsensitive(self, name);
    }

    fn lookupStarPlaceholder(self: *Ctx, name: []const u8) ?u32 {
        return self.star_placeholders.get(name);
    }

    fn getStaticConfigVar(self: *const Ctx, name: []const u8) ?value_mod.Value {
        for (self.static_config_vars.items) |entry| {
            if (identifierEq(entry.name, name)) return entry.value;
        }
        return null;
    }

    fn setStaticConfigVar(self: *Ctx, name: []const u8, value: value_mod.Value) !void {
        for (self.static_config_vars.items) |*entry| {
            if (identifierEq(entry.name, name)) {
                entry.value = value;
                return;
            }
        }
        try self.static_config_vars.append(self.a, .{
            .name = try self.a.dupe(u8, name),
            .value = value,
        });
    }

    fn appendStaticConfigVarKnownAbsent(self: *Ctx, name: []const u8, value: value_mod.Value) !void {
        try self.static_config_vars.append(self.a, .{
            .name = try self.a.dupe(u8, name),
            .value = value,
        });
    }

    fn removeStaticConfigVar(self: *Ctx, name: []const u8) void {
        var i: usize = 0;
        while (i < self.static_config_vars.items.len) : (i += 1) {
            if (!identifierEq(self.static_config_vars.items[i].name, name)) continue;
            self.a.free(self.static_config_vars.items[i].name);
            _ = self.static_config_vars.swapRemove(i);
            return;
        }
    }

    fn lookupInitialConfigValue(self: *const Ctx, name: []const u8) ?value_mod.Value {
        var default_value: ?value_mod.Value = null;
        for (self.initial_config_entries) |entry| {
            if (!identifierEq(entry.name, name)) continue;
            if (!entry.is_default) return entry.value;
            if (default_value == null) default_value = entry.value;
        }
        return default_value;
    }

    pub fn truncateStaticConfigVars(self: *Ctx, new_len: usize) void {
        while (self.static_config_vars.items.len > new_len) {
            const idx = self.static_config_vars.items.len - 1;
            self.a.free(self.static_config_vars.items[idx].name);
            self.static_config_vars.items.len = idx;
        }
    }

    fn declareGlobal(self: *Ctx, name_id: InternId) !SlotId {
        const name = self.pool.get(name_id);
        if (lookupGlobalSlot(self.prog, name)) |existing| return existing;
        // Reserve past any locals already allocated in the current resolution
        // context so later globals don't alias top-level nested locals or
        // callable locals that coexist with `!global` writes.
        const slot = @max(self.prog.next_global_slot, self.next_local_slot);
        self.prog.next_global_slot = slot + 1;
        if (self.next_local_slot < self.prog.next_global_slot) {
            self.next_local_slot = self.prog.next_global_slot;
        }
        self.prog.max_slot = @max(self.prog.max_slot, slot + 1);
        if (hasMixedIdentifierAliasChars(name)) {
            self.prog.global_slots_have_mixed_alias_keys = true;
        }
        try self.prog.global_slots.put(self.a, name, slot);
        return slot;
    }

    fn markDeclaredGlobal(self: *Ctx, name_id: InternId) !void {
        const name = self.pool.get(name_id);
        const gop = try self.prog.declared_global_names.getOrPut(self.a, name);
        if (!gop.found_existing) gop.key_ptr.* = try self.a.dupe(u8, name);
    }

    fn slotIsGlobal(self: *const Ctx, slot: SlotId) bool {
        var it = self.prog.global_slots.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == slot) return true;
        }
        return false;
    }

    pub fn declareLocal(self: *Ctx, name_id: InternId) !SlotId {
        const name = self.pool.get(name_id);
        if (lookupSlotInsensitive(self.currentScope(), name)) |existing| return existing;
        // Callable bodies may discover a later top-level variable as a global
        // while resolving the body, then continue resolving sibling flow-control
        // scopes.  Local slots must not reuse that global frame slot, otherwise
        // a loop variable can overwrite/clear the global fallback value at run
        // time.
        while (self.slotIsGlobal(self.next_local_slot)) {
            self.next_local_slot += 1;
        }
        const slot = self.next_local_slot;
        self.next_local_slot += 1;
        self.prog.max_slot = @max(self.prog.max_slot, slot + 1);
        try self.currentScope().put(self.a, name, slot);
        return slot;
    }
};

fn hasFutureTopLevelMixinDecl(ctx: *Ctx, name_slice: []const u8, after_span_start: u32) ResolveError!bool {
    const root = ctx.ast.root;
    const root_node = ctx.ast.getNode(root);
    if (root_node.tag != .stylesheet_root) return false;
    const root_children = readChildList(ctx.ast, root_node.payload);
    for (root_children) |u| {
        const child_idx: NodeIndex = @enumFromInt(u);
        const child = ctx.ast.getNode(child_idx);
        if (child.tag != .stmt_mixin_decl) continue;
        if (child.span_start <= after_span_start) continue;
        const child_name_id: InternId = @enumFromInt(ctx.ast.getExtraU32(child.payload));
        const raw_child_name = ctx.pool.get(child_name_id);
        const unescaped_child_name = try css_utils.unescapeSassIdentifier(ctx.a, raw_child_name);
        defer if (unescaped_child_name.ptr != raw_child_name.ptr) ctx.a.free(unescaped_child_name);
        if (identifierEqSass(unescaped_child_name, name_slice)) return true;
    }
    return false;
}

fn reserveNextCallableMixinBinding(ctx: *Ctx, name_slice: []const u8) ResolveError!MixinId {
    if (lookupIdentifierIdInsensitive(&ctx.pending_next_mixin_bindings, name_slice)) |existing| {
        return existing;
    }
    const gop = try ctx.pending_next_mixin_bindings.getOrPut(ctx.a, name_slice);
    if (!gop.found_existing) {
        gop.key_ptr.* = try ctx.a.dupe(u8, name_slice);
        gop.value_ptr.* = ctx.next_mixin_id;
        ctx.next_mixin_id += 1;
    }
    return gop.value_ptr.*;
}

fn popPendingNextMixinBinding(ctx: *Ctx, name_slice: []const u8) ?MixinId {
    var it = ctx.pending_next_mixin_bindings.iterator();
    while (it.next()) |entry| {
        if (!identifierEqSass(entry.key_ptr.*, name_slice)) continue;
        const key = entry.key_ptr.*;
        const id = entry.value_ptr.*;
        _ = ctx.pending_next_mixin_bindings.remove(key);
        return id;
    }
    return null;
}

fn lookupStaticSlotValue(prog: *const ResolvedProgram, slot: SlotId) ?value_mod.Value {
    for (prog.static_slot_values.items) |entry| {
        if (entry.slot == slot) return entry.value;
    }
    return null;
}

/// Determine whether Slot is a module variable declared with `!default`. with `@use ... with`
/// Used to hold static references to slots that can be overwritten (static branch pruning / inline).
fn slotIsConfigurableDefault(prog: *const ResolvedProgram, slot: SlotId) bool {
    var it = prog.default_vars.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == slot) return true;
    }
    return false;
}

fn setStaticSlotValue(prog: *ResolvedProgram, alloc: std.mem.Allocator, slot: SlotId, value: value_mod.Value) !void {
    for (prog.static_slot_values.items) |*entry| {
        if (entry.slot == slot) {
            entry.value = value;
            return;
        }
    }
    try prog.static_slot_values.append(alloc, .{
        .slot = slot,
        .value = value,
    });
}

fn setFlowLocalFallback(
    prog: *ResolvedProgram,
    alloc: std.mem.Allocator,
    slot: SlotId,
    fallback: SlotId,
) !void {
    for (prog.flow_local_fallbacks.items) |*entry| {
        if (entry.slot == slot) {
            entry.fallback = fallback;
            return;
        }
    }
    try prog.flow_local_fallbacks.append(alloc, .{
        .slot = slot,
        .fallback = fallback,
    });
}

fn removeStaticSlotValue(prog: *ResolvedProgram, slot: SlotId) void {
    var i: usize = 0;
    while (i < prog.static_slot_values.items.len) : (i += 1) {
        if (prog.static_slot_values.items[i].slot != slot) continue;
        _ = prog.static_slot_values.swapRemove(i);
        return;
    }
}

fn effectiveConfigSeedValue(loader: *const ModuleResolver, module_id: u32, slot: SlotId) ?value_mod.Value {
    const key = packSeedKey(module_id, slot);
    const acc = loader.config_seed_accum.get(key) orelse return null;
    if (acc.explicit_set and acc.explicit_value.kind() != .nil) return acc.explicit_value;
    if (acc.default_set) return acc.default_value;
    if (acc.explicit_set) return acc.explicit_value;
    return null;
}

fn lookupModuleStaticSlotValue(loader: *const ModuleResolver, module_id: u32, slot: SlotId) ?value_mod.Value {
    if (module_id >= loader.records_ptr.items.len) return null;
    return lookupStaticSlotValue(&loader.records_ptr.items[module_id].prog, slot);
}

fn lookupModuleStaticOrConfigSeedValue(loader: *const ModuleResolver, module_id: u32, slot: SlotId) ?value_mod.Value {
    if (lookupModuleStaticSlotValue(loader, module_id, slot)) |value| return value;
    return effectiveConfigSeedValue(loader, module_id, slot);
}

const ResolverEvalEnv = struct {
    ctx: *Ctx,
    allow_configurable_defaults: bool = false,

    pub fn allocator(self: *const ResolverEvalEnv) std.mem.Allocator {
        return self.ctx.a;
    }

    /// Long-lived alloc used when appending to Sidecar Value pool (number / callable / ...).
    /// If you append with per-module arena (`ctx.a`), bundle.deinit will appear after arena.deinit.
    /// Be sure to use ResolvedBundle.shared_value_pools_alloc to free the same memory again and segfault it.
    // Returns an alloc (= `ctx.root_alloc` = caller's allocator) with the same lifetime as ///.
    pub fn poolAlloc(self: *const ResolverEvalEnv) std.mem.Allocator {
        return self.ctx.root_alloc;
    }

    pub fn colorAllocator(self: *const ResolverEvalEnv) std.mem.Allocator {
        return self.ctx.root_alloc;
    }

    pub fn pool(self: *const ResolverEvalEnv) *InternPool {
        return self.ctx.pool;
    }

    pub fn numberPool(self: *const ResolverEvalEnv) *value_mod.NumberPool {
        return self.ctx.prog.value_number_pool;
    }

    pub fn listMetaPool(self: *const ResolverEvalEnv) *value_mod.ListMetaPool {
        return self.ctx.prog.value_list_meta_pool;
    }

    pub fn stringFlagsPool(self: *const ResolverEvalEnv) *value_mod.StringFlagsPool {
        return self.ctx.prog.value_string_flags_pool;
    }

    pub fn callablePayloadPool(self: *const ResolverEvalEnv) *value_mod.CallablePayloadPool {
        return self.ctx.prog.value_callable_payload_pool;
    }

    pub fn colorPool(self: *const ResolverEvalEnv) ?*value_mod.ColorPool {
        return self.ctx.color_pool;
    }

    pub fn lookupVar(self: *const ResolverEvalEnv, slot: SlotId) ?value_mod.Value {
        // The `!default` variable can be overwritten by a subsequent `@use ... with`, so the
        // Static branch pruning with static values is dangerous. Defer resolution until runtime eval.
        if (!self.allow_configurable_defaults and slotIsConfigurableDefault(self.ctx.prog, slot)) return null;
        return lookupStaticSlotValue(self.ctx.prog, slot);
    }

    pub fn lookupCrossVar(self: *const ResolverEvalEnv, module_id: u32, slot: SlotId) ?value_mod.Value {
        if (self.ctx.loader) |loader| {
            if (module_id < loader.records_ptr.items.len) {
                const target_prog = &loader.records_ptr.items[module_id].prog;
                if (lookupStaticSlotValue(target_prog, slot)) |value| return value;
                if (!self.allow_configurable_defaults and slotIsConfigurableDefault(target_prog, slot)) return null;
            }
            return effectiveConfigSeedValue(loader, module_id, slot);
        }
        return null;
    }

    pub fn getStaticList(self: *const ResolverEvalEnv, handle: value_mod.ListHandle) ?[]const value_mod.Value {
        const idx: usize = @intCast(handle);
        if (idx >= self.ctx.static_eval_store.lists.items.len) return null;
        return self.ctx.static_eval_store.lists.items[idx];
    }

    pub fn getStaticListPool(self: *const ResolverEvalEnv) []const []const value_mod.Value {
        return self.ctx.static_eval_store.lists.items;
    }

    pub fn pushStaticList(
        self: *const ResolverEvalEnv,
        items: []const value_mod.Value,
        separator: value_mod.ListSeparator,
        bracketed: bool,
        is_map: bool,
        slash_coercible: bool,
    ) !value_mod.Value {
        const stored = try self.ctx.prog.arena.allocator().dupe(value_mod.Value, items);
        const handle: value_mod.ListHandle = @intCast(self.ctx.static_eval_store.lists.items.len);
        try self.ctx.static_eval_store.lists.append(self.ctx.static_eval_store.alloc, stored);
        return value_mod.Value.listWithMetaEx(handle, separator, bracketed, is_map, slash_coercible);
    }
};

fn tryStaticEvalValueWithConfigDefaults(ctx: *Ctx, expr: ExprIndex, allow_configurable_defaults: bool) ?value_mod.Value {
    var env: ResolverEvalEnv = .{
        .ctx = ctx,
        .allow_configurable_defaults = allow_configurable_defaults,
    };
    return resolver_eval.eval(&env, ctx.prog, expr) catch null;
}

fn tryStaticEvalValue(ctx: *Ctx, expr: ExprIndex) ?value_mod.Value {
    return tryStaticEvalValueWithConfigDefaults(ctx, expr, false);
}

fn tryAppendStaticValueExpr(ctx: *Ctx, value: value_mod.Value, span: Span) ResolveError!?ExprIndex {
    switch (value.kind()) {
        .number => return try appendNumberLiteral(ctx.prog, ctx.a, value.asF64(ctx.prog.value_number_pool), value.unitId(ctx.prog.value_number_pool), span),
        .string => return try appendExpr(ctx.prog, ctx.a, .{
            .kind = .literal_string,
            .payload = packLiteralStringPayload(
                value.stringIntern(),
                value.stringQuoted(ctx.prog.value_string_flags_pool.items),
                value.stringNamedColorLiteral(ctx.prog.value_string_flags_pool.items),
            ),
            .span = span,
        }),
        .boolean => return try appendExpr(ctx.prog, ctx.a, .{
            .kind = .literal_bool,
            .payload = if (value.p64Of() != 0) 1 else 0,
            .span = span,
        }),
        .nil => return try appendExpr(ctx.prog, ctx.a, .{
            .kind = .literal_null,
            .payload = 0,
            .span = span,
        }),
        .color => {
            const color_pool = ctx.color_pool orelse return null;
            const entry = value.colorEntry(color_pool).*;
            if (entry.space != .srgb or entry.missing != 0) return null;
            for (entry.channels) |channel| {
                if (!std.math.isFinite(channel) or channel < 0.0 or channel > 1.0) return null;
            }
            const channel_tol: f64 = 5e-6;
            for (entry.channels[0..3]) |channel| {
                const byte = std.math.clamp(channel, 0.0, 1.0) * 255.0;
                if (@abs(byte - @round(byte)) > channel_tol) return null;
            }
            const clamp_unit = struct {
                fn run(v: f64) f64 {
                    return std.math.clamp(v, 0.0, 1.0);
                }
            }.run;
            const clamp_byte = struct {
                fn run(v: f64) u8 {
                    const rounded: f64 = @round(std.math.clamp(v, 0.0, 255.0));
                    return @intFromFloat(rounded);
                }
            }.run;
            const rgba: u32 =
                (@as(u32, clamp_byte(clamp_unit(entry.channels[0]) * 255.0)) << 24) |
                (@as(u32, clamp_byte(clamp_unit(entry.channels[1]) * 255.0)) << 16) |
                (@as(u32, clamp_byte(clamp_unit(entry.channels[2]) * 255.0)) << 8) |
                @as(u32, clamp_byte(clamp_unit(entry.channels[3]) * 255.0));
            var flags: u8 = 0;
            if (entry.inspect_repr == .literal_long_hex) flags |= 0b0000_0001;
            if (entry.inspect_repr == .legacy_rgb_function) flags |= 0b0000_1000;
            if (entry.inspect_uppercase_hex) flags |= 0b0000_0010;
            if (entry.prefer_long_hex and entry.inspect_repr == .auto) flags |= 0b0000_0100;
            const color_idx: u32 = @intCast(ctx.prog.color_literals.items.len);
            try ctx.prog.color_literals.append(ctx.a, .{
                .rgba = rgba,
                .alpha = entry.channels[3],
                .flags = flags,
            });
            return try appendExpr(ctx.prog, ctx.a, .{
                .kind = .literal_color,
                .payload = color_idx,
                .span = span,
            });
        },
        .list => {
            const handle: usize = @intCast(value.listHandle());
            if (handle >= ctx.static_eval_store.lists.items.len) return null;
            const items = ctx.static_eval_store.lists.items[handle];
            var elems: std.ArrayListUnmanaged(ExprIndex) = .empty;
            defer elems.deinit(ctx.a);
            try elems.ensureTotalCapacity(ctx.a, items.len);
            for (items) |item| {
                const child = try tryAppendStaticValueExpr(ctx, item, span) orelse return null;
                try elems.append(ctx.a, child);
            }
            const lmp = ctx.prog.value_list_meta_pool.items;
            return try appendListExprFromElems(
                ctx,
                elems.items,
                value.listSeparator(lmp),
                value.listBracketed(lmp),
                value.listIsMap(lmp),
                value.listCoerceSlash(lmp),
                span,
            );
        },
        else => return null,
    }
}

fn resolveExprMaybeStaticLiteral(ast: *const ast_flat.Ast, ctx: *Ctx, node: NodeIndex) ResolveError!ExprIndex {
    const expr = try resolveExpr(ast, ctx, node);
    // Inside a Flow control (@while/@for/@each/@if) or within a callable body,
    // static_slot_values remains the value at top-level initialization and is not updated, so
    // If static substitution is performed there, it will be inconsistent with the runtime value after reassignment.
    // Example: `$i: 1; @while ... { @include m($i); $i: $i + 1; }` inlines `$i` into literal 1.
    if (ctx.flow_control_depth > 0 or ctx.in_callable) return expr;
    const n = ast.getNode(node);
    const span = Span{ .start = n.span_start, .end = n.span_end };
    const static_value = tryStaticEvalValue(ctx, expr) orelse return expr;
    return (try tryAppendStaticValueExpr(ctx, static_value, span)) orelse expr;
}

const WithConfigEntry = data_mod.WithConfigEntry;

const identifierEq = name_lookup.identifierEq;
const hasMixedIdentifierAliasChars = name_lookup.hasMixedIdentifierAliasChars;
const lookupConfigVarTargetInsensitive = name_lookup.lookupConfigVarTargetInsensitive;
const lookupCallableTargetInsensitive = name_lookup.lookupCallableTargetInsensitive;
const lookupIdentifierIdInsensitive = name_lookup.lookupIdentifierIdInsensitive;
const lookupIdentifierIdKeyInsensitive = name_lookup.lookupIdentifierIdKeyInsensitive;
const lookupBoolFlagInsensitive = name_lookup.lookupBoolFlagInsensitive;
const lookupVoidFlagInsensitive = name_lookup.lookupVoidFlagInsensitive;
const lookupUseBindingInsensitive = name_lookup.lookupUseBindingInsensitive;
const lookupStringMapIdentifierInsensitive = name_lookup.lookupStringMapIdentifierInsensitive;
const lookupStringMapIdentifierInsensitiveNoMixedKeys = name_lookup.lookupStringMapIdentifierInsensitiveNoMixedKeys;

const map_copy = @import("map_copy.zig");
const copyStringMapWithOwnedKeys = map_copy.copyStringMapWithOwnedKeys;
const copyStringSetWithOwnedKeys = map_copy.copyStringSetWithOwnedKeys;

/// markAmbiguousName in conjunction with scope undo log. set is ambiguous_star_* in ctx
/// (one of 3 types), specify specificity with map_id. record to undo log is
/// Only when there is an actual change from "non-existence to existence".
fn markAmbiguousNameCtx(
    ctx: *Ctx,
    map_id: UndoMapId,
    set: *std.StringHashMapUnmanaged(void),
    name: []const u8,
) !void {
    if (lookupVoidFlagInsensitive(set, name)) return;
    // Separately from case-insensitive lookup to determine found_existing with exact key match
    // View the result of getOrPut (same logic as old code).
    const gop = try set.getOrPut(ctx.a, name);
    if (gop.found_existing) return; // exact byte match existing, state unchanged
    const dup_key = try ctx.a.dupe(u8, name);
    gop.key_ptr.* = dup_key;
    if (ctx.undo_layers.items.len > 0) {
        const top = &ctx.undo_layers.items[ctx.undo_layers.items.len - 1];
        try top.entries.append(ctx.a, .{
            .map_id = map_id,
            .was_present = false,
            .key = dup_key,
            .prev = .{ .void_v = {} },
        });
    }
}

const sameCallableTarget = module_exports.sameCallableTarget;

fn internIdentifierDashCanonical(pool: *InternPool, alloc: std.mem.Allocator, name_id: InternId) !InternId {
    const raw = pool.get(name_id);
    var needs_normalize = false;
    for (raw) |c| {
        if (c == '_') {
            needs_normalize = true;
            break;
        }
    }
    if (!needs_normalize) return name_id;

    const buf = try alloc.alloc(u8, raw.len);
    defer alloc.free(buf);
    for (raw, 0..) |c, i| {
        buf[i] = if (c == '_') '-' else c;
    }
    return pool.intern(buf);
}

fn isDoubleDashIdentifier(name: []const u8) bool {
    return name.len >= 2 and name[0] == '-' and name[1] == '-';
}

fn cssIdentEquals(name: []const u8, expected_lower: []const u8) bool {
    if (name.len != expected_lower.len) return false;
    for (name, expected_lower) |raw, want| {
        var c = raw;
        if (c == '_') c = '-';
        if (std.ascii.toLower(c) != want) return false;
    }
    return true;
}

fn isReservedFunctionName(name: []const u8) bool {
    const reserved_lowercase = [_][]const u8{ "element", "expression", "url", "and", "or", "not" };
    for (reserved_lowercase) |r| {
        if (std.mem.eql(u8, name, r)) return true;
    }
    if (std.ascii.eqlIgnoreCase(name, "type")) return true;
    if (name.len > 1 and name[0] == '-') {
        if (std.mem.findScalar(u8, name[1..], '-')) |dash| {
            const base = name[dash + 2 ..];
            if (std.mem.eql(u8, base, "element")) return true;
        }
    }
    return false;
}

fn cssSpecialBaseName(raw_name: []const u8) ?[]const u8 {
    if (raw_name.len == 0) return null;
    if (std.ascii.startsWithIgnoreCase(raw_name, "progid:")) return "progid";

    var base = raw_name;
    if (raw_name[0] == '-') {
        if (std.mem.findScalar(u8, raw_name[1..], '-')) |dash_idx| {
            base = raw_name[dash_idx + 2 ..];
        }
    }
    if (std.mem.findScalar(u8, base, ':')) |colon| {
        base = base[0..colon];
    }

    if (cssIdentEquals(base, "calc") or
        cssIdentEquals(base, "element") or
        cssIdentEquals(base, "expression") or
        cssIdentEquals(base, "progid") or
        cssIdentEquals(base, "url"))
    {
        return base;
    }
    return null;
}

fn isCssSpecialPassthroughFunction(name: []const u8) bool {
    if (cssSpecialBaseName(name)) |base| {
        return cssIdentEquals(base, "element") or
            cssIdentEquals(base, "expression") or
            cssIdentEquals(base, "progid") or
            cssIdentEquals(base, "url");
    }
    return false;
}

fn hasVendorPrefixedFunctionName(raw_name: []const u8) bool {
    return raw_name.len > 0 and raw_name[0] == '-' and
        std.mem.findScalar(u8, raw_name[1..], '-') != null;
}

fn canonicalizeCssSpecialFunctionName(alloc: std.mem.Allocator, raw_name: []const u8) ![]const u8 {
    if (cssSpecialBaseName(raw_name)) |base| {
        if (cssIdentEquals(base, "url")) {
            const owned = try alloc.dupe(u8, base);
            for (owned) |*c| c.* = std.ascii.toLower(c.*);
            return owned;
        }
    }
    if (std.ascii.startsWithIgnoreCase(raw_name, "progid:")) {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(alloc);
        try out.ensureTotalCapacityPrecise(alloc, raw_name.len);
        for (raw_name[0..7]) |c| {
            out.appendAssumeCapacity(std.ascii.toLower(c));
        }
        try out.appendSlice(alloc, raw_name[7..]);
        return try out.toOwnedSlice(alloc);
    }
    if (raw_name.len > 0 and raw_name[0] == '-') {
        if (std.mem.findScalar(u8, raw_name, ':')) |colon| {
            const prefix = raw_name[0..colon];
            if (prefix.len >= 6 and std.ascii.eqlIgnoreCase(prefix[prefix.len - 6 ..], "progid")) {
                var out: std.ArrayListUnmanaged(u8) = .empty;
                defer out.deinit(alloc);
                try out.ensureTotalCapacityPrecise(alloc, raw_name.len);
                for (raw_name[0..colon]) |c| {
                    out.appendAssumeCapacity(std.ascii.toLower(c));
                }
                try out.appendSlice(alloc, raw_name[colon..]);
                return try out.toOwnedSlice(alloc);
            }
        }
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try out.ensureTotalCapacityPrecise(alloc, raw_name.len);
    for (raw_name) |c| {
        out.appendAssumeCapacity(std.ascii.toLower(c));
    }
    return try out.toOwnedSlice(alloc);
}

fn resolveCssSpecialOpaqueCallExpr(ctx: *Ctx, span: Span, canonical_name: []const u8) !ExprIndex {
    const start: usize = @min(ctx.ast.source.len, @as(usize, span.start));
    const end: usize = @min(ctx.ast.source.len, @as(usize, span.end));
    if (end <= start) return error.SassError;
    const raw = ctx.ast.source[start..end];
    const lparen = std.mem.findScalar(u8, raw, '(') orelse return error.SassError;
    const rparen = std.mem.lastIndexOfScalar(u8, raw, ')') orelse return error.SassError;
    if (rparen < lparen) return error.SassError;
    const inner = raw[lparen + 1 .. rparen];
    const text = try std.fmt.allocPrint(ctx.a, "{s}({s})", .{ canonical_name, inner });
    const id = if (ctx.calc_arg_mode) try markCalcArgText(ctx, text) else try ctx.pool.intern(text);
    return try appendExpr(ctx.prog, ctx.a, .{
        .kind = .literal_string,
        .payload = packLiteralStringPayload(id, false, false),
        .span = span,
    });
}

fn isIdentifierChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

fn markCalcArgText(ctx: *Ctx, raw: []const u8) ResolveError!InternId {
    const marked = try std.fmt.allocPrint(ctx.a, "{s}{s}", .{ calc_arg_marker, raw });
    defer ctx.a.free(marked);
    return try ctx.pool.intern(marked);
}

fn markCalcInterpText(ctx: *Ctx, raw: []const u8) ResolveError!InternId {
    const marked = try std.fmt.allocPrint(ctx.a, "{s}{s}", .{ calc_interp_marker, raw });
    defer ctx.a.free(marked);
    return try ctx.pool.intern(marked);
}

fn shouldPreserveCalcParensNode(ast: *const ast_flat.Ast, ctx: *Ctx, node: NodeIndex) bool {
    const n = ast.getNode(node);
    return switch (n.tag) {
        .expr_paren => shouldPreserveCalcParensNode(ast, ctx, @enumFromInt(n.payload)),
        .expr_unquoted_ident, .expr_interp, .expr_string_interp => true,
        .expr_func_call => blk: {
            const off: ExtraIndex = n.payload;
            const name_id: InternId = @enumFromInt(ast.getExtraU32(off));
            const ns_id: InternId = @enumFromInt(ast.getExtraU32(off + 1));
            if (ns_id != .none) break :blk false;
            const raw_name = ctx.pool.get(name_id);
            break :blk identifierEq(raw_name, "var") or identifierEq(raw_name, "env");
        },
        else => false,
    };
}

fn nodeIsCalcLikeFunctionCall(ast: *const ast_flat.Ast, ctx: *Ctx, node: NodeIndex) bool {
    const n = ast.getNode(node);
    return switch (n.tag) {
        .expr_paren => nodeIsCalcLikeFunctionCall(ast, ctx, @enumFromInt(n.payload)),
        .expr_func_call => blk: {
            const off: ExtraIndex = n.payload;
            const name_id: InternId = @enumFromInt(ast.getExtraU32(off));
            const ns_id: InternId = @enumFromInt(ast.getExtraU32(off + 1));
            if (ns_id != .none) break :blk false;
            const raw_name = ctx.pool.get(name_id);
            break :blk identifierEq(raw_name, "calc") or
                identifierEq(raw_name, "min") or
                identifierEq(raw_name, "max") or
                identifierEq(raw_name, "clamp");
        },
        else => false,
    };
}

fn nodeIsCalcFunctionCall(ast: *const ast_flat.Ast, ctx: *Ctx, node: NodeIndex) bool {
    const n = ast.getNode(node);
    return switch (n.tag) {
        .expr_paren => nodeIsCalcFunctionCall(ast, ctx, @enumFromInt(n.payload)),
        .expr_func_call => blk: {
            const off: ExtraIndex = n.payload;
            const name_id: InternId = @enumFromInt(ast.getExtraU32(off));
            const ns_id: InternId = @enumFromInt(ast.getExtraU32(off + 1));
            if (ns_id != .none) break :blk false;
            const raw_name = ctx.pool.get(name_id);
            break :blk identifierEq(raw_name, "calc");
        },
        else => false,
    };
}

fn nodeContainsCalcArgOpaqueCssFunction(ast: *const ast_flat.Ast, ctx: *Ctx, node: NodeIndex) bool {
    const n = ast.getNode(node);
    return switch (n.tag) {
        .expr_paren => nodeContainsCalcArgOpaqueCssFunction(ast, ctx, @enumFromInt(n.payload)),
        .expr_unary_op => blk: {
            const off: ExtraIndex = n.payload;
            const operand: NodeIndex = @enumFromInt(ast.getExtraU32(off));
            break :blk nodeContainsCalcArgOpaqueCssFunction(ast, ctx, operand);
        },
        .expr_binary_op, .expr_slash_expr => blk: {
            const off: ExtraIndex = n.payload;
            const lhs: NodeIndex = @enumFromInt(ast.getExtraU32(off));
            const rhs: NodeIndex = @enumFromInt(ast.getExtraU32(off + 1));
            break :blk nodeContainsCalcArgOpaqueCssFunction(ast, ctx, lhs) or
                nodeContainsCalcArgOpaqueCssFunction(ast, ctx, rhs);
        },
        .expr_func_call => blk: {
            const off: ExtraIndex = n.payload;
            const name_id: InternId = @enumFromInt(ast.getExtraU32(off));
            const ns_id: InternId = @enumFromInt(ast.getExtraU32(off + 1));
            if (ns_id != .none) break :blk false;
            const raw_name = ctx.pool.get(name_id);
            break :blk identifierEq(raw_name, "var") or identifierEq(raw_name, "env");
        },
        else => false,
    };
}

fn resolveCalcArgInterpPart(ast: *const ast_flat.Ast, ctx: *Ctx, node: NodeIndex, span: Span) ResolveError!ExprIndex {
    const n = ast.getNode(node);
    if (extractCalcArgStaticNumberInfo(ast, ctx, node)) |num| {
        return try appendNumberLiteral(ctx.prog, ctx.a, num.value, num.unit_id, span);
    }
    if (nodeContainsCalcArgOpaqueCssFunction(ast, ctx, node) and
        !calcArgNodeNeedsRuntimeInterpolation(ast, node) and
        n.span_start <= n.span_end and n.span_end <= ast.source.len)
    {
        const raw_expr = std.mem.trim(u8, ast.source[n.span_start..n.span_end], " \t\r\n");
        if (raw_expr.len != 0) {
            const marked_id = try markCalcArgText(ctx, raw_expr);
            return try appendExpr(ctx.prog, ctx.a, .{
                .kind = .literal_string,
                .payload = packLiteralStringPayload(marked_id, false, false),
                .span = span,
            });
        }
    }
    return resolveExpr(ast, ctx, node);
}

fn nodeIsSlashLiteralOperand(ast: *const ast_flat.Ast, node: NodeIndex) bool {
    const n = ast.getNode(node);
    return switch (n.tag) {
        .expr_paren => nodeIsSlashLiteralOperand(ast, @enumFromInt(n.payload)),
        .expr_color_hex,
        => true,
        else => false,
    };
}

fn parseWithConfigEntries(ctx: *Ctx, config_extra: ExtraIndex) ResolveError![]WithConfigEntry {
    var out: std.ArrayListUnmanaged(WithConfigEntry) = .empty;
    errdefer out.deinit(ctx.a);

    const count = ctx.ast.getExtraU32(config_extra);
    var p: ExtraIndex = config_extra + 1;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const name_id: InternId = @enumFromInt(ctx.ast.getExtraU32(p));
        const expr_node: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(p + 1));
        const flags = ctx.ast.getExtraU32(p + 2);
        p += 3;

        const expr_idx = resolveExpr(ctx.ast, ctx, expr_node) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SassError,
        };
        var env: ResolverEvalEnv = .{ .ctx = ctx, .allow_configurable_defaults = true };
        const value = resolver_eval.eval(&env, ctx.prog, expr_idx) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SassError,
        };
        const name = ctx.pool.get(name_id);
        for (out.items) |existing| {
            if (identifierEq(existing.name, name)) return error.SassError;
        }
        try out.append(ctx.a, .{
            .name = name,
            .value = value,
            .is_default = (flags & 0b0000_0001) != 0,
        });
    }

    return try out.toOwnedSlice(ctx.a);
}

fn updateTopLevelStaticConfigValue(ctx: *Ctx, slot: SlotId, value_expr: ExprIndex) ResolveError!void {
    var env: ResolverEvalEnv = .{ .ctx = ctx, .allow_configurable_defaults = true };
    const value = resolver_eval.eval(&env, ctx.prog, value_expr) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (decodeCrossAssignSlot(slot)) |cross| {
                if (ctx.loader) |loader| {
                    if (cross.module_id < loader.records_ptr.items.len) {
                        removeStaticSlotValue(&loader.records_ptr.items[cross.module_id].prog, cross.slot);
                    }
                }
            } else {
                removeStaticSlotValue(ctx.prog, slot);
            }
            return;
        },
    };

    if (decodeCrossAssignSlot(slot)) |cross| {
        const loader = try requireModuleLoader(ctx);
        std.debug.assert(cross.module_id < loader.records_ptr.items.len);
        const target_prog = &loader.records_ptr.items[cross.module_id].prog;
        try setStaticSlotValue(target_prog, target_prog.arena.allocator(), cross.slot, value);
        return;
    }
    try setStaticSlotValue(ctx.prog, ctx.a, slot, value);
}

fn lookupStaticValueForSlotIncludingCross(ctx: *const Ctx, slot: SlotId) ?value_mod.Value {
    if (decodeCrossAssignSlot(slot)) |cross| {
        if (ctx.loader) |loader| return lookupModuleStaticOrConfigSeedValue(loader, cross.module_id, cross.slot);
        return null;
    }
    return lookupStaticSlotValue(ctx.prog, slot);
}

fn lookupVisibleConfigVarValue(ctx: *const Ctx, name: []const u8) ?value_mod.Value {
    if (ctx.visiting_imports.items.len != 0) {
        return ctx.getStaticConfigVar(name);
    }

    if (ctx.lookupInitialConfigValue(name)) |value| return value;

    var scope_i: usize = ctx.scopes.items.len;
    while (scope_i > 0) {
        scope_i -= 1;
        if (lookupSlotInsensitive(&ctx.scopes.items[scope_i], name)) |slot| {
            return lookupStaticValueForSlotIncludingCross(ctx, slot);
        }
    }

    if (lookupConfigVarTargetInsensitive(&ctx.star_vars, name)) |target| {
        if (ctx.loader) |loader| return lookupModuleStaticOrConfigSeedValue(loader, target.module_id, target.slot);
        return null;
    }

    if (lookupGlobalSlot(ctx.prog, name)) |slot| {
        return lookupStaticValueForSlotIncludingCross(ctx, slot);
    }
    return null;
}

fn moduleSlotIsTopLevelDefaultVar(loader: *const ModuleResolver, module_id: u32, slot: SlotId) bool {
    if (module_id >= loader.records_ptr.items.len) return false;
    var it = loader.records_ptr.items[module_id].prog.default_vars.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == slot) return true;
    }
    return false;
}

fn tryResolveCrossVarStaticExpr(
    ctx: *Ctx,
    cross: CrossVarTarget,
    span: Span,
) ResolveError!?ExprIndex {
    // Inside deferred callable-default resolution, keep cross_var_ref rather
    // than materializing the current value. The compiler's compileParamDefault
    //can only encode atom shapes (var_ref/cross_slot/value/binary/...); a
    // materialized list/map becomes `.list` which falls through to .none and
    // causes runtime BuiltinArity when the default is needed. Late-binding
    // via cross_slot also matches Sass's call-time default-evaluation model.
    if (ctx.resolving_callable_default) return null;
    const loader = ctx.loader orelse return null;
    if (lookupModuleStaticSlotValue(loader, cross.module_id, cross.slot)) |value| {
        if (try tryAppendStaticValueExpr(ctx, value, span)) |expr| return expr;
    }
    if (moduleSlotIsTopLevelDefaultVar(loader, cross.module_id, cross.slot)) {
        return null;
    }
    if (effectiveConfigSeedValue(loader, cross.module_id, cross.slot)) |seed| {
        if (try tryAppendStaticValueExpr(ctx, seed, span)) |expr| return expr;
    }
    return null;
}

fn captureImportConfigSnapshot(ctx: *Ctx) ResolveError!void {
    // Var exposed by import-through-@forward is placed in snapshot with top priority.
    // However, import-forwarded `!default` var is only used if there is a subsequent bare assign
    // Shadow on local/global side.
    var import_default_sources: std.StringHashMapUnmanaged(bool) = .empty;
    defer import_default_sources.deinit(ctx.a);
    var star_it = ctx.star_vars.iterator();
    while (star_it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (ctx.getStaticConfigVar(name) != null) continue;
        if (ctx.loader) |loader| {
            const target = entry.value_ptr.*;
            const value = lookupModuleStaticOrConfigSeedValue(loader, target.module_id, target.slot) orelse continue;
            try ctx.appendStaticConfigVarKnownAbsent(name, value);
            const from_default = lookupBoolFlagInsensitive(&ctx.import_star_vars, name) orelse false;
            try import_default_sources.put(ctx.a, name, from_default);
        }
    }

    var scope_i: usize = ctx.scopes.items.len;
    while (scope_i > 0) {
        scope_i -= 1;
        var sit = ctx.scopes.items[scope_i].iterator();
        while (sit.next()) |entry| {
            const name = entry.key_ptr.*;
            const slot = entry.value_ptr.*;
            const value = lookupStaticValueForSlotIncludingCross(ctx, slot) orelse continue;
            if (ctx.getStaticConfigVar(name) == null) {
                try ctx.appendStaticConfigVarKnownAbsent(name, value);
                continue;
            }
            const from_default_star = import_default_sources.get(name) orelse false;
            if (!from_default_star) continue;
            if (decodeCrossAssignSlot(slot) != null or !hasResolvedAssignToSlot(ctx.prog, slot)) continue;
            try ctx.setStaticConfigVar(name, value);
            try import_default_sources.put(ctx.a, name, false);
        }
    }

    var git = ctx.prog.global_slots.iterator();
    while (git.next()) |entry| {
        const name = entry.key_ptr.*;
        const slot = entry.value_ptr.*;
        const value = lookupStaticValueForSlotIncludingCross(ctx, slot) orelse continue;
        if (ctx.getStaticConfigVar(name) == null) {
            try ctx.appendStaticConfigVarKnownAbsent(name, value);
            continue;
        }
        const from_default_star = import_default_sources.get(name) orelse false;
        if (!from_default_star) continue;
        if (!hasResolvedAssignToSlot(ctx.prog, slot)) continue;
        try ctx.setStaticConfigVar(name, value);
        try import_default_sources.put(ctx.a, name, false);
    }
}

const packSeedKey = data_mod.packConfigSeedKey;

const cross_assign_slot_flag: u32 = 0x8000_0000;
const cross_assign_slot_mask: u32 = 0x0000_ffff;
const cross_assign_module_mask: u32 = 0x7fff;

fn encodeCrossAssignSlot(module_id: u32, slot: SlotId) ResolveError!SlotId {
    if (module_id > cross_assign_module_mask) return error.CrossAssignOverflow;
    if (slot > cross_assign_slot_mask) return error.CrossAssignOverflow;
    return @intCast(cross_assign_slot_flag | (module_id << 16) | (slot & cross_assign_slot_mask));
}

pub fn decodeCrossAssignSlot(slot: SlotId) ?struct { module_id: u32, slot: SlotId } {
    if ((slot & cross_assign_slot_flag) == 0) return null;
    return .{
        .module_id = (slot >> 16) & cross_assign_module_mask,
        .slot = slot & cross_assign_slot_mask,
    };
}

fn lookupStarMixinMapInsensitive(ctx: *const Ctx, name: []const u8) ?CrossCallableTarget {
    if (ctx.star_mixins_have_mixed_alias_keys) {
        return lookupCallableTargetInsensitive(&ctx.star_mixins, name);
    }
    return lookupStringMapIdentifierInsensitiveNoMixedKeys(CrossCallableTarget, &ctx.star_mixins, name);
}

fn lookupStarFunctionMapInsensitive(ctx: *const Ctx, name: []const u8) ?CrossCallableTarget {
    if (ctx.star_functions_have_mixed_alias_keys) {
        return lookupCallableTargetInsensitive(&ctx.star_functions, name);
    }
    return lookupStringMapIdentifierInsensitiveNoMixedKeys(CrossCallableTarget, &ctx.star_functions, name);
}

fn noteStarMixinMapKey(ctx: *Ctx, key: []const u8) void {
    if (hasMixedIdentifierAliasChars(key)) ctx.star_mixins_have_mixed_alias_keys = true;
}

fn noteStarFunctionMapKey(ctx: *Ctx, key: []const u8) void {
    if (hasMixedIdentifierAliasChars(key)) ctx.star_functions_have_mixed_alias_keys = true;
}

fn lookupCapturedUseBindingInsensitive(
    bindings: []const PendingUseBinding,
    name: []const u8,
) ?UseBinding {
    for (bindings) |entry| {
        if (identifierEq(entry.key, name)) return entry.value;
    }
    return null;
}

fn lookupUseBindingInContext(ctx: *const Ctx, name: []const u8) ?UseBinding {
    return lookupUseBindingInsensitive(&ctx.prog.use_map, name) orelse
        lookupCapturedUseBindingInsensitive(ctx.deferred_callable_default_use_bindings, name);
}

fn lookupSlotInsensitive(
    map: *const std.StringHashMapUnmanaged(SlotId),
    name: []const u8,
) ?SlotId {
    return lookupStringMapIdentifierInsensitive(SlotId, map, name);
}

fn lookupGlobalSlot(prog: *const ResolvedProgram, name: []const u8) ?SlotId {
    if (prog.global_slots_have_mixed_alias_keys) {
        return lookupSlotInsensitive(&prog.global_slots, name);
    }
    return lookupStringMapIdentifierInsensitiveNoMixedKeys(SlotId, &prog.global_slots, name);
}

fn packUserFunctionLookupCacheKey(module_id: u32, name_id: InternId) u64 {
    return (@as(u64, module_id) << 32) | @as(u64, @intFromEnum(name_id));
}

fn hasResolvedAssignToSlot(prog: *const ResolvedProgram, slot: SlotId) bool {
    for (prog.assign_stmts.items) |assign| {
        if (decodeCrossAssignSlot(assign.slot) != null) continue;
        if (assign.slot == slot) return true;
    }
    return false;
}

fn argNameEq(ctx: *Ctx, arg_name: InternId, expected: []const u8) bool {
    if (arg_name == .none or arg_name == call_arg_splat_sentinel) return false;
    var raw = ctx.pool.get(arg_name);
    if (raw.len > 0 and raw[0] == '$') raw = raw[1..];
    return identifierEq(raw, expected);
}

const LiteralStringInfo = struct {
    id: InternId,
    text: []const u8,
};

fn literalStringInfo(ctx: *Ctx, e: ExprIndex) ?LiteralStringInfo {
    const ex = ctx.prog.exprs.items[e];
    if (ex.kind != .literal_string) return null;
    const s = unpackLiteralStringPayload(ex.payload);
    return .{
        .id = s.id,
        .text = ctx.pool.get(s.id),
    };
}

fn unquoteCalcLiteralTextId(ast: *const ast_flat.Ast, pool: *InternPool, node: NodeIndex) ?InternId {
    if (node == .none) return null;
    const call_node = ast.getNode(node);
    if (call_node.tag != .expr_func_call) return null;

    const off: ExtraIndex = call_node.payload;
    const name_id: InternId = @enumFromInt(ast.getExtraU32(off));
    const ns_id: InternId = @enumFromInt(ast.getExtraU32(off + 1));
    const arg_count = ast.getExtraU32(off + 2);
    if (arg_count != 1) return null;

    const is_unquote = blk: {
        if (ns_id == .none and identifierEq(pool.get(name_id), "unquote")) break :blk true;
        if (ns_id != .none and identifierEq(pool.get(ns_id), "string") and identifierEq(pool.get(name_id), "unquote")) break :blk true;
        break :blk false;
    };
    if (!is_unquote) return null;

    const inner_node: NodeIndex = @enumFromInt(ast.getExtraU32(off + 3));
    const inner = ast.getNode(inner_node);
    if (inner.tag != .expr_string_literal) return null;
    if ((inner.flags & 1) == 0) return null;

    const inner_off: ExtraIndex = inner.payload;
    const text_id: InternId = @enumFromInt(ast.getExtraU32(inner_off));
    const text = std.mem.trim(u8, pool.get(text_id), " \t\r\n");
    if (!(std.ascii.startsWithIgnoreCase(text, "calc(") and text.len >= 6 and text[text.len - 1] == ')')) return null;
    return text_id;
}

fn tryFoldLiteralStringExpr(ctx: *Ctx, e: ExprIndex) !?InternId {
    const ex = ctx.prog.exprs.items[e];
    return switch (ex.kind) {
        .literal_string => unpackLiteralStringPayload(ex.payload).id,
        .interp => blk: {
            const interp = ctx.prog.interp_exprs.items[ex.payload];
            var out: std.ArrayListUnmanaged(u8) = .empty;
            defer out.deinit(ctx.a);
            var i: u32 = 0;
            while (i < interp.part_count) : (i += 1) {
                const part_expr = ctx.prog.interp_parts.items[interp.part_start + i];
                if (try tryFoldLiteralStringExpr(ctx, part_expr)) |part_id| {
                    try out.appendSlice(ctx.a, ctx.pool.get(part_id));
                    continue;
                }
                const static_value = tryStaticEvalValue(ctx, part_expr) orelse return null;
                if (!(try appendStaticInterpolationValueText(ctx, &out, static_value))) return null;
            }
            break :blk try ctx.pool.intern(out.items);
        },
        else => null,
    };
}

fn appendStaticInterpolationValueText(
    ctx: *Ctx,
    out: *std.ArrayListUnmanaged(u8),
    value: value_mod.Value,
) !bool {
    return switch (value.kind()) {
        .string => blk: {
            const text = if (value.stringIntern() == .none) "" else ctx.pool.get(value.stringIntern());
            try out.appendSlice(ctx.a, text);
            break :blk true;
        },
        .number => blk: {
            const unit_id = value.unitId(ctx.prog.value_number_pool);
            const unit = if (unit_id == .none) null else ctx.pool.get(unit_id);
            const text = try value_format.formatNumberWithUnit(ctx.a, value.asF64(ctx.prog.value_number_pool), unit);
            defer ctx.a.free(text);
            try out.appendSlice(ctx.a, text);
            break :blk true;
        },
        .boolean => blk: {
            try out.appendSlice(ctx.a, if (value.p64Of() != 0) "true" else "false");
            break :blk true;
        },
        .nil => true,
        else => false,
    };
}

fn literalBoolValueWithConfigDefaults(ctx: *Ctx, e: ExprIndex, allow_configurable_defaults: bool) ?bool {
    // `&` is evaluated against the selector context at the call site, not the
    // resolver's current style-rule depth.  A mixin/function can be defined at
    // top level and later included both with and without a parent selector:
    // `if(sass(&): "&"; else: "")` must therefore stay dynamic even when the
    // resolver is currently at top level.
    if (exprMayDependOnParentSelector(ctx, e)) return null;
    const value = tryStaticEvalValueWithConfigDefaults(ctx, e, allow_configurable_defaults) orelse return null;
    return value.isTruthy();
}

fn literalBoolValue(ctx: *Ctx, e: ExprIndex) ?bool {
    return literalBoolValueWithConfigDefaults(ctx, e, false);
}

fn literalBoolValueForFlowControl(ctx: *Ctx, e: ExprIndex) ?bool {
    return literalBoolValueWithConfigDefaults(ctx, e, true);
}

fn exprMayDependOnParentSelector(ctx: *Ctx, e: ExprIndex) bool {
    if (e >= ctx.prog.exprs.items.len) return false;
    const ex = ctx.prog.exprs.items[e];
    return switch (ex.kind) {
        .literal_string => blk: {
            const payload = unpackLiteralStringPayload(ex.payload);
            if (payload.quoted) break :blk false;
            break :blk std.mem.eql(u8, ctx.pool.get(payload.id), "&");
        },
        .binary => blk: {
            if (ex.payload >= ctx.prog.binary_exprs.items.len) break :blk false;
            const b = ctx.prog.binary_exprs.items[ex.payload];
            break :blk exprMayDependOnParentSelector(ctx, b.lhs) or exprMayDependOnParentSelector(ctx, b.rhs);
        },
        .unary => blk: {
            if (ex.payload >= ctx.prog.unary_exprs.items.len) break :blk false;
            const u = ctx.prog.unary_exprs.items[ex.payload];
            break :blk exprMayDependOnParentSelector(ctx, u.operand);
        },
        .interp => blk: {
            if (ex.payload >= ctx.prog.interp_exprs.items.len) break :blk false;
            const ip = ctx.prog.interp_exprs.items[ex.payload];
            var i: u32 = 0;
            while (i < ip.part_count) : (i += 1) {
                const part_idx = ip.part_start + i;
                if (part_idx >= ctx.prog.interp_parts.items.len) break;
                if (exprMayDependOnParentSelector(ctx, ctx.prog.interp_parts.items[part_idx])) break :blk true;
            }
            break :blk false;
        },
        .list => blk: {
            if (ex.payload >= ctx.prog.list_exprs.items.len) break :blk false;
            const list = ctx.prog.list_exprs.items[ex.payload];
            var i: u32 = 0;
            while (i < list.elem_count) : (i += 1) {
                const elem_idx = list.elem_start + i;
                if (elem_idx >= ctx.prog.list_elems.items.len) break;
                if (exprMayDependOnParentSelector(ctx, ctx.prog.list_elems.items[elem_idx])) break :blk true;
            }
            break :blk false;
        },
        .if_builtin => blk: {
            if (ex.payload >= ctx.prog.call_exprs.items.len) break :blk false;
            const call = ctx.prog.call_exprs.items[ex.payload];
            break :blk anyCallArgsDepend(ctx, call.arg_start, call.arg_count);
        },
        .builtin_call => blk: {
            if (ex.payload >= ctx.prog.builtin_calls.items.len) break :blk false;
            const call = ctx.prog.builtin_calls.items[ex.payload];
            break :blk anyCallArgsDepend(ctx, call.arg_start, call.arg_count);
        },
        .call => blk: {
            if (ex.payload >= ctx.prog.call_exprs.items.len) break :blk false;
            const call = ctx.prog.call_exprs.items[ex.payload];
            break :blk anyCallArgsDepend(ctx, call.arg_start, call.arg_count);
        },
        else => false,
    };
}

fn anyCallArgsDepend(ctx: *Ctx, arg_start: u32, arg_count: u32) bool {
    var i: u32 = 0;
    while (i < arg_count) : (i += 1) {
        const arg_idx = arg_start + i;
        if (arg_idx >= ctx.prog.call_args.items.len) return false;
        if (exprMayDependOnParentSelector(ctx, ctx.prog.call_args.items[arg_idx])) return true;
    }
    return false;
}

fn isLiteralNull(ctx: *Ctx, e: ExprIndex) bool {
    return ctx.prog.exprs.items[e].kind == .literal_null;
}

fn mixinAcceptsContentById(ctx: *Ctx, mid: u32) bool {
    if (mid >= ctx.prog.mixins.items.len) return false;
    return ctx.prog.mixins.items[mid].accepts_content;
}

fn mixinCapturesCallersLocalsById(ctx: *Ctx, mid: u32) bool {
    if (mid >= ctx.prog.mixins.items.len) return false;
    return ctx.prog.mixins.items[mid].captures_callers_locals;
}

fn functionCapturesCallersLocalsById(ctx: *Ctx, fid: u32) bool {
    if (fid >= ctx.prog.functions.items.len) return false;
    return ctx.prog.functions.items[fid].captures_callers_locals;
}

const PreboundMetaCallable = struct {
    kind: PreboundCallableKind,
    module_id: u32,
    id: u32,
    accepts_content: bool,
    captures_callers_locals: bool,
    name: InternId,
};

fn tryResolvePreboundMetaCallable(
    ctx: *Ctx,
    builtin_id: u32,
    arg_start: u32,
    arg_count: u32,
) PreboundMetaCallable {
    var out: PreboundMetaCallable = .{
        .kind = PreboundCallableKind.none,
        .module_id = local_module_id_sentinel,
        .id = 0,
        .accepts_content = false,
        .captures_callers_locals = false,
        .name = .none,
    };

    if (builtin_id != builtin_mod.meta_get_function_id and builtin_id != builtin_mod.meta_get_mixin_id) {
        return out;
    }
    if (arg_count == 0) return out;

    var name_expr: ?ExprIndex = null;
    var css_expr: ?ExprIndex = null;
    var module_expr: ?ExprIndex = null;
    var positional_index: u32 = 0;

    var i: u32 = 0;
    while (i < arg_count) : (i += 1) {
        const idx = arg_start + i;
        const expr = ctx.prog.call_args.items[idx];
        const arg_name = ctx.prog.call_arg_names.items[idx];
        if (arg_name == call_arg_splat_sentinel) return out;

        if (arg_name == .none) {
            if (builtin_id == builtin_mod.meta_get_function_id) {
                switch (positional_index) {
                    0 => {
                        if (name_expr != null) return out;
                        name_expr = expr;
                    },
                    1 => {
                        if (css_expr != null) return out;
                        css_expr = expr;
                    },
                    2 => {
                        if (module_expr != null) return out;
                        module_expr = expr;
                    },
                    else => return out,
                }
            } else {
                switch (positional_index) {
                    0 => {
                        if (name_expr != null) return out;
                        name_expr = expr;
                    },
                    1 => {
                        if (module_expr != null) return out;
                        module_expr = expr;
                    },
                    else => return out,
                }
            }
            positional_index += 1;
            continue;
        }

        if (argNameEq(ctx, arg_name, "name")) {
            if (name_expr != null) return out;
            name_expr = expr;
            continue;
        }
        if (builtin_id == builtin_mod.meta_get_function_id and argNameEq(ctx, arg_name, "css")) {
            if (css_expr != null) return out;
            css_expr = expr;
            continue;
        }
        if (argNameEq(ctx, arg_name, "module")) {
            if (module_expr != null) return out;
            module_expr = expr;
            continue;
        }
        return out;
    }

    const name_e = name_expr orelse return out;
    const name_info = literalStringInfo(ctx, name_e) orelse return out;
    const name = name_info.text;

    if (module_expr) |me| {
        if (!isLiteralNull(ctx, me)) return out;
    }

    if (builtin_id == builtin_mod.meta_get_function_id) {
        if (css_expr) |ce| {
            const css = literalBoolValue(ctx, ce) orelse return out;
            if (css) return out;
        }
        const fid = lookupIdentifierIdInsensitive(&ctx.prog.function_names, name) orelse return out;
        out.kind = .function;
        out.id = fid;
        out.captures_callers_locals = functionCapturesCallersLocalsById(ctx, fid);
        out.name = name_info.id;
        return out;
    }

    const mid = lookupIdentifierIdInsensitive(&ctx.prog.mixin_names, name) orelse return out;
    out.kind = .mixin;
    out.id = mid;
    out.accepts_content = mixinAcceptsContentById(ctx, mid);
    out.captures_callers_locals = mixinCapturesCallersLocalsById(ctx, mid);
    out.name = name_info.id;
    return out;
}

fn findVariableExistsNameArgExpr(ctx: *Ctx, arg_start: u32, arg_count: u32) ?ExprIndex {
    var name_expr: ?ExprIndex = null;
    var positional_index: u32 = 0;

    var i: u32 = 0;
    while (i < arg_count) : (i += 1) {
        const idx = arg_start + i;
        const expr = ctx.prog.call_args.items[idx];
        const arg_name = ctx.prog.call_arg_names.items[idx];
        if (arg_name == call_arg_splat_sentinel) return null;

        if (arg_name == .none) {
            if (positional_index == 0 and name_expr == null) {
                name_expr = expr;
            } else {
                return null;
            }
            positional_index += 1;
            continue;
        }

        if (argNameEq(ctx, arg_name, "name")) {
            if (name_expr != null) return null;
            name_expr = expr;
            continue;
        }
        return null;
    }

    return name_expr;
}

fn lookupScopedSlotByName(ctx: *Ctx, name: []const u8) ?SlotId {
    var i: usize = ctx.scopes.items.len;
    while (i > 0) {
        i -= 1;
        if (ctx.scopes.items[i].get(name)) |s| return s;
        if (lookupSlotInsensitive(&ctx.scopes.items[i], name)) |s| return s;
    }
    return null;
}

fn resolveBuiltinLocalSlotHint(ctx: *Ctx, builtin_id: u32, arg_start: u32, arg_count: u32) u32 {
    if (builtin_id != meta_variable_exists_builtin_id) return std.math.maxInt(u32);
    const name_expr = findVariableExistsNameArgExpr(ctx, arg_start, arg_count) orelse return std.math.maxInt(u32);
    const info = literalStringInfo(ctx, name_expr) orelse return std.math.maxInt(u32);
    return lookupScopedSlotByName(ctx, info.text) orelse std.math.maxInt(u32);
}

fn mapBinOp(op: AstBinOp) BinOp {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .eq => .eq,
        .ne => .neq,
        .lt => .lt,
        .gt => .gt,
        .le => .le,
        .ge => .ge,
        .log_and => .and_op,
        .log_or => .or_op,
    };
}

fn mapUnaryOp(op: AstUnaryOp) UnaryOp {
    return switch (op) {
        .negate => .neg,
        .positive => .pos,
        .slash_prefix => .slash_prefix,
        .not => .not_op,
    };
}

fn appendExpr(prog: *ResolvedProgram, alloc: std.mem.Allocator, re: ResolvedExpr) !ExprIndex {
    const idx: ExprIndex = @intCast(prog.exprs.items.len);
    try prog.exprs.append(alloc, re);
    return idx;
}

fn appendSassErrorExpr(ctx: *Ctx, span: Span) !ExprIndex {
    return try appendExpr(ctx.prog, ctx.a, .{
        .kind = .sass_error,
        .payload = 0,
        .span = span,
    });
}

fn appendCallArgsWithNames(
    prog: *ResolvedProgram,
    alloc: std.mem.Allocator,
    args: []const ExprIndex,
    arg_names: []const InternId,
) !u32 {
    std.debug.assert(args.len == arg_names.len);
    std.debug.assert(prog.call_args.items.len == prog.call_arg_names.items.len);
    const start: u32 = @intCast(prog.call_args.items.len);
    for (args, arg_names) |e, name_id| {
        try prog.call_args.append(alloc, e);
        try prog.call_arg_names.append(alloc, name_id);
    }
    return start;
}

const literal_string_quoted_bit: u32 = 0x8000_0000;
const literal_string_named_color_bit: u32 = 0x4000_0000;
const literal_string_raw_text_bit: u32 = 0x2000_0000;
const literal_string_flag_mask: u32 =
    literal_string_quoted_bit | literal_string_named_color_bit | literal_string_raw_text_bit;

fn packLiteralStringPayload(id: InternId, quoted: bool, named_color_literal: bool) u32 {
    return packLiteralStringPayloadEx(id, quoted, named_color_literal, false);
}

fn packLiteralStringPayloadEx(id: InternId, quoted: bool, named_color_literal: bool, raw_text: bool) u32 {
    const raw: u32 = @intFromEnum(id);
    return (raw & ~literal_string_flag_mask) |
        (if (quoted) literal_string_quoted_bit else 0) |
        (if (named_color_literal) literal_string_named_color_bit else 0) |
        (if (raw_text) literal_string_raw_text_bit else 0);
}

pub fn unpackLiteralStringPayload(payload: u32) struct {
    id: InternId,
    quoted: bool,
    named_color_literal: bool,
    raw_text: bool,
} {
    return .{
        .id = @enumFromInt(payload & ~literal_string_flag_mask),
        .quoted = (payload & literal_string_quoted_bit) != 0,
        .named_color_literal = (payload & literal_string_named_color_bit) != 0,
        .raw_text = (payload & literal_string_raw_text_bit) != 0,
    };
}

fn requireModuleLoader(ctx: *const Ctx) ResolveError!*ModuleResolver {
    return ctx.loader orelse error.InternalError;
}

const requireModuleExports = module_exports.requireModuleExports;

fn collectImplicitUseConfigEntries(
    ctx: *Ctx,
    loader: *ModuleResolver,
    module_id: u32,
    out: *std.ArrayListUnmanaged(WithConfigEntry),
) ResolveError!void {
    const ex = try requireModuleExports(loader, module_id);
    var it = ex.default_vars.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (lookupVoidFlagInsensitive(&ex.ambiguous_default_vars, name)) continue;
        const value = lookupVisibleConfigVarValue(ctx, name) orelse continue;
        try out.append(ctx.a, .{
            .name = name,
            .value = value,
            .is_default = false,
        });
    }
}

fn collectImplicitForwardConfigEntries(
    ctx: *Ctx,
    loader: *ModuleResolver,
    module_id: u32,
    prefix: ?[]const u8,
    show: ?[]const []const u8,
    hide: ?[]const []const u8,
    out: *std.ArrayListUnmanaged(WithConfigEntry),
) ResolveError!void {
    const ex = try requireModuleExports(loader, module_id);
    var it = ex.default_vars.iterator();
    while (it.next()) |entry| {
        const target_name = entry.key_ptr.*;
        if (lookupVoidFlagInsensitive(&ex.ambiguous_default_vars, target_name)) continue;
        const forwarded_name = try withForwardPrefix(ctx.prog, prefix, target_name);
        if (!forwardAllowsVar(forwarded_name, show, hide)) continue;
        const value = lookupVisibleConfigVarValue(ctx, forwarded_name) orelse continue;
        try out.append(ctx.a, .{
            .name = target_name,
            .value = value,
            .is_default = false,
        });
    }
}

fn applyImplicitImportConfigEntries(
    loader: *ModuleResolver,
    module_id: u32,
    known_before_count: u32,
    entries: []const WithConfigEntry,
) ResolveError!void {
    if (entries.len == 0) return;
    // Sass @import-derived implicit configuration is sticky:
    // once the target module is loaded, later imports don't reconfigure it.
    // With cross-entry persistent, the module of the prior entry is treated as "unloaded" for this entry.
    if (module_id < known_before_count and module_id >= loader.entry_records_baseline) return;
    const ex = try requireModuleExports(loader, module_id);
    for (entries) |entry| {
        if (lookupVoidFlagInsensitive(&ex.ambiguous_default_vars, entry.name)) continue;
        const target = lookupConfigVarTargetInsensitive(&ex.default_vars, entry.name) orelse continue;
        try applyConfigTarget(loader, target, entry.value, false);
    }
}

fn requireModuleBasePath(ctx: *const Ctx) ResolveError![]const u8 {
    if (ctx.module_path.len == 0) return error.UsermoduleBasePathMissing;
    return ctx.module_path;
}

fn mergeStarUserModule(ctx: *Ctx, module_id: u32) !void {
    ctx.markScopeRestoreDirty();
    const loader = try requireModuleLoader(ctx);
    const ex = try requireModuleExports(loader, module_id);

    // When merging the first module into an empty map, all entries are definitely unregistered, so
    // You can completely skip dedupe's `lookupCallableTargetInsensitive` (variant scan).
    // Large legacy `@import` chains can have enough mixins/functions per module
    // that duplicate checks dominate this merge path.
    const vars_fast = ctx.star_vars.count() == 0;
    const mixins_fast = ctx.star_mixins.count() == 0;
    const functions_fast = ctx.star_functions.count() == 0;

    if (vars_fast) {
        try ctx.star_vars.ensureUnusedCapacity(ctx.a, ex.vars.count());
    }
    var vit = ex.vars.iterator();
    while (vit.next()) |e| {
        const name = e.key_ptr.*;
        const target = e.value_ptr.*;
        // Collision between local $var and @use ... as * is an error.
        if (lookupGlobalSlot(ctx.prog, name)) |local_slot| {
            // Treated as a conflict only if there is already an assignment that has been previously resolved.
            // "Subsequent top-level $var declarations" prefetched with predeclare are @use as * after
            //Do not cause a conflict here as it is write-through to the module variable.
            if (hasResolvedAssignToSlot(ctx.prog, local_slot)) {
                try markAmbiguousNameCtx(ctx, .ambiguous_star_vars, &ctx.ambiguous_star_vars, name);
                continue;
            }
        }
        if (!vars_fast) {
            if (lookupConfigVarTargetInsensitive(&ctx.star_vars, name)) |existing| {
                if (existing.module_id != target.module_id or existing.slot != target.slot) {
                    try markAmbiguousNameCtx(ctx, .ambiguous_star_vars, &ctx.ambiguous_star_vars, name);
                    continue;
                }
                continue;
            }
            try ctx.recordMapMut(ctx.a, .star_vars, name);
            try ctx.star_vars.put(ctx.a, name, target);
        } else {
            try ctx.recordMapMut(ctx.a, .star_vars, name);
            ctx.star_vars.putAssumeCapacity(name, target);
        }
    }

    if (mixins_fast) {
        try ctx.star_mixins.ensureUnusedCapacity(ctx.a, ex.mixins.count());
    }
    var mit = ex.mixins.iterator();
    while (mit.next()) |e| {
        const name = e.key_ptr.*;
        const target = e.value_ptr.*;
        if (lookupIdentifierIdInsensitive(&ctx.prog.mixin_names, name) != null) {
            // local mixin declarations shadow star-imported mixins.
            continue;
        }
        if (!mixins_fast) {
            if (lookupStarMixinMapInsensitive(ctx, name)) |existing| {
                if (!sameCallableTarget(existing, target)) {
                    try markAmbiguousNameCtx(ctx, .ambiguous_star_mixins, &ctx.ambiguous_star_mixins, name);
                    continue;
                }
                continue;
            }
            try ctx.recordMapMut(ctx.a, .star_mixins, name);
            try ctx.star_mixins.put(ctx.a, name, target);
            noteStarMixinMapKey(ctx, name);
        } else {
            try ctx.recordMapMut(ctx.a, .star_mixins, name);
            ctx.star_mixins.putAssumeCapacity(name, target);
            noteStarMixinMapKey(ctx, name);
        }
    }

    if (functions_fast) {
        try ctx.star_functions.ensureUnusedCapacity(ctx.a, ex.functions.count());
    }
    var fit = ex.functions.iterator();
    while (fit.next()) |e| {
        const name = e.key_ptr.*;
        const target = e.value_ptr.*;
        if (lookupIdentifierIdInsensitive(&ctx.prog.function_names, name) != null) {
            // local function declarations shadow star-imported functions.
            continue;
        }
        if (!functions_fast) {
            if (lookupStarFunctionMapInsensitive(ctx, name)) |existing| {
                if (!sameCallableTarget(existing, target)) {
                    try markAmbiguousNameCtx(ctx, .ambiguous_star_functions, &ctx.ambiguous_star_functions, name);
                    continue;
                }
                continue;
            }
            try ctx.recordMapMut(ctx.a, .star_functions, name);
            try ctx.star_functions.put(ctx.a, name, target);
            noteStarFunctionMapKey(ctx, name);
        } else {
            try ctx.recordMapMut(ctx.a, .star_functions, name);
            ctx.star_functions.putAssumeCapacity(name, target);
            noteStarFunctionMapKey(ctx, name);
        }
    }
    const placeholders_fast = ctx.star_placeholders.count() == 0;
    if (placeholders_fast) {
        try ctx.star_placeholders.ensureUnusedCapacity(ctx.a, ex.placeholders.count());
    }
    var pit = ex.placeholders.iterator();
    while (pit.next()) |e| {
        const name = e.key_ptr.*;
        if (!placeholders_fast) {
            if (ctx.star_placeholders.get(name)) |existing_mid| {
                if (existing_mid != module_id) return error.SassError;
                continue;
            }
            try ctx.recordMapMut(ctx.a, .star_placeholders, name);
            try ctx.star_placeholders.put(ctx.a, name, module_id);
        } else {
            try ctx.recordMapMut(ctx.a, .star_placeholders, name);
            ctx.star_placeholders.putAssumeCapacity(name, module_id);
        }
    }

    const builtin_fast = ctx.star_builtin_fns.count() == 0;
    if (builtin_fast) {
        try ctx.star_builtin_fns.ensureUnusedCapacity(ctx.a, ex.builtin_functions.count());
    }
    var bit = ex.builtin_functions.iterator();
    while (bit.next()) |e| {
        const name = e.key_ptr.*;
        const target = e.value_ptr.*;
        if (!builtin_fast) {
            if (lookupIdentifierIdInsensitive(&ctx.star_builtin_fns, name)) |existing| {
                if (existing != target) return error.SassError;
                continue;
            }
            try ctx.recordMapMut(ctx.a, .star_builtin_fns, name);
            try ctx.star_builtin_fns.put(ctx.a, name, target);
        } else {
            try ctx.recordMapMut(ctx.a, .star_builtin_fns, name);
            ctx.star_builtin_fns.putAssumeCapacity(name, target);
        }
    }
}

fn rebindUnassignedGlobalVarRefsToCrossTarget(
    ctx: *Ctx,
    name: []const u8,
    target: VarTarget,
) ResolveError!void {
    const slot = lookupGlobalSlot(ctx.prog, name) orelse return;
    if (hasResolvedAssignToSlot(ctx.prog, slot)) return;

    var ei: usize = 0;
    while (ei < ctx.prog.exprs.items.len) : (ei += 1) {
        var ex = &ctx.prog.exprs.items[ei];
        if (ex.kind != .var_ref) continue;
        if (ex.payload != slot) continue;

        const cidx: u32 = @intCast(ctx.prog.cross_var_refs.items.len);
        try ctx.prog.cross_var_refs.append(ctx.a, .{
            .module_id = target.module_id,
            .slot = target.slot,
        });
        ex.kind = .cross_var_ref;
        ex.payload = cidx;
    }
}

/// Expose `@forward` reached via `@import` to importer scope.
/// Inject the name after prefix/show/hide is applied to the same star map as `@use ... as *`.
fn mergeForwardRuleIntoImportScope(ctx: *Ctx, fr: ForwardRuleResolved, remove_local_callables: bool) ResolveError!void {
    ctx.markScopeRestoreDirty();
    switch (fr.target) {
        .builtin_module => |module_name| {
            var builtin_functions: std.StringHashMapUnmanaged(u32) = .empty;
            defer builtin_functions.deinit(ctx.a);
            try builtin_mod.fillBuiltinFunctionNameToIdMap(ctx.a, module_name, &builtin_functions);

            var bit = builtin_functions.iterator();
            while (bit.next()) |entry| {
                const name = entry.key_ptr.*;
                const out_name = try withForwardPrefix(ctx.prog, fr.prefix, name);
                if (!forwardAllowsPlain(out_name, fr.show, fr.hide)) continue;
                if (lookupIdentifierIdInsensitive(&ctx.star_builtin_fns, out_name)) |existing| {
                    if (existing == entry.value_ptr.*) continue;
                }
                try ctx.recordMapMut(ctx.a, .star_builtin_fns, out_name);
                try ctx.star_builtin_fns.put(ctx.a, out_name, entry.value_ptr.*);
            }
        },
        .user_module => |module_id| {
            const loader = try requireModuleLoader(ctx);
            const ex = try requireModuleExports(loader, module_id);

            var vit = ex.vars.iterator();
            while (vit.next()) |entry| {
                const name = entry.key_ptr.*;
                const out_name = try withForwardPrefix(ctx.prog, fr.prefix, name);
                if (!forwardAllowsVar(out_name, fr.show, fr.hide)) continue;
                const is_default_export = if (lookupConfigVarTargetInsensitive(&ex.default_vars, name)) |default_target|
                    (default_target.module_id == entry.value_ptr.*.module_id and default_target.slot == entry.value_ptr.*.slot)
                else
                    false;
                var same_existing = false;
                if (lookupConfigVarTargetInsensitive(&ctx.star_vars, out_name)) |existing| {
                    if (existing.module_id == entry.value_ptr.*.module_id and existing.slot == entry.value_ptr.*.slot) {
                        same_existing = true;
                    }
                }
                if (!same_existing) {
                    // @forward via import is overwritten with last win.
                    try ctx.recordMapMut(ctx.a, .star_vars, out_name);
                    try ctx.star_vars.put(ctx.a, out_name, entry.value_ptr.*);
                }
                try ctx.recordMapMut(ctx.a, .import_star_vars, out_name);
                try ctx.import_star_vars.put(ctx.a, out_name, is_default_export);
                try rebindUnassignedGlobalVarRefsToCrossTarget(ctx, out_name, entry.value_ptr.*);
            }
            var avit = ex.ambiguous_vars.iterator();
            while (avit.next()) |entry| {
                const name = entry.key_ptr.*;
                const out_name = try withForwardPrefix(ctx.prog, fr.prefix, name);
                if (!forwardAllowsVar(out_name, fr.show, fr.hide)) continue;
                try markAmbiguousNameCtx(ctx, .ambiguous_star_vars, &ctx.ambiguous_star_vars, out_name);
            }

            var mit = ex.mixins.iterator();
            while (mit.next()) |entry| {
                const name = entry.key_ptr.*;
                const out_name = try withForwardPrefix(ctx.prog, fr.prefix, name);
                if (!forwardAllowsPlain(out_name, fr.show, fr.hide)) continue;
                if (remove_local_callables) {
                    if (lookupIdentifierIdKeyInsensitive(&ctx.prog.mixin_names, out_name)) |local_name| {
                        try ctx.recordMapMut(ctx.a, .prog_mixin_names, local_name);
                        _ = ctx.prog.mixin_names.remove(local_name);
                    }
                }
                if (lookupStarMixinMapInsensitive(ctx, out_name)) |existing| {
                    if (existing.module_id == entry.value_ptr.*.module_id and existing.id == entry.value_ptr.*.id) {
                        continue;
                    }
                }
                try ctx.recordMapMut(ctx.a, .star_mixins, out_name);
                try ctx.star_mixins.put(ctx.a, out_name, entry.value_ptr.*);
                noteStarMixinMapKey(ctx, out_name);
            }
            var amit = ex.ambiguous_mixins.iterator();
            while (amit.next()) |entry| {
                const name = entry.key_ptr.*;
                const out_name = try withForwardPrefix(ctx.prog, fr.prefix, name);
                if (!forwardAllowsPlain(out_name, fr.show, fr.hide)) continue;
                try markAmbiguousNameCtx(ctx, .ambiguous_star_mixins, &ctx.ambiguous_star_mixins, out_name);
            }

            var fit = ex.functions.iterator();
            while (fit.next()) |entry| {
                const name = entry.key_ptr.*;
                const out_name = try withForwardPrefix(ctx.prog, fr.prefix, name);
                if (!forwardAllowsPlain(out_name, fr.show, fr.hide)) continue;
                if (remove_local_callables) {
                    if (lookupIdentifierIdKeyInsensitive(&ctx.prog.function_names, out_name)) |local_name| {
                        try ctx.recordMapMut(ctx.a, .prog_function_names, local_name);
                        _ = ctx.prog.function_names.remove(local_name);
                    }
                }
                if (lookupStarFunctionMapInsensitive(ctx, out_name)) |existing| {
                    if (existing.module_id == entry.value_ptr.*.module_id and existing.id == entry.value_ptr.*.id) {
                        continue;
                    }
                }
                try ctx.recordMapMut(ctx.a, .star_functions, out_name);
                try ctx.star_functions.put(ctx.a, out_name, entry.value_ptr.*);
                noteStarFunctionMapKey(ctx, out_name);
            }
            var afit = ex.ambiguous_functions.iterator();
            while (afit.next()) |entry| {
                const name = entry.key_ptr.*;
                const out_name = try withForwardPrefix(ctx.prog, fr.prefix, name);
                if (!forwardAllowsPlain(out_name, fr.show, fr.hide)) continue;
                try markAmbiguousNameCtx(ctx, .ambiguous_star_functions, &ctx.ambiguous_star_functions, out_name);
            }

            var bit = ex.builtin_functions.iterator();
            while (bit.next()) |entry| {
                const name = entry.key_ptr.*;
                const out_name = try withForwardPrefix(ctx.prog, fr.prefix, name);
                if (!forwardAllowsPlain(out_name, fr.show, fr.hide)) continue;
                if (lookupIdentifierIdInsensitive(&ctx.star_builtin_fns, out_name)) |existing| {
                    if (existing == entry.value_ptr.*) continue;
                }
                try ctx.recordMapMut(ctx.a, .star_builtin_fns, out_name);
                try ctx.star_builtin_fns.put(ctx.a, out_name, entry.value_ptr.*);
            }

            var pit = ex.placeholders.iterator();
            while (pit.next()) |entry| {
                const name = entry.key_ptr.*;
                const out_name = try withForwardPrefix(ctx.prog, fr.prefix, name);
                if (!forwardAllowsPlain(out_name, fr.show, fr.hide)) continue;
                if (ctx.star_placeholders.get(out_name)) |existing_mid| {
                    if (existing_mid == module_id) continue;
                }
                try ctx.recordMapMut(ctx.a, .star_placeholders, out_name);
                try ctx.star_placeholders.put(ctx.a, out_name, module_id);
            }
        },
    }
}

fn resolveBuiltinModuleVariableNumber(module_name: []const u8, var_name: []const u8) ?f64 {
    if (!identifierEqSass(module_name, "math")) return null;

    if (identifierEqSass(var_name, "pi")) return std.math.pi;
    if (identifierEqSass(var_name, "e")) return std.math.e;
    if (identifierEqSass(var_name, "epsilon")) return std.math.floatEps(f64);
    if (identifierEqSass(var_name, "max-safe-integer")) return 9007199254740991;
    if (identifierEqSass(var_name, "min-safe-integer")) return -9007199254740991;
    if (identifierEqSass(var_name, "max-number")) return std.math.floatMax(f64);
    if (identifierEqSass(var_name, "min-number")) return std.math.floatTrueMin(f64);
    if (identifierEqSass(var_name, "infinity")) return std.math.inf(f64);
    if (identifierEqSass(var_name, "-infinity")) return -std.math.inf(f64);
    if (identifierEqSass(var_name, "nan")) return std.math.nan(f64);
    return null;
}

fn exprLiteralStringText(ctx: *Ctx, expr_idx: ExprIndex) ?[]const u8 {
    if (expr_idx >= ctx.prog.exprs.items.len) return null;
    const ex = ctx.prog.exprs.items[expr_idx];
    if (ex.kind != .literal_string) return null;
    const payload = unpackLiteralStringPayload(ex.payload);
    return ctx.pool.get(payload.id);
}

fn collapseStaticTextExprToIntern(ctx: *Ctx, expr_idx: ExprIndex) ?InternId {
    if (expr_idx >= ctx.prog.exprs.items.len) return null;
    const ex = ctx.prog.exprs.items[expr_idx];
    switch (ex.kind) {
        .literal_string => {
            const payload = unpackLiteralStringPayload(ex.payload);
            return payload.id;
        },
        .interp => {
            if (ex.payload >= ctx.prog.interp_exprs.items.len) return null;
            const ie = ctx.prog.interp_exprs.items[ex.payload];
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            defer buf.deinit(ctx.a);

            var i: u32 = 0;
            while (i < ie.part_count) : (i += 1) {
                const part_idx = ie.part_start + i;
                if (part_idx >= ctx.prog.interp_parts.items.len) return null;
                const part_expr = ctx.prog.interp_parts.items[part_idx];
                const text = exprLiteralStringText(ctx, part_expr) orelse return null;
                buf.appendSlice(ctx.a, text) catch return null;
            }
            return ctx.pool.intern(buf.items) catch null;
        },
        else => return null,
    }
}

fn reserveGlobalSlotPrefix(ctx: *Ctx, upto: SlotId) void {
    if (ctx.prog.next_global_slot < upto) ctx.prog.next_global_slot = upto;
    if (ctx.prog.max_slot < upto) ctx.prog.max_slot = upto;
}

fn ensureMetaModuleLoadedForIntrospection(
    ctx: *Ctx,
    builtin_id: u32,
    arg_exprs: []const ExprIndex,
    arg_names: []const InternId,
) ResolveError!void {
    const meta_module_variables_id: u32 = 133;
    const meta_module_functions_id: u32 = 134;
    const meta_module_mixins_id: u32 = 135;

    if (builtin_id != meta_module_variables_id and builtin_id != meta_module_functions_id and builtin_id != meta_module_mixins_id) {
        return;
    }
    if (arg_exprs.len != 1 or arg_names.len != 1) return;
    if (arg_names[0] != .none) {
        const arg_name = ctx.pool.get(arg_names[0]);
        if (!identifierEq(arg_name, "module")) return;
    }
    const module_name = exprLiteralStringText(ctx, arg_exprs[0]) orelse return;
    if (lookupUseBindingInsensitive(&ctx.prog.use_map, module_name) != null) return;
    return error.Unsupported;
}

fn appendBoolLiteralExpr(ctx: *Ctx, value: bool, span: Span) ResolveError!ExprIndex {
    return appendExpr(ctx.prog, ctx.a, .{
        .kind = .literal_bool,
        .payload = if (value) 1 else 0,
        .span = span,
    });
}

fn tryFoldMetaBuiltinExists(
    ctx: *Ctx,
    builtin_id: u32,
    arg_exprs: []const ExprIndex,
    arg_names: []const InternId,
    span: Span,
) ResolveError!?ExprIndex {
    const meta_variable_exists_id: u32 = 127;
    const meta_function_exists_id: u32 = 129;
    const meta_mixin_exists_id: u32 = 130;

    if (builtin_id != meta_variable_exists_id and builtin_id != meta_function_exists_id and builtin_id != meta_mixin_exists_id) {
        return null;
    }
    if (arg_exprs.len != 1 or arg_names.len != 1) return null;
    if (arg_names[0] != .none) {
        const arg_name = ctx.pool.get(arg_names[0]);
        const expected_name = switch (builtin_id) {
            meta_variable_exists_id => "name",
            meta_function_exists_id => "name",
            meta_mixin_exists_id => "name",
            else => "",
        };
        if (!identifierEq(arg_name, expected_name)) return null;
    }
    const query_name = exprLiteralStringText(ctx, arg_exprs[0]) orelse return null;

    return switch (builtin_id) {
        meta_variable_exists_id => blk: {
            if (lookupScopedSlotByName(ctx, query_name) != null) {
                break :blk try appendBoolLiteralExpr(ctx, true, span);
            }
            if (lookupGlobalSlot(ctx.prog, query_name)) |slot| {
                break :blk try appendBoolLiteralExpr(ctx, hasResolvedAssignToSlot(ctx.prog, slot), span);
            }
            if (lookupVoidFlagInsensitive(&ctx.ambiguous_star_vars, query_name)) return error.Unsupported;
            if (lookupConfigVarTargetInsensitive(&ctx.star_vars, query_name) != null) {
                break :blk try appendBoolLiteralExpr(ctx, true, span);
            }
            break :blk try appendBoolLiteralExpr(ctx, false, span);
        },
        meta_function_exists_id => blk: {
            if (lookupIdentifierIdInsensitive(&ctx.prog.function_names, query_name) != null) {
                break :blk try appendBoolLiteralExpr(ctx, true, span);
            }
            if (lookupVoidFlagInsensitive(&ctx.ambiguous_star_functions, query_name)) return error.Unsupported;
            if (ctx.lookupStarFunction(query_name) != null or
                lookupIdentifierIdInsensitive(&ctx.star_builtin_fns, query_name) != null or
                builtin_mod.resolveLegacyGlobal(query_name) != null)
            {
                break :blk try appendBoolLiteralExpr(ctx, true, span);
            }
            break :blk try appendBoolLiteralExpr(ctx, false, span);
        },
        meta_mixin_exists_id => blk: {
            if (lookupIdentifierIdInsensitive(&ctx.prog.mixin_names, query_name) != null) {
                break :blk try appendBoolLiteralExpr(ctx, true, span);
            }
            if (lookupVoidFlagInsensitive(&ctx.ambiguous_star_mixins, query_name)) return error.Unsupported;
            if (ctx.lookupStarMixin(query_name) != null) {
                break :blk try appendBoolLiteralExpr(ctx, true, span);
            }
            break :blk try appendBoolLiteralExpr(ctx, false, span);
        },
        else => null,
    };
}

fn resolveExprVariable(ast: *const ast_flat.Ast, ctx: *Ctx, n: AstNode, span: Span) ResolveError!ExprIndex {
    if (isPlainCssStylesheetPath(ctx.module_path)) {
        if (span.start <= span.end and span.end <= ast.source.len) {
            return resolveInterpolatedTextExpr(ctx, ast.source[span.start..span.end], span, false);
        }
        return error.SassError;
    }
    const name_id: InternId = @enumFromInt(n.payload);
    const raw_name = ctx.pool.get(name_id);
    const local_slot = ctx.lookupScopedSlot(name_id);
    if (lookupBoolFlagInsensitive(&ctx.import_star_vars, raw_name)) |from_import_default| {
        if (ctx.lookupStarVar(name_id)) |cross| {
            if (from_import_default) {
                if (lookupGlobalSlot(ctx.prog, raw_name)) |global_slot| {
                    if (hasResolvedAssignToSlot(ctx.prog, global_slot)) {
                        return try appendExpr(ctx.prog, ctx.a, .{
                            .kind = .var_ref,
                            .payload = global_slot,
                            .span = span,
                        });
                    }
                }
            }
            if (try tryResolveCrossVarStaticExpr(ctx, cross, span)) |static_expr| {
                return static_expr;
            }
            const cidx: u32 = @intCast(ctx.prog.cross_var_refs.items.len);
            try ctx.prog.cross_var_refs.append(ctx.a, .{
                .module_id = cross.module_id,
                .slot = cross.slot,
            });
            return try appendExpr(ctx.prog, ctx.a, .{
                .kind = .cross_var_ref,
                .payload = cidx,
                .span = span,
            });
        }
    }
    if (local_slot) |slot| {
        return try appendExpr(ctx.prog, ctx.a, .{ .kind = .var_ref, .payload = slot, .span = span });
    }
    if (lookupVoidFlagInsensitive(&ctx.ambiguous_star_vars, raw_name)) {
        return error.SassError;
    }
    if (ctx.lookupStarVar(name_id)) |cross| {
        const from_import_default = lookupBoolFlagInsensitive(&ctx.import_star_vars, raw_name) orelse false;
        if (from_import_default) {
            if (lookupGlobalSlot(ctx.prog, raw_name)) |global_slot| {
                if (hasResolvedAssignToSlot(ctx.prog, global_slot)) {
                    return try appendExpr(ctx.prog, ctx.a, .{
                        .kind = .var_ref,
                        .payload = global_slot,
                        .span = span,
                    });
                }
            }
        }
        if (try tryResolveCrossVarStaticExpr(ctx, cross, span)) |static_expr| {
            return static_expr;
        }
        const cidx: u32 = @intCast(ctx.prog.cross_var_refs.items.len);
        try ctx.prog.cross_var_refs.append(ctx.a, .{
            .module_id = cross.module_id,
            .slot = cross.slot,
        });
        return try appendExpr(ctx.prog, ctx.a, .{
            .kind = .cross_var_ref,
            .payload = cidx,
            .span = span,
        });
    }
    if (lookupGlobalSlot(ctx.prog, raw_name)) |slot| {
        return try appendExpr(ctx.prog, ctx.a, .{ .kind = .var_ref, .payload = slot, .span = span });
    }
    if (ctx.in_callable) {
        const slot = lookupGlobalSlot(ctx.prog, raw_name) orelse try ctx.declareGlobal(name_id);
        return try appendExpr(ctx.prog, ctx.a, .{
            .kind = .var_ref,
            .payload = slot,
            .span = span,
        });
    }
    if (ctx.allow_unknown_var_literal) {
        if (span.start <= span.end and span.end <= ast.source.len) {
            const raw = std.mem.trim(u8, ast.source[span.start..span.end], " \t\r\n");
            if (raw.len != 0) {
                const id = try ctx.pool.intern(raw);
                return try appendExpr(ctx.prog, ctx.a, .{
                    .kind = .literal_string,
                    .payload = packLiteralStringPayload(id, false, false),
                    .span = span,
                });
            }
        }
        const name = ctx.pool.get(name_id);
        const text = try std.fmt.allocPrint(ctx.a, "${s}", .{name});
        defer ctx.a.free(text);
        const id = try ctx.pool.intern(text);
        return try appendExpr(ctx.prog, ctx.a, .{
            .kind = .literal_string,
            .payload = packLiteralStringPayload(id, false, false),
            .span = span,
        });
    }
    return error.UnknownVar;
}

fn resolveExprNamespacedVar(ast: *const ast_flat.Ast, ctx: *Ctx, n: AstNode, span: Span) ResolveError!ExprIndex {
    if (isPlainCssStylesheetPath(ctx.module_path)) {
        if (span.start <= span.end and span.end <= ast.source.len) {
            return resolveInterpolatedTextExpr(ctx, ast.source[span.start..span.end], span, false);
        }
        return error.SassError;
    }
    const off: ExtraIndex = n.payload;
    const ns_id: InternId = @enumFromInt(ast.getExtraU32(off));
    const name_id: InternId = @enumFromInt(ast.getExtraU32(off + 1));
    const ns = ctx.pool.get(ns_id);
    const lazy_callable_error = ctx.in_callable and !ctx.resolving_callable_default;
    const binding = lookupUseBindingInContext(ctx, ns) orelse {
        if (lazy_callable_error) return try appendSassErrorExpr(ctx, span);
        return error.UnknownVar;
    };
    switch (binding) {
        .builtin_module => |module_name| {
            if (resolveBuiltinModuleVariableNumber(module_name, ctx.pool.get(name_id))) |num| {
                return try appendNumberLiteral(ctx.prog, ctx.a, num, .none, span);
            }
            if (lazy_callable_error) return try appendSassErrorExpr(ctx, span);
            return error.UnknownVar;
        },
        .user_module => |mid| {
            const ldr = try requireModuleLoader(ctx);
            const ex = try requireModuleExports(ldr, mid);
            if (lookupVoidFlagInsensitive(&ex.ambiguous_vars, ctx.pool.get(name_id))) {
                if (lazy_callable_error) return try appendSassErrorExpr(ctx, span);
                return error.SassError;
            }
            const target = lookupConfigVarTargetInsensitive(&ex.vars, ctx.pool.get(name_id)) orelse {
                if (lazy_callable_error) return try appendSassErrorExpr(ctx, span);
                return error.UnknownVar;
            };
            const cidx: u32 = @intCast(ctx.prog.cross_var_refs.items.len);
            try ctx.prog.cross_var_refs.append(ctx.a, .{
                .module_id = target.module_id,
                .slot = target.slot,
            });
            return try appendExpr(ctx.prog, ctx.a, .{
                .kind = .cross_var_ref,
                .payload = cidx,
                .span = span,
            });
        },
    }
}

fn resolveExprUnquotedIdent(ctx: *Ctx, n: AstNode, span: Span) ResolveError!ExprIndex {
    const id: InternId = @enumFromInt(n.payload);
    const text = ctx.pool.get(id);
    if (isCssIfCallText(text)) {
        if (try resolveCssIfSyntaxExpr(ctx, text, span)) |expr_idx| {
            return expr_idx;
        }
    }
    if (try resolveCssIfLeadingComparisonExpr(ctx, text, span)) |expr_idx| {
        return expr_idx;
    }
    if (try resolveCssSpecialCallExprFromSourceText(ctx, text, span)) |expr_idx| {
        return expr_idx;
    }
    if (try resolveCssEqArgFunctionExprFromSourceText(ctx, text, span)) |expr_idx| {
        return expr_idx;
    }
    if (std.mem.indexOf(u8, text, "#{") != null) {
        return resolveInterpolatedTextExpr(ctx, text, span, false);
    }
    if (ctx.calc_arg_mode and
        !(ctx.calc_arg_allow_numberish_ident_literals and isCalcArgNumberishIdentifier(text)))
    {
        const marked_id = try markCalcArgText(ctx, text);
        return try appendExpr(ctx.prog, ctx.a, .{
            .kind = .literal_string,
            .payload = packLiteralStringPayload(marked_id, false, false),
            .span = span,
        });
    }
    return try appendExpr(ctx.prog, ctx.a, .{
        .kind = .literal_string,
        .payload = packLiteralStringPayload(id, false, color_mod.lookupNamedColor(text) != null),
        .span = span,
    });
}

fn resolveExprTextTemplate(ast: *const ast_flat.Ast, ctx: *Ctx, node: NodeIndex, span: Span) ResolveError!ExprIndex {
    const text_storage = try astTextNodeRawAlloc(ctx.a, ast, ctx.pool, node);
    defer ctx.a.free(text_storage);
    const text = text_storage;
    if (isCssIfCallText(text)) {
        if (try resolveCssIfSyntaxExpr(ctx, text, span)) |expr_idx| {
            return expr_idx;
        }
    }
    if (try resolveCssIfLeadingComparisonExpr(ctx, text, span)) |expr_idx| {
        return expr_idx;
    }
    if (try resolveCssSpecialCallExprFromSourceText(ctx, text, span)) |expr_idx| {
        return expr_idx;
    }
    if (try resolveCssEqArgFunctionExprFromSourceText(ctx, text, span)) |expr_idx| {
        return expr_idx;
    }
    if (astTextNodeHasInterpolation(ast, node) or std.mem.indexOf(u8, text, "#{") != null) {
        return resolveInterpolatedTextExpr(ctx, text, span, false);
    }
    if (ctx.calc_arg_mode and
        !(ctx.calc_arg_allow_numberish_ident_literals and isCalcArgNumberishIdentifier(text)))
    {
        const marked_id = try markCalcArgText(ctx, text);
        return try appendExpr(ctx.prog, ctx.a, .{
            .kind = .literal_string,
            .payload = packLiteralStringPayload(marked_id, false, false),
            .span = span,
        });
    }
    const id = try ctx.pool.intern(text);
    return try appendExpr(ctx.prog, ctx.a, .{
        .kind = .literal_string,
        .payload = packLiteralStringPayload(id, false, color_mod.lookupNamedColor(text) != null),
        .span = span,
    });
}

fn resolveExprSlashExpr(ast: *const ast_flat.Ast, ctx: *Ctx, n: AstNode, span: Span) ResolveError!ExprIndex {
    const off: ExtraIndex = n.payload;
    const lhs: NodeIndex = @enumFromInt(ast.getExtraU32(off));
    const rhs: NodeIndex = @enumFromInt(ast.getExtraU32(off + 1));
    if (ctx.calc_arg_mode and
        (calcArgCompositeNeedsRuntimeInterpolation(ast, lhs) or calcArgCompositeNeedsRuntimeInterpolation(ast, rhs)))
    {
        return try resolveCalcArgBinaryInterp(ast, ctx, lhs, rhs, " / ", span);
    }
    if (ctx.calc_arg_mode and
        (nodeIsCalcLikeFunctionCall(ast, ctx, lhs) or nodeIsCalcLikeFunctionCall(ast, ctx, rhs)) and
        span.start <= span.end and span.end <= ast.source.len)
    {
        const raw_expr = std.mem.trim(u8, ast.source[span.start..span.end], " \t\r\n");
        if (raw_expr.len != 0) {
            const marked_id = try markCalcArgText(ctx, raw_expr);
            return try appendExpr(ctx.prog, ctx.a, .{
                .kind = .literal_string,
                .payload = packLiteralStringPayload(marked_id, false, false),
                .span = span,
            });
        }
    }
    const li = try resolveExpr(ast, ctx, lhs);
    const ri = try resolveExpr(ast, ctx, rhs);
    const lhs_calc_like = nodeIsCalcFunctionCall(ast, ctx, lhs);
    const rhs_calc_like = nodeIsCalcFunctionCall(ast, ctx, rhs);

    // `calc(...)/...` is kept as slash separator.
    // `calc(1)/2`, `1/calc(2)`, `calc(1)/calc(2)` are declarations
    // Maintain the `1/2` system even at boundaries and do not fold into numerical division (0.5).
    if (lhs_calc_like or rhs_calc_like) {
        var elems = [_]ExprIndex{ li, ri };
        return try appendListExprFromElems(ctx, elems[0..], .slash, false, false, false, span);
    }

    const lhs_lit_number = isLiteralNumberNode(ast, lhs);
    const rhs_lit_number = isLiteralNumberNode(ast, rhs);
    if (lhs_lit_number and rhs_lit_number) {
        var elems = [_]ExprIndex{ li, ri };
        return try appendListExprFromElems(ctx, elems[0..], .slash, false, false, true, span);
    }

    if (ctx.in_declaration_value and
        (nodeIsSlashLiteralOperand(ast, lhs) or
            nodeIsSlashLiteralOperand(ast, rhs)))
    {
        var elems = [_]ExprIndex{ li, ri };
        return try appendListExprFromElems(ctx, elems[0..], .slash, false, false, false, span);
    }

    if (unquoteCalcLiteralTextId(ast, ctx.pool, lhs) != null or
        unquoteCalcLiteralTextId(ast, ctx.pool, rhs) != null)
    {
        var elems = [_]ExprIndex{ li, ri };
        return try appendListExprFromElems(ctx, elems[0..], .slash, false, false, false, span);
    }

    if (rhs_lit_number and isSlashListExpr(ctx.prog, li)) {
        const lex = ctx.prog.exprs.items[li];
        const ll = ctx.prog.list_exprs.items[lex.payload];
        const existing = ctx.prog.list_elems.items[ll.elem_start .. ll.elem_start + ll.elem_count];
        var elems: std.ArrayListUnmanaged(ExprIndex) = .empty;
        defer elems.deinit(ctx.a);
        try elems.ensureTotalCapacity(ctx.a, existing.len + 1);
        try elems.appendSlice(ctx.a, existing);
        try elems.append(ctx.a, ri);
        return try appendListExprFromElems(ctx, elems.items, .slash, ll.bracketed, false, ll.slash_coercible, span);
    }

    // A chained slash + css-ish callable like `1/2/foo()` is
    //Keep slash list without folding into numeric division.
    // However, namespaced Sass module call (`list.nth(...)`)
    // Treat it as a normal division and fold it into a number at runtime.
    if (isSlashListExpr(ctx.prog, li) and ast.getNode(rhs).tag == .expr_func_call) {
        const rhs_call = ast.getNode(rhs);
        const rhs_off: ExtraIndex = rhs_call.payload;
        const rhs_ns: InternId = @enumFromInt(ast.getExtraU32(rhs_off + 1));
        if (rhs_ns == .none) {
            const lex = ctx.prog.exprs.items[li];
            const ll = ctx.prog.list_exprs.items[lex.payload];
            const existing = ctx.prog.list_elems.items[ll.elem_start .. ll.elem_start + ll.elem_count];
            var elems: std.ArrayListUnmanaged(ExprIndex) = .empty;
            defer elems.deinit(ctx.a);
            try elems.ensureTotalCapacity(ctx.a, existing.len + 1);
            try elems.appendSlice(ctx.a, existing);
            try elems.append(ctx.a, ri);
            return try appendListExprFromElems(ctx, elems.items, .slash, ll.bracketed, false, false, span);
        }
    }

    const bidx: u32 = @intCast(ctx.prog.binary_exprs.items.len);
    try ctx.prog.binary_exprs.append(ctx.a, .{ .lhs = li, .rhs = ri, .op = .div });
    return try appendExpr(ctx.prog, ctx.a, .{ .kind = .binary, .payload = bidx, .span = span });
}

fn resolveExprParen(ast: *const ast_flat.Ast, ctx: *Ctx, n: AstNode, span: Span) ResolveError!ExprIndex {
    const inner: NodeIndex = @enumFromInt(n.payload);
    const inner_node = ast.getNode(inner);
    if (ctx.calc_arg_mode and (inner_node.tag == .expr_variable or inner_node.tag == .expr_namespaced_var)) {
        const inner_e = try resolveExpr(ast, ctx, inner);
        const open_id = try markCalcArgText(ctx, "(");
        const close_id = try markCalcArgText(ctx, ")");
        const open_e = try appendExpr(ctx.prog, ctx.a, .{
            .kind = .literal_string,
            .payload = packLiteralStringPayload(open_id, false, false),
            .span = span,
        });
        const close_e = try appendExpr(ctx.prog, ctx.a, .{
            .kind = .literal_string,
            .payload = packLiteralStringPayload(close_id, false, false),
            .span = span,
        });
        const parts = [_]ExprIndex{ open_e, inner_e, close_e };
        return try appendInterpExprResolved(ctx, &parts, span, false);
    }
    if (ctx.calc_arg_mode and calcArgNodeNeedsRuntimeInterpolation(ast, inner)) {
        const inner_e = try resolveExpr(ast, ctx, inner);
        const open_id = try ctx.pool.intern("(");
        const close_id = try ctx.pool.intern(")");
        const open_e = try appendStringLiteralExpr(ctx.prog, ctx.a, open_id, span);
        const close_e = try appendStringLiteralExpr(ctx.prog, ctx.a, close_id, span);
        const parts = [_]ExprIndex{ open_e, inner_e, close_e };
        return try appendInterpExprResolved(ctx, &parts, span, false);
    }
    if (ctx.calc_arg_mode and shouldPreserveCalcParensNode(ast, ctx, inner) and span.start <= span.end and span.end <= ast.source.len) {
        const raw_paren = std.mem.trim(u8, ast.source[span.start..span.end], " \t\r\n");
        if (raw_paren.len != 0) {
            const marked_id = try markCalcArgText(ctx, raw_paren);
            return try appendExpr(ctx.prog, ctx.a, .{
                .kind = .literal_string,
                .payload = packLiteralStringPayload(marked_id, false, false),
                .span = span,
            });
        }
    }
    // Parentheses force slash-as-division semantics for the
    // immediately wrapped `/` expression (sass-spec
    // values/numbers/divide/slash_free/value.hrx::parentheses).
    // Short-circuit `expr_slash_expr` to a binary `div` so `(1/2)`
    // yields `0.5` rather than a slash list.
    if (inner_node.tag == .expr_slash_expr) {
        const off: ExtraIndex = inner_node.payload;
        const lhs: NodeIndex = @enumFromInt(ast.getExtraU32(off));
        const rhs: NodeIndex = @enumFromInt(ast.getExtraU32(off + 1));
        const li = try resolveExpr(ast, ctx, lhs);
        const ri = try resolveExpr(ast, ctx, rhs);
        const bidx: u32 = @intCast(ctx.prog.binary_exprs.items.len);
        try ctx.prog.binary_exprs.append(ctx.a, .{ .lhs = li, .rhs = ri, .op = .div });
        return try appendExpr(ctx.prog, ctx.a, .{ .kind = .binary, .payload = bidx, .span = span });
    }
    return resolveExpr(ast, ctx, inner);
}

fn resolveExprStringInterp(ast: *const ast_flat.Ast, ctx: *Ctx, n: AstNode, span: Span) ResolveError!ExprIndex {
    const off: ExtraIndex = n.payload;
    const quoted = (n.flags & 1) != 0;
    const part_count = ast.getExtraU32(off);
    var p: ExtraIndex = off + 1;
    var has_interpolated_part = false;
    {
        var scan_i: u32 = 0;
        var scan_p: ExtraIndex = off + 1;
        while (scan_i < part_count) : (scan_i += 1) {
            if (ast.getExtraU32(scan_p) != 0) {
                has_interpolated_part = true;
                break;
            }
            scan_p += 2;
        }
    }
    var resolved_parts: std.ArrayListUnmanaged(ExprIndex) = .empty;
    defer resolved_parts.deinit(ctx.a);

    // Preserve quoted-string interpolation semantics without injecting
    // literal quote characters into the string payload itself.
    //
    // Interp lowering currently compiles as chained `add` operations.
    // Seeding with an empty quoted string makes the final concatenated
    // value quoted while keeping textual content unchanged.
    if (quoted) {
        const empty_id = try ctx.pool.intern("");
        const seed = try appendExpr(ctx.prog, ctx.a, .{
            .kind = .literal_string,
            .payload = packLiteralStringPayload(empty_id, true, false),
            .span = span,
        });
        try resolved_parts.append(ctx.a, seed);
    }
    var i: u32 = 0;
    while (i < part_count) : (i += 1) {
        const kind = ast.getExtraU32(p);
        const val = ast.getExtraU32(p + 1);
        p += 2;
        if (kind == 0) {
            const id: InternId = @enumFromInt(val);
            const lit_text = ctx.pool.get(id);
            if (quoted and has_interpolated_part) {
                try appendLiteralExprPartWithQuote(ctx, &resolved_parts, lit_text, span, true);
            } else {
                try appendTextExprParts(ctx, &resolved_parts, lit_text, span, false);
            }
        } else {
            const inode: NodeIndex = @enumFromInt(val);
            const e = try resolveExpr(ast, ctx, inode);
            try resolved_parts.append(ctx.a, e);
        }
    }
    return try appendInterpExprResolved(ctx, resolved_parts.items, span, quoted);
}

fn resolveExprFuncCall(ast: *const ast_flat.Ast, ctx: *Ctx, n: AstNode, span: Span) ResolveError!ExprIndex {
    if (isPlainCssStylesheetPath(ctx.module_path)) {
        if (span.start <= span.end and span.end <= ast.source.len) {
            return resolveInterpolatedTextExpr(ctx, ast.source[span.start..span.end], span, false);
        }
        return error.SassError;
    }
    const off: ExtraIndex = n.payload;
    var name_id: InternId = @enumFromInt(ast.getExtraU32(off));
    const ns_id: InternId = @enumFromInt(ast.getExtraU32(off + 1));
    const arg_count = ast.getExtraU32(off + 2);
    const raw_name_is_interpolated = ns_id == .none and blk: {
        const raw_name = ctx.pool.get(name_id);
        break :blk std.mem.indexOf(u8, raw_name, "#{") != null;
    };
    if (ns_id == .none) {
        const raw_name = ctx.pool.get(name_id);
        if (std.mem.indexOf(u8, raw_name, "#{") != null) {
            const name_expr = try resolveInterpolatedTextExpr(ctx, raw_name, span, false);
            if (try tryFoldLiteralStringExpr(ctx, name_expr)) |folded_name_id| {
                name_id = folded_name_id;
            }
        }
    }
    const raw_name_for_if = ctx.pool.get(name_id);
    const unescaped_name = try css_utils.unescapeSassIdentifier(ctx.a, raw_name_for_if);
    defer if (unescaped_name.ptr != raw_name_for_if.ptr) ctx.a.free(unescaped_name);
    const name_slice = unescaped_name;
    const has_custom_function_binding = ns_id == .none and
        (lookupIdentifierIdInsensitive(&ctx.prog.function_names, name_slice) != null or
            ctx.lookupStarFunction(name_slice) != null);

    if (ns_id == .none and !has_custom_function_binding and span.start <= span.end and span.end <= ast.source.len and identifierEq(name_slice, "calc")) {
        const raw_calc_call = ast.source[span.start..span.end];
        if (std.mem.indexOfScalar(u8, raw_calc_call, '$') == null) {
            try validateRawCalcCallSyntax(ctx, raw_calc_call);
        }
    }

    if (ctx.calc_arg_mode and ns_id == .none and
        (identifierEq(name_slice, "var") or identifierEq(name_slice, "env")) and
        span.start <= span.end and span.end <= ast.source.len)
    {
        const raw_call = std.mem.trim(u8, ast.source[span.start..span.end], " \t\r\n");
        if (std.mem.indexOf(u8, raw_call, "#{") == null) {
            const marked_id = try markCalcArgText(ctx, raw_call);
            return try appendExpr(ctx.prog, ctx.a, .{
                .kind = .literal_string,
                .payload = packLiteralStringPayload(marked_id, false, false),
                .span = span,
            });
        }
    }

    if (ns_id == .none and std.mem.eql(u8, raw_name_for_if, "if")) {
        if (span.start <= span.end and span.end <= ast.source.len) {
            if (try resolveCssIfSyntaxExpr(ctx, ast.source[span.start..span.end], span)) |expr_idx| {
                return expr_idx;
            }
        }
        // Non-CSS `if(...)` keeps flowing into the normal builtin
        // resolution below so arity validation happens on the same
        // resolved-expression path as ordinary function calls.
    }

    if (ns_id == .none and isDoubleDashIdentifier(name_slice)) {
        if (span.start <= span.end and span.end <= ast.source.len) {
            return resolveInterpolatedTextExpr(ctx, ast.source[span.start..span.end], span, false);
        }
        return error.SassError;
    }
    if (ns_id == .none and !has_custom_function_binding and span.start <= span.end and span.end <= ast.source.len) {
        if (try resolveCssSpecialCallExprFromSourceText(ctx, ast.source[span.start..span.end], span)) |expr_idx| {
            return expr_idx;
        }
    }
    if (ns_id == .none and !has_custom_function_binding and isCssSpecialPassthroughFunction(name_slice)) {
        const canonical_name = try canonicalizeCssSpecialFunctionName(ctx.a, name_slice);
        defer ctx.a.free(canonical_name);
        return resolveCssSpecialOpaqueCallExpr(ctx, span, canonical_name);
    }
    const is_vendor_calc_special = if (ns_id == .none) blk: {
        if (cssSpecialBaseName(name_slice)) |base| {
            break :blk cssIdentEquals(base, "calc");
        }
        break :blk false;
    } else false;
    const is_calc_size_call = ns_id == .none and cssIdentEquals(name_slice, "calc-size");
    const is_css_math_legacy_call = ns_id == .none and
        !has_custom_function_binding and
        isCssMathLegacyCalcFunctionName(name_slice);
    const calc_arg_mode = is_vendor_calc_special or is_calc_size_call or is_css_math_legacy_call;
    const calc_arg_allow_numberish_ident_literals = is_css_math_legacy_call;
    const preserve_unquote_calc_first_arg =
        ns_id == .none and (identifierEq(name_slice, "invert") or identifierEq(name_slice, "saturate"));
    const allow_unknown_var_for_calc_if = ctx.calc_arg_mode and
        ns_id == .none and
        identifierEq(name_slice, "if");

    var arg_buf: std.ArrayListUnmanaged(ExprIndex) = .empty;
    defer arg_buf.deinit(ctx.a);
    var arg_name_buf: std.ArrayListUnmanaged(InternId) = .empty;
    defer arg_name_buf.deinit(ctx.a);
    const arg_nodes_start: ExtraIndex = off + 3;
    const arg_names_start: ExtraIndex = arg_nodes_start + arg_count;
    var ai: u32 = 0;
    while (ai < arg_count) : (ai += 1) {
        const an: NodeIndex = @enumFromInt(ast.getExtraU32(arg_nodes_start + ai));
        const raw_name: InternId = @enumFromInt(ast.getExtraU32(arg_names_start + ai));
        const arg_node = ast.getNode(an);
        if (arg_node.tag == .expr_splat) {
            const inner: NodeIndex = @enumFromInt(arg_node.payload);
            const saved_calc_arg_mode = ctx.calc_arg_mode;
            const inherit_calc_arg_mode = saved_calc_arg_mode and ns_id == .none and !has_custom_function_binding;
            ctx.calc_arg_mode = inherit_calc_arg_mode or calc_arg_mode;
            defer ctx.calc_arg_mode = saved_calc_arg_mode;
            const saved_calc_arg_allow_numberish = ctx.calc_arg_allow_numberish_ident_literals;
            ctx.calc_arg_allow_numberish_ident_literals =
                saved_calc_arg_allow_numberish or calc_arg_allow_numberish_ident_literals;
            defer ctx.calc_arg_allow_numberish_ident_literals = saved_calc_arg_allow_numberish;
            const saved_in_declaration_value = ctx.in_declaration_value;
            ctx.in_declaration_value = false;
            defer ctx.in_declaration_value = saved_in_declaration_value;
            const saved_allow_unknown_var = ctx.allow_unknown_var_literal;
            ctx.allow_unknown_var_literal = saved_allow_unknown_var or allow_unknown_var_for_calc_if;
            defer ctx.allow_unknown_var_literal = saved_allow_unknown_var;
            const resolved = resolveExpr(ast, ctx, inner) catch |err| {
                if (is_vendor_calc_special and err == error.UnknownVar) {
                    const canonical_name = try canonicalizeCssSpecialFunctionName(ctx.a, name_slice);
                    defer ctx.a.free(canonical_name);
                    return resolveCssSpecialOpaqueCallExpr(ctx, span, canonical_name);
                }
                return err;
            };
            try arg_buf.append(ctx.a, resolved);
            try arg_name_buf.append(ctx.a, call_arg_splat_sentinel);
            continue;
        }
        const saved_calc_arg_mode = ctx.calc_arg_mode;
        const inherit_calc_arg_mode = saved_calc_arg_mode and ns_id == .none and !has_custom_function_binding;
        ctx.calc_arg_mode = inherit_calc_arg_mode or calc_arg_mode;
        defer ctx.calc_arg_mode = saved_calc_arg_mode;
        const saved_calc_arg_allow_numberish = ctx.calc_arg_allow_numberish_ident_literals;
        ctx.calc_arg_allow_numberish_ident_literals =
            saved_calc_arg_allow_numberish or calc_arg_allow_numberish_ident_literals;
        defer ctx.calc_arg_allow_numberish_ident_literals = saved_calc_arg_allow_numberish;
        const saved_in_declaration_value = ctx.in_declaration_value;
        ctx.in_declaration_value = false;
        defer ctx.in_declaration_value = saved_in_declaration_value;
        const saved_allow_unknown_var = ctx.allow_unknown_var_literal;
        ctx.allow_unknown_var_literal = saved_allow_unknown_var or allow_unknown_var_for_calc_if;
        defer ctx.allow_unknown_var_literal = saved_allow_unknown_var;
        const resolved = resolveExpr(ast, ctx, an) catch |err| {
            if (is_vendor_calc_special and err == error.UnknownVar) {
                const canonical_name = try canonicalizeCssSpecialFunctionName(ctx.a, name_slice);
                defer ctx.a.free(canonical_name);
                return resolveCssSpecialOpaqueCallExpr(ctx, span, canonical_name);
            }
            return err;
        };
        var arg_expr = resolved;
        if (preserve_unquote_calc_first_arg and ai == 0 and raw_name == .none) {
            if (unquoteCalcLiteralTextId(ast, ctx.pool, an)) |calc_text_id| {
                const wrap_node = ast.getNode(an);
                const arg_span = Span{ .start = wrap_node.span_start, .end = wrap_node.span_end };
                arg_expr = try appendExpr(ctx.prog, ctx.a, .{
                    .kind = .literal_string,
                    .payload = packLiteralStringPayload(calc_text_id, true, false),
                    .span = arg_span,
                });
            }
        }
        try arg_buf.append(ctx.a, arg_expr);
        try arg_name_buf.append(ctx.a, raw_name);
    }

    if (raw_name_is_interpolated) {
        var can_lower_to_interpolated_css = true;
        for (arg_name_buf.items) |arg_name| {
            if (arg_name != .none) {
                can_lower_to_interpolated_css = false;
                break;
            }
        }
        if (can_lower_to_interpolated_css) {
            var parts: std.ArrayListUnmanaged(ExprIndex) = .empty;
            defer parts.deinit(ctx.a);
            try parts.ensureTotalCapacity(ctx.a, 3 + 2 * arg_buf.items.len);

            parts.appendAssumeCapacity(try resolveInterpolatedTextExpr(ctx, name_slice, span, false));
            const open_id = try ctx.pool.intern("(");
            parts.appendAssumeCapacity(try appendStringLiteralExpr(ctx.prog, ctx.a, open_id, span));
            for (arg_buf.items, 0..) |arg_expr, idx| {
                if (idx != 0) {
                    const comma_id = try ctx.pool.intern(", ");
                    parts.appendAssumeCapacity(try appendStringLiteralExpr(ctx.prog, ctx.a, comma_id, span));
                }
                parts.appendAssumeCapacity(arg_expr);
            }
            const close_id = try ctx.pool.intern(")");
            parts.appendAssumeCapacity(try appendStringLiteralExpr(ctx.prog, ctx.a, close_id, span));

            return try appendInterpExprResolved(ctx, parts.items, span, false);
        }

        const astart = try appendCallArgsWithNames(ctx.prog, ctx.a, arg_buf.items, arg_name_buf.items);
        const cidx: u32 = @intCast(ctx.prog.call_exprs.items.len);
        try ctx.prog.call_exprs.append(ctx.a, .{
            .callee_module = 0,
            .callee_id = 0,
            .callee_name = name_id,
            .callee_is_css = true,
            .arg_start = astart,
            .arg_count = @intCast(arg_buf.items.len),
        });
        return try appendExpr(ctx.prog, ctx.a, .{
            .kind = .call,
            .payload = cidx,
            .span = span,
        });
    }

    if (ns_id != .none) {
        const ns_str = ctx.pool.get(ns_id);
        const binding = lookupUseBindingInContext(ctx, ns_str) orelse {
            if (ctx.in_callable and !ctx.resolving_callable_default) {
                return try appendSassErrorExpr(ctx, span);
            }
            return error.UnknownFunctionNsMissing;
        };
        switch (binding) {
            .builtin_module => |mod| {
                const bid = builtin_mod.resolve(mod, name_slice) orelse {
                    if (ctx.in_callable and !ctx.resolving_callable_default) {
                        return try appendSassErrorExpr(ctx, span);
                    }
                    return error.UnknownFunctionInBuiltinNs;
                };
                try ensureMetaModuleLoadedForIntrospection(ctx, bid, arg_buf.items, arg_name_buf.items);
                if (try tryFoldMetaBuiltinExists(ctx, bid, arg_buf.items, arg_name_buf.items, span)) |folded| {
                    return folded;
                }
                const astart = try appendCallArgsWithNames(ctx.prog, ctx.a, arg_buf.items, arg_name_buf.items);
                const prebound = tryResolvePreboundMetaCallable(ctx, bid, astart, @intCast(arg_buf.items.len));
                const bidx: u32 = @intCast(ctx.prog.builtin_calls.items.len);
                try ctx.prog.builtin_calls.append(ctx.a, .{
                    .builtin_id = bid,
                    .arg_start = astart,
                    .arg_count = @intCast(arg_buf.items.len),
                    .local_slot_hint = resolveBuiltinLocalSlotHint(ctx, bid, astart, @intCast(arg_buf.items.len)),
                    .prebound_kind = prebound.kind,
                    .prebound_module = prebound.module_id,
                    .prebound_id = prebound.id,
                    .prebound_accepts_content = prebound.accepts_content,
                    .prebound_capture_callers_locals = prebound.captures_callers_locals,
                    .prebound_name = prebound.name,
                });
                return try appendExpr(ctx.prog, ctx.a, .{ .kind = .builtin_call, .payload = bidx, .span = span });
            },
            .user_module => |mid| {
                const user_fn_cache_key = packUserFunctionLookupCacheKey(mid, name_id);
                if (ctx.user_function_lookup_cache.get(user_fn_cache_key)) |target| {
                    const astart = try appendCallArgsWithNames(ctx.prog, ctx.a, arg_buf.items, arg_name_buf.items);
                    const cidx: u32 = @intCast(ctx.prog.call_exprs.items.len);
                    try ctx.prog.call_exprs.append(ctx.a, .{
                        .callee_module = target.module_id,
                        .callee_id = target.id,
                        .arg_start = astart,
                        .arg_count = @intCast(arg_buf.items.len),
                    });
                    return try appendExpr(ctx.prog, ctx.a, .{ .kind = .call, .payload = cidx, .span = span });
                }
                const ldr = try requireModuleLoader(ctx);
                const ex = try requireModuleExports(ldr, mid);
                if (lookupVoidFlagInsensitive(&ex.ambiguous_functions, name_slice)) return error.SassError;
                if (lookupIdentifierIdInsensitive(&ex.builtin_functions, name_slice)) |bid| {
                    try ensureMetaModuleLoadedForIntrospection(ctx, bid, arg_buf.items, arg_name_buf.items);
                    if (try tryFoldMetaBuiltinExists(ctx, bid, arg_buf.items, arg_name_buf.items, span)) |folded| {
                        return folded;
                    }
                    const astart = try appendCallArgsWithNames(ctx.prog, ctx.a, arg_buf.items, arg_name_buf.items);
                    const prebound = tryResolvePreboundMetaCallable(ctx, bid, astart, @intCast(arg_buf.items.len));
                    const bidx: u32 = @intCast(ctx.prog.builtin_calls.items.len);
                    try ctx.prog.builtin_calls.append(ctx.a, .{
                        .builtin_id = bid,
                        .arg_start = astart,
                        .arg_count = @intCast(arg_buf.items.len),
                        .local_slot_hint = resolveBuiltinLocalSlotHint(ctx, bid, astart, @intCast(arg_buf.items.len)),
                        .prebound_kind = prebound.kind,
                        .prebound_module = prebound.module_id,
                        .prebound_id = prebound.id,
                        .prebound_accepts_content = prebound.accepts_content,
                        .prebound_capture_callers_locals = prebound.captures_callers_locals,
                        .prebound_name = prebound.name,
                    });
                    return try appendExpr(ctx.prog, ctx.a, .{ .kind = .builtin_call, .payload = bidx, .span = span });
                }
                const target = lookupCallableTargetInsensitive(&ex.functions, name_slice) orelse return error.UnknownFunctionInUserNs;
                try ctx.user_function_lookup_cache.put(ctx.a, user_fn_cache_key, target);
                const astart = try appendCallArgsWithNames(ctx.prog, ctx.a, arg_buf.items, arg_name_buf.items);
                const cidx: u32 = @intCast(ctx.prog.call_exprs.items.len);
                try ctx.prog.call_exprs.append(ctx.a, .{
                    .callee_module = target.module_id,
                    .callee_id = target.id,
                    .arg_start = astart,
                    .arg_count = @intCast(arg_buf.items.len),
                });
                return try appendExpr(ctx.prog, ctx.a, .{ .kind = .call, .payload = cidx, .span = span });
            },
        }
    }
    if (ns_id == .none and identifierEq(name_slice, "if")) {
        return resolveLegacyIfBuiltinExpr(ctx, arg_buf.items, arg_name_buf.items, span);
    }
    const local_fid = lookupIdentifierIdInsensitive(&ctx.prog.function_names, name_slice);
    const astart = try appendCallArgsWithNames(ctx.prog, ctx.a, arg_buf.items, arg_name_buf.items);
    if (local_fid) |fid| {
        const cidx: u32 = @intCast(ctx.prog.call_exprs.items.len);
        try ctx.prog.call_exprs.append(ctx.a, .{
            .callee_module = local_module_id_sentinel,
            .callee_id = fid,
            .callee_name = name_id,
            .callee_capture_callers_locals = functionCapturesCallersLocalsById(ctx, fid),
            .arg_start = astart,
            .arg_count = @intCast(arg_buf.items.len),
        });
        return try appendExpr(ctx.prog, ctx.a, .{ .kind = .call, .payload = cidx, .span = span });
    }
    if (lookupVoidFlagInsensitive(&ctx.ambiguous_star_functions, name_slice)) {
        return error.SassError;
    }
    if (ctx.lookupStarFunction(name_slice)) |target| {
        const cidx: u32 = @intCast(ctx.prog.call_exprs.items.len);
        try ctx.prog.call_exprs.append(ctx.a, .{
            .callee_module = target.module_id,
            .callee_id = target.id,
            .arg_start = astart,
            .arg_count = @intCast(arg_buf.items.len),
        });
        return try appendExpr(ctx.prog, ctx.a, .{ .kind = .call, .payload = cidx, .span = span });
    }
    if (lookupIdentifierIdInsensitive(&ctx.star_builtin_fns, name_slice)) |bid| {
        const bidx: u32 = @intCast(ctx.prog.builtin_calls.items.len);
        const prebound = tryResolvePreboundMetaCallable(ctx, bid, astart, @intCast(arg_buf.items.len));
        try ctx.prog.builtin_calls.append(ctx.a, .{
            .builtin_id = bid,
            .arg_start = astart,
            .arg_count = @intCast(arg_buf.items.len),
            .local_slot_hint = resolveBuiltinLocalSlotHint(ctx, bid, astart, @intCast(arg_buf.items.len)),
            .prebound_kind = prebound.kind,
            .prebound_module = prebound.module_id,
            .prebound_id = prebound.id,
            .prebound_accepts_content = prebound.accepts_content,
            .prebound_capture_callers_locals = prebound.captures_callers_locals,
            .prebound_name = prebound.name,
        });
        return try appendExpr(ctx.prog, ctx.a, .{
            .kind = .builtin_call,
            .payload = bidx,
            .span = span,
        });
    } else {
        if (builtin_mod.resolveLegacyGlobal(name_slice)) |bid| {
            if (try tryFoldMetaBuiltinExists(ctx, bid, arg_buf.items, arg_name_buf.items, span)) |folded| {
                return folded;
            }
            const bidx: u32 = @intCast(ctx.prog.builtin_calls.items.len);
            const prebound = tryResolvePreboundMetaCallable(ctx, bid, astart, @intCast(arg_buf.items.len));
            try ctx.prog.builtin_calls.append(ctx.a, .{
                .builtin_id = bid,
                .arg_start = astart,
                .arg_count = @intCast(arg_buf.items.len),
                .local_slot_hint = resolveBuiltinLocalSlotHint(ctx, bid, astart, @intCast(arg_buf.items.len)),
                .prebound_kind = prebound.kind,
                .prebound_module = prebound.module_id,
                .prebound_id = prebound.id,
                .prebound_accepts_content = prebound.accepts_content,
                .prebound_capture_callers_locals = prebound.captures_callers_locals,
                .prebound_name = prebound.name,
            });
            return try appendExpr(ctx.prog, ctx.a, .{
                .kind = .builtin_call,
                .payload = bidx,
                .span = span,
            });
        }
        const css_name_id = try ctx.pool.intern(name_slice);
        const cidx: u32 = @intCast(ctx.prog.call_exprs.items.len);
        try ctx.prog.call_exprs.append(ctx.a, .{
            .callee_module = 0,
            .callee_id = 0,
            .callee_name = css_name_id,
            .callee_is_css = true,
            .callee_css_late_sass_resolution = ctx.in_callable and !ctx.resolving_callable_default,
            .arg_start = astart,
            .arg_count = @intCast(arg_buf.items.len),
        });
        return try appendExpr(ctx.prog, ctx.a, .{
            .kind = .call,
            .payload = cidx,
            .span = span,
        });
    }
}

fn resolveExpr(ast: *const ast_flat.Ast, ctx: *Ctx, node: NodeIndex) ResolveError!ExprIndex {
    if (node == .none) return error.SassError;
    const n = ast.getNode(node);
    const span = Span{ .start = n.span_start, .end = n.span_end };
    // CLI-FIX-E Step 2: When an error occurs, record the most recent expr span in thread-local.
    // The span of the innermost frame (= closest to the actual error location) remains (via recordErrorSpanIfUnset).
    // Resolver-only diagnostics do not yet carry the module file id here, so
    // this fallback records the entry span. Runtime errors use the VM
    // current_source_span.file_id path for module-specific frames.
    errdefer |err| {
        error_format.recordErrorSpanIfUnset(span.start, span.end, 0);
        error_format.recordErrorTag(err);
    }
    switch (n.tag) {
        .expr_number_immediate => {
            const v: f64 = @floatFromInt(@as(i32, @bitCast(n.payload)));
            return try appendNumberLiteral(ctx.prog, ctx.a, v, .none, span);
        },
        .expr_number_literal => {
            const off: ExtraIndex = n.payload;
            const lo = ast.getExtraU32(off);
            const hi = ast.getExtraU32(off + 1);
            const unit_id: InternId = @enumFromInt(ast.getExtraU32(off + 2));
            const bits: u64 = (@as(u64, hi) << 32) | @as(u64, lo);
            const v: f64 = @bitCast(bits);
            return try appendNumberLiteral(ctx.prog, ctx.a, v, unit_id, span);
        },
        .expr_string_literal => {
            const off: ExtraIndex = n.payload;
            const id: InternId = @enumFromInt(ast.getExtraU32(off));
            const quoted = (n.flags & 1) != 0;
            return try appendExpr(ctx.prog, ctx.a, .{
                .kind = .literal_string,
                .payload = packLiteralStringPayload(id, quoted, false),
                .span = span,
            });
        },
        .expr_color_hex => {
            const rgba = ast.getExtraU32(n.payload);
            const color_idx: u32 = @intCast(ctx.prog.color_literals.items.len);
            try ctx.prog.color_literals.append(ctx.a, .{
                .rgba = rgba,
                .alpha = std.math.nan(f64),
                .flags = n.flags,
            });
            return try appendExpr(ctx.prog, ctx.a, .{
                .kind = .literal_color,
                .payload = color_idx,
                .span = span,
            });
        },
        .expr_bool_true => return try appendExpr(ctx.prog, ctx.a, .{ .kind = .literal_bool, .payload = 1, .span = span }),
        .expr_bool_false => return try appendExpr(ctx.prog, ctx.a, .{ .kind = .literal_bool, .payload = 0, .span = span }),
        .expr_null => return try appendExpr(ctx.prog, ctx.a, .{ .kind = .literal_null, .payload = 0, .span = span }),
        .expr_important => {
            const id = try ctx.pool.intern("!important");
            return try appendExpr(ctx.prog, ctx.a, .{
                .kind = .literal_string,
                .payload = packLiteralStringPayload(id, false, false),
                .span = span,
            });
        },
        .expr_variable => return try resolveExprVariable(ast, ctx, n, span),
        .expr_namespaced_var => return try resolveExprNamespacedVar(ast, ctx, n, span),
        .expr_unquoted_ident => return try resolveExprUnquotedIdent(ctx, n, span),
        .expr_text_template => return try resolveExprTextTemplate(ast, ctx, node, span),
        .expr_binary_op => {
            const off: ExtraIndex = n.payload;
            const lhs: NodeIndex = @enumFromInt(ast.getExtraU32(off));
            const rhs: NodeIndex = @enumFromInt(ast.getExtraU32(off + 1));
            const op_u = ast.getExtraU32(off + 2);
            const op: AstBinOp = @enumFromInt(@as(u8, @truncate(op_u)));
            if (ctx.calc_arg_mode and
                calcArgMathOpText(op) != null and
                (calcArgNodeNeedsRuntimeInterpolation(ast, lhs) or calcArgNodeNeedsRuntimeInterpolation(ast, rhs)))
            {
                return try resolveCalcArgBinaryInterp(ast, ctx, lhs, rhs, calcArgMathOpText(op).?, span);
            }
            if (ctx.calc_arg_mode and
                (nodeIsCalcLikeFunctionCall(ast, ctx, lhs) or
                    nodeIsCalcLikeFunctionCall(ast, ctx, rhs) or
                    ((op == .add or op == .sub) and calcArgBinaryNeedsLiteralPreserve(ast, ctx, lhs, rhs))) and
                span.start <= span.end and span.end <= ast.source.len)
            {
                const raw_expr = std.mem.trim(u8, ast.source[span.start..span.end], " \t\r\n");
                if (raw_expr.len != 0) {
                    const marked_id = try markCalcArgText(ctx, raw_expr);
                    return try appendExpr(ctx.prog, ctx.a, .{
                        .kind = .literal_string,
                        .payload = packLiteralStringPayload(marked_id, false, false),
                        .span = span,
                    });
                }
            }
            const li = try resolveExpr(ast, ctx, lhs);
            const ri = try resolveExpr(ast, ctx, rhs);
            const bidx: u32 = @intCast(ctx.prog.binary_exprs.items.len);
            try ctx.prog.binary_exprs.append(ctx.a, .{ .lhs = li, .rhs = ri, .op = mapBinOp(op) });
            return try appendExpr(ctx.prog, ctx.a, .{ .kind = .binary, .payload = bidx, .span = span });
        },
        .expr_unary_op => {
            const off: ExtraIndex = n.payload;
            const operand: NodeIndex = @enumFromInt(ast.getExtraU32(off));
            const op_u = ast.getExtraU32(off + 1);
            const op: AstUnaryOp = @enumFromInt(@as(u8, @truncate(op_u)));
            const uop = mapUnaryOp(op);
            const oi = try resolveExpr(ast, ctx, operand);
            const uidx: u32 = @intCast(ctx.prog.unary_exprs.items.len);
            try ctx.prog.unary_exprs.append(ctx.a, .{ .operand = oi, .op = uop });
            return try appendExpr(ctx.prog, ctx.a, .{ .kind = .unary, .payload = uidx, .span = span });
        },
        .expr_slash_expr => return try resolveExprSlashExpr(ast, ctx, n, span),
        .expr_paren => return try resolveExprParen(ast, ctx, n, span),
        .expr_comma_list, .expr_space_list => {
            const off: ExtraIndex = n.payload;
            const raw = readChildList(ast, off);
            var children: std.ArrayListUnmanaged(NodeIndex) = .empty;
            defer children.deinit(ctx.a);
            try children.ensureTotalCapacity(ctx.a, raw.len);
            for (raw) |u| {
                children.appendAssumeCapacity(@enumFromInt(u));
            }
            const separator: ListSeparator = if (n.tag == .expr_comma_list) .comma else .space;
            return try resolveList(ast, ctx, children.items, separator, false, span);
        },
        .expr_bracketed_list => {
            const off: ExtraIndex = n.payload;
            const raw = readChildList(ast, off);
            var children: std.ArrayListUnmanaged(NodeIndex) = .empty;
            defer children.deinit(ctx.a);
            for (raw) |u| {
                try children.append(ctx.a, @enumFromInt(u));
            }
            const has_trailing_comma = (n.flags & ast_flat.LIST_FLAG_TRAILING_COMMA) != 0;
            const separator: ListSeparator = blk: {
                if (children.items.len == 0) break :blk .undecided;
                if (children.items.len == 1 and !has_trailing_comma) {
                    const child_tag = ast.getNode(children.items[0]).tag;
                    if (child_tag != .expr_comma_list and child_tag != .expr_space_list) {
                        break :blk .undecided;
                    }
                }
                break :blk .comma;
            };
            return try resolveList(ast, ctx, children.items, separator, true, span);
        },
        .expr_map_literal => {
            const off: ExtraIndex = n.payload;
            const pair_count = ast.getExtraU32(off);
            const key_start: ExtraIndex = off + 1;
            const val_start: ExtraIndex = key_start + pair_count;
            var pair_exprs: std.ArrayListUnmanaged(ExprIndex) = .empty;
            defer pair_exprs.deinit(ctx.a);
            try pair_exprs.ensureTotalCapacity(ctx.a, pair_count * 2);
            var i: u32 = 0;
            while (i < pair_count) : (i += 1) {
                const kn: NodeIndex = @enumFromInt(ast.getExtraU32(key_start + i));
                const vn: NodeIndex = @enumFromInt(ast.getExtraU32(val_start + i));
                const ke = try resolveExpr(ast, ctx, kn);
                const ve = try resolveExpr(ast, ctx, vn);
                try pair_exprs.append(ctx.a, ke);
                try pair_exprs.append(ctx.a, ve);
            }
            const estart: u32 = @intCast(ctx.prog.list_elems.items.len);
            try ctx.prog.list_elems.appendSlice(ctx.a, pair_exprs.items);
            const lidx: u32 = @intCast(ctx.prog.list_exprs.items.len);
            try ctx.prog.list_exprs.append(ctx.a, .{
                .elem_start = estart,
                .elem_count = pair_count * 2,
                .separator = .comma,
                .bracketed = false,
                .is_map = true,
            });
            return try appendExpr(ctx.prog, ctx.a, .{
                .kind = .list,
                .payload = lidx,
                .span = span,
            });
        },
        .expr_interp => {
            const inner: NodeIndex = @enumFromInt(n.payload);
            const inner_e = try resolveExpr(ast, ctx, inner);
            const part = [_]ExprIndex{inner_e};
            return try appendInterpExprResolved(ctx, &part, span, false);
        },
        .expr_string_interp => return try resolveExprStringInterp(ast, ctx, n, span),
        .expr_func_call => return try resolveExprFuncCall(ast, ctx, n, span),
        else => {
            if (error_format.verboseErrorsEnabled()) {
                resolverStderrPrint("zsass resolver unsupported expr tag={s} module={s}\n", .{ @tagName(n.tag), ctx.module_path });
            }
            return error.SassError;
        },
    }
}

fn isLiteralNumberNode(ast: *const ast_flat.Ast, node: NodeIndex) bool {
    const tag = ast.getNode(node).tag;
    return tag == .expr_number_immediate or tag == .expr_number_literal;
}

const StaticNumberInfo = struct {
    value: f64,
    unit_id: InternId,
};

fn extractStaticNumberInfo(ast: *const ast_flat.Ast, node: NodeIndex) ?StaticNumberInfo {
    const n = ast.getNode(node);
    return switch (n.tag) {
        .expr_number_immediate => .{
            .value = @as(f64, @floatFromInt(@as(i32, @bitCast(n.payload)))),
            .unit_id = .none,
        },
        .expr_number_literal => blk: {
            const off: ExtraIndex = n.payload;
            const lo = ast.getExtraU32(off);
            const hi = ast.getExtraU32(off + 1);
            const bits: u64 = (@as(u64, hi) << 32) | @as(u64, lo);
            break :blk .{
                .value = @bitCast(bits),
                .unit_id = @enumFromInt(ast.getExtraU32(off + 2)),
            };
        },
        else => null,
    };
}

fn staticUnitsEqualIgnoreCase(ctx: *Ctx, lhs: InternId, rhs: InternId) bool {
    if (lhs == .none or rhs == .none) return lhs == rhs;
    return std.ascii.eqlIgnoreCase(ctx.pool.get(lhs), ctx.pool.get(rhs));
}

fn convertComparableUnitValueStatic(ctx: *Ctx, value: f64, from: InternId, to: InternId) ?f64 {
    if (from == .none or to == .none) return null;
    if (staticUnitsEqualIgnoreCase(ctx, from, to)) return value;
    const from_info = comparableUnitInfo(ctx.pool.get(from)) orelse return null;
    const to_info = comparableUnitInfo(ctx.pool.get(to)) orelse return null;
    if (from_info.family != to_info.family) return null;
    return value * from_info.factor / to_info.factor;
}

fn combineStaticAddSub(ctx: *Ctx, lhs: StaticNumberInfo, rhs: StaticNumberInfo, is_sub: bool) ?StaticNumberInfo {
    const rhs_value = if (is_sub) -rhs.value else rhs.value;
    if (lhs.unit_id == .none and rhs.unit_id == .none) {
        return .{ .value = lhs.value + rhs_value, .unit_id = .none };
    }
    if (lhs.unit_id == .none) {
        return .{ .value = lhs.value + rhs_value, .unit_id = rhs.unit_id };
    }
    if (rhs.unit_id == .none) {
        return .{ .value = lhs.value + rhs_value, .unit_id = lhs.unit_id };
    }
    if (staticUnitsEqualIgnoreCase(ctx, lhs.unit_id, rhs.unit_id)) {
        return .{ .value = lhs.value + rhs_value, .unit_id = lhs.unit_id };
    }
    const rhs_converted = convertComparableUnitValueStatic(ctx, rhs_value, rhs.unit_id, lhs.unit_id) orelse return null;
    return .{ .value = lhs.value + rhs_converted, .unit_id = lhs.unit_id };
}

fn combineStaticMul(lhs: StaticNumberInfo, rhs: StaticNumberInfo) ?StaticNumberInfo {
    if (lhs.unit_id == .none and rhs.unit_id == .none) {
        return .{ .value = lhs.value * rhs.value, .unit_id = .none };
    }
    if (lhs.unit_id == .none) {
        return .{ .value = lhs.value * rhs.value, .unit_id = rhs.unit_id };
    }
    if (rhs.unit_id == .none) {
        return .{ .value = lhs.value * rhs.value, .unit_id = lhs.unit_id };
    }
    return null;
}

fn combineStaticDiv(ctx: *Ctx, lhs: StaticNumberInfo, rhs: StaticNumberInfo) ?StaticNumberInfo {
    if (rhs.value == 0) return null;
    if (rhs.unit_id == .none) {
        return .{ .value = lhs.value / rhs.value, .unit_id = lhs.unit_id };
    }
    if (lhs.unit_id == .none) return null;
    if (staticUnitsEqualIgnoreCase(ctx, lhs.unit_id, rhs.unit_id)) {
        return .{ .value = lhs.value / rhs.value, .unit_id = .none };
    }
    const rhs_converted = convertComparableUnitValueStatic(ctx, rhs.value, rhs.unit_id, lhs.unit_id) orelse return null;
    return .{ .value = lhs.value / rhs_converted, .unit_id = .none };
}

fn extractCalcArgStaticNumberInfo(ast: *const ast_flat.Ast, ctx: *Ctx, node: NodeIndex) ?StaticNumberInfo {
    if (extractStaticNumberInfo(ast, node)) |base| return base;

    const n = ast.getNode(node);
    return switch (n.tag) {
        .expr_paren => extractCalcArgStaticNumberInfo(ast, ctx, @enumFromInt(n.payload)),
        .expr_unary_op => blk: {
            const off: ExtraIndex = n.payload;
            const operand: NodeIndex = @enumFromInt(ast.getExtraU32(off));
            const op_u = ast.getExtraU32(off + 1);
            const op: AstUnaryOp = @enumFromInt(@as(u8, @truncate(op_u)));
            const inner = extractCalcArgStaticNumberInfo(ast, ctx, operand) orelse break :blk null;
            break :blk switch (op) {
                .positive => inner,
                .negate => .{ .value = -inner.value, .unit_id = inner.unit_id },
                else => null,
            };
        },
        .expr_binary_op => blk: {
            const off: ExtraIndex = n.payload;
            const lhs: NodeIndex = @enumFromInt(ast.getExtraU32(off));
            const rhs: NodeIndex = @enumFromInt(ast.getExtraU32(off + 1));
            const op_u = ast.getExtraU32(off + 2);
            const op: AstBinOp = @enumFromInt(@as(u8, @truncate(op_u)));
            const l = extractCalcArgStaticNumberInfo(ast, ctx, lhs) orelse break :blk null;
            const r = extractCalcArgStaticNumberInfo(ast, ctx, rhs) orelse break :blk null;
            break :blk switch (op) {
                .add => combineStaticAddSub(ctx, l, r, false),
                .sub => combineStaticAddSub(ctx, l, r, true),
                .mul => combineStaticMul(l, r),
                .div => combineStaticDiv(ctx, l, r),
                else => null,
            };
        },
        .expr_slash_expr => blk: {
            const off: ExtraIndex = n.payload;
            const lhs: NodeIndex = @enumFromInt(ast.getExtraU32(off));
            const rhs: NodeIndex = @enumFromInt(ast.getExtraU32(off + 1));
            const l = extractCalcArgStaticNumberInfo(ast, ctx, lhs) orelse break :blk null;
            const r = extractCalcArgStaticNumberInfo(ast, ctx, rhs) orelse break :blk null;
            break :blk combineStaticDiv(ctx, l, r);
        },
        else => null,
    };
}

fn isCssMathLegacyCalcFunctionName(name: []const u8) bool {
    const calc_names = [_][]const u8{
        "clamp",
        "hypot",
        "max",
        "min",
        "round",
    };
    for (calc_names) |candidate| {
        if (identifierEq(name, candidate)) return true;
    }
    return false;
}

fn isCalcArgNumberishIdentifier(text: []const u8) bool {
    const numberish_or_keyword = [_][]const u8{
        "infinity",
        "-infinity",
        "+infinity",
        "nan",
        "-nan",
        "+nan",
        "pi",
        "e",
        // round() strategy keywords should stay unmarked so positional
        // strategy parsing keeps working in legacy/global calls.
        "nearest",
        "up",
        "down",
        "to-zero",
    };
    for (numberish_or_keyword) |candidate| {
        if (cssIdentEquals(text, candidate)) return true;
    }
    return false;
}

fn calcArgBinaryNeedsLiteralPreserve(
    ast: *const ast_flat.Ast,
    ctx: *Ctx,
    lhs: NodeIndex,
    rhs: NodeIndex,
) bool {
    const l = extractCalcArgStaticNumberInfo(ast, ctx, lhs) orelse return false;
    const r = extractCalcArgStaticNumberInfo(ast, ctx, rhs) orelse return false;

    if (l.unit_id == .none or r.unit_id == .none) return false;

    const lu = ctx.pool.get(l.unit_id);
    const ru = ctx.pool.get(r.unit_id);
    if (std.ascii.eqlIgnoreCase(lu, ru)) return false;

    const l_is_percent = std.mem.eql(u8, lu, "%");
    const r_is_percent = std.mem.eql(u8, ru, "%");
    if (l_is_percent != r_is_percent) return true;

    const li = comparableUnitInfo(lu) orelse return true;
    const ri = comparableUnitInfo(ru) orelse return true;
    return li.family != ri.family;
}

fn calcArgMathOpText(op: AstBinOp) ?[]const u8 {
    return switch (op) {
        .add => " + ",
        .sub => " - ",
        else => null,
    };
}

fn calcArgNodeNeedsRuntimeInterpolation(ast: *const ast_flat.Ast, node: NodeIndex) bool {
    if (node == .none) return false;
    const n = ast.getNode(node);
    return switch (n.tag) {
        .expr_variable => true,
        .expr_namespaced_var => true,
        .expr_interp, .expr_string_interp, .expr_text_template => true,
        .expr_unary_op => blk: {
            const off: ExtraIndex = n.payload;
            const operand: NodeIndex = @enumFromInt(ast.getExtraU32(off));
            break :blk calcArgNodeNeedsRuntimeInterpolation(ast, operand);
        },
        .expr_paren => calcArgNodeNeedsRuntimeInterpolation(ast, @enumFromInt(n.payload)),
        .expr_binary_op => blk: {
            const off: ExtraIndex = n.payload;
            const lhs: NodeIndex = @enumFromInt(ast.getExtraU32(off));
            const rhs: NodeIndex = @enumFromInt(ast.getExtraU32(off + 1));
            break :blk calcArgNodeNeedsRuntimeInterpolation(ast, lhs) or
                calcArgNodeNeedsRuntimeInterpolation(ast, rhs);
        },
        .expr_slash_expr => blk: {
            const off: ExtraIndex = n.payload;
            const lhs: NodeIndex = @enumFromInt(ast.getExtraU32(off));
            const rhs: NodeIndex = @enumFromInt(ast.getExtraU32(off + 1));
            break :blk calcArgNodeNeedsRuntimeInterpolation(ast, lhs) or
                calcArgNodeNeedsRuntimeInterpolation(ast, rhs);
        },
        else => false,
    };
}

fn calcArgCompositeNeedsRuntimeInterpolation(ast: *const ast_flat.Ast, node: NodeIndex) bool {
    if (node == .none) return false;
    const n = ast.getNode(node);
    return switch (n.tag) {
        .expr_paren => calcArgNodeNeedsRuntimeInterpolation(ast, @enumFromInt(n.payload)),
        .expr_binary_op => blk: {
            const off: ExtraIndex = n.payload;
            const lhs: NodeIndex = @enumFromInt(ast.getExtraU32(off));
            const rhs: NodeIndex = @enumFromInt(ast.getExtraU32(off + 1));
            break :blk calcArgNodeNeedsRuntimeInterpolation(ast, lhs) or
                calcArgNodeNeedsRuntimeInterpolation(ast, rhs);
        },
        .expr_slash_expr => blk: {
            const off: ExtraIndex = n.payload;
            const lhs: NodeIndex = @enumFromInt(ast.getExtraU32(off));
            const rhs: NodeIndex = @enumFromInt(ast.getExtraU32(off + 1));
            break :blk calcArgNodeNeedsRuntimeInterpolation(ast, lhs) or
                calcArgNodeNeedsRuntimeInterpolation(ast, rhs);
        },
        else => false,
    };
}

fn resolveCalcArgBinaryInterp(
    ast: *const ast_flat.Ast,
    ctx: *Ctx,
    lhs: NodeIndex,
    rhs: NodeIndex,
    op_text: []const u8,
    span: Span,
) ResolveError!ExprIndex {
    const li = try resolveCalcArgInterpPart(ast, ctx, lhs, span);
    const ri = try resolveCalcArgInterpPart(ast, ctx, rhs, span);
    const marker_id = try markCalcInterpText(ctx, "");
    const marker_e = try appendStringLiteralExpr(ctx.prog, ctx.a, marker_id, span);
    const op_id = try ctx.pool.intern(op_text);
    const op_e = try appendStringLiteralExpr(ctx.prog, ctx.a, op_id, span);
    const parts = [_]ExprIndex{ marker_e, li, op_e, ri };
    return try appendInterpExprResolved(ctx, &parts, span, false);
}

fn numberIsIntegral(v: f64) bool {
    if (!std.math.isFinite(v)) return false;
    const rounded = @round(v);
    return std.math.approxEqAbs(f64, v, rounded, 1e-9);
}

fn comparableUnitInfo(unit: []const u8) ?struct { family: enum { length, angle, time, frequency, resolution }, factor: f64 } {
    // Length
    if (std.mem.eql(u8, unit, "px")) return .{ .family = .length, .factor = 1.0 };
    if (std.mem.eql(u8, unit, "in")) return .{ .family = .length, .factor = 96.0 };
    if (std.mem.eql(u8, unit, "cm")) return .{ .family = .length, .factor = 96.0 / 2.54 };
    if (std.mem.eql(u8, unit, "mm")) return .{ .family = .length, .factor = 96.0 / 25.4 };
    if (std.mem.eql(u8, unit, "pt")) return .{ .family = .length, .factor = 96.0 / 72.0 };
    if (std.mem.eql(u8, unit, "pc")) return .{ .family = .length, .factor = 16.0 };
    if (std.mem.eql(u8, unit, "Q") or std.mem.eql(u8, unit, "q")) return .{ .family = .length, .factor = 96.0 / 101.6 };

    // Angle
    if (std.mem.eql(u8, unit, "deg")) return .{ .family = .angle, .factor = 1.0 };
    if (std.mem.eql(u8, unit, "rad")) return .{ .family = .angle, .factor = 180.0 / std.math.pi };
    if (std.mem.eql(u8, unit, "grad")) return .{ .family = .angle, .factor = 0.9 };
    if (std.mem.eql(u8, unit, "turn")) return .{ .family = .angle, .factor = 360.0 };

    // Time
    if (std.mem.eql(u8, unit, "s")) return .{ .family = .time, .factor = 1.0 };
    if (std.mem.eql(u8, unit, "ms")) return .{ .family = .time, .factor = 0.001 };

    // Frequency
    if (std.mem.eql(u8, unit, "Hz")) return .{ .family = .frequency, .factor = 1.0 };
    if (std.mem.eql(u8, unit, "kHz")) return .{ .family = .frequency, .factor = 1000.0 };

    // Resolution
    if (std.mem.eql(u8, unit, "dppx")) return .{ .family = .resolution, .factor = 1.0 };
    if (std.mem.eql(u8, unit, "dpi")) return .{ .family = .resolution, .factor = 1.0 / 96.0 };
    if (std.mem.eql(u8, unit, "dpcm")) return .{ .family = .resolution, .factor = 2.54 / 96.0 };
    return null;
}

fn validateStaticForBounds(ctx: *Ctx, from_n: NodeIndex, to_n: NodeIndex) ResolveError!void {
    const from = extractStaticNumberInfo(ctx.ast, from_n) orelse return;
    const to = extractStaticNumberInfo(ctx.ast, to_n) orelse return;

    if (!numberIsIntegral(from.value) or !numberIsIntegral(to.value)) {
        return error.Unsupported;
    }

    if (from.unit_id == .none or to.unit_id == .none or from.unit_id == to.unit_id) return;
    const from_info = comparableUnitInfo(ctx.pool.get(from.unit_id)) orelse return error.Unsupported;
    const to_info = comparableUnitInfo(ctx.pool.get(to.unit_id)) orelse return error.Unsupported;
    if (from_info.family != to_info.family) return error.Unsupported;
    const to_in_from = to.value * to_info.factor / from_info.factor;
    if (!numberIsIntegral(to_in_from)) return error.Unsupported;
}

fn isSlashListExpr(prog: *const ResolvedProgram, expr: ExprIndex) bool {
    const ex = prog.exprs.items[expr];
    if (ex.kind != .list) return false;
    const l = prog.list_exprs.items[ex.payload];
    return l.separator == .slash;
}

/// Expose for compiler: used to decide whether `emit_decl`'s value came
/// directly from a syntactic `a/b` slash list (preserve in output) vs. an
/// indirection (function return, if() branch, variable ref -- coerce).
pub fn isDirectSlashListValueExpr(prog: *const ResolvedProgram, expr: ExprIndex) bool {
    return isSlashListExpr(prog, expr);
}

const ParsedNonEmptyLine = struct {
    raw: []const u8,
    trimmed: []const u8,
};

fn nextNonEmptyLine(text: []const u8, cursor: *usize) ?ParsedNonEmptyLine {
    while (cursor.* < text.len) {
        while (cursor.* < text.len and (text[cursor.*] == '\n' or text[cursor.*] == '\r')) : (cursor.* += 1) {}
        const line_start = cursor.*;
        while (cursor.* < text.len and text[cursor.*] != '\n' and text[cursor.*] != '\r') : (cursor.* += 1) {}
        const raw_line = text[line_start..cursor.*];
        const trimmed = std.mem.trim(u8, raw_line, " \t");
        if (trimmed.len != 0) return .{ .raw = raw_line, .trimmed = trimmed };
    }
    return null;
}

fn leadingIndentColumns(line: []const u8) usize {
    var cols: usize = 0;
    for (line) |c| {
        switch (c) {
            ' ' => cols += 1,
            '\t' => cols += 4,
            else => break,
        }
    }
    return cols;
}

fn sourceSliceHasTopLevelComma(text: []const u8) bool {
    var paren_depth: u32 = 0;
    var bracket_depth: u32 = 0;
    var brace_depth: u32 = 0;
    var in_string: u8 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (c == in_string) in_string = 0;
            continue;
        }
        switch (c) {
            '"', '\'' => in_string = c,
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            '{' => brace_depth += 1,
            '}' => {
                if (brace_depth > 0) brace_depth -= 1;
            },
            ',' => {
                if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) return true;
            },
            else => {},
        }
    }
    return false;
}

/// Requirements quick check for `sourceSpanLooksLikeBareMultilineComma`. declaration value
/// If raw text does not contain `,`, the end of the declaration start line cannot also be `,`
/// (Even in the `b: c,\n d` form of sass syntax, the value span is `c,...d` and includes `,`).
/// You can skip all line scans by confirming false for plain CSS-heavy inputs.
/// Aim for hot where `sourceSpanLooksLikeBareMultilineComma` accounted for perf flat 15%.
fn rawValueLooksLikeTrailingCommaCandidate(raw_val: []const u8) bool {
    return std.mem.indexOfScalar(u8, raw_val, ',') != null;
}

fn sourceSpanLooksLikeBareMultilineComma(text: []const u8, span: Span) bool {
    const start: usize = @min(@as(usize, @intCast(span.start)), text.len);
    if (start >= text.len) return false;

    var line_start = start;
    while (line_start > 0 and text[line_start - 1] != '\n' and text[line_start - 1] != '\r') : (line_start -= 1) {}
    var line_end = start;
    while (line_end < text.len and text[line_end] != '\n' and text[line_end] != '\r') : (line_end += 1) {}

    const line_raw = text[line_start..line_end];
    const line_trimmed = std.mem.trim(u8, line_raw, " \t");
    if (line_trimmed.len == 0) return false;
    const colon = std.mem.indexOfScalar(u8, line_trimmed, ':') orelse return false;
    const value_part = std.mem.trim(u8, line_trimmed[colon + 1 ..], " \t");
    if (value_part.len == 0 or value_part[value_part.len - 1] != ',') return false;
    if (std.mem.indexOfScalar(u8, value_part, '(') != null or std.mem.indexOfScalar(u8, value_part, ')') != null) return false;

    var cursor = line_end;
    while (cursor < text.len and (text[cursor] == '\n' or text[cursor] == '\r')) : (cursor += 1) {}
    const next_line = nextNonEmptyLine(text, &cursor) orelse return false;

    const current_indent = leadingIndentColumns(line_raw);
    const next_indent = leadingIndentColumns(next_line.raw);
    if (next_indent <= current_indent) return false;
    if (std.mem.indexOfScalar(u8, next_line.trimmed, ':') != null) return false;
    return true;
}

fn declarationSourceHasHorizontalWhitespaceAfterColon(text: []const u8, span: Span) bool {
    const start: usize = @min(@as(usize, @intCast(span.start)), text.len);
    const end: usize = @min(@as(usize, @intCast(span.end)), text.len);
    if (end <= start) return false;
    const slice = text[start..end];
    const colon = css_utils.findDeclarationColon(slice) orelse return false;
    const next = colon + 1;
    return next < slice.len and (slice[next] == ' ' or slice[next] == '\t');
}

fn declarationSourceHasWhitespaceAfterColon(text: []const u8, span: Span) bool {
    const start: usize = @min(@as(usize, @intCast(span.start)), text.len);
    const end: usize = @min(@as(usize, @intCast(span.end)), text.len);
    if (end <= start) return false;
    const slice = text[start..end];
    const colon = css_utils.findDeclarationColon(slice) orelse return false;
    const next = colon + 1;
    return next < slice.len and std.ascii.isWhitespace(slice[next]);
}

fn appendListExprFromElems(
    ctx: *Ctx,
    elems: []const ExprIndex,
    separator: ListSeparator,
    bracketed: bool,
    is_map: bool,
    slash_coercible: bool,
    span: Span,
) !ExprIndex {
    const estart: u32 = @intCast(ctx.prog.list_elems.items.len);
    try ctx.prog.list_elems.appendSlice(ctx.a, elems);
    const lidx: u32 = @intCast(ctx.prog.list_exprs.items.len);
    try ctx.prog.list_exprs.append(ctx.a, .{
        .elem_start = estart,
        .elem_count = @intCast(elems.len),
        .separator = separator,
        .bracketed = bracketed,
        .is_map = is_map,
        .slash_coercible = slash_coercible,
    });
    return try appendExpr(ctx.prog, ctx.a, .{ .kind = .list, .payload = lidx, .span = span });
}

fn resolveList(
    ast: *const ast_flat.Ast,
    ctx: *Ctx,
    children: []const NodeIndex,
    separator: ListSeparator,
    bracketed: bool,
    span: Span,
) !ExprIndex {
    // NOTE:
    // A child can itself be a list expression, and resolving that child
    // appends into `prog.list_elems`.  So we must not capture `estart`
    // before recursive `resolveExpr` calls, otherwise nested lists make the
    // parent list point at the wrong element window.
    var elems: std.ArrayListUnmanaged(ExprIndex) = .empty;
    defer elems.deinit(ctx.a);
    try elems.ensureTotalCapacity(ctx.a, children.len);
    for (children) |ch| {
        try elems.append(ctx.a, try resolveExpr(ast, ctx, ch));
    }
    var effective_separator = separator;
    if (!bracketed and effective_separator == .comma and children.len == 0) {
        effective_separator = .undecided;
    }
    return try appendListExprFromElems(ctx, elems.items, effective_separator, bracketed, false, false, span);
}

/// Closing `}` for `#{ ... }`, honoring nested `#{`, strings, and `//` / `/* */` comments.
fn findInterpExprEnd(text: []const u8, inner_start: usize) ?usize {
    var depth: u32 = 1;
    var p = inner_start;
    while (p < text.len) {
        if (p + 1 < text.len and text[p] == '#' and text[p + 1] == '{') {
            depth += 1;
            p += 2;
            continue;
        }
        if (text[p] == '}') {
            depth -= 1;
            if (depth == 0) return p;
            p += 1;
            continue;
        }
        if (text[p] == '"' or text[p] == '\'') {
            const quote = text[p];
            p += 1;
            while (p < text.len) {
                if (text[p] == '\\' and p + 1 < text.len) {
                    p += 2;
                    continue;
                }
                if (text[p] == quote) {
                    p += 1;
                    break;
                }
                p += 1;
            }
            continue;
        }
        if (p + 1 < text.len and text[p] == '/' and text[p + 1] == '/') {
            p += 2;
            while (p < text.len and text[p] != '\n') p += 1;
            continue;
        }
        if (p + 1 < text.len and text[p] == '/' and text[p + 1] == '*') {
            p += 2;
            while (p + 1 < text.len) {
                if (text[p] == '*' and text[p + 1] == '/') {
                    p += 2;
                    break;
                }
                p += 1;
            }
            continue;
        }
        p += 1;
    }
    return null;
}

fn interpolationStartEscaped(text: []const u8, hash_pos: usize) bool {
    var bs_count: usize = 0;
    var p = hash_pos;
    while (p > 0 and text[p - 1] == '\\') : (p -= 1) {
        bs_count += 1;
    }
    return (bs_count % 2) == 1;
}

fn findNextInterpolationStart(text: []const u8, start: usize) ?usize {
    var i = start;
    while (i + 1 < text.len) : (i += 1) {
        if (text[i] != '#' or text[i + 1] != '{') continue;
        if (interpolationStartEscaped(text, i)) continue;
        return i;
    }
    return null;
}

fn textHasRealInterpolationOutsideSkips(text: []const u8) bool {
    var in_string: u8 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];

        if (in_string != 0) {
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (c == in_string) in_string = 0;
            continue;
        }

        if (c == '"' or c == '\'') {
            in_string = c;
            continue;
        }

        if (c == '/' and i + 1 < text.len) {
            if (text[i + 1] == '*') {
                i += 2;
                while (i + 1 < text.len) : (i += 1) {
                    if (text[i] == '*' and text[i + 1] == '/') {
                        i += 1;
                        break;
                    }
                }
                continue;
            }
            if (text[i + 1] == '/') {
                i += 2;
                while (i < text.len and text[i] != '\n' and text[i] != '\r') : (i += 1) {}
                continue;
            }
        }

        if (c == '#' and i + 1 < text.len and text[i + 1] == '{' and !interpolationStartEscaped(text, i)) {
            return true;
        }
    }
    return false;
}

fn parseSubExpr(ctx: *Ctx, inner: []const u8, _: Span) ResolveError!ExprIndex {
    var sub_ast = ast_flat.Ast.init(ctx.a, inner, .none);
    defer sub_ast.deinit();
    var lexer = lexer_mod.Lexer.init(ctx.a, inner);
    defer lexer.deinit();
    const tokens = lexer.tokenize() catch return error.SassError;
    var parser = parser_mod.Parser.init(ctx.a, ctx.pool, tokens, inner);
    defer parser.deinit();
    parser.pos = 0;
    const expr_root = parser.parseExpression(&sub_ast) catch return error.SassError;
    var ppos = parser.pos;
    while (ppos < parser.tokens.len) {
        const t = parser.tokens[ppos].tag;
        if (t == .whitespace or t == .newline or t == .comment) {
            ppos += 1;
            continue;
        }
        break;
    }
    if (ppos < parser.tokens.len and parser.tokens[ppos].tag != .eof) return error.SassError;

    var sub_ctx = Ctx{
        .ast = &sub_ast,
        .pool = ctx.pool,
        .prog = ctx.prog,
        .a = ctx.a,
        .root_alloc = ctx.root_alloc,
        .module_path = ctx.module_path,
        .loader = ctx.loader,
        .static_eval_store = ctx.static_eval_store,
        .color_pool = ctx.color_pool,
        .scopes = ctx.scopes,
        .star_vars = ctx.star_vars,
        .ambiguous_star_vars = ctx.ambiguous_star_vars,
        .star_mixins = ctx.star_mixins,
        .ambiguous_star_mixins = ctx.ambiguous_star_mixins,
        .star_functions = ctx.star_functions,
        .ambiguous_star_functions = ctx.ambiguous_star_functions,
        .star_mixins_have_mixed_alias_keys = ctx.star_mixins_have_mixed_alias_keys,
        .star_functions_have_mixed_alias_keys = ctx.star_functions_have_mixed_alias_keys,
        .star_placeholders = ctx.star_placeholders,
        .star_builtin_fns = ctx.star_builtin_fns,
        .forward_rules = ctx.forward_rules,
        .next_local_slot = ctx.next_local_slot,
        .in_callable = ctx.in_callable,
        .resolving_callable_default = ctx.resolving_callable_default,
        .deferred_callable_default_use_bindings = ctx.deferred_callable_default_use_bindings,
        .mixin_accepts_content = ctx.mixin_accepts_content,
    };
    return resolveExpr(&sub_ast, &sub_ctx, expr_root);
}

fn isBareVarIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

fn isBareNamespaceStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '-';
}

fn findNextBareVarReference(text: []const u8, start: usize) ?struct { start: usize, end: usize } {
    var i = start;
    var in_string: u8 = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (c == in_string) in_string = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            continue;
        }
        if (c == '$') {
            var j = i + 1;
            if (j >= text.len or !isBareVarIdentChar(text[j])) continue;
            while (j < text.len and isBareVarIdentChar(text[j])) : (j += 1) {}
            return .{ .start = i, .end = j };
        }
        if (!isBareNamespaceStart(c)) continue;
        var j = i + 1;
        while (j < text.len and isBareVarIdentChar(text[j])) : (j += 1) {}
        if (j + 2 > text.len or text[j] != '.' or text[j + 1] != '$') continue;
        var k = j + 2;
        if (k >= text.len or !isBareVarIdentChar(text[k])) continue;
        while (k < text.len and isBareVarIdentChar(text[k])) : (k += 1) {}
        return .{ .start = i, .end = k };
    }
    return null;
}

/// Scan the interpolation in `text` (bare `$var` / `ns.$var` when `#{...}` and `allow_bare_vars=true`),
/// Push the literal part and the interpolation expression to `out` in order. Old `appendInterpolatedTextParts` /
/// Consolidated version of `appendInterpTemplateParts`.
fn appendInterpolationParts(ctx: *Ctx, text: []const u8, span: Span, out: *std.ArrayListUnmanaged(ExprIndex), allow_bare_vars: bool) ResolveError!void {
    var i: usize = 0;
    while (i < text.len) {
        const next_interp_start = findNextInterpolationStart(text, i);
        const next_bare = if (allow_bare_vars) findNextBareVarReference(text, i) else null;

        const choose_interp = blk: {
            if (next_interp_start == null and next_bare == null) break :blk false;
            if (next_interp_start != null and next_bare == null) break :blk true;
            if (next_interp_start == null and next_bare != null) break :blk false;
            break :blk next_interp_start.? <= next_bare.?.start;
        };

        if (next_interp_start == null and next_bare == null) {
            if (i < text.len) {
                const lit_id = try ctx.pool.intern(text[i..text.len]);
                try out.append(ctx.a, try appendRawTextLiteralExpr(ctx.prog, ctx.a, lit_id, span));
            }
            break;
        }

        if (choose_interp) {
            const hash_pos = next_interp_start.?;
            if (hash_pos > i) {
                const lit_id = try ctx.pool.intern(text[i..hash_pos]);
                try out.append(ctx.a, try appendRawTextLiteralExpr(ctx.prog, ctx.a, lit_id, span));
            }
            const inner_start = hash_pos + 2;
            const inner_end = findInterpExprEnd(text, inner_start) orelse return error.SassError;
            const saved_allow_unknown_var = ctx.allow_unknown_var_literal;
            ctx.allow_unknown_var_literal = false;
            defer ctx.allow_unknown_var_literal = saved_allow_unknown_var;
            const expr_idx = try parseSubExpr(ctx, text[inner_start..inner_end], span);
            try out.append(ctx.a, expr_idx);
            i = inner_end + 1;
            continue;
        }

        const bare = next_bare.?;
        if (bare.start > i) {
            const lit_id = try ctx.pool.intern(text[i..bare.start]);
            try out.append(ctx.a, try appendRawTextLiteralExpr(ctx.prog, ctx.a, lit_id, span));
        }
        const expr_idx = try parseSubExpr(ctx, text[bare.start..bare.end], span);
        try out.append(ctx.a, expr_idx);
        i = bare.end;
    }
}

fn appendCalcLiteralTextPart(ctx: *Ctx, out: *std.ArrayListUnmanaged(ExprIndex), text: []const u8, span: Span) ResolveError!void {
    if (text.len == 0) return;
    const normalized = calc_utils.simplifyInterpolatedCalcLiteralChunk(ctx.a, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer if (normalized) |buf| ctx.a.free(buf);
    const literal = normalized orelse text;
    const lit_id = try ctx.pool.intern(literal);
    try out.append(ctx.a, try appendRawTextLiteralExpr(ctx.prog, ctx.a, lit_id, span));
}

fn isSimpleSlashNumberToken(text: []const u8) bool {
    const raw = std.mem.trim(u8, text, " \t\r\n");
    if (raw.len == 0) return false;
    var i: usize = 0;
    if (raw[i] == '+' or raw[i] == '-') {
        i += 1;
        if (i >= raw.len) return false;
    }
    var saw_digit = false;
    if (i < raw.len and raw[i] == '.') {
        i += 1;
        while (i < raw.len and std.ascii.isDigit(raw[i])) : (i += 1) saw_digit = true;
    } else {
        while (i < raw.len and std.ascii.isDigit(raw[i])) : (i += 1) saw_digit = true;
        if (i < raw.len and raw[i] == '.') {
            i += 1;
            while (i < raw.len and std.ascii.isDigit(raw[i])) : (i += 1) saw_digit = true;
        }
    }
    if (!saw_digit) return false;
    if (i < raw.len and (raw[i] == 'e' or raw[i] == 'E')) {
        const exp_start = i;
        i += 1;
        if (i < raw.len and (raw[i] == '+' or raw[i] == '-')) i += 1;
        const digits_start = i;
        while (i < raw.len and std.ascii.isDigit(raw[i])) : (i += 1) {}
        if (i == digits_start) i = exp_start;
    }
    if (i < raw.len and raw[i] == '%') i += 1 else {
        while (i < raw.len and (std.ascii.isAlphabetic(raw[i]) or raw[i] == '_' or raw[i] == '-')) : (i += 1) {}
    }
    return i == raw.len;
}

fn appendCompactTrimmed(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    try out.appendSlice(allocator, std.mem.trim(u8, text, " \t\r\n"));
}

fn preservedCalcSlashInterpolationLiteral(ctx: *Ctx, text: []const u8) ResolveError!?[]const u8 {
    const raw = std.mem.trim(u8, text, " \t\r\n");
    if (raw.len == 0) return null;
    var depth: u32 = 0;
    var slash_pos: ?usize = null;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '(') {
            depth += 1;
            continue;
        }
        if (c == ')') {
            if (depth == 0) return null;
            depth -= 1;
            continue;
        }
        if (depth == 0 and c == '/') {
            if (slash_pos != null) return null;
            slash_pos = i;
        } else if (depth == 0 and (c == '+' or c == '*' or c == ',' or c == '[' or c == ']' or c == '{' or c == '}')) {
            return null;
        } else if (depth == 0 and c == '-') {
            const prev = if (i == 0) 0 else raw[i - 1];
            if (i != 0 and prev != 'e' and prev != 'E' and prev != ' ' and prev != '\t' and prev != '\r' and prev != '\n') return null;
        }
    }
    const slash = slash_pos orelse return null;
    const left = raw[0..slash];
    const right = raw[slash + 1 ..];
    if (!isSimpleSlashNumberToken(left) or !isSimpleSlashNumberToken(right)) return null;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(ctx.a);
    try out.appendSlice(ctx.a, calc_interp_preserve_start);
    try appendCompactTrimmed(&out, ctx.a, left);
    try out.appendSlice(ctx.a, calc_interp_preserve_slash);
    try appendCompactTrimmed(&out, ctx.a, right);
    try out.appendSlice(ctx.a, calc_interp_preserve_end);
    return try out.toOwnedSlice(ctx.a);
}

/// Split an interpolated `calc()` argument like `appendInterpolationParts()`,
/// but let complete literal-only multiplicative terms simplify before runtime
/// interpolation concatenates the pieces. This keeps the existing calc marker
/// boundary while matching official Sass CLI for `calc(#{$x} + 4px * 2)` without
/// simplifying `calc(#{$x} * 2)`.
fn appendCalcInterpolationParts(ctx: *Ctx, text: []const u8, span: Span, out: *std.ArrayListUnmanaged(ExprIndex)) ResolveError!void {
    var i: usize = 0;
    while (i < text.len) {
        const next_interp_start = findNextInterpolationStart(text, i);
        if (next_interp_start == null) {
            try appendCalcLiteralTextPart(ctx, out, text[i..text.len], span);
            break;
        }

        const hash_pos = next_interp_start.?;
        if (hash_pos > i) {
            try appendCalcLiteralTextPart(ctx, out, text[i..hash_pos], span);
        }
        const inner_start = hash_pos + 2;
        const inner_end = findInterpExprEnd(text, inner_start) orelse return error.SassError;
        const saved_allow_unknown_var = ctx.allow_unknown_var_literal;
        ctx.allow_unknown_var_literal = false;
        defer ctx.allow_unknown_var_literal = saved_allow_unknown_var;
        const inner = text[inner_start..inner_end];
        if (try preservedCalcSlashInterpolationLiteral(ctx, inner)) |literal| {
            defer ctx.a.free(literal);
            try appendLiteralExprPart(ctx, out, literal, span);
        } else {
            const preserve_wrapped_interpolation = hash_pos > 0 and text[hash_pos - 1] == '(' and
                inner_end + 1 < text.len and text[inner_end + 1] == ')';
            if (preserve_wrapped_interpolation) try appendLiteralExprPart(ctx, out, calc_interp_preserve_start, span);
            const expr_idx = try parseSubExpr(ctx, inner, span);
            try out.append(ctx.a, expr_idx);
            if (preserve_wrapped_interpolation) try appendLiteralExprPart(ctx, out, calc_interp_preserve_end, span);
        }
        i = inner_end + 1;
    }
}

fn unwrapInterpolatedCalcOuterParensText(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '(' or trimmed[trimmed.len - 1] != ')') return text;
    const close = findMatchingParenSimple(trimmed, 0) orelse return text;
    if (close != trimmed.len - 1) return text;
    const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
    if (std.mem.startsWith(u8, inner, "#{")) {
        const interp_end = findInterpExprEnd(inner, 2) orelse return text;
        if (interp_end + 1 == inner.len) return text;
    }
    if (std.mem.indexOfAny(u8, inner, "+-*/") == null) return text;
    return inner;
}

fn unwrapInterpolatedNestedCalcText(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len < 6 or !std.ascii.startsWithIgnoreCase(trimmed, "calc(") or trimmed[trimmed.len - 1] != ')') return text;
    const close = findMatchingParenSimple(trimmed, 4) orelse return text;
    if (close != trimmed.len - 1) return text;
    const inner = std.mem.trim(u8, trimmed[5..close], " \t\r\n");
    if (std.mem.startsWith(u8, inner, "#{\"") or std.mem.startsWith(u8, inner, "#{\'")) return text;
    return inner;
}

fn resolveInterpolatedTextExpr(ctx: *Ctx, text: []const u8, span: Span, allow_bare_vars: bool) ResolveError!ExprIndex {
    if (isCssIfCallText(text)) {
        if (try resolveCssIfSyntaxExpr(ctx, text, span)) |expr_idx| {
            return expr_idx;
        }
    }

    if (std.mem.indexOf(u8, text, "#{") == null and (!allow_bare_vars or std.mem.indexOfScalar(u8, text, '$') == null)) {
        const id = try ctx.pool.intern(text);
        return try appendExpr(ctx.prog, ctx.a, .{
            .kind = .literal_string,
            .payload = packLiteralStringPayload(id, false, false),
            .span = span,
        });
    }

    var parts: std.ArrayListUnmanaged(ExprIndex) = .empty;
    defer parts.deinit(ctx.a);
    try appendInterpolationParts(ctx, text, span, &parts, allow_bare_vars);
    if (parts.items.len == 0) {
        const empty_id = try ctx.pool.intern("");
        return try appendStringLiteralExpr(ctx.prog, ctx.a, empty_id, span);
    }

    return try appendInterpExprResolved(ctx, parts.items, span, false);
}

fn appendStringLiteralExpr(prog: *ResolvedProgram, alloc: std.mem.Allocator, lit_id: InternId, span: Span) !ExprIndex {
    return appendStringLiteralExprWithQuote(prog, alloc, lit_id, span, false);
}

fn appendStringLiteralExprWithQuote(
    prog: *ResolvedProgram,
    alloc: std.mem.Allocator,
    lit_id: InternId,
    span: Span,
    quoted: bool,
) !ExprIndex {
    return try appendExpr(prog, alloc, .{
        .kind = .literal_string,
        .payload = packLiteralStringPayload(lit_id, quoted, false),
        .span = span,
    });
}

/// Raw-text literal: created from source-text fragments (e.g. interpolation
/// split produces literal chunks between `#{...}` boundaries).
/// Marked with `raw_text` so the compiler does NOT apply the literal_string
/// "&"  ->  load_parent_selector shortcut: the outer nesting resolver must
/// still see the bare `&` character to drive cartesian selector expansion.
fn appendRawTextLiteralExpr(prog: *ResolvedProgram, alloc: std.mem.Allocator, lit_id: InternId, span: Span) !ExprIndex {
    return try appendExpr(prog, alloc, .{
        .kind = .literal_string,
        .payload = packLiteralStringPayloadEx(lit_id, false, false, true),
        .span = span,
    });
}

const InterpCallSourceFlags = struct {
    name_has_interp: bool = false,
    args_have_interp: bool = false,
};

fn analyzeInterpolatedCallSource(text: []const u8) InterpCallSourceFlags {
    var flags: InterpCallSourceFlags = .{};
    var in_string: u8 = 0;
    var saw_lparen = false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (c == in_string) in_string = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            continue;
        }
        if (!saw_lparen and c == '(') {
            saw_lparen = true;
            continue;
        }
        if (c == '#' and i + 1 < text.len and text[i + 1] == '{') {
            if (saw_lparen) {
                flags.args_have_interp = true;
            } else {
                flags.name_has_interp = true;
            }
            i += 1;
        }
    }
    return flags;
}

fn interpCallSourceFlagsFromSpan(ast: *const ast_flat.Ast, span: Span) InterpCallSourceFlags {
    if (span.start > span.end or span.end > ast.source.len) return .{};
    return analyzeInterpolatedCallSource(ast.source[span.start..span.end]);
}

fn appendInterpExprResolved(
    ctx: *Ctx,
    parts: []const ExprIndex,
    span: Span,
    preserve_quote: bool,
) ResolveError!ExprIndex {
    const pstart: u32 = @intCast(ctx.prog.interp_parts.items.len);
    for (parts) |part_expr| {
        try ctx.prog.interp_parts.append(ctx.a, part_expr);
    }
    const call_flags = interpCallSourceFlagsFromSpan(ctx.ast, span);
    const iidx: u32 = @intCast(ctx.prog.interp_exprs.items.len);
    try ctx.prog.interp_exprs.append(ctx.a, .{
        .part_start = pstart,
        .part_count = @intCast(parts.len),
        .preserve_quote = preserve_quote,
        .source_name_has_interp = call_flags.name_has_interp,
        .source_args_have_interp = call_flags.args_have_interp,
    });
    return try appendExpr(ctx.prog, ctx.a, .{
        .kind = .interp,
        .payload = iidx,
        .span = span,
    });
}

fn markInterpExprErrorOnUndeclaredVar(prog: *ResolvedProgram, expr: ExprIndex) void {
    const ex = prog.exprs.items[expr];
    if (ex.kind != .interp) return;
    prog.interp_exprs.items[ex.payload].error_on_undeclared_var = true;
}

fn appendLiteralExprPart(
    ctx: *Ctx,
    parts: *std.ArrayListUnmanaged(ExprIndex),
    text: []const u8,
    span: Span,
) ResolveError!void {
    return appendLiteralExprPartWithQuote(ctx, parts, text, span, false);
}

fn appendLiteralExprPartWithQuote(
    ctx: *Ctx,
    parts: *std.ArrayListUnmanaged(ExprIndex),
    text: []const u8,
    span: Span,
    quoted: bool,
) ResolveError!void {
    if (text.len == 0) return;
    const lit_id = try ctx.pool.intern(text);
    try parts.append(ctx.a, try appendStringLiteralExprWithQuote(ctx.prog, ctx.a, lit_id, span, quoted));
}

fn appendTextExprParts(
    ctx: *Ctx,
    parts: *std.ArrayListUnmanaged(ExprIndex),
    text: []const u8,
    span: Span,
    allow_bare_vars: bool,
) ResolveError!void {
    if (text.len == 0) return;
    if (std.mem.indexOf(u8, text, "#{") != null or
        (allow_bare_vars and std.mem.indexOfScalar(u8, text, '$') != null))
    {
        try appendInterpolationParts(ctx, text, span, parts, allow_bare_vars);
        return;
    }
    try appendLiteralExprPart(ctx, parts, text, span);
}

fn finishConcatExprParts(
    ctx: *Ctx,
    parts: []const ExprIndex,
    span: Span,
) ResolveError!ExprIndex {
    if (parts.len == 0) {
        const empty_id = try ctx.pool.intern("");
        return try appendStringLiteralExpr(ctx.prog, ctx.a, empty_id, span);
    }
    if (parts.len == 1) return parts[0];

    return try appendInterpExprResolved(ctx, parts, span, false);
}

fn findMatchingBracketSimple(text: []const u8, open_pos: usize) ?usize {
    if (open_pos >= text.len or text[open_pos] != '[') return null;
    var depth: u32 = 1;
    var i = open_pos + 1;
    var in_string: u8 = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (c == in_string) in_string = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            continue;
        }
        if (c == '[') {
            depth += 1;
        } else if (c == ']') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn mediaOperandHasTopLevelGroupedSyntax(text: []const u8) bool {
    var i: usize = 0;
    var paren_depth: u32 = 0;
    var bracket_depth: u32 = 0;
    var in_string: u8 = 0;
    var interp_depth: u32 = 0;

    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (interp_depth > 0) {
            switch (c) {
                '{' => interp_depth += 1,
                '}' => {
                    interp_depth -= 1;
                },
                else => {},
            }
            continue;
        }
        if (in_string != 0) {
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (c == in_string) in_string = 0;
            continue;
        }
        switch (c) {
            '#' => if (i + 1 < text.len and text[i + 1] == '{') {
                interp_depth = 1;
                i += 1;
            },
            '"', '\'' => in_string = c,
            '(' => {
                if (paren_depth == 0 and bracket_depth == 0 and i != 0) return true;
                paren_depth += 1;
            },
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '[' => {
                if (paren_depth == 0 and bracket_depth == 0) return true;
                bracket_depth += 1;
            },
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            ',' => if (paren_depth == 0 and bracket_depth == 0) return true,
            else => {},
        }
    }

    return false;
}

fn mediaOperandNeedsParse(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (media_prelude.looksLikeMediaLogicalCondition(trimmed) or media_prelude.isMediaRatioLiteral(trimmed)) {
        return false;
    }
    if (std.mem.indexOf(u8, trimmed, "#{") != null or std.mem.indexOfScalar(u8, trimmed, '$') != null) return true;
    if (css_utils.containsArithmeticOp(trimmed) or css_utils.containsTopLevelSlash(trimmed)) return true;
    if (media_prelude.findTopLevelMediaRangeOperator(trimmed) != null) return true;

    if (trimmed[0] == '(') {
        if (findMatchingParenSimple(trimmed, 0)) |close| {
            if (close == trimmed.len - 1) {
                return mediaOperandNeedsParse(trimmed[1 .. trimmed.len - 1]);
            }
        }
    }
    if (trimmed[0] == '[') {
        if (findMatchingBracketSimple(trimmed, 0)) |close| {
            if (close == trimmed.len - 1) {
                return mediaOperandNeedsParse(trimmed[1 .. trimmed.len - 1]);
            }
        }
    }

    if (mediaOperandHasTopLevelGroupedSyntax(trimmed)) return true;
    return false;
}

fn resolveMediaDynamicOperandExpr(ctx: *Ctx, text: []const u8, span: Span) ResolveError!ExprIndex {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len >= 2 and trimmed[0] == '[') {
        if (findMatchingBracketSimple(trimmed, 0)) |close| {
            if (close == trimmed.len - 1) {
                var parts: std.ArrayListUnmanaged(ExprIndex) = .empty;
                defer parts.deinit(ctx.a);
                try appendLiteralExprPart(ctx, &parts, "[", span);
                const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
                if (inner.len > 0) {
                    if (mediaOperandNeedsParse(inner)) {
                        try parts.append(ctx.a, try resolveMediaDynamicOperandExpr(ctx, inner, span));
                    } else {
                        try appendTextExprParts(ctx, &parts, inner, span, true);
                    }
                }
                try appendLiteralExprPart(ctx, &parts, "]", span);
                return finishConcatExprParts(ctx, parts.items, span);
            }
        }
    }
    if (std.mem.indexOf(u8, trimmed, "#{") != null) {
        var parts: std.ArrayListUnmanaged(ExprIndex) = .empty;
        defer parts.deinit(ctx.a);
        try appendTextExprParts(ctx, &parts, trimmed, span, true);
        return finishConcatExprParts(ctx, parts.items, span);
    }
    return try parseSubExpr(ctx, trimmed, span);
}

fn resolveMediaParenExpression(ctx: *Ctx, inner: []const u8, span: Span) ResolveError!ExprIndex {
    const trimmed_inner = std.mem.trim(u8, inner, " \t\r\n");
    if (trimmed_inner.len == 0) {
        const empty_id = try ctx.pool.intern("");
        return try appendStringLiteralExpr(ctx.prog, ctx.a, empty_id, span);
    }

    if (css_utils.findDeclarationColon(inner)) |colon_pos| {
        const lhs_raw = inner[0..colon_pos];
        if (media_prelude.findTopLevelMediaRangeOperator(lhs_raw) != null) {
            const raw_id = try ctx.pool.intern(trimmed_inner);
            return try appendStringLiteralExpr(ctx.prog, ctx.a, raw_id, span);
        }

        var parts: std.ArrayListUnmanaged(ExprIndex) = .empty;
        defer parts.deinit(ctx.a);

        const lhs = std.mem.trim(u8, lhs_raw, " \t\r\n");
        const rhs = std.mem.trim(u8, inner[colon_pos + 1 ..], " \t\r\n");

        if (mediaOperandNeedsParse(lhs)) {
            try parts.append(ctx.a, try resolveMediaDynamicOperandExpr(ctx, lhs, span));
        } else {
            try appendTextExprParts(ctx, &parts, lhs, span, true);
        }
        try appendLiteralExprPart(ctx, &parts, ": ", span);
        if (mediaOperandNeedsParse(rhs)) {
            try parts.append(ctx.a, try resolveMediaDynamicOperandExpr(ctx, rhs, span));
        } else {
            try appendTextExprParts(ctx, &parts, rhs, span, true);
        }
        return finishConcatExprParts(ctx, parts.items, span);
    }

    if (media_prelude.findTopLevelMediaRangeOperator(inner) != null) {
        var parts: std.ArrayListUnmanaged(ExprIndex) = .empty;
        defer parts.deinit(ctx.a);

        var start: usize = 0;
        var i: usize = 0;
        while (i < inner.len) {
            if (media_prelude.matchTopLevelMediaRangeOperator(inner, i)) |op_len| {
                const operand = std.mem.trim(u8, inner[start..i], " \t\r\n");
                if (mediaOperandNeedsParse(operand)) {
                    try parts.append(ctx.a, try resolveMediaDynamicOperandExpr(ctx, operand, span));
                } else {
                    try appendTextExprParts(ctx, &parts, operand, span, true);
                }
                try appendLiteralExprPart(ctx, &parts, " ", span);
                try appendLiteralExprPart(ctx, &parts, inner[i .. i + op_len], span);
                try appendLiteralExprPart(ctx, &parts, " ", span);
                i += op_len;
                start = i;
                continue;
            }
            i += 1;
        }

        const operand = std.mem.trim(u8, inner[start..], " \t\r\n");
        if (mediaOperandNeedsParse(operand)) {
            try parts.append(ctx.a, try resolveMediaDynamicOperandExpr(ctx, operand, span));
        } else {
            try appendTextExprParts(ctx, &parts, operand, span, true);
        }
        return finishConcatExprParts(ctx, parts.items, span);
    }

    if (mediaOperandNeedsParse(trimmed_inner)) {
        return try resolveMediaDynamicOperandExpr(ctx, trimmed_inner, span);
    }

    const raw_id = try ctx.pool.intern(trimmed_inner);
    return try appendStringLiteralExpr(ctx.prog, ctx.a, raw_id, span);
}

fn mediaPreludeNeedsEvaluation(text: []const u8) bool {
    if (std.mem.indexOf(u8, text, "#{") != null or std.mem.indexOfScalar(u8, text, '$') != null) return true;

    var i: usize = 0;
    var in_string: u8 = 0;
    while (i < text.len) {
        const c = text[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < text.len) {
                i += 2;
                continue;
            }
            if (c == in_string) in_string = 0;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            i += 1;
            continue;
        }
        if (c == '(') {
            const close = findMatchingParenSimple(text, i) orelse return false;
            if (mediaOperandNeedsParse(text[i + 1 .. close])) return true;
            i = close + 1;
            continue;
        }
        i += 1;
    }
    return false;
}

fn resolveMediaPreludeExpr(ctx: *Ctx, text: []const u8, span: Span) ResolveError!ExprIndex {
    var parts: std.ArrayListUnmanaged(ExprIndex) = .empty;
    defer parts.deinit(ctx.a);

    const has_interpolation = std.mem.indexOf(u8, text, "#{") != null;
    var start: usize = 0;
    var i: usize = 0;
    var in_string: u8 = 0;
    while (i < text.len) {
        const c = text[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < text.len) {
                i += 2;
                continue;
            }
            if (c == in_string) in_string = 0;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            i += 1;
            continue;
        }
        if (i + 1 < text.len and c == '#' and text[i + 1] == '{') {
            const inner_end = findInterpExprEnd(text, i + 2) orelse return error.SassError;
            i = inner_end + 1;
            continue;
        }
        if (c == '(') {
            const close = findMatchingParenSimple(text, i) orelse break;
            if (!has_interpolation) {
                const normalized_prefix = try prelude.normalizeMediaKeywords(ctx.a, text[start..i]);
                defer if (normalized_prefix.ptr != text[start..i].ptr) ctx.a.free(normalized_prefix);
                try appendTextExprParts(ctx, &parts, normalized_prefix, span, true);
            } else {
                try appendTextExprParts(ctx, &parts, text[start..i], span, true);
            }
            try appendLiteralExprPart(ctx, &parts, "(", span);
            try parts.append(ctx.a, try resolveMediaParenExpression(ctx, text[i + 1 .. close], span));
            try appendLiteralExprPart(ctx, &parts, ")", span);
            i = close + 1;
            start = i;
            continue;
        }
        i += 1;
    }

    if (!has_interpolation) {
        const normalized_tail = try prelude.normalizeMediaKeywords(ctx.a, text[start..]);
        defer if (normalized_tail.ptr != text[start..].ptr) ctx.a.free(normalized_tail);
        try appendTextExprParts(ctx, &parts, normalized_tail, span, true);
    } else {
        try appendTextExprParts(ctx, &parts, text[start..], span, true);
    }
    if (parts.items.len == 1 and std.mem.indexOf(u8, text, "#{") != null) {
        return try appendInterpExprResolved(ctx, parts.items, span, false);
    }
    return finishConcatExprParts(ctx, parts.items, span);
}

fn supportsOperandNeedsEvaluation(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (std.mem.indexOf(u8, trimmed, "#{") != null) return true;
    if (std.mem.indexOfScalar(u8, trimmed, '$') != null) return true;
    if (css_utils.containsCalcFunction(trimmed)) return false;
    return css_utils.containsArithmeticOp(trimmed);
}

fn resolveSupportsDynamicOperandExpr(ctx: *Ctx, text: []const u8, span: Span) ResolveError!ExprIndex {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) {
        const empty_id = try ctx.pool.intern("");
        return try appendStringLiteralExpr(ctx.prog, ctx.a, empty_id, span);
    }
    if (std.mem.indexOf(u8, trimmed, "#{") != null) {
        if (std.mem.startsWith(u8, trimmed, "#{")) {
            if (findInterpExprEnd(trimmed, 2)) |inner_end| {
                if (inner_end == trimmed.len - 1) {
                    const interp_inner = std.mem.trim(u8, trimmed[2..inner_end], " \t\r\n");
                    if (interp_inner.len > 5 and
                        std.ascii.eqlIgnoreCase(interp_inner[0..4], "calc") and
                        interp_inner[4] == '(')
                    {
                        if (findMatchingParenSimple(interp_inner, 4)) |calc_close| {
                            if (calc_close == interp_inner.len - 1) {
                                const calc_inner = std.mem.trim(u8, interp_inner[5..calc_close], " \t\r\n");
                                return try parseSubExpr(ctx, calc_inner, span);
                            }
                        }
                    }
                }
            }
        }
        return try resolveInterpolatedTextExpr(ctx, trimmed, span, true);
    }
    if (css_utils.containsCalcFunction(trimmed) and std.mem.indexOfScalar(u8, trimmed, '$') != null) {
        return try resolveInterpolatedTextExpr(ctx, trimmed, span, true);
    }
    return try parseSubExpr(ctx, trimmed, span);
}

fn resolveSupportsDeclarationExpr(
    ctx: *Ctx,
    inner: []const u8,
    colon_pos: usize,
    span: Span,
) ResolveError!ExprIndex {
    const lhs_raw = inner[0..colon_pos];
    const rhs_raw = inner[colon_pos + 1 ..];
    const lhs = std.mem.trim(u8, lhs_raw, " \t\r\n");
    const rhs = std.mem.trim(u8, rhs_raw, " \t\r\n");
    const is_custom = std.mem.startsWith(u8, lhs, "--");

    if (is_custom) {
        if (std.mem.indexOf(u8, inner, "#{") != null or std.mem.indexOfScalar(u8, inner, '$') != null) {
            return try resolveInterpolatedTextExpr(ctx, inner, span, true);
        }
        const raw_id = try ctx.pool.intern(inner);
        return try appendStringLiteralExpr(ctx.prog, ctx.a, raw_id, span);
    }

    if (!supportsOperandNeedsEvaluation(lhs) and !supportsOperandNeedsEvaluation(rhs)) {
        const raw_id = try ctx.pool.intern(inner);
        return try appendStringLiteralExpr(ctx.prog, ctx.a, raw_id, span);
    }

    var parts: std.ArrayListUnmanaged(ExprIndex) = .empty;
    defer parts.deinit(ctx.a);

    if (supportsOperandNeedsEvaluation(lhs)) {
        try parts.append(ctx.a, try resolveSupportsDynamicOperandExpr(ctx, lhs, span));
    } else {
        try appendTextExprParts(ctx, &parts, lhs, span, false);
    }
    try appendLiteralExprPart(ctx, &parts, ": ", span);
    if (supportsOperandNeedsEvaluation(rhs)) {
        try parts.append(ctx.a, try resolveSupportsDynamicOperandExpr(ctx, rhs, span));
    } else {
        try appendTextExprParts(ctx, &parts, rhs, span, false);
    }
    return finishConcatExprParts(ctx, parts.items, span);
}

fn resolveSupportsInnerExpr(ctx: *Ctx, inner: []const u8, span: Span) ResolveError!ExprIndex {
    if (css_utils.findDeclarationColon(inner)) |colon_pos| {
        return try resolveSupportsDeclarationExpr(ctx, inner, colon_pos, span);
    }
    return try resolveSupportsPreludeExpr(ctx, inner, span);
}

fn resolveSupportsPreludeExpr(ctx: *Ctx, text: []const u8, span: Span) ResolveError!ExprIndex {
    var parts: std.ArrayListUnmanaged(ExprIndex) = .empty;
    defer parts.deinit(ctx.a);

    var start: usize = 0;
    var i: usize = 0;
    var in_string: u8 = 0;
    while (i < text.len) {
        const c = text[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < text.len) {
                i += 2;
                continue;
            }
            if (c == in_string) in_string = 0;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            i += 1;
            continue;
        }
        if (c == '(') {
            const is_func = blk: {
                if (i == 0) break :blk false;
                const prev = text[i - 1];
                break :blk std.ascii.isAlphanumeric(prev) or prev == '-' or prev == '_';
            };
            if (!is_func) {
                const close = findMatchingParenSimple(text, i) orelse break;
                try appendTextExprParts(ctx, &parts, text[start..i], span, false);
                try appendLiteralExprPart(ctx, &parts, "(", span);
                try parts.append(ctx.a, try resolveSupportsInnerExpr(ctx, text[i + 1 .. close], span));
                try appendLiteralExprPart(ctx, &parts, ")", span);
                i = close + 1;
                start = i;
                continue;
            }
        }
        i += 1;
    }

    try appendTextExprParts(ctx, &parts, text[start..], span, false);
    return finishConcatExprParts(ctx, parts.items, span);
}

const CssIfClause = struct {
    condition: []const u8,
    value: []const u8,
    is_else: bool,
};

const CssIfTokenKind = enum {
    clause,
    op_not,
    op_and,
    op_or,
    op_else,
};

const CssIfToken = struct {
    kind: CssIfTokenKind,
    text: []const u8,
};

fn isCssIfCallText(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len < 4) return false;
    if (!std.mem.eql(u8, trimmed[0..2], "if")) return false;
    return trimmed[2] == '(';
}

fn isCssIfIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

fn cssIfKeywordKind(word: []const u8) ?CssIfTokenKind {
    if (std.ascii.eqlIgnoreCase(word, "not")) return .op_not;
    if (std.ascii.eqlIgnoreCase(word, "and")) return .op_and;
    if (std.ascii.eqlIgnoreCase(word, "or")) return .op_or;
    if (std.ascii.eqlIgnoreCase(word, "else")) return .op_else;
    return null;
}

fn isCssIfSyntax(args: []const u8) bool {
    var depth: i32 = 0;
    var in_string: u8 = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const c = args[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < args.len) {
                i += 1;
                continue;
            }
            if (c == in_string) in_string = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            continue;
        }
        if (c == '(') {
            depth += 1;
            continue;
        }
        if (c == ')') {
            depth -= 1;
            continue;
        }
        if (depth == 0 and c == ':') {
            if (i > 0) {
                var j: usize = i - 1;
                while (j > 0 and (isIdentifierChar(args[j]) or args[j] == '-')) : (j -= 1) {}
                if (j < i and args[j] == '$') {
                    const before_dollar = std.mem.trimEnd(u8, args[0..j], " \t\n\r");
                    if (before_dollar.len == 0) continue;
                }
            }
            return true;
        }
        if (depth == 0 and c == ',') return false;
    }
    return false;
}

fn parseCssIfClause(text: []const u8) CssIfClause {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    var depth: i32 = 0;
    var in_string: u8 = 0;
    var ci: usize = 0;
    while (ci < trimmed.len) : (ci += 1) {
        const c = trimmed[ci];
        if (in_string != 0) {
            if (c == '\\' and ci + 1 < trimmed.len) {
                ci += 1;
                continue;
            }
            if (c == in_string) in_string = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            continue;
        }
        if (c == '(') {
            depth += 1;
            continue;
        }
        if (c == ')') {
            if (depth > 0) depth -= 1;
            continue;
        }
        if (depth == 0 and c == ':') {
            const cond_part = std.mem.trim(u8, trimmed[0..ci], " \t\r\n");
            const val_part = std.mem.trim(u8, trimmed[ci + 1 ..], " \t\r\n");
            return .{
                .condition = cond_part,
                .value = val_part,
                .is_else = std.ascii.eqlIgnoreCase(cond_part, "else"),
            };
        }
    }
    return .{ .condition = trimmed, .value = "", .is_else = false };
}

fn appendCssIfClauseToken(
    alloc: std.mem.Allocator,
    tokens: *std.ArrayListUnmanaged(CssIfToken),
    text: []const u8,
) ResolveError!void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) {
        try tokens.append(alloc, .{ .kind = .clause, .text = "" });
        return;
    }
    try tokens.append(alloc, .{ .kind = .clause, .text = trimmed });
}

fn appendNonEmptyCssIfClauseToken(
    alloc: std.mem.Allocator,
    tokens: *std.ArrayListUnmanaged(CssIfToken),
    text: []const u8,
) ResolveError!void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return;
    try tokens.append(alloc, .{ .kind = .clause, .text = trimmed });
}

const CssIfCondEval = union(enum) {
    sass_true,
    sass_false,
    css_unknown: ExprIndex,
    sass_expr: ExprIndex,
};

fn tokenizeCssIfCondition(alloc: std.mem.Allocator, text: []const u8) ResolveError!?std.ArrayListUnmanaged(CssIfToken) {
    var tokens: std.ArrayListUnmanaged(CssIfToken) = .empty;
    errdefer tokens.deinit(alloc);

    var depth: i32 = 0;
    var in_string: u8 = 0;
    var chunk_start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < text.len) {
                i += 2;
                continue;
            }
            if (c == in_string) in_string = 0;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            i += 1;
            continue;
        }
        if (c == '(') {
            if (depth == 0 and i > chunk_start) {
                const before = std.mem.trimEnd(u8, text[chunk_start..i], " \t\r\n");
                if (before.len > 0) {
                    const last = before[before.len - 1];
                    if (!isCssIfIdentChar(last) and last != '#' and last != '}') {
                        const start = blk: {
                            var s = i;
                            while (s > chunk_start and
                                (text[s - 1] == ' ' or text[s - 1] == '\t' or text[s - 1] == '\n' or text[s - 1] == '\r'))
                            {
                                s -= 1;
                            }
                            break :blk s;
                        };
                        if (start > chunk_start) return null;
                    }
                }
            }
            depth += 1;
            i += 1;
            continue;
        }
        if (c == ')') {
            if (depth > 0) depth -= 1;
            i += 1;
            continue;
        }
        if (depth == 0 and std.ascii.isAlphabetic(c)) {
            const word_start = i;
            var word_end = i + 1;
            while (word_end < text.len and isCssIfIdentChar(text[word_end])) : (word_end += 1) {}
            if (cssIfKeywordKind(text[word_start..word_end])) |kind| {
                const prev_ok = word_start == 0 or !isCssIfIdentChar(text[word_start - 1]);
                const next_ok = word_end == text.len or !isCssIfIdentChar(text[word_end]);
                if (prev_ok and next_ok) {
                    if (word_end < text.len and text[word_end] == '(' and kind != .op_else) {
                        return null;
                    }
                    try appendNonEmptyCssIfClauseToken(alloc, &tokens, text[chunk_start..word_start]);
                    try tokens.append(alloc, .{ .kind = kind, .text = text[word_start..word_end] });
                    chunk_start = word_end;
                    i = word_end;
                    continue;
                }
            }
        }
        i += 1;
    }

    try appendCssIfClauseToken(alloc, &tokens, text[chunk_start..]);
    return tokens;
}

fn validateCssIfClauseText(alloc: std.mem.Allocator, text: []const u8) ResolveError!bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(trimmed, "else")) return false;

    if (trimmed[0] == '(') {
        if (findMatchingParenSimple(trimmed, 0)) |end_idx| {
            if (end_idx == trimmed.len - 1) {
                const inner = std.mem.trim(u8, trimmed[1..end_idx], " \t\r\n");
                if (inner.len == 0) return false;
                return try validateCssIfCondition(alloc, inner);
            }
        }
    }

    var depth: i32 = 0;
    var in_string: u8 = 0;
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        const c = trimmed[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < trimmed.len) {
                i += 1;
                continue;
            }
            if (c == in_string) in_string = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            continue;
        }
        if (c == '(') {
            if (depth == 0) {
                const prev = blk: {
                    var j = i;
                    while (j > 0) {
                        const p = trimmed[j - 1];
                        if (p == ' ' or p == '\t' or p == '\n' or p == '\r') {
                            j -= 1;
                            continue;
                        }
                        break :blk p;
                    }
                    break :blk @as(u8, 0);
                };
                if (prev == 0 or (!isCssIfIdentChar(prev) and prev != '#' and prev != '}')) {
                    return false;
                }
            }
            depth += 1;
            continue;
        }
        if (c == ')') {
            if (depth > 0) depth -= 1;
            continue;
        }
        if (depth == 0 and c == ',') return false;
    }
    return true;
}

fn hasTopLevelWhitespace(text: []const u8) bool {
    var depth: i32 = 0;
    var in_string: u8 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (c == in_string) in_string = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            continue;
        }
        if (c == '(') {
            depth += 1;
            continue;
        }
        if (c == ')') {
            if (depth > 0) depth -= 1;
            continue;
        }
        if (depth == 0 and (c == ' ' or c == '\t' or c == '\n' or c == '\r')) return true;
    }
    return false;
}

fn containsSassCondition(text: []const u8) bool {
    var i: usize = 0;
    while (i + 5 <= text.len) : (i += 1) {
        if (std.mem.startsWith(u8, text[i..], "sass(")) {
            if (i > 0 and isCssIfIdentChar(text[i - 1])) continue;
            return true;
        }
    }
    return false;
}

fn hasTopLevelArbitrarySubstitution(text: []const u8) bool {
    var depth: i32 = 0;
    var in_string: u8 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < text.len) {
                i += 2;
                continue;
            }
            if (c == in_string) in_string = 0;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            i += 1;
            continue;
        }
        if (c == '(') {
            depth += 1;
            i += 1;
            continue;
        }
        if (c == ')') {
            if (depth > 0) depth -= 1;
            i += 1;
            continue;
        }
        if (depth != 0) {
            i += 1;
            continue;
        }

        if (std.ascii.isAlphabetic(c)) {
            const start_idx = i;
            i += 1;
            while (i < text.len and isCssIfIdentChar(text[i])) : (i += 1) {}
            const name = text[start_idx..i];
            var j = i;
            while (j < text.len and (text[j] == ' ' or text[j] == '\t' or text[j] == '\n' or text[j] == '\r')) {
                j += 1;
            }
            if (j < text.len and text[j] == '(') {
                if (std.ascii.eqlIgnoreCase(name, "var") or
                    std.ascii.eqlIgnoreCase(name, "attr") or
                    std.ascii.eqlIgnoreCase(name, "if"))
                {
                    return true;
                }
            }
            continue;
        }
        i += 1;
    }
    return false;
}

fn validateCssIfCondition(alloc: std.mem.Allocator, text: []const u8) ResolveError!bool {
    if (containsSassCondition(text) and hasTopLevelArbitrarySubstitution(text)) {
        return false;
    }

    var tokens = (try tokenizeCssIfCondition(alloc, text)) orelse return false;
    defer tokens.deinit(alloc);
    if (tokens.items.len == 0) return false;

    if (tokens.items.len == 1) {
        if (tokens.items[0].kind != .clause) return false;
        return try validateCssIfClauseText(alloc, tokens.items[0].text);
    }

    if (tokens.items[0].kind == .op_not) {
        if (tokens.items.len != 2 or tokens.items[1].kind != .clause) return false;
        if (!(try validateCssIfClauseText(alloc, tokens.items[1].text))) return false;
        return !hasTopLevelWhitespace(tokens.items[1].text);
    }

    if (tokens.items[0].kind != .clause) return false;
    var expected_op: ?CssIfTokenKind = null;
    var idx: usize = 0;
    while (idx < tokens.items.len) : (idx += 1) {
        const tok = tokens.items[idx];
        if ((idx & 1) == 0) {
            if (tok.kind != .clause) return false;
            if (!(try validateCssIfClauseText(alloc, tok.text))) return false;
        } else {
            if (tok.kind != .op_and and tok.kind != .op_or) return false;
            if (expected_op == null) {
                expected_op = tok.kind;
            } else if (expected_op.? != tok.kind) {
                return false;
            }
        }
    }
    return true;
}

fn validateCssIfArguments(alloc: std.mem.Allocator, args: []const u8) ResolveError!bool {
    var trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (trimmed[trimmed.len - 1] == ',') {
        trimmed = std.mem.trim(u8, trimmed[0 .. trimmed.len - 1], " \t\r\n");
        if (trimmed.len == 0) return false;
    }

    var trailing_semis: usize = 0;
    var end_idx = trimmed.len;
    while (end_idx > 0) {
        const c = trimmed[end_idx - 1];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            end_idx -= 1;
            continue;
        }
        if (c == ';') {
            trailing_semis += 1;
            end_idx -= 1;
            continue;
        }
        break;
    }
    if (trailing_semis > 1) return false;
    if (trailing_semis == 1) {
        trimmed = std.mem.trim(u8, trimmed[0..end_idx], " \t\r\n");
        if (trimmed.len == 0) return false;
    }

    var depth: i32 = 0;
    var in_string: u8 = 0;
    var start_idx: usize = 0;
    var saw_empty = false;
    var saw_else = false;
    var saw_clause = false;
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        const c = trimmed[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < trimmed.len) {
                i += 1;
                continue;
            }
            if (c == in_string) in_string = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            continue;
        }
        if (c == '(') {
            depth += 1;
            continue;
        }
        if (c == ')') {
            if (depth > 0) depth -= 1;
            continue;
        }
        if (depth == 0 and c == ',') return false;
        if (depth == 0 and c == ';') {
            const seg = std.mem.trim(u8, trimmed[start_idx..i], " \t\r\n");
            if (seg.len == 0) {
                saw_empty = true;
            } else {
                if (saw_empty) return false;
                const clause = parseCssIfClause(seg);
                if (clause.is_else) {
                    saw_else = true;
                } else {
                    if (saw_else) return false;
                    if (!(try validateCssIfCondition(alloc, clause.condition))) return false;
                }
                saw_clause = true;
            }
            start_idx = i + 1;
        }
    }

    const last = std.mem.trim(u8, trimmed[start_idx..], " \t\r\n");
    if (last.len == 0) {
        return !saw_empty and saw_clause;
    }
    if (saw_empty) return false;

    const clause = parseCssIfClause(last);
    if (clause.is_else) {
        // trailing `else:` in css-if allows duplicates,
        // The first `else` that is reached is adopted and subsequent ones are ignored.
        return true;
    }
    if (saw_else) return false;
    return try validateCssIfCondition(alloc, clause.condition);
}

fn findMatchingParenSimple(text: []const u8, open_idx: usize) ?usize {
    if (open_idx >= text.len or text[open_idx] != '(') return null;
    var depth: i32 = 0;
    var in_string: u8 = 0;
    var i = open_idx;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (c == in_string) in_string = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            continue;
        }
        if (c == '\\' and i + 1 < text.len) {
            i += 1;
            continue;
        }
        if (c == '(') depth += 1;
        if (c == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn calcTextHasTopLevelComma(text: []const u8) bool {
    var depth: i32 = 0;
    var in_string: u8 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (c == in_string) in_string = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            continue;
        }
        if (c == '(') {
            depth += 1;
            continue;
        }
        if (c == ')' and depth > 0) {
            depth -= 1;
            continue;
        }
        if (c == ',' and depth == 0) return true;
    }
    return false;
}

fn previousNonWhitespaceByte(text: []const u8, index: usize) ?u8 {
    if (index == 0) return null;
    var i = index;
    while (i > 0) {
        i -= 1;
        if (!std.ascii.isWhitespace(text[i])) return text[i];
    }
    return null;
}

fn calcHasModuloOperatorResolver(expr: []const u8) bool {
    var depth: i32 = 0;
    var in_string: u8 = 0;
    var i: usize = 0;
    while (i < expr.len) : (i += 1) {
        const c = expr[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < expr.len) {
                i += 1;
                continue;
            }
            if (c == in_string) in_string = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            continue;
        }
        if (c == '(') {
            depth += 1;
            continue;
        }
        if (c == ')' and depth > 0) {
            depth -= 1;
            continue;
        }
        if (depth != 0 or c != '%') continue;
        if (i > 0 and !std.ascii.isWhitespace(expr[i - 1])) continue;

        const prev = previousNonWhitespaceByte(expr, i) orelse continue;
        var j = i + 1;
        while (j < expr.len and std.ascii.isWhitespace(expr[j])) : (j += 1) {}
        if (j >= expr.len) continue;
        const next = expr[j];
        const prev_is_operand = std.ascii.isDigit(prev) or prev == ')' or isIdentifierChar(prev);
        const next_is_operand = std.ascii.isDigit(next) or next == '$' or next == '(' or next == '.' or next == '-' or isIdentifierChar(next);
        if (prev_is_operand and next_is_operand) return true;
    }
    return false;
}

fn validateRawCalcCallSyntax(_: *Ctx, raw_text: []const u8) ResolveError!void {
    const trimmed = std.mem.trim(u8, raw_text, " \t\r\n");
    if (trimmed.len == 0 or trimmed[trimmed.len - 1] != ')') return;
    const lparen = std.mem.findScalar(u8, trimmed, '(') orelse return;
    const rparen = findMatchingParenSimple(trimmed, lparen) orelse return;
    if (rparen + 1 != trimmed.len) return;

    const raw_name = std.mem.trim(u8, trimmed[0..lparen], " \t\r\n");
    if (!identifierEq(raw_name, "calc")) return;

    const inner = trimmed[lparen + 1 .. rparen];
    if (std.mem.trim(u8, inner, " \t\r\n").len == 0) return error.SassError;
    if (calcTextHasTopLevelComma(inner)) return error.SassError;
    if (calc_utils.calcHasBadWhitespace(inner)) return error.SassError;
    if (calc_utils.calcHasKnownIncompatibleUnits(inner)) return error.SassError;
    if (calcHasModuloOperatorResolver(inner)) return error.SassError;

    // Expressions containing variables/interpolation are evaluated on the runtime side.
    if (std.mem.findScalar(u8, inner, '$') != null or std.mem.indexOf(u8, inner, "#{") != null) return;
}

fn resolveCssSpecialCallExprFromSourceText(ctx: *Ctx, raw_text: []const u8, span: Span) ResolveError!?ExprIndex {
    const trimmed = std.mem.trim(u8, raw_text, " \t\r\n");
    if (trimmed.len == 0 or trimmed[trimmed.len - 1] != ')') return null;

    const lparen = std.mem.findScalar(u8, trimmed, '(') orelse return null;
    const rparen = findMatchingParenSimple(trimmed, lparen) orelse return null;
    if (rparen + 1 != trimmed.len) return null;

    const raw_name = std.mem.trim(u8, trimmed[0..lparen], " \t\r\n");
    const inner = trimmed[lparen + 1 .. rparen];
    const base = cssSpecialBaseName(raw_name) orelse return null;
    const has_bare_var = std.mem.findScalar(u8, inner, '$') != null;
    const has_interpolation_marker = std.mem.indexOf(u8, inner, "#{") != null;
    const has_interpolation = if (cssIdentEquals(base, "calc"))
        textHasRealInterpolationOutsideSkips(inner)
    else
        has_interpolation_marker;
    const normalized_inner = if (cssIdentEquals(base, "url"))
        std.mem.trim(u8, inner, " \t\r\n")
    else
        inner;
    const needs_inner_normalization = normalized_inner.len != inner.len;
    const url_eval_mode: enum { none, basic, structured } = if (cssIdentEquals(base, "url")) blk: {
        if ((has_bare_var and !has_interpolation_marker) or css_utils.urlContentNeedsEval(normalized_inner, .structured)) {
            break :blk .structured;
        }
        if (has_bare_var or css_utils.urlContentNeedsEval(inner, .basic)) {
            break :blk .basic;
        }
        break :blk .none;
    } else .none;

    const preserve_vendor_url_name = cssIdentEquals(base, "url") and has_bare_var and hasVendorPrefixedFunctionName(raw_name);
    const canonical_name = if (preserve_vendor_url_name)
        try ctx.a.dupe(u8, raw_name)
    else
        try canonicalizeCssSpecialFunctionName(ctx.a, raw_name);
    defer ctx.a.free(canonical_name);

    if (std.mem.eql(u8, canonical_name, raw_name) and !has_interpolation and url_eval_mode == .none and !needs_inner_normalization) {
        return null;
    }

    if (url_eval_mode == .structured) {
        const inner_expr = parseSubExpr(ctx, normalized_inner, span) catch |err| blk: {
            if (cssIdentEquals(base, "url")) switch (err) {
                error.UnknownVar => return error.UnknownVar,
                else => {},
            };
            const normalized_text = try std.fmt.allocPrint(ctx.a, "{s}({s})", .{ canonical_name, normalized_inner });
            defer ctx.a.free(normalized_text);
            break :blk try resolveInterpolatedTextExpr(ctx, normalized_text, span, true);
        };
        const name_id = try ctx.pool.intern(canonical_name);
        const args = [_]ExprIndex{inner_expr};
        const arg_names = [_]InternId{.none};
        const astart = try appendCallArgsWithNames(ctx.prog, ctx.a, &args, &arg_names);
        const cidx: u32 = @intCast(ctx.prog.call_exprs.items.len);
        try ctx.prog.call_exprs.append(ctx.a, .{
            .callee_module = 0,
            .callee_id = 0,
            .callee_name = name_id,
            .callee_is_css = true,
            .arg_start = astart,
            .arg_count = 1,
        });
        return try appendExpr(ctx.prog, ctx.a, .{
            .kind = .call,
            .payload = cidx,
            .span = span,
        });
    }

    if (url_eval_mode == .basic) {
        const normalized_text = try std.fmt.allocPrint(ctx.a, "{s}({s})", .{ canonical_name, normalized_inner });
        defer ctx.a.free(normalized_text);
        return try resolveInterpolatedTextExpr(ctx, normalized_text, span, true);
    }

    if (!has_interpolation) {
        const text_out = try std.fmt.allocPrint(ctx.a, "{s}({s})", .{ canonical_name, normalized_inner });
        defer ctx.a.free(text_out);
        const id = if (ctx.calc_arg_mode) try markCalcArgText(ctx, text_out) else try ctx.pool.intern(text_out);
        return try appendExpr(ctx.prog, ctx.a, .{
            .kind = .literal_string,
            .payload = packLiteralStringPayload(id, false, false),
            .span = span,
        });
    }

    var parts: std.ArrayListUnmanaged(ExprIndex) = .empty;
    defer parts.deinit(ctx.a);
    if (cssIdentEquals(base, "calc")) {
        try appendLiteralExprPart(ctx, &parts, calc_interp_marker, span);
    }
    try appendLiteralExprPart(ctx, &parts, canonical_name, span);
    try appendLiteralExprPart(ctx, &parts, "(", span);
    if (cssIdentEquals(base, "calc")) {
        const calc_inner = unwrapInterpolatedNestedCalcText(unwrapInterpolatedCalcOuterParensText(normalized_inner));
        try appendCalcInterpolationParts(ctx, calc_inner, span, &parts);
    } else try appendTextExprParts(ctx, &parts, normalized_inner, span, false);
    try appendLiteralExprPart(ctx, &parts, ")", span);
    return try finishConcatExprParts(ctx, parts.items, span);
}

const CssEqArgRange = struct {
    start: usize,
    end: usize,
};

fn splitTopLevelCommaEqArgRanges(
    allocator: std.mem.Allocator,
    inner: []const u8,
) ResolveError!std.ArrayListUnmanaged(CssEqArgRange) {
    var out: std.ArrayListUnmanaged(CssEqArgRange) = .empty;
    errdefer out.deinit(allocator);

    var seg_start: usize = 0;
    var depth_paren: u32 = 0;
    var depth_bracket: u32 = 0;
    var in_string: u8 = 0;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        const c = inner[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < inner.len) {
                i += 1;
                continue;
            }
            if (c == in_string) in_string = 0;
            continue;
        }
        switch (c) {
            '"', '\'' => in_string = c,
            '(' => depth_paren += 1,
            ')' => {
                if (depth_paren > 0) depth_paren -= 1;
            },
            '[' => depth_bracket += 1,
            ']' => {
                if (depth_bracket > 0) depth_bracket -= 1;
            },
            ',' => if (depth_paren == 0 and depth_bracket == 0) {
                try out.append(allocator, .{ .start = seg_start, .end = i });
                seg_start = i + 1;
            },
            else => {},
        }
    }
    try out.append(allocator, .{ .start = seg_start, .end = inner.len });
    return out;
}

fn detectCssEqArgPos(seg: []const u8) ?usize {
    var depth_paren: u32 = 0;
    var depth_bracket: u32 = 0;
    var in_string: u8 = 0;
    var i: usize = 0;
    while (i < seg.len) : (i += 1) {
        const c = seg[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < seg.len) {
                i += 1;
                continue;
            }
            if (c == in_string) in_string = 0;
            continue;
        }
        switch (c) {
            '"', '\'' => in_string = c,
            '(' => depth_paren += 1,
            ')' => {
                if (depth_paren > 0) depth_paren -= 1;
            },
            '[' => depth_bracket += 1,
            ']' => {
                if (depth_bracket > 0) depth_bracket -= 1;
            },
            '=' => if (depth_paren == 0 and depth_bracket == 0) {
                if ((i > 0 and seg[i - 1] == '=') or (i + 1 < seg.len and seg[i + 1] == '=')) continue;
                return i;
            },
            else => {},
        }
    }
    return null;
}

fn isCssEqArgName(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    }
    return true;
}

fn cssEqArgNeedsEvaluation(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '$') != null or std.mem.indexOf(u8, trimmed, "#{") != null) return true;
    if (css_utils.containsArithmeticOp(trimmed)) return true;
    return trimmed.len >= 2 and trimmed[0] == '.' and std.ascii.isDigit(trimmed[1]);
}

fn resolveCssEqArgFunctionExprFromSourceText(ctx: *Ctx, raw_text: []const u8, span: Span) ResolveError!?ExprIndex {
    const trimmed = std.mem.trim(u8, raw_text, " \t\r\n");
    if (trimmed.len == 0 or trimmed[trimmed.len - 1] != ')') return null;

    const lparen = std.mem.findScalar(u8, trimmed, '(') orelse return null;
    const rparen = findMatchingParenSimple(trimmed, lparen) orelse return null;
    if (rparen + 1 != trimmed.len) return null;

    const raw_name = std.mem.trim(u8, trimmed[0..lparen], " \t\r\n");
    if (raw_name.len == 0 or cssSpecialBaseName(raw_name) != null) return null;

    const inner = trimmed[lparen + 1 .. rparen];
    var ranges = try splitTopLevelCommaEqArgRanges(ctx.a, inner);
    defer ranges.deinit(ctx.a);
    if (ranges.items.len == 0) return null;

    var any_eval = false;
    for (ranges.items) |range| {
        const seg = inner[range.start..range.end];
        const eq_pos = detectCssEqArgPos(seg) orelse return null;
        const lhs = std.mem.trim(u8, seg[0..eq_pos], " \t\r\n");
        const rhs = std.mem.trim(u8, seg[eq_pos + 1 ..], " \t\r\n");
        if (!isCssEqArgName(lhs) or rhs.len == 0) return null;
        if (cssEqArgNeedsEvaluation(rhs)) any_eval = true;
    }
    if (!any_eval) return null;

    var parts: std.ArrayListUnmanaged(ExprIndex) = .empty;
    defer parts.deinit(ctx.a);
    try parts.ensureTotalCapacity(ctx.a, 3 + 4 * ranges.items.len);
    try appendLiteralExprPart(ctx, &parts, raw_name, span);
    try appendLiteralExprPart(ctx, &parts, "(", span);

    for (ranges.items, 0..) |range, idx| {
        if (idx != 0) try appendLiteralExprPart(ctx, &parts, ", ", span);
        const seg = inner[range.start..range.end];
        const eq_pos = detectCssEqArgPos(seg).?;
        const lhs = std.mem.trim(u8, seg[0..eq_pos], " \t\r\n");
        const rhs = std.mem.trim(u8, seg[eq_pos + 1 ..], " \t\r\n");
        try appendLiteralExprPart(ctx, &parts, lhs, span);
        try appendLiteralExprPart(ctx, &parts, "=", span);

        const rhs_expr = parseSubExpr(ctx, rhs, span) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => try resolveInterpolatedTextExpr(ctx, rhs, span, true),
        };
        parts.appendAssumeCapacity(rhs_expr);
    }

    try appendLiteralExprPart(ctx, &parts, ")", span);
    return try finishConcatExprParts(ctx, parts.items, span);
}

fn normalizeCssIfText(alloc: std.mem.Allocator, text: []const u8) ResolveError![]u8 {
    var collapsed: std.ArrayListUnmanaged(u8) = .empty;
    defer collapsed.deinit(alloc);
    var in_string: u8 = 0;
    var last_space = false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string != 0) {
            try collapsed.append(alloc, c);
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                try collapsed.append(alloc, text[i]);
                continue;
            }
            if (c == in_string) in_string = 0;
            last_space = false;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            try collapsed.append(alloc, c);
            last_space = false;
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            if (!last_space) try collapsed.append(alloc, ' ');
            last_space = true;
            continue;
        }
        try collapsed.append(alloc, c);
        last_space = false;
    }

    const collapsed_slice = std.mem.trim(u8, collapsed.items, " ");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    var j: usize = 0;
    while (j < collapsed_slice.len) : (j += 1) {
        const c = collapsed_slice[j];
        if (c == ' ') {
            if (out.items.len == 0) continue;
            if (j + 1 < collapsed_slice.len) {
                const next = collapsed_slice[j + 1];
                if (next == ')' or next == ':' or next == ';' or next == ',' or next == '(') continue;
            }
            const prev = out.items[out.items.len - 1];
            if (prev == '(') continue;
        }
        try out.append(alloc, c);
    }
    return out.toOwnedSlice(alloc);
}

fn appendCssIfInterpolationValue(
    ctx: *Ctx,
    out: *std.ArrayListUnmanaged(u8),
    inner: []const u8,
    span: Span,
) ResolveError!bool {
    const trimmed = std.mem.trim(u8, inner, " \t\r\n");
    if (trimmed.len == 0) return false;

    const expr_idx = parseSubExpr(ctx, trimmed, span) catch return false;
    const value = tryStaticEvalValue(ctx, expr_idx) orelse return false;
    var env: ResolverEvalEnv = .{ .ctx = ctx };
    const text_out = resolver_eval.valueToInterpolationTextOwned(&env, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer ctx.a.free(text_out);
    try out.appendSlice(ctx.a, text_out);
    return true;
}

fn simplifyCssIfInterpolations(ctx: *Ctx, text: []const u8, span: Span) ResolveError![]u8 {
    if (std.mem.indexOf(u8, text, "#{") == null) return try ctx.a.dupe(u8, text);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(ctx.a);
    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == '#' and text[i + 1] == '{' and !interpolationStartEscaped(text, i)) {
            const inner_start = i + 2;
            const inner_end = findInterpExprEnd(text, inner_start) orelse return error.SassError;
            const inner = text[inner_start..inner_end];
            if (!(try appendCssIfInterpolationValue(ctx, &out, inner, span))) {
                try out.appendSlice(ctx.a, text[i .. inner_end + 1]);
            }
            i = inner_end + 1;
            continue;
        }
        try out.append(ctx.a, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(ctx.a);
}

fn resolveCssIfConditionTextExpr(ctx: *Ctx, text: []const u8, span: Span) ResolveError!ExprIndex {
    const simplified = try simplifyCssIfInterpolations(ctx, text, span);
    defer ctx.a.free(simplified);

    if (std.mem.indexOf(u8, simplified, "#{") != null or std.mem.indexOfScalar(u8, simplified, '$') != null) {
        return try resolveInterpolatedTextExpr(ctx, simplified, span, true);
    }

    const normalized = try normalizeCssIfText(ctx.a, simplified);
    defer ctx.a.free(normalized);
    const id = try ctx.pool.intern(normalized);
    return try appendStringLiteralExpr(ctx.prog, ctx.a, id, span);
}

fn maybeUnwrapLogicalCssUnknownText(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len >= 2 and trimmed[0] == '(' and trimmed[trimmed.len - 1] == ')') {
        var depth: i32 = 0;
        var matches_whole = true;
        for (trimmed, 0..) |c, idx| {
            if (c == '(') depth += 1;
            if (c == ')') depth -= 1;
            if (depth == 0 and idx < trimmed.len - 1) {
                matches_whole = false;
                break;
            }
        }
        if (matches_whole) {
            return std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
        }
    }
    return trimmed;
}

fn maybeUnwrapLogicalCssUnknownExpr(ctx: *Ctx, expr: ExprIndex, span: Span) ResolveError!ExprIndex {
    const folded_id = (try tryFoldLiteralStringExpr(ctx, expr)) orelse return expr;
    const raw = ctx.pool.get(folded_id);
    const unwrapped = maybeUnwrapLogicalCssUnknownText(raw);
    if (std.mem.eql(u8, raw, unwrapped)) return expr;
    const id = try ctx.pool.intern(unwrapped);
    return try appendStringLiteralExpr(ctx.prog, ctx.a, id, span);
}

fn evalCssIfAtomSymbolic(ctx: *Ctx, text: []const u8, span: Span) ResolveError!?CssIfCondEval {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return .sass_false;

    if (trimmed[0] == '(' and findMatchingParenSimple(trimmed, 0) == trimmed.len - 1) {
        const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
        const inner_eval = (try evalCssIfConditionSymbolic(ctx, inner, span)) orelse return null;
        return switch (inner_eval) {
            .css_unknown => |expr_idx| .{ .css_unknown = try appendWrappedTextExpr(ctx, "(", expr_idx, ")", span) },
            else => inner_eval,
        };
    }

    if (std.ascii.startsWithIgnoreCase(trimmed, "sass(") and trimmed[trimmed.len - 1] == ')') {
        const end_idx = findMatchingParenSimple(trimmed, 4) orelse return null;
        if (end_idx == trimmed.len - 1) {
            const inner = std.mem.trim(u8, trimmed[5..end_idx], " \t\r\n");
            const expr_idx = parseSubExpr(ctx, inner, span) catch return null;
            if (literalBoolValue(ctx, expr_idx)) |cond| {
                return if (cond) .sass_true else .sass_false;
            }
            return .{ .sass_expr = expr_idx };
        }
    }

    return .{ .css_unknown = try resolveCssIfConditionTextExpr(ctx, trimmed, span) };
}

fn cssCondNot(ctx: *Ctx, evaled: CssIfCondEval, span: Span) ResolveError!CssIfCondEval {
    return switch (evaled) {
        .sass_true => .sass_false,
        .sass_false => .sass_true,
        .css_unknown => |expr_idx| .{ .css_unknown = try appendWrappedTextExpr(ctx, "not ", expr_idx, "", span) },
        .sass_expr => |expr_idx| .{ .sass_expr = try appendUnaryResolvedExpr(ctx, expr_idx, .not_op, span) },
    };
}

fn cssCondAnd(ctx: *Ctx, lhs: CssIfCondEval, rhs_text: []const u8, span: Span) ResolveError!?CssIfCondEval {
    switch (lhs) {
        .sass_false => return .sass_false,
        .sass_true => {
            const rhs = (try evalCssIfAtomSymbolic(ctx, rhs_text, span)) orelse return null;
            return switch (rhs) {
                .css_unknown => |expr_idx| .{ .css_unknown = try maybeUnwrapLogicalCssUnknownExpr(ctx, expr_idx, span) },
                else => rhs,
            };
        },
        .css_unknown => |lhs_expr| {
            const rhs = (try evalCssIfAtomSymbolic(ctx, rhs_text, span)) orelse return null;
            return switch (rhs) {
                .sass_false => .sass_false,
                .sass_true => .{ .css_unknown = try maybeUnwrapLogicalCssUnknownExpr(ctx, lhs_expr, span) },
                .css_unknown => |rhs_expr| .{ .css_unknown = try appendJoinedTextExpr(ctx, lhs_expr, " and ", rhs_expr, span) },
                .sass_expr => null,
            };
        },
        .sass_expr => |lhs_expr| {
            const rhs = (try evalCssIfAtomSymbolic(ctx, rhs_text, span)) orelse return null;
            return switch (rhs) {
                .sass_false => .sass_false,
                .sass_true => .{ .sass_expr = lhs_expr },
                .sass_expr => |rhs_expr| .{ .sass_expr = try appendBinaryResolvedExpr(ctx, lhs_expr, rhs_expr, .and_op, span) },
                .css_unknown => null,
            };
        },
    }
}

fn cssCondOr(ctx: *Ctx, lhs: CssIfCondEval, rhs_text: []const u8, span: Span) ResolveError!?CssIfCondEval {
    switch (lhs) {
        .sass_true => return .sass_true,
        .sass_false => {
            const rhs = (try evalCssIfAtomSymbolic(ctx, rhs_text, span)) orelse return null;
            return switch (rhs) {
                .css_unknown => |expr_idx| .{ .css_unknown = try maybeUnwrapLogicalCssUnknownExpr(ctx, expr_idx, span) },
                else => rhs,
            };
        },
        .css_unknown => |lhs_expr| {
            const rhs = (try evalCssIfAtomSymbolic(ctx, rhs_text, span)) orelse return null;
            return switch (rhs) {
                .sass_true => .sass_true,
                .sass_false => .{ .css_unknown = try maybeUnwrapLogicalCssUnknownExpr(ctx, lhs_expr, span) },
                .css_unknown => |rhs_expr| .{ .css_unknown = try appendJoinedTextExpr(ctx, lhs_expr, " or ", rhs_expr, span) },
                .sass_expr => null,
            };
        },
        .sass_expr => |lhs_expr| {
            const rhs = (try evalCssIfAtomSymbolic(ctx, rhs_text, span)) orelse return null;
            return switch (rhs) {
                .sass_true => .sass_true,
                .sass_false => .{ .sass_expr = lhs_expr },
                .sass_expr => |rhs_expr| .{ .sass_expr = try appendBinaryResolvedExpr(ctx, lhs_expr, rhs_expr, .or_op, span) },
                .css_unknown => null,
            };
        },
    }
}

fn evalCssIfConditionSymbolic(ctx: *Ctx, condition: []const u8, span: Span) ResolveError!?CssIfCondEval {
    var tokens = (try tokenizeCssIfCondition(ctx.a, condition)) orelse return null;
    defer tokens.deinit(ctx.a);
    if (tokens.items.len == 0) return null;

    if (tokens.items.len == 1) {
        if (tokens.items[0].kind != .clause) return null;
        return try evalCssIfAtomSymbolic(ctx, tokens.items[0].text, span);
    }

    if (tokens.items[0].kind == .op_not) {
        if (tokens.items.len != 2 or tokens.items[1].kind != .clause) return null;
        const inner = (try evalCssIfAtomSymbolic(ctx, tokens.items[1].text, span)) orelse return null;
        return try cssCondNot(ctx, inner, span);
    }

    if (tokens.items[0].kind != .clause) return null;
    var result = (try evalCssIfAtomSymbolic(ctx, tokens.items[0].text, span)) orelse return null;
    var expected_op: ?CssIfTokenKind = null;
    var idx: usize = 1;
    while (idx < tokens.items.len) : (idx += 2) {
        if (idx + 1 >= tokens.items.len) return null;
        const op = tokens.items[idx];
        if (op.kind != .op_and and op.kind != .op_or) return null;
        if (expected_op == null) {
            expected_op = op.kind;
        } else if (expected_op.? != op.kind) {
            return null;
        }
        if (tokens.items[idx + 1].kind != .clause) return null;
        result = switch (op.kind) {
            .op_and => (try cssCondAnd(ctx, result, tokens.items[idx + 1].text, span)) orelse return null,
            .op_or => (try cssCondOr(ctx, result, tokens.items[idx + 1].text, span)) orelse return null,
            else => unreachable,
        };
    }
    return result;
}

fn splitCssIfClauses(alloc: std.mem.Allocator, args: []const u8) ResolveError!std.ArrayListUnmanaged(CssIfClause) {
    var out: std.ArrayListUnmanaged(CssIfClause) = .empty;
    errdefer out.deinit(alloc);

    var trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == ',') {
        trimmed = std.mem.trim(u8, trimmed[0 .. trimmed.len - 1], " \t\r\n");
    }
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == ';') {
        trimmed = std.mem.trim(u8, trimmed[0 .. trimmed.len - 1], " \t\r\n");
    }

    var start_idx: usize = 0;
    var depth: i32 = 0;
    var in_string: u8 = 0;
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        const c = trimmed[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < trimmed.len) {
                i += 1;
                continue;
            }
            if (c == in_string) in_string = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            continue;
        }
        if (c == '(') {
            depth += 1;
            continue;
        }
        if (c == ')') {
            if (depth > 0) depth -= 1;
            continue;
        }
        if (depth == 0 and c == ';') {
            const seg = std.mem.trim(u8, trimmed[start_idx..i], " \t\r\n");
            if (seg.len != 0) try out.append(alloc, parseCssIfClause(seg));
            start_idx = i + 1;
        }
    }
    const last = std.mem.trim(u8, trimmed[start_idx..], " \t\r\n");
    if (last.len != 0) try out.append(alloc, parseCssIfClause(last));
    return out;
}

fn resolveCssIfValueExpr(ctx: *Ctx, text: []const u8, span: Span) ResolveError!ExprIndex {
    const simplified = try simplifyCssIfInterpolations(ctx, text, span);
    defer ctx.a.free(simplified);

    if (std.mem.indexOf(u8, simplified, "#{") != null) {
        return try resolveInterpolatedTextExpr(ctx, simplified, span, true);
    }

    const normalized = try normalizeCssIfText(ctx.a, simplified);
    defer ctx.a.free(normalized);
    if (normalized.len == 0) {
        return try appendNullLiteralExpr(ctx, span);
    }
    return parseSubExpr(ctx, normalized, span) catch resolveInterpolatedTextExpr(ctx, normalized, span, true);
}

fn appendIfBuiltinExpr(ctx: *Ctx, cond: ExprIndex, if_true: ExprIndex, if_false: ExprIndex, span: Span) ResolveError!ExprIndex {
    const astart: u32 = @intCast(ctx.prog.call_args.items.len);
    try ctx.prog.call_args.append(ctx.a, cond);
    try ctx.prog.call_args.append(ctx.a, if_true);
    try ctx.prog.call_args.append(ctx.a, if_false);
    try ctx.prog.call_arg_names.append(ctx.a, .none);
    try ctx.prog.call_arg_names.append(ctx.a, .none);
    try ctx.prog.call_arg_names.append(ctx.a, .none);

    const cidx: u32 = @intCast(ctx.prog.call_exprs.items.len);
    try ctx.prog.call_exprs.append(ctx.a, .{
        .callee_module = 0,
        .callee_id = std.math.maxInt(u32),
        .arg_start = astart,
        .arg_count = 3,
    });
    return try appendExpr(ctx.prog, ctx.a, .{ .kind = .if_builtin, .payload = cidx, .span = span });
}

fn resolveLegacyIfBuiltinExpr(
    ctx: *Ctx,
    args: []const ExprIndex,
    arg_names: []const InternId,
    span: Span,
) ResolveError!ExprIndex {
    if (args.len != arg_names.len) return error.SassError;

    var condition_expr: ?ExprIndex = null;
    var if_true_expr: ?ExprIndex = null;
    var if_false_expr: ?ExprIndex = null;
    var positional_index: usize = 0;

    const appendPositional = struct {
        fn append(
            condition_expr_ptr: *?ExprIndex,
            if_true_expr_ptr: *?ExprIndex,
            if_false_expr_ptr: *?ExprIndex,
            positional_index_ptr: *usize,
            expr: ExprIndex,
        ) ResolveError!void {
            switch (positional_index_ptr.*) {
                0 => {
                    if (condition_expr_ptr.* != null) return error.SassError;
                    condition_expr_ptr.* = expr;
                },
                1 => {
                    if (if_true_expr_ptr.* != null) return error.SassError;
                    if_true_expr_ptr.* = expr;
                },
                2 => {
                    if (if_false_expr_ptr.* != null) return error.SassError;
                    if_false_expr_ptr.* = expr;
                },
                else => return error.SassError,
            }
            positional_index_ptr.* += 1;
        }
    }.append;

    for (args, 0..) |expr, i| {
        const arg_name = arg_names[i];

        if (arg_name == call_arg_splat_sentinel) {
            const ex = ctx.prog.exprs.items[expr];
            if (ex.kind == .list) {
                const list = ctx.prog.list_exprs.items[ex.payload];
                if (!list.is_map) {
                    var elem_i: u32 = 0;
                    while (elem_i < list.elem_count) : (elem_i += 1) {
                        try appendPositional(
                            &condition_expr,
                            &if_true_expr,
                            &if_false_expr,
                            &positional_index,
                            ctx.prog.list_elems.items[list.elem_start + elem_i],
                        );
                    }
                    continue;
                }
            }
            try appendPositional(
                &condition_expr,
                &if_true_expr,
                &if_false_expr,
                &positional_index,
                expr,
            );
            continue;
        }

        if (arg_name == .none) {
            try appendPositional(
                &condition_expr,
                &if_true_expr,
                &if_false_expr,
                &positional_index,
                expr,
            );
            continue;
        }

        if (argNameEq(ctx, arg_name, "condition")) {
            if (condition_expr != null) return error.SassError;
            condition_expr = expr;
            continue;
        }
        if (argNameEq(ctx, arg_name, "if-true")) {
            if (if_true_expr != null) return error.SassError;
            if_true_expr = expr;
            continue;
        }
        if (argNameEq(ctx, arg_name, "if-false")) {
            if (if_false_expr != null) return error.SassError;
            if_false_expr = expr;
            continue;
        }
        return error.SassError;
    }

    if (condition_expr == null or if_true_expr == null) return error.SassError;

    const else_expr = if (if_false_expr) |v|
        v
    else
        try appendNullLiteralExpr(ctx, span);

    return appendIfBuiltinExpr(ctx, condition_expr.?, if_true_expr.?, else_expr, span);
}

fn appendNullLiteralExpr(ctx: *Ctx, span: Span) ResolveError!ExprIndex {
    return try appendExpr(ctx.prog, ctx.a, .{ .kind = .literal_null, .payload = 0, .span = span });
}

fn appendBinaryResolvedExpr(ctx: *Ctx, lhs: ExprIndex, rhs: ExprIndex, op: BinOp, span: Span) ResolveError!ExprIndex {
    const bidx: u32 = @intCast(ctx.prog.binary_exprs.items.len);
    try ctx.prog.binary_exprs.append(ctx.a, .{ .lhs = lhs, .rhs = rhs, .op = op });
    return try appendExpr(ctx.prog, ctx.a, .{ .kind = .binary, .payload = bidx, .span = span });
}

fn appendUnaryResolvedExpr(ctx: *Ctx, operand: ExprIndex, op: UnaryOp, span: Span) ResolveError!ExprIndex {
    const uidx: u32 = @intCast(ctx.prog.unary_exprs.items.len);
    try ctx.prog.unary_exprs.append(ctx.a, .{ .operand = operand, .op = op });
    return try appendExpr(ctx.prog, ctx.a, .{ .kind = .unary, .payload = uidx, .span = span });
}

fn appendWrappedTextExpr(
    ctx: *Ctx,
    prefix: []const u8,
    inner: ExprIndex,
    suffix: []const u8,
    span: Span,
) ResolveError!ExprIndex {
    var parts: std.ArrayListUnmanaged(ExprIndex) = .empty;
    defer parts.deinit(ctx.a);
    try appendLiteralExprPart(ctx, &parts, prefix, span);
    try parts.append(ctx.a, inner);
    try appendLiteralExprPart(ctx, &parts, suffix, span);
    return finishConcatExprParts(ctx, parts.items, span);
}

fn appendJoinedTextExpr(
    ctx: *Ctx,
    lhs: ExprIndex,
    sep: []const u8,
    rhs: ExprIndex,
    span: Span,
) ResolveError!ExprIndex {
    var parts: std.ArrayListUnmanaged(ExprIndex) = .empty;
    defer parts.deinit(ctx.a);
    try parts.append(ctx.a, lhs);
    try appendLiteralExprPart(ctx, &parts, sep, span);
    try parts.append(ctx.a, rhs);
    return finishConcatExprParts(ctx, parts.items, span);
}

fn appendCssIfRenderedExpr(
    ctx: *Ctx,
    cond_text: ExprIndex,
    if_true: ExprIndex,
    if_false: ?ExprIndex,
    span: Span,
) ResolveError!ExprIndex {
    var parts: std.ArrayListUnmanaged(ExprIndex) = .empty;
    defer parts.deinit(ctx.a);
    try appendLiteralExprPart(ctx, &parts, "if(", span);
    try parts.append(ctx.a, cond_text);
    try appendLiteralExprPart(ctx, &parts, ": ", span);
    try parts.append(ctx.a, if_true);
    if (if_false) |else_expr| {
        try appendLiteralExprPart(ctx, &parts, "; else: ", span);
        try parts.append(ctx.a, else_expr);
    }
    try appendLiteralExprPart(ctx, &parts, ")", span);
    return finishConcatExprParts(ctx, parts.items, span);
}

const ResolvedCssIfClause = struct {
    cond: CssIfCondEval,
    value_expr: ExprIndex,
};

fn lowerResolvedCssIfClauses(
    ctx: *Ctx,
    clauses: []const ResolvedCssIfClause,
    index: usize,
    else_expr: ?ExprIndex,
    span: Span,
) ResolveError!?ExprIndex {
    if (index >= clauses.len) return else_expr;

    const clause = clauses[index];
    const next_expr = try lowerResolvedCssIfClauses(ctx, clauses, index + 1, else_expr, span);
    return switch (clause.cond) {
        .sass_true => clause.value_expr,
        .sass_false => next_expr,
        .css_unknown => |cond_text| try appendCssIfRenderedExpr(ctx, cond_text, clause.value_expr, next_expr, span),
        .sass_expr => |cond_expr| blk: {
            const fallback = next_expr orelse try appendNullLiteralExpr(ctx, span);
            break :blk try appendIfBuiltinExpr(ctx, cond_expr, clause.value_expr, fallback, span);
        },
    };
}

fn resolveCssIfSyntaxExpr(ctx: *Ctx, raw_call: []const u8, span: Span) ResolveError!?ExprIndex {
    const call_text = std.mem.trim(u8, raw_call, " \t\r\n");
    const open_idx = std.mem.indexOfScalar(u8, call_text, '(') orelse return null;
    const close_idx = findMatchingParenSimple(call_text, open_idx) orelse return null;
    if (close_idx != call_text.len - 1) return null;
    const args = call_text[open_idx + 1 .. close_idx];
    if (!isCssIfSyntax(args)) return null;
    if (!(try validateCssIfArguments(ctx.a, args))) {
        // spec: malformed css-if operator / substitution layout is rejected
        // during resolve instead of flowing through the symbolic lowering.
        return error.SassError;
    }

    var clauses = try splitCssIfClauses(ctx.a, args);
    defer clauses.deinit(ctx.a);
    if (clauses.items.len == 0) return error.SassError;

    var resolved_clauses: std.ArrayListUnmanaged(ResolvedCssIfClause) = .empty;
    defer resolved_clauses.deinit(ctx.a);
    try resolved_clauses.ensureTotalCapacity(ctx.a, clauses.items.len);
    var else_expr: ?ExprIndex = null;

    // Evaluate clauses left-to-right with short-circuit.
    // - Static true picks the branch immediately when no symbolic clause precedes it.
    // - Static false skips value resolution entirely.
    // - Symbolic/css clauses are lowered and keep scanning for fallback.
    // - First reachable else wins; trailing else clauses are ignored.
    var saw_terminal_else = false;
    for (clauses.items) |clause| {
        if (saw_terminal_else) continue;

        if (clause.is_else) {
            if (else_expr == null) else_expr = try resolveCssIfValueExpr(ctx, clause.value, span);
            saw_terminal_else = true;
            continue;
        }

        const cond_eval = (try evalCssIfConditionSymbolic(ctx, clause.condition, span)) orelse {
            // spec: unresolved top-level symbolic/css operator mix is malformed.
            return error.SassError;
        };

        switch (cond_eval) {
            .sass_false => continue,
            .sass_true => {
                const value_expr = try resolveCssIfValueExpr(ctx, clause.value, span);
                if (resolved_clauses.items.len == 0) {
                    return value_expr;
                }
                else_expr = value_expr;
                saw_terminal_else = true;
            },
            .css_unknown, .sass_expr => {
                const value_expr = try resolveCssIfValueExpr(ctx, clause.value, span);
                resolved_clauses.appendAssumeCapacity(.{
                    .cond = cond_eval,
                    .value_expr = value_expr,
                });
            },
        }
    }

    if (resolved_clauses.items.len == 0) {
        return else_expr orelse try appendNullLiteralExpr(ctx, span);
    }
    const lowered = try lowerResolvedCssIfClauses(ctx, resolved_clauses.items, 0, else_expr, span);
    return lowered orelse try appendNullLiteralExpr(ctx, span);
}

fn resolveCssIfLeadingComparisonExpr(ctx: *Ctx, raw_text: []const u8, span: Span) ResolveError!?ExprIndex {
    const text = std.mem.trim(u8, raw_text, " \t\r\n");
    if (!std.ascii.startsWithIgnoreCase(text, "if(")) return null;

    const call_open_idx = std.mem.indexOfScalar(u8, text, '(') orelse return null;
    const call_close_idx = findMatchingParenSimple(text, call_open_idx) orelse return null;
    if (call_close_idx + 1 >= text.len) return null;

    const lhs_text = std.mem.trim(u8, text[0 .. call_close_idx + 1], " \t\r\n");
    const rest = std.mem.trimStart(u8, text[call_close_idx + 1 ..], " \t\r\n");

    // SAFETY: `op` is assigned in each recognized-operator branch before use.
    var op: BinOp = undefined;
    // SAFETY: `rhs_raw` is assigned together with `op`, and the non-assignment path returns null.
    var rhs_raw: []const u8 = undefined;
    if (std.mem.startsWith(u8, rest, "==")) {
        op = .eq;
        rhs_raw = rest[2..];
    } else if (std.mem.startsWith(u8, rest, "!=")) {
        op = .neq;
        rhs_raw = rest[2..];
    } else {
        return null;
    }

    const rhs_text = std.mem.trim(u8, rhs_raw, " \t\r\n");
    if (rhs_text.len == 0) return null;

    const lhs_expr = (try resolveCssIfSyntaxExpr(ctx, lhs_text, span)) orelse return null;
    const rhs_expr = parseSubExpr(ctx, rhs_text, span) catch
        (try resolveInterpolatedTextExpr(ctx, rhs_text, span, true));
    return try appendBinaryResolvedExpr(ctx, lhs_expr, rhs_expr, op, span);
}

fn parsePropertyNamespaceSelector(
    ctx: *Ctx,
    selector_text: []const u8,
    span: Span,
) ?struct { prefix: InternId, prefix_expr: ExprIndex, value_expr: ?ExprIndex } {
    const trimmed = std.mem.trim(u8, selector_text, " \t\r\n");
    if (trimmed.len == 0) return null;

    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        const c = trimmed[i];
        if (c == '#') {
            if (i + 1 >= trimmed.len or trimmed[i + 1] != '{') return null;
            continue;
        }
    }

    const colon_idx = findPropertyNamespaceColon(trimmed) orelse return null;
    if (colon_idx == 0) return null;
    if (std.mem.indexOfScalarPos(u8, trimmed, colon_idx + 1, ':') != null) return null;

    const prefix_text = std.mem.trim(u8, trimmed[0..colon_idx], " \t\r\n");
    const value_region = trimmed[colon_idx + 1 ..];
    if (prefix_text.len == 0) return null;

    if (containsOutsideInterpolation(prefix_text, "&.[]()>+~,")) return null;

    const has_interp = std.mem.indexOf(u8, prefix_text, "#{") != null;
    if (!has_interp) {
        for (prefix_text) |c| {
            if (!isIdentifierChar(c)) return null;
        }
    }

    const value_text = std.mem.trim(u8, value_region, " \t\r\n");
    if (value_text.len > 0 and (value_region.len == 0 or !std.ascii.isWhitespace(value_region[0]))) {
        return null;
    }

    const prefix_expr = if (has_interp)
        resolveInterpolatedTextExpr(ctx, prefix_text, span, false) catch return null
    else
        appendStringLiteralExpr(ctx.prog, ctx.a, ctx.pool.intern(prefix_text) catch return null, span) catch return null;

    const value_expr: ?ExprIndex = if (value_text.len == 0)
        null
    else
        parseSubExpr(ctx, value_text, span) catch return null;

    const prefix_intern: InternId = if (has_interp) .none else ctx.pool.intern(prefix_text) catch return null;
    return .{
        .prefix = prefix_intern,
        .prefix_expr = prefix_expr,
        .value_expr = value_expr,
    };
}

fn findPropertyNamespaceColon(text: []const u8) ?usize {
    var i: usize = 0;
    var interp_depth: u32 = 0;
    var in_string: ?u8 = null;
    var escaped = false;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string) |q| {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (c == q) in_string = null;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            continue;
        }
        if (c == '#' and i + 1 < text.len and text[i + 1] == '{') {
            interp_depth += 1;
            i += 1;
            continue;
        }
        if (interp_depth > 0) {
            if (c == '{') {
                interp_depth += 1;
            } else if (c == '}') {
                interp_depth -= 1;
            }
            continue;
        }
        if (c == ':') return i;
    }
    return null;
}

fn containsOutsideInterpolation(text: []const u8, needles: []const u8) bool {
    var i: usize = 0;
    var interp_depth: u32 = 0;
    var in_string: ?u8 = null;
    var escaped = false;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string) |q| {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (c == q) in_string = null;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            continue;
        }
        if (c == '#' and i + 1 < text.len and text[i + 1] == '{') {
            interp_depth += 1;
            i += 1;
            continue;
        }
        if (interp_depth > 0) {
            if (c == '{') {
                interp_depth += 1;
            } else if (c == '}') {
                interp_depth -= 1;
            }
            continue;
        }
        if (std.mem.indexOfScalar(u8, needles, c) != null) return true;
    }
    return false;
}

fn exprNodeSourceText(ast: *const ast_flat.Ast, node: NodeIndex) ?[]const u8 {
    const n = ast.getNode(node);
    if (n.span_end < n.span_start or n.span_end > ast.source.len) return null;
    return ast.source[n.span_start..n.span_end];
}

/// `compactAdjacentSlashWhitespace` + `normalizeLeadingZeros` +
/// Determine the plain-CSS value where all three stages of `expandHexAlphaColors` are no-op
/// quick scan. Skip all alloc/free in plain-CSS declaration of hot path.
///
/// Conditions for each stage to make changes:
/// * compact slash: contains `/`
/// * leading zero: `.<digit>` appears in new leading-zero padding context
/// * hex alpha: `#` followed by 4 / 8 hex digits
///
/// False positive (=actually no-op but not returning true) is only a performance loss.
/// false negative (= return true even though conversion is actually required) is a behavior change
/// Be careful. Set it to the safe side with a simple judgment that does not include any of "/", "#", and ".".
fn plainCssValueNeedsNoNormalize(text: []const u8) bool {
    return std.mem.indexOfAny(u8, text, "/#.") == null;
}

fn compactAdjacentSlashWhitespace(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '/') == null) return allocator.dupe(u8, text);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch != '/') {
            try out.append(allocator, ch);
            continue;
        }

        try out.append(allocator, ch);
        var j = i + 1;
        while (j < text.len and std.ascii.isWhitespace(text[j])) : (j += 1) {}
        if (j < text.len and text[j] == '/') {
            i = j - 1;
        }
    }

    return out.toOwnedSlice(allocator);
}

fn appendDynamicTextExprParts(
    ctx: *Ctx,
    store: *std.ArrayListUnmanaged(ExprIndex),
    expr: ExprIndex,
) ResolveError!struct { start: u32, count: u32 } {
    const start: u32 = @intCast(store.items.len);
    const ex = ctx.prog.exprs.items[expr];
    if (ex.kind == .interp) {
        const interp = ctx.prog.interp_exprs.items[ex.payload];
        var i: u32 = 0;
        while (i < interp.part_count) : (i += 1) {
            try store.append(ctx.a, ctx.prog.interp_parts.items[interp.part_start + i]);
        }
        return .{ .start = start, .count = interp.part_count };
    }
    try store.append(ctx.a, expr);
    return .{ .start = start, .count = 1 };
}

fn validateResolvedLiteralSelector(selector: []const u8) bool {
    validateSelectorDelimiters(selector) catch return false;
    validateSelectorParentheses(selector) catch return false;
    validatePseudoClassArgs(selector) catch return false;
    return true;
}

fn resolvedLiteralSelectorSyntaxValid(ctx: *Ctx, literal_id: InternId) ResolveError!bool {
    const gop = try ctx.literal_selector_syntax_cache.getOrPut(ctx.a, literal_id);
    if (!gop.found_existing) {
        gop.value_ptr.* = validateResolvedLiteralSelector(ctx.pool.get(literal_id));
    }
    return gop.value_ptr.*;
}

fn resolveSelectorRuleData(ctx: *Ctx, sel_node: NodeIndex, span: Span) ResolveError!RuleData {
    const sn = ctx.ast.getNode(sel_node);
    const in_plain_css_module = isPlainCssStylesheetPath(ctx.module_path);
    const raw_text = if (sn.tag == .expr_unquoted_ident)
        ctx.pool.get(@as(InternId, @enumFromInt(sn.payload)))
    else
        exprNodeSourceText(ctx.ast, sel_node) orelse return error.SassError;
    var stripped_selector_owned: ?[]const u8 = null;
    defer if (stripped_selector_owned) |owned| ctx.a.free(owned);
    const text = blk: {
        const stripped = try selector_helpers.stripSelectorComments(ctx.a, raw_text);
        if (stripped.ptr == raw_text.ptr and stripped.len == raw_text.len) break :blk raw_text;
        stripped_selector_owned = stripped;
        break :blk stripped;
    };
    if (containsReferenceCombinator(text)) return error.SassError;
    if (in_plain_css_module) {
        const plain_css_is_top_level = ctx.plain_css_style_rule_depth == 0;
        validatePlainCssSelector(text, plain_css_is_top_level) catch return error.SassError;
    }
    const plain_css_parent_combine = in_plain_css_module and
        ctx.plain_css_style_rule_depth == 0 and
        ctx.style_rule_depth > 0;
    const plain_css_hoist_at_rules = in_plain_css_module and
        ctx.plain_css_style_rule_depth == 0 and
        ctx.style_rule_depth == 0;
    if (sn.tag == .expr_unquoted_ident and std.mem.indexOf(u8, text, "#{") == null) {
        const literal_id = try ctx.pool.intern(text);
        const literal_selector_syntax_valid = try resolvedLiteralSelectorSyntaxValid(ctx, literal_id);
        const is_placeholder = simplePlaceholderSelectorKey(text) != null;
        const prop_ns = parsePropertyNamespaceSelector(ctx, text, span);
        return .{
            .selector_kind = .literal,
            .literal_intern = literal_id,
            .is_placeholder = is_placeholder,
            .literal_selector_syntax_valid = literal_selector_syntax_valid,
            .is_plain_css = in_plain_css_module,
            .plain_css_parent_selector_combine = plain_css_parent_combine,
            .plain_css_hoist_block_at_rules = plain_css_hoist_at_rules,
            .prop_namespace_prefix = if (prop_ns) |v| v.prefix else .none,
            .prop_namespace_prefix_expr = if (prop_ns) |v| v.prefix_expr else null,
            .prop_namespace_value_expr = if (prop_ns) |v| v.value_expr else null,
            .dynamic_parts_start = 0,
            .dynamic_parts_count = 0,
            .body_direct = &.{},
        };
    }
    const text_expr = try resolveExpr(ctx.ast, ctx, sel_node);
    const tex = ctx.prog.exprs.items[text_expr];
    const literal_id = if (tex.kind == .literal_string)
        unpackLiteralStringPayload(tex.payload).id
    else
        InternId.none;

    if (literal_id != .none) {
        const literal_text = ctx.pool.get(literal_id);
        const literal_selector_syntax_valid = try resolvedLiteralSelectorSyntaxValid(ctx, literal_id);
        const is_placeholder = simplePlaceholderSelectorKey(literal_text) != null;
        const prop_ns = parsePropertyNamespaceSelector(ctx, text, span);
        return .{
            .selector_kind = .literal,
            .literal_intern = literal_id,
            .is_placeholder = is_placeholder,
            .literal_selector_syntax_valid = literal_selector_syntax_valid,
            .is_plain_css = in_plain_css_module,
            .plain_css_parent_selector_combine = plain_css_parent_combine,
            .plain_css_hoist_block_at_rules = plain_css_hoist_at_rules,
            .prop_namespace_prefix = if (prop_ns) |v| v.prefix else .none,
            .prop_namespace_prefix_expr = if (prop_ns) |v| v.prefix_expr else null,
            .prop_namespace_value_expr = if (prop_ns) |v| v.value_expr else null,
            .dynamic_parts_start = 0,
            .dynamic_parts_count = 0,
            .body_direct = &.{},
        };
    }
    const stored = try appendDynamicTextExprParts(ctx, &ctx.prog.selector_part_exprs, text_expr);
    const prop_ns = parsePropertyNamespaceSelector(ctx, text, span);
    return .{
        .selector_kind = .dynamic,
        .literal_intern = .none,
        .is_placeholder = false,
        .is_plain_css = in_plain_css_module,
        .plain_css_parent_selector_combine = plain_css_parent_combine,
        .plain_css_hoist_block_at_rules = plain_css_hoist_at_rules,
        .prop_namespace_prefix = if (prop_ns) |v| v.prefix else .none,
        .prop_namespace_prefix_expr = if (prop_ns) |v| v.prefix_expr else null,
        .prop_namespace_value_expr = if (prop_ns) |v| v.value_expr else null,
        .dynamic_parts_start = stored.start,
        .dynamic_parts_count = stored.count,
        .body_direct = &.{},
    };
}

fn resolveDeclPropData(ctx: *Ctx, prop_node: NodeIndex, _: Span) ResolveError!struct {
    prop_kind: DeclPropKind,
    prop_intern: InternId,
    prop_parts_start: u32,
    prop_parts_count: u32,
} {
    const pn = ctx.ast.getNode(prop_node);
    const text = if (pn.tag == .expr_unquoted_ident)
        ctx.pool.get(@as(InternId, @enumFromInt(pn.payload)))
    else
        exprNodeSourceText(ctx.ast, prop_node) orelse return error.SassError;
    const prop_expr = try resolveExpr(ctx.ast, ctx, prop_node);
    const ex = ctx.prog.exprs.items[prop_expr];
    if (ex.kind == .literal_string) {
        return .{
            .prop_kind = .literal,
            .prop_intern = unpackLiteralStringPayload(ex.payload).id,
            .prop_parts_start = 0,
            .prop_parts_count = 0,
        };
    }
    _ = text;
    const stored = try appendDynamicTextExprParts(ctx, &ctx.prog.decl_prop_part_exprs, prop_expr);
    return .{
        .prop_kind = .dynamic,
        .prop_intern = .none,
        .prop_parts_start = stored.start,
        .prop_parts_count = stored.count,
    };
}

const ResolvedStmtSlice = struct {
    start: StmtIndex,
    len: u32,
};

fn resolveStmtList(ctx: *Ctx, extra_off: ExtraIndex) ResolveError!ResolvedStmtSlice {
    const raw = readChildList(ctx.ast, extra_off);
    if (raw.len == 0) return .{ .start = 0, .len = 0 };
    const start: StmtIndex = @intCast(ctx.prog.stmts.items.len);
    var last_child_idx: StmtIndex = start;
    for (raw) |u| {
        last_child_idx = try resolveStmt(ctx, @enumFromInt(u));
        if (ctx.pending_extra_top.items.len > 0) {
            ctx.pending_extra_top.clearRetainingCapacity();
        }
    }
    if (raw.len == 1) return .{ .start = last_child_idx, .len = 1 };
    const len: u32 = @intCast(ctx.prog.stmts.items.len - start);
    return .{ .start = start, .len = len };
}

fn resolveStmtListInFlowControl(ctx: *Ctx, extra_off: ExtraIndex) ResolveError!ResolvedStmtSlice {
    ctx.flow_control_depth += 1;
    defer ctx.flow_control_depth -= 1;
    return resolveStmtList(ctx, extra_off);
}

fn resolveStmtListInFlowControlScope(ctx: *Ctx, extra_off: ExtraIndex) ResolveError!ResolvedStmtSlice {
    try ctx.pushScope(ctx.a);
    defer ctx.popScope(ctx.a);
    ctx.currentScopeFlags().is_flow_control = true;
    return resolveStmtListInFlowControl(ctx, extra_off);
}

fn appendNoop(ctx: *Ctx, span: Span) !StmtIndex {
    const idx: StmtIndex = @intCast(ctx.prog.stmts.items.len);
    try ctx.prog.stmts.append(ctx.a, .{
        .kind = .noop,
        .payload = 0,
        .span = span,
        .origin_id = ctx.currentOrigin(),
    });
    return idx;
}

fn resolveErrorStmt(ctx: *Ctx, n: AstNode, span: Span) ResolveError!StmtIndex {
    const expr_node: NodeIndex = @enumFromInt(n.payload);
    const expr_idx = try resolveExpr(ctx.ast, ctx, expr_node);
    const idx: StmtIndex = @intCast(ctx.prog.stmts.items.len);
    try ctx.prog.stmts.append(ctx.a, .{
        .kind = .error_stmt,
        .payload = expr_idx,
        .span = span,
        .origin_id = ctx.currentOrigin(),
    });
    return idx;
}

fn resolveDebugStmt(ctx: *Ctx, n: AstNode, span: Span) ResolveError!StmtIndex {
    const expr_node: NodeIndex = @enumFromInt(n.payload);
    const expr_idx = try resolveExpr(ctx.ast, ctx, expr_node);
    const idx: StmtIndex = @intCast(ctx.prog.stmts.items.len);
    try ctx.prog.stmts.append(ctx.a, .{
        .kind = .debug_stmt,
        .payload = expr_idx,
        .span = span,
        .origin_id = ctx.currentOrigin(),
    });
    return idx;
}

fn resolveWarnStmt(ctx: *Ctx, n: AstNode, span: Span) ResolveError!StmtIndex {
    const expr_node: NodeIndex = @enumFromInt(n.payload);
    const expr_idx = try resolveExpr(ctx.ast, ctx, expr_node);
    const idx: StmtIndex = @intCast(ctx.prog.stmts.items.len);
    try ctx.prog.stmts.append(ctx.a, .{
        .kind = .warn_stmt,
        .payload = expr_idx,
        .span = span,
        .origin_id = ctx.currentOrigin(),
    });
    return idx;
}

const NamespacedVariableAssign = struct {
    ns: []const u8,
    member: []const u8,
};

fn isSimpleIdentifierChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

fn isSimpleIdentifier(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        if (!isSimpleIdentifierChar(c)) return false;
    }
    return true;
}

fn parseNamespacedVariableAssign(raw_prop: []const u8) ?NamespacedVariableAssign {
    const trimmed = std.mem.trim(u8, raw_prop, " \t\n\r");
    const dot_dollar = std.mem.indexOf(u8, trimmed, ".$") orelse return null;
    if (dot_dollar == 0) return null;
    const ns = std.mem.trim(u8, trimmed[0..dot_dollar], " \t\n\r");
    const member = std.mem.trim(u8, trimmed[dot_dollar + 2 ..], " \t\n\r");
    if (!isSimpleIdentifier(ns) or !isSimpleIdentifier(member)) return null;
    return .{ .ns = ns, .member = member };
}

fn resolveStyleRuleStmt(ctx: *Ctx, n: AstNode, span: Span) ResolveError!StmtIndex {
    const off: ExtraIndex = n.payload;
    const sel_n: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(off));
    const body_extra = ctx.ast.getExtraU32(off + 1);
    var rd = try resolveSelectorRuleData(ctx, sel_n, span);
    if (ctx.property_namespace_depth > 0 and rd.prop_namespace_prefix_expr == null) {
        return error.SassError;
    }
    const raw = readChildList(ctx.ast, body_extra);
    var direct: std.ArrayListUnmanaged(StmtIndex) = .empty;
    const enters_property_namespace = rd.prop_namespace_prefix_expr != null;
    ctx.nested_stmt_depth += 1;
    ctx.style_rule_depth += 1;
    if (rd.is_plain_css) ctx.plain_css_style_rule_depth += 1;
    if (enters_property_namespace) ctx.property_namespace_depth += 1;
    try ctx.pushScope(ctx.a);
    if (!ctx.in_callable and ctx.next_local_slot < ctx.prog.next_global_slot) {
        ctx.next_local_slot = ctx.prog.next_global_slot;
    }
    const saved_plain_css_validate_values = ctx.plain_css_validate_values;
    if (rd.is_plain_css) ctx.plain_css_validate_values = true;
    defer {
        ctx.plain_css_validate_values = saved_plain_css_validate_values;
        ctx.popScope(ctx.a);
        if (rd.is_plain_css and ctx.plain_css_style_rule_depth > 0) ctx.plain_css_style_rule_depth -= 1;
        if (enters_property_namespace and ctx.property_namespace_depth > 0) ctx.property_namespace_depth -= 1;
        if (ctx.style_rule_depth > 0) ctx.style_rule_depth -= 1;
        ctx.nested_stmt_depth -= 1;
    }
    try direct.ensureTotalCapacity(ctx.a, raw.len);
    for (raw) |u| {
        const child_idx = try resolveStmt(ctx, @enumFromInt(u));
        if (ctx.pending_extra_top.items.len > 0) {
            try direct.ensureUnusedCapacity(ctx.a, ctx.pending_extra_top.items.len);
            for (ctx.pending_extra_top.items) |ex| {
                direct.appendAssumeCapacity(ex);
            }
            ctx.pending_extra_top.clearRetainingCapacity();
        }
        try direct.append(ctx.a, child_idx);
    }
    rd.body_direct = try ctx.prog.arena.allocator().dupe(StmtIndex, direct.items);
    const idx: StmtIndex = @intCast(ctx.prog.stmts.items.len);
    const ridx: u32 = @intCast(ctx.prog.rule_stmts.items.len);
    try ctx.prog.rule_stmts.append(ctx.a, rd);
    try ctx.prog.stmts.append(ctx.a, .{
        .kind = .rule,
        .payload = ridx,
        .span = span,
        .origin_id = ctx.currentOrigin(),
    });
    return idx;
}

fn normalizeSassTerminatedComment(allocator: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, raw, "/*")) return null;
    const trimmed_raw = std.mem.trimEnd(u8, raw, " \t\r\n\x0c");
    if (!std.mem.endsWith(u8, trimmed_raw, "*/")) return null;

    var first_nl: ?usize = null;
    for (2..raw.len) |i| {
        if (raw[i] == '\n' or raw[i] == '\r' or raw[i] == '\x0c') {
            first_nl = i;
            break;
        }
    }
    const nl_pos = first_nl orelse return null;
    for (raw[2..nl_pos]) |c| {
        if (c != ' ' and c != '\t') return null;
    }

    const Line = struct { indent: usize, content: []const u8 };
    var lines: std.ArrayListUnmanaged(Line) = .empty;
    defer lines.deinit(allocator);

    var pos = nl_pos + 1;
    if (raw[nl_pos] == '\r' and pos < raw.len and raw[pos] == '\n') pos += 1;

    while (pos < raw.len) {
        var line_end = pos;
        while (line_end < raw.len and raw[line_end] != '\n' and raw[line_end] != '\r' and raw[line_end] != '\x0c') line_end += 1;
        const line = raw[pos..line_end];
        var indent: usize = 0;
        while (indent < line.len and (line[indent] == ' ' or line[indent] == '\t')) indent += 1;
        try lines.append(allocator, .{ .indent = indent, .content = line[indent..] });
        if (line_end >= raw.len) break;
        pos = line_end + 1;
        if (line_end < raw.len and raw[line_end] == '\r' and pos < raw.len and raw[pos] == '\n') pos += 1;
    }

    if (lines.items.len == 0) return null;

    var min_indent: usize = std.math.maxInt(usize);
    for (lines.items) |line| {
        if (std.mem.trimEnd(u8, line.content, " \t").len > 0)
            min_indent = @min(min_indent, line.indent);
    }
    if (min_indent == std.math.maxInt(usize)) min_indent = 0;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var first = true;
    for (lines.items) |line| {
        if (first and std.mem.trimEnd(u8, line.content, " \t").len == 0) continue;
        const extra = if (line.indent > min_indent) line.indent - min_indent else 0;
        if (first) {
            try out.appendSlice(allocator, "/*");
            try out.appendNTimes(allocator, ' ', extra + 1);
            try out.appendSlice(allocator, line.content);
            first = false;
        } else {
            try out.appendSlice(allocator, "\n *");
            try out.appendNTimes(allocator, ' ', @max(@as(usize, 1), extra));
            try out.appendSlice(allocator, line.content);
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn resolveCommentStmt(ctx: *Ctx, span: Span) ResolveError!StmtIndex {
    if (span.end > span.start and span.end <= ctx.ast.source.len) {
        const raw = ctx.ast.source[span.start..span.end];
        const effective_raw = if (ctx.ast.is_indented_syntax)
            (normalizeSassTerminatedComment(ctx.a, raw) catch null) orelse raw
        else
            raw;
        const text_expr = if (std.mem.indexOf(u8, effective_raw, "#{") != null)
            try resolveInterpolatedTextExpr(ctx, effective_raw, span, false)
        else
            null;
        const id = if (text_expr) |expr_idx|
            collapseStaticTextExprToIntern(ctx, expr_idx) orelse .none
        else
            try ctx.pool.intern(effective_raw);
        const idx: StmtIndex = @intCast(ctx.prog.stmts.items.len);
        const cidx: u32 = @intCast(ctx.prog.comment_stmts.items.len);
        // Calculate source column of `/*` directly from AST source. line start (= previous `\n`
        // Distance from source (start of source) is col. @import inline after compiling
        // Ast.source is always correct here, even if it comes from a file that differs from `cb.module_id`
        // It is reliable because it is calculated against.
        const source_col: u32 = blk: {
            const start: usize = @intCast(span.start);
            var line_start: usize = 0;
            if (std.mem.lastIndexOfScalar(u8, ctx.ast.source[0..start], '\n')) |nl| {
                line_start = nl + 1;
            }
            break :blk @intCast(start - line_start);
        };
        // `/*` Is there a non-blank character in the same line just before (backward scan of ast.source)?
        // Check from the beginning of line to just before `/*`, and if all are space/tab, there is no leading token (= line alone).
        // CR is treated as the same line assuming that only `\n` is used as a delimiter when calculating line_starts.
        var leading_same_line: bool = blk: {
            const start: usize = @intCast(span.start);
            var line_start: usize = 0;
            if (std.mem.lastIndexOfScalar(u8, ctx.ast.source[0..start], '\n')) |nl| {
                line_start = nl + 1;
            }
            for (ctx.ast.source[line_start..start]) |ch| {
                if (ch != ' ' and ch != '\t' and ch != '\r') break :blk true;
            }
            break :blk false;
        };
        // For `@include foo(...); /* c */` without a content block, the
        // trailing comment belongs to the include site, not the final
        // declaration emitted by the mixin body. The mixin body has a different
        // source position, so treating the comment as same-line would attach it
        // to the wrong output. Includes with content blocks keep the comment
        // behavior of caller-authored declarations.
        if (leading_same_line and ctx.prog.stmts.items.len > 0) {
            const prev_stmt = ctx.prog.stmts.items[ctx.prog.stmts.items.len - 1];
            if (prev_stmt.kind == .include) {
                const include_payload = prev_stmt.payload;
                if (include_payload < ctx.prog.include_stmts.items.len) {
                    const inc = ctx.prog.include_stmts.items[include_payload];
                    if (inc.content_block == std.math.maxInt(u32)) {
                        leading_same_line = false;
                    }
                }
            }
        }
        try ctx.prog.comment_stmts.append(ctx.a, .{
            .text_intern = id,
            .text_expr = if (id == .none) text_expr else null,
            .source_col = source_col,
            .leading_same_line = leading_same_line,
        });
        try ctx.prog.stmts.append(ctx.a, .{
            .kind = .comment,
            .payload = cidx,
            .span = span,
            .origin_id = ctx.currentOrigin(),
        });
        return idx;
    }
    return try appendNoop(ctx, span);
}

fn sourceColumn(source: []const u8, offset_u32: u32) u32 {
    const offset: usize = @min(source.len, @as(usize, offset_u32));
    const line_start: usize = if (std.mem.lastIndexOfScalar(u8, source[0..offset], '\n')) |nl| nl + 1 else 0;
    return @intCast(offset - line_start);
}

fn internMarkedCustomPropertyRawValue(ctx: *Ctx, raw_value: []const u8, prop_span_start: u32) ResolveError!InternId {
    const col = sourceColumn(ctx.ast.source, prop_span_start);
    var leading: usize = 0;
    while (leading < raw_value.len and (raw_value[leading] == ' ' or raw_value[leading] == '\t')) : (leading += 1) {}

    const marked = if (leading == 0)
        try std.fmt.allocPrint(ctx.a, "{s}{d};{s}", .{
            opcode_mod.custom_property_source_col_marker,
            col,
            raw_value,
        })
    else
        try std.fmt.allocPrint(ctx.a, "{s}{s}{d};{s}", .{
            raw_value[0..leading],
            opcode_mod.custom_property_source_col_marker,
            col,
            raw_value[leading..],
        });
    defer ctx.a.free(marked);
    return try ctx.pool.intern(marked);
}

/// Resolve fast path of declaration from `*.css` source. With plain CSS:
/// * Prop is only ident (not interpolation).
/// * value is a literal_string of raw text (no expression evaluation).
/// * namespaced var assign / callable_decl_context / for `$ns.foo = 1`
/// `in_declaration_value` save-restore cannot occur in plain CSS, so skip it.
/// Cut out the plain-CSS branch of generic `resolveDeclarationStmt` into a smaller path,
/// Eliminate generic dispatch costs such as `resolveExpr`. prop_ast.tag is
/// Called only when `.expr_unquoted_ident` (otherwise fallback to generic path).
fn resolvePlainCssDeclarationStmtFast(
    ctx: *Ctx,
    n: AstNode,
    span: Span,
    prop_n: NodeIndex,
    val_n: NodeIndex,
) ResolveError!StmtIndex {
    const prop_ast = ctx.ast.getNode(prop_n);
    const val_ast = ctx.ast.getNode(val_n);
    const prop_start: usize = @min(ctx.ast.source.len, @as(usize, prop_ast.span_start));
    const prop_end: usize = @min(ctx.ast.source.len, @as(usize, prop_ast.span_end));
    const val_start: usize = @min(ctx.ast.source.len, @as(usize, val_ast.span_start));
    const val_end: usize = @min(ctx.ast.source.len, @as(usize, val_ast.span_end));
    const raw_prop = if (prop_end > prop_start) ctx.ast.source[prop_start..prop_end] else "";
    const raw_val = if (val_end > val_start) ctx.ast.source[val_start..val_end] else "";

    if (std.mem.indexOf(u8, raw_prop, "#{") != null or
        std.mem.indexOf(u8, raw_val, "#{") != null)
    {
        return error.SassError;
    }

    const trimmed_prop = std.mem.trim(u8, raw_prop, " \t\r\n");
    const is_custom_property = std.mem.startsWith(u8, trimmed_prop, "--");

    if (ctx.property_namespace_depth > 0 and is_custom_property) {
        return error.SassError;
    }

    if (ctx.plain_css_validate_values and !is_custom_property) {
        validatePlainCssValue(raw_val) catch return error.SassError;
    }

    const prop_intern: InternId = @enumFromInt(prop_ast.payload);

    const raw_id: InternId = if (is_custom_property)
        try ctx.pool.intern(raw_val)
    else if (plainCssValueNeedsNoNormalize(raw_val))
        try ctx.pool.intern(raw_val)
    else id: {
        const compacted = try compactAdjacentSlashWhitespace(ctx.a, raw_val);
        defer ctx.a.free(compacted);
        const zero_filled = try value_format.normalizeLeadingZeros(ctx.a, compacted);
        defer ctx.a.free(zero_filled);
        const hex_expanded = try value_format.expandHexAlphaColors(ctx.a, zero_filled);
        defer ctx.a.free(hex_expanded);
        break :id try ctx.pool.intern(hex_expanded);
    };

    const val_e = try appendExpr(ctx.prog, ctx.a, .{
        .kind = .literal_string,
        .payload = packLiteralStringPayloadEx(raw_id, false, false, true),
        .span = .{ .start = val_ast.span_start, .end = val_ast.span_end },
    });

    const important = (n.flags & 2) != 0;
    var emit_decl_flags: u16 = 0;
    if (sourceSliceHasTopLevelComma(raw_val)) {
        emit_decl_flags |= opcode_mod.emit_decl_flag_has_explicit_top_level_comma;
    }
    const value_has_newline = std.mem.indexOfAny(u8, raw_val, "\n\r") != null;
    if (value_has_newline) {
        emit_decl_flags |= opcode_mod.emit_decl_flag_value_source_multiline;
    }
    // `sourceSpanLooksLikeBareMultilineComma` scans span line in reverse/order direction
    // Heavy functions to do. A typical plain CSS declaration does not have trailing `,`, so
    // Check raw_val first; if it has no comma, skip the more expensive source scan.
    if (rawValueLooksLikeTrailingCommaCandidate(raw_val) and
        sourceSpanLooksLikeBareMultilineComma(ctx.ast.source, span))
    {
        emit_decl_flags |= opcode_mod.emit_decl_flag_bare_multiline_comma_syntax;
    }
    if (is_custom_property and
        declarationSourceHasHorizontalWhitespaceAfterColon(ctx.ast.source, span))
    {
        emit_decl_flags |= opcode_mod.emit_decl_flag_custom_property_leading_space;
    }

    const raw_value_source_intern: InternId = if (is_custom_property and value_has_newline)
        try internMarkedCustomPropertyRawValue(ctx, raw_val, prop_ast.span_start)
    else
        .none;

    const idx: StmtIndex = @intCast(ctx.prog.stmts.items.len);
    const pidx: u32 = @intCast(ctx.prog.decl_stmts.items.len);
    try ctx.prog.decl_stmts.append(ctx.a, .{
        .prop_kind = .literal,
        .prop_intern = prop_intern,
        .prop_parts_start = 0,
        .prop_parts_count = 0,
        .value_expr = val_e,
        .important = important,
        .emit_decl_flags = emit_decl_flags,
        .raw_value_source_intern = raw_value_source_intern,
    });
    try ctx.prog.stmts.append(ctx.a, .{
        .kind = .declaration,
        .payload = pidx,
        .span = span,
        .origin_id = ctx.currentOrigin(),
    });
    return idx;
}

fn resolveDeclarationStmt(ctx: *Ctx, n: AstNode, span: Span, in_plain_css_module: bool) ResolveError!StmtIndex {
    const off: ExtraIndex = n.payload;
    const prop_n: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(off));
    const val_n: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(off + 1));
    if (in_plain_css_module) {
        const prop_ast_for_fast = ctx.ast.getNode(prop_n);
        if (prop_ast_for_fast.tag == .expr_unquoted_ident) {
            return try resolvePlainCssDeclarationStmtFast(ctx, n, span, prop_n, val_n);
        }
    }
    var plain_css_is_custom_property = false;
    if (in_plain_css_module) {
        const prop_ast = ctx.ast.getNode(prop_n);
        const val_ast = ctx.ast.getNode(val_n);
        const prop_start: usize = @min(ctx.ast.source.len, @as(usize, prop_ast.span_start));
        const prop_end: usize = @min(ctx.ast.source.len, @as(usize, prop_ast.span_end));
        const val_start: usize = @min(ctx.ast.source.len, @as(usize, val_ast.span_start));
        const val_end: usize = @min(ctx.ast.source.len, @as(usize, val_ast.span_end));
        const raw_prop = if (prop_end > prop_start) ctx.ast.source[prop_start..prop_end] else "";
        const raw_val = if (val_end > val_start) ctx.ast.source[val_start..val_end] else "";
        if (std.mem.indexOf(u8, raw_prop, "#{") != null or
            std.mem.indexOf(u8, raw_val, "#{") != null)
        {
            return error.SassError;
        }
        const trimmed_prop = std.mem.trim(u8, raw_prop, " \t\r\n");
        plain_css_is_custom_property = std.mem.startsWith(u8, trimmed_prop, "--");
        if (ctx.plain_css_validate_values and !plain_css_is_custom_property) {
            validatePlainCssValue(raw_val) catch return error.SassError;
        }
    }
    const prop_ast = ctx.ast.getNode(prop_n);
    {
        const raw_start: usize = @min(ctx.ast.source.len, @as(usize, prop_ast.span_start));
        const raw_end: usize = @min(ctx.ast.source.len, @as(usize, prop_ast.span_end));
        const raw_prop_text = if (raw_end > raw_start) ctx.ast.source[raw_start..raw_end] else "";
        const trimmed_prop_text = std.mem.trim(u8, raw_prop_text, " \t\r\n");
        if (ctx.property_namespace_depth > 0 and std.mem.startsWith(u8, trimmed_prop_text, "--")) {
            return error.SassError;
        }
    }
    if (prop_ast.tag == .expr_unquoted_ident) {
        const prop_id: InternId = @enumFromInt(prop_ast.payload);
        const raw_prop = ctx.pool.get(prop_id);
        if (parseNamespacedVariableAssign(raw_prop)) |namespaced| {
            const binding = lookupUseBindingInContext(ctx, namespaced.ns) orelse return error.UnknownVar;
            switch (binding) {
                .builtin_module => return error.UnknownVar,
                .user_module => |mid| {
                    const loader = try requireModuleLoader(ctx);
                    const ex = try requireModuleExports(loader, mid);
                    if (lookupVoidFlagInsensitive(&ex.ambiguous_vars, namespaced.member)) return error.SassError;
                    const target = lookupConfigVarTargetInsensitive(&ex.shadowed_forward_vars, namespaced.member) orelse
                        lookupConfigVarTargetInsensitive(&ex.vars, namespaced.member) orelse
                        return error.UnknownVar;
                    const val_e = try resolveExpr(ctx.ast, ctx, val_n);
                    const idx: StmtIndex = @intCast(ctx.prog.stmts.items.len);
                    const aidx: u32 = @intCast(ctx.prog.assign_stmts.items.len);
                    try ctx.prog.assign_stmts.append(ctx.a, .{
                        .slot = try encodeCrossAssignSlot(target.module_id, target.slot),
                        .value_expr = val_e,
                        .default = false,
                        .global = false,
                    });
                    try ctx.prog.stmts.append(ctx.a, .{
                        .kind = .assign_var,
                        .payload = aidx,
                        .span = span,
                        .origin_id = ctx.currentOrigin(),
                    });
                    return idx;
                },
            }
        }
    }
    if (ctx.callable_decl_context == .function) return error.SassError;
    const pd = try resolveDeclPropData(ctx, prop_n, span);
    const saved_in_declaration_value = ctx.in_declaration_value;
    ctx.in_declaration_value = true;
    defer ctx.in_declaration_value = saved_in_declaration_value;
    const val_ast = ctx.ast.getNode(val_n);
    const val_start: usize = @min(ctx.ast.source.len, @as(usize, val_ast.span_start));
    const val_end: usize = @min(ctx.ast.source.len, @as(usize, val_ast.span_end));
    const value_source = if (val_end > val_start) ctx.ast.source[val_start..val_end] else "";
    const source_has_legacy_plus_important = declarationSourceHasLegacyPlusImportant(ctx.ast.source, span);
    const legacy_plus_important_expr = try resolveLegacyPlusImportantValue(ctx, value_source, .{ .start = val_ast.span_start, .end = val_ast.span_end });
    const important = (n.flags & 2) != 0 or source_has_legacy_plus_important or legacy_plus_important_expr != null;
    const base_val_e = if (legacy_plus_important_expr) |expr_idx|
        expr_idx
    else if (in_plain_css_module) blk: {
        const raw_val = value_source;
        const raw_id = if (plain_css_is_custom_property) id: {
            // official Sass CLI uses plain CSS custom property (`--foo:`) value
            // retain verbatim (slash compaction / leading-zero / hex color expansion
            // Neither applies).
            break :id try ctx.pool.intern(raw_val);
        } else id: {
            const compacted = try compactAdjacentSlashWhitespace(ctx.a, raw_val);
            defer ctx.a.free(compacted);
            const zero_filled = try value_format.normalizeLeadingZeros(ctx.a, compacted);
            defer ctx.a.free(zero_filled);
            const hex_expanded = try value_format.expandHexAlphaColors(ctx.a, zero_filled);
            defer ctx.a.free(hex_expanded);
            break :id try ctx.pool.intern(hex_expanded);
        };
        break :blk try appendExpr(ctx.prog, ctx.a, .{
            .kind = .literal_string,
            .payload = packLiteralStringPayloadEx(raw_id, false, false, true),
            .span = .{ .start = val_ast.span_start, .end = val_ast.span_end },
        });
    } else blk: {
        if (pd.prop_kind == .dynamic and std.mem.indexOf(u8, value_source, "#{") != null) {
            if (try resolveCssSpecialCallExprFromSourceText(ctx, value_source, .{ .start = val_ast.span_start, .end = val_ast.span_end })) |expr_idx| {
                break :blk expr_idx;
            }
        }
        break :blk try resolveExpr(ctx.ast, ctx, val_n);
    };
    const val_e = if (source_has_legacy_plus_important) blk: {
        const important_id = try ctx.pool.intern("!important");
        const important_expr = try appendExpr(ctx.prog, ctx.a, .{
            .kind = .literal_string,
            .payload = packLiteralStringPayload(important_id, false, false),
            .span = .{ .start = val_ast.span_end, .end = val_ast.span_end },
        });
        const elems = [_]ExprIndex{ base_val_e, important_expr };
        break :blk try appendListExprFromElems(ctx, &elems, .space, false, false, false, span);
    } else base_val_e;
    var emit_decl_flags: u16 = 0;
    if (sourceSliceHasTopLevelComma(value_source)) {
        emit_decl_flags |= opcode_mod.emit_decl_flag_has_explicit_top_level_comma;
    }
    if (std.mem.indexOfAny(u8, value_source, "\n\r") != null) {
        emit_decl_flags |= opcode_mod.emit_decl_flag_value_source_multiline;
    }
    if (rawValueLooksLikeTrailingCommaCandidate(value_source) and
        sourceSpanLooksLikeBareMultilineComma(ctx.ast.source, span))
    {
        emit_decl_flags |= opcode_mod.emit_decl_flag_bare_multiline_comma_syntax;
    }
    const prop_source_is_custom = blk: {
        if (pd.prop_kind == .literal) break :blk std.mem.startsWith(u8, ctx.pool.get(pd.prop_intern), "--");
        const prop_source = exprNodeSourceText(ctx.ast, prop_n) orelse "";
        break :blk std.mem.startsWith(u8, std.mem.trim(u8, prop_source, " \t\r\n"), "--");
    };
    const custom_source_has_leading_space = if (pd.prop_kind == .dynamic)
        declarationSourceHasWhitespaceAfterColon(ctx.ast.source, span)
    else
        declarationSourceHasHorizontalWhitespaceAfterColon(ctx.ast.source, span);
    if ((prop_source_is_custom or pd.prop_kind == .dynamic) and custom_source_has_leading_space) {
        emit_decl_flags |= opcode_mod.emit_decl_flag_custom_property_leading_space;
    }
    const raw_value_source_intern: InternId = if (prop_source_is_custom and
        std.mem.indexOfAny(u8, value_source, "\n\r") != null and
        std.mem.indexOf(u8, value_source, "#{") == null)
        try internMarkedCustomPropertyRawValue(ctx, value_source, prop_ast.span_start)
    else
        .none;
    const idx: StmtIndex = @intCast(ctx.prog.stmts.items.len);
    const pidx: u32 = @intCast(ctx.prog.decl_stmts.items.len);
    try ctx.prog.decl_stmts.append(ctx.a, .{
        .prop_kind = pd.prop_kind,
        .prop_intern = pd.prop_intern,
        .prop_parts_start = pd.prop_parts_start,
        .prop_parts_count = pd.prop_parts_count,
        .value_expr = val_e,
        .important = important,
        .emit_decl_flags = emit_decl_flags,
        .raw_value_source_intern = raw_value_source_intern,
    });
    try ctx.prog.stmts.append(ctx.a, .{
        .kind = .declaration,
        .payload = pidx,
        .span = span,
        .origin_id = ctx.currentOrigin(),
    });
    return idx;
}

fn resolveVariableDeclStmt(ctx: *Ctx, n: AstNode, span: Span) ResolveError!StmtIndex {
    const off: ExtraIndex = n.payload;
    const name_id: InternId = @enumFromInt(ctx.ast.getExtraU32(off));
    const val_n: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(off + 1));
    const flags_u = ctx.ast.getExtraU32(off + 2);
    const is_default = (flags_u & 1) != 0;
    const is_global = (flags_u & 2) != 0;
    const is_top_level_decl = ctx.scopes.items.len == 0 and ctx.nested_stmt_depth == 0;
    const name = ctx.pool.get(name_id);
    const star_target = ctx.lookupStarVar(name_id);
    const import_default_flag = lookupBoolFlagInsensitive(&ctx.import_star_vars, name);
    const from_import_forward = import_default_flag != null;
    const from_import_default = import_default_flag orelse false;
    const needs_global_path = ctx.scopes.items.len == 0 or is_global or (star_target != null and from_import_forward);
    // SAFETY: each control-flow path that continues past `handled_flow_local_fallback` assigns `slot`.
    var slot: SlotId = undefined;
    // SAFETY: each control-flow path that continues past `handled_flow_local_fallback` assigns `val_e`.
    var val_e: ExprIndex = undefined;
    var handled_flow_local_fallback = false;

    // Case where "a new local is created but a var with the same name is visible in outer" in Flow-control:
    // RHS refers to local slot, undeclared first read uses outer slot fallback.
    if (!needs_global_path and
        (flags_u & 2) == 0 and
        !ctx.in_callable and
        ctx.flow_control_depth > 0 and
        ctx.lookupFlowControlAssignSlot(name_id) == null and
        ctx.lookupScopedSlot(name_id) == null)
    {
        if (ctx.lookupSlot(name_id)) |fallback_slot| {
            if (decodeCrossAssignSlot(fallback_slot) == null) {
                slot = try ctx.declareLocal(name_id);
                if (slot != fallback_slot) {
                    try setFlowLocalFallback(ctx.prog, ctx.a, slot, fallback_slot);
                }
                val_e = try resolveExpr(ctx.ast, ctx, val_n);
                handled_flow_local_fallback = true;
            }
        }
    }

    if (!handled_flow_local_fallback) {
        val_e = try resolveExpr(ctx.ast, ctx, val_n);
        slot = if (needs_global_path) blk: {
            try ctx.markDeclaredGlobal(name_id);
            // to public var reached via `@import` / import-through-`@forward`
            // bare assign (`$a: ...`) writes-through from importer scope to target module.
            if (star_target) |target| {
                const should_cross_assign =
                    if (is_top_level_decl)
                        // Top-level bare assign to import-forwarded `!default` var shadows locally.
                        !(from_import_forward and from_import_default and !is_global)
                    else
                        // Nested: `!global` and import-forwarded vars write-through.
                        // Plain nested assign for `@use ... as *` stays local.
                        (is_global or from_import_forward);
                if (should_cross_assign) {
                    break :blk try encodeCrossAssignSlot(target.module_id, target.slot);
                }
            }
            if (lookupGlobalSlot(ctx.prog, name)) |s| break :blk s;
            break :blk try ctx.declareGlobal(name_id);
        } else blk: {
            if ((flags_u & 2) != 0) {
                if (lookupGlobalSlot(ctx.prog, ctx.pool.get(name_id))) |s| break :blk s;
                break :blk try ctx.declareGlobal(name_id);
            }
            if (ctx.flow_control_depth > 0) {
                if (ctx.lookupFlowControlAssignSlot(name_id)) |s| break :blk s;
            }
            if (ctx.lookupScopedSlot(name_id)) |s| break :blk s;
            break :blk try ctx.declareLocal(name_id);
        };
    }
    const initial_config_value: ?value_mod.Value =
        if (is_default and is_top_level_decl and decodeCrossAssignSlot(slot) == null)
            ctx.lookupInitialConfigValue(name)
        else
            null;

    if (!ctx.in_callable and ctx.flow_control_depth == 0) {
        const keep_existing_default_static = is_default and blk: {
            const existing = lookupStaticValueForSlotIncludingCross(ctx, slot) orelse break :blk false;
            break :blk existing.kind() != .nil;
        };
        if (initial_config_value) |configured| {
            try setStaticSlotValue(ctx.prog, ctx.a, slot, configured);
            try ctx.setStaticConfigVar(name, configured);
        } else if (!keep_existing_default_static) {
            try updateTopLevelStaticConfigValue(ctx, slot, val_e);
        }
    } else {
        // If reassignment occurs within a flow control (@while/@for/@each/@if etc.) or within a callable body,
        // The runtime value is different from the one at top-level initialization, so invalidate the existing static_slot_values.
        // (Example: `$i: 1; @while ... { @include m($i); $i: $i + 1; }` causes `$i` to be inlined to the initial value 1)
        if (decodeCrossAssignSlot(slot)) |cross| {
            if (ctx.loader) |loader| {
                if (cross.module_id < loader.records_ptr.items.len) {
                    removeStaticSlotValue(&loader.records_ptr.items[cross.module_id].prog, cross.slot);
                }
            }
        } else {
            removeStaticSlotValue(ctx.prog, slot);
        }
    }
    if (is_default and is_top_level_decl and decodeCrossAssignSlot(slot) == null) {
        const owned = try ctx.a.dupe(u8, name);
        const gop = try ctx.prog.default_vars.getOrPut(ctx.a, owned);
        if (gop.found_existing) {
            ctx.a.free(owned);
        } else {
            gop.key_ptr.* = owned;
        }
        gop.value_ptr.* = slot;
    }
    const idx: StmtIndex = @intCast(ctx.prog.stmts.items.len);
    const aidx: u32 = @intCast(ctx.prog.assign_stmts.items.len);
    try ctx.prog.assign_stmts.append(ctx.a, .{
        .slot = slot,
        .value_expr = val_e,
        .default = is_default,
        .global = is_global,
    });
    try ctx.prog.stmts.append(ctx.a, .{
        .kind = .assign_var,
        .payload = aidx,
        .span = span,
        .origin_id = ctx.currentOrigin(),
    });
    return idx;
}

fn resolveReturnStmt(ctx: *Ctx, n: AstNode, span: Span) ResolveError!StmtIndex {
    if (ctx.callable_decl_context != .function) return error.Unsupported;
    const val_n: NodeIndex = @enumFromInt(n.payload);
    const val_e = try resolveExpr(ctx.ast, ctx, val_n);
    const idx: StmtIndex = @intCast(ctx.prog.stmts.items.len);
    const ridx: u32 = @intCast(ctx.prog.return_stmts.items.len);
    try ctx.prog.return_stmts.append(ctx.a, .{ .value_expr = val_e });
    try ctx.prog.stmts.append(ctx.a, .{
        .kind = .return_stmt,
        .payload = ridx,
        .span = span,
        .origin_id = ctx.currentOrigin(),
    });
    return idx;
}

fn resolveIfStmt(ctx: *Ctx, n: AstNode, span: Span) ResolveError!StmtIndex {
    const off: ExtraIndex = n.payload;
    const cond_n: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(off));
    const then_body = ctx.ast.getExtraU32(off + 1);
    const elseif_count = ctx.ast.getExtraU32(off + 2);
    // `!global` variable declarations inside flow-control branches must
    // reserve module slots even for statically skipped branches.
    try predeclareGlobalSlotsInStmtList(ctx, then_body);
    {
        var pre_q: ExtraIndex = off + 3;
        var pre_i: u32 = 0;
        while (pre_i < elseif_count) : (pre_i += 1) {
            pre_q += 1; // cond expr
            try predeclareGlobalSlotsInStmtList(ctx, ctx.ast.getExtraU32(pre_q));
            pre_q += 1;
        }
        try predeclareGlobalSlotsInStmtList(ctx, ctx.ast.getExtraU32(pre_q));
    }
    var q: ExtraIndex = off + 3;
    const IfBranch = @TypeOf(ctx.prog.if_branches.items[0]);
    var own_branches: std.ArrayListUnmanaged(IfBranch) = .empty;
    defer own_branches.deinit(ctx.a);
    // Static branch pruning is only sound while resolving straight-line
    // top-level code.  Inside flow control the resolver's static slot table is
    // deliberately invalidated for assignments, but a condition may still
    // reference an earlier top-level initializer.  Pruning such a branch would
    // freeze the first-iteration value and drop runtime output from later loop
    // iterations (for example an @each that sets a sentinel and then tests it
    // on the next pass).
    const allow_static_pruning = !ctx.in_callable and ctx.flow_control_depth == 0;

    {
        const cond_e = try resolveExpr(ctx.ast, ctx, cond_n);
        if (allow_static_pruning) {
            if (literalBoolValueForFlowControl(ctx, cond_e)) |cond| {
                if (cond) {
                    const then_res = try resolveStmtListInFlowControlScope(ctx, then_body);
                    try own_branches.append(ctx.a, .{
                        .cond_expr = cond_e,
                        .body_start = then_res.start,
                        .body_len = then_res.len,
                    });
                } else if (stmtListContainsContentCall(ctx.ast, then_body)) {
                    ctx.mixin_accepts_content = true;
                }
            } else {
                const then_res = try resolveStmtListInFlowControlScope(ctx, then_body);
                try own_branches.append(ctx.a, .{
                    .cond_expr = cond_e,
                    .body_start = then_res.start,
                    .body_len = then_res.len,
                });
            }
        } else {
            const then_res = try resolveStmtListInFlowControlScope(ctx, then_body);
            try own_branches.append(ctx.a, .{
                .cond_expr = cond_e,
                .body_start = then_res.start,
                .body_len = then_res.len,
            });
        }
    }
    var saw_dynamic_branch = if (allow_static_pruning)
        (own_branches.items.len != 0 and own_branches.items[0].cond_expr != null and
            literalBoolValueForFlowControl(ctx, own_branches.items[0].cond_expr.?) == null)
    else
        own_branches.items.len != 0;
    var short_circuit_taken = if (allow_static_pruning)
        (own_branches.items.len != 0 and !saw_dynamic_branch and
            own_branches.items[0].cond_expr != null and literalBoolValueForFlowControl(ctx, own_branches.items[0].cond_expr.?).?)
    else
        false;
    var ei: u32 = 0;
    while (ei < elseif_count) : (ei += 1) {
        if (short_circuit_taken) {
            q += 2;
            continue;
        }
        const ec_n: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(q));
        q += 1;
        const eb = ctx.ast.getExtraU32(q);
        q += 1;
        const ec_e = try resolveExpr(ctx.ast, ctx, ec_n);
        if (allow_static_pruning and !saw_dynamic_branch) {
            if (literalBoolValueForFlowControl(ctx, ec_e)) |cond| {
                if (!cond) {
                    if (stmtListContainsContentCall(ctx.ast, eb)) ctx.mixin_accepts_content = true;
                    continue;
                }
                const eb_res = try resolveStmtListInFlowControlScope(ctx, eb);
                try own_branches.append(ctx.a, .{
                    .cond_expr = ec_e,
                    .body_start = eb_res.start,
                    .body_len = eb_res.len,
                });
                short_circuit_taken = true;
                continue;
            }
        }
        const eb_res = try resolveStmtListInFlowControlScope(ctx, eb);
        try own_branches.append(ctx.a, .{
            .cond_expr = ec_e,
            .body_start = eb_res.start,
            .body_len = eb_res.len,
        });
        if (literalBoolValueForFlowControl(ctx, ec_e) == null) saw_dynamic_branch = true;
    }
    const else_extra = ctx.ast.getExtraU32(q);
    if (else_extra != std.math.maxInt(u32) and !short_circuit_taken) {
        const er = try resolveStmtListInFlowControlScope(ctx, else_extra);
        try own_branches.append(ctx.a, .{
            .cond_expr = null,
            .body_start = er.start,
            .body_len = er.len,
        });
    } else if (else_extra != std.math.maxInt(u32) and stmtListContainsContentCall(ctx.ast, else_extra)) {
        ctx.mixin_accepts_content = true;
    }
    if (own_branches.items.len == 0) return try appendNoop(ctx, span);
    const bstart: u32 = @intCast(ctx.prog.if_branches.items.len);
    for (own_branches.items) |br| {
        try ctx.prog.if_branches.append(ctx.a, br);
    }
    const br_count: u32 = @intCast(own_branches.items.len);
    const idx: StmtIndex = @intCast(ctx.prog.stmts.items.len);
    const iidx: u32 = @intCast(ctx.prog.if_stmts.items.len);
    try ctx.prog.if_stmts.append(ctx.a, .{ .branches_start = bstart, .branches_count = br_count });
    try ctx.prog.stmts.append(ctx.a, .{
        .kind = .if_chain,
        .payload = iidx,
        .span = span,
        .origin_id = ctx.currentOrigin(),
    });
    return idx;
}

fn resolveForStmt(ctx: *Ctx, n: AstNode, span: Span) ResolveError!StmtIndex {
    const off: ExtraIndex = n.payload;
    const var_id: InternId = @enumFromInt(ctx.ast.getExtraU32(off));
    const from_n: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(off + 1));
    const to_n: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(off + 2));
    const body_ex = ctx.ast.getExtraU32(off + 3);
    const through = (n.flags & 1) == 0;
    try validateStaticForBounds(ctx, from_n, to_n);
    try ctx.pushScope(ctx.a);
    errdefer ctx.popScope(ctx.a);
    ctx.currentScopeFlags().is_flow_control = true;
    // Prevent local allocators from colliding with global prefixes, regardless of nesting position.
    if (!ctx.in_callable and ctx.next_local_slot < ctx.prog.next_global_slot) {
        ctx.next_local_slot = ctx.prog.next_global_slot;
    }
    const slot = try ctx.declareLocal(var_id);
    const cursor_slot = try ctx.declareLocal(try ctx.pool.intern("__zsass_for_cursor"));
    const to_slot = try ctx.declareLocal(try ctx.pool.intern("__zsass_for_to"));
    const step_slot = try ctx.declareLocal(try ctx.pool.intern("__zsass_for_step"));
    const fe = try resolveExpr(ctx.ast, ctx, from_n);
    const te = try resolveExpr(ctx.ast, ctx, to_n);
    const body = try resolveStmtListInFlowControl(ctx, body_ex);
    const raw_for_body = readChildList(ctx.ast, body_ex);
    var fb_start = body.start;
    var fb_len = body.len;
    // style rule stacks child stmt first, parent rule statement last. If there is a single AST child and the last sentence is .rule, the body is only that one statement.
    if (raw_for_body.len == 1) {
        const last_si: StmtIndex = @intCast(ctx.prog.stmts.items.len - 1);
        if (ctx.prog.stmts.items[last_si].kind == .rule) {
            fb_start = last_si;
            fb_len = 1;
        }
    }
    ctx.popScope(ctx.a);
    const idx: StmtIndex = @intCast(ctx.prog.stmts.items.len);
    const fidx: u32 = @intCast(ctx.prog.for_stmts.items.len);
    try ctx.prog.for_stmts.append(ctx.a, .{
        .slot = slot,
        .cursor_slot = cursor_slot,
        .to_slot = to_slot,
        .step_slot = step_slot,
        .from_expr = fe,
        .to_expr = te,
        .through = through,
        .body_start = fb_start,
        .body_len = fb_len,
    });
    try ctx.prog.stmts.append(ctx.a, .{
        .kind = .for_loop,
        .payload = fidx,
        .span = span,
        .origin_id = ctx.currentOrigin(),
    });
    return idx;
}

fn resolveEachStmt(ctx: *Ctx, n: AstNode, span: Span) ResolveError!StmtIndex {
    const off: ExtraIndex = n.payload;
    const var_count = ctx.ast.getExtraU32(off);
    var q: ExtraIndex = off + 1;
    const slot_start: u32 = @intCast(ctx.prog.each_slots.items.len);
    try ctx.pushScope(ctx.a);
    errdefer ctx.popScope(ctx.a);
    ctx.currentScopeFlags().is_flow_control = true;
    if (!ctx.in_callable and ctx.next_local_slot < ctx.prog.next_global_slot) {
        ctx.next_local_slot = ctx.prog.next_global_slot;
    }
    const var_ids_start = q;
    var after_vars = q;
    var scan_vi: u32 = 0;
    while (scan_vi < var_count) : (scan_vi += 1) {
        after_vars += 1;
    }
    const list_n: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(after_vars));
    const body_ex = ctx.ast.getExtraU32(after_vars + 1);
    const le = try resolveExpr(ctx.ast, ctx, list_n);

    q = var_ids_start;
    var vi: u32 = 0;
    while (vi < var_count) : (vi += 1) {
        const vid: InternId = @enumFromInt(ctx.ast.getExtraU32(q));
        q += 1;
        const s = try ctx.declareLocal(vid);
        try ctx.prog.each_slots.append(ctx.a, s);
    }
    const list_temp_name = try ctx.pool.intern("__zsass_each_list");
    const index_name = try ctx.pool.intern("__zsass_each_i");
    const list_temp_slot = try ctx.declareLocal(list_temp_name);
    const index_slot = try ctx.declareLocal(index_name);
    const body = try resolveStmtListInFlowControl(ctx, body_ex);
    const raw_each_body = readChildList(ctx.ast, body_ex);
    var eb_start = body.start;
    var eb_len = body.len;
    if (raw_each_body.len == 1) {
        const last_si: StmtIndex = @intCast(ctx.prog.stmts.items.len - 1);
        if (ctx.prog.stmts.items[last_si].kind == .rule) {
            eb_start = last_si;
            eb_len = 1;
        }
    }
    ctx.popScope(ctx.a);
    const idx: StmtIndex = @intCast(ctx.prog.stmts.items.len);
    const eidx: u32 = @intCast(ctx.prog.each_stmts.items.len);
    try ctx.prog.each_stmts.append(ctx.a, .{
        .slot_start = slot_start,
        .slot_count = var_count,
        .list_temp_slot = list_temp_slot,
        .index_slot = index_slot,
        .list_expr = le,
        .body_start = eb_start,
        .body_len = eb_len,
    });
    try ctx.prog.stmts.append(ctx.a, .{
        .kind = .each_loop,
        .payload = eidx,
        .span = span,
        .origin_id = ctx.currentOrigin(),
    });
    return idx;
}

fn resolveWhileStmt(ctx: *Ctx, n: AstNode, span: Span) ResolveError!StmtIndex {
    const off: ExtraIndex = n.payload;
    const cond_n: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(off));
    const body_ex = ctx.ast.getExtraU32(off + 1);
    const ce = try resolveExpr(ctx.ast, ctx, cond_n);
    ctx.while_body_depth += 1;
    defer ctx.while_body_depth -= 1;
    const body = if (ctx.in_callable)
        try resolveStmtListInFlowControl(ctx, body_ex)
    else
        try resolveStmtListInFlowControlScope(ctx, body_ex);
    const raw_while_body = readChildList(ctx.ast, body_ex);
    var wb_start = body.start;
    var wb_len = body.len;
    if (raw_while_body.len == 1) {
        const last_si: StmtIndex = @intCast(ctx.prog.stmts.items.len - 1);
        if (ctx.prog.stmts.items[last_si].kind == .rule) {
            wb_start = last_si;
            wb_len = 1;
        }
    }
    const idx: StmtIndex = @intCast(ctx.prog.stmts.items.len);
    const widx: u32 = @intCast(ctx.prog.while_stmts.items.len);
    try ctx.prog.while_stmts.append(ctx.a, .{
        .cond_expr = ce,
        .body_start = wb_start,
        .body_len = wb_len,
    });
    try ctx.prog.stmts.append(ctx.a, .{
        .kind = .while_loop,
        .payload = widx,
        .span = span,
        .origin_id = ctx.currentOrigin(),
    });
    return idx;
}

fn resolveStmt(ctx: *Ctx, node: NodeIndex) ResolveError!StmtIndex {
    const n = ctx.ast.getNode(node);
    const span = Span{ .start = n.span_start, .end = n.span_end };
    // CLI-FIX-E Step 2: When an error occurs, record the most recent stmt span in thread-local.
    errdefer |err| {
        error_format.recordErrorSpanIfUnset(span.start, span.end, 0);
        error_format.recordErrorTag(err);
    }
    const in_plain_css_module = isPlainCssStylesheetPath(ctx.module_path);
    const is_top_level_stmt = ctx.scopes.items.len == 0 and ctx.nested_stmt_depth == 0;
    if (is_top_level_stmt) {
        const keeps_module_directive_open = module_directive.topLevelStmtKeepsModuleDirectiveOpen(ctx.ast, ctx.pool, n);
        if (!keeps_module_directive_open) ctx.module_directive_locked = true;
    }
    if (in_plain_css_module) {
        switch (n.tag) {
            .stmt_variable_decl,
            .stmt_use,
            .stmt_forward,
            .stmt_return,
            .stmt_if,
            .stmt_for,
            .stmt_each,
            .stmt_while,
            .stmt_include_rule,
            .stmt_error,
            .stmt_debug,
            .stmt_warn,
            .stmt_mixin_decl,
            .stmt_function_decl,
            .stmt_at_root,
            .stmt_content,
            .stmt_extend,
            => return error.SassError,
            .stmt_comment => {
                const start: usize = @min(ctx.ast.source.len, @as(usize, span.start));
                const end: usize = @min(ctx.ast.source.len, @as(usize, span.end));
                if (end > start) {
                    const raw = ctx.ast.source[start..end];
                    if (std.mem.startsWith(u8, std.mem.trimStart(u8, raw, " \t\r\n"), "//")) {
                        return error.SassError;
                    }
                }
            },
            else => {},
        }
    }
    switch (n.tag) {
        .stmt_comment => return try resolveCommentStmt(ctx, span),
        .stmt_declaration => return try resolveDeclarationStmt(ctx, n, span, in_plain_css_module),
        .stmt_style_rule => return try resolveStyleRuleStmt(ctx, n, span),
        .stmt_variable_decl => return try resolveVariableDeclStmt(ctx, n, span),
        .stmt_return => return try resolveReturnStmt(ctx, n, span),
        .stmt_if => return try resolveIfStmt(ctx, n, span),
        .stmt_for => return try resolveForStmt(ctx, n, span),
        .stmt_each => return try resolveEachStmt(ctx, n, span),
        .stmt_while => return try resolveWhileStmt(ctx, n, span),
        .stmt_include_rule => return try resolveIncludeStmt(ctx, n, span),
        .stmt_error => return try resolveErrorStmt(ctx, n, span),
        .stmt_debug => return try resolveDebugStmt(ctx, n, span),
        .stmt_warn => return try resolveWarnStmt(ctx, n, span),
        .stmt_mixin_decl => {
            try resolveMixinDecl(ctx, n, span);
            return try appendNoop(ctx, span);
        },
        .stmt_function_decl => {
            try resolveFunctionDecl(ctx, n, span);
            return try appendNoop(ctx, span);
        },
        .stmt_use => return try module_stmt.resolveUseStmt(ctx, n, span, is_top_level_stmt, ModuleStmtDeps),
        .stmt_forward => return try module_stmt.resolveForwardStmt(ctx, n, span, is_top_level_stmt, ModuleStmtDeps),
        .stmt_at_root => return try resolveAtRootStmt(ctx, n, span),
        .stmt_content => return try resolveContentStmt(ctx, n, span),
        .stmt_extend => return try resolveExtendStmt(ctx, n, span),
        .stmt_at_rule => return try resolveAtRuleStmt(ctx, n, span),
        .stmt_import => return try module_stmt.resolveImportStmt(ctx, n, span, ModuleStmtDeps),
        else => {
            // resolveStmt only accepts stmt_* nodes in root/body child list.
            std.debug.assert(false);
            unreachable;
        },
    }
}

const ModuleStmtDeps = struct {
    pub const parseWithConfigEntries = resolverParseWithConfigEntries;
    pub const requireModuleLoader = resolverRequireModuleLoader;
    pub const requireModuleBasePath = resolverRequireModuleBasePath;
    pub const resolveUserModule = resolverResolveUserModule;
    pub const applyUseOrForwardConfig = resolverApplyUseOrForwardConfig;
    pub const collectImplicitUseConfigEntries = resolverCollectImplicitUseConfigEntries;
    pub const collectImplicitForwardConfigEntries = resolverCollectImplicitForwardConfigEntries;
    pub const applyImplicitImportConfigEntries = resolverApplyImplicitImportConfigEntries;
    pub const mergeStarUserModule = resolverMergeStarUserModule;
    pub const appendNoop = resolverAppendNoop;
    pub const resolveImportedFile = resolverResolveImportedFile;
    pub const resolveInterpolatedTextExpr = resolverResolveInterpolatedTextExpr;
    pub const appendLiteralExprPart = resolverAppendLiteralExprPart;
    pub const finishConcatExprParts = resolverFinishConcatExprParts;
    pub const appendExpr = resolverAppendExpr;
    pub const packLiteralStringPayload = resolverPackLiteralStringPayload;
    pub const markInterpExprErrorOnUndeclaredVar = resolverMarkInterpExprErrorOnUndeclaredVar;
    pub const appendStringLiteralExpr = resolverAppendStringLiteralExpr;
    pub const appendTextExprParts = resolverAppendTextExprParts;
    pub const parseSubExpr = resolverParseSubExpr;
    pub const resolveMediaParenExpression = resolverResolveMediaParenExpression;
    pub const findMatchingParenSimple = resolverFindMatchingParenSimple;
    pub const resolverStderrPrint = resolverResolverStderrPrint;
    pub const captureImportConfigSnapshot = resolverCaptureImportConfigSnapshot;
    pub const snapshotStringMap = resolverSnapshotStringMap;
    pub const restoreStringMap = resolverRestoreStringMap;
    pub const predeclareTopLevelCallables = resolverPredeclareTopLevelCallables;
    pub const resolveRootStmtSequence = resolverResolveRootStmtSequence;
    pub const mergeForwardRuleIntoImportScope = resolverMergeForwardRuleIntoImportScope;
};

const resolverParseWithConfigEntries = parseWithConfigEntries;
const resolverRequireModuleLoader = requireModuleLoader;
const resolverRequireModuleBasePath = requireModuleBasePath;
const resolverResolveUserModule = resolveUserModule;
const resolverApplyUseOrForwardConfig = applyUseOrForwardConfig;
const resolverCollectImplicitUseConfigEntries = collectImplicitUseConfigEntries;
const resolverCollectImplicitForwardConfigEntries = collectImplicitForwardConfigEntries;
const resolverApplyImplicitImportConfigEntries = applyImplicitImportConfigEntries;
const resolverMergeStarUserModule = mergeStarUserModule;
const resolverAppendNoop = appendNoop;
const resolverResolveImportedFile = resolveImportedFile;
const resolverResolveInterpolatedTextExpr = resolveInterpolatedTextExpr;
const resolverAppendLiteralExprPart = appendLiteralExprPart;
const resolverFinishConcatExprParts = finishConcatExprParts;
const resolverAppendExpr = appendExpr;
const resolverPackLiteralStringPayload = packLiteralStringPayload;
const resolverMarkInterpExprErrorOnUndeclaredVar = markInterpExprErrorOnUndeclaredVar;
const resolverAppendStringLiteralExpr = appendStringLiteralExpr;
const resolverAppendTextExprParts = appendTextExprParts;
const resolverParseSubExpr = parseSubExpr;
const resolverResolveMediaParenExpression = resolveMediaParenExpression;
const resolverFindMatchingParenSimple = findMatchingParenSimple;
const resolverResolverStderrPrint = resolverStderrPrint;
const resolverCaptureImportConfigSnapshot = captureImportConfigSnapshot;
const resolverSnapshotStringMap = snapshotStringMap;
const resolverRestoreStringMap = restoreStringMap;
const resolverPredeclareTopLevelCallables = predeclareTopLevelCallables;
const resolverResolveRootStmtSequence = resolveRootStmtSequence;
const resolverMergeForwardRuleIntoImportScope = mergeForwardRuleIntoImportScope;

const ast_text = @import("ast_text.zig");
const astTextNodeHasInterpolation = ast_text.astTextNodeHasInterpolation;
const astTextNodeStaticText = ast_text.astTextNodeStaticText;
const astTextNodeRawAlloc = ast_text.astTextNodeRawAlloc;
const readChildList = ast_text.readChildList;
const buildLineStarts = ast_text.buildLineStarts;
const module_resolver_state = @import("module_resolver_state.zig");
const bindRecordsToSelf = module_resolver_state.bindRecordsToSelf;
const bindRecordsToPersistent = module_resolver_state.bindRecordsToPersistent;
const deinitAll = module_resolver_state.deinitAll;
const isVisiting = module_resolver_state.isVisiting;

const isPlainCssImport = import_css.isPlainCssImport;
const stripOuterQuotes = import_css.stripOuterQuotes;
const identifierEqSass = names.identifierEqSass;
const defaultNamespaceForUse = names.defaultNamespaceForUse;
const forwardMatchesVarToken = names.forwardMatchesVarToken;
const forwardMatchesPlainToken = names.forwardMatchesPlainToken;
const forwardAllowsVar = names.forwardAllowsVar;
const forwardAllowsPlain = names.forwardAllowsPlain;
const withForwardPrefix = names.withForwardPrefix;
pub const resolveUserModulePath = path_resolution.resolveUserModulePath;
const resolveImportModulePathWithPolicy = path_resolution.resolveImportModulePathWithPolicy;
const test_only_path_resolver = path_resolution.test_only_path_resolver;
const isPlainCssStylesheetPath = path_resolution.isPlainCssStylesheetPath;

fn resolveImportedFile(ctx: *Ctx, url: []const u8, span: Span) ResolveError!StmtIndex {
    return module_import_inline.resolveImportedFile(ctx, url, span, ModuleStmtDeps);
}

fn resolveAtRuleStmt(ctx: *Ctx, n: AstNode, span: Span) ResolveError!StmtIndex {
    return stmt_at_rule.resolveAtRuleStmt(ctx, n, span, AtRuleStmtDeps);
}

fn resolveAtRootStmt(ctx: *Ctx, n: AstNode, span: Span) ResolveError!StmtIndex {
    return stmt_at_rule.resolveAtRootStmt(ctx, n, span, AtRuleStmtDeps);
}

const AtRuleStmtDeps = struct {
    pub const validateAtRuleNameInterpolation = resolverValidateAtRuleNameInterpolation;
    pub const resolveInterpolatedTextExpr = resolverResolveInterpolatedTextExpr;
    pub const collapseStaticTextExprToIntern = resolverCollapseStaticTextExprToIntern;
    pub const mediaPreludeNeedsEvaluation = resolverMediaPreludeNeedsEvaluation;
    pub const resolveMediaPreludeExpr = resolverResolveMediaPreludeExpr;
    pub const resolveSupportsPreludeExpr = resolverResolveSupportsPreludeExpr;
    pub const resolveExpr = resolverResolveExpr;
    pub const appendExpr = resolverAppendExpr;
    pub const packLiteralStringPayload = resolverPackLiteralStringPayload;
    pub const resolveStmt = resolverResolveStmt;
    pub const appendNoop = resolverAppendNoop;
};

const resolverValidateAtRuleNameInterpolation = validateAtRuleNameInterpolation;
const resolverCollapseStaticTextExprToIntern = collapseStaticTextExprToIntern;
const resolverMediaPreludeNeedsEvaluation = mediaPreludeNeedsEvaluation;
const resolverResolveMediaPreludeExpr = resolveMediaPreludeExpr;
const resolverResolveSupportsPreludeExpr = resolveSupportsPreludeExpr;
const resolverResolveExpr = resolveExpr;
const resolverResolveStmt = resolveStmt;

fn resolveContentBlock(ctx: *Ctx, using_extra: u32, body_extra: u32) ResolveError!u32 {
    return stmt_content.resolveContentBlock(ctx, using_extra, body_extra, ContentStmtDeps);
}

fn resolveContentStmt(ctx: *Ctx, n: AstNode, span: Span) ResolveError!StmtIndex {
    return stmt_content.resolveContentStmt(ctx, n, span, ContentStmtDeps);
}

fn stmtListContainsContentCall(ast: *const ast_flat.Ast, body_extra: u32) bool {
    return stmt_content.stmtListContainsContentCall(ast, body_extra);
}

const ContentStmtDeps = struct {
    pub const resolveExpr = resolverResolveExpr;
    pub const resolveStmt = resolverResolveStmt;
    pub const appendCallArgsWithNames = resolverAppendCallArgsWithNames;
};

const resolverAppendCallArgsWithNames = appendCallArgsWithNames;

fn predeclareGlobalSlotsInStmtList(ctx: *Ctx, body_extra: u32) ResolveError!void {
    if (body_extra == std.math.maxInt(u32)) return;
    const raw = readChildList(ctx.ast, body_extra);
    for (raw) |u| {
        try predeclareGlobalSlotsInStmt(ctx, @enumFromInt(u));
    }
}

fn predeclareGlobalSlotsInStmt(ctx: *Ctx, node: NodeIndex) ResolveError!void {
    const n = ctx.ast.getNode(node);
    switch (n.tag) {
        .stmt_variable_decl => {
            const off: ExtraIndex = n.payload;
            const name_id: InternId = @enumFromInt(ctx.ast.getExtraU32(off));
            const flags = ctx.ast.getExtraU32(off + 2);
            if ((flags & 0b0000_0010) == 0) return;
            const name = ctx.pool.get(name_id);
            try ctx.markDeclaredGlobal(name_id);
            if (lookupGlobalSlot(ctx.prog, name) != null) return;
            _ = try ctx.declareGlobal(name_id);
        },
        .stmt_if => {
            const off: ExtraIndex = n.payload;
            try predeclareGlobalSlotsInStmtList(ctx, ctx.ast.getExtraU32(off + 1));
            const elseif_count = ctx.ast.getExtraU32(off + 2);
            var q: ExtraIndex = off + 3;
            var ei: u32 = 0;
            while (ei < elseif_count) : (ei += 1) {
                q += 1; // cond expr
                try predeclareGlobalSlotsInStmtList(ctx, ctx.ast.getExtraU32(q));
                q += 1;
            }
            try predeclareGlobalSlotsInStmtList(ctx, ctx.ast.getExtraU32(q));
        },
        else => {},
    }
}

fn resolveExtendStmt(ctx: *Ctx, n: AstNode, span: Span) ResolveError!StmtIndex {
    const off: ExtraIndex = n.payload;
    const sel_n: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(off));
    const sel_node = ctx.ast.getNode(sel_n);
    const raw_sel = if (sel_node.tag == .expr_unquoted_ident)
        std.mem.trim(u8, ctx.pool.get(@as(InternId, @enumFromInt(sel_node.payload))), " \t\r\n")
    else blk: {
        const raw = exprNodeSourceText(ctx.ast, sel_n) orelse return error.SassError;
        break :blk std.mem.trim(u8, raw, " \t\r\n");
    };
    if (raw_sel.len == 0) return try appendNoop(ctx, span);
    var normalized_sel_buf: ?[]u8 = null;
    defer if (normalized_sel_buf) |buf| ctx.a.free(buf);
    const sel_for_extend = blk: {
        if (std.mem.indexOfAny(u8, raw_sel, "\r\n") == null) break :blk raw_sel;
        const buf = try ctx.a.alloc(u8, raw_sel.len);
        normalized_sel_buf = buf;
        for (raw_sel, 0..) |ch, i| {
            buf[i] = switch (ch) {
                '\r', '\n', '\t' => ' ',
                else => ch,
            };
        }
        break :blk std.mem.trim(u8, buf, " \t");
    };

    const target_expr = try resolveExpr(ctx.ast, ctx, sel_n);
    const tex = ctx.prog.exprs.items[target_expr];
    // @extend target selectors should stay literal unless they contain interpolation.
    // Generic expression resolvers can reinterpret multiline selector text.
    const has_interp = std.mem.indexOf(u8, sel_for_extend, "#{") != null;
    const target_id = if (!has_interp)
        try ctx.pool.intern(sel_for_extend)
    else if (tex.kind == .literal_string)
        unpackLiteralStringPayload(tex.payload).id
    else
        InternId.none;
    var dynamic_parts_start: u32 = 0;
    var dynamic_parts_count: u32 = 0;
    if (target_id == .none) {
        const stored = try appendDynamicTextExprParts(ctx, &ctx.prog.selector_part_exprs, target_expr);
        dynamic_parts_start = stored.start;
        dynamic_parts_count = stored.count;
    }

    const target_module: u32 = local_module_id_sentinel;
    const idx: StmtIndex = @intCast(ctx.prog.stmts.items.len);
    const eidx: u32 = @intCast(ctx.prog.extend_stmts.items.len);
    try ctx.prog.extend_stmts.append(ctx.a, .{
        .target_selector = target_id,
        .target_module = target_module,
        .optional = (n.flags & 1) != 0,
        .target_is_placeholder = target_id != .none and simplePlaceholderSelectorKey(sel_for_extend) != null,
        .target_dynamic = target_id == .none,
        .dynamic_parts_start = dynamic_parts_start,
        .dynamic_parts_count = dynamic_parts_count,
    });
    try ctx.prog.stmts.append(ctx.a, .{
        .kind = .extend,
        .payload = eidx,
        .span = span,
        .origin_id = ctx.currentOrigin(),
    });
    return idx;
}

const ResolvedCallArgs = struct {
    arg_start: u32,
    arg_count: u32,
};

fn resolveExprFromSourceText(ctx: *Ctx, raw_src: []const u8) ResolveError!ExprIndex {
    var sub_ast = ast_flat.Ast.init(ctx.a, raw_src, .none);
    defer sub_ast.deinit();
    var lexer = lexer_mod.Lexer.init(ctx.a, raw_src);
    defer lexer.deinit();
    const tokens = lexer.tokenize() catch return error.SassError;
    var parser = parser_mod.Parser.init(ctx.a, ctx.pool, tokens, raw_src);
    defer parser.deinit();
    parser.pos = 0;
    const expr_root = parser.parseExpression(&sub_ast) catch return error.SassError;
    var ppos = parser.pos;
    while (ppos < parser.tokens.len) {
        const t = parser.tokens[ppos].tag;
        if (t == .whitespace or t == .newline or t == .comment) {
            ppos += 1;
            continue;
        }
        break;
    }
    if (ppos < parser.tokens.len and parser.tokens[ppos].tag != .eof) return error.SassError;

    var sub_ctx = ctx.*;
    sub_ctx.ast = &sub_ast;
    return try resolveExprMaybeStaticLiteral(&sub_ast, &sub_ctx, expr_root);
}

fn resolveLegacyPlusImportantValue(ctx: *Ctx, value_source: []const u8, span: Span) ResolveError!?ExprIndex {
    _ = span;
    const trimmed = std.mem.trimEnd(u8, value_source, " \t\r\n");
    if (trimmed.len == 0) return null;
    const before_plus = blk: {
        if (trimmed[trimmed.len - 1] == '+') break :blk trimmed[0 .. trimmed.len - 1];
        if (trimmed.len > "!important".len and std.ascii.endsWithIgnoreCase(trimmed, "!important")) {
            const before_bang = std.mem.trimEnd(u8, trimmed[0 .. trimmed.len - "!important".len], " \t\r\n");
            if (before_bang.len != 0 and before_bang[before_bang.len - 1] == '+') break :blk before_bang[0 .. before_bang.len - 1];
        }
        return null;
    };
    const expr_src = std.mem.trim(u8, before_plus, " \t\r\n");
    if (expr_src.len == 0) return null;
    return try resolveExprFromSourceText(ctx, expr_src);
}

fn declarationSourceHasLegacyPlusImportant(source: []const u8, span: Span) bool {
    const start: usize = @min(source.len, @as(usize, span.start));
    const end: usize = @min(source.len, @as(usize, span.end));
    if (end <= start) return false;
    const text = std.mem.trimEnd(u8, source[start..end], " \t\r\n;}");
    if (text.len <= "!important".len) return false;
    if (!std.ascii.endsWithIgnoreCase(text, "!important")) return false;
    const before_bang = std.mem.trimEnd(u8, text[0 .. text.len - "!important".len], " \t\r\n");
    return before_bang.len != 0 and before_bang[before_bang.len - 1] == '+';
}

fn resolveIncludeArgsFromSource(ctx: *Ctx, inner_src: []const u8) ResolveError!ResolvedCallArgs {
    if (inner_src.len == 0) {
        return .{ .arg_start = 0, .arg_count = 0 };
    }

    const fake_call_src = try std.fmt.allocPrint(ctx.a, "__zsass_include({s})", .{inner_src});
    var sub_ast = ast_flat.Ast.init(ctx.a, fake_call_src, .none);
    defer sub_ast.deinit();
    var lexer = lexer_mod.Lexer.init(ctx.a, fake_call_src);
    defer lexer.deinit();
    const tokens = lexer.tokenize() catch return error.SassError;
    var parser = parser_mod.Parser.init(ctx.a, ctx.pool, tokens, fake_call_src);
    defer parser.deinit();
    parser.pos = 0;
    const expr_root = parser.parseExpression(&sub_ast) catch return error.SassError;
    var ppos = parser.pos;
    while (ppos < parser.tokens.len) {
        const t = parser.tokens[ppos].tag;
        if (t == .whitespace or t == .newline or t == .comment) {
            ppos += 1;
            continue;
        }
        break;
    }
    if (ppos < parser.tokens.len and parser.tokens[ppos].tag != .eof) return error.SassError;

    const root = sub_ast.getNode(expr_root);
    if (root.tag != .expr_func_call) return error.SassError;

    var sub_ctx = ctx.*;
    sub_ctx.ast = &sub_ast;

    const off: ExtraIndex = root.payload;
    const argc = sub_ast.getExtraU32(off + 2);
    var args: std.ArrayListUnmanaged(ExprIndex) = .empty;
    defer args.deinit(ctx.a);
    var arg_names: std.ArrayListUnmanaged(InternId) = .empty;
    defer arg_names.deinit(ctx.a);
    const arg_nodes_start: ExtraIndex = off + 3;
    const arg_names_start: ExtraIndex = arg_nodes_start + argc;
    var i: u32 = 0;
    while (i < argc) : (i += 1) {
        const arg_node_index: NodeIndex = @enumFromInt(sub_ast.getExtraU32(arg_nodes_start + i));
        const raw_name: InternId = @enumFromInt(sub_ast.getExtraU32(arg_names_start + i));
        const arg_node = sub_ast.getNode(arg_node_index);
        if (arg_node.tag == .expr_splat) {
            const inner_node: NodeIndex = @enumFromInt(arg_node.payload);
            try args.append(ctx.a, try resolveExprMaybeStaticLiteral(&sub_ast, &sub_ctx, inner_node));
            try arg_names.append(ctx.a, call_arg_splat_sentinel);
            continue;
        }
        try args.append(ctx.a, try resolveExprMaybeStaticLiteral(&sub_ast, &sub_ctx, arg_node_index));
        try arg_names.append(ctx.a, raw_name);
    }

    return .{
        .arg_start = try appendCallArgsWithNames(ctx.prog, ctx.a, args.items, arg_names.items),
        .arg_count = @intCast(args.items.len),
    };
}

fn resolveIncludeStmt(ctx: *Ctx, n: AstNode, span: Span) ResolveError!StmtIndex {
    const off: ExtraIndex = n.payload;
    const name_id: InternId = @enumFromInt(ctx.ast.getExtraU32(off));
    const namespace_id: InternId = @enumFromInt(ctx.ast.getExtraU32(off + 1));
    const args_extra = ctx.ast.getExtraU32(off + 2);
    const using_extra = ctx.ast.getExtraU32(off + 3);
    const body_extra = ctx.ast.getExtraU32(off + 4);

    const raw_name_slice = ctx.pool.get(name_id);
    const unescaped_name = try css_utils.unescapeSassIdentifier(ctx.a, raw_name_slice);
    defer if (unescaped_name.ptr != raw_name_slice.ptr) ctx.a.free(unescaped_name);
    const name_slice = unescaped_name;
    if (isDoubleDashIdentifier(name_slice)) return error.Unsupported;
    var callee_module = local_module_id_sentinel;
    // SAFETY: initialized before first read in this scope.
    var mid: MixinId = undefined;
    if (namespace_id != .none) {
        const ns = ctx.pool.get(namespace_id);
        const binding = lookupUseBindingInContext(ctx, ns) orelse return error.UnknownMixin;
        switch (binding) {
            .builtin_module => |mod_name| {
                const bid = builtin_mod.resolveMixin(mod_name, name_slice) orelse return error.UnknownMixin;
                mid = builtinMixinIdToSentinel(bid) orelse return error.UnknownMixin;
                callee_module = local_module_id_sentinel;
            },
            .user_module => |mod_id| {
                const user_mixin_cache_key = packUserFunctionLookupCacheKey(mod_id, name_id);
                if (ctx.user_mixin_lookup_cache.get(user_mixin_cache_key)) |target| {
                    mid = @intCast(target.id);
                    callee_module = target.module_id;
                } else {
                    const ldr = try requireModuleLoader(ctx);
                    const ex = try requireModuleExports(ldr, mod_id);
                    if (lookupVoidFlagInsensitive(&ex.ambiguous_mixins, name_slice)) return error.SassError;
                    if (lookupIdentifierIdInsensitive(&ex.builtin_mixins, name_slice)) |bid| {
                        mid = builtinMixinIdToSentinel(bid) orelse return error.UnknownMixin;
                        callee_module = local_module_id_sentinel;
                        try ctx.user_mixin_lookup_cache.put(ctx.a, user_mixin_cache_key, .{
                            .module_id = callee_module,
                            .id = mid,
                        });
                    } else {
                        const target = lookupCallableTargetInsensitive(&ex.mixins, name_slice) orelse return error.UnknownMixin;
                        try ctx.user_mixin_lookup_cache.put(ctx.a, user_mixin_cache_key, target);
                        mid = @intCast(target.id);
                        callee_module = target.module_id;
                    }
                }
            },
        }
    } else {
        if (lookupIdentifierIdInsensitive(&ctx.prog.mixin_names, name_slice)) |local_mid| {
            if (ctx.in_callable) {
                const local_idx: usize = @intCast(local_mid);
                const local_is_resolved = local_idx < ctx.prog.mixins.items.len and
                    ctx.prog.mixins.items[local_idx].name != .none;
                if (local_is_resolved and try hasFutureTopLevelMixinDecl(ctx, name_slice, span.start)) {
                    mid = try reserveNextCallableMixinBinding(ctx, name_slice);
                } else {
                    mid = local_mid;
                }
            } else {
                mid = local_mid;
            }
            callee_module = local_module_id_sentinel;
        } else if (lookupVoidFlagInsensitive(&ctx.ambiguous_star_mixins, name_slice)) {
            return error.SassError;
        } else if (ctx.lookupStarMixin(name_slice)) |target| {
            mid = @intCast(target.id);
            callee_module = target.module_id;
        } else if (builtin_mod.resolveLegacyGlobalMixin(name_slice)) |bid| {
            mid = builtinMixinIdToSentinel(bid) orelse return error.UnknownMixin;
            callee_module = local_module_id_sentinel;
        } else if (ctx.in_callable or ctx.flow_control_depth > 0) {
            // The include may be skipped at runtime when it lives in flow
            // control (for example `@each { @if $flag { @include missing; } }`).
            // official Sass CLI reports an unknown mixin only if the branch executes, so
            // keep a provisional local id and let the compiler emit a runtime
            // error at the include site instead of failing resolution eagerly.
            // Callable bodies need the same late binding because later imports
            // or declarations can still provide the mixin before invocation.
            // record only for new insertion (state change); no-op for existing entry.
            const found_before = ctx.prog.mixin_names.contains(name_slice);
            const gop = try ctx.prog.mixin_names.getOrPut(ctx.a, name_slice);
            if (!gop.found_existing) {
                gop.key_ptr.* = try ctx.a.dupe(u8, name_slice);
                gop.value_ptr.* = ctx.next_mixin_id;
                ctx.next_mixin_id += 1;
                if (!found_before and ctx.undo_layers.items.len > 0) {
                    const top = &ctx.undo_layers.items[ctx.undo_layers.items.len - 1];
                    try top.entries.append(ctx.a, .{
                        .map_id = .prog_mixin_names,
                        .was_present = false,
                        .key = gop.key_ptr.*,
                        .prev = .{ .void_v = {} },
                    });
                }
            }
            mid = gop.value_ptr.*;
            callee_module = local_module_id_sentinel;
        } else {
            return error.UnknownMixin;
        }
    }

    var arg_start: u32 = 0;
    var arg_count: u32 = 0;
    if (args_extra != std.math.maxInt(u32)) {
        const inner = findIncludeArgsInnerSpan(ctx.ast.source, n.span_start, n.span_end) orelse return error.SassError;
        if (inner.end <= inner.start) {
            arg_count = 0;
        } else {
            const inner_src = ctx.ast.source[inner.start..inner.end];
            const resolved_args = try resolveIncludeArgsFromSource(ctx, inner_src);
            arg_start = resolved_args.arg_start;
            arg_count = resolved_args.arg_count;
        }
    }

    const content_block = try resolveContentBlock(ctx, using_extra, body_extra);

    const idx: StmtIndex = @intCast(ctx.prog.stmts.items.len);
    const iidx: u32 = @intCast(ctx.prog.include_stmts.items.len);
    try ctx.prog.include_stmts.append(ctx.a, .{
        .callee_module = callee_module,
        .mixin_id = mid,
        .callee_name = name_id,
        .capture_callers_locals = callee_module == local_module_id_sentinel and mixinCapturesCallersLocalsById(ctx, mid),
        .arg_start = arg_start,
        .arg_count = arg_count,
        .content_block = content_block,
    });
    try ctx.prog.stmts.append(ctx.a, .{
        .kind = .include,
        .payload = iidx,
        .span = span,
        .origin_id = ctx.currentOrigin(),
    });
    return idx;
}

fn findIncludeArgsInnerSpan(source: []const u8, span_start: u32, span_end: u32) ?struct { start: u32, end: u32 } {
    var p: usize = @intCast(span_start);
    const end_limit: usize = @min(source.len, @as(usize, @intCast(span_end)));
    while (p < end_limit and std.ascii.isWhitespace(source[p])) : (p += 1) {}
    if (p >= end_limit) return null;
    if (source[p] == '+') {
        p += 1;
    } else {
        if (p + "@include".len > end_limit) return null;
        if (!std.mem.startsWith(u8, source[p..end_limit], "@include")) return null;
        p += "@include".len;
    }
    while (p < end_limit and std.ascii.isWhitespace(source[p])) : (p += 1) {}
    while (p < end_limit) {
        const c = source[p];
        if (c == '\\' and p + 1 < end_limit) {
            p += 2;
            continue;
        }
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') {
            p += 1;
            continue;
        }
        break;
    }
    if (p < end_limit and source[p] == '.') {
        p += 1;
        while (p < end_limit) {
            const c = source[p];
            if (c == '\\' and p + 1 < end_limit) {
                p += 2;
                continue;
            }
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') {
                p += 1;
                continue;
            }
            break;
        }
    }
    while (p < end_limit and std.ascii.isWhitespace(source[p])) : (p += 1) {}
    if (p >= end_limit or source[p] != '(') return null;
    const inner_start: u32 = @intCast(p + 1);
    var depth: u32 = 1;
    p += 1;
    while (p < end_limit) : (p += 1) {
        switch (source[p]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) {
                    return .{ .start = inner_start, .end = @intCast(p) };
                }
            },
            '"', '\'' => {
                const quote = source[p];
                p += 1;
                while (p < end_limit) : (p += 1) {
                    if (source[p] == '\\' and p + 1 < end_limit) {
                        p += 1;
                    } else if (source[p] == quote) {
                        break;
                    }
                }
            },
            else => {},
        }
    }
    return null;
}

/// Push callable scope and declare parameters in-order.
/// Default expr is resolved in the 2nd pass after module resolution is completed, so only the AST node reference is retained here.
fn resolveCallableParams(
    ctx: *Ctx,
    params_extra: ExtraIndex,
    out_names: *std.ArrayListUnmanaged(InternId),
    out_slots: *std.ArrayListUnmanaged(SlotId),
    out_defaults: *std.ArrayListUnmanaged(?ExprIndex),
    out_default_nodes: *std.ArrayListUnmanaged(?NodeIndex),
    out_has_rest: *bool,
) !void {
    const ast = ctx.ast;
    const count = ast.getExtraU32(params_extra);
    const has_splat = ast.getExtraU32(params_extra + 1);
    out_has_rest.* = has_splat != 0;
    var q: ExtraIndex = params_extra + 2;

    const had_outer_scope = ctx.scopes.items.len > 0 or ctx.nested_stmt_depth > 0;
    try ctx.pushCallableScope(ctx.a);
    errdefer ctx.popScope(ctx.a);
    // Callable locals must not alias global slot indices (0..next_global_slot),
    // If there is an outer scope capture, maintain that slot bandwidth.
    if (had_outer_scope) {
        if (ctx.next_local_slot < ctx.prog.next_global_slot) {
            ctx.next_local_slot = ctx.prog.next_global_slot;
        }
    } else {
        ctx.next_local_slot = ctx.prog.next_global_slot;
    }

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const raw_name_id: InternId = @enumFromInt(ast.getExtraU32(q));
        q += 1;
        const def_or_max = ast.getExtraU32(q);
        q += 1;
        const name_id = try internIdentifierDashCanonical(ctx.pool, ctx.a, raw_name_id);
        try out_names.append(ctx.a, name_id);
        const slot = try ctx.declareLocal(name_id);
        try out_slots.append(ctx.a, slot);
        const is_rest_param = has_splat != 0 and i + 1 == count;
        if (is_rest_param or def_or_max == std.math.maxInt(u32)) {
            try out_defaults.append(ctx.a, null);
            try out_default_nodes.append(ctx.a, null);
        } else {
            try out_defaults.append(ctx.a, null);
            try out_default_nodes.append(ctx.a, @enumFromInt(def_or_max));
        }
    }
}

fn dupExprNodeTextTrimmed(ctx: *Ctx, node_idx: NodeIndex) ![]const u8 {
    const n = ctx.ast.getNode(node_idx);
    const start: usize = @min(ctx.ast.source.len, @as(usize, n.span_start));
    const end: usize = @min(ctx.ast.source.len, @as(usize, n.span_end));
    if (end <= start) return try ctx.a.dupe(u8, "");
    const trimmed = std.mem.trim(u8, ctx.ast.source[start..end], " \t\r\n");
    return try ctx.a.dupe(u8, trimmed);
}

fn queueCallableDefaultNodes(
    ctx: *Ctx,
    kind: PendingCallableDefaultKind,
    callable_id: u32,
    default_nodes: []const ?NodeIndex,
) !void {
    var captured_use_bindings: ?[]const PendingUseBinding = null;
    for (default_nodes, 0..) |maybe_node, i| {
        const node = maybe_node orelse continue;
        const text = try dupExprNodeTextTrimmed(ctx, node);
        const use_bindings = captured_use_bindings orelse blk: {
            const snap = try snapshotStringMap(UseBinding, ctx.a, &ctx.prog.use_map);
            captured_use_bindings = snap;
            break :blk snap;
        };
        try ctx.pending_callable_defaults.append(ctx.a, .{
            .kind = kind,
            .callable_id = callable_id,
            .param_index = @intCast(i),
            .expr_text = text,
            .use_bindings = use_bindings,
        });
    }
}

fn resolveDeferredCallableDefaultExpr(
    ctx: *Ctx,
    expr_text: []const u8,
    use_bindings: []const PendingUseBinding,
    param_names: []const InternId,
    param_slots: []const SlotId,
    param_index: u32,
) ResolveError!ExprIndex {
    try ctx.pushTransientExprScope(ctx.a);
    defer ctx.popTransientExprScope(ctx.a);

    const names_len = @min(param_names.len, param_slots.len);
    const visible_count: usize = @min(@as(usize, @intCast(param_index)), names_len);
    var i: usize = 0;
    while (i < visible_count) : (i += 1) {
        const name = ctx.pool.get(param_names[i]);
        try ctx.currentScope().put(ctx.a, name, param_slots[i]);
    }

    // Since callable default is a prerequisite for call-time evaluation, here we use it as callable context.
    // Resolve (unresolved global references pre-reserve slot and evaluate later).
    const saved_in_callable = ctx.in_callable;
    ctx.in_callable = true;
    defer ctx.in_callable = saved_in_callable;

    // Suppress static materialization of cross-module var refs so
    // map/list-valued defaults (e.g. `$max-widths: $container-max-widths`)
    // stay as cross_var_ref and the compiler can encode them as
    // ParamDefault.cross_slot (evaluated at call time from module globals).
    const saved_resolving_default = ctx.resolving_callable_default;
    ctx.resolving_callable_default = true;
    defer ctx.resolving_callable_default = saved_resolving_default;

    const saved_use_bindings = ctx.deferred_callable_default_use_bindings;
    ctx.deferred_callable_default_use_bindings = use_bindings;
    defer ctx.deferred_callable_default_use_bindings = saved_use_bindings;

    return try parseSubExpr(ctx, expr_text, .{
        .start = 0,
        .end = @intCast(expr_text.len),
    });
}

fn resolvePendingCallableDefaults(ctx: *Ctx) ResolveError!void {
    for (ctx.pending_callable_defaults.items) |pending| {
        const param_idx: usize = @intCast(pending.param_index);
        switch (pending.kind) {
            .mixin => {
                if (pending.callable_id >= ctx.prog.mixins.items.len) return error.Unsupported;
                var mixin = &ctx.prog.mixins.items[pending.callable_id];
                if (param_idx >= mixin.defaults.len) return error.Unsupported;
                const de = resolveDeferredCallableDefaultExpr(
                    ctx,
                    pending.expr_text,
                    pending.use_bindings,
                    mixin.param_names,
                    mixin.param_slots,
                    pending.param_index,
                ) catch |err| switch (err) {
                    error.SassError, error.UnknownVar => null,
                    else => return err,
                };
                mixin.defaults[param_idx] = de;
            },
            .function => {
                if (pending.callable_id >= ctx.prog.functions.items.len) return error.Unsupported;
                var func = &ctx.prog.functions.items[pending.callable_id];
                if (param_idx >= func.defaults.len) return error.Unsupported;
                const de = resolveDeferredCallableDefaultExpr(
                    ctx,
                    pending.expr_text,
                    pending.use_bindings,
                    func.param_names,
                    func.param_slots,
                    pending.param_index,
                ) catch |err| switch (err) {
                    error.SassError, error.UnknownVar => null,
                    else => return err,
                };
                func.defaults[param_idx] = de;
            },
        }
    }
}

fn finalizeResolvedMixins(ctx: *Ctx) ResolveError!void {
    try ensureMixinsLen(ctx, ctx.next_mixin_id);
    var unresolved_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer unresolved_names.deinit(ctx.a);

    var it = ctx.prog.mixin_names.iterator();
    while (it.next()) |entry| {
        const id: usize = @intCast(entry.value_ptr.*);
        if (id >= ctx.prog.mixins.items.len) return error.Unsupported;
        if (ctx.prog.mixins.items[id].name == .none) {
            try unresolved_names.append(ctx.a, entry.key_ptr.*);
        }
    }
    for (unresolved_names.items) |name| {
        //Normally finalize is called at the outermost (no scope), so record is no-op. Pass to maintain invariant.
        try ctx.recordMapMut(ctx.a, .prog_mixin_names, name);
        _ = ctx.prog.mixin_names.remove(name);
    }
}

fn widenCallableLocalCounts(ctx: *Ctx) void {
    const global_slots = ctx.prog.next_global_slot;
    for (ctx.prog.mixins.items) |*m| {
        if (m.local_count < global_slots) m.local_count = global_slots;
    }
    for (ctx.prog.functions.items) |*f| {
        if (f.local_count < global_slots) f.local_count = global_slots;
    }
    for (ctx.prog.content_blocks.items) |*c| {
        if (c.local_count < global_slots) c.local_count = global_slots;
    }
}

fn ensureMixinsLen(ctx: *Ctx, need_len: usize) !void {
    while (ctx.prog.mixins.items.len < need_len) {
        const next_id: MixinId = @intCast(ctx.prog.mixins.items.len);
        try ctx.prog.mixins.append(ctx.a, .{
            .id = next_id,
            .name = .none,
            .param_names = &.{},
            .param_slots = &.{},
            .defaults = &.{},
            .has_rest = false,
            .global_slot_base = 0,
            .local_count = 0,
            .body_roots = &.{},
            .accepts_content = false,
            .captures_callers_locals = false,
        });
    }
}

fn ensureFunctionsLen(ctx: *Ctx, need_len: usize) !void {
    while (ctx.prog.functions.items.len < need_len) {
        const next_id: FunctionId = @intCast(ctx.prog.functions.items.len);
        try ctx.prog.functions.append(ctx.a, .{
            .id = next_id,
            .name = .none,
            .param_names = &.{},
            .param_slots = &.{},
            .defaults = &.{},
            .has_rest = false,
            .global_slot_base = 0,
            .local_count = 0,
            .body_roots = &.{},
            .captures_callers_locals = false,
        });
    }
}

fn resolveMixinDecl(ctx: *Ctx, n: AstNode, span: Span) !void {
    if (ctx.flow_control_depth > 0 or ctx.in_callable) return error.Unsupported;
    const off: ExtraIndex = n.payload;
    const name_id: InternId = @enumFromInt(ctx.ast.getExtraU32(off));
    const params_ex = ctx.ast.getExtraU32(off + 1);
    const body_ex = ctx.ast.getExtraU32(off + 2);

    const raw_name = ctx.pool.get(name_id);
    const unescaped_name = try css_utils.unescapeSassIdentifier(ctx.a, raw_name);
    defer if (unescaped_name.ptr != raw_name.ptr) ctx.a.free(unescaped_name);
    if (isDoubleDashIdentifier(unescaped_name)) return error.Unsupported;
    const name_str = unescaped_name;
    ctx.markScopeRestoreDirty();
    // Record prev state just before mutation (was_present + old value or absent).
    try ctx.recordMapMut(ctx.a, .seen_mixin_decls, name_str);
    const seen_gop = try ctx.seen_mixin_decls.getOrPut(ctx.a, name_str);
    if (!seen_gop.found_existing) seen_gop.key_ptr.* = try ctx.a.dupe(u8, name_str);
    const pending_next_mid = popPendingNextMixinBinding(ctx, name_str);
    const mid: MixinId = blk: {
        if (pending_next_mid) |pending_mid| {
            try ctx.recordMapMut(ctx.a, .prog_mixin_names, name_str);
            const map_gop = try ctx.prog.mixin_names.getOrPut(ctx.a, name_str);
            if (!map_gop.found_existing) map_gop.key_ptr.* = try ctx.a.dupe(u8, name_str);
            map_gop.value_ptr.* = pending_mid;
            break :blk pending_mid;
        }
        try ctx.recordMapMut(ctx.a, .prog_mixin_names, name_str);
        const map_gop = try ctx.prog.mixin_names.getOrPut(ctx.a, name_str);
        if (seen_gop.found_existing) {
            const new_id = ctx.next_mixin_id;
            ctx.next_mixin_id += 1;
            if (!map_gop.found_existing) map_gop.key_ptr.* = try ctx.a.dupe(u8, name_str);
            map_gop.value_ptr.* = new_id;
            break :blk new_id;
        }
        if (!map_gop.found_existing) {
            map_gop.key_ptr.* = try ctx.a.dupe(u8, name_str);
            map_gop.value_ptr.* = ctx.next_mixin_id;
            ctx.next_mixin_id += 1;
        }
        break :blk map_gop.value_ptr.*;
    };
    const saved_next_local_slot = ctx.next_local_slot;
    defer ctx.next_local_slot = saved_next_local_slot;

    var param_names: std.ArrayListUnmanaged(InternId) = .empty;
    defer param_names.deinit(ctx.a);
    var param_slots: std.ArrayListUnmanaged(SlotId) = .empty;
    defer param_slots.deinit(ctx.a);
    var defaults: std.ArrayListUnmanaged(?ExprIndex) = .empty;
    defer defaults.deinit(ctx.a);
    var default_nodes: std.ArrayListUnmanaged(?NodeIndex) = .empty;
    defer default_nodes.deinit(ctx.a);
    var has_rest = false;
    const global_slot_base = ctx.prog.next_global_slot;
    const had_outer_scope = ctx.scopes.items.len > 0 or ctx.nested_stmt_depth > 0;

    const saved_in_callable = ctx.in_callable;
    const saved_callable_decl_context = ctx.callable_decl_context;
    const saved_mixin_accepts_content = ctx.mixin_accepts_content;
    ctx.mixin_accepts_content = false;
    if (params_ex != std.math.maxInt(u32)) {
        try resolveCallableParams(ctx, params_ex, &param_names, &param_slots, &defaults, &default_nodes, &has_rest);
    } else {
        try ctx.pushCallableScope(ctx.a);
        if (had_outer_scope) {
            if (ctx.next_local_slot < ctx.prog.next_global_slot) {
                ctx.next_local_slot = ctx.prog.next_global_slot;
            }
        } else {
            ctx.next_local_slot = ctx.prog.next_global_slot;
        }
    }
    errdefer ctx.popScope(ctx.a);
    ctx.in_callable = true;
    ctx.callable_decl_context = .mixin;
    defer {
        ctx.in_callable = saved_in_callable;
        ctx.callable_decl_context = saved_callable_decl_context;
        ctx.mixin_accepts_content = saved_mixin_accepts_content;
    }
    const raw_body = readChildList(ctx.ast, body_ex);
    const roots_buf = try ctx.prog.arena.allocator().alloc(StmtIndex, raw_body.len);
    for (raw_body, 0..) |u, i| {
        roots_buf[i] = try resolveStmt(ctx, @enumFromInt(u));
    }
    const local_count = ctx.next_local_slot;
    ctx.popScope(ctx.a);

    const pn = try ctx.prog.arena.allocator().dupe(InternId, param_names.items);
    const ps = try ctx.prog.arena.allocator().dupe(SlotId, param_slots.items);
    const ds = try ctx.prog.arena.allocator().dupe(?ExprIndex, defaults.items);

    const resolved: ResolvedMixin = .{
        .id = mid,
        .name = name_id,
        .param_names = pn,
        .param_slots = ps,
        .defaults = ds,
        .has_rest = has_rest,
        .global_slot_base = global_slot_base,
        .local_count = local_count,
        .body_roots = roots_buf,
        .accepts_content = ctx.mixin_accepts_content,
        .captures_callers_locals = had_outer_scope,
    };
    try ensureMixinsLen(ctx, @as(usize, @intCast(mid)) + 1);
    ctx.prog.mixins.items[mid] = resolved;
    reserveGlobalSlotPrefix(ctx, local_count);
    try queueCallableDefaultNodes(ctx, .mixin, mid, default_nodes.items);
    _ = span;
}

fn resolveFunctionDecl(ctx: *Ctx, n: AstNode, span: Span) !void {
    if (ctx.flow_control_depth > 0 or ctx.in_callable) return error.Unsupported;
    const off: ExtraIndex = n.payload;
    const name_id: InternId = @enumFromInt(ctx.ast.getExtraU32(off));
    const params_ex = ctx.ast.getExtraU32(off + 1);
    const body_ex = ctx.ast.getExtraU32(off + 2);

    const raw_name = ctx.pool.get(name_id);
    const unescaped_name = try css_utils.unescapeSassIdentifier(ctx.a, raw_name);
    defer if (unescaped_name.ptr != raw_name.ptr) ctx.a.free(unescaped_name);
    if (isReservedFunctionName(unescaped_name)) return error.Unsupported;
    const name_str = unescaped_name;
    ctx.markScopeRestoreDirty();
    try ctx.recordMapMut(ctx.a, .seen_function_decls, name_str);
    const seen_gop = try ctx.seen_function_decls.getOrPut(ctx.a, name_str);
    if (!seen_gop.found_existing) seen_gop.key_ptr.* = try ctx.a.dupe(u8, name_str);
    const fid: FunctionId = blk: {
        try ctx.recordMapMut(ctx.a, .prog_function_names, name_str);
        const map_gop = try ctx.prog.function_names.getOrPut(ctx.a, name_str);
        if (seen_gop.found_existing) {
            const new_id = ctx.next_function_id;
            ctx.next_function_id += 1;
            if (!map_gop.found_existing) map_gop.key_ptr.* = try ctx.a.dupe(u8, name_str);
            map_gop.value_ptr.* = new_id;
            break :blk new_id;
        }
        if (!map_gop.found_existing) {
            map_gop.key_ptr.* = try ctx.a.dupe(u8, name_str);
            map_gop.value_ptr.* = ctx.next_function_id;
            ctx.next_function_id += 1;
        }
        break :blk map_gop.value_ptr.*;
    };
    const saved_next_local_slot = ctx.next_local_slot;
    defer ctx.next_local_slot = saved_next_local_slot;

    var param_names: std.ArrayListUnmanaged(InternId) = .empty;
    defer param_names.deinit(ctx.a);
    var param_slots: std.ArrayListUnmanaged(SlotId) = .empty;
    defer param_slots.deinit(ctx.a);
    var defaults: std.ArrayListUnmanaged(?ExprIndex) = .empty;
    defer defaults.deinit(ctx.a);
    var default_nodes: std.ArrayListUnmanaged(?NodeIndex) = .empty;
    defer default_nodes.deinit(ctx.a);
    var has_rest = false;
    const global_slot_base = ctx.prog.next_global_slot;
    const had_outer_scope = ctx.scopes.items.len > 0 or ctx.nested_stmt_depth > 0;

    try resolveCallableParams(ctx, params_ex, &param_names, &param_slots, &defaults, &default_nodes, &has_rest);
    errdefer ctx.popScope(ctx.a);
    const saved_in_callable = ctx.in_callable;
    const saved_callable_decl_context = ctx.callable_decl_context;
    ctx.in_callable = true;
    ctx.callable_decl_context = .function;
    defer {
        ctx.in_callable = saved_in_callable;
        ctx.callable_decl_context = saved_callable_decl_context;
    }
    const raw_fn_body = readChildList(ctx.ast, body_ex);
    const fn_roots = try ctx.prog.arena.allocator().alloc(StmtIndex, raw_fn_body.len);
    for (raw_fn_body, 0..) |u, i| {
        fn_roots[i] = try resolveStmt(ctx, @enumFromInt(u));
    }
    const local_count = ctx.next_local_slot;
    ctx.popScope(ctx.a);

    const pn = try ctx.prog.arena.allocator().dupe(InternId, param_names.items);
    const ps = try ctx.prog.arena.allocator().dupe(SlotId, param_slots.items);
    const ds = try ctx.prog.arena.allocator().dupe(?ExprIndex, defaults.items);

    const resolved: ResolvedFunction = .{
        .id = fid,
        .name = name_id,
        .param_names = pn,
        .param_slots = ps,
        .defaults = ds,
        .has_rest = has_rest,
        .global_slot_base = global_slot_base,
        .local_count = local_count,
        .body_roots = fn_roots,
        .captures_callers_locals = had_outer_scope,
    };
    try ensureFunctionsLen(ctx, @as(usize, @intCast(fid)) + 1);
    ctx.prog.functions.items[fid] = resolved;
    reserveGlobalSlotPrefix(ctx, local_count);
    try queueCallableDefaultNodes(ctx, .function, fid, default_nodes.items);
    _ = span;
}

const ResolvedModuleTemp = struct {
    prog: ResolvedProgram,
    forward_rules: []const ForwardRuleResolved,
};

fn predeclareTopLevelCallables(ctx: *Ctx, raw_children: []const u32) !void {
    for (raw_children) |u| {
        const n = ctx.ast.getNode(@enumFromInt(u));
        switch (n.tag) {
            // top-level `meta.variable-exists()`
            // before declaration must observe "not declared yet", even when module is configured via `with`.
            // Predeclare preempting the variable slot breaks this observation, so limit it to callable preregistration only.
            .stmt_variable_decl => {},
            .stmt_mixin_decl => {
                const name_id: InternId = @enumFromInt(ctx.ast.getExtraU32(n.payload));
                const raw_name = ctx.pool.get(name_id);
                const unescaped_name = try css_utils.unescapeSassIdentifier(ctx.a, raw_name);
                const name = if (unescaped_name.ptr == raw_name.ptr)
                    try ctx.a.dupe(u8, unescaped_name)
                else
                    unescaped_name;
                var keep_name = false;
                defer if (!keep_name and name.ptr != raw_name.ptr) ctx.a.free(name);
                if (ctx.prog.mixin_names.get(name)) |existing| {
                    if (existing >= ctx.next_mixin_id) ctx.next_mixin_id = existing + 1;
                } else {
                    const id: MixinId = ctx.next_mixin_id;
                    ctx.next_mixin_id += 1;
                    ctx.markScopeRestoreDirty();
                    try ctx.recordMapMut(ctx.a, .prog_mixin_names, name);
                    try ctx.prog.mixin_names.put(ctx.a, name, id);
                    keep_name = true;
                }
            },
            .stmt_function_decl => {
                const name_id: InternId = @enumFromInt(ctx.ast.getExtraU32(n.payload));
                const raw_name = ctx.pool.get(name_id);
                const unescaped_name = try css_utils.unescapeSassIdentifier(ctx.a, raw_name);
                const name = if (unescaped_name.ptr == raw_name.ptr)
                    try ctx.a.dupe(u8, unescaped_name)
                else
                    unescaped_name;
                var keep_name = false;
                defer if (!keep_name and name.ptr != raw_name.ptr) ctx.a.free(name);
                if (ctx.prog.function_names.get(name)) |existing| {
                    if (existing >= ctx.next_function_id) ctx.next_function_id = existing + 1;
                } else {
                    const id: FunctionId = ctx.next_function_id;
                    ctx.next_function_id += 1;
                    ctx.markScopeRestoreDirty();
                    try ctx.recordMapMut(ctx.a, .prog_function_names, name);
                    try ctx.prog.function_names.put(ctx.a, name, id);
                    keep_name = true;
                }
            },
            else => {},
        }
    }
}

fn importStmtIsCssOnly(ctx: *Ctx, n: AstNode) bool {
    if (n.tag != .stmt_import) return false;
    const off: ExtraIndex = n.payload;
    const url_node: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(off));
    const cond_slot = ctx.ast.getExtraU32(off + 1);
    const url_static = astTextNodeStaticText(ctx.ast, ctx.pool, url_node) orelse return true;
    const url_raw = std.mem.trim(u8, url_static, " \t\n\r");
    const url_inner = stripOuterQuotes(url_raw);
    const has_conds = cond_slot != std.math.maxInt(u32);
    return isPlainCssStylesheetPath(ctx.module_path) or has_conds or isPlainCssImport(url_raw, url_inner);
}

fn appendResolvedRootStmt(
    ctx: *Ctx,
    out: *std.ArrayListUnmanaged(StmtIndex),
    node: NodeIndex,
    merge_import_forwards: bool,
) ResolveError!void {
    const n = ctx.ast.getNode(node);
    const forward_before = ctx.forward_rules.items.len;
    const idx = try resolveStmt(ctx, node);
    if (merge_import_forwards and n.tag == .stmt_forward and ctx.forward_rules.items.len > forward_before) {
        var fi: usize = forward_before;
        while (fi < ctx.forward_rules.items.len) : (fi += 1) {
            try mergeForwardRuleIntoImportScope(ctx, ctx.forward_rules.items[fi], true);
        }
    }
    if (ctx.pending_extra_top.items.len > 0) {
        try out.ensureUnusedCapacity(ctx.a, ctx.pending_extra_top.items.len + 1);
        for (ctx.pending_extra_top.items) |ex| {
            out.appendAssumeCapacity(ex);
        }
        ctx.pending_extra_top.clearRetainingCapacity();
        out.appendAssumeCapacity(idx);
    } else {
        try out.append(ctx.a, idx);
    }
}

fn resolveRootStmtSequence(
    ctx: *Ctx,
    raw: []const u32,
    out: *std.ArrayListUnmanaged(StmtIndex),
    merge_import_forwards: bool,
) ResolveError!void {
    var i: usize = 0;
    while (i < raw.len) {
        const node: NodeIndex = @enumFromInt(raw[i]);
        const n = ctx.ast.getNode(node);
        if (n.tag != .stmt_import) {
            try appendResolvedRootStmt(ctx, out, node, merge_import_forwards);
            i += 1;
            continue;
        }

        var group_end = i + 1;
        while (group_end < raw.len) : (group_end += 1) {
            const next = ctx.ast.getNode(@enumFromInt(raw[group_end]));
            if (next.tag != .stmt_import or
                next.span_start != n.span_start or
                next.span_end != n.span_end)
            {
                break;
            }
        }

        if (group_end == i + 1) {
            try appendResolvedRootStmt(ctx, out, node, merge_import_forwards);
            i = group_end;
            continue;
        }

        var pass: usize = 0;
        while (pass < 2) : (pass += 1) {
            const want_css_only = pass == 0;
            var j: usize = i;
            while (j < group_end) : (j += 1) {
                const import_node: NodeIndex = @enumFromInt(raw[j]);
                const import_stmt = ctx.ast.getNode(import_node);
                if (importStmtIsCssOnly(ctx, import_stmt) != want_css_only) continue;
                try appendResolvedRootStmt(ctx, out, import_node, merge_import_forwards);
            }
        }

        i = group_end;
    }
}

fn resolveSingleAst(
    allocator: std.mem.Allocator,
    ast: *const ast_flat.Ast,
    intern_pool: *InternPool,
    module_path: []const u8,
    loader: ?*ModuleResolver,
    static_eval_store: *StaticEvalListStore,
    color_pool: ?*value_mod.ColorPool,
) ResolveError!ResolvedModuleTemp {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    // Shared value pool is held by loader (= MR). resolveSingleAst is assumed to be called only via MR
    //(ModuleResolver.resolveParsedModule). loader == null is unreachable because there is no legacy callsite.
    const mr = loader orelse unreachable;
    var prog = ResolvedProgram{
        .arena = arena,
        .value_number_pool = &mr.shared_value_pools.number_pool,
        .value_list_meta_pool = &mr.shared_value_pools.list_meta_pool,
        .value_string_flags_pool = &mr.shared_value_pools.string_flags_pool,
        .value_callable_payload_pool = &mr.shared_value_pools.callable_payload_pool,
    };
    errdefer prog.deinit();
    const a2 = prog.arena.allocator();
    prog.module_path = try a2.dupe(u8, module_path);
    prog.line_starts = try buildLineStarts(a2, ast.source);
    prog.source_len = @intCast(ast.source.len);

    var ctx: Ctx = .{
        .ast = ast,
        .pool = intern_pool,
        .prog = &prog,
        .a = a2,
        .root_alloc = allocator,
        .module_path = module_path,
        .loader = loader,
        .static_eval_store = static_eval_store,
        .color_pool = color_pool,
        .initial_config_entries = mr.active_initial_config_entries,
    };
    errdefer ctx.deinitScopes(a2);

    const root = ast.root;
    const root_node = ast.getNode(root);
    if (root_node.tag != .stylesheet_root) {
        // parser.parse() always returns stylesheet_root.
        unreachable;
    }
    const extra_off: ExtraIndex = root_node.payload;
    const raw = readChildList(ctx.ast, extra_off);
    ctx.next_mixin_id = @intCast(ctx.prog.mixin_names.count());
    ctx.next_function_id = @intCast(ctx.prog.function_names.count());
    try predeclareTopLevelCallables(&ctx, raw);
    var top_list: std.ArrayListUnmanaged(StmtIndex) = .empty;
    defer top_list.deinit(a2);
    try resolveRootStmtSequence(&ctx, raw, &top_list, false);
    widenCallableLocalCounts(&ctx);
    try resolvePendingCallableDefaults(&ctx);
    try finalizeResolvedMixins(&ctx);
    prog.top_stmts = try top_list.toOwnedSlice(a2);
    {
        try copyStringMapWithOwnedKeys(CrossVarTarget, a2, &prog.star_vars, &ctx.star_vars);
        try copyStringSetWithOwnedKeys(a2, &prog.ambiguous_star_vars, &ctx.ambiguous_star_vars);
        try copyStringMapWithOwnedKeys(CrossCallableTarget, a2, &prog.star_mixins, &ctx.star_mixins);
        try copyStringSetWithOwnedKeys(a2, &prog.ambiguous_star_mixins, &ctx.ambiguous_star_mixins);
        try copyStringMapWithOwnedKeys(CrossCallableTarget, a2, &prog.star_functions, &ctx.star_functions);
        try copyStringSetWithOwnedKeys(a2, &prog.ambiguous_star_functions, &ctx.ambiguous_star_functions);
        try copyStringMapWithOwnedKeys(u32, a2, &prog.star_builtin_fns, &ctx.star_builtin_fns);
    }
    const forward_rules = try ctx.forward_rules.toOwnedSlice(a2);
    ctx.deinitScopes(a2);
    return .{
        .prog = prog,
        .forward_rules = forward_rules,
    };
}

fn patchLocalModuleRefs(prog: *ResolvedProgram, module_id: u32) void {
    for (prog.call_exprs.items) |*c| {
        if (c.callee_module == local_module_id_sentinel) c.callee_module = module_id;
    }
    for (prog.include_stmts.items) |*inc| {
        if (inc.callee_module == local_module_id_sentinel) inc.callee_module = module_id;
    }
}

const module_exports = @import("module_exports.zig");
const buildModuleExports = module_exports.buildModuleExports;
const applyConfigTarget = module_exports.applyConfigTarget;
const applyUseOrForwardConfig = module_exports.applyUseOrForwardConfig;

const module_loader = @import("module_loader.zig");

fn resolveEntryAst(self: *ModuleResolver, ast: *const ast_flat.Ast, entry_path: []const u8) ResolveError!u32 {
    return module_loader.resolveEntryAst(self, ast, entry_path, resolveParsedModule);
}

fn resolveUserModule(self: *ModuleResolver, from_path: []const u8, url: []const u8) ResolveError!u32 {
    return module_loader.resolveUserModule(self, from_path, url, resolveParsedModule);
}

fn resolveParsedModule(self: *ModuleResolver, ast: *const ast_flat.Ast, module_path: []const u8) ResolveError!u32 {
    if (self.id_by_path_ptr.get(module_path)) |id| return id;
    if (isVisiting(self, module_path)) return error.UsermoduleCircular;
    try self.visiting.append(self.meta, module_path);
    defer _ = self.visiting.pop();

    // CLI-FIX-E Step 2c+: error stack frame push/pop. entry resolve is on the first push
    // label="root stylesheet", imported (= parent frame is already stacked) is label="@use".
    // dart distinguishes between @use/@forward/@import, but in Phase 1 it is fixed to @use (most callsites are @use),
    // Scheduled to be distinguished in subsequent phases. Even if the resolve is successful, pop it and return the stack to empty.
    // (stack represents only active resolve chain). In the case of an error, use the catch path of the driver.
    // Flush with clearErrorContext after reading stack.
    const _label: []const u8 = if (error_format.error_state.error_stack_len == 0) "root stylesheet" else "@use";
    error_format.pushFrame(module_path, ast.source, _label);
    defer error_format.popFrame();

    var tmp = try resolveSingleAst(self.prog_arena_alloc, ast, self.pool, module_path, self, &self.static_eval_store, self.color_pool);
    const module_id: u32 = @intCast(self.records_ptr.items.len);
    patchLocalModuleRefs(&tmp.prog, module_id);
    var exports = buildModuleExports(self.records_alloc, &tmp.prog, module_id, tmp.forward_rules, self) catch |err| {
        tmp.prog.deinit();
        return err;
    };
    {
        const a = tmp.prog.arena.allocator();
        try copyStringMapWithOwnedKeys(CallableTarget, a, &tmp.prog.exported_mixins, &exports.mixins);
        try copyStringSetWithOwnedKeys(a, &tmp.prog.ambiguous_export_mixins, &exports.ambiguous_mixins);
        try copyStringMapWithOwnedKeys(CallableTarget, a, &tmp.prog.exported_functions, &exports.functions);
        try copyStringSetWithOwnedKeys(a, &tmp.prog.ambiguous_export_functions, &exports.ambiguous_functions);
        try copyStringMapWithOwnedKeys(u32, a, &tmp.prog.exported_builtin_fns, &exports.builtin_functions);
        try copyStringMapWithOwnedKeys(VarTarget, a, &tmp.prog.exported_vars, &exports.vars);
        try copyStringSetWithOwnedKeys(a, &tmp.prog.ambiguous_export_vars, &exports.ambiguous_vars);
        try copyStringMapWithOwnedKeys(VarTarget, a, &tmp.prog.exported_default_vars, &exports.default_vars);
        try copyStringMapWithOwnedKeys(VarTarget, a, &tmp.prog.exported_default_vars, &exports.private_default_vars);
        try copyStringSetWithOwnedKeys(a, &tmp.prog.ambiguous_export_default_vars, &exports.ambiguous_default_vars);
    }
    const key = self.records_alloc.dupe(u8, module_path) catch |err| {
        exports.deinit(self.records_alloc);
        tmp.prog.deinit();
        return err;
    };

    self.records_ptr.append(self.records_alloc, .{
        .path = key,
        .prog = tmp.prog,
        .exports = exports,
    }) catch |err| {
        exports.deinit(self.records_alloc);
        tmp.prog.deinit();
        return err;
    };
    errdefer {
        var popped = self.records_ptr.pop().?;
        popped.exports.deinit(self.records_alloc);
        popped.prog.deinit();
    }
    try self.id_by_path_ptr.put(self.records_alloc, key, module_id);
    return module_id;
}

const bundle_builder = @import("bundle_builder.zig");
const buildResolvedBundleFromResolver = bundle_builder.buildResolvedBundleFromResolver;

fn resolveSingleBundleImpl(
    allocator: std.mem.Allocator,
    ast: *const ast_flat.Ast,
    intern_pool: *InternPool,
    color_pool: ?*value_mod.ColorPool,
) ResolveError!ResolvedBundle {
    const t = perf.timeBegin();
    defer perf.timeEnd(.phase_resolve_ns, t);
    perf.note(.resolve_program);
    var meta_arena = std.heap.ArenaAllocator.init(allocator);
    defer meta_arena.deinit();
    var single_static_eval_lists: std.ArrayListUnmanaged([]const value_mod.Value) = .empty;
    // Shared static-eval Value pool storage (P4 c3 retry A.2): pointer stabilization with heap alloc,
    // Transfer ownership to bundle when bundle construction is successful, free with MR.deinitAll when construction fails.
    const shared_pools = try allocator.create(SharedValuePoolStorage);
    shared_pools.* = .{};
    var mr: ModuleResolver = .{
        .alloc = allocator,
        .meta = meta_arena.allocator(),
        .pool = intern_pool,
        .color_pool = color_pool,
        .records_alloc = meta_arena.allocator(),
        .prog_arena_alloc = allocator,
        .static_eval_store = StaticEvalListStore.initOwned(meta_arena.allocator(), &single_static_eval_lists),
        // SAFETY: Set by `bindRecordsToSelf` or `bindRecordsToPersistent` before any read.
        .records_ptr = undefined,
        // SAFETY: Set by `bindRecordsToSelf` or `bindRecordsToPersistent` before any read.
        .id_by_path_ptr = undefined,
        // SAFETY: Set by `bindRecordsToSelf` or `bindRecordsToPersistent` before any read.
        .import_origins_ptr = undefined,
        .shared_value_pools = shared_pools,
        .shared_value_pools_alloc = allocator,
        .owns_shared_value_pools = true,
    };
    bindRecordsToSelf(&mr);
    var ok = false;
    defer if (!ok) deinitAll(&mr);

    const root_id = try resolveParsedModule(&mr, ast, "");
    var bundle = try buildResolvedBundleFromResolver(allocator, &mr, root_id);
    // Success path: Transfer ownership of shared pool storage to bundle.
    bundle.shared_value_pools = mr.shared_value_pools;
    bundle.shared_value_pools_alloc = mr.shared_value_pools_alloc;
    bundle.owns_shared_value_pools = true;
    mr.owns_shared_value_pools = false;
    ok = true;
    return bundle;
}

fn resolve(allocator: std.mem.Allocator, ast: *const ast_flat.Ast, intern_pool: *InternPool) ResolveError!ResolvedBundle {
    return resolveSingleBundleImpl(allocator, ast, intern_pool, null);
}

pub fn resolveWithColorPool(
    allocator: std.mem.Allocator,
    ast: *const ast_flat.Ast,
    intern_pool: *InternPool,
    color_pool: *value_mod.ColorPool,
) ResolveError!ResolvedBundle {
    return resolveSingleBundleImpl(allocator, ast, intern_pool, color_pool);
}

fn resolveWithEntryPathImpl(
    allocator: std.mem.Allocator,
    ast: *const ast_flat.Ast,
    intern_pool: *InternPool,
    entry_path: []const u8,
    load_paths: []const []const u8,
    color_pool: ?*value_mod.ColorPool,
    source_cache: ?*source_cache_mod.SharedSourceCache,
    ast_cache: ?*ast_cache_mod.ParsedAstCache,
    persistent_ctx: ?PersistentResolveContext,
    deprecation_opts: ?*deprecation_mod.DeprecationOpts,
) ResolveError!ResolvedBundle {
    const t = perf.timeBegin();
    defer perf.timeEnd(.phase_resolve_ns, t);
    perf.note(.resolve_program);
    var meta_arena = std.heap.ArenaAllocator.init(allocator);
    defer meta_arena.deinit();
    const records_alloc: std.mem.Allocator = if (persistent_ctx) |ps|
        ps.records_arena.allocator()
    else
        meta_arena.allocator();
    // child_allocator: persistent in prog.arena uses c_allocator (long-lived).
    // If arena_alloc is passed, it will be wiped by reset at the end of entry.
    const prog_arena_alloc: std.mem.Allocator = if (persistent_ctx) |ps|
        ps.alloc
    else
        allocator;
    var single_static_eval_lists: std.ArrayListUnmanaged([]const value_mod.Value) = .empty;
    const sel_store: StaticEvalListStore = if (persistent_ctx) |ps|
        StaticEvalListStore.initBorrowed(ps.records_arena.allocator(), ps.static_eval_lists)
    else
        StaticEvalListStore.initOwned(meta_arena.allocator(), &single_static_eval_lists);
    // Shared static-eval Value pool storage (P4 c3 retry A.2):
    // persistent: Owned by PersistentResolverState (shared across entries).
    // single-entry: stabilize pointer with heap alloc and transfer ownership to bundle.
    var shared_pools_owned: bool = false;
    const shared_pools_alloc: std.mem.Allocator = if (persistent_ctx) |ps| ps.alloc else allocator;
    const shared_pools_ptr: *SharedValuePoolStorage = if (persistent_ctx) |ps|
        ps.shared_value_pools
    else blk: {
        const p = try allocator.create(SharedValuePoolStorage);
        p.* = .{};
        shared_pools_owned = true;
        break :blk p;
    };
    var mr: ModuleResolver = .{
        .alloc = allocator,
        .meta = meta_arena.allocator(),
        .pool = intern_pool,
        .color_pool = color_pool,
        .load_paths = load_paths,
        .source_cache = source_cache,
        .ast_cache = ast_cache,
        .deprecation_opts = deprecation_opts,
        .records_alloc = records_alloc,
        .prog_arena_alloc = prog_arena_alloc,
        .static_eval_store = sel_store,
        // SAFETY: Set by `bindRecordsToSelf` or `bindRecordsToPersistent` before any read.
        .records_ptr = undefined,
        // SAFETY: Set by `bindRecordsToSelf` or `bindRecordsToPersistent` before any read.
        .id_by_path_ptr = undefined,
        // SAFETY: Set by `bindRecordsToSelf` or `bindRecordsToPersistent` before any read.
        .import_origins_ptr = undefined,
        .shared_value_pools = shared_pools_ptr,
        .shared_value_pools_alloc = shared_pools_alloc,
        .owns_shared_value_pools = shared_pools_owned,
    };
    if (persistent_ctx) |ps| {
        bindRecordsToPersistent(&mr, ps.records, ps.id_by_path, ps.import_origins);
    } else {
        bindRecordsToSelf(&mr);
    }
    // In cross-entry persistent mode, the module of the prior entry is treated as "unloaded" for this entry.
    // Get the baseline before resolveEntryAst and use it in the "already loaded" judgment of `@use ... with`.
    mr.entry_records_baseline = @intCast(mr.records_ptr.items.len);
    var ok = false;
    defer if (!ok) deinitAll(&mr);

    const root_id = try resolveEntryAst(&mr, ast, entry_path);
    var bundle = try buildResolvedBundleFromResolver(allocator, &mr, root_id);
    if (persistent_ctx != null) bundle.persistent_modules = true;
    // Success path: Transfer ownership of shared pool storage to bundle (single-entry only).
    // persistent means PS continues to own it, bundle.owns_shared_value_pools = false;
    bundle.shared_value_pools = mr.shared_value_pools;
    bundle.shared_value_pools_alloc = mr.shared_value_pools_alloc;
    bundle.owns_shared_value_pools = mr.owns_shared_value_pools;
    mr.owns_shared_value_pools = false;
    ok = true;
    return bundle;
}

fn resolveWithEntryPath(
    allocator: std.mem.Allocator,
    ast: *const ast_flat.Ast,
    intern_pool: *InternPool,
    entry_path: []const u8,
    load_paths: []const []const u8,
) ResolveError!ResolvedBundle {
    return resolveWithEntryPathImpl(allocator, ast, intern_pool, entry_path, load_paths, null, null, null, null, null);
}

pub fn resolveWithEntryPathAndColorPool(
    allocator: std.mem.Allocator,
    ast: *const ast_flat.Ast,
    intern_pool: *InternPool,
    entry_path: []const u8,
    load_paths: []const []const u8,
    color_pool: *value_mod.ColorPool,
) ResolveError!ResolvedBundle {
    return resolveWithEntryPathImpl(allocator, ast, intern_pool, entry_path, load_paths, color_pool, null, null, null, null);
}

pub fn resolveWithEntryPathColorPoolCachesAndPersistent(
    allocator: std.mem.Allocator,
    ast: *const ast_flat.Ast,
    intern_pool: *InternPool,
    entry_path: []const u8,
    load_paths: []const []const u8,
    color_pool: *value_mod.ColorPool,
    source_cache: ?*source_cache_mod.SharedSourceCache,
    ast_cache: ?*ast_cache_mod.ParsedAstCache,
    persistent_ctx: ?PersistentResolveContext,
    deprecation_opts: ?*deprecation_mod.DeprecationOpts,
) ResolveError!ResolvedBundle {
    return resolveWithEntryPathImpl(allocator, ast, intern_pool, entry_path, load_paths, color_pool, source_cache, ast_cache, persistent_ctx, deprecation_opts);
}

fn parseAndResolve(allocator: std.mem.Allocator, source: []const u8) !ResolvedBundle {
    // Scratch arena: owns InternPool + parse allocations. Defer runs last so ast/parser/lexer deinit first.
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();

    var lexer = lexer_mod.Lexer.init(a, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    var pool = try InternPool.init(a);
    var parser = parser_mod.Parser.init(a, &pool, tokens, source);
    defer parser.deinit();
    var ast = try parser.parse();
    defer ast.deinit();

    return try resolve(allocator, &ast, &pool);
}

fn parseAndResolveWithPath(
    allocator: std.mem.Allocator,
    source: []const u8,
    entry_path: []const u8,
) !ResolvedBundle {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();

    const is_plain_css_source = if (syntax_override_mod.get()) |over|
        over == .css
    else
        std.mem.endsWith(u8, entry_path, ".css");
    var lexer = if (is_plain_css_source)
        lexer_mod.Lexer.initPlainCss(a, source)
    else
        lexer_mod.Lexer.init(a, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();

    var pool = try InternPool.init(a);
    var parser = parser_mod.Parser.init(a, &pool, tokens, source);
    defer parser.deinit();
    var ast = try parser.parse();
    defer ast.deinit();

    return try resolveWithEntryPath(allocator, &ast, &pool, entry_path, &.{});
}

test "minimal rule + declaration" {
    var bundle = try parseAndResolve(std.testing.allocator, ".a { color: red; }");
    defer bundle.deinit();
    const pr = &bundle.modules[0];
    try std.testing.expectEqual(@as(usize, 1), pr.rule_stmts.items.len);
    try std.testing.expectEqual(@as(usize, 1), pr.decl_stmts.items.len);
}

test "mixin + include name" {
    var bundle = try parseAndResolve(std.testing.allocator,
        \\@mixin m() { color: red; }
        \\.a { @include m; }
    );
    defer bundle.deinit();
    const pr = &bundle.modules[0];
    try std.testing.expect(pr.mixin_names.get("m") != null);
    try std.testing.expectEqual(@as(usize, 1), pr.include_stmts.items.len);
}

test "interpolation in selector text resolves to dynamic rule" {
    var bundle = try parseAndResolve(std.testing.allocator,
        \\.a-#{1} { x: y; }
    );
    defer bundle.deinit();
    const pr = &bundle.modules[0];
    try std.testing.expectEqual(@as(usize, 1), pr.rule_stmts.items.len);
    try std.testing.expect(pr.rule_stmts.items[0].selector_kind == .dynamic);
    try std.testing.expect(pr.rule_stmts.items[0].dynamic_parts_count > 0);
}

test "include arg: nested comma-list keeps space-list children" {
    var bundle = try parseAndResolve(std.testing.allocator,
        \\@mixin m($v) { --x: #{$v}; }
        \\.a { @include m((0 0.5em 1em -0.125em, 0 0px 0 1px)); }
    );
    defer bundle.deinit();
    const pr = &bundle.modules[0];

    try std.testing.expectEqual(@as(usize, 1), pr.include_stmts.items.len);
    const inc = pr.include_stmts.items[0];
    try std.testing.expectEqual(@as(u32, 1), inc.arg_count);

    const arg_expr = pr.call_args.items[inc.arg_start];
    try std.testing.expect(pr.exprs.items[arg_expr].kind == .list);
    const outer = pr.list_exprs.items[pr.exprs.items[arg_expr].payload];
    try std.testing.expect(outer.separator == .comma);
    try std.testing.expect(!outer.bracketed);
    try std.testing.expectEqual(@as(u32, 2), outer.elem_count);

    const lhs = pr.list_elems.items[outer.elem_start];
    const rhs = pr.list_elems.items[outer.elem_start + 1];
    try std.testing.expect(pr.exprs.items[lhs].kind == .list);
    try std.testing.expect(pr.exprs.items[rhs].kind == .list);

    const lhs_list = pr.list_exprs.items[pr.exprs.items[lhs].payload];
    const rhs_list = pr.list_exprs.items[pr.exprs.items[rhs].payload];
    try std.testing.expect(lhs_list.separator == .space);
    try std.testing.expect(rhs_list.separator == .space);
    try std.testing.expect(!lhs_list.bracketed);
    try std.testing.expect(!rhs_list.bracketed);
    try std.testing.expectEqual(@as(u32, 4), lhs_list.elem_count);
    try std.testing.expectEqual(@as(u32, 4), rhs_list.elem_count);
}

test "list literal: empty paren list resolves to undecided separator" {
    var bundle = try parseAndResolve(std.testing.allocator, ".a { b: (); }");
    defer bundle.deinit();
    const pr = &bundle.modules[0];
    const decl = pr.decl_stmts.items[0];
    const ex = pr.exprs.items[decl.value_expr];
    try std.testing.expectEqual(ExprKind.list, ex.kind);
    const l = pr.list_exprs.items[ex.payload];
    try std.testing.expect(l.separator == .undecided);
    try std.testing.expect(!l.bracketed);
    try std.testing.expectEqual(@as(u32, 0), l.elem_count);
}

test "list literal: single bracketed scalar resolves to undecided separator" {
    var bundle = try parseAndResolve(std.testing.allocator, ".a { b: [1]; }");
    defer bundle.deinit();
    const pr = &bundle.modules[0];
    const decl = pr.decl_stmts.items[0];
    const ex = pr.exprs.items[decl.value_expr];
    try std.testing.expectEqual(ExprKind.list, ex.kind);
    const l = pr.list_exprs.items[ex.payload];
    try std.testing.expect(l.separator == .undecided);
    try std.testing.expect(l.bracketed);
    try std.testing.expectEqual(@as(u32, 1), l.elem_count);
}

test "list literal: single bracketed scalar with trailing comma resolves to comma separator" {
    var bundle = try parseAndResolve(std.testing.allocator, ".a { b: [1,]; }");
    defer bundle.deinit();
    const pr = &bundle.modules[0];
    const decl = pr.decl_stmts.items[0];
    const ex = pr.exprs.items[decl.value_expr];
    try std.testing.expectEqual(ExprKind.list, ex.kind);
    const l = pr.list_exprs.items[ex.payload];
    try std.testing.expect(l.separator == .comma);
    try std.testing.expect(l.bracketed);
    try std.testing.expectEqual(@as(u32, 1), l.elem_count);
}

test "list literal: single bracketed nested list keeps comma outer separator" {
    var bundle = try parseAndResolve(std.testing.allocator, ".a { b: [1 2]; }");
    defer bundle.deinit();
    const pr = &bundle.modules[0];
    const decl = pr.decl_stmts.items[0];
    const ex = pr.exprs.items[decl.value_expr];
    try std.testing.expectEqual(ExprKind.list, ex.kind);
    const outer = pr.list_exprs.items[ex.payload];
    try std.testing.expect(outer.separator == .comma);
    try std.testing.expect(outer.bracketed);
    try std.testing.expectEqual(@as(u32, 1), outer.elem_count);

    const child = pr.list_elems.items[outer.elem_start];
    try std.testing.expectEqual(ExprKind.list, pr.exprs.items[child].kind);
    const inner = pr.list_exprs.items[pr.exprs.items[child].payload];
    try std.testing.expect(inner.separator == .space);
}

test "slash expr: literal numbers resolve as slash-list" {
    var bundle = try parseAndResolve(std.testing.allocator, ".a { b: 255 / 0.5; }");
    defer bundle.deinit();
    const pr = &bundle.modules[0];
    const decl = pr.decl_stmts.items[0];
    const ex = pr.exprs.items[decl.value_expr];
    try std.testing.expectEqual(ExprKind.list, ex.kind);
    const l = pr.list_exprs.items[ex.payload];
    try std.testing.expect(l.separator == .slash);
    try std.testing.expectEqual(@as(u32, 2), l.elem_count);
}

test "slash expr: variable rhs stays division" {
    var bundle = try parseAndResolve(std.testing.allocator,
        \\$x: 2;
        \\.a { b: 10 / $x; }
    );
    defer bundle.deinit();
    const pr = &bundle.modules[0];
    const decl = pr.decl_stmts.items[0];
    const ex = pr.exprs.items[decl.value_expr];
    try std.testing.expectEqual(ExprKind.binary, ex.kind);
    const b = pr.binary_exprs.items[ex.payload];
    try std.testing.expectEqual(BinOp.div, b.op);
}

test "slash expr: chained literal numbers flatten slash-list" {
    var bundle = try parseAndResolve(std.testing.allocator, ".a { b: 1 / 2 / 3; }");
    defer bundle.deinit();
    const pr = &bundle.modules[0];
    const decl = pr.decl_stmts.items[0];
    const ex = pr.exprs.items[decl.value_expr];
    try std.testing.expectEqual(ExprKind.list, ex.kind);
    const l = pr.list_exprs.items[ex.payload];
    try std.testing.expect(l.separator == .slash);
    try std.testing.expectEqual(@as(u32, 3), l.elem_count);
}

test "rgb modern slash syntax keeps alpha as slash-list in channel tail" {
    var bundle = try parseAndResolve(std.testing.allocator, ".a { b: rgb(10 20 30 / 0.4); }");
    defer bundle.deinit();
    const pr = &bundle.modules[0];
    const decl = pr.decl_stmts.items[0];
    const root = pr.exprs.items[decl.value_expr];
    try std.testing.expectEqual(ExprKind.builtin_call, root.kind);
    const call = pr.builtin_calls.items[root.payload];
    try std.testing.expectEqual(@as(u32, 1), call.arg_count);

    const arg_expr = pr.call_args.items[call.arg_start];
    try std.testing.expectEqual(ExprKind.list, pr.exprs.items[arg_expr].kind);
    const outer = pr.list_exprs.items[pr.exprs.items[arg_expr].payload];
    try std.testing.expect(outer.separator == .space);
    try std.testing.expectEqual(@as(u32, 3), outer.elem_count);

    const tail_expr = pr.list_elems.items[outer.elem_start + 2];
    try std.testing.expectEqual(ExprKind.list, pr.exprs.items[tail_expr].kind);
    const tail = pr.list_exprs.items[pr.exprs.items[tail_expr].payload];
    try std.testing.expect(tail.separator == .slash);
    try std.testing.expectEqual(@as(u32, 2), tail.elem_count);
}

fn touchTmpFile(tmp_dir: *std.testing.TmpDir, rel_path: []const u8) !void {
    if (std.fs.path.dirname(rel_path)) |parent| {
        try tmp_dir.dir.createDirPath(zsass_io.io, parent);
    }
    const f = try tmp_dir.dir.createFile(zsass_io.io, rel_path, .{});
    f.close(zsass_io.io);
}

fn writeTmpFileAll(tmp_dir: *std.testing.TmpDir, rel_path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(rel_path)) |parent| {
        try tmp_dir.dir.createDirPath(zsass_io.io, parent);
    }
    const file = try tmp_dir.dir.createFile(zsass_io.io, rel_path, .{ .truncate = true });
    defer file.close(zsass_io.io);
    var fb: [4096]u8 = undefined;
    var fw = file.writerStreaming(zsass_io.io, &fb);
    try fw.interface.writeAll(bytes);
    try fw.flush();
}

test "resolveUserModulePath allows css fallback for bare @use urls" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try touchTmpFile(&tmp_dir, "fixtures/podll-only-css.css");

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const fixtures_dir = try std.fs.path.join(allocator, &.{ tmp_path, "fixtures" });
    defer allocator.free(fixtures_dir);

    const load_paths = [_][]const u8{fixtures_dir};
    const resolved = try resolveUserModulePath(allocator, "/virtual/input.scss", "podll-only-css", &load_paths, .{});
    try std.testing.expect(resolved != null);
    defer allocator.free(resolved.?);
    try std.testing.expect(std.mem.endsWith(u8, resolved.?, "fixtures/podll-only-css.css"));
}

test "resolveUserModulePath keeps Sass-first ordering over css fallback" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try touchTmpFile(&tmp_dir, "fixtures/_podll-priority.scss");
    try touchTmpFile(&tmp_dir, "fixtures/podll-priority.css");

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const fixtures_dir = try std.fs.path.join(allocator, &.{ tmp_path, "fixtures" });
    defer allocator.free(fixtures_dir);

    const load_paths = [_][]const u8{fixtures_dir};
    const resolved = try resolveUserModulePath(allocator, "/virtual/input.scss", "podll-priority", &load_paths, .{});
    try std.testing.expect(resolved != null);
    defer allocator.free(resolved.?);
    try std.testing.expect(std.mem.endsWith(u8, resolved.?, "fixtures/_podll-priority.scss"));
}

test "resolveSassModulePathOnly ignores css fallback for @import expansion path" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try touchTmpFile(&tmp_dir, "fixtures/podll-import-css-only.css");

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const fixtures_dir = try std.fs.path.join(allocator, &.{ tmp_path, "fixtures" });
    defer allocator.free(fixtures_dir);

    const load_paths = [_][]const u8{fixtures_dir};
    const resolved = try test_only_path_resolver.resolveSassModulePathOnly(allocator, "/virtual/input.scss", "podll-import-css-only", &load_paths);
    try std.testing.expect(resolved == null);
}

test "resolveSassImportPathOnly prefers import-only candidates" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try touchTmpFile(&tmp_dir, "fixtures/_podll-import-priority.scss");
    try touchTmpFile(&tmp_dir, "fixtures/_podll-import-priority.import.scss");

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const fixtures_dir = try std.fs.path.join(allocator, &.{ tmp_path, "fixtures" });
    defer allocator.free(fixtures_dir);

    const load_paths = [_][]const u8{fixtures_dir};
    const resolved = try test_only_path_resolver.resolveSassImportPathOnly(allocator, "/virtual/input.scss", "podll-import-priority", &load_paths);
    try std.testing.expect(resolved != null);
    defer allocator.free(resolved.?);
    try std.testing.expect(std.mem.endsWith(u8, resolved.?, "_podll-import-priority.import.scss"));
}

test "resolveImportModulePathWithPolicy allows css fallback for bare @import" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try touchTmpFile(&tmp_dir, "fixtures/podll-import-css-only.css");

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const fixtures_dir = try std.fs.path.join(allocator, &.{ tmp_path, "fixtures" });
    defer allocator.free(fixtures_dir);

    const load_paths = [_][]const u8{fixtures_dir};
    const resolved = try resolveImportModulePathWithPolicy(
        allocator,
        "/virtual/input.scss",
        "podll-import-css-only",
        &load_paths,
        true,
        .{},
    );
    try std.testing.expect(resolved != null);
    defer allocator.free(resolved.?);
    try std.testing.expect(std.mem.endsWith(u8, resolved.?, "fixtures/podll-import-css-only.css"));
}

test "resolveImportModulePathWithPolicy prefers top-level css over nested index scss" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try touchTmpFile(&tmp_dir, "fixtures/podll-import-priority.css");
    try touchTmpFile(&tmp_dir, "fixtures/index/podll-import-priority.scss");

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const fixtures_dir = try std.fs.path.join(allocator, &.{ tmp_path, "fixtures" });
    defer allocator.free(fixtures_dir);

    const load_paths = [_][]const u8{fixtures_dir};
    const resolved = try resolveImportModulePathWithPolicy(
        allocator,
        "/virtual/input.scss",
        "podll-import-priority",
        &load_paths,
        true,
        .{},
    );
    try std.testing.expect(resolved != null);
    defer allocator.free(resolved.?);
    try std.testing.expect(std.mem.endsWith(u8, resolved.?, "fixtures/podll-import-priority.css"));
}

test "nested @import keeps imported function local to the rule scope" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeTmpFileAll(&tmp_dir, "_other.scss",
        \\@function d() {@return e}
    );

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const entry_path = try std.fs.path.join(allocator, &.{ tmp_path, "entry.scss" });
    defer allocator.free(entry_path);

    var bundle = try parseAndResolveWithPath(allocator,
        \\a { @import "other"; }
        \\b { c: d(); }
    , entry_path);
    defer bundle.deinit();

    const pr = &bundle.modules[bundle.root_index];
    try std.testing.expect(pr.decl_stmts.items.len >= 1);
    const decl = pr.decl_stmts.items[pr.decl_stmts.items.len - 1];
    const ex = pr.exprs.items[decl.value_expr];
    try std.testing.expectEqual(ExprKind.call, ex.kind);
    const call = pr.call_exprs.items[ex.payload];
    try std.testing.expect(call.callee_is_css);
    try std.testing.expect(call.callee_name != .none);
}

test "import child module keeps its own @forward head even when parent lock is closed" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const entry_src =
        \\$a: configured;
        \\@import "midstream";
    ;
    try writeTmpFileAll(&tmp_dir, "_midstream.scss",
        \\@forward "upstream";
    );
    try writeTmpFileAll(&tmp_dir, "_upstream.scss",
        \\$a: original !default;
        \\b { c: $a; }
    );

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const entry_path = try std.fs.path.join(allocator, &.{ tmp_path, "entry.scss" });
    defer allocator.free(entry_path);

    var bundle = try parseAndResolveWithPath(allocator, entry_src, entry_path);
    defer bundle.deinit();
    try std.testing.expect(bundle.modules.len >= 2);
}

test "@imported callable default keeps defining file @use namespace" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeTmpFileAll(&tmp_dir, "_defs.scss",
        \\@use "sass:map";
        \\@function keys-default($m: (a: 1), $keys: map.keys($m)) {
        \\  @return $keys;
        \\}
    );

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const entry_path = try std.fs.path.join(allocator, &.{ tmp_path, "entry.scss" });
    defer allocator.free(entry_path);

    var bundle = try parseAndResolveWithPath(allocator,
        \\@import "defs";
        \\.x { y: keys-default(); }
    , entry_path);
    defer bundle.deinit();

    const root = &bundle.modules[bundle.root_index];
    try std.testing.expect(root.functions.items.len >= 1);
    try std.testing.expect(root.functions.items[0].defaults.len >= 2);
    const default_expr = root.functions.items[0].defaults[1] orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(ExprKind.builtin_call, root.exprs.items[default_expr].kind);
}

test "unused callable body defers missing namespace function error" {
    var bundle = try parseAndResolveWithPath(std.testing.allocator,
        \\@mixin unused() {
        \\  a: list.join((a), (b));
        \\}
        \\.x { y: z; }
    , "/virtual/entry.scss");
    defer bundle.deinit();

    const root = &bundle.modules[bundle.root_index];
    var found = false;
    for (root.exprs.items) |expr| {
        if (expr.kind == .sass_error) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "@use without entry path returns module base path missing" {
    try std.testing.expectError(error.UsermoduleBasePathMissing, parseAndResolve(std.testing.allocator,
        \\@use "theme";
    ));
}

test "@forward builtin module works without entry path" {
    var bundle = try parseAndResolve(std.testing.allocator,
        \\@forward "sass:math";
    );
    defer bundle.deinit();

    const root = &bundle.modules[bundle.root_index];
    try std.testing.expectEqual(@as(usize, 1), bundle.modules.len);
    try std.testing.expect(root.exported_builtin_fns.count() != 0);
}

test "@import without entry path returns module base path missing" {
    try std.testing.expectError(error.UsermoduleBasePathMissing, parseAndResolve(std.testing.allocator,
        \\@import "theme";
    ));
}

test "@import inside mixin body is SassError" {
    try std.testing.expectError(error.SassError, parseAndResolveWithPath(std.testing.allocator,
        \\@mixin m() {
        \\  @import "other";
        \\}
    , "/virtual/entry.scss"));
}

test "@function nested declaration is SassError" {
    try std.testing.expectError(error.SassError, parseAndResolveWithPath(std.testing.allocator,
        \\@function test() {
        \\  @if (false) {
        \\    @return 0;
        \\  } @else {
        \\    opacity: 1;
        \\  }
        \\}
    , "/virtual/entry.scss"));
}

test "nested property rule rejects nested style rule body" {
    try std.testing.expectError(error.SassError, parseAndResolve(std.testing.allocator,
        \\a {
        \\  display: block
        \\
        \\  b {
        \\    c {
        \\      foo: bar;
        \\    }
        \\  }
        \\}
    ));
}

test "@import missing file is SassError" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const entry_path = try std.fs.path.join(allocator, &.{ tmp_path, "entry.scss" });
    defer allocator.free(entry_path);

    try std.testing.expectError(error.SassError, parseAndResolveWithPath(allocator,
        \\@import "missing";
    , entry_path));
}

test "defaultNamespaceForUse strips dotted suffix and leading underscore" {
    try std.testing.expectEqualStrings("other", defaultNamespaceForUse("other.scss"));
    try std.testing.expectEqualStrings("other", defaultNamespaceForUse("other.foo.bar.scss"));
    try std.testing.expectEqualStrings("other", defaultNamespaceForUse("_other.foo.sass"));
}

test "@use with arithmetic expression lowers to config seed" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeTmpFileAll(&tmp_dir, "_theme.scss",
        \\$spacing: 0px !default;
        \\.theme { gap: $spacing; }
    );

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const entry_path = try std.fs.path.join(allocator, &.{ tmp_path, "entry.scss" });
    defer allocator.free(entry_path);

    var bundle = try parseAndResolveWithPath(allocator,
        \\$scale: 3;
        \\@use "theme" with ($spacing: 1px * $scale);
    , entry_path);
    defer bundle.deinit();

    try std.testing.expectEqual(@as(usize, 1), bundle.config_seeds.len);
    const seed = bundle.config_seeds[0];
    try std.testing.expectEqual(@as(value_mod.ValueKind, .number), seed.value.kind());
    try std.testing.expectEqual(@as(f64, 3.0), seed.value.asF64(bundle.modules[bundle.root_index].value_number_pool));
    try std.testing.expect(seed.value.unitId(bundle.modules[bundle.root_index].value_number_pool) != .none);
}

test "@charset keeps module directive head open for later @use with config" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeTmpFileAll(&tmp_dir, "_theme.scss",
        \\$spacing: 0px !default;
        \\.theme { gap: $spacing; }
    );

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const entry_path = try std.fs.path.join(allocator, &.{ tmp_path, "entry.scss" });
    defer allocator.free(entry_path);

    var bundle = try parseAndResolveWithPath(allocator,
        \\@charset "UTF-8";
        \\@use "theme" with ($spacing: 3px);
    , entry_path);
    defer bundle.deinit();

    try std.testing.expectEqual(@as(usize, 1), bundle.config_seeds.len);
    try std.testing.expectEqual(@as(value_mod.ValueKind, .number), bundle.config_seeds[0].value.kind());
    try std.testing.expectEqual(@as(f64, 3.0), bundle.config_seeds[0].value.asF64(bundle.modules[bundle.root_index].value_number_pool));
}

test "@import keeps module directive head open for later @use with config" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeTmpFileAll(&tmp_dir, "plain.css", ".plain {}\n");
    try writeTmpFileAll(&tmp_dir, "_theme.scss",
        \\$spacing: 0px !default;
        \\.theme { gap: $spacing; }
    );

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const entry_path = try std.fs.path.join(allocator, &.{ tmp_path, "entry.scss" });
    defer allocator.free(entry_path);

    var bundle = try parseAndResolveWithPath(allocator,
        \\@import "plain.css";
        \\@use "theme" with ($spacing: 4px);
    , entry_path);
    defer bundle.deinit();

    try std.testing.expectEqual(@as(usize, 1), bundle.config_seeds.len);
    try std.testing.expectEqual(@as(value_mod.ValueKind, .number), bundle.config_seeds[0].value.kind());
    try std.testing.expectEqual(@as(f64, 4.0), bundle.config_seeds[0].value.asF64(bundle.modules[bundle.root_index].value_number_pool));
}

test "legacy variable-exists in imported top-level if folds false before resolving branch body" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeTmpFileAll(&tmp_dir, "_child.scss",
        \\$x: 1 !default;
        \\@if variable-exists(y) {
        \\  $x: $y;
        \\}
    );

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const entry_path = try std.fs.path.join(allocator, &.{ tmp_path, "entry.scss" });
    defer allocator.free(entry_path);

    var bundle = try parseAndResolveWithPath(allocator,
        \\@import "child";
        \\@mixin m($x: $x) {}
    , entry_path);
    defer bundle.deinit();
    try std.testing.expect(bundle.modules.len >= 1);
}

test "top-level mixin/function declarations keep module directive head open for @use with config" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeTmpFileAll(&tmp_dir, "_theme.scss",
        \\$spacing: 0px !default;
        \\.theme { gap: $spacing; }
    );

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const entry_path = try std.fs.path.join(allocator, &.{ tmp_path, "entry.scss" });
    defer allocator.free(entry_path);

    var bundle = try parseAndResolveWithPath(allocator,
        \\@mixin noop() {}
        \\@function noop() { @return null; }
        \\@use "theme" with ($spacing: 5px);
    , entry_path);
    defer bundle.deinit();

    try std.testing.expectEqual(@as(usize, 1), bundle.config_seeds.len);
    try std.testing.expectEqual(@as(value_mod.ValueKind, .number), bundle.config_seeds[0].value.kind());
    try std.testing.expectEqual(@as(f64, 5.0), bundle.config_seeds[0].value.asF64(bundle.modules[bundle.root_index].value_number_pool));
}

test "lookupUseBindingInsensitive treats hyphen and underscore as equal" {
    var map: std.StringHashMapUnmanaged(UseBinding) = .empty;
    defer map.deinit(std.testing.allocator);
    try map.put(std.testing.allocator, "my_mod", .{ .user_module = 7 });
    const got = lookupUseBindingInsensitive(&map, "my-mod") orelse return error.TestExpectedEqual;
    try std.testing.expect(got == .user_module);
    try std.testing.expectEqual(@as(u32, 7), got.user_module);
}

test "parseNamespacedVariableAssign detects `ns.$member` form" {
    const parsed = parseNamespacedVariableAssign("math.$max-safe-integer") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("math", parsed.ns);
    try std.testing.expectEqualStrings("max-safe-integer", parsed.member);
}

test "parseNamespacedVariableAssign ignores plain declarations" {
    try std.testing.expect(parseNamespacedVariableAssign("color: red") == null);
    try std.testing.expect(parseNamespacedVariableAssign("ns.$bad*name") == null);
}

test "cross assign slot encode/decode round trip" {
    const encoded = try encodeCrossAssignSlot(17, 23);
    const decoded = decodeCrossAssignSlot(encoded) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u32, 17), decoded.module_id);
    try std.testing.expectEqual(@as(SlotId, 23), decoded.slot);
}

test "decodeCrossAssignSlot returns null for regular local slot" {
    try std.testing.expect(decodeCrossAssignSlot(1234) == null);
}

test "lookupSlotInsensitive treats hyphen and underscore as equal" {
    var map: std.StringHashMapUnmanaged(SlotId) = .empty;
    defer map.deinit(std.testing.allocator);
    try map.put(std.testing.allocator, "my_mod", 42);
    try std.testing.expectEqual(@as(SlotId, 42), lookupSlotInsensitive(&map, "my-mod").?);
}

test "lookupSlotInsensitive keeps mixed alias spelling fallback" {
    var map: std.StringHashMapUnmanaged(SlotId) = .empty;
    defer map.deinit(std.testing.allocator);
    try map.put(std.testing.allocator, "my_mod-name", 42);
    try std.testing.expectEqual(@as(SlotId, 42), lookupSlotInsensitive(&map, "my-mod_name").?);
}

test "lookupSlotInsensitive no-mixed-key fast path covers uniform aliases" {
    var map: std.StringHashMapUnmanaged(SlotId) = .empty;
    defer map.deinit(std.testing.allocator);
    try map.put(std.testing.allocator, "my-mod-name", 42);
    try std.testing.expectEqual(
        @as(SlotId, 42),
        lookupStringMapIdentifierInsensitiveNoMixedKeys(SlotId, &map, "my_mod_name").?,
    );
    try std.testing.expectEqual(
        @as(SlotId, 42),
        lookupStringMapIdentifierInsensitiveNoMixedKeys(SlotId, &map, "my_mod-name").?,
    );
}

test "lookupSlotInsensitive no-mixed-key fast path skips mixed-key scan" {
    var map: std.StringHashMapUnmanaged(SlotId) = .empty;
    defer map.deinit(std.testing.allocator);
    try map.put(std.testing.allocator, "my_mod-name", 42);
    try std.testing.expect(
        lookupStringMapIdentifierInsensitiveNoMixedKeys(SlotId, &map, "my-mod_name") == null,
    );
    try std.testing.expectEqual(@as(SlotId, 42), lookupSlotInsensitive(&map, "my-mod_name").?);
}

test "forward show/hide variable token requires `$` and allows -/_ equivalence" {
    try std.testing.expect(forwardMatchesVarToken("$a", "a"));
    try std.testing.expect(forwardMatchesVarToken("$my_var", "my-var"));
    try std.testing.expect(!forwardMatchesVarToken("a", "a"));
}

test "forward show/hide plain token treats - and _ as equal" {
    try std.testing.expect(forwardMatchesPlainToken("b_a", "b-a"));
    try std.testing.expect(forwardMatchesPlainToken("b-a", "b_a"));
}

test "forward visibility checks operate on exported (prefixed) name" {
    const show = [_][]const u8{"b_a"};
    const hide = [_][]const u8{"a"};
    try std.testing.expect(forwardAllowsPlain("b-a", &show, null));
    try std.testing.expect(forwardAllowsPlain("b-a", null, &hide));
}

test "plain css entry rejects local Sass functions" {
    try std.testing.expectError(error.SassError, parseAndResolveWithPath(std.testing.allocator,
        \\@function a() {@return b}
        \\c { d: a() }
    , "/virtual/plain.css"));
}

test "plain css entry rejects sass-only declaration values" {
    try std.testing.expectError(error.SassError, parseAndResolveWithPath(std.testing.allocator,
        \\a {
        \\  x: index(1 2 3, 1);
        \\}
    , "/virtual/plain.css"));
}

test "plain css entry rejects top-level leading combinator selectors" {
    try std.testing.expectError(error.SassError, parseAndResolveWithPath(std.testing.allocator,
        \\> a { b: c; }
    , "/virtual/plain.css"));
}

test "plain css entry rejects sass variable declarations" {
    try std.testing.expectError(error.SassError, parseAndResolveWithPath(std.testing.allocator,
        \\$var: value;
    , "/virtual/plain.css"));
}

test "plain css entry rejects interpolated import and multi import" {
    try std.testing.expectError(error.SassError, parseAndResolveWithPath(std.testing.allocator,
        \\@import url("foo#{bar}baz");
    , "/virtual/plain.css"));
    try std.testing.expectError(error.SassError, parseAndResolveWithPath(std.testing.allocator,
        \\@import "a", "b";
    , "/virtual/plain.css"));
}

test "plain css custom @function body keeps raw declaration values" {
    var bundle = try parseAndResolveWithPath(std.testing.allocator,
        \\@function --a() {
        \\  result: $b;
        \\}
    , "/virtual/plain.css");
    defer bundle.deinit();

    const pr = &bundle.modules[bundle.root_index];
    try std.testing.expectEqual(@as(usize, 1), pr.at_rule_stmts.items.len);
    const ar = pr.at_rule_stmts.items[0];
    try std.testing.expectEqual(@as(usize, 1), ar.body_direct.len);
    const stmt = pr.stmts.items[ar.body_direct[0]];
    try std.testing.expectEqual(StmtKind.declaration, stmt.kind);
    const decl = pr.decl_stmts.items[stmt.payload];
    const ex = pr.exprs.items[decl.value_expr];
    try std.testing.expectEqual(ExprKind.literal_string, ex.kind);
}

test "nested @import rejects top-level plain css leading combinators" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeTmpFileAll(&tmp_dir, "plain.css",
        \\> b { c: d; }
    );

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const entry_path = try std.fs.path.join(allocator, &.{ tmp_path, "entry.scss" });
    defer allocator.free(entry_path);

    try std.testing.expectError(error.SassError, parseAndResolveWithPath(allocator,
        \\a { @import "plain"; }
    , entry_path));
}

test "resolver: reserved lowercase function names are rejected" {
    try std.testing.expectError(error.Unsupported, parseAndResolve(std.testing.allocator,
        \\@function element() {@return 1}
    ));
    try std.testing.expectError(error.Unsupported, parseAndResolve(std.testing.allocator,
        \\@function type() {@return 1}
    ));
}

test "resolver: css special function call is emitted as literal css call" {
    var bundle = try parseAndResolve(std.testing.allocator,
        \\@function URL() {@return 1}
        \\a { b: URL() }
    );
    defer bundle.deinit();

    const pr = &bundle.modules[bundle.root_index];
    const decl = pr.decl_stmts.items[0];
    const ex = pr.exprs.items[decl.value_expr];
    try std.testing.expectEqual(ExprKind.literal_string, ex.kind);
    try std.testing.expectEqual(@as(usize, 0), pr.call_exprs.items.len);
    try std.testing.expectEqual(@as(usize, 0), pr.builtin_calls.items.len);
}

test "resolver: vendor-prefixed css special call with unknown var compiles as literal" {
    var bundle = try parseAndResolve(std.testing.allocator,
        \\a { b: -c-element($d); }
    );
    defer bundle.deinit();
    const pr = &bundle.modules[bundle.root_index];
    try std.testing.expectEqual(@as(usize, 1), pr.decl_stmts.items.len);
    const decl = pr.decl_stmts.items[0];
    const ex = pr.exprs.items[decl.value_expr];
    try std.testing.expectEqual(ExprKind.literal_string, ex.kind);
}

test "resolver: vendor-prefixed url with unknown var errors" {
    try std.testing.expectError(error.UnknownVar, parseAndResolve(std.testing.allocator,
        \\a { b: -c-url($d); }
    ));
}

test "resolver: custom css @function body keeps unknown var literal" {
    var bundle = try parseAndResolve(std.testing.allocator,
        \\@function --a() {
        \\  result: $b;
        \\}
    );
    defer bundle.deinit();
    const pr = &bundle.modules[bundle.root_index];
    try std.testing.expectEqual(@as(usize, 1), pr.at_rule_stmts.items.len);
    const ar = pr.at_rule_stmts.items[0];
    try std.testing.expectEqual(@as(usize, 1), ar.body_direct.len);
    const stmt = pr.stmts.items[ar.body_direct[0]];
    try std.testing.expectEqual(StmtKind.declaration, stmt.kind);
    const decl = pr.decl_stmts.items[stmt.payload];
    const ex = pr.exprs.items[decl.value_expr];
    try std.testing.expectEqual(ExprKind.literal_string, ex.kind);
}

test "resolver: include name starting with -- errors even with __ declaration" {
    try std.testing.expectError(error.Unsupported, parseAndResolve(std.testing.allocator,
        \\@mixin __a() { b: c; }
        \\d { @include --a; }
    ));
}

test "resolver: empty @at-root query emits no at-rule statement" {
    var bundle = try parseAndResolve(std.testing.allocator,
        \\@at-root (without: media) {}
    );
    defer bundle.deinit();
    const pr = &bundle.modules[bundle.root_index];
    try std.testing.expectEqual(@as(usize, 0), pr.at_rule_stmts.items.len);
    try std.testing.expectEqual(@as(usize, 1), pr.top_stmts.len);
    try std.testing.expect(pr.stmts.items[pr.top_stmts[0]].kind == .noop);
}

test "resolver: literal nested property rule is marked as property namespace" {
    var bundle = try parseAndResolve(std.testing.allocator,
        \\a {
        \\  b: {
        \\    c: d;
        \\  }
        \\}
    );
    defer bundle.deinit();

    const pr = &bundle.modules[bundle.root_index];
    const outer_stmt = pr.stmts.items[pr.top_stmts[0]];
    try std.testing.expectEqual(StmtKind.rule, outer_stmt.kind);
    const outer_rule = pr.rule_stmts.items[outer_stmt.payload];
    try std.testing.expectEqual(@as(usize, 1), outer_rule.body_direct.len);

    const inner_stmt = pr.stmts.items[outer_rule.body_direct[0]];
    try std.testing.expectEqual(StmtKind.rule, inner_stmt.kind);
    const inner_rule = pr.rule_stmts.items[inner_stmt.payload];
    try std.testing.expect(inner_rule.prop_namespace_prefix_expr != null);
    try std.testing.expectEqual(@as(?ExprIndex, null), inner_rule.prop_namespace_value_expr);
}

test "resolver: interpolated nested property rule is marked as property namespace" {
    var bundle = try parseAndResolve(std.testing.allocator,
        \\$name: b;
        \\a {
        \\  #{$name}: {
        \\    c: d;
        \\  }
        \\}
    );
    defer bundle.deinit();

    const pr = &bundle.modules[bundle.root_index];
    const outer_stmt = pr.stmts.items[pr.top_stmts[1]];
    try std.testing.expectEqual(StmtKind.rule, outer_stmt.kind);
    const outer_rule = pr.rule_stmts.items[outer_stmt.payload];
    try std.testing.expectEqual(@as(usize, 1), outer_rule.body_direct.len);

    const inner_stmt = pr.stmts.items[outer_rule.body_direct[0]];
    try std.testing.expectEqual(StmtKind.rule, inner_stmt.kind);
    const inner_rule = pr.rule_stmts.items[inner_stmt.payload];
    try std.testing.expect(inner_rule.prop_namespace_prefix_expr != null);
    try std.testing.expectEqual(@as(?ExprIndex, null), inner_rule.prop_namespace_value_expr);
}

test "resolver: nested property rule with script value keeps value expr" {
    var bundle = try parseAndResolve(std.testing.allocator,
        \\a {
        \\  b: c + d {
        \\    e: f;
        \\  }
        \\}
    );
    defer bundle.deinit();

    const pr = &bundle.modules[bundle.root_index];
    const outer_stmt = pr.stmts.items[pr.top_stmts[0]];
    try std.testing.expectEqual(StmtKind.rule, outer_stmt.kind);
    const outer_rule = pr.rule_stmts.items[outer_stmt.payload];
    try std.testing.expectEqual(@as(usize, 1), outer_rule.body_direct.len);

    const inner_stmt = pr.stmts.items[outer_rule.body_direct[0]];
    try std.testing.expectEqual(StmtKind.rule, inner_stmt.kind);
    const inner_rule = pr.rule_stmts.items[inner_stmt.payload];
    try std.testing.expect(inner_rule.prop_namespace_prefix_expr != null);
    try std.testing.expect(inner_rule.prop_namespace_value_expr != null);
}

test "resolver: star import keeps var and callable conflicts lazy until reference" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeTmpFileAll(&tmp_dir, "mods/_a.scss",
        \\$shared: a;
        \\@mixin shared() {}
        \\@function shared() {
        \\  @return a;
        \\}
    );
    try writeTmpFileAll(&tmp_dir, "mods/_b.scss",
        \\$shared: b;
        \\@mixin shared() {}
        \\@function shared() {
        \\  @return b;
        \\}
    );

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const entry_path = try std.fs.path.join(allocator, &.{ tmp_path, "mods", "entry.scss" });
    defer allocator.free(entry_path);

    const source =
        \\@use "a" as *;
        \\@use "b" as *;
        \\
    ;
    var bundle = try parseAndResolveWithPath(allocator, source, entry_path);
    defer bundle.deinit();

    const root = &bundle.modules[bundle.root_index];
    try std.testing.expectEqual(@as(usize, 1), root.ambiguous_star_vars.count());
    try std.testing.expectEqual(@as(usize, 1), root.ambiguous_star_mixins.count());
    try std.testing.expectEqual(@as(usize, 1), root.ambiguous_star_functions.count());
}

test "resolver: star import ambiguous variable read is deferred SassError" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeTmpFileAll(&tmp_dir, "mods/_a.scss", "$shared: a;\n");
    try writeTmpFileAll(&tmp_dir, "mods/_b.scss", "$shared: b;\n");

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const entry_path = try std.fs.path.join(allocator, &.{ tmp_path, "mods", "entry.scss" });
    defer allocator.free(entry_path);

    try std.testing.expectError(error.SassError, parseAndResolveWithPath(allocator,
        \\@use "a" as *;
        \\@use "b" as *;
        \\.x { y: $shared; }
    , entry_path));
}

test "resolver: star import ambiguous callable reference is deferred SassError" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeTmpFileAll(&tmp_dir, "mods/_a.scss",
        \\@mixin shared() {}
        \\@function shared() {
        \\  @return a;
        \\}
    );
    try writeTmpFileAll(&tmp_dir, "mods/_b.scss",
        \\@mixin shared() {}
        \\@function shared() {
        \\  @return b;
        \\}
    );

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const entry_path = try std.fs.path.join(allocator, &.{ tmp_path, "mods", "entry.scss" });
    defer allocator.free(entry_path);

    try std.testing.expectError(error.SassError, parseAndResolveWithPath(allocator,
        \\@use "a" as *;
        \\@use "b" as *;
        \\.x {
        \\  @include shared;
        \\  y: shared();
        \\}
    , entry_path));
}

test "resolver: local callables shadow star imported callables" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeTmpFileAll(&tmp_dir, "mods/_dep.scss",
        \\@mixin shared() {}
        \\@function shared() {
        \\  @return dep;
        \\}
    );

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const entry_path = try std.fs.path.join(allocator, &.{ tmp_path, "mods", "entry.scss" });
    defer allocator.free(entry_path);

    var bundle = try parseAndResolveWithPath(allocator,
        \\@use "dep" as *;
        \\@mixin shared() {}
        \\@function shared() {
        \\  @return local;
        \\}
        \\.x {
        \\  @include shared;
        \\  y: shared();
        \\}
    , entry_path);
    defer bundle.deinit();

    const root = &bundle.modules[bundle.root_index];
    try std.testing.expectEqual(@as(usize, 0), root.ambiguous_star_mixins.count());
    try std.testing.expectEqual(@as(usize, 0), root.ambiguous_star_functions.count());
}

test "resolver: forward export conflicting members stay eager SassError" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeTmpFileAll(&tmp_dir, "mods/_a.scss",
        \\$shared: a !default;
        \\@mixin shared() {}
        \\@function shared() {
        \\  @return a;
        \\}
    );
    try writeTmpFileAll(&tmp_dir, "mods/_b.scss",
        \\$shared: b !default;
        \\@mixin shared() {}
        \\@function shared() {
        \\  @return b;
        \\}
    );

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const entry_path = try std.fs.path.join(allocator, &.{ tmp_path, "mods", "entry.scss" });
    defer allocator.free(entry_path);

    try std.testing.expectError(error.SassError, parseAndResolveWithPath(allocator,
        \\@forward "a";
        \\@forward "b";
    , entry_path));
}

test "resolver: forward export diamond remains usable" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeTmpFileAll(&tmp_dir, "mods/_leaf.scss",
        \\$shared: leaf !default;
        \\@mixin shared() {}
        \\@function shared() {
        \\  @return leaf;
        \\}
    );
    try writeTmpFileAll(&tmp_dir, "mods/_a.scss",
        \\@forward "leaf";
    );
    try writeTmpFileAll(&tmp_dir, "mods/_b.scss",
        \\@forward "leaf";
    );
    try writeTmpFileAll(&tmp_dir, "mods/_hub.scss",
        \\@forward "a";
        \\@forward "b";
    );

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const entry_path = try std.fs.path.join(allocator, &.{ tmp_path, "mods", "entry.scss" });
    defer allocator.free(entry_path);

    var bundle = try parseAndResolveWithPath(allocator,
        \\@use "hub";
        \\.x {
        \\  y: hub.$shared;
        \\  @include hub.shared;
        \\  y: hub.shared();
        \\}
    , entry_path);
    defer bundle.deinit();

    const root = &bundle.modules[bundle.root_index];
    try std.testing.expectEqual(@as(usize, 0), root.ambiguous_export_vars.count());
    try std.testing.expectEqual(@as(usize, 0), root.ambiguous_export_default_vars.count());
    try std.testing.expectEqual(@as(usize, 0), root.ambiguous_export_mixins.count());
    try std.testing.expectEqual(@as(usize, 0), root.ambiguous_export_functions.count());
}

test "resolver: forward export ignores callable-only global refs" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeTmpFileAll(&tmp_dir, "mods/_functions.scss",
        \\@function use-member() {
        \\  @return $member;
        \\}
    );
    try writeTmpFileAll(&tmp_dir, "mods/_vars.scss",
        \\$member: value !default;
    );
    try writeTmpFileAll(&tmp_dir, "mods/_hub.scss",
        \\@forward "functions";
        \\@forward "vars";
    );

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const entry_path = try std.fs.path.join(allocator, &.{ tmp_path, "mods", "entry.scss" });
    defer allocator.free(entry_path);

    var bundle = try parseAndResolveWithPath(allocator,
        \\@use "hub";
        \\a {b: hub.$member}
    , entry_path);
    defer bundle.deinit();
}

test "resolver: nested !global member stays exported" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeTmpFileAll(&tmp_dir, "mods/_other.scss",
        \\x {
        \\  @if false {
        \\    $member: value !global;
        \\  }
        \\}
    );

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const entry_path = try std.fs.path.join(allocator, &.{ tmp_path, "mods", "entry.scss" });
    defer allocator.free(entry_path);

    var bundle = try parseAndResolveWithPath(allocator,
        \\@use "other";
        \\a {b: other.$member}
    , entry_path);
    defer bundle.deinit();
}
