const std = @import("std");
const data_mod = @import("data.zig");
const origin_mod = @import("../runtime/origin.zig");

const ModuleResolver = data_mod.ModuleResolver;
const ModuleRecord = data_mod.ModuleRecord;
const ModuleExports = data_mod.ModuleExports;
const CssOrigin = origin_mod.CssOrigin;
const OriginId = origin_mod.OriginId;

/// Point records / id_by_path / import_origins to inline storage (single-entry/non-persistent).
/// Must be called after alloc in structure literal (records_ptr / id_by_path_ptr / import_origins_ptr are undefined).
pub fn bindRecordsToSelf(self: *ModuleResolver) void {
    self.records_ptr = &self.records_storage;
    self.id_by_path_ptr = &self.id_by_path_storage;
    self.import_origins_ptr = &self.import_origins_storage;
    self.records_owned = true;
}

/// Point records / id_by_path / import_origins to persistent state owned storage.
/// Assuming that records_alloc is also switched to persistent_alloc.
pub fn bindRecordsToPersistent(
    self: *ModuleResolver,
    records: *std.ArrayListUnmanaged(ModuleRecord),
    id_by_path: *std.StringHashMapUnmanaged(u32),
    import_origins: *std.ArrayListUnmanaged(CssOrigin),
) void {
    self.records_ptr = records;
    self.id_by_path_ptr = id_by_path;
    self.import_origins_ptr = import_origins;
    self.records_owned = false;
}

pub fn deinitAll(self: *ModuleResolver) void {
    if (self.records_owned) {
        for (self.records_ptr.items) |*r| {
            r.exports.deinit(self.records_alloc);
            r.prog.deinit();
        }
        self.records_ptr.deinit(self.records_alloc);
        self.id_by_path_ptr.deinit(self.records_alloc);
        self.import_origins_ptr.deinit(self.records_alloc);
    }
    self.visiting.deinit(self.meta);
    self.config_seed_accum.deinit(self.meta);
    self.static_eval_store.deinit();
    if (self.owns_shared_value_pools) {
        self.shared_value_pools.deinit(self.shared_value_pools_alloc);
        self.shared_value_pools_alloc.destroy(self.shared_value_pools);
        self.owns_shared_value_pools = false;
    }
}

pub fn appendImportOrigin(self: *ModuleResolver, source_path: []const u8, parent_import_origin: OriginId) error{OutOfMemory}!OriginId {
    const owned_path = try self.records_alloc.dupe(u8, source_path);
    const idx_u32: u32 = @intCast(self.import_origins_ptr.items.len);
    try self.import_origins_ptr.append(self.records_alloc, .{
        .kind = .import_stylesheet,
        .source_path = owned_path,
        .module_id = std.math.maxInt(u32),
        .parent_import_origin = parent_import_origin,
    });
    return @fromBackingInt(@intCast(idx_u32));
}

pub fn isVisiting(self: *const ModuleResolver, path: []const u8) bool {
    for (self.visiting.items) |p| {
        if (std.mem.eql(u8, p, path)) return true;
    }
    return false;
}
