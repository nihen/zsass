const std = @import("std");

const ast_flat = @import("../frontend/ast_flat.zig");
const deprecation_mod = @import("../runtime/deprecation.zig");
const error_format = @import("../runtime/error_format.zig");
const data = @import("data.zig");
const ast_text = @import("ast_text.zig");
const import_child_ast = @import("import_child_ast.zig");
const import_css = @import("import_css.zig");
const import_scan = @import("import_scan.zig");
const import_preamble = @import("import_preamble.zig");
const module_resolver_state = @import("module_resolver_state.zig");
const path_resolution = @import("path_resolution.zig");

const ExtraIndex = ast_flat.ExtraIndex;
const Span = data.Span;
const StmtIndex = data.StmtIndex;
const ResolveError = data.ResolveError;
const UseBinding = data.UseBinding;

const readChildList = ast_text.readChildList;
const loadImportChildAst = import_child_ast.loadImportChildAst;
const importSourceNeedsConfigSnapshot = import_css.importSourceNeedsConfigSnapshot;
const isBareImportLookupUrl = import_css.isBareImportLookupUrl;
const hasBareImportedTopLevelDeclaration = import_scan.hasBareImportedTopLevelDeclaration;
const recordImportPreambleComments = import_preamble.recordImportPreambleComments;
const adjustModuleStyleImportPreamble = import_preamble.adjustModuleStyleImportPreamble;
const appendImportOrigin = module_resolver_state.appendImportOrigin;
const resolveImportModulePathWithPolicy = path_resolution.resolveImportModulePathWithPolicy;
const spanStartLineColOneBased = data.spanStartLineColOneBased;

/// Inline expansion of Sass file `@import` to parent ctx.
pub fn resolveImportedFile(ctx: anytype, url: []const u8, span: Span, comptime deps: anytype) ResolveError!StmtIndex {
    const entering_import_context = ctx.visiting_imports.items.len == 0;
    const saved_static_config_len = ctx.static_config_vars.items.len;
    var captured_import_config = false;
    defer if (captured_import_config) {
        ctx.truncateStaticConfigVars(saved_static_config_len);
    };

    const loader = try deps.requireModuleLoader(ctx);
    const module_path = try deps.requireModuleBasePath(ctx);
    var effective_lp = loader.load_paths;
    var filtered_lp: ?[]const []const u8 = null;
    defer if (filtered_lp) |buf| ctx.a.free(buf);
    if (ctx.visiting_imports.items.len > 0 and isBareImportLookupUrl(url)) {
        const importer_path = ctx.visiting_imports.items[ctx.visiting_imports.items.len - 1];
        const importer_dir = std.fs.path.dirname(importer_path) orelse ".";
        var keep_count: usize = 0;
        for (effective_lp) |lp| {
            if (!std.mem.eql(u8, lp, importer_dir)) keep_count += 1;
        }
        if (keep_count != effective_lp.len) {
            const buf = try ctx.a.alloc([]const u8, keep_count);
            var wi: usize = 0;
            for (effective_lp) |lp| {
                if (std.mem.eql(u8, lp, importer_dir)) continue;
                buf[wi] = lp;
                wi += 1;
            }
            filtered_lp = buf;
            effective_lp = buf;
        }
    }
    const pkg_enabled = if (ctx.loader) |l| l.pkg_importer_enabled else false;
    const resolved_path = (resolveImportModulePathWithPolicy(ctx.a, module_path, url, effective_lp, true, .{ .pkg_importer_enabled = pkg_enabled }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    }) orelse {
        if (error_format.verboseErrorsEnabled()) {
            deps.resolverStderrPrint("zsass resolver: @import file not found url={s} from={s}\n", .{ url, ctx.module_path });
        }
        return error.SassError;
    };
    defer ctx.a.free(resolved_path);

    for (ctx.visiting_imports.items) |p| {
        if (std.mem.eql(u8, p, resolved_path)) {
            if (error_format.verboseErrorsEnabled()) {
                deps.resolverStderrPrint("zsass resolver: @import circular url={s}\n", .{url});
            }
            return error.SassError;
        }
    }
    if (std.mem.eql(u8, ctx.module_path, resolved_path)) {
        return error.SassError;
    }

    if (loader.deprecation_opts) |dep_opts| {
        const pos = spanStartLineColOneBased(ctx.ast.source.len, ctx.prog.line_starts, span.start);
        try deprecation_mod.emitDeprecation(
            dep_opts,
            .import,
            "Sass @import rules are deprecated and will be removed in Dart Sass 3.0.0.",
            ctx.module_path,
            pos.line,
            pos.col,
        );
    }

    var child_loaded = loadImportChildAst(
        ctx.a,
        ctx.pool,
        if (ctx.loader) |ld| ld.source_cache else null,
        if (ctx.loader) |ld| ld.ast_cache else null,
        resolved_path,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.IoFailure => {
            if (error_format.verboseErrorsEnabled()) {
                deps.resolverStderrPrint("zsass resolver: @import file read failed url={s}\n", .{url});
            }
            return error.SassError;
        },
        error.SyntaxError => return error.SassError,
    };
    defer child_loaded.deinit(ctx.a);

    if (entering_import_context and importSourceNeedsConfigSnapshot(child_loaded.source)) {
        ctx.truncateStaticConfigVars(saved_static_config_len);
        try deps.captureImportConfigSnapshot(ctx);
        captured_import_config = true;
    }

    const child_ast_ptr = child_loaded.astPtr();

    const saved_ast = ctx.ast;
    const saved_path = ctx.module_path;
    const saved_module_directive_locked = ctx.module_directive_locked;
    try ctx.visiting_imports.append(ctx.a, saved_path);
    defer _ = ctx.visiting_imports.pop();

    const use_map_snapshot = try deps.snapshotStringMap(UseBinding, ctx.a, &ctx.prog.use_map);
    defer ctx.a.free(use_map_snapshot);

    ctx.ast = child_ast_ptr;
    ctx.module_path = resolved_path;
    ctx.module_directive_locked = false;
    defer {
        ctx.ast = saved_ast;
        ctx.module_path = saved_path;
        ctx.module_directive_locked = saved_module_directive_locked;
        // OOM during scope unwind cannot propagate from within a `defer`.
        // Log and continue: subsequent compiles will rebuild the map.
        deps.restoreStringMap(UseBinding, ctx.a, &ctx.prog.use_map, use_map_snapshot) catch |err| {
            std.log.warn("restoreStringMap (use_map) failed during defer: {s}", .{@errorName(err)});
        };
    }

    const parent_import_origin = if (ctx.origin_stack.items.len > 0)
        ctx.origin_stack.items[ctx.origin_stack.items.len - 1]
    else
        .invalid;
    const loader_import_origin_idx = try appendImportOrigin(loader, resolved_path, parent_import_origin);
    try ctx.origin_stack.append(ctx.a, loader_import_origin_idx);
    defer _ = ctx.origin_stack.pop();

    const root_node = child_ast_ptr.getNode(child_ast_ptr.root);
    if (root_node.tag != .stylesheet_root) unreachable;
    const child_extra_off: ExtraIndex = root_node.payload;
    const child_raw_full = readChildList(child_ast_ptr, child_extra_off);
    if (ctx.nested_stmt_depth > 0 and hasBareImportedTopLevelDeclaration(child_ast_ptr, child_raw_full)) {
        return error.SassError;
    }

    const child_raw: []const u32 = child_raw_full;
    const child_first_module_directive: ?usize = blk_first_md: {
        for (child_raw_full, 0..) |u, i| {
            const tag = child_ast_ptr.getNode(@enumFromInt(u)).tag;
            if (tag == .stmt_use or tag == .stmt_forward) break :blk_first_md i;
        }
        break :blk_first_md null;
    };
    const loader_records_before: u32 = blk_loader_count: {
        if (child_first_module_directive == null) break :blk_loader_count 0;
        const ld = ctx.loader orelse break :blk_loader_count 0;
        break :blk_loader_count @intCast(ld.records_ptr.items.len);
    };
    const import_is_top_level = ctx.scopes.items.len == 0 and ctx.nested_stmt_depth == 0;
    const import_forward_before = ctx.forward_rules.items.len;
    if (import_is_top_level) {
        try ctx.pushInlineImportStarLayer(ctx.a);
    }
    var expanded_top: std.ArrayListUnmanaged(StmtIndex) = .empty;
    defer expanded_top.deinit(ctx.a);
    try deps.predeclareTopLevelCallables(ctx, child_raw);
    deps.resolveRootStmtSequence(ctx, child_raw, &expanded_top, true) catch |err| {
        if (error_format.verboseErrorsEnabled()) {
            deps.resolverStderrPrint("zsass resolver: inline @import resolve failed path={s} err={}\n", .{ resolved_path, err });
        }
        return err;
    };
    if (import_is_top_level) {
        ctx.popInlineImportStarLayer(ctx.a);
    }
    var fi: usize = import_forward_before;
    while (fi < ctx.forward_rules.items.len) : (fi += 1) {
        try deps.mergeForwardRuleIntoImportScope(ctx, ctx.forward_rules.items[fi], false);
    }

    try recordImportPreambleComments(ctx.prog, loader, loader_import_origin_idx, expanded_top.items);
    if (child_first_module_directive != null) {
        const loader_records_after: u32 = if (ctx.loader) |ld| @intCast(ld.records_ptr.items.len) else 0;
        try adjustModuleStyleImportPreamble(
            ctx.a,
            ctx.prog,
            &expanded_top,
            loader_records_after > loader_records_before,
        );
    }

    if (expanded_top.items.len > 0) {
        try ctx.pending_extra_top.appendSlice(ctx.a, expanded_top.items);
    }

    return try deps.appendNoop(ctx, span);
}
