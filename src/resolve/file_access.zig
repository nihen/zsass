//! Which files a compilation may load through `@use`, `@forward`,
//! `@import`, and `meta.load-css()`.
//!
//! Sass resolves these URLs against the importing file, the load paths, and
//! absolute paths, so neither `file_path` nor the load paths confine what a
//! stylesheet can read. `FileImportPolicy.roots` does: a candidate file must
//! lie inside one of the roots, both as written and after symbolic links are
//! resolved.
//!
//! A candidate outside the roots is never touched on disk. When resolution
//! finds nothing it may load and a candidate was refused, it fails with
//! `error.FileImportDenied` whether or not the refused file exists, so the
//! diagnostic does not reveal what is outside the roots.

const std = @import("std");
const zsass_io = @import("../runtime/io.zig");

pub const FileImportPolicy = union(enum) {
    /// No stylesheet is read from disk. Built-in `sass:` modules still load.
    disabled,
    /// Any file the process can read, as Sass resolves it (the default).
    unrestricted,
    /// Only files inside these directories.
    roots: []const []const u8,
};

pub const FileAccess = struct {
    mode: std.meta.Tag(FileImportPolicy),
    /// Each root twice: as given (made absolute) and with symbolic links
    /// resolved. A candidate is written against the first form; the file it
    /// names must lie inside the second.
    lexical_roots: []const []const u8 = &.{},
    canonical_roots: []const []const u8 = &.{},
    cwd: []const u8 = "",

    /// Canonicalize the roots once for the compilation. A root that does not
    /// exist allows nothing.
    pub fn init(allocator: std.mem.Allocator, policy: FileImportPolicy) !FileAccess {
        switch (policy) {
            .disabled => return .{ .mode = .disabled },
            .unrestricted => return .{ .mode = .unrestricted },
            .roots => |roots| {
                const cwd = try zsass_io.realPathAlloc(std.Io.Dir.cwd(), ".", allocator);
                errdefer allocator.free(cwd);
                var lexical: std.ArrayList([]const u8) = .empty;
                errdefer {
                    for (lexical.items) |r| allocator.free(r);
                    lexical.deinit(allocator);
                }
                var canonical: std.ArrayList([]const u8) = .empty;
                errdefer {
                    for (canonical.items) |r| allocator.free(r);
                    canonical.deinit(allocator);
                }
                for (roots) |root| {
                    if (root.len == 0) continue;
                    const real = zsass_io.realPathAlloc(std.Io.Dir.cwd(), root, allocator) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => continue,
                    };
                    errdefer allocator.free(real);
                    const abs = try std.fs.path.resolve(allocator, &.{ cwd, root });
                    errdefer allocator.free(abs);
                    try canonical.append(allocator, real);
                    try lexical.append(allocator, abs);
                }
                return .{
                    .mode = .roots,
                    .lexical_roots = try lexical.toOwnedSlice(allocator),
                    .canonical_roots = try canonical.toOwnedSlice(allocator),
                    .cwd = cwd,
                };
            },
        }
    }

    pub fn deinit(self: *FileAccess, allocator: std.mem.Allocator) void {
        for (self.lexical_roots) |r| allocator.free(r);
        allocator.free(self.lexical_roots);
        for (self.canonical_roots) |r| allocator.free(r);
        allocator.free(self.canonical_roots);
        if (self.cwd.len != 0) allocator.free(self.cwd);
        self.* = undefined;
    }

    pub fn restricts(self: *const FileAccess) bool {
        return self.mode != .unrestricted;
    }

    pub const Placement = enum {
        /// The path leads to an entry inside a root.
        inside,
        /// The path, or a symbolic link on it, leads outside the roots.
        outside,
        /// The path, or something on the way to it, does not exist; what was
        /// looked at lies inside a root.
        missing,
    };

    /// Where `path` leads. With roots, symbolic links on it are followed one
    /// component at a time and only inside the roots: a link whose target
    /// lies outside makes the answer `outside` without the target being
    /// looked at, so the answer does not depend on what exists out there.
    pub fn place(self: *const FileAccess, path: []const u8) Placement {
        switch (self.mode) {
            .unrestricted => return .inside,
            .disabled => return .outside,
            .roots => {},
        }
        var buf: [4 * std.fs.max_path_bytes]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const a = fba.allocator();
        // The path being followed, kept apart from the scratch space that each
        // hop starts afresh, so a chain of links does not run out of room.
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var abs: []const u8 = blk: {
            const resolved = std.fs.path.resolve(a, &.{ self.cwd, path }) catch return .outside;
            if (resolved.len > path_buf.len) return .outside;
            @memcpy(path_buf[0..resolved.len], resolved);
            break :blk path_buf[0..resolved.len];
        };
        var hops: usize = 0;
        while (true) {
            fba.reset();
            // Rewrite a path under a root as given to the same path under the
            // root with its links resolved.
            const root, const rest = self.splitAtRoot(abs) orelse return .outside;
            var current: std.ArrayListUnmanaged(u8) = .empty;
            current.appendSlice(a, root) catch return .outside;
            var it = std.mem.tokenizeScalar(u8, rest, std.fs.path.sep);
            const followed: ?[]const u8 = while (it.next()) |component| {
                const base_len = current.items.len;
                if (base_len == 0 or !std.fs.path.isSep(current.items[base_len - 1])) current.append(a, std.fs.path.sep) catch return .outside;
                current.appendSlice(a, component) catch return .outside;
                const st = std.Io.Dir.cwd().statFile(zsass_io.io, current.items, .{ .follow_symlinks = false }) catch return .missing;
                if (st.kind != .sym_link) continue;
                var target_buf: [std.fs.max_path_bytes]u8 = undefined;
                const n = std.Io.Dir.cwd().readLink(zsass_io.io, current.items, &target_buf) catch return .outside;
                const target = target_buf[0..n];
                const parent = current.items[0..base_len];
                break std.fs.path.resolve(a, &.{ parent, target, it.rest() }) catch return .outside;
            } else null;
            const next = followed orelse return .inside;
            hops += 1;
            if (hops > 40) return .outside;
            // A link may name the root as it was given, not only resolved.
            if (self.splitAtRoot(next) == null) return .outside;
            if (next.len > path_buf.len) return .outside;
            @memcpy(path_buf[0..next.len], next);
            abs = path_buf[0..next.len];
        }
    }

    /// The canonical root `path` lies under and the rest of the path.
    fn splitAtRoot(self: *const FileAccess, path: []const u8) ?struct { []const u8, []const u8 } {
        for (self.canonical_roots, self.lexical_roots) |canonical, lexical| {
            if (inside(canonical, path)) return .{ canonical, path[canonical.len..] };
            if (inside(lexical, path)) return .{ canonical, path[lexical.len..] };
        }
        return null;
    }

    /// True when the file `path` names, symbolic links resolved, lies
    /// inside a root. Only call this for a path `place` put inside.
    pub fn allowsFile(self: *const FileAccess, path: []const u8) bool {
        return switch (self.mode) {
            .unrestricted => true,
            .disabled => false,
            .roots => blk: {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                var fba = std.heap.FixedBufferAllocator.init(&buf);
                const real = zsass_io.realPathAlloc(std.Io.Dir.cwd(), path, fba.allocator()) catch break :blk false;
                break :blk insideAny(self.canonical_roots, real);
            },
        };
    }
};

/// The existence checks of one URL resolution. `denied` records that a
/// candidate was refused, so that a resolution that finds nothing reports the
/// policy rather than a missing file.
pub const Probe = struct {
    access: ?*const FileAccess = null,
    denied: bool = false,

    /// True when the caller may look for `path` on disk.
    pub fn allows(self: *Probe, path: []const u8) bool {
        const access = self.access orelse return true;
        switch (access.place(path)) {
            .inside => return true,
            .missing => return false,
            .outside => {
                self.denied = true;
                return false;
            },
        }
    }

    /// The final check on a file resolution chose.
    pub fn allowsFile(self: *Probe, path: []const u8) bool {
        const access = self.access orelse return true;
        if (access.allowsFile(path)) return true;
        self.denied = true;
        return false;
    }
};

/// `path` is `root` or lies below it, compared by whole path components.
fn inside(root: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    if (root.len != 0 and std.fs.path.isSep(root[root.len - 1])) return true;
    return std.fs.path.isSep(path[root.len]);
}

fn insideAny(roots: []const []const u8, path: []const u8) bool {
    for (roots) |root| {
        if (inside(root, path)) return true;
    }
    return false;
}

test "containment follows path components" {
    try std.testing.expect(inside("/a/b", "/a/b"));
    try std.testing.expect(inside("/a/b", "/a/b/c.scss"));
    try std.testing.expect(!inside("/a/b", "/a/bc/d.scss"));
    try std.testing.expect(!inside("/a/b", "/a"));
    try std.testing.expect(inside("/", "/etc/passwd"));
}

test "disabled refuses every path and records it" {
    var access = try FileAccess.init(std.testing.allocator, .disabled);
    defer access.deinit(std.testing.allocator);
    var probe: Probe = .{ .access = &access };
    try std.testing.expect(!probe.allows("/tmp/x.scss"));
    try std.testing.expect(probe.denied);
}
