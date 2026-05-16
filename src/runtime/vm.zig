//!Stage 1a bytecode VM -- while+switch dispatch, Rule IR append.

const std = @import("std");
const builtin = @import("builtin");
const opcode_mod = @import("../ir/opcode.zig");
const media_prelude = @import("../resolve/media_prelude.zig");
const supports_prelude = @import("../resolve/supports_prelude.zig");
const ast_cache_mod = @import("../resolve/ast_cache.zig");
const value_mod = @import("value.zig");
const rule_ir_mod = @import("../ir/rule_ir.zig");
const compiler_mod = @import("../ir/compiler.zig");
const resolver_mod = @import("../resolve/resolver.zig");
const resolver_eval = @import("../resolve/resolver_eval.zig");
const color_mod = @import("../color/color.zig");
const calculation_mod = @import("../color/calculation.zig");
const builtin_mod = @import("../builtin/mod.zig");
const builtin_shared = @import("../builtin/shared.zig");
const observe_mod = @import("observe.zig");
const perf = @import("perf.zig");
const value_format = @import("value_format.zig");
const value_inspect = @import("value_inspect.zig");
const error_format = @import("error_format.zig");
const color_format = @import("../color/color_format.zig");
const calc_utils = @import("calc_utils.zig");
const units = @import("units.zig");
const css_utils = @import("css_utils.zig");
const ir_validate = @import("../ir/validate.zig");
const selector_mod = @import("../selector/selector.zig");
const selector_helpers_mod = @import("../selector/selector_helpers.zig");
const zsass_io = @import("io.zig");
const deprecation_mod = @import("deprecation.zig");
const intern_pool_mod = @import("intern_pool.zig");
const value_eq = @import("value_eq.zig");
const value_eq_env_mod = @import("value_eq_env.zig");
const resolver_eval_test_env_mod = @import("resolver_eval_test_env.zig");
const vm_selector_resolve = @import("vm_selector_resolve.zig");
const vm_emit = @import("vm_emit.zig");
const vm_cross_module = @import("vm_cross_module.zig");
const vm_dispatch = @import("vm_dispatch.zig");
const origin_mod = @import("origin.zig");
const InternPool = intern_pool_mod.InternPool;
const InternId = intern_pool_mod.InternId;
const OriginId = origin_mod.OriginId;
const RuntimeValueEqEnv = value_eq_env_mod.RuntimeValueEqEnv;
const ResolverEvalTestEnv = resolver_eval_test_env_mod.ResolverEvalTestEnv;

const Instruction = opcode_mod.Instruction;
const Value = value_mod.Value;
const ListSeparator = value_mod.ListSeparator;
const ColorPool = value_mod.ColorPool;
const NumberPool = value_mod.NumberPool;
const RuleIR = rule_ir_mod.RuleIR;
const Span = rule_ir_mod.Span;
const Program = compiler_mod.Program;
const Chunk = compiler_mod.Chunk;
const call_arg_splat_sentinel = resolver_mod.call_arg_splat_sentinel;
const media_prelude_has_interp_flag: u8 = 1;
const media_prelude_interp_at_start_flag: u8 = 2;
const media_prelude_compact_dynamic_feature_colon_flag: u8 = 4;
const rule_flag_plain_css_preserve: u16 = 1 << 0;
const rule_flag_plain_css_combine_parent: u16 = 1 << 1;
const rule_flag_selector_validation_failed: u16 = 1 << 2;

const RuleOpenMode = enum(u2) {
    ordinary,
    plain_css_preserve,
    plain_css_combine_parent,
};

const InterpolatedCallContext = enum(u2) {
    none,
    generic,
    url_like,
};

const InterpolatedCallInfo = struct {
    context: InterpolatedCallContext = .none,
    arg_start: usize = 0,
    preserve_quoted_args: bool = false,
    unquote_quoted_args: bool = false,
};

fn isCommaSeparatorFragment(text: []const u8) bool {
    if (text.len == 0 or text[0] != ',') return false;
    var i: usize = 1;
    while (i < text.len) : (i += 1) {
        if (text[i] != ' ' and text[i] != '\t' and text[i] != '\r' and text[i] != '\n' and text[i] != '\x0c') {
            return false;
        }
    }
    return true;
}

fn decodeRuleOpenMode(flags: u16) RuleOpenMode {
    if ((flags & rule_flag_plain_css_combine_parent) != 0) return .plain_css_combine_parent;
    if ((flags & rule_flag_plain_css_preserve) != 0) return .plain_css_preserve;
    return .ordinary;
}

fn unpackCallArgB(arg_b: u32) struct { id: u32, argc: u32 } {
    return .{
        .id = arg_b >> 16,
        .argc = arg_b & 0xffff,
    };
}

const vmStderrPrint = error_format.stderrPrint;

const VMError = error{
    OutOfMemory,
    StackUnderflow,
    StackOverflow,
    FrameOverflow,
    UnsupportedOpcode,
    /// builtin dispatch fails with argument arity (e.g. `color.red()` = 0 args)
    BuiltinArity,
    /// builtin dispatch fails on argument type (e.g. `math.abs("foo")`)
    BuiltinType,
    /// Builtin is not implemented (Color 4 space-aware, etc., resolve passes, but body is stub)
    BuiltinUnsupported,
    /// `@error` directive runtime failure.
    SassError,
    /// deprecation becomes error with --fatal-deprecation
    FatalDeprecation,
    BadJump,
    InternalError,
};

/// Value that does not conflict with `encodeChunkRef` / `decodeChunkRef` (assuming id does not use upper bit).
const chunk_run_sentinel: u32 = 0xffff_fffc;
const content_none_sentinel: u32 = std.math.maxInt(u32);
const no_local_slot_hint: u32 = std.math.maxInt(u32);
const calc_arg_marker = calc_utils.calc_arg_marker;
const calc_interp_marker = calc_utils.calc_interp_marker;
const literal_decl_marker = "\x01zsass-literal-decl:";
const interp_decl_marker = "\x01zsass-interp-decl:";
const color_preserve_slash_marker = "\x01zsass-color-preserve-slash:";
const calc_interp_preserve_start = "\x01zsass-calc-preserve:";
const calc_interp_preserve_end = "\x02";
const media_prelude_preserve_case_marker = "\x01zsass-media-preserve:";

fn fuzzyNumberOrder(a: f64, b: f64) std.math.Order {
    if (std.math.approxEqAbs(f64, a, b, 1e-11)) return .eq;
    return std.math.order(a, b);
}

pub const Frame = struct {
    locals: []Value,
    declared: []bool = &.{},
    /// Global-prefix slots that should be propagated back to module/caller on return.
    global_writeback: []bool = &.{},
    global_writeback_any: bool = false,
    return_pc: u32,
    /// 0 = top-level, `encodeChunkRef`, or `chunk_run_sentinel`.
    return_chunk: u32,
    save_sp: u32,
    /// `doCall` module immediately before; restore on return.
    caller_module_id: u32 = 0,
    /// Content closure set by `@include ... {}` (only valid for mixin frames).
    content_module_id: u32 = content_none_sentinel,
    content_chunk_id: u32 = content_none_sentinel,
    content_capture_locals: []const Value = &.{},
    content_capture_declared: []const bool = &.{},
    /// Parent binding when the above content closure further calls `@content`.
    content_parent_module_id: u32 = content_none_sentinel,
    content_parent_chunk_id: u32 = content_none_sentinel,
    content_parent_capture_locals: []const Value = &.{},
    content_parent_capture_declared: []const bool = &.{},
    /// At the end of the content frame, write-back the first local band to the caller.
    /// To allow `@content` to update existing locals in the include caller.
    content_writeback_locals: []Value = &.{},
    content_writeback_declared: []bool = &.{},
    /// `call_content` automatically opens maybe-current rule for hidden selector context
    /// Close on content frame return.
    auto_close_current_rule_on_return: bool = false,
};

const ContentBinding = struct {
    module_id: u32 = content_none_sentinel,
    chunk_id: u32 = content_none_sentinel,
    capture_locals: []const Value = &.{},
    capture_declared: []const bool = &.{},
};

pub const ChunkRef = union(enum) {
    top,
    mixin: u32,
    function: u32,
    content: u32,
    placeholder: u32,
};

const LoadCssConfig = vm_cross_module.LoadCssConfig;
const LoadCssSeedBinding = vm_cross_module.LoadCssSeedBinding;

const LoadCssSavedState = struct {
    values: []Value,
    declared: []bool,
};

const VisibleLoadCssModule = struct {
    owner_module: u32,
    context_root: u32,
    canonical_module: u32,
    tag: u32,
};

const SavedAtRootSelectorFrame = struct {
    selectors: []InternId,
    owner_modules: []u32,
    push_ir_lens: []usize,
    keep_len: usize,
    parent: ?InternId,
};

const AtRootBubbleFrame = struct {
    start_idx: usize,
    mask: u8,
};

const OpenAtRuleBubbleFrame = struct {
    node_idx: usize,
    type_mask: u8,
};

/// Frame stacked at emit_at_rule_begin and popped by emit_at_rule_end.
/// Conditional at-rules nested inside keyframe steps keep keyframe nesting and
/// wrap direct declarations in the outer selector instead of hoisting outside
/// the keyframe frame. Example: `.foo { @keyframes wave { 50% { @supports (...) { color: blue } } } }`
/// serializes as `@keyframes wave { 50% { @supports (...) { .foo { color: blue } } } }`.
///
/// Processing:
/// - In emit_at_rule_begin, @supports/@media/@layer is directly under keyframe frame (or
/// the outermost of its nested chain), when pushing frame:
/// 1. If compile had previously closed the keyframe frame rule with emit_rule_end, undo
/// (pop trailing rule_end and open_rule_depth++). This makes @supports
/// Nested inside the keyframe frame.
/// 2. `at_root_saved_selector_frames` (push_at_root_scope by most recent @keyframes
/// the last selector (= outer style rule) of the selector column saved in selector_stack
/// Push so that the following emit_rule_begin_current_maybe opens the rule in the outer selector.
/// - in emit_at_rule_end:
/// 1. Pop the pushed outer selector.
/// 2. If undo is done, reissue rule_end (restore the original close of keyframe frame).
const KeyframeNestedAtRuleFrame = struct {
    /// Did this frame increment in_keyframe_nested_at_rule_depth in emit_at_rule_begin?
    incremented_nested_depth: bool = false,
    /// Did you push outer selector to selector_stack / scope_push_ir_lens?
    pushed_outer: bool = false,
    /// Did you pop the previous trailing rule_end and reopen the keyframe frame rule?
    /// If true, reissue rule_end after emit_at_rule_end.
    undid_close: bool = false,
    /// True if this at-rule is @keyframes body (decrement in_keyframes_block_depth at end).
    is_keyframes: bool = false,
};

fn atRuleBubbleTypeMask(raw_name: []const u8) u8 {
    if (std.mem.eql(u8, raw_name, "media")) return rule_ir_mod.at_root_bubble_media_mask;
    if (std.mem.eql(u8, raw_name, "supports")) return rule_ir_mod.at_root_bubble_supports_mask;
    if (std.mem.eql(u8, raw_name, "layer")) return rule_ir_mod.at_root_bubble_layer_mask;
    return 0;
}

fn atRuleAllowsDirectDeclarations(raw_name: []const u8) bool {
    return std.mem.eql(u8, raw_name, "page") or
        std.mem.eql(u8, raw_name, "font-face") or
        std.mem.eql(u8, raw_name, "property") or
        std.mem.eql(u8, raw_name, "counter-style");
}

const MaybeCurrentRuleState = enum(u2) {
    inactive,
    open,
    closed_elsewhere,
};

const ListSourceShape = struct {
    first_item_gap: u32 = 0,
    first_pair_gap: u32 = 0,
};

const FlowScope = struct {
    frame_depth: usize,
    global_limit: usize,
    saved_start: usize,
};

const FlowSavedSlot = struct {
    slot: u32,
    value: Value,
    declared: bool,
};

fn programNeedsStackSourceSpans(program: *const Program) bool {
    for (program.modules) |mod| {
        const path = mod.module_path;
        if (path.len >= 5 and std.ascii.eqlIgnoreCase(path[path.len - 5 ..], ".sass")) return true;
    }
    return false;
}

/// The nest_depth of rule_ir is available in u8, but the usage on the writer side is `nest_depth != 0`
/// bool test only. When it reaches 256 steps or more, silent wrap becomes 0 and hoisted rule
/// Perform a saturation cast to avoid fallback blank from firing accidentally.
inline fn saturateNestDepth(depth: usize) u8 {
    return std.math.cast(u8, depth) orelse std.math.maxInt(u8);
}

pub const VM = struct {
    stack: std.ArrayListUnmanaged(Value) = .empty,
    stack_source_spans: std.ArrayListUnmanaged(Span) = .empty,
    track_stack_source_spans: bool = false,
    frame_stack: std.ArrayListUnmanaged(Frame) = .empty,
    flow_scope_stack: std.ArrayListUnmanaged(FlowScope) = .empty,
    flow_saved_slots: std.ArrayListUnmanaged(FlowSavedSlot) = .empty,
    list_pool: std.ArrayListUnmanaged([]Value) = .empty,
    list_source_shapes: std.AutoHashMapUnmanaged(u32, ListSourceShape) = .empty,
    /// arglist positional list handle -> keyword map list handle.
    arglist_keyword_lists: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// A collection of handles to avoid coercion of slash-list to slash-free number.
    slash_list_preserve: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// list_pool handle indexed sidecar bitset. Bit is set = "This list handle is
    /// Guaranteed (recursively) to not contain `&` (slice in list_pool is immutable, so
    /// A bit once set is valid forever). Usage:
    /// 1. The cache that `maybeResolveParentSelectorValue` sets up after the first walk (old
    /// `parent_sel_resolve_none` AutoHashMap replacement, lookup to O(1) memory access)
    /// 2. A callsite that can determine that elements are "known no-`&`" at construction time (builtin/list/map/meta, etc.)
    // Route to pre-populate with /// and avoid the first walk itself (in parallel with Value internal flag bit)
    /// Index is handle (index of list_pool.items), size is resize delayed until list_pool.items.len.
    list_parent_sel_none: std.DynamicBitSetUnmanaged = .{},
    /// key -> index hash for `map.get` / `map.has-key` in `builtin/map.zig`.
    /// Drop iterative lookups on large maps to O(1) for repeated helper calls.
    map_lookup_index_cache: std.AutoHashMapUnmanaged(u32, ?*std.StringHashMapUnmanaged(u32)) = .empty,
    /// Repeated `list.index()` over immutable list handles.
    list_index_cache: std.AutoHashMapUnmanaged(builtin_mod.ListIndexCacheKey, Value) = .empty,
    /// Legacy global builtin lookup cache for Indirect CSS/string callable fallback.
    /// value=maxInt(u32) is miss sentinel.
    legacy_global_builtin_cache: std.AutoHashMapUnmanaged(InternId, u32) = .empty,
    color_pool: *ColorPool,
    deprecation_opts: deprecation_mod.DeprecationOpts = .{},
    /// Suppress direct VM diagnostics for tests that intentionally exercise
    /// user-facing failures. CLI/API callers keep the default false.
    suppress_diagnostics: bool = builtin.is_test,
    /// Optional fd for TAGD builtin-dispatch error lines (e.g. spec_runner pipe). Per-VM, not process-global.
    error_sink_fd: ?i32 = null,
    /// Stage 2 sidecar for unit-bearing numbers (NaN-box prep).
    /// Currently unused -- populated by `Value.number(...)` once accessor API
    /// switches to handle-based lookup. Append-only for VM lifetime.
    number_pool: value_mod.NumberPool = .empty,
    /// Stage 2 sidecar for callable payloads (`flags|module_id|name`).
    /// Currently unused -- see `number_pool` above.
    callable_payload_pool: value_mod.CallablePayloadPool = .empty,
    /// Stage 2 sidecar for list metadata flags (separator/bracketed/is_map/coerce_slash).
    /// Currently unused -- populated by `Value.list*` constructors once
    /// accessor API switches to handle-based lookup (P4 commit 3 stage B).
    /// Append-only for VM lifetime.
    list_meta_pool: value_mod.ListMetaPool = .empty,
    /// Stage 2 sidecar for string flags
    /// (quoted/from_inspect/named_color_literal/preserve_ampersand/preserve_literal_text).
    /// Currently unused -- see `list_meta_pool` above.
    string_flags_pool: value_mod.StringFlagsPool = .empty,
    /// Parent selector for nested rules (for `&` expansion). Push with `emit_rule_begin`, pop with `pop_rule_scope`.
    selector_stack: std.ArrayListUnmanaged(InternId) = .empty,
    /// Module-system @extend owner for each selector scope. This is captured
    /// when the selector is pushed, because a rule may be opened lazily after
    /// the first declaration, possibly inside a mixin from another module.
    selector_owner_stack: std.ArrayListUnmanaged(u32) = .empty,
    /// `rule_ir.nodes.items.len` snapshot at the time of push in parallel with `selector_stack`.
    /// If snapshot == current_len at pop time, "there was no IR emit in scope" (= empty rule scope).
    /// trailing empty nested rule in official Sass CLI (`&.empty{}` in `.parent { .child {} &.empty {} } .next{}`)
    // To reproduce the behavior where /// suppresses blanks between subsequent top-level rules.
    /// When detected, set `pending_empty_scope_after_visible` and propagate the flag to the next stmt_gap.
    /// Combined with `rule_ir.last_visible_emit_node_count` to set stmt_gap since last visible emit.
    /// Also check that it is not included.
    scope_push_ir_lens: std.ArrayListUnmanaged(usize) = .empty,
    /// True if empty scope was popped immediately after the most recent visible emit (without stmt_gap).
    /// In the next `emit_stmt_gap`, set the `stmt_gap_after_empty_skip` flag on the stmt_gap node and consume it.
    /// Just before emit_stmt_gap `rule_ir.last_visible_emit_node_count >
    /// Clear if pending_set_at_visible_count` (visible emit ran after set = trailing
    /// because it is no longer empty).
    pending_empty_scope_after_visible: bool = false,
    suppress_next_origin_reopen: bool = false,
    /// `rule_ir.last_visible_emit_node_count` at the time of setting `pending_empty_scope_after_visible`.
    /// Used for invalidation determination in emit_stmt_gap.
    pending_set_at_visible_count: usize = 0,
    /// True immediately after detecting trailing-empty-scope and suppressing emit_stmt_gap.
    /// Set `suppress_leading_blank` flag in next appendRuleBegin / appendAtRuleBegin
    /// Suppress fallback blank (`indent_level == 0 and nest_depth == 0`) on the writer side.
    /// Return to false at the time of application.
    suppress_next_rule_begin_blank: bool = false,
    /// In the block of `@at-root <selector>`, there is a selector context for interpreting `&` even if selector_stack is empty.
    at_root_selector_context_stack: std.ArrayListUnmanaged(bool) = .empty,
    at_rule_media_stack: std.ArrayListUnmanaged(bool) = .empty,
    at_rule_decl_container_stack: std.ArrayListUnmanaged(bool) = .empty,
    open_at_rule_bubble_stack: std.ArrayListUnmanaged(OpenAtRuleBubbleFrame) = .empty,
    /// See KeyframeNestedAtRuleFrame for details. Push with emit_at_rule_begin
    /// and pop at emit_at_rule_end in parallel with `open_at_rule_bubble_stack`.
    keyframe_nested_at_rule_stack: std.ArrayListUnmanaged(KeyframeNestedAtRuleFrame) = .empty,
    /// @keyframes at-rule open depth. emit_at_rule_begin @keyframes increment,
    /// decrement at emit_at_rule_end (KeyframeNestedAtRuleFrame.is_keyframes=true).
    /// Used to determine how to handle @supports/@media within keyframe frame.
    in_keyframes_block_depth: u32 = 0,
    /// Nesting depth of @supports/@media/@layer opened inside keyframe frame.
    /// Once you push the outer selector in the outer at-rule, the nested @supports/@media
    /// Do not push again (prevent double push).
    in_keyframe_nested_at_rule_depth: u32 = 0,
    at_root_selector_context_depth: u32 = 0,
    media_query_depth: u32 = 0,
    at_root_bubble_stack: std.ArrayListUnmanaged(AtRootBubbleFrame) = .empty,
    /// Correspondence management of `emit_rule_begin_current_maybe` / `emit_rule_end_maybe`.
    maybe_current_rule_stack: std.ArrayListUnmanaged(MaybeCurrentRuleState) = .empty,
    /// The most recent selector that was once popped by source-order split. Used for reopening in subsequent declaration.
    recent_popped_selector: ?InternId = null,
    recent_popped_selector_owner: u32 = 0,
    /// Z10-SAMESEL: True only if the previous opcode was `push_selector_scope*`.
    /// Is the following `emit_rule_begin_current*` a fresh (immediately after push) user-written rule?
    /// Distinguish whether it is reopening an existing scope (@include boundary / @at-root return, etc.).
    /// Reset to false by opcode processing other than push (rule_begin / decl, etc.).
    just_pushed_selector_scope: bool = false,
    /// Selector scope suffix temporarily removed with `@at-root`. Leave the load-css caller prefix.
    at_root_saved_selector_frames: std.ArrayListUnmanaged(SavedAtRootSelectorFrame) = .empty,
    /// Length of caller selector prefix seeded with `runTopWithSelectorPrefix()`.
    selector_prefix_depth: usize = 0,
    /// nested property namespace stack (for `foo: { ... }`).
    prop_namespace_stack: std.ArrayListUnmanaged(InternId) = .empty,
    allocator: std.mem.Allocator,
    intern_pool: *InternPool,
    rule_ir: *RuleIR,
    program: *Program,
    histogram: ?*observe_mod.OpcodeHistogram = null,
    /// Debug: if non-zero, prints STORE_LOCAL events for this slot.
    trace_slot: u32 = std.math.maxInt(u32),

    pc: u32 = 0,
    current_chunk: ChunkRef = .top,
    /// Module index of the running chunk (corresponds to `program.modules`).
    current_module: u32 = 0,
    /// Running CSS origin. In Z34a, only infra holds root/module origin.
    current_origin: OriginId = .invalid,
    /// Top-level `$variable` storage for each module (`load_mod_global` / for cross-module use).
    mod_globals_bufs: [][]Value = &.{},
    /// Did each module's global slot become "declared" at runtime?
    /// `with()` seed is entered only by the value, but remains false before the declaration (`$x: ...`) is executed.
    mod_global_declared_bufs: [][]bool = &.{},
    /// Backing storage for `mod_globals_bufs` (single allocation by avoiding alloc-in-loop).
    mod_globals_values_storage: []Value = &.{},
    /// Backing storage for `mod_global_declared_bufs` (single allocation to avoid alloc-in-loop).
    mod_global_declared_storage: []bool = &.{},
    /// Have you executed top chunk with `@use` / `@forward`?
    executed_modules: []bool = &.{},
    /// The header loud comment of the preceding `@forward`, and that module of the following module.
    /// Mapping to play when re-referenced with `@use`.
    /// Value stores InternId(u32) and maxInt(u32) is unset sentinel.
    dependency_replay_comments: []u32 = &.{},
    /// Loader origin when module is loaded for the first time.
    /// official Sass CLI re-emit pattern: previously-loaded module in subsequent @use chain
    // Used to re-emit the first-loader preamble when /// is re-visited.
    /// .invalid not loaded sentinel.
    module_first_loader_origin: []OriginId = &.{},
    /// A bool array of currently running modules (on the saved frame chain).
    /// For FL active determination of re-emit pattern (left  ->  shared, input @use right after left completion
    /// FL[shared]=left is inactive so it will not be re-emit, spec diamond comment_only).
    module_currently_running: []bool = &.{},
    /// Did the module issue visible CSS when it was first loaded (runtime judgment: if rule_ir.nodes increased)?
    /// re-emit pattern: If L has no visible output (only var def, etc.), FL preamble re-emit is not necessary.
    /// Avoid false re-emit in declaration-only module `_variables.scss` (var def only).
    module_emitted_visible: []bool = &.{},
    /// `runTop` The first `enter_frame` uses `mod_globals_bufs[root]` as is.
    prebound_top_locals: ?[]Value = null,
    prebound_top_declared: ?[]bool = null,
    /// module visibility closure (`from * module_count + to`).
    /// Built from `@use`/`@forward` dependency graph per runTop.
    module_visibility_matrix: []bool = &.{},
    /// shortest stable (`rerun_each_call == false`) dependency distance.
    module_visibility_distance: []u32 = &.{},
    /// modules transitively reachable from root via @import chain (`rerun_each_call` deps).
    /// These get global @extend visibility (same as root).
    module_import_reachable_from_root: []bool = &.{},
    /// Number of open `{ ... }` blocks on RuleIR (independent of selector_stack).
    open_rule_depth: u32 = 0,
    /// Selector-stack depth for each currently-open RuleIR style-rule block.
    /// `open_rule_depth` alone can't tell whether the current selector scope
    /// is already open because parent selectors are often push-only.
    open_rule_selector_depth_stack: std.ArrayListUnmanaged(u32) = .empty,
    /// The block (`style rule` / block at-rule) depth at which the declaration can legally be made.
    open_block_depth: u32 = 0,
    stream_chunk_flush_enabled: bool = false,
    stream_chunk_flush_threshold_nodes: usize = 0,
    stream_chunk_extend_targets: std.ArrayListUnmanaged(InternId) = .empty,
    /// Source line information to pass to `findFlushableRange` during streaming flush.
    /// Build from program.modules with `configureStreamChunkFlush` and release with `deinit`.
    stream_chunk_source_locations: []rule_ir_mod.SourceLocation = &.{},
    current_source_span: Span = .{ .start = 0, .end = 0, .file_id = 0 },
    pending_content_module: u32 = content_none_sentinel,
    pending_content_chunk: u32 = content_none_sentinel,
    pending_content_capture: []const Value = &.{},
    pending_content_capture_declared: []const bool = &.{},
    current_builtin_local_slot_hint: u32 = no_local_slot_hint,
    next_extend_relation_id: u32 = 0,
    rerun_shadow_owner_module: ?u32 = null,
    rerun_shadow_source_file: ?u32 = null,
    rerun_shadow_last_end: u32 = 0,
    rerun_shadow_root_tag: ?u32 = null,
    random_state: u64 = 0xdead_beef_cafe_babe,
    /// root VM owns the storage; child VM (meta.load-css reentrant) shares pointer to detect loops.
    load_css_stack_owner: std.ArrayListUnmanaged([]const u8) = .empty,
    load_css_stack_ptr: ?*std.ArrayListUnmanaged([]const u8) = null,
    /// root VM owns the storage; child VM (meta.load-css reentrant) shares pointer for configured-load guards.
    load_css_loaded_paths_owner: std.StringHashMapUnmanaged(void) = .empty,
    load_css_loaded_paths_ptr: ?*std.StringHashMapUnmanaged(void) = null,
    /// Apply the initial value of meta.load-css `$with` to module globals at the start of a run.
    load_css_seed_bindings: []const LoadCssSeedBinding = &.{},
    /// root VM owns the storage; child VM shares pointer for loaded module globals snapshots.
    load_css_state_owner: std.StringHashMapUnmanaged(LoadCssSavedState) = .empty,
    load_css_state_ptr: ?*std.StringHashMapUnmanaged(LoadCssSavedState) = null,
    /// root VM owns list backing storage for values stored in `load_css_state_owner`.
    load_css_state_list_pool_owner: std.ArrayListUnmanaged([]Value) = .empty,
    load_css_state_list_pool_ptr: ?*std.ArrayListUnmanaged([]Value) = null,
    /// From which module/tag can the CSS copy loaded with `meta.load-css()` be extended?
    load_css_visible_modules_owner: std.ArrayListUnmanaged(VisibleLoadCssModule) = .empty,
    load_css_visible_modules_ptr: ?*std.ArrayListUnmanaged(VisibleLoadCssModule) = null,
    load_css_next_tag_owner: u32 = 0,
    load_css_next_tag_ptr: ?*u32 = null,
    /// load-css child VM: emitted RuleIR Bundle node/extend edge into this virtual module tag.
    load_css_module_tag_override: ?u32 = null,
    shadow_context_root_tag: ?u32 = null,
    /// load-css child VM: Do not include top-level declaration in caller's style-rule context.
    load_css_strict_top_level: bool = false,
    /// Leave globals before sync in child load-css VM.
    keep_mod_globals_after_run: bool = false,

    const max_frames: usize = 4096;
    const max_stack: usize = 1 << 20;
    const SavedVMState = struct {
        const Scalars = struct {
            pc: u32,
            current_chunk: ChunkRef,
            current_module: u32,
            current_origin: OriginId,
            open_rule_depth: u32,
            open_block_depth: u32,
            at_root_selector_context_depth: u32,
            media_query_depth: u32,
            in_keyframes_block_depth: u32,
            in_keyframe_nested_at_rule_depth: u32,
            pending_content_module: u32,
            pending_content_chunk: u32,
            pending_content_capture: []const Value,
            pending_content_capture_declared: []const bool,
            current_builtin_local_slot_hint: u32,
            current_source_span: Span,
            prebound_top_locals: ?[]Value,
            prebound_top_declared: ?[]bool,
            load_css_module_tag_override: ?u32,
            shadow_context_root_tag: ?u32,
        };

        const Stacks = struct {
            stack: std.ArrayListUnmanaged(Value),
            stack_source_spans: std.ArrayListUnmanaged(Span),
            frame_stack: std.ArrayListUnmanaged(Frame),
            flow_scope_stack: std.ArrayListUnmanaged(FlowScope),
            flow_saved_slots: std.ArrayListUnmanaged(FlowSavedSlot),
            selector_stack: std.ArrayListUnmanaged(InternId),
            selector_owner_stack: std.ArrayListUnmanaged(u32),
            open_rule_selector_depth_stack: std.ArrayListUnmanaged(u32),
            at_root_selector_context_stack: std.ArrayListUnmanaged(bool),
            at_rule_media_stack: std.ArrayListUnmanaged(bool),
            at_rule_decl_container_stack: std.ArrayListUnmanaged(bool),
            open_at_rule_bubble_stack: std.ArrayListUnmanaged(OpenAtRuleBubbleFrame),
            keyframe_nested_at_rule_stack: std.ArrayListUnmanaged(KeyframeNestedAtRuleFrame),
            at_root_bubble_stack: std.ArrayListUnmanaged(AtRootBubbleFrame),
            maybe_current_rule_stack: std.ArrayListUnmanaged(MaybeCurrentRuleState),
            prop_namespace_stack: std.ArrayListUnmanaged(InternId),
        };

        scalars: Scalars,
        stacks: Stacks,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        intern_pool: *InternPool,
        color_pool: *ColorPool,
        rule_ir: *RuleIR,
        program: *Program,
    ) std.mem.Allocator.Error!VM {
        var vm: VM = .{
            .allocator = allocator,
            .intern_pool = intern_pool,
            .color_pool = color_pool,
            .rule_ir = rule_ir,
            .program = program,
            .track_stack_source_spans = programNeedsStackSourceSpans(program),
        };
        // If any seeding `appendSlice` below fails part-way through, hand the
        // partially-populated VM to its own `deinit` so the sidecar pools that
        // were already grown are released along with everything else `vm` owns.
        errdefer vm.deinit();
        // NaN-box stage 3: seed runtime sidecar pools from the shared compile-time
        // pool so that const_pool callable / unit-bearing number Values whose
        // handles index into the shared pool resolve correctly when the VM reads
        // through `vm.callable_payload_pool` / `vm.number_pool`. Runtime additions
        // (`Value.callable*` calls within instructions) append to vm's local clone
        // and are discarded with the VM (per-entry isolation).
        if (program.shared_value_pools) |shared| {
            try vm.callable_payload_pool.appendSlice(allocator, shared.callable_payload_pool.items);
            try vm.number_pool.appendSlice(allocator, shared.number_pool.items);
            try vm.list_meta_pool.appendSlice(allocator, shared.list_meta_pool.items);
            try vm.string_flags_pool.appendSlice(allocator, shared.string_flags_pool.items);
        }
        return vm;
    }

    /// sidecar bitset configuration hook entity called from builtin. `BuiltinContext.vm`
    /// Cast (`*anyopaque`) to VM and delegate to sidecar inspection method.
    /// fn pointer to set on `BuiltinContext.list_parent_sel_none_hook`.
    pub fn builtinListSidecarHook(
        vm_opaque: *anyopaque,
        handle: u32,
        items: []const Value,
    ) std.mem.Allocator.Error!void {
        const self: *VM = @ptrCast(@alignCast(vm_opaque));
        try self.maybeNoteListParentSelNoneFromItems(handle, items);
    }

    pub fn deinit(self: *VM) void {
        self.freeModGlobalsIfAny();
        self.stack.deinit(self.allocator);
        self.stack_source_spans.deinit(self.allocator);
        self.frame_stack.deinit(self.allocator);
        self.flow_scope_stack.deinit(self.allocator);
        self.flow_saved_slots.deinit(self.allocator);
        self.list_pool.deinit(self.allocator);
        self.number_pool.deinit(self.allocator);
        self.callable_payload_pool.deinit(self.allocator);
        self.list_meta_pool.deinit(self.allocator);
        self.string_flags_pool.deinit(self.allocator);
        self.list_source_shapes.deinit(self.allocator);
        self.arglist_keyword_lists.deinit(self.allocator);
        self.slash_list_preserve.deinit(self.allocator);
        self.list_parent_sel_none.deinit(self.allocator);
        {
            var it = self.map_lookup_index_cache.valueIterator();
            while (it.next()) |slot| {
                if (slot.*) |ptr| {
                    ptr.deinit(self.allocator);
                    self.allocator.destroy(ptr);
                }
            }
            self.map_lookup_index_cache.deinit(self.allocator);
        }
        self.list_index_cache.deinit(self.allocator);
        self.legacy_global_builtin_cache.deinit(self.allocator);
        self.selector_stack.deinit(self.allocator);
        self.selector_owner_stack.deinit(self.allocator);
        self.scope_push_ir_lens.deinit(self.allocator);
        self.open_rule_selector_depth_stack.deinit(self.allocator);
        self.at_root_selector_context_stack.deinit(self.allocator);
        self.at_rule_media_stack.deinit(self.allocator);
        self.at_rule_decl_container_stack.deinit(self.allocator);
        self.open_at_rule_bubble_stack.deinit(self.allocator);
        self.keyframe_nested_at_rule_stack.deinit(self.allocator);
        self.at_root_bubble_stack.deinit(self.allocator);
        self.maybe_current_rule_stack.deinit(self.allocator);
        self.clearSavedAtRootSelectorFrames();
        self.at_root_saved_selector_frames.deinit(self.allocator);
        self.stream_chunk_extend_targets.deinit(self.allocator);
        if (self.stream_chunk_source_locations.len != 0) {
            self.allocator.free(self.stream_chunk_source_locations);
            self.stream_chunk_source_locations = &.{};
        }
        self.prop_namespace_stack.deinit(self.allocator);
        if (self.load_css_stack_ptr == &self.load_css_stack_owner) {
            self.load_css_stack_owner.deinit(self.allocator);
        }
        if (self.load_css_loaded_paths_ptr == &self.load_css_loaded_paths_owner) {
            self.clearOwnedLoadCssLoadedPaths();
            self.load_css_loaded_paths_owner.deinit(self.allocator);
        }
        if (self.load_css_state_ptr == &self.load_css_state_owner) {
            self.clearOwnedLoadCssSavedStates();
            self.load_css_state_owner.deinit(self.allocator);
        }
        if (self.load_css_state_list_pool_ptr == &self.load_css_state_list_pool_owner) {
            self.clearOwnedLoadCssSavedLists();
            self.load_css_state_list_pool_owner.deinit(self.allocator);
        }
        if (self.load_css_visible_modules_ptr == &self.load_css_visible_modules_owner) {
            self.load_css_visible_modules_owner.deinit(self.allocator);
        }
        self.freeExecutedModulesIfAny();
        self.freeModuleVisibilityIfAny();
    }

    fn checkMapDuplicateKeys(self: *VM, items: []const Value) VMError!void {
        const pair_count = items.len / 2;
        if (pair_count < 8) {
            var key_i: usize = 0;
            while (key_i + 1 < items.len) : (key_i += 2) {
                var prev_i: usize = 0;
                while (prev_i < key_i) : (prev_i += 2) {
                    if (valueEq(self.intern_pool, &self.number_pool, &self.list_meta_pool, &self.string_flags_pool, &self.callable_payload_pool, self.allocator, self.color_pool, &self.list_pool, items[prev_i], items[key_i])) {
                        return error.SassError;
                    }
                }
            }
            return;
        }

        var plain_seen: std.StringHashMapUnmanaged(void) = .{};
        defer plain_seen.deinit(self.allocator);
        try plain_seen.ensureTotalCapacity(self.allocator, @intCast(pair_count));

        var special_seen: std.ArrayListUnmanaged(Value) = .empty;
        defer special_seen.deinit(self.allocator);

        var key_i: usize = 0;
        while (key_i + 1 < items.len) : (key_i += 2) {
            const key = items[key_i];
            if (plainMapKeyBytes(self.intern_pool, key)) |raw| {
                if (plain_seen.contains(raw)) return error.SassError;
                for (special_seen.items) |prev| {
                    if (valueEq(self.intern_pool, &self.number_pool, &self.list_meta_pool, &self.string_flags_pool, &self.callable_payload_pool, self.allocator, self.color_pool, &self.list_pool, prev, key)) {
                        return error.SassError;
                    }
                }
                try plain_seen.put(self.allocator, raw, {});
            } else {
                var prev_i: usize = 0;
                while (prev_i < key_i) : (prev_i += 2) {
                    if (valueEq(self.intern_pool, &self.number_pool, &self.list_meta_pool, &self.string_flags_pool, &self.callable_payload_pool, self.allocator, self.color_pool, &self.list_pool, items[prev_i], key)) {
                        return error.SassError;
                    }
                }
                try special_seen.append(self.allocator, key);
            }
        }
    }

    pub fn configureStreamChunkFlush(
        self: *VM,
        enabled: bool,
        threshold_nodes: usize,
    ) !void {
        self.stream_chunk_extend_targets.clearRetainingCapacity();
        self.stream_chunk_flush_enabled = false;
        self.stream_chunk_flush_threshold_nodes = 0;
        self.rule_ir.configureStreaming(false, 0);
        if (self.stream_chunk_source_locations.len != 0) {
            self.allocator.free(self.stream_chunk_source_locations);
            self.stream_chunk_source_locations = &.{};
        }
        if (!enabled or threshold_nodes == 0) return;

        const safe = try self.collectPotentialExtendTargetsFromProgram();
        if (!safe) return;

        const locs = try self.allocator.alloc(rule_ir_mod.SourceLocation, self.program.modules.len);
        for (self.program.modules, 0..) |mod, idx| {
            locs[idx] = .{
                .source_path = mod.module_path,
                .line_starts = mod.line_starts,
                .source_len = mod.source_len,
            };
        }
        self.stream_chunk_source_locations = locs;

        self.stream_chunk_flush_enabled = true;
        self.stream_chunk_flush_threshold_nodes = threshold_nodes;
        self.rule_ir.configureStreaming(true, threshold_nodes);
    }

    fn collectPotentialExtendTargetsFromProgram(self: *VM) !bool {
        for (self.program.modules) |*mod| {
            if (!(try self.collectPotentialExtendTargetsFromChunk(&mod.top))) return false;
            for (mod.mixins) |*chunk| {
                if (!(try self.collectPotentialExtendTargetsFromChunk(chunk))) return false;
            }
            for (mod.functions) |*chunk| {
                if (!(try self.collectPotentialExtendTargetsFromChunk(chunk))) return false;
            }
            for (mod.content_blocks) |*chunk| {
                if (!(try self.collectPotentialExtendTargetsFromChunk(chunk))) return false;
            }
            for (mod.placeholder_blocks) |*chunk| {
                if (!(try self.collectPotentialExtendTargetsFromChunk(chunk))) return false;
            }
        }
        return true;
    }

    fn collectPotentialExtendTargetsFromChunk(self: *VM, chunk: *const Chunk) !bool {
        for (chunk.code) |inst| {
            if (inst.opcode() != .record_extend) continue;
            const dynamic_target = (inst.arg_a & 0x4) != 0;
            const target_selector: InternId = @enumFromInt(inst.arg_b);
            if (dynamic_target or target_selector == .none) {
                // Streaming pre-scan only knows static @extend targets.
                // Interpolated targets are resolved at runtime, so keep flushing disabled.
                return false;
            }
            rule_ir_mod.RuleIR.collectExtendTargetBranches(
                self.allocator,
                self.intern_pool,
                target_selector,
                &self.stream_chunk_extend_targets,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return false,
            };
        }
        return true;
    }

    fn maybeFlushStreamChunks(self: *VM) VMError!void {
        if (!self.stream_chunk_flush_enabled) return;
        if (self.open_rule_depth != 0 or self.open_block_depth != 0) return;
        // While there are items left in the selector_stack, inside the parent style rule
        // emit_rule_end_if_open preceded close, but immediately after ensureCurrentRuleOpenForDeclaration
        // block of the same selector may be reopened (nested mixin
        // Raised via `@include rfs(...)` in _root.scss). If you flush at this point, block 1 will appear.
        // reopen block 2 is divided into another stream_chunk, adjacent same-selector of rule_ir
        // :root block is split into two because merge (Z10-SAMESEL) does not start.
        // Delay flush until after pop_rule_scope (selector_stack empty).
        if (self.selector_stack.items.len != 0) return;
        const locs: ?[]const rule_ir_mod.SourceLocation =
            if (self.stream_chunk_source_locations.len == 0) null else self.stream_chunk_source_locations;
        _ = self.rule_ir.flushReady(
            self.allocator,
            self.intern_pool,
            self.stream_chunk_extend_targets.items,
            locs,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SassError,
        };
    }

    fn freeModGlobalsIfAny(self: *VM) void {
        if (self.mod_globals_values_storage.len != 0) {
            self.allocator.free(self.mod_globals_values_storage);
        }
        self.mod_globals_values_storage = &.{};
        if (self.mod_globals_bufs.len != 0) {
            self.allocator.free(self.mod_globals_bufs);
        }
        self.mod_globals_bufs = &.{};

        if (self.mod_global_declared_storage.len != 0) {
            self.allocator.free(self.mod_global_declared_storage);
        }
        self.mod_global_declared_storage = &.{};
        if (self.mod_global_declared_bufs.len != 0) {
            self.allocator.free(self.mod_global_declared_bufs);
        }
        self.mod_global_declared_bufs = &.{};
        self.prebound_top_locals = null;
        self.prebound_top_declared = null;
    }

    fn freeExecutedModulesIfAny(self: *VM) void {
        if (self.executed_modules.len != 0) {
            self.allocator.free(self.executed_modules);
        }
        self.executed_modules = &.{};
        if (self.dependency_replay_comments.len != 0) {
            self.allocator.free(self.dependency_replay_comments);
        }
        self.dependency_replay_comments = &.{};
        if (self.module_first_loader_origin.len != 0) {
            self.allocator.free(self.module_first_loader_origin);
        }
        self.module_first_loader_origin = &.{};
        if (self.module_currently_running.len != 0) {
            self.allocator.free(self.module_currently_running);
        }
        self.module_currently_running = &.{};
        if (self.module_emitted_visible.len != 0) {
            self.allocator.free(self.module_emitted_visible);
        }
        self.module_emitted_visible = &.{};
    }

    fn initExecutedModules(self: *VM) VMError!void {
        self.freeExecutedModulesIfAny();
        self.executed_modules = try self.allocator.alloc(bool, self.program.modules.len);
        @memset(self.executed_modules, false);
        self.dependency_replay_comments = try self.allocator.alloc(u32, self.program.modules.len);
        @memset(self.dependency_replay_comments, std.math.maxInt(u32));
        self.module_first_loader_origin = try self.allocator.alloc(OriginId, self.program.modules.len);
        @memset(self.module_first_loader_origin, OriginId.invalid);
        self.module_currently_running = try self.allocator.alloc(bool, self.program.modules.len);
        @memset(self.module_currently_running, false);
        self.module_emitted_visible = try self.allocator.alloc(bool, self.program.modules.len);
        @memset(self.module_emitted_visible, false);
    }

    /// Used in official Sass CLI's re-emit pattern. From the beginning of the top chunk of module M
    /// Append consecutive emit_comments to rule_ir. enter_frame / emit_stmt_gap
    /// / nop is skip. Stops at first non-preamble inst.
    fn emitModulePreambleComments(self: *VM, module_id: u32) VMError!void {
        return vm_emit.emitModulePreambleComments(self, module_id);
    }

    fn emitImportOriginPreamble(self: *VM, origin: origin_mod.CssOrigin) VMError!void {
        return vm_emit.emitImportOriginPreamble(self, origin);
    }

    fn emitOriginPreamble(self: *VM, origin_id: OriginId) VMError!void {
        return vm_emit.emitOriginPreamble(self, origin_id);
    }

    fn isImportOriginOnActiveStack(self: *VM, target: OriginId) bool {
        if (!target.isValid()) return false;
        var cur = self.current_origin;
        while (cur.isValid()) {
            if (cur == target) return true;
            const cur_idx = @intFromEnum(cur);
            if (cur_idx >= self.program.origins.len) return false;
            const current = self.program.origins[cur_idx];
            if (current.kind != .import_stylesheet) return false;
            cur = current.parent_import_origin;
        }
        return false;
    }

    fn isOriginActive(self: *VM, origin_id: OriginId) bool {
        if (!origin_id.isValid()) return false;
        const origin_idx = @intFromEnum(origin_id);
        if (origin_idx >= self.program.origins.len) return false;
        const origin = self.program.origins[origin_idx];
        return switch (origin.kind) {
            .root => true,
            .module => if (origin.module_id < self.module_currently_running.len)
                self.module_currently_running[origin.module_id]
            else
                false,
            .import_stylesheet => self.isImportOriginOnActiveStack(origin_id),
        };
    }

    /// For @use/@forward target N of fresh-load, pre-scan direct deps of N,
    /// Add preamble of first loader FL[L] of already loaded module L immediately before N's CSS
    /// Emit using the official Sass CLI re-emit pattern for preserved preamble comments.
    ///
    /// FL only emit (spec
    /// in `directives/use/css/order/use_only.hrx::comment_order/diamond`
    /// If input @use right(@use shared) comes after completing left  ->  shared,
    /// FL[shared] = left is inactive so it will not be re-emit).
    fn isAlreadyEmitted(
        small: []const OriginId,
        small_len: usize,
        heap: *const std.ArrayListUnmanaged(OriginId),
        origin: OriginId,
    ) bool {
        for (small[0..small_len]) |emitted_origin| {
            if (emitted_origin == origin) return true;
        }
        for (heap.items) |emitted_origin| {
            if (emitted_origin == origin) return true;
        }
        return false;
    }

    pub fn preEmitFirstLoaderPreambles(self: *VM, target_module: u32) VMError!void {
        if (target_module >= self.program.modules.len) return;
        if (target_module >= self.executed_modules.len) return;
        if (self.executed_modules[target_module]) return;
        const target_chunk = &self.program.modules[target_module].top;
        var emitted_small: [64]OriginId = undefined;
        var emitted_small_len: usize = 0;
        var emitted_heap: std.ArrayListUnmanaged(OriginId) = .empty;
        defer emitted_heap.deinit(self.allocator);
        if (target_chunk.code.len > emitted_small.len) {
            try emitted_heap.ensureTotalCapacity(self.allocator, target_chunk.code.len - emitted_small.len);
        }
        for (target_chunk.code) |inst| {
            if (inst.opcode() != .run_dependency) continue;
            const dep_id = inst.arg_a;
            const dep_rerun_each_call = (inst.arg_b & 0b1) != 0;
            if (self.classifyDependencyRun(dep_id, dep_rerun_each_call) == .skip_body) continue;
            // "loaded" signal uses module_first_loader instead of executed_modules.
            // executed_modules[N] is not set when rerun_each_call=true (@import-routed)
            // (for rerun). module_first_loader[N] != maxInt means "loaded at least once"
            // means.
            if (dep_id >= self.module_first_loader_origin.len) continue;
            const fl_origin = self.module_first_loader_origin[dep_id];
            if (!fl_origin.isValid()) continue;
            // If L itself does not output visible output (var defs only, etc.), re-emit is not necessary.
            if (dep_id >= self.module_emitted_visible.len) continue;
            if (!self.module_emitted_visible[dep_id]) continue;
            if (!self.isOriginActive(fl_origin)) continue;
            if (isAlreadyEmitted(&emitted_small, emitted_small_len, &emitted_heap, fl_origin)) continue;
            if (emitted_small_len < emitted_small.len) {
                emitted_small[emitted_small_len] = fl_origin;
                emitted_small_len += 1;
            } else {
                try emitted_heap.append(self.allocator, fl_origin);
            }
            try self.emitOriginPreamble(fl_origin);
        }
    }

    fn replayCommentBeforeRunDependency(self: *const VM, chunk: *const Chunk, run_inst_idx: usize) ?InternId {
        if (run_inst_idx >= chunk.code.len) return null;
        var i = run_inst_idx;
        var allow_charset_const = false;
        while (i > 0) {
            i -= 1;
            const prev = chunk.code[i];
            switch (prev.opcode()) {
                .emit_stmt_gap => continue,
                .load_const => {
                    if (allow_charset_const) {
                        allow_charset_const = false;
                        continue;
                    }
                    return null;
                },
                .emit_at_rule_simple => {
                    const at_name = self.intern_pool.get(@enumFromInt(prev.arg_b));
                    if (std.ascii.eqlIgnoreCase(at_name, "charset")) {
                        allow_charset_const = true;
                        continue;
                    }
                    return null;
                },
                .emit_comment => return @enumFromInt(prev.arg_b),
                else => return null,
            }
        }
        return null;
    }

    fn freeModuleVisibilityIfAny(self: *VM) void {
        if (self.module_visibility_matrix.len != 0) {
            self.allocator.free(self.module_visibility_matrix);
        }
        self.module_visibility_matrix = &.{};
        if (self.module_visibility_distance.len != 0) {
            self.allocator.free(self.module_visibility_distance);
        }
        self.module_visibility_distance = &.{};
        if (self.module_import_reachable_from_root.len != 0) {
            self.allocator.free(self.module_import_reachable_from_root);
        }
        self.module_import_reachable_from_root = &.{};
        self.rule_ir.module_visibility_matrix = &.{};
        self.rule_ir.module_visibility_n = 0;
    }

    fn clearSavedAtRootSelectorFrames(self: *VM) void {
        for (self.at_root_saved_selector_frames.items) |frame| {
            self.allocator.free(frame.selectors);
            self.allocator.free(frame.owner_modules);
            self.allocator.free(frame.push_ir_lens);
        }
        self.at_root_saved_selector_frames.clearRetainingCapacity();
    }

    fn buildModuleVisibilityMatrix(self: *VM) VMError!void {
        self.freeModuleVisibilityIfAny();
        const n = self.program.modules.len;
        if (n == 0) return;

        const matrix_len = n * n;
        self.module_visibility_matrix = try self.allocator.alloc(bool, matrix_len);
        @memset(self.module_visibility_matrix, false);
        self.module_visibility_distance = try self.allocator.alloc(u32, matrix_len);
        @memset(self.module_visibility_distance, std.math.maxInt(u32));

        var stack: std.ArrayListUnmanaged(u32) = .empty;
        defer stack.deinit(self.allocator);
        try stack.ensureTotalCapacity(self.allocator, n);

        // Plan C: The outer loop only starts from modules whose reachable_mask is true.
        // Unreachable modules are not referenced in the VM, so no visibility line is required.
        const reachable_mask = self.program.reachable_mask;

        var from: u32 = 0;
        while (from < n) : (from += 1) {
            if (reachable_mask) |mask| {
                if (!mask[from]) continue;
            }
            stack.clearRetainingCapacity();
            self.module_visibility_matrix[from * n + from] = true;
            self.module_visibility_distance[from * n + from] = 0;
            try stack.append(self.allocator, from);

            var head: usize = 0;
            while (head < stack.items.len) : (head += 1) {
                const cur = stack.items[head];
                if (cur >= n) continue;
                const cur_dist = self.module_visibility_distance[from * n + cur];
                if (cur_dist == std.math.maxInt(u32)) continue;

                const mod = &self.program.modules[cur];
                for (mod.top.code) |inst| {
                    if (inst.opcode() != .run_dependency) continue;
                    if ((inst.arg_b & 0b1) != 0) continue;
                    const dep = inst.arg_a;
                    if (dep >= n) continue;

                    const next_dist = cur_dist + 1;
                    const slot = from * n + dep;
                    if (self.module_visibility_distance[slot] != std.math.maxInt(u32) and
                        self.module_visibility_distance[slot] <= next_dist)
                    {
                        continue;
                    }
                    self.module_visibility_distance[slot] = next_dist;
                    self.module_visibility_matrix[slot] = true;
                    try stack.append(self.allocator, dep);
                }
            }
        }

        self.rule_ir.module_visibility_matrix = self.module_visibility_matrix;
        self.rule_ir.module_visibility_n = @intCast(n);
        self.module_import_reachable_from_root = try self.allocator.alloc(bool, n);
        @memset(self.module_import_reachable_from_root, false);
        if (self.program.root_index < n) {
            stack.clearRetainingCapacity();
            const root_mod = &self.program.modules[self.program.root_index];
            for (root_mod.top.code) |inst| {
                if (inst.opcode() != .run_dependency) continue;
                if ((inst.arg_b & 0b1) == 0) continue;
                const dep = inst.arg_a;
                if (dep >= n) continue;
                if (self.module_import_reachable_from_root[dep]) continue;
                self.module_import_reachable_from_root[dep] = true;
                try stack.append(self.allocator, dep);
            }
            var import_head: usize = 0;
            while (import_head < stack.items.len) : (import_head += 1) {
                const cur = stack.items[import_head];
                if (cur >= n) continue;
                const mod = &self.program.modules[cur];
                for (mod.top.code) |inst| {
                    if (inst.opcode() != .run_dependency) continue;
                    const dep = inst.arg_a;
                    if (dep >= n) continue;
                    if (self.module_import_reachable_from_root[dep]) continue;
                    self.module_import_reachable_from_root[dep] = true;
                    try stack.append(self.allocator, dep);
                }
            }
        }
    }

    fn moduleVisibleFrom(self: *const VM, from: u32, target: u32) bool {
        const n = self.program.modules.len;
        if (from >= n or target >= n) return false;
        if (self.module_visibility_matrix.len != n * n) return from == target;
        return self.module_visibility_matrix[from * n + target];
    }

    fn moduleStableDistance(self: *const VM, from: u32, target: u32) ?u32 {
        const n = self.program.modules.len;
        if (from >= n or target >= n) return null;
        if (self.module_visibility_distance.len != n * n) return if (from == target) 0 else null;
        const dist = self.module_visibility_distance[from * n + target];
        if (dist == std.math.maxInt(u32)) return null;
        return dist;
    }

    fn extendModuleGroupStartOrder(self: *const VM, source_module: u32, canonical_target_module: u32) ?u32 {
        if (source_module < self.module_import_reachable_from_root.len and self.module_import_reachable_from_root[source_module]) {
            return null;
        }
        const dist = self.moduleStableDistance(source_module, canonical_target_module) orelse return null;
        const dist_capped: u32 = if (dist > 0xFFFF) 0xFFFF else dist;
        const source_capped: u32 = if (source_module > 0xFFFF) 0xFFFF else source_module;
        return ((0xFFFF - dist_capped) << 16) | source_capped;
    }

    pub fn noteRerunShadowRoot(self: *VM, owner_module: u32, root_tag: u32) void {
        self.rerun_shadow_owner_module = owner_module;
        self.rerun_shadow_source_file = self.current_source_span.file_id;
        self.rerun_shadow_last_end = self.current_source_span.end;
        self.rerun_shadow_root_tag = root_tag;
    }

    pub fn reusableRerunShadowRoot(self: *const VM, owner_module: u32) ?u32 {
        if (self.shadow_context_root_tag != null) return null;
        if (self.rerun_shadow_owner_module != owner_module) return null;
        if (self.rerun_shadow_source_file != self.current_source_span.file_id) return null;
        if (self.current_source_span.start < self.rerun_shadow_last_end) return null;
        return self.rerun_shadow_root_tag;
    }

    fn isPrivatePlaceholderSelector(selector: []const u8) bool {
        if (selector.len < 2 or selector[0] != '%') return false;
        return selector[1] == '-' or selector[1] == '_';
    }

    fn clearOwnedLoadCssLoadedPaths(self: *VM) void {
        var it = self.load_css_loaded_paths_owner.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.load_css_loaded_paths_owner.clearRetainingCapacity();
    }

    fn clearOwnedLoadCssSavedStates(self: *VM) void {
        var it = self.load_css_state_owner.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*.values);
            self.allocator.free(entry.value_ptr.*.declared);
        }
        self.load_css_state_owner.clearRetainingCapacity();
    }

    fn clearOwnedLoadCssSavedLists(self: *VM) void {
        for (self.load_css_state_list_pool_owner.items) |items| {
            self.allocator.free(items);
        }
        self.load_css_state_list_pool_owner.clearRetainingCapacity();
    }

    fn ensureLoadCssLoadedPathsMap(self: *VM) *std.StringHashMapUnmanaged(void) {
        if (self.load_css_loaded_paths_ptr == null) {
            self.load_css_loaded_paths_ptr = &self.load_css_loaded_paths_owner;
        }
        return self.load_css_loaded_paths_ptr.?;
    }

    fn ensureLoadCssStateMap(self: *VM) *std.StringHashMapUnmanaged(LoadCssSavedState) {
        if (self.load_css_state_ptr == null) {
            self.load_css_state_ptr = &self.load_css_state_owner;
        }
        return self.load_css_state_ptr.?;
    }

    pub fn ensureLoadCssStateListPool(self: *VM) *std.ArrayListUnmanaged([]Value) {
        if (self.load_css_state_list_pool_ptr == null) {
            self.load_css_state_list_pool_ptr = &self.load_css_state_list_pool_owner;
        }
        return self.load_css_state_list_pool_ptr.?;
    }

    fn ensureLoadCssVisibleModules(self: *VM) *std.ArrayListUnmanaged(VisibleLoadCssModule) {
        if (self.load_css_visible_modules_ptr == null) {
            self.load_css_visible_modules_ptr = &self.load_css_visible_modules_owner;
        }
        return self.load_css_visible_modules_ptr.?;
    }

    fn ensureLoadCssNextTagPtr(self: *VM) *u32 {
        if (self.load_css_next_tag_ptr == null) {
            self.load_css_next_tag_owner = @intCast(self.program.modules.len);
            self.load_css_next_tag_ptr = &self.load_css_next_tag_owner;
        }
        return self.load_css_next_tag_ptr.?;
    }

    fn resetOwnedLoadCssLoadedPaths(self: *VM) void {
        const map = self.ensureLoadCssLoadedPathsMap();
        if (map == &self.load_css_loaded_paths_owner) {
            self.clearOwnedLoadCssLoadedPaths();
        }
    }

    fn resetOwnedLoadCssSavedStates(self: *VM) void {
        const map = self.ensureLoadCssStateMap();
        if (map == &self.load_css_state_owner) {
            self.clearOwnedLoadCssSavedStates();
        }
        const list_pool = self.ensureLoadCssStateListPool();
        if (list_pool == &self.load_css_state_list_pool_owner) {
            self.clearOwnedLoadCssSavedLists();
        }
    }

    fn resetOwnedLoadCssVisibleModules(self: *VM) void {
        const list = self.ensureLoadCssVisibleModules();
        if (list == &self.load_css_visible_modules_owner) {
            self.load_css_visible_modules_owner.clearRetainingCapacity();
        }
        const next_tag = self.ensureLoadCssNextTagPtr();
        if (next_tag == &self.load_css_next_tag_owner) {
            next_tag.* = @intCast(self.program.modules.len);
        }
    }

    pub fn isLoadCssModulePathLoaded(self: *const VM, path: []const u8) bool {
        if (path.len == 0) return false;
        const map = self.load_css_loaded_paths_ptr orelse return false;
        return map.contains(path);
    }

    pub fn markLoadCssModulePathLoaded(self: *VM, path: []const u8) VMError!void {
        if (path.len == 0) return;
        const map = self.ensureLoadCssLoadedPathsMap();
        if (map.contains(path)) return;

        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        const gop = try map.getOrPut(self.allocator, owned);
        if (gop.found_existing) {
            self.allocator.free(owned);
            return;
        }
        gop.key_ptr.* = owned;
        gop.value_ptr.* = {};
    }

    pub fn effectiveModuleTag(self: *const VM) u32 {
        return self.load_css_module_tag_override orelse self.current_module;
    }

    pub fn allocateLoadCssModuleTag(self: *VM) u32 {
        const next_tag = self.ensureLoadCssNextTagPtr();
        const tag = next_tag.*;
        if (next_tag.* != std.math.maxInt(u32)) next_tag.* += 1;
        return tag;
    }

    pub fn findVisibleShadowModuleTag(self: *const VM, context_root: u32, canonical_module: u32) ?u32 {
        const list = self.load_css_visible_modules_ptr orelse return null;
        for (list.items) |entry| {
            if (entry.context_root != context_root) continue;
            if (entry.canonical_module != canonical_module) continue;
            return entry.tag;
        }
        return null;
    }

    pub fn registerVisibleLoadCssModule(
        self: *VM,
        owner_module: u32,
        context_root: u32,
        canonical_module: u32,
        tag: u32,
    ) VMError!void {
        const list = self.ensureLoadCssVisibleModules();
        for (list.items) |entry| {
            if (entry.owner_module == owner_module and entry.tag == tag) return;
        }
        try list.append(self.allocator, .{
            .owner_module = owner_module,
            .context_root = context_root,
            .canonical_module = canonical_module,
            .tag = tag,
        });

        // replay of existing edge: `extending_selector` / `target_selector` is
        // Trimmed / suppress-check / validated / split during original registration.
        //Here, directly append edge with target_module replaced.
        // **For edges derived from replay, set `is_replayed=true` to exclude them from being replayed**
        // (Otherwise, the number of edges will explode exponentially to K*2^N after N registers).
        const initial_edge_len = self.rule_ir.extend_edges.items.len;
        var edge_idx: usize = 0;
        while (edge_idx < initial_edge_len) : (edge_idx += 1) {
            const edge = self.rule_ir.extend_edges.items[edge_idx];
            if (edge.is_replayed) continue;
            if (edge.source_module != owner_module) continue;
            if (edge.target_module == tag) continue;
            try self.rule_ir.appendExtendEdge(self.allocator, .{
                .extending_selector = edge.extending_selector,
                .target_selector = edge.target_selector,
                .optional = edge.optional,
                .is_placeholder = edge.is_placeholder,
                .is_replayed = true,
                .source_module = edge.source_module,
                .target_module = tag,
                .relation_id = edge.relation_id,
                .relation_order = edge.relation_order,
                .relation_branch_index = edge.relation_branch_index,
                .relation_branch_leading_newline = edge.relation_branch_leading_newline,
                .module_group_start_order = edge.module_group_start_order,
            });
        }
    }

    fn persistableLoadCssValue(src_list_pool: []const []Value, value: Value) bool {
        if (value.kind() == .list) {
            const handle: usize = @intCast(value.listHandle());
            if (handle >= src_list_pool.len) return false;
            for (src_list_pool[handle]) |item| {
                if (!persistableLoadCssValue(src_list_pool, item)) return false;
            }
            return true;
        }
        if (value.kind() == .callable or value.kind() == .calc_fragment or value.kind() == .interp_fragment) return false;
        return true;
    }

    fn clonePersistableLoadCssValue(
        self: *VM,
        dst_list_pool: *std.ArrayListUnmanaged([]Value),
        src_list_pool: []const []Value,
        value: Value,
    ) VMError!?Value {
        if (value.kind() == .list) {
            const handle: usize = @intCast(value.listHandle());
            if (handle >= src_list_pool.len) return null;
            const src_items = src_list_pool[handle];
            const dst_items = try self.allocator.alloc(Value, src_items.len);
            errdefer self.allocator.free(dst_items);
            for (src_items, 0..) |item, i| {
                dst_items[i] = (try self.clonePersistableLoadCssValue(dst_list_pool, src_list_pool, item)) orelse {
                    self.allocator.free(dst_items);
                    return null;
                };
            }
            const dst_handle: u32 = @intCast(dst_list_pool.items.len);
            try dst_list_pool.append(self.allocator, dst_items);
            return Value.listWithMetaEx(
                dst_handle,
                value.listSeparator(self.list_meta_pool.items),
                value.listBracketed(self.list_meta_pool.items),
                value.listIsMap(self.list_meta_pool.items),
                value.listCoerceSlash(self.list_meta_pool.items),
            );
        }
        if (value.kind() == .callable or value.kind() == .calc_fragment or value.kind() == .interp_fragment) return null;
        return value;
    }

    fn copyPersistableLoadCssState(
        self: *VM,
        dst_values: []Value,
        dst_declared: []bool,
        dst_list_pool: *std.ArrayListUnmanaged([]Value),
        src_values: []const Value,
        src_declared: []const bool,
        src_list_pool: []const []Value,
    ) VMError!void {
        const n = @min(@min(dst_values.len, dst_declared.len), @min(src_values.len, src_declared.len));
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (!persistableLoadCssValue(src_list_pool, src_values[i])) continue;
            dst_values[i] = (try self.clonePersistableLoadCssValue(dst_list_pool, src_list_pool, src_values[i])) orelse continue;
            dst_declared[i] = src_declared[i];
        }
    }

    pub fn saveCurrentModuleLoadCssState(self: *VM, module_id: u32) VMError!void {
        if (module_id >= self.program.modules.len) return;
        if (module_id >= self.mod_globals_bufs.len or module_id >= self.mod_global_declared_bufs.len) return;

        const path = self.program.modules[module_id].module_path;
        if (path.len == 0) return;

        const values_src = self.mod_globals_bufs[module_id];
        const declared_src = self.mod_global_declared_bufs[module_id];
        const values = try self.allocator.alloc(Value, values_src.len);
        errdefer self.allocator.free(values);
        @memset(values, Value.nil_v);
        const declared = try self.allocator.alloc(bool, declared_src.len);
        errdefer self.allocator.free(declared);
        @memset(declared, false);
        try copyPersistableLoadCssState(
            self,
            values,
            declared,
            self.ensureLoadCssStateListPool(),
            values_src,
            declared_src,
            self.list_pool.items,
        );

        const map = self.ensureLoadCssStateMap();
        const gop = try map.getOrPut(self.allocator, path);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, path);
            gop.value_ptr.* = .{ .values = values, .declared = declared };
            return;
        }

        self.allocator.free(gop.value_ptr.*.values);
        self.allocator.free(gop.value_ptr.*.declared);
        gop.value_ptr.* = .{ .values = values, .declared = declared };
    }

    fn seedModulesFromLoadCssState(self: *VM) VMError!void {
        const map = self.load_css_state_ptr orelse return;
        for (self.program.modules, 0..) |mod, mid| {
            if (mid >= self.mod_globals_bufs.len or mid >= self.mod_global_declared_bufs.len) continue;
            if (mod.module_path.len == 0) continue;
            const saved = map.get(mod.module_path) orelse continue;
            try copyPersistableLoadCssState(
                self,
                self.mod_globals_bufs[mid],
                self.mod_global_declared_bufs[mid],
                &self.list_pool,
                saved.values,
                saved.declared,
                self.ensureLoadCssStateListPool().items,
            );
        }
    }

    fn findProgramModuleByPath(self: *const VM, path: []const u8) ?u32 {
        for (self.program.modules, 0..) |mod, mid| {
            if (mod.module_path.len == 0) continue;
            if (std.mem.eql(u8, mod.module_path, path)) return @intCast(mid);
        }
        return null;
    }

    pub fn syncLoadCssChildStates(self: *VM, child_vm: *VM) VMError!void {
        for (child_vm.program.modules, 0..) |mod, child_mid| {
            if (mod.module_path.len == 0) continue;
            const parent_mid = self.findProgramModuleByPath(mod.module_path) orelse continue;
            if (parent_mid >= self.mod_globals_bufs.len or parent_mid >= self.mod_global_declared_bufs.len) continue;
            if (child_mid >= child_vm.mod_globals_bufs.len or child_mid >= child_vm.mod_global_declared_bufs.len) continue;
            try copyPersistableLoadCssState(
                self,
                self.mod_globals_bufs[parent_mid],
                self.mod_global_declared_bufs[parent_mid],
                &self.list_pool,
                child_vm.mod_globals_bufs[child_mid],
                child_vm.mod_global_declared_bufs[child_mid],
                child_vm.list_pool.items,
            );
        }
    }

    pub fn moduleHasStaticConfigSeed(self: *const VM, module_id: u32) bool {
        for (self.program.module_config_seeds) |seed| {
            if (seed.module_id == module_id) return true;
        }
        return false;
    }

    pub fn moduleTopEmitsCss(self: *const VM, module_id: u32) bool {
        if (module_id >= self.program.modules.len) return false;
        const top = &self.program.modules[module_id].top;
        for (top.code) |inst| {
            switch (inst.opcode()) {
                .emit_rule_begin,
                .emit_rule_begin_dynamic,
                .emit_at_rule_simple,
                .emit_at_rule_begin,
                .emit_comment,
                .emit_comment_dynamic,
                .emit_decl,
                .emit_decl_raw,
                .emit_raw_decl,
                .load_emit_decl,
                .run_dependency,
                => return true,
                else => {},
            }
        }
        return false;
    }

    fn initModGlobals(self: *VM) VMError!void {
        self.freeModGlobalsIfAny();
        const n = self.program.modules.len;
        const rows = try self.allocator.alloc([]Value, n);
        errdefer self.allocator.free(rows);
        const declared_rows = try self.allocator.alloc([]bool, n);
        errdefer self.allocator.free(declared_rows);

        var total_slots: usize = 0;
        for (self.program.modules) |m| {
            total_slots += m.max_slot;
        }

        var values_storage: []Value = &.{};
        var declared_storage: []bool = &.{};
        if (total_slots != 0) {
            values_storage = try self.allocator.alloc(Value, total_slots);
            errdefer self.allocator.free(values_storage);
            declared_storage = try self.allocator.alloc(bool, total_slots);
            errdefer self.allocator.free(declared_storage);
            @memset(values_storage, Value.nil_v);
            @memset(declared_storage, false);
        }

        var cursor: usize = 0;
        for (self.program.modules, 0..) |m, i| {
            const row_len = m.max_slot;
            const row = values_storage[cursor .. cursor + row_len];
            const declared = declared_storage[cursor .. cursor + row_len];
            rows[i] = row;
            declared_rows[i] = declared;
            cursor += row_len;
        }
        std.debug.assert(cursor == total_slots);
        self.mod_globals_bufs = rows;
        self.mod_global_declared_bufs = declared_rows;
        self.mod_globals_values_storage = values_storage;
        self.mod_global_declared_storage = declared_storage;

        try self.ensureStaticEvalListsLoaded();

        for (self.program.module_config_seeds) |seed| {
            if (seed.module_id >= self.mod_globals_bufs.len) return error.InternalError;
            const row = self.mod_globals_bufs[seed.module_id];
            if (seed.slot >= row.len) return error.InternalError;
            row[seed.slot] = seed.value;
        }

        for (self.load_css_seed_bindings) |seed| {
            if (seed.module_id >= self.mod_globals_bufs.len) return error.InternalError;
            const row = self.mod_globals_bufs[seed.module_id];
            if (seed.slot >= row.len) return error.InternalError;
            if (seed.value.kind() == .nil and row[seed.slot].kind() != .nil) continue;
            row[seed.slot] = seed.value;
        }
    }

    pub fn ensureStaticEvalListsLoaded(self: *VM) VMError!void {
        if (self.program.static_eval_lists.len == 0) return;
        if (self.list_pool.items.len == 0) {
            const n = self.program.static_eval_lists.len;
            try self.list_pool.ensureTotalCapacity(self.allocator, n);
            // `list_pool` holds `[][]Value` (mutable view) while the
            // program-owned static lists are `[][]const Value`. Duplicate
            // every static list into `program.arena` so the pool keeps a
            // mutable -- but still program-lifetime -- copy. Every other
            // `list_pool.append` site already feeds arena-owned slices, so
            // this keeps ownership uniform without violating `const`.
            const arena_alloc = self.arena();
            for (self.program.static_eval_lists) |items| {
                const owned = try arena_alloc.alloc(Value, items.len);
                @memcpy(owned, items);
                self.list_pool.appendAssumeCapacity(owned);
            }
            // Static-eval list elements only have literal values that are determined at compile-time
            // (number / string-quoted / unquoted non-`&` / color / boolean / nil / nested
            // homogeneous list). parent-selector `&` is a special expr exclusive to runtime, and static_eval is
            // Do not store bare `&` in literal_string (see `tryAppendStaticValueExpr`).
            // Therefore, we can safely assert that all list handles derived from static_eval do not contain `&`.
            // Completely avoid the first walk by setting bitset to 0..n all at once.
            try self.list_parent_sel_none.resize(self.allocator, @max(n, self.list_parent_sel_none.bit_length), false);
            self.list_parent_sel_none.setRangeValue(.{ .start = 0, .end = n }, true);
            return;
        }
        if (self.list_pool.items.len < self.program.static_eval_lists.len) {
            return error.InternalError;
        }
    }

    fn markGlobalDeclared(self: *VM, module_id: u32, slot: u32) void {
        if (module_id >= self.mod_global_declared_bufs.len) return;
        if (module_id >= self.program.modules.len) return;
        const mod = &self.program.modules[module_id];
        if (slot >= mod.global_slot_count) return;
        const row = self.mod_global_declared_bufs[module_id];
        if (slot >= row.len) return;
        row[slot] = true;
    }

    fn markCurrentFrameGlobalWriteback(self: *VM, slot: u32) void {
        if (self.frame_stack.items.len == 0) return;
        if (self.current_module >= self.program.modules.len) return;
        const mod = &self.program.modules[self.current_module];
        if (slot >= mod.global_slot_count) return;
        const fr = &self.frame_stack.items[self.frame_stack.items.len - 1];
        if (slot >= fr.global_writeback.len) return;
        fr.global_writeback[slot] = true;
        fr.global_writeback_any = true;
    }

    fn writeGlobalSlotImmediate(self: *VM, module_id: u32, slot: u32, value: Value) void {
        if (module_id >= self.program.modules.len) return;
        const mod = &self.program.modules[module_id];
        if (slot >= mod.global_slot_count) return;
        const slot_usize: usize = @intCast(slot);

        if (module_id < self.mod_globals_bufs.len and module_id < self.mod_global_declared_bufs.len) {
            const row = self.mod_globals_bufs[module_id];
            const decl = self.mod_global_declared_bufs[module_id];
            if (slot_usize < row.len and slot_usize < decl.len) {
                row[slot_usize] = value;
                decl[slot_usize] = true;
            }
        }

        for (self.frame_stack.items) |*frame| {
            if (frame.caller_module_id != module_id) continue;
            if (slot_usize >= frame.locals.len or slot_usize >= frame.declared.len) continue;
            if (slot_usize >= frame.global_writeback.len) continue;
            frame.locals[slot_usize] = value;
            frame.declared[slot_usize] = true;
            frame.global_writeback[slot_usize] = true;
            frame.global_writeback_any = true;
        }
    }

    fn allocateGlobalWriteback(self: *VM, module_id: u32, local_count: usize) VMError![]bool {
        if (module_id >= self.program.modules.len) return &.{};
        const global_count: usize = @intCast(self.program.modules[module_id].global_slot_count);
        const n = @min(global_count, local_count);
        if (n == 0) return &.{};
        const slots = try self.arena().alloc(bool, n);
        @memset(slots, false);
        return slots;
    }

    fn shouldCaptureFlowScopeGlobals(self: *const VM) bool {
        if (self.frame_stack.items.len == 0) return false;
        if (self.current_chunk != .top) return true;
        return self.open_block_depth > 0 or
            self.selector_stack.items.len > 0 or
            self.prop_namespace_stack.items.len > 0;
    }

    fn pushFlowScope(self: *VM) VMError!void {
        if (!self.shouldCaptureFlowScopeGlobals()) return;
        const chunk = self.getChunk(self.current_module, self.current_chunk);
        const global_limit: usize = chunk.global_slot_base;
        try self.flow_scope_stack.append(self.allocator, .{
            .frame_depth = self.frame_stack.items.len,
            .global_limit = global_limit,
            .saved_start = self.flow_saved_slots.items.len,
        });
    }

    fn snapshotFlowScopeSlot(self: *VM, slot: usize, fr: *const Frame) VMError!void {
        if (self.flow_scope_stack.items.len == 0) return;
        const scope = &self.flow_scope_stack.items[self.flow_scope_stack.items.len - 1];
        if (scope.frame_depth != self.frame_stack.items.len) return;
        if (slot >= scope.global_limit) return;
        // In top-level chunk nested flow-controls (e.g. `@if` in `@media` / style-rule),
        // Assignment to existing slot needs to be reflected in outer scope.
        // (Updates that set `$extend-breakpoint` to false with @if must be visible in the next iter)
        //
        // On the other hand, callable chunk also restores existing slots for legacy compatibility.
        // (Example: slot update performed global fallback within function/while will be rewound after loop ends)
        if (self.current_chunk == .top and fr.declared[slot]) return;
        const slot_u32: u32 = @intCast(slot);
        for (self.flow_saved_slots.items[scope.saved_start..]) |saved| {
            if (saved.slot == slot_u32) return;
        }
        try self.flow_saved_slots.append(self.allocator, .{
            .slot = slot_u32,
            .value = fr.locals[slot],
            .declared = fr.declared[slot],
        });
    }

    fn popFlowScope(self: *VM) void {
        const scope = self.flow_scope_stack.pop() orelse return;
        defer self.flow_saved_slots.shrinkRetainingCapacity(scope.saved_start);
        if (scope.frame_depth == 0 or self.frame_stack.items.len == 0) return;
        if (scope.frame_depth != self.frame_stack.items.len) return;
        const fr = &self.frame_stack.items[self.frame_stack.items.len - 1];
        const n = @min(scope.global_limit, @min(fr.locals.len, fr.declared.len));
        for (self.flow_saved_slots.items[scope.saved_start..]) |saved| {
            const slot: usize = @intCast(saved.slot);
            if (slot >= n) continue;
            fr.locals[slot] = saved.value;
            fr.declared[slot] = saved.declared;
        }
    }

    fn unwindFlowScopesForCurrentFrame(self: *VM) void {
        const frame_depth = self.frame_stack.items.len;
        while (self.flow_scope_stack.items.len > 0) {
            const scope = self.flow_scope_stack.items[self.flow_scope_stack.items.len - 1];
            if (scope.frame_depth != frame_depth) break;
            self.popFlowScope();
        }
    }

    pub fn isModuleGlobalDeclared(self: *const VM, module_id: u32, slot: u32) bool {
        if (module_id >= self.mod_global_declared_bufs.len) return false;
        if (module_id >= self.program.modules.len) return false;
        const mod = &self.program.modules[module_id];
        if (slot >= mod.global_slot_count) return false;
        const row = self.mod_global_declared_bufs[module_id];
        if (slot >= row.len) return false;
        return row[slot];
    }

    pub fn currentBuiltinLocalSlotHint(self: *const VM) ?u32 {
        if (self.current_builtin_local_slot_hint == no_local_slot_hint) return null;
        return self.current_builtin_local_slot_hint;
    }

    pub fn isCurrentFrameSlotDeclared(self: *const VM, slot: u32) bool {
        if (self.frame_stack.items.len == 0) return false;
        const fr = self.frame_stack.items[self.frame_stack.items.len - 1];
        if (slot >= fr.declared.len) return false;
        return fr.declared[slot];
    }

    fn requireDeclaredFrameSlot(self: *const VM, fr: *const Frame, slot: usize) VMError!Value {
        _ = self;
        if (slot >= fr.locals.len or slot >= fr.declared.len) return error.BadJump;
        if (!fr.declared[slot]) return error.SassError;
        return fr.locals[slot];
    }

    fn readFrameLocalWithFallback(self: *const VM, fr: *const Frame, slot: usize) VMError!Value {
        if (slot >= fr.locals.len) return error.BadJump;
        if (slot < fr.declared.len and !fr.declared[slot] and self.current_module < self.program.modules.len) {
            const mod = &self.program.modules[self.current_module];
            if (slot < mod.local_fallback_slots.len) {
                const fallback_raw = mod.local_fallback_slots[slot];
                if (fallback_raw != std.math.maxInt(u32)) {
                    const fallback_slot: usize = @intCast(fallback_raw);
                    if (fallback_slot >= fr.locals.len) return error.BadJump;
                    return fr.locals[fallback_slot];
                }
            }
        }
        return fr.locals[slot];
    }

    fn requireDeclaredModuleSlot(self: *const VM, module_id: u32, slot: u32) VMError!Value {
        if (module_id >= self.mod_globals_bufs.len or module_id >= self.mod_global_declared_bufs.len) {
            return error.BadJump;
        }
        const row = self.mod_globals_bufs[module_id];
        const declared = self.mod_global_declared_bufs[module_id];
        const target_slot: usize = @intCast(slot);
        if (target_slot >= row.len or target_slot >= declared.len) return error.BadJump;
        if (!declared[target_slot]) return error.SassError;
        return row[target_slot];
    }

    fn arena(self: *VM) std.mem.Allocator {
        return self.program.arena.allocator();
    }

    fn copyFields(comptime T: type, dst: anytype, src: anytype) void {
        inline for (std.meta.fields(T)) |field| {
            @field(dst.*, field.name) = @field(src.*, field.name);
        }
    }

    pub fn saveState(self: *VM) SavedVMState {
        // SAFETY: copyFields() writes every field in `saved.scalars` and `saved.stacks` before return.
        var saved: SavedVMState = undefined;
        copyFields(SavedVMState.Scalars, &saved.scalars, self);
        copyFields(SavedVMState.Stacks, &saved.stacks, self);
        inline for (std.meta.fields(SavedVMState.Stacks)) |field| @field(self, field.name) = .empty;
        return saved;
    }

    pub fn restoreState(self: *VM, saved: *const SavedVMState) void {
        inline for (std.meta.fields(SavedVMState.Stacks)) |field| @field(self, field.name).deinit(self.allocator);
        copyFields(SavedVMState.Stacks, self, &saved.stacks);
        copyFields(SavedVMState.Scalars, self, &saved.scalars);
    }

    pub fn clearModuleRuleState(self: *VM, clear_saved_at_root_selector_frames: bool) void {
        self.selector_stack.clearRetainingCapacity();
        self.selector_owner_stack.clearRetainingCapacity();
        self.at_root_selector_context_stack.clearRetainingCapacity();
        self.open_rule_selector_depth_stack.clearRetainingCapacity();
        self.at_rule_media_stack.clearRetainingCapacity();
        self.at_rule_decl_container_stack.clearRetainingCapacity();
        self.open_at_rule_bubble_stack.clearRetainingCapacity();
        self.keyframe_nested_at_rule_stack.clearRetainingCapacity();
        self.at_root_bubble_stack.clearRetainingCapacity();
        self.at_root_selector_context_depth = 0;
        self.media_query_depth = 0;
        self.in_keyframes_block_depth = 0;
        self.in_keyframe_nested_at_rule_depth = 0;
        self.maybe_current_rule_stack.clearRetainingCapacity();
        if (clear_saved_at_root_selector_frames) self.clearSavedAtRootSelectorFrames();
        self.prop_namespace_stack.clearRetainingCapacity();
    }

    pub fn runTop(self: *VM) VMError!void {
        try self.runTopWithSelectorPrefix(&.{});
    }

    pub fn runTopWithSelectorPrefix(self: *VM, selector_prefix: []const InternId) VMError!void {
        if (self.load_css_stack_ptr == null) self.load_css_stack_ptr = &self.load_css_stack_owner;
        if (self.load_css_stack_ptr == &self.load_css_stack_owner) self.load_css_stack_owner.clearRetainingCapacity();
        self.resetOwnedLoadCssLoadedPaths();
        self.resetOwnedLoadCssSavedStates();
        self.resetOwnedLoadCssVisibleModules();
        self.arglist_keyword_lists.clearRetainingCapacity();
        // pre-size hot ArrayLists to avoid repeated realloc during execution
        try self.stack.ensureTotalCapacity(self.allocator, 4096);
        try self.frame_stack.ensureTotalCapacity(self.allocator, 64);
        try self.flow_scope_stack.ensureTotalCapacity(self.allocator, 32);
        try self.initModGlobals();
        try self.seedModulesFromLoadCssState();
        try self.initExecutedModules();
        try self.buildModuleVisibilityMatrix();
        defer {
            self.freeExecutedModulesIfAny();
            if (!self.keep_mod_globals_after_run) self.freeModGlobalsIfAny();
        }
        self.next_extend_relation_id = 0;
        self.rerun_shadow_owner_module = null;
        self.rerun_shadow_source_file = null;
        self.rerun_shadow_last_end = 0;
        self.rerun_shadow_root_tag = null;

        if (self.program.modules.len == 0) return;
        if (self.program.root_index >= self.program.modules.len) return error.InternalError;
        self.current_origin = if (self.program.origins.len > 0) @enumFromInt(0) else .invalid;
        // The root module is also currently-running track target (re-emit FL active judgment
        // Allow root preamble re-emit when FL = root index).
        if (self.program.root_index < self.module_currently_running.len) {
            self.module_currently_running[self.program.root_index] = true;
        }
        defer if (self.program.root_index < self.module_currently_running.len) {
            self.module_currently_running[self.program.root_index] = false;
        };
        try self.runTopModuleWithSelectorPrefix(self.program.root_index, selector_prefix, false);
        try self.rule_ir.normalizeAtRootBubblesRuleIR(self.allocator, self.intern_pool);
        try self.rule_ir.normalizeNestedMediaRuleIR(self.allocator, self.intern_pool);
    }

    const DependencyRunEffect = enum { skip_body, run_body };

    pub fn classifyDependencyRun(self: *VM, module_id: u32, rerun_each_call: bool) DependencyRunEffect {
        const shadow_copy = rerun_each_call or
            (self.load_css_module_tag_override != null and self.load_css_module_tag_override.? != self.current_module);
        if (!shadow_copy and module_id < self.executed_modules.len and self.executed_modules[module_id]) {
            return .skip_body;
        }
        return .run_body;
    }

    pub fn replayDependencySkipPreamble(self: *VM, module_id: u32) VMError!void {
        if (self.selector_stack.items.len == 0 and self.open_block_depth == 0 and
            module_id < self.dependency_replay_comments.len)
        {
            const replay_comment = self.dependency_replay_comments[module_id];
            if (replay_comment != std.math.maxInt(u32)) {
                try self.rule_ir.appendComment(
                    self.allocator,
                    @enumFromInt(replay_comment),
                    self.currentSourceSpan(),
                );
            }
        }
    }

    fn runDependencyBody(self: *VM, module_id: u32, rerun_each_call: bool, is_forward: bool) VMError!void {
        return vm_cross_module.runDependencyBody(self, module_id, rerun_each_call, is_forward);
    }

    fn runTopDependencyAtCurrentPosition(self: *VM, module_id: u32, rerun_each_call: bool, is_forward: bool) VMError!void {
        return vm_cross_module.runTopDependencyAtCurrentPosition(self, module_id, rerun_each_call, is_forward);
    }

    fn runTopModuleWithSelectorPrefix(self: *VM, module_id: u32, selector_prefix: []const InternId, rerun_each_call: bool) VMError!void {
        return vm_cross_module.runTopModuleWithSelectorPrefix(self, module_id, selector_prefix, rerun_each_call);
    }

    pub const StepResult = union(enum) {
        continue_exec,
        halt_top,
        exit_run_chunk: ?Value,
    };

    pub fn runLoopTop(self: *VM) VMError!void {
        while (true) {
            const r = try self.step();
            switch (r) {
                .continue_exec => {},
                .halt_top => return,
                .exit_run_chunk => return error.InternalError,
            }
        }
    }

    pub fn step(self: *VM) VMError!StepResult {
        const chunk = self.getChunk(self.current_module, self.current_chunk);
        if (self.pc >= chunk.code.len) return error.BadJump;
        if (chunk.code_origin.len == chunk.code.len) {
            self.current_origin = chunk.code_origin[self.pc];
        }

        const inst = chunk.code[self.pc];
        self.pc += 1;
        if (chunk.source_locs.len == chunk.code.len) {
            const loc = chunk.source_locs[self.pc - 1];
            self.current_source_span = .{
                .start = loc.start,
                .end = loc.end,
                .file_id = self.load_css_module_tag_override orelse loc.module_id,
            };
        } else {
            self.current_source_span = .{
                .start = 0,
                .end = 0,
                .file_id = self.load_css_module_tag_override orelse self.current_module,
            };
        }
        if (self.histogram) |h| h.tick(inst.opcode());
        perf.note(.vm_step);

        // Z10-SAMESEL: `just_pushed_selector_scope` is **fresh while stepInner is running
        // Indicates immediately after selector scope. Usually the previous opcode is push_selector_scope type
        // You can judge by whether it was, but `@extend` is the selector scope push and the first declaration
        // Insert `record_extend` between open. If you set it to false here, it will be user-written.
        // sibling nested rule is incorrectly determined as compiler-synthesized reopen, adjacent same-selector
        // block merge runs. record_extend does not consume scope freshness, so immediately after push
        // Maintain freshness.
        const now_op = inst.opcode();
        const now_is_push = (now_op == .push_selector_scope or
            now_op == .push_selector_scope_dynamic or
            (now_op == .record_extend and self.just_pushed_selector_scope));
        defer self.just_pushed_selector_scope = now_is_push;

        return stepInner(self, inst, chunk) catch |err| {
            // CLI-FIX-E Step 2: To build source frame in driver's catch path,
            // Record the span where the most recent error occurred in the thread-local context.
            error_format.recordErrorSpan(
                self.current_source_span.start,
                self.current_source_span.end,
                self.current_source_span.file_id,
            );
            error_format.recordErrorTag(err);
            if (error_format.verboseErrorsEnabled()) {
                if (err == error.SassError) {
                    self.printCurrentVmErrorSource();
                }
                if (!self.suppress_diagnostics) {
                    vmStderrPrint("zsass err module={d} chunk={s} pc={d} op={s} {}\n", .{
                        self.current_module,
                        chunk.name,
                        self.pc - 1,
                        @tagName(inst.opcode()),
                        err,
                    });
                }
            }
            return err;
        };
    }

    fn pendingCssMathCallPreserveContext(self: *VM) bool {
        const chunk = self.getChunk(self.current_module, self.current_chunk);
        if (self.pc >= chunk.code.len) return self.stackContainsCssMathCallable();

        const next = chunk.code[self.pc];
        if (next.opcode() == .call_builtin) {
            return switch (next.arg_a) {
                0, // math.abs / global abs()
                4, // math.min / global min()
                5, // math.max / global max()
                11, // sqrt()
                12, // pow()
                13, // log()
                14, // sin()
                15, // cos()
                16, // tan()
                17, // asin()
                18, // acos()
                19, // atan()
                20, // atan2()
                21, // hypot()
                105, // exp()
                106, // sign()
                107, // mod()
                108, // rem()
                110, // clamp()
                113, // math.round / global round()
                => true,
                else => false,
            };
        }

        if (next.opcode() != .call_indirect or next.arg_a != 0) return self.stackContainsCssMathCallable();

        const meta_idx: usize = @intCast(next.arg_b);
        if (meta_idx >= chunk.builtin_call_meta.len) return self.stackContainsCssMathCallable();
        const argc: usize = @intCast(chunk.builtin_call_meta[meta_idx].argc);
        if (argc == 0 or self.stack.items.len < argc) return self.stackContainsCssMathCallable();

        const callable = self.stack.items[self.stack.items.len - argc];
        if (callable.kind() != .callable or !callable.callableIsCss(&self.callable_payload_pool)) return self.stackContainsCssMathCallable();
        if (callable.callableNameIntern(&self.callable_payload_pool) == .none) return self.stackContainsCssMathCallable();

        const name = self.intern_pool.get(callable.callableNameIntern(&self.callable_payload_pool));
        return identifierEq(name, "calc") or
            identifierEq(name, "calc-size") or
            identifierEq(name, "min") or
            identifierEq(name, "max") or
            identifierEq(name, "clamp") or
            identifierEq(name, "round") or
            identifierEq(name, "hypot") or
            self.stackContainsCssMathCallable();
    }

    fn stackContainsCssMathCallable(self: *VM) bool {
        for (self.stack.items) |value| {
            if (value.kind() != .callable or !value.callableIsCss(&self.callable_payload_pool)) continue;
            const name_id = value.callableNameIntern(&self.callable_payload_pool);
            if (name_id == .none) continue;
            const name = self.intern_pool.get(name_id);
            if (identifierEq(name, "calc") or
                identifierEq(name, "calc-size") or
                identifierEq(name, "min") or
                identifierEq(name, "max") or
                identifierEq(name, "clamp") or
                identifierEq(name, "round") or
                identifierEq(name, "hypot"))
            {
                return true;
            }
        }
        return false;
    }

    fn stepUnpack(self: *VM, expect: u32) VMError!void {
        // @each destructuring: extras ignored; missing slots filled with nil (official Sass CLI).
        // Non-list value behaves as a one-element row (first slot bound, rest nil).
        const listv = try self.pop();
        if (listv.kind() != .list) {
            var i: u32 = 0;
            while (i < expect) : (i += 1) {
                if (i == 0) try self.push(listv) else try self.push(Value.nil_v);
            }
            return;
        }

        const items = self.list_pool.items[listv.listHandle()];
        var i: u32 = 0;
        while (i < expect) : (i += 1) {
            if (i < items.len) try self.push(items[i]) else try self.push(Value.nil_v);
        }
    }

    fn stepListItem(self: *VM) VMError!void {
        const idxv = try self.pop();
        const listv = try self.maybeResolveParentSelectorValue(try self.pop());
        if (idxv.kind() != .number) {
            try self.push(Value.nil_v);
            return;
        }

        const idx_f = idxv.asF64(&self.number_pool);
        if (!std.math.isFinite(idx_f) or idx_f < 0) {
            try self.push(Value.nil_v);
            return;
        }

        const idx_trunc = @trunc(idx_f);
        const max_idx_f: f64 = @floatFromInt(std.math.maxInt(usize));
        if (idx_trunc > max_idx_f) {
            try self.push(Value.nil_v);
            return;
        }

        const idx: usize = @intFromFloat(idx_trunc);
        if (listv.kind() != .list) {
            if (idx == 0) {
                try self.push(listv);
            } else {
                try self.push(Value.nil_v);
            }
            return;
        }

        const view = value_mod.inspectLogicalListView(self.list_pool.items, listv).?;
        if (!view.is_map) {
            if (idx >= view.items.len) {
                try self.push(Value.nil_v);
            } else {
                try self.push(view.items[idx]);
            }
            return;
        }

        const start = idx * 2;
        if (start + 1 >= view.items.len) {
            try self.push(Value.nil_v);
            return;
        }

        const pair = [_]Value{ view.items[start], view.items[start + 1] };
        try self.push(try self.makeListValue(pair[0..], .space, false));
    }

    fn stepInner(self: *VM, inst: Instruction, chunk: *const Chunk) VMError!StepResult {
        switch (inst.opcode()) {
            .nop => return .continue_exec,
            .halt => return .halt_top,

            .load_const => {
                const idx: usize = @intCast(inst.arg_b);
                if (idx >= chunk.const_pool.len) return error.BadJump;
                try self.push(chunk.const_pool[idx]);
            },
            .load_local => {
                const slot_raw: u32 = inst.arg_b;
                if (resolver_mod.decodeCrossAssignSlot(slot_raw)) |target| {
                    if (target.module_id >= self.mod_globals_bufs.len) return error.BadJump;
                    const row = self.mod_globals_bufs[target.module_id];
                    const target_slot: usize = @intCast(target.slot);
                    if (target_slot >= row.len) return error.BadJump;
                    try self.push(row[target_slot]);
                    return .continue_exec;
                }
                const slot: usize = @intCast(slot_raw);
                const fr = self.frame_stack.items[self.frame_stack.items.len - 1];
                try self.push(try self.readFrameLocalWithFallback(&fr, slot));
            },
            .load_local_strict => {
                const slot: usize = @intCast(inst.arg_b);
                const fr = self.frame_stack.items[self.frame_stack.items.len - 1];
                try self.push(try self.requireDeclaredFrameSlot(&fr, slot));
            },
            .store_local, .store_local_writeback => {
                const writeback = inst.opcode() == .store_local_writeback;
                const slot_raw: u32 = inst.arg_b;
                if (resolver_mod.decodeCrossAssignSlot(slot_raw)) |target| {
                    if (target.module_id >= self.mod_globals_bufs.len) return error.BadJump;
                    const row = self.mod_globals_bufs[target.module_id];
                    const target_slot: usize = @intCast(target.slot);
                    if (target_slot >= row.len) return error.BadJump;
                    row[target_slot] = try self.pop();
                    self.markGlobalDeclared(target.module_id, target.slot);
                    if (self.trace_slot == target.slot and self.trace_slot != std.math.maxInt(u32)) {
                        vmStderrPrint(
                            "zsass-slot-trace STORE_CROSS slot={d} mod={d} pc={d} kind={s}\n",
                            .{ target.slot, target.module_id, self.pc - 1, @tagName(row[target_slot].kind()) },
                        );
                    }
                    return .continue_exec;
                }
                const slot: usize = @intCast(slot_raw);
                const fr = &self.frame_stack.items[self.frame_stack.items.len - 1];
                if (slot >= fr.locals.len) return error.BadJump;
                if (slot >= fr.declared.len) return error.BadJump;
                if (!writeback) try self.snapshotFlowScopeSlot(slot, fr);
                const stored_value = try self.pop();
                fr.locals[slot] = stored_value;
                fr.declared[slot] = true;
                if (writeback) {
                    self.markCurrentFrameGlobalWriteback(slot_raw);
                    self.writeGlobalSlotImmediate(self.current_module, slot_raw, stored_value);
                }
                self.markGlobalDeclared(self.current_module, slot_raw);
                if (self.trace_slot == slot_raw) {
                    vmStderrPrint(
                        "zsass-slot-trace STORE slot={d} mod={d} pc={d} kind={s}\n",
                        .{ slot_raw, self.current_module, self.pc - 1, @tagName(fr.locals[slot].kind()) },
                    );
                }
            },
            .clear_local => {
                const slot: usize = @intCast(inst.arg_b);
                const fr = &self.frame_stack.items[self.frame_stack.items.len - 1];
                if (slot >= fr.locals.len or slot >= fr.declared.len) return error.BadJump;
                fr.locals[slot] = Value.nil_v;
                fr.declared[slot] = false;
                if (self.trace_slot == @as(u32, @intCast(slot))) {
                    vmStderrPrint(
                        "zsass-slot-trace CLEAR slot={d} mod={d} pc={d}\n",
                        .{ slot, self.current_module, self.pc - 1 },
                    );
                }
            },
            .pop => {
                _ = try self.pop();
            },
            .dup => {
                const v = self.stack.items[self.stack.items.len - 1];
                try self.push(v);
            },
            .unpack => {
                try self.stepUnpack(inst.arg_a);
            },
            .list_len => {
                const listv = try self.maybeResolveParentSelectorValue(try self.pop());
                if (listv.kind() != .list) {
                    try self.push(Value.numberUnitless(1));
                } else {
                    const view = value_mod.inspectLogicalListView(self.list_pool.items, listv).?;
                    const row_len: usize = if (view.is_map) view.items.len / 2 else view.items.len;
                    try self.push(Value.numberUnitless(@floatFromInt(row_len)));
                }
            },
            .list_item => {
                try self.stepListItem();
            },
            .coerce_slash_free => {
                const value = try self.maybeResolveParentSelectorValue(try self.pop());
                try self.push(try self.coerceInterpolatedSlashListValue(value));
            },

            .add => {
                const b = try self.maybeResolveParentSelectorValue(try self.pop());
                const a = try self.maybeResolveParentSelectorValue(try self.pop());
                try self.push(try addValues(
                    self.intern_pool,
                    &self.number_pool,
                    self.allocator,
                    &self.list_pool,
                    self.color_pool,
                    &self.callable_payload_pool,
                    a,
                    b,
                    self.pendingCssMathCallPreserveContext(),
                ));
            },
            .sub => {
                const b = try self.maybeResolveParentSelectorValue(try self.pop());
                const a = try self.maybeResolveParentSelectorValue(try self.pop());
                try self.push(try subValues(
                    self.intern_pool,
                    &self.number_pool,
                    self.allocator,
                    &self.list_pool,
                    self.color_pool,
                    &self.slash_list_preserve,
                    a,
                    b,
                    self.pendingCssMathCallPreserveContext(),
                ));
            },
            .mul => {
                const b = try self.maybeResolveParentSelectorValue(try self.pop());
                const a = try self.maybeResolveParentSelectorValue(try self.pop());
                try self.push(try mulValues(
                    self.intern_pool,
                    &self.number_pool,
                    self.allocator,
                    &self.list_pool,
                    self.color_pool,
                    &self.slash_list_preserve,
                    a,
                    b,
                    self.pendingCssMathCallPreserveContext(),
                ));
            },
            .div => {
                const b = try self.maybeResolveParentSelectorValue(try self.pop());
                const a = try self.maybeResolveParentSelectorValue(try self.pop());
                const slash_dep: ?deprecation_mod.SlashDivDeprecationSite = blk: {
                    const fid: usize = @intCast(self.current_source_span.file_id);
                    if (fid >= self.program.modules.len) break :blk null;
                    const mod = self.program.modules[fid];
                    if (mod.module_path.len == 0) break :blk null;
                    const pos = sourceOffsetToLineColVm(mod.line_starts, mod.source_len, self.current_source_span.start);
                    break :blk .{
                        .opts = &self.deprecation_opts,
                        .path = mod.module_path,
                        .line = pos.line + 1,
                        .col = pos.col + 1,
                    };
                };
                try self.push(try divValues(
                    self.intern_pool,
                    &self.number_pool,
                    self.allocator,
                    &self.list_pool,
                    self.color_pool,
                    &self.slash_list_preserve,
                    a,
                    b,
                    self.pendingCssMathCallPreserveContext(),
                    slash_dep,
                ));
            },
            .mod => {
                const b = try self.maybeResolveParentSelectorValue(try self.pop());
                const a = try self.maybeResolveParentSelectorValue(try self.pop());
                try self.push(try modValues(self.intern_pool, &self.number_pool, self.allocator, &self.list_pool, self.color_pool, &self.slash_list_preserve, a, b));
            },
            .neg => {
                const a = try self.maybeResolveParentSelectorValue(try self.pop());
                if (a.kind() == .number) {
                    try self.push(try Value.number(-a.asF64(&self.number_pool), a.unitId(&self.number_pool), &self.number_pool, self.allocator));
                } else {
                    try self.push(try unaryPrefixValue(self, "-", a, .require_non_calc));
                }
            },
            .pos => {
                const a = try self.maybeResolveParentSelectorValue(try self.pop());
                if (a.kind() == .number) {
                    try self.push(a);
                } else {
                    try self.push(try unaryPrefixValue(self, "+", a, .require_non_calc));
                }
            },
            .slash_prefix => {
                const a = try self.maybeResolveParentSelectorValue(try self.pop());
                try self.push(try unaryPrefixValue(self, "/", a, .allow_calc));
            },
            .not_op => {
                const a = try self.maybeResolveParentSelectorValue(try self.pop());
                try self.push(if (a.isTruthy()) Value.false_v else Value.true_v);
            },

            .eq => try self.cmpOp(.eq),
            .neq => try self.cmpOp(.neq),
            .lt => try self.cmpOp(.lt),
            .gt => try self.cmpOp(.gt),
            .le => try self.cmpOp(.le),
            .ge => try self.cmpOp(.ge),

            .and_op => {
                const b = try self.maybeResolveParentSelectorValue(try self.pop());
                const a = try self.maybeResolveParentSelectorValue(try self.pop());
                try self.push(if (a.isTruthy() and b.isTruthy()) Value.true_v else Value.false_v);
            },
            .or_op => {
                const b = try self.maybeResolveParentSelectorValue(try self.pop());
                const a = try self.maybeResolveParentSelectorValue(try self.pop());
                try self.push(if (a.isTruthy() or b.isTruthy()) Value.true_v else Value.false_v);
            },

            .jmp => {
                const off: i32 = @bitCast(inst.arg_b);
                self.pc = @intCast(@as(i64, @intCast(self.pc)) + @as(i64, off));
            },
            .jmp_if_false => {
                const v = try self.maybeResolveParentSelectorValue(try self.pop());
                if (!v.isTruthy()) {
                    const off: i32 = @bitCast(inst.arg_b);
                    self.pc = @intCast(@as(i64, @intCast(self.pc)) + @as(i64, off));
                }
            },
            .branch_if_false_local => {
                const slot: usize = @intCast(inst.arg_a);
                const fr = self.frame_stack.items[self.frame_stack.items.len - 1];
                const v = try self.maybeResolveParentSelectorValue(try self.readFrameLocalWithFallback(&fr, slot));
                if (!v.isTruthy()) {
                    const off: i32 = @bitCast(inst.arg_b);
                    self.pc = @intCast(@as(i64, @intCast(self.pc)) + @as(i64, off));
                }
            },
            .jmp_if_true => {
                const v = try self.maybeResolveParentSelectorValue(try self.pop());
                if (v.isTruthy()) {
                    const off: i32 = @bitCast(inst.arg_b);
                    self.pc = @intCast(@as(i64, @intCast(self.pc)) + @as(i64, off));
                }
            },
            .push_flow_scope => try self.pushFlowScope(),
            .pop_flow_scope => self.popFlowScope(),

            .enter_frame,
            .leave_frame,
            .call_mixin,
            .call_function,
            .call_content,
            .call_placeholder,
            => return self.stepInnerCall(inst, chunk),
            .record_extend => return self.stepInnerEmit(inst, chunk),
            .call_builtin => return self.stepInnerCall(inst, chunk),
            .load_mod_global => {
                const mid: u32 = inst.arg_a;
                const slot: usize = @intCast(inst.arg_b);
                if (mid >= self.mod_globals_bufs.len) return error.BadJump;
                const row = self.mod_globals_bufs[mid];
                if (slot >= row.len) return error.BadJump;
                try self.push(row[slot]);
            },
            .load_mod_global_strict => {
                try self.push(try self.requireDeclaredModuleSlot(inst.arg_a, inst.arg_b));
            },
            .run_dependency,
            .call_indirect,
            .ret,
            .ret_value,
            .ret_void,
            => return self.stepInnerCall(inst, chunk),

            .emit_rule_begin,
            .emit_rule_begin_current,
            .emit_rule_begin_current_maybe,
            .push_selector_scope,
            .emit_rule_end,
            .emit_rule_end_maybe,
            .emit_rule_end_if_open,
            .emit_rule_end_pop,
            .pop_rule_scope,
            => return self.stepInnerEmit(inst, chunk),
            .load_local_add_const => {
                const slot: usize = @intCast(inst.arg_a);
                const idx: usize = @intCast(inst.arg_b);
                if (idx >= chunk.const_pool.len) return error.BadJump;
                const fr = self.frame_stack.items[self.frame_stack.items.len - 1];
                const l = try self.maybeResolveParentSelectorValue(try self.readFrameLocalWithFallback(&fr, slot));
                const c = chunk.const_pool[idx];
                try self.push(try addValues(
                    self.intern_pool,
                    &self.number_pool,
                    self.allocator,
                    &self.list_pool,
                    self.color_pool,
                    &self.callable_payload_pool,
                    l,
                    c,
                    self.pendingCssMathCallPreserveContext(),
                ));
            },
            .load_local_mul_const => {
                const slot: usize = @intCast(inst.arg_a);
                const idx: usize = @intCast(inst.arg_b);
                if (idx >= chunk.const_pool.len) return error.BadJump;
                const fr = self.frame_stack.items[self.frame_stack.items.len - 1];
                if (self.trace_slot == @as(u32, @intCast(slot))) {
                    const raw = fr.locals[slot];
                    const declared = if (slot < fr.declared.len) fr.declared[slot] else false;
                    vmStderrPrint(
                        "zsass-slot-trace LOAD_MUL slot={d} pc={d} declared={any} raw_kind={s} frames={d}\n",
                        .{ slot, self.pc - 1, declared, @tagName(raw.kind()), self.frame_stack.items.len },
                    );
                }
                const l = try self.maybeResolveParentSelectorValue(try self.readFrameLocalWithFallback(&fr, slot));
                const c = chunk.const_pool[idx];
                const preserve_css_math = self.pendingCssMathCallPreserveContext();
                const out = mulValues(
                    self.intern_pool,
                    &self.number_pool,
                    self.allocator,
                    &self.list_pool,
                    self.color_pool,
                    &self.slash_list_preserve,
                    l,
                    c,
                    preserve_css_math,
                ) catch |err| {
                    if (err == error.SassError) {
                        self.printLoadLocalMulConstDiagnostic(slot, idx, l, c, preserve_css_math);
                    }
                    return err;
                };
                try self.push(out);
            },
            .load_local_ge_const => {
                const slot: usize = @intCast(inst.arg_a);
                const idx: usize = @intCast(inst.arg_b);
                if (idx >= chunk.const_pool.len) return error.BadJump;
                const fr = self.frame_stack.items[self.frame_stack.items.len - 1];
                const raw_local = try self.maybeResolveParentSelectorValue(try self.readFrameLocalWithFallback(&fr, slot));
                const raw_const = chunk.const_pool[idx];
                const local_val = try self.coerceSlashFreeValue(raw_local);
                const const_val = try self.coerceSlashFreeValue(raw_const);
                if (local_val.kind() != .number or const_val.kind() != .number) return error.SassError;
                const pair = try comparableNumbers(self.intern_pool, &self.number_pool, self.allocator, local_val, const_val);
                const ord = fuzzyNumberOrder(pair.a, pair.b);
                try self.push(if (ord == .gt or ord == .eq) Value.true_v else Value.false_v);
            },
            .load_const_add_local => {
                const slot: usize = @intCast(inst.arg_a);
                const idx: usize = @intCast(inst.arg_b);
                if (idx >= chunk.const_pool.len) return error.BadJump;
                const fr = self.frame_stack.items[self.frame_stack.items.len - 1];
                const c = chunk.const_pool[idx];
                const l = try self.maybeResolveParentSelectorValue(try self.readFrameLocalWithFallback(&fr, slot));
                try self.push(try addValues(
                    self.intern_pool,
                    &self.number_pool,
                    self.allocator,
                    &self.list_pool,
                    self.color_pool,
                    &self.callable_payload_pool,
                    c,
                    l,
                    self.pendingCssMathCallPreserveContext(),
                ));
            },
            .load_emit_decl,
            .emit_decl,
            .emit_decl_raw,
            .emit_raw_decl,
            .emit_at_rule_simple,
            .emit_at_rule_begin,
            .emit_at_rule_end,
            .emit_comment,
            .emit_comment_dynamic,
            .emit_error,
            .emit_debug,
            .emit_warn,
            .emit_stmt_gap,
            .emit_fragment,
            => return self.stepInnerEmit(inst, chunk),

            .make_number_unit,
            .make_string,
            .make_list,
            .make_bool,
            => return self.stepInnerMake(inst),

            .load_arg => {
                if (self.frame_stack.items.len == 0) return error.InternalError;
                const fr = self.frame_stack.items[self.frame_stack.items.len - 1];
                const chunk_args_base: usize = self.getChunk(self.current_module, self.current_chunk).arg_base;
                const slot = chunk_args_base + inst.arg_a;
                if (slot >= fr.locals.len) return error.BadJump;
                try self.push(fr.locals[slot]);
            },
            .set_content => return self.stepInnerCall(inst, chunk),

            .make_selector => return self.stepInnerMake(inst),
            .emit_rule_begin_dynamic,
            .push_selector_scope_dynamic,
            .push_at_root_scope,
            .pop_at_root_scope,
            .push_at_root_bubble,
            .pop_at_root_bubble,
            .emit_decl_dynamic,
            .push_prop_namespace,
            .pop_prop_namespace,
            => return self.stepInnerEmit(inst, chunk),
            .load_parent_selector => {
                // `&` as an expression value: eagerly resolve to the current parent selector list
                // so that `$x: &;` captures the selector in effect at assignment time (matching
                // official Sass CLI), rather than being re-resolved against whatever `&` happens to be
                // when the stored value is later used.
                const current_id = self.currentAmpersandSelector();
                if (current_id == null) {
                    try self.push(Value.nil_v);
                } else {
                    const current_text = self.intern_pool.get(current_id.?);
                    const val = self.selectorTextToValue(current_text) catch |err| switch (err) {
                        error.SassError => Value.string(current_id.?, false),
                        else => return err,
                    };
                    try self.push(val);
                }
            },
            ._op_count => return error.InternalError,
        }
        return .continue_exec;
    }

    fn stepInnerMake(self: *VM, inst: Instruction) VMError!StepResult {
        switch (inst.opcode()) {
            .make_number_unit => {
                const unit: InternId = @enumFromInt(inst.arg_b);
                const bitsv = try self.pop();
                if (bitsv.kind() != .number) return error.InternalError;
                try self.push(try Value.number(bitsv.asF64(&self.number_pool), unit, &self.number_pool, self.allocator));
            },
            .make_string => {
                const id: InternId = @enumFromInt(inst.arg_b);
                const quoted = inst.arg_a != 0;
                try self.push(Value.string(id, quoted));
            },
            .make_list => {
                const len: usize = inst.arg_a;
                const flags = inst.arg_b;
                const items = try self.arena().alloc(Value, len);
                // SAFETY: If `track_stack_source_spans`, `item_spans` is assigned before any read; otherwise it is never read.
                var item_spans: []Span = undefined;
                var i: usize = 0;
                var list_parent_selector_none = true;
                if (self.track_stack_source_spans) {
                    item_spans = try self.arena().alloc(Span, len);
                    while (i < len) : (i += 1) {
                        const popped = try self.popWithSpan();
                        items[len - 1 - i] = popped.value;
                        item_spans[len - 1 - i] = popped.span;
                        list_parent_selector_none = list_parent_selector_none and self.valueKnownNoParentSelector(popped.value);
                    }
                } else {
                    while (i < len) : (i += 1) {
                        const item = try self.pop();
                        items[len - 1 - i] = item;
                        list_parent_selector_none = list_parent_selector_none and self.valueKnownNoParentSelector(item);
                    }
                }
                const is_map = Value.unpackListMap(flags);
                if (is_map) {
                    if ((items.len & 1) != 0) return error.SassError;
                    try self.checkMapDuplicateKeys(items);
                }
                const h: u32 = @intCast(self.list_pool.items.len);
                try self.list_pool.append(self.allocator, items);
                if (self.track_stack_source_spans) {
                    var shape: ListSourceShape = .{};
                    if (len > 0 and item_spans[0].start > self.current_source_span.start) {
                        shape.first_item_gap = item_spans[0].start - self.current_source_span.start;
                    }
                    if (len > 1 and item_spans[1].start > item_spans[0].end) {
                        shape.first_pair_gap = item_spans[1].start - item_spans[0].end;
                    }
                    try self.list_source_shapes.put(self.allocator, h, shape);
                }
                var list_value = Value.listWithMetaEx(
                    h,
                    Value.unpackListSeparator(flags),
                    Value.unpackListBracketed(flags),
                    is_map,
                    Value.unpackListSlashCoerce(flags),
                );
                if (list_parent_selector_none) list_value = list_value.withListParentSelectorNone();
                try self.push(list_value);
            },
            .make_bool => {
                try self.push(if (inst.arg_a != 0) Value.true_v else Value.false_v);
            },
            .make_selector => {
                const n: usize = @intCast(inst.arg_a);
                if (self.stack.items.len < n) return error.StackUnderflow;
                const base = self.stack.items.len - n;
                var acc: std.ArrayListUnmanaged(u8) = .empty;
                defer acc.deinit(self.allocator);
                const interpolation_context = (inst.arg_b & opcode_mod.make_selector_flag_interpolation_context) != 0;
                const preserve_empty_seps = (inst.arg_b & opcode_mod.make_selector_flag_preserve_empty_separators) != 0;
                const source_name_interp = (inst.arg_b & opcode_mod.make_selector_flag_source_name_interp) != 0;
                const source_args_interp = (inst.arg_b & opcode_mod.make_selector_flag_source_args_interp) != 0;
                const source_has_interp = source_name_interp or source_args_interp;
                const call_info = interpolatedCallInfo(
                    self.allocator,
                    self.intern_pool,
                    self.stack.items[base .. base + n],
                    source_name_interp,
                    source_args_interp,
                );
                var i: usize = 0;
                var preserved_parent_marker = false;
                var calc_interp_marked = false;
                // Empty interpolation collapses a separator only when both
                // neighboring parts are whitespace. Preserve the separator when
                // either side is non-whitespace, e.g. `.a #{""}:valid`.
                var pending_pop_on_next_ws = false;
                while (i < n) : (i += 1) {
                    const raw_value = self.stack.items[base + i];
                    // in non-interpolation_context (= non-value context, selector/prop/extend)
                    // If we receive a bare `&` value, it eagerly resolves to parent text
                    // The merged text of `.b { &#{""} { ... } }` and `.b { #{"&"} { ... } }`
                    // becomes `.b`, and downstream combineNestedRuleSelector incorrectly combines into `.b .b`.
                    // Leave `&` as literal and leave it to `&` replacement on the combineNestedRuleSelector side.
                    if (!interpolation_context and
                        self.selector_stack.items.len > 0 and
                        raw_value.kind() == .string and
                        std.mem.eql(u8, std.mem.trim(u8, self.intern_pool.get(raw_value.stringIntern()), " \t\r\n"), "&"))
                    {
                        try acc.appendSlice(self.allocator, self.intern_pool.get(raw_value.stringIntern()));
                        preserved_parent_marker = true;
                        continue;
                    }
                    const part = try self.maybeResolveParentSelectorValue(raw_value);
                    const part_preserve_literal_calc = part.kind() == .string and
                        !part.stringQuoted(self.string_flags_pool.items) and
                        part.stringPreserveLiteralText(self.string_flags_pool.items) and
                        isUnquotedCalcLikeString(self.intern_pool, part);
                    if (shouldMarkCalcInterpString(self.intern_pool, part) or (interpolation_context and (source_has_interp or part_preserve_literal_calc) and isUnquotedCalcLikeString(self.intern_pool, part))) calc_interp_marked = true;
                    if (part.kind() == .nil) {
                        if (!preserve_empty_seps and acc.items.len > 0) {
                            const last = acc.items[acc.items.len - 1];
                            if (last == ' ' or last == '\t') pending_pop_on_next_ws = true;
                        }
                        continue;
                    }
                    if (!self.hasActiveSelectorContext() and isBareUnquotedParentSelectorValue(self.intern_pool, part)) continue;
                    const in_call_args = call_info.context != .none and i >= call_info.arg_start and i + 1 < n;
                    const id = if (call_info.preserve_quoted_args and in_call_args and part.kind() == .string and
                        !part.stringQuoted(self.string_flags_pool.items) and
                        isCommaSeparatorFragment(self.intern_pool.get(part.stringIntern())))
                        try self.intern_pool.intern(", ")
                    else if (call_info.unquote_quoted_args and in_call_args and part.kind() == .string and part.stringQuoted(self.string_flags_pool.items))
                        try valueToInternIdDeclUnquotedStringPart(
                            self.intern_pool,
                            &self.number_pool,
                            self.allocator,
                            &self.list_pool,
                            self.color_pool,
                            &self.slash_list_preserve,
                            part,
                        )
                    else if (call_info.preserve_quoted_args and in_call_args)
                        try valueToInternIdDecl(
                            self.intern_pool,
                            &self.number_pool,
                            self.allocator,
                            &self.list_pool,
                            self.color_pool,
                            &self.slash_list_preserve,
                            part,
                            false,
                        )
                    else if (interpolation_context and part.kind() == .list and
                        listValueContainsQuotedStringRecursive(&self.list_pool, part))
                        try valueToInternIdInterpolated(
                            self.intern_pool,
                            &self.number_pool,
                            self.allocator,
                            &self.list_pool,
                            self.color_pool,
                            &self.slash_list_preserve,
                            part,
                        )
                    else
                        try valueToInternIdRaw(self.intern_pool, &self.number_pool, self.allocator, &self.list_pool, self.color_pool, &self.slash_list_preserve, part);
                    const s = self.intern_pool.get(id);
                    if (s.len == 0) {
                        if (!preserve_empty_seps and acc.items.len > 0) {
                            const last = acc.items[acc.items.len - 1];
                            if (last == ' ' or last == '\t') pending_pop_on_next_ws = true;
                        }
                        continue;
                    }
                    if (pending_pop_on_next_ws) {
                        if (s[0] == ' ' or s[0] == '\t') {
                            //Both sides ws  ->  pop one and collapse to single space.
                            _ = acc.pop();
                        }
                        pending_pop_on_next_ws = false;
                    }
                    const protect_interpolated_calc_list =
                        interpolation_context and
                        source_has_interp and
                        part.kind() == .list and
                        css_utils.containsCalcFunction(s);
                    if (protect_interpolated_calc_list) calc_interp_marked = true;
                    const protect_interpolated_calc =
                        protect_interpolated_calc_list or
                        self.shouldProtectInterpolatedCalcString(part, s, interpolation_context, source_has_interp, part_preserve_literal_calc);
                    if (protect_interpolated_calc) {
                        try acc.appendSlice(self.allocator, calc_interp_preserve_start);
                        try acc.appendSlice(self.allocator, s);
                        try acc.appendSlice(self.allocator, calc_interp_preserve_end);
                    } else {
                        try acc.appendSlice(self.allocator, s);
                    }
                }
                if (pending_pop_on_next_ws) {
                    while (acc.items.len > 0 and (acc.items[acc.items.len - 1] == ' ' or acc.items[acc.items.len - 1] == '\t')) {
                        _ = acc.pop();
                    }
                }
                self.stack.items.len -= n;
                if (self.track_stack_source_spans) self.stack_source_spans.items.len -= n;
                var merged_text: []const u8 = try self.allocator.dupe(u8, acc.items);
                defer self.allocator.free(@constCast(merged_text));
                const escape_normalized = try css_utils.normalizeInterpolatedEscapedHyphens(self.allocator, merged_text);
                if (escape_normalized.ptr != merged_text.ptr) {
                    self.allocator.free(@constCast(merged_text));
                    merged_text = escape_normalized;
                }
                if (interpolation_context) {
                    const url_quote_normalized = try normalizeInterpolatedUrlSingleQuotes(self.allocator, merged_text);
                    if (!(url_quote_normalized.ptr == merged_text.ptr and url_quote_normalized.len == merged_text.len)) {
                        self.allocator.free(@constCast(merged_text));
                        merged_text = url_quote_normalized;
                    }
                } else {
                    const quote_normalized_selector = try normalizeSelectorAdjacentQuotedFragments(self.allocator, merged_text);
                    if (!(quote_normalized_selector.ptr == merged_text.ptr and quote_normalized_selector.len == merged_text.len)) {
                        self.allocator.free(@constCast(merged_text));
                        merged_text = quote_normalized_selector;
                    }
                }
                const merged_value_marked = calc_interp_marked and css_utils.containsCalcFunction(merged_text);
                const merged = if (merged_value_marked)
                    (try internCalcInterpString(self.intern_pool, self.allocator, merged_text)).stringIntern()
                else
                    try self.intern_pool.intern(merged_text);
                // preserved_parent_marker is set in selector-context and `&` is literal
                // If left as merged text. In the later stage (internDynamicSelectorValue etc.)
                // maybeResolveParentSelectorValue makes bare "&" parent text again
                // Push with preserve_ampersand flag to prevent it from resolving.
                const merged_value = if (preserved_parent_marker)
                    Value.stringPreservingAmpersand(merged, false)
                else if (interpolation_context)
                    Value.string(merged, false).withPreserveLiteralText()
                else
                    Value.string(merged, false);
                try self.push(merged_value);
            },
            else => unreachable,
        }
        return .continue_exec;
    }

    fn stepInnerCall(self: *VM, inst: Instruction, chunk: *const Chunk) VMError!StepResult {
        switch (inst.opcode()) {
            .enter_frame => {
                const lc: usize = inst.arg_a;
                if (self.frame_stack.items.len == 0) {
                    if (self.prebound_top_locals) |pb| {
                        const declared = self.prebound_top_declared orelse return error.InternalError;
                        if (pb.len != lc) return error.InternalError;
                        if (declared.len != lc) return error.InternalError;
                        try self.frame_stack.append(self.allocator, .{
                            .locals = pb,
                            .declared = declared,
                            .global_writeback = &.{},
                            .return_pc = 0,
                            .return_chunk = 0,
                            .save_sp = 0,
                            .caller_module_id = 0,
                            .content_module_id = content_none_sentinel,
                            .content_chunk_id = content_none_sentinel,
                            .content_capture_locals = &.{},
                            .content_capture_declared = &.{},
                        });
                        self.prebound_top_locals = null;
                        self.prebound_top_declared = null;
                        return .continue_exec;
                    }
                    const locals = try self.arena().alloc(Value, lc);
                    @memset(locals, Value.nil_v);
                    const declared = try self.arena().alloc(bool, lc);
                    @memset(declared, false);
                    try self.frame_stack.append(self.allocator, .{
                        .locals = locals,
                        .declared = declared,
                        .global_writeback = &.{},
                        .return_pc = 0,
                        .return_chunk = 0,
                        .save_sp = 0,
                        .caller_module_id = 0,
                        .content_module_id = content_none_sentinel,
                        .content_chunk_id = content_none_sentinel,
                        .content_capture_locals = &.{},
                        .content_capture_declared = &.{},
                    });
                    return .continue_exec;
                }
                const fr = &self.frame_stack.items[self.frame_stack.items.len - 1];
                if (fr.locals.len == 0) {
                    fr.locals = try self.arena().alloc(Value, lc);
                    @memset(fr.locals, Value.nil_v);
                    fr.declared = try self.arena().alloc(bool, lc);
                    @memset(fr.declared, false);
                } else {
                    if (fr.locals.len != lc) return error.InternalError;
                    if (fr.declared.len != lc) return error.InternalError;
                }
            },
            .leave_frame => return self.doRetVoid(),
            .call_mixin => {
                const target_mod: u32 = inst.arg_a;
                const u = unpackCallArgB(inst.arg_b);
                try self.doCall(target_mod, .{ .mixin = u.id }, u.argc);
                return .continue_exec;
            },
            .call_function => {
                const target_mod: u32 = inst.arg_a;
                const u = unpackCallArgB(inst.arg_b);
                try self.doCall(target_mod, .{ .function = u.id }, u.argc);
                return .continue_exec;
            },
            .call_content => {
                const meta_idx: usize = @intCast(inst.arg_b);
                if (meta_idx >= chunk.builtin_call_meta.len) return error.BadJump;
                const meta = chunk.builtin_call_meta[meta_idx];
                const argc: usize = @intCast(meta.argc);
                const names_start: usize = @intCast(meta.arg_names_start);
                const names_end: usize = names_start + argc;
                if (names_end > chunk.builtin_call_arg_names.len) return error.BadJump;
                const arg_names = chunk.builtin_call_arg_names[names_start..names_end];
                try self.validateCallArgOrdering(arg_names);

                var args_buf: [64]Value = undefined;
                const args = if (argc <= args_buf.len)
                    args_buf[0..argc]
                else
                    try self.allocator.alloc(Value, argc);
                defer if (argc > args_buf.len) self.allocator.free(args);
                var i: usize = argc;
                while (i > 0) {
                    i -= 1;
                    const raw = try self.pop();
                    args[i] = try self.coerceSlashFreeValueForUserCallArg(raw);
                }
                const expanded = try self.expandCallArgsWithSplat(args, arg_names);
                defer self.freeExpandedCallArgs(expanded);

                const fr = self.frame_stack.items[self.frame_stack.items.len - 1];
                if (fr.content_chunk_id == content_none_sentinel) return .continue_exec;
                // If one combined selector rule is already open, such as `.a { .b { .. } }`,
                // No additional wrapper is needed as it includes the entire scope of selector_stack.
                // Only when no rule is open yet (rule_depth == 0) parent style_rule's
                // Wrap selector only once for content body.
                const open_current_rule_wrapper = self.selector_stack.items.len != 0 and
                    self.open_rule_depth == 0 and
                    self.open_block_depth > self.open_rule_depth;
                if (open_current_rule_wrapper) {
                    try self.openCurrentRuleBlock(true, false);
                }
                self.doCallContentPrepared(
                    fr.content_module_id,
                    fr.content_chunk_id,
                    fr.content_capture_locals,
                    fr.content_capture_declared,
                    expanded.args,
                    expanded.arg_names,
                    expanded.last_spread_separator,
                ) catch |call_err| {
                    if (open_current_rule_wrapper) {
                        try self.closeMaybeCurrentRuleBlock();
                    }
                    return call_err;
                };
                if (open_current_rule_wrapper) {
                    self.frame_stack.items[self.frame_stack.items.len - 1].auto_close_current_rule_on_return = true;
                }
                return .continue_exec;
            },
            .call_placeholder => {
                const target_mod: u32 = inst.arg_a;
                const target_sel: InternId = @enumFromInt(inst.arg_b);
                const pid = self.findPlaceholderChunk(target_mod, target_sel) orelse return .continue_exec;
                try self.doCall(target_mod, .{ .placeholder = pid }, 0);
                return .continue_exec;
            },
            .call_builtin => {
                const builtin_id: u32 = inst.arg_a;
                const meta_idx: usize = @intCast(inst.arg_b);
                if (meta_idx >= chunk.builtin_call_meta.len) return error.BadJump;
                const meta = chunk.builtin_call_meta[meta_idx];
                const argc: u32 = meta.argc;
                const names_start: usize = @intCast(meta.arg_names_start);
                const names_end: usize = names_start + argc;
                if (names_end > chunk.builtin_call_arg_names.len) return error.BadJump;
                const arg_names = chunk.builtin_call_arg_names[names_start..names_end];
                if (builtinRejectsTopLevelRest(builtin_id) and callArgNamesContainSplat(arg_names)) {
                    return error.SassError;
                }
                try self.validateCallArgOrdering(arg_names);
                const had_splat = callArgNamesContainSplat(arg_names);
                const argc_usize: usize = @intCast(argc);
                var args_buf: [64]Value = undefined;
                const args = if (argc_usize <= args_buf.len)
                    args_buf[0..argc_usize]
                else
                    try self.allocator.alloc(Value, argc_usize);
                defer if (argc_usize > args_buf.len) self.allocator.free(args);
                var i: u32 = argc;
                while (i > 0) {
                    i -= 1;
                    const resolved = try self.maybeResolveParentSelectorValue(try self.pop());
                    args[@intCast(i)] = if (builtinSkipsSlashFreeCoercion(builtin_id))
                        resolved
                    else
                        try self.coerceSlashFreeValue(resolved);
                }
                const expanded = try self.expandCallArgsWithSplat(args, arg_names);
                defer self.freeExpandedCallArgs(expanded);
                const prev_slot_hint = self.current_builtin_local_slot_hint;
                self.current_builtin_local_slot_hint = meta.local_slot_hint;
                defer self.current_builtin_local_slot_hint = prev_slot_hint;
                const raw_out = try self.dispatchBuiltinArgs(builtin_id, expanded.args, expanded.arg_names);
                const out = try self.maybeSerializeDirectBuiltinColorWithSplat(builtin_id, had_splat, raw_out);
                try self.push(out);
            },
            .run_dependency => {
                const rerun_each_call = (inst.arg_b & 0b1) != 0;
                const is_forward = (inst.arg_b & 0b10) != 0;
                // The preceding loud comment can only be saved via `@forward` dep.
                // via `@use` dep's preceding comment is in module-local context (sass-spec
                // diamond `use_only::comment_order`) So when replaying on the second visit
                // The comment from the left route is leaked to the right route, violating the spec.
                if (is_forward and
                    self.current_chunk == .top and
                    self.selector_stack.items.len == 0 and
                    self.open_block_depth == 0 and
                    inst.arg_a < self.dependency_replay_comments.len and
                    self.moduleTopEmitsCss(inst.arg_a) and
                    self.dependency_replay_comments[inst.arg_a] == std.math.maxInt(u32))
                {
                    const run_inst_idx: usize = self.pc - 1;
                    if (self.replayCommentBeforeRunDependency(chunk, run_inst_idx)) |comment_id| {
                        self.dependency_replay_comments[inst.arg_a] = @intFromEnum(comment_id);
                    }
                }
                try self.runTopDependencyAtCurrentPosition(inst.arg_a, rerun_each_call, is_forward);
            },
            .call_indirect => {
                const meta_idx: usize = @intCast(inst.arg_b);
                if (meta_idx >= chunk.builtin_call_meta.len) return error.BadJump;
                const meta = chunk.builtin_call_meta[meta_idx];
                const argc: usize = @intCast(meta.argc);
                const names_start: usize = @intCast(meta.arg_names_start);
                const names_end: usize = names_start + argc;
                if (names_end > chunk.builtin_call_arg_names.len) return error.BadJump;
                const arg_names = chunk.builtin_call_arg_names[names_start..names_end];
                try self.validateCallArgOrdering(arg_names);
                var raw_args_buf: [64]Value = undefined;
                const raw_args = if (argc <= raw_args_buf.len)
                    raw_args_buf[0..argc]
                else
                    try self.allocator.alloc(Value, argc);
                defer if (argc > raw_args_buf.len) self.allocator.free(raw_args);
                var i: usize = argc;
                while (i > 0) {
                    i -= 1;
                    const resolved = try self.maybeResolveParentSelectorValue(try self.pop());
                    raw_args[i] = resolved;
                }
                const raw_target = try self.pop();
                const target_v = if (raw_target.kind() == .nil)
                    self.fallbackCallableFromLocals(inst.arg_a != 0) orelse raw_target
                else
                    raw_target;
                const preserve_slash_free = target_v.kind() == .callable and target_v.callableIsCss(&self.callable_payload_pool);
                var args_buf: [64]Value = undefined;
                const args = if (argc <= args_buf.len)
                    args_buf[0..argc]
                else
                    try self.allocator.alloc(Value, argc);
                defer if (argc > args_buf.len) self.allocator.free(args);
                for (raw_args, 0..) |arg, idx| {
                    args[idx] = if (preserve_slash_free) arg else try self.coerceSlashFreeValueForUserCallArg(arg);
                }
                const expanded = try self.expandCallArgsWithSplat(args, arg_names);
                defer self.freeExpandedCallArgs(expanded);
                if (try self.invokeCallable(inst.arg_a != 0, target_v, expanded.args, expanded.arg_names, expanded.last_spread_separator)) |out| {
                    if (inst.arg_a == 0) try self.push(out);
                }
            },
            .ret, .ret_value => {
                const v = try self.pop();
                return self.doRetValue(v);
            },
            .ret_void => {
                return self.doRetVoid();
            },
            .set_content => {
                if (inst.arg_b == content_none_sentinel) {
                    self.pending_content_module = content_none_sentinel;
                    self.pending_content_chunk = content_none_sentinel;
                    self.pending_content_capture = &.{};
                    self.pending_content_capture_declared = &.{};
                } else {
                    const cap = if (self.frame_stack.items.len > 0) self.frame_stack.items[self.frame_stack.items.len - 1] else null;
                    self.pending_content_module = inst.arg_a;
                    self.pending_content_chunk = inst.arg_b;
                    self.pending_content_capture = if (cap) |fr| fr.locals else &.{};
                    self.pending_content_capture_declared = if (cap) |fr| fr.declared else &.{};
                }
            },
            else => unreachable,
        }
        return .continue_exec;
    }

    fn stepInnerEmit(self: *VM, inst: Instruction, chunk: *const Chunk) VMError!StepResult {
        _ = chunk;
        switch (inst.opcode()) {
            .record_extend => {
                if (self.selector_stack.items.len == 0) return error.SassError;
                const extending_selector = self.selector_stack.items[self.selector_stack.items.len - 1];
                const optional = (inst.arg_a & 0x1) != 0;
                const dynamic_target = (inst.arg_a & 0x4) != 0;
                const target_selector: InternId = if (dynamic_target)
                    try self.internExtendTargetValue(try self.pop())
                else
                    @enumFromInt(inst.arg_b);
                const target_raw = std.mem.trim(u8, self.intern_pool.get(target_selector), " \t\r\n");
                const is_placeholder = if ((inst.arg_a & 0x2) != 0)
                    true
                else
                    selector_helpers_mod.simplePlaceholderSelectorKey(target_raw) != null;
                const source_module = self.effectiveModuleTag();
                const relation_id = self.next_extend_relation_id;
                if (self.next_extend_relation_id != std.math.maxInt(u32)) {
                    self.next_extend_relation_id += 1;
                }
                const in_media = self.mediaQueryActive();
                try self.rule_ir.noteExtendRelationMediaContext(
                    self.allocator,
                    source_module,
                    relation_id,
                    in_media,
                );
                if (self.load_css_module_tag_override) |_| {
                    const group_start = self.extendModuleGroupStartOrder(source_module, self.current_module);
                    try self.rule_ir.appendExtendRelationScoped(
                        self.allocator,
                        self.intern_pool,
                        extending_selector,
                        target_selector,
                        optional,
                        is_placeholder,
                        source_module,
                        source_module,
                        relation_id,
                        group_start,
                    );
                } else {
                    const source_is_root = source_module == self.program.root_index or
                        (source_module < self.module_import_reachable_from_root.len and self.module_import_reachable_from_root[source_module]);
                    var target_module: u32 = 0;
                    while (target_module < self.program.modules.len) : (target_module += 1) {
                        if (!source_is_root and !self.moduleVisibleFrom(source_module, target_module)) continue;
                        if (is_placeholder and target_module != source_module and isPrivatePlaceholderSelector(target_raw)) {
                            continue;
                        }
                        const group_start = self.extendModuleGroupStartOrder(source_module, target_module);
                        try self.rule_ir.appendExtendRelationScoped(
                            self.allocator,
                            self.intern_pool,
                            extending_selector,
                            target_selector,
                            optional,
                            is_placeholder,
                            source_module,
                            target_module,
                            relation_id,
                            group_start,
                        );
                    }
                }
                if (self.load_css_visible_modules_ptr) |list| {
                    for (list.items) |entry| {
                        if (entry.owner_module != source_module) continue;
                        if (entry.tag == source_module) continue;
                        const group_start = self.extendModuleGroupStartOrder(source_module, entry.canonical_module);
                        try self.rule_ir.appendExtendRelationScoped(
                            self.allocator,
                            self.intern_pool,
                            extending_selector,
                            target_selector,
                            optional,
                            is_placeholder,
                            source_module,
                            entry.tag,
                            relation_id,
                            group_start,
                        );
                    }
                }
                return .continue_exec;
            },
            .emit_rule_begin => {
                try self.closeOpenMaybeCurrentRuleBeforeBoundary();
                try self.openRuleScope(inst, true, false);
            },
            .emit_rule_begin_current => {
                try self.closeOpenMaybeCurrentRuleBeforeBoundary();
                try self.openCurrentRuleBlock(false, inst.arg_a != 0);
            },
            .emit_rule_begin_current_maybe => {
                try self.closeOpenMaybeCurrentRuleBeforeBoundary();
                try self.openCurrentRuleBlock(true, inst.arg_a != 0);
            },
            .push_selector_scope => {
                try self.closeOpenMaybeCurrentRuleBeforeBoundary();
                try self.openRuleScope(inst, false, false);
            },
            .emit_rule_end => {
                try self.closeRuleBlock();
            },
            .emit_rule_end_maybe => {
                try self.closeMaybeCurrentRuleBlock();
            },
            .emit_rule_end_if_open => {
                try self.closeRuleBlockIfOpen();
            },
            .emit_rule_end_pop => {
                try self.closeRuleBlock();
                self.recent_popped_selector = self.selector_stack.pop();
                self.recent_popped_selector_owner = self.selector_owner_stack.pop() orelse self.currentEmitModuleTag();
                self.suppressParentReopenMergeAfterSameSelectorChild();
                try self.popScopePushIrLenAndCheckEmpty();
            },
            .pop_rule_scope => {
                try self.closeOpenMaybeCurrentRuleBeforeBoundary();
                self.recent_popped_selector = self.selector_stack.pop();
                self.recent_popped_selector_owner = self.selector_owner_stack.pop() orelse self.currentEmitModuleTag();
                self.suppressParentReopenMergeAfterSameSelectorChild();
                try self.popScopePushIrLenAndCheckEmpty();
            },
            .load_emit_decl => {
                const slot: usize = @intCast(inst.arg_a);
                const prop: u32 = inst.arg_b;
                const fr = self.frame_stack.items[self.frame_stack.items.len - 1];
                const val_raw = try self.maybeResolveParentSelectorValue(try self.readFrameLocalWithFallback(&fr, slot));
                // A variable-referenced slash list must coerce to its numeric
                // division at the declaration boundary (sass-spec
                // values/numbers/divide/slash_free/variable.hrx::local:
                //`$a: 1/2; b {c: $a}`  ->  `c: 0.5`).
                const val = try self.coerceSlashFreeValueForDecl(val_raw, false);
                if (val.kind() == .nil) return .continue_exec;
                if (val.kind() == .string and !val.stringQuoted(self.string_flags_pool.items)) {
                    const raw = self.intern_pool.get(val.stringIntern());
                    if (raw.len == 0) return .continue_exec;
                }
                try self.reopenRecentNestedRuleForDeclaration();
                try self.ensureCurrentRuleOpenForDeclaration();
                if (self.open_block_depth == 0 or (self.load_css_strict_top_level and self.open_rule_depth == 0)) return error.SassError;
                if (self.mediaQueryActive() and self.open_rule_depth == 0 and !self.declarationAtRuleActive()) return error.SassError;
                const input_prop_name = self.intern_pool.get(@enumFromInt(prop));
                if (self.prop_namespace_stack.items.len > 0 and std.mem.startsWith(u8, input_prop_name, "--")) {
                    return error.SassError;
                }
                const prop_id = try self.applyPropertyNamespace(@enumFromInt(prop));
                const prop_name = self.intern_pool.get(prop_id);
                const is_custom_property = std.mem.startsWith(u8, prop_name, "--");
                if (try self.declarationValueNeedsIndentedCommaSyntaxError(val, 0)) return error.SassError;
                try ensureDeclarationValueIsCssValue(&self.list_pool, val, is_custom_property);
                var vid = try valueToInternIdDecl(self.intern_pool, &self.number_pool, self.allocator, &self.list_pool, self.color_pool, &self.slash_list_preserve, val, is_custom_property);
                const val_calc_interp_marked = shouldMarkCalcInterpString(self.intern_pool, val);
                if (!is_custom_property and val_calc_interp_marked) {
                    const before_calc = calc_utils.stripCalcArgMarker(self.intern_pool.get(vid));
                    if (css_utils.containsCalcFunction(before_calc)) {
                        const normalized = try calc_utils.normalizeCalcInDeclValueForMarkedInterpolation(self.allocator, before_calc);
                        if (normalized.ptr != before_calc.ptr) {
                            defer self.allocator.free(normalized);
                            vid = try self.intern_pool.intern(normalized);
                        }
                    }
                    vid = try internWithLeadingMarker(self.intern_pool, self.allocator, calc_interp_marker, vid);
                }
                vid = try normalizeUnicodeRangeDeclValue(self, vid, is_custom_property);
                if (!is_custom_property and self.intern_pool.get(vid).len == 0) return .continue_exec;
                try self.rule_ir.appendDecl(self.allocator, @intFromEnum(prop_id), @intFromEnum(vid), self.currentSourceSpan());
            },
            .emit_decl => {
                const prop: u32 = inst.arg_b;
                const emit_decl_flags = inst.arg_a;
                const preserve_slash = (emit_decl_flags & opcode_mod.emit_decl_flag_preserve_slash) != 0;
                const val_raw = try self.maybeResolveParentSelectorValue(try self.pop());
                const val = try self.coerceSlashFreeValueForDecl(val_raw, preserve_slash);
                if (val.kind() == .nil) return .continue_exec;
                if (val.kind() == .string and !val.stringQuoted(self.string_flags_pool.items)) {
                    const raw = self.intern_pool.get(val.stringIntern());
                    if (raw.len == 0) return .continue_exec;
                }
                try self.reopenRecentNestedRuleForDeclaration();
                try self.ensureCurrentRuleOpenForDeclaration();
                if (self.open_block_depth == 0 or (self.load_css_strict_top_level and self.open_rule_depth == 0)) return error.SassError;
                if (self.mediaQueryActive() and self.open_rule_depth == 0 and !self.declarationAtRuleActive()) return error.SassError;
                const input_prop_name = self.intern_pool.get(@enumFromInt(prop));
                if (self.prop_namespace_stack.items.len > 0 and std.mem.startsWith(u8, input_prop_name, "--")) {
                    return error.SassError;
                }
                const prop_id = try self.applyPropertyNamespace(@enumFromInt(prop));
                const prop_name = self.intern_pool.get(prop_id);
                const is_custom_property = std.mem.startsWith(u8, prop_name, "--");
                if (try self.declarationValueNeedsIndentedCommaSyntaxError(val, emit_decl_flags)) return error.SassError;
                try ensureDeclarationValueIsCssValue(&self.list_pool, val, is_custom_property);
                if (is_custom_property and
                    (emit_decl_flags & opcode_mod.emit_decl_flag_value_source_multiline) != 0 and
                    val.kind() == .string and !val.stringQuoted(self.string_flags_pool.items))
                {
                    const raw_value = calc_utils.stripCalcArgMarker(self.intern_pool.get(val.stringIntern()));
                    if (std.mem.indexOfScalar(u8, raw_value, '\n') != null or std.mem.indexOfScalar(u8, raw_value, '\r') != null) {
                        const spaced_raw = if (raw_value.len != 0 and raw_value[0] != ' ' and raw_value[0] != '\t' and
                            (emit_decl_flags & opcode_mod.emit_decl_flag_custom_property_leading_space) != 0)
                            try std.fmt.allocPrint(self.allocator, " {s}", .{raw_value})
                        else
                            raw_value;
                        defer if (spaced_raw.ptr != raw_value.ptr) self.allocator.free(@constCast(spaced_raw));
                        const normalized = try normalizeRawCustomPropertyLiteral(self.allocator, spaced_raw);
                        defer self.allocator.free(normalized);
                        try self.rule_ir.appendDeclRaw(self.allocator, @intFromEnum(prop_id), normalized, self.currentSourceSpan());
                        return .continue_exec;
                    }
                }
                var vid = if (preserve_slash and val.kind() == .list and val.listSlash(self.list_meta_pool.items))
                    try valueToInternIdDeclSlashCompact(self.intern_pool, &self.number_pool, self.allocator, &self.list_pool, self.color_pool, &self.slash_list_preserve, val, is_custom_property)
                else
                    try valueToInternIdDecl(self.intern_pool, &self.number_pool, self.allocator, &self.list_pool, self.color_pool, &self.slash_list_preserve, val, is_custom_property);
                const val_calc_interp_marked = shouldMarkCalcInterpString(self.intern_pool, val);
                const is_plain_css_decl = (emit_decl_flags & opcode_mod.emit_decl_flag_plain_css_origin) != 0 or
                    self.currentSourceUsesPlainCss();
                if (!is_custom_property and is_plain_css_decl) {
                    const before_plain = self.intern_pool.get(vid);
                    const had_literal_marker = std.mem.startsWith(u8, before_plain, literal_decl_marker);
                    var working = if (had_literal_marker) before_plain[literal_decl_marker.len..] else before_plain;
                    var working_owned: ?[]u8 = null;
                    defer if (working_owned) |m| self.allocator.free(m);
                    if (std.mem.indexOfAny(u8, working, "'\"\\") != null) {
                        const normalized = try normalizePlainCssDeclQuotes(self.allocator, working);
                        if (!std.mem.eql(u8, normalized, working)) {
                            working_owned = normalized;
                            working = normalized;
                        } else {
                            self.allocator.free(normalized);
                        }
                    }
                    if (!had_literal_marker) {
                        const spaced = try normalizePlainCssDeclSpaces(self.allocator, working);
                        if (!std.mem.eql(u8, spaced, working)) {
                            if (working_owned) |m| self.allocator.free(m);
                            working_owned = spaced;
                            working = spaced;
                        } else {
                            self.allocator.free(spaced);
                        }
                    }
                    if (working.ptr != (if (had_literal_marker) before_plain[literal_decl_marker.len..].ptr else before_plain.ptr) or
                        working.len != (if (had_literal_marker) before_plain.len - literal_decl_marker.len else before_plain.len))
                    {
                        if (had_literal_marker) {
                            const marked = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ literal_decl_marker, working });
                            defer self.allocator.free(marked);
                            vid = try self.intern_pool.intern(marked);
                        } else {
                            vid = try self.intern_pool.intern(working);
                        }
                    }
                }
                const vid_text_for_literal = self.intern_pool.get(vid);
                const vid_preserve_literal_decl = std.mem.indexOf(u8, vid_text_for_literal, literal_decl_marker) != null;
                const val_preserve_literal_calc = !is_plain_css_decl and ((vid_preserve_literal_decl and css_utils.containsCalcFunction(vid_text_for_literal)) or (val.kind() == .string and
                    !val.stringQuoted(self.string_flags_pool.items) and
                    val.stringPreserveLiteralText(self.string_flags_pool.items) and
                    css_utils.containsCalcFunction(self.intern_pool.get(val.stringIntern()))));
                if (!is_custom_property and val_preserve_literal_calc) {
                    const raw_literal = self.intern_pool.get(vid);
                    const unmarked_literal = try stripLiteralDeclMarkersVm(self.allocator, raw_literal);
                    defer if (unmarked_literal.ptr != raw_literal.ptr) self.allocator.free(unmarked_literal);
                    try self.rule_ir.appendDeclRaw(self.allocator, @intFromEnum(prop_id), unmarked_literal, self.currentSourceSpan());
                    return .continue_exec;
                }
                if (!is_custom_property) {
                    const vid_raw = self.intern_pool.get(vid);
                    if (std.mem.indexOf(u8, vid_raw, calc_interp_preserve_start) != null and
                        css_utils.containsCalcFunction(vid_raw))
                    {
                        try self.rule_ir.appendDeclRaw(self.allocator, @intFromEnum(prop_id), vid_raw, self.currentSourceSpan());
                        return .continue_exec;
                    }
                }
                if (!is_custom_property and val_calc_interp_marked) {
                    const marked_value = self.intern_pool.get(val.stringIntern());
                    const marked_raw = calc_utils.stripCalcArgMarker(marked_value);
                    if (std.mem.indexOf(u8, marked_raw, calc_interp_preserve_start) != null and
                        css_utils.containsCalcFunction(marked_raw))
                    {
                        try self.rule_ir.appendDeclRaw(self.allocator, @intFromEnum(prop_id), marked_value, self.currentSourceSpan());
                        return .continue_exec;
                    }
                }
                if (!is_custom_property and
                    !val_preserve_literal_calc and
                    (val_calc_interp_marked or
                        (emit_decl_flags & opcode_mod.emit_decl_flag_strip_source_comments) == 0))
                {
                    const before_calc = calc_utils.stripCalcArgMarker(self.intern_pool.get(vid));
                    if (css_utils.containsCalcFunction(before_calc)) {
                        const normalized = if (val_calc_interp_marked)
                            try calc_utils.normalizeCalcInDeclValueForMarkedInterpolation(self.allocator, before_calc)
                        else
                            try calc_utils.normalizeCalcInDeclValue(self.allocator, before_calc);
                        if (normalized.ptr != before_calc.ptr) {
                            defer self.allocator.free(normalized);
                            vid = try self.intern_pool.intern(normalized);
                        }
                    }
                }
                vid = try normalizeUnicodeRangeDeclValue(self, vid, is_custom_property);
                // emit_decl_flag_strip_source_comments is set only for values
                // without interpolation. Strip source comments from plain CSS
                // literal values; preserve text produced by interpolation. Custom
                // properties preserve their bytes.
                if (!is_custom_property and (emit_decl_flags & opcode_mod.emit_decl_flag_strip_source_comments) != 0) {
                    const before = self.intern_pool.get(vid);
                    if (std.mem.indexOf(u8, before, "/*") != null) {
                        const stripped = try css_utils.stripPlainCssDeclComments(self.allocator, before);
                        if (stripped.ptr != before.ptr) {
                            const normalized = try normalizePlainCssDeclSpaces(self.allocator, stripped);
                            defer self.allocator.free(normalized);
                            vid = try self.intern_pool.intern(normalized);
                            self.allocator.free(@constCast(stripped));
                        }
                    }
                }
                // official Sass CLI true semantic: does not go through calc() builtin at decl value stage (= function return value or
                // Preserve as plain CSS unparsed if calc text assembled via unquote(" + ").
                // flatten the internal calc literal at text-level via a helper's add() helper
                // The inner calc of `calc(... + calc(... * var(...)))` is broken. via calc() builtin
                // The value has already been simplified in buildCalcCallableResult, so here parens / spacing
                // Perform normalization only (NoFlatten version).
                if (!is_custom_property and (emit_decl_flags & opcode_mod.emit_decl_flag_strip_source_comments) != 0) {
                    const before_calc = self.intern_pool.get(vid);
                    if (!val_preserve_literal_calc and css_utils.containsCalcFunction(before_calc)) {
                        // The plain CSS file (`.css`) is flattened because it is simplified by official Sass CLI.
                        // From SCSS source (via variable / function return value / interp) is plain CSS
                        // Preserve as unparsed (string-based add() helper compatible).
                        const flattened = if (val_calc_interp_marked)
                            try calc_utils.normalizeCalcInDeclValueForMarkedInterpolation(self.allocator, before_calc)
                        else if (is_plain_css_decl)
                            try calc_utils.normalizeCalcInPlainCssDeclValue(self.allocator, before_calc)
                        else
                            try calc_utils.normalizeCalcInDeclValueNoFlatten(self.allocator, before_calc);
                        if (flattened.ptr != before_calc.ptr) {
                            vid = try self.intern_pool.intern(flattened);
                            self.allocator.free(@constCast(flattened));
                        }
                    }
                }
                if (!is_custom_property and val_calc_interp_marked) {
                    vid = try internWithLeadingMarker(self.intern_pool, self.allocator, calc_interp_marker, vid);
                }
                if (!is_custom_property and (emit_decl_flags & opcode_mod.emit_decl_flag_value_has_interp) != 0) {
                    vid = try internWithLeadingMarker(self.intern_pool, self.allocator, interp_decl_marker, vid);
                }
                if (!is_custom_property and self.intern_pool.get(vid).len == 0) return .continue_exec;
                try self.rule_ir.appendDecl(self.allocator, @intFromEnum(prop_id), @intFromEnum(vid), self.currentSourceSpan());
            },
            .emit_decl_raw, .emit_raw_decl => {
                const prop: u32 = inst.arg_b;
                const val = try self.maybeResolveParentSelectorValue(try self.pop());
                try self.reopenRecentNestedRuleForDeclaration();
                try self.ensureCurrentRuleOpenForDeclaration();
                if (self.open_block_depth == 0 or (self.load_css_strict_top_level and self.open_rule_depth == 0)) return error.SassError;
                if (self.mediaQueryActive() and self.open_rule_depth == 0 and !self.declarationAtRuleActive()) return error.SassError;
                const input_prop_name = self.intern_pool.get(@enumFromInt(prop));
                if (self.prop_namespace_stack.items.len > 0 and std.mem.startsWith(u8, input_prop_name, "--")) {
                    return error.SassError;
                }
                const prop_id = try self.applyPropertyNamespace(@enumFromInt(prop));
                const prop_name = self.intern_pool.get(prop_id);
                const is_custom_property = std.mem.startsWith(u8, prop_name, "--");

                const raw_id = if (val.kind() == .string) blk: {
                    if (val.stringQuoted(self.string_flags_pool.items)) {
                        break :blk try valueToInternIdDecl(
                            self.intern_pool,
                            &self.number_pool,
                            self.allocator,
                            &self.list_pool,
                            self.color_pool,
                            &self.slash_list_preserve,
                            val,
                            is_custom_property,
                        );
                    }
                    const raw = calc_utils.stripCalcArgMarker(self.intern_pool.get(val.stringIntern()));
                    if (std.mem.indexOf(u8, raw, "#{") != null) {
                        // Escaped interpolation literals (`\\#{...}`) keep raw text.
                        break :blk val.stringIntern();
                    }
                    const needs_interpolated_decl_normalization = !is_custom_property and
                        (css_utils.containsCalcFunction(raw) or
                            std.mem.indexOfScalar(u8, raw, '\n') != null);
                    if (needs_interpolated_decl_normalization) {
                        break :blk try valueToInternIdInterpolatedDeclRaw(
                            self.intern_pool,
                            &self.number_pool,
                            self.allocator,
                            &self.list_pool,
                            self.color_pool,
                            &self.slash_list_preserve,
                            val,
                            is_custom_property,
                        );
                    }
                    // Custom property values are preserved byte-for-byte by
                    // official Sass CLI (no quote / space / slash / hex normalization).
                    // The resolver also skips its plain-CSS literal text rewrites
                    // for custom properties; mirror that here.
                    if (is_custom_property) {
                        if (customCalcShouldSimplifyToNumber(raw)) {
                            if (try parseCalcNumberish(self.intern_pool, &self.number_pool, self.allocator, raw)) |parsed| {
                                break :blk try valueToInternIdDecl(
                                    self.intern_pool,
                                    &self.number_pool,
                                    self.allocator,
                                    &self.list_pool,
                                    self.color_pool,
                                    &self.slash_list_preserve,
                                    parsed,
                                    true,
                                );
                            }
                        }
                        const raw_normalized = try normalizeRawCustomPropertyLiteral(self.allocator, raw);
                        defer self.allocator.free(raw_normalized);
                        const slash_normalized = if (css_utils.containsCalcFunction(raw_normalized) and std.mem.indexOf(u8, raw_normalized, "url(") == null)
                            try normalizeCustomCalcSlashWhitespace(self.allocator, raw_normalized)
                        else
                            try self.allocator.dupe(u8, raw_normalized);
                        defer self.allocator.free(slash_normalized);
                        break :blk try self.intern_pool.intern(slash_normalized);
                    }
                    // Plain CSS source path stores raw decl bytes (with the
                    // original ' / " quote chars) on an unquoted literal_string.
                    // official Sass CLI parses each quoted segment and re-serializes via
                    // preferredQuoteChar (double-preferred unless the body
                    // contains a "). Mirror that here so plain-CSS input matches
                    // the same quote policy as SCSS-derived quoted Values.
                    // also after comma space / !important before space / modern
                    // Also normalize color syntax ' / '.
                    var working: []const u8 = raw;
                    var working_owned: ?[]u8 = null;
                    defer if (working_owned) |m| self.allocator.free(m);
                    const has_interp = inst.opcode() == .emit_raw_decl and
                        (inst.arg_a & opcode_mod.emit_raw_decl_flag_strip_source_comments) == 0;
                    if (std.mem.indexOfScalar(u8, working, '\'') != null) {
                        const normalized = if (has_interp)
                            try normalizeUrlQuotesInInterp(self.allocator, working)
                        else
                            try normalizePlainCssDeclQuotes(self.allocator, working);
                        if (!std.mem.eql(u8, normalized, working)) {
                            working_owned = normalized;
                            working = normalized;
                        } else {
                            self.allocator.free(normalized);
                        }
                    }
                    if (!has_interp) {
                        const normalized = try normalizePlainCssDeclSpaces(self.allocator, working);
                        if (!std.mem.eql(u8, normalized, working)) {
                            if (working_owned) |m| self.allocator.free(m);
                            working_owned = normalized;
                            working = normalized;
                        } else {
                            self.allocator.free(normalized);
                        }
                    }
                    if (working.ptr != raw.ptr) {
                        break :blk try self.intern_pool.intern(working);
                    }
                    break :blk val.stringIntern();
                } else try valueToInternIdInterpolatedDeclRaw(
                    self.intern_pool,
                    &self.number_pool,
                    self.allocator,
                    &self.list_pool,
                    self.color_pool,
                    &self.slash_list_preserve,
                    val,
                    is_custom_property,
                );
                var out_id: InternId = raw_id;
                if (is_custom_property) {
                    const raw_before_ws = self.intern_pool.get(out_id);
                    if (raw_before_ws.len != 0 and raw_before_ws[0] != ' ' and raw_before_ws[0] != '\t') {
                        if ((inst.arg_a & opcode_mod.emit_raw_decl_flag_custom_property_leading_space) != 0) {
                            const restored = try std.fmt.allocPrint(self.allocator, " {s}", .{raw_before_ws});
                            defer self.allocator.free(restored);
                            out_id = try self.intern_pool.intern(restored);
                        }
                    }
                }
                out_id = try normalizeUnicodeRangeDeclValue(self, out_id, is_custom_property);
                // emit_raw_decl_flag_strip_source_comments is set only for pure
                // literal source values. Interpolation and custom properties
                // preserve authored bytes. Older raw-decl opcodes keep flag 0.
                if (!is_custom_property and inst.opcode() == .emit_raw_decl and
                    (inst.arg_a & opcode_mod.emit_raw_decl_flag_strip_source_comments) != 0)
                {
                    const before = self.intern_pool.get(out_id);
                    const stripped = try css_utils.stripPlainCssDeclComments(self.allocator, before);
                    if (stripped.ptr != before.ptr) {
                        const normalized = try normalizePlainCssDeclSpaces(self.allocator, stripped);
                        defer self.allocator.free(normalized);
                        out_id = try self.intern_pool.intern(normalized);
                        self.allocator.free(@constCast(stripped));
                    }
                }
                // emit_raw_decl path: plain CSS literal derived (no interp source, e.g. `.css` file
                // direct writing inside calc()). The official Sass CLI simplifies this.
                // On the other hand, if emit_decl path (= runtime computed value) is via buildCalcCallableResult
                // It has already been simplified, so it should be preserved if it is via the function return value (string-based add() helper)
                // Do not flatten on emit_decl handler side. Distinguish the two routes by opcode type.
                if (!is_custom_property and inst.opcode() == .emit_raw_decl and
                    (inst.arg_a & opcode_mod.emit_raw_decl_flag_strip_source_comments) != 0)
                {
                    const before_calc = self.intern_pool.get(out_id);
                    if (css_utils.containsCalcFunction(before_calc)) {
                        const flattened = try calc_utils.normalizeCalcInPlainCssDeclValue(self.allocator, before_calc);
                        if (flattened.ptr != before_calc.ptr) {
                            out_id = try self.intern_pool.intern(flattened);
                            self.allocator.free(@constCast(flattened));
                        }
                    }
                }
                if (!is_custom_property and inst.opcode() == .emit_raw_decl and
                    (inst.arg_a & opcode_mod.emit_raw_decl_flag_value_has_interp) != 0)
                {
                    out_id = try internWithLeadingMarker(self.intern_pool, self.allocator, interp_decl_marker, out_id);
                }
                if (!is_custom_property and self.intern_pool.get(out_id).len == 0) return .continue_exec;
                try self.rule_ir.appendDeclRaw(self.allocator, @intFromEnum(prop_id), self.intern_pool.get(out_id), self.currentSourceSpan());
            },
            .emit_at_rule_simple => {
                try self.closeOpenMaybeCurrentRuleBeforeBoundary();
                var name_id: InternId = @enumFromInt(inst.arg_b);
                const prelude_v = try self.pop();
                const prelude_id = if (self.intern_pool.get(name_id).len == 0) blk: {
                    const split = try self.splitDynamicAtRuleText(prelude_v);
                    name_id = split.name_id;
                    break :blk split.prelude_id;
                } else try self.valueToPreparedPreludeIntern(
                    name_id,
                    prelude_v,
                    @truncate((inst.arg_a >> 8) & 0x7f),
                );
                try self.rule_ir.appendAtRuleSimpleMaybeHoisted(self.allocator, self.intern_pool, name_id, prelude_id, self.currentSourceSpan());
            },
            .emit_at_rule_begin => {
                try self.closeOpenMaybeCurrentRuleBeforeBoundary();
                var name_id: InternId = @enumFromInt(inst.arg_b);
                const prelude_v = try self.pop();
                const prelude_id = if (self.intern_pool.get(name_id).len == 0) blk: {
                    const split = try self.splitDynamicAtRuleText(prelude_v);
                    name_id = split.name_id;
                    break :blk split.prelude_id;
                } else try self.valueToPreparedPreludeIntern(
                    name_id,
                    prelude_v,
                    @truncate((inst.arg_a >> 8) & 0x7f),
                );
                const raw_name = self.intern_pool.get(name_id);
                const is_media = std.mem.eql(u8, raw_name, "media");
                const is_supports = std.mem.eql(u8, raw_name, "supports");
                const is_layer = std.mem.eql(u8, raw_name, "layer");
                const is_container = std.mem.eql(u8, raw_name, "container");
                const is_keyframes = rule_ir_mod.isKeyframesAtRuleName(raw_name);
                // @supports/@media/@layer inside a keyframe step remain nested
                // and wrap body declarations with the outer non-keyframe selector.
                var kf_frame: KeyframeNestedAtRuleFrame = .{ .is_keyframes = is_keyframes };
                if ((is_media or is_supports or is_layer) and
                    self.in_keyframes_block_depth > 0 and
                    self.selector_stack.items.len > 0 and
                    self.in_keyframe_nested_at_rule_depth == 0)
                {
                    // If a trailing rule_end was emitted just before this
                    // at-rule, undo it so the at-rule remains nested inside the
                    // keyframe frame.
                    if (self.open_rule_depth < self.selector_stack.items.len and
                        self.rule_ir.nodes.items.len > 0 and
                        self.rule_ir.nodes.items[self.rule_ir.nodes.items.len - 1].kind == .rule_end)
                    {
                        _ = self.rule_ir.nodes.pop();
                        _ = self.rule_ir.node_source_files.pop();
                        self.rule_ir.last_visible_emit_node_count = self.rule_ir.nodes.items.len;
                        self.open_rule_depth += 1;
                        try self.open_rule_selector_depth_stack.append(self.allocator, @intCast(self.selector_stack.items.len));
                        self.open_block_depth += 1;
                        kf_frame.undid_close = true;
                    }
                    // Outer selectors saved in push_at_root_scope of most recent @keyframes
                    // Push the end to selector_stack (if emit_rule_begin_current_maybe is outer
                    // Allow the rule to be opened).
                    if (self.at_root_saved_selector_frames.items.len > 0) {
                        const saved = &self.at_root_saved_selector_frames.items[self.at_root_saved_selector_frames.items.len - 1];
                        if (saved.selectors.len > 0) {
                            const outer_sel = saved.selectors[saved.selectors.len - 1];
                            try self.selector_stack.append(self.allocator, outer_sel);
                            const outer_owner = if (saved.owner_modules.len > 0)
                                saved.owner_modules[saved.owner_modules.len - 1]
                            else
                                self.currentEmitModuleTag();
                            try self.selector_owner_stack.append(self.allocator, outer_owner);
                            try self.scope_push_ir_lens.append(self.allocator, self.rule_ir.nodes.items.len);
                            kf_frame.pushed_outer = true;
                        }
                    }
                    self.in_keyframe_nested_at_rule_depth += 1;
                    kf_frame.incremented_nested_depth = true;
                }
                const keep_empty_block = (inst.arg_a & 0x8000) != 0;
                const nest_depth: u8 = @truncate(inst.arg_a & 0x007f);
                try self.rule_ir.appendAtRuleBegin(self.allocator, name_id, prelude_id, nest_depth, keep_empty_block, self.currentSourceSpan());
                const at_rule_node_idx = self.rule_ir.nodes.items.len - 1;
                if ((inst.arg_a & opcode_mod.at_rule_flag_plain_css_preserve) != 0) {
                    self.rule_ir.setPlainCssPreserveNestedAtRuleAt(at_rule_node_idx, true);
                }
                self.applyPendingSuppressNextRuleBeginBlank(at_rule_node_idx);
                // Parent style_rule / at-rule context (selector_stack is not empty or
                // an at_rule_begin issued from an at-rule block that is already open).
                // Targeted by hoist (= kept blank after block ends) in normalizeNestedMediaRuleIR.
                // Add flag to begin node to achieve blank retention after hoist from writer.
                const is_bubbling_terminal = rule_ir_mod.isBubblingTerminalAtRuleName(raw_name);
                if ((is_media or is_supports or is_bubbling_terminal or is_container or is_layer) and self.selector_stack.items.len > 0) {
                    // @media emitted from the context of parent style_rule is
                    // hoisted outside parent with normalizeNestedMediaRuleIR. The
                    // official Sass CLI keeps blank after @media block exits after hoist.
                    // Merge if parent is only at-rule (e.g. @media outer { @media inner {}}).
                    // No extra blank is needed after this hoist.
                    //
                    // "Terminal at-rule" such as @keyframes / @font-face / @property also parent style_rule
                    // bubble out in the same way. Do not insert blank before hoist;
                    // keep the source-side blank after hoist for the next sibling rule.
                    self.rule_ir.setPreserveAtRuleBlockFollowingBlankAt(at_rule_node_idx, true);
                    // Official Sass CLI does not output blank between parent style_rule (writer fallback
                    // Suppress blank). rebuildHoistedRuleMediaItem in normalizeNestedMediaRuleIR
                    // This is also set in path.
                    self.rule_ir.setSuppressLeadingBlankAt(at_rule_node_idx, true);
                }
                // At-rule begin emitted within @at-root scope is also treated
                // as hoisted, like rule_begin. After lifting out of the parent
                // rule, force a blank before the next non-hoisted rule/at-rule
                // and suppress the leading blank on the hoisted node itself.
                if (self.at_root_saved_selector_frames.items.len > 0) {
                    self.rule_ir.setOriginAtRootHoistedAt(at_rule_node_idx, true);
                    self.rule_ir.setSuppressLeadingBlankAt(at_rule_node_idx, true);
                }
                try self.open_at_rule_bubble_stack.append(self.allocator, .{
                    .node_idx = at_rule_node_idx,
                    .type_mask = atRuleBubbleTypeMask(raw_name),
                });
                try self.keyframe_nested_at_rule_stack.append(self.allocator, kf_frame);
                if (is_keyframes) self.in_keyframes_block_depth += 1;
                const has_selector_context = atRootPreludeActsLikeSelector(self.intern_pool, name_id, prelude_id);
                try self.at_root_selector_context_stack.append(self.allocator, has_selector_context);
                try self.at_rule_media_stack.append(self.allocator, is_media);
                try self.at_rule_decl_container_stack.append(self.allocator, atRuleAllowsDirectDeclarations(raw_name));
                if (has_selector_context) self.at_root_selector_context_depth += 1;
                if (is_media) self.media_query_depth += 1;
                self.open_block_depth += 1;
            },
            .emit_at_rule_end => {
                try self.closeOpenMaybeCurrentRuleBeforeBoundary();
                // Pop any pushed outer selector and restore a close that was undone.
                const kf_frame: KeyframeNestedAtRuleFrame = if (self.keyframe_nested_at_rule_stack.items.len > 0)
                    self.keyframe_nested_at_rule_stack.pop().?
                else
                    .{};
                if (kf_frame.pushed_outer) {
                    _ = self.selector_stack.pop();
                    _ = self.selector_owner_stack.pop();
                    if (self.scope_push_ir_lens.items.len > 0) _ = self.scope_push_ir_lens.pop();
                }
                if (kf_frame.incremented_nested_depth and self.in_keyframe_nested_at_rule_depth > 0) {
                    self.in_keyframe_nested_at_rule_depth -= 1;
                }
                if (kf_frame.is_keyframes and self.in_keyframes_block_depth > 0) {
                    self.in_keyframes_block_depth -= 1;
                }
                if (self.open_block_depth > 0) self.open_block_depth -= 1;
                if (self.at_root_selector_context_stack.items.len > 0) {
                    const had_selector_context = self.at_root_selector_context_stack.pop().?;
                    if (had_selector_context and self.at_root_selector_context_depth > 0) {
                        self.at_root_selector_context_depth -= 1;
                    }
                }
                if (self.at_rule_media_stack.items.len > 0) {
                    const was_media = self.at_rule_media_stack.pop().?;
                    if (was_media and self.media_query_depth > 0) {
                        self.media_query_depth -= 1;
                    }
                }
                if (self.at_rule_decl_container_stack.items.len > 0) {
                    _ = self.at_rule_decl_container_stack.pop();
                }
                if (self.open_at_rule_bubble_stack.items.len > 0) {
                    _ = self.open_at_rule_bubble_stack.pop();
                }
                try self.rule_ir.appendAtRuleEnd(self.allocator, self.currentSourceSpan());
                // Restore undo keyframe frame close (rule_end popped with emit_at_rule_begin)
                // reissue). Closing keyframe frame rule gracefully after closing @supports / @media .
                if (kf_frame.undid_close) {
                    try self.rule_ir.appendRuleEnd(self.allocator, self.currentSourceSpan());
                    if (self.open_rule_depth > 0) self.open_rule_depth -= 1;
                    if (self.open_rule_selector_depth_stack.items.len > 0) {
                        _ = self.open_rule_selector_depth_stack.pop();
                    }
                    if (self.open_block_depth > 0) self.open_block_depth -= 1;
                }
                try self.maybeFlushStreamChunks();
            },
            .emit_comment => {
                const text_id: InternId = @enumFromInt(inst.arg_b);
                // arg_a = source column of `/*` calculated by resolver (ast.source basis) + bit 15
                // leading_same_line flag.
                // Even if the module_id of chunk and the actual file differ with @import inline,
                // col is always valid ast.source criteria (see rule_ir emitCommentNode).
                const source_col: u32 = inst.arg_a & 0x7FFF;
                const leading_same_line: bool = (inst.arg_a & 0x8000) != 0;
                try self.emitCommentWithRuleWrap(text_id, source_col, leading_same_line);
            },
            .emit_comment_dynamic => {
                const val = try self.maybeResolveParentSelectorValue(try self.pop());
                // Dynamic loud-comment text is whitespace-sensitive, unlike a
                // declaration value. Preserve raw string text so line breaks in
                // multi-line loud comments are not normalized away.
                const text_id = if (val.isString())
                    val.stringIntern()
                else
                    try valueToInternIdRaw(
                        self.intern_pool,
                        &self.number_pool,
                        self.allocator,
                        &self.list_pool,
                        self.color_pool,
                        &self.slash_list_preserve,
                        val,
                    );
                const source_col: u32 = inst.arg_a & 0x7FFF;
                const leading_same_line: bool = (inst.arg_a & 0x8000) != 0;
                try self.emitCommentWithRuleWrap(text_id, source_col, leading_same_line);
            },
            .emit_error => {
                const val = try self.pop();
                const msg = try self.valueToDiagnosticMessage(val, true);
                if (!self.suppress_diagnostics) vmStderrPrint("Error: {s}\n", .{msg});
                return error.SassError;
            },
            .emit_debug => {
                if (self.deprecation_opts.quiet) return .continue_exec;
                if (self.suppress_diagnostics) return .continue_exec;
                const val = try self.pop();
                const msg = try self.valueToDiagnosticMessage(val, false);
                const file_id: usize = @intCast(self.current_source_span.file_id);
                if (file_id < self.program.modules.len) {
                    const module = self.program.modules[file_id];
                    const pos = sourceOffsetToLineColVm(module.line_starts, module.source_len, self.current_source_span.start);
                    vmStderrPrint("{s}:{d} DEBUG: {s}\n", .{ module.module_path, pos.line + 1, msg });
                } else {
                    vmStderrPrint("DEBUG: {s}\n", .{msg});
                }
            },
            .emit_warn => {
                if (self.deprecation_opts.quiet) return .continue_exec;
                if (self.suppress_diagnostics) return .continue_exec;
                const val = try self.pop();
                const msg = try self.valueToDiagnosticMessage(val, false);
                const file_id: usize = @intCast(self.current_source_span.file_id);
                if (file_id < self.program.modules.len) {
                    const module = self.program.modules[file_id];
                    const pos = sourceOffsetToLineColVm(module.line_starts, module.source_len, self.current_source_span.start);
                    vmStderrPrint("WARNING: {s}\n    {s} {d}:{d}  root stylesheet\n", .{ msg, module.module_path, pos.line + 1, pos.col + 1 });
                } else {
                    vmStderrPrint("WARNING: {s}\n", .{msg});
                }
            },
            .emit_stmt_gap => {
                // Load marker only in top-level context. loop in rule body (`.boxed { @include box }`
                // ->  @for etc. in box mixin) cannot be determined by mixin chunk compile-time (caller context
                //), so it is determined by runtime. parent is style_rule (selector_stack > 0)
                // If and inside at_rule block (open_block_depth > 0), do not stack stmt_gap.
                // The latter is between @for/@each/@while expanded rules in @layer / @media / @supports
                // To avoid inserting unnecessary blanks (actual behavior of official Sass CLI, confirmed with sass CLI 1.99.0).
                if (self.selector_stack.items.len == 0 and self.open_block_depth == 0) {
                    // Empty scope was popped immediately after the previous visible emit (= trailing
                    // empty rule), consume this stmt_gap without accumulating it. official Sass CLI is
                    // Suppress blank after `&.empty{}` in `.parent { .child {} &.empty {} } .next{}`.
                    // However, if visible emit is running after setting pending, it is no longer trailing, so invalidate.
                    if (self.pending_empty_scope_after_visible) {
                        if (self.rule_ir.last_visible_emit_node_count > self.pending_set_at_visible_count) {
                            self.pending_empty_scope_after_visible = false;
                        } else {
                            // suppress: do not append stmt_gap node. fallback blank too
                            // The mechanism for setting the suppress flag in the next rule_begin to suppress is
                            // Writer side (writer is last_visible_emit_node_count == nodes.len
                            //In this case, it is determined that there is no previous stmt_gap) -- Here, from IR
                            // It is enough to delete stmt_gap. However, top-level fallback blank
                            // To suppress (`indent_level == 0 and nest_depth == 0`),
                            // A separate route is required to set the suppress flag to "next rule_begin".
                            // Supported in the later stage (writer side prev_visible_followed_by_empty_skip state).
                            self.pending_empty_scope_after_visible = false;
                            self.suppress_next_rule_begin_blank = true;
                            return .continue_exec;
                        }
                    }
                    // Consecutive top-level statement gaps can appear after an
                    // inline import. If the first gap only sets
                    // suppress_next_rule_begin_blank, the second must be skipped
                    // too until a visible emit occurs.
                    // Suppress this stmt_gap itself.
                    if (self.suppress_next_rule_begin_blank and
                        self.rule_ir.last_visible_emit_node_count == self.pending_set_at_visible_count)
                    {
                        return .continue_exec;
                    }
                    try self.rule_ir.appendStmtGap(self.allocator, self.currentSourceSpan());
                }
            },
            .emit_fragment => {
                const prop: u32 = inst.arg_b;
                const val = try self.maybeResolveParentSelectorValue(try self.pop());
                const raw_id = try valueToInternIdInterpolated(
                    self.intern_pool,
                    &self.number_pool,
                    self.allocator,
                    &self.list_pool,
                    self.color_pool,
                    &self.slash_list_preserve,
                    val,
                );
                if (self.open_block_depth == 0 or (self.load_css_strict_top_level and self.open_rule_depth == 0)) return error.SassError;
                if (self.mediaQueryActive() and self.open_rule_depth == 0 and !self.declarationAtRuleActive()) return error.SassError;
                const prop_id = try self.applyPropertyNamespace(@enumFromInt(prop));
                const raw_fragment = self.intern_pool.get(raw_id);
                const unmarked_fragment = try calc_utils.stripCalcInterpolationPreserveMarkers(self.allocator, raw_fragment);
                defer if (unmarked_fragment.ptr != raw_fragment.ptr) self.allocator.free(unmarked_fragment);
                try self.rule_ir.appendDeclRaw(
                    self.allocator,
                    @intFromEnum(prop_id),
                    unmarked_fragment,
                    self.currentSourceSpan(),
                );
            },
            .emit_rule_begin_dynamic => {
                try self.closeOpenMaybeCurrentRuleBeforeBoundary();
                try self.openRuleScope(inst, true, true);
            },
            .push_selector_scope_dynamic => {
                try self.closeOpenMaybeCurrentRuleBeforeBoundary();
                try self.openRuleScope(inst, false, true);
            },
            .push_at_root_scope => try self.pushAtRootScope(inst.arg_a == 0),
            .pop_at_root_scope => try self.popAtRootScope(),
            .push_at_root_bubble => try self.pushAtRootBubble(@truncate(inst.arg_a)),
            .pop_at_root_bubble => self.popAtRootBubble(),
            .emit_decl_dynamic => {
                const val = try self.maybeResolveParentSelectorValue(try self.pop());
                const propv = try self.maybeResolveParentSelectorValue(try self.pop());
                if (val.kind() == .nil) return .continue_exec;
                const raw_prop_id = try valueToInternIdInterpolated(
                    self.intern_pool,
                    &self.number_pool,
                    self.allocator,
                    &self.list_pool,
                    self.color_pool,
                    &self.slash_list_preserve,
                    propv,
                );
                const raw_prop = std.mem.trim(u8, self.intern_pool.get(raw_prop_id), " \t\r\n");
                if (raw_prop.len == 0) return error.SassError;
                try self.reopenRecentNestedRuleForDeclaration();
                try self.ensureCurrentRuleOpenForDeclaration();
                const prop_id = try self.applyPropertyNamespace(try self.intern_pool.intern(raw_prop));
                const prop_u: u32 = @intFromEnum(prop_id);
                const prop_name = self.intern_pool.get(prop_id);
                const is_custom_property = std.mem.startsWith(u8, prop_name, "--");
                if (self.open_block_depth == 0) return error.SassError;
                if (try self.declarationValueNeedsIndentedCommaSyntaxError(val, inst.arg_a)) return error.SassError;
                try ensureDeclarationValueIsCssValue(&self.list_pool, val, is_custom_property);
                var dynamic_custom_raw_value_id: ?InternId = null;
                if (is_custom_property) {
                    const raw_vid = if (val.kind() == .string and !val.stringQuoted(self.string_flags_pool.items))
                        val.stringIntern()
                    else
                        try valueToInternIdInterpolatedDeclRaw(
                            self.intern_pool,
                            &self.number_pool,
                            self.allocator,
                            &self.list_pool,
                            self.color_pool,
                            &self.slash_list_preserve,
                            val,
                            true,
                        );
                    dynamic_custom_raw_value_id = raw_vid;
                    const raw_value = calc_utils.stripCalcArgMarker(self.intern_pool.get(raw_vid));
                    const raw_trimmed = std.mem.trim(u8, raw_value, " \t\r\n");
                    const normalize_dynamic_calc_with_css_vars =
                        std.ascii.startsWithIgnoreCase(raw_trimmed, "calc(") and
                        std.mem.indexOf(u8, raw_trimmed, "var(") != null;
                    if (!normalize_dynamic_calc_with_css_vars and
                        (inst.arg_a & opcode_mod.emit_decl_flag_value_source_multiline) != 0 and
                        (std.mem.indexOfScalar(u8, raw_value, '\n') != null or std.mem.indexOfScalar(u8, raw_value, '\r') != null))
                    {
                        const spaced_raw = if (raw_value.len != 0 and raw_value[0] != ' ' and raw_value[0] != '\t' and
                            ((inst.arg_a & opcode_mod.emit_decl_flag_custom_property_leading_space) != 0 or
                                (inst.arg_a & opcode_mod.emit_decl_flag_value_source_multiline) != 0 or
                                dynamicCustomValueNeedsImplicitLeadingSpace(raw_value)))
                            try std.fmt.allocPrint(self.allocator, " {s}", .{raw_value})
                        else
                            raw_value;
                        defer if (spaced_raw.ptr != raw_value.ptr) self.allocator.free(@constCast(spaced_raw));
                        const normalized = try normalizeRawCustomPropertyLiteral(self.allocator, spaced_raw);
                        defer self.allocator.free(normalized);
                        const unmarked = try calc_utils.stripCalcInterpolationPreserveMarkers(self.allocator, normalized);
                        defer if (unmarked.ptr != normalized.ptr) self.allocator.free(unmarked);
                        try self.rule_ir.appendDeclRaw(self.allocator, prop_u, unmarked, self.currentSourceSpan());
                        return .continue_exec;
                    }
                }
                var vid = try valueToInternIdDecl(self.intern_pool, &self.number_pool, self.allocator, &self.list_pool, self.color_pool, &self.slash_list_preserve, val, is_custom_property);
                const val_calc_interp_marked = shouldMarkCalcInterpString(self.intern_pool, val);
                if (!is_custom_property and val_calc_interp_marked) {
                    const marked_value = self.intern_pool.get(val.stringIntern());
                    const marked_raw = calc_utils.stripCalcArgMarker(marked_value);
                    if (std.mem.indexOf(u8, marked_raw, calc_interp_preserve_start) != null and
                        css_utils.containsCalcFunction(marked_raw))
                    {
                        try self.rule_ir.appendDeclRaw(self.allocator, prop_u, marked_value, self.currentSourceSpan());
                        return .continue_exec;
                    }
                }
                if (!is_custom_property and val_calc_interp_marked) {
                    const before_calc = calc_utils.stripCalcArgMarker(self.intern_pool.get(vid));
                    if (css_utils.containsCalcFunction(before_calc)) {
                        const normalized = try calc_utils.normalizeCalcInDeclValueForMarkedInterpolation(self.allocator, before_calc);
                        if (normalized.ptr != before_calc.ptr) {
                            defer self.allocator.free(normalized);
                            vid = try self.intern_pool.intern(normalized);
                        }
                    }
                    vid = try internWithLeadingMarker(self.intern_pool, self.allocator, calc_interp_marker, vid);
                }
                if (!is_custom_property and self.intern_pool.get(vid).len == 0) return .continue_exec;
                // If the custom property's prop name is created via interpolation (`#{...}`),
                // official Sass CLI serializes the value as a "regular CSS expression", so
                // Flatten the redundant paren inside `calc(...)`.
                // Direct literal `--x:` (emit_decl side) call site has no effect.
                if (is_custom_property) {
                    const raw_source = if (dynamic_custom_raw_value_id) |raw_id|
                        calc_utils.stripCalcArgMarker(self.intern_pool.get(raw_id))
                    else
                        "";
                    if (hasNestedCalcFunctionText(raw_source)) {
                        const raw_source_trimmed = std.mem.trim(u8, raw_source, " \t\r\n");
                        const normalized = try normalizeRawCustomPropertyLiteral(self.allocator, raw_source_trimmed);
                        defer self.allocator.free(normalized);
                        const raw_out = if ((normalized.len == 0 or (normalized[0] != ' ' and normalized[0] != '\t')) and
                            ((inst.arg_a & opcode_mod.emit_decl_flag_custom_property_leading_space) != 0 or
                                (inst.arg_a & opcode_mod.emit_decl_flag_value_source_multiline) != 0 or
                                dynamicCustomValueNeedsImplicitLeadingSpace(normalized)))
                            try std.fmt.allocPrint(self.allocator, " {s}", .{normalized})
                        else
                            normalized;
                        defer if (raw_out.ptr != normalized.ptr) self.allocator.free(@constCast(raw_out));
                        const unmarked = try calc_utils.stripCalcInterpolationPreserveMarkers(self.allocator, raw_out);
                        defer if (unmarked.ptr != raw_out.ptr) self.allocator.free(unmarked);
                        try self.rule_ir.appendDeclRaw(self.allocator, prop_u, unmarked, self.currentSourceSpan());
                        return .continue_exec;
                    }
                    const raw = calc_utils.stripCalcArgMarker(self.intern_pool.get(vid));
                    if (raw.ptr != self.intern_pool.get(vid).ptr) {
                        vid = self.intern_pool.intern(raw) catch return error.OutOfMemory;
                    }
                    if (css_utils.containsCalcFunction(raw)) {
                        const normalized = try calc_utils.normalizeCalcInDeclValue(self.allocator, raw);
                        defer if (normalized.ptr != raw.ptr) self.allocator.free(normalized);
                        if (normalized.ptr != raw.ptr) {
                            vid = self.intern_pool.intern(normalized) catch return error.OutOfMemory;
                        }
                    }
                    const raw_after_calc = self.intern_pool.get(vid);
                    if (std.mem.indexOf(u8, raw_after_calc, calc_interp_preserve_start) != null) {
                        const unmarked = try calc_utils.stripCalcInterpolationPreserveMarkers(self.allocator, raw_after_calc);
                        defer if (unmarked.ptr != raw_after_calc.ptr) self.allocator.free(unmarked);
                        if (unmarked.ptr != raw_after_calc.ptr) {
                            vid = self.intern_pool.intern(unmarked) catch return error.OutOfMemory;
                        }
                    }
                    const value_text = self.intern_pool.get(vid);
                    const raw_out = if ((value_text.len == 0 or (value_text[0] != ' ' and value_text[0] != '\t')) and
                        ((inst.arg_a & opcode_mod.emit_decl_flag_custom_property_leading_space) != 0 or
                            (inst.arg_a & opcode_mod.emit_decl_flag_value_source_multiline) != 0 or
                            dynamicCustomValueNeedsImplicitLeadingSpace(value_text)))
                        try std.fmt.allocPrint(self.allocator, " {s}", .{value_text})
                    else
                        value_text;
                    defer if (raw_out.ptr != value_text.ptr) self.allocator.free(@constCast(raw_out));
                    try self.rule_ir.appendDeclRaw(self.allocator, prop_u, raw_out, self.currentSourceSpan());
                    return .continue_exec;
                }
                try self.rule_ir.appendDecl(self.allocator, prop_u, @intFromEnum(vid), self.currentSourceSpan());
            },
            .push_prop_namespace => {
                const prefix_v = try self.maybeResolveParentSelectorValue(try self.pop());
                const prefix_id = try valueToInternIdRaw(self.intern_pool, &self.number_pool, self.allocator, &self.list_pool, self.color_pool, &self.slash_list_preserve, prefix_v);
                const raw_prefix = std.mem.trim(u8, self.intern_pool.get(prefix_id), " \t\r\n");
                if (raw_prefix.len == 0) return .continue_exec;
                const merged_id = if (self.prop_namespace_stack.items.len == 0) blk: {
                    break :blk try self.intern_pool.intern(raw_prefix);
                } else blk: {
                    const parent = self.intern_pool.get(self.prop_namespace_stack.items[self.prop_namespace_stack.items.len - 1]);
                    const merged = try std.fmt.allocPrint(self.allocator, "{s}-{s}", .{ parent, raw_prefix });
                    defer self.allocator.free(merged);
                    break :blk try self.intern_pool.intern(merged);
                };
                try self.prop_namespace_stack.append(self.allocator, merged_id);
            },
            .pop_prop_namespace => {
                if (self.prop_namespace_stack.items.len > 0) {
                    _ = self.prop_namespace_stack.pop();
                }
            },
            else => unreachable,
        }
        return .continue_exec;
    }

    inline fn applyPendingSuppressNextRuleBeginBlank(self: *VM, new_idx: usize) void {
        if (self.suppress_next_rule_begin_blank) {
            self.rule_ir.setSuppressLeadingBlankAt(new_idx, true);
            self.suppress_next_rule_begin_blank = false;
        }
    }

    /// Call with pop_rule_scope / emit_rule_end_pop. When pushing, pop IR len snapshot,
    /// ``There are no IR emits in scope (snapshot == current_len), and since the last visible emit
    /// stmt_gap etc. are not included (rule_ir.last_visible_emit_node_count == current_ir_len)"
    /// Set `pending_empty_scope_after_visible`. For trailing empty rule blank suppression of official Sass CLI.
    inline fn popScopePushIrLenAndCheckEmpty(self: *VM) VMError!void {
        if (self.scope_push_ir_lens.items.len == 0) return;
        const start_len = self.scope_push_ir_lens.pop().?;
        const current_len = self.rule_ir.nodes.items.len;
        if (start_len == current_len and self.rule_ir.last_visible_emit_node_count == current_len) {
            self.pending_empty_scope_after_visible = true;
            self.suppress_next_origin_reopen = true;
            self.pending_set_at_visible_count = self.rule_ir.last_visible_emit_node_count;
        }
    }

    fn selectorBranchMatchesExactOrPseudoSuffix(branch: []const u8, needle_list: []const u8) bool {
        var depth: u32 = 0;
        var in_string: ?u8 = null;
        var escaped = false;
        var start: usize = 0;
        var i: usize = 0;
        while (i <= needle_list.len) : (i += 1) {
            const at_end = i == needle_list.len;
            const c: u8 = if (at_end) 0 else needle_list[i];
            if (!at_end) {
                if (in_string) |quote| {
                    if (escaped) escaped = false else if (c == '\\') escaped = true else if (c == quote) in_string = null;
                    continue;
                }
                switch (c) {
                    '\'', '"' => in_string = c,
                    '(', '[', '{' => {
                        depth += 1;
                    },
                    ')', ']', '}' => {
                        if (depth > 0) depth -= 1;
                    },
                    ',' => {},
                    else => {},
                }
                if (c != ',' or depth != 0) continue;
            }
            const needle_trim = std.mem.trim(u8, needle_list[start..i], " \t\r\n");
            if (needle_trim.len != 0 and (std.mem.eql(u8, branch, needle_trim) or
                (branch.len > needle_trim.len and std.mem.startsWith(u8, branch, needle_trim) and branch[needle_trim.len] == ':')))
            {
                return true;
            }
            start = i + 1;
        }
        return false;
    }

    fn selectorListTextContainsExactOrPseudoSuffixBranch(haystack: []const u8, needle: []const u8) bool {
        var depth: u32 = 0;
        var in_string: ?u8 = null;
        var escaped = false;
        var start: usize = 0;
        var i: usize = 0;
        while (i <= haystack.len) : (i += 1) {
            const at_end = i == haystack.len;
            const c: u8 = if (at_end) 0 else haystack[i];
            if (!at_end) {
                if (in_string) |quote| {
                    if (escaped) escaped = false else if (c == '\\') escaped = true else if (c == quote) in_string = null;
                    continue;
                }
                switch (c) {
                    '\'', '"' => in_string = c,
                    '(', '[', '{' => {
                        depth += 1;
                    },
                    ')', ']', '}' => {
                        if (depth > 0) depth -= 1;
                    },
                    ',' => {},
                    else => {},
                }
                if (c != ',' or depth != 0) continue;
            }
            const branch = std.mem.trim(u8, haystack[start..i], " \t\r\n");
            if (selectorBranchMatchesExactOrPseudoSuffix(branch, needle)) return true;
            start = i + 1;
        }
        return false;
    }

    fn suppressParentReopenMergeAfterSameSelectorChild(self: *VM) void {
        const popped = self.recent_popped_selector orelse return;
        if (self.selector_stack.items.len == 0) return;
        const parent = self.selector_stack.items[self.selector_stack.items.len - 1];
        if (popped == parent) {
            self.suppress_next_origin_reopen = true;
            return;
        }
        if (selectorListTextContainsExactOrPseudoSuffixBranch(
            self.intern_pool.get(popped),
            self.intern_pool.get(parent),
        )) {
            self.suppress_next_origin_reopen = true;
        }
    }

    fn appendCurrentRuleBegin(self: *VM, suppress_top_level_blank: bool) VMError!void {
        return vm_emit.appendCurrentRuleBegin(self, suppress_top_level_blank);
    }

    fn openCurrentRuleBlock(self: *VM, maybe: bool, suppress_top_level_blank: bool) VMError!void {
        return vm_emit.openCurrentRuleBlock(self, maybe, suppress_top_level_blank);
    }

    fn noteMaybeCurrentRuleClosedByExplicitEnd(self: *VM) void {
        if (self.maybe_current_rule_stack.items.len == 0) return;
        const top = &self.maybe_current_rule_stack.items[self.maybe_current_rule_stack.items.len - 1];
        if (top.* == .open) top.* = .closed_elsewhere;
    }

    fn finishRuleBlockClose(self: *VM) VMError!void {
        if (self.open_rule_depth > 0) self.open_rule_depth -= 1;
        if (self.open_rule_selector_depth_stack.items.len > 0) {
            _ = self.open_rule_selector_depth_stack.pop();
        }
        if (self.open_block_depth > 0) self.open_block_depth -= 1;
        try self.rule_ir.appendRuleEnd(self.allocator, self.currentSourceSpan());
        try self.maybeFlushStreamChunks();
    }

    fn closeRuleBlock(self: *VM) VMError!void {
        self.noteMaybeCurrentRuleClosedByExplicitEnd();
        // Loud comments inside a parent selector can be emitted through a
        // temporary RuleIR wrapper when the parent block itself is already
        // closed.  The compiler may still have a structural EMIT_RULE_END for
        // the source block; with no open RuleIR block there is nothing to close.
        // Emitting here would create an unmatched top-level rule_end before the
        // following nested sibling.
        if (self.open_rule_depth == 0) return;
        try self.finishRuleBlockClose();
    }

    fn closeMaybeCurrentRuleBlock(self: *VM) VMError!void {
        if (self.maybe_current_rule_stack.items.len == 0) return error.BadJump;
        const state = self.maybe_current_rule_stack.pop().?;
        switch (state) {
            .inactive, .closed_elsewhere => {},
            .open => try self.finishRuleBlockClose(),
        }
    }

    fn closeRuleBlockIfOpen(self: *VM) VMError!void {
        if (self.open_rule_depth == 0) return;
        self.noteMaybeCurrentRuleClosedByExplicitEnd();
        try self.finishRuleBlockClose();
    }

    fn closeOpenMaybeCurrentRuleBeforeBoundary(self: *VM) VMError!void {
        if (self.maybe_current_rule_stack.items.len == 0) return;
        const top = &self.maybe_current_rule_stack.items[self.maybe_current_rule_stack.items.len - 1];
        if (top.* != .open) return;
        top.* = .closed_elsewhere;
        try self.finishRuleBlockClose();
    }

    /// `emit_rule_begin*` / `push_selector_scope*` 4 Common handler for opcodes.
    /// If `emit_rule` is true, load rule_begin in Rule IR and advance `open_rule_depth`.
    /// If false, push only to selector_stack (not to parent scope integration, Rule IR).
    /// If `dynamic` is true, get the selector from the value that pops the stack top, if it is false
    /// Use intern id of `inst.arg_b`.
    fn openRuleScope(self: *VM, inst: Instruction, emit_rule: bool, dynamic: bool) VMError!void {
        self.recent_popped_selector = null;
        self.suppress_next_origin_reopen = false;
        // leak close: Case in which open_rule_depth remains even though the parent block has already been closed.
        // Fix up only in opcodes that issue rule_begin (push_selector_scope does not open block).
        if (emit_rule and self.selector_stack.items.len == 0 and self.open_rule_depth > 0) {
            var leak = self.open_rule_depth;
            while (leak > 0) : (leak -= 1) {
                try self.rule_ir.appendRuleEnd(self.allocator, self.currentSourceSpan());
            }
            if (self.open_block_depth >= self.open_rule_depth) {
                self.open_block_depth -= self.open_rule_depth;
            } else {
                self.open_block_depth = 0;
            }
            self.open_rule_depth = 0;
            self.open_rule_selector_depth_stack.clearRetainingCapacity();
        }
        const mode = decodeRuleOpenMode(inst.arg_a);
        if (!dynamic and (inst.arg_a & rule_flag_selector_validation_failed) != 0) {
            return error.SassError;
        }
        const out_id = if (dynamic) blk: {
            const v = try self.pop();
            break :blk try self.internDynamicSelectorValueWithMode(v, mode);
        } else try self.resolveSelectorInternForStackWithMode(inst.arg_b, mode);
        if (emit_rule) {
            // nest_depth on Rule IR is "selector_stack depth just before pushing itself" = "number of parent scopes".
            // This also causes the push-only parent scope (`.a` of `.a { .b { ... } }`)
            // Count as a parent and give nest_depth > 0 to the rule hoisted to top-level with unnest.
            // writer side fallback blank (`indent_level == 0 and nest_depth == 0`) between unnest sibling
            // Prevent accidental firing.
            const nest_depth: u8 = saturateNestDepth(self.selector_stack.items.len);
            const owner_module = self.currentSelectorPushOwnerModuleTag();
            try self.selector_stack.append(self.allocator, out_id);
            try self.selector_owner_stack.append(self.allocator, owner_module);
            try self.scope_push_ir_lens.append(self.allocator, self.rule_ir.nodes.items.len);
            var span = self.current_source_span;
            span.file_id = owner_module;
            try self.rule_ir.appendRuleBegin(self.allocator, @intFromEnum(out_id), nest_depth, span);
            const new_idx = self.rule_ir.nodes.items.len - 1;
            self.applyPendingSuppressNextRuleBeginBlank(new_idx);
            // Rule_begin emitted within @at-root scope is treated as hoisted.
            if (self.at_root_saved_selector_frames.items.len > 0) {
                self.rule_ir.setOriginAtRootHoistedAt(new_idx, true);
                self.rule_ir.setSuppressLeadingBlankAt(new_idx, true);
            }
            self.open_rule_depth += 1;
            try self.open_rule_selector_depth_stack.append(self.allocator, @intCast(self.selector_stack.items.len));
            self.open_block_depth += 1;
        } else {
            try self.selector_stack.append(self.allocator, out_id);
            try self.selector_owner_stack.append(self.allocator, self.currentSelectorPushOwnerModuleTag());
            try self.scope_push_ir_lens.append(self.allocator, self.rule_ir.nodes.items.len);
        }
    }

    fn pushAtRootScope(self: *VM, keep_prefix: bool) VMError!void {
        const keep_len: usize = if (keep_prefix)
            @min(self.selector_prefix_depth, self.selector_stack.items.len)
        else
            0;
        const parent = if (keep_prefix and self.selector_stack.items.len > 0)
            self.selector_stack.items[self.selector_stack.items.len - 1]
        else
            null;
        const saved = try self.allocator.dupe(InternId, self.selector_stack.items[keep_len..]);
        errdefer self.allocator.free(saved);
        const saved_owner_modules = try self.allocator.dupe(u32, self.selector_owner_stack.items[keep_len..]);
        errdefer self.allocator.free(saved_owner_modules);
        // scope_push_ir_lens keeps the same length as selector_stack. Cut with keep_len.
        const saved_lens = try self.allocator.dupe(usize, self.scope_push_ir_lens.items[keep_len..]);
        errdefer self.allocator.free(saved_lens);
        try self.at_root_saved_selector_frames.append(self.allocator, .{
            .selectors = saved,
            .owner_modules = saved_owner_modules,
            .push_ir_lens = saved_lens,
            .keep_len = keep_len,
            .parent = parent,
        });
        self.selector_stack.items.len = keep_len;
        self.selector_owner_stack.items.len = keep_len;
        self.scope_push_ir_lens.items.len = keep_len;
    }

    fn popAtRootScope(self: *VM) VMError!void {
        if (self.at_root_saved_selector_frames.items.len == 0) return;
        const frame = self.at_root_saved_selector_frames.pop().?;
        defer self.allocator.free(frame.selectors);
        defer self.allocator.free(frame.owner_modules);
        defer self.allocator.free(frame.push_ir_lens);
        while (self.selector_stack.items.len > frame.keep_len) {
            _ = self.selector_stack.pop();
        }
        while (self.selector_owner_stack.items.len > frame.keep_len) {
            _ = self.selector_owner_stack.pop();
        }
        // Also cut scope_push_ir_lens to frame.keep_len.
        if (self.scope_push_ir_lens.items.len > frame.keep_len) {
            self.scope_push_ir_lens.items.len = frame.keep_len;
        }
        try self.selector_stack.appendSlice(self.allocator, frame.selectors);
        try self.selector_owner_stack.appendSlice(self.allocator, frame.owner_modules);
        try self.scope_push_ir_lens.appendSlice(self.allocator, frame.push_ir_lens);
    }

    fn pushAtRootBubble(self: *VM, mask: u8) VMError!void {
        if (mask == 0) return;
        try self.at_root_bubble_stack.append(self.allocator, .{
            .start_idx = self.rule_ir.nodes.items.len,
            .mask = mask,
        });
    }

    fn popAtRootBubble(self: *VM) void {
        if (self.at_root_bubble_stack.items.len == 0) return;
        const frame = self.at_root_bubble_stack.pop().?;
        const end_idx = self.rule_ir.nodes.items.len;
        if (frame.start_idx >= end_idx) return;
        self.rule_ir.markTopLevelRangeBubbleFlags(frame.start_idx, end_idx, frame.mask);

        var outer_bubble_mask: u8 = 0;
        var wrapper_node_idx: ?usize = null;
        for (self.open_at_rule_bubble_stack.items) |entry| {
            const matched = entry.type_mask & frame.mask;
            if (matched != 0) {
                outer_bubble_mask |= matched;
                continue;
            }
            if (outer_bubble_mask != 0) {
                wrapper_node_idx = entry.node_idx;
                break;
            }
        }
        if (wrapper_node_idx) |node_idx| {
            self.rule_ir.addBubbleMaskAt(node_idx, outer_bubble_mask);
        }
    }

    fn applyPropertyNamespace(self: *VM, prop_id: InternId) VMError!InternId {
        if (self.prop_namespace_stack.items.len == 0) return prop_id;
        const prefix_id = self.prop_namespace_stack.items[self.prop_namespace_stack.items.len - 1];
        const prefix = self.intern_pool.get(prefix_id);
        if (prefix.len == 0) return prop_id;
        const prop = self.intern_pool.get(prop_id);
        const merged = try std.fmt.allocPrint(self.allocator, "{s}-{s}", .{ prefix, prop });
        defer self.allocator.free(merged);
        return self.intern_pool.intern(merged) catch error.OutOfMemory;
    }

    pub fn currentAtRootParentSelector(self: *const VM) ?InternId {
        if (self.at_root_saved_selector_frames.items.len == 0) return null;
        return self.at_root_saved_selector_frames.items[self.at_root_saved_selector_frames.items.len - 1].parent;
    }

    pub fn currentAtRootKeepLen(self: *const VM) ?usize {
        if (self.at_root_saved_selector_frames.items.len == 0) return null;
        return self.at_root_saved_selector_frames.items[self.at_root_saved_selector_frames.items.len - 1].keep_len;
    }

    fn mediaQueryActive(self: *const VM) bool {
        return self.media_query_depth != 0;
    }

    fn declarationAtRuleActive(self: *const VM) bool {
        return self.at_rule_decl_container_stack.items.len != 0 and
            self.at_rule_decl_container_stack.items[self.at_rule_decl_container_stack.items.len - 1];
    }

    fn internExtendTargetValue(self: *VM, v: Value) VMError!InternId {
        const resolved = try self.maybeResolveParentSelectorValue(v);
        const raw_unfixed_id = if (resolved.isString() and !resolved.stringQuoted(self.string_flags_pool.items))
            resolved.stringIntern()
        else
            try valueToInternIdRaw(
                self.intern_pool,
                &self.number_pool,
                self.allocator,
                &self.list_pool,
                self.color_pool,
                &self.slash_list_preserve,
                resolved,
            );
        const unescaped_id = try self.maybeUnescapeDynamicSelectorText(raw_unfixed_id);
        const raw_id = try self.ensureInternTrailingEscapeDelimiter(unescaped_id);
        if (std.mem.trim(u8, self.intern_pool.get(raw_id), " \t\r\n").len == 0) return error.SassError;
        return raw_id;
    }

    pub fn ensureInternTrailingEscapeDelimiter(self: *VM, raw_id: InternId) VMError!InternId {
        const raw = self.intern_pool.get(raw_id);
        if (!endsWithCssHexEscape(raw)) return raw_id;
        const with_delim = try std.fmt.allocPrint(self.allocator, "{s} ", .{raw});
        defer self.allocator.free(with_delim);
        return self.intern_pool.intern(with_delim) catch error.OutOfMemory;
    }

    fn currentAmpersandSelector(self: *const VM) ?InternId {
        if (self.currentAtRootParentSelector()) |saved_parent| {
            if (self.selector_stack.items.len == self.selector_prefix_depth) return saved_parent;
        }
        if (self.selector_stack.items.len == 0) return null;
        return self.selector_stack.items[self.selector_stack.items.len - 1];
    }

    pub fn combineNestedRuleSelectorForSelectorResolve(self: *VM, parent_sel: []const u8, child_sel: []const u8) VMError![]const u8 {
        return combineNestedRuleSelector(self.allocator, parent_sel, child_sel);
    }

    pub fn validateLiteralSelectorForSelectorResolve(self: *const VM, selector: []const u8) VMError!void {
        try validateLiteralSelectorForScope(selector, self.hasActiveSelectorContext());
    }

    pub fn validateDynamicSelectorForSelectorResolve(self: *const VM, selector: []const u8) VMError!void {
        try validateDynamicSelectorForScope(selector, self.hasActiveSelectorContext());
    }

    pub fn valueToInternIdRawForSelectorResolve(self: *VM, value: Value) VMError!InternId {
        return valueToInternIdRaw(
            self.intern_pool,
            &self.number_pool,
            self.allocator,
            &self.list_pool,
            self.color_pool,
            &self.slash_list_preserve,
            value,
        );
    }

    fn maybeUnescapeDynamicSelectorText(self: *VM, raw_id: InternId) VMError!InternId {
        return vm_selector_resolve.maybeUnescapeDynamicSelectorText(self, raw_id);
    }

    fn resolveSelectorInternForStackWithMode(self: *VM, sel_u: u32, mode: RuleOpenMode) VMError!InternId {
        return vm_selector_resolve.resolveSelectorInternForStackWithMode(self, sel_u, mode);
    }

    fn resolveSelectorInternForStack(self: *VM, sel_u: u32) VMError!InternId {
        return vm_selector_resolve.resolveSelectorInternForStack(self, sel_u);
    }

    pub fn currentSourceSpan(self: *const VM) Span {
        return self.current_source_span;
    }

    pub fn currentSelectorOwnerSpan(self: *const VM) Span {
        var span = self.current_source_span;
        span.file_id = self.currentSelectorOwnerModuleTag();
        return span;
    }

    pub fn currentSelectorOwnerModuleTag(self: *const VM) u32 {
        if (self.selector_owner_stack.items.len == 0) return self.currentEmitModuleTag();
        return self.selector_owner_stack.items[self.selector_owner_stack.items.len - 1];
    }

    pub fn currentSelectorPushOwnerModuleTag(self: *const VM) u32 {
        if (self.load_css_module_tag_override) |tag| return tag;
        if (self.selector_owner_stack.items.len != 0) return self.currentSelectorOwnerModuleTag();
        if (self.current_source_span.file_id == self.current_module) return self.current_source_span.file_id;
        if (self.frame_stack.items.len != 0) return self.currentEmitModuleTag();
        return self.current_source_span.file_id;
    }

    pub fn currentEmitModuleTag(self: *const VM) u32 {
        if (self.load_css_module_tag_override) |tag| return tag;
        if (self.frame_stack.items.len == 0) return self.current_module;

        // CSS generated by a mixin belongs to the module that invoked the
        // outermost active callable for module-system @extend visibility. Keep
        // source spans pointing at the callee text for diagnostics, but tag
        // RuleIR nodes by the include site so sibling modules cannot extend
        // selectors merely because both call/use the mixin's defining module.
        for (self.frame_stack.items) |fr| {
            if (fr.caller_module_id != self.current_module) return fr.caller_module_id;
        }
        return self.frame_stack.items[0].caller_module_id;
    }

    fn printCurrentVmErrorSource(self: *const VM) void {
        const file_id: usize = @intCast(self.current_source_span.file_id);
        if (file_id >= self.program.modules.len) return;
        const module = self.program.modules[file_id];
        const start = sourceOffsetToLineColVm(module.line_starts, module.source_len, self.current_source_span.start);
        const end = sourceOffsetToLineColVm(module.line_starts, module.source_len, self.current_source_span.end);
        vmStderrPrint(
            "zsass src file={s} span={d}:{d}-{d}:{d} bytes={d}..{d}\n",
            .{
                module.module_path,
                start.line + 1,
                start.col + 1,
                end.line + 1,
                end.col + 1,
                self.current_source_span.start,
                self.current_source_span.end,
            },
        );
    }

    fn printLoadLocalMulConstDiagnostic(
        self: *VM,
        slot: usize,
        const_idx: usize,
        lhs: Value,
        rhs: Value,
        preserve_css_math: bool,
    ) void {
        const lhs_text = self.allocValueDiagnosticText(lhs) catch return;
        defer self.allocator.free(lhs_text);
        const rhs_text = self.allocValueDiagnosticText(rhs) catch return;
        defer self.allocator.free(rhs_text);
        vmStderrPrint(
            "zsass mul-local-const slot={d} const_idx={d} lhs_kind={s} rhs_kind={s} preserve_css_math={any} lhs={s} rhs={s}\n",
            .{
                slot,
                const_idx,
                @tagName(lhs.kind()),
                @tagName(rhs.kind()),
                preserve_css_math,
                lhs_text,
                rhs_text,
            },
        );
    }

    fn allocValueDiagnosticText(self: *VM, v: Value) VMError![]const u8 {
        return valueToOpString(self.intern_pool, &self.number_pool, self.allocator, &self.list_pool, self.color_pool, &self.callable_payload_pool, v) catch
            std.fmt.allocPrint(self.allocator, "<{s}>", .{@tagName(v.kind())}) catch error.OutOfMemory;
    }

    fn currentSourceUsesIndentedSyntax(self: *const VM) bool {
        const file_id: usize = @intCast(self.current_source_span.file_id);
        if (file_id >= self.program.modules.len) return false;
        const path = self.program.modules[file_id].module_path;
        return std.mem.endsWith(u8, path, ".sass");
    }

    fn currentSourceUsesPlainCss(self: *const VM) bool {
        const file_id: usize = @intCast(self.current_source_span.file_id);
        if (file_id < self.program.modules.len) {
            const path = self.program.modules[file_id].module_path;
            if (std.mem.endsWith(u8, path, ".css")) return true;
        }
        if (self.current_module < self.program.modules.len) {
            return std.mem.endsWith(u8, self.program.modules[self.current_module].module_path, ".css");
        }
        return false;
    }

    fn currentSourceSpanLooksNested(self: *const VM) bool {
        const file_id: usize = @intCast(self.current_source_span.file_id);
        if (file_id >= self.program.modules.len) return false;
        const module = &self.program.modules[file_id];
        if (self.current_source_span.start >= module.source_len) return true;
        if (module.line_starts.len == 0) return false;

        var line_idx: usize = 0;
        while (line_idx + 1 < module.line_starts.len and module.line_starts[line_idx + 1] <= self.current_source_span.start) : (line_idx += 1) {}
        return self.current_source_span.start > module.line_starts[line_idx];
    }

    fn reopenRecentNestedRuleForDeclaration(self: *VM) VMError!void {
        if (self.open_block_depth != 0 or self.selector_stack.items.len != 0) return;
        if (self.load_css_strict_top_level or self.mediaQueryActive()) return;
        // In `.sass`, indentation itself is a block structure, so source-order split
        // Multiplying reopen heuristic causes invalid dedent to be mistaken as sibling declaration.
        if (self.currentSourceUsesIndentedSyntax()) return;
        if (!self.currentSourceSpanLooksNested()) return;

        const selector = self.recent_popped_selector orelse return;
        try self.selector_stack.append(self.allocator, selector);
        errdefer _ = self.selector_stack.pop();
        try self.selector_owner_stack.append(self.allocator, self.recent_popped_selector_owner);
        errdefer _ = self.selector_owner_stack.pop();
        try self.scope_push_ir_lens.append(self.allocator, self.rule_ir.nodes.items.len);
        errdefer _ = self.scope_push_ir_lens.pop();
        try self.appendCurrentRuleBegin(true);
        self.recent_popped_selector = null;
    }

    fn emitCommentWithRuleWrap(self: *VM, text_id: InternId, source_col: u32, leading_same_line: bool) VMError!void {
        return vm_emit.emitCommentWithRuleWrap(self, text_id, source_col, leading_same_line);
    }

    fn ensureCurrentRuleOpenForDeclaration(self: *VM) VMError!void {
        if (self.selector_stack.items.len == 0) return;
        if (self.open_rule_depth != 0) return;
        // A declaration that resumes the current parent rule immediately after
        // a nested child rule (`.a { &::after {...} color: red; }`) is a
        // source-order split of one nested block, not a fresh top-level
        // sibling.  Suppress writer fallback blank for that reopen.  @at-root
        // hoists are deliberately excluded: official Sass CLI keeps a blank between
        // the hoisted block and the resumed parent rule.
        const suppress_reopen_blank = self.recent_popped_selector != null and
            self.at_root_saved_selector_frames.items.len == 0 and
            self.currentSourceSpanLooksNested();
        try self.openCurrentRuleBlock(true, suppress_reopen_blank);
    }

    fn declarationValueNeedsIndentedCommaSyntaxError(self: *VM, value: Value, emit_decl_flags: u16) VMError!bool {
        if (value.kind() != .list) return false;
        if (value.listSeparator(self.list_meta_pool.items) != .comma or value.listBracketed(self.list_meta_pool.items) or value.listIsMap(self.list_meta_pool.items)) return false;
        if (!self.currentSourceUsesIndentedSyntax()) return false;
        const handle: usize = @intCast(value.listHandle());
        if (handle >= self.list_pool.items.len) return false;
        const items = self.list_pool.items[handle];
        if (items.len < 2) return false;

        if ((emit_decl_flags & opcode_mod.emit_decl_flag_bare_multiline_comma_syntax) != 0) return true;
        if ((emit_decl_flags & opcode_mod.emit_decl_flag_has_explicit_top_level_comma) != 0) return false;

        const shape = self.list_source_shapes.get(value.listHandle()) orelse return false;
        if (shape.first_item_gap != 0) return false;
        return shape.first_pair_gap > 2;
    }

    /// `emit_rule_begin_dynamic` / `push_selector_scope_dynamic` Common: Combine child selector value with parent stack and intern.
    fn internDynamicSelectorValueWithMode(self: *VM, v: Value, mode: RuleOpenMode) VMError!InternId {
        return vm_selector_resolve.internDynamicSelectorValueWithMode(self, v, mode);
    }

    /// `emit_rule_begin_dynamic` / `push_selector_scope_dynamic` Common: Combine child selector value with parent stack and intern.
    fn internDynamicSelectorValue(self: *VM, v: Value) VMError!InternId {
        return vm_selector_resolve.internDynamicSelectorValue(self, v);
    }

    fn valueToPreparedPreludeIntern(self: *VM, name_id: InternId, v: Value, media_flags: u8) VMError!?InternId {
        if (v.kind() == .nil) return null;
        const raw_id = try valueToInternIdRaw(
            self.intern_pool,
            &self.number_pool,
            self.allocator,
            &self.list_pool,
            self.color_pool,
            &self.slash_list_preserve,
            v,
        );

        var prelude_id = raw_id;
        const raw_for_marker = self.intern_pool.get(raw_id);
        if (std.mem.indexOf(u8, raw_for_marker, calc_interp_preserve_start) != null) {
            const unmarked = try calc_utils.stripCalcInterpolationPreserveMarkers(self.allocator, raw_for_marker);
            defer if (unmarked.ptr != raw_for_marker.ptr) self.allocator.free(unmarked);
            if (unmarked.ptr != raw_for_marker.ptr) {
                prelude_id = try self.intern_pool.intern(unmarked);
            }
        }

        const name = self.intern_pool.get(name_id);
        const raw_name = if (name.len > 0 and name[0] == '@') name[1..] else name;
        if (std.mem.eql(u8, raw_name, "supports")) {
            const raw = self.intern_pool.get(prelude_id);
            if (std.mem.indexOfAny(u8, raw, "\n\r") != null) return prelude_id;
            const had_interp = (media_flags & media_prelude_has_interp_flag) != 0;
            const prepared = try supports_prelude.prepare(
                self.allocator,
                raw,
                !had_interp,
            );
            defer self.allocator.free(prepared);
            return try self.intern_pool.intern(prepared);
        }
        if (!std.mem.eql(u8, raw_name, "media")) return prelude_id;

        var current: []const u8 = try self.allocator.dupe(u8, self.intern_pool.get(prelude_id));
        defer self.allocator.free(current);

        const had_interp = (media_flags & media_prelude_has_interp_flag) != 0;
        const interp_at_start = (media_flags & media_prelude_interp_at_start_flag) != 0;
        const compact_dynamic_feature_colon = (media_flags & media_prelude_compact_dynamic_feature_colon_flag) != 0;

        const stripped = if (had_interp)
            try media_prelude.stripPreludeComments(self.allocator, current)
        else
            try media_prelude.stripSupportsComments(self.allocator, current);
        if (stripped.ptr != current.ptr) {
            self.allocator.free(current);
            current = stripped;
        }

        if (media_prelude.mediaPreludeHasLineBreakBeforeLogicKeyword(current)) return error.SassError;

        const normalized_ws = try media_prelude.normalizePreludeWhitespaceWithOptions(self.allocator, current, had_interp);
        if (normalized_ws.ptr != current.ptr) {
            self.allocator.free(current);
            current = normalized_ws;
        }

        const fixed_commas = try media_prelude.removeSpaceBeforeMediaCommas(self.allocator, current);
        if (fixed_commas.ptr != current.ptr) {
            self.allocator.free(current);
            current = fixed_commas;
        }

        const unwrapped = try media_prelude.unwrapMediaNot(self.allocator, current, had_interp);
        if (unwrapped.ptr != current.ptr) {
            self.allocator.free(current);
            current = unwrapped;
        }

        const trimmed_start = std.mem.trimStart(u8, current, " \t\r\n");
        const trimmed_end = std.mem.trimEnd(u8, trimmed_start, " \t\r\n");
        if (trimmed_end.len == 0) return null;
        const had_trailing_ws = trimmed_end.len != trimmed_start.len;
        const keep_escape_delimiter = had_trailing_ws and endsWithCssHexEscape(trimmed_end);
        if (trimmed_end.ptr != current.ptr or trimmed_end.len != current.len or keep_escape_delimiter) {
            const extra: usize = if (keep_escape_delimiter) 1 else 0;
            const duped = try self.allocator.alloc(u8, trimmed_end.len + extra);
            @memcpy(duped[0..trimmed_end.len], trimmed_end);
            if (keep_escape_delimiter) duped[trimmed_end.len] = ' ';
            self.allocator.free(current);
            current = duped;
        }

        if (!had_interp) {
            const normalized_kw = try media_prelude.normalizeMediaKeywords(self.allocator, current);
            if (normalized_kw.ptr != current.ptr) {
                self.allocator.free(current);
                current = normalized_kw;
            }
        }

        const escape_separated = try insertMediaHexEscapeSeparatorsBeforeParen(self.allocator, current);
        if (escape_separated.ptr != current.ptr) {
            self.allocator.free(current);
            current = escape_separated;
        }

        const unquoted = try unquoteQuotedMediaFeatureStrings(self.allocator, current);
        const unquoted_media_feature = !(unquoted.ptr == current.ptr and unquoted.len == current.len);
        if (unquoted.ptr != current.ptr) {
            self.allocator.free(current);
            current = unquoted;
        }

        if (compact_dynamic_feature_colon) {
            const compacted_colon = try compactWhitespaceAfterColon(self.allocator, current);
            if (compacted_colon.ptr != current.ptr) {
                self.allocator.free(current);
                current = compacted_colon;
            }
        }

        media_prelude.validateMediaQueryPrelude(current, interp_at_start) catch return error.SassError;
        if (had_interp or unquoted_media_feature) {
            const marked = try std.mem.concat(self.allocator, u8, &.{ media_prelude_preserve_case_marker, current });
            self.allocator.free(current);
            current = marked;
        }
        return try self.intern_pool.intern(current);
    }

    fn splitDynamicAtRuleText(self: *VM, v: Value) VMError!struct { name_id: InternId, prelude_id: ?InternId } {
        if (v.kind() == .nil) return error.SassError;
        const raw_id = try valueToInternIdRaw(
            self.intern_pool,
            &self.number_pool,
            self.allocator,
            &self.list_pool,
            self.color_pool,
            &self.slash_list_preserve,
            v,
        );
        const raw = std.mem.trim(u8, self.intern_pool.get(raw_id), " \t\r\n");
        if (raw.len == 0) return error.SassError;
        var name_end: usize = 0;
        while (name_end < raw.len and raw[name_end] != ' ' and raw[name_end] != '\t' and raw[name_end] != '\n' and raw[name_end] != '\r') : (name_end += 1) {}
        const name_raw = if (raw[0] == '@') raw[1..name_end] else raw[0..name_end];
        if (name_raw.len == 0) return error.SassError;
        var prelude_start = name_end;
        while (prelude_start < raw.len and (raw[prelude_start] == ' ' or raw[prelude_start] == '\t' or raw[prelude_start] == '\n' or raw[prelude_start] == '\r')) : (prelude_start += 1) {}
        const name_id = try self.intern_pool.intern(name_raw);
        const prelude_id = if (prelude_start < raw.len)
            try self.intern_pool.intern(raw[prelude_start..])
        else
            null;
        return .{ .name_id = name_id, .prelude_id = prelude_id };
    }

    fn unquoteQuotedMediaFeatureStrings(alloc: std.mem.Allocator, text: []const u8) VMError![]const u8 {
        var acc: std.ArrayListUnmanaged(u8) = .empty;
        defer acc.deinit(alloc);

        var i: usize = 0;
        var changed = false;
        while (i < text.len) {
            if (text[i] != '(') {
                try acc.append(alloc, text[i]);
                i += 1;
                continue;
            }

            const close_idx = findMatchingParenInDeclText(text, i) orelse {
                try acc.append(alloc, text[i]);
                i += 1;
                continue;
            };
            const inner = text[i + 1 .. close_idx];
            const trimmed = std.mem.trim(u8, inner, " \t\r\n");
            const unquoted = unwrapSingleQuotedToken(trimmed);
            if (unquoted) |raw_inner| {
                const canonical_inner = try compactWhitespaceAfterColon(alloc, raw_inner);
                defer if (canonical_inner.ptr != raw_inner.ptr) alloc.free(canonical_inner);
                try acc.append(alloc, '(');
                try acc.appendSlice(alloc, canonical_inner);
                try acc.append(alloc, ')');
                changed = true;
            } else {
                const value_unquoted = try unquoteQuotedMediaFeatureValueTokens(alloc, inner);
                defer if (value_unquoted.ptr != inner.ptr) alloc.free(value_unquoted);
                if (value_unquoted.ptr != inner.ptr or value_unquoted.len != inner.len) {
                    try acc.append(alloc, '(');
                    try acc.appendSlice(alloc, value_unquoted);
                    try acc.append(alloc, ')');
                    changed = true;
                } else {
                    try acc.appendSlice(alloc, text[i .. close_idx + 1]);
                }
            }
            i = close_idx + 1;
        }

        if (!changed) return text;
        return try acc.toOwnedSlice(alloc);
    }

    fn unquoteQuotedMediaFeatureValueTokens(alloc: std.mem.Allocator, text: []const u8) VMError![]const u8 {
        var acc: std.ArrayListUnmanaged(u8) = .empty;
        defer acc.deinit(alloc);

        var i: usize = 0;
        var changed = false;
        var after_colon = false;
        while (i < text.len) {
            const c = text[i];
            if (!after_colon) {
                try acc.append(alloc, c);
                if (c == ':') after_colon = true;
                i += 1;
                continue;
            }
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                try acc.append(alloc, c);
                i += 1;
                continue;
            }
            if (c == '"' or c == '\'') {
                const quote = c;
                var j = i + 1;
                while (j < text.len) : (j += 1) {
                    if (text[j] == '\\' and j + 1 < text.len) {
                        j += 1;
                        continue;
                    }
                    if (text[j] == quote) break;
                }
                if (j < text.len and text[j] == quote) {
                    try acc.appendSlice(alloc, text[i + 1 .. j]);
                    i = j + 1;
                    changed = true;
                    after_colon = false;
                    continue;
                }
            }
            try acc.append(alloc, c);
            after_colon = false;
            i += 1;
        }

        if (!changed) return text;
        return try acc.toOwnedSlice(alloc);
    }

    fn unwrapSingleQuotedToken(text: []const u8) ?[]const u8 {
        if (text.len < 2) return null;
        const quote = text[0];
        if (quote != '"' and quote != '\'') return null;

        var i: usize = 1;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (text[i] == quote) {
                if (i + 1 != text.len) return null;
                return text[1..i];
            }
        }
        return null;
    }

    fn compactWhitespaceAfterColon(alloc: std.mem.Allocator, text: []const u8) VMError![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(alloc);

        var i: usize = 0;
        var changed = false;
        while (i < text.len) : (i += 1) {
            const c = text[i];
            try out.append(alloc, c);
            if (c != ':') continue;

            var j = i + 1;
            while (j < text.len and (text[j] == ' ' or text[j] == '\t' or text[j] == '\n' or text[j] == '\r')) : (j += 1) {}
            if (j != i + 1) {
                changed = true;
                i = j - 1;
            }
        }

        if (!changed) return text;
        return try out.toOwnedSlice(alloc);
    }

    pub fn maybeResolveParentSelectorValue(self: *VM, v: Value) VMError!Value {
        if (v.kind() == .list) {
            if (v.listParentSelectorNone()) return v;
            const in_handle = v.listHandle();
            // list_pool's slice is append-only and immutable. Once with "No `&`"
            // The determined handle will have the same conclusion thereafter.
            // Avoid repeated traversal of large immutable lists.
            if (self.listHandleParentSelNone(in_handle)) return v;

            const items = self.list_pool.items[in_handle];
            // Most lists do not contain `&` and do not require conversion. in that case
            // Pre-allocating the ArrayList is pure waste. Delayed until first change detected.
            var resolved_items: std.ArrayListUnmanaged(Value) = .empty;
            defer resolved_items.deinit(self.allocator);
            var changed = false;

            for (items, 0..) |item, i| {
                const resolved = try self.maybeResolveParentSelectorValue(item);
                const item_changed = (resolved.kind() != item.kind() or resolved.p32Of() != item.p32Of() or resolved.p64Of() != item.p64Of());
                if (!changed) {
                    if (item_changed) {
                        try resolved_items.ensureTotalCapacity(self.allocator, items.len);
                        try resolved_items.appendSlice(self.allocator, items[0..i]);
                        try resolved_items.append(self.allocator, resolved);
                        changed = true;
                    }
                } else {
                    try resolved_items.append(self.allocator, resolved);
                }
            }
            if (!changed) {
                try self.noteListParentSelNone(in_handle);
                return v.withListParentSelectorNone();
            }

            const handle: u32 = @intCast(self.list_pool.items.len);
            const owned = try self.arena().alloc(Value, resolved_items.items.len);
            @memcpy(owned, resolved_items.items);
            try self.list_pool.append(self.allocator, owned);
            return Value.listWithMetaEx(handle, v.listSeparator(self.list_meta_pool.items), v.listBracketed(self.list_meta_pool.items), v.listIsMap(self.list_meta_pool.items), v.listCoerceSlash(self.list_meta_pool.items));
        }
        if (v.kind() != .string or v.stringQuoted(self.string_flags_pool.items)) return v;
        if (v.stringPreservesAmpersand(self.string_flags_pool.items)) return v;
        const raw = self.intern_pool.get(v.stringIntern());
        if (!std.mem.eql(u8, raw, "&")) return v;
        const current_id = self.currentAmpersandSelector() orelse return Value.nil_v;
        const current_text = self.intern_pool.get(current_id);
        return self.selectorTextToValue(current_text) catch |err| switch (err) {
            // Give up converting the corrupted selector to a value and save it to a plain string (maintaining the existing behavior).
            error.SassError => Value.string(current_id, false),
            else => return err,
        };
    }

    pub fn valueKnownNoParentSelector(self: *VM, v: Value) bool {
        return switch (v.kind()) {
            .list => v.listParentSelectorNone() or self.listHandleParentSelNone(v.listHandle()),
            .string => v.stringQuoted(self.string_flags_pool.items) or
                v.stringPreservesAmpersand(self.string_flags_pool.items) or
                v.stringIntern() != intern_pool_mod.intern_ampersand,
            else => true,
        };
    }

    /// Readonly check for list_pool handle unit sidecar bitset. Only handles less than bit_length
    /// `isSet`, false if out of range (= undefined). bitset is a lazy resize, so bit is set at construction time.
    /// The handle that was not set up may initially be less than or outside bit_length, both of which are
    /// It works safely with "unknown  ->  false".
    pub inline fn listHandleParentSelNone(self: *const VM, handle: u32) bool {
        return handle < self.list_parent_sel_none.bit_length and self.list_parent_sel_none.isSet(handle);
    }

    /// Set the bit for handle in sidecar bitset. If bit_length is insufficient, resize.
    /// Since list_pool is append-only, handle < list_pool.items.len is assumed.
    pub fn noteListParentSelNone(self: *VM, handle: u32) std.mem.Allocator.Error!void {
        if (handle >= self.list_parent_sel_none.bit_length) {
            // Cheap (amortized) even if you follow the entire list_pool and repeat append after that.
            // Resize based on list_pool.items.len to reserve some capacity in advance.
            const target = @max(@as(usize, handle) + 1, self.list_pool.items.len);
            try self.list_parent_sel_none.resize(self.allocator, target, false);
        }
        self.list_parent_sel_none.set(handle);
    }

    /// For list handle immediately after construction, if all elements are known-no-`&`
    /// Helper to set sidecar bit. builtin / appended list inside VM
    /// Call immediately after. If known-no does not hold even for 1 element, the bit will not be set.
    /// (= defer to existing lazy walk path).
    pub fn maybeNoteListParentSelNoneFromItems(
        self: *VM,
        handle: u32,
        items: []const Value,
    ) std.mem.Allocator.Error!void {
        for (items) |item| {
            if (!self.valueKnownNoParentSelector(item)) return;
        }
        try self.noteListParentSelNone(handle);
    }

    pub fn hasActiveSelectorContext(self: *const VM) bool {
        return self.selector_stack.items.len > 0 or
            self.at_root_selector_context_depth > 0 or
            self.currentAtRootParentSelector() != null;
    }

    fn makeListValue(
        self: *VM,
        items: []const Value,
        separator: ListSeparator,
        is_bracketed: bool,
    ) VMError!Value {
        const handle: u32 = @intCast(self.list_pool.items.len);
        const owned = try self.arena().alloc(Value, items.len);
        @memcpy(owned, items);
        try self.list_pool.append(self.allocator, owned);
        return Value.listWith(handle, separator, is_bracketed);
    }

    fn selectorTextToValue(self: *VM, selector_text: []const u8) VMError!Value {
        var parsed = selector_mod.parse(self.allocator, selector_text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SassError,
        };
        defer parsed.deinit();

        var outer_items: std.ArrayListUnmanaged(Value) = .empty;
        defer outer_items.deinit(self.allocator);
        try outer_items.ensureTotalCapacity(self.allocator, parsed.selectors.items.len);

        for (parsed.selectors.items) |complex| {
            var inner_items: std.ArrayListUnmanaged(Value) = .empty;
            defer inner_items.deinit(self.allocator);
            try inner_items.ensureTotalCapacity(self.allocator, complex.components.items.len);

            for (complex.components.items) |comp| {
                switch (comp) {
                    .compound => |compound| {
                        const css = try selector_mod.compoundSelectorToCss(self.allocator, &compound);
                        defer self.allocator.free(css);
                        const id = self.intern_pool.intern(css) catch return error.OutOfMemory;
                        try inner_items.append(self.allocator, Value.string(id, false));
                    },
                    .combinator => |comb| {
                        const css_text = std.mem.trim(u8, comb.toCss(), " ");
                        if (css_text.len == 0) continue;
                        const id = self.intern_pool.intern(css_text) catch return error.OutOfMemory;
                        try inner_items.append(self.allocator, Value.string(id, false));
                    },
                }
            }

            const inner = try self.makeListValue(inner_items.items, .space, false);
            try outer_items.append(self.allocator, inner);
        }

        return self.makeListValue(outer_items.items, .comma, false);
    }

    fn valueToDiagnosticMessage(self: *VM, v: Value, comptime prefer_css_decl_render: bool) VMError![]const u8 {
        const msg_id_res = if (prefer_css_decl_render)
            valueToInternIdDecl(self.intern_pool, &self.number_pool, self.allocator, &self.list_pool, self.color_pool, &self.slash_list_preserve, v, false)
        else
            valueToInternIdRaw(self.intern_pool, &self.number_pool, self.allocator, &self.list_pool, self.color_pool, &self.slash_list_preserve, v);

        const msg_id = msg_id_res catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => blk: {
                const fallback = try valueToOpString(self.intern_pool, &self.number_pool, self.allocator, &self.list_pool, self.color_pool, &self.callable_payload_pool, v);
                defer self.allocator.free(fallback);
                break :blk self.intern_pool.intern(fallback) catch return error.OutOfMemory;
            },
        };
        return self.intern_pool.get(msg_id);
    }

    /// When Resolver's `!global` alias slot is not propagated on the VM side, set `nil` callable target.
    /// Complete with unique callables in the current frame. If it's ambiguous, don't complete it.
    fn fallbackCallableFromLocals(self: *const VM, expect_mixin: bool) ?Value {
        if (self.frame_stack.items.len == 0) return null;
        const fr = self.frame_stack.items[self.frame_stack.items.len - 1];
        var found: ?Value = null;
        for (fr.locals) |v| {
            if (v.kind() != .callable) continue;
            if (v.callableIsMixin(&self.callable_payload_pool) != expect_mixin) continue;
            if (found != null) return null;
            found = v;
        }
        return found;
    }

    fn findPlaceholderChunk(self: *VM, module_id: u32, target: InternId) ?u32 {
        if (module_id >= self.program.modules.len) return null;
        const mod = &self.program.modules[module_id];
        for (mod.placeholder_targets, 0..) |id, i| {
            if (id == target) return @intCast(i);
        }
        return null;
    }

    fn doRetValue(self: *VM, v: Value) VMError!StepResult {
        const callee_module_id = self.current_module;
        self.unwindFlowScopesForCurrentFrame();
        const fr = self.frame_stack.pop() orelse return error.InternalError;
        if (fr.auto_close_current_rule_on_return) {
            try self.closeMaybeCurrentRuleBlock();
        }
        self.writeBackFrameGlobals(callee_module_id, fr);
        self.writeBackCapturedLocals(fr);
        self.stack.shrinkRetainingCapacity(fr.save_sp);
        if (self.track_stack_source_spans) self.stack_source_spans.shrinkRetainingCapacity(fr.save_sp);
        if (fr.return_chunk == chunk_run_sentinel) {
            return .{ .exit_run_chunk = v };
        }
        try self.push(v);
        self.pc = fr.return_pc;
        self.current_chunk = decodeChunkRef(fr.return_chunk);
        self.current_module = fr.caller_module_id;
        return .continue_exec;
    }

    fn doRetVoid(self: *VM) VMError!StepResult {
        const callee_module_id = self.current_module;
        self.unwindFlowScopesForCurrentFrame();
        const fr = self.frame_stack.pop() orelse return error.InternalError;
        if (fr.auto_close_current_rule_on_return) {
            try self.closeMaybeCurrentRuleBlock();
        }
        self.writeBackFrameGlobals(callee_module_id, fr);
        self.writeBackCapturedLocals(fr);
        self.stack.shrinkRetainingCapacity(fr.save_sp);
        if (self.track_stack_source_spans) self.stack_source_spans.shrinkRetainingCapacity(fr.save_sp);
        if (fr.return_chunk == chunk_run_sentinel) {
            return .{ .exit_run_chunk = null };
        }
        self.pc = fr.return_pc;
        self.current_chunk = decodeChunkRef(fr.return_chunk);
        self.current_module = fr.caller_module_id;
        return .continue_exec;
    }

    fn writeBackFrameGlobals(self: *VM, module_id: u32, fr: Frame) void {
        if (module_id >= self.program.modules.len) return;
        if (module_id >= self.mod_globals_bufs.len or module_id >= self.mod_global_declared_bufs.len) return;

        const global_count = self.program.modules[module_id].global_slot_count;
        const dst_values = self.mod_globals_bufs[module_id];
        const dst_declared = self.mod_global_declared_bufs[module_id];
        const n: usize = @min(
            @as(usize, @intCast(global_count)),
            @min(@min(dst_values.len, dst_declared.len), @min(fr.locals.len, fr.declared.len)),
        );

        if (n == 0) return;
        const selective = fr.global_writeback.len >= n;
        if (selective and !fr.global_writeback_any) return;
        if (selective) {
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (!fr.global_writeback[i]) continue;
                dst_values[i] = fr.locals[i];
                dst_declared[i] = fr.declared[i];
            }
        } else {
            @memcpy(dst_values[0..n], fr.locals[0..n]);
            @memcpy(dst_declared[0..n], fr.declared[0..n]);
        }

        if (self.frame_stack.items.len == 0) return;
        const caller = &self.frame_stack.items[self.frame_stack.items.len - 1];
        if (fr.caller_module_id != module_id) return;
        var caller_global_limit: usize = n;
        if (fr.return_chunk != chunk_run_sentinel) {
            const caller_chunk = self.getChunk(module_id, decodeChunkRef(fr.return_chunk));
            caller_global_limit = @min(caller_global_limit, caller_chunk.global_slot_base);
        }
        const caller_n: usize = @min(caller_global_limit, @min(caller.locals.len, caller.declared.len));
        if (caller_n == 0) return;
        if (selective) {
            var i: usize = 0;
            while (i < caller_n) : (i += 1) {
                if (!fr.global_writeback[i]) continue;
                caller.locals[i] = fr.locals[i];
                caller.declared[i] = fr.declared[i];
            }
        } else {
            @memcpy(caller.locals[0..caller_n], fr.locals[0..caller_n]);
            @memcpy(caller.declared[0..caller_n], fr.declared[0..caller_n]);
        }
    }

    fn argNameMatches(self: *VM, arg_name: InternId, param_name: InternId) bool {
        if (arg_name == .none or arg_name == call_arg_splat_sentinel or param_name == .none) return false;
        var raw = self.intern_pool.get(arg_name);
        if (raw.len > 0 and raw[0] == '$') raw = raw[1..];
        return identifierEq(raw, self.intern_pool.get(param_name));
    }

    const ExpandedCallArgs = struct {
        args: []Value,
        arg_names: []InternId,
        last_spread_separator: ?ListSeparator = null,
        owned: bool,
    };

    pub fn freeExpandedCallArgs(self: *VM, expanded: ExpandedCallArgs) void {
        if (!expanded.owned) return;
        self.allocator.free(expanded.args);
        self.allocator.free(expanded.arg_names);
    }

    fn validateCallArgOrdering(self: *VM, arg_names: []const InternId) VMError!void {
        _ = self;
        var saw_named = false;
        for (arg_names) |name_id| {
            if (name_id == call_arg_splat_sentinel) continue;
            if (name_id == .none) {
                if (saw_named) return error.BuiltinArity;
                continue;
            }
            saw_named = true;
        }
    }

    pub fn listItemsAt(self: *VM, handle: u32) VMError![]const Value {
        if (handle >= self.list_pool.items.len) return error.InternalError;
        return self.list_pool.items[handle];
    }

    pub fn markSlashListPreserve(self: *VM, value: Value) VMError!void {
        if (value.kind() != .list or !value.listSlash(self.list_meta_pool.items)) return;
        const gop = try self.slash_list_preserve.getOrPut(self.allocator, value.listHandle());
        gop.value_ptr.* = {};
    }

    fn isSlashListPreserved(self: *VM, value: Value) bool {
        if (value.kind() != .list or !value.listSlash(self.list_meta_pool.items)) return false;
        return self.slash_list_preserve.contains(value.listHandle());
    }

    fn coerceSlashFreeValue(self: *VM, value: Value) VMError!Value {
        if (self.isSlashListPreserved(value)) return value;
        return coerceCalcStringToNumberish(self.intern_pool, &self.number_pool, self.allocator, &self.list_pool, value);
    }

    fn coerceSlashFreeValueForUserCallArg(self: *VM, value: Value) VMError!Value {
        if (shouldMarkCalcInterpString(self.intern_pool, value)) {
            const raw = calc_utils.stripCalcArgMarker(self.intern_pool.get(value.stringIntern()));
            if (css_utils.containsCalcFunction(raw)) return value;
        }
        return self.coerceSlashFreeValue(value);
    }

    fn coerceInterpolatedSlashListValue(self: *VM, value: Value) VMError!Value {
        if (self.isSlashListPreserved(value)) return value;
        if (try coerceSlashListToNumberish(self.intern_pool, &self.number_pool, self.allocator, &self.list_pool, value)) |parsed| {
            return parsed;
        }
        return value;
    }

    /// Like `coerceSlashFreeValue` at declaration boundaries, with two official Sass CLI
    /// surface-preservation exceptions:
    /// - selected source slash expressions stay literal when the resolver marks
    ///   the declaration as preserve-slash;
    /// - SassScript-built unquoted calc strings (`calc(#{$x} * 2)`,
    ///   `string.unquote("calc(...)")`) keep their CSS surface when emitted as
    ///   values, while arithmetic paths may still parse them as numberish.
    fn coerceSlashFreeValueForDecl(self: *VM, value: Value, preserve_slash_list: bool) VMError!Value {
        if (preserve_slash_list and value.kind() == .list and value.listSlash(self.list_meta_pool.items)) return value;
        if (shouldMarkCalcInterpString(self.intern_pool, value)) {
            const raw = calc_utils.stripCalcArgMarker(self.intern_pool.get(value.stringIntern()));
            if (css_utils.containsCalcFunction(raw)) return value;
        }
        if (value.kind() == .string and
            !value.stringQuoted(self.string_flags_pool.items) and
            value.stringPreserveLiteralText(self.string_flags_pool.items) and
            css_utils.containsCalcFunction(self.intern_pool.get(value.stringIntern())))
        {
            return value;
        }
        return self.coerceSlashFreeValue(value);
    }

    fn appendKeywordPairsToExpanded(
        self: *VM,
        key_values: []const Value,
        out_args: *std.ArrayListUnmanaged(Value),
        out_names: *std.ArrayListUnmanaged(InternId),
    ) VMError!void {
        if (key_values.len % 2 != 0) return error.BuiltinArity;
        var i: usize = 0;
        while (i + 1 < key_values.len) : (i += 2) {
            const key_v = key_values[i];
            if (key_v.kind() != .string or key_v.stringNamedColorLiteral(self.string_flags_pool.items)) return error.SassError;
            try out_args.append(self.allocator, key_values[i + 1]);
            try out_names.append(self.allocator, key_v.stringIntern());
        }
    }

    pub fn lookupArglistKeywordHandle(self: *const VM, positional_list_handle: u32) ?u32 {
        return self.arglist_keyword_lists.get(positional_list_handle);
    }

    fn setArglistKeywordHandle(self: *VM, positional_list_handle: u32, keyword_list_handle: u32) VMError!void {
        const gop = try self.arglist_keyword_lists.getOrPut(self.allocator, positional_list_handle);
        gop.value_ptr.* = keyword_list_handle;
    }

    fn expandCallArgsWithSplat(self: *VM, args: []const Value, arg_names: []const InternId) VMError!ExpandedCallArgs {
        if (arg_names.len != args.len) return error.InternalError;

        var has_splat = false;
        for (arg_names) |name_id| {
            if (name_id == call_arg_splat_sentinel) {
                has_splat = true;
                break;
            }
        }
        if (!has_splat) {
            return .{
                .args = @constCast(args),
                .arg_names = @constCast(arg_names),
                .last_spread_separator = null,
                .owned = false,
            };
        }

        var out_args: std.ArrayListUnmanaged(Value) = .empty;
        errdefer out_args.deinit(self.allocator);
        var out_names: std.ArrayListUnmanaged(InternId) = .empty;
        errdefer out_names.deinit(self.allocator);
        var last_spread_separator: ?ListSeparator = null;

        var saw_rest = false;
        for (args, arg_names) |arg, name_id| {
            if (name_id == call_arg_splat_sentinel) {
                saw_rest = true;
                continue;
            }
            if (!saw_rest or name_id != .none) continue;
            try out_args.append(self.allocator, arg);
            try out_names.append(self.allocator, .none);
        }

        saw_rest = false;
        for (args, arg_names) |arg, name_id| {
            if (name_id != call_arg_splat_sentinel) {
                if (saw_rest) {
                    if (name_id != .none) {
                        try out_args.append(self.allocator, arg);
                        try out_names.append(self.allocator, name_id);
                    }
                    continue;
                }
                try out_args.append(self.allocator, arg);
                try out_names.append(self.allocator, name_id);
                continue;
            }

            saw_rest = true;
            if (arg.kind() == .list) {
                last_spread_separator = arg.listSeparator(self.list_meta_pool.items);
                const list_handle = arg.listHandle();
                const items = try self.listItemsAt(list_handle);
                if (self.lookupArglistKeywordHandle(list_handle)) |kw_handle| {
                    try out_args.ensureUnusedCapacity(self.allocator, items.len);
                    try out_names.ensureUnusedCapacity(self.allocator, items.len);
                    for (items) |item| {
                        out_args.appendAssumeCapacity(item);
                        out_names.appendAssumeCapacity(.none);
                    }
                    const kw_items = try self.listItemsAt(kw_handle);
                    try self.appendKeywordPairsToExpanded(kw_items, &out_args, &out_names);
                } else if (arg.listIsMap(self.list_meta_pool.items)) {
                    try self.appendKeywordPairsToExpanded(items, &out_args, &out_names);
                } else {
                    try out_args.ensureUnusedCapacity(self.allocator, items.len);
                    try out_names.ensureUnusedCapacity(self.allocator, items.len);
                    for (items) |item| {
                        out_args.appendAssumeCapacity(item);
                        out_names.appendAssumeCapacity(.none);
                    }
                }
            } else {
                try out_args.append(self.allocator, arg);
                try out_names.append(self.allocator, .none);
            }
        }

        return .{
            .args = try out_args.toOwnedSlice(self.allocator),
            .arg_names = try out_names.toOwnedSlice(self.allocator),
            .last_spread_separator = last_spread_separator,
            .owned = true,
        };
    }

    fn maybeSerializeIndirectBuiltinColor(self: *VM, call_name: []const u8, result: Value) VMError!Value {
        return vm_dispatch.maybeSerializeIndirectBuiltinColor(self, call_name, result);
    }

    fn maybeSerializeDirectBuiltinColorWithSplat(self: *VM, builtin_id: u32, had_splat: bool, result: Value) VMError!Value {
        if (!had_splat) return result;
        const call_name = builtin_mod.debugNameById(builtin_id) orelse return result;
        return try self.maybeSerializeIndirectBuiltinColor(call_name, result);
    }

    pub fn expandMetaApplyImplicitSplatArgs(self: *VM, args: []const Value, arg_names: []const InternId) VMError!ExpandedCallArgs {
        if (args.len != 1) {
            return .{ .args = @constCast(args), .arg_names = @constCast(arg_names), .last_spread_separator = null, .owned = false };
        }
        if (arg_names.len > 1) return error.InternalError;
        if (arg_names.len == 1 and arg_names[0] != .none) {
            return .{ .args = @constCast(args), .arg_names = @constCast(arg_names), .last_spread_separator = null, .owned = false };
        }

        const arg = args[0];
        if (arg.kind() != .list) {
            return .{ .args = @constCast(args), .arg_names = @constCast(arg_names), .last_spread_separator = null, .owned = false };
        }
        const items = try self.listItemsAt(arg.listHandle());

        var out_args: std.ArrayListUnmanaged(Value) = .empty;
        errdefer out_args.deinit(self.allocator);
        var out_names: std.ArrayListUnmanaged(InternId) = .empty;
        errdefer out_names.deinit(self.allocator);

        if (arg.listIsMap(self.list_meta_pool.items)) {
            try self.appendKeywordPairsToExpanded(items, &out_args, &out_names);
        } else {
            try out_args.ensureUnusedCapacity(self.allocator, items.len);
            try out_names.ensureUnusedCapacity(self.allocator, items.len);
            for (items) |item| {
                out_args.appendAssumeCapacity(item);
                out_names.appendAssumeCapacity(.none);
            }
        }

        return .{
            .args = try out_args.toOwnedSlice(self.allocator),
            .arg_names = try out_names.toOwnedSlice(self.allocator),
            .last_spread_separator = arg.listSeparator(self.list_meta_pool.items),
            .owned = true,
        };
    }

    fn internNormalizedKeywordName(self: *VM, name_id: InternId) VMError!InternId {
        var raw = self.intern_pool.get(name_id);
        if (raw.len > 0 and raw[0] == '$') raw = raw[1..];
        var needs_normalize = false;
        for (raw) |c| {
            if (c == '_') {
                needs_normalize = true;
                break;
            }
        }
        if (!needs_normalize) return name_id;

        const buf = try self.allocator.alloc(u8, raw.len);
        defer self.allocator.free(buf);
        for (raw, 0..) |c, i| {
            buf[i] = if (c == '_') '-' else c;
        }
        return self.intern_pool.intern(buf) catch return error.OutOfMemory;
    }

    fn buildRestListValue(self: *VM, rest_items: []const Value, separator: ?ListSeparator) VMError!Value {
        const owned = try self.arena().alloc(Value, rest_items.len);
        if (rest_items.len > 0) @memcpy(owned, rest_items);
        const h: u32 = @intCast(self.list_pool.items.len);
        try self.list_pool.append(self.allocator, owned);
        // The rest positional of `$args...` is always treated as a list.
        // Even if the first element is a string and has an even length, it will not be converted to a map (handled as a map by the keywords() side)
        // Determine using arglist keyword handle).
        return Value.listWithMeta(h, separator orelse .comma, false, false);
    }

    fn buildKeywordMapListValue(self: *VM, key_values: []const Value) VMError!Value {
        if (key_values.len % 2 != 0) return error.InternalError;
        const owned = try self.arena().alloc(Value, key_values.len);
        if (key_values.len > 0) @memcpy(owned, key_values);
        const h: u32 = @intCast(self.list_pool.items.len);
        try self.list_pool.append(self.allocator, owned);
        return Value.listWithMeta(h, .comma, false, true);
    }

    const CallLocals = struct {
        values: []Value,
        declared: []bool,
    };

    fn allocateCallLocals(
        self: *VM,
        target_module: u32,
        target: ChunkRef,
        caller_mod: u32,
        capture_callers_locals: bool,
    ) VMError!CallLocals {
        const callee = self.getChunk(target_module, target);
        const locals = try self.arena().alloc(Value, callee.local_count);
        const declared = try self.arena().alloc(bool, callee.local_count);

        const mod = self.program.modules[target_module];
        if (caller_mod == target_module and self.frame_stack.items.len > 0) {
            const caller_fr = &self.frame_stack.items[self.frame_stack.items.len - 1];
            if (capture_callers_locals) {
                const copy_n: usize = @min(callee.local_count, caller_fr.locals.len);
                if (copy_n > 0) @memcpy(locals[0..copy_n], caller_fr.locals[0..copy_n]);
                if (copy_n < locals.len) @memset(locals[copy_n..], Value.nil_v);

                const declared_n: usize = @min(callee.local_count, caller_fr.declared.len);
                if (declared_n > 0) @memcpy(declared[0..declared_n], caller_fr.declared[0..declared_n]);
                if (declared_n < declared.len) @memset(declared[declared_n..], false);
            } else {
                const global_n: usize = @min(@as(usize, @intCast(mod.global_slot_count)), callee.local_count);
                const copy_n: usize = @min(global_n, caller_fr.locals.len);
                if (copy_n > 0) @memcpy(locals[0..copy_n], caller_fr.locals[0..copy_n]);
                if (copy_n < locals.len) @memset(locals[copy_n..], Value.nil_v);

                const declared_n: usize = @min(global_n, caller_fr.declared.len);
                if (declared_n > 0) @memcpy(declared[0..declared_n], caller_fr.declared[0..declared_n]);
                if (declared_n < declared.len) @memset(declared[declared_n..], false);
            }
        } else if (self.mod_globals_bufs.len > target_module and self.mod_global_declared_bufs.len > target_module) {
            const mg = self.mod_globals_bufs[target_module];
            const md = self.mod_global_declared_bufs[target_module];
            const global_n: usize = @min(@as(usize, @intCast(mod.global_slot_count)), callee.local_count);
            const copy_n: usize = @min(global_n, mg.len);
            if (copy_n > 0) @memcpy(locals[0..copy_n], mg[0..copy_n]);
            if (copy_n < locals.len) @memset(locals[copy_n..], Value.nil_v);

            const declared_n: usize = @min(global_n, md.len);
            if (declared_n > 0) @memcpy(declared[0..declared_n], md[0..declared_n]);
            if (declared_n < declared.len) @memset(declared[declared_n..], false);
        } else {
            @memset(locals, Value.nil_v);
            @memset(declared, false);
        }
        return .{
            .values = locals,
            .declared = declared,
        };
    }

    fn resolveParamDefaultOperand(self: *VM, operand: Chunk.ParamDefaultBinaryOperand, locals: []const Value) VMError!Value {
        return switch (operand) {
            .value => |v| v,
            .local_slot => |slot| blk: {
                if (slot >= locals.len) return error.InternalError;
                break :blk locals[slot];
            },
            .cross_slot => |target| blk: {
                if (target.module_id >= self.mod_globals_bufs.len) return error.InternalError;
                const row = self.mod_globals_bufs[target.module_id];
                if (target.slot >= row.len) return error.InternalError;
                break :blk row[target.slot];
            },
        };
    }

    fn evalParamDefaultAtomExpr(self: *VM, spec: Chunk.ParamDefaultAtomExpr, locals: []const Value) VMError!Value {
        return switch (spec) {
            .value => |v| v,
            .local_slot => |slot| blk: {
                if (slot >= locals.len) return error.InternalError;
                break :blk locals[slot];
            },
            .cross_slot => |target| blk: {
                if (target.module_id >= self.mod_globals_bufs.len) return error.InternalError;
                const row = self.mod_globals_bufs[target.module_id];
                if (target.slot >= row.len) return error.InternalError;
                break :blk row[target.slot];
            },
            .binary => |binary| blk: {
                const raw_lhs = try self.resolveParamDefaultOperand(binary.lhs, locals);
                const raw_rhs = try self.resolveParamDefaultOperand(binary.rhs, locals);
                break :blk switch (binary.op) {
                    .add => try addValues(self.intern_pool, &self.number_pool, self.allocator, &self.list_pool, self.color_pool, &self.callable_payload_pool, raw_lhs, raw_rhs, false),
                    .sub => try subValues(self.intern_pool, &self.number_pool, self.allocator, &self.list_pool, self.color_pool, &self.slash_list_preserve, raw_lhs, raw_rhs, false),
                    .mul => try mulValues(self.intern_pool, &self.number_pool, self.allocator, &self.list_pool, self.color_pool, &self.slash_list_preserve, raw_lhs, raw_rhs, false),
                    .div => try divValues(self.intern_pool, &self.number_pool, self.allocator, &self.list_pool, self.color_pool, &self.slash_list_preserve, raw_lhs, raw_rhs, false, null),
                    .mod => try modValues(self.intern_pool, &self.number_pool, self.allocator, &self.list_pool, self.color_pool, &self.slash_list_preserve, raw_lhs, raw_rhs),
                    .eq, .neq, .lt, .gt, .le, .ge => cmp: {
                        const lhs = try self.coerceSlashFreeValue(raw_lhs);
                        const rhs = try self.coerceSlashFreeValue(raw_rhs);
                        const ok: bool = switch (binary.op) {
                            .eq => valueEq(self.intern_pool, &self.number_pool, &self.list_meta_pool, &self.string_flags_pool, &self.callable_payload_pool, self.allocator, self.color_pool, &self.list_pool, lhs, rhs),
                            .neq => !valueEq(self.intern_pool, &self.number_pool, &self.list_meta_pool, &self.string_flags_pool, &self.callable_payload_pool, self.allocator, self.color_pool, &self.list_pool, lhs, rhs),
                            .lt, .gt, .le, .ge => ord: {
                                if (lhs.kind() != .number or rhs.kind() != .number) return error.SassError;
                                const pair = try comparableNumbers(self.intern_pool, &self.number_pool, self.allocator, lhs, rhs);
                                const ord = fuzzyNumberOrder(pair.a, pair.b);
                                break :ord switch (binary.op) {
                                    .lt => ord == .lt,
                                    .gt => ord == .gt,
                                    .le => ord == .lt or ord == .eq,
                                    .ge => ord == .gt or ord == .eq,
                                    else => unreachable,
                                };
                            },
                            else => unreachable,
                        };
                        break :cmp if (ok) Value.true_v else Value.false_v;
                    },
                    else => return error.InternalError,
                };
            },
            .unary => |unary| blk: {
                const raw = try self.resolveParamDefaultOperand(unary.operand, locals);
                const value = try self.coerceSlashFreeValue(raw);
                break :blk switch (unary.op) {
                    .neg => if (value.kind() == .number)
                        try Value.number(-value.asF64(&self.number_pool), value.unitId(&self.number_pool), &self.number_pool, self.allocator)
                    else
                        try unaryPrefixValue(self, "-", value, .require_non_calc),
                    .pos => if (value.kind() == .number)
                        value
                    else
                        try unaryPrefixValue(self, "+", value, .require_non_calc),
                    .slash_prefix => try unaryPrefixValue(self, "/", value, .allow_calc),
                    .not_op => if (value.isTruthy()) Value.false_v else Value.true_v,
                };
            },
        };
    }

    fn evalParamDefaultInterp(self: *VM, ip: Chunk.ParamDefaultInterp, locals: []const Value) VMError!Value {
        var acc: std.ArrayListUnmanaged(u8) = .empty;
        defer acc.deinit(self.allocator);
        var i: usize = 0;
        while (i < ip.part_count) : (i += 1) {
            const raw = try self.evalParamDefaultAtomExpr(ip.parts[i], locals);
            if (raw.kind() == .nil) continue;
            const coerced = try self.coerceSlashFreeValue(raw);
            const id = try valueToInternIdRaw(
                self.intern_pool,
                &self.number_pool,
                self.allocator,
                &self.list_pool,
                self.color_pool,
                &self.slash_list_preserve,
                coerced,
            );
            const s = self.intern_pool.get(id);
            if (s.len == 0) continue;
            try acc.appendSlice(self.allocator, s);
        }
        const dup = try self.allocator.dupe(u8, acc.items);
        defer self.allocator.free(dup);
        const normalized = try css_utils.normalizeInterpolatedEscapedHyphens(self.allocator, dup);
        defer if (normalized.ptr != dup.ptr) self.allocator.free(@constCast(normalized));
        const merged = try self.intern_pool.intern(normalized);
        return Value.string(merged, ip.preserve_quote);
    }

    fn evalParamDefaultExpr(self: *VM, spec: Chunk.ParamDefaultExpr, locals: []const Value) VMError!Value {
        return switch (spec) {
            .value => |v| v,
            .local_slot => |slot| blk: {
                if (slot >= locals.len) return error.InternalError;
                break :blk locals[slot];
            },
            .cross_slot => |target| blk: {
                if (target.module_id >= self.mod_globals_bufs.len) return error.InternalError;
                const row = self.mod_globals_bufs[target.module_id];
                if (target.slot >= row.len) return error.InternalError;
                break :blk row[target.slot];
            },
            .binary => |binary| try self.evalParamDefaultAtomExpr(.{ .binary = binary }, locals),
            .unary => |unary| try self.evalParamDefaultAtomExpr(.{ .unary = unary }, locals),
            .interp => |ip| try self.evalParamDefaultInterp(ip, locals),
            .builtin_call => |call| blk: {
                const argc: usize = @intCast(call.argc);
                var args_buf: [Chunk.max_param_default_call_args]Value = undefined;
                var arg_names_buf: [Chunk.max_param_default_call_args]InternId = undefined;
                var any_named = false;

                var i: usize = 0;
                while (i < argc) : (i += 1) {
                    args_buf[i] = try self.evalParamDefaultAtomExpr(call.args[i], locals);
                    const name_id = call.arg_names[i];
                    arg_names_buf[i] = name_id;
                    if (name_id != .none) any_named = true;
                }

                const arg_names = if (any_named) arg_names_buf[0..argc] else &.{};
                if (arg_names.len != 0) try self.validateCallArgOrdering(arg_names);
                break :blk try self.dispatchBuiltinArgs(call.builtin_id, args_buf[0..argc], arg_names);
            },
            .call => |call| blk: {
                const argc: usize = @intCast(call.argc);
                var args_buf: [Chunk.max_param_default_call_args]Value = undefined;
                var arg_names_buf: [Chunk.max_param_default_call_args]InternId = undefined;
                var any_named = false;

                var i: usize = 0;
                while (i < argc) : (i += 1) {
                    args_buf[i] = try self.evalParamDefaultAtomExpr(call.args[i], locals);
                    const name_id = call.arg_names[i];
                    arg_names_buf[i] = name_id;
                    if (name_id != .none) any_named = true;
                }

                const arg_names = if (any_named) arg_names_buf[0..argc] else &.{};
                if (arg_names.len != 0) try self.validateCallArgOrdering(arg_names);

                const target = if (call.callee_is_css)
                    try Value.callableMake(
                        0,
                        value_mod.callable_flag_is_css,
                        0,
                        call.callee_name,
                        &self.callable_payload_pool,
                        self.allocator,
                    )
                else
                    try Value.callableMake(
                        call.callee_id,
                        value_mod.callable_flag_has_module,
                        @truncate(call.callee_module),
                        call.callee_name,
                        &self.callable_payload_pool,
                        self.allocator,
                    );

                break :blk try self.invokeCallableFromBuiltinSync(false, target, args_buf[0..argc], arg_names);
            },
        };
    }

    fn evalParamDefaultIfBuiltin(self: *VM, if_builtin: Chunk.ParamDefaultIfBuiltin, locals: []const Value) VMError!Value {
        const condition = try self.evalParamDefaultExpr(if_builtin.condition, locals);
        return if (condition.isTruthy())
            try self.evalParamDefaultExpr(if_builtin.if_true, locals)
        else
            try self.evalParamDefaultExpr(if_builtin.if_false, locals);
    }

    fn evalParamDefault(self: *VM, spec: Chunk.ParamDefault, locals: []const Value) VMError!?Value {
        return switch (spec) {
            .none => null,
            .value => |v| v,
            .local_slot => |slot| blk: {
                if (slot >= locals.len) return error.InternalError;
                break :blk locals[slot];
            },
            .cross_slot => |target| blk: {
                if (target.module_id >= self.mod_globals_bufs.len) return error.InternalError;
                const row = self.mod_globals_bufs[target.module_id];
                if (target.slot >= row.len) return error.InternalError;
                break :blk row[target.slot];
            },
            .binary => |binary| try self.evalParamDefaultAtomExpr(.{ .binary = binary }, locals),
            .unary => |unary| try self.evalParamDefaultAtomExpr(.{ .unary = unary }, locals),
            .interp => |ip| try self.evalParamDefaultInterp(ip, locals),
            .list => |l| blk: {
                var items_buf: [Chunk.max_param_default_list_items]Value = undefined;
                var i: usize = 0;
                while (i < l.elem_count) : (i += 1) {
                    items_buf[i] = switch (l.elems[i]) {
                        .expr => |expr| try self.evalParamDefaultExpr(expr, locals),
                        .if_builtin => |if_builtin| try self.evalParamDefaultIfBuiltin(if_builtin, locals),
                    };
                }
                const handle: u32 = @intCast(self.list_pool.items.len);
                const owned = try self.arena().alloc(Value, l.elem_count);
                if (l.elem_count > 0) @memcpy(owned, items_buf[0..l.elem_count]);
                try self.list_pool.append(self.allocator, owned);
                break :blk Value.listWithMetaEx(handle, l.separator, l.bracketed, l.is_map, false);
            },
            .if_builtin => |if_builtin| try self.evalParamDefaultIfBuiltin(if_builtin, locals),
            .builtin_call => |call| blk: {
                const argc: usize = @intCast(call.argc);
                var args_buf: [Chunk.max_param_default_call_args]Value = undefined;
                var arg_names_buf: [Chunk.max_param_default_call_args]InternId = undefined;
                var any_named = false;

                var i: usize = 0;
                while (i < argc) : (i += 1) {
                    args_buf[i] = try self.evalParamDefaultExpr(call.args[i], locals);
                    const name_id = call.arg_names[i];
                    arg_names_buf[i] = name_id;
                    if (name_id != .none) any_named = true;
                }

                const arg_names = if (any_named) arg_names_buf[0..argc] else &.{};
                if (arg_names.len != 0) try self.validateCallArgOrdering(arg_names);
                break :blk try self.dispatchBuiltinArgs(call.builtin_id, args_buf[0..argc], arg_names);
            },
            .call => |call| blk: {
                const argc: usize = @intCast(call.argc);
                var args_buf: [Chunk.max_param_default_call_args]Value = undefined;
                var arg_names_buf: [Chunk.max_param_default_call_args]InternId = undefined;
                var any_named = false;

                var i: usize = 0;
                while (i < argc) : (i += 1) {
                    args_buf[i] = try self.evalParamDefaultExpr(call.args[i], locals);
                    const name_id = call.arg_names[i];
                    arg_names_buf[i] = name_id;
                    if (name_id != .none) any_named = true;
                }

                const arg_names = if (any_named) arg_names_buf[0..argc] else &.{};
                if (arg_names.len != 0) try self.validateCallArgOrdering(arg_names);

                const target = if (call.callee_is_css)
                    try Value.callableMake(
                        0,
                        value_mod.callable_flag_is_css,
                        0,
                        call.callee_name,
                        &self.callable_payload_pool,
                        self.allocator,
                    )
                else
                    try Value.callableMake(
                        call.callee_id,
                        value_mod.callable_flag_has_module,
                        @truncate(call.callee_module),
                        call.callee_name,
                        &self.callable_payload_pool,
                        self.allocator,
                    );

                break :blk try self.invokeCallableFromBuiltinSync(false, target, args_buf[0..argc], arg_names);
            },
        };
    }

    fn bindCallableArgs(
        self: *VM,
        callee: *const Chunk,
        locals: []Value,
        declared: []bool,
        args: []const Value,
        arg_names: []const InternId,
        rest_separator_override: ?ListSeparator,
    ) VMError!void {
        if (arg_names.len != 0 and arg_names.len != args.len) return error.InternalError;
        if (declared.len < locals.len) return error.InternalError;

        const arg_base: usize = callee.arg_base;
        if (arg_base + callee.argc > callee.local_count) return error.InternalError;
        const has_rest = callee.has_rest and callee.argc > 0;
        const fixed_argc: usize = if (has_rest) callee.argc - 1 else callee.argc;
        if (!has_rest and args.len > fixed_argc) {
            return setTooManyArgumentsError(fixed_argc, args.len);
        }
        if (arg_names.len != 0 and callee.param_names.len != callee.argc) return error.InternalError;

        var bound_buf: [64]bool = undefined;
        const bound = if (fixed_argc <= bound_buf.len)
            bound_buf[0..fixed_argc]
        else
            try self.allocator.alloc(bool, fixed_argc);
        defer if (fixed_argc > bound_buf.len) self.allocator.free(bound);
        @memset(bound, false);
        var rest_positional: std.ArrayListUnmanaged(Value) = .empty;
        defer rest_positional.deinit(self.allocator);
        var rest_keywords: std.ArrayListUnmanaged(Value) = .empty;
        defer rest_keywords.deinit(self.allocator);
        if (has_rest) {
            try rest_positional.ensureTotalCapacity(self.allocator, args.len);
            try rest_keywords.ensureTotalCapacity(self.allocator, args.len * 2);
        }

        var next_pos: usize = 0;
        for (args, 0..) |arg, i| {
            const name_id = if (arg_names.len == 0) InternId.none else arg_names[i];
            if (name_id == .none) {
                while (next_pos < fixed_argc and bound[next_pos]) : (next_pos += 1) {}
                if (next_pos < fixed_argc) {
                    locals[arg_base + next_pos] = arg;
                    declared[arg_base + next_pos] = true;
                    bound[next_pos] = true;
                    next_pos += 1;
                } else if (has_rest) {
                    try rest_positional.append(self.allocator, arg);
                } else {
                    return setTooManyArgumentsError(fixed_argc, args.len);
                }
                continue;
            }

            var matched: ?usize = null;
            var param_idx: usize = 0;
            while (param_idx < fixed_argc) : (param_idx += 1) {
                const param_name = callee.param_names[param_idx];
                if (self.argNameMatches(name_id, param_name)) {
                    matched = param_idx;
                    break;
                }
            }
            if (matched) |slot_idx| {
                if (bound[slot_idx]) {
                    error_format.setContextMessage("Duplicate argument.");
                    return error.BuiltinArity;
                }
                locals[arg_base + slot_idx] = arg;
                declared[arg_base + slot_idx] = true;
                bound[slot_idx] = true;
                continue;
            }
            if (!has_rest) {
                const raw_name = self.intern_pool.get(name_id);
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "No parameter named ${s}.", .{raw_name}) catch return error.BuiltinArity;
                error_format.setContextMessage(msg);
                return error.BuiltinArity;
            }
            const norm_name = try self.internNormalizedKeywordName(name_id);
            try rest_keywords.append(self.allocator, Value.string(norm_name, false));
            try rest_keywords.append(self.allocator, arg);
        }

        var pi: usize = 0;
        while (pi < fixed_argc) : (pi += 1) {
            if (bound[pi]) continue;
            if (callee.param_defaults.len == callee.argc) {
                if (try self.evalParamDefault(callee.param_defaults[pi], locals)) |dv| {
                    locals[arg_base + pi] = dv;
                    declared[arg_base + pi] = true;
                    continue;
                }
            }
            const param_name = self.intern_pool.get(callee.param_names[pi]);
            return setMissingNamedArgumentError(param_name);
        }

        if (has_rest) {
            const rest_val = try self.buildRestListValue(rest_positional.items, rest_separator_override);
            locals[arg_base + fixed_argc] = rest_val;
            declared[arg_base + fixed_argc] = true;
            // So that keywords() can determine whether it is an arglist or not,
            //Always record positional-handle -> map-handle even if keyword is empty.
            const kw_val = try self.buildKeywordMapListValue(rest_keywords.items);
            try self.setArglistKeywordHandle(rest_val.listHandle(), kw_val.listHandle());
        }
    }

    fn setTooManyArgumentsError(expected: usize, got: usize) VMError {
        var buf: [128]u8 = undefined;
        const msg = error_format.formatTooManyArguments(&buf, expected, got) catch return error.BuiltinArity;
        error_format.setContextMessage(msg);
        return error.BuiltinArity;
    }

    fn setMissingNamedArgumentError(param_name: []const u8) VMError {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Missing argument ${s}.", .{param_name}) catch return error.BuiltinArity;
        error_format.setContextMessage(msg);
        return error.BuiltinArity;
    }

    pub fn doCallPrepared(
        self: *VM,
        target_module: u32,
        target: ChunkRef,
        args: []const Value,
        arg_names: []const InternId,
        rest_separator_override: ?ListSeparator,
        capture_callers_locals: bool,
    ) VMError!void {
        if (self.frame_stack.items.len >= max_frames) return error.FrameOverflow;

        const callee = self.getChunk(target_module, target);
        const caller_mod = self.current_module;
        const save_sp: u32 = @intCast(self.stack.items.len);
        const ret_pc = self.pc;
        const ret_enc = encodeChunkRef(self.current_chunk);
        const local_frame = try self.allocateCallLocals(target_module, target, caller_mod, capture_callers_locals);
        const locals = local_frame.values;
        const declared = local_frame.declared;
        const global_writeback = try self.allocateGlobalWriteback(target_module, callee.local_count);
        try self.bindCallableArgs(callee, locals, declared, args, arg_names, rest_separator_override);
        const has_pending_content = self.pending_content_chunk != content_none_sentinel;
        if (has_pending_content and switch (target) {
            .mixin => !callee.has_content,
            else => false,
        }) return error.BuiltinUnsupported;
        const attach_content = switch (target) {
            .mixin => has_pending_content,
            else => false,
        };
        const parent_content = if (self.frame_stack.items.len > 0)
            self.frame_stack.items[self.frame_stack.items.len - 1]
        else
            null;
        try self.frame_stack.append(self.allocator, .{
            .locals = locals,
            .declared = declared,
            .global_writeback = global_writeback,
            .return_pc = ret_pc,
            .return_chunk = ret_enc,
            .save_sp = save_sp,
            .caller_module_id = caller_mod,
            .content_module_id = if (attach_content) self.pending_content_module else content_none_sentinel,
            .content_chunk_id = if (attach_content) self.pending_content_chunk else content_none_sentinel,
            .content_capture_locals = if (attach_content) self.pending_content_capture else &.{},
            .content_capture_declared = if (attach_content) self.pending_content_capture_declared else &.{},
            .content_parent_module_id = if (attach_content) if (parent_content) |fr| fr.content_module_id else content_none_sentinel else content_none_sentinel,
            .content_parent_chunk_id = if (attach_content) if (parent_content) |fr| fr.content_chunk_id else content_none_sentinel else content_none_sentinel,
            .content_parent_capture_locals = if (attach_content) if (parent_content) |fr| fr.content_capture_locals else &.{} else &.{},
            .content_parent_capture_declared = if (attach_content) if (parent_content) |fr| fr.content_capture_declared else &.{} else &.{},
        });
        if (attach_content) {
            self.pending_content_module = content_none_sentinel;
            self.pending_content_chunk = content_none_sentinel;
            self.pending_content_capture = &.{};
            self.pending_content_capture_declared = &.{};
        }

        self.current_module = target_module;
        self.current_chunk = target;
        self.pc = 0;
    }

    fn doCall(self: *VM, target_module: u32, target: ChunkRef, argc: u32) VMError!void {
        const argc_usize: usize = @intCast(argc);
        var args_buf: [64]Value = undefined;
        const args = if (argc_usize <= args_buf.len)
            args_buf[0..argc_usize]
        else
            try self.allocator.alloc(Value, argc_usize);
        defer if (argc_usize > args_buf.len) self.allocator.free(args);
        var i: u32 = argc;
        while (i > 0) {
            i -= 1;
            const resolved = try self.maybeResolveParentSelectorValue(try self.pop());
            args[@intCast(i)] = try self.coerceSlashFreeValueForUserCallArg(resolved);
        }
        return self.doCallPrepared(target_module, target, args, &.{}, null, false);
    }

    fn contentBindingFromFrame(fr: Frame) ContentBinding {
        return .{
            .module_id = fr.content_module_id,
            .chunk_id = fr.content_chunk_id,
            .capture_locals = fr.content_capture_locals,
            .capture_declared = fr.content_capture_declared,
        };
    }

    fn contentParentBindingFromFrame(fr: Frame) ContentBinding {
        return .{
            .module_id = fr.content_parent_module_id,
            .chunk_id = fr.content_parent_chunk_id,
            .capture_locals = fr.content_parent_capture_locals,
            .capture_declared = fr.content_parent_capture_declared,
        };
    }

    fn contentBindingEq(a: ContentBinding, b: ContentBinding) bool {
        return a.module_id == b.module_id and
            a.chunk_id == b.chunk_id and
            a.capture_locals.ptr == b.capture_locals.ptr and
            a.capture_locals.len == b.capture_locals.len and
            a.capture_declared.ptr == b.capture_declared.ptr and
            a.capture_declared.len == b.capture_declared.len;
    }

    fn resolveParentContentBinding(self: *VM, child_binding: ContentBinding) ContentBinding {
        if (child_binding.chunk_id == content_none_sentinel) return .{};

        var i: usize = self.frame_stack.items.len;
        while (i > 0) {
            i -= 1;
            const fr = self.frame_stack.items[i];
            if (!contentBindingEq(contentBindingFromFrame(fr), child_binding)) continue;
            return contentParentBindingFromFrame(fr);
        }
        return .{};
    }

    fn writeBackCapturedLocals(self: *VM, fr: Frame) void {
        if (fr.content_writeback_locals.len == 0 or fr.locals.len == 0) return;
        const callee = switch (self.current_chunk) {
            .content => self.getChunk(self.current_module, self.current_chunk),
            else => {
                const n: usize = @min(fr.content_writeback_locals.len, fr.locals.len);
                if (n == 0) return;
                @memcpy(fr.content_writeback_locals[0..n], fr.locals[0..n]);
                if (fr.content_writeback_declared.len == 0 or fr.declared.len == 0) return;
                const dn: usize = @min(fr.content_writeback_declared.len, fr.declared.len);
                if (dn == 0) return;
                @memcpy(fr.content_writeback_declared[0..dn], fr.declared[0..dn]);
                return;
            },
        };
        if (self.current_module >= self.program.modules.len) return;

        const mod = &self.program.modules[self.current_module];
        const shift_base: usize = @intCast(callee.global_slot_base);
        const shift_bias: usize = if (mod.global_slot_count > callee.global_slot_base)
            @intCast(mod.global_slot_count - callee.global_slot_base)
        else
            0;

        // When the content callee uses a remapped global prefix but its frame
        // is no larger than the capture frame, shifted whole-frame writeback
        // would alias loop temporaries backwards (for example callee slot 156
        // into capture slot 154).  Content bodies that only read captured loop
        // locals must not mutate the caller's iterator/list slots, so leave the
        // capture frame untouched in this layout.  Same-size assignment
        // writeback needs dirty-slot tracking rather than blind frame copy.
        if (shift_bias != 0 and fr.content_writeback_locals.len >= fr.locals.len) {
            return;
        }

        if (shift_bias == 0) {
            const n: usize = @min(fr.content_writeback_locals.len, fr.locals.len);
            if (n == 0) return;
            @memcpy(fr.content_writeback_locals[0..n], fr.locals[0..n]);
            if (fr.content_writeback_declared.len == 0 or fr.declared.len == 0) return;
            const dn: usize = @min(fr.content_writeback_declared.len, fr.declared.len);
            if (dn == 0) return;
            @memcpy(fr.content_writeback_declared[0..dn], fr.declared[0..dn]);
            return;
        }

        const same_n: usize = @min(shift_base, @min(fr.content_writeback_locals.len, fr.locals.len));
        if (same_n > 0) {
            @memcpy(fr.content_writeback_locals[0..same_n], fr.locals[0..same_n]);
        }

        var src: usize = shift_base;
        while (src < fr.content_writeback_locals.len) : (src += 1) {
            const shifted_src = src + shift_bias;
            if (shifted_src < fr.locals.len) {
                fr.content_writeback_locals[src] = fr.locals[shifted_src];
            } else {
                break;
            }
        }

        if (fr.content_writeback_declared.len == 0 or fr.declared.len == 0) return;
        const same_decl_n: usize = @min(shift_base, @min(fr.content_writeback_declared.len, fr.declared.len));
        if (same_decl_n > 0) {
            @memcpy(fr.content_writeback_declared[0..same_decl_n], fr.declared[0..same_decl_n]);
        }
        src = shift_base;
        while (src < fr.content_writeback_declared.len) : (src += 1) {
            const shifted_src = src + shift_bias;
            if (shifted_src < fr.declared.len) {
                fr.content_writeback_declared[src] = fr.declared[shifted_src];
            } else {
                break;
            }
        }
    }

    fn copyCapturedContentLocals(
        self: *VM,
        target_module: u32,
        callee: *const Chunk,
        capture_locals: []const Value,
        capture_declared: []const bool,
        locals: []Value,
        declared: []bool,
        allow_direct_overflow_fallback: bool,
    ) void {
        if (capture_locals.len == 0 or locals.len == 0) return;

        // Callable/content bytecode may remap caller-local slots upward when the
        // module accumulates additional globals after the callable was resolved.
        // `global_slot_base` marks the first slot that participated in that remap.
        const shift_base: usize = @intCast(callee.global_slot_base);
        const shift_bias: usize = if (target_module < self.program.modules.len and self.program.modules[target_module].global_slot_count > callee.global_slot_base)
            @intCast(self.program.modules[target_module].global_slot_count - callee.global_slot_base)
        else
            0;
        if (shift_bias == 0) {
            const n: usize = @min(capture_locals.len, locals.len);
            if (n > 0) @memcpy(locals[0..n], capture_locals[0..n]);
            const dn: usize = @min(capture_declared.len, declared.len);
            if (dn > 0) @memcpy(declared[0..dn], capture_declared[0..dn]);
            return;
        }

        const same_n: usize = @min(shift_base, @min(capture_locals.len, locals.len));
        if (same_n > 0) {
            @memcpy(locals[0..same_n], capture_locals[0..same_n]);
        }

        var src: usize = shift_base;
        while (src < capture_locals.len) : (src += 1) {
            const shifted_dst = src + shift_bias;
            if (shifted_dst < locals.len) {
                locals[shifted_dst] = capture_locals[src];
            } else if (allow_direct_overflow_fallback and capture_locals.len == locals.len and src < locals.len) {
                locals[src] = capture_locals[src];
            } else {
                break;
            }
        }

        const same_decl_n: usize = @min(shift_base, @min(capture_declared.len, declared.len));
        if (same_decl_n > 0) {
            @memcpy(declared[0..same_decl_n], capture_declared[0..same_decl_n]);
        }
        src = shift_base;
        while (src < capture_declared.len) : (src += 1) {
            const shifted_dst = src + shift_bias;
            if (shifted_dst < declared.len) {
                declared[shifted_dst] = capture_declared[src];
            } else if (allow_direct_overflow_fallback and capture_declared.len == declared.len and src < declared.len) {
                declared[src] = capture_declared[src];
            } else {
                break;
            }
        }

        // Nested @content frames can be compiled before the enclosing content
        // block's later flow-control temporaries have been allocated.  In that
        // case the capturing frame is longer than the callee frame, but the
        // currently-visible loop locals still use their final slot numbers in
        // both frames.  The global-slot shift above moves older pre-remap slots
        // into their final positions; fill any still-undeclared callee slots
        // from the same-index capture so loop variables such as
        // `@each $breakpoint ... { @include m { ... $breakpoint ... } }`
        // survive the nested content call.
        if (capture_locals.len >= locals.len and capture_declared.len >= declared.len) {
            const direct_n: usize = @min(locals.len, declared.len);
            var direct: usize = shift_base;
            while (direct < direct_n) : (direct += 1) {
                if (declared[direct]) continue;
                if (!capture_declared[direct]) continue;
                locals[direct] = capture_locals[direct];
                declared[direct] = true;
            }
        }
    }

    fn overlayCurrentFrameGlobalWritebacksForContent(
        self: *VM,
        target_module: u32,
        locals: []Value,
        declared: []bool,
        global_writeback: []bool,
    ) void {
        if (self.current_module != target_module) return;
        if (self.frame_stack.items.len == 0) return;
        if (target_module >= self.program.modules.len) return;

        const caller = self.frame_stack.items[self.frame_stack.items.len - 1];
        if (!caller.global_writeback_any) return;
        if (caller.global_writeback.len == 0) return;

        const global_count: usize = @intCast(self.program.modules[target_module].global_slot_count);
        const n: usize = @min(
            global_count,
            @min(
                @min(locals.len, declared.len),
                @min(
                    @min(caller.locals.len, caller.declared.len),
                    @min(caller.global_writeback.len, global_writeback.len),
                ),
            ),
        );
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (!caller.global_writeback[i]) continue;
            locals[i] = caller.locals[i];
            declared[i] = caller.declared[i];
            global_writeback[i] = true;
        }
    }

    fn doCallContentPrepared(
        self: *VM,
        target_module: u32,
        content_chunk_id: u32,
        capture_locals: []const Value,
        capture_declared: []const bool,
        args: []const Value,
        arg_names: []const InternId,
        rest_separator_override: ?ListSeparator,
    ) VMError!void {
        if (self.frame_stack.items.len >= max_frames) return error.FrameOverflow;

        const callee = self.getChunk(target_module, .{ .content = content_chunk_id });
        const caller_mod = self.current_module;
        const save_sp: u32 = @intCast(self.stack.items.len);
        const ret_pc = self.pc;
        const ret_enc = encodeChunkRef(self.current_chunk);

        const locals = try self.arena().alloc(Value, callee.local_count);
        @memset(locals, Value.nil_v);
        const declared = try self.arena().alloc(bool, callee.local_count);
        @memset(declared, false);
        const global_writeback = try self.allocateGlobalWriteback(target_module, callee.local_count);

        if (self.mod_globals_bufs.len > target_module) {
            const mg = self.mod_globals_bufs[target_module];
            const md = self.mod_global_declared_bufs[target_module];
            const n = @min(mg.len, locals.len);
            if (n > 0) @memcpy(locals[0..n], mg[0..n]);
            const dn = @min(md.len, declared.len);
            if (dn > 0) @memcpy(declared[0..dn], md[0..dn]);
        }
        const caller_frame = if (self.frame_stack.items.len > 0)
            self.frame_stack.items[self.frame_stack.items.len - 1]
        else
            null;
        const allow_direct_capture_fallback = if (caller_frame) |fr|
            fr.content_parent_chunk_id != content_none_sentinel
        else
            false;
        if (capture_locals.len > 0) {
            self.copyCapturedContentLocals(target_module, callee, capture_locals, capture_declared, locals, declared, allow_direct_capture_fallback);
        }
        self.overlayCurrentFrameGlobalWritebacksForContent(target_module, locals, declared, global_writeback);

        try self.bindCallableArgs(callee, locals, declared, args, arg_names, rest_separator_override);
        const next_binding = if (caller_frame) |fr|
            contentParentBindingFromFrame(fr)
        else
            ContentBinding{};
        const next_parent_binding = self.resolveParentContentBinding(next_binding);

        try self.frame_stack.append(self.allocator, .{
            .locals = locals,
            .declared = declared,
            .global_writeback = global_writeback,
            .return_pc = ret_pc,
            .return_chunk = ret_enc,
            .save_sp = save_sp,
            .caller_module_id = caller_mod,
            .content_module_id = next_binding.module_id,
            .content_chunk_id = next_binding.chunk_id,
            .content_capture_locals = next_binding.capture_locals,
            .content_capture_declared = next_binding.capture_declared,
            .content_parent_module_id = next_parent_binding.module_id,
            .content_parent_chunk_id = next_parent_binding.chunk_id,
            .content_parent_capture_locals = next_parent_binding.capture_locals,
            .content_parent_capture_declared = next_parent_binding.capture_declared,
            .content_writeback_locals = @constCast(capture_locals),
            .content_writeback_declared = @constCast(capture_declared),
        });

        self.current_module = target_module;
        self.current_chunk = .{ .content = content_chunk_id };
        self.pc = 0;
    }

    fn dispatchBuiltinArgs(self: *VM, builtin_id: u32, args: []const Value, arg_names: []const InternId) VMError!Value {
        return vm_dispatch.dispatchBuiltinArgs(self, builtin_id, args, arg_names);
    }

    fn hasTopLevelCommaInCalcText(_: *VM, text: []const u8) bool {
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

    fn isSingleFunctionCallText(_: *VM, text: []const u8, func_name: []const u8) bool {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (!std.mem.startsWith(u8, trimmed, func_name)) return false;
        if (trimmed.len <= func_name.len + 1 or trimmed[func_name.len] != '(' or trimmed[trimmed.len - 1] != ')') return false;

        var depth: i32 = 0;
        var in_string: u8 = 0;
        var i: usize = func_name.len;
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
            if (c == '(') depth += 1;
            if (c == ')') {
                depth -= 1;
                if (depth == 0) return i == trimmed.len - 1;
            }
        }
        return false;
    }

    fn shouldProtectInterpolatedCalcString(
        self: *VM,
        part: Value,
        s: []const u8,
        interpolation_context: bool,
        source_has_interp: bool,
        part_preserve_literal_calc: bool,
    ) bool {
        if (!interpolation_context) return false;
        if (part.kind() != .string) return false;
        if (part.stringQuoted(self.string_flags_pool.items)) return false;
        if (!self.isSingleFunctionCallText(s, "calc")) return false;
        if (shouldMarkCalcInterpString(self.intern_pool, part)) return true;
        return (source_has_interp or part_preserve_literal_calc) and
            isUnquotedCalcLikeString(self.intern_pool, part) and
            !customCalcShouldSimplifyToNumber(s);
    }

    fn isSimpleCalcIdentifierFragment(_: *VM, text: []const u8) bool {
        if (text.len == 0) return false;
        for (text, 0..) |c, i| {
            const is_head = std.ascii.isAlphabetic(c) or c == '_';
            const is_tail = is_head or std.ascii.isDigit(c) or c == '-';
            if (i == 0) {
                if (!is_head) return false;
            } else if (!is_tail) {
                return false;
            }
        }
        return true;
    }

    fn normalizeCalcPassthroughInner(self: *VM, inner: []const u8) VMError![]const u8 {
        const flattened = try calc_utils.flattenNestedCalc(self.allocator, inner);
        defer if (!calc_utils.sameSliceStorage(flattened, inner)) self.allocator.free(flattened);

        const optimized = try calc_utils.removeUnnecessaryCalcParens(self.allocator, flattened);
        defer if (!calc_utils.sameSliceStorage(optimized, flattened)) self.allocator.free(optimized);

        return try dupeRuntimeMaybeAliased(self.allocator, optimized);
    }
    fn calcSpaceListNeedsPassthrough(self: *VM, v: Value) bool {
        if (v.kind() != .list or v.listSeparator(self.list_meta_pool.items) != .space) return false;
        const items = self.list_pool.items[v.listHandle()];
        var saw_special_text = false;
        for (items) |item| {
            if (item.isNumber()) continue;
            if (item.isString()) {
                if (item.stringQuoted(self.string_flags_pool.items)) return false;
                const raw = calc_utils.stripCalcArgMarker(self.intern_pool.get(item.stringIntern()));
                if (raw.len == 0) continue;
                const t = std.mem.trim(u8, raw, " \t\r\n");
                if (t.len == 0) continue;
                if (std.mem.indexOf(u8, t, "var(") != null or std.mem.indexOf(u8, t, "env(") != null) {
                    saw_special_text = true;
                }
                const head = t[0];
                const tail = t[t.len - 1];
                if (head == '+' or head == '-' or head == '*' or head == '/' or
                    tail == '+' or tail == '-' or tail == '*' or tail == '/')
                {
                    saw_special_text = true;
                }
            } else {
                return false;
            }
        }
        return saw_special_text;
    }

    fn renderCalcCallableArgText(self: *VM, arg: Value) VMError![]const u8 {
        if (arg.isNumber()) {
            return try formatNumberValue(self.intern_pool, &self.number_pool, self.allocator, arg);
        }
        if (arg.isString()) {
            if (arg.stringQuoted(self.string_flags_pool.items)) return error.SassError;
            const raw = calc_utils.stripCalcArgMarker(self.intern_pool.get(arg.stringIntern()));
            if (color_mod.lookupNamedColor(raw) != null) return error.SassError;
            return try dupeRuntimeMaybeAliased(self.allocator, raw);
        }
        if (arg.kind() == .list) {
            if (arg.listSlash(self.list_meta_pool.items)) {
                const id = try valueToInternIdDecl(
                    self.intern_pool,
                    &self.number_pool,
                    self.allocator,
                    &self.list_pool,
                    self.color_pool,
                    &self.slash_list_preserve,
                    arg,
                    false,
                );
                const raw = calc_utils.stripCalcArgMarker(self.intern_pool.get(id));
                if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return error.SassError;
                return try dupeRuntimeMaybeAliased(self.allocator, raw);
            }
            const coerced = try coerceCalcStringToNumberish(self.intern_pool, &self.number_pool, self.allocator, &self.list_pool, arg);
            if (coerced.isNumber()) {
                return try formatNumberValue(self.intern_pool, &self.number_pool, self.allocator, coerced);
            }
            const id = try valueToInternIdDecl(
                self.intern_pool,
                &self.number_pool,
                self.allocator,
                &self.list_pool,
                self.color_pool,
                &self.slash_list_preserve,
                arg,
                false,
            );
            const raw = calc_utils.stripCalcArgMarker(self.intern_pool.get(id));
            if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return error.SassError;
            return try dupeRuntimeMaybeAliased(self.allocator, raw);
        }
        return error.SassError;
    }

    fn buildCalcCallableResult(self: *VM, args: []const Value) VMError!Value {
        if (args.len != 1) return error.SassError;

        const source_arg = args[0];
        // If Sass arithmetic has already reduced the calc() argument to a number,
        // return that number directly. Rendering it to CSS text and parsing it back
        // truncates the hidden f64 precision that later arithmetic (for example
        // percentage(calc($a / $b))) still observes in official Sass CLI.
        if (source_arg.kind() == .number) return source_arg;

        const source_marked = shouldMarkCalcString(self.intern_pool, source_arg);
        const source_interp_marked = shouldMarkCalcInterpString(self.intern_pool, source_arg);
        if (source_arg.kind() == .string) {
            if (source_arg.stringQuoted(self.string_flags_pool.items)) return error.SassError;
            const source_raw = calc_utils.stripCalcArgMarker(self.intern_pool.get(source_arg.stringIntern()));
            if (color_mod.lookupNamedColor(source_raw) != null) return error.SassError;
        }
        const raw_owned: ?[]const u8 = if (source_arg.kind() == .string) null else try self.renderCalcCallableArgText(args[0]);
        defer if (raw_owned) |owned| self.allocator.free(owned);
        const raw = if (source_arg.kind() == .string)
            calc_utils.stripCalcArgMarker(self.intern_pool.get(source_arg.stringIntern()))
        else
            raw_owned.?;
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return error.SassError;
        if (self.hasTopLevelCommaInCalcText(trimmed)) return error.SassError;
        if (calc_utils.calcHasBadWhitespace(trimmed)) return error.SassError;
        if (calcTextHasComplexNestedCalcAddend(trimmed)) return error.SassError;

        const has_special_var_call =
            std.mem.indexOf(u8, trimmed, "var(") != null or
            std.mem.indexOf(u8, trimmed, "env(") != null;
        const marked_outer_parens = source_marked and hasOuterWrappingParensVm(trimmed);
        const string_outer_parens_with_op =
            source_arg.kind() == .string and
            hasOuterWrappingParensVm(trimmed) and
            std.mem.indexOfAny(u8, trimmed, "+-*/") != null;
        const list_passthrough = self.calcSpaceListNeedsPassthrough(source_arg);
        const needs_passthrough =
            source_interp_marked or has_special_var_call or marked_outer_parens or string_outer_parens_with_op or list_passthrough;
        if (needs_passthrough) {
            if (self.isSingleCssMathFunctionCallText(trimmed)) {
                if (source_interp_marked) return try internCalcInterpString(self.intern_pool, self.allocator, trimmed);
                const id_keep = try self.intern_pool.intern(trimmed);
                return Value.string(id_keep, false);
            }
            var normalized = if (source_interp_marked)
                try calc_utils.flattenNestedCalc(self.allocator, trimmed)
            else
                try self.normalizeCalcPassthroughInner(trimmed);
            var normalized_owned = !source_interp_marked or !calc_utils.sameSliceStorage(normalized, trimmed);
            defer if (normalized_owned) self.allocator.free(normalized);

            if (source_interp_marked and hasOuterWrappingParensVm(normalized)) {
                const close = findMatchingParenInDeclText(normalized, 0) orelse normalized.len;
                if (close == normalized.len - 1) {
                    const inner = std.mem.trim(u8, normalized[1..close], " \t\r\n");
                    const unwrapped = try dupeRuntimeMaybeAliased(self.allocator, inner);
                    if (normalized_owned) self.allocator.free(normalized);
                    normalized = unwrapped;
                    normalized_owned = true;
                }
            }

            if (self.isSingleFunctionCallText(trimmed, "calc") or self.isSingleFunctionCallText(normalized, "calc")) {
                const calc_text = if (self.isSingleFunctionCallText(normalized, "calc")) normalized else trimmed;
                const nested_inner = std.mem.trim(u8, calc_text[5 .. calc_text.len - 1], " \t\r\n");
                if (self.isSimpleCalcIdentifierFragment(nested_inner) and !std.mem.eql(u8, normalized, nested_inner)) {
                    const replaced = try self.allocator.dupe(u8, nested_inner);
                    if (normalized_owned) self.allocator.free(normalized);
                    normalized = replaced;
                    normalized_owned = true;
                }
            }

            const wrapped_passthrough = try std.fmt.allocPrint(self.allocator, "calc({s})", .{normalized});
            defer self.allocator.free(wrapped_passthrough);
            if (source_interp_marked) return try internCalcInterpString(self.intern_pool, self.allocator, wrapped_passthrough);
            const id_passthrough = try self.intern_pool.intern(wrapped_passthrough);
            return Value.string(id_passthrough, false);
        }

        // Avoid calc(calc(...)) / calc(min(...)) double wrapping.
        if (self.isSingleFunctionCallText(trimmed, "calc") or
            self.isSingleFunctionCallText(trimmed, "min") or
            self.isSingleFunctionCallText(trimmed, "max") or
            self.isSingleFunctionCallText(trimmed, "clamp") or
            self.isSingleCssMathFunctionCallText(trimmed))
        {
            if (source_interp_marked) return try internCalcInterpString(self.intern_pool, self.allocator, trimmed);
            const id_keep = try self.intern_pool.intern(trimmed);
            return Value.string(id_keep, false);
        }

        if (calcTextContainsKnownCssMathFunctionLike(trimmed)) {
            return try self.preserveUnparsedCalcText(trimmed);
        }

        const flattened_calc_arg = try calc_utils.flattenNestedCalc(self.allocator, trimmed);
        defer if (!calc_utils.sameSliceStorage(flattened_calc_arg, trimmed)) self.allocator.free(flattened_calc_arg);
        const parsed = calculation_mod.parseCalc(self.allocator, flattened_calc_arg) catch {
            // official Sass CLI treats unknown CSS functions inside calculation syntax as
            // opaque CSS and preserves the whole calculation, while Sass/user
            // functions that were resolved earlier still reach this point as
            // concrete numbers/strings. If the calculation parser cannot parse
            // a function-like fragment, keep the CSS surface instead of turning
            // a custom CSS calculation into a Sass error.
            if (calcTextContainsUnknownFunctionLike(trimmed)) {
                return try self.preserveUnparsedCalcText(trimmed);
            }
            return error.SassError;
        };
        defer self.allocator.destroy(parsed);
        defer calculation_mod.freeCalcValue(self.allocator, parsed);

        const simplified = calculation_mod.simplify(self.allocator, parsed) catch return error.SassError;
        defer self.allocator.destroy(simplified);
        defer calculation_mod.freeCalcValue(self.allocator, simplified);

        switch (simplified.*) {
            .number => |n| {
                const unit_id: InternId = if (n.unit) |u| try self.intern_pool.intern(u) else .none;
                return try Value.number(n.value, unit_id, &self.number_pool, self.allocator);
            },
            .variable => {
                const wrapped_var = try std.fmt.allocPrint(self.allocator, "calc({s})", .{trimmed});
                defer self.allocator.free(wrapped_var);
                if (source_interp_marked) return try internCalcInterpString(self.intern_pool, self.allocator, wrapped_var);
                const id_var = try self.intern_pool.intern(wrapped_var);
                return Value.string(id_var, false);
            },
            else => {},
        }

        const css = calculation_mod.toCss(self.allocator, simplified) catch return error.SassError;
        defer self.allocator.free(css);
        if (self.isSingleFunctionCallText(css, "min") or
            self.isSingleFunctionCallText(css, "max") or
            self.isSingleFunctionCallText(css, "clamp"))
        {
            if (source_interp_marked) return try internCalcInterpString(self.intern_pool, self.allocator, css);
            const id_inner = try self.intern_pool.intern(css);
            return Value.string(id_inner, false);
        }

        const wrapped = try std.fmt.allocPrint(self.allocator, "calc({s})", .{css});
        defer self.allocator.free(wrapped);
        if (source_interp_marked) return try internCalcInterpString(self.intern_pool, self.allocator, wrapped);
        const id = try self.intern_pool.intern(wrapped);
        return Value.string(id, false);
    }

    fn calcTextHasComplexNestedCalcAddend(text: []const u8) bool {
        var depth: i32 = 0;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            const c = text[i];
            if (c == '(') {
                depth += 1;
                continue;
            }
            if (c == ')') {
                if (depth > 0) depth -= 1;
                continue;
            }
            if (depth != 0 or (c != '+' and c != '-')) continue;

            var j = i + 1;
            while (j < text.len and (text[j] == ' ' or text[j] == '\t' or text[j] == '\n' or text[j] == '\r')) : (j += 1) {}
            if (j + 5 <= text.len and std.ascii.eqlIgnoreCase(text[j .. j + 5], "calc(")) {
                const end = findMatchingParenText(text, j + 4) orelse return true;
                if (calcInnerLooksComplexUnit(text[j + 5 .. end])) return true;
            }
        }
        return false;
    }

    fn calcTextContainsUnknownFunctionLike(text: []const u8) bool {
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
            if (c != '(' or i == 0) continue;

            var j = i;
            while (j > 0) {
                const prev = text[j - 1];
                if (std.ascii.isAlphabetic(prev) or std.ascii.isDigit(prev) or prev == '_' or prev == '-') {
                    j -= 1;
                    continue;
                }
                break;
            }
            if (j < i and (std.ascii.isAlphabetic(text[j]) or text[j] == '_' or text[j] == '-')) {
                if (isKnownCalcFunctionName(text[j..i])) continue;
                return true;
            }
        }
        return false;
    }

    fn calcTextContainsKnownCssMathFunctionLike(text: []const u8) bool {
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
            if (c != '(' or i == 0) continue;

            var j = i;
            while (j > 0) {
                const prev = text[j - 1];
                if (std.ascii.isAlphabetic(prev) or std.ascii.isDigit(prev) or prev == '_' or prev == '-') {
                    j -= 1;
                    continue;
                }
                break;
            }
            if (j < i and (std.ascii.isAlphabetic(text[j]) or text[j] == '_' or text[j] == '-')) {
                if (!std.ascii.eqlIgnoreCase(text[j..i], "calc") and isKnownCalcFunctionName(text[j..i])) return true;
            }
        }
        return false;
    }

    fn isKnownCalcFunctionName(name: []const u8) bool {
        return std.ascii.eqlIgnoreCase(name, "calc") or
            std.ascii.eqlIgnoreCase(name, "calc-size") or
            std.ascii.eqlIgnoreCase(name, "min") or
            std.ascii.eqlIgnoreCase(name, "max") or
            std.ascii.eqlIgnoreCase(name, "clamp") or
            std.ascii.eqlIgnoreCase(name, "round") or
            std.ascii.eqlIgnoreCase(name, "mod") or
            std.ascii.eqlIgnoreCase(name, "rem") or
            std.ascii.eqlIgnoreCase(name, "sin") or
            std.ascii.eqlIgnoreCase(name, "cos") or
            std.ascii.eqlIgnoreCase(name, "tan") or
            std.ascii.eqlIgnoreCase(name, "asin") or
            std.ascii.eqlIgnoreCase(name, "acos") or
            std.ascii.eqlIgnoreCase(name, "atan") or
            std.ascii.eqlIgnoreCase(name, "atan2") or
            std.ascii.eqlIgnoreCase(name, "pow") or
            std.ascii.eqlIgnoreCase(name, "sqrt") or
            std.ascii.eqlIgnoreCase(name, "hypot") or
            std.ascii.eqlIgnoreCase(name, "log") or
            std.ascii.eqlIgnoreCase(name, "exp") or
            std.ascii.eqlIgnoreCase(name, "abs") or
            std.ascii.eqlIgnoreCase(name, "sign");
    }

    fn isSingleCssMathFunctionCallText(self: *VM, text: []const u8) bool {
        const open = std.mem.indexOfScalar(u8, text, '(') orelse return false;
        if (open == 0) return false;
        if (!isKnownCalcFunctionName(text[0..open])) return false;
        return self.isSingleFunctionCallText(text, text[0..open]);
    }

    fn preserveUnparsedCalcText(self: *VM, trimmed: []const u8) VMError!Value {
        const wrapped = try std.fmt.allocPrint(self.allocator, "calc({s})", .{trimmed});
        defer self.allocator.free(wrapped);
        const id = try internRuntimeText(self.intern_pool, self.allocator, wrapped);
        return Value.string(id, false).withPreserveLiteralText();
    }

    fn findMatchingParenText(text: []const u8, open_idx: usize) ?usize {
        if (open_idx >= text.len or text[open_idx] != '(') return null;
        var depth: i32 = 1;
        var i = open_idx + 1;
        while (i < text.len) : (i += 1) {
            if (text[i] == '(') depth += 1;
            if (text[i] == ')') {
                depth -= 1;
                if (depth == 0) return i;
            }
        }
        return null;
    }

    fn calcInnerLooksComplexUnit(inner: []const u8) bool {
        return calcInnerHasUnitFactor(inner, "* 1") or calcInnerHasUnitFactor(inner, "/ 1");
    }

    fn calcInnerHasUnitFactor(inner: []const u8, needle: []const u8) bool {
        var search_start: usize = 0;
        while (std.mem.indexOfPos(u8, inner, search_start, needle)) |idx| {
            const unit_start = idx + needle.len;
            if (unit_start < inner.len) {
                const c = inner[unit_start];
                if (std.ascii.isAlphabetic(c) or c == '%' or c == '_') return true;
            }
            search_start = idx + 1;
        }
        return false;
    }

    fn buildCalcSizeCallableResult(self: *VM, args: []const Value) VMError!Value {
        if (args.len == 0 or args.len > 2) return error.SassError;
        try ensureDeclarationValueIsCssValue(&self.list_pool, args[0], false);

        const arg0_id = try valueToInternIdDecl(
            self.intern_pool,
            &self.number_pool,
            self.allocator,
            &self.list_pool,
            self.color_pool,
            &self.slash_list_preserve,
            args[0],
            false,
        );
        const arg0_text = calc_utils.stripCalcArgMarker(self.intern_pool.get(arg0_id));

        if (args.len == 1) {
            const out = try std.fmt.allocPrint(self.allocator, "calc-size({s})", .{arg0_text});
            defer self.allocator.free(out);
            const id_one = try self.intern_pool.intern(out);
            return Value.string(id_one, false);
        }

        const raw = try self.renderCalcCallableArgText(args[1]);
        defer self.allocator.free(raw);
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0 or self.hasTopLevelCommaInCalcText(trimmed) or calc_utils.calcHasBadWhitespace(trimmed)) {
            return error.SassError;
        }

        const placeholder = "__zsass_calc_size__";
        const replaced = try calc_utils.replaceAllLiteral(self.allocator, trimmed, "size", placeholder);
        defer self.allocator.free(replaced);
        const parsed = calculation_mod.parseCalc(self.allocator, replaced) catch return error.SassError;
        defer self.allocator.destroy(parsed);
        defer calculation_mod.freeCalcValue(self.allocator, parsed);
        const simplified = calculation_mod.simplify(self.allocator, parsed) catch return error.SassError;
        defer self.allocator.destroy(simplified);
        defer calculation_mod.freeCalcValue(self.allocator, simplified);

        const css = switch (simplified.*) {
            .number => |n| blk: {
                const unit_id: InternId = if (n.unit) |u| try self.intern_pool.intern(u) else .none;
                const v = try Value.number(n.value, unit_id, &self.number_pool, self.allocator);
                break :blk try formatNumberValue(self.intern_pool, &self.number_pool, self.allocator, v);
            },
            else => calculation_mod.toCss(self.allocator, simplified) catch return error.SassError,
        };
        defer self.allocator.free(css);

        const restore_var = try calc_utils.replaceAllLiteral(self.allocator, css, "var(__zsass_calc_size__)", "size");
        defer self.allocator.free(restore_var);
        const restore_plain = try calc_utils.replaceAllLiteral(self.allocator, restore_var, "__zsass_calc_size__", "size");
        defer self.allocator.free(restore_plain);

        const out = try std.fmt.allocPrint(self.allocator, "calc-size({s}, {s})", .{ arg0_text, restore_plain });
        defer self.allocator.free(out);
        const id_two = try self.intern_pool.intern(out);
        return Value.string(id_two, false);
    }

    pub fn buildCssCallableResult(self: *VM, name_id: InternId, args: []const Value, arg_names: []const InternId) VMError!Value {
        if (arg_names.len != 0) {
            for (arg_names) |arg_name| {
                if (arg_name != .none) return error.SassError;
            }
        }
        const name = self.intern_pool.get(name_id);
        if (identifierEq(name, "calc")) return self.buildCalcCallableResult(args);
        if (identifierEq(name, "calc-size")) return self.buildCalcSizeCallableResult(args);

        var acc: std.ArrayListUnmanaged(u8) = .empty;
        defer acc.deinit(self.allocator);
        try acc.appendSlice(self.allocator, name);
        try acc.append(self.allocator, '(');
        for (args, 0..) |arg, i| {
            if (i != 0) try acc.appendSlice(self.allocator, ", ");
            if (arg_names.len != 0 and arg_names[i] != .none) {
                var raw = self.intern_pool.get(arg_names[i]);
                if (raw.len > 0 and raw[0] == '$') raw = raw[1..];
                try acc.appendSlice(self.allocator, raw);
                try acc.appendSlice(self.allocator, ": ");
            }
            try ensureDeclarationValueIsCssValue(&self.list_pool, arg, false);
            const arg_id = try valueToInternIdDecl(
                self.intern_pool,
                &self.number_pool,
                self.allocator,
                &self.list_pool,
                self.color_pool,
                &self.slash_list_preserve,
                arg,
                false,
            );
            try acc.appendSlice(self.allocator, self.intern_pool.get(arg_id));
        }
        try acc.append(self.allocator, ')');
        const id = self.intern_pool.intern(acc.items) catch return error.OutOfMemory;
        return Value.string(id, false).withPreserveLiteralText();
    }

    pub fn invokeCallableFromBuiltinSync(
        self: *VM,
        expect_mixin: bool,
        target_v: Value,
        args: []const Value,
        arg_names: []const InternId,
    ) VMError!Value {
        return vm_dispatch.invokeCallableFromBuiltinSync(self, expect_mixin, target_v, args, arg_names);
    }

    pub fn validateMetaCallTarget(self: *VM, target_v: Value, expect_mixin: bool) VMError!void {
        if (expect_mixin) {
            if (target_v.kind() != .callable or !target_v.callableIsMixin(&self.callable_payload_pool)) {
                recordArgumentTypeMismatchMessage(self, "mixin", target_v, "mixin reference");
                return error.BuiltinType;
            }
            return;
        }

        if (target_v.kind() == .string) return;
        if (target_v.kind() != .callable or target_v.callableIsMixin(&self.callable_payload_pool)) {
            recordArgumentTypeMismatchMessage(self, "function", target_v, "function reference");
            return error.BuiltinType;
        }
    }

    fn invokeCallable(
        self: *VM,
        expect_mixin: bool,
        target_v: Value,
        args: []const Value,
        arg_names: []const InternId,
        rest_separator_override: ?ListSeparator,
    ) VMError!?Value {
        return vm_dispatch.invokeCallable(self, expect_mixin, target_v, args, arg_names, rest_separator_override);
    }

    pub fn encodeChunkRefForDispatch(_: *VM, r: ChunkRef) u32 {
        return encodeChunkRef(r);
    }

    pub fn recordArgumentTypeMismatchMessageForDispatch(self: *VM, param_name: []const u8, value: Value, expected: []const u8) void {
        recordArgumentTypeMismatchMessage(self, param_name, value, expected);
    }

    pub fn stripCalcArgMarkerForDispatch(_: *VM, text: []const u8) []const u8 {
        return calc_utils.stripCalcArgMarker(text);
    }

    pub fn serializeUnquotedDeclStringForDispatch(self: *VM, raw: []const u8) VMError![]u8 {
        return serializeUnquotedDeclString(self.allocator, raw);
    }

    pub fn invokeMetaLoadCss(self: *VM, args: []const Value, arg_names: []const InternId) VMError!void {
        return vm_cross_module.invokeMetaLoadCss(self, args, arg_names);
    }

    fn buildLoadCssSeedBindings(self: *VM, child_vm: *VM, config: LoadCssConfig) VMError![]LoadCssSeedBinding {
        return vm_cross_module.buildLoadCssSeedBindings(self, child_vm, config);
    }

    fn runLoadCssModule(self: *VM, resolved_path: []const u8, config: LoadCssConfig) VMError!void {
        return vm_cross_module.runLoadCssModule(self, resolved_path, config);
    }

    pub fn initLoadCssChildVM(self: *VM, child_program: *Program, is_plain_css_source: bool, has_parent_selector: bool) std.mem.Allocator.Error!VM {
        var child_vm = try VM.init(self.allocator, self.intern_pool, self.color_pool, self.rule_ir, child_program);
        child_vm.error_sink_fd = self.error_sink_fd;
        child_vm.load_css_stack_ptr = self.load_css_stack_ptr;
        child_vm.load_css_loaded_paths_ptr = self.load_css_loaded_paths_ptr;
        child_vm.load_css_state_ptr = self.load_css_state_ptr;
        child_vm.load_css_state_list_pool_ptr = self.ensureLoadCssStateListPool();
        child_vm.load_css_visible_modules_ptr = self.load_css_visible_modules_ptr;
        child_vm.load_css_next_tag_ptr = self.load_css_next_tag_ptr;
        child_vm.load_css_module_tag_override = self.load_css_next_tag_ptr.?.* - 1;
        child_vm.shadow_context_root_tag = child_vm.load_css_module_tag_override;
        child_vm.load_css_strict_top_level = is_plain_css_source and has_parent_selector;
        child_vm.keep_mod_globals_after_run = true;
        return child_vm;
    }

    fn encodeChunkRef(r: ChunkRef) u32 {
        return switch (r) {
            .top => 0,
            .mixin => |id| 1 + id,
            .placeholder => |id| 0x2000_0000 | id,
            .content => |id| 0x4000_0000 | id,
            .function => |id| 0x8000_0000 | id,
        };
    }

    fn decodeChunkRef(x: u32) ChunkRef {
        if (x == 0) return .top;
        if (x & 0x8000_0000 != 0) return .{ .function = x & 0x7fff_ffff };
        if (x & 0x4000_0000 != 0) return .{ .content = x & 0x3fff_ffff };
        if (x & 0x2000_0000 != 0) return .{ .placeholder = x & 0x1fff_ffff };
        return .{ .mixin = x - 1 };
    }

    fn getChunk(self: *VM, module_id: u32, r: ChunkRef) *const Chunk {
        const m = &self.program.modules[module_id];
        return switch (r) {
            .top => &m.top,
            .mixin => |id| &m.mixins[id],
            .function => |id| &m.functions[id],
            .content => |id| &m.content_blocks[id],
            .placeholder => |id| &m.placeholder_blocks[id],
        };
    }

    /// Helper for CLI-FIX-E Step 2c+ Phase 3: error trace. frame_stack[0] (= entry called
    /// Get "entry's callsite span" from caller chunk + return_pc (return destination of outer call).
    /// Display the position where the function was called in the `{entry} l:c root stylesheet` line of dart compatible trace.
    pub const CallSiteInfo = struct {
        source_module_id: u32,
        span_start: u32,
        span_end: u32,
    };

    pub fn outermostCallerInfo(self: *VM) ?CallSiteInfo {
        // Find the outermost non-sentinel frame. frame_stack[0] is usually the initial sentinel of runTop
        // frame (return_chunk == chunk_run_sentinel), so skip sentinel and start the first real frame
        // Take. This is the caller frame where entry called "dep2.broken()".
        var i: usize = 0;
        while (i < self.frame_stack.items.len) : (i += 1) {
            const fr = self.frame_stack.items[i];
            if (fr.return_chunk == chunk_run_sentinel) continue;
            if (fr.return_pc == 0) continue;
            if (fr.caller_module_id >= self.program.modules.len) continue;
            const r = decodeChunkRef(fr.return_chunk);
            const chunk = self.getChunk(fr.caller_module_id, r);
            const pc_idx: usize = @intCast(fr.return_pc - 1);
            if (pc_idx >= chunk.source_locs.len) continue;
            const loc = chunk.source_locs[pc_idx];
            return .{
                .source_module_id = loc.module_id,
                .span_start = loc.start,
                .span_end = loc.end,
            };
        }
        return null;
    }

    /// CLI-FIX-E Step 2c+ Phase 3: inner chunk name where error occurred (= function name / mixin name /
    /// "top" etc.). Display `broken()` etc. in inner frame label of dart compatible trace.
    pub fn innerMostChunkName(self: *VM) []const u8 {
        const chunk = self.getChunk(self.current_module, self.current_chunk);
        return chunk.name;
    }

    pub fn innerMostChunkRef(self: *VM) ChunkRef {
        return self.current_chunk;
    }

    fn cmpOp(self: *VM, op: enum { eq, neq, lt, gt, le, ge }) VMError!void {
        const raw_b = try self.maybeResolveParentSelectorValue(try self.pop());
        const raw_a = try self.maybeResolveParentSelectorValue(try self.pop());
        const b = try self.coerceSlashFreeValue(raw_b);
        const a = try self.coerceSlashFreeValue(raw_a);
        const ok: bool = switch (op) {
            .eq => valueEq(self.intern_pool, &self.number_pool, &self.list_meta_pool, &self.string_flags_pool, &self.callable_payload_pool, self.allocator, self.color_pool, &self.list_pool, a, b),
            .neq => !valueEq(self.intern_pool, &self.number_pool, &self.list_meta_pool, &self.string_flags_pool, &self.callable_payload_pool, self.allocator, self.color_pool, &self.list_pool, a, b),
            .lt, .gt, .le, .ge => blk: {
                if (a.kind() != .number or b.kind() != .number) return error.SassError;
                const pair = try comparableNumbers(self.intern_pool, &self.number_pool, self.allocator, a, b);
                const fa = pair.a;
                const fb = pair.b;
                const ord = fuzzyNumberOrder(fa, fb);
                break :blk switch (op) {
                    .lt => ord == .lt,
                    .gt => ord == .gt,
                    .le => ord == .lt or ord == .eq,
                    .ge => ord == .gt or ord == .eq,
                    else => unreachable,
                };
            },
        };
        try self.push(if (ok) Value.true_v else Value.false_v);
    }

    fn comparableNumbers(pool: *InternPool, number_pool: *NumberPool, alloc: std.mem.Allocator, a: Value, b: Value) VMError!struct { a: f64, b: f64 } {
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

    const convertComparableUnitRuntime = convertComparableUnitValueRuntime;

    const CanonicalComparableFactorRuntime = units.CanonicalComparableFactor;
    const canonicalComparableFactorRuntime = units.canonicalComparableFactorCi;

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
    ) VMError!CanonicalComparableNumberRuntime {
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
            .desc = try buildUnitDescriptionFromFactorsVm(alloc, numerators.items, denominators.items),
        };
    }

    fn pushWithSpan(self: *VM, v: Value, span: Span) VMError!void {
        if (self.stack.items.len >= max_stack) return error.StackOverflow;
        try self.stack.append(self.allocator, v);
        if (self.track_stack_source_spans) try self.stack_source_spans.append(self.allocator, span);
    }

    fn push(self: *VM, v: Value) VMError!void {
        return self.pushWithSpan(v, self.current_source_span);
    }

    const PoppedValue = struct {
        value: Value,
        span: Span,
    };

    fn popWithSpan(self: *VM) VMError!PoppedValue {
        const value = self.stack.pop() orelse return error.StackUnderflow;
        if (!self.track_stack_source_spans) {
            return .{ .value = value, .span = self.current_source_span };
        }
        const span = self.stack_source_spans.pop() orelse return error.InternalError;
        return .{ .value = value, .span = span };
    }

    pub fn pop(self: *VM) VMError!Value {
        return (try self.popWithSpan()).value;
    }
};

const identifierEq = builtin_shared.identifierEq;

fn hasNestedCalcFunctionText(text: []const u8) bool {
    const first = std.mem.indexOf(u8, text, "calc(") orelse return false;
    return std.mem.indexOf(u8, text[first + 5 ..], "calc(") != null;
}

fn dynamicCustomValueNeedsImplicitLeadingSpace(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return true;
    if (trimmed[0] == '$') return false;
    var i: usize = 0;
    while (i < trimmed.len and (std.ascii.isAlphanumeric(trimmed[i]) or trimmed[i] == '-' or trimmed[i] == '_')) : (i += 1) {}
    if (i > 0 and i < trimmed.len and trimmed[i] == '(') return false;
    return true;
}

fn shouldMarkCalcString(pool: *InternPool, v: Value) bool {
    if (v.kind() != .string or v.stringQuoted(value_mod.empty_string_flags_pool)) return false;
    const raw = pool.get(v.stringIntern());
    return std.mem.startsWith(u8, raw, calc_arg_marker);
}

fn shouldMarkCalcInterpString(pool: *InternPool, v: Value) bool {
    if (v.kind() != .string or v.stringQuoted(value_mod.empty_string_flags_pool)) return false;
    return std.mem.startsWith(u8, pool.get(v.stringIntern()), calc_interp_marker);
}

fn internWithLeadingMarker(pool: *InternPool, alloc: std.mem.Allocator, marker: []const u8, id: InternId) VMError!InternId {
    const text = pool.get(id);
    if (std.mem.startsWith(u8, text, marker)) return id;
    const marked = try std.fmt.allocPrint(alloc, "{s}{s}", .{ marker, text });
    defer alloc.free(marked);
    return pool.intern(marked) catch error.OutOfMemory;
}

fn stripLiteralDeclMarkersVm(alloc: std.mem.Allocator, text: []const u8) VMError![]const u8 {
    if (std.mem.indexOf(u8, text, literal_decl_marker) == null) return text;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], literal_decl_marker)) {
            i += literal_decl_marker.len;
            continue;
        }
        try out.append(alloc, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

fn isUnquotedCalcLikeString(pool: *InternPool, v: Value) bool {
    if (v.kind() != .string or v.stringQuoted(value_mod.empty_string_flags_pool)) return false;
    const raw = calc_utils.stripCalcArgMarker(pool.get(v.stringIntern()));
    return css_utils.containsCalcFunction(raw);
}

fn internCalcString(pool: *InternPool, alloc: std.mem.Allocator, text: []const u8, marked: bool) VMError!Value {
    if (marked) {
        const wrapped = try std.fmt.allocPrint(alloc, "{s}{s}", .{ calc_arg_marker, text });
        defer alloc.free(wrapped);
        const id_marked = try internRuntimeText(pool, alloc, wrapped);
        return Value.string(id_marked, false);
    }
    const id = try internRuntimeText(pool, alloc, text);
    return Value.string(id, false);
}

fn internCalcInterpString(pool: *InternPool, alloc: std.mem.Allocator, text: []const u8) VMError!Value {
    const wrapped = try std.fmt.allocPrint(alloc, "{s}{s}", .{ calc_interp_marker, text });
    defer alloc.free(wrapped);
    const id_marked = try internRuntimeText(pool, alloc, wrapped);
    return Value.string(id_marked, false);
}

const generated_string_fresh_threshold = 256;

fn internGeneratedString(pool: *InternPool, text: []const u8) VMError!InternId {
    if (text.len >= generated_string_fresh_threshold) {
        return pool.storeFresh(text);
    }
    return pool.intern(text);
}

fn valueEq(
    pool: *InternPool,
    number_pool: *NumberPool,
    list_meta_pool: *value_mod.ListMetaPool,
    string_flags_pool: *value_mod.StringFlagsPool,
    callable_payload_pool: *value_mod.CallablePayloadPool,
    alloc: std.mem.Allocator,
    color_pool: *const ColorPool,
    list_pool: *const std.ArrayListUnmanaged([]Value),
    a: Value,
    b: Value,
) bool {
    var env: RuntimeValueEqEnv = .{
        .alloc = alloc,
        .pool_ptr = pool,
        .number_pool_ptr = number_pool,
        .list_meta_pool_ptr = list_meta_pool,
        .string_flags_pool_ptr = string_flags_pool,
        .callable_payload_pool_ptr = callable_payload_pool,
        .color_pool_ptr = color_pool,
        .list_pool_ptr = list_pool,
    };
    return value_eq.valueEqEnv(&env, a, b);
}

fn plainMapKeyBytes(pool: *const InternPool, v: Value) ?[]const u8 {
    if (v.kind() != .string) return null;
    if (v.stringNamedColorLiteral(value_mod.empty_string_flags_pool)) return null;
    const raw = pool.get(v.stringIntern());
    if (std.mem.startsWith(u8, raw, calc_arg_marker)) return null;
    if (v.stringQuoted(value_mod.empty_string_flags_pool) and pool.hasBackslash(v.stringIntern())) return null;
    return raw;
}

const UnaryCalcPolicy = enum {
    /// prefix unary to a value containing calc()/min()/max()/clamp()/round() is a SassError.
    require_non_calc,
    /// Convert the calc value to a prefix string as is.
    allow_calc,
};

fn unaryPrefixValue(self: *VM, prefix: []const u8, v: Value, calc_policy: UnaryCalcPolicy) VMError!Value {
    const raw = if (v.kind() == .string and v.stringQuoted(self.string_flags_pool.items))
        try serializeQuotedDeclString(self.allocator, calc_utils.stripCalcArgMarker(self.intern_pool.get(v.stringIntern())))
    else
        try valueToOpString(self.intern_pool, &self.number_pool, self.allocator, &self.list_pool, self.color_pool, &self.callable_payload_pool, v);
    defer self.allocator.free(raw);

    if (calc_policy == .require_non_calc and css_utils.containsCalcFunction(raw)) {
        return error.SassError;
    }
    // legacy eval2: unary +/- on "." is invalid.
    if (!std.mem.eql(u8, prefix, "/") and std.mem.eql(u8, raw, ".")) {
        return error.SassError;
    }

    const merged = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, raw });
    defer self.allocator.free(merged);
    const id = try self.intern_pool.intern(merged);
    return Value.string(id, false);
}

fn callArgNamesContainSplat(arg_names: []const InternId) bool {
    for (arg_names) |name_id| {
        if (name_id == call_arg_splat_sentinel) return true;
    }
    return false;
}

fn builtinRejectsTopLevelRest(builtin_id: u32) bool {
    return switch (builtin_id) {
        // CSS-only calculation functions reject top-level rest args.
        // Keep abs/min/max/round/sign out of this list: those have Sass
        // builtin variants that may accept varargs.
        11, // sqrt
        12, // pow
        13, // log
        14, // sin
        15, // cos
        16, // tan
        17, // asin
        18, // acos
        19, // atan
        20, // atan2
        21, // hypot
        105, // exp
        107, // mod
        108, // rem
        110, // clamp
        => true,
        else => false,
    };
}

fn builtinSkipsSlashFreeCoercion(builtin_id: u32) bool {
    return switch (builtin_id) {
        // Color constructors need the raw `calc(...)` / slash-list surface form.
        // Eager calc-string coercion turns CSS fallback inputs into plain numbers
        // before the builtin can inspect them.
        39,
        40,
        41,
        42,
        52,
        91,
        92,
        93,
        94,
        95,
        // CSS math functions need slash-list arguments to reach the builtin
        // before coercion. Otherwise `tan(var(--angle) / 2)` fails while Dart
        // Sass preserves it as a CSS function call.
        11, // sqrt
        12, // pow
        13, // log
        14, // sin
        15, // cos
        16, // tan
        17, // asin
        18, // acos
        19, // atan
        20, // atan2
        21, // hypot
        105, // exp
        107, // mod
        108, // rem
        110, // clamp
        // meta.calc-name()/meta.calc-args() must observe raw calc()/interpolation
        // values. Eager calc->number coercion here turns valid inputs into
        // BuiltinType errors.
        150,
        151,
        // Global CSS filter builtins need access to raw unquoted calc() text.
        185,
        186,
        187,
        => true,
        else => false,
    };
}

fn calcOperandNeedsParensForMultiplicative(raw: []const u8) bool {
    const t = std.mem.trim(u8, raw, " \t\r\n");
    if (t.len < 3) return false;
    if (t[0] == '(' and t[t.len - 1] == ')') return false;
    return calc_utils.calcExprHasAdditiveOp(t) or calcOperandHasCompactAdditiveBeforeCssVar(t);
}

fn calcOperandHasCompactAdditiveBeforeCssVar(text: []const u8) bool {
    var depth: u32 = 0;
    var in_str: u8 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_str != 0) {
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (c == in_str) in_str = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_str = c;
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
        if (depth != 0 or (c != '+' and c != '-') or i == 0) continue;

        var j = i + 1;
        while (j < text.len and std.ascii.isWhitespace(text[j])) : (j += 1) {}
        const rhs_is_special =
            (j + 4 <= text.len and std.ascii.eqlIgnoreCase(text[j .. j + 3], "var") and text[j + 3] == '(') or
            (j + 4 <= text.len and std.ascii.eqlIgnoreCase(text[j .. j + 3], "env") and text[j + 3] == '(');
        if (!rhs_is_special) continue;

        var k = i;
        while (k > 0 and std.ascii.isWhitespace(text[k - 1])) : (k -= 1) {}
        if (k == 0) continue;
        const prev = text[k - 1];
        if (prev == '(' or prev == ',' or prev == '+' or prev == '-' or prev == '*' or prev == '/') continue;
        return true;
    }
    return false;
}

fn formatCalcArithmeticNumber(pool: *InternPool, number_pool: *NumberPool, alloc: std.mem.Allocator, v: Value) VMError![]const u8 {
    std.debug.assert(v.kind() == .number);
    const n = v.asF64(number_pool);
    const unit_id = v.unitId(number_pool);
    const unit = if (unit_id == .none) null else pool.get(unit_id);
    if (std.math.isNan(n)) {
        if (unit) |u| {
            if (unitFactorCanAttachDirectly(u)) {
                return std.fmt.allocPrint(alloc, "NaN * 1{s}", .{u}) catch error.OutOfMemory;
            }
            return std.fmt.allocPrint(alloc, "NaN * {s}", .{u}) catch error.OutOfMemory;
        }
        return try alloc.dupe(u8, "NaN");
    }
    if (std.math.isInf(n)) {
        const keyword = if (n < 0) "-infinity" else "infinity";
        if (unit) |u| {
            if (unitFactorCanAttachDirectly(u)) {
                return std.fmt.allocPrint(alloc, "{s} * 1{s}", .{ keyword, u }) catch error.OutOfMemory;
            }
            return std.fmt.allocPrint(alloc, "{s} * {s}", .{ keyword, u }) catch error.OutOfMemory;
        }
        return try alloc.dupe(u8, keyword);
    }
    return formatNumberValue(pool, number_pool, alloc, v);
}

/// CLI-FIX-E Step 2c+ Phase 2 helper: Generate dart compatible messages for incompat units
/// Set to thread-local context. When format fails in OOM etc., silently give up and use generic
/// Return to `Compilation failed.` fallback (survival is prioritized over rich message in situations where there is no alloc space).
fn recordIncompatibleUnitsMessage(
    pool: *InternPool,
    number_pool: *NumberPool,
    alloc: std.mem.Allocator,
    lhs: Value,
    rhs: Value,
) void {
    const sa = formatNumberValue(pool, number_pool, alloc, lhs) catch return;
    defer alloc.free(sa);
    const sb = formatNumberValue(pool, number_pool, alloc, rhs) catch return;
    defer alloc.free(sb);
    const msg = std.fmt.allocPrint(alloc, "{s} and {s} have incompatible units.", .{ sa, sb }) catch return;
    defer alloc.free(msg);
    error_format.setContextMessage(msg);
}

fn addValues(
    pool: *InternPool,
    number_pool: *NumberPool,
    alloc: std.mem.Allocator,
    list_pool: *const std.ArrayListUnmanaged([]Value),
    color_pool: *const ColorPool,
    callable_payload_pool: *const value_mod.CallablePayloadPool,
    a: Value,
    b: Value,
    preserve_css_math: bool,
) VMError!Value {
    const lhs = try coerceCalcStringToNumberish(pool, number_pool, alloc, list_pool, a);
    const rhs = try coerceCalcStringToNumberish(pool, number_pool, alloc, list_pool, b);
    const lhs_marked = shouldMarkCalcString(pool, a) or shouldMarkCalcString(pool, lhs);
    const rhs_marked = shouldMarkCalcString(pool, b) or shouldMarkCalcString(pool, rhs);
    const mark_result = lhs_marked or rhs_marked or preserve_css_math;
    const preserve_only = preserve_css_math and !lhs_marked and !rhs_marked;
    if (colorArithmeticShouldError(pool, lhs, rhs)) {
        return error.SassError;
    }
    if (listValueContainsMapRecursive(list_pool, lhs) or listValueContainsMapRecursive(list_pool, rhs)) {
        return error.SassError;
    }

    if (lhs.kind() == .number and rhs.kind() == .number) {
        if (combineAddUnits(pool, number_pool, lhs, rhs)) |resolved| {
            return try Value.number(lhs.asF64(number_pool) + resolved.rhs, resolved.unit, number_pool, alloc);
        } else |err| switch (err) {
            error.SassError => {
                const ua = lhs.unitId(number_pool);
                const ub = rhs.unitId(number_pool);
                if (mark_result and shouldPreserveCssMathAdd(pool, ua, ub)) {
                    const sa = try formatCalcArithmeticNumber(pool, number_pool, alloc, lhs);
                    defer alloc.free(sa);
                    const sb = try formatCalcArithmeticNumber(pool, number_pool, alloc, rhs);
                    defer alloc.free(sb);
                    const merged = try std.fmt.allocPrint(alloc, "{s} + {s}", .{ sa, sb });
                    defer alloc.free(merged);
                    return internCalcString(pool, alloc, merged, true);
                }
                // CLI-FIX-E Step 2c+ Phase 2: dart compatible context-aware message.
                // Save "{lhs_text} and {rhs_text} have incompatible units." in thread-local,
                // Display instead of `Compilation failed.` in driver's error output.
                recordIncompatibleUnitsMessage(pool, number_pool, alloc, lhs, rhs);
                return error.SassError;
            },
            else => return err,
        }
    }
    if (lhs.kind() == .string and rhs.kind() == .string) {
        const qa = lhs.stringQuoted(value_mod.empty_string_flags_pool);
        const qb = rhs.stringQuoted(value_mod.empty_string_flags_pool);
        const sa = calc_utils.stripCalcArgMarker(pool.get(lhs.stringIntern()));
        const sb = calc_utils.stripCalcArgMarker(pool.get(rhs.stringIntern()));
        if (mark_result) {
            if (preserve_only and (qa or qb)) {
                const merged = try std.fmt.allocPrint(alloc, "{s}{s}", .{ sa, sb });
                defer alloc.free(merged);
                const id = try internGeneratedString(pool, merged);
                return Value.string(id, qa or qb);
            }
            if (qa or qb) return error.SassError;
            const merged_calc = try std.fmt.allocPrint(alloc, "{s} + {s}", .{ sa, sb });
            defer alloc.free(merged_calc);
            return internCalcString(pool, alloc, merged_calc, true);
        }
        const lhs_calc_like = !qa and isUnquotedCalcLikeString(pool, lhs);
        const rhs_calc_like = !qb and isUnquotedCalcLikeString(pool, rhs);
        if (!qa and !qb and (lhs_calc_like or rhs_calc_like)) {
            const lhs_trim = std.mem.trim(u8, sa, " \t\r\n");
            const rhs_trim = std.mem.trim(u8, sb, " \t\r\n");
            const allow_concat =
                lhs_calc_like != rhs_calc_like and
                ((lhs_calc_like and rhs_trim.len != 0) or
                    (rhs_calc_like and lhs_trim.len != 0));
            if (!allow_concat) return error.SassError;
        }
        const merged = try std.fmt.allocPrint(alloc, "{s}{s}", .{ sa, sb });
        defer alloc.free(merged);
        const id = try internGeneratedString(pool, merged);
        const keep_rhs_quote = qb and !qa and isUnquotedCalcLikeString(pool, lhs);
        const out = Value.string(id, qa or keep_rhs_quote);
        return if (qa or keep_rhs_quote) out else out.withPreserveLiteralText();
    }
    if (lhs.kind() == .number and rhs.kind() == .string) {
        const num_s = try formatNumberValue(pool, number_pool, alloc, lhs);
        defer alloc.free(num_s);
        const sb = calc_utils.stripCalcArgMarker(pool.get(rhs.stringIntern()));
        if (mark_result) {
            if (preserve_only and rhs.stringQuoted(value_mod.empty_string_flags_pool)) {
                const merged = try std.fmt.allocPrint(alloc, "{s}{s}", .{ num_s, sb });
                defer alloc.free(merged);
                const id = try internGeneratedString(pool, merged);
                return Value.string(id, true);
            }
            if (rhs.stringQuoted(value_mod.empty_string_flags_pool)) return error.SassError;
            const merged_calc = try std.fmt.allocPrint(alloc, "{s} + {s}", .{ num_s, sb });
            defer alloc.free(merged_calc);
            return internCalcString(pool, alloc, merged_calc, true);
        }
        if (!rhs.stringQuoted(value_mod.empty_string_flags_pool) and isUnquotedCalcLikeString(pool, rhs)) return error.SassError;
        const merged = try std.fmt.allocPrint(alloc, "{s}{s}", .{ num_s, sb });
        defer alloc.free(merged);
        const id = try internGeneratedString(pool, merged);
        const out = Value.string(id, rhs.stringQuoted(value_mod.empty_string_flags_pool));
        return if (rhs.stringQuoted(value_mod.empty_string_flags_pool)) out else out.withPreserveLiteralText();
    }
    if (lhs.kind() == .string and rhs.kind() == .number) {
        const sb = try formatNumberValue(pool, number_pool, alloc, rhs);
        defer alloc.free(sb);
        const sa = calc_utils.stripCalcArgMarker(pool.get(lhs.stringIntern()));
        if (mark_result) {
            if (preserve_only and lhs.stringQuoted(value_mod.empty_string_flags_pool)) {
                const merged = try std.fmt.allocPrint(alloc, "{s}{s}", .{ sa, sb });
                defer alloc.free(merged);
                const id = try internGeneratedString(pool, merged);
                return Value.string(id, true);
            }
            if (lhs.stringQuoted(value_mod.empty_string_flags_pool)) return error.SassError;
            const merged_calc = try std.fmt.allocPrint(alloc, "{s} + {s}", .{ sa, sb });
            defer alloc.free(merged_calc);
            return internCalcString(pool, alloc, merged_calc, true);
        }
        if (!lhs.stringQuoted(value_mod.empty_string_flags_pool) and isUnquotedCalcLikeString(pool, lhs)) return error.SassError;
        const merged = try std.fmt.allocPrint(alloc, "{s}{s}", .{ sa, sb });
        defer alloc.free(merged);
        const id = try internGeneratedString(pool, merged);
        const out = Value.string(id, lhs.stringQuoted(value_mod.empty_string_flags_pool));
        return if (lhs.stringQuoted(value_mod.empty_string_flags_pool)) out else out.withPreserveLiteralText();
    }
    const sa = try valueToOpString(pool, number_pool, alloc, list_pool, color_pool, callable_payload_pool, lhs);
    defer alloc.free(sa);
    const sb = try valueToOpString(pool, number_pool, alloc, list_pool, color_pool, callable_payload_pool, rhs);
    defer alloc.free(sb);
    const merged = if (mark_result)
        try std.fmt.allocPrint(alloc, "{s} + {s}", .{ sa, sb })
    else
        try std.fmt.allocPrint(alloc, "{s}{s}", .{ sa, sb });
    defer alloc.free(merged);
    if (mark_result) {
        if ((lhs.kind() == .string and lhs.stringQuoted(value_mod.empty_string_flags_pool)) or (rhs.kind() == .string and rhs.stringQuoted(value_mod.empty_string_flags_pool))) {
            return error.SassError;
        }
        return internCalcString(pool, alloc, merged, true);
    }
    const id = try internGeneratedString(pool, merged);
    const quoted = (lhs.kind() == .string and lhs.stringQuoted(value_mod.empty_string_flags_pool)) or
        (rhs.kind() == .string and rhs.stringQuoted(value_mod.empty_string_flags_pool));
    const out = Value.string(id, quoted);
    return if (quoted) out else out.withPreserveLiteralText();
}

const AddUnitsResolved = struct {
    unit: InternId,
    rhs: f64,
};

fn combineAddUnits(pool: *InternPool, number_pool: *NumberPool, lhs: Value, rhs: Value) VMError!AddUnitsResolved {
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
    return error.SassError;
}

fn shouldPreserveCssMathAdd(pool: *const InternPool, ua: InternId, ub: InternId) bool {
    if (ua == .none or ub == .none or ua == ub) return false;
    const ua_text = pool.get(ua);
    const ub_text = pool.get(ub);
    if (unitTextLooksComposite(ua_text) or unitTextLooksComposite(ub_text)) return false;
    return !knownCalculationUnitsIncompatibleRuntime(ua_text, ub_text);
}

const CssMathUnitCategoryRuntime = enum {
    length,
    angle,
    time,
    frequency,
    resolution,
    unknown,
};

fn cssMathUnitCategoryRuntime(unit: []const u8) CssMathUnitCategoryRuntime {
    if (std.ascii.eqlIgnoreCase(unit, "px") or
        std.ascii.eqlIgnoreCase(unit, "cm") or
        std.ascii.eqlIgnoreCase(unit, "mm") or
        std.ascii.eqlIgnoreCase(unit, "in") or
        std.ascii.eqlIgnoreCase(unit, "pt") or
        std.ascii.eqlIgnoreCase(unit, "pc") or
        std.ascii.eqlIgnoreCase(unit, "q")) return .length;

    if (std.ascii.eqlIgnoreCase(unit, "deg") or
        std.ascii.eqlIgnoreCase(unit, "rad") or
        std.ascii.eqlIgnoreCase(unit, "grad") or
        std.ascii.eqlIgnoreCase(unit, "turn")) return .angle;

    if (std.ascii.eqlIgnoreCase(unit, "s") or std.ascii.eqlIgnoreCase(unit, "ms")) return .time;

    if (std.ascii.eqlIgnoreCase(unit, "hz") or std.ascii.eqlIgnoreCase(unit, "khz")) return .frequency;

    if (std.ascii.eqlIgnoreCase(unit, "dpi") or
        std.ascii.eqlIgnoreCase(unit, "dpcm") or
        std.ascii.eqlIgnoreCase(unit, "dppx")) return .resolution;

    return .unknown;
}

fn knownCalculationUnitsIncompatibleRuntime(unit_a: []const u8, unit_b: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(unit_a, unit_b)) return false;
    const cat_a = cssMathUnitCategoryRuntime(unit_a);
    const cat_b = cssMathUnitCategoryRuntime(unit_b);
    if (cat_a == .unknown or cat_b == .unknown) return false;
    return cat_a != cat_b;
}

const convertComparableUnitValueRuntime = units.convertComparableUnitCi;

fn isSimpleUnitIdentifier(unit: []const u8) bool {
    if (unit.len == 0) return false;
    if (std.mem.eql(u8, unit, "%")) return true;

    var i: usize = 0;
    if (unit[i] == '-') {
        i += 1;
        if (i >= unit.len) return false;
    }
    if (!(std.ascii.isAlphabetic(unit[i]) or unit[i] == '_')) return false;
    i += 1;
    while (i < unit.len) : (i += 1) {
        const c = unit[i];
        if (!(std.ascii.isAlphabetic(c) or std.ascii.isDigit(c) or c == '-' or c == '_')) return false;
    }
    return true;
}

fn isNumberishUnitSuffix(unit: []const u8) bool {
    if (unit.len == 0) return false;
    var has_alpha_or_percent = false;
    for (unit) |c| {
        if (c == '(' or c == ')') return false;
        if (std.ascii.isAlphabetic(c) or c == '%') has_alpha_or_percent = true;
        if (std.ascii.isAlphabetic(c) or std.ascii.isDigit(c) or c == '-' or c == '_' or c == '%' or c == '/' or c == '*' or c == '^' or c == '.') {
            continue;
        }
        return false;
    }
    return has_alpha_or_percent;
}

fn parseSimpleNumberish(pool: *InternPool, number_pool: *NumberPool, alloc: std.mem.Allocator, text: []const u8) VMError!?Value {
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

    // Do not allow spaces in units.
    for (unit_part) |c| {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') return null;
    }
    if (!isNumberishUnitSuffix(unit_part)) return null;
    const unit_id = try pool.intern(unit_part);
    return try Value.number(value, unit_id, number_pool, alloc);
}

fn parseCalcMultiplicativeNumberishExpr(
    pool: *InternPool,
    number_pool: *NumberPool,
    alloc: std.mem.Allocator,
    expr_raw: []const u8,
    numeric: *f64,
    numerators: *std.ArrayListUnmanaged([]const u8),
    denominators: *std.ArrayListUnmanaged([]const u8),
) VMError!bool {
    const expr = std.mem.trim(u8, expr_raw, " \t\r\n");
    if (expr.len == 0) return false;

    var depth: usize = 0;
    var seg_start: usize = 0;
    var current_op: enum { mul, div } = .mul;
    var i: usize = 0;
    while (i <= expr.len) : (i += 1) {
        const at_end = i == expr.len;
        if (!at_end) {
            const c = expr[i];
            switch (c) {
                '(' => depth += 1,
                ')' => {
                    if (depth == 0) return false;
                    depth -= 1;
                },
                '*', '/' => if (depth == 0) {
                    // Flush current segment before consuming the operator.
                } else {},
                else => {},
            }
            if (!(depth == 0 and (c == '*' or c == '/'))) continue;
        }

        if (depth != 0) return false;
        const token_raw = std.mem.trim(u8, expr[seg_start..i], " \t\r\n");
        if (token_raw.len == 0) return false;

        var token_numeric: f64 = 1.0;
        var token_nums: std.ArrayListUnmanaged([]const u8) = .empty;
        defer token_nums.deinit(alloc);
        var token_dens: std.ArrayListUnmanaged([]const u8) = .empty;
        defer token_dens.deinit(alloc);

        if (hasOuterWrappingParensVm(token_raw)) {
            const inner = std.mem.trim(u8, token_raw[1 .. token_raw.len - 1], " \t\r\n");
            if (inner.len == 0) return false;
            if (!(try parseCalcMultiplicativeNumberishExpr(pool, number_pool, alloc, inner, &token_numeric, &token_nums, &token_dens))) {
                return false;
            }
        } else {
            const parsed = (try parseSimpleNumberish(pool, number_pool, alloc, token_raw)) orelse return false;
            if (parsed.kind() != .number) return false;
            token_numeric = parsed.asF64(number_pool);
            const parsed_unit = parsed.unitId(number_pool);
            if (parsed_unit != .none) {
                try appendUnitTextFactors(alloc, pool.get(parsed_unit), &token_nums, &token_dens, false);
            }
        }

        switch (current_op) {
            .mul => {
                numeric.* *= token_numeric;
                try numerators.appendSlice(alloc, token_nums.items);
                try denominators.appendSlice(alloc, token_dens.items);
            },
            .div => {
                numeric.* /= token_numeric;
                try numerators.appendSlice(alloc, token_dens.items);
                try denominators.appendSlice(alloc, token_nums.items);
            },
        }

        if (at_end) break;
        current_op = if (expr[i] == '/') .div else .mul;
        seg_start = i + 1;
    }
    return true;
}

fn parseCalcNumberish(pool: *InternPool, number_pool: *NumberPool, alloc: std.mem.Allocator, text: []const u8) VMError!?Value {
    const raw = calc_utils.stripCalcArgMarker(text);
    const t = std.mem.trim(u8, raw, " \t\r\n");
    if (!std.mem.startsWith(u8, t, "calc(") or t.len < 6 or t[t.len - 1] != ')') return null;

    const inner = std.mem.trim(u8, t[5 .. t.len - 1], " \t\r\n");
    if (try parseSimpleNumberish(pool, number_pool, alloc, inner)) |value| return value;

    // `calc(infinity * 1px)` / `calc(-infinity * 1px)` / `calc(NaN * 1px)` back to number.
    if (std.mem.indexOfScalar(u8, inner, '*')) |star_idx| {
        const lhs = std.mem.trim(u8, inner[0..star_idx], " \t\r\n");
        const rhs = std.mem.trim(u8, inner[star_idx + 1 ..], " \t\r\n");
        if (rhs.len >= 2 and rhs[0] == '1') {
            const unit_text = rhs[1..];
            if (unit_text.len != 0) {
                var has_ws = false;
                for (unit_text) |c| {
                    if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                        has_ws = true;
                        break;
                    }
                }
                if (!has_ws) {
                    const scalar_opt: ?f64 = blk: {
                        if (std.ascii.eqlIgnoreCase(lhs, "infinity")) break :blk std.math.inf(f64);
                        if (std.ascii.eqlIgnoreCase(lhs, "-infinity")) break :blk -std.math.inf(f64);
                        if (std.ascii.eqlIgnoreCase(lhs, "nan") or std.ascii.eqlIgnoreCase(lhs, "-nan")) break :blk std.math.nan(f64);
                        break :blk null;
                    };
                    if (scalar_opt) |scalar| {
                        const unit_id = try pool.intern(unit_text);
                        return try Value.number(scalar, unit_id, number_pool, alloc);
                    }
                }
            }
        }
    }

    var numeric: f64 = 1.0;
    var numerators: std.ArrayListUnmanaged([]const u8) = .empty;
    defer numerators.deinit(alloc);
    var denominators: std.ArrayListUnmanaged([]const u8) = .empty;
    defer denominators.deinit(alloc);

    if (!(try parseCalcMultiplicativeNumberishExpr(pool, number_pool, alloc, inner, &numeric, &numerators, &denominators))) return null;

    const factor = simplifyUnitFactorsCaseInsensitive(&numerators, &denominators);
    const desc = try buildUnitDescriptionFromFactorsVm(alloc, numerators.items, denominators.items);
    var out_unit: InternId = .none;
    if (desc) |text_desc| {
        defer alloc.free(text_desc);
        out_unit = try pool.intern(text_desc);
    }
    return try Value.number(numeric * factor, out_unit, number_pool, alloc);
}

fn coerceSlashListToNumberish(
    pool: *InternPool,
    number_pool: *NumberPool,
    alloc: std.mem.Allocator,
    list_pool: *const std.ArrayListUnmanaged([]Value),
    v: Value,
) VMError!?Value {
    if (v.kind() != .list or !v.listSlash(value_mod.empty_list_meta_pool) or !v.listCoerceSlash(value_mod.empty_list_meta_pool) or v.listBracketed(value_mod.empty_list_meta_pool) or v.listComma(value_mod.empty_list_meta_pool)) return null;
    const items = list_pool.items[v.listHandle()];
    if (items.len < 2) return null;

    const first = try coerceCalcStringToNumberish(pool, number_pool, alloc, list_pool, items[0]);
    if (first.kind() != .number) return null;

    var numeric = first.asF64(number_pool);
    var numerators: std.ArrayListUnmanaged([]const u8) = .empty;
    defer numerators.deinit(alloc);
    var denominators: std.ArrayListUnmanaged([]const u8) = .empty;
    defer denominators.deinit(alloc);

    const first_unit = first.unitId(number_pool);
    if (first_unit != .none) {
        try appendUnitTextFactors(alloc, pool.get(first_unit), &numerators, &denominators, false);
    }

    for (items[1..]) |item| {
        const divisor = try coerceCalcStringToNumberish(pool, number_pool, alloc, list_pool, item);
        if (divisor.kind() != .number) return null;
        numeric /= divisor.asF64(number_pool);
        const divisor_unit = divisor.unitId(number_pool);
        if (divisor_unit != .none) {
            try appendUnitTextFactors(alloc, pool.get(divisor_unit), &numerators, &denominators, true);
        }
    }

    const factor = simplifyUnitFactorsCaseInsensitive(&numerators, &denominators);
    const desc = try buildUnitDescriptionFromFactorsVm(alloc, numerators.items, denominators.items);
    var out_unit: InternId = .none;
    if (desc) |text| {
        defer alloc.free(text);
        out_unit = try pool.intern(text);
    }
    return try Value.number(numeric * factor, out_unit, number_pool, alloc);
}

fn coerceCalcStringToNumberish(
    pool: *InternPool,
    number_pool: *NumberPool,
    alloc: std.mem.Allocator,
    list_pool: *const std.ArrayListUnmanaged([]Value),
    v: Value,
) VMError!Value {
    if (v.kind() == .string and !v.stringQuoted(value_mod.empty_string_flags_pool)) {
        const raw = calc_utils.stripCalcArgMarker(pool.get(v.stringIntern()));
        if (std.mem.indexOf(u8, raw, calc_interp_preserve_start) != null) return v;
        if (try parseCalcNumberish(pool, number_pool, alloc, raw)) |parsed| return parsed;
    }
    if (try coerceSlashListToNumberish(pool, number_pool, alloc, list_pool, v)) |parsed| return parsed;
    return v;
}

fn simplifySlashOperandText(pool: *InternPool, number_pool: *NumberPool, alloc: std.mem.Allocator, raw: []const u8) VMError![]const u8 {
    if (try parseCalcNumberish(pool, number_pool, alloc, raw)) |parsed| {
        if (parsed.kind() == .number and parsed.unitId(number_pool) == .none and std.math.isFinite(parsed.asF64(number_pool))) {
            return value_format.formatNumberWithUnit(alloc, parsed.asF64(number_pool), null) catch error.OutOfMemory;
        }
    }
    return try alloc.dupe(u8, raw);
}

fn subValues(
    pool: *InternPool,
    number_pool: *NumberPool,
    alloc: std.mem.Allocator,
    list_pool: *const std.ArrayListUnmanaged([]Value),
    color_pool: *const ColorPool,
    slash_list_preserve: ?*const std.AutoHashMapUnmanaged(u32, void),
    a: Value,
    b: Value,
    preserve_css_math: bool,
) VMError!Value {
    const lhs = try coerceCalcStringToNumberish(pool, number_pool, alloc, list_pool, a);
    const rhs = try coerceCalcStringToNumberish(pool, number_pool, alloc, list_pool, b);
    const lhs_marked = shouldMarkCalcString(pool, a) or shouldMarkCalcString(pool, lhs);
    const rhs_marked = shouldMarkCalcString(pool, b) or shouldMarkCalcString(pool, rhs);
    const mark_result = lhs_marked or rhs_marked or preserve_css_math;
    if (colorArithmeticShouldError(pool, lhs, rhs)) {
        return error.SassError;
    }

    if (lhs.kind() == .number and rhs.kind() == .number) {
        if (combineAddUnits(pool, number_pool, lhs, rhs)) |resolved| {
            return try Value.number(lhs.asF64(number_pool) - resolved.rhs, resolved.unit, number_pool, alloc);
        } else |err| switch (err) {
            error.SassError => {
                const ua = lhs.unitId(number_pool);
                const ub = rhs.unitId(number_pool);
                if (mark_result and shouldPreserveCssMathAdd(pool, ua, ub)) {
                    const sa_num = try formatCalcArithmeticNumber(pool, number_pool, alloc, lhs);
                    defer alloc.free(sa_num);
                    const sb_num = try formatCalcArithmeticNumber(pool, number_pool, alloc, rhs);
                    defer alloc.free(sb_num);
                    const merged_num = try std.fmt.allocPrint(alloc, "{s} - {s}", .{ sa_num, sb_num });
                    defer alloc.free(merged_num);
                    return internCalcString(pool, alloc, merged_num, true);
                }
                return error.SassError;
            },
            else => return err,
        }
    }
    const sa = try valueToArithmeticOperandText(pool, number_pool, alloc, list_pool, color_pool, slash_list_preserve, lhs);
    defer alloc.free(sa);
    const sb = try valueToArithmeticOperandText(pool, number_pool, alloc, list_pool, color_pool, slash_list_preserve, rhs);
    defer alloc.free(sb);
    if (!mark_result and (isUnquotedCalcLikeString(pool, lhs) or isUnquotedCalcLikeString(pool, rhs))) {
        return error.SassError;
    }
    const merged = if (mark_result) blk: {
        const sa_t = std.mem.trim(u8, sa, " \t\r\n");
        const sb_t = std.mem.trim(u8, sb, " \t\r\n");
        const sb_fmt = if (calc_utils.calcExprHasAdditiveOp(sb_t))
            try std.fmt.allocPrint(alloc, "({s})", .{sb_t})
        else
            try alloc.dupe(u8, sb_t);
        defer alloc.free(sb_fmt);
        break :blk try std.fmt.allocPrint(alloc, "{s} - {s}", .{ sa_t, sb_fmt });
    } else try std.fmt.allocPrint(alloc, "{s}-{s}", .{ sa, sb });
    defer alloc.free(merged);
    if (mark_result) return internCalcString(pool, alloc, merged, true);
    const id = try internGeneratedString(pool, merged);
    return Value.string(id, false);
}

fn unitTextLooksComposite(text: []const u8) bool {
    return std.mem.indexOfAny(u8, text, "/*^()") != null;
}

const UnitExprOpVm = enum { mul, div };

fn hasOuterWrappingParensVm(text: []const u8) bool {
    if (text.len < 2 or text[0] != '(' or text[text.len - 1] != ')') return false;
    var depth: usize = 0;
    for (text, 0..) |c, idx| {
        switch (c) {
            '(' => depth += 1,
            ')' => {
                if (depth == 0) return false;
                depth -= 1;
                if (depth == 0 and idx != text.len - 1) return false;
            },
            else => {},
        }
    }
    return depth == 0;
}

fn hasTopLevelUnitOperatorVm(text: []const u8) bool {
    var depth: usize = 0;
    for (text) |c| {
        switch (c) {
            '(' => depth += 1,
            ')' => {
                if (depth == 0) return false;
                depth -= 1;
            },
            '*', '/' => if (depth == 0) return true,
            else => {},
        }
    }
    return false;
}

fn appendUnitTokenFactorsVm(
    alloc: std.mem.Allocator,
    token_raw: []const u8,
    op: UnitExprOpVm,
    numerators: *std.ArrayListUnmanaged([]const u8),
    denominators: *std.ArrayListUnmanaged([]const u8),
) VMError!bool {
    var token = std.mem.trim(u8, token_raw, " \t\r\n");
    if (token.len == 0) return false;

    var reciprocal = false;
    if (std.mem.endsWith(u8, token, "^-1")) {
        reciprocal = true;
        token = std.mem.trim(u8, token[0 .. token.len - 3], " \t\r\n");
    }

    while (hasOuterWrappingParensVm(token)) {
        token = std.mem.trim(u8, token[1 .. token.len - 1], " \t\r\n");
    }
    if (token.len == 0) return false;

    var token_nums: std.ArrayListUnmanaged([]const u8) = .empty;
    defer token_nums.deinit(alloc);
    var token_dens: std.ArrayListUnmanaged([]const u8) = .empty;
    defer token_dens.deinit(alloc);

    if (hasTopLevelUnitOperatorVm(token)) {
        if (!(try appendUnitExprFactorsVm(alloc, token, .mul, &token_nums, &token_dens))) return false;
    } else {
        try token_nums.append(alloc, token);
    }

    const ratio_nums = if (reciprocal) token_dens.items else token_nums.items;
    const ratio_dens = if (reciprocal) token_nums.items else token_dens.items;

    switch (op) {
        .mul => {
            try numerators.appendSlice(alloc, ratio_nums);
            try denominators.appendSlice(alloc, ratio_dens);
        },
        .div => {
            try denominators.appendSlice(alloc, ratio_nums);
            try numerators.appendSlice(alloc, ratio_dens);
        },
    }
    return true;
}

fn appendUnitExprFactorsVm(
    alloc: std.mem.Allocator,
    expr_raw: []const u8,
    start_op: UnitExprOpVm,
    numerators: *std.ArrayListUnmanaged([]const u8),
    denominators: *std.ArrayListUnmanaged([]const u8),
) VMError!bool {
    if (start_op == .div) {
        var local_nums: std.ArrayListUnmanaged([]const u8) = .empty;
        defer local_nums.deinit(alloc);
        var local_dens: std.ArrayListUnmanaged([]const u8) = .empty;
        defer local_dens.deinit(alloc);

        if (!(try appendUnitExprFactorsVm(alloc, expr_raw, .mul, &local_nums, &local_dens))) return false;
        try numerators.appendSlice(alloc, local_dens.items);
        try denominators.appendSlice(alloc, local_nums.items);
        return true;
    }

    const expr = std.mem.trim(u8, expr_raw, " \t\r\n");
    if (expr.len == 0) return false;

    var depth: usize = 0;
    var seg_start: usize = 0;
    var current_op: UnitExprOpVm = .mul;
    var i: usize = 0;
    while (i <= expr.len) : (i += 1) {
        const at_end = i == expr.len;
        if (!at_end) {
            const c = expr[i];
            switch (c) {
                '(' => depth += 1,
                ')' => {
                    if (depth == 0) return false;
                    depth -= 1;
                },
                else => {},
            }
            if (depth == 0 and (c == '*' or c == '/')) {
                const token = std.mem.trim(u8, expr[seg_start..i], " \t\r\n");
                if (token.len == 0) return false;
                if (!(try appendUnitTokenFactorsVm(alloc, token, current_op, numerators, denominators))) {
                    return false;
                }
                current_op = if (c == '*') .mul else .div;
                seg_start = i + 1;
            }
            continue;
        }

        if (depth != 0) return false;
        const token = std.mem.trim(u8, expr[seg_start..i], " \t\r\n");
        if (token.len == 0) return false;
        if (!(try appendUnitTokenFactorsVm(alloc, token, current_op, numerators, denominators))) return false;
    }
    return true;
}

fn appendUnitTextFactors(
    alloc: std.mem.Allocator,
    unit_text: []const u8,
    numerators: *std.ArrayListUnmanaged([]const u8),
    denominators: *std.ArrayListUnmanaged([]const u8),
    divide: bool,
) VMError!void {
    const start_op: UnitExprOpVm = if (divide) .div else .mul;
    const ok = try appendUnitExprFactorsVm(alloc, unit_text, start_op, numerators, denominators);
    if (!ok) return error.SassError;
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
            _ = numerators.orderedRemove(i);
            _ = denominators.orderedRemove(j);
            matched = true;
            break;
        }
        if (!matched) {
            j = 0;
            while (j < denominators.items.len) : (j += 1) {
                if (convertComparableUnitValueRuntime(1.0, n, denominators.items[j])) |factor| {
                    _ = numerators.orderedRemove(i);
                    _ = denominators.orderedRemove(j);
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
) VMError!void {
    var extra: usize = if (items.len > 0) items.len - 1 else 0;
    for (items) |unit| extra += unit.len;
    try out.ensureTotalCapacity(alloc, out.items.len + extra);
    for (items, 0..) |unit, idx| {
        if (idx != 0) try out.append(alloc, '*');
        try out.appendSlice(alloc, unit);
    }
}

fn buildUnitDescriptionFromFactorsVm(
    alloc: std.mem.Allocator,
    numerators: []const []const u8,
    denominators: []const []const u8,
) VMError!?[]u8 {
    if (numerators.len == 0 and denominators.len == 0) return null;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

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
) VMError!?CombinedUnitsRuntime {
    std.debug.assert(ua != .none and ub != .none);
    const ua_text = pool.get(ua);
    const ub_text = pool.get(ub);

    var numerators: std.ArrayListUnmanaged([]const u8) = .empty;
    defer numerators.deinit(alloc);
    var denominators: std.ArrayListUnmanaged([]const u8) = .empty;
    defer denominators.deinit(alloc);

    appendUnitTextFactors(alloc, ua_text, &numerators, &denominators, false) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    appendUnitTextFactors(alloc, ub_text, &numerators, &denominators, true) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };

    const scale = simplifyUnitFactorsCaseInsensitive(&numerators, &denominators);

    const combined_text = try buildUnitDescriptionFromFactorsVm(alloc, numerators.items, denominators.items);
    if (combined_text == null) {
        return .{ .unit = .none, .factor = scale };
    }
    defer alloc.free(combined_text.?);
    return .{
        .unit = try pool.intern(combined_text.?),
        .factor = scale,
    };
}

fn combineUnitIdsForMul(
    pool: *InternPool,
    alloc: std.mem.Allocator,
    ua: InternId,
    ub: InternId,
) VMError!?CombinedUnitsRuntime {
    std.debug.assert(ua != .none and ub != .none);
    const ua_text = pool.get(ua);
    const ub_text = pool.get(ub);

    var numerators: std.ArrayListUnmanaged([]const u8) = .empty;
    defer numerators.deinit(alloc);
    var denominators: std.ArrayListUnmanaged([]const u8) = .empty;
    defer denominators.deinit(alloc);

    appendUnitTextFactors(alloc, ua_text, &numerators, &denominators, false) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    appendUnitTextFactors(alloc, ub_text, &numerators, &denominators, false) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };

    const scale = simplifyUnitFactorsCaseInsensitive(&numerators, &denominators);

    const combined_text = try buildUnitDescriptionFromFactorsVm(alloc, numerators.items, denominators.items);
    if (combined_text == null) {
        return .{ .unit = .none, .factor = scale };
    }
    defer alloc.free(combined_text.?);
    return .{
        .unit = try pool.intern(combined_text.?),
        .factor = scale,
    };
}

fn mulValues(
    pool: *InternPool,
    number_pool: *NumberPool,
    alloc: std.mem.Allocator,
    list_pool: *const std.ArrayListUnmanaged([]Value),
    color_pool: *const ColorPool,
    slash_list_preserve: ?*const std.AutoHashMapUnmanaged(u32, void),
    a: Value,
    b: Value,
    preserve_css_math: bool,
) VMError!Value {
    const lhs = try coerceCalcStringToNumberish(pool, number_pool, alloc, list_pool, a);
    const rhs = try coerceCalcStringToNumberish(pool, number_pool, alloc, list_pool, b);
    const lhs_marked = shouldMarkCalcString(pool, a) or shouldMarkCalcString(pool, lhs);
    const rhs_marked = shouldMarkCalcString(pool, b) or shouldMarkCalcString(pool, rhs);
    const mark_result = lhs_marked or rhs_marked or preserve_css_math;
    if (colorArithmeticShouldError(pool, lhs, rhs)) {
        return error.SassError;
    }

    if (lhs.kind() == .number and rhs.kind() == .number) {
        const ua = lhs.unitId(number_pool);
        const ub = rhs.unitId(number_pool);
        const lf = lhs.asF64(number_pool);
        const rf = rhs.asF64(number_pool);
        if (ua == .none and ub == .none) return try Value.number(lf * rf, .none, number_pool, alloc);
        if (ua == .none) return try Value.number(lf * rf, ub, number_pool, alloc);
        if (ub == .none) return try Value.number(lf * rf, ua, number_pool, alloc);
        if (try combineUnitIdsForMul(pool, alloc, ua, ub)) |combined| {
            return try Value.number(lf * rf * combined.factor, combined.unit, number_pool, alloc);
        }
    }
    if (mark_result) {
        const sa_raw = try valueToArithmeticOperandText(pool, number_pool, alloc, list_pool, color_pool, slash_list_preserve, lhs);
        defer alloc.free(sa_raw);
        const sb_raw = try valueToArithmeticOperandText(pool, number_pool, alloc, list_pool, color_pool, slash_list_preserve, rhs);
        defer alloc.free(sb_raw);
        const sa_t = std.mem.trim(u8, sa_raw, " \t\r\n");
        const sb_t = std.mem.trim(u8, sb_raw, " \t\r\n");
        const sa = if (calcOperandNeedsParensForMultiplicative(sa_t))
            try std.fmt.allocPrint(alloc, "({s})", .{sa_t})
        else
            try alloc.dupe(u8, sa_t);
        defer alloc.free(sa);
        const sb = if (calcOperandNeedsParensForMultiplicative(sb_t))
            try std.fmt.allocPrint(alloc, "({s})", .{sb_t})
        else
            try alloc.dupe(u8, sb_t);
        defer alloc.free(sb);
        const merged = try std.fmt.allocPrint(alloc, "{s} * {s}", .{ sa, sb });
        defer alloc.free(merged);
        return internCalcString(pool, alloc, merged, true);
    }
    return error.SassError;
}

fn divValues(
    pool: *InternPool,
    number_pool: *NumberPool,
    alloc: std.mem.Allocator,
    list_pool: *const std.ArrayListUnmanaged([]Value),
    color_pool: *const ColorPool,
    slash_list_preserve: ?*const std.AutoHashMapUnmanaged(u32, void),
    a: Value,
    b: Value,
    preserve_css_math: bool,
    slash_dep: ?deprecation_mod.SlashDivDeprecationSite,
) VMError!Value {
    const lhs = try coerceCalcStringToNumberish(pool, number_pool, alloc, list_pool, a);
    const rhs = try coerceCalcStringToNumberish(pool, number_pool, alloc, list_pool, b);
    const lhs_marked = shouldMarkCalcString(pool, a) or shouldMarkCalcString(pool, lhs);
    const rhs_marked = shouldMarkCalcString(pool, b) or shouldMarkCalcString(pool, rhs);
    const mark_result = lhs_marked or rhs_marked or preserve_css_math;
    if (colorArithmeticShouldError(pool, lhs, rhs)) {
        return error.SassError;
    }

    if (lhs.kind() == .number and rhs.kind() == .number) {
        if (slash_dep) |site| {
            try deprecation_mod.emitDeprecation(
                site.opts,
                .slash_div,
                "Using / for division is deprecated and will be removed in official Sass CLI 3.0.0.",
                site.path,
                site.line,
                site.col,
            );
        }
        const ua = lhs.unitId(number_pool);
        const ub = rhs.unitId(number_pool);

        const numerator = lhs.asF64(number_pool);
        var denominator = rhs.asF64(number_pool);
        var factor: f64 = 1.0;
        var out_unit: InternId = .none;

        if (ua == .none and ub == .none) {
            out_unit = .none;
        } else if (ub == .none) {
            out_unit = ua;
        } else if (ua != .none and std.ascii.eqlIgnoreCase(pool.get(ua), pool.get(ub))) {
            out_unit = .none;
        } else if (ua != .none) {
            if (convertComparableUnitValueRuntime(denominator, pool.get(ub), pool.get(ua))) |converted| {
                denominator = converted;
                out_unit = .none;
            } else if (try combineUnitIdsForOp(pool, alloc, ua, ub)) |combined| {
                factor = combined.factor;
                out_unit = combined.unit;
            } else {
                out_unit = ua;
            }
        } else {
            // unitless / unit
            var numerators: std.ArrayListUnmanaged([]const u8) = .empty;
            defer numerators.deinit(alloc);
            var denominators: std.ArrayListUnmanaged([]const u8) = .empty;
            defer denominators.deinit(alloc);
            appendUnitTextFactors(alloc, pool.get(ub), &numerators, &denominators, true) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    const sa_raw = try valueToArithmeticOperandText(pool, number_pool, alloc, list_pool, color_pool, slash_list_preserve, lhs);
                    defer alloc.free(sa_raw);
                    const sb_raw = try valueToArithmeticOperandText(pool, number_pool, alloc, list_pool, color_pool, slash_list_preserve, rhs);
                    defer alloc.free(sb_raw);
                    const sa = try simplifySlashOperandText(pool, number_pool, alloc, sa_raw);
                    defer alloc.free(sa);
                    const sb = try simplifySlashOperandText(pool, number_pool, alloc, sb_raw);
                    defer alloc.free(sb);
                    const merged = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ sa, sb });
                    defer alloc.free(merged);
                    const id = try internGeneratedString(pool, merged);
                    return Value.string(id, false);
                },
            };
            factor = simplifyUnitFactorsCaseInsensitive(&numerators, &denominators);
            const combined_text = try buildUnitDescriptionFromFactorsVm(alloc, numerators.items, denominators.items);
            if (combined_text) |text| {
                defer alloc.free(text);
                out_unit = try pool.intern(text);
            } else {
                out_unit = .none;
            }
        }

        if (denominator == 0) {
            return try Value.number(numerator / denominator, out_unit, number_pool, alloc);
        }
        return try Value.number((numerator / denominator) * factor, out_unit, number_pool, alloc);
    }
    const sa_raw = try valueToArithmeticOperandText(pool, number_pool, alloc, list_pool, color_pool, slash_list_preserve, lhs);
    defer alloc.free(sa_raw);
    const sb_raw = try valueToArithmeticOperandText(pool, number_pool, alloc, list_pool, color_pool, slash_list_preserve, rhs);
    defer alloc.free(sb_raw);
    const sa = try simplifySlashOperandText(pool, number_pool, alloc, sa_raw);
    defer alloc.free(sa);
    const sb = try simplifySlashOperandText(pool, number_pool, alloc, sb_raw);
    defer alloc.free(sb);
    if (mark_result) {
        const sa_t = std.mem.trim(u8, sa, " \t\r\n");
        const sb_t = std.mem.trim(u8, sb, " \t\r\n");
        const sa_fmt = if (calcOperandNeedsParensForMultiplicative(sa_t))
            try std.fmt.allocPrint(alloc, "({s})", .{sa_t})
        else
            try alloc.dupe(u8, sa_t);
        defer alloc.free(sa_fmt);
        const sb_needs_parens = calcOperandNeedsParensForMultiplicative(sb_t) or hasTopLevelUnitOperatorVm(sb_t);
        const sb_fmt = if (sb_needs_parens)
            try std.fmt.allocPrint(alloc, "({s})", .{sb_t})
        else
            try alloc.dupe(u8, sb_t);
        defer alloc.free(sb_fmt);
        const merged_calc = try std.fmt.allocPrint(alloc, "{s} / {s}", .{ sa_fmt, sb_fmt });
        defer alloc.free(merged_calc);
        return internCalcString(pool, alloc, merged_calc, true);
    }
    const merged = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ sa, sb });
    defer alloc.free(merged);
    const id = try internGeneratedString(pool, merged);
    return Value.string(id, false);
}

fn modValues(
    pool: *InternPool,
    number_pool: *NumberPool,
    alloc: std.mem.Allocator,
    list_pool: *const std.ArrayListUnmanaged([]Value),
    _: *const ColorPool,
    _: ?*const std.AutoHashMapUnmanaged(u32, void),
    a: Value,
    b: Value,
) VMError!Value {
    const lhs = try coerceCalcStringToNumberish(pool, number_pool, alloc, list_pool, a);
    const rhs = try coerceCalcStringToNumberish(pool, number_pool, alloc, list_pool, b);
    if (colorArithmeticShouldError(pool, lhs, rhs)) {
        return error.SassError;
    }

    if (lhs.kind() == .number and rhs.kind() == .number) {
        const ua = lhs.unitId(number_pool);
        const ub = rhs.unitId(number_pool);
        if (ua == ub or ua == .none or ub == .none) {
            const unit = if (ua != .none) ua else ub;
            const av = lhs.asF64(number_pool);
            const bv = rhs.asF64(number_pool);
            if (std.math.isInf(bv)) {
                // sass-spec operators/modulo.hrx:
                // finite % +/-infinity returns dividends only with the same sign, NaN with different signs.
                if (std.math.isNan(av)) return try Value.number(std.math.nan(f64), unit, number_pool, alloc);
                if (std.math.signbit(av) == std.math.signbit(bv)) return try Value.number(av, unit, number_pool, alloc);
                return try Value.number(std.math.nan(f64), unit, number_pool, alloc);
            }
            return try Value.number(@mod(av, bv), unit, number_pool, alloc);
        }
    }
    return error.SassError;
}

fn valueToOpString(
    pool: *InternPool,
    number_pool: *NumberPool,
    alloc: std.mem.Allocator,
    list_pool: *const std.ArrayListUnmanaged([]Value),
    color_pool: *const ColorPool,
    callable_payload_pool: *const value_mod.CallablePayloadPool,
    v: Value,
) VMError![]const u8 {
    if (v.kind() == .nil) return try alloc.dupe(u8, "");
    if (v.kind() == .boolean) return try alloc.dupe(u8, if (v.p64Of() != 0) "true" else "false");
    if (v.isNumber()) return try formatNumberValue(pool, number_pool, alloc, v);
    if (v.isString()) return try alloc.dupe(u8, calc_utils.stripCalcArgMarker(pool.get(v.stringIntern())));

    if (v.kind() == .list) {
        const items = list_pool.items[v.listHandle()];
        if (items.len == 0) {
            return try alloc.dupe(u8, if (v.listBracketed(value_mod.empty_list_meta_pool)) "[]" else "()");
        }
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(alloc);
        if (v.listBracketed(value_mod.empty_list_meta_pool)) try out.append(alloc, '[');
        const sep = switch (v.listSeparator(value_mod.empty_list_meta_pool)) {
            .slash => "/",
            .comma => ", ",
            .space, .undecided => " ",
        };
        var wrote_any = false;
        for (items) |item| {
            if (item.kind() == .nil) continue;
            if (wrote_any) try out.appendSlice(alloc, sep);
            const item_text = try valueToOpString(pool, number_pool, alloc, list_pool, color_pool, callable_payload_pool, item);
            defer alloc.free(item_text);
            try out.appendSlice(alloc, item_text);
            wrote_any = true;
        }
        if (v.listBracketed(value_mod.empty_list_meta_pool)) try out.append(alloc, ']');
        return try out.toOwnedSlice(alloc);
    }

    if (v.kind() == .color) {
        // official Sass CLI string-concat / op-string uses the color's CSS form
        //(named color / short hex / rgb() -- whichever `Color.toString()`
        // produces), not a fixed 6-digit hex.
        const entry = v.colorEntry(color_pool).*;
        return color_format.formatColorCss(alloc, entry) catch error.OutOfMemory;
    }

    if (v.kind() == .callable) {
        if (v.callableIsCss(callable_payload_pool) and v.callableNameIntern(callable_payload_pool) != .none) {
            return try alloc.dupe(u8, pool.get(v.callableNameIntern(callable_payload_pool)));
        }
        return error.SassError;
    }

    return try alloc.dupe(u8, "()");
}

fn sourceOffsetToLineColVm(line_starts: []const u32, source_len: u32, offset: u32) struct { line: u32, col: u32 } {
    if (line_starts.len == 0) return .{ .line = 0, .col = 0 };
    const clamped = @min(offset, source_len);
    var lo: usize = 0;
    var hi: usize = line_starts.len;
    while (lo + 1 < hi) {
        const mid = lo + (hi - lo) / 2;
        if (line_starts[mid] <= clamped) {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    const line_start = line_starts[lo];
    return .{
        .line = @intCast(lo),
        .col = clamped - line_start,
    };
}

fn valueToArithmeticOperandText(
    pool: *InternPool,
    number_pool: *NumberPool,
    alloc: std.mem.Allocator,
    list_pool: *const std.ArrayListUnmanaged([]Value),
    color_pool: *const ColorPool,
    slash_list_preserve: ?*const std.AutoHashMapUnmanaged(u32, void),
    v: Value,
) VMError![]const u8 {
    if (v.kind() == .string and !v.stringQuoted(value_mod.empty_string_flags_pool)) {
        return try alloc.dupe(u8, calc_utils.stripCalcArgMarker(pool.get(v.stringIntern())));
    }
    if (v.kind() == .number) {
        const n = v.asF64(number_pool);
        const unit_id = v.unitId(number_pool);
        const unit = if (unit_id == .none) null else pool.get(unit_id);
        if (std.math.isNan(n)) {
            if (unit) |u| {
                if (unitFactorCanAttachDirectly(u)) {
                    return std.fmt.allocPrint(alloc, "NaN * 1{s}", .{u}) catch error.OutOfMemory;
                }
                return std.fmt.allocPrint(alloc, "NaN * {s}", .{u}) catch error.OutOfMemory;
            }
            return try alloc.dupe(u8, "NaN");
        }
        if (std.math.isInf(n)) {
            const keyword = if (n < 0) "-infinity" else "infinity";
            if (unit) |u| {
                if (unitFactorCanAttachDirectly(u)) {
                    return std.fmt.allocPrint(alloc, "{s} * 1{s}", .{ keyword, u }) catch error.OutOfMemory;
                }
                return std.fmt.allocPrint(alloc, "{s} * {s}", .{ keyword, u }) catch error.OutOfMemory;
            }
            return try alloc.dupe(u8, keyword);
        }
        return try formatNumberValue(pool, number_pool, alloc, v);
    }
    const id = try valueToInternIdDecl(pool, number_pool, alloc, list_pool, color_pool, slash_list_preserve, v, false);
    return try alloc.dupe(u8, pool.get(id));
}

fn isColorLikeValue(pool: *InternPool, v: Value) bool {
    if (v.kind() == .color) return true;
    if (v.isString()) {
        if (v.stringQuoted(value_mod.empty_string_flags_pool)) return false;
        if (!v.stringNamedColorLiteral(value_mod.empty_string_flags_pool)) return false;
        return color_mod.lookupNamedColor(pool.get(v.stringIntern())) != null;
    }
    return false;
}

fn colorArithmeticShouldError(pool: *InternPool, lhs: Value, rhs: Value) bool {
    const lhs_color = isColorLikeValue(pool, lhs);
    const rhs_color = isColorLikeValue(pool, rhs);
    if (!lhs_color and !rhs_color) return false;
    if (lhs_color and rhs_color) return true;
    if (lhs_color) return rhs.kind() != .string or rhs_color;
    return lhs.kind() != .string or lhs_color;
}

fn unitLooksCompound(unit_text: []const u8) bool {
    const trimmed = std.mem.trim(u8, unit_text, " \t\r\n");
    if (trimmed.len == 0) return false;
    return std.mem.indexOfScalar(u8, trimmed, '*') != null or
        std.mem.indexOfScalar(u8, trimmed, '/') != null or
        std.mem.endsWith(u8, trimmed, "^-1");
}

fn unitFactorCanAttachDirectly(unit: []const u8) bool {
    const trimmed = std.mem.trim(u8, unit, " \t\r\n");
    return isSimpleUnitIdentifier(trimmed);
}

fn appendCalcUnitFactor(
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    op: enum { mul, div },
    factor: []const u8,
) VMError!void {
    try out.appendSlice(alloc, if (op == .mul) " * " else " / ");
    if (unitFactorCanAttachDirectly(factor)) {
        try out.append(alloc, '1');
    }
    try out.appendSlice(alloc, factor);
}

fn appendCalcWithCompoundUnit(
    alloc: std.mem.Allocator,
    value: f64,
    numerators: []const []const u8,
    denominators: []const []const u8,
) VMError![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);

    if (std.math.isNan(value)) {
        try out.appendSlice(alloc, "calc(NaN");
        for (numerators) |unit| {
            try appendCalcUnitFactor(&out, alloc, .mul, unit);
        }
        for (denominators) |unit| {
            try appendCalcUnitFactor(&out, alloc, .div, unit);
        }
        try out.append(alloc, ')');
        return out.toOwnedSlice(alloc);
    }

    if (std.math.isInf(value)) {
        try out.appendSlice(alloc, if (value < 0) "calc(-infinity" else "calc(infinity");
        for (numerators) |unit| {
            try appendCalcUnitFactor(&out, alloc, .mul, unit);
        }
        for (denominators) |unit| {
            try appendCalcUnitFactor(&out, alloc, .div, unit);
        }
        try out.append(alloc, ')');
        return out.toOwnedSlice(alloc);
    }

    const core = value_format.formatNumberCore(alloc, value) catch return error.OutOfMemory;
    defer alloc.free(core);

    try out.appendSlice(alloc, "calc(");
    try out.appendSlice(alloc, core);

    var numerator_index: usize = 0;
    if (numerators.len > 0 and unitFactorCanAttachDirectly(numerators[0])) {
        try out.appendSlice(alloc, numerators[0]);
        numerator_index = 1;
    }
    for (numerators[numerator_index..]) |unit| {
        try appendCalcUnitFactor(&out, alloc, .mul, unit);
    }
    for (denominators) |unit| {
        try appendCalcUnitFactor(&out, alloc, .div, unit);
    }
    try out.append(alloc, ')');
    return out.toOwnedSlice(alloc);
}

fn formatNumberValue(pool: *const InternPool, number_pool: *NumberPool, alloc: std.mem.Allocator, v: Value) VMError![]const u8 {
    std.debug.assert(v.kind() == .number);
    const n = v.asF64(number_pool);
    const unit_id = v.unitId(number_pool);
    const raw_unit_text = if (unit_id == .none) null else pool.get(unit_id);
    const preserve_simple_escaped_punctuation = if (raw_unit_text) |unit|
        numberUnitShouldPreserveSimpleEscapedPunctuation(unit)
    else
        false;
    const unit_text = if (raw_unit_text) |unit| blk: {
        if (preserve_simple_escaped_punctuation) break :blk unit;
        const unescaped = try css_utils.unescapeSassIdentifier(alloc, unit);
        break :blk unescaped;
    } else null;
    defer if (unit_text) |unit| {
        if (raw_unit_text) |raw| {
            if (unit.ptr != raw.ptr) alloc.free(@constCast(unit));
        }
    };
    if (unit_text) |unit| {
        if (!preserve_simple_escaped_punctuation and unitLooksCompound(unit)) {
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

fn numberUnitShouldPreserveSimpleEscapedPunctuation(unit: []const u8) bool {
    var i: usize = 0;
    while (i < unit.len) : (i += 1) {
        if (unit[i] != '\\') continue;
        if (i + 1 >= unit.len) return false;
        const next = unit[i + 1];
        if (next == '\n' or next == '\r' or next == '\x0c') return false;
        if (std.ascii.isHex(next)) {
            i += 1;
            var count: u8 = 1;
            while (i + 1 < unit.len and count < 6 and std.ascii.isHex(unit[i + 1])) {
                i += 1;
                count += 1;
            }
            if (i + 1 < unit.len and cssEscapeWhitespace(unit[i + 1])) i += 1;
            continue;
        }
        if (!std.ascii.isAlphanumeric(next) and next != '_' and next != '-') return true;
        i += 1;
    }
    return false;
}

fn formatInspectionValueForArgMessage(self: *VM, v: Value) VMError![]const u8 {
    if (v.kind() == .number) {
        // Preserve VM-side compound-unit rendering (`calc(...)`) for diagnostics.
        return formatNumberValue(self.intern_pool, &self.number_pool, self.allocator, v);
    }
    var inspect_ctx: value_inspect.Context = .{
        .allocator = self.allocator,
        .intern_pool = self.intern_pool,
        .number_pool = &self.number_pool,
        .list_pool = &self.list_pool,
        .list_meta_pool = &self.list_meta_pool,
        .color_pool = self.color_pool,
        .callable_payload_pool = &self.callable_payload_pool,
    };
    return value_inspect.formatValueForArgMismatch(&inspect_ctx, v) catch error.OutOfMemory;
}

fn recordArgumentTypeMismatchMessage(self: *VM, param_name: []const u8, value: Value, expected: []const u8) void {
    const rendered = formatInspectionValueForArgMessage(self, value) catch return;
    defer self.allocator.free(rendered);
    const article = value_inspect.indefiniteArticle(expected);
    const msg = std.fmt.allocPrint(self.allocator, "${s}: {s} is not {s} {s}.", .{ param_name, rendered, article, expected }) catch return;
    defer self.allocator.free(msg);
    error_format.setContextMessage(msg);
}

fn selectorSourceHasNewline(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, '\n') != null or std.mem.indexOfScalar(u8, s, '\r') != null;
}

fn selectorSourceHasTopLevelCommaNewline(s: []const u8) bool {
    var depth: u32 = 0;
    var in_string: u8 = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < s.len) {
                i += 1;
                continue;
            }
            if (c == in_string) in_string = 0;
            continue;
        }
        switch (c) {
            '"', '\'' => in_string = c,
            '(', '[' => depth += 1,
            ')', ']' => if (depth > 0) {
                depth -= 1;
            },
            ',' => if (depth == 0) {
                var j = i + 1;
                while (j < s.len and (s[j] == ' ' or s[j] == '\t' or s[j] == '\n' or s[j] == '\r')) : (j += 1) {
                    if (s[j] == '\n' or s[j] == '\r') return true;
                }
                var k = i;
                while (k > 0 and (s[k - 1] == ' ' or s[k - 1] == '\t' or s[k - 1] == '\n' or s[k - 1] == '\r')) : (k -= 1) {
                    if (s[k - 1] == '\n' or s[k - 1] == '\r') return true;
                }
            },
            else => {},
        }
    }
    return false;
}

fn selectorSimpleHasParentReference(simple: selector_mod.SimpleSelector) bool {
    return switch (simple) {
        .parent => true,
        .pseudo_class => |pseudo| blk: {
            if (pseudo.selector) |inner| break :blk selectorListHasParentReference(inner);
            break :blk false;
        },
        .pseudo_element => |pseudo| blk: {
            if (pseudo.selector) |inner| break :blk selectorListHasParentReference(inner);
            break :blk false;
        },
        else => false,
    };
}

fn selectorComplexHasParentReference(complex: *const selector_mod.ComplexSelector) bool {
    for (complex.components.items) |component| {
        if (component != .compound) continue;
        for (component.compound.simple_selectors.items) |simple| {
            if (selectorSimpleHasParentReference(simple)) return true;
        }
    }
    return false;
}

fn selectorListHasParentReference(list: *const selector_mod.SelectorList) bool {
    for (list.selectors.items) |complex| {
        if (selectorComplexHasParentReference(&complex)) return true;
    }
    return false;
}

fn selectorListToCssWithSeparator(
    alloc: std.mem.Allocator,
    list: *const selector_mod.SelectorList,
    separator: []const u8,
) VMError![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    for (list.selectors.items, 0..) |complex, i| {
        if (i > 0) try buf.appendSlice(alloc, separator);
        const css = selector_mod.complexSelectorToCss(alloc, &complex) catch return error.OutOfMemory;
        defer alloc.free(css);
        try buf.appendSlice(alloc, css);
    }
    return buf.toOwnedSlice(alloc);
}

fn splitRawSelectorList(
    allocator: std.mem.Allocator,
    selector_list: []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
) !void {
    const trimSelectorPartPreserveEscapedSpace = struct {
        fn isWs(c: u8) bool {
            return c == ' ' or c == '\t' or c == '\r' or c == '\n';
        }

        fn isEscapedTrailingSpace(seg: []const u8, space_idx: usize) bool {
            if (seg[space_idx] != ' ' or space_idx == 0) return false;
            var backslashes: usize = 0;
            var i = space_idx;
            while (i > 0 and seg[i - 1] == '\\') : (i -= 1) {
                backslashes += 1;
            }
            return (backslashes & 1) == 1;
        }

        fn trim(seg: []const u8) []const u8 {
            var start: usize = 0;
            while (start < seg.len and isWs(seg[start])) : (start += 1) {}

            var end: usize = seg.len;
            while (end > start and isWs(seg[end - 1])) {
                const idx = end - 1;
                if (isEscapedTrailingSpace(seg, idx)) break;
                end -= 1;
            }
            return seg[start..end];
        }
    };

    var start: usize = 0;
    var depth_paren: i32 = 0;
    var depth_bracket: i32 = 0;
    var i: usize = 0;
    while (i < selector_list.len) : (i += 1) {
        switch (selector_list[i]) {
            '(' => depth_paren += 1,
            ')' => {
                if (depth_paren > 0) depth_paren -= 1;
            },
            '[' => depth_bracket += 1,
            ']' => {
                if (depth_bracket > 0) depth_bracket -= 1;
            },
            ',' => {
                if (depth_paren == 0 and depth_bracket == 0) {
                    const part = trimSelectorPartPreserveEscapedSpace.trim(selector_list[start..i]);
                    if (part.len != 0) try out.append(allocator, part);
                    start = i + 1;
                }
            },
            else => {},
        }
    }
    const tail = trimSelectorPartPreserveEscapedSpace.trim(selector_list[start..]);
    if (tail.len != 0) try out.append(allocator, tail);
}

fn appendRawSelectorListWithSeparator(
    alloc: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    selector_list: []const u8,
    separator: []const u8,
) VMError!void {
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer parts.deinit(alloc);
    splitRawSelectorList(alloc, selector_list, &parts) catch return error.OutOfMemory;
    if (parts.items.len <= 1) {
        try out.appendSlice(alloc, selector_list);
        return;
    }
    for (parts.items, 0..) |part, i| {
        if (i > 0) try out.appendSlice(alloc, separator);
        try out.appendSlice(alloc, part);
    }
}

fn rawSelectorListHasDuplicate(alloc: std.mem.Allocator, sel: []const u8) bool {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer parts.deinit(scratch.allocator());
    splitRawSelectorList(scratch.allocator(), sel, &parts) catch return false;
    for (parts.items, 0..) |part, i| {
        for (parts.items[i + 1 ..]) |other| {
            if (std.mem.eql(u8, part, other)) return true;
        }
    }
    return false;
}

fn combineNestedRuleSelectorRawCartesian(alloc: std.mem.Allocator, parent_sel: []const u8, child_sel: []const u8) VMError![]const u8 {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    var parent_parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer parent_parts.deinit(sa);
    try splitRawSelectorList(sa, parent_sel, &parent_parts);

    var child_parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer child_parts.deinit(sa);
    try splitRawSelectorList(sa, child_sel, &child_parts);

    if (parent_parts.items.len == 0) return alloc.dupe(u8, child_sel) catch error.OutOfMemory;
    if (child_parts.items.len == 0) return alloc.dupe(u8, parent_sel) catch error.OutOfMemory;

    const separator = if (selectorSourceHasNewline(parent_sel) or selectorSourceHasNewline(child_sel)) ",\n" else ", ";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    var estimated: usize = 0;
    if (parent_parts.items.len != 0 and child_parts.items.len != 0) {
        const pair_count = parent_parts.items.len * child_parts.items.len;
        for (parent_parts.items) |parent_part| {
            for (child_parts.items) |child_part| {
                estimated += parent_part.len + 1 + child_part.len;
            }
        }
        if (pair_count > 1) estimated += (pair_count - 1) * separator.len;
    }
    try out.ensureTotalCapacity(alloc, estimated);

    var first = true;
    for (parent_parts.items) |parent_part| {
        for (child_parts.items) |child_part| {
            if (!first) try out.appendSlice(alloc, separator);
            first = false;
            try out.appendSlice(alloc, parent_part);
            try out.append(alloc, ' ');
            try out.appendSlice(alloc, child_part);
        }
    }

    return out.toOwnedSlice(alloc);
}

fn selectorListHasLeadingNamespacePipe(alloc: std.mem.Allocator, selector_list: []const u8) bool {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer parts.deinit(scratch.allocator());
    splitRawSelectorList(scratch.allocator(), selector_list, &parts) catch return false;
    for (parts.items) |part| {
        const trimmed = std.mem.trimStart(u8, part, " \t\r\n");
        if (trimmed.len != 0 and trimmed[0] == '|') return true;
    }
    return false;
}

fn parentSelectorEndsWithExplicitCombinator(parent_sel: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, parent_sel, " \t\r\n");
    if (trimmed.len == 0) return false;
    return switch (trimmed[trimmed.len - 1]) {
        '>', '+', '~' => true,
        else => false,
    };
}

fn childSelectorStartsWithAmpersandCombinator(child_sel: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, child_sel, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '&') return false;

    var i: usize = 1;
    while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t' or trimmed[i] == '\r' or trimmed[i] == '\n')) : (i += 1) {}
    if (i >= trimmed.len) return false;

    return switch (trimmed[i]) {
        '>', '+', '~' => true,
        else => false,
    };
}

fn isSelectorInterpolationIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c >= 0x80;
}

fn quotedSelectorFragmentIsIdentifierLike(raw: []const u8) bool {
    if (raw.len == 0) return true;
    for (raw) |c| {
        if (!isSelectorInterpolationIdentChar(c)) return false;
    }
    return true;
}

fn normalizeSelectorAdjacentQuotedFragments(alloc: std.mem.Allocator, text: []const u8) VMError![]const u8 {
    if (std.mem.indexOfAny(u8, text, "\"'") == null) return text;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var changed = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const q = text[i];
        if (q != '\"' and q != '\'') {
            i += 1;
            continue;
        }

        var j = i + 1;
        var escaped = false;
        var has_escape = false;
        while (j < text.len) : (j += 1) {
            const c = text[j];
            if (escaped) {
                escaped = false;
                has_escape = true;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                has_escape = true;
                continue;
            }
            if (c == q) break;
        }
        if (j >= text.len) break;

        const inner = text[i + 1 .. j];
        const prev_adjacent = i > 0 and (isSelectorInterpolationIdentChar(text[i - 1]) or text[i - 1] == '&');
        const next_adjacent = j + 1 < text.len and isSelectorInterpolationIdentChar(text[j + 1]);
        if (!has_escape and (prev_adjacent or next_adjacent) and quotedSelectorFragmentIsIdentifierLike(inner)) {
            try out.appendSlice(alloc, text[last_emit..i]);
            try out.appendSlice(alloc, inner);
            last_emit = j + 1;
            changed = true;
        }
        i = j + 1;
    }

    if (!changed) {
        out.deinit(alloc);
        return text;
    }
    try out.appendSlice(alloc, text[last_emit..]);
    return try out.toOwnedSlice(alloc);
}

fn normalizeInterpolatedUrlSingleQuotes(alloc: std.mem.Allocator, text: []const u8) VMError![]const u8 {
    if (std.mem.find(u8, text, "url('") == null and
        std.mem.find(u8, text, "URL('") == null and
        std.mem.find(u8, text, "Url('") == null)
    {
        return text;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var changed = false;
    var i: usize = 0;
    while (i < text.len) {
        if ((text[i] == 'u' or text[i] == 'U') and
            i + 4 < text.len and text[i + 3] == '(' and
            std.ascii.eqlIgnoreCase(text[i .. i + 3], "url"))
        {
            const open = i + 3;
            const close = css_utils.findMatchingParen(text, open) orelse {
                try out.append(alloc, text[i]);
                i += 1;
                continue;
            };
            const raw_inner = text[open + 1 .. close];
            const inner = std.mem.trim(u8, raw_inner, " \t\r\n");
            if (inner.len >= 2 and inner[0] == '\'' and inner[inner.len - 1] == '\'') {
                var has_double_quote = false;
                for (inner[1 .. inner.len - 1]) |c| {
                    if (c == '"') {
                        has_double_quote = true;
                        break;
                    }
                }
                if (!has_double_quote) {
                    changed = true;
                    try out.appendSlice(alloc, text[i .. open + 1]);
                    const lead_ws_len: usize = @intCast(@intFromPtr(inner.ptr) - @intFromPtr(raw_inner.ptr));
                    if (lead_ws_len > 0) try out.appendSlice(alloc, raw_inner[0..lead_ws_len]);
                    try out.append(alloc, '"');
                    try out.appendSlice(alloc, inner[1 .. inner.len - 1]);
                    try out.append(alloc, '"');
                    const trail_ws_start = lead_ws_len + inner.len;
                    if (trail_ws_start < raw_inner.len) try out.appendSlice(alloc, raw_inner[trail_ws_start..]);
                    try out.append(alloc, ')');
                    i = close + 1;
                    continue;
                }
            }
        }
        try out.append(alloc, text[i]);
        i += 1;
    }
    if (!changed) {
        out.deinit(alloc);
        return text;
    }
    return try out.toOwnedSlice(alloc);
}

fn normalizeUrlDoubleQuotesWithInnerQuotes(alloc: std.mem.Allocator, text: []const u8) VMError![]const u8 {
    if (std.mem.indexOf(u8, text, "url(\"") == null and
        std.mem.indexOf(u8, text, "URL(\"") == null and
        std.mem.indexOf(u8, text, "Url(\"") == null)
    {
        return text;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var changed = false;
    var i: usize = 0;
    while (i < text.len) {
        if ((text[i] == 'u' or text[i] == 'U') and
            i + 5 < text.len and text[i + 3] == '(' and text[i + 4] == '"' and
            std.ascii.eqlIgnoreCase(text[i .. i + 3], "url"))
        {
            const inner_start = i + 5;
            const close_paren = std.mem.indexOfScalarPos(u8, text, inner_start, ')') orelse {
                try out.append(alloc, text[i]);
                i += 1;
                continue;
            };
            var end_quote = close_paren;
            while (end_quote > inner_start and (text[end_quote - 1] == ' ' or text[end_quote - 1] == '\t' or text[end_quote - 1] == '\r' or text[end_quote - 1] == '\n')) : (end_quote -= 1) {}
            if (end_quote > inner_start and text[end_quote - 1] == '"') {
                const inner = text[inner_start .. end_quote - 1];
                if (std.mem.indexOfScalar(u8, inner, '"') != null and std.mem.indexOfScalar(u8, inner, '\'') == null) {
                    changed = true;
                    try out.appendSlice(alloc, text[i .. i + 4]);
                    try out.append(alloc, '\'');
                    try out.appendSlice(alloc, inner);
                    try out.append(alloc, '\'');
                    try out.appendSlice(alloc, text[end_quote..close_paren]);
                    try out.append(alloc, ')');
                    i = close_paren + 1;
                    continue;
                }
            }
        }
        try out.append(alloc, text[i]);
        i += 1;
    }
    if (!changed) {
        out.deinit(alloc);
        return text;
    }
    return try out.toOwnedSlice(alloc);
}

/// Nested rule: Unify selector parser's `resolveParent` and correctly generate Cartesian product when parent/child has multiple branches.
/// If the source side is a selector list with line breaks, maintain the `,\n` delimiter.
fn combineNestedRuleSelector(alloc: std.mem.Allocator, parent_sel: []const u8, child_sel: []const u8) VMError![]const u8 {
    var parent_owned: ?[]const u8 = null;
    defer if (parent_owned) |owned| alloc.free(@constCast(owned));
    var child_owned: ?[]const u8 = null;
    defer if (child_owned) |owned| alloc.free(@constCast(owned));

    var parent_text = parent_sel;
    const stripped_parent = try selector_helpers_mod.stripSelectorComments(alloc, parent_sel);
    if (!(stripped_parent.ptr == parent_sel.ptr and stripped_parent.len == parent_sel.len)) {
        parent_text = stripped_parent;
        parent_owned = stripped_parent;
    }

    var child_text = child_sel;
    const stripped_child = try selector_helpers_mod.stripSelectorComments(alloc, child_sel);
    if (!(stripped_child.ptr == child_sel.ptr and stripped_child.len == child_sel.len)) {
        child_text = stripped_child;
        child_owned = stripped_child;
    }

    if (parentSelectorEndsWithExplicitCombinator(parent_text) and childSelectorStartsWithAmpersandCombinator(child_text)) {
        return expandAmpSelector(alloc, parent_text, child_text);
    }
    if (std.mem.indexOfScalar(u8, child_text, '&') == null and selectorListHasLeadingNamespacePipe(alloc, child_text)) {
        return combineNestedRuleSelectorRawCartesian(alloc, parent_text, child_text);
    }
    if (std.mem.indexOfScalar(u8, child_text, '&') == null and rawSelectorListHasDuplicate(alloc, parent_text)) {
        return combineNestedRuleSelectorRawCartesian(alloc, parent_text, child_text);
    }
    if (std.mem.indexOfScalar(u8, child_text, '&') == null and std.mem.indexOf(u8, parent_text, "\\ ") != null) {
        return combineNestedRuleSelectorRawCartesian(alloc, parent_text, child_text);
    }

    var parent = selector_mod.parse(alloc, parent_text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return combineNestedRuleSelectorLegacy(alloc, parent_text, child_text),
    };
    defer parent.deinit();

    var child = selector_mod.parse(alloc, child_text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return combineNestedRuleSelectorLegacy(alloc, parent_text, child_text),
    };
    defer child.deinit();

    var resolved = selector_mod.resolveParent(alloc, &child, &parent) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SassError,
    };
    defer resolved.deinit();

    if (std.mem.indexOfScalar(u8, child_text, '&') == null and
        resolved.selectors.items.len == parent.selectors.items.len * child.selectors.items.len)
    {
        // If child does not have `&` (resolveParent with canResolveParentParentMajor path
        // propagate returns early with `hasParentReference`)
        // Set newline flag in the same per-item rule.
        var out_idx: usize = 0;
        for (parent.selectors.items, 0..) |parent_complex, parent_idx| {
            const parent_sep_newline = parent_idx > 0 and parent_complex.leading_separator_has_newline;
            for (child.selectors.items, 0..) |child_complex, child_idx| {
                const child_sep_newline = child_idx > 0 and child_complex.leading_separator_has_newline;
                resolved.selectors.items[out_idx].leading_separator_has_newline = if (out_idx == 0)
                    false
                else if (child_idx == 0)
                    parent_sep_newline
                else if (parent_sep_newline)
                    true
                else
                    child_sep_newline; // child has no `&`, so no-amp rule simplifies to child_sep_newline
                out_idx += 1;
            }
        }
    }

    const css = selector_mod.toCss(alloc, &resolved) catch return error.OutOfMemory;
    // fallback: resolveParent does not go through propagate path and newline flag of all items
    // remain false (e.g. path with canResolveParentParentMajor=false or number of child items
    //transformation that does not match parentxchild) and there is a top-level newline on the source side,
    // Only if all items on the child side are descendant-style that does not include `&`,
    // Re-append `,\n` with traditional global override. Does not apply to mixed list
    // (This is inconsistent with official Sass CLI's per-item rule).
    const child_newline_requires_preserve =
        selectorSourceHasTopLevelCommaNewline(child_text) and !selectorListHasParentReference(&child);
    if (resolved.selectors.items.len > 1 and
        (selectorSourceHasTopLevelCommaNewline(parent_text) or child_newline_requires_preserve) and
        std.mem.indexOfScalar(u8, css, '\n') == null and
        std.mem.indexOfScalar(u8, css, '\r') == null)
    {
        alloc.free(@constCast(css));
        return selectorListToCssWithSeparator(alloc, &resolved, ",\n");
    }
    return css;
}

/// Fallback: Stage 1a compatible simple join for selectors not accepted by parser.
fn combineNestedRuleSelectorLegacy(alloc: std.mem.Allocator, parent_sel: []const u8, child_sel: []const u8) VMError![]const u8 {
    if (std.mem.indexOfScalar(u8, child_sel, '&') != null) {
        return expandAmpSelector(alloc, parent_sel, child_sel);
    }
    if (std.mem.indexOfScalar(u8, parent_sel, ',') == null) {
        return std.fmt.allocPrint(alloc, "{s} {s}", .{ parent_sel, child_sel }) catch error.OutOfMemory;
    }
    var iter = std.mem.splitSequence(u8, parent_sel, ",");
    var joined: std.ArrayListUnmanaged(u8) = .empty;
    defer joined.deinit(alloc);
    var first = true;
    while (iter.next()) |raw_seg| {
        const seg = std.mem.trimStart(u8, raw_seg, " \t\n\r");
        if (seg.len == 0) continue;
        if (!first) try joined.appendSlice(alloc, ", ");
        try joined.ensureUnusedCapacity(alloc, seg.len + 1 + child_sel.len);
        joined.appendSliceAssumeCapacity(seg);
        joined.appendAssumeCapacity(' ');
        joined.appendSliceAssumeCapacity(child_sel);
        first = false;
    }
    if (joined.items.len == 0) return alloc.dupe(u8, child_sel) catch error.OutOfMemory;
    return joined.toOwnedSlice(alloc);
}

/// Treat `parent_sel` as a comma-separated compound selector and replace `&` in `child_sel` with each segment (Stage 1a simple version).
fn expandAmpSelector(alloc: std.mem.Allocator, parent_sel: []const u8, child_sel: []const u8) VMError![]const u8 {
    if (std.mem.indexOfScalar(u8, child_sel, '&') == null)
        return alloc.dupe(u8, child_sel) catch error.OutOfMemory;

    var parent_count: usize = 0;
    {
        var count_iter = std.mem.splitSequence(u8, parent_sel, ",");
        while (count_iter.next()) |raw_seg| {
            if (std.mem.trim(u8, raw_seg, " \t\r\n").len != 0) parent_count += 1;
        }
    }

    var iter = std.mem.splitSequence(u8, parent_sel, ",");
    var joined: std.ArrayListUnmanaged(u8) = .empty;
    defer joined.deinit(alloc);
    var first: bool = true;
    const child_has_newline = selectorSourceHasNewline(child_sel);
    while (iter.next()) |raw_seg| {
        const seg = std.mem.trim(u8, raw_seg, " \t\n\r");
        if (seg.len == 0) continue;
        if (!first) try joined.appendSlice(alloc, ", ");
        const replaced = try replaceAmpInOne(alloc, seg, child_sel);
        defer alloc.free(replaced);
        if (parent_count == 1 and child_has_newline) {
            try appendRawSelectorListWithSeparator(alloc, &joined, replaced, ", ");
        } else {
            try joined.appendSlice(alloc, replaced);
        }
        first = false;
    }
    if (joined.items.len == 0)
        return alloc.dupe(u8, child_sel) catch error.OutOfMemory;
    return joined.toOwnedSlice(alloc);
}

fn replaceAmpInOne(alloc: std.mem.Allocator, parent_one: []const u8, child_sel: []const u8) VMError![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    var rest = child_sel;
    while (rest.len > 0) {
        if (std.mem.indexOfScalar(u8, rest, '&')) |pos| {
            try out.appendSlice(alloc, rest[0..pos]);
            try out.appendSlice(alloc, parent_one);
            rest = rest[pos + 1 ..];
        } else {
            try out.appendSlice(alloc, rest);
            break;
        }
    }
    return out.toOwnedSlice(alloc);
}

fn isBareUnquotedParentSelectorValue(pool: *const InternPool, v: Value) bool {
    if (v.kind() != .string or v.stringQuoted(value_mod.empty_string_flags_pool)) return false;
    return std.mem.eql(u8, pool.get(v.stringIntern()), "&");
}

fn isEscapedSelectorCharacter(text: []const u8, index: usize) bool {
    if (index == 0) return false;
    var backslashes: usize = 0;
    var i = index;
    while (i > 0) {
        i -= 1;
        if (text[i] != '\\') break;
        backslashes += 1;
    }
    return (backslashes % 2) == 1;
}

fn selectorHasAmpersandWithSuffixLegacy(selector: []const u8) bool {
    var in_string: u8 = 0;
    var bracket_depth: u32 = 0;
    var paren_depth: u32 = 0;
    for (selector, 0..) |c, i| {
        if (isEscapedSelectorCharacter(selector, i)) continue;
        if (in_string != 0) {
            if (c == in_string) in_string = 0;
            continue;
        }
        switch (c) {
            '"', '\'' => in_string = c,
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '&' => {
                if (bracket_depth == 0 and paren_depth == 0 and i + 1 < selector.len) {
                    const next = selector[i + 1];
                    if (std.ascii.isAlphanumeric(next) or next == '-' or next == '_') return true;
                }
            },
            else => {},
        }
    }
    return false;
}

fn selectorHasAtSignLegacy(selector: []const u8) bool {
    var in_string: u8 = 0;
    var bracket_depth: u32 = 0;
    var paren_depth: u32 = 0;
    var i: usize = 0;
    while (i < selector.len) : (i += 1) {
        const c = selector[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < selector.len) {
                i += 1;
                continue;
            }
            if (c == in_string) in_string = 0;
            continue;
        }
        switch (c) {
            '"', '\'' => in_string = c,
            '\\' => {
                if (i + 1 < selector.len) i += 1;
            },
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '@' => {
                if (bracket_depth == 0 and paren_depth == 0) return true;
            },
            else => {},
        }
    }
    return false;
}

fn validateAmpersandPositionLegacy(selector: []const u8) VMError!void {
    var i: usize = 0;
    var in_string: u8 = 0;
    var paren_depth: u32 = 0;
    while (i < selector.len) : (i += 1) {
        const c = selector[i];
        if (isEscapedSelectorCharacter(selector, i)) continue;
        if (in_string != 0) {
            if (c == in_string) in_string = 0;
            continue;
        }
        switch (c) {
            '"', '\'' => {
                in_string = c;
                continue;
            },
            '(' => {
                paren_depth += 1;
                continue;
            },
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
                continue;
            },
            '&' => {
                if (paren_depth > 0) continue;
                if (i > 0) {
                    const prev = selector[i - 1];
                    if (std.ascii.isAlphanumeric(prev) or prev == '-' or prev == '_' or
                        prev == ')' or prev == ']' or prev == '*' or prev == '%')
                    {
                        return error.SassError;
                    }
                }
            },
            else => {},
        }
    }
}

fn validateLiteralSelectorForScope(selector: []const u8, has_parent_context: bool) VMError!void {
    if (!has_parent_context and selectorHasAmpersandWithSuffixLegacy(selector)) {
        return error.SassError;
    }
    if (selectorHasAtSignLegacy(selector)) return error.SassError;
    try validateAmpersandPositionLegacy(selector);
}

fn validateDynamicSelectorForScope(selector: []const u8, has_parent_context: bool) VMError!void {
    if (!has_parent_context and selectorHasAmpersandWithSuffixLegacy(selector)) {
        return error.SassError;
    }
    if (selectorHasAtSignLegacy(selector)) return error.SassError;
    selector_helpers_mod.validateSelectorDelimiters(selector) catch return error.SassError;
    selector_helpers_mod.validateSelectorParentheses(selector) catch return error.SassError;
    selector_helpers_mod.validatePseudoClassArgs(selector) catch return error.SassError;
    try validateAmpersandPositionLegacy(selector);
}

fn atRootPreludeActsLikeSelector(pool: *const InternPool, name_id: InternId, prelude_id: ?InternId) bool {
    if (prelude_id == null) return false;
    if (!std.mem.eql(u8, pool.get(name_id), "at-root")) return false;
    const trimmed = std.mem.trim(u8, pool.get(prelude_id.?), " \t\r\n");
    return trimmed.len > 0 and trimmed[0] != '(';
}

const ListSerializeMode = enum {
    normal,
    map_value,
};

fn listValueContainsMapRecursive(list_pool: *const std.ArrayListUnmanaged([]Value), value: Value) bool {
    if (value.kind() != .list) return false;
    if (value.listIsMap(value_mod.empty_list_meta_pool)) return true;
    const handle: usize = @intCast(value.listHandle());
    if (handle >= list_pool.items.len) return false;
    const items = list_pool.items[handle];
    for (items) |item| {
        if (listValueContainsMapRecursive(list_pool, item)) return true;
    }
    return false;
}

fn listValueContainsQuotedStringRecursive(list_pool: *const std.ArrayListUnmanaged([]Value), value: Value) bool {
    if (value.kind() != .list) return false;
    const handle: usize = @intCast(value.listHandle());
    if (handle >= list_pool.items.len) return false;
    const items = list_pool.items[handle];
    for (items) |item| {
        if (item.kind() == .string and item.stringQuoted(value_mod.empty_string_flags_pool)) return true;
        if (listValueContainsQuotedStringRecursive(list_pool, item)) return true;
    }
    return false;
}

fn declarationValueNeedsCssError(list_pool: *const std.ArrayListUnmanaged([]Value), value: Value) bool {
    if (listValueContainsMapRecursive(list_pool, value)) return true;
    if (value.kind() != .list) return false;
    if (value.listBracketed(value_mod.empty_list_meta_pool)) return false;
    const handle: usize = @intCast(value.listHandle());
    if (handle >= list_pool.items.len) return false;
    return list_pool.items[handle].len == 0;
}

fn ensureDeclarationValueIsCssValue(
    list_pool: *const std.ArrayListUnmanaged([]Value),
    value: Value,
    custom_property: bool,
) VMError!void {
    if (custom_property) return;
    if (declarationValueNeedsCssError(list_pool, value)) return error.SassError;
}

fn shouldRenderImplicitMapList(v: Value, items: []const Value, mode: ListSerializeMode) bool {
    if (mode != .map_value) return false;
    if (v.listBracketed(value_mod.empty_list_meta_pool)) return false;
    if (v.listSeparator(value_mod.empty_list_meta_pool) != .comma) return false;
    return items.len % 2 == 0;
}

fn shouldPreserveTrailingEmptyCommaSlot(v: Value, items: []const Value) bool {
    if (v.listSeparator(value_mod.empty_list_meta_pool) != .comma or v.listBracketed(value_mod.empty_list_meta_pool) or v.listIsMap(value_mod.empty_list_meta_pool)) return false;
    if (items.len < 2) return false;
    if (items[items.len - 1].kind() != .nil) return false;
    var i: usize = 0;
    while (i + 1 < items.len) : (i += 1) {
        if (items[i].kind() == .nil) return false;
    }
    return true;
}

fn listSeparatorCssForEmission(
    v: Value,
    items: []const Value,
    slash_list_preserve: ?*const std.AutoHashMapUnmanaged(u32, void),
) []const u8 {
    if (v.listSeparator(value_mod.empty_list_meta_pool) != .slash) return v.listSeparatorCss(value_mod.empty_list_meta_pool);
    if (slash_list_preserve) |preserve| {
        if (preserve.contains(v.listHandle())) return v.listSeparatorCss(value_mod.empty_list_meta_pool);
    }
    if (!v.listCoerceSlash(value_mod.empty_list_meta_pool)) return v.listSeparatorCss(value_mod.empty_list_meta_pool);
    for (items) |item| {
        if (item.kind() == .nil) continue;
        if (item.kind() != .number) return v.listSeparatorCss(value_mod.empty_list_meta_pool);
    }
    return "/";
}

/// For selector `make_selector` -- CSS `"` is not appended to the string (the intern contents of the quoted Sass string are concatenated as is).
fn valueToInternIdRawWithMode(
    pool: *InternPool,
    number_pool: *NumberPool,
    alloc: std.mem.Allocator,
    list_pool: *const std.ArrayListUnmanaged([]Value),
    color_pool: *const ColorPool,
    slash_list_preserve: ?*const std.AutoHashMapUnmanaged(u32, void),
    v: Value,
    mode: ListSerializeMode,
) VMError!InternId {
    if (v.kind() == .nil) return pool.intern("") catch error.OutOfMemory;
    if (v.kind() == .boolean) {
        return pool.intern(if (v.p64Of() != 0) "true" else "false") catch error.OutOfMemory;
    }
    if (v.isNumber()) {
        const css = try formatNumberValue(pool, number_pool, alloc, v);
        defer alloc.free(css);
        return pool.intern(css) catch error.OutOfMemory;
    }
    if (v.isString()) {
        const stored = pool.get(v.stringIntern());
        const raw = calc_utils.stripCalcArgMarker(stored);
        if (std.mem.startsWith(u8, stored, calc_interp_marker) and
            std.mem.indexOf(u8, raw, calc_interp_preserve_start) == null and
            css_utils.containsCalcFunction(raw))
        {
            const normalized = try calc_utils.normalizeCalcInDeclValueForMarkedInterpolation(alloc, raw);
            defer if (normalized.ptr != raw.ptr) alloc.free(normalized);
            const compact = try calc_utils.trimParenEdgeWhitespace(alloc, normalized);
            defer if (compact.ptr != normalized.ptr) alloc.free(compact);
            return pool.intern(compact) catch error.OutOfMemory;
        }
        return pool.intern(raw) catch error.OutOfMemory;
    }
    if (v.kind() == .color) {
        const entry = v.colorEntry(color_pool).*;
        const s = try color_format.formatColorCssRaw(alloc, entry);
        defer alloc.free(s);
        return pool.intern(s) catch error.OutOfMemory;
    }
    if (v.kind() == .list) {
        const items = list_pool.items[v.listHandle()];
        var acc: std.ArrayListUnmanaged(u8) = .empty;
        defer acc.deinit(alloc);
        const render_as_map = (v.listIsMap(value_mod.empty_list_meta_pool) or shouldRenderImplicitMapList(v, items, mode)) and (items.len % 2 == 0);

        if (render_as_map) {
            try acc.append(alloc, '(');
            var i: usize = 0;
            var wrote_any = false;
            while (i + 1 < items.len) : (i += 2) {
                if (wrote_any) try acc.appendSlice(alloc, ", ");
                const key_id = try valueToInternIdRawWithMode(pool, number_pool, alloc, list_pool, color_pool, slash_list_preserve, items[i], .normal);
                const val_id = try valueToInternIdRawWithMode(pool, number_pool, alloc, list_pool, color_pool, slash_list_preserve, items[i + 1], .map_value);
                try acc.appendSlice(alloc, pool.get(key_id));
                try acc.appendSlice(alloc, ": ");
                try acc.appendSlice(alloc, pool.get(val_id));
                wrote_any = true;
            }
            try acc.append(alloc, ')');
            return pool.intern(acc.items) catch error.OutOfMemory;
        }

        if (items.len == 0) {
            return pool.intern(if (v.listBracketed(value_mod.empty_list_meta_pool)) "[]" else "") catch error.OutOfMemory;
        }

        const sep = listSeparatorCssForEmission(v, items, slash_list_preserve);
        const preserve_trailing_empty_slot = shouldPreserveTrailingEmptyCommaSlot(v, items);
        var wrote_any = false;
        for (items, 0..) |item, item_index| {
            if (item.kind() == .nil and !(preserve_trailing_empty_slot and item_index + 1 == items.len)) continue;
            if (wrote_any) try acc.appendSlice(alloc, sep);
            if (item.kind() != .nil) {
                const id = try valueToInternIdRawWithMode(pool, number_pool, alloc, list_pool, color_pool, slash_list_preserve, item, .normal);
                const part = pool.get(id);
                try acc.appendSlice(alloc, part);
            }
            wrote_any = true;
        }
        return pool.intern(acc.items) catch error.OutOfMemory;
    }
    return error.SassError;
}

fn valueToInternIdRaw(
    pool: *InternPool,
    number_pool: *NumberPool,
    alloc: std.mem.Allocator,
    list_pool: *const std.ArrayListUnmanaged([]Value),
    color_pool: *const ColorPool,
    slash_list_preserve: ?*const std.AutoHashMapUnmanaged(u32, void),
    v: Value,
) VMError!InternId {
    return valueToInternIdRawWithMode(pool, number_pool, alloc, list_pool, color_pool, slash_list_preserve, v, .normal);
}

fn normalizeUnicodeRangeDeclText(alloc: std.mem.Allocator, raw: []const u8) VMError!?[]const u8 {
    var start: usize = 0;
    while (start < raw.len and (raw[start] == ' ' or raw[start] == '\t' or raw[start] == '\n' or raw[start] == '\r')) : (start += 1) {}
    if (start >= raw.len) return null;

    var end: usize = raw.len;
    while (end > start and (raw[end - 1] == ' ' or raw[end - 1] == '\t' or raw[end - 1] == '\n' or raw[end - 1] == '\r')) : (end -= 1) {}
    const trimmed = raw[start..end];
    if (trimmed.len < 2) return null;
    if (!((trimmed[0] == 'U' or trimmed[0] == 'u') and trimmed[1] == '+')) return null;

    const ur_len = css_utils.unicodeRangeLen(trimmed);
    if (ur_len == 0) return error.SassError;

    const ur = trimmed[0..ur_len];
    ir_validate.validateUnicodeRange(ur) catch return error.SassError;
    if (ur_len == trimmed.len) return null;

    const rest = trimmed[ur_len..];
    if (rest.len == 0) return null;
    if (rest[0] == '?') return error.SassError;
    if (rest[0] == ',') return null;

    var needs_space = false;
    if (rest[0] == '-') {
        if (ur[ur.len - 1] != '?') return error.SassError;
        if (rest.len == 1) return error.SassError;
        if (std.ascii.isWhitespace(rest[1])) return error.SassError;
        needs_space = !std.ascii.isDigit(rest[1]);
    } else if (!std.ascii.isWhitespace(rest[0])) {
        needs_space = true;
    }

    if (!needs_space) return null;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, raw[0..start]);
    try out.appendSlice(alloc, ur);
    try out.append(alloc, ' ');
    try out.appendSlice(alloc, rest);
    try out.appendSlice(alloc, raw[end..]);
    return try out.toOwnedSlice(alloc);
}

fn normalizeUnicodeRangeDeclValue(self: *VM, vid: InternId, is_custom_property: bool) VMError!InternId {
    if (is_custom_property) return vid;
    const raw = self.intern_pool.get(vid);
    const maybe_normalized = try normalizeUnicodeRangeDeclText(self.allocator, raw);
    if (maybe_normalized) |normalized| {
        defer self.allocator.free(normalized);
        return self.intern_pool.intern(normalized) catch error.OutOfMemory;
    }
    return vid;
}

fn findMatchingParenInDeclText(text: []const u8, open_idx: usize) ?usize {
    if (open_idx >= text.len or text[open_idx] != '(') return null;
    var depth: i32 = 0;
    var in_string: u8 = 0;
    var i: usize = open_idx;
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

fn isSimpleCalcIdentifierFragmentDecl(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text, 0..) |c, i| {
        const is_head = std.ascii.isAlphabetic(c) or c == '_';
        const is_tail = is_head or std.ascii.isDigit(c) or c == '-';
        if (i == 0) {
            if (!is_head) return false;
        } else if (!is_tail) {
            return false;
        }
    }
    return true;
}

fn normalizeCalcDeclString(alloc: std.mem.Allocator, raw: []const u8) VMError!?[]const u8 {
    const start = std.mem.indexOfNone(u8, raw, " \t\r\n") orelse return null;
    const end = std.mem.lastIndexOfNone(u8, raw, " \t\r\n") orelse return null;
    const trimmed = raw[start .. end + 1];
    if (trimmed.len < 6 or !std.ascii.startsWithIgnoreCase(trimmed, "calc(") or trimmed[trimmed.len - 1] != ')') {
        return null;
    }
    const close_idx = findMatchingParenInDeclText(trimmed, 4) orelse return null;
    if (close_idx != trimmed.len - 1) return null;

    const inner = trimmed[5..close_idx];
    const inner_trimmed = std.mem.trim(u8, inner, " \t\r\n");
    if (!(inner_trimmed.len >= 6 and std.ascii.startsWithIgnoreCase(inner_trimmed, "calc(") and inner_trimmed[inner_trimmed.len - 1] == ')')) {
        return null;
    }

    const flattened = try calc_utils.flattenNestedCalc(alloc, inner_trimmed);
    defer if (!calc_utils.sameSliceStorage(flattened, inner_trimmed)) alloc.free(flattened);
    const optimized = try calc_utils.removeUnnecessaryCalcParens(alloc, flattened);
    defer if (!calc_utils.sameSliceStorage(optimized, flattened)) alloc.free(optimized);

    var normalized_inner = optimized;
    var owned_normalized_inner: ?[]u8 = null;
    defer if (owned_normalized_inner) |buf| alloc.free(buf);

    const nested_trimmed = inner_trimmed;
    if (nested_trimmed.len >= 6 and std.ascii.startsWithIgnoreCase(nested_trimmed, "calc(") and nested_trimmed[nested_trimmed.len - 1] == ')') {
        if (findMatchingParenInDeclText(nested_trimmed, 4)) |nested_close| {
            if (nested_close == nested_trimmed.len - 1) {
                const nested_inner_raw = nested_trimmed[5..nested_close];
                const nested_inner_trimmed = std.mem.trim(u8, nested_inner_raw, " \t\r\n");
                const has_outer_ws = nested_inner_trimmed.len != nested_inner_raw.len;
                const has_edge_operator = nested_inner_trimmed.len > 0 and
                    (nested_inner_trimmed[0] == '+' or
                        nested_inner_trimmed[0] == '-' or
                        nested_inner_trimmed[0] == '*' or
                        nested_inner_trimmed[0] == '/' or
                        nested_inner_trimmed[nested_inner_trimmed.len - 1] == '+' or
                        nested_inner_trimmed[nested_inner_trimmed.len - 1] == '-' or
                        nested_inner_trimmed[nested_inner_trimmed.len - 1] == '*' or
                        nested_inner_trimmed[nested_inner_trimmed.len - 1] == '/');

                if (isSimpleCalcIdentifierFragmentDecl(nested_inner_trimmed) and !has_outer_ws) {
                    if (!std.mem.eql(u8, normalized_inner, nested_inner_trimmed)) {
                        if (owned_normalized_inner) |buf| {
                            alloc.free(buf);
                            owned_normalized_inner = null;
                        }
                        const dup = try alloc.dupe(u8, nested_inner_trimmed);
                        owned_normalized_inner = dup;
                        normalized_inner = dup;
                    }
                } else if (has_outer_ws or has_edge_operator) {
                    if (owned_normalized_inner) |buf| {
                        alloc.free(buf);
                        owned_normalized_inner = null;
                    }
                    const wrapped = try std.fmt.allocPrint(alloc, "({s})", .{nested_inner_raw});
                    owned_normalized_inner = wrapped;
                    normalized_inner = wrapped;
                } else if (!std.mem.eql(u8, normalized_inner, nested_inner_raw)) {
                    if (owned_normalized_inner) |buf| {
                        alloc.free(buf);
                        owned_normalized_inner = null;
                    }
                    const dup = try alloc.dupe(u8, nested_inner_raw);
                    owned_normalized_inner = dup;
                    normalized_inner = dup;
                }
            }
        }
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, raw[0..start]);
    try out.appendSlice(alloc, "calc(");
    try out.appendSlice(alloc, normalized_inner);
    try out.appendSlice(alloc, ")");
    try out.appendSlice(alloc, raw[end + 1 ..]);
    if (std.mem.eql(u8, out.items, raw)) {
        out.deinit(alloc);
        return null;
    }
    return try out.toOwnedSlice(alloc);
}

fn normalizeProgidDeclString(alloc: std.mem.Allocator, raw: []const u8) VMError!?[]u8 {
    if (!css_utils.containsAsciiIgnoreCase(raw, "progid:")) {
        return null;
    }
    // Broad whitespace folding is only needed for legacy DX filter chains.
    // Generic `progid:c(...)` values (special function tests) must preserve
    // comment-derived spacing.
    if (!css_utils.containsAsciiIgnoreCase(raw, "DXImageTransform.Microsoft.")) {
        return null;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, raw.len);

    var in_string: u8 = 0;
    var pending_space = false;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (in_string != 0) {
            try out.append(alloc, c);
            if (c == '\\' and i + 1 < raw.len) {
                i += 1;
                try out.append(alloc, raw[i]);
                continue;
            }
            if (c == in_string) in_string = 0;
            continue;
        }

        if (c == '"' or c == '\'') {
            if (pending_space and out.items.len != 0) {
                try out.append(alloc, ' ');
            }
            pending_space = false;
            in_string = c;
            try out.append(alloc, c);
            continue;
        }

        if (c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == '\x0c') {
            pending_space = true;
            continue;
        }

        if (pending_space and out.items.len != 0) {
            try out.append(alloc, ' ');
        }
        pending_space = false;
        try out.append(alloc, c);
    }

    if (std.mem.eql(u8, out.items, raw)) {
        out.deinit(alloc);
        return null;
    }
    return try out.toOwnedSlice(alloc);
}

fn simplifyRawInterpolatedSlashExprForDeclaration(
    alloc: std.mem.Allocator,
    raw: []const u8,
) VMError!?[]const u8 {
    const start = std.mem.indexOfNone(u8, raw, " \t\r\n") orelse return null;
    const end = std.mem.lastIndexOfNone(u8, raw, " \t\r\n") orelse return null;
    const trimmed = raw[start .. end + 1];
    if (trimmed.len < 3 or std.mem.indexOfScalar(u8, trimmed, '/') == null) return null;
    if (std.mem.indexOfAny(u8, trimmed, " \t\r\n,()[]{}")) |_| return null;

    var saw_unit = false;
    for (trimmed) |c| {
        if (std.ascii.isAlphabetic(c) or c == '%') {
            saw_unit = true;
            break;
        }
    }
    if (!saw_unit) return null;

    const parsed = calculation_mod.parseCalc(alloc, trimmed) catch return null;
    defer {
        calculation_mod.freeCalcValue(alloc, parsed);
        alloc.destroy(parsed);
    }

    const simplified = calculation_mod.simplify(alloc, parsed) catch return null;
    defer {
        calculation_mod.freeCalcValue(alloc, simplified);
        alloc.destroy(simplified);
    }
    if (simplified.* != .number) return null;
    const number = simplified.number;

    const formatted = try value_format.formatNumberWithUnit(
        alloc,
        number.value,
        number.unit,
    );
    defer alloc.free(formatted);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, raw[0..start]);
    try out.appendSlice(alloc, formatted);
    try out.appendSlice(alloc, raw[end + 1 ..]);
    if (std.mem.eql(u8, out.items, raw)) {
        out.deinit(alloc);
        return null;
    }
    return try out.toOwnedSlice(alloc);
}

fn isSimpleSlashNumberishTokenChar(c: u8) bool {
    return std.ascii.isAlphabetic(c) or std.ascii.isDigit(c) or c == '.' or c == '%';
}

fn simplifyCalcInnerSlashFragmentsForDeclaration(
    alloc: std.mem.Allocator,
    inner: []const u8,
) VMError!?[]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    var changed = false;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < inner.len) {
        if (inner[i] == '/' and i > 0 and i + 1 < inner.len and
            isSimpleSlashNumberishTokenChar(inner[i - 1]) and
            isSimpleSlashNumberishTokenChar(inner[i + 1]))
        {
            var left_start = i;
            while (left_start > 0 and isSimpleSlashNumberishTokenChar(inner[left_start - 1])) {
                left_start -= 1;
            }
            var right_end = i + 1;
            while (right_end < inner.len and isSimpleSlashNumberishTokenChar(inner[right_end])) {
                right_end += 1;
            }

            const candidate = inner[left_start..right_end];
            if (try simplifyRawInterpolatedSlashExprForDeclaration(alloc, candidate)) |simplified| {
                defer alloc.free(simplified);
                try out.appendSlice(alloc, inner[last_emit..left_start]);
                try out.appendSlice(alloc, simplified);
                i = right_end;
                last_emit = right_end;
                changed = true;
                continue;
            }
        }

        i += 1;
    }
    try out.appendSlice(alloc, inner[last_emit..]);

    if (!changed or std.mem.eql(u8, out.items, inner)) {
        out.deinit(alloc);
        return null;
    }
    return try out.toOwnedSlice(alloc);
}

fn simplifyCalcDeclSlashFragmentsForDeclaration(
    alloc: std.mem.Allocator,
    raw: []const u8,
) VMError!?[]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    var changed = false;
    var in_string: u8 = 0;
    var last_emit: usize = 0;
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < raw.len) {
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
        if (c == '\\' and i + 1 < raw.len) {
            i += 2;
            continue;
        }

        const has_calc_prefix = i + 5 <= raw.len and
            std.ascii.eqlIgnoreCase(raw[i .. i + 4], "calc") and
            raw[i + 4] == '(';
        if (!has_calc_prefix) {
            i += 1;
            continue;
        }
        if (i > 0) {
            const prev = raw[i - 1];
            if (std.ascii.isAlphabetic(prev) or std.ascii.isDigit(prev) or prev == '-' or prev == '_') {
                i += 1;
                continue;
            }
        }

        const close_idx = findMatchingParenInDeclText(raw, i + 4) orelse {
            i += 1;
            continue;
        };
        const inner = raw[i + 5 .. close_idx];
        try out.appendSlice(alloc, raw[last_emit..i]);
        if (try simplifyCalcInnerSlashFragmentsForDeclaration(alloc, inner)) |simplified_inner| {
            defer alloc.free(simplified_inner);
            try out.appendSlice(alloc, raw[i .. i + 5]);
            try out.appendSlice(alloc, simplified_inner);
            try out.append(alloc, ')');
            changed = true;
        } else {
            try out.appendSlice(alloc, raw[i .. close_idx + 1]);
        }
        i = close_idx + 1;
        last_emit = i;
    }

    try out.appendSlice(alloc, raw[last_emit..]);
    if (!changed or std.mem.eql(u8, out.items, raw)) {
        out.deinit(alloc);
        return null;
    }
    return try out.toOwnedSlice(alloc);
}

fn valueToInternIdInterpolated(
    pool: *InternPool,
    number_pool: *NumberPool,
    alloc: std.mem.Allocator,
    list_pool: *const std.ArrayListUnmanaged([]Value),
    color_pool: *const ColorPool,
    slash_list_preserve: ?*const std.AutoHashMapUnmanaged(u32, void),
    v: Value,
) VMError!InternId {
    const value = v;
    if (value.kind() == .nil) return pool.intern("") catch error.OutOfMemory;

    if (value.isString()) {
        const stored = pool.get(value.stringIntern());
        const calc_interp_marked = std.mem.indexOf(u8, stored, calc_interp_marker) != null;
        const raw = calc_utils.stripCalcArgMarker(stored);
        const preserve_literal = value.stringPreserveLiteralText(value_mod.empty_string_flags_pool);
        const preserve_decl_text = value.stringPreserveDeclText(value_mod.empty_string_flags_pool);
        const maybe_normalized = if (!preserve_literal) try normalizeCalcDeclString(alloc, raw) else null;
        defer if (maybe_normalized) |normalized| alloc.free(normalized);
        const effective = if (maybe_normalized) |normalized| normalized else raw;
        if (preserve_decl_text) {
            const marked = try std.fmt.allocPrint(alloc, "{s}{s}", .{ literal_decl_marker, effective });
            defer alloc.free(marked);
            return pool.intern(marked) catch error.OutOfMemory;
        }
        if (calc_interp_marked) {
            const marked = try std.fmt.allocPrint(alloc, "{s}{s}", .{ calc_interp_marker, effective });
            defer alloc.free(marked);
            return pool.intern(marked) catch error.OutOfMemory;
        }
        if (stringNeedsDeclEscape(effective)) {
            const rendered = if (std.mem.indexOfAny(u8, effective, "\"'") != null and std.mem.indexOfAny(u8, effective, "\n\r\x0c") != null)
                try serializeUnquotedInterpolatedDeclString(alloc, effective)
            else
                try serializeUnquotedDeclString(alloc, effective);
            defer alloc.free(rendered);
            return pool.intern(rendered) catch error.OutOfMemory;
        }
        return pool.intern(effective) catch error.OutOfMemory;
    }

    if (value.kind() == .list) {
        const items = list_pool.items[value.listHandle()];
        var acc: std.ArrayListUnmanaged(u8) = .empty;
        defer acc.deinit(alloc);
        const sep: []const u8 = switch (value.listSeparator(value_mod.empty_list_meta_pool)) {
            .comma => ", ",
            .slash => " / ",
            .space, .undecided => " ",
        };
        var wrote_any = false;
        for (items) |item| {
            if (item.kind() == .nil) continue;
            const item_id = try valueToInternIdInterpolated(pool, number_pool, alloc, list_pool, color_pool, slash_list_preserve, item);
            const item_text = pool.get(item_id);
            if (item_text.len == 0) continue;
            if (wrote_any) try acc.appendSlice(alloc, sep);
            try acc.appendSlice(alloc, item_text);
            wrote_any = true;
        }
        const maybe_normalized = try normalizeCalcDeclString(alloc, acc.items);
        defer if (maybe_normalized) |normalized| alloc.free(normalized);
        const effective = if (maybe_normalized) |normalized| normalized else acc.items;
        return pool.intern(effective) catch error.OutOfMemory;
    }

    return valueToInternIdDecl(pool, number_pool, alloc, list_pool, color_pool, slash_list_preserve, value, false);
}

/// For CSS output of declared values -- Sass quoted string intern as `"..."`.
fn valueToInternIdDeclWithMode(
    pool: *InternPool,
    number_pool: *NumberPool,
    alloc: std.mem.Allocator,
    list_pool: *const std.ArrayListUnmanaged([]Value),
    color_pool: *const ColorPool,
    slash_list_preserve: ?*const std.AutoHashMapUnmanaged(u32, void),
    v: Value,
    custom_property: bool,
    mode: ListSerializeMode,
) VMError!InternId {
    if (v.kind() == .nil) return pool.intern("") catch error.OutOfMemory;

    if (v.isString()) {
        const stored = pool.get(v.stringIntern());
        const calc_interp_marked = std.mem.indexOf(u8, stored, calc_interp_marker) != null;
        const inner = calc_utils.stripCalcArgMarker(stored);
        const preserve_color_slash_text = std.mem.startsWith(u8, inner, color_preserve_slash_marker);
        const visible_inner = if (preserve_color_slash_text) inner[color_preserve_slash_marker.len..] else inner;
        const custom_inner = if (custom_property and visible_inner.len != 0 and (visible_inner[0] == ' ' or visible_inner[0] == '\t'))
            visible_inner[1..]
        else
            visible_inner;
        const preserve_literal = v.stringPreserveLiteralText(value_mod.empty_string_flags_pool);
        const preserve_decl_text = v.stringPreserveDeclText(value_mod.empty_string_flags_pool);
        const maybe_normalized = if (!custom_property and !preserve_literal) try normalizeCalcDeclString(alloc, custom_inner) else null;
        defer if (maybe_normalized) |normalized| alloc.free(normalized);
        const calc_normalized_inner = if (maybe_normalized) |normalized| normalized else custom_inner;
        const maybe_progid_normalized = if (!custom_property)
            try normalizeProgidDeclString(alloc, calc_normalized_inner)
        else
            null;
        defer if (maybe_progid_normalized) |normalized| alloc.free(normalized);
        const effective_inner = if (maybe_progid_normalized) |normalized|
            normalized
        else
            calc_normalized_inner;
        if (!custom_property and !v.stringQuoted(value_mod.empty_string_flags_pool) and std.mem.eql(u8, std.mem.trim(u8, effective_inner, " \t\r\n"), ".")) {
            return error.SassError;
        }
        if (v.stringQuoted(value_mod.empty_string_flags_pool)) {
            // Custom property quoted string is output using normal quote serialize.
            //(legacy: `--x: "a"`  ->  preserve `"a"`. Traditional unconditional unquote is
            // This was the source of the drift that also removed quotes via list elements. )
            const rendered = try serializeQuotedDeclString(alloc, inner);
            defer alloc.free(rendered);
            if (custom_property) {
                const normalized = try normalizeCustomPropertyValueSingleLine(alloc, rendered);
                defer alloc.free(normalized);
                return pool.intern(normalized) catch error.OutOfMemory;
            }
            return pool.intern(rendered) catch error.OutOfMemory;
        }
        if (custom_property) {
            const normalized = try normalizeCustomPropertyValueSingleLine(alloc, custom_inner);
            defer alloc.free(normalized);
            return pool.intern(normalized) catch error.OutOfMemory;
        }
        // Plain CSS source path stores raw decl bytes (with the original
        // ' / " quote chars) on an unquoted literal_string. official Sass CLI parses
        // each quoted segment and re-serializes via preferredQuoteChar
        // (double-preferred unless the body contains a "). Mirror that here.
        const quote_normalized_inner = if (preserve_literal or preserve_color_slash_text)
            effective_inner
        else
            try normalizePlainCssDeclQuotes(alloc, effective_inner);
        defer if (quote_normalized_inner.ptr != effective_inner.ptr) alloc.free(quote_normalized_inner);
        // plain CSS decl value after comma space / before !important space /
        // Normalize modern color syntax ' / ' to be compatible with official Sass CLI.
        // SassScript-computed string (unquote / string concatenation) is a runtime marker
        // Protect with `preserve_literal_text` and skip normalize.
        const space_normalized_inner = blk: {
            if (preserve_literal or preserve_color_slash_text) break :blk quote_normalized_inner;
            const normalized = try normalizePlainCssDeclSpaces(alloc, quote_normalized_inner);
            if (std.mem.eql(u8, normalized, quote_normalized_inner)) {
                alloc.free(normalized);
                break :blk quote_normalized_inner;
            }
            break :blk normalized;
        };
        defer if (space_normalized_inner.ptr != quote_normalized_inner.ptr) alloc.free(space_normalized_inner);
        if (preserve_literal and std.mem.indexOfAny(u8, space_normalized_inner, "\"'") != null) {
            const url_quote_normalized = try normalizeUrlDoubleQuotesWithInnerQuotes(alloc, space_normalized_inner);
            defer if (url_quote_normalized.ptr != space_normalized_inner.ptr) alloc.free(url_quote_normalized);
            if (url_quote_normalized.ptr != space_normalized_inner.ptr or url_quote_normalized.len != space_normalized_inner.len) {
                return pool.intern(url_quote_normalized) catch error.OutOfMemory;
            }
            return internRuntimeText(pool, alloc, space_normalized_inner);
        }
        if (preserve_decl_text) {
            const marked = try std.fmt.allocPrint(alloc, "{s}{s}", .{ literal_decl_marker, space_normalized_inner });
            defer alloc.free(marked);
            return pool.intern(marked) catch error.OutOfMemory;
        }
        if (calc_interp_marked) {
            const marked = try std.fmt.allocPrint(alloc, "{s}{s}", .{ calc_interp_marker, space_normalized_inner });
            defer alloc.free(marked);
            return pool.intern(marked) catch error.OutOfMemory;
        }
        if (stringNeedsDeclEscape(space_normalized_inner)) {
            const rendered = if (std.mem.indexOfAny(u8, space_normalized_inner, "\"'") != null and std.mem.indexOfAny(u8, space_normalized_inner, "\n\r\x0c") != null)
                try serializeUnquotedInterpolatedDeclString(alloc, space_normalized_inner)
            else
                try serializeUnquotedDeclString(alloc, space_normalized_inner);
            defer alloc.free(rendered);
            return pool.intern(rendered) catch error.OutOfMemory;
        }
        return internRuntimeText(pool, alloc, space_normalized_inner);
    }

    if (v.kind() == .list) {
        const items = list_pool.items[v.listHandle()];
        var acc: std.ArrayListUnmanaged(u8) = .empty;
        defer acc.deinit(alloc);
        const render_as_map = (v.listIsMap(value_mod.empty_list_meta_pool) or shouldRenderImplicitMapList(v, items, mode)) and (items.len % 2 == 0);

        if (render_as_map) {
            try acc.append(alloc, '(');
            var i: usize = 0;
            var wrote_any = false;
            while (i + 1 < items.len) : (i += 2) {
                if (wrote_any) try acc.appendSlice(alloc, ", ");
                const key_id = try valueToInternIdDeclWithMode(pool, number_pool, alloc, list_pool, color_pool, slash_list_preserve, items[i], custom_property, .normal);
                const val_id = try valueToInternIdDeclWithMode(pool, number_pool, alloc, list_pool, color_pool, slash_list_preserve, items[i + 1], custom_property, .map_value);
                try acc.appendSlice(alloc, pool.get(key_id));
                try acc.appendSlice(alloc, ": ");
                try acc.appendSlice(alloc, pool.get(val_id));
                wrote_any = true;
            }
            try acc.append(alloc, ')');
        } else {
            if (items.len == 0) {
                try acc.appendSlice(alloc, if (v.listBracketed(value_mod.empty_list_meta_pool)) "[]" else "");
            } else {
                if (v.listBracketed(value_mod.empty_list_meta_pool)) try acc.append(alloc, '[');
                const sep = listSeparatorCssForEmission(v, items, slash_list_preserve);
                const preserve_trailing_empty_slot = shouldPreserveTrailingEmptyCommaSlot(v, items);
                var wrote_any = false;
                for (items, 0..) |item, item_index| {
                    if (item.kind() == .nil and !(preserve_trailing_empty_slot and item_index + 1 == items.len)) continue;
                    const part = if (item.kind() != .nil) blk: {
                        const id = try valueToInternIdDeclWithMode(pool, number_pool, alloc, list_pool, color_pool, slash_list_preserve, item, custom_property, .normal);
                        const rendered = pool.get(id);
                        if (rendered.len == 0 and
                            v.listSeparator(value_mod.empty_list_meta_pool) != .comma and
                            item.kind() == .list and
                            !item.listBracketed(value_mod.empty_list_meta_pool) and
                            !item.listIsMap(value_mod.empty_list_meta_pool))
                        {
                            const sub_items = list_pool.items[item.listHandle()];
                            if (sub_items.len == 0) continue;
                        }
                        break :blk rendered;
                    } else "";
                    const preserve_empty_part = item.kind() == .nil and preserve_trailing_empty_slot and item_index + 1 == items.len;
                    if (part.len == 0 and !preserve_empty_part) continue;
                    if (wrote_any) try acc.appendSlice(alloc, sep);
                    try acc.appendSlice(alloc, part);
                    wrote_any = true;
                }
                if (v.listBracketed(value_mod.empty_list_meta_pool)) try acc.append(alloc, ']');
            }
        }

        if (custom_property) {
            const normalized = try normalizeCustomPropertyValueSingleLine(alloc, acc.items);
            defer alloc.free(normalized);
            return pool.intern(normalized) catch error.OutOfMemory;
        }
        return pool.intern(acc.items) catch error.OutOfMemory;
    }

    return valueToInternIdRaw(pool, number_pool, alloc, list_pool, color_pool, slash_list_preserve, v);
}

fn valueToInternIdDeclUnquotedStringPart(
    pool: *InternPool,
    number_pool: *NumberPool,
    alloc: std.mem.Allocator,
    list_pool: *const std.ArrayListUnmanaged([]Value),
    color_pool: *const ColorPool,
    slash_list_preserve: ?*const std.AutoHashMapUnmanaged(u32, void),
    v: Value,
) VMError!InternId {
    if (!v.isString() or !v.stringQuoted(value_mod.empty_string_flags_pool)) {
        return valueToInternIdDecl(pool, number_pool, alloc, list_pool, color_pool, slash_list_preserve, v, false);
    }

    const inner = calc_utils.stripCalcArgMarker(pool.get(v.stringIntern()));
    const maybe_normalized = try normalizeCalcDeclString(alloc, inner);
    defer if (maybe_normalized) |normalized| alloc.free(normalized);
    const effective_inner = if (maybe_normalized) |normalized| normalized else inner;
    if (std.mem.eql(u8, std.mem.trim(u8, effective_inner, " \t\r\n"), ".")) {
        return error.SassError;
    }
    if (stringNeedsDeclEscape(effective_inner)) {
        const rendered = try serializeUnquotedDeclString(alloc, effective_inner);
        defer alloc.free(rendered);
        return pool.intern(rendered) catch error.OutOfMemory;
    }
    return pool.intern(effective_inner) catch error.OutOfMemory;
}

fn valueToInternIdDecl(
    pool: *InternPool,
    number_pool: *NumberPool,
    alloc: std.mem.Allocator,
    list_pool: *const std.ArrayListUnmanaged([]Value),
    color_pool: *const ColorPool,
    slash_list_preserve: ?*const std.AutoHashMapUnmanaged(u32, void),
    v: Value,
    custom_property: bool,
) VMError!InternId {
    return valueToInternIdDeclWithMode(pool, number_pool, alloc, list_pool, color_pool, slash_list_preserve, v, custom_property, .normal);
}

fn internRuntimeText(pool: *InternPool, alloc: std.mem.Allocator, text: []const u8) VMError!InternId {
    const scratch = try alloc.dupe(u8, text);
    defer alloc.free(scratch);
    return pool.intern(scratch) catch error.OutOfMemory;
}

fn dupeRuntimeMaybeAliased(alloc: std.mem.Allocator, text: []const u8) VMError![]u8 {
    const out = try alloc.alloc(u8, text.len);
    std.mem.copyForwards(u8, out, text);
    return out;
}

fn valueToInternIdInterpolatedDeclRaw(
    pool: *InternPool,
    number_pool: *NumberPool,
    alloc: std.mem.Allocator,
    list_pool: *const std.ArrayListUnmanaged([]Value),
    color_pool: *const ColorPool,
    slash_list_preserve: ?*const std.AutoHashMapUnmanaged(u32, void),
    v: Value,
    custom_property: bool,
) VMError!InternId {
    const raw_id = try valueToInternIdInterpolated(pool, number_pool, alloc, list_pool, color_pool, slash_list_preserve, v);
    if (custom_property) {
        if (customCalcShouldSimplifyToNumber(pool.get(raw_id))) {
            if (try parseCalcNumberish(pool, number_pool, alloc, pool.get(raw_id))) |parsed| {
                return valueToInternIdDecl(pool, number_pool, alloc, list_pool, color_pool, slash_list_preserve, parsed, true);
            }
        }
        return raw_id;
    }
    const maybe_simplified = try simplifyCalcDeclSlashFragmentsForDeclaration(alloc, pool.get(raw_id));
    defer if (maybe_simplified) |simplified| alloc.free(simplified);
    if (maybe_simplified) |simplified| {
        return pool.intern(simplified) catch error.OutOfMemory;
    }
    return raw_id;
}

fn interpolatedCallNameIsUrlLike(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "url") or
        std.ascii.eqlIgnoreCase(name, "url-prefix") or
        std.ascii.eqlIgnoreCase(name, "domain");
}

fn interpolatedCallInfo(
    alloc: std.mem.Allocator,
    pool: *InternPool,
    parts: []const Value,
    source_name_has_interp: bool,
    source_args_have_interp: bool,
) InterpolatedCallInfo {
    if (parts.len < 3) return .{};
    const last = parts[parts.len - 1];
    if (last.kind() != .string or last.stringQuoted(value_mod.empty_string_flags_pool)) return .{};
    if (!std.mem.eql(u8, pool.get(last.stringIntern()), ")")) return .{};

    var name_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer name_buf.deinit(alloc);

    var i: usize = 0;
    while (i < parts.len - 1) : (i += 1) {
        const part = parts[i];
        if (part.kind() != .string or part.stringQuoted(value_mod.empty_string_flags_pool)) return .{};
        const text = pool.get(part.stringIntern());
        if (text.len == 0) continue;

        if (std.mem.eql(u8, text, "(")) {
            if (name_buf.items.len == 0) return .{};
            var info: InterpolatedCallInfo = .{
                .context = if (interpolatedCallNameIsUrlLike(name_buf.items)) .url_like else .generic,
                .arg_start = i + 1,
            };
            if (info.context == .url_like) {
                const has_source_interp = source_name_has_interp or source_args_have_interp;
                info.unquote_quoted_args = has_source_interp;
                info.preserve_quoted_args = !has_source_interp;
            } else if (source_name_has_interp and !source_args_have_interp) {
                info.preserve_quoted_args = true;
            } else {
                info.context = .none;
            }
            return info;
        }
        if (text[text.len - 1] == '(') {
            name_buf.appendSlice(alloc, text[0 .. text.len - 1]) catch return .{};
            if (name_buf.items.len == 0) return .{};
            var info: InterpolatedCallInfo = .{
                .context = if (interpolatedCallNameIsUrlLike(name_buf.items)) .url_like else .generic,
                .arg_start = i + 1,
            };
            if (info.context == .url_like) {
                const has_source_interp = source_name_has_interp or source_args_have_interp;
                info.unquote_quoted_args = has_source_interp;
                info.preserve_quoted_args = !has_source_interp;
            } else if (source_name_has_interp and !source_args_have_interp) {
                info.preserve_quoted_args = true;
            } else {
                info.context = .none;
            }
            return info;
        }
        if (std.mem.indexOfScalar(u8, text, '(') != null) return .{};
        name_buf.appendSlice(alloc, text) catch return .{};
    }

    return .{};
}

fn valueToInternIdDeclSlashCompact(
    pool: *InternPool,
    number_pool: *NumberPool,
    alloc: std.mem.Allocator,
    list_pool: *const std.ArrayListUnmanaged([]Value),
    color_pool: *const ColorPool,
    slash_list_preserve: ?*const std.AutoHashMapUnmanaged(u32, void),
    v: Value,
    custom_property: bool,
) VMError!InternId {
    if (v.kind() != .list or !v.listSlash(value_mod.empty_list_meta_pool) or v.listBracketed(value_mod.empty_list_meta_pool) or v.listIsMap(value_mod.empty_list_meta_pool)) {
        return valueToInternIdDecl(pool, number_pool, alloc, list_pool, color_pool, slash_list_preserve, v, custom_property);
    }

    const items = list_pool.items[v.listHandle()];
    var acc: std.ArrayListUnmanaged(u8) = .empty;
    defer acc.deinit(alloc);
    try acc.ensureTotalCapacity(alloc, items.len * 2);

    var wrote_any = false;
    for (items) |item| {
        if (item.kind() == .nil) continue;
        if (wrote_any) try acc.append(alloc, '/');
        const id = try valueToInternIdDeclWithMode(pool, number_pool, alloc, list_pool, color_pool, slash_list_preserve, item, custom_property, .normal);
        try acc.appendSlice(alloc, pool.get(id));
        wrote_any = true;
    }

    if (!wrote_any) return pool.intern("") catch error.OutOfMemory;
    return pool.intern(acc.items) catch error.OutOfMemory;
}

fn preferredQuoteChar(raw: []const u8) u8 {
    // Legacy policy: default is double quote. Only use single quote when the
    // string contains a double quote AND does not contain a single quote, so
    // we avoid escaping a double quote unnecessarily.
    var has_single = false;
    var has_double = false;
    for (raw) |c| {
        if (c == '\'') has_single = true;
        if (c == '"') has_double = true;
    }
    if (has_double and !has_single) return '\'';
    return '"';
}

fn normalizePlainCssDeclQuotes(alloc: std.mem.Allocator, raw: []const u8) VMError![]u8 {
    if (css_utils.containsAsciiIgnoreCase(raw, "progid:DXImageTransform.Microsoft.")) {
        return alloc.dupe(u8, raw);
    }
    const isIdentChar = struct {
        fn f(b: u8) bool {
            return std.ascii.isAlphanumeric(b) or b == '-' or b == '_';
        }
    }.f;
    const isOpaqueCssFnName = struct {
        fn f(name: []const u8) bool {
            if (name.len == 0) return false;
            if (name[0] == '-') {
                if (std.mem.findScalarPos(u8, name, 1, '-')) |dash| {
                    const base = name[dash + 1 ..];
                    return std.ascii.eqlIgnoreCase(base, "calc") or
                        std.ascii.eqlIgnoreCase(base, "element") or
                        std.ascii.eqlIgnoreCase(base, "expression");
                }
                return false;
            }
            return std.ascii.eqlIgnoreCase(name, "element") or
                std.ascii.eqlIgnoreCase(name, "expression") or
                std.ascii.eqlIgnoreCase(name, "type");
        }
    }.f;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, raw.len);
    var paren_depth: u32 = 0;
    var opaque_active = false;
    var opaque_enter_depth: u32 = 0;
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c == '(') {
            var start = out.items.len;
            while (start > 0 and isIdentChar(out.items[start - 1])) : (start -= 1) {}
            const fn_name = out.items[start..];
            if (!opaque_active) {
                if (fn_name.len > 0 and isOpaqueCssFnName(fn_name)) {
                    opaque_active = true;
                    opaque_enter_depth = paren_depth;
                } else {
                    var k = out.items.len;
                    while (k > 0) {
                        const b = out.items[k - 1];
                        if (isIdentChar(b) or b == '.' or b == ':') {
                            k -= 1;
                        } else break;
                    }
                    const chain = out.items[k..];
                    if (chain.len >= 7 and css_utils.containsAsciiIgnoreCase(chain, "progid:")) {
                        opaque_active = true;
                        opaque_enter_depth = paren_depth;
                    }
                }
            }
            paren_depth += 1;
            try out.append(alloc, c);
            i += 1;
            continue;
        }
        if (c == ')') {
            if (paren_depth > 0) paren_depth -= 1;
            if (opaque_active and paren_depth <= opaque_enter_depth) {
                opaque_active = false;
            }
            try out.append(alloc, c);
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            const q = c;
            var j: usize = i + 1;
            while (j < raw.len) {
                if (raw[j] == '\\') {
                    j += if (j + 1 < raw.len) 2 else 1;
                    continue;
                }
                if (raw[j] == q) break;
                j += 1;
            }
            const end = if (j < raw.len) j + 1 else raw.len;
            if (opaque_active or j >= raw.len) {
                try out.appendSlice(alloc, raw[i..end]);
                i = end;
                continue;
            }
            const inner = raw[i + 1 .. j];
            const decoded = css_utils.unescapeSassString(alloc, inner) catch return error.OutOfMemory;
            defer if (decoded.ptr != inner.ptr) alloc.free(decoded);
            const rendered = try serializeQuotedDeclString(alloc, decoded);
            defer alloc.free(rendered);
            try out.appendSlice(alloc, rendered);
            i = end;
            continue;
        }
        try out.append(alloc, c);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

fn normalizeUrlQuotesInInterp(alloc: std.mem.Allocator, raw: []const u8) VMError![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, raw.len);
    var i: usize = 0;
    while (i < raw.len) {
        if (i + 4 <= raw.len and
            std.ascii.toLower(raw[i]) == 'u' and
            std.ascii.toLower(raw[i + 1]) == 'r' and
            std.ascii.toLower(raw[i + 2]) == 'l' and
            raw[i + 3] == '(')
        {
            if (i > 0 and (std.ascii.isAlphanumeric(raw[i - 1]) or raw[i - 1] == '-' or raw[i - 1] == '_')) {
                try out.append(alloc, raw[i]);
                i += 1;
                continue;
            }
            try out.appendSlice(alloc, raw[i .. i + 4]);
            i += 4;
            while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t')) {
                try out.append(alloc, raw[i]);
                i += 1;
            }
            if (i < raw.len and raw[i] == '\'') {
                var j: usize = i + 1;
                var has_backslash = false;
                var has_double_quote = false;
                while (j < raw.len) {
                    if (raw[j] == '\\') {
                        has_backslash = true;
                        j += if (j + 1 < raw.len) @as(usize, 2) else @as(usize, 1);
                        continue;
                    }
                    if (raw[j] == '\'') break;
                    if (raw[j] == '"') has_double_quote = true;
                    j += 1;
                }
                if (j < raw.len and !has_backslash and !has_double_quote) {
                    try out.append(alloc, '"');
                    try out.appendSlice(alloc, raw[i + 1 .. j]);
                    try out.append(alloc, '"');
                    i = j + 1;
                    continue;
                }
            }
            continue;
        }
        try out.append(alloc, raw[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

// Normalize spaces between tokens in plain CSS declaration values:
// - ",X" -> ", X".
// - "X!important" -> "X !important".
// - Modern color functions remove spaces around the channel slash.
// Quoted strings and url(...) pass through verbatim. Restrict slash compaction
// to known color functions so user-defined slash-list arguments remain intact.
fn normalizePlainCssDeclSpaces(alloc: std.mem.Allocator, raw: []const u8) VMError![]u8 {
    //Fast path: no target char present  ->  no change, return copy.
    //Include quote chars so adjacent-string separator insertion (`"a""b"`  ->
    // `"a" "b"`) can run.
    var needs_work = false;
    for (raw) |c| {
        if (c == ',' or c == '!' or c == '/' or c == '"' or c == '\'') {
            needs_work = true;
            break;
        }
    }
    if (!needs_work) {
        var copy: std.ArrayListUnmanaged(u8) = .empty;
        errdefer copy.deinit(alloc);
        try copy.appendSlice(alloc, raw);
        return try copy.toOwnedSlice(alloc);
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, raw.len + 16);

    // Per-paren flag: is this paren group a modern color function
    // (rgb/hsl/hwb/lab/lch/oklab/oklch/color)? Only the `/` inside it is changed to ` / `.
    var color_fn_stack: [16]bool = [_]bool{false} ** 16;
    var var_fn_stack: [16]bool = [_]bool{false} ** 16;
    var paren_depth: u32 = 0;
    var url_depth: u32 = 0;
    // Do not insert space after `,` in the paren group after `progid:`;
    // the official Sass CLI preserves legacy IE filter values as source text.
    // Set flag until `(` of progid:X.Y.foo(...) is closed.
    var progid_active = false;
    var progid_enter_depth: u32 = 0;
    var opaque_fn_stack: [16]bool = [_]bool{false} ** 16;
    var opaque_active = false;
    var opaque_enter_depth: u32 = 0;

    const WsFn = struct {
        fn isWs(b: u8) bool {
            return b == ' ' or b == '\t' or b == '\n' or b == '\r' or b == '\x0c';
        }
        fn isIdentChar(b: u8) bool {
            return std.ascii.isAlphanumeric(b) or b == '-' or b == '_';
        }
        fn isColorFnName(name: []const u8) bool {
            return std.ascii.eqlIgnoreCase(name, "rgb") or
                std.ascii.eqlIgnoreCase(name, "rgba") or
                std.ascii.eqlIgnoreCase(name, "hsl") or
                std.ascii.eqlIgnoreCase(name, "hsla") or
                std.ascii.eqlIgnoreCase(name, "hwb") or
                std.ascii.eqlIgnoreCase(name, "lab") or
                std.ascii.eqlIgnoreCase(name, "lch") or
                std.ascii.eqlIgnoreCase(name, "oklab") or
                std.ascii.eqlIgnoreCase(name, "oklch") or
                std.ascii.eqlIgnoreCase(name, "color");
        }
        fn isOpaqueCssFnName(name: []const u8) bool {
            if (name.len == 0) return false;
            if (name[0] == '-') {
                if (std.mem.findScalarPos(u8, name, 1, '-')) |dash| {
                    const base = name[dash + 1 ..];
                    return std.ascii.eqlIgnoreCase(base, "calc") or
                        std.ascii.eqlIgnoreCase(base, "element") or
                        std.ascii.eqlIgnoreCase(base, "expression");
                }
                return false;
            }
            return std.ascii.eqlIgnoreCase(name, "element") or
                std.ascii.eqlIgnoreCase(name, "expression") or
                std.ascii.eqlIgnoreCase(name, "type");
        }
    };

    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];

        //Inside url(...)  ->  pass bytes verbatim so data URIs with ',' / '/'
        // are untouched. Quoted segments inside still need to be tracked so
        // we don't mis-count ')' inside them.
        if (url_depth > 0) {
            if (c == '"' or c == '\'') {
                const q = c;
                var j: usize = i + 1;
                while (j < raw.len) {
                    if (raw[j] == '\\' and j + 1 < raw.len) {
                        j += 2;
                        continue;
                    }
                    if (raw[j] == q) break;
                    j += 1;
                }
                try out.append(alloc, c);
                const inner_end = if (j < raw.len) j else raw.len;
                const inner = raw[i + 1 .. inner_end];
                const decoded = css_utils.unescapeSassString(alloc, inner) catch return error.OutOfMemory;
                defer if (decoded.ptr != inner.ptr) alloc.free(decoded);
                try appendSerializedDeclString(alloc, &out, decoded, q);
                if (j < raw.len) {
                    try out.append(alloc, q);
                    i = j + 1;
                } else {
                    i = raw.len;
                }
                continue;
            }
            if (c == '(') {
                url_depth += 1;
                paren_depth += 1;
            } else if (c == ')') {
                url_depth -= 1;
                if (paren_depth > 0) paren_depth -= 1;
            }
            try out.append(alloc, c);
            i += 1;
            continue;
        }

        // Quoted segment: copy verbatim (do not touch embedded ',' / '/').
        if (c == '"' or c == '\'') {
            const q = c;
            try out.append(alloc, c);
            i += 1;
            while (i < raw.len) {
                if (raw[i] == '\\' and i + 1 < raw.len) {
                    try out.append(alloc, raw[i]);
                    try out.append(alloc, raw[i + 1]);
                    i += 2;
                    continue;
                }
                const b = raw[i];
                try out.append(alloc, b);
                i += 1;
                if (b == q) break;
            }
            // official Sass CLI: adjacent quoted strings (e.g. `"a""b"`) are parsed as
            // separate tokens and re-emitted with a space separator. Insert one
            // here if the closing quote is immediately followed by another quote.
            if (paren_depth == 0 and i < raw.len and (raw[i] == '"' or raw[i] == '\'')) {
                try out.append(alloc, ' ');
            }
            continue;
        }

        // url( entry: push url_depth and skip reformatting inside.
        if ((c == 'u' or c == 'U') and i + 3 < raw.len and
            (raw[i + 1] == 'r' or raw[i + 1] == 'R') and
            (raw[i + 2] == 'l' or raw[i + 2] == 'L') and
            raw[i + 3] == '(')
        {
            const at_ident_start = i == 0 or !WsFn.isIdentChar(raw[i - 1]);
            if (at_ident_start) {
                if (paren_depth < color_fn_stack.len) {
                    color_fn_stack[paren_depth] = false;
                }
                paren_depth += 1;
                url_depth += 1;
                try out.appendSlice(alloc, raw[i .. i + 4]);
                i += 4;
                continue;
            }
        }

        if (c == '(') {
            // Extract the function name from the previous output bytes and judge the color function.
            var start = out.items.len;
            while (start > 0 and WsFn.isIdentChar(out.items[start - 1])) : (start -= 1) {}
            const fn_name = out.items[start..];
            const is_color = fn_name.len > 0 and WsFn.isColorFnName(fn_name);
            const is_var = fn_name.len > 0 and std.ascii.eqlIgnoreCase(fn_name, "var");
            const is_opaque = fn_name.len > 0 and WsFn.isOpaqueCssFnName(fn_name);
            if (paren_depth < color_fn_stack.len) {
                color_fn_stack[paren_depth] = is_color;
                var_fn_stack[paren_depth] = is_var;
                opaque_fn_stack[paren_depth] = is_opaque;
            }
            if (is_opaque and !opaque_active) {
                opaque_active = true;
                opaque_enter_depth = paren_depth;
            }
            // Detect `(` in the final function of dotted chain containing `progid:`. Out trailing
            // `progid:X.Y.foo` (connected only with ident and `.` / `:`) back to `progid:` starting point
            // Determine whether
            if (!progid_active) {
                var k = out.items.len;
                while (k > 0) {
                    const b = out.items[k - 1];
                    if (WsFn.isIdentChar(b) or b == '.' or b == ':') {
                        k -= 1;
                    } else break;
                }
                const chain = out.items[k..];
                if (chain.len >= 7 and (std.ascii.startsWithIgnoreCase(chain, "progid:") or css_utils.containsAsciiIgnoreCase(chain, "progid:"))) {
                    progid_active = true;
                    progid_enter_depth = paren_depth;
                }
            }
            paren_depth += 1;
            try out.append(alloc, c);
            i += 1;
            continue;
        }

        if (c == ')') {
            if (paren_depth > 0) paren_depth -= 1;
            if (progid_active and paren_depth <= progid_enter_depth) {
                progid_active = false;
            }
            if (opaque_active and paren_depth <= opaque_enter_depth) {
                opaque_active = false;
            }
            try out.append(alloc, c);
            i += 1;
            continue;
        }

        // Whitespace byte: pass through verbatim.
        if (WsFn.isWs(c)) {
            try out.append(alloc, c);
            i += 1;
            continue;
        }

        // Comma: emit and insert single space if next non-ws token follows.
        // Immediately before the CSS comment `/*` official Sass CLI treats the comment boundary as a separator, so
        // Do not insert whitespace (e.g. do not change `var(--x,/*!*/ /*!*/)` to `, /*`).
        // Pregid:X.Y.foo(...) is preserved as per source (legacy IE filter).
        if (c == ',') {
            try out.append(alloc, ',');
            i += 1;
            if (!progid_active and !opaque_active and i < raw.len) {
                while (i < raw.len and WsFn.isWs(raw[i])) : (i += 1) {}
                if (i >= raw.len) continue;
                const next_c = raw[i];
                const is_comment_start = next_c == '/' and i + 1 < raw.len and raw[i + 1] == '*';
                const level = if (paren_depth > 0) paren_depth - 1 else 0;
                const is_var_empty_fallback = next_c == ')' and paren_depth > 0 and level < var_fn_stack.len and var_fn_stack[level];
                if (is_var_empty_fallback or (!WsFn.isWs(next_c) and next_c != ')' and next_c != ',' and !is_comment_start)) {
                    try out.append(alloc, ' ');
                }
            }
            continue;
        }

        // '!important' [case-insensitive] with optional ws between ! and important.
        // If the part before ! is not ws, insert ' ', and remove ws between ! and important.
        if (c == '!') {
            var j = i + 1;
            while (j < raw.len and WsFn.isWs(raw[j])) : (j += 1) {}
            if (j + 9 <= raw.len and std.ascii.eqlIgnoreCase(raw[j .. j + 9], "important")) {
                const prev_is_ws = out.items.len == 0 or WsFn.isWs(out.items[out.items.len - 1]);
                if (!prev_is_ws) try out.append(alloc, ' ');
                try out.appendSlice(alloc, "!important");
                i = j + 9;
                continue;
            }
        }

        //'/' inside a color function paren  ->  Remove ws from both sides
        // Make it compact `/` (modern color syntax alpha separator).
        if (c == '/' and paren_depth > 0) {
            const level = paren_depth - 1;
            const is_color = level < color_fn_stack.len and color_fn_stack[level];
            if (is_color) {
                while (out.items.len > 0 and WsFn.isWs(out.items[out.items.len - 1])) {
                    _ = out.pop();
                }
                try out.append(alloc, '/');
                i += 1;
                while (i < raw.len and WsFn.isWs(raw[i])) : (i += 1) {}
                continue;
            }
        }

        try out.append(alloc, c);
        i += 1;
    }

    return out.toOwnedSlice(alloc);
}

const isPrivateUseCodePoint = css_utils.isPrivateUseCodePoint;

fn codePointNeedsHexEscape(code_point: u21) bool {
    return code_point == 0 or
        (code_point >= 1 and code_point <= 0x1F and code_point != 0x09) or
        code_point == 0x7F or
        isPrivateUseCodePoint(code_point);
}

fn codePointNeedsHexEscapeSeparator(code_point: u21) bool {
    if (code_point < 0x80) {
        const byte: u8 = @intCast(code_point);
        return std.ascii.isHex(byte) or byte == ' ' or byte == '\t';
    }
    return false;
}

fn insertMediaHexEscapeSeparatorsBeforeParen(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var needs_change = false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != ')') continue;
        if (i == 0 or std.ascii.isWhitespace(text[i - 1])) continue;
        if (!endsWithCssHexEscape(text[0..i])) continue;
        needs_change = true;
        break;
    }
    if (!needs_change) return text;

    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, text.len + 4);
    i = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == ')' and i > 0 and !std.ascii.isWhitespace(text[i - 1]) and endsWithCssHexEscape(out.items)) {
            try out.append(allocator, ' ');
        }
        try out.append(allocator, text[i]);
    }
    return try out.toOwnedSlice(allocator);
}

fn endsWithCssHexEscape(text: []const u8) bool {
    if (text.len < 2) return false;
    var i: usize = text.len;
    var count: u8 = 0;
    while (i > 0 and count < 6 and std.ascii.isHex(text[i - 1])) {
        i -= 1;
        count += 1;
    }
    if (count == 0 or i == 0) return false;
    return text[i - 1] == '\\';
}

fn cssEscapeWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0c';
}

fn cssHexDigitValue(c: u8) u21 {
    return switch (c) {
        '0'...'9' => @as(u21, c - '0'),
        'a'...'f' => @as(u21, c - 'a' + 10),
        'A'...'F' => @as(u21, c - 'A' + 10),
        else => 0,
    };
}

fn isIdentifierStartContextForEscape(out: []const u8) bool {
    if (out.len == 0) return true;
    const prev = out[out.len - 1];
    return prev == ' ' or prev == '\t' or prev == '\n' or prev == '\r' or prev == '\x0c' or
        prev == '(' or prev == ')' or prev == '[' or prev == ']' or prev == '{' or prev == '}' or
        prev == ',' or prev == ':' or prev == ';' or prev == '/';
}

fn appendForcedHexEscape(
    alloc: std.mem.Allocator,
    acc: *std.ArrayListUnmanaged(u8),
    code_point: u21,
) VMError!void {
    var buf: [16]u8 = undefined;
    const escaped = std.fmt.bufPrint(&buf, "\\{x} ", .{code_point}) catch |err| {
        std.debug.panic("appendForcedHexEscape formatting failed: {s}", .{@errorName(err)});
    };
    try acc.appendSlice(alloc, escaped);
}

fn appendSerializedDeclCodePoint(
    alloc: std.mem.Allocator,
    acc: *std.ArrayListUnmanaged(u8),
    quote_char: ?u8,
    code_point: u21,
) VMError!bool {
    if (quote_char == null and
        (code_point == '\n' or code_point == '\r' or code_point == '\x0c'))
    {
        try acc.append(alloc, ' ');
        return false;
    }

    if (quote_char) |q| {
        if (code_point == q) {
            try acc.append(alloc, '\\');
            try acc.append(alloc, q);
            return false;
        }
    }
    if (code_point == '\\') {
        try acc.appendSlice(alloc, "\\\\");
        return false;
    }
    if (codePointNeedsHexEscape(code_point) and !(quote_char != null and isPrivateUseCodePoint(code_point))) {
        var buf: [16]u8 = undefined;
        const escaped = std.fmt.bufPrint(&buf, "\\{x}", .{code_point}) catch |err| {
            std.debug.panic("appendSerializedDeclCodePoint formatting failed: {s}", .{@errorName(err)});
        };
        try acc.appendSlice(alloc, escaped);
        // Separator spaces are inserted by the caller only when required by
        // the following code point (hex-digit/whitespace ambiguity).
        return true;
    }
    if (code_point < 0x80) {
        try acc.append(alloc, @intCast(code_point));
        return false;
    }
    var utf8_buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(code_point, &utf8_buf) catch |err| {
        std.debug.panic("appendSerializedDeclCodePoint utf8Encode failed: {s}", .{@errorName(err)});
    };
    try acc.appendSlice(alloc, utf8_buf[0..len]);
    return false;
}

fn appendSerializedDeclString(
    alloc: std.mem.Allocator,
    acc: *std.ArrayListUnmanaged(u8),
    raw: []const u8,
    quote_char: ?u8,
) VMError!void {
    return appendSerializedDeclStringImpl(alloc, acc, raw, quote_char, false);
}

fn appendSerializedDeclStringImpl(
    alloc: std.mem.Allocator,
    acc: *std.ArrayListUnmanaged(u8),
    raw: []const u8,
    quote_char: ?u8,
    collapse_quoted_segment_newlines: bool,
) VMError!void {
    var i: usize = 0;
    var prev_was_hex_escape = false;
    while (i < raw.len) {
        if (quote_char == null and (raw[i] == '"' or raw[i] == '\'')) {
            const q = raw[i];
            var j: usize = i + 1;
            while (j < raw.len) {
                if (raw[j] == '\\' and j + 1 < raw.len) {
                    j += 2;
                    continue;
                }
                if (raw[j] == q) break;
                j += 1;
            }
            try acc.append(alloc, q);
            const inner_end = if (j < raw.len) j else raw.len;
            try appendSerializedDeclStringImpl(alloc, acc, raw[i + 1 .. inner_end], q, collapse_quoted_segment_newlines);
            if (j < raw.len) {
                try acc.append(alloc, q);
                i = j + 1;
            } else {
                i = raw.len;
            }
            prev_was_hex_escape = false;
            continue;
        }
        // official Sass CLI compatible: literal whitespace run in unquoted context
        // Collapse (space / TAB / LF / CR / FF) into a single space.
        // Convert TAB to \9 hex escape when source converts `\9` escape
        // Only if you have (lower backslash-hex branch) literal TAB
        // Treat byte as whitespace.
        if (quote_char == null) {
            const c0 = raw[i];
            if (c0 == ' ' or c0 == '\t' or c0 == '\n' or c0 == '\r' or c0 == '\x0c') {
                var j: usize = i;
                while (j < raw.len) : (j += 1) {
                    const cj = raw[j];
                    if (cj != ' ' and cj != '\t' and cj != '\n' and cj != '\r' and cj != '\x0c') break;
                }
                const last_is_space = acc.items.len > 0 and acc.items[acc.items.len - 1] == ' ';
                if (acc.items.len != 0 and !last_is_space) {
                    try acc.append(alloc, ' ');
                }
                prev_was_hex_escape = false;
                i = j;
                continue;
            }
        }
        if (raw[i] == '\\') {
            if (i + 1 >= raw.len) {
                try acc.appendSlice(alloc, "\\\\");
                prev_was_hex_escape = false;
                i += 1;
                continue;
            }

            const next = raw[i + 1];
            if (next == '\n' or next == '\x0c') {
                // CSS line-continuation escape: drop both bytes.
                prev_was_hex_escape = false;
                i += 2;
                continue;
            }
            if (next == '\r') {
                // CRLF continuation also collapses.
                i += 2;
                if (i < raw.len and raw[i] == '\n') i += 1;
                prev_was_hex_escape = false;
                continue;
            }

            if (quote_char != null) {
                const q = quote_char.?;
                if (next == '\\') {
                    // Preserve consecutive backslashes as distinct code points
                    // in quoted output (`\\` -> `\\\\`).
                    try acc.appendSlice(alloc, "\\\\");
                    prev_was_hex_escape = false;
                    i += 1;
                    continue;
                }
                if (next == q) {
                    // Backslash-escaped quote inside quoted output keeps the
                    // escaped backslash and escaped quote (`\"` -> `\\\"`).
                    try acc.appendSlice(alloc, "\\\\");
                    try acc.append(alloc, '\\');
                    try acc.append(alloc, q);
                    prev_was_hex_escape = false;
                    i += 2;
                    continue;
                }
                if (std.ascii.isHex(next)) {
                    var j: usize = i + 1;
                    var count: u8 = 0;
                    var parsed: u21 = 0;
                    while (j < raw.len and count < 6 and std.ascii.isHex(raw[j])) : (j += 1) {
                        parsed = parsed * 16 + cssHexDigitValue(raw[j]);
                        count += 1;
                    }
                    if (quote_char != null) {
                        if (j < raw.len and cssEscapeWhitespace(raw[j])) {
                            if (raw[j] == '\r' and j + 1 < raw.len and raw[j + 1] == '\n') j += 1;
                            j += 1;
                        }
                        try acc.appendSlice(alloc, "\\\\");
                        try acc.appendSlice(alloc, raw[i + 1 .. j]);
                        prev_was_hex_escape = false;
                        i = j;
                        continue;
                    }
                    var had_escape_delimiter = false;
                    if (j < raw.len and cssEscapeWhitespace(raw[j])) {
                        had_escape_delimiter = true;
                        if (raw[j] == '\r' and j + 1 < raw.len and raw[j + 1] == '\n') j += 1;
                        j += 1;
                    }
                    const code_point: u21 = if (parsed > 0x10FFFF) 0xFFFD else parsed;
                    if (prev_was_hex_escape and codePointNeedsHexEscapeSeparator(code_point)) {
                        try acc.append(alloc, ' ');
                    }
                    prev_was_hex_escape = try appendSerializedDeclCodePoint(alloc, acc, quote_char, code_point);
                    if (had_escape_delimiter and prev_was_hex_escape) {
                        try acc.append(alloc, ' ');
                        prev_was_hex_escape = false;
                    }
                    i = j;
                    continue;
                }

                const next_seq_len = std.unicode.utf8ByteSequenceLength(raw[i + 1]) catch 1;
                const next_slice = if (i + 1 + next_seq_len <= raw.len and std.unicode.utf8ValidateSlice(raw[i + 1 .. i + 1 + next_seq_len]))
                    raw[i + 1 .. i + 1 + next_seq_len]
                else
                    raw[i + 1 .. i + 2];
                try acc.appendSlice(alloc, "\\\\");
                try acc.appendSlice(alloc, next_slice);
                prev_was_hex_escape = false;
                i += 1 + next_slice.len;
                continue;
            }

            if (std.ascii.isHex(next)) {
                var j: usize = i + 1;
                var count: u8 = 0;
                var parsed: u21 = 0;
                while (j < raw.len and count < 6 and std.ascii.isHex(raw[j])) : (j += 1) {
                    parsed = parsed * 16 + cssHexDigitValue(raw[j]);
                    count += 1;
                }
                var had_escape_delimiter = false;
                if (j < raw.len and cssEscapeWhitespace(raw[j])) {
                    had_escape_delimiter = true;
                    if (raw[j] == '\r' and j + 1 < raw.len and raw[j + 1] == '\n') j += 1;
                    j += 1;
                }

                const code_point: u21 = if (parsed > 0x10FFFF) 0xFFFD else parsed;
                const preserve_tab_escape = quote_char == null and
                    code_point == '\t' and
                    isIdentifierStartContextForEscape(acc.items);
                const preserve_linebreak_escape = quote_char == null and
                    (code_point == '\n' or code_point == '\r' or code_point == '\x0c');
                const preserve_leading_digit_escape = quote_char == null and
                    code_point < 0x80 and
                    std.ascii.isDigit(@as(u8, @intCast(code_point))) and
                    isIdentifierStartContextForEscape(acc.items);
                const preserve_leading_hyphen_escape = blk: {
                    if (quote_char != null or code_point != '-' or !isIdentifierStartContextForEscape(acc.items)) break :blk false;
                    if (j >= raw.len or raw[j] >= 0x80) break :blk false;
                    break :blk std.ascii.isAlphabetic(raw[j]) or raw[j] == '_';
                };

                if (preserve_tab_escape) {
                    try appendForcedHexEscape(alloc, acc, code_point);
                    prev_was_hex_escape = false;
                } else if (preserve_leading_digit_escape) {
                    try appendForcedHexEscape(alloc, acc, code_point);
                    prev_was_hex_escape = false;
                } else if (preserve_leading_hyphen_escape) {
                    try acc.appendSlice(alloc, "\\-");
                    prev_was_hex_escape = false;
                } else if (preserve_linebreak_escape) {
                    try appendForcedHexEscape(alloc, acc, code_point);
                    prev_was_hex_escape = false;
                } else {
                    if (prev_was_hex_escape and codePointNeedsHexEscapeSeparator(code_point)) {
                        try acc.append(alloc, ' ');
                    }
                    prev_was_hex_escape = try appendSerializedDeclCodePoint(alloc, acc, quote_char, code_point);
                    if (had_escape_delimiter and prev_was_hex_escape) {
                        try acc.append(alloc, ' ');
                        prev_was_hex_escape = false;
                    }
                }

                i = j;
                continue;
            }

            const next_seq_len = std.unicode.utf8ByteSequenceLength(raw[i + 1]) catch 1;
            const next_slice = if (i + 1 + next_seq_len <= raw.len and std.unicode.utf8ValidateSlice(raw[i + 1 .. i + 1 + next_seq_len]))
                raw[i + 1 .. i + 1 + next_seq_len]
            else
                raw[i + 1 .. i + 2];
            const code_point: u21 = if (next_slice.len == 1 and next_slice[0] < 0x80)
                next_slice[0]
            else
                std.unicode.utf8Decode(next_slice) catch next_slice[0];

            const preserve_alpha_escape = quote_char == null and code_point < 0x80 and
                std.ascii.isAlphabetic(@as(u8, @intCast(code_point)));
            const preserve_hyphen_escape = quote_char == null and code_point == '-' and
                isIdentifierStartContextForEscape(acc.items);
            const preserve_simple_escape = (quote_char == null and
                (code_point == ' ' or code_point == ')' or code_point == '"' or code_point == '\'')) or
                preserve_hyphen_escape or
                preserve_alpha_escape;
            const preserve_tab_escape = quote_char == null and code_point == '\t' and
                isIdentifierStartContextForEscape(acc.items);
            const preserve_escaped_punctuation = quote_char == null and code_point < 0x80 and blk: {
                const ascii_code: u8 = @intCast(code_point);
                break :blk !std.ascii.isAlphanumeric(ascii_code) and ascii_code != '_' and ascii_code != '-';
            };
            if (preserve_tab_escape) {
                try appendForcedHexEscape(alloc, acc, code_point);
                prev_was_hex_escape = false;
            } else if (preserve_simple_escape or preserve_escaped_punctuation) {
                try acc.append(alloc, '\\');
                try acc.appendSlice(alloc, next_slice);
                prev_was_hex_escape = false;
            } else {
                if (prev_was_hex_escape and codePointNeedsHexEscapeSeparator(code_point)) {
                    try acc.append(alloc, ' ');
                }
                prev_was_hex_escape = try appendSerializedDeclCodePoint(alloc, acc, quote_char, code_point);
            }
            i += 1 + next_slice.len;
            continue;
        }

        const seq_len = std.unicode.utf8ByteSequenceLength(raw[i]) catch 1;
        const slice = if (i + seq_len <= raw.len and std.unicode.utf8ValidateSlice(raw[i .. i + seq_len]))
            raw[i .. i + seq_len]
        else
            raw[i .. i + 1];
        const code_point: u21 = if (slice.len == 1 and raw[i] < 0x80)
            raw[i]
        else
            std.unicode.utf8Decode(slice) catch raw[i];
        if (quote_char != null and collapse_quoted_segment_newlines and
            (code_point == '\n' or code_point == '\r' or code_point == '\x0c'))
        {
            const last_is_space = acc.items.len > 0 and acc.items[acc.items.len - 1] == ' ';
            if (acc.items.len != 0 and !last_is_space) try acc.append(alloc, ' ');
            prev_was_hex_escape = false;
            i += slice.len;
            continue;
        }
        if (quote_char == null and isIdentifierStartContextForEscape(acc.items) and code_point < 0x80) {
            const ascii_code: u8 = @intCast(code_point);
            if (ascii_code == '\t') {
                try appendForcedHexEscape(alloc, acc, code_point);
                prev_was_hex_escape = false;
                i += slice.len;
                continue;
            }
        }
        if (prev_was_hex_escape and codePointNeedsHexEscapeSeparator(code_point)) {
            try acc.append(alloc, ' ');
        }
        prev_was_hex_escape = try appendSerializedDeclCodePoint(alloc, acc, quote_char, code_point);
        i += slice.len;
    }
}

fn serializeQuotedDeclString(alloc: std.mem.Allocator, raw: []const u8) VMError![]u8 {
    const quote_char = preferredQuoteChar(raw);
    var acc: std.ArrayListUnmanaged(u8) = .empty;
    defer acc.deinit(alloc);
    try acc.append(alloc, quote_char);
    try appendSerializedDeclString(alloc, &acc, raw, quote_char);
    try acc.append(alloc, quote_char);
    return acc.toOwnedSlice(alloc);
}

fn serializeUnquotedDeclString(alloc: std.mem.Allocator, raw: []const u8) VMError![]u8 {
    var acc: std.ArrayListUnmanaged(u8) = .empty;
    defer acc.deinit(alloc);
    try appendSerializedDeclString(alloc, &acc, raw, null);
    return acc.toOwnedSlice(alloc);
}

fn serializeUnquotedInterpolatedDeclString(alloc: std.mem.Allocator, raw: []const u8) VMError![]u8 {
    var acc: std.ArrayListUnmanaged(u8) = .empty;
    defer acc.deinit(alloc);
    try appendSerializedDeclStringImpl(alloc, &acc, raw, null, true);
    return acc.toOwnedSlice(alloc);
}

fn stringNeedsDeclEscape(raw: []const u8) bool {
    if (raw.len > 1 and raw[0] < 0x80 and raw[1] < 0x80) {
        if (raw[0] == '-' and (std.ascii.isAlphabetic(raw[1]) or raw[1] == '_')) {
            // Function call pattern like -a-calc(...) doesn't need escaping
            var j: usize = 1;
            while (j < raw.len and (std.ascii.isAlphanumeric(raw[j]) or raw[j] == '-' or raw[j] == '_')) : (j += 1) {}
            if (j >= raw.len or raw[j] != '(') return true;
        } else if (std.ascii.isDigit(raw[0]) and (std.ascii.isAlphabetic(raw[1]) or raw[1] == '_')) return true;
    }
    var scan_i: usize = 0;
    while (scan_i < raw.len) {
        if (std.mem.startsWith(u8, raw[scan_i..], calc_interp_preserve_start)) {
            const body_start = scan_i + calc_interp_preserve_start.len;
            if (std.mem.indexOf(u8, raw[body_start..], calc_interp_preserve_end)) |end_rel| {
                scan_i = body_start + end_rel + calc_interp_preserve_end.len;
                continue;
            }
        }
        const c = raw[scan_i];
        if (c == '\\' or (c >= 0x00 and c <= 0x1F) or c == 0x7F) return true;
        scan_i += 1;
    }
    var i: usize = 0;
    while (i < raw.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(raw[i]) catch {
            i += 1;
            continue;
        };
        if (i + seq_len > raw.len or !std.unicode.utf8ValidateSlice(raw[i .. i + seq_len])) {
            i += 1;
            continue;
        }
        const code_point = std.unicode.utf8Decode(raw[i .. i + seq_len]) catch {
            i += 1;
            continue;
        };
        if (isPrivateUseCodePoint(code_point)) return true;
        i += seq_len;
    }
    return false;
}

fn normalizeCustomPropertyValueSingleLine(alloc: std.mem.Allocator, value: []const u8) VMError![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, value.len);
    var pending_space = false;
    for (value) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            if (out.items.len != 0) pending_space = true;
            continue;
        }
        if (pending_space) {
            const prev = if (out.items.len > 0) out.items[out.items.len - 1] else 0;
            if (out.items.len > 0 and prev == ',' and c == ')') {
                try out.append(alloc, ' ');
            } else if (out.items.len > 0 and prev != '(' and c != ')' and c != ',') {
                try out.append(alloc, ' ');
            }
            pending_space = false;
        }
        try out.append(alloc, c);
    }
    return out.toOwnedSlice(alloc);
}

fn customCalcShouldSimplifyToNumber(raw: []const u8) bool {
    const t = std.mem.trim(u8, raw, " \t\r\n");
    if (!std.mem.startsWith(u8, t, "calc((")) return false;
    if (std.mem.indexOfAny(u8, t, "\n\r") != null) return false;
    if (std.mem.indexOf(u8, t, "var(") != null or std.mem.indexOf(u8, t, "env(") != null) return false;
    if (std.mem.indexOfScalar(u8, t, '/') == null) return false;
    return true;
}

fn normalizeCustomCalcSlashWhitespace(alloc: std.mem.Allocator, value: []const u8) VMError![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, value.len);

    var i: usize = 0;
    var in_string: u8 = 0;
    var calc_depth: u32 = 0;
    while (i < value.len) {
        const c = value[i];
        if (in_string != 0) {
            try out.append(alloc, c);
            if (c == '\\' and i + 1 < value.len) {
                i += 1;
                try out.append(alloc, value[i]);
            } else if (c == in_string) {
                in_string = 0;
            }
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            try out.append(alloc, c);
            i += 1;
            continue;
        }
        if (i + 5 <= value.len and std.ascii.eqlIgnoreCase(value[i .. i + 4], "calc") and value[i + 4] == '(') {
            try out.appendSlice(alloc, value[i .. i + 5]);
            calc_depth += 1;
            i += 5;
            continue;
        }
        if (calc_depth > 0) {
            if (c == '(') {
                calc_depth += 1;
                try out.append(alloc, c);
                i += 1;
                continue;
            }
            if (c == ')') {
                calc_depth -= 1;
                try out.append(alloc, c);
                i += 1;
                continue;
            }
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                var j = i;
                while (j < value.len and (value[j] == ' ' or value[j] == '\t' or value[j] == '\r' or value[j] == '\n')) : (j += 1) {}
                if (j < value.len and value[j] == '/') {
                    if (out.items.len != 0 and out.items[out.items.len - 1] != ' ') try out.append(alloc, ' ');
                    i = j;
                    continue;
                }
                if (out.items.len != 0 and out.items[out.items.len - 1] == '/') {
                    try out.append(alloc, ' ');
                    i = j;
                    continue;
                }
                try out.appendSlice(alloc, value[i..j]);
                i = j;
                continue;
            }
            if (c == '/') {
                try out.append(alloc, '/');
                i += 1;
                continue;
            }
        }
        try out.append(alloc, c);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

fn normalizeRawCustomPropertyLiteral(alloc: std.mem.Allocator, value: []const u8) VMError![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, value.len);

    var i: usize = 0;
    if (value.len > 0 and value[0] == ' ') {
        try out.append(alloc, ' ');
        while (i < value.len and value[i] == ' ') : (i += 1) {}
    }

    while (i < value.len) : (i += 1) {
        const c = value[i];
        if (c == '\r') {
            if (i + 1 < value.len and value[i + 1] == '\n') i += 1;
            try out.append(alloc, '\n');
            continue;
        }
        try out.append(alloc, c);
    }

    return out.toOwnedSlice(alloc);
}

fn expectVmCss(source: []const u8, expected: []const u8) !void {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator, source);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    vm.deprecation_opts.quiet = true;
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(expected, buf.items);
}

//---- tests --------------------------------------------------------

test "vm: skipped flow-control branch can contain unresolved mixin" {
    try expectVmCss(
        \\$use-mixin: false;
        \\$items: (square 0) (pill 200px);
        \\@each $item in $items {
        \\  .#{nth($item, 1)} {
        \\    @if($use-mixin) {
        \\      @include border-radius(nth($item, 2));
        \\    } @else {
        \\      border-radius: nth($item, 2);
        \\    }
        \\  }
        \\}
    ,
        \\.square {
        \\  border-radius: 0;
        \\}
        \\
        \\.pill {
        \\  border-radius: 200px;
        \\}
        \\
    );
}

test "vm: legacy plus important evaluates value expression" {
    try expectVmCss(
        \\$brand-face: "Helvetica Neue", sans-serif;
        \\$brand-color: #4a8ec2;
        \\.brand {
        \\  font-family: $brand-face +!important;
        \\  color: $brand-color +!important;
        \\}
    ,
        \\.brand {
        \\  font-family: "Helvetica Neue", sans-serif !important;
        \\  color: #4a8ec2 !important;
        \\}
        \\
    );
}

test "vm: quoted declaration strings keep CSS-looking function text quoted" {
    try expectVmCss(
        \\.a {
        \\  x: "var(--x)";
        \\  y: "rgb(1 2 3)";
        \\  z: "hsl(0 0% 0%)";
        \\}
    ,
        \\.a {
        \\  x: "var(--x)";
        \\  y: "rgb(1 2 3)";
        \\  z: "hsl(0 0% 0%)";
        \\}
        \\
    );
}

fn renderVmCssForTest(allocator: std.mem.Allocator, source: []const u8, source_path: ?[]const u8) ![]u8 {
    var r = if (source_path) |path|
        try compiler_mod.parseResolveCompileWithPath(allocator, source, path, &.{})
    else
        try compiler_mod.parseResolveCompile(allocator, source);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    vm.deprecation_opts.quiet = true;
    defer vm.deinit();

    try vm.runTop();

    const source_locations = try allocator.alloc(rule_ir_mod.SourceLocation, r.program.modules.len);
    defer allocator.free(source_locations);
    for (r.program.modules, 0..) |mod, idx| {
        source_locations[idx] = .{
            .source_path = mod.module_path,
            .line_starts = mod.line_starts,
            .source_len = mod.source_len,
        };
    }

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeToWithSourceMap(&w.writer, &r.pool, null, source_locations, .expanded, .{});
    }
    return try buf.toOwnedSlice(allocator);
}

test "vm: literal rule \u{2192} Rule IR 3 nodes" {
    const allocator = std.testing.allocator;
    //`body` selector -- If it is `.a`, an extra decl will be added at the beginning in the parser's declaration/rule judgment.
    var r = try compiler_mod.parseResolveCompile(allocator, ".a { color: red; }");
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    // Debug: bytecode / node order (keep during development)
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.a {
        \\  color: red;
        \\}
        \\
    , buf.items);
}

test "vm: nested interpolation in quoted string keeps full payload" {
    const css = try renderVmCssForTest(std.testing.allocator, ".a { output: \"#{\"foo#{'ba' + 'r'}baz\"}\"; }\n", null);
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.a {
        \\  output: "foobarbaz";
        \\}
        \\
    , css);
}

test "vm: nested interpolation with surrounding literal text preserves tail" {
    const css = try renderVmCssForTest(std.testing.allocator, ".a { output: \"[#{" ++ "\"foo#{'ba' + 'r'}baz" ++ "\"}]\"; }\n", null);
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.a {
        \\  output: "[foobarbaz]";
        \\}
        \\
    , css);
}

test "vm: quoted string interpolation preserves embedded quote characters" {
    const css = try renderVmCssForTest(std.testing.allocator,
        \\.a { output: "#{str-slice("x%3D'0'%3E", 1)}"; }
    , null);
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.a {
        \\  output: "x%3D'0'%3E";
        \\}
        \\
    , css);
}

test "vm: interpolated single-quoted url preserves embedded single quotes" {
    const css = try renderVmCssForTest(std.testing.allocator,
        \\.a { output: url('#{str-slice("data:image/svg+xml,%3Csvg%20x%3D'0'%3E", 1)}'); }
    , null);
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.a {
        \\  output: url("data:image/svg+xml,%3Csvg%20x%3D'0'%3E");
        \\}
        \\
    , css);
}

test "vm: escaped interpolation marker in quoted string stays literal text" {
    const css = try renderVmCssForTest(std.testing.allocator, ".a { output: \"\\#{notinterp}\"; }\n", null);
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.a {
        \\  output: "#{notinterp}";
        \\}
        \\
    , css);
}

test "vm: interpolation of quoted string in unquoted context drops quote flag" {
    const css = try renderVmCssForTest(std.testing.allocator, ".a { output: #{\"literal\"}literal; }\n", null);
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.a {
        \\  output: literalliteral;
        \\}
        \\
    , css);
}

test "vm: extend leaves unrelated selector list order unchanged" {
    try expectVmCss(
        \\.sans-serif { a: b; }
        \\body { @extend .sans-serif; }
        \\.ui.button:disabled,.ui.buttons .disabled.button,.ui.disabled.active.button,.ui.disabled.button,.ui.disabled.button:hover { a: b; }
    ,
        \\.sans-serif, body {
        \\  a: b;
        \\}
        \\
        \\.ui.button:disabled, .ui.buttons .disabled.button, .ui.disabled.active.button, .ui.disabled.button, .ui.disabled.button:hover {
        \\  a: b;
        \\}
        \\
    );
}

test "vm: extend preserves live original selector list sibling order" {
    try expectVmCss(
        \\.sans-serif { a: b; }
        \\#quick h1 { @extend .sans-serif; }
        \\#full h1 { @extend .sans-serif; }
        \\body { @extend .sans-serif; }
        \\ul li, dl, ol li { @extend .sans-serif; }
        \\.sans-serif, body, ul li, dl, ol li { font-family: sans; }
    ,
        \\.sans-serif, ul li, dl, ol li, body, #full h1, #quick h1 {
        \\  a: b;
        \\}
        \\
        \\.sans-serif, #quick h1, #full h1, body, ul li, dl, ol li {
        \\  font-family: sans;
        \\}
        \\
    );
}

test "vm: repeated placeholder occurrence switches exact extenders to source order" {
    try expectVmCss(
        \\%unselectable { a: b; }
        \\.button { @extend %unselectable; }
        \\.file { @extend %unselectable; }
        \\.breadcrumb { @extend %unselectable; }
        \\.tabs { @extend %unselectable; }
        \\.utility { @extend %unselectable; }
        \\%unselectable { a: b; }
        \\.button { @extend %unselectable; }
        \\.file { @extend %unselectable; }
        \\.breadcrumb { @extend %unselectable; }
        \\.tabs { @extend %unselectable; }
        \\.utility { @extend %unselectable; }
    ,
        \\.utility, .tabs, .breadcrumb, .file, .button {
        \\  a: b;
        \\}
        \\
        \\.button, .file, .breadcrumb, .tabs, .utility {
        \\  a: b;
        \\}
        \\
    );
}

test "vm: repeated placeholder occurrence source-orders transitive extenders" {
    try expectVmCss(
        \\%control { a: control; }
        \\.button { @extend %control; }
        \\@mixin input { @extend %control; b: input; }
        \\%input { @include input; }
        \\%input-textarea { @extend %input; c: input-textarea; }
        \\.input { @extend %input-textarea; }
        \\.textarea { @extend %input-textarea; }
        \\.select { select { @extend %input; } }
        \\.file-cta, .file-name { @extend %control; }
        \\%control { a: control; }
        \\.button { @extend %control; }
        \\@mixin input { @extend %control; b: input; }
        \\%input { @include input; }
        \\%input-textarea { @extend %input; c: input-textarea; }
        \\.input { @extend %input-textarea; }
        \\.textarea { @extend %input-textarea; }
        \\.select { select { @extend %input; } }
        \\.file-cta, .file-name { @extend %control; }
    ,
        \\.file-cta, .file-name, .select select, .textarea, .input, .button {
        \\  a: control;
        \\}
        \\
        \\.select select, .textarea, .input {
        \\  b: input;
        \\}
        \\
        \\.textarea, .input {
        \\  c: input-textarea;
        \\}
        \\
        \\.button, .input, .textarea, .select select, .file-cta, .file-name {
        \\  a: control;
        \\}
        \\
        \\.input, .textarea, .select select {
        \\  b: input;
        \\}
        \\
        \\.input, .textarea {
        \\  c: input-textarea;
        \\}
        \\
    );
}

test "vm: repeated nested media mixin preserves source order" {
    try expectVmCss(
        \\@mixin below { @media (max-width: 959px) { @content; } }
        \\@mixin fluid($property, $min, $max, $minw: 480px, $maxw: 960px) {
        \\  & { #{$property}: $min; }
        \\  @media (min-width: $minw) and (max-width: #{$maxw - 1px}) { #{$property}: calc(#{$min} + 15); }
        \\  @media (min-width: $maxw) { #{$property}: $max; }
        \\}
        \\.a { @include below { @include fluid(padding-left, 15px, 30px); @include fluid(padding-right, 15px, 30px); } }
    ,
        \\@media (max-width: 959px) {
        \\  .a {
        \\    padding-left: 15px;
        \\  }
        \\}
        \\@media (max-width: 959px) and (min-width: 480px) and (max-width: 959px) {
        \\  .a {
        \\    padding-left: calc(15px + 15);
        \\  }
        \\}
        \\@media (max-width: 959px) and (min-width: 960px) {
        \\  .a {
        \\    padding-left: 30px;
        \\  }
        \\}
        \\@media (max-width: 959px) {
        \\  .a {
        \\    padding-right: 15px;
        \\  }
        \\}
        \\@media (max-width: 959px) and (min-width: 480px) and (max-width: 959px) {
        \\  .a {
        \\    padding-right: calc(15px + 15);
        \\  }
        \\}
        \\@media (max-width: 959px) and (min-width: 960px) {
        \\  .a {
        \\    padding-right: 30px;
        \\  }
        \\}
        \\
    );
}

test "vm: media interpolation unquotes quoted feature text" {
    const css = try renderVmCssForTest(std.testing.allocator,
        \\$foo: 20px;
        \\@media screen and ("min-width:#{$foo}") {
        \\  .bar { width: 12px; }
        \\}
        \\@media screen and ("min-width:0") {
        \\  .bar { width: 12px; }
        \\}
        \\
    , null);
    defer std.testing.allocator.free(css);
    // Do not add a blank line between adjacent top-level @media rules;
    // verified against the official sass CLI 1.99.0.
    try std.testing.expectEqualStrings(
        \\@media screen and (min-width:20px) {
        \\  .bar {
        \\    width: 12px;
        \\  }
        \\}
        \\@media screen and (min-width:0) {
        \\  .bar {
        \\    width: 12px;
        \\  }
        \\}
        \\
    , css);
}

test "vm: media feature unquotes quoted literal value" {
    const css = try renderVmCssForTest(std.testing.allocator,
        \\@media screen and (min-width: '1140px') and (max-width: "1199px") {
        \\  .bar { width: 12px; }
        \\}
        \\
    , null);
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\@media screen and (min-width: 1140px) and (max-width: 1199px) {
        \\  .bar {
        \\    width: 12px;
        \\  }
        \\}
        \\
    , css);
}

test "vm: declaration serialization re-escapes identifier control escapes" {
    const css = try renderVmCssForTest(std.testing.allocator, ".a { output: \\b\\c\\d\\e\\f\\g; }\n", null);
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.a {
        \\  output: \b \c \d \e \f g;
        \\}
        \\
    , css);
}

test "vm: declaration serialization preserves literal backslash in unquoted string" {
    const css = try renderVmCssForTest(std.testing.allocator, ".a { output: \\\\; }\n", null);
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.a {
        \\  output: \\;
        \\}
        \\
    , css);
}

test "vm: declaration serialization preserves escaped punctuation identifiers" {
    const css = try renderVmCssForTest(
        std.testing.allocator,
        "$d: \\24; $at: \\40; $plus: \\2b; $slash: \\2f; $hash: \\#;\n" ++
            ".a { d: $d; at: $at; plus: $plus; slash: $slash; hash: $hash; }\n",
        null,
    );
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.a {
        \\  d: \$;
        \\  at: \@;
        \\  plus: \+;
        \\  slash: \/;
        \\  hash: \#;
        \\}
        \\
    , css);
}

test "vm: unquote preserves interpolated escaped punctuation in quoted content" {
    const css = try renderVmCssForTest(
        std.testing.allocator,
        "$d: \\24; $zero: \\30; $at: \\40;\n" ++
            ".a { d: unquote(\"\\\"#{ $d }\\\"\"); zero: unquote(\"\\\"#{ $zero }\\\"\"); at: unquote(\"\\\"#{ $at }\\\"\"); }\n",
        null,
    );
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.a {
        \\  d: "\$";
        \\  zero: "\30 ";
        \\  at: "\@";
        \\}
        \\
    , css);
}

test "vm: empty rest arg in declaration list does not leave trailing separator" {
    const css = try renderVmCssForTest(
        std.testing.allocator,
        "@mixin filter($filters...) { .a { filter: contrast(.9) brightness(1.2) $filters; width: 1 $filters; } }\n" ++
            "@include filter;\n" ++
            "@include filter(blur(2px));\n",
        null,
    );
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.a {
        \\  filter: contrast(0.9) brightness(1.2);
        \\  width: 1;
        \\}
        \\
        \\.a {
        \\  filter: contrast(0.9) brightness(1.2) blur(2px);
        \\  width: 1 blur(2px);
        \\}
        \\
    , css);
}

test "vm: unquoted empty string in declaration list does not leave separators" {
    const css = try renderVmCssForTest(
        std.testing.allocator,
        ".a { a: unquote(\"\") 1; b: 1 unquote(\"\"); c: 1 unquote(\"\") 2; d: unquote(\"\") unquote(\"\"); }\n",
        null,
    );
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.a {
        \\  a: 1;
        \\  b: 1;
        \\  c: 1 2;
        \\}
        \\
    , css);
}

test "vm: url quoted line continuation preserves internal spaces" {
    try expectVmCss(
        \\.a { e: url('x\
        \\  y  z'); }
    ,
        \\.a {
        \\  e: url("x  y  z");
        \\}
        \\
    );
}

test "vm: quoted url decodes string escapes" {
    try expectVmCss(
        \\.a { a: url("\41"); b: url("a\ b"); c: url("a\#b"); d: url("a\\b"); }
    ,
        \\.a {
        \\  a: url("A");
        \\  b: url("a b");
        \\  c: url("a#b");
        \\  d: url("a\\\\b");
        \\}
        \\
    );
}

test "vm: declaration serialization decodes hex escape in url without backslash amplification" {
    const css = try renderVmCssForTest(std.testing.allocator, ".a { output: url(\\41); }\n", null);
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.a {
        \\  output: url(A);
        \\}
        \\
    , css);
}

test "vm: declaration serialization drops consumed hex-escape delimiter space" {
    const css = try renderVmCssForTest(std.testing.allocator, ".a { output: \\61 x; }\n", null);
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.a {
        \\  output: ax;
        \\}
        \\
    , css);
}

test "vm: declaration serialization keeps control escape delimiter with single backslash" {
    const css = try renderVmCssForTest(std.testing.allocator, ".a { output: \\1a  \\1a ; }\n", null);
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.a {
        \\  output: \1a  \1a ;
        \\}
        \\
    , css);
}

test "vm: rest arglist with leading string pair stays positional list (not map)" {
    const css = try renderVmCssForTest(
        std.testing.allocator,
        "@use \"sass:list\";\n" ++
            "@use \"sass:string\";\n" ++
            "@function passthrough($args...) {@return $args}\n" ++
            ".a { output: string.quote(list.nth(passthrough(--c, d), 2)); }\n",
        null,
    );
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.a {
        \\  output: "d";
        \\}
        \\
    , css);
}

test "vm: declaration serialization preserves empty comma slot for nil list item" {
    var pool = try InternPool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var color_pool: ColorPool = .empty;
    defer color_pool.deinit(std.testing.allocator);
    var list_pool: std.ArrayListUnmanaged([]Value) = .empty;
    defer list_pool.deinit(std.testing.allocator);

    const owned = try std.testing.allocator.alloc(Value, 2);
    defer std.testing.allocator.free(owned);
    const name_id = try pool.intern("--c");
    owned[0] = Value.string(name_id, false);
    owned[1] = Value.nil_v;
    try list_pool.append(std.testing.allocator, owned);

    var number_pool: NumberPool = .empty;
    defer number_pool.deinit(std.testing.allocator);
    const out_id = try valueToInternIdDecl(
        &pool,
        &number_pool,
        std.testing.allocator,
        &list_pool,
        &color_pool,
        null,
        Value.listWithComma(0, false),
        false,
    );
    try std.testing.expectEqualStrings("--c, ", pool.get(out_id));
}

test "vm: quoted interpolation re-escapes identifier control escapes" {
    const css = try renderVmCssForTest(std.testing.allocator, ".a { output: \"#{\\b\\c\\d\\e\\f\\g}\"; }\n", null);
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.a {
        \\  output: "\\b \\c \\d \\e \\f g";
        \\}
        \\
    , css);
}

test "vm: double ampersand in value expands parent selector twice" {
    const css = try renderVmCssForTest(std.testing.allocator, ".and-and { value: true && false; }\n", null);
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.and-and {
        \\  value: true .and-and .and-and false;
        \\}
        \\
    , css);
}

test "vm: subtraction preserves quoted rhs under strict-unary parse" {
    const css = try renderVmCssForTest(std.testing.allocator, ".a { b: literal -\"quoted\"; }\n", null);
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.a {
        \\  b: literal-"quoted";
        \\}
        \\
    , css);
}

test "vm: subtraction preserves quoted lhs and rhs" {
    const css = try renderVmCssForTest(std.testing.allocator, ".a { b: \"quoted\" -\"quoted\"; }\n", null);
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.a {
        \\  b: "quoted"-"quoted";
        \\}
        \\
    , css);
}

test "vm: subtraction keeps interpolation order around hyphen" {
    const css = try renderVmCssForTest(std.testing.allocator, ".a { b: #{interpolant}-#{interpolant}; }\n", null);
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.a {
        \\  b: interpolant-interpolant;
        \\}
        \\
    , css);
}

test "vm: division preserves quoted operands" {
    const css = try renderVmCssForTest(std.testing.allocator, ".a { b: \"quoted\" /\"quoted\"; }\n", null);
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.a {
        \\  b: "quoted"/"quoted";
        \\}
        \\
    , css);
}

test "vm: indented selector newline inside brackets collapses" {
    const css = try renderVmCssForTest(std.testing.allocator, "a[\n  b]\n  c: d\n", "input.sass");
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\a[b] {
        \\  c: d;
        \\}
        \\
    , css);
}

test "vm: 1px + 2px \u{2192} 3px decl" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator, ".a { width: 1px + 2px; }");
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.a {
        \\  width: 3px;
        \\}
        \\
    , buf.items);
}

test "vm: clamp preserves mixed percent + length math" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator, ".a { width: clamp(1% + 1px, 2px, 3px); }");
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.a {
        \\  width: clamp(1% + 1px, 2px, 3px);
        \\}
        \\
    , buf.items);
}

test "vm: incompatible length addition raises SassError" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator, ".a { width: 1px + 1em; }");
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    vm.suppress_diagnostics = true;
    defer vm.deinit();

    try std.testing.expectError(error.SassError, vm.runTop());
}

test "vm: color arithmetic raises SassError" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator, ".a { add: #abc + 1; mul: 1 * #123; div: #abc / 1; }");
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try std.testing.expectError(error.SassError, vm.runTop());
}

test "vm: named color arithmetic raises SassError" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator, ".a { add: 2px + red; mul: 2px * red; mod: 2px % red; }");
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try std.testing.expectError(error.SassError, vm.runTop());
}

test "vm: modulo with infinity keeps same-sign dividend and mismatched sign yields NaN" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator,
        \\.a {
        \\  p: 5px % calc(infinity * 1px);
        \\  n: -5px % calc(-infinity * 1px);
        \\  x: 5px % calc(-infinity * 1px);
        \\}
    );
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    vm.deprecation_opts.quiet = true;
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.a {
        \\  p: 5px;
        \\  n: -5px;
        \\  x: calc(NaN * 1px);
        \\}
        \\
    , buf.items);
}

test "vm: css if() with sass() conditions resolves selected branch" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator,
        \\.a {
        \\  t: if(sass(true): c; else: d);
        \\  f: if(sass(false): c; else: d);
        \\}
    );
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.a {
        \\  t: c;
        \\  f: d;
        \\}
        \\
    , buf.items);
}

test "vm: css if rejects malformed mixed symbolic/css operator layouts" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.SassError,
        compiler_mod.parseResolveCompile(allocator, "a { b: if(sass(true) and css(1) var(--and) css(2): c) }"),
    );
    try std.testing.expectError(
        error.SassError,
        compiler_mod.parseResolveCompile(allocator, "a { b: if(not var(--not) css(): c) }"),
    );
}

test "vm: css if preserves interpolation semantics in css conditions" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator,
        \\a {
        \\  b: if(css(1) #{"and"} css(2): c);
        \\  c: if((#{"not"} css()) and sass(true): d);
        \\}
    );
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\a {
        \\  b: if(css(1) and css(2): c);
        \\  c: if(not css(): d);
        \\}
        \\
    , buf.items);
}

test "vm: css if lowers css clauses with later runtime sass branches" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator,
        \\@mixin emit($flag) {
        \\  x: if(css(1): c; sass($flag): d; else: e);
        \\}
        \\.t { @include emit(true); }
        \\.f { @include emit(false); }
    );
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.t {
        \\  x: if(css(1): c; else: d);
        \\}
        \\
        \\.f {
        \\  x: if(css(1): c; else: e);
        \\}
        \\
    , buf.items);
}

test "vm: css if() accepts trailing comma after else branch" {
    try expectVmCss(
        \\.a {
        \\  t: if(
        \\    sass(true): c; else: d,
        \\  );
        \\  f: if(
        \\    sass(false): c; else: d,
        \\  );
        \\}
    ,
        \\.a {
        \\  t: c;
        \\  f: d;
        \\}
        \\
    );
}

test "vm: legacy if() accepts rest syntax in branch positions" {
    try expectVmCss(
        \\a {
        \\  b: if(true, b, c...);
        \\  c: if(false, b, c...);
        \\}
    ,
        \\a {
        \\  b: b;
        \\  c: c;
        \\}
        \\
    );
}

test "vm: css if value keeps runtime interpolation bodies intact" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator,
        \\@mixin emit($x) {
        \\  .a { x: if(sass(true): #{$x}px); }
        \\}
        \\@include emit(12);
    );
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.a {
        \\  x: 12px;
        \\}
        \\
    , buf.items);
}

test "vm: unary plus and slash-prefix for non-number values" {
    const allocator = std.testing.allocator;
    const src =
        \\.a {
        \\  d: +foo(12px);
        \\  e: (1, /2);
        \\}
    ;
    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.a {
        \\  d: +foo(12px);
        \\  e: 1, /2;
        \\}
        \\
    , buf.items);
}

test "vm: unary signed calc() raises SassError" {
    const allocator = std.testing.allocator;
    var rp = try compiler_mod.parseResolveCompile(allocator, ".a { b: +calc(var(--c)); }");
    defer rp.pool.deinit(allocator);
    defer rp.color_pool.deinit(allocator);
    defer rp.resolved.deinit();
    defer rp.program.deinit();
    var irp = RuleIR.init();
    defer irp.deinit(allocator);
    var vmp = try VM.init(allocator, &rp.pool, &rp.color_pool, &irp, &rp.program);
    defer vmp.deinit();
    try std.testing.expectError(error.SassError, vmp.runTop());

    var rn = try compiler_mod.parseResolveCompile(allocator, ".a { b: -(calc(var(--c))); }");
    defer rn.pool.deinit(allocator);
    defer rn.color_pool.deinit(allocator);
    defer rn.resolved.deinit();
    defer rn.program.deinit();
    var irn = RuleIR.init();
    defer irn.deinit(allocator);
    var vmn = try VM.init(allocator, &rn.pool, &rn.color_pool, &irn, &rn.program);
    defer vmn.deinit();
    try std.testing.expectError(error.SassError, vmn.runTop());
}

test "vm: abs preserves css math call for unresolved argument" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator, ".a { width: abs(var(--x)); }");
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.a {
        \\  width: abs(var(--x));
        \\}
        \\
    , buf.items);
}

test "vm: abs accepts unquoted numeric string" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator, ".a { width: abs(unquote(\"-2px\")); }");
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.a {
        \\  width: 2px;
        \\}
        \\
    , buf.items);
}

test "vm: string.to-upper-case decodes escaped code points before ASCII case map" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator, "@use \"sass:string\"; .a { b: string.to-upper-case(\"\\61 b\"); }");
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.a {
        \\  b: "AB";
        \\}
        \\
    , buf.items);
}

test "vm: string.to-upper-case decodes escaped code points in unquoted identifiers" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator, "@use \"sass:string\"; .a { b: string.to-upper-case(ab\\63 d); }");
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.a {
        \\  b: ABCD;
        \\}
        \\
    , buf.items);
}

test "vm: string.to-lower-case decodes escaped code points before ASCII case map" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator, "@use \"sass:string\"; .a { b: string.to-lower-case(\"\\41 B\"); }");
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.a {
        \\  b: "ab";
        \\}
        \\
    , buf.items);
}

test "vm: string.to-lower-case preserves escaped punctuation" {
    try expectVmCss(
        \\@use "sass:string";
        \\.a { hash: string.to-lower-case('C\\#'); plus: string.to-lower-case('C\\+\\+'); bang: string.to-lower-case('A\\!'); }
        \\
    ,
        \\.a {
        \\  hash: "c\\#";
        \\  plus: "c\\+\\+";
        \\  bang: "a\\!";
        \\}
        \\
    );
}

test "vm: string.unique-id returns distinct identifier-like values" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator, "@use \"sass:string\"; .a { b: string.unique-id(); c: string.unique-id(); }");
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    const b_key = "  b: ";
    const c_key = "  c: ";
    const b_pos = std.mem.indexOf(u8, buf.items, b_key) orelse return error.TestExpectedEqual;
    const c_pos = std.mem.indexOf(u8, buf.items, c_key) orelse return error.TestExpectedEqual;

    const b_start = b_pos + b_key.len;
    const c_start = c_pos + c_key.len;
    const b_end = std.mem.indexOfScalarPos(u8, buf.items, b_start, ';') orelse return error.TestExpectedEqual;
    const c_end = std.mem.indexOfScalarPos(u8, buf.items, c_start, ';') orelse return error.TestExpectedEqual;

    const b_value = std.mem.trim(u8, buf.items[b_start..b_end], " \t\r\n");
    const c_value = std.mem.trim(u8, buf.items[c_start..c_end], " \t\r\n");

    try std.testing.expect(b_value.len >= 2 and c_value.len >= 2);
    try std.testing.expect(b_value[0] == 'u' and c_value[0] == 'u');
    try std.testing.expect(!std.mem.eql(u8, b_value, c_value));

    for (b_value[1..]) |ch| {
        try std.testing.expect(std.ascii.isHex(ch));
    }
    for (c_value[1..]) |ch| {
        try std.testing.expect(std.ascii.isHex(ch));
    }
}

test "vm: string.unique_id underscore alias resolves" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator, "@use \"sass:string\"; .a { b: string.unique_id(); }");
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    const key = "  b: ";
    const pos = std.mem.indexOf(u8, buf.items, key) orelse return error.TestExpectedEqual;
    const start = pos + key.len;
    const end = std.mem.indexOfScalarPos(u8, buf.items, start, ';') orelse return error.TestExpectedEqual;
    const value = std.mem.trim(u8, buf.items[start..end], " \t\r\n");
    try std.testing.expect(value.len >= 2);
    try std.testing.expect(value[0] == 'u');
    for (value[1..]) |ch| {
        try std.testing.expect(std.ascii.isHex(ch));
    }
}

test "vm: meta.call unknown string falls back to css function" {
    try expectVmCss(
        \\@use "sass:math";
        \\@use "sass:meta";
        \\.a { b: meta.call(missing, 1px / 2px, 1px / math.round(1.5)); }
    ,
        \\.a {
        \\  b: missing(0.5, 0.5px);
        \\}
        \\
    );
}

test "vm: meta.call unknown string rejects keyword args for css fallback" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator, "@use \"sass:meta\"; .a { b: meta.call(missing, $a: b); }");
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try std.testing.expectError(error.SassError, vm.runTop());
}

test "vm: unknown css function fallback preserves quoted string args" {
    try expectVmCss(
        \\.a { b: file_join("images", "kittens.jpg"); }
    ,
        \\.a {
        \\  b: file_join("images", "kittens.jpg");
        \\}
        \\
    );
}

test "vm: unknown css function call evaluates sass arguments" {
    try expectVmCss(
        \\@use "sass:math";
        \\.a { b: missing(1px / 2px, 1px / math.round(1.5)); }
    ,
        \\.a {
        \\  b: missing(1px/2px, 0.5px);
        \\}
        \\
    );
}

test "vm: meta.call string target matches underscore function names" {
    try expectVmCss(
        \\@use "sass:meta";
        \\@function foo_($arg...) { @return meta.type-of($arg); }
        \\.a { b: meta.call("foo_", one); }
    ,
        \\.a {
        \\  b: arglist;
        \\}
        \\
    );
}

test "vm: url raw path works as mixin argument" {
    try expectVmCss(
        \\@mixin bg($image) { background-image: $image; }
        \\a { @include bg(url(../images/icon.svg)); }
    ,
        \\a {
        \\  background-image: url(../images/icon.svg);
        \\}
        \\
    );
}

test "vm: unknown css function preserves slash-list arguments after sass evaluation" {
    try expectVmCss(
        \\.a { b: foobar(1 + 2 3/4 5 + 6, orange); }
    ,
        \\.a {
        \\  b: foobar(3 3/4 11, orange);
        \\}
        \\
    );
}

test "vm: escaped mixin names with empty arglists resolve" {
    try expectVmCss(
        \\$foo\\bar: 1;
        \\@function foo\\func() { @return 1; }
        \\@mixin foo\\mixin() { mixin-value: 1; }
        \\.test {
        \\  var-value: $foo\\bar;
        \\  func-value: foo\\func();
        \\  @include foo\\mixin();
        \\}
    ,
        \\.test {
        \\  var-value: 1;
        \\  func-value: 1;
        \\  mixin-value: 1;
        \\}
        \\
    );
}

test "vm: callable default slash literal evaluates when arg omitted" {
    try expectVmCss(
        \\@mixin bar($x: 3/4) {
        \\  bar-content: $x;
        \\}
        \\.a {
        \\  @include bar();
        \\}
    ,
        \\.a {
        \\  bar-content: 0.75;
        \\}
        \\
    );
}

test "vm: callable default unary expression can reference earlier parameter" {
    try expectVmCss(
        \\@mixin focus-ring($width: 2px, $offset: -$width, $enabled: not false) {
        \\  width: $width;
        \\  offset: $offset;
        \\  enabled: $enabled;
        \\}
        \\.a {
        \\  @include focus-ring();
        \\}
    ,
        \\.a {
        \\  width: 2px;
        \\  offset: -2px;
        \\  enabled: true;
        \\}
        \\
    );
}

test "vm: null selector interpolation after parent reference keeps current selector" {
    try expectVmCss(
        \\@mixin focus-ring($target: null) {
        \\  & #{$target} { a: b; }
        \\  &#{$target}:focus { c: d; }
        \\}
        \\button {
        \\  @include focus-ring();
        \\}
    ,
        \\button {
        \\  a: b;
        \\}
        \\button:focus {
        \\  c: d;
        \\}
        \\
    );
}

test "vm: mixin default builtin call evaluates when arg omitted" {
    try expectVmCss(
        \\@use "sass:meta";
        \\@mixin grid-image-horizontal($grid-width, $padding-width, $grid-color: hsl(0, 0%, 93%), $margin-color: $grid-color) {
        \\  same: $grid-color == $margin-color;
        \\  kind: meta.type-of($grid-color);
        \\}
        \\.a {
        \\  @include grid-image-horizontal(12px, 13px);
        \\}
    ,
        \\.a {
        \\  same: true;
        \\  kind: color;
        \\}
        \\
    );
}

test "vm: function default builtin call evaluates when arg omitted" {
    try expectVmCss(
        \\@use "sass:meta";
        \\@function fallback-color-kind($color: hsl(0, 0%, 93%)) {
        \\  @return meta.type-of($color);
        \\}
        \\.a {
        \\  kind: fallback-color-kind();
        \\}
    ,
        \\.a {
        \\  kind: color;
        \\}
        \\
    );
}

test "vm: parameter default list can contain legacy if builtin" {
    try expectVmCss(
        \\$x: a;
        \\@function f($flag, $c: $x if($flag, b, c)) { @return $c; }
        \\.a { x: f(true); y: f(false); }
    ,
        \\.a {
        \\  x: a b;
        \\  y: a c;
        \\}
        \\
    );
}

test "vm: mixin default builtin call supports nested builtin-call args when arg omitted" {
    try expectVmCss(
        \\@mixin button-variant(
        \\  $background,
        \\  $border,
        \\  $hover-background: if(true, rgb(1, 2, 3), rgb(4, 5, 6)),
        \\  $hover-border: if(false, rgb(7, 8, 9), rgb(10, 11, 12))
        \\) {
        \\  hover-background-ok: $hover-background == rgb(1, 2, 3);
        \\  hover-border-ok: $hover-border == rgb(10, 11, 12);
        \\}
        \\.a {
        \\  @include button-variant(#000, #000);
        \\}
    ,
        \\.a {
        \\  hover-background-ok: true;
        \\  hover-border-ok: true;
        \\}
        \\
    );
}

test "vm: round(number, step) evaluates css round signature" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator, ".a { width: round(117px, 25px); }");
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.a {
        \\  width: 125px;
        \\}
        \\
    , buf.items);
}

test "vm: global round with SassScript modulo still follows builtin arity" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator, ".a { width: round(7 % 3, 1); }");
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try std.testing.expectError(error.SassError, vm.runTop());
}

test "vm: round(strategy, number) preserves unresolved var() as css fallback" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator, ".a { width: round(up, var(--x)); }");
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.a {
        \\  width: round(up, var(--x));
        \\}
        \\
    , buf.items);
}

test "vm: round(strategy, number, step) evaluates strategy signature" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator, ".a { width: round(to-zero, -120px, -25px); }");
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.a {
        \\  width: -125px;
        \\}
        \\
    , buf.items);
}

test "vm: legacy global round evaluates compatible variable arithmetic" {
    try expectVmCss(
        \\$lh: 1.227;
        \\$fs: 22px;
        \\$pv: 13px;
        \\.a { min-height: round(($lh * $fs + 2 * $pv)); }
    ,
        \\.a {
        \\  min-height: 53px;
        \\}
        \\
    );
}

test "vm: legacy global round preserves css-only additive arguments" {
    try expectVmCss(
        \\$a: 1px;
        \\$b: 2em;
        \\$c: var(--x);
        \\.a { b: round($a + $b); c: round($a + $c); }
    ,
        \\.a {
        \\  b: round(1px + 2em);
        \\  c: round(1px + var(--x));
        \\}
        \\
    );
}

test "vm: legacy global round evaluates parenthesized unitless term added to percent" {
    try expectVmCss(
        \\$base-l: 29%;
        \\$x: 0.07257293850849245;
        \\.a { b: round($base-l + ($x * 53)); c: max($base-l, round($base-l + ($x * 53))); }
    ,
        \\.a {
        \\  b: 33%;
        \\  c: 33%;
        \\}
        \\
    );
}

test "vm: legacy global round evaluates unitless calc arithmetic used by later Sass math" {
    try expectVmCss(
        \\$leading: round(16 * calc(112.5 / 100) * 1.7);
        \\.a { b: #{.5 * $leading - (.5 * 4) + "px"}; }
    ,
        \\.a {
        \\  b: 13.5px;
        \\}
        \\
    );
}

test "vm: static values from nested rule scopes do not leak into following @if blocks" {
    try expectVmCss(
        \\$base: 16 * calc(100 / 100);
        \\$leading: round($base * 1.625);
        \\$base-desktop: 16 * calc(112.5 / 100);
        \\$leading-desktop: round($base-desktop * 1.7);
        \\$hr-height: 4;
        \\$hr-style: line;
        \\.a {
        \\  @media b {
        \\    $leading: $leading-desktop;
        \\    height: #{$leading + "px"};
        \\  }
        \\  @if $hr-style == line {
        \\    c: #{0.5 * $leading - (0.5 * $hr-height) + "px"};
        \\  }
        \\}
    ,
        \\@media b {
        \\  .a {
        \\    height: 31px;
        \\  }
        \\}
        \\.a {
        \\  c: 11px;
        \\}
        \\
    );
}

test "vm: @if declaration after nested media reopens parent rule in source order" {
    try expectVmCss(
        \\$ok: true;
        \\.a {
        \\  x: 1;
        \\  @media b { y: 2; }
        \\  @if $ok { z: 3; }
        \\}
    ,
        \\.a {
        \\  x: 1;
        \\}
        \\@media b {
        \\  .a {
        \\    y: 2;
        \\  }
        \\}
        \\.a {
        \\  z: 3;
        \\}
        \\
    );
}

test "vm: nested media emitted by mixin splits enclosing media before following rule" {
    try expectVmCss(
        \\@mixin t() {
        \\  transition: a;
        \\  @media (reduce) { transition: none; }
        \\}
        \\@media screen {
        \\  .a { @include t(); transform: x; }
        \\  .b { @include t(); }
        \\}
    ,
        \\@media screen {
        \\  .a {
        \\    transition: a;
        \\    transform: x;
        \\  }
        \\}
        \\@media screen and (reduce) {
        \\  .a {
        \\    transition: none;
        \\  }
        \\}
        \\@media screen {
        \\  .b {
        \\    transition: a;
        \\  }
        \\}
        \\@media screen and (reduce) {
        \\  .b {
        \\    transition: none;
        \\  }
        \\}
        \\
    );
}

test "vm: nested media inside media keeps following declarations before following nested rule" {
    try expectVmCss(
        \\@mixin t() {
        \\  transition: a;
        \\  @media (reduce) { transition: none; }
        \\}
        \\@media screen {
        \\  .a {
        \\    @include t();
        \\    transform: x;
        \\    &:before { c: d; }
        \\  }
        \\}
    ,
        \\@media screen {
        \\  .a {
        \\    transition: a;
        \\    transform: x;
        \\  }
        \\}
        \\@media screen and (reduce) {
        \\  .a {
        \\    transition: none;
        \\  }
        \\}
        \\@media screen {
        \\  .a:before {
        \\    c: d;
        \\  }
        \\}
        \\
    );
}

test "vm: mixin include expands width" {
    const allocator = std.testing.allocator;
    const src =
        \\@mixin m($w) { width: $w; }
        \\.a { @include m(5px); }
    ;
    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.a {
        \\  width: 5px;
        \\}
        \\
    , buf.items);
}

test "vm: nested rule after mid-close mixin stays before later declarations" {
    try expectVmCss(
        \\@mixin ripple {
        \\  position: relative;
        \\  &:after { content: ""; }
        \\}
        \\.btn {
        \\  border-radius: 1px;
        \\  @include ripple;
        \\  &:hover { color: red; }
        \\  color: black;
        \\  @each $name in primary { &-#{$name} { a: b; } }
        \\}
    ,
        \\.btn {
        \\  border-radius: 1px;
        \\  position: relative;
        \\}
        \\.btn:after {
        \\  content: "";
        \\}
        \\.btn:hover {
        \\  color: red;
        \\}
        \\.btn {
        \\  color: black;
        \\}
        \\.btn-primary {
        \\  a: b;
        \\}
        \\
    );
}

test "vm: nested rules before declarations preserve source order in emitted css" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator,
        \\foo {
        \\  bar { c: d }
        \\  a: b;
        \\}
    );
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\foo bar {
        \\  c: d;
        \\}
        \\foo {
        \\  a: b;
        \\}
        \\
    , buf.items);
}

test "vm: mixin comments stay inside the surrounding rule across nested output" {
    try expectVmCss(
        \\@mixin foo($x, $y) {
        \\  /* begin foo */
        \\  margin: $x $y;
        \\  blip {
        \\    hey: now;
        \\  }
        \\  /* end foo */
        \\}
        \\
        \\div {
        \\  @include foo(1, 2);
        \\  @include foo(1, 3);
        \\}
    ,
        \\div {
        \\  /* begin foo */
        \\  margin: 1 2;
        \\}
        \\div blip {
        \\  hey: now;
        \\}
        \\div {
        \\  /* end foo */
        \\  /* begin foo */
        \\  margin: 1 3;
        \\}
        \\div blip {
        \\  hey: now;
        \\}
        \\div {
        \\  /* end foo */
        \\}
        \\
    );
}

test "vm: unknown block at-rule bubbles out of parent selector" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator,
        \\.foo {
        \\  @fblthp {
        \\    .bar { a: b }
        \\  }
        \\}
    );
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\@fblthp {
        \\  .foo .bar {
        \\    a: b;
        \\  }
        \\}
        \\
    , buf.items);
}

test "vm: interpolated at-rule name evaluates before emit" {
    try expectVmCss(
        \\@use "sass:string";
        \\@mixin make($selector) {
        \\  @#{string.slice($selector, 2)} { @content; }
        \\}
        \\@include make("@function --hsv(--src-color <color>) returns <color>") {
        \\  result: red;
        \\}
    ,
        \\@function --hsv(--src-color <color>) returns <color> {
        \\  result: red;
        \\}
        \\
    );
}

test "vm: empty nested rule splits surrounding declarations" {
    try expectVmCss(
        \\.a {
        \\  x: 1;
        \\  &[b] {}
        \\  y: 2;
        \\}
    ,
        \\.a {
        \\  x: 1;
        \\}
        \\.a {
        \\  y: 2;
        \\}
        \\
    );
}

test "vm: block at-rule wraps direct declarations in current selector" {
    try expectVmCss(
        \\.foo {
        \\  @media screen {
        \\    color: red;
        \\    .bar { a: b }
        \\  }
        \\}
    ,
        \\@media screen {
        \\  .foo {
        \\    color: red;
        \\  }
        \\  .foo .bar {
        \\    a: b;
        \\  }
        \\}
        \\
    );
}

test "vm: block at-rule content call wraps caller selector" {
    try expectVmCss(
        \\@mixin mq {
        \\  @media screen {
        \\    @content;
        \\  }
        \\}
        \\.foo {
        \\  @include mq {
        \\    color: red;
        \\  }
        \\}
    ,
        \\@media screen {
        \\  .foo {
        \\    color: red;
        \\  }
        \\}
        \\
    );
}

test "vm: empty content before nested mixin rule closes caller block" {
    try expectVmCss(
        \\@mixin m {
        \\  a: b;
        \\  @content;
        \\  &:hover { c: d; }
        \\}
        \\.x {
        \\  @include m;
        \\  e: f;
        \\}
    ,
        \\.x {
        \\  a: b;
        \\}
        \\.x:hover {
        \\  c: d;
        \\}
        \\.x {
        \\  e: f;
        \\}
        \\
    );
}

test "vm: nested keyframes clear parent selector context" {
    try expectVmCss(
        \\div {
        \\  @-webkit-keyframes fade {
        \\    0% { opacity: 0; }
        \\    100% { opacity: 1; }
        \\  }
        \\}
    ,
        \\@-webkit-keyframes fade {
        \\  0% {
        \\    opacity: 0;
        \\  }
        \\  100% {
        \\    opacity: 1;
        \\  }
        \\}
        \\
    );
}

test "vm: content block nested rule closes current parent block if open" {
    try expectVmCss(
        \\@mixin wrap {
        \\  .foo {
        \\    @content;
        \\  }
        \\}
        \\@include wrap {
        \\  bar {
        \\    color: red;
        \\  }
        \\}
    ,
        \\.foo bar {
        \\  color: red;
        \\}
        \\
    );
}

test "vm: map literal duplicate keys raise SassError" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator,
        \\$a: "foo";
        \\$b: "foo";
        \\$map: (
        \\  $a: 1,
        \\  $b: 2,
        \\);
    );
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try std.testing.expectError(error.SassError, vm.runTop());
}

test "vm: @each map single variable yields pair list" {
    try expectVmCss(
        \\@each $pair in (a: 1, b: 2) {
        \\  .x { v: $pair; }
        \\}
    ,
        \\.x {
        \\  v: a 1;
        \\}
        \\
        \\.x {
        \\  v: b 2;
        \\}
        \\
    );
}

test "vm: @each list expression sees outer variable before loop variable shadow" {
    try expectVmCss(
        \\$name: double, dashed;
        \\@each $name in $name {
        \\  .border-#{$name} { border-style: #{$name} !important; }
        \\}
        \\
    ,
        \\.border-double {
        \\  border-style: double !important;
        \\}
        \\
        \\.border-dashed {
        \\  border-style: dashed !important;
        \\}
        \\
    );
}

test "vm: @each over parent selector iterates logical selector entries" {
    try expectVmCss(
        \\@use "sass:meta";
        \\.test, .other {
        \\  @each $list in & {
        \\    item: meta.inspect($list);
        \\  }
        \\}
    ,
        \\.test, .other {
        \\  item: .test;
        \\  item: .other;
        \\}
        \\
    );
}

test "vm: @each destructuring uses top-level list entries" {
    try expectVmCss(
        \\@use "sass:meta";
        \\@each $a, $b in 1, 2 3, 4 5 {
        \\  .n-#{$a} {
        \\    b: meta.inspect($b);
        \\  }
        \\}
    ,
        \\.n-1 {
        \\  b: null;
        \\}
        \\
        \\.n-2 {
        \\  b: 3;
        \\}
        \\
        \\.n-4 {
        \\  b: 5;
        \\}
        \\
    );
}

test "vm: nested property with script value emits prefix declaration and children" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator,
        \\foo {
        \\  bar: baz + bang {
        \\    bip: bop;
        \\    bing: bop;
        \\  }
        \\}
    );
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\foo {
        \\  bar: bazbang;
        \\  bar-bip: bop;
        \\  bar-bing: bop;
        \\}
        \\
    , buf.items);
}

test "vm: rest args preserve last spread separator for user callables" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator,
        \\@function foo($a, $b...) {
        \\  @return "a: #{$a}, b: #{$b}";
        \\}
        \\$list: 3 4 5;
        \\.foo { val: foo(1, 2, $list...) }
    );
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.foo {
        \\  val: "a: 1, b: 2 3 4 5";
        \\}
        \\
    , buf.items);
}

test "vm: interpolated css function call preserves quoted args" {
    try expectVmCss(
        \\$quo: quo;
        \\.a {
        \\  b: un#{$quo}te("hello");
        \\}
    ,
        \\.a {
        \\  b: unquote("hello");
        \\}
        \\
    );
}

test "vm: url-like interpolation drops inner quotes" {
    try expectVmCss(
        \\$var: "http://test.com";
        \\.a {
        \\  b: url(#{$var});
        \\  c: url-prefix(#{"https://sass-lang.com/docs"});
        \\  d: domain(#{"sass-lang.com"});
        \\}
    ,
        \\.a {
        \\  b: url(http://test.com);
        \\  c: url-prefix(https://sass-lang.com/docs);
        \\  d: domain(sass-lang.com);
        \\}
        \\
    );
}

test "vm: url content evaluates Sass function call" {
    try expectVmCss(
        \\@function font-path($name) {
        \\  @return "../webfonts/#{$name}";
        \\}
        \\.a {
        \\  src: url(font-path("fa-solid-900.woff2")) format("woff2"), url(foo.png);
        \\}
    ,
        \\.a {
        \\  src: url("../webfonts/fa-solid-900.woff2") format("woff2"), url(foo.png);
        \\}
        \\
    );
}

test "vm: named splat expands through function include and content calls" {
    try expectVmCss(
        \\@use "sass:meta";
        \\@function args-to-keywords($args...) {
        \\  @return meta.inspect(meta.keywords($args));
        \\}
        \\@mixin include-path($args...) {
        \\  include-path {
        \\    value: args-to-keywords($args...);
        \\  }
        \\}
        \\@mixin forward-content() {
        \\  @content($ignored: (content-key: content-value)...);
        \\}
        \\direct {
        \\  value: args-to-keywords($ignored: (direct-key: direct-value)...);
        \\}
        \\@include include-path($ignored: (include-key: include-value)...);
        \\@include forward-content using ($args...) {
        \\  content-path {
        \\    value: args-to-keywords($args...);
        \\  }
        \\}
    ,
        \\direct {
        \\  value: (direct-key: direct-value);
        \\}
        \\
        \\include-path {
        \\  value: (include-key: include-value);
        \\}
        \\
        \\content-path {
        \\  value: (content-key: content-value);
        \\}
        \\
    );
}

test "vm: meta.call invokes function reference" {
    const allocator = std.testing.allocator;
    const src =
        \\@use "sass:meta";
        \\@function add-two($v) { @return $v + 2px; }
        \\.a { width: meta.call(meta.get-function("add-two"), 10px); }
    ;
    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.a {
        \\  width: 12px;
        \\}
        \\
    , buf.items);
}

test "vm: meta.apply invokes mixin reference" {
    const allocator = std.testing.allocator;
    const src =
        \\@use "sass:meta";
        \\@mixin set-width($v) { width: $v; }
        \\.a { @include meta.apply(meta.get-mixin("set-width"), 6px); }
    ;
    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.a {
        \\  width: 6px;
        \\}
        \\
    , buf.items);
}

test "vm: meta.apply mixin reference sees mutated local scope variable" {
    const allocator = std.testing.allocator;
    const src =
        \\@use "sass:meta";
        \\a {
        \\  $a: x;
        \\  @mixin m { a: $a; }
        \\  $ref: meta.get-mixin("m");
        \\  $a: y;
        \\  @include meta.apply($ref);
        \\}
    ;
    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\a {
        \\  a: y;
        \\}
        \\
    , buf.items);
}

test "vm: meta.get-function local ref can escape via !global" {
    const allocator = std.testing.allocator;
    const src =
        \\@use "sass:meta";
        \\$add-two-fn: null;
        \\
        \\.scope {
        \\  @function add-two($v) {@return $v + 2}
        \\  $add-two-fn: meta.get-function(add-two) !global;
        \\}
        \\
        \\a { b: meta.call($add-two-fn, 10) }
    ;
    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\a {
        \\  b: 12;
        \\}
        \\
    , buf.items);
}

test "vm: meta.get-mixin local ref can escape via !global" {
    const allocator = std.testing.allocator;
    const src =
        \\@use "sass:meta";
        \\$add-two-mixin: null;
        \\
        \\.scope {
        \\  @mixin add-two($v) { b: $v + 2; }
        \\  $add-two-mixin: meta.get-mixin(add-two) !global;
        \\}
        \\
        \\a { @include meta.apply($add-two-mixin, 10); }
    ;
    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\a {
        \\  b: 12;
        \\}
        \\
    , buf.items);
}

test "vm: nested @content fall-through keeps outer callback" {
    const allocator = std.testing.allocator;
    const src =
        \\@use "sass:meta";
        \\@mixin a {
        \\  @content(content-rule-a);
        \\}
        \\
        \\@mixin b {
        \\  @include meta.apply(meta.get-mixin(a)) using ($content-arg) {
        \\    @content($content-arg);
        \\  }
        \\}
        \\
        \\a {
        \\  @include meta.apply(meta.get-mixin(b)) using ($content-arg) {
        \\    in-content-body: $content-arg;
        \\  }
        \\}
    ;
    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\a {
        \\  in-content-body: content-rule-a;
        \\}
        \\
    , buf.items);
}

test "vm: @content call binds named arguments to using params" {
    const allocator = std.testing.allocator;
    const src =
        \\@mixin outer {
        \\  @content($second: two, $first: one);
        \\}
        \\
        \\@include outer using ($first, $second) {
        \\  a { value: $first $second; }
        \\}
    ;
    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\a {
        \\  value: one two;
        \\}
        \\
    , buf.items);
}

test "vm: media hex escape before paren keeps delimiter space" {
    try expectVmCss(
        \\@media screen and (min-width: 0\\0) { a { b: c; } }
    ,
        \\@media screen and (min-width: 0\\0 ) {
        \\  a {
        \\    b: c;
        \\  }
        \\}
        \\
    );
}

test "vm: unused function body defers unknown namespaced builtin" {
    try expectVmCss(
        \\@use "sass:math";
        \\@function unused($x) {
        \\  @return math.unitless($x);
        \\}
        \\.x { y: ok; }
    ,
        \\.x {
        \\  y: ok;
        \\}
        \\
    );
}

test "vm: callable body can resolve later global function at call time" {
    try expectVmCss(
        \\@function remove-via-later($list, $value) {
        \\  @return replace-later($list, $value, null);
        \\}
        \\@function replace-later($list, $old, $value) {
        \\  @return b c;
        \\}
        \\.x { y: remove-via-later(a b c, a); }
    ,
        \\.x {
        \\  y: b c;
        \\}
        \\
    );
}

test "vm: mixin body resolves unqualified function calls at include time" {
    try expectVmCss(
        \\@function f() { @return before; }
        \\@mixin m { value: f(); }
        \\@function f() { @return after; }
        \\.a { @include m; }
        \\
    ,
        \\.a {
        \\  value: after;
        \\}
        \\
    );
}

test "vm: forwarded content through media keeps remapped loop locals" {
    try expectVmCss(
        \\$g: null;
        \\@mixin bp($k) {
        \\  @if $k == small { @content; }
        \\  @else { @media (min-width: 1px) { @content; } }
        \\}
        \\@mixin recursive($name: auto, $map: null) {
        \\  @if $name == auto {
        \\    @each $k, $v in $map {
        \\      @include bp($k) {
        \\        @include recursive($v, $map) { @content; }
        \\      }
        \\    }
        \\  } @else {
        \\    $g: $name !global;
        \\    @content;
        \\  }
        \\}
        \\@include recursive(auto, (small: 20px, medium: 30px)) {
        \\  .x { y: $g * 0.5; }
        \\}
    ,
        \\.x {
        \\  y: 10px;
        \\}
        \\
        \\@media (min-width: 1px) {
        \\  .x {
        \\    y: 15px;
        \\  }
        \\}
        \\
    );
}

test "vm: captured content frames are seeded with module globals" {
    try expectVmCss(
        \\$grid-row-columns: 2 !default;
        \\@mixin media { @content; }
        \\@mixin make {
        \\  @include media {
        \\    @if $grid-row-columns > 0 { .ok { x: $grid-row-columns; } }
        \\  }
        \\}
        \\@include make();
    ,
        \\.ok {
        \\  x: 2;
        \\}
        \\
    );
}

test "vm: content block captures remapped outer locals after later globals" {
    try expectVmCss(
        \\@mixin inner {
        \\  @content;
        \\}
        \\
        \\@mixin outer($n) {
        \\  $label: foo;
        \\
        \\  @include inner {
        \\    @if $n > 0 {
        \\      .#{$label} {
        \\        order: $n;
        \\      }
        \\    }
        \\  }
        \\}
        \\
        \\$later-global: 1;
        \\@include outer(2);
    ,
        \\.foo {
        \\  order: 2;
        \\}
        \\
    );
}

test "vm: nested content each loop keeps remapped loop variable slots" {
    try expectVmCss(
        \\$breakpoints: (sm: 1px, md: 2px, lg: 3px, xl: 4px);
        \\$sidebar-width: (sm: 10px, md: 20px, lg: 30px);
        \\$sidebar-narrow-width: (md: 21px, lg: 31px);
        \\$sidebar-wide-width: (lg: 32px, xl: 42px);
        \\@mixin breakpoint($breakpoint) {
        \\  $value: map-get($breakpoints, $breakpoint);
        \\  @media (min-width: $value) { @content; }
        \\}
        \\.PageLayout {
        \\  @include breakpoint(md) {
        \\    $local: keep;
        \\    @each $breakpoint in sm, md, lg {
        \\      @include breakpoint($breakpoint) { --w: #{map-get($sidebar-width, $breakpoint)}; }
        \\    }
        \\    &.narrow {
        \\      @each $breakpoint in md, lg {
        \\        @include breakpoint($breakpoint) { --w: #{map-get($sidebar-narrow-width, $breakpoint)}; }
        \\      }
        \\    }
        \\    &.wide {
        \\      @each $breakpoint in lg, xl {
        \\        @include breakpoint($breakpoint) { --w: #{map-get($sidebar-wide-width, $breakpoint)}; }
        \\      }
        \\    }
        \\  }
        \\}
    ,
        \\@media (min-width: 2px) and (min-width: 1px) {
        \\  .PageLayout {
        \\    --w: 10px;
        \\  }
        \\}
        \\@media (min-width: 2px) and (min-width: 2px) {
        \\  .PageLayout {
        \\    --w: 20px;
        \\  }
        \\}
        \\@media (min-width: 2px) and (min-width: 3px) {
        \\  .PageLayout {
        \\    --w: 30px;
        \\  }
        \\}
        \\@media (min-width: 2px) and (min-width: 2px) {
        \\  .PageLayout.narrow {
        \\    --w: 21px;
        \\  }
        \\}
        \\@media (min-width: 2px) and (min-width: 3px) {
        \\  .PageLayout.narrow {
        \\    --w: 31px;
        \\  }
        \\}
        \\@media (min-width: 2px) and (min-width: 3px) {
        \\  .PageLayout.wide {
        \\    --w: 32px;
        \\  }
        \\}
        \\@media (min-width: 2px) and (min-width: 4px) {
        \\  .PageLayout.wide {
        \\    --w: 42px;
        \\  }
        \\}
        \\
    );
}

test "vm: raw custom property preserves trailing whitespace in scss" {
    try expectVmCss(
        \\a {
        \\  --b: c ;
        \\  --d: e\t;
        \\}
    ,
        \\a {
        \\  --b: c ;
        \\  --d: e\t;
        \\}
        \\
    );
}

test "vm: raw one-line custom property collapses whitespace runs" {
    try expectVmCss(
        \\a {
        \\  --x: var(--x)  ;
        \\  --y: var(--x,   4vw);
        \\  --z: foo   "bar   baz"  qux;
        \\}
    ,
        \\a {
        \\  --x: var(--x) ;
        \\  --y: var(--x, 4vw);
        \\  --z: foo "bar   baz" qux;
        \\}
        \\
    );
}

test "vm: raw calc declaration normalizes nested var fallback whitespace" {
    try expectVmCss(
        \\a {
        \\  font-size: calc(var(--text-xxxl) + var(--text-hero-l,   4vw))
        \\}
    ,
        \\a {
        \\  font-size: calc(var(--text-xxxl) + var(--text-hero-l, 4vw));
        \\}
        \\
    );
}

test "vm: raw calc declaration preserves hyphenated identifiers" {
    try expectVmCss(
        \\a {
        \\  margin-top: calc(flow-space * 2);
        \\}
    ,
        \\a {
        \\  margin-top: calc(flow-space * 2);
        \\}
        \\
    );
}

test "vm: multiline selector segment newline moves after comma" {
    try expectVmCss(
        \\h1, .h1
        \\h2, .h2
        \\h3, .h3 {
        \\  line-height: 1.1;
        \\}
    ,
        \\h1, .h1 h2,
        \\.h2 h3,
        \\.h3 {
        \\  line-height: 1.1;
        \\}
        \\
    );
}

test "vm: escaped plus selector inside is pseudo emits rule" {
    try expectVmCss(
        \\body:is(:not(.css-settings-manager), .code-language) pre:is(.language-c\+\+, .language-cpp) { x: y; }
        \\
    ,
        \\body:is(:not(.css-settings-manager), .code-language) pre:is(.language-c\+\+, .language-cpp) {
        \\  x: y;
        \\}
        \\
    );
}

test "vm: alpha hex colors serialize through normal declaration values" {
    try expectVmCss(
        \\a {
        \\  box-shadow: inset 0 0 0 1px #ffff;
        \\  color: #000000ff;
        \\  background: #00000040;
        \\  --raw: #ffff;
        \\}
    ,
        \\a {
        \\  box-shadow: inset 0 0 0 1px white;
        \\  color: black;
        \\  background: rgba(0, 0, 0, 0.2509803922);
        \\  --raw: #ffff;
        \\}
        \\
    );
}

test "vm: alpha hex color through mixin parameter keeps named output" {
    try expectVmCss(
        \\@mixin m($c, $w) {
        \\  a {
        \\    --x: #{$c};
        \\    #{$w}: $c;
        \\    color: $c;
        \\  }
        \\}
        \\@include m(#000000ff, --y);
        \\
    ,
        \\a {
        \\  --x: black;
        \\  --y: black;
        \\  color: black;
        \\}
        \\
    );
}

test "vm: scss multiline comma list declaration is allowed" {
    try expectVmCss(
        \\.a {
        \\  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Oxygen,
        \\    Ubuntu, Cantarell, "Open Sans", "Helvetica Neue", sans-serif;
        \\}
        \\
    ,
        \\.a {
        \\  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Oxygen, Ubuntu, Cantarell, "Open Sans", "Helvetica Neue", sans-serif;
        \\}
        \\
    );
}

test "vm: indented custom property stops before next sibling declaration" {
    const allocator = std.testing.allocator;
    const src =
        \\a
        \\  --b: c
        \\
        \\d
        \\  --e: f
    ;

    const css = try renderVmCssForTest(allocator, src, "input.sass");
    defer allocator.free(css);

    try std.testing.expectEqualStrings(
        \\a {
        \\  --b: c;
        \\}
        \\
        \\d {
        \\  --e: f;
        \\}
        \\
    , css);
}

test "vm: declaration after @at-root mixin no longer errors at declaration boundary" {
    try expectVmCss(
        \\@mixin position-horizontal($start: null, $end: null) {
        \\  @at-root {
        \\    & {
        \\      inset-inline-start: $start;
        \\      inset-inline-end: $end;
        \\    }
        \\  }
        \\}
        \\@mixin position($top: null, $end: null, $bottom: null, $start: null) {
        \\  @include position-horizontal($start, $end);
        \\  top: $top;
        \\  bottom: $bottom;
        \\}
        \\a { @include position(0, 0, 0, 0); }
        \\
    ,
        // A hoisted `& { ... }` block produced by @at-root is returned before
        // the parent tail declarations, leaving them as a separate block.
        \\a {
        \\  inset-inline-start: 0;
        \\  inset-inline-end: 0;
        \\}
        \\
        \\a {
        \\  top: 0;
        \\  bottom: 0;
        \\}
        \\
    );
}

test "vm: quoted dot declaration value remains valid css" {
    try expectVmCss(
        \\.a {
        \\  content: ".";
        \\}
        \\
    ,
        \\.a {
        \\  content: ".";
        \\}
        \\
    );
}

test "vm: nested declaration after nested selector reopens outer rule" {
    try expectVmCss(
        \\$css-var-prefix: --ui-;
        \\.dialog-open {
        \\  &:not([open]),
        \\  &[open="false"] {
        \\    display: none;
        \\  }
        \\  padding-right: var(#{$css-var-prefix}scrollbar-width, 0px);
        \\  overflow: hidden;
        \\  dialog {
        \\    overflow: auto;
        \\  }
        \\}
        \\
    ,
        \\.dialog-open:not([open]), .dialog-open[open=false] {
        \\  display: none;
        \\}
        \\.dialog-open {
        \\  padding-right: var(--ui-scrollbar-width, 0px);
        \\  overflow: hidden;
        \\}
        \\.dialog-open dialog {
        \\  overflow: auto;
        \\}
        \\
    );
}

test "vm: nested empty interpolated custom property after nested selector stays attached to outer rule" {
    try expectVmCss(
        \\$prefix: bs-;
        \\.a {
        \\  &.x { color: red; }
        \\  --#{$prefix}#{null}: #{null};
        \\  color: blue;
        \\}
        \\
    ,
        \\.a.x {
        \\  color: red;
        \\}
        \\.a {
        \\  --bs-: ;
        \\  color: blue;
        \\}
        \\
    );
}

test "vm: indented inconsistent dedent stays SassError" {
    const allocator = std.testing.allocator;
    const src =
        \\a
        \\    b: c
        \\ d: e
        \\
    ;
    var r = try compiler_mod.parseResolveCompileWithPath(allocator, src, "input.sass", &.{});
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try std.testing.expectError(error.SassError, vm.runTop());
}

test "vm: meta.global-variable-exists ignores local style-rule vars" {
    const allocator = std.testing.allocator;
    const src =
        \\@use "sass:meta";
        \\a {
        \\  $local-variable: null;
        \\  b: meta.global-variable-exists(local-variable);
        \\}
    ;
    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\a {
        \\  b: false;
        \\}
        \\
    , buf.items);
}

test "vm: style-rule !global declaration does not alias later local slot" {
    const allocator = std.testing.allocator;
    const src =
        \\div {
        \\  $foo: inner !default !global;
        \\  $foo: lexical;
        \\  inner { foo: $foo; }
        \\}
        \\outer { foo: $foo; }
    ;
    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\div inner {
        \\  foo: lexical;
        \\}
        \\
        \\outer {
        \\  foo: inner;
        \\}
        \\
    , buf.items);
}

test "vm: top-level if updates existing globals but keeps new vars local" {
    const allocator = std.testing.allocator;
    const src =
        \\@use "sass:meta";
        \\$root: initial;
        \\@if true {
        \\  $root: updated;
        \\  $local: inside;
        \\}
        \\result {
        \\  root: $root;
        \\  local-exists: meta.variable-exists(local);
        \\}
    ;
    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\result {
        \\  root: updated;
        \\  local-exists: false;
        \\}
        \\
    , buf.items);
}

test "vm: callable while flow-control restores global shadows after loop" {
    const css = try renderVmCssForTest(std.testing.allocator,
        \\$flag: true;
        \\$root: initial;
        \\@function f() {
        \\  @while $flag {
        \\    $flag: false;
        \\    $root: inner;
        \\  }
        \\  $seen-flag: $flag !global;
        \\  $seen-root: $root !global;
        \\  @return null;
        \\}
        \\result {
        \\  f: f();
        \\  flag: $flag;
        \\  root: $root;
        \\  seen-flag: $seen-flag;
        \\  seen-root: $seen-root;
        \\}
        \\
    , null);
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\result {
        \\  flag: true;
        \\  root: initial;
        \\  seen-flag: true;
        \\  seen-root: initial;
        \\}
        \\
    , css);
}

test "vm: nested style-rule flow-control does not overwrite globals" {
    const css = try renderVmCssForTest(std.testing.allocator,
        \\@use "sass:meta";
        \\$root: global;
        \\wrapper {
        \\  @if true {
        \\    $root: local;
        \\    $inner: here;
        \\  }
        \\}
        \\result {
        \\  root: $root;
        \\  inner-exists: meta.variable-exists(inner);
        \\}
        \\
    , null);
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\result {
        \\  root: global;
        \\  inner-exists: false;
        \\}
        \\
    , css);
}

test "vm: top chunk nested @if assignment persists across @each iterations" {
    const css = try renderVmCssForTest(std.testing.allocator,
        \\@media (min-width: 1px) {
        \\  $flag: true;
        \\  @each $name in a, b, c {
        \\    @if $flag {
        \\      .#{$name} {
        \\        v: 1;
        \\      }
        \\      @if $name == b {
        \\        $flag: false;
        \\      }
        \\    }
        \\  }
        \\}
        \\
    , null);
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\@media (min-width: 1px) {
        \\  .a {
        \\    v: 1;
        \\  }
        \\  .b {
        \\    v: 1;
        \\  }
        \\}
        \\
    , css);
}

test "vm: @if in loop is not pruned by stale top-level static value" {
    const css = try renderVmCssForTest(std.testing.allocator,
        \\$breakpoints: (xxs: 0, xs: 360px, sm: 576px);
        \\$old-breakpoint: null;
        \\$old-breakpoint-value: null;
        \\@each $breakpoint, $breakpoint-value in $breakpoints {
        \\  @if $old-breakpoint {
        \\    @custom-media --#{$old-breakpoint}-only (#{$old-breakpoint-value} <= width <= #{$breakpoint-value});
        \\  }
        \\  $old-breakpoint: $breakpoint;
        \\  $old-breakpoint-value: $breakpoint-value;
        \\}
        \\
    , null);
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\@custom-media --xxs-only (0 <= width <= 360px);
        \\@custom-media --xs-only (360px <= width <= 576px);
        \\
    , css);
}

test "vm: content block flow locals do not alias global slot prefix under outer @if" {
    const css = try renderVmCssForTest(std.testing.allocator,
        \\@mixin inflate(
        \\  $p01: null, $p02: null, $p03: null, $p04: null, $p05: null,
        \\  $p06: null, $p07: null, $p08: null, $p09: null, $p10: null,
        \\  $p11: null, $p12: null, $p13: null, $p14: null, $p15: null,
        \\  $p16: null, $p17: null, $p18: null, $p19: null, $p20: null
        \\) {}
        \\
        \\@mixin wrap($cond) {
        \\  @if $cond {
        \\    @content;
        \\  } @else {
        \\    @content;
        \\  }
        \\}
        \\
        \\@if true {
        \\  @each $bp in a, b {
        \\    @include wrap(true) {
        \\      $flag: true;
        \\      @each $name in a, b, c {
        \\        @if $flag {
        \\          .probe-#{$bp}-#{$name} {
        \\            v: 1;
        \\          }
        \\          @if $bp == $name {
        \\            $flag: false;
        \\          }
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
        \\
    , null);
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.probe-a-a {
        \\  v: 1;
        \\}
        \\
        \\.probe-b-a {
        \\  v: 1;
        \\}
        \\
        \\.probe-b-b {
        \\  v: 1;
        \\}
        \\
    , css);
}

test "vm: false meta.variable-exists guard skips unresolved var branch" {
    const allocator = std.testing.allocator;
    const src =
        \\@use "sass:meta";
        \\result {
        \\  @if meta.variable-exists(missing) {
        \\    value: $missing;
        \\  }
        \\  after: ok;
        \\}
    ;
    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\result {
        \\  after: ok;
        \\}
        \\
    , buf.items);
}

test "vm: meta.content-exists errors outside mixin" {
    const allocator = std.testing.allocator;
    const src =
        \\@use "sass:meta";
        \\a { b: meta.content-exists(); }
    ;
    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try std.testing.expectError(error.SassError, vm.runTop());
}

test "vm: meta.get-function css callable stays plain CSS" {
    const allocator = std.testing.allocator;
    const src =
        \\@use "sass:meta";
        \\.a { width: meta.call(meta.get-function("round", $css: true), 1.9); }
    ;
    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.a {
        \\  width: round(1.9);
        \\}
        \\
    , buf.items);
}

test "vm: meta.call(get-function(\"rgb\")) keeps rgb functional output" {
    const allocator = std.testing.allocator;
    const src =
        \\@use "sass:meta";
        \\.a { b: meta.call(meta.get-function("rgb"), $blue: 1, $green: 2, $red: 3); }
    ;
    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.a {
        \\  b: rgb(3, 2, 1);
        \\}
        \\
    , buf.items);
}

test "vm: meta.keywords accepts named $args forwarding" {
    const allocator = std.testing.allocator;
    const src =
        \\@use "sass:meta";
        \\@function args-to-keywords($args...) {
        \\  @return meta.keywords($args: $args);
        \\}
        \\.a { b: meta.inspect(args-to-keywords($c: d)); }
    ;
    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.a {
        \\  b: (c: d);
        \\}
        \\
    , buf.items);
}

test "vm: meta.keywords rejects non-arglist list" {
    const allocator = std.testing.allocator;
    const src =
        \\@use "sass:meta";
        \\.a { b: meta.keywords(1 2 3); }
    ;
    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try std.testing.expectError(error.BuiltinType, vm.runTop());
}

test "vm: meta.feature-exists is dash-sensitive" {
    const allocator = std.testing.allocator;
    const src =
        \\@use "sass:meta";
        \\.a {
        \\  ok: meta.feature-exists(at-error);
        \\  ng: meta.feature-exists(at_error);
        \\}
    ;
    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.a {
        \\  ok: true;
        \\  ng: false;
        \\}
        \\
    , buf.items);
}

test "vm: color.to-gamut requires explicit method" {
    const allocator = std.testing.allocator;
    const src =
        \\@use "sass:color";
        \\.a { b: color.to-gamut(#abcdef); }
    ;
    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try std.testing.expectError(error.SassError, vm.runTop());
}

test "vm: color.is-powerless invalid channel raises SassError" {
    const allocator = std.testing.allocator;
    const src =
        \\@use "sass:color";
        \\.a { b: color.is-powerless(black, "RED"); }
    ;
    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try std.testing.expectError(error.SassError, vm.runTop());
}

test "vm: @error aborts with SassError" {
    const allocator = std.testing.allocator;
    const src = "@error \"boom\";";
    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try std.testing.expectError(error.SassError, vm.runTop());
}

test "vm: ordering comparison with null aborts with SassError" {
    const allocator = std.testing.allocator;
    const src =
        \\$v: null;
        \\.a { x: if($v > 0, 1, 0); }
    ;
    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try std.testing.expectError(error.SassError, vm.runTop());
}

test "vm: @debug does not abort execution" {
    const allocator = std.testing.allocator;
    const src =
        \\@debug "hello";
        \\.a { color: red; }
    ;
    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.a {
        \\  color: red;
        \\}
        \\
    , buf.items);
}

fn writeFileAll(path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir_path| {
        try std.Io.Dir.cwd().createDirPath(zsass_io.io, dir_path);
    }
    const file = try std.Io.Dir.cwd().createFile(zsass_io.io, path, .{ .truncate = true });
    defer file.close(zsass_io.io);
    var fb: [2048]u8 = undefined;
    var fw = file.writerStreaming(zsass_io.io, &fb);
    try fw.interface.writeAll(bytes);
    try fw.flush();
}

fn compileWithEntryPathToCss(
    allocator: std.mem.Allocator,
    source: []const u8,
    entry_path: []const u8,
    load_paths: []const []const u8,
) ![]u8 {
    var r = try compiler_mod.parseResolveCompileWithPath(allocator, source, entry_path, load_paths);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();
    try vm.runTop();

    var css: std.ArrayList(u8) = .empty;
    errdefer css.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &css);
        try rule_ir.writeTo(&w.writer, &r.pool);
        css = w.toArrayList();
    }
    return try css.toOwnedSlice(allocator);
}

fn compileWithAstCacheToCss(
    allocator: std.mem.Allocator,
    source: []const u8,
    entry_path: []const u8,
    load_paths: []const []const u8,
) ![]u8 {
    var pool = try InternPool.init(allocator);
    defer pool.deinit(allocator);

    var ast_cache = ast_cache_mod.ParsedAstCache.init(allocator, &pool);
    defer ast_cache.deinit();

    var r = try compiler_mod.parseResolveCompileWithPoolPhaseTimerCachesAndPersistent(
        allocator,
        source,
        entry_path,
        load_paths,
        null,
        &pool,
        null,
        &ast_cache,
        null,
        null,
    );
    defer if (!r.borrowed_color_pool) r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();
    try vm.runTop();

    var css: std.ArrayList(u8) = .empty;
    errdefer css.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &css);
        try rule_ir.writeTo(&w.writer, &pool);
        css = w.toArrayList();
    }
    return try css.toOwnedSlice(allocator);
}

test "vm: ast cache converts imported indented syntax before parsing" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const tmp_sub = td.sub_path[0..];
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_sub});
    defer allocator.free(root);
    const part_path = try std.fmt.allocPrint(allocator, "{s}/_part.sass", .{root});
    defer allocator.free(part_path);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.scss", .{root});
    defer allocator.free(entry_path);

    try writeFileAll(part_path,
        \\@keyframes spinAround
        \\  from
        \\    transform: rotate(0deg)
        \\  to
        \\    transform: rotate(359deg)
        \\.button
        \\  &:hover,
        \\  &.state-hover
        \\    color: red
    );
    try writeFileAll(entry_path,
        \\@import "part";
    );

    const css = try compileWithAstCacheToCss(allocator,
        \\@import "part";
    , entry_path, &.{root});
    defer allocator.free(css);

    try std.testing.expectEqualStrings(
        \\@keyframes spinAround {
        \\  from {
        \\    transform: rotate(0deg);
        \\  }
        \\  to {
        \\    transform: rotate(359deg);
        \\  }
        \\}
        \\.button:hover, .button.state-hover {
        \\  color: red;
        \\}
        \\
    , css);
}

test "vm: placeholder chain transitive extenders keep later-declared selector order" {
    try expectVmCss(
        \\%control { x: y; }
        \\%input { @extend %control; y: z; }
        \\.button { @extend %control; }
        \\.input { @extend %input; }
        \\.textarea { @extend %input; }
        \\.select select { @extend %input; }
        \\.file-name { @extend %control; }
    ,
        \\.file-name, .button, .select select, .textarea, .input {
        \\  x: y;
        \\}
        \\
        \\.select select, .textarea, .input {
        \\  y: z;
        \\}
        \\
    );
}

test "vm: placeholder branch pseudo selectors keep original branch order" {
    try expectVmCss(
        \\%control {
        \\  &:focus,
        \\  &.state-focused,
        \\  &:active,
        \\  &.state-active { outline: none; }
        \\}
        \\%input { @extend %control; }
        \\.button { @extend %control; }
        \\.input { @extend %input; }
        \\.textarea { @extend %input; }
        \\.select select { @extend %input; }
        \\.file-name { @extend %control; }
    ,
        \\.file-name:focus, .button:focus, .select select:focus, .textarea:focus, .input:focus, .state-focused.file-name, .state-focused.button, .select select.state-focused, .state-focused.textarea, .state-focused.input, .file-name:active, .button:active, .select select:active, .textarea:active, .input:active, .state-active.file-name, .state-active.button, .select select.state-active, .state-active.textarea, .state-active.input {
        \\  outline: none;
        \\}
        \\
    );
}

test "vm: placeholder branch disabled selectors keep original branch order" {
    try expectVmCss(
        \\%control {
        \\  &[disabled],
        \\  fieldset[disabled] & { cursor: not-allowed; }
        \\}
        \\%input { @extend %control; }
        \\.button { @extend %control; }
        \\.input { @extend %input; }
        \\.textarea { @extend %input; }
        \\.select select { @extend %input; }
        \\.file-name { @extend %control; }
    ,
        \\[disabled].file-name, [disabled].button, .select select[disabled], [disabled].textarea, [disabled].input, fieldset[disabled] .file-name, fieldset[disabled] .button, fieldset[disabled] .select select, .select fieldset[disabled] select, fieldset[disabled] .textarea, fieldset[disabled] .input {
        \\  cursor: not-allowed;
        \\}
        \\
    );
}

test "vm: calc interpolation preserves parens around negative number" {
    try expectVmCss(
        \\$x: -4px;
        \\.a { top: calc(100% + (#{$x})); }
    ,
        \\.a {
        \\  top: calc(100% + (-4px));
        \\}
        \\
    );
}

test "vm: if-wrapped content block does not hoist nested include out of content body" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const tmp_sub = td.sub_path[0..];
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_sub});
    defer allocator.free(root);
    const tools_path = try std.fmt.allocPrint(allocator, "{s}/tools/_index.scss", .{root});
    defer allocator.free(tools_path);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.scss", .{root});
    defer allocator.free(entry_path);

    try writeFileAll(tools_path,
        \\@mixin elevation($z) {
        \\  & { value: #{$z * 2%}; }
        \\}
        \\@mixin layer($name) {
        \\  @at-root (without: layer) {
        \\    @layer x-#{$name} {
        \\      @content;
        \\    }
        \\  }
        \\}
    );
    try writeFileAll(entry_path,
        \\@use "sass:list";
        \\@use "tools";
        \\@if (list.length((a)) > 0) {
        \\  @property --x {
        \\    syntax: "<color>";
        \\    inherits: false;
        \\    initial-value: transparent;
        \\  }
        \\
        \\  @include tools.layer("helpers") {
        \\    @for $z from 0 through 2 {
        \\      .e-#{$z} {
        \\        @include tools.elevation($z);
        \\      }
        \\    }
        \\  }
        \\}
    );

    const css = try compileWithEntryPathToCss(allocator,
        \\@use "sass:list";
        \\@use "tools";
        \\@if (list.length((a)) > 0) {
        \\  @property --x {
        \\    syntax: "<color>";
        \\    inherits: false;
        \\    initial-value: transparent;
        \\  }
        \\
        \\  @include tools.layer("helpers") {
        \\    @for $z from 0 through 2 {
        \\      .e-#{$z} {
        \\        @include tools.elevation($z);
        \\      }
        \\    }
        \\  }
        \\}
    , entry_path, &.{root});
    defer allocator.free(css);

    // The official sass CLI 1.99.0 emits no blank line here.
    try std.testing.expectEqualStrings(
        \\@property --x {
        \\  syntax: "<color>";
        \\  inherits: false;
        \\  initial-value: transparent;
        \\}
        \\@layer x-helpers {
        \\  .e-0 {
        \\    value: 0%;
        \\  }
        \\  .e-1 {
        \\    value: 2%;
        \\  }
        \\  .e-2 {
        \\    value: 4%;
        \\  }
        \\}
        \\
    , css);
}

test "vm: mixin two-pass lowering keeps assign_var after preceding control flow" {
    try expectVmCss(
        \\@use "sass:list";
        \\@mixin utility($value) {
        \\  $modifier: "";
        \\  @if list.nth($value, 1) {
        \\    $modifier: "-" + list.nth($value, 1);
        \\  }
        \\  $value: list.nth($value, 2);
        \\  .foo#{$modifier} {
        \\    color: $value;
        \\  }
        \\}
        \\@include utility((hover red));
    ,
        \\.foo-hover {
        \\  color: red;
        \\}
        \\
    );
}

test "vm: user module may use builtin-like namespace when builtin is not loaded" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const tmp_sub = td.sub_path[0..];
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_sub});
    defer allocator.free(root);
    const color_path = try std.fmt.allocPrint(allocator, "{s}/_color.scss", .{root});
    defer allocator.free(color_path);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.scss", .{root});
    defer allocator.free(entry_path);

    try writeFileAll(color_path,
        \\$brand: red;
    );
    try writeFileAll(entry_path,
        \\@use "color";
        \\a { b: color.$brand; }
    );

    const css = try compileWithEntryPathToCss(allocator,
        \\@use "color";
        \\a { b: color.$brand; }
    , entry_path, &.{root});
    defer allocator.free(css);

    try std.testing.expectEqualStrings(
        \\a {
        \\  b: red;
        \\}
        \\
    , css);
}

test "vm: parameter defaults may call namespaced user functions" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const tmp_sub = td.sub_path[0..];
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_sub});
    defer allocator.free(root);
    const cv_path = try std.fmt.allocPrint(allocator, "{s}/_cv.scss", .{root});
    defer allocator.free(cv_path);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.scss", .{root});
    defer allocator.free(entry_path);

    try writeFileAll(cv_path,
        \\@function getVar($name) {
        \\  @return red;
        \\}
    );
    try writeFileAll(entry_path,
        \\@use "cv";
        \\@mixin arrow($color: cv.getVar("arrow-color")) {
        \\  color: $color;
        \\}
        \\a { @include arrow; }
    );

    const css = try compileWithEntryPathToCss(allocator,
        \\@use "cv";
        \\@mixin arrow($color: cv.getVar("arrow-color")) {
        \\  color: $color;
        \\}
        \\a { @include arrow; }
    , entry_path, &.{root});
    defer allocator.free(css);

    try std.testing.expectEqualStrings(
        \\a {
        \\  color: red;
        \\}
        \\
    , css);
}

test "vm: unresolved parameter defaults are not evaluated until omitted" {
    try expectVmCss(
        \\@mixin maybe($color: missing.$color) {
        \\  color: $color;
        \\}
        \\a { @include maybe(red); }
    ,
        \\a {
        \\  color: red;
        \\}
        \\
    );

    try std.testing.expectError(
        error.BuiltinArity,
        expectVmCss(
            \\@mixin maybe($color: missing.$color) {
            \\  color: $color;
            \\}
            \\a { @include maybe; }
        ,
            "",
        ),
    );
}

test "vm: math.round accepts modulo expressions in normal SassScript" {
    try expectVmCss(
        \\@use "sass:math";
        \\a { b: math.round(53% % 10); }
    ,
        \\a {
        \\  b: 3%;
        \\}
        \\
    );
}

test "vm: selector line comments are stripped before selector normalization" {
    try expectVmCss(
        \\button,
        \\[type=button], // 1
        \\[type=reset],
        \\[type=submit] {
        \\  appearance: button;
        \\}
    ,
        \\button,
        \\[type=button],
        \\[type=reset],
        \\[type=submit] {
        \\  appearance: button;
        \\}
        \\
    );
}

test "vm: selector line comments may contain slash-separated URLs" {
    try expectVmCss(
        \\abbr[title],
        \\// Add data-* attribute, see https://github.com/twbs/generic helper/issues/5257
        \\abbr[data-original-title] {
        \\  cursor: help;
        \\}
    ,
        \\abbr[title],
        \\abbr[data-original-title] {
        \\  cursor: help;
        \\}
        \\
    );
}

test "vm: nested selector attribute value may contain escaped quote" {
    try expectVmCss(
        \\li[data-task],
        \\input[type="checkbox"][data-task]:checked {
        \\  &[data-task=">"],
        \\  &[data-task='"'],
        \\  &[data-task="<"] {
        \\    &,
        \\    input[type="checkbox"]:checked {
        \\      x: y;
        \\    }
        \\  }
        \\}
    ,
        \\li[data-task][data-task=">"],
        \\li[data-task][data-task=">"] input[type=checkbox]:checked, li[data-task][data-task='"'],
        \\li[data-task][data-task='"'] input[type=checkbox]:checked, li[data-task][data-task="<"],
        \\li[data-task][data-task="<"] input[type=checkbox]:checked,
        \\input[type=checkbox][data-task]:checked[data-task=">"],
        \\input[type=checkbox][data-task]:checked[data-task=">"] input[type=checkbox]:checked,
        \\input[type=checkbox][data-task]:checked[data-task='"'],
        \\input[type=checkbox][data-task]:checked[data-task='"'] input[type=checkbox]:checked,
        \\input[type=checkbox][data-task]:checked[data-task="<"],
        \\input[type=checkbox][data-task]:checked[data-task="<"] input[type=checkbox]:checked {
        \\  x: y;
        \\}
        \\
    );
}

fn latestAssignExprForSlot(resolved: *const resolver_mod.ResolvedProgram, slot: resolver_mod.SlotId) ?resolver_mod.ExprIndex {
    var found: ?resolver_mod.ExprIndex = null;
    for (resolved.assign_stmts.items) |assign| {
        if (assign.slot == slot) found = assign.value_expr;
    }
    return found;
}

test "vm: plain css @use hoists direct media block around parent selector" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const tmp_sub = td.sub_path[0..];
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_sub});
    defer allocator.free(root);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.scss", .{root});
    defer allocator.free(entry_path);
    const plain_path = try std.fmt.allocPrint(allocator, "{s}/plain.css", .{root});
    defer allocator.free(plain_path);

    const entry_source =
        \\@use "plain";
        \\
    ;
    const plain_source =
        \\a {
        \\  @media b {
        \\    c: d;
        \\  }
        \\}
        \\
    ;

    try writeFileAll(entry_path, entry_source);
    try writeFileAll(plain_path, plain_source);

    const css = try compileWithEntryPathToCss(allocator, entry_source, entry_path, &.{root});
    defer allocator.free(css);

    try std.testing.expectEqualStrings(
        \\@media b {
        \\  a {
        \\    c: d;
        \\  }
        \\}
        \\
    , css);
}

test "vm: imported plain css top-level & stays nested under parent rule" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const tmp_sub = td.sub_path[0..];
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_sub});
    defer allocator.free(root);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.scss", .{root});
    defer allocator.free(entry_path);
    const plain_path = try std.fmt.allocPrint(allocator, "{s}/plain.css", .{root});
    defer allocator.free(plain_path);

    const entry_source =
        \\a {@import "plain"}
        \\
    ;
    const plain_source =
        \\& {b {c: d}}
        \\
    ;

    try writeFileAll(entry_path, entry_source);
    try writeFileAll(plain_path, plain_source);

    const css = try compileWithEntryPathToCss(allocator, entry_source, entry_path, &.{root});
    defer allocator.free(css);

    try std.testing.expectEqualStrings(
        \\a {
        \\  & {
        \\    b {
        \\      c: d;
        \\    }
        \\  }
        \\}
        \\
    , css);
}

test "vm: function default var resolves after later @import" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const tmp_sub = td.sub_path[0..];
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_sub});
    defer allocator.free(root);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.scss", .{root});
    defer allocator.free(entry_path);
    const fn_path = try std.fmt.allocPrint(allocator, "{s}/_functions.scss", .{root});
    defer allocator.free(fn_path);
    const vars_path = try std.fmt.allocPrint(allocator, "{s}/_variables.scss", .{root});
    defer allocator.free(vars_path);

    const functions_src =
        \\@function use-gap($v: $theme-gap) {
        \\  @return $v;
        \\}
        \\
    ;
    const vars_src =
        \\$theme-gap: 7px;
        \\
    ;
    const entry_src =
        \\@import "functions";
        \\@import "variables";
        \\.a { width: use-gap(); }
        \\
    ;
    try writeFileAll(fn_path, functions_src);
    try writeFileAll(vars_path, vars_src);
    try writeFileAll(entry_path, entry_src);

    const css = try compileWithEntryPathToCss(allocator, entry_src, entry_path, &.{root});
    defer allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.a {
        \\  width: 7px;
        \\}
        \\
    , css);
}

test "vm: callable global fallback does not collide with later flow locals" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const tmp_sub = td.sub_path[0..];
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_sub});
    defer allocator.free(root);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.scss", .{root});
    defer allocator.free(entry_path);

    const entry_src =
        \\@mixin generate-utility($values) {
        \\  @each $key, $value in $values {
        \\    $properties: margin;
        \\    $state: hover;
        \\    $property-class: m;
        \\    $property-class-modifier: if(sass($key): "-" + $key; else: "");
        \\    @if $value != null {
        \\      @if false {
        \\        @each $pseudo in $state { .x-#{$pseudo}:#{$pseudo} { --x: #{$value}; } }
        \\      } @else {
        \\        .#{$property-class + $property-class-modifier} {
        \\          @each $property in $properties {
        \\            #{$property}: $value if(sass($enable-important-utilities): !important; else: null);
        \\          }
        \\        }
        \\        @each $pseudo in $state {
        \\          .#{$property-class + $property-class-modifier}-#{$pseudo}:#{$pseudo} {
        \\            @each $property in $properties { #{$property}: $value if(sass($enable-important-utilities): !important; else: null); }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
        \\$enable-important-utilities: true !default;
        \\@include generate-utility((7: 3rem, 8: 4rem, 9: 5rem));
        \\
    ;
    try writeFileAll(entry_path, entry_src);

    const css = try compileWithEntryPathToCss(allocator, entry_src, entry_path, &.{root});
    defer allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.m-7 {
        \\  margin: 3rem !important;
        \\}
        \\
        \\.m-7-hover:hover {
        \\  margin: 3rem !important;
        \\}
        \\
        \\.m-8 {
        \\  margin: 4rem !important;
        \\}
        \\
        \\.m-8-hover:hover {
        \\  margin: 4rem !important;
        \\}
        \\
        \\.m-9 {
        \\  margin: 5rem !important;
        \\}
        \\
        \\.m-9-hover:hover {
        \\  margin: 5rem !important;
        \\}
        \\
    , css);
}

test "vm: mixin default var resolves after later @import" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const tmp_sub = td.sub_path[0..];
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_sub});
    defer allocator.free(root);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.scss", .{root});
    defer allocator.free(entry_path);
    const mixin_path = try std.fmt.allocPrint(allocator, "{s}/_functions.scss", .{root});
    defer allocator.free(mixin_path);
    const vars_path = try std.fmt.allocPrint(allocator, "{s}/_variables.scss", .{root});
    defer allocator.free(vars_path);

    const mixin_src =
        \\@mixin apply-gap($v: $theme-gap) {
        \\  width: $v;
        \\}
        \\
    ;
    const vars_src =
        \\$theme-gap: 11px;
        \\
    ;
    const entry_src =
        \\@import "functions";
        \\@import "variables";
        \\.a { @include apply-gap(); }
        \\
    ;
    try writeFileAll(mixin_path, mixin_src);
    try writeFileAll(vars_path, vars_src);
    try writeFileAll(entry_path, entry_src);

    const css = try compileWithEntryPathToCss(allocator, entry_src, entry_path, &.{root});
    defer allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.a {
        \\  width: 11px;
        \\}
        \\
    , css);
}

test "vm: variable-exists stays false before configured !default declaration via @use with" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const tmp_sub = td.sub_path[0..];
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_sub});
    defer allocator.free(root);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.scss", .{root});
    defer allocator.free(entry_path);
    const other_path = try std.fmt.allocPrint(allocator, "{s}/_other.scss", .{root});
    defer allocator.free(other_path);

    const other_src =
        \\@use "sass:meta";
        \\$before-declaration: meta.variable-exists(a);
        \\$a: original !default;
        \\b {
        \\  before-declaration: $before-declaration;
        \\  after-declaration: meta.variable-exists(a);
        \\  final-value: $a;
        \\}
        \\
    ;
    const entry_src =
        \\@use "other" with ($a: configured);
        \\
    ;
    try writeFileAll(other_path, other_src);
    try writeFileAll(entry_path, entry_src);

    const css = try compileWithEntryPathToCss(allocator, entry_src, entry_path, &.{root});
    defer allocator.free(css);
    try std.testing.expectEqualStrings(
        \\b {
        \\  before-declaration: false;
        \\  after-declaration: true;
        \\  final-value: configured;
        \\}
        \\
    , css);
}

test "vm: variable-exists stays false before configured !default declaration via @forward with" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const tmp_sub = td.sub_path[0..];
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_sub});
    defer allocator.free(root);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.scss", .{root});
    defer allocator.free(entry_path);
    const midstream_path = try std.fmt.allocPrint(allocator, "{s}/_midstream.scss", .{root});
    defer allocator.free(midstream_path);
    const upstream_path = try std.fmt.allocPrint(allocator, "{s}/_upstream.scss", .{root});
    defer allocator.free(upstream_path);

    const midstream_src =
        \\@forward "upstream" with ($a: configured);
        \\
    ;
    const upstream_src =
        \\@use "sass:meta";
        \\$before-declaration: meta.variable-exists(a);
        \\$a: original !default;
        \\b {
        \\  before-declaration: $before-declaration;
        \\  after-declaration: meta.variable-exists(a);
        \\  final-value: $a;
        \\}
        \\
    ;
    const entry_src =
        \\@use "midstream";
        \\
    ;
    try writeFileAll(midstream_path, midstream_src);
    try writeFileAll(upstream_path, upstream_src);
    try writeFileAll(entry_path, entry_src);

    const css = try compileWithEntryPathToCss(allocator, entry_src, entry_path, &.{root});
    defer allocator.free(css);
    try std.testing.expectEqualStrings(
        \\b {
        \\  before-declaration: false;
        \\  after-declaration: true;
        \\  final-value: configured;
        \\}
        \\
    , css);
}

test "vm: @extend can target placeholders from forwarded modules" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const tmp_sub = td.sub_path[0..];
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_sub});
    defer allocator.free(root);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.scss", .{root});
    defer allocator.free(entry_path);
    const forwarder_path = try std.fmt.allocPrint(allocator, "{s}/_forwarder.scss", .{root});
    defer allocator.free(forwarder_path);
    const upstream_path = try std.fmt.allocPrint(allocator, "{s}/_upstream.scss", .{root});
    defer allocator.free(upstream_path);

    const entry_src =
        \\@use "forwarder";
        \\
    ;
    try writeFileAll(forwarder_path,
        \\@forward "upstream";
        \\.y { @extend %x; }
        \\
    );
    try writeFileAll(upstream_path,
        \\%x { color: red; }
        \\
    );
    try writeFileAll(entry_path, entry_src);

    const css = try compileWithEntryPathToCss(allocator, entry_src, entry_path, &.{root});
    defer allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.y {
        \\  color: red;
        \\}
        \\
    , css);
}

test "vm: @use placeholder extenders keep source order within module group" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const tmp_sub = td.sub_path[0..];
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_sub});
    defer allocator.free(root);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.scss", .{root});
    defer allocator.free(entry_path);
    const lib_path = try std.fmt.allocPrint(allocator, "{s}/_lib.scss", .{root});
    defer allocator.free(lib_path);

    const entry_src =
        \\@use "lib";
        \\.a { @extend %overlay; }
        \\.b { @extend %overlay; }
        \\
    ;
    try writeFileAll(lib_path,
        \\%overlay { x: y; }
        \\
    );
    try writeFileAll(entry_path, entry_src);

    const css = try compileWithEntryPathToCss(allocator, entry_src, entry_path, &.{root});
    defer allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.a, .b {
        \\  x: y;
        \\}
        \\
    , css);
}

test "vm: @forward ignores duplicate private default variables" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const tmp_sub = td.sub_path[0..];
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_sub});
    defer allocator.free(root);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.scss", .{root});
    defer allocator.free(entry_path);
    const a_path = try std.fmt.allocPrint(allocator, "{s}/_a.scss", .{root});
    defer allocator.free(a_path);
    const b_path = try std.fmt.allocPrint(allocator, "{s}/_b.scss", .{root});
    defer allocator.free(b_path);

    try writeFileAll(a_path,
        \\$_shared: a !default;
        \\@mixin a() {}
        \\
    );
    try writeFileAll(b_path,
        \\$_shared: b !default;
        \\@mixin b() {}
        \\
    );
    const entry_src =
        \\@forward "a";
        \\@forward "b";
        \\
    ;
    try writeFileAll(entry_path, entry_src);

    const css = try compileWithEntryPathToCss(allocator, entry_src, entry_path, &.{root});
    defer allocator.free(css);
    try std.testing.expectEqualStrings("", css);
}

test "vm: placeholder-before-visible target sorts module extenders before visible original" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const tmp_sub = td.sub_path[0..];
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_sub});
    defer allocator.free(root);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.scss", .{root});
    defer allocator.free(entry_path);
    const common_path = try std.fmt.allocPrint(allocator, "{s}/_common.scss", .{root});
    defer allocator.free(common_path);
    const popovers_path = try std.fmt.allocPrint(allocator, "{s}/widgets/_popovers.scss", .{root});
    defer allocator.free(popovers_path);
    const app_path = try std.fmt.allocPrint(allocator, "{s}/widgets/_app-notification.scss", .{root});
    defer allocator.free(app_path);
    const misc_path = try std.fmt.allocPrint(allocator, "{s}/widgets/_misc.scss", .{root});
    defer allocator.free(misc_path);

    const entry_src =
        \\@use "common";
        \\@use "widgets/popovers";
        \\@use "widgets/app-notification";
        \\@use "widgets/misc";
        \\
    ;
    try writeFileAll(common_path,
        \\%osd, .osd { a: 1; }
        \\
    );
    try writeFileAll(popovers_path,
        \\@forward "../common";
        \\popover.background {
        \\  .csd &, & {
        \\    &.touch-selection,
        \\    &.magnifier { @extend %osd; }
        \\    &.osd { @extend %osd; }
        \\  }
        \\}
        \\
    );
    try writeFileAll(app_path,
        \\@forward "../common";
        \\.app-notification,
        \\.app-notification.frame { @extend %osd; }
        \\
    );
    try writeFileAll(misc_path,
        \\@forward "../common";
        \\.scale-popup { .osd & { @extend %osd; } }
        \\
    );
    try writeFileAll(entry_path, entry_src);

    const css = try compileWithEntryPathToCss(allocator, entry_src, entry_path, &.{root});
    defer allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.osd .scale-popup, .app-notification,
        \\.app-notification.frame, .csd popover.background.touch-selection, .csd popover.background.magnifier, popover.background.touch-selection, popover.background.magnifier, .csd popover.background.osd, popover.background.osd, .osd {
        \\  a: 1;
        \\}
        \\
    , css);
}

test "vm: false configurable default prunes skipped @if branch with undefined variable" {
    const css = try renderVmCssForTest(
        std.testing.allocator,
        "$enable-dark-mode: false !default;\n" ++
            "$enable-dark-mode: true !default;\n" ++
            "@if $enable-dark-mode { $x: $undefined; }\n" ++
            ".a { b: ok; }\n",
        null,
    );
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.a {
        \\  b: ok;
        \\}
        \\
    , css);
}

test "vm: @use with arithmetic expression evaluates at resolve time" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const tmp_sub = td.sub_path[0..];
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_sub});
    defer allocator.free(root);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.scss", .{root});
    defer allocator.free(entry_path);
    const other_path = try std.fmt.allocPrint(allocator, "{s}/_theme.scss", .{root});
    defer allocator.free(other_path);

    const other_src =
        \\$spacing: 0px !default;
        \\.theme {
        \\  gap: $spacing;
        \\}
        \\
    ;
    const entry_src =
        \\$scale: 3;
        \\@use "theme" with ($spacing: 1px * $scale);
        \\
    ;
    try writeFileAll(other_path, other_src);
    try writeFileAll(entry_path, entry_src);

    const css = try compileWithEntryPathToCss(allocator, entry_src, entry_path, &.{root});
    defer allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.theme {
        \\  gap: 3px;
        \\}
        \\
    , css);
}

test "vm: @forward with configurable calc variable evaluates at resolve time" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const tmp_sub = td.sub_path[0..];
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_sub});
    defer allocator.free(root);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.scss", .{root});
    defer allocator.free(entry_path);
    const target_path = try std.fmt.allocPrint(allocator, "{s}/_target.scss", .{root});
    defer allocator.free(target_path);

    try writeFileAll(target_path,
        \\$x: null !default;
        \\.target {
        \\  width: $x;
        \\}
        \\
    );
    const entry_src =
        \\$x: calc(var(--foo) * 4) !default;
        \\@forward "target" with ($x: $x);
        \\
    ;
    try writeFileAll(entry_path, entry_src);

    const css = try compileWithEntryPathToCss(allocator, entry_src, entry_path, &.{root});
    defer allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.target {
        \\  width: calc(var(--foo) * 4);
        \\}
        \\
    , css);
}

test "vm: @use with config can read composite configurable defaults" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const tmp_sub = td.sub_path[0..];
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_sub});
    defer allocator.free(root);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.scss", .{root});
    defer allocator.free(entry_path);
    const target_path = try std.fmt.allocPrint(allocator, "{s}/_target.scss", .{root});
    defer allocator.free(target_path);

    try writeFileAll(target_path,
        \\$x: null !default;
        \\.target {
        \\  width: inspect($x);
        \\}
        \\
    );
    const entry_src =
        \\$a: var(--a) !default;
        \\$x: (h1: (font-size: $a, margin: 0 0 var(--b))) !default;
        \\@use "target" with ($x: $x);
        \\
    ;
    try writeFileAll(entry_path, entry_src);

    const css = try compileWithEntryPathToCss(allocator, entry_src, entry_path, &.{root});
    defer allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.target {
        \\  width: (h1: (font-size: var(--a), margin: 0 0 var(--b)));
        \\}
        \\
    , css);
}

test "vm: @forward keeps placeholder extends module-local" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const tmp_sub = td.sub_path[0..];
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_sub});
    defer allocator.free(root);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.scss", .{root});
    defer allocator.free(entry_path);
    const a_path = try std.fmt.allocPrint(allocator, "{s}/_a.scss", .{root});
    defer allocator.free(a_path);
    const b_path = try std.fmt.allocPrint(allocator, "{s}/_b.scss", .{root});
    defer allocator.free(b_path);

    const entry_src =
        \\@forward "a";
        \\@forward "b";
        \\
    ;
    const a_src =
        \\.a {
        \\  %x { k: v; }
        \\  > .b { @extend %x; }
        \\}
        \\
    ;
    const b_src =
        \\.c {
        \\  %x { k: v; }
        \\  > .d { @extend %x; }
        \\}
        \\
    ;

    try writeFileAll(entry_path, entry_src);
    try writeFileAll(a_path, a_src);
    try writeFileAll(b_path, b_src);

    const css = try compileWithEntryPathToCss(allocator, entry_src, entry_path, &.{root});
    defer allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.a > .b {
        \\  k: v;
        \\}
        \\.c > .d {
        \\  k: v;
        \\}
        \\
    , css);
}

test "vm: @forward with arithmetic expression evaluates at resolve time" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const tmp_sub = td.sub_path[0..];
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_sub});
    defer allocator.free(root);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.scss", .{root});
    defer allocator.free(entry_path);
    const mid_path = try std.fmt.allocPrint(allocator, "{s}/_mid.scss", .{root});
    defer allocator.free(mid_path);
    const theme_path = try std.fmt.allocPrint(allocator, "{s}/_theme.scss", .{root});
    defer allocator.free(theme_path);

    const mid_src =
        \\$scale: 3;
        \\@forward "theme" with ($spacing: 1px * $scale);
        \\
    ;
    const theme_src =
        \\$spacing: 0px !default;
        \\.theme {
        \\  gap: $spacing;
        \\}
        \\
    ;
    const entry_src =
        \\@use "mid";
        \\
    ;
    try writeFileAll(mid_path, mid_src);
    try writeFileAll(theme_path, theme_src);
    try writeFileAll(entry_path, entry_src);

    const css = try compileWithEntryPathToCss(allocator, entry_src, entry_path, &.{root});
    defer allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.theme {
        \\  gap: 3px;
        \\}
        \\
    , css);
}

test "vm: forwarded configurable cross-module var stays dynamic until runtime config is known" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const tmp_sub = td.sub_path[0..];
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_sub});
    defer allocator.free(root);
    const module_a_dir = try std.fmt.allocPrint(allocator, "{s}/module/a", .{root});
    defer allocator.free(module_a_dir);
    const module_b_dir = try std.fmt.allocPrint(allocator, "{s}/module/b", .{root});
    defer allocator.free(module_b_dir);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.scss", .{root});
    defer allocator.free(entry_path);
    const index_path = try std.fmt.allocPrint(allocator, "{s}/module/_index.scss", .{root});
    defer allocator.free(index_path);
    const a_entry_path = try std.fmt.allocPrint(allocator, "{s}/module/a/a.scss", .{root});
    defer allocator.free(a_entry_path);
    const a_vars_path = try std.fmt.allocPrint(allocator, "{s}/module/a/_variables.scss", .{root});
    defer allocator.free(a_vars_path);
    const b_entry_path = try std.fmt.allocPrint(allocator, "{s}/module/b/b.scss", .{root});
    defer allocator.free(b_entry_path);
    const b_vars_path = try std.fmt.allocPrint(allocator, "{s}/module/b/_variables.scss", .{root});
    defer allocator.free(b_vars_path);

    try std.Io.Dir.cwd().createDirPath(zsass_io.io, module_a_dir);
    try std.Io.Dir.cwd().createDirPath(zsass_io.io, module_b_dir);

    const entry_src =
        \\@use "module" with (
        \\  $a: a,
        \\  $b: b,
        \\);
        \\
    ;
    const index_src =
        \\@forward "./a/a";
        \\@forward "./b/b";
        \\
    ;
    const a_entry_src =
        \\@forward "./variables";
        \\@use "./variables" as *;
        \\.a {
        \\  content: #{$a};
        \\}
        \\
    ;
    const b_entry_src =
        \\@forward "./variables";
        \\@use "./variables" as *;
        \\.b {
        \\  content: #{$b};
        \\}
        \\
    ;

    try writeFileAll(entry_path, entry_src);
    try writeFileAll(index_path, index_src);
    try writeFileAll(a_entry_path, a_entry_src);
    try writeFileAll(a_vars_path, "$a: default !default;\n");
    try writeFileAll(b_entry_path, b_entry_src);
    try writeFileAll(b_vars_path, "$b: default !default;\n");

    const css = try compileWithEntryPathToCss(allocator, entry_src, entry_path, &.{root});
    defer allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.a {
        \\  content: a;
        \\}
        \\
        \\.b {
        \\  content: b;
        \\}
        \\
    , css);
}

test "vm: @use with config reaches simple forwarded mutable defaults" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const tmp_sub = td.sub_path[0..];
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_sub});
    defer allocator.free(root);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.scss", .{root});
    defer allocator.free(entry_path);
    const index_path = try std.fmt.allocPrint(allocator, "{s}/_index.scss", .{root});
    defer allocator.free(index_path);
    const lib_path = try std.fmt.allocPrint(allocator, "{s}/_lib.scss", .{root});
    defer allocator.free(lib_path);

    const entry_src =
        \\@use "index" with ($rtl: true);
        \\.rtl { #{index.$side}: 1px; }
        \\
    ;
    const index_src =
        \\@forward "lib";
        \\
    ;
    const lib_src =
        \\$rtl: false !default;
        \\$side: "right" !default;
        \\@if $rtl { $side: "left"; }
        \\
    ;
    try writeFileAll(entry_path, entry_src);
    try writeFileAll(index_path, index_src);
    try writeFileAll(lib_path, lib_src);

    const css = try compileWithEntryPathToCss(allocator, entry_src, entry_path, &.{root});
    defer allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.rtl {
        \\  left: 1px;
        \\}
        \\
    , css);
}

test "vm: interpolation preserves quoted strings while evaluating function args" {
    try expectVmCss(
        \\@use "sass:color";
        \\@use "sass:meta";
        \\.x {
        \\  a: #{color.channel(#fafafa, "red", $space: rgb)};
        \\  b: #{meta.type-of("red")};
        \\  c: #{"red"};
        \\}
    ,
        \\.x {
        \\  a: 250;
        \\  b: string;
        \\  c: red;
        \\}
        \\
    );
}

test "vm: @forward header loud comment replays only for direct @use of first forwarded module" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const tmp_sub = td.sub_path[0..];
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_sub});
    defer allocator.free(root);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.scss", .{root});
    defer allocator.free(entry_path);
    const index_path = try std.fmt.allocPrint(allocator, "{s}/_index.scss", .{root});
    defer allocator.free(index_path);
    const shared_path = try std.fmt.allocPrint(allocator, "{s}/_shared.scss", .{root});
    defer allocator.free(shared_path);
    const a_path = try std.fmt.allocPrint(allocator, "{s}/_a.scss", .{root});
    defer allocator.free(a_path);
    const b_path = try std.fmt.allocPrint(allocator, "{s}/_b.scss", .{root});
    defer allocator.free(b_path);

    try writeFileAll(entry_path,
        \\@use "index";
        \\
    );
    try writeFileAll(index_path,
        \\/* Header */
        \\@charset "utf-8";
        \\@forward "shared";
        \\@forward "a";
        \\@forward "b";
        \\
    );
    try writeFileAll(shared_path,
        \\.shared { x: y; }
        \\
    );
    try writeFileAll(a_path,
        \\@use "shared";
        \\.a { x: y; }
        \\
    );
    try writeFileAll(b_path,
        \\.b { x: y; }
        \\
    );

    const css = try compileWithEntryPathToCss(allocator,
        \\@use "index";
        \\
    , entry_path, &.{root});
    defer allocator.free(css);
    try std.testing.expectEqualStrings(
        \\/* Header */
        \\.shared {
        \\  x: y;
        \\} /* Header */
        \\.a {
        \\  x: y;
        \\}
        \\
        \\.b {
        \\  x: y;
        \\}
        \\
    , css);
}

test "vm: meta.load-css runtime config overrides forwarded !default seed with multi-word values" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const tmp_sub = td.sub_path[0..];
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_sub});
    defer allocator.free(root);
    const case_dir = try std.fmt.allocPrint(allocator, "{s}/through_default", .{root});
    defer allocator.free(case_dir);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.scss", .{case_dir});
    defer allocator.free(entry_path);
    const loaded_path = try std.fmt.allocPrint(allocator, "{s}/_loaded.scss", .{case_dir});
    defer allocator.free(loaded_path);
    const forwarded_path = try std.fmt.allocPrint(allocator, "{s}/_forwarded.scss", .{case_dir});
    defer allocator.free(forwarded_path);

    try writeFileAll(entry_path,
        \\@use "sass:meta";
        \\@include meta.load-css("loaded", $with: (a: from input));
        \\
    );
    try writeFileAll(loaded_path,
        \\@forward "forwarded" with ($a: from loaded !default);
        \\
    );
    try writeFileAll(forwarded_path,
        \\$a: from forwarded !default;
        \\b {c: $a}
        \\
    );

    const css = try compileWithEntryPathToCss(allocator,
        \\@use "sass:meta";
        \\@include meta.load-css("loaded", $with: (a: from input));
        \\
    , entry_path, &.{case_dir});
    defer allocator.free(css);
    try std.testing.expectEqualStrings(
        \\b {
        \\  c: from input;
        \\}
        \\
    , css);
}

test "vm: meta.load-css runtime config reaches forwarded unconfigured defaults" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const tmp_sub = td.sub_path[0..];
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_sub});
    defer allocator.free(root);
    const case_dir = try std.fmt.allocPrint(allocator, "{s}/through_unconfigured", .{root});
    defer allocator.free(case_dir);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.scss", .{case_dir});
    defer allocator.free(entry_path);
    const loaded_path = try std.fmt.allocPrint(allocator, "{s}/_loaded.scss", .{case_dir});
    defer allocator.free(loaded_path);
    const forwarded_path = try std.fmt.allocPrint(allocator, "{s}/_forwarded.scss", .{case_dir});
    defer allocator.free(forwarded_path);

    try writeFileAll(entry_path,
        \\@use "sass:meta";
        \\@include meta.load-css("loaded", $with: (a: from input));
        \\
    );
    try writeFileAll(loaded_path,
        \\@forward "forwarded" with ($b: from loaded);
        \\
    );
    try writeFileAll(forwarded_path,
        \\$a: from forwarded !default;
        \\$b: from forwarded !default;
        \\c {
        \\  a: $a;
        \\  b: $b;
        \\}
        \\
    );

    const css = try compileWithEntryPathToCss(allocator,
        \\@use "sass:meta";
        \\@include meta.load-css("loaded", $with: (a: from input));
        \\
    , entry_path, &.{case_dir});
    defer allocator.free(css);
    try std.testing.expectEqualStrings(
        \\c {
        \\  a: from input;
        \\  b: from loaded;
        \\}
        \\
    , css);
}

test "vm: meta.load-css leaves unconfigured defaults intact for multi-word values" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const tmp_sub = td.sub_path[0..];
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_sub});
    defer allocator.free(root);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.scss", .{root});
    defer allocator.free(entry_path);
    const other_path = try std.fmt.allocPrint(allocator, "{s}/_other.scss", .{root});
    defer allocator.free(other_path);

    try writeFileAll(entry_path,
        \\@use "sass:meta";
        \\@include meta.load-css("other", $with: (a: configured a));
        \\
    );
    try writeFileAll(other_path,
        \\$a: original a !default;
        \\$b: original b !default;
        \\
        \\c {
        \\  a: $a;
        \\  b: $b;
        \\}
        \\
    );

    const css = try compileWithEntryPathToCss(allocator,
        \\@use "sass:meta";
        \\@include meta.load-css("other", $with: (a: configured a));
        \\
    , entry_path, &.{root});
    defer allocator.free(css);
    try std.testing.expectEqualStrings(
        \\c {
        \\  a: configured a;
        \\  b: original b;
        \\}
        \\
    , css);
}

test "vm: @use with list expression seeds runtime list values" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const tmp_sub = td.sub_path[0..];
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_sub});
    defer allocator.free(root);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.scss", .{root});
    defer allocator.free(entry_path);
    const other_path = try std.fmt.allocPrint(allocator, "{s}/_theme.scss", .{root});
    defer allocator.free(other_path);

    const other_src =
        \\@use "sass:list";
        \\$vals: 0 !default;
        \\.theme {
        \\  second: list.nth($vals, 2);
        \\}
        \\
    ;
    const entry_src =
        \\@use "theme" with ($vals: 1px 2px 3px);
        \\
    ;
    try writeFileAll(other_path, other_src);
    try writeFileAll(entry_path, entry_src);

    const css = try compileWithEntryPathToCss(allocator, entry_src, entry_path, &.{root});
    defer allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.theme {
        \\  second: 2px;
        \\}
        \\
    , css);
}

test "vm: configured module forwards initial config through nested @use with local variables" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const tmp_sub = td.sub_path[0..];
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_sub});
    defer allocator.free(root);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.scss", .{root});
    defer allocator.free(entry_path);
    const include_path = try std.fmt.allocPrint(allocator, "{s}/_include.scss", .{root});
    defer allocator.free(include_path);
    const settings_path = try std.fmt.allocPrint(allocator, "{s}/_settings.scss", .{root});
    defer allocator.free(settings_path);

    const entry_src =
        \\@use "include" with ($os: "linux", $theme: "dark");
        \\
    ;
    const include_src =
        \\$os: "" !default;
        \\$theme: "" !default;
        \\@use "settings" with ($os: $os, $theme: $theme);
        \\
    ;
    const settings_src =
        \\$os: "" !default;
        \\$theme: "" !default;
        \\:root {
        \\  os: $os;
        \\  theme: $theme;
        \\}
        \\
    ;
    try writeFileAll(entry_path, entry_src);
    try writeFileAll(include_path, include_src);
    try writeFileAll(settings_path, settings_src);

    const css = try compileWithEntryPathToCss(allocator, entry_src, entry_path, &.{root});
    defer allocator.free(css);
    try std.testing.expectEqualStrings(
        \\:root {
        \\  os: "linux";
        \\  theme: "dark";
        \\}
        \\
    , css);
}

test "vm: @use with color literal seeds runtime color values" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const tmp_sub = td.sub_path[0..];
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_sub});
    defer allocator.free(root);
    const entry_path = try std.fmt.allocPrint(allocator, "{s}/entry.scss", .{root});
    defer allocator.free(entry_path);
    const other_path = try std.fmt.allocPrint(allocator, "{s}/_theme.scss", .{root});
    defer allocator.free(other_path);

    const other_src =
        \\$c: #000 !default;
        \\.theme {
        \\  red: red($c);
        \\}
        \\
    ;
    const entry_src =
        \\@use "theme" with ($c: #123456);
        \\
    ;
    try writeFileAll(other_path, other_src);
    try writeFileAll(entry_path, entry_src);

    const css = try compileWithEntryPathToCss(allocator, entry_src, entry_path, &.{root});
    defer allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.theme {
        \\  red: 18;
        \\}
        \\
    , css);
}

test "vm: resolver_eval matches runtime for top-level arithmetic assignment" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator,
        \\$scale: 3;
        \\$value: 1px * $scale;
    );
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    const root_id = r.resolved.root_index;
    const resolved = &r.resolved.modules[root_id];
    const slot = resolved.global_slots.get("value") orelse return error.TestExpectedEqual;
    const expr_idx = latestAssignExprForSlot(resolved, slot) orelse return error.TestExpectedEqual;

    var eval_env: ResolverEvalTestEnv = .{
        .alloc = allocator,
        .module_id = root_id,
        .pool_ptr = &r.pool,
        .color_pool_ptr = &r.color_pool,
        .resolved_modules = r.resolved.modules,
        .config_seeds = r.program.module_config_seeds,
        .static_eval_lists = r.resolved.static_eval_lists,
    };
    defer eval_env.number_pool_storage.deinit(allocator);
    defer eval_env.list_meta_pool_storage.deinit(allocator);
    defer eval_env.string_flags_pool_storage.deinit(allocator);
    defer eval_env.callable_payload_pool_storage.deinit(allocator);
    const static_value = try resolver_eval.eval(&eval_env, resolved, expr_idx);

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);
    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();
    vm.keep_mod_globals_after_run = true;
    try vm.runTop();

    // The number handle of runtime_value indexes the VM's number_pool, but
    // eval_env.numberPool() is test local pool. valueEq is env.numberPool()
    // Re-intern runtime_value to eval_env pool to resolve handle.
    const runtime_value_raw = vm.mod_globals_bufs[root_id][slot];
    const runtime_value = if (runtime_value_raw.kind() == .number)
        try value_mod.Value.number(
            runtime_value_raw.asF64(&vm.number_pool),
            runtime_value_raw.unitId(&vm.number_pool),
            eval_env.numberPool(),
            allocator,
        )
    else
        runtime_value_raw;
    try std.testing.expect(resolver_eval.valueEq(&eval_env, static_value, runtime_value));
}

test "vm: case-insensitive clamp/hypot resolve as calculation builtins" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(
        allocator,
        ".a { c1: ClAmP(1px, 0px, 3px); c2: hYpOt(1, 2); }",
    );
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);
    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.a {
        \\  c1: 1px;
        \\  c2: 2.2360679775;
        \\}
        \\
    , buf.items);
}

test "vm: slash-free arithmetic coerces slash list into numeric value" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(
        allocator,
        ".a { b: -7px / 4em * 1em; }",
    );
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);
    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.a {
        \\  b: -1.75px;
        \\}
        \\
    , buf.items);
}

test "vm: slash-free equality coerces slash list into numeric value" {
    const css = try renderVmCssForTest(std.testing.allocator,
        \\foo {
        \\  a: 1/2 == 0.5;
        \\  b: (1/2) == 0.5;
        \\}
        \\
    , null);
    defer std.testing.allocator.free(css);

    try std.testing.expectEqualStrings(
        \\foo {
        \\  a: true;
        \\  b: true;
        \\}
        \\
    , css);
}

test "vm: number units unescape sass identifier escapes" {
    const css = try renderVmCssForTest(std.testing.allocator,
        \\a { b: 1\65 _em--_--e0; }
        \\
    , null);
    defer std.testing.allocator.free(css);

    try std.testing.expectEqualStrings(
        \\a {
        \\  b: 1e_em--_--e0;
        \\}
        \\
    , css);
}

test "vm: escaped slash number unit survives string concatenation" {
    const css = try renderVmCssForTest(std.testing.allocator,
        \\@use "sass:string";
        \\@function str-replace($string, $search, $replace: "") {
        \\  $index: string.index($string, $search);
        \\  @if $index {
        \\    @return string.slice($string, 1, $index - 1) + $replace + str-replace(string.slice($string, $index + string.length($search)), $search, $replace);
        \\  }
        \\  @return $string;
        \\}
        \\$map: (1\/2: x);
        \\@each $key, $value in $map {
        \\  $name: w + "-" + $key;
        \\  a { name: $name; idx: string.index($name, "\\/"); repl: str-replace($name, "\\/", "-"); }
        \\}
        \\
    , null);
    defer std.testing.allocator.free(css);

    try std.testing.expectEqualStrings(
        \\a {
        \\  name: w-1\/2;
        \\  idx: 4;
        \\  repl: w-1-2;
        \\}
        \\
    , css);
}

test "vm: nested import function captures import-scope variables" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);

    const theme_path = try std.fs.path.join(allocator, &.{ tmp_path, "_theme.scss" });
    defer allocator.free(theme_path);
    try writeFileAll(theme_path,
        \\$crust: black !default;
        \\@function f($x) { @return mix($x, $crust, 50%); }
        \\a { color: f(red); }
        \\
    );

    const latte_path = try std.fs.path.join(allocator, &.{ tmp_path, "_latte.scss" });
    defer allocator.free(latte_path);
    try writeFileAll(latte_path,
        \\$crust: white;
        \\
    );

    const entry_path = try std.fs.path.join(allocator, &.{ tmp_path, "entry.scss" });
    defer allocator.free(entry_path);

    const css = try renderVmCssForTest(allocator,
        \\.dark { @import "theme"; }
        \\.light { @import "latte"; @import "theme"; }
        \\
    , entry_path);
    defer allocator.free(css);

    try std.testing.expectEqualStrings(
        \\.dark a {
        \\  color: rgb(127.5, 0, 0);
        \\}
        \\
        \\.light a {
        \\  color: rgb(255, 127.5, 127.5);
        \\}
        \\
    , css);
}

test "vm: slash-free user function arguments evaluate as division" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator,
        \\@function passthrough($v) {@return $v}
        \\.a { b: passthrough(1/2); }
    );
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);
    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.a {
        \\  b: 0.5;
        \\}
        \\
    , buf.items);
}

test "vm: color constructor builtins preserve raw calc strings before coercion" {
    const css = try renderVmCssForTest(std.testing.allocator,
        \\@use "sass:string";
        \\.a {
        \\  b: hsl(string.unquote("calc(1)"), 2%, 3%);
        \\  c: rgb(string.unquote("calc(1)"), 2, 3, 0.4);
        \\}
        \\
    , null);
    defer std.testing.allocator.free(css);

    try std.testing.expectEqualStrings(
        \\.a {
        \\  b: hsl(calc(1), 2%, 3%);
        \\  c: rgb(calc(1), 2, 3, 0.4);
        \\}
        \\
    , css);
}

test "vm: rgba color alpha passthrough preserves fractional channels" {
    const css = try renderVmCssForTest(std.testing.allocator,
        \\.a {
        \\  c1: rgba(mix(white, #e9ecef, 80%), var(--a));
        \\  c2: rgb(mix(white, #e9ecef, 80%), var(--a));
        \\}
        \\
    , null);
    defer std.testing.allocator.free(css);

    try std.testing.expectEqualStrings(
        \\.a {
        \\  c1: rgba(250.6, 251.2, 251.8, var(--a));
        \\  c2: rgb(250.6, 251.2, 251.8, var(--a));
        \\}
        \\
    , css);
}

test "vm: global opacity keeps unquoted calc strings" {
    const css = try renderVmCssForTest(std.testing.allocator,
        \\@use "sass:string";
        \\.a {
        \\  b: opacity(string.unquote("calc(1)"));
        \\}
        \\
    , null);
    defer std.testing.allocator.free(css);

    try std.testing.expectEqualStrings(
        \\.a {
        \\  b: opacity(calc(1));
        \\}
        \\
    , css);
}

test "vm: clamp rejects top-level rest args in calculation syntax" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(
        allocator,
        ".a { c: clamp(1px 2px 3px...); }",
    );
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);
    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try std.testing.expectError(error.SassError, vm.runTop());
}

test "vm: comparableNumbers converts compatible length units" {
    var pool = try InternPool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var number_pool: NumberPool = .empty;
    defer number_pool.deinit(std.testing.allocator);

    const one_cm = (try parseSimpleNumberish(&pool, &number_pool, std.testing.allocator, "1cm")).?;
    const five_mm = (try parseSimpleNumberish(&pool, &number_pool, std.testing.allocator, "5mm")).?;
    const pair = try VM.comparableNumbers(&pool, &number_pool, std.testing.allocator, one_cm, five_mm);

    try std.testing.expectApproxEqAbs(@as(f64, 1.0), pair.a, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), pair.b, 1e-12);
}

test "vm: comparableNumbers converts compatible generated units" {
    var pool = try InternPool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var number_pool: NumberPool = .empty;
    defer number_pool.deinit(std.testing.allocator);

    const lhs = (try parseSimpleNumberish(&pool, &number_pool, std.testing.allocator, "23in/2fu")).?;
    const rhs = (try parseSimpleNumberish(&pool, &number_pool, std.testing.allocator, "23cm/2fu")).?;
    const pair = try VM.comparableNumbers(&pool, &number_pool, std.testing.allocator, lhs, rhs);

    try std.testing.expect(pair.a > pair.b);
}

test "vm: comparableNumbers rejects incompatible units" {
    var pool = try InternPool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    var number_pool: NumberPool = .empty;
    defer number_pool.deinit(std.testing.allocator);

    const one_second = (try parseSimpleNumberish(&pool, &number_pool, std.testing.allocator, "1s")).?;
    const one_px = (try parseSimpleNumberish(&pool, &number_pool, std.testing.allocator, "1px")).?;

    try std.testing.expectError(error.SassError, VM.comparableNumbers(&pool, &number_pool, std.testing.allocator, one_second, one_px));
}

test "vm: @for descending loop preserves fixed direction" {
    const allocator = std.testing.allocator;
    const src =
        \\.a {
        \\  @for $i from 3 through 1 {
        \\    b#{$i}: $i;
        \\  }
        \\}
    ;
    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);
    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.a {
        \\  b3: 3;
        \\  b2: 2;
        \\  b1: 1;
        \\}
        \\
    , buf.items);
}

test "vm: @for body assignment does not change iteration cursor" {
    try expectVmCss(
        \\.a {
        \\  @for $i from 1 through 3 {
        \\    before#{$i}: $i;
        \\    $i: 999;
        \\    after#{$i}: $i;
        \\  }
        \\}
    ,
        \\.a {
        \\  before1: 1;
        \\  after999: 999;
        \\  before2: 2;
        \\  after999: 999;
        \\  before3: 3;
        \\  after999: 999;
        \\}
        \\
    );
}

test "vm: top-level !global in @for does not alias loop slots" {
    try expectVmCss(
        \\@for $i from 1 through 2 {
        \\  $g: outer !global;
        \\  .a-#{$i} { value: $i; }
        \\}
        \\result { value: $g; }
    ,
        \\.a-1 {
        \\  value: 1;
        \\}
        \\
        \\.a-2 {
        \\  value: 2;
        \\}
        \\
        \\result {
        \\  value: outer;
        \\}
        \\
    );
}

test "vm: nested @each/@for selector interpolation with arithmetic stays scoped to the rule" {
    try expectVmCss(
        \\$colors: (yellow: yellow,);
        \\@each $name, $color in $colors {
        \\  @for $i from 0 through 0 {
        \\    .#{$name}-#{($i*100)} {
        \\      color: red;
        \\    }
        \\  }
        \\}
    ,
        \\.yellow-0 {
        \\  color: red;
        \\}
        \\
    );
}

test "vm: interpolation coerces slash-free variable refs to numbers" {
    try expectVmCss(
        \\$x: 10px / 5px;
        \\test {
        \\  font-size: #{$x};
        \\}
    ,
        \\test {
        \\  font-size: 2;
        \\}
        \\
    );
}

test "vm: selector pseudo leading child combinator gains space" {
    try expectVmCss(
        \\.orbit:has(>*:is(.orbit, [class*='orbit-'])),
        \\[class*='orbit-']:has(>*:is(.orbit, [class*='orbit-'])) { x: y; }
    ,
        \\.orbit:has(> *:is(.orbit, [class*=orbit-])),
        \\[class*=orbit-]:has(> *:is(.orbit, [class*=orbit-])) {
        \\  x: y;
        \\}
        \\
    );
}

test "vm: direct slash interpolation preserves slash list text" {
    try expectVmCss(
        \\test {
        \\  a: #{10px/5px};
        \\  b: #{100%/3};
        \\}
    ,
        \\test {
        \\  a: 10px/5px;
        \\  b: 100%/3;
        \\}
        \\
    );
}

test "vm: calc declaration text simplifies slash arithmetic after interpolation" {
    try expectVmCss(
        \\$content-width: 960px;
        \\test {
        \\  padding: 0 calc(100%/2 - #{$content-width/2});
        \\}
    ,
        \\test {
        \\  padding: 0 calc(50% - 480px);
        \\}
        \\
    );
}

test "vm: calc interpolation preserves literal slash number text" {
    try expectVmCss(
        \\test {
        \\  width: calc(#{100% / 3} - #{1.5rem * (1 / 3)});
        \\}
    ,
        \\test {
        \\  width: calc(100%/3 - 0.5rem);
        \\}
        \\
    );
}

test "vm: calc interpolation preserves parens around interpolated operand" {
    try expectVmCss(
        \\$difference: 55;
        \\test {
        \\  padding-right: calc(175px + (#{$difference}) * (100vw - 300px) / 660);
        \\}
    ,
        \\test {
        \\  padding-right: calc(175px + (55) * (100vw - 300px) / 660);
        \\}
        \\
    );
}

test "vm: dynamic declaration calc interpolation preserves parens around interpolated operand" {
    try expectVmCss(
        \\$property: padding-right;
        \\$difference: 55;
        \\test {
        \\  #{$property}: calc(175px + (#{$difference}) * (100vw - 300px) / 660);
        \\}
    ,
        \\test {
        \\  padding-right: calc(175px + (55) * (100vw - 300px) / 660);
        \\}
        \\
    );
}

test "vm: generic add() calc branch preserves incompatible relative length addition" {
    try expectVmCss(
        \\@function add($value1, $value2, $return-calc: true) {
        \\  @if $value1 == null {
        \\    @return $value2;
        \\  }
        \\  @if $value2 == null {
        \\    @return $value1;
        \\  }
        \\  @if type-of($value1) == number and type-of($value2) == number and comparable($value1, $value2) {
        \\    @return $value1 + $value2;
        \\  }
        \\  @return if($return-calc == true, calc(#{$value1} + #{$value2}), $value1 + unquote(" + ") + $value2);
        \\}
        \\$input-line-height: 1.5;
        \\$input-padding-y: .375rem;
        \\.field {
        \\  height: add($input-line-height * 1em, $input-padding-y * 2);
        \\}
    ,
        \\.field {
        \\  height: calc(1.5em + 0.75rem);
        \\}
        \\
    );
}

test "vm: generic add(false) concatenates calc-like fragments" {
    try expectVmCss(
        \\@function add($value1, $value2, $return-calc: true) {
        \\  @if $value1 == null {
        \\    @return $value2;
        \\  }
        \\  @if $value2 == null {
        \\    @return $value1;
        \\  }
        \\  @if type-of($value1) == number and type-of($value2) == number and comparable($value1, $value2) {
        \\    @return $value1 + $value2;
        \\  }
        \\  @return if($return-calc == true, calc(#{$value1} + #{$value2}), $value1 + unquote(" + ") + $value2);
        \\}
        \\$input-border-width: 1px;
        \\$input-height-border: calc(#{$input-border-width} * 2);
        \\$input-line-height: 1.5;
        \\$input-padding-y: .375rem;
        \\.field {
        \\  a: add($input-padding-y * 2, $input-height-border, false);
        \\  b: add($input-line-height * 1em, add($input-padding-y * 2, $input-height-border, false));
        \\}
    ,
        \\.field {
        \\  a: 0.75rem + 2px;
        \\  b: calc(1.5em + 0.75rem + 2px);
        \\}
        \\
    );
}

test "vm: generic add(false) trims nested calc edge spacing" {
    try expectVmCss(
        \\@function add($value1, $value2, $return-calc: true) {
        \\  @if $value1 == null {
        \\    @return $value2;
        \\  }
        \\  @if $value2 == null {
        \\    @return $value1;
        \\  }
        \\  @if type-of($value1) == number and type-of($value2) == number and comparable($value1, $value2) {
        \\    @return $value1 + $value2;
        \\  }
        \\  @return if($return-calc == true, calc(#{$value1} + #{$value2}), $value1 + unquote(" + ") + $value2);
        \\}
        \\$input-border-width: var(--component-border-width);
        \\$input-height-border: calc(
        \\  #{$input-border-width} * 2
        \\);
        \\.field {
        \\  b: add(1.5em, add(0.5rem, $input-height-border, false));
        \\}
    ,
        \\.field {
        \\  b: calc(1.5em + 0.5rem + calc(var(--component-border-width) * 2));
        \\}
        \\
    );
}

test "vm: dynamic custom property keeps nested calc from string-built value" {
    try expectVmCss(
        \\@function add($value1, $value2, $return-calc: true) {
        \\  @return if($return-calc == true, calc(#{$value1} + #{$value2}), $value1 + unquote(" + ") + $value2);
        \\}
        \\$prefix: cui-;
        \\$border-width: var(--cui-border-width);
        \\$height-border: calc(#{$border-width} * 2);
        \\$height: add(1.5em, add(0.75rem, $height-border, false));
        \\.field {
        \\  --#{$prefix}height: #{$height};
        \\}
        \\
    ,
        \\.field {
        \\  --cui-height: calc(1.5em + 0.75rem + calc(var(--cui-border-width) * 2));
        \\}
        \\
    );
}

test "vm: dynamic custom property preserves source colon spacing" {
    try expectVmCss(
        \\$name: blue-50;
        \\$value: rgb(243.9, 249.75, 254.4);
        \\:root {
        \\  --#{$name}:#{$value};
        \\  --#{$name}-s: #{$value};
        \\  --#{$name}-plain:$value;
        \\  --#{$name}-plain-s: $value;
        \\}
        \\
    ,
        \\:root {
        \\  --blue-50:rgb(243.9, 249.75, 254.4);
        \\  --blue-50-s: rgb(243.9, 249.75, 254.4);
        \\  --blue-50-plain:$value;
        \\  --blue-50-plain-s: $value;
        \\}
        \\
    );
}

test "vm: calc interpolation preserves additive parens from unquoted strings" {
    try expectVmCss(
        \\@function add($value1, $value2, $return-calc: true) {
        \\  @if type-of($value1) == number and type-of($value2) == number and comparable($value1, $value2) {
        \\    @return $value1 + $value2;
        \\  }
        \\  @if type-of($value1) != number { $value1: unquote("(") + $value1 + unquote(")"); }
        \\  @if type-of($value2) != number { $value2: unquote("(") + $value2 + unquote(")"); }
        \\  @return if($return-calc == true, calc(#{$value1} + #{$value2}), $value1 + unquote(" + ") + $value2);
        \\}
        \\$input-border-width: 1px;
        \\$input-height-border: $input-border-width * 2;
        \\.field {
        \\  a: add(0.5rem, $input-height-border, false);
        \\  b: add(1.5em, add(0.5rem, $input-height-border, false));
        \\  c: calc(1.5em + #{unquote("(0.5rem + 2px)")});
        \\}
    ,
        \\.field {
        \\  a: 0.5rem + 2px;
        \\  b: calc(1.5em + (0.5rem + 2px));
        \\  c: calc(1.5em + (0.5rem + 2px));
        \\}
        \\
    );
}

test "vm: multiline interpolated calc compares equal to single-line form" {
    try expectVmCss(
        \\$prefix: ui-;
        \\$pagination-border-width: var(--#{$prefix}border-width);
        \\$pagination-margin-start: calc(
        \\  #{$pagination-border-width} * -1
        \\);
        \\a {
        \\  result: $pagination-margin-start == calc(#{$pagination-border-width} * -1);
        \\}
        \\@if $pagination-margin-start == calc(#{$pagination-border-width} * -1) {
        \\  a { x: yes; }
        \\} @else {
        \\  a { x: no; }
        \\}
    ,
        \\a {
        \\  result: true;
        \\}
        \\
        \\a {
        \\  x: yes;
        \\}
        \\
    );
}

test "vm: interpolated calc keeps single subtract parens but drops multiplicative wrappers" {
    try expectVmCss(
        \\$content-width: 800px;
        \\$spacing-unit: 30px;
        \\.a {
        \\  single: calc(#{$content-width} - (#{$spacing-unit}));
        \\  double: calc(#{$content-width} - (#{$spacing-unit} * 2));
        \\  half: calc(35% - (#{$spacing-unit} / 2));
        \\}
    ,
        \\.a {
        \\  single: calc(800px - (30px));
        \\  double: calc(800px - 30px * 2);
        \\  half: calc(35% - 30px / 2);
        \\}
        \\
    );
}

test "vm: calc preserves var multiplication inside color-mix arguments" {
    try expectVmCss(
        \\@function token-color($color, $opacity: 1) {
        \\  $color: rgb(var(--ui-token-#{$color}));
        \\  $color: color-mix(in srgb, $color calc($opacity * 100%), transparent);
        \\  @return $color;
        \\}
        \\.field {
        \\  color: token-color(on-surface, var(--ui-emphasis-opacity));
        \\}
    ,
        \\.field {
        \\  color: color-mix(in srgb, rgb(var(--ui-token-on-surface)) calc(var(--ui-emphasis-opacity) * 100%), transparent);
        \\}
        \\
    );
}

test "vm: css trig preserves css-var slash argument" {
    try expectVmCss(
        \\.field {
        \\  b: tan(var(--o-angle) / 2);
        \\  c: calc(tan(var(--o-angle) / 2));
        \\  d: calc(var(--r) * tan(45deg));
        \\}
    ,
        \\.field {
        \\  b: tan(var(--o-angle) / 2);
        \\  c: tan(var(--o-angle) / 2);
        \\  d: calc(var(--r) * 1);
        \\}
        \\
    );
}

test "vm: css math preserves var and env hyphenated identifiers" {
    try expectVmCss(
        \\.field {
        \\  padding-bottom: calc(env(safe-area-inset-bottom) + var(--footer-nav-height, 0px));
        \\  margin: clamp(var(--space-4), 10vh, var(--space-11));
        \\  color: hsl(var(--theme-h), var(--theme-s), min(var(--theme-l), var(--theme-text-l)));
        \\}
    ,
        \\.field {
        \\  padding-bottom: calc(env(safe-area-inset-bottom) + var(--footer-nav-height, 0px));
        \\  margin: clamp(var(--space-4), 10vh, var(--space-11));
        \\  color: hsl(var(--theme-h), var(--theme-s), min(var(--theme-l), var(--theme-text-l)));
        \\}
        \\
    );
}

test "vm: css max preserves interpolated var operand in division" {
    try expectVmCss(
        \\$token: icon-size;
        \\$value: var(--md-radio-#{$token}, 20px);
        \\.field {
        \\  margin: max(0px, ((48px - $value) / 2));
        \\}
    ,
        \\.field {
        \\  margin: max(0px, (48px - var(--md-radio-icon-size, 20px)) / 2);
        \\}
        \\
    );
}

test "vm: global max evaluates variable arithmetic argument" {
    try expectVmCss(
        \\$tb: 2.5rem;
        \\$pad: (2rem, 0, 1rem, 0);
        \\a {
        \\  padding: max(0.1rem, $tb - 2rem + nth($pad, 3));
        \\}
    ,
        \\a {
        \\  padding: 1.5rem;
        \\}
        \\
    );
}

test "vm: interpolated calc preserves surface through mixin argument" {
    try expectVmCss(
        \\@mixin emit($v) { .field { width: $v; } }
        \\$size: 32px;
        \\@include emit(calc(#{$size} / 2));
        \\@include emit(calc(1px));
    ,
        \\.field {
        \\  width: calc(32px / 2);
        \\}
        \\
        \\.field {
        \\  width: 1px;
        \\}
        \\
    );
}

test "vm: interpolated calc preserves surface through function return" {
    try expectVmCss(
        \\@function id($v) { @return $v; }
        \\$size: 32px;
        \\.field {
        \\  a: id(calc(#{$size} / 2));
        \\  b: id(calc(1px));
        \\}
    ,
        \\.field {
        \\  a: calc(32px / 2);
        \\  b: 1px;
        \\}
        \\
    );
}

test "vm: calc string from interpolation preserves declaration surface through variable" {
    try expectVmCss(
        \\$width: 1px;
        \\$margin-start: calc(#{$width} * -1);
        \\.page-item:not(:first-child) .page-link {
        \\  margin-left: $margin-start;
        \\}
    ,
        \\.page-item:not(:first-child) .page-link {
        \\  margin-left: calc(1px * -1);
        \\}
        \\
    );
}

test "vm: interpolated calc simplifies adjacent static multiplicative term" {
    try expectVmCss(
        \\$space: 8px;
        \\.field {
        \\  inset: calc(#{$space} + 4px * 2);
        \\}
    ,
        \\.field {
        \\  inset: calc(8px + 8px);
        \\}
        \\
    );
}

test "vm: interpolated calc removes redundant arithmetic outer parens" {
    try expectVmCss(
        \\$space: 8px;
        \\.field {
        \\  margin-top: calc((0px - #{$space} / 2));
        \\  width: calc((#{$space}));
        \\}
    ,
        \\.field {
        \\  margin-top: calc(0px - 8px / 2);
        \\  width: calc((8px));
        \\}
        \\
    );
}

test "vm: unquoted calc string preserves declaration surface through variable" {
    try expectVmCss(
        \\@use "sass:string";
        \\$margin-start: string.unquote("calc(1px * -1)");
        \\.page-item:not(:first-child) .page-link {
        \\  margin-left: $margin-start;
        \\}
    ,
        \\.page-item:not(:first-child) .page-link {
        \\  margin-left: calc(1px * -1);
        \\}
        \\
    );
}

test "vm: calc additive parens before IE hack suffix are removed" {
    try expectVmCss(
        \\$height: 20px;
        \\$border: 1px;
        \\.field {
        \\  line-height: calc((#{$height} - #{$border}*2))\0;
        \\}
    ,
        \\.field {
        \\  line-height: calc(20px - 1px * 2) \0 ;
        \\}
        \\
    );
}

test "vm: nested calc additive passthrough removes unnecessary outer parens" {
    try expectVmCss(
        \\.field {
        \\  max-width: calc(
        \\    calc(2 * calc(var(--width) + var(--spacing)) + calc(3 * var(--gap)))
        \\  );
        \\  offset: calc(1px + calc(var(--x) + 2px));
        \\}
    ,
        \\.field {
        \\  max-width: calc(2 * (var(--width) + var(--spacing)) + 3 * var(--gap));
        \\  offset: calc(1px + var(--x) + 2px);
        \\}
        \\
    );
}

test "vm: nested calc leading multiplicative operand is flattened" {
    try expectVmCss(
        \\.field {
        \\  top: calc(calc(var(--base-size-8) * -1) - var(--Layout-row-gap));
        \\  left: calc(calc(var(--x) * 2) + var(--gap));
        \\}
    ,
        \\.field {
        \\  top: calc(var(--base-size-8) * -1 - var(--Layout-row-gap));
        \\  left: calc(var(--x) * 2 + var(--gap));
        \\}
        \\
    );
}

test "vm: calc variable with CSS var can be subtracted from calc var product" {
    try expectVmCss(
        \\$size: calc(var(--x) * 1.2);
        \\.field {
        \\  transform: translate(calc(-1 * var(--y) - $size * 0.5 + 1px), -50%);
        \\}
    ,
        \\.field {
        \\  transform: translate(calc(-1 * var(--y) - var(--x) * 1.2 * 0.5 + 1px), -50%);
        \\}
        \\
    );
}

test "vm: interpolated numeric calc simplifies in custom property" {
    try expectVmCss(
        \\@for $i from 0 through 1 {
        \\  $percent: calc($i * 5);
        \\  $value: calc(($i * 5 / 100));
        \\  .orbit.shrink-#{$percent} { --o-orbit-ratio: #{$value}; }
        \\}
    ,
        \\.orbit.shrink-0 {
        \\  --o-orbit-ratio: 0;
        \\}
        \\
        \\.orbit.shrink-5 {
        \\  --o-orbit-ratio: 0.05;
        \\}
        \\
    );
}

test "vm: calc variable containing additive calc can be used in multiplicative expression" {
    try expectVmCss(
        \\$tooltip-height: calc(1rem + 2 * 8px);
        \\.field { margin-bottom: calc(-1 * $tooltip-height / 2); }
    ,
        \\.field {
        \\  margin-bottom: calc(-1 * (1rem + 16px) / 2);
        \\}
        \\
    );
}

test "vm: user calc return keeps hidden precision for percentage" {
    try expectVmCss(
        \\@function divide($a, $b) { @return calc($a / $b); }
        \\.field { width: percentage(divide(1, 24)); }
    ,
        \\.field {
        \\  width: 4.1666666667%;
        \\}
        \\
    );
}

test "vm: calc slash argument keeps full precision before later arithmetic" {
    try expectVmCss(
        \\@for $i from 1 through 6 {
        \\  .poster:nth-child(#{$i}) {
        \\    animation-delay: $i * calc(2.5s / 18);
        \\  }
        \\}
    ,
        \\.poster:nth-child(1) {
        \\  animation-delay: 0.1388888889s;
        \\}
        \\
        \\.poster:nth-child(2) {
        \\  animation-delay: 0.2777777778s;
        \\}
        \\
        \\.poster:nth-child(3) {
        \\  animation-delay: 0.4166666667s;
        \\}
        \\
        \\.poster:nth-child(4) {
        \\  animation-delay: 0.5555555556s;
        \\}
        \\
        \\.poster:nth-child(5) {
        \\  animation-delay: 0.6944444444s;
        \\}
        \\
        \\.poster:nth-child(6) {
        \\  animation-delay: 0.8333333333s;
        \\}
        \\
    );
}

test "vm: implicit signed number subtraction preserves hyphen in string concat" {
    try expectVmCss(
        \\.font {
        \\  unicode-range: U + 0000-00ff, U + 0131;
        \\}
    ,
        \\.font {
        \\  unicode-range: U0-0ff, U131;
        \\}
        \\
    );
}

test "vm: unicode-range declaration preserves comma spacing" {
    try expectVmCss(
        \\.font {
        \\  unicode-range: U+F003, U+F006;
        \\}
    ,
        \\.font {
        \\  unicode-range: U+F003, U+F006;
        \\}
        \\
    );
}

test "vm: nested mixin global restore is visible to caller frame" {
    try expectVmCss(
        \\$bp: null;
        \\@mixin breakpoint($value) {
        \\  $old-bp: null;
        \\  @if global-variable-exists(bp) {
        \\    $old-bp: $bp;
        \\  }
        \\  $bp: $value !global;
        \\  @content;
        \\  $bp: $old-bp !global;
        \\}
        \\@mixin each-bp {
        \\  @each $name in small, medium, large {
        \\    $old-bp: null;
        \\    @if global-variable-exists(bp) {
        \\      $old-bp: $bp;
        \\    }
        \\    $bp: $name !global;
        \\    @include breakpoint($name) {
        \\      .#{$name} { value: $bp; }
        \\    }
        \\    $bp: $old-bp !global;
        \\  }
        \\}
        \\@mixin wrapper {
        \\  @include each-bp;
        \\}
        \\@include wrapper;
        \\.after { restored: $bp == null; }
    ,
        \\.small {
        \\  value: small;
        \\}
        \\
        \\.medium {
        \\  value: medium;
        \\}
        \\
        \\.large {
        \\  value: large;
        \\}
        \\
        \\.after {
        \\  restored: true;
        \\}
        \\
    );
}

test "vm: custom property calc interpolation preserves source colon spacing" {
    try expectVmCss(
        \\$x: 1;
        \\.field {
        \\  --a: calc(#{$x} * 1);
        \\  --b:calc(#{$x} * 1);
        \\}
    ,
        \\.field {
        \\  --a: calc(1 * 1);
        \\  --b:calc(1 * 1);
        \\}
        \\
    );
}

test "vm: raw custom property normalizes CRLF and leading spaces" {
    try expectVmCss(
        "a {\r\n\t--x:  var(--y);\r\n\t--m:\r\n\thsl(\r\n\t\t1,\r\n\t\t2,\r\n\t\t3\r\n\t);\r\n}\r\n",
        "a {\n  --x: var(--y);\n  --m:\n  hsl(\n  \t1,\n  \t2,\n  \t3\n  );\n}\n",
    );
}

test "vm: raw custom property tab continuation keeps relative source indent" {
    const css = try renderVmCssForTest(
        std.testing.allocator,
        "body {\r\n" ++
            "\t--content-margin-start: max(\r\n" ++
            "\t\tcalc(50% - var(--line-width)/2),\r\n" ++
            "\t\tcalc(50% - var(--max-width)/2) );\r\n" ++
            "}\r\n",
        "input.scss",
    );
    defer std.testing.allocator.free(css);

    try std.testing.expectEqualStrings(
        "body {\n" ++
            "  --content-margin-start: max(\n" ++
            "  \tcalc(50% - var(--line-width)/2),\n" ++
            "  \tcalc(50% - var(--max-width)/2) );\n" ++
            "}\n",
        css,
    );
}

test "vm: raw custom property multiline strips trailing line-end spaces" {
    const css = try renderVmCssForTest(
        std.testing.allocator,
        ".field {\n" ++
            "  --hl1:\n" ++
            "  hsla(\n" ++
            "    var(--accent-h),\n" ++
            "    50%,\n" ++
            "    calc(var(--base-l) - 20%), \n" ++
            "    30%\n" ++
            "    );\n" ++
            "}\n",
        "input.scss",
    );
    defer std.testing.allocator.free(css);

    try std.testing.expectEqualStrings(
        ".field {\n" ++
            "  --hl1:\n" ++
            "  hsla(\n" ++
            "    var(--accent-h),\n" ++
            "    50%,\n" ++
            "    calc(var(--base-l) - 20%),\n" ++
            "    30%\n" ++
            "    );\n" ++
            "}\n",
        css,
    );
}

test "vm: raw custom property semicolon line is collapsed with trailing space" {
    const css = try renderVmCssForTest(
        std.testing.allocator,
        ".field {\n" ++
            "  --text-highlight-bg: #999\n" ++
            "  ;\n" ++
            "  --background-modifier-hover:\n" ++
            "  hsl(\n" ++
            "    var(--base-h),\n" ++
            "    var(--base-s),\n" ++
            "    calc(var(--base-d) + 10%))\n" ++
            "  ;\n" ++
            "}\n",
        "input.scss",
    );
    defer std.testing.allocator.free(css);

    try std.testing.expectEqualStrings(
        ".field {\n" ++
            "  --text-highlight-bg: #999 ;\n" ++
            "  --background-modifier-hover:\n" ++
            "  hsl(\n" ++
            "    var(--base-h),\n" ++
            "    var(--base-s),\n" ++
            "    calc(var(--base-d) + 10%)) ;\n" ++
            "}\n",
        css,
    );
}

test "vm: custom property below-base indentation preserves relative offsets" {
    const css = try renderVmCssForTest(std.testing.allocator,
        \\.indentation {
        \\  --below-base:
        \\    foo
        \\ bar
        \\   baz;
        \\}
        \\
    , "input.scss");
    defer std.testing.allocator.free(css);

    try std.testing.expectEqualStrings(
        \\.indentation {
        \\  --below-base:
        \\     foo
        \\  bar
        \\    baz;
        \\}
        \\
    , css);
}

test "vm: raw custom property multiline indentation follows emitted rule depth" {
    const css = try renderVmCssForTest(std.testing.allocator,
        \\.outer {
        \\  a {
        \\    --x: calc(
        \\      1
        \\    );
        \\  }
        \\}
        \\@mixin m {
        \\  a {
        \\    --y: hsl(
        \\      1,
        \\      2%,
        \\      3%
        \\    );
        \\  }
        \\}
        \\@include m;
        \\
    , "input.scss");
    defer std.testing.allocator.free(css);

    try std.testing.expectEqualStrings(
        \\.outer a {
        \\  --x: calc(
        \\    1
        \\  );
        \\}
        \\
        \\a {
        \\  --y: hsl(
        \\    1,
        \\    2%,
        \\    3%
        \\  );
        \\}
        \\
    , css);
}

test "vm: raw custom property multiline keeps continuation relative to emitted indent" {
    try expectVmCss(
        \\:root {
        \\    --x: calc(
        \\        -1 * var(--x)
        \\    );
        \\    --y: a,
        \\        b;
        \\}
    ,
        \\:root {
        \\  --x: calc(
        \\      -1 * var(--x)
        \\  );
        \\  --y: a,
        \\      b;
        \\}
        \\
    );
}

test "vm: calc plus negative number serializes as subtraction" {
    try expectVmCss(
        \\.field {
        \\  opacity: calc((var(--show-fade-animation) + (-1)) * -1);
        \\}
        \\
    ,
        \\.field {
        \\  opacity: calc((var(--show-fade-animation) - 1) * -1);
        \\}
        \\
    );
}

test "vm: calc interpolation flattens simple nested product calc" {
    try expectVmCss(
        \\$grid-gutter-width: 1.5rem;
        \\.field {
        \\  height: calc(100% - calc(#{$grid-gutter-width} * 0.5));
        \\}
        \\
    ,
        \\.field {
        \\  height: calc(100% - 1.5rem * 0.5);
        \\}
        \\
    );
}

test "vm: declaration interpolation preserves function comma spacing" {
    try expectVmCss(
        \\@mixin animation($animate...) {
        \\  $max: length($animate);
        \\  $animations: '';
        \\  @for $i from 1 through $max {
        \\    $animations: #{$animations + nth($animate, $i)};
        \\    @if $i < $max { $animations: #{$animations + ", "}; }
        \\  }
        \\  animation: $animations;
        \\}
        \\.field {
        \\  @include animation('fadeUpAnimation 500ms cubic-bezier(0.77,0,0.18,1) 300ms forwards');
        \\}
        \\
    ,
        \\.field {
        \\  animation: fadeUpAnimation 500ms cubic-bezier(0.77,0,0.18,1) 300ms forwards;
        \\}
        \\
    );
}

test "vm: unquoted calc string preserves literal text in declarations" {
    try expectVmCss(
        \\.field {
        \\  font: 400 unquote("calc(14px * 0.83)") / 20px Roboto, sans-serif;
        \\}
        \\
    ,
        \\.field {
        \\  font: 400 calc(14px * 0.83) / 20px Roboto, sans-serif;
        \\}
        \\
    );
}

test "vm: static custom property preserves multiline css if source" {
    try expectVmCss(
        \\.switch::before {
        \\  --_handle-size: if(
        \\    style(--icon: ''): var(--handle-size);
        \\    else: max(var(--handle-size), var(--with-icon-handle-size));
        \\  );
        \\}
        \\
    ,
        \\.switch::before {
        \\  --_handle-size: if(
        \\    style(--icon: ''): var(--handle-size);
        \\    else: max(var(--handle-size), var(--with-icon-handle-size));
        \\  );
        \\}
        \\
    );
}

test "vm: dynamic custom property preserves multiline var and plain calc values" {
    const css = try renderVmCssForTest(std.testing.allocator,
        \\$prefix: bs-;
        \\$x: 1;
        \\.field {
        \\  --#{$prefix}border-radius-2xl: var(
        \\    --#{$prefix}border-radius-xxl
        \\  );
        \\  --#{$prefix}calc: calc(
        \\    #{$x} * 1
        \\  );
        \\}
        \\
    , "input.scss");
    defer std.testing.allocator.free(css);

    try std.testing.expectEqualStrings(
        \\.field {
        \\  --bs-border-radius-2xl: var(
        \\    --bs-border-radius-xxl
        \\  );
        \\  --bs-calc: calc(
        \\    1 * 1
        \\  );
        \\}
        \\
    , css);
}

test "vm: dynamic custom property normalizes multiline calc with CSS vars" {
    const css = try renderVmCssForTest(std.testing.allocator,
        \\$prefix: --ui-;
        \\textarea[aria-invalid] {
        \\  #{$prefix}icon-height: calc(
        \\    (1rem * var(#{$prefix}line-height)) +
        \\      (var(#{$prefix}control-spacing-vertical) * 2) +
        \\      (var(#{$prefix}border-width) * 2)
        \\  );
        \\}
        \\
    , "input.scss");
    defer std.testing.allocator.free(css);

    try std.testing.expectEqualStrings(
        \\textarea[aria-invalid] {
        \\  --ui-icon-height: calc(1rem * var(--ui-line-height) + var(--ui-control-spacing-vertical) * 2 + var(--ui-border-width) * 2);
        \\}
        \\
    , css);
}

test "vm: nested map.get preserves list value kind" {
    try expectVmCss(
        \\@use 'sass:map';
        \\@use 'sass:list';
        \\$deps: ('shape': ('top': (var(--a), var(--a), var(--b), var(--b))));
        \\$value: map.get($deps, 'shape', 'top');
        \\.field {
        \\  first: list.nth($value, 1);
        \\  second: list.nth($value, 2);
        \\  third: list.nth($value, 3);
        \\}
    ,
        \\.field {
        \\  first: var(--a);
        \\  second: var(--a);
        \\  third: var(--b);
        \\}
        \\
    );
}

test "vm: dynamic custom property preserves empty var fallback space" {
    try expectVmCss(
        \\@use 'sass:map';
        \\@function values($deps: ()) {
        \\  @return ('a': var(--a, #{map.get($deps, 'missing')}));
        \\}
        \\.field {
        \\  @each $token, $value in values(()) {
        \\    --_#{$token}: #{$value};
        \\  }
        \\}
    ,
        \\.field {
        \\  --_a: var(--a, );
        \\}
        \\
    );
}

test "vm: later global !default does not reuse top-level local slot" {
    try expectVmCss(
        \\div {
        \\  $foo: lexical;
        \\  inner { foo: $foo; }
        \\}
        \\$foo: outer !default;
        \\outer { foo: $foo; }
    ,
        \\div inner {
        \\  foo: lexical;
        \\}
        \\
        \\outer {
        \\  foo: outer;
        \\}
        \\
    );
}

test "vm: same-unit multiplication survives later cancellation" {
    try expectVmCss(
        \\.result {
        \\  output: (4.2deg * 1deg / 1deg);
        \\  output: (4.2ms * 1ms / 1ms);
        \\}
    ,
        \\.result {
        \\  output: 4.2deg;
        \\  output: 4.2ms;
        \\}
        \\
    );
}

test "vm: generated units remain comparable after compatible conversion" {
    try expectVmCss(
        \\div {
        \\  ho: (23in/2fu) > (23cm/2fu);
        \\}
    ,
        \\div {
        \\  ho: true;
        \\}
        \\
    );
}

test "vm: selector-less @at-root hoists nested rules out of parent selector" {
    const allocator = std.testing.allocator;
    const src =
        \\.foo {
        \\  @at-root {
        \\    .bar {
        \\      a: b;
        \\    }
        \\  }
        \\}
    ;

    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);
    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.bar {
        \\  a: b;
        \\}
        \\
    , buf.items);
}

test "vm: selectorful @at-root resolves ampersand against suspended parent selector" {
    const allocator = std.testing.allocator;
    const src =
        \\.foo {
        \\  @at-root {
        \\    &-bar {
        \\      color: red;
        \\    }
        \\  }
        \\}
    ;

    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);
    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.foo-bar {
        \\  color: red;
        \\}
        \\
    , buf.items);
}

test "vm: @at-root keeps caller selector prefix from load-css style entry" {
    const allocator = std.testing.allocator;
    const src =
        \\@at-root {
        \\  b {
        \\    c: d;
        \\  }
        \\}
    ;

    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    const prefix_id = try r.pool.intern("a");

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);
    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTopWithSelectorPrefix(&.{prefix_id});

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\a b {
        \\  c: d;
        \\}
        \\
    , buf.items);
}

test "vm: combineNestedRuleSelector handles comma child selectors as cartesian product" {
    const allocator = std.testing.allocator;
    const out = try combineNestedRuleSelector(allocator, "div", "span, p, span");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("div span, div p, div span", out);
}

test "vm: combineNestedRuleSelector keeps multiline separator when source selector had newline" {
    const allocator = std.testing.allocator;
    const out = try combineNestedRuleSelector(allocator, "a\n, b", "z &");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("z a,\nz b", out);
}

test "vm: combineNestedRuleSelector ignores child-source newline separators" {
    const allocator = std.testing.allocator;
    const out = try combineNestedRuleSelector(allocator, "a", "&.foo,\n&.bar");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("a.foo, a.bar", out);
}

test "vm: parent suffix child-source newline separators collapse" {
    try expectVmCss(
        \\.a {
        \\  &-1,
        \\  &-2,
        \\  &-3 {
        \\    x: y;
        \\  }
        \\}
    ,
        \\.a-1, .a-2, .a-3 {
        \\  x: y;
        \\}
        \\
    );
}

test "vm: nested selector pseudo argument newlines do not force selector list wrapping" {
    try expectVmCss(
        \\.a {
        \\  &-1,
        \\  &-2 {
        \\    .child:where(
        \\      .a > .child
        \\    ) {
        \\      x: y;
        \\    }
        \\  }
        \\}
    ,
        \\.a-1 .child:where(.a > .child), .a-2 .child:where(.a > .child) {
        \\  x: y;
        \\}
        \\
    );
}

test "vm: combineNestedRuleSelector rejects compound merge after trailing combinator parent" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.SassError, combineNestedRuleSelector(allocator, ".code.ruby >", "&.ruby"));
}

test "vm: adjacent nested @extend siblings are not merged" {
    try expectVmCss(
        \\.text-base { font-family: a; }
        \\.snippet-box {
        \\  .customized-button { @extend .text-base; margin: 1; }
        \\  .customized-button { @extend .text-base; margin: 1; }
        \\}
        \\
    ,
        \\.text-base, .snippet-box .customized-button {
        \\  font-family: a;
        \\}
        \\
        \\.snippet-box .customized-button {
        \\  margin: 1;
        \\}
        \\.snippet-box .customized-button {
        \\  margin: 1;
        \\}
        \\
    );
}

test "vm: media selector extend keeps broader sibling over stateful extender" {
    try expectVmCss(
        \\@mixin m { @media (min-width: 1px) { @content; } }
        \\.a, .b { @include m { &:not(.x) { x: y; } } }
        \\.b:not(:hover) { @extend .a; }
        \\
    ,
        \\@media (min-width: 1px) {
        \\  .a:not(.x), .b:not(.x) {
        \\    x: y;
        \\  }
        \\}
        \\
    );
}

test "vm: duplicate later @extend keeps first branch order" {
    try expectVmCss(
        \\.text-base { font: a; }
        \\.root {
        \\  .nb-stdout, .nb-stderr { @extend .text-base; color: x; }
        \\  .nb-stderr { @extend .text-base; color: y; }
        \\}
        \\
    ,
        \\.text-base, .root .nb-stdout, .root .nb-stderr {
        \\  font: a;
        \\}
        \\
        \\.root .nb-stdout, .root .nb-stderr {
        \\  color: x;
        \\}
        \\.root .nb-stderr {
        \\  color: y;
        \\}
        \\
    );
}

test "vm: chained ancestor extend trims redundant woven descendants" {
    try expectVmCss(
        \\.snippet-panel { color: red; }
        \\
        \\.snippet-panel-immersive {
        \\  @extend .snippet-panel;
        \\  width: 100%;
        \\
        \\  .text-base { font-family: a; }
        \\  .welcome-section { @extend .text-base; padding: 1px; }
        \\}
        \\
        \\.snippet-panel {
        \\  .text-base { font-family: a; }
        \\  .welcome-section { @extend .text-base; padding: 1px; }
        \\}
        \\
    ,
        \\.snippet-panel, .snippet-panel-immersive {
        \\  color: red;
        \\}
        \\
        \\.snippet-panel-immersive {
        \\  width: 100%;
        \\}
        \\.snippet-panel-immersive .text-base, .snippet-panel-immersive .welcome-section {
        \\  font-family: a;
        \\}
        \\.snippet-panel-immersive .welcome-section {
        \\  padding: 1px;
        \\}
        \\
        \\.snippet-panel .text-base, .snippet-panel .welcome-section, .snippet-panel-immersive .text-base, .snippet-panel-immersive .welcome-section {
        \\  font-family: a;
        \\}
        \\.snippet-panel .welcome-section, .snippet-panel-immersive .welcome-section {
        \\  padding: 1px;
        \\}
        \\
    );
}

test "vm: descendant extender that contains target is still emitted" {
    try expectVmCss(
        \\rubberband {
        \\  border: red;
        \\}
        \\flowbox {
        \\  rubberband { @extend rubberband; }
        \\}
    ,
        \\rubberband, flowbox rubberband {
        \\  border: red;
        \\}
        \\
    );
}

test "vm: same-compound extender that contains target is still emitted" {
    try expectVmCss(
        \\.c {
        \\  color: red;
        \\}
        \\.c.d {
        \\  @extend .c;
        \\}
    ,
        \\.c, .c.d {
        \\  color: red;
        \\}
        \\
    );
}

test "vm: prefixed cross extends keep later local branches first" {
    try expectVmCss(
        \\.nav-panel {
        \\  .text-base { font: a; }
        \\  .item { @extend .text-base; }
        \\  .item-title { @extend .text-base; }
        \\  .item-active { @extend .text-base; }
        \\}
        \\.overlay-panel {
        \\  .text-base { font: a; }
        \\  .item-muted { @extend .text-base; }
        \\  .item-selected { @extend .text-base; }
        \\}
        \\
    ,
        \\.nav-panel .text-base, .nav-panel .overlay-panel .item-selected, .overlay-panel .nav-panel .item-selected, .nav-panel .overlay-panel .item-muted, .overlay-panel .nav-panel .item-muted, .nav-panel .item-active, .nav-panel .item-title, .nav-panel .item {
        \\  font: a;
        \\}
        \\.overlay-panel .text-base, .overlay-panel .item-selected, .overlay-panel .item-muted, .overlay-panel .nav-panel .item, .nav-panel .overlay-panel .item, .overlay-panel .nav-panel .item-title, .nav-panel .overlay-panel .item-title, .overlay-panel .nav-panel .item-active, .nav-panel .overlay-panel .item-active {
        \\  font: a;
        \\}
        \\
    );
}

test "vm: @extend preserves multiline selector list formatting" {
    try expectVmCss(
        \\.foo {
        \\  h1 {
        \\    color: red;
        \\  }
        \\}
        \\
        \\.bar {
        \\  &:hover h3,
        \\  h3 {
        \\    @extend h1;
        \\  }
        \\}
    ,
        \\.foo h1,
        \\.foo .bar h3,
        \\.bar .foo h3 {
        \\  color: red;
        \\}
        \\
    );
}

test "vm: @extend accepts multiline target selector list" {
    const allocator = std.testing.allocator;
    var r = try compiler_mod.parseResolveCompile(allocator,
        \\%x { color: red; }
        \\.a {
        \\  @extend %x,
        \\  .b;
        \\}
    );
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
    defer buf = w.toArrayList();
    try std.testing.expectError(error.SassError, rule_ir.writeTo(&w.writer, &r.pool));
}

test "vm: descendant extender with child target keeps both ancestor weave orders" {
    try expectVmCss(
        \\.group {
        \\  > .field:not(:focus) { x: y; }
        \\}
        \\.widget_categories,
        \\.widget_archive {
        \\  select { @extend .field; }
        \\}
    ,
        \\.group > .field:not(:focus), .widget_categories .group > select:not(:focus),
        \\.widget_archive .group > select:not(:focus) {
        \\  x: y;
        \\}
        \\
    );
}

test "vm: descendant extender with sibling target keeps both ancestor weave orders" {
    try expectVmCss(
        \\.group-rounded {
        \\  .group-button + .field {
        \\    x: y;
        \\  }
        \\}
        \\
        \\.search-scope {
        \\  input[type="text"] {
        \\    @extend .field;
        \\  }
        \\}
    ,
        \\.group-rounded .group-button + .field, .group-rounded .search-scope .group-button + input[type=text], .search-scope .group-rounded .group-button + input[type=text] {
        \\  x: y;
        \\}
        \\
    );
}

test "vm: selector-adjacent css-if quoted interpolation drops quotes" {
    try expectVmCss(
        \\$infix: if(sass(true): "-sm"; else: "");
        \\.g-col#{$infix}-1 { x: y; }
        \\:root { --shadow#{if(sass(true): '-sm'; else: '')}: y; }
    ,
        \\.g-col-sm-1 {
        \\  x: y;
        \\}
        \\
        \\:root {
        \\  --shadow-sm: y;
        \\}
        \\
    );
}

test "vm: nested selector with parent-name prefix still combines parent" {
    try expectVmCss(
        \\$css-prefix: "next-";
        \\@mixin nested-prefix() {
        \\  .#{$css-prefix}breadcrumb-text:not(.#{$css-prefix}breadcrumb-text-ellipsis):hover > a { color: red; }
        \\  .#{$css-prefix}search-left-addon + .#{$css-prefix}search-input .#{$css-prefix}input { color: blue; }
        \\}
        \\.#{$css-prefix} {
        \\  &breadcrumb { @include nested-prefix(); }
        \\}
    ,
        \\.next-breadcrumb .next-breadcrumb-text:not(.next-breadcrumb-text-ellipsis):hover > a {
        \\  color: red;
        \\}
        \\.next-breadcrumb .next-search-left-addon + .next-search-input .next-input {
        \\  color: blue;
        \\}
        \\
    );
}

test "vm: parent selector adjacent quoted interpolation drops quotes after ampersand expansion" {
    try expectVmCss(
        \\@function breakpoint-infix($name) { @return if(sass($name == xs): ""; else: "-#{$name}"); }
        \\.navshell-expand {
        \\  $infix: breakpoint-infix(sm);
        \\  &#{$infix} { x: y; }
        \\}
    ,
        \\.navshell-expand-sm {
        \\  x: y;
        \\}
        \\
    );
}

test "vm: css-if sass parent selector is evaluated at mixin include site" {
    try expectVmCss(
        \\@mixin state-selector($state) {
        \\  .validated #{if(sass(&): "&"; else: "")}:#{$state},
        \\  #{if(sass(&): "&"; else: "")}.state-#{$state} {
        \\    @content;
        \\  }
        \\}
        \\@include state-selector(valid) {
        \\  ~ .state-feedback { display: block; }
        \\}
        \\.field {
        \\  @include state-selector(valid) { color: green; }
        \\}
    ,
        \\.validated :valid ~ .state-feedback,
        \\.state-valid ~ .state-feedback {
        \\  display: block;
        \\}
        \\
        \\.validated .field:valid, .field.state-valid {
        \\  color: green;
        \\}
        \\
    );
}

test "vm: quoted breakpoint interpolation matches placeholder extend target" {
    try expectVmCss(
        \\@function breakpoint-infix($name) { @return if(sass($name == xs): ""; else: "-#{$name}"); }
        \\@mixin media-breakpoint-up($name) { @media (min-width: 576px) { @content; } }
        \\@mixin make-max-widths($name) {
        \\  $infix: breakpoint-infix($name);
        \\  %responsive-container#{$infix} { max-width: 540px; }
        \\  .box#{$infix}, .box { @extend %responsive-container#{$infix}; }
        \\}
        \\@include media-breakpoint-up(sm) { @include make-max-widths(sm); }
    ,
        \\@media (min-width: 576px) {
        \\  .box-sm, .box {
        \\    max-width: 540px;
        \\  }
        \\}
        \\
    );
}

test "vm: placeholder declared after sibling extenders keeps source order in media" {
    try expectVmCss(
        \\.a { @extend %p; }
        \\.b { @extend %p; }
        \\@media screen {
        \\  %p { x: y; }
        \\}
    ,
        \\@media screen {
        \\  .a, .b {
        \\    x: y;
        \\  }
        \\}
        \\
    );
}

test "vm: placeholder responsive container selector order keeps base-first responsive order" {
    try expectVmCss(
        \\$breakpoints: (sm: 576px, md: 768px, lg: 992px, xl: 1200px);
        \\$max-widths: (sm: 540px, md: 720px, lg: 960px, xl: 1140px);
        \\@function breakpoint-infix($name, $map) { @return if(sass($name == xs): ""; else: "-#{$name}"); }
        \\%flex-properties { display: flex; }
        \\.box, .fluid { width: 100%; }
        \\@each $breakpoint, $max-width in $max-widths {
        \\  .box-#{$breakpoint} { @extend .fluid; }
        \\}
        \\.navshell {
        \\  .box, .fluid { @extend %flex-properties; }
        \\  @each $breakpoint, $max-width in $max-widths {
        \\    > .box#{breakpoint-infix($breakpoint, $max-widths)} {
        \\      @extend %flex-properties;
        \\    }
        \\  }
        \\}
    ,
        \\.navshell .box, .navshell .fluid, .navshell .box-sm, .navshell .box-md, .navshell .box-lg, .navshell .box-xl {
        \\  display: flex;
        \\}
        \\
        \\.box, .fluid, .box-xl, .box-lg, .box-md, .box-sm {
        \\  width: 100%;
        \\}
        \\
    );
}

test "vm: element extender keeps user selector list order" {
    try expectVmCss(
        \\.h3 { @extend h3; }
        \\.small-box { h3, p { z-index: 5; } }
    ,
        \\.small-box h3, .small-box .h3, .small-box p {
        \\  z-index: 5;
        \\}
        \\
    );
}

test "vm: placeholder extend inserts class before stateful pseudo chain" {
    try expectVmCss(
        \\%tag-state {
        \\  &:not(.disabled):not([disabled]).hover { color: red; }
        \\  &:not(.disabled):not([disabled]):hover { color: blue; }
        \\}
        \\.next-tag { @extend %tag-state; }
        \\.existing%tag-state {
        \\  &:not(.disabled):not([disabled]).hover { color: green; }
        \\}
    ,
        \\.next-tag:not(.disabled):not([disabled]).hover {
        \\  color: red;
        \\}
        \\.next-tag:not(.disabled):not([disabled]):hover {
        \\  color: blue;
        \\}
        \\
        \\.existing.next-tag:not(.disabled):not([disabled]).hover {
        \\  color: green;
        \\}
        \\
    );
}

test "vm: leading nested conditional emits before later declarations" {
    try expectVmCss(
        \\.a {
        \\  &[disabled], &.disabled {
        \\    @if true {
        \\      > .close { color: gray; }
        \\    }
        \\    color: gray;
        \\    background: white;
        \\  }
        \\}
    ,
        \\.a[disabled] > .close, .a.disabled > .close {
        \\  color: gray;
        \\}
        \\.a[disabled], .a.disabled {
        \\  color: gray;
        \\  background: white;
        \\}
        \\
    );
}

test "vm: declarations before nested rules keep later nested rules outside parent" {
    try expectVmCss(
        \\.notification {
        \\  color: red;
        \\  @if true {
        \\    a:not(.button) { color: currentColor; }
        \\    strong { color: currentColor; }
        \\  }
        \\  code { background: white; }
        \\}
    ,
        \\.notification {
        \\  color: red;
        \\}
        \\.notification a:not(.button) {
        \\  color: currentColor;
        \\}
        \\.notification strong {
        \\  color: currentColor;
        \\}
        \\.notification code {
        \\  background: white;
        \\}
        \\
    );
}

test "vm: @extend saturates :not() exclusions without subset branches" {
    try expectVmCss(
        \\.alert a:not(.alert a.btn) { x: y; }
        \\.notice-root { @extend .alert; }
        \\.notice-a { @extend .alert; }
        \\.notice-b { @extend .alert; }
        \\.notice-c { @extend .alert; }
        \\.notice-d { @extend .alert; }
        \\.notice-e { @extend .alert; }
        \\.notice-f { @extend .alert; }
    ,
        \\.alert a:not(.alert a.btn):not(.notice-root a.btn):not(.notice-a a.btn):not(.notice-b a.btn):not(.notice-c a.btn):not(.notice-d a.btn):not(.notice-e a.btn):not(.notice-f a.btn), .notice-f a:not(.alert a.btn):not(.notice-root a.btn):not(.notice-a a.btn):not(.notice-b a.btn):not(.notice-c a.btn):not(.notice-d a.btn):not(.notice-e a.btn):not(.notice-f a.btn), .notice-e a:not(.alert a.btn):not(.notice-root a.btn):not(.notice-a a.btn):not(.notice-b a.btn):not(.notice-c a.btn):not(.notice-d a.btn):not(.notice-e a.btn):not(.notice-f a.btn), .notice-d a:not(.alert a.btn):not(.notice-root a.btn):not(.notice-a a.btn):not(.notice-b a.btn):not(.notice-c a.btn):not(.notice-d a.btn):not(.notice-e a.btn):not(.notice-f a.btn), .notice-c a:not(.alert a.btn):not(.notice-root a.btn):not(.notice-a a.btn):not(.notice-b a.btn):not(.notice-c a.btn):not(.notice-d a.btn):not(.notice-e a.btn):not(.notice-f a.btn), .notice-b a:not(.alert a.btn):not(.notice-root a.btn):not(.notice-a a.btn):not(.notice-b a.btn):not(.notice-c a.btn):not(.notice-d a.btn):not(.notice-e a.btn):not(.notice-f a.btn), .notice-a a:not(.alert a.btn):not(.notice-root a.btn):not(.notice-a a.btn):not(.notice-b a.btn):not(.notice-c a.btn):not(.notice-d a.btn):not(.notice-e a.btn):not(.notice-f a.btn), .notice-root a:not(.alert a.btn):not(.notice-root a.btn):not(.notice-a a.btn):not(.notice-b a.btn):not(.notice-c a.btn):not(.notice-d a.btn):not(.notice-e a.btn):not(.notice-f a.btn) {
        \\  x: y;
        \\}
        \\
    );
}

test "vm: attribute extender with carrier type keeps specificity selector" {
    try expectVmCss(
        \\[mode=dark] .a,
        \\[scheme=dark] .a { x: y; }
        \\body[mode='dark'] [mode='light'],
        \\body[scheme='dark'] [scheme='light'] { @extend [mode='dark']; }
    ,
        \\[mode=dark] .a, body[mode=dark] [mode=light] .a,
        \\body[scheme=dark] [scheme=light] .a,
        \\[scheme=dark] .a {
        \\  x: y;
        \\}
        \\
    );
}

test "vm: dynamic @extend disables stream chunk flush pre-scan" {
    const allocator = std.testing.allocator;
    const src =
        \\$breakpoint: sm;
        \\%responsive-container-sm {
        \\  color: red;
        \\}
        \\.foo {
        \\  @extend %responsive-container-#{$breakpoint};
        \\}
    ;

    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.configureStreamChunkFlush(true, 1);
    try std.testing.expect(!vm.stream_chunk_flush_enabled);
    try std.testing.expectEqual(@as(usize, 0), vm.stream_chunk_extend_targets.items.len);

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.foo {
        \\  color: red;
        \\}
        \\
    , buf.items);
}

test "vm: parent selector expression resolves to selector list value" {
    const allocator = std.testing.allocator;
    const src =
        \\@use "sass:list";
        \\@use "sass:meta";
        \\.foo,
        \\.bar {
        \\  type: meta.type-of(&);
        \\  len: list.length(&);
        \\  item_type: meta.type-of(list.nth(&, 1));
        \\  item_len: list.length(list.nth(&, 1));
        \\  sel: &;
        \\}
        \\
    ;

    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);
    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();
    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.foo,
        \\.bar {
        \\  type: list;
        \\  len: 2;
        \\  item_type: list;
        \\  item_len: 1;
        \\  sel: .foo, .bar;
        \\}
        \\
    , buf.items);
}

test "vm: top-level parent selector value is nil but nested parent selectors stay truthy" {
    const css = try renderVmCssForTest(std.testing.allocator,
        \\@if & {
        \\  skipped-direct {
        \\    nope: nope;
        \\  }
        \\}
        \\$parent: &;
        \\@if $parent {
        \\  skipped-var {
        \\    nope: nope;
        \\  }
        \\}
        \\test {
        \\  test-01: #{if(&, 'true', 'false')};
        \\}
        \\#{if(&, 'has-parent', 'parentless')} {
        \\  test: parent;
        \\}
        \\@mixin with-js() {
        \\  .js:root #{if(&, '&', '')} {
        \\    @content;
        \\  }
        \\}
        \\@include with-js() {
        \\  .bou {
        \\    content: 'bar';
        \\  }
        \\}
        \\.bou {
        \\  @include with-js() {
        \\    .bar {
        \\      content: 'baz';
        \\    }
        \\  }
        \\}
        \\
    , null);
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\test {
        \\  test-01: true;
        \\}
        \\
        \\parentless {
        \\  test: parent;
        \\}
        \\
        \\.js:root .bou {
        \\  content: "bar";
        \\}
        \\
        \\.js:root .bou .bar {
        \\  content: "baz";
        \\}
        \\
    , css);
}

test "vm: parent selector variable in mixin distinguishes top-level and nested callers" {
    const css = try renderVmCssForTest(std.testing.allocator,
        \\@mixin prepend-foo {
        \\  $parent: &;
        \\
        \\  @if $parent {
        \\    .foo & {
        \\      @content;
        \\    }
        \\  } @else {
        \\    .foo {
        \\      @content;
        \\    }
        \\  }
        \\}
        \\
        \\@include prepend-foo {
        \\  bar {
        \\    color: red;
        \\  }
        \\}
        \\
        \\bar {
        \\  @include prepend-foo {
        \\    baz {
        \\      color: red;
        \\    }
        \\  }
        \\}
        \\
    , null);
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\.foo bar {
        \\  color: red;
        \\}
        \\
        \\.foo bar baz {
        \\  color: red;
        \\}
        \\
    , css);
}

test "vm: parent selector equality and string concatenation resolve current selector" {
    const css = try renderVmCssForTest(std.testing.allocator,
        \\el {
        \\  eval: ((& + '') == 'el');
        \\  parse: (& + '' == 'el');
        \\}
        \\
        \\.parent-sel-value {
        \\  .parent-sel-interpolation {
        \\    .parent-sel-value-concat {
        \\      font-family: "Current parent: " + &;
        \\    }
        \\  }
        \\}
        \\
        \\@mixin where($sel: null) {
        \\  @if (& == $sel) {
        \\    h1 {
        \\      color: white;
        \\    }
        \\  } @else {
        \\    h1 {
        \\      color: blue;
        \\    }
        \\  }
        \\}
        \\
        \\.hive { @include where(); }
        \\.bee { @include where(".bee"); }
        \\.amp { @include where(&); }
        \\.quotedamp { @include where("&"); }
        \\
    , null);
    defer std.testing.allocator.free(css);
    try std.testing.expectEqualStrings(
        \\el {
        \\  eval: true;
        \\  parse: true;
        \\}
        \\
        \\.parent-sel-value .parent-sel-interpolation .parent-sel-value-concat {
        \\  font-family: "Current parent: .parent-sel-value .parent-sel-interpolation .parent-sel-value-concat";
        \\}
        \\
        \\.hive h1 {
        \\  color: blue;
        \\}
        \\
        \\.bee h1 {
        \\  color: blue;
        \\}
        \\
        \\.amp h1 {
        \\  color: white;
        \\}
        \\
        \\.quotedamp h1 {
        \\  color: blue;
        \\}
        \\
    , css);
}

test "vm: top-level literal parent selector suffix is rejected" {
    const allocator = std.testing.allocator;
    const src =
        \\&post {
        \\  foo {
        \\    bar: baz;
        \\  }
        \\}
        \\
    ;

    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);
    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try std.testing.expectError(error.SassError, vm.runTop());
}

test "vm: literal parent selector must begin compound" {
    const allocator = std.testing.allocator;
    const src =
        \\test {
        \\  pre& {
        \\    foo {
        \\      bar: baz;
        \\    }
        \\  }
        \\}
        \\
    ;

    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);
    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try std.testing.expectError(error.SassError, vm.runTop());
}

test "vm: top-level selector interpolation drops bare parent selector" {
    const allocator = std.testing.allocator;
    const src =
        \\pre#{&} {
        \\  foo {
        \\    bar: baz;
        \\  }
        \\}
        \\
    ;

    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);
    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();
    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\pre foo {
        \\  bar: baz;
        \\}
        \\
    , buf.items);
}

test "vm: empty top-level selector interpolation errors" {
    const allocator = std.testing.allocator;
    const src =
        \\#{&} {
        \\  foo {
        \\    bar: baz;
        \\  }
        \\}
        \\
    ;

    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);
    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try std.testing.expectError(error.SassError, vm.runTop());
}

test "vm: invalid top-level selector interpolation errors" {
    const allocator = std.testing.allocator;
    const src =
        \\#{hdr(2,5)} {
        \\  color: #08c;
        \\}
        \\
    ;

    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);
    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try std.testing.expectError(error.SassError, vm.runTop());
}

test "vm: nth-child empty args selector errors" {
    const allocator = std.testing.allocator;
    const src =
        \\a:nth-child() {
        \\  color: yellowgreen;
        \\}
        \\
    ;

    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);
    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try std.testing.expectError(error.SassError, vm.runTop());
}

test "vm: trailing combinator parent cannot be merged into compound selector" {
    const allocator = std.testing.allocator;
    const src =
        \\.code.ruby > {
        \\  &.ruby {
        \\    color: green;
        \\  }
        \\}
        \\
    ;

    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);
    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try std.testing.expectError(error.SassError, vm.runTop());
}

test "vm: @at-root with multi-member parent distributes pseudo to all members" {
    const allocator = std.testing.allocator;
    const src =
        \\.a, .b {
        \\  .c {
        \\    @at-root .root, &:hover, &.active {
        \\      color: red;
        \\    }
        \\  }
        \\}
        \\
    ;

    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);
    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\.root, .a .c:hover, .a .c.active, .b .c:hover, .b .c.active {
        \\  color: red;
        \\}
        \\
    , buf.items);
}

test "vm: @extend keeps independent :not selector-list members separate" {
    const allocator = std.testing.allocator;
    const src =
        \\%p { outline: 1px; }
        \\%before { display: block; }
        \\@mixin a {
        \\  @extend %p;
        \\  &::after {
        \\    @extend %before;
        \\    a: b;
        \\  }
        \\}
        \\[role="scrollbar"]:not([aria-controls]),
        \\[role="scrollbar"]:not([aria-valuemin]),
        \\[role="scrollbar"]:not([aria-valuemax]) {
        \\  @include a;
        \\}
        \\
    ;

    var r = try compiler_mod.parseResolveCompile(allocator, src);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = RuleIR.init();
    defer rule_ir.deinit(allocator);
    var vm = try VM.init(allocator, &r.pool, &r.color_pool, &rule_ir, &r.program);
    defer vm.deinit();

    try vm.runTop();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    {
        var w = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = w.toArrayList();
        try rule_ir.writeTo(&w.writer, &r.pool);
    }

    try std.testing.expectEqualStrings(
        \\[role=scrollbar]:not([aria-controls]),
        \\[role=scrollbar]:not([aria-valuemin]),
        \\[role=scrollbar]:not([aria-valuemax]) {
        \\  outline: 1px;
        \\}
        \\
        \\[role=scrollbar]:not([aria-controls])::after,
        \\[role=scrollbar]:not([aria-valuemin])::after,
        \\[role=scrollbar]:not([aria-valuemax])::after {
        \\  display: block;
        \\}
        \\
        \\[role=scrollbar]:not([aria-controls])::after,
        \\[role=scrollbar]:not([aria-valuemin])::after,
        \\[role=scrollbar]:not([aria-valuemax])::after {
        \\  a: b;
        \\}
        \\
    , buf.items);
}

test "vm: @extend keeps nested extender when sibling extender has broader final compound only" {
    try expectVmCss(
        \\%active {
        \\  &.paused { @extend %paused; }
        \\}
        \\.in {
        \\  @extend %active;
        \\  & .nested { @extend %active; }
        \\  &.paused-all {
        \\    @extend %paused;
        \\    & .nested { @extend %paused; }
        \\  }
        \\}
        \\%paused { c: d; }
    ,
        \\.paused.in, .in .paused.nested, .in.paused-all, .in.paused-all .nested {
        \\  c: d;
        \\}
        \\
    );
}

test "vm: @extend trims redundant nested deep pseudo extender" {
    try expectVmCss(
        \\%base { a: b; }
        \\%disabled {
        \\  @extend %base;
        \\  filter: grayscale(50%);
        \\  :deep(.x) { text-decoration: line-through; }
        \\}
        \\.user-management {
        \\  .disabled-tag { @extend %disabled; }
        \\  .user-detail { .disabled-tag { @extend %disabled; } }
        \\}
    ,
        \\.user-management .user-detail .disabled-tag, .user-management .disabled-tag {
        \\  a: b;
        \\}
        \\
        \\.user-management .user-detail .disabled-tag, .user-management .disabled-tag {
        \\  filter: grayscale(50%);
        \\}
        \\.user-management .disabled-tag :deep(.x) {
        \\  text-decoration: line-through;
        \\}
        \\
    );
}

test "vm: generated simple-selector variant stays after original descendant" {
    try expectVmCss(
        \\%selected_items { a: b; }
        \\.view, %view {
        \\  &:selected { @extend %selected_items; }
        \\}
        \\.view, textview { text { @extend %view; } }
        \\iconview { @extend .view; }
    ,
        \\.view:selected, iconview:selected, .view text:selected, iconview text:selected, textview text:selected {
        \\  a: b;
        \\}
        \\
    );
}

test "vm: @extend keeps later nested compound variant before broader ancestor branch" {
    try expectVmCss(
        \\%numeric { font-weight: 400; }
        \\.calendar {
        \\  .calendar-day-base {
        \\    @extend %numeric;
        \\    &.calendar-day-heading { @extend %numeric; }
        \\  }
        \\}
    ,
        \\.calendar .calendar-day-base.calendar-day-heading, .calendar .calendar-day-base {
        \\  font-weight: 400;
        \\}
        \\
    );
}

test "vm: mixin nested pseudo does not merge following same selector declarations" {
    try expectVmCss(
        \\@mixin button($t) {
        \\  @if $t == insensitive { color: red; }
        \\  @else if $t == undecorated {
        \\    background: transparent;
        \\    &:insensitive { @include button(insensitive); }
        \\  }
        \\}
        \\%osd { @include button(undecorated); &:insensitive { background: none; } }
        \\.type { @extend %osd; }
        \\.show { @extend %osd; }
    ,
        \\.show, .type {
        \\  background: transparent;
        \\}
        \\.show:insensitive, .type:insensitive {
        \\  color: red;
        \\}
        \\.show:insensitive, .type:insensitive {
        \\  background: none;
        \\}
        \\
    );
}
test "vm: declaration after same-selector nested child remains split" {
    try expectVmCss(
        \\.x {
        \\  a: b;
        \\  &, &:focus { c: d; }
        \\  e: f;
        \\}
    ,
        \\.x {
        \\  a: b;
        \\}
        \\.x, .x:focus {
        \\  c: d;
        \\}
        \\.x {
        \\  e: f;
        \\}
        \\
    );
}

test "vm: nested extended rule keeps flow declarations in current child block" {
    try expectVmCss(
        \\$ok: true;
        \\%x { margin: 0; }
        \\.a {
        \\  @extend %x;
        \\  c: d;
        \\  b, c {
        \\    @extend %x;
        \\    @if $ok { e: f; }
        \\    g: h;
        \\  }
        \\}
    ,
        \\.a b, .a c, .a {
        \\  margin: 0;
        \\}
        \\
        \\.a {
        \\  c: d;
        \\}
        \\.a b, .a c {
        \\  e: f;
        \\  g: h;
        \\}
        \\
    );
}

test "vm: interpolated nested property namespace is not a selector" {
    try expectVmCss(
        \\@function ns($selector) {
        \\  @return ':root.dark-mode #{$selector}';
        \\}
        \\.text-alt-preto {
        \\  #{ns('&')}: {
        \\    color: black;
        \\  }
        \\}
    ,
        \\.text-alt-preto {
        \\  :root.dark-mode &-color: black;
        \\}
        \\
    );
}

test "vm: @extend keeps later placeholder extender before nested branches" {
    try expectVmCss(
        \\%button { a: b; }
        \\#notification {
        \\  .popup-menu & {
        \\    .notification-button, .notification-icon-button { @extend %button; }
        \\  }
        \\}
        \\.notification { &-button, &-icon-button { @extend %button; } }
        \\.modal-dialog { &-button-box { .modal-dialog-button { @extend %button; } } }
        \\.sound-button { @extend %button; }
    ,
        \\.sound-button, .modal-dialog-button-box .modal-dialog-button, .notification-button, .notification-icon-button, .popup-menu #notification .notification-button, .popup-menu #notification .notification-icon-button {
        \\  a: b;
        \\}
        \\
    );
}
test "vm: @extend orders direct branch selectors before descendant branch selectors" {
    try expectVmCss(
        \\%active {
        \\  &.a, &.b { @extend %p; }
        \\}
        \\.x {
        \\  @extend %active;
        \\  & .n, .xn { @extend %active; }
        \\  &.all { @extend %p; & .n, .xn { @extend %p; } }
        \\}
        \\%p { c: d; }
    ,
        \\.a.x, .b.x, .x .a.n, .x .a.xn, .x .b.n, .x .b.xn, .x.all, .x.all .n, .x.all .xn {
        \\  c: d;
        \\}
        \\
    );
}

test "vm: @extend branch ordering does not reorder pseudo-state validation selectors" {
    try expectVmCss(
        \\.scope .field:valid, .field.state-valid,
        \\.scope .choice:valid,
        \\.choice.state-valid { x: y; }
        \\.base { t: u; }
        \\.context .item { @extend .base; }
    ,
        \\.scope .field:valid, .field.state-valid,
        \\.scope .choice:valid,
        \\.choice.state-valid {
        \\  x: y;
        \\}
        \\
        \\.base, .context .item {
        \\  t: u;
        \\}
        \\
    );
}

test "vm: rgba alpha literal preserves precision through mixin argument" {
    try expectVmCss(
        \\@mixin shadow($c) { x: $c; }
        \\.a { @include shadow(rgba(0, 0, 0, .3)); }
    ,
        \\.a {
        \\  x: rgba(0, 0, 0, 0.3);
        \\}
        \\
    );
}

test "vm: @extend deduplicates shared ancestor before nested child extender" {
    try expectVmCss(
        \\.markdown {
        \\  .book-steps > ol > li { @extend .markdown-inner; }
        \\  .book-card { .markdown-inner { padding: 1rem; } }
        \\}
    ,
        \\.markdown .book-card .markdown-inner, .markdown .book-card .book-steps > ol > li {
        \\  padding: 1rem;
        \\}
        \\
    );
}

test "vm: @extend keeps nested extenders in source order before following original selectors" {
    try expectVmCss(
        \\.a,
        \\.b {
        \\  .x { @extend .target; }
        \\  .y { @extend .target; }
        \\  .z { > q { @extend .target; } }
        \\}
        \\.before,
        \\.target,
        \\.after { p: v; }
    ,
        \\.before,
        \\.target,
        \\.a .x,
        \\.b .x,
        \\.a .y,
        \\.b .y,
        \\.a .z > q,
        \\.b .z > q,
        \\.after {
        \\  p: v;
        \\}
        \\
    );
}
