const std = @import("std");
const data_mod = @import("data.zig");
const origin_mod = @import("../runtime/origin.zig");

const ModuleResolver = data_mod.ModuleResolver;
const ResolvedProgram = data_mod.ResolvedProgram;
const StmtIndex = data_mod.StmtIndex;
const OriginId = origin_mod.OriginId;

const PreambleError = error{ OutOfMemory, InternalError };

fn collectCommentInternIds(
    prog: *const ResolvedProgram,
    allocator: std.mem.Allocator,
    stmts: []const StmtIndex,
) PreambleError![]const u32 {
    const out = try allocator.alloc(u32, stmts.len);
    errdefer allocator.free(out);
    var i: usize = 0;
    for (stmts) |si| {
        const st = prog.stmts.items[si];
        if (st.kind != .comment) return error.InternalError;
        out[i] = @intFromEnum(prog.comment_stmts.items[st.payload].text_intern);
        i += 1;
    }
    return out;
}

pub fn recordImportPreambleComments(
    prog: *const ResolvedProgram,
    loader: *ModuleResolver,
    import_origin_id: OriginId,
    expanded_top: []const StmtIndex,
) PreambleError!void {
    if (expanded_top.len == 0) return;
    const origin_index = @intFromEnum(import_origin_id);
    if (origin_index >= loader.import_origins_ptr.items.len) return;

    var preamble_count: usize = 0;
    while (preamble_count < expanded_top.len) : (preamble_count += 1) {
        const si = expanded_top[preamble_count];
        if (prog.stmts.items[si].kind != .comment) break;
    }
    if (preamble_count == 0) return;

    const origin = &loader.import_origins_ptr.items[origin_index];
    // import_origins is retained across entries in cross-entry persistent mode, so
    // preamble_comment_ids is also allocated with long-lived records_alloc.
    origin.preamble_comment_ids = try collectCommentInternIds(
        prog,
        loader.records_alloc,
        expanded_top[0..preamble_count],
    );
}

pub fn adjustModuleStyleImportPreamble(
    allocator: std.mem.Allocator,
    prog: *const ResolvedProgram,
    expanded_top: *std.ArrayListUnmanaged(StmtIndex),
    fresh_load: bool,
) PreambleError!void {
    if (expanded_top.items.len == 0) return;

    // From the beginning of expanded_top:
    // leading_comment_end: first non-comment and non-noop stmt
    // module_dep_block_end: end of subsequent consecutive module_dep
    var leading_comment_end: usize = 0;
    var saw_any_leading_comment = false;
    while (leading_comment_end < expanded_top.items.len) {
        const si = expanded_top.items[leading_comment_end];
        const k = prog.stmts.items[si].kind;
        if (k == .comment) {
            saw_any_leading_comment = true;
            leading_comment_end += 1;
        } else if (k == .noop) {
            leading_comment_end += 1;
        } else break;
    }
    if (!saw_any_leading_comment) return;

    // Find module_dep block range (consecutive module_dep + noop after leading_comment_end).
    var module_dep_block_end: usize = leading_comment_end;
    var saw_any_module_dep = false;
    while (module_dep_block_end < expanded_top.items.len) {
        const si = expanded_top.items[module_dep_block_end];
        const k = prog.stmts.items[si].kind;
        if (k == .module_dep) {
            saw_any_module_dep = true;
            module_dep_block_end += 1;
        } else if (k == .noop) {
            module_dep_block_end += 1;
        } else break;
    }
    if (!saw_any_module_dep) return;

    if (fresh_load) {
        // Drop leading preamble comments.
        var write: usize = 0;
        var read: usize = 0;
        while (read < expanded_top.items.len) : (read += 1) {
            const si = expanded_top.items[read];
            const k = prog.stmts.items[si].kind;
            if (read < leading_comment_end and k == .comment) continue;
            expanded_top.items[write] = si;
            write += 1;
        }
        expanded_top.shrinkRetainingCapacity(write);
        return;
    }

    // Move leading preamble comments after the module_dep block:
    // [comments][module_deps][rest] -> [module_deps][comments][rest].
    const comments_count = blk: {
        var c: usize = 0;
        for (expanded_top.items[0..leading_comment_end]) |si| {
            if (prog.stmts.items[si].kind == .comment) c += 1;
        }
        break :blk c;
    };
    if (comments_count == 0) return;

    var saved_comments = std.ArrayList(StmtIndex).empty;
    defer saved_comments.deinit(allocator);
    try saved_comments.ensureTotalCapacity(allocator, comments_count);
    for (expanded_top.items[0..leading_comment_end]) |si| {
        if (prog.stmts.items[si].kind == .comment) {
            saved_comments.appendAssumeCapacity(si);
        }
    }

    var rebuilt = std.ArrayList(StmtIndex).empty;
    defer rebuilt.deinit(allocator);
    try rebuilt.ensureTotalCapacity(allocator, expanded_top.items.len);
    for (expanded_top.items[0..leading_comment_end]) |si| {
        if (prog.stmts.items[si].kind != .comment) {
            rebuilt.appendAssumeCapacity(si);
        }
    }
    for (expanded_top.items[leading_comment_end..module_dep_block_end]) |si| {
        rebuilt.appendAssumeCapacity(si);
    }
    for (saved_comments.items) |si| rebuilt.appendAssumeCapacity(si);
    for (expanded_top.items[module_dep_block_end..]) |si| {
        rebuilt.appendAssumeCapacity(si);
    }
    expanded_top.clearRetainingCapacity();
    try expanded_top.appendSlice(allocator, rebuilt.items);
}
