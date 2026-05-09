//! Stage 1 PoC opcode set.
//!
//! Instruction layout: fixed 8 bytes = [2]u32
//!   word0: { op: u8, pad: u8, argA: u16 } (little endian packing)
//!   word1: argB: u32 (interpretation per-opcode)
//!
//! 8 byte fixed prioritizes decoding cost reduction over density.
//! If it is necessary to make the length variable in the subsequent stage, judge by measurement (equivalent to decision #2).

pub const Opcode = enum(u8) {
    //-- stack / local ------------------------------
    nop = 0,
    halt,
    pop,
    dup,
    load_const, // argB: const_pool index
    load_local, // argB: slot index (per frame)
    load_local_strict, // argB: slot index (per frame); undeclared variable => SassError
    store_local, // argB: slot index
    /// Like `store_local`, but mark the slot for caller/module write-back when the frame returns.
    store_local_writeback, // argB: slot index
    /// Reset slot to nil and undeclared. Compiler emits this for `@for`/`@each` synthetic
    /// iter holders + loop variables after `pop_flow_scope`. Without it the iter list /
    /// counter / loop var values leak into subsequent reads at the same lexical level
    /// (Z21: adminlte top-chunk @each iter holder slot 1503 stale-list bug).
    /// argB: slot index
    clear_local,
    unpack, // argA: expected count (destructuring @each)
    list_len, // pop list, push length (unitless number)
    list_item, // pop index (number), pop list, push item at index
    /// Pop value and coerce slash-free list values to numberish form.
    coerce_slash_free,

    //-- arithmetic / logic (binary) ----------------
    add,
    sub,
    mul,
    div,
    mod,
    neg,
    pos,
    slash_prefix,
    not_op,
    eq,
    neq,
    lt,
    gt,
    le,
    ge,
    and_op,
    or_op,

    //-- control flow --------------------------------
    // JMP* is word1 = i32 relative offset (signed, word index, not instruction number)
    jmp,
    jmp_if_false,
    jmp_if_true,
    push_flow_scope,
    pop_flow_scope,
    // @each / @for is initially expanded with jmp + compare, dedicated opcode is added later

    //-- call ------------------------------------
    call_mixin, // argA: mixin id, argB: argc (includes @content future)
    call_function, // argA: function id, argB: argc
    /// `@content` call inside mixin body -- argB: builtin_call_meta index
    call_content,
    /// `@extend %placeholder` -- argA: module_id, argB: placeholder selector intern id
    call_placeholder,
    /// Record `@extend` edge for Rule IR merge.
    /// argA bit0: optional, bit1: target_is_placeholder; argB: target selector intern id.
    record_extend,
    ret, // mixin/function body endpoint: stack top = return value (function only)
    ret_void,

    //-- emit --------------------------------------
    emit_rule_begin, // argB: selector_id (intern)
    /// Open a CSS block for the current top-of-stack selector without pushing a new selector scope.
    emit_rule_begin_current,
    /// Like `emit_rule_begin_current`, but no-ops when there is no current selector scope.
    emit_rule_begin_current_maybe,
    emit_rule_end, // IR `}` only (selector stack is not popped)
    /// Close a block opened by `emit_rule_begin_current_maybe` if one was opened.
    emit_rule_end_maybe,
    /// Close the currently open rule block only when one is active.
    emit_rule_end_if_open,
    pop_rule_scope, // pop the parent rule's selector from the stack (CSS is already closed)
    emit_decl, // argB: prop_intern; stack top = value
    emit_decl_raw, // argB: prop_intern; stack top = pre-rendered string
    /// Pop prelude (string or nil), emit `@name prelude;` -- argB: at-rule name intern (without `@`)
    emit_at_rule_simple,
    /// Pop prelude (string or nil), emit `@name prelude {` -- argB: at-rule name intern (without `@`)
    emit_at_rule_begin,
    /// Emit `}` for at-rule block.
    emit_at_rule_end,
    /// Emit loud comment (raw text) -- argB: comment text intern
    emit_comment,
    /// Pop value, stringify as interpolated text, emit loud comment.
    emit_comment_dynamic,
    /// Pop value, stringify diagnostic message, and abort with `error.SassError`.
    emit_error,
    /// Pop value, stringify diagnostic message, and print to stderr (compile continues).
    emit_debug,
    /// Pop value, stringify diagnostic message, print warning to stderr (compile continues).
    emit_warn,
    /// Load the top-level stmt boundary marker into Rule IR. writer at rule_begin/at_rule_begin
    /// Signal to insert a blank line immediately before (equivalent to `top_level_stmt_gap` in legacy).
    emit_stmt_gap,

    //-- value construction ------------------------
    make_number_unit, // argB: unit_intern (stack top = f64 bits)
    make_string, // argB: intern; argA flag: quoted
    make_list, // argA: length; argB: Value.packListFlags(separator, bracketed)
    make_bool, // argA: 0/1

    //-- frame / args / emit aliases (Stage 1a Step 5) -
    ret_value, // function @return: stack top = return value (prefers legacy `ret`)
    enter_frame, // argA: local_count
    leave_frame,
    load_arg, // argA: arg index within current callable
    /// Set pending include-content closure for the next `call_mixin`.
    /// argA: module_id, argB: content_chunk_id (u32.max => clear)
    set_content,
    emit_fragment, // argB: prop_intern; stack top = interp_fragment
    emit_raw_decl, // argB: prop_intern; stack top = string (same role as emit_decl_raw)
    call_indirect, // argA: 0=function / 1=mixin, argB: builtin_call_meta index
    /// Built-in Sass function -- argA: builtin_id (u16), argB: `Chunk.builtin_call_meta` index
    call_builtin,
    /// Read another module's global slot -- argA: module_id (u16), argB: global slot index
    load_mod_global,
    /// Like `load_mod_global`, but undeclared variable => SassError.
    load_mod_global_strict,
    /// Execute another module's top chunk at the current source-order position.
    /// argA: module_id (u16)
    run_dependency,

    //-- fused superinstructions (Stage 1b-B1) -------
    /// load_local + load_const + add -- argA: slot, argB: const_pool index
    load_local_add_const,
    /// load_local + load_const + mul -- argA: slot, argB: const_pool index
    load_local_mul_const,
    /// load_local + load_const + ge -- argA: slot, argB: const_pool index
    load_local_ge_const,
    /// load_const + load_local + add -- argA: slot, argB: const_pool index (eval: const + local)
    load_const_add_local,
    /// load_local + emit_decl -- argA: slot, argB: prop_intern
    load_emit_decl,
    /// load_local + jmp_if_false -- argA: slot, argB: relative jump offset (i32 bitcast)
    branch_if_false_local,
    /// emit_rule_end + pop_rule_scope
    emit_rule_end_pop,

    //-- selector / prop name interpolation (Stage 1b-A1) -
    /// argA: parts_count -- pop N values from stack (bottom..top order), stringify + concat, push one string
    make_selector,
    /// Pop string value (selector text), apply `&` + RuleIR rule_begin like emit_rule_begin
    emit_rule_begin_dynamic,
    /// Pop value, pop prop string; append decl (prop + value interned like emit_decl)
    emit_decl_dynamic,
    /// Like `emit_rule_begin`, only update selector_stack and do not write to Rule IR (avoid emptying the outer block due to include expansion)
    push_selector_scope,
    /// Just combine string (make_selector result) on stack with parent and stack it on selector_stack (do not output to IR)
    push_selector_scope_dynamic,
    /// Save the current non-prefix selector scopes, then clear them so `@at-root`
    /// body rules emit at the root while explicit `&` can still resolve.
    push_at_root_scope,
    /// Restore selector scopes saved by `push_at_root_scope`.
    pop_at_root_scope,
    /// Mark direct top-level items emitted until `pop_at_root_bubble` with bubble flags.
    push_at_root_bubble,
    /// Finalize bubble flags for the current `@at-root (...)` body.
    pop_at_root_bubble,
    /// Pop prefix string and push nested-property namespace scope (`foo: { ... }`).
    push_prop_namespace,
    /// Pop nested-property namespace scope.
    pop_prop_namespace,
    /// Push the parent selector (value of `&`) as a SelectorList value, or nil if no parent.
    /// Resolves eagerly at expression-evaluation time so `$x: &;` captures the current parent
    /// (matching dart-sass), rather than deferring until the stored value is used.
    load_parent_selector,

    //-- sentinel (opcode count) --------------------
    _op_count,
};

pub const Instruction = extern struct {
    op: u8,
    _pad: u8 = 0,
    arg_a: u16,
    arg_b: u32,

    pub inline fn make(op: Opcode, arg_a: u16, arg_b: u32) Instruction {
        return .{ .op = @intFromEnum(op), .arg_a = arg_a, .arg_b = arg_b };
    }

    pub inline fn opcode(self: Instruction) Opcode {
        return @enumFromInt(self.op);
    }
};

pub const make_selector_flag_source_name_interp: u32 = 1 << 0;
pub const make_selector_flag_source_args_interp: u32 = 1 << 1;
pub const make_selector_flag_interpolation_context: u32 = 1 << 2;
/// When constructing text for loud comment (`/*! ... #{...} ... */`), empty interp is
/// Suppress the collapse that pops the previous space. Bootstrap bsBanner("")
/// To keep `Bootstrap v5.3.8` (double spaces) (Z23-BOOTSTRAP-P3 pod).
pub const make_selector_flag_preserve_empty_separators: u32 = 1 << 3;
/// Low-byte transport flag for emit_at_rule_begin. Plain CSS nested
/// conditional at-rules preserve CSS nesting semantics, so RuleIR must not
/// apply Sass media-hoist body wrapping to their descendants. VM masks this
/// bit out before storing the at-rule's blank-control nest depth.
pub const at_rule_flag_plain_css_preserve: u16 = 1 << 7;
pub const emit_decl_flag_preserve_slash: u16 = 1 << 0;
pub const emit_decl_flag_has_explicit_top_level_comma: u16 = 1 << 1;
pub const emit_decl_flag_bare_multiline_comma_syntax: u16 = 1 << 2;
/// For emit_decl, when value expression does not contain interp (pure literal/list),
/// Strip source `/* */` on the writer side. SpaceList tail derived from interp in SCSS
/// (e.g. `var(--x) #{"/* rtl: ..."}`) preserves without setting flag.
pub const emit_decl_flag_strip_source_comments: u16 = 1 << 3;
/// For emit_decl, if source is a raw value written in a plain CSS file (`.css` extension)
/// Stand up. The plain CSS literal calc(... calc(...)) is simplified in dart-sass (chatwoot
/// `.css` etc. from node_modules). On the other hand, SCSS evaluation (variable / function return value / interp
// calc assembled via ///) is preserved as plain CSS unparsed (via bootstrap add()
/// via the return value of helper nested calc). Since the difference between the two routes cannot be identified at text-level, the source file
/// Differentiate by extension (CSS spec: plain CSS is dart-sass simplify, SCSS computed is preserve).
pub const emit_decl_flag_plain_css_origin: u16 = 1 << 4;
/// For emit_raw_decl, when value text is pure literal (not from interp)
/// Strip source `/* */`. plain CSS `font-family: a, /* hint */ b;`
// To remove /// etc. like dart-sass. From interp (e.g. `#{"/* rtl: ..."}`)
/// preserves without setting flag (Z23-BOOTSTRAP-P3 pod).
pub const emit_raw_decl_flag_strip_source_comments: u16 = 1 << 0;
/// For emit_raw_decl, custom property source is like `--x: <value>`
/// If you had a horizontal space after the colon, it would be lost via interpolation
/// Restore leading spaces on the VM side.
pub const emit_raw_decl_flag_custom_property_leading_space: u16 = 1 << 1;
/// resolver -> compiler For internal transmission. emit_decl ignores it, emit_raw_decl
/// Copy to `emit_raw_decl_flag_custom_property_leading_space`.
pub const emit_decl_flag_custom_property_leading_space: u16 = 1 << 5;
/// For emit_decl_dynamic. If the source value of dynamic custom property itself is multiple lines,
/// Keep raw special-function text after interpolation without single-line serializing.
pub const emit_decl_flag_value_source_multiline: u16 = 1 << 6;

/// Internal marker prepended to raw multiline custom-property values by the
/// resolver. It carries the declaration line's source column, which remains
/// accurate for @import-inlined modules where VM source spans can point at the
/// caller module.
pub const custom_property_source_col_marker = "\x00zsass-custom-prop-col:";

comptime {
    if (@sizeOf(Instruction) != 8) @compileError("Instruction must be 8 bytes");
}
