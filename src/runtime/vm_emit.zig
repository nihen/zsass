const std = @import("std");
const intern_pool_mod = @import("intern_pool.zig");
const origin_mod = @import("origin.zig");

const InternId = intern_pool_mod.InternId;
const OriginId = origin_mod.OriginId;

/// The nest_depth of rule_ir is available in u8, but the usage on the writer side is `nest_depth != 0`
/// bool test only. When it reaches 256 steps or more, silent wrap becomes 0 and hoisted rule
/// Perform a saturation cast to avoid fallback blank from firing accidentally.
inline fn saturateNestDepth(depth: usize) u8 {
    return std.math.cast(u8, depth) orelse std.math.maxInt(u8);
}

/// Used in dart-sass's re-emit pattern. From the beginning of the top chunk of module M
/// Append consecutive emit_comments to rule_ir. enter_frame / emit_stmt_gap
/// / nop is skip. Stops at first non-preamble inst.
pub fn emitModulePreambleComments(self: anytype, module_id: u32) !void {
    if (module_id >= self.program.modules.len) return;
    const chunk = &self.program.modules[module_id].top;
    for (chunk.code) |inst| {
        switch (inst.opcode()) {
            .enter_frame, .emit_stmt_gap, .nop => continue,
            .emit_comment => {
                const text_id: InternId = @enumFromInt(inst.arg_b);
                try self.rule_ir.appendComment(
                    self.allocator,
                    text_id,
                    self.currentSourceSpan(),
                );
            },
            else => return,
        }
    }
}

pub fn emitImportOriginPreamble(self: anytype, origin: origin_mod.CssOrigin) !void {
    for (origin.preamble_comment_ids) |comment_id| {
        try self.rule_ir.appendComment(
            self.allocator,
            @enumFromInt(comment_id),
            self.currentSourceSpan(),
        );
    }
}

pub fn emitOriginPreamble(self: anytype, origin_id: OriginId) !void {
    if (!origin_id.isValid()) return;
    const origin_idx = @intFromEnum(origin_id);
    if (origin_idx >= self.program.origins.len) return;
    const origin = self.program.origins[origin_idx];
    switch (origin.kind) {
        .root => {},
        .module => try emitModulePreambleComments(self, origin.module_id),
        .import_stylesheet => try emitImportOriginPreamble(self, origin),
    }
}

/// If trailing-empty-scope is detected in the previous `emit_stmt_gap` and stmt_gap is suppressed,
/// Set the `suppress_leading_blank` flag in the subsequent rule_begin / at_rule_begin to
/// Suppress fallback blank (`indent_level == 0 and nest_depth == 0`). Consumes flag after application.
inline fn applyPendingSuppressNextRuleBeginBlank(self: anytype, new_idx: usize) void {
    if (self.suppress_next_rule_begin_blank) {
        self.rule_ir.setSuppressLeadingBlankAt(new_idx, true);
        self.suppress_next_rule_begin_blank = false;
    }
}

pub fn appendCurrentRuleBegin(self: anytype, suppress_top_level_blank: bool) !void {
    if (self.selector_stack.items.len == 0) return error.InternalError;
    const selector_id = self.selector_stack.items[self.selector_stack.items.len - 1];
    // selector_stack is stacked with parent scopes including itself. Parent scope number (= after unnest
    // nest depth) to the writer, even for rules hoisted to top-level with unnest.
    // Assign nest_depth > 0 to prevent false firing of fallback blank on the writer side.
    const parent_depth: usize = self.selector_stack.items.len - 1;
    const nest_depth: u8 = if (suppress_top_level_blank and parent_depth == 0)
        1
    else
        saturateNestDepth(parent_depth);
    try self.rule_ir.appendRuleBegin(
        self.allocator,
        @intFromEnum(selector_id),
        nest_depth,
        self.currentSelectorOwnerSpan(),
    );
    const new_idx = self.rule_ir.nodes.items.len - 1;
    applyPendingSuppressNextRuleBeginBlank(self, new_idx);
    // Z10-SAMESEL: This rule_begin is "reopen" (parent rule is split with nested inner rule)
    // resume after retrieval, @include bounds, @at-root reversion, etc.) or push_selector_scope
    // Distinguish whether it is a new user-written rule immediately after. User-written immediately after a direct push.
    if (self.suppress_next_origin_reopen) {
        self.suppress_next_origin_reopen = false;
    } else if (!self.just_pushed_selector_scope) {
        self.rule_ir.setOriginReopenAt(new_idx, true);
    }
    // emitted within @at-root scope (push_at_root_scope and before pop_at_root_scope)
    // rule_begin is treated as hoisted. In adjacent merge judgment, reopen immediately after hoisted block is
    // Do not merge. A hoisted rule is treated as an escape from its parent rule, so
    // On the writer side, "blank suppression with previous rule + blank enforcement with next non-hoisted rule"
    // To achieve this, suppress_leading_blank is also set here (Z23-MEDIA).
    if (self.at_root_saved_selector_frames.items.len > 0) {
        self.rule_ir.setOriginAtRootHoistedAt(new_idx, true);
        self.rule_ir.setSuppressLeadingBlankAt(new_idx, true);
    }
    self.open_rule_depth += 1;
    try self.open_rule_selector_depth_stack.append(self.allocator, @intCast(self.selector_stack.items.len));
    self.open_block_depth += 1;
}

pub fn openCurrentRuleBlock(self: anytype, maybe: bool, suppress_top_level_blank: bool) !void {
    if (!maybe) {
        try appendCurrentRuleBegin(self, suppress_top_level_blank);
        return;
    }
    const should_open = blk: {
        const current_depth = self.selector_stack.items.len;
        if (current_depth == 0) break :blk false;
        if (self.open_rule_selector_depth_stack.items.len == 0) break :blk true;
        const open_depth = self.open_rule_selector_depth_stack.items[self.open_rule_selector_depth_stack.items.len - 1];
        if (open_depth == current_depth) break :blk false;
        if (open_depth < current_depth) break :blk true;
        break :blk self.open_rule_depth < current_depth;
    };
    try self.maybe_current_rule_stack.append(
        self.allocator,
        if (should_open) .open else .inactive,
    );
    if (!should_open) return;
    try appendCurrentRuleBegin(self, suppress_top_level_blank);
}

pub fn emitCommentWithRuleWrap(self: anytype, text_id: InternId, source_col: u32, leading_same_line: bool) !void {
    const need_wrap = self.selector_stack.items.len > 0 and
        self.open_rule_depth == 0 and
        !self.load_css_strict_top_level;
    if (need_wrap) {
        const selector_id = self.selector_stack.items[self.selector_stack.items.len - 1];
        const parent_depth: usize = self.selector_stack.items.len - 1;
        try self.rule_ir.appendRuleBegin(
            self.allocator,
            @intFromEnum(selector_id),
            saturateNestDepth(parent_depth),
            self.currentSelectorOwnerSpan(),
        );
        const begin_idx = self.rule_ir.nodes.items.len - 1;
        self.rule_ir.setOriginReopenAt(begin_idx, true);
        // This wrapper is a continuation of the current nested parent, not a
        // fresh top-level source rule.  Source stmt gaps before the comment
        // are indentation structure inside the parent and must not become a
        // top-level blank before the reopened parent comment block.
        self.rule_ir.setSuppressLeadingBlankAt(begin_idx, true);
        applyPendingSuppressNextRuleBeginBlank(self, begin_idx);
        if (self.at_root_saved_selector_frames.items.len > 0) {
            self.rule_ir.setOriginAtRootHoistedAt(begin_idx, true);
            self.rule_ir.setSuppressLeadingBlankAt(begin_idx, true);
        }
    }
    try self.rule_ir.appendCommentWithColAndLeading(self.allocator, text_id, self.currentSourceSpan(), source_col, leading_same_line);
    if (need_wrap) {
        try self.rule_ir.appendRuleEnd(self.allocator, self.currentSourceSpan());
    }
}
