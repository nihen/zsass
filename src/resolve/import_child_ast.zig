const std = @import("std");
const ast_flat = @import("../frontend/ast_flat.zig");
const lexer_mod = @import("../frontend/lexer.zig");
const parser_mod = @import("../frontend/parser.zig");
const intern_pool_mod = @import("../runtime/intern_pool.zig");
const path_resolution = @import("path_resolution.zig");
const source_cache_mod = @import("source_cache.zig");
const ast_cache_mod = @import("ast_cache.zig");
const resource_budget = @import("../runtime/resource_budget.zig");

const InternPool = intern_pool_mod.InternPool;

pub const LoadImportChildAstError = error{ OutOfMemory, IoFailure, SyntaxError } || resource_budget.LimitError;

fn parseFailure(err: anyerror) LoadImportChildAstError {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (resource_budget.isLimitError(err)) return @errorCast(err);
    return error.SyntaxError;
}

pub const ImportChildAst = struct {
    source: []const u8,
    loaded: path_resolution.LoadedModuleSource,
    scratch: std.heap.ArenaAllocator,
    owned_ast: ?ast_flat.Ast = null,
    borrowed_ast: ?*const ast_flat.Ast = null,

    pub fn astPtr(self: *const ImportChildAst) *const ast_flat.Ast {
        if (self.borrowed_ast) |ast| return ast;
        return &self.owned_ast.?;
    }

    pub fn deinit(self: *ImportChildAst, allocator: std.mem.Allocator) void {
        // owned_ast allocations live in scratch; deinitializing scratch releases them.
        self.scratch.deinit();
        self.loaded.deinit(allocator);
        self.* = undefined;
    }
};

pub fn loadImportChildAst(
    allocator: std.mem.Allocator,
    pool: *InternPool,
    source_cache: ?*source_cache_mod.SharedSourceCache,
    ast_cache: ?*ast_cache_mod.ParsedAstCache,
    path: []const u8,
    budget: ?*resource_budget.ResourceBudget,
) LoadImportChildAstError!ImportChildAst {
    var loaded = path_resolution.loadModuleSource(allocator, source_cache, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.IoFailure,
    };
    errdefer loaded.deinit(allocator);
    const source = loaded.source;
    if (budget) |b| try b.checkSourceBytes(source.len);
    const max_syntax_depth = if (budget) |b| b.limits.max_syntax_depth else resource_budget.default_max_syntax_depth;

    var scratch = std.heap.ArenaAllocator.init(allocator);
    errdefer scratch.deinit();
    const sa = scratch.allocator();

    if (ast_cache) |ac| {
        const entry = ac.getOrParse(path, source, max_syntax_depth) catch |err| return parseFailure(err);
        return .{
            .source = source,
            .loaded = loaded,
            .scratch = scratch,
            .owned_ast = null,
            .borrowed_ast = &entry.ast,
        };
    }

    const is_indented_syntax = std.mem.endsWith(u8, path, ".sass");
    const is_plain_css_source = std.mem.endsWith(u8, path, ".css");
    var lexer = if (is_plain_css_source)
        lexer_mod.Lexer.initPlainCss(sa, source)
    else
        lexer_mod.Lexer.init(sa, source);
    lexer.is_indented_syntax = is_indented_syntax;
    defer lexer.deinit();
    const tokens = lexer.tokenize() catch return error.SyntaxError;
    var parser = parser_mod.Parser.init(sa, pool, tokens, source);
    parser.is_indented_syntax = is_indented_syntax;
    parser.is_plain_css = is_plain_css_source;
    parser.no_interpolation = !lexer.saw_interpolation;
    parser.max_syntax_depth = max_syntax_depth;
    defer parser.deinit();
    var ast = parser.parse() catch |err| return parseFailure(err);
    ast.is_indented_syntax = is_indented_syntax;
    errdefer ast.deinit();

    return .{
        .source = source,
        .loaded = loaded,
        .scratch = scratch,
        .owned_ast = ast,
        .borrowed_ast = null,
    };
}
