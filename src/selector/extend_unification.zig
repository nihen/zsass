const std = @import("std");
const selector_mod = @import("selector.zig");
const ComplexSelector = selector_mod.ComplexSelector;
const ComplexSelectorComponent = selector_mod.ComplexSelectorComponent;
const CompoundSelector = selector_mod.CompoundSelector;
const SimpleSelector = selector_mod.SimpleSelector;
const Combinator = selector_mod.Combinator;
const specificity = @import("extend_specificity.zig");
const getLastCompound = specificity.getLastCompound;
const compoundContainsTarget = specificity.compoundContainsTarget;
const cloneSimpleSelector = selector_mod.cloneSimpleSelector;
const simpleSelectorEql = specificity.simpleSelectorEql;
const compoundSelectorEql = specificity.compoundSelectorEql;
const complexSelectorEql = specificity.complexSelectorEql;
const complexIsBroaderThan = specificity.complexIsBroaderThan;
const complexIsSupersededBy = specificity.complexIsSupersededBy;
const complexSpecificity = specificity.complexSpecificity;
const specificityGte = specificity.specificityGte;
const narrowerHasWhitelistedLastCompoundPseudoExtras = specificity.narrowerHasWhitelistedLastCompoundPseudoExtras;
const narrowerKeepsFinalTrimStatefulExtras = specificity.narrowerKeepsFinalTrimStatefulExtras;
const complexHasSiblingCombinator = specificity.complexHasSiblingCombinator;

// ============================================================================
// Selector unification, weaving, and trimming
// ============================================================================

fn css2PseudoElementName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "before") or
        std.ascii.eqlIgnoreCase(name, "after") or
        std.ascii.eqlIgnoreCase(name, "first-line") or
        std.ascii.eqlIgnoreCase(name, "first-letter");
}

const UnifyTypeInfo = struct {
    ns: ?[]const u8,
    name: []const u8,
    is_universal_tag: bool,
};

fn unifyScanTypeInfo(simple_selectors: []const SimpleSelector, target: ?*const CompoundSelector) ?UnifyTypeInfo {
    var ti: ?UnifyTypeInfo = null;
    for (simple_selectors) |ss| {
        if (target) |t| {
            if (isInTarget(ss, t)) continue;
        }
        switch (ss) {
            .universal => {
                ti = .{ .ns = null, .name = "*", .is_universal_tag = true };
            },
            .type_selector => |n| {
                if (std.mem.find(u8, n, "|")) |pipe_pos| {
                    ti = .{ .ns = n[0..pipe_pos], .name = n[pipe_pos + 1 ..], .is_universal_tag = false };
                } else {
                    ti = .{ .ns = null, .name = n, .is_universal_tag = false };
                }
            },
            else => {},
        }
    }
    return ti;
}

/// Returns `null` when `oti` and `eti` cannot be unified (conflicting type selectors).
fn unifyMergeTypeSelectorsOrNull(oti: UnifyTypeInfo, eti: UnifyTypeInfo) ?UnifyTypeInfo {
    const o_is_univ_name = std.mem.eql(u8, oti.name, "*");
    const e_is_univ_name = std.mem.eql(u8, eti.name, "*");
    // SAFETY: initialized before first read in this scope.
    var unified_name: []const u8 = undefined;
    if (o_is_univ_name and e_is_univ_name) {
        unified_name = "*";
    } else if (o_is_univ_name) {
        unified_name = eti.name;
    } else if (e_is_univ_name) {
        unified_name = oti.name;
    } else {
        if (!std.mem.eql(u8, oti.name, eti.name)) {
            return null;
        }
        unified_name = oti.name;
    }
    var unified_ns: ?[]const u8 = null;
    if (oti.ns == null and eti.ns == null) {
        unified_ns = null;
    } else if (oti.ns != null and eti.ns != null) {
        const ons = oti.ns.?;
        const ens = eti.ns.?;
        if (std.mem.eql(u8, ons, "*")) {
            unified_ns = ens;
        } else if (std.mem.eql(u8, ens, "*")) {
            unified_ns = ons;
        } else if (std.mem.eql(u8, ons, ens)) {
            unified_ns = ons;
        } else {
            return null;
        }
    } else {
        const explicit_ns = (oti.ns orelse eti.ns).?;
        if (std.mem.eql(u8, explicit_ns, "*")) {
            unified_ns = null;
        } else {
            return null;
        }
    }
    return .{
        .ns = unified_ns,
        .name = unified_name,
        .is_universal_tag = oti.is_universal_tag and eti.is_universal_tag and
            std.mem.eql(u8, unified_name, "*") and unified_ns == null,
    };
}

fn unifyExtractLastId(simple_selectors: []const SimpleSelector, target: ?*const CompoundSelector) ?[]const u8 {
    var id: ?[]const u8 = null;
    for (simple_selectors) |ss| {
        if (target) |t| {
            if (isInTarget(ss, t)) continue;
        }
        if (ss == .id) id = ss.id;
    }
    return id;
}

fn unifyExtractPseudoElementLikeLast(simple_selectors: []const SimpleSelector, target: ?*const CompoundSelector) ?[]const u8 {
    var pe: ?[]const u8 = null;
    for (simple_selectors) |ss| {
        if (target) |t| {
            if (isInTarget(ss, t)) continue;
        }
        switch (ss) {
            .pseudo_element => |ps| pe = ps.name,
            .pseudo_class => |ps| {
                if (css2PseudoElementName(ps.name)) pe = ps.name;
            },
            else => {},
        }
    }
    return pe;
}

fn unifyCompoundHasNonTypeSimples(original: *const CompoundSelector, target: *const CompoundSelector, extender: *const CompoundSelector) bool {
    for (extender.simple_selectors.items) |ss| {
        switch (ss) {
            .type_selector, .universal => {},
            else => return true,
        }
    }
    for (original.simple_selectors.items) |ss| {
        if (isInTarget(ss, target)) continue;
        switch (ss) {
            .type_selector, .universal => {},
            else => return true,
        }
    }
    return false;
}

fn unifyAppendResolvedType(
    allocator: std.mem.Allocator,
    result: *CompoundSelector,
    ti: UnifyTypeInfo,
    has_other_selectors: bool,
    drop_redundant_universal: bool,
) !void {
    const name_is_star = std.mem.eql(u8, ti.name, "*");
    const is_any_universal = name_is_star and
        (ti.ns == null or (ti.ns != null and std.mem.eql(u8, ti.ns.?, "*")));
    if (is_any_universal) {
        if (!has_other_selectors or (ti.is_universal_tag and !drop_redundant_universal and ti.ns != null and !std.mem.eql(u8, ti.ns.?, "*"))) {
            if (ti.ns != null and std.mem.eql(u8, ti.ns.?, "*")) {
                const type_str = try unifyBuildTypeStr(allocator, ti.ns, ti.name);
                try result.simple_selectors.append(allocator, .{ .type_selector = type_str });
            } else {
                try result.simple_selectors.append(allocator, .universal);
            }
        }
    } else {
        const type_str = try unifyBuildTypeStr(allocator, ti.ns, ti.name);
        try result.simple_selectors.append(allocator, .{ .type_selector = type_str });
    }
}

pub fn unifyCompound(
    allocator: std.mem.Allocator,
    original: *const CompoundSelector,
    target: *const CompoundSelector,
    extender: *const CompoundSelector,
) !?CompoundSelector {
    var result = CompoundSelector.init(allocator);
    errdefer result.deinit();

    const original_ti = unifyScanTypeInfo(original.simple_selectors.items, target);
    const extender_ti = unifyScanTypeInfo(extender.simple_selectors.items, null);

    var unified_ti: ?UnifyTypeInfo = null;
    if (original_ti != null and extender_ti != null) {
        if (unifyMergeTypeSelectorsOrNull(original_ti.?, extender_ti.?)) |u| {
            unified_ti = u;
        } else {
            result.deinit();
            return null;
        }
    } else if (original_ti != null) {
        unified_ti = original_ti;
    } else if (extender_ti != null) {
        unified_ti = extender_ti;
    }

    const original_id = unifyExtractLastId(original.simple_selectors.items, target);
    const extender_id = unifyExtractLastId(extender.simple_selectors.items, null);
    if (original_id != null and extender_id != null) {
        if (!std.mem.eql(u8, original_id.?, extender_id.?)) {
            result.deinit();
            return null;
        }
    }

    const original_pseudo_elem = unifyExtractPseudoElementLikeLast(original.simple_selectors.items, target);
    const extender_pseudo_elem = unifyExtractPseudoElementLikeLast(extender.simple_selectors.items, null);
    if (original_pseudo_elem != null and extender_pseudo_elem != null) {
        if (!std.ascii.eqlIgnoreCase(original_pseudo_elem.?, extender_pseudo_elem.?)) {
            result.deinit();
            return null;
        }
    }

    const has_other_selectors = unifyCompoundHasNonTypeSimples(original, target, extender);

    if (unified_ti) |ti| {
        try unifyAppendResolvedType(allocator, &result, ti, has_other_selectors, original_pseudo_elem != null);
    }

    // 2. Original's non-target, non-type simple selectors (maintaining order)
    // Also collect them for dedup checking in step 3.
    var orig_non_target_ss: [64]SimpleSelector = undefined;
    var orig_non_target_count: usize = 0;
    for (original.simple_selectors.items) |ss| {
        if (isInTarget(ss, target)) continue;
        switch (ss) {
            .type_selector, .universal => continue,
            else => {},
        }
        try result.simple_selectors.append(allocator, try cloneSimpleSelector(ss, allocator));
        if (orig_non_target_count < 64) {
            orig_non_target_ss[orig_non_target_count] = ss;
            orig_non_target_count += 1;
        }
    }

    // 3. Extender's non-type simple selectors merged at correct positions.
    // Only dedup against original's non-target selectors (not against previously
    // added extender selectors) to preserve intentional duplicates like .foo.foo.
    //
    // When the original compound contributes NOTHING besides the target (i.e.
    // `%p` extended by `input:not([type]):not(.native).valid` where
    // source is just `%p`), emit the extender's simple selectors verbatim to
    // preserve source-order output. When the original contributes a
    // type selector or other simples, unify by kind-order so the final compound
    //follows the canonical order (type  ->  class/id/attr  ->  pseudo-class  ->
    //pseudo-element) -- e.g. `input.err` extended by `input:hover.err` yields
    // `input.err:hover`, not `input:hover.err`.
    const original_contributes_non_target =
        original_ti != null or orig_non_target_count > 0;
    for (extender.simple_selectors.items) |ss| {
        switch (ss) {
            .type_selector, .universal => continue,
            else => {},
        }
        if (unifyIsDup(ss, orig_non_target_ss[0..orig_non_target_count])) continue;
        if (original_contributes_non_target) {
            const insert_pos = unifyInsertPos(ss, result.simple_selectors.items, css2PseudoElementName);
            try result.simple_selectors.insert(allocator, insert_pos, try cloneSimpleSelector(ss, allocator));
        } else {
            try result.simple_selectors.append(allocator, try cloneSimpleSelector(ss, allocator));
        }
    }

    if (result.simple_selectors.items.len == 0) {
        result.deinit();
        return null;
    }

    return result;
}

fn unifyInsertPos(ss: SimpleSelector, items: []const SimpleSelector, isCss2PE: fn ([]const u8) bool) usize {
    const ss_kind = unifyOrderKind(ss, isCss2PE);
    if (ss_kind <= 1) {
        // Class/id/attribute selectors added by @extend are merged into the
        // pre-pseudo portion of the compound. Do not jump over an existing
        // stateful pseudo chain just because the original selector has another
        // class later (for example `:not(...).hover`).
        for (items, 0..) |item, idx| {
            if (unifyOrderKind(item, isCss2PE) > 1) return idx;
        }
        return items.len;
    }
    var i: usize = items.len;
    while (i > 0) {
        if (unifyOrderKind(items[i - 1], isCss2PE) <= ss_kind) return i;
        i -= 1;
    }
    return 0;
}

fn unifyOrderKind(ss: SimpleSelector, isCss2PE: fn ([]const u8) bool) u8 {
    return switch (ss) {
        .type_selector, .universal => 0,
        .class, .id, .attribute, .placeholder, .parent => 1,
        .pseudo_class => |ps| if (isCss2PE(ps.name)) @as(u8, 3) else if (ps.argument != null or ps.selector != null) @as(u8, 4) else 2,
        .pseudo_element => 5,
    };
}

fn unifyBuildTypeStr(allocator: std.mem.Allocator, ns: ?[]const u8, name: []const u8) ![]const u8 {
    if (ns) |namespace| {
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(allocator, namespace);
        try buf.append(allocator, '|');
        try buf.appendSlice(allocator, name);
        return try buf.toOwnedSlice(allocator);
    }
    return try allocator.dupe(u8, name);
}

fn unifyIsDup(ss: SimpleSelector, existing: []const SimpleSelector) bool {
    for (existing) |e| {
        if (simpleSelectorEql(ss, e)) return true;
    }
    return false;
}

fn isInTarget(ss: SimpleSelector, target: *const CompoundSelector) bool {
    for (target.simple_selectors.items) |target_ss| {
        if (simpleSelectorEql(ss, target_ss)) return true;
    }
    return false;
}

// ============================================================================
//weavePaths -- high-level combinator interaction
// ============================================================================

/// Weave two prefix paths, each with a trailing combinator to the target.
/// Returns a list of possible weavings, each ending with the appropriate combinator(s).
pub fn weavePaths(
    allocator: std.mem.Allocator,
    orig_base: []const ComplexSelectorComponent,
    orig_comb: Combinator,
    ext_base: []const ComplexSelectorComponent,
    ext_comb: Combinator,
) std.mem.Allocator.Error!std.ArrayList(ComplexSelector) {
    var results: std.ArrayList(ComplexSelector) = .empty;
    errdefer {
        for (results.items) |*r| r.deinit();
        results.deinit(allocator);
    }

    // Case 1: Both descendant
    if (orig_comb == .descendant and ext_comb == .descendant) {
        if (orig_base.len == 0 and ext_base.len == 0) {
            var sel = ComplexSelector.init(allocator);
            try results.append(allocator, sel);
            _ = &sel;
            return results;
        }
        if (orig_base.len == 0) {
            var sel = ComplexSelector.init(allocator);
            errdefer sel.deinit();
            try cloneComponents(allocator, &sel, ext_base);
            try sel.components.append(allocator, .{ .combinator = .descendant });
            try results.append(allocator, sel);
            return results;
        }
        if (ext_base.len == 0) {
            var sel = ComplexSelector.init(allocator);
            errdefer sel.deinit();
            try cloneComponents(allocator, &sel, orig_base);
            try sel.components.append(allocator, .{ .combinator = .descendant });
            try results.append(allocator, sel);
            return results;
        }
        var woven = try weave(allocator, orig_base, ext_base);
        defer {
            for (woven.items) |*w| w.deinit();
            woven.deinit(allocator);
        }
        if (woven.items.len == 0) return results;
        try results.ensureUnusedCapacity(allocator, woven.items.len);
        for (woven.items) |*w| {
            var sel = try w.clone(allocator);
            errdefer sel.deinit();
            if (sel.components.items.len > 0 and sel.components.items[sel.components.items.len - 1] == .compound) {
                try sel.components.append(allocator, .{ .combinator = .descendant });
            }
            try results.append(allocator, sel);
        }
        return results;
    }

    // Case 2: One descendant, one non-descendant
    if (orig_comb == .descendant or ext_comb == .descendant) {
        const nonDesc_base = if (orig_comb != .descendant) orig_base else ext_base;
        const nonDesc_comb = if (orig_comb != .descendant) orig_comb else ext_comb;
        const desc_base = if (orig_comb == .descendant) orig_base else ext_base;

        if (nonDesc_base.len == 0 and desc_base.len == 0) {
            var sel = ComplexSelector.init(allocator);
            try sel.components.append(allocator, .{ .combinator = nonDesc_comb });
            try results.append(allocator, sel);
            return results;
        }

        if (desc_base.len == 0) {
            var sel = ComplexSelector.init(allocator);
            errdefer sel.deinit();
            try cloneComponents(allocator, &sel, nonDesc_base);
            if (sel.components.items.len > 0 and sel.components.items[sel.components.items.len - 1] == .compound) {
                try sel.components.append(allocator, .{ .combinator = nonDesc_comb });
            }
            try results.append(allocator, sel);
            return results;
        }

        if (nonDesc_base.len == 0) {
            var sel = ComplexSelector.init(allocator);
            errdefer sel.deinit();
            try cloneComponents(allocator, &sel, desc_base);
            if (sel.components.items.len > 0 and sel.components.items[sel.components.items.len - 1] == .compound) {
                try sel.components.append(allocator, .{ .combinator = nonDesc_comb });
            }
            try results.append(allocator, sel);
            return results;
        }

        // For child combinator (>): check if desc_base's last compound is a superselector
        // of nonDesc_base's last compound. If so, absorption is valid because the nonDesc
        //compound is the PARENT of the target -- it satisfies the ancestor requirement.
        //e.g., desc_base=[.a], nonDesc_base=[.a.b], comb=child  ->  .a.b > y (not .a .a.b > y)
        // This does NOT apply to sibling combinators (+, ~) because the nonDesc compound
        //is a sibling, not an ancestor -- the desc ancestor is a separate element.
        if (nonDesc_comb == .child) {
            const desc_last_c = getLastCompoundFromSlice(desc_base);
            const nonDesc_last_c = getLastCompoundFromSlice(nonDesc_base);
            if (desc_last_c != null and nonDesc_last_c != null and
                compoundContainsTarget(nonDesc_last_c.?, desc_last_c.?))
            {
                const desc_rest = getSliceBeforeLastCompound(desc_base);
                if (desc_rest.len == 0) {
                    // Simple absorption: desc_base is single compound, fully contained in nonDesc
                    var sel = ComplexSelector.init(allocator);
                    errdefer sel.deinit();
                    try cloneComponents(allocator, &sel, nonDesc_base);
                    if (sel.components.items.len > 0 and sel.components.items[sel.components.items.len - 1] == .compound) {
                        try sel.components.append(allocator, .{ .combinator = nonDesc_comb });
                    }
                    try results.append(allocator, sel);
                    return results;
                }
                if (componentsHasPrefix(nonDesc_base, desc_rest)) {
                    var sel = ComplexSelector.init(allocator);
                    errdefer sel.deinit();
                    try cloneComponents(allocator, &sel, nonDesc_base);
                    if (sel.components.items.len > 0 and sel.components.items[sel.components.items.len - 1] == .compound) {
                        try sel.components.append(allocator, .{ .combinator = nonDesc_comb });
                    }
                    try results.append(allocator, sel);
                    return results;
                }
            }
        }

        // Check if desc_base's last compound appears in nonDesc_base, enabling
        //common ancestor dedup. e.g., desc=[.foo], nonDesc=[.foo .bip]  ->  [.foo .bip]
        if (nonDesc_comb == .child) {
            const desc_last_c = getLastCompoundFromSlice(desc_base);
            if (desc_last_c != null) {
                // Check if desc_last appears as first compound in nonDesc_base
                const nonDesc_first_c = blk: {
                    for (nonDesc_base) |*c| {
                        if (c.* == .compound) break :blk &c.compound;
                    }
                    break :blk @as(?*const CompoundSelector, null);
                };
                if (nonDesc_first_c != null and compoundSelectorEql(desc_last_c.?, nonDesc_first_c.?)) {
                    const desc_rest = getSliceBeforeLastCompound(desc_base);
                    if (desc_rest.len == 0) {
                        //desc_base is single compound matching nonDesc_base's first compound  ->  absorb
                        var sel = ComplexSelector.init(allocator);
                        errdefer sel.deinit();
                        try cloneComponents(allocator, &sel, nonDesc_base);
                        if (sel.components.items.len > 0 and sel.components.items[sel.components.items.len - 1] == .compound) {
                            try sel.components.append(allocator, .{ .combinator = nonDesc_comb });
                        }
                        try results.append(allocator, sel);
                        return results;
                    }
                }
            }
        }

        // Child combinator (>): when the non-descendant base has an
        // ancestor segment before its direct-parent compound, weave that
        // ancestor segment with the descendant extender base. Both possible
        // ancestor orders must be preserved.
        if (nonDesc_comb == .child) {
            const non_desc_last = getLastCompoundFromSlice(nonDesc_base);
            const non_desc_rest = getSliceBeforeLastCompound(nonDesc_base);
            if (non_desc_last != null and non_desc_rest.len > 0) {
                const comb_before_non_desc_last = getCombinatorBeforeLastCompound(nonDesc_base);
                // Only descendant-separated ancestor chains can accept the
                // extender base in multiple positions. If the direct parent
                // is itself constrained by `>` (e.g. `.outer > .floating >`),
                // inserting an unrelated ancestor before that parent would
                // imply a different DOM shape than Sass permits.
                if (comb_before_non_desc_last == .descendant) {
                    var woven_prefixes = try weave(allocator, non_desc_rest, desc_base);
                    defer {
                        for (woven_prefixes.items) |*w| w.deinit();
                        woven_prefixes.deinit(allocator);
                    }
                    if (woven_prefixes.items.len > 0) {
                        try results.ensureUnusedCapacity(allocator, woven_prefixes.items.len);
                        for (woven_prefixes.items) |*w| {
                            var sel = try w.clone(allocator);
                            errdefer sel.deinit();
                            if (comb_before_non_desc_last == .descendant) {
                                try appendDescIfNeeded(allocator, &sel);
                            } else if (sel.components.items.len > 0 and sel.components.items[sel.components.items.len - 1] == .compound) {
                                try sel.components.append(allocator, .{ .combinator = comb_before_non_desc_last });
                            }
                            try sel.components.append(allocator, .{ .compound = try non_desc_last.?.clone(allocator) });
                            try sel.components.append(allocator, .{ .combinator = nonDesc_comb });
                            try results.append(allocator, sel);
                        }
                        return results;
                    }
                }
            }
        }

        // Sibling combinator (+ / ~): when the non-descendant base has an
        // ancestor segment before its last sibling compound, weave that
        // segment with the descendant base to preserve both valid orderings.
        // e.g. nonDesc=`.a .b` +, desc=`.c` ->
        // `.a .c .b + target` and `.c .a .b + target`.
        sibling_weave: {
            if (!(nonDesc_comb == .next_sibling or nonDesc_comb == .general_sibling)) break :sibling_weave;
            const non_desc_last = getLastCompoundFromSlice(nonDesc_base);
            const non_desc_rest = getSliceBeforeLastCompound(nonDesc_base);
            if (non_desc_last != null and non_desc_rest.len > 0) {
                const comb_before_non_desc_last = getCombinatorBeforeLastCompound(nonDesc_base);
                // Only descendant-separated ancestor chains can accept the
                // extender base in multiple positions. If the sibling itself
                // is constrained by `>` (for example `.card-group > .card +`),
                // inserting an unrelated extender between the parent and the
                // sibling changes which element is the direct parent.
                if (comb_before_non_desc_last != .descendant) break :sibling_weave;
                var woven_prefixes = try weave(allocator, non_desc_rest, desc_base);
                defer {
                    for (woven_prefixes.items) |*w| w.deinit();
                    woven_prefixes.deinit(allocator);
                }
                if (woven_prefixes.items.len > 0) {
                    try results.ensureUnusedCapacity(allocator, woven_prefixes.items.len);
                    for (woven_prefixes.items) |*w| {
                        var sel = try w.clone(allocator);
                        errdefer sel.deinit();
                        if (comb_before_non_desc_last == .descendant) {
                            try appendDescIfNeeded(allocator, &sel);
                        } else if (sel.components.items.len > 0 and sel.components.items[sel.components.items.len - 1] == .compound) {
                            try sel.components.append(allocator, .{ .combinator = comb_before_non_desc_last });
                        }
                        try sel.components.append(allocator, .{ .compound = try non_desc_last.?.clone(allocator) });
                        try sel.components.append(allocator, .{ .combinator = nonDesc_comb });
                        try results.append(allocator, sel);
                    }
                    return results;
                }
            }
        }

        // Both have content. Non-descendant base must come last.
        {
            var sel = ComplexSelector.init(allocator);
            errdefer sel.deinit();
            try cloneComponents(allocator, &sel, desc_base);
            if (sel.components.items.len > 0 and sel.components.items[sel.components.items.len - 1] == .compound) {
                try sel.components.append(allocator, .{ .combinator = .descendant });
            }
            const non_desc_to_clone = blk: {
                if (nonDesc_comb == .child and compoundComponentCount(nonDesc_base) == 1) break :blk nonDesc_base;
                const desc_first_idx = firstCompoundIndex(desc_base);
                const non_desc_first_idx = firstCompoundIndex(nonDesc_base);
                if (desc_first_idx != null and non_desc_first_idx != null and
                    compoundSelectorEql(&desc_base[desc_first_idx.?].compound, &nonDesc_base[non_desc_first_idx.?].compound))
                {
                    break :blk sliceAfterSharedFirstDescendantCompound(nonDesc_base);
                }
                break :blk nonDesc_base;
            };
            try cloneComponents(allocator, &sel, non_desc_to_clone);
            if (sel.components.items.len > 0 and sel.components.items[sel.components.items.len - 1] == .compound) {
                try sel.components.append(allocator, .{ .combinator = nonDesc_comb });
            }
            try results.append(allocator, sel);
        }
        return results;
    }

    // Case 3: Both non-descendant, same combinator
    if (orig_comb == ext_comb) {
        if (orig_comb == .general_sibling) {
            return weaveTildeTilde(allocator, orig_base, ext_base);
        }
        if (orig_comb == .next_sibling) {
            return weaveSameComb(allocator, orig_base, ext_base, .next_sibling);
        }
        if (orig_comb == .child) {
            return weaveSameComb(allocator, orig_base, ext_base, .child);
        }
    }

    // Case 4: ~ + + or + + ~
    if ((orig_comb == .general_sibling and ext_comb == .next_sibling) or
        (orig_comb == .next_sibling and ext_comb == .general_sibling))
    {
        const tilde_base = if (orig_comb == .general_sibling) orig_base else ext_base;
        const plus_base = if (orig_comb == .next_sibling) orig_base else ext_base;
        return weaveTildePlus(allocator, tilde_base, plus_base);
    }

    // Case 5: > + sibling (or sibling + >)
    // Observed official Sass CLI output places the child combinator's context first (descendant),
    // then the sibling combinator's compound follows with its combinator.
    // e.g., `.a > x` extended by `.b ~ y`: orig=.a(>), ext=.b(~)
    // ->  result: `.a > .b ~ target` (child base, then sibling compound with ~)
    {
        const child_base = if (orig_comb == .child) orig_base else ext_base;
        const sibling_base = if (orig_comb == .child) ext_base else orig_base;
        const sibling_comb = if (orig_comb == .child) ext_comb else orig_comb;

        const child_last = getLastCompoundFromSlice(child_base);
        const sibling_last = getLastCompoundFromSlice(sibling_base);
        const child_rest = getSliceBeforeLastCompound(child_base);
        const sibling_rest = getSliceBeforeLastCompound(sibling_base);

        // When the combinator before sibling_last in sibling_base is > (child),
        // the sibling's ancestor occupies the same parent position as child_last.
        // They share the same DOM parent (since siblings share a parent), so merge them.
        //e.g., .a > .b + x extended by .c > y: .a and .c share parent  ->  .a.c > .b + y
        const comb_before_sibling = getCombinatorBeforeLastCompound(sibling_base);
        if (comb_before_sibling == .child and child_last != null) {
            const sibling_rest_last = getLastCompoundFromSlice(sibling_rest);
            if (sibling_rest_last != null) {
                const merged_parent = try mergeCompounds(allocator, sibling_rest_last.?, child_last.?);
                if (merged_parent) |*mp| {
                    var merged_p = mp.*;
                    errdefer merged_p.deinit();

                    const sibling_rest_rest = getSliceBeforeLastCompound(sibling_rest);
                    var inner = try weave(allocator, child_rest, sibling_rest_rest);
                    defer {
                        for (inner.items) |*r| r.deinit();
                        inner.deinit(allocator);
                    }

                    if (inner.items.len == 0 and child_rest.len > 0 and sibling_rest_rest.len > 0) {
                        merged_p.deinit();
                        return results;
                    }

                    if (inner.items.len == 0) {
                        var sel = ComplexSelector.init(allocator);
                        errdefer sel.deinit();
                        try sel.components.append(allocator, .{ .compound = merged_p });
                        try sel.components.append(allocator, .{ .combinator = .child });
                        if (sibling_last) |sl| {
                            try sel.components.append(allocator, .{ .compound = try sl.clone(allocator) });
                            try sel.components.append(allocator, .{ .combinator = sibling_comb });
                        }
                        try results.append(allocator, sel);
                    } else {
                        for (inner.items) |*ip| {
                            var sel = try ip.clone(allocator);
                            errdefer sel.deinit();
                            try appendDescIfNeeded(allocator, &sel);
                            try sel.components.append(allocator, .{ .compound = try merged_p.clone(allocator) });
                            try sel.components.append(allocator, .{ .combinator = .child });
                            if (sibling_last) |sl| {
                                try sel.components.append(allocator, .{ .compound = try sl.clone(allocator) });
                                try sel.components.append(allocator, .{ .combinator = sibling_comb });
                            }
                            try results.append(allocator, sel);
                        }
                        merged_p.deinit();
                    }
                    return results;
                }
            }
        }

        var inner = try weave(allocator, child_rest, sibling_rest);
        defer {
            for (inner.items) |*r| r.deinit();
            inner.deinit(allocator);
        }

        if (inner.items.len == 0 and child_rest.len > 0 and sibling_rest.len > 0) {
            return results;
        }

        if (inner.items.len == 0) {
            var sel = ComplexSelector.init(allocator);
            errdefer sel.deinit();
            if (child_last) |cl| {
                try sel.components.append(allocator, .{ .compound = try cl.clone(allocator) });
                try sel.components.append(allocator, .{ .combinator = .child });
            }
            if (sibling_last) |sl| {
                try sel.components.append(allocator, .{ .compound = try sl.clone(allocator) });
                try sel.components.append(allocator, .{ .combinator = sibling_comb });
            }
            try results.append(allocator, sel);
        } else {
            for (inner.items) |*ip| {
                var sel = try ip.clone(allocator);
                errdefer sel.deinit();
                try appendDescIfNeeded(allocator, &sel);
                if (child_last) |cl| {
                    try sel.components.append(allocator, .{ .compound = try cl.clone(allocator) });
                    try sel.components.append(allocator, .{ .combinator = .child });
                }
                if (sibling_last) |sl| {
                    try sel.components.append(allocator, .{ .compound = try sl.clone(allocator) });
                    try sel.components.append(allocator, .{ .combinator = sibling_comb });
                }
                try results.append(allocator, sel);
            }
        }
        return results;
    }
}

/// ~ + ~: Three results (both orderings + merged compound)
fn weaveTildeTilde(
    allocator: std.mem.Allocator,
    base1: []const ComplexSelectorComponent,
    base2: []const ComplexSelectorComponent,
) !std.ArrayList(ComplexSelector) {
    var results: std.ArrayList(ComplexSelector) = .empty;
    errdefer {
        for (results.items) |*r| r.deinit();
        results.deinit(allocator);
    }

    const last1 = getLastCompoundFromSlice(base1);
    const last2 = getLastCompoundFromSlice(base2);
    const rest1 = getSliceBeforeLastCompound(base1);
    const rest2 = getSliceBeforeLastCompound(base2);

    if (last1 == null and last2 == null) {
        var sel = ComplexSelector.init(allocator);
        try sel.components.append(allocator, .{ .combinator = .general_sibling });
        try results.append(allocator, sel);
        return results;
    }

    var inner = try weave(allocator, rest1, rest2);
    defer {
        for (inner.items) |*r| r.deinit();
        inner.deinit(allocator);
    }

    if (inner.items.len == 0 and rest1.len > 0 and rest2.len > 0) {
        return results;
    }

    const can_merge = if (last1 != null and last2 != null) canMergeCompounds(last1.?, last2.?) else true;

    // Check if one compound is a superselector of the other.
    // If so, only produce the merged result.
    const is_superselector = if (last1 != null and last2 != null)
        compoundContainsTarget(last1.?, last2.?) or compoundContainsTarget(last2.?, last1.?)
    else
        false;

    if (inner.items.len == 0) {
        if (last1 != null and last2 != null and !is_superselector) {
            // Result 1: last1 ~ last2 ~
            var s1 = ComplexSelector.init(allocator);
            try s1.components.append(allocator, .{ .compound = try last1.?.clone(allocator) });
            try s1.components.append(allocator, .{ .combinator = .general_sibling });
            try s1.components.append(allocator, .{ .compound = try last2.?.clone(allocator) });
            try s1.components.append(allocator, .{ .combinator = .general_sibling });
            try results.append(allocator, s1);
            // Result 2: last2 ~ last1 ~
            var s2 = ComplexSelector.init(allocator);
            try s2.components.append(allocator, .{ .compound = try last2.?.clone(allocator) });
            try s2.components.append(allocator, .{ .combinator = .general_sibling });
            try s2.components.append(allocator, .{ .compound = try last1.?.clone(allocator) });
            try s2.components.append(allocator, .{ .combinator = .general_sibling });
            try results.append(allocator, s2);
        } else if (last1 != null and !is_superselector) {
            var s1 = ComplexSelector.init(allocator);
            try s1.components.append(allocator, .{ .compound = try last1.?.clone(allocator) });
            try s1.components.append(allocator, .{ .combinator = .general_sibling });
            try results.append(allocator, s1);
        } else if (last2 != null and !is_superselector) {
            var s1 = ComplexSelector.init(allocator);
            try s1.components.append(allocator, .{ .compound = try last2.?.clone(allocator) });
            try s1.components.append(allocator, .{ .combinator = .general_sibling });
            try results.append(allocator, s1);
        }
        // Merged result
        if (can_merge and last1 != null and last2 != null) {
            const merged = try mergeCompounds(allocator, last1.?, last2.?);
            if (merged) |m| {
                var sel = ComplexSelector.init(allocator);
                try sel.components.append(allocator, .{ .compound = m });
                try sel.components.append(allocator, .{ .combinator = .general_sibling });
                try results.append(allocator, sel);
            }
        }
    } else {
        const inner_result_cap = std.math.mul(usize, inner.items.len, 3) catch std.math.maxInt(usize);
        try results.ensureUnusedCapacity(allocator, inner_result_cap);
        for (inner.items) |*ip| {
            if (last1 != null and last2 != null and !is_superselector) {
                var s1 = try ip.clone(allocator);
                try appendDescIfNeeded(allocator, &s1);
                try s1.components.append(allocator, .{ .compound = try last1.?.clone(allocator) });
                try s1.components.append(allocator, .{ .combinator = .general_sibling });
                try s1.components.append(allocator, .{ .compound = try last2.?.clone(allocator) });
                try s1.components.append(allocator, .{ .combinator = .general_sibling });
                try results.append(allocator, s1);

                var s2 = try ip.clone(allocator);
                try appendDescIfNeeded(allocator, &s2);
                try s2.components.append(allocator, .{ .compound = try last2.?.clone(allocator) });
                try s2.components.append(allocator, .{ .combinator = .general_sibling });
                try s2.components.append(allocator, .{ .compound = try last1.?.clone(allocator) });
                try s2.components.append(allocator, .{ .combinator = .general_sibling });
                try results.append(allocator, s2);
            }
            if (can_merge and last1 != null and last2 != null) {
                const merged = try mergeCompounds(allocator, last1.?, last2.?);
                if (merged) |m| {
                    var sel = try ip.clone(allocator);
                    try appendDescIfNeeded(allocator, &sel);
                    try sel.components.append(allocator, .{ .compound = m });
                    try sel.components.append(allocator, .{ .combinator = .general_sibling });
                    try results.append(allocator, sel);
                }
            }
        }
    }
    return results;
}

/// ~ + +: Two results (tilde before plus, and merged with +)
fn weaveTildePlus(
    allocator: std.mem.Allocator,
    tilde_base: []const ComplexSelectorComponent,
    plus_base: []const ComplexSelectorComponent,
) !std.ArrayList(ComplexSelector) {
    var results: std.ArrayList(ComplexSelector) = .empty;
    errdefer {
        for (results.items) |*r| r.deinit();
        results.deinit(allocator);
    }

    const tilde_last = getLastCompoundFromSlice(tilde_base);
    const plus_last = getLastCompoundFromSlice(plus_base);
    const tilde_rest = getSliceBeforeLastCompound(tilde_base);
    const plus_rest = getSliceBeforeLastCompound(plus_base);

    var inner = try weave(allocator, tilde_rest, plus_rest);
    defer {
        for (inner.items) |*r| r.deinit();
        inner.deinit(allocator);
    }

    if (inner.items.len == 0 and tilde_rest.len > 0 and plus_rest.len > 0) {
        return results;
    }

    const can_merge = if (tilde_last != null and plus_last != null) canMergeCompounds(tilde_last.?, plus_last.?) else true;

    // If the tilde compound is a superselector of the plus compound,
    // only produce the merged result.
    const tilde_is_superselector = if (tilde_last != null and plus_last != null)
        compoundContainsTarget(plus_last.?, tilde_last.?)
    else
        false;

    if (inner.items.len == 0) {
        // Result 1: tilde_last ~ plus_last + (skip if superselector)
        if (!tilde_is_superselector) {
            var sel = ComplexSelector.init(allocator);
            errdefer sel.deinit();
            if (tilde_last) |tl| {
                try sel.components.append(allocator, .{ .compound = try tl.clone(allocator) });
                try sel.components.append(allocator, .{ .combinator = .general_sibling });
            }
            if (plus_last) |pl| {
                try sel.components.append(allocator, .{ .compound = try pl.clone(allocator) });
            }
            try sel.components.append(allocator, .{ .combinator = .next_sibling });
            try results.append(allocator, sel);
        }
        // Result 2: merged +
        if (can_merge and tilde_last != null and plus_last != null) {
            const merged = try mergeCompounds(allocator, tilde_last.?, plus_last.?);
            if (merged) |m| {
                var sel = ComplexSelector.init(allocator);
                try sel.components.append(allocator, .{ .compound = m });
                try sel.components.append(allocator, .{ .combinator = .next_sibling });
                try results.append(allocator, sel);
            }
        }
    } else {
        const inner_result_cap = std.math.mul(usize, inner.items.len, 2) catch std.math.maxInt(usize);
        try results.ensureUnusedCapacity(allocator, inner_result_cap);
        for (inner.items) |*ip| {
            if (!tilde_is_superselector) {
                var sel = try ip.clone(allocator);
                errdefer sel.deinit();
                try appendDescIfNeeded(allocator, &sel);
                if (tilde_last) |tl| {
                    try sel.components.append(allocator, .{ .compound = try tl.clone(allocator) });
                    try sel.components.append(allocator, .{ .combinator = .general_sibling });
                }
                if (plus_last) |pl| {
                    try sel.components.append(allocator, .{ .compound = try pl.clone(allocator) });
                }
                try sel.components.append(allocator, .{ .combinator = .next_sibling });
                try results.append(allocator, sel);
            }
            if (can_merge and tilde_last != null and plus_last != null) {
                const merged = try mergeCompounds(allocator, tilde_last.?, plus_last.?);
                if (merged) |m| {
                    var sel = try ip.clone(allocator);
                    errdefer sel.deinit();
                    try appendDescIfNeeded(allocator, &sel);
                    try sel.components.append(allocator, .{ .compound = m });
                    try sel.components.append(allocator, .{ .combinator = .next_sibling });
                    try results.append(allocator, sel);
                }
            }
        }
    }
    return results;
}

/// Same combinator (> or +): Unify compounds and produce single result.
fn weaveSameComb(
    allocator: std.mem.Allocator,
    base1: []const ComplexSelectorComponent,
    base2: []const ComplexSelectorComponent,
    comb: Combinator,
) std.mem.Allocator.Error!std.ArrayList(ComplexSelector) {
    var results: std.ArrayList(ComplexSelector) = .empty;
    errdefer {
        for (results.items) |*r| r.deinit();
        results.deinit(allocator);
    }

    const last1 = getLastCompoundFromSlice(base1);
    const last2 = getLastCompoundFromSlice(base2);
    const rest1 = getSliceBeforeLastCompound(base1);
    const rest2 = getSliceBeforeLastCompound(base2);

    if (last1 != null and last2 != null) {
        const merged = try mergeCompounds(allocator, last1.?, last2.?);
        if (merged == null) return results;
        var merged_val = merged.?;
        errdefer merged_val.deinit();

        // Use weavePaths recursively to preserve intermediate combinators.
        // e.g., base1=[.a, >, .b], base2=[.c, >, .d] with comb=+
        // ->  rest1=[.a], rest2=[.c], comb_before_1=>, comb_before_2=>
        // ->  weavePaths([.a], >, [.c], >)  ->  weaveSameComb  ->  [.a.c, >]
        // ->  result: [.a.c, >, .b.d, +]
        const comb_before_1 = getCombinatorBeforeLastCompound(base1);
        const comb_before_2 = getCombinatorBeforeLastCompound(base2);
        var inner = try weavePaths(allocator, rest1, comb_before_1, rest2, comb_before_2);
        defer {
            for (inner.items) |*r| r.deinit();
            inner.deinit(allocator);
        }

        if (inner.items.len == 0 and rest1.len > 0 and rest2.len > 0) {
            merged_val.deinit();
            return results;
        }

        if (inner.items.len == 0) {
            var sel = ComplexSelector.init(allocator);
            try sel.components.append(allocator, .{ .compound = merged_val });
            // SAFETY: initialized before first read in this scope.
            merged_val = undefined;
            try sel.components.append(allocator, .{ .combinator = comb });
            try results.append(allocator, sel);
        } else {
            try results.ensureUnusedCapacity(allocator, inner.items.len);
            for (inner.items) |*ip| {
                var sel = try ip.clone(allocator);
                errdefer sel.deinit();
                // Only add descendant if inner result ends with a compound
                // (weavePaths results may already end with a combinator)
                if (sel.components.items.len > 0 and sel.components.items[sel.components.items.len - 1] == .compound) {
                    try sel.components.append(allocator, .{ .combinator = .descendant });
                }
                try sel.components.append(allocator, .{ .compound = try merged_val.clone(allocator) });
                try sel.components.append(allocator, .{ .combinator = comb });
                try results.append(allocator, sel);
            }
            merged_val.deinit();
        }
    } else if (last1 != null) {
        var sel = ComplexSelector.init(allocator);
        errdefer sel.deinit();
        try cloneComponents(allocator, &sel, base1);
        if (sel.components.items.len > 0 and sel.components.items[sel.components.items.len - 1] == .compound) {
            try sel.components.append(allocator, .{ .combinator = comb });
        }
        try results.append(allocator, sel);
    } else if (last2 != null) {
        var sel = ComplexSelector.init(allocator);
        errdefer sel.deinit();
        try cloneComponents(allocator, &sel, base2);
        if (sel.components.items.len > 0 and sel.components.items[sel.components.items.len - 1] == .compound) {
            try sel.components.append(allocator, .{ .combinator = comb });
        }
        try results.append(allocator, sel);
    } else {
        var sel = ComplexSelector.init(allocator);
        try sel.components.append(allocator, .{ .combinator = comb });
        try results.append(allocator, sel);
    }
    return results;
}

/// Check if two compounds can be merged (compatible type selectors and IDs).
fn canMergeCompounds(c1: *const CompoundSelector, c2: *const CompoundSelector) bool {
    var type1: ?[]const u8 = null;
    var type2: ?[]const u8 = null;
    var id1: ?[]const u8 = null;
    var id2: ?[]const u8 = null;
    for (c1.simple_selectors.items) |ss| {
        switch (ss) {
            .type_selector => |n| type1 = n,
            .id => |n| id1 = n,
            else => {},
        }
    }
    for (c2.simple_selectors.items) |ss| {
        switch (ss) {
            .type_selector => |n| type2 = n,
            .id => |n| id2 = n,
            else => {},
        }
    }
    if (type1 != null and type2 != null and !std.mem.eql(u8, type1.?, type2.?)) return false;
    if (id1 != null and id2 != null and !std.mem.eql(u8, id1.?, id2.?)) return false;
    return true;
}

/// Merge two compound selectors into one.
fn mergeCompounds(allocator: std.mem.Allocator, c1: *const CompoundSelector, c2: *const CompoundSelector) !?CompoundSelector {
    if (!canMergeCompounds(c1, c2)) return null;
    var type1: ?[]const u8 = null;
    var type2: ?[]const u8 = null;
    for (c1.simple_selectors.items) |ss| {
        if (ss == .type_selector) {
            type1 = ss.type_selector;
            break;
        }
    }
    for (c2.simple_selectors.items) |ss| {
        if (ss == .type_selector) {
            type2 = ss.type_selector;
            break;
        }
    }

    var result = CompoundSelector.init(allocator);
    errdefer result.deinit();

    const final_type = type1 orelse type2;
    if (final_type) |t| {
        try result.simple_selectors.append(allocator, .{ .type_selector = try allocator.dupe(u8, t) });
    }
    for (c1.simple_selectors.items) |ss| {
        if (ss == .type_selector) continue;
        try result.simple_selectors.append(allocator, try cloneSimpleSelector(ss, allocator));
    }
    for (c2.simple_selectors.items) |ss| {
        if (ss == .type_selector) continue;
        var is_dup = false;
        for (result.simple_selectors.items) |existing| {
            if (simpleSelectorEql(ss, existing)) {
                is_dup = true;
                break;
            }
        }
        if (!is_dup) {
            try result.simple_selectors.append(allocator, try cloneSimpleSelector(ss, allocator));
        }
    }
    return result;
}

fn getLastCompoundFromSlice(components: []const ComplexSelectorComponent) ?*const CompoundSelector {
    var i: usize = components.len;
    while (i > 0) {
        i -= 1;
        if (components[i] == .compound) return &components[i].compound;
    }
    return null;
}

fn getSliceBeforeLastCompound(components: []const ComplexSelectorComponent) []const ComplexSelectorComponent {
    var i: usize = components.len;
    while (i > 0) {
        i -= 1;
        if (components[i] == .compound) {
            if (i > 0 and components[i - 1] == .combinator) return components[0 .. i - 1];
            return components[0..i];
        }
    }
    return components[0..0];
}

/// Get the combinator that precedes the last compound in a component slice.
/// Returns .descendant if there is no explicit combinator before the last compound.
fn getCombinatorBeforeLastCompound(components: []const ComplexSelectorComponent) Combinator {
    var i: usize = components.len;
    while (i > 0) {
        i -= 1;
        if (components[i] == .compound) {
            if (i > 0 and components[i - 1] == .combinator) return components[i - 1].combinator;
            return .descendant;
        }
    }
    return .descendant;
}

fn firstCompoundIndex(components: []const ComplexSelectorComponent) ?usize {
    for (components, 0..) |component, idx| {
        if (component == .compound) return idx;
    }
    return null;
}

fn compoundComponentCount(components: []const ComplexSelectorComponent) usize {
    var count: usize = 0;
    for (components) |component| {
        if (component == .compound) count += 1;
    }
    return count;
}

fn sliceAfterSharedFirstDescendantCompound(components: []const ComplexSelectorComponent) []const ComplexSelectorComponent {
    const first_idx = firstCompoundIndex(components) orelse return components;
    var start = first_idx + 1;
    if (start < components.len and components[start] == .combinator and components[start].combinator == .descendant) {
        start += 1;
    }
    return components[start..];
}

fn componentsHasPrefix(
    components: []const ComplexSelectorComponent,
    prefix: []const ComplexSelectorComponent,
) bool {
    if (prefix.len > components.len) return false;
    for (prefix, 0..) |prefix_component, idx| {
        const component = components[idx];
        if (std.meta.activeTag(component) != std.meta.activeTag(prefix_component)) return false;
        switch (prefix_component) {
            .combinator => |comb| {
                if (component.combinator != comb) return false;
            },
            .compound => |compound| {
                if (!compoundSelectorEql(&component.compound, &compound)) return false;
            },
        }
    }
    return true;
}

fn cloneComponents(allocator: std.mem.Allocator, sel: *ComplexSelector, comps: []const ComplexSelectorComponent) !void {
    for (comps) |c| {
        switch (c) {
            .compound => |cs| try sel.components.append(allocator, .{ .compound = try cs.clone(allocator) }),
            .combinator => |cb| try sel.components.append(allocator, .{ .combinator = cb }),
        }
    }
}

fn appendDescIfNeeded(allocator: std.mem.Allocator, sel: *ComplexSelector) !void {
    if (sel.components.items.len > 0 and sel.components.items[sel.components.items.len - 1] == .compound) {
        try sel.components.append(allocator, .{ .combinator = .descendant });
    }
}

// ============================================================================
// Group-based helpers for weave (sass-spec-covered behavior)
// ============================================================================

/// A "group" is a slice of components connected by non-descendant combinators,
/// ending at a descendant boundary. E.g., `a > b c`  ->  groups [[a, >, b], [c]].
const Group = struct {
    start: usize,
    end: usize, // exclusive
};

/// Split a component slice into groups at descendant combinator boundaries.
fn splitIntoGroups(components: []const ComplexSelectorComponent, allocator: std.mem.Allocator) !std.ArrayList(Group) {
    var groups: std.ArrayList(Group) = .empty;
    errdefer groups.deinit(allocator);

    var group_start: usize = 0;
    var i: usize = 0;
    while (i < components.len) {
        if (components[i] == .combinator and components[i].combinator == .descendant) {
            // End current group at the compound before this descendant
            if (i > group_start) {
                try groups.append(allocator, .{ .start = group_start, .end = i });
            }
            group_start = i + 1;
        }
        i += 1;
    }
    // Final group
    if (group_start < components.len) {
        try groups.append(allocator, .{ .start = group_start, .end = components.len });
    }
    return groups;
}

/// Check if two groups are structurally equal.
fn groupEql(components1: []const ComplexSelectorComponent, g1: Group, components2: []const ComplexSelectorComponent, g2: Group) bool {
    const s1 = components1[g1.start..g1.end];
    const s2 = components2[g2.start..g2.end];
    if (s1.len != s2.len) return false;
    for (s1, s2) |a, b| {
        const a_tag: @TypeOf(std.meta.activeTag(a)) = a;
        const b_tag: @TypeOf(std.meta.activeTag(b)) = b;
        if (a_tag != b_tag) return false;
        switch (a) {
            .combinator => |c| {
                if (c != b.combinator) return false;
            },
            .compound => |c| {
                if (!compoundSelectorEql(&c, &b.compound)) return false;
            },
        }
    }
    return true;
}

/// Check if group1 is a "parent superselector" of group2.
/// group1 is a parent superselector if `group1 X` matches a superset of `group2 X`.
/// E.g., [a] is a parent superselector of [a > b] because `a X`  >  `a > b X`.
/// But [a] is NOT a parent superselector of [a + b] because sibling combinators
/// don't create ancestor relationships.
fn groupIsParentSuperselector(components1: []const ComplexSelectorComponent, g1: Group, components2: []const ComplexSelectorComponent, g2: Group) bool {
    const s1 = components1[g1.start..g1.end];
    const s2 = components2[g2.start..g2.end];

    // Get first compound of each group (for ancestor matching)
    var first1_compound: ?*const CompoundSelector = null;
    for (s1) |*c| {
        if (c.* == .compound) {
            first1_compound = &c.compound;
            break;
        }
    }
    var first2_compound: ?*const CompoundSelector = null;
    for (s2) |*c| {
        if (c.* == .compound) {
            first2_compound = &c.compound;
            break;
        }
    }

    if (first1_compound == null or first2_compound == null) return false;

    // If both are single-compound groups
    if (s1.len == 1 and s2.len == 1) {
        // Same size: g1 is superselector if g2's compound contains g1's compound
        return compoundContainsTarget(first2_compound.?, first1_compound.?);
    }

    // If g1 is a single compound and g2 is multi-compound
    if (s1.len == 1 and s2.len > 1) {
        // Case A: g1's compound matches g2's FIRST compound, and g2 uses child combinator (>).
        //Child combinator preserves ancestor relationship: a > b X  <  a X
        //Sibling combinators (+, ~) do NOT: a + b X  not subset of  a X
        if (compoundContainsTarget(first2_compound.?, first1_compound.?) and
            s2.len >= 2 and s2[1] == .combinator and s2[1].combinator == .child) return true;

        // Case B: g1's compound matches g2's LAST compound.
        // The multi-compound group adds restrictions (parent/sibling requirements)
        // that make it more specific, regardless of combinator type.
        // e.g., [b] is superselector of [a > b] (child adds restriction)
        //       [b] is superselector of [a + b] (sibling adds restriction)
        var last2_compound: ?*const CompoundSelector = null;
        for (s2) |*c| {
            if (c.* == .compound) last2_compound = &c.compound;
        }
        if (last2_compound != null and compoundContainsTarget(last2_compound.?, first1_compound.?)) return true;

        return false;
    }

    // g1 is multi-compound: more restrictive cases
    if (s1.len > s2.len) return false;

    // Get last compound of each group
    var last1_compound: ?*const CompoundSelector = null;
    for (s1) |*c| {
        if (c.* == .compound) last1_compound = &c.compound;
    }
    var last2_compound: ?*const CompoundSelector = null;
    for (s2) |*c| {
        if (c.* == .compound) last2_compound = &c.compound;
    }
    if (last1_compound == null or last2_compound == null) return false;
    if (!compoundContainsTarget(last2_compound.?, last1_compound.?)) return false;

    // Same length: g1 is superselector only if ALL corresponding compounds match
    if (s1.len == s2.len) {
        var ci: usize = 0;
        while (ci < s1.len) : (ci += 1) {
            if (s1[ci] == .compound and s2[ci] == .compound) {
                if (!compoundContainsTarget(&s2[ci].compound, &s1[ci].compound)) return false;
            } else if (s1[ci] == .combinator and s2[ci] == .combinator) {
                if (s1[ci].combinator != s2[ci].combinator) return false;
            } else {
                return false; // structural mismatch
            }
        }
        return true;
    }

    return false;
}

/// Select the "more specific" group from two groups for LCS matching.
/// Returns 0 if g1 is more specific, 1 if g2, or null if not matchable.
fn groupSelectForLcs(
    components1: []const ComplexSelectorComponent,
    g1: Group,
    components2: []const ComplexSelectorComponent,
    g2: Group,
) ?u8 {
    if (groupEql(components1, g1, components2, g2)) return 0;
    // If g2 is a superselector of g1, use g1 (more specific)
    if (groupIsParentSuperselector(components2, g2, components1, g1)) return 0;
    // If g1 is a superselector of g2, use g2 (more specific)
    if (groupIsParentSuperselector(components1, g1, components2, g2)) return 1;
    return null;
}

// ============================================================================
// rootish helpers (for :root/:host/:host-context unification in weave)
// ============================================================================

/// Check if a compound selector contains a "rootish" pseudo-class
/// (:root, :host, :host-context) that can only match a unique element.
fn compoundIsRootish(compound: *const CompoundSelector) bool {
    for (compound.simple_selectors.items) |ss| {
        switch (ss) {
            .pseudo_class => |ps| {
                if (std.mem.eql(u8, ps.name, "root") or
                    std.mem.eql(u8, ps.name, "host") or
                    std.mem.eql(u8, ps.name, "host-context"))
                    return true;
            },
            else => {},
        }
    }
    return false;
}

/// Check if a complex selector has a rootish compound at a non-initial position
/// (i.e. as a descendant of something). Such selectors are semantically impossible
/// because :root/:host can never be a descendant of another element.
fn complexHasRootishNonInitial(sel: *const ComplexSelector) bool {
    var found_first_compound = false;
    for (sel.components.items) |comp| {
        switch (comp) {
            .compound => |*cs| {
                if (found_first_compound) {
                    if (compoundIsRootish(cs)) return true;
                }
                found_first_compound = true;
            },
            .combinator => {},
        }
    }
    return false;
}

/// Unify two compounds directly (without extend target context).
/// Used when two rootish compounds must be merged because they represent
/// the same unique element (e.g., :root).
fn unifyTwoCompounds(
    allocator: std.mem.Allocator,
    c1: *const CompoundSelector,
    c2: *const CompoundSelector,
) !?CompoundSelector {
    // Delegate to unifyCompound with an empty target so nothing is filtered.
    var empty_target = CompoundSelector.init(allocator);
    defer empty_target.deinit();
    return unifyCompound(allocator, c1, &empty_target, c2);
}

// ============================================================================
// weave
// ============================================================================

/// Interleave the components of two complex selector prefixes using group-based
/// LCS with superselector matching.
/// Produces all possible orderings via cartesian product of per-gap chunks.
fn weave(
    allocator: std.mem.Allocator,
    prefix1: []const ComplexSelectorComponent,
    prefix2: []const ComplexSelectorComponent,
) !std.ArrayList(ComplexSelector) {
    var results: std.ArrayList(ComplexSelector) = .empty;
    errdefer {
        for (results.items) |*r| r.deinit();
        results.deinit(allocator);
    }

    if (prefix1.len == 0) {
        var sel = ComplexSelector.init(allocator);
        errdefer sel.deinit();
        try cloneComponents(allocator, &sel, prefix2);
        try results.append(allocator, sel);
        return results;
    }
    if (prefix2.len == 0) {
        var sel = ComplexSelector.init(allocator);
        errdefer sel.deinit();
        try cloneComponents(allocator, &sel, prefix1);
        try results.append(allocator, sel);
        return results;
    }

    // Group-based LCS weaving.
    // Groups are sequences of compounds connected by non-descendant combinators.
    //E.g., `a + b c`  ->  groups: [a + b], [c]
    // LCS operates on groups, preserving non-descendant combinators within groups.
    var groups1 = try splitIntoGroups(prefix1, allocator);
    defer groups1.deinit(allocator);
    var groups2 = try splitIntoGroups(prefix2, allocator);
    defer groups2.deinit(allocator);

    const m = groups1.items.len;
    const n = groups2.items.len;

    // Build LCS table on groups (flat (m+1) * (n+1) storage, row-major)
    const dp_stride = n + 1;
    const dp = try allocator.alloc(u32, (m + 1) * dp_stride);
    defer allocator.free(dp);
    @memset(dp, 0);
    for (1..m + 1) |i| {
        for (1..n + 1) |j| {
            // Match groups by exact equality OR superselector relationship
            if (groupSelectForLcs(prefix1, groups1.items[i - 1], prefix2, groups2.items[j - 1]) != null) {
                dp[i * dp_stride + j] = dp[(i - 1) * dp_stride + (j - 1)] + 1;
            } else {
                dp[i * dp_stride + j] = @max(dp[(i - 1) * dp_stride + j], dp[i * dp_stride + (j - 1)]);
            }
        }
    }

    const lcs_len = dp[m * dp_stride + n];
    if (lcs_len == 0) {
        // No common groups.
        // Check if first compounds are rootish (:root/:host/:host-context).
        // Rootish compounds represent a unique element and must be unified
        // rather than interleaved.
        const p1_first_rootish = prefix1.len > 0 and prefix1[0] == .compound and compoundIsRootish(&prefix1[0].compound);
        const p2_first_rootish = prefix2.len > 0 and prefix2[0] == .compound and compoundIsRootish(&prefix2[0].compound);

        if (p1_first_rootish and p2_first_rootish) {
            //Both prefixes start with rootish -- unify them.
            if (try unifyTwoCompounds(allocator, &prefix1[0].compound, &prefix2[0].compound)) |unified| {
                const rest1 = if (prefix1.len > 1) prefix1[1..] else &[_]ComplexSelectorComponent{};
                const rest2 = if (prefix2.len > 1) prefix2[1..] else &[_]ComplexSelectorComponent{};

                if (rest1.len == 0 and rest2.len == 0) {
                    var combined = ComplexSelector.init(allocator);
                    errdefer combined.deinit();
                    try combined.components.append(allocator, .{ .compound = unified });
                    try results.append(allocator, combined);
                } else if (rest1.len == 0) {
                    var combined = ComplexSelector.init(allocator);
                    errdefer combined.deinit();
                    try combined.components.append(allocator, .{ .compound = unified });
                    try cloneComponents(allocator, &combined, rest2);
                    try results.append(allocator, combined);
                } else if (rest2.len == 0) {
                    var combined = ComplexSelector.init(allocator);
                    errdefer combined.deinit();
                    try combined.components.append(allocator, .{ .compound = unified });
                    try cloneComponents(allocator, &combined, rest1);
                    try results.append(allocator, combined);
                } else {
                    // Both rests non-empty. A non-descendant combinator (>, +, ~)
                    // at the start of a rest means the following compound was originally
                    // adjacent to the rootish compound and must stay right after it.
                    const rest1_non_desc = rest1[0] == .combinator and rest1[0].combinator != .descendant;
                    const rest2_non_desc = rest2[0] == .combinator and rest2[0].combinator != .descendant;

                    if (rest1_non_desc or rest2_non_desc) {
                        // Constrained ordering: put non-descendant rest first
                        var combined = ComplexSelector.init(allocator);
                        errdefer combined.deinit();
                        try combined.components.append(allocator, .{ .compound = unified });
                        if (rest1_non_desc) {
                            try cloneComponents(allocator, &combined, rest1);
                            try cloneComponents(allocator, &combined, rest2);
                        } else {
                            try cloneComponents(allocator, &combined, rest2);
                            try cloneComponents(allocator, &combined, rest1);
                        }
                        try results.append(allocator, combined);
                    } else {
                        //Both start with descendant -- produce both orderings
                        {
                            var combined = ComplexSelector.init(allocator);
                            errdefer combined.deinit();
                            try combined.components.append(allocator, .{ .compound = try unified.clone(allocator) });
                            try cloneComponents(allocator, &combined, rest1);
                            try cloneComponents(allocator, &combined, rest2);
                            try results.append(allocator, combined);
                        }
                        {
                            var combined = ComplexSelector.init(allocator);
                            errdefer combined.deinit();
                            try combined.components.append(allocator, .{ .compound = unified });
                            try cloneComponents(allocator, &combined, rest2);
                            try cloneComponents(allocator, &combined, rest1);
                            try results.append(allocator, combined);
                        }
                    }
                }
            }
            // If unification failed (e.g., html:root vs xml:root), return empty.
            return results;
        }

        // Default: produce both orderings
        {
            var combined = ComplexSelector.init(allocator);
            errdefer combined.deinit();
            try cloneComponents(allocator, &combined, prefix1);
            try combined.components.append(allocator, .{ .combinator = .descendant });
            try cloneComponents(allocator, &combined, prefix2);
            try results.append(allocator, combined);
        }
        {
            var combined = ComplexSelector.init(allocator);
            errdefer combined.deinit();
            try cloneComponents(allocator, &combined, prefix2);
            try combined.components.append(allocator, .{ .combinator = .descendant });
            try cloneComponents(allocator, &combined, prefix1);
            try results.append(allocator, combined);
        }

        // Post-filter for one-sided rootish: remove selectors where rootish is non-initial
        {
            var write_idx: usize = 0;
            for (results.items) |*r| {
                if (complexHasRootishNonInitial(r)) {
                    r.deinit();
                } else {
                    results.items[write_idx] = r.*;
                    write_idx += 1;
                }
            }
            results.shrinkRetainingCapacity(write_idx);
        }

        return results;
    }

    // Backtrack LCS (group indices) + track which source to use for anchor
    const LcsPair = struct { g1_idx: usize, g2_idx: usize, anchor_source: u8 }; // 0=prefix1, 1=prefix2
    const lcs_pairs = try allocator.alloc(LcsPair, lcs_len);
    defer allocator.free(lcs_pairs);
    {
        var k: usize = lcs_len;
        var i: usize = m;
        var j: usize = n;
        while (i > 0 and j > 0) {
            const sel = groupSelectForLcs(prefix1, groups1.items[i - 1], prefix2, groups2.items[j - 1]);
            if (sel != null) {
                k -= 1;
                lcs_pairs[k] = .{ .g1_idx = i - 1, .g2_idx = j - 1, .anchor_source = sel.? };
                i -= 1;
                j -= 1;
            } else if (dp[(i - 1) * dp_stride + j] > dp[i * dp_stride + (j - 1)]) {
                i -= 1;
            } else {
                j -= 1;
            }
        }
    }

    // Helper: clone a sequence of groups into a component ordering
    const cloneGroupsToOrdering = struct {
        fn call(alloc: std.mem.Allocator, pfx: []const ComplexSelectorComponent, groups: []const Group, ordering: *std.ArrayList(ComplexSelectorComponent)) !void {
            var prealloc_cap: usize = 0;
            for (groups, 0..) |g, group_idx| {
                prealloc_cap = std.math.add(usize, prealloc_cap, g.end - g.start) catch std.math.maxInt(usize);
                if (group_idx > 0) {
                    prealloc_cap = std.math.add(usize, prealloc_cap, 1) catch std.math.maxInt(usize);
                }
            }
            try ordering.ensureUnusedCapacity(alloc, prealloc_cap);
            for (groups) |g| {
                if (ordering.items.len > 0) try ordering.append(alloc, .{ .combinator = .descendant });
                for (pfx[g.start..g.end]) |comp| {
                    switch (comp) {
                        .compound => |cs| try ordering.append(alloc, .{ .compound = try cs.clone(alloc) }),
                        .combinator => |cb| try ordering.append(alloc, .{ .combinator = cb }),
                    }
                }
            }
        }
    }.call;

    // Build chunks from group gaps
    const Chunk = std.ArrayList(std.ArrayList(ComplexSelectorComponent));
    var chunks: std.ArrayList(Chunk) = .empty;
    defer {
        for (chunks.items) |*chunk| {
            for (chunk.items) |*ordering| {
                for (ordering.items) |*comp| {
                    if (comp.* == .compound) comp.compound.deinit();
                }
                ordering.deinit(allocator);
            }
            chunk.deinit(allocator);
        }
        chunks.deinit(allocator);
    }
    // Anchors: store the group slice from prefix1 for each LCS anchor
    const AnchorInfo = struct { start: usize, end: usize, source: u8 }; // source: 0=prefix1, 1=prefix2
    var anchors: std.ArrayList(AnchorInfo) = .empty;
    defer anchors.deinit(allocator);
    try chunks.ensureTotalCapacity(allocator, lcs_pairs.len + 1);
    try anchors.ensureTotalCapacity(allocator, lcs_pairs.len);

    var gpos1: usize = 0;
    var gpos2: usize = 0;
    for (lcs_pairs) |pair| {
        const gidx1 = pair.g1_idx;
        const gidx2 = pair.g2_idx;
        const nc_g1 = groups1.items[gpos1..gidx1];
        const nc_g2 = groups2.items[gpos2..gidx2];

        var chunk: Chunk = .empty;
        try chunk.ensureTotalCapacity(allocator, 2);
        if (nc_g1.len == 0 and nc_g2.len == 0) {
            const ordering: std.ArrayList(ComplexSelectorComponent) = .empty;
            try chunk.append(allocator, ordering);
        } else if (nc_g1.len == 0) {
            var ordering: std.ArrayList(ComplexSelectorComponent) = .empty;
            try cloneGroupsToOrdering(allocator, prefix2, nc_g2, &ordering);
            try chunk.append(allocator, ordering);
        } else if (nc_g2.len == 0) {
            var ordering: std.ArrayList(ComplexSelectorComponent) = .empty;
            try cloneGroupsToOrdering(allocator, prefix1, nc_g1, &ordering);
            try chunk.append(allocator, ordering);
        } else {
            {
                var ordering: std.ArrayList(ComplexSelectorComponent) = .empty;
                try cloneGroupsToOrdering(allocator, prefix1, nc_g1, &ordering);
                try cloneGroupsToOrdering(allocator, prefix2, nc_g2, &ordering);
                try chunk.append(allocator, ordering);
            }
            {
                var ordering: std.ArrayList(ComplexSelectorComponent) = .empty;
                try cloneGroupsToOrdering(allocator, prefix2, nc_g2, &ordering);
                try cloneGroupsToOrdering(allocator, prefix1, nc_g1, &ordering);
                try chunk.append(allocator, ordering);
            }
        }
        try chunks.append(allocator, chunk);
        // Use the more specific group as anchor (from groupSelectForLcs)
        const anchor_g = if (pair.anchor_source == 0)
            groups1.items[gidx1]
        else
            groups2.items[gidx2];
        const anchor_prefix = if (pair.anchor_source == 0) prefix1 else prefix2;
        _ = anchor_prefix;
        try anchors.append(allocator, .{ .start = anchor_g.start, .end = anchor_g.end, .source = pair.anchor_source });

        gpos1 = gidx1 + 1;
        gpos2 = gidx2 + 1;
    }

    // Trailing non-common groups
    const trailing_g1 = groups1.items[gpos1..];
    const trailing_g2 = groups2.items[gpos2..];
    if (trailing_g1.len > 0 or trailing_g2.len > 0) {
        var chunk: Chunk = .empty;
        try chunk.ensureTotalCapacity(allocator, 2);
        if (trailing_g1.len == 0) {
            var ordering: std.ArrayList(ComplexSelectorComponent) = .empty;
            try cloneGroupsToOrdering(allocator, prefix2, trailing_g2, &ordering);
            try chunk.append(allocator, ordering);
        } else if (trailing_g2.len == 0) {
            var ordering: std.ArrayList(ComplexSelectorComponent) = .empty;
            try cloneGroupsToOrdering(allocator, prefix1, trailing_g1, &ordering);
            try chunk.append(allocator, ordering);
        } else {
            {
                var ordering: std.ArrayList(ComplexSelectorComponent) = .empty;
                try cloneGroupsToOrdering(allocator, prefix1, trailing_g1, &ordering);
                try cloneGroupsToOrdering(allocator, prefix2, trailing_g2, &ordering);
                try chunk.append(allocator, ordering);
            }
            {
                var ordering: std.ArrayList(ComplexSelectorComponent) = .empty;
                try cloneGroupsToOrdering(allocator, prefix2, trailing_g2, &ordering);
                try cloneGroupsToOrdering(allocator, prefix1, trailing_g1, &ordering);
                try chunk.append(allocator, ordering);
            }
        }
        try chunks.append(allocator, chunk);
    }

    // Cartesian product of all chunks
    var prefixes: std.ArrayList(ComplexSelector) = .empty;
    defer {
        for (prefixes.items) |*p| p.deinit();
        prefixes.deinit(allocator);
    }
    {
        var empty_sel = ComplexSelector.init(allocator);
        try prefixes.append(allocator, empty_sel);
        _ = &empty_sel;
    }

    for (chunks.items, 0..) |chunk, chunk_idx| {
        var new_prefixes: std.ArrayList(ComplexSelector) = .empty;
        errdefer {
            for (new_prefixes.items) |*p| p.deinit();
            new_prefixes.deinit(allocator);
        }
        const new_prefix_cap = std.math.mul(usize, chunk.items.len, prefixes.items.len) catch std.math.maxInt(usize);
        try new_prefixes.ensureTotalCapacity(allocator, new_prefix_cap);

        for (chunk.items) |ordering| {
            for (prefixes.items) |*prefix| {
                var new_sel = try prefix.clone(allocator);
                errdefer new_sel.deinit();

                if (ordering.items.len > 0) {
                    if (new_sel.components.items.len > 0) {
                        try new_sel.components.append(allocator, .{ .combinator = .descendant });
                    }
                    for (ordering.items) |comp| {
                        switch (comp) {
                            .compound => |cs| try new_sel.components.append(allocator, .{ .compound = try cs.clone(allocator) }),
                            .combinator => |cb| try new_sel.components.append(allocator, .{ .combinator = cb }),
                        }
                    }
                }

                // Append the LCS anchor group (from the more specific source)
                if (chunk_idx < anchors.items.len) {
                    const anchor = anchors.items[chunk_idx];
                    const anchor_src = if (anchor.source == 0) prefix1 else prefix2;
                    if (new_sel.components.items.len > 0) {
                        try new_sel.components.append(allocator, .{ .combinator = .descendant });
                    }
                    for (anchor_src[anchor.start..anchor.end]) |comp| {
                        switch (comp) {
                            .compound => |cs| try new_sel.components.append(allocator, .{ .compound = try cs.clone(allocator) }),
                            .combinator => |cb| try new_sel.components.append(allocator, .{ .combinator = cb }),
                        }
                    }
                }

                try new_prefixes.append(allocator, new_sel);
            }
        }

        for (prefixes.items) |*p| p.deinit();
        prefixes.deinit(allocator);
        prefixes = new_prefixes;
    }

    // Deduplicate and move to results
    try results.ensureUnusedCapacity(allocator, prefixes.items.len);
    for (prefixes.items) |*p| {
        var is_dup = false;
        for (results.items) |*existing| {
            if (complexSelectorEql(existing, p)) {
                is_dup = true;
                break;
            }
        }
        if (!is_dup) {
            try results.append(allocator, p.*);
            p.* = ComplexSelector.init(allocator); // moved
        }
    }

    // Post-filter: remove results where a rootish compound (:root/:host/:host-context)
    // appears in a non-initial position (as a descendant). Such selectors are
    // semantically impossible.
    {
        var write_idx: usize = 0;
        for (results.items) |*r| {
            if (complexHasRootishNonInitial(r)) {
                r.deinit();
            } else {
                results.items[write_idx] = r.*;
                write_idx += 1;
            }
        }
        results.shrinkRetainingCapacity(write_idx);
    }

    return results;
}

// ============================================================================
// trim
// ============================================================================

fn complexSharesLeadingStandaloneTypeSelector(
    broader: *const ComplexSelector,
    narrower: *const ComplexSelector,
) bool {
    if (broader.components.items.len == 0 or narrower.components.items.len == 0) return false;
    if (broader.components.items[0] != .compound or narrower.components.items[0] != .compound) return false;

    const b_first = broader.components.items[0].compound.simple_selectors.items;
    const n_first = narrower.components.items[0].compound.simple_selectors.items;
    if (b_first.len != 1 or n_first.len != 1) return false;
    if (b_first[0] != .type_selector or n_first[0] != .type_selector) return false;
    return std.mem.eql(u8, b_first[0].type_selector, n_first[0].type_selector);
}

/// Remove selectors that are subsets of other selectors in the list.
pub fn trimWithMetadata(
    allocator: std.mem.Allocator,
    selectors: *std.ArrayList(ComplexSelector),
    is_first_pass_list: ?*std.ArrayList(bool),
    orig_groups_list: ?*std.ArrayList(usize),
    eval_orders_list: ?*std.ArrayList(u32),
) !void {
    _ = allocator;
    if (selectors.items.len <= 1) return;
    const is_first_pass = if (is_first_pass_list) |list| list.items else &.{};
    const orig_groups = if (orig_groups_list) |list| list.items else &.{};
    const eval_orders = if (eval_orders_list) |list| list.items else &.{};

    //Track removal reason for each selector so we can fix superseded -> broader chains.
    const RemovalReason = enum { none, duplicate, superseded, broader };
    var removal_reason: [256]RemovalReason = .{.none} ** 256;
    var superseded_by: [256]usize = .{0} ** 256;
    const len = @min(selectors.items.len, 256);

    for (0..len) |i| {
        if (removal_reason[i] != .none) continue;
        for (0..len) |j| {
            if (i == j or removal_reason[j] != .none) continue;
            // Remove exact duplicates (keep the first occurrence)
            if (complexSelectorEql(&selectors.items[i], &selectors.items[j])) {
                if (i < eval_orders.len and j < eval_orders.len and eval_orders[i] != eval_orders[j]) {
                    if (eval_orders[i] > eval_orders[j]) {
                        removal_reason[i] = .duplicate;
                        break;
                    }
                    removal_reason[j] = .duplicate;
                    continue;
                }
                if (i < orig_groups.len and j < orig_groups.len and
                    orig_groups[i] != orig_groups[j])
                {
                    removal_reason[i] = .duplicate;
                    break;
                }
                if (j > i) {
                    removal_reason[j] = .duplicate;
                }
                continue;
            }
            // Remove i if j supersedes it (e.g., :is(.c) is superseded by :is(.c, .d))
            //Skip cross-group supersedence via :not() extras -- selectors from
            // different originals (.b:focus from extending orig0 vs
            // .b:focus:not(:hover) from extending orig1) are independent and
            // the broader one must survive for correct output.
            {
                const cross_group = i < orig_groups.len and j < orig_groups.len and
                    orig_groups[i] != orig_groups[j];
                const both_first_pass = i < is_first_pass.len and j < is_first_pass.len and
                    is_first_pass[i] and is_first_pass[j];
                const same_group_both_fp = both_first_pass and
                    i < orig_groups.len and j < orig_groups.len and
                    orig_groups[i] == orig_groups[j];
                if (!cross_group and !same_group_both_fp and
                    complexIsSupersededBy(&selectors.items[i], &selectors.items[j]))
                {
                    if ((complexHasSiblingCombinator(&selectors.items[j]) or
                        complexHasSiblingCombinator(&selectors.items[i])) and
                        narrowerKeepsFinalTrimStatefulExtras(&selectors.items[j], &selectors.items[i]))
                    {
                        continue;
                    }
                    removal_reason[i] = .superseded;
                    superseded_by[i] = j;
                    break;
                }
            }
            // Remove i if j is a broader (more general) selector than i.
            // Exception: keep i when its last compound has extra pseudo-classes
            // that j's doesn't (preserves specificity for stateful matching).
            if (complexIsBroaderThan(&selectors.items[j], &selectors.items[i])) {
                const both_first_pass = blk_bfp: {
                    if (i >= is_first_pass.len or j >= is_first_pass.len) break :blk_bfp false;
                    break :blk_bfp is_first_pass[i] and is_first_pass[j];
                };
                // Skip when BOTH are first-pass (direct extensions) from the
                //SAME original group -- they come from different extenders
                // (per-ext_i dedup in the first pass ensures one entry per
                // extension per compound) and must both survive regardless of
                // whether one is a superset of the other.
                const same_group_both_fp = blk_sg: {
                    if (!both_first_pass) break :blk_sg false;
                    if (i >= orig_groups.len or j >= orig_groups.len) break :blk_sg false;
                    break :blk_sg orig_groups[i] == orig_groups[j];
                };
                if (same_group_both_fp) continue;
                const cross_group_first_pass_type_prefixed = blk_cgfp: {
                    if (!both_first_pass) break :blk_cgfp false;
                    if (i >= orig_groups.len or j >= orig_groups.len) break :blk_cgfp false;
                    if (orig_groups[i] == orig_groups[j]) break :blk_cgfp false;
                    break :blk_cgfp complexSharesLeadingStandaloneTypeSelector(
                        &selectors.items[j],
                        &selectors.items[i],
                    );
                };
                if (cross_group_first_pass_type_prefixed) continue;
                const same_group_transitive_specificity = blk_sgts: {
                    if (both_first_pass) break :blk_sgts false;
                    if (i >= is_first_pass.len or j >= is_first_pass.len) break :blk_sgts false;
                    if (is_first_pass[i] or is_first_pass[j]) break :blk_sgts false;
                    if (i >= orig_groups.len or j >= orig_groups.len) break :blk_sgts false;
                    if (orig_groups[i] != orig_groups[j]) break :blk_sgts false;
                    const narrow_spec = complexSpecificity(&selectors.items[i]);
                    const broad_spec = complexSpecificity(&selectors.items[j]);
                    break :blk_sgts specificityGte(narrow_spec, broad_spec) and !specificityGte(broad_spec, narrow_spec);
                };
                if (same_group_transitive_specificity) continue;
                // Selectors produced from different original selector branches
                // must both survive even when one is broader than the other.
                // They represent distinct originals in the same comma list.
                // Exception: when j is a true superselector of i (matches every
                // element i matches), i is fully redundant and can be removed.
                // e.g., `.foo[data-toggle]` supersedes `.foo[data-toggle]:hover`.
                if (i < orig_groups.len and j < orig_groups.len and
                    orig_groups[i] != orig_groups[j])
                {
                    // Direct first-pass selectors from distinct original list
                    // members must both survive for single-compound state
                    // variants (e.g. `.a:selected` and `.a:selected:focus`
                    // emitted from `&:focus, &`).
                    if (both_first_pass and
                        selectors.items[i].components.items.len == 1 and
                        selectors.items[j].components.items.len == 1)
                    {
                        continue;
                    }
                    // Cross-group: only remove when j is a true superselector
                    // of i. Applies to both single-compound and multi-compound
                    // selectors (e.g. `.b:focus` supersedes `.b:focus:not(:hover)`
                    // generated from different original selector list members).
                    if (selector_mod.complexIsSuperSelector(&selectors.items[j], &selectors.items[i])) {
                        removal_reason[i] = .broader;
                        break;
                    }
                    continue;
                }
                // In circular extends on single-compound selectors, a direct
                // (first-pass) result can be broader than a transitive chain
                // result from the same original.  Both must survive because
                // they represent distinct extend paths.  Only skip when both
                // selectors are single-compound, the broader has no pseudos,
                // and the broader is first-pass while narrower is not.
                if (!same_group_both_fp) {
                    const circ_single_compound = blk_csc: {
                        if (i >= orig_groups.len or j >= orig_groups.len) break :blk_csc false;
                        if (orig_groups[i] != orig_groups[j]) break :blk_csc false;
                        if (j >= is_first_pass.len or i >= is_first_pass.len) break :blk_csc false;
                        if (!is_first_pass[j] or is_first_pass[i]) break :blk_csc false;
                        // Both must be single-compound selectors
                        if (selectors.items[i].components.items.len != 1) break :blk_csc false;
                        if (selectors.items[j].components.items.len != 1) break :blk_csc false;
                        const j_last = getLastCompound(&selectors.items[j]) orelse break :blk_csc false;
                        for (j_last.simple_selectors.items) |ss| {
                            if (ss == .pseudo_class or ss == .pseudo_element) break :blk_csc false;
                        }
                        break :blk_csc true;
                    };
                    if (circ_single_compound) continue;
                }
                var narrower_has_extra_pseudos = narrowerKeepsFinalTrimStatefulExtras(
                    &selectors.items[j],
                    &selectors.items[i],
                );
                if (narrower_has_extra_pseudos and !both_first_pass and
                    !complexHasSiblingCombinator(&selectors.items[j]) and
                    !complexHasSiblingCombinator(&selectors.items[i]) and
                    !narrowerHasWhitelistedLastCompoundPseudoExtras(&selectors.items[j], &selectors.items[i]))
                {
                    narrower_has_extra_pseudos = false;
                }
                if (!narrower_has_extra_pseudos) {
                    removal_reason[i] = .broader;
                    break;
                }
            }
        }
    }

    // Post-pass: restore superseded items whose superseder was broader-removed.
    // Prevents the chain: A superseded by B, B broader-removed by C,
    //both A and B removed -- A should survive (extend-result-of-extend test).
    // Only restore when superseder was broader-removed (not duplicate/superseded).
    for (0..len) |i| {
        if (removal_reason[i] == .superseded) {
            const sup = superseded_by[i];
            if (sup < len and removal_reason[sup] == .broader) {
                removal_reason[i] = .none;
            }
        }
    }

    // Remove marked selectors in reverse order
    var idx: usize = len;
    while (idx > 0) {
        idx -= 1;
        if (removal_reason[idx] != .none) {
            var removed = selectors.orderedRemove(idx);
            removed.deinit();
            if (is_first_pass_list) |list| {
                _ = list.orderedRemove(idx);
            }
            if (orig_groups_list) |list| {
                _ = list.orderedRemove(idx);
            }
            if (eval_orders_list) |list| {
                _ = list.orderedRemove(idx);
            }
        }
    }
}

pub fn trim(
    allocator: std.mem.Allocator,
    selectors: *std.ArrayList(ComplexSelector),
    is_first_pass: []const bool,
    orig_groups: []const usize,
) !void {
    var is_first_pass_copy: ?std.ArrayList(bool) = null;
    var orig_groups_copy: ?std.ArrayList(usize) = null;

    if (is_first_pass.len > 0) {
        var list: std.ArrayList(bool) = .empty;
        defer list.deinit(allocator);
        try list.appendSlice(allocator, is_first_pass);
        is_first_pass_copy = list;
    }
    if (orig_groups.len > 0) {
        var list: std.ArrayList(usize) = .empty;
        defer list.deinit(allocator);
        try list.appendSlice(allocator, orig_groups);
        orig_groups_copy = list;
    }

    try trimWithMetadata(
        allocator,
        selectors,
        if (is_first_pass_copy) |*list| list else null,
        if (orig_groups_copy) |*list| list else null,
        null,
    );
}
