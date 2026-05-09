//! Thread-safe cache to share source file across worker pool.
//!
//! In large multi-entry compilations, hundreds of entries share the same vendor
//! To `@import` partials (compass / fontawesome, etc.), disk is required without cache.
//!IO runs for the number of entries x number of dependencies. `SharedSourceCache` in legacy zsass
//! Provide an equivalent mechanism on the rewrite side.
//!
//! API:
//! - `init(alloc)` / `deinit()`: lifetime management of cache itself
//! - `getOrLoad(path)`: Return borrowed slice if cache hit. If it's miss, use caller alloc.
//! Move buffer read from disk to cache and return slice. The return value is cache
//! Alive and valid. caller is not free.

const std = @import("std");
const zsass_io = @import("../runtime/io.zig");

pub const SharedSourceCache = struct {
    mutex: std.Io.Mutex = .init,
    map: std.StringHashMapUnmanaged([]const u8) = .empty,
    alloc: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SharedSourceCache {
        return .{ .alloc = allocator };
    }

    pub fn deinit(self: *SharedSourceCache) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
        self.map.deinit(self.alloc);
    }

    /// Returns source corresponding to path. If it is a hit, the existing borrow slice, if it is a miss, it is an existing borrow slice.
    /// Read from disk, store in cache, and return slice. The return value is valid while the cache is alive.
    pub fn getOrLoad(self: *SharedSourceCache, path: []const u8) ![]const u8 {
        // Two-stage lock: first check if there is no shared, if it is a miss, release the lock during read,
        // Re-lock + existing check at put (avoid duplicate alloc at race).
        {
            self.mutex.lockUncancelable(zsass_io.io);
            defer self.mutex.unlock(zsass_io.io);
            if (self.map.get(path)) |hit| return hit;
        }

        // disk read is out of lock. Temporary buffer is allocated using self.alloc (matches cache lifetime).
        const file = try std.Io.Dir.cwd().openFile(zsass_io.io, path, .{});
        defer file.close(zsass_io.io);
        var rb: [8192]u8 = undefined;
        var rd = file.reader(zsass_io.io, &rb);
        const source = try rd.interface.allocRemaining(self.alloc, .limited(1 << 29));
        errdefer self.alloc.free(source);

        const key = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(key);

        self.mutex.lockUncancelable(zsass_io.io);
        defer self.mutex.unlock(zsass_io.io);

        if (self.map.get(path)) |hit| {
            // Another worker has already put it: throw away your own buffer
            self.alloc.free(source);
            self.alloc.free(key);
            return hit;
        }
        try self.map.put(self.alloc, key, source);
        return source;
    }
};
