const std = @import("std");

const value_mod = @import("../runtime/value.zig");
const origin_mod = @import("../runtime/origin.zig");
const data = @import("data.zig");
const perf = @import("../runtime/perf.zig");

const ConfigSeed = data.ConfigSeed;
const CssOrigin = origin_mod.CssOrigin;
const ModuleResolver = data.ModuleResolver;
const ResolvedBundle = data.ResolvedBundle;
const ResolvedProgram = data.ResolvedProgram;
const ResolveError = data.ResolveError;

const unpackConfigSeedKey = data.unpackConfigSeedKey;

fn copyStaticEvalLists(allocator: std.mem.Allocator, lists: []const []const value_mod.Value) ![]const []const value_mod.Value {
    if (lists.len == 0) return &.{};
    const owned = try allocator.alloc([]const value_mod.Value, lists.len);
    for (lists, 0..) |items, i| {
        owned[i] = items;
    }
    return owned;
}

/// Flat-buffer view of copied import origins. The `origins` slice references
/// `path_bytes` / `id_bytes`; freeing requires releasing all three slices.
pub const CopiedOrigins = struct {
    origins: []CssOrigin,
    path_bytes: []u8,
    id_bytes: []u32,
};

/// Copy `origins` into bundle-owned storage.
///
/// Source paths and preamble-comment-id arrays are concatenated into single
/// flat buffers (`path_bytes` / `id_bytes`); each `CssOrigin.source_path` /
/// `preamble_comment_ids` is then a borrowed slice into that buffer. This
/// replaces the previous per-element `dupe` with three bulk allocations and
/// lets `ResolvedBundle.deinit` free everything in three `free` calls.
fn copyOrigins(allocator: std.mem.Allocator, origins: []const CssOrigin) !CopiedOrigins {
    if (origins.len == 0) return .{ .origins = &.{}, .path_bytes = &.{}, .id_bytes = &.{} };

    var path_total: usize = 0;
    var id_total: usize = 0;
    for (origins) |o| {
        path_total += o.source_path.len;
        id_total += o.preamble_comment_ids.len;
    }

    const path_bytes: []u8 = if (path_total == 0)
        &.{}
    else
        try allocator.alloc(u8, path_total);
    errdefer if (path_total != 0) allocator.free(path_bytes);
    const id_bytes: []u32 = if (id_total == 0)
        &.{}
    else
        try allocator.alloc(u32, id_total);
    errdefer if (id_total != 0) allocator.free(id_bytes);

    const out = try allocator.alloc(CssOrigin, origins.len);
    errdefer allocator.free(out);

    var path_cursor: usize = 0;
    var id_cursor: usize = 0;
    for (origins, 0..) |origin, i| {
        const path_end = path_cursor + origin.source_path.len;
        @memcpy(path_bytes[path_cursor..path_end], origin.source_path);
        const path_slice = path_bytes[path_cursor..path_end];
        path_cursor = path_end;

        const ids_slice: []const u32 = if (origin.preamble_comment_ids.len == 0)
            &.{}
        else blk: {
            const id_end = id_cursor + origin.preamble_comment_ids.len;
            @memcpy(id_bytes[id_cursor..id_end], origin.preamble_comment_ids);
            const s = id_bytes[id_cursor..id_end];
            id_cursor = id_end;
            break :blk s;
        };

        out[i] = .{
            .kind = origin.kind,
            .source_path = path_slice,
            .module_id = origin.module_id,
            .parent_import_origin = origin.parent_import_origin,
            .preamble_comment_ids = ids_slice,
        };
    }
    return .{ .origins = out, .path_bytes = path_bytes, .id_bytes = id_bytes };
}

pub fn buildResolvedBundleFromResolver(
    allocator: std.mem.Allocator,
    mr: *ModuleResolver,
    root_id: u32,
) ResolveError!ResolvedBundle {
    const t_total = perf.timeBegin();
    defer perf.timeEnd(.bundle_total_ns, t_total);

    const t_modules = perf.timeBegin();
    const modules = try allocator.alloc(ResolvedProgram, mr.records_ptr.items.len);
    errdefer allocator.free(modules);
    for (mr.records_ptr.items, 0..) |*r, i| {
        modules[i] = r.prog;
    }
    perf.bump(.bundle_modules_copy_ns, modules.len * @sizeOf(ResolvedProgram));
    perf.timeEnd(.bundle_modules_copy_ns, t_modules);

    // Plan C: Since bundle.modules contains all cumulative records in cross-entry persistent mode,
    // Build a mask to skip compile / VM prologue for modules that are not reachable from root.
    // BFS resolve-time dep information (module_dep_stmts / forward_rules / use_map / cross_var_refs).
    const t_reach = perf.timeBegin();
    const reachable_mask = try buildReachableMaskFromResolved(allocator, modules, root_id);
    errdefer allocator.free(reachable_mask);
    perf.timeEnd(.bundle_reachable_ns, t_reach);

    const t_order = perf.timeBegin();
    const module_extend_group_order = try buildExtendGroupOrderFromResolved(allocator, modules, root_id);
    errdefer allocator.free(module_extend_group_order);
    perf.timeEnd(.bundle_extend_order_ns, t_order);

    const t_seeds = perf.timeBegin();
    var config_seeds = try allocator.alloc(ConfigSeed, mr.config_seed_accum.count());
    errdefer if (config_seeds.len != 0) allocator.free(config_seeds);
    var si: usize = 0;
    var sit = mr.config_seed_accum.iterator();
    while (sit.next()) |entry| {
        const unpacked = unpackConfigSeedKey(entry.key_ptr.*);
        const acc = entry.value_ptr.*;
        const effective = if (acc.explicit_set and acc.explicit_value.kind() != .nil)
            acc.explicit_value
        else if (acc.default_set)
            acc.default_value
        else if (acc.explicit_set)
            acc.explicit_value
        else
            continue;
        config_seeds[si] = .{
            .module_id = unpacked.module_id,
            .slot = unpacked.slot,
            .value = effective,
        };
        si += 1;
    }
    if (si < config_seeds.len) {
        config_seeds = try allocator.realloc(config_seeds, si);
    }
    perf.timeEnd(.bundle_config_seeds_ns, t_seeds);

    const t_lists = perf.timeBegin();
    const static_eval_lists = try copyStaticEvalLists(allocator, mr.static_eval_store.lists.items);
    errdefer if (static_eval_lists.len != 0) allocator.free(static_eval_lists);
    perf.timeEnd(.bundle_static_lists_ns, t_lists);

    const t_origins = perf.timeBegin();
    const copied_origins = try copyOrigins(allocator, mr.import_origins_ptr.items);
    perf.timeEnd(.bundle_origins_ns, t_origins);
    errdefer {
        if (copied_origins.origins.len != 0) allocator.free(copied_origins.origins);
        if (copied_origins.path_bytes.len != 0) allocator.free(copied_origins.path_bytes);
        if (copied_origins.id_bytes.len != 0) allocator.free(copied_origins.id_bytes);
    }

    return .{
        .modules = modules,
        .root_index = root_id,
        .import_origins = copied_origins.origins,
        .import_origin_path_bytes = copied_origins.path_bytes,
        .import_origin_id_bytes = copied_origins.id_bytes,
        .config_seeds = config_seeds,
        .static_eval_lists = static_eval_lists,
        .alloc = allocator,
        .reachable_mask = reachable_mask,
        .module_extend_group_order = module_extend_group_order,
        // shared pool ownership / pointer is set by caller (resolve*Impl) on success path
        // Overwrite. Here, we just transcribed the MR value for plumbing.
        .shared_value_pools = mr.shared_value_pools,
        .shared_value_pools_alloc = mr.shared_value_pools_alloc,
        .owns_shared_value_pools = false,
    };
}

/// Depth-first post-order numbering over `module_dep_stmts` from the entry
/// root, visiting dependencies in statement order with first-visit dedup.
/// This mirrors how a fresh single-entry resolve appends module records, so
/// in non-persistent mode the resulting ordinal order equals the module id
/// order. Modules never referenced by a dependency statement (unreachable
/// records of earlier entries, or modules only referenced for variable
/// lookup) stay at maxInt(u32); they never execute top-level code and thus
/// never record @extend relations.
fn buildExtendGroupOrderFromResolved(
    allocator: std.mem.Allocator,
    modules: []const ResolvedProgram,
    root_id: u32,
) ResolveError![]u32 {
    const n = modules.len;
    const order = try allocator.alloc(u32, n);
    errdefer allocator.free(order);
    @memset(order, std.math.maxInt(u32));
    if (n == 0 or root_id >= n) return order;

    const visited = try allocator.alloc(bool, n);
    defer allocator.free(visited);
    @memset(visited, false);

    const Frame = struct { module: u32, dep_idx: usize };
    var stack: std.ArrayListUnmanaged(Frame) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, .{ .module = root_id, .dep_idx = 0 });
    visited[root_id] = true;

    var next_order: u32 = 0;
    while (stack.items.len > 0) {
        const frame = &stack.items[stack.items.len - 1];
        const deps = modules[frame.module].module_dep_stmts.items;
        if (frame.dep_idx < deps.len) {
            const dep = deps[frame.dep_idx].module_id;
            frame.dep_idx += 1;
            if (dep < n and !visited[dep]) {
                visited[dep] = true;
                try stack.append(allocator, .{ .module = dep, .dep_idx = 0 });
            }
            continue;
        }
        order[frame.module] = next_order;
        if (next_order != std.math.maxInt(u32)) next_order += 1;
        _ = stack.pop();
    }
    return order;
}

/// Follow ResolvedProgram.module_dep_stmts / forward_rules / use_map / cross_var_refs
/// Returns a bool array of modules reachable from root (allocated on allocator).
/// When bundle.modules contains all cumulative records in cross-entry persistent mode,
/// Used by root to skip unrelated previous entry modules from VM prologue / compile.
fn buildReachableMaskFromResolved(
    allocator: std.mem.Allocator,
    modules: []const ResolvedProgram,
    root_id: u32,
) ResolveError![]bool {
    const n = modules.len;
    const mask = try allocator.alloc(bool, n);
    errdefer allocator.free(mask);
    @memset(mask, false);
    if (n == 0) return mask;
    if (root_id >= n) return mask;

    var stack: std.ArrayListUnmanaged(u32) = .empty;
    defer stack.deinit(allocator);
    try stack.ensureTotalCapacity(allocator, n);
    stack.appendAssumeCapacity(root_id);
    mask[root_id] = true;

    while (stack.pop()) |cur| {
        const m = &modules[cur];
        // module_dep_stmts: run_dependency dep that @use / @forward / @import emit.
        // Equivalent to VM reachability (run_dependency opcode follow).
        for (m.module_dep_stmts.items) |d| {
            if (d.module_id < n and !mask[d.module_id]) {
                mask[d.module_id] = true;
                try stack.append(allocator, d.module_id);
            }
        }
        // use_map: @use namespace bindings (user_module variant).
        // Used in load_mod_global / load_mod_global_strict routes.
        var uit = m.use_map.iterator();
        while (uit.next()) |entry| {
            switch (entry.value_ptr.*) {
                .user_module => |mid| {
                    if (mid < n and !mask[mid]) {
                        mask[mid] = true;
                        try stack.append(allocator, mid);
                    }
                },
                .builtin_module => {},
            }
        }
        // cross_var_refs: cross-module static var lookup target module.
        for (m.cross_var_refs.items) |c| {
            if (c.module_id < n and !mask[c.module_id]) {
                mask[c.module_id] = true;
                try stack.append(allocator, c.module_id);
            }
        }
    }
    return mask;
}
