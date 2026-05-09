const std = @import("std");
const zsass_io = @import("../runtime/io.zig");

const base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// How `sources` paths are written in the emitted `.map` JSON.
pub const SourceMapUrlsMode = enum { relative, absolute };

pub const SourceContentRange = struct {
    start: u32,
    end: u32,
};

pub const SourceMap = struct {
    allocator: std.mem.Allocator,
    sources: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Parallel to `sources` when `--embed-sources` is enabled. The raw text
    /// of every entry is concatenated back-to-back in `sources_content_bytes`,
    /// and each entry's slice range is recorded in `sources_content_ranges`.
    /// Storing it as a single buffer + offsets keeps `populateEmbedContents`
    /// from doing one heap dupe per source file.
    sources_content_bytes: std.ArrayListUnmanaged(u8) = .empty,
    sources_content_ranges: std.ArrayListUnmanaged(SourceContentRange) = .empty,
    /// Parallel to `sources`: filesystem path (or entry virtual path) used to load `sourcesContent`.
    sources_embed_from: std.ArrayListUnmanaged([]const u8) = .empty,
    names: std.ArrayListUnmanaged([]const u8) = .empty,
    source_index_by_path: std.StringHashMapUnmanaged(u32) = .empty,
    name_index_by_name: std.StringHashMapUnmanaged(u32) = .empty,
    mappings: std.ArrayListUnmanaged(u8) = .empty,

    generated_line: u32 = 0,
    prev_generated_column: i64 = 0,
    prev_source_index: i64 = 0,
    prev_source_line: i64 = 0,
    prev_source_column: i64 = 0,
    prev_name_index: i64 = 0,
    has_segment_on_line: bool = false,

    pub fn init(allocator: std.mem.Allocator) SourceMap {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SourceMap) void {
        for (self.sources.items) |src| {
            self.allocator.free(src);
        }
        for (self.sources_embed_from.items) |p| {
            self.allocator.free(p);
        }
        for (self.names.items) |name| {
            self.allocator.free(name);
        }
        self.sources.deinit(self.allocator);
        self.sources_content_bytes.deinit(self.allocator);
        self.sources_content_ranges.deinit(self.allocator);
        self.sources_embed_from.deinit(self.allocator);
        self.names.deinit(self.allocator);
        self.source_index_by_path.deinit(self.allocator);
        self.name_index_by_name.deinit(self.allocator);
        self.mappings.deinit(self.allocator);
    }

    pub fn addSource(self: *SourceMap, displayed_path: []const u8, content_source_path: []const u8) !u32 {
        if (self.source_index_by_path.get(displayed_path)) |idx| return idx;

        const owned_disp = try self.allocator.dupe(u8, displayed_path);
        errdefer self.allocator.free(owned_disp);
        const owned_phys = try self.allocator.dupe(u8, content_source_path);
        errdefer self.allocator.free(owned_phys);

        const idx: u32 = @intCast(self.sources.items.len);
        try self.sources.append(self.allocator, owned_disp);
        errdefer {
            _ = self.sources.pop();
        }
        try self.sources_embed_from.append(self.allocator, owned_phys);
        errdefer {
            _ = self.sources_embed_from.pop();
        }

        try self.source_index_by_path.put(self.allocator, owned_disp, idx);
        return idx;
    }

    /// Fill `sourcesContent` for JSON output from `sources_embed_from` paths.
    /// All-or-nothing: any read failure surfaces as
    /// `error.SourceMapEmbedReadFailed` and the previous content is left
    /// untouched. The caller (CLI / embedding API) decides whether to abort
    /// or continue without `sourcesContent`.
    pub fn populateEmbedContents(self: *SourceMap, scratch_alloc: std.mem.Allocator, entry_path: []const u8, entry_source: []const u8) !void {
        if (self.sources_embed_from.items.len != self.sources.items.len) return error.InvalidSourceLocation;

        var staged_bytes: std.ArrayListUnmanaged(u8) = .empty;
        errdefer staged_bytes.deinit(self.allocator);
        var staged_ranges: std.ArrayListUnmanaged(SourceContentRange) = .empty;
        errdefer staged_ranges.deinit(self.allocator);
        try staged_ranges.ensureTotalCapacityPrecise(self.allocator, self.sources_embed_from.items.len);

        for (self.sources_embed_from.items) |phys| {
            const start: u32 = @intCast(staged_bytes.items.len);
            if (std.mem.eql(u8, phys, entry_path)) {
                try staged_bytes.appendSlice(self.allocator, entry_source);
            } else {
                const disk = readFileToStringAlloc(scratch_alloc, phys) catch
                    return error.SourceMapEmbedReadFailed;
                defer scratch_alloc.free(disk);
                try staged_bytes.appendSlice(self.allocator, disk);
            }
            const end: u32 = @intCast(staged_bytes.items.len);
            staged_ranges.appendAssumeCapacity(.{ .start = start, .end = end });
        }

        // Commit: free old content only after the staged buffers are ready.
        self.sources_content_bytes.deinit(self.allocator);
        self.sources_content_ranges.deinit(self.allocator);
        self.sources_content_bytes = staged_bytes;
        self.sources_content_ranges = staged_ranges;
    }

    fn readFileToStringAlloc(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        const file = try std.Io.Dir.cwd().openFile(zsass_io.io, path, .{});
        defer file.close(zsass_io.io);
        var rb: [8192]u8 = undefined;
        var rd = file.reader(zsass_io.io, &rb);
        return try rd.interface.allocRemaining(allocator, .limited(1 << 29));
    }

    fn addName(self: *SourceMap, name: []const u8) !u32 {
        if (self.name_index_by_name.get(name)) |idx| return idx;

        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);

        const idx: u32 = @intCast(self.names.items.len);
        try self.names.append(self.allocator, owned);
        errdefer {
            _ = self.names.pop();
        }

        try self.name_index_by_name.put(self.allocator, owned, idx);
        return idx;
    }

    fn newGeneratedLine(self: *SourceMap) !void {
        try self.mappings.append(self.allocator, ';');
        self.generated_line += 1;
        self.prev_generated_column = 0;
        self.has_segment_on_line = false;
    }

    pub fn appendSegment(
        self: *SourceMap,
        gen_line: u32,
        gen_col: u32,
        source_index: ?u32,
        src_line: ?u32,
        src_col: ?u32,
        name_index: ?u32,
    ) !void {
        if (gen_line < self.generated_line) return error.InvalidGeneratedLine;
        while (self.generated_line < gen_line) {
            try self.newGeneratedLine();
        }

        const gen_col_i64: i64 = @intCast(gen_col);
        // Generated columns must monotonically increase within a single line:
        // the writer emits left-to-right and any regression would produce a
        // non-decodable mapping for downstream consumers.
        if (self.has_segment_on_line and gen_col_i64 < self.prev_generated_column) {
            return error.InvalidGeneratedColumn;
        }

        if (self.has_segment_on_line) {
            try self.mappings.append(self.allocator, ',');
        }

        try encodeVlq(&self.mappings, self.allocator, gen_col_i64 - self.prev_generated_column);
        self.prev_generated_column = gen_col_i64;

        if (source_index) |src_idx| {
            const src_line_u32 = src_line orelse return error.InvalidSourceLocation;
            const src_col_u32 = src_col orelse return error.InvalidSourceLocation;

            const src_idx_i64: i64 = @intCast(src_idx);
            try encodeVlq(&self.mappings, self.allocator, src_idx_i64 - self.prev_source_index);
            self.prev_source_index = src_idx_i64;

            const src_line_i64: i64 = @intCast(src_line_u32);
            try encodeVlq(&self.mappings, self.allocator, src_line_i64 - self.prev_source_line);
            self.prev_source_line = src_line_i64;

            const src_col_i64: i64 = @intCast(src_col_u32);
            try encodeVlq(&self.mappings, self.allocator, src_col_i64 - self.prev_source_column);
            self.prev_source_column = src_col_i64;

            if (name_index) |nidx| {
                const name_idx_i64: i64 = @intCast(nidx);
                try encodeVlq(&self.mappings, self.allocator, name_idx_i64 - self.prev_name_index);
                self.prev_name_index = name_idx_i64;
            }
        } else if (src_line != null or src_col != null or name_index != null) {
            return error.InvalidSourceLocation;
        }

        self.has_segment_on_line = true;
    }

    fn writeJson(self: *const SourceMap, writer: anytype) !void {
        try writer.writeAll("{\"version\":3,\"sources\":[");
        for (self.sources.items, 0..) |src, i| {
            if (i != 0) try writer.writeByte(',');
            try writeJsonString(writer, src);
        }
        if (self.sources_content_ranges.items.len == self.sources.items.len) {
            try writer.writeAll("],\"sourcesContent\":[");
            for (self.sources_content_ranges.items, 0..) |range, j| {
                if (j != 0) try writer.writeByte(',');
                const raw = self.sources_content_bytes.items[range.start..range.end];
                try writeJsonString(writer, raw);
            }
            try writer.writeAll("],\"names\":[");
        } else {
            try writer.writeAll("],\"names\":[");
        }
        for (self.names.items, 0..) |name, i| {
            if (i != 0) try writer.writeByte(',');
            try writeJsonString(writer, name);
        }
        try writer.writeAll("],\"mappings\":\"");
        try writer.writeAll(self.mappings.items);
        try writer.writeAll("\"}");
    }

    pub fn toJsonAlloc(self: *const SourceMap, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
        try self.writeJson(&aw.writer);
        out = aw.toArrayList();
        return try out.toOwnedSlice(allocator);
    }

    pub fn toInlineCommentAlloc(self: *const SourceMap, allocator: std.mem.Allocator) ![]u8 {
        const json = try self.toJsonAlloc(allocator);
        defer allocator.free(json);

        const encoded = try percentEncode(allocator, json);
        defer allocator.free(encoded);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        try out.appendSlice(allocator, "/*# sourceMappingURL=data:application/json;charset=utf-8,");
        try out.appendSlice(allocator, encoded);
        try out.appendSlice(allocator, " */");
        return try out.toOwnedSlice(allocator);
    }
};

pub fn percentEncode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, input.len);

    const hex = "0123456789ABCDEF";
    for (input) |c| {
        if ((c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '.' or c == '~')
        {
            try out.append(allocator, c);
        } else {
            try out.ensureUnusedCapacity(allocator, 3);
            out.appendAssumeCapacity('%');
            out.appendAssumeCapacity(hex[c >> 4]);
            out.appendAssumeCapacity(hex[c & 0x0f]);
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn encodeVlq(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: i64) !void {
    // Source-map VLQ is the zig-zag of the signed delta. `i64.min` has no
    // positive complement, and very large positive values would overflow when
    // doubled. Both are well outside any realistic line/column delta, so
    // refuse them rather than wrap silently.
    var vlq: u64 = blk: {
        if (value >= 0) {
            const abs: u64 = @intCast(value);
            if (abs > std.math.maxInt(u64) / 2) return error.InvalidVlq;
            break :blk abs * 2;
        } else {
            if (value == std.math.minInt(i64)) return error.InvalidVlq;
            const abs: u64 = @intCast(-value);
            if (abs > (std.math.maxInt(u64) - 1) / 2) return error.InvalidVlq;
            break :blk abs * 2 + 1;
        }
    };

    while (true) {
        var digit: u6 = @intCast(vlq & 0x1f);
        vlq >>= 5;
        if (vlq != 0) digit |= 0x20;
        try out.append(allocator, base64_alphabet[digit]);
        if (vlq == 0) break;
    }
}

fn decodeVlqOne(input: []const u8, cursor: *usize) !i64 {
    var shift: u6 = 0;
    var value: u64 = 0;

    while (true) {
        if (cursor.* >= input.len) return error.InvalidVlq;
        const ch = input[cursor.*];
        cursor.* += 1;

        const raw = base64Decode(ch) orelse return error.InvalidVlq;
        const cont = (raw & 0x20) != 0;
        const payload: u64 = raw & 0x1f;
        value |= payload << shift;
        shift += 5;
        if (!cont) break;
    }

    const is_neg = (value & 1) != 0;
    const mag: i64 = @intCast(value >> 1);
    return if (is_neg) -mag else mag;
}

fn base64Decode(ch: u8) ?u8 {
    if (ch >= 'A' and ch <= 'Z') return ch - 'A';
    if (ch >= 'a' and ch <= 'z') return 26 + (ch - 'a');
    if (ch >= '0' and ch <= '9') return 52 + (ch - '0');
    if (ch == '+') return 62;
    if (ch == '/') return 63;
    return null;
}

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    const hex = "0123456789abcdef";
                    try writer.writeAll("\\u00");
                    try writer.writeByte(hex[c >> 4]);
                    try writer.writeByte(hex[c & 0x0f]);
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

test "vlq known vectors" {
    const Case = struct { value: i64, encoded: []const u8 };
    const cases = [_]Case{
        .{ .value = 0, .encoded = "A" },
        .{ .value = 1, .encoded = "C" },
        .{ .value = -1, .encoded = "D" },
        .{ .value = 15, .encoded = "e" },
        .{ .value = -15, .encoded = "f" },
        .{ .value = 16, .encoded = "gB" },
        .{ .value = 1000, .encoded = "w+B" },
    };

    for (cases) |c| {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(std.testing.allocator);
        try encodeVlq(&out, std.testing.allocator, c.value);
        try std.testing.expectEqualStrings(c.encoded, out.items);
    }
}

test "vlq round trip (>=8 cases)" {
    const values = [_]i64{ -12345, -2048, -1024, -100, -1, 0, 1, 2, 15, 16, 31, 32, 100, 1000, 16384 };
    for (values) |v| {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(std.testing.allocator);

        try encodeVlq(&out, std.testing.allocator, v);

        var cursor: usize = 0;
        const decoded = try decodeVlqOne(out.items, &cursor);
        try std.testing.expectEqual(v, decoded);
        try std.testing.expectEqual(out.items.len, cursor);
    }
}

test "source map json minimal" {
    var sm = SourceMap.init(std.testing.allocator);
    defer sm.deinit();

    const src = try sm.addSource("input.scss", "input.scss");
    try sm.appendSegment(0, 0, src, 0, 0, null);

    const json = try sm.toJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.find(u8, json, "\"version\":3") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"sources\":[\"input.scss\"]") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"names\":[]") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"mappings\":\"AAAA\"") != null);
}

test "source map generated line gaps" {
    var sm = SourceMap.init(std.testing.allocator);
    defer sm.deinit();

    const src = try sm.addSource("a.scss", "a.scss");
    try sm.appendSegment(0, 0, src, 0, 0, null);
    try sm.newGeneratedLine();
    try sm.newGeneratedLine();
    try sm.appendSegment(2, 0, src, 2, 0, null);

    try std.testing.expectEqualStrings("AAAA;;AAEA", sm.mappings.items);
}

test "source map multi source + name" {
    var sm = SourceMap.init(std.testing.allocator);
    defer sm.deinit();

    const a = try sm.addSource("a.scss", "a.scss");
    const b = try sm.addSource("b.scss", "b.scss");
    const n = try sm.addName("token");

    try sm.appendSegment(0, 0, a, 0, 0, null);
    try sm.appendSegment(0, 4, b, 2, 3, n);

    const json = try sm.toJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.find(u8, json, "\"sources\":[\"a.scss\",\"b.scss\"]") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"names\":[\"token\"]") != null);
}

test "source map dedup addSource/addName" {
    var sm = SourceMap.init(std.testing.allocator);
    defer sm.deinit();

    const a0 = try sm.addSource("dup.scss", "dup.scss");
    const a1 = try sm.addSource("dup.scss", "dup.scss");
    try std.testing.expectEqual(a0, a1);

    const n0 = try sm.addName("x");
    const n1 = try sm.addName("x");
    try std.testing.expectEqual(n0, n1);
}

test "inline comment" {
    var sm = SourceMap.init(std.testing.allocator);
    defer sm.deinit();

    const src = try sm.addSource("input.scss", "input.scss");
    try sm.appendSegment(0, 0, src, 0, 0, null);

    const comment = try sm.toInlineCommentAlloc(std.testing.allocator);
    defer std.testing.allocator.free(comment);

    try std.testing.expect(std.mem.startsWith(u8, comment, "/*# sourceMappingURL=data:application/json;charset=utf-8,"));
    try std.testing.expect(std.mem.endsWith(u8, comment, " */"));
}
