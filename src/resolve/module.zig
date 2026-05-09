const std = @import("std");
const zsass_io = @import("../runtime/io.zig");
const pkg_importer = @import("pkg_importer.zig");
const test_utils = struct {
    fn writeFile(dir: *std.Io.Dir, path: []const u8, contents: []const u8) !void {
        if (std.fs.path.dirname(path)) |parent| {
            try dir.createDirPath(zsass_io.io, parent);
        }
        const file = try dir.createFile(zsass_io.io, path, .{});
        defer file.close(zsass_io.io);
        try file.writeStreamingAll(zsass_io.io, contents);
    }

    fn touchFile(dir: *std.Io.Dir, path: []const u8) !void {
        try writeFile(dir, path, "");
    }

    fn realpathAlloc(allocator: std.mem.Allocator, dir: *std.Io.Dir) ![]u8 {
        return zsass_io.realPathAlloc(dir.*, ".", allocator);
    }

    fn joinRealpath(allocator: std.mem.Allocator, dir: *std.Io.Dir, relative_path: []const u8) ![]u8 {
        const root = try realpathAlloc(allocator, dir);
        defer allocator.free(root);
        return std.fs.path.join(allocator, &.{ root, relative_path });
    }
};

//--- Member Types ----------------------------------------------------------

const MemberKind = enum {
    variable,
    function,
    mixin,
};

const Visibility = enum {
    public,
    private, // starts with _ or -
};

const ModuleMember = struct {
    name: []const u8,
    kind: MemberKind,
    visibility: Visibility,
};

//--- Forward / Use Rules --------------------------------------------------

const ForwardRule = struct {
    url: []const u8,
    prefix: ?[]const u8, // as prefix-*
    shown: ?[]const []const u8, // show list
    hidden: ?[]const []const u8, // hide list
};

//--- Module --------------------------------------------------------------

const Module = struct {
    url: []const u8,
    canonical_url: []const u8,
    members: std.ArrayList(ModuleMember),
    forwards: std.ArrayList(ForwardRule),
    upstream_modules: std.ArrayList(*Module),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, url: []const u8) Module {
        return .{
            .url = url,
            .canonical_url = url,
            .members = .empty,
            .forwards = .empty,
            .upstream_modules = .empty,
            .allocator = allocator,
        };
    }

    fn deinit(self: *Module) void {
        self.members.deinit(self.allocator);
        self.forwards.deinit(self.allocator);
        self.upstream_modules.deinit(self.allocator);
    }

    fn addMember(self: *Module, member: ModuleMember) !void {
        try self.members.append(self.allocator, member);
    }

    fn getMember(self: *const Module, name: []const u8, kind: MemberKind) ?ModuleMember {
        for (self.members.items) |m| {
            if (m.kind == kind and std.mem.eql(u8, m.name, name)) {
                return m;
            }
        }
        return null;
    }

    fn getVisibleMembers(self: *const Module, allocator: std.mem.Allocator) ![]ModuleMember {
        var result: std.ArrayList(ModuleMember) = .empty;
        errdefer result.deinit(allocator);
        try result.ensureTotalCapacity(allocator, self.members.items.len);
        for (self.members.items) |m| {
            if (m.visibility == .public) {
                result.appendAssumeCapacity(m);
            }
        }
        return result.toOwnedSlice(allocator);
    }
};

//--- URL Resolution --------------------------------------------------------

pub const ResolveResult = struct {
    path: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ResolveResult) void {
        self.allocator.free(self.path);
    }
};

/// Resolver-tuning options that can be threaded through `resolveUrl` and
/// `resolveImportUrl` without breaking existing call-sites.
pub const ResolveOptions = struct {
    /// dart-sass parity: the `pkg:` URL scheme must be explicitly enabled
    /// via `--pkg-importer=node`. When this flag is `false` (the default),
    /// `pkg:` resolution is rejected so untrusted SCSS input cannot use it
    /// to read packages off the host filesystem.
    pkg_importer_enabled: bool = false,
};

pub fn resolveUrl(
    allocator: std.mem.Allocator,
    url: []const u8,
    from_path: []const u8,
    load_paths: []const []const u8,
    opts: ResolveOptions,
) !?ResolveResult {
    return resolveUrlImpl(allocator, url, from_path, load_paths, false, opts);
}

pub fn resolveImportUrl(
    allocator: std.mem.Allocator,
    url: []const u8,
    from_path: []const u8,
    load_paths: []const []const u8,
    opts: ResolveOptions,
) !?ResolveResult {
    return resolveUrlImpl(allocator, url, from_path, load_paths, true, opts);
}

fn tryOverlayExplicitRelative(
    allocator: std.mem.Allocator,
    url: []const u8,
    from_path: []const u8,
    load_paths: []const []const u8,
    is_import: bool,
) !?[]const u8 {
    for (load_paths) |source_root| {
        const rel_from = std.fs.path.relativePosix(allocator, "", source_root, from_path) catch continue;
        defer allocator.free(rel_from);
        if (std.mem.eql(u8, rel_from, from_path) or std.mem.startsWith(u8, rel_from, "..")) continue;

        const rel_dir = std.fs.path.dirname(rel_from) orelse ".";
        for (load_paths) |target_root| {
            const overlay_base = try std.fs.path.resolve(allocator, &.{ target_root, rel_dir });
            defer allocator.free(overlay_base);

            const overlay_abs = try std.fs.path.resolve(allocator, &.{ overlay_base, url });
            defer allocator.free(overlay_abs);

            const abs_base = std.fs.path.dirname(overlay_abs) orelse "/";
            const abs_file = std.fs.path.basename(overlay_abs);
            if (is_import) {
                inline for ([_]CandidateKind{ .import_non_index, .normal_non_index, .import_index, .normal_index }) |kind| {
                    if (try tryCandidatePhase(allocator, abs_base, abs_file, kind)) |path| {
                        return path;
                    }
                }
            } else if (try tryCandidates(allocator, abs_base, abs_file)) |path| {
                return path;
            }
        }
    }
    return null;
}

fn trySyntheticExplicitRelative(
    allocator: std.mem.Allocator,
    url: []const u8,
    load_paths: []const []const u8,
    is_import: bool,
) !?[]const u8 {
    for (load_paths) |lp| {
        const synthetic_abs = std.fs.path.resolve(allocator, &.{ lp, url }) catch continue;
        defer allocator.free(synthetic_abs);

        const abs_base = std.fs.path.dirname(synthetic_abs) orelse "/";
        const abs_file = std.fs.path.basename(synthetic_abs);
        if (is_import) {
            inline for ([_]CandidateKind{ .import_non_index, .normal_non_index, .import_index, .normal_index }) |kind| {
                if (try tryCandidatePhase(allocator, abs_base, abs_file, kind)) |path| {
                    return path;
                }
            }
        } else if (try tryCandidates(allocator, abs_base, abs_file)) |path| {
            return path;
        }

        var trimmed = url;
        while (std.mem.startsWith(u8, trimmed, "../")) {
            trimmed = trimmed[3..];
            if (trimmed.len == 0) break;

            if (is_import) {
                inline for ([_]CandidateKind{ .import_non_index, .normal_non_index, .import_index, .normal_index }) |kind| {
                    if (try tryCandidatePhase(allocator, lp, trimmed, kind)) |path| {
                        return path;
                    }
                }
            } else if (try tryCandidates(allocator, lp, trimmed)) |path| {
                return path;
            }
        }
    }

    const synthetic_name = std.fs.path.basename(url);
    if (!std.mem.eql(u8, synthetic_name, url)) {
        for (load_paths) |lp| {
            if (is_import) {
                inline for ([_]CandidateKind{ .import_non_index, .normal_non_index, .import_index, .normal_index }) |kind| {
                    if (try tryCandidatePhase(allocator, lp, synthetic_name, kind)) |path| {
                        return path;
                    }
                }
            } else if (try tryCandidates(allocator, lp, synthetic_name)) |path| {
                return path;
            }
        }
    }
    return null;
}

fn resolveUrlImpl(
    allocator: std.mem.Allocator,
    url: []const u8,
    from_path: []const u8,
    load_paths: []const []const u8,
    is_import: bool,
    opts: ResolveOptions,
) !?ResolveResult {
    // 0. Handle pkg: URL scheme (Node.js package resolution).
    // Always rejected unless the caller explicitly opted in via
    // --pkg-importer=node (or the embedding-API equivalent), matching
    // dart-sass behavior. Even when enabled, pkg_importer itself
    // performs path-traversal validation.
    if (std.mem.startsWith(u8, url, "pkg:")) {
        if (!opts.pkg_importer_enabled) return null;
        const dir = std.fs.path.dirname(from_path) orelse ".";
        if (pkg_importer.resolve(allocator, url, dir)) |path| {
            return .{ .path = path, .allocator = allocator };
        }
        return null;
    }

    // 1. Resolve relative to from_path's directory.
    const dir = std.fs.path.dirname(from_path) orelse ".";

    // Check if URL is an explicit relative path (./ or ../)
    const is_explicit_relative = std.mem.startsWith(u8, url, "./") or
        std.mem.startsWith(u8, url, "../") or
        std.mem.eql(u8, url, ".") or
        std.mem.eql(u8, url, "..");

    // Normalize away any `.` / `..` path components.
    // For relative paths, normalize relative to from_path's directory.
    // For other paths (bare names), normalize from root.
    const needs_norm = std.mem.find(u8, url, "/./") != null or
        std.mem.find(u8, url, "/../") != null or
        std.mem.endsWith(u8, url, "/..") or
        std.mem.endsWith(u8, url, "/.") or
        is_explicit_relative;
    const nurl_alloc: ?[]const u8 = if (needs_norm) blk: {
        if (is_explicit_relative) {
            // Resolve relative URL against the source file's directory
            break :blk try std.fs.path.resolve(allocator, &.{ dir, url });
        } else {
            const abs = try std.fs.path.resolve(allocator, &.{ "/", url });
            defer allocator.free(abs);
            break :blk try allocator.dupe(u8, abs[1..]);
        }
    } else null;
    defer if (nurl_alloc) |p| allocator.free(p);
    const nurl: []const u8 = if (nurl_alloc) |p| p else url;

    // For explicit relative paths that have been normalized to an absolute path,
    // split into directory and filename for candidate lookup.
    if (is_explicit_relative and nurl_alloc != null) {
        const abs_base = std.fs.path.dirname(nurl) orelse "/";
        const abs_file = std.fs.path.basename(nurl);
        if (is_import) {
            inline for ([_]CandidateKind{ .import_non_index, .normal_non_index, .import_index, .normal_index }) |kind| {
                if (try tryCandidatePhase(allocator, abs_base, abs_file, kind)) |path| {
                    return .{ .path = path, .allocator = allocator };
                }
            }
        } else if (try tryCandidates(allocator, abs_base, abs_file)) |path| {
            return .{ .path = path, .allocator = allocator };
        }
        // Dart Sass still consults load paths for explicit-relative URLs when
        // the importer-relative candidate is absent. This is observable in
        // real-world projects that write `@import "./variables/colors"` from a
        // file under `src/` while `variables/` lives at the configured source
        // root.
        if (try trySyntheticExplicitRelative(allocator, url, load_paths, is_import)) |path| {
            return .{ .path = path, .allocator = allocator };
        }
        if (try tryOverlayExplicitRelative(allocator, url, from_path, load_paths, is_import)) |path| {
            return .{ .path = path, .allocator = allocator };
        }
        // Explicit relative paths don't fall through to load paths
        return null;
    }

    if (is_import) {
        inline for ([_]CandidateKind{ .import_non_index, .normal_non_index, .import_index, .normal_index }) |kind| {
            if (try tryCandidatePhase(allocator, dir, nurl, kind)) |path| {
                return .{ .path = path, .allocator = allocator };
            }
        }
    } else if (try tryCandidates(allocator, dir, nurl)) |path| {
        return .{ .path = path, .allocator = allocator };
    }

    // For explicit relative paths (./ or ../), don't fall through to load paths
    if (std.mem.startsWith(u8, nurl, "./") or std.mem.startsWith(u8, nurl, "../")) {
        return null;
    }

    // 2. Try each load path
    for (load_paths) |lp| {
        if (is_import) {
            inline for ([_]CandidateKind{ .import_non_index, .normal_non_index, .import_index, .normal_index }) |kind| {
                if (try tryCandidatePhase(allocator, lp, nurl, kind)) |path| {
                    return .{ .path = path, .allocator = allocator };
                }
            }
        } else if (try tryCandidates(allocator, lp, nurl)) |path| {
            return .{ .path = path, .allocator = allocator };
        }
    }

    return null;
}

const CandidateKind = enum {
    import_non_index,
    import_index,
    normal_non_index,
    normal_index,
};

fn tryCandidatePhase(
    allocator: std.mem.Allocator,
    base: []const u8,
    name: []const u8,
    kind: CandidateKind,
) !?[]const u8 {
    const name_dir = std.fs.path.dirname(name);
    const name_file = std.fs.path.basename(name);

    const effective_base = if (name_dir) |nd|
        try std.fs.path.join(allocator, &.{ base, nd })
    else
        try allocator.dupe(u8, base);
    defer allocator.free(effective_base);

    const has_ext = std.mem.endsWith(u8, name_file, ".scss") or
        std.mem.endsWith(u8, name_file, ".sass") or
        std.mem.endsWith(u8, name_file, ".css");
    if (has_ext) {
        if (kind != .normal_non_index) return null;
        const cand = try std.mem.concat(allocator, u8, &.{ effective_base, "/", name_file });
        if (fileExists(cand)) return cand;
        allocator.free(cand);
        const part = try std.mem.concat(allocator, u8, &.{ effective_base, "/_", name_file });
        if (fileExists(part)) return part;
        allocator.free(part);
        return null;
    }

    var candidates: [6]?[]const u8 = .{ null, null, null, null, null, null };
    var candidate_count: usize = 0;
    switch (kind) {
        .import_non_index => {
            candidates[0] = try std.mem.concat(allocator, u8, &.{ effective_base, "/", name_file, ".import.scss" });
            candidates[1] = try std.mem.concat(allocator, u8, &.{ effective_base, "/", name_file, ".import.sass" });
            candidates[2] = try std.mem.concat(allocator, u8, &.{ effective_base, "/_", name_file, ".import.scss" });
            candidates[3] = try std.mem.concat(allocator, u8, &.{ effective_base, "/_", name_file, ".import.sass" });
            candidate_count = 4;
        },
        .normal_non_index => {
            candidates[0] = try std.mem.concat(allocator, u8, &.{ effective_base, "/", name_file, ".scss" });
            candidates[1] = try std.mem.concat(allocator, u8, &.{ effective_base, "/", name_file, ".sass" });
            candidates[2] = try std.mem.concat(allocator, u8, &.{ effective_base, "/_", name_file, ".scss" });
            candidates[3] = try std.mem.concat(allocator, u8, &.{ effective_base, "/_", name_file, ".sass" });
            candidates[4] = try std.mem.concat(allocator, u8, &.{ effective_base, "/", name_file, ".css" });
            candidates[5] = try std.mem.concat(allocator, u8, &.{ effective_base, "/_", name_file, ".css" });
            candidate_count = 6;
        },
        .import_index => {
            candidates[0] = try std.mem.concat(allocator, u8, &.{ effective_base, "/", name_file, "/index.import.scss" });
            candidates[1] = try std.mem.concat(allocator, u8, &.{ effective_base, "/", name_file, "/index.import.sass" });
            candidates[2] = try std.mem.concat(allocator, u8, &.{ effective_base, "/", name_file, "/_index.import.scss" });
            candidates[3] = try std.mem.concat(allocator, u8, &.{ effective_base, "/", name_file, "/_index.import.sass" });
            candidate_count = 4;
        },
        .normal_index => {
            candidates[0] = try std.mem.concat(allocator, u8, &.{ effective_base, "/", name_file, "/index.scss" });
            candidates[1] = try std.mem.concat(allocator, u8, &.{ effective_base, "/", name_file, "/index.sass" });
            candidates[2] = try std.mem.concat(allocator, u8, &.{ effective_base, "/", name_file, "/_index.scss" });
            candidates[3] = try std.mem.concat(allocator, u8, &.{ effective_base, "/", name_file, "/_index.sass" });
            candidate_count = 4;
        },
    }
    defer for (candidates) |candidate| if (candidate) |path| allocator.free(path);

    var found_idx: ?usize = null;
    if (kind == .normal_non_index) {
        for (candidates[0..4], 0..) |candidate_opt, idx| {
            const candidate = candidate_opt.?;
            if (!fileExists(candidate)) continue;
            if (found_idx != null) return error.AmbiguousImport;
            found_idx = idx;
        }
        if (found_idx == null) {
            for (candidates[4..candidate_count], 4..) |candidate_opt, idx| {
                const candidate = candidate_opt.?;
                if (!fileExists(candidate)) continue;
                if (found_idx != null) return error.AmbiguousImport;
                found_idx = idx;
            }
        }
    } else {
        for (candidates[0..candidate_count], 0..) |candidate_opt, idx| {
            const candidate = candidate_opt.?;
            if (!fileExists(candidate)) continue;
            if (found_idx != null) return error.AmbiguousImport;
            found_idx = idx;
        }
    }

    if (found_idx) |idx| return try allocator.dupe(u8, candidates[idx].?);
    return null;
}

fn tryCandidates(allocator: std.mem.Allocator, base: []const u8, name: []const u8) !?[]const u8 {
    inline for ([_]CandidateKind{ .normal_non_index, .normal_index }) |kind| {
        if (try tryCandidatePhase(allocator, base, name, kind)) |path| {
            return path;
        }
    }
    return null;
}

fn fileExists(path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(zsass_io.io, path, .{}) catch return false;
    return stat.kind == .file;
}

//---- Namespace Derivation --------------------------------------------------

fn deriveNamespace(url: []const u8) []const u8 {
    // Get basename (last component)
    var name = std.fs.path.basename(url);

    // Strip extension (.scss, .sass, .css)
    if (std.mem.endsWith(u8, name, ".scss")) {
        name = name[0 .. name.len - 5];
    } else if (std.mem.endsWith(u8, name, ".sass")) {
        name = name[0 .. name.len - 5];
    } else if (std.mem.endsWith(u8, name, ".css")) {
        name = name[0 .. name.len - 4];
    }

    // Strip leading underscore (partial prefix)
    if (name.len > 0 and name[0] == '_') {
        name = name[1..];
    }

    return name;
}

//--- Circular Dependency Detection ------------------------------------------

const DependencyGraph = struct {
    edges: std.StringHashMap(std.ArrayList([]const u8)),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) DependencyGraph {
        return .{
            .edges = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *DependencyGraph) void {
        var it = self.edges.valueIterator();
        while (it.next()) |list| {
            list.deinit(self.allocator);
        }
        self.edges.deinit();
    }

    fn addEdge(self: *DependencyGraph, from: []const u8, to: []const u8) !void {
        const gop = try self.edges.getOrPut(from);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(self.allocator, to);

        // Ensure `to` node exists in graph as well
        const gop2 = try self.edges.getOrPut(to);
        if (!gop2.found_existing) {
            gop2.value_ptr.* = .empty;
        }
    }

    fn hasCycle(self: *DependencyGraph) bool {
        const cycle = self.detectCycle(self.allocator) catch return false;
        if (cycle) |c| {
            self.allocator.free(c);
            return true;
        }
        return false;
    }

    const Color = enum { white, gray, black };

    fn detectCycle(self: *DependencyGraph, allocator: std.mem.Allocator) !?[]const []const u8 {
        var colors = std.StringHashMap(Color).init(allocator);
        defer colors.deinit();

        // Initialize all nodes to white
        var key_it = self.edges.keyIterator();
        while (key_it.next()) |key| {
            try colors.put(key.*, .white);
        }

        // DFS from each unvisited node
        var all_keys: std.ArrayList([]const u8) = .empty;
        defer all_keys.deinit(allocator);
        var key_it2 = self.edges.keyIterator();
        while (key_it2.next()) |key| {
            try all_keys.append(allocator, key.*);
        }

        for (all_keys.items) |node| {
            if (colors.get(node).? == .white) {
                var path: std.ArrayList([]const u8) = .empty;
                defer path.deinit(allocator);
                if (try self.dfsVisit(node, &colors, &path, allocator)) {
                    return try path.toOwnedSlice(allocator);
                }
            }
        }

        return null;
    }

    fn dfsVisit(
        self: *DependencyGraph,
        node: []const u8,
        colors: *std.StringHashMap(Color),
        path: *std.ArrayList([]const u8),
        allocator: std.mem.Allocator,
    ) !bool {
        try colors.put(node, .gray);
        try path.append(allocator, node);

        if (self.edges.get(node)) |neighbors| {
            try path.ensureUnusedCapacity(allocator, 1);
            for (neighbors.items) |neighbor| {
                const color = colors.get(neighbor) orelse .white;
                switch (color) {
                    .gray => {
                        //Found a cycle -- add the back-edge target to close the cycle
                        path.appendAssumeCapacity(neighbor);
                        return true;
                    },
                    .white => {
                        if (try self.dfsVisit(neighbor, colors, path, allocator)) {
                            return true;
                        }
                    },
                    .black => {},
                }
            }
        }

        // Backtrack
        _ = path.pop();
        try colors.put(node, .black);
        return false;
    }
};

//--- Module Cache ----------------------------------------------------------

const ModuleCache = struct {
    modules: std.StringHashMap(*Module),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) ModuleCache {
        return .{
            .modules = std.StringHashMap(*Module).init(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *ModuleCache) void {
        self.modules.deinit();
    }

    fn get(self: *ModuleCache, canonical_url: []const u8) ?*Module {
        return self.modules.get(canonical_url);
    }

    fn put(self: *ModuleCache, canonical_url: []const u8, module: *Module) !void {
        try self.modules.put(canonical_url, module);
    }
};

//---- Forward Application --------------------------------------------------

fn applyForwardRule(
    allocator: std.mem.Allocator,
    member: ModuleMember,
    rule: *const ForwardRule,
) ?ModuleMember {
    _ = allocator;

    // Private members are never forwarded
    if (member.visibility == .private) return null;

    // If `hidden` list is set, exclude members in it
    if (rule.hidden) |hidden| {
        for (hidden) |h| {
            if (std.mem.eql(u8, member.name, h)) return null;
        }
    }

    // If `shown` list is set, only include members in it
    if (rule.shown) |shown| {
        var found = false;
        for (shown) |s| {
            if (std.mem.eql(u8, member.name, s)) {
                found = true;
                break;
            }
        }
        if (!found) return null;
    }

    // Apply prefix if set
    if (rule.prefix) |prefix| {
        // When prefix is applied, the member name becomes prefix + name.
        // Since we don't allocate here, we return a member that signals
        // the prefix should be applied. The caller should handle
        // allocation for the prefixed name. For this implementation we
        // store the original name and let higher-level code combine them.
        // This keeps the function allocation-free.
        _ = prefix;
    }

    return member;
}

//--- Import vs @use Distinction ----------------------------------------------

fn isPlainCssImport(url: []const u8) bool {
    // Starts with http:// or https://
    if (std.mem.startsWith(u8, url, "http://") or
        std.mem.startsWith(u8, url, "https://"))
    {
        return true;
    }

    // Protocol-relative URL (starts with //)
    if (std.mem.startsWith(u8, url, "//")) {
        return true;
    }

    // Ends with .css
    if (std.mem.endsWith(u8, url, ".css")) {
        return true;
    }

    // Is a url() function call
    if (std.mem.startsWith(u8, url, "url(")) {
        return true;
    }

    return false;
}

//--- Tests ----------------------------------------------------------------

test "deriveNamespace: simple name" {
    try std.testing.expectEqualStrings("foo", deriveNamespace("foo"));
}

test "deriveNamespace: path with directories" {
    try std.testing.expectEqualStrings("foo", deriveNamespace("path/to/foo"));
}

test "deriveNamespace: strip partial prefix" {
    try std.testing.expectEqualStrings("foo", deriveNamespace("path/to/_foo"));
}

test "deriveNamespace: strip .scss extension" {
    try std.testing.expectEqualStrings("foo", deriveNamespace("foo.scss"));
}

test "deriveNamespace: strip .sass extension" {
    try std.testing.expectEqualStrings("bar", deriveNamespace("bar.sass"));
}

test "deriveNamespace: strip .css extension" {
    try std.testing.expectEqualStrings("baz", deriveNamespace("baz.css"));
}

test "deriveNamespace: partial with extension" {
    try std.testing.expectEqualStrings("vars", deriveNamespace("_vars.scss"));
}

test "deriveNamespace: path with partial and extension" {
    try std.testing.expectEqualStrings("mixins", deriveNamespace("lib/_mixins.sass"));
}

test "isPlainCssImport: http URL" {
    try std.testing.expect(isPlainCssImport("http://example.com/style.css"));
}

test "isPlainCssImport: https URL" {
    try std.testing.expect(isPlainCssImport("https://cdn.example.com/reset.css"));
}

test "isPlainCssImport: .css extension" {
    try std.testing.expect(isPlainCssImport("vanilla.css"));
}

test "isPlainCssImport: url() function" {
    try std.testing.expect(isPlainCssImport("url(https://example.com/style.css)"));
}

test "isPlainCssImport: .scss is not plain CSS" {
    try std.testing.expect(!isPlainCssImport("styles.scss"));
}

test "isPlainCssImport: bare name is not plain CSS" {
    try std.testing.expect(!isPlainCssImport("foundation"));
}

test "Module: add and get members" {
    const allocator = std.testing.allocator;
    var mod = Module.init(allocator, "test.scss");
    defer mod.deinit();

    try mod.addMember(.{
        .name = "primary-color",
        .kind = .variable,
        .visibility = .public,
    });
    try mod.addMember(.{
        .name = "_internal",
        .kind = .variable,
        .visibility = .private,
    });
    try mod.addMember(.{
        .name = "darken",
        .kind = .function,
        .visibility = .public,
    });

    // Find existing member
    const found = mod.getMember("primary-color", .variable);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("primary-color", found.?.name);
    try std.testing.expectEqual(Visibility.public, found.?.visibility);

    // Wrong kind returns null
    try std.testing.expect(mod.getMember("primary-color", .function) == null);

    // Non-existent member
    try std.testing.expect(mod.getMember("nonexistent", .variable) == null);

    // Function member
    const func = mod.getMember("darken", .function);
    try std.testing.expect(func != null);
}

test "Module: getVisibleMembers filters private" {
    const allocator = std.testing.allocator;
    var mod = Module.init(allocator, "test.scss");
    defer mod.deinit();

    try mod.addMember(.{ .name = "public-var", .kind = .variable, .visibility = .public });
    try mod.addMember(.{ .name = "_private-var", .kind = .variable, .visibility = .private });
    try mod.addMember(.{ .name = "public-fn", .kind = .function, .visibility = .public });
    try mod.addMember(.{ .name = "-private-fn", .kind = .function, .visibility = .private });

    const visible = try mod.getVisibleMembers(allocator);
    defer allocator.free(visible);

    try std.testing.expectEqual(@as(usize, 2), visible.len);
    try std.testing.expectEqualStrings("public-var", visible[0].name);
    try std.testing.expectEqualStrings("public-fn", visible[1].name);
}

test "applyForwardRule: basic pass-through" {
    const member = ModuleMember{
        .name = "color",
        .kind = .variable,
        .visibility = .public,
    };
    const rule = ForwardRule{
        .url = "colors",
        .prefix = null,
        .shown = null,
        .hidden = null,
    };
    const result = applyForwardRule(std.testing.allocator, member, &rule);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("color", result.?.name);
}

test "applyForwardRule: private member is filtered" {
    const member = ModuleMember{
        .name = "_internal",
        .kind = .variable,
        .visibility = .private,
    };
    const rule = ForwardRule{
        .url = "colors",
        .prefix = null,
        .shown = null,
        .hidden = null,
    };
    const result = applyForwardRule(std.testing.allocator, member, &rule);
    try std.testing.expect(result == null);
}

test "applyForwardRule: hidden list" {
    const member = ModuleMember{
        .name = "secret",
        .kind = .variable,
        .visibility = .public,
    };
    const hidden = [_][]const u8{"secret"};
    const rule = ForwardRule{
        .url = "mod",
        .prefix = null,
        .shown = null,
        .hidden = &hidden,
    };
    const result = applyForwardRule(std.testing.allocator, member, &rule);
    try std.testing.expect(result == null);
}

test "applyForwardRule: shown list allows member" {
    const member = ModuleMember{
        .name = "allowed",
        .kind = .variable,
        .visibility = .public,
    };
    const shown = [_][]const u8{"allowed"};
    const rule = ForwardRule{
        .url = "mod",
        .prefix = null,
        .shown = &shown,
        .hidden = null,
    };
    const result = applyForwardRule(std.testing.allocator, member, &rule);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("allowed", result.?.name);
}

test "applyForwardRule: shown list blocks unlisted member" {
    const member = ModuleMember{
        .name = "blocked",
        .kind = .variable,
        .visibility = .public,
    };
    const shown = [_][]const u8{"allowed"};
    const rule = ForwardRule{
        .url = "mod",
        .prefix = null,
        .shown = &shown,
        .hidden = null,
    };
    const result = applyForwardRule(std.testing.allocator, member, &rule);
    try std.testing.expect(result == null);
}

test "applyForwardRule: with prefix" {
    const member = ModuleMember{
        .name = "color",
        .kind = .variable,
        .visibility = .public,
    };
    const rule = ForwardRule{
        .url = "colors",
        .prefix = "clr-",
        .shown = null,
        .hidden = null,
    };
    const result = applyForwardRule(std.testing.allocator, member, &rule);
    try std.testing.expect(result != null);
}

test "DependencyGraph: no cycle in linear chain" {
    const allocator = std.testing.allocator;
    var graph = DependencyGraph.init(allocator);
    defer graph.deinit();

    try graph.addEdge("a", "b");
    try graph.addEdge("b", "c");

    try std.testing.expect(!graph.hasCycle());
}

test "DependencyGraph: simple cycle" {
    const allocator = std.testing.allocator;
    var graph = DependencyGraph.init(allocator);
    defer graph.deinit();

    try graph.addEdge("a", "b");
    try graph.addEdge("b", "c");
    try graph.addEdge("c", "a");

    try std.testing.expect(graph.hasCycle());
}

test "DependencyGraph: self-loop" {
    const allocator = std.testing.allocator;
    var graph = DependencyGraph.init(allocator);
    defer graph.deinit();

    try graph.addEdge("a", "a");

    try std.testing.expect(graph.hasCycle());
}

test "DependencyGraph: detectCycle returns path" {
    const allocator = std.testing.allocator;
    var graph = DependencyGraph.init(allocator);
    defer graph.deinit();

    try graph.addEdge("a", "b");
    try graph.addEdge("b", "c");
    try graph.addEdge("c", "a");

    const cycle = try graph.detectCycle(allocator);
    try std.testing.expect(cycle != null);
    defer allocator.free(cycle.?);

    // The cycle path should contain at least 2 elements and the last
    // should equal an earlier element (closing the cycle)
    try std.testing.expect(cycle.?.len >= 2);
}

test "DependencyGraph: no cycle returns null" {
    const allocator = std.testing.allocator;
    var graph = DependencyGraph.init(allocator);
    defer graph.deinit();

    try graph.addEdge("x", "y");
    try graph.addEdge("y", "z");

    const cycle = try graph.detectCycle(allocator);
    try std.testing.expect(cycle == null);
}

test "ModuleCache: put and get" {
    const allocator = std.testing.allocator;
    var cache = ModuleCache.init(allocator);
    defer cache.deinit();

    var mod = Module.init(allocator, "test.scss");
    defer mod.deinit();

    try cache.put("test.scss", &mod);

    const found = cache.get("test.scss");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("test.scss", found.?.url);
}

test "ModuleCache: get non-existent returns null" {
    const allocator = std.testing.allocator;
    var cache = ModuleCache.init(allocator);
    defer cache.deinit();

    try std.testing.expect(cache.get("nonexistent.scss") == null);
}

test "resolveUrl: relative path with temp files" {
    const allocator = std.testing.allocator;

    // Create a temp directory structure
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try test_utils.touchFile(&tmp_dir.dir, "sub/colors.scss");
    const from_path = try test_utils.joinRealpath(allocator, &tmp_dir.dir, "main.scss");
    defer allocator.free(from_path);

    var result = try resolveUrl(allocator, "./sub/colors", from_path, &.{}, .{});
    try std.testing.expect(result != null);
    defer result.?.deinit();

    try std.testing.expect(std.mem.endsWith(u8, result.?.path, "sub/colors.scss"));
}

test "resolveUrl: load path resolution" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try test_utils.touchFile(&tmp_dir.dir, "lib/utils.scss");
    const tmp_path = try test_utils.realpathAlloc(allocator, &tmp_dir.dir);
    defer allocator.free(tmp_path);

    const lib_path = try std.fs.path.join(allocator, &.{ tmp_path, "lib" });
    defer allocator.free(lib_path);

    const load_paths = [_][]const u8{lib_path};
    var result = try resolveUrl(allocator, "utils", "/some/other/file.scss", &load_paths, .{});
    try std.testing.expect(result != null);
    defer result.?.deinit();

    try std.testing.expect(std.mem.endsWith(u8, result.?.path, "utils.scss"));
}

test "resolveUrl: partial resolution" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try test_utils.touchFile(&tmp_dir.dir, "_variables.scss");
    const tmp_path = try test_utils.realpathAlloc(allocator, &tmp_dir.dir);
    defer allocator.free(tmp_path);

    const load_paths = [_][]const u8{tmp_path};
    var result = try resolveUrl(allocator, "variables", "/other/file.scss", &load_paths, .{});
    try std.testing.expect(result != null);
    defer result.?.deinit();

    try std.testing.expect(std.mem.endsWith(u8, result.?.path, "_variables.scss"));
}

test "resolveUrl: index file resolution" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try test_utils.touchFile(&tmp_dir.dir, "components/index.scss");
    const tmp_path = try test_utils.realpathAlloc(allocator, &tmp_dir.dir);
    defer allocator.free(tmp_path);

    const load_paths = [_][]const u8{tmp_path};
    var result = try resolveUrl(allocator, "components", "/other/file.scss", &load_paths, .{});
    try std.testing.expect(result != null);
    defer result.?.deinit();

    try std.testing.expect(std.mem.endsWith(u8, result.?.path, "components/index.scss"));
}

test "resolveUrl: _index file resolution" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try test_utils.touchFile(&tmp_dir.dir, "mixins/_index.scss");
    const tmp_path = try test_utils.realpathAlloc(allocator, &tmp_dir.dir);
    defer allocator.free(tmp_path);

    const load_paths = [_][]const u8{tmp_path};
    // First try without regular index.scss so _index.scss is found
    var result = try resolveUrl(allocator, "mixins", "/other/file.scss", &load_paths, .{});
    try std.testing.expect(result != null);
    defer result.?.deinit();

    try std.testing.expect(std.mem.endsWith(u8, result.?.path, "mixins/_index.scss"));
}

test "resolveUrl: returns null when not found" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try test_utils.realpathAlloc(allocator, &tmp_dir.dir);
    defer allocator.free(tmp_path);

    const load_paths = [_][]const u8{tmp_path};
    const result = try resolveUrl(allocator, "nonexistent", "/other/file.scss", &load_paths, .{});
    try std.testing.expect(result == null);
}

test "resolveUrl: .sass extension" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try test_utils.touchFile(&tmp_dir.dir, "theme.sass");
    const tmp_path = try test_utils.realpathAlloc(allocator, &tmp_dir.dir);
    defer allocator.free(tmp_path);

    const load_paths = [_][]const u8{tmp_path};
    var result = try resolveUrl(allocator, "theme", "/other/file.scss", &load_paths, .{});
    try std.testing.expect(result != null);
    defer result.?.deinit();

    try std.testing.expect(std.mem.endsWith(u8, result.?.path, "theme.sass"));
}

test "resolveImportUrl: import-only non-index beats normal file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try test_utils.touchFile(&tmp_dir.dir, "other.import.sass");
    try test_utils.touchFile(&tmp_dir.dir, "other.scss");
    const tmp_path = try test_utils.realpathAlloc(allocator, &tmp_dir.dir);
    defer allocator.free(tmp_path);

    var result = try resolveImportUrl(allocator, "other", "/other/file.scss", &.{tmp_path}, .{});
    try std.testing.expect(result != null);
    defer result.?.deinit();

    try std.testing.expect(std.mem.endsWith(u8, result.?.path, "other.import.sass"));
}

test "resolveImportUrl: normal file beats import-only index" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try test_utils.touchFile(&tmp_dir.dir, "other.scss");
    try test_utils.touchFile(&tmp_dir.dir, "other/index.import.scss");
    const tmp_path = try test_utils.realpathAlloc(allocator, &tmp_dir.dir);
    defer allocator.free(tmp_path);

    var result = try resolveImportUrl(allocator, "other", "/other/file.scss", &.{tmp_path}, .{});
    try std.testing.expect(result != null);
    defer result.?.deinit();

    try std.testing.expect(std.mem.endsWith(u8, result.?.path, "other.scss"));
}

test "resolveImportUrl: explicit extension does not resolve directory index" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try test_utils.touchFile(&tmp_dir.dir, "dir.scss/index.scss");
    const tmp_path = try test_utils.realpathAlloc(allocator, &tmp_dir.dir);
    defer allocator.free(tmp_path);

    const result = try resolveImportUrl(allocator, "dir.scss", "/other/file.scss", &.{tmp_path}, .{});
    try std.testing.expect(result == null);
}

test "resolveImportUrl: unresolved relative paths can overlay onto sibling load paths" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(zsass_io.io, "overlay/case");
    try tmp_dir.dir.createDirPath(zsass_io.io, "fixtures");
    const input = try tmp_dir.dir.createFile(zsass_io.io, "overlay/case/input.scss", .{});
    input.close(zsass_io.io);
    const partial = try tmp_dir.dir.createFile(zsass_io.io, "fixtures/_test-hue.scss", .{});
    partial.close(zsass_io.io);

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const overlay_root = try std.fs.path.join(allocator, &.{ tmp_path, "overlay" });
    defer allocator.free(overlay_root);
    const fixture_root = try std.fs.path.join(allocator, &.{ tmp_path, "fixtures" });
    defer allocator.free(fixture_root);
    const input_path = try std.fs.path.join(allocator, &.{ overlay_root, "case", "input.scss" });
    defer allocator.free(input_path);

    const load_paths = [_][]const u8{ overlay_root, fixture_root };
    var result = try resolveImportUrl(allocator, "../test-hue", input_path, &load_paths, .{});
    try std.testing.expect(result != null);
    defer result.?.deinit();

    try expectPathEndsWith(allocator, result.?.path, &.{ "fixtures", "_test-hue.scss" });
}

/// Cross-platform variant of `std.mem.endsWith` for filesystem paths.
/// Both the input path and the expected suffix are normalised to use
/// forward slashes before comparison, so the assertion holds whether
/// the OS returned a POSIX-style path (`/foo/bar`), a native Windows
/// path (`C:\foo\bar`), or a mixed string (zsass's own resolution
/// joins always emit `/`, but `realpath`-style helpers return native
/// separators on Windows). Used by the `resolveUrl` /
/// `resolveImportUrl` tests below.
fn expectPathEndsWith(allocator: std.mem.Allocator, path: []const u8, parts: []const []const u8) !void {
    var normalised: std.ArrayList(u8) = .empty;
    defer normalised.deinit(allocator);
    try normalised.appendSlice(allocator, path);
    std.mem.replaceScalar(u8, normalised.items, '\\', '/');
    const expected = try std.mem.join(allocator, "/", parts);
    defer allocator.free(expected);
    try std.testing.expect(std.mem.endsWith(u8, normalised.items, expected));
}

test "resolveImportUrl: explicit relative paths can resolve from synthetic callers via load paths" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(zsass_io.io, "three_args/w3c");
    const partial = try tmp_dir.dir.createFile(zsass_io.io, "three_args/_test-hue.scss", .{});
    partial.close(zsass_io.io);

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const w3c_dir = try std.fs.path.join(allocator, &.{ tmp_path, "three_args", "w3c" });
    defer allocator.free(w3c_dir);

    var result = try resolveImportUrl(allocator, "../test-hue", "<stdin>", &.{w3c_dir}, .{});
    try std.testing.expect(result != null);
    defer result.?.deinit();

    try expectPathEndsWith(allocator, result.?.path, &.{ "three_args", "_test-hue.scss" });
}

test "resolveImportUrl: missing explicit sibling falls back to load path root" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(zsass_io.io, "src");
    try tmp_dir.dir.createDirPath(zsass_io.io, "variables");
    const input = try tmp_dir.dir.createFile(zsass_io.io, "src/component-entry.scss", .{});
    input.close(zsass_io.io);
    const partial = try tmp_dir.dir.createFile(zsass_io.io, "variables/_colors.scss", .{});
    partial.close(zsass_io.io);

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const input_path = try std.fs.path.join(allocator, &.{ tmp_path, "src", "component-entry.scss" });
    defer allocator.free(input_path);

    var result = try resolveImportUrl(allocator, "./variables/colors", input_path, &.{tmp_path}, .{});
    try std.testing.expect(result != null);
    defer result.?.deinit();

    try expectPathEndsWith(allocator, result.?.path, &.{ "variables", "_colors.scss" });
}

test "resolveUrl: explicit relative paths can resolve from synthetic callers via load paths" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(zsass_io.io, "three_args/w3c");
    const partial = try tmp_dir.dir.createFile(zsass_io.io, "three_args/_test-hue.scss", .{});
    partial.close(zsass_io.io);

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const w3c_dir = try std.fs.path.join(allocator, &.{ tmp_path, "three_args", "w3c" });
    defer allocator.free(w3c_dir);

    var result = try resolveUrl(allocator, "../test-hue", "<stdin>", &.{w3c_dir}, .{});
    try std.testing.expect(result != null);
    defer result.?.deinit();

    try expectPathEndsWith(allocator, result.?.path, &.{ "three_args", "_test-hue.scss" });
}

test "resolveUrl: synthetic callers prefer explicit-relative matches across spec-style load paths" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(zsass_io.io, "spec/core_functions/color/hwb/three_args/w3c");
    const partial = try tmp_dir.dir.createFile(zsass_io.io, "spec/core_functions/color/hwb/three_args/_test-hue.scss", .{});
    partial.close(zsass_io.io);

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const spec_root = try std.fs.path.join(allocator, &.{ tmp_path, "spec" });
    defer allocator.free(spec_root);
    const base_path = try std.fs.path.join(allocator, &.{ spec_root, "core_functions", "color", "hwb" });
    defer allocator.free(base_path);
    const w3c_dir = try std.fs.path.join(allocator, &.{ base_path, "three_args", "w3c" });
    defer allocator.free(w3c_dir);

    const load_paths = [_][]const u8{ w3c_dir, base_path, spec_root };
    var result = try resolveUrl(allocator, "../test-hue", "<stdin>", &load_paths, .{});
    try std.testing.expect(result != null);
    defer result.?.deinit();

    try expectPathEndsWith(allocator, result.?.path, &.{ "spec", "core_functions", "color", "hwb", "three_args", "_test-hue.scss" });
}

test "resolveUrl: synthetic callers can match load-path rooted overlays for explicit relatives" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(zsass_io.io, "spec/core_functions/color/hwb/three_args/w3c");
    const partial = try tmp_dir.dir.createFile(zsass_io.io, "spec/core_functions/color/hwb/three_args/w3c/_test-hue.scss", .{});
    partial.close(zsass_io.io);

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const spec_root = try std.fs.path.join(allocator, &.{ tmp_path, "spec" });
    defer allocator.free(spec_root);
    const base_path = try std.fs.path.join(allocator, &.{ spec_root, "core_functions", "color", "hwb" });
    defer allocator.free(base_path);
    const w3c_dir = try std.fs.path.join(allocator, &.{ base_path, "three_args", "w3c" });
    defer allocator.free(w3c_dir);

    const load_paths = [_][]const u8{ w3c_dir, base_path, spec_root };
    var result = try resolveUrl(allocator, "../test-hue", "<stdin>", &load_paths, .{});
    try std.testing.expect(result != null);
    defer result.?.deinit();

    try expectPathEndsWith(allocator, result.?.path, &.{ "spec", "core_functions", "color", "hwb", "three_args", "w3c", "_test-hue.scss" });
}

test "resolveUrl: synthetic explicit relative paths prefer Sass partials over CSS fallbacks" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(zsass_io.io, "three_args/w3c");
    const scss_partial = try tmp_dir.dir.createFile(zsass_io.io, "three_args/w3c/_test-hue.scss", .{});
    scss_partial.close(zsass_io.io);
    const css_partial = try tmp_dir.dir.createFile(zsass_io.io, "three_args/w3c/_test-hue.css", .{});
    css_partial.close(zsass_io.io);

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const w3c_dir = try std.fs.path.join(allocator, &.{ tmp_path, "three_args", "w3c" });
    defer allocator.free(w3c_dir);

    var result = try resolveUrl(allocator, "../test-hue", "<stdin>", &.{w3c_dir}, .{});
    try std.testing.expect(result != null);
    defer result.?.deinit();

    try expectPathEndsWith(allocator, result.?.path, &.{ "three_args", "w3c", "_test-hue.scss" });
}

test "resolveUrl: load-path bare urls prefer Sass partials over CSS fallbacks" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(zsass_io.io, "fixtures");
    const scss_partial = try tmp_dir.dir.createFile(zsass_io.io, "fixtures/_rate_standing.scss", .{});
    scss_partial.close(zsass_io.io);
    const css_fallback = try tmp_dir.dir.createFile(zsass_io.io, "fixtures/rate_standing.css", .{});
    css_fallback.close(zsass_io.io);

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", allocator);
    defer allocator.free(tmp_path);
    const fixtures_dir = try std.fs.path.join(allocator, &.{ tmp_path, "fixtures" });
    defer allocator.free(fixtures_dir);

    var result = try resolveUrl(allocator, "rate_standing", "<stdin>", &.{fixtures_dir}, .{});
    try std.testing.expect(result != null);
    defer result.?.deinit();

    try expectPathEndsWith(allocator, result.?.path, &.{ "fixtures", "_rate_standing.scss" });
}
