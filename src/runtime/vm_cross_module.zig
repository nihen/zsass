const std = @import("std");
const lexer_mod = @import("../frontend/lexer.zig");
const parser_mod = @import("../frontend/parser.zig");
const compiler_mod = @import("../ir/compiler.zig");
const resolver_mod = @import("../resolve/resolver.zig");
const rule_ir_mod = @import("../ir/rule_ir.zig");
const perf = @import("perf.zig");
const zsass_io = @import("io.zig");
const value_mod = @import("value.zig");
const intern_pool_mod = @import("intern_pool.zig");
const builtin_shared = @import("../builtin/shared.zig");

const Value = value_mod.Value;
const InternId = intern_pool_mod.InternId;
const Span = rule_ir_mod.Span;
const call_arg_splat_sentinel = resolver_mod.call_arg_splat_sentinel;
const content_none_sentinel: u32 = std.math.maxInt(u32);
const no_local_slot_hint: u32 = std.math.maxInt(u32);

pub const LoadCssConfigEntry = struct {
    name: []u8,
    value: Value,
};

pub const LoadCssConfig = struct {
    entries: []LoadCssConfigEntry = &.{},

    pub fn deinit(self: *LoadCssConfig, alloc: std.mem.Allocator) void {
        for (self.entries) |entry| {
            alloc.free(entry.name);
        }
        if (self.entries.len != 0) alloc.free(self.entries);
        self.entries = &.{};
    }

    pub fn isEmpty(self: LoadCssConfig) bool {
        return self.entries.len == 0;
    }
};

pub const LoadCssSeedBinding = struct {
    module_id: u32,
    slot: u32,
    value: Value,
};

const LoadCssArgBinding = struct {
    url_index: usize,
    with_index: ?usize,
};

const identifierEq = builtin_shared.identifierEq;

pub fn runDependencyBody(self: anytype, module_id: u32, rerun_each_call: bool, is_forward: bool) !void {
    if (module_id >= self.program.modules.len) return error.InternalError;
    const shadow_copy = rerun_each_call or
        (self.load_css_module_tag_override != null and self.load_css_module_tag_override.? != self.current_module);
    const saved_state = self.saveState();
    defer self.restoreState(&saved_state);

    const selector_prefix: []const InternId = if (shadow_copy) &.{} else saved_state.stacks.selector_stack.items;
    const start_node_idx = self.rule_ir.nodes.items.len;
    if (shadow_copy) {
        const owner_module = self.effectiveModuleTag();
        if (rerun_each_call and self.shadow_context_root_tag == null) {
            if (self.reusableRerunShadowRoot(owner_module)) |context_root| {
                if (self.findVisibleShadowModuleTag(context_root, module_id)) |existing_tag| {
                    try self.registerVisibleLoadCssModule(owner_module, context_root, module_id, existing_tag);
                    if (!is_forward) return;
                    self.load_css_module_tag_override = existing_tag;
                    self.shadow_context_root_tag = context_root;
                    self.noteRerunShadowRoot(owner_module, context_root);
                } else {
                    const child_tag = self.allocateLoadCssModuleTag();
                    try self.registerVisibleLoadCssModule(owner_module, context_root, module_id, child_tag);
                    self.load_css_module_tag_override = child_tag;
                    self.shadow_context_root_tag = context_root;
                    self.noteRerunShadowRoot(owner_module, context_root);
                }
            } else {
                const child_tag = self.allocateLoadCssModuleTag();
                try self.registerVisibleLoadCssModule(owner_module, child_tag, module_id, child_tag);
                self.load_css_module_tag_override = child_tag;
                self.shadow_context_root_tag = child_tag;
                self.noteRerunShadowRoot(owner_module, child_tag);
            }
        } else {
            const context_root = self.shadow_context_root_tag orelse owner_module;
            if (self.findVisibleShadowModuleTag(context_root, module_id)) |existing_tag| {
                try self.registerVisibleLoadCssModule(owner_module, context_root, module_id, existing_tag);
                if (!rerun_each_call and !is_forward) return;
                self.load_css_module_tag_override = existing_tag;
                self.shadow_context_root_tag = context_root;
            } else {
                const child_tag = self.allocateLoadCssModuleTag();
                try self.registerVisibleLoadCssModule(owner_module, context_root, module_id, child_tag);
                self.load_css_module_tag_override = child_tag;
                self.shadow_context_root_tag = context_root;
            }
        }
    }
    if (module_id < self.module_first_loader_origin.len and
        self.module_first_loader_origin[module_id] == .invalid)
    {
        self.module_first_loader_origin[module_id] = self.current_origin;
    }
    const track_running = module_id < self.module_currently_running.len;
    if (track_running) self.module_currently_running[module_id] = true;
    defer if (track_running) {
        self.module_currently_running[module_id] = false;
    };
    const node_count_before = self.rule_ir.nodes.items.len;
    try runTopModuleWithSelectorPrefix(self, module_id, selector_prefix, shadow_copy);
    if (module_id < self.module_emitted_visible.len) {
        const nodes = self.rule_ir.nodes.items;
        var has_visible = false;
        var i: usize = node_count_before;
        while (i < nodes.len) : (i += 1) {
            switch (nodes[i].kind) {
                .rule_begin, .rule_end, .decl, .decl_raw, .at_rule_simple, .at_rule_begin, .at_rule_end, .comment, .stream_chunk => {
                    has_visible = true;
                    break;
                },
                .stmt_gap, .group_boundary, .sourcemap_gap => continue,
            }
        }
        if (has_visible) {
            self.module_emitted_visible[module_id] = true;
        }
    }
    if (shadow_copy and saved_state.stacks.selector_stack.items.len > 0) {
        const parent_selector = saved_state.stacks.selector_stack.items[saved_state.stacks.selector_stack.items.len - 1];
        try prefixRuleIrRangeTopLevelRules(self, start_node_idx, parent_selector);
    }
}

pub fn runTopDependencyAtCurrentPosition(self: anytype, module_id: u32, rerun_each_call: bool, is_forward: bool) !void {
    if (module_id >= self.program.modules.len) return error.InternalError;
    const effect = self.classifyDependencyRun(module_id, rerun_each_call);
    switch (effect) {
        .skip_body => {
            try self.replayDependencySkipPreamble(module_id);
            return;
        },
        .run_body => {
            if (self.current_chunk == .top and
                self.selector_stack.items.len == 0 and
                self.open_block_depth == 0)
            {
                try self.preEmitFirstLoaderPreambles(module_id);
            }
            if (module_id < self.module_first_loader_origin.len and
                self.module_first_loader_origin[module_id] == .invalid)
            {
                self.module_first_loader_origin[module_id] = self.current_origin;
            }
            try runDependencyBody(self, module_id, rerun_each_call, is_forward);
        },
    }
}

pub fn runTopModuleWithSelectorPrefix(self: anytype, module_id: u32, selector_prefix: []const InternId, rerun_each_call: bool) !void {
    if (module_id >= self.program.modules.len) return error.InternalError;
    if (!rerun_each_call and module_id < self.executed_modules.len and self.executed_modules[module_id]) return;
    self.pc = 0;
    self.current_module = module_id;
    self.current_chunk = .top;
    self.stack.clearRetainingCapacity();
    self.frame_stack.clearRetainingCapacity();
    self.flow_scope_stack.clearRetainingCapacity();
    self.flow_saved_slots.clearRetainingCapacity();
    self.selector_prefix_depth = selector_prefix.len;
    self.clearModuleRuleState(true);
    if (selector_prefix.len > 0) {
        try self.selector_stack.appendSlice(self.allocator, selector_prefix);
        try self.selector_owner_stack.appendNTimes(self.allocator, self.currentEmitModuleTag(), selector_prefix.len);
        try self.scope_push_ir_lens.appendNTimes(self.allocator, self.rule_ir.nodes.items.len, selector_prefix.len);
    }
    self.pending_content_module = content_none_sentinel;
    self.pending_content_chunk = content_none_sentinel;
    self.pending_content_capture = &.{};
    self.pending_content_capture_declared = &.{};
    self.current_builtin_local_slot_hint = no_local_slot_hint;
    self.next_extend_relation_id = 0;
    const current_path = if (module_id < self.program.modules.len)
        self.program.modules[module_id].module_path
    else
        "";
    const already_loaded = current_path.len != 0 and self.isLoadCssModulePathLoaded(current_path);
    if (already_loaded and !rerun_each_call) {
        if (self.moduleHasStaticConfigSeed(module_id)) {
            return error.SassError;
        }
        const is_dynamic_root = self.load_css_module_tag_override != null and module_id == self.program.root_index;
        if (!is_dynamic_root and !self.moduleTopEmitsCss(module_id)) {
            try self.saveCurrentModuleLoadCssState(module_id);
            return;
        }
    }
    if (self.mod_globals_bufs.len > self.current_module) {
        self.prebound_top_locals = self.mod_globals_bufs[self.current_module];
        self.prebound_top_declared = self.mod_global_declared_bufs[self.current_module];
    } else {
        self.prebound_top_locals = null;
        self.prebound_top_declared = null;
    }
    try self.runLoopTop();
    if (!rerun_each_call and module_id < self.executed_modules.len) {
        self.executed_modules[module_id] = true;
    }
    if (self.open_rule_depth > 0) {
        var leak = self.open_rule_depth;
        while (leak > 0) : (leak -= 1) {
            try self.rule_ir.appendRuleEnd(self.allocator, self.currentSourceSpan());
        }
        self.open_rule_depth = 0;
    }
    self.open_block_depth = 0;
    self.clearModuleRuleState(false);
    if (module_id < self.program.modules.len) {
        try self.markLoadCssModulePathLoaded(self.program.modules[module_id].module_path);
        try self.saveCurrentModuleLoadCssState(module_id);
    }
}

fn bindMetaLoadCssArgs(self: anytype, arg_names: []const InternId, argc: usize) !LoadCssArgBinding {
    var url_index: ?usize = null;
    var with_index: ?usize = null;

    var i: usize = 0;
    while (i < argc) : (i += 1) {
        const name_id = if (i < arg_names.len) arg_names[i] else .none;
        if (name_id == call_arg_splat_sentinel) return error.BuiltinUnsupported;
        if (name_id != .none) {
            var raw = self.intern_pool.get(name_id);
            if (raw.len > 0 and raw[0] == '$') raw = raw[1..];
            if (identifierEq(raw, "url")) {
                if (url_index != null) return error.BuiltinArity;
                url_index = i;
                continue;
            }
            if (identifierEq(raw, "with")) {
                if (with_index != null) return error.BuiltinArity;
                with_index = i;
                continue;
            }
            return error.BuiltinArity;
        }

        if (url_index == null) {
            url_index = i;
        } else if (with_index == null) {
            with_index = i;
        } else {
            return error.BuiltinArity;
        }
    }

    return .{
        .url_index = url_index orelse return error.BuiltinArity,
        .with_index = with_index,
    };
}

fn cloneLoadCssConfigName(self: anytype, raw_name: []const u8) ![]u8 {
    var name = raw_name;
    if (name.len > 0 and name[0] == '$') name = name[1..];
    if (name.len == 0) return error.SassError;
    const out = try self.allocator.alloc(u8, name.len);
    for (name, 0..) |c, i| {
        out[i] = if (c == '_') '-' else c;
    }
    return out;
}

fn parseLoadCssWithConfig(self: anytype, with_v: Value) !LoadCssConfig {
    if (with_v.kind() == .nil) return .{};
    if (with_v.kind() != .list) return error.BuiltinType;
    const list_handle = with_v.listHandle();
    if (list_handle >= self.list_pool.items.len) return error.BuiltinType;
    const elems = self.list_pool.items[list_handle];
    if (!with_v.listIsMap(self.list_meta_pool.items)) {
        if (elems.len == 0) return .{};
        return error.BuiltinType;
    }
    if (elems.len == 0) return .{};
    if (elems.len % 2 != 0) return error.SassError;

    var out: std.ArrayListUnmanaged(LoadCssConfigEntry) = .empty;
    errdefer {
        for (out.items) |entry| self.allocator.free(entry.name);
        out.deinit(self.allocator);
    }
    try out.ensureTotalCapacity(self.allocator, elems.len / 2);

    var i: usize = 0;
    while (i + 1 < elems.len) : (i += 2) {
        const key_v = elems[i];
        if (key_v.kind() != .string) return error.SassError;
        const key_name = self.intern_pool.get(key_v.stringIntern());
        const normalized = try cloneLoadCssConfigName(self, key_name);
        errdefer self.allocator.free(normalized);
        for (out.items) |entry| {
            if (identifierEq(entry.name, normalized)) return error.SassError;
        }
        out.appendAssumeCapacity(.{
            .name = normalized,
            .value = elems[i + 1],
        });
    }

    return .{ .entries = try out.toOwnedSlice(self.allocator) };
}

fn cloneValueForLoadCssChild(self: anytype, child: anytype, v: Value) !Value {
    if (v.kind() == .list) {
        const src_handle = v.listHandle();
        if (src_handle >= self.list_pool.items.len) return error.BuiltinType;
        const src_items = self.list_pool.items[src_handle];
        const owned = try child.allocator.alloc(Value, src_items.len);
        errdefer child.allocator.free(owned);
        for (src_items, 0..) |item, idx| {
            owned[idx] = try cloneValueForLoadCssChild(self, child, item);
        }
        const dst_handle: u32 = @intCast(child.list_pool.items.len);
        try child.list_pool.append(child.allocator, owned);
        return Value.listWithMetaEx(dst_handle, v.listSeparator(self.list_meta_pool.items), v.listBracketed(self.list_meta_pool.items), v.listIsMap(self.list_meta_pool.items), v.listCoerceSlash(self.list_meta_pool.items));
    }
    return v;
}

fn freeLoadCssClonedValue(self: anytype, child: anytype, value: Value) void {
    if (value.kind() != .list) return;
    const handle: usize = @intCast(value.listHandle());
    if (handle >= child.list_pool.items.len) return;
    const items = child.list_pool.items[handle];
    for (items) |item| {
        freeLoadCssClonedValue(self, child, item);
    }
    child.allocator.free(items);
    child.list_pool.items[handle] = &.{};
}

fn freeLoadCssSeedBindingLists(self: anytype, child: anytype, seed_bindings: []const LoadCssSeedBinding) void {
    for (seed_bindings) |seed| {
        freeLoadCssClonedValue(self, child, seed.value);
    }
}

fn lookupLoadCssVarTarget(
    map: *const std.StringHashMapUnmanaged(resolver_mod.VarTarget),
    name: []const u8,
) ?resolver_mod.VarTarget {
    var it = map.iterator();
    while (it.next()) |entry| {
        if (identifierEq(entry.key_ptr.*, name)) return entry.value_ptr.*;
    }
    return null;
}

fn loadCssNameIsAmbiguous(map: *const std.StringHashMapUnmanaged(void), name: []const u8) bool {
    var it = map.iterator();
    while (it.next()) |entry| {
        if (identifierEq(entry.key_ptr.*, name)) return true;
    }
    return false;
}

pub fn buildLoadCssSeedBindings(self: anytype, child_vm: anytype, config: LoadCssConfig) ![]LoadCssSeedBinding {
    if (config.entries.len == 0) return try self.allocator.alloc(LoadCssSeedBinding, 0);
    const root_mod = &child_vm.program.modules[child_vm.program.root_index];
    var out: std.ArrayListUnmanaged(LoadCssSeedBinding) = .empty;
    errdefer out.deinit(self.allocator);
    try out.ensureTotalCapacity(self.allocator, config.entries.len);
    for (config.entries) |entry| {
        if (loadCssNameIsAmbiguous(&root_mod.ambiguous_export_default_vars, entry.name)) return error.SassError;
        const target = lookupLoadCssVarTarget(&root_mod.exported_default_vars, entry.name) orelse return error.SassError;
        if (target.module_id >= child_vm.program.modules.len) return error.SassError;
        const row_len = child_vm.program.modules[target.module_id].max_slot;
        if (target.slot >= row_len) return error.SassError;
        const target_path = child_vm.program.modules[target.module_id].module_path;
        if (self.isLoadCssModulePathLoaded(target_path)) return error.SassError;
        const cloned = try cloneValueForLoadCssChild(self, child_vm, entry.value);
        try out.append(self.allocator, .{
            .module_id = target.module_id,
            .slot = target.slot,
            .value = cloned,
        });
    }
    return try out.toOwnedSlice(self.allocator);
}

fn isAbsoluteOrExternalLoadCssUrl(url: []const u8) bool {
    if (std.mem.startsWith(u8, url, "http://")) return true;
    if (std.mem.startsWith(u8, url, "https://")) return true;
    if (std.mem.startsWith(u8, url, "//")) return true;
    if (std.mem.startsWith(u8, url, "url(")) return true;
    return false;
}

fn fileExists(path: []const u8) bool {
    const f = std.Io.Dir.cwd().openFile(zsass_io.io, path, .{}) catch return false;
    defer f.close(zsass_io.io);
    return true;
}

fn resolvePlainCssPath(self: anytype, from_path: []const u8, url: []const u8) !?[]u8 {
    if (isAbsoluteOrExternalLoadCssUrl(url)) return null;
    const base_dir = std.fs.path.dirname(from_path) orelse ".";
    {
        const abs = if (std.fs.path.isAbsolute(url))
            std.fs.path.resolve(self.allocator, &.{url})
        else
            std.fs.path.resolve(self.allocator, &.{ base_dir, url });
        const candidate = abs catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        errdefer self.allocator.free(candidate);
        if (fileExists(candidate)) return candidate;
        self.allocator.free(candidate);
    }
    if (std.fs.path.isAbsolute(url)) return null;
    for (self.program.load_paths) |lp| {
        const candidate = std.fs.path.resolve(self.allocator, &.{ lp, url }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        errdefer self.allocator.free(candidate);
        if (fileExists(candidate)) return candidate;
        self.allocator.free(candidate);
    }
    return null;
}

fn resolveLoadCssPath(self: anytype, url: []const u8) !?[]const u8 {
    if (self.current_module >= self.program.modules.len) return null;
    const from_path = self.program.modules[self.current_module].module_path;
    if (from_path.len == 0) return null;

    if (url.len >= 4 and std.ascii.eqlIgnoreCase(url[url.len - 4 ..], ".css")) {
        return resolvePlainCssPath(self, from_path, url);
    }

    return resolver_mod.resolveUserModulePath(self.allocator, from_path, url, self.program.load_paths, .{ .pkg_importer_enabled = self.program.pkg_importer_enabled }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn stmtSliceNeedsParentWrapper(self: anytype, root: *const resolver_mod.ResolvedProgram, body: []const resolver_mod.StmtIndex) bool {
    for (body) |si| {
        if (stmtNeedsParentWrapper(self, root, si)) return true;
    }
    return false;
}

fn stmtNeedsParentWrapper(self: anytype, root: *const resolver_mod.ResolvedProgram, si: resolver_mod.StmtIndex) bool {
    if (si >= root.stmts.items.len) return false;
    const st = root.stmts.items[si];
    switch (st.kind) {
        .rule => {
            if (st.payload >= root.rule_stmts.items.len) return false;
            const rule = root.rule_stmts.items[st.payload];
            if (rule.is_plain_css and rule.selector_kind == .literal) {
                const selector = self.intern_pool.get(rule.literal_intern);
                if (std.mem.indexOfScalar(u8, selector, '&') != null) return true;
            }
            return stmtSliceNeedsParentWrapper(self, root, rule.body_direct);
        },
        .at_rule => {
            if (st.payload >= root.at_rule_stmts.items.len) return false;
            const at_rule = root.at_rule_stmts.items[st.payload];
            return stmtSliceNeedsParentWrapper(self, root, at_rule.body_direct);
        },
        else => return false,
    }
}

fn loadCssNeedsParentWrapper(self: anytype, bundle: *const resolver_mod.ResolvedBundle) bool {
    if (bundle.root_index >= bundle.modules.len) return false;
    const root = &bundle.modules[bundle.root_index];
    return stmtSliceNeedsParentWrapper(self, root, root.top_stmts);
}

const ParentWrappedRuleRange = struct {
    begin_idx: usize,
    end_idx: usize,
    begin_file_id: u32,
    end_file_id: u32,
    begin_span: Span,
    end_span: Span,
    inner_payload: u32,
};

pub fn wrapRuleIrTopLevelAmpRulesWithParent(self: anytype, start_idx: usize, parent_selector: InternId) !void {
    if (start_idx >= self.rule_ir.nodes.items.len) return;
    const parent_raw = self.intern_pool.get(parent_selector);
    if (std.mem.trim(u8, parent_raw, " \t\r\n").len == 0) return;

    var ranges: std.ArrayListUnmanaged(ParentWrappedRuleRange) = .empty;
    defer ranges.deinit(self.allocator);

    var i = start_idx;
    while (i < self.rule_ir.nodes.items.len) : (i += 1) {
        const node = self.rule_ir.nodes.items[i];
        if (node.kind != .rule_begin) continue;

        var depth: usize = 0;
        var end_idx = i;
        while (end_idx < self.rule_ir.nodes.items.len) : (end_idx += 1) {
            switch (self.rule_ir.nodes.items[end_idx].kind) {
                .rule_begin => depth += 1,
                .rule_end => {
                    if (depth == 0) break;
                    depth -= 1;
                    if (depth == 0) break;
                },
                .decl,
                .decl_raw,
                .at_rule_begin,
                .at_rule_end,
                .at_rule_simple,
                .comment,
                .stmt_gap,
                .group_boundary,
                .sourcemap_gap,
                .stream_chunk,
                => {},
            }
        }
        if (end_idx >= self.rule_ir.nodes.items.len) break;

        const selector_u = self.rule_ir.extra.items[node.payload];
        const selector_id: InternId = @enumFromInt(selector_u);
        const selector_raw = self.intern_pool.get(selector_id);
        if (std.mem.indexOfScalar(u8, selector_raw, '&') != null) {
            try ranges.append(self.allocator, .{
                .begin_idx = i,
                .end_idx = end_idx,
                .begin_file_id = self.rule_ir.node_source_files.items[i],
                .end_file_id = self.rule_ir.node_source_files.items[end_idx],
                .begin_span = .{
                    .start = node.source_start,
                    .end = node.source_end,
                    .file_id = self.rule_ir.node_source_files.items[i],
                },
                .end_span = .{
                    .start = self.rule_ir.nodes.items[end_idx].source_start,
                    .end = self.rule_ir.nodes.items[end_idx].source_end,
                    .file_id = self.rule_ir.node_source_files.items[end_idx],
                },
                .inner_payload = node.payload,
            });
        }

        i = end_idx;
    }

    var ri = ranges.items.len;
    while (ri > 0) {
        ri -= 1;
        const range = ranges.items[ri];
        const wrapper_nest_depth: u32 = if (range.inner_payload + 1 < self.rule_ir.extra.items.len)
            self.rule_ir.extra.items[range.inner_payload + 1]
        else
            0;

        const extra_off: u32 = @intCast(self.rule_ir.extra.items.len);
        try self.rule_ir.extra.appendSlice(self.allocator, &[_]u32{
            @intFromEnum(parent_selector),
            wrapper_nest_depth,
            0,
        });

        try self.rule_ir.nodes.insert(self.allocator, range.begin_idx, .{
            .kind = .rule_begin,
            .payload = extra_off,
            .source_start = range.begin_span.start,
            .source_end = range.begin_span.end,
        });
        try self.rule_ir.node_source_files.insert(self.allocator, range.begin_idx, range.begin_file_id);

        try self.rule_ir.nodes.insert(self.allocator, range.end_idx + 2, .{
            .kind = .rule_end,
            .payload = 0,
            .source_start = range.end_span.start,
            .source_end = range.end_span.end,
        });
        try self.rule_ir.node_source_files.insert(self.allocator, range.end_idx + 2, range.end_file_id);

        const inner_idx = range.begin_idx + 1;
        if (inner_idx < self.rule_ir.nodes.items.len) {
            const inner_node = self.rule_ir.nodes.items[inner_idx];
            if (inner_node.kind == .rule_begin and inner_node.payload + 1 < self.rule_ir.extra.items.len) {
                self.rule_ir.extra.items[inner_node.payload + 1] += 1;
            }
        }
    }
}

pub fn prefixRuleIrRangeTopLevelRules(self: anytype, start_idx: usize, parent_selector: InternId) !void {
    if (start_idx >= self.rule_ir.nodes.items.len) return;
    const parent_raw = self.intern_pool.get(parent_selector);
    if (std.mem.trim(u8, parent_raw, " \t\r\n").len == 0) return;

    var rule_depth: usize = 0;
    var at_rule_depth: usize = 0;
    var i = start_idx;
    while (i < self.rule_ir.nodes.items.len) : (i += 1) {
        const node = self.rule_ir.nodes.items[i];
        switch (node.kind) {
            .rule_begin => {
                if (rule_depth == 0) {
                    const selector_u = self.rule_ir.extra.items[node.payload];
                    const selector_id: InternId = @enumFromInt(selector_u);
                    const selector_raw = self.intern_pool.get(selector_id);
                    const combined = try self.combineNestedRuleSelectorForSelectorResolve(parent_raw, selector_raw);
                    defer self.allocator.free(combined);
                    const combined_id = try self.intern_pool.intern(combined);
                    self.rule_ir.extra.items[node.payload] = @intFromEnum(combined_id);
                }
                rule_depth += 1;
            },
            .rule_end => {
                if (rule_depth > 0) rule_depth -= 1;
            },
            .at_rule_begin => at_rule_depth += 1,
            .at_rule_end => {
                if (at_rule_depth > 0) at_rule_depth -= 1;
            },
            .decl,
            .decl_raw,
            .at_rule_simple,
            .comment,
            .stmt_gap,
            .group_boundary,
            .sourcemap_gap,
            .stream_chunk,
            => {},
        }
    }
}

fn readFileToStringAlloc(self: anytype, path: []const u8) ![]const u8 {
    const file = std.Io.Dir.cwd().openFile(zsass_io.io, path, .{}) catch return error.SassError;
    defer file.close(zsass_io.io);
    var rb: [2048]u8 = undefined;
    var rd = file.reader(zsass_io.io, &rb);
    return rd.interface.allocRemaining(self.allocator, .limited(1 << 29)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SassError,
    };
}

pub fn runLoadCssModule(self: anytype, resolved_path: []const u8, config: LoadCssConfig) !void {
    perf.note(.vm_module_run);
    const source = try readFileToStringAlloc(self, resolved_path);
    defer self.allocator.free(source);

    var scratch = std.heap.ArenaAllocator.init(self.allocator);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const is_plain_css_source = std.mem.endsWith(u8, resolved_path, ".css");
    const is_sass_source = std.mem.endsWith(u8, resolved_path, ".sass");
    var lexer = if (is_plain_css_source)
        lexer_mod.Lexer.initPlainCss(sa, source)
    else
        lexer_mod.Lexer.init(sa, source);
    lexer.source_name = resolved_path;
    lexer.is_indented_syntax = is_sass_source;
    defer lexer.deinit();
    const tokens = lexer.tokenize() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => {
            lexer.printLastErrorDiagnostic("SassError");
            return error.SassError;
        },
    };

    var parser = parser_mod.Parser.init(sa, self.intern_pool, tokens, source);
    parser.is_indented_syntax = is_sass_source;
    defer parser.deinit();
    var ast = parser.parse() catch return error.SassError;
    ast.is_indented_syntax = is_sass_source;
    defer ast.deinit();

    var resolved = resolver_mod.resolveWithEntryPathAndColorPool(self.allocator, &ast, self.intern_pool, resolved_path, self.program.load_paths, self.color_pool) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SassError,
    };
    defer resolved.deinit();

    var child_program = compiler_mod.compile(self.allocator, self.intern_pool, &resolved, self.color_pool) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SassError,
    };
    defer child_program.deinit();

    const parent_selector = if (self.selector_stack.items.len > 0)
        self.selector_stack.items[self.selector_stack.items.len - 1]
    else
        null;
    const needs_parent_wrapper = parent_selector != null and
        is_plain_css_source and
        loadCssNeedsParentWrapper(self, &resolved);

    var child_vm = try self.initLoadCssChildVM(&child_program, is_plain_css_source, parent_selector != null);
    defer child_vm.deinit();
    try child_vm.ensureStaticEvalListsLoaded();
    const seed_bindings = try buildLoadCssSeedBindings(self, &child_vm, config);
    defer self.allocator.free(seed_bindings);
    defer freeLoadCssSeedBindingLists(self, &child_vm, seed_bindings);
    child_vm.load_css_seed_bindings = seed_bindings;
    defer child_vm.load_css_seed_bindings = &.{};
    const start_node_idx = self.rule_ir.nodes.items.len;
    if (parent_selector) |parent| {
        if (is_plain_css_source) {
            try child_vm.runTopWithSelectorPrefix(self.selector_stack.items);
            if (needs_parent_wrapper) {
                try wrapRuleIrTopLevelAmpRulesWithParent(self, start_node_idx, parent);
            }
        } else {
            try child_vm.runTopWithSelectorPrefix(&.{});
            try prefixRuleIrRangeTopLevelRules(self, start_node_idx, parent);
        }
    } else {
        try child_vm.runTopWithSelectorPrefix(&.{});
    }
    try self.syncLoadCssChildStates(&child_vm);
}

pub fn invokeMetaLoadCss(self: anytype, args: []const Value, arg_names: []const InternId) !void {
    if (self.pending_content_chunk != content_none_sentinel) return error.BuiltinUnsupported;

    const binding = try bindMetaLoadCssArgs(self, arg_names, args.len);
    if (binding.url_index >= args.len) return error.BuiltinArity;
    const url_v = args[binding.url_index];
    if (url_v.kind() != .string) return error.BuiltinType;
    const url = self.intern_pool.get(url_v.stringIntern());
    if (url.len == 0) return error.BuiltinArity;

    var config = if (binding.with_index) |wi| blk: {
        if (wi >= args.len) break :blk LoadCssConfig{};
        break :blk try parseLoadCssWithConfig(self, args[wi]);
    } else LoadCssConfig{};
    defer config.deinit(self.allocator);

    if (!config.isEmpty() and url.len >= 4 and std.ascii.eqlIgnoreCase(url[url.len - 4 ..], ".css")) {
        return error.SassError;
    }

    if (std.mem.startsWith(u8, url, "sass:")) {
        if (!config.isEmpty()) return error.SassError;
        return;
    }

    if (isAbsoluteOrExternalLoadCssUrl(url)) return error.SassError;

    const resolved_path = (try resolveLoadCssPath(self, url)) orelse return error.SassError;
    defer self.allocator.free(resolved_path);
    if (!config.isEmpty() and self.isLoadCssModulePathLoaded(resolved_path)) return error.SassError;
    var stack = self.load_css_stack_ptr orelse blk: {
        self.load_css_stack_ptr = &self.load_css_stack_owner;
        break :blk self.load_css_stack_ptr.?;
    };

    var pushed_current = false;
    if (self.current_module < self.program.modules.len) {
        const current_path = self.program.modules[self.current_module].module_path;
        if (current_path.len > 0 and (stack.items.len == 0 or !std.mem.eql(u8, stack.items[stack.items.len - 1], current_path))) {
            try stack.append(self.allocator, current_path);
            pushed_current = true;
        }
    }
    defer {
        if (pushed_current) _ = stack.pop();
    }

    for (stack.items) |p| {
        if (std.mem.eql(u8, p, resolved_path)) return error.SassError;
    }
    try stack.append(self.allocator, resolved_path);
    defer _ = stack.pop();

    const owner_module = self.effectiveModuleTag();
    const child_tag = self.allocateLoadCssModuleTag();
    try self.registerVisibleLoadCssModule(owner_module, owner_module, std.math.maxInt(u32), child_tag);
    try runLoadCssModule(self, resolved_path, config);
    try self.markLoadCssModulePathLoaded(resolved_path);
}
