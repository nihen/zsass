/// ast_flat.zig -- Flat SoA AST representation (Phase R.2a scaffold)
///
/// This file is self-contained: it imports `std`, `intern_pool.zig`, and
/// `token.zig`.
/// Imported by `src/frontend/parser.zig` and `src/resolve/resolver.zig`.
///
/// Design reference: .plans/20260411-catch-up-design.md Section 2
const std = @import("std");
const intern_pool_mod = @import("../runtime/intern_pool.zig");

// -- Compile-time size/alignment assertions ------------------------------------

comptime {
    std.debug.assert(@sizeOf(AstTag) == 1);
    std.debug.assert(@sizeOf(AstNode) == 16);
}

// -- Public type aliases -------------------------------------------------------

/// Identifier handle -- alias for intern pool keys used in AST nodes.
pub const InternId = intern_pool_mod.InternId;

/// Index into Ast.nodes.  Sentinel `.none` (== maxInt(u32)) means "absent".
/// A real node can never occupy that slot because u32 max is ~4 billion entries.
pub const NodeIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub inline fn toU32(self: NodeIndex) u32 {
        return @intFromEnum(self);
    }
    pub inline fn fromU32(v: u32) NodeIndex {
        return @enumFromInt(v);
    }
};

/// Offset into Ast.extra aux pool (flat []u32 buffer).
pub const ExtraIndex = u32;

/// Shared list-node flags (`expr_comma_list`, `expr_space_list`, `expr_bracketed_list`).
pub const LIST_FLAG_TRAILING_COMMA: u8 = 0b0000_0001;

// -- AstNode -------------------------------------------------------------------

/// One AST node.  Stored via std.MultiArrayList(AstNode) for SoA layout.
///
/// Total size: 16 bytes (tag:1 + flags:1 + _pad:2 + payload:4 + span_start:4 + span_end:4).
/// Alignment: 4 (from the u32 fields).
///
/// Payload interpretation is tag-specific; callers use the helper functions
/// on Ast to read extra-pool slots for compound nodes.
pub const AstNode = struct {
    tag: AstTag, // u8 -- node kind
    flags: u8, // bit field, tag-specific (see tag doc comments)
    _pad: u16 = 0, // reserved, must be zero
    payload: u32, // tag-specific: NodeIndex / ExtraIndex / InternId / immediate
    span_start: u32, // byte offset in source (inclusive)
    span_end: u32, // byte offset in source (exclusive)
};

// -- Operator enums ------------------------------------------------------------

/// Binary operator kinds used by expr_binary_op.
pub const BinOp = enum(u8) {
    log_or,
    log_and,
    eq,
    ne,
    gt,
    lt,
    ge,
    le,
    add,
    sub,
    mul,
    div,
    mod,
};

/// Unary operator kinds used by expr_unary_op.
pub const UnaryOp = enum(u8) {
    not,
    negate,
    positive,
    /// Leading `/` in unary position (libsass-era `(1, / 2)`  ->  `1, /2`).
    slash_prefix,
};

// -- BranchTag ---------------------------------- ----------------------------------

/// All AST node variants.  Single source of truth for what the flat AST can
/// express. The mapping against the legacy hierarchical AST / expression model
/// is in .plans/20260411-catch-up-design.md Section 2.5.
///
/// Rule: fits in u8 (asserted at comptime via @sizeOf(AstTag) == 1).
/// `_count` is a sentinel for variant counting -- keep it last.
pub const AstTag = enum(u8) {
    // -- structural --
    /// payload: ExtraIndex  ->  [child_count: u32, children: NodeIndex...]
    stylesheet_root,

    // -- statements (source tags -- populated by parser before resolver rewrites) --

    /// payload: ExtraIndex  ->  { selector_node: u32, body_extra: ExtraIndex }
    /// body_extra points at a `[child_count, child_idx_0, ...]` block.
    stmt_style_rule,
    /// payload: ExtraIndex  ->  { property_node: u32, value_node: u32 }
    /// flags bit 0: is_custom_property
    /// flags bit 1: is_important (`!important` suffix on the value)
    stmt_declaration,
    /// payload: ExtraIndex  ->  { name_id: InternId, prelude_node_or_max: u32, body_extra_or_max: ExtraIndex }
    /// `prelude_node_or_max` == u32.max if the at-rule has no prelude.
    /// `body_extra_or_max` == u32.max for the statement form (e.g. `@charset "UTF-8";`)
    /// otherwise points at a `[child_count, child_idx_0, ...]` block.
    stmt_at_rule,
    /// payload: unused -- comment text lives at span_start..span_end in source
    stmt_comment,
    /// payload: ExtraIndex  ->  { name_id: InternId, value_node: u32, flags_u32: u32 }
    /// flags_u32 bit 0: !default, bit 1: !global
    stmt_variable_decl,
    /// payload: ExtraIndex  ->  { name_id: InternId, params_extra_or_max: ExtraIndex, body_extra: ExtraIndex }
    /// `params_extra_or_max` == u32.max when the mixin was declared
    /// without a parenthesised parameter list (`@mixin no_params { ... }`).
    stmt_mixin_decl,
    /// payload: ExtraIndex  ->  { name_id: InternId, namespace_id: InternId,
    ///                         args_extra_or_max: ExtraIndex,
    ///                         using_extra_or_max: ExtraIndex,
    ///                         body_extra_or_max: ExtraIndex }
    /// `namespace_id` == .none for unqualified `@include name(...)`.
    /// Each `*_or_max` slot holds u32.max when the corresponding
    /// clause is absent.
    stmt_include_rule,
    /// payload: ExtraIndex  ->  { name_id: InternId, params_extra_or_max: ExtraIndex, body_extra: ExtraIndex }
    /// Same layout as stmt_mixin_decl -- the two share
    /// `parseParamList` + `parseBlockBody`.
    stmt_function_decl,
    /// payload: NodeIndex of value expression
    stmt_return,
    /// payload: ExtraIndex  ->  { cond_node: u32, then_extra: ExtraIndex, elseif_count: u32, elseifs: [NodeIndex, ExtraIndex]..., else_extra: ExtraIndex }
    stmt_if,
    /// payload: ExtraIndex  ->  { var_count: u32, var_ids: InternId..., list_node: u32, body_extra: ExtraIndex }
    stmt_each,
    /// payload: ExtraIndex  ->  { var_id: InternId, from_node: u32, to_node: u32, body_extra: ExtraIndex }
    /// flags bit 0: exclusive (through vs to)
    stmt_for,
    /// payload: ExtraIndex  ->  { cond_node: u32, body_extra: ExtraIndex }
    stmt_while,
    /// payload: ExtraIndex  ->  { selector_node: u32 }
    /// flags bit 0: optional (!optional)
    stmt_extend,
    /// payload: NodeIndex
    stmt_debug,
    /// payload: NodeIndex
    stmt_warn,
    /// payload: NodeIndex
    stmt_error,
    /// payload: ExtraIndex  ->  { args_extra: ExtraIndex }
    stmt_content,
    /// payload: ExtraIndex  ->  { selector_node_or_none: u32, body_extra: ExtraIndex }
    stmt_at_root,
    /// payload: ExtraIndex  ->  { url_id: InternId, namespace_id: InternId, config_extra: ExtraIndex }
    /// flags bit 0: as_star (namespace is *)
    stmt_use,
    /// payload: ExtraIndex  ->  { url_id: InternId, prefix_id: InternId, show_extra: ExtraIndex, hide_extra: ExtraIndex, config_extra: ExtraIndex }
    stmt_forward,
    /// payload: ExtraIndex  ->  { url_node: u32, cond_node_or_max: u32 }
    /// `url_node` is an unquoted text template covering the full import target
    /// token run (`"foo"`, `url(foo.css)`, `other.css`, ...).
    /// `cond_node_or_max` == u32.max when there are no trailing media/supports
    /// conditions; otherwise it points at another unquoted text-template expr.
    /// Additional `@import "a", "b"` entries from a comma list are pushed as
    /// extra `stmt_import` nodes onto `Parser.pending_statements` and drained
    /// by the parse loop so each URL becomes its own `stmt_import` node.
    stmt_import,

    // -- expressions (literals) --

    /// payload: ExtraIndex  ->  { value_f64_lo: u32, value_f64_hi: u32, unit_id: InternId }
    expr_number_literal,
    /// payload: i32 immediate cast to u32 (small unitless integer values)
    expr_number_immediate,
    /// payload: ExtraIndex  ->  { intern_id: InternId }
    /// flags bit 0: quoted
    expr_string_literal,
    /// payload: ExtraIndex  ->  { rgba: u32 }
    /// flags bits 0-1: short(0) / long(1) / upper(2)
    expr_color_hex,
    /// payload: unused
    expr_bool_true,
    /// payload: unused
    expr_bool_false,
    /// payload: unused
    expr_null,
    /// payload: InternId (identifier text)
    expr_unquoted_ident,
    /// payload: InternId (full unicode-range text, e.g. "U+0025-00FF")
    expr_unicode_range,
    /// payload: unused
    expr_important,

    // -- expressions (references) --

    /// payload: InternId (variable name without the leading $)
    /// Phase S rewrites this to resolved_var_ref
    expr_variable,
    /// payload: ExtraIndex  ->  { ns_id: InternId, name_id: InternId }
    expr_namespaced_var,

    // -- expressions (operators) --

    /// payload: ExtraIndex ->  { lhs: NodeIndex, rhs: NodeIndex, op: BinOp(u8), _path: u8, _path2: u16 }
    /// Stored as 3 u32 slots: lhs, rhs, (op:u8 | 0:u24)
    expr_binary_op,
    /// payload: ExtraIndex -> { operand: NodeIndex, op: UnaryOp(u8), _path: u8, _path2: u16 }
    /// Stored as 2 u32 slots: operand, (op:u8 | 0:u24)
    expr_unary_op,
    /// payload: ExtraIndex  ->  { lhs: NodeIndex, rhs: NodeIndex }
    /// Represents the CSS slash-separated pair (e.g. font shorthand, calc division)
    expr_slash_expr,

    // -- expressions (compound) --

    /// payload: ExtraIndex -> { len: u32, children: NodeIndex... }
    /// flags bit 0: source had a trailing comma before the closing bracket/paren
    expr_comma_list,
    /// payload: ExtraIndex -> { len: u32, children: NodeIndex... }
    expr_space_list,
    /// payload: ExtraIndex -> { len: u32, children: NodeIndex... }
    /// flags bit 0: source had a trailing comma before the closing bracket
    expr_bracketed_list,
    /// payload: NodeIndex (the inner expression)
    expr_paren,
    /// payload: ExtraIndex ->  { len: u32, key_nodes: NodeIndex..., value_nodes: NodeIndex... }
    expr_map_literal,

    // -- expressions (calls) --

    /// payload: ExtraIndex  ->  { name_id: InternId, namespace_id: InternId,
    ///                         arg_count: u32,
    ///                         arg_nodes: NodeIndex... (arg_count x u32),
    ///                         arg_name_ids: InternId... (arg_count x u32) }
    /// namespace_id == .none means "no namespace" (plain `foo()`).
    /// arg_name_ids[i] == .none means "positional" (not a keyword arg).
    ///
    /// Note: this diverges slightly from design Section 2.3, which stored args
    /// behind a separate `args_extra: ExtraIndex` indirection.  Inlining
    /// the argument list after the fixed header saves one u32 slot per
    /// call and avoids unnecessary aux pool allocations; there is no
    /// reader that benefits from the indirection.
    expr_func_call,

    // -- expressions (interpolation) --

    /// payload: NodeIndex (the inner expression)
    expr_interp,
    /// payload: ExtraIndex  ->  { len: u32, parts: u32... }
    /// Each part is two u32 slots: { kind: u32 (0=literal InternId, 1=interp NodeIndex), value: u32 }
    expr_string_interp,
    /// payload: ExtraIndex  ->  { len: u32, parts: u32... }
    /// Same part layout as `expr_string_interp`, but represents unquoted raw
    /// CSS text captured structurally (declaration values, at-rule preludes,
    /// plain CSS `@import` components, opaque CSS calls, ...).
    expr_text_template,
    /// payload: NodeIndex (the splatted expression)
    expr_splat,

    // -- resolver-added (Phase S populates these) --

    /// payload: (frame_depth: u16) << 16 | (slot: u16) -- packed inline u32
    resolved_var_ref,
    /// payload: ExtraIndex  ->  { kind_and_id: u32, namespace: InternId, args_extra: ExtraIndex, named_extra: ExtraIndex }
    resolved_func_call,
    /// payload: ValueSlot index into Ast.const_pool
    const_value,

    // -- selector-level (Phase S populates these) --

    sel_compound,
    sel_combinator,
    sel_complex,
    sel_list,

    /// Sentinel for variant counting -- always last.
    _count,
};

// -- Ast container -------------------------------------------------------------

/// Main container for the flat SoA AST of one source file.
///
/// Lifetime: tied to a compile arena.  All allocations go through `self.arena`.
/// `source` is a borrowed slice -- not owned by Ast.
pub const Ast = struct {
    /// SoA storage for all nodes (tag, flags, payload, span_start, span_end columns).
    nodes: std.MultiArrayList(AstNode),
    /// Flat aux pool for variable-length node payloads (u32 slots).
    extra: std.ArrayListUnmanaged(u32),
    /// Const-folded literal values (NaN-boxed u64 Value).  Populated by Phase S.
    const_pool: std.ArrayListUnmanaged(u64),
    /// Index of the stylesheet_root node (.none before first addNode call).
    root: NodeIndex,
    /// Source text -- borrowed, lifetime = compile arena.
    source: []const u8,
    /// InternId of the source file path.
    source_path: InternId,
    /// Allocator (compile arena or std.testing.allocator in tests).
    arena: std.mem.Allocator,
    is_indented_syntax: bool = false,
    /// Create an empty Ast backed by `arena`.  `source` is borrowed.
    pub fn init(arena: std.mem.Allocator, source: []const u8, source_path: InternId) Ast {
        return .{
            .nodes = .empty,
            .extra = .empty,
            .const_pool = .empty,
            .root = .none,
            .source = source,
            .source_path = source_path,
            .arena = arena,
        };
    }

    /// Release all allocations.  Safe to call on a default-init Ast.
    pub fn deinit(self: *Ast) void {
        self.nodes.deinit(self.arena);
        self.extra.deinit(self.arena);
        self.const_pool.deinit(self.arena);
    }

    // -- node pool ------------------------------------------------------------

    /// Append a node; return its sequential index.
    pub fn addNode(self: *Ast, node: AstNode) !NodeIndex {
        const idx: u32 = @intCast(self.nodes.len);
        try self.nodes.append(self.arena, node);
        return @enumFromInt(idx);
    }

    /// Get a copy of the node at `idx`.
    pub fn getNode(self: *const Ast, idx: NodeIndex) AstNode {
        return self.nodes.get(@intFromEnum(idx));
    }

    /// Overwrite the `payload` column of an existing node in place.
    ///
    /// Enables the reserve-slot-then-patch pattern used by recursive-descent
    /// parsers: emit the parent with a dummy payload, recurse to build its
    /// children in `extra`, then patch the parent's payload to the resulting
    /// `ExtraIndex`.
    pub fn setPayload(self: *Ast, idx: NodeIndex, payload: u32) void {
        self.nodes.items(.payload)[@intFromEnum(idx)] = payload;
    }

    /// Overwrite the `tag` column of an existing node in place.
    fn setTag(self: *Ast, idx: NodeIndex, tag: AstTag) void {
        self.nodes.items(.tag)[@intFromEnum(idx)] = tag;
    }

    /// Overwrite the `flags` column of an existing node in place.
    pub fn setFlags(self: *Ast, idx: NodeIndex, flags: u8) void {
        self.nodes.items(.flags)[@intFromEnum(idx)] = flags;
    }

    /// Overwrite the `span_end` column of an existing node in place.
    /// Needed when a block statement's end is only known after all children
    /// have been parsed and emitted.
    pub fn setSpanEnd(self: *Ast, idx: NodeIndex, span_end: u32) void {
        self.nodes.items(.span_end)[@intFromEnum(idx)] = span_end;
    }

    // -- extra pool -----------------------------------------------------------

    /// Append one u32 to extra; return its offset.
    pub fn appendExtraU32(self: *Ast, v: u32) !ExtraIndex {
        const off: ExtraIndex = @intCast(self.extra.items.len);
        try self.extra.append(self.arena, v);
        return off;
    }

    /// Append a slice of u32 to extra; return the offset of the first element.
    ///
    /// Use for len-prefixed child-list patterns:
    ///   const off = try ast.appendExtraU32(child_count);
    ///   _ = try ast.appendExtraSlice(children_u32_slice);
    fn appendExtraSlice(self: *Ast, slice: []const u32) !ExtraIndex {
        const off: ExtraIndex = @intCast(self.extra.items.len);
        try self.extra.appendSlice(self.arena, slice);
        return off;
    }

    /// Read a u32 from the extra pool at `off`.
    pub fn getExtraU32(self: *const Ast, off: ExtraIndex) u32 {
        return self.extra.items[off];
    }

    // -- f64 helpers (little-endian lo/hi split) -------------------------------

    /// Append an f64 as two consecutive u32 slots (lo first).
    /// Returns the offset of the lo slot.
    pub fn appendExtraF64(self: *Ast, f: f64) !ExtraIndex {
        const bits: u64 = @bitCast(f);
        const lo: u32 = @truncate(bits);
        const hi: u32 = @truncate(bits >> 32);
        const off: ExtraIndex = @intCast(self.extra.items.len);
        try self.extra.append(self.arena, lo);
        try self.extra.append(self.arena, hi);
        return off;
    }

    /// Read an f64 from two consecutive u32 slots at `off` (lo/hi little-endian).
    pub fn getExtraF64(self: *const Ast, off: ExtraIndex) f64 {
        const lo = self.extra.items[off];
        const hi = self.extra.items[off + 1];
        const bits: u64 = (@as(u64, hi) << 32) | @as(u64, lo);
        return @bitCast(bits);
    }
};

// -- Statement payload accessors (L1.0) ---------------------------------------

inline fn decodeOptionalNodeIndex(raw: u32) ?NodeIndex {
    return if (raw == std.math.maxInt(u32)) null else NodeIndex.fromU32(raw);
}

inline fn decodeOptionalExtraIndex(raw: u32) ?ExtraIndex {
    return if (raw == std.math.maxInt(u32)) null else raw;
}

fn stylesheetRootChildren(node: AstNode, ast: *const Ast) []const u32 {
    std.debug.assert(node.tag == .stylesheet_root);
    const extra_off = node.payload;
    const child_count = ast.getExtraU32(extra_off);
    return ast.extra.items[extra_off .. extra_off + 1 + child_count];
}

fn bodyChildrenSlice(ast: *const Ast, extra_off: ExtraIndex) []const u32 {
    const child_count = ast.getExtraU32(extra_off);
    return ast.extra.items[extra_off + 1 .. extra_off + 1 + child_count];
}

const StyleRuleDecoded = struct {
    selector_node: NodeIndex,
    body_extra: ExtraIndex,
};

fn styleRuleDecode(node: AstNode, ast: *const Ast) StyleRuleDecoded {
    std.debug.assert(node.tag == .stmt_style_rule);
    const extra_off = node.payload;
    return .{
        .selector_node = NodeIndex.fromU32(ast.getExtraU32(extra_off)),
        .body_extra = ast.getExtraU32(extra_off + 1),
    };
}

const DeclarationDecoded = struct {
    property_node: NodeIndex,
    value_node: NodeIndex,
    is_custom_property: bool,
    is_important: bool,
};

fn declarationDecode(node: AstNode, ast: *const Ast) DeclarationDecoded {
    std.debug.assert(node.tag == .stmt_declaration);
    const extra_off = node.payload;
    return .{
        .property_node = NodeIndex.fromU32(ast.getExtraU32(extra_off)),
        .value_node = NodeIndex.fromU32(ast.getExtraU32(extra_off + 1)),
        .is_custom_property = (node.flags & 0b01) != 0,
        .is_important = (node.flags & 0b10) != 0,
    };
}

const AtRuleDecoded = struct {
    name_id: InternId,
    prelude_node: ?NodeIndex,
    body_extra: ?ExtraIndex,
};

fn atRuleDecode(node: AstNode, ast: *const Ast) AtRuleDecoded {
    std.debug.assert(node.tag == .stmt_at_rule);
    const extra_off = node.payload;
    return .{
        .name_id = @enumFromInt(ast.getExtraU32(extra_off)),
        .prelude_node = decodeOptionalNodeIndex(ast.getExtraU32(extra_off + 1)),
        .body_extra = decodeOptionalExtraIndex(ast.getExtraU32(extra_off + 2)),
    };
}

const VariableDeclDecoded = struct {
    name_id: InternId,
    value_node: NodeIndex,
    is_default: bool,
    is_global: bool,
};

fn variableDeclDecode(node: AstNode, ast: *const Ast) VariableDeclDecoded {
    std.debug.assert(node.tag == .stmt_variable_decl);
    const extra_off = node.payload;
    const flags_u32 = ast.getExtraU32(extra_off + 2);
    return .{
        .name_id = @enumFromInt(ast.getExtraU32(extra_off)),
        .value_node = NodeIndex.fromU32(ast.getExtraU32(extra_off + 1)),
        .is_default = (flags_u32 & 0b01) != 0,
        .is_global = (flags_u32 & 0b10) != 0,
    };
}

const MixinDeclDecoded = struct {
    name_id: InternId,
    params_extra: ?ExtraIndex,
    body_extra: ExtraIndex,
};

fn mixinDeclDecode(node: AstNode, ast: *const Ast) MixinDeclDecoded {
    std.debug.assert(node.tag == .stmt_mixin_decl);
    const extra_off = node.payload;
    return .{
        .name_id = @enumFromInt(ast.getExtraU32(extra_off)),
        .params_extra = decodeOptionalExtraIndex(ast.getExtraU32(extra_off + 1)),
        .body_extra = ast.getExtraU32(extra_off + 2),
    };
}

const FunctionDeclDecoded = struct {
    name_id: InternId,
    params_extra: ?ExtraIndex,
    body_extra: ExtraIndex,
};

fn functionDeclDecode(node: AstNode, ast: *const Ast) FunctionDeclDecoded {
    std.debug.assert(node.tag == .stmt_function_decl);
    const extra_off = node.payload;
    return .{
        .name_id = @enumFromInt(ast.getExtraU32(extra_off)),
        .params_extra = decodeOptionalExtraIndex(ast.getExtraU32(extra_off + 1)),
        .body_extra = ast.getExtraU32(extra_off + 2),
    };
}

const IncludeRuleDecoded = struct {
    name_id: InternId,
    namespace_id: InternId,
    args_extra: ?ExtraIndex,
    using_extra: ?ExtraIndex,
    body_extra: ?ExtraIndex,
};

fn includeRuleDecode(node: AstNode, ast: *const Ast) IncludeRuleDecoded {
    std.debug.assert(node.tag == .stmt_include_rule);
    const extra_off = node.payload;
    return .{
        .name_id = @enumFromInt(ast.getExtraU32(extra_off)),
        .namespace_id = @enumFromInt(ast.getExtraU32(extra_off + 1)),
        .args_extra = decodeOptionalExtraIndex(ast.getExtraU32(extra_off + 2)),
        .using_extra = decodeOptionalExtraIndex(ast.getExtraU32(extra_off + 3)),
        .body_extra = decodeOptionalExtraIndex(ast.getExtraU32(extra_off + 4)),
    };
}

const SingleValueStatementDecoded = struct {
    value_node: NodeIndex,
};

fn returnDecode(node: AstNode, ast: *const Ast) SingleValueStatementDecoded {
    _ = ast;
    std.debug.assert(node.tag == .stmt_return);
    return .{ .value_node = NodeIndex.fromU32(node.payload) };
}

const IfDecoded = struct {
    cond_node: NodeIndex,
    then_extra: ExtraIndex,
    elseif_count: u32,
    else_extra: ?ExtraIndex,
};

fn ifDecode(node: AstNode, ast: *const Ast) IfDecoded {
    std.debug.assert(node.tag == .stmt_if);
    const extra_off = node.payload;
    const elseif_count = ast.getExtraU32(extra_off + 2);
    return .{
        .cond_node = NodeIndex.fromU32(ast.getExtraU32(extra_off)),
        .then_extra = ast.getExtraU32(extra_off + 1),
        .elseif_count = elseif_count,
        .else_extra = decodeOptionalExtraIndex(ast.getExtraU32(extra_off + 3 + elseif_count * 2)),
    };
}

const IfElseIfClauseDecoded = struct {
    cond_node: NodeIndex,
    then_extra: ExtraIndex,
};

fn ifElseIfClause(
    ast: *const Ast,
    extra_off: ExtraIndex,
    clause_index: u32,
    elseif_count: u32,
) IfElseIfClauseDecoded {
    std.debug.assert(clause_index < elseif_count);
    const slot = extra_off + 3 + clause_index * 2;
    return .{
        .cond_node = NodeIndex.fromU32(ast.getExtraU32(slot)),
        .then_extra = ast.getExtraU32(slot + 1),
    };
}

const EachDecoded = struct {
    var_count: u32,
    list_node: NodeIndex,
    body_extra: ExtraIndex,
};

fn eachDecode(node: AstNode, ast: *const Ast) EachDecoded {
    std.debug.assert(node.tag == .stmt_each);
    const extra_off = node.payload;
    const var_count = ast.getExtraU32(extra_off);
    const list_node_slot = extra_off + 1 + var_count;
    return .{
        .var_count = var_count,
        .list_node = NodeIndex.fromU32(ast.getExtraU32(list_node_slot)),
        .body_extra = ast.getExtraU32(list_node_slot + 1),
    };
}

fn eachVarId(ast: *const Ast, extra_off: ExtraIndex, var_index: u32) InternId {
    const var_count = ast.getExtraU32(extra_off);
    std.debug.assert(var_index < var_count);
    return @enumFromInt(ast.getExtraU32(extra_off + 1 + var_index));
}

const ForDecoded = struct {
    var_id: InternId,
    from_node: NodeIndex,
    to_node: NodeIndex,
    body_extra: ExtraIndex,
    exclusive: bool,
};

fn forDecode(node: AstNode, ast: *const Ast) ForDecoded {
    std.debug.assert(node.tag == .stmt_for);
    const extra_off = node.payload;
    return .{
        .var_id = @enumFromInt(ast.getExtraU32(extra_off)),
        .from_node = NodeIndex.fromU32(ast.getExtraU32(extra_off + 1)),
        .to_node = NodeIndex.fromU32(ast.getExtraU32(extra_off + 2)),
        .body_extra = ast.getExtraU32(extra_off + 3),
        .exclusive = (node.flags & 0b01) != 0,
    };
}

const WhileDecoded = struct {
    cond_node: NodeIndex,
    body_extra: ExtraIndex,
};

fn whileDecode(node: AstNode, ast: *const Ast) WhileDecoded {
    std.debug.assert(node.tag == .stmt_while);
    const extra_off = node.payload;
    return .{
        .cond_node = NodeIndex.fromU32(ast.getExtraU32(extra_off)),
        .body_extra = ast.getExtraU32(extra_off + 1),
    };
}

const ExtendDecoded = struct {
    selector_node: NodeIndex,
    is_optional: bool,
};

fn extendDecode(node: AstNode, ast: *const Ast) ExtendDecoded {
    std.debug.assert(node.tag == .stmt_extend);
    const extra_off = node.payload;
    return .{
        .selector_node = NodeIndex.fromU32(ast.getExtraU32(extra_off)),
        .is_optional = (node.flags & 0b01) != 0,
    };
}

fn debugDecode(node: AstNode, ast: *const Ast) SingleValueStatementDecoded {
    _ = ast;
    std.debug.assert(node.tag == .stmt_debug);
    return .{ .value_node = NodeIndex.fromU32(node.payload) };
}

fn warnDecode(node: AstNode, ast: *const Ast) SingleValueStatementDecoded {
    _ = ast;
    std.debug.assert(node.tag == .stmt_warn);
    return .{ .value_node = NodeIndex.fromU32(node.payload) };
}

fn errorDecode(node: AstNode, ast: *const Ast) SingleValueStatementDecoded {
    _ = ast;
    std.debug.assert(node.tag == .stmt_error);
    return .{ .value_node = NodeIndex.fromU32(node.payload) };
}

const ContentDecoded = struct {
    args_extra: ExtraIndex,
};

fn contentDecode(node: AstNode, ast: *const Ast) ContentDecoded {
    _ = ast;
    std.debug.assert(node.tag == .stmt_content);
    return .{ .args_extra = node.payload };
}

const AtRootDecoded = struct {
    selector_node: ?NodeIndex,
    body_extra: ExtraIndex,
};

fn atRootDecode(node: AstNode, ast: *const Ast) AtRootDecoded {
    std.debug.assert(node.tag == .stmt_at_root);
    const extra_off = node.payload;
    return .{
        .selector_node = decodeOptionalNodeIndex(ast.getExtraU32(extra_off)),
        .body_extra = ast.getExtraU32(extra_off + 1),
    };
}

const UseDecoded = struct {
    url_id: InternId,
    namespace_id: InternId,
    config_extra: ExtraIndex,
    as_star: bool,
};

fn useDecode(node: AstNode, ast: *const Ast) UseDecoded {
    std.debug.assert(node.tag == .stmt_use);
    const extra_off = node.payload;
    return .{
        .url_id = @enumFromInt(ast.getExtraU32(extra_off)),
        .namespace_id = @enumFromInt(ast.getExtraU32(extra_off + 1)),
        .config_extra = ast.getExtraU32(extra_off + 2),
        .as_star = (node.flags & 0b01) != 0,
    };
}

const ForwardDecoded = struct {
    url_id: InternId,
    prefix_id: InternId,
    show_extra: ExtraIndex,
    hide_extra: ExtraIndex,
    config_extra: ExtraIndex,
};

fn forwardDecode(node: AstNode, ast: *const Ast) ForwardDecoded {
    std.debug.assert(node.tag == .stmt_forward);
    const extra_off = node.payload;
    return .{
        .url_id = @enumFromInt(ast.getExtraU32(extra_off)),
        .prefix_id = @enumFromInt(ast.getExtraU32(extra_off + 1)),
        .show_extra = ast.getExtraU32(extra_off + 2),
        .hide_extra = ast.getExtraU32(extra_off + 3),
        .config_extra = ast.getExtraU32(extra_off + 4),
    };
}

const ImportDecoded = struct {
    url_node: NodeIndex,
    conditions: ?NodeIndex,
};

fn importDecode(node: AstNode, ast: *const Ast) ImportDecoded {
    std.debug.assert(node.tag == .stmt_import);
    const extra_off = node.payload;
    return .{
        .url_node = @enumFromInt(ast.getExtraU32(extra_off)),
        .conditions = if (ast.getExtraU32(extra_off + 1) == std.math.maxInt(u32))
            null
        else
            @enumFromInt(ast.getExtraU32(extra_off + 1)),
    };
}

// -- Tests ---------------------------------------------------------------------

test "AstNode is 16 bytes" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(AstNode));
}

test "AstTag is u8 (1 byte)" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(AstTag));
}

test "NodeIndex.none sentinel equals maxInt(u32)" {
    try std.testing.expectEqual(std.math.maxInt(u32), @intFromEnum(NodeIndex.none));
}

test "empty Ast init/deinit \u{2014} no leaks" { // Use std.testing.allocator (leak-detecting) wrapped in an ArenaAllocator
    // so the Ast sees a single arena interface.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = Ast.init(arena.allocator(), "", .none);
    defer ast.deinit();
    try std.testing.expectEqual(NodeIndex.none, ast.root);
}

test "addNode returns sequential indices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = Ast.init(arena.allocator(), "", .none);
    defer ast.deinit();

    const node = AstNode{
        .tag = .expr_null,
        .flags = 0,
        .payload = 0,
        .span_start = 0,
        .span_end = 0,
    };
    const idx0 = try ast.addNode(node);
    const idx1 = try ast.addNode(node);
    const idx2 = try ast.addNode(node);

    try std.testing.expectEqual(@as(u32, 0), idx0.toU32());
    try std.testing.expectEqual(@as(u32, 1), idx1.toU32());
    try std.testing.expectEqual(@as(u32, 2), idx2.toU32());
}

test "appendExtraU32 round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = Ast.init(arena.allocator(), "", .none);
    defer ast.deinit();

    const off = try ast.appendExtraU32(42);
    try std.testing.expectEqual(@as(u32, 42), ast.getExtraU32(off));
}

test "appendExtraF64 round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = Ast.init(arena.allocator(), "", .none);
    defer ast.deinit();

    const off = try ast.appendExtraF64(3.14);
    const got = ast.getExtraF64(off);
    try std.testing.expectApproxEqAbs(3.14, got, 1e-10);
}

test "appendExtraF64 round-trip \u{2014} negative and special values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = Ast.init(arena.allocator(), "", .none);
    defer ast.deinit();

    // Zero
    const off0 = try ast.appendExtraF64(0.0);
    try std.testing.expectApproxEqAbs(0.0, ast.getExtraF64(off0), 0.0);
    // Negative
    const off1 = try ast.appendExtraF64(-1.5);
    try std.testing.expectApproxEqAbs(-1.5, ast.getExtraF64(off1), 1e-10);
    // Large
    const off2 = try ast.appendExtraF64(1.0e15);
    try std.testing.expectApproxEqAbs(1.0e15, ast.getExtraF64(off2), 1.0);
}

test "appendExtraSlice round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = Ast.init(arena.allocator(), "", .none);
    defer ast.deinit();

    const data = [_]u32{ 10, 20, 30 };
    const off = try ast.appendExtraSlice(&data);
    try std.testing.expectEqual(@as(u32, 10), ast.getExtraU32(off + 0));
    try std.testing.expectEqual(@as(u32, 20), ast.getExtraU32(off + 1));
    try std.testing.expectEqual(@as(u32, 30), ast.getExtraU32(off + 2));
}

test "construct a minimal stylesheet \u{2014} round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = Ast.init(arena.allocator(), ".a { color: red; }", .none);
    defer ast.deinit();

    // stylesheet_root with 0 children: extra = [0]
    const extra_off = try ast.appendExtraU32(0); // child_count = 0
    const root_idx = try ast.addNode(.{
        .tag = .stylesheet_root,
        .flags = 0,
        .payload = extra_off,
        .span_start = 0,
        .span_end = 18,
    });
    ast.root = root_idx;

    // Verify round-trip
    try std.testing.expectEqual(root_idx, ast.root);
    const n = ast.getNode(root_idx);
    try std.testing.expectEqual(AstTag.stylesheet_root, n.tag);
    try std.testing.expectEqual(extra_off, n.payload);
    try std.testing.expectEqual(@as(u32, 0), n.span_start);
    try std.testing.expectEqual(@as(u32, 18), n.span_end);
    // child count stored in extra
    try std.testing.expectEqual(@as(u32, 0), ast.getExtraU32(extra_off));
}

test "NodeIndex.fromU32 / toU32 round-trip" {
    const idx = NodeIndex.fromU32(99);
    try std.testing.expectEqual(@as(u32, 99), idx.toU32());
    // none sentinel
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), NodeIndex.none.toU32());
}

test "BinOp and UnaryOp enums compile and cover expected variants" {
    // Reference every BinOp variant to verify they compile.
    const all_bin = [_]BinOp{
        .log_or, .log_and, .eq,  .ne,  .gt,  .lt, .ge, .le,
        .add,    .sub,     .mul, .div, .mod,
    };
    try std.testing.expectEqual(@as(usize, 13), all_bin.len);

    const all_un = [_]UnaryOp{ .not, .negate, .positive, .slash_prefix };
    try std.testing.expectEqual(@as(usize, 4), all_un.len);
}

test "AstTag._count fits in u8 \u{2014} fewer than 256 variants" {
    const count = @intFromEnum(AstTag._count);
    try std.testing.expect(count < 256);
}

test "setPayload patches payload in place" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = Ast.init(arena.allocator(), "", .none);
    defer ast.deinit();

    const idx = try ast.addNode(.{
        .tag = .stylesheet_root,
        .flags = 0,
        .payload = 0,
        .span_start = 0,
        .span_end = 0,
    });
    ast.setPayload(idx, 1234);
    try std.testing.expectEqual(@as(u32, 1234), ast.getNode(idx).payload);
    // other columns must be untouched
    try std.testing.expectEqual(AstTag.stylesheet_root, ast.getNode(idx).tag);
    try std.testing.expectEqual(@as(u8, 0), ast.getNode(idx).flags);
}

test "setTag patches tag in place" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = Ast.init(arena.allocator(), "", .none);
    defer ast.deinit();

    const idx = try ast.addNode(.{
        .tag = .stylesheet_root,
        .flags = 0,
        .payload = 42,
        .span_start = 0,
        .span_end = 0,
    });
    ast.setTag(idx, .stmt_comment);
    try std.testing.expectEqual(AstTag.stmt_comment, ast.getNode(idx).tag);
    // payload must be untouched
    try std.testing.expectEqual(@as(u32, 42), ast.getNode(idx).payload);
}

test "setFlags patches flags in place" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = Ast.init(arena.allocator(), "", .none);
    defer ast.deinit();

    const idx = try ast.addNode(.{
        .tag = .stmt_declaration,
        .flags = 0,
        .payload = 0,
        .span_start = 0,
        .span_end = 0,
    });
    ast.setFlags(idx, 0b0000_0001);
    try std.testing.expectEqual(@as(u8, 1), ast.getNode(idx).flags);
}

test "setSpanEnd patches span_end in place" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = Ast.init(arena.allocator(), "", .none);
    defer ast.deinit();

    const idx = try ast.addNode(.{
        .tag = .stmt_style_rule,
        .flags = 0,
        .payload = 0,
        .span_start = 10,
        .span_end = 0,
    });
    ast.setSpanEnd(idx, 42);
    try std.testing.expectEqual(@as(u32, 42), ast.getNode(idx).span_end);
    try std.testing.expectEqual(@as(u32, 10), ast.getNode(idx).span_start);
}

test "reserve-slot-then-patch pattern for stylesheet_root with 2 children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = Ast.init(arena.allocator(), "", .none);
    defer ast.deinit();

    // Step 1: reserve the stylesheet_root slot with placeholder payload.
    const root_idx = try ast.addNode(.{
        .tag = .stylesheet_root,
        .flags = 0,
        .payload = 0,
        .span_start = 0,
        .span_end = 0,
    });
    // Step 2: emit two child nodes.
    const child_a = try ast.addNode(.{
        .tag = .stmt_comment,
        .flags = 0,
        .payload = 0,
        .span_start = 0,
        .span_end = 5,
    });
    const child_b = try ast.addNode(.{
        .tag = .stmt_comment,
        .flags = 0,
        .payload = 0,
        .span_start = 10,
        .span_end = 15,
    });
    // Step 3: write the children list into extra as [count, a, b].
    const extra_off = try ast.appendExtraU32(2);
    _ = try ast.appendExtraU32(child_a.toU32());
    _ = try ast.appendExtraU32(child_b.toU32());
    // Step 4: patch the root's payload to point at extra_off.
    ast.setPayload(root_idx, extra_off);
    ast.setSpanEnd(root_idx, 15);
    ast.root = root_idx;

    // Verify the patched root + children reachable via extra.
    const root = ast.getNode(root_idx);
    try std.testing.expectEqual(AstTag.stylesheet_root, root.tag);
    try std.testing.expectEqual(extra_off, root.payload);
    try std.testing.expectEqual(@as(u32, 15), root.span_end);

    try std.testing.expectEqual(@as(u32, 2), ast.getExtraU32(extra_off));
    const a_from_extra: NodeIndex = @enumFromInt(ast.getExtraU32(extra_off + 1));
    const b_from_extra: NodeIndex = @enumFromInt(ast.getExtraU32(extra_off + 2));
    try std.testing.expectEqual(child_a, a_from_extra);
    try std.testing.expectEqual(child_b, b_from_extra);
}

test "multiple nodes \u{2014} getNode accesses correct rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = Ast.init(arena.allocator(), "", .none);
    defer ast.deinit();

    const a = try ast.addNode(.{ .tag = .expr_bool_true, .flags = 0, .payload = 0, .span_start = 0, .span_end = 1 });
    const b = try ast.addNode(.{ .tag = .expr_bool_false, .flags = 0, .payload = 0, .span_start = 2, .span_end = 6 });
    const c = try ast.addNode(.{ .tag = .expr_null, .flags = 0, .payload = 0, .span_start = 7, .span_end = 11 });

    try std.testing.expectEqual(AstTag.expr_bool_true, ast.getNode(a).tag);
    try std.testing.expectEqual(AstTag.expr_bool_false, ast.getNode(b).tag);
    try std.testing.expectEqual(AstTag.expr_null, ast.getNode(c).tag);

    try std.testing.expectEqual(@as(u32, 0), ast.getNode(a).span_start);
    try std.testing.expectEqual(@as(u32, 2), ast.getNode(b).span_start);
    try std.testing.expectEqual(@as(u32, 7), ast.getNode(c).span_start);
}

fn testNode(tag: AstTag, flags: u8, payload: u32) AstNode {
    return .{ .tag = tag, .flags = flags, .payload = payload, .span_start = 0, .span_end = 0 };
}

test "decode helpers: stylesheet children slices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = Ast.init(arena.allocator(), "", .none);
    defer ast.deinit();

    const c0 = try ast.addNode(testNode(.stmt_comment, 0, 0));
    const c1 = try ast.addNode(testNode(.stmt_comment, 0, 0));
    const off = try ast.appendExtraU32(2);
    _ = try ast.appendExtraU32(c0.toU32());
    _ = try ast.appendExtraU32(c1.toU32());

    try std.testing.expectEqual(@as(usize, 3), stylesheetRootChildren(testNode(.stylesheet_root, 0, off), &ast).len);
    try std.testing.expectEqual(@as(usize, 2), bodyChildrenSlice(&ast, off).len);
}

test "decode helpers: statement payload coverage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ast = Ast.init(arena.allocator(), "", .none);
    defer ast.deinit();

    const n0 = try ast.addNode(testNode(.expr_unquoted_ident, 0, 1));
    const n1 = try ast.addNode(testNode(.expr_number_immediate, 0, 2));
    const n2 = try ast.addNode(testNode(.expr_bool_true, 0, 0));

    const style_off = try ast.appendExtraU32(n0.toU32());
    _ = try ast.appendExtraU32(10);
    try std.testing.expectEqual(n0, styleRuleDecode(testNode(.stmt_style_rule, 0, style_off), &ast).selector_node);

    const decl_off = try ast.appendExtraU32(n0.toU32());
    _ = try ast.appendExtraU32(n1.toU32());
    const decl = declarationDecode(testNode(.stmt_declaration, 0b11, decl_off), &ast);
    try std.testing.expect(decl.is_custom_property and decl.is_important);

    const at_off = try ast.appendExtraU32(100);
    _ = try ast.appendExtraU32(n0.toU32());
    _ = try ast.appendExtraU32(std.math.maxInt(u32));
    try std.testing.expect(atRuleDecode(testNode(.stmt_at_rule, 0, at_off), &ast).body_extra == null);

    const var_off = try ast.appendExtraU32(101);
    _ = try ast.appendExtraU32(n1.toU32());
    _ = try ast.appendExtraU32(0b11);
    try std.testing.expect(variableDeclDecode(testNode(.stmt_variable_decl, 0, var_off), &ast).is_default);

    const mixin_off = try ast.appendExtraU32(102);
    _ = try ast.appendExtraU32(std.math.maxInt(u32));
    _ = try ast.appendExtraU32(20);
    _ = mixinDeclDecode(testNode(.stmt_mixin_decl, 0, mixin_off), &ast);

    const fn_off = try ast.appendExtraU32(103);
    _ = try ast.appendExtraU32(21);
    _ = try ast.appendExtraU32(22);
    _ = functionDeclDecode(testNode(.stmt_function_decl, 0, fn_off), &ast);

    const include_off = try ast.appendExtraU32(104);
    _ = try ast.appendExtraU32(105);
    _ = try ast.appendExtraU32(std.math.maxInt(u32));
    _ = try ast.appendExtraU32(23);
    _ = try ast.appendExtraU32(std.math.maxInt(u32));
    _ = includeRuleDecode(testNode(.stmt_include_rule, 0, include_off), &ast);

    _ = returnDecode(testNode(.stmt_return, 0, n1.toU32()), &ast);

    const if_off = try ast.appendExtraU32(n2.toU32());
    _ = try ast.appendExtraU32(24);
    _ = try ast.appendExtraU32(1);
    _ = try ast.appendExtraU32(n2.toU32());
    _ = try ast.appendExtraU32(25);
    _ = try ast.appendExtraU32(26);
    const if_dec = ifDecode(testNode(.stmt_if, 0, if_off), &ast);
    _ = ifElseIfClause(&ast, if_off, 0, if_dec.elseif_count);

    const each_off = try ast.appendExtraU32(1);
    _ = try ast.appendExtraU32(106);
    _ = try ast.appendExtraU32(n1.toU32());
    _ = try ast.appendExtraU32(27);
    _ = eachDecode(testNode(.stmt_each, 0, each_off), &ast);
    _ = eachVarId(&ast, each_off, 0);

    const for_off = try ast.appendExtraU32(107);
    _ = try ast.appendExtraU32(n1.toU32());
    _ = try ast.appendExtraU32(n2.toU32());
    _ = try ast.appendExtraU32(28);
    try std.testing.expect(forDecode(testNode(.stmt_for, 0b01, for_off), &ast).exclusive);

    const while_off = try ast.appendExtraU32(n2.toU32());
    _ = try ast.appendExtraU32(29);
    _ = whileDecode(testNode(.stmt_while, 0, while_off), &ast);

    const extend_off = try ast.appendExtraU32(n0.toU32());
    _ = extendDecode(testNode(.stmt_extend, 0b01, extend_off), &ast);

    _ = debugDecode(testNode(.stmt_debug, 0, n1.toU32()), &ast);
    _ = warnDecode(testNode(.stmt_warn, 0, n1.toU32()), &ast);
    _ = errorDecode(testNode(.stmt_error, 0, n1.toU32()), &ast);

    try std.testing.expectEqual(@as(ExtraIndex, 30), contentDecode(testNode(.stmt_content, 0, 30), &ast).args_extra);

    const at_root_off = try ast.appendExtraU32(n0.toU32());
    _ = try ast.appendExtraU32(31);
    _ = atRootDecode(testNode(.stmt_at_root, 0, at_root_off), &ast);

    const use_off = try ast.appendExtraU32(108);
    _ = try ast.appendExtraU32(109);
    _ = try ast.appendExtraU32(std.math.maxInt(u32));
    _ = useDecode(testNode(.stmt_use, 0b01, use_off), &ast);

    const fwd_off = try ast.appendExtraU32(110);
    _ = try ast.appendExtraU32(111);
    _ = try ast.appendExtraU32(32);
    _ = try ast.appendExtraU32(std.math.maxInt(u32));
    _ = try ast.appendExtraU32(33);
    _ = forwardDecode(testNode(.stmt_forward, 0, fwd_off), &ast);

    const import_off = try ast.appendExtraU32(40);
    _ = try ast.appendExtraU32(60);
    const imp = importDecode(testNode(.stmt_import, 0, import_off), &ast);
    try std.testing.expectEqual(@as(u32, 40), imp.url_node.toU32());
    try std.testing.expectEqual(@as(u32, 60), imp.conditions.?.toU32());
}
