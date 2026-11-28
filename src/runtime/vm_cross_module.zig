const std = @import("std");
const error_format = @import("error_format.zig");
const file_access_mod = @import("../resolve/file_access.zig");
const deprecation_mod = @import("deprecation.zig");
const resource_budget = @import("resource_budget.zig");
const stack_guard = @import("stack_guard.zig");
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
const vm_dispatch = @import("vm_dispatch.zig");
const vm_module_load = @import("vm_module_load.zig");

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
    // Where this `@use`/`@forward` is, for the trace of a warning raised
    // while the module runs.
    try self.module_run_sites.append(self.allocator, .{
        .module_id = @intCast(self.diagnosticModuleIndex()),
        .offset = self.current_source_span.start,
        .forward = is_forward,
    });
    defer _ = self.module_run_sites.pop();
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
    const track_running = module_id < self.module_currently_running.len;
    if (track_running) self.module_currently_running[module_id] = true;
    defer if (track_running) {
        self.module_currently_running[module_id] = false;
    };
    try runTopModuleWithSelectorPrefix(self, module_id, selector_prefix, shadow_copy);
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
            if (module_id < self.module_css_deferred.len and self.module_css_deferred[module_id]) {
                self.module_css_deferred[module_id] = false;
                try vm_module_load.emitModuleCss(self, module_id);
                return;
            }
            return;
        },
        .run_body => {
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
    if (self.frame_stack.items.len > 0) {
        // Reclaim slot storage of any frames left behind by a previous top
        // run (top frames are not popped on halt). frame_stack[0] is the
        // oldest frame, so its marker is the lowest pool position.
        self.frame_slot_pool.release(self.frame_stack.items[0].slot_pool_marker);
    }
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
        // Snapshot pure-top dependency state right after its top ran, before
        // the entry root can mutate it (cross-assign / !global writes stay
        // per-entry, exactly as they would by re-running the top).
        if (selector_prefix.len == 0 and self.load_css_module_tag_override == null) {
            self.saveModuleToCrossEntryStates(module_id);
        }
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

/// "$url: 1 is not a string." for meta.load-css().
fn reportLoadCssTypeMismatch(self: anytype, comptime param: []const u8, v: value_mod.Value) error{SassError} {
    return reportLoadCssTypeMismatchAs(self, param, v, "string");
}

fn reportLoadCssTypeMismatchAs(self: anytype, comptime param: []const u8, v: value_mod.Value, comptime expected: []const u8) error{SassError} {
    var bctx = vm_dispatch.builtinContext(self);
    builtin_shared.reportArgumentTypeMismatch(&bctx, param, v, expected) catch {};
    return error.SassError;
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
        .url_index = url_index orelse return builtin_shared.reportMissingArgument("url"),
        .with_index = with_index,
    };
}

fn cloneLoadCssConfigName(self: anytype, raw_name: []const u8) ![]u8 {
    // A key is the name without `$`: `("$a": b)` names the variable `$$a`.
    const name = raw_name;
    if (name.len == 0) return error.SassError;
    const out = try self.allocator.alloc(u8, name.len);
    for (name, 0..) |c, i| {
        out[i] = if (c == '_') '-' else c;
    }
    return out;
}

fn parseLoadCssWithConfig(self: anytype, with_v: Value) !LoadCssConfig {
    if (with_v.kind() == .nil) return .{};
    if (with_v.kind() != .list) return reportLoadCssTypeMismatchAs(self, "with", with_v, "map");
    const list_handle = with_v.listHandle();
    if (list_handle >= self.list_pool.items.len) return error.BuiltinType;
    const elems = self.list_pool.items[list_handle];
    if (!with_v.listIsMap(self.list_meta_pool.items)) {
        if (elems.len == 0) return .{};
        return reportLoadCssTypeMismatchAs(self, "with", with_v, "map");
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
        if (key_v.kind() != .string) return reportLoadCssTypeMismatch(self, "with key", key_v);
        const key_name = self.intern_pool.get(key_v.stringIntern());
        const normalized = try cloneLoadCssConfigName(self, key_name);
        errdefer self.allocator.free(normalized);
        for (out.items) |entry| {
            if (identifierEq(entry.name, normalized)) {
                var buf: [512]u8 = undefined;
                if (std.fmt.bufPrint(&buf, "The variable ${s} was configured twice.", .{key_name})) |msg| {
                    error_format.setContextMessage(msg);
                } else |_| {}
                return error.SassError;
            }
        }
        out.appendAssumeCapacity(.{
            .name = normalized,
            .value = elems[i + 1],
        });
    }

    return .{ .entries = try out.toOwnedSlice(self.allocator) };
}

fn cloneValueForLoadCssChild(self: anytype, child: anytype, v: Value) !Value {
    try stack_guard.check();
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
    // A number with a unit lives in the VM's number pool; the child has its
    // own, so the number is made again there.
    if (v.kind() == .number and v.unitId(&self.number_pool) != .none) {
        return Value.number(v.asF64(&self.number_pool), v.unitId(&self.number_pool), &child.number_pool, child.allocator);
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

/// `path` as written from the working directory, when that can be found.
fn cwdRelativePath(self: anytype, path: []const u8) error{OutOfMemory}!?[]u8 {
    const cwd = zsass_io.realPathAlloc(std.Io.Dir.cwd(), ".", self.allocator) catch return null;
    defer self.allocator.free(cwd);
    return try std.fs.path.relativeAlloc(self.allocator, cwd, null, cwd, path);
}

/// "_other.scss was already loaded, so it can't be configured using
/// \"with\".", with the path as written from the working directory.
fn reportAlreadyLoaded(self: anytype, path: []const u8) void {
    const shown = cwdRelativePath(self, path) catch null;
    defer if (shown) |t| self.allocator.free(t);
    var buf: [1024]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "{s} was already loaded, so it can't be configured using \"with\".", .{shown orelse path})) |msg| {
        error_format.setContextMessage(msg);
    } else |_| {}
}

pub fn buildLoadCssSeedBindings(self: anytype, child_vm: anytype, config: LoadCssConfig) ![]LoadCssSeedBinding {
    if (config.entries.len == 0) return try self.allocator.alloc(LoadCssSeedBinding, 0);
    const root_mod = &child_vm.program.modules[child_vm.program.root_index];
    var out: std.ArrayListUnmanaged(LoadCssSeedBinding) = .empty;
    errdefer out.deinit(self.allocator);
    try out.ensureTotalCapacity(self.allocator, config.entries.len);
    for (config.entries) |entry| {
        if (loadCssNameIsAmbiguous(&root_mod.ambiguous_export_default_vars, entry.name)) return error.SassError;
        const target = lookupLoadCssVarTarget(&root_mod.exported_default_vars, entry.name) orelse {
            var buf: [512]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "${s} was not declared with !default in the @used module.", .{entry.name})) |msg| {
                error_format.setContextMessage(msg);
            } else |_| {}
            return error.SassError;
        };
        if (target.module_id >= child_vm.program.modules.len) return error.SassError;
        const row_len = child_vm.program.modules[target.module_id].max_slot;
        if (target.slot >= row_len) return error.SassError;
        const target_path = child_vm.program.modules[target.module_id].module_path;
        if (self.isLoadCssModulePathLoaded(target_path)) {
            // The loaded module is named by its path; one it forwards is not.
            if (target.module_id == child_vm.program.root_index) {
                reportAlreadyLoaded(self, target_path);
            } else {
                error_format.setContextMessage("This module was already loaded, so it can't be configured using \"with\".");
            }
            return error.SassError;
        }
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
    var probe: file_access_mod.Probe = .{ .access = resource_budget.ResourceBudget.fileAccess(self.budget) };
    const found = try resolvePlainCssPathProbed(self, &probe, from_path, url);
    if (found) |path| {
        if (probe.allowsFile(path)) return path;
        self.allocator.free(path);
        return error.FileImportDenied;
    }
    if (probe.denied) return error.FileImportDenied;
    return null;
}

fn resolvePlainCssPathProbed(self: anytype, probe: *file_access_mod.Probe, from_path: []const u8, url: []const u8) !?[]u8 {
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
        if (probe.allows(candidate) and fileExists(candidate)) return candidate;
        self.allocator.free(candidate);
    }
    if (std.fs.path.isAbsolute(url)) return null;
    for (self.program.load_paths) |lp| {
        const candidate = std.fs.path.resolve(self.allocator, &.{ lp, url }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        errdefer self.allocator.free(candidate);
        if (probe.allows(candidate) and fileExists(candidate)) return candidate;
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

    return resolver_mod.resolveUserModulePath(self.allocator, from_path, url, self.program.load_paths, .{
        .pkg_importer_enabled = self.program.pkg_importer_enabled,
        .file_access = resource_budget.ResourceBudget.fileAccess(self.budget),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileImportDenied => return error.FileImportDenied,
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

fn wrapRuleIrTopLevelAmpRulesWithParent(self: anytype, start_idx: usize, parent_selector: InternId) !void {
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
        const selector_id: InternId = @fromBackingInt(@intCast(selector_u));
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

    // Each range gains a rule around it.
    if (self.rule_ir.budget) |b| try b.chargeIrNodes(2 * ranges.items.len);
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
            @backingInt(parent_selector),
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

/// `keyframes` or a vendor-prefixed spelling such as `-webkit-keyframes`: one
/// prefix word between two hyphens, matched case-sensitively.
fn isKeyframesAtRuleName(name: []const u8) bool {
    const raw = if (name.len > 0 and name[0] == '@') name[1..] else name;
    if (std.mem.eql(u8, raw, "keyframes")) return true;
    const suffix = "-keyframes";
    if (raw.len <= suffix.len + 1 or raw[0] != '-') return false;
    if (!std.mem.eql(u8, raw[raw.len - suffix.len ..], suffix)) return false;
    return std.mem.findScalar(u8, raw[1 .. raw.len - suffix.len], '-') == null;
}

/// At-rules whose block holds style rules, so that a comment directly inside
/// one is wrapped like a top-level comment.
fn isStyleRuleGroupAtRuleName(name: []const u8) bool {
    const raw = if (name.len > 0 and name[0] == '@') name[1..] else name;
    return std.ascii.eqlIgnoreCase(raw, "media") or std.ascii.eqlIgnoreCase(raw, "supports");
}

/// Nest the statements a `meta.load-css()` call appended from `start_idx` on
/// under `parent_selector`: an outermost style rule gets the parent selector
/// prepended, and a comment at the top level or directly inside `@media` /
/// `@supports` is wrapped in a rule of its own. Keyframe selectors are not
/// style rules and stay as written.
fn prefixRuleIrRangeTopLevelRules(self: anytype, start_idx: usize, parent_selector: InternId) !void {
    if (start_idx >= self.rule_ir.nodes.items.len) return;
    const parent_raw = self.intern_pool.get(parent_selector);
    if (std.mem.trim(u8, parent_raw, " \t\r\n").len == 0) return;

    const AtRuleKind = enum { style_group, keyframes, other };
    var at_rule_stack: std.ArrayListUnmanaged(AtRuleKind) = .empty;
    defer at_rule_stack.deinit(self.allocator);
    // Open `@keyframes` blocks.
    var keyframes_depth: usize = 0;
    var wrapped_comments: usize = 0;
    // Runs of wrapped comments; consecutive ones share one rule, with only
    // gaps between them, as in the rebuild below.
    var wrapped_runs: usize = 0;
    var in_run = false;

    var rule_depth: usize = 0;
    var i = start_idx;
    while (i < self.rule_ir.nodes.items.len) : (i += 1) {
        const node = self.rule_ir.nodes.items[i];
        switch (node.kind) {
            .comment, .stmt_gap, .group_boundary, .sourcemap_gap => {},
            else => in_run = false,
        }
        switch (node.kind) {
            .rule_begin => {
                if (rule_depth == 0 and keyframes_depth == 0) {
                    const selector_u = self.rule_ir.extra.items[node.payload];
                    const selector_id: InternId = @fromBackingInt(@intCast(selector_u));
                    const selector_raw = self.intern_pool.get(selector_id);
                    const combined = try self.combineNestedRuleSelectorForSelectorResolve(parent_raw, selector_raw);
                    defer self.allocator.free(combined);
                    const combined_id = try self.intern_pool.intern(combined);
                    self.rule_ir.extra.items[node.payload] = @backingInt(combined_id);
                }
                rule_depth += 1;
            },
            .rule_end => {
                if (rule_depth > 0) rule_depth -= 1;
            },
            .at_rule_begin => {
                const name_id: InternId = @fromBackingInt(@intCast(self.rule_ir.extra.items[node.payload]));
                const name = self.intern_pool.get(name_id);
                const kind: AtRuleKind = if (isKeyframesAtRuleName(name))
                    .keyframes
                else if (isStyleRuleGroupAtRuleName(name))
                    .style_group
                else
                    .other;
                try at_rule_stack.append(self.allocator, kind);
                if (kind == .keyframes) keyframes_depth += 1;
            },
            .at_rule_end => {
                if (at_rule_stack.pop()) |kind| {
                    if (kind == .keyframes) keyframes_depth -= 1;
                }
            },
            .comment => {
                // The nearest enclosing at-rule decides.
                const stack = at_rule_stack.items;
                if (rule_depth == 0 and (stack.len == 0 or stack[stack.len - 1] == .style_group)) {
                    wrapped_comments += 1;
                    if (!in_run) wrapped_runs += 1;
                    in_run = true;
                } else {
                    in_run = false;
                }
            },
            .decl,
            .decl_raw,
            .at_rule_simple,
            .stmt_gap,
            .group_boundary,
            .sourcemap_gap,
            .stream_chunk,
            => {},
        }
    }
    if (wrapped_comments == 0) return;
    // One rule opened and closed per run.
    if (self.rule_ir.budget) |b| try b.chargeIrNodes(2 * wrapped_runs);

    // Rebuild the tail of both node buffers in one pass; inserting two nodes
    // per comment in place would move the rest of the buffer every time.
    const Node = @TypeOf(self.rule_ir.nodes.items[0]);
    const old_nodes = try self.allocator.dupe(Node, self.rule_ir.nodes.items[start_idx..]);
    defer self.allocator.free(old_nodes);
    const old_files = try self.allocator.dupe(u32, self.rule_ir.node_source_files.items[start_idx..]);
    defer self.allocator.free(old_files);
    try self.rule_ir.nodes.ensureTotalCapacity(self.allocator, start_idx + old_nodes.len + 2 * wrapped_comments);
    try self.rule_ir.node_source_files.ensureTotalCapacity(self.allocator, start_idx + old_nodes.len + 2 * wrapped_comments);
    try self.rule_ir.extra.ensureUnusedCapacity(self.allocator, 4 * wrapped_comments);
    self.rule_ir.nodes.items.len = start_idx;
    self.rule_ir.node_source_files.items.len = start_idx;

    at_rule_stack.clearRetainingCapacity();
    rule_depth = 0;
    const extend_snapshot: u32 = @intCast(self.rule_ir.extend_edges.items.len);
    // Consecutive comments share one wrapping rule.
    var open_wrap: ?struct { node: Node, file_id: u32 } = null;
    for (old_nodes, old_files) |node, file_id| {
        var wrap = false;
        switch (node.kind) {
            .rule_begin => rule_depth += 1,
            .rule_end => {
                if (rule_depth > 0) rule_depth -= 1;
            },
            .at_rule_begin => {
                const name_id: InternId = @fromBackingInt(@intCast(self.rule_ir.extra.items[node.payload]));
                const kind: AtRuleKind = if (isStyleRuleGroupAtRuleName(self.intern_pool.get(name_id))) .style_group else .other;
                at_rule_stack.appendAssumeCapacity(kind);
            },
            .at_rule_end => _ = at_rule_stack.pop(),
            .comment => {
                const stack = at_rule_stack.items;
                wrap = rule_depth == 0 and (stack.len == 0 or stack[stack.len - 1] == .style_group);
            },
            .stmt_gap, .group_boundary, .sourcemap_gap => {
                // A gap between two wrapped comments is inside the rule.
                if (open_wrap != null) continue;
            },
            else => {},
        }
        if (!wrap) {
            if (open_wrap) |last| {
                self.rule_ir.nodes.appendAssumeCapacity(.{
                    .kind = .rule_end,
                    .payload = 0,
                    .source_start = last.node.source_start,
                    .source_end = last.node.source_end,
                });
                self.rule_ir.node_source_files.appendAssumeCapacity(last.file_id);
                open_wrap = null;
            }
            self.rule_ir.nodes.appendAssumeCapacity(node);
            self.rule_ir.node_source_files.appendAssumeCapacity(file_id);
            continue;
        }
        const starts_wrap = open_wrap == null;
        if (starts_wrap) {
            const extra_off: u32 = @intCast(self.rule_ir.extra.items.len);
            self.rule_ir.extra.appendSliceAssumeCapacity(&[_]u32{ @backingInt(parent_selector), 1, 0, extend_snapshot });
            self.rule_ir.nodes.appendAssumeCapacity(.{
                .kind = .rule_begin,
                .payload = extra_off,
                .source_start = node.source_start,
                .source_end = node.source_end,
            });
            self.rule_ir.node_source_files.appendAssumeCapacity(file_id);
        }
        self.rule_ir.nodes.appendAssumeCapacity(node);
        self.rule_ir.node_source_files.appendAssumeCapacity(file_id);
        // The first comment is now the first line of the rule's body, not
        // the tail of the line it followed in the source.
        if (starts_wrap) self.rule_ir.clearCommentLeadingSameLineAt(self.rule_ir.nodes.items.len - 1);
        open_wrap = .{ .node = node, .file_id = file_id };
    }
    if (open_wrap) |last| {
        self.rule_ir.nodes.appendAssumeCapacity(.{
            .kind = .rule_end,
            .payload = 0,
            .source_start = last.node.source_start,
            .source_end = last.node.source_end,
        });
        self.rule_ir.node_source_files.appendAssumeCapacity(last.file_id);
    }
}

/// Mark the rules and at-rules a nested `meta.load-css()` appended from
/// `start_idx` on as nested statements, which are not separated by blank
/// lines the way top-level statements are.
fn markRuleIrRangeAsNested(self: anytype, start_idx: usize) void {
    var depth: usize = 0;
    // The outermost at-rule block the range ends with, if it ends with one.
    var trailing_at_rule: ?usize = null;
    var i = start_idx;
    while (i < self.rule_ir.nodes.items.len) : (i += 1) {
        const node = self.rule_ir.nodes.items[i];
        switch (node.kind) {
            .rule_begin => {
                if (depth == 0) {
                    trailing_at_rule = null;
                    if (self.rule_ir.extra.items[node.payload + 1] == 0) self.rule_ir.extra.items[node.payload + 1] = 1;
                }
                depth += 1;
            },
            .at_rule_begin => {
                if (depth == 0) {
                    trailing_at_rule = i;
                    if (self.rule_ir.extra.items[node.payload + 2] == 0) self.rule_ir.extra.items[node.payload + 2] = 1;
                }
                depth += 1;
            },
            .rule_end, .at_rule_end => {
                if (depth > 0) depth -= 1;
            },
            .decl, .decl_raw, .at_rule_simple, .comment, .stream_chunk => {
                if (depth == 0) trailing_at_rule = null;
            },
            .stmt_gap, .group_boundary, .sourcemap_gap => {},
        }
    }
    // An at-rule block that bubbles out of a style rule to the top level is
    // followed by a blank line like any other top-level block.
    if (trailing_at_rule) |idx| {
        if (self.open_block_depth == self.open_rule_depth) self.rule_ir.setPreserveAtRuleBlockFollowingBlankAt(idx, true);
    }
}

/// Mark the outermost rules and at-rules a top-level `meta.load-css()`
/// appended from `start_idx` on as top-level statements. The official CLI
/// separates all of them by a blank line, including a rule that was nested in
/// the loaded stylesheet (`a { b { ... } }` prints `a` and `a b` apart).
fn markRuleIrRangeAsTopLevel(self: anytype, start_idx: usize) void {
    var depth: usize = 0;
    var i = start_idx;
    while (i < self.rule_ir.nodes.items.len) : (i += 1) {
        const node = self.rule_ir.nodes.items[i];
        switch (node.kind) {
            .rule_begin => {
                if (depth == 0) {
                    self.rule_ir.extra.items[node.payload + 1] = 0;
                    self.rule_ir.setSuppressLeadingBlankAt(i, false);
                }
                depth += 1;
            },
            .at_rule_begin => {
                if (depth == 0) {
                    self.rule_ir.extra.items[node.payload + 2] = 0;
                    self.rule_ir.setSuppressLeadingBlankAt(i, false);
                }
                depth += 1;
            },
            .rule_end, .at_rule_end => {
                if (depth > 0) depth -= 1;
            },
            else => {},
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

pub const LoadCssRunOptions = struct {
    /// Copy the child's module globals back into this VM after the run.
    sync_state: bool = true,
    /// Silence `@debug` / `@warn` / deprecations in the child run.
    quiet: bool = false,
};

/// A failed load of the module is a Sass error unless a limit stopped it.
fn loadCssFailure(err: anyerror) (std.mem.Allocator.Error || resource_budget.LimitError || error{SassError}) {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (resource_budget.isLimitError(err)) return @errorCast(err);
    return error.SassError;
}

pub fn runLoadCssModule(self: anytype, resolved_path: []const u8, config: LoadCssConfig, opts: LoadCssRunOptions) !void {
    perf.note(.vm_module_run);
    const source = try readFileToStringAlloc(self, resolved_path);
    defer self.allocator.free(source);
    if (self.budget) |b| try b.checkSourceBytes(source.len);

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
            lexer.noteLastErrorMessage();
            return error.SassError;
        },
    };

    var parser = parser_mod.Parser.init(sa, self.intern_pool, tokens, source);
    parser.is_indented_syntax = is_sass_source;
    parser.is_plain_css = is_plain_css_source;
    if (self.budget) |b| parser.max_syntax_depth = b.limits.max_syntax_depth;
    defer parser.deinit();
    var ast = parser.parse() catch |err| return loadCssFailure(err);
    ast.is_indented_syntax = is_sass_source;
    defer ast.deinit();

    // The child draws on the same budget and file policy as this compilation.
    // The module's own configurations and imports warn under this
    // compilation's deprecation options, located in the module and below
    // the trace that reached `meta.load-css()`.
    var resolved = blk: {
        const saved_provider = deprecation_mod.trace_provider;
        const saved_outer = deprecation_mod.outer_trace_provider;
        const saved_label = deprecation_mod.outer_root_label;
        deprecation_mod.outer_trace_provider = saved_provider;
        deprecation_mod.outer_root_label = "load-css()";
        deprecation_mod.trace_provider = null;
        defer {
            deprecation_mod.trace_provider = saved_provider;
            deprecation_mod.outer_trace_provider = saved_outer;
            deprecation_mod.outer_root_label = saved_label;
        }
        break :blk resolver_mod.resolveWithEntryPathColorPoolCachesAndPersistent(self.allocator, &ast, self.intern_pool, resolved_path, self.program.load_paths, self.color_pool, null, null, null, &self.deprecation_opts, null, self.budget) catch |err| return loadCssFailure(err);
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
    // A long @error message the module raised is the parent's to print.
    defer if (child_vm.error_message_full) |m| {
        if (self.allocator.dupe(u8, m)) |copy| {
            if (self.error_message_full) |old| self.allocator.free(old);
            self.error_message_full = copy;
        } else |_| {}
    };
    defer self.deprecation_opts.takeWarningState(&child_vm.deprecation_opts);
    // A warning in the module shows its source and, below it, the trace
    // that reached `meta.load-css()`.
    child_vm.diag_entry_source = source;
    child_vm.diag_parent = self;
    if (opts.quiet) child_vm.deprecation_opts.quiet = true;
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
    if (child_vm.nested_in_parent_block) {
        markRuleIrRangeAsNested(self, start_node_idx);
    } else {
        markRuleIrRangeAsTopLevel(self, start_node_idx);
    }
    if (opts.sync_state) try self.syncLoadCssChildStates(&child_vm);
}

/// Limit on the `meta.load-css()` stack, which gains two entries per nested
/// load: 200 modules that load one another. Each level runs a child VM on
/// the native stack, so the limit has to hold on a small stack too; the
/// official CLI itself runs out of stack between 100 and 500 levels.
const max_load_css_depth = 400;

pub fn invokeMetaLoadCss(self: anytype, args: []const Value, arg_names: []const InternId) !void {
    if (self.pending_content_chunk != content_none_sentinel) {
        error_format.setContextMessage("Mixin doesn't accept a content block.");
        return error.SassError;
    }

    const binding = try bindMetaLoadCssArgs(self, arg_names, args.len);
    if (binding.url_index >= args.len) return error.BuiltinArity;
    const url_v = args[binding.url_index];
    if (url_v.kind() != .string) return reportLoadCssTypeMismatch(self, "url", url_v);
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
        if (!config.isEmpty()) {
            var buf: [512]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "Built-in module {s} can't be configured.", .{url})) |msg| {
                error_format.setContextMessage(msg);
            } else |_| {}
            return error.SassError;
        }
        return;
    }

    if (isAbsoluteOrExternalLoadCssUrl(url)) return error.SassError;

    const had_message = error_format.currentContextMessage() != null;
    const resolved_path = (try resolveLoadCssPath(self, url)) orelse {
        // An ambiguous URL has said which files it could mean.
        if (had_message or error_format.currentContextMessage() == null) error_format.setContextMessage("Can't find stylesheet to import.");
        return error.SassError;
    };
    defer self.allocator.free(resolved_path);
    if (!config.isEmpty() and self.isLoadCssModulePathLoaded(resolved_path)) {
        reportAlreadyLoaded(self, resolved_path);
        return error.SassError;
    }
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

    // The paths may be written `input.scss` and `./input.scss`.
    const resolved_canonical = try std.fs.path.resolve(self.allocator, &.{resolved_path});
    defer self.allocator.free(resolved_canonical);
    for (stack.items) |p| {
        const canonical = try std.fs.path.resolve(self.allocator, &.{p});
        defer self.allocator.free(canonical);
        if (std.mem.eql(u8, canonical, resolved_canonical)) {
            const shown = try cwdRelativePath(self, resolved_canonical);
            defer if (shown) |t| self.allocator.free(t);
            var buf: [1024]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "Module loop: {s} is already being loaded.", .{shown orelse resolved_path})) |msg| {
                error_format.setContextMessage(msg);
            } else |_| {}
            return error.SassError;
        }
    }
    // Each nested load runs a child VM on the native stack; fail cleanly
    // before a long chain of modules overflows it.
    if (stack.items.len >= max_load_css_depth) return error.SassError;
    try stack.append(self.allocator, resolved_path);
    defer _ = stack.pop();

    const owner_module = self.effectiveModuleTag();
    const child_tag = self.allocateLoadCssModuleTag();
    try self.registerVisibleLoadCssModule(owner_module, owner_module, std.math.maxInt(u32), child_tag);
    try runLoadCssModule(self, resolved_path, config, .{});
    try self.markLoadCssModulePathLoaded(resolved_path);
}
