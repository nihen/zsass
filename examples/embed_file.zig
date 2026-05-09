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

    const input_path = if (args.len > 1) args[1] else "examples/sample.scss";
    const output_path = if (args.len > 2) args[2] else "zig-out/examples/embed_file.css";

    const input_dir = std.fs.path.dirname(input_path) orelse ".";
    const load_paths = [_][]const u8{input_dir};

    try ensureParentDir(output_path);

    const source = try readFileAlloc(allocator, input_path);
    defer allocator.free(source);

    var result = try zsass.compileSourceToCssWithSourceMap(
        allocator,
        source,
        input_path,
        load_paths[0..],
        output_path,
        .{},
    );
    defer result.deinit(allocator);

    try writeFile(output_path, result.css);
    try printLine("Wrote {s} ({d} bytes)\n", .{ output_path, result.css.len });

    const map_path = try std.fmt.allocPrint(allocator, "{s}.map", .{output_path});
    defer allocator.free(map_path);
    try writeFile(map_path, result.source_map_json);
    try printLine("Wrote {s} ({d} bytes)\n", .{ map_path, result.source_map_json.len });
}

fn ensureParentDir(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;
    try std.Io.Dir.cwd().createDirPath(zsass_io.io, parent);
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(zsass_io.io, path, .{});
    defer file.close(zsass_io.io);
    var rb: [4096]u8 = undefined;
    var rd = file.reader(zsass_io.io, &rb);
    return try rd.interface.allocRemaining(allocator, .limited(1 << 29));
}

fn writeFile(path: []const u8, contents: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(zsass_io.io, path, .{ .truncate = true });
    defer file.close(zsass_io.io);
    try file.writeStreamingAll(zsass_io.io, contents);
}

fn printLine(comptime format: []const u8, args: anytype) !void {
    var buf: [256]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buf, format, args);
    try std.Io.File.stdout().writeStreamingAll(zsass_io.io, rendered);
}
