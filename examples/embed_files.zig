const std = @import("std");
const zsass = @import("compiler");

const zsass_io = zsass.io_facility;

pub fn main(init: std.process.Init) !void {
    zsass_io.io = init.io;
    const allocator = std.heap.c_allocator;

    var args_list: std.ArrayList([:0]const u8) = .empty;
    defer args_list.deinit(allocator);
    {
        var it: std.process.Args.Iterator = .init(init.minimal.args);
        while (it.next()) |arg| {
            args_list.append(allocator, arg) catch @panic("OOM");
        }
    }
    const args = args_list.items;

    var paths_list: std.ArrayList([]const u8) = .empty;
    defer paths_list.deinit(allocator);
    if (args.len > 1) {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            try paths_list.append(allocator, args[i]);
        }
    } else {
        try paths_list.append(allocator, "examples/sample.scss");
    }
    const paths = paths_list.items;

    const results = try zsass.compileFiles(allocator, paths, .{
        .output_style = .compressed,
        .source_map = false,
        .quiet = true,
        .load_paths = &.{},
        .jobs = 0,
    });
    defer {
        for (results) |*r| r.deinit(allocator);
        allocator.free(results);
    }

    for (paths, results) |path, result| {
        if (result.err) |err| {
            try printLine("FAIL  {s}: {}\n", .{ path, err });
            continue;
        }
        const css = result.css orelse continue;
        try printLine("OK    {s}  ({d} bytes)\n", .{ path, css.len });
        try printLine("{s}\n", .{css});
    }
}

fn printLine(comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buf, fmt, args);
    try std.Io.File.stdout().writeStreamingAll(zsass_io.io, rendered);
}
