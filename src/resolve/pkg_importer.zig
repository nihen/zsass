const std = @import("std");
const zsass_io = @import("../runtime/io.zig");

/// Reject any sub-path that could escape the resolved package root via
/// `..` traversal or absolute paths. Applied to the URL subpath, to
/// `package.json` `sass`/`style` fields, and to `exports` targets.
fn isSafeRelativePath(p: []const u8) bool {
    if (p.len == 0) return false;
    // No absolute paths.
    if (p[0] == '/' or p[0] == '\\') return false;
    // Windows drive letter (e.g. `C:\...`).
    if (p.len >= 2 and p[1] == ':') return false;
    // No `..` traversal components.
    if (std.mem.eql(u8, p, "..")) return false;
    if (std.mem.startsWith(u8, p, "../")) return false;
    if (std.mem.startsWith(u8, p, "..\\")) return false;
    if (std.mem.endsWith(u8, p, "/..")) return false;
    if (std.mem.endsWith(u8, p, "\\..")) return false;
    if (std.mem.indexOf(u8, p, "/../") != null) return false;
    if (std.mem.indexOf(u8, p, "\\..\\") != null) return false;
    if (std.mem.indexOf(u8, p, "/..\\") != null) return false;
    if (std.mem.indexOf(u8, p, "\\../") != null) return false;
    return true;
}

/// Reject package names that could redirect resolution outside their normal
/// scope. Catches:
///   - empty
///   - leading `/` or `\` (absolute paths)
///   - leading `.` (`.` / `..` / `./foo`)
///   - drive letter (`C:\foo`)
///   - any embedded path-separator-bracketed `..` segment, e.g.
///     `pkg:foo\..\..\secret`. On Windows `\` is a path separator and
///     `std.fs.path.join` interprets `..` segments, so a name like that
///     would otherwise resolve outside `node_modules/<pkg>`.
fn isSafePackageName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] == '/' or name[0] == '\\') return false;
    if (name[0] == '.') return false;
    if (name.len >= 2 and name[1] == ':') return false;
    // `@/foo` is malformed npm-style (empty scope) and would resolve to
    // `node_modules/@/foo`; refuse it explicitly so a misformatted `pkg:`
    // can't probe the filesystem at unusual locations.
    if (name.len >= 2 and name[0] == '@' and name[1] == '/') return false;
    // Treat anything containing a `..` traversal component as unsafe even
    // if it's stuffed into the package name (e.g. `pkg:foo\..\..\secret`).
    if (std.mem.indexOf(u8, name, "/..") != null) return false;
    if (std.mem.indexOf(u8, name, "\\..") != null) return false;
    if (std.mem.indexOf(u8, name, "../") != null) return false;
    if (std.mem.indexOf(u8, name, "..\\") != null) return false;
    if (std.mem.endsWith(u8, name, "/..")) return false;
    if (std.mem.endsWith(u8, name, "\\..")) return false;
    return true;
}

/// Resolve a `pkg:` URL to a filesystem path using Node.js module resolution.
/// Returns null if the package cannot be found.
/// Caller owns the returned slice.
pub fn resolve(allocator: std.mem.Allocator, pkg_url: []const u8, from_dir: []const u8) ?[]const u8 {
    // Strip "pkg:" prefix
    const name = if (std.mem.startsWith(u8, pkg_url, "pkg:"))
        pkg_url["pkg:".len..]
    else
        return null;

    if (name.len == 0) return null;

    // Split scoped package: @scope/name/path -> package = @scope/name, subpath = path
    const pkg_name, const subpath = splitPackagePath(name);

    // Reject malicious package name / traversal subpath before any I/O.
    if (!isSafePackageName(pkg_name)) return null;
    if (subpath) |sp| if (!isSafeRelativePath(sp)) return null;

    // Walk up directories looking for node_modules/<package>
    var dir = from_dir;
    while (true) {
        const candidate = std.fs.path.join(allocator, &.{ dir, "node_modules", pkg_name }) catch return null;
        defer allocator.free(candidate);

        if (resolvePackageEntry(allocator, candidate, subpath)) |result| {
            // Defense-in-depth against symlinks pointing outside the
            // package: realpath both the package root and the resolved
            // file, then refuse anything that escapes after symlink
            // resolution. Lexical `..` is already blocked by
            // `isSafeRelativePath`; this catches the case where a
            // package's exports / sass / style target points at a
            // symlink that itself escapes the package directory.
            if (containmentOk(allocator, candidate, result)) {
                return result;
            }
            allocator.free(result);
            return null;
        }

        // Move to parent directory
        const parent = std.fs.path.dirname(dir) orelse break;
        if (std.mem.eql(u8, parent, dir)) break;
        dir = parent;
    }

    return null;
}

/// True when `candidate_path` realpath-resolves to a location inside
/// (or equal to) `container_path` realpath. Path separator is checked
/// so `node_modules/foo-bar` does not match `node_modules/foo`.
fn containmentOk(allocator: std.mem.Allocator, container_path: []const u8, candidate_path: []const u8) bool {
    const container_real = zsass_io.realPathAlloc(std.Io.Dir.cwd(), container_path, allocator) catch return false;
    defer allocator.free(container_real);
    const candidate_real = zsass_io.realPathAlloc(std.Io.Dir.cwd(), candidate_path, allocator) catch return false;
    defer allocator.free(candidate_real);
    if (candidate_real.len < container_real.len) return false;
    if (!std.mem.startsWith(u8, candidate_real, container_real)) return false;
    if (candidate_real.len == container_real.len) return true;
    const sep = candidate_real[container_real.len];
    return sep == '/' or sep == '\\';
}

fn splitPackagePath(name: []const u8) struct { []const u8, ?[]const u8 } {
    if (name.len > 0 and name[0] == '@') {
        // Scoped: @scope/pkg or @scope/pkg/subpath
        if (std.mem.findScalar(u8, name[1..], '/')) |first_slash| {
            const after_scope = 1 + first_slash + 1; // skip @, scope, /
            if (std.mem.findScalarPos(u8, name, after_scope, '/')) |second_slash| {
                return .{ name[0..second_slash], name[second_slash + 1 ..] };
            }
            return .{ name, null };
        }
        return .{ name, null };
    }
    // Unscoped: pkg or pkg/subpath
    if (std.mem.findScalar(u8, name, '/')) |slash| {
        return .{ name[0..slash], name[slash + 1 ..] };
    }
    return .{ name, null };
}

fn resolvePackageEntry(allocator: std.mem.Allocator, pkg_dir: []const u8, subpath: ?[]const u8) ?[]const u8 {
    if (subpath) |sp| {
        // Direct subpath: look for the file with sass extensions
        return resolveSassFile(allocator, pkg_dir, sp);
    }

    // Try package.json fields
    const pkg_json_path = std.fs.path.join(allocator, &.{ pkg_dir, "package.json" }) catch return null;
    defer allocator.free(pkg_json_path);

    const pkg_json_content = readFileAlloc(allocator, pkg_json_path) orelse return null;
    defer allocator.free(pkg_json_content);

    // 1. Try "exports" field with conditions ["sass", "style", "default"]
    //    Handles: "exports": { ".": { "sass": "./dist/index.scss" } }
    //    and:     "exports": { ".": "./dist/index.css" }
    //    and:     "exports": "./dist/index.css" (shorthand for ".")
    if (resolveExportsField(allocator, pkg_json_content, pkg_dir)) |result| {
        return result;
    }

    // 2. Look for top-level "sass" field first, then "style"
    if (extractJsonStringField(pkg_json_content, "sass")) |sass_entry| {
        if (isSafeRelativePath(sass_entry)) {
            const full = std.fs.path.join(allocator, &.{ pkg_dir, sass_entry }) catch return null;
            if (fileExists(full)) return full;
            allocator.free(full);
        }
    }
    if (extractJsonStringField(pkg_json_content, "style")) |style_entry| {
        if (isSafeRelativePath(style_entry)) {
            const full = std.fs.path.join(allocator, &.{ pkg_dir, style_entry }) catch return null;
            if (fileExists(full)) return full;
            allocator.free(full);
        }
    }

    // 3. Fallback: index.scss, index.sass, _index.scss, _index.sass
    return resolveSassFile(allocator, pkg_dir, "index");
}

/// Resolve the "exports" field from package.json for the "." subpath.
/// Checks conditions in order: "sass", "style", "default".
fn resolveExportsField(allocator: std.mem.Allocator, json: []const u8, pkg_dir: []const u8) ?[]const u8 {
    // Find "exports" key
    const exports_start = findJsonObjectField(json, "exports") orelse return null;
    const val_start = skipJsonWhitespace(json, exports_start);
    if (val_start >= json.len) return null;

    if (json[val_start] == '"') {
        //"exports": "./dist/index.css" -- shorthand for "."
        const str = extractQuotedString(json, val_start) orelse return null;
        return resolveExportsPath(allocator, pkg_dir, str);
    }

    if (json[val_start] != '{') return null;

    // "exports": { ... }
    // Look for "." entry first
    const dot_start = findJsonObjectFieldInRange(json, val_start, ".") orelse return null;
    const dot_val_start = skipJsonWhitespace(json, dot_start);
    if (dot_val_start >= json.len) return null;

    if (json[dot_val_start] == '"') {
        // "exports": { ".": "./dist/index.css" }
        const str = extractQuotedString(json, dot_val_start) orelse return null;
        return resolveExportsPath(allocator, pkg_dir, str);
    }

    if (json[dot_val_start] != '{') return null;

    // "exports": { ".": { "sass": "...", "style": "...", "default": "..." } }
    // Try conditions in priority order
    const conditions = [_][]const u8{ "sass", "style", "default" };
    for (conditions) |cond| {
        if (findJsonObjectFieldInRange(json, dot_val_start, cond)) |cond_start| {
            const cond_val_start = skipJsonWhitespace(json, cond_start);
            if (extractQuotedString(json, cond_val_start)) |path| {
                if (resolveExportsPath(allocator, pkg_dir, path)) |result| return result;
            }
        }
    }

    return null;
}

fn resolveExportsPath(allocator: std.mem.Allocator, pkg_dir: []const u8, path: []const u8) ?[]const u8 {
    if (path.len == 0) return null;
    // Conditional `exports` targets typically start with `./`. Strip it and
    // validate the remainder so legitimate package.json layouts still resolve
    // while `..` traversal is rejected.
    const stripped = if (std.mem.startsWith(u8, path, "./")) path[2..] else path;
    if (!isSafeRelativePath(stripped)) return null;
    const full = std.fs.path.join(allocator, &.{ pkg_dir, stripped }) catch return null;
    if (fileExists(full)) return full;
    allocator.free(full);
    return null;
}

/// Find the value position after `"field":` in a JSON object starting at `start`.
fn findJsonObjectFieldInRange(json: []const u8, start: usize, field: []const u8) ?usize {
    var pos = start;
    if (pos < json.len and json[pos] == '{') pos += 1;
    while (pos < json.len) {
        pos = skipJsonWhitespace(json, pos);
        if (pos >= json.len or json[pos] == '}') return null;
        if (json[pos] != '"') {
            pos += 1;
            continue;
        }
        const key = extractQuotedString(json, pos) orelse return null;
        const after_key = pos + key.len + 2; // skip quotes
        const colon = skipJsonWhitespace(json, after_key);
        if (colon >= json.len or json[colon] != ':') {
            pos = colon;
            continue;
        }
        if (std.mem.eql(u8, key, field)) {
            return colon + 1; // position after ':'
        }
        // Skip the value to continue searching
        pos = skipJsonValue(json, skipJsonWhitespace(json, colon + 1));
        if (pos < json.len and json[pos] == ',') pos += 1;
    }
    return null;
}

/// Find the value position after top-level `"field":` in JSON.
fn findJsonObjectField(json: []const u8, field: []const u8) ?usize {
    return findJsonObjectFieldInRange(json, 0, field);
}

fn skipJsonWhitespace(json: []const u8, start: usize) usize {
    var i = start;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) : (i += 1) {}
    return i;
}

/// Extract the content of a quoted string starting at `pos` (which points to the opening `"`).
fn extractQuotedString(json: []const u8, pos: usize) ?[]const u8 {
    if (pos >= json.len or json[pos] != '"') return null;
    var i = pos + 1;
    while (i < json.len and json[i] != '"') {
        if (json[i] == '\\') i += 1; // skip escape
        i += 1;
    }
    if (i >= json.len) return null;
    return json[pos + 1 .. i];
}

/// Skip a JSON value (string, number, object, array) starting at `pos`.
fn skipJsonValue(json: []const u8, start: usize) usize {
    if (start >= json.len) return start;
    return switch (json[start]) {
        '"' => blk: {
            var i = start + 1;
            while (i < json.len and json[i] != '"') : (i += 1) {
                if (json[i] == '\\') i += 1;
            }
            break :blk if (i < json.len) i + 1 else i;
        },
        '{' => skipJsonBracket(json, start, '{', '}'),
        '[' => skipJsonBracket(json, start, '[', ']'),
        else => blk: {
            var i = start;
            while (i < json.len and json[i] != ',' and json[i] != '}' and json[i] != ']') : (i += 1) {}
            break :blk i;
        },
    };
}

fn skipJsonBracket(json: []const u8, start: usize, open: u8, close: u8) usize {
    var depth: usize = 0;
    var i = start;
    while (i < json.len) : (i += 1) {
        if (json[i] == open) depth += 1;
        if (json[i] == close) {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
        if (json[i] == '"') {
            i += 1;
            while (i < json.len and json[i] != '"') : (i += 1) {
                if (json[i] == '\\') i += 1;
            }
        }
    }
    return i;
}

fn resolveSassFile(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ?[]const u8 {
    const extensions = [_][]const u8{ ".scss", ".sass", ".css" };
    const prefixes = [_][]const u8{ "", "_" };

    for (prefixes) |prefix| {
        for (extensions) |ext| {
            const filename = std.mem.concat(allocator, u8, &.{ prefix, name, ext }) catch continue;
            defer allocator.free(filename);
            const full = std.fs.path.join(allocator, &.{ dir, filename }) catch continue;
            if (fileExists(full)) return full;
            allocator.free(full);
        }
    }
    return null;
}

fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(zsass_io.io, path, .{}) catch return false;
    return true;
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const file = std.Io.Dir.cwd().openFile(zsass_io.io, path, .{}) catch return null;
    defer file.close(zsass_io.io);
    return blk: {
        var __rb: [1024]u8 = undefined;
        var __rd = file.reader(zsass_io.io, &__rb);
        break :blk __rd.interface.allocRemaining(allocator, .limited(1024 * 1024));
    } catch null;
}

/// Simple JSON string field extractor (no full parser needed).
/// Finds `"<field>": "<value>"` and returns value.
fn extractJsonStringField(json: []const u8, field: []const u8) ?[]const u8 {
    // Search for "field": "value"
    var pos: usize = 0;
    while (pos < json.len) {
        const field_start = std.mem.findPos(u8, json, pos, field) orelse return null;
        // Check it's a proper key: preceded by "
        if (field_start == 0 or json[field_start - 1] != '"') {
            pos = field_start + 1;
            continue;
        }
        // Find closing quote of key
        const after_key = field_start + field.len;
        if (after_key >= json.len or json[after_key] != '"') {
            pos = after_key;
            continue;
        }
        // Skip whitespace and colon
        var i = after_key + 1;
        while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) : (i += 1) {}
        if (i >= json.len or json[i] != ':') {
            pos = i;
            continue;
        }
        i += 1;
        while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) : (i += 1) {}
        if (i >= json.len or json[i] != '"') {
            pos = i;
            continue;
        }
        i += 1;
        const val_start = i;
        while (i < json.len and json[i] != '"') : (i += 1) {}
        if (i >= json.len) return null;
        return json[val_start..i];
    }
    return null;
}

test "extractJsonStringField" {
    const json = "{ \"name\": \"my-pkg\", \"sass\": \"dist/main.scss\", \"style\": \"dist/style.css\" }";
    try std.testing.expectEqualStrings("dist/main.scss", extractJsonStringField(json, "sass").?);
    try std.testing.expectEqualStrings("dist/style.css", extractJsonStringField(json, "style").?);
    try std.testing.expect(extractJsonStringField(json, "missing") == null);
}

test "isSafeRelativePath rejects traversal and absolute paths" {
    try std.testing.expect(isSafeRelativePath("dist/main.scss"));
    try std.testing.expect(isSafeRelativePath("a/b/c"));
    try std.testing.expect(!isSafeRelativePath(""));
    try std.testing.expect(!isSafeRelativePath(".."));
    try std.testing.expect(!isSafeRelativePath("../etc/passwd"));
    try std.testing.expect(!isSafeRelativePath("..\\etc"));
    try std.testing.expect(!isSafeRelativePath("dist/../../../etc/passwd"));
    try std.testing.expect(!isSafeRelativePath("dist\\..\\..\\..\\etc"));
    try std.testing.expect(!isSafeRelativePath("dist/main/.."));
    try std.testing.expect(!isSafeRelativePath("/etc/passwd"));
    try std.testing.expect(!isSafeRelativePath("\\etc\\passwd"));
    try std.testing.expect(!isSafeRelativePath("C:\\Windows"));
}

test "isSafePackageName rejects traversal-bearing names" {
    try std.testing.expect(isSafePackageName("pkg-name"));
    try std.testing.expect(isSafePackageName("@scope/pkg"));
    try std.testing.expect(!isSafePackageName(""));
    try std.testing.expect(!isSafePackageName("."));
    try std.testing.expect(!isSafePackageName(".."));
    try std.testing.expect(!isSafePackageName("../foo"));
    try std.testing.expect(!isSafePackageName("/abs/pkg"));
    try std.testing.expect(!isSafePackageName("C:\\pkg"));
    // Embedded traversal that would only become dangerous after path-join
    // on Windows (or any platform that treats `\` as a separator).
    try std.testing.expect(!isSafePackageName("foo\\..\\..\\secret"));
    try std.testing.expect(!isSafePackageName("foo\\..\\bar"));
    try std.testing.expect(!isSafePackageName("foo/../bar"));
    try std.testing.expect(!isSafePackageName("foo/../../bar"));
    try std.testing.expect(!isSafePackageName("foo/.."));
    try std.testing.expect(!isSafePackageName("foo\\.."));
}

test "resolve rejects pkg: URLs that try to traverse out" {
    const alloc = std.testing.allocator;
    // None of these should reach the filesystem (the test allocator would
    // catch any leak). They must all return null at the validation step.
    try std.testing.expect(resolve(alloc, "pkg:foo/../../etc", "/tmp") == null);
    try std.testing.expect(resolve(alloc, "pkg:foo/..", "/tmp") == null);
    try std.testing.expect(resolve(alloc, "pkg:../etc", "/tmp") == null);
    try std.testing.expect(resolve(alloc, "pkg:./bar", "/tmp") == null);
    try std.testing.expect(resolve(alloc, "pkg:/etc/passwd", "/tmp") == null);
    try std.testing.expect(resolve(alloc, "pkg:", "/tmp") == null);
    // Backslash and Windows-style traversal must be rejected on every host
    // (the resolver does not assume the runtime OS).
    try std.testing.expect(resolve(alloc, "pkg:foo\\..\\..\\secret", "/tmp") == null);
    try std.testing.expect(resolve(alloc, "pkg:foo\\..", "/tmp") == null);
    try std.testing.expect(resolve(alloc, "pkg:..\\foo", "/tmp") == null);
    try std.testing.expect(resolve(alloc, "pkg:\\\\unc\\share", "/tmp") == null);
    try std.testing.expect(resolve(alloc, "pkg:C:\\foo", "/tmp") == null);
    // Scoped package traversal: `@scope/..`, `@scope/../foo`, etc.
    try std.testing.expect(resolve(alloc, "pkg:@scope/..", "/tmp") == null);
    try std.testing.expect(resolve(alloc, "pkg:@scope/../foo", "/tmp") == null);
    try std.testing.expect(resolve(alloc, "pkg:@scope/foo/../../etc", "/tmp") == null);
    try std.testing.expect(resolve(alloc, "pkg:@scope/foo\\..\\..\\etc", "/tmp") == null);
    try std.testing.expect(resolve(alloc, "pkg:@/foo", "/tmp") == null);
}

test "splitPackagePath unscoped" {
    const name1, const sub1 = splitPackagePath("pkg-name");
    try std.testing.expectEqualStrings("pkg-name", name1);
    try std.testing.expect(sub1 == null);

    const name2, const sub2 = splitPackagePath("pkg-name/scss/main");
    try std.testing.expectEqualStrings("pkg-name", name2);
    try std.testing.expectEqualStrings("scss/main", sub2.?);
}

test "splitPackagePath scoped" {
    const name1, const sub1 = splitPackagePath("@org/pkg");
    try std.testing.expectEqualStrings("@org/pkg", name1);
    try std.testing.expect(sub1 == null);

    const name2, const sub2 = splitPackagePath("@org/pkg/lib/main");
    try std.testing.expectEqualStrings("@org/pkg", name2);
    try std.testing.expectEqualStrings("lib/main", sub2.?);
}

test "resolveExportsField - shorthand string" {
    //"exports": "./dist/index.css" -- can't resolve without filesystem, test the JSON parsing
    const json = "{ \"name\": \"pkg\", \"exports\": \"./dist/index.css\" }";
    const start = findJsonObjectField(json, "exports").?;
    const val_start = skipJsonWhitespace(json, start);
    const path = extractQuotedString(json, val_start).?;
    try std.testing.expectEqualStrings("./dist/index.css", path);
}

test "resolveExportsField - conditional exports" {
    const json =
        \\{ "exports": { ".": { "sass": "./dist/main.scss", "default": "./dist/main.css" } } }
    ;
    const exports_start = findJsonObjectField(json, "exports").?;
    const val_start = skipJsonWhitespace(json, exports_start);
    try std.testing.expect(json[val_start] == '{');
    const dot_start = findJsonObjectFieldInRange(json, val_start, ".").?;
    const dot_val_start = skipJsonWhitespace(json, dot_start);
    try std.testing.expect(json[dot_val_start] == '{');
    // "sass" condition
    const sass_start = findJsonObjectFieldInRange(json, dot_val_start, "sass").?;
    const sass_val = extractQuotedString(json, skipJsonWhitespace(json, sass_start)).?;
    try std.testing.expectEqualStrings("./dist/main.scss", sass_val);
    // "default" condition
    const default_start = findJsonObjectFieldInRange(json, dot_val_start, "default").?;
    const default_val = extractQuotedString(json, skipJsonWhitespace(json, default_start)).?;
    try std.testing.expectEqualStrings("./dist/main.css", default_val);
    //"style" condition -- not present
    try std.testing.expect(findJsonObjectFieldInRange(json, dot_val_start, "style") == null);
}
