const std = @import("std");
const zsass_io = @import("../runtime/io.zig");
const module_mod = @import("module.zig");
const source_cache_mod = @import("source_cache.zig");

/// Starting from the specified `base_abs` (absolute path that has already been joined & resolved),
/// Try candidates in the following order: `.scss` / `_prefix.scss` partial / `_index.scss` index / `.sass`.
/// If found, return the absolute path with alloc (caller is free). If not found, null.
/// `has_ext` depends on whether the url ends with `.scss` / `.sass`, and only in that case base_abs is
/// Directly (without prefix) Add candidates to try first.
pub fn resolveUserModulePath(
    alloc: std.mem.Allocator,
    from_path: []const u8,
    url: []const u8,
    load_paths: []const []const u8,
    resolve_opts: module_mod.ResolveOptions,
) !?[]const u8 {
    // @use/@forward and runtime meta.load-css allow `.css` fallback.
    return resolveUserModulePathWithPolicy(alloc, from_path, url, load_paths, true, resolve_opts);
}

fn isSassStylesheetPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".scss") or std.mem.endsWith(u8, path, ".sass");
}

pub fn isPlainCssStylesheetPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".css");
}

fn resolveUserModulePathWithPolicy(
    alloc: std.mem.Allocator,
    from_path: []const u8,
    url: []const u8,
    load_paths: []const []const u8,
    allow_plain_css: bool,
    resolve_opts: module_mod.ResolveOptions,
) !?[]const u8 {
    // Use `module.zig::resolveUrl()` as a single resolution path.
    // `<stdin>` call + synthetic load-path overlay of explicit relative (`../x`)
    // Absorb zsass-specific edges here.
    const resolved_opt = module_mod.resolveUrl(alloc, url, from_path, load_paths, resolve_opts) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.AmbiguousImport => return null,
    };
    if (resolved_opt) |resolved| {
        if (isSassStylesheetPath(resolved.path) or (allow_plain_css and isPlainCssStylesheetPath(resolved.path))) {
            return resolved.path;
        }
        var drop = resolved;
        drop.deinit();
    }
    return null;
}

pub fn resolveImportModulePathWithPolicy(
    alloc: std.mem.Allocator,
    from_path: []const u8,
    url: []const u8,
    load_paths: []const []const u8,
    allow_plain_css: bool,
    resolve_opts: module_mod.ResolveOptions,
) !?[]const u8 {
    const resolved_opt = module_mod.resolveImportUrl(alloc, url, from_path, load_paths, resolve_opts) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.AmbiguousImport => return null,
    };
    if (resolved_opt) |resolved| {
        if (isSassStylesheetPath(resolved.path) or (allow_plain_css and isPlainCssStylesheetPath(resolved.path))) {
            return resolved.path;
        }
        var drop = resolved;
        drop.deinit();
    }
    return null;
}

pub const test_only_path_resolver = struct {
    pub fn resolveSassModulePathOnly(
        alloc: std.mem.Allocator,
        from_path: []const u8,
        url: []const u8,
        load_paths: []const []const u8,
    ) !?[]const u8 {
        return resolveUserModulePathWithPolicy(alloc, from_path, url, load_paths, false, .{});
    }

    pub fn resolveSassImportPathOnly(
        alloc: std.mem.Allocator,
        from_path: []const u8,
        url: []const u8,
        load_paths: []const []const u8,
    ) !?[]const u8 {
        return resolveImportModulePathWithPolicy(alloc, from_path, url, load_paths, false, .{});
    }
};

fn readFileToStringAlloc(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(zsass_io.io, path, .{});
    defer file.close(zsass_io.io);
    var rb: [8192]u8 = undefined;
    var rd = file.reader(zsass_io.io, &rb);
    return try rd.interface.allocRemaining(allocator, .limited(1 << 29));
}

/// Loader results that distinguish between borrowed (cache hit) and owned (cache miss / no cache) results.
/// caller can be safely freed with `defer .deinit(alloc)`.
pub const LoadedModuleSource = struct {
    source: []const u8,
    owned: bool,

    pub fn deinit(self: *LoadedModuleSource, alloc: std.mem.Allocator) void {
        if (self.owned) alloc.free(self.source);
        self.* = .{ .source = &.{}, .owned = false };
    }
};

pub fn loadModuleSource(
    alloc: std.mem.Allocator,
    cache: ?*source_cache_mod.SharedSourceCache,
    path: []const u8,
) !LoadedModuleSource {
    if (cache) |sc| {
        return .{ .source = try sc.getOrLoad(path), .owned = false };
    }
    return .{ .source = try readFileToStringAlloc(alloc, path), .owned = true };
}
