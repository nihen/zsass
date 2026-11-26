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

fn isLegacyPseudoElementName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "before") or
        std.ascii.eqlIgnoreCase(name, "after") or
        std.ascii.eqlIgnoreCase(name, "first-line") or
        std.ascii.eqlIgnoreCase(name, "first-letter");
}

fn compoundSpecificity(compound: *const CompoundSelector) Specificity {
    var spec = Specificity{ .a = 0, .b = 0, .c = 0 };
    for (compound.simple_selectors.items) |ss| {
        switch (ss) {
            .id => spec.a += 1,
            .class, .attribute, .placeholder => spec.b += 1,
            .pseudo_class => |ps| {
                // `:where()` adds nothing, whatever it holds.
                if (std.ascii.eqlIgnoreCase(ps.name, "where")) continue;
                // `:before` and its kin are pseudo-elements written with
                // one colon.
                if (ps.selector == null and isLegacyPseudoElementName(ps.name)) {
                    spec.c += 1;
                    continue;
                }
                // `:nth-child(2n of S)` counts itself and `S`.
                if (ps.selector != null and selector_mod.isNthWithOfPseudo(ps.name)) spec.b += 1;
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
        h ^= @as(u64, @backingInt(op)) *% 0x100000001b3;
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
                h ^= @as(u64, @backingInt(comb)) *% 0x100000001b3;
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
