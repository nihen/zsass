//! sass:selector builtins.
const std = @import("std");
const selector_mod = @import("../selector/selector.zig");
const extend_mod = @import("../selector/extend.zig");
const extend_unification_mod = @import("../selector/extend_unification.zig");
const extend_specificity = @import("../selector/extend_specificity.zig");
const shared = @import("shared.zig");
const intern_pool_mod = @import("../runtime/intern_pool.zig");

const Value = shared.Value;
const InternId = shared.InternId;
const ListSeparator = shared.ListSeparator;
const BuiltinContext = shared.BuiltinContext;
const BuiltinError = shared.BuiltinError;

const internString = shared.internString;
const bindNamedOrPositionalArgsStrict = shared.bindNamedOrPositionalArgsStrict;
const valueToCssString = shared.valueToCssString;
const reportMissingArgument = shared.reportMissingArgument;

const ApplyState = extend_mod.ApplyState;

const simpleSelectorEql = extend_specificity.simpleSelectorEql;

const SelectorList = selector_mod.SelectorList;
const ComplexSelector = selector_mod.ComplexSelector;
const ComplexSelectorComponent = selector_mod.ComplexSelectorComponent;
const CompoundSelector = selector_mod.CompoundSelector;
const SimpleSelector = selector_mod.SimpleSelector;
const Combinator = selector_mod.Combinator;
const PseudoSelector = selector_mod.PseudoSelector;

fn boolValue(v: bool) Value {
    return if (v) Value.true_v else Value.false_v;
}

fn pushListWithSeparator(
    ctx: *BuiltinContext,
    items: []const Value,
    separator: ListSeparator,
    bracketed: bool,
) BuiltinError!Value {
    return shared.pushListWithMeta(ctx, items, separator, bracketed, false);
}

const pushCommaList = shared.pushCommaList;

fn makeUnquotedStringValue(ctx: *BuiltinContext, s: []const u8) BuiltinError!Value {
    const id = try internString(ctx, s);
    if (std.mem.eql(u8, s, "&")) return Value.stringPreservingAmpersand(id, false);
    return Value.string(id, false);
}

fn selectorValueToString(ctx: *BuiltinContext, value: Value, depth: u8) BuiltinError![]u8 {
    if (value.isString()) {
        return ctx.allocator.dupe(u8, ctx.intern_pool.get(value.stringIntern())) catch error.OutOfMemory;
    }
    if (value.kind() == .list) {
        if (value.listSlash(ctx.list_meta_pool.items)) return error.BuiltinType;
        if (depth >= 1 and value.listComma(ctx.list_meta_pool.items)) return error.BuiltinType;

        const items = ctx.list_pool.items[value.listHandle()];

        var saw_nested = false;
        for (items) |item| {
            if (item.kind() == .list) {
                saw_nested = true;
                break;
            }
        }
        if (saw_nested and (depth != 0 or !value.listComma(ctx.list_meta_pool.items))) return error.BuiltinType;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(ctx.allocator);
        const sep = if (value.listComma(ctx.list_meta_pool.items)) ", " else " ";

        for (items, 0..) |item, i| {
            if (i > 0) try buf.appendSlice(ctx.allocator, sep);
            const item_str = try selectorValueToString(ctx, item, depth + @intFromBool(saw_nested));
            defer ctx.allocator.free(item_str);
            try buf.appendSlice(ctx.allocator, item_str);
        }
        return try buf.toOwnedSlice(ctx.allocator);
    }
    return error.BuiltinType;
}

fn selectorArgString(ctx: *BuiltinContext, value: Value) BuiltinError![]u8 {
    return selectorValueToString(ctx, value, 0);
}

fn selectorArgCssString(ctx: *BuiltinContext, value: Value) BuiltinError![]u8 {
    const css = try valueToCssString(ctx, value);
    return @constCast(css);
}

fn selectorListToValue(ctx: *BuiltinContext, list: *const SelectorList) BuiltinError!Value {
    var outer_items: std.ArrayList(Value) = .empty;
    defer outer_items.deinit(ctx.allocator);
    try outer_items.ensureTotalCapacity(ctx.allocator, list.selectors.items.len);

    for (list.selectors.items) |complex| {
        var inner_items: std.ArrayList(Value) = .empty;
        defer inner_items.deinit(ctx.allocator);
        try inner_items.ensureTotalCapacity(ctx.allocator, complex.components.items.len);

        for (complex.components.items) |comp| {
            switch (comp) {
                .compound => |compound| {
                    const css = try selector_mod.compoundSelectorToCss(ctx.allocator, &compound);
                    defer ctx.allocator.free(css);
                    inner_items.appendAssumeCapacity(try makeUnquotedStringValue(ctx, css));
                },
                .combinator => |comb| {
                    const css_text = std.mem.trim(u8, comb.toCss(), " ");
                    if (css_text.len == 0) continue;
                    inner_items.appendAssumeCapacity(try makeUnquotedStringValue(ctx, css_text));
                },
            }
        }

        const inner = try pushListWithSeparator(ctx, inner_items.items, .space, false);
        outer_items.appendAssumeCapacity(inner);
    }

    return pushCommaList(ctx, outer_items.items);
}

pub fn selector_parse(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{"selector"}, 1);
    const selector_val = bound[0] orelse return reportMissingArgument("selector");
    const selector_str = try selectorArgString(ctx, selector_val);
    defer ctx.allocator.free(selector_str);

    var parsed = selector_mod.parse(ctx.allocator, selector_str) catch return error.SassError;
    defer parsed.deinit();
    if (selector_mod.hasParentReference(&parsed)) return error.BuiltinType;
    return selectorListToValue(ctx, &parsed);
}

pub fn selector_nest(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    if (args.len == 0) return error.BuiltinArity;

    const first_str = try selectorArgString(ctx, args[0]);
    defer ctx.allocator.free(first_str);
    var current = selector_mod.parse(ctx.allocator, first_str) catch return error.SassError;
    if (selector_mod.hasParentReference(&current)) {
        if (hasParentSuffix(first_str)) {
            current.deinit();
            return error.SassError;
        }
    }

    for (args[1..]) |arg_val| {
        const child_str = try selectorArgString(ctx, arg_val);
        defer ctx.allocator.free(child_str);
        var child = selector_mod.parse(ctx.allocator, child_str) catch {
            current.deinit();
            return error.SassError;
        };
        defer child.deinit();

        const resolved = selector_mod.resolveParent(ctx.allocator, &child, &current) catch {
            current.deinit();
            return error.SassError;
        };
        current.deinit();
        current = resolved;
    }
    defer current.deinit();

    if (args.len == 1 and selector_mod.hasParentReference(&current)) {
        // Keep a bare parent selector as selector list value so declaration emission
        // doesn't eagerly resolve `&` to the current rule selector.
        return selectorListToValue(ctx, &current);
    }

    const result_css = try selector_mod.toCss(ctx.allocator, &current);
    defer ctx.allocator.free(result_css);
    return makeUnquotedStringValue(ctx, result_css);
}

pub fn selector_append(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    if (args.len == 0) return error.BuiltinArity;

    const first_str = try selectorArgString(ctx, args[0]);
    defer ctx.allocator.free(first_str);
    var current = selector_mod.parse(ctx.allocator, first_str) catch return error.SassError;
    if (selector_mod.hasParentReference(&current) or !selectorAppendBaseIsValid(&current)) {
        current.deinit();
        return error.SassError;
    }
    defer current.deinit();

    for (args[1..]) |arg_val| {
        const suffix_str = try selectorArgString(ctx, arg_val);
        defer ctx.allocator.free(suffix_str);
        var suffix = selector_mod.parse(ctx.allocator, suffix_str) catch return error.SassError;
        defer suffix.deinit();
        if (selector_mod.hasParentReference(&suffix) or !selectorAppendSuffixIsValid(&suffix)) {
            return error.SassError;
        }
        const appended = selector_mod.selectorAppend(ctx.allocator, &current, &suffix) catch return error.SassError;
        current.deinit();
        current = appended;
        if (current.selectors.items.len == 0) return error.SassError;
    }

    return selectorListToValue(ctx, &current);
}

pub fn selector_unify(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{ "selector1", "selector2" }, 2);
    const sel1_val = bound[0] orelse return reportMissingArgument("selector1");
    const sel2_val = bound[1] orelse return reportMissingArgument("selector2");

    const sel1_str = try selectorArgString(ctx, sel1_val);
    defer ctx.allocator.free(sel1_str);
    const sel2_str = try selectorArgString(ctx, sel2_val);
    defer ctx.allocator.free(sel2_str);

    var sel1 = selector_mod.parse(ctx.allocator, sel1_str) catch return error.SassError;
    defer sel1.deinit();
    if (selector_mod.hasParentReference(&sel1)) return error.BuiltinType;

    var sel2 = selector_mod.parse(ctx.allocator, sel2_str) catch return error.SassError;
    defer sel2.deinit();
    if (selector_mod.hasParentReference(&sel2)) return error.BuiltinType;

    var result = SelectorList.init(ctx.allocator);
    errdefer result.deinit();

    for (sel1.selectors.items) |complex1| {
        for (sel2.selectors.items) |complex2| {
            const unified_list = try unifyComplexSelectors(ctx.allocator, &complex1, &complex2);
            defer {
                for (unified_list) |*item| item.deinit();
                ctx.allocator.free(unified_list);
            }

            for (unified_list) |item| {
                var duplicate = false;
                for (result.selectors.items) |existing| {
                    if (complexSelectorsEqualForResult(&existing, &item)) {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate) {
                    try result.selectors.append(ctx.allocator, try item.clone(ctx.allocator));
                }
            }
        }
    }

    if (result.selectors.items.len == 0) {
        result.deinit();
        return Value.nil_v;
    }
    defer result.deinit();
    return selectorListToValue(ctx, &result);
}

pub fn selector_is_super(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{ "super", "sub" }, 2);
    const super_val = bound[0] orelse return reportMissingArgument("super");
    const sub_val = bound[1] orelse return reportMissingArgument("sub");

    const super_str = try selectorArgString(ctx, super_val);
    defer ctx.allocator.free(super_str);
    const sub_str = try selectorArgString(ctx, sub_val);
    defer ctx.allocator.free(sub_str);

    var super_sel = selector_mod.parse(ctx.allocator, super_str) catch return error.SassError;
    defer super_sel.deinit();
    if (selector_mod.hasParentReference(&super_sel)) return error.SassError;

    var sub_sel = selector_mod.parse(ctx.allocator, sub_str) catch return error.SassError;
    defer sub_sel.deinit();
    if (selector_mod.hasParentReference(&sub_sel)) return error.SassError;

    return boolValue(selector_mod.isSuperSelector(&super_sel, &sub_sel));
}

pub fn selector_extend(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{ "selector", "extendee", "extender" }, 3);
    const selector_val = bound[0] orelse return reportMissingArgument("selector");
    const extendee_val = bound[1] orelse return reportMissingArgument("extendee");
    const extender_val = bound[2] orelse return reportMissingArgument("extender");

    const sel_str = try selectorArgString(ctx, selector_val);
    defer ctx.allocator.free(sel_str);
    const extendee_str = try selectorArgString(ctx, extendee_val);
    defer ctx.allocator.free(extendee_str);
    const extender_str = try selectorArgString(ctx, extender_val);
    defer ctx.allocator.free(extender_str);

    return selectorExtendCore(ctx, sel_str, extendee_str, extender_str);
}

pub fn selector_replace(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{ "selector", "original", "replacement" }, 3);
    const selector_val = bound[0] orelse return reportMissingArgument("selector");
    const original_val = bound[1] orelse return reportMissingArgument("original");
    const replacement_val = bound[2] orelse return reportMissingArgument("replacement");

    const sel_str = try selectorArgString(ctx, selector_val);
    defer ctx.allocator.free(sel_str);
    const original_str = try selectorArgString(ctx, original_val);
    defer ctx.allocator.free(original_str);
    const replacement_str = try selectorArgString(ctx, replacement_val);
    defer ctx.allocator.free(replacement_str);

    return selectorReplaceCore(ctx, sel_str, original_str, replacement_str);
}

pub fn selector_simple_selectors(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{"selector"}, 1);
    const selector_val = bound[0] orelse return reportMissingArgument("selector");
    if (selector_val.kind() == .nil) return error.SassError;

    const selector_str = try selectorArgCssString(ctx, selector_val);
    defer ctx.allocator.free(selector_str);

    var parsed = selector_mod.parse(ctx.allocator, selector_str) catch {
        return makeUnquotedStringValue(ctx, selector_str);
    };
    defer parsed.deinit();

    if (parsed.selectors.items.len == 0) return Value.nil_v;
    const complex = parsed.selectors.items[0];

    var total_simple: usize = 0;
    for (complex.components.items) |comp| {
        if (comp == .compound) total_simple += comp.compound.simple_selectors.items.len;
    }

    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(ctx.allocator);
    try items.ensureTotalCapacity(ctx.allocator, total_simple);

    for (complex.components.items) |comp| {
        switch (comp) {
            .compound => |compound| {
                for (compound.simple_selectors.items) |ss| {
                    const css = try simpleSelectorToCssAlloc(ctx.allocator, ss);
                    defer ctx.allocator.free(css);
                    items.appendAssumeCapacity(try makeUnquotedStringValue(ctx, css));
                }
            },
            .combinator => {},
        }
    }

    return pushCommaList(ctx, items.items);
}

fn trimSuperselectedResults(result: *SelectorList, originals: *const SelectorList, consider_originals: bool) void {
    var i: usize = 0;
    while (i < result.selectors.items.len) {
        if (isOriginalSelector(&result.selectors.items[i], originals)) {
            i += 1;
            continue;
        }
        var has_superselector = false;
        for (result.selectors.items, 0..) |*other, j| {
            if (i == j) continue;
            if (!consider_originals and isOriginalSelector(other, originals)) continue;
            if (selector_mod.complexIsSuperSelector(other, &result.selectors.items[i])) {
                has_superselector = true;
                break;
            }
        }
        if (has_superselector) {
            var removed = result.selectors.orderedRemove(i);
            removed.deinit();
        } else {
            i += 1;
        }
    }
}

fn isOriginalSelector(sel: *const ComplexSelector, originals: *const SelectorList) bool {
    for (originals.selectors.items) |*orig| {
        if (complexSelectorCssEql(sel, orig)) return true;
    }
    return false;
}

fn complexSelectorCssEql(a: *const ComplexSelector, b: *const ComplexSelector) bool {
    if (a.components.items.len != b.components.items.len) return false;
    for (a.components.items, b.components.items) |ac, bc| {
        switch (ac) {
            .combinator => |ca| {
                if (bc != .combinator) return false;
                if (ca != bc.combinator) return false;
            },
            .compound => |ca| {
                if (bc != .compound) return false;
                const cb = bc.compound;
                if (ca.simple_selectors.items.len != cb.simple_selectors.items.len) return false;
                for (ca.simple_selectors.items, cb.simple_selectors.items) |sa, sb| {
                    if (!simpleSelectorEql(sa, sb)) return false;
                }
            },
        }
    }
    return true;
}

fn compoundCountInComplex(complex: *const ComplexSelector) usize {
    var n: usize = 0;
    for (complex.components.items) |comp| {
        if (comp == .compound) n += 1;
    }
    return n;
}

/// Shallow `&` only on each compound's `simple_selectors` (not nested inside pseudo args; differs from `hasParentReference`).
fn complexHasShallowParentSelector(complex: *const ComplexSelector) bool {
    for (complex.components.items) |comp| {
        if (comp == .compound) {
            for (comp.compound.simple_selectors.items) |ss| {
                if (ss == .parent) return true;
            }
        }
    }
    return false;
}

fn selectorListHasShallowParentSelector(list: *const SelectorList) bool {
    for (list.selectors.items) |complex| {
        if (complexHasShallowParentSelector(&complex)) return true;
    }
    return false;
}

fn selectorExtendCore(
    ctx: *BuiltinContext,
    sel_str: []const u8,
    extendee_str: []const u8,
    extender_str: []const u8,
) BuiltinError!Value {
    var sel = selector_mod.parse(ctx.allocator, sel_str) catch return error.SassError;
    defer sel.deinit();
    if (selectorListHasShallowParentSelector(&sel)) return error.BuiltinType;

    var extendee = selector_mod.parse(ctx.allocator, extendee_str) catch return error.SassError;
    defer extendee.deinit();
    for (extendee.selectors.items) |extendee_complex| {
        if (compoundCountInComplex(&extendee_complex) > 1) return error.BuiltinType;
        if (complexHasShallowParentSelector(&extendee_complex)) return error.BuiltinType;
    }

    var extender = selector_mod.parse(ctx.allocator, extender_str) catch return error.SassError;
    defer extender.deinit();
    if (selectorListHasShallowParentSelector(&extender)) return error.BuiltinType;

    if (selectorExtendSuppressedForBogusCombinators(&sel, &extender)) {
        return selectorListToValue(ctx, &sel);
    }

    {
        var has_bogus_extender = false;
        var has_combinator_only_extender = false;
        for (extender.selectors.items) |extender_complex| {
            var prev_was_nondesc = false;
            var is_bogus = false;
            for (extender_complex.components.items) |comp| {
                switch (comp) {
                    .combinator => |comb| {
                        if (comb != .descendant) {
                            if (prev_was_nondesc) {
                                is_bogus = true;
                                break;
                            }
                            prev_was_nondesc = true;
                        } else {
                            prev_was_nondesc = false;
                        }
                    },
                    .compound => {
                        prev_was_nondesc = false;
                    },
                }
            }
            if (is_bogus) has_bogus_extender = true;

            const compound_count = compoundCountInComplex(&extender_complex);
            if (compound_count == 0 and extender_complex.components.items.len > 0) {
                has_combinator_only_extender = true;
            }
        }

        if (has_bogus_extender) {
            return selectorListToValue(ctx, &sel);
        }

        if (has_combinator_only_extender) {
            var combined = SelectorList.init(ctx.allocator);
            defer combined.deinit();
            for (sel.selectors.items) |orig_complex| {
                try combined.selectors.append(ctx.allocator, try orig_complex.clone(ctx.allocator));
            }
            for (extender.selectors.items) |extender_complex| {
                if (compoundCountInComplex(&extender_complex) == 0) {
                    try combined.selectors.append(ctx.allocator, try extender_complex.clone(ctx.allocator));
                }
            }
            return selectorListToValue(ctx, &combined);
        }
    }

    var result = try extend_mod.applySelectorFunctionExtend(
        ctx.allocator,
        &sel,
        &extendee,
        &extender,
        addSelectorExtensionTargets,
    );
    defer result.deinit();

    trimSuperselectedResults(&result, &sel, true);

    return selectorListToValue(ctx, &result);
}

fn selectorReplaceCore(
    ctx: *BuiltinContext,
    sel_str: []const u8,
    original_str: []const u8,
    replacement_str: []const u8,
) BuiltinError!Value {
    var sel = selector_mod.parse(ctx.allocator, sel_str) catch return error.SassError;
    defer sel.deinit();
    if (selectorListHasShallowParentSelector(&sel)) return error.SassError;

    var original = selector_mod.parse(ctx.allocator, original_str) catch return error.SassError;
    defer original.deinit();
    for (original.selectors.items) |original_complex| {
        if (compoundCountInComplex(&original_complex) > 1) return error.SassError;
        if (complexHasShallowParentSelector(&original_complex)) return error.SassError;
    }

    var replacement = selector_mod.parse(ctx.allocator, replacement_str) catch return error.SassError;
    defer replacement.deinit();
    if (selectorListHasShallowParentSelector(&replacement)) return error.SassError;

    var result = SelectorList.init(ctx.allocator);
    errdefer result.deinit();

    for (sel.selectors.items) |sel_complex| {
        if (original.selectors.items.len == 1) {
            if (try replaceSelectorPseudoTargets(ctx.allocator, &sel_complex, &original.selectors.items[0], &replacement)) |replaced_value| {
                var replaced = replaced_value;
                defer replaced.deinit();
                for (replaced.selectors.items) |new_complex| {
                    try result.selectors.append(ctx.allocator, try new_complex.clone(ctx.allocator));
                }
                continue;
            }
        }

        var single = SelectorList.init(ctx.allocator);
        try single.selectors.append(ctx.allocator, try sel_complex.clone(ctx.allocator));
        defer single.deinit();

        var extended_single = try extend_mod.applySelectorFunctionReplace(
            ctx.allocator,
            &single,
            &original,
            &replacement,
            addSelectorExtensionTargets,
        );
        defer extended_single.deinit();

        trimSuperselectedResults(&extended_single, &single, false);

        if (extended_single.selectors.items.len == 0) {
            try result.selectors.append(ctx.allocator, try sel_complex.clone(ctx.allocator));
        } else {
            const original_css = try selectorToCssSingle(ctx.allocator, &sel_complex);
            defer ctx.allocator.free(original_css);

            var changed = false;
            for (extended_single.selectors.items) |new_complex| {
                const new_css = try selectorToCssSingle(ctx.allocator, &new_complex);
                defer ctx.allocator.free(new_css);
                if (!std.mem.eql(u8, original_css, new_css)) {
                    changed = true;
                    break;
                }
            }

            if (!changed) {
                try result.selectors.append(ctx.allocator, try sel_complex.clone(ctx.allocator));
            } else {
                for (extended_single.selectors.items) |new_complex| {
                    const new_css = try selectorToCssSingle(ctx.allocator, &new_complex);
                    defer ctx.allocator.free(new_css);
                    if (std.mem.eql(u8, original_css, new_css)) continue;
                    try result.selectors.append(ctx.allocator, try new_complex.clone(ctx.allocator));
                }
            }
        }
    }

    if (result.selectors.items.len == 0) {
        result.deinit();
        const result_css = try selector_mod.toCss(ctx.allocator, &sel);
        defer ctx.allocator.free(result_css);
        return makeUnquotedStringValue(ctx, result_css);
    }

    defer result.deinit();
    return selectorListToValue(ctx, &result);
}

const PseudoSelectorKind = enum {
    class,
    element,
};

fn clonePseudoSelectorWithInner(
    allocator: std.mem.Allocator,
    kind: PseudoSelectorKind,
    pseudo: PseudoSelector,
    inner: *SelectorList,
) std.mem.Allocator.Error!SimpleSelector {
    return switch (kind) {
        .class => try selector_mod.cloneSimpleSelector(.{
            .pseudo_class = .{
                .name = pseudo.name,
                .argument = pseudo.argument,
                .selector = inner,
            },
        }, allocator),
        .element => try selector_mod.cloneSimpleSelector(.{
            .pseudo_element = .{
                .name = pseudo.name,
                .argument = pseudo.argument,
                .selector = inner,
            },
        }, allocator),
    };
}

fn replaceSelectorPseudoTargets(
    allocator: std.mem.Allocator,
    complex: *const ComplexSelector,
    original_complex: *const ComplexSelector,
    replacement: *const SelectorList,
) !?SelectorList {
    if (original_complex.components.items.len != 1 or original_complex.components.items[0] != .compound) return null;
    const target = original_complex.components.items[0].compound;

    var changed = false;
    var out_complex = ComplexSelector.init(allocator);
    errdefer out_complex.deinit();
    var pseudo_replace_arena = std.heap.ArenaAllocator.init(allocator);
    defer pseudo_replace_arena.deinit();

    for (complex.components.items) |comp| {
        switch (comp) {
            .combinator => |comb| try out_complex.components.append(allocator, .{ .combinator = comb }),
            .compound => |compound| {
                var out_compound = CompoundSelector.init(allocator);
                errdefer out_compound.deinit();

                for (compound.simple_selectors.items) |ss| {
                    switch (ss) {
                        .pseudo_class => |ps| {
                            if (ps.selector) |inner| {
                                _ = pseudo_replace_arena.reset(.retain_capacity);
                                const arena_alloc = pseudo_replace_arena.allocator();
                                if (try replaceInPseudoSelectorList(arena_alloc, inner, target, replacement)) |new_inner| {
                                    changed = true;
                                    var owned_inner = new_inner;
                                    try out_compound.simple_selectors.append(
                                        allocator,
                                        try clonePseudoSelectorWithInner(allocator, .class, ps, &owned_inner),
                                    );
                                    continue;
                                }
                            }
                            try out_compound.simple_selectors.append(allocator, try selector_mod.cloneSimpleSelector(ss, allocator));
                        },
                        .pseudo_element => |ps| {
                            if (ps.selector) |inner| {
                                _ = pseudo_replace_arena.reset(.retain_capacity);
                                const arena_alloc = pseudo_replace_arena.allocator();
                                if (try replaceInPseudoSelectorList(arena_alloc, inner, target, replacement)) |new_inner| {
                                    changed = true;
                                    var owned_inner = new_inner;
                                    try out_compound.simple_selectors.append(
                                        allocator,
                                        try clonePseudoSelectorWithInner(allocator, .element, ps, &owned_inner),
                                    );
                                    continue;
                                }
                            }
                            try out_compound.simple_selectors.append(allocator, try selector_mod.cloneSimpleSelector(ss, allocator));
                        },
                        else => try out_compound.simple_selectors.append(allocator, try selector_mod.cloneSimpleSelector(ss, allocator)),
                    }
                }

                try out_complex.components.append(allocator, .{ .compound = out_compound });
            },
        }
    }

    if (!changed) {
        out_complex.deinit();
        return null;
    }

    var out = SelectorList.init(allocator);
    errdefer out.deinit();
    try out.selectors.append(allocator, out_complex);
    return out;
}

fn replaceInPseudoSelectorList(
    allocator: std.mem.Allocator,
    inner: *const SelectorList,
    target: CompoundSelector,
    replacement: *const SelectorList,
) !?SelectorList {
    var changed = false;
    var out = SelectorList.init(allocator);
    errdefer out.deinit();

    for (inner.selectors.items) |inner_complex| {
        if (try replaceSingleCompoundComplex(allocator, &inner_complex, target, replacement)) |replaced_items| {
            defer {
                for (replaced_items) |*item| item.deinit();
                allocator.free(replaced_items);
            }
            changed = true;
            for (replaced_items) |item| {
                try out.selectors.append(allocator, try item.clone(allocator));
            }
            continue;
        }

        try out.selectors.append(allocator, try inner_complex.clone(allocator));
    }

    if (!changed) {
        out.deinit();
        return null;
    }
    return out;
}

fn replaceSingleCompoundComplex(
    allocator: std.mem.Allocator,
    complex: *const ComplexSelector,
    target: CompoundSelector,
    replacement: *const SelectorList,
) !?[]ComplexSelector {
    if (complex.components.items.len != 1 or complex.components.items[0] != .compound) return null;
    const compound = complex.components.items[0].compound;
    if (!compoundContainsUnifyTarget(compound, target)) return null;

    var results: std.ArrayList(ComplexSelector) = .empty;
    errdefer {
        for (results.items) |*item| item.deinit();
        results.deinit(allocator);
    }
    try results.ensureTotalCapacity(allocator, replacement.selectors.items.len);

    for (replacement.selectors.items) |replacement_complex| {
        if (replacement_complex.components.items.len != 1 or replacement_complex.components.items[0] != .compound) continue;
        const merged = try replaceCompoundSelector(allocator, compound, target, replacement_complex.components.items[0].compound) orelse continue;
        errdefer {
            var tmp = merged;
            tmp.deinit();
        }

        var out_complex = ComplexSelector.init(allocator);
        errdefer out_complex.deinit();
        try out_complex.components.append(allocator, .{ .compound = merged });
        results.appendAssumeCapacity(out_complex);
    }

    if (results.items.len == 0) {
        results.deinit(allocator);
        return null;
    }
    return try results.toOwnedSlice(allocator);
}

fn replaceCompoundSelector(
    allocator: std.mem.Allocator,
    compound: CompoundSelector,
    target: CompoundSelector,
    replacement: CompoundSelector,
) !?CompoundSelector {
    var merged = CompoundSelector.init(allocator);
    errdefer merged.deinit();

    for (compound.simple_selectors.items) |ss| {
        if (simpleSelectorInCompound(ss, target)) continue;
        try merged.simple_selectors.append(allocator, try selector_mod.cloneSimpleSelector(ss, allocator));
    }
    for (replacement.simple_selectors.items) |ss| {
        var dup = false;
        for (merged.simple_selectors.items) |existing| {
            if (simpleSelectorEql(ss, existing)) {
                dup = true;
                break;
            }
        }
        if (!dup) {
            try merged.simple_selectors.append(allocator, try selector_mod.cloneSimpleSelector(ss, allocator));
        }
    }

    sortCompoundSelectors(&merged);
    return merged;
}

fn simpleSelectorToCssAlloc(allocator: std.mem.Allocator, ss: SimpleSelector) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    switch (ss) {
        .type_selector => |n| try buf.appendSlice(allocator, n),
        .class => |n| {
            try buf.append(allocator, '.');
            try buf.appendSlice(allocator, n);
        },
        .id => |n| {
            try buf.append(allocator, '#');
            try buf.appendSlice(allocator, n);
        },
        .pseudo_class => |ps| {
            try buf.append(allocator, ':');
            try buf.appendSlice(allocator, ps.name);
            if (ps.argument) |a| {
                try buf.append(allocator, '(');
                try buf.appendSlice(allocator, a);
                try buf.append(allocator, ')');
            } else if (ps.selector) |sel| {
                try buf.append(allocator, '(');
                const inner = try selector_mod.toCss(allocator, sel);
                defer allocator.free(inner);
                try buf.appendSlice(allocator, inner);
                try buf.append(allocator, ')');
            }
        },
        .pseudo_element => |ps| {
            try buf.appendSlice(allocator, "::");
            try buf.appendSlice(allocator, ps.name);
            if (ps.argument) |a| {
                try buf.append(allocator, '(');
                try buf.appendSlice(allocator, a);
                try buf.append(allocator, ')');
            } else if (ps.selector) |sel| {
                try buf.append(allocator, '(');
                const inner = try selector_mod.toCss(allocator, sel);
                defer allocator.free(inner);
                try buf.appendSlice(allocator, inner);
                try buf.append(allocator, ')');
            }
        },
        .attribute => |attr| {
            try buf.append(allocator, '[');
            try buf.appendSlice(allocator, attr.name);
            if (attr.op) |op| {
                try buf.appendSlice(allocator, op.toCss());
                if (attr.value) |v| {
                    try buf.append(allocator, '"');
                    try buf.appendSlice(allocator, v);
                    try buf.append(allocator, '"');
                }
            }
            if (attr.modifier) |mod| {
                try buf.append(allocator, ' ');
                try buf.append(allocator, mod);
            }
            try buf.append(allocator, ']');
        },
        .placeholder => |n| {
            try buf.append(allocator, '%');
            try buf.appendSlice(allocator, n);
        },
        .parent => try buf.append(allocator, '&'),
        .universal => try buf.append(allocator, '*'),
    }

    return try buf.toOwnedSlice(allocator);
}

fn complexSelectorsEqualForResult(
    a: *const ComplexSelector,
    b: *const ComplexSelector,
) bool {
    const allocator = std.heap.page_allocator;
    const a_css = selectorToCssSingle(allocator, a) catch return false;
    defer allocator.free(a_css);
    const b_css = selectorToCssSingle(allocator, b) catch return false;
    defer allocator.free(b_css);
    return std.mem.eql(u8, a_css, b_css);
}

fn selectorToCssSingle(
    allocator: std.mem.Allocator,
    complex: *const ComplexSelector,
) ![]const u8 {
    var list = SelectorList.init(allocator);
    defer list.deinit();
    try list.selectors.append(allocator, try complex.clone(allocator));
    return selector_mod.toCss(allocator, &list);
}

fn selectorAppendBaseIsValid(list: *const SelectorList) bool {
    for (list.selectors.items) |complex| {
        if (!complexCanAcceptAppendSuffix(&complex)) return false;
    }
    return true;
}

fn selectorAppendSuffixIsValid(list: *const SelectorList) bool {
    for (list.selectors.items) |complex| {
        if (complex.components.items.len == 0) return false;
        if (complex.components.items[0] != .compound) return false;

        const first_compound = complex.components.items[0].compound;
        if (first_compound.simple_selectors.items.len == 0) return false;

        const first_simple = first_compound.simple_selectors.items[0];
        switch (first_simple) {
            .parent, .universal => return false,
            .type_selector => |name| {
                if (std.mem.findScalar(u8, name, '|') != null) return false;
                if (std.mem.eql(u8, name, "*")) return false;
            },
            else => {},
        }
    }
    return true;
}

fn complexCanAcceptAppendSuffix(complex: *const ComplexSelector) bool {
    const idx = getLastCompoundIdxStatic(complex) orelse return false;
    if (idx + 1 != complex.components.items.len) return false;
    const compound = complex.components.items[idx].compound;
    if (compound.simple_selectors.items.len == 0) return false;

    const last_simple = compound.simple_selectors.items[compound.simple_selectors.items.len - 1];
    return switch (last_simple) {
        .universal => false,
        .type_selector => |name| !std.mem.eql(u8, name, "*") and !std.mem.endsWith(u8, name, "|*"),
        else => true,
    };
}

fn getLastCompoundIdxStatic(complex: *const ComplexSelector) ?usize {
    var last_idx: ?usize = null;
    for (complex.components.items, 0..) |comp, idx| {
        if (comp == .compound) last_idx = idx;
    }
    return last_idx;
}

fn combinedExtendeeTarget(allocator: std.mem.Allocator, extendee: *const SelectorList) !?CompoundSelector {
    if (extendee.selectors.items.len <= 1) return null;

    var combined: ?CompoundSelector = null;
    errdefer if (combined) |*compound| compound.deinit();

    for (extendee.selectors.items) |extendee_complex| {
        var target_compound: ?CompoundSelector = null;
        for (extendee_complex.components.items) |comp| {
            if (comp == .compound) target_compound = comp.compound;
        }
        if (target_compound == null) return null;

        if (combined == null) {
            combined = try target_compound.?.clone(allocator);
            continue;
        }

        const merged = try unifyCompounds(allocator, combined.?, target_compound.?);
        if (merged == null) return null;

        combined.?.deinit();
        combined = merged.?;
    }

    return combined;
}

fn addSelectorExtensionTargets(
    allocator: std.mem.Allocator,
    store: *ApplyState,
    extendee: *const SelectorList,
    extender: *const SelectorList,
) !void {
    for (extendee.selectors.items) |extendee_complex| {
        var target_compound: ?CompoundSelector = null;
        for (extendee_complex.components.items) |comp| {
            if (comp == .compound) target_compound = comp.compound;
        }
        if (target_compound) |tc| {
            var target_clone = try tc.clone(allocator);
            errdefer target_clone.deinit();
            const extender_clone = try extender.clone(allocator);
            try store.addExtension(.{
                .extender = extender_clone,
                .target = target_clone,
                .optional = false,
                .span = null,
            });
        }
    }

    if (try combinedExtendeeTarget(allocator, extendee)) |combined_target| {
        var target_clone = combined_target;
        errdefer target_clone.deinit();
        const extender_clone = try extender.clone(allocator);
        try store.addExtension(.{
            .extender = extender_clone,
            .target = target_clone,
            .optional = false,
            .span = null,
        });
    }
}

fn getLastCompoundValue(complex: *const ComplexSelector) ?CompoundSelector {
    var last: ?CompoundSelector = null;
    for (complex.components.items) |comp| {
        if (comp == .compound) last = comp.compound;
    }
    return last;
}

fn unifyCompounds(allocator: std.mem.Allocator, c1: CompoundSelector, c2: CompoundSelector) !?CompoundSelector {
    var type1: ?[]const u8 = null;
    var type2: ?[]const u8 = null;
    var has_universal1 = false;
    var has_universal2 = false;

    for (c1.simple_selectors.items) |ss| {
        switch (ss) {
            .type_selector => |t| type1 = t,
            .universal => has_universal1 = true,
            else => {},
        }
    }
    for (c2.simple_selectors.items) |ss| {
        switch (ss) {
            .type_selector => |t| type2 = t,
            .universal => has_universal2 = true,
            else => {},
        }
    }

    const a_full: []const u8 = type1 orelse if (has_universal1) "*" else "";
    const b_full: []const u8 = type2 orelse if (has_universal2) "*" else "";
    const a_has = type1 != null or has_universal1;
    const b_has = type2 != null or has_universal2;

    var unified_type: ?[]const u8 = null;
    var unified_is_universal = false;

    if (a_has and b_has) {
        const result = try unifyNsSelectors(allocator, a_full, has_universal1, b_full, has_universal2);
        if (result == null) return null;
        const r = result.?;
        if (std.mem.eql(u8, r, "*")) {
            unified_is_universal = true;
            allocator.free(r);
        } else {
            unified_type = r;
        }
    } else if (a_has and !b_has) {
        if (type1) |t| {
            unified_type = try allocator.dupe(u8, t);
        } else if (c2.simple_selectors.items.len == 0) {
            unified_is_universal = true;
        }
    } else if (b_has and !a_has) {
        if (type2) |t| {
            unified_type = try allocator.dupe(u8, t);
        } else if (c1.simple_selectors.items.len == 0) {
            unified_is_universal = true;
        }
    }

    {
        var id1: ?[]const u8 = null;
        var id2: ?[]const u8 = null;
        for (c1.simple_selectors.items) |ss| {
            if (ss == .id) id1 = ss.id;
        }
        for (c2.simple_selectors.items) |ss| {
            if (ss == .id) id2 = ss.id;
        }
        if (id1 != null and id2 != null and !std.mem.eql(u8, id1.?, id2.?)) return null;
    }

    var pe1: ?SimpleSelector = null;
    var pe2: ?SimpleSelector = null;
    for (c1.simple_selectors.items) |ss| {
        switch (ss) {
            .pseudo_element => pe1 = ss,
            .pseudo_class => |pc| {
                if (isLegacyPseudoElement(pc.name)) pe1 = ss;
            },
            else => {},
        }
    }
    for (c2.simple_selectors.items) |ss| {
        switch (ss) {
            .pseudo_element => pe2 = ss,
            .pseudo_class => |pc| {
                if (isLegacyPseudoElement(pc.name)) pe2 = ss;
            },
            else => {},
        }
    }
    if (pe1 != null and pe2 != null) {
        if (!pseudoElementsCompatibleForUnify(pe1.?, pe2.?)) return null;
    }

    const has_host1 = hasHostSelector(c1);
    const has_host2 = hasHostSelector(c2);
    if (has_host1 and !canUnifyWithHost(c2)) return null;
    if (has_host2 and !canUnifyWithHost(c1)) return null;

    return @as(?CompoundSelector, try mergeUnifiedCompoundSelectors(
        allocator,
        c1,
        c2,
        unified_type,
        unified_is_universal,
        if (pe1) |pseudo| pseudoElementName(pseudo) else null,
    ));
}

fn mergeUnifiedCompoundSelectors(
    allocator: std.mem.Allocator,
    c1: CompoundSelector,
    c2: CompoundSelector,
    unified_type: ?[]const u8,
    unified_is_universal: bool,
    existing_pseudo_name: ?[]const u8,
) !CompoundSelector {
    var merged = CompoundSelector.init(allocator);
    errdefer merged.deinit();

    if (unified_type) |ut| {
        try merged.simple_selectors.append(allocator, .{ .type_selector = ut });
    } else if (unified_is_universal) {
        try merged.simple_selectors.append(allocator, .{ .universal = {} });
    }

    const placement1 = compoundPseudoPlacement(c1);
    const placement2 = compoundPseudoPlacement(c2);
    const split1 = placement1.pseudo_index orelse c1.simple_selectors.items.len;
    const split2 = placement2.pseudo_index orelse c2.simple_selectors.items.len;

    if (hasHostSelector(c1) and !hasHostSelector(c2)) {
        if (firstSelectorPseudoIndex(c2, 0, split2)) |selector_pseudo_idx| {
            try appendCompoundSegment(allocator, &merged, c2, 0, selector_pseudo_idx + 1, existing_pseudo_name);
            try appendCompoundSegment(allocator, &merged, c1, 0, split1, existing_pseudo_name);
            try appendCompoundSegment(allocator, &merged, c2, selector_pseudo_idx + 1, split2, existing_pseudo_name);
        } else {
            try appendCompoundSegment(allocator, &merged, c1, 0, split1, existing_pseudo_name);
            try appendCompoundSegment(allocator, &merged, c2, 0, split2, existing_pseudo_name);
        }
    } else {
        try appendCompoundSegment(allocator, &merged, c1, 0, split1, existing_pseudo_name);
        try appendCompoundSegment(allocator, &merged, c2, 0, split2, existing_pseudo_name);
    }

    const pre_start: usize = if (unified_type != null or unified_is_universal) 1 else 0;
    if (merged.simple_selectors.items.len > pre_start) {
        sortSimpleSelectorSlice(merged.simple_selectors.items[pre_start..]);
    }

    if (placement1.pseudo_index) |idx| {
        try appendUniqueSimpleSelector(allocator, &merged, c1.simple_selectors.items[idx], null);
    }
    if (placement2.pseudo_index) |idx| {
        try appendUniqueSimpleSelector(allocator, &merged, c2.simple_selectors.items[idx], existing_pseudo_name);
    }

    const after1 = if (placement1.pseudo_index) |idx| idx + 1 else c1.simple_selectors.items.len;
    const after2 = if (placement2.pseudo_index) |idx| idx + 1 else c2.simple_selectors.items.len;
    try appendCompoundSegment(allocator, &merged, c1, after1, c1.simple_selectors.items.len, existing_pseudo_name);
    try appendCompoundSegment(allocator, &merged, c2, after2, c2.simple_selectors.items.len, existing_pseudo_name);

    return merged;
}

fn getLastCompoundIdx(complex: *const ComplexSelector) ?usize {
    var last_idx: ?usize = null;
    for (complex.components.items, 0..) |comp, idx| {
        if (comp == .compound) last_idx = idx;
    }
    return last_idx;
}

fn unifyComplexSelectors(
    allocator: std.mem.Allocator,
    complex1: *const ComplexSelector,
    complex2: *const ComplexSelector,
) ![]ComplexSelector {
    if (!complexSupportsUnify(complex1) or !complexSupportsUnify(complex2)) {
        return allocator.alloc(ComplexSelector, 0);
    }

    const last1 = getLastCompoundValue(complex1) orelse return allocator.alloc(ComplexSelector, 0);
    const last2 = getLastCompoundValue(complex2) orelse return allocator.alloc(ComplexSelector, 0);
    const merged = try unifyCompounds(allocator, last1, last2) orelse return allocator.alloc(ComplexSelector, 0);
    errdefer {
        var tmp = merged;
        tmp.deinit();
    }

    const last1_idx = getLastCompoundIdx(complex1) orelse return allocator.alloc(ComplexSelector, 0);
    const last2_idx = getLastCompoundIdx(complex2) orelse return allocator.alloc(ComplexSelector, 0);
    const prefix1 = complex1.components.items[0..last1_idx];
    const prefix2 = complex2.components.items[0..last2_idx];

    var prefix_results = try unifySelectorPrefixes(allocator, prefix1, prefix2);
    defer {
        for (prefix_results.items) |*prefix| prefix.deinit();
        prefix_results.deinit(allocator);
    }

    if (prefix_results.items.len == 0) {
        if (prefix1.len != 0 or prefix2.len != 0) {
            var merged_tmp = merged;
            merged_tmp.deinit();
            return allocator.alloc(ComplexSelector, 0);
        }
        var unified = ComplexSelector.init(allocator);
        errdefer unified.deinit();
        try unified.components.append(allocator, .{ .compound = merged });
        const out = try allocator.alloc(ComplexSelector, 1);
        out[0] = unified;
        return out;
    }

    var results: std.ArrayList(ComplexSelector) = .empty;
    errdefer {
        for (results.items) |*item| item.deinit();
        results.deinit(allocator);
    }
    try results.ensureTotalCapacity(allocator, prefix_results.items.len);

    for (prefix_results.items) |prefix| {
        var unified = ComplexSelector.init(allocator);
        errdefer unified.deinit();
        try unified.components.ensureTotalCapacity(allocator, prefix.components.items.len + 1);
        for (prefix.components.items) |comp| {
            switch (comp) {
                .compound => |c| unified.components.appendAssumeCapacity(.{ .compound = try c.clone(allocator) }),
                .combinator => |comb| unified.components.appendAssumeCapacity(.{ .combinator = comb }),
            }
        }
        unified.components.appendAssumeCapacity(.{ .compound = try merged.clone(allocator) });
        results.appendAssumeCapacity(unified);
    }

    var merged_tmp = merged;
    merged_tmp.deinit();
    return try results.toOwnedSlice(allocator);
}

fn prefixAllCombinatorsAre(
    prefix: []const ComplexSelectorComponent,
    combinator: Combinator,
) bool {
    for (prefix) |comp| {
        switch (comp) {
            .compound => {},
            .combinator => |actual| if (actual != combinator) return false,
        }
    }
    return true;
}

fn appendComponentClone(
    allocator: std.mem.Allocator,
    dest: *ComplexSelector,
    comp: ComplexSelectorComponent,
) !void {
    switch (comp) {
        .compound => |c| try dest.components.append(allocator, .{ .compound = try c.clone(allocator) }),
        .combinator => |comb| try dest.components.append(allocator, .{ .combinator = comb }),
    }
}

fn appendComplexClone(
    allocator: std.mem.Allocator,
    dest: *ComplexSelector,
    src: *const ComplexSelector,
) !void {
    for (src.components.items) |comp| {
        try appendComponentClone(allocator, dest, comp);
    }
}

fn appendDescendantCompounds(
    allocator: std.mem.Allocator,
    dest: *ComplexSelector,
    compounds: []const CompoundSelector,
) !void {
    for (compounds) |compound| {
        try dest.components.append(allocator, .{ .compound = try compound.clone(allocator) });
        try dest.components.append(allocator, .{ .combinator = .descendant });
    }
}

fn descendantPrefixCompounds(
    allocator: std.mem.Allocator,
    prefix: []const ComplexSelectorComponent,
) ![]CompoundSelector {
    var compounds: std.ArrayList(CompoundSelector) = .empty;
    errdefer {
        for (compounds.items) |*compound| compound.deinit();
        compounds.deinit(allocator);
    }
    try compounds.ensureTotalCapacity(allocator, prefix.len);

    for (prefix) |comp| {
        switch (comp) {
            .compound => |compound| compounds.appendAssumeCapacity(try compound.clone(allocator)),
            .combinator => {},
        }
    }

    return try compounds.toOwnedSlice(allocator);
}

fn deinitCompoundSlice(allocator: std.mem.Allocator, compounds: []CompoundSelector) void {
    for (compounds) |*compound| compound.deinit();
    allocator.free(compounds);
}

fn getLastCompoundFromSlice(components: []const ComplexSelectorComponent) ?*const CompoundSelector {
    var i: usize = components.len;
    while (i > 0) {
        i -= 1;
        if (components[i] == .compound) return &components[i].compound;
    }
    return null;
}

fn prefixBeforeLastCompoundKeepCombinator(
    prefix: []const ComplexSelectorComponent,
) []const ComplexSelectorComponent {
    var i: usize = prefix.len;
    while (i > 0) {
        i -= 1;
        if (prefix[i] == .compound) return prefix[0..i];
    }
    return prefix[0..0];
}

fn prependLeadingCombinatorToResults(
    allocator: std.mem.Allocator,
    results: *std.ArrayList(ComplexSelector),
    leading_comb: ?Combinator,
) !void {
    if (leading_comb == null) return;
    const comb = leading_comb.?;

    for (results.items) |*sel| {
        var with_leading = ComplexSelector.init(allocator);
        errdefer with_leading.deinit();
        try with_leading.components.append(allocator, .{ .combinator = comb });
        try appendComplexClone(allocator, &with_leading, sel);
        sel.deinit();
        sel.* = with_leading;
    }
}

fn canonicalCommonCompound(
    allocator: std.mem.Allocator,
    a: CompoundSelector,
    b: CompoundSelector,
) !?CompoundSelector {
    if (compoundIsSuperSelectorWrapped(&a, &b)) return try b.clone(allocator);
    if (compoundIsSuperSelectorWrapped(&b, &a)) return try a.clone(allocator);
    if (compoundsRequireSameElement(a, b)) {
        if (compoundsRequireReverseForcedMerge(a, b)) {
            return try unifyCompounds(allocator, b, a);
        }
        return try unifyCompounds(allocator, a, b);
    }
    return null;
}

const MatchIndex = struct {
    i: usize,
    j: usize,
};

fn longestCommonCompoundSubsequence(
    allocator: std.mem.Allocator,
    seq1: []const CompoundSelector,
    seq2: []const CompoundSelector,
) std.mem.Allocator.Error![]MatchIndex {
    const rows = seq1.len + 1;
    const cols = seq2.len + 1;
    var dp = try allocator.alloc(usize, rows * cols);
    defer allocator.free(dp);
    @memset(dp, 0);

    var i: usize = seq1.len;
    while (i > 0) {
        i -= 1;
        var j: usize = seq2.len;
        while (j > 0) {
            j -= 1;
            const idx = i * cols + j;
            const has_common = blk: {
                if (try canonicalCommonCompound(allocator, seq1[i], seq2[j])) |common| {
                    var tmp = common;
                    tmp.deinit();
                    break :blk true;
                }
                break :blk false;
            };
            if (has_common) {
                dp[idx] = dp[(i + 1) * cols + (j + 1)] + 1;
            } else {
                const skip1 = dp[(i + 1) * cols + j];
                const skip2 = dp[i * cols + (j + 1)];
                dp[idx] = if (skip1 >= skip2) skip1 else skip2;
            }
        }
    }

    var out: std.ArrayList(MatchIndex) = .empty;
    errdefer out.deinit(allocator);

    i = 0;
    var j: usize = 0;
    while (i < seq1.len and j < seq2.len) {
        if (dp[i * cols + j] == dp[(i + 1) * cols + (j + 1)] + 1) {
            if (try canonicalCommonCompound(allocator, seq1[i], seq2[j])) |common| {
                var tmp = common;
                tmp.deinit();
                try out.append(allocator, .{ .i = i, .j = j });
                i += 1;
                j += 1;
                continue;
            }
        }

        const skip1 = dp[(i + 1) * cols + j];
        const skip2 = dp[i * cols + (j + 1)];
        if (skip1 >= skip2) {
            i += 1;
        } else {
            j += 1;
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn unifyDescendantCompoundPrefixes(
    allocator: std.mem.Allocator,
    seq1: []const CompoundSelector,
    seq2: []const CompoundSelector,
) std.mem.Allocator.Error!std.ArrayList(ComplexSelector) {
    var results: std.ArrayList(ComplexSelector) = .empty;
    errdefer {
        for (results.items) |*item| item.deinit();
        results.deinit(allocator);
    }

    if (seq1.len == 0 and seq2.len == 0) {
        try results.append(allocator, ComplexSelector.init(allocator));
        return results;
    }
    if (seq1.len == 0) {
        var only_second = ComplexSelector.init(allocator);
        errdefer only_second.deinit();
        try appendDescendantCompounds(allocator, &only_second, seq2);
        try results.append(allocator, only_second);
        return results;
    }
    if (seq2.len == 0) {
        var only_first = ComplexSelector.init(allocator);
        errdefer only_first.deinit();
        try appendDescendantCompounds(allocator, &only_first, seq1);
        try results.append(allocator, only_first);
        return results;
    }

    const matches = try longestCommonCompoundSubsequence(allocator, seq1, seq2);
    defer allocator.free(matches);

    if (matches.len == 0) {
        const seq1_rootish = seq1.len > 0 and compoundHasRootishConstraint(seq1[0]);
        const seq2_rootish = seq2.len > 0 and compoundHasRootishConstraint(seq2[0]);

        if (seq1_rootish and seq2_rootish) {
            const merged_root = try canonicalCommonCompound(allocator, seq1[0], seq2[0]) orelse return results;
            defer {
                var tmp = merged_root;
                tmp.deinit();
            }

            var suffix_results = try unifyDescendantCompoundPrefixes(allocator, seq1[1..], seq2[1..]);
            defer {
                for (suffix_results.items) |*item| item.deinit();
                suffix_results.deinit(allocator);
            }
            try results.ensureUnusedCapacity(allocator, suffix_results.items.len);

            for (suffix_results.items) |suffix| {
                var combined = ComplexSelector.init(allocator);
                errdefer combined.deinit();
                try combined.components.append(allocator, .{ .compound = try merged_root.clone(allocator) });
                if (suffix.components.items.len > 0) {
                    try combined.components.append(allocator, .{ .combinator = .descendant });
                    try appendComplexClone(allocator, &combined, &suffix);
                }
                results.appendAssumeCapacity(combined);
            }
            return results;
        }

        if (seq1_rootish or seq2_rootish) {
            const rootish_compound = if (seq1_rootish) seq1[0] else seq2[0];
            const left_suffix = if (seq1_rootish) seq1[1..] else seq1;
            const right_suffix = if (seq2_rootish) seq2[1..] else seq2;
            var suffix_results = try unifyDescendantCompoundPrefixes(allocator, left_suffix, right_suffix);
            defer {
                for (suffix_results.items) |*item| item.deinit();
                suffix_results.deinit(allocator);
            }
            try results.ensureUnusedCapacity(allocator, suffix_results.items.len);

            for (suffix_results.items) |suffix| {
                var combined = ComplexSelector.init(allocator);
                errdefer combined.deinit();
                try combined.components.append(allocator, .{ .compound = try rootish_compound.clone(allocator) });
                if (suffix.components.items.len > 0) {
                    try combined.components.append(allocator, .{ .combinator = .descendant });
                    try appendComplexClone(allocator, &combined, &suffix);
                }
                results.appendAssumeCapacity(combined);
            }
            return results;
        }

        var first_then_second = ComplexSelector.init(allocator);
        errdefer first_then_second.deinit();
        try appendDescendantCompounds(allocator, &first_then_second, seq1);
        try appendDescendantCompounds(allocator, &first_then_second, seq2);
        try results.append(allocator, first_then_second);

        var second_then_first = ComplexSelector.init(allocator);
        errdefer second_then_first.deinit();
        try appendDescendantCompounds(allocator, &second_then_first, seq2);
        try appendDescendantCompounds(allocator, &second_then_first, seq1);
        try results.append(allocator, second_then_first);
        return results;
    }

    var partials: std.ArrayList(ComplexSelector) = .empty;
    defer {
        for (partials.items) |*item| item.deinit();
        partials.deinit(allocator);
    }
    try partials.append(allocator, ComplexSelector.init(allocator));

    var start1: usize = 0;
    var start2: usize = 0;
    for (matches) |match| {
        var segment_results = try unifyDescendantCompoundPrefixes(allocator, seq1[start1..match.i], seq2[start2..match.j]);
        defer {
            for (segment_results.items) |*item| item.deinit();
            segment_results.deinit(allocator);
        }

        var common = (try canonicalCommonCompound(allocator, seq1[match.i], seq2[match.j])).?;
        defer common.deinit();

        var next_partials: std.ArrayList(ComplexSelector) = .empty;
        errdefer {
            for (next_partials.items) |*item| item.deinit();
            next_partials.deinit(allocator);
        }
        try next_partials.ensureTotalCapacity(allocator, segment_results.items.len * partials.items.len);

        for (segment_results.items) |segment| {
            for (partials.items) |partial| {
                var combined = ComplexSelector.init(allocator);
                errdefer combined.deinit();
                try appendComplexClone(allocator, &combined, &partial);
                try appendComplexClone(allocator, &combined, &segment);
                try combined.components.append(allocator, .{ .compound = try common.clone(allocator) });
                try combined.components.append(allocator, .{ .combinator = .descendant });
                next_partials.appendAssumeCapacity(combined);
            }
        }

        for (partials.items) |*item| item.deinit();
        partials.deinit(allocator);
        partials = next_partials;

        start1 = match.i + 1;
        start2 = match.j + 1;
    }

    var trailing_results = try unifyDescendantCompoundPrefixes(allocator, seq1[start1..], seq2[start2..]);
    defer {
        for (trailing_results.items) |*item| item.deinit();
        trailing_results.deinit(allocator);
    }

    for (partials.items) |partial| {
        for (trailing_results.items) |trailing| {
            var combined = ComplexSelector.init(allocator);
            errdefer combined.deinit();
            try appendComplexClone(allocator, &combined, &partial);
            try appendComplexClone(allocator, &combined, &trailing);
            try results.append(allocator, combined);
        }
    }

    return results;
}

fn unifyAdjacentGeneralPrefixes(
    allocator: std.mem.Allocator,
    adjacent_base: []const ComplexSelectorComponent,
    broader_base: []const ComplexSelectorComponent,
) std.mem.Allocator.Error!std.ArrayList(ComplexSelector) {
    var results: std.ArrayList(ComplexSelector) = .empty;
    errdefer {
        for (results.items) |*item| item.deinit();
        results.deinit(allocator);
    }

    const adjacent_tail = getLastCompoundFromSlice(adjacent_base) orelse return results;
    const broader_tail = getLastCompoundFromSlice(broader_base) orelse return results;

    const adjacent_leading = prefixBeforeLastCompoundKeepCombinator(adjacent_base);
    const broader_leading = prefixBeforeLastCompoundKeepCombinator(broader_base);

    var leading_results = try unifySelectorPrefixes(allocator, adjacent_leading, broader_leading);
    defer {
        for (leading_results.items) |*item| item.deinit();
        leading_results.deinit(allocator);
    }

    const needs_empty_prefix = leading_results.items.len == 0 and
        adjacent_leading.len == 0 and broader_leading.len == 0;

    var lead_idx: usize = 0;
    while (lead_idx < leading_results.items.len or (needs_empty_prefix and lead_idx == 0)) : (lead_idx += 1) {
        if (!compoundIsSuperSelectorWrapped(broader_tail, adjacent_tail)) {
            var chained = ComplexSelector.init(allocator);
            errdefer chained.deinit();
            if (lead_idx < leading_results.items.len) {
                try appendComplexClone(allocator, &chained, &leading_results.items[lead_idx]);
            }
            try chained.components.append(allocator, .{ .compound = try broader_tail.clone(allocator) });
            try chained.components.append(allocator, .{ .combinator = .general_sibling });
            try chained.components.append(allocator, .{ .compound = try adjacent_tail.clone(allocator) });
            try chained.components.append(allocator, .{ .combinator = .next_sibling });
            try results.append(allocator, chained);
        }

        const merged = try unifyCompounds(allocator, broader_tail.*, adjacent_tail.*) orelse continue;
        defer {
            var tmp = merged;
            tmp.deinit();
        }
        var merged_prefix = ComplexSelector.init(allocator);
        errdefer merged_prefix.deinit();
        if (lead_idx < leading_results.items.len) {
            try appendComplexClone(allocator, &merged_prefix, &leading_results.items[lead_idx]);
        }
        try merged_prefix.components.append(allocator, .{ .compound = try merged.clone(allocator) });
        try merged_prefix.components.append(allocator, .{ .combinator = .next_sibling });
        try results.append(allocator, merged_prefix);
    }

    return results;
}

fn unifySiblingDescendantPrefixes(
    allocator: std.mem.Allocator,
    sibling_base: []const ComplexSelectorComponent,
    sibling_comb: Combinator,
    descendant_base: []const ComplexSelectorComponent,
) std.mem.Allocator.Error!std.ArrayList(ComplexSelector) {
    var results: std.ArrayList(ComplexSelector) = .empty;
    errdefer {
        for (results.items) |*item| item.deinit();
        results.deinit(allocator);
    }

    if (!prefixAllCombinatorsAre(sibling_base, .descendant) or
        !prefixAllCombinatorsAre(descendant_base, .descendant))
    {
        return results;
    }

    var combined = ComplexSelector.init(allocator);
    errdefer combined.deinit();
    try appendComplexComponentsClone(allocator, &combined, descendant_base);
    if (descendant_base.len > 0 and sibling_base.len > 0) {
        try combined.components.append(allocator, .{ .combinator = .descendant });
    }
    try appendComplexComponentsClone(allocator, &combined, sibling_base);
    try combined.components.append(allocator, .{ .combinator = sibling_comb });
    try results.append(allocator, combined);
    return results;
}

fn appendComplexComponentsClone(
    allocator: std.mem.Allocator,
    dest: *ComplexSelector,
    components: []const ComplexSelectorComponent,
) !void {
    for (components) |comp| {
        try appendComponentClone(allocator, dest, comp);
    }
}

fn unifySelectorPrefixes(
    allocator: std.mem.Allocator,
    prefix1: []const ComplexSelectorComponent,
    prefix2: []const ComplexSelectorComponent,
) std.mem.Allocator.Error!std.ArrayList(ComplexSelector) {
    var results: std.ArrayList(ComplexSelector) = .empty;
    errdefer {
        for (results.items) |*item| item.deinit();
        results.deinit(allocator);
    }

    if (prefixHasUnsupportedRuns(prefix1) or prefixHasUnsupportedRuns(prefix2)) {
        return results;
    }

    const PrefixInfo = struct {
        base: []const ComplexSelectorComponent,
        comb: Combinator,
    };

    const p1: PrefixInfo = if (prefix1.len > 0 and prefix1[prefix1.len - 1] == .combinator)
        .{ .base = prefix1[0 .. prefix1.len - 1], .comb = prefix1[prefix1.len - 1].combinator }
    else
        .{ .base = prefix1, .comb = .descendant };
    const p2: PrefixInfo = if (prefix2.len > 0 and prefix2[prefix2.len - 1] == .combinator)
        .{ .base = prefix2[0 .. prefix2.len - 1], .comb = prefix2[prefix2.len - 1].combinator }
    else
        .{ .base = prefix2, .comb = .descendant };

    var leading_comb: ?Combinator = null;
    var adj_c1 = p1.comb;
    var adj_c2 = p2.comb;
    var adj_b1 = p1.base;
    var adj_b2 = p2.base;

    const setLeading = struct {
        fn call(leading: *?Combinator, candidate: Combinator) bool {
            if (leading.*) |existing| {
                return existing == candidate;
            }
            leading.* = candidate;
            return true;
        }
    }.call;

    if (adj_b1.len == 0 and adj_c1 != .descendant) {
        if (!setLeading(&leading_comb, adj_c1)) return results;
        adj_c1 = .descendant;
    } else if (adj_b1.len > 0 and adj_b1[0] == .combinator) {
        const lc = adj_b1[0].combinator;
        if (!setLeading(&leading_comb, lc)) return results;
        adj_b1 = adj_b1[1..];
    }

    if (adj_b2.len == 0 and adj_c2 != .descendant) {
        if (!setLeading(&leading_comb, adj_c2)) return results;
        adj_c2 = .descendant;
    } else if (adj_b2.len > 0 and adj_b2[0] == .combinator) {
        const lc = adj_b2[0].combinator;
        if (!setLeading(&leading_comb, lc)) return results;
        adj_b2 = adj_b2[1..];
    }

    if (adj_c1 == .descendant and adj_c2 == .descendant and
        prefixAllCombinatorsAre(adj_b1, .descendant) and
        prefixAllCombinatorsAre(adj_b2, .descendant))
    {
        const seq1 = try descendantPrefixCompounds(allocator, adj_b1);
        defer deinitCompoundSlice(allocator, seq1);
        const seq2 = try descendantPrefixCompounds(allocator, adj_b2);
        defer deinitCompoundSlice(allocator, seq2);
        var descendant_results = try unifyDescendantCompoundPrefixes(allocator, seq1, seq2);
        try prependLeadingCombinatorToResults(allocator, &descendant_results, leading_comb);
        return descendant_results;
    }

    if ((adj_c1 == .next_sibling and adj_c2 == .general_sibling) or
        (adj_c1 == .general_sibling and adj_c2 == .next_sibling))
    {
        const broader_base = if (adj_c1 == .general_sibling) adj_b1 else adj_b2;
        const adjacent_base = if (adj_c1 == .next_sibling) adj_b1 else adj_b2;
        var special_results = try unifyAdjacentGeneralPrefixes(allocator, adjacent_base, broader_base);
        if (special_results.items.len > 0) {
            try prependLeadingCombinatorToResults(allocator, &special_results, leading_comb);
            return special_results;
        }
        special_results.deinit(allocator);
    }

    if ((adj_c1 == .next_sibling or adj_c1 == .general_sibling) and adj_c2 == .descendant) {
        var special_results = try unifySiblingDescendantPrefixes(allocator, adj_b1, adj_c1, adj_b2);
        if (special_results.items.len > 0) {
            try prependLeadingCombinatorToResults(allocator, &special_results, leading_comb);
            return special_results;
        }
        special_results.deinit(allocator);
    }

    if ((adj_c2 == .next_sibling or adj_c2 == .general_sibling) and adj_c1 == .descendant) {
        var special_results = try unifySiblingDescendantPrefixes(allocator, adj_b2, adj_c2, adj_b1);
        if (special_results.items.len > 0) {
            try prependLeadingCombinatorToResults(allocator, &special_results, leading_comb);
            return special_results;
        }
        special_results.deinit(allocator);
    }

    var woven = try extend_unification_mod.weavePaths(allocator, adj_b1, adj_c1, adj_b2, adj_c2);
    defer {
        for (woven.items) |*w| w.deinit();
        woven.deinit(allocator);
    }

    try results.ensureUnusedCapacity(allocator, woven.items.len);
    for (woven.items) |*w| {
        var prefix = ComplexSelector.init(allocator);
        errdefer prefix.deinit();
        const lead_extra: usize = if (leading_comb != null) 1 else 0;
        try prefix.components.ensureTotalCapacity(allocator, w.components.items.len + lead_extra);
        if (leading_comb) |lc| {
            prefix.components.appendAssumeCapacity(.{ .combinator = lc });
        }
        for (w.components.items) |comp| {
            switch (comp) {
                .compound => |c| prefix.components.appendAssumeCapacity(.{ .compound = try c.clone(allocator) }),
                .combinator => |cb| prefix.components.appendAssumeCapacity(.{ .combinator = cb }),
            }
        }
        results.appendAssumeCapacity(prefix);
    }

    return results;
}

fn compoundIsSuperSelectorWrapped(
    a: *const CompoundSelector,
    b: *const CompoundSelector,
) bool {
    var super_list = SelectorList.init(std.heap.page_allocator);
    defer super_list.deinit();
    var sub_list = SelectorList.init(std.heap.page_allocator);
    defer sub_list.deinit();

    var super_complex = ComplexSelector.init(std.heap.page_allocator);
    defer super_complex.deinit();
    var sub_complex = ComplexSelector.init(std.heap.page_allocator);
    defer sub_complex.deinit();

    super_complex.components.append(std.heap.page_allocator, .{ .compound = a.clone(std.heap.page_allocator) catch return false }) catch return false;
    sub_complex.components.append(std.heap.page_allocator, .{ .compound = b.clone(std.heap.page_allocator) catch return false }) catch return false;

    super_list.selectors.append(std.heap.page_allocator, super_complex.clone(std.heap.page_allocator) catch return false) catch return false;
    sub_list.selectors.append(std.heap.page_allocator, sub_complex.clone(std.heap.page_allocator) catch return false) catch return false;
    return selector_mod.isSuperSelector(&super_list, &sub_list);
}

fn complexSupportsUnify(complex: *const ComplexSelector) bool {
    var seen_compound = false;
    var leading_combinators: usize = 0;
    var consecutive_combinators: usize = 0;
    var prev_was_combinator = false;

    for (complex.components.items) |comp| {
        switch (comp) {
            .compound => {
                seen_compound = true;
                prev_was_combinator = false;
                consecutive_combinators = 0;
            },
            .combinator => {
                if (!seen_compound) {
                    leading_combinators += 1;
                }
                if (prev_was_combinator) {
                    consecutive_combinators += 1;
                }
                prev_was_combinator = true;
            },
        }
    }

    if (leading_combinators > 1) return false;
    if (consecutive_combinators > 0) return false;
    return true;
}

fn complexLeadingCombinatorCount(complex: *const ComplexSelector) usize {
    var n: usize = 0;
    for (complex.components.items) |comp| {
        switch (comp) {
            .combinator => n += 1,
            .compound => break,
        }
    }
    return n;
}

fn selectorListHasLeadingCombinator(list: *const SelectorList) bool {
    for (list.selectors.items) |c| {
        if (c.components.items.len > 0 and c.components.items[0] == .combinator) return true;
    }
    return false;
}

fn selectorExtendSuppressedForBogusCombinators(
    sel: *const SelectorList,
    extender: *const SelectorList,
) bool {
    const ext_lead = selectorListHasLeadingCombinator(extender);
    for (sel.selectors.items) |c| {
        const lead = complexLeadingCombinatorCount(&c);
        if (lead > 1) return true;
        if (lead >= 1 and ext_lead) return true;
    }
    return false;
}

fn prefixHasUnsupportedRuns(prefix: []const ComplexSelectorComponent) bool {
    var prev_was_combinator = false;
    for (prefix) |comp| {
        switch (comp) {
            .compound => prev_was_combinator = false,
            .combinator => {
                if (prev_was_combinator) return true;
                prev_was_combinator = true;
            },
        }
    }
    return false;
}

fn selectorAppendSuffixSimpleEq(a: SimpleSelector, b: SimpleSelector) bool {
    return simpleSelectorEql(a, b);
}

const legacy_pseudo_elements = std.StaticStringMap(void).initComptime(.{
    .{ "before", {} },
    .{ "after", {} },
    .{ "first-line", {} },
    .{ "first-letter", {} },
});

fn isLegacyPseudoElement(name: []const u8) bool {
    return legacy_pseudo_elements.has(name);
}

const NsInfo = struct {
    kind: enum { default, empty, explicit, any },
    ns: []const u8,
    name: []const u8,
};

fn parseNs(full: []const u8) NsInfo {
    if (std.mem.find(u8, full, "|")) |pipe| {
        const ns_part = full[0..pipe];
        const name_part = full[pipe + 1 ..];
        if (std.mem.eql(u8, ns_part, "*")) {
            return .{ .kind = .any, .ns = "*", .name = name_part };
        } else if (ns_part.len == 0) {
            return .{ .kind = .empty, .ns = "", .name = name_part };
        } else {
            return .{ .kind = .explicit, .ns = ns_part, .name = name_part };
        }
    }
    return .{ .kind = .default, .ns = "", .name = full };
}

fn unifyNsSelectors(allocator: std.mem.Allocator, a_full: []const u8, a_is_universal: bool, b_full: []const u8, b_is_universal: bool) !?[]const u8 {
    const a = parseNs(a_full);
    const b = parseNs(b_full);

    const a_is_star = std.mem.eql(u8, a.name, "*");
    const b_is_star = std.mem.eql(u8, b.name, "*");
    if (!a_is_star and !b_is_star and !a_is_universal and !b_is_universal) {
        if (!std.mem.eql(u8, a.name, b.name)) return null;
    }

    const eff_name = if (a_is_star or a_is_universal) b.name else a.name;

    const EffNs = struct {
        kind: @TypeOf(a.kind),
        ns: []const u8,
    };
    const eff_ns: EffNs = switch (a.kind) {
        .any => .{ .kind = b.kind, .ns = b.ns },
        .default => switch (b.kind) {
            .any, .default => .{ .kind = .default, .ns = "" },
            .explicit, .empty => return null,
        },
        .empty => switch (b.kind) {
            .any, .empty => .{ .kind = .empty, .ns = "" },
            .default, .explicit => return null,
        },
        .explicit => switch (b.kind) {
            .any => .{ .kind = .explicit, .ns = a.ns },
            .explicit => if (std.mem.eql(u8, a.ns, b.ns))
                .{ .kind = .explicit, .ns = a.ns }
            else
                return null,
            .default, .empty => return null,
        },
    };

    return switch (eff_ns.kind) {
        .default => try allocator.dupe(u8, eff_name),
        .any => try std.mem.concat(allocator, u8, &.{ "*|", eff_name }),
        .empty => try std.mem.concat(allocator, u8, &.{ "|", eff_name }),
        .explicit => try std.mem.concat(allocator, u8, &.{ eff_ns.ns, "|", eff_name }),
    };
}

fn sortCompoundSelectors(compound: *CompoundSelector) void {
    const items = compound.simple_selectors.items;
    if (items.len <= 1) return;

    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const key = items[i];
        const key_pri = selectorSortPriority(key);
        var j: usize = i;
        while (j > 0 and selectorSortPriority(items[j - 1]) > key_pri) : (j -= 1) {
            items[j] = items[j - 1];
        }
        items[j] = key;
    }
}

fn selectorSortPriority(ss: SimpleSelector) u8 {
    return switch (ss) {
        .type_selector => 0,
        .universal => 0,
        .id => 1,
        .class => 2,
        .attribute => 3,
        .placeholder => 4,
        .pseudo_class => |pc| if (isLegacyPseudoElement(pc.name)) 6 else 5,
        .pseudo_element => 6,
        .parent => 0,
    };
}

const CompoundPseudoPlacement = struct {
    pseudo_index: ?usize = null,
    invalid: bool = false,
};

fn compoundPseudoPlacement(compound: CompoundSelector) CompoundPseudoPlacement {
    var placement = CompoundPseudoPlacement{};

    for (compound.simple_selectors.items, 0..) |ss, idx| {
        const is_pseudo_element = switch (ss) {
            .pseudo_element => true,
            .pseudo_class => |pc| isLegacyPseudoElement(pc.name),
            else => false,
        };
        if (!is_pseudo_element) continue;

        if (placement.pseudo_index != null) {
            placement.invalid = true;
            return placement;
        }
        placement.pseudo_index = idx;
    }

    if (placement.pseudo_index) |pseudo_idx| {
        for (compound.simple_selectors.items[pseudo_idx + 1 ..]) |ss| {
            if (ss != .pseudo_class) {
                placement.invalid = true;
                return placement;
            }
        }
    }

    return placement;
}

fn pseudoElementsCompatible(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn pseudoElementName(ss: SimpleSelector) ?[]const u8 {
    return switch (ss) {
        .pseudo_element => |pe| pe.name,
        .pseudo_class => |pc| if (isLegacyPseudoElement(pc.name)) pc.name else null,
        else => null,
    };
}

fn pseudoElementSelector(ss: SimpleSelector) ?PseudoSelector {
    return switch (ss) {
        .pseudo_element => |pe| pe,
        .pseudo_class => |pc| if (isLegacyPseudoElement(pc.name)) pc else null,
        else => null,
    };
}

fn pseudoElementsCompatibleForUnify(a: SimpleSelector, b: SimpleSelector) bool {
    const a_pseudo = pseudoElementSelector(a) orelse return false;
    const b_pseudo = pseudoElementSelector(b) orelse return false;
    if (!std.mem.eql(u8, a_pseudo.name, b_pseudo.name)) return false;
    if (a_pseudo.argument != null and b_pseudo.argument != null) {
        if (!std.mem.eql(u8, a_pseudo.argument.?, b_pseudo.argument.?)) return false;
    } else if (a_pseudo.argument != null or b_pseudo.argument != null) {
        return false;
    }
    return selectorListsEqualForUnify(a_pseudo.selector, b_pseudo.selector);
}

const rootish_pseudos = std.StaticStringMap(void).initComptime(.{
    .{ "root", {} },
    .{ "scope", {} },
    .{ "host", {} },
    .{ "host-context", {} },
    .{ "slotted", {} },
});

fn isRootishPseudo(name: []const u8) bool {
    return rootish_pseudos.has(name);
}

/// Selector-accepting pseudo-classes that, combined with `:host` / `:host-context`,
/// allow unification (`:is(...)` / `:where(...)` / `:not(...)` / `:has(...)` /
/// `:matches(...)`). Used by `canUnifyWithHost` to keep the host compound flexible.
const host_compatible_fn_pseudos = std.StaticStringMap(void).initComptime(.{
    .{ "is", {} },
    .{ "where", {} },
    .{ "not", {} },
    .{ "has", {} },
    .{ "matches", {} },
});

fn compoundHasRootishConstraint(compound: CompoundSelector) bool {
    for (compound.simple_selectors.items) |ss| {
        switch (ss) {
            .pseudo_class => |pc| if (isRootishPseudo(pc.name)) return true,
            .pseudo_element => {},
            else => {},
        }
    }
    return false;
}

fn compoundsRequireSameElement(a: CompoundSelector, b: CompoundSelector) bool {
    if (compoundHasRootishConstraint(a) and compoundHasRootishConstraint(b)) return true;

    for (a.simple_selectors.items) |sa| {
        switch (sa) {
            .id => |id_name| {
                for (b.simple_selectors.items) |sb| {
                    if (sb == .id and std.mem.eql(u8, id_name, sb.id)) return true;
                }
            },
            .pseudo_class, .pseudo_element => {
                const a_pseudo_name = pseudoElementName(sa) orelse {
                    if (sa == .pseudo_class and isRootishPseudo(sa.pseudo_class.name)) {
                        for (b.simple_selectors.items) |sb| {
                            if (sb == .pseudo_class and std.mem.eql(u8, sa.pseudo_class.name, sb.pseudo_class.name)) {
                                return true;
                            }
                        }
                    }
                    continue;
                };

                for (b.simple_selectors.items) |sb| {
                    const b_pseudo_name = pseudoElementName(sb) orelse continue;
                    if (pseudoElementsCompatible(a_pseudo_name, b_pseudo_name)) return true;
                }
            },
            else => {},
        }
    }

    return false;
}

fn compoundsRequireReverseForcedMerge(a: CompoundSelector, b: CompoundSelector) bool {
    for (a.simple_selectors.items) |sa| {
        switch (sa) {
            .id => |id_name| {
                for (b.simple_selectors.items) |sb| {
                    if (sb == .id and std.mem.eql(u8, id_name, sb.id)) return true;
                }
            },
            .pseudo_class, .pseudo_element => {
                const a_pseudo_name = pseudoElementName(sa) orelse continue;
                for (b.simple_selectors.items) |sb| {
                    const b_pseudo_name = pseudoElementName(sb) orelse continue;
                    if (pseudoElementsCompatible(a_pseudo_name, b_pseudo_name)) return true;
                }
            },
            else => {},
        }
    }
    return false;
}

fn hasHostSelector(compound: CompoundSelector) bool {
    for (compound.simple_selectors.items) |ss| {
        switch (ss) {
            .pseudo_class => |pc| {
                if (std.mem.eql(u8, pc.name, "host") or std.mem.eql(u8, pc.name, "host-context")) return true;
            },
            else => {},
        }
    }
    return false;
}

fn canUnifyWithHost(compound: CompoundSelector) bool {
    for (compound.simple_selectors.items) |ss| {
        switch (ss) {
            .pseudo_class => |pc| {
                if (std.mem.eql(u8, pc.name, "host") or std.mem.eql(u8, pc.name, "host-context")) continue;
                if ((pc.selector != null or pc.argument != null) and
                    host_compatible_fn_pseudos.has(pc.name))
                {
                    continue;
                }
                return false;
            },
            .class, .id, .type_selector, .universal, .attribute => return false,
            else => {},
        }
    }
    return true;
}

fn firstSelectorPseudoIndex(compound: CompoundSelector, start: usize, end: usize) ?usize {
    for (compound.simple_selectors.items[start..end], start..) |ss, idx| {
        switch (ss) {
            .pseudo_class => |pc| {
                if (pc.selector != null and
                    !std.mem.eql(u8, pc.name, "host") and
                    !std.mem.eql(u8, pc.name, "host-context"))
                    return idx;
            },
            else => {},
        }
    }
    return null;
}

fn selectorListsEqualForUnify(a: ?*SelectorList, b: ?*SelectorList) bool {
    if (a == null or b == null) return a == null and b == null;

    const a_css = selector_mod.toCss(std.heap.page_allocator, a.?) catch return false;
    defer std.heap.page_allocator.free(a_css);
    const b_css = selector_mod.toCss(std.heap.page_allocator, b.?) catch return false;
    defer std.heap.page_allocator.free(b_css);
    return std.mem.eql(u8, a_css, b_css);
}

fn appendUniqueSimpleSelector(
    allocator: std.mem.Allocator,
    dest: *CompoundSelector,
    ss: SimpleSelector,
    existing_pseudo_name: ?[]const u8,
) !void {
    switch (ss) {
        .type_selector, .universal => return,
        .pseudo_class => |pc| {
            if (isLegacyPseudoElement(pc.name) and existing_pseudo_name != null and pseudoElementsCompatible(pc.name, existing_pseudo_name.?)) {
                return;
            }
        },
        .pseudo_element => |pe| {
            if (existing_pseudo_name != null and pseudoElementsCompatible(pe.name, existing_pseudo_name.?)) {
                return;
            }
        },
        else => {},
    }

    for (dest.simple_selectors.items) |existing| {
        if (simpleSelectorEql(ss, existing)) return;
    }
    try dest.simple_selectors.append(allocator, try selector_mod.cloneSimpleSelector(ss, allocator));
}

fn appendCompoundSegment(
    allocator: std.mem.Allocator,
    dest: *CompoundSelector,
    compound: CompoundSelector,
    start: usize,
    end: usize,
    existing_pseudo_name: ?[]const u8,
) !void {
    for (compound.simple_selectors.items[start..end]) |ss| {
        try appendUniqueSimpleSelector(allocator, dest, ss, existing_pseudo_name);
    }
}

fn sortSimpleSelectorSlice(items: []SimpleSelector) void {
    if (items.len <= 1) return;

    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const key = items[i];
        const key_priority = selectorSortPriority(key);
        var j = i;
        while (j > 0 and selectorSortPriority(items[j - 1]) > key_priority) : (j -= 1) {
            items[j] = items[j - 1];
        }
        items[j] = key;
    }
}

fn simpleSelectorInCompound(ss: SimpleSelector, compound: CompoundSelector) bool {
    for (compound.simple_selectors.items) |candidate| {
        if (selectorAppendSuffixSimpleEq(ss, candidate)) return true;
    }
    return false;
}

fn compoundContainsUnifyTarget(compound: CompoundSelector, target: CompoundSelector) bool {
    for (target.simple_selectors.items) |target_ss| {
        if (!simpleSelectorInCompound(target_ss, compound)) return false;
    }
    return true;
}

fn hasParentSuffix(text: []const u8) bool {
    for (text, 0..) |c, i| {
        if (c == '&' and i + 1 < text.len) {
            const next = text[i + 1];
            if (std.ascii.isAlphanumeric(next) or next == '-' or next == '_') {
                return true;
            }
        }
    }
    return false;
}

fn expectUnifiedSelectorSet(
    allocator: std.mem.Allocator,
    lhs_src: []const u8,
    rhs_src: []const u8,
    expected: []const []const u8,
) !void {
    var lhs = try selector_mod.parse(allocator, lhs_src);
    defer lhs.deinit();
    var rhs = try selector_mod.parse(allocator, rhs_src);
    defer rhs.deinit();

    const unified = try unifyComplexSelectors(allocator, &lhs.selectors.items[0], &rhs.selectors.items[0]);
    defer {
        for (unified) |*item| item.deinit();
        allocator.free(unified);
    }

    try std.testing.expectEqual(expected.len, unified.len);

    var actual_css: std.ArrayList([]const u8) = .empty;
    defer {
        for (actual_css.items) |item| allocator.free(item);
        actual_css.deinit(allocator);
    }
    try actual_css.ensureTotalCapacity(allocator, unified.len);

    for (unified) |*item| {
        const css = try selectorToCssSingle(allocator, item);
        actual_css.appendAssumeCapacity(css);
    }

    for (expected) |exp| {
        var found = false;
        for (actual_css.items) |actual| {
            if (std.mem.eql(u8, exp, actual)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }

    for (actual_css.items) |actual| {
        var found = false;
        for (expected) |exp| {
            if (std.mem.eql(u8, exp, actual)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "selector unify compounds: universal + class collapses to class" {
    const allocator = std.testing.allocator;

    var lhs = try selector_mod.parse(allocator, "*.a");
    defer lhs.deinit();
    var rhs = try selector_mod.parse(allocator, ".a");
    defer rhs.deinit();

    const l_comp = lhs.selectors.items[0].components.items[0].compound;
    const r_comp = rhs.selectors.items[0].components.items[0].compound;
    const merged = try unifyCompounds(allocator, l_comp, r_comp);
    try std.testing.expect(merged != null);

    var merged_comp = merged.?;
    defer merged_comp.deinit();
    const css = try selector_mod.compoundSelectorToCss(allocator, &merged_comp);
    defer allocator.free(css);
    try std.testing.expectEqualStrings(".a", css);
}

test "selector unify complex: child and descendant weaving keeps child context" {
    const allocator = std.testing.allocator;

    var lhs = try selector_mod.parse(allocator, ".c > .d");
    defer lhs.deinit();
    var rhs = try selector_mod.parse(allocator, ".e .f");
    defer rhs.deinit();

    const unified = try unifyComplexSelectors(allocator, &lhs.selectors.items[0], &rhs.selectors.items[0]);
    defer {
        for (unified) |*item| item.deinit();
        allocator.free(unified);
    }

    try std.testing.expectEqual(@as(usize, 1), unified.len);
    const css = try selectorToCssSingle(allocator, &unified[0]);
    defer allocator.free(css);
    try std.testing.expectEqualStrings(".e .c > .d.f", css);
}

test "selector unify complex: sibling and next-sibling returns both legacy branches" {
    const allocator = std.testing.allocator;

    var lhs = try selector_mod.parse(allocator, ".c ~ .d");
    defer lhs.deinit();
    var rhs = try selector_mod.parse(allocator, ".e + .f");
    defer rhs.deinit();

    const unified = try unifyComplexSelectors(allocator, &lhs.selectors.items[0], &rhs.selectors.items[0]);
    defer {
        for (unified) |*item| item.deinit();
        allocator.free(unified);
    }

    try std.testing.expectEqual(@as(usize, 2), unified.len);
    const css0 = try selectorToCssSingle(allocator, &unified[0]);
    defer allocator.free(css0);
    const css1 = try selectorToCssSingle(allocator, &unified[1]);
    defer allocator.free(css1);

    const branch1 = std.mem.eql(u8, css0, ".c ~ .e + .d.f") and std.mem.eql(u8, css1, ".c.e + .d.f");
    const branch2 = std.mem.eql(u8, css1, ".c ~ .e + .d.f") and std.mem.eql(u8, css0, ".c.e + .d.f");
    try std.testing.expect(branch1 or branch2);
}

test "selector unify complex: leading combinator stays on result" {
    const allocator = std.testing.allocator;

    var lhs = try selector_mod.parse(allocator, "+ .c");
    defer lhs.deinit();
    var rhs = try selector_mod.parse(allocator, "+ .d");
    defer rhs.deinit();

    const unified = try unifyComplexSelectors(allocator, &lhs.selectors.items[0], &rhs.selectors.items[0]);
    defer {
        for (unified) |*item| item.deinit();
        allocator.free(unified);
    }

    try std.testing.expectEqual(@as(usize, 1), unified.len);
    const css = try selectorToCssSingle(allocator, &unified[0]);
    defer allocator.free(css);
    try std.testing.expectEqualStrings("+ .c.d", css);
}

test "selector unify complex edge: multiple isolated keeps child context" {
    const allocator = std.testing.allocator;
    const expected = [_][]const u8{
        ".f .c > .g ~ .d + .e.h",
        ".f .c > .g.d + .e.h",
    };
    try expectUnifiedSelectorSet(allocator, ".c > .d + .e", ".f .g ~ .h", &expected);
}

test "selector unify complex edge: overlap id forced unification" {
    const allocator = std.testing.allocator;
    const expected = [_][]const u8{
        "#c.s2-1.s1-1 .s1-2.s2-2",
    };
    try expectUnifiedSelectorSet(allocator, "#c.s1-1 .s1-2", "#c.s2-1 .s2-2", &expected);
}

test "selector unify complex edge: overlap pseudo-element forced unification" {
    const allocator = std.testing.allocator;
    const expected = [_][]const u8{
        ".s2-1.s1-1::c .s1-2.s2-2",
    };
    try expectUnifiedSelectorSet(allocator, ".s1-1::c .s1-2", ".s2-1::c .s2-2", &expected);
}

test "selector unify complex edge: rootish mixed merges root and scope" {
    const allocator = std.testing.allocator;
    const expected = [_][]const u8{
        ":root:scope .c .e .d.f",
        ":root:scope .e .c .d.f",
    };
    try expectUnifiedSelectorSet(allocator, ":root .c .d", ":scope .e .f", &expected);
}

test "selector unify complex edge: root in one selector1 three layer" {
    const allocator = std.testing.allocator;
    const expected = [_][]const u8{
        ":root .c .e .d.f",
        ":root .e .c .d.f",
    };
    try expectUnifiedSelectorSet(allocator, ":root .c .d", ".e .f", &expected);
}

test "selector unify complex edge: root in one selector2 three layer" {
    const allocator = std.testing.allocator;
    const expected = [_][]const u8{
        ":root .c .e .d.f",
        ":root .e .c .d.f",
    };
    try expectUnifiedSelectorSet(allocator, ".c .d", ":root .e .f", &expected);
}

test "selector unify complex edge: scope stays first" {
    const allocator = std.testing.allocator;
    const expected = [_][]const u8{
        ":scope .d .c.e",
    };
    try expectUnifiedSelectorSet(allocator, ":scope .c", ".d .e", &expected);
}

const InternPool = intern_pool_mod.InternPool;

const SelectorBuiltinTestHarness = struct {
    allocator: std.mem.Allocator,
    intern_pool: InternPool,
    list_pool: std.ArrayListUnmanaged([]Value),
    color_pool: shared.ColorPool,
    number_pool: shared.NumberPool,
    callable_payload_pool: shared.CallablePayloadPool,
    list_meta_pool: shared.ListMetaPool,
    string_flags_pool: shared.StringFlagsPool,
    random_state: u64,

    fn init(allocator: std.mem.Allocator) !SelectorBuiltinTestHarness {
        return .{
            .allocator = allocator,
            .intern_pool = try InternPool.init(allocator),
            .list_pool = .empty,
            .color_pool = .empty,
            .number_pool = .empty,
            .callable_payload_pool = .empty,
            .list_meta_pool = .empty,
            .string_flags_pool = .empty,
            .random_state = 0xC0DEC0DE,
        };
    }

    fn deinit(self: *SelectorBuiltinTestHarness) void {
        for (self.list_pool.items) |items| self.allocator.free(items);
        self.list_pool.deinit(self.allocator);
        self.color_pool.deinit(self.allocator);
        self.number_pool.deinit(self.allocator);
        self.callable_payload_pool.deinit(self.allocator);
        self.list_meta_pool.deinit(self.allocator);
        self.string_flags_pool.deinit(self.allocator);
        self.intern_pool.deinit(self.allocator);
    }

    fn context(self: *SelectorBuiltinTestHarness) BuiltinContext {
        return .{
            .allocator = self.allocator,
            .intern_pool = &self.intern_pool,
            .list_pool = &self.list_pool,
            .color_pool = &self.color_pool,
            .number_pool = &self.number_pool,
            .callable_payload_pool = &self.callable_payload_pool,
            .list_meta_pool = &self.list_meta_pool,
            .string_flags_pool = &self.string_flags_pool,
            .random_state = &self.random_state,
            .vm = @ptrFromInt(1),
        };
    }
};

fn testStringValue(ctx: *BuiltinContext, text: []const u8) !Value {
    const id = try ctx.intern_pool.intern(text);
    return Value.string(id, false);
}

test "selector.parse classifies parent selector as BuiltinType" {
    var harness = try SelectorBuiltinTestHarness.init(std.testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const args = [_]Value{try testStringValue(&ctx, "&")};
    const names = [_]InternId{};
    try std.testing.expectError(error.BuiltinType, selector_parse(&ctx, &args, &names));
}

test "selector.parse keeps invalid syntax as SassError" {
    var harness = try SelectorBuiltinTestHarness.init(std.testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const args = [_]Value{try testStringValue(&ctx, "a[")};
    const names = [_]InternId{};
    try std.testing.expectError(error.SassError, selector_parse(&ctx, &args, &names));
}

test "selector.parse classifies slash list argument as BuiltinType" {
    var harness = try SelectorBuiltinTestHarness.init(std.testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const left = try testStringValue(&ctx, ".a");
    const right = try testStringValue(&ctx, ".b");
    const slash_list = try pushListWithSeparator(&ctx, &.{ left, right }, .slash, false);

    const args = [_]Value{slash_list};
    const names = [_]InternId{};
    try std.testing.expectError(error.BuiltinType, selector_parse(&ctx, &args, &names));
}

test "selector.unify classifies parent selector as BuiltinType" {
    var harness = try SelectorBuiltinTestHarness.init(std.testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const args = [_]Value{
        try testStringValue(&ctx, ".a"),
        try testStringValue(&ctx, "&"),
    };
    const names = [_]InternId{};
    try std.testing.expectError(error.BuiltinType, selector_unify(&ctx, &args, &names));
}

test "selector.extend classifies complex extendee as BuiltinType" {
    var harness = try SelectorBuiltinTestHarness.init(std.testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const args = [_]Value{
        try testStringValue(&ctx, ".a"),
        try testStringValue(&ctx, ".b .c"),
        try testStringValue(&ctx, ".d"),
    };
    const names = [_]InternId{};
    try std.testing.expectError(error.BuiltinType, selector_extend(&ctx, &args, &names));
}

test "selector.nest bare parent stays unresolved ampersand" {
    var harness = try SelectorBuiltinTestHarness.init(std.testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const args = [_]Value{try testStringValue(&ctx, "&")};
    const out = try selector_nest(&ctx, &args);
    try std.testing.expect(out.kind() == .list);

    const out_text = try selectorArgString(&ctx, out);
    defer ctx.allocator.free(out_text);
    try std.testing.expectEqualStrings("&", out_text);

    const outer_items = ctx.list_pool.items[out.listHandle()];
    try std.testing.expectEqual(@as(usize, 1), outer_items.len);
    try std.testing.expect(outer_items[0].kind() == .list);
    const inner_items = ctx.list_pool.items[outer_items[0].listHandle()];
    try std.testing.expectEqual(@as(usize, 1), inner_items.len);
    try std.testing.expect(inner_items[0].kind() == .string);
    try std.testing.expect(inner_items[0].stringPreservesAmpersand(ctx.string_flags_pool.items));
}

test "selector.nest resolves parent when second argument exists" {
    var harness = try SelectorBuiltinTestHarness.init(std.testing.allocator);
    defer harness.deinit();

    var ctx = harness.context();
    const args = [_]Value{
        try testStringValue(&ctx, "c"),
        try testStringValue(&ctx, "&"),
    };
    const out = try selector_nest(&ctx, &args);
    try std.testing.expect(out.kind() == .string);
    const out_text = ctx.intern_pool.get(out.stringIntern());
    try std.testing.expectEqualStrings("c", out_text);
}
