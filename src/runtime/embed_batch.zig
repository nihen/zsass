//! Embedding-friendly batch compile API.
//!
//! `compileFiles` parallelises file compilation using the same shared
//! source / parsed-AST / persistent-resolver caches the CLI uses, but writes
//! results into in-memory `CompileFileResult` records instead of disk. The
//! caller decides what to do with the bytes (write to disk, attach to a
//! bundler response, embed in a build pipeline, etc.).
//!
//! Threading contract:
//!   - The caller's allocator is wrapped in an internal mutex-guarded shim
//!     (`ThreadSafeAlloc`) before being handed to worker threads, so even a
//!     non-thread-safe allocator (e.g. `ArenaAllocator`) is safe to pass.
//!   - Worker threads are joined unconditionally on every exit path,
//!     including mid-spawn failures.

const std = @import("std");

const compiler_mod = @import("../ir/compiler.zig");
const rule_ir_mod = @import("../ir/rule_ir.zig");
const source_map_mod = @import("../ir/source_map.zig");
const vm_mod = @import("vm.zig");
const intern_pool_mod = @import("intern_pool.zig");
const source_cache_mod = @import("../resolve/source_cache.zig");
const ast_cache_mod = @import("../resolve/ast_cache.zig");
const persistent_resolver_mod = @import("../resolve/persistent_resolver.zig");
const perf = @import("perf.zig");
const syntax_override_mod = @import("syntax_override.zig");
const zsass_io = @import("io.zig");
const error_format = @import("error_format.zig");

/// Spin-lock-guarded wrapper around an arbitrary `std.mem.Allocator`. Used so
/// the caller's allocator is safe to share across worker threads even when its
/// own implementation is not (e.g. `ArenaAllocator`, `FixedBufferAllocator`).
///
/// A spin lock is fine here because lock holders only run a single allocator
/// call, and the contention window is the very short worker-spawn handoff.
/// Zig 0.16 dropped the standalone `std.Thread.Mutex`; the io-vtable `Io.Mutex`
/// would force every `Allocator.VTable` callback to thread an `Io` through to
/// the lock - this lightweight wrapper avoids that intrusion.
const ThreadSafeAlloc = struct {
    child: std.mem.Allocator,
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *ThreadSafeAlloc) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *ThreadSafeAlloc) void {
        self.locked.store(false, .release);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ThreadSafeAlloc = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.unlock();
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *ThreadSafeAlloc = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.unlock();
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *ThreadSafeAlloc = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.unlock();
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *ThreadSafeAlloc = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.unlock();
        self.child.rawFree(memory, alignment, ret_addr);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *ThreadSafeAlloc) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

/// Result of compiling one input file. `css` and `source_map_json` are
/// `alloc`-owned (the same allocator that was passed to `compileFiles`).
/// `err` is non-null when the entry failed; `css` and `source_map_json` are
/// then null.
pub const CompileFileResult = struct {
    css: ?[]u8 = null,
    source_map_json: ?[]u8 = null,
    err: ?anyerror = null,
    /// Dart-style rendered diagnostic for `err` (message, inner-most source
    /// frame, and the `@import`/`@use` chain), multi-line, `alloc`-owned.
    /// Null when the entry succeeded, when no diagnostic was captured, or
    /// when allocating the rendered text failed (`err` is still set then).
    err_rendered: ?[]u8 = null,
    /// Error CSS payload for `err` (the rendered diagnostic as a CSS comment
    /// plus a `body::before` rule that displays it on the page), `alloc`-owned.
    /// Callers that write compile output to disk can write this to the
    /// destination on failure to mirror the CLI's `--error-css` behavior.
    /// Null when the entry succeeded or when `err_rendered` is null.
    err_css: ?[]u8 = null,

    pub fn deinit(self: *CompileFileResult, allocator: std.mem.Allocator) void {
        if (self.css) |b| allocator.free(b);
        if (self.source_map_json) |b| allocator.free(b);
        if (self.err_rendered) |b| allocator.free(b);
        if (self.err_css) |b| allocator.free(b);
        self.css = null;
        self.source_map_json = null;
        self.err_rendered = null;
        self.err_css = null;
    }
};

/// Per-batch options shared by every entry in a `compileFiles` call.
pub const CompileFilesOptions = struct {
    /// `.expanded` (default) or `.compressed`.
    output_style: rule_ir_mod.OutputStyle = .expanded,
    /// When true, `result.source_map_json` is populated with Source Map v3 JSON.
    source_map: bool = false,
    /// Suppress `@warn` / `@debug` output (mirrors the CLI `--quiet`).
    quiet: bool = false,
    /// Search roots consulted by `@use` / `@forward` / bare relative `@import`
    /// after the entry's own directory.
    load_paths: []const []const u8 = &.{},
    /// Worker thread count. `0` means "use `std.Thread.getCpuCount()`".
    jobs: usize = 0,
};

/// Compile each path in `paths` and return one `CompileFileResult` per entry,
/// in input order. The result slice and every owned CSS / source-map slice
/// are allocated from `alloc`; the caller is responsible for freeing them via
/// `result.deinit(alloc)` and `alloc.free(results)`.
///
/// Parallel runs share `SharedSourceCache`, `ParsedAstCache`, and
/// `PersistentResolverState` per worker, mirroring the CLI's batch path so
/// vendor `@use` / `@forward` chains are not re-parsed for every entry.
pub fn compileFiles(
    alloc: std.mem.Allocator,
    paths: []const []const u8,
    opts: CompileFilesOptions,
) ![]CompileFileResult {
    var results = try alloc.alloc(CompileFileResult, paths.len);
    errdefer {
        for (results) |*r| r.deinit(alloc);
        alloc.free(results);
    }
    for (results) |*r| r.* = .{};

    if (paths.len == 0) return results;

    var source_cache = source_cache_mod.SharedSourceCache.init(std.heap.c_allocator);
    defer source_cache.deinit();

    const order = try buildOrderByFileSize(alloc, paths);
    defer alloc.free(order);

    if (paths.len == 1) {
        var pool_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer pool_arena.deinit();
        var shared_pool = try intern_pool_mod.InternPool.init(pool_arena.allocator());
        defer shared_pool.deinit(pool_arena.allocator());
        var ast_cache = ast_cache_mod.ParsedAstCache.init(std.heap.c_allocator, &shared_pool);
        defer ast_cache.deinit();
        var persistent_state = persistent_resolver_mod.PersistentResolverState.init(
            std.heap.c_allocator,
            &shared_pool,
            &source_cache,
            &ast_cache,
        );
        defer persistent_state.deinit();
        var work_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer work_arena.deinit();
        compileOnePath(
            alloc,
            work_arena.allocator(),
            paths[0],
            opts,
            &shared_pool,
            &source_cache,
            &ast_cache,
            &persistent_state,
            &results[0],
        );
        return results;
    }

    const cpu_count = std.Thread.getCpuCount() catch 4;
    const requested = if (opts.jobs == 0) cpu_count else opts.jobs;
    const worker_count = @min(paths.len, requested);

    var ts_alloc = ThreadSafeAlloc{ .child = alloc };
    const safe_alloc = ts_alloc.allocator();

    const Shared = struct {
        alloc: std.mem.Allocator,
        paths: []const []const u8,
        order: []const usize,
        opts: CompileFilesOptions,
        source_cache: *source_cache_mod.SharedSourceCache,
        results: []CompileFileResult,
        // Snapshot of the caller thread's syntax override; each worker
        // copies it into its own thread-local slot at spawn time so the
        // parser / resolver pick the same syntax decision the CLI made.
        syntax_override: ?syntax_override_mod.SyntaxOverride,
        next_index: usize = 0,
        mutex: std.Io.Mutex = .init,
        stop: bool = false,
    };

    var shared: Shared = .{
        .alloc = safe_alloc,
        .paths = paths,
        .order = order,
        .opts = opts,
        .source_cache = &source_cache,
        .results = results,
        .syntax_override = syntax_override_mod.get(),
    };

    const threads = try alloc.alloc(std.Thread, worker_count);
    defer alloc.free(threads);

    var started: usize = 0;
    errdefer {
        // Spawn loop bailed mid-way: signal active threads to stop pulling new
        // slots, then join the ones that already started before our caller
        // unwinds the stack-allocated `shared`.
        shared.mutex.lockUncancelable(zsass_io.io);
        shared.stop = true;
        shared.mutex.unlock(zsass_io.io);
        for (threads[0..started]) |t| t.join();
    }

    for (threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, struct {
            fn run(state: *Shared) void {
                // Each worker has its own thread-local syntax-override
                // slot; copy the caller-thread snapshot in before any
                // parse / resolve work runs on this thread.
                syntax_override_mod.set(state.syntax_override);
                defer perf.flushThread();
                var pool_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
                defer pool_arena.deinit();
                const pool_alloc = pool_arena.allocator();
                var shared_pool = intern_pool_mod.InternPool.init(pool_alloc) catch |err| {
                    failAllRemaining(state, err);
                    return;
                };
                defer shared_pool.deinit(pool_alloc);
                var local_ast_cache = ast_cache_mod.ParsedAstCache.init(std.heap.c_allocator, &shared_pool);
                defer local_ast_cache.deinit();
                var persistent_state = persistent_resolver_mod.PersistentResolverState.init(
                    std.heap.c_allocator,
                    &shared_pool,
                    state.source_cache,
                    &local_ast_cache,
                );
                defer persistent_state.deinit();
                var work_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
                defer work_arena.deinit();

                while (true) {
                    const slot = blk: {
                        state.mutex.lockUncancelable(zsass_io.io);
                        defer state.mutex.unlock(zsass_io.io);
                        if (state.stop or state.next_index >= state.order.len) break :blk null;
                        const idx = state.order[state.next_index];
                        state.next_index += 1;
                        break :blk idx;
                    } orelse return;

                    compileOnePath(
                        state.alloc,
                        work_arena.allocator(),
                        state.paths[slot],
                        state.opts,
                        &shared_pool,
                        state.source_cache,
                        &local_ast_cache,
                        &persistent_state,
                        &state.results[slot],
                    );
                    _ = work_arena.reset(.retain_capacity);
                }
            }

            fn failAllRemaining(state: *Shared, err: anyerror) void {
                state.mutex.lockUncancelable(zsass_io.io);
                defer state.mutex.unlock(zsass_io.io);
                while (state.next_index < state.order.len) {
                    const slot = state.order[state.next_index];
                    state.results[slot].err = err;
                    state.next_index += 1;
                }
            }
        }.run, .{&shared});
        started += 1;
    }

    for (threads) |thread| thread.join();
    return results;
}

fn compileOnePath(
    out_alloc: std.mem.Allocator,
    work_alloc: std.mem.Allocator,
    input_path: []const u8,
    opts: CompileFilesOptions,
    shared_pool: *intern_pool_mod.InternPool,
    source_cache: *source_cache_mod.SharedSourceCache,
    ast_cache: *ast_cache_mod.ParsedAstCache,
    persistent_state: *persistent_resolver_mod.PersistentResolverState,
    out: *CompileFileResult,
) void {
    out.* = .{};
    // Diagnostic state is threadlocal; reset so a previous entry compiled on
    // this worker thread cannot leak its span/stack into this entry's report.
    error_format.clearErrorContext();
    compileOnePathFallible(out_alloc, work_alloc, input_path, opts, shared_pool, source_cache, ast_cache, persistent_state, out) catch |err| {
        if (out.css) |b| {
            out_alloc.free(b);
            out.css = null;
        }
        if (out.source_map_json) |b| {
            out_alloc.free(b);
            out.source_map_json = null;
        }
        out.err = err;
        out.err_rendered = error_format.formatDiagnosticAlloc(out_alloc, err);
        out.err_css = formatErrorCssAlloc(out_alloc, err, input_path, out.err_rendered);
    };
}

/// Error CSS for a failed entry, mirroring the CLI's `--error-css` output.
/// When the resolver captured a stack snapshot the rendered diagnostic
/// already carries the source frame and trace, so wrap that. Otherwise
/// (e.g. a parse error in the entry itself) rebuild the inner-most frame
/// from the recorded span the way the CLI driver does: re-read the entry
/// and feed `writeErrorCssTemplate`. `file_id == 0` means the recorded span
/// belongs to the entry; spans in other modules cannot be resolved to a
/// source here, so those fall back to message + path.
fn formatErrorCssAlloc(
    alloc: std.mem.Allocator,
    err: anyerror,
    input_path: []const u8,
    rendered: ?[]const u8,
) ?[]u8 {
    if (error_format.error_state.error_stack_snapshot_len > 0) {
        if (rendered) |r| return error_format.formatErrorCssFromDiagnosticAlloc(alloc, r);
    }

    const ctx = error_format.error_state.last_error_ctx;
    var source: ?[]u8 = null;
    defer if (source) |s| alloc.free(s);
    var line_starts: ?[]u32 = null;
    defer if (line_starts) |ls| alloc.free(ls);
    if (ctx.has_value and ctx.file_id == 0) {
        source = readFileAlloc(alloc, input_path) catch null;
        if (source) |s| {
            line_starts = error_format.computeLineStarts(alloc, s) catch null;
        }
    }
    const has_frame = line_starts != null;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    error_format.writeErrorCssTemplate(
        &aw.writer,
        err,
        input_path,
        if (has_frame) source else null,
        line_starts,
        ctx.span_start,
        ctx.span_end,
        has_frame,
    ) catch return null;
    return aw.toOwnedSlice() catch null;
}

fn compileOnePathFallible(
    out_alloc: std.mem.Allocator,
    work_alloc: std.mem.Allocator,
    input_path: []const u8,
    opts: CompileFilesOptions,
    shared_pool: *intern_pool_mod.InternPool,
    source_cache: *source_cache_mod.SharedSourceCache,
    ast_cache: *ast_cache_mod.ParsedAstCache,
    persistent_state: *persistent_resolver_mod.PersistentResolverState,
    out: *CompileFileResult,
) !void {
    const source = try readFileAlloc(work_alloc, input_path);

    var deprecation_opts: @import("deprecation.zig").DeprecationOpts = .{};
    deprecation_opts.quiet = opts.quiet;

    const persistent_ctx = persistent_state.compileContext();
    var borrowed = try compiler_mod.parseResolveCompileWithPoolPhaseTimerCachesAndPersistent(
        work_alloc,
        source,
        input_path,
        opts.load_paths,
        null,
        shared_pool,
        source_cache,
        ast_cache,
        persistent_ctx,
        &deprecation_opts,
        null,
    );
    defer {
        if (!borrowed.borrowed_color_pool) borrowed.color_pool.deinit(work_alloc);
        borrowed.resolved.deinit();
        borrowed.program.deinit();
    }

    var rule_ir = rule_ir_mod.RuleIR.init();
    defer rule_ir.deinit(work_alloc);

    var vm = try vm_mod.VM.init(work_alloc, shared_pool, &borrowed.color_pool, &rule_ir, &borrowed.program);
    defer vm.deinit();
    vm.deprecation_opts = deprecation_opts;
    // Stream chunk flush keeps VM emit memory bounded when source maps are off
    // (mirrors driver.runEnd2EndWithPool's behavior for the no-sourcemap path).
    if (!opts.source_map) {
        vm.configureStreamChunkFlush(true, 1024) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    try vm_mod.VM.runTop(&vm);

    const source_locations = try work_alloc.alloc(rule_ir_mod.SourceLocation, borrowed.program.modules.len);
    for (borrowed.program.modules, 0..) |mod, idx| {
        source_locations[idx] = .{
            .source_path = mod.module_path,
            .line_starts = mod.line_starts,
            .source_len = mod.source_len,
        };
    }

    var sm: ?source_map_mod.SourceMap = null;
    defer if (sm) |*m| m.deinit();
    if (opts.source_map) sm = source_map_mod.SourceMap.init(work_alloc);

    var aw = std.Io.Writer.Allocating.init(out_alloc);
    defer aw.deinit();
    const sm_ptr: ?*source_map_mod.SourceMap = if (sm) |*m| m else null;
    try rule_ir.writeToWithSourceMap(&aw.writer, shared_pool, sm_ptr, source_locations, opts.output_style, .{});
    out.css = try aw.toOwnedSlice();

    if (sm) |*m| {
        out.source_map_json = try m.toJsonAlloc(out_alloc);
    }
}

fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(zsass_io.io, path, .{});
    defer file.close(zsass_io.io);
    var rb: [4096]u8 = undefined;
    var rd = file.reader(zsass_io.io, &rb);
    return try rd.interface.allocRemaining(alloc, .limited(1 << 29));
}

/// Order entries by descending file size for better load balancing across
/// workers (large files start early, leaving smaller fillers for the tail).
/// Mirrors the CLI driver's `buildJobOrderByFileSize`.
fn buildOrderByFileSize(alloc: std.mem.Allocator, paths: []const []const u8) ![]usize {
    const Weighted = struct { index: usize, size: u64 };
    const weighted = try alloc.alloc(Weighted, paths.len);
    defer alloc.free(weighted);
    for (paths, 0..) |path, idx| {
        const st = std.Io.Dir.cwd().statFile(zsass_io.io, path, .{}) catch null;
        weighted[idx] = .{
            .index = idx,
            .size = if (st) |stat| stat.size else 0,
        };
    }
    std.mem.sort(Weighted, weighted, {}, struct {
        fn lessThan(_: void, a: Weighted, b: Weighted) bool {
            if (a.size == b.size) return a.index < b.index;
            return a.size > b.size;
        }
    }.lessThan);
    const order = try alloc.alloc(usize, paths.len);
    for (weighted, 0..) |entry, i| order[i] = entry.index;
    return order;
}
