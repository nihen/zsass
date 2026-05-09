//! Selector validation and post-processing helpers for extend and placeholder flows.

const std = @import("std");
const SelectorPart = struct {
    text: []const u8,
    separator_has_newline: bool = false,
};

// Misc helpers
const css_utils = @import("../runtime/css_utils.zig");
const isEscapedCharacter = css_utils.isEscapedCharacter;
const isHexDigit = css_utils.isHexDigit;

fn consumeStringQuoting(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    text: []const u8,
    i: *usize,
    in_string: *u8,
) !bool {
    const c = text[i.*];
    if (in_string.* != 0) {
        if (c == '\\' and i.* + 1 < text.len) {
            try buf.append(allocator, c);
            i.* += 1;
            try buf.append(allocator, text[i.*]);
            i.* += 1;
            return true;
        }
        if (c == in_string.*) in_string.* = 0;
        try buf.append(allocator, c);
        i.* += 1;
        return true;
    }
    if (c == '"' or c == '\'') {
        in_string.* = c;
        try buf.append(allocator, c);
        i.* += 1;
        return true;
    }
    return false;
}

/// Strip comments from selector text while preserving selector token boundaries.
pub fn stripSelectorComments(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.find(u8, text, "/*") == null and std.mem.find(u8, text, "//") == null) return text;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var i: usize = 0;
    var in_string: u8 = 0;

    while (i < text.len) {
        if (try consumeStringQuoting(allocator, &buf, text, &i, &in_string)) continue;
        const c = text[i];
        if (c == '/' and i + 1 < text.len) {
            if (text[i + 1] == '*') {
                var saw_newline = false;
                while (buf.items.len > 0 and
                    (buf.items[buf.items.len - 1] == ' ' or
                        buf.items[buf.items.len - 1] == '\t' or
                        buf.items[buf.items.len - 1] == '\n' or
                        buf.items[buf.items.len - 1] == '\r'))
                {
                    const last = buf.items[buf.items.len - 1];
                    if (last == '\n' or last == '\r') saw_newline = true;
                    _ = buf.pop();
                }
                i += 2;
                while (i + 1 < text.len) {
                    if (text[i] == '\n' or text[i] == '\r') saw_newline = true;
                    if (text[i] == '*' and text[i + 1] == '/') {
                        i += 2;
                        break;
                    }
                    i += 1;
                }
                while (i < text.len and (text[i] == ' ' or text[i] == '\t' or
                    text[i] == '\n' or text[i] == '\r'))
                {
                    if (text[i] == '\n' or text[i] == '\r') saw_newline = true;
                    i += 1;
                }
                if (i < text.len and buf.items.len > 0) {
                    const last = buf.items[buf.items.len - 1];
                    const next_char = text[i];
                    if (last != '(' and last != '[' and next_char != ')' and next_char != ']') {
                        try buf.append(allocator, if (saw_newline) '\n' else ' ');
                    }
                }
                continue;
            } else if (text[i + 1] == '/') {
                var saw_newline = false;
                while (buf.items.len > 0 and
                    (buf.items[buf.items.len - 1] == ' ' or
                        buf.items[buf.items.len - 1] == '\t' or
                        buf.items[buf.items.len - 1] == '\n' or
                        buf.items[buf.items.len - 1] == '\r'))
                {
                    const last = buf.items[buf.items.len - 1];
                    if (last == '\n' or last == '\r') saw_newline = true;
                    _ = buf.pop();
                }
                i += 2;
                while (i < text.len and text[i] != '\n' and text[i] != '\r') {
                    i += 1;
                }
                while (i < text.len and (text[i] == ' ' or text[i] == '\t' or
                    text[i] == '\n' or text[i] == '\r'))
                {
                    if (text[i] == '\n' or text[i] == '\r') saw_newline = true;
                    i += 1;
                }
                if (i < text.len and buf.items.len > 0) {
                    const last = buf.items[buf.items.len - 1];
                    const next_char = text[i];
                    if (last != '(' and last != '[' and next_char != ')' and next_char != ']') {
                        try buf.append(allocator, if (saw_newline) '\n' else ' ');
                    }
                }
                continue;
            }
        }
        try buf.append(allocator, c);
        i += 1;
    }

    return buf.toOwnedSlice(allocator);
}

fn isSelectorCommaWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Whether the comma at `comma_i` sits next to a newline (before or after whitespace padding).
fn commaSeparatorHasNewline(selector: []const u8, start: usize, comma_i: usize) bool {
    var j = comma_i + 1;
    while (j < selector.len and isSelectorCommaWhitespace(selector[j])) : (j += 1) {
        if (selector[j] == '\n' or selector[j] == '\r') return true;
    }
    var k = comma_i;
    while (k > start and isSelectorCommaWhitespace(selector[k - 1])) : (k -= 1) {
        if (selector[k - 1] == '\n' or selector[k - 1] == '\r') return true;
    }
    return false;
}

fn splitSelectorPartsAlloc(allocator: std.mem.Allocator, selector: []const u8) !std.ArrayList(SelectorPart) {
    var parts: std.ArrayList(SelectorPart) = .empty;
    errdefer parts.deinit(allocator);

    var depth: i32 = 0;
    var in_string: u8 = 0;
    var start: usize = 0;
    var i: usize = 0;

    while (i < selector.len) : (i += 1) {
        const c = selector[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < selector.len) {
                i += 1;
                continue;
            }
            if (c == in_string) in_string = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            continue;
        }
        if (c == '(' or c == '[') depth += 1;
        if (c == ')' or c == ']') depth -= 1;
        if (c == ',' and depth == 0) {
            const sep_has_newline = commaSeparatorHasNewline(selector, start, i);
            try parts.append(allocator, .{
                .text = selector[start..i],
                .separator_has_newline = sep_has_newline,
            });
            start = i + 1;
        }
    }

    if (start < selector.len) {
        try parts.append(allocator, .{ .text = selector[start..] });
    }
    return parts;
}

pub fn simplePlaceholderSelectorKey(sel: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, sel, " \t\n\r");
    if (trimmed.len < 2 or trimmed[0] != '%') return null;
    for (trimmed[1..]) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') continue;
        return null;
    }
    return trimmed;
}

fn compactNonEmptySelectorParts(
    allocator: std.mem.Allocator,
    original_parts: []const SelectorPart,
) !std.ArrayList(SelectorPart) {
    var compacted_original_parts: std.ArrayList(SelectorPart) = .empty;
    errdefer compacted_original_parts.deinit(allocator);
    try compacted_original_parts.ensureTotalCapacity(allocator, original_parts.len);
    var pending_separator_has_newline = false;
    for (original_parts) |part| {
        const trimmed = trimSelectorPartPreservingEscapedWhitespace(part.text);
        if (trimmed.len == 0) {
            pending_separator_has_newline = pending_separator_has_newline or part.separator_has_newline;
            continue;
        }
        if (compacted_original_parts.items.len > 0) {
            const last = compacted_original_parts.items.len - 1;
            compacted_original_parts.items[last].separator_has_newline =
                compacted_original_parts.items[last].separator_has_newline or
                pending_separator_has_newline;
            pending_separator_has_newline = false;
        }
        try compacted_original_parts.append(allocator, .{
            .text = part.text,
            .separator_has_newline = part.separator_has_newline,
        });
    }
    return compacted_original_parts;
}

fn matchOriginalPartsToExtendedIndices(
    original_items: []const SelectorPart,
    extended_items: []const SelectorPart,
    matched_ext_indices: []usize,
) usize {
    var next_ext_idx: usize = 0;
    var matched_count: usize = 0;
    for (original_items, 0..) |orig_part, orig_idx| {
        const orig_trimmed = trimSelectorPartPreservingEscapedWhitespace(orig_part.text);
        var ext_idx = next_ext_idx;
        while (ext_idx < extended_items.len) : (ext_idx += 1) {
            const ext_trimmed = trimSelectorPartPreservingEscapedWhitespace(extended_items[ext_idx].text);
            if (std.mem.eql(u8, ext_trimmed, orig_trimmed)) {
                matched_ext_indices[orig_idx] = ext_idx;
                matched_count += 1;
                next_ext_idx = ext_idx + 1;
                break;
            }
        }
    }
    return matched_count;
}

fn applyCommaNewlineSeparatorsFromExtendMatch(
    original_items: []const SelectorPart,
    extended_len: usize,
    original_parts_uncollapsed: []const SelectorPart,
    matched_ext_indices: []usize,
    matched_count: usize,
    separators: []bool,
) bool {
    var changed = false;
    if (matched_count != 0) {
        var last_matched_part_idx: ?usize = null;
        for (matched_ext_indices, 0..) |mi, oi| {
            if (mi != std.math.maxInt(usize)) last_matched_part_idx = oi;
        }
        for (original_items, 0..) |part, part_idx| {
            const group_start = matched_ext_indices[part_idx];
            if (group_start == std.math.maxInt(usize)) continue;

            var next_matched_part_idx = part_idx + 1;
            while (next_matched_part_idx < matched_ext_indices.len and
                matched_ext_indices[next_matched_part_idx] == std.math.maxInt(usize))
            {
                next_matched_part_idx += 1;
            }
            const group_end = if (next_matched_part_idx < matched_ext_indices.len)
                matched_ext_indices[next_matched_part_idx]
            else
                extended_len;

            if (group_end <= group_start) continue;

            if (part.separator_has_newline) {
                const boundary_idx = group_end - 1;
                if (boundary_idx < separators.len and !separators[boundary_idx]) {
                    separators[boundary_idx] = true;
                    changed = true;
                }
            }

            if (last_matched_part_idx) |last_idx| {
                if (part_idx == last_idx and group_end > group_start + 1 and part_idx > 0) {
                    const preceding_sep_newline = original_items[part_idx - 1].separator_has_newline;
                    if (preceding_sep_newline) {
                        var tail_sep_idx = group_start;
                        while (tail_sep_idx + 1 < group_end and tail_sep_idx < separators.len) : (tail_sep_idx += 1) {
                            if (!separators[tail_sep_idx]) {
                                separators[tail_sep_idx] = true;
                                changed = true;
                            }
                        }
                    }
                }
            }
        }
    } else if (extended_len == original_parts_uncollapsed.len) {
        for (original_parts_uncollapsed[0 .. original_parts_uncollapsed.len - 1], 0..) |p, idx| {
            if (p.separator_has_newline and !separators[idx]) {
                separators[idx] = true;
                changed = true;
            }
        }
    }
    return changed;
}

/// Preserve comma-newline separators from the original selector list when possible.
pub fn preserveOriginalSelectorCommaNewlinesAlloc(
    allocator: std.mem.Allocator,
    original_selector: []const u8,
    extended_selector: []const u8,
) ![]const u8 {
    if (std.mem.findScalar(u8, original_selector, '\n') == null and
        std.mem.findScalar(u8, original_selector, '\r') == null)
    {
        return extended_selector;
    }

    var original_parts = try splitSelectorPartsAlloc(allocator, original_selector);
    defer original_parts.deinit(allocator);
    var compacted_original_parts = try compactNonEmptySelectorParts(allocator, original_parts.items);
    defer compacted_original_parts.deinit(allocator);
    const original_items = compacted_original_parts.items;
    if (original_items.len <= 1) return extended_selector;

    var extended_parts = try splitSelectorPartsAlloc(allocator, extended_selector);
    defer extended_parts.deinit(allocator);
    if (extended_parts.items.len <= 1) {
        return extended_selector;
    }

    var separators = try allocator.alloc(bool, extended_parts.items.len - 1);
    defer allocator.free(separators);
    for (extended_parts.items[0 .. extended_parts.items.len - 1], 0..) |part, idx| {
        separators[idx] = part.separator_has_newline;
    }

    const matched_ext_indices = try allocator.alloc(usize, original_items.len);
    defer allocator.free(matched_ext_indices);
    @memset(matched_ext_indices, std.math.maxInt(usize));

    //For each original item, search forward on the extended side to find the minimum matching ext_idx.
    //The extended word in between is included in the "extend-added group" as a sibling derived from @extend.
    //Original for which no matching extended is found is treated as dropped by placeholder etc. (maxInt remains).
    //In older implementations that advanced `next_orig_idx` in a per-extended loop, before orig[1]=`.btn-flat`
    //When ext[1]=`.btn-small` comes, orig[1] is skipped and the .btn-flat match is lost.
    //There was a bug (observed with materialize `.btn,\n.btn-flat` + `.btn-small @extend .btn`).
    const matched_count = matchOriginalPartsToExtendedIndices(
        original_items,
        extended_parts.items,
        matched_ext_indices,
    );

    const changed = applyCommaNewlineSeparatorsFromExtendMatch(
        original_items,
        extended_parts.items.len,
        original_parts.items,
        matched_ext_indices,
        matched_count,
        separators,
    );

    if (!changed) return extended_selector;

    var rebuilt: std.ArrayList(u8) = .empty;
    errdefer rebuilt.deinit(allocator);
    for (extended_parts.items, 0..) |part, idx| {
        const trimmed = trimSelectorPartPreservingEscapedWhitespace(part.text);
        try rebuilt.appendSlice(allocator, trimmed);
        if (idx + 1 < extended_parts.items.len) {
            try rebuilt.appendSlice(allocator, if (separators[idx]) ",\n" else ", ");
        }
    }
    return rebuilt.toOwnedSlice(allocator);
}

test "preserveOriginalSelectorCommaNewlinesAlloc keeps multiline separators after dropping leading placeholder branch" {
    const allocator = std.testing.allocator;
    const preserved = try preserveOriginalSelectorCommaNewlinesAlloc(
        allocator,
        "%hidden-text, .button-left,\n.button-right,\n.button-plus,\n.button-min",
        ".button-left, .button-right, .button-plus, .button-min",
    );
    defer allocator.free(preserved);

    try std.testing.expectEqualStrings(
        ".button-left,\n.button-right,\n.button-plus,\n.button-min",
        preserved,
    );
}

test "preserveOriginalSelectorCommaNewlinesAlloc keeps only boundary newline for extend-added siblings" {
    //materialize `.btn,\n.btn-flat { ... }` to `.btn-small @extend .btn`, `.btn-large @extend .btn`
    //is applied, extended sibling lines up on the same line `, `, newline of the original source
    //is reflected only on the boundary (end of extend group).
    const allocator = std.testing.allocator;
    const original = ".btn,\n.btn-flat";
    const extended = ".btn, .btn-small, .btn-large, .btn-flat";
    const preserved = try preserveOriginalSelectorCommaNewlinesAlloc(
        allocator,
        original,
        extended,
    );
    defer if (preserved.ptr != extended.ptr) allocator.free(preserved);

    try std.testing.expectEqualStrings(
        ".btn, .btn-small, .btn-large,\n.btn-flat",
        preserved,
    );
}

fn trimSelectorPartPreservingEscapedWhitespace(part: []const u8) []const u8 {
    var start: usize = 0;
    while (start < part.len and (part[start] == ' ' or part[start] == '\t' or part[start] == '\n' or part[start] == '\r')) {
        start += 1;
    }

    var end = part.len;
    while (end > start) {
        const ch = part[end - 1];
        if (ch != ' ' and ch != '\t' and ch != '\n' and ch != '\r') break;

        // Check for directly escaped whitespace: `\ `
        var slash_count: usize = 0;
        var j = end - 1;
        while (j > start and part[j - 1] == '\\') {
            slash_count += 1;
            j -= 1;
        }
        if (slash_count % 2 == 1) break;

        // Check for hex escape delimiter: `\XXXX ` where trailing space terminates a hex escape.
        // Walk backwards over hex digits; if preceded by `\`, the space is a hex escape delimiter.
        if (end >= 3) {
            var hex_j = end - 2; // position before the trailing space
            var hex_count: usize = 0;
            while (hex_j > start and hex_count < 6 and isHexDigit(part[hex_j])) {
                hex_count += 1;
                if (hex_j == 0) break;
                hex_j -= 1;
            }
            if (hex_count > 0 and hex_j < end and part[hex_j] == '\\') {
                break; // Space is a hex escape delimiter, preserve it
            }
        }

        end -= 1;
    }

    return part[start..end];
}

/// Scans from `inner_start` (first char after `(`) to the index of the matching `)` for depth opened at `inner_start - 1`.
fn scanToClosingParenFromInner(sel: []const u8, inner_start: usize) usize {
    var depth: u32 = 1;
    var j = inner_start;
    var s_str: u8 = 0;
    while (j < sel.len) {
        if (s_str != 0) {
            if (sel[j] == '\\' and j + 1 < sel.len) {
                j += 2;
            } else if (sel[j] == s_str) {
                s_str = 0;
                j += 1;
            } else {
                j += 1;
            }
            continue;
        }
        if (sel[j] == '"' or sel[j] == '\'') {
            s_str = sel[j];
            j += 1;
            continue;
        }
        if (sel[j] == '(') {
            depth += 1;
        } else if (sel[j] == ')') {
            depth -= 1;
            if (depth == 0) break;
        }
        j += 1;
    }
    return j;
}

/// Single leading combinator is OK (e.g., "> a" is valid CSS).
pub fn hasBogusCombinatorsSimple(sel: []const u8) bool {
    if (sel.len == 0) return false;

    // We scan through the selector tracking combinators.
    // A combinator is +, >, or ~.
    // We need to handle:
    //  - strings (skip)
    //  - brackets (skip)
    //  - parens (recurse for pseudo-class selectors)
    var i: usize = 0;
    var consecutive_combinators: u32 = 0;
    var paren_depth: u32 = 0;
    var bracket_depth: u32 = 0;
    var in_string: u8 = 0;

    while (i < sel.len) {
        const c = sel[i];

        // Handle strings
        if (in_string != 0) {
            if (c == '\\' and i + 1 < sel.len) {
                i += 2;
            } else if (c == in_string) {
                in_string = 0;
                i += 1;
            } else {
                i += 1;
            }
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            consecutive_combinators = 0;
            i += 1;
            continue;
        }

        // Handle brackets
        if (c == '[') {
            bracket_depth += 1;
            consecutive_combinators = 0;
            i += 1;
            continue;
        }
        if (c == ']' and bracket_depth > 0) {
            bracket_depth -= 1;
            i += 1;
            continue;
        }
        if (bracket_depth > 0) {
            i += 1;
            continue;
        }

        // Escaped punctuation is part of the current simple selector, not a
        // combinator.  In particular `.language-c\+\+` must not be treated as
        // ending in the adjacent-sibling combinator.
        if (c == '\\' and i + 1 < sel.len) {
            consecutive_combinators = 0;
            i += 2;
            continue;
        }

        // Handle parens (for pseudo-class selectors like :is(), :has(), :not())
        if (c == '(') {
            paren_depth += 1;
            if (paren_depth == 1) {
                const inner_start = i + 1;
                const j = scanToClosingParenFromInner(sel, inner_start);
                if (j <= sel.len) {
                    const inner = sel[inner_start..j];
                    if (isSelectorPseudo(sel, i)) {
                        const is_has = isHasPseudo(sel, i);
                        if (checkBogusCombinatorInPseudo(inner, is_has)) return true;
                    }
                }
            }
            consecutive_combinators = 0;
            i += 1;
            continue;
        }
        if (c == ')') {
            if (paren_depth > 0) paren_depth -= 1;
            i += 1;
            continue;
        }
        if (paren_depth > 0) {
            i += 1;
            continue;
        }

        // Handle whitespace (skip)
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            i += 1;
            continue;
        }

        // Handle combinators
        if (c == '+' or c == '>' or c == '~') {
            consecutive_combinators += 1;
            // Multiple consecutive combinators is bogus
            if (consecutive_combinators >= 2) return true;
            i += 1;
            continue;
        }

        // Regular character
        consecutive_combinators = 0;
        i += 1;
    }

    // Trailing combinator is bogus
    if (consecutive_combinators > 0) return true;

    return false;
}

test "selector helpers: escaped plus is not a bogus combinator" {
    try std.testing.expect(!hasBogusCombinatorsSimple(
        "body:is(:not(.css-settings-manager), .code-language) pre:is(.language-c\\+\\+, .language-cpp)",
    ));
    try std.testing.expect(!checkBogusInPseudoPart(".language-c\\+\\+", false));
}

const SelectorArgumentPart = struct {
    text: []const u8,
    separator_has_newline: bool = false,
};

fn argsListCommaHasNewlineNear(args: []const u8, part_start: usize, comma_i: usize) bool {
    var separator_has_newline = false;
    var j = comma_i + 1;
    while (j < args.len and std.ascii.isWhitespace(args[j])) : (j += 1) {
        if (args[j] == '\n' or args[j] == '\r') separator_has_newline = true;
    }
    if (!separator_has_newline) {
        var k = comma_i;
        while (k > part_start and std.ascii.isWhitespace(args[k - 1])) : (k -= 1) {
            if (args[k - 1] == '\n' or args[k - 1] == '\r') separator_has_newline = true;
        }
    }
    return separator_has_newline;
}

fn splitSelectorArgumentsWithSeparators(allocator: std.mem.Allocator, args: []const u8) !std.ArrayList(SelectorArgumentPart) {
    var parts: std.ArrayList(SelectorArgumentPart) = .empty;
    errdefer parts.deinit(allocator);

    var start: usize = 0;
    var depth_paren: u32 = 0;
    var depth_bracket: u32 = 0;
    var depth_brace: u32 = 0;
    var in_string: u8 = 0;
    var i: usize = 0;
    while (i < args.len) {
        const c = args[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < args.len) {
                i += 2;
                continue;
            }
            if (c == in_string) in_string = 0;
            i += 1;
            continue;
        }

        switch (c) {
            '\\' => {
                if (i + 1 < args.len) {
                    i += 2;
                } else {
                    i += 1;
                }
                continue;
            },
            '"', '\'' => {
                in_string = c;
                i += 1;
                continue;
            },
            '[' => {
                depth_bracket += 1;
                i += 1;
                continue;
            },
            ']' => {
                if (depth_bracket > 0) depth_bracket -= 1;
                i += 1;
                continue;
            },
            '{' => {
                depth_brace += 1;
                i += 1;
                continue;
            },
            '}' => {
                if (depth_brace > 0) depth_brace -= 1;
                i += 1;
                continue;
            },
            '(' => {
                depth_paren += 1;
                i += 1;
                continue;
            },
            ')' => {
                if (depth_paren > 0) depth_paren -= 1;
                i += 1;
                continue;
            },
            ',' => {
                if (depth_paren == 0 and depth_bracket == 0 and depth_brace == 0) {
                    const separator_has_newline = argsListCommaHasNewlineNear(args, start, i);
                    try parts.append(allocator, .{
                        .text = args[start..i],
                        .separator_has_newline = separator_has_newline,
                    });
                    start = i + 1;
                }
                i += 1;
                continue;
            },
            else => {
                i += 1;
                continue;
            },
        }
    }

    try parts.append(allocator, .{ .text = args[start..] });
    return parts;
}

fn matchPseudoDefAt(selector: []const u8, i: usize, defs: []const []const u8) ?[]const u8 {
    for (defs) |name| {
        if (i + name.len <= selector.len and std.ascii.eqlIgnoreCase(selector[i..][0..name.len], name)) {
            return name;
        }
    }
    return null;
}

fn findPseudoArgumentListEnd(selector: []const u8, args_start: usize) ?usize {
    var depth: u32 = 1;
    var j = args_start;
    while (j < selector.len and depth > 0) {
        if (selector[j] == '(') {
            depth += 1;
        } else if (selector[j] == ')') {
            depth -= 1;
        }
        if (depth > 0) j += 1;
    }
    if (depth != 0) return null;
    return j;
}

fn rebuildUniqueCommaSeparatedPseudoArgs(
    allocator: std.mem.Allocator,
    arg_parts: []const SelectorArgumentPart,
) !struct { owned: []const u8, had_duplicate: bool } {
    var rebuilt: std.ArrayList(u8) = .empty;
    errdefer rebuilt.deinit(allocator);
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(allocator);
    try seen.ensureTotalCapacity(allocator, arg_parts.len);
    var first = true;
    var last_kept_idx: usize = 0;
    var had_duplicate = false;
    for (arg_parts, 0..) |arg_part, arg_idx| {
        const trimmed = std.mem.trim(u8, arg_part.text, " \t\n\r");
        if (trimmed.len == 0) continue;
        var duplicate = false;
        for (seen.items) |prev| {
            if (std.mem.eql(u8, prev, trimmed)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            had_duplicate = true;
            continue;
        }
        try seen.append(allocator, trimmed);
        if (!first) {
            var separator_has_newline = false;
            var check_idx = last_kept_idx;
            while (check_idx < arg_idx) : (check_idx += 1) {
                if (arg_parts[check_idx].separator_has_newline) {
                    separator_has_newline = true;
                    break;
                }
            }
            try rebuilt.appendSlice(allocator, if (separator_has_newline) ",\n" else ", ");
        }
        first = false;
        last_kept_idx = arg_idx;
        try rebuilt.appendSlice(allocator, trimmed);
    }
    return .{
        .owned = try rebuilt.toOwnedSlice(allocator),
        .had_duplicate = had_duplicate,
    };
}

fn dedupeSelectorPseudoArguments(allocator: std.mem.Allocator, selector: []const u8) std.mem.Allocator.Error![]const u8 {
    const pseudo_defs = [_][]const u8{
        ":is(",   ":where(",        ":matches(", ":any(",      ":not(", ":has(",
        ":host(", ":host-context(", ":slotted(", "::slotted(",
    };
    const defs_slice: []const []const u8 = &pseudo_defs;

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    var changed = false;
    while (i < selector.len) {
        if (matchPseudoDefAt(selector, i, defs_slice)) |name| {
            const args_start = i + name.len;
            const j = findPseudoArgumentListEnd(selector, args_start) orelse {
                try result.appendSlice(allocator, selector[i..]);
                changed = true;
                break;
            };

            const args = selector[args_start..j];
            const deduped_args = try dedupeSelectorPseudoArguments(allocator, args);
            defer if (deduped_args.ptr != args.ptr) allocator.free(deduped_args);

            var arg_parts = try splitSelectorArgumentsWithSeparators(allocator, deduped_args);
            defer arg_parts.deinit(allocator);

            const rb = try rebuildUniqueCommaSeparatedPseudoArgs(allocator, arg_parts.items);
            defer allocator.free(rb.owned);

            try result.appendSlice(allocator, name);
            try result.appendSlice(allocator, rb.owned);
            try result.append(allocator, ')');
            if (!std.mem.eql(u8, rb.owned, args) or deduped_args.ptr != args.ptr or rb.had_duplicate) changed = true;
            i = j + 1;
            continue;
        }

        try result.append(allocator, selector[i]);
        i += 1;
    }

    if (!changed) {
        result.deinit(allocator);
        return selector;
    }
    return result.toOwnedSlice(allocator);
}

pub fn containsReferenceCombinator(selector: []const u8) bool {
    var i: usize = 0;
    var in_string: u8 = 0;
    var bracket_depth: u32 = 0;
    var paren_depth: u32 = 0;
    while (i < selector.len) : (i += 1) {
        const c = selector[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < selector.len) {
                i += 1;
            } else if (c == in_string) {
                in_string = 0;
            }
            continue;
        }
        switch (c) {
            '"', '\'' => in_string = c,
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '/' => {
                if (bracket_depth > 0 or paren_depth > 0) continue;
                var j = i + 1;
                if (j >= selector.len or !isCssIdentStart(selector[j])) continue;
                j += 1;
                while (j < selector.len and isCssIdentChar(selector[j])) : (j += 1) {}
                if (j < selector.len and selector[j] == '/') return true;
            },
            else => {},
        }
    }
    return false;
}

fn isCssIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '-';
}

fn isCssIdentChar(c: u8) bool {
    return isCssIdentStart(c) or std.ascii.isDigit(c);
}

fn validateDelimitersOnCloseParen(bracket_depth: u32, paren_depth: *u32) !void {
    if (bracket_depth != 0) return;
    if (paren_depth.* == 0) return error.SassError;
    paren_depth.* -= 1;
}

fn validateDelimitersOnCloseBracket(bracket_depth: *u32) !void {
    if (bracket_depth.* == 0) return error.SassError;
    bracket_depth.* -= 1;
}

fn delimiterScanInsideString(c: u8, in_string: *u8) bool {
    if (in_string.* == 0) return false;
    if (c == in_string.*) in_string.* = 0;
    return true;
}

fn skipSelectorComment(selector: []const u8, i: *usize) bool {
    if (i.* + 1 >= selector.len or selector[i.*] != '/') return false;
    const next = selector[i.* + 1];
    if (next == '/') {
        i.* += 2;
        while (i.* < selector.len and selector[i.*] != '\n' and selector[i.*] != '\r') : (i.* += 1) {}
        return true;
    }
    if (next == '*') {
        i.* += 2;
        while (i.* + 1 < selector.len) : (i.* += 1) {
            if (selector[i.*] == '*' and selector[i.* + 1] == '/') {
                i.* += 2;
                return true;
            }
        }
        i.* = selector.len;
        return true;
    }
    return false;
}

fn delimiterScanOneChar(selector: []const u8, i: usize, paren_depth: *u32, bracket_depth: *u32, in_string: *u8) !void {
    const c = selector[i];
    if (isEscapedCharacter(selector, i)) return;
    if (delimiterScanInsideString(c, in_string)) return;
    switch (c) {
        '"', '\'' => in_string.* = c,
        '(' => paren_depth.* += 1,
        ')' => try validateDelimitersOnCloseParen(bracket_depth.*, paren_depth),
        '[' => bracket_depth.* += 1,
        ']' => try validateDelimitersOnCloseBracket(bracket_depth),
        else => {},
    }
}

fn validateDelimitersNoUnclosedDepth(paren_depth: u32, bracket_depth: u32, in_string: u8) !void {
    if (paren_depth != 0 or bracket_depth != 0 or in_string != 0) {
        return error.SassError;
    }
}

pub fn validateSelectorDelimiters(selector: []const u8) anyerror!void {
    var paren_depth: u32 = 0;
    var bracket_depth: u32 = 0;
    var in_string: u8 = 0;
    var i: usize = 0;
    while (i < selector.len) {
        if (in_string == 0 and skipSelectorComment(selector, &i)) continue;
        try delimiterScanOneChar(selector, i, &paren_depth, &bracket_depth, &in_string);
        i += 1;
    }
    try validateDelimitersNoUnclosedDepth(paren_depth, bracket_depth, in_string);
}

/// Check if a selector contains an unescaped '@' outside of strings and brackets.
/// '@' is not valid in CSS selectors and indicates interpolation produced invalid output.
/// Escaped '@' (i.e., '\@') is valid CSS and should not trigger this check.
pub fn selectorHasAtSign(selector: []const u8) bool {
    var in_string: u8 = 0;
    var bracket_depth: u32 = 0;
    var paren_depth: u32 = 0;
    var i: usize = 0;
    while (i < selector.len) : (i += 1) {
        const c = selector[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < selector.len) {
                i += 1;
                continue;
            }
            if (c == in_string) in_string = 0;
            continue;
        }
        if (skipSelectorComment(selector, &i)) continue;
        switch (c) {
            '"', '\'' => in_string = c,
            '\\' => {
                // Skip escaped character
                if (i + 1 < selector.len) i += 1;
            },
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '@' => {
                if (bracket_depth == 0 and paren_depth == 0) return true;
            },
            else => {},
        }
    }
    return false;
}

/// Validate that pseudo-classes requiring arguments have non-empty args.
/// E.g., `:nth-child()` is invalid (must have An+B expression).
pub fn validatePseudoClassArgs(selector: []const u8) anyerror!void {
    // Pseudo-classes that require An+B arguments
    const nth_pseudos = [_][]const u8{
        ":nth-child(",
        ":nth-last-child(",
        ":nth-of-type(",
        ":nth-last-of-type(",
    };
    for (nth_pseudos) |pseudo| {
        var pos: usize = 0;
        var in_string: u8 = 0;
        while (pos < selector.len) {
            if (in_string != 0) {
                if (selector[pos] == '\\' and pos + 1 < selector.len) {
                    pos += 2;
                    continue;
                }
                if (selector[pos] == in_string) in_string = 0;
                pos += 1;
                continue;
            }
            if (skipSelectorComment(selector, &pos)) continue;
            if (selector[pos] == '"' or selector[pos] == '\'') {
                in_string = selector[pos];
                pos += 1;
                continue;
            }
            if (std.ascii.toLower(selector[pos]) == pseudo[0] and
                pos + pseudo.len <= selector.len)
            {
                // Case-insensitive match
                var match = true;
                for (pseudo, 0..) |pc, pi| {
                    if (pos + pi >= selector.len or
                        std.ascii.toLower(selector[pos + pi]) != pc)
                    {
                        match = false;
                        break;
                    }
                }
                if (match) {
                    var after = pos + pseudo.len;
                    while (after < selector.len and
                        (selector[after] == ' ' or selector[after] == '\t' or selector[after] == '\n' or selector[after] == '\r'))
                    {
                        after += 1;
                    }
                    if (after < selector.len and selector[after] == ')') {
                        return error.SassError;
                    }
                }
            }
            pos += 1;
        }
    }
}

pub fn validateSelectorParentheses(selector: []const u8) anyerror!void {
    var i: usize = 0;
    var in_string: u8 = 0;
    var bracket_depth: u32 = 0;
    while (i < selector.len) : (i += 1) {
        const c = selector[i];
        if (isEscapedCharacter(selector, i)) continue;
        if (in_string != 0) {
            if (c == in_string) in_string = 0;
            continue;
        }
        if (skipSelectorComment(selector, &i)) continue;

        switch (c) {
            '"', '\'' => in_string = c,
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            '(' => {
                if (bracket_depth > 0) continue;

                var j = i;
                while (j > 0 and (selector[j - 1] == ' ' or selector[j - 1] == '\t' or selector[j - 1] == '\n' or selector[j - 1] == '\r')) {
                    j -= 1;
                }
                if (j == 0) return error.SassError;

                var name_start = j;
                while (name_start > 0 and isCssIdentChar(selector[name_start - 1])) {
                    name_start -= 1;
                }
                if (name_start == j) return error.SassError;

                if (name_start == 0 or selector[name_start - 1] != ':') {
                    if (!(name_start > 1 and selector[name_start - 2] == ':')) {
                        return error.SassError;
                    }
                }
            },
            else => {},
        }
    }
}

/// Check if the paren at position `paren_pos` is preceded by a selector pseudo-class
/// like :is, :not, :where, :matches, :has
fn isSelectorPseudo(sel: []const u8, paren_pos: usize) bool {
    if (paren_pos == 0) return false;
    // Look backwards for the pseudo-class name
    const before = sel[0..paren_pos];
    const pseudo_names = [_][]const u8{ ":is", ":not", ":where", ":matches", ":has" };
    for (pseudo_names) |name| {
        if (before.len >= name.len and
            std.mem.eql(u8, before[before.len - name.len ..], name))
        {
            return true;
        }
    }
    return false;
}

test "selector validation ignores Sass and CSS comments" {
    const with_line_comment =
        "button,\n" ++
        "html input[type=\"button\"], // comment with (2) and `audio`\n" ++
        "input[type=\"reset\"],\n" ++
        "input[type=\"submit\"]";
    try validateSelectorDelimiters(with_line_comment);
    try validateSelectorParentheses(with_line_comment);
    try validatePseudoClassArgs(with_line_comment);

    const with_block_comment = "a/* :nth-child() ( */:hover";
    try validateSelectorDelimiters(with_block_comment);
    try validateSelectorParentheses(with_block_comment);
    try validatePseudoClassArgs(with_block_comment);
}

/// Check if the paren at position `paren_pos` is preceded by :has
fn isHasPseudo(sel: []const u8, paren_pos: usize) bool {
    if (paren_pos < 4) return false;
    return std.mem.eql(u8, sel[paren_pos - 4 .. paren_pos], ":has");
}

/// Check if any comma-separated selector part inside a pseudo-class has bogus combinators.
/// For :has(), a single leading combinator is allowed.
/// For other pseudo-classes (:is, :not, :where, :matches), leading/trailing/multiple combinators are bogus.
fn checkBogusCombinatorInPseudo(inner: []const u8, is_has: bool) bool {
    // Split by comma and check each part
    var start: usize = 0;
    var paren_d: u32 = 0;
    var s: u8 = 0;
    var i: usize = 0;
    while (i <= inner.len) {
        if (i < inner.len) {
            if (s != 0) {
                if (inner[i] == '\\' and i + 1 < inner.len) {
                    i += 2;
                    continue;
                }
                if (inner[i] == s) s = 0;
                i += 1;
                continue;
            }
            if (inner[i] == '"' or inner[i] == '\'') {
                s = inner[i];
                i += 1;
                continue;
            }
            if (inner[i] == '(') {
                paren_d += 1;
                i += 1;
                continue;
            }
            if (inner[i] == ')') {
                if (paren_d > 0) paren_d -= 1;
                i += 1;
                continue;
            }
            if (inner[i] == ',' and paren_d == 0) {
                const part = std.mem.trim(u8, inner[start..i], " \t\n\r");
                if (checkBogusInPseudoPart(part, is_has)) return true;
                start = i + 1;
                i += 1;
                continue;
            }
        }
        if (i == inner.len) {
            const part = std.mem.trim(u8, inner[start..i], " \t\n\r");
            if (checkBogusInPseudoPart(part, is_has)) return true;
            break;
        }
        i += 1;
    }
    return false;
}

fn bogusPartAdvanceInString(part: []const u8, i: *usize, in_str: *u8) void {
    const c = part[i.*];
    if (c == '\\' and i.* + 1 < part.len) {
        i.* += 2;
    } else if (c == in_str.*) {
        in_str.* = 0;
        i.* += 1;
    } else {
        i.* += 1;
    }
}

const BogusPseudoComb = enum { not_combinator, combinator_ok, bogus };

fn bogusPartClassifyCombinator(
    c: u8,
    is_has: bool,
    seen_non_comb: bool,
    consecutive: *u32,
) BogusPseudoComb {
    if (c != '+' and c != '>' and c != '~') return .not_combinator;
    consecutive.* += 1;
    if (!seen_non_comb and !is_has) return .bogus;
    if (consecutive.* >= 2) return .bogus;
    return .combinator_ok;
}

fn bogusPartSkipIfBracket(
    c: u8,
    bracket_d: *u32,
    i: *usize,
    seen_non_comb: *bool,
    consecutive: *u32,
) bool {
    if (c == '[') {
        bracket_d.* += 1;
        seen_non_comb.* = true;
        consecutive.* = 0;
        i.* += 1;
        return true;
    }
    if (c == ']' and bracket_d.* > 0) {
        bracket_d.* -= 1;
        i.* += 1;
        return true;
    }
    if (bracket_d.* > 0) {
        i.* += 1;
        return true;
    }
    return false;
}

/// Returns true if bogus combinators were found.
fn bogusPartScanOne(
    part: []const u8,
    i: *usize,
    is_has: bool,
    in_str: *u8,
    bracket_d: *u32,
    seen_non_comb: *bool,
    consecutive: *u32,
) bool {
    const c = part[i.*];
    if (in_str.* != 0) {
        bogusPartAdvanceInString(part, i, in_str);
        return false;
    }
    if (c == '"' or c == '\'') {
        in_str.* = c;
        seen_non_comb.* = true;
        consecutive.* = 0;
        i.* += 1;
        return false;
    }
    if (bogusPartSkipIfBracket(c, bracket_d, i, seen_non_comb, consecutive)) return false;
    if (c == '\\' and i.* + 1 < part.len) {
        seen_non_comb.* = true;
        consecutive.* = 0;
        i.* += 2;
        return false;
    }
    if (c == ' ' or c == '\t') {
        i.* += 1;
        return false;
    }
    switch (bogusPartClassifyCombinator(c, is_has, seen_non_comb.*, consecutive)) {
        .not_combinator => {
            seen_non_comb.* = true;
            consecutive.* = 0;
            i.* += 1;
        },
        .combinator_ok => i.* += 1,
        .bogus => return true,
    }
    return false;
}

/// Check a single selector part inside a pseudo-class for bogus combinators.
fn checkBogusInPseudoPart(part: []const u8, is_has: bool) bool {
    if (part.len == 0) return false;

    var i: usize = 0;
    var consecutive: u32 = 0;
    var seen_non_comb = false;
    var in_str: u8 = 0;
    var bracket_d: u32 = 0;

    while (i < part.len) {
        if (bogusPartScanOne(part, &i, is_has, &in_str, &bracket_d, &seen_non_comb, &consecutive)) return true;
    }

    // Trailing combinator
    if (consecutive > 0) return true;

    return false;
}
