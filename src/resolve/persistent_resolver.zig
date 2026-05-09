//!Per-worker persistent state for cross-entry resolve/compile artifact reuse.
//!
//!In a multi-entry CLI run, all entries often `@use` the same vendor modules.
//!This corresponds to the increase in wall time, which is mainly caused by re-running fresh resolve+compile.
//!Design details: `.plans/ideal/20260502-cross-entry-resolve-reuse-design.md`
//!
//!Option C adopted: bundle.modules is a sparse array containing all persistent records.
//!However, modules that are not reachable from root are specified by reachable_mask in VM prologue.
//!Skip. byte code/records continues to use global module_id (no renumber required).

const std = @import("std");

const intern_pool_mod = @import("../runtime/intern_pool.zig");
const value_mod = @import("../runtime/value.zig");
const origin_mod = @import("../runtime/origin.zig");
const source_cache_mod = @import("source_cache.zig");
const ast_cache_mod = @import("ast_cache.zig");
const resolver_mod = @import("resolver.zig");
const compiler_mod = @import("../ir/compiler.zig");

pub const PersistentResolverState = struct {
    /// Long-lived allocator (typically c_allocator). backing of records_arena.
    alloc: std.mem.Allocator,
    /// Shared InternPool (one per worker; cross-worker sharing is not allowed).
    pool: *intern_pool_mod.InternPool,
    /// Shared source byte cache (reserved by driver in per-worker pool).
    source_cache: *source_cache_mod.SharedSourceCache,
    /// Shared parsed AST cache (per-worker).
    ast_cache: *ast_cache_mod.ParsedAstCache,

    /// records array / id_by_path map / related key string / alloc in ModuleExports /
    /// All import_origins / static_eval list copies are allocated from this arena. worker thread
    /// It is retained for the lifetime of , and is released all at once on deinit.
    records_arena: std.heap.ArenaAllocator,
    /// Resolve results that are append-only accumulated in cross-entry. module_id is in records.items
    /// 0-base index. Persistent across entries.
    records: std.ArrayListUnmanaged(resolver_mod.ModuleRecord) = .empty,
    /// module_id in canonical path  ->  records. appended in parallel with records.
    id_by_path: std.StringHashMapUnmanaged(u32) = .empty,
    /// The list literal pool referenced by the resolved expression in records. list handle in byte code is
    /// append-only is required across entries to reference this index. Share with records.
    /// Individual fields are accessed using helper on resolver.zig side (StaticEvalListStore type is
    /// resolver.zig is private, so here it has ArrayList directly).
    static_eval_lists: std.ArrayListUnmanaged([]const value_mod.Value) = .empty,
    /// import_origins is also shared because it is referenced by OriginId from the byte code of records.
    /// Source_path / preamble_comment_ids of CssOrigin also alloc in records_arena.
    import_origins: std.ArrayListUnmanaged(origin_mod.CssOrigin) = .empty,
    /// Since the color literal of ResolvedExpr in records holds the pool index, ColorPool is also
    /// If not shared, color index will be invalidated across entries (panic: p32 OOB).
    /// ColorPool itself uses its own allocator instead of records_arena (pool internal implementation).
    color_pool: value_mod.ColorPool = .empty,
    /// Static-eval Value sidecar pool shared storage (P4 c3 retry A.2). All modules
    /// Pointed to by ResolvedProgram.value_*_pool. append-only across entry.
    /// alloc backend is self.alloc (long-lived) and freed with deinit.
    shared_value_pools: resolver_mod.SharedValuePoolStorage = .{},

    /// Step 6: Cross-entry reuse of compile chunks. ResolvedProgram of records[i] is
    /// Since it is immutable, the results (ModuleChunks) once compiled can be used in other entries.
    /// Sorted with the same index as records (sparse: null = not compiled / no compile required).
    /// slice (code / const_pool / etc.) inside chunks allocs from compile_arena.
    compiled_chunks: std.ArrayListUnmanaged(?compiler_mod.ModuleChunks) = .empty,
    /// Long-lived arena (alloc backed) for internal data of ModuleChunks in compiled_chunks.
    compile_arena: std.heap.ArenaAllocator,

    pub fn init(
        alloc: std.mem.Allocator,
        pool: *intern_pool_mod.InternPool,
        source_cache: *source_cache_mod.SharedSourceCache,
        ast_cache: *ast_cache_mod.ParsedAstCache,
    ) PersistentResolverState {
        return .{
            .alloc = alloc,
            .pool = pool,
            .source_cache = source_cache,
            .ast_cache = ast_cache,
            .records_arena = std.heap.ArenaAllocator.init(alloc),
            .compile_arena = std.heap.ArenaAllocator.init(alloc),
        };
    }

    pub fn resolveContext(self: *PersistentResolverState) resolver_mod.PersistentResolveContext {
        return .{
            .alloc = self.alloc,
            .records_arena = &self.records_arena,
            .records = &self.records,
            .id_by_path = &self.id_by_path,
            .static_eval_lists = &self.static_eval_lists,
            .import_origins = &self.import_origins,
            .shared_value_pools = &self.shared_value_pools,
        };
    }

    pub fn compileContext(self: *PersistentResolverState) compiler_mod.PersistentCompileContext {
        return .{
            .resolve_ctx = self.resolveContext(),
            .color_pool = &self.color_pool,
            .alloc = self.alloc,
            .compiled_chunks = &self.compiled_chunks,
            .compile_arena = self.compile_arena.allocator(),
        };
    }

    pub fn deinit(self: *PersistentResolverState) void {
        //ResolvedProgram has its own arena, so separate deinit is required.
        //(ResolvedProgram uses external memory that is not freed by records_arena.deinit().
        //(Because it is managed by its own arena).
        for (self.records.items) |*r| {
            r.prog.deinit();
        }
        //exports / records / id_by_path / static_eval_lists / import_origins is
        //Since it is allocated from records_arena, no need for individual deinit.
        self.records_arena.deinit();
        //The data in compiled_chunks is allocated from compile_arena, so it is released all at once.
        self.compile_arena.deinit();
        //ColorPool is ArrayListUnmanaged and uses external alloc, so deinit it individually.
        self.color_pool.deinit(self.alloc);
        //shared_value_pools is a group of ArrayListUnmanaged with self.alloc as backend.
        self.shared_value_pools.deinit(self.alloc);
    }
};
