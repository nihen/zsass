const std = @import("std");

const builtin_mod = @import("../builtin/mod.zig");
const resolver_eval = @import("resolver_eval.zig");
const value_mod = @import("../runtime/value.zig");
const intern_pool_mod = @import("../runtime/intern_pool.zig");
const data = @import("data.zig");
const names = @import("names.zig");
const name_lookup = @import("name_lookup.zig");

const CallableTarget = data.CallableTarget;
const ForwardRuleResolved = data.ForwardRuleResolved;
const ModuleExports = data.ModuleExports;
const ModuleResolver = data.ModuleResolver;
const ResolvedProgram = data.ResolvedProgram;
const ResolveError = data.ResolveError;
const SlotId = data.SlotId;
const VarTarget = data.VarTarget;
const WithConfigEntry = data.WithConfigEntry;
const InternPool = intern_pool_mod.InternPool;

const forwardAllowsPlain = names.forwardAllowsPlain;
const forwardAllowsVar = names.forwardAllowsVar;
const isPrivateMemberName = names.isPrivateMemberName;
const withForwardPrefix = names.withForwardPrefix;
const lookupCallableTargetInsensitive = name_lookup.lookupCallableTargetInsensitive;
const lookupConfigVarTargetInsensitive = name_lookup.lookupConfigVarTargetInsensitive;
const lookupIdentifierIdInsensitive = name_lookup.lookupIdentifierIdInsensitive;
const lookupVoidFlagInsensitive = name_lookup.lookupVoidFlagInsensitive;

fn sameVarTarget(a: VarTarget, b: VarTarget) bool {
    return a.module_id == b.module_id and a.slot == b.slot;
}

pub fn sameCallableTarget(a: CallableTarget, b: CallableTarget) bool {
    return a.module_id == b.module_id and a.id == b.id;
}

fn markAmbiguousName(
    alloc: std.mem.Allocator,
    set: *std.StringHashMapUnmanaged(void),
    name: []const u8,
) !void {
    if (lookupVoidFlagInsensitive(set, name)) return;
    const gop = try set.getOrPut(alloc, name);
    if (!gop.found_existing) gop.key_ptr.* = try alloc.dupe(u8, name);
}

pub fn requireModuleExports(loader: *const ModuleResolver, module_id: u32) ResolveError!*const ModuleExports {
    if (module_id >= loader.records_ptr.items.len) return error.InternalError;
    return &loader.records_ptr.items[module_id].exports;
}

fn valueEqSimple(a: value_mod.Value, b: value_mod.Value) bool {
    return a.kind() == b.kind() and a.p32Of() == b.p32Of() and a.p64Of() == b.p64Of();
}

const LoaderValueEqEnv = struct {
    loader: *const ModuleResolver,

    pub fn allocator(self: *const LoaderValueEqEnv) std.mem.Allocator {
        return self.loader.alloc;
    }

    /// Long-lived alloc used when appending to the Sidecar Value pool.
    pub fn poolAlloc(self: *const LoaderValueEqEnv) std.mem.Allocator {
        return self.loader.alloc;
    }

    pub fn pool(self: *const LoaderValueEqEnv) *InternPool {
        return self.loader.pool;
    }

    pub fn numberPool(self: *LoaderValueEqEnv) *value_mod.NumberPool {
        return &self.loader.shared_value_pools.number_pool;
    }

    pub fn listMetaPool(self: *LoaderValueEqEnv) *value_mod.ListMetaPool {
        return &self.loader.shared_value_pools.list_meta_pool;
    }

    pub fn stringFlagsPool(self: *LoaderValueEqEnv) *value_mod.StringFlagsPool {
        return &self.loader.shared_value_pools.string_flags_pool;
    }

    pub fn callablePayloadPool(self: *LoaderValueEqEnv) *value_mod.CallablePayloadPool {
        return &self.loader.shared_value_pools.callable_payload_pool;
    }

    pub fn colorPool(self: *const LoaderValueEqEnv) ?*value_mod.ColorPool {
        return self.loader.color_pool;
    }

    pub fn lookupVar(_: *const LoaderValueEqEnv, _: SlotId) ?value_mod.Value {
        return null;
    }

    pub fn lookupCrossVar(_: *const LoaderValueEqEnv, _: u32, _: SlotId) ?value_mod.Value {
        return null;
    }

    pub fn getStaticList(self: *const LoaderValueEqEnv, handle: value_mod.ListHandle) ?[]const value_mod.Value {
        const idx: usize = @intCast(handle);
        if (idx >= self.loader.static_eval_store.lists.items.len) return null;
        return self.loader.static_eval_store.lists.items[idx];
    }
};

fn configValueEq(loader: *const ModuleResolver, a: value_mod.Value, b: value_mod.Value) bool {
    if (valueEqSimple(a, b)) return true;
    if (a.kind() != .list and a.kind() != .color and b.kind() != .list and b.kind() != .color) return false;
    var env: LoaderValueEqEnv = .{ .loader = loader };
    return resolver_eval.valueEq(&env, a, b);
}

const packSeedKey = data.packConfigSeedKey;

fn loaderHasExplicitConfigForTarget(loader: *const ModuleResolver, target: VarTarget) bool {
    const key = packSeedKey(target.module_id, target.slot);
    if (loader.config_seed_accum.get(key)) |acc| {
        return acc.explicit_set;
    }
    return false;
}

fn loaderExplicitConfigValueForTarget(loader: *const ModuleResolver, target: VarTarget) ?value_mod.Value {
    const key = packSeedKey(target.module_id, target.slot);
    if (loader.config_seed_accum.get(key)) |acc| {
        if (acc.explicit_set) return acc.explicit_value;
    }
    return null;
}

fn sameExportSourceModule(loader: *const ModuleResolver, a_module_id: u32, b_module_id: u32) bool {
    if (a_module_id == b_module_id) return true;
    if (a_module_id >= loader.records_ptr.items.len or b_module_id >= loader.records_ptr.items.len) return false;
    return std.mem.eql(u8, loader.records_ptr.items[a_module_id].path, loader.records_ptr.items[b_module_id].path);
}

fn putExportSourceModule(
    alloc: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(u32),
    name: []const u8,
    source_module_id: u32,
) !void {
    try map.put(alloc, name, source_module_id);
}

fn mergeForwardVarExport(
    alloc: std.mem.Allocator,
    out: *ModuleExports,
    loader: *const ModuleResolver,
    module_id: u32,
    name: []const u8,
    target: VarTarget,
    source_module_id: u32,
    from_import: bool,
) ResolveError!void {
    if (lookupVoidFlagInsensitive(&out.ambiguous_vars, name)) return;
    if (lookupConfigVarTargetInsensitive(&out.vars, name)) |existing| {
        if (existing.module_id == module_id) {
            if (from_import) {
                try out.vars.put(alloc, name, target);
                try putExportSourceModule(alloc, &out.var_source_modules, name, source_module_id);
            } else {
                try out.shadowed_forward_vars.put(alloc, name, target);
            }
            return;
        }
        const existing_source_module_id = lookupIdentifierIdInsensitive(&out.var_source_modules, name) orelse existing.module_id;
        if (sameVarTarget(existing, target) or sameExportSourceModule(loader, existing_source_module_id, source_module_id)) return;
        if (from_import) {
            try out.vars.put(alloc, name, target);
            try putExportSourceModule(alloc, &out.var_source_modules, name, source_module_id);
            return;
        }
        return error.SassError;
    }
    try out.vars.put(alloc, name, target);
    try putExportSourceModule(alloc, &out.var_source_modules, name, source_module_id);
}

fn markForwardAmbiguousVarExport(
    alloc: std.mem.Allocator,
    out: *ModuleExports,
    module_id: u32,
    name: []const u8,
    from_import: bool,
) !void {
    if (lookupVoidFlagInsensitive(&out.ambiguous_vars, name)) return;
    if (lookupConfigVarTargetInsensitive(&out.vars, name)) |existing| {
        if (existing.module_id == module_id and !from_import) return;
    }
    try markAmbiguousName(alloc, &out.ambiguous_vars, name);
}

fn mergeForwardDefaultVarExport(
    alloc: std.mem.Allocator,
    out: *ModuleExports,
    loader: *const ModuleResolver,
    module_id: u32,
    name: []const u8,
    target: VarTarget,
    source_module_id: u32,
    from_import: bool,
) ResolveError!void {
    if (lookupVoidFlagInsensitive(&out.ambiguous_default_vars, name)) return;
    if (lookupConfigVarTargetInsensitive(&out.default_vars, name)) |existing| {
        if (existing.module_id == module_id) {
            if (from_import) {
                try out.default_vars.put(alloc, name, target);
                try putExportSourceModule(alloc, &out.default_var_source_modules, name, source_module_id);
            }
            return;
        }
        const existing_source_module_id = lookupIdentifierIdInsensitive(&out.default_var_source_modules, name) orelse existing.module_id;
        if (sameVarTarget(existing, target) or sameExportSourceModule(loader, existing_source_module_id, source_module_id)) return;
        if (from_import) {
            try out.default_vars.put(alloc, name, target);
            try putExportSourceModule(alloc, &out.default_var_source_modules, name, source_module_id);
            return;
        }
        return error.SassError;
    }
    try out.default_vars.put(alloc, name, target);
    try putExportSourceModule(alloc, &out.default_var_source_modules, name, source_module_id);
}

fn markForwardAmbiguousDefaultVarExport(
    alloc: std.mem.Allocator,
    out: *ModuleExports,
    module_id: u32,
    name: []const u8,
    from_import: bool,
) !void {
    if (lookupVoidFlagInsensitive(&out.ambiguous_default_vars, name)) return;
    if (lookupConfigVarTargetInsensitive(&out.default_vars, name)) |existing| {
        if (existing.module_id == module_id and !from_import) return;
    }
    try markAmbiguousName(alloc, &out.ambiguous_default_vars, name);
}

fn mergeForwardCallableExport(
    alloc: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(CallableTarget),
    source_map: *std.StringHashMapUnmanaged(u32),
    ambiguous: *std.StringHashMapUnmanaged(void),
    loader: *const ModuleResolver,
    module_id: u32,
    name: []const u8,
    target: CallableTarget,
    source_module_id: u32,
    from_import: bool,
) ResolveError!void {
    if (lookupVoidFlagInsensitive(ambiguous, name)) return;
    if (lookupCallableTargetInsensitive(map, name)) |existing| {
        if (existing.module_id == module_id) {
            if (from_import) {
                try map.put(alloc, name, target);
                try putExportSourceModule(alloc, source_map, name, source_module_id);
            }
            return;
        }
        const existing_source_module_id = lookupIdentifierIdInsensitive(source_map, name) orelse existing.module_id;
        if (sameCallableTarget(existing, target) or sameExportSourceModule(loader, existing_source_module_id, source_module_id)) return;
        if (from_import) {
            try map.put(alloc, name, target);
            try putExportSourceModule(alloc, source_map, name, source_module_id);
            return;
        }
        return error.SassError;
    }
    try map.put(alloc, name, target);
    try putExportSourceModule(alloc, source_map, name, source_module_id);
}

fn markForwardAmbiguousCallableExport(
    alloc: std.mem.Allocator,
    map: *const std.StringHashMapUnmanaged(CallableTarget),
    ambiguous: *std.StringHashMapUnmanaged(void),
    module_id: u32,
    name: []const u8,
    from_import: bool,
) !void {
    if (lookupVoidFlagInsensitive(ambiguous, name)) return;
    if (lookupCallableTargetInsensitive(map, name)) |existing| {
        if (existing.module_id == module_id and !from_import) return;
    }
    try markAmbiguousName(alloc, ambiguous, name);
}

pub fn buildModuleExports(
    meta_alloc: std.mem.Allocator,
    prog: *ResolvedProgram,
    module_id: u32,
    forward_rules: []const ForwardRuleResolved,
    loader: *const ModuleResolver,
) ResolveError!ModuleExports {
    var out: ModuleExports = .{};
    errdefer out.deinit(meta_alloc);

    var vit = prog.global_slots.iterator();
    while (vit.next()) |e| {
        const name = e.key_ptr.*;
        if (isPrivateMemberName(name)) continue;
        if (!lookupVoidFlagInsensitive(&prog.declared_global_names, name)) continue;
        if (!out.vars.contains(name)) {
            try out.vars.put(meta_alloc, name, .{
                .module_id = module_id,
                .slot = e.value_ptr.*,
            });
            try out.var_source_modules.put(meta_alloc, name, module_id);
        }
    }
    var dvit = prog.default_vars.iterator();
    while (dvit.next()) |e| {
        const name = e.key_ptr.*;
        if (isPrivateMemberName(name)) {
            if (lookupConfigVarTargetInsensitive(&out.private_default_vars, name) == null) {
                try out.private_default_vars.put(meta_alloc, name, .{
                    .module_id = module_id,
                    .slot = e.value_ptr.*,
                });
            }
            continue;
        }
        if (!out.default_vars.contains(name)) {
            try out.default_vars.put(meta_alloc, name, .{
                .module_id = module_id,
                .slot = e.value_ptr.*,
            });
            try out.default_var_source_modules.put(meta_alloc, name, module_id);
        }
    }
    var mit = prog.mixin_names.iterator();
    while (mit.next()) |e| {
        const name = e.key_ptr.*;
        if (isPrivateMemberName(name)) continue;
        if (!out.mixins.contains(name)) {
            try out.mixins.put(meta_alloc, name, .{
                .module_id = module_id,
                .id = e.value_ptr.*,
            });
            try out.mixin_source_modules.put(meta_alloc, name, module_id);
        }
    }
    var fit = prog.function_names.iterator();
    while (fit.next()) |e| {
        const name = e.key_ptr.*;
        if (isPrivateMemberName(name)) continue;
        if (!out.functions.contains(name)) {
            try out.functions.put(meta_alloc, name, .{
                .module_id = module_id,
                .id = e.value_ptr.*,
            });
            try out.function_source_modules.put(meta_alloc, name, module_id);
        }
    }
    for (prog.rule_stmts.items) |r| {
        if (r.selector_kind != .literal or !r.is_placeholder) continue;
        const name = loader.pool.get(r.literal_intern);
        if (!out.placeholders.contains(name)) try out.placeholders.put(meta_alloc, name, {});
    }

    for (forward_rules) |fr| {
        switch (fr.target) {
            .builtin_module => |module_name| {
                var builtin_functions: std.StringHashMapUnmanaged(u32) = .empty;
                defer builtin_functions.deinit(meta_alloc);
                try builtin_mod.fillBuiltinFunctionNameToIdMap(meta_alloc, module_name, &builtin_functions);

                var builtin_mixins: std.StringHashMapUnmanaged(u32) = .empty;
                defer builtin_mixins.deinit(meta_alloc);
                try builtin_mod.fillBuiltinMixinNameToIdMap(meta_alloc, module_name, &builtin_mixins);

                var fbit = builtin_functions.iterator();
                while (fbit.next()) |e| {
                    const name = e.key_ptr.*;
                    const out_name = try withForwardPrefix(prog, fr.prefix, name);
                    if (!forwardAllowsPlain(out_name, fr.show, fr.hide)) continue;
                    if (lookupIdentifierIdInsensitive(&out.builtin_functions, out_name)) |existing| {
                        if (existing == e.value_ptr.*) continue;
                        if (fr.from_import) {
                            try out.builtin_functions.put(meta_alloc, out_name, e.value_ptr.*);
                            continue;
                        }
                        return error.SassError;
                    }
                    try out.builtin_functions.put(meta_alloc, out_name, e.value_ptr.*);
                }
                var mbit = builtin_mixins.iterator();
                while (mbit.next()) |e| {
                    const name = e.key_ptr.*;
                    const out_name = try withForwardPrefix(prog, fr.prefix, name);
                    if (!forwardAllowsPlain(out_name, fr.show, fr.hide)) continue;
                    if (lookupIdentifierIdInsensitive(&out.builtin_mixins, out_name)) |existing| {
                        if (existing == e.value_ptr.*) continue;
                        if (fr.from_import) {
                            try out.builtin_mixins.put(meta_alloc, out_name, e.value_ptr.*);
                            continue;
                        }
                        return error.SassError;
                    }
                    try out.builtin_mixins.put(meta_alloc, out_name, e.value_ptr.*);
                }
            },
            .user_module => |forward_module_id| {
                const dep = try requireModuleExports(loader, forward_module_id);
                var fvit = dep.vars.iterator();
                while (fvit.next()) |e| {
                    const name = e.key_ptr.*;
                    const out_name = try withForwardPrefix(prog, fr.prefix, name);
                    if (!forwardAllowsVar(out_name, fr.show, fr.hide)) continue;
                    const source_module_id = lookupIdentifierIdInsensitive(&dep.var_source_modules, name) orelse e.value_ptr.*.module_id;
                    try mergeForwardVarExport(meta_alloc, &out, loader, module_id, out_name, e.value_ptr.*, source_module_id, fr.from_import);
                }
                var afvit = dep.ambiguous_vars.iterator();
                while (afvit.next()) |e| {
                    const name = e.key_ptr.*;
                    const out_name = try withForwardPrefix(prog, fr.prefix, name);
                    if (!forwardAllowsVar(out_name, fr.show, fr.hide)) continue;
                    try markForwardAmbiguousVarExport(meta_alloc, &out, module_id, out_name, fr.from_import);
                }
                var fdvit = dep.default_vars.iterator();
                while (fdvit.next()) |e| {
                    if (loaderHasExplicitConfigForTarget(loader, e.value_ptr.*)) continue;
                    const name = e.key_ptr.*;
                    const out_name = try withForwardPrefix(prog, fr.prefix, name);
                    if (!forwardAllowsVar(out_name, fr.show, fr.hide)) continue;
                    const source_module_id = lookupIdentifierIdInsensitive(&dep.default_var_source_modules, name) orelse e.value_ptr.*.module_id;
                    try mergeForwardDefaultVarExport(meta_alloc, &out, loader, module_id, out_name, e.value_ptr.*, source_module_id, fr.from_import);
                }
                var afdvit = dep.ambiguous_default_vars.iterator();
                while (afdvit.next()) |e| {
                    const name = e.key_ptr.*;
                    const out_name = try withForwardPrefix(prog, fr.prefix, name);
                    if (!forwardAllowsVar(out_name, fr.show, fr.hide)) continue;
                    try markForwardAmbiguousDefaultVarExport(meta_alloc, &out, module_id, out_name, fr.from_import);
                }
                // In the first forward dep where out.mixins / out.ambiguous_mixins is empty, all
                // mergeForwardCallableExport lookup twice (ambiguous + map) can be
                // skipped and bulk inserted. Large legacy `@forward` chains make
                // this route hot.
                const fmixins_fast = out.mixins.count() == 0 and out.ambiguous_mixins.count() == 0;
                if (fmixins_fast) {
                    try out.mixins.ensureUnusedCapacity(meta_alloc, dep.mixins.count());
                    try out.mixin_source_modules.ensureUnusedCapacity(meta_alloc, dep.mixins.count());
                }
                var fmit = dep.mixins.iterator();
                while (fmit.next()) |e| {
                    const name = e.key_ptr.*;
                    const out_name = try withForwardPrefix(prog, fr.prefix, name);
                    if (!forwardAllowsPlain(out_name, fr.show, fr.hide)) continue;
                    const source_module_id = lookupIdentifierIdInsensitive(&dep.mixin_source_modules, name) orelse e.value_ptr.*.module_id;
                    if (fmixins_fast) {
                        out.mixins.putAssumeCapacity(out_name, e.value_ptr.*);
                        out.mixin_source_modules.putAssumeCapacity(out_name, source_module_id);
                    } else {
                        try mergeForwardCallableExport(meta_alloc, &out.mixins, &out.mixin_source_modules, &out.ambiguous_mixins, loader, module_id, out_name, e.value_ptr.*, source_module_id, fr.from_import);
                    }
                }
                var afmit = dep.ambiguous_mixins.iterator();
                while (afmit.next()) |e| {
                    const name = e.key_ptr.*;
                    const out_name = try withForwardPrefix(prog, fr.prefix, name);
                    if (!forwardAllowsPlain(out_name, fr.show, fr.hide)) continue;
                    try markForwardAmbiguousCallableExport(meta_alloc, &out.mixins, &out.ambiguous_mixins, module_id, out_name, fr.from_import);
                }
                const ffunctions_fast = out.functions.count() == 0 and out.ambiguous_functions.count() == 0;
                if (ffunctions_fast) {
                    try out.functions.ensureUnusedCapacity(meta_alloc, dep.functions.count());
                    try out.function_source_modules.ensureUnusedCapacity(meta_alloc, dep.functions.count());
                }
                var ffit = dep.functions.iterator();
                while (ffit.next()) |e| {
                    const name = e.key_ptr.*;
                    const out_name = try withForwardPrefix(prog, fr.prefix, name);
                    if (!forwardAllowsPlain(out_name, fr.show, fr.hide)) continue;
                    const source_module_id = lookupIdentifierIdInsensitive(&dep.function_source_modules, name) orelse e.value_ptr.*.module_id;
                    if (ffunctions_fast) {
                        out.functions.putAssumeCapacity(out_name, e.value_ptr.*);
                        out.function_source_modules.putAssumeCapacity(out_name, source_module_id);
                    } else {
                        try mergeForwardCallableExport(meta_alloc, &out.functions, &out.function_source_modules, &out.ambiguous_functions, loader, module_id, out_name, e.value_ptr.*, source_module_id, fr.from_import);
                    }
                }
                var affit = dep.ambiguous_functions.iterator();
                while (affit.next()) |e| {
                    const name = e.key_ptr.*;
                    const out_name = try withForwardPrefix(prog, fr.prefix, name);
                    if (!forwardAllowsPlain(out_name, fr.show, fr.hide)) continue;
                    try markForwardAmbiguousCallableExport(meta_alloc, &out.functions, &out.ambiguous_functions, module_id, out_name, fr.from_import);
                }
                var fbit = dep.builtin_functions.iterator();
                while (fbit.next()) |e| {
                    const name = e.key_ptr.*;
                    const out_name = try withForwardPrefix(prog, fr.prefix, name);
                    if (!forwardAllowsPlain(out_name, fr.show, fr.hide)) continue;
                    if (lookupIdentifierIdInsensitive(&out.builtin_functions, out_name)) |existing| {
                        if (existing == e.value_ptr.*) continue;
                        if (fr.from_import) {
                            try out.builtin_functions.put(meta_alloc, out_name, e.value_ptr.*);
                            continue;
                        }
                        return error.SassError;
                    }
                    try out.builtin_functions.put(meta_alloc, out_name, e.value_ptr.*);
                }
                var bmit = dep.builtin_mixins.iterator();
                while (bmit.next()) |e| {
                    const name = e.key_ptr.*;
                    const out_name = try withForwardPrefix(prog, fr.prefix, name);
                    if (!forwardAllowsPlain(out_name, fr.show, fr.hide)) continue;
                    if (lookupIdentifierIdInsensitive(&out.builtin_mixins, out_name)) |existing| {
                        if (existing == e.value_ptr.*) continue;
                        if (fr.from_import) {
                            try out.builtin_mixins.put(meta_alloc, out_name, e.value_ptr.*);
                            continue;
                        }
                        return error.SassError;
                    }
                    try out.builtin_mixins.put(meta_alloc, out_name, e.value_ptr.*);
                }
                var fpit = dep.placeholders.iterator();
                while (fpit.next()) |e| {
                    const name = e.key_ptr.*;
                    const out_name = try withForwardPrefix(prog, fr.prefix, name);
                    if (!forwardAllowsPlain(out_name, fr.show, fr.hide)) continue;
                    if (out.placeholders.contains(out_name)) continue;
                    try out.placeholders.put(meta_alloc, out_name, {});
                }
            },
        }
    }

    return out;
}

pub fn applyConfigTarget(
    self: *ModuleResolver,
    target: VarTarget,
    value: value_mod.Value,
    is_default: bool,
) ResolveError!void {
    const key = packSeedKey(target.module_id, target.slot);
    const gop = try self.config_seed_accum.getOrPut(self.meta, key);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{};
    }
    const acc = gop.value_ptr;

    if (is_default) {
        if (!acc.default_set) {
            acc.default_set = true;
            acc.default_value = value;
        }
        return;
    }

    if (acc.explicit_set) {
        if (!configValueEq(self, acc.explicit_value, value)) return error.SassError;
        return;
    }
    acc.explicit_set = true;
    acc.explicit_value = value;
}

pub fn applyUseOrForwardConfig(
    self: *ModuleResolver,
    module_id: u32,
    entries: []const WithConfigEntry,
    known_before_count: u32,
    allow_same_already_configured: bool,
) ResolveError!void {
    if (entries.len == 0) return;
    const ex = try requireModuleExports(self, module_id);
    for (entries) |entry| {
        if (lookupVoidFlagInsensitive(&ex.ambiguous_default_vars, entry.name)) return error.SassError;
        const target = lookupConfigVarTargetInsensitive(&ex.default_vars, entry.name) orelse
            lookupConfigVarTargetInsensitive(&ex.private_default_vars, entry.name) orelse {
            const already_configured = lookupConfigVarTargetInsensitive(&ex.vars, entry.name) orelse return error.SassError;
            if (loaderExplicitConfigValueForTarget(self, already_configured)) |existing| {
                if (configValueEq(self, existing, entry.value)) continue;
            }
            return error.SassError;
        };
        // Sass: Already loaded module cannot be reconfigured with with().
        // `known_before_count` is the number of modules that existed before this stmt was executed.
        // If you try to set a module_id smaller than that, an "already loaded" error will occur.
        // However, in cross-entry persistent mode, the module only loaded by the prior entry is
        // Allow config (less than entry_records_baseline) since this is the "first load" for this entry.
        if (target.module_id < known_before_count and target.module_id >= self.entry_records_baseline) {
            if (allow_same_already_configured) {
                if (loaderExplicitConfigValueForTarget(self, target)) |existing| {
                    if (configValueEq(self, existing, entry.value)) continue;
                }
            }
            return error.SassError;
        }
        try applyConfigTarget(self, target, entry.value, entry.is_default);
    }
}
