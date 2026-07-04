const std = @import("std");

const builtin_mod = @import("../builtin/mod.zig");
const ast_flat = @import("../frontend/ast_flat.zig");
const media_prelude = @import("media_prelude.zig");
const css_utils = @import("../runtime/css_utils.zig");
const data = @import("data.zig");
const intern_pool_mod = @import("../runtime/intern_pool.zig");
const import_condition = @import("import_condition.zig");
const import_css = @import("import_css.zig");
const name_lookup = @import("name_lookup.zig");
const names = @import("names.zig");
const path_resolution = @import("path_resolution.zig");
const ast_text = @import("ast_text.zig");
const resolve_error_stack = @import("error_stack.zig");

const AstNode = ast_flat.AstNode;
const NodeIndex = ast_flat.NodeIndex;
const ExtraIndex = ast_flat.ExtraIndex;
const ExprIndex = data.ExprIndex;
const Span = data.Span;
const StmtIndex = data.StmtIndex;
const ResolveError = data.ResolveError;
const WithConfigEntry = data.WithConfigEntry;
const InternId = intern_pool_mod.InternId;

const astTextNodeHasInterpolation = ast_text.astTextNodeHasInterpolation;
const astTextNodeRawAlloc = ast_text.astTextNodeRawAlloc;
const parseForwardNameList = ast_text.parseForwardNameList;
const normalizeImportConditionText = import_condition.normalizeImportConditionText;
const validateImportConditionText = import_condition.validateImportConditionText;
const importConditionStartsOnNewLine = import_condition.importConditionStartsOnNewLine;
const importConditionHasIdentifierParenLineBreak = import_condition.importConditionHasIdentifierParenLineBreak;
const importConditionParenIsFunctionCall = import_condition.importConditionParenIsFunctionCall;
const isSingleInterpolationBlockText = import_condition.isSingleInterpolationBlockText;
const normalizePlainCssImportQuote = import_css.normalizePlainCssImportQuote;
const isPlainCssImport = import_css.isPlainCssImport;
const importUrlHasDynamicDollar = import_css.importUrlHasDynamicDollar;
const stripOuterQuotes = import_css.stripOuterQuotes;
const lookupUseBindingInsensitive = name_lookup.lookupUseBindingInsensitive;
const identifierEq = name_lookup.identifierEq;
const defaultNamespaceForUse = names.defaultNamespaceForUse;
const builtinModuleUrlToShortName = names.builtinModuleUrlToShortName;
const isPlainCssStylesheetPath = path_resolution.isPlainCssStylesheetPath;
const setCurrentErrorFrameSpan = resolve_error_stack.setCurrentFrameSpan;

pub fn resolveUseStmt(ctx: anytype, n: AstNode, span: Span, is_top_level_stmt: bool, comptime deps: anytype) ResolveError!StmtIndex {
    if (is_top_level_stmt and ctx.module_directive_locked) return error.SassError;
    const off: ExtraIndex = n.payload;
    const url_id: InternId = @enumFromInt(ctx.ast.getExtraU32(off));
    const namespace_id: InternId = @enumFromInt(ctx.ast.getExtraU32(off + 1));
    const config_ex = ctx.ast.getExtraU32(off + 2);
    const has_config = config_ex != std.math.maxInt(u32);
    const config_entries = if (has_config) try deps.parseWithConfigEntries(ctx, config_ex) else &.{};
    const url = ctx.pool.get(url_id);
    const as_star = (n.flags & 1) != 0;
    if (builtinModuleUrlToShortName(url)) |mod_path| {
        if (has_config) return error.SassError;
        if (as_star) {
            ctx.markScopeRestoreDirty();
            try builtin_mod.addModuleToStarMap(mod_path, &ctx.star_builtin_fns, ctx.a);
        } else {
            const ns_key: []const u8 = if (namespace_id != .none)
                ctx.pool.get(namespace_id)
            else
                mod_path;
            if (lookupUseBindingInsensitive(&ctx.prog.use_map, ns_key)) |existing| {
                switch (existing) {
                    .builtin_module => |already| {
                        if (ctx.visiting_imports.items.len != 0 and std.ascii.eqlIgnoreCase(already, mod_path)) {
                            return try deps.appendNoop(ctx, span);
                        }
                        return error.SassError;
                    },
                    .user_module => return error.SassError,
                }
            }
            try ctx.prog.use_map.put(ctx.a, ns_key, .{ .builtin_module = mod_path });
        }
        return try deps.appendNoop(ctx, span);
    }

    const loader = try deps.requireModuleLoader(ctx);
    const module_path = try deps.requireModuleBasePath(ctx);
    const known_before_count: u32 = @intCast(loader.records_ptr.items.len);
    setCurrentErrorFrameSpan(span);
    const saved_pending_config = loader.pending_next_config_entries;
    if (config_entries.len > 0) loader.pending_next_config_entries = config_entries;
    defer loader.pending_next_config_entries = saved_pending_config;
    const mid = try deps.resolveUserModule(loader, module_path, url);
    if (config_entries.len > 0) {
        try deps.applyUseOrForwardConfig(loader, mid, config_entries, known_before_count, false);
    } else if (ctx.visiting_imports.items.len != 0) {
        var implicit_entries: std.ArrayListUnmanaged(WithConfigEntry) = .empty;
        defer implicit_entries.deinit(ctx.a);
        try deps.collectImplicitUseConfigEntries(ctx, loader, mid, &implicit_entries);
        try deps.applyImplicitImportConfigEntries(loader, mid, known_before_count, implicit_entries.items);
    }
    if (as_star) {
        try deps.mergeStarUserModule(ctx, mid);
    } else {
        const ns_key: []const u8 = if (namespace_id != .none)
            ctx.pool.get(namespace_id)
        else
            defaultNamespaceForUse(url);
        if (lookupUseBindingInsensitive(&ctx.prog.use_map, ns_key)) |existing| {
            switch (existing) {
                .builtin_module => return error.SassError,
                .user_module => |existing_mid| {
                    if (existing_mid != mid) return error.SassError;
                    if (config_entries.len != 0) return error.SassError;
                    if (ctx.visiting_imports.items.len != 0) {
                        return try appendModuleDep(ctx, mid, span, true, false);
                    }
                    return try deps.appendNoop(ctx, span);
                },
            }
        }
        try ctx.prog.use_map.put(ctx.a, ns_key, .{ .user_module = mid });
    }
    const rerun_each_call = ctx.visiting_imports.items.len != 0;
    return try appendModuleDep(ctx, mid, span, rerun_each_call, false);
}

pub fn resolveForwardStmt(ctx: anytype, n: AstNode, span: Span, is_top_level_stmt: bool, comptime deps: anytype) ResolveError!StmtIndex {
    if (is_top_level_stmt and ctx.module_directive_locked) return error.SassError;
    const off: ExtraIndex = n.payload;
    const url_id: InternId = @enumFromInt(ctx.ast.getExtraU32(off));
    const prefix_id: InternId = @enumFromInt(ctx.ast.getExtraU32(off + 1));
    const show_ex = ctx.ast.getExtraU32(off + 2);
    const hide_ex = ctx.ast.getExtraU32(off + 3);
    const config_ex = ctx.ast.getExtraU32(off + 4);
    const has_config = config_ex != std.math.maxInt(u32);
    const config_entries = if (has_config) try deps.parseWithConfigEntries(ctx, config_ex) else &.{};
    const url = ctx.pool.get(url_id);
    const builtin_short = builtinModuleUrlToShortName(url);
    if (has_config and builtin_short != null) {
        return error.SassError;
    }
    const prefix: ?[]const u8 = if (prefix_id == .none) null else ctx.pool.get(prefix_id);
    const show = try parseForwardNameList(ctx.a, ctx.ast, ctx.pool, show_ex);
    const hide = try parseForwardNameList(ctx.a, ctx.ast, ctx.pool, hide_ex);
    if (builtin_short) |short_name| {
        ctx.markScopeRestoreDirty();
        try ctx.forward_rules.append(ctx.a, .{
            .target = .{ .builtin_module = short_name },
            .prefix = prefix,
            .show = show,
            .hide = hide,
            .from_import = ctx.visiting_imports.items.len != 0,
        });
        return try deps.appendNoop(ctx, span);
    }
    const loader = try deps.requireModuleLoader(ctx);
    const module_path = try deps.requireModuleBasePath(ctx);
    const known_before_count: u32 = @intCast(loader.records_ptr.items.len);
    setCurrentErrorFrameSpan(span);
    const saved_pending_config = loader.pending_next_config_entries;
    const forward_initial_entries = if (config_entries.len > 0)
        config_entries
    else if (ctx.initial_config_entries.len != 0)
        ctx.initial_config_entries
    else
        &.{};
    if (forward_initial_entries.len > 0) loader.pending_next_config_entries = forward_initial_entries;
    defer loader.pending_next_config_entries = saved_pending_config;
    const mid = try deps.resolveUserModule(loader, module_path, url);
    if (config_entries.len > 0) {
        try deps.applyUseOrForwardConfig(loader, mid, config_entries, known_before_count, false);
        if (ctx.visiting_imports.items.len != 0) {
            var implicit_entries: std.ArrayListUnmanaged(WithConfigEntry) = .empty;
            defer implicit_entries.deinit(ctx.a);
            try deps.collectImplicitForwardConfigEntries(ctx, loader, mid, prefix, show, hide, &implicit_entries);

            var filtered: std.ArrayListUnmanaged(WithConfigEntry) = .empty;
            defer filtered.deinit(ctx.a);
            try filtered.ensureTotalCapacity(ctx.a, implicit_entries.items.len);
            for (implicit_entries.items) |entry| {
                var blocked_by_explicit = false;
                for (config_entries) |cfg| {
                    if (!cfg.is_default and identifierEq(cfg.name, entry.name)) {
                        blocked_by_explicit = true;
                        break;
                    }
                }
                if (blocked_by_explicit) continue;
                filtered.appendAssumeCapacity(entry);
            }
            try deps.applyImplicitImportConfigEntries(loader, mid, known_before_count, filtered.items);
        }
    } else if (ctx.initial_config_entries.len != 0) {
        var implicit_entries: std.ArrayListUnmanaged(WithConfigEntry) = .empty;
        defer implicit_entries.deinit(ctx.a);
        try deps.collectImplicitForwardConfigEntries(ctx, loader, mid, prefix, show, hide, &implicit_entries);
        try deps.applyUseOrForwardConfig(loader, mid, implicit_entries.items, known_before_count, true);
    } else if (ctx.visiting_imports.items.len != 0) {
        var implicit_entries: std.ArrayListUnmanaged(WithConfigEntry) = .empty;
        defer implicit_entries.deinit(ctx.a);
        try deps.collectImplicitForwardConfigEntries(ctx, loader, mid, prefix, show, hide, &implicit_entries);
        try deps.applyImplicitImportConfigEntries(loader, mid, known_before_count, implicit_entries.items);
    }
    ctx.markScopeRestoreDirty();
    try ctx.forward_rules.append(ctx.a, .{
        .target = .{ .user_module = mid },
        .prefix = prefix,
        .show = show,
        .hide = hide,
        .from_import = ctx.visiting_imports.items.len != 0,
    });
    const rerun_each_call = ctx.visiting_imports.items.len != 0;
    return try appendModuleDep(ctx, mid, span, rerun_each_call, true);
}

pub fn resolveImportStmt(ctx: anytype, n: AstNode, span: Span, comptime deps: anytype) ResolveError!StmtIndex {
    const off: ExtraIndex = n.payload;
    const url_node: NodeIndex = @enumFromInt(ctx.ast.getExtraU32(off));
    const cond_slot = ctx.ast.getExtraU32(off + 1);
    const cond_node: ?NodeIndex = if (cond_slot == std.math.maxInt(u32)) null else @enumFromInt(cond_slot);

    const url_raw_storage = try astTextNodeRawAlloc(ctx.a, ctx.ast, ctx.pool, url_node);
    defer ctx.a.free(url_raw_storage);
    const url_raw = std.mem.trim(u8, url_raw_storage, " \t\n\r");
    const url_inner = stripOuterQuotes(url_raw);
    const has_conds = cond_node != null;
    const url_has_dynamic = astTextNodeHasInterpolation(ctx.ast, url_node) or
        importUrlHasDynamicDollar(url_raw);
    const in_sass_module = std.mem.endsWith(u8, ctx.module_path, ".sass");
    // SAFETY: Initialized before use/free exactly when `has_conds` is true; otherwise defer is skipped.
    var cond_raw_storage: []u8 = undefined;
    defer if (has_conds) ctx.a.free(cond_raw_storage);
    const cond_raw = if (cond_node) |cn| blk: {
        cond_raw_storage = try astTextNodeRawAlloc(ctx.a, ctx.ast, ctx.pool, cn);
        break :blk std.mem.trim(u8, cond_raw_storage, " \t\n\r");
    } else "";
    const cond_has_dynamic = if (cond_node != null)
        astTextNodeHasInterpolation(ctx.ast, cond_node.?) or std.mem.indexOfScalar(u8, cond_raw, '$') != null
    else
        false;

    if (in_sass_module) {
        const stmt_start: usize = @min(ctx.ast.source.len, @as(usize, span.start));
        const url_ast = ctx.ast.getNode(url_node);
        const url_prefix_end: usize = @min(ctx.ast.source.len, @as(usize, url_ast.span_start));
        if (url_prefix_end > stmt_start) {
            const prefix = ctx.ast.source[stmt_start..url_prefix_end];
            if (std.mem.indexOfScalar(u8, prefix, ',') != null and
                std.mem.indexOfAny(u8, prefix, "\r\n") != null)
            {
                return error.SassError;
            }
        }
    }

    const in_plain_css_module = isPlainCssStylesheetPath(ctx.module_path);
    if (in_plain_css_module) {
        if (url_has_dynamic) {
            return error.SassError;
        }
        const stmt_start: usize = @min(ctx.ast.source.len, @as(usize, span.start));
        const url_ast = ctx.ast.getNode(url_node);
        const url_prefix_end: usize = @min(ctx.ast.source.len, @as(usize, url_ast.span_start));
        if (url_prefix_end > stmt_start and
            std.mem.indexOfScalar(u8, ctx.ast.source[stmt_start..url_prefix_end], ',') != null)
        {
            return error.SassError;
        }
        if (has_conds and cond_has_dynamic) {
            return error.SassError;
        }
    }
    const css_only = in_plain_css_module or has_conds or url_has_dynamic or isPlainCssImport(url_raw, url_inner);
    if (!css_only) {
        if (ctx.flow_control_depth > 0 or ctx.in_callable) return error.SassError;
        // dart's stack trace points the parent frame at the import URL
        // (`{parent} l:c root stylesheet` with c = quote start), not the
        // statement head. Pass the url node span alongside the stmt span.
        const url_ast = ctx.ast.getNode(url_node);
        const url_span = Span{ .start = url_ast.span_start, .end = url_ast.span_end };
        return try deps.resolveImportedFile(ctx, url_inner, span, url_span);
    }

    return emitImportAtRuleCssOnly(ctx, span, url_node, cond_node, deps);
}

fn emitImportAtRuleCssOnly(
    ctx: anytype,
    span: Span,
    url_node: NodeIndex,
    cond_node: ?NodeIndex,
    comptime deps: anytype,
) ResolveError!StmtIndex {
    const url_raw_storage = try astTextNodeRawAlloc(ctx.a, ctx.ast, ctx.pool, url_node);
    defer ctx.a.free(url_raw_storage);
    const url_raw = std.mem.trim(u8, url_raw_storage, " \t\n\r");
    const url_inner = stripOuterQuotes(url_raw);
    const has_conds = cond_node != null;
    const in_plain_css_module = isPlainCssStylesheetPath(ctx.module_path);
    var cond_normalized: []const u8 = "";
    var free_cond_normalized = false;
    var cond_source_storage: ?[]u8 = null;
    var url_emit_storage: ?[]u8 = null;
    defer if (url_emit_storage) |buf| ctx.a.free(buf);
    defer if (cond_source_storage) |buf| ctx.a.free(buf);
    defer if (free_cond_normalized) ctx.a.free(cond_normalized);

    const needs_quoted_css_url = url_raw.len == url_inner.len and
        url_inner.len >= 4 and
        std.ascii.eqlIgnoreCase(url_inner[url_inner.len - 4 ..], ".css") and
        !std.mem.startsWith(u8, url_inner, "http://") and
        !std.mem.startsWith(u8, url_inner, "https://") and
        !std.mem.startsWith(u8, url_inner, "//") and
        !std.mem.startsWith(u8, url_raw, "url(");
    var url_emit_text = if (needs_quoted_css_url) blk: {
        url_emit_storage = try std.fmt.allocPrint(ctx.a, "\"{s}\"", .{url_inner});
        break :blk url_emit_storage.?;
    } else url_raw;
    if (normalizePlainCssImportQuote(ctx.a, url_emit_text, in_plain_css_module)) |adjusted| {
        if (url_emit_storage) |owned| ctx.a.free(owned);
        url_emit_storage = adjusted;
        url_emit_text = adjusted;
    }

    if (has_conds) {
        cond_source_storage = try astTextNodeRawAlloc(ctx.a, ctx.ast, ctx.pool, cond_node.?);
        const cond_source = cond_source_storage.?;
        if (std.mem.endsWith(u8, ctx.module_path, ".sass")) {
            const gap_start: usize = @min(ctx.ast.source.len, @as(usize, ctx.ast.getNode(url_node).span_end));
            const gap_end: usize = @min(ctx.ast.source.len, @as(usize, ctx.ast.getNode(cond_node.?).span_start));
            const cond_gap = if (gap_end > gap_start) ctx.ast.source[gap_start..gap_end] else "";
            if (std.mem.indexOfAny(u8, cond_gap, "\r\n") != null or
                importConditionStartsOnNewLine(cond_source) or
                importConditionHasIdentifierParenLineBreak(cond_source))
            {
                return error.SassError;
            }
        }
        const cond_raw = std.mem.trim(u8, cond_source, " \t\n\r");
        cond_normalized = try normalizeImportConditionText(ctx.a, cond_raw);
        free_cond_normalized = !(cond_normalized.ptr == cond_raw.ptr and cond_normalized.len == cond_raw.len);
        try validateImportConditionText(cond_normalized);
    }
    const import_name_id = try ctx.pool.intern("import");
    const prelude_expr = if (has_conds) blk: {
        var parts: std.ArrayListUnmanaged(ExprIndex) = .empty;
        defer parts.deinit(ctx.a);
        const saved = ctx.allow_unknown_var_literal;
        ctx.allow_unknown_var_literal = false;
        defer ctx.allow_unknown_var_literal = saved;
        try parts.append(ctx.a, try deps.resolveInterpolatedTextExpr(ctx, url_emit_text, span, true));
        try deps.appendLiteralExprPart(ctx, &parts, " ", span);
        try parts.append(ctx.a, try resolveImportConditionExpr(ctx, cond_normalized, span, deps));
        break :blk try deps.finishConcatExprParts(ctx, parts.items, span);
    } else if (std.mem.indexOf(u8, url_raw, "#{") != null or
        std.mem.indexOfScalar(u8, url_raw, '$') != null)
    blk: {
        const saved = ctx.allow_unknown_var_literal;
        ctx.allow_unknown_var_literal = false;
        defer ctx.allow_unknown_var_literal = saved;
        break :blk try deps.resolveInterpolatedTextExpr(ctx, url_raw, span, true);
    } else blk: {
        const prelude_id = try ctx.pool.intern(url_emit_text);
        break :blk try deps.appendExpr(ctx.prog, ctx.a, .{
            .kind = .literal_string,
            .payload = deps.packLiteralStringPayload(prelude_id, false, false),
            .span = span,
        });
    };
    if ((has_conds and std.mem.indexOfScalar(u8, cond_normalized, '$') != null) or
        std.mem.indexOf(u8, url_raw, "#{") != null or
        std.mem.indexOfScalar(u8, url_raw, '$') != null)
    {
        deps.markInterpExprErrorOnUndeclaredVar(ctx.prog, prelude_expr);
    }

    const idx: StmtIndex = @intCast(ctx.prog.stmts.items.len);
    const ar_idx: u32 = @intCast(ctx.prog.at_rule_stmts.items.len);
    try ctx.prog.at_rule_stmts.append(ctx.a, .{
        .name_intern = import_name_id,
        .prelude_expr = prelude_expr,
        .is_plain_css = in_plain_css_module,
        .body_direct = &.{},
        .had_block = false,
    });
    try ctx.prog.stmts.append(ctx.a, .{
        .kind = .at_rule,
        .payload = ar_idx,
        .span = span,
        .origin_id = ctx.currentOrigin(),
    });
    return idx;
}

fn resolveImportConditionExpr(ctx: anytype, text: []const u8, span: Span, comptime deps: anytype) ResolveError!ExprIndex {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.indexOfScalar(u8, trimmed, '$') != null and std.mem.indexOf(u8, trimmed, "#{") == null) {
        if (std.mem.indexOfScalar(u8, trimmed, '(')) |open_idx| {
            if (importConditionParenIsFunctionCall(trimmed, open_idx)) {
                if (deps.findMatchingParenSimple(trimmed, open_idx)) |close_idx| {
                    if (close_idx == trimmed.len - 1) {
                        const id = try ctx.pool.intern(trimmed);
                        return try deps.appendStringLiteralExpr(ctx.prog, ctx.a, id, span);
                    }
                }
            }
        }
    }

    if (std.mem.indexOfScalar(u8, text, '$') == null and std.mem.indexOf(u8, text, "#{") == null) {
        const id = try ctx.pool.intern(text);
        return try deps.appendStringLiteralExpr(ctx.prog, ctx.a, id, span);
    }

    var parts: std.ArrayListUnmanaged(ExprIndex) = .empty;
    defer parts.deinit(ctx.a);

    var copy_start: usize = 0;
    var i: usize = 0;
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
        if (c != '(') continue;

        if (importConditionParenIsFunctionCall(text, i)) {
            const close = deps.findMatchingParenSimple(text, i) orelse continue;
            i = close;
            continue;
        }
        const close = deps.findMatchingParenSimple(text, i) orelse continue;
        const inner = text[i + 1 .. close];
        const inner_trimmed = std.mem.trim(u8, inner, " \t\r\n");
        if (std.mem.indexOfScalar(u8, inner_trimmed, '$') == null and std.mem.indexOf(u8, inner_trimmed, "#{") == null) {
            i = close;
            continue;
        }

        try deps.appendTextExprParts(ctx, &parts, text[copy_start..i], span, true);
        try deps.appendLiteralExprPart(ctx, &parts, "(", span);
        if (isSingleInterpolationBlockText(inner_trimmed)) {
            try parts.append(ctx.a, try deps.resolveInterpolatedTextExpr(ctx, inner_trimmed, span, false));
        } else {
            try parts.append(ctx.a, try resolveImportConditionParenExpr(ctx, inner, span, deps));
        }
        try deps.appendLiteralExprPart(ctx, &parts, ")", span);
        copy_start = close + 1;
        i = close;
    }

    try deps.appendTextExprParts(ctx, &parts, text[copy_start..], span, true);
    return try deps.finishConcatExprParts(ctx, parts.items, span);
}

fn resolveImportConditionDynamicOperandExpr(ctx: anytype, text: []const u8, span: Span, comptime deps: anytype) ResolveError!ExprIndex {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) {
        const empty_id = try ctx.pool.intern("");
        return try deps.appendStringLiteralExpr(ctx.prog, ctx.a, empty_id, span);
    }
    if (std.mem.indexOf(u8, trimmed, "#{") != null) {
        return try deps.resolveInterpolatedTextExpr(ctx, trimmed, span, true);
    }
    return try deps.parseSubExpr(ctx, trimmed, span);
}

fn resolveImportConditionParenExpr(ctx: anytype, inner: []const u8, span: Span, comptime deps: anytype) ResolveError!ExprIndex {
    const trimmed = std.mem.trim(u8, inner, " \t\r\n");
    if (trimmed.len == 0) {
        const empty_id = try ctx.pool.intern("");
        return try deps.appendStringLiteralExpr(ctx.prog, ctx.a, empty_id, span);
    }

    if (media_prelude.findTopLevelMediaRangeOperator(trimmed) != null) {
        return try deps.resolveMediaParenExpression(ctx, trimmed, span);
    }

    if (css_utils.findDeclarationColon(trimmed)) |colon_pos| {
        const lhs = std.mem.trim(u8, trimmed[0..colon_pos], " \t\r\n");
        const rhs = std.mem.trim(u8, trimmed[colon_pos + 1 ..], " \t\r\n");

        if (std.mem.indexOfScalar(u8, lhs, '$') == null and std.mem.indexOf(u8, lhs, "#{") == null and
            std.mem.indexOfScalar(u8, rhs, '$') == null and std.mem.indexOf(u8, rhs, "#{") == null)
        {
            const id = try ctx.pool.intern(trimmed);
            return try deps.appendStringLiteralExpr(ctx.prog, ctx.a, id, span);
        }

        var parts: std.ArrayListUnmanaged(ExprIndex) = .empty;
        defer parts.deinit(ctx.a);

        if (std.mem.indexOfScalar(u8, lhs, '$') != null or std.mem.indexOf(u8, lhs, "#{") != null) {
            try parts.append(ctx.a, try resolveImportConditionDynamicOperandExpr(ctx, lhs, span, deps));
        } else {
            try deps.appendTextExprParts(ctx, &parts, lhs, span, false);
        }
        try deps.appendLiteralExprPart(ctx, &parts, ": ", span);
        if (std.mem.indexOfScalar(u8, rhs, '$') != null or std.mem.indexOf(u8, rhs, "#{") != null) {
            try parts.append(ctx.a, try resolveImportConditionDynamicOperandExpr(ctx, rhs, span, deps));
        } else {
            try deps.appendTextExprParts(ctx, &parts, rhs, span, false);
        }
        return try deps.finishConcatExprParts(ctx, parts.items, span);
    }

    if (std.mem.indexOfScalar(u8, trimmed, '$') != null or std.mem.indexOf(u8, trimmed, "#{") != null) {
        return try resolveImportConditionDynamicOperandExpr(ctx, trimmed, span, deps);
    }

    const id = try ctx.pool.intern(trimmed);
    return try deps.appendStringLiteralExpr(ctx.prog, ctx.a, id, span);
}

fn appendModuleDep(ctx: anytype, module_id: u32, span: Span, rerun_each_call: bool, is_forward: bool) ResolveError!StmtIndex {
    const idx: StmtIndex = @intCast(ctx.prog.stmts.items.len);
    const dep_idx: u32 = @intCast(ctx.prog.module_dep_stmts.items.len);
    try ctx.prog.module_dep_stmts.append(ctx.a, .{
        .module_id = module_id,
        .rerun_each_call = rerun_each_call,
        .is_forward = is_forward,
    });
    try ctx.prog.stmts.append(ctx.a, .{
        .kind = .module_dep,
        .payload = dep_idx,
        .span = span,
        .origin_id = ctx.currentOrigin(),
    });
    return idx;
}
