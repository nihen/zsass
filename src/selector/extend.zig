const std = @import("std");
const selector_mod = @import("selector.zig");
const SelectorList = selector_mod.SelectorList;
const ComplexSelector = selector_mod.ComplexSelector;
const ComplexSelectorComponent = selector_mod.ComplexSelectorComponent;
const CompoundSelector = selector_mod.CompoundSelector;
const PseudoSelector = selector_mod.PseudoSelector;
const SimpleSelector = selector_mod.SimpleSelector;
const specificity = @import("extend_specificity.zig");
const extend_engine = @import("extend_engine.zig");
const cloneSimpleSelector = selector_mod.cloneSimpleSelector;
const simpleSelectorEql = specificity.simpleSelectorEql;
const compoundSelectorEql = specificity.compoundSelectorEql;
pub const complexSelectorEql = specificity.complexSelectorEql;
const getLastCompound = specificity.getLastCompound;
pub const compoundContainsTarget = specificity.compoundContainsTarget;

// ============================================================================
// Types
// ============================================================================

pub const Extension = struct {
    extender: SelectorList,
    target: CompoundSelector,
    optional: bool,
    span: ?struct { start: u32, end: u32 },
    /// Monotonic id for @extend evaluation order (matches official Sass CLI comma ordering).
    eval_order: u32 = 0,
    /// Shared id for all targets emitted by the same @extend statement.
    statement_group_order: ?u32 = null,
    /// Monotonic source order for this @extend statement or split branch.
    statement_order: ?u32 = null,
    /// Selector-list branch within a shared @extend statement. This lets
    /// repeated-target reapplication stay branch-local (`.a, .b {@extend .x}`
    /// should not synthesize `.a .b ...` combinations when extending `.x + .x`).
    statement_branch_index: ?u32 = null,
    /// Historical (@import compatibility): true when this @extend was recorded
    /// while evaluating an @import child stylesheet.
    /// Used for comma-list ordering: mixed import vs @use extenders of the same target are not
    /// primary-merged (official Sass CLI use_into_use_and_import_into_* specs).
    from_import_child: bool = false,
    /// Shared @use/@forward module chunk identity.
    /// Later module chunks sort ahead of earlier ones, while selectors within
    /// the same chunk keep their original declaration order.
    module_group_start_order: ?u32 = null,
    /// True when propagated from child @use module.
    is_propagated: bool = false,
    /// The module the `@extend` was written in.
    source_module: u32 = 0,

    pub fn deinit(self: *Extension) void {
        self.extender.deinit();
        self.target.deinit();
    }
};

fn isTransparentSelectorPseudo(name: []const u8) bool {
    const base = selector_mod.pseudoBaseName(name);
    return std.ascii.eqlIgnoreCase(base, "is") or
        std.ascii.eqlIgnoreCase(base, "where") or
        std.ascii.eqlIgnoreCase(base, "matches") or
        std.ascii.eqlIgnoreCase(base, "any");
}

fn transparentPseudoOnly(complex: *const ComplexSelector) ?PseudoSelector {
    if (complex.components.items.len != 1) return null;
    const compound = switch (complex.components.items[0]) {
        .compound => |c| c,
        .combinator => return null,
    };
    if (compound.simple_selectors.items.len != 1) return null;
    return switch (compound.simple_selectors.items[0]) {
        .pseudo_class => |ps| if (isTransparentSelectorPseudo(ps.name) and ps.selector != null) ps else null,
        else => null,
    };
}

// SAFETY: `@TypeOf` only inspects the compile-time type of `Extension.span`.
// The `undefined` value is never read at runtime.
const ExtensionSpan = @TypeOf(@as(Extension, undefined).span);

const ApplyContext = struct {
    target_extend_order_snapshot: u32 = 0,
    target_module_group_start_order: ?u32 = null,
    target_is_direct_rule: bool = false,
};

inline fn saturatingAddUsize(lhs: usize, rhs: usize) usize {
    return std.math.add(usize, lhs, rhs) catch std.math.maxInt(usize);
}

/// CSS text for a selector: returns cached (borrowed) or freshly allocated (owned).
const CssResult = struct {
    css: []const u8,
    owned: bool,
    allocator: std.mem.Allocator,

    fn deinit(self: CssResult) void {
        if (self.owned) self.allocator.free(self.css);
    }
};

// ============================================================================
//Extension index -- maps simple selector key  ->  matching extension indices.
// Eliminates full-scan of all extensions in the first-pass inner loop.
// ============================================================================

const SsKey = struct {
    tag: std.meta.Tag(SimpleSelector),
    name: []const u8,
};

const SsKeyContext = struct {
    pub fn hash(_: @This(), k: SsKey) u64 {
        var h = std.hash.Wyhash.init(@intFromEnum(k.tag));
        h.update(k.name);
        return h.final();
    }
    pub fn eql(_: @This(), a: SsKey, b: SsKey) bool {
        return a.tag == b.tag and std.mem.eql(u8, a.name, b.name);
    }
};

/// Maps SsKey  ->  list of extension indices (in sorted_indices order).
const ExtIndex = std.HashMapUnmanaged(SsKey, std.ArrayListUnmanaged(usize), SsKeyContext, 80);

fn ssKeyFromSimple(ss: SimpleSelector) SsKey {
    return switch (ss) {
        .type_selector => |n| .{ .tag = .type_selector, .name = n },
        .class => |n| .{ .tag = .class, .name = n },
        .id => |n| .{ .tag = .id, .name = n },
        .placeholder => |n| .{ .tag = .placeholder, .name = n },
        .parent => .{ .tag = .parent, .name = "" },
        .universal => .{ .tag = .universal, .name = "" },
        .attribute => |a| .{ .tag = .attribute, .name = a.name },
        .pseudo_class => |p| .{ .tag = .pseudo_class, .name = p.name },
        .pseudo_element => |p| .{ .tag = .pseudo_element, .name = p.name },
    };
}

fn complexCssResult(c: *const ComplexSelector) std.mem.Allocator.Error!CssResult {
    if (c.cached_css) |css| return .{ .css = css, .owned = false, .allocator = c.allocator };
    const css = try selector_mod.complexSelectorToCss(c.allocator, c);
    return .{ .css = css, .owned = true, .allocator = c.allocator };
}

fn complexHasExactCssText(
    lhs: *const ComplexSelector,
    rhs: *const ComplexSelector,
) !bool {
    // Fast path: structural equality avoids CSS generation
    if (complexSelectorEql(lhs, rhs)) return true;
    // Fast rejection: different component counts can never produce identical CSS
    if (lhs.components.items.len != rhs.components.items.len) return false;
    const lr = try complexCssResult(lhs);
    defer lr.deinit();
    const rr = try complexCssResult(rhs);
    defer rr.deinit();
    return std.mem.eql(u8, lr.css, rr.css);
}

fn firstCompound(complex: *const ComplexSelector) ?*const CompoundSelector {
    for (complex.components.items) |*component| {
        if (component.* == .compound) return &component.compound;
    }
    return null;
}

/// What one module contributes to the rules of the modules it uses: its
/// extenders in the order it registered them, each as the modules using
/// that module left it.
const GroupData = struct {
    module: u32,
    targets: std.ArrayList(CompoundSelector) = .empty,
    extenders: std.ArrayList(SelectorList) = .empty,
    done: bool = false,
    busy: bool = false,

    fn deinit(self: *GroupData, allocator: std.mem.Allocator) void {
        for (self.targets.items) |*target| target.deinit();
        self.targets.deinit(allocator);
        for (self.extenders.items) |*list| list.deinit();
        self.extenders.deinit(allocator);
    }
};

/// The module number of the engine that holds every other module's part.
const other_modules = std.math.maxInt(u32);

const GroupEngine = struct {
    module: u32,
    engine: *extend_engine.Engine,
};

const GroupKey = struct {
    module: u32,
    group: u32,
    /// The order of the module's first `@extend`.
    first: u32,
};

pub const ApplyState = struct {
    extensions: std.ArrayList(Extension),
    /// Every `@extend` whose target a rule of this module holds, as it was
    /// written and in the order it ran. The engine works from these.
    exact_order_hints: std.ArrayList(Extension),
    allocator: std.mem.Allocator,
    has_propagated_extensions: bool = false,
    /// For finding the extensions a selector's simple selectors are targets
    /// of, when marking which `@extend`s found their target.
    apply_cache_valid: bool = false,
    cached_sorted_indices: std.ArrayList(usize) = .empty,
    cached_ext_is_placeholder: std.ArrayList(bool) = .empty,
    cached_ext_index: ExtIndex = .empty,
    /// One engine per module that has `@extend`s reaching this module's
    /// rules. This module's own comes first; the others follow, the module
    /// loaded last first.
    engines: std.ArrayList(GroupEngine) = .empty,
    engines_built: bool = false,
    engines_usable: bool = false,
    /// The module whose rules this store extends.
    own_module: u32 = 0,
    /// `visibility[from * n + target]`: module `from` uses module `target`,
    /// directly or not. Borrowed.
    visibility: []const bool = &.{},
    visibility_n: u32 = 0,
    /// `@extend`s whose target no rule of the module holds. They extend
    /// nothing by themselves, but their extenders are still extended.
    unmatched_hints: std.ArrayList(Extension) = .empty,

    pub fn init(allocator: std.mem.Allocator) ApplyState {
        return .{
            .extensions = .empty,
            .exact_order_hints = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ApplyState) void {
        self.dropEngines();
        self.engines.deinit(self.allocator);
        for (self.unmatched_hints.items) |*ext| ext.deinit();
        self.unmatched_hints.deinit(self.allocator);
        self.deinitCachedExtIndex();
        self.cached_ext_index.deinit(self.allocator);
        self.cached_sorted_indices.deinit(self.allocator);
        self.cached_ext_is_placeholder.deinit(self.allocator);
        for (self.extensions.items) |*ext| {
            ext.deinit();
        }
        self.extensions.deinit(self.allocator);
        for (self.exact_order_hints.items) |*ext| {
            ext.deinit();
        }
        self.exact_order_hints.deinit(self.allocator);
    }

    pub fn addExtension(self: *ApplyState, extension: Extension) !void {
        if (extension.is_propagated) self.has_propagated_extensions = true;
        try self.extensions.append(self.allocator, extension);
        self.invalidateExtensionCaches();
    }

    pub fn addExactOrderHint(self: *ApplyState, extension: Extension) !void {
        try self.exact_order_hints.append(self.allocator, extension);
    }

    fn dropEngines(self: *ApplyState) void {
        for (self.engines.items) |group| group.engine.deinit(self.allocator);
        self.engines.clearRetainingCapacity();
        self.engines_built = false;
        self.engines_usable = false;
    }

    fn moduleUses(self: *const ApplyState, from: u32, target: u32) bool {
        if (from == target) return false;
        const n = self.visibility_n;
        if (n == 0 or self.visibility.len != n * n or from >= n or target >= n) return false;
        return self.visibility[from * n + target];
    }

    /// Group the `@extend`s by the module they were written in. An
    /// `@extend` reaches the rules of its own module and of the modules
    /// that module uses, and the `@extend`s of two modules that do not use
    /// one another do not see each other's results.
    fn buildEngines(self: *ApplyState) !void {
        self.engines_built = true;
        var all: std.ArrayList(*const Extension) = .empty;
        defer all.deinit(self.allocator);
        for (self.exact_order_hints.items) |*hint| try all.append(self.allocator, hint);
        for (self.unmatched_hints.items) |*hint| try all.append(self.allocator, hint);
        // A store filled directly has no edge history; its extensions are
        // the `@extend`s.
        if (all.items.len == 0) {
            for (self.extensions.items) |*ext| try all.append(self.allocator, ext);
        }
        std.mem.sort(*const Extension, all.items, {}, struct {
            fn lessThan(_: void, x: *const Extension, y: *const Extension) bool {
                return x.eval_order < y.eval_order;
            }
        }.lessThan);

        var modules: std.ArrayList(GroupKey) = .empty;
        defer modules.deinit(self.allocator);
        for (all.items) |hint| {
            var known = false;
            for (modules.items) |*key| {
                if (key.module != hint.source_module) continue;
                known = true;
                if (hint.module_group_start_order) |group| key.group = @max(key.group, group);
            }
            if (!known) try modules.append(self.allocator, .{ .module = hint.source_module, .group = hint.module_group_start_order orelse 0, .first = hint.eval_order });
        }
        const own = self.own_module;
        std.mem.sort(GroupKey, modules.items, own, struct {
            fn lessThan(own_module: u32, x: GroupKey, y: GroupKey) bool {
                if ((x.module == own_module) != (y.module == own_module)) return x.module == own_module;
                if (x.group != y.group) return x.group > y.group;
                return x.first > y.first;
            }
        }.lessThan);

        const groups = try self.allocator.alloc(GroupData, modules.items.len);
        defer {
            for (groups) |*group| group.deinit(self.allocator);
            self.allocator.free(groups);
        }
        for (groups, modules.items) |*group, key| group.* = .{ .module = key.module };

        var own_engine: ?*extend_engine.Engine = null;
        errdefer if (own_engine) |engine| engine.deinit(self.allocator);
        var foreign: std.ArrayList(usize) = .empty;
        defer foreign.deinit(self.allocator);
        for (modules.items, 0..) |key, index| {
            if (key.module == own) {
                var sources: std.ArrayList(extend_engine.Source) = .empty;
                defer sources.deinit(self.allocator);
                for (all.items) |hint| {
                    if (hint.source_module != own) continue;
                    try sources.append(self.allocator, .{ .extender = &hint.extender, .target = &hint.target, .order = hint.eval_order });
                }
                own_engine = try extend_engine.Engine.init(self.allocator, sources.items, .written) orelse return;
                continue;
            }
            self.buildGroup(all.items, groups, index) catch |err| switch (err) {
                error.Unsupported => {
                    if (own_engine) |engine| engine.deinit(self.allocator);
                    own_engine = null;
                    return;
                },
                else => |e| return e,
            };
            try foreign.append(self.allocator, index);
        }
        if (own_engine) |engine| {
            try self.engines.append(self.allocator, .{ .module = own, .engine = engine });
            own_engine = null;
        }
        if (foreign.items.len != 0) {
            const combined = try self.resolvedEngine(groups, foreign.items) orelse {
                self.dropEngines();
                self.engines_built = true;
                return;
            };
            try self.engines.append(self.allocator, .{ .module = other_modules, .engine = combined });
        }
        self.engines_usable = true;
    }

    /// An engine holding the given groups' extenders as they are, group
    /// after group.
    fn resolvedEngine(self: *ApplyState, groups: []const GroupData, indices: []const usize) !?*extend_engine.Engine {
        var sources: std.ArrayList(extend_engine.Source) = .empty;
        defer sources.deinit(self.allocator);
        for (indices) |index| {
            const group = &groups[index];
            for (group.targets.items, group.extenders.items) |*target, *list| {
                try sources.append(self.allocator, .{ .extender = list, .target = target, .order = @intCast(sources.items.len) });
            }
        }
        return extend_engine.Engine.init(self.allocator, sources.items, .resolved);
    }

    /// Work out what one other module contributes.
    fn buildGroup(
        self: *ApplyState,
        all: []const *const Extension,
        groups: []GroupData,
        index: usize,
    ) error{ OutOfMemory, Unsupported }!void {
        const group = &groups[index];
        if (group.done) return;
        // Modules do not use one another in a circle; a group met again
        // while it is being worked out contributes nothing yet.
        if (group.busy) return;
        group.busy = true;
        defer group.busy = false;

        var sources: std.ArrayList(extend_engine.Source) = .empty;
        defer sources.deinit(self.allocator);
        for (all) |hint| {
            if (hint.source_module != group.module) continue;
            try sources.append(self.allocator, .{ .extender = &hint.extender, .target = &hint.target, .order = hint.eval_order });
        }
        const engine = try extend_engine.Engine.init(self.allocator, sources.items, .written) orelse return error.Unsupported;
        defer engine.deinit(self.allocator);

        // The modules that use this one extend its extenders.
        var downstream: std.ArrayList(usize) = .empty;
        defer downstream.deinit(self.allocator);
        for (groups, 0..) |*other, other_index| {
            if (other_index == index or !self.moduleUses(other.module, group.module)) continue;
            try self.buildGroup(all, groups, other_index);
            if (other.done) try downstream.append(self.allocator, other_index);
        }
        const downstream_engine: ?*extend_engine.Engine = if (downstream.items.len != 0)
            try self.resolvedEngine(groups, downstream.items) orelse return error.Unsupported
        else
            null;
        defer if (downstream_engine) |e| e.deinit(self.allocator);

        const count = engine.entryCount();
        try group.targets.ensureTotalCapacity(self.allocator, count);
        try group.extenders.ensureTotalCapacity(self.allocator, count);
        for (0..count) |entry_index| {
            if (engine.entrySuperseded(entry_index)) continue;
            var written = SelectorList.init(self.allocator);
            defer written.deinit();
            {
                var cloned = try engine.entryExtender(entry_index).clone(self.allocator);
                errdefer cloned.deinit();
                try written.selectors.append(self.allocator, cloned);
            }
            var extended = if (downstream_engine) |e|
                try e.extendSelector(self.allocator, &written, std.math.maxInt(u32))
            else
                try written.clone(self.allocator);
            errdefer extended.deinit();

            var target = CompoundSelector.init(self.allocator);
            errdefer target.deinit();
            try target.simple_selectors.append(self.allocator, try selector_mod.cloneSimpleSelector(engine.entryTarget(entry_index), self.allocator));
            group.targets.appendAssumeCapacity(target);
            group.extenders.appendAssumeCapacity(extended);
        }
        group.done = true;
    }

    fn extendWithEngines(self: *ApplyState, selector_list: *const SelectorList, snapshot: u32) !SelectorList {
        var details: std.ArrayList(extend_engine.Detail) = .empty;
        defer details.deinit(self.allocator);

        // This module's own `@extend`s first.
        var result: SelectorList = blk: {
            for (self.engines.items) |group| {
                if (group.module != self.own_module) continue;
                break :blk try group.engine.extendSelectorDetailed(self.allocator, selector_list, snapshot, &details);
            }
            for (selector_list.selectors.items) |_| {
                try details.append(self.allocator, .{ .original = true, .source = .{ .a = 0, .b = 0, .c = 0 } });
            }
            break :blk try selector_list.clone(self.allocator);
        };
        errdefer result.deinit();

        // Then every other module's, all of them at once on the selector
        // as this module left it.
        for (self.engines.items) |group| {
            if (group.module != other_modules) continue;
            var group_details: std.ArrayList(extend_engine.Detail) = .empty;
            defer group_details.deinit(self.allocator);
            var extended = try group.engine.extendSelectorDetailed(self.allocator, &result, std.math.maxInt(u32), &group_details);
            errdefer extended.deinit();
            // What this module's own result was made of keeps how it was
            // marked; the rest is generated.
            var own_index: usize = 0;
            for (group_details.items) |*detail| {
                if (!detail.original) continue;
                if (own_index < details.items.len) detail.* = details.items[own_index];
                own_index += 1;
            }
            const changed = extended.selectors.items.len != result.selectors.items.len;
            result.deinit();
            result = extended;
            if (changed) extend_engine.trimUnion(&result, &group_details);
        }
        return result;
    }

    fn invalidateExtensionCaches(self: *ApplyState) void {
        self.dropEngines();
        self.apply_cache_valid = false;
        self.cached_sorted_indices.clearRetainingCapacity();
        self.cached_ext_is_placeholder.clearRetainingCapacity();
        self.deinitCachedExtIndex();
    }

    fn deinitCachedExtIndex(self: *ApplyState) void {
        var eit = self.cached_ext_index.iterator();
        while (eit.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.cached_ext_index.clearRetainingCapacity();
    }

    fn ensureApplyCaches(self: *ApplyState) !void {
        if (self.apply_cache_valid) return;

        const extensions = self.extensions.items;
        self.cached_sorted_indices.clearRetainingCapacity();
        self.cached_ext_is_placeholder.clearRetainingCapacity();
        self.deinitCachedExtIndex();

        try self.cached_sorted_indices.ensureTotalCapacity(self.allocator, extensions.len);
        for (0..extensions.len) |i| {
            self.cached_sorted_indices.appendAssumeCapacity(i);
        }
        if (self.cached_sorted_indices.items.len > 1) {
            const SortExt = struct {
                ext_items: []const Extension,
                fn less(c: @This(), ia: usize, ib: usize) bool {
                    const a = c.ext_items[ia].eval_order;
                    const b = c.ext_items[ib].eval_order;
                    if (a != b) return a < b;
                    return ia < ib;
                }
            };
            std.mem.sort(usize, self.cached_sorted_indices.items, SortExt{ .ext_items = extensions }, SortExt.less);
            // Reverse to match official Sass CLI ordering: later-declared extensions appear first
            std.mem.reverse(usize, self.cached_sorted_indices.items);
        }

        try self.cached_ext_is_placeholder.ensureTotalCapacity(self.allocator, extensions.len);
        for (extensions) |ext| {
            self.cached_ext_is_placeholder.appendAssumeCapacity(for (ext.target.simple_selectors.items) |tss| {
                if (tss == .placeholder) break true;
            } else false);
        }

        var target_simple_count: usize = 0;
        for (extensions) |ext| {
            target_simple_count = saturatingAddUsize(target_simple_count, ext.target.simple_selectors.items.len);
        }
        try self.cached_ext_index.ensureTotalCapacity(self.allocator, @intCast(@min(target_simple_count, std.math.maxInt(u32))));

        for (self.cached_sorted_indices.items) |ext_i| {
            const ext = &extensions[ext_i];
            for (ext.target.simple_selectors.items) |tss| {
                const key = ssKeyFromSimple(tss);
                const gop = try self.cached_ext_index.getOrPut(self.allocator, key);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(self.allocator, ext_i);
            }
        }
        self.apply_cache_valid = true;
    }

    pub fn applySelectorExtensionsWithContext(
        self: *ApplyState,
        selector_list: *const SelectorList,
        rule_ctx: RuleApplyContext,
    ) !SelectorList {
        const ctx = ApplyContext{
            .target_extend_order_snapshot = rule_ctx.target_extend_order_snapshot,
            .target_is_direct_rule = rule_ctx.target_is_direct_rule,
        };
        return self.applySelectorExtensionsInner(selector_list, ctx);
    }

    fn applySelectorExtensionsInner(
        self: *ApplyState,
        selector_list: *const SelectorList,
        context: ?ApplyContext,
    ) !SelectorList {
        if (!self.engines_built) try self.buildEngines();
        if (!self.engines_usable) return selector_list.clone(self.allocator);
        const snapshot: u32 = if (context) |ctx| ctx.target_extend_order_snapshot else std.math.maxInt(u32);
        return self.extendWithEngines(selector_list, snapshot);
    }

    pub fn hasPropagatedExtensions(self: *const ApplyState) bool {
        return self.has_propagated_extensions;
    }

    pub fn selectorHasAnyExtensionTarget(self: *const ApplyState, selector_list: *const SelectorList) !bool {
        for (selector_list.selectors.items) |complex| {
            for (self.extensions.items) |ext| {
                if (compoundContainsTargetInComplex(&complex, &ext.target) or
                    try complexContainsTargetInPseudos(&complex, &ext.target))
                {
                    return true;
                }
            }
        }
        return false;
    }

    /// Like markMatches, but skips propagated extensions (from child @use modules).
    fn markNonPropagatedCandidatesForSimple(
        self: *ApplyState,
        outer_complex: *const ComplexSelector,
        simple: SimpleSelector,
        matched: []bool,
    ) !void {
        const candidates = if (self.cached_ext_index.get(ssKeyFromSimple(simple))) |list| list.items else return;
        for (candidates) |idx| {
            if (matched[idx]) continue;
            const ext = &self.extensions.items[idx];
            if (ext.is_propagated) continue;
            if (compoundContainsTargetInComplex(outer_complex, &ext.target) or
                try complexContainsTargetInPseudos(outer_complex, &ext.target))
            {
                matched[idx] = true;
            }
        }
    }

    fn markNonPropagatedCandidatesInComplex(
        self: *ApplyState,
        outer_complex: *const ComplexSelector,
        walk_complex: *const ComplexSelector,
        matched: []bool,
    ) !void {
        for (walk_complex.components.items) |component| {
            if (component != .compound) continue;
            for (component.compound.simple_selectors.items) |ss| {
                try self.markNonPropagatedCandidatesForSimple(outer_complex, ss, matched);
                switch (ss) {
                    .pseudo_class => |ps| {
                        if (ps.selector) |inner| {
                            for (inner.selectors.items) |inner_complex| {
                                try self.markNonPropagatedCandidatesInComplex(outer_complex, &inner_complex, matched);
                            }
                        }
                    },
                    .pseudo_element => |ps| {
                        if (ps.selector) |inner| {
                            for (inner.selectors.items) |inner_complex| {
                                try self.markNonPropagatedCandidatesInComplex(outer_complex, &inner_complex, matched);
                            }
                        }
                    },
                    else => {},
                }
            }
        }
    }

    fn markChainedNonPropagatedCandidatesForSimple(
        self: *ApplyState,
        carrier: *const Extension,
        simple: SimpleSelector,
        matched: []bool,
        changed: *bool,
    ) bool {
        const candidates = if (self.cached_ext_index.get(ssKeyFromSimple(simple))) |list| list.items else return false;
        var marked_any = false;
        for (candidates) |idx| {
            if (matched[idx]) continue;
            const ext = &self.extensions.items[idx];
            if (ext.is_propagated) continue;
            if (ext.target.simple_selectors.items.len != 1 and !extensionExtenderContainsTarget(carrier, &ext.target)) {
                continue;
            }
            matched[idx] = true;
            changed.* = true;
            marked_any = true;
        }
        return marked_any;
    }

    fn markChainedNonPropagatedCandidatesInComplex(
        self: *ApplyState,
        carrier: *const Extension,
        complex: *const ComplexSelector,
        matched: []bool,
        changed: *bool,
    ) void {
        for (complex.components.items) |component| {
            if (component != .compound) continue;
            for (component.compound.simple_selectors.items) |ss| {
                _ = self.markChainedNonPropagatedCandidatesForSimple(carrier, ss, matched, changed);
                switch (ss) {
                    .pseudo_class => |ps| {
                        if (ps.selector) |inner| {
                            self.markChainedNonPropagatedCandidatesInSelectorList(carrier, inner, matched, changed);
                        }
                    },
                    .pseudo_element => |ps| {
                        if (ps.selector) |inner| {
                            self.markChainedNonPropagatedCandidatesInSelectorList(carrier, inner, matched, changed);
                        }
                    },
                    else => {},
                }
            }
        }
    }

    fn markChainedNonPropagatedCandidatesInSelectorList(
        self: *ApplyState,
        carrier: *const Extension,
        selector_list: *const SelectorList,
        matched: []bool,
        changed: *bool,
    ) void {
        for (selector_list.selectors.items) |complex| {
            self.markChainedNonPropagatedCandidatesInComplex(carrier, &complex, matched, changed);
        }
    }

    pub fn markMatchesNonPropagated(self: *ApplyState, selector_list: *const SelectorList, matched: []bool) !void {
        if (matched.len != self.extensions.items.len) return error.InvalidMatchedSlice;
        try self.ensureApplyCaches();
        for (selector_list.selectors.items) |complex| {
            try self.markNonPropagatedCandidatesInComplex(&complex, &complex, matched);
        }

        // Same chained @extend support as markMatches(), but confined to local
        // (non-propagated) extensions so module boundaries remain respected.
        const processed_carriers = try self.allocator.alloc(bool, self.extensions.items.len);
        defer self.allocator.free(processed_carriers);
        @memset(processed_carriers, false);
        var changed = true;
        while (changed) {
            changed = false;
            for (self.extensions.items, 0..) |carrier, carrier_idx| {
                if (!matched[carrier_idx]) continue;
                if (carrier.is_propagated) continue;
                if (processed_carriers[carrier_idx]) continue;
                processed_carriers[carrier_idx] = true;
                self.markChainedNonPropagatedCandidatesInSelectorList(&carrier, &carrier.extender, matched, &changed);
            }
        }
    }
};

const RuleModuleEdgeOptions = struct {
    optional: bool,
    span: ExtensionSpan = null,
    statement_group_order: ?u32 = null,
    statement_order: ?u32 = null,
    statement_branch_index: ?u32 = null,
    statement_branch_leading_newline: bool = false,
    module_group_start_order: ?u32 = null,
    from_import_child: bool = false,
    is_propagated: bool = false,
    source_module: u32 = 0,
};

pub const RuleModuleExtendState = struct {
    allocator: std.mem.Allocator,
    module_stores: []ApplyState,
    module_next_eval_order: []u32,
    module_edge_indices: []std.ArrayListUnmanaged(u32),
    /// One allocation; `module_matched` rows are subslices of this buffer.
    module_matched_backing: []bool,
    module_matched: [][]bool,

    pub fn init(allocator: std.mem.Allocator, module_store_count: usize) !RuleModuleExtendState {
        const module_stores = try allocator.alloc(ApplyState, module_store_count);
        errdefer allocator.free(module_stores);
        for (module_stores) |*store| {
            store.* = ApplyState.init(allocator);
        }

        const module_next_eval_order = try allocator.alloc(u32, module_store_count);
        errdefer allocator.free(module_next_eval_order);
        @memset(module_next_eval_order, 0);

        const module_edge_indices = try allocator.alloc(std.ArrayListUnmanaged(u32), module_store_count);
        errdefer allocator.free(module_edge_indices);
        for (module_edge_indices) |*edge_indices| {
            edge_indices.* = .empty;
        }

        const module_matched = try allocator.alloc([]bool, module_store_count);
        errdefer allocator.free(module_matched);
        const module_matched_backing = try allocator.alloc(bool, 0);
        errdefer allocator.free(module_matched_backing);
        for (module_matched) |*matched| {
            matched.* = module_matched_backing[0..0];
        }

        return .{
            .allocator = allocator,
            .module_stores = module_stores,
            .module_next_eval_order = module_next_eval_order,
            .module_edge_indices = module_edge_indices,
            .module_matched_backing = module_matched_backing,
            .module_matched = module_matched,
        };
    }

    pub fn deinit(self: *RuleModuleExtendState) void {
        for (self.module_stores) |*store| {
            store.deinit();
        }
        self.allocator.free(self.module_stores);

        self.allocator.free(self.module_next_eval_order);

        for (self.module_edge_indices) |*edge_indices| {
            edge_indices.deinit(self.allocator);
        }
        self.allocator.free(self.module_edge_indices);

        self.allocator.free(self.module_matched_backing);
        self.allocator.free(self.module_matched);
    }

    fn selectorListHasExactBranch(list: *const SelectorList, branch: *const ComplexSelector) !bool {
        for (list.selectors.items) |*existing| {
            if (try complexHasExactCssText(existing, branch)) return true;
        }
        return false;
    }

    fn storeHasExactExtensionBranch(
        store: *const ApplyState,
        target: *const CompoundSelector,
        branch: *const ComplexSelector,
    ) !bool {
        for (store.extensions.items) |*existing_ext| {
            if (!compoundSelectorEql(&existing_ext.target, target)) continue;
            if (try selectorListHasExactBranch(&existing_ext.extender, branch)) return true;
        }
        return false;
    }

    fn storeRemoveLaterExactExtensionBranch(
        store: *ApplyState,
        target: *const CompoundSelector,
        branch: *const ComplexSelector,
        current_eval_order: u32,
    ) !bool {
        var removed_any = false;
        for (store.extensions.items) |*existing_ext| {
            if (existing_ext.eval_order <= current_eval_order) continue;
            if (!compoundSelectorEql(&existing_ext.target, target)) continue;
            var idx: usize = existing_ext.extender.selectors.items.len;
            while (idx > 0) {
                idx -= 1;
                if (!try complexHasExactCssText(&existing_ext.extender.selectors.items[idx], branch)) continue;
                var removed = existing_ext.extender.selectors.orderedRemove(idx);
                removed.deinit();
                removed_any = true;
            }
        }
        return removed_any;
    }

    pub fn addModuleEdge(
        self: *RuleModuleExtendState,
        module_idx: usize,
        edge_idx: u32,
        extender: *const SelectorList,
        target: *const CompoundSelector,
        options: RuleModuleEdgeOptions,
    ) !bool {
        const idx = self.moduleIndex(module_idx);
        const store = &self.module_stores[idx];
        store.own_module = @intCast(idx);
        // Use the global edge_idx so eval_order can be compared against
        // `target_extend_order_snapshot` (sampled from global
        // `extend_edges.items.len`). Relative order within any module is
        // preserved because edges are appended monotonically.
        const eval_order = edge_idx;
        {
            var hint_extender = try extender.clone(self.allocator);
            errdefer hint_extender.deinit();
            var hint_target = try target.clone(self.allocator);
            errdefer hint_target.deinit();
            try store.addExactOrderHint(.{
                .extender = hint_extender,
                .target = hint_target,
                .optional = options.optional,
                .span = options.span,
                .eval_order = eval_order,
                .statement_group_order = options.statement_group_order,
                .statement_order = options.statement_order,
                .from_import_child = options.from_import_child,
                .module_group_start_order = options.module_group_start_order,
                .is_propagated = options.is_propagated,
                .source_module = options.source_module,
            });
        }

        // official Sass CLI treats duplicate @extend extenders as already satisfied by
        // their first occurrence. A later duplicate must not move that selector
        // ahead of intervening extenders during the usual later-first ordering.
        // Filter per selector-list branch so `.a, .b { @extend %x }` followed by
        // `.b { @extend %x }` keeps `.a, .b` rather than becoming `.b, .a`.
        var filtered_extender = SelectorList.init(self.allocator);
        errdefer filtered_extender.deinit();
        for (extender.selectors.items) |*branch| {
            if (try selectorListHasExactBranch(&filtered_extender, branch)) continue;
            const removed_later = try storeRemoveLaterExactExtensionBranch(store, target, branch, eval_order);
            if (!removed_later and try storeHasExactExtensionBranch(store, target, branch)) continue;
            try filtered_extender.selectors.append(self.allocator, try branch.clone(self.allocator));
        }
        if (filtered_extender.selectors.items.len == 0) return false;

        if (filtered_extender.selectors.items.len > 1 and shouldSplitBranchLocalExtender(&filtered_extender)) {
            var branch_pos: usize = 0;
            while (branch_pos < filtered_extender.selectors.items.len) : (branch_pos += 1) {
                const branch = &filtered_extender.selectors.items[branch_pos];
                var one_extender = SelectorList.init(self.allocator);
                errdefer one_extender.deinit();
                try one_extender.selectors.append(self.allocator, try branch.clone(self.allocator));

                var target_clone = try target.clone(self.allocator);
                errdefer target_clone.deinit();

                try store.addExtension(.{
                    .extender = one_extender,
                    .target = target_clone,
                    .optional = options.optional,
                    .span = options.span,
                    .eval_order = eval_order,
                    .statement_group_order = options.statement_group_order,
                    .statement_branch_index = @intCast(branch_pos),
                    .statement_order = options.statement_order,
                    .from_import_child = options.from_import_child,
                    .module_group_start_order = options.module_group_start_order,
                    .is_propagated = options.is_propagated,
                });
                try self.module_edge_indices[idx].append(self.allocator, edge_idx);
            }

            if (self.module_next_eval_order[idx] != std.math.maxInt(u32)) {
                self.module_next_eval_order[idx] += 1;
            }
            return true;
        }

        var target_clone = try target.clone(self.allocator);
        errdefer target_clone.deinit();

        try store.addExtension(.{
            .extender = filtered_extender,
            .target = target_clone,
            .optional = options.optional,
            .span = options.span,
            .eval_order = eval_order,
            .statement_group_order = options.statement_group_order,
            .statement_order = options.statement_order,
            .statement_branch_index = null,
            .from_import_child = options.from_import_child,
            .module_group_start_order = options.module_group_start_order,
            .is_propagated = options.is_propagated,
        });
        try self.module_edge_indices[idx].append(self.allocator, edge_idx);

        if (self.module_next_eval_order[idx] != std.math.maxInt(u32)) {
            self.module_next_eval_order[idx] += 1;
        }
        return true;
    }

    /// Record an `@extend` whose target the module does not hold.
    pub fn addUnmatchedEdge(
        self: *RuleModuleExtendState,
        module_idx: usize,
        edge_idx: u32,
        source_module: u32,
        extender: *const SelectorList,
        target: *const CompoundSelector,
    ) !void {
        const store = &self.module_stores[self.moduleIndex(module_idx)];
        var extender_clone = try extender.clone(self.allocator);
        errdefer extender_clone.deinit();
        var target_clone = try target.clone(self.allocator);
        errdefer target_clone.deinit();
        try store.unmatched_hints.append(self.allocator, .{
            .extender = extender_clone,
            .target = target_clone,
            .optional = true,
            .span = null,
            .eval_order = edge_idx,
            .source_module = source_module,
        });
        store.own_module = @intCast(self.moduleIndex(module_idx));
        store.dropEngines();
    }

    /// Tell every store which module uses which.
    pub fn setVisibility(self: *RuleModuleExtendState, matrix: []const bool, n: u32) void {
        for (self.module_stores) |*store| {
            store.visibility = matrix;
            store.visibility_n = n;
        }
    }

    pub fn finalize(self: *RuleModuleExtendState) !void {
        var total: usize = 0;
        for (self.module_stores) |*store| {
            total = try std.math.add(usize, total, store.extensions.items.len);
        }
        const new_backing = try self.allocator.alloc(bool, total);

        self.allocator.free(self.module_matched_backing);
        self.module_matched_backing = new_backing;

        var offset: usize = 0;
        for (self.module_matched, 0..) |*matched, i| {
            const len = self.module_stores[i].extensions.items.len;
            matched.* = new_backing[offset..][0..len];
            @memset(matched.*, false);
            offset = try std.math.add(usize, offset, len);
        }
    }

    pub fn moduleHasExtensions(self: *const RuleModuleExtendState, module_idx: usize) bool {
        return self.moduleExtensionCount(module_idx) != 0;
    }

    pub fn moduleExtensionCount(self: *const RuleModuleExtendState, module_idx: usize) usize {
        const idx = self.moduleIndex(module_idx);
        return self.module_stores[idx].extensions.items.len;
    }

    pub fn moduleMatched(self: *RuleModuleExtendState, module_idx: usize) []bool {
        const idx = self.moduleIndex(module_idx);
        return self.module_matched[idx];
    }

    pub fn moduleEdgeIndices(self: *const RuleModuleExtendState, module_idx: usize) []const u32 {
        const idx = self.moduleIndex(module_idx);
        return self.module_edge_indices[idx].items;
    }

    pub fn moduleHasPropagatedExtensions(self: *const RuleModuleExtendState, module_idx: usize) bool {
        const idx = self.moduleIndex(module_idx);
        return self.module_stores[idx].hasPropagatedExtensions();
    }

    pub fn selectorHasAnyExtensionTarget(
        self: *const RuleModuleExtendState,
        module_idx: usize,
        selector_list: *const SelectorList,
    ) !bool {
        const idx = self.moduleIndex(module_idx);
        return self.module_stores[idx].selectorHasAnyExtensionTarget(selector_list);
    }

    pub fn markModuleMatchesNonPropagated(
        self: *RuleModuleExtendState,
        module_idx: usize,
        selector_list: *const SelectorList,
        matched: []bool,
    ) !void {
        const idx = self.moduleIndex(module_idx);
        try self.module_stores[idx].markMatchesNonPropagated(selector_list, matched);
    }

    fn moduleIndex(self: *const RuleModuleExtendState, module_idx: usize) usize {
        if (self.module_stores.len == 0) return 0;
        return if (module_idx < self.module_stores.len) module_idx else 0;
    }
};

pub const RuleApplyContext = struct {
    target_extend_order_snapshot: u32 = 0,
    target_is_direct_rule: bool = false,
};

pub fn applyExtendEdgesToSelectorWithContext(
    state: *RuleModuleExtendState,
    module_idx: usize,
    selector_list: *const SelectorList,
    rule_ctx: RuleApplyContext,
) !SelectorList {
    const idx = if (state.module_stores.len == 0)
        0
    else if (module_idx < state.module_stores.len)
        module_idx
    else
        0;
    return state.module_stores[idx].applySelectorExtensionsWithContext(selector_list, rule_ctx);
}

/// `selector.extend()`: every complex selector of `extendee` is a compound
/// whose simple selectors are extended together by `extender`.
pub fn applySelectorFunctionExtend(
    allocator: std.mem.Allocator,
    selector_list: *const SelectorList,
    extendee: *const SelectorList,
    extender: *const SelectorList,
) error{OutOfMemory}!SelectorList {
    return applySelectorFunction(allocator, selector_list, extendee, extender, false);
}

/// `selector.replace()`: the same, and what held the targets does not stay.
pub fn applySelectorFunctionReplace(
    allocator: std.mem.Allocator,
    selector_list: *const SelectorList,
    original: *const SelectorList,
    replacement: *const SelectorList,
) error{OutOfMemory}!SelectorList {
    return applySelectorFunction(allocator, selector_list, original, replacement, true);
}

fn applySelectorFunction(
    allocator: std.mem.Allocator,
    selector_list: *const SelectorList,
    extendee: *const SelectorList,
    extender: *const SelectorList,
    replace: bool,
) error{OutOfMemory}!SelectorList {
    var sources: std.ArrayList(extend_engine.Source) = .empty;
    defer sources.deinit(allocator);
    for (extendee.selectors.items, 0..) |*complex, index| {
        if (complex.components.items.len != 1 or complex.components.items[0] != .compound) continue;
        try sources.append(allocator, .{ .extender = extender, .target = &complex.components.items[0].compound, .order = @intCast(index) });
    }
    const engine = try extend_engine.Engine.init(allocator, sources.items, if (replace) .replace else .function) orelse return selector_list.clone(allocator);
    defer engine.deinit(allocator);
    return engine.extendSelector(allocator, selector_list, std.math.maxInt(u32));
}

fn extensionExtenderContainsTarget(ext: *const Extension, target: *const CompoundSelector) bool {
    for (ext.extender.selectors.items) |*complex| {
        if (compoundContainsTargetInComplex(complex, target)) return true;
    }
    return false;
}

fn shouldSplitBranchLocalExtender(extender: *const SelectorList) bool {
    if (extender.selectors.items.len <= 1) return false;
    const first = &extender.selectors.items[0];
    if (first.components.items.len < 3) return false;
    const first_first = firstCompound(first) orelse return false;
    const first_last = getLastCompound(first) orelse return false;

    for (extender.selectors.items[1..]) |*branch| {
        if (branch.components.items.len != first.components.items.len) return false;
        const branch_first = firstCompound(branch) orelse return false;
        const branch_last = getLastCompound(branch) orelse return false;
        if (branch_first.simple_selectors.items.len != first_first.simple_selectors.items.len) return false;
        if (!compoundsShareSimpleSelector(first_first, branch_first)) return false;
        if (!compoundSelectorEql(first_last, branch_last)) return false;
    }
    return true;
}

fn compoundsShareSimpleSelector(a: *const CompoundSelector, b: *const CompoundSelector) bool {
    for (a.simple_selectors.items) |a_ss| {
        for (b.simple_selectors.items) |b_ss| {
            if (simpleSelectorEql(a_ss, b_ss)) return true;
        }
    }
    return false;
}

// ============================================================================
// Core Algorithm
// ============================================================================

fn prefixHasSiblingCombinator(components: []const ComplexSelectorComponent) bool {
    for (components) |component| {
        if (component != .combinator) continue;
        if (component.combinator == .next_sibling or component.combinator == .general_sibling) return true;
    }
    return false;
}

fn complexHasSiblingCombinator(complex: *const ComplexSelector) bool {
    return prefixHasSiblingCombinator(complex.components.items);
}

fn compoundContainsTargetInComplex(complex: *const ComplexSelector, target: *const CompoundSelector) bool {
    for (complex.components.items) |comp| {
        switch (comp) {
            .compound => |c| {
                if (compoundContainsTarget(&c, target)) return true;
            },
            .combinator => {},
        }
    }
    return false;
}

fn complexContainsTargetInPseudos(
    complex: *const ComplexSelector,
    target: *const CompoundSelector,
) error{OutOfMemory}!bool {
    for (complex.components.items) |comp| {
        switch (comp) {
            .compound => |compound| {
                if (try compoundContainsTargetInPseudos(&compound, target)) return true;
            },
            .combinator => {},
        }
    }
    return false;
}

fn compoundContainsTargetInPseudos(
    compound: *const CompoundSelector,
    target: *const CompoundSelector,
) error{OutOfMemory}!bool {
    for (compound.simple_selectors.items) |ss| {
        switch (ss) {
            .pseudo_class => |ps| {
                if (ps.selector) |inner| {
                    for (inner.selectors.items) |inner_complex| {
                        if (compoundContainsTargetInComplex(&inner_complex, target)) return true;
                        if (try complexContainsTargetInPseudos(&inner_complex, target)) return true;
                    }
                }
            },
            .pseudo_element => |ps| {
                if (ps.selector) |inner| {
                    for (inner.selectors.items) |inner_complex| {
                        if (compoundContainsTargetInComplex(&inner_complex, target)) return true;
                        if (try complexContainsTargetInPseudos(&inner_complex, target)) return true;
                    }
                }
            },
            else => {},
        }
    }
    return false;
}

// ============================================================================
// Post-processing: selector pseudo coalescing, :not merging
// ============================================================================
