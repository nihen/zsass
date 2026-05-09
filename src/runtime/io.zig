const std = @import("std");

/// Global Io instance, set by main() at startup.
/// For use by modules that don't have direct access to process.Init.
pub var io: std.Io = std.Io.Threaded.global_single_threaded.io();

/// Wrapper around Dir.realPathFileAlloc that returns []u8 instead of [:0]u8,
/// so that callers can free with the same allocator without sentinel mismatch.
pub fn realPathAlloc(dir: std.Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const result_z: [:0]u8 = try dir.realPathFileAlloc(io, path, allocator);
    defer allocator.free(result_z);
    return try allocator.dupe(u8, result_z);
}
