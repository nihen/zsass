const std = @import("std");
const selector_mod = @import("../selector/selector.zig");
const value_mod = @import("value.zig");
const intern_pool_mod = @import("intern_pool.zig");

const InternId = intern_pool_mod.InternId;
const Value = value_mod.Value;

fn allTopLevelItemsRepeatParent(sel: []const u8, parent: []const u8) bool {
    if (parent.len == 0) return false;
    var paren_depth: u32 = 0;
    var bracket_depth: u32 = 0;
    var in_string: u8 = 0;
    var item_start: usize = 0;
    var has_item = false;
    var i: usize = 0;
    while (i < sel.len) : (i += 1) {
        const c = sel[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < sel.len) {
                i += 1;
                continue;
            }
            if (c == in_string) in_string = 0;
            continue;
        }
        switch (c) {
            '"', '\'' => in_string = c,
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => if (bracket_depth > 0) {
                bracket_depth -= 1;
            },
            ',' => if (paren_depth == 0 and bracket_depth == 0) {
                const item = std.mem.trim(u8, sel[item_start..i], " \t\r\n");
                if (item.len == 0) return false;
                if (!itemRepeatsParent(item, parent)) return false;
                has_item = true;
                item_start = i + 1;
            },
            else => {},
        }
    }
    const item = std.mem.trim(u8, sel[item_start..], " \t\r\n");
    if (item.len == 0) return has_item;
    if (!itemRepeatsParent(item, parent)) return false;
    return true;
}

fn itemRepeatsParent(item: []const u8, parent: []const u8) bool {
    if (!std.mem.startsWith(u8, item, parent)) return false;
    if (item.len > parent.len and !rawSelectorBoundary(item[parent.len])) return false;

    var search_from = parent.len;
    while (std.mem.indexOfPos(u8, item, search_from, parent)) |pos| {
        const before_ok = pos == 0 or rawSelectorBoundary(item[pos - 1]);
        const after_pos = pos + parent.len;
        const after_ok = after_pos >= item.len or rawSelectorBoundary(item[after_pos]);
        if (before_ok and after_ok) return true;
        search_from = pos + 1;
    }
    return false;
}

fn rawSelectorBoundary(c: u8) bool {
    return !(std.ascii.isAlphanumeric(c) or c == '_' or c == '-');
}

fn selectorParentForCombination(self: anytype, raw_selector: []const u8) ?InternId {
    if (self.currentAtRootParentSelector()) |saved_parent| {
        const keep_len = self.currentAtRootKeepLen() orelse self.selector_prefix_depth;
        if (self.selector_stack.items.len == keep_len) {
            if (std.mem.indexOfScalar(u8, raw_selector, '&') != null) {
                return saved_parent;
            }
            if (keep_len > 0 and keep_len == self.selector_prefix_depth and self.selector_stack.items.len > 0) {
                return self.selector_stack.items[self.selector_stack.items.len - 1];
            }
            return null;
        }
    }
    if (self.selector_stack.items.len == 0) return null;
    const parent_id = self.selector_stack.items[self.selector_stack.items.len - 1];
    const parent_raw = self.intern_pool.get(parent_id);
    if (std.mem.indexOfScalar(u8, raw_selector, '&') == null and
        parent_raw.len != 0 and
        std.mem.indexOfScalar(u8, parent_raw, ',') == null and
        allTopLevelItemsRepeatParent(raw_selector, parent_raw))
    {
        return null;
    }
    return parent_id;
}

fn selectorIsBareParentReference(raw_selector: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, raw_selector, " \t\r\n"), "&");
}

pub fn resolveSelectorInternForStackWithMode(self: anytype, sel_u: u32, mode: anytype) !InternId {
    const raw_id: InternId = try self.ensureInternTrailingEscapeDelimiter(@enumFromInt(sel_u));
    const raw = self.intern_pool.get(raw_id);
    switch (mode) {
        .plain_css_preserve => {
            if (self.selector_prefix_depth > 0 and
                self.selector_stack.items.len == self.selector_prefix_depth and
                self.selector_stack.items.len > 0 and
                std.mem.indexOfScalar(u8, raw, '&') == null)
            {
                const parent_id = self.selector_stack.items[self.selector_stack.items.len - 1];
                const parent_str = self.intern_pool.get(parent_id);
                const combined = try self.combineNestedRuleSelectorForSelectorResolve(parent_str, raw);
                defer self.allocator.free(combined);
                return try self.intern_pool.intern(combined);
            }
            return raw_id;
        },
        .plain_css_combine_parent => {
            if (self.selector_stack.items.len == 0) return raw_id;
            if (std.mem.indexOfScalar(u8, raw, '&') != null) return raw_id;
            const parent_id = self.selector_stack.items[self.selector_stack.items.len - 1];
            const parent_str = self.intern_pool.get(parent_id);
            const combined = try self.combineNestedRuleSelectorForSelectorResolve(parent_str, raw);
            defer self.allocator.free(combined);
            return try self.intern_pool.intern(combined);
        },
        .ordinary => {},
    }
    return resolveSelectorInternForStack(self, @intFromEnum(raw_id));
}

pub fn resolveSelectorInternForStack(self: anytype, sel_u: u32) !InternId {
    var out_id: InternId = try self.ensureInternTrailingEscapeDelimiter(@enumFromInt(sel_u));
    const raw = self.intern_pool.get(out_id);
    try self.validateLiteralSelectorForSelectorResolve(raw);
    if (selectorParentForCombination(self, raw)) |parent_id| {
        if (selectorIsBareParentReference(raw)) return parent_id;
        const parent_str = self.intern_pool.get(parent_id);
        const combined = try self.combineNestedRuleSelectorForSelectorResolve(parent_str, raw);
        defer self.allocator.free(combined);
        out_id = try self.intern_pool.intern(combined);
    }
    return out_id;
}

pub fn internDynamicSelectorValueWithMode(self: anytype, v: Value, mode: anytype) !InternId {
    if (try resolveAtRootInterpolatedParentSelectorValue(self, v)) |at_root_id| {
        return at_root_id;
    }
    const resolved = try self.maybeResolveParentSelectorValue(v);
    const raw_unfixed_id = if (resolved.isString())
        resolved.stringIntern()
    else
        try self.valueToInternIdRawForSelectorResolve(resolved);
    const unescaped_id = try maybeUnescapeDynamicSelectorText(self, raw_unfixed_id);
    const raw_id = try self.ensureInternTrailingEscapeDelimiter(unescaped_id);
    if (try resolveAtRootParentReferencesInRawSelector(self, raw_id)) |at_root_id| {
        return at_root_id;
    }
    const raw = self.intern_pool.get(raw_id);
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return error.SassError;
    switch (mode) {
        .plain_css_preserve => {
            if (self.selector_prefix_depth > 0 and
                self.selector_stack.items.len == self.selector_prefix_depth and
                self.selector_stack.items.len > 0 and
                std.mem.indexOfScalar(u8, raw, '&') == null)
            {
                const parent_id = self.selector_stack.items[self.selector_stack.items.len - 1];
                const parent_str = self.intern_pool.get(parent_id);
                const combined = try self.combineNestedRuleSelectorForSelectorResolve(parent_str, raw);
                defer self.allocator.free(combined);
                const combined_id = try self.intern_pool.intern(combined);
                try self.validateDynamicSelectorForSelectorResolve(self.intern_pool.get(combined_id));
                return combined_id;
            }
            try self.validateDynamicSelectorForSelectorResolve(raw);
            return raw_id;
        },
        .plain_css_combine_parent => {
            if (self.selector_stack.items.len == 0) {
                try self.validateDynamicSelectorForSelectorResolve(raw);
                return raw_id;
            }
            if (std.mem.indexOfScalar(u8, raw, '&') != null) {
                try self.validateDynamicSelectorForSelectorResolve(raw);
                return raw_id;
            }
            const parent_id = self.selector_stack.items[self.selector_stack.items.len - 1];
            const parent_str = self.intern_pool.get(parent_id);
            const combined = try self.combineNestedRuleSelectorForSelectorResolve(parent_str, raw);
            defer self.allocator.free(combined);
            const combined_id = try self.intern_pool.intern(combined);
            try self.validateDynamicSelectorForSelectorResolve(self.intern_pool.get(combined_id));
            return combined_id;
        },
        .ordinary => return internDynamicSelectorValue(self, v),
    }
}

pub fn internDynamicSelectorValue(self: anytype, v: Value) !InternId {
    if (try resolveAtRootInterpolatedParentSelectorValue(self, v)) |at_root_id| {
        return at_root_id;
    }
    const resolved = try self.maybeResolveParentSelectorValue(v);
    var out_id = if (resolved.isString())
        resolved.stringIntern()
    else
        try self.valueToInternIdRawForSelectorResolve(resolved);
    out_id = try maybeUnescapeDynamicSelectorText(self, out_id);
    out_id = try self.ensureInternTrailingEscapeDelimiter(out_id);
    if (try resolveAtRootParentReferencesInRawSelector(self, out_id)) |at_root_id| {
        return at_root_id;
    }
    const raw = self.intern_pool.get(out_id);
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return error.SassError;
    if (selectorParentForCombination(self, raw)) |parent_id| {
        if (selectorIsBareParentReference(raw)) return parent_id;
        const parent_str = self.intern_pool.get(parent_id);
        const combined = try self.combineNestedRuleSelectorForSelectorResolve(parent_str, raw);
        defer self.allocator.free(combined);
        out_id = try self.intern_pool.intern(combined);
    }
    try self.validateDynamicSelectorForSelectorResolve(self.intern_pool.get(out_id));
    return out_id;
}

fn resolveAtRootInterpolatedParentSelectorValue(self: anytype, v: Value) !?InternId {
    if (v.kind() != .string or !v.stringPreservesAmpersand(self.string_flags_pool.items)) return null;
    const parent_id = self.currentAtRootParentSelector() orelse return null;
    const keep_len = self.currentAtRootKeepLen() orelse self.selector_prefix_depth;
    if (self.selector_stack.items.len != keep_len) return null;

    const raw = self.intern_pool.get(v.stringIntern());
    if (std.mem.indexOfScalar(u8, raw, '&') == null) return null;
    const parent = self.intern_pool.get(parent_id);

    if (std.mem.indexOfScalar(u8, parent, ',') != null) {
        return resolveAtRootParentReferencesParsed(self, raw, parent);
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(self.allocator);
    try out.ensureTotalCapacity(self.allocator, raw.len + parent.len);
    for (raw) |ch| {
        if (ch == '&') {
            try out.appendSlice(self.allocator, parent);
        } else {
            try out.append(self.allocator, ch);
        }
    }
    const raw_id = try internNormalizedSelectorText(self, out.items);
    const fixed_id = try self.ensureInternTrailingEscapeDelimiter(raw_id);
    try self.validateDynamicSelectorForSelectorResolve(self.intern_pool.get(fixed_id));
    return fixed_id;
}

fn resolveAtRootParentReferencesInRawSelector(self: anytype, raw_id: InternId) !?InternId {
    const parent_id = self.currentAtRootParentSelector() orelse return null;
    const keep_len = self.currentAtRootKeepLen() orelse self.selector_prefix_depth;
    if (self.selector_stack.items.len != keep_len) return null;

    const raw = self.intern_pool.get(raw_id);
    if (std.mem.indexOfScalar(u8, raw, '&') == null) {
        if (keep_len > 0 and keep_len == self.selector_prefix_depth) return null;
        try self.validateDynamicSelectorForSelectorResolve(raw);
        return raw_id;
    }
    const parent = self.intern_pool.get(parent_id);

    if (std.mem.indexOfScalar(u8, parent, ',') != null) {
        return resolveAtRootParentReferencesParsed(self, raw, parent);
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(self.allocator);
    try out.ensureTotalCapacity(self.allocator, raw.len + parent.len);
    for (raw) |ch| {
        if (ch == '&') {
            try out.appendSlice(self.allocator, parent);
        } else {
            try out.append(self.allocator, ch);
        }
    }
    const replaced_id = try internNormalizedSelectorText(self, out.items);
    const fixed_id = try self.ensureInternTrailingEscapeDelimiter(replaced_id);
    try self.validateDynamicSelectorForSelectorResolve(self.intern_pool.get(fixed_id));
    return fixed_id;
}

fn resolveAtRootParentReferencesParsed(self: anytype, raw: []const u8, parent: []const u8) !?InternId {
    var child_sel = selector_mod.parse(self.allocator, raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer child_sel.deinit();
    var parent_sel = selector_mod.parse(self.allocator, parent) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parent_sel.deinit();

    var resolved = selector_mod.resolveParentAtRoot(self.allocator, &child_sel, &parent_sel) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer resolved.deinit();

    const css = selector_mod.toCss(self.allocator, &resolved) catch return error.OutOfMemory;
    defer self.allocator.free(css);
    const replaced_id = try self.intern_pool.intern(css);
    const fixed_id = try self.ensureInternTrailingEscapeDelimiter(replaced_id);
    try self.validateDynamicSelectorForSelectorResolve(self.intern_pool.get(fixed_id));
    return fixed_id;
}

fn selectorListToCssWithSeparator(
    alloc: std.mem.Allocator,
    list: *const selector_mod.SelectorList,
    separator: []const u8,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    for (list.selectors.items, 0..) |complex, i| {
        if (i > 0) try buf.appendSlice(alloc, separator);
        const css = selector_mod.complexSelectorToCss(alloc, &complex) catch return error.OutOfMemory;
        defer alloc.free(css);
        try buf.appendSlice(alloc, css);
    }
    return buf.toOwnedSlice(alloc);
}

fn internNormalizedSelectorText(self: anytype, raw: []const u8) !InternId {
    var parsed = selector_mod.parse(self.allocator, raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return self.intern_pool.intern(raw) catch error.OutOfMemory,
    };
    defer parsed.deinit();
    const css = selectorListToCssWithSeparator(self.allocator, &parsed, ", ") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer self.allocator.free(css);
    return self.intern_pool.intern(css) catch error.OutOfMemory;
}

pub fn maybeUnescapeDynamicSelectorText(self: anytype, raw_id: InternId) !InternId {
    const raw = self.intern_pool.get(raw_id);
    if (std.mem.indexOfScalar(u8, raw, '@') == null or std.mem.indexOfScalar(u8, raw, '\\') == null) {
        return raw_id;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(self.allocator);
    var i: usize = 0;
    var changed = false;
    while (i < raw.len) {
        if (raw[i] == '\\') {
            var slash_count: usize = 0;
            while (i + slash_count < raw.len and raw[i + slash_count] == '\\') : (slash_count += 1) {}
            if (slash_count > 1 and i + slash_count < raw.len and raw[i + slash_count] == '@') {
                var keep: usize = 0;
                while (keep < slash_count - 1) : (keep += 1) {
                    try out.append(self.allocator, '\\');
                }
                try out.append(self.allocator, '@');
                i += slash_count + 1;
                changed = true;
                continue;
            }
        }
        try out.append(self.allocator, raw[i]);
        i += 1;
    }
    if (!changed) return raw_id;
    return self.intern_pool.intern(out.items) catch error.OutOfMemory;
}
