const std = @import("std");
const selector_mod = @import("selector.zig");
const SelectorList = selector_mod.SelectorList;
const ComplexSelector = selector_mod.ComplexSelector;
const CompoundSelector = selector_mod.CompoundSelector;
const extend_mod = @import("extend.zig");
const ApplyState = extend_mod.ApplyState;
const complexToCssAlloc = extend_mod.complexToCssAlloc;
const compoundContainsTarget = extend_mod.compoundContainsTarget;
const normalizeGeneratedCompoundClassOrder = extend_mod.normalizeGeneratedCompoundClassOrder;
const unification = @import("extend_unification.zig");
const unifyCompound = unification.unifyCompound;
const trim = unification.trim;
const trimWithMetadata = unification.trimWithMetadata;
const weavePaths = unification.weavePaths;

test "simple extend: .bar extends .foo" {
    const allocator = std.testing.allocator;

    // Parse the selector to extend: .foo
    var target_list = try selector_mod.parse(allocator, ".foo");
    defer target_list.deinit();

    // Parse the extender: .bar
    var extender = try selector_mod.parse(allocator, ".bar");
    defer extender.deinit();

    // Get the target compound
    var target_compound = try target_list.selectors.items[0].components.items[0].compound.clone(allocator);
    defer target_compound.deinit();

    // Create extension store
    var store = ApplyState.init(allocator);
    defer store.deinit();

    try store.addExtension(.{
        .extender = try extender.clone(allocator),
        .target = try target_compound.clone(allocator),
        .optional = false,
        .span = null,
    });

    // Apply extensions to ".foo"
    var result = try store.applySelectorExtensions(&target_list);
    defer result.deinit();

    // Should produce ".foo, .bar"
    try std.testing.expect(result.selectors.items.len >= 2);

    // Check that both .foo and .bar are present
    var has_foo = false;
    var has_bar = false;
    for (result.selectors.items) |sel| {
        const css = try complexToCssAlloc(allocator, sel);
        defer allocator.free(css);
        if (std.mem.eql(u8, css, ".foo")) has_foo = true;
        if (std.mem.eql(u8, css, ".bar")) has_bar = true;
    }
    try std.testing.expect(has_foo);
    try std.testing.expect(has_bar);
}

test "extend with combinators" {
    const allocator = std.testing.allocator;

    // Selector: .parent .foo
    var target_list = try selector_mod.parse(allocator, ".parent .foo");
    defer target_list.deinit();

    // Extender: .bar
    var extender = try selector_mod.parse(allocator, ".bar");
    defer extender.deinit();

    // Target: .foo
    var target_compound_list = try selector_mod.parse(allocator, ".foo");
    defer target_compound_list.deinit();
    var target_compound = try target_compound_list.selectors.items[0].components.items[0].compound.clone(allocator);
    defer target_compound.deinit();

    var store = ApplyState.init(allocator);
    defer store.deinit();

    try store.addExtension(.{
        .extender = try extender.clone(allocator),
        .target = try target_compound.clone(allocator),
        .optional = false,
        .span = null,
    });

    var result = try store.applySelectorExtensions(&target_list);
    defer result.deinit();

    // Should produce ".parent .foo, .parent .bar" (at minimum)
    try std.testing.expect(result.selectors.items.len >= 2);

    var has_parent_bar = false;
    for (result.selectors.items) |sel| {
        const css = try complexToCssAlloc(allocator, sel);
        defer allocator.free(css);
        if (std.mem.eql(u8, css, ".parent .bar")) has_parent_bar = true;
    }
    try std.testing.expect(has_parent_bar);
}

test "placeholder extend" {
    const allocator = std.testing.allocator;

    // Selector: %placeholder
    var target_list = try selector_mod.parse(allocator, "%placeholder");
    defer target_list.deinit();

    // Extender: .bar
    var extender = try selector_mod.parse(allocator, ".bar");
    defer extender.deinit();

    // Target: %placeholder
    var target_compound = try target_list.selectors.items[0].components.items[0].compound.clone(allocator);
    defer target_compound.deinit();

    var store = ApplyState.init(allocator);
    defer store.deinit();

    try store.addExtension(.{
        .extender = try extender.clone(allocator),
        .target = try target_compound.clone(allocator),
        .optional = false,
        .span = null,
    });

    var result = try store.applySelectorExtensions(&target_list);
    defer result.deinit();

    // Should produce "%placeholder, .bar"
    try std.testing.expect(result.selectors.items.len >= 2);

    var has_bar = false;
    for (result.selectors.items) |sel| {
        const css = try complexToCssAlloc(allocator, sel);
        defer allocator.free(css);
        if (std.mem.eql(u8, css, ".bar")) has_bar = true;
    }
    try std.testing.expect(has_bar);
}

test "optional extend" {
    const allocator = std.testing.allocator;

    // Selector: .foo
    var target_list = try selector_mod.parse(allocator, ".foo");
    defer target_list.deinit();

    // Extender: .bar, targeting .nonexistent
    var extender = try selector_mod.parse(allocator, ".bar");
    defer extender.deinit();

    var target_compound_list = try selector_mod.parse(allocator, ".nonexistent");
    defer target_compound_list.deinit();
    var target_compound = try target_compound_list.selectors.items[0].components.items[0].compound.clone(allocator);
    defer target_compound.deinit();

    var store = ApplyState.init(allocator);
    defer store.deinit();

    try store.addExtension(.{
        .extender = try extender.clone(allocator),
        .target = try target_compound.clone(allocator),
        .optional = true,
        .span = null,
    });

    // Apply extensions - should not fail even though target doesn't match
    var result = try store.applySelectorExtensions(&target_list);
    defer result.deinit();

    // Should produce just ".foo" since .nonexistent is not in .foo
    try std.testing.expectEqual(@as(usize, 1), result.selectors.items.len);
}

test "extension store init and deinit" {
    const allocator = std.testing.allocator;
    var store = ApplyState.init(allocator);
    defer store.deinit();

    try std.testing.expectEqual(@as(usize, 0), store.extensions.items.len);
}

test "addExtension" {
    const allocator = std.testing.allocator;

    var store = ApplyState.init(allocator);
    defer store.deinit();

    var extender = try selector_mod.parse(allocator, ".bar");
    defer extender.deinit();

    var target_list = try selector_mod.parse(allocator, ".foo");
    defer target_list.deinit();
    var target = try target_list.selectors.items[0].components.items[0].compound.clone(allocator);
    defer target.deinit();

    try store.addExtension(.{
        .extender = try extender.clone(allocator),
        .target = try target.clone(allocator),
        .optional = false,
        .span = null,
    });

    try std.testing.expectEqual(@as(usize, 1), store.extensions.items.len);
}

test "compoundContainsTarget" {
    const allocator = std.testing.allocator;

    // Parse ".foo.bar"
    var list = try selector_mod.parse(allocator, ".foo.bar");
    defer list.deinit();
    const compound = &list.selectors.items[0].components.items[0].compound;

    // Parse ".foo" as target
    var target_list = try selector_mod.parse(allocator, ".foo");
    defer target_list.deinit();
    const target = &target_list.selectors.items[0].components.items[0].compound;

    try std.testing.expect(compoundContainsTarget(compound, target));

    // Parse ".baz" as target - should not match
    var baz_list = try selector_mod.parse(allocator, ".baz");
    defer baz_list.deinit();
    const baz_target = &baz_list.selectors.items[0].components.items[0].compound;

    try std.testing.expect(!compoundContainsTarget(compound, baz_target));
}

test "unifyCompound: compatible" {
    const allocator = std.testing.allocator;

    // original: div.foo, target: .foo, extender: .bar
    var orig_list = try selector_mod.parse(allocator, "div.foo");
    defer orig_list.deinit();
    const original = &orig_list.selectors.items[0].components.items[0].compound;

    var target_list = try selector_mod.parse(allocator, ".foo");
    defer target_list.deinit();
    const target = &target_list.selectors.items[0].components.items[0].compound;

    var ext_list = try selector_mod.parse(allocator, ".bar");
    defer ext_list.deinit();
    const extender = &ext_list.selectors.items[0].components.items[0].compound;

    var result = try unifyCompound(allocator, original, target, extender);
    try std.testing.expect(result != null);
    defer result.?.deinit();

    // Should have div and .bar
    try std.testing.expect(result.?.simple_selectors.items.len >= 2);
}

test "unifyCompound: incompatible type selectors" {
    const allocator = std.testing.allocator;

    // original: div.foo, target: .foo, extender: span.bar
    var orig_list = try selector_mod.parse(allocator, "div.foo");
    defer orig_list.deinit();
    const original = &orig_list.selectors.items[0].components.items[0].compound;

    var target_list = try selector_mod.parse(allocator, ".foo");
    defer target_list.deinit();
    const target = &target_list.selectors.items[0].components.items[0].compound;

    var ext_list = try selector_mod.parse(allocator, "span.bar");
    defer ext_list.deinit();
    const extender = &ext_list.selectors.items[0].components.items[0].compound;

    const result = try unifyCompound(allocator, original, target, extender);
    // div and span conflict -> null
    try std.testing.expect(result == null);
}

test "pseudo :is() extend: :is(.c) with .c -> .d produces :is(.c, .d)" {
    const allocator = std.testing.allocator;

    var sel_list = try selector_mod.parse(allocator, ":is(.c)");
    defer sel_list.deinit();

    var target_list = try selector_mod.parse(allocator, ".c");
    defer target_list.deinit();
    const target_compound = target_list.selectors.items[0].components.items[0].compound;

    var extender = try selector_mod.parse(allocator, ".d");
    defer extender.deinit();

    var store = ApplyState.init(allocator);
    defer store.deinit();

    try store.addExtension(.{
        .extender = try extender.clone(allocator),
        .target = try target_compound.clone(allocator),
        .optional = false,
        .span = null,
    });

    var result = try store.applySelectorExtensions(&sel_list);
    defer result.deinit();

    const css = try selector_mod.toCss(allocator, &result);
    defer allocator.free(css);
    try std.testing.expectEqualStrings(":is(.c, .d)", css);
}

test "pseudo :not() preserves non-not suffix on extender" {
    const allocator = std.testing.allocator;

    var sel_list = try selector_mod.parse(allocator, "a:not(.foo)");
    defer sel_list.deinit();

    var target_list = try selector_mod.parse(allocator, ".foo");
    defer target_list.deinit();
    const target_compound = target_list.selectors.items[0].components.items[0].compound;

    var extender = try selector_mod.parse(allocator, ".bar:not(.x)");
    defer extender.deinit();

    var store = ApplyState.init(allocator);
    defer store.deinit();

    try store.addExtension(.{
        .extender = try extender.clone(allocator),
        .target = try target_compound.clone(allocator),
        .optional = false,
        .span = null,
    });

    var result = try store.applySelectorExtensions(&sel_list);
    defer result.deinit();

    const css = try selector_mod.toCss(allocator, &result);
    defer allocator.free(css);
    try std.testing.expectEqualStrings("a:not(.foo):not(.bar:not(.x))", css);
}

test "pseudo :not() skips pure not extender without target" {
    const allocator = std.testing.allocator;

    var sel_list = try selector_mod.parse(allocator, "a:not(.foo)");
    defer sel_list.deinit();

    var target_list = try selector_mod.parse(allocator, ".foo");
    defer target_list.deinit();
    const target_compound = target_list.selectors.items[0].components.items[0].compound;

    var extender = try selector_mod.parse(allocator, ":not(.z)");
    defer extender.deinit();

    var store = ApplyState.init(allocator);
    defer store.deinit();

    try store.addExtension(.{
        .extender = try extender.clone(allocator),
        .target = try target_compound.clone(allocator),
        .optional = true,
        .span = null,
    });

    var result = try store.applySelectorExtensions(&sel_list);
    defer result.deinit();

    const css = try selector_mod.toCss(allocator, &result);
    defer allocator.free(css);
    try std.testing.expectEqualStrings("a:not(.foo)", css);
}

test "selector pseudos coalesce repeated extend variants into one inner list" {
    const allocator = std.testing.allocator;

    var sel_list = try selector_mod.parse(allocator, "matches :matches(oh, no)");
    defer sel_list.deinit();

    var oh_list = try selector_mod.parse(allocator, "oh");
    defer oh_list.deinit();
    const target_compound = oh_list.selectors.items[0].components.items[0].compound;

    var extender_matches = try selector_mod.parse(allocator, "matches");
    defer extender_matches.deinit();

    var extender_any = try selector_mod.parse(allocator, "any");
    defer extender_any.deinit();

    var store = ApplyState.init(allocator);
    defer store.deinit();

    try store.addExtension(.{
        .extender = try extender_matches.clone(allocator),
        .target = try target_compound.clone(allocator),
        .optional = false,
        .span = null,
    });
    try store.addExtension(.{
        .extender = try extender_any.clone(allocator),
        .target = try target_compound.clone(allocator),
        .optional = false,
        .span = null,
    });

    var result = try store.applySelectorExtensions(&sel_list);
    defer result.deinit();

    const css = try selector_mod.toCss(allocator, &result);
    defer allocator.free(css);
    try std.testing.expectEqualStrings("matches :matches(oh, any, matches, no)", css);
}

test "normalizeGeneratedCompoundClassOrder sorts single-class extenders by eval order" {
    const allocator = std.testing.allocator;

    var foo_target = try selector_mod.parse(allocator, ".foo");
    defer foo_target.deinit();

    var bar_target = try selector_mod.parse(allocator, ".bar");
    defer bar_target.deinit();

    var baz_extender = try selector_mod.parse(allocator, ".baz");
    defer baz_extender.deinit();

    var bang_extender = try selector_mod.parse(allocator, ".bang");
    defer bang_extender.deinit();

    var store = ApplyState.init(allocator);
    defer store.deinit();

    try store.addExtension(.{
        .extender = try baz_extender.clone(allocator),
        .target = try foo_target.selectors.items[0].components.items[0].compound.clone(allocator),
        .optional = false,
        .span = null,
        .eval_order = 0,
    });
    try store.addExtension(.{
        .extender = try bang_extender.clone(allocator),
        .target = try bar_target.selectors.items[0].components.items[0].compound.clone(allocator),
        .optional = false,
        .span = null,
        .eval_order = 1,
    });

    var bang_baz = try selector_mod.parse(allocator, ".bang.baz");
    defer bang_baz.deinit();

    var compound = try bang_baz.selectors.items[0].components.items[0].compound.clone(allocator);
    defer compound.deinit();

    normalizeGeneratedCompoundClassOrder(&compound, store.extensions.items, store.sort_extension_hints.items);

    var normalized_list = SelectorList.init(allocator);
    defer normalized_list.deinit();
    var normalized_complex = try bang_baz.selectors.items[0].clone(allocator);
    normalized_complex.components.items[0].compound.deinit();
    normalized_complex.components.items[0].compound = compound;
    compound = CompoundSelector.init(allocator);
    try normalized_list.selectors.append(allocator, normalized_complex);

    const css = try selector_mod.toCss(allocator, &normalized_list);
    defer allocator.free(css);
    try std.testing.expectEqualStrings(".baz.bang", css);
}

test "normalizeGeneratedCompoundClassOrder sorts rightmost nested extender classes by eval order" {
    const allocator = std.testing.allocator;

    var foo_target = try selector_mod.parse(allocator, ".foo");
    defer foo_target.deinit();

    var bar_target = try selector_mod.parse(allocator, ".bar");
    defer bar_target.deinit();

    var alpha_extender = try selector_mod.parse(allocator, ".parent1 .alpha");
    defer alpha_extender.deinit();

    var beta_extender = try selector_mod.parse(allocator, ".parent2 .beta");
    defer beta_extender.deinit();

    var store = ApplyState.init(allocator);
    defer store.deinit();

    try store.addExtension(.{
        .extender = try alpha_extender.clone(allocator),
        .target = try foo_target.selectors.items[0].components.items[0].compound.clone(allocator),
        .optional = false,
        .span = null,
        .eval_order = 0,
    });
    try store.addExtension(.{
        .extender = try beta_extender.clone(allocator),
        .target = try bar_target.selectors.items[0].components.items[0].compound.clone(allocator),
        .optional = false,
        .span = null,
        .eval_order = 1,
    });

    var beta_alpha = try selector_mod.parse(allocator, ".beta.alpha");
    defer beta_alpha.deinit();

    var compound = try beta_alpha.selectors.items[0].components.items[0].compound.clone(allocator);
    defer compound.deinit();

    normalizeGeneratedCompoundClassOrder(&compound, store.extensions.items, store.sort_extension_hints.items);

    var normalized_list = SelectorList.init(allocator);
    defer normalized_list.deinit();
    var normalized_complex = try beta_alpha.selectors.items[0].clone(allocator);
    normalized_complex.components.items[0].compound.deinit();
    normalized_complex.components.items[0].compound = compound;
    compound = CompoundSelector.init(allocator);
    try normalized_list.selectors.append(allocator, normalized_complex);

    const css = try selector_mod.toCss(allocator, &normalized_list);
    defer allocator.free(css);
    try std.testing.expectEqualStrings(".alpha.beta", css);
}

test "applyExtensions preserves selector order for multiline selector list input" {
    const allocator = std.testing.allocator;

    var sel_list = try selector_mod.parse(
        allocator,
        ".example-1-1,\n.example-1-2,\n.example-1-3",
    );
    defer sel_list.deinit();

    var target = try selector_mod.parse(allocator, ".example-1-2");
    defer target.deinit();

    var extender = try selector_mod.parse(allocator, ".my-page-1 .my-module-1-1");
    defer extender.deinit();

    var store = ApplyState.init(allocator);
    defer store.deinit();

    try store.addExtension(.{
        .extender = try extender.clone(allocator),
        .target = try target.selectors.items[0].components.items[0].compound.clone(allocator),
        .optional = false,
        .span = null,
        .eval_order = 0,
    });

    var result = try store.applySelectorExtensions(&sel_list);
    defer result.deinit();

    const css = try selector_mod.toCss(allocator, &result);
    defer allocator.free(css);
    try std.testing.expectEqualStrings(
        ".example-1-1,\n.example-1-2,\n.my-page-1 .my-module-1-1,\n.example-1-3",
        css,
    );
}

test "applyExtensions preserves chained local @extend insertion order in loop" {
    const allocator = std.testing.allocator;

    var sel_list = try selector_mod.parse(allocator, ".foo");
    defer sel_list.deinit();

    var foo_target = try selector_mod.parse(allocator, ".foo");
    defer foo_target.deinit();
    var bar_target = try selector_mod.parse(allocator, ".bar");
    defer bar_target.deinit();
    var baz_target = try selector_mod.parse(allocator, ".baz");
    defer baz_target.deinit();

    var foo_extender = try selector_mod.parse(allocator, ".foo");
    defer foo_extender.deinit();
    var bar_extender = try selector_mod.parse(allocator, ".bar");
    defer bar_extender.deinit();
    var baz_extender = try selector_mod.parse(allocator, ".baz");
    defer baz_extender.deinit();

    var store = ApplyState.init(allocator);
    defer store.deinit();

    try store.addExtension(.{
        .extender = try foo_extender.clone(allocator),
        .target = try bar_target.selectors.items[0].components.items[0].compound.clone(allocator),
        .optional = false,
        .span = null,
        .eval_order = 0,
    });
    try store.addExtension(.{
        .extender = try bar_extender.clone(allocator),
        .target = try baz_target.selectors.items[0].components.items[0].compound.clone(allocator),
        .optional = false,
        .span = null,
        .eval_order = 1,
    });
    try store.addExtension(.{
        .extender = try baz_extender.clone(allocator),
        .target = try foo_target.selectors.items[0].components.items[0].compound.clone(allocator),
        .optional = false,
        .span = null,
        .eval_order = 2,
    });

    var result = try store.applySelectorExtensions(&sel_list);
    defer result.deinit();

    const css = try selector_mod.toCss(allocator, &result);
    defer allocator.free(css);
    try std.testing.expectEqualStrings(".foo, .baz, .bar", css);
}

test "applyExtensions orders direct cross-compound extends by evaluation order" {
    const allocator = std.testing.allocator;

    var sel_list = try selector_mod.parse(allocator, "a b");
    defer sel_list.deinit();

    var a_target = try selector_mod.parse(allocator, "a");
    defer a_target.deinit();
    var b_target = try selector_mod.parse(allocator, "b");
    defer b_target.deinit();
    var d_extender = try selector_mod.parse(allocator, "d");
    defer d_extender.deinit();
    var c_extender = try selector_mod.parse(allocator, "c");
    defer c_extender.deinit();

    var store = ApplyState.init(allocator);
    defer store.deinit();

    try store.addExtension(.{
        .extender = try c_extender.clone(allocator),
        .target = try b_target.selectors.items[0].components.items[0].compound.clone(allocator),
        .optional = false,
        .span = null,
        .eval_order = 0,
    });
    try store.addExtension(.{
        .extender = try d_extender.clone(allocator),
        .target = try a_target.selectors.items[0].components.items[0].compound.clone(allocator),
        .optional = false,
        .span = null,
        .eval_order = 1,
    });

    var result = try store.applySelectorExtensions(&sel_list);
    defer result.deinit();

    const css = try selector_mod.toCss(allocator, &result);
    defer allocator.free(css);
    try std.testing.expectEqualStrings("a b, d b, a c, d c", css);
}

test "applyExtensions keeps cross-target second-pass results after all direct matches" {
    const allocator = std.testing.allocator;

    var sel_list = try selector_mod.parse(allocator, ".foo .bar");
    defer sel_list.deinit();

    var foo_target = try selector_mod.parse(allocator, ".foo");
    defer foo_target.deinit();
    var bar_target = try selector_mod.parse(allocator, ".bar");
    defer bar_target.deinit();
    var baz_extender = try selector_mod.parse(allocator, ".baz");
    defer baz_extender.deinit();

    var store = ApplyState.init(allocator);
    defer store.deinit();

    try store.addExtension(.{
        .extender = try baz_extender.clone(allocator),
        .target = try foo_target.selectors.items[0].components.items[0].compound.clone(allocator),
        .optional = false,
        .span = null,
        .eval_order = 0,
    });
    try store.addExtension(.{
        .extender = try baz_extender.clone(allocator),
        .target = try bar_target.selectors.items[0].components.items[0].compound.clone(allocator),
        .optional = false,
        .span = null,
        .eval_order = 1,
    });

    var result = try store.applySelectorExtensions(&sel_list);
    defer result.deinit();

    const css = try selector_mod.toCss(allocator, &result);
    defer allocator.free(css);
    try std.testing.expectEqualStrings(".foo .bar, .foo .baz, .baz .bar, .baz .baz", css);
}

test "applyExtensions interleaves branch-local chained extensions before unrelated direct matches" {
    const allocator = std.testing.allocator;

    var sel_list = try selector_mod.parse(allocator, ".base");
    defer sel_list.deinit();

    var base_target = try selector_mod.parse(allocator, ".base");
    defer base_target.deinit();
    var mid_target = try selector_mod.parse(allocator, ".mid");
    defer mid_target.deinit();
    var other_extender = try selector_mod.parse(allocator, ".other");
    defer other_extender.deinit();
    var mid_extender = try selector_mod.parse(allocator, ".mid");
    defer mid_extender.deinit();
    var leaf_extender = try selector_mod.parse(allocator, ".leaf");
    defer leaf_extender.deinit();

    var store = ApplyState.init(allocator);
    defer store.deinit();

    try store.addExtension(.{
        .extender = try other_extender.clone(allocator),
        .target = try base_target.selectors.items[0].components.items[0].compound.clone(allocator),
        .optional = false,
        .span = null,
        .eval_order = 0,
    });
    try store.addExtension(.{
        .extender = try mid_extender.clone(allocator),
        .target = try base_target.selectors.items[0].components.items[0].compound.clone(allocator),
        .optional = false,
        .span = null,
        .eval_order = 1,
    });
    try store.addExtension(.{
        .extender = try leaf_extender.clone(allocator),
        .target = try mid_target.selectors.items[0].components.items[0].compound.clone(allocator),
        .optional = false,
        .span = null,
        .eval_order = 2,
    });

    var result = try store.applySelectorExtensions(&sel_list);
    defer result.deinit();

    const css = try selector_mod.toCss(allocator, &result);
    defer allocator.free(css);
    try std.testing.expectEqualStrings(".base, .mid, .leaf, .other", css);
}

test "applyExtensions keeps same-branch single selectors before descendant variants" {
    const allocator = std.testing.allocator;

    var sel_list = try selector_mod.parse(allocator, ".button.is-rounded");
    defer sel_list.deinit();

    var is_rounded_target = try selector_mod.parse(allocator, ".is-rounded");
    defer is_rounded_target.deinit();
    var button_target = try selector_mod.parse(allocator, ".button");
    defer button_target.deinit();
    var avatar_extender = try selector_mod.parse(allocator, ".avatar");
    defer avatar_extender.deinit();
    var copy_button_extender = try selector_mod.parse(allocator, ".copy-container button");
    defer copy_button_extender.deinit();

    var store = ApplyState.init(allocator);
    defer store.deinit();

    try store.addExtension(.{
        .extender = try avatar_extender.clone(allocator),
        .target = try is_rounded_target.selectors.items[0].components.items[0].compound.clone(allocator),
        .optional = false,
        .span = null,
        .eval_order = 0,
    });
    try store.addExtension(.{
        .extender = try copy_button_extender.clone(allocator),
        .target = try button_target.selectors.items[0].components.items[0].compound.clone(allocator),
        .optional = false,
        .span = null,
        .eval_order = 1,
    });

    var result = try store.applySelectorExtensions(&sel_list);
    defer result.deinit();

    const css = try selector_mod.toCss(allocator, &result);
    defer allocator.free(css);
    try std.testing.expectEqualStrings(
        ".button.is-rounded, .copy-container button.is-rounded, .button.avatar, .copy-container button.avatar",
        css,
    );
}

test "trim removes duplicates" {
    const allocator = std.testing.allocator;

    var list: std.ArrayList(ComplexSelector) = .empty;
    defer {
        for (list.items) |*s| s.deinit();
        list.deinit(allocator);
    }

    var sel1 = try selector_mod.parse(allocator, ".foo");
    defer sel1.deinit();
    var sel2 = try selector_mod.parse(allocator, ".foo");
    defer sel2.deinit();

    try list.append(allocator, try sel1.selectors.items[0].clone(allocator));
    try list.append(allocator, try sel2.selectors.items[0].clone(allocator));

    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try trim(allocator, &list, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
}

test "applyExtensions drops duplicate original selector once list is extended" {
    const allocator = std.testing.allocator;

    var sel_list = try selector_mod.parse(allocator, ".la, .la");
    defer sel_list.deinit();

    var target = try selector_mod.parse(allocator, ".la");
    defer target.deinit();
    var extender = try selector_mod.parse(allocator, ".header-arrow");
    defer extender.deinit();

    var store = ApplyState.init(allocator);
    defer store.deinit();

    try store.addExtension(.{
        .extender = try extender.clone(allocator),
        .target = try target.selectors.items[0].components.items[0].compound.clone(allocator),
        .optional = false,
        .span = null,
        .eval_order = 0,
    });

    var result = try store.applySelectorExtensions(&sel_list);
    defer result.deinit();

    const css = try selector_mod.toCss(allocator, &result);
    defer allocator.free(css);
    try std.testing.expectEqualStrings(".la, .header-arrow", css);
}

test "applyExtensions orders local placeholder transitive extenders later first" {
    const allocator = std.testing.allocator;

    var sel_list = try selector_mod.parse(allocator, "%base");
    defer sel_list.deinit();

    var base_target = try selector_mod.parse(allocator, "%base");
    defer base_target.deinit();
    var mid_target = try selector_mod.parse(allocator, "%mid");
    defer mid_target.deinit();
    var mid_extender = try selector_mod.parse(allocator, "%mid");
    defer mid_extender.deinit();
    var early_extender = try selector_mod.parse(allocator, ".early");
    defer early_extender.deinit();
    var late_extender = try selector_mod.parse(allocator, ".late");
    defer late_extender.deinit();

    var store = ApplyState.init(allocator);
    defer store.deinit();

    try store.addExtension(.{
        .extender = try mid_extender.clone(allocator),
        .target = try base_target.selectors.items[0].components.items[0].compound.clone(allocator),
        .optional = false,
        .span = null,
        .eval_order = 0,
    });
    try store.addExtension(.{
        .extender = try early_extender.clone(allocator),
        .target = try mid_target.selectors.items[0].components.items[0].compound.clone(allocator),
        .optional = false,
        .span = null,
        .eval_order = 1,
    });
    try store.addExtension(.{
        .extender = try late_extender.clone(allocator),
        .target = try mid_target.selectors.items[0].components.items[0].compound.clone(allocator),
        .optional = false,
        .span = null,
        .eval_order = 2,
    });

    var result = try store.applySelectorExtensions(&sel_list);
    defer result.deinit();

    const css = try selector_mod.toCss(allocator, &result);
    defer allocator.free(css);
    try std.testing.expectEqualStrings("%base, .late, .early", css);
}

test "trimWithMetadata keeps cross-group first-pass single-compound focus variant" {
    const allocator = std.testing.allocator;

    var list: std.ArrayList(ComplexSelector) = .empty;
    defer {
        for (list.items) |*s| s.deinit();
        list.deinit(allocator);
    }

    var first_pass: std.ArrayList(bool) = .empty;
    defer first_pass.deinit(allocator);
    var orig_groups: std.ArrayList(usize) = .empty;
    defer orig_groups.deinit(allocator);
    var eval_orders: std.ArrayList(u32) = .empty;
    defer eval_orders.deinit(allocator);

    var focus_sel = try selector_mod.parse(allocator, "iconview:selected:focus");
    defer focus_sel.deinit();
    var broad_sel = try selector_mod.parse(allocator, "iconview:selected");
    defer broad_sel.deinit();

    try list.append(allocator, try focus_sel.selectors.items[0].clone(allocator));
    try first_pass.append(allocator, true);
    try orig_groups.append(allocator, 0);
    try eval_orders.append(allocator, 0);

    try list.append(allocator, try broad_sel.selectors.items[0].clone(allocator));
    try first_pass.append(allocator, true);
    try orig_groups.append(allocator, 1);
    try eval_orders.append(allocator, 0);

    try trimWithMetadata(allocator, &list, &first_pass, &orig_groups, &eval_orders);

    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    const css = try complexToCssAlloc(allocator, list.items[0]);
    defer allocator.free(css);
    try std.testing.expectEqualStrings("iconview:selected:focus", css);
}

test "trimWithMetadata trims cross-group first-pass descendant focus variant" {
    const allocator = std.testing.allocator;

    var list: std.ArrayList(ComplexSelector) = .empty;
    defer {
        for (list.items) |*s| s.deinit();
        list.deinit(allocator);
    }

    var first_pass: std.ArrayList(bool) = .empty;
    defer first_pass.deinit(allocator);
    var orig_groups: std.ArrayList(usize) = .empty;
    defer orig_groups.deinit(allocator);
    var eval_orders: std.ArrayList(u32) = .empty;
    defer eval_orders.deinit(allocator);

    var focus_sel = try selector_mod.parse(allocator, ".view text:selected:focus");
    defer focus_sel.deinit();
    var broad_sel = try selector_mod.parse(allocator, ".view text:selected");
    defer broad_sel.deinit();

    try list.append(allocator, try focus_sel.selectors.items[0].clone(allocator));
    try first_pass.append(allocator, true);
    try orig_groups.append(allocator, 0);
    try eval_orders.append(allocator, 0);

    try list.append(allocator, try broad_sel.selectors.items[0].clone(allocator));
    try first_pass.append(allocator, true);
    try orig_groups.append(allocator, 1);
    try eval_orders.append(allocator, 0);

    try trimWithMetadata(allocator, &list, &first_pass, &orig_groups, &eval_orders);

    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    const css = try complexToCssAlloc(allocator, list.items[0]);
    defer allocator.free(css);
    try std.testing.expectEqualStrings(".view text:selected", css);
}

test "trimWithMetadata keeps cross-group first-pass descendant focus when leading type matches" {
    const allocator = std.testing.allocator;

    var list: std.ArrayList(ComplexSelector) = .empty;
    defer {
        for (list.items) |*s| s.deinit();
        list.deinit(allocator);
    }

    var first_pass: std.ArrayList(bool) = .empty;
    defer first_pass.deinit(allocator);
    var orig_groups: std.ArrayList(usize) = .empty;
    defer orig_groups.deinit(allocator);
    var eval_orders: std.ArrayList(u32) = .empty;
    defer eval_orders.deinit(allocator);

    var focus_sel = try selector_mod.parse(allocator, "textview text:selected:focus");
    defer focus_sel.deinit();
    var broad_sel = try selector_mod.parse(allocator, "textview text:selected");
    defer broad_sel.deinit();

    try list.append(allocator, try focus_sel.selectors.items[0].clone(allocator));
    try first_pass.append(allocator, true);
    try orig_groups.append(allocator, 0);
    try eval_orders.append(allocator, 0);

    try list.append(allocator, try broad_sel.selectors.items[0].clone(allocator));
    try first_pass.append(allocator, true);
    try orig_groups.append(allocator, 1);
    try eval_orders.append(allocator, 0);

    try trimWithMetadata(allocator, &list, &first_pass, &orig_groups, &eval_orders);

    try std.testing.expectEqual(@as(usize, 2), list.items.len);
}

test "applyExtensions keeps both descendant weave orders for self type extend" {
    const allocator = std.testing.allocator;

    var sel_list = try selector_mod.parse(allocator, ".jumbotron h1");
    defer sel_list.deinit();

    var target = try selector_mod.parse(allocator, "h1");
    defer target.deinit();
    var extender = try selector_mod.parse(allocator, ".CodeMirror .CodeMirror-code h1");
    defer extender.deinit();

    var store = ApplyState.init(allocator);
    defer store.deinit();

    try store.addExtension(.{
        .extender = try extender.clone(allocator),
        .target = try target.selectors.items[0].components.items[0].compound.clone(allocator),
        .optional = false,
        .span = null,
        .eval_order = 0,
    });

    var result = try store.applySelectorExtensions(&sel_list);
    defer result.deinit();

    const css = try selector_mod.toCss(allocator, &result);
    defer allocator.free(css);
    try std.testing.expectEqualStrings(
        ".jumbotron h1, .jumbotron .CodeMirror .CodeMirror-code h1, .CodeMirror .CodeMirror-code .jumbotron h1",
        css,
    );
}

test "weavePaths returns both descendant orderings for unrelated prefixes" {
    const allocator = std.testing.allocator;

    var original = try selector_mod.parse(allocator, ".jumbotron h1");
    defer original.deinit();
    var extender = try selector_mod.parse(allocator, ".CodeMirror .CodeMirror-code h1");
    defer extender.deinit();

    const orig_prefix = original.selectors.items[0].components.items[0..1];
    const ext_prefix = extender.selectors.items[0].components.items[0..3];

    var woven = try weavePaths(allocator, orig_prefix, .descendant, ext_prefix, .descendant);
    defer {
        for (woven.items) |*w| w.deinit();
        woven.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), woven.items.len);
}
