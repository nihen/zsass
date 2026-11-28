//! sass:selector builtins.
const std = @import("std");
const resource_budget = @import("../runtime/resource_budget.zig");
const stack_guard = @import("../runtime/stack_guard.zig");
const selector_mod = @import("../selector/selector.zig");
const extend_mod = @import("../selector/extend.zig");
const extend_engine_mod = @import("../selector/extend_engine.zig");
const extend_specificity = @import("../selector/extend_specificity.zig");
const shared = @import("shared.zig");
const error_format = @import("../runtime/error_format.zig");
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

const simpleSelectorEql = extend_specificity.simpleSelectorEql;

const SelectorList = selector_mod.SelectorList;
const ComplexSelector = selector_mod.ComplexSelector;
const CompoundSelector = selector_mod.CompoundSelector;
const SimpleSelector = selector_mod.SimpleSelector;
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
    try stack_guard.check();
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

/// A selector argument's text, or the official CLI's error naming the
/// parameter (none for selector.append() and selector.nest()).
fn selectorArgStringNamed(ctx: *BuiltinContext, value: Value, comptime param: []const u8) BuiltinError![]u8 {
    return selectorArgString(ctx, value) catch |err| {
        if (err != error.BuiltinType or error_format.currentContextMessage() != null) return err;
        const text = shared.valueToInspectionString(ctx, value) catch return err;
        defer ctx.allocator.free(text);
        // A list is shown in parentheses.
        const is_list = value.kind() == .list and !value.listBracketed(ctx.list_meta_pool.items) and
            !(text.len > 0 and text[0] == '(');
        const prefix = if (param.len == 0) "" else "$" ++ param ++ ": ";
        var buf: [512]u8 = undefined;
        const msg = (if (is_list)
            std.fmt.bufPrint(&buf, "{s}({s}) is not a valid selector: it must be a string,\na list of strings, or a list of lists of strings.", .{ prefix, text })
        else
            std.fmt.bufPrint(&buf, "{s}{s} is not a valid selector: it must be a string,\na list of strings, or a list of lists of strings.", .{ prefix, text })) catch return err;
        error_format.setContextMessage(msg);
        return err;
    };
}

/// A selector parsed from an argument's text; text that ends too soon is
/// reported as the official CLI does.
fn parseSelectorArg(ctx: *BuiltinContext, text: []const u8, comptime param: []const u8) BuiltinError!SelectorList {
    return selector_mod.parse(ctx.allocator, text) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.UnexpectedEnd) {
            error_format.setContextMessage(if (param.len == 0) "expected more input." else "$" ++ param ++ ": expected more input.");
        }
        return error.SassError;
    };
}

/// "$extendee: Parent selectors aren't allowed here.", the parameter named
/// unless it is selector.append()'s.
fn parentNotAllowed(comptime param: []const u8) BuiltinError {
    error_format.setContextMessage((if (param.len == 0) "" else "$" ++ param ++ ": ") ++ "Parent selectors aren't allowed here.");
    return error.BuiltinType;
}

fn selectorArgString(ctx: *BuiltinContext, value: Value) BuiltinError![]u8 {
    const text = try selectorValueToString(ctx, value, 0);
    if (std.mem.indexOf(u8, text, "/*") == null and std.mem.indexOf(u8, text, "//") == null) return text;
    defer ctx.allocator.free(text);
    return stripSelectorComments(ctx.allocator, text);
}

/// A selector argument may hold comments, as a stylesheet's selectors do:
/// `/* ... */` reads as a space and `//` runs to the end of the line.
/// Quoted strings and escapes are kept as they are; an unterminated
/// `/*` is an error.
fn stripSelectorComments(allocator: std.mem.Allocator, text: []const u8) BuiltinError![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, text.len);
    var i: usize = 0;
    var quote: u8 = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '\\' and i + 1 < text.len) {
            out.appendSliceAssumeCapacity(text[i .. i + 2]);
            i += 2;
            continue;
        }
        if (quote != 0) {
            if (c == quote) quote = 0;
            out.appendAssumeCapacity(c);
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
            out.appendAssumeCapacity(c);
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < text.len and text[i + 1] == '*') {
            // An unterminated comment is a syntax error, as in a stylesheet.
            const end = std.mem.indexOfPos(u8, text, i + 2, "*/") orelse return error.SassError;
            out.appendAssumeCapacity(' ');
            i = end + 2;
            continue;
        }
        if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
            i = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
            continue;
        }
        out.appendAssumeCapacity(c);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn selectorArgCssString(ctx: *BuiltinContext, value: Value) BuiltinError![]u8 {
    const css = try valueToCssString(ctx, value);
    return @constCast(css);
}

/// "Can't extend complex selector d e.": only a compound selector may be
/// extended.
fn cantExtendComplex(ctx: *BuiltinContext, complex: *const ComplexSelector, err: BuiltinError) BuiltinError {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(ctx.allocator);
    for (complex.components.items) |comp| {
        const part = switch (comp) {
            .compound => |compound| try selector_mod.compoundSelectorToCss(ctx.allocator, &compound),
            .combinator => |comb| try ctx.allocator.dupe(u8, std.mem.trim(u8, comb.toCss(), " ")),
        };
        defer ctx.allocator.free(part);
        if (part.len == 0) continue;
        if (text.items.len > 0) try text.append(ctx.allocator, ' ');
        try text.appendSlice(ctx.allocator, part);
    }
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Can't extend complex selector {s}.", .{text.items}) catch return err;
    error_format.setContextMessage(msg);
    return err;
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
    const selector_str = try selectorArgStringNamed(ctx, selector_val, "selector");
    defer ctx.allocator.free(selector_str);

    var parsed = try parseSelectorArg(ctx, selector_str, "selector");
    defer parsed.deinit();
    if (selector_mod.hasParentReference(&parsed)) return parentNotAllowed("selector");
    return selectorListToValue(ctx, &parsed);
}

pub fn selector_nest(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    if (args.len == 0) {
        error_format.setContextMessage("$selectors: At least one selector must be passed.");
        return error.BuiltinArity;
    }

    const first_str = try selectorArgStringNamed(ctx, args[0], "");
    defer ctx.allocator.free(first_str);
    var current = try parseSelectorArg(ctx, first_str, "");
    if (selector_mod.hasParentReference(&current)) {
        if (hasParentSuffix(first_str)) {
            current.deinit();
            error_format.setContextMessage("A top-level selector may not contain a parent selector with a suffix.");
            return error.SassError;
        }
    }

    for (args[1..]) |arg_val| {
        const child_str = try selectorArgStringNamed(ctx, arg_val, "");
        defer ctx.allocator.free(child_str);
        var child = parseSelectorArg(ctx, child_str, "") catch |err| {
            current.deinit();
            return err;
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

    return selectorListToValue(ctx, &current);
}

pub fn selector_append(ctx: *BuiltinContext, args: []const Value) BuiltinError!Value {
    if (args.len == 0) {
        error_format.setContextMessage("$selectors: At least one selector must be passed.");
        return error.BuiltinArity;
    }

    const first_str = try selectorArgStringNamed(ctx, args[0], "");
    defer ctx.allocator.free(first_str);
    var current = try parseSelectorArg(ctx, first_str, "");
    if (selector_mod.hasParentReference(&current)) {
        current.deinit();
        return parentNotAllowed("");
    }
    if (!selectorAppendBaseIsValid(&current)) {
        current.deinit();
        return error.SassError;
    }
    defer current.deinit();

    for (args[1..]) |arg_val| {
        const suffix_str = try selectorArgStringNamed(ctx, arg_val, "");
        defer ctx.allocator.free(suffix_str);
        var suffix = try parseSelectorArg(ctx, suffix_str, "");
        defer suffix.deinit();
        if (selector_mod.hasParentReference(&suffix)) return parentNotAllowed("");
        if (!selectorAppendSuffixIsValid(&suffix)) return error.SassError;
        const appended = selector_mod.selectorAppend(ctx.allocator, &current, &suffix) catch return error.SassError;
        current.deinit();
        current = appended;
        if (current.selectors.items.len == 0) return error.SassError;
    }

    // A suffix joined to an escaped name makes one name, which has its own
    // canonical spelling (`\\2d ` and `a` are `-a`).
    const appended_css = try selector_mod.toCss(ctx.allocator, &current);
    defer ctx.allocator.free(appended_css);
    if (std.mem.indexOfScalar(u8, appended_css, '\\') != null) {
        // A name the parser does not read back, such as one that ends in
        // an escaped space, stays as it was joined.
        if (selector_mod.parse(ctx.allocator, appended_css)) |reparsed| {
            current.deinit();
            current = reparsed;
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        }
    }

    return selectorListToValue(ctx, &current);
}

pub fn selector_unify(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{ "selector1", "selector2" }, 2);
    const sel1_val = bound[0] orelse return reportMissingArgument("selector1");
    const sel2_val = bound[1] orelse return reportMissingArgument("selector2");

    const sel1_str = try selectorArgStringNamed(ctx, sel1_val, "selector1");
    defer ctx.allocator.free(sel1_str);
    const sel2_str = try selectorArgStringNamed(ctx, sel2_val, "selector2");
    defer ctx.allocator.free(sel2_str);

    var sel1 = try parseSelectorArg(ctx, sel1_str, "selector1");
    defer sel1.deinit();
    if (selector_mod.hasParentReference(&sel1)) return parentNotAllowed("selector1");

    var sel2 = try parseSelectorArg(ctx, sel2_str, "selector2");
    defer sel2.deinit();
    if (selector_mod.hasParentReference(&sel2)) return parentNotAllowed("selector2");

    var result = SelectorList.init(ctx.allocator);
    errdefer result.deinit();

    for (sel1.selectors.items) |complex1| {
        for (sel2.selectors.items) |complex2| {
            const unified_list = try unifyComplexSelectors(ctx.allocator, ctx.budget, &complex1, &complex2);
            defer {
                for (unified_list) |*item| item.deinit();
                ctx.allocator.free(unified_list);
            }

            // Every result stays, a repeat included.
            for (unified_list) |item| {
                var cloned = try item.clone(ctx.allocator);
                errdefer cloned.deinit();
                try result.selectors.append(ctx.allocator, cloned);
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

    const super_str = try selectorArgStringNamed(ctx, super_val, "super");
    defer ctx.allocator.free(super_str);
    const sub_str = try selectorArgStringNamed(ctx, sub_val, "sub");
    defer ctx.allocator.free(sub_str);

    var super_sel = try parseSelectorArg(ctx, super_str, "super");
    defer super_sel.deinit();
    if (selector_mod.hasParentReference(&super_sel)) return parentNotAllowed("super");

    var sub_sel = try parseSelectorArg(ctx, sub_str, "sub");
    defer sub_sel.deinit();
    if (selector_mod.hasParentReference(&sub_sel)) return parentNotAllowed("sub");

    return boolValue(selector_mod.isSuperSelector(&super_sel, &sub_sel));
}

pub fn selector_extend(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{ "selector", "extendee", "extender" }, 3);
    const selector_val = bound[0] orelse return reportMissingArgument("selector");
    const extendee_val = bound[1] orelse return reportMissingArgument("extendee");
    const extender_val = bound[2] orelse return reportMissingArgument("extender");

    const sel_str = try selectorArgStringNamed(ctx, selector_val, "selector");
    defer ctx.allocator.free(sel_str);
    const extendee_str = try selectorArgStringNamed(ctx, extendee_val, "extendee");
    defer ctx.allocator.free(extendee_str);
    const extender_str = try selectorArgStringNamed(ctx, extender_val, "extender");
    defer ctx.allocator.free(extender_str);

    return selectorExtendCore(ctx, sel_str, extendee_str, extender_str);
}

pub fn selector_replace(ctx: *BuiltinContext, args: []const Value, arg_names: []const InternId) BuiltinError!Value {
    const bound = try bindNamedOrPositionalArgsStrict(ctx, args, arg_names, &.{ "selector", "original", "replacement" }, 3);
    const selector_val = bound[0] orelse return reportMissingArgument("selector");
    const original_val = bound[1] orelse return reportMissingArgument("original");
    const replacement_val = bound[2] orelse return reportMissingArgument("replacement");

    const sel_str = try selectorArgStringNamed(ctx, selector_val, "selector");
    defer ctx.allocator.free(sel_str);
    const original_str = try selectorArgStringNamed(ctx, original_val, "original");
    defer ctx.allocator.free(original_str);
    const replacement_str = try selectorArgStringNamed(ctx, replacement_val, "replacement");
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
    var sel = try parseSelectorArg(ctx, sel_str, "selector");
    defer sel.deinit();
    if (selectorListHasShallowParentSelector(&sel)) return parentNotAllowed("selector");

    var extendee = try parseSelectorArg(ctx, extendee_str, "extendee");
    defer extendee.deinit();
    for (extendee.selectors.items) |extendee_complex| {
        if (complexHasShallowParentSelector(&extendee_complex)) return parentNotAllowed("extendee");
        if (compoundCountInComplex(&extendee_complex) > 1) return cantExtendComplex(ctx, &extendee_complex, error.BuiltinType);
    }

    var extender = try parseSelectorArg(ctx, extender_str, "extender");
    defer extender.deinit();
    if (selectorListHasShallowParentSelector(&extender)) return parentNotAllowed("extender");

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
        ctx.budget,
        &sel,
        &extendee,
        &extender,
    );
    defer result.deinit();

    return selectorListToValue(ctx, &result);
}

fn selectorReplaceCore(
    ctx: *BuiltinContext,
    sel_str: []const u8,
    original_str: []const u8,
    replacement_str: []const u8,
) BuiltinError!Value {
    var sel = try parseSelectorArg(ctx, sel_str, "selector");
    defer sel.deinit();
    if (selectorListHasShallowParentSelector(&sel)) return parentNotAllowed("selector");

    var original = try parseSelectorArg(ctx, original_str, "original");
    defer original.deinit();
    for (original.selectors.items) |original_complex| {
        if (complexHasShallowParentSelector(&original_complex)) return parentNotAllowed("original");
        if (compoundCountInComplex(&original_complex) > 1) return cantExtendComplex(ctx, &original_complex, error.SassError);
    }

    var replacement = try parseSelectorArg(ctx, replacement_str, "replacement");
    defer replacement.deinit();
    if (selectorListHasShallowParentSelector(&replacement)) return parentNotAllowed("replacement");

    // The whole list at once: what one selector turns into can be dropped
    // for another selector of the list that covers it.
    var result = try extend_mod.applySelectorFunctionReplace(ctx.allocator, ctx.budget, &sel, &original, &replacement);
    defer result.deinit();
    return selectorListToValue(ctx, &result);
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

fn unifyComplexSelectors(
    allocator: std.mem.Allocator,
    budget: ?*resource_budget.ResourceBudget,
    complex1: *const ComplexSelector,
    complex2: *const ComplexSelector,
) ![]ComplexSelector {
    return extend_engine_mod.unifyComplexes(allocator, budget, complex1, complex2);
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

    const unified = try unifyComplexSelectors(allocator, null, &lhs.selectors.items[0], &rhs.selectors.items[0]);
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

    const unified = try unifyComplexSelectors(allocator, null, &lhs.selectors.items[0], &rhs.selectors.items[0]);
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

    const unified = try unifyComplexSelectors(allocator, null, &lhs.selectors.items[0], &rhs.selectors.items[0]);
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

    const unified = try unifyComplexSelectors(allocator, null, &lhs.selectors.items[0], &rhs.selectors.items[0]);
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
    // The result is a selector value: a comma list of space lists.
    try std.testing.expect(out.kind() == .list);
    const outer_items = ctx.list_pool.items[out.listHandle()];
    try std.testing.expectEqual(@as(usize, 1), outer_items.len);
    const inner_items = ctx.list_pool.items[outer_items[0].listHandle()];
    try std.testing.expectEqual(@as(usize, 1), inner_items.len);
    try std.testing.expectEqualStrings("c", ctx.intern_pool.get(inner_items[0].stringIntern()));
}
