const std = @import("std");

/// Per-worker store of import-preamble resolve checkpoints (multi-entry CLI
/// batches). Keyed by the canonical resolved path of an entry's first leading
/// textual `@import`. The payload is a resolver-private snapshot allocated in
/// `arena`; a `blocked` entry marks a key whose capture failed validation and
/// must not be retried within this worker. Content per path is frozen for the
/// process lifetime by SharedSourceCache, so the path alone identifies the
/// imported chain.
pub const PreambleCheckpointStore = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.StringHashMapUnmanaged(?*const anyopaque) = .empty,

    pub const Lookup = union(enum) {
        absent,
        blocked,
        hit: *const anyopaque,
    };

    pub fn init(backing: std.mem.Allocator) PreambleCheckpointStore {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn deinit(self: *PreambleCheckpointStore) void {
        // entries' table and keys live in the arena.
        self.arena.deinit();
    }

    pub fn lookup(self: *const PreambleCheckpointStore, key: []const u8) Lookup {
        const slot = self.entries.get(key) orelse return .absent;
        if (slot) |payload| return .{ .hit = payload };
        return .blocked;
    }

    /// `payload == null` blocks the key (capture validation failed).
    pub fn put(self: *PreambleCheckpointStore, key: []const u8, payload: ?*const anyopaque) !void {
        const a = self.arena.allocator();
        const owned_key = try a.dupe(u8, key);
        try self.entries.put(a, owned_key, payload);
    }
};
