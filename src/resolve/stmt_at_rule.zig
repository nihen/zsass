const std = @import("std");

const ast_flat = @import("../frontend/ast_flat.zig");
const data = @import("data.zig");
const ast_text = @import("ast_text.zig");
const path_resolution = @import("path_resolution.zig");
const selector_helpers = @import("../selector/selector_helpers.zig");

const AstNode = ast_flat.AstNode;
const NodeIndex = ast_flat.NodeIndex;
const ExtraIndex = ast_flat.ExtraIndex;
const InternId = @import("../runtime/intern_pool.zig").InternId;
const ExprIndex = data.ExprIndex;
const StmtIndex = data.StmtIndex;
const Span = data.Span;
const AtRootBehavior = data.AtRootBehavior;
const ResolveError = data.ResolveError;

const media_prelude_has_interp_flag = data.media_prelude_has_interp_flag;
const media_prelude_interp_at_start_flag = data.media_prelude_interp_at_start_flag;
const atRuleNameHasInterpolation = ast_text.atRuleNameHasInterpolation;
const extractRawAtRuleNameText = ast_text.extractRawAtRuleNameText;
const sourceLineStartAtByte = ast_text.sourceLineStartAtByte;
const astTextNodeRawAlloc = ast_text.astTextNodeRawAlloc;
const preludeLooksLikeCustomCssFunction = ast_text.preludeLooksLikeCustomCssFunction;
const readChildList = ast_text.readChildList;
const isPlainCssStylesheetPath = path_resolution.isPlainCssStylesheetPath;
const selectorHasAtSign = selector_helpers.selectorHasAtSign;

fn cssIdentEquals(name: []const u8, expected_lower: []const u8) bool {
    if (name.len != expected_lower.len) return false;
    for (name, expected_lower) |raw, want| {
        var c = raw;
        if (c == '_') c = '-';
        if (std.ascii.toLower(c) != want) return false;
    }
    return true;
}

fn atRuleNameRaw(name: []const u8) []const u8 {
    return if (name.len > 0 and name[0] == '@') name[1..] else name;
}

fn isKeyframesAtRuleRawName(raw_name: []const u8) bool {
    return cssIdentEquals(raw_name, "keyframes") or
        cssIdentEquals(raw_name, "-webkit-keyframes") or
        cssIdentEquals(raw_name, "-moz-keyframes") or
        cssIdentEquals(raw_name, "-o-keyframes") or
        cssIdentEquals(raw_name, "-ms-keyframes");
}

pub fn resolveAtRuleStmt(ctx: anytype, n: AstNode, span: Span, comptime deps: anytype) ResolveError!StmtIndex {
    const off: ExtraIndex = n.payload;
    const name_id: InternId = @enumFromInt(ctx.ast.getExtraU32(off));
    const prelude_slot = ctx.ast.getExtraU32(off + 1);
    const body_extra = ctx.ast.getExtraU32(off + 2);
    var effective_name_id = name_id;
    var at_rule_name = ctx.pool.get(name_id);
    const raw_at_rule_name = extractRawAtRuleNameText(ctx.ast.source, span) orelse at_rule_name;
    const interpolated_at_rule_name = if (std.mem.indexOf(u8, at_rule_name, "#{") != null)
        at_rule_name
    else
        raw_at_rule_name;
    const has_interpolated_name = std.mem.indexOf(u8, raw_at_rule_name, "#{") != null or
        std.mem.indexOf(u8, at_rule_name, "#{") != null or
        atRuleNameHasInterpolation(ctx.ast.source, span);
    var dynamic_at_rule_name_expr: ?ExprIndex = null;
    const in_plain_css_module = isPlainCssStylesheetPath(ctx.module_path);
    if (in_plain_css_module and has_interpolated_name) return error.SassError;
    if (has_interpolated_name and std.mem.indexOf(u8, interpolated_at_rule_name, "#{") != null) {
        deps.validateAtRuleNameInterpolation(interpolated_at_rule_name) catch return error.SassError;
        if (deps.resolveInterpolatedTextExpr(ctx, interpolated_at_rule_name, span, false) catch null) |name_expr| {
            if (deps.collapseStaticTextExprToIntern(ctx, name_expr)) |collapsed| {
                effective_name_id = collapsed;
                at_rule_name = ctx.pool.get(collapsed);
            } else {
                dynamic_at_rule_name_expr = name_expr;
            }
        }
    }
    const raw_name = atRuleNameRaw(at_rule_name);
    const is_keyframes_at_rule = isKeyframesAtRuleRawName(raw_name);
    const is_media_at_rule = cssIdentEquals(raw_name, "media") and !has_interpolated_name;
    const is_supports_at_rule = cssIdentEquals(raw_name, "supports") and !has_interpolated_name;
    if (ctx.callable_decl_context == .function) return error.SassError;
    if (ctx.property_namespace_depth > 0) return error.SassError;
    const allow_unknown_var_in_prelude = is_supports_at_rule or has_interpolated_name;
    var allow_unknown_var_in_body = false;
    var media_flags: u8 = 0;
    const body_child_nodes = if (body_extra != std.math.maxInt(u32))
        readChildList(ctx.ast, body_extra)
    else
        &.{};

    var prelude_expr: ?ExprIndex = null;
    if (prelude_slot != std.math.maxInt(u32)) {
        const saved = ctx.allow_unknown_var_literal;
        ctx.allow_unknown_var_literal = saved or allow_unknown_var_in_prelude;
        defer ctx.allow_unknown_var_literal = saved;

        const prelude_node: NodeIndex = @enumFromInt(prelude_slot);
        const pn = ctx.ast.getNode(prelude_node);
        const prelude_raw_storage = try astTextNodeRawAlloc(ctx.a, ctx.ast, ctx.pool, prelude_node);
        defer ctx.a.free(prelude_raw_storage);
        const raw_prelude = prelude_raw_storage;
        const prelude_is_text = pn.tag == .expr_unquoted_ident or
            pn.tag == .expr_string_literal or
            pn.tag == .expr_string_interp or
            pn.tag == .expr_text_template;
        if (is_supports_at_rule and std.mem.endsWith(u8, ctx.module_path, ".sass")) {
            if (sourceLineStartAtByte(ctx.ast.source, pn.span_start) > sourceLineStartAtByte(ctx.ast.source, span.start)) {
                return error.SassError;
            }
        }
        if (in_plain_css_module and std.mem.indexOf(u8, raw_prelude, "#{") != null) {
            return error.SassError;
        }

        if ((is_media_at_rule or is_supports_at_rule) and std.mem.indexOf(u8, raw_prelude, "#{") != null) {
            media_flags |= media_prelude_has_interp_flag;
            const trimmed_left = std.mem.trimStart(u8, raw_prelude, " \t\r\n");
            if (is_media_at_rule and std.mem.startsWith(u8, trimmed_left, "#{")) {
                media_flags |= media_prelude_interp_at_start_flag;
            }
        }
        if (is_media_at_rule and std.mem.indexOfScalar(u8, raw_prelude, '$') != null) {
            media_flags |= media_prelude_has_interp_flag;
        }

        if (prelude_is_text) {
            if (cssIdentEquals(raw_name, "function") and preludeLooksLikeCustomCssFunction(raw_prelude)) {
                allow_unknown_var_in_body = true;
            }
        }

        if (is_media_at_rule and deps.mediaPreludeNeedsEvaluation(raw_prelude)) {
            prelude_expr = try deps.resolveMediaPreludeExpr(ctx, raw_prelude, span);
        } else if (is_supports_at_rule) {
            prelude_expr = try deps.resolveSupportsPreludeExpr(ctx, raw_prelude, span);
        } else if (is_keyframes_at_rule and prelude_is_text) {
            if (std.mem.indexOf(u8, raw_prelude, "#{") != null) {
                prelude_expr = try deps.resolveInterpolatedTextExpr(ctx, raw_prelude, span, !allow_unknown_var_in_prelude);
            } else {
                const raw_id = try ctx.pool.intern(raw_prelude);
                prelude_expr = try deps.appendExpr(ctx.prog, ctx.a, .{
                    .kind = .literal_string,
                    .payload = deps.packLiteralStringPayload(raw_id, false, false),
                    .span = span,
                });
            }
        } else if (prelude_is_text) {
            if (!is_media_at_rule and !is_supports_at_rule and !is_keyframes_at_rule) {
                if (std.mem.indexOf(u8, raw_prelude, "#{") != null) {
                    prelude_expr = try deps.resolveInterpolatedTextExpr(ctx, raw_prelude, span, !allow_unknown_var_in_prelude);
                } else {
                    const raw_id = try ctx.pool.intern(raw_prelude);
                    prelude_expr = try deps.appendExpr(ctx.prog, ctx.a, .{
                        .kind = .literal_string,
                        .payload = deps.packLiteralStringPayload(raw_id, false, false),
                        .span = span,
                    });
                }
            } else if (std.mem.indexOfScalar(u8, raw_prelude, '$') != null) {
                prelude_expr = try deps.resolveInterpolatedTextExpr(ctx, raw_prelude, span, !allow_unknown_var_in_prelude);
            } else {
                prelude_expr = try deps.resolveExpr(ctx.ast, ctx, prelude_node);
            }
        } else {
            prelude_expr = try deps.resolveExpr(ctx.ast, ctx, prelude_node);
        }
    }
    if (dynamic_at_rule_name_expr) |name_expr| {
        if (prelude_slot == std.math.maxInt(u32)) {
            effective_name_id = try ctx.pool.intern("");
            at_rule_name = "";
            prelude_expr = name_expr;
        }
    }

    var body_roots: []StmtIndex = &.{};
    if (body_extra != std.math.maxInt(u32)) {
        const raw = body_child_nodes;
        if (raw.len > 0) {
            const saved = ctx.allow_unknown_var_literal;
            ctx.allow_unknown_var_literal = saved or allow_unknown_var_in_body;
            defer ctx.allow_unknown_var_literal = saved;
            const saved_plain_css_validate_values = ctx.plain_css_validate_values;
            if (in_plain_css_module and allow_unknown_var_in_body) ctx.plain_css_validate_values = false;
            defer ctx.plain_css_validate_values = saved_plain_css_validate_values;

            var roots_buf: std.ArrayListUnmanaged(StmtIndex) = .empty;
            defer roots_buf.deinit(ctx.a);
            ctx.nested_stmt_depth += 1;
            try ctx.pushScope(ctx.a);
            if (!ctx.in_callable and ctx.next_local_slot < ctx.prog.next_global_slot) {
                ctx.next_local_slot = ctx.prog.next_global_slot;
            }
            defer {
                ctx.popScope(ctx.a);
                ctx.nested_stmt_depth -= 1;
            }
            try roots_buf.ensureTotalCapacity(ctx.a, raw.len);
            for (raw) |u| {
                const child_idx = try deps.resolveStmt(ctx, @enumFromInt(u));
                if (ctx.pending_extra_top.items.len > 0) {
                    try roots_buf.ensureUnusedCapacity(ctx.a, ctx.pending_extra_top.items.len);
                    for (ctx.pending_extra_top.items) |ex| {
                        roots_buf.appendAssumeCapacity(ex);
                    }
                    ctx.pending_extra_top.clearRetainingCapacity();
                }
                try roots_buf.append(ctx.a, child_idx);
            }
            body_roots = try ctx.prog.arena.allocator().dupe(StmtIndex, roots_buf.items);
        }
    }

    const idx: StmtIndex = @intCast(ctx.prog.stmts.items.len);
    const ar_idx: u32 = @intCast(ctx.prog.at_rule_stmts.items.len);
    try ctx.prog.at_rule_stmts.append(ctx.a, .{
        .name_intern = effective_name_id,
        .prelude_expr = prelude_expr,
        .media_flags = media_flags,
        .is_plain_css = in_plain_css_module,
        .at_root_behavior = .none,
        .body_direct = body_roots,
        .had_block = body_extra != std.math.maxInt(u32),
    });
    try ctx.prog.stmts.append(ctx.a, .{
        .kind = .at_rule,
        .payload = ar_idx,
        .span = span,
        .origin_id = ctx.currentOrigin(),
    });
    return idx;
}

fn atRootSelectorLooksLikeQuery(selector_text: []const u8) bool {
    const trimmed = std.mem.trim(u8, selector_text, " \t\r\n");
    return trimmed.len >= 2 and trimmed[0] == '(' and std.mem.indexOfScalar(u8, trimmed, ':') != null;
}

fn classifyAtRootSelectorText(selector_text: []const u8) AtRootBehavior {
    const raw = std.mem.trim(u8, selector_text, " \t\n\r");
    if (raw.len < 2 or raw[0] != '(' or raw[raw.len - 1] != ')') return .none;

    const inner = std.mem.trim(u8, raw[1 .. raw.len - 1], " \t\n\r");
    const colon = std.mem.findScalar(u8, inner, ':') orelse return .none;
    const prefix = std.mem.trim(u8, inner[0..colon], " \t\n\r");
    const query_part = std.mem.trim(u8, inner[colon + 1 ..], " \t\n\r");

    const is_without = cssIdentEquals(prefix, "without");
    const is_with = cssIdentEquals(prefix, "with");
    if (!is_without and !is_with) return .none;

    var has_media = false;
    var has_layer = false;
    var has_supports = false;
    var has_all = false;
    var has_rule = false;
    var rest = query_part;
    while (rest.len > 0) {
        rest = std.mem.trimStart(u8, rest, " \t\n\r");
        if (rest.len == 0) break;

        // SAFETY: both tokenization branches assign `token` before it is matched.
        var token: []const u8 = undefined;
        if (rest[0] == '"' or rest[0] == '\'') {
            const quote = rest[0];
            const end = std.mem.findScalarPos(u8, rest, 1, quote) orelse return .none;
            token = rest[1..end];
            rest = rest[end + 1 ..];
        } else {
            const end = std.mem.findAny(u8, rest, " \t\n\r") orelse rest.len;
            token = rest[0..end];
            rest = rest[end..];
        }

        if (cssIdentEquals(token, "media")) {
            has_media = true;
        } else if (cssIdentEquals(token, "layer")) {
            has_layer = true;
        } else if (cssIdentEquals(token, "supports")) {
            has_supports = true;
        } else if (cssIdentEquals(token, "all")) {
            has_all = true;
        } else if (cssIdentEquals(token, "rule")) {
            has_rule = true;
        }
    }

    if (is_without) {
        if (has_all) return .without_all;
        if (has_media and has_supports) return .without_media_supports;
        if (has_media) return .without_media;
        if (has_layer) return .without_layer;
        if (has_supports) return .without_supports;
        if (has_rule) return .without_all;
        return .none;
    }

    if (has_all) return .with_all;
    if (has_media and has_supports) return .with_media_supports;
    if (has_media) return .with_media;
    if (has_layer) return .with_layer;
    if (has_supports) return .with_supports;
    if (has_rule) return .with_rule;
    return .none;
}

fn atRootQueryStartsOnNextLine(source: []const u8, span: Span) bool {
    const start: usize = @min(source.len, @as(usize, span.start));
    const end: usize = @min(source.len, @as(usize, span.end));
    if (end <= start) return false;
    const raw = source[start..end];
    const at_idx = std.mem.indexOf(u8, raw, "@at-root") orelse return false;
    var p = at_idx + "@at-root".len;
    while (p < raw.len and (raw[p] == ' ' or raw[p] == '\t')) : (p += 1) {}
    return p < raw.len and (raw[p] == '\n' or raw[p] == '\r');
}

pub fn resolveAtRootStmt(ctx: anytype, n: AstNode, span: Span, comptime deps: anytype) ResolveError!StmtIndex {
    const off: ExtraIndex = n.payload;
    const selector_slot = ctx.ast.getExtraU32(off);
    const body_extra = ctx.ast.getExtraU32(off + 1);

    var body_roots: []StmtIndex = &.{};
    if (body_extra != std.math.maxInt(u32)) {
        const raw = readChildList(ctx.ast, body_extra);
        if (raw.len > 0) {
            try ctx.pushScope(ctx.a);
            defer ctx.popScope(ctx.a);

            var roots_buf: std.ArrayListUnmanaged(StmtIndex) = .empty;
            defer roots_buf.deinit(ctx.a);
            try roots_buf.ensureTotalCapacity(ctx.a, raw.len);
            for (raw) |u| {
                const child_idx = try deps.resolveStmt(ctx, @enumFromInt(u));
                if (ctx.pending_extra_top.items.len > 0) {
                    try roots_buf.ensureUnusedCapacity(ctx.a, ctx.pending_extra_top.items.len);
                    for (ctx.pending_extra_top.items) |ex| {
                        roots_buf.appendAssumeCapacity(ex);
                    }
                    ctx.pending_extra_top.clearRetainingCapacity();
                }
                try roots_buf.append(ctx.a, child_idx);
            }
            body_roots = try ctx.prog.arena.allocator().dupe(StmtIndex, roots_buf.items);
        }
    }

    var selector_raw_text: ?[]const u8 = null;
    var at_root_behavior: AtRootBehavior = .none;
    if (selector_slot != std.math.maxInt(u32)) {
        const sel_node: NodeIndex = @enumFromInt(selector_slot);
        const sn = ctx.ast.getNode(sel_node);
        if (sn.tag == .expr_unquoted_ident) {
            const raw_id: InternId = @enumFromInt(sn.payload);
            selector_raw_text = ctx.pool.get(raw_id);
            at_root_behavior = classifyAtRootSelectorText(selector_raw_text.?);
        }
    }
    if (selector_raw_text) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len > 0 and selectorHasAtSign(trimmed) and !atRootSelectorLooksLikeQuery(trimmed)) {
            return error.SassError;
        }
    }

    // Query-only empty blocks (and empty @at-root) emit nothing.
    if (body_roots.len == 0) {
        if (body_extra == std.math.maxInt(u32)) {
            if (selector_raw_text) |raw| {
                if (atRootSelectorLooksLikeQuery(raw) and atRootQueryStartsOnNextLine(ctx.ast.source, span)) {
                    // Syntax error in `.sass` where `@at-root` newline query is interpreted as selector.
                    return error.Unsupported;
                }
            }
        }
        return try deps.appendNoop(ctx, span);
    }

    var prelude_expr: ?ExprIndex = null;
    if (selector_slot != std.math.maxInt(u32)) {
        const sel_node: NodeIndex = @enumFromInt(selector_slot);
        const sn = ctx.ast.getNode(sel_node);
        if (sn.tag == .expr_unquoted_ident) {
            const raw_id: InternId = @enumFromInt(sn.payload);
            const raw = ctx.pool.get(raw_id);
            if (std.mem.indexOfScalar(u8, raw, '$') != null) {
                prelude_expr = try deps.resolveInterpolatedTextExpr(ctx, raw, span, true);
            } else {
                prelude_expr = try deps.resolveExpr(ctx.ast, ctx, sel_node);
            }
        } else {
            prelude_expr = try deps.resolveExpr(ctx.ast, ctx, sel_node);
        }
    }

    const idx: StmtIndex = @intCast(ctx.prog.stmts.items.len);
    const ar_idx: u32 = @intCast(ctx.prog.at_rule_stmts.items.len);
    const at_root_name = try ctx.pool.intern("at-root");
    try ctx.prog.at_rule_stmts.append(ctx.a, .{
        .name_intern = at_root_name,
        .prelude_expr = prelude_expr,
        .is_plain_css = isPlainCssStylesheetPath(ctx.module_path),
        .at_root_behavior = at_root_behavior,
        .body_direct = body_roots,
        .had_block = body_extra != std.math.maxInt(u32),
    });
    try ctx.prog.stmts.append(ctx.a, .{
        .kind = .at_rule,
        .payload = ar_idx,
        .span = span,
        .origin_id = ctx.currentOrigin(),
    });
    return idx;
}
