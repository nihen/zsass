const std = @import("std");

pub fn stripOuterQuotes(s: []const u8) []const u8 {
    if (s.len >= 2) {
        if ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\'')) {
            return s[1 .. s.len - 1];
        }
    }
    return s;
}

/// Normalize quote chars for a plain-CSS @import url_emit_text.
/// Returns null if no change is needed; otherwise returns a newly-allocated
/// buffer that the caller must free.
/// Rules (official Sass CLI compatible):
/// * url('X')  ->  url("X") (always, regardless of source mode)
/// * bare 'X'  ->  "X" (only when in_plain_css_module, i.e. .css source)
/// The bare-string rewrite is skipped in .scss mode to preserve quote style.
pub fn normalizePlainCssImportQuote(
    allocator: std.mem.Allocator,
    text: []const u8,
    in_plain_css_module: bool,
) ?[]u8 {
    const is_bare_single_quoted = text.len >= 2 and text[0] == '\'' and text[text.len - 1] == '\'';
    const is_url_form = std.mem.startsWith(u8, text, "url(") and std.mem.endsWith(u8, text, ")");
    if (is_bare_single_quoted and in_plain_css_module) {
        const inner = text[1 .. text.len - 1];
        if (std.mem.indexOfScalar(u8, inner, '"') != null) return null;
        if (std.mem.indexOfScalar(u8, inner, '\\') != null) return null;
        return std.fmt.allocPrint(allocator, "\"{s}\"", .{inner}) catch null;
    }
    if (is_url_form) {
        const inner = text[4 .. text.len - 1];
        const inner_trim = std.mem.trim(u8, inner, " \t\n\r");
        if (inner_trim.len < 2) return null;
        if (inner_trim[0] != '\'' or inner_trim[inner_trim.len - 1] != '\'') return null;
        const url_inner = inner_trim[1 .. inner_trim.len - 1];
        if (std.mem.indexOfScalar(u8, url_inner, '"') != null) return null;
        if (std.mem.indexOfScalar(u8, url_inner, '\\') != null) return null;
        return std.fmt.allocPrint(allocator, "url(\"{s}\")", .{url_inner}) catch null;
    }
    return null;
}

pub fn isPlainCssImport(raw: []const u8, inner: []const u8) bool {
    if (std.mem.startsWith(u8, raw, "url(")) return true;
    if (std.mem.startsWith(u8, inner, "http://")) return true;
    if (std.mem.startsWith(u8, inner, "https://")) return true;
    if (std.mem.startsWith(u8, inner, "//")) return true;
    if (inner.len >= 4 and std.ascii.eqlIgnoreCase(inner[inner.len - 4 ..], ".css")) return true;
    return false;
}

pub fn importUrlHasDynamicDollar(raw: []const u8) bool {
    if (raw.len >= 2) {
        const q = raw[0];
        if ((q == '"' or q == '\'') and raw[raw.len - 1] == q) return false;
    }
    return std.mem.indexOfScalar(u8, raw, '$') != null;
}

pub fn isBareImportLookupUrl(url: []const u8) bool {
    if (url.len == 0) return false;
    if (std.mem.startsWith(u8, url, "./") or std.mem.startsWith(u8, url, "../")) return false;
    if (url[0] == '/') return false;
    if (std.mem.indexOf(u8, url, "://") != null) return false;
    if (std.mem.startsWith(u8, url, "//")) return false;
    return std.mem.indexOfScalar(u8, url, '/') == null;
}

pub fn importSourceNeedsConfigSnapshot(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "!default") != null or
        std.mem.indexOf(u8, source, "@import") != null or
        std.mem.indexOf(u8, source, "@use") != null or
        std.mem.indexOf(u8, source, "@forward") != null;
}

test "importUrlHasDynamicDollar treats quoted dollar as literal path text" {
    try std.testing.expect(!importUrlHasDynamicDollar("\"$pkg/module\""));
    try std.testing.expect(!importUrlHasDynamicDollar("'$pkg/module'"));
    try std.testing.expect(importUrlHasDynamicDollar("$pkg/module"));
}
