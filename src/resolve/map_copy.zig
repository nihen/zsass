const std = @import("std");

fn totalStringMapKeyBytes(comptime V: type, map: *const std.StringHashMapUnmanaged(V)) usize {
    var total: usize = 0;
    var it = map.iterator();
    while (it.next()) |entry| {
        total += entry.key_ptr.*.len;
    }
    return total;
}

pub fn copyStringMapWithOwnedKeys(
    comptime V: type,
    alloc: std.mem.Allocator,
    dst: *std.StringHashMapUnmanaged(V),
    src: *const std.StringHashMapUnmanaged(V),
) !void {
    const total = totalStringMapKeyBytes(V, src);
    const storage = try alloc.alloc(u8, total);
    var cursor: usize = 0;
    var it = src.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const begin = cursor;
        cursor += key.len;
        if (key.len != 0) @memcpy(storage[begin..cursor], key);
        try dst.put(alloc, storage[begin..cursor], entry.value_ptr.*);
    }
    std.debug.assert(cursor == total);
}

pub fn copyStringSetWithOwnedKeys(
    alloc: std.mem.Allocator,
    dst: *std.StringHashMapUnmanaged(void),
    src: *const std.StringHashMapUnmanaged(void),
) !void {
    const total = totalStringMapKeyBytes(void, src);
    const storage = try alloc.alloc(u8, total);
    var cursor: usize = 0;
    var it = src.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const begin = cursor;
        cursor += key.len;
        if (key.len != 0) @memcpy(storage[begin..cursor], key);
        try dst.put(alloc, storage[begin..cursor], {});
    }
    std.debug.assert(cursor == total);
}
