const std = @import("std");

const ast_flat = @import("../frontend/ast_flat.zig");
const intern_pool_mod = @import("../runtime/intern_pool.zig");

const AstNode = ast_flat.AstNode;
const ExtraIndex = ast_flat.ExtraIndex;
const InternId = intern_pool_mod.InternId;
const InternPool = intern_pool_mod.InternPool;

/// Returns whether a top-level statement may appear before or among Sass module
/// directives without locking the module-directive preamble.
pub fn topLevelStmtKeepsModuleDirectiveOpen(ast: *const ast_flat.Ast, pool: *const InternPool, n: AstNode) bool {
    return switch (n.tag) {
        .stmt_comment,
        .stmt_variable_decl,
        .stmt_use,
        .stmt_forward,
        .stmt_import,
        .stmt_mixin_decl,
        .stmt_function_decl,
        => true,
        .stmt_at_rule => topLevelAtRuleKeepsModuleDirectiveOpen(ast, pool, n),
        else => false,
    };
}

fn topLevelAtRuleKeepsModuleDirectiveOpen(ast: *const ast_flat.Ast, pool: *const InternPool, n: AstNode) bool {
    if (n.tag != .stmt_at_rule) return false;

    const off: ExtraIndex = n.payload;
    const name_id: InternId = @enumFromInt(ast.getExtraU32(off));
    const raw_name = extractRawAtRuleNameText(ast.source, n.span_start, n.span_end) orelse pool.get(name_id);
    if (std.mem.indexOf(u8, raw_name, "#{") != null) return false;
    return cssIdentEquals(atRuleNameRaw(raw_name), "charset");
}

fn extractRawAtRuleNameText(source: []const u8, span_start: u32, span_end: u32) ?[]const u8 {
    const start: usize = @min(source.len, @as(usize, span_start));
    const end: usize = @min(source.len, @as(usize, span_end));
    if (end <= start) return null;
    const raw = source[start..end];
    const at_idx = std.mem.indexOfScalar(u8, raw, '@') orelse return null;
    var p: usize = at_idx + 1;
    while (p < raw.len and (raw[p] == ' ' or raw[p] == '\t')) : (p += 1) {}
    if (p >= raw.len) return null;

    var q: usize = p;
    var interp_depth: usize = 0;
    while (q < raw.len) {
        const c = raw[q];
        if (interp_depth == 0) {
            if (c == '#' and q + 1 < raw.len and raw[q + 1] == '{') {
                interp_depth = 1;
                q += 2;
                continue;
            }
            if (std.ascii.isWhitespace(c) or c == '{' or c == ';') break;
        } else {
            if (c == '{') {
                interp_depth += 1;
            } else if (c == '}') {
                interp_depth -= 1;
            }
        }
        q += 1;
    }
    return raw[p..q];
}

fn cssIdentEquals(name: []const u8, expected_lower: []const u8) bool {
    if (name.len != expected_lower.len) return false;
    for (name, expected_lower) |raw, want| {
        var c = raw;
        if (c == '_') c = '-';
        if (std.ascii.toLower(c) != want) return false;
    }
    return true;
}

fn atRuleNameRaw(name: []const u8) []const u8 {
    return if (name.len > 0 and name[0] == '@') name[1..] else name;
}
