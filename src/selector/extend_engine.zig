//! `@extend` as the Sass specification describes it (spec/at-rules/extend.md
//! in sass/sass), with the parts the specification leaves open settled by
//! what the official CLI prints.
//!
//! The model:
//!
//! * `@extend`s are registered in the order they run. Each makes one entry
//!   per complex selector of its rule's selector, as the `@extend`s before
//!   it left that selector.
//! * When an earlier extender holds the new target, every extender that
//!   holds it is extended with the new entries; what comes out extends that
//!   extender's own target.
//! * A style rule that some `@extend`s precede has all of them applied at
//!   once. Each later `@extend` is applied by itself, as it is registered,
//!   to the rules that hold its target.
//! * Extending a compound selector takes every combination of "this simple
//!   selector itself" and "one of its extenders"; extending a complex
//!   selector takes every combination of its compounds' results. The first
//!   position varies fastest. The extenders' simple selectors are added as
//!   the specification's "Unifying a Simple Selector" says, and their
//!   parents are woven with the selector's own.
//! * A generated selector is dropped when another selector covers it and is
//!   at least as specific as the extenders it came from (the second law of
//!   extend). A selector the rule was written with is never dropped (the
//!   first law), nor is an extender that stands as it was written. Where a
//!   generated selector came from is kept per simple selector: each one of
//!   an `@extend`'s rule carries the specificity of the complex selector it
//!   was written in. What a compound turns into is trimmed first, then the
//!   whole list; a list of more than a hundred selectors is left as it is.
//!
//! The rules a module uses are extended by that module's `@extend`s through
//! a second engine holding the extenders as they ended up (`Mode.resolved`);
//! `selector.extend()` and `selector.replace()` use the same machinery.

const std = @import("std");
const selector_mod = @import("selector.zig");
const spec_mod = @import("extend_specificity.zig");

const SelectorList = selector_mod.SelectorList;
const ComplexSelector = selector_mod.ComplexSelector;
const ComplexSelectorComponent = selector_mod.ComplexSelectorComponent;
const CompoundSelector = selector_mod.CompoundSelector;
const SimpleSelector = selector_mod.SimpleSelector;
const Combinator = selector_mod.Combinator;
const Specificity = spec_mod.Specificity;

const Allocator = std.mem.Allocator;
const Error = Allocator.Error;

const zero_spec: Specificity = .{ .a = 0, .b = 0, .c = 0 };

fn specMax(a: Specificity, b: Specificity) Specificity {
    return if (spec_mod.specificityGte(a, b)) a else b;
}

/// One `@extend`, as the caller knows it.
pub const Source = struct {
    extender: *const SelectorList,
    target: *const CompoundSelector,
    /// Position in the stylesheet's sequence of `@extend`s. A style rule
    /// says how many came before it with the same numbering.
    order: u32,
};

/// A compound selector whose simple selectors each remember where they
/// came from: the specificity of the complex selector of the `@extend`'s
/// rule they were written in, or nothing for a style rule's own.
const Marked = struct {
    simples: []const SimpleSelector,
    marks: []const Specificity,
};

const Piece = union(enum) {
    compound: Marked,
    combinator: Combinator,
};

/// A complex selector of a list being extended.
const Item = struct {
    pieces: []const Piece,
    /// The same selector in the form the rest of the code reads.
    complex: ComplexSelector,
    /// Written in the rule (possibly with a pseudo-class argument extended).
    original: bool = false,
};

const Entry = struct {
    target: SimpleSelector,
    /// Every simple selector that has to be there for the extender to
    /// apply. One for `@extend`; `selector.extend()` may name several.
    targets: []const SimpleSelector,
    pieces: []const Piece,
    complex: ComplexSelector,
    step: u32,
    /// Made by the `@extend` itself, not by extending an extender.
    direct: bool,
    /// A complex selector of the `@extend`'s rule as it was written.
    written: bool,
    /// A later `@extend` changed a pseudo-class argument in it; the changed
    /// selector is another entry.
    superseded: bool = false,
};

/// One result of extending a compound selector.
const Made = struct {
    pieces: []const Piece,
    /// One of the extenders in it was written on a line of its own.
    newline: bool = false,
    /// It is one extender as written and nothing else. The official CLI
    /// treats such a selector like one the rule was written with: it is
    /// never trimmed (`.z` stays beside `:is(.z)`).
    written_extender: bool = false,
};

const Step = struct {
    order: u32,
    target: SimpleSelector,
};

/// Which entries an extension pass sees.
const View = union(enum) {
    /// Every entry registered before the given order.
    before: u32,
    /// The entries one `@extend` made for its target: its own, and what
    /// came of extending the extenders that hold that target.
    step: u32,
    /// The entries one `@extend` made itself.
    step_direct: u32,
};

fn materialize(a: Allocator, pieces: []const Piece) Error!ComplexSelector {
    var complex = ComplexSelector.init(a);
    for (pieces) |piece| {
        switch (piece) {
            .combinator => |combinator| try complex.components.append(a, .{ .combinator = combinator }),
            .compound => |marked| {
                var compound = CompoundSelector.init(a);
                try compound.simple_selectors.appendSlice(a, marked.simples);
                try complex.components.append(a, .{ .compound = compound });
            },
        }
    }
    return complex;
}

fn piecesOf(a: Allocator, complex: *const ComplexSelector, mark: Specificity) Error![]const Piece {
    const out = try a.alloc(Piece, complex.components.items.len);
    for (complex.components.items, 0..) |component, index| {
        switch (component) {
            .combinator => |combinator| out[index] = .{ .combinator = combinator },
            .compound => |compound| {
                const marks = try a.alloc(Specificity, compound.simple_selectors.items.len);
                @memset(marks, mark);
                out[index] = .{ .compound = .{ .simples = compound.simple_selectors.items, .marks = marks } };
            },
        }
    }
    return out;
}

fn makeItem(a: Allocator, pieces: []const Piece, original: bool, newline: bool) Error!Item {
    var complex = try materialize(a, pieces);
    complex.leading_separator_has_newline = newline;
    return .{ .pieces = pieces, .complex = complex, .original = original };
}

/// The most specific of the extenders whose simple selectors are in it.
fn sourceSpec(pieces: []const Piece) Specificity {
    var spec = zero_spec;
    for (pieces) |piece| {
        if (piece != .compound) continue;
        for (piece.compound.marks) |mark| spec = specMax(spec, mark);
    }
    return spec;
}

pub const Detail = struct {
    original: bool,
    source: Specificity,
};

/// Trim a selector list put together from the results of several engines,
/// by the rule each engine trims with.
pub fn trimUnion(list: *SelectorList, details: *std.ArrayList(Detail)) void {
    const selectors = list.selectors.items;
    if (selectors.len > 100) return;
    var index = selectors.len;
    while (index > 0) {
        index -= 1;
        const detail = details.items[index];
        var covered = false;
        for (list.selectors.items, 0..) |*other, other_index| {
            if (other_index == index) continue;
            if (detail.original) {
                if (other_index < index and details.items[other_index].original and sameAsWritten(other, &list.selectors.items[index])) covered = true;
            } else if (spec_mod.specificityGte(spec_mod.complexSpecificity(other), detail.source) and
                selector_mod.complexIsSuperSelector(other, &list.selectors.items[index]))
            {
                covered = true;
            }
            if (covered) break;
        }
        if (covered) {
            var removed = list.selectors.orderedRemove(index);
            removed.deinit();
            _ = details.orderedRemove(index);
        }
    }
}

pub const Engine = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,
    steps: std.ArrayList(Step) = .empty,
    by_target: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty,
    steps_by_target: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty,
    mode: Mode = .written,
    /// `selector.replace()`: a compound that holds a target does not stay.
    replace: bool = false,

    pub const Mode = enum {
        /// `@extend`s of one module, as they were written.
        written,
        /// The selectors another module's rules ended up with: taken as
        /// they are, nothing extends them further.
        resolved,
        /// `selector.extend()`: like `resolved`, and the specificity of
        /// the extenders does not keep a result from being trimmed.
        function,
        /// `selector.replace()`: like `function`, and a compound that
        /// holds a target does not stay.
        replace,
    };

    /// `sources` must be in registration order.
    pub fn init(backing: Allocator, sources: []const Source, mode: Mode) Error!?*Engine {
        for (sources) |source| {
            if (source.target.simple_selectors.items.len == 0) return null;
        }
        const self = try backing.create(Engine);
        self.* = .{ .arena = std.heap.ArenaAllocator.init(backing), .mode = mode, .replace = mode == .replace };
        errdefer self.deinit(backing);
        for (sources) |source| try self.register(source);
        return self;
    }

    pub fn deinit(self: *Engine, backing: Allocator) void {
        self.arena.deinit();
        backing.destroy(self);
    }

    fn register(self: *Engine, source: Source) Error!void {
        const resolved = self.mode != .written;
        const by_function = self.mode == .function or self.mode == .replace;
        const a = self.arena.allocator();
        const targets = try a.alloc(SimpleSelector, source.target.simple_selectors.items.len);
        for (source.target.simple_selectors.items, 0..) |simple, index| targets[index] = try selector_mod.cloneSimpleSelector(simple, a);
        const target = targets[0];
        const step_index: u32 = @intCast(self.steps.items.len);

        // The extenders are the rule's selector as the extensions before
        // this one left it. Its own simple selectors are marked with the
        // specificity of the complex selector they are written in.
        var items: std.ArrayList(Item) = .empty;
        for (source.extender.selectors.items) |*written| {
            const complex = try written.clone(a);
            const pieces = try piecesOf(a, &complex, if (by_function) zero_spec else spec_mod.complexSpecificity(&complex));
            try items.append(a, try makeItem(a, pieces, true, complex.leading_separator_has_newline));
        }
        const extended = if (resolved) items.items else try self.extendItems(a, items.items, .{ .before = std.math.maxInt(u32) });

        try self.steps.append(a, .{ .order = source.order, .target = target });
        {
            const key = try simpleKey(a, target);
            const gop = try self.steps_by_target.getOrPut(a, key);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(a, step_index);
        }

        const direct_start = self.entries.items.len;
        for (extended) |item| try self.addEntry(targets, item, step_index, true);

        // When an earlier extender holds the target, every extender that
        // holds it is extended with the new entries, these new extenders
        // included; what comes out extends that extender's own target.
        // Without such an earlier extender nothing of the kind is done,
        // so `.z, .k .c {@extend .c}` alone does not make `.k .z` an
        // extender.
        var earlier_holds = false;
        if (resolved) return;
        for (self.entries.items[0..direct_start]) |*entry| {
            if (complexHoldsSimple(&entry.complex, target)) {
                earlier_holds = true;
                break;
            }
        }
        if (!earlier_holds) return;
        const direct_end = self.entries.items.len;
        var index: usize = 0;
        while (index < direct_end) : (index += 1) {
            const entry = self.entries.items[index];
            if (!complexHoldsSimple(&entry.complex, target)) continue;
            // Nothing is dropped here: every result is an extender.
            const one: Item = .{ .pieces = entry.pieces, .complex = entry.complex, .original = true };
            const derived = try self.extendComplex(a, &one, .{ .step_direct = step_index }) orelse continue;
            // The extender itself is there already; a first result that
            // differs from it (a pseudo-class argument was extended) is new.
            for (derived) |item| {
                if (item.original and !sameAsWritten(&item.complex, &entry.complex)) self.entries.items[index].superseded = true;
                try self.addEntry(entry.targets, item, step_index, false);
            }
        }
    }

    fn addEntry(self: *Engine, targets: []const SimpleSelector, item: Item, step: u32, direct: bool) Error!void {
        const a = self.arena.allocator();
        const first_key = try simpleKey(a, targets[0]);
        if (self.by_target.get(first_key)) |list| {
            for (list.items) |index| {
                const existing = &self.entries.items[index];
                if (existing.targets.len == targets.len and spec_mod.complexSelectorEql(&existing.complex, &item.complex)) return;
            }
        }
        const entry_index: u32 = @intCast(self.entries.items.len);
        for (targets) |target| {
            const gop = try self.by_target.getOrPut(a, try simpleKey(a, target));
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(a, entry_index);
        }
        try self.entries.append(a, .{
            .target = targets[0],
            .targets = targets,
            .pieces = item.pieces,
            .complex = item.complex,
            .step = step,
            .direct = direct,
            .written = direct and item.original and self.mode != .function and self.mode != .replace,
        });
    }

    /// The extenders registered, in order, each with its target.
    pub fn entryCount(self: *const Engine) usize {
        return self.entries.items.len;
    }

    pub fn entrySuperseded(self: *const Engine, index: usize) bool {
        return self.entries.items[index].superseded;
    }

    pub fn entryTarget(self: *const Engine, index: usize) SimpleSelector {
        return self.entries.items[index].target;
    }

    pub fn entryExtender(self: *const Engine, index: usize) *const ComplexSelector {
        return &self.entries.items[index].complex;
    }

    /// Extend the selector of a rule that `snapshot` extensions precede.
    pub fn extendSelector(self: *Engine, out: Allocator, list: *const SelectorList, snapshot: u32) Error!SelectorList {
        return self.extendSelectorDetailed(out, list, snapshot, null);
    }

    /// The same, also telling of every resulting selector whether the rule
    /// was written with it and how specific its extenders are.
    pub fn extendSelectorDetailed(self: *Engine, out: Allocator, list: *const SelectorList, snapshot: u32, details: ?*std.ArrayList(Detail)) Error!SelectorList {
        var scratch = std.heap.ArenaAllocator.init(self.arena.child_allocator);
        defer scratch.deinit();
        const a = scratch.allocator();

        var items: std.ArrayList(Item) = .empty;
        for (list.selectors.items) |*written| {
            const pieces = try piecesOf(a, written, zero_spec);
            try items.append(a, try makeItem(a, pieces, true, written.leading_separator_has_newline));
        }
        var current = try self.extendItems(a, items.items, .{ .before = snapshot });

        var next_step: u32 = 0;
        while (next_step < self.steps.items.len and self.steps.items[next_step].order < snapshot) next_step += 1;
        while (true) {
            const step_index = try self.firstStepHeld(a, current, next_step) orelse break;
            current = try self.extendItems(a, current, .{ .step = step_index });
            next_step = step_index + 1;
        }

        var result = SelectorList.init(out);
        errdefer result.deinit();
        for (current) |*item| {
            var cloned = try item.complex.clone(out);
            errdefer cloned.deinit();
            try result.selectors.append(out, cloned);
            if (details) |list_out| try list_out.append(out, .{ .original = item.original, .source = sourceSpec(item.pieces) });
        }
        return result;
    }

    /// The first step at or after `from` whose target one of `items` holds.
    fn firstStepHeld(self: *Engine, a: Allocator, items: []const Item, from: u32) Error!?u32 {
        if (from >= self.steps.items.len) return null;
        var best: ?u32 = null;
        for (items) |*item| try self.firstStepInComplex(a, &item.complex, from, &best);
        return best;
    }

    fn firstStepInComplex(self: *Engine, a: Allocator, complex: *const ComplexSelector, from: u32, best: *?u32) Error!void {
        for (complex.components.items) |*component| {
            if (component.* != .compound) continue;
            for (component.compound.simple_selectors.items) |simple| {
                const key = try simpleKey(a, simple);
                if (self.steps_by_target.get(key)) |step_list| {
                    for (step_list.items) |step_index| {
                        if (step_index < from) continue;
                        if (best.* == null or step_index < best.*.?) best.* = step_index;
                        break;
                    }
                }
                const inner = pseudoSelectorOf(simple) orelse continue;
                for (inner.selectors.items) |*inner_complex| try self.firstStepInComplex(a, inner_complex, from, best);
            }
        }
    }

    fn entriesFor(self: *Engine, a: Allocator, simple: SimpleSelector, view: View, out: *std.ArrayList(*const Entry)) Error!void {
        const key = try simpleKey(a, simple);
        const list = self.by_target.get(key) orelse return;
        for (list.items) |index| {
            const entry = &self.entries.items[index];
            const visible = switch (view) {
                .before => |order| self.steps.items[entry.step].order < order,
                .step => |step| entry.step == step and spec_mod.simpleSelectorEql(entry.target, self.steps.items[step].target),
                .step_direct => |step| entry.step == step and entry.direct,
            };
            if (visible) try out.append(a, entry);
        }
    }

    // ------------------------------------------------------------------
    // Extending a selector list
    // ------------------------------------------------------------------

    fn extendItems(self: *Engine, a: Allocator, items: []Item, view: View) Error![]Item {
        var out: std.ArrayList(Item) = .empty;
        var changed = false;
        for (items) |*item| {
            if (try self.extendComplex(a, item, view)) |extended| {
                changed = true;
                try out.appendSlice(a, extended);
            } else {
                try out.append(a, item.*);
            }
        }
        if (!changed) return items;
        if (self.replace) return out.items;
        return trim(a, out.items);
    }

    /// Every combination of the results of the selector's compounds, the
    /// selector itself first. Null when nothing in it is extended.
    fn extendComplex(self: *Engine, a: Allocator, item: *const Item, view: View) Error!?[]Item {
        const pieces = item.pieces;
        // A selector with two combinators in a row is left alone.
        for (pieces[0..pieces.len -| 1], pieces[@min(1, pieces.len)..]) |x, y| {
            if (x == .combinator and y == .combinator) return null;
        }
        var options: std.ArrayList(?[]const Made) = .empty;
        var any = false;
        for (pieces) |piece| {
            if (piece != .compound) {
                try options.append(a, null);
                continue;
            }
            const extended = try self.extendCompound(a, piece.compound, view);
            if (extended != null) any = true;
            try options.append(a, extended);
        }
        if (!any) return null;

        var results: std.ArrayList(Item) = .empty;
        const choice = try a.alloc(usize, pieces.len);
        @memset(choice, 0);
        while (true) {
            var all_first = true;
            var newline = item.complex.leading_separator_has_newline;
            var written_extender = false;
            for (pieces, 0..) |_, index| {
                const list = options.items[index] orelse continue;
                if (choice[index] != 0) all_first = false;
                if (list[choice[index]].newline) newline = true;
                if (pieces.len == 1 and list[choice[index]].written_extender) written_extender = true;
            }
            const woven = try weaveChoice(a, pieces, options.items, choice);
            for (woven) |made| {
                try results.append(a, try makeItem(a, made, (item.original and all_first) or written_extender, newline));
            }

            // The first position varies fastest.
            var position: usize = 0;
            while (position < pieces.len) : (position += 1) {
                const list = options.items[position] orelse continue;
                choice[position] += 1;
                if (choice[position] < list.len) break;
                choice[position] = 0;
            }
            if (position == pieces.len) break;
        }
        return results.items;
    }

    /// The results of extending one compound selector: the compound itself
    /// first, then one result per combination of extenders. Null when
    /// nothing in it is extended.
    fn extendCompound(self: *Engine, a: Allocator, written: Marked, view: View) Error!?[]const Made {
        // A pseudo-class whose argument is extended is replaced first; what
        // replaces it can be a target itself.
        var any = false;
        var expanded_simples: std.ArrayList(SimpleSelector) = .empty;
        var expanded_marks: std.ArrayList(Specificity) = .empty;
        for (written.simples, written.marks) |simple, mark| {
            if (try self.extendPseudo(a, simple, view)) |replaced| {
                any = true;
                for (replaced) |each| {
                    try expanded_simples.append(a, each);
                    try expanded_marks.append(a, mark);
                }
            } else {
                try expanded_simples.append(a, simple);
                try expanded_marks.append(a, mark);
            }
        }
        const compound: Marked = .{ .simples = expanded_simples.items, .marks = expanded_marks.items };

        var choices: std.ArrayList([]const *const Entry) = .empty;
        for (compound.simples) |simple| {
            var found: std.ArrayList(*const Entry) = .empty;
            try self.entriesFor(a, simple, view, &found);
            // An extender with several targets applies only where all of
            // them are.
            var kept: usize = 0;
            for (found.items) |entry| {
                if (entry.targets.len > 1 and !holdsAll(compound.simples, entry.targets)) continue;
                found.items[kept] = entry;
                kept += 1;
            }
            found.items.len = kept;
            if (found.items.len != 0) any = true;
            try choices.append(a, found.items);
        }
        if (!any) return null;

        var results: std.ArrayList(Made) = .empty;
        const choice = try a.alloc(usize, compound.simples.len);
        @memset(choice, 0);
        while (true) {
            var base_simples: std.ArrayList(SimpleSelector) = .empty;
            var base_marks: std.ArrayList(Specificity) = .empty;
            var chosen: std.ArrayList(*const Entry) = .empty;
            var valid = true;
            for (choices.items, 0..) |entries, index| {
                if (choice[index] == 0) {
                    if (self.replace and entries.len != 0) valid = false;
                    continue;
                }
                // Every target of the chosen extender goes with it.
                const entry = entries[choice[index] - 1];
                if (entry.targets.len == 1) continue;
                for (compound.simples, 0..) |simple, other| {
                    if (other == index or !holdsAll(entry.targets, &[_]SimpleSelector{simple})) continue;
                    if (choice[other] == 0 or choices.items[other][choice[other] - 1] != entry) valid = false;
                }
            }
            for (choices.items, 0..) |entries, index| {
                if (choice[index] == 0) {
                    try base_simples.append(a, compound.simples[index]);
                    try base_marks.append(a, compound.marks[index]);
                    continue;
                }
                const entry = entries[choice[index] - 1];
                var seen = false;
                for (chosen.items) |other| {
                    if (other == entry) seen = true;
                }
                if (!seen) try chosen.append(a, entry);
            }
            if (!valid) {
                // Not a combination.
            } else if (chosen.items.len == 0) {
                const single = try a.alloc(Piece, 1);
                single[0] = .{ .compound = .{ .simples = base_simples.items, .marks = base_marks.items } };
                try results.append(a, .{ .pieces = single });
            } else {
                try unifyChosen(a, &base_simples, &base_marks, chosen.items, &results);
            }

            var position: usize = 0;
            while (position < compound.simples.len) : (position += 1) {
                choice[position] += 1;
                if (choice[position] <= choices.items[position].len) break;
                choice[position] = 0;
            }
            if (position == compound.simples.len) break;
        }

        // What a compound turns into is trimmed by itself, the compound
        // counting as written.
        if (results.items.len == 0) return null;
        var items: std.ArrayList(Item) = .empty;
        for (results.items, 0..) |made, index| {
            try items.append(a, try makeItem(a, made.pieces, (index == 0 and !self.replace) or made.written_extender, made.newline));
        }
        const kept = if (self.replace) items.items else try trim(a, items.items);
        const out = try a.alloc(Made, kept.len);
        for (kept, 0..) |item, index| {
            var written_extender = false;
            for (results.items) |made| {
                if (made.pieces.ptr == item.pieces.ptr) written_extender = made.written_extender;
            }
            out[index] = .{ .pieces = item.pieces, .newline = item.complex.leading_separator_has_newline, .written_extender = written_extender };
        }
        return out;
    }

    /// Extend the selector argument of a pseudo-class. Returns what replaces
    /// the pseudo-class, or null when its argument holds no target.
    fn extendPseudo(self: *Engine, a: Allocator, simple: SimpleSelector, view: View) Error!?[]const SimpleSelector {
        const pseudo = switch (simple) {
            .pseudo_class => |p| p,
            .pseudo_element => |p| p,
            else => return null,
        };
        const argument = pseudo.selector orelse return null;

        var items: std.ArrayList(Item) = .empty;
        for (argument.selectors.items) |*written| {
            const pieces = try piecesOf(a, written, zero_spec);
            try items.append(a, try makeItem(a, pieces, true, written.leading_separator_has_newline));
        }
        const extended = try self.extendItems(a, items.items, view);
        if (extended.ptr == items.items.ptr) return null;

        const name = selector_mod.pseudoBaseName(pseudo.name);
        var complexes: std.ArrayList(ComplexSelector) = .empty;

        if (std.ascii.eqlIgnoreCase(name, "not")) {
            var written_with_complex = false;
            for (argument.selectors.items) |*complex| {
                if (compoundCount(complex) > 1) written_with_complex = true;
            }
            for (extended) |*item| {
                if (!written_with_complex and compoundCount(&item.complex) > 1) continue;
                if (onlyPseudoWithSelector(&item.complex)) |inner| {
                    const inner_name = selector_mod.pseudoBaseName(inner.name);
                    if (std.ascii.eqlIgnoreCase(inner_name, "is") or
                        std.ascii.eqlIgnoreCase(inner_name, "where") or
                        std.ascii.eqlIgnoreCase(inner_name, "matches"))
                    {
                        for (inner.selector.?.selectors.items) |complex| try complexes.append(a, complex);
                    }
                    continue;
                }
                try complexes.append(a, item.complex);
            }
            if (complexes.items.len == 0) return null;
            if (argument.selectors.items.len > 1) {
                const one = try a.alloc(SimpleSelector, 1);
                one[0] = try pseudoWithSelector(a, simple, complexes.items);
                return one;
            }
            const each = try a.alloc(SimpleSelector, complexes.items.len);
            for (complexes.items, 0..) |complex, index| {
                each[index] = try pseudoWithSelector(a, simple, &[_]ComplexSelector{complex});
            }
            return each;
        }

        const flattens = std.ascii.eqlIgnoreCase(name, "is") or
            std.ascii.eqlIgnoreCase(name, "where") or
            std.ascii.eqlIgnoreCase(name, "matches") or
            std.ascii.eqlIgnoreCase(name, "any") or
            std.ascii.eqlIgnoreCase(name, "current") or
            std.ascii.eqlIgnoreCase(name, "nth-child") or
            std.ascii.eqlIgnoreCase(name, "nth-last-child");
        for (extended) |*item| {
            if (flattens) {
                if (onlyPseudoWithSelector(&item.complex)) |inner| {
                    if (std.ascii.eqlIgnoreCase(inner.name, pseudo.name) and optionalTextEql(inner.argument, pseudo.argument)) {
                        for (inner.selector.?.selectors.items) |complex| try complexes.append(a, complex);
                    }
                    continue;
                }
            }
            try complexes.append(a, item.complex);
        }
        const one = try a.alloc(SimpleSelector, 1);
        one[0] = try pseudoWithSelector(a, simple, complexes.items);
        return one;
    }
};

// ----------------------------------------------------------------------
// Unifying the chosen extenders into a compound
// ----------------------------------------------------------------------

/// `base` holds the simple selectors of the compound that stay. Each chosen
/// extender's last compound is merged into it and the extenders' parents
/// are woven together; one result per way of weaving is appended.
fn unifyChosen(
    a: Allocator,
    base_simples: *std.ArrayList(SimpleSelector),
    base_marks: *std.ArrayList(Specificity),
    chosen: []const *const Entry,
    results: *std.ArrayList(Made),
) Error!void {
    var newline = false;
    var trailing: ?Combinator = null;
    const written_extender = base_simples.items.len == 0 and chosen.len == 1 and chosen[0].written;
    // Parents, each ending with the combinator that binds it to the compound.
    var parents: std.ArrayList([]const Piece) = .empty;
    try parents.append(a, &.{});

    for (chosen, 0..) |entry, index| {
        if (entry.complex.leading_separator_has_newline) newline = true;
        // An extender may end with a combinator, which then follows the
        // compound it is merged into.
        var pieces = entry.pieces;
        while (pieces.len != 0 and pieces[pieces.len - 1] == .combinator) {
            if (trailing != null) return;
            trailing = pieces[pieces.len - 1].combinator;
            pieces = pieces[0 .. pieces.len - 1];
        }
        if (pieces.len == 0) return;
        const last = pieces[pieces.len - 1].compound;
        if (index == 0 and base_simples.items.len == 0) {
            try base_simples.appendSlice(a, last.simples);
            try base_marks.appendSlice(a, last.marks);
        } else {
            var after_element = false;
            for (last.simples, last.marks) |simple, mark| {
                if (!try unifySimple(a, base_simples, base_marks, simple, mark, after_element)) return;
                if (isPseudoElement(simple)) after_element = true;
            }
        }

        const prefix = pieces[0 .. pieces.len - 1];
        if (prefix.len == 0) continue;
        var next: std.ArrayList([]const Piece) = .empty;
        for (parents.items) |existing| {
            if (existing.len == 0) {
                try next.append(a, prefix);
                continue;
            }
            const woven = try weavePrefixes(a, existing, prefix);
            try next.appendSlice(a, woven);
        }
        parents = next;
        if (parents.items.len == 0) return;
    }

    for (parents.items) |prefix| {
        var out: std.ArrayList(Piece) = .empty;
        try out.appendSlice(a, prefix);
        try out.append(a, .{ .compound = .{ .simples = base_simples.items, .marks = base_marks.items } });
        if (trailing) |combinator| try out.append(a, .{ .combinator = combinator });
        try results.append(a, .{ .pieces = out.items, .newline = newline, .written_extender = written_extender and trailing == null });
    }
}

fn isPseudoElement(simple: SimpleSelector) bool {
    return switch (simple) {
        .pseudo_element => true,
        .pseudo_class => |p| p.selector == null and p.argument == null and isLegacyPseudoElementName(p.name),
        else => false,
    };
}

fn isLegacyPseudoElementName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "before") or
        std.ascii.eqlIgnoreCase(name, "after") or
        std.ascii.eqlIgnoreCase(name, "first-line") or
        std.ascii.eqlIgnoreCase(name, "first-letter");
}

/// `:before` and `::before` are the same pseudo-element.
fn samePseudoElement(x: SimpleSelector, y: SimpleSelector) bool {
    if (!isPseudoElement(x) or !isPseudoElement(y)) return false;
    const px = switch (x) {
        .pseudo_class => |p| p,
        .pseudo_element => |p| p,
        else => return false,
    };
    const py = switch (y) {
        .pseudo_class => |p| p,
        .pseudo_element => |p| p,
        else => return false,
    };
    return px.selector == null and py.selector == null and px.argument == null and py.argument == null and
        isLegacyPseudoElementName(px.name) and std.ascii.eqlIgnoreCase(px.name, py.name);
}

fn isPseudo(simple: SimpleSelector) bool {
    return simple == .pseudo_class or simple == .pseudo_element;
}

fn isHost(simple: SimpleSelector) bool {
    const pseudo = switch (simple) {
        .pseudo_class => |p| p,
        else => return false,
    };
    return std.ascii.eqlIgnoreCase(pseudo.name, "host") or std.ascii.eqlIgnoreCase(pseudo.name, "host-context");
}

const TypeParts = struct { namespace: ?[]const u8, name: []const u8 };

fn typeParts(simple: SimpleSelector) ?TypeParts {
    return switch (simple) {
        .universal => .{ .namespace = null, .name = "*" },
        .type_selector => |text| if (std.mem.indexOfScalar(u8, text, '|')) |bar|
            .{ .namespace = text[0..bar], .name = text[bar + 1 ..] }
        else
            .{ .namespace = null, .name = text },
        else => null,
    };
}

/// "Unifying a Simple Selector" of the specification: add `simple` to
/// the compound so that it matches what both match. False when nothing can.
fn unifySimple(
    a: Allocator,
    simples: *std.ArrayList(SimpleSelector),
    marks: *std.ArrayList(Specificity),
    simple: SimpleSelector,
    mark: Specificity,
    /// In the compound it comes from, `simple` follows a pseudo-element.
    after_element: bool,
) Error!bool {
    if (isHost(simple)) {
        for (simples.items) |other| {
            if (!isHost(other) and pseudoSelectorOf(other) == null) return false;
        }
    } else if (pseudoSelectorOf(simple) == null) {
        for (simples.items) |other| {
            if (isHost(other)) return false;
        }
    }

    if (typeParts(simple)) |added| {
        for (simples.items, 0..) |other, index| {
            const existing = typeParts(other) orelse continue;
            const merged = mergeTypes(existing, added) orelse return false;
            simples.items[index] = try typeSimple(a, merged);
            marks.items[index] = specMax(marks.items[index], mark);
            return true;
        }
        // A universal selector adds nothing to a compound that says more.
        const any_namespace = added.namespace == null or std.mem.eql(u8, added.namespace.?, "*");
        if (any_namespace and std.mem.eql(u8, added.name, "*") and simples.items.len != 0) return true;
        try simples.insert(a, 0, simple);
        try marks.insert(a, 0, mark);
        return true;
    }

    for (simples.items) |other| {
        if (spec_mod.simpleSelectorEql(other, simple) or samePseudoElement(other, simple)) return true;
    }
    // `*` alone gives way to what is added to it.
    if (simples.items.len == 1 and simples.items[0] == .universal) {
        simples.items[0] = simple;
        marks.items[0] = mark;
        return true;
    }
    if (simple == .id) {
        for (simples.items) |other| {
            if (other == .id) return false;
        }
    }
    if (isPseudoElement(simple)) {
        for (simples.items) |other| {
            if (isPseudoElement(other)) return false;
        }
        try simples.append(a, simple);
        try marks.append(a, mark);
        return true;
    }
    var position = simples.items.len;
    if (after_element) {
        // What follows a pseudo-element stays behind it.
    } else if (isPseudo(simple)) {
        for (simples.items, 0..) |other, index| {
            if (isPseudoElement(other) or isHost(other)) {
                position = index;
                break;
            }
        }
    } else {
        for (simples.items, 0..) |other, index| {
            if (isPseudo(other)) {
                position = index;
                break;
            }
        }
    }
    try simples.insert(a, position, simple);
    try marks.insert(a, position, mark);
    return true;
}

fn mergeTypes(x: TypeParts, y: TypeParts) ?TypeParts {
    const x_any_name = std.mem.eql(u8, x.name, "*");
    const y_any_name = std.mem.eql(u8, y.name, "*");
    const name = if (x_any_name) y.name else if (y_any_name) x.name else if (std.mem.eql(u8, x.name, y.name)) x.name else return null;
    var namespace: ?[]const u8 = null;
    if (x.namespace != null and y.namespace != null) {
        const xn = x.namespace.?;
        const yn = y.namespace.?;
        namespace = if (std.mem.eql(u8, xn, "*")) yn else if (std.mem.eql(u8, yn, "*")) xn else if (std.mem.eql(u8, xn, yn)) xn else return null;
    } else if (x.namespace != null or y.namespace != null) {
        const explicit = (x.namespace orelse y.namespace).?;
        if (!std.mem.eql(u8, explicit, "*")) return null;
    }
    return .{ .namespace = namespace, .name = name };
}

fn typeSimple(a: Allocator, parts: TypeParts) Error!SimpleSelector {
    if (parts.namespace) |namespace| {
        return .{ .type_selector = try std.fmt.allocPrint(a, "{s}|{s}", .{ namespace, parts.name }) };
    }
    if (std.mem.eql(u8, parts.name, "*")) return .universal;
    return .{ .type_selector = parts.name };
}

// ----------------------------------------------------------------------
// Weaving
// ----------------------------------------------------------------------

/// A compound selector and the combinator that follows it.
const Link = struct {
    compound: CompoundSelector,
    marks: []const Specificity,
    combinator: Combinator,
};

const Parents = struct {
    leading: []const Combinator,
    links: []Link,
};

/// Split a sequence of parents into its links. Null for a sequence this
/// model does not describe (two combinators in a row).
fn parseParents(a: Allocator, pieces: []const Piece) Error!?Parents {
    var leading: std.ArrayList(Combinator) = .empty;
    var links: std.ArrayList(Link) = .empty;
    var index: usize = 0;
    while (index < pieces.len and pieces[index] == .combinator) : (index += 1) {
        try leading.append(a, pieces[index].combinator);
    }
    while (index < pieces.len) {
        if (pieces[index] != .compound) return null;
        const marked = pieces[index].compound;
        var compound = CompoundSelector.init(a);
        try compound.simple_selectors.appendSlice(a, marked.simples);
        var link: Link = .{ .compound = compound, .marks = marked.marks, .combinator = .descendant };
        index += 1;
        if (index < pieces.len and pieces[index] == .combinator) {
            link.combinator = pieces[index].combinator;
            index += 1;
        }
        try links.append(a, link);
    }
    return .{ .leading = leading.items, .links = links.items };
}

/// The two compounds as one, followed by `combinator`.
fn unifyLinks(a: Allocator, first: Link, second: Link, combinator: Combinator) Error!?Link {
    var simples: std.ArrayList(SimpleSelector) = .empty;
    var marks: std.ArrayList(Specificity) = .empty;
    try simples.appendSlice(a, first.compound.simple_selectors.items);
    try marks.appendSlice(a, first.marks);
    var after_element = false;
    for (second.compound.simple_selectors.items, second.marks) |simple, mark| {
        if (!try unifySimple(a, &simples, &marks, simple, mark, after_element)) return null;
        if (isPseudoElement(simple)) after_element = true;
    }
    var compound = CompoundSelector.init(a);
    try compound.simple_selectors.appendSlice(a, simples.items);
    return .{ .compound = compound, .marks = marks.items, .combinator = combinator };
}

fn oneLink(a: Allocator, link: Link) Error![]const Link {
    const out = try a.alloc(Link, 1);
    out[0] = link;
    return out;
}

fn twoLinks(a: Allocator, first: Link, second: Link) Error![]const Link {
    const out = try a.alloc(Link, 2);
    out[0] = first;
    out[1] = second;
    return out;
}

/// How many links the first group has.
fn groupEnd(links: []const Link) usize {
    for (links, 0..) |link, index| {
        if (link.combinator == .descendant) return index + 1;
    }
    return links.len;
}

/// The runs of links held together by combinators other than descendant.
fn groupsOf(a: Allocator, links: []const Link) Error![]const []const Link {
    var groups: std.ArrayList([]const Link) = .empty;
    var start: usize = 0;
    for (links, 0..) |link, index| {
        if (link.combinator == .descendant) {
            try groups.append(a, links[start .. index + 1]);
            start = index + 1;
        }
    }
    if (start < links.len) try groups.append(a, links[start..]);
    return groups.items;
}

/// The group as the parents of some element.
fn groupAsParents(a: Allocator, group: []const Link) Error!ComplexSelector {
    var complex = ComplexSelector.init(a);
    for (group) |link| {
        try complex.components.append(a, .{ .compound = link.compound });
        try complex.components.append(a, .{ .combinator = link.combinator });
    }
    var element = CompoundSelector.init(a);
    try element.simple_selectors.append(a, .{ .placeholder = "-" });
    try complex.components.append(a, .{ .compound = element });
    return complex;
}

/// True when every element with the parents `narrow` has the parents `wide`.
fn parentsCover(a: Allocator, wide: []const Link, narrow: []const Link) Error!bool {
    const x = try groupAsParents(a, wide);
    const y = try groupAsParents(a, narrow);
    return selector_mod.complexIsSuperSelector(&x, &y);
}

/// True for a simple selector only one element can match within its scope:
/// an ID or a pseudo-element.
fn isUnique(simple: SimpleSelector) bool {
    return simple == .id or isPseudoElement(simple);
}

fn shareUnique(first: []const Link, second: []const Link) bool {
    for (first) |link1| {
        for (link1.compound.simple_selectors.items) |x| {
            if (!isUnique(x)) continue;
            for (second) |link2| {
                for (link2.compound.simple_selectors.items) |y| {
                    if (spec_mod.simpleSelectorEql(x, y)) return true;
                }
            }
        }
    }
    return false;
}

fn linksToPieces(a: Allocator, links: []const Link) Error![]const Piece {
    var out: std.ArrayList(Piece) = .empty;
    for (links) |link| {
        try out.append(a, .{ .compound = .{ .simples = link.compound.simple_selectors.items, .marks = link.marks } });
        try out.append(a, .{ .combinator = link.combinator });
    }
    return out.items;
}

/// Two groups as one: their last compounds merged and the parents before
/// them woven. Null unless there is exactly one way.
fn unifyGroups(a: Allocator, base: []const Link, added: []const Link) Error!?[]const Link {
    const base_last = base[base.len - 1];
    const added_last = added[added.len - 1];
    const last = try unifyLinks(a, base_last, added_last, base_last.combinator) orelse return null;
    var links: std.ArrayList(Link) = .empty;
    if (base.len > 1 or added.len > 1) {
        const woven = try weavePrefixes(
            a,
            try linksToPieces(a, base[0 .. base.len - 1]),
            try linksToPieces(a, added[0 .. added.len - 1]),
        );
        if (woven.len != 1) return null;
        const parsed = try parseParents(a, woven[0]) orelse return null;
        if (parsed.leading.len != 0) return null;
        try links.appendSlice(a, parsed.links);
    }
    try links.append(a, last);
    return links.items;
}

/// True for a compound that names the root of its tree.
fn isRootish(compound: *const CompoundSelector) bool {
    for (compound.simple_selectors.items) |simple| {
        const pseudo = switch (simple) {
            .pseudo_class => |p| p,
            else => continue,
        };
        if (std.ascii.eqlIgnoreCase(pseudo.name, "root") or
            std.ascii.eqlIgnoreCase(pseudo.name, "scope") or
            std.ascii.eqlIgnoreCase(pseudo.name, "host") or
            std.ascii.eqlIgnoreCase(pseudo.name, "host-context")) return true;
    }
    return false;
}

/// The group that stands for both when two parents are taken to be the
/// same element: the narrower of the two when one covers the other, and
/// the two put together when they name the same ID or pseudo-element.
fn commonGroup(a: Allocator, first: []const Link, second: []const Link) Error!?[]const Link {
    if (shareUnique(first, second)) return unifyGroups(a, second, first);
    if (try parentsCover(a, second, first)) return first;
    if (try parentsCover(a, first, second)) return second;
    return null;
}

/// Weave two sequences of parents, each ending with the combinator that
/// binds it to what follows. The parents next to what follows are merged
/// by their combinators; the rest keep their own order, and the parents the
/// two share are written once.
fn weavePrefixes(a: Allocator, first: []const Piece, second: []const Piece) Error![]const []const Piece {
    const one = try parseParents(a, first) orelse return &.{};
    const two = try parseParents(a, second) orelse return &.{};
    if (one.leading.len != 0 and two.leading.len != 0 and !std.mem.eql(Combinator, one.leading, two.leading)) return &.{};
    const leading = if (one.leading.len != 0) one.leading else two.leading;

    var links1 = one.links;
    var links2 = two.links;

    // Sets of alternatives, in the order they are written.
    var sets: std.ArrayList([]const []const Link) = .empty;

    // The ends, last first.
    var tail_sets: std.ArrayList([]const []const Link) = .empty;
    while (true) {
        const end1: ?Link = if (links1.len != 0 and links1[links1.len - 1].combinator != .descendant) links1[links1.len - 1] else null;
        const end2: ?Link = if (links2.len != 0 and links2[links2.len - 1].combinator != .descendant) links2[links2.len - 1] else null;
        if (end1 == null and end2 == null) break;
        var alternatives: std.ArrayList([]const Link) = .empty;
        if (end1 != null and end2 != null) {
            const l1 = end1.?;
            const l2 = end2.?;
            const c1 = l1.combinator;
            const c2 = l2.combinator;
            if (c1 == .general_sibling and c2 == .general_sibling) {
                if (selector_mod.compoundIsSuperSelector(l1.compound, l2.compound)) {
                    try alternatives.append(a, try oneLink(a, l2));
                } else if (selector_mod.compoundIsSuperSelector(l2.compound, l1.compound)) {
                    try alternatives.append(a, try oneLink(a, l1));
                } else {
                    try alternatives.append(a, try twoLinks(a, l1, l2));
                    try alternatives.append(a, try twoLinks(a, l2, l1));
                    if (try unifyLinks(a, l1, l2, .general_sibling)) |unified| {
                        try alternatives.append(a, try oneLink(a, unified));
                    }
                }
                links1 = links1[0 .. links1.len - 1];
                links2 = links2[0 .. links2.len - 1];
            } else if ((c1 == .general_sibling and c2 == .next_sibling) or (c1 == .next_sibling and c2 == .general_sibling)) {
                const following = if (c1 == .general_sibling) l1 else l2;
                const next = if (c1 == .general_sibling) l2 else l1;
                if (selector_mod.compoundIsSuperSelector(following.compound, next.compound)) {
                    try alternatives.append(a, try oneLink(a, next));
                } else {
                    try alternatives.append(a, try twoLinks(a, following, next));
                    if (try unifyLinks(a, following, next, .next_sibling)) |unified| {
                        try alternatives.append(a, try oneLink(a, unified));
                    }
                }
                links1 = links1[0 .. links1.len - 1];
                links2 = links2[0 .. links2.len - 1];
            } else if (c1 == .child and (c2 == .general_sibling or c2 == .next_sibling)) {
                try alternatives.append(a, try oneLink(a, l2));
                links2 = links2[0 .. links2.len - 1];
            } else if (c2 == .child and (c1 == .general_sibling or c1 == .next_sibling)) {
                try alternatives.append(a, try oneLink(a, l1));
                links1 = links1[0 .. links1.len - 1];
            } else if (c1 == c2) {
                const unified = try unifyLinks(a, l1, l2, c1) orelse return &.{};
                try alternatives.append(a, try oneLink(a, unified));
                links1 = links1[0 .. links1.len - 1];
                links2 = links2[0 .. links2.len - 1];
            } else {
                return &.{};
            }
        } else if (end1) |l1| {
            // An ancestor on the other side that covers this parent is
            // taken to be this parent.
            if (l1.combinator == .child and links2.len != 0 and selector_mod.compoundIsSuperSelector(links2[links2.len - 1].compound, l1.compound)) {
                links2 = links2[0 .. links2.len - 1];
            }
            try alternatives.append(a, try oneLink(a, l1));
            links1 = links1[0 .. links1.len - 1];
        } else {
            const l2 = end2.?;
            if (l2.combinator == .child and links1.len != 0 and selector_mod.compoundIsSuperSelector(links1[links1.len - 1].compound, l2.compound)) {
                links1 = links1[0 .. links1.len - 1];
            }
            try alternatives.append(a, try oneLink(a, l2));
            links2 = links2[0 .. links2.len - 1];
        }
        try tail_sets.append(a, alternatives.items);
    }

    // A root comes first, and two roots are one.
    {
        const root1 = links1.len != 0 and isRootish(&links1[0].compound);
        const root2 = links2.len != 0 and isRootish(&links2[0].compound);
        if (root1 and root2) {
            // What a combinator ties to one root stays right behind it.
            const tied1 = groupEnd(links1);
            const tied2 = groupEnd(links2);
            const tied = if (tied1 > 1) links1[1..tied1] else links2[1..tied2];
            if (tied1 > 1 and tied2 > 1) return &.{};
            const combinator = if (tied1 > 1) links1[0].combinator else links2[0].combinator;
            const unified = try unifyLinks(a, links1[0], links2[0], combinator) orelse return &.{};
            const single = try a.alloc([]const Link, 1);
            single[0] = try joinLinks(a, try oneLink(a, unified), tied);
            try sets.append(a, single);
            links1 = links1[tied1..];
            links2 = links2[tied2..];
        } else if (root1 or root2) {
            const links = if (root1) links1 else links2;
            const tied = groupEnd(links);
            const single = try a.alloc([]const Link, 1);
            single[0] = links[0..tied];
            try sets.append(a, single);
            if (root1) links1 = links1[tied..] else links2 = links2[tied..];
        }
    }

    // The rest: the longest run of parents the two share, and between its
    // members what each has on its own, in either order.
    const groups1 = try groupsOf(a, links1);
    const groups2 = try groupsOf(a, links2);
    const rows = groups1.len + 1;
    const cols = groups2.len + 1;
    const lengths = try a.alloc(usize, rows * cols);
    @memset(lengths, 0);
    const common = try a.alloc(?[]const Link, rows * cols);
    @memset(common, null);
    // `lengths[i][j]` is the longest shared run of the first `i` groups of
    // one and the first `j` of the other. It is read back from the end,
    // giving up a group of the second side first when either would do.
    for (groups1, 0..) |g1, i| {
        for (groups2, 0..) |g2, j| {
            const both = try commonGroup(a, g1, g2);
            common[(i + 1) * cols + (j + 1)] = both;
            lengths[(i + 1) * cols + (j + 1)] = if (both != null)
                lengths[i * cols + j] + 1
            else
                @max(lengths[i * cols + (j + 1)], lengths[(i + 1) * cols + j]);
        }
    }
    var shared: std.ArrayList([]const Link) = .empty;
    {
        var i = groups1.len;
        var j = groups2.len;
        while (i > 0 and j > 0) {
            if (common[i * cols + j]) |group| {
                try shared.insert(a, 0, group);
                i -= 1;
                j -= 1;
            } else if (lengths[i * cols + (j - 1)] >= lengths[(i - 1) * cols + j]) {
                j -= 1;
            } else {
                i -= 1;
            }
        }
    }
    // Before each shared parent comes what either side has ahead of the
    // first of its parents that covers the shared one.
    var at1: usize = 0;
    var at2: usize = 0;
    var shared_index: usize = 0;
    while (true) {
        const next: ?[]const Link = if (shared_index < shared.items.len) shared.items[shared_index] else null;
        var until1 = groups1.len;
        var until2 = groups2.len;
        if (next) |group| {
            until1 = at1;
            while (until1 < groups1.len and !try parentsCover(a, groups1[until1], group)) until1 += 1;
            until2 = at2;
            while (until2 < groups2.len and !try parentsCover(a, groups2[until2], group)) until2 += 1;
        }
        const part1 = try flatten(a, groups1[at1..until1]);
        const part2 = try flatten(a, groups2[at2..until2]);
        if (part1.len != 0 or part2.len != 0) {
            var alternatives: std.ArrayList([]const Link) = .empty;
            if (part2.len == 0) {
                try alternatives.append(a, part1);
            } else if (part1.len == 0) {
                try alternatives.append(a, part2);
            } else {
                try alternatives.append(a, try joinLinks(a, part1, part2));
                try alternatives.append(a, try joinLinks(a, part2, part1));
            }
            try sets.append(a, alternatives.items);
        }
        const group = next orelse break;
        const single = try a.alloc([]const Link, 1);
        single[0] = group;
        try sets.append(a, single);
        at1 = @min(until1 + 1, groups1.len);
        at2 = @min(until2 + 1, groups2.len);
        shared_index += 1;
    }
    {
        var index = tail_sets.items.len;
        while (index > 0) {
            index -= 1;
            try sets.append(a, tail_sets.items[index]);
        }
    }

    // Every combination, the first set varying fastest.
    var out: std.ArrayList([]const Piece) = .empty;
    const choice = try a.alloc(usize, sets.items.len);
    @memset(choice, 0);
    while (true) {
        var components: std.ArrayList(Piece) = .empty;
        for (leading) |combinator| try components.append(a, .{ .combinator = combinator });
        for (sets.items, 0..) |alternatives, index| {
            try components.appendSlice(a, try linksToPieces(a, alternatives[choice[index]]));
        }
        try out.append(a, components.items);

        var position: usize = 0;
        while (position < sets.items.len) : (position += 1) {
            choice[position] += 1;
            if (choice[position] < sets.items[position].len) break;
            choice[position] = 0;
        }
        if (position == sets.items.len) break;
    }
    return out.items;
}

fn flatten(a: Allocator, groups: []const []const Link) Error![]const Link {
    var out: std.ArrayList(Link) = .empty;
    for (groups) |group| try out.appendSlice(a, group);
    return out.items;
}

fn joinLinks(a: Allocator, x: []const Link, y: []const Link) Error![]const Link {
    const out = try a.alloc(Link, x.len + y.len);
    @memcpy(out[0..x.len], x);
    @memcpy(out[x.len..], y);
    return out;
}

/// Put together one choice of every compound's results.
fn weaveChoice(a: Allocator, pieces: []const Piece, options: []const ?[]const Made, choice: []const usize) Error![]const []const Piece {
    var prefixes: std.ArrayList([]const Piece) = .empty;
    try prefixes.append(a, &.{});

    for (pieces, 0..) |piece, index| {
        var next: std.ArrayList([]const Piece) = .empty;
        if (piece == .combinator) {
            // A combinator an extender brought along stands; the
            // descendant combinator gives way to it, another one clashes.
            for (prefixes.items) |prefix| {
                if (prefix.len != 0 and prefix[prefix.len - 1] == .combinator) {
                    const brought = prefix[prefix.len - 1].combinator;
                    if (piece.combinator == .descendant or piece.combinator == brought) {
                        try next.append(a, prefix);
                    } else if (index == 0) {
                        try next.append(a, try concat(a, prefix, pieces[index .. index + 1]));
                    }
                    continue;
                }
                try next.append(a, try concat(a, prefix, pieces[index .. index + 1]));
            }
            prefixes = next;
            if (prefixes.items.len == 0) break;
            continue;
        }
        const chosen: []const Piece = if (options[index]) |list| list[choice[index]].pieces else pieces[index .. index + 1];

        // The parents are everything before the compound that takes this
        // one's place.
        var last_compound = chosen.len;
        while (last_compound > 0 and chosen[last_compound - 1] == .combinator) last_compound -= 1;
        if (last_compound <= 1) {
            for (prefixes.items) |prefix| try next.append(a, try concat(a, prefix, chosen));
        } else {
            const parents = chosen[0 .. last_compound - 1];
            const rest = chosen[last_compound - 1 ..];
            for (prefixes.items) |prefix| {
                if (prefix.len == 0) {
                    try next.append(a, chosen);
                    continue;
                }
                const woven = try weavePrefixes(a, prefix, parents);
                for (woven) |w| try next.append(a, try concat(a, w, rest));
            }
        }
        prefixes = next;
        if (prefixes.items.len == 0) break;
    }
    return prefixes.items;
}

fn concat(a: Allocator, x: []const Piece, y: []const Piece) Error![]const Piece {
    const out = try a.alloc(Piece, x.len + y.len);
    @memcpy(out[0..x.len], x);
    @memcpy(out[x.len..], y);
    return out;
}

// ----------------------------------------------------------------------
// Trimming
// ----------------------------------------------------------------------

/// Drop what another selector of the list makes redundant. Going from the
/// last selector to the first, a generated selector goes when one before
/// it, or one after it that stayed, covers it and is at least as specific
/// as the extenders it came from. A written selector goes only when the
/// same selector, written the same way, comes before it (`.b.c` stays
/// beside `.c.b`). A long list is not trimmed at all.
fn trim(a: Allocator, items: []Item) Error![]Item {
    // The official CLI leaves a list of more than a hundred selectors as
    // it is.
    if (items.len > 100) return items;
    const specs = try a.alloc(Specificity, items.len);
    for (items, 0..) |*item, index| specs[index] = spec_mod.complexSpecificity(&item.complex);
    const kept = try a.alloc(bool, items.len);
    @memset(kept, false);

    var index = items.len;
    while (index > 0) {
        index -= 1;
        const item = &items[index];
        const source = sourceSpec(item.pieces);
        var covered = false;
        if (item.original) {
            for (items[0..index]) |*other| {
                if (other.original and sameAsWritten(&other.complex, &item.complex)) {
                    // The one that stays is written where this one was
                    // written: on a line of its own or not.
                    other.complex.leading_separator_has_newline = item.complex.leading_separator_has_newline;
                    covered = true;
                    break;
                }
            }
        } else {
            for (items, 0..) |*other, other_index| {
                if (other_index == index) continue;
                if (other_index > index and !kept[other_index]) continue;
                if (!spec_mod.specificityGte(specs[other_index], source)) continue;
                if (selector_mod.complexIsSuperSelector(&other.complex, &item.complex)) {
                    covered = true;
                    break;
                }
            }
        }
        kept[index] = !covered;
    }

    var out: std.ArrayList(Item) = .empty;
    for (items, 0..) |item, i| {
        if (kept[i]) try out.append(a, item);
    }
    return out.items;
}

// ----------------------------------------------------------------------
// Small helpers
// ----------------------------------------------------------------------

fn holdsAll(simples: []const SimpleSelector, wanted: []const SimpleSelector) bool {
    for (wanted) |want| {
        var found = false;
        for (simples) |simple| {
            if (spec_mod.simpleSelectorEql(simple, want)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// The same simple selectors and combinators in the same order.
fn sameAsWritten(x: *const ComplexSelector, y: *const ComplexSelector) bool {
    if (x.components.items.len != y.components.items.len) return false;
    for (x.components.items, y.components.items) |cx, cy| {
        switch (cx) {
            .combinator => |combinator| if (cy != .combinator or cy.combinator != combinator) return false,
            .compound => |compound| {
                if (cy != .compound) return false;
                const other = cy.compound.simple_selectors.items;
                if (compound.simple_selectors.items.len != other.len) return false;
                for (compound.simple_selectors.items, other) |sx, sy| {
                    if (!spec_mod.simpleSelectorEql(sx, sy)) return false;
                }
            },
        }
    }
    return true;
}

fn pseudoSelectorOf(simple: SimpleSelector) ?*SelectorList {
    return switch (simple) {
        .pseudo_class => |p| p.selector,
        .pseudo_element => |p| p.selector,
        else => null,
    };
}

fn complexHoldsSimple(complex: *const ComplexSelector, target: SimpleSelector) bool {
    for (complex.components.items) |*component| {
        if (component.* != .compound) continue;
        for (component.compound.simple_selectors.items) |simple| {
            if (spec_mod.simpleSelectorEql(simple, target)) return true;
            const inner = pseudoSelectorOf(simple) orelse continue;
            for (inner.selectors.items) |*inner_complex| {
                if (complexHoldsSimple(inner_complex, target)) return true;
            }
        }
    }
    return false;
}

fn compoundCount(complex: *const ComplexSelector) usize {
    var count: usize = 0;
    for (complex.components.items) |component| {
        if (component == .compound) count += 1;
    }
    return count;
}

/// The pseudo selector with a selector argument that is all of `complex`.
fn onlyPseudoWithSelector(complex: *const ComplexSelector) ?selector_mod.PseudoSelector {
    if (complex.components.items.len != 1 or complex.components.items[0] != .compound) return null;
    const simples = complex.components.items[0].compound.simple_selectors.items;
    if (simples.len != 1) return null;
    const pseudo = switch (simples[0]) {
        .pseudo_class => |p| p,
        .pseudo_element => |p| p,
        else => return null,
    };
    if (pseudo.selector == null) return null;
    return pseudo;
}

fn optionalTextEql(x: ?[]const u8, y: ?[]const u8) bool {
    if (x == null or y == null) return x == null and y == null;
    return std.mem.eql(u8, x.?, y.?);
}

fn pseudoWithSelector(a: Allocator, simple: SimpleSelector, complexes: []const ComplexSelector) Error!SimpleSelector {
    const list = try a.create(SelectorList);
    list.* = SelectorList.init(a);
    try list.selectors.appendSlice(a, complexes);
    return switch (simple) {
        .pseudo_class => |p| .{ .pseudo_class = .{ .name = p.name, .argument = p.argument, .selector = list } },
        .pseudo_element => |p| .{ .pseudo_element = .{ .name = p.name, .argument = p.argument, .selector = list } },
        else => unreachable,
    };
}

/// Text that is the same for simple selectors that are the same.
fn simpleKey(a: Allocator, simple: SimpleSelector) Error![]const u8 {
    return switch (simple) {
        .class => |name| std.fmt.allocPrint(a, ".{s}", .{name}),
        .id => |name| std.fmt.allocPrint(a, "#{s}", .{name}),
        .placeholder => |name| std.fmt.allocPrint(a, "%{s}", .{name}),
        .type_selector => |name| name,
        .universal => "*",
        .parent => "&",
        else => {
            var compound = CompoundSelector.init(a);
            try compound.simple_selectors.append(a, simple);
            return selector_mod.compoundSelectorToCss(a, &compound);
        },
    };
}
