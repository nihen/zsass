const std = @import("std");
const zsass = @import("compiler");

const zsass_io = zsass.io_facility;

const inline_source =
    \\@use "sass:math";
    \\
    \\$gap: 0.75rem;
    \\$brand: #25c2a0;
    \\
    \\.card {
    \\  padding: $gap;
    \\  width: math.div(100%, 3);
    \\  border: 2px solid $brand;
    \\  color: $brand;
    \\}
    \\
;

pub fn main(init: std.process.Init) !void {
    zsass_io.io = init.io;
    const allocator = std.heap.c_allocator;

    var result = try zsass.compileSourceToCssWithSourceMap(
        allocator,
        inline_source,
        "embed_basic.scss",
        &.{},
        null,
        .{},
    );
    defer result.deinit(allocator);

    try printSection("--- CSS ---\n", .{});
    try writeRaw(result.css);

    if (result.source_map_json.len == 0) {
        try printSection("\n--- Source map: (none) ---\n", .{});
    } else {
        try printSection("\n--- Source map ({d} bytes) ---\n", .{result.source_map_json.len});
        try writeRaw(result.source_map_json);
        try writeRaw("\n");
    }
}

fn printSection(comptime fmt: []const u8, args: anytype) !void {
    var buf: [256]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buf, fmt, args);
    try writeRaw(rendered);
}

fn writeRaw(data: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(zsass_io.io, data);
}
