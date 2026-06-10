const std = @import("std");

const perf = @import("../runtime/perf.zig");
const lexer_mod = @import("../frontend/lexer.zig");
const parser_mod = @import("../frontend/parser.zig");
const ast_flat = @import("../frontend/ast_flat.zig");
const data = @import("data.zig");
const module_resolver_state = @import("module_resolver_state.zig");
const path_resolution = @import("path_resolution.zig");

const ModuleResolver = data.ModuleResolver;
const ResolveError = data.ResolveError;

const isVisiting = module_resolver_state.isVisiting;
const loadModuleSource = path_resolution.loadModuleSource;
const resolveUserModulePath = path_resolution.resolveUserModulePath;

pub const ResolveParsedModuleFn = *const fn (*ModuleResolver, *const ast_flat.Ast, []const u8) ResolveError!u32;

fn resolveParsedWithPendingInitialConfig(
    self: *ModuleResolver,
    ast: *const ast_flat.Ast,
    resolved: []const u8,
    resolve_parsed: ResolveParsedModuleFn,
) ResolveError!u32 {
    const saved_active_config = self.active_initial_config_entries;
    const active_config = self.pending_next_config_entries;
    self.pending_next_config_entries = &.{};
    self.active_initial_config_entries = active_config;
    defer self.active_initial_config_entries = saved_active_config;

    return resolve_parsed(self, ast, resolved);
}

pub fn resolveEntryAst(self: *ModuleResolver, ast: *const ast_flat.Ast, entry_path: []const u8, resolve_parsed: ResolveParsedModuleFn) ResolveError!u32 {
    const canonical = std.fs.path.resolve(self.alloc, &.{entry_path}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer self.alloc.free(canonical);
    return resolve_parsed(self, ast, canonical);
}

pub fn resolveUserModule(self: *ModuleResolver, from_path: []const u8, url: []const u8, resolve_parsed: ResolveParsedModuleFn) ResolveError!u32 {
    if (url.len == 0) return error.UsermodulePathEmpty;
    const t_path = perf.timeBegin();
    const resolved_raw = resolveUserModulePath(self.alloc, from_path, url, self.load_paths, .{ .pkg_importer_enabled = self.pkg_importer_enabled }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    } orelse return error.UsermoduleNotFound;
    defer self.alloc.free(resolved_raw);
    const resolved = std.fs.path.resolve(self.alloc, &.{resolved_raw}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer self.alloc.free(resolved);
    perf.timeEnd(.resolve_path_lookup_ns, t_path);
    if (self.id_by_path_ptr.get(resolved)) |id| {
        perf.note(.resolve_record_hit);
        return id;
    }
    perf.note(.resolve_record_miss);
    if (isVisiting(self, resolved)) return error.UsermoduleCircular;

    // When ast_cache hit: borrow parsed AST and go straight to resolve (lex/parse skip).
    // Ast_cache side dupes parse_source into arena, so the source passed here is
    // It is enough to survive until the function return.
    if (self.ast_cache) |ac| {
        var source_for_cache = loadModuleSource(self.alloc, self.source_cache, resolved) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.UsermoduleIoFailure,
        };
        defer source_for_cache.deinit(self.alloc);
        const entry = ac.getOrParse(resolved, source_for_cache.source) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SyntaxError => return error.UsermoduleLexFailure,
            else => return error.UsermoduleParseFailure,
        };
        if (entry.ast.getNode(entry.ast.root).tag != .stylesheet_root) return error.UsermoduleRootMismatch;
        return resolveParsedWithPendingInitialConfig(self, &entry.ast, resolved, resolve_parsed);
    }

    var loaded = loadModuleSource(self.alloc, self.source_cache, resolved) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.UsermoduleIoFailure,
    };
    defer loaded.deinit(self.alloc);
    const source = loaded.source;

    var scratch = std.heap.ArenaAllocator.init(self.alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const is_indented_syntax = std.mem.endsWith(u8, resolved, ".sass");
    const is_plain_css_source = std.mem.endsWith(u8, resolved, ".css");
    var lexer = if (is_plain_css_source)
        lexer_mod.Lexer.initPlainCss(sa, source)
    else
        lexer_mod.Lexer.init(sa, source);
    lexer.source_name = resolved;
    lexer.is_indented_syntax = is_indented_syntax;
    defer lexer.deinit();
    const tokens = lexer.tokenize() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => {
            lexer.printLastErrorDiagnostic("UsermoduleLexFailure");
            return error.UsermoduleLexFailure;
        },
    };
    var parser = parser_mod.Parser.init(sa, self.pool, tokens, source);
    parser.is_indented_syntax = is_indented_syntax;
    parser.no_interpolation = !lexer.saw_interpolation;
    defer parser.deinit();
    var ast = parser.parse() catch return error.UsermoduleParseFailure;
    ast.is_indented_syntax = is_indented_syntax;
    defer ast.deinit();
    if (ast.getNode(ast.root).tag != .stylesheet_root) return error.UsermoduleRootMismatch;

    return resolveParsedWithPendingInitialConfig(self, &ast, resolved, resolve_parsed);
}
