//! Parsed AST cache over worker for Multi-entry CLI.
//!
//! For large multi-entry compilations (hundreds of entries sharing vendor
//! modules), common vendor `@use` / `@forward` / `@import` chains
//! (compass / fontawesome etc.) are reused across entries. SharedSourceCache
//! shares disk reads but lex/parse is re-executed per entry, and the profile
//! Top `lexer.tokenize 2.60%` + `parser.parseUnaryOrAtom 1.07%` + related alloc of gap
//! occupies a part. Has a mechanism equivalent to legacy zsass's `ImportCaches.stylesheets`.
//!
//! Design:
//! - `Entry` is a heap alloc (stable pointer). It has a **per-entry arena** inside and there
//! Alloc all AST nodes / extra / const_pool. ast.source is also duplicated to the same arena
//! Borrow what was created (parse_source is after sass syntax conversion / plain css etc.
//! (may differ from original). Now `*const Ast` borrow when cache hit is
//! Valid for cache lifetime.
//! - Mutex protects only map operations (lookup/insert). AST in entry is immutable and
//! Read concurrently from multiple workers.
//! - In the case of cache miss, lex/parse is done **outside of lock**, and lock is taken again when storing.
//! Existing check (discards own Entry when racing).
//! Scale without degenerating because it does not exceed cpu_count.
//!
//! Handoff rejected trial "per-worker parsed module AST cache" is heap-stable
//! I proceeded to Entry, but segfaulted in multi-entry suites. This implementation is (1) Entry
//! Strict ownership of internal arena, switch ast.source to dup within the same arena, (2) source_path
//! Only intern_id comes from shared InternPool, so it is valid beyond worker, (3) caller (resolver)
//! side does not receive **Ast by value copy, but eliminates race by borrowing `*const Ast`**.
const std = @import("std");
const ast_flat = @import("../frontend/ast_flat.zig");
const lexer_mod = @import("../frontend/lexer.zig");
const parser_mod = @import("../frontend/parser.zig");
const intern_pool_mod = @import("../runtime/intern_pool.zig");
const zsass_io = @import("../runtime/io.zig");

const InternPool = intern_pool_mod.InternPool;

pub const Entry = struct {
    /// Arena that holds AST + parse_source. Deinited when Entry is destroyed.
    arena: *std.heap.ArenaAllocator,
    ast: ast_flat.Ast,

    fn destroy(self: *Entry, parent_alloc: std.mem.Allocator) void {
        self.arena.deinit();
        parent_alloc.destroy(self.arena);
        parent_alloc.destroy(self);
    }
};

pub const ParsedAstCache = struct {
    mutex: std.Io.Mutex = .init,
    map: std.StringHashMapUnmanaged(*Entry) = .empty,
    /// Allocator that holds the key (path string) and Entry pointer. Usually worker pool
    /// Pass a long-lived allocator (such as `std.heap.c_allocator`) that lives beyond.
    alloc: std.mem.Allocator,
    /// shared intern pool. Used to resolve ast's source_path intern.
    pool: *InternPool,

    pub fn init(allocator: std.mem.Allocator, pool: *InternPool) ParsedAstCache {
        return .{ .alloc = allocator, .pool = pool };
    }

    pub fn deinit(self: *ParsedAstCache) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            entry.value_ptr.*.destroy(self.alloc);
        }
        self.map.deinit(self.alloc);
    }

    /// Returns the parsed AST corresponding to path. Existing Entry pointer if cache hit, if miss
    /// Parse `source` to create Entry, store it in cache, and return pointer.
    /// The return value is valid for the lifetime of the cache. AST in Entry is only for immutable read (resolver is
    /// Do not mutate AST).
    pub fn getOrParse(
        self: *ParsedAstCache,
        path: []const u8,
        source: []const u8,
    ) !*const Entry {
        {
            self.mutex.lockUncancelable(zsass_io.io);
            defer self.mutex.unlock(zsass_io.io);
            if (self.map.get(path)) |hit| return hit;
        }

        // Execute parse outside lock. The arena of entry is heap allocated and is owned by Entry.
        const arena = try self.alloc.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(self.alloc);
        errdefer {
            arena.deinit();
            self.alloc.destroy(arena);
        }
        const a = arena.allocator();

        const is_indented_syntax = std.mem.endsWith(u8, path, ".sass");
        const is_plain_css = std.mem.endsWith(u8, path, ".css");
        const parse_source = try a.dupe(u8, source);

        var lexer = if (is_plain_css)
            lexer_mod.Lexer.initPlainCss(a, parse_source)
        else
            lexer_mod.Lexer.init(a, parse_source);
        lexer.source_name = path;
        lexer.is_indented_syntax = is_indented_syntax;
        defer lexer.deinit();
        const tokens = try lexer.tokenize();

        var parser = parser_mod.Parser.init(a, self.pool, tokens, parse_source);
        parser.is_indented_syntax = is_indented_syntax;
        parser.no_interpolation = !lexer.saw_interpolation;
        defer parser.deinit();
        var ast = try parser.parse();
        ast.is_indented_syntax = is_indented_syntax;
        // parser/lexer's defer deinit frees internal alloc on arena, but
        // ast's own nodes / extra / const_pool remain in arena (deinit is not called).

        const entry = try self.alloc.create(Entry);
        errdefer self.alloc.destroy(entry);
        entry.* = .{ .arena = arena, .ast = ast };

        const key = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(key);

        self.mutex.lockUncancelable(zsass_io.io);
        defer self.mutex.unlock(zsass_io.io);

        if (self.map.get(path)) |hit| {
            // race: another worker parsed first. Discard your entry.
            self.alloc.free(key);
            entry.destroy(self.alloc);
            return hit;
        }
        try self.map.put(self.alloc, key, entry);
        return entry;
    }
};
