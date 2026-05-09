const std = @import("std");
const prelude = @import("prelude.zig");
const ir_validate = @import("../ir/validate.zig");
const comment_strip = @import("../frontend/comment_strip.zig");
const expr_scan = @import("../runtime/expr_scan.zig");

pub const MEDIA_MERGE_UNRESOLVABLE = prelude.MEDIA_MERGE_UNRESOLVABLE;
pub const mergeMediaQueryLists = prelude.mergeMediaQueryLists;
pub const findTopLevelMediaRangeOperator = prelude.findTopLevelMediaRangeOperator;
pub const matchTopLevelMediaRangeOperator = prelude.matchTopLevelMediaRangeOperator;
pub const looksLikeMediaLogicalCondition = prelude.looksLikeMediaLogicalCondition;
pub const isMediaRatioLiteral = prelude.isMediaRatioLiteral;
pub const normalizePreludeWhitespaceWithOptions = prelude.normalizePreludeWhitespaceWithOptions;
pub const normalizeMediaKeywords = prelude.normalizeMediaKeywords;
pub const removeSpaceBeforeMediaCommas = prelude.removeSpaceBeforeMediaCommas;
pub const unwrapMediaNot = prelude.unwrapMediaNot;
pub const validateMediaQueryPrelude = ir_validate.validateMediaQueryPrelude;
pub const stripPreludeComments = comment_strip.stripPreludeComments;
pub const stripSupportsComments = comment_strip.stripSupportsComments;

pub fn mediaPreludeHasLineBreakBeforeLogicKeyword(text: []const u8) bool {
    var i: usize = 0;
    var in_string: u8 = 0;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;

    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (c == in_string and !expr_scan.isEscapedCharacter(text, i)) in_string = 0;
            continue;
        }
        if ((c == '"' or c == '\'') and !expr_scan.isEscapedCharacter(text, i)) {
            in_string = c;
            continue;
        }

        switch (c) {
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

        if (paren_depth != 0 or bracket_depth != 0) continue;
        if (!std.ascii.isWhitespace(c)) continue;

        var saw_newline = c == '\n' or c == '\r';
        var j = i + 1;
        while (j < text.len and std.ascii.isWhitespace(text[j])) : (j += 1) {
            if (text[j] == '\n' or text[j] == '\r') saw_newline = true;
        }
        if (!saw_newline or j >= text.len) continue;

        if (j + 3 <= text.len and
            ((text[j] == 'a' and text[j + 1] == 'n' and text[j + 2] == 'd') or
                (text[j] == 'o' and text[j + 1] == 'r') or
                (text[j] == 'n' and text[j + 1] == 'o' and text[j + 2] == 't')))
        {
            const after = if (text[j] == 'o' and text[j + 1] == 'r') j + 2 else j + 3;
            if (after == text.len or text[after] == ' ' or text[after] == '\t' or text[after] == '(' or text[after] == '{') {
                return true;
            }
        }
    }
    return false;
}

pub fn mediaPreludeHasLineBreakAfterLogicKeyword(text: []const u8) bool {
    var i: usize = 0;
    var in_string: u8 = 0;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;

    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (c == in_string and !expr_scan.isEscapedCharacter(text, i)) in_string = 0;
            continue;
        }
        if ((c == '"' or c == '\'') and !expr_scan.isEscapedCharacter(text, i)) {
            in_string = c;
            continue;
        }

        switch (c) {
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

        if (paren_depth != 0 or bracket_depth != 0) continue;

        const before_ok = i == 0 or !(std.ascii.isAlphanumeric(text[i - 1]) or text[i - 1] == '_' or text[i - 1] == '-');
        if (!before_ok) continue;

        const keyword_len: usize = blk: {
            if (i + 3 <= text.len and text[i] == 'a' and text[i + 1] == 'n' and text[i + 2] == 'd') break :blk 3;
            if (i + 3 <= text.len and text[i] == 'n' and text[i + 1] == 'o' and text[i + 2] == 't') break :blk 3;
            if (i + 2 <= text.len and text[i] == 'o' and text[i + 1] == 'r') break :blk 2;
            continue;
        };

        const after_kw = i + keyword_len;
        if (after_kw < text.len and (std.ascii.isAlphanumeric(text[after_kw]) or text[after_kw] == '_' or text[after_kw] == '-')) {
            continue;
        }

        var saw_newline = false;
        var j = after_kw;
        while (j < text.len and std.ascii.isWhitespace(text[j])) : (j += 1) {
            if (text[j] == '\n' or text[j] == '\r') saw_newline = true;
        }
        if (saw_newline and j < text.len and (text[j] == '(' or std.ascii.isAlphabetic(text[j]) or text[j] == '-')) {
            return true;
        }
    }
    return false;
}
