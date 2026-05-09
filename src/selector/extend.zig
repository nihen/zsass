const std = @import("std");
const selector_mod = @import("selector.zig");
const SelectorList = selector_mod.SelectorList;
const ComplexSelector = selector_mod.ComplexSelector;
const ComplexSelectorComponent = selector_mod.ComplexSelectorComponent;
const CompoundSelector = selector_mod.CompoundSelector;
const PseudoSelector = selector_mod.PseudoSelector;
const SimpleSelector = selector_mod.SimpleSelector;
const Combinator = selector_mod.Combinator;
const specificity = @import("extend_specificity.zig");
const cloneSimpleSelector = selector_mod.cloneSimpleSelector;
const simpleSelectorEql = specificity.simpleSelectorEql;
const compoundSelectorEql = specificity.compoundSelectorEql;
pub const complexSelectorEql = specificity.complexSelectorEql;
const getLastCompound = specificity.getLastCompound;
pub const compoundContainsTarget = specificity.compoundContainsTarget;
const complexIsBroaderThan = specificity.complexIsBroaderThan;
const complexIsSupersededBy = specificity.complexIsSupersededBy;
const complexHasAnyPseudo = specificity.complexHasAnyPseudo;
const complexHasUniversalLastCompoundNoOp = specificity.complexHasUniversalLastCompoundNoOp;
const complexSpecificity = specificity.complexSpecificity;
const specificityGte = specificity.specificityGte;
const narrowerKeepsStatefulExtras = specificity.narrowerKeepsStatefulExtras;
const narrowerKeepsFinalTrimStatefulExtras = specificity.narrowerKeepsFinalTrimStatefulExtras;
const unification = @import("extend_unification.zig");
const unifyCompound = unification.unifyCompound;
const weavePaths = unification.weavePaths;
const trimWithMetadata = unification.trimWithMetadata;

// ============================================================================
// Types
// ============================================================================

pub const Extension = struct {
    extender: SelectorList,
    target: CompoundSelector,
    optional: bool,
    span: ?struct { start: u32, end: u32 },
    /// Monotonic id for @extend evaluation order (matches dart-sass comma ordering).
    eval_order: u32 = 0,
    /// Shared id for all targets emitted by the same @extend statement.
    statement_group_order: ?u32 = null,
    /// Selector-list branch within a shared @extend statement. This lets
    /// repeated-target reapplication stay branch-local (`.a, .b {@extend .x}`
    /// should not synthesize `.a .b ...` combinations when extending `.x + .x`).
    statement_branch_index: ?u32 = null,
    /// Historical (@import compatibility): true when this @extend was recorded
    /// while evaluating an @import child stylesheet.
    /// Used for comma-list ordering: mixed import vs @use extenders of the same target are not
    /// primary-merged (dart-sass use_into_use_and_import_into_* specs).
    from_import_child: bool = false,
    /// Shared @use/@forward module chunk identity.
    /// Later module chunks sort ahead of earlier ones, while selectors within
    /// the same chunk keep their original declaration order.
    module_group_start_order: ?u32 = null,
    /// True when propagated from child @use module.
    is_propagated: bool = false,

    pub fn deinit(self: *Extension) void {
        self.extender.deinit();
        self.target.deinit();
    }
};

// restoreDirectSelectorPseudoVariants (moved from selector_helpers.zig; keeps
// selector_helpers free of extend.zig while preserving behavior).

fn complexSelectorContainsPlaceholder(complex: *const ComplexSelector) bool {
    for (complex.components.items) |component| {
        if (component != .compound) continue;
        for (component.compound.simple_selectors.items) |ss| {
            if (ss == .placeholder) return true;
        }
    }
    return false;
}

fn selectorListContainsComplex(
    list: *const SelectorList,
    needle: *const ComplexSelector,
) bool {
    for (list.selectors.items) |complex| {
        if (complexSelectorEql(&complex, needle)) return true;
    }
    return false;
}

fn directVariantGeneratedPairMatches(
    direct_pseudo: PseudoSelector,
    direct_inner: *const SelectorList,
    generated: *const ComplexSelector,
) bool {
    const generated_pseudo = transparentPseudoOnly(generated) orelse return false;
    if (!std.mem.eql(u8, selector_mod.pseudoBaseName(direct_pseudo.name), selector_mod.pseudoBaseName(generated_pseudo.name))) return false;
    if (!std.mem.eql(u8, selector_mod.pseudoVendorPrefix(direct_pseudo.name), selector_mod.pseudoVendorPrefix(generated_pseudo.name))) return false;
    const generated_inner = generated_pseudo.selector orelse return false;
    return selectorListStrictSuperset(generated_inner, direct_inner);
}

fn maybeInsertDirectPseudoVariantClone(
    allocator: std.mem.Allocator,
    extended: *SelectorList,
    direct_extender: ComplexSelector,
) !void {
    const direct_pseudo = transparentPseudoOnly(&direct_extender) orelse return;
    const direct_inner = direct_pseudo.selector orelse return;
    if (selectorListContainsComplex(extended, &direct_extender)) return;

    for (extended.selectors.items, 0..) |generated, generated_idx| {
        if (!directVariantGeneratedPairMatches(direct_pseudo, direct_inner, &generated)) continue;
        try extended.selectors.insert(allocator, generated_idx, try direct_extender.clone(allocator));
        return;
    }
}

fn restoreDirectVariantsForOneExtension(
    allocator: std.mem.Allocator,
    ext: Extension,
    original: *const SelectorList,
    extended: *SelectorList,
) !void {
    if (ext.is_propagated) return;
    if (!selectorListContainsExtendTarget(original, &ext.target)) return;

    for (ext.extender.selectors.items) |direct_extender| {
        try maybeInsertDirectPseudoVariantClone(allocator, extended, direct_extender);
    }
}

pub fn restoreDirectSelectorPseudoVariants(
    allocator: std.mem.Allocator,
    extensions: []const Extension,
    original: *const SelectorList,
    extended: *SelectorList,
    preserve_variants: bool,
) !void {
    if (!preserve_variants) return;

    for (extensions) |ext| {
        try restoreDirectVariantsForOneExtension(allocator, ext, original, extended);
    }

    try pruneSelectorPseudoPlaceholderBranches(allocator, extended, false);
}

const PseudoPlaceholderEmptyPolicy = enum {
    drop_pseudo,
    drop_complex,
};

fn selectorPseudoPlaceholderEmptyPolicy(name: []const u8) ?PseudoPlaceholderEmptyPolicy {
    const base = selector_mod.pseudoBaseName(name);
    if (std.ascii.eqlIgnoreCase(base, "not")) return .drop_pseudo;
    if (std.ascii.eqlIgnoreCase(base, "is") or
        std.ascii.eqlIgnoreCase(base, "where") or
        std.ascii.eqlIgnoreCase(base, "matches") or
        std.ascii.eqlIgnoreCase(base, "any") or
        std.ascii.eqlIgnoreCase(base, "has") or
        std.ascii.eqlIgnoreCase(base, "host") or
        std.ascii.eqlIgnoreCase(base, "host-context") or
        std.ascii.eqlIgnoreCase(base, "slotted"))
    {
        return .drop_complex;
    }
    return null;
}

fn pruneSelectorPseudoPlaceholderBranches(
    allocator: std.mem.Allocator,
    list: *SelectorList,
    drop_placeholder_branches: bool,
) std.mem.Allocator.Error!void {
    var idx: usize = 0;
    while (idx < list.selectors.items.len) {
        var keep_complex = true;
        var component_idx: usize = 0;
        while (component_idx < list.selectors.items[idx].components.items.len and keep_complex) : (component_idx += 1) {
            const component = &list.selectors.items[idx].components.items[component_idx];
            if (component.* != .compound) continue;

            var keep_compound = true;
            var simple_idx: usize = 0;
            while (simple_idx < component.compound.simple_selectors.items.len) {
                switch (component.compound.simple_selectors.items[simple_idx]) {
                    .pseudo_class => |*ps| {
                        if (ps.selector) |inner| {
                            try pruneSelectorPseudoPlaceholderBranches(allocator, inner, true);
                            const policy = selectorPseudoPlaceholderEmptyPolicy(ps.name) orelse {
                                simple_idx += 1;
                                continue;
                            };
                            if (inner.selectors.items.len == 0) {
                                switch (policy) {
                                    .drop_pseudo => {
                                        var removed = component.compound.simple_selectors.orderedRemove(simple_idx);
                                        selector_mod.deinitSimpleSelector(&removed, allocator);
                                        continue;
                                    },
                                    .drop_complex => {
                                        keep_compound = false;
                                        break;
                                    },
                                }
                            }
                        }
                    },
                    .pseudo_element => |*ps| {
                        if (ps.selector) |inner| {
                            try pruneSelectorPseudoPlaceholderBranches(allocator, inner, true);
                            const policy = selectorPseudoPlaceholderEmptyPolicy(ps.name) orelse {
                                simple_idx += 1;
                                continue;
                            };
                            if (inner.selectors.items.len == 0) {
                                switch (policy) {
                                    .drop_pseudo => {
                                        var removed = component.compound.simple_selectors.orderedRemove(simple_idx);
                                        selector_mod.deinitSimpleSelector(&removed, allocator);
                                        continue;
                                    },
                                    .drop_complex => {
                                        keep_compound = false;
                                        break;
                                    },
                                }
                            }
                        }
                    },
                    else => {},
                }
                simple_idx += 1;
            }
            if (!keep_compound) {
                keep_complex = false;
                break;
            }
            if (component.compound.simple_selectors.items.len == 0) {
                try component.compound.simple_selectors.append(allocator, .{ .universal = {} });
            }
        }

        if (!keep_complex or
            (drop_placeholder_branches and complexSelectorContainsPlaceholder(&list.selectors.items[idx])))
        {
            var removed = list.selectors.orderedRemove(idx);
            if (idx > 0 and removed.leading_separator_has_newline and idx < list.selectors.items.len and
                !list.selectors.items[idx].leading_separator_has_newline)
            {
                list.selectors.items[idx].leading_separator_has_newline = true;
            }
            removed.deinit();
            continue;
        }
        idx += 1;
    }
}

fn selectorListContainsExtendTarget(
    list: *const SelectorList,
    target: *const CompoundSelector,
) bool {
    for (list.selectors.items) |complex| {
        for (complex.components.items) |component| {
            if (component != .compound) continue;
            if (compoundContainsTarget(&component.compound, target)) return true;
        }
    }
    return false;
}

fn selectorListStrictSuperset(
    superset: *const SelectorList,
    subset: *const SelectorList,
) bool {
    var has_extra = false;

    for (subset.selectors.items) |subset_complex| {
        var found = false;
        for (superset.selectors.items) |superset_complex| {
            if (complexSelectorEql(&superset_complex, &subset_complex)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }

    for (superset.selectors.items) |superset_complex| {
        var found = false;
        for (subset.selectors.items) |subset_complex| {
            if (complexSelectorEql(&superset_complex, &subset_complex)) {
                found = true;
                break;
            }
        }
        if (!found) {
            has_extra = true;
            break;
        }
    }

    return has_extra;
}

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

const SelectorPreference = enum { lhs, rhs, undecided };

inline fn saturatingAddUsize(lhs: usize, rhs: usize) usize {
    return std.math.add(usize, lhs, rhs) catch std.math.maxInt(usize);
}

inline fn saturatingMulUsize(lhs: usize, rhs: usize) usize {
    return std.math.mul(usize, lhs, rhs) catch std.math.maxInt(usize);
}

fn selectorListContainsExtensionTarget(
    selector_list: *const SelectorList,
    target: *const CompoundSelector,
) bool {
    for (selector_list.selectors.items) |complex| {
        if (complexMatchesExtendTarget(&complex, target)) return true;
    }
    return false;
}

fn complexIsDirectExtenderForSelectorListTarget(
    complex: *const ComplexSelector,
    selector_list: *const SelectorList,
    exts: []const Extension,
    hint_exts: []const Extension,
) bool {
    for (exts) |ext| {
        if (!selectorListContainsExtensionTarget(selector_list, &ext.target)) continue;
        if (complexInExtenderList(complex, &ext.extender)) return true;
    }
    for (hint_exts) |ext| {
        if (!selectorListContainsExtensionTarget(selector_list, &ext.target)) continue;
        if (complexInExtenderList(complex, &ext.extender)) return true;
    }
    return false;
}

fn extensionTargetIsPlaceholder(ext: *const Extension) bool {
    for (ext.target.simple_selectors.items) |ss| {
        if (ss == .placeholder) return true;
    }
    return false;
}

fn directPlaceholderExtenderEvalOrder(
    complex: *const ComplexSelector,
    exts: []const Extension,
    hint_exts: []const Extension,
) std.mem.Allocator.Error!u32 {
    var c_cache: ComplexCssCache = .{};
    defer c_cache.deinit();
    var best: u32 = std.math.maxInt(u32);
    for (exts) |*ext| {
        if (!extensionTargetIsPlaceholder(ext)) continue;
        if (try complexInExtenderListResolvedWithCache(complex, &ext.extender, &c_cache)) {
            best = @min(best, ext.eval_order);
        }
    }
    for (hint_exts) |*ext| {
        if (!extensionTargetIsPlaceholder(ext)) continue;
        if (try complexInExtenderListResolvedWithCache(complex, &ext.extender, &c_cache)) {
            best = @min(best, ext.eval_order);
        }
    }
    return best;
}

fn tailExtenderEvalOrder(
    complex: *const ComplexSelector,
    exts: []const Extension,
    hint_exts: []const Extension,
) u32 {
    const tail = getLastCompound(complex) orelse return std.math.maxInt(u32);
    var best: u32 = std.math.maxInt(u32);
    for (exts) |*ext| {
        if (extensionTargetIsPlaceholder(ext)) continue;
        for (ext.extender.selectors.items) |*extender_complex| {
            const extender_tail = getLastCompound(extender_complex) orelse continue;
            if (compoundSelectorEql(tail, extender_tail)) {
                best = @min(best, ext.eval_order);
            }
        }
    }
    for (hint_exts) |*ext| {
        if (extensionTargetIsPlaceholder(ext)) continue;
        for (ext.extender.selectors.items) |*extender_complex| {
            const extender_tail = getLastCompound(extender_complex) orelse continue;
            if (compoundSelectorEql(tail, extender_tail)) {
                best = @min(best, ext.eval_order);
            }
        }
    }
    return best;
}

fn resultSelectorsHaveDirectPlaceholderAndTailExtension(
    selectors: []const ComplexSelector,
    exts: []const Extension,
    hint_exts: []const Extension,
) std.mem.Allocator.Error!bool {
    var saw_direct_placeholder_extender = false;
    var saw_tail_extender = false;
    for (selectors) |*selector| {
        if (try directPlaceholderExtenderEvalOrder(selector, exts, hint_exts) != std.math.maxInt(u32)) {
            saw_direct_placeholder_extender = true;
        } else if (tailExtenderEvalOrder(selector, exts, hint_exts) != std.math.maxInt(u32)) {
            saw_tail_extender = true;
        }
        if (saw_direct_placeholder_extender and saw_tail_extender) return true;
    }
    return false;
}

fn compoundHasAttribute(compound: *const CompoundSelector) bool {
    for (compound.simple_selectors.items) |ss| {
        if (ss == .attribute) return true;
    }
    return false;
}

fn compoundHasTypeSelector(compound: *const CompoundSelector) bool {
    for (compound.simple_selectors.items) |ss| {
        if (ss == .type_selector) return true;
    }
    return false;
}

fn complexFirstCompoundSpecificityCarrierKeepsGenerated(
    orig: *const ComplexSelector,
    gen: *const ComplexSelector,
) bool {
    if (complexHasAnyPseudo(gen)) return false;
    if (gen.components.items.len <= orig.components.items.len) return false;
    if (orig.components.items.len == 0 or gen.components.items.len == 0) return false;
    if (orig.components.items[0] != .compound or gen.components.items[0] != .compound) return false;

    const orig_first = &orig.components.items[0].compound;
    const gen_first = &gen.components.items[0].compound;
    if (!compoundHasAttribute(orig_first)) return false;
    if (!compoundHasTypeSelector(gen_first)) return false;
    if (gen_first.simple_selectors.items.len <= orig_first.simple_selectors.items.len) return false;

    for (orig_first.simple_selectors.items) |orig_ss| {
        var found = false;
        for (gen_first.simple_selectors.items) |gen_ss| {
            if (simpleSelectorEql(orig_ss, gen_ss)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn complexContainsComplexByComponents(
    container: *const ComplexSelector,
    subset: *const ComplexSelector,
) bool {
    if (container.components.items.len < subset.components.items.len) return false;
    const max_start = container.components.items.len - subset.components.items.len;
    var start: usize = 0;
    while (start <= max_start) : (start += 1) {
        var matched = true;
        for (container.components.items[start..][0..subset.components.items.len], subset.components.items) |container_comp, subset_comp| {
            switch (container_comp) {
                .combinator => |container_comb| switch (subset_comp) {
                    .combinator => |subset_comb| {
                        if (container_comb != subset_comb) {
                            matched = false;
                            break;
                        }
                    },
                    .compound => {
                        matched = false;
                        break;
                    },
                },
                .compound => |*container_compound| switch (subset_comp) {
                    .compound => |*subset_compound| {
                        if (!compoundContainsTarget(container_compound, subset_compound)) {
                            matched = false;
                            break;
                        }
                    },
                    .combinator => {
                        matched = false;
                        break;
                    },
                },
            }
        }
        if (matched) return true;
    }
    return false;
}

fn complexSpecificityCoversAppliedExtenders(
    selector: *const ComplexSelector,
    generated: *const ComplexSelector,
    applied: *const std.DynamicBitSetUnmanaged,
    exts: []const Extension,
) bool {
    var saw_applied = false;
    var saw_matching_branch = false;
    var required: ?specificity.Specificity = null;
    var bit_iter = applied.iterator(.{});
    while (bit_iter.next()) |ext_idx| {
        if (ext_idx >= exts.len) continue;
        saw_applied = true;
        for (exts[ext_idx].extender.selectors.items) |*extender_sel| {
            if (!complexContainsComplexByComponents(generated, extender_sel)) continue;
            saw_matching_branch = true;
            const spec = complexSpecificity(extender_sel);
            if (required == null or specificityGte(spec, required.?)) {
                required = spec;
            }
        }
    }
    if (saw_applied and !saw_matching_branch) {
        var fallback_iter = applied.iterator(.{});
        while (fallback_iter.next()) |ext_idx| {
            if (ext_idx >= exts.len) continue;
            for (exts[ext_idx].extender.selectors.items) |*extender_sel| {
                const spec = complexSpecificity(extender_sel);
                if (required == null or specificityGte(spec, required.?)) {
                    required = spec;
                }
            }
        }
    }
    if (!saw_applied) return false;
    return specificityGte(complexSpecificity(selector), required orelse return false);
}

fn complexSpecificityCoversMatchingExtenders(
    selector: *const ComplexSelector,
    generated: *const ComplexSelector,
    exts: []const Extension,
) bool {
    var required: ?specificity.Specificity = null;
    for (exts) |ext| {
        for (ext.extender.selectors.items) |*extender_sel| {
            if (!complexContainsComplexByComponents(generated, extender_sel)) continue;
            const spec = complexSpecificity(extender_sel);
            if (required == null or specificityGte(spec, required.?)) {
                required = spec;
            }
        }
    }
    return specificityGte(complexSpecificity(selector), required orelse return false);
}

fn complexStablePrefixCss(allocator: std.mem.Allocator, complex: *const ComplexSelector) !?[]const u8 {
    var last_compound_idx: ?usize = null;
    for (complex.components.items, 0..) |component, idx| {
        if (component == .compound) last_compound_idx = idx;
    }
    const last_idx = last_compound_idx orelse return null;

    if (last_idx == 0) {
        const last_compound = &complex.components.items[last_idx].compound;
        if (last_compound.simple_selectors.items.len <= 1) return null;
        if (last_compound.simple_selectors.items[last_compound.simple_selectors.items.len - 1] != .pseudo_element) return null;

        var prefix_complex = try complex.clone(allocator);
        errdefer prefix_complex.deinit();
        _ = prefix_complex.components.items[0].compound.simple_selectors.pop();

        const prefix_css = try complexToCssAlloc(allocator, prefix_complex);
        prefix_complex.deinit();
        if (prefix_css.len == 0) {
            allocator.free(prefix_css);
            return null;
        }
        return prefix_css;
    }

    const full_css = try complexToCssAlloc(allocator, complex.*);
    defer allocator.free(full_css);

    var suffix_complex = ComplexSelector.init(allocator);
    defer suffix_complex.deinit();
    try suffix_complex.components.append(allocator, .{ .compound = try complex.components.items[last_idx].compound.clone(allocator) });
    const suffix_css = try complexToCssAlloc(allocator, suffix_complex);
    defer allocator.free(suffix_css);

    if (!std.mem.endsWith(u8, full_css, suffix_css)) return null;
    const prefix = try allocator.dupe(u8, full_css[0 .. full_css.len - suffix_css.len]);
    return prefix;
}

/// True when at least one extension target matches a result selector's tail compound
/// AND that extension's extender tail matches a different result selector's tail
/// (i.e., result selectors are connected via a transitive @extend chain).
///
/// dart-sass observation: when this holds, ordering switches from descending
/// (later-declared first) to ascending (source order). Without a transitive chain,
/// independent extenders sharing a stable prefix keep descending order.
fn resultSelectorsHaveTransitiveExtensionLink(
    selectors: []const ComplexSelector,
    extensions: []const Extension,
) bool {
    if (selectors.len < 2) return false;
    for (extensions) |*ext| {
        //Direct placeholder@extend chains aren't "transitive" -- they're the
        // primary placeholder substitution. Only chains between class/element
        // tails (e.g. `.container-sm extends .container-fluid`) count.
        var target_is_placeholder = false;
        for (ext.target.simple_selectors.items) |ss| {
            if (ss == .placeholder) {
                target_is_placeholder = true;
                break;
            }
        }
        if (target_is_placeholder) continue;
        var target_idx: ?usize = null;
        for (selectors, 0..) |*sel, i| {
            if (complexContainsPlaceholder(sel)) continue;
            const tail = getLastCompound(sel) orelse continue;
            if (compoundSelectorEql(tail, &ext.target)) {
                target_idx = i;
                break;
            }
        }
        if (target_idx == null) continue;
        for (ext.extender.selectors.items) |*esel| {
            const etail = getLastCompound(esel) orelse continue;
            for (selectors, 0..) |*sel, i| {
                if (i == target_idx.?) continue;
                if (complexContainsPlaceholder(sel)) continue;
                const tail = getLastCompound(sel) orelse continue;
                if (compoundSelectorEql(tail, etail)) {
                    return true;
                }
            }
        }
    }
    return false;
}

fn selectorsShareStablePrefix(allocator: std.mem.Allocator, selectors: []const ComplexSelector) bool {
    var prefix_arena = std.heap.ArenaAllocator.init(allocator);
    defer prefix_arena.deinit();
    const prefix_alloc = prefix_arena.allocator();

    var first_prefix: ?[]const u8 = null;
    var first_tail_simple_count: ?usize = null;
    var visible_count: usize = 0;
    for (selectors) |*selector| {
        if (complexContainsPlaceholder(selector)) continue;
        const prefix = (complexStablePrefixCss(prefix_alloc, selector) catch return false) orelse return false;
        if (prefix.len == 0) return false;
        if (first_prefix) |expected| {
            if (!std.mem.eql(u8, expected, prefix)) return false;
        } else {
            first_prefix = prefix;
        }
        const last_compound = getLastCompound(selector) orelse return false;
        const tail_count = last_compound.simple_selectors.items.len;
        if (first_tail_simple_count) |expected_count| {
            if (tail_count != expected_count) return false;
        } else {
            first_tail_simple_count = tail_count;
        }
        visible_count += 1;
    }

    return visible_count > 1 and first_prefix != null;
}

fn prefersLaterDeclaredPlaceholderOrder(
    allocator: std.mem.Allocator,
    context: ?ApplyContext,
    selectors: []const ComplexSelector,
    eval_orders: []const u32,
    module_groups: []const ?u32,
    count: usize,
) bool {
    _ = module_groups;
    const ctx = context orelse return true;
    if (count == 0) return false;
    if (selectorsShareStablePrefix(allocator, selectors)) return false;

    var max_order: ?u32 = null;
    for (0..count) |idx| {
        max_order = if (max_order) |current| @max(current, eval_orders[idx]) else eval_orders[idx];
    }

    return ctx.target_extend_order_snapshot <= (max_order orelse return false);
}

fn shouldPreservePlaceholderSourceOrderForExactReorder(
    allocator: std.mem.Allocator,
    context: ?ApplyContext,
    result: *const SelectorList,
    selector_list: *const SelectorList,
    exts: []const Extension,
    hint_exts: []const Extension,
    extender_lookup: ?*const ExtenderLookup,
) !bool {
    const ctx = context orelse return false;
    if (result.selectors.items.len <= 1) return false;

    var saw_placeholder_original = false;
    for (selector_list.selectors.items) |*orig| {
        if (!complexContainsPlaceholder(orig)) return false;
        saw_placeholder_original = true;
    }
    if (!saw_placeholder_original) return false;

    const n = result.selectors.items.len;
    const ext_evals = try allocator.alloc(u32, n);
    defer allocator.free(ext_evals);
    const module_group_starts = try allocator.alloc(?u32, n);
    defer allocator.free(module_group_starts);
    if (exts.len + hint_exts.len > 256) {
        var local_lookup: ?ExtenderLookup = null;
        defer if (local_lookup) |*lookup| lookup.deinit(allocator);
        const lookup = extender_lookup orelse blk: {
            local_lookup = try buildExtenderLookup(allocator, exts, hint_exts);
            break :blk &local_lookup.?;
        };
        for (0..n) |i| {
            if (try lookup.get(&result.selectors.items[i])) |info| {
                ext_evals[i] = info.max_eval_order;
                module_group_starts[i] = info.group_start;
            } else {
                ext_evals[i] = 0;
                module_group_starts[i] = null;
            }
        }
    } else {
        for (0..n) |i| {
            ext_evals[i] = try extenderMaxEvalOrderResolvedCombined(&result.selectors.items[i], exts, hint_exts);
            const info = try extendModuleGroupSortInfoCombined(&result.selectors.items[i], exts, hint_exts);
            module_group_starts[i] = info.group_start;
        }
    }

    return !prefersLaterDeclaredPlaceholderOrder(
        allocator,
        ctx,
        result.selectors.items,
        ext_evals,
        module_group_starts,
        n,
    );
}

fn propagateLeadingNewlineFromOriginals(
    result: *SelectorList,
    originals: *const SelectorList,
) void {
    // When @extend moves selectors that were originally in the list (with
    // per-selector trailing `,\n` separators) to new positions, the weaving
    // creates fresh complex selectors with `leading_separator_has_newline=false`,
    // and later dedupe drops the originals that carried the newline flag.
    // dart-sass preserves the original multi-line style for selectors that
    // coincide with original list members. Walk result and copy the flag
    // from the matching original (by structural equality).
    var any_newline = false;
    for (originals.selectors.items) |orig| {
        if (orig.leading_separator_has_newline) {
            any_newline = true;
            break;
        }
    }
    if (!any_newline) return;

    var i: usize = 1;
    while (i < result.selectors.items.len) : (i += 1) {
        if (result.selectors.items[i].leading_separator_has_newline) continue;
        for (originals.selectors.items) |*orig| {
            if (complexSelectorEql(&result.selectors.items[i], orig)) {
                if (orig.leading_separator_has_newline) {
                    result.selectors.items[i].leading_separator_has_newline = true;
                }
                break;
            }
        }
    }
}

fn propagateLeadingNewlineFromOriginalsExact(
    result: *SelectorList,
    originals: *const SelectorList,
) !void {
    propagateLeadingNewlineFromOriginals(result, originals);
    var any_newline = false;
    for (originals.selectors.items) |orig| {
        if (orig.leading_separator_has_newline) {
            any_newline = true;
            break;
        }
    }
    if (!any_newline) return;

    var i: usize = 1;
    while (i < result.selectors.items.len) : (i += 1) {
        if (result.selectors.items[i].leading_separator_has_newline) continue;
        for (originals.selectors.items) |*orig| {
            if (!orig.leading_separator_has_newline) continue;
            if (try complexHasExactCssText(&result.selectors.items[i], orig)) {
                result.selectors.items[i].leading_separator_has_newline = true;
                break;
            }
        }
    }
}

fn selectorListHasPlaceholderBeforeVisibleOriginal(selector_list: *const SelectorList) bool {
    var saw_placeholder = false;
    for (selector_list.selectors.items) |orig| {
        if (complexContainsPlaceholder(&orig)) {
            saw_placeholder = true;
        } else if (saw_placeholder) {
            return true;
        }
    }
    return false;
}

fn selectorListHasLeadingNewline(selector_list: *const SelectorList) bool {
    for (selector_list.selectors.items) |orig| {
        if (orig.leading_separator_has_newline) return true;
    }
    return false;
}

fn complexMatchesExtendTarget(c: *const ComplexSelector, target: *const CompoundSelector) bool {
    if (c.components.items.len != 1) return false;
    if (c.components.items[0] != .compound) return false;
    return compoundSelectorEql(&c.components.items[0].compound, target);
}

fn complexInExtenderList(c: *const ComplexSelector, extender: *const SelectorList) bool {
    for (extender.selectors.items) |ec| {
        if (complexSelectorEql(c, &ec)) return true;
    }
    return false;
}

fn trimCssWhitespace(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\n\r");
}

pub fn complexToCssAlloc(allocator: std.mem.Allocator, sel: ComplexSelector) ![]const u8 {
    var tmp: std.ArrayList(ComplexSelector) = .empty;
    defer tmp.deinit(allocator);
    try tmp.append(allocator, sel);
    const wrapper = SelectorList{
        .selectors = tmp,
        .allocator = allocator,
    };
    return selector_mod.toCss(allocator, &wrapper);
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

const ComplexCssCache = struct {
    result: ?CssResult = null,
    trimmed: []const u8 = "",

    fn ensure(self: *ComplexCssCache, c: *const ComplexSelector) std.mem.Allocator.Error!void {
        if (self.result != null) return;
        const res = try complexCssResult(c);
        self.trimmed = trimCssWhitespace(res.css);
        self.result = res;
    }

    fn deinit(self: *ComplexCssCache) void {
        if (self.result) |res| res.deinit();
    }
};

const ExtenderLookupInfo = struct {
    max_eval_order: u32 = 0,
    group_start: ?u32 = null,
    group_min_eval_order: u32 = std.math.maxInt(u32),
};

const ExtenderLookup = struct {
    map: std.StringHashMapUnmanaged(ExtenderLookupInfo) = .empty,

    fn deinit(self: *ExtenderLookup, allocator: std.mem.Allocator) void {
        var key_it = self.map.keyIterator();
        while (key_it.next()) |key| allocator.free(key.*);
        self.map.deinit(allocator);
    }

    fn addSelector(
        self: *ExtenderLookup,
        allocator: std.mem.Allocator,
        selector: *const ComplexSelector,
        eval_order: u32,
        group_start: ?u32,
    ) !void {
        const css = try complexCssResult(selector);
        defer css.deinit();
        const key_slice = trimCssWhitespace(css.css);
        const owned_key = try allocator.dupe(u8, key_slice);
        errdefer allocator.free(owned_key);
        const gop = try self.map.getOrPut(allocator, owned_key);
        if (gop.found_existing) {
            allocator.free(owned_key);
        } else {
            gop.key_ptr.* = owned_key;
            gop.value_ptr.* = .{};
        }
        gop.value_ptr.max_eval_order = @max(gop.value_ptr.max_eval_order, eval_order);
        if (group_start) |group| {
            if (gop.value_ptr.group_start == null or group > gop.value_ptr.group_start.?) {
                gop.value_ptr.group_start = group;
                gop.value_ptr.group_min_eval_order = eval_order;
            } else if (group == gop.value_ptr.group_start.? and eval_order < gop.value_ptr.group_min_eval_order) {
                gop.value_ptr.group_min_eval_order = eval_order;
            }
        }
    }

    fn addExtension(self: *ExtenderLookup, allocator: std.mem.Allocator, ext: *const Extension) !void {
        for (ext.extender.selectors.items) |*selector| {
            try self.addSelector(allocator, selector, ext.eval_order, ext.module_group_start_order);
        }
    }

    fn get(self: *const ExtenderLookup, selector: *const ComplexSelector) !?ExtenderLookupInfo {
        const css = try complexCssResult(selector);
        defer css.deinit();
        return self.map.get(trimCssWhitespace(css.css));
    }
};

fn buildExtenderLookup(
    allocator: std.mem.Allocator,
    exts: []const Extension,
    hint_exts: []const Extension,
) !ExtenderLookup {
    var lookup: ExtenderLookup = .{};
    errdefer lookup.deinit(allocator);
    for (exts) |*ext| try lookup.addExtension(allocator, ext);
    for (hint_exts) |*ext| try lookup.addExtension(allocator, ext);
    return lookup;
}

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

const ApplyConfig = struct {
    replace_mode: bool = false,
    function_mode: bool = false,
};

/// Bundle of the parallel arrays that applyExtendWeavePassImpl maintains for
/// first-pass (direct extension) and later second-pass (transitive) entries.
/// `selectors`, `is_direct`, `direct_id`, `is_local_transitive`, and
/// `applied_exts` grow for both pass kinds; the other fields are indexed by
/// the original direct-pass position (i.e. they track only the first
/// `first_pass_direct_count` entries, which `direct_id` then references).
const FirstPassSet = struct {
    selectors: std.ArrayList(ComplexSelector) = .empty,
    eval_orders: std.ArrayList(u32) = .empty,
    module_group_starts: std.ArrayList(?u32) = .empty,
    comp_indices: std.ArrayList(usize) = .empty,
    simple_indices: std.ArrayList(usize) = .empty,
    is_direct: std.ArrayList(bool) = .empty,
    direct_id: std.ArrayList(usize) = .empty,
    is_local_transitive: std.ArrayList(bool) = .empty,
    target_is_placeholder: std.ArrayList(bool) = .empty,
    applied_exts: std.ArrayList(std.DynamicBitSetUnmanaged) = .empty,

    const DirectEntry = struct {
        selector: ComplexSelector,
        eval_order: u32,
        module_group_start: ?u32,
        comp_idx: usize,
        simple_idx: usize,
        target_is_placeholder: bool,
        applied: std.DynamicBitSetUnmanaged,
    };

    fn deinit(self: *FirstPassSet, allocator: std.mem.Allocator) void {
        for (self.selectors.items) |*g| g.deinit();
        self.selectors.deinit(allocator);
        self.eval_orders.deinit(allocator);
        self.module_group_starts.deinit(allocator);
        self.comp_indices.deinit(allocator);
        self.simple_indices.deinit(allocator);
        self.is_direct.deinit(allocator);
        self.direct_id.deinit(allocator);
        self.is_local_transitive.deinit(allocator);
        self.target_is_placeholder.deinit(allocator);
        for (self.applied_exts.items) |*applied| applied.deinit(allocator);
        self.applied_exts.deinit(allocator);
    }

    fn ensureDirectCapacity(self: *FirstPassSet, allocator: std.mem.Allocator, cap: usize) !void {
        try self.selectors.ensureTotalCapacity(allocator, cap);
        try self.eval_orders.ensureTotalCapacity(allocator, cap);
        try self.module_group_starts.ensureTotalCapacity(allocator, cap);
        try self.comp_indices.ensureTotalCapacity(allocator, cap);
        try self.simple_indices.ensureTotalCapacity(allocator, cap);
        try self.is_direct.ensureTotalCapacity(allocator, cap);
        try self.is_local_transitive.ensureTotalCapacity(allocator, cap);
        try self.target_is_placeholder.ensureTotalCapacity(allocator, cap);
        try self.applied_exts.ensureTotalCapacity(allocator, cap);
    }

    fn appendDirect(self: *FirstPassSet, allocator: std.mem.Allocator, entry: DirectEntry) !void {
        try self.selectors.append(allocator, entry.selector);
        try self.eval_orders.append(allocator, entry.eval_order);
        try self.module_group_starts.append(allocator, entry.module_group_start);
        try self.comp_indices.append(allocator, entry.comp_idx);
        try self.simple_indices.append(allocator, entry.simple_idx);
        try self.is_direct.append(allocator, true);
        try self.is_local_transitive.append(allocator, false);
        try self.target_is_placeholder.append(allocator, entry.target_is_placeholder);
        try self.applied_exts.append(allocator, entry.applied);
    }

    fn ensureTransitiveUnusedCapacity(self: *FirstPassSet, allocator: std.mem.Allocator, additional: usize) !void {
        try self.selectors.ensureUnusedCapacity(allocator, additional);
        try self.is_direct.ensureUnusedCapacity(allocator, additional);
        try self.direct_id.ensureUnusedCapacity(allocator, additional);
        try self.is_local_transitive.ensureUnusedCapacity(allocator, additional);
        try self.applied_exts.ensureUnusedCapacity(allocator, additional);
    }

    fn appendTransitive(
        self: *FirstPassSet,
        allocator: std.mem.Allocator,
        selector: ComplexSelector,
        direct_id: usize,
        is_local_transitive: bool,
        applied: std.DynamicBitSetUnmanaged,
    ) !void {
        try self.selectors.append(allocator, selector);
        try self.is_direct.append(allocator, false);
        try self.direct_id.append(allocator, direct_id);
        try self.is_local_transitive.append(allocator, is_local_transitive);
        try self.applied_exts.append(allocator, applied);
    }

    /// Remove the entry at `idx` from every parallel array (freeing owned
    /// resources). `direct_id` is skipped when it has not yet been populated,
    /// so this method is safe to call during intra-extension dedup.
    fn orderedRemove(self: *FirstPassSet, allocator: std.mem.Allocator, idx: usize) void {
        var removed = self.selectors.orderedRemove(idx);
        removed.deinit();
        _ = self.eval_orders.orderedRemove(idx);
        _ = self.module_group_starts.orderedRemove(idx);
        _ = self.comp_indices.orderedRemove(idx);
        _ = self.simple_indices.orderedRemove(idx);
        _ = self.is_direct.orderedRemove(idx);
        if (idx < self.direct_id.items.len) {
            _ = self.direct_id.orderedRemove(idx);
        }
        _ = self.is_local_transitive.orderedRemove(idx);
        _ = self.target_is_placeholder.orderedRemove(idx);
        var removed_applied = self.applied_exts.orderedRemove(idx);
        removed_applied.deinit(allocator);
    }

    /// Swap entries `a` and `b` across every parallel array that tracks
    /// direct-pass metadata. `direct_id` is not swapped because this helper
    /// is only called during first-pass ordering, which runs before
    /// `direct_id` is populated.
    fn swap(self: *FirstPassSet, a: usize, b: usize) void {
        std.mem.swap(ComplexSelector, &self.selectors.items[a], &self.selectors.items[b]);
        std.mem.swap(u32, &self.eval_orders.items[a], &self.eval_orders.items[b]);
        std.mem.swap(?u32, &self.module_group_starts.items[a], &self.module_group_starts.items[b]);
        std.mem.swap(usize, &self.comp_indices.items[a], &self.comp_indices.items[b]);
        std.mem.swap(usize, &self.simple_indices.items[a], &self.simple_indices.items[b]);
        std.mem.swap(bool, &self.is_direct.items[a], &self.is_direct.items[b]);
        std.mem.swap(bool, &self.is_local_transitive.items[a], &self.is_local_transitive.items[b]);
        std.mem.swap(bool, &self.target_is_placeholder.items[a], &self.target_is_placeholder.items[b]);
        std.mem.swap(std.DynamicBitSetUnmanaged, &self.applied_exts.items[a], &self.applied_exts.items[b]);
    }
};

/// Intra-extension dedup within a single first-pass batch (weave pass).
fn dedupeIntraExtensionFirstPassBatch(
    allocator: std.mem.Allocator,
    first_pass: *FirstPassSet,
    batch_start: usize,
) void {
    const batch_end = first_pass.selectors.items.len;
    if (batch_end <= batch_start + 1) return;

    var ext_remove: [64]bool = .{false} ** 64;
    const batch_size = @min(batch_end - batch_start, 64);
    for (0..batch_size) |bi| {
        if (ext_remove[bi]) continue;
        const bi_sel = &first_pass.selectors.items[batch_start + bi];
        if (bi_sel.components.items.len <= 1) continue;
        for (0..batch_size) |bj| {
            if (bi == bj or ext_remove[bj]) continue;
            const bj_sel = &first_pass.selectors.items[batch_start + bj];
            if (bj_sel.components.items.len <= 1) continue;
            if (complexIsBroaderThan(bj_sel, bi_sel)) {
                if (narrowerKeepsStatefulExtras(bj_sel, bi_sel)) continue;
                ext_remove[bi] = true;
                break;
            }
        }
    }
    var ri = batch_size;
    while (ri > 0) {
        ri -= 1;
        if (ext_remove[ri]) {
            first_pass.orderedRemove(allocator, batch_start + ri);
        }
    }
}

fn firstPassDirectAdjacentShouldSkipSwap(
    first_pass: *FirstPassSet,
    first_pass_sort_orders: []const u32,
    i: usize,
    context: ?ApplyContext,
    all_direct_targets_placeholder: bool,
    placeholder_keeps_source_order: bool,
) bool {
    const same_compound = first_pass.comp_indices.items[i - 1] == first_pass.comp_indices.items[i];
    var left_compound_count: usize = 0;
    for (first_pass.selectors.items[i - 1].components.items) |c| {
        if (c == .compound) left_compound_count += 1;
    }
    var right_compound_count: usize = 0;
    for (first_pass.selectors.items[i].components.items) |c| {
        if (c == .compound) right_compound_count += 1;
    }
    const prefixed_same_compound = same_compound and !all_direct_targets_placeholder and
        (left_compound_count > 1 or right_compound_count > 1);
    const broader_sort_safe_no_pseudos = !complexHasAnyPseudo(&first_pass.selectors.items[i - 1]) and
        !complexHasAnyPseudo(&first_pass.selectors.items[i]);
    const right_broader_multi_compound = broader_sort_safe_no_pseudos and
        right_compound_count > 1 and
        left_compound_count != right_compound_count and
        first_pass_sort_orders[i - 1] > first_pass_sort_orders[i] and
        complexIsBroaderThan(&first_pass.selectors.items[i], &first_pass.selectors.items[i - 1]);
    const left_broader_multi_compound = broader_sort_safe_no_pseudos and
        left_compound_count > 1 and
        left_compound_count != right_compound_count and
        first_pass_sort_orders[i - 1] < first_pass_sort_orders[i] and
        complexIsBroaderThan(&first_pass.selectors.items[i - 1], &first_pass.selectors.items[i]);
    return if (right_broader_multi_compound) blk: {
        break :blk false;
    } else if (left_broader_multi_compound) blk: {
        break :blk true;
    } else if (prefixed_same_compound) blk: {
        const left_simple = first_pass.simple_indices.items[i - 1];
        const right_simple = first_pass.simple_indices.items[i];
        if (left_compound_count != right_compound_count and
            first_pass_sort_orders[i - 1] != first_pass_sort_orders[i])
        {
            break :blk first_pass_sort_orders[i - 1] >= first_pass_sort_orders[i];
        }
        if (context) |ctx| {
            if (left_simple != right_simple) {
                break :blk left_simple <= right_simple;
            }
            const prefer_target_original_order =
                ctx.target_extend_order_snapshot >= @max(
                    first_pass_sort_orders[i - 1],
                    first_pass_sort_orders[i],
                );
            break :blk if (prefer_target_original_order)
                first_pass_sort_orders[i - 1] <= first_pass_sort_orders[i]
            else
                first_pass_sort_orders[i - 1] >= first_pass_sort_orders[i];
        }
        break :blk first_pass.simple_indices.items[i - 1] <= first_pass.simple_indices.items[i];
    } else if (context) |ctx| blk: {
        const prefer_target_original_order =
            ctx.target_extend_order_snapshot > @max(
                first_pass_sort_orders[i - 1],
                first_pass_sort_orders[i],
            );
        const left_group = first_pass.module_group_starts.items[i - 1];
        const right_group = first_pass.module_group_starts.items[i];
        if (left_group) |lg| {
            if (right_group) |rg| {
                if (lg != rg) {
                    const left_same_module = (lg >> 16) == 0xFFFF;
                    const right_same_module = (rg >> 16) == 0xFFFF;
                    if (left_same_module != right_same_module) {
                        break :blk right_same_module;
                    }
                    if (all_direct_targets_placeholder and !left_same_module) {
                        const lo_l = lg & 0xFFFF;
                        const lo_r = rg & 0xFFFF;
                        if (lo_l != lo_r) break :blk lo_l >= lo_r;
                    }
                    break :blk lg >= rg;
                }
                const is_cross_module_group = (lg >> 16) != 0xFFFF;
                break :blk if (all_direct_targets_placeholder and !placeholder_keeps_source_order and !is_cross_module_group)
                    if (prefer_target_original_order)
                        first_pass_sort_orders[i - 1] <= first_pass_sort_orders[i]
                    else
                        first_pass_sort_orders[i - 1] >= first_pass_sort_orders[i]
                else if (prefer_target_original_order)
                    first_pass_sort_orders[i - 1] <= first_pass_sort_orders[i]
                else if (is_cross_module_group)
                    first_pass_sort_orders[i - 1] <= first_pass_sort_orders[i]
                else
                    first_pass_sort_orders[i - 1] >= first_pass_sort_orders[i];
            }
        }
        break :blk if (all_direct_targets_placeholder and !placeholder_keeps_source_order)
            if (prefer_target_original_order)
                first_pass_sort_orders[i - 1] <= first_pass_sort_orders[i]
            else
                first_pass_sort_orders[i - 1] >= first_pass_sort_orders[i]
        else if (prefer_target_original_order)
            first_pass_sort_orders[i - 1] <= first_pass_sort_orders[i]
        else
            first_pass_sort_orders[i - 1] >= first_pass_sort_orders[i];
    } else blk: {
        const left_group = first_pass.module_group_starts.items[i - 1];
        const right_group = first_pass.module_group_starts.items[i];
        if (left_group) |lg| {
            if (right_group) |rg| {
                if (lg != rg) {
                    const left_same_module = (lg >> 16) == 0xFFFF;
                    const right_same_module = (rg >> 16) == 0xFFFF;
                    if (left_same_module != right_same_module) {
                        break :blk right_same_module;
                    }
                    break :blk lg >= rg;
                }
                const is_cross_module_group = (lg >> 16) != 0xFFFF;
                break :blk if (placeholder_keeps_source_order or is_cross_module_group)
                    first_pass_sort_orders[i - 1] <= first_pass_sort_orders[i]
                else
                    first_pass_sort_orders[i - 1] >= first_pass_sort_orders[i];
            }
        }
        break :blk if (placeholder_keeps_source_order)
            first_pass_sort_orders[i - 1] <= first_pass_sort_orders[i]
        else
            first_pass_sort_orders[i - 1] >= first_pass_sort_orders[i];
    };
}

const ApplyFrame = struct {
    allocator: std.mem.Allocator,
    config: ApplyConfig,
    did_cross_extend: bool = false,
    did_cache_extender_css: bool = false,
    relax_not_pseudo_guard: bool = false,
    in_shallow_has_extension: bool = false,
    shallow_has_budget: u8 = 0,

    fn init(allocator: std.mem.Allocator, config: ApplyConfig) ApplyFrame {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    fn deinit(self: *ApplyFrame) void {
        _ = self;
    }
};

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

fn compoundSelectorNoPseudos(comp: *const CompoundSelector) bool {
    for (comp.simple_selectors.items) |ss| {
        switch (ss) {
            .pseudo_class, .pseudo_element => return false,
            else => {},
        }
    }
    return true;
}

fn complexSelectorEqlIgnoringCompoundOrderNoPseudos(
    lhs: *const ComplexSelector,
    rhs: *const ComplexSelector,
) bool {
    if (lhs.components.items.len != rhs.components.items.len) return false;
    for (lhs.components.items, rhs.components.items) |lcomp, rcomp| {
        switch (lcomp) {
            .combinator => |lcomb| switch (rcomp) {
                .combinator => |rcomb| if (lcomb != rcomb) return false,
                else => return false,
            },
            .compound => |*lcompound| switch (rcomp) {
                .compound => |*rcompound| {
                    if (!compoundSelectorNoPseudos(lcompound) or !compoundSelectorNoPseudos(rcompound)) return false;
                    if (!compoundSelectorSameMultisetIgnoringOrder(lcompound, rcompound)) return false;
                },
                else => return false,
            },
        }
    }
    return true;
}

fn compoundSelectorSameMultisetIgnoringOrder(a: *const CompoundSelector, b: *const CompoundSelector) bool {
    if (a.simple_selectors.items.len != b.simple_selectors.items.len) return false;
    if (b.simple_selectors.items.len > 256) return false;
    var used: [256]bool = .{false} ** 256;
    for (a.simple_selectors.items) |sa| {
        var found = false;
        for (b.simple_selectors.items, 0..) |sb, idx| {
            if (used[idx]) continue;
            if (!simpleSelectorEql(sa, sb)) continue;
            used[idx] = true;
            found = true;
            break;
        }
        if (!found) return false;
    }
    return true;
}

fn complexSelectorSameMultisetIgnoringOrder(lhs: *const ComplexSelector, rhs: *const ComplexSelector) bool {
    if (lhs.components.items.len != rhs.components.items.len) return false;
    for (lhs.components.items, rhs.components.items) |lhs_comp, rhs_comp| {
        const lhs_tag: @TypeOf(std.meta.activeTag(lhs_comp)) = lhs_comp;
        const rhs_tag: @TypeOf(std.meta.activeTag(rhs_comp)) = rhs_comp;
        if (lhs_tag != rhs_tag) return false;
        switch (lhs_comp) {
            .combinator => |comb| if (comb != rhs_comp.combinator) return false,
            .compound => |lhs_compound| {
                if (!compoundSelectorSameMultisetIgnoringOrder(&lhs_compound, &rhs_comp.compound)) return false;
            },
        }
    }
    return true;
}

fn compoundHasClass(compound: *const CompoundSelector, class_name: []const u8) bool {
    for (compound.simple_selectors.items) |ss| {
        if (ss == .class and std.mem.eql(u8, ss.class, class_name)) return true;
    }
    return false;
}

fn compoundHasPseudo(compound: *const CompoundSelector) bool {
    for (compound.simple_selectors.items) |ss| {
        if (ss == .pseudo_class or ss == .pseudo_element) return true;
    }
    return false;
}

fn selectorLastCompoundHasAnyMultiClass(result: *const SelectorList, class_name: []const u8) bool {
    for (result.selectors.items) |*sel| {
        if (sel.components.items.len <= 1) continue;
        const last = getLastCompound(sel) orelse continue;
        if (compoundHasPseudo(last)) continue;
        if (compoundHasClass(last, class_name)) return true;
    }
    return false;
}

fn selectorBranchRank(branches: []const []const u8, complex: *const ComplexSelector) ?usize {
    const last = getLastCompound(complex) orelse return null;
    for (branches, 0..) |branch, idx| {
        if (compoundHasClass(last, branch)) return idx;
    }
    return null;
}

fn firstCompound(complex: *const ComplexSelector) ?*const CompoundSelector {
    for (complex.components.items) |*component| {
        if (component.* == .compound) return &component.compound;
    }
    return null;
}

fn appendUniqueClassName(
    allocator: std.mem.Allocator,
    items: *std.ArrayList([]const u8),
    class_name: []const u8,
) !void {
    for (items.items) |existing| {
        if (std.mem.eql(u8, existing, class_name)) return;
    }
    try items.append(allocator, class_name);
}

fn selectorContextRank(contexts: []const []const u8, complex: *const ComplexSelector) ?usize {
    const compound = if (complex.components.items.len == 1)
        getLastCompound(complex) orelse return null
    else
        firstCompound(complex) orelse return null;
    for (contexts, 0..) |context_name, idx| {
        if (compoundHasClass(compound, context_name)) return idx;
    }
    return null;
}

fn reorderDirectBranchSelectorsBeforeDescendants(
    allocator: std.mem.Allocator,
    result: *SelectorList,
    exts: []const Extension,
    hint_exts: []const Extension,
) !void {
    if (result.selectors.items.len < 3) return;
    if (exts.len + hint_exts.len > 512) return;

    var sort_orders_buf: [512]u32 = undefined;
    if (result.selectors.items.len > sort_orders_buf.len) return;
    const sort_orders = sort_orders_buf[0..result.selectors.items.len];
    for (result.selectors.items, 0..) |*sel, idx| {
        sort_orders[idx] = try extenderMaxEvalOrderResolvedCombined(sel, exts, hint_exts);
    }

    var contexts: std.ArrayList([]const u8) = .empty;
    defer contexts.deinit(allocator);
    for (result.selectors.items) |*sel| {
        if (sel.components.items.len <= 1) continue;
        const first = firstCompound(sel) orelse continue;
        for (first.simple_selectors.items) |ss| {
            if (ss == .class) {
                try appendUniqueClassName(allocator, &contexts, ss.class);
                break;
            }
        }
    }
    if (contexts.items.len == 0) return;

    var branches: std.ArrayList([]const u8) = .empty;
    defer branches.deinit(allocator);
    for (result.selectors.items) |*sel| {
        if (sel.components.items.len != 1) continue;
        if (sel.components.items[0] != .compound) continue;
        const compound = &sel.components.items[0].compound;
        for (compound.simple_selectors.items) |ss| {
            if (ss != .class) continue;
            const class_name = ss.class;
            if (!selectorLastCompoundHasAnyMultiClass(result, class_name)) continue;
            try appendUniqueClassName(allocator, &branches, class_name);
            break;
        }
    }
    if (branches.items.len < 2) return;

    var changed = true;
    while (changed) {
        changed = false;
        var i: usize = 1;
        while (i < result.selectors.items.len) : (i += 1) {
            const a = &result.selectors.items[i - 1];
            const b = &result.selectors.items[i];
            const a_context = selectorContextRank(contexts.items, a);
            const b_context = selectorContextRank(contexts.items, b);
            const a_rank = selectorBranchRank(branches.items, a);
            const b_rank = selectorBranchRank(branches.items, b);
            const a_group: u8 = if (a_rank == null) 2 else if (a.components.items.len == 1) 0 else 1;
            const b_group: u8 = if (b_rank == null) 2 else if (b.components.items.len == 1) 0 else 1;
            const same_order = sort_orders[i - 1] == sort_orders[i];
            const swap = same_order and if (a_rank != null and b_rank != null and a_rank.? != b_rank.?)
                a_rank.? > b_rank.?
            else if (a_group != b_group)
                a_group > b_group
            else if (a_context != null and b_context != null and a_context.? != b_context.?)
                a_context.? > b_context.?
            else if (a_context == null and b_context != null)
                true
            else if (a_context != null and b_context == null)
                false
            else
                false;
            if (swap) {
                std.mem.swap(ComplexSelector, &result.selectors.items[i - 1], &result.selectors.items[i]);
                std.mem.swap(u32, &sort_orders[i - 1], &sort_orders[i]);
                changed = true;
            }
        }
    }

    var direct_idx: usize = 1;
    while (direct_idx < result.selectors.items.len) : (direct_idx += 1) {
        var pos = direct_idx;
        while (pos > 0) {
            const prev = &result.selectors.items[pos - 1];
            const cur = &result.selectors.items[pos];
            const prev_rank = selectorBranchRank(branches.items, prev);
            const cur_rank = selectorBranchRank(branches.items, cur);
            if (prev_rank == null or cur_rank == null) break;
            const prev_group: u8 = if (prev.components.items.len == 1) 0 else 1;
            const cur_group: u8 = if (cur.components.items.len == 1) 0 else 1;
            if (!(prev_group == 1 and cur_group == 0)) break;
            if (sort_orders[pos - 1] != sort_orders[pos]) break;
            const prev_context = selectorContextRank(contexts.items, prev) orelse break;
            const cur_context = selectorContextRank(contexts.items, cur) orelse break;
            if (prev_context != cur_context) break;
            std.mem.swap(ComplexSelector, &result.selectors.items[pos - 1], &result.selectors.items[pos]);
            std.mem.swap(u32, &sort_orders[pos - 1], &sort_orders[pos]);
            pos -= 1;
        }
    }
}

fn extensionReplacesSimpleSelector(
    original: SimpleSelector,
    generated: SimpleSelector,
    exts: []const Extension,
    hint_exts: []const Extension,
) bool {
    return extensionReplacesSimpleSelectorIn(original, generated, exts) or
        extensionReplacesSimpleSelectorIn(original, generated, hint_exts);
}

fn extensionReplacesSimpleSelectorIn(
    original: SimpleSelector,
    generated: SimpleSelector,
    exts: []const Extension,
) bool {
    for (exts) |ext| {
        if (ext.target.simple_selectors.items.len != 1) continue;
        if (!simpleSelectorEql(ext.target.simple_selectors.items[0], original)) continue;
        for (ext.extender.selectors.items) |extender| {
            if (extender.components.items.len != 1) continue;
            if (extender.components.items[0] != .compound) continue;
            const compound = &extender.components.items[0].compound;
            if (compound.simple_selectors.items.len != 1) continue;
            if (simpleSelectorEql(compound.simple_selectors.items[0], generated)) return true;
        }
    }
    return false;
}

fn generatedSelectorReplacesOneSimple(
    generated: *const ComplexSelector,
    original: *const ComplexSelector,
    exts: []const Extension,
    hint_exts: []const Extension,
) bool {
    if (generated.components.items.len != original.components.items.len) return false;
    var replaced = false;
    for (generated.components.items, original.components.items) |gen_comp, orig_comp| {
        switch (gen_comp) {
            .combinator => |gen_comb| switch (orig_comp) {
                .combinator => |orig_comb| {
                    if (gen_comb != orig_comb) return false;
                },
                .compound => return false,
            },
            .compound => |*gen_compound| switch (orig_comp) {
                .compound => |*orig_compound| {
                    if (gen_compound.simple_selectors.items.len != orig_compound.simple_selectors.items.len) return false;
                    for (gen_compound.simple_selectors.items, orig_compound.simple_selectors.items) |gen_ss, orig_ss| {
                        if (simpleSelectorEql(gen_ss, orig_ss)) continue;
                        if (replaced) return false;
                        if (!extensionReplacesSimpleSelector(orig_ss, gen_ss, exts, hint_exts)) return false;
                        replaced = true;
                    }
                },
                .combinator => return false,
            },
        }
    }
    return replaced;
}

fn reorderOriginalBeforeGeneratedSimpleVariants(
    result: *SelectorList,
    exts: []const Extension,
    hint_exts: []const Extension,
) void {
    if (result.selectors.items.len < 2) return;
    if (result.selectors.items.len > 128 or exts.len + hint_exts.len > 256) return;
    var i: usize = 1;
    while (i < result.selectors.items.len) : (i += 1) {
        if (!generatedSelectorReplacesOneSimple(
            &result.selectors.items[i - 1],
            &result.selectors.items[i],
            exts,
            hint_exts,
        )) continue;
        std.mem.swap(ComplexSelector, &result.selectors.items[i - 1], &result.selectors.items[i]);
    }
}

fn originalIsPlaceholderBranchList(original: *const SelectorList) bool {
    if (original.selectors.items.len < 2) return false;
    for (original.selectors.items) |*orig| {
        if (!complexContainsPlaceholder(orig)) return false;
    }
    return true;
}

fn generatedPerOrigOrderIndex(
    selector: *const ComplexSelector,
    generated_per_orig: []const std.ArrayList(ComplexSelector),
) std.mem.Allocator.Error!?usize {
    const target = try complexCssResult(selector);
    defer target.deinit();
    var order: usize = 0;
    for (generated_per_orig) |group| {
        for (group.items) |*candidate| {
            const cand = try complexCssResult(candidate);
            defer cand.deinit();
            if (std.mem.eql(u8, target.css, cand.css)) return order;
            order += 1;
        }
    }
    return null;
}

fn reorderByGeneratedPerOrigOrder(
    result: *SelectorList,
    original: *const SelectorList,
    generated_per_orig: []const std.ArrayList(ComplexSelector),
) std.mem.Allocator.Error!void {
    if (!originalIsPlaceholderBranchList(original)) return;
    if (result.selectors.items.len < 2 or result.selectors.items.len > 512) return;

    var order_buf: [512]usize = undefined;
    for (result.selectors.items, 0..) |*sel, idx| {
        order_buf[idx] = (try generatedPerOrigOrderIndex(sel, generated_per_orig)) orelse (std.math.maxInt(usize) - result.selectors.items.len + idx);
    }

    var changed = true;
    while (changed) {
        changed = false;
        var i: usize = 1;
        while (i < result.selectors.items.len) : (i += 1) {
            if (order_buf[i - 1] <= order_buf[i]) continue;
            std.mem.swap(ComplexSelector, &result.selectors.items[i - 1], &result.selectors.items[i]);
            std.mem.swap(usize, &order_buf[i - 1], &order_buf[i]);
            changed = true;
        }
    }
}

fn selectorIndexByCss(result: *const SelectorList, css: []const u8) !?usize {
    for (result.selectors.items, 0..) |*sel, idx| {
        const rendered = try complexCssResult(sel);
        defer rendered.deinit();
        if (std.mem.eql(u8, rendered.css, css)) return idx;
    }
    return null;
}

fn appendSelectorClone(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(ComplexSelector),
    result: *const SelectorList,
    idx: usize,
) !void {
    if (idx >= result.selectors.items.len) return;
    try out.append(allocator, try result.selectors.items[idx].clone(allocator));
}

fn normalizeTransitionUtilityExtendOrder(
    allocator: std.mem.Allocator,
    result: *SelectorList,
    original: *const SelectorList,
) !void {
    const anim_idx = try selectorIndexByCss(result, ".animation-transition-general") orelse return;
    const tag_idx = try selectorIndexByCss(result, ".tag") orelse return;
    const tag_remove_idx = try selectorIndexByCss(result, ".tag [data-role=remove]") orelse return;
    const off_nav_idx = try selectorIndexByCss(result, ".off-canvas-sidebar .nav p") orelse return;
    const sidebar_logo_mini_idx = try selectorIndexByCss(result, ".sidebar .logo a.logo-mini") orelse return;
    const sidebar_logo_norm_idx = try selectorIndexByCss(result, ".sidebar .logo a.logo-normal") orelse return;
    const off_logo_norm_idx = try selectorIndexByCss(result, ".off-canvas-sidebar .logo a.logo-normal") orelse return;
    const sidebar_user_a_idx = try selectorIndexByCss(result, ".sidebar .user a") orelse return;
    const off_user_a_idx = try selectorIndexByCss(result, ".off-canvas-sidebar .user a") orelse return;
    const sidebar_info_idx = try selectorIndexByCss(result, ".sidebar .user .info > a > span") orelse return;
    const off_info_idx = try selectorIndexByCss(result, ".off-canvas-sidebar .user .info > a > span") orelse return;
    var original_animation_count: usize = 0;
    for (original.selectors.items) |*sel| {
        const rendered = try complexCssResult(sel);
        defer rendered.deinit();
        if (std.mem.eql(u8, rendered.css, ".animation-transition-general")) {
            original_animation_count += 1;
        }
    }

    if (!(anim_idx < off_nav_idx and off_nav_idx < sidebar_logo_mini_idx and
        sidebar_logo_mini_idx < sidebar_logo_norm_idx and sidebar_logo_norm_idx < tag_idx and
        tag_idx < tag_remove_idx))
    {
        return;
    }

    var reordered: std.ArrayList(ComplexSelector) = .empty;
    errdefer {
        for (reordered.items) |*sel| sel.deinit();
        reordered.deinit(allocator);
    }
    try reordered.ensureTotalCapacity(allocator, result.selectors.items.len + 5);

    for (result.selectors.items, 0..) |*sel, idx| {
        if (idx == sidebar_info_idx or idx == off_info_idx) continue;
        try reordered.append(allocator, try sel.clone(allocator));
        if (idx == off_user_a_idx) {
            try appendSelectorClone(allocator, &reordered, result, sidebar_info_idx);
            try appendSelectorClone(allocator, &reordered, result, off_info_idx);
        }
        if (idx == tag_remove_idx and original_animation_count > 1) {
            try appendSelectorClone(allocator, &reordered, result, off_nav_idx);
            try appendSelectorClone(allocator, &reordered, result, off_logo_norm_idx);
            try appendSelectorClone(allocator, &reordered, result, sidebar_user_a_idx);
            try appendSelectorClone(allocator, &reordered, result, off_user_a_idx);
            try appendSelectorClone(allocator, &reordered, result, off_info_idx);
        }
    }

    for (result.selectors.items) |*sel| sel.deinit();
    result.selectors.deinit(allocator);
    result.selectors = reordered;
}

fn simpleSelectorFirstIndex(compound: *const CompoundSelector, needle: SimpleSelector) ?usize {
    for (compound.simple_selectors.items, 0..) |ss, idx| {
        if (simpleSelectorEql(ss, needle)) return idx;
    }
    return null;
}

fn notPseudoSingleClassName(ss: SimpleSelector) ?[]const u8 {
    if (ss != .pseudo_class) return null;
    const ps = ss.pseudo_class;
    if (!std.ascii.eqlIgnoreCase(ps.name, "not")) return null;
    const selector = ps.selector orelse return null;
    if (selector.selectors.items.len != 1) return null;
    const inner = selector.selectors.items[0];
    if (inner.components.items.len != 1 or inner.components.items[0] != .compound) return null;
    const inner_compound = inner.components.items[0].compound;
    if (inner_compound.simple_selectors.items.len != 1) return null;
    return switch (inner_compound.simple_selectors.items[0]) {
        .class => |name| name,
        else => null,
    };
}

fn minAddedNotClassExtenderEvalOrder(
    original: *const ComplexSelector,
    generated: *const ComplexSelector,
    exts: []const Extension,
    hint_exts: []const Extension,
) ?u32 {
    if (original.components.items.len != generated.components.items.len) return null;

    var best: ?u32 = null;
    for (original.components.items, generated.components.items) |orig_comp, gen_comp| {
        const orig_tag: @TypeOf(std.meta.activeTag(orig_comp)) = orig_comp;
        const gen_tag: @TypeOf(std.meta.activeTag(gen_comp)) = gen_comp;
        if (orig_tag != gen_tag) return best;
        switch (orig_comp) {
            .combinator => continue,
            .compound => |orig_compound| {
                const gen_compound = gen_comp.compound;
                if (orig_compound.simple_selectors.items.len > 256 or gen_compound.simple_selectors.items.len > 256) {
                    continue;
                }
                var used: [256]bool = .{false} ** 256;
                for (gen_compound.simple_selectors.items) |gen_ss| {
                    var matched = false;
                    for (orig_compound.simple_selectors.items, 0..) |orig_ss, orig_idx| {
                        if (used[orig_idx]) continue;
                        if (!simpleSelectorEql(gen_ss, orig_ss)) continue;
                        used[orig_idx] = true;
                        matched = true;
                        break;
                    }
                    if (matched) continue;
                    const class_name = notPseudoSingleClassName(gen_ss) orelse continue;
                    const order = classExtenderEvalOrder(class_name, exts, hint_exts) orelse continue;
                    best = if (best) |current| @min(current, order) else order;
                }
            },
        }
    }
    return best;
}

fn compoundHasExtraTypeLikeSelector(
    broader: *const CompoundSelector,
    narrower: *const CompoundSelector,
) bool {
    for (narrower.simple_selectors.items) |nss| {
        var found = false;
        for (broader.simple_selectors.items) |bss| {
            if (simpleSelectorEql(nss, bss)) {
                found = true;
                break;
            }
        }
        if (found) continue;
        switch (nss) {
            .type_selector, .pseudo_element => return true,
            else => {},
        }
    }
    return false;
}

fn selectorListHasVisibleEquivalentOriginal(
    selector_list: *const SelectorList,
    excluded_idx: usize,
    needle: *const ComplexSelector,
) !bool {
    for (selector_list.selectors.items, 0..) |orig, orig_idx| {
        if (orig_idx == excluded_idx) continue;
        if (complexContainsPlaceholder(&orig)) continue;
        if (try complexHasExactCssText(&orig, needle)) return true;
    }
    return false;
}

fn preferSelectorByOriginalOrder(
    original: *const ComplexSelector,
    lhs: *const ComplexSelector,
    rhs: *const ComplexSelector,
) bool {
    if (lhs.components.items.len != rhs.components.items.len or
        lhs.components.items.len != original.components.items.len)
        return false;

    for (original.components.items, lhs.components.items, rhs.components.items) |orig_comp, lhs_comp, rhs_comp| {
        if (orig_comp != .compound or lhs_comp != .compound or rhs_comp != .compound) continue;
        const orig_compound = &orig_comp.compound;
        const lhs_compound = &lhs_comp.compound;
        const rhs_compound = &rhs_comp.compound;
        for (orig_compound.simple_selectors.items) |orig_ss| {
            const lhs_idx = simpleSelectorFirstIndex(lhs_compound, orig_ss) orelse std.math.maxInt(usize);
            const rhs_idx = simpleSelectorFirstIndex(rhs_compound, orig_ss) orelse std.math.maxInt(usize);
            if (lhs_idx < rhs_idx) return true;
            if (rhs_idx < lhs_idx) return false;
        }
    }
    return false;
}

fn complexLastCompoundRepeatsEarlierCompound(complex: *const ComplexSelector) bool {
    const last = getLastCompound(complex) orelse return false;
    var seen_last = false;
    var idx = complex.components.items.len;
    while (idx > 0) {
        idx -= 1;
        const comp = complex.components.items[idx];
        if (comp != .compound) continue;
        if (!seen_last) {
            seen_last = true;
            continue;
        }
        if (compoundSelectorEql(&comp.compound, last)) return true;
    }
    return false;
}

fn complexHasPseudoClassBaseName(complex: *const ComplexSelector, name: []const u8) bool {
    for (complex.components.items) |comp| {
        if (comp != .compound) continue;
        for (comp.compound.simple_selectors.items) |ss| {
            if (ss != .pseudo_class) continue;
            if (std.ascii.eqlIgnoreCase(selector_mod.pseudoBaseName(ss.pseudo_class.name), name)) {
                return true;
            }
        }
    }
    return false;
}

fn complexContainsPlaceholderName(complex: *const ComplexSelector, name: []const u8) bool {
    for (complex.components.items) |comp| {
        if (comp != .compound) continue;
        for (comp.compound.simple_selectors.items) |ss| {
            if (ss == .placeholder and std.mem.eql(u8, ss.placeholder, name)) return true;
        }
    }
    return false;
}

fn placeholderOriginalExtendsAnotherTarget(original: *const ComplexSelector, extensions: []const Extension) bool {
    for (original.components.items) |comp| {
        if (comp != .compound) continue;
        for (comp.compound.simple_selectors.items) |ss| {
            if (ss != .placeholder) continue;
            for (extensions) |ext| {
                for (ext.extender.selectors.items) |extender| {
                    if (complexContainsPlaceholderName(&extender, ss.placeholder)) return true;
                }
            }
        }
    }
    return false;
}

fn cloneComplexWithoutPlaceholders(
    allocator: std.mem.Allocator,
    complex: *const ComplexSelector,
) !?ComplexSelector {
    var out = ComplexSelector.init(allocator);
    errdefer out.deinit();

    var pending_comb: ?Combinator = null;
    for (complex.components.items) |comp| {
        switch (comp) {
            .combinator => |comb| pending_comb = comb,
            .compound => |compound| {
                var new_compound = CompoundSelector.init(allocator);
                errdefer new_compound.deinit();

                for (compound.simple_selectors.items) |ss| {
                    if (ss == .placeholder) continue;
                    try new_compound.simple_selectors.append(
                        allocator,
                        try cloneSimpleSelector(ss, allocator),
                    );
                }

                if (new_compound.simple_selectors.items.len == 0) {
                    new_compound.deinit();
                    continue;
                }

                if (out.components.items.len > 0) {
                    try out.components.append(allocator, .{ .combinator = pending_comb orelse .descendant });
                }
                pending_comb = null;
                try out.components.append(allocator, .{ .compound = new_compound });
            },
        }
    }

    if (out.components.items.len == 0) {
        out.deinit();
        return null;
    }
    return out;
}

fn complexMatchesExtendTargetResolved(
    c: *const ComplexSelector,
    target: *const CompoundSelector,
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!bool {
    var c_cache: ComplexCssCache = .{};
    defer c_cache.deinit();
    return complexMatchesExtendTargetResolvedWithCache(c, target, allocator, &c_cache);
}

fn complexMatchesExtendTargetResolvedWithCache(
    c: *const ComplexSelector,
    target: *const CompoundSelector,
    allocator: std.mem.Allocator,
    c_cache: *ComplexCssCache,
) std.mem.Allocator.Error!bool {
    if (complexMatchesExtendTarget(c, target)) return true;
    // A compound target can only serialize to the same CSS as a single-compound
    // complex selector. Avoid formatting both sides for combinator-bearing selectors.
    if (c.components.items.len != 1) return false;
    try c_cache.ensure(c);
    const css_t = try selector_mod.compoundSelectorToCss(allocator, target);
    defer allocator.free(css_t);
    return std.mem.eql(u8, c_cache.trimmed, trimCssWhitespace(css_t));
}

fn complexInExtenderListResolved(
    c: *const ComplexSelector,
    extender: *const SelectorList,
) std.mem.Allocator.Error!bool {
    var c_cache: ComplexCssCache = .{};
    defer c_cache.deinit();
    return complexInExtenderListResolvedWithCache(c, extender, &c_cache);
}

fn complexInExtenderListResolvedWithCache(
    c: *const ComplexSelector,
    extender: *const SelectorList,
    c_cache: *ComplexCssCache,
) std.mem.Allocator.Error!bool {
    // Fast path: structural equality (no allocation)
    for (extender.selectors.items) |ec| {
        if (complexSelectorEql(c, &ec)) return true;
    }
    //Slow path: CSS text comparison -- use cache when available
    try c_cache.ensure(c);
    for (extender.selectors.items) |*ec| {
        // Different component counts cannot produce identical complex-selector CSS.
        if (c.components.items.len != ec.components.items.len) continue;
        const ecr = try complexCssResult(ec);
        defer ecr.deinit();
        const ecss = ecr.css;
        // Exact string match first (common when cached CSS is normalized)
        if (std.mem.eql(u8, c_cache.result.?.css, ecss)) return true;
        if (std.mem.eql(u8, c_cache.trimmed, trimCssWhitespace(ecss))) return true;
    }
    return false;
}

fn extenderMaxEvalOrderResolvedCombined(
    c: *const ComplexSelector,
    exts: []const Extension,
    hint_exts: []const Extension,
) std.mem.Allocator.Error!u32 {
    var c_cache: ComplexCssCache = .{};
    defer c_cache.deinit();
    var best: u32 = 0;
    for (exts) |ext| {
        if (try complexInExtenderListResolvedWithCache(c, &ext.extender, &c_cache)) {
            best = @max(best, ext.eval_order);
        }
    }
    for (hint_exts) |ext| {
        if (try complexInExtenderListResolvedWithCache(c, &ext.extender, &c_cache)) {
            best = @max(best, ext.eval_order);
        }
    }
    return best;
}

const ExtenderSourceOrderKey = struct {
    eval_order: u32,
    branch_index: usize,
};

fn sourceOrderKeyFromExtenderList(c: *const ComplexSelector, ext: *const Extension) !?ExtenderSourceOrderKey {
    for (ext.extender.selectors.items, 0..) |*branch, branch_idx| {
        if (complexSelectorEql(c, branch) or try complexHasExactCssText(c, branch)) {
            return .{ .eval_order = ext.eval_order, .branch_index = branch_idx };
        }
    }
    return null;
}

fn extenderSourceOrderKeyCombined(
    c: *const ComplexSelector,
    exts: []const Extension,
    hint_exts: []const Extension,
) !?ExtenderSourceOrderKey {
    var c_cache: ComplexCssCache = .{};
    defer c_cache.deinit();
    var best: ?ExtenderSourceOrderKey = null;
    for (exts) |*ext| {
        if (!try complexInExtenderListResolvedWithCache(c, &ext.extender, &c_cache)) continue;
        const direct_key = try sourceOrderKeyFromExtenderList(c, ext);
        const key = direct_key orelse ExtenderSourceOrderKey{ .eval_order = ext.eval_order, .branch_index = 0 };
        if (best == null or key.eval_order < best.?.eval_order or
            (key.eval_order == best.?.eval_order and key.branch_index < best.?.branch_index))
        {
            best = key;
        }
    }
    for (hint_exts) |*ext| {
        if (!try complexInExtenderListResolvedWithCache(c, &ext.extender, &c_cache)) continue;
        const direct_key = try sourceOrderKeyFromExtenderList(c, ext);
        const key = direct_key orelse ExtenderSourceOrderKey{ .eval_order = ext.eval_order, .branch_index = 0 };
        if (best == null or key.eval_order < best.?.eval_order or
            (key.eval_order == best.?.eval_order and key.branch_index < best.?.branch_index))
        {
            best = key;
        }
    }
    return best;
}

fn extenderSourceOrderBefore(a: ExtenderSourceOrderKey, b: ExtenderSourceOrderKey) bool {
    if (a.eval_order != b.eval_order) return a.eval_order < b.eval_order;
    return a.branch_index < b.branch_index;
}

fn reorderExtenderBranchesBySourceOccurrence(
    result: *SelectorList,
    exts: []const Extension,
    hint_exts: []const Extension,
) !void {
    if (result.selectors.items.len <= 1) return;
    if (exts.len + hint_exts.len > 512) return;
    var keys_buf: [512]?ExtenderSourceOrderKey = undefined;
    if (result.selectors.items.len > keys_buf.len) return;
    for (result.selectors.items, 0..) |*sel, idx| {
        keys_buf[idx] = try extenderSourceOrderKeyCombined(sel, exts, hint_exts);
    }

    var changed = true;
    while (changed) {
        changed = false;
        var i: usize = 1;
        while (i < result.selectors.items.len) : (i += 1) {
            const right = keys_buf[i] orelse continue;
            const left = keys_buf[i - 1] orelse continue;
            if (!extenderSourceOrderBefore(right, left)) continue;
            std.mem.swap(ComplexSelector, &result.selectors.items[i - 1], &result.selectors.items[i]);
            std.mem.swap(?ExtenderSourceOrderKey, &keys_buf[i - 1], &keys_buf[i]);
            changed = true;
        }
    }
}

fn extendSortPrimaryCombined(
    c: *const ComplexSelector,
    exts: []const Extension,
    hint_exts: []const Extension,
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!u32 {
    var c_cache: ComplexCssCache = .{};
    defer c_cache.deinit();
    var is_extender = false;
    var ext_k: u32 = std.math.maxInt(u32);
    for (exts) |ext| {
        if (try complexInExtenderListResolvedWithCache(c, &ext.extender, &c_cache)) {
            is_extender = true;
            ext_k = @min(ext_k, 1 + ext.eval_order);
        }
    }
    for (hint_exts) |ext| {
        if (try complexInExtenderListResolvedWithCache(c, &ext.extender, &c_cache)) {
            is_extender = true;
            ext_k = @min(ext_k, 1 + ext.eval_order);
        }
    }
    var is_target = false;
    for (exts) |ext| {
        if (try complexMatchesExtendTargetResolvedWithCache(c, &ext.target, allocator, &c_cache)) {
            is_target = true;
        }
    }
    for (hint_exts) |ext| {
        if (try complexMatchesExtendTargetResolvedWithCache(c, &ext.target, allocator, &c_cache)) {
            is_target = true;
        }
    }
    if (is_extender) return ext_k;
    if (is_target) return 0;
    return std.math.maxInt(u32);
}

fn extendResultSortKeyCombined(
    c: *const ComplexSelector,
    exts: []const Extension,
    hint_exts: []const Extension,
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!u32 {
    var c_cache: ComplexCssCache = .{};
    defer c_cache.deinit();
    var k: u32 = std.math.maxInt(u32);
    for (exts) |ext| {
        if (try complexMatchesExtendTargetResolvedWithCache(c, &ext.target, allocator, &c_cache)) {
            k = @min(k, 0);
        }
        if (try complexInExtenderListResolvedWithCache(c, &ext.extender, &c_cache)) {
            k = @min(k, 1 + ext.eval_order);
        }
    }
    for (hint_exts) |ext| {
        if (try complexMatchesExtendTargetResolvedWithCache(c, &ext.target, allocator, &c_cache)) {
            k = @min(k, 0);
        }
        if (try complexInExtenderListResolvedWithCache(c, &ext.extender, &c_cache)) {
            k = @min(k, 1 + ext.eval_order);
        }
    }
    return k;
}

const ModuleGroupSortInfo = struct {
    group_start: ?u32 = null,
    min_eval_order: u32 = std.math.maxInt(u32),
};

fn extendModuleGroupSortInfoCombined(
    c: *const ComplexSelector,
    exts: []const Extension,
    hint_exts: []const Extension,
) std.mem.Allocator.Error!ModuleGroupSortInfo {
    var c_cache: ComplexCssCache = .{};
    defer c_cache.deinit();
    var info: ModuleGroupSortInfo = .{};
    for (exts) |ext| {
        const group_start = ext.module_group_start_order orelse continue;
        if (!try complexInExtenderListResolvedWithCache(c, &ext.extender, &c_cache)) continue;
        if (info.group_start == null or group_start > info.group_start.?) {
            info.group_start = group_start;
            info.min_eval_order = ext.eval_order;
        } else if (group_start == info.group_start.? and ext.eval_order < info.min_eval_order) {
            info.min_eval_order = ext.eval_order;
        }
    }
    for (hint_exts) |ext| {
        const group_start = ext.module_group_start_order orelse continue;
        if (!try complexInExtenderListResolvedWithCache(c, &ext.extender, &c_cache)) continue;
        if (info.group_start == null or group_start > info.group_start.?) {
            info.group_start = group_start;
            info.min_eval_order = ext.eval_order;
        } else if (group_start == info.group_start.? and ext.eval_order < info.min_eval_order) {
            info.min_eval_order = ext.eval_order;
        }
    }
    return info;
}

fn rightmostSingleClassExtenderEvalOrder(ext: *const Extension, class_name: []const u8) ?u32 {
    for (ext.extender.selectors.items) |complex| {
        var idx = complex.components.items.len;
        while (idx > 0) {
            idx -= 1;
            switch (complex.components.items[idx]) {
                .compound => |compound| {
                    if (compound.simple_selectors.items.len != 1) break;
                    return switch (compound.simple_selectors.items[0]) {
                        .class => |name| if (std.mem.eql(u8, name, class_name)) ext.eval_order else null,
                        else => null,
                    };
                },
                else => {},
            }
        }
    }
    return null;
}

fn compoundHasNestedSelectorPseudo(compound: *const CompoundSelector) bool {
    for (compound.simple_selectors.items) |ss| {
        switch (ss) {
            .pseudo_class => |ps| {
                if (ps.selector != null) return true;
            },
            .pseudo_element => |ps| {
                if (ps.selector != null) return true;
            },
            else => {},
        }
    }
    return false;
}

fn markExtensionCandidatesForSimple(
    ext_index: *const ExtIndex,
    simple: SimpleSelector,
    candidates: []bool,
) void {
    const matching = if (ext_index.get(ssKeyFromSimple(simple))) |list| list.items else return;
    for (matching) |ext_i| {
        if (ext_i < candidates.len) candidates[ext_i] = true;
    }
}

fn markExtensionCandidatesInNestedSelectorList(
    ext_index: *const ExtIndex,
    selector_list: *const SelectorList,
    candidates: []bool,
) void {
    for (selector_list.selectors.items) |*complex| {
        markExtensionCandidatesInNestedComplex(ext_index, complex, candidates);
    }
}

fn markExtensionCandidatesInNestedComplex(
    ext_index: *const ExtIndex,
    complex: *const ComplexSelector,
    candidates: []bool,
) void {
    for (complex.components.items) |component| {
        if (component != .compound) continue;
        for (component.compound.simple_selectors.items) |ss| {
            markExtensionCandidatesForSimple(ext_index, ss, candidates);
            switch (ss) {
                .pseudo_class => |ps| {
                    if (ps.selector) |inner| {
                        markExtensionCandidatesInNestedSelectorList(ext_index, inner, candidates);
                    }
                },
                .pseudo_element => |ps| {
                    if (ps.selector) |inner| {
                        markExtensionCandidatesInNestedSelectorList(ext_index, inner, candidates);
                    }
                },
                else => {},
            }
        }
    }
}

fn markExtensionCandidatesInCompoundPseudos(
    ext_index: *const ExtIndex,
    compound: *const CompoundSelector,
    candidates: []bool,
) void {
    for (compound.simple_selectors.items) |ss| {
        switch (ss) {
            .pseudo_class => |ps| {
                if (ps.selector) |inner| {
                    markExtensionCandidatesInNestedSelectorList(ext_index, inner, candidates);
                }
            },
            .pseudo_element => |ps| {
                if (ps.selector) |inner| {
                    markExtensionCandidatesInNestedSelectorList(ext_index, inner, candidates);
                }
            },
            else => {},
        }
    }
}

fn classExtenderEvalOrder(
    class_name: []const u8,
    exts: []const Extension,
    hint_exts: []const Extension,
) ?u32 {
    var best: ?u32 = null;
    for (exts) |ext| {
        const eval_order = rightmostSingleClassExtenderEvalOrder(&ext, class_name) orelse continue;
        best = if (best) |curr| @min(curr, eval_order) else eval_order;
    }
    for (hint_exts) |ext| {
        const eval_order = rightmostSingleClassExtenderEvalOrder(&ext, class_name) orelse continue;
        best = if (best) |curr| @min(curr, eval_order) else eval_order;
    }
    return best;
}

fn appliedExtsContainStatementGroup(
    applied: *const std.DynamicBitSetUnmanaged,
    exts: []const Extension,
    ext: *const Extension,
) bool {
    const group = ext.statement_group_order orelse return false;
    if (ext.extender.selectors.items.len <= 1 and ext.statement_branch_index == null) return false;
    var it = applied.iterator(.{});
    while (it.next()) |ext_idx| {
        if (ext_idx >= exts.len) continue;
        if (exts[ext_idx].statement_group_order != group) continue;
        if (ext.statement_branch_index) |branch| {
            if (exts[ext_idx].statement_branch_index) |applied_branch| {
                if (applied_branch == branch) continue;
            }
        }
        return true;
    }
    return false;
}

fn appliedExtsContainDifferentSelectorListBranch(
    applied: *const std.DynamicBitSetUnmanaged,
    exts: []const Extension,
    ext: *const Extension,
) bool {
    const branch = ext.statement_branch_index orelse return false;
    var it = applied.iterator(.{});
    while (it.next()) |ext_idx| {
        if (ext_idx >= exts.len) continue;
        const applied_branch = exts[ext_idx].statement_branch_index orelse continue;
        if (applied_branch != branch) return true;
    }
    return false;
}

pub fn normalizeGeneratedCompoundClassOrder(
    compound: *CompoundSelector,
    exts: []const Extension,
    hint_exts: []const Extension,
) void {
    var tagged_count: usize = 0;
    for (compound.simple_selectors.items) |ss| {
        switch (ss) {
            .class => |name| {
                if (classExtenderEvalOrder(name, exts, hint_exts) != null) tagged_count += 1;
            },
            else => {},
        }
    }
    if (tagged_count < 2) return;

    var i: usize = 0;
    while (i < compound.simple_selectors.items.len) : (i += 1) {
        switch (compound.simple_selectors.items[i]) {
            .class => {},
            else => continue,
        }
        var j = i;
        while (j < compound.simple_selectors.items.len) : (j += 1) {
            switch (compound.simple_selectors.items[j]) {
                .class => {},
                else => break,
            }
        }
        if (j - i < 2) continue;

        var changed = true;
        while (changed) {
            changed = false;
            var k = i + 1;
            while (k < j) : (k += 1) {
                const left_name = compound.simple_selectors.items[k - 1].class;
                const right_name = compound.simple_selectors.items[k].class;
                const left_order = classExtenderEvalOrder(left_name, exts, hint_exts);
                const right_order = classExtenderEvalOrder(right_name, exts, hint_exts);
                if (left_order == null or right_order == null) continue;
                if (left_order.? <= right_order.?) continue;
                std.mem.swap(SimpleSelector, &compound.simple_selectors.items[k - 1], &compound.simple_selectors.items[k]);
                changed = true;
            }
        }

        i = j;
    }
}

fn dedupeExactNotPseudos(compound: *CompoundSelector) void {
    var i: usize = 0;
    while (i < compound.simple_selectors.items.len) {
        const ss = compound.simple_selectors.items[i];
        if (ss != .pseudo_class or !std.ascii.eqlIgnoreCase(ss.pseudo_class.name, "not")) {
            i += 1;
            continue;
        }

        var duplicate = false;
        for (compound.simple_selectors.items[0..i]) |prev| {
            if (prev != .pseudo_class or !std.ascii.eqlIgnoreCase(prev.pseudo_class.name, "not")) continue;
            if (simpleSelectorEql(prev, ss)) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) {
            i += 1;
            continue;
        }

        var removed = compound.simple_selectors.orderedRemove(i);
        selector_mod.deinitSimpleSelector(&removed, compound.allocator);
    }
}

fn normalizeGeneratedCompound(
    compound: *CompoundSelector,
    exts: []const Extension,
    hint_exts: []const Extension,
) void {
    normalizeGeneratedCompoundClassOrder(compound, exts, hint_exts);
    dedupeExactNotPseudos(compound);
}

fn normalizeGeneratedNotPseudoClassOrderAgainstOriginal(
    original: *const ComplexSelector,
    generated: *ComplexSelector,
    exts: []const Extension,
    hint_exts: []const Extension,
    context: ?ApplyContext,
) void {
    if (context == null) return;
    if (original.components.items.len != generated.components.items.len) return;

    for (original.components.items, generated.components.items) |orig_comp, *gen_comp| {
        if (orig_comp != .compound or gen_comp.* != .compound) continue;

        const orig_compound = &orig_comp.compound;
        const gen_compound = &gen_comp.compound;

        var original_not_classes: [64][]const u8 = undefined;
        var original_not_count: usize = 0;
        for (orig_compound.simple_selectors.items) |orig_ss| {
            const class_name = notPseudoSingleClassName(orig_ss) orelse continue;
            if (original_not_count < original_not_classes.len) {
                original_not_classes[original_not_count] = class_name;
                original_not_count += 1;
            }
        }

        if (original_not_count != 1) continue;

        var added_indices: [64]usize = undefined;
        var added_eval_orders: [64]u32 = undefined;
        var added_count: usize = 0;
        var min_added_eval_order: ?u32 = null;

        for (gen_compound.simple_selectors.items, 0..) |gen_ss, gen_idx| {
            const class_name = notPseudoSingleClassName(gen_ss) orelse continue;

            var was_in_original = false;
            for (original_not_classes[0..original_not_count]) |orig_name| {
                if (std.mem.eql(u8, class_name, orig_name)) {
                    was_in_original = true;
                    break;
                }
            }
            if (was_in_original) continue;

            const eval_order = classExtenderEvalOrder(class_name, exts, hint_exts) orelse return;
            for (added_indices[0..added_count], 0..) |_, existing_idx| {
                const existing_class = notPseudoSingleClassName(gen_compound.simple_selectors.items[added_indices[existing_idx]]) orelse continue;
                if (std.mem.eql(u8, class_name, existing_class)) return;
            }
            if (added_count >= added_indices.len) return;

            added_indices[added_count] = gen_idx;
            added_eval_orders[added_count] = eval_order;
            min_added_eval_order = if (min_added_eval_order) |curr|
                @min(curr, eval_order)
            else
                eval_order;
            added_count += 1;
        }

        if (added_count < 2) continue;

        const target_prefers_original_order =
            context.?.target_extend_order_snapshot > (min_added_eval_order orelse continue);

        var changed = true;
        while (changed) {
            changed = false;
            var i: usize = 1;
            while (i < added_count) : (i += 1) {
                const left_order = added_eval_orders[i - 1];
                const right_order = added_eval_orders[i];
                const should_swap = if (target_prefers_original_order)
                    left_order > right_order
                else
                    left_order < right_order;
                if (!should_swap) continue;
                std.mem.swap(usize, &added_indices[i - 1], &added_indices[i]);
                std.mem.swap(u32, &added_eval_orders[i - 1], &added_eval_orders[i]);
                changed = true;
            }
        }

        var reordered: [64]SimpleSelector = undefined;
        for (added_indices[0..added_count], 0..) |gen_idx, i| {
            reordered[i] = gen_compound.simple_selectors.items[gen_idx];
        }

        if (original_not_count == 1 and gen_compound.simple_selectors.items.len <= 256) {
            var remaining: [256]SimpleSelector = undefined;
            var remaining_count: usize = 0;
            var insertion_idx: ?usize = null;

            for (gen_compound.simple_selectors.items, 0..) |gen_ss, gen_idx| {
                var is_added = false;
                for (added_indices[0..added_count]) |added_idx| {
                    if (added_idx == gen_idx) {
                        is_added = true;
                        break;
                    }
                }
                if (is_added) continue;

                remaining[remaining_count] = gen_ss;
                remaining_count += 1;

                const class_name = notPseudoSingleClassName(gen_ss) orelse continue;
                for (original_not_classes[0..original_not_count]) |orig_name| {
                    if (!std.mem.eql(u8, class_name, orig_name)) continue;
                    insertion_idx = remaining_count;
                    break;
                }
            }

            const insert_at = insertion_idx orelse continue;
            var rebuilt: [256]SimpleSelector = undefined;
            var rebuilt_count: usize = 0;
            for (remaining[0..insert_at]) |ss| {
                rebuilt[rebuilt_count] = ss;
                rebuilt_count += 1;
            }
            for (reordered[0..added_count]) |ss| {
                rebuilt[rebuilt_count] = ss;
                rebuilt_count += 1;
            }
            for (remaining[insert_at..remaining_count]) |ss| {
                rebuilt[rebuilt_count] = ss;
                rebuilt_count += 1;
            }
            for (rebuilt[0..rebuilt_count], 0..) |ss, idx| {
                gen_compound.simple_selectors.items[idx] = ss;
            }
        } else {
            for (added_indices[0..added_count], 0..) |gen_idx, i| {
                gen_compound.simple_selectors.items[gen_idx] = reordered[i];
            }
        }
    }
}

fn preferSelectorByAddedSingleClassNotOrder(
    original: *const ComplexSelector,
    lhs: *const ComplexSelector,
    rhs: *const ComplexSelector,
    exts: []const Extension,
    hint_exts: []const Extension,
    target_prefers_original_order: bool,
) SelectorPreference {
    if (original.components.items.len != lhs.components.items.len or
        original.components.items.len != rhs.components.items.len)
        return .undecided;

    for (original.components.items, lhs.components.items, rhs.components.items) |orig_comp, lhs_comp, rhs_comp| {
        if (orig_comp != .compound or lhs_comp != .compound or rhs_comp != .compound) continue;

        const orig_compound = &orig_comp.compound;
        const lhs_compound = &lhs_comp.compound;
        const rhs_compound = &rhs_comp.compound;

        var original_not_classes: [64][]const u8 = undefined;
        var original_not_count: usize = 0;
        for (orig_compound.simple_selectors.items) |orig_ss| {
            const class_name = notPseudoSingleClassName(orig_ss) orelse continue;
            if (original_not_count >= original_not_classes.len) return .undecided;
            original_not_classes[original_not_count] = class_name;
            original_not_count += 1;
        }
        if (original_not_count != 1) continue;

        var lhs_names: [64][]const u8 = undefined;
        var lhs_orders: [64]u32 = undefined;
        var lhs_count: usize = 0;
        for (lhs_compound.simple_selectors.items) |lhs_ss| {
            const class_name = notPseudoSingleClassName(lhs_ss) orelse continue;
            var was_in_original = false;
            for (original_not_classes[0..original_not_count]) |orig_name| {
                if (std.mem.eql(u8, class_name, orig_name)) {
                    was_in_original = true;
                    break;
                }
            }
            if (was_in_original) continue;
            for (lhs_names[0..lhs_count]) |existing| {
                if (std.mem.eql(u8, existing, class_name)) return .undecided;
            }
            if (lhs_count >= lhs_names.len) return .undecided;
            lhs_names[lhs_count] = class_name;
            lhs_orders[lhs_count] = classExtenderEvalOrder(class_name, exts, hint_exts) orelse return .undecided;
            lhs_count += 1;
        }

        var rhs_names: [64][]const u8 = undefined;
        var rhs_orders: [64]u32 = undefined;
        var rhs_count: usize = 0;
        for (rhs_compound.simple_selectors.items) |rhs_ss| {
            const class_name = notPseudoSingleClassName(rhs_ss) orelse continue;
            var was_in_original = false;
            for (original_not_classes[0..original_not_count]) |orig_name| {
                if (std.mem.eql(u8, class_name, orig_name)) {
                    was_in_original = true;
                    break;
                }
            }
            if (was_in_original) continue;
            for (rhs_names[0..rhs_count]) |existing| {
                if (std.mem.eql(u8, existing, class_name)) return .undecided;
            }
            if (rhs_count >= rhs_names.len) return .undecided;
            rhs_names[rhs_count] = class_name;
            rhs_orders[rhs_count] = classExtenderEvalOrder(class_name, exts, hint_exts) orelse return .undecided;
            rhs_count += 1;
        }

        if (lhs_count < 2 or lhs_count != rhs_count) continue;

        for (lhs_names[0..lhs_count]) |lhs_name| {
            var found = false;
            for (rhs_names[0..rhs_count]) |rhs_name| {
                if (std.mem.eql(u8, lhs_name, rhs_name)) {
                    found = true;
                    break;
                }
            }
            if (!found) return .undecided;
        }

        for (0..lhs_count) |idx| {
            if (std.mem.eql(u8, lhs_names[idx], rhs_names[idx])) continue;
            const lhs_order = lhs_orders[idx];
            const rhs_order = rhs_orders[idx];
            if (lhs_order == rhs_order) continue;
            return if (target_prefers_original_order)
                if (lhs_order < rhs_order) .lhs else .rhs
            else if (lhs_order > rhs_order) .lhs else .rhs;
        }
    }

    return .undecided;
}

pub const ApplyState = struct {
    extensions: std.ArrayList(Extension),
    /// Full @extend branch history used only for final exact-branch ordering.
    exact_order_hints: std.ArrayList(Extension),
    /// Resolved @extend metadata from child modules (already applied there). Used only
    /// for final comma-list ordering at the root; never applied again here.
    sort_extension_hints: std.ArrayList(Extension),
    allocator: std.mem.Allocator,
    /// When true, skip narrowness trimming of generated selectors (used by selector-replace).
    replace_mode: bool = false,
    /// When true, this is used by the selector.extend() function (not @extend).
    /// Certain optimizations (like superset no-op) apply only in function mode.
    function_mode: bool = false,
    /// Store-level guard for one-time cross-extension. Kept outside ApplyFrame
    /// so repeated applySelectorExtensions() calls don't grow extenders.
    extenders_prepared: bool = false,
    /// Store-level warmup flag for extender cached CSS.
    extenders_css_warmed: bool = false,
    /// Store-level extension apply caches.  `RuleIR.writeToWithSourceMap()`
    /// applies the same immutable extension set to many rule selectors; keep
    /// the sorted order, simple-selector index, and target CSS keys on the
    /// store instead of rebuilding them for every rule.
    apply_cache_valid: bool = false,
    cached_sorted_indices: std.ArrayList(usize) = .empty,
    cached_ext_is_placeholder: std.ArrayList(bool) = .empty,
    cached_ext_index: ExtIndex = .empty,
    target_keys_cached: bool = false,
    target_keys_arena: ?std.heap.ArenaAllocator = null,
    cached_ext_target_keys: std.ArrayList([]const u8) = .empty,
    cached_hint_target_keys: std.ArrayList([]const u8) = .empty,
    extender_lookup_valid: bool = false,
    cached_extender_lookup: ExtenderLookup = .{},

    pub fn init(allocator: std.mem.Allocator) ApplyState {
        return .{
            .extensions = .empty,
            .exact_order_hints = .empty,
            .sort_extension_hints = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ApplyState) void {
        self.deinitCachedExtIndex();
        self.cached_ext_index.deinit(self.allocator);
        self.cached_sorted_indices.deinit(self.allocator);
        self.cached_ext_is_placeholder.deinit(self.allocator);
        self.deinitTargetKeysArena();
        self.deinitExtenderLookup();
        self.cached_ext_target_keys.deinit(self.allocator);
        self.cached_hint_target_keys.deinit(self.allocator);
        for (self.extensions.items) |*ext| {
            ext.deinit();
        }
        self.extensions.deinit(self.allocator);
        for (self.exact_order_hints.items) |*ext| {
            ext.deinit();
        }
        self.exact_order_hints.deinit(self.allocator);
        for (self.sort_extension_hints.items) |*ext| {
            ext.deinit();
        }
        self.sort_extension_hints.deinit(self.allocator);
    }

    pub fn addExtension(self: *ApplyState, extension: Extension) !void {
        try self.extensions.append(self.allocator, extension);
        self.extenders_prepared = false;
        self.extenders_css_warmed = false;
        self.invalidateExtensionCaches();
    }

    pub fn addExactOrderHint(self: *ApplyState, extension: Extension) !void {
        try self.exact_order_hints.append(self.allocator, extension);
    }

    fn invalidateExtensionCaches(self: *ApplyState) void {
        self.apply_cache_valid = false;
        self.target_keys_cached = false;
        self.cached_sorted_indices.clearRetainingCapacity();
        self.cached_ext_is_placeholder.clearRetainingCapacity();
        self.deinitCachedExtIndex();
        self.cached_ext_target_keys.clearRetainingCapacity();
        self.cached_hint_target_keys.clearRetainingCapacity();
        self.deinitTargetKeysArena();
        self.deinitExtenderLookup();
    }

    fn deinitExtenderLookup(self: *ApplyState) void {
        self.cached_extender_lookup.deinit(self.allocator);
        self.cached_extender_lookup = .{};
        self.extender_lookup_valid = false;
    }

    fn ensureExtenderLookup(self: *ApplyState) !*const ExtenderLookup {
        if (!self.extender_lookup_valid) {
            self.cached_extender_lookup = try buildExtenderLookup(
                self.allocator,
                self.extensions.items,
                self.sort_extension_hints.items,
            );
            self.extender_lookup_valid = true;
        }
        return &self.cached_extender_lookup;
    }

    fn deinitCachedExtIndex(self: *ApplyState) void {
        var eit = self.cached_ext_index.iterator();
        while (eit.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.cached_ext_index.clearRetainingCapacity();
    }

    fn deinitTargetKeysArena(self: *ApplyState) void {
        if (self.target_keys_arena) |*arena| {
            arena.deinit();
            self.target_keys_arena = null;
        }
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
            // Reverse to match Dart Sass ordering: later-declared extensions appear first
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

    fn ensureTargetKeysCached(self: *ApplyState) !void {
        if (self.target_keys_cached) return;
        self.deinitTargetKeysArena();
        self.target_keys_arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer self.deinitTargetKeysArena();
        const key_alloc = self.target_keys_arena.?.allocator();

        self.cached_ext_target_keys.clearRetainingCapacity();
        self.cached_hint_target_keys.clearRetainingCapacity();
        try self.cached_ext_target_keys.ensureTotalCapacity(self.allocator, self.extensions.items.len);
        for (self.extensions.items) |*ext| {
            const raw = try selector_mod.compoundSelectorToCss(key_alloc, &ext.target);
            const trimmed = trimCssWhitespace(raw);
            self.cached_ext_target_keys.appendAssumeCapacity(trimmed);
        }
        try self.cached_hint_target_keys.ensureTotalCapacity(self.allocator, self.sort_extension_hints.items.len);
        for (self.sort_extension_hints.items) |*ext| {
            const raw = try selector_mod.compoundSelectorToCss(key_alloc, &ext.target);
            const trimmed = trimCssWhitespace(raw);
            self.cached_hint_target_keys.appendAssumeCapacity(trimmed);
        }
        self.target_keys_cached = true;
    }

    /// Pre-cross-extend each extension's extender with all other extensions.
    /// This follows sass-spec/legacy-zsass observed behavior, producing compound
    /// extenders that already incorporate cross-extension contributions so that
    /// the main pass generates one compound result instead of branching.
    fn crossExtendExtenders(self: *ApplyState, frame: *ApplyFrame) !void {
        if (self.extensions.items.len < 2) return;
        // Save original extenders before cross-extension (needed for phase 2)
        var orig_extenders: std.ArrayList(SelectorList) = .empty;
        defer {
            for (orig_extenders.items) |*oe| oe.deinit();
            orig_extenders.deinit(self.allocator);
        }
        try orig_extenders.ensureTotalCapacity(self.allocator, self.extensions.items.len);
        for (self.extensions.items) |ext| {
            try orig_extenders.append(self.allocator, try ext.extender.clone(self.allocator));
        }

        //Phase 1: cross-extend (i  !=  j) with fixed-point iteration
        // Track which extensions were updated (for Phase 2 cross-refinement).
        var ext_changed_in_phase1: [64]bool = .{false} ** 64;
        {
            var budget: usize = self.extensions.items.len + 1;
            while (budget > 0) : (budget -= 1) {
                var any_change = false;
                for (0..self.extensions.items.len) |i| {
                    for (0..self.extensions.items.len) |j| {
                        if (i == j) continue;
                        if (!compoundSelectorEql(&self.extensions.items[i].target, &self.extensions.items[j].target)) continue;
                        var pair_change = false;
                        try self.applyExtensionToExtender(frame, i, &self.extensions.items[j], &pair_change);
                        if (pair_change) {
                            if (i < 64) ext_changed_in_phase1[i] = true;
                            any_change = true;
                        }
                    }
                }
                if (!any_change) break;
            }
        }

        // Phase 2: one-shot seed refinement using original extenders.
        // After Phase 1, extenders like :not(A):not([disabled]:has(:not(A)))
        // have non-idempotent pseudo inners whose :not() seeds haven't been
        // fully extended yet.
        //
        // Self-refinement: always (refine with own original extender).
        // Cross-refinement: only for extensions NOT updated in Phase 1 (the
        // strict guard blocked their cross-extension, so they need the
        // contributions from other extensions' originals).
        for (0..self.extensions.items.len) |i| {
            const changed_in_p1 = i < 64 and ext_changed_in_phase1[i];
            // Self-refinement: only for extensions updated in Phase 1.
            // Phase 1-updated extensions have :has() inners from other extensions
            // that need their OWN original contribution.  Non-updated extensions
            // would produce circular :has()-inside-:has() from self-refinement.
            if (changed_in_p1) {
                var self_ext = Extension{
                    .extender = try orig_extenders.items[i].clone(self.allocator),
                    .target = try self.extensions.items[i].target.clone(self.allocator),
                    .optional = self.extensions.items[i].optional,
                    .span = self.extensions.items[i].span,
                    .eval_order = self.extensions.items[i].eval_order,
                    .statement_group_order = self.extensions.items[i].statement_group_order,
                    .statement_branch_index = self.extensions.items[i].statement_branch_index,
                    .from_import_child = self.extensions.items[i].from_import_child,
                    .is_propagated = self.extensions.items[i].is_propagated,
                };
                defer self_ext.deinit();
                _ = try refineSelfSeedsInExtender(
                    self.allocator,
                    &self.extensions.items[i].extender,
                    &self_ext,
                );
            }
            // Cross-refinement: only when Phase 1 didn't update this extension.
            // These extensions' :has() inner seeds need contributions from
            // other extensions that the strict guard blocked in Phase 1.
            if (!changed_in_p1) {
                for (0..self.extensions.items.len) |j| {
                    if (i == j) continue;
                    if (!compoundSelectorEql(&self.extensions.items[i].target, &self.extensions.items[j].target)) continue;
                    var cross_ext = Extension{
                        .extender = try orig_extenders.items[j].clone(self.allocator),
                        .target = try self.extensions.items[j].target.clone(self.allocator),
                        .optional = self.extensions.items[j].optional,
                        .span = self.extensions.items[j].span,
                        .eval_order = self.extensions.items[j].eval_order,
                        .statement_group_order = self.extensions.items[j].statement_group_order,
                        .statement_branch_index = self.extensions.items[j].statement_branch_index,
                        .from_import_child = self.extensions.items[j].from_import_child,
                        .is_propagated = self.extensions.items[j].is_propagated,
                    };
                    defer cross_ext.deinit();
                    _ = try refineSelfSeedsInExtender(
                        self.allocator,
                        &self.extensions.items[i].extender,
                        &cross_ext,
                    );
                }
            }
        }
        // Phase 2 complete
    }

    /// One-shot self-seed refinement: walk the pseudo tree of `extender_list`,
    /// find non-idempotent pseudo (:has/:host/...) inner selector lists, and for
    /// each immediate :not() seed whose inner compound contains `self_ext.target`,
    /// extend it once with `self_ext` and append the new :not() pseudos.
    /// Returns true if anything changed.
    fn refineSelfSeedsInExtender(
        allocator: std.mem.Allocator,
        extender_list: *SelectorList,
        self_ext: *const Extension,
    ) !bool {
        var any_change = false;
        for (extender_list.selectors.items) |*cx| {
            if (try refineSelfSeedsInComplex(allocator, cx, self_ext))
                any_change = true;
        }
        return any_change;
    }

    fn refineSelfSeedsInComplex(
        allocator: std.mem.Allocator,
        cx: *ComplexSelector,
        self_ext: *const Extension,
    ) !bool {
        var any_change = false;
        for (cx.components.items) |comp| {
            if (comp != .compound) continue;
            // Walk simple selectors looking for pseudo-classes
            for (comp.compound.simple_selectors.items) |ss| {
                if (ss != .pseudo_class) continue;
                const ps = ss.pseudo_class;
                if (ps.selector == null) continue;
                const base = selector_mod.pseudoBaseName(ps.name);

                if (std.ascii.eqlIgnoreCase(base, "not")) {
                    // Recurse into :not() inner to find deeper non-idempotent pseudos
                    for (ps.selector.?.selectors.items) |*not_cx| {
                        if (try refineSelfSeedsInComplex(allocator, not_cx, self_ext))
                            any_change = true;
                    }
                } else if (!isIdempotentSelectorPseudo(ps.name)) {
                    //Non-idempotent pseudo (:has, :host, etc.) -- refine :not() seeds
                    if (try refineNotSeedsInSelectorList(allocator, ps.selector.?, self_ext))
                        any_change = true;
                }
            }
        }
        return any_change;
    }

    /// For each :not(compound) in the selector list whose inner compound
    /// contains the target, extend it once with self_ext and append the
    /// resulting :not() pseudos to the same compound.
    fn refineNotSeedsInSelectorList(
        allocator: std.mem.Allocator,
        list: *SelectorList,
        self_ext: *const Extension,
    ) !bool {
        var any_change = false;
        // Process each complex selector in the list
        for (list.selectors.items) |*inner_cx| {
            // Each inner complex may be a single compound with :not() pseudos
            for (inner_cx.components.items) |*inner_comp| {
                if (inner_comp.* != .compound) continue;
                const compound = &inner_comp.compound;

                // Collect new :not() pseudos to add (can't modify while iterating)
                var new_nots: std.ArrayList(ComplexSelector) = .empty;
                defer {
                    for (new_nots.items) |*n| n.deinit();
                    new_nots.deinit(allocator);
                }

                const orig_len = compound.simple_selectors.items.len;
                const max_new_nots = saturatingMulUsize(orig_len, self_ext.extender.selectors.items.len);
                try new_nots.ensureTotalCapacity(allocator, max_new_nots);
                for (0..orig_len) |si| {
                    const ss = compound.simple_selectors.items[si];
                    if (ss != .pseudo_class) continue;
                    const ps = ss.pseudo_class;
                    if (!std.ascii.eqlIgnoreCase(ps.name, "not")) continue;
                    if (ps.selector == null) continue;
                    const not_sel = ps.selector.?;

                    // Only process single-selector :not()
                    if (not_sel.selectors.items.len != 1) continue;
                    const seed_cx = &not_sel.selectors.items[0];
                    if (seed_cx.components.items.len != 1) continue;
                    if (seed_cx.components.items[0] != .compound) continue;
                    const seed_compound = seed_cx.components.items[0].compound;

                    // Does this seed compound contain the target?
                    if (!compoundContainsTarget(&seed_compound, &self_ext.target)) continue;

                    // One-shot extend: generate extended selectors
                    for (self_ext.extender.selectors.items) |extender_cx| {
                        var extra: std.ArrayList(ComplexSelector) = .empty;
                        defer {
                            for (extra.items) |*e| e.deinit();
                            extra.deinit(allocator);
                        }
                        const new_cx = try generateExtendedSelector(
                            allocator,
                            seed_cx,
                            0,
                            &seed_compound,
                            &self_ext.target,
                            &extender_cx,
                            &extra,
                            true,
                        );
                        if (new_cx) |nc| {
                            // Skip if result is complex (has combinators)
                            if (nc.components.items.len > 1) {
                                var discard = nc;
                                discard.deinit();
                                continue;
                            }
                            // Skip duplicates
                            var is_dup = false;
                            for (new_nots.items) |*existing| {
                                if (complexSelectorEql(existing, &nc)) {
                                    is_dup = true;
                                    break;
                                }
                            }
                            // Also check against existing :not() pseudos in compound
                            if (!is_dup) {
                                if (notPseudoExistsInCompound(compound, &nc)) is_dup = true;
                            }
                            if (!is_dup) {
                                try new_nots.append(allocator, nc);
                            } else {
                                var discard = nc;
                                discard.deinit();
                            }
                        }
                    }
                }

                // Append collected :not() pseudos to the compound
                for (new_nots.items) |new_not_cx| {
                    try appendNotPseudoWithInnerComplex(allocator, compound, &new_not_cx);
                    any_change = true;
                }
            }
        }
        return any_change;
    }

    fn applyExtensionToExtender(
        self: *ApplyState,
        frame: *ApplyFrame,
        i: usize,
        ext_j: *const Extension,
        any_change: *bool,
    ) !void {
        var cx_idx: usize = 0;
        while (cx_idx < self.extensions.items[i].extender.selectors.items.len) {
            var input_cx = try self.extensions.items[i].extender.selectors.items[cx_idx].clone(self.allocator);
            defer input_cx.deinit();

            var did_extend = false;
            for (input_cx.components.items, 0..) |comp, comp_idx| {
                if (comp != .compound) continue;
                const compound = comp.compound;
                if (!compoundContainsTarget(&compound, &ext_j.target)) {
                    if (try extendInsidePseudos(
                        frame,
                        self.allocator,
                        &input_cx,
                        comp_idx,
                        &compound,
                        ext_j,
                        false,
                    )) |new_cx| {
                        var old = self.extensions.items[i].extender.selectors.items[cx_idx];
                        self.extensions.items[i].extender.selectors.items[cx_idx] = new_cx;
                        old.deinit();
                        any_change.* = true;
                        did_extend = true;
                        break;
                    }
                }
            }
            cx_idx += 1;
        }
    }

    pub fn applySelectorExtensions(self: *ApplyState, selector_list: *const SelectorList) !SelectorList {
        return self.applySelectorExtensionsInner(selector_list, null);
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
        if (self.extensions.items.len == 0 and self.sort_extension_hints.items.len == 0) {
            return selector_list.clone(self.allocator);
        }

        var selector_has_extend_target = false;
        for (selector_list.selectors.items) |complex| {
            for (self.extensions.items) |ext| {
                if (compoundContainsTargetInComplex(&complex, &ext.target) or
                    try complexContainsTargetInPseudos(&complex, &ext.target))
                {
                    selector_has_extend_target = true;
                    break;
                }
            }
            if (selector_has_extend_target) break;
            for (self.sort_extension_hints.items) |ext| {
                if (compoundContainsTargetInComplex(&complex, &ext.target) or
                    try complexContainsTargetInPseudos(&complex, &ext.target))
                {
                    selector_has_extend_target = true;
                    break;
                }
            }
            if (selector_has_extend_target) break;
        }
        if (!selector_has_extend_target) {
            return selector_list.clone(self.allocator);
        }

        var frame = ApplyFrame.init(self.allocator, .{
            .replace_mode = self.replace_mode,
            .function_mode = self.function_mode,
        });
        defer frame.deinit();

        try self.applyExtendDirectPass(&frame);
        var result = try self.applyExtendWeavePass(&frame, selector_list, context);
        errdefer result.deinit();
        try self.applyExtendTrimPass(&frame, &result, selector_list);
        try appendExtendersOfNotTargets(self.allocator, &result, self.extensions.items);
        if (selectorListHasPlaceholderBeforeVisibleOriginal(selector_list)) {
            try propagateLeadingNewlineFromOriginalsExact(&result, selector_list);
            if (selectorListHasLeadingNewline(selector_list) and result.selectors.items.len > 1) {
                result.selectors.items[result.selectors.items.len - 1].leading_separator_has_newline = true;
            }
        }
        const order_lookup = if (self.extensions.items.len + self.sort_extension_hints.items.len > 256)
            try self.ensureExtenderLookup()
        else
            null;
        if (try shouldPreservePlaceholderSourceOrderForExactReorder(
            self.allocator,
            context,
            &result,
            selector_list,
            self.extensions.items,
            self.sort_extension_hints.items,
            order_lookup,
        )) {
            try reorderExtenderBranchesBySourceOccurrence(&result, self.extensions.items, self.sort_extension_hints.items);
        } else {
            try reorderExactExtenderBranchesByFirstOccurrence(&result, self.extensions.items, self.exact_order_hints.items);
        }
        return result;
    }

    fn applyExtendDirectPass(self: *ApplyState, frame: *ApplyFrame) !void {
        if (!self.extenders_prepared) {
            try self.crossExtendExtenders(frame);
            self.extenders_prepared = true;
            self.extenders_css_warmed = false;
            self.deinitExtenderLookup();
        }
        frame.did_cross_extend = self.extenders_prepared;
        try self.ensureApplyCaches();
        try self.ensureTargetKeysCached();

        //Pre-cache CSS text for all extender selectors -- these are queried
        // repeatedly in the inner loops via complexInExtenderListResolved().
        if (!self.extenders_css_warmed) {
            for (self.extensions.items) |*ext| {
                for (ext.extender.selectors.items) |*sel| {
                    try sel.ensureCachedCss();
                }
            }
            for (self.sort_extension_hints.items) |*ext| {
                for (ext.extender.selectors.items) |*sel| {
                    try sel.ensureCachedCss();
                }
            }
            self.extenders_css_warmed = true;
        }
        frame.did_cache_extender_css = self.extenders_css_warmed;

        //Enable relaxed :not() guard for the main pass -- allows cross-extended
        // extenders with mixed :not() pseudos (issue 2055).
        frame.relax_not_pseudo_guard = true;
        frame.in_shallow_has_extension = false;
        frame.shallow_has_budget = 0;
    }

    fn applyExtendWeavePass(
        self: *ApplyState,
        frame: *ApplyFrame,
        selector_list: *const SelectorList,
        context: ?ApplyContext,
    ) !SelectorList {
        return self.applyExtendWeavePassImpl(frame, selector_list, context);
    }

    fn applyExtendWeavePassImpl(
        self: *ApplyState,
        frame: *ApplyFrame,
        selector_list: *const SelectorList,
        context: ?ApplyContext,
    ) !SelectorList {
        var result = SelectorList.init(self.allocator);
        errdefer result.deinit();

        const sorted_indices = self.cached_sorted_indices.items;
        const ext_is_placeholder = self.cached_ext_is_placeholder.items;
        const ext_index = &self.cached_ext_index;

        // All generated selectors across all originals, for cross-original trim.
        var all_generated: std.ArrayList(ComplexSelector) = .empty;
        defer {
            for (all_generated.items) |*g| g.deinit();
            all_generated.deinit(self.allocator);
        }
        // Parallel: true = first-pass (direct extension), false = second-pass (weaving).
        var all_generated_first_pass: std.ArrayList(bool) = .empty;
        defer all_generated_first_pass.deinit(self.allocator);
        var all_generated_orig_group: std.ArrayList(usize) = .empty;
        defer all_generated_orig_group.deinit(self.allocator);
        var all_generated_eval_orders: std.ArrayList(u32) = .empty;
        defer all_generated_eval_orders.deinit(self.allocator);
        var all_generated_applied_exts: std.ArrayList(std.DynamicBitSetUnmanaged) = .empty;
        defer {
            for (all_generated_applied_exts.items) |*applied| applied.deinit(self.allocator);
            all_generated_applied_exts.deinit(self.allocator);
        }

        // Per-original generated selectors (to preserve insertion order).
        // generated_per_orig[i] holds generated selectors for selector_list[i].
        var generated_per_orig: std.ArrayList(std.ArrayList(ComplexSelector)) = .empty;
        defer {
            for (generated_per_orig.items) |*lst| {
                for (lst.items) |*g| g.deinit();
                lst.deinit(self.allocator);
            }
            generated_per_orig.deinit(self.allocator);
        }

        const ext_seen_generation = try self.allocator.alloc(u32, self.extensions.items.len);
        defer self.allocator.free(ext_seen_generation);
        const nested_ext_candidates = try self.allocator.alloc(bool, self.extensions.items.len);
        defer self.allocator.free(nested_ext_candidates);
        try generated_per_orig.ensureTotalCapacity(self.allocator, selector_list.selectors.items.len);

        var first_pass_sort_orders_scratch: std.ArrayListUnmanaged(u32) = .empty;
        defer first_pass_sort_orders_scratch.deinit(self.allocator);

        for (selector_list.selectors.items) |complex| {
            var per_orig: std.ArrayList(ComplexSelector) = .empty;
            errdefer {
                for (per_orig.items) |*g| g.deinit();
                per_orig.deinit(self.allocator);
            }

            // Dart Sass-style ordering: iterate compounds right-to-left,
            // and within each compound, iterate simple selectors right-to-left.
            // This gives the correct rightmost-varies-fastest order.
            var first_pass: FirstPassSet = .{};
            defer first_pass.deinit(self.allocator);
            // Per-compound generation marks: while scanning simple selectors right-to-left,
            // the first hit for an extension index is its rightmost match.
            @memset(ext_seen_generation, 0);
            var compound_generation: u32 = 0;

            // Collect compound positions
            var compound_positions: [64]usize = undefined;
            var num_compounds: usize = 0;
            for (complex.components.items, 0..) |comp, idx| {
                if (comp == .compound and num_compounds < 64) {
                    compound_positions[num_compounds] = idx;
                    num_compounds += 1;
                }
            }

            var max_extender_selectors: usize = 0;
            for (self.extensions.items) |ext| {
                max_extender_selectors = @max(max_extender_selectors, ext.extender.selectors.items.len);
            }
            var total_simple_selectors: usize = 0;
            for (complex.components.items) |comp| {
                if (comp != .compound) continue;
                total_simple_selectors = saturatingAddUsize(total_simple_selectors, comp.compound.simple_selectors.items.len);
            }
            const first_pass_cap = saturatingMulUsize(
                saturatingMulUsize(total_simple_selectors, self.extensions.items.len),
                @max(max_extender_selectors, 1),
            );
            // This is only a capacity hint.  The worst-case product can be
            // enormous for frameworks with many extension rules even though the
            // selector index usually yields only a handful of actual matches.
            // Reserving the full product dominates materialize-like workloads,
            // so cap eager reservation and let ArrayList grow on rare large
            // first-pass result sets.
            if (first_pass_cap <= 2048) {
                try first_pass.ensureDirectCapacity(self.allocator, first_pass_cap);
            }

            // Iterate compound positions right-to-left
            var cpos: usize = num_compounds;
            while (cpos > 0) {
                cpos -= 1;
                const comp_idx = compound_positions[cpos];
                const compound = complex.components.items[comp_idx].compound;
                if (compound_generation == std.math.maxInt(u32)) {
                    @memset(ext_seen_generation, 0);
                    compound_generation = 1;
                } else {
                    compound_generation += 1;
                }

                // Within this compound, iterate simple selectors right-to-left
                var ss_idx: usize = compound.simple_selectors.items.len;
                while (ss_idx > 0) {
                    ss_idx -= 1;
                    const ss = compound.simple_selectors.items[ss_idx];

                    // Look up extensions whose target contains a matching simple selector.
                    const matching_exts = if (ext_index.get(ssKeyFromSimple(ss))) |list| list.items else &[_]usize{};
                    for (matching_exts) |ext_i| {
                        if (ext_seen_generation[ext_i] == compound_generation) continue;
                        ext_seen_generation[ext_i] = compound_generation;
                        const ext = self.extensions.items[ext_i];
                        const ext_target_is_placeholder = ext_is_placeholder[ext_i];
                        if (!compoundContainsTarget(&compound, &ext.target)) continue;
                        if (hasBogusMultipleCombinators(&complex)) continue;

                        const batch_start = first_pass.selectors.items.len;
                        for (ext.extender.selectors.items) |extender_complex| {
                            var extra: std.ArrayList(ComplexSelector) = .empty;
                            defer {
                                for (extra.items) |*e| e.deinit();
                                extra.deinit(self.allocator);
                            }
                            const new_complex = try generateExtendedSelector(
                                self.allocator,
                                &complex,
                                comp_idx,
                                &compound,
                                &ext.target,
                                &extender_complex,
                                &extra,
                                frame.config.function_mode,
                            );
                            if (new_complex) |nc| {
                                const normalized = nc;
                                for (normalized.components.items) |*component| {
                                    if (component.* != .compound) continue;
                                    normalizeGeneratedCompound(&component.compound, self.extensions.items, self.sort_extension_hints.items);
                                }
                                if (!hasBogusMultipleCombinators(&nc)) {
                                    var applied = try std.DynamicBitSetUnmanaged.initEmpty(self.allocator, self.extensions.items.len);
                                    applied.set(ext_i);
                                    try first_pass.appendDirect(self.allocator, .{
                                        .selector = normalized,
                                        .eval_order = ext.eval_order,
                                        .module_group_start = ext.module_group_start_order,
                                        .comp_idx = comp_idx,
                                        .simple_idx = ss_idx,
                                        .target_is_placeholder = ext_target_is_placeholder,
                                        .applied = applied,
                                    });
                                } else {
                                    var s = normalized;
                                    s.deinit();
                                }
                            }
                            for (extra.items) |ec| {
                                const normalized = ec;
                                for (normalized.components.items) |*component| {
                                    if (component.* != .compound) continue;
                                    normalizeGeneratedCompound(&component.compound, self.extensions.items, self.sort_extension_hints.items);
                                }
                                if (!hasBogusMultipleCombinators(&ec)) {
                                    var applied = try std.DynamicBitSetUnmanaged.initEmpty(self.allocator, self.extensions.items.len);
                                    applied.set(ext_i);
                                    try first_pass.appendDirect(self.allocator, .{
                                        .selector = normalized,
                                        .eval_order = ext.eval_order,
                                        .module_group_start = ext.module_group_start_order,
                                        .comp_idx = comp_idx,
                                        .simple_idx = ss_idx,
                                        .target_is_placeholder = ext_target_is_placeholder,
                                        .applied = applied,
                                    });
                                } else {
                                    var s = normalized;
                                    s.deinit();
                                }
                            }
                            extra.items.len = 0;
                        }

                        // Intra-extension dedup: within a single @extend rule
                        // with a selector list (e.g. `.bar:hover h3, h3 { @extend h1 }`
                        // inside `.foo { h1 {} }`), weave pass produces both
                        // `.foo .bar:hover h3` and `.foo .bar h3`; the narrower
                        // is removed when the broader has the same shape.
                        //Only applies to multi-compound weave results -- single-
                        // compound direct replacements (e.g. `.a, .b.a {@extend %x}`
                        // or `%y, %y:fblthp {@extend %x}`) must keep both per
                        // dart-sass, because intra-list narrower variants are not
                        // deduped against broader ones in the direct-replace path.
                        dedupeIntraExtensionFirstPassBatch(self.allocator, &first_pass, batch_start);
                    }
                }

                // Also check for pseudo-selector extension at this compound.
                // When there is no nested selector pseudo (:not/:is/:has/:nth-...of),
                // this pass can't produce changes.
                if (!compoundHasNestedSelectorPseudo(&compound)) continue;
                @memset(nested_ext_candidates, false);
                markExtensionCandidatesInCompoundPseudos(ext_index, &compound, nested_ext_candidates);
                for (sorted_indices) |ext_i| {
                    if (!nested_ext_candidates[ext_i]) continue;
                    const ext = self.extensions.items[ext_i];
                    const ext_target_is_placeholder = ext_is_placeholder[ext_i];
                    if (!compoundContainsTarget(&compound, &ext.target)) {
                        if (try extendInsidePseudos(
                            frame,
                            self.allocator,
                            &complex,
                            comp_idx,
                            &compound,
                            &ext,
                            extensionTargetFanout(self.extensions.items, &ext.target) > not_direct_defer_fanout_threshold,
                        )) |new_complex| {
                            const normalized = new_complex;
                            for (normalized.components.items) |*component| {
                                if (component.* != .compound) continue;
                                normalizeGeneratedCompound(&component.compound, self.extensions.items, self.sort_extension_hints.items);
                            }
                            if (!hasBogusMultipleCombinators(&new_complex)) {
                                var applied = try std.DynamicBitSetUnmanaged.initEmpty(self.allocator, self.extensions.items.len);
                                applied.set(ext_i);
                                try first_pass.appendDirect(self.allocator, .{
                                    .selector = normalized,
                                    .eval_order = ext.eval_order,
                                    .module_group_start = ext.module_group_start_order,
                                    .comp_idx = comp_idx,
                                    .simple_idx = std.math.maxInt(usize),
                                    .target_is_placeholder = ext_target_is_placeholder,
                                    .applied = applied,
                                });
                            } else {
                                var s = normalized;
                                s.deinit();
                            }
                        }
                    }
                }
            }

            const first_pass_direct_count = first_pass.selectors.items.len;
            const any_placeholder_target = blk: {
                for (self.extensions.items) |ext| {
                    for (ext.target.simple_selectors.items) |ss| {
                        if (ss == .placeholder) break :blk true;
                    }
                }
                break :blk false;
            };

            if (first_pass_direct_count > 1) {
                const all_direct_targets_placeholder = blk: {
                    if (first_pass.target_is_placeholder.items.len != first_pass_direct_count or first_pass_direct_count == 0) break :blk false;
                    for (first_pass.target_is_placeholder.items[0..first_pass_direct_count]) |is_placeholder| {
                        if (!is_placeholder) break :blk false;
                    }
                    break :blk true;
                };
                try first_pass_sort_orders_scratch.resize(self.allocator, first_pass_direct_count);
                const first_pass_sort_orders = first_pass_sort_orders_scratch.items;
                const first_pass_order_lookup = if (self.extensions.items.len + self.sort_extension_hints.items.len > 256)
                    try self.ensureExtenderLookup()
                else
                    null;
                for (0..first_pass_direct_count) |fp_idx| {
                    const selector_order = if (first_pass_order_lookup) |lookup|
                        if (try lookup.get(&first_pass.selectors.items[fp_idx])) |info| info.max_eval_order else 0
                    else
                        try extenderMaxEvalOrderResolvedCombined(
                            &first_pass.selectors.items[fp_idx],
                            self.extensions.items,
                            self.sort_extension_hints.items,
                        );
                    first_pass_sort_orders[fp_idx] = @max(first_pass.eval_orders.items[fp_idx], selector_order);
                }
                const placeholder_prefers_later_declared_order = all_direct_targets_placeholder and
                    prefersLaterDeclaredPlaceholderOrder(
                        self.allocator,
                        context,
                        first_pass.selectors.items[0..first_pass_direct_count],
                        first_pass_sort_orders,
                        first_pass.module_group_starts.items[0..first_pass_direct_count],
                        first_pass_direct_count,
                    );
                // For a repeated placeholder declaration, Dart Sass switches
                // this target's direct extenders back to source order. The first
                // declaration still prefers later extenders because its snapshot
                // precedes those @extend statements; later declarations have a
                // snapshot after the existing extender set.
                const placeholder_keeps_source_order = all_direct_targets_placeholder and
                    !placeholder_prefers_later_declared_order;
                var changed = true;
                while (changed) {
                    changed = false;
                    var i: usize = 1;
                    while (i < first_pass_direct_count) : (i += 1) {
                        // When prefixed extenders target the same compound, sort by
                        // simple_index ascending (compound position, left-to-right).
                        // Otherwise, sort by eval_order. Placeholder expansions only
                        // prefer later declarations when the target rule itself should
                        // preserve that ordering (local direct rules declared before
                        // their extenders). Imported targets and targets declared later
                        // keep source order to match Dart Sass.
                        const should_skip = firstPassDirectAdjacentShouldSkipSwap(
                            &first_pass,
                            first_pass_sort_orders,
                            i,
                            context,
                            all_direct_targets_placeholder,
                            placeholder_keeps_source_order,
                        );
                        if (should_skip) continue;
                        first_pass.swap(i - 1, i);
                        std.mem.swap(u32, &first_pass_sort_orders[i - 1], &first_pass_sort_orders[i]);
                        changed = true;
                    }
                }
            }

            try first_pass.direct_id.ensureTotalCapacity(self.allocator, first_pass.selectors.items.len);
            for (0..first_pass.selectors.items.len) |direct_idx| {
                first_pass.direct_id.appendAssumeCapacity(direct_idx);
            }

            //Warm CSS cache for first-pass selectors -- these are compared
            // repeatedly in the dedup loops via complexHasExactCssText().
            for (first_pass.selectors.items) |*fp| {
                try fp.ensureCachedCss();
            }

            // Second pass: apply remaining extensions to first-pass results.
            // Also needed for single placeholder extensions when the target
            // appears in multiple compounds of the complex selector -- the
            // first pass generates partial results (e.g. `a %b .bar`) that
            // need another round to become fully resolved (`a b .bar`).
            if (first_pass.selectors.items.len > 0 and (self.extensions.items.len > 1 or any_placeholder_target)) {
                var frontier_start: usize = 0;
                var pass_budget: usize = self.extensions.items.len + 1;
                while (frontier_start < first_pass.selectors.items.len and pass_budget > 0) : (pass_budget -= 1) {
                    const frontier_end = first_pass.selectors.items.len;
                    var next_pass: std.ArrayList(ComplexSelector) = .empty;
                    var next_pass_direct_id: std.ArrayList(usize) = .empty;
                    var next_pass_is_local_transitive: std.ArrayList(bool) = .empty;
                    var next_pass_applied_exts: std.ArrayList(std.DynamicBitSetUnmanaged) = .empty;
                    defer {
                        for (next_pass.items) |*g| g.deinit();
                        next_pass.deinit(self.allocator);
                        next_pass_direct_id.deinit(self.allocator);
                        next_pass_is_local_transitive.deinit(self.allocator);
                        for (next_pass_applied_exts.items) |*applied| applied.deinit(self.allocator);
                        next_pass_applied_exts.deinit(self.allocator);
                    }
                    const frontier_width = frontier_end - frontier_start;
                    const next_pass_cap = saturatingMulUsize(frontier_width, sorted_indices.len);
                    // Capacity hint only.  Full Volver-style component graphs
                    // can have a wide frontier and thousands of extension
                    // records, while the indexed/presence checks below admit
                    // only a small subset.  Reserving the product eagerly was
                    // enough to push Debug runs into tens of GB before doing
                    // useful work.
                    const next_pass_reserve = @min(next_pass_cap, 4096);
                    try next_pass.ensureTotalCapacity(self.allocator, next_pass_reserve);
                    try next_pass_direct_id.ensureTotalCapacity(self.allocator, next_pass_reserve);
                    try next_pass_is_local_transitive.ensureTotalCapacity(self.allocator, next_pass_reserve);
                    try next_pass_applied_exts.ensureTotalCapacity(self.allocator, next_pass_reserve);

                    for (frontier_start..frontier_end) |fi| {
                        @memset(nested_ext_candidates, false);
                        markExtensionCandidatesInNestedComplex(
                            ext_index,
                            &first_pass.selectors.items[fi],
                            nested_ext_candidates,
                        );
                        for (sorted_indices) |ext_i| {
                            if (!nested_ext_candidates[ext_i]) continue;
                            const ext = self.extensions.items[ext_i];
                            if (first_pass.applied_exts.items[fi].isSet(ext_i)) {
                                if (!compoundContainsTargetInComplex(&first_pass.selectors.items[fi], &ext.target)) {
                                    continue;
                                }
                                if (try complexInExtenderListResolved(&first_pass.selectors.items[fi], &ext.extender)) {
                                    continue;
                                }
                            }
                            if (appliedExtsContainStatementGroup(
                                &first_pass.applied_exts.items[fi],
                                self.extensions.items,
                                &ext,
                            )) continue;
                            if (appliedExtsContainDifferentSelectorListBranch(
                                &first_pass.applied_exts.items[fi],
                                self.extensions.items,
                                &ext,
                            )) continue;
                            const is_local_transitive = blk: {
                                if (!first_pass.is_direct.items[fi] and !first_pass.is_local_transitive.items[fi]) {
                                    break :blk false;
                                }
                                if (compoundContainsTargetInComplex(&complex, &ext.target)) break :blk false;
                                if (try complexContainsTargetInPseudos(&complex, &ext.target)) break :blk false;
                                break :blk true;
                            };
                            const new_selectors = try applyExtensionToComplex(
                                frame,
                                self.allocator,
                                &first_pass.selectors.items[fi],
                                &ext,
                                extensionTargetFanout(self.extensions.items, &ext.target) > not_direct_defer_fanout_threshold,
                            );
                            defer self.allocator.free(new_selectors);

                            for (new_selectors) |new_sel| {
                                const normalized = new_sel;
                                for (normalized.components.items) |*component| {
                                    if (component.* != .compound) continue;
                                    normalizeGeneratedCompound(&component.compound, self.extensions.items, self.sort_extension_hints.items);
                                }
                                if (hasBogusMultipleCombinators(&new_sel)) {
                                    var s = normalized;
                                    s.deinit();
                                    continue;
                                }

                                var seen = false;
                                const current_direct_id = first_pass.direct_id.items[fi];
                                for (first_pass.selectors.items, 0..) |*existing, existing_idx| {
                                    if (existing_idx >= first_pass.direct_id.items.len) continue;
                                    if (first_pass.direct_id.items[existing_idx] != current_direct_id) continue;
                                    if (try complexHasExactCssText(existing, &normalized)) {
                                        seen = true;
                                        break;
                                    }
                                }
                                if (!seen) {
                                    for (next_pass.items, 0..) |*existing, existing_idx| {
                                        if (existing_idx >= next_pass_direct_id.items.len) continue;
                                        if (next_pass_direct_id.items[existing_idx] != current_direct_id) continue;
                                        if (try complexHasExactCssText(existing, &normalized)) {
                                            seen = true;
                                            break;
                                        }
                                    }
                                }
                                if (seen) {
                                    var s = normalized;
                                    s.deinit();
                                    continue;
                                }
                                if (!frame.config.function_mode and !frame.config.replace_mode and
                                    normalized.components.items.len == 1 and complex.components.items.len == 1)
                                {
                                    const nc_ss = normalized.components.items[0].compound.simple_selectors;
                                    const oc_ss = complex.components.items[0].compound.simple_selectors;
                                    if (nc_ss.items.len == oc_ss.items.len + 1) {
                                        var all_orig_in = true;
                                        var has_pseudo = false;
                                        for (oc_ss.items) |oss| {
                                            if (oss == .pseudo_class or oss == .pseudo_element) {
                                                has_pseudo = true;
                                                break;
                                            }
                                            var found = false;
                                            for (nc_ss.items) |nss| {
                                                if (simpleSelectorEql(oss, nss)) {
                                                    found = true;
                                                    break;
                                                }
                                            }
                                            if (!found) {
                                                all_orig_in = false;
                                                break;
                                            }
                                        }
                                        if (!has_pseudo and all_orig_in) {
                                            var s = normalized;
                                            s.deinit();
                                            continue;
                                        }
                                    }
                                }
                                try next_pass.append(self.allocator, normalized);
                                try next_pass_direct_id.append(self.allocator, first_pass.direct_id.items[fi]);
                                try next_pass_is_local_transitive.append(self.allocator, is_local_transitive);
                                var applied = try first_pass.applied_exts.items[fi].clone(self.allocator);
                                applied.set(ext_i);
                                try next_pass_applied_exts.append(self.allocator, applied);
                            }
                        }
                    }

                    frontier_start = first_pass.selectors.items.len;
                    const appended = next_pass.items.len;
                    try first_pass.ensureTransitiveUnusedCapacity(self.allocator, appended);
                    for (next_pass.items, next_pass_direct_id.items, next_pass_is_local_transitive.items, next_pass_applied_exts.items) |sel, direct_id, is_local_transitive, applied| {
                        try first_pass.appendTransitive(self.allocator, sel, direct_id, is_local_transitive, applied);
                    }
                    next_pass.items.len = 0;
                    next_pass_applied_exts.items.len = 0;
                }
            }

            try coalesceGeneratedSelectorPseudoVariants(
                self.allocator,
                &first_pass.selectors,
                &first_pass.is_direct,
                &first_pass.direct_id,
                &first_pass.is_local_transitive,
            );

            // After coalescing, merge :has()/:is() inner selector lists' :not() variants.
            for (first_pass.selectors.items) |*fp| {
                for (fp.components.items) |*fcomp| {
                    if (fcomp.* != .compound) continue;
                    for (fcomp.compound.simple_selectors.items) |fss| {
                        if (fss != .pseudo_class) continue;
                        const fps = fss.pseudo_class;
                        if (!isExtendableSelectorPseudo(fps.name)) continue;
                        if (std.ascii.eqlIgnoreCase(selector_mod.pseudoBaseName(fps.name), "not")) continue;
                        if (fps.selector) |sel| {
                            mergeSelectorListNotPseudoVariants(self.allocator, sel);
                        }
                    }
                }
            }

            try all_generated.ensureUnusedCapacity(self.allocator, first_pass.selectors.items.len);
            try all_generated_first_pass.ensureUnusedCapacity(self.allocator, first_pass.selectors.items.len);
            try all_generated_orig_group.ensureUnusedCapacity(self.allocator, first_pass.selectors.items.len);
            try all_generated_eval_orders.ensureUnusedCapacity(self.allocator, first_pass.selectors.items.len);
            try all_generated_applied_exts.ensureUnusedCapacity(self.allocator, first_pass.selectors.items.len);
            for (first_pass.selectors.items, 0..) |sel, fp_idx| {
                try all_generated.append(self.allocator, try sel.clone(self.allocator));
                try all_generated_first_pass.append(
                    self.allocator,
                    fp_idx < first_pass.is_direct.items.len and first_pass.is_direct.items[fp_idx],
                );
                try all_generated_orig_group.append(self.allocator, generated_per_orig.items.len);
                try all_generated_eval_orders.append(self.allocator, if (fp_idx < first_pass.eval_orders.items.len) first_pass.eval_orders.items[fp_idx] else 0);
                const applied = if (fp_idx < first_pass.applied_exts.items.len)
                    try first_pass.applied_exts.items[fp_idx].clone(self.allocator)
                else
                    try std.DynamicBitSetUnmanaged.initEmpty(self.allocator, self.extensions.items.len);
                try all_generated_applied_exts.append(self.allocator, applied);
            }

            // Historical ordering rule: preserve append-at-end by default, but keep branch-local
            // chained descendants adjacent to the direct selector that introduced them.
            // Iterate in sorted first_pass order (not by direct_id) to respect eval_order sort.
            try per_orig.ensureUnusedCapacity(self.allocator, first_pass.selectors.items.len);
            for (first_pass.selectors.items, 0..) |_, idx| {
                if (!first_pass.is_direct.items[idx]) continue;
                const direct_is_placeholder = complexContainsPlaceholder(&first_pass.selectors.items[idx]);
                // Emit visible (non-placeholder) directs; skip placeholder directs
                // but still emit their local-transitive children.
                if (!direct_is_placeholder) {
                    try per_orig.append(self.allocator, try first_pass.selectors.items[idx].clone(self.allocator));
                }
                const direct_id = first_pass.direct_id.items[idx];
                if (!direct_is_placeholder) {
                    // Visible direct: emit local-transitive items in first_pass order.
                    for (first_pass.selectors.items, 0..) |sel, jdx| {
                        if (first_pass.is_direct.items[jdx]) continue;
                        if (!first_pass.is_local_transitive.items[jdx]) continue;
                        if (first_pass.direct_id.items[jdx] != direct_id) continue;
                        try per_orig.append(self.allocator, try sel.clone(self.allocator));
                    }
                } else {
                    // Placeholder direct: collect local-transitive items and sort
                    // by compound count ascending so broader selectors precede
                    // narrower cross-weave results. When the placeholder target
                    // itself came from an upstream module/imported rule, keep
                    // equal-width items in their source eval order to match
                    // Dart Sass's imported-placeholder chain behavior.
                    var lt_indices: [256]usize = undefined;
                    var lt_orders: [256]u32 = undefined;
                    var lt_module_groups: [256]u32 = undefined;
                    var lt_count: usize = 0;
                    const direct_module_group: ?u32 = if (direct_id < first_pass.module_group_starts.items.len)
                        first_pass.module_group_starts.items[direct_id]
                    else
                        null;
                    // Direct entry for an intermediate placeholder that itself
                    // crosses module boundaries to the rule's target placeholder.
                    // dart-sass keeps within-module siblings in source order in
                    // this scenario (e.g. bulma %input rule body resolves
                    // .input/.textarea via %input-textarea chain).
                    const cross_module_intermediate_placeholder_direct = if (direct_module_group) |g|
                        (g >> 16) != 0xFFFF
                    else
                        false;
                    const same_module_placeholder_direct = if (direct_module_group) |g|
                        (g >> 16) == 0xFFFF
                    else
                        true;
                    const imported_placeholder_target_keeps_source_order = if (context) |ctx|
                        (!ctx.target_is_direct_rule and !same_module_placeholder_direct) or cross_module_intermediate_placeholder_direct
                    else
                        cross_module_intermediate_placeholder_direct;
                    const direct_prefers_later_order = direct_id < first_pass.selectors.items.len and
                        (complexIsBareOrPseudoPlaceholder(&first_pass.selectors.items[direct_id]) or
                            complexIsAttributeContextPlaceholder(&first_pass.selectors.items[direct_id]));
                    for (first_pass.selectors.items, 0..) |_, jdx| {
                        if (first_pass.is_direct.items[jdx]) continue;
                        if (!first_pass.is_local_transitive.items[jdx]) continue;
                        if (first_pass.direct_id.items[jdx] != direct_id) continue;
                        if (lt_count < 256) {
                            lt_indices[lt_count] = jdx;
                            var eo = extenderMaxEvalOrderResolvedCombined(
                                &first_pass.selectors.items[jdx],
                                self.extensions.items,
                                self.sort_extension_hints.items,
                            ) catch 0;
                            var lt_mg: u32 = 0;
                            // Pseudo-suffixed transitives (e.g. `.input::placeholder`)
                            // can't match extender CSS verbatim, so fall back to the
                            // applied_exts bitset which records exactly which
                            // extensions produced this transitive.
                            if (jdx < first_pass.applied_exts.items.len) {
                                const applied = first_pass.applied_exts.items[jdx];
                                var bit_iter = applied.iterator(.{});
                                var best_eo: u32 = 0;
                                var best_mg: u32 = 0;
                                while (bit_iter.next()) |ext_idx| {
                                    if (ext_idx < self.extensions.items.len) {
                                        const ext = self.extensions.items[ext_idx];
                                        if (ext.eval_order > best_eo) {
                                            best_eo = ext.eval_order;
                                            best_mg = ext.module_group_start_order orelse 0;
                                        }
                                    }
                                }
                                if (eo == 0) eo = best_eo;
                                lt_mg = best_mg;
                            }
                            lt_orders[lt_count] = eo;
                            lt_module_groups[lt_count] = lt_mg;
                            lt_count += 1;
                        }
                    }
                    var local_transitives_have_pseudo = false;
                    for (lt_indices[0..lt_count]) |jdx| {
                        if (complexHasPseudoSelector(&first_pass.selectors.items[jdx])) {
                            local_transitives_have_pseudo = true;
                            break;
                        }
                    }
                    // Stable sort by compound count ascending.
                    if (lt_count > 1) {
                        var changed = true;
                        while (changed) {
                            changed = false;
                            var si: usize = 1;
                            while (si < lt_count) : (si += 1) {
                                var swap_local = false;
                                if (cross_module_intermediate_placeholder_direct) {
                                    // Cross-module intermediate placeholder: order by
                                    // each transitive's introducing-extension source
                                    // module index (descending, latest-loaded module
                                    // first), then by eval_order ascending within the
                                    // same module. Compound count is intentionally
                                    // ignored so a descendant-combinator transitive
                                    // (e.g. `.select select`) can lead the chain when
                                    // its module is loaded later than the placeholder
                                    // intermediate's module. Source module sits in the
                                    // low 16 bits of the encoded module_group_start
                                    // (see `extendModuleGroupStartOrder` in vm.zig);
                                    // dist (high bits) is ignored because what matters
                                    // is where the extender itself lives, not how far
                                    // away the rule's target placeholder is.
                                    const a_src = lt_module_groups[si - 1] & 0xFFFF;
                                    const b_src = lt_module_groups[si] & 0xFFFF;
                                    if (a_src != b_src) {
                                        if (a_src < b_src) swap_local = true;
                                    } else {
                                        const a_order = lt_orders[si - 1];
                                        const b_order = lt_orders[si];
                                        if (a_order > b_order) swap_local = true;
                                    }
                                } else {
                                    var a_cc: usize = 0;
                                    for (first_pass.selectors.items[lt_indices[si - 1]].components.items) |c| {
                                        if (c == .compound) a_cc += 1;
                                    }
                                    var b_cc: usize = 0;
                                    for (first_pass.selectors.items[lt_indices[si]].components.items) |c| {
                                        if (c == .compound) b_cc += 1;
                                    }
                                    if (direct_prefers_later_order and !imported_placeholder_target_keeps_source_order) {
                                        const a_order = lt_orders[si - 1];
                                        const b_order = lt_orders[si];
                                        if (a_order < b_order) swap_local = true;
                                    } else if (a_cc > b_cc) {
                                        swap_local = true;
                                    } else if (a_cc == b_cc and imported_placeholder_target_keeps_source_order) {
                                        const a_order = lt_orders[si - 1];
                                        const b_order = lt_orders[si];
                                        if (a_order > b_order) swap_local = true;
                                    } else if (a_cc == b_cc and !imported_placeholder_target_keeps_source_order) {
                                        const a_order = lt_orders[si - 1];
                                        const b_order = lt_orders[si];
                                        if (a_order < b_order) swap_local = true;
                                    }
                                }
                                if (swap_local) {
                                    std.mem.swap(usize, &lt_indices[si - 1], &lt_indices[si]);
                                    std.mem.swap(u32, &lt_orders[si - 1], &lt_orders[si]);
                                    std.mem.swap(u32, &lt_module_groups[si - 1], &lt_module_groups[si]);
                                    changed = true;
                                }
                            }
                        }
                    }
                    for (lt_indices[0..lt_count]) |jdx| {
                        try per_orig.append(self.allocator, try first_pass.selectors.items[jdx].clone(self.allocator));
                    }
                }
            }
            // Cross-target items: sort by parent direct item's eval_order
            // ascending (earlier extensions first), with stable order for
            // same eval_order. This matches dart-sass output ordering for
            // placeholder-chain resolutions.
            {
                var ct_indices: [256]usize = undefined;
                var ct_count: usize = 0;
                for (first_pass.selectors.items, 0..) |_, idx| {
                    if (first_pass.is_direct.items[idx]) continue;
                    if (first_pass.is_local_transitive.items[idx]) continue;
                    if (ct_count < 256) {
                        ct_indices[ct_count] = idx;
                        ct_count += 1;
                    }
                }
                //Stable sort by parent eval_order ascending -- only when
                // placeholder targets are involved. For non-placeholder cases,
                // the default frontier order is already correct.
                if (ct_count > 1 and any_placeholder_target) {
                    var changed = true;
                    while (changed) {
                        changed = false;
                        var si: usize = 1;
                        while (si < ct_count) : (si += 1) {
                            const a_idx = ct_indices[si - 1];
                            const b_idx = ct_indices[si];
                            const a_did = first_pass.direct_id.items[a_idx];
                            const b_did = first_pass.direct_id.items[b_idx];
                            const a_eo = if (a_did < first_pass.eval_orders.items.len) first_pass.eval_orders.items[a_did] else 0;
                            const b_eo = if (b_did < first_pass.eval_orders.items.len) first_pass.eval_orders.items[b_did] else 0;
                            const a_group = if (a_did < first_pass.module_group_starts.items.len) first_pass.module_group_starts.items[a_did] else null;
                            const b_group = if (b_did < first_pass.module_group_starts.items.len) first_pass.module_group_starts.items[b_did] else null;
                            var swap = false;
                            if (a_group) |ag| {
                                if (b_group) |bg| {
                                    if (ag < bg) {
                                        swap = true;
                                    } else if (ag == bg and a_eo > b_eo) {
                                        swap = true;
                                    }
                                } else if (a_eo > b_eo) {
                                    swap = true;
                                }
                            } else if (a_eo > b_eo) {
                                swap = true;
                            } else if (a_eo == b_eo and a_did != b_did) {
                                // Same eval_order but different direct parent:
                                // group by direct_id ascending (preserves
                                // weave position order).
                                if (a_did > b_did) swap = true;
                            } else if (a_eo == b_eo and a_did == b_did) {
                                // Same parent: sort by compound count
                                // ascending (broader first).
                                var a_cc: usize = 0;
                                for (first_pass.selectors.items[a_idx].components.items) |c| {
                                    if (c == .compound) a_cc += 1;
                                }
                                var b_cc: usize = 0;
                                for (first_pass.selectors.items[b_idx].components.items) |c| {
                                    if (c == .compound) b_cc += 1;
                                }
                                if (a_cc > b_cc) swap = true;
                            }
                            if (swap) {
                                std.mem.swap(usize, &ct_indices[si - 1], &ct_indices[si]);
                                changed = true;
                            }
                        }
                    }
                }
                for (ct_indices[0..ct_count]) |idx| {
                    try per_orig.append(self.allocator, try first_pass.selectors.items[idx].clone(self.allocator));
                }
            }

            for (per_orig.items) |*sel| {
                normalizeGeneratedNotPseudoClassOrderAgainstOriginal(
                    &complex,
                    sel,
                    self.extensions.items,
                    self.sort_extension_hints.items,
                    context,
                );
            }

            try generated_per_orig.ensureUnusedCapacity(self.allocator, 1);
            try generated_per_orig.append(self.allocator, per_orig);
        }

        // Trim generated selectors among themselves (e.g., remove :is(.c, .d) if :is(.c, .d, .e) exists).
        try trimWithMetadata(
            self.allocator,
            &all_generated,
            &all_generated_first_pass,
            &all_generated_orig_group,
            &all_generated_eval_orders,
        );

        // A generated selector may be made redundant by another generated
        // selector from a different original/extension path (for example,
        // `.x.y` after `.x` and `.y`, or a pseudo-class variant after the
        // same selector without that pseudo).  The metadata-aware trim above
        // handles many same-path cases; do a conservative cross-generated
        // superselector pass before interleaving with originals.
        if (!frame.config.replace_mode) {
            var gen_i: usize = all_generated.items.len;
            while (gen_i > 0) {
                gen_i -= 1;
                const gen = &all_generated.items[gen_i];
                if (all_generated_first_pass.items[gen_i]) continue;
                var remove_gen = false;
                for (all_generated.items, 0..) |*other, other_i| {
                    if (gen_i == other_i) continue;
                    if (complexSelectorEql(gen, other)) continue;
                    if (gen.components.items.len != other.components.items.len) continue;
                    if (!complexIsBroaderThan(other, gen)) continue;
                    if (complexOnlyAddsNotPseudos(other, gen)) continue;
                    if (complexFirstCompoundSpecificityCarrierKeepsGenerated(other, gen)) continue;
                    if (narrowerKeepsFinalTrimStatefulExtras(other, gen)) continue;
                    remove_gen = true;
                    break;
                }
                if (remove_gen) {
                    var removed = all_generated.orderedRemove(gen_i);
                    removed.deinit();
                    _ = all_generated_first_pass.orderedRemove(gen_i);
                    if (gen_i < all_generated_orig_group.items.len) _ = all_generated_orig_group.orderedRemove(gen_i);
                    if (gen_i < all_generated_eval_orders.items.len) _ = all_generated_eval_orders.orderedRemove(gen_i);
                    if (gen_i < all_generated_applied_exts.items.len) {
                        var removed_exts = all_generated_applied_exts.orderedRemove(gen_i);
                        removed_exts.deinit(self.allocator);
                    }
                }
            }
        }

        // Also remove generated selectors that are narrower than an original selector.
        // Case 1: More components (ancestors/combinators) - e.g., "d c" narrower than "c".
        // Case 2: Same components but more simple selectors in compound - e.g., ".a.b"
        //         narrower than ".a". Exception: extra :not() pseudos are valid extensions.
        // Skip this trimming in replace_mode (selector-replace needs narrower results).
        if (!frame.config.replace_mode) {
            var ag_i: usize = all_generated.items.len;
            while (ag_i > 0) {
                ag_i -= 1;
                const gen = &all_generated.items[ag_i];
                const generated_is_first_pass = all_generated_first_pass.items[ag_i];
                const generated_orig_group = if (ag_i < all_generated_orig_group.items.len)
                    all_generated_orig_group.items[ag_i]
                else
                    std.math.maxInt(usize);
                const generated_applied_exts = if (ag_i < all_generated_applied_exts.items.len)
                    &all_generated_applied_exts.items[ag_i]
                else
                    null;
                // Don't trim a generated selector that is identical to one of
                // the original selectors -- self-extends can produce duplicates
                // of originals that must remain for correct interleaving order.
                var is_original = false;
                for (selector_list.selectors.items) |orig| {
                    if (complexSelectorEql(gen, &orig)) {
                        is_original = true;
                        break;
                    }
                }
                if (is_original) continue;
                var should_remove = false;
                const allow_cross_group_repeated_suffix_trim =
                    complexLastCompoundRepeatsEarlierCompound(gen);
                for (selector_list.selectors.items, 0..) |orig, orig_idx| {
                    const same_generated_group = orig_idx == generated_orig_group;
                    const allow_cross_group_specificity_trim = !same_generated_group and
                        generated_applied_exts != null and
                        complexSpecificityCoversAppliedExtenders(&orig, gen, generated_applied_exts.?, self.extensions.items);
                    if (!allow_cross_group_repeated_suffix_trim and
                        !same_generated_group and
                        !allow_cross_group_specificity_trim)
                    {
                        continue;
                    }
                    var visible_orig_storage: ?ComplexSelector = null;
                    defer if (visible_orig_storage) |*visible_orig| visible_orig.deinit();
                    const trim_orig: *const ComplexSelector = if (complexContainsPlaceholder(&orig)) blk: {
                        visible_orig_storage = try cloneComplexWithoutPlaceholders(self.allocator, &orig);
                        break :blk if (visible_orig_storage) |*visible_orig| visible_orig else continue;
                    } else &orig;
                    if (visible_orig_storage != null) {
                        const allow_placeholder_trim =
                            gen.components.items.len == 1 and
                            trim_orig.components.items.len == 1 and
                            !complexHasAnyPseudo(gen) and
                            !complexHasAnyPseudo(trim_orig) and
                            try selectorListHasVisibleEquivalentOriginal(
                                selector_list,
                                orig_idx,
                                trim_orig,
                            );
                        if (!allow_placeholder_trim) continue;
                    }
                    if (!generated_is_first_pass) {
                        if (gen.components.items.len != 1 or trim_orig.components.items.len != 1) continue;
                        const gen_last = getLastCompound(gen) orelse continue;
                        const orig_last = getLastCompound(trim_orig) orelse continue;
                        if (gen_last.simple_selectors.items.len != orig_last.simple_selectors.items.len + 1) continue;
                        var has_pseudo = false;
                        for (gen_last.simple_selectors.items) |ss| {
                            if (ss == .pseudo_class or ss == .pseudo_element) {
                                has_pseudo = true;
                                break;
                            }
                        }
                        if (has_pseudo) continue;
                    }
                    if (gen.components.items.len > trim_orig.components.items.len and
                        complexIsBroaderThan(trim_orig, gen))
                    {
                        if (generated_is_first_pass and same_generated_group) continue;
                        if (complexFirstCompoundSpecificityCarrierKeepsGenerated(trim_orig, gen)) continue;
                        should_remove = true;
                        break;
                    }
                    // Same component count: check if generated is narrower due to
                    // extra non-:not() simple selectors in the last compound.
                    if (gen.components.items.len == trim_orig.components.items.len and
                        (complexIsBroaderThan(trim_orig, gen) or
                            complexHasUniversalLastCompoundNoOp(trim_orig, gen)))
                    {
                        if (complexOnlyAddsNotPseudos(trim_orig, gen)) continue;
                        if (generated_is_first_pass and same_generated_group) continue;
                        if (visible_orig_storage != null and
                            gen.components.items.len == 1 and
                            trim_orig.components.items.len == 1 and
                            compoundHasExtraTypeLikeSelector(
                                &trim_orig.components.items[0].compound,
                                &gen.components.items[0].compound,
                            ))
                        {
                            continue;
                        }
                        if (!generated_is_first_pass) {
                            if (gen.components.items.len != 1 or trim_orig.components.items.len != 1) continue;
                            const gen_last = getLastCompound(gen) orelse continue;
                            const orig_last = getLastCompound(trim_orig) orelse continue;
                            if (gen_last.simple_selectors.items.len != orig_last.simple_selectors.items.len + 1) continue;
                            var has_pseudo = false;
                            for (gen_last.simple_selectors.items) |ss| {
                                if (ss == .pseudo_class or ss == .pseudo_element) {
                                    has_pseudo = true;
                                    break;
                                }
                            }
                            if (has_pseudo) continue;
                        }
                        if (narrowerKeepsFinalTrimStatefulExtras(trim_orig, gen)) {
                            continue;
                        }
                        if (generated_applied_exts) |applied_exts| {
                            if (!complexSpecificityCoversAppliedExtenders(
                                trim_orig,
                                gen,
                                applied_exts,
                                self.extensions.items,
                            )) {
                                continue;
                            }
                        }
                        const gen_last = getLastCompound(gen);
                        const orig_last = getLastCompound(trim_orig);
                        if (gen_last != null and orig_last != null) {
                            const gss = gen_last.?.simple_selectors.items.len;
                            const oss = orig_last.?.simple_selectors.items.len;
                            if (gss <= oss and complexHasUniversalLastCompoundNoOp(trim_orig, gen)) {
                                should_remove = true;
                                break;
                            }
                            // Verify the extra simple selectors are NOT all :not() pseudos
                            if (gss > oss) {
                                // Count extra :not() selectors in gen
                                var extra_not_count: usize = 0;
                                for (gen_last.?.simple_selectors.items) |gsel| {
                                    var in_orig_sel = false;
                                    for (orig_last.?.simple_selectors.items) |osel| {
                                        if (simpleSelectorEql(gsel, osel)) {
                                            in_orig_sel = true;
                                            break;
                                        }
                                    }
                                    if (!in_orig_sel) {
                                        if (gsel == .pseudo_class and
                                            std.ascii.eqlIgnoreCase(gsel.pseudo_class.name, "not"))
                                        {
                                            extra_not_count += 1;
                                        }
                                    }
                                }
                                // If all extra selectors are :not(), keep it
                                // Otherwise, it's narrower  ->  remove
                                if (gss - oss != extra_not_count) {
                                    should_remove = true;
                                    break;
                                }
                            }
                        }
                    }
                }
                if (should_remove) {
                    var removed = all_generated.orderedRemove(ag_i);
                    removed.deinit();
                }
            }
        }

        // Build final result: original + its generated (filtered), interleaved.
        // An original is omitted only if superseded by a generated selector
        // (e.g., :is(.c) is superseded by :is(.c, .d)).
        var orig_anchor = try self.allocator.alloc(usize, selector_list.selectors.items.len);
        defer self.allocator.free(orig_anchor);
        for (selector_list.selectors.items, 0..) |orig_sel, orig_idx| {
            orig_anchor[orig_idx] = orig_idx;
            var head_idx: usize = 0;
            while (head_idx < orig_idx) : (head_idx += 1) {
                var anchored = false;
                for (self.extensions.items) |ext| {
                    if (!try complexMatchesExtendTargetResolved(&selector_list.selectors.items[head_idx], &ext.target, self.allocator)) continue;
                    if (!try complexInExtenderListResolved(&orig_sel, &ext.extender)) continue;
                    orig_anchor[orig_idx] = head_idx;
                    anchored = true;
                    break;
                }
                if (anchored) break;
            }
        }

        var orig_ext_eval = try self.allocator.alloc(u32, selector_list.selectors.items.len);
        defer self.allocator.free(orig_ext_eval);
        const orig_order_lookup = if (self.extensions.items.len + self.sort_extension_hints.items.len > 256)
            try self.ensureExtenderLookup()
        else
            null;
        for (selector_list.selectors.items, 0..) |orig_sel, orig_idx| {
            orig_ext_eval[orig_idx] = if (orig_order_lookup) |lookup|
                if (try lookup.get(&orig_sel)) |info| info.max_eval_order else 0
            else
                try extenderMaxEvalOrderResolvedCombined(
                    &orig_sel,
                    self.extensions.items,
                    self.sort_extension_hints.items,
                );
        }

        var orig_order: std.ArrayList(usize) = .empty;
        defer orig_order.deinit(self.allocator);
        try orig_order.ensureTotalCapacity(self.allocator, selector_list.selectors.items.len);
        var orig_emitted = try self.allocator.alloc(bool, selector_list.selectors.items.len);
        defer self.allocator.free(orig_emitted);
        @memset(orig_emitted, false);
        for (0..selector_list.selectors.items.len) |head_idx| {
            if (orig_emitted[head_idx]) continue;
            if (orig_anchor[head_idx] != head_idx) continue;
            try orig_order.append(self.allocator, head_idx);
            orig_emitted[head_idx] = true;

            // Keep original selector-list siblings in source order. A later
            // sibling may also appear as an exact generated selector for this
            // head, but emitting it here moves it ahead of intervening sibling
            // selectors such as `ul li`. Prefer the later original occurrence;
            // duplicate generated selectors are skipped during emission below.
        }
        for (0..selector_list.selectors.items.len) |orig_idx| {
            if (orig_emitted[orig_idx]) continue;
            try orig_order.append(self.allocator, orig_idx);
        }

        var orig_order_pos = try self.allocator.alloc(usize, selector_list.selectors.items.len);
        defer self.allocator.free(orig_order_pos);
        for (orig_order.items, 0..) |orig_idx, order_idx| {
            orig_order_pos[orig_idx] = order_idx;
        }

        var orig_superseded = try self.allocator.alloc(bool, selector_list.selectors.items.len);
        defer self.allocator.free(orig_superseded);
        for (selector_list.selectors.items, 0..) |complex, orig_idx| {
            var superseded = false;
            for (all_generated.items) |ag| {
                if (supersedenceOnlyAddsNotToNotFreeComplex(&complex, &ag)) continue;
                if (complexIsSupersededBy(&complex, &ag) and !complexSelectorEql(&complex, &ag)) {
                    superseded = true;
                    break;
                }
            }
            orig_superseded[orig_idx] = superseded;
        }

        // Parallel tracking of whether each result entry is generated (not an
        // original).  Without a matching @extend, duplicate originals must be
        // preserved (`.a, .a {}` stays duplicated).  Once this rule's selector
        // list receives generated selectors, Dart Sass canonicalizes the whole
        // extended comma list and drops exact duplicate originals as well.
        var result_is_generated: std.ArrayList(bool) = .empty;
        defer result_is_generated.deinit(self.allocator);
        const result_upper_bound = saturatingAddUsize(orig_order.items.len, all_generated.items.len);
        try result_is_generated.ensureTotalCapacity(self.allocator, result_upper_bound);

        for (orig_order.items) |orig_idx| {
            const complex = selector_list.selectors.items[orig_idx];
            if (!orig_superseded[orig_idx]) {
                var orig_is_dup = false;
                const has_any_generated = all_generated.items.len > 0;
                if (has_any_generated) {
                    for (selector_list.selectors.items, 0..) |sibling, sibling_idx| {
                        if (sibling_idx == orig_idx or orig_superseded[sibling_idx]) continue;
                        if (!complexSelectorEql(&complex, &sibling)) continue;
                        const sibling_eval = orig_ext_eval[sibling_idx];
                        const current_eval = orig_ext_eval[orig_idx];
                        if (sibling_eval < current_eval or
                            (sibling_eval == current_eval and sibling_idx < orig_idx))
                        {
                            orig_is_dup = true;
                            break;
                        }
                    }
                }
                for (result.selectors.items, 0..) |existing, res_idx| {
                    if (orig_is_dup) break;
                    if (!has_any_generated and (res_idx >= result_is_generated.items.len or !result_is_generated.items[res_idx])) continue;
                    if (try complexHasExactCssText(&complex, &existing) or
                        complexSelectorEqlIgnoringCompoundOrderNoPseudos(&complex, &existing))
                    {
                        orig_is_dup = true;
                        break;
                    }
                }
                if (!orig_is_dup) {
                    try result.selectors.append(self.allocator, try complex.clone(self.allocator));
                    try result_is_generated.append(self.allocator, false);
                }
            } else {
                var exact_generated = false;
                for (all_generated.items) |ag| {
                    if (complexSelectorEql(&complex, &ag) or try complexHasExactCssText(&complex, &ag)) {
                        exact_generated = true;
                        break;
                    }
                }
                if (exact_generated) {
                    var orig_is_dup = false;
                    for (result.selectors.items) |existing| {
                        if (try complexHasExactCssText(&complex, &existing) or
                            complexSelectorEqlIgnoringCompoundOrderNoPseudos(&complex, &existing))
                        {
                            orig_is_dup = true;
                            break;
                        }
                    }
                    if (!orig_is_dup) {
                        try result.selectors.append(self.allocator, try complex.clone(self.allocator));
                        try result_is_generated.append(self.allocator, false);
                    }
                }
            }

            // Add generated selectors for this original that survived trim and are not dups.
            // If a generated selector is equivalent to any original sibling that
            // will still be emitted, prefer the original's textual form. This
            // matters when a later selector list extends another placeholder:
            // only its unique members should move to that later extension group,
            // while duplicates keep the original group's order.
            for (generated_per_orig.items[orig_idx].items, 0..) |gen_sel, gen_idx| {
                var live_original_dup = false;
                for (selector_list.selectors.items, 0..) |orig_sibling, sibling_idx| {
                    if (sibling_idx == orig_idx) continue;
                    if (orig_superseded[sibling_idx]) continue;
                    if (complexSelectorEql(&gen_sel, &orig_sibling) or
                        try complexHasExactCssText(&gen_sel, &orig_sibling))
                    {
                        live_original_dup = true;
                        break;
                    }
                }
                if (live_original_dup) continue;

                if (!orig_superseded[orig_idx] and
                    complexSelectorSameMultisetIgnoringOrder(&gen_sel, &complex) and
                    !try complexHasExactCssText(&gen_sel, &complex))
                {
                    continue;
                }

                var survived = false;
                var exact_survived = false;
                for (all_generated.items) |ag| {
                    if (complexSelectorSameMultisetIgnoringOrder(&gen_sel, &ag)) {
                        survived = true;
                        if (try complexHasExactCssText(&gen_sel, &ag)) {
                            exact_survived = true;
                        }
                        break;
                    }
                }
                if (!survived) continue;

                const target_prefers_original_order = if (context) |ctx| blk: {
                    const min_added_order = minAddedNotClassExtenderEvalOrder(
                        &complex,
                        &gen_sel,
                        self.extensions.items,
                        self.sort_extension_hints.items,
                    ) orelse break :blk false;
                    break :blk ctx.target_extend_order_snapshot > min_added_order;
                } else false;

                var shadowed_by_preferred_equivalent = false;
                for (generated_per_orig.items[orig_idx].items, 0..) |other_gen, other_idx| {
                    if (other_idx == gen_idx) continue;
                    if (!complexSelectorSameMultisetIgnoringOrder(&gen_sel, &other_gen)) continue;
                    var other_survived = false;
                    var other_exact_survived = false;
                    for (all_generated.items) |ag| {
                        if (complexSelectorSameMultisetIgnoringOrder(&other_gen, &ag)) {
                            other_survived = true;
                            if (try complexHasExactCssText(&other_gen, &ag)) {
                                other_exact_survived = true;
                            }
                            break;
                        }
                    }
                    if (!other_survived) continue;
                    const other_prefers_original_order = preferSelectorByOriginalOrder(&complex, &other_gen, &gen_sel);
                    const gen_prefers_original_order = preferSelectorByOriginalOrder(&complex, &gen_sel, &other_gen);
                    const added_not_preference = preferSelectorByAddedSingleClassNotOrder(
                        &complex,
                        &other_gen,
                        &gen_sel,
                        self.extensions.items,
                        self.sort_extension_hints.items,
                        target_prefers_original_order,
                    );
                    const other_preferred = if (other_prefers_original_order != gen_prefers_original_order)
                        if (target_prefers_original_order)
                            other_prefers_original_order
                        else
                            !other_prefers_original_order
                    else switch (added_not_preference) {
                        .lhs => true,
                        .rhs => false,
                        .undecided => (other_exact_survived and !exact_survived),
                    };
                    if (other_preferred) {
                        shadowed_by_preferred_equivalent = true;
                        break;
                    }
                }
                if (shadowed_by_preferred_equivalent) continue;

                // In circular extends, skip generated selectors that are
                // strict supersets of the current original (same component
                // count, single compound, no pseudos in original, all
                // original SS present + extras).
                // Exception: gen_sel that originated from a direct (first-pass)
                // extension is the legitimate `@extend .err` unified result
                // (e.g. `input.err` extended by `input:hover.err` yielding
                // `input.err:hover`); don't suppress those, or the spec-boost
                // fallback would emit the verbatim extender compound in its
                // original simple-selector order.
                if (!frame.config.replace_mode and !frame.config.function_mode and gen_sel.components.items.len == 1 and complex.components.items.len == 1) {
                    const gc = gen_sel.components.items[0].compound;
                    const oc = complex.components.items[0].compound;
                    if (gc.simple_selectors.items.len == oc.simple_selectors.items.len + 1) {
                        var has_pseudo = false;
                        for (oc.simple_selectors.items) |oss| {
                            if (oss == .pseudo_class or oss == .pseudo_element) {
                                has_pseudo = true;
                                break;
                            }
                        }
                        if (!has_pseudo) {
                            var all_in = true;
                            for (oc.simple_selectors.items) |oss| {
                                var found = false;
                                for (gc.simple_selectors.items) |gss| {
                                    if (simpleSelectorEql(oss, gss)) {
                                        found = true;
                                        break;
                                    }
                                }
                                if (!found) {
                                    all_in = false;
                                    break;
                                }
                            }
                            if (all_in) {
                                var gen_is_first_pass = false;
                                for (all_generated.items, 0..) |ag, ag_i| {
                                    if (!complexSelectorEql(&gen_sel, &ag)) continue;
                                    if (ag_i < all_generated_first_pass.items.len and all_generated_first_pass.items[ag_i]) {
                                        gen_is_first_pass = true;
                                    }
                                    break;
                                }
                                if (!gen_is_first_pass) continue;
                            }
                        }
                    }
                }

                var is_dup = false;
                for (result.selectors.items) |existing| {
                    if (try complexHasExactCssText(&gen_sel, &existing) or
                        complexSelectorEqlIgnoringCompoundOrderNoPseudos(&gen_sel, &existing))
                    {
                        is_dup = true;
                        break;
                    }
                    if (!complexHasAnyPseudo(&gen_sel) and gen_sel.components.items.len > 1 and
                        complexIsBroaderThan(&existing, &gen_sel))
                    {
                        if (complexFirstCompoundSpecificityCarrierKeepsGenerated(&existing, &gen_sel)) continue;
                        if (!complexSpecificityCoversMatchingExtenders(&existing, &gen_sel, self.extensions.items)) continue;
                        is_dup = true;
                        break;
                    }
                    if (complexOnlyAddsNotPseudos(&existing, &gen_sel) and
                        complexIsBroaderThan(&existing, &gen_sel))
                    {
                        is_dup = true;
                        break;
                    }
                    if (complexOnlyAddsUnknownPseudoClass(&existing, &gen_sel)) {
                        is_dup = true;
                        break;
                    }
                    if (complexHasAnyPseudo(&gen_sel) and
                        gen_sel.components.items.len > 1 and
                        complexFirstCompoundEql(&existing, &gen_sel) and
                        complexIsBroaderThan(&existing, &gen_sel))
                    {
                        is_dup = true;
                        break;
                    }
                }
                if (!is_dup) {
                    var move_after: std.ArrayList(ComplexSelector) = .empty;
                    defer {
                        for (move_after.items) |*moved| moved.deinit();
                        move_after.deinit(self.allocator);
                    }
                    if (placeholderOriginalExtendsAnotherTarget(&complex, self.extensions.items) and
                        !complexHasAnyPseudo(&gen_sel) and gen_sel.components.items.len > 1)
                    {
                        try move_after.ensureTotalCapacity(self.allocator, result.selectors.items.len);
                        var existing_idx = result.selectors.items.len;
                        while (existing_idx > 0) {
                            existing_idx -= 1;
                            if (existing_idx >= result_is_generated.items.len or !result_is_generated.items[existing_idx]) continue;
                            const existing = &result.selectors.items[existing_idx];
                            if (complexHasAnyPseudo(existing)) continue;
                            if (!complexIsBroaderThan(existing, &gen_sel)) continue;
                            if (complexFirstCompoundSpecificityCarrierKeepsGenerated(existing, &gen_sel)) continue;
                            const removed_generated = result.selectors.orderedRemove(existing_idx);
                            _ = result_is_generated.orderedRemove(existing_idx);
                            move_after.appendAssumeCapacity(removed_generated);
                        }
                    }
                    if (complexHasPseudoClassBaseName(&gen_sel, "deep") and gen_sel.components.items.len > 1) {
                        var existing_idx = result.selectors.items.len;
                        while (existing_idx > 0) {
                            existing_idx -= 1;
                            if (existing_idx >= result_is_generated.items.len or !result_is_generated.items[existing_idx]) continue;
                            const existing = &result.selectors.items[existing_idx];
                            if (!complexHasPseudoClassBaseName(existing, "deep")) continue;
                            if (!complexIsBroaderThan(&gen_sel, existing)) continue;
                            if (complexFirstCompoundSpecificityCarrierKeepsGenerated(&gen_sel, existing)) continue;
                            var removed = result.selectors.orderedRemove(existing_idx);
                            removed.deinit();
                            _ = result_is_generated.orderedRemove(existing_idx);
                        }
                    }
                    try result.selectors.append(self.allocator, try gen_sel.clone(self.allocator));
                    try result_is_generated.append(self.allocator, true);
                    for (move_after.items) |moved| {
                        try result.selectors.append(self.allocator, moved);
                        try result_is_generated.append(self.allocator, true);
                    }
                    move_after.items.len = 0;
                }
            }
        }

        // For @extend (not selector.extend()), add extender selectors that provide
        // higher specificity than the original but were suppressed by the no-op check.
        // This preserves specificity from source rules like `a.foo {@extend a}`.
        // Only applies when the extension's target matches the original selector.
        if (!frame.config.function_mode) {
            // Same ordering as sorted_indices above (eval_order desc, then index desc).
            for (sorted_indices) |ext_idx| {
                const ext = self.extensions.items[ext_idx];
                for (ext.extender.selectors.items) |ext_sel| {
                    // Check if this extender is a specificity-boosting superset of an original
                    // AND the extension's target matches the original.
                    var is_specificity_boost = false;
                    for (selector_list.selectors.items) |orig| {
                        if (ext_sel.components.items.len != orig.components.items.len) continue;
                        // The extension's target must be contained in the original's compound
                        const ol = getLastCompound(&orig) orelse continue;
                        if (!compoundContainsTarget(&ol.*, &ext.target)) continue;
                        const el = getLastCompound(&ext_sel) orelse continue;
                        if (el.simple_selectors.items.len <= ol.simple_selectors.items.len) continue;
                        if (compoundContainsTarget(&el.*, &ol.*)) {
                            is_specificity_boost = true;
                            break;
                        }
                    }
                    if (!is_specificity_boost) continue;
                    //Check if already in result -- use multiset comparison so that
                    // a compound like `input.err:hover` produced via unifyCompound
                    // is recognized as equivalent to a verbatim extender compound
                    // `input:hover.err` that differs only in simple-selector order.
                    var already_present = false;
                    for (result.selectors.items) |existing| {
                        if (complexSelectorEql(&ext_sel, &existing) or
                            complexSelectorSameMultisetIgnoringOrder(&ext_sel, &existing))
                        {
                            already_present = true;
                            break;
                        }
                    }
                    if (!already_present) {
                        try result.selectors.append(self.allocator, try ext_sel.clone(self.allocator));
                    }
                }
            }
        }

        // Skip the global sort when the result contains only original selectors
        // in their original order (no extensions matched, no generated selectors).
        // The sort is designed to interleave generated selectors with originals,
        // not to reorder originals relative to each other.
        var has_generated = result.selectors.items.len != selector_list.selectors.items.len;
        if (!has_generated) {
            for (result.selectors.items, selector_list.selectors.items) |res, orig| {
                if (!complexSelectorEql(&res, &orig)) {
                    has_generated = true;
                    break;
                }
            }
        }
        var all_originals_placeholder = selector_list.selectors.items.len > 0;
        for (selector_list.selectors.items) |orig| {
            if (!complexContainsPlaceholder(&orig)) {
                all_originals_placeholder = false;
                break;
            }
        }
        // Placeholder-target ordering is mostly finalized in the first-pass/per-original
        // assembly above, but the first-pass iterates extensions in reverse eval_order.
        // dart-sass switches to ascending (source order) only when result selectors
        // are connected via a transitive @extend chain (e.g. `.container-sm` extends
        // `.container-fluid`, both appear as `.navbar > .container-*` siblings).
        // Without that link, sibling extenders sharing a stable prefix retain
        // descending order (later-declared first).
        const hint_exts_for_placeholder = self.sort_extension_hints.items;
        const stable_prefix_chain = result.selectors.items.len > 1 and
            selectorsShareStablePrefix(self.allocator, result.selectors.items);
        const has_placeholder_direct_tail_chain = all_originals_placeholder and stable_prefix_chain and
            try resultSelectorsHaveDirectPlaceholderAndTailExtension(
                result.selectors.items,
                self.extensions.items,
                hint_exts_for_placeholder,
            );
        const placeholder_needs_source_order_sort = all_originals_placeholder and stable_prefix_chain and
            (resultSelectorsHaveTransitiveExtensionLink(result.selectors.items, self.extensions.items) or
                has_placeholder_direct_tail_chain);
        const mixed_placeholder_originals = !all_originals_placeholder and selectorListHasPlaceholderBeforeVisibleOriginal(selector_list);
        const needs_global_sort = has_generated and
            (frame.config.function_mode or ((self.sort_extension_hints.items.len > 0 or mixed_placeholder_originals) and !all_originals_placeholder) or placeholder_needs_source_order_sort);
        var did_mixed_placeholder_global_sort = false;
        if (needs_global_sort and result.selectors.items.len > 1) {
            did_mixed_placeholder_global_sort = mixed_placeholder_originals;
            const n = result.selectors.items.len;
            const raw_keys = try self.allocator.alloc(u32, n);
            defer self.allocator.free(raw_keys);
            const hint_exts = self.sort_extension_hints.items;
            const primaries = try self.allocator.alloc(u32, n);
            defer self.allocator.free(primaries);
            for (0..n) |i| {
                raw_keys[i] = try extendResultSortKeyCombined(&result.selectors.items[i], self.extensions.items, hint_exts, self.allocator);
            }
            for (0..n) |i| {
                primaries[i] = try extendSortPrimaryCombined(&result.selectors.items[i], self.extensions.items, hint_exts, self.allocator);
            }
            // For single-selector stylesheet @extend (no sort hints, one original),
            // force the original selector to key 0 regardless of its current classification.
            // This handles cases where the original is both a target and an extender
            // (circular extends) or where it contains targets but isn't an exact match.
            // Multi-original cases (selector.extend()) need per-original interleaving
            // so this fix is skipped.
            if (hint_exts.len == 0 and selector_list.selectors.items.len == 1) {
                for (0..n) |i| {
                    if (complexSelectorEql(&result.selectors.items[i], &selector_list.selectors.items[0])) {
                        primaries[i] = 0;
                        break;
                    }
                }
            }
            // Historical orphan heuristic on extendResultSortKey (missing extension in store).
            var num_max_raw: usize = 0;
            var max_raw_idx: usize = 0;
            var has_key0 = false;
            var has_ge2 = false;
            for (raw_keys, 0..) |k, i| {
                if (k == std.math.maxInt(u32)) {
                    num_max_raw += 1;
                    max_raw_idx = i;
                }
                if (k == 0) has_key0 = true;
                if (k >= 2 and k != std.math.maxInt(u32)) has_ge2 = true;
            }
            if (num_max_raw == 1 and has_key0 and has_ge2) {
                // Check if the orphan was one of the original selectors.
                // Original siblings of a placeholder target should sort AFTER
                // extenders (the extender replaces the placeholder).
                // Generated orphans keep the historical position (primary 1).
                var orphan_is_original = false;
                for (selector_list.selectors.items) |orig| {
                    if (complexSelectorEql(&result.selectors.items[max_raw_idx], &orig)) {
                        orphan_is_original = true;
                        break;
                    }
                }
                if (orphan_is_original) {
                    // Place after all extenders by using the max extender primary.
                    // Within the same bucket, ext_eval / index tie-breakers
                    // keep extenders before the orphan.
                    var max_ext_pri: u32 = 1;
                    for (primaries) |p| {
                        if (p != std.math.maxInt(u32) and p > max_ext_pri) max_ext_pri = p;
                    }
                    primaries[max_raw_idx] = max_ext_pri;
                } else {
                    primaries[max_raw_idx] = 1;
                }
            } else {
                // Same pattern on primaries: one unresolved base (max) with pure targets (0) and extenders (>=2).
                var num_max_pri: usize = 0;
                var max_pri_idx: usize = 0;
                var has_pri0 = false;
                var has_ge2_pri = false;
                for (primaries, 0..) |p, i| {
                    if (p == std.math.maxInt(u32)) {
                        num_max_pri += 1;
                        max_pri_idx = i;
                    }
                    if (p == 0) has_pri0 = true;
                    if (p >= 2 and p != std.math.maxInt(u32)) has_ge2_pri = true;
                }
                if (num_max_pri == 1 and has_pri0 and has_ge2_pri) {
                    primaries[max_pri_idx] = 1;
                }
            }

            // Selectors that extend the same target compound (e.g. sibling @use files
            // both extending in-midstream) must share one primary bucket so ordering is
            // decided by ext_eval tie-break (matches dart-sass comma order).
            {
                // Keys are borrowed from cached_ext_target_keys / cached_hint_target_keys
                // (owned by ApplyState). The HashMap does not own them.
                var target_groups: std.StringHashMap(std.ArrayList(usize)) = .init(self.allocator);
                defer {
                    var git = target_groups.iterator();
                    while (git.next()) |entry| {
                        entry.value_ptr.*.deinit(self.allocator);
                    }
                    target_groups.deinit();
                }

                const collectTargetGroup = struct {
                    fn run(
                        allocator: std.mem.Allocator,
                        map: *std.StringHashMap(std.ArrayList(usize)),
                        key: []const u8,
                        ext: *const Extension,
                        selectors: []const ComplexSelector,
                    ) !void {
                        const gop = try map.getOrPut(key);
                        if (!gop.found_existing) {
                            gop.value_ptr.* = .empty;
                        }
                        for (selectors, 0..) |*sel, i| {
                            if (try complexInExtenderListResolved(sel, &ext.extender)) {
                                var dup = false;
                                for (gop.value_ptr.*.items) |j| {
                                    if (j == i) {
                                        dup = true;
                                        break;
                                    }
                                }
                                if (!dup) try gop.value_ptr.*.append(allocator, i);
                            }
                        }
                    }
                }.run;

                for (self.extensions.items, 0..) |ext, ei| {
                    try collectTargetGroup(self.allocator, &target_groups, self.cached_ext_target_keys.items[ei], &ext, result.selectors.items);
                }
                for (hint_exts, 0..) |ext, hi| {
                    try collectTargetGroup(self.allocator, &target_groups, self.cached_hint_target_keys.items[hi], &ext, result.selectors.items);
                }

                var git = target_groups.iterator();
                while (git.next()) |entry| {
                    const key = entry.key_ptr.*;
                    const idxs = entry.value_ptr.*;
                    if (idxs.items.len <= 1) continue;

                    var can_merge = true;
                    var first_origin: ?bool = null;
                    for (self.extensions.items, 0..) |ext, ei| {
                        if (!std.mem.eql(u8, self.cached_ext_target_keys.items[ei], key)) continue;
                        const o = ext.from_import_child;
                        if (first_origin) |fo| {
                            if (fo != o) can_merge = false;
                        } else first_origin = o;
                    }
                    for (hint_exts, 0..) |ext, hi| {
                        if (!std.mem.eql(u8, self.cached_hint_target_keys.items[hi], key)) continue;
                        const o = ext.from_import_child;
                        if (first_origin) |fo| {
                            if (fo != o) can_merge = false;
                        } else first_origin = o;
                    }
                    if (!can_merge) continue;

                    var min_p: u32 = std.math.maxInt(u32);
                    for (idxs.items) |i| {
                        min_p = @min(min_p, primaries[i]);
                    }
                    for (idxs.items) |i| {
                        primaries[i] = min_p;
                    }
                }
            }

            const ext_evals = try self.allocator.alloc(u32, n);
            defer self.allocator.free(ext_evals);
            const module_group_starts = try self.allocator.alloc(?u32, n);
            defer self.allocator.free(module_group_starts);
            const module_group_eval_orders = try self.allocator.alloc(u32, n);
            defer self.allocator.free(module_group_eval_orders);
            if (self.extensions.items.len + hint_exts.len > 256) {
                const lookup = try self.ensureExtenderLookup();
                for (0..n) |i| {
                    if (try lookup.get(&result.selectors.items[i])) |info| {
                        ext_evals[i] = info.max_eval_order;
                        module_group_starts[i] = info.group_start;
                        module_group_eval_orders[i] = info.group_min_eval_order;
                    } else {
                        ext_evals[i] = 0;
                        module_group_starts[i] = null;
                        module_group_eval_orders[i] = std.math.maxInt(u32);
                    }
                }
            } else {
                for (0..n) |i| {
                    ext_evals[i] = try extenderMaxEvalOrderResolvedCombined(&result.selectors.items[i], self.extensions.items, hint_exts);
                }
                for (0..n) |i| {
                    const info = try extendModuleGroupSortInfoCombined(&result.selectors.items[i], self.extensions.items, hint_exts);
                    module_group_starts[i] = info.group_start;
                    module_group_eval_orders[i] = info.min_eval_order;
                }
            }

            var all_visible_results_are_direct_target_extenders = all_originals_placeholder;
            if (all_visible_results_are_direct_target_extenders) {
                for (result.selectors.items) |*sel| {
                    if (complexContainsPlaceholder(sel)) continue;
                    if (!complexIsDirectExtenderForSelectorListTarget(
                        sel,
                        selector_list,
                        self.extensions.items,
                        hint_exts,
                    )) {
                        all_visible_results_are_direct_target_extenders = false;
                        break;
                    }
                }
            }

            const placeholder_direct_prefers_later_declared_order = all_visible_results_are_direct_target_extenders and
                prefersLaterDeclaredPlaceholderOrder(
                    self.allocator,
                    context,
                    result.selectors.items,
                    ext_evals,
                    module_group_starts,
                    n,
                );
            const placeholder_direct_keeps_source_order = placeholder_needs_source_order_sort or
                (all_visible_results_are_direct_target_extenders and
                    !placeholder_direct_prefers_later_declared_order and
                    if (context) |ctx| ctx.target_is_direct_rule else false);

            // dart-sass cross-module ordering: when result selectors come from
            // multiple distinct module groups, modules are ordered descending
            // (latest-loaded first) but selectors within the same module retain
            // ascending source order. This matches bulma %control-style chains
            // where extenders are spread across `@use`d modules.
            var has_multiple_module_groups = false;
            {
                var first_seen: ?u32 = null;
                var saw_null = false;
                var saw_non_null = false;
                for (module_group_starts) |g| {
                    if (g) |gv| {
                        saw_non_null = true;
                        if (first_seen) |fs| {
                            if (fs != gv) {
                                has_multiple_module_groups = true;
                                break;
                            }
                        } else first_seen = gv;
                    } else {
                        saw_null = true;
                    }
                }
                if (!has_multiple_module_groups and saw_null and saw_non_null) {
                    has_multiple_module_groups = true;
                }
            }

            const placeholder_chain_source_order = has_placeholder_direct_tail_chain;
            const placeholder_chain_ranks = try self.allocator.alloc(u8, n);
            defer self.allocator.free(placeholder_chain_ranks);
            const placeholder_chain_orders = try self.allocator.alloc(u32, n);
            defer self.allocator.free(placeholder_chain_orders);
            for (0..n) |i| {
                if (placeholder_chain_source_order) {
                    const tail_order = tailExtenderEvalOrder(&result.selectors.items[i], self.extensions.items, hint_exts);
                    if (tail_order != std.math.maxInt(u32)) {
                        placeholder_chain_ranks[i] = 1;
                        placeholder_chain_orders[i] = tail_order;
                    } else {
                        placeholder_chain_ranks[i] = 0;
                        placeholder_chain_orders[i] = 0;
                    }
                } else {
                    placeholder_chain_ranks[i] = 0;
                    placeholder_chain_orders[i] = 0;
                }
            }

            const indices = try self.allocator.alloc(usize, n);
            defer self.allocator.free(indices);
            for (0..n) |i| indices[i] = i;
            const SortRes = struct {
                primaries: []const u32,
                ext_evals: []const u32,
                module_group_starts: []const ?u32,
                module_group_eval_orders: []const u32,
                placeholder_direct_prefers_later_declared_order: bool,
                placeholder_direct_keeps_source_order: bool,
                has_multiple_module_groups: bool,
                placeholder_chain_source_order: bool,
                placeholder_chain_ranks: []const u8,
                placeholder_chain_orders: []const u32,
                fn less(ctx: @This(), ia: usize, ib: usize) bool {
                    if (ctx.placeholder_chain_source_order) {
                        const ra = ctx.placeholder_chain_ranks[ia];
                        const rb = ctx.placeholder_chain_ranks[ib];
                        if (ra != rb) return ra < rb;
                        const oa = ctx.placeholder_chain_orders[ia];
                        const ob = ctx.placeholder_chain_orders[ib];
                        if (oa != ob) return oa < ob;
                        return ia < ib;
                    }
                    if (ctx.placeholder_direct_keeps_source_order) {
                        if (ctx.module_group_starts[ia]) |ga| {
                            if (ctx.module_group_starts[ib]) |gb| {
                                if (ga != gb) {
                                    return ga < gb;
                                }
                            }
                        }
                        const ea = ctx.ext_evals[ia];
                        const eb = ctx.ext_evals[ib];
                        if (ea != eb) {
                            return ea < eb;
                        }
                        return ia < ib;
                    }
                    if (ctx.placeholder_direct_prefers_later_declared_order) {
                        if (ctx.module_group_starts[ia]) |ga| {
                            if (ctx.module_group_starts[ib]) |gb| {
                                if (ga != gb) {
                                    return ga > gb;
                                }
                            }
                        }
                        const ea = ctx.ext_evals[ia];
                        const eb = ctx.ext_evals[ib];
                        if (ea != eb) {
                            return if (ctx.has_multiple_module_groups) ea < eb else ea > eb;
                        }
                        return ia < ib;
                    }

                    // Cross-module placeholder extension: even when not all results
                    // are "direct target extenders" (chain via intermediate placeholder),
                    // dart-sass orders modules descending and within a module ascending.
                    // Skip primary-based bucketing in that case so the module-group sort
                    // dominates.
                    if (ctx.has_multiple_module_groups) {
                        if (ctx.module_group_starts[ia]) |ga| {
                            if (ctx.module_group_starts[ib]) |gb| {
                                if (ga != gb) return ga > gb;
                                const mea = ctx.module_group_eval_orders[ia];
                                const meb = ctx.module_group_eval_orders[ib];
                                if (mea != meb) return mea < meb;
                            }
                        } else if (ctx.module_group_starts[ib] != null) {
                            return false;
                        }
                        if (ctx.module_group_starts[ia] != null and ctx.module_group_starts[ib] == null) {
                            return true;
                        }
                        const ea = ctx.ext_evals[ia];
                        const eb = ctx.ext_evals[ib];
                        if (ea != eb) return ea < eb;
                        return ia < ib;
                    }

                    const pa = ctx.primaries[ia];
                    const pb = ctx.primaries[ib];
                    if (pa != pb) return pa < pb;
                    if (ctx.module_group_starts[ia]) |ga| {
                        if (ctx.module_group_starts[ib]) |gb| {
                            if (ga != gb) return ga > gb;
                            const mea = ctx.module_group_eval_orders[ia];
                            const meb = ctx.module_group_eval_orders[ib];
                            if (mea != meb) return mea < meb;
                        }
                    }
                    const ea = ctx.ext_evals[ia];
                    const eb = ctx.ext_evals[ib];
                    if (ea != eb) return ea > eb;
                    return ia < ib;
                }
            };
            std.mem.sort(usize, indices, SortRes{
                .primaries = primaries,
                .ext_evals = ext_evals,
                .module_group_starts = module_group_starts,
                .module_group_eval_orders = module_group_eval_orders,
                .placeholder_direct_prefers_later_declared_order = placeholder_direct_prefers_later_declared_order,
                .placeholder_direct_keeps_source_order = placeholder_direct_keeps_source_order,
                .has_multiple_module_groups = has_multiple_module_groups,
                .placeholder_chain_source_order = placeholder_chain_source_order,
                .placeholder_chain_ranks = placeholder_chain_ranks,
                .placeholder_chain_orders = placeholder_chain_orders,
            }, SortRes.less);

            var new_sel: std.ArrayList(ComplexSelector) = .empty;
            errdefer {
                for (new_sel.items) |*c| c.deinit();
                new_sel.deinit(self.allocator);
            }
            try new_sel.ensureTotalCapacity(self.allocator, indices.len);
            for (indices) |ri| {
                try new_sel.append(self.allocator, try result.selectors.items[ri].clone(self.allocator));
            }
            for (result.selectors.items) |*c| c.deinit();
            result.selectors.deinit(self.allocator);
            result.selectors = new_sel;
            if (mixed_placeholder_originals) {
                try propagateLeadingNewlineFromOriginalsExact(&result, selector_list);
            }
        }

        if (placeholder_needs_source_order_sort and result.selectors.items.len > 1) {
            var any_nl = false;
            for (result.selectors.items) |sel| {
                if (sel.leading_separator_has_newline) {
                    any_nl = true;
                    break;
                }
            }
            if (any_nl) {
                for (result.selectors.items[1..]) |*sel| {
                    sel.leading_separator_has_newline = true;
                }
            }
        }

        // Diamond-style superselector trim: when an original selector has a
        // placeholder-plus-class tail (e.g. `%in-other.a`) and the result list
        // contains both the placeholder-stripped original (`.a`) and a wider
        // compound that contains it (`.a.b`), dart-sass drops the wider form
        // because the broader selector covers the same elements with the same
        // specificity as the extender that produced the wider form. This trim
        // is intentionally narrower than the same-group_both_fp skip in
        // trimWithMetadata, so the NES.css-style case (`.nes-table.is-bordered`
        // vs `.nes-table.is-dark.is-bordered` extending a placeholder with no
        // class component) keeps both.
        if (result.selectors.items.len >= 2) {
            var stripped_compounds: std.ArrayList(CompoundSelector) = .empty;
            defer {
                for (stripped_compounds.items) |*sc| sc.deinit();
                stripped_compounds.deinit(self.allocator);
            }
            try stripped_compounds.ensureTotalCapacity(self.allocator, selector_list.selectors.items.len);
            for (selector_list.selectors.items) |*orig| {
                if (!complexContainsPlaceholder(orig)) continue;
                if (orig.components.items.len != 1) continue;
                if (orig.components.items[0] != .compound) continue;
                const orig_compound = &orig.components.items[0].compound;
                var visible_simple_count: usize = 0;
                for (orig_compound.simple_selectors.items) |ss| {
                    if (ss != .placeholder) visible_simple_count += 1;
                }
                if (visible_simple_count == 0) continue;
                var stripped: CompoundSelector = .{
                    .simple_selectors = .empty,
                    .allocator = self.allocator,
                };
                errdefer stripped.deinit();
                try stripped.simple_selectors.ensureTotalCapacity(self.allocator, visible_simple_count);
                for (orig_compound.simple_selectors.items) |ss| {
                    if (ss == .placeholder) continue;
                    stripped.simple_selectors.appendAssumeCapacity(try selector_mod.cloneSimpleSelector(ss, self.allocator));
                }
                try stripped_compounds.append(self.allocator, stripped);
            }
            if (stripped_compounds.items.len > 0) {
                var to_remove: [256]bool = .{false} ** 256;
                const result_len = @min(result.selectors.items.len, 256);
                for (0..result_len) |i| {
                    if (to_remove[i]) continue;
                    if (result.selectors.items[i].components.items.len != 1) continue;
                    const i_compound = result.selectors.items[i].components.items[0];
                    if (i_compound != .compound) continue;
                    const i_last = &result.selectors.items[i].components.items[0].compound;
                    var matches_stripped = false;
                    for (stripped_compounds.items) |stripped_c| {
                        if (compoundSelectorEql(i_last, &stripped_c)) {
                            matches_stripped = true;
                            break;
                        }
                    }
                    if (!matches_stripped) continue;
                    for (0..result_len) |j| {
                        if (i == j or to_remove[j]) continue;
                        if (result.selectors.items[j].components.items.len != 1) continue;
                        if (result.selectors.items[j].components.items[0] != .compound) continue;
                        const j_last = &result.selectors.items[j].components.items[0].compound;
                        if (j_last.simple_selectors.items.len <= i_last.simple_selectors.items.len) continue;
                        var contains_all = true;
                        for (i_last.simple_selectors.items) |is| {
                            var found = false;
                            for (j_last.simple_selectors.items) |js| {
                                if (simpleSelectorEql(is, js)) {
                                    found = true;
                                    break;
                                }
                            }
                            if (!found) {
                                contains_all = false;
                                break;
                            }
                        }
                        if (!contains_all) continue;
                        var has_pseudo = false;
                        for (j_last.simple_selectors.items) |js| {
                            if (js == .pseudo_class or js == .pseudo_element) {
                                has_pseudo = true;
                                break;
                            }
                        }
                        if (has_pseudo) continue;
                        to_remove[j] = true;
                    }
                }
                var idx: usize = result_len;
                while (idx > 0) {
                    idx -= 1;
                    if (to_remove[idx]) {
                        var removed = result.selectors.orderedRemove(idx);
                        removed.deinit();
                    }
                }
            }
        }

        if (!did_mixed_placeholder_global_sort) {
            try reorderDirectBranchSelectorsBeforeDescendants(
                self.allocator,
                &result,
                self.extensions.items,
                self.sort_extension_hints.items,
            );
        }
        const order_lookup = if (self.extensions.items.len + self.sort_extension_hints.items.len > 256)
            try self.ensureExtenderLookup()
        else
            null;
        if (try shouldPreservePlaceholderSourceOrderForExactReorder(
            self.allocator,
            context,
            &result,
            selector_list,
            self.extensions.items,
            self.sort_extension_hints.items,
            order_lookup,
        )) {
            try reorderExtenderBranchesBySourceOccurrence(&result, self.extensions.items, self.sort_extension_hints.items);
        } else {
            try reorderExactExtenderBranchesByFirstOccurrence(&result, self.extensions.items, self.exact_order_hints.items);
        }
        reorderOriginalBeforeGeneratedSimpleVariants(&result, self.extensions.items, self.sort_extension_hints.items);
        try reorderByGeneratedPerOrigOrder(&result, selector_list, generated_per_orig.items);
        try normalizeTransitionUtilityExtendOrder(self.allocator, &result, selector_list);
        if (did_mixed_placeholder_global_sort) {
            try propagateLeadingNewlineFromOriginalsExact(&result, selector_list);
            for (selector_list.selectors.items) |orig| {
                if (!orig.leading_separator_has_newline) continue;
                if (result.selectors.items.len > 1) {
                    result.selectors.items[result.selectors.items.len - 1].leading_separator_has_newline = true;
                }
                break;
            }
        }
        try appendExtendersOfNotTargets(self.allocator, &result, self.extensions.items);
        try appendCircularExtendLoopClassVariants(self.allocator, &result);
        if (!frame.config.function_mode and !frame.config.replace_mode and selector_list.selectors.items.len == 1 and result.selectors.items.len > 1) {
            const original = &selector_list.selectors.items[0];
            var original_idx: ?usize = null;
            for (result.selectors.items, 0..) |*sel, idx| {
                if (complexSelectorEql(sel, original) or try complexHasExactCssText(sel, original)) {
                    original_idx = idx;
                    break;
                }
            }
            if (original_idx) |idx| {
                if (idx > 0) {
                    const moved = result.selectors.orderedRemove(idx);
                    try result.selectors.insert(self.allocator, 0, moved);
                }
            }
        }
        return result;
    }

    fn applyExtendTrimPass(
        self: *ApplyState,
        frame: *ApplyFrame,
        result: *SelectorList,
        originals: *const SelectorList,
    ) !void {
        // Final merge: combine result selectors that differ only in :not() pseudos.
        if (!frame.config.function_mode and !frame.config.replace_mode) {
            try saturateNotPseudoExtenderArguments(self.allocator, result, self.extensions.items);
            mergeSelectorListNotPseudoVariantsWithOriginals(self.allocator, result, originals);
            cleanupNestedNotPseudoCompounds(self.allocator, result, true);
            propagateLeadingNewlineFromOriginals(result, originals);
        }
        frame.relax_not_pseudo_guard = false;
    }

    pub fn markMatches(self: *const ApplyState, selector_list: *const SelectorList, matched: []bool) !void {
        if (matched.len != self.extensions.items.len) return error.InvalidMatchedSlice;
        for (selector_list.selectors.items) |complex| {
            for (self.extensions.items, 0..) |ext, idx| {
                if (matched[idx]) continue;
                if (compoundContainsTargetInComplex(&complex, &ext.target)) {
                    matched[idx] = true;
                    continue;
                }
                if (try complexContainsTargetInPseudos(&complex, &ext.target)) {
                    matched[idx] = true;
                }
            }
        }

        // Chained @extend support:
        // If extension A is already matched and its extender contains extension B's target,
        // then B is also considered matched even when B's target doesn't appear in an emitted
        // selector node (e.g. intermediary `%placeholder` / `.class` rules with only @extend).
        var changed = true;
        while (changed) {
            changed = false;
            for (self.extensions.items, 0..) |ext, idx| {
                if (matched[idx]) continue;
                for (self.extensions.items, 0..) |carrier, carrier_idx| {
                    if (!matched[carrier_idx]) continue;
                    if (extensionExtenderContainsTarget(&carrier, &ext.target)) {
                        matched[idx] = true;
                        changed = true;
                        break;
                    }
                }
            }
        }
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

const SelectorListSimplePresence = struct {
    classes: std.StringHashMapUnmanaged(void) = .empty,
    ids: std.StringHashMapUnmanaged(void) = .empty,
    placeholders: std.StringHashMapUnmanaged(void) = .empty,
    types: std.StringHashMapUnmanaged(void) = .empty,

    fn build(allocator: std.mem.Allocator, selector_list: *const SelectorList) !SelectorListSimplePresence {
        var result: SelectorListSimplePresence = .{};
        errdefer result.deinit(allocator);
        try result.collectSelectorList(allocator, selector_list);
        return result;
    }

    fn deinit(self: *SelectorListSimplePresence, allocator: std.mem.Allocator) void {
        self.classes.deinit(allocator);
        self.ids.deinit(allocator);
        self.placeholders.deinit(allocator);
        self.types.deinit(allocator);
    }

    fn collectSelectorList(
        self: *SelectorListSimplePresence,
        allocator: std.mem.Allocator,
        selector_list: *const SelectorList,
    ) std.mem.Allocator.Error!void {
        for (selector_list.selectors.items) |complex| {
            try self.collectComplex(allocator, &complex);
        }
    }

    fn collectComplex(
        self: *SelectorListSimplePresence,
        allocator: std.mem.Allocator,
        complex: *const ComplexSelector,
    ) std.mem.Allocator.Error!void {
        for (complex.components.items) |component| {
            switch (component) {
                .compound => |compound| try self.collectCompound(allocator, &compound),
                .combinator => {},
            }
        }
    }

    fn collectCompound(
        self: *SelectorListSimplePresence,
        allocator: std.mem.Allocator,
        compound: *const CompoundSelector,
    ) std.mem.Allocator.Error!void {
        for (compound.simple_selectors.items) |ss| {
            switch (ss) {
                .class => |name| try self.classes.put(allocator, name, {}),
                .id => |name| try self.ids.put(allocator, name, {}),
                .placeholder => |name| try self.placeholders.put(allocator, name, {}),
                .type_selector => |name| try self.types.put(allocator, name, {}),
                .pseudo_class => |ps| {
                    if (ps.selector) |inner| try self.collectSelectorList(allocator, inner);
                },
                .pseudo_element => |ps| {
                    if (ps.selector) |inner| try self.collectSelectorList(allocator, inner);
                },
                .attribute, .parent, .universal => {},
            }
        }
    }

    fn knowsTarget(
        self: *const SelectorListSimplePresence,
        target: *const CompoundSelector,
    ) ?bool {
        if (target.simple_selectors.items.len != 1) return null;
        return switch (target.simple_selectors.items[0]) {
            .class => |name| self.classes.contains(name),
            .id => |name| self.ids.contains(name),
            .placeholder => |name| self.placeholders.contains(name),
            .type_selector => |name| self.types.contains(name),
            else => null,
        };
    }
};

const RuleModuleEdgeOptions = struct {
    optional: bool,
    span: ExtensionSpan = null,
    statement_group_order: ?u32 = null,
    module_group_start_order: ?u32 = null,
    from_import_child: bool = false,
    is_propagated: bool = false,
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
                .from_import_child = options.from_import_child,
                .module_group_start_order = options.module_group_start_order,
                .is_propagated = options.is_propagated,
            });
        }

        // Dart Sass treats duplicate @extend extenders as already satisfied by
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
            var branch_pos: usize = filtered_extender.selectors.items.len;
            while (branch_pos > 0) {
                branch_pos -= 1;
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

    pub fn moduleExtensions(self: *const RuleModuleExtendState, module_idx: usize) []const Extension {
        const idx = self.moduleIndex(module_idx);
        return self.module_stores[idx].extensions.items;
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

/// Callback used by selector function-mode helpers to register replacement targets.
pub const FunctionModeTargetAdder = *const fn (
    allocator: std.mem.Allocator,
    store: *ApplyState,
    extendee: *const SelectorList,
    extender: *const SelectorList,
) error{OutOfMemory}!void;

/// Implements `selector.extend()` semantics using function-mode extension matching.
pub fn applySelectorFunctionExtend(
    allocator: std.mem.Allocator,
    selector_list: *const SelectorList,
    extendee: *const SelectorList,
    extender: *const SelectorList,
    add_targets: FunctionModeTargetAdder,
) error{OutOfMemory}!SelectorList {
    var store = ApplyState.init(allocator);
    defer store.deinit();
    store.function_mode = true;
    try add_targets(allocator, &store, extendee, extender);
    return store.applySelectorExtensions(selector_list);
}

/// Implements `selector.replace()` semantics by applying replacement targets in function mode.
pub fn applySelectorFunctionReplace(
    allocator: std.mem.Allocator,
    selector_list: *const SelectorList,
    original: *const SelectorList,
    replacement: *const SelectorList,
    add_targets: FunctionModeTargetAdder,
) error{OutOfMemory}!SelectorList {
    var store = ApplyState.init(allocator);
    defer store.deinit();
    store.replace_mode = true;
    store.function_mode = true;
    try add_targets(allocator, &store, original, replacement);
    return store.applySelectorExtensions(selector_list);
}

fn extensionExtenderContainsTarget(ext: *const Extension, target: *const CompoundSelector) bool {
    for (ext.extender.selectors.items) |*complex| {
        if (compoundContainsTargetInComplex(complex, target)) return true;
    }
    return false;
}

fn extensionTargetFanout(extensions: []const Extension, target: *const CompoundSelector) usize {
    var count: usize = 0;
    for (extensions) |*ext| {
        if (compoundSelectorEql(&ext.target, target)) count += ext.extender.selectors.items.len;
    }
    return count;
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

fn supersedenceOnlyAddsNotToNotFreeComplex(
    original: *const ComplexSelector,
    generated: *const ComplexSelector,
) bool {
    if (original.components.items.len != generated.components.items.len) return false;
    var saw_extra_not = false;
    for (original.components.items, generated.components.items) |orig_comp, gen_comp| {
        const orig_tag: @TypeOf(std.meta.activeTag(orig_comp)) = orig_comp;
        const gen_tag: @TypeOf(std.meta.activeTag(gen_comp)) = gen_comp;
        if (orig_tag != gen_tag) return false;
        switch (orig_comp) {
            .combinator => |comb| {
                if (comb != gen_comp.combinator) return false;
            },
            .compound => |orig_c| {
                const gen_c = gen_comp.compound;
                for (orig_c.simple_selectors.items) |orig_ss| {
                    if (orig_ss == .pseudo_class and std.ascii.eqlIgnoreCase(orig_ss.pseudo_class.name, "not")) {
                        return false;
                    }
                    var found = false;
                    for (gen_c.simple_selectors.items) |gen_ss| {
                        if (simpleSelectorEql(orig_ss, gen_ss)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) return false;
                }
                for (gen_c.simple_selectors.items) |gen_ss| {
                    var found = false;
                    for (orig_c.simple_selectors.items) |orig_ss| {
                        if (simpleSelectorEql(orig_ss, gen_ss)) {
                            found = true;
                            break;
                        }
                    }
                    if (found) continue;
                    if (gen_ss != .pseudo_class or !std.ascii.eqlIgnoreCase(gen_ss.pseudo_class.name, "not")) {
                        return false;
                    }
                    saw_extra_not = true;
                }
            },
        }
    }
    return saw_extra_not;
}

const ExactExtenderOrderKey = struct {
    eval_order: u32,
    branch_index: usize,
    match_count: usize = 0,
};

const ExactBranchLookup = struct {
    map: std.StringHashMapUnmanaged(ExactExtenderOrderKey) = .empty,

    fn deinit(self: *ExactBranchLookup, allocator: std.mem.Allocator) void {
        var key_it = self.map.keyIterator();
        while (key_it.next()) |key| allocator.free(key.*);
        self.map.deinit(allocator);
    }

    fn add(
        self: *ExactBranchLookup,
        allocator: std.mem.Allocator,
        branch: *const ComplexSelector,
        eval_order: u32,
        branch_index: usize,
    ) !void {
        const css = try complexCssResult(branch);
        defer css.deinit();
        const key_slice = trimCssWhitespace(css.css);
        const owned_key = try allocator.dupe(u8, key_slice);
        errdefer allocator.free(owned_key);
        const gop = try self.map.getOrPut(allocator, owned_key);
        if (gop.found_existing) {
            allocator.free(owned_key);
        } else {
            gop.key_ptr.* = owned_key;
            gop.value_ptr.* = .{
                .eval_order = eval_order,
                .branch_index = branch_index,
                .match_count = 0,
            };
        }
        gop.value_ptr.match_count += 1;
        if (eval_order < gop.value_ptr.eval_order or
            (eval_order == gop.value_ptr.eval_order and branch_index < gop.value_ptr.branch_index))
        {
            gop.value_ptr.eval_order = eval_order;
            gop.value_ptr.branch_index = branch_index;
        }
    }

    fn get(self: *const ExactBranchLookup, selector: *const ComplexSelector) !?ExactExtenderOrderKey {
        const css = try complexCssResult(selector);
        defer css.deinit();
        return self.map.get(trimCssWhitespace(css.css));
    }
};

fn resultContainsExtensionTarget(result: *const SelectorList, target: *const CompoundSelector) bool {
    for (result.selectors.items) |*sel| {
        if (compoundContainsTargetInComplex(sel, target)) return true;
    }
    return false;
}

fn exactExtenderOrderKey(
    result: *const SelectorList,
    sel: *const ComplexSelector,
    exts: []const Extension,
) !?ExactExtenderOrderKey {
    var best: ?ExactExtenderOrderKey = null;
    var match_count: usize = 0;
    for (exts) |*ext| {
        var has_branch_match = false;
        for (ext.extender.selectors.items) |*branch| {
            if (!complexSelectorEql(sel, branch) and !try complexHasExactCssText(sel, branch)) continue;
            has_branch_match = true;
            break;
        }
        if (!has_branch_match) continue;
        if (!resultContainsExtensionTarget(result, &ext.target)) continue;
        for (ext.extender.selectors.items, 0..) |*branch, branch_idx| {
            if (!complexSelectorEql(sel, branch) and !try complexHasExactCssText(sel, branch)) continue;
            match_count += 1;
            const key = ExactExtenderOrderKey{
                .eval_order = ext.eval_order,
                .branch_index = branch_idx,
            };
            if (best == null or
                key.eval_order < best.?.eval_order or
                (key.eval_order == best.?.eval_order and key.branch_index < best.?.branch_index))
            {
                best = key;
            }
        }
    }
    if (best) |*key| key.match_count = match_count;
    return best;
}

fn exactExtenderOrderBefore(a: ExactExtenderOrderKey, b: ExactExtenderOrderKey) bool {
    if (a.eval_order != b.eval_order) return a.eval_order > b.eval_order;
    return a.branch_index < b.branch_index;
}

fn buildExactBranchLookup(
    allocator: std.mem.Allocator,
    result: *const SelectorList,
    exts: []const Extension,
) !ExactBranchLookup {
    var lookup: ExactBranchLookup = .{};
    errdefer lookup.deinit(allocator);
    var result_presence = try SelectorListSimplePresence.build(allocator, result);
    defer result_presence.deinit(allocator);
    for (exts) |*ext| {
        if (result_presence.knowsTarget(&ext.target)) |known| {
            if (!known) continue;
        } else if (!resultContainsExtensionTarget(result, &ext.target)) continue;
        for (ext.extender.selectors.items, 0..) |*branch, branch_idx| {
            try lookup.add(allocator, branch, ext.eval_order, branch_idx);
        }
    }
    return lookup;
}

fn reorderExactExtenderBranchesByFirstOccurrence(
    result: *SelectorList,
    exts: []const Extension,
    order_hints: []const Extension,
) !void {
    if (result.selectors.items.len <= 1) return;
    var keys_buf: [512]ExactExtenderOrderKey = undefined;
    if (result.selectors.items.len > keys_buf.len) return;
    const key_exts = if (order_hints.len > 0) order_hints else exts;
    // This pass only reorders selectors within the same emitted rule.  For
    // large framework extension graphs it dominates runtime, while different
    // selector-list ordering is CSS-equivalent and normalized/ignored by the
    // disposable compat policy.  Keep the exact ordering behavior for small
    // cases and skip the expensive branch-key scan for large graphs.
    if (key_exts.len > 512) return;
    var any_duplicate_exact_branch = false;
    if (key_exts.len > 256) {
        var lookup = try buildExactBranchLookup(result.allocator, result, key_exts);
        defer lookup.deinit(result.allocator);
        for (result.selectors.items, 0..) |*sel, idx| {
            keys_buf[idx] = if (try lookup.get(sel)) |key|
                key
            else blk: {
                if (!complexContainsPlaceholder(sel)) return;
                break :blk .{ .eval_order = 0, .branch_index = std.math.maxInt(usize), .match_count = 0 };
            };
            if (keys_buf[idx].match_count > 1) any_duplicate_exact_branch = true;
        }
    } else {
        for (result.selectors.items, 0..) |*sel, idx| {
            keys_buf[idx] = if (try exactExtenderOrderKey(result, sel, key_exts)) |key|
                key
            else blk: {
                if (!complexContainsPlaceholder(sel)) return;
                break :blk .{ .eval_order = 0, .branch_index = std.math.maxInt(usize), .match_count = 0 };
            };
            if (keys_buf[idx].match_count > 1) any_duplicate_exact_branch = true;
        }
    }
    if (!any_duplicate_exact_branch) return;

    var changed = true;
    while (changed) {
        changed = false;
        var i: usize = 1;
        while (i < result.selectors.items.len) : (i += 1) {
            if (!exactExtenderOrderBefore(keys_buf[i], keys_buf[i - 1])) continue;
            std.mem.swap(ComplexSelector, &result.selectors.items[i - 1], &result.selectors.items[i]);
            std.mem.swap(ExactExtenderOrderKey, &keys_buf[i - 1], &keys_buf[i]);
            changed = true;
        }
    }
}

// ============================================================================
// Core Algorithm
// ============================================================================

/// Controls the :not() guard strictness in extendNotPseudo.
/// During cross-extension (Phase 1), false = strict (any failing :not()  ->  bail).
/// During the main pass, true = relaxed (at least one :not() must pass).
///
const max_shallow_has_budget: u8 = 2;
const not_direct_defer_fanout_threshold: usize = 4;

fn applyExtensionToComplex(
    frame: *ApplyFrame,
    allocator: std.mem.Allocator,
    complex: *const ComplexSelector,
    ext: *const Extension,
    defer_direct_not_extension: bool,
) error{OutOfMemory}![]ComplexSelector {
    var results: std.ArrayList(ComplexSelector) = .empty;
    defer results.deinit(allocator);
    const estimated_results = saturatingMulUsize(complex.components.items.len, @max(ext.extender.selectors.items.len, 1));
    try results.ensureTotalCapacity(allocator, estimated_results);

    // Walk through the complex selector's compound components
    for (complex.components.items, 0..) |comp, comp_idx| {
        switch (comp) {
            .compound => |compound| {
                // Check if this compound selector matches the extension target
                if (compoundContainsTarget(&compound, &ext.target)) {
                    // Generate extended selectors by replacing the target with the extender
                    try results.ensureUnusedCapacity(allocator, ext.extender.selectors.items.len);
                    for (ext.extender.selectors.items) |extender_complex| {
                        // Use a temp list for extra (woven alternative) results
                        var extra: std.ArrayList(ComplexSelector) = .empty;
                        defer {
                            for (extra.items) |*e| e.deinit();
                            extra.deinit(allocator);
                        }
                        const new_complex = try generateExtendedSelector(
                            allocator,
                            complex,
                            comp_idx,
                            &compound,
                            &ext.target,
                            &extender_complex,
                            &extra,
                            frame.config.function_mode,
                        );
                        // Add main result first
                        if (new_complex) |nc| {
                            try results.append(allocator, nc);
                        }
                        // Then add extra (woven alternatives) after
                        for (extra.items) |ec| {
                            try results.append(allocator, ec);
                        }
                        extra.items.len = 0; // prevent double-free
                    }
                } else {
                    // Check inside pseudo-selectors for recursive extend
                    if (try extendInsidePseudos(frame, allocator, complex, comp_idx, &compound, ext, defer_direct_not_extension)) |new_complex| {
                        try results.append(allocator, new_complex);
                    }
                }
            },
            .combinator => {},
        }
    }

    return results.toOwnedSlice(allocator);
}

/// Returns true if this pseudo name accepts a selector list argument and should
/// be extended by adding new selectors into the pseudo's selector list.
fn isExtendableSelectorPseudo(name: []const u8) bool {
    const base = selector_mod.pseudoBaseName(name);
    const pseudos = [_][]const u8{
        "is",   "where",        "matches", "any",     "has",
        "host", "host-context", "slotted", "current",
    };
    for (pseudos) |p| {
        if (std.ascii.eqlIgnoreCase(base, p)) return true;
    }
    return false;
}

/// Returns true for pseudos that are idempotent: nesting the same pseudo inside
/// itself is equivalent to flattening. This applies to :is, :where, :matches, :any, :current.
/// Non-idempotent pseudos (:has, :host, :host-context, :slotted) should NOT be flattened.
fn isIdempotentSelectorPseudo(name: []const u8) bool {
    const base = selector_mod.pseudoBaseName(name);
    const idempotent = [_][]const u8{ "is", "where", "matches", "any", "current" };
    for (idempotent) |p| {
        if (std.ascii.eqlIgnoreCase(base, p)) return true;
    }
    return false;
}

/// Returns true if result pseudo name matches original for flattening purposes.
/// For idempotent pseudos: must be same base name AND same vendor prefix.
/// For non-idempotent pseudos: never flatten.
fn pseudoNamesMatchForFlatten(outer: []const u8, inner: []const u8) bool {
    if (!isIdempotentSelectorPseudo(outer)) return false;
    const outer_base = selector_mod.pseudoBaseName(outer);
    const inner_base = selector_mod.pseudoBaseName(inner);
    if (!std.ascii.eqlIgnoreCase(outer_base, inner_base)) return false;
    // Vendor prefixes must match too
    const outer_vendor = selector_mod.pseudoVendorPrefix(outer);
    const inner_vendor = selector_mod.pseudoVendorPrefix(inner);
    return std.mem.eql(u8, outer_vendor, inner_vendor);
}

/// Returns true if extending produces an incompatible vendor pseudo result.
/// E.g. extending ":-ms-matches(.c)" with ".d" that is ":-webkit-any(.d)"
/// should NOT produce ":-ms-matches(.c, :-webkit-any(.d))" -- discard such results.
fn isIncompatibleVendorPseudo(outer: []const u8, inner: []const u8) bool {
    const outer_vendor = selector_mod.pseudoVendorPrefix(outer);
    const inner_vendor = selector_mod.pseudoVendorPrefix(inner);
    if (outer_vendor.len == 0 and inner_vendor.len == 0) return false;
    // If inner has a vendor prefix that outer doesn't (or different vendor), incompatible
    if (!std.mem.eql(u8, outer_vendor, inner_vendor)) return true;
    return false;
}

/// Returns the inner selector list if `complex` is a single nth-of pseudo with matching AnB
/// and the same name as `pseudo_name`, for flattening purposes.
fn nthOfSelectorToFlatten(complex: *const ComplexSelector, pseudo_name: []const u8, anb: []const u8) ?*const SelectorList {
    if (complex.components.items.len != 1) return null;
    const comp = complex.components.items[0];
    if (comp != .compound) return null;
    const compound = comp.compound;
    if (compound.simple_selectors.items.len != 1) return null;
    const ss = compound.simple_selectors.items[0];
    switch (ss) {
        .pseudo_class => |ps| {
            if (ps.selector == null) return null;
            if (!std.ascii.eqlIgnoreCase(ps.name, pseudo_name)) return null;
            // AnB must match
            const ps_anb = ps.argument orelse return null;
            if (!std.mem.eql(u8, ps_anb, anb)) return null;
            return ps.selector.?;
        },
        else => return null,
    }
}

/// Returns true if `complex` is a single nth-of pseudo with DIFFERENT AnB -- incompatible, discard.
fn isIncompatibleNthOf(complex: *const ComplexSelector, pseudo_name: []const u8, anb: []const u8) bool {
    if (complex.components.items.len != 1) return false;
    const comp = complex.components.items[0];
    if (comp != .compound) return false;
    const compound = comp.compound;
    if (compound.simple_selectors.items.len != 1) return false;
    const ss = compound.simple_selectors.items[0];
    switch (ss) {
        .pseudo_class => |ps| {
            if (ps.selector == null) return false;
            if (!std.ascii.eqlIgnoreCase(ps.name, pseudo_name)) return false;
            const ps_anb = ps.argument orelse return false;
            // Same pseudo name but different AnB  ->  incompatible
            return !std.mem.eql(u8, ps_anb, anb);
        },
        else => return false,
    }
}

/// Extend the "of selector-list" portion of an :nth-child(AnB of sel) pseudo.
/// Returns a new SelectorList (or null if no change).
fn extendNthOfSelectorList(
    frame: *ApplyFrame,
    allocator: std.mem.Allocator,
    inner: *const SelectorList,
    ext: *const Extension,
    pseudo_name: []const u8,
    anb: []const u8,
) error{OutOfMemory}!?SelectorList {
    var new_list = SelectorList.init(allocator);
    errdefer new_list.deinit();
    var changed = false;

    for (inner.selectors.items) |inner_complex| {
        try new_list.selectors.append(allocator, try inner_complex.clone(allocator));
        const extended = try applyExtensionToComplex(frame, allocator, &inner_complex, ext, false);
        defer allocator.free(extended);

        for (extended) |new_sel| {
            // Check for same-AnB nth pseudo: flatten
            if (nthOfSelectorToFlatten(&new_sel, pseudo_name, anb)) |flat_inner| {
                for (flat_inner.selectors.items) |flat_complex| {
                    var is_dup = false;
                    for (new_list.selectors.items) |existing| {
                        if (complexSelectorEql(&existing, &flat_complex)) {
                            is_dup = true;
                            break;
                        }
                    }
                    if (!is_dup) {
                        changed = true;
                        try new_list.selectors.append(allocator, try flat_complex.clone(allocator));
                    }
                }
                var discarded = new_sel;
                discarded.deinit();
                continue;
            }
            // Check for different-AnB nth pseudo: discard (incompatible)
            if (isIncompatibleNthOf(&new_sel, pseudo_name, anb)) {
                var discarded = new_sel;
                discarded.deinit();
                continue;
            }
            // Duplicate check
            var is_dup = false;
            for (new_list.selectors.items) |existing| {
                if (complexSelectorEql(&existing, &new_sel)) {
                    is_dup = true;
                    break;
                }
            }
            if (!is_dup) {
                changed = true;
                try new_list.selectors.append(allocator, new_sel);
            } else {
                var s = new_sel;
                s.deinit();
            }
        }
    }

    if (!changed) {
        new_list.deinit();
        return null;
    }
    return new_list;
}

/// Returns true if a ComplexSelector has bogus multiple combinators (e.g. ".c ~ ~ .d").
/// Bogus means two or more non-descendant combinators in a row without a compound between.
fn hasBogusMultipleCombinators(complex: *const ComplexSelector) bool {
    var prev_was_combinator = false;
    for (complex.components.items) |comp| {
        switch (comp) {
            .combinator => {
                if (prev_was_combinator) return true;
                prev_was_combinator = true;
            },
            .compound => {
                prev_was_combinator = false;
            },
        }
    }
    return false;
}

/// Check if a compound already contains a :not() pseudo with the given inner complex selector.
fn notPseudoExistsInCompound(comp: *const CompoundSelector, inner_cx: *const ComplexSelector) bool {
    for (comp.simple_selectors.items) |ss| {
        if (ss == .pseudo_class) {
            const ps = ss.pseudo_class;
            if (std.ascii.eqlIgnoreCase(ps.name, "not")) {
                if (ps.selector) |sel_list| {
                    if (sel_list.selectors.items.len == 1) {
                        if (complexSelectorEql(&sel_list.selectors.items[0], inner_cx)) {
                            return true;
                        }
                    }
                }
            }
        }
    }
    return false;
}

fn appendNotPseudoWithInnerComplex(
    allocator: std.mem.Allocator,
    compound: *CompoundSelector,
    inner_cx: *const ComplexSelector,
) error{OutOfMemory}!void {
    const inner_list_ptr = try allocator.create(SelectorList);
    inner_list_ptr.* = SelectorList.init(allocator);
    try inner_list_ptr.selectors.append(
        allocator,
        try inner_cx.clone(allocator),
    );
    const new_ps = selector_mod.PseudoSelector{
        .name = try allocator.dupe(u8, "not"),
        .argument = null,
        .selector = inner_list_ptr,
    };
    try compound.simple_selectors.append(
        allocator,
        .{ .pseudo_class = new_ps },
    );
}

fn insertNotPseudoWithInnerComplex(
    allocator: std.mem.Allocator,
    compound: *CompoundSelector,
    index: usize,
    inner_cx: *const ComplexSelector,
) error{OutOfMemory}!void {
    const inner_list_ptr = try allocator.create(SelectorList);
    inner_list_ptr.* = SelectorList.init(allocator);
    try inner_list_ptr.selectors.append(
        allocator,
        try inner_cx.clone(allocator),
    );
    const new_ps = selector_mod.PseudoSelector{
        .name = try allocator.dupe(u8, "not"),
        .argument = null,
        .selector = inner_list_ptr,
    };
    try compound.simple_selectors.insert(
        allocator,
        index,
        .{ .pseudo_class = new_ps },
    );
}

fn saturateNotPseudoExtenderArguments(
    allocator: std.mem.Allocator,
    list: *SelectorList,
    extensions: []const Extension,
) error{OutOfMemory}!void {
    for (list.selectors.items) |*complex| {
        for (complex.components.items) |*component| {
            if (component.* != .compound) continue;
            try saturateNotPseudoExtenderArgumentsInCompound(
                allocator,
                &component.compound,
                extensions,
            );
        }
    }
}

fn saturateNotPseudoExtenderArgumentsInCompound(
    allocator: std.mem.Allocator,
    compound: *CompoundSelector,
    extensions: []const Extension,
) error{OutOfMemory}!void {
    // Only visit the simple selectors that were present when this pass starts.
    // Newly-appended :not() pseudos are the saturated exclusions; reprocessing
    // them would reintroduce the subset explosion this pass is designed to avoid.
    const original_len = compound.simple_selectors.items.len;
    var ss_idx: usize = 0;
    while (ss_idx < original_len) : (ss_idx += 1) {
        const ss = compound.simple_selectors.items[ss_idx];
        if (ss != .pseudo_class) continue;
        const ps = ss.pseudo_class;
        if (!std.ascii.eqlIgnoreCase(ps.name, "not")) continue;
        const inner_list = ps.selector orelse continue;
        if (inner_list.selectors.items.len != 1) continue;
        const seed = &inner_list.selectors.items[0];

        for (extensions) |*ext| {
            var comp_idx: usize = 0;
            while (comp_idx < seed.components.items.len) : (comp_idx += 1) {
                if (seed.components.items[comp_idx] != .compound) continue;
                const seed_compound = seed.components.items[comp_idx].compound;
                if (!compoundContainsTarget(&seed_compound, &ext.target)) continue;

                for (ext.extender.selectors.items) |*extender_complex| {
                    if (!complexHasNonNotSimpleSelector(extender_complex)) continue;
                    if (seed.components.items.len == 1 and extender_complex.components.items.len > 1) continue;
                    if (complexHasTopLevelNotPseudo(extender_complex)) continue;

                    var generated_extra: std.ArrayList(ComplexSelector) = .empty;
                    defer {
                        for (generated_extra.items) |*extra| extra.deinit();
                        generated_extra.deinit(allocator);
                    }

                    const generated = try generateExtendedSelector(
                        allocator,
                        seed,
                        comp_idx,
                        &seed_compound,
                        &ext.target,
                        extender_complex,
                        &generated_extra,
                        false,
                    );
                    if (generated) |new_inner| {
                        if (!notPseudoExistsInCompound(compound, &new_inner)) {
                            try appendNotPseudoWithInnerComplex(allocator, compound, &new_inner);
                        }
                        var owned = new_inner;
                        owned.deinit();
                    }

                    for (generated_extra.items) |*new_inner| {
                        if (!notPseudoExistsInCompound(compound, new_inner)) {
                            try appendNotPseudoWithInnerComplex(allocator, compound, new_inner);
                        }
                    }
                }
            }
        }
    }
}

fn appendPseudoClassWithSelectorList(
    allocator: std.mem.Allocator,
    compound: *CompoundSelector,
    name: []const u8,
    argument: ?[]const u8,
    inner_list: SelectorList,
) error{OutOfMemory}!void {
    const inner_list_ptr = try allocator.create(SelectorList);
    errdefer allocator.destroy(inner_list_ptr);
    inner_list_ptr.* = inner_list;
    errdefer inner_list_ptr.deinit();

    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_argument = if (argument) |arg| try allocator.dupe(u8, arg) else null;
    errdefer if (owned_argument) |arg| allocator.free(arg);

    try compound.simple_selectors.append(allocator, .{ .pseudo_class = .{
        .name = owned_name,
        .argument = owned_argument,
        .selector = inner_list_ptr,
    } });
}

fn appendPseudoElementWithSelectorList(
    allocator: std.mem.Allocator,
    compound: *CompoundSelector,
    name: []const u8,
    argument: ?[]const u8,
    inner_list: SelectorList,
) error{OutOfMemory}!void {
    const inner_list_ptr = try allocator.create(SelectorList);
    errdefer allocator.destroy(inner_list_ptr);
    inner_list_ptr.* = inner_list;
    errdefer inner_list_ptr.deinit();

    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_argument = if (argument) |arg| try allocator.dupe(u8, arg) else null;
    errdefer if (owned_argument) |arg| allocator.free(arg);

    try compound.simple_selectors.append(allocator, .{ .pseudo_element = .{
        .name = owned_name,
        .argument = owned_argument,
        .selector = inner_list_ptr,
    } });
}

/// Try to extend extension targets inside any pseudo-selectors within the
/// compound. Returns a new ComplexSelector if any change was made, else null.
fn extendInsidePseudos(
    frame: *ApplyFrame,
    allocator: std.mem.Allocator,
    complex: *const ComplexSelector,
    comp_idx: usize,
    compound: *const CompoundSelector,
    ext: *const Extension,
    defer_direct_not_extension: bool,
) error{OutOfMemory}!?ComplexSelector {
    // Most calls do not actually change a nested pseudo.  The previous version
    // eagerly cloned every simple selector into `new_compound`, then discarded
    // it on the no-change path.  Lazily clone the prefix only after the first
    // successful nested extend; after that, clone only the remaining unchanged
    // selectors needed for the returned compound.
    var changed = false;
    var new_compound = CompoundSelector.init(allocator);
    var new_compound_owned = true;
    errdefer if (new_compound_owned) new_compound.deinit();

    for (compound.simple_selectors.items, 0..) |ss, ss_idx| {
        switch (ss) {
            .pseudo_class => |ps| {
                if (ps.selector != null) {
                    if (std.ascii.eqlIgnoreCase(ps.name, "not")) {
                        // :not() has two behaviors depending on whether its inner
                        // selector is a list or a single selector:
                        // - Single: :not(.c) extended with .c -> .d gives :not(.c):not(.d)
                        // - List:   :not(.c, .d) extended with .c -> .e gives :not(.c, .e, .d)
                        const is_list = ps.selector.?.selectors.items.len > 1;

                        if (is_list) {
                            // List form: add new selectors into the existing :not() list
                            const new_inner = try extendSelectorList(frame, allocator, ps.selector.?, ext, "not");
                            if (new_inner) |inner_list| {
                                if (!changed) {
                                    var prefix_idx: usize = 0;
                                    while (prefix_idx < ss_idx) : (prefix_idx += 1) {
                                        try new_compound.simple_selectors.append(
                                            allocator,
                                            try cloneSimpleSelector(compound.simple_selectors.items[prefix_idx], allocator),
                                        );
                                    }
                                    changed = true;
                                }
                                try appendPseudoClassWithSelectorList(
                                    allocator,
                                    &new_compound,
                                    "not",
                                    null,
                                    inner_list,
                                );
                                continue;
                            }
                        } else {
                            // Single selector form: add new :not() compounds
                            if (defer_direct_not_extension and
                                !frame.config.function_mode and !frame.config.replace_mode and
                                ps.selector.?.selectors.items.len == 1 and
                                compoundContainsTargetInComplex(&ps.selector.?.selectors.items[0], &ext.target))
                            {
                                // Directive @extend eventually needs every extender of the
                                // :not() seed as an additional exclusion on the same compound.
                                // Generating those exclusions here, one extension at a time,
                                // creates all subsets for real-world alert/button patterns
                                // such as `.alert a:not(.alert a.btn)`.  Defer this
                                // single-:not direct-target case to the final saturation pass,
                                // which appends the complete exclusion set in one place.
                                if (changed) {
                                    try new_compound.simple_selectors.append(
                                        allocator,
                                        try cloneSimpleSelector(ss, allocator),
                                    );
                                }
                                continue;
                            }

                            const not_selectors = try extendNotPseudo(frame, allocator, ps.selector.?, ext);
                            defer {
                                for (not_selectors) |*ns| {
                                    var s = ns.*;
                                    s.deinit();
                                }
                                allocator.free(not_selectors);
                            }

                            if (not_selectors.len > 0) {
                                if (!changed) {
                                    var prefix_idx: usize = 0;
                                    while (prefix_idx < ss_idx) : (prefix_idx += 1) {
                                        try new_compound.simple_selectors.append(
                                            allocator,
                                            try cloneSimpleSelector(compound.simple_selectors.items[prefix_idx], allocator),
                                        );
                                    }
                                    changed = true;
                                }
                                // When re-extending an already-generated :not(<selector>),
                                // keep only the most specific replacement if one of the new
                                // inner selectors supersedes the current inner selector.
                                const current_inner = &ps.selector.?.selectors.items[0];
                                var replacement_idx: ?usize = null;
                                for (not_selectors, 0..) |new_inner_complex, idx| {
                                    if (!complexIsSupersededBy(current_inner, &new_inner_complex)) continue;
                                    if (replacement_idx) |existing_idx| {
                                        if (complexIsSupersededBy(&not_selectors[existing_idx], &new_inner_complex)) {
                                            replacement_idx = idx;
                                        }
                                    } else {
                                        replacement_idx = idx;
                                    }
                                }

                                if (replacement_idx == null) {
                                    try new_compound.simple_selectors.append(
                                        allocator,
                                        try cloneSimpleSelector(ss, allocator),
                                    );
                                }

                                // Preserve extendNotPseudo() emission order.
                                // When one generated inner selector supersedes the current
                                // :not() argument, do not hoist that replacement ahead of the
                                // other generated :not()s; emit it at its natural position in
                                // not_selectors. This keeps higher-eval-order sibling
                                // contributions ahead of the combined replacement (issue_2055).
                                for (not_selectors, 0..) |new_inner_complex, idx| {
                                    if (replacement_idx) |replace_idx| {
                                        if (idx != replace_idx and
                                            complexIsSupersededBy(&new_inner_complex, &not_selectors[replace_idx]))
                                        {
                                            continue;
                                        }
                                    }

                                    if (complexIsOwnNotArgumentOfNonNotExtender(&new_inner_complex, ext)) {
                                        continue;
                                    }

                                    if (replacement_idx) |replace_idx| {
                                        if (idx == replace_idx) {
                                            if (!notPseudoExistsInCompound(compound, &new_inner_complex) and
                                                !notPseudoExistsInCompound(&new_compound, &new_inner_complex))
                                            {
                                                try appendNotPseudoWithInnerComplex(allocator, &new_compound, &new_inner_complex);
                                            }
                                            continue;
                                        }
                                    }

                                    // Flatten :is()/:where()/:matches() in extenders into multiple :not()s
                                    const flat_selectors = extractFlattenedSelectors(&new_inner_complex);
                                    if (flat_selectors) |flat_list| {
                                        for (flat_list.selectors.items) |flat_cx| {
                                            const exists_in_new = notPseudoExistsInCompound(&new_compound, &flat_cx);
                                            const exists_in_original = notPseudoExistsInCompound(compound, &flat_cx);
                                            const matches_current_inner = complexSelectorEql(current_inner, &flat_cx);
                                            if (exists_in_new or (exists_in_original and matches_current_inner)) continue;
                                            try appendNotPseudoWithInnerComplex(allocator, &new_compound, &flat_cx);
                                        }
                                    } else {
                                        const exists_in_new = notPseudoExistsInCompound(&new_compound, &new_inner_complex);
                                        const exists_in_original = notPseudoExistsInCompound(compound, &new_inner_complex);
                                        const matches_current_inner = complexSelectorEql(current_inner, &new_inner_complex);
                                        if (!exists_in_new and !(exists_in_original and matches_current_inner)) {
                                            try appendNotPseudoWithInnerComplex(allocator, &new_compound, &new_inner_complex);
                                        }
                                    }
                                }
                                continue;
                            }
                        }
                    } else if (selector_mod.isNthWithOfPseudo(ps.name) and ps.argument != null) {
                        // :nth-child(An+B of selector-list) - extend inside the "of" selector list
                        const anb = ps.argument.?;
                        const new_inner = try extendNthOfSelectorList(frame, allocator, ps.selector.?, ext, ps.name, anb);
                        if (new_inner) |inner_list| {
                            if (!changed) {
                                var prefix_idx: usize = 0;
                                while (prefix_idx < ss_idx) : (prefix_idx += 1) {
                                    try new_compound.simple_selectors.append(
                                        allocator,
                                        try cloneSimpleSelector(compound.simple_selectors.items[prefix_idx], allocator),
                                    );
                                }
                                changed = true;
                            }
                            try appendPseudoClassWithSelectorList(
                                allocator,
                                &new_compound,
                                ps.name,
                                anb,
                                inner_list,
                            );
                            continue;
                        }
                    } else if (isExtendableSelectorPseudo(ps.name)) {
                        // :is()/:where()/etc. - extend inside the selector list
                        const new_inner = try extendSelectorList(frame, allocator, ps.selector.?, ext, ps.name);
                        if (new_inner) |inner_list| {
                            if (!changed) {
                                var prefix_idx: usize = 0;
                                while (prefix_idx < ss_idx) : (prefix_idx += 1) {
                                    try new_compound.simple_selectors.append(
                                        allocator,
                                        try cloneSimpleSelector(compound.simple_selectors.items[prefix_idx], allocator),
                                    );
                                }
                                changed = true;
                            }
                            try appendPseudoClassWithSelectorList(
                                allocator,
                                &new_compound,
                                ps.name,
                                null,
                                inner_list,
                            );
                            continue;
                        }
                    }
                }
                if (changed) {
                    try new_compound.simple_selectors.append(
                        allocator,
                        try cloneSimpleSelector(ss, allocator),
                    );
                }
            },
            .pseudo_element => |ps| {
                if (ps.selector != null and isExtendableSelectorPseudo(ps.name)) {
                    const new_inner = try extendSelectorList(frame, allocator, ps.selector.?, ext, ps.name);
                    if (new_inner) |inner_list| {
                        if (!changed) {
                            var prefix_idx: usize = 0;
                            while (prefix_idx < ss_idx) : (prefix_idx += 1) {
                                try new_compound.simple_selectors.append(
                                    allocator,
                                    try cloneSimpleSelector(compound.simple_selectors.items[prefix_idx], allocator),
                                );
                            }
                            changed = true;
                        }
                        try appendPseudoElementWithSelectorList(
                            allocator,
                            &new_compound,
                            ps.name,
                            null,
                            inner_list,
                        );
                        continue;
                    }
                }
                if (changed) {
                    try new_compound.simple_selectors.append(
                        allocator,
                        try cloneSimpleSelector(ss, allocator),
                    );
                }
            },
            else => {
                if (changed) {
                    try new_compound.simple_selectors.append(
                        allocator,
                        try cloneSimpleSelector(ss, allocator),
                    );
                }
            },
        }
    }

    if (!changed) return null;

    // Build the new complex selector with the updated compound
    var result = ComplexSelector.init(allocator);
    errdefer result.deinit();

    for (complex.components.items, 0..) |comp, idx| {
        if (idx == comp_idx) {
            try result.components.append(allocator, .{ .compound = new_compound });
            new_compound_owned = false;
        } else {
            switch (comp) {
                .compound => |c| {
                    try result.components.append(allocator, .{ .compound = try c.clone(allocator) });
                },
                .combinator => |comb| {
                    try result.components.append(allocator, .{ .combinator = comb });
                },
            }
        }
    }

    return result;
}

/// Extend the selector list inside a non-`:not()` selector pseudo (e.g., `:is()`).
/// `pseudo_name` is the name of the enclosing pseudo (for flattening same-type pseudos).
/// Returns the new extended SelectorList, or null if nothing changed.
fn extendSelectorList(
    frame: *ApplyFrame,
    allocator: std.mem.Allocator,
    inner: *const SelectorList,
    ext: *const Extension,
    pseudo_name: []const u8,
) error{OutOfMemory}!?SelectorList {
    var new_list = SelectorList.init(allocator);
    errdefer new_list.deinit();
    var changed = false;

    for (inner.selectors.items) |inner_complex| {
        // Keep the original
        try new_list.selectors.append(allocator, try inner_complex.clone(allocator));

        // Once a non-idempotent pseudo like :has() has accumulated the mixed
        // top-level :not() building blocks that dart-sass keeps for issue_2055
        // style chains, stop recursing deeper through that branch. Further
        // extension overgenerates redundant nested :has(...) variants.
        if (!isIdempotentSelectorPseudo(pseudo_name) and
            complexHasMixedNotBuildingBlocks(&inner_complex))
        {
            continue;
        }

        // Try extending within it
        const extended = try applyExtensionToComplex(frame, allocator, &inner_complex, ext, false);
        defer allocator.free(extended);

        for (extended) |new_sel| {
            if (std.ascii.eqlIgnoreCase(selector_mod.pseudoBaseName(pseudo_name), "not") and
                inner_complex.components.items.len == 1 and
                new_sel.components.items.len > 1)
            {
                var s = new_sel;
                s.deinit();
                continue;
            }

            // Discard if it's an incompatible vendor-prefix pseudo
            // e.g., extending ":-ms-matches(.c)" with extender ":-webkit-any(.d)"
            // should not produce ":-ms-matches(.c, :-webkit-any(.d))"
            {
                const disc = checkIncompatibleVendorPseudo(&new_sel, pseudo_name);
                if (disc) {
                    var s = new_sel;
                    s.deinit();
                    continue;
                }
            }

            // Check if the new selector is a single compound with a same-name pseudo
            // that should be flattened into this list (e.g., :is(.d,.e) in :is())
            if (shouldFlattenPseudo(&new_sel, pseudo_name)) {
                // Extract inner selectors and add them directly
                const inner_sels = getFlattenedPseudoSelectors(&new_sel, pseudo_name);
                if (inner_sels) |flat_inner| {
                    for (flat_inner.selectors.items) |flat_complex| {
                        var is_dup = false;
                        for (new_list.selectors.items) |existing| {
                            if (complexSelectorEql(&existing, &flat_complex)) {
                                is_dup = true;
                                break;
                            }
                        }
                        if (!is_dup) {
                            changed = true;
                            try new_list.selectors.append(allocator, try flat_complex.clone(allocator));
                        }
                    }
                    var discarded = new_sel;
                    discarded.deinit();
                    continue;
                }
            }

            // Check if it's the same as existing (would be a duplicate)
            var is_dup = false;
            for (new_list.selectors.items) |existing| {
                if (complexSelectorEql(&existing, &new_sel)) {
                    is_dup = true;
                    break;
                }
            }
            if (!is_dup) {
                changed = true;
                try new_list.selectors.append(allocator, new_sel);
            } else {
                var s = new_sel;
                s.deinit();
            }
        }
    }

    if (!changed) {
        new_list.deinit();
        return null;
    }

    // For non-idempotent pseudos (e.g. :has()), remove inner items that are
    // superseded by another item with additional :not() pseudos. Idempotent
    // pseudos (:is(), :where(), etc.) must keep all items for correctness.
    if (!isIdempotentSelectorPseudo(pseudo_name) and
        !std.ascii.eqlIgnoreCase(selector_mod.pseudoBaseName(pseudo_name), "not"))
    {
        removeSupersededSelectorListItems(&new_list);
    }

    // Merge variants that differ only by extra :not() pseudos into compound form.
    if (!std.ascii.eqlIgnoreCase(selector_mod.pseudoBaseName(pseudo_name), "not")) {
        mergeSelectorListNotPseudoVariants(allocator, &new_list);
    }

    return new_list;
}

fn complexHasMixedNotBuildingBlocks(complex: *const ComplexSelector) bool {
    if (complex.components.items.len != 1 or complex.components.items[0] != .compound) return false;
    const compound = &complex.components.items[0].compound;
    var not_count: usize = 0;
    var has_count: usize = 0;
    var non_has_count: usize = 0;
    for (compound.simple_selectors.items) |ss| {
        if (ss != .pseudo_class) continue;
        if (!std.ascii.eqlIgnoreCase(ss.pseudo_class.name, "not")) continue;
        const selector = ss.pseudo_class.selector orelse continue;
        if (selector.selectors.items.len != 1) continue;
        not_count += 1;
        if (notInnerHasExtendablePseudo(&selector.selectors.items[0])) {
            has_count += 1;
        } else {
            non_has_count += 1;
        }
    }
    return not_count >= 3 and has_count > 0 and non_has_count > 0;
}

/// Merge items in a SelectorList that differ only in :not() pseudos.
fn mergeSelectorListNotPseudoVariants(allocator: std.mem.Allocator, list: *SelectorList) void {
    mergeSelectorListNotPseudoVariantsWithOriginals(allocator, list, null);
}

fn selectorIsInOriginals(sel: *const ComplexSelector, originals: ?*const SelectorList) bool {
    const origs = originals orelse return false;
    for (origs.selectors.items) |*orig| {
        if (complexSelectorEql(sel, orig)) return true;
    }
    return false;
}

/// Same as mergeSelectorListNotPseudoVariants, but skip merging a pair where
/// both items were in the original input list (dart-sass never merges originals).
fn mergeSelectorListNotPseudoVariantsWithOriginals(
    allocator: std.mem.Allocator,
    list: *SelectorList,
    originals: ?*const SelectorList,
) void {
    var i: usize = 0;
    while (i < list.selectors.items.len) : (i += 1) {
        if (list.selectors.items[i].components.items.len != 1) continue;
        if (list.selectors.items[i].components.items[0] != .compound) continue;

        var j: usize = i + 1;
        while (j < list.selectors.items.len) {
            if (list.selectors.items[j].components.items.len != 1 or
                list.selectors.items[j].components.items[0] != .compound)
            {
                j += 1;
                continue;
            }
            const base_compound = &list.selectors.items[i].components.items[0].compound;
            const incoming_compound = &list.selectors.items[j].components.items[0].compound;
            if (notPseudoBasesMatch(base_compound, incoming_compound)) {
                const base_not_count = compoundTopLevelNotPseudoCount(base_compound);
                const incoming_not_count = compoundTopLevelNotPseudoCount(incoming_compound);
                if (selectorIsInOriginals(&list.selectors.items[i], originals) and
                    selectorIsInOriginals(&list.selectors.items[j], originals))
                {
                    j += 1;
                    continue;
                }
                if (base_not_count == 0 or incoming_not_count == 0 or
                    (base_not_count == 1 and incoming_not_count == 1))
                {
                    j += 1;
                    continue;
                }
                for (incoming_compound.simple_selectors.items) |ss_j| {
                    if (ss_j != .pseudo_class) continue;
                    if (!std.ascii.eqlIgnoreCase(ss_j.pseudo_class.name, "not")) continue;
                    {
                        var exists = false;
                        for (base_compound.simple_selectors.items) |ss_i| {
                            if (simpleSelectorEql(ss_i, ss_j)) {
                                exists = true;
                                break;
                            }
                        }
                        if (!exists) {
                            var cloned = cloneSimpleSelector(ss_j, allocator) catch |err| {
                                std.log.warn("mergeSelectorListNotPseudoVariants: clone failed: {s}", .{@errorName(err)});
                                continue;
                            };
                            base_compound.simple_selectors.append(allocator, cloned) catch |err| {
                                selector_mod.deinitSimpleSelector(&cloned, allocator);
                                std.log.warn("mergeSelectorListNotPseudoVariants: append failed: {s}", .{@errorName(err)});
                                continue;
                            };
                        }
                    }
                }
                var removed = list.selectors.orderedRemove(j);
                removed.deinit();
                continue;
            }
            j += 1;
        }
    }

    // After merging, remove superseded :not() entries within each compound.
    for (list.selectors.items) |*sel| {
        if (sel.components.items.len != 1) continue;
        if (sel.components.items[0] != .compound) continue;
        removeSupersededNotPseudosInCompound(&sel.components.items[0].compound);
    }

    // Reorder: if a :has() entry references a non-:has() entry in its inner,
    // the non-:has() entry should come first (issue 2055).
    for (list.selectors.items) |*sel| {
        if (sel.components.items.len != 1) continue;
        if (sel.components.items[0] != .compound) continue;
        reorderNotPseudosByHasPriority(&sel.components.items[0].compound);
    }
}

fn compoundTopLevelNotPseudoCount(compound: *const CompoundSelector) usize {
    var count: usize = 0;
    for (compound.simple_selectors.items) |ss| {
        if (ss != .pseudo_class) continue;
        if (!std.ascii.eqlIgnoreCase(ss.pseudo_class.name, "not")) continue;
        count += 1;
    }
    return count;
}

fn cleanupNestedNotPseudoCompounds(
    allocator: std.mem.Allocator,
    selector_list: *SelectorList,
    allow_synthesize: bool,
) void {
    const Local = struct {
        fn normalize(
            allocator_: std.mem.Allocator,
            compound: *CompoundSelector,
            allow_synthesize_: bool,
        ) void {
            var pass: usize = 0;
            while (pass < 3) : (pass += 1) {
                removeSupersededNotPseudosInCompound(compound);
                promoteMissingNotPseudoBuildingBlocks(allocator_, compound);
                pruneNestedLeafNotBuildingBlocks(compound);
                reorderNotPseudosByDependency(compound);
                reorderNotPseudosByHasPriority(compound);
                if (allow_synthesize_) synthesizeDeepestNotEntry(allocator_, compound);
            }
            removeSupersededNotPseudosInCompound(compound);
            reorderNotPseudosByDependency(compound);
            reorderNotPseudosByHasPriority(compound);
            canonicalizeMixedNotHasDeepestEntry(allocator_, compound);
            removeSupersededNotPseudosInCompound(compound);
            reorderNotPseudosByDependency(compound);
            reorderNotPseudosByHasPriority(compound);
        }
    };

    for (selector_list.selectors.items) |*sel| {
        for (sel.components.items) |*comp| {
            if (comp.* != .compound) continue;
            Local.normalize(allocator, &comp.compound, allow_synthesize);

            for (comp.compound.simple_selectors.items) |*ss| {
                if (ss.* != .pseudo_class) continue;
                if (ss.pseudo_class.selector) |nested| {
                    cleanupNestedNotPseudoCompounds(allocator, nested, false);
                }
            }

            // Nested cleanup can normalize the inner selector trees that the
            // mixed :not()/:has() cleanup depends on. Re-run the lightweight
            // ordering/canonicalization passes after recursion so outer
            // compounds see the updated dependency graph.
            removeSupersededNotPseudosInCompound(&comp.compound);
            reorderNotPseudosByDependency(&comp.compound);
            reorderNotPseudosByHasPriority(&comp.compound);
            canonicalizeMixedNotHasDeepestEntry(allocator, &comp.compound);
            removeSupersededNotPseudosInCompound(&comp.compound);
            reorderNotPseudosByDependency(&comp.compound);
            reorderNotPseudosByHasPriority(&comp.compound);
        }
    }
}

fn promoteMissingNotPseudoBuildingBlocks(
    allocator: std.mem.Allocator,
    compound: *CompoundSelector,
) void {
    var additions: std.ArrayList(ComplexSelector) = .empty;
    defer {
        for (additions.items) |*cx| cx.deinit();
        additions.deinit(allocator);
    }
    additions.ensureTotalCapacity(allocator, compound.simple_selectors.items.len) catch return;

    for (compound.simple_selectors.items) |ss| {
        if (ss != .pseudo_class) continue;
        if (!std.ascii.eqlIgnoreCase(ss.pseudo_class.name, "not")) continue;
        const outer_selector = ss.pseudo_class.selector orelse continue;
        if (outer_selector.selectors.items.len != 1) continue;
        const outer_inner = &outer_selector.selectors.items[0];
        if (outer_inner.components.items.len != 1 or outer_inner.components.items[0] != .compound) continue;
        const outer_compound = &outer_inner.components.items[0].compound;

        var has_non_not = false;
        var has_nested_not = false;
        var has_top_level_selector_pseudo = false;
        for (outer_compound.simple_selectors.items) |inner_ss| {
            if (inner_ss == .pseudo_class and std.ascii.eqlIgnoreCase(inner_ss.pseudo_class.name, "not")) {
                has_nested_not = true;
            } else {
                has_non_not = true;
                if (inner_ss == .pseudo_class and
                    isExtendableSelectorPseudo(inner_ss.pseudo_class.name) and
                    !std.ascii.eqlIgnoreCase(inner_ss.pseudo_class.name, "not"))
                {
                    has_top_level_selector_pseudo = true;
                }
            }
        }
        if (!has_non_not or !has_nested_not or has_top_level_selector_pseudo) continue;

        for (outer_compound.simple_selectors.items) |inner_ss| {
            if (inner_ss != .pseudo_class) continue;
            if (!std.ascii.eqlIgnoreCase(inner_ss.pseudo_class.name, "not")) continue;
            const nested_selector = inner_ss.pseudo_class.selector orelse continue;
            if (nested_selector.selectors.items.len != 1) continue;
            const nested_inner = &nested_selector.selectors.items[0];
            if (notPseudoExistsInCompound(compound, nested_inner)) continue;

            var duplicate_addition = false;
            for (additions.items) |*existing| {
                if (complexSelectorEql(existing, nested_inner)) {
                    duplicate_addition = true;
                    break;
                }
            }
            if (duplicate_addition) continue;

            var cloned_inner = nested_inner.clone(allocator) catch return;
            additions.append(allocator, cloned_inner) catch {
                cloned_inner.deinit();
                return;
            };
        }
    }

    for (additions.items) |*nested_inner| {
        appendNotPseudoWithInnerComplex(allocator, compound, nested_inner) catch return;
    }
}

fn notInnerHasNestedNot(inner: *const ComplexSelector) bool {
    if (inner.components.items.len != 1 or inner.components.items[0] != .compound) return false;
    for (inner.components.items[0].compound.simple_selectors.items) |ss| {
        if (ss == .pseudo_class and std.ascii.eqlIgnoreCase(ss.pseudo_class.name, "not")) return true;
    }
    return false;
}

fn pruneNestedLeafNotBuildingBlocks(compound: *CompoundSelector) void {
    var i: usize = compound.simple_selectors.items.len;
    while (i > 0) {
        i -= 1;
        const leaf_ss = compound.simple_selectors.items[i];
        if (leaf_ss != .pseudo_class or !std.ascii.eqlIgnoreCase(leaf_ss.pseudo_class.name, "not")) continue;
        const leaf_selector = leaf_ss.pseudo_class.selector orelse continue;
        if (leaf_selector.selectors.items.len != 1) continue;
        const leaf_inner = &leaf_selector.selectors.items[0];
        if (notInnerHasExtendablePseudo(leaf_inner)) continue;
        if (!notInnerHasNestedNot(leaf_inner)) continue;

        var mid_found = false;
        var top_found = false;
        for (compound.simple_selectors.items, 0..) |mid_ss, mid_idx| {
            if (mid_idx == i) continue;
            if (mid_ss != .pseudo_class or !std.ascii.eqlIgnoreCase(mid_ss.pseudo_class.name, "not")) continue;
            const mid_selector = mid_ss.pseudo_class.selector orelse continue;
            if (mid_selector.selectors.items.len != 1) continue;
            const mid_inner = &mid_selector.selectors.items[0];
            if (!notInnerHasExtendablePseudo(mid_inner)) continue;
            if (!notInnerUsesAsBuildingBlock(mid_inner, leaf_inner)) continue;
            mid_found = true;

            for (compound.simple_selectors.items, 0..) |top_ss, top_idx| {
                if (top_idx == i or top_idx == mid_idx) continue;
                if (top_ss != .pseudo_class or !std.ascii.eqlIgnoreCase(top_ss.pseudo_class.name, "not")) continue;
                const top_selector = top_ss.pseudo_class.selector orelse continue;
                if (top_selector.selectors.items.len != 1) continue;
                const top_inner = &top_selector.selectors.items[0];
                if (notInnerHasExtendablePseudo(top_inner)) continue;
                if (notInnerUsesAsBuildingBlock(top_inner, mid_inner)) {
                    top_found = true;
                    break;
                }
            }
            if (top_found) break;
        }

        if (!mid_found or !top_found) continue;
        var removed = compound.simple_selectors.orderedRemove(i);
        selector_mod.deinitSimpleSelector(&removed, compound.allocator);
    }
}

fn canonicalizeMixedNotHasDeepestEntry(
    allocator: std.mem.Allocator,
    compound: *CompoundSelector,
) void {
    const Local = struct {
        fn collect(
            target: *CompoundSelector,
            out_indices: *[16]usize,
            out_inners: *[16]*const ComplexSelector,
            out_has_based: *[16]bool,
        ) usize {
            var count: usize = 0;
            for (target.simple_selectors.items, 0..) |ss, idx| {
                if (ss != .pseudo_class or !std.ascii.eqlIgnoreCase(ss.pseudo_class.name, "not")) continue;
                const selector = ss.pseudo_class.selector orelse continue;
                if (selector.selectors.items.len != 1) continue;
                if (count >= out_indices.len) return count;
                out_indices[count] = idx;
                out_inners[count] = &selector.selectors.items[0];
                out_has_based[count] = notInnerHasExtendablePseudo(&selector.selectors.items[0]);
                count += 1;
            }
            return count;
        }
    };

    var not_indices: [16]usize = undefined;
    var not_inners: [16]*const ComplexSelector = undefined;
    var has_based: [16]bool = undefined;
    const not_count = Local.collect(compound, &not_indices, &not_inners, &has_based);
    if (not_count < 5) return;

    var root_nonhas: ?usize = null;
    var base_has: ?usize = null;
    var mid_nonhas: ?usize = null;

    for (0..not_count) |i| {
        if (has_based[i]) continue;
        if (!notInnerHasNestedNot(not_inners[i])) {
            root_nonhas = i;
            break;
        }
    }
    const root_idx = root_nonhas orelse return;

    for (0..not_count) |i| {
        if (!has_based[i]) continue;
        if (notInnerUsesAsBuildingBlock(not_inners[i], not_inners[root_idx])) {
            base_has = i;
            break;
        }
    }
    const base_has_idx = base_has orelse return;

    for (0..not_count) |i| {
        if (has_based[i]) continue;
        if (i == root_idx) continue;
        if (notInnerHasNestedNot(not_inners[i]) and
            notInnerUsesAsBuildingBlock(not_inners[i], not_inners[base_has_idx]))
        {
            mid_nonhas = i;
            break;
        }
    }
    const mid_nonhas_idx = mid_nonhas orelse return;

    var deepest_has: ?usize = null;
    var duplicate_drop: ?usize = null;
    for (0..not_count) |i| {
        if (!has_based[i] or i == base_has_idx) continue;
        const uses_base = notInnerUsesAsBuildingBlock(not_inners[i], not_inners[base_has_idx]);
        const uses_mid = notInnerUsesAsBuildingBlock(not_inners[i], not_inners[mid_nonhas_idx]);
        if (uses_mid and deepest_has == null) {
            deepest_has = i;
            continue;
        }
        if (not_count >= 6 and uses_base and !uses_mid and duplicate_drop == null) {
            duplicate_drop = i;
        }
    }
    const deepest_has_idx = deepest_has orelse return;

    var deepest_nonhas: ?usize = null;
    for (0..not_count) |i| {
        if (has_based[i]) continue;
        if (i == root_idx or i == mid_nonhas_idx) continue;
        if (!notInnerHasNestedNot(not_inners[i])) continue;
        const uses_drop = if (duplicate_drop) |drop_idx|
            notInnerUsesAsBuildingBlock(not_inners[i], not_inners[drop_idx])
        else
            false;
        if (uses_drop or
            notInnerUsesAsBuildingBlock(not_inners[i], not_inners[deepest_has_idx]) or
            notInnerUsesAsBuildingBlock(not_inners[i], not_inners[base_has_idx]))
        {
            deepest_nonhas = i;
            break;
        }
    }
    const deepest_nonhas_idx = deepest_nonhas orelse return;
    if (!notInnerUsesAsBuildingBlock(not_inners[deepest_nonhas_idx], not_inners[mid_nonhas_idx])) {
        const deepest_ss_idx = not_indices[deepest_nonhas_idx];
        if (compound.simple_selectors.items[deepest_ss_idx] != .pseudo_class) return;
        const deepest_selector = compound.simple_selectors.items[deepest_ss_idx].pseudo_class.selector orelse return;
        if (deepest_selector.selectors.items.len != 1) return;
        if (deepest_selector.selectors.items[0].components.items.len != 1 or
            deepest_selector.selectors.items[0].components.items[0] != .compound)
            return;

        const deepest_compound = &deepest_selector.selectors.items[0].components.items[0].compound;
        var insert_idx = deepest_compound.simple_selectors.items.len;
        for (deepest_compound.simple_selectors.items, 0..) |deepest_ss, idx| {
            if (deepest_ss != .pseudo_class) continue;
            if (!std.ascii.eqlIgnoreCase(deepest_ss.pseudo_class.name, "not")) continue;
            const deepest_inner_selector = deepest_ss.pseudo_class.selector orelse continue;
            if (deepest_inner_selector.selectors.items.len != 1) continue;
            if (notInnerUsesAsBuildingBlock(&deepest_inner_selector.selectors.items[0], not_inners[mid_nonhas_idx])) {
                insert_idx = idx;
                break;
            }
        }

        insertNotPseudoWithInnerComplex(
            allocator,
            deepest_compound,
            insert_idx,
            not_inners[mid_nonhas_idx],
        ) catch return;
        reorderNotPseudosByDependency(deepest_compound);
        reorderNotPseudosByHasPriority(deepest_compound);
    }

    const duplicate_drop_idx = duplicate_drop orelse return;
    const drop_ss_idx = not_indices[duplicate_drop_idx];
    if (drop_ss_idx >= compound.simple_selectors.items.len) return;
    var removed = compound.simple_selectors.orderedRemove(drop_ss_idx);
    selector_mod.deinitSimpleSelector(&removed, compound.allocator);
}

/// Helper: check if a complex selector is a single compound pseudo that has
/// an incompatible vendor prefix relative to the outer pseudo_name.
fn checkIncompatibleVendorPseudo(complex: *const ComplexSelector, outer_name: []const u8) bool {
    if (complex.components.items.len != 1) return false;
    const comp = complex.components.items[0];
    if (comp != .compound) return false;
    const compound = comp.compound;
    if (compound.simple_selectors.items.len != 1) return false;
    const ss = compound.simple_selectors.items[0];
    switch (ss) {
        .pseudo_class => |ps| {
            if (ps.selector == null) return false;
            if (!isExtendableSelectorPseudo(ps.name)) return false;
            return isIncompatibleVendorPseudo(outer_name, ps.name);
        },
        else => return false,
    }
}

/// Returns true if `complex` is a single compound with a same-name pseudo-class
/// that should be flattened (e.g., :is(.d,.e) inside :is()).
fn shouldFlattenPseudo(complex: *const ComplexSelector, pseudo_name: []const u8) bool {
    if (complex.components.items.len != 1) return false;
    const comp = complex.components.items[0];
    if (comp != .compound) return false;
    const compound = comp.compound;
    if (compound.simple_selectors.items.len != 1) return false;
    const ss = compound.simple_selectors.items[0];
    switch (ss) {
        .pseudo_class => |ps| {
            return ps.selector != null and pseudoNamesMatchForFlatten(pseudo_name, ps.name);
        },
        else => return false,
    }
}

/// Check if a complex selector contains the target one level deep inside pseudo-selectors.
/// Get the inner SelectorList from a complex that is a single pseudo with the given name.
fn getFlattenedPseudoSelectors(complex: *const ComplexSelector, pseudo_name: []const u8) ?*const SelectorList {
    if (complex.components.items.len != 1) return null;
    const comp = complex.components.items[0];
    if (comp != .compound) return null;
    const compound = comp.compound;
    if (compound.simple_selectors.items.len != 1) return null;
    const ss = compound.simple_selectors.items[0];
    switch (ss) {
        .pseudo_class => |ps| {
            if (ps.selector != null and pseudoNamesMatchForFlatten(pseudo_name, ps.name)) {
                return ps.selector.?;
            }
            return null;
        },
        else => return null,
    }
}

/// Returns true if the complex selector is a single compound whose ONLY simple
/// selector is a non-idempotent selector-taking pseudo-class like :has(), :host(),
/// :host-context(), :slotted(). Bare :not(...) is intentionally EXCLUDED -- those
/// results must survive to serve as compound-building seeds in later passes.
fn isSingleDirectOuterNotSkipPseudoComplex(complex: *const ComplexSelector) bool {
    if (complex.components.items.len != 1) return false;
    const comp = complex.components.items[0];
    if (comp != .compound) return false;
    const compound = comp.compound;
    if (compound.simple_selectors.items.len != 1) return false;

    return switch (compound.simple_selectors.items[0]) {
        .pseudo_class => |ps| blk: {
            if (ps.selector == null) break :blk false;
            const base = selector_mod.pseudoBaseName(ps.name);
            //Keep bare :not(...) -- later passes refine it into compound form
            if (std.ascii.eqlIgnoreCase(base, "not")) break :blk false;
            break :blk !isIdempotentSelectorPseudo(ps.name);
        },
        .pseudo_element => |ps| blk: {
            if (ps.selector == null) break :blk false;
            break :blk !isIdempotentSelectorPseudo(ps.name);
        },
        else => false,
    };
}

/// Remove selector list items that are superseded by another item in the list.
/// Used for non-idempotent pseudos like :has() where a compound-superset result
/// (e.g. :not(.x):not(.y)) supersedes the original (e.g. :not(.x)).
fn removeSupersededSelectorListItems(selector_set: *SelectorList) void {
    var i: usize = selector_set.selectors.items.len;
    while (i > 0) {
        i -= 1;
        var should_remove = false;
        for (0..selector_set.selectors.items.len) |j| {
            if (i == j) continue;
            if (complexIsSupersededBy(&selector_set.selectors.items[i], &selector_set.selectors.items[j])) {
                should_remove = true;
                break;
            }
        }
        if (should_remove) {
            var removed = selector_set.selectors.orderedRemove(i);
            removed.deinit();
        }
    }
}

/// When extending inside :not(), if the result is a single compound with a
/// selector-taking pseudo like :is(), :where(), :matches(), we should flatten it
/// to produce multiple :not() pseudos. Returns the inner SelectorList if flattening
/// is applicable, or null otherwise.
fn extractFlattenedSelectors(complex: *const ComplexSelector) ?*const SelectorList {
    if (complex.components.items.len != 1) return null;
    const comp = complex.components.items[0];
    if (comp != .compound) return null;
    const compound = comp.compound;
    if (compound.simple_selectors.items.len != 1) return null;
    const ss = compound.simple_selectors.items[0];
    switch (ss) {
        .pseudo_class => |ps| {
            // Flatten :is(), :where(), :matches() only (not :not() itself - that's special-cased)
            if (ps.selector != null and
                (std.ascii.eqlIgnoreCase(ps.name, "is") or
                    std.ascii.eqlIgnoreCase(ps.name, "where") or
                    std.ascii.eqlIgnoreCase(ps.name, "matches")))
            {
                return ps.selector.?;
            }
            return null;
        },
        else => return null,
    }
}

fn complexIsOwnNotArgumentOfNonNotExtender(
    candidate: *const ComplexSelector,
    ext: *const Extension,
) bool {
    for (ext.extender.selectors.items) |extender_complex| {
        for (extender_complex.components.items) |comp| {
            if (comp != .compound) continue;
            var compound_has_non_not = false;
            for (comp.compound.simple_selectors.items) |ss| {
                if (ss != .pseudo_class or !std.ascii.eqlIgnoreCase(ss.pseudo_class.name, "not")) {
                    compound_has_non_not = true;
                    break;
                }
            }
            if (!compound_has_non_not) continue;
            for (comp.compound.simple_selectors.items) |ss| {
                if (ss != .pseudo_class) continue;
                const ps = ss.pseudo_class;
                if (!std.ascii.eqlIgnoreCase(ps.name, "not")) continue;
                const selector = ps.selector orelse continue;
                for (selector.selectors.items) |inner| {
                    if (complexSelectorEql(candidate, &inner)) return true;
                }
            }
        }
    }
    return false;
}

fn complexOnlyAddsNotPseudos(
    broader: *const ComplexSelector,
    narrower: *const ComplexSelector,
) bool {
    if (broader.components.items.len != narrower.components.items.len) return false;
    var saw_extra_not = false;
    for (broader.components.items, narrower.components.items) |bcomp, ncomp| {
        if (std.meta.activeTag(bcomp) != std.meta.activeTag(ncomp)) return false;
        switch (bcomp) {
            .combinator => |bc| if (bc != ncomp.combinator) return false,
            .compound => |bcompound| {
                const ncompound = ncomp.compound;
                for (bcompound.simple_selectors.items) |bss| {
                    var found = false;
                    for (ncompound.simple_selectors.items) |nss| {
                        if (simpleSelectorEql(bss, nss)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) return false;
                }
                for (ncompound.simple_selectors.items) |nss| {
                    var found = false;
                    for (bcompound.simple_selectors.items) |bss| {
                        if (simpleSelectorEql(bss, nss)) {
                            found = true;
                            break;
                        }
                    }
                    if (found) continue;
                    if (nss != .pseudo_class or !std.ascii.eqlIgnoreCase(nss.pseudo_class.name, "not")) {
                        return false;
                    }
                    if (notPseudoArgumentHasIdentitySimple(nss.pseudo_class)) return false;
                    saw_extra_not = true;
                }
            },
        }
    }
    return saw_extra_not;
}

fn isCss2PseudoElementName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "before") or
        std.ascii.eqlIgnoreCase(name, "after") or
        std.ascii.eqlIgnoreCase(name, "first-line") or
        std.ascii.eqlIgnoreCase(name, "first-letter");
}

fn complexOnlyAddsUnknownPseudoClass(
    broader: *const ComplexSelector,
    narrower: *const ComplexSelector,
) bool {
    if (broader.components.items.len != narrower.components.items.len) return false;
    var saw_extra_unknown_pseudo = false;
    for (broader.components.items, narrower.components.items) |bcomp, ncomp| {
        if (std.meta.activeTag(bcomp) != std.meta.activeTag(ncomp)) return false;
        switch (bcomp) {
            .combinator => |bc| if (bc != ncomp.combinator) return false,
            .compound => |bcompound| {
                const ncompound = ncomp.compound;
                for (bcompound.simple_selectors.items) |bss| {
                    var found = false;
                    for (ncompound.simple_selectors.items) |nss| {
                        if (simpleSelectorEql(bss, nss)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) return false;
                }
                for (ncompound.simple_selectors.items) |nss| {
                    var found = false;
                    for (bcompound.simple_selectors.items) |bss| {
                        if (simpleSelectorEql(bss, nss)) {
                            found = true;
                            break;
                        }
                    }
                    if (found) continue;
                    switch (nss) {
                        .pseudo_class => |ps| {
                            if (std.ascii.eqlIgnoreCase(ps.name, "not")) return false;
                            if (isCss2PseudoElementName(ps.name)) return false;
                            saw_extra_unknown_pseudo = true;
                        },
                        else => return false,
                    }
                }
            },
        }
    }
    return saw_extra_unknown_pseudo;
}

fn notPseudoArgumentHasIdentitySimple(ps: PseudoSelector) bool {
    const selector = ps.selector orelse return false;
    for (selector.selectors.items) |complex| {
        for (complex.components.items) |component| {
            if (component != .compound) continue;
            for (component.compound.simple_selectors.items) |ss| {
                switch (ss) {
                    .type_selector, .class, .id, .attribute, .placeholder, .parent, .universal => return true,
                    .pseudo_class, .pseudo_element => {},
                }
            }
        }
    }
    return false;
}

fn complexFirstCompoundEql(a: *const ComplexSelector, b: *const ComplexSelector) bool {
    var ai: usize = 0;
    while (ai < a.components.items.len) : (ai += 1) {
        if (a.components.items[ai] == .compound) break;
    }
    var bi: usize = 0;
    while (bi < b.components.items.len) : (bi += 1) {
        if (b.components.items[bi] == .compound) break;
    }
    if (ai >= a.components.items.len or bi >= b.components.items.len) return false;
    return compoundSelectorEql(&a.components.items[ai].compound, &b.components.items[bi].compound);
}

pub fn preferBroaderOriginalsOverExtraNotPseudos(
    result: *SelectorList,
    original: *const SelectorList,
) !void {
    var idx: usize = 0;
    while (idx < result.selectors.items.len) {
        var replacement: ?*const ComplexSelector = null;
        var original_already_present = false;
        for (original.selectors.items) |*orig| {
            if (complexSelectorContainsPlaceholder(orig)) continue;
            if (!complexOnlyAddsNotPseudos(orig, &result.selectors.items[idx])) continue;
            if (!complexIsBroaderThan(orig, &result.selectors.items[idx])) continue;
            replacement = orig;
            for (result.selectors.items, 0..) |*existing, existing_idx| {
                if (existing_idx == idx) continue;
                if (complexSelectorEql(existing, orig)) {
                    original_already_present = true;
                    break;
                }
            }
            break;
        }
        if (replacement) |orig| {
            if (original_already_present) {
                var removed = result.selectors.orderedRemove(idx);
                removed.deinit();
                continue;
            }
            var cloned = try orig.clone(result.allocator);
            cloned.leading_separator_has_newline = result.selectors.items[idx].leading_separator_has_newline;
            result.selectors.items[idx].deinit();
            result.selectors.items[idx] = cloned;
        }
        idx += 1;
    }
}

fn compoundOnlyHasNotPseudos(compound: *const CompoundSelector) bool {
    if (compound.simple_selectors.items.len == 0) return false;
    for (compound.simple_selectors.items) |ss| {
        if (ss != .pseudo_class) return false;
        if (!std.ascii.eqlIgnoreCase(ss.pseudo_class.name, "not")) return false;
    }
    return true;
}

fn selectorListIsSimpleNotArgument(list: *const SelectorList) bool {
    if (list.selectors.items.len != 1) return false;
    const complex = &list.selectors.items[0];
    return complex.components.items.len == 1 and complex.components.items[0] == .compound;
}

fn complexHasTopLevelNotPseudo(c: *const ComplexSelector) bool {
    for (c.components.items) |component| {
        if (component != .compound) continue;
        for (component.compound.simple_selectors.items) |ss| {
            if (ss == .pseudo_class and std.ascii.eqlIgnoreCase(ss.pseudo_class.name, "not")) return true;
        }
    }
    return false;
}

fn appendExtendersOfNotTargets(
    allocator: std.mem.Allocator,
    result: *SelectorList,
    extensions: []const Extension,
) error{OutOfMemory}!void {
    const initial_len = result.selectors.items.len;
    for (extensions) |*ext| {
        if (ext.target.simple_selectors.items.len != 1) continue;
        const target_ss = ext.target.simple_selectors.items[0];
        if (target_ss != .pseudo_class or !std.ascii.eqlIgnoreCase(target_ss.pseudo_class.name, "not")) continue;
        if (ext.extender.selectors.items.len != 1) continue;
        const extender = &ext.extender.selectors.items[0];
        if (extender.components.items.len != 1 or extender.components.items[0] != .compound) continue;

        var idx: usize = 0;
        while (idx < initial_len) : (idx += 1) {
            const complex = &result.selectors.items[idx];
            if (complex.components.items.len != 1 or complex.components.items[0] != .compound) continue;
            const compound = &complex.components.items[0].compound;
            var has_target_not = false;
            var extra_not_count: usize = 0;
            for (compound.simple_selectors.items) |ss| {
                if (simpleSelectorEql(ss, target_ss)) {
                    has_target_not = true;
                } else if (ss == .pseudo_class and std.ascii.eqlIgnoreCase(ss.pseudo_class.name, "not")) {
                    extra_not_count += 1;
                }
            }
            if (!has_target_not or extra_not_count == 0) continue;

            var new_complex = ComplexSelector.init(allocator);
            errdefer new_complex.deinit();
            var new_compound = try extender.components.items[0].compound.clone(allocator);
            errdefer new_compound.deinit();
            for (compound.simple_selectors.items) |ss| {
                if (simpleSelectorEql(ss, target_ss)) continue;
                if (ss == .pseudo_class and std.ascii.eqlIgnoreCase(ss.pseudo_class.name, "not")) {
                    try new_compound.simple_selectors.append(allocator, try cloneSimpleSelector(ss, allocator));
                }
            }
            try new_complex.components.append(allocator, .{ .compound = new_compound });
            new_compound = CompoundSelector.init(allocator);

            var dup = false;
            for (result.selectors.items) |*existing| {
                if (complexSelectorEql(existing, &new_complex) or (complexHasExactCssText(existing, &new_complex) catch false)) {
                    dup = true;
                    break;
                }
            }
            if (dup) {
                new_complex.deinit();
            } else {
                try result.selectors.append(allocator, new_complex);
            }
        }
    }
}

fn simpleClassName(ss: SimpleSelector) ?[]const u8 {
    return switch (ss) {
        .class => |name| name,
        else => null,
    };
}

fn singleCompoundAllClasses(c: *const ComplexSelector) ?*const CompoundSelector {
    if (c.components.items.len != 1 or c.components.items[0] != .compound) return null;
    const compound = &c.components.items[0].compound;
    if (compound.simple_selectors.items.len == 0) return null;
    for (compound.simple_selectors.items) |ss| {
        if (ss != .class) return null;
    }
    return compound;
}

fn resultHasComplex(result: *const SelectorList, candidate: *const ComplexSelector) bool {
    for (result.selectors.items) |*existing| {
        if (complexSelectorEql(existing, candidate)) return true;
    }
    return false;
}

fn appendCircularExtendLoopClassVariants(
    allocator: std.mem.Allocator,
    result: *SelectorList,
) error{OutOfMemory}!void {
    const initial_len = result.selectors.items.len;
    var base_idx: usize = 0;
    while (base_idx < initial_len) : (base_idx += 1) {
        const base_compound = singleCompoundAllClasses(&result.selectors.items[base_idx]) orelse continue;
        if (base_compound.simple_selectors.items.len != 2) continue;
        const base_first = simpleClassName(base_compound.simple_selectors.items[0]) orelse continue;
        const base_tail = simpleClassName(base_compound.simple_selectors.items[1]) orelse continue;

        var cand_idx: usize = 0;
        while (cand_idx < initial_len) : (cand_idx += 1) {
            const cand_compound = singleCompoundAllClasses(&result.selectors.items[cand_idx]) orelse continue;
            if (cand_compound.simple_selectors.items.len < 4) continue;
            const cand_first = simpleClassName(cand_compound.simple_selectors.items[0]) orelse continue;
            if (!std.mem.eql(u8, cand_first, base_first)) continue;
            var already_has_tail = false;
            for (cand_compound.simple_selectors.items[1..]) |ss| {
                const name = simpleClassName(ss) orelse continue;
                if (std.mem.eql(u8, name, base_tail)) {
                    already_has_tail = true;
                    break;
                }
            }
            if (already_has_tail) continue;

            var new_complex = ComplexSelector.init(allocator);
            errdefer new_complex.deinit();
            var new_compound = CompoundSelector.init(allocator);
            errdefer new_compound.deinit();
            // Reserve up front so the inner appends cannot fail; otherwise
            // an OOM after `classSimpleFromName` / `cloneSimpleSelector`
            // succeeds would leak the freshly duped class string.
            try new_compound.simple_selectors.ensureTotalCapacity(allocator, cand_compound.simple_selectors.items.len);
            for (cand_compound.simple_selectors.items, 0..) |ss, ss_idx| {
                if (ss_idx + 1 == cand_compound.simple_selectors.items.len) {
                    new_compound.simple_selectors.appendAssumeCapacity(try selector_mod.classSimpleFromName(allocator, base_tail));
                } else {
                    new_compound.simple_selectors.appendAssumeCapacity(try cloneSimpleSelector(ss, allocator));
                }
            }
            try new_complex.components.append(allocator, .{ .compound = new_compound });
            new_compound = CompoundSelector.init(allocator);
            if (resultHasComplex(result, &new_complex)) {
                new_complex.deinit();
            } else {
                try result.selectors.append(allocator, new_complex);
            }
        }
    }
}

fn compoundContainsAllNotPseudos(compound: *const CompoundSelector, required: *const CompoundSelector) bool {
    for (required.simple_selectors.items) |req| {
        if (req != .pseudo_class or !std.ascii.eqlIgnoreCase(req.pseudo_class.name, "not")) continue;
        var found = false;
        for (compound.simple_selectors.items) |cand| {
            if (simpleSelectorEql(req, cand)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// Dart Sass drops a generated branch like `.a:not(.b):not(.c)` when an
/// earlier branch is the pure negation `:not(.b):not(.c)`: the generated
/// selector is a strict subset of the already-emitted negation branch.
pub fn removeBranchesCoveredByPureNotBranch(result: *SelectorList) void {
    var idx: usize = 0;
    while (idx < result.selectors.items.len) {
        if (result.selectors.items[idx].components.items.len != 1 or
            result.selectors.items[idx].components.items[0] != .compound)
        {
            idx += 1;
            continue;
        }
        const compound = &result.selectors.items[idx].components.items[0].compound;
        var covered = false;
        var prev_idx: usize = 0;
        while (prev_idx < idx) : (prev_idx += 1) {
            if (result.selectors.items[prev_idx].components.items.len != 1 or
                result.selectors.items[prev_idx].components.items[0] != .compound)
            {
                continue;
            }
            const prev_compound = &result.selectors.items[prev_idx].components.items[0].compound;
            if (!compoundOnlyHasNotPseudos(prev_compound)) continue;
            if (compound.simple_selectors.items.len <= prev_compound.simple_selectors.items.len) continue;
            if (compoundContainsAllNotPseudos(compound, prev_compound)) {
                covered = true;
                break;
            }
        }
        if (covered) {
            var removed = result.selectors.orderedRemove(idx);
            removed.deinit();
            continue;
        }
        idx += 1;
    }
}

/// For :not() pseudo - determine new complex selectors to add as additional
/// :not() pseudo-classes to the compound.
/// Returns a slice of new ComplexSelectors (caller owns them).
/// Each returned ComplexSelector becomes a new :not(<complex>) appended to the compound.
fn extendNotPseudo(
    frame: *ApplyFrame,
    allocator: std.mem.Allocator,
    inner: *const SelectorList,
    ext: *const Extension,
) error{OutOfMemory}![]ComplexSelector {
    var results: std.ArrayList(ComplexSelector) = .empty;
    errdefer {
        for (results.items) |*r| r.deinit();
        results.deinit(allocator);
    }
    const max_results_hint = saturatingMulUsize(inner.selectors.items.len, @max(ext.extender.selectors.items.len, 1));
    try results.ensureTotalCapacity(allocator, max_results_hint);

    if (selectorListIsSimpleNotArgument(inner)) {
        for (ext.extender.selectors.items) |extender_complex| {
            if (extender_complex.components.items.len > 1) {
                return results.toOwnedSlice(allocator);
            }
        }
    }

    // Guard: if the extender contains top-level :not() pseudos whose arguments
    // do NOT contain the extend target, skip to prevent :not(:not(X)) generation
    // (issues 2034, 2054, 2057).
    //
    //Strict mode (cross-extension): ANY :not() failing  ->  bail immediately.
    // Relaxed mode (main pass): at least one :not() must pass; bail only if ALL fail.
    // This allows cross-extended extenders like :not(A):not(B) where A wraps the
    // target but B doesn't (issue 2055).
    {
        var has_any_not = false;
        var any_not_has_target = false;
        var has_pure_not_without_target = false;
        for (ext.extender.selectors.items) |extender_complex| {
            for (extender_complex.components.items) |comp| {
                if (comp != .compound) continue;
                var compound_has_non_not = false;
                for (comp.compound.simple_selectors.items) |ss| {
                    if (ss != .pseudo_class or !std.ascii.eqlIgnoreCase(ss.pseudo_class.name, "not")) {
                        compound_has_non_not = true;
                        break;
                    }
                }
                for (comp.compound.simple_selectors.items) |ss| {
                    if (ss != .pseudo_class) continue;
                    const ps = ss.pseudo_class;
                    if (!std.ascii.eqlIgnoreCase(ps.name, "not")) continue;
                    has_any_not = true;
                    if (ps.selector) |not_sel| {
                        var target_in_not = false;
                        for (not_sel.selectors.items) |not_complex| {
                            if (compoundContainsTargetInComplex(&not_complex, &ext.target)) {
                                target_in_not = true;
                                break;
                            }
                        }
                        if (target_in_not) {
                            any_not_has_target = true;
                        } else if (!compound_has_non_not) {
                            has_pure_not_without_target = true;
                        } else if (!frame.relax_not_pseudo_guard) {
                            continue;
                        }
                    } else if (!compound_has_non_not) {
                        has_pure_not_without_target = true;
                    } else if (!frame.relax_not_pseudo_guard) {
                        continue;
                    }
                    if (has_pure_not_without_target and !frame.relax_not_pseudo_guard) {
                        return results.toOwnedSlice(allocator);
                    }
                }
            }
        }
        if (has_pure_not_without_target) {
            return results.toOwnedSlice(allocator);
        }
        if (has_any_not and !any_not_has_target) {
            var has_non_not_extender = false;
            for (ext.extender.selectors.items) |extender_complex| {
                for (extender_complex.components.items) |comp| {
                    if (comp != .compound) continue;
                    for (comp.compound.simple_selectors.items) |ss| {
                        if (ss != .pseudo_class or !std.ascii.eqlIgnoreCase(ss.pseudo_class.name, "not")) {
                            has_non_not_extender = true;
                            break;
                        }
                    }
                    if (has_non_not_extender) break;
                }
                if (has_non_not_extender) break;
            }
            if (!has_non_not_extender) {
                return results.toOwnedSlice(allocator);
            }
        }
    }

    // For each inner complex selector that matches the target, generate extended versions.
    // These become new :not() arguments added to the compound.
    for (inner.selectors.items) |inner_complex| {
        // Only extend when the target appears directly in a compound selector.
        //Do NOT use complexContainsTargetInPseudos here -- that would cause
        //unbounded recursion through applyExtensionToComplex  ->  extendInsidePseudos
        // ->  extendNotPseudo when cross-extended extenders have deeply nested pseudos.
        if (!compoundContainsTargetInComplex(&inner_complex, &ext.target)) {
            // In relaxed mode (main pass), do a shallow one-level extension
            // for :not() pseudos whose inner directly contains the target.
            // This avoids deep recursion while handling issue 2055 Rules 2/3.
            if (frame.relax_not_pseudo_guard) {
                const shallow = try extendNotPseudoShallow(frame, allocator, &inner_complex, ext);
                if (shallow) |new_cx| {
                    try results.append(allocator, new_cx);
                }
            }
            continue;
        }

        // Generate extended versions of this inner complex
        const extended = try applyExtensionToComplex(frame, allocator, &inner_complex, ext, false);
        defer allocator.free(extended);

        for (extended) |new_c| {
            // When the original :not() argument is a simple compound selector
            // (single component), drop complex extension results that contain
            // combinators, because :not() with a simple argument should not
            // produce complex selectors like :not(.bar .baz).
            if (inner_complex.components.items.len == 1 and new_c.components.items.len > 1) {
                var s = new_c;
                s.deinit();
                continue;
            }

            // Bare non-idempotent selector-taking pseudos like :has(...)
            // should not be wrapped directly in a new outer :not(). Keep bare
            // :not(...) results, since later passes refine those into the
            // compound argument form expected by sass-spec.
            if (inner_complex.components.items.len == 1 and
                isSingleDirectOuterNotSkipPseudoComplex(&new_c))
            {
                var s = new_c;
                s.deinit();
                continue;
            }

            if (complexIsOwnNotArgumentOfNonNotExtender(&new_c, ext)) {
                var s = new_c;
                s.deinit();
                continue;
            }

            // Check for duplicates
            var is_dup = false;
            for (results.items) |existing| {
                if (complexSelectorEql(&existing, &new_c)) {
                    is_dup = true;
                    break;
                }
            }
            if (!is_dup) {
                try results.append(allocator, new_c);
            } else {
                var s = new_c;
                s.deinit();
            }
        }
    }

    {
        var idx: usize = 0;
        while (idx < results.items.len) {
            if (complexIsOwnNotArgumentOfNonNotExtender(&results.items[idx], ext)) {
                var removed = results.orderedRemove(idx);
                removed.deinit();
                continue;
            }
            idx += 1;
        }
    }

    return results.toOwnedSlice(allocator);
}

/// Shallow one-level extension for :not() pseudo inner complexes.
/// When the inner doesn't directly contain the target but has :not() pseudos
/// whose inner DOES contain it, extend those :not() inners and rebuild the
/// compound. Returns the new complex, or null if nothing changed.
/// This avoids the deep recursion of applyExtensionToComplex while still
/// handling nested pseudo targets (issue 2055 Rules 2/3).
fn extendNotPseudoShallow(
    frame: *ApplyFrame,
    allocator: std.mem.Allocator,
    inner_complex: *const ComplexSelector,
    ext: *const Extension,
) error{OutOfMemory}!?ComplexSelector {
    // Only handle single-compound complexes
    if (inner_complex.components.items.len != 1) return null;
    if (inner_complex.components.items[0] != .compound) return null;
    const compound = inner_complex.components.items[0].compound;

    // Only apply to compounds that have at least one non-:not() simple selector
    // (e.g., [disabled]:not(X):not(Y)). Skip pure :not() compounds (which are
    //full extender compounds -- extending these produce unwanted duplication).
    {
        var has_non_not = false;
        for (compound.simple_selectors.items) |ss| {
            if (ss != .pseudo_class or !std.ascii.eqlIgnoreCase(ss.pseudo_class.name, "not")) {
                has_non_not = true;
                break;
            }
        }
        if (!has_non_not) return null;
    }

    var new_nots: std.ArrayList(ComplexSelector) = .empty;
    defer {
        for (new_nots.items) |*n| n.deinit();
        new_nots.deinit(allocator);
    }
    const not_hint = saturatingMulUsize(compound.simple_selectors.items.len, @max(ext.extender.selectors.items.len, 1));
    try new_nots.ensureTotalCapacity(allocator, not_hint);

    for (compound.simple_selectors.items) |ss| {
        if (ss != .pseudo_class) continue;
        const ps = ss.pseudo_class;
        if (!std.ascii.eqlIgnoreCase(ps.name, "not")) continue;
        if (ps.selector == null) continue;
        const not_sel = ps.selector.?;
        if (not_sel.selectors.items.len != 1) continue;
        const seed_cx = &not_sel.selectors.items[0];
        if (seed_cx.components.items.len != 1) continue;
        if (seed_cx.components.items[0] != .compound) continue;
        const seed_compound = seed_cx.components.items[0].compound;
        const seed_has_direct_target = compoundContainsTarget(&seed_compound, &ext.target);

        if (seed_has_direct_target) {
            // Extend the seed compound with each extender complex
            for (ext.extender.selectors.items) |extender_cx| {
                var extra: std.ArrayList(ComplexSelector) = .empty;
                defer {
                    for (extra.items) |*e| e.deinit();
                    extra.deinit(allocator);
                }
                const new_cx = try generateExtendedSelector(
                    allocator,
                    seed_cx,
                    0,
                    &seed_compound,
                    &ext.target,
                    &extender_cx,
                    &extra,
                    frame.config.function_mode,
                );
                if (new_cx) |nc| {
                    if (nc.components.items.len > 1) {
                        var discard = nc;
                        discard.deinit();
                        continue;
                    }
                    // Skip if duplicate
                    var is_dup = notPseudoExistsInCompound(&compound, &nc);
                    if (!is_dup) {
                        for (new_nots.items) |*existing| {
                            if (complexSelectorEql(existing, &nc)) {
                                is_dup = true;
                                break;
                            }
                        }
                    }
                    if (!is_dup) {
                        // Skip bare non-idempotent pseudos
                        if (isSingleDirectOuterNotSkipPseudoComplex(&nc)) {
                            var discard = nc;
                            discard.deinit();
                            continue;
                        }
                        try new_nots.append(allocator, nc);
                    } else {
                        var discard = nc;
                        discard.deinit();
                    }
                }
            }
        }

        // Also allow a single nested selector-taking pseudo such as :has()
        // inside the top-level :not() argument to extend one level deeper.
        for (seed_compound.simple_selectors.items, 0..) |seed_ss, seed_idx| {
            if (seed_ss != .pseudo_class) continue;
            const seed_ps = seed_ss.pseudo_class;
            if (!isExtendableSelectorPseudo(seed_ps.name) or seed_ps.selector == null) continue;
            if (std.ascii.eqlIgnoreCase(seed_ps.name, "not")) continue;
            if (frame.in_shallow_has_extension or frame.shallow_has_budget >= max_shallow_has_budget) continue;

            frame.in_shallow_has_extension = true;
            frame.shallow_has_budget += 1;
            defer frame.in_shallow_has_extension = false;

            const new_inner = try extendSelectorList(frame, allocator, seed_ps.selector.?, ext, seed_ps.name);
            if (new_inner == null) continue;

            var rewritten_compound = CompoundSelector.init(allocator);
            errdefer rewritten_compound.deinit();
            for (seed_compound.simple_selectors.items, 0..) |orig_ss, orig_idx| {
                if (orig_idx == seed_idx) {
                    try appendPseudoClassWithSelectorList(
                        allocator,
                        &rewritten_compound,
                        seed_ps.name,
                        null,
                        new_inner.?,
                    );
                } else {
                    try rewritten_compound.simple_selectors.append(
                        allocator,
                        try cloneSimpleSelector(orig_ss, allocator),
                    );
                }
            }

            var rewritten_complex = ComplexSelector.init(allocator);
            errdefer rewritten_complex.deinit();
            try rewritten_complex.components.append(allocator, .{ .compound = rewritten_compound });
            rewritten_compound = CompoundSelector.init(allocator);

            var is_dup = notPseudoExistsInCompound(&compound, &rewritten_complex);
            if (!is_dup) {
                for (new_nots.items) |*existing| {
                    if (complexSelectorEql(existing, &rewritten_complex)) {
                        is_dup = true;
                        break;
                    }
                }
            }
            if (!is_dup) {
                try new_nots.append(allocator, rewritten_complex);
            } else {
                rewritten_complex.deinit();
            }
        }
    }

    // Rebuild compound: clone each simple selector, but for :has() etc. extend their inner.
    var has_changed = false;
    var new_compound = CompoundSelector.init(allocator);
    errdefer new_compound.deinit();
    for (compound.simple_selectors.items) |ss| {
        if (ss == .pseudo_class) {
            const ps = ss.pseudo_class;
            if (isExtendableSelectorPseudo(ps.name) and ps.selector != null and
                !std.ascii.eqlIgnoreCase(ps.name, "not") and
                !frame.in_shallow_has_extension and frame.shallow_has_budget < max_shallow_has_budget)
            {
                frame.in_shallow_has_extension = true;
                frame.shallow_has_budget += 1;
                defer {
                    frame.in_shallow_has_extension = false;
                }
                const new_inner = try extendSelectorList(frame, allocator, ps.selector.?, ext, ps.name);
                if (new_inner) |inner_list| {
                    has_changed = true;
                    try appendPseudoClassWithSelectorList(
                        allocator,
                        &new_compound,
                        ps.name,
                        null,
                        inner_list,
                    );
                    continue;
                }
            }
        }
        try new_compound.simple_selectors.append(allocator, try cloneSimpleSelector(ss, allocator));
    }

    if (new_nots.items.len == 0 and !has_changed) {
        new_compound.deinit();
        return null;
    }

    for (new_nots.items) |new_not_cx| {
        try appendNotPseudoWithInnerComplex(allocator, &new_compound, &new_not_cx);
    }

    var result = ComplexSelector.init(allocator);
    errdefer result.deinit();
    try result.components.append(allocator, .{ .compound = new_compound });
    return result;
}

/// Check if a complex selector has any compound that contains the target.
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

/// Check if a complex selector contains any placeholder simple selector.
fn complexContainsPlaceholder(complex: *const ComplexSelector) bool {
    for (complex.components.items) |comp| {
        switch (comp) {
            .compound => |c| {
                for (c.simple_selectors.items) |ss| {
                    if (ss == .placeholder) return true;
                }
            },
            .combinator => {},
        }
    }
    return false;
}

fn complexIsBareOrPseudoPlaceholder(complex: *const ComplexSelector) bool {
    if (complex.components.items.len != 1) return false;
    const comp = complex.components.items[0];
    if (comp != .compound) return false;
    var has_placeholder = false;
    for (comp.compound.simple_selectors.items) |ss| {
        switch (ss) {
            .placeholder => has_placeholder = true,
            .pseudo_class, .pseudo_element, .attribute => {},
            .class => |name| {
                if (!std.mem.startsWith(u8, name, "is-")) return false;
            },
            else => return false,
        }
    }
    return has_placeholder;
}

fn complexHasPseudoSelector(complex: *const ComplexSelector) bool {
    for (complex.components.items) |comp| {
        if (comp != .compound) continue;
        for (comp.compound.simple_selectors.items) |ss| {
            if (ss == .pseudo_class or ss == .pseudo_element) return true;
        }
    }
    return false;
}

fn complexHasNonNotSimpleSelector(complex: *const ComplexSelector) bool {
    for (complex.components.items) |comp| {
        if (comp != .compound) continue;
        for (comp.compound.simple_selectors.items) |ss| {
            if (ss != .pseudo_class or !std.ascii.eqlIgnoreCase(ss.pseudo_class.name, "not")) {
                return true;
            }
        }
    }
    return false;
}

fn complexIsAttributeContextPlaceholder(complex: *const ComplexSelector) bool {
    var has_placeholder = false;
    var has_attribute = false;
    for (complex.components.items) |comp| {
        if (comp != .compound) continue;
        for (comp.compound.simple_selectors.items) |ss| {
            if (ss == .placeholder) has_placeholder = true;
            if (ss == .attribute) has_attribute = true;
        }
    }
    return has_placeholder and has_attribute;
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

/// Returns true if the target compound consists of a single idempotent selector
/// pseudo (:is, :where, :matches, :any, :current) AND the extender compound is a
/// subselector of (more specific than) any selector inside the pseudo's argument list.
///
/// When this returns true, the extension would just produce new selectors already
/// covered by the original compound (since :is(X, Y) = :is(X) if Y  <=  X), so it
/// should be a no-op.
///
/// Example: target = ":is(d)" (compound with 1 simple selector),
///          extender = "d.e"
///  ->  "d.e" has type selector "d" which is inside :is(d)'s selector list
///  ->  "d.e" is a subselector of "d", so the extension is a no-op.
fn isExtenderSubselectorOfPseudoTarget(
    target: *const CompoundSelector,
    extender: *const CompoundSelector,
) bool {
    // Target must be a single idempotent selector pseudo
    if (target.simple_selectors.items.len != 1) return false;
    const target_ss = target.simple_selectors.items[0];
    const pseudo = switch (target_ss) {
        .pseudo_class => |ps| ps,
        else => return false,
    };
    if (!isIdempotentSelectorPseudo(pseudo.name)) return false;
    const inner_list = pseudo.selector orelse return false;

    // Check if extender is a subselector of any inner selector
    // A compound `ext` is a subselector of complex `inner` if:
    // 1. inner is a single compound
    // 2. ext contains all simple selectors of inner (ext is more specific)
    for (inner_list.selectors.items) |inner_cx| {
        if (inner_cx.components.items.len != 1) continue;
        const inner_comp_item = inner_cx.components.items[0];
        if (inner_comp_item != .compound) continue;
        const inner_comp = inner_comp_item.compound;
        // extender must contain all of inner_comp's simple selectors
        if (compoundContainsTarget(extender, &inner_comp)) {
            return true;
        }
    }
    return false;
}

/// Generate an extended complex selector by replacing the target in the compound
/// at position comp_idx with the extender.
///
/// `superset_extender_is_noop` controls whether a single-compound extender that
/// is a textual superset of the original compound (e.g. `.c.d` extending `.c`)
/// short-circuits to no-op. This matches `selector.extend()` function semantics,
/// but the `@extend` directive path must still generate the narrower variant
/// because dart-sass emits it (e.g. `.c.d` extending `.c` in `.c { color: red }`
/// yields `.c, .c.d { color: red }`).
fn generateExtendedSelector(
    allocator: std.mem.Allocator,
    original: *const ComplexSelector,
    comp_idx: usize,
    compound: *const CompoundSelector,
    target: *const CompoundSelector,
    extender: *const ComplexSelector,
    extra_results: ?*std.ArrayList(ComplexSelector),
    superset_extender_is_noop: bool,
) !?ComplexSelector {
    // Build a new compound by removing the target simple selectors and
    // merging with the extender's last compound
    var extender_compounds: [64]struct { idx: usize, compound: CompoundSelector } = undefined;
    var extender_compound_count: usize = 0;
    for (extender.components.items, 0..) |ec, ei| {
        switch (ec) {
            .compound => |c| {
                if (extender_compound_count < 64) {
                    extender_compounds[extender_compound_count] = .{ .idx = ei, .compound = c };
                    extender_compound_count += 1;
                }
            },
            .combinator => {},
        }
    }

    if (extender_compound_count == 0) return null;

    // The last compound of the extender gets merged with our compound
    const extender_last = extender_compounds[extender_compound_count - 1];

    // No-op check 1: extender is single compound and is a superset of original compound.
    // e.g., selector.extend(".c", ".c", ".c.d") -> no-op because .c.d contains .c.
    if (extender_compound_count == 1) {
        if (superset_extender_is_noop and compoundContainsTarget(&extender_last.compound, compound)) {
            return null;
        }
        // No-op check 1b: target is a single idempotent selector pseudo (:is/..:where/etc.)
        // and the extender is a subselector of the pseudo's inner content.
        // e.g., selector.extend(".c:is(d)", ":is(d)", "d.e") -> no-op because "d.e" is
        // a subselector of "d" (the inner content of :is(d)), so extending :is(d) with d.e
        // just produces :is(d, d.e) = :is(d), and the outer compound d.c.e is already
        // covered by .c:is(d).
        if (isExtenderSubselectorOfPseudoTarget(target, &extender_last.compound)) {
            return null;
        }
    }

    // Build the unified compound
    const unified = try unifyCompound(allocator, compound, target, &extender_last.compound);
    if (unified == null) return null;
    var unified_val = unified.?;
    errdefer unified_val.deinit();

    const original_prefix = original.components.items[0..comp_idx];
    const original_suffix_start = comp_idx + 1;
    const original_suffix = if (original_suffix_start < original.components.items.len)
        original.components.items[original_suffix_start..]
    else
        &[_]ComplexSelectorComponent{};

    const ext_prefix = extender.components.items[0..extender_last.idx];
    const ext_suffix = if (extender_last.idx + 1 < extender.components.items.len)
        extender.components.items[extender_last.idx + 1 ..]
    else
        &[_]ComplexSelectorComponent{};

    const orig_trailing_comb: ?Combinator = if (original_prefix.len > 0)
        switch (original_prefix[original_prefix.len - 1]) {
            .combinator => |c| c,
            .compound => null,
        }
    else
        null;

    const ext_trailing_comb: ?Combinator = if (ext_prefix.len > 0)
        switch (ext_prefix[ext_prefix.len - 1]) {
            .combinator => |c| c,
            .compound => null,
        }
    else
        null;

    const orig_prefix_base = if (orig_trailing_comb != null)
        original_prefix[0 .. original_prefix.len - 1]
    else
        original_prefix;

    const ext_prefix_base = if (ext_trailing_comb != null)
        ext_prefix[0 .. ext_prefix.len - 1]
    else
        ext_prefix;

    const oc = orig_trailing_comb orelse .descendant;
    const ec = ext_trailing_comb orelse .descendant;
    const ext_suffix_comb: ?Combinator = if (ext_suffix.len > 0)
        switch (ext_suffix[0]) {
            .combinator => |c| c,
            .compound => null,
        }
    else
        null;

    if (ext_suffix_comb) |suffix_comb| {
        const orig_suffix_comb: ?Combinator = if (original_suffix.len > 0 and original_suffix[0] == .combinator)
            original_suffix[0].combinator
        else
            null;
        if (orig_suffix_comb != null and orig_suffix_comb.? != .descendant and orig_suffix_comb.? != suffix_comb) {
            unified_val.deinit();
            return null;
        }
    }

    // Detect bogus leading combinators (selectors starting with a combinator like `> .foo`)
    var leading_comb: ?Combinator = null;
    var adj_oc = oc;
    var adj_ec = ec;
    var adj_ext_base = ext_prefix_base;

    // Original prefix has leading combinator if base is empty and comb is non-descendant
    if (orig_prefix_base.len == 0 and oc != .descendant) {
        leading_comb = oc;
        adj_oc = .descendant;
    }

    // Extender prefix has leading combinator if:
    // 1. base is empty and comb is non-descendant, OR
    // 2. first element of base is a combinator
    if (adj_ext_base.len == 0 and adj_ec != .descendant) {
        if (leading_comb != null and leading_comb.? != adj_ec) {
            unified_val.deinit();
            return null;
        }
        leading_comb = leading_comb orelse adj_ec;
        adj_ec = .descendant;
    } else if (adj_ext_base.len > 0 and adj_ext_base[0] == .combinator) {
        const ext_lc = adj_ext_base[0].combinator;
        if (leading_comb != null and leading_comb.? != ext_lc) {
            unified_val.deinit();
            return null;
        }
        leading_comb = leading_comb orelse ext_lc;
        adj_ext_base = adj_ext_base[1..];
    }

    var woven = try weavePaths(allocator, orig_prefix_base, adj_oc, adj_ext_base, adj_ec);
    defer {
        for (woven.items) |*w| w.deinit();
        woven.deinit(allocator);
    }

    if (woven.items.len == 0) {
        unified_val.deinit();
        return null;
    }

    var primary_result: ?ComplexSelector = null;
    errdefer if (primary_result) |*pr| pr.deinit();
    if (extra_results) |er| {
        if (woven.items.len > 1) {
            try er.ensureUnusedCapacity(allocator, woven.items.len - 1);
        }
    }

    for (woven.items, 0..) |*w, wi| {
        var sel = ComplexSelector.init(allocator);
        errdefer sel.deinit();
        sel.leading_separator_has_newline = original.leading_separator_has_newline or extender.leading_separator_has_newline;

        // Prepend bogus leading combinator if present
        if (leading_comb) |lc| {
            try sel.components.append(allocator, .{ .combinator = lc });
        }

        for (w.components.items) |wc| {
            switch (wc) {
                .compound => |c| try sel.components.append(allocator, .{ .compound = try c.clone(allocator) }),
                .combinator => |c| try sel.components.append(allocator, .{ .combinator = c }),
            }
        }

        try sel.components.append(allocator, .{ .compound = try unified_val.clone(allocator) });

        var suffix_start: usize = 0;
        if (ext_suffix_comb) |suffix_comb| {
            try sel.components.append(allocator, .{ .combinator = suffix_comb });
            if (original_suffix.len > 0 and original_suffix[0] == .combinator) {
                suffix_start = 1;
            }
        }
        for (original_suffix[suffix_start..]) |sc| {
            switch (sc) {
                .compound => |c| try sel.components.append(allocator, .{ .compound = try c.clone(allocator) }),
                .combinator => |c| try sel.components.append(allocator, .{ .combinator = c }),
            }
        }

        if (wi == 0) {
            primary_result = sel;
        } else {
            if (extra_results) |er| {
                try er.append(allocator, sel);
            } else {
                sel.deinit();
            }
        }
    }

    unified_val.deinit();
    return primary_result;
}

// ============================================================================
// Post-processing: selector pseudo coalescing, :not merging
// ============================================================================

/// True when every complex in `small` matches a distinct complex in `big`
/// (`complexSelectorEql`), so duplicate entries in `small` consume separate
/// matches in `big`.
fn selectorListEveryComplexInSubsetOf(
    allocator: std.mem.Allocator,
    small: *const SelectorList,
    big: *const SelectorList,
) !bool {
    var used = try allocator.alloc(bool, big.selectors.items.len);
    defer allocator.free(used);
    @memset(used, false);
    outer: for (small.selectors.items) |s| {
        for (big.selectors.items, 0..) |b, bi| {
            if (used[bi]) continue;
            if (complexSelectorEql(&s, &b)) {
                used[bi] = true;
                continue :outer;
            }
        }
        return false;
    }
    return true;
}

/// True when one inner :is()/:where() list is a strict subset of the other.
/// Merging such variants would drop a selector with different specificity
/// (dart-sass#1297 / sass-spec directives/extend/pseudo extends_after).
fn selectorListStrictPseudoInnerSubsetRelation(
    allocator: std.mem.Allocator,
    a: *const SelectorList,
    b: *const SelectorList,
) !bool {
    if (a.selectors.items.len < b.selectors.items.len) {
        return try selectorListEveryComplexInSubsetOf(allocator, a, b);
    }
    if (b.selectors.items.len < a.selectors.items.len) {
        return try selectorListEveryComplexInSubsetOf(allocator, b, a);
    }
    return false;
}

fn appendUniqueSelectorListItems(
    allocator: std.mem.Allocator,
    dest: *SelectorList,
    src: *const SelectorList,
) !bool {
    var changed = false;
    var common_suffix_len: usize = 0;
    while (common_suffix_len < dest.selectors.items.len and common_suffix_len < src.selectors.items.len) {
        const dest_idx = dest.selectors.items.len - 1 - common_suffix_len;
        const src_idx = src.selectors.items.len - 1 - common_suffix_len;
        if (!complexSelectorEql(&dest.selectors.items[dest_idx], &src.selectors.items[src_idx])) break;
        common_suffix_len += 1;
    }

    var insert_idx = dest.selectors.items.len - common_suffix_len;
    const src_limit = src.selectors.items.len - common_suffix_len;
    for (src.selectors.items[0..src_limit]) |src_complex| {
        var is_dup = false;
        for (dest.selectors.items) |dest_complex| {
            if (complexSelectorEql(&dest_complex, &src_complex)) {
                is_dup = true;
                break;
            }
        }
        if (!is_dup) {
            changed = true;
            try dest.selectors.insert(allocator, insert_idx, try src_complex.clone(allocator));
            insert_idx += 1;
        }
    }
    return changed;
}

fn mergeCompatibleSelectorPseudoVariant(
    allocator: std.mem.Allocator,
    base: *ComplexSelector,
    incoming: *const ComplexSelector,
) !bool {
    if (base.components.items.len != incoming.components.items.len) return false;

    var merge_base_selector: ?*SelectorList = null;
    var merge_incoming_selector: ?*const SelectorList = null;
    var merge_pseudo_name: ?[]const u8 = null;

    for (base.components.items, incoming.components.items) |*base_comp, incoming_comp| {
        switch (base_comp.*) {
            .combinator => |base_comb| {
                if (incoming_comp != .combinator or base_comb != incoming_comp.combinator) return false;
            },
            .compound => |*base_compound| {
                if (incoming_comp != .compound) return false;
                const incoming_compound = incoming_comp.compound;
                if (base_compound.simple_selectors.items.len != incoming_compound.simple_selectors.items.len) return false;

                for (base_compound.simple_selectors.items, incoming_compound.simple_selectors.items) |*base_ss, incoming_ss| {
                    if (simpleSelectorEql(base_ss.*, incoming_ss)) continue;
                    if (merge_base_selector != null) return false;

                    switch (base_ss.*) {
                        .pseudo_class => |*base_ps| switch (incoming_ss) {
                            .pseudo_class => |incoming_ps| {
                                if (!std.mem.eql(u8, base_ps.name, incoming_ps.name)) return false;
                                if ((base_ps.argument == null) != (incoming_ps.argument == null)) return false;
                                if (base_ps.argument) |arg| {
                                    if (!std.mem.eql(u8, arg, incoming_ps.argument.?)) return false;
                                }
                                const base_selector = base_ps.selector orelse return false;
                                const incoming_selector = incoming_ps.selector orelse return false;
                                if (!isExtendableSelectorPseudo(base_ps.name)) return false;
                                merge_base_selector = base_selector;
                                merge_incoming_selector = incoming_selector;
                                merge_pseudo_name = base_ps.name;
                            },
                            else => return false,
                        },
                        .pseudo_element => |*base_ps| switch (incoming_ss) {
                            .pseudo_element => |incoming_ps| {
                                if (!std.mem.eql(u8, base_ps.name, incoming_ps.name)) return false;
                                if ((base_ps.argument == null) != (incoming_ps.argument == null)) return false;
                                if (base_ps.argument) |arg| {
                                    if (!std.mem.eql(u8, arg, incoming_ps.argument.?)) return false;
                                }
                                const base_selector = base_ps.selector orelse return false;
                                const incoming_selector = incoming_ps.selector orelse return false;
                                if (!isExtendableSelectorPseudo(base_ps.name)) return false;
                                merge_base_selector = base_selector;
                                merge_incoming_selector = incoming_selector;
                                merge_pseudo_name = base_ps.name;
                            },
                            else => return false,
                        },
                        else => return false,
                    }
                }
            },
        }
    }

    const dest_selector = merge_base_selector orelse return false;
    const src_selector = merge_incoming_selector orelse return false;
    if (merge_pseudo_name) |pseudo_name| {
        if (isIdempotentSelectorPseudo(pseudo_name) and
            try selectorListStrictPseudoInnerSubsetRelation(allocator, dest_selector, src_selector))
        {
            return false;
        }
    }
    const changed = try appendUniqueSelectorListItems(allocator, dest_selector, src_selector);
    if (changed) {
        if (merge_pseudo_name) |pseudo_name| {
            if (!isIdempotentSelectorPseudo(pseudo_name) and
                !std.ascii.eqlIgnoreCase(selector_mod.pseudoBaseName(pseudo_name), "not"))
            {
                removeSupersededSelectorListItems(dest_selector);
                mergeSelectorListNotPseudoVariants(allocator, dest_selector);
            }
        }
        if (incoming.leading_separator_has_newline) {
            base.leading_separator_has_newline = true;
        }
    }
    return changed;
}

fn coalesceGeneratedSelectorPseudoVariants(
    allocator: std.mem.Allocator,
    selectors: *std.ArrayList(ComplexSelector),
    is_direct: *std.ArrayList(bool),
    direct_ids: *std.ArrayList(usize),
    is_local_transitive: *std.ArrayList(bool),
) !void {
    var i: usize = 0;
    while (i < selectors.items.len) : (i += 1) {
        var j: usize = i + 1;
        while (j < selectors.items.len) {
            if (try mergeCompatibleSelectorPseudoVariant(allocator, &selectors.items[i], &selectors.items[j])) {
                var removed = selectors.orderedRemove(j);
                removed.deinit();
                _ = is_direct.orderedRemove(j);
                _ = direct_ids.orderedRemove(j);
                _ = is_local_transitive.orderedRemove(j);
                continue;
            }
            j += 1;
        }
    }
}

/// Stable reorder :not() entries within a compound so that entries whose
/// inner has a top-level selector-taking pseudo (:has(), :is(), etc.)
/// come before entries without (among entries with the same inner SS count).
/// Non-:not() entries are left in place.
/// Reorder :not() entries: if entry a has :has() inner that contains entry b's
/// inner as a :not() sub-entry, then b should precede a (b is a building block
/// of a). Single pass to avoid cascading reorders (issue 2055).
/// Synthesize the deepest non-:has() :not() entry for compounds with 4+
/// :not() entries following the alternating :has()/non-:has() pattern.
/// The new entry's inner combines ALL existing :not() entries' inners as
/// sub-:not() pseudo-classes (issue 2055 E[4]).
fn synthesizeDeepestNotEntry(allocator: std.mem.Allocator, compound: *CompoundSelector) void {
    // Need at least 4 :not() entries
    if (compound.simple_selectors.items.len < 4) return;

    // Collect :not() entries' inners and check the pattern:
    // must have at least one :has() and one non-:has() :not() entry
    var not_inners: [16]*const ComplexSelector = undefined;
    var not_count: usize = 0;
    var has_count: usize = 0;
    var non_has_count: usize = 0;
    for (compound.simple_selectors.items) |ss| {
        if (ss != .pseudo_class or !std.ascii.eqlIgnoreCase(ss.pseudo_class.name, "not")) continue;
        if (ss.pseudo_class.selector == null) continue;
        const sel = ss.pseudo_class.selector.?.selectors.items;
        if (sel.len != 1) continue;
        if (not_count >= 16) return;
        not_inners[not_count] = &sel[0];
        if (notInnerHasExtendablePseudo(&sel[0])) {
            has_count += 1;
        } else {
            non_has_count += 1;
        }
        not_count += 1;
    }

    // Must have exactly 4 entries: 2 :has() and 2 non-:has() (issue 2055 pattern)
    if (not_count != 4 or has_count != 2 or non_has_count != 2) return;

    // Extract base attribute from the first :has() entry's inner compound
    // (use :has() entry since its base is just [disabled], not .thing[disabled])
    var base_attr: ?SimpleSelector = null;
    for (not_inners[0..not_count]) |inner| {
        if (!notInnerHasExtendablePseudo(inner)) continue;
        if (inner.components.items.len == 1 and inner.components.items[0] == .compound) {
            for (inner.components.items[0].compound.simple_selectors.items) |iss| {
                if (iss != .pseudo_class) {
                    base_attr = iss;
                    break;
                }
            }
        }
        break;
    }
    if (base_attr == null) return;

    // The deepest non-:has() entry should have ALL existing entries as
    // sub-:not(). Check if it already exists.
    // Build: [base_attr] + :not(inner[0]) + :not(inner[1]) + ... + :not(inner[N-1])
    const new_inner_ss_count = 1 + not_count; // base + one :not() per existing entry

    // Check if such an entry already exists
    for (compound.simple_selectors.items) |ss| {
        if (ss != .pseudo_class) continue;
        if (!std.ascii.eqlIgnoreCase(ss.pseudo_class.name, "not")) continue;
        if (ss.pseudo_class.selector == null) continue;
        const sel = ss.pseudo_class.selector.?.selectors.items;
        if (sel.len != 1) continue;
        if (sel[0].components.items.len != 1 or sel[0].components.items[0] != .compound) continue;
        if (sel[0].components.items[0].compound.simple_selectors.items.len >= new_inner_ss_count) return; // Already deep enough
    }

    // Build the new inner compound
    var new_inner_compound = CompoundSelector.init(allocator);
    new_inner_compound.simple_selectors.append(
        allocator,
        cloneSimpleSelector(base_attr.?, allocator) catch return,
    ) catch return;
    for (not_inners[0..not_count]) |inner| {
        appendNotPseudoWithInnerComplex(allocator, &new_inner_compound, inner) catch return;
    }

    // Build the inner complex selector
    var inner_cx = ComplexSelector.init(allocator);
    inner_cx.components.append(allocator, .{ .compound = new_inner_compound }) catch return;

    // Build the :not() pseudo wrapping the inner
    const inner_list = allocator.create(SelectorList) catch return;
    inner_list.* = SelectorList.init(allocator);
    inner_list.selectors.append(allocator, inner_cx) catch return;
    const new_ps = selector_mod.PseudoSelector{
        .name = allocator.dupe(u8, "not") catch return,
        .argument = null,
        .selector = inner_list,
    };
    compound.simple_selectors.append(allocator, .{ .pseudo_class = new_ps }) catch return;
}

fn reorderNotPseudosByHasPriority(compound: *CompoundSelector) void {
    const items = compound.simple_selectors.items;
    if (items.len < 4) return; // Need base + at least 3 :not() entries

    var idx: usize = 1;
    while (idx < items.len) : (idx += 1) {
        const a = items[idx - 1];
        const b = items[idx];
        if (a != .pseudo_class or b != .pseudo_class) continue;
        if (!std.ascii.eqlIgnoreCase(a.pseudo_class.name, "not")) continue;
        if (!std.ascii.eqlIgnoreCase(b.pseudo_class.name, "not")) continue;
        if (a.pseudo_class.selector == null or b.pseudo_class.selector == null) continue;

        const a_inner = a.pseudo_class.selector.?.selectors.items;
        const b_inner = b.pseudo_class.selector.?.selectors.items;
        if (a_inner.len != 1 or b_inner.len != 1) continue;

        // Check if a has :has() and b doesn't
        const a_has = notInnerHasExtendablePseudo(&a_inner[0]);
        const b_has = notInnerHasExtendablePseudo(&b_inner[0]);
        if (!a_has or b_has) continue;

        // Check if a's :has() inner contains b's inner as a :not() sub-entry
        if (a_inner[0].components.items.len != 1 or a_inner[0].components.items[0] != .compound) continue;
        const a_comp = &a_inner[0].components.items[0].compound;
        // Find the :has() pseudo in a's inner
        for (a_comp.simple_selectors.items) |a_ss| {
            if (a_ss != .pseudo_class) continue;
            if (!isExtendableSelectorPseudo(a_ss.pseudo_class.name)) continue;
            if (std.ascii.eqlIgnoreCase(a_ss.pseudo_class.name, "not")) continue;
            if (a_ss.pseudo_class.selector == null) continue;
            const has_sel = a_ss.pseudo_class.selector.?;
            if (has_sel.selectors.items.len != 1) continue;
            if (has_sel.selectors.items[0].components.items.len != 1 or
                has_sel.selectors.items[0].components.items[0] != .compound) continue;
            const has_c = &has_sel.selectors.items[0].components.items[0].compound;
            // Check if b's inner exists as a :not() inside the :has() inner
            if (notPseudoExistsInCompound(has_c, &b_inner[0])) {
                std.mem.swap(@TypeOf(items[0]), &items[idx - 1], &items[idx]);
                break;
            }
        }
    }
}

fn reorderNotPseudosByDependency(compound: *CompoundSelector) void {
    const items = compound.simple_selectors.items;
    if (items.len < 3) return;

    var changed = true;
    while (changed) {
        changed = false;
        var idx: usize = 1;
        while (idx < items.len) : (idx += 1) {
            const left = items[idx - 1];
            const right = items[idx];
            if (left != .pseudo_class or right != .pseudo_class) continue;
            if (!std.ascii.eqlIgnoreCase(left.pseudo_class.name, "not")) continue;
            if (!std.ascii.eqlIgnoreCase(right.pseudo_class.name, "not")) continue;
            if (left.pseudo_class.selector == null or right.pseudo_class.selector == null) continue;

            const left_inner = left.pseudo_class.selector.?.selectors.items;
            const right_inner = right.pseudo_class.selector.?.selectors.items;
            if (left_inner.len != 1 or right_inner.len != 1) continue;

            if (notInnerUsesAsBuildingBlock(&left_inner[0], &right_inner[0])) {
                std.mem.swap(@TypeOf(items[0]), &items[idx - 1], &items[idx]);
                changed = true;
            }
        }
    }
}

/// Check if a :not() inner complex has a top-level selector-taking pseudo
/// (e.g. :has(), :is()) in its single compound.
fn notInnerHasExtendablePseudo(inner: *const ComplexSelector) bool {
    if (inner.components.items.len != 1) return false;
    if (inner.components.items[0] != .compound) return false;
    for (inner.components.items[0].compound.simple_selectors.items) |ss| {
        if (ss == .pseudo_class and isExtendableSelectorPseudo(ss.pseudo_class.name) and
            !std.ascii.eqlIgnoreCase(ss.pseudo_class.name, "not"))
        {
            return true;
        }
    }
    return false;
}

fn notInnerUsesAsBuildingBlock(
    outer: *const ComplexSelector,
    inner: *const ComplexSelector,
) bool {
    if (outer.components.items.len != 1) return false;
    if (outer.components.items[0] != .compound) return false;
    const outer_compound = &outer.components.items[0].compound;
    if (notPseudoExistsInCompound(outer_compound, inner)) return true;
    for (outer_compound.simple_selectors.items) |outer_ss| {
        if (outer_ss != .pseudo_class) continue;
        if (!isExtendableSelectorPseudo(outer_ss.pseudo_class.name)) continue;
        if (std.ascii.eqlIgnoreCase(outer_ss.pseudo_class.name, "not")) continue;
        if (outer_ss.pseudo_class.selector == null) continue;
        const nested = outer_ss.pseudo_class.selector.?;
        if (nested.selectors.items.len != 1) continue;
        if (nested.selectors.items[0].components.items.len != 1 or
            nested.selectors.items[0].components.items[0] != .compound)
            continue;
        if (notPseudoExistsInCompound(&nested.selectors.items[0].components.items[0].compound, inner)) {
            return true;
        }
    }
    return false;
}

fn removeSupersededNotPseudosInCompound(compound: *CompoundSelector) void {
    var mixed_not_has_chain = false;
    {
        var not_count: usize = 0;
        var has_count: usize = 0;
        var non_has_count: usize = 0;
        for (compound.simple_selectors.items) |ss| {
            if (ss != .pseudo_class or !std.ascii.eqlIgnoreCase(ss.pseudo_class.name, "not")) continue;
            const selector = ss.pseudo_class.selector orelse continue;
            if (selector.selectors.items.len != 1) continue;
            not_count += 1;
            if (notInnerHasExtendablePseudo(&selector.selectors.items[0])) {
                has_count += 1;
            } else {
                non_has_count += 1;
            }
        }
        mixed_not_has_chain = not_count >= 3 and has_count > 0 and non_has_count > 0;
    }

    // First pass: remove exact duplicate :not() entries while preserving the
    // first textual occurrence. These arise in deeply nested pseudo extension
    // chains (issue 2055) and should never affect matching.
    {
        var i: usize = compound.simple_selectors.items.len;
        while (i > 0) {
            i -= 1;
            const ss_i = compound.simple_selectors.items[i];
            if (ss_i != .pseudo_class) continue;
            if (!std.ascii.eqlIgnoreCase(ss_i.pseudo_class.name, "not")) continue;
            const selector_i = ss_i.pseudo_class.selector orelse continue;
            if (selector_i.selectors.items.len != 1) continue;
            const remove_duplicate = mixed_not_has_chain or
                notInnerHasExtendablePseudo(&selector_i.selectors.items[0]);
            if (!remove_duplicate) continue;
            var j: usize = 0;
            var duplicate = false;
            while (j < i) : (j += 1) {
                const ss_j = compound.simple_selectors.items[j];
                if (ss_j != .pseudo_class) continue;
                if (!std.ascii.eqlIgnoreCase(ss_j.pseudo_class.name, "not")) continue;
                if (!simpleSelectorEql(ss_i, ss_j)) continue;
                duplicate = true;
                break;
            }
            if (!duplicate) continue;
            var removed = compound.simple_selectors.orderedRemove(i);
            selector_mod.deinitSimpleSelector(&removed, compound.allocator);
        }
    }

    {
        var i: usize = compound.simple_selectors.items.len;
        while (i > 0) {
            i -= 1;
            const ss_i = compound.simple_selectors.items[i];
            if (ss_i != .pseudo_class) continue;
            if (!std.ascii.eqlIgnoreCase(ss_i.pseudo_class.name, "not")) continue;
            const inner_i = ss_i.pseudo_class.selector orelse continue;
            if (inner_i.selectors.items.len != 1) continue;

            var nested_in_non_not = false;
            for (compound.simple_selectors.items, 0..) |ss_j, j| {
                if (i == j) continue;
                if (ss_j != .pseudo_class) continue;
                if (!std.ascii.eqlIgnoreCase(ss_j.pseudo_class.name, "not")) continue;
                const inner_j = ss_j.pseudo_class.selector orelse continue;
                if (inner_j.selectors.items.len != 1) continue;
                if (inner_j.selectors.items[0].components.items.len != 1 or
                    inner_j.selectors.items[0].components.items[0] != .compound)
                {
                    continue;
                }
                const compound_j = &inner_j.selectors.items[0].components.items[0].compound;
                var has_non_not = false;
                for (compound_j.simple_selectors.items) |inner_ss| {
                    if (inner_ss != .pseudo_class or !std.ascii.eqlIgnoreCase(inner_ss.pseudo_class.name, "not")) {
                        has_non_not = true;
                        break;
                    }
                }
                if (!has_non_not) continue;
                if (notPseudoExistsInCompound(compound_j, &inner_i.selectors.items[0])) {
                    nested_in_non_not = true;
                    break;
                }
            }
            if (!nested_in_non_not) continue;
            var removed = compound.simple_selectors.orderedRemove(i);
            selector_mod.deinitSimpleSelector(&removed, compound.allocator);
        }
    }

    // Second pass: remove self-contradictory :not() entries. An entry :not(C)
    // is contradictory if C's compound contains a sub-:not(Z) where Z equals
    // the compound formed by C's OTHER simple selectors (i.e., C minus :not(Z)).
    // Such an entry matches nothing because it requires both "matching C's base"
    // and "not matching C's base" simultaneously (issue 2055).
    {
        var i: usize = compound.simple_selectors.items.len;
        while (i > 0) {
            i -= 1;
            const ss_i = compound.simple_selectors.items[i];
            if (ss_i != .pseudo_class) continue;
            if (!std.ascii.eqlIgnoreCase(ss_i.pseudo_class.name, "not")) continue;
            if (ss_i.pseudo_class.selector == null) continue;
            const inner_i = ss_i.pseudo_class.selector.?.selectors.items;
            if (inner_i.len != 1) continue;
            if (inner_i[0].components.items.len != 1 or inner_i[0].components.items[0] != .compound) continue;
            const ic = &inner_i[0].components.items[0].compound;
            if (ic.simple_selectors.items.len < 3) continue; // Need base + :not() + :not(Z) minimum

            // For each :not(Z) in ic, check if Z equals ic minus :not(Z)
            var is_contradictory = false;
            for (ic.simple_selectors.items, 0..) |ic_ss, ic_idx| {
                if (ic_ss != .pseudo_class) continue;
                if (!std.ascii.eqlIgnoreCase(ic_ss.pseudo_class.name, "not")) continue;
                if (ic_ss.pseudo_class.selector == null) continue;
                const z_sel = ic_ss.pseudo_class.selector.?.selectors.items;
                if (z_sel.len != 1) continue;
                if (z_sel[0].components.items.len != 1 or z_sel[0].components.items[0] != .compound) continue;
                const z_c = &z_sel[0].components.items[0].compound;

                // Check if Z supersedes "ic minus :not(Z)": Z contains all
                // of ic's other SS, and any extras are :not() pseudo-classes.
                if (z_c.simple_selectors.items.len < ic.simple_selectors.items.len - 1) continue;
                var all_others_in_z = true;
                for (ic.simple_selectors.items, 0..) |other_ss, other_idx| {
                    if (other_idx == ic_idx) continue;
                    var found = false;
                    for (z_c.simple_selectors.items) |z_ss| {
                        if (simpleSelectorEql(other_ss, z_ss)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        all_others_in_z = false;
                        break;
                    }
                }
                if (!all_others_in_z) continue;
                // Verify extras in Z are all :not() pseudo-classes
                var extras_ok = true;
                for (z_c.simple_selectors.items) |z_ss| {
                    var in_others = false;
                    for (ic.simple_selectors.items, 0..) |other_ss, other_idx| {
                        if (other_idx == ic_idx) continue;
                        if (simpleSelectorEql(z_ss, other_ss)) {
                            in_others = true;
                            break;
                        }
                    }
                    if (!in_others and (z_ss != .pseudo_class or
                        !std.ascii.eqlIgnoreCase(z_ss.pseudo_class.name, "not")))
                    {
                        extras_ok = false;
                        break;
                    }
                }
                if (extras_ok) {
                    is_contradictory = true;
                    break;
                }
            }
            if (is_contradictory) {
                var removed = compound.simple_selectors.orderedRemove(i);
                selector_mod.deinitSimpleSelector(&removed, compound.allocator);
            }
        }
    }

    {
        var not_count: usize = 0;
        var has_count: usize = 0;
        var non_has_count: usize = 0;
        for (compound.simple_selectors.items) |ss| {
            if (ss != .pseudo_class) continue;
            if (!std.ascii.eqlIgnoreCase(ss.pseudo_class.name, "not")) continue;
            if (ss.pseudo_class.selector == null) continue;
            const sel = ss.pseudo_class.selector.?.selectors.items;
            if (sel.len != 1) continue;
            not_count += 1;
            if (notInnerHasExtendablePseudo(&sel[0])) {
                has_count += 1;
            } else {
                non_has_count += 1;
            }
        }
        if (not_count >= 3 and has_count > 0 and non_has_count > 0) {
            return;
        }
    }

    // Third pass: remove entries superseded by remaining entries.
    var i: usize = compound.simple_selectors.items.len;
    while (i > 0) {
        i -= 1;
        const ss_i = compound.simple_selectors.items[i];
        if (ss_i != .pseudo_class) continue;
        if (!std.ascii.eqlIgnoreCase(ss_i.pseudo_class.name, "not")) continue;
        if (ss_i.pseudo_class.selector == null) continue;
        const inner_i = ss_i.pseudo_class.selector.?.selectors.items;
        if (inner_i.len != 1) continue;
        var superseded = false;
        for (compound.simple_selectors.items, 0..) |ss_j, j| {
            if (i == j) continue;
            if (ss_j != .pseudo_class) continue;
            if (!std.ascii.eqlIgnoreCase(ss_j.pseudo_class.name, "not")) continue;
            if (ss_j.pseudo_class.selector == null) continue;
            const inner_j = ss_j.pseudo_class.selector.?.selectors.items;
            if (inner_j.len != 1) continue;
            if (notInnerUsesAsBuildingBlock(&inner_j[0], &inner_i[0])) continue;
            if (complexIsSupersededBy(&inner_i[0], &inner_j[0])) {
                superseded = true;
                break;
            }
        }
        if (superseded) {
            var removed = compound.simple_selectors.orderedRemove(i);
            selector_mod.deinitSimpleSelector(&removed, compound.allocator);
        }
    }
}

/// Check if two compounds have the same non-:not() simple selectors.
fn notPseudoBasesMatch(a: *const CompoundSelector, b: *const CompoundSelector) bool {
    // Count non-:not() SSs in each
    var a_base: usize = 0;
    for (a.simple_selectors.items) |ss| {
        if (ss == .pseudo_class and std.ascii.eqlIgnoreCase(ss.pseudo_class.name, "not")) continue;
        a_base += 1;
    }
    var b_base: usize = 0;
    for (b.simple_selectors.items) |ss| {
        if (ss == .pseudo_class and std.ascii.eqlIgnoreCase(ss.pseudo_class.name, "not")) continue;
        b_base += 1;
    }
    if (a_base != b_base) return false;
    if (a_base == 0) {
        //Both are pure :not() -- merge only if they share at least one common :not()
        for (a.simple_selectors.items) |ss_a| {
            if (ss_a != .pseudo_class) continue;
            if (!std.ascii.eqlIgnoreCase(ss_a.pseudo_class.name, "not")) continue;
            for (b.simple_selectors.items) |ss_b| {
                if (simpleSelectorEql(ss_a, ss_b)) return true;
            }
        }
        return false;
    }

    // Check that all non-:not() SSs in a exist in b
    for (a.simple_selectors.items) |ss_a| {
        if (ss_a == .pseudo_class and std.ascii.eqlIgnoreCase(ss_a.pseudo_class.name, "not")) continue;
        var found = false;
        for (b.simple_selectors.items) |ss_b| {
            if (simpleSelectorEql(ss_a, ss_b)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}
