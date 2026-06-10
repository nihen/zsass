//! Cross-entry module global-state cache.
//!
//! In a multi-entry batch, many entries `@use` the same vendor modules
//! (bulma, material-web, ...). A module whose top chunk is
//! `cross_entry_pure_top` (no CSS-affecting work of its own) produces the
//! same module-global end state on every entry of the batch, so its top
//! execution can be replayed from a snapshot instead of re-run.
//!
//! The cache is per-worker (no locking) and lives alongside
//! PersistentResolverState: it is only enabled when the persistent
//! resolve/compile reuse is, because that is what guarantees a stable
//! module structure (slot layout, color pool) across entries.
//!
//! Values are stored in cache-local pools: lists are deep-copied,
//! unit-bearing numbers and colors are re-pooled by value (number/color
//! pools are per-VM / shallow-copied per entry, so raw handles do not
//! survive entry boundaries). Strings are InternIds in the worker-shared
//! InternPool and travel as-is. Values that cannot be re-materialized
//! (callables, calc/interp fragments) or that carry list sidecar state
//! (slash-preserve, arglist keywords, source shapes) disqualify the whole
//! module snapshot -- the module is simply re-run, never half-restored.

const std = @import("std");
const value_mod = @import("value.zig");

const Value = value_mod.Value;

pub const SavedModuleState = struct {
    values: []Value,
    declared: []bool,
};

pub const CrossEntryModuleStates = struct {
    allocator: std.mem.Allocator,
    /// module_path -> snapshot of module-global slots after top execution.
    map: std.StringHashMapUnmanaged(SavedModuleState) = .empty,
    /// Cache-local storage backing list values inside snapshots.
    list_pool: std.ArrayListUnmanaged([]Value) = .empty,
    /// Cache-local storage backing unit-bearing numbers inside snapshots.
    number_pool: value_mod.NumberPool = .empty,
    /// Cache-local storage backing colors inside snapshots.
    color_pool: value_mod.ColorPool = .empty,

    pub fn init(allocator: std.mem.Allocator) CrossEntryModuleStates {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CrossEntryModuleStates) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.values);
            self.allocator.free(entry.value_ptr.declared);
        }
        self.map.deinit(self.allocator);
        for (self.list_pool.items) |row| self.allocator.free(row);
        self.list_pool.deinit(self.allocator);
        self.number_pool.deinit(self.allocator);
        self.color_pool.deinit(self.allocator);
        self.* = undefined;
    }
};
