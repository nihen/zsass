//! Which entries may share resolve and compile results across a batch.
//!
//! An entry that configures a module, or reaches one through Sass `@import`,
//! can give a shared module a state that the cross-entry caches cannot tell
//! apart from its default; such an entry compiles without them.

const std = @import("std");

fn sourceMayConfigureModule(source: []const u8) bool {
    if (std.mem.indexOf(u8, source, "with") == null) return false;
    return std.mem.indexOf(u8, source, "@use") != null or
        std.mem.indexOf(u8, source, "@forward") != null;
}

pub fn sourceMayReachUnknownConfiguration(source: []const u8) bool {
    if (sourceMayConfigureModule(source)) return true;
    if (std.mem.indexOf(u8, source, "@import") == null) return false;
    return !sourceImportsArePlainCssOnly(source);
}

fn importTailHasOnlyWhitespaceBeforeSemicolon(source: []const u8, start: usize) bool {
    var k = start;
    while (k < source.len) : (k += 1) {
        if (source[k] == ';') return true;
        if (!std.ascii.isWhitespace(source[k])) return false;
    }
    return true;
}

/// True when every `@import` occurrence in `source` is a plain-CSS import
/// (url(...), an http(s)/protocol-relative URL, or a quoted path ending in
/// .css). Plain-CSS imports pass through to the output without loading a
/// Sass module, so they cannot inject configuration into module resolution.
/// Anything ambiguous (quoted Sass partials, media-suffixed quoted imports,
/// "@import" text inside strings or comments) answers false, keeping the
/// caller on the conservative path.
fn sourceImportsArePlainCssOnly(source: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, source, i, "@import")) |pos| {
        i = pos + "@import".len;
        var j = i;
        while (j < source.len and std.ascii.isWhitespace(source[j])) j += 1;
        if (j >= source.len) return false;
        if (std.mem.startsWith(u8, source[j..], "url(")) continue;
        if (source[j] == '"' or source[j] == '\'') {
            const quote = source[j];
            const rest = source[j + 1 ..];
            const end = std.mem.indexOfScalar(u8, rest, quote) orelse return false;
            const path = rest[0..end];
            const after_quote = j + 1 + end + 1;
            if (!importTailHasOnlyWhitespaceBeforeSemicolon(source, after_quote)) return false;
            if (std.mem.startsWith(u8, path, "http://") or
                std.mem.startsWith(u8, path, "https://") or
                std.mem.startsWith(u8, path, "//"))
            {
                continue;
            }
            if (std.mem.endsWith(u8, path, ".css")) continue;
            return false;
        }
        return false;
    }
    return true;
}

test "batch_reuse: plain-css import probe rejects quoted media suffixes" {
    try std.testing.expect(sourceImportsArePlainCssOnly("@import \"theme.css\";"));
    try std.testing.expect(sourceImportsArePlainCssOnly("@import \"https://example.com/theme.css\";"));
    try std.testing.expect(!sourceImportsArePlainCssOnly("@import \"theme.css\" screen;"));
    try std.testing.expect(!sourceImportsArePlainCssOnly("@import \"theme\";"));
}
