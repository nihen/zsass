/// Pure evaluator helpers for interpolation detection and at-rule prelude handling.
const std = @import("std");
const expr_scan = @import("../runtime/expr_scan.zig");
const string_scan = @import("../frontend/string_scan.zig");

const isIdentChar = expr_scan.isIdentChar;

fn findMatchingParen(text: []const u8, start: usize) ?usize {
    var depth: u32 = 0;
    var in_string: u8 = 0;
    var interpolation_depth: u32 = 0;
    var i = start;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_string != 0) {
            if (ch == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (ch == '#' and i + 1 < text.len and text[i + 1] == '{') {
                interpolation_depth += 1;
                i += 1;
                continue;
            }
            if (interpolation_depth > 0) {
                if (ch == '{') {
                    interpolation_depth += 1;
                } else if (ch == '}') {
                    interpolation_depth -= 1;
                }
                continue;
            }
            if (ch == in_string) in_string = 0;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            in_string = ch;
            continue;
        }
        if (ch == '(') depth += 1;
        if (ch == ')') {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

const ParsedMediaQuery = struct {
    modifier: ?[]const u8, // "not" or "only" or null
    media_type: ?[]const u8, // "screen", "print", "all", etc. or null
    features: []const []const u8, // "(color)", "(min-width: 300px)", etc.
};

/// Result of merging two media queries.
const MediaMergeResult = union(enum) {
    /// The intersection can be expressed as a single query string.
    merged: []const u8,
    /// The intersection is provably empty (incompatible).
    empty,
    /// The intersection exists but cannot be expressed as a single query.
    unresolvable,
};

fn splitMediaQueriesAlloc(allocator: std.mem.Allocator, text: []const u8) !std.ArrayList([]const u8) {
    var queries: std.ArrayList([]const u8) = .empty;
    var comma_count: usize = 0;
    for (text) |c| {
        if (c == ',') comma_count += 1;
    }
    try queries.ensureTotalCapacity(allocator, comma_count + 1);
    var paren_depth: u32 = 0;
    var start: usize = 0;
    for (text, 0..) |c, i| {
        switch (c) {
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            ',' => if (paren_depth == 0) {
                const q = std.mem.trim(u8, text[start..i], " \t\n\r");
                if (q.len > 0) {
                    try queries.append(allocator, q);
                }
                start = i + 1;
            },
            else => {},
        }
    }
    const last = std.mem.trim(u8, text[start..], " \t\n\r");
    if (last.len > 0) {
        try queries.append(allocator, last);
    }
    return queries;
}

/// Check if a string is a known media type.
fn isMediaType(s: []const u8) bool {
    const types = [_][]const u8{ "all", "screen", "print", "speech", "tty", "tv", "projection", "handheld", "braille", "embossed", "aural" };
    for (types) |t| {
        if (std.ascii.eqlIgnoreCase(s, t)) return true;
    }
    return false;
}

/// Parse a single media query (no commas) into structured components.
fn parseMediaQuery(query: []const u8) ParsedMediaQuery {
    const trimmed = std.mem.trim(u8, query, " \t\n\r");
    if (trimmed.len == 0) return .{ .modifier = null, .media_type = null, .features = &.{} };

    // If it starts with '(' it's just features, no type
    if (trimmed[0] == '(') {
        return .{ .modifier = null, .media_type = null, .features = &.{} };
    }

    // Check for modifier (not/only)
    var rest = trimmed;
    var modifier: ?[]const u8 = null;
    if (startsWithMediaKeyword(rest, "not")) {
        modifier = "not";
        rest = std.mem.trimStart(u8, rest[3..], " \t");
    } else if (startsWithMediaKeyword(rest, "only")) {
        modifier = "only";
        rest = std.mem.trimStart(u8, rest[4..], " \t");
    }

    // Extract media type (next word before "and" or "(")
    var type_end: usize = 0;
    while (type_end < rest.len and rest[type_end] != ' ' and rest[type_end] != '\t' and rest[type_end] != '(') : (type_end += 1) {}
    const media_type = if (type_end > 0) rest[0..type_end] else null;

    return .{
        .modifier = modifier,
        .media_type = media_type,
        .features = &.{}, // features handled separately
    };
}

/// Extract all parenthesized feature expressions from a query string.
fn extractMediaFeatures(allocator: std.mem.Allocator, query: []const u8) !std.ArrayList([]const u8) {
    var features: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < query.len) {
        if (query[i] == '(') {
            if (findMatchingParen(query, i)) |close| {
                try features.append(allocator, query[i .. close + 1]);
                i = close + 1;
                continue;
            }
        }
        i += 1;
    }
    return features;
}

/// Check if query explicitly uses "all" keyword (not just implicit).
fn hasExplicitAll(query: ParsedMediaQuery) bool {
    return query.media_type != null and std.ascii.eqlIgnoreCase(query.media_type.?, "all") and query.modifier == null;
}

/// Merge two individual media queries (no commas).
/// Returns merged string (caller owns), .empty, or .unresolvable.
fn mergeTwoMediaQueries(allocator: std.mem.Allocator, parent: []const u8, child: []const u8) !MediaMergeResult {
    const pq = parseMediaQuery(parent);
    const cq = parseMediaQuery(child);

    // Extract features from both
    var parent_features = try extractMediaFeatures(allocator, parent);
    defer parent_features.deinit(allocator);
    var child_features = try extractMediaFeatures(allocator, child);
    defer child_features.deinit(allocator);

    const p_type = pq.media_type orelse "all";
    const c_type = cq.media_type orelse "all";
    const p_mod = pq.modifier;
    const c_mod = cq.modifier;
    const p_is_not = p_mod != null and std.mem.eql(u8, p_mod.?, "not");
    const c_is_not = c_mod != null and std.mem.eql(u8, c_mod.?, "not");

    // Both have "not" modifier
    if (p_is_not and c_is_not) {
        // "not X" + "not X and (features)" = "not X and (features)" (narrower wins)
        // "not X" + "not Y" = unresolvable (can't combine)
        // "not X and (f1)" + "not X and (f2)" = unresolvable
        if (std.ascii.eqlIgnoreCase(p_type, c_type)) {
            // Same type with "not"
            if (parent_features.items.len == 0 and child_features.items.len == 0) {
                // "not screen" + "not screen" = "not screen"
                return .{ .merged = try allocator.dupe(u8, parent) };
            }
            if (parent_features.items.len == 0) {
                // "not screen" + "not screen and (color)" = "not screen and (color)"
                return .{ .merged = try allocator.dupe(u8, child) };
            }
            if (child_features.items.len == 0) {
                // "not screen and (color)" + "not screen" = "not screen and (color)"
                return .{ .merged = try allocator.dupe(u8, parent) };
            }
            // Both have features: "not screen and (f1)" + "not screen and (f2)"
            // This is unresolvable
            return .unresolvable;
        }
        // Different types with "not": e.g. "not screen" + "not print"
        return .unresolvable;
    }

    // One has "not" modifier
    if (p_is_not) {
        return mergeNotWithPositive(allocator, pq, parent_features.items, cq, child_features.items, child);
    }
    if (c_is_not) {
        return mergeNotWithPositive(allocator, cq, child_features.items, pq, parent_features.items, parent);
    }

    // Neither has "not" -- both are positive queries
    const p_is_all = std.ascii.eqlIgnoreCase(p_type, "all");
    const c_is_all = std.ascii.eqlIgnoreCase(c_type, "all");

    if (!p_is_all and !c_is_all and !std.ascii.eqlIgnoreCase(p_type, c_type)) {
        // Different explicit types (e.g., screen + print) = empty
        return .empty;
    }

    // Determine the resulting type and modifier
    var result_modifier: ?[]const u8 = null;
    // SAFETY: initialized before first read in this scope.
    var result_type: []const u8 = undefined;
    const p_explicit_all = hasExplicitAll(pq) and parent_features.items.len > 0;
    const c_explicit_all = hasExplicitAll(cq) and child_features.items.len > 0;

    if (!p_is_all and !c_is_all) {
        // Same type
        result_type = p_type;
        // Preserve "only" if either has it
        if ((p_mod != null and std.mem.eql(u8, p_mod.?, "only")) or
            (c_mod != null and std.mem.eql(u8, c_mod.?, "only")))
        {
            result_modifier = "only";
        }
    } else if (p_is_all and c_is_all) {
        // Both are "all"
        result_type = "all";
    } else if (p_is_all) {
        // Parent is "all" (implicit or explicit), child has specific type
        result_type = c_type;
        if (c_mod != null and std.mem.eql(u8, c_mod.?, "only")) {
            result_modifier = "only";
        }
    } else {
        // Child is "all" (implicit or explicit), parent has specific type
        result_type = p_type;
        if (p_mod != null and std.mem.eql(u8, p_mod.?, "only")) {
            result_modifier = "only";
        }
    }

    // Build result string
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const type_is_all = std.ascii.eqlIgnoreCase(result_type, "all");

    if (result_modifier) |mod| {
        try buf.appendSlice(allocator, mod);
        try buf.append(allocator, ' ');
        try buf.appendSlice(allocator, result_type);
    } else if (!type_is_all) {
        try buf.appendSlice(allocator, result_type);
    } else if (type_is_all and p_explicit_all and c_explicit_all) {
        // Keep explicit "all" only if BOTH sides had explicit "all and"
        try buf.appendSlice(allocator, "all");
    }

    // Append all features from parent, then child
    for (parent_features.items) |feat| {
        if (buf.items.len > 0) {
            try buf.appendSlice(allocator, " and ");
        }
        try buf.appendSlice(allocator, feat);
    }
    for (child_features.items) |feat| {
        if (buf.items.len > 0) {
            try buf.appendSlice(allocator, " and ");
        }
        try buf.appendSlice(allocator, feat);
    }

    if (buf.items.len == 0) {
        buf.deinit(allocator);
        return .empty;
    }

    return .{ .merged = try buf.toOwnedSlice(allocator) };
}

/// Handle merging a "not TYPE [and FEATURES]" query with a positive query.
fn mergeNotWithPositive(
    allocator: std.mem.Allocator,
    not_query: ParsedMediaQuery,
    not_features: []const []const u8,
    pos_query: ParsedMediaQuery,
    pos_features: []const []const u8,
    pos_original: []const u8,
) !MediaMergeResult {
    const not_type = not_query.media_type orelse "all";
    const not_is_all = std.ascii.eqlIgnoreCase(not_type, "all");
    const pos_type_raw = pos_query.media_type orelse "all";
    const pos_is_all = std.ascii.eqlIgnoreCase(pos_type_raw, "all");

    if (not_query.media_type == null and not_features.len > 0) {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        try buf.appendSlice(allocator, "(not ");
        try buf.appendSlice(allocator, not_features[0]);
        try buf.append(allocator, ')');
        for (not_features[1..]) |feature| {
            try buf.appendSlice(allocator, " and ");
            try buf.appendSlice(allocator, feature);
        }
        try buf.appendSlice(allocator, " and ");
        try buf.appendSlice(allocator, pos_original);
        return .{ .merged = try buf.toOwnedSlice(allocator) };
    }

    // "not all and (features)" is special: it means "not (all and features)" = "no type with these features"
    // This is unresolvable with any positive query that doesn't negate those features
    if (not_is_all) {
        // "not all and (color)" + anything = unresolvable (we can't express "screen and not (color)")
        return .unresolvable;
    }

    // "not TYPE" (without features) means "everything except TYPE"
    // "not TYPE and (features)" means "not (TYPE and features)" = everything except TYPE-with-features

    if (!pos_is_all and !std.ascii.eqlIgnoreCase(not_type, pos_type_raw)) {
        // Different types: "not screen" + "print [and features]" => "print [and features]"
        // The positive query's type is completely unaffected by "not OTHER_TYPE"
        return .{ .merged = try allocator.dupe(u8, pos_original) };
    }

    if (!pos_is_all and std.ascii.eqlIgnoreCase(not_type, pos_type_raw)) {
        // Same type: "not TYPE [and features_n]" + "TYPE [and features_p]"
        if (not_features.len == 0) {
            // "not TYPE" + "TYPE [and features]" = empty
            // "not screen" + "screen" = empty
            // "not screen" + "screen and (color)" = empty (screen is entirely excluded)
            return .empty;
        }
        // "not TYPE and (features_n)" + "TYPE [and features_p]"
        // Check if positive features are a superset of not features
        // e.g., "not screen and (color)" + "screen and (color)" = empty
        //       "not screen and (color)" + "screen and (color) and (grid)" = empty
        //       "not screen and (color)" + "screen" = unresolvable (overlap exists)
        //       "not screen and (color)" + "screen and (grid)" = unresolvable
        if (allFeaturesPresent(not_features, pos_features)) {
            return .empty;
        }
        return .unresolvable;
    }

    // pos_is_all: "not TYPE [and features]" + "(features)" or "all and (features)"
    // e.g., "not screen" + "(color)" = unresolvable
    //       "not screen and (color)" + "(grid)" = unresolvable
    return .unresolvable;
}

/// Check if all features in `required` are present in `available`.
fn allFeaturesPresent(required: []const []const u8, available: []const []const u8) bool {
    for (required) |req| {
        var found = false;
        for (available) |avail| {
            if (std.mem.eql(u8, req, avail)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn hasTopLevelMediaOr(text: []const u8) bool {
    var i: usize = 0;
    var paren_depth: u32 = 0;
    var bracket_depth: u32 = 0;
    var in_string: u8 = 0;
    var interp_depth: u32 = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (interp_depth > 0) {
            switch (c) {
                '{' => interp_depth += 1,
                '}' => {
                    interp_depth -= 1;
                },
                else => {},
            }
            continue;
        }
        if (in_string != 0) {
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
            } else if (c == '#' and i + 1 < text.len and text[i + 1] == '{') {
                interp_depth = 1;
                i += 1;
            } else if (c == in_string) {
                in_string = 0;
            }
            continue;
        }
        switch (c) {
            '#' => if (i + 1 < text.len and text[i + 1] == '{') {
                interp_depth = 1;
                i += 1;
            },
            '"', '\'' => in_string = c,
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            'o', 'O' => {
                if (paren_depth == 0 and bracket_depth == 0 and mediaKeywordAt(text, i, "or")) return true;
            },
            else => {},
        }
    }
    return false;
}

/// Merge two potentially comma-separated media query lists.
/// Returns: merged prelude string (caller owns), null for empty, or error.
/// For unresolvable queries, returns the special sentinel "UNRESOLVABLE".
pub const MEDIA_MERGE_UNRESOLVABLE: []const u8 = "<<UNRESOLVABLE>>";

pub fn mergeMediaQueryLists(allocator: std.mem.Allocator, parent: []const u8, child: []const u8) !?[]const u8 {
    if (hasTopLevelMediaOr(parent) or hasTopLevelMediaOr(child)) {
        return MEDIA_MERGE_UNRESOLVABLE;
    }

    var parent_queries = try splitMediaQueriesAlloc(allocator, parent);
    defer parent_queries.deinit(allocator);
    var child_queries = try splitMediaQueriesAlloc(allocator, child);
    defer child_queries.deinit(allocator);

    // Check if any pair is unresolvable - if so, the whole thing is unresolvable
    // (per Sass spec: if any query in a comma list can't be merged, keep all nested)
    var merged_parts: std.ArrayList([]const u8) = .empty;
    defer {
        for (merged_parts.items) |p| allocator.free(p);
        merged_parts.deinit(allocator);
    }
    try merged_parts.ensureTotalCapacity(allocator, parent_queries.items.len * child_queries.items.len);

    for (parent_queries.items) |pq| {
        for (child_queries.items) |cq| {
            const result = try mergeTwoMediaQueries(allocator, pq, cq);
            switch (result) {
                .merged => |m| try merged_parts.append(allocator, m),
                .empty => {}, // Skip empty intersections
                .unresolvable => {
                    // If ANY pair is unresolvable, the whole merge is unresolvable
                    return MEDIA_MERGE_UNRESOLVABLE;
                },
            }
        }
    }

    if (merged_parts.items.len == 0) {
        return null; // All empty
    }

    // Join with ", "
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (merged_parts.items, 0..) |part, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, part);
    }
    return try buf.toOwnedSlice(allocator);
}

pub fn findTopLevelMediaRangeOperator(text: []const u8) ?usize {
    var i: usize = 0;
    var paren_depth: u32 = 0;
    var bracket_depth: u32 = 0;
    var in_string: u8 = 0;
    var interp_depth: u32 = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (interp_depth > 0) {
            switch (c) {
                '{' => interp_depth += 1,
                '}' => {
                    interp_depth -= 1;
                },
                else => {},
            }
            continue;
        }
        if (in_string != 0) {
            if (c == '\\' and i + 1 < text.len) i += 1 else if (c == in_string) in_string = 0;
            continue;
        }
        switch (c) {
            '#' => if (i + 1 < text.len and text[i + 1] == '{') {
                interp_depth = 1;
                i += 1;
            },
            '"', '\'' => in_string = c,
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            '<', '>', '=' => if (paren_depth == 0 and bracket_depth == 0) return i,
            else => {},
        }
    }
    return null;
}

pub fn matchTopLevelMediaRangeOperator(text: []const u8, pos: usize) ?usize {
    var paren_depth: u32 = 0;
    var bracket_depth: u32 = 0;
    var in_string: u8 = 0;
    var interp_depth: u32 = 0;
    var i: usize = 0;
    while (i < pos and i < text.len) : (i += 1) {
        const c = text[i];
        if (interp_depth > 0) {
            switch (c) {
                '{' => interp_depth += 1,
                '}' => {
                    interp_depth -= 1;
                },
                else => {},
            }
            continue;
        }
        if (in_string != 0) {
            if (c == '\\' and i + 1 < text.len) i += 1 else if (c == in_string) in_string = 0;
            continue;
        }
        switch (c) {
            '#' => if (i + 1 < text.len and text[i + 1] == '{') {
                interp_depth = 1;
                i += 1;
            },
            '"', '\'' => in_string = c,
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            else => {},
        }
    }
    if (interp_depth != 0 or paren_depth != 0 or bracket_depth != 0 or pos >= text.len) return null;
    return switch (text[pos]) {
        '<', '>' => if (pos + 1 < text.len and text[pos + 1] == '=') 2 else 1,
        '=' => 1,
        else => null,
    };
}

pub fn looksLikeMediaLogicalCondition(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\n\r");
    if (trimmed.len == 0) return false;
    if (startsWithMediaKeyword(trimmed, "not")) return true;

    var i: usize = 0;
    var paren_depth: u32 = 0;
    var bracket_depth: u32 = 0;
    var in_string: u8 = 0;
    while (i < trimmed.len) : (i += 1) {
        const c = trimmed[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < trimmed.len) {
                i += 1;
            } else if (c == in_string) {
                in_string = 0;
            }
            continue;
        }
        switch (c) {
            '"', '\'' => in_string = c,
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            'a', 'A' => {
                if (paren_depth == 0 and bracket_depth == 0 and mediaKeywordAt(trimmed, i, "and")) return true;
            },
            'o', 'O' => {
                if (paren_depth == 0 and bracket_depth == 0 and mediaKeywordAt(trimmed, i, "or")) return true;
            },
            else => {},
        }
    }
    return false;
}

fn startsWithMediaKeyword(text: []const u8, keyword: []const u8) bool {
    if (text.len < keyword.len) return false;
    if (!std.ascii.eqlIgnoreCase(text[0..keyword.len], keyword)) return false;
    return text.len == keyword.len or !isIdentChar(text[keyword.len]);
}

fn mediaKeywordAt(text: []const u8, idx: usize, keyword: []const u8) bool {
    if (idx + keyword.len > text.len) return false;
    if (!std.ascii.eqlIgnoreCase(text[idx .. idx + keyword.len], keyword)) return false;
    if (idx > 0 and isIdentChar(text[idx - 1])) return false;
    if (idx + keyword.len < text.len and isIdentChar(text[idx + keyword.len])) return false;
    return true;
}

pub fn isMediaRatioLiteral(text: []const u8) bool {
    const slash = std.mem.findScalar(u8, text, '/') orelse return false;
    if (std.mem.findScalarLast(u8, text, '/') != slash) return false;
    if (slash == 0 or slash + 1 >= text.len) return false;
    for (text) |c| {
        if (c == '/') continue;
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') return false;
        if (std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '%' or c == '_') continue;
        return false;
    }
    return true;
}

/// Normalize media/supports keywords (and, or, not) to lowercase.
/// Also ensures space between ) and keyword, and space between keyword and (.
/// Returns the original slice if no changes were needed.
pub fn normalizeMediaKeywords(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    // Quick check: scan for mixed-case and/or/not keywords at word boundaries
    var needs_normalize = false;
    var ci: usize = 0;
    while (ci < text.len) {
        // Skip non-alpha
        if (!std.ascii.isAlphabetic(text[ci])) {
            ci += 1;
            continue;
        }
        // At a word start - check if it's and/or/not with mixed case
        const remaining = text[ci..];
        if (remaining.len >= 3 and std.ascii.eqlIgnoreCase(remaining[0..3], "and") and
            (remaining.len == 3 or !isIdentChar(remaining[3])))
        {
            if (!std.mem.eql(u8, remaining[0..3], "and")) {
                needs_normalize = true;
                break;
            }
            ci += 3;
            continue;
        }
        if (remaining.len >= 3 and std.ascii.eqlIgnoreCase(remaining[0..3], "not") and
            (remaining.len == 3 or !isIdentChar(remaining[3])))
        {
            if (!std.mem.eql(u8, remaining[0..3], "not")) {
                needs_normalize = true;
                break;
            }
            ci += 3;
            continue;
        }
        if (remaining.len >= 2 and std.ascii.eqlIgnoreCase(remaining[0..2], "or") and
            (remaining.len == 2 or !isIdentChar(remaining[2])))
        {
            if (!std.mem.eql(u8, remaining[0..2], "or")) {
                needs_normalize = true;
                break;
            }
            ci += 2;
            continue;
        }
        // Skip rest of identifier
        while (ci < text.len and isIdentChar(text[ci])) : (ci += 1) {}
    }
    // Also check for missing space: )and or )or or )not
    if (!needs_normalize) {
        if (std.mem.find(u8, text, ")and") != null or
            std.mem.find(u8, text, ")or") != null or
            std.mem.find(u8, text, ")not") != null)
        {
            needs_normalize = true;
        }
    }
    if (!needs_normalize) return text;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var i: usize = 0;
    var in_string: u8 = 0;
    while (i < text.len) {
        if (try string_scan.consumeStringQuoting(allocator, &buf, text, &i, &in_string)) continue;
        const c = text[i];

        // Check for keywords (and, or, not) that need lowercasing or space insertion
        const remaining = text[i..];
        if (remaining.len >= 3 and std.ascii.eqlIgnoreCase(remaining[0..3], "and") and
            (remaining.len == 3 or !isIdentChar(remaining[3])))
        {
            // Ensure space before keyword
            if (buf.items.len > 0 and buf.items[buf.items.len - 1] == ')') {
                try buf.append(allocator, ' ');
            }
            try buf.appendSlice(allocator, "and");
            i += 3;
            continue;
        }
        if (remaining.len >= 3 and std.ascii.eqlIgnoreCase(remaining[0..3], "not") and
            (remaining.len == 3 or !isIdentChar(remaining[3])))
        {
            // Ensure space before keyword
            if (buf.items.len > 0 and buf.items[buf.items.len - 1] == ')') {
                try buf.append(allocator, ' ');
            }
            try buf.appendSlice(allocator, "not");
            i += 3;
            continue;
        }
        if (remaining.len >= 2 and std.ascii.eqlIgnoreCase(remaining[0..2], "or") and
            (remaining.len == 2 or !isIdentChar(remaining[2])))
        {
            // Ensure space before keyword
            if (buf.items.len > 0 and buf.items[buf.items.len - 1] == ')') {
                try buf.append(allocator, ' ');
            }
            try buf.appendSlice(allocator, "or");
            i += 2;
            continue;
        }

        try buf.append(allocator, c);
        i += 1;
    }

    return buf.toOwnedSlice(allocator);
}

/// Collapse whitespace in @import supports() content.
/// Replaces any whitespace sequence containing a newline with a single space,
/// preserving spaces adjacent to parens (unlike normalizePreludeWhitespace).
/// Also strips space before `:` for proper declaration formatting.
pub fn collapseImportSupportsWhitespace(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    // Quick check: if no newlines, return as-is
    if (std.mem.find(u8, text, "\n") == null and std.mem.find(u8, text, "\r") == null) return text;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var i: usize = 0;
    var in_string: u8 = 0;
    while (i < text.len) {
        if (try string_scan.consumeStringQuoting(allocator, &buf, text, &i, &in_string)) continue;
        const c = text[i];
        if (c == '\n' or c == '\r') {
            // Replace newline + surrounding whitespace with a single space
            while (i < text.len and (text[i] == ' ' or text[i] == '\t' or
                text[i] == '\n' or text[i] == '\r'))
            {
                i += 1;
            }
            // Don't add space before ':' (for proper declaration formatting)
            if (i < text.len and text[i] == ':') {
                continue;
            }
            // Don't add space if buf already ends with a space
            if (buf.items.len > 0 and buf.items[buf.items.len - 1] == ' ') {
                continue;
            }
            try buf.append(allocator, ' ');
            continue;
        }
        try buf.append(allocator, c);
        i += 1;
    }

    return buf.toOwnedSlice(allocator);
}
pub fn normalizePreludeWhitespaceWithOptions(
    allocator: std.mem.Allocator,
    text: []const u8,
    preserve_space_before_colon: bool,
) ![]const u8 {
    // Quick check: if no newlines, multiple spaces, tabs, or space-before-colon, return as-is
    var needs_normalize = false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n' or text[i] == '\r' or text[i] == '\x0c') {
            needs_normalize = true;
            break;
        }
        if (text[i] == ' ' and i + 1 < text.len and text[i + 1] == ' ') {
            needs_normalize = true;
            break;
        }
        if (text[i] == '\t') {
            needs_normalize = true;
            break;
        }
        // Check for space before colon (e.g., after comment stripping)
        if (!preserve_space_before_colon and text[i] == ' ' and i + 1 < text.len and text[i + 1] == ':') {
            needs_normalize = true;
            break;
        }
    }
    if (!needs_normalize) return text;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    i = 0;
    var in_string: u8 = 0;
    while (i < text.len) {
        if (try string_scan.consumeStringQuoting(allocator, &buf, text, &i, &in_string)) continue;
        const c = text[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0c') {
            // Collapse whitespace to single space
            while (i < text.len and (text[i] == ' ' or text[i] == '\t' or
                text[i] == '\n' or text[i] == '\r' or text[i] == '\x0c'))
            {
                i += 1;
            }
            // Don't add space after ( or [ or at start
            if (buf.items.len > 0) {
                const last = buf.items[buf.items.len - 1];
                // Don't add space before ) or ] or :
                const next_char = if (i < text.len) text[i] else 0;
                if (last != '(' and last != '[' and
                    next_char != ')' and next_char != ']' and
                    (preserve_space_before_colon or next_char != ':'))
                {
                    try buf.append(allocator, ' ');
                }
            }
            continue;
        }
        try buf.append(allocator, c);
        i += 1;
    }

    return buf.toOwnedSlice(allocator);
}

pub fn removeSpaceBeforeMediaCommas(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.find(u8, text, " ,") == null) return text;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var in_string: u8 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string != 0) {
            try buf.append(allocator, c);
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                try buf.append(allocator, text[i]);
                continue;
            }
            if (c == in_string) in_string = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            try buf.append(allocator, c);
            continue;
        }
        if (c == ' ' and i + 1 < text.len and text[i + 1] == ',') {
            continue;
        }
        try buf.append(allocator, c);
    }

    return buf.toOwnedSlice(allocator);
}
fn isParenthesizedMediaFeatureList(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r')) : (i += 1) {}
        if (i >= text.len or text[i] != '(') return false;
        const close = findMatchingParen(text, i) orelse return false;
        i = close + 1;
        while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r')) : (i += 1) {}
        if (i >= text.len) return true;
        if (!startsWithMediaKeyword(text[i..], "and")) return false;
        i += 3;
    }
    return text.len > 0;
}

fn simplifyNegatedMediaType(rest: []const u8) ?[]const u8 {
    if (rest.len < 2 or rest[0] != '(') return null;
    const close = findMatchingParen(rest, 0) orelse return null;
    if (close != rest.len - 1) return null;

    const inner = std.mem.trim(u8, rest[1..close], " \t\n\r");
    if (inner.len == 0) return null;

    var type_end: usize = 0;
    while (type_end < inner.len and inner[type_end] != ' ' and inner[type_end] != '\t' and inner[type_end] != '\n' and inner[type_end] != '\r') : (type_end += 1) {}
    if (type_end == 0) return null;

    const media_type = inner[0..type_end];
    if (!isMediaType(media_type) or std.ascii.eqlIgnoreCase(media_type, "all")) return null;

    const tail = std.mem.trimStart(u8, inner[type_end..], " \t\n\r");
    if (!startsWithMediaKeyword(tail, "and")) return null;

    const features = std.mem.trimStart(u8, tail[3..], " \t\n\r");
    if (!isParenthesizedMediaFeatureList(features)) return null;
    return features;
}

fn unwrapSingleMediaNot(allocator: std.mem.Allocator, text: []const u8, lowercase_only: bool) ![]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\n\r");
    if (trimmed.len < 3) return text;
    if (trimmed[0] != '(') return text;
    if (trimmed[trimmed.len - 1] != ')') return text;

    // Check that the outer parens encompass the entire expression
    // by finding the matching close paren for the opening one
    var depth: u32 = 1;
    var i: usize = 1;
    while (i < trimmed.len - 1) : (i += 1) {
        if (trimmed[i] == '(') depth += 1;
        if (trimmed[i] == ')') {
            depth -= 1;
            if (depth == 0) break;
        }
    }
    // If depth reached 0 before the last char, the outer parens don't match
    if (i < trimmed.len - 1) return text;

    // Extract inner content and check for "not (" pattern
    const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\n\r");

    // Check for "not " prefix
    if (inner.len > 4 and inner[3] == ' ') {
        const is_lowercase_not = inner[0] == 'n' and inner[1] == 'o' and inner[2] == 't';
        const is_any_case_not = (inner[0] == 'n' or inner[0] == 'N') and
            (inner[1] == 'o' or inner[1] == 'O') and
            (inner[2] == 't' or inner[2] == 'T');
        const matches = if (lowercase_only) is_lowercase_not else is_any_case_not;
        if (matches) {
            const rest = std.mem.trim(u8, inner[4..], " \t\n\r");
            if (rest.len > 0 and rest[0] == '(') {
                if (simplifyNegatedMediaType(rest)) |features| {
                    return std.mem.concat(allocator, u8, &.{ "not ", features });
                }
                // Normalize to lowercase "not" (Sass always normalizes keywords)
                return std.mem.concat(allocator, u8, &.{ "not ", rest });
            }
        }
    }

    return text;
}

pub fn unwrapMediaNot(allocator: std.mem.Allocator, text: []const u8, lowercase_only: bool) ![]const u8 {
    var queries = try splitMediaQueriesAlloc(allocator, text);
    defer queries.deinit(allocator);

    if (queries.items.len <= 1) return unwrapSingleMediaNot(allocator, text, lowercase_only);

    var rebuilt: std.ArrayList(u8) = .empty;
    errdefer rebuilt.deinit(allocator);
    var changed = false;

    for (queries.items, 0..) |query, idx| {
        const unwrapped = try unwrapSingleMediaNot(allocator, query, lowercase_only);
        defer if (unwrapped.ptr != query.ptr) allocator.free(unwrapped);

        if (idx > 0) try rebuilt.appendSlice(allocator, ", ");
        try rebuilt.appendSlice(allocator, unwrapped);
        if (unwrapped.ptr != query.ptr or !std.mem.eql(u8, unwrapped, query)) changed = true;
    }

    if (!changed) {
        rebuilt.deinit(allocator);
        return text;
    }

    return rebuilt.toOwnedSlice(allocator);
}
