const std = @import("std");
const resolver_mod = @import("../resolve/resolver.zig");
const intern_pool_mod = @import("intern_pool.zig");
const value_mod = @import("value.zig");

const InternPool = intern_pool_mod.InternPool;
const Value = value_mod.Value;
const NumberPool = value_mod.NumberPool;
const ColorPool = value_mod.ColorPool;

pub const ResolverEvalTestEnv = struct {
    alloc: std.mem.Allocator,
    module_id: u32,
    pool_ptr: *InternPool,
    color_pool_ptr: *ColorPool,
    resolved_modules: []const resolver_mod.ResolvedProgram,
    config_seeds: []const resolver_mod.ConfigSeed,
    static_eval_lists: []const []const Value,
    /// stage 2 pool: number placeholder (no-op) for passing the API.
    number_pool_storage: NumberPool = .empty,
    list_meta_pool_storage: value_mod.ListMetaPool = .empty,
    string_flags_pool_storage: value_mod.StringFlagsPool = .empty,
    callable_payload_pool_storage: value_mod.CallablePayloadPool = .empty,

    pub fn allocator(self: *const ResolverEvalTestEnv) std.mem.Allocator {
        return self.alloc;
    }

    /// uniform interface: test env has a single alloc (test allocator).
    pub fn poolAlloc(self: *const ResolverEvalTestEnv) std.mem.Allocator {
        return self.alloc;
    }

    pub fn colorAllocator(self: *const ResolverEvalTestEnv) std.mem.Allocator {
        return self.alloc;
    }

    pub fn pool(self: *const ResolverEvalTestEnv) *InternPool {
        return self.pool_ptr;
    }

    pub fn numberPool(self: *ResolverEvalTestEnv) *NumberPool {
        return &self.number_pool_storage;
    }

    pub fn listMetaPool(self: *ResolverEvalTestEnv) *value_mod.ListMetaPool {
        return &self.list_meta_pool_storage;
    }

    pub fn stringFlagsPool(self: *ResolverEvalTestEnv) *value_mod.StringFlagsPool {
        return &self.string_flags_pool_storage;
    }

    pub fn callablePayloadPool(self: *ResolverEvalTestEnv) *value_mod.CallablePayloadPool {
        return &self.callable_payload_pool_storage;
    }

    pub fn colorPool(self: *const ResolverEvalTestEnv) ?*ColorPool {
        return self.color_pool_ptr;
    }

    pub fn lookupVar(self: *const ResolverEvalTestEnv, slot: resolver_mod.SlotId) ?Value {
        if (self.module_id >= self.resolved_modules.len) return null;
        return lookupResolvedStaticSlotValue(&self.resolved_modules[self.module_id], slot);
    }

    pub fn lookupCrossVar(self: *const ResolverEvalTestEnv, module_id: u32, slot: resolver_mod.SlotId) ?Value {
        if (lookupConfigSeedValue(self.config_seeds, module_id, slot)) |value| return value;
        if (module_id >= self.resolved_modules.len) return null;
        return lookupResolvedStaticSlotValue(&self.resolved_modules[module_id], slot);
    }

    pub fn getStaticList(self: *const ResolverEvalTestEnv, handle: value_mod.ListHandle) ?[]const Value {
        const idx: usize = @intCast(handle);
        if (idx >= self.static_eval_lists.len) return null;
        return self.static_eval_lists[idx];
    }

    pub fn getStaticListPool(self: *const ResolverEvalTestEnv) []const []const Value {
        return self.static_eval_lists;
    }

    pub fn pushStaticList(
        _: *const ResolverEvalTestEnv,
        _: []const Value,
        _: value_mod.ListSeparator,
        _: bool,
        _: bool,
        _: bool,
    ) !Value {
        return error.OutOfMemory;
    }
};

fn lookupResolvedStaticSlotValue(resolved: *const resolver_mod.ResolvedProgram, slot: resolver_mod.SlotId) ?Value {
    for (resolved.static_slot_values.items) |entry| {
        if (entry.slot == slot) return entry.value;
    }
    return null;
}

fn lookupConfigSeedValue(
    config_seeds: []const resolver_mod.ConfigSeed,
    module_id: u32,
    slot: resolver_mod.SlotId,
) ?Value {
    for (config_seeds) |seed| {
        if (seed.module_id == module_id and seed.slot == slot) return seed.value;
    }
    return null;
}
