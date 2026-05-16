const std = @import("std");

const ast_flat = @import("../frontend/ast_flat.zig");
const data = @import("data.zig");
const ast_text = @import("ast_text.zig");

const AstNode = ast_flat.AstNode;
const NodeIndex = ast_flat.NodeIndex;
const ExtraIndex = ast_flat.ExtraIndex;
const InternId = @import("../runtime/intern_pool.zig").InternId;
const ExprIndex = data.ExprIndex;
const SlotId = data.SlotId;
const StmtIndex = data.StmtIndex;
const Span = data.Span;
const ResolveError = data.ResolveError;
const call_arg_splat_sentinel = data.call_arg_splat_sentinel;

const readChildList = ast_text.readChildList;

fn parseContentParamList(
    ctx: anytype,
    params_extra: u32,
    comptime deps: anytype,
    out_names: *std.ArrayListUnmanaged(InternId),
    out_slots: *std.ArrayListUnmanaged(SlotId),
    out_defaults: *std.ArrayListUnmanaged(?ExprIndex),
    out_has_rest: *bool,
) ResolveError!void {
    out_has_rest.* = false;
    if (params_extra == std.math.maxInt(u32)) return;
    const count = ctx.ast.getExtraU32(params_extra);
    const has_splat = ctx.ast.getExtraU32(params_extra + 1);
    out_has_rest.* = has_splat != 0;
    var q: ExtraIndex = params_extra + 2;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const name_id: InternId = @enumFromInt(ctx.ast.getExtraU32(q));
        q += 1;
        const def_or_max = ctx.ast.getExtraU32(q);
        q += 1;
        try out_names.append(ctx.a, name_id);
        const slot = try ctx.declareLocal(name_id);
        try out_slots.append(ctx.a, slot);
        const is_rest_param = has_splat != 0 and i + 1 == count;
        if (is_rest_param or def_or_max == std.math.maxInt(u32)) {
            try out_defaults.append(ctx.a, null);
        } else {
            try out_defaults.append(ctx.a, try deps.resolveExpr(ctx.ast, ctx, @enumFromInt(def_or_max)));
        }
    }
}

pub fn resolveContentBlock(ctx: anytype, using_extra: u32, body_extra: u32, comptime deps: anytype) ResolveError!u32 {
    if (body_extra == std.math.maxInt(u32)) return std.math.maxInt(u32);

    var param_names: std.ArrayListUnmanaged(InternId) = .empty;
    defer param_names.deinit(ctx.a);
    var param_slots: std.ArrayListUnmanaged(SlotId) = .empty;
    defer param_slots.deinit(ctx.a);
    var defaults: std.ArrayListUnmanaged(?ExprIndex) = .empty;
    defer defaults.deinit(ctx.a);
    var has_rest = false;
    const global_slot_base = ctx.prog.next_global_slot;

    try ctx.pushScope(ctx.a);
    errdefer ctx.popScope(ctx.a);
    // Caller scope captures are allowed; keep the running local allocator, but
    // never let content-block locals alias the reserved global slot prefix.
    //
    // A content block inside a top-level conditional can otherwise allocate
    // locals inside the reserved global range. Nested conditional flow-scope
    // restoration would then roll back updates that must remain local.
    if (!ctx.in_callable and ctx.next_local_slot < ctx.prog.next_global_slot) {
        ctx.next_local_slot = ctx.prog.next_global_slot;
    }
    try parseContentParamList(ctx, using_extra, deps, &param_names, &param_slots, &defaults, &has_rest);

    const raw = readChildList(ctx.ast, body_extra);
    var roots_buf: std.ArrayListUnmanaged(StmtIndex) = .empty;
    defer roots_buf.deinit(ctx.a);
    try roots_buf.ensureTotalCapacity(ctx.a, raw.len);
    for (raw) |u| {
        const child_idx = try deps.resolveStmt(ctx, @enumFromInt(u));
        if (ctx.pending_extra_top.items.len > 0) {
            for (ctx.pending_extra_top.items) |ex| {
                try roots_buf.append(ctx.a, ex);
            }
            ctx.pending_extra_top.clearRetainingCapacity();
        }
        try roots_buf.append(ctx.a, child_idx);
    }
    const roots = try ctx.prog.arena.allocator().dupe(StmtIndex, roots_buf.items);
    const local_count = ctx.next_local_slot;
    ctx.popScope(ctx.a);

    const pn = try ctx.prog.arena.allocator().dupe(InternId, param_names.items);
    const ps = try ctx.prog.arena.allocator().dupe(SlotId, param_slots.items);
    const ds = try ctx.prog.arena.allocator().dupe(?ExprIndex, defaults.items);

    const cid: u32 = @intCast(ctx.prog.content_blocks.items.len);
    try ctx.prog.content_blocks.append(ctx.a, .{
        .id = cid,
        .param_names = pn,
        .param_slots = ps,
        .defaults = ds,
        .has_rest = has_rest,
        .global_slot_base = global_slot_base,
        .local_count = local_count,
        .body_roots = roots,
    });
    return cid;
}

pub fn resolveContentStmt(ctx: anytype, n: AstNode, span: Span, comptime deps: anytype) ResolveError!StmtIndex {
    const off: ExtraIndex = n.payload;
    const arg_count = ctx.ast.getExtraU32(off);

    ctx.mixin_accepts_content = true;

    var args: std.ArrayListUnmanaged(ExprIndex) = .empty;
    defer args.deinit(ctx.a);
    var arg_names: std.ArrayListUnmanaged(InternId) = .empty;
    defer arg_names.deinit(ctx.a);

    const arg_nodes_start: ExtraIndex = off + 1;
    const arg_names_start: ExtraIndex = arg_nodes_start + arg_count;
    var i: u32 = 0;
    while (i < arg_count) : (i += 1) {
        const an: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(arg_nodes_start + i));
        const raw_name: InternId = @enumFromInt(ctx.ast.getExtraU32(arg_names_start + i));
        const arg_node = ctx.ast.getNode(an);
        if (arg_node.tag == .expr_splat) {
            const inner: NodeIndex = @enumFromInt(arg_node.payload);
            try args.append(ctx.a, try deps.resolveExpr(ctx.ast, ctx, inner));
            try arg_names.append(ctx.a, call_arg_splat_sentinel);
            continue;
        }
        try args.append(ctx.a, try deps.resolveExpr(ctx.ast, ctx, an));
        try arg_names.append(ctx.a, raw_name);
    }
    const arg_start = try deps.appendCallArgsWithNames(ctx.prog, ctx.a, args.items, arg_names.items);

    const idx: StmtIndex = @intCast(ctx.prog.stmts.items.len);
    const cidx: u32 = @intCast(ctx.prog.content_stmts.items.len);
    try ctx.prog.content_stmts.append(ctx.a, .{
        .arg_start = arg_start,
        .arg_count = arg_count,
    });
    try ctx.prog.stmts.append(ctx.a, .{
        .kind = .content_call,
        .payload = cidx,
        .span = span,
        .origin_id = ctx.currentOrigin(),
    });
    return idx;
}

pub fn stmtListContainsContentCall(ast: *const ast_flat.Ast, body_extra: u32) bool {
    if (body_extra == std.math.maxInt(u32)) return false;
    const raw = readChildList(ast, body_extra);
    for (raw) |u| {
        if (stmtContainsContentCall(ast, @enumFromInt(u))) return true;
    }
    return false;
}

fn stmtContainsContentCall(ast: *const ast_flat.Ast, node: NodeIndex) bool {
    const n = ast.getNode(node);
    switch (n.tag) {
        .stmt_content => return true,
        .stmt_if => {
            const off: ExtraIndex = n.payload;
            if (stmtListContainsContentCall(ast, ast.getExtraU32(off + 1))) return true;
            const elseif_count = ast.getExtraU32(off + 2);
            var q: ExtraIndex = off + 3;
            var ei: u32 = 0;
            while (ei < elseif_count) : (ei += 1) {
                q += 1; // skip cond expr
                if (stmtListContainsContentCall(ast, ast.getExtraU32(q))) return true;
                q += 1;
            }
            return stmtListContainsContentCall(ast, ast.getExtraU32(q));
        },
        else => return false,
    }
}
