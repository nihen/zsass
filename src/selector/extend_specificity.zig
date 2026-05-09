const std = @import("std");
const selector_mod = @import("selector.zig");

/// FNV-1a hash with a seed byte prepended, used for structural selector hashing.
/// Faster than Wyhash for short strings (selector names are typically <20 bytes).
fn fnvHashSeeded(seed: u8, data: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    h = (h ^ seed) *% 0x100000001b3;
    for (data) |b| {
        h = (h ^ b) *% 0x100000001b3;
    }
    return h;
}
const SelectorList = selector_mod.SelectorList;
const ComplexSelector = selector_mod.ComplexSelector;
const CompoundSelector = selector_mod.CompoundSelector;
const SimpleSelector = selector_mod.SimpleSelector;
const Combinator = selector_mod.Combinator;

/// Get the last compound selector from a complex selector.
pub fn getLastCompound(complex: *const ComplexSelector) ?*const CompoundSelector {
    var i: usize = complex.components.items.len;
    while (i > 0) {
        i -= 1;
        switch (complex.components.items[i]) {
            .compound => |*c| return c,
            .combinator => {},
        }
    }
    return null;
}

/// Check if a compound selector contains all simple selectors of the target.
pub fn compoundContainsTarget(compound: *const CompoundSelector, target: *const CompoundSelector) bool {
    for (target.simple_selectors.items) |target_ss| {
        var found = false;
        for (compound.simple_selectors.items) |compound_ss| {
            if (simpleSelectorEql(target_ss, compound_ss)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

// ============================================================================
// Specificity comparison, equality, and structural hashing
// ============================================================================

pub fn complexIsBroaderThan(broader: *const ComplexSelector, narrower: *const ComplexSelector) bool {
    if (broader.components.items.len > narrower.components.items.len) return false;
    const broader_last = getLastCompound(broader) orelse return false;
    const narrower_last = getLastCompound(narrower) orelse return false;
    // If one has a pseudo-element and the other doesn't, they target different things.
    {
        const hasPseudoElement = struct {
            fn check(compound: *const CompoundSelector) bool {
                for (compound.simple_selectors.items) |ss| {
                    switch (ss) {
                        .pseudo_element => return true,
                        .pseudo_class => |ps| {
                            if (std.ascii.eqlIgnoreCase(ps.name, "before") or
                                std.ascii.eqlIgnoreCase(ps.name, "after") or
                                std.ascii.eqlIgnoreCase(ps.name, "first-line") or
                                std.ascii.eqlIgnoreCase(ps.name, "first-letter")) return true;
                        },
                        else => {},
                    }
                }
                return false;
            }
        }.check;
        if (hasPseudoElement(narrower_last) != hasPseudoElement(broader_last)) return false;
    }
    //Universal selector (*) matches all elements -- it's broader than any compound.
    const broader_is_universal = compoundIsAnyUniversal(broader_last);
    if (!broader_is_universal) {
        if (broader_last.simple_selectors.items.len > narrower_last.simple_selectors.items.len) return false;
    }
    // All of broader's simple selectors must appear in narrower's last compound.
    // Exception: universal selector (*) implicitly matches everything.
    if (!broader_is_universal) {
        for (broader_last.simple_selectors.items) |bs| {
            var found_b = false;
            for (narrower_last.simple_selectors.items) |ns| {
                if (simpleSelectorEql(bs, ns)) {
                    found_b = true;
                    break;
                }
            }
            if (!found_b) return false;
        }
    }
    // If broader has a non-descendant combinator before its last compound,
    // narrower must have the same combinator before its last compound AND
    // broader's penultimate compound must be contained in narrower's penultimate.
    // e.g., ".a.b + y" is NOT broader than ".a.b ~ .a + y" because the compound
    // immediately before "+ y" differs (.a.b vs .a).
    {
        const b_comb_before_last = getCombBeforeLastCompound(broader);
        if (b_comb_before_last != null and b_comb_before_last.? != .descendant) {
            const n_comb_before_last = getCombBeforeLastCompound(narrower);
            if (n_comb_before_last == null or n_comb_before_last.? != b_comb_before_last.?) return false;
            const b_penult = getPenultimateCompound(broader);
            const n_penult = getPenultimateCompound(narrower);
            if (b_penult != null and n_penult != null) {
                if (!compoundContainsTarget(n_penult.?, b_penult.?)) return false;
            }
        }
    }
    // If same component count, broader must have strictly fewer simple selectors
    // OR broader_last is universal and narrower_last is not (universal matches everything)
    // OR same compounds but broader uses more permissive combinators (desc > child, ~ > +)
    if (broader.components.items.len == narrower.components.items.len) {
        if (broader_is_universal and !compoundIsAnyUniversal(narrower_last)) return true;
        if (broader.components.items.len == 1 and narrower.components.items.len == 1 and
            broader_last.simple_selectors.items.len < narrower_last.simple_selectors.items.len)
        {
            // Before declaring broader is truly broader, check that narrower
            // has genuinely different selectors. If narrower only has duplicates
            // of broader's selectors (e.g., .foo.foo vs .foo), they match the
            // same elements and neither is strictly broader.
            var has_unique_narrower_selector = false;
            for (narrower_last.simple_selectors.items) |ns| {
                var found_in_broader = false;
                for (broader_last.simple_selectors.items) |bs| {
                    if (simpleSelectorEql(bs, ns)) {
                        found_in_broader = true;
                        break;
                    }
                }
                if (!found_in_broader) {
                    has_unique_narrower_selector = true;
                    break;
                }
            }
            if (has_unique_narrower_selector) return true;
        }
        // Check if each broader compound is a subset of the corresponding narrower
        //compound. e.g., ".a .d" is broader than ".a.b .d" because .a  <=  .a.b
        // and .d = .d (with at least one strictly smaller compound).
        {
            var all_broader_contained = true;
            var any_strictly_contained = false;
            var has_broader_comb = false;
            var has_narrower_comb = false;
            for (broader.components.items, narrower.components.items) |bc, nc| {
                if (bc == .compound and nc == .compound) {
                    if (!compoundContainsTarget(&nc.compound, &bc.compound)) {
                        all_broader_contained = false;
                        break;
                    }
                    if (bc.compound.simple_selectors.items.len < nc.compound.simple_selectors.items.len) {
                        any_strictly_contained = true;
                    }
                } else if (bc == .combinator and nc == .combinator) {
                    if (bc.combinator != nc.combinator) {
                        // Check if broader's comb is more permissive
                        if (bc.combinator == .descendant and nc.combinator == .child) {
                            has_broader_comb = true;
                        } else if (bc.combinator == .general_sibling and nc.combinator == .next_sibling) {
                            has_broader_comb = true;
                        } else {
                            has_narrower_comb = true;
                        }
                    }
                } else {
                    all_broader_contained = false;
                    break;
                }
            }
            if (all_broader_contained and (any_strictly_contained or (has_broader_comb and !has_narrower_comb))) return true;
        }
        return false;
    }
    // broader has fewer components than narrower.
    // Check if broader's compounds form an order-preserving subsequence of narrower's
    // compounds (each broader compound's simple selectors are contained in the matched
    // narrower compound). This ensures broader truly matches a superset.
    //e.g., "a c" is broader than "d a c" because [a -> a, c -> c] matches in order.
    //"a c" is NOT broader than "b d c" because [a -> ?] has no match.
    var b_comps: [32]*const CompoundSelector = undefined;
    var b_count: usize = 0;
    for (broader.components.items) |*c| {
        if (c.* == .compound and b_count < 32) {
            b_comps[b_count] = &c.compound;
            b_count += 1;
        }
    }
    var n_comps: [64]*const CompoundSelector = undefined;
    var n_count: usize = 0;
    for (narrower.components.items) |*c| {
        if (c.* == .compound and n_count < 64) {
            n_comps[n_count] = &c.compound;
            n_count += 1;
        }
    }
    var n_idx: usize = 0;
    for (0..b_count) |bi| {
        var found = false;
        while (n_idx < n_count) {
            if (compoundContainsTarget(n_comps[n_idx], b_comps[bi])) {
                n_idx += 1;
                found = true;
                break;
            }
            n_idx += 1;
        }
        if (!found) return false;
    }
    return true;
}

pub fn narrowerHasWhitelistedLastCompoundPseudoExtras(
    broader: *const ComplexSelector,
    narrower: *const ComplexSelector,
) bool {
    if (broader.components.items.len != narrower.components.items.len) return false;
    const last_idx = broader.components.items.len - 1;
    var found_any = false;
    for (broader.components.items, narrower.components.items, 0..) |bcomp, ncomp, idx| {
        switch (bcomp) {
            .combinator => |bcomb| switch (ncomp) {
                .combinator => |ncomb| if (bcomb != ncomb) return false,
                else => return false,
            },
            .compound => |*bcompound| switch (ncomp) {
                .compound => |*ncompound| {
                    for (ncompound.simple_selectors.items) |nss| {
                        var found = false;
                        for (bcompound.simple_selectors.items) |bss| {
                            if (simpleSelectorEql(nss, bss)) {
                                found = true;
                                break;
                            }
                        }
                        if (found) continue;
                        if (idx != last_idx) return false;
                        switch (nss) {
                            .pseudo_class => |ps| {
                                const keep =
                                    std.ascii.eqlIgnoreCase(ps.name, "active") or
                                    std.ascii.eqlIgnoreCase(ps.name, "focus") or
                                    std.ascii.eqlIgnoreCase(ps.name, "hover") or
                                    std.ascii.eqlIgnoreCase(ps.name, "valid") or
                                    std.ascii.eqlIgnoreCase(ps.name, "invalid");
                                if (!keep) return false;
                                found_any = true;
                            },
                            else => return false,
                        }
                    }
                },
                else => return false,
            },
        }
    }
    return found_any;
}

pub fn complexHasAnyPseudo(sel: *const ComplexSelector) bool {
    for (sel.components.items) |comp| {
        if (comp != .compound) continue;
        for (comp.compound.simple_selectors.items) |ss| {
            switch (ss) {
                .pseudo_class, .pseudo_element => return true,
                else => {},
            }
        }
    }
    return false;
}

pub fn complexHasSiblingCombinator(sel: *const ComplexSelector) bool {
    for (sel.components.items) |comp| {
        if (comp != .combinator) continue;
        switch (comp.combinator) {
            .next_sibling, .general_sibling => return true,
            else => {},
        }
    }
    return false;
}

fn getCombBeforeLastCompound(sel: *const ComplexSelector) ?Combinator {
    const items = sel.components.items;
    // Find last compound, then look at what's before it
    var i: usize = items.len;
    while (i > 0) {
        i -= 1;
        if (items[i] == .compound) {
            // Found last compound; check element before it
            if (i > 0) {
                return switch (items[i - 1]) {
                    .combinator => |c| c,
                    .compound => .descendant,
                };
            }
            return null;
        }
    }
    return null;
}

fn getPenultimateCompound(sel: *const ComplexSelector) ?*const CompoundSelector {
    const items = sel.components.items;
    var found_last = false;
    var i: usize = items.len;
    while (i > 0) {
        i -= 1;
        if (items[i] == .compound) {
            if (!found_last) {
                found_last = true;
                continue;
            }
            return &items[i].compound;
        }
    }
    return null;
}

pub fn narrowerKeepsStatefulExtras(
    broader: *const ComplexSelector,
    narrower: *const ComplexSelector,
) bool {
    if (broader.components.items.len != narrower.components.items.len) return false;

    var has_sibling_combinator = false;
    var last_compound_idx: usize = 0;
    for (broader.components.items, 0..) |comp, idx| {
        switch (comp) {
            .combinator => |comb| switch (comb) {
                .next_sibling, .general_sibling => has_sibling_combinator = true,
                else => {},
            },
            .compound => last_compound_idx = idx,
        }
    }

    var extra_pseudo_count: usize = 0;
    var extra_on_last_compound = false;
    for (broader.components.items, narrower.components.items, 0..) |bcomp, ncomp, idx| {
        switch (bcomp) {
            .combinator => |bcomb| switch (ncomp) {
                .combinator => |ncomb| {
                    if (bcomb != ncomb) return false;
                },
                else => return false,
            },
            .compound => |*bcompound| switch (ncomp) {
                .compound => |*ncompound| {
                    for (ncompound.simple_selectors.items) |nss| {
                        var found = false;
                        for (bcompound.simple_selectors.items) |bss| {
                            if (simpleSelectorEql(nss, bss)) {
                                found = true;
                                break;
                            }
                        }
                        if (found) continue;
                        switch (nss) {
                            .pseudo_class => {
                                extra_pseudo_count += 1;
                                if (idx == last_compound_idx) extra_on_last_compound = true;
                            },
                            .pseudo_element => return false,
                            else => return false,
                        }
                    }
                },
                else => return false,
            },
        }
    }

    if (extra_pseudo_count == 0) return false;
    return has_sibling_combinator or extra_on_last_compound;
}

pub fn narrowerKeepsFinalTrimStatefulExtras(
    broader: *const ComplexSelector,
    narrower: *const ComplexSelector,
) bool {
    if (narrowerKeepsStatefulExtras(broader, narrower)) return true;
    if (broader.components.items.len != narrower.components.items.len) return false;

    var extra_pseudo_class_count: usize = 0;
    const last_idx = broader.components.items.len - 1;
    for (broader.components.items, narrower.components.items, 0..) |bcomp, ncomp, idx| {
        switch (bcomp) {
            .combinator => |bcomb| switch (ncomp) {
                .combinator => |ncomb| {
                    if (bcomb != ncomb) return false;
                },
                else => return false,
            },
            .compound => |*bcompound| switch (ncomp) {
                .compound => |*ncompound| {
                    for (ncompound.simple_selectors.items) |nss| {
                        var found = false;
                        for (bcompound.simple_selectors.items) |bss| {
                            if (simpleSelectorEql(nss, bss)) {
                                found = true;
                                break;
                            }
                        }
                        if (found) continue;
                        if (idx != last_idx) return false;
                        switch (nss) {
                            .pseudo_class => extra_pseudo_class_count += 1,
                            else => return false,
                        }
                    }
                },
                else => return false,
            },
        }
    }

    return extra_pseudo_class_count > 0;
}

pub const Specificity = struct { a: u16, b: u16, c: u16 };

pub fn complexSpecificity(sel: *const ComplexSelector) Specificity {
    var spec = Specificity{ .a = 0, .b = 0, .c = 0 };
    for (sel.components.items) |comp| {
        if (comp == .compound) {
            const cs = compoundSpecificity(&comp.compound);
            spec.a += cs.a;
            spec.b += cs.b;
            spec.c += cs.c;
        }
    }
    return spec;
}

fn compoundSpecificity(compound: *const CompoundSelector) Specificity {
    var spec = Specificity{ .a = 0, .b = 0, .c = 0 };
    for (compound.simple_selectors.items) |ss| {
        switch (ss) {
            .id => spec.a += 1,
            .class, .attribute, .placeholder => spec.b += 1,
            .pseudo_class => |ps| {
                if (ps.selector) |sel_list| {
                    //:not(), :is(), :has() etc. -- specificity of most specific argument
                    var max_inner = Specificity{ .a = 0, .b = 0, .c = 0 };
                    for (sel_list.selectors.items) |inner| {
                        const inner_spec = complexSpecificity(&inner);
                        if (specificityGt(inner_spec, max_inner)) max_inner = inner_spec;
                    }
                    spec.a += max_inner.a;
                    spec.b += max_inner.b;
                    spec.c += max_inner.c;
                } else {
                    spec.b += 1;
                }
            },
            .pseudo_element => spec.c += 1,
            .type_selector => spec.c += 1,
            .universal, .parent => {},
        }
    }
    return spec;
}

fn specificityGt(a: Specificity, b: Specificity) bool {
    if (a.a != b.a) return a.a > b.a;
    if (a.b != b.b) return a.b > b.b;
    return a.c > b.c;
}

pub fn specificityGte(a: Specificity, b: Specificity) bool {
    if (a.a != b.a) return a.a > b.a;
    if (a.b != b.b) return a.b > b.b;
    return a.c >= b.c;
}

fn compoundIsAnyUniversal(compound: *const CompoundSelector) bool {
    if (compound.simple_selectors.items.len != 1) return false;
    return switch (compound.simple_selectors.items[0]) {
        .universal => true,
        .type_selector => |name| std.mem.eql(u8, name, "*|*"),
        else => false,
    };
}

pub fn complexHasUniversalLastCompoundNoOp(broader: *const ComplexSelector, narrower: *const ComplexSelector) bool {
    if (broader.components.items.len != narrower.components.items.len) return false;

    const broader_last = getLastCompound(broader) orelse return false;
    const narrower_last = getLastCompound(narrower) orelse return false;
    if (!compoundIsAnyUniversal(broader_last)) return false;
    if (compoundSelectorEql(broader_last, narrower_last)) return false;

    var seen_last = false;
    var idx: usize = broader.components.items.len;
    while (idx > 0) {
        idx -= 1;
        const b = broader.components.items[idx];
        const n = narrower.components.items[idx];
        const b_tag: @TypeOf(std.meta.activeTag(b)) = b;
        const n_tag: @TypeOf(std.meta.activeTag(n)) = n;
        if (b_tag != n_tag) return false;

        switch (b) {
            .combinator => |comb| {
                if (comb != n.combinator) return false;
            },
            .compound => |bc| {
                if (!seen_last) {
                    seen_last = true;
                    continue;
                }
                if (!compoundSelectorEql(&bc, &n.compound)) return false;
            },
        }
    }

    return seen_last;
}

/// Returns true if complex selector `other` supersedes `self`, meaning `self`
/// can be dropped from the list when `other` is also present.
/// Two cases:
/// 1. `:is(.c)` is superseded by `:is(.c, .d)` (inner list extended)
/// 2. `:not(.c)` is superseded by `:not(.c):not(.d)` (compound extended with more :not()s)
pub fn complexIsSupersededBy(self_sel: *const ComplexSelector, other: *const ComplexSelector) bool {
    // Must have same number of components
    if (self_sel.components.items.len != other.components.items.len) return false;

    var any_superseded = false;
    for (self_sel.components.items, other.components.items) |sc, oc| {
        const sc_tag: @TypeOf(std.meta.activeTag(sc)) = sc;
        const oc_tag: @TypeOf(std.meta.activeTag(oc)) = oc;
        if (sc_tag != oc_tag) return false;

        switch (sc) {
            .combinator => |sc_comb| {
                if (sc_comb != oc.combinator) return false;
            },
            .compound => |sc_c| {
                const oc_c = oc.compound;
                if (!compoundIsSupersededBy(&sc_c, &oc_c, &any_superseded)) return false;
            },
        }
    }
    return any_superseded;
}

/// Returns true if compound `other` supersedes compound `self`.
/// Sets `any_superseded` to true if there was an actual difference (not exact equality).
/// Handles two cases:
/// 1. Same-count compounds where pseudo inner lists differ (:is(.c) vs :is(.c, .d))
/// 2. Compounds where `other` has all of `self`'s simple selectors PLUS more (:not(.c) vs :not(.c):not(.d))
fn compoundIsSupersededBy(
    self_c: *const CompoundSelector,
    other_c: *const CompoundSelector,
    any_superseded: *bool,
) bool {
    // Case 1: Same number of simple selectors - check if pseudo inner lists are extended
    if (self_c.simple_selectors.items.len == other_c.simple_selectors.items.len) {
        for (self_c.simple_selectors.items, other_c.simple_selectors.items) |ss, os| {
            const ss_tag: @TypeOf(std.meta.activeTag(ss)) = ss;
            const os_tag: @TypeOf(std.meta.activeTag(os)) = os;
            if (ss_tag != os_tag) return false;

            switch (ss) {
                .pseudo_class => |sps| {
                    const ops = os.pseudo_class;
                    if (!std.mem.eql(u8, sps.name, ops.name)) return false;
                    if (sps.selector != null and ops.selector != null) {
                        if (selectorListIsSubset(sps.selector.?, ops.selector.?)) {
                            if (!selectorListEql(sps.selector.?, ops.selector.?)) {
                                any_superseded.* = true;
                            }
                        } else {
                            return false;
                        }
                    } else if (!simpleSelectorEql(ss, os)) {
                        return false;
                    }
                },
                .pseudo_element => |sps| {
                    const ops = os.pseudo_element;
                    if (!std.mem.eql(u8, sps.name, ops.name)) return false;
                    if (sps.selector != null and ops.selector != null) {
                        if (selectorListIsSubset(sps.selector.?, ops.selector.?)) {
                            if (!selectorListEql(sps.selector.?, ops.selector.?)) {
                                any_superseded.* = true;
                            }
                        } else {
                            return false;
                        }
                    } else if (!simpleSelectorEql(ss, os)) {
                        return false;
                    }
                },
                else => {
                    if (!simpleSelectorEql(ss, os)) return false;
                },
            }
        }
        return true;
    }

    // Case 2: `other` has MORE simple selectors than `self`.
    // `self` is superseded if all of `self`'s simple selectors appear in `other`
    // AND the extra selectors in `other` are all :not() pseudo-classes.
    // This handles the :not() case: :not(.c) superseded by :not(.c):not(.d).
    //NOTE: For regular compounds, `.a.b` does NOT supersede `.a` -- `.a` is
    // broader (matches more elements). Only :not() additions make a compound
    // supersede a subset, because :not(.c):not(.d) is more restrictive than :not(.c).
    if (other_c.simple_selectors.items.len > self_c.simple_selectors.items.len) {
        var self_has_not = false;
        for (self_c.simple_selectors.items) |ss| {
            if (ss == .pseudo_class and std.ascii.eqlIgnoreCase(ss.pseudo_class.name, "not")) {
                self_has_not = true;
                break;
            }
        }
        if (!self_has_not) return false;

        // Check that all of self's simple selectors appear in other
        for (self_c.simple_selectors.items) |ss| {
            var found = false;
            for (other_c.simple_selectors.items) |os| {
                if (simpleSelectorEql(ss, os)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        // Only supersede if ALL extra selectors in other are :not() pseudo-classes
        var all_extra_are_not = true;
        for (other_c.simple_selectors.items) |os| {
            var in_self = false;
            for (self_c.simple_selectors.items) |ss| {
                if (simpleSelectorEql(os, ss)) {
                    in_self = true;
                    break;
                }
            }
            if (!in_self) {
                // This is an extra selector in other. Check if it's :not()
                switch (os) {
                    .pseudo_class => |ps| {
                        if (!std.ascii.eqlIgnoreCase(ps.name, "not")) {
                            all_extra_are_not = false;
                            break;
                        }
                    },
                    else => {
                        all_extra_are_not = false;
                        break;
                    },
                }
            }
        }
        if (all_extra_are_not) {
            any_superseded.* = true;
            return true;
        }
    }

    return false;
}

/// Returns true if all selectors in `subset` are also in `superset`.
fn selectorListIsSubset(subset: *const SelectorList, superset: *const SelectorList) bool {
    for (subset.selectors.items) |sub_complex| {
        var found = false;
        for (superset.selectors.items) |sup_complex| {
            if (complexSelectorEql(&sub_complex, &sup_complex) or
                complexIsCompoundNotSubsetOf(&sub_complex, &sup_complex))
            {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// Returns true if `subset` is a single compound whose simple selectors all
/// appear in `superset` (also a single compound), and the extra simple
/// selectors in `superset` are all :not() pseudo-classes.
/// This recognises `:not(.x)` as a subset of `:not(.x):not(.y)`.
fn complexIsCompoundNotSubsetOf(subset: *const ComplexSelector, superset: *const ComplexSelector) bool {
    if (subset.components.items.len != 1 or superset.components.items.len != 1) return false;
    if (subset.components.items[0] != .compound or superset.components.items[0] != .compound) return false;
    const sub_c = subset.components.items[0].compound;
    const sup_c = superset.components.items[0].compound;
    if (sup_c.simple_selectors.items.len <= sub_c.simple_selectors.items.len) return false;
    for (sub_c.simple_selectors.items) |sub_ss| {
        var found = false;
        for (sup_c.simple_selectors.items) |sup_ss| {
            if (simpleSelectorEql(sub_ss, sup_ss)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    for (sup_c.simple_selectors.items) |sup_ss| {
        var in_sub = false;
        for (sub_c.simple_selectors.items) |sub_ss| {
            if (simpleSelectorEql(sup_ss, sub_ss)) {
                in_sub = true;
                break;
            }
        }
        if (!in_sub) {
            if (sup_ss != .pseudo_class or
                !std.ascii.eqlIgnoreCase(sup_ss.pseudo_class.name, "not"))
            {
                return false;
            }
        }
    }
    return true;
}

pub fn complexSelectorEql(a: *const ComplexSelector, b: *const ComplexSelector) bool {
    if (a.components.items.len != b.components.items.len) return false;
    for (a.components.items, b.components.items) |ac, bc| {
        const tag_a: @TypeOf(std.meta.activeTag(ac)) = ac;
        const tag_b: @TypeOf(std.meta.activeTag(bc)) = bc;
        if (tag_a != tag_b) return false;
        switch (ac) {
            .compound => |ca| {
                if (!compoundSelectorEql(&ca, &bc.compound)) return false;
            },
            .combinator => |comb_a| {
                if (comb_a != bc.combinator) return false;
            },
        }
    }
    return true;
}

fn compoundMultisetHash(c: *const CompoundSelector) u64 {
    const items = c.simple_selectors.items;
    const n = items.len;
    if (n == 0) return 0;
    // Order-independent hash: XOR individual hashes with mixing.
    // This is O(n) vs the previous O(n log n) sort-based approach.
    // XOR is commutative so the result is independent of selector order.
    var xor_sum: u64 = 0;
    var add_sum: u64 = 0;
    for (items) |ss| {
        const h = simpleSelectorStructuralHash(ss);
        xor_sum ^= h;
        add_sum +%= h;
    }
    // Combine XOR and addition to reduce collision rate vs pure XOR.
    return xor_sum *% 0x100000001b3 ^ add_sum;
}

fn simpleSelectorStructuralHash(ss: SimpleSelector) u64 {
    return switch (ss) {
        .type_selector => |n| fnvHashSeeded(0x01, n),
        .class => |n| fnvHashSeeded(0x02, n),
        .id => |n| fnvHashSeeded(0x03, n),
        .placeholder => |n| fnvHashSeeded(0x04, n),
        .parent => 0x05,
        .universal => 0x06,
        .attribute => |a| attrStructuralHash(a),
        .pseudo_class => |p| pseudoStructuralHash(p) ^ 0x0a00000000000000,
        .pseudo_element => |p| pseudoStructuralHash(p) ^ 0x0b00000000000000,
    };
}

fn attrStructuralHash(a: selector_mod.AttributeSelector) u64 {
    var h = fnvHashSeeded(0x10, a.name);
    if (a.op) |op| {
        h ^= @as(u64, @intFromEnum(op)) *% 0x100000001b3;
    }
    if (a.value) |v| {
        h ^= fnvHashSeeded(0x11, v);
    }
    if (a.modifier) |m| {
        h ^= @as(u64, m) *% 0x100000001b3;
    }
    return h;
}

fn pseudoStructuralHash(p: selector_mod.PseudoSelector) u64 {
    var h = fnvHashSeeded(0x20, p.name);
    if (p.argument) |arg| {
        h ^= fnvHashSeeded(0x21, arg);
    }
    if (p.selector) |sl| {
        h ^= selectorListStructuralHash(sl);
    }
    return h;
}

fn selectorListStructuralHash(sl: *const SelectorList) u64 {
    var h: u64 = 0xd1310ba6adf49455;
    for (sl.selectors.items) |cx| {
        h ^= complexStructuralHash(&cx);
        h *%= 0x9e3779b97f4a7c15;
    }
    return h;
}

fn complexStructuralHash(c: *const ComplexSelector) u64 {
    var h: u64 = 0x243f6a8885a308d3;
    for (c.components.items) |comp| {
        switch (comp) {
            .compound => |co| {
                h ^= compoundMultisetHash(&co);
            },
            .combinator => |comb| {
                h ^= @as(u64, @intFromEnum(comb)) *% 0x100000001b3;
            },
        }
        h *%= 0x9e3779b97f4a7c15;
    }
    return h;
}

pub fn compoundSelectorEql(a: *const CompoundSelector, b: *const CompoundSelector) bool {
    if (a.simple_selectors.items.len != b.simple_selectors.items.len) return false;
    if (compoundMultisetHash(a) != compoundMultisetHash(b)) return false;
    for (a.simple_selectors.items) |sa| {
        var found = false;
        for (b.simple_selectors.items) |sb| {
            if (simpleSelectorEql(sa, sb)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

// ============================================================================
// SimpleSelector comparison helpers (duplicated from selector.zig since they
// are private there)
// ============================================================================

pub fn simpleSelectorEql(a: SimpleSelector, b: SimpleSelector) bool {
    const tag_a: @TypeOf(std.meta.activeTag(a)) = a;
    const tag_b: @TypeOf(std.meta.activeTag(b)) = b;
    if (tag_a != tag_b) return false;

    switch (a) {
        .type_selector => |na| return std.mem.eql(u8, na, b.type_selector),
        .class => |na| return std.mem.eql(u8, na, b.class),
        .id => |na| return std.mem.eql(u8, na, b.id),
        .placeholder => |na| return std.mem.eql(u8, na, b.placeholder),
        .parent => return true,
        .universal => return true,
        .attribute => |aa| {
            const ba = b.attribute;
            if (!std.mem.eql(u8, aa.name, ba.name)) return false;
            if (aa.op != ba.op) return false;
            if (aa.modifier != ba.modifier) return false;
            if (aa.value != null and ba.value != null) {
                return std.mem.eql(u8, aa.value.?, ba.value.?);
            }
            return aa.value == null and ba.value == null;
        },
        .pseudo_class => |pa| {
            const pb = b.pseudo_class;
            return pseudoSelectorEql(pa, pb);
        },
        .pseudo_element => |pa| {
            const pb = b.pseudo_element;
            return pseudoSelectorEql(pa, pb);
        },
    }
}

fn pseudoSelectorEql(a: selector_mod.PseudoSelector, b: selector_mod.PseudoSelector) bool {
    if (!std.mem.eql(u8, a.name, b.name)) return false;
    if (a.argument != null and b.argument != null) {
        if (!std.mem.eql(u8, a.argument.?, b.argument.?)) return false;
    } else if (a.argument != null or b.argument != null) {
        return false;
    }
    // Also compare inner selector lists (e.g., :is(.c) vs :is(.c, .d))
    if (a.selector != null and b.selector != null) {
        if (!selectorListEql(a.selector.?, b.selector.?)) return false;
    } else if (a.selector != null or b.selector != null) {
        return false;
    }
    return true;
}

fn selectorListEql(a: *const SelectorList, b: *const SelectorList) bool {
    if (a.selectors.items.len != b.selectors.items.len) return false;
    for (a.selectors.items, b.selectors.items) |ac, bc| {
        if (!complexSelectorEql(&ac, &bc)) return false;
    }
    return true;
}
