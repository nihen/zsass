const std = @import("std");
const ast_flat = @import("../frontend/ast_flat.zig");
const intern_pool_mod = @import("../runtime/intern_pool.zig");
const data = @import("data.zig");

const InternPool = intern_pool_mod.InternPool;
const InternId = intern_pool_mod.InternId;
const NodeIndex = ast_flat.NodeIndex;
const ExtraIndex = ast_flat.ExtraIndex;
const Span = data.Span;

pub fn astTextNodeHasInterpolation(ast: *const ast_flat.Ast, node: NodeIndex) bool {
    const n = ast.getNode(node);
    return switch (n.tag) {
        .expr_string_interp => true,
        .expr_interp => true,
        .expr_text_template => blk: {
            const off: ExtraIndex = n.payload;
            const part_count = ast.getExtraU32(off);
            var p: ExtraIndex = off + 1;
            var i: u32 = 0;
            while (i < part_count) : (i += 1) {
                if (ast.getExtraU32(p) != 0) break :blk true;
                p += 2;
            }
            break :blk false;
        },
        .expr_unquoted_ident => std.mem.indexOf(u8, ast.source[n.span_start..n.span_end], "#{") != null,
        .expr_string_literal => false,
        else => false,
    };
}

pub fn astTextNodeStaticText(ast: *const ast_flat.Ast, pool: *InternPool, node: NodeIndex) ?[]const u8 {
    const n = ast.getNode(node);
    return switch (n.tag) {
        .expr_unquoted_ident => pool.get(@enumFromInt(n.payload)),
        .expr_string_literal => pool.get(@enumFromInt(ast.getExtraU32(n.payload))),
        .expr_string_interp => blk: {
            const off: ExtraIndex = n.payload;
            const part_count = ast.getExtraU32(off);
            if (part_count != 1) break :blk null;
            if (ast.getExtraU32(off + 1) != 0) break :blk null;
            break :blk pool.get(@enumFromInt(ast.getExtraU32(off + 2)));
        },
        .expr_text_template => blk: {
            const off: ExtraIndex = n.payload;
            const part_count = ast.getExtraU32(off);
            if (part_count == 0) break :blk "";
            if (part_count != 1) break :blk null;
            if (ast.getExtraU32(off + 1) != 0) break :blk null;
            break :blk pool.get(@enumFromInt(ast.getExtraU32(off + 2)));
        },
        else => null,
    };
}

fn appendAstTextNodeRaw(
    allocator: std.mem.Allocator,
    ast: *const ast_flat.Ast,
    pool: *InternPool,
    node: NodeIndex,
    out: *std.ArrayListUnmanaged(u8),
) !void {
    const n = ast.getNode(node);
    switch (n.tag) {
        .expr_unquoted_ident => try out.appendSlice(allocator, pool.get(@enumFromInt(n.payload))),
        .expr_string_literal => {
            const id: InternId = @enumFromInt(ast.getExtraU32(n.payload));
            try out.appendSlice(allocator, pool.get(id));
        },
        .expr_string_interp => {
            const off: ExtraIndex = n.payload;
            const part_count = ast.getExtraU32(off);
            var p: ExtraIndex = off + 1;
            var i: u32 = 0;
            while (i < part_count) : (i += 1) {
                const kind = ast.getExtraU32(p);
                const val = ast.getExtraU32(p + 1);
                p += 2;
                if (kind == 0) {
                    try out.appendSlice(allocator, pool.get(@enumFromInt(val)));
                } else {
                    const inner: NodeIndex = @enumFromInt(val);
                    const inner_node = ast.getNode(inner);
                    try out.appendSlice(allocator, "#{");
                    try out.appendSlice(allocator, ast.source[inner_node.span_start..inner_node.span_end]);
                    try out.append(allocator, '}');
                }
            }
        },
        .expr_text_template => {
            const off: ExtraIndex = n.payload;
            const part_count = ast.getExtraU32(off);
            var p: ExtraIndex = off + 1;
            var i: u32 = 0;
            while (i < part_count) : (i += 1) {
                const kind = ast.getExtraU32(p);
                const val = ast.getExtraU32(p + 1);
                p += 2;
                if (kind == 0) {
                    try out.appendSlice(allocator, pool.get(@enumFromInt(val)));
                } else {
                    const inner: NodeIndex = @enumFromInt(val);
                    const inner_node = ast.getNode(inner);
                    try out.appendSlice(allocator, "#{");
                    try out.appendSlice(allocator, ast.source[inner_node.span_start..inner_node.span_end]);
                    try out.append(allocator, '}');
                }
            }
        },
        else => {
            if (n.span_start <= n.span_end and n.span_end <= ast.source.len) {
                try out.appendSlice(allocator, ast.source[n.span_start..n.span_end]);
                return;
            }
            return error.SassError;
        },
    }
}

pub fn astTextNodeRawAlloc(
    allocator: std.mem.Allocator,
    ast: *const ast_flat.Ast,
    pool: *InternPool,
    node: NodeIndex,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendAstTextNodeRaw(allocator, ast, pool, node, &buf);
    return try buf.toOwnedSlice(allocator);
}

pub fn readChildList(ast: *const ast_flat.Ast, extra_off: ExtraIndex) []const u32 {
    const count = ast.getExtraU32(extra_off);
    const ptr = ast.extra.items.ptr + extra_off + 1;
    return ptr[0..count];
}

pub fn parseForwardNameList(
    allocator: std.mem.Allocator,
    ast: *const ast_flat.Ast,
    pool: *InternPool,
    extra: u32,
) !?[]const []const u8 {
    if (extra == std.math.maxInt(u32)) return null;
    const count = ast.getExtraU32(extra);
    const out = try allocator.alloc([]const u8, count);
    var q: ExtraIndex = extra + 1;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const id: InternId = @enumFromInt(ast.getExtraU32(q));
        q += 1;
        out[i] = pool.get(id);
    }
    return out;
}

pub fn sourceLineStartAtByte(source: []const u8, byte_pos: u32) u32 {
    var i: usize = @intCast(@min(byte_pos, @as(u32, @intCast(source.len))));
    while (i > 0) : (i -= 1) {
        const c = source[i - 1];
        if (c == '\n' or c == '\r') break;
    }
    return @intCast(i);
}

pub fn buildLineStarts(allocator: std.mem.Allocator, source: []const u8) ![]u32 {
    var nl_count: usize = 1;
    for (source) |c| {
        if (c == '\n') nl_count += 1;
    }
    var out: std.ArrayListUnmanaged(u32) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, nl_count);
    out.appendAssumeCapacity(0);
    for (source, 0..) |c, i| {
        if (c != '\n') continue;
        const next: usize = i + 1;
        if (next > std.math.maxInt(u32)) return error.OutOfMemory;
        out.appendAssumeCapacity(@intCast(next));
    }

    return try out.toOwnedSlice(allocator);
}

pub fn atRuleNameHasInterpolation(source: []const u8, span: Span) bool {
    const raw_name = extractRawAtRuleNameText(source, span) orelse return false;
    return std.mem.indexOf(u8, raw_name, "#{") != null;
}

pub fn extractRawAtRuleNameText(source: []const u8, span: Span) ?[]const u8 {
    const start: usize = @min(source.len, @as(usize, span.start));
    const end: usize = @min(source.len, @as(usize, span.end));
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

pub fn preludeLooksLikeCustomCssFunction(raw: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return std.mem.startsWith(u8, trimmed, "--");
}
