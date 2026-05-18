//! Selector placeholder pruning helpers for filtering and cleanup.

const std = @import("std");
const css_utils = @import("../runtime/css_utils.zig");

const isIdentStart = css_utils.isIdentStart;
const isIdentChar = css_utils.isIdentChar;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn isPlaceholderSelector(selector: []const u8) bool {
    // Check if ALL selectors in a comma-separated list are placeholders
    var iter = std.mem.splitSequence(u8, selector, ",");
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\n\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] != '%') return false;
    }
    return true;
}

/// Check if ALL selectors in a comma-separated list are private placeholders (%-prefix).
pub fn isPrivatePlaceholderSelector(selector: []const u8) bool {
    var iter = std.mem.splitSequence(u8, selector, ",");
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\n\r");
        if (trimmed.len == 0) continue;
        if (trimmed.len < 2 or trimmed[0] != '%' or trimmed[1] != '-') return false;
    }
    return true;
}

/// Remove private placeholder selector parts (%-prefix) from a comma-separated selector list.
pub fn removePrivatePlaceholderParts(allocator: std.mem.Allocator, selector: []const u8) std.mem.Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var parts = try splitSelectorArguments(allocator, selector);
    defer parts.deinit(allocator);

    var first = true;
    for (parts.items) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\n\r");
        if (trimmed.len == 0) continue;
        if (trimmed.len >= 2 and trimmed[0] == '%' and trimmed[1] == '-') continue;

        if (!first) {
            try buf.appendSlice(allocator, ", ");
        }
        try buf.appendSlice(allocator, trimmed);
        first = false;
    }

    return buf.toOwnedSlice(allocator);
}

/// Remove placeholder selector parts from a comma-separated selector list.
/// Also handles placeholders inside pseudo-class functions like :is(), :where(), :matches(), :not(), :has().
/// Returns a new string with only non-placeholder parts, or empty string if all are placeholders.
pub fn removePlaceholderParts(allocator: std.mem.Allocator, selector: []const u8) std.mem.Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // Reuse the balanced splitter so commas inside strings, attribute selectors,
    // and nested structures aren't rewritten while filtering placeholders.
    var parts = try splitSelectorArguments(allocator, selector);
    defer parts.deinit(allocator);

    var first = true;
    for (parts.items) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\n\r");
        if (trimmed.len == 0) continue;
        // Skip parts that start with % (placeholder selectors)
        if (trimmed[0] == '%') continue;

        // Check for placeholders inside pseudo-class functions
        const cleaned = try cleanPlaceholdersInPseudos(allocator, trimmed);
        defer if (cleaned.ptr != trimmed.ptr) {
            // cleanPlaceholdersInPseudos may return comptime literals (e.g. universal "*").
            const literal_star: []const u8 = "*";
            if (cleaned.ptr == literal_star.ptr and cleaned.len == 1) {
                // not heap
            } else {
                allocator.free(cleaned);
            }
        };
        const cleaned_trimmed = std.mem.trim(u8, cleaned, " \t\n\r");

        // If cleaning resulted in empty string or still contains placeholders, skip this part
        if (cleaned_trimmed.len == 0) continue;
        if (containsPlaceholderToken(cleaned_trimmed)) continue;

        if (!first) {
            // Preserve newline separators from the original selector string.
            // The raw part text starts with whitespace after the comma; if that
            // whitespace contains a newline, use ",\n" instead of ", ".
            const has_newline = for (part) |ch| {
                if (ch == '\n' or ch == '\r') break true;
                if (ch != ' ' and ch != '\t') break false;
            } else false;
            try buf.appendSlice(allocator, if (has_newline) ",\n" else ", ");
        }
        try buf.appendSlice(allocator, cleaned_trimmed);
        first = false;
    }

    return buf.toOwnedSlice(allocator);
}

/// Clean placeholder selectors from inside pseudo-class functions.
/// Handles :is(), :where(), :matches(), :not(), :has().
fn cleanPlaceholdersInPseudos(allocator: std.mem.Allocator, selector: []const u8) std.mem.Allocator.Error![]const u8 {
    const nth_pseudos = [_][]const u8{
        ":nth-child(",
        ":nth-last-child(",
        ":nth-of-type(",
        ":nth-last-of-type(",
    };
    const pseudo_defs = [_]struct {
        name: []const u8,
        drop_if_empty: bool,
    }{
        .{ .name = ":is(", .drop_if_empty = false },
        .{ .name = ":where(", .drop_if_empty = false },
        .{ .name = ":matches(", .drop_if_empty = false },
        .{ .name = ":any(", .drop_if_empty = false },
        .{ .name = ":not(", .drop_if_empty = true },
        .{ .name = ":has(", .drop_if_empty = false },
        .{ .name = ":host(", .drop_if_empty = false },
        .{ .name = ":host-context(", .drop_if_empty = false },
        .{ .name = ":slotted(", .drop_if_empty = false },
        .{ .name = "::slotted(", .drop_if_empty = false },
        .{ .name = "::part(", .drop_if_empty = false },
    };

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    var found_any = false;
    while (i < selector.len) {
        var matched_nth: ?[]const u8 = null;
        for (nth_pseudos) |name| {
            if (i + name.len <= selector.len and
                std.ascii.eqlIgnoreCase(selector[i..][0..name.len], name))
            {
                matched_nth = name;
                break;
            }
        }
        if (matched_nth) |nth_name| {
            found_any = true;
            const args_start = i + nth_name.len;

            var depth: u32 = 1;
            var j = args_start;
            while (j < selector.len and depth > 0) {
                if (selector[j] == '(') depth += 1;
                if (selector[j] == ')') depth -= 1;
                if (depth > 0) j += 1;
            }
            const args_end = j;
            const args = selector[args_start..args_end];
            var removed_all_selectors = false;
            const cleaned_args = try cleanNthPseudoArgs(allocator, args, &removed_all_selectors);
            defer if (cleaned_args.ptr != args.ptr) allocator.free(cleaned_args);
            const after_paren_idx = if (args_end < selector.len) args_end + 1 else args_end;
            if (removed_all_selectors and nthPseudoIsStandalone(selector, i, after_paren_idx)) {
                result.items.len = 0;
                return result.toOwnedSlice(allocator);
            }
            if (cleaned_args.len == 0) {
                result.items.len = 0;
                return result.toOwnedSlice(allocator);
            }

            try result.appendSlice(allocator, nth_name);
            try result.appendSlice(allocator, cleaned_args);
            try result.append(allocator, ')');

            i = after_paren_idx;
            continue;
        }

        var matched_pseudo: ?usize = null;
        for (pseudo_defs, 0..) |pdef, idx| {
            if (i + pdef.name.len <= selector.len and
                std.ascii.eqlIgnoreCase(selector[i..][0..pdef.name.len], pdef.name))
            {
                matched_pseudo = idx;
                break;
            }
        }

        if (matched_pseudo) |pidx| {
            found_any = true;
            const def = pseudo_defs[pidx];
            const args_start = i + def.name.len;

            // Find matching closing paren
            var depth: u32 = 1;
            var j = args_start;
            while (j < selector.len and depth > 0) {
                if (selector[j] == '(') depth += 1;
                if (selector[j] == ')') depth -= 1;
                if (depth > 0) j += 1;
            }
            const args_end = j;
            const args = selector[args_start..args_end];

            // Remove placeholders from the arguments
            var cleaned_args: std.ArrayList(u8) = .empty;
            defer cleaned_args.deinit(allocator);

            var arg_parts = try splitSelectorArguments(allocator, args);
            defer arg_parts.deinit(allocator);

            var first_arg = true;
            for (arg_parts.items) |arg| {
                const trimmed = std.mem.trim(u8, arg, " \t\n\r");
                if (trimmed.len == 0) continue;

                const cleaned_inner = try cleanPlaceholdersInPseudos(allocator, trimmed);
                const trimmed_inner = std.mem.trim(u8, cleaned_inner, " \t\n\r");
                const skip = trimmed_inner.len == 0 or containsPlaceholderToken(trimmed_inner);
                if (!skip) {
                    if (!first_arg) {
                        try cleaned_args.appendSlice(allocator, ", ");
                    }
                    try cleaned_args.appendSlice(allocator, trimmed_inner);
                    first_arg = false;
                }

                if (cleaned_inner.ptr != trimmed.ptr) {
                    const literal_star: []const u8 = "*";
                    if (cleaned_inner.ptr != literal_star.ptr or cleaned_inner.len != 1) {
                        allocator.free(cleaned_inner);
                    }
                }
            }

            if (cleaned_args.items.len > 0) {
                // Has remaining arguments - keep the pseudo with cleaned args
                try result.appendSlice(allocator, def.name);
                try result.appendSlice(allocator, cleaned_args.items);
                try result.append(allocator, ')');
            } else if (def.drop_if_empty) {
                const after_paren_idx = if (args_end < selector.len) args_end + 1 else args_end;
                if (std.mem.eql(u8, def.name, ":not(") and pseudoIsStandalone(selector, i, after_paren_idx)) {
                    // Standalone `:not(%ph)` with no args left matches every element (official Sass CLI).
                    result.deinit(allocator);
                    return "*";
                }
                //Compound `a:not(%ph)`  ->  drop the empty `:not()`, keep `a` (already in result).
                i = after_paren_idx;
                continue;
            } else {
                // Invalid selector: :is(), :where(), :matches(), :has() with no args
                result.items.len = 0;
                return result.toOwnedSlice(allocator);
            }

            i = if (args_end < selector.len) args_end + 1 else args_end;
        } else {
            try result.append(allocator, selector[i]);
            i += 1;
        }
    }

    if (!found_any) {
        result.deinit(allocator);
        return selector;
    }

    // Empty result indicates the selector became invalid after removing placeholders,
    // allowing callers to drop it entirely.
    return result.toOwnedSlice(allocator);
}

fn containsPlaceholderToken(text: []const u8) bool {
    var i: usize = 0;
    var in_string: u8 = 0;
    while (i < text.len) {
        const c = text[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < text.len) {
                i += 2;
                continue;
            }
            if (c == in_string) in_string = 0;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            i += 1;
            continue;
        }
        if (c == '\\' and i + 1 < text.len) {
            i += 2;
            continue;
        }
        if (c == '%' and i + 1 < text.len and isIdentStart(text[i + 1])) {
            return true;
        }
        i += 1;
    }
    return false;
}

/// Split a selector argument list on commas while respecting nested parentheses,
/// brackets, braces, quoted strings, and escapes.
fn splitSelectorArguments(allocator: std.mem.Allocator, args: []const u8) !std.ArrayList([]const u8) {
    var parts: std.ArrayList([]const u8) = .empty;
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
            if (c == in_string) {
                in_string = 0;
            }
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
                    try parts.append(allocator, args[start..i]);
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

    try parts.append(allocator, args[start..]);
    return parts;
}

// ---------------------------------------------------------------------------
// Private sub-helpers used by cleanPlaceholdersInPseudos
// ---------------------------------------------------------------------------

fn cleanNthPseudoArgs(allocator: std.mem.Allocator, args: []const u8, removed_all: *bool) ![]const u8 {
    removed_all.* = false;
    const of_idx = findNthOfClause(args) orelse return args;
    const before = std.mem.trimEnd(u8, args[0..of_idx], " \t\n\r");
    const selector_list = std.mem.trimStart(u8, args[of_idx + 2 ..], " \t\n\r");
    if (selector_list.len == 0) {
        removed_all.* = true;
        return try allocator.dupe(u8, before);
    }
    if (!containsPlaceholderToken(selector_list)) {
        return args;
    }
    const cleaned = try removePlaceholderParts(allocator, selector_list);
    if (cleaned.len == 0) {
        allocator.free(cleaned);
        removed_all.* = true;
        return try allocator.dupe(u8, before);
    }
    const result = try std.mem.concat(allocator, u8, &.{ before, " of ", cleaned });
    allocator.free(cleaned);
    return result;
}

fn nthPseudoIsStandalone(selector: []const u8, pseudo_start: usize, after_paren_idx: usize) bool {
    return pseudoIsStandalone(selector, pseudo_start, after_paren_idx);
}

fn pseudoIsStandalone(selector: []const u8, pseudo_start: usize, after_paren_idx: usize) bool {
    const prefix = selector[0..pseudo_start];
    if (containsNonWhitespace(prefix)) return false;
    const clamped_after = if (after_paren_idx > selector.len) selector.len else after_paren_idx;
    const suffix = selector[clamped_after..];
    if (containsNonWhitespace(suffix)) return false;
    return true;
}

fn containsNonWhitespace(text: []const u8) bool {
    return std.mem.findNone(u8, text, " \t\n\r") != null;
}

fn findNthOfClause(args: []const u8) ?usize {
    var i: usize = 0;
    var in_string: u8 = 0;
    var depth_paren: u32 = 0;
    var depth_bracket: u32 = 0;
    var depth_brace: u32 = 0;
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
            '"', '\'' => {
                in_string = c;
                i += 1;
                continue;
            },
            '(' => {
                depth_paren += 1;
            },
            ')' => {
                if (depth_paren > 0) depth_paren -= 1;
            },
            '[' => {
                depth_bracket += 1;
            },
            ']' => {
                if (depth_bracket > 0) depth_bracket -= 1;
            },
            '{' => {
                depth_brace += 1;
            },
            '}' => {
                if (depth_brace > 0) depth_brace -= 1;
            },
            '\\' => {
                if (i + 1 < args.len) {
                    i += 2;
                } else {
                    i += 1;
                }
                continue;
            },
            else => {},
        }
        if (depth_paren == 0 and depth_bracket == 0 and depth_brace == 0 and
            std.ascii.toLower(c) == 'o' and
            i + 1 < args.len and std.ascii.toLower(args[i + 1]) == 'f' and
            nthClauseBoundaryBefore(args, i) and nthClauseBoundaryAfter(args, i + 2))
        {
            return i;
        }
        i += 1;
    }
    return null;
}

fn nthClauseBoundaryBefore(args: []const u8, idx: usize) bool {
    if (idx == 0) return true;
    const prev = args[idx - 1];
    if (std.ascii.isWhitespace(prev)) return true;
    return !isIdentChar(prev);
}

fn nthClauseBoundaryAfter(args: []const u8, idx: usize) bool {
    if (idx >= args.len) return true;
    const ch = args[idx];
    if (std.ascii.isWhitespace(ch)) return true;
    return !isIdentChar(ch);
}

// ---------------------------------------------------------------------------
// Tests (moved from evaluator.zig)
// ---------------------------------------------------------------------------

test "removePlaceholderParts drops placeholder tokens inside pseudo selectors" {
    const allocator = std.testing.allocator;
    const cleaned = try removePlaceholderParts(
        allocator,
        ":is(.retain %ghost, %ghost .chain, .keep, :is(%ghost, .also))",
    );
    defer allocator.free(cleaned);
    try std.testing.expectEqualStrings(":is(.keep, :is(.also))", cleaned);
}

test "removePlaceholderParts drops placeholder selectors from nth-child of clauses" {
    const allocator = std.testing.allocator;
    const cleaned = try removePlaceholderParts(
        allocator,
        "a:nth-child(2n of .foo %ghost, .bar, %ghost .baz)",
    );
    defer allocator.free(cleaned);
    try std.testing.expectEqualStrings("a:nth-child(2n of .bar)", cleaned);
}

test "removePlaceholderParts returns empty when every branch was placeholder-backed" {
    const allocator = std.testing.allocator;
    const cleaned = try removePlaceholderParts(allocator, ":is(.only %ghost, %ghost .also)");
    defer allocator.free(cleaned);
    try std.testing.expectEqual(@as(usize, 0), cleaned.len);
}

test "removePlaceholderParts rewrites standalone :not() with only placeholders to universal *" {
    const allocator = std.testing.allocator;
    const cleaned = try removePlaceholderParts(allocator, ":not(%ghost)");
    defer allocator.free(cleaned);
    try std.testing.expectEqualStrings("*", cleaned);
}

test "removePlaceholderParts preserves commas inside attribute strings" {
    const allocator = std.testing.allocator;
    const cleaned = try removePlaceholderParts(allocator, "[data-test=\"a,b\"], %ghost");
    defer allocator.free(cleaned);
    try std.testing.expectEqualStrings("[data-test=\"a,b\"]", cleaned);
}
