const std = @import("std");

// ============================================================================
// Types
// ============================================================================

pub const AttributeOp = enum {
    eq,
    tilde_eq,
    pipe_eq,
    caret_eq,
    dollar_eq,
    star_eq,

    pub fn toCss(self: AttributeOp) []const u8 {
        return switch (self) {
            .eq => "=",
            .tilde_eq => "~=",
            .pipe_eq => "|=",
            .caret_eq => "^=",
            .dollar_eq => "$=",
            .star_eq => "*=",
        };
    }
};

pub const AttributeSelector = struct {
    name: []const u8,
    op: ?AttributeOp,
    value: ?[]const u8,
    modifier: ?u8,
};

pub const PseudoSelector = struct {
    name: []const u8,
    argument: ?[]const u8,
    selector: ?*SelectorList,
};

pub const SimpleSelector = union(enum) {
    type_selector: []const u8,
    class: []const u8,
    id: []const u8,
    attribute: AttributeSelector,
    pseudo_class: PseudoSelector,
    pseudo_element: PseudoSelector,
    placeholder: []const u8,
    parent: void,
    universal: void,
};

pub const Combinator = enum {
    descendant,
    child,
    next_sibling,
    general_sibling,
    column,

    pub fn toCss(self: Combinator) []const u8 {
        return switch (self) {
            .descendant => " ",
            .child => " > ",
            .next_sibling => " + ",
            .general_sibling => " ~ ",
            .column => " || ",
        };
    }
};

pub const CompoundSelector = struct {
    simple_selectors: std.ArrayList(SimpleSelector),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CompoundSelector {
        return .{
            .simple_selectors = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CompoundSelector) void {
        for (self.simple_selectors.items) |*ss| {
            deinitSimpleSelector(ss, self.allocator);
        }
        self.simple_selectors.deinit(self.allocator);
    }

    pub fn clone(self: *const CompoundSelector, allocator: std.mem.Allocator) !CompoundSelector {
        var result = CompoundSelector.init(allocator);
        // OOM mid-loop must release every selector that was already cloned
        // into `result`, otherwise we leak the partial set.
        errdefer result.deinit();
        for (self.simple_selectors.items) |ss| {
            const cloned = try cloneSimpleSelector(ss, allocator);
            errdefer deinitSimpleSelector(@constCast(&cloned), allocator);
            try result.simple_selectors.append(allocator, cloned);
        }
        return result;
    }
};

pub const ComplexSelectorComponent = union(enum) {
    compound: CompoundSelector,
    combinator: Combinator,
};

pub const ComplexSelector = struct {
    components: std.ArrayList(ComplexSelectorComponent),
    allocator: std.mem.Allocator,
    /// True when the comma separator before this selector had a newline in the
    /// original source. `toCss()` uses this to preserve selector-list wrapping.
    leading_separator_has_newline: bool = false,
    /// Lazily-populated CSS text cache.  Populated on first call to
    /// `getCachedCss()` and freed in `deinit()`.  Selectors are immutable
    /// after creation, so the cache never becomes stale.
    cached_css: ?[]const u8 = null,
    /// Trimmed view of `cached_css` for whitespace-insensitive comparisons.
    /// This always points inside `cached_css` and doesn't own memory.
    cached_css_trimmed: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) ComplexSelector {
        return .{
            .components = .empty,
            .allocator = allocator,
            .leading_separator_has_newline = false,
        };
    }

    pub fn deinit(self: *ComplexSelector) void {
        if (self.cached_css) |css| {
            self.allocator.free(css);
        }
        for (self.components.items) |*comp| {
            switch (comp.*) {
                .compound => |*c| c.deinit(),
                .combinator => {},
            }
        }
        self.components.deinit(self.allocator);
    }

    /// Populate the CSS cache if not yet set.  Must be called through a
    /// mutable pointer (i.e. on a selector that lives in an ArrayList, not
    /// on a for-loop value copy).  The cached string is freed in `deinit()`.
    pub fn ensureCachedCss(self: *ComplexSelector) std.mem.Allocator.Error!void {
        if (self.cached_css == null) {
            const css = try complexSelectorToCss(self.allocator, self);
            self.cached_css = css;
            self.cached_css_trimmed = std.mem.trim(u8, css, " \t\n\r");
        }
    }

    pub fn clone(self: *const ComplexSelector, allocator: std.mem.Allocator) !ComplexSelector {
        var result = ComplexSelector.init(allocator);
        // OOM mid-loop must release every component already cloned into
        // `result` (compounds carry their own owned memory).
        errdefer result.deinit();
        result.leading_separator_has_newline = self.leading_separator_has_newline;
        for (self.components.items) |comp| {
            switch (comp) {
                .compound => |c| {
                    var cloned = try c.clone(allocator);
                    errdefer cloned.deinit();
                    try result.components.append(allocator, .{ .compound = cloned });
                },
                .combinator => |comb| {
                    try result.components.append(allocator, .{ .combinator = comb });
                },
            }
        }
        return result;
    }
};

pub const SelectorList = struct {
    selectors: std.ArrayList(ComplexSelector),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SelectorList {
        return .{
            .selectors = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SelectorList) void {
        for (self.selectors.items) |*sel| {
            sel.deinit();
        }
        self.selectors.deinit(self.allocator);
    }

    pub fn clone(self: *const SelectorList, allocator: std.mem.Allocator) !SelectorList {
        var result = SelectorList.init(allocator);
        // OOM mid-loop must release every complex selector that has
        // already been deep-cloned into `result`.
        errdefer result.deinit();
        for (self.selectors.items) |sel| {
            var cloned = try sel.clone(allocator);
            errdefer cloned.deinit();
            try result.selectors.append(allocator, cloned);
        }
        return result;
    }
};

// ============================================================================
// Helper functions for deep clone / deinit of SimpleSelector
// ============================================================================

pub fn deinitSimpleSelector(ss: *SimpleSelector, allocator: std.mem.Allocator) void {
    switch (ss.*) {
        .type_selector => |name| allocator.free(name),
        .class => |name| allocator.free(name),
        .id => |name| allocator.free(name),
        .placeholder => |name| allocator.free(name),
        .attribute => |attr| {
            allocator.free(attr.name);
            if (attr.value) |v| allocator.free(v);
        },
        .pseudo_class, .pseudo_element => |*ps| {
            allocator.free(ps.name);
            if (ps.argument) |arg| allocator.free(arg);
            if (ps.selector) |sel_ptr| {
                sel_ptr.deinit();
                allocator.destroy(sel_ptr);
            }
        },
        .parent, .universal => {},
    }
}

/// Build a `.class` `SimpleSelector` from a borrowed name slice. The
/// returned selector owns the duplicated name so callers can embed it in a
/// `CompoundSelector` whose `deinit` will free the class string.
pub fn classSimpleFromName(allocator: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!SimpleSelector {
    return .{ .class = try allocator.dupe(u8, name) };
}

pub fn cloneSimpleSelector(ss: SimpleSelector, allocator: std.mem.Allocator) std.mem.Allocator.Error!SimpleSelector {
    return switch (ss) {
        .type_selector => |name| .{ .type_selector = try allocator.dupe(u8, name) },
        .class => |name| .{ .class = try allocator.dupe(u8, name) },
        .id => |name| .{ .id = try allocator.dupe(u8, name) },
        .placeholder => |name| .{ .placeholder = try allocator.dupe(u8, name) },
        .attribute => |attr| blk: {
            // Allocate name first; if any later step fails we must free the
            // partial allocation rather than leak it.
            const name = try allocator.dupe(u8, attr.name);
            errdefer allocator.free(name);
            const value = if (attr.value) |v| try allocator.dupe(u8, v) else null;
            // No more fallible steps after this point.
            break :blk .{ .attribute = .{
                .name = name,
                .op = attr.op,
                .value = value,
                .modifier = attr.modifier,
            } };
        },
        .pseudo_class => |ps| .{ .pseudo_class = try clonePseudoSelector(ps, allocator) },
        .pseudo_element => |ps| .{ .pseudo_element = try clonePseudoSelector(ps, allocator) },
        .parent => .{ .parent = {} },
        .universal => .{ .universal = {} },
    };
}

fn clonePseudoSelector(ps: PseudoSelector, allocator: std.mem.Allocator) std.mem.Allocator.Error!PseudoSelector {
    const name = try allocator.dupe(u8, ps.name);
    errdefer allocator.free(name);

    const argument: ?[]u8 = if (ps.argument) |arg| try allocator.dupe(u8, arg) else null;
    errdefer if (argument) |a| allocator.free(a);

    var inner_ptr: ?*SelectorList = null;
    if (ps.selector) |sel_ptr| {
        const new_ptr = try allocator.create(SelectorList);
        errdefer allocator.destroy(new_ptr);
        new_ptr.* = try sel_ptr.clone(allocator);
        inner_ptr = new_ptr;
    }

    return PseudoSelector{
        .name = name,
        .argument = argument,
        .selector = inner_ptr,
    };
}

// ============================================================================
// Parser
// ============================================================================

const ParseError = error{
    InvalidSelector,
    UnexpectedEnd,
    OutOfMemory,
};

pub const ResolveParentError = std.mem.Allocator.Error || error{
    InvalidParentSelector,
};

inline fn dupeForParse(allocator: std.mem.Allocator, value: []const u8) ParseError![]const u8 {
    return allocator.dupe(u8, value) catch return ParseError.OutOfMemory;
}

inline fn allocSelectorListForParse(allocator: std.mem.Allocator, value: SelectorList) ParseError!*SelectorList {
    const ptr = allocator.create(SelectorList) catch return ParseError.OutOfMemory;
    ptr.* = value;
    return ptr;
}

/// Parse a selector-list source string into a `SelectorList` AST.
/// Rejects syntactically invalid selectors with `ParseError.InvalidSelector`.
/// Returned value is owned by the caller; free via `SelectorList.deinit`.
pub fn parse(allocator: std.mem.Allocator, input: []const u8) ParseError!SelectorList {
    var list = SelectorList.init(allocator);
    errdefer list.deinit();

    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return ParseError.InvalidSelector;
    if (hasInvalidIdentifierStart(trimmed)) return ParseError.InvalidSelector;

    const SelectorListPart = struct {
        text: []const u8,
        leading_separator_has_newline: bool,
    };

    // Split by top-level commas while preserving whether the separator before
    // each selector contained a newline.
    var parts: std.ArrayList(SelectorListPart) = .empty;
    defer parts.deinit(allocator);
    const max_parts = std.mem.count(u8, trimmed, ",") + 1;
    parts.ensureTotalCapacity(allocator, max_parts) catch return ParseError.OutOfMemory;

    var start: usize = 0;
    var paren_depth: u32 = 0;
    var bracket_depth: u32 = 0;
    var leading_separator_has_newline = false;
    for (trimmed, 0..) |ch, i| {
        switch (ch) {
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            ',' => {
                if (paren_depth == 0 and bracket_depth == 0) {
                    parts.append(allocator, .{
                        .text = trimmed[start..i],
                        .leading_separator_has_newline = leading_separator_has_newline,
                    }) catch return ParseError.OutOfMemory;
                    leading_separator_has_newline = false;
                    var j = i + 1;
                    while (j < trimmed.len and isWhitespace(trimmed[j])) : (j += 1) {
                        if (trimmed[j] == '\n' or trimmed[j] == '\r') {
                            leading_separator_has_newline = true;
                        }
                    }
                    start = i + 1;
                }
            },
            else => {},
        }
    }
    parts.append(allocator, .{
        .text = trimmed[start..],
        .leading_separator_has_newline = leading_separator_has_newline,
    }) catch return ParseError.OutOfMemory;

    for (parts.items) |part| {
        const part_trimmed = std.mem.trim(u8, part.text, " \t\r\n");
        if (part_trimmed.len == 0) continue;
        var complex = try parseComplexSelector(allocator, part.text);
        complex.leading_separator_has_newline = part.leading_separator_has_newline;
        list.selectors.append(allocator, complex) catch return ParseError.OutOfMemory;
    }

    if (list.selectors.items.len == 0) return ParseError.InvalidSelector;

    return list;
}

fn parseComplexSelector(allocator: std.mem.Allocator, input: []const u8) ParseError!ComplexSelector {
    var complex = ComplexSelector.init(allocator);
    errdefer complex.deinit();

    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return ParseError.InvalidSelector;

    var pos: usize = 0;
    while (pos < trimmed.len) {
        // Skip whitespace
        const ws_start = pos;
        while (pos < trimmed.len and isWhitespace(trimmed[pos])) {
            pos += 1;
        }
        if (pos >= trimmed.len) break;

        // Check for combinator characters
        var explicit_combinator: ?Combinator = null;
        if (trimmed[pos] == '>') {
            explicit_combinator = .child;
            pos += 1;
        } else if (trimmed[pos] == '+') {
            explicit_combinator = .next_sibling;
            pos += 1;
        } else if (trimmed[pos] == '~') {
            explicit_combinator = .general_sibling;
            pos += 1;
        } else if (pos + 1 < trimmed.len and trimmed[pos] == '|' and trimmed[pos + 1] == '|') {
            explicit_combinator = .column;
            pos += 2;
        }

        if (explicit_combinator) |comb| {
            // Leading combinator (at start) or between compounds
            complex.components.append(allocator, .{ .combinator = comb }) catch return ParseError.OutOfMemory;
            // Skip whitespace after combinator
            while (pos < trimmed.len and isWhitespace(trimmed[pos])) {
                pos += 1;
            }
            //Trailing combinator (at end) -- keep it, no compound follows
            if (pos >= trimmed.len) break;
            // Check for consecutive combinators (e.g., "> >")
            continue;
        } else if (complex.components.items.len > 0) {
            // Implicit descendant combinator between compounds
            const had_whitespace = pos > ws_start;
            if (had_whitespace) {
                complex.components.append(allocator, .{ .combinator = .descendant }) catch return ParseError.OutOfMemory;
            }
        }

        // Parse compound selector
        const compound = try parseCompoundSelector(allocator, trimmed, &pos);
        complex.components.append(allocator, .{ .compound = compound }) catch return ParseError.OutOfMemory;
    }

    return complex;
}

fn parseCompoundSelector(allocator: std.mem.Allocator, input: []const u8, pos: *usize) ParseError!CompoundSelector {
    var compound = CompoundSelector.init(allocator);
    errdefer compound.deinit();

    // Skip whitespace
    while (pos.* < input.len and isWhitespace(input[pos.*])) {
        pos.* += 1;
    }

    while (pos.* < input.len) {
        const ch = input[pos.*];

        if (isWhitespace(ch) or ch == ',' or ch == '>' or ch == '+' or ch == '~') break;

        // || combinator
        if (ch == '|' and pos.* + 1 < input.len and input[pos.* + 1] == '|') break;

        // Empty namespace prefix: |type or |*
        if (ch == '|' and pos.* + 1 < input.len and input[pos.* + 1] != '|') {
            pos.* += 1; // skip '|'
            if (pos.* < input.len and input[pos.*] == '*') {
                // |* = universal with empty namespace
                pos.* += 1;
                const owned = try dupeForParse(allocator, "|*");
                compound.simple_selectors.append(allocator, .{ .type_selector = owned }) catch return ParseError.OutOfMemory;
            } else {
                const name = readIdentifier(input, pos);
                if (name.len == 0) return ParseError.InvalidSelector;
                const normalized_name = try normalizeIdentifierEscapesForParse(allocator, name);
                defer allocator.free(normalized_name);
                const full = std.mem.concat(allocator, u8, &.{ "|", normalized_name }) catch return ParseError.OutOfMemory;
                compound.simple_selectors.append(allocator, .{ .type_selector = full }) catch return ParseError.OutOfMemory;
            }
            continue;
        }

        if (ch == '.') {
            // Class selector
            pos.* += 1;
            const name = readIdentifier(input, pos);
            if (name.len == 0) return ParseError.InvalidSelector;
            const owned_name = try normalizeIdentifierEscapesForParse(allocator, name);
            compound.simple_selectors.append(allocator, .{ .class = owned_name }) catch return ParseError.OutOfMemory;
        } else if (ch == '#') {
            // ID selector
            pos.* += 1;
            const name = readIdentifier(input, pos);
            if (name.len == 0) return ParseError.InvalidSelector;
            const owned_name = try normalizeIdentifierEscapesForParse(allocator, name);
            compound.simple_selectors.append(allocator, .{ .id = owned_name }) catch return ParseError.OutOfMemory;
        } else if (ch == '[') {
            // Attribute selector
            const attr = try parseAttributeSelector(allocator, input, pos);
            compound.simple_selectors.append(allocator, .{ .attribute = attr }) catch return ParseError.OutOfMemory;
        } else if (ch == ':') {
            // Pseudo-class or pseudo-element
            pos.* += 1;
            var is_element = false;
            if (pos.* < input.len and input[pos.*] == ':') {
                is_element = true;
                pos.* += 1;
            }
            const name = readIdentifier(input, pos);
            if (name.len == 0) return ParseError.InvalidSelector;
            const owned_name = try normalizeIdentifierEscapesForParse(allocator, name);

            var ps = PseudoSelector{
                .name = owned_name,
                .argument = null,
                .selector = null,
            };

            // Check for parenthesized argument
            if (pos.* < input.len and input[pos.*] == '(') {
                pos.* += 1;
                const arg_start = pos.*;
                var depth: u32 = 1;
                var bracket_depth: u32 = 0;
                var in_string: u8 = 0;
                while (pos.* < input.len and depth > 0) {
                    const arg_ch = input[pos.*];
                    if (in_string != 0) {
                        if (arg_ch == '\\' and pos.* + 1 < input.len) {
                            pos.* += 2;
                            continue;
                        }
                        if (arg_ch == in_string) in_string = 0;
                        pos.* += 1;
                        continue;
                    }
                    switch (arg_ch) {
                        '"', '\'' => in_string = arg_ch,
                        '[' => bracket_depth += 1,
                        ']' => {
                            if (bracket_depth == 0) return ParseError.InvalidSelector;
                            bracket_depth -= 1;
                        },
                        '(' => depth += 1,
                        ')' => {
                            if (bracket_depth == 0) depth -= 1;
                        },
                        else => {},
                    }
                    if (depth > 0) pos.* += 1;
                }
                if (depth != 0 or bracket_depth != 0 or in_string != 0) return ParseError.InvalidSelector;
                const arg = std.mem.trim(u8, input[arg_start..pos.*], " \t\r\n");
                if (pos.* < input.len and input[pos.*] == ')') pos.* += 1;

                // Check if this is a selector-taking pseudo
                if (isNthWithOfPseudo(name)) {
                    //:nth-child(An+B of selector-list) -- split on " of "
                    if (splitNthOf(arg)) |parts| {
                        const compact = compactAnB(allocator, parts.anb) catch
                            return ParseError.OutOfMemory;
                        ps.argument = compact;
                        const inner = parse(allocator, parts.selector) catch {
                            // fallback: store whole arg as argument
                            allocator.free(compact);
                            ps.argument = try dupeForParse(allocator, arg);
                            if (is_element) {
                                compound.simple_selectors.append(allocator, .{ .pseudo_element = ps }) catch return ParseError.OutOfMemory;
                            } else {
                                compound.simple_selectors.append(allocator, .{ .pseudo_class = ps }) catch return ParseError.OutOfMemory;
                            }
                            continue;
                        };
                        const sel_ptr = try allocSelectorListForParse(allocator, inner);
                        ps.selector = sel_ptr;
                    } else {
                        //Plain :nth-child(An+B) -- compact and store as argument
                        const compact = compactAnB(allocator, arg) catch
                            return ParseError.OutOfMemory;
                        ps.argument = compact;
                    }
                } else if (isSelectorPseudo(name)) {
                    const inner = parse(allocator, arg) catch return ParseError.InvalidSelector;
                    const sel_ptr = try allocSelectorListForParse(allocator, inner);
                    ps.selector = sel_ptr;
                } else {
                    ps.argument = try dupeForParse(allocator, arg);
                }
            }

            if (is_element) {
                compound.simple_selectors.append(allocator, .{ .pseudo_element = ps }) catch return ParseError.OutOfMemory;
            } else {
                compound.simple_selectors.append(allocator, .{ .pseudo_class = ps }) catch return ParseError.OutOfMemory;
            }
        } else if (ch == '%') {
            // Placeholder selector
            pos.* += 1;
            const name = readIdentifier(input, pos);
            if (name.len == 0) return ParseError.InvalidSelector;
            const owned_name = try normalizeIdentifierEscapesForParse(allocator, name);
            compound.simple_selectors.append(allocator, .{ .placeholder = owned_name }) catch return ParseError.OutOfMemory;
        } else if (ch == '&') {
            if (compound.simple_selectors.items.len > 0) return ParseError.InvalidSelector;
            // Parent selector
            pos.* += 1;
            compound.simple_selectors.append(allocator, .{ .parent = {} }) catch return ParseError.OutOfMemory;
        } else if (ch == '*') {
            pos.* += 1;
            // Check for namespace: *|type or *|*
            if (pos.* < input.len and input[pos.*] == '|' and (pos.* + 1 >= input.len or input[pos.* + 1] != '|')) {
                pos.* += 1; // skip '|'
                if (pos.* < input.len and input[pos.*] == '*') {
                    // *|* = universal with any namespace
                    pos.* += 1;
                    const owned = try dupeForParse(allocator, "*|*");
                    compound.simple_selectors.append(allocator, .{ .type_selector = owned }) catch return ParseError.OutOfMemory;
                } else {
                    const name = readIdentifier(input, pos);
                    if (name.len == 0) {
                        // Just *| with nothing after - treat as universal
                        compound.simple_selectors.append(allocator, .{ .universal = {} }) catch return ParseError.OutOfMemory;
                    } else {
                        const full = std.mem.concat(allocator, u8, &.{ "*|", name }) catch return ParseError.OutOfMemory;
                        compound.simple_selectors.append(allocator, .{ .type_selector = full }) catch return ParseError.OutOfMemory;
                    }
                }
            } else {
                // Plain universal selector
                compound.simple_selectors.append(allocator, .{ .universal = {} }) catch return ParseError.OutOfMemory;
            }
        } else if (isIdentChar(ch) or ch == '-' or ch == '\\') {
            // Type selector, possibly with namespace: ns|type or ns|*
            const name = readIdentifier(input, pos);
            if (name.len == 0) return ParseError.InvalidSelector;
            if (pos.* < input.len and input[pos.*] == '|' and (pos.* + 1 >= input.len or input[pos.* + 1] != '|')) {
                // Namespace prefix: ns|...
                pos.* += 1; // skip '|'
                if (pos.* < input.len and input[pos.*] == '*') {
                    // ns|* = universal with explicit namespace
                    pos.* += 1;
                    const normalized_ns = try normalizeIdentifierEscapesForParse(allocator, name);
                    defer allocator.free(normalized_ns);
                    const full = std.mem.concat(allocator, u8, &.{ normalized_ns, "|*" }) catch return ParseError.OutOfMemory;
                    compound.simple_selectors.append(allocator, .{ .type_selector = full }) catch return ParseError.OutOfMemory;
                } else {
                    const type_name = readIdentifier(input, pos);
                    if (type_name.len == 0) return ParseError.InvalidSelector;
                    const normalized_ns = try normalizeIdentifierEscapesForParse(allocator, name);
                    defer allocator.free(normalized_ns);
                    const normalized_type = try normalizeIdentifierEscapesForParse(allocator, type_name);
                    defer allocator.free(normalized_type);
                    const full = std.mem.concat(allocator, u8, &.{ normalized_ns, "|", normalized_type }) catch return ParseError.OutOfMemory;
                    compound.simple_selectors.append(allocator, .{ .type_selector = full }) catch return ParseError.OutOfMemory;
                }
            } else {
                const owned_name = try normalizeIdentifierEscapesForParse(allocator, name);
                compound.simple_selectors.append(allocator, .{ .type_selector = owned_name }) catch return ParseError.OutOfMemory;
            }
        } else {
            break;
        }
    }

    if (compound.simple_selectors.items.len == 0) {
        return ParseError.InvalidSelector;
    }

    return compound;
}

fn parseAttributeSelector(allocator: std.mem.Allocator, input: []const u8, pos: *usize) ParseError!AttributeSelector {
    // Skip '['
    pos.* += 1;

    // Skip whitespace
    while (pos.* < input.len and isWhitespace(input[pos.*])) pos.* += 1;

    // Read attribute name (with optional namespace prefix: ns|attr, *|attr, |attr)
    const name_start = pos.*;
    // Handle *| or | prefix (universal/no namespace)
    if (pos.* < input.len and input[pos.*] == '*' and pos.* + 1 < input.len and input[pos.* + 1] == '|') {
        pos.* += 2; // skip *|
        _ = readIdentifier(input, pos);
    } else if (pos.* < input.len and input[pos.*] == '|' and pos.* + 1 < input.len and input[pos.* + 1] != '=') {
        pos.* += 1; // skip | (no namespace)
        _ = readIdentifier(input, pos);
    } else {
        _ = readIdentifier(input, pos);
        // Check for namespace separator: ns|attr (not ns|= which is pipe_eq operator)
        if (pos.* < input.len and input[pos.*] == '|' and
            (pos.* + 1 >= input.len or input[pos.* + 1] != '='))
        {
            pos.* += 1; // skip |
            _ = readIdentifier(input, pos);
        }
    }
    const name = input[name_start..pos.*];
    if (name.len == 0) return ParseError.InvalidSelector;
    const owned_name = allocator.dupe(u8, name) catch return ParseError.OutOfMemory;

    // Skip whitespace
    while (pos.* < input.len and isWhitespace(input[pos.*])) pos.* += 1;

    // Check for end
    if (pos.* >= input.len) return ParseError.UnexpectedEnd;
    if (input[pos.*] == ']') {
        pos.* += 1;
        return .{
            .name = owned_name,
            .op = null,
            .value = null,
            .modifier = null,
        };
    }

    // Parse operator
    const op = try parseAttributeOp(input, pos);

    // Skip whitespace
    while (pos.* < input.len and isWhitespace(input[pos.*])) pos.* += 1;

    // Parse value
    if (pos.* >= input.len) return ParseError.UnexpectedEnd;
    // SAFETY: initialized before first read in this scope.
    var value: []const u8 = undefined;
    if (input[pos.*] == '"' or input[pos.*] == '\'') {
        const quote = input[pos.*];
        pos.* += 1;
        const val_start = pos.*;
        while (pos.* < input.len) {
            if (input[pos.*] == '\\' and pos.* + 1 < input.len) {
                pos.* += 2;
                continue;
            }
            if (input[pos.*] == quote) break;
            pos.* += 1;
        }
        value = input[val_start..pos.*];
        if (pos.* < input.len) pos.* += 1; // skip closing quote
    } else {
        const val_start = pos.*;
        while (pos.* < input.len and input[pos.*] != ']' and !isWhitespace(input[pos.*])) pos.* += 1;
        value = input[val_start..pos.*];
    }
    const owned_value = try normalizeAttributeValueEscapesForParse(allocator, value);

    // Skip whitespace
    while (pos.* < input.len and isWhitespace(input[pos.*])) pos.* += 1;

    // Check for modifier (i or s)
    var modifier: ?u8 = null;
    if (pos.* < input.len and (input[pos.*] == 'i' or input[pos.*] == 's' or input[pos.*] == 'I' or input[pos.*] == 'S')) {
        // Check if this is followed by ] or whitespace
        if (pos.* + 1 >= input.len or input[pos.* + 1] == ']' or isWhitespace(input[pos.* + 1])) {
            modifier = std.ascii.toLower(input[pos.*]);
            pos.* += 1;
        }
    }

    // Skip whitespace
    while (pos.* < input.len and isWhitespace(input[pos.*])) pos.* += 1;

    // Skip ']'
    if (pos.* < input.len and input[pos.*] == ']') pos.* += 1;

    return .{
        .name = owned_name,
        .op = op,
        .value = owned_value,
        .modifier = modifier,
    };
}

fn parseAttributeOp(input: []const u8, pos: *usize) ParseError!AttributeOp {
    if (pos.* >= input.len) return ParseError.UnexpectedEnd;
    const ch = input[pos.*];
    if (ch == '=') {
        pos.* += 1;
        return .eq;
    }
    if (pos.* + 1 >= input.len) return ParseError.InvalidSelector;
    if (input[pos.* + 1] != '=') return ParseError.InvalidSelector;
    const result: AttributeOp = switch (ch) {
        '~' => .tilde_eq,
        '|' => .pipe_eq,
        '^' => .caret_eq,
        '$' => .dollar_eq,
        '*' => .star_eq,
        else => return ParseError.InvalidSelector,
    };
    pos.* += 2;
    return result;
}

fn cssEscapeSequenceLen(input: []const u8, start: usize) usize {
    if (start >= input.len or input[start] != '\\' or start + 1 >= input.len) return 0;
    const next = input[start + 1];
    if (next == '\n' or next == '\r') return 0;

    if (std.ascii.isHex(next)) {
        var i = start + 1;
        var hex_count: usize = 0;
        while (i < input.len and hex_count < 6 and std.ascii.isHex(input[i])) : (i += 1) {
            hex_count += 1;
        }
        if (i < input.len and isWhitespace(input[i])) i += 1;
        return i - start;
    }

    return 2;
}

fn appendSelectorHexEscapeForIdentifier(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    code_point: u21,
) ParseError!void {
    try buf.append(allocator, '\\');
    var hex_buf: [6]u8 = undefined;
    const hex_out = std.fmt.bufPrint(&hex_buf, "{x}", .{code_point}) catch |err| {
        std.debug.panic("appendSelectorHexEscapeForIdentifier formatting failed: {s}", .{@errorName(err)});
    };
    try buf.appendSlice(allocator, hex_out);
    try buf.append(allocator, ' ');
}

fn isSelectorEscapeHexOnly(ch: u8) bool {
    return ch == ' ' or ch < 0x20 or ch == 0x7f;
}

fn normalizeAttributeValueEscapesForParse(
    allocator: std.mem.Allocator,
    value: []const u8,
) ParseError![]const u8 {
    if (std.mem.findScalar(u8, value, '\\') == null) return dupeForParse(allocator, value);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var i: usize = 0;
    while (i < value.len) {
        if (value[i] != '\\' or i + 1 >= value.len) {
            try buf.append(allocator, value[i]);
            i += 1;
            continue;
        }

        const next = value[i + 1];
        if (next == '\n' or next == '\r') {
            try buf.append(allocator, value[i]);
            i += 1;
            continue;
        }
        if (next == '\"' or next == '\\') {
            try buf.append(allocator, value[i]);
            try buf.append(allocator, next);
            i += 2;
            continue;
        }
        if (std.ascii.isHex(next)) {
            try buf.append(allocator, value[i]);
            i += 1;
            continue;
        }

        try buf.append(allocator, next);
        i += 2;
    }

    return buf.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
}

fn normalizeIdentifierEscapesForParse(
    allocator: std.mem.Allocator,
    ident: []const u8,
) ParseError![]const u8 {
    if (std.mem.findScalar(u8, ident, '\\') == null) {
        return dupeForParse(allocator, ident);
    }

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var i: usize = 0;
    while (i < ident.len) {
        const esc_len = cssEscapeSequenceLen(ident, i);
        if (esc_len == 0) {
            try buf.append(allocator, ident[i]);
            i += 1;
            continue;
        }

        if (i + 1 < ident.len and std.ascii.isHex(ident[i + 1])) {
            var hex_end = i + 1;
            var hex_count: usize = 0;
            while (hex_end < ident.len and hex_count < 6 and std.ascii.isHex(ident[hex_end])) : (hex_end += 1) {
                hex_count += 1;
            }

            var after_hex = hex_end;
            if (after_hex < ident.len and isWhitespace(ident[after_hex])) after_hex += 1;

            const code_point = std.fmt.parseInt(u21, ident[i + 1 .. hex_end], 16) catch {
                try buf.append(allocator, ident[i]);
                i += 1;
                continue;
            };

            const prev_is_ident = buf.items.len > 0 and isIdentChar(buf.items[buf.items.len - 1]);
            if (code_point < 0x80) {
                const ch: u8 = @intCast(code_point);
                if (isSelectorEscapeHexOnly(ch)) {
                    try appendSelectorHexEscapeForIdentifier(&buf, allocator, code_point);
                } else if (isIdentChar(ch)) {
                    if (prev_is_ident) {
                        try buf.append(allocator, ch);
                    } else {
                        try appendSelectorHexEscapeForIdentifier(&buf, allocator, code_point);
                    }
                } else {
                    try buf.append(allocator, '\\');
                    try buf.append(allocator, ch);
                }
            } else {
                var utf8_buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(code_point, &utf8_buf) catch {
                    try buf.append(allocator, ident[i]);
                    i += 1;
                    continue;
                };
                try buf.appendSlice(allocator, utf8_buf[0..len]);
            }

            i = after_hex;
            continue;
        }

        const next = ident[i + 1];
        if (isIdentChar(next)) {
            const prev_is_ident = buf.items.len > 0 and isIdentChar(buf.items[buf.items.len - 1]);
            if (next == '-' and !prev_is_ident) {
                try buf.append(allocator, '\\');
                try buf.append(allocator, next);
            } else {
                try buf.append(allocator, next);
            }
        } else {
            try buf.append(allocator, '\\');
            try buf.append(allocator, next);
        }
        i += 2;
    }

    return buf.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
}

fn readIdentifier(input: []const u8, pos: *usize) []const u8 {
    const start = pos.*;
    if (pos.* >= input.len) return input[start..start];

    // CSS identifiers must begin with ident-start (or escape), optionally
    // preceded by `-`.
    if (input[pos.*] == '-') {
        pos.* += 1;
        if (pos.* >= input.len) {
            pos.* = start;
            return input[start..start];
        }
        if (input[pos.*] == '-') {
            // `--foo` is valid.
            pos.* += 1;
        } else if (isIdentifierStartChar(input[pos.*])) {
            pos.* += 1;
        } else {
            const esc_len = cssEscapeSequenceLen(input, pos.*);
            if (esc_len != 0) {
                pos.* += esc_len;
            } else {
                pos.* = start;
                return input[start..start];
            }
        }
    } else if (isIdentifierStartChar(input[pos.*])) {
        pos.* += 1;
    } else {
        const esc_len = cssEscapeSequenceLen(input, pos.*);
        if (esc_len != 0) {
            pos.* += esc_len;
        } else {
            return input[start..start];
        }
    }

    while (pos.* < input.len) {
        if (isIdentChar(input[pos.*])) {
            pos.* += 1;
        } else {
            const esc_len = cssEscapeSequenceLen(input, pos.*);
            if (esc_len != 0) {
                pos.* += esc_len;
            } else {
                break;
            }
        }
    }
    return input[start..pos.*];
}

fn isIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch > 127;
}

fn isIdentifierStartChar(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_' or ch > 127;
}

fn isEscapedCharacter(input: []const u8, i: usize) bool {
    return i + 1 < input.len and input[i] == '\\' and input[i + 1] != '\n' and input[i + 1] != '\r';
}

fn isWhitespace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}

/// Skips past a CSS escape sequence starting at `i` (which must point to `\`).
/// Advances `i` past the backslash, any hex digits, and the optional terminator whitespace.
/// Returns the new value of `i` (points to the first character after the escape).
fn skipEscape(input: []const u8, i: usize) usize {
    var pos = i + 1; // skip backslash
    if (pos >= input.len) return pos;
    if (std.ascii.isHex(input[pos])) {
        // Consume up to 6 hex digits
        var hex_count: u32 = 0;
        while (pos < input.len and hex_count < 6 and std.ascii.isHex(input[pos])) : (hex_count += 1) {
            pos += 1;
        }
        // Consume optional single whitespace that terminates the hex escape
        if (pos < input.len and isWhitespace(input[pos])) {
            pos += 1;
        }
    } else {
        // Single-character escape: skip the escaped character
        pos += 1;
    }
    return pos;
}

/// Returns true if selector contains id/class/type tokens whose identifier
/// body starts with a digit (`#2`, `.3`, `1a`), excluding keyframe percentages.
pub fn hasInvalidIdentifierStart(selector: []const u8) bool {
    var i: usize = 0;
    var in_string: u8 = 0;
    var bracket_depth: u32 = 0;
    var paren_depth: u32 = 0;
    var at_compound_start = true;

    while (i < selector.len) : (i += 1) {
        const c = selector[i];

        if (isEscapedCharacter(selector, i)) {
            at_compound_start = false;
            i = skipEscape(selector, i) - 1; // -1 because the for loop will increment
            continue;
        }

        if (in_string != 0) {
            if (c == in_string) in_string = 0;
            continue;
        }

        switch (c) {
            '"', '\'' => {
                in_string = c;
                at_compound_start = false;
                continue;
            },
            '[' => {
                bracket_depth += 1;
                at_compound_start = false;
                continue;
            },
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
                at_compound_start = false;
                continue;
            },
            '(' => {
                paren_depth += 1;
                at_compound_start = false;
                continue;
            },
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
                at_compound_start = false;
                continue;
            },
            else => {},
        }

        if (bracket_depth > 0 or paren_depth > 0) {
            at_compound_start = false;
            continue;
        }

        if (isWhitespace(c)) {
            at_compound_start = true;
            continue;
        }

        if (c == ',' or c == '+' or c == '>' or c == '~') {
            at_compound_start = true;
            continue;
        }

        if (c == '#' or c == '.') {
            const next = if (i + 1 < selector.len) selector[i + 1] else 0;
            if (std.ascii.isDigit(next)) return true;
            if (c == '.') {
                const ok = next == '_' or next == '-' or next == '\\' or
                    std.ascii.isAlphabetic(next) or next >= 0x80;
                if (!ok) return true;
            }
            at_compound_start = false;
            continue;
        }

        if (at_compound_start and std.ascii.isDigit(c)) {
            var j: usize = i + 1;
            while (j < selector.len and std.ascii.isDigit(selector[j])) : (j += 1) {}

            if (j < selector.len and selector[j] == '.') {
                j += 1;
                while (j < selector.len and std.ascii.isDigit(selector[j])) : (j += 1) {}
            }

            if (j < selector.len and (selector[j] == 'e' or selector[j] == 'E')) {
                var k: usize = j + 1;
                if (k < selector.len and (selector[k] == '+' or selector[k] == '-')) k += 1;
                if (k < selector.len and std.ascii.isDigit(selector[k])) {
                    j = k + 1;
                    while (j < selector.len and std.ascii.isDigit(selector[j])) : (j += 1) {}
                }
            }

            if (j < selector.len and selector[j] == '%') {
                const after = j + 1;
                const is_terminator = after >= selector.len or selector[after] == ',' or isWhitespace(selector[after]);
                if (is_terminator) {
                    i = after - 1;
                    at_compound_start = false;
                    continue;
                }
            }

            return true;
        }

        at_compound_start = false;
    }

    return false;
}

/// Check if a string is a valid CSS identifier (can be output unquoted)
fn isCssIdentifier(val: []const u8) bool {
    if (val.len == 0) return false;
    if (std.mem.startsWith(u8, val, "--")) return false;
    // Must start with a letter, underscore, or non-ASCII
    const first = val[0];
    if (!std.ascii.isAlphabetic(first) and first != '_' and first < 128) {
        // Allow leading - followed by a valid ident start
        if (first == '-') {
            if (val.len < 2) return false;
            const second = val[1];
            if (!std.ascii.isAlphabetic(second) and second != '_' and second < 128 and second != '-') return false;
        } else {
            return false;
        }
    }
    // Rest must be ident chars
    for (val[1..]) |ch| {
        if (!isIdentChar(ch)) return false;
    }
    return true;
}

fn isSelectorPseudo(name: []const u8) bool {
    const base = pseudoBaseName(name);
    const selector_pseudos = [_][]const u8{
        "not",  "is",           "has",     "where",   "matches",   "any",
        "host", "host-context", "slotted", "current", "nth-child", "nth-last-child",
    };
    for (selector_pseudos) |sp| {
        if (std.ascii.eqlIgnoreCase(base, sp)) return true;
    }
    return false;
}

/// Return the base name of a pseudo, stripping vendor prefix.
/// E.g. ":-ms-matches"  ->  "matches", ":is"  ->  "is"
pub fn pseudoBaseName(name: []const u8) []const u8 {
    if (name.len > 1 and name[0] == '-') {
        // vendor prefix: -vendor-name
        if (std.mem.findScalar(u8, name[1..], '-')) |pos| {
            return name[pos + 2 ..];
        }
    }
    return name;
}

/// Return the vendor prefix of a pseudo (including surrounding dashes), or empty.
/// E.g. "-ms-matches"  ->  "-ms-", "matches"  ->  ""
pub fn pseudoVendorPrefix(name: []const u8) []const u8 {
    if (name.len > 1 and name[0] == '-') {
        if (std.mem.findScalar(u8, name[1..], '-')) |pos| {
            return name[0 .. pos + 2];
        }
    }
    return "";
}

/// Return true if this pseudo takes An+B of <selector-list> syntax.
pub fn isNthWithOfPseudo(name: []const u8) bool {
    const base = pseudoBaseName(name);
    return std.ascii.eqlIgnoreCase(base, "nth-child") or
        std.ascii.eqlIgnoreCase(base, "nth-last-child");
}

/// Split ":nth-child(An+B of selector-list)" argument into {anb, selector}.
/// Returns null if there is no "of" keyword (plain An+B syntax).
fn splitNthOf(arg: []const u8) ?struct { anb: []const u8, selector: []const u8 } {
    // Look for " of " keyword at top level (not inside parens)
    var depth: u32 = 0;
    var i: usize = 0;
    while (i < arg.len) {
        const ch = arg[i];
        if (ch == '(') {
            depth += 1;
        } else if (ch == ')') {
            if (depth > 0) depth -= 1;
        } else if (depth == 0 and (ch == ' ' or ch == '\t')) {
            // check for "of"
            const rest = std.mem.trimStart(u8, arg[i..], " \t");
            if (rest.len >= 3 and
                std.ascii.eqlIgnoreCase(rest[0..2], "of") and
                (rest[2] == ' ' or rest[2] == '\t'))
            {
                const anb = std.mem.trimEnd(u8, arg[0..i], " \t");
                const sel = std.mem.trimStart(u8, rest[2..], " \t");
                return .{ .anb = anb, .selector = sel };
            }
        }
        i += 1;
    }
    return null;
}

/// Compact an An+B expression: normalize spaces and sign.
/// E.g. "2n + 1"  ->  "2n+1", "0n+1"  ->  "1", "-0n+0"  ->  "0"
fn compactAnB(allocator: std.mem.Allocator, anb: []const u8) ![]const u8 {
    const s = std.mem.trim(u8, anb, " \t");
    // Remove spaces around + and -
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var j: usize = 0;
    while (j < s.len) {
        const c = s[j];
        if (c == ' ' or c == '\t') {
            // skip whitespace around operators
            j += 1;
            continue;
        }
        try buf.append(allocator, c);
        j += 1;
    }
    return buf.toOwnedSlice(allocator);
}

fn isNthOfTypePseudo(name: []const u8) bool {
    const base = pseudoBaseName(name);
    return std.ascii.eqlIgnoreCase(base, "nth-of-type") or
        std.ascii.eqlIgnoreCase(base, "nth-last-of-type");
}

fn normalizeNthOfTypeArgumentForEmit(allocator: std.mem.Allocator, arg: []const u8) ![]const u8 {
    if (arg.len == 0) return arg;

    const trimmed = std.mem.trim(u8, arg, " \t\r\n");
    var needs_change = trimmed.len != arg.len;
    var i: usize = 0;
    while (i < trimmed.len) {
        if (trimmed[i] == ' ' or trimmed[i] == '\t' or trimmed[i] == '\n' or trimmed[i] == '\r') {
            var j = i + 1;
            while (j < trimmed.len and (trimmed[j] == ' ' or trimmed[j] == '\t' or trimmed[j] == '\n' or trimmed[j] == '\r')) : (j += 1) {}
            if (j > i + 1) {
                needs_change = true;
                break;
            }
            i = j;
            continue;
        }
        i += 1;
    }
    if (!needs_change) return arg;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    i = 0;
    while (i < trimmed.len) {
        const c = trimmed[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t' or trimmed[i] == '\n' or trimmed[i] == '\r')) : (i += 1) {}
            if (i < trimmed.len and out.items.len > 0) try out.append(allocator, ' ');
            continue;
        }
        try out.append(allocator, c);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

// ============================================================================
// CSS Output
// ============================================================================

/// Serialize a `SelectorList` back to its CSS source form. Returned slice is
/// caller-owned and must be freed with `allocator.free`.
pub fn toCss(allocator: std.mem.Allocator, selector_list: *const SelectorList) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var est: usize = 0;
    for (selector_list.selectors.items) |complex| {
        est += estimateComplexSelectorCssLen(&complex) + 2;
    }
    try buf.ensureTotalCapacity(allocator, @max(est, 16));

    for (selector_list.selectors.items, 0..) |complex, i| {
        if (i > 0) {
            try buf.appendSlice(allocator, if (complex.leading_separator_has_newline) ",\n" else ", ");
        }
        try writeComplexSelector(&buf, allocator, &complex);
    }

    return buf.toOwnedSlice(allocator);
}

/// Cheap upper-ish bound for selector CSS length to cut ArrayList reallocations (extend / cache paths).
fn estimateComplexSelectorCssLen(complex: *const ComplexSelector) usize {
    var n: usize = 0;
    for (complex.components.items) |comp| {
        switch (comp) {
            .compound => |c| {
                // Extend-heavy realworld selectors often exceed the old 16-byte
                // per-simple heuristic; a wider upper-ish bound avoids ArrayList
                // remaps without walking every selector name on this hot path.
                n += c.simple_selectors.items.len * 32;
            },
            .combinator => |comb| {
                n += switch (comb) {
                    .descendant => 1,
                    .child, .next_sibling, .general_sibling => 3,
                    .column => 4,
                };
            },
        }
    }
    return @max(n, 8);
}

/// Serialize a single `ComplexSelector` back to CSS. Caller owns the result.
pub fn complexSelectorToCss(allocator: std.mem.Allocator, complex: *const ComplexSelector) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.ensureTotalCapacity(allocator, estimateComplexSelectorCssLen(complex));
    try writeComplexSelector(&buf, allocator, complex);
    return buf.toOwnedSlice(allocator);
}

fn estimateCompoundSelectorCssLen(compound: *const CompoundSelector) usize {
    var est: usize = 0;
    for (compound.simple_selectors.items) |ss| {
        est += switch (ss) {
            .type_selector => |n| n.len,
            .class => |n| 1 + n.len,
            .id => |n| 1 + n.len,
            .placeholder => |n| 1 + n.len,
            .parent => 1,
            .universal => 1,
            .attribute => |a| blk: {
                var e: usize = 1 + a.name.len + 1;
                if (a.op) |op| {
                    e += op.toCss().len;
                    if (a.value) |v| {
                        e += if (isCssIdentifier(v)) v.len else 2 + v.len;
                    }
                }
                if (a.modifier) |_| e += 2;
                break :blk e;
            },
            .pseudo_class => |p| 1 + p.name.len + if (p.argument) |a| a.len + 2 else 0,
            .pseudo_element => |p| 1 + p.name.len + if (p.argument) |a| a.len + 2 else 0,
        };
    }
    return @max(est, 8);
}

fn exactCompoundSelectorCssLenFast(compound: *const CompoundSelector) ?usize {
    var len: usize = 0;
    for (compound.simple_selectors.items) |ss| {
        len += switch (ss) {
            .type_selector => |n| n.len,
            .class => |n| 1 + n.len,
            .id => |n| 1 + n.len,
            .placeholder => |n| 1 + n.len,
            .parent => 1,
            .universal => 1,
            .attribute => |a| blk: {
                var n: usize = 1 + a.name.len + 1;
                if (a.op) |op| {
                    n += op.toCss().len;
                    if (a.value) |v| n += if (isCssIdentifier(v)) v.len else 2 + v.len;
                }
                if (a.modifier) |_| n += 2;
                break :blk n;
            },
            .pseudo_class => |p| blk: {
                if (p.selector != null) return null;
                var n: usize = 1 + p.name.len;
                if (p.argument) |arg| {
                    // nth-of-type arguments may be normalized during emit, so
                    // the raw argument length is not an exact output length.
                    if (isNthOfTypePseudo(p.name)) return null;
                    n += arg.len + 2;
                }
                break :blk n;
            },
            .pseudo_element => |p| blk: {
                if (p.selector != null) return null;
                var n: usize = 2 + p.name.len;
                if (p.argument) |arg| {
                    if (isNthOfTypePseudo(p.name)) return null;
                    n += arg.len + 2;
                }
                break :blk n;
            },
        };
    }
    return len;
}

/// Serialize a single `CompoundSelector` back to CSS. Caller owns the result.
pub fn compoundSelectorToCss(allocator: std.mem.Allocator, compound: *const CompoundSelector) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    if (exactCompoundSelectorCssLenFast(compound)) |exact| {
        try buf.ensureTotalCapacityPrecise(allocator, exact);
    } else {
        try buf.ensureTotalCapacity(allocator, estimateCompoundSelectorCssLen(compound));
    }
    try writeCompoundSelector(&buf, allocator, compound);
    return buf.toOwnedSlice(allocator);
}

fn writeComplexSelector(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, complex: *const ComplexSelector) std.mem.Allocator.Error!void {
    const items = complex.components.items;
    const combinator_padding_cap = std.math.mul(usize, items.len, 2) catch std.math.maxInt(usize);
    try buf.ensureUnusedCapacity(allocator, combinator_padding_cap);
    for (items, 0..) |comp, idx| {
        switch (comp) {
            .compound => |c| {
                try writeCompoundSelector(buf, allocator, &c);
            },
            .combinator => |comb| {
                if (comb == .descendant) {
                    try buf.append(allocator, ' ');
                } else {
                    // Explicit combinator spacing rules:
                    // - Leading space: always (unless at start)
                    // - Trailing space: only if next is NOT also a combinator
                    //   (the next combinator's leading space provides separation)
                    const is_first = idx == 0;
                    const is_last = idx == items.len - 1;
                    const next_is_comb = !is_last and items[idx + 1] == .combinator;
                    if (!is_first) try buf.append(allocator, ' ');
                    try buf.appendSlice(allocator, switch (comb) {
                        .child => ">",
                        .next_sibling => "+",
                        .general_sibling => "~",
                        .column => "||",
                        .descendant => unreachable,
                    });
                    if (!is_last and !next_is_comb) try buf.append(allocator, ' ');
                }
            },
        }
    }
}

fn normalizeLeadingCombinatorPseudoArg(allocator: std.mem.Allocator, inner: []const u8) std.mem.Allocator.Error![]const u8 {
    if (inner.len < 2) return inner;
    const c = inner[0];
    if ((c != '>' and c != '+' and c != '~') or inner[1] == ' ' or inner[1] == '\t' or inner[1] == '\n' or inner[1] == '\r') return inner;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, inner.len + 1);
    try out.append(allocator, c);
    try out.append(allocator, ' ');
    try out.appendSlice(allocator, inner[1..]);
    return try out.toOwnedSlice(allocator);
}

fn writeCompoundSelector(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, compound: *const CompoundSelector) std.mem.Allocator.Error!void {
    for (compound.simple_selectors.items) |ss| {
        try writeSimpleSelector(buf, allocator, &ss);
    }
}

fn writeSimpleSelector(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, ss: *const SimpleSelector) std.mem.Allocator.Error!void {
    switch (ss.*) {
        .type_selector => |name| {
            try buf.appendSlice(allocator, name);
        },
        .class => |name| {
            try buf.append(allocator, '.');
            try buf.appendSlice(allocator, name);
        },
        .id => |name| {
            try buf.append(allocator, '#');
            try buf.appendSlice(allocator, name);
        },
        .attribute => |attr| {
            try buf.append(allocator, '[');
            try buf.appendSlice(allocator, attr.name);
            if (attr.op) |op| {
                try buf.appendSlice(allocator, op.toCss());
                if (attr.value) |val| {
                    if (isCssIdentifier(val)) {
                        try buf.appendSlice(allocator, val);
                    } else {
                        const quote: u8 = if (std.mem.findScalar(u8, val, '"') != null and
                            std.mem.findScalar(u8, val, '\'') == null)
                            '\''
                        else
                            '"';
                        try buf.append(allocator, quote);
                        try appendCssStringContentQuoted(buf, allocator, val, quote);
                        try buf.append(allocator, quote);
                    }
                }
            }
            if (attr.modifier) |mod| {
                try buf.append(allocator, ' ');
                try buf.append(allocator, mod);
            }
            try buf.append(allocator, ']');
        },
        .pseudo_class => |ps| {
            try buf.append(allocator, ':');
            try buf.appendSlice(allocator, ps.name);
            if (ps.selector) |sel| {
                try buf.append(allocator, '(');
                // For nth-child(An+B of selector-list): output "arg of selector"
                if (ps.argument) |anb| {
                    try buf.appendSlice(allocator, anb);
                    try buf.appendSlice(allocator, " of ");
                }
                const inner_raw = try toCss(allocator, sel);
                defer allocator.free(inner_raw);
                const inner = try normalizeLeadingCombinatorPseudoArg(allocator, inner_raw);
                defer if (inner.ptr != inner_raw.ptr) allocator.free(inner);
                try buf.appendSlice(allocator, inner);
                try buf.append(allocator, ')');
            } else if (ps.argument) |arg| {
                try buf.append(allocator, '(');
                const normalized_arg = if (isNthOfTypePseudo(ps.name))
                    try normalizeNthOfTypeArgumentForEmit(allocator, arg)
                else
                    arg;
                defer if (normalized_arg.ptr != arg.ptr) allocator.free(normalized_arg);
                try buf.appendSlice(allocator, normalized_arg);
                try buf.append(allocator, ')');
            }
        },
        .pseudo_element => |ps| {
            try buf.appendSlice(allocator, "::");
            try buf.appendSlice(allocator, ps.name);
            if (ps.selector) |sel| {
                try buf.append(allocator, '(');
                // For nth-child(An+B of selector-list): output "arg of selector"
                if (ps.argument) |anb| {
                    try buf.appendSlice(allocator, anb);
                    try buf.appendSlice(allocator, " of ");
                }
                const inner_raw = try toCss(allocator, sel);
                defer allocator.free(inner_raw);
                const inner = try normalizeLeadingCombinatorPseudoArg(allocator, inner_raw);
                defer if (inner.ptr != inner_raw.ptr) allocator.free(inner);
                try buf.appendSlice(allocator, inner);
                try buf.append(allocator, ')');
            } else if (ps.argument) |arg| {
                try buf.append(allocator, '(');
                const normalized_arg = if (isNthOfTypePseudo(ps.name))
                    try normalizeNthOfTypeArgumentForEmit(allocator, arg)
                else
                    arg;
                defer if (normalized_arg.ptr != arg.ptr) allocator.free(normalized_arg);
                try buf.appendSlice(allocator, normalized_arg);
                try buf.append(allocator, ')');
            }
        },
        .placeholder => |name| {
            try buf.append(allocator, '%');
            try buf.appendSlice(allocator, name);
        },
        .parent => {
            try buf.append(allocator, '&');
        },
        .universal => {
            try buf.append(allocator, '*');
        },
    }
}

fn appendCssStringContentQuoted(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8, quote: u8) std.mem.Allocator.Error!void {
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        const c = value[i];
        if (c == '\\' and i + 1 < value.len and (value[i + 1] == '\\' or value[i + 1] == quote)) {
            try buf.append(allocator, '\\');
            try buf.append(allocator, value[i + 1]);
            i += 1;
            continue;
        }
        if (c == quote or c == '\\') try buf.append(allocator, '\\');
        try buf.append(allocator, c);
    }
}

fn buildResolvedPseudoSelector(
    allocator: std.mem.Allocator,
    is_element: bool,
    ps: PseudoSelector,
    resolved_inner: SelectorList,
) std.mem.Allocator.Error!SimpleSelector {
    const selector_ptr = try allocator.create(SelectorList);
    errdefer allocator.destroy(selector_ptr);
    selector_ptr.* = resolved_inner;
    errdefer selector_ptr.deinit();

    const owned_name = try allocator.dupe(u8, ps.name);
    errdefer allocator.free(owned_name);

    const owned_argument = if (ps.argument) |arg| try allocator.dupe(u8, arg) else null;
    errdefer if (owned_argument) |arg| allocator.free(arg);

    const owned_ps = PseudoSelector{
        .name = owned_name,
        .argument = owned_argument,
        .selector = selector_ptr,
    };
    return if (is_element)
        .{ .pseudo_element = owned_ps }
    else
        .{ .pseudo_class = owned_ps };
}

// ============================================================================
// Parent Selector Resolution
// ============================================================================

/// Substitute the Sass `&` parent placeholder in `selector_list` with `parent`,
/// returning a new `SelectorList` owned by the caller. Errors if `&` appears in
/// a context where no parent is available (e.g. top level).
pub fn resolveParent(allocator: std.mem.Allocator, selector_list: *const SelectorList, parent: *const SelectorList) ResolveParentError!SelectorList {
    var result = SelectorList.init(allocator);
    errdefer result.deinit();

    if (canResolveParentParentMajor(selector_list)) {
        for (parent.selectors.items) |parent_complex| {
            var single_parent = SelectorList.init(allocator);
            defer single_parent.deinit();
            try single_parent.selectors.append(allocator, try parent_complex.clone(allocator));

            for (selector_list.selectors.items) |complex| {
                if (!complexHasParent(&complex)) {
                    var new_complex = try parent_complex.clone(allocator);
                    errdefer new_complex.deinit();
                    const child_starts_with_combinator = complex.components.items.len > 0 and
                        complex.components.items[0] == .combinator;
                    const parent_ends_with_combinator = parent_complex.components.items.len > 0 and
                        parent_complex.components.items[parent_complex.components.items.len - 1] == .combinator;
                    if (!child_starts_with_combinator and !parent_ends_with_combinator) {
                        try new_complex.components.append(allocator, .{ .combinator = .descendant });
                    }
                    for (complex.components.items) |comp| {
                        switch (comp) {
                            .compound => |c| try new_complex.components.append(allocator, .{ .compound = try c.clone(allocator) }),
                            .combinator => |comb| try new_complex.components.append(allocator, .{ .combinator = comb }),
                        }
                    }
                    try result.selectors.append(allocator, new_complex);
                } else {
                    const resolved = try resolveParentInComplex(allocator, &complex, &single_parent);
                    defer allocator.free(resolved);
                    for (resolved) |r| {
                        try result.selectors.append(allocator, r);
                    }
                }
            }
        }
        propagateParentReferenceSeparatorNewlines(&result, selector_list, parent);
        return result;
    }

    for (selector_list.selectors.items) |complex| {
        // Check if this complex selector contains &
        if (!complexHasParent(&complex)) {
            // No & reference: prepend parent, then child components.
            // Skip adding descendant combinator if:
            //   - child starts with an explicit combinator, OR
            //   - parent ends with an explicit combinator
            const child_starts_with_combinator = complex.components.items.len > 0 and
                complex.components.items[0] == .combinator;
            for (parent.selectors.items) |parent_complex| {
                var new_complex = try parent_complex.clone(allocator);
                errdefer new_complex.deinit();
                const parent_ends_with_combinator = parent_complex.components.items.len > 0 and
                    parent_complex.components.items[parent_complex.components.items.len - 1] == .combinator;
                if (!child_starts_with_combinator and !parent_ends_with_combinator) {
                    try new_complex.components.append(allocator, .{ .combinator = .descendant });
                }
                for (complex.components.items) |comp| {
                    switch (comp) {
                        .compound => |c| {
                            try new_complex.components.append(allocator, .{ .compound = try c.clone(allocator) });
                        },
                        .combinator => |comb| {
                            try new_complex.components.append(allocator, .{ .combinator = comb });
                        },
                    }
                }
                try result.selectors.append(allocator, new_complex);
            }
        } else {
            // Replace & with parent selectors
            const resolved = try resolveParentInComplex(allocator, &complex, parent);
            defer allocator.free(resolved);
            for (resolved) |r| {
                try result.selectors.append(allocator, r);
            }
        }
    }

    return result;
}

/// @at-root variant: child members without `&` stay as-is (no parent prepend).
/// Parent-major ordering for `&` members to match Dart Sass output.
pub fn resolveParentAtRoot(allocator: std.mem.Allocator, selector_list: *const SelectorList, parent: *const SelectorList) ResolveParentError!SelectorList {
    var result = SelectorList.init(allocator);
    errdefer result.deinit();

    for (selector_list.selectors.items) |complex| {
        if (!complexHasParent(&complex)) {
            try result.selectors.append(allocator, try complex.clone(allocator));
        }
    }

    for (parent.selectors.items, 0..) |parent_complex, parent_idx| {
        var single_parent = SelectorList.init(allocator);
        defer single_parent.deinit();
        try single_parent.selectors.append(allocator, try parent_complex.clone(allocator));

        const parent_sep_newline = parent_idx > 0 and parent_complex.leading_separator_has_newline;

        for (selector_list.selectors.items) |complex| {
            if (!complexHasParent(&complex)) continue;
            const resolved = try resolveParentInComplex(allocator, &complex, &single_parent);
            defer allocator.free(resolved);
            for (resolved) |r| {
                var cloned = r;
                if (parent_sep_newline) {
                    cloned.leading_separator_has_newline = true;
                }
                try result.selectors.append(allocator, cloned);
            }
        }
    }

    return result;
}

fn propagateParentReferenceSeparatorNewlines(
    result: *SelectorList,
    selector_list: *const SelectorList,
    parent: *const SelectorList,
) void {
    if (!hasParentReference(selector_list)) return;
    if (selector_list.selectors.items.len == 0 or parent.selectors.items.len == 0) return;
    if (result.selectors.items.len != parent.selectors.items.len * selector_list.selectors.items.len) return;

    // dart-sass rule per-item:
    //- out_idx==0  ->  None
    //- child_idx==0  ->  parent's newline flag
    //- parent_idx>0 and parent newline  ->  forced newline (align within parent boundaries)
    //- else  ->  newline flag of child (however, if the corresponding item of child contains `&`, collapse)
    var out_idx: usize = 0;
    for (parent.selectors.items, 0..) |parent_complex, parent_idx| {
        const parent_sep_newline = parent_idx > 0 and parent_complex.leading_separator_has_newline;
        for (selector_list.selectors.items, 0..) |child_complex, child_idx| {
            const child_sep_newline = child_idx > 0 and child_complex.leading_separator_has_newline;
            const child_has_amp = complexHasParent(&child_complex);
            result.selectors.items[out_idx].leading_separator_has_newline = if (out_idx == 0)
                false
            else if (child_idx == 0)
                parent_sep_newline
            else if (parent_sep_newline)
                true
            else
                child_sep_newline and !child_has_amp;
            out_idx += 1;
        }
    }
}

fn canResolveParentParentMajor(selector_list: *const SelectorList) bool {
    for (selector_list.selectors.items) |complex| {
        if (complexDirectParentCount(&complex) > 1) return false;
        if (complexHasDeepOnlyParent(&complex)) return false;
    }
    return true;
}

fn complexDirectParentCount(complex: *const ComplexSelector) usize {
    var count: usize = 0;
    for (complex.components.items) |comp| {
        switch (comp) {
            .compound => |c| {
                for (c.simple_selectors.items) |ss| {
                    if (ss == .parent) count += 1;
                }
            },
            .combinator => {},
        }
    }
    return count;
}

fn complexHasDeepOnlyParent(complex: *const ComplexSelector) bool {
    for (complex.components.items) |comp| {
        switch (comp) {
            .compound => |c| {
                if (compoundHasParentDeep(&c) and !compoundHasParent(&c)) return true;
            },
            .combinator => {},
        }
    }
    return false;
}

fn complexHasParent(complex: *const ComplexSelector) bool {
    for (complex.components.items) |comp| {
        switch (comp) {
            .compound => |c| {
                if (compoundHasParentDeep(&c)) return true;
            },
            .combinator => {},
        }
    }
    return false;
}

/// Check if a compound selector contains & anywhere, including inside pseudo selectors.
fn compoundHasParentDeep(compound: *const CompoundSelector) bool {
    for (compound.simple_selectors.items) |ss| {
        if (ss == .parent) return true;
        // Check inside pseudo selector arguments
        const ps: ?PseudoSelector = switch (ss) {
            .pseudo_class => |p| p,
            .pseudo_element => |p| p,
            else => null,
        };
        if (ps) |pseudo| {
            if (pseudo.selector) |sel_list| {
                for (sel_list.selectors.items) |sel_complex| {
                    if (complexHasParent(&sel_complex)) return true;
                }
            }
        }
    }
    return false;
}

fn resolveParentInComplex(allocator: std.mem.Allocator, complex: *const ComplexSelector, parent: *const SelectorList) ResolveParentError![]ComplexSelector {
    // Start with a single empty complex selector
    var results: std.ArrayList(ComplexSelector) = .empty;
    defer results.deinit(allocator);
    var single_parent_arena = std.heap.ArenaAllocator.init(allocator);
    defer single_parent_arena.deinit();

    var initial = ComplexSelector.init(allocator);
    try results.append(allocator, initial);
    _ = &initial;

    for (complex.components.items) |comp| {
        switch (comp) {
            .combinator => |comb| {
                for (results.items) |*r| {
                    try r.components.append(allocator, .{ .combinator = comb });
                }
            },
            .compound => |c| {
                const has_direct_parent = compoundHasParent(&c);
                const has_deep_parent = compoundHasParentDeep(&c);
                if (!has_deep_parent) {
                    for (results.items) |*r| {
                        try r.components.append(allocator, .{ .compound = try c.clone(allocator) });
                    }
                } else if (!has_direct_parent and has_deep_parent) {
                    // & only inside pseudo selectors - resolve recursively
                    for (results.items) |*r| {
                        const resolved_compound = try resolveParentInCompound(allocator, &c, parent);
                        try r.components.append(allocator, .{ .compound = resolved_compound });
                    }
                } else {
                    // For each parent selector, we multiply the results
                    var new_results: std.ArrayList(ComplexSelector) = .empty;
                    defer new_results.deinit(allocator);
                    const new_results_cap = std.math.mul(usize, results.items.len, parent.selectors.items.len) catch std.math.maxInt(usize);
                    try new_results.ensureTotalCapacity(allocator, new_results_cap);

                    for (results.items) |*r| {
                        for (parent.selectors.items) |parent_complex| {
                            if (complexEndsWithCombinator(&parent_complex) and compoundUsesParentAsCompoundTail(&c)) {
                                return error.InvalidParentSelector;
                            }
                            var new_complex = try r.clone(allocator);
                            errdefer new_complex.deinit();

                            // Build a compound by replacing & with the last compound of parent
                            // and prepend parent context
                            var new_compound = CompoundSelector.init(allocator);
                            errdefer new_compound.deinit();

                            // Get the last compound from parent
                            var last_parent_compound_idx: ?usize = null;
                            for (parent_complex.components.items, 0..) |pc, pi| {
                                if (pc == .compound) {
                                    last_parent_compound_idx = pi;
                                }
                            }

                            //The child compound is purely `&` (no other simple selector),
                            //In cases where the parent ends in a trailing combinator (such as `b ~`),
                            //Don't merge parent_last into child compound, parent's
                            //All components (including trailing combinator) as prefix
                            //Needs to be restored. dart-sass behavior:
                            //parent `b ~` + child `& c`  ->  `b ~ c`
                            const child_is_pure_parent = !compoundUsesParentAsCompoundTail(&c);
                            const parent_has_trailing_combinator = complexEndsWithCombinator(&parent_complex);
                            const preserve_parent_trailing_combinator = child_is_pure_parent and parent_has_trailing_combinator;

                            // Add parent components before the last compound
                            if (last_parent_compound_idx) |lpi| {
                                const prefix_end = if (preserve_parent_trailing_combinator) parent_complex.components.items.len else lpi;
                                for (parent_complex.components.items[0..prefix_end]) |pc| {
                                    switch (pc) {
                                        .compound => |pc_c| {
                                            try new_complex.components.append(allocator, .{ .compound = try pc_c.clone(allocator) });
                                        },
                                        .combinator => |pc_comb| {
                                            try new_complex.components.append(allocator, .{ .combinator = pc_comb });
                                        },
                                    }
                                }

                                if (!preserve_parent_trailing_combinator) {
                                    // Merge parent's last compound with current compound (sans &)
                                    const parent_last = parent_complex.components.items[lpi].compound;
                                    for (parent_last.simple_selectors.items) |pss| {
                                        try new_compound.simple_selectors.append(allocator, try cloneSimpleSelector(pss, allocator));
                                    }
                                }
                            }

                            // Add non-& selectors from current compound,
                            // resolving & inside pseudo selectors recursively
                            for (c.simple_selectors.items) |ss| {
                                if (ss == .parent) continue;
                                const ps_opt: ?PseudoSelector = switch (ss) {
                                    .pseudo_class => |p| p,
                                    .pseudo_element => |p| p,
                                    else => null,
                                };
                                if (ps_opt) |ps| {
                                    if (ps.selector) |sel_list| {
                                        // Check if this pseudo has & inside
                                        var pseudo_has_parent = false;
                                        for (sel_list.selectors.items) |sel_complex| {
                                            if (complexHasParent(&sel_complex)) {
                                                pseudo_has_parent = true;
                                                break;
                                            }
                                        }
                                        if (pseudo_has_parent) {
                                            // Resolve & in pseudo selector argument
                                            _ = single_parent_arena.reset(.retain_capacity);
                                            const arena_alloc = single_parent_arena.allocator();
                                            var one_parent_list = SelectorList.init(arena_alloc);
                                            try one_parent_list.selectors.append(arena_alloc, try parent_complex.clone(arena_alloc));
                                            const resolved_inner = try resolveParentInPseudoSelectorList(allocator, sel_list, &one_parent_list);
                                            const new_pseudo = try buildResolvedPseudoSelector(allocator, ss == .pseudo_element, ps, resolved_inner);
                                            try new_compound.simple_selectors.append(allocator, new_pseudo);
                                            continue;
                                        }
                                    }
                                }
                                try new_compound.simple_selectors.append(allocator, try cloneSimpleSelector(ss, allocator));
                            }

                            if (new_compound.simple_selectors.items.len > 0) {
                                try new_complex.components.append(allocator, .{ .compound = new_compound });
                            } else {
                                //preserve_parent_trailing_combinator path: trailing of parent
                                //Have combinator at the end of new_complex and child subsequent components
                                //(Next iter combinator / compound). No empty compound required.
                                new_compound.deinit();
                            }
                            try new_results.append(allocator, new_complex);
                        }
                    }

                    // Replace results with new_results
                    for (results.items) |*r| {
                        r.deinit();
                    }
                    results.clearRetainingCapacity();
                    try results.ensureTotalCapacity(allocator, new_results.items.len);
                    for (new_results.items) |nr| {
                        try results.append(allocator, nr);
                    }
                    // Prevent new_results from deiniting items we moved
                    new_results.clearRetainingCapacity();
                }
            },
        }
    }

    return results.toOwnedSlice(allocator);
}

fn compoundHasParent(compound: *const CompoundSelector) bool {
    for (compound.simple_selectors.items) |ss| {
        if (ss == .parent) return true;
    }
    return false;
}

fn compoundUsesParentAsCompoundTail(compound: *const CompoundSelector) bool {
    for (compound.simple_selectors.items) |ss| {
        if (ss != .parent) return true;
    }
    return false;
}

fn complexEndsWithCombinator(complex: *const ComplexSelector) bool {
    return complex.components.items.len > 0 and
        complex.components.items[complex.components.items.len - 1] == .combinator;
}

fn resolveParentInPseudoSelectorList(
    allocator: std.mem.Allocator,
    selector_list: *const SelectorList,
    parent: *const SelectorList,
) ResolveParentError!SelectorList {
    var result = SelectorList.init(allocator);
    errdefer result.deinit();

    for (selector_list.selectors.items) |sel_complex| {
        if (complexHasParent(&sel_complex)) {
            var single = SelectorList.init(allocator);
            defer single.deinit();
            try single.selectors.append(allocator, try sel_complex.clone(allocator));

            var resolved = try resolveParent(allocator, &single, parent);
            defer resolved.deinit();
            for (resolved.selectors.items) |resolved_complex| {
                try result.selectors.append(allocator, try resolved_complex.clone(allocator));
            }
        } else {
            try result.selectors.append(allocator, try sel_complex.clone(allocator));
        }
    }

    return result;
}

/// Resolve & references inside pseudo selectors of a compound.
/// Used when a compound has no direct & but contains & inside pseudo args.
fn resolveParentInCompound(allocator: std.mem.Allocator, c: *const CompoundSelector, parent: *const SelectorList) ResolveParentError!CompoundSelector {
    var new_compound = CompoundSelector.init(allocator);
    errdefer new_compound.deinit();

    for (c.simple_selectors.items) |ss| {
        const ps_opt: ?PseudoSelector = switch (ss) {
            .pseudo_class => |p| p,
            .pseudo_element => |p| p,
            else => null,
        };
        if (ps_opt) |ps| {
            if (ps.selector) |sel_list| {
                var pseudo_has_parent = false;
                for (sel_list.selectors.items) |sel_complex| {
                    if (complexHasParent(&sel_complex)) {
                        pseudo_has_parent = true;
                        break;
                    }
                }
                if (pseudo_has_parent) {
                    const resolved_inner = try resolveParentInPseudoSelectorList(allocator, sel_list, parent);
                    const new_pseudo = try buildResolvedPseudoSelector(allocator, ss == .pseudo_element, ps, resolved_inner);
                    try new_compound.simple_selectors.append(allocator, new_pseudo);
                    continue;
                }
            }
        }
        try new_compound.simple_selectors.append(allocator, try cloneSimpleSelector(ss, allocator));
    }
    return new_compound;
}

// ============================================================================
// Selector append (cross-product)
// ============================================================================

/// selector-append($selectors...): Computes the cross product of base and suffix.
/// For each base complex selector and each suffix complex selector, merges the
/// last compound of base with the first compound of suffix (like concatenation).
pub fn selectorAppend(allocator: std.mem.Allocator, base: *const SelectorList, suffix: *const SelectorList) !SelectorList {
    var result = SelectorList.init(allocator);
    errdefer result.deinit();
    for (base.selectors.items) |*base_complex| {
        for (suffix.selectors.items) |*suffix_complex| {
            const appended = try appendComplexSelectors(allocator, base_complex, suffix_complex);
            if (appended) |a| {
                try result.selectors.append(allocator, a);
            }
        }
    }
    return result;
}

/// Return true if any complex selector in `list` contains a `&` parent reference.
pub fn hasParentReference(list: *const SelectorList) bool {
    for (list.selectors.items) |complex| {
        if (complexHasParent(&complex)) return true;
    }
    return false;
}

/// Merge the last compound of `base` with the first compound of `suffix`.
fn appendComplexSelectors(allocator: std.mem.Allocator, base: *const ComplexSelector, suffix: *const ComplexSelector) !?ComplexSelector {
    if (base.components.items.len == 0 or suffix.components.items.len == 0) return null;

    // Find the last compound index in base
    var base_last_compound_idx: ?usize = null;
    var i: usize = base.components.items.len;
    while (i > 0) {
        i -= 1;
        if (base.components.items[i] == .compound) {
            base_last_compound_idx = i;
            break;
        }
    }
    if (base_last_compound_idx == null) return null;
    const base_last_idx = base_last_compound_idx.?;
    const base_last_compound = base.components.items[base_last_idx].compound;

    // Find the first compound index in suffix
    if (suffix.components.items[0] != .compound) return null;
    const suffix_first_compound = suffix.components.items[0].compound;

    // Build merged compound: base_last + suffix_first simple selectors
    var merged = CompoundSelector.init(allocator);
    errdefer merged.deinit();
    for (base_last_compound.simple_selectors.items) |ss| {
        try merged.simple_selectors.append(allocator, try cloneSimpleSelector(ss, allocator));
    }
    for (suffix_first_compound.simple_selectors.items) |ss| {
        try merged.simple_selectors.append(allocator, try cloneSimpleSelector(ss, allocator));
    }

    // Build result complex: base components up to base_last_idx, then merged, then suffix rest
    var result = ComplexSelector.init(allocator);
    errdefer result.deinit();

    // Copy base components before last compound
    for (base.components.items[0..base_last_idx]) |comp| {
        switch (comp) {
            .compound => |c| try result.components.append(allocator, .{ .compound = try c.clone(allocator) }),
            .combinator => |comb| try result.components.append(allocator, .{ .combinator = comb }),
        }
    }

    // Add merged compound
    try result.components.append(allocator, .{ .compound = merged });

    // Add suffix components after first compound
    for (suffix.components.items[1..]) |comp| {
        switch (comp) {
            .compound => |c| try result.components.append(allocator, .{ .compound = try c.clone(allocator) }),
            .combinator => |comb| try result.components.append(allocator, .{ .combinator = comb }),
        }
    }

    return result;
}

// ============================================================================
// Super-selector check
// ============================================================================

/// Sass `selector.is-superselector()`: return true if every complex selector in
/// `sub` is matched by at least one complex selector in `super_sel`.
pub fn isSuperSelector(super_sel: *const SelectorList, sub: *const SelectorList) bool {
    // super is a super-selector of sub if every complex selector in sub
    // is matched by at least one complex selector in super.
    for (sub.selectors.items) |sub_complex| {
        var matched = false;
        for (super_sel.selectors.items) |super_complex| {
            if (complexIsSuperSelector(&super_complex, &sub_complex)) {
                matched = true;
                break;
            }
        }
        if (!matched) return false;
    }
    return true;
}

pub fn complexIsSuperSelector(super_sel: *const ComplexSelector, sub: *const ComplexSelector) bool {
    if (complexNotIsSuperSelector(super_sel, sub)) |result| {
        return result;
    }

    if (transparentPseudoPairIsSuperSelector(super_sel, sub)) |result| {
        return result;
    }

    if (subSelectorSubsetPseudo(super_sel, sub)) |result| {
        return result;
    }

    if (transparentPseudoSelector(super_sel, sub)) |ps| {
        if (ps.selector) |sel| {
            for (sel.selectors.items) |inner| {
                if (complexIsSuperSelector(&inner, sub)) return true;
            }
        }
        return false;
    }

    const super_parts = decomposeComplexSelector(super_sel) orelse return false;
    const sub_parts = decomposeComplexSelector(sub) orelse return false;

    if (super_parts.compound_count == 0 or sub_parts.compound_count == 0) return false;
    if (super_parts.compound_count > sub_parts.compound_count) return false;

    var super_idx = super_parts.compound_count - 1;
    var sub_idx = sub_parts.compound_count - 1;

    if (!compoundIsSuperSelector(super_parts.compounds[super_idx], sub_parts.compounds[sub_idx])) {
        return false;
    }

    while (super_idx > 0) {
        const super_comb = super_parts.combinators[super_idx - 1];
        super_idx -= 1;

        var matched = false;
        var candidate = sub_idx;
        while (candidate > 0) {
            candidate -= 1;
            if (!compoundIsSuperSelector(super_parts.compounds[super_idx], sub_parts.compounds[candidate])) {
                continue;
            }
            if (!combinatorPathMatches(super_comb, &sub_parts, candidate, sub_idx)) {
                continue;
            }
            sub_idx = candidate;
            matched = true;
            break;
        }

        if (!matched) return false;
    }

    return true;
}

fn transparentPseudoPairIsSuperSelector(super_sel: *const ComplexSelector, sub: *const ComplexSelector) ?bool {
    const super_ps = transparentPseudoOnly(super_sel) orelse return null;
    const sub_ps = transparentPseudoOnly(sub) orelse return null;
    if (!transparentSelectorPseudoNamesComparableForSuperselector(super_ps.name, sub_ps.name)) {
        // Both complexes are only :is/:where/:matches/:any. Without this early
        // answer, compound matching would spuriously relate :is() to :any().
        return false;
    }
    return isSuperSelector(super_ps.selector.?, sub_ps.selector.?);
}

/// True when both sides are the same pseudo name, or both are unprefixed
/// :is / :where / :matches (matching semantics align; specificity is ignored).
/// Vendor-prefixed names only pair with an identical string; :any is excluded
/// so :is and :any are not treated as interchangeable here.
fn transparentSelectorPseudoNamesComparableForSuperselector(a: []const u8, b: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(a, b)) return true;
    const ba = pseudoBaseName(a);
    const bb = pseudoBaseName(b);
    if (!std.mem.eql(u8, a, ba)) return false;
    if (!std.mem.eql(u8, b, bb)) return false;
    return isCanonicalTransparentSelectorPseudoBase(ba) and isCanonicalTransparentSelectorPseudoBase(bb);
}

fn isCanonicalTransparentSelectorPseudoBase(base: []const u8) bool {
    return std.ascii.eqlIgnoreCase(base, "is") or
        std.ascii.eqlIgnoreCase(base, "where") or
        std.ascii.eqlIgnoreCase(base, "matches");
}

fn transparentPseudoSelector(super_sel: *const ComplexSelector, sub: *const ComplexSelector) ?PseudoSelector {
    if (transparentPseudoOnly(sub) != null) return null;
    return transparentPseudoOnly(super_sel);
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

fn subSelectorSubsetPseudo(super_sel: *const ComplexSelector, sub: *const ComplexSelector) ?bool {
    if (complexIsSingleNthSelector(super_sel) != null) return null;
    if (sub.components.items.len != 1) return null;
    const compound = switch (sub.components.items[0]) {
        .compound => |c| c,
        .combinator => return null,
    };
    if (compound.simple_selectors.items.len != 1) return null;
    const pseudo = switch (compound.simple_selectors.items[0]) {
        .pseudo_class => |ps| ps,
        else => return null,
    };
    const inner = pseudo.selector orelse return null;
    if (!isNthWithOfPseudo(pseudo.name)) return null;

    var super_list = SelectorList.init(std.heap.page_allocator);
    defer super_list.deinit();
    super_list.selectors.append(std.heap.page_allocator, super_sel.clone(std.heap.page_allocator) catch return null) catch return null;
    return isSuperSelector(&super_list, inner);
}

fn complexIsSingleNthSelector(complex: *const ComplexSelector) ?PseudoSelector {
    if (complex.components.items.len != 1) return null;
    const compound = switch (complex.components.items[0]) {
        .compound => |c| c,
        .combinator => return null,
    };
    if (compound.simple_selectors.items.len != 1) return null;
    return switch (compound.simple_selectors.items[0]) {
        .pseudo_class => |ps| if (isNthWithOfPseudo(ps.name) and ps.selector != null) ps else null,
        else => null,
    };
}

fn isTransparentSelectorPseudo(name: []const u8) bool {
    const base = pseudoBaseName(name);
    return std.ascii.eqlIgnoreCase(base, "is") or
        std.ascii.eqlIgnoreCase(base, "where") or
        std.ascii.eqlIgnoreCase(base, "matches") or
        std.ascii.eqlIgnoreCase(base, "any");
}

const NotCompoundInfo = struct {
    name: []const u8,
    selectors: SelectorList,

    fn deinit(self: *NotCompoundInfo) void {
        self.selectors.deinit();
    }
};

fn complexNotIsSuperSelector(super_sel: *const ComplexSelector, sub: *const ComplexSelector) ?bool {
    const super_not = aggregateNotCompound(std.heap.page_allocator, super_sel) catch return null;
    if (super_not == null) return null;
    var super_info = super_not.?;
    defer super_info.deinit();

    const sub_not = aggregateNotCompound(std.heap.page_allocator, sub) catch return false;
    if (sub_not) |info| {
        var sub_info = info;
        defer sub_info.deinit();
        if (!std.mem.eql(u8, super_info.name, sub_info.name)) return false;
        return isSuperSelector(&sub_info.selectors, &super_info.selectors);
    }

    return !complexCouldMatchAnyNotSelector(&super_info.selectors, sub);
}

fn aggregateNotCompound(allocator: std.mem.Allocator, complex: *const ComplexSelector) !?NotCompoundInfo {
    if (complex.components.items.len != 1) return null;
    const compound = switch (complex.components.items[0]) {
        .compound => |c| c,
        .combinator => return null,
    };
    if (compound.simple_selectors.items.len == 0) return null;

    var result = SelectorList.init(allocator);
    errdefer result.deinit();

    var not_name: ?[]const u8 = null;
    for (compound.simple_selectors.items) |simple| {
        const pseudo = switch (simple) {
            .pseudo_class => |ps| ps,
            else => return null,
        };
        if (!std.ascii.eqlIgnoreCase(pseudoBaseName(pseudo.name), "not")) return null;
        const inner = pseudo.selector orelse return null;

        if (not_name == null) {
            not_name = pseudo.name;
        } else if (!std.mem.eql(u8, not_name.?, pseudo.name)) {
            return null;
        }

        for (inner.selectors.items) |inner_complex| {
            try result.selectors.append(allocator, try inner_complex.clone(allocator));
        }
    }

    return .{
        .name = not_name.?,
        .selectors = result,
    };
}

fn complexCouldMatchAnyNotSelector(not_selectors: *const SelectorList, sub: *const ComplexSelector) bool {
    for (not_selectors.selectors.items) |excluded| {
        if (complexIsSuperSelector(&excluded, sub) or complexIsSuperSelector(sub, &excluded)) {
            return true;
        }
        if (complexesCouldOverlap(&excluded, sub)) {
            return true;
        }
    }
    return false;
}

fn complexesCouldOverlap(a: *const ComplexSelector, b: *const ComplexSelector) bool {
    const a_compound = singleCompoundFromComplex(a) orelse return false;
    const b_compound = singleCompoundFromComplex(b) orelse return false;
    return compoundsCouldOverlap(a_compound, b_compound);
}

fn compoundsCouldOverlap(a: CompoundSelector, b: CompoundSelector) bool {
    const a_pseudo = compoundPseudoElementInfo(a);
    const b_pseudo = compoundPseudoElementInfo(b);
    if (a_pseudo.invalid or b_pseudo.invalid) return false;
    if ((a_pseudo.name == null) != (b_pseudo.name == null)) return false;
    if (a_pseudo.name) |a_name| {
        if (!pseudoElementsCompatible(a_name, b_pseudo.name.?)) return false;
    }

    if (typeSelectorsConflict(a, b)) return false;
    if (idSelectorsConflict(a, b)) return false;
    if (exactAttributeSelectorsConflict(a, b)) return false;

    return true;
}

fn typeSelectorsConflict(a: CompoundSelector, b: CompoundSelector) bool {
    var a_type: ?[]const u8 = null;
    var b_type: ?[]const u8 = null;

    for (a.simple_selectors.items) |ss| {
        switch (ss) {
            .type_selector => |name| {
                if (a_type == null) a_type = name;
            },
            else => {},
        }
    }
    for (b.simple_selectors.items) |ss| {
        switch (ss) {
            .type_selector => |name| {
                if (b_type == null) b_type = name;
            },
            else => {},
        }
    }

    if (a_type == null or b_type == null) return false;
    return !typeSelectorIsSuper(a_type.?, b_type.?) and !typeSelectorIsSuper(b_type.?, a_type.?);
}

fn idSelectorsConflict(a: CompoundSelector, b: CompoundSelector) bool {
    var a_id: ?[]const u8 = null;
    var b_id: ?[]const u8 = null;

    for (a.simple_selectors.items) |ss| {
        switch (ss) {
            .id => |name| {
                if (a_id == null) a_id = name;
            },
            else => {},
        }
    }
    for (b.simple_selectors.items) |ss| {
        switch (ss) {
            .id => |name| {
                if (b_id == null) b_id = name;
            },
            else => {},
        }
    }

    if (a_id == null or b_id == null) return false;
    return !std.mem.eql(u8, a_id.?, b_id.?);
}

fn exactAttributeSelectorsConflict(a: CompoundSelector, b: CompoundSelector) bool {
    for (a.simple_selectors.items) |a_ss| {
        const a_attr = switch (a_ss) {
            .attribute => |attr| attr,
            else => continue,
        };
        if (a_attr.op != .eq or a_attr.value == null) continue;

        for (b.simple_selectors.items) |b_ss| {
            const b_attr = switch (b_ss) {
                .attribute => |attr| attr,
                else => continue,
            };
            if (!std.mem.eql(u8, a_attr.name, b_attr.name)) continue;
            if (b_attr.op != .eq or b_attr.value == null) continue;
            if (!std.mem.eql(u8, a_attr.value.?, b_attr.value.?)) return true;
        }
    }
    return false;
}

const DecomposedComplexSelector = struct {
    compounds: [64]CompoundSelector,
    combinators: [63]Combinator,
    compound_count: usize,
};

fn decomposeComplexSelector(complex: *const ComplexSelector) ?DecomposedComplexSelector {
    var result = DecomposedComplexSelector{
        // SAFETY: initialized before first read in this scope.
        .compounds = undefined,
        // SAFETY: initialized before first read in this scope.
        .combinators = undefined,
        .compound_count = 0,
    };

    var expect_compound = true;
    for (complex.components.items) |comp| {
        switch (comp) {
            .compound => |c| {
                if (!expect_compound or result.compound_count >= result.compounds.len) return null;
                result.compounds[result.compound_count] = c;
                result.compound_count += 1;
                expect_compound = false;
            },
            .combinator => |comb| {
                if (expect_compound or result.compound_count == 0 or result.compound_count > result.combinators.len) {
                    return null;
                }
                result.combinators[result.compound_count - 1] = comb;
                expect_compound = true;
            },
        }
    }

    if (expect_compound) return null;
    return result;
}

fn combinatorPathMatches(super_comb: Combinator, sub_parts: *const DecomposedComplexSelector, start_idx: usize, end_idx: usize) bool {
    if (start_idx >= end_idx) return false;

    switch (super_comb) {
        .child => {
            return end_idx == start_idx + 1 and sub_parts.combinators[start_idx] == .child;
        },
        .next_sibling => {
            return end_idx == start_idx + 1 and sub_parts.combinators[start_idx] == .next_sibling;
        },
        .column => {
            return end_idx == start_idx + 1 and sub_parts.combinators[start_idx] == .column;
        },
        .descendant => {
            const path = sub_parts.combinators[start_idx..end_idx];
            if (path.len == 0) return false;
            if (path[0] != .descendant and path[0] != .child) return false;
            for (path[1..]) |sub_comb| {
                if (sub_comb == .column) return false;
            }
            return true;
        },
        .general_sibling => {
            for (sub_parts.combinators[start_idx..end_idx]) |sub_comb| {
                if (sub_comb != .general_sibling and sub_comb != .next_sibling) return false;
            }
            return true;
        },
    }
}

fn compoundIsSuperSelector(super_sel: CompoundSelector, sub: CompoundSelector) bool {
    const super_pseudo = compoundPseudoElementInfo(super_sel);
    const sub_pseudo = compoundPseudoElementInfo(sub);

    if (super_pseudo.invalid or sub_pseudo.invalid) return false;
    if ((super_pseudo.name == null) != (sub_pseudo.name == null)) return false;
    if (super_pseudo.name) |super_name| {
        if (!pseudoElementsCompatible(super_name, sub_pseudo.name.?)) return false;
        const super_idx = super_pseudo.index.?;
        const sub_idx = sub_pseudo.index.?;
        if (!simpleSelectorEqlForSuper(
            super_sel.simple_selectors.items[super_idx],
            sub.simple_selectors.items[sub_idx],
        )) return false;
    }

    // Super selectors before and after a pseudo-element must stay on the same
    // side of that pseudo-element in the sub selector.
    const super_split = super_pseudo.index orelse super_sel.simple_selectors.items.len;
    const sub_split = sub_pseudo.index orelse sub.simple_selectors.items.len;

    for (super_sel.simple_selectors.items[0..super_split]) |super_ss| {
        if (!compoundContainsSuperSimpleInRange(super_ss, sub, 0, sub_split)) return false;
    }

    const super_after_start = if (super_pseudo.index) |idx| idx + 1 else super_sel.simple_selectors.items.len;
    const sub_after_start = if (sub_pseudo.index) |idx| idx + 1 else sub.simple_selectors.items.len;
    for (super_sel.simple_selectors.items[super_after_start..]) |super_ss| {
        if (!compoundContainsSuperSimpleInRange(super_ss, sub, sub_after_start, sub.simple_selectors.items.len)) return false;
    }
    return true;
}

fn compoundContainsSuperSimple(super_ss: SimpleSelector, sub: CompoundSelector) bool {
    return compoundContainsSuperSimpleInRange(super_ss, sub, 0, sub.simple_selectors.items.len);
}

fn compoundContainsSuperSimpleInRange(super_ss: SimpleSelector, sub: CompoundSelector, start: usize, end: usize) bool {
    if (transparentPseudoSimple(super_ss)) |ps| {
        if (transparentSuperSimpleMatchesRange(ps, sub, start, end)) return true;
    }

    if (super_ss == .pseudo_class) {
        const pseudo = super_ss.pseudo_class;
        if (std.ascii.eqlIgnoreCase(pseudoBaseName(pseudo.name), "not") and pseudo.selector != null) {
            return notSuperSimpleMatchesRange(pseudo, sub, start, end);
        }
    }

    switch (super_ss) {
        .universal => return true,
        .type_selector => |super_name| {
            const super_ns = parseNs(super_name);
            if (super_ns.kind == .any and std.mem.eql(u8, super_ns.name, "*")) {
                return true;
            }
            for (sub.simple_selectors.items[start..end]) |sub_ss| {
                switch (sub_ss) {
                    .type_selector => |sub_name| {
                        if (typeSelectorIsSuper(super_name, sub_name)) return true;
                    },
                    else => {},
                }
            }
            return false;
        },
        else => {
            for (sub.simple_selectors.items[start..end]) |sub_ss| {
                if (simpleSelectorEqlForSuper(super_ss, sub_ss)) return true;
                if (transparentPseudoSimple(sub_ss)) |ps| {
                    if (transparentSubSimpleMatches(super_ss, ps)) return true;
                }
            }
            return false;
        },
    }
}

fn notSuperSimpleMatchesRange(
    super_ps: PseudoSelector,
    sub: CompoundSelector,
    start: usize,
    end: usize,
) bool {
    const selectors = super_ps.selector orelse return false;
    var sub_range = cloneCompoundRange(std.heap.page_allocator, sub, start, end) catch return false;
    defer sub_range.deinit();

    for (selectors.selectors.items) |inner_complex| {
        const inner_compound = singleCompoundFromComplex(&inner_complex) orelse return false;
        if (compoundsCouldOverlap(inner_compound, sub_range)) return false;
    }
    return true;
}

fn transparentPseudoSimple(ss: SimpleSelector) ?PseudoSelector {
    return switch (ss) {
        .pseudo_class => |ps| if (isTransparentSelectorPseudo(ps.name) and ps.selector != null) ps else null,
        else => null,
    };
}

fn transparentSuperSimpleMatchesRange(
    super_ps: PseudoSelector,
    sub: CompoundSelector,
    start: usize,
    end: usize,
) bool {
    const selectors = super_ps.selector orelse return false;
    var sub_range = cloneCompoundRange(std.heap.page_allocator, sub, start, end) catch return false;
    defer sub_range.deinit();

    for (selectors.selectors.items) |inner_complex| {
        const inner_compound = singleCompoundFromComplex(&inner_complex) orelse continue;
        if (compoundIsSuperSelector(inner_compound, sub_range)) return true;
    }
    return false;
}

fn transparentSubSimpleMatches(super_ss: SimpleSelector, sub_ps: PseudoSelector) bool {
    const selectors = sub_ps.selector orelse return false;
    for (selectors.selectors.items) |inner_complex| {
        const inner_compound = singleCompoundFromComplex(&inner_complex) orelse continue;
        if (compoundContainsSuperSimple(super_ss, inner_compound)) return true;
    }
    return false;
}

fn cloneCompoundRange(
    allocator: std.mem.Allocator,
    compound: CompoundSelector,
    start: usize,
    end: usize,
) !CompoundSelector {
    var result = CompoundSelector.init(allocator);
    errdefer result.deinit();
    for (compound.simple_selectors.items[start..end]) |ss| {
        try result.simple_selectors.append(allocator, try cloneSimpleSelector(ss, allocator));
    }
    return result;
}

fn singleCompoundFromComplex(complex: *const ComplexSelector) ?CompoundSelector {
    if (complex.components.items.len != 1) return null;
    return switch (complex.components.items[0]) {
        .compound => |compound| compound,
        .combinator => null,
    };
}

const CompoundPseudoElementInfo = struct {
    name: ?[]const u8 = null,
    invalid: bool = false,
    index: ?usize = null,
};

fn compoundPseudoElementInfo(compound: CompoundSelector) CompoundPseudoElementInfo {
    var result = CompoundPseudoElementInfo{};

    for (compound.simple_selectors.items, 0..) |ss, idx| {
        const name = simpleSelectorPseudoElementName(ss) orelse continue;

        if (result.name != null) {
            result.invalid = true;
            return result;
        }

        result.name = name;
        result.index = idx;
    }

    if (result.index) |pseudo_idx| {
        for (compound.simple_selectors.items[pseudo_idx + 1 ..]) |ss| {
            switch (ss) {
                .pseudo_class => {},
                else => {
                    result.invalid = true;
                    return result;
                },
            }
        }
    }

    return result;
}

fn simpleSelectorPseudoElementName(ss: SimpleSelector) ?[]const u8 {
    return switch (ss) {
        .pseudo_element => |ps| ps.name,
        .pseudo_class => |ps| if (isLegacyPseudoElementName(ps.name)) ps.name else null,
        else => null,
    };
}

const legacy_pseudo_element_names = std.StaticStringMap(void).initComptime(.{
    .{ "before", {} },
    .{ "after", {} },
    .{ "first-line", {} },
    .{ "first-letter", {} },
});

fn isLegacyPseudoElementName(name: []const u8) bool {
    return legacy_pseudo_element_names.has(name);
}

fn pseudoElementsCompatible(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn simpleSelectorEqlForSuper(a: SimpleSelector, b: SimpleSelector) bool {
    const a_legacy = switch (a) {
        .pseudo_class => |ps| isLegacyPseudoElementName(ps.name),
        else => false,
    };
    const b_legacy = switch (b) {
        .pseudo_class => |ps| isLegacyPseudoElementName(ps.name),
        else => false,
    };
    if (a_legacy or b_legacy) {
        const a_name = simpleSelectorPseudoElementName(a) orelse return false;
        const b_name = simpleSelectorPseudoElementName(b) orelse return false;
        if (!pseudoElementsCompatible(a_name, b_name)) return false;

        return switch (a) {
            .pseudo_class => |pa| switch (b) {
                .pseudo_class => |pb| pseudoSelectorIsSuper(pa, pb),
                .pseudo_element => |pb| pa.argument == null and pa.selector == null and pb.argument == null and pb.selector == null,
                else => false,
            },
            .pseudo_element => |pa| switch (b) {
                .pseudo_class => |pb| pa.argument == null and pa.selector == null and pb.argument == null and pb.selector == null,
                .pseudo_element => |pb| pseudoSelectorIsSuper(pa, pb),
                else => false,
            },
            else => false,
        };
    }
    return switch (a) {
        .pseudo_class => |pa| switch (b) {
            .pseudo_class => |pb| pseudoSelectorIsSuper(pa, pb),
            else => false,
        },
        .pseudo_element => |pa| switch (b) {
            .pseudo_element => |pb| pseudoSelectorIsSuper(pa, pb),
            else => false,
        },
        else => simpleSelectorEql(a, b),
    };
}

fn simpleSelectorEql(a: SimpleSelector, b: SimpleSelector) bool {
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

fn pseudoSelectorEql(a: PseudoSelector, b: PseudoSelector) bool {
    if (std.ascii.eqlIgnoreCase(pseudoBaseName(a.name), "current") or
        std.ascii.eqlIgnoreCase(pseudoBaseName(b.name), "current"))
    {
        if (!std.mem.eql(u8, a.name, b.name)) return false;
        if (a.argument != null and b.argument != null) {
            if (!std.mem.eql(u8, a.argument.?, b.argument.?)) return false;
        } else if (a.argument != null or b.argument != null) {
            return false;
        }
        if (a.selector != null and b.selector != null) {
            return selectorListStructuralEql(a.selector.?, b.selector.?);
        }
        return a.selector == null and b.selector == null;
    }
    return pseudoSelectorIsSuper(a, b) and pseudoSelectorIsSuper(b, a);
}

fn pseudoSelectorIsSuper(a: PseudoSelector, b: PseudoSelector) bool {
    if (!std.mem.eql(u8, a.name, b.name)) return false;
    if (a.argument != null and b.argument != null) {
        if (!std.mem.eql(u8, a.argument.?, b.argument.?)) return false;
    } else if (a.argument != null or b.argument != null) {
        return false;
    }
    if (a.selector != null and b.selector != null) {
        if (std.ascii.eqlIgnoreCase(pseudoBaseName(a.name), "current")) {
            return pseudoSelectorEql(a, b);
        }
        return isSuperSelector(a.selector.?, b.selector.?);
    }
    return a.selector == null and b.selector == null;
}

fn selectorListStructuralEql(a: *const SelectorList, b: *const SelectorList) bool {
    if (a.selectors.items.len != b.selectors.items.len) return false;
    for (a.selectors.items, b.selectors.items) |sa, sb| {
        if (!complexStructuralEql(&sa, &sb)) return false;
    }
    return true;
}

fn complexStructuralEql(a: *const ComplexSelector, b: *const ComplexSelector) bool {
    if (a.components.items.len != b.components.items.len) return false;
    for (a.components.items, b.components.items) |ca, cb| {
        switch (ca) {
            .compound => |a_compound| switch (cb) {
                .compound => |b_compound| if (!compoundStructuralEql(&a_compound, &b_compound)) return false,
                .combinator => return false,
            },
            .combinator => |a_comb| switch (cb) {
                .compound => return false,
                .combinator => |b_comb| if (a_comb != b_comb) return false,
            },
        }
    }
    return true;
}

fn compoundStructuralEql(a: *const CompoundSelector, b: *const CompoundSelector) bool {
    if (a.simple_selectors.items.len != b.simple_selectors.items.len) return false;
    for (a.simple_selectors.items, b.simple_selectors.items) |sa, sb| {
        if (!simpleSelectorEql(sa, sb)) return false;
    }
    return true;
}

const NsKind = enum {
    any,
    default,
    empty,
    explicit,
};

const NsInfo = struct {
    kind: NsKind,
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

fn typeSelectorIsSuper(super_name: []const u8, sub_name: []const u8) bool {
    const super_ns = parseNs(super_name);
    const sub_ns = parseNs(sub_name);

    const super_any_name = std.mem.eql(u8, super_ns.name, "*");
    if (!super_any_name and !std.mem.eql(u8, super_ns.name, sub_ns.name)) return false;

    return switch (super_ns.kind) {
        .any => true,
        .default => sub_ns.kind == .default,
        .empty => sub_ns.kind == .empty,
        .explicit => sub_ns.kind == .explicit and std.mem.eql(u8, super_ns.ns, sub_ns.ns),
    };
}

// ============================================================================
// Specificity
// ============================================================================

fn specificity(compound: *const CompoundSelector) [3]u32 {
    var a: u32 = 0;
    var b: u32 = 0;
    var c: u32 = 0;

    for (compound.simple_selectors.items) |ss| {
        switch (ss) {
            .id => a += 1,
            .class, .attribute, .pseudo_class => b += 1,
            .type_selector, .pseudo_element => c += 1,
            .universal, .parent, .placeholder => {},
        }
    }

    return .{ a, b, c };
}

// ============================================================================
// Tests
// ============================================================================

test "parse simple type selector" {
    const allocator = std.testing.allocator;
    var list = try parse(allocator, "div");
    defer list.deinit();

    try std.testing.expectEqual(@as(usize, 1), list.selectors.items.len);
    const complex = list.selectors.items[0];
    try std.testing.expectEqual(@as(usize, 1), complex.components.items.len);
    const compound = complex.components.items[0].compound;
    try std.testing.expectEqual(@as(usize, 1), compound.simple_selectors.items.len);
    try std.testing.expectEqualStrings("div", compound.simple_selectors.items[0].type_selector);
}

test "parse class selector" {
    const allocator = std.testing.allocator;
    var list = try parse(allocator, ".foo");
    defer list.deinit();

    const compound = list.selectors.items[0].components.items[0].compound;
    try std.testing.expectEqualStrings("foo", compound.simple_selectors.items[0].class);
}

test "parse id selector" {
    const allocator = std.testing.allocator;
    var list = try parse(allocator, "#bar");
    defer list.deinit();

    const compound = list.selectors.items[0].components.items[0].compound;
    try std.testing.expectEqualStrings("bar", compound.simple_selectors.items[0].id);
}

test "parse compound selector" {
    const allocator = std.testing.allocator;
    var list = try parse(allocator, "div.class#id");
    defer list.deinit();

    const compound = list.selectors.items[0].components.items[0].compound;
    try std.testing.expectEqual(@as(usize, 3), compound.simple_selectors.items.len);
    try std.testing.expectEqualStrings("div", compound.simple_selectors.items[0].type_selector);
    try std.testing.expectEqualStrings("class", compound.simple_selectors.items[1].class);
    try std.testing.expectEqualStrings("id", compound.simple_selectors.items[2].id);
}

test "parse complex selector with child combinator" {
    const allocator = std.testing.allocator;
    var list = try parse(allocator, "div > p");
    defer list.deinit();

    const complex = list.selectors.items[0];
    try std.testing.expectEqual(@as(usize, 3), complex.components.items.len);
    try std.testing.expectEqualStrings("div", complex.components.items[0].compound.simple_selectors.items[0].type_selector);
    try std.testing.expectEqual(Combinator.child, complex.components.items[1].combinator);
    try std.testing.expectEqualStrings("p", complex.components.items[2].compound.simple_selectors.items[0].type_selector);
}

test "parse complex selector with descendant combinator" {
    const allocator = std.testing.allocator;
    var list = try parse(allocator, "ul li");
    defer list.deinit();

    const complex = list.selectors.items[0];
    try std.testing.expectEqual(@as(usize, 3), complex.components.items.len);
    try std.testing.expectEqualStrings("ul", complex.components.items[0].compound.simple_selectors.items[0].type_selector);
    try std.testing.expectEqual(Combinator.descendant, complex.components.items[1].combinator);
    try std.testing.expectEqualStrings("li", complex.components.items[2].compound.simple_selectors.items[0].type_selector);
}

test "parse selector list" {
    const allocator = std.testing.allocator;
    var list = try parse(allocator, "div, span");
    defer list.deinit();

    try std.testing.expectEqual(@as(usize, 2), list.selectors.items.len);
    try std.testing.expectEqualStrings("div", list.selectors.items[0].components.items[0].compound.simple_selectors.items[0].type_selector);
    try std.testing.expectEqualStrings("span", list.selectors.items[1].components.items[0].compound.simple_selectors.items[0].type_selector);
}

test "parse attribute selector bare" {
    const allocator = std.testing.allocator;
    var list = try parse(allocator, "[href]");
    defer list.deinit();

    const compound = list.selectors.items[0].components.items[0].compound;
    const attr = compound.simple_selectors.items[0].attribute;
    try std.testing.expectEqualStrings("href", attr.name);
    try std.testing.expect(attr.op == null);
}

test "parse attribute selector with value" {
    const allocator = std.testing.allocator;
    var list = try parse(allocator, "[type=text]");
    defer list.deinit();

    const compound = list.selectors.items[0].components.items[0].compound;
    const attr = compound.simple_selectors.items[0].attribute;
    try std.testing.expectEqualStrings("type", attr.name);
    try std.testing.expectEqual(AttributeOp.eq, attr.op.?);
    try std.testing.expectEqualStrings("text", attr.value.?);
}

test "parse pseudo-class" {
    const allocator = std.testing.allocator;
    var list = try parse(allocator, ":hover");
    defer list.deinit();

    const compound = list.selectors.items[0].components.items[0].compound;
    const ps = compound.simple_selectors.items[0].pseudo_class;
    try std.testing.expectEqualStrings("hover", ps.name);
}

test "parse pseudo-element" {
    const allocator = std.testing.allocator;
    var list = try parse(allocator, "::before");
    defer list.deinit();

    const compound = list.selectors.items[0].components.items[0].compound;
    const ps = compound.simple_selectors.items[0].pseudo_element;
    try std.testing.expectEqualStrings("before", ps.name);
}

test "parse placeholder selector" {
    const allocator = std.testing.allocator;
    var list = try parse(allocator, "%placeholder");
    defer list.deinit();

    const compound = list.selectors.items[0].components.items[0].compound;
    try std.testing.expectEqualStrings("placeholder", compound.simple_selectors.items[0].placeholder);
}

test "toCss round-trip simple" {
    const allocator = std.testing.allocator;
    var list = try parse(allocator, "div.class > p");
    defer list.deinit();

    const css = try toCss(allocator, &list);
    defer allocator.free(css);

    try std.testing.expectEqualStrings("div.class > p", css);
}

test "toCss round-trip selector list" {
    const allocator = std.testing.allocator;
    var list = try parse(allocator, "div, span");
    defer list.deinit();

    const css = try toCss(allocator, &list);
    defer allocator.free(css);

    try std.testing.expectEqualStrings("div, span", css);
}

test "toCss round-trip id" {
    const allocator = std.testing.allocator;
    var list = try parse(allocator, "#main");
    defer list.deinit();

    const css = try toCss(allocator, &list);
    defer allocator.free(css);

    try std.testing.expectEqualStrings("#main", css);
}

test "toCss round-trip pseudo" {
    const allocator = std.testing.allocator;
    var list = try parse(allocator, "a:hover");
    defer list.deinit();

    const css = try toCss(allocator, &list);
    defer allocator.free(css);

    try std.testing.expectEqualStrings("a:hover", css);
}

test "toCss round-trip pseudo-element" {
    const allocator = std.testing.allocator;
    var list = try parse(allocator, "p::before");
    defer list.deinit();

    const css = try toCss(allocator, &list);
    defer allocator.free(css);

    try std.testing.expectEqualStrings("p::before", css);
}

test "isSuperSelector treats legacy pseudo-element syntax as equivalent" {
    const allocator = std.testing.allocator;
    var super_sel = try parse(allocator, ".foo:before");
    defer super_sel.deinit();
    var sub_sel = try parse(allocator, ".foo::before");
    defer sub_sel.deinit();

    try std.testing.expect(isSuperSelector(&super_sel, &sub_sel));
}

test "isSuperSelector requires matching pseudo-element presence" {
    const allocator = std.testing.allocator;
    var super_sel = try parse(allocator, ".foo");
    defer super_sel.deinit();
    var sub_sel = try parse(allocator, ".foo::before");
    defer sub_sel.deinit();

    try std.testing.expect(!isSuperSelector(&super_sel, &sub_sel));
}

test "isSuperSelector rejects pseudo-elements in invalid order" {
    const allocator = std.testing.allocator;
    var super_sel = try parse(allocator, ".foo::before.bar");
    defer super_sel.deinit();
    var sub_sel = try parse(allocator, ".foo.bar::before");
    defer sub_sel.deinit();

    try std.testing.expect(!isSuperSelector(&super_sel, &sub_sel));
}

test "toCss round-trip placeholder" {
    const allocator = std.testing.allocator;
    var list = try parse(allocator, "%placeholder");
    defer list.deinit();

    const css = try toCss(allocator, &list);
    defer allocator.free(css);

    try std.testing.expectEqualStrings("%placeholder", css);
}

test "parent selector resolution" {
    const allocator = std.testing.allocator;
    var parent = try parse(allocator, ".parent");
    defer parent.deinit();

    var child = try parse(allocator, "&.child");
    defer child.deinit();

    var resolved = try resolveParent(allocator, &child, &parent);
    defer resolved.deinit();

    const css = try toCss(allocator, &resolved);
    defer allocator.free(css);

    try std.testing.expectEqualStrings(".parent.child", css);
}

test "parent selector resolution - no ampersand" {
    const allocator = std.testing.allocator;
    var parent = try parse(allocator, ".parent");
    defer parent.deinit();

    var child = try parse(allocator, ".child");
    defer child.deinit();

    var resolved = try resolveParent(allocator, &child, &parent);
    defer resolved.deinit();

    const css = try toCss(allocator, &resolved);
    defer allocator.free(css);

    try std.testing.expectEqualStrings(".parent .child", css);
}

test "parent selector resolution preserves multiline parent separators for ampersand suffix" {
    const allocator = std.testing.allocator;
    var parent = try parse(allocator, ".button-left,\n.button-right,\n.button-plus");
    defer parent.deinit();

    var child = try parse(allocator, "&:after");
    defer child.deinit();

    var resolved = try resolveParent(allocator, &child, &parent);
    defer resolved.deinit();

    const css = try toCss(allocator, &resolved);
    defer allocator.free(css);

    try std.testing.expectEqualStrings(
        ".button-left:after,\n.button-right:after,\n.button-plus:after",
        css,
    );
}

test "specificity calculation" {
    const allocator = std.testing.allocator;

    // div.class#id => [1, 1, 1]
    var list = try parse(allocator, "div.class#id");
    defer list.deinit();

    const compound = &list.selectors.items[0].components.items[0].compound;
    const spec = specificity(compound);
    try std.testing.expectEqual(@as(u32, 1), spec[0]); // a (id)
    try std.testing.expectEqual(@as(u32, 1), spec[1]); // b (class)
    try std.testing.expectEqual(@as(u32, 1), spec[2]); // c (type)
}

test "specificity - universal has zero" {
    const allocator = std.testing.allocator;

    var list = try parse(allocator, "*");
    defer list.deinit();

    const compound = &list.selectors.items[0].components.items[0].compound;
    const spec = specificity(compound);
    try std.testing.expectEqual(@as(u32, 0), spec[0]);
    try std.testing.expectEqual(@as(u32, 0), spec[1]);
    try std.testing.expectEqual(@as(u32, 0), spec[2]);
}

test "specificity - multiple classes" {
    const allocator = std.testing.allocator;

    var list = try parse(allocator, ".a.b.c");
    defer list.deinit();

    const compound = &list.selectors.items[0].components.items[0].compound;
    const spec = specificity(compound);
    try std.testing.expectEqual(@as(u32, 0), spec[0]);
    try std.testing.expectEqual(@as(u32, 3), spec[1]);
    try std.testing.expectEqual(@as(u32, 0), spec[2]);
}

test "parse next sibling combinator" {
    const allocator = std.testing.allocator;
    var list = try parse(allocator, "h1 + p");
    defer list.deinit();

    const complex = list.selectors.items[0];
    try std.testing.expectEqual(@as(usize, 3), complex.components.items.len);
    try std.testing.expectEqual(Combinator.next_sibling, complex.components.items[1].combinator);
}

test "parse general sibling combinator" {
    const allocator = std.testing.allocator;
    var list = try parse(allocator, "h1 ~ p");
    defer list.deinit();

    const complex = list.selectors.items[0];
    try std.testing.expectEqual(@as(usize, 3), complex.components.items.len);
    try std.testing.expectEqual(Combinator.general_sibling, complex.components.items[1].combinator);
}

test "parse pseudo-class with argument" {
    const allocator = std.testing.allocator;
    var list = try parse(allocator, ":nth-child(2n+1)");
    defer list.deinit();

    const compound = list.selectors.items[0].components.items[0].compound;
    const ps = compound.simple_selectors.items[0].pseudo_class;
    try std.testing.expectEqualStrings("nth-child", ps.name);
    try std.testing.expectEqualStrings("2n+1", ps.argument.?);
}

test "splitNthOf accepts top-level tab before of" {
    const parts = splitNthOf("2n+1\tof .item") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("2n+1", parts.anb);
    try std.testing.expectEqualStrings(".item", parts.selector);
}

test "splitNthOf ignores tab-of sequence inside nested parens" {
    try std.testing.expect(splitNthOf("2n+(foo\tof .item)") == null);
}

test "parse :not() pseudo-class with selector" {
    const allocator = std.testing.allocator;
    var list = try parse(allocator, ":not(.hidden)");
    defer list.deinit();

    const compound = list.selectors.items[0].components.items[0].compound;
    const ps = compound.simple_selectors.items[0].pseudo_class;
    try std.testing.expectEqualStrings("not", ps.name);
    try std.testing.expect(ps.selector != null);
}

test "isSuperSelector basic" {
    const allocator = std.testing.allocator;

    // .foo is a super-selector of .foo.bar (because .foo matches all elements .foo.bar matches)
    var super_sel = try parse(allocator, ".foo");
    defer super_sel.deinit();

    var sub = try parse(allocator, ".foo.bar");
    defer sub.deinit();

    try std.testing.expect(isSuperSelector(&super_sel, &sub));
    try std.testing.expect(!isSuperSelector(&sub, &super_sel));
}

test "isSuperSelector respects child vs descendant combinators" {
    const allocator = std.testing.allocator;

    var descendant = try parse(allocator, ".a .b");
    defer descendant.deinit();

    var child = try parse(allocator, ".a > .b");
    defer child.deinit();

    try std.testing.expect(isSuperSelector(&descendant, &child));
    try std.testing.expect(!isSuperSelector(&child, &descendant));
}

test "isSuperSelector respects sibling combinator strength" {
    const allocator = std.testing.allocator;

    var general = try parse(allocator, ".a ~ .b");
    defer general.deinit();

    var adjacent = try parse(allocator, ".a + .b");
    defer adjacent.deinit();

    try std.testing.expect(isSuperSelector(&general, &adjacent));
    try std.testing.expect(!isSuperSelector(&adjacent, &general));
}

test "isSuperSelector does not treat sibling as descendant" {
    const allocator = std.testing.allocator;

    var descendant = try parse(allocator, ".a .b");
    defer descendant.deinit();

    var sibling = try parse(allocator, ".a + .b");
    defer sibling.deinit();

    try std.testing.expect(!isSuperSelector(&descendant, &sibling));
}

test "isSuperSelector treats universal as implicit superselector" {
    const allocator = std.testing.allocator;

    var super_sel = try parse(allocator, "*");
    defer super_sel.deinit();

    var sub_sel = try parse(allocator, ".foo");
    defer sub_sel.deinit();

    try std.testing.expect(isSuperSelector(&super_sel, &sub_sel));
}

test "isSuperSelector compares selector pseudo arguments structurally" {
    const allocator = std.testing.allocator;

    var super_sel = try parse(allocator, ":is(.foo, .bar)");
    defer super_sel.deinit();

    var sub_sel = try parse(allocator, ":is(.foo)");
    defer sub_sel.deinit();

    var unequal = try parse(allocator, ":is(.baz)");
    defer unequal.deinit();

    try std.testing.expect(isSuperSelector(&super_sel, &sub_sel));
    try std.testing.expect(!isSuperSelector(&sub_sel, &super_sel));
    try std.testing.expect(!isSuperSelector(&super_sel, &unequal));
}

test "isSuperSelector compares transparent selector pseudos by their inner selectors" {
    const allocator = std.testing.allocator;

    var super_sel = try parse(allocator, ":where(.foo, .bar)");
    defer super_sel.deinit();

    var sub_sel = try parse(allocator, ":where(.foo)");
    defer sub_sel.deinit();

    var unequal = try parse(allocator, ":where(.baz)");
    defer unequal.deinit();

    try std.testing.expect(isSuperSelector(&super_sel, &sub_sel));
    try std.testing.expect(!isSuperSelector(&sub_sel, &super_sel));
    try std.testing.expect(!isSuperSelector(&super_sel, &unequal));

    var is_sub = try parse(allocator, ":is(.foo)");
    defer is_sub.deinit();
    var is_super = try parse(allocator, ":is(.foo)");
    defer is_super.deinit();
    var where_wider = try parse(allocator, ":where(.foo, .bar)");
    defer where_wider.deinit();
    try std.testing.expect(isSuperSelector(&where_wider, &is_sub));
    try std.testing.expect(!isSuperSelector(&is_super, &where_wider));
}

test "isSuperSelector does not treat transparent pseudos as equivalent across names" {
    const allocator = std.testing.allocator;

    var is_super = try parse(allocator, ":is(.foo, .bar)");
    defer is_super.deinit();

    var any_sub = try parse(allocator, ":any(.foo, .bar)");
    defer any_sub.deinit();

    var prefixed_sub = try parse(allocator, ":-pfx-is(.foo, .bar)");
    defer prefixed_sub.deinit();

    try std.testing.expect(!isSuperSelector(&is_super, &any_sub));
    try std.testing.expect(!isSuperSelector(&is_super, &prefixed_sub));
}

test "isSuperSelector treats transparent selector pseudos inside compounds as transparent" {
    const allocator = std.testing.allocator;

    var super_sel = try parse(allocator, ":where(.foo).bar");
    defer super_sel.deinit();

    var sub_sel = try parse(allocator, ".foo.bar");
    defer sub_sel.deinit();

    var transparent_sub = try parse(allocator, ".bar:is(.foo)");
    defer transparent_sub.deinit();

    try std.testing.expect(isSuperSelector(&super_sel, &sub_sel));
    try std.testing.expect(isSuperSelector(&super_sel, &transparent_sub));
}

test "isSuperSelector does not treat :not() as a superselector of overlapping compounds" {
    const allocator = std.testing.allocator;

    var excluded_class = try parse(allocator, ":not(.foo)");
    defer excluded_class.deinit();
    var overlapping_class = try parse(allocator, ".bar");
    defer overlapping_class.deinit();
    try std.testing.expect(!isSuperSelector(&excluded_class, &overlapping_class));

    var excluded_id = try parse(allocator, ":not(#foo)");
    defer excluded_id.deinit();
    var disjoint_id = try parse(allocator, "#bar");
    defer disjoint_id.deinit();
    try std.testing.expect(isSuperSelector(&excluded_id, &disjoint_id));

    var excluded_type = try parse(allocator, ":not(a)");
    defer excluded_type.deinit();
    var disjoint_type = try parse(allocator, "div");
    defer disjoint_type.deinit();
    try std.testing.expect(isSuperSelector(&excluded_type, &disjoint_type));
}

test "isSuperSelector handles mixed compounds with disjoint :not() exclusions" {
    const allocator = std.testing.allocator;

    var disjoint_id_super = try parse(allocator, ".foo:not(#bar)");
    defer disjoint_id_super.deinit();
    var disjoint_id_sub = try parse(allocator, ".foo#baz");
    defer disjoint_id_sub.deinit();
    try std.testing.expect(isSuperSelector(&disjoint_id_super, &disjoint_id_sub));

    var overlapping_class_super = try parse(allocator, ".foo:not(.bar)");
    defer overlapping_class_super.deinit();
    var overlapping_class_sub = try parse(allocator, ".foo.baz");
    defer overlapping_class_sub.deinit();
    try std.testing.expect(!isSuperSelector(&overlapping_class_super, &overlapping_class_sub));

    var disjoint_type_super = try parse(allocator, ".foo:not(a)");
    defer disjoint_type_super.deinit();
    var disjoint_type_sub = try parse(allocator, "div.foo");
    defer disjoint_type_sub.deinit();
    try std.testing.expect(isSuperSelector(&disjoint_type_super, &disjoint_type_sub));
}

test "attribute selector with tilde-eq" {
    const allocator = std.testing.allocator;
    var list = try parse(allocator, "[class~=active]");
    defer list.deinit();

    const attr = list.selectors.items[0].components.items[0].compound.simple_selectors.items[0].attribute;
    try std.testing.expectEqualStrings("class", attr.name);
    try std.testing.expectEqual(AttributeOp.tilde_eq, attr.op.?);
    try std.testing.expectEqualStrings("active", attr.value.?);
}

test "toCss attribute selector" {
    const allocator = std.testing.allocator;
    var list = try parse(allocator, "[href]");
    defer list.deinit();

    const css = try toCss(allocator, &list);
    defer allocator.free(css);

    try std.testing.expectEqualStrings("[href]", css);
}

test "toCss attribute selector with value" {
    const allocator = std.testing.allocator;
    var list = try parse(allocator, "[type=\"text\"]");
    defer list.deinit();

    const css = try toCss(allocator, &list);
    defer allocator.free(css);

    try std.testing.expectEqualStrings("[type=text]", css);
}

test "toCss attribute selector decodes unnecessary string escapes" {
    const allocator = std.testing.allocator;
    var list = try parse(allocator, "[class*='\\:col-']");
    defer list.deinit();

    const css = try toCss(allocator, &list);
    defer allocator.free(css);

    try std.testing.expectEqualStrings("[class*=\":col-\"]", css);
}

test "toCss attribute selector keeps double-dash value quoted" {
    const allocator = std.testing.allocator;
    var list = try parse(allocator, ".a[class*=\"--disabled\"]");
    defer list.deinit();

    const css = try toCss(allocator, &list);
    defer allocator.free(css);

    try std.testing.expectEqualStrings(".a[class*=\"--disabled\"]", css);
}

test "toCss attribute selector escapes embedded double quotes" {
    const allocator = std.testing.allocator;
    var list = try parse(allocator, "div[data-refs-self*='\"card\"']");
    defer list.deinit();

    const css = try toCss(allocator, &list);
    defer allocator.free(css);

    try std.testing.expectEqualStrings("div[data-refs-self*='\"card\"']", css);
}

test "parse parent selector" {
    const allocator = std.testing.allocator;
    var list = try parse(allocator, "&");
    defer list.deinit();

    const compound = list.selectors.items[0].components.items[0].compound;
    try std.testing.expect(compound.simple_selectors.items[0] == .parent);
}

test "parse rejects identifier starts with digit for id/class/type selectors" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(ParseError.InvalidSelector, parse(allocator, "#2b"));
    try std.testing.expectError(ParseError.InvalidSelector, parse(allocator, ".3c"));
    try std.testing.expectError(ParseError.InvalidSelector, parse(allocator, "1a"));
}

test "hasInvalidIdentifierStart allows keyframe percentages" {
    try std.testing.expect(!hasInvalidIdentifierStart("0%"));
    try std.testing.expect(!hasInvalidIdentifierStart("12.5%"));
    try std.testing.expect(!hasInvalidIdentifierStart("1e2%"));
}

test "hasInvalidIdentifierStart flags invalid starts in selector compounds" {
    try std.testing.expect(hasInvalidIdentifierStart(".a > #2b"));
    try std.testing.expect(hasInvalidIdentifierStart(".a + .3x"));
    try std.testing.expect(hasInvalidIdentifierStart("1foo .bar"));
}
