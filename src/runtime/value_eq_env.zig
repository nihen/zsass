const std = @import("std");
const intern_pool_mod = @import("intern_pool.zig");
const value_mod = @import("value.zig");

const InternPool = intern_pool_mod.InternPool;
const Value = value_mod.Value;
const NumberPool = value_mod.NumberPool;
const ColorPool = value_mod.ColorPool;

pub const RuntimeValueEqEnv = struct {
    alloc: std.mem.Allocator,
    pool_ptr: *InternPool,
    number_pool_ptr: *NumberPool,
    list_meta_pool_ptr: *value_mod.ListMetaPool,
    string_flags_pool_ptr: *value_mod.StringFlagsPool,
    callable_payload_pool_ptr: *value_mod.CallablePayloadPool,
    color_pool_ptr: *const ColorPool,
    list_pool_ptr: *const std.ArrayListUnmanaged([]Value),

    pub fn allocator(self: *const RuntimeValueEqEnv) std.mem.Allocator {
        return self.alloc;
    }

    pub fn pool(self: *const RuntimeValueEqEnv) *InternPool {
        return self.pool_ptr;
    }

    pub fn numberPool(self: *const RuntimeValueEqEnv) *NumberPool {
        return self.number_pool_ptr;
    }

    pub fn listMetaPool(self: *const RuntimeValueEqEnv) *value_mod.ListMetaPool {
        return self.list_meta_pool_ptr;
    }

    pub fn stringFlagsPool(self: *const RuntimeValueEqEnv) *value_mod.StringFlagsPool {
        return self.string_flags_pool_ptr;
    }

    pub fn callablePayloadPool(self: *const RuntimeValueEqEnv) *value_mod.CallablePayloadPool {
        return self.callable_payload_pool_ptr;
    }

    pub fn colorPool(self: *const RuntimeValueEqEnv) ?*const ColorPool {
        return self.color_pool_ptr;
    }

    pub fn getStaticList(self: *const RuntimeValueEqEnv, handle: value_mod.ListHandle) ?[]const Value {
        const idx: usize = @intCast(handle);
        if (idx >= self.list_pool_ptr.items.len) return null;
        return self.list_pool_ptr.items[idx];
    }
};
