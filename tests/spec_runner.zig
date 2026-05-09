const std = @import("std");
const builtin = @import("builtin");
const zsass_options = @import("zsass_options");
const version_string = zsass_options.version;
const compiler = if (builtin.is_test)
    struct {
        pub const CompileOptions = struct {};
        pub fn compileSourceToCss(_: std.mem.Allocator, _: []const u8, _: []const u8, _: []const []const u8, _: CompileOptions) ![]u8 {
            return error.CompilerModuleUnavailable;
        }
        pub fn setCompileErrorSinkFd(_: ?i32) void {}
    }
else
    @import("compiler");

/// When true, only FAIL lines, a progress counter, and the final summary are printed.
var quiet_mode: bool = false;
/// When true, compile-error tags are aggregated and dumped at the end.
var structured_errors: bool = false;

/// Aggregated error tag counts across all HRX files (parent-side only).
var error_tag_counts: std.StringArrayHashMapUnmanaged(u32) = .empty;

/// Aggregated error-with-detail counts, keyed by `<tag>:<detail>` (e.g. `BuiltinType:color.same`).
/// Source is the line where vm side dispatch catch directly sends `TAGD=<errorName>:<builtin_name>\n` to sink fd.
/// parent-side only. dump is count descending at the end, top N only.
var error_detail_counts: std.StringArrayHashMapUnmanaged(u32) = .empty;

/// When non-null (child process after fork), compile-error tags are written as
/// `TAG=<errorName>\n` lines to this fd. Parent leaves this as null.
var error_tag_sink_fd: ?i32 = null;

fn printProgress(summary: *const TestSummary) void {
    const done = summary.passed + summary.failed + summary.errors;
    std.debug.print("\r  sass-spec: {d} done, {d} failed", .{ done, summary.failed });
}

// ============================================================
// HRX Parser
// ============================================================

pub const HrxEntry = struct {
    filename: []const u8,
    content: []const u8,
};

pub const HrxArchive = struct {
    entries: std.ArrayList(HrxEntry) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HrxArchive {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HrxArchive) void {
        self.entries.deinit(self.allocator);
    }

    pub fn getEntry(self: *const HrxArchive, name: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.filename, name)) {
                return entry.content;
            }
        }
        return null;
    }

    /// Get all test cases from the archive.
    /// Each test case is identified by its directory prefix (the path before input.scss/input.sass/output.css).
    /// Returns a list of unique directory prefixes.
    pub fn getTestCases(self: *const HrxArchive, allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
        var cases: std.ArrayList([]const u8) = .empty;
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();

        for (self.entries.items) |entry| {
            if (testCasePrefixForEntry(entry.filename)) |prefix| {
                try appendUniqueCasePrefix(&cases, &seen, allocator, prefix);
            }
        }

        std.mem.sort([]const u8, cases.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        return cases;
    }

    /// Check if a filename within a test case prefix is a supplementary file
    /// (not input.scss, output.css, error, etc.)
    fn isSupplementaryFile(rel_name: []const u8) bool {
        if (std.mem.eql(u8, rel_name, "input.scss")) return false;
        if (std.mem.eql(u8, rel_name, "input.sass")) return false;
        if (std.mem.eql(u8, rel_name, "output.css")) return false;
        if (std.mem.eql(u8, rel_name, "error")) return false;
        if (std.mem.eql(u8, rel_name, "warning")) return false;
        if (std.mem.eql(u8, rel_name, "options.yml")) return false;
        if (std.mem.startsWith(u8, rel_name, "error-")) return false;
        if (std.mem.startsWith(u8, rel_name, "output-")) return false;
        return true;
    }

    /// Check if a test case has any supplementary files.
    /// Also checks ancestor directories of prefix for shared files.
    pub fn hasSupplementaryFiles(
        self: *const HrxArchive,
        prefix: []const u8,
    ) bool {
        for (self.entries.items) |entry| {
            // Direct match: files under the test prefix
            if (std.mem.startsWith(u8, entry.filename, prefix)) {
                const rel_name = entry.filename[prefix.len..];
                if (rel_name.len == 0) continue;
                if (isSupplementaryFile(rel_name)) return true;
            }
            // Ancestor match: files in parent directories of prefix
            // e.g., prefix="mixin/trailing_comma/positional/" should find "mixin/_utils.scss"
            if (entry.filename.len > 0 and !std.mem.startsWith(u8, entry.filename, prefix)) {
                if (isParentEntryOfPrefix(entry.filename, prefix)) {
                    const basename = std.fs.path.basename(entry.filename);
                    if (isSupplementaryFile(basename)) return true;
                } else if (std.fs.path.dirname(entry.filename) == null) {
                    // Root-level file (no directory): available to all test prefixes
                    if (isSupplementaryFile(entry.filename)) return true;
                }
            }
        }
        return false;
    }
};

fn appendUniqueCasePrefix(
    cases: *std.ArrayList([]const u8),
    seen: *std.StringHashMap(void),
    allocator: std.mem.Allocator,
    prefix: []const u8,
) !void {
    if (seen.contains(prefix)) return;
    try seen.put(prefix, {});
    try cases.append(allocator, prefix);
}

fn testCasePrefixForEntry(filename: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, filename, "input.scss") or std.mem.eql(u8, filename, "input.sass")) {
        return "";
    }
    if (std.mem.endsWith(u8, filename, "/input.scss")) {
        return filename[0 .. filename.len - "input.scss".len];
    }
    if (std.mem.endsWith(u8, filename, "/input.sass")) {
        return filename[0 .. filename.len - "input.sass".len];
    }
    return null;
}

fn isParentEntryOfPrefix(entry_filename: []const u8, prefix: []const u8) bool {
    const entry_dir = std.fs.path.dirname(entry_filename) orelse return false;
    const entry_dir_with_slash_len = entry_dir.len + 1;
    return entry_dir_with_slash_len <= prefix.len and
        std.mem.startsWith(u8, prefix, entry_filename[0..entry_dir_with_slash_len]);
}

const boundary = "<===>";

pub fn parseHrx(allocator: std.mem.Allocator, content: []const u8) !HrxArchive {
    var archive = HrxArchive.init(allocator);
    errdefer archive.deinit();

    var pos: usize = 0;
    const len = content.len;

    while (pos < len) {
        // Skip separator lines (lines containing only '=')
        if (isSeparatorLine(content, pos)) {
            pos = skipLine(content, pos);
            continue;
        }

        // Skip empty boundary markers (just "<===>\n" with no filename)
        if (pos + 5 <= len and std.mem.eql(u8, content[pos .. pos + 5], "<===>")) {
            const rest_start = pos + 5;
            if (rest_start >= len or content[rest_start] == '\n' or content[rest_start] == '\r') {
                pos = skipLine(content, pos);
                continue;
            }
        }

        // Look for boundary marker (allow optional whitespace after marker)
        if (std.mem.startsWith(u8, content[pos..], boundary)) {
            pos += boundary.len;
            while (pos < len and (content[pos] == ' ' or content[pos] == '\t')) : (pos += 1) {}

            // Extract filename (until end of line)
            const filename_end = std.mem.findScalar(u8, content[pos..], '\n') orelse (len - pos);
            var filename = content[pos .. pos + filename_end];
            // Trim trailing \r
            if (filename.len > 0 and filename[filename.len - 1] == '\r') {
                filename = filename[0 .. filename.len - 1];
            }
            // Trim trailing whitespace
            filename = std.mem.trimEnd(u8, filename, " \t");
            pos += filename_end;
            if (pos < len) pos += 1; // skip \n

            // Extract content until next boundary or end
            const content_start = pos;
            var content_end = len;

            // Scan forward for the next boundary marker
            while (pos < len) {
                if (std.mem.startsWith(u8, content[pos..], "<===>")) {
                    content_end = pos;
                    break;
                }
                if (isSeparatorLine(content, pos)) {
                    // Check if the line after the separator is a boundary
                    const after_sep = skipLine(content, pos);
                    if (after_sep < len and std.mem.startsWith(u8, content[after_sep..], "<===>")) {
                        content_end = pos;
                        break;
                    }
                }
                pos = skipLine(content, pos);
            }

            const entry_content = content[content_start..content_end];

            if (filename.len > 0) {
                try archive.entries.append(allocator, .{
                    .filename = filename,
                    .content = entry_content,
                });
            }
        } else {
            pos = skipLine(content, pos);
        }
    }

    return archive;
}

fn skipLine(content: []const u8, start: usize) usize {
    var pos = start;
    while (pos < content.len and content[pos] != '\n') : (pos += 1) {}
    if (pos < content.len) pos += 1; // skip \n
    return pos;
}

fn isSeparatorLine(content: []const u8, pos: usize) bool {
    if (pos >= content.len or content[pos] != '=') return false;
    var i = pos;
    while (i < content.len and content[i] == '=') : (i += 1) {}
    // Must be followed by newline or end of content, and have enough '='s
    if (i - pos < 10) return false; // at least 10 '=' characters
    if (i >= content.len or content[i] == '\n' or content[i] == '\r') return true;
    return false;
}

// ============================================================
// Test Runner
// ============================================================

pub const TestResult = enum {
    pass,
    fail,
    skip,
    error_result,
};

pub const TestSummary = struct {
    total: u32 = 0,
    passed: u32 = 0,
    failed: u32 = 0,
    skipped: u32 = 0,
    errors: u32 = 0,
};

/// Per-HRX timeout in seconds (default 30s, override with ZSASS_TEST_TIMEOUT env var)
const DEFAULT_HRX_TIMEOUT_SEC: u32 = 30;

fn getHrxTimeoutNs() u64 {
    const env_val = std.c.getenv("ZSASS_TEST_TIMEOUT") orelse return @as(u64, DEFAULT_HRX_TIMEOUT_SEC) * std.time.ns_per_s;
    const secs = std.fmt.parseInt(u32, std.mem.span(env_val), 10) catch return @as(u64, DEFAULT_HRX_TIMEOUT_SEC) * std.time.ns_per_s;
    return @as(u64, secs) * std.time.ns_per_s;
}

fn noteErrorTag(allocator: std.mem.Allocator, name: []const u8) void {
    if (!structured_errors) return;
    const gop = error_tag_counts.getOrPut(allocator, name) catch return;
    if (gop.found_existing) {
        gop.value_ptr.* += 1;
        return;
    }

    const owned = allocator.dupe(u8, name) catch {
        error_tag_counts.orderedRemoveAt(gop.index);
        return;
    };
    gop.key_ptr.* = owned;
    gop.value_ptr.* = 1;
}

fn noteErrorDetail(allocator: std.mem.Allocator, key: []const u8) void {
    if (!structured_errors) return;
    const gop = error_detail_counts.getOrPut(allocator, key) catch return;
    if (gop.found_existing) {
        gop.value_ptr.* += 1;
        return;
    }

    const owned = allocator.dupe(u8, key) catch {
        error_detail_counts.orderedRemoveAt(gop.index);
        return;
    };
    gop.key_ptr.* = owned;
    gop.value_ptr.* = 1;
}

fn parseSummaryField(field: []const u8) ?u32 {
    if (field.len == 0) return null;
    return std.fmt.parseInt(u32, field, 10) catch null;
}

fn handleChildProtocolLine(
    allocator: std.mem.Allocator,
    line_raw: []const u8,
    summary: *TestSummary,
    got_summary: *bool,
) void {
    const line = std.mem.trim(u8, line_raw, "\r\n\t ");
    if (line.len == 0) return;

    if (std.mem.startsWith(u8, line, "TAGD=")) {
        const detail = line["TAGD=".len..];
        if (detail.len > 0) noteErrorDetail(allocator, detail);
        return;
    }

    if (std.mem.startsWith(u8, line, "TAG=")) {
        const tag_name = line["TAG=".len..];
        if (tag_name.len > 0) noteErrorTag(allocator, tag_name);
        return;
    }

    if (!std.mem.startsWith(u8, line, "SUMMARY ")) return;
    if (got_summary.*) return;

    var iter = std.mem.splitScalar(u8, line["SUMMARY ".len..], ' ');
    const passed = parseSummaryField(iter.next() orelse return) orelse return;
    const failed = parseSummaryField(iter.next() orelse return) orelse return;
    const errors = parseSummaryField(iter.next() orelse return) orelse return;
    const total = parseSummaryField(iter.next() orelse return) orelse return;
    const skipped = parseSummaryField(iter.next() orelse return) orelse return;

    summary.passed += passed;
    summary.failed += failed;
    summary.errors += errors;
    summary.total += total;
    summary.skipped += skipped;
    got_summary.* = true;
}

/// Fork-based sandbox for processHrxFile.
/// Child process runs the HRX tests and writes results to a pipe.
/// Parent waits with a timeout; kills child on hang or crash.
fn processHrxFileSandboxed(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    filename: []const u8,
    rel_path: []const u8,
    base_path: []const u8,
    dir_rel_path: []const u8,
    summary: *TestSummary,
    failures: *std.ArrayList(FailureInfo),
) !void {
    // Create a pipe for child  ->  parent communication
    var pipe_fds: [2]i32 = undefined;
    {
        const rc = std.os.linux.pipe(&pipe_fds);
        if (rc > 0xfffffffffffff000) return error.SystemResources;
    }
    const read_fd = pipe_fds[0];
    const write_fd = pipe_fds[1];

    const pipe_resize_cmd: i32 = if (@hasDecl(std.os.linux.F, "SETPIPE_SZ")) std.os.linux.F.SETPIPE_SZ else 1031;
    _ = std.os.linux.fcntl(write_fd, pipe_resize_cmd, 1024 * 1024);

    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;

    if (pid == 0) {
        // ===== CHILD PROCESS =====
        _ = std.os.linux.close(read_fd);

        // In quiet mode, suppress compiler Debug/Warning/Error output
        if (quiet_mode) {
            const devnull = std.c.open("/dev/null", @bitCast(std.c.O{ .ACCMODE = .WRONLY }), @as(std.c.mode_t, 0));
            _ = std.c.dup2(devnull, 2);
            _ = std.os.linux.close(devnull);
        }

        // Limit child memory to 1.5GB to prevent runaway allocations
        // (arena allocator accumulates ~300-400MB for 999-iteration map.merge loops)
        {
            const mem_limit: u64 = 1536 * 1024 * 1024;
            if (std.posix.getrlimit(.AS)) |rl| {
                std.posix.setrlimit(.AS, .{ .cur = mem_limit, .max = rl.max }) catch {};
            } else |_| {}
        }

        // Run the actual HRX test processing
        var child_summary = TestSummary{};
        error_tag_sink_fd = write_fd;
        //Teach detail sink to VM builtin dispatch catch (for TAGD line output).
        compiler.setCompileErrorSinkFd(write_fd);
        processHrxFile(allocator, dir, filename, rel_path, base_path, dir_rel_path, &child_summary, failures) catch {
            // Write error marker and exit
            const err_buf = std.fmt.comptimePrint("SUMMARY 0 0 1 1 0\n", .{});
            _ = std.c.write(write_fd, err_buf.ptr, err_buf.len);
            _ = std.os.linux.close(write_fd);
            std.process.exit(1);
        };

        // Write summary as "SUMMARY passed failed errors total skipped\n"
        var result_buf: [128]u8 = undefined;
        const result_str = std.fmt.bufPrint(&result_buf, "SUMMARY {d} {d} {d} {d} {d}\n", .{
            child_summary.passed,
            child_summary.failed,
            child_summary.errors,
            child_summary.total,
            child_summary.skipped,
        }) catch {
            _ = std.os.linux.close(write_fd);
            std.process.exit(1);
        };
        _ = std.c.write(write_fd, result_str.ptr, result_str.len);
        _ = std.os.linux.close(write_fd);
        std.process.exit(0);
    }

    // ===== PARENT PROCESS =====
    _ = std.os.linux.close(write_fd);

    // Wait for child with timeout using poll
    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = read_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    const timeout_ns = getHrxTimeoutNs();
    const timeout_ms: i32 = @intCast(timeout_ns / std.time.ns_per_ms);

    const poll_result = std.posix.poll(&poll_fds, timeout_ms) catch 0;

    if (poll_result == 0) {
        // Timeout -- kill the child
        std.debug.print("  TIMEOUT: {s} (killed after {d}s)\n", .{ rel_path, timeout_ns / std.time.ns_per_s });
        std.posix.kill(pid, std.posix.SIG.KILL) catch {};
        _ = std.c.waitpid(pid, null, 0);
        _ = std.os.linux.close(read_fd);

        // Count all tests in this HRX as errors (we don't know the count, use 1)
        summary.total += 1;
        summary.errors += 1;
        return;
    }

    // Read result lines from pipe until EOF.
    var got_summary = false;
    var read_buf: [4096]u8 = undefined;
    var carry: [256]u8 = undefined;
    var carry_len: usize = 0;

    while (true) {
        const n_raw = std.c.read(read_fd, &read_buf, read_buf.len);
        if (n_raw <= 0) break;

        const chunk = read_buf[0..@as(usize, @intCast(n_raw))];
        var start: usize = 0;
        while (start < chunk.len) {
            const rel_nl = std.mem.findScalar(u8, chunk[start..], '\n') orelse {
                const tail = chunk[start..];
                if (tail.len <= carry.len - carry_len) {
                    @memcpy(carry[carry_len .. carry_len + tail.len], tail);
                    carry_len += tail.len;
                } else {
                    carry_len = 0;
                }
                break;
            };

            const end = start + rel_nl;
            const piece = chunk[start..end];
            if (carry_len == 0) {
                handleChildProtocolLine(allocator, piece, summary, &got_summary);
            } else {
                if (piece.len <= carry.len - carry_len) {
                    @memcpy(carry[carry_len .. carry_len + piece.len], piece);
                    carry_len += piece.len;
                    handleChildProtocolLine(allocator, carry[0..carry_len], summary, &got_summary);
                }
                carry_len = 0;
            }
            start = end + 1;
        }
    }
    if (carry_len > 0) {
        handleChildProtocolLine(allocator, carry[0..carry_len], summary, &got_summary);
    }
    _ = std.os.linux.close(read_fd);

    // Wait for child to finish and check exit status
    var wait_status: c_int = 0;
    _ = std.c.waitpid(pid, &wait_status, 0);
    const wait_result_status = wait_status;
    const status = wait_result_status;

    // Check if child was killed by a signal (crash)
    if (std.posix.W.IFSIGNALED(@bitCast(status))) {
        const sig = std.posix.W.TERMSIG(@bitCast(status));
        std.debug.print("  CRASH: {s} (signal {d})\n", .{ rel_path, sig });
        summary.total += 1;
        summary.errors += 1;
        return;
    }

    if (!got_summary) {
        std.debug.print("  ERROR: {s} (no output from child)\n", .{rel_path});
        summary.total += 1;
        summary.errors += 1;
        return;
    }
    if (quiet_mode) printProgress(summary);
}

const FailureInfo = struct {
    test_name: []const u8,
    message: []const u8,
};

pub fn runSpecTests(
    allocator: std.mem.Allocator,
    spec_dir: []const u8,
    filter: ?[]const u8,
) !TestSummary {
    var summary = TestSummary{};
    var failures: std.ArrayList(FailureInfo) = .empty;
    if (structured_errors and error_tag_counts.count() != 0) {
        var stale_it = error_tag_counts.iterator();
        while (stale_it.next()) |entry| allocator.free(entry.key_ptr.*);
        error_tag_counts.deinit(allocator);
        error_tag_counts = .empty;
    }
    if (structured_errors and error_detail_counts.count() != 0) {
        var stale_d_it = error_detail_counts.iterator();
        while (stale_d_it.next()) |entry| allocator.free(entry.key_ptr.*);
        error_detail_counts.deinit(allocator);
        error_detail_counts = .empty;
    }
    defer {
        for (failures.items) |f| {
            allocator.free(f.test_name);
            allocator.free(f.message);
        }
        failures.deinit(allocator);
    }

    // Walk through the spec directory looking for .hrx files
    var dir = std.Io.Dir.openDirAbsolute(std.Io.Threaded.global_single_threaded.io(), spec_dir, .{
        .iterate = true,
    }) catch |err| {
        if (!builtin.is_test) {
            std.debug.print("Error opening spec directory '{s}': {}\n", .{ spec_dir, err });
        }
        summary.errors += 1;
        return summary;
    };
    defer dir.close(std.Io.Threaded.global_single_threaded.io());

    try walkDir(allocator, dir, spec_dir, "", filter, &summary, &failures);

    // Print summary
    if (quiet_mode) std.debug.print("\n", .{}); // close \r progress line
    std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
    std.debug.print("sass-spec Test Results\n", .{});
    std.debug.print("=" ** 60 ++ "\n", .{});
    const effective_total = summary.total - summary.skipped;
    std.debug.print("Total:   {d} ({d} - {d} skipped)\n", .{ effective_total, summary.total, summary.skipped });
    std.debug.print("Passed:  {d}\n", .{summary.passed});
    std.debug.print("Failed:  {d}\n", .{summary.failed});
    std.debug.print("Errors:  {d}\n", .{summary.errors});

    // Summary printed inline during test execution
    if (structured_errors) {
        const ErrorTagEntry = struct {
            name: []const u8,
            count: u32,
        };

        var entries: std.ArrayList(ErrorTagEntry) = .empty;
        defer entries.deinit(allocator);
        var total_tagged: u64 = 0;

        var it = error_tag_counts.iterator();
        while (it.next()) |entry| {
            total_tagged += entry.value_ptr.*;
            entries.append(allocator, .{
                .name = entry.key_ptr.*,
                .count = entry.value_ptr.*,
            }) catch break;
        }

        const Ctx = struct {
            fn lessThan(_: void, a: ErrorTagEntry, b: ErrorTagEntry) bool {
                if (a.count == b.count) return std.mem.lessThan(u8, a.name, b.name);
                return a.count > b.count;
            }
        };
        std.sort.block(ErrorTagEntry, entries.items, {}, Ctx.lessThan);

        const stdout = std.Io.File.stdout();
        var stdout_writer = stdout.writer(std.Io.Threaded.global_single_threaded.io(), &[_]u8{});
        stdout_writer.interface.writeAll("=== Error tag summary ===\n") catch {};
        for (entries.items) |entry| {
            stdout_writer.interface.print("  {d: >4} {s}\n", .{ entry.count, entry.name }) catch {};
        }
        stdout_writer.interface.print("  (total tagged: {d})\n", .{total_tagged}) catch {};
        stdout_writer.interface.flush() catch {};

        var free_it = error_tag_counts.iterator();
        while (free_it.next()) |entry| allocator.free(entry.key_ptr.*);
        error_tag_counts.deinit(allocator);
        error_tag_counts = .empty;

        // detail breakdown (top 40)
        if (error_detail_counts.count() != 0) {
            const DetailEntry = struct {
                name: []const u8,
                count: u32,
            };

            var d_entries: std.ArrayList(DetailEntry) = .empty;
            defer d_entries.deinit(allocator);
            var detail_total: u64 = 0;

            var d_it = error_detail_counts.iterator();
            while (d_it.next()) |entry| {
                detail_total += entry.value_ptr.*;
                d_entries.append(allocator, .{
                    .name = entry.key_ptr.*,
                    .count = entry.value_ptr.*,
                }) catch break;
            }

            const DCtx = struct {
                fn lessThan(_: void, a: DetailEntry, b: DetailEntry) bool {
                    if (a.count == b.count) return std.mem.lessThan(u8, a.name, b.name);
                    return a.count > b.count;
                }
            };
            std.sort.block(DetailEntry, d_entries.items, {}, DCtx.lessThan);

            stdout_writer.interface.writeAll("=== Error detail summary (top 40) ===\n") catch {};
            const show_n = @min(d_entries.items.len, 40);
            for (d_entries.items[0..show_n]) |entry| {
                stdout_writer.interface.print("  {d: >4} {s}\n", .{ entry.count, entry.name }) catch {};
            }
            stdout_writer.interface.print("  (total detailed: {d}, distinct keys: {d})\n", .{ detail_total, d_entries.items.len }) catch {};
            stdout_writer.interface.flush() catch {};

            var free_d_it = error_detail_counts.iterator();
            while (free_d_it.next()) |entry| allocator.free(entry.key_ptr.*);
            error_detail_counts.deinit(allocator);
            error_detail_counts = .empty;
        }
    }

    return summary;
}

fn walkDir(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    base_path: []const u8,
    rel_path: []const u8,
    filter: ?[]const u8,
    summary: *TestSummary,
    failures: *std.ArrayList(FailureInfo),
) !void {
    const WalkEntry = struct {
        name: []const u8,
        kind: std.Io.File.Kind,
    };

    var entries: std.ArrayList(WalkEntry) = .empty;
    defer {
        for (entries.items) |entry| allocator.free(entry.name);
        entries.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next(std.Io.Threaded.global_single_threaded.io())) |entry| {
        try entries.append(allocator, .{
            .name = try cloneSliceAlloc(allocator, entry.name),
            .kind = entry.kind,
        });
    }

    std.mem.sort(WalkEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: WalkEntry, b: WalkEntry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    for (entries.items) |entry| {
        switch (entry.kind) {
            .directory => {
                // Skip hidden directories
                if (entry.name.len > 0 and entry.name[0] == '.') continue;

                const sub_rel = if (rel_path.len == 0)
                    try cloneSliceAlloc(allocator, entry.name)
                else
                    try concatManyAlloc(allocator, &.{ rel_path, "/", entry.name });
                defer allocator.free(sub_rel);

                var sub_dir = dir.openDir(std.Io.Threaded.global_single_threaded.io(), entry.name, .{
                    .iterate = true,
                }) catch continue;
                defer sub_dir.close(std.Io.Threaded.global_single_threaded.io());

                try walkDir(allocator, sub_dir, base_path, sub_rel, filter, summary, failures);
            },
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".hrx")) {
                    const full_rel = if (rel_path.len == 0)
                        try cloneSliceAlloc(allocator, entry.name)
                    else
                        try concatManyAlloc(allocator, &.{ rel_path, "/", entry.name });
                    defer allocator.free(full_rel);

                    // Apply filter
                    if (filter) |f| {
                        if (!containsSubstring(full_rel, f)) continue;
                    }

                    try processHrxFileSandboxed(allocator, dir, entry.name, full_rel, base_path, rel_path, summary, failures);
                }
            },
            else => {},
        }
    }
}

fn containsSubstring(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn cloneSliceAlloc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, source.len);
    @memcpy(out, source);
    return out;
}

fn concatManyAlloc(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var total: usize = 0;
    for (parts) |part| total += part.len;
    const out = try allocator.alloc(u8, total);
    var cursor: usize = 0;
    for (parts) |part| {
        @memcpy(out[cursor .. cursor + part.len], part);
        cursor += part.len;
    }
    return out;
}

fn appendLog(log: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) void {
    log.appendSlice(allocator, text) catch {};
}

fn appendLogCaseLine(
    log: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    prefix: []const u8,
    case_name: []const u8,
) void {
    appendLog(log, allocator, prefix);
    appendLog(log, allocator, case_name);
    appendLog(log, allocator, "\n");
}

fn appendIndentedLog(log: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) void {
    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |line| {
        appendLog(log, allocator, "      |");
        appendLog(log, allocator, line);
        appendLog(log, allocator, "\n");
    }
}

/// Find the spec root directory by looking for "/spec/" or a path ending with "/spec" in base_path.
/// Returns the path up to and including "spec", or null if not found.
fn findSpecRoot(base_path: []const u8) ?[]const u8 {
    // Look for "/spec/" in the path
    if (std.mem.find(u8, base_path, "/spec/")) |idx| {
        return base_path[0 .. idx + 5]; // include "/spec"
    }
    // Check if path ends with "/spec"
    if (std.mem.endsWith(u8, base_path, "/spec")) {
        return base_path;
    }
    return null;
}

fn processHrxFile(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    filename: []const u8,
    rel_path: []const u8,
    base_path: []const u8,
    dir_rel_path: []const u8,
    summary: *TestSummary,
    _: *std.ArrayList(FailureInfo),
) !void {
    // Read the HRX file
    const content = dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), filename, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        std.debug.print("  ERROR reading {s}: {}\n", .{ rel_path, err });
        summary.total += 1;
        summary.errors += 1;
        return;
    };
    defer allocator.free(content);

    // Parse the HRX archive
    var archive = parseHrx(allocator, content) catch |err| {
        std.debug.print("  ERROR parsing {s}: {}\n", .{ rel_path, err });
        summary.total += 1;
        summary.errors += 1;
        return;
    };
    defer archive.deinit();

    // Get test cases from the archive
    var cases = try archive.getTestCases(allocator);
    defer cases.deinit(allocator);

    if (cases.items.len == 0) {
        // No scss test cases found in this file
        return;
    }

    var case_logs: std.ArrayList(u8) = .empty;
    defer {
        if (case_logs.items.len != 0) {
            std.debug.print("{s}", .{case_logs.items});
        }
        case_logs.deinit(allocator);
    }

    for (cases.items) |prefix| {
        const input_scss_name = if (prefix.len == 0)
            "input.scss"
        else
            try concatManyAlloc(allocator, &.{ prefix, "input.scss" });
        defer if (prefix.len != 0) allocator.free(input_scss_name);
        const input_sass_name = if (prefix.len == 0)
            "input.sass"
        else
            try concatManyAlloc(allocator, &.{ prefix, "input.sass" });
        defer if (prefix.len != 0) allocator.free(input_sass_name);

        const output_name = if (prefix.len == 0)
            "output.css"
        else
            try concatManyAlloc(allocator, &.{ prefix, "output.css" });
        defer if (prefix.len != 0) allocator.free(output_name);

        const error_name = if (prefix.len == 0)
            "error"
        else
            try concatManyAlloc(allocator, &.{ prefix, "error" });
        defer if (prefix.len != 0) allocator.free(error_name);

        const input_content_scss = archive.getEntry(input_scss_name);
        const input_content_sass = archive.getEntry(input_sass_name);
        const input_content = input_content_scss orelse input_content_sass;
        const expected_output = archive.getEntry(output_name);
        const expected_error = archive.getEntry(error_name);

        if (input_content == null) continue;

        const test_name = if (prefix.len == 0)
            try cloneSliceAlloc(allocator, rel_path)
        else
            try concatManyAlloc(allocator, &.{ rel_path, "::", prefix[0 .. prefix.len - 1] });
        defer allocator.free(test_name);

        // Check options.yml for :todo: - dart-sass (skip such tests)
        {
            const options_name = if (prefix.len == 0)
                "options.yml"
            else
                try concatManyAlloc(allocator, &.{ prefix, "options.yml" });
            defer if (prefix.len > 0) allocator.free(options_name);

            if (archive.getEntry(options_name)) |options_content| {
                if (std.mem.find(u8, options_content, "todo") != null and
                    std.mem.find(u8, options_content, "dart-sass") != null)
                {
                    summary.total += 1;
                    summary.skipped += 1;
                    appendLogCaseLine(&case_logs, allocator, "  SKIP (todo: dart-sass): ", test_name);
                    continue;
                }
            }
        }

        summary.total += 1;

        // Determine the file extension for .sass detection
        const is_sass_input = (input_content_scss == null and input_content_sass != null);

        // Tests that expect errors: if our compiler also errors, count as pass
        if (expected_error != null and expected_output == null) {
            // Try to compile -- if it errors, that matches the expected behavior
            var test_arena_err = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer test_arena_err.deinit();
            const test_alloc_err = test_arena_err.allocator();

            // Check for supplementary files
            const has_extra_err = archive.hasSupplementaryFiles(prefix);
            var tmp_dir_err: ?TmpDir = null;
            defer if (tmp_dir_err) |*td| td.cleanup();
            var compile_file_path_err: []const u8 = "";
            var compile_load_paths_err: []const []const u8 = &.{};
            var compile_load_paths_err_storage: [3][]const u8 = undefined;

            if (has_extra_err) {
                tmp_dir_err = makeTmpDir() catch {
                    summary.skipped += 1;
                    continue;
                };
                const td = &tmp_dir_err.?;
                for (archive.entries.items) |entry| {
                    if (!std.mem.startsWith(u8, entry.filename, prefix)) continue;
                    const rel_name = entry.filename[prefix.len..];
                    if (rel_name.len == 0) continue;
                    if (std.fs.path.dirname(rel_name)) |parent_dir| {
                        td.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), parent_dir) catch continue;
                    }
                    const file = td.dir.createFile(std.Io.Threaded.global_single_threaded.io(), rel_name, .{}) catch continue;
                    file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), entry.content) catch {
                        file.close(std.Io.Threaded.global_single_threaded.io());
                        continue;
                    };
                    file.close(std.Io.Threaded.global_single_threaded.io());
                }
                {
                    const err_input_ext: []const u8 = if (is_sass_input) "input.sass" else "input.scss";
                    const file = td.dir.createFile(std.Io.Threaded.global_single_threaded.io(), err_input_ext, .{}) catch {
                        summary.skipped += 1;
                        continue;
                    };
                    file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), input_content.?) catch {
                        file.close(std.Io.Threaded.global_single_threaded.io());
                        summary.skipped += 1;
                        continue;
                    };
                    file.close(std.Io.Threaded.global_single_threaded.io());
                }
                const tmp_path_z = realPathAllocNoSentinel(td.dir, ".", test_alloc_err) catch {
                    summary.skipped += 1;
                    continue;
                };
                const tmp_path: []const u8 = tmp_path_z;
                const err_input_ext2: []const u8 = if (is_sass_input) "input.sass" else "input.scss";
                const input_path = std.fs.path.join(test_alloc_err, &.{ tmp_path, err_input_ext2 }) catch {
                    summary.skipped += 1;
                    continue;
                };
                const hrx_dir_err = if (dir_rel_path.len > 0)
                    std.fs.path.join(test_alloc_err, &.{ base_path, dir_rel_path }) catch tmp_path
                else
                    cloneSliceAlloc(test_alloc_err, base_path) catch tmp_path;
                compile_load_paths_err_storage = .{ tmp_path, hrx_dir_err, base_path };
                compile_file_path_err = input_path;
                compile_load_paths_err = compile_load_paths_err_storage[0..];
            }

            // For .sass inputs, set file_path so the compiler detects and converts indented syntax
            if (is_sass_input and (compile_file_path_err.len == 0 or std.mem.eql(u8, compile_file_path_err, "<stdin>"))) {
                compile_file_path_err = "input.sass";
            }

            _ = compiler.compileSourceToCss(
                test_alloc_err,
                input_content.?,
                compile_file_path_err,
                compile_load_paths_err,
                .{},
            ) catch {
                // Compiler errored as expected -- pass
                summary.passed += 1;
                if (!quiet_mode) appendLogCaseLine(&case_logs, allocator, "  PASS (expected error): ", test_name);
                continue;
            };
            // Compiler succeeded but error was expected -- fail
            summary.failed += 1;
            appendLogCaseLine(&case_logs, allocator, "  FAIL: ", test_name);
            appendLog(&case_logs, allocator, "        expected error but compilation succeeded\n");
            continue;
        }

        if (expected_output == null) {
            summary.skipped += 1;
            continue;
        }

        // Use a per-test arena to isolate memory
        var test_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer test_arena.deinit();
        const test_alloc = test_arena.allocator();

        // Check if this test case has supplementary files (for @use/@import)
        const has_extra_files = archive.hasSupplementaryFiles(prefix);

        // Set up temp directory and compile options for multi-file tests
        var tmp_dir: ?TmpDir = null;
        defer if (tmp_dir) |*td| td.cleanup();

        var compile_file_path: []const u8 = "";
        var compile_load_paths: []const []const u8 = &.{};
        var compile_load_paths_storage: [4][]const u8 = undefined;

        if (has_extra_files) {
            // Create a temp directory for this test case
            tmp_dir = makeTmpDir() catch {
                summary.errors += 1;
                continue;
            };
            const td = &tmp_dir.?;

            // Compute HRX stem from rel_path (e.g., "callable/arguments.hrx" -> "callable/arguments")
            // The stem must be relative to spec_root so that @use 'callable/arguments/...' paths resolve.
            const hrx_stem = blk: {
                const basename_hrx = std.fs.path.basename(rel_path);
                const stem = if (std.mem.endsWith(u8, basename_hrx, ".hrx"))
                    basename_hrx[0 .. basename_hrx.len - 4]
                else
                    basename_hrx;
                // Compute the relative path from spec_root to base_path
                const maybe_spec_root = findSpecRoot(base_path);
                const spec_rel_prefix: []const u8 = if (maybe_spec_root) |sr| blk2: {
                    if (base_path.len > sr.len and std.mem.startsWith(u8, base_path, sr)) {
                        // base_path = /path/to/spec/callable -> spec_rel_prefix = "callable"
                        const after_spec = base_path[sr.len..];
                        if (after_spec.len > 0 and after_spec[0] == '/') {
                            break :blk2 after_spec[1..];
                        }
                    }
                    break :blk2 "";
                } else "";
                if (spec_rel_prefix.len > 0 and dir_rel_path.len > 0) {
                    break :blk concatManyAlloc(test_alloc, &.{ spec_rel_prefix, "/", dir_rel_path, "/", stem }) catch "";
                } else if (spec_rel_prefix.len > 0) {
                    break :blk concatManyAlloc(test_alloc, &.{ spec_rel_prefix, "/", stem }) catch "";
                } else if (dir_rel_path.len > 0) {
                    break :blk concatManyAlloc(test_alloc, &.{ dir_rel_path, "/", stem }) catch "";
                } else {
                    break :blk cloneSliceAlloc(test_alloc, stem) catch "";
                }
            };

            // Write all supplementary files to the temp directory
            for (archive.entries.items) |entry| {
                var rel_name: []const u8 = "";
                if (std.mem.startsWith(u8, entry.filename, prefix)) {
                    // Direct child: file under test prefix
                    // When hrx_stem is set, prefix files also need the stem so they
                    // live alongside input.scss (which is written at {hrx_stem}/{prefix}input.scss).
                    const bare = entry.filename[prefix.len..];
                    if (hrx_stem.len > 0) {
                        if (prefix.len > 0) {
                            rel_name = concatManyAlloc(test_alloc, &.{ hrx_stem, "/", prefix, bare }) catch "";
                        } else {
                            rel_name = concatManyAlloc(test_alloc, &.{ hrx_stem, "/", bare }) catch "";
                        }
                    } else {
                        rel_name = bare;
                    }
                } else if (std.fs.path.dirname(entry.filename)) |entry_dir| {
                    // Ancestor file: in a parent directory of prefix
                    const entry_dir_with_slash_len = entry_dir.len + 1;
                    if (entry_dir_with_slash_len <= prefix.len and
                        std.mem.startsWith(u8, prefix, entry.filename[0..entry_dir_with_slash_len]))
                    {
                        // Write with HRX stem prefix so @use paths resolve correctly
                        // e.g., "mixin/_utils.scss" -> "callable/arguments/mixin/_utils.scss"
                        if (hrx_stem.len > 0) {
                            rel_name = concatManyAlloc(test_alloc, &.{ hrx_stem, "/", entry.filename }) catch "";
                        } else {
                            rel_name = entry.filename;
                        }
                    }
                } else {
                    // Root-level file (no directory): write with HRX stem prefix
                    // e.g., "_util.scss" in random.hrx -> "math/random/_util.scss"
                    if (hrx_stem.len > 0) {
                        rel_name = concatManyAlloc(test_alloc, &.{ hrx_stem, "/", entry.filename }) catch "";
                    } else {
                        rel_name = entry.filename;
                    }
                }
                if (rel_name.len == 0) continue;

                // Write all files including input.scss
                // Create parent directories if needed
                if (std.fs.path.dirname(rel_name)) |parent_dir| {
                    td.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), parent_dir) catch continue;
                }

                const file = td.dir.createFile(std.Io.Threaded.global_single_threaded.io(), rel_name, .{}) catch continue;
                file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), entry.content) catch {
                    file.close(std.Io.Threaded.global_single_threaded.io());
                    continue;
                };
                file.close(std.Io.Threaded.global_single_threaded.io());
            }

            // Write input.scss at the correct location within the HRX directory structure
            // so that relative @use paths (e.g., "../util") resolve correctly.
            // The input goes at {hrx_stem}/{prefix}input.scss (or .sass)
            const input_ext: []const u8 = if (is_sass_input) "input.sass" else "input.scss";
            const input_rel_path = blk: {
                if (hrx_stem.len > 0) {
                    break :blk concatManyAlloc(test_alloc, &.{ hrx_stem, "/", prefix, input_ext }) catch input_ext;
                } else if (prefix.len > 0) {
                    break :blk concatManyAlloc(test_alloc, &.{ prefix, input_ext }) catch input_ext;
                } else {
                    break :blk @as([]const u8, input_ext);
                }
            };
            {
                if (std.fs.path.dirname(input_rel_path)) |parent_dir| {
                    td.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), parent_dir) catch {};
                }
                const file = td.dir.createFile(std.Io.Threaded.global_single_threaded.io(), input_rel_path, .{}) catch |err| {
                    appendLog(&case_logs, allocator, "  ERROR writing input.scss for ");
                    appendLog(&case_logs, allocator, test_name);
                    appendLog(&case_logs, allocator, ": ");
                    appendLog(&case_logs, allocator, @errorName(err));
                    appendLog(&case_logs, allocator, "\n");
                    summary.errors += 1;
                    continue;
                };
                file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), input_content.?) catch |err| {
                    file.close(std.Io.Threaded.global_single_threaded.io());
                    appendLog(&case_logs, allocator, "  ERROR writing input.scss content for ");
                    appendLog(&case_logs, allocator, test_name);
                    appendLog(&case_logs, allocator, ": ");
                    appendLog(&case_logs, allocator, @errorName(err));
                    appendLog(&case_logs, allocator, "\n");
                    summary.errors += 1;
                    continue;
                };
                file.close(std.Io.Threaded.global_single_threaded.io());
            }

            // Get the absolute path to the temp directory
            const tmp_path_z = realPathAllocNoSentinel(td.dir, ".", test_alloc) catch |err| {
                appendLog(&case_logs, allocator, "  ERROR getting realpath for ");
                appendLog(&case_logs, allocator, test_name);
                appendLog(&case_logs, allocator, ": ");
                appendLog(&case_logs, allocator, @errorName(err));
                appendLog(&case_logs, allocator, "\n");
                summary.errors += 1;
                continue;
            };
            const tmp_path: []const u8 = tmp_path_z;
            const input_path = std.fs.path.join(test_alloc, &.{ tmp_path, input_rel_path }) catch |err| {
                appendLog(&case_logs, allocator, "  ERROR joining path for ");
                appendLog(&case_logs, allocator, test_name);
                appendLog(&case_logs, allocator, ": ");
                appendLog(&case_logs, allocator, @errorName(err));
                appendLog(&case_logs, allocator, "\n");
                summary.errors += 1;
                continue;
            };

            // Set compile options: file_path for relative resolution,
            // load_paths for bare @use imports
            // Include: tmp_path (for HRX supplementary files),
            //          hrx_dir (for external files next to HRX),
            //          base_path (for spec-root relative imports like "core_functions/list/utils")
            const hrx_dir = if (dir_rel_path.len > 0)
                std.fs.path.join(test_alloc, &.{ base_path, dir_rel_path }) catch tmp_path
            else
                try cloneSliceAlloc(test_alloc, base_path);
            // Find the spec root directory (parent of "spec" in path)
            // to support cross-directory imports like "core_functions/list/utils"
            const spec_root = findSpecRoot(base_path);
            var load_path_count: usize = 3;
            compile_load_paths_storage[0] = tmp_path;
            compile_load_paths_storage[1] = hrx_dir;
            compile_load_paths_storage[2] = base_path;
            if (spec_root != null and !std.mem.eql(u8, spec_root.?, base_path)) {
                compile_load_paths_storage[3] = spec_root.?;
                load_path_count = 4;
            }

            compile_file_path = input_path;
            compile_load_paths = compile_load_paths_storage[0..load_path_count];
        } else {
            // For .sass inputs, set file_path so the compiler knows to convert
            if (is_sass_input) {
                compile_file_path = "input.sass";
            }
            // Even without supplementary files, set load_paths for external module resolution
            const hrx_dir2 = if (dir_rel_path.len > 0)
                std.fs.path.join(test_alloc, &.{ base_path, dir_rel_path }) catch base_path
            else
                cloneSliceAlloc(test_alloc, base_path) catch base_path;
            const spec_root2 = findSpecRoot(base_path);
            var load_path_count2: usize = 2;
            compile_load_paths_storage[0] = hrx_dir2;
            compile_load_paths_storage[1] = base_path;
            if (spec_root2 != null and !std.mem.eql(u8, spec_root2.?, base_path)) {
                compile_load_paths_storage[2] = spec_root2.?;
                load_path_count2 = 3;
            }
            compile_load_paths = compile_load_paths_storage[0..load_path_count2];
        }

        // Try to compile
        const result = compiler.compileSourceToCss(
            test_alloc,
            input_content.?,
            compile_file_path,
            compile_load_paths,
            .{},
        ) catch |e| {
            if (expected_error != null) {
                // Expected error, got error - pass
                summary.passed += 1;
                if (!quiet_mode) appendLogCaseLine(&case_logs, allocator, "  PASS (expected error): ", test_name);
            } else {
                summary.errors += 1;
                appendLog(&case_logs, allocator, "  ERROR: ");
                appendLog(&case_logs, allocator, test_name);
                appendLog(&case_logs, allocator, " (");
                appendLog(&case_logs, allocator, @errorName(e));
                appendLog(&case_logs, allocator, ")\n");
                appendLog(&case_logs, allocator, "    file_path: ");
                appendLog(&case_logs, allocator, compile_file_path);
                appendLog(&case_logs, allocator, "\n");
                for (compile_load_paths) |p| {
                    appendLog(&case_logs, allocator, "    load_path: ");
                    appendLog(&case_logs, allocator, p);
                    appendLog(&case_logs, allocator, "\n");
                }
                if (structured_errors) {
                    const name = @errorName(e);
                    if (error_tag_sink_fd) |fd| {
                        _ = std.c.write(fd, "TAG=", "TAG=".len);
                        _ = std.c.write(fd, name.ptr, name.len);
                        _ = std.c.write(fd, "\n", 1);
                    } else {
                        noteErrorTag(allocator, name);
                    }
                }
            }
            continue;
        };

        // Compare output -- normalize consecutive newlines like the official
        // sass-spec runner's normalizeOutput (collapses \n+  ->  \n).
        const expected_raw = std.mem.trimEnd(u8, expected_output.?, "\n\r");
        const actual_raw = std.mem.trimEnd(u8, result, "\n\r");
        const expected = normalizeNewlines(allocator, expected_raw) catch expected_raw;
        const actual = normalizeNewlines(allocator, actual_raw) catch actual_raw;

        if (std.mem.eql(u8, expected, actual)) {
            summary.passed += 1;
            if (!quiet_mode) appendLogCaseLine(&case_logs, allocator, "  PASS: ", test_name);
        } else {
            summary.failed += 1;
            appendLogCaseLine(&case_logs, allocator, "  FAIL: ", test_name);
            appendLog(&case_logs, allocator, "    Expected:\n");
            appendIndentedLog(&case_logs, allocator, expected);
            appendLog(&case_logs, allocator, "    Actual:\n");
            appendIndentedLog(&case_logs, allocator, actual);
        }
    }
}

/// Normalize output for comparison, matching the official sass-spec runner's
/// `normalizeOutput` which collapses consecutive newlines into one.
fn normalizeNewlines(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, text.len);
    var prev_was_newline = false;
    for (text) |c| {
        if (c == '\n') {
            if (!prev_was_newline) {
                result.appendAssumeCapacity(c);
            }
            prev_was_newline = true;
        } else {
            prev_was_newline = false;
            result.appendAssumeCapacity(c);
        }
    }
    return result.items;
}

fn resolveSpecDirPath(allocator: std.mem.Allocator, spec_dir: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(spec_dir)) {
        return allocator.dupe(u8, spec_dir);
    }

    const cwd = try realPathAllocNoSentinel(std.Io.Dir.cwd(), ".", allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, spec_dir });
}

const TextJsonFormat = enum { text, json };

fn formatTargetTriple(buffer: []u8) []const u8 {
    return std.fmt.bufPrint(
        buffer,
        "{s}-{s}-{s}",
        .{
            @tagName(builtin.target.cpu.arch),
            @tagName(builtin.target.os.tag),
            @tagName(builtin.target.abi),
        },
    ) catch unreachable;
}

const SpecRunnerBuildInfoJson = struct {
    name: []const u8,
    version: []const u8,
    zig: []const u8,
    target: []const u8,
    optimize: []const u8,
    link_libc: bool,
    single_threaded: bool,
    exe_path: ?[]const u8,
};

fn printSpecRunnerBuildInfo(format: TextJsonFormat) void {
    switch (format) {
        .text => printSpecRunnerBuildInfoText(),
        .json => printSpecRunnerBuildInfoJson(),
    }
}

fn printSpecRunnerBuildInfoText() void {
    var target_buf: [96]u8 = undefined;
    const target = formatTargetTriple(&target_buf);
    const exe_path = std.process.executablePathAlloc(std.Io.Threaded.global_single_threaded.io(), std.heap.page_allocator) catch null;
    defer if (exe_path) |buf| std.heap.page_allocator.free(buf);
    const stdout = std.Io.File.stdout();
    var stdout_writer = stdout.writer(std.Io.Threaded.global_single_threaded.io(), &[_]u8{});
    stdout_writer.interface.writeAll("spec_runner build info\n") catch {};
    stdout_writer.interface.print("  version: {s}\n", .{version_string}) catch {};
    stdout_writer.interface.print("  zig: {s}\n", .{builtin.zig_version_string}) catch {};
    stdout_writer.interface.print("  target: {s}\n", .{target}) catch {};
    stdout_writer.interface.print("  optimize: {s}\n", .{@tagName(builtin.mode)}) catch {};
    stdout_writer.interface.print("  link_libc: {s}\n", .{if (builtin.link_libc) "true" else "false"}) catch {};
    stdout_writer.interface.print("  single_threaded: {s}\n", .{if (builtin.single_threaded) "true" else "false"}) catch {};
    if (exe_path) |path| {
        stdout_writer.interface.print("  exe: {s}\n", .{path}) catch {};
    } else {
        stdout_writer.interface.writeAll("  exe: <unknown>\n") catch {};
    }
    stdout_writer.interface.flush() catch {};
}

fn printSpecRunnerBuildInfoJson() void {
    var target_buf: [96]u8 = undefined;
    const target = formatTargetTriple(&target_buf);
    const exe_path = std.process.executablePathAlloc(std.Io.Threaded.global_single_threaded.io(), std.heap.page_allocator) catch null;
    defer if (exe_path) |buf| std.heap.page_allocator.free(buf);
    const payload = SpecRunnerBuildInfoJson{
        .name = "spec_runner",
        .version = version_string,
        .zig = builtin.zig_version_string,
        .target = target,
        .optimize = @tagName(builtin.mode),
        .link_libc = builtin.link_libc,
        .single_threaded = builtin.single_threaded,
        .exe_path = exe_path,
    };
    const stdout = std.Io.File.stdout();
    var stdout_writer = stdout.writer(std.Io.Threaded.global_single_threaded.io(), &[_]u8{});
    var jw = std.json.Stringify{
        .writer = &stdout_writer.interface,
        .options = .{ .whitespace = .indent_2 },
    };
    jw.write(payload) catch {};
    stdout_writer.interface.writeByte('\n') catch {};
    stdout_writer.interface.flush() catch {};
}

fn realPathAllocNoSentinel(dir: std.Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const result_z: [:0]u8 = try dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator);
    defer allocator.free(result_z);
    return try allocator.dupe(u8, result_z);
}

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

const TempDirCreated = struct {
    dir: std.Io.Dir,
    path_buf: [128]u8,
    path_len: usize,
};

fn createTempDir() !TempDirCreated {
    var buf: [128]u8 = undefined;
    const tpl = "/tmp/zsass-spec-XXXXXX";
    @memcpy(buf[0..tpl.len], tpl);
    buf[tpl.len] = 0;
    const result = mkdtemp(@ptrCast(&buf));
    if (result == null) return error.TempDirCreationFailed;
    const io_val = std.Io.Threaded.global_single_threaded.io();
    const span = std.mem.span(result.?);
    const dir = try std.Io.Dir.openDirAbsolute(io_val, span, .{});
    var out: TempDirCreated = .{ .dir = dir, .path_buf = undefined, .path_len = span.len };
    @memcpy(out.path_buf[0..span.len], span);
    return out;
}

const TmpDir = if (builtin.is_test) std.testing.TmpDir else struct {
    dir: std.Io.Dir,
    path_buf: [128]u8,
    path_len: usize,
    pub fn cleanup(self: *@This()) void {
        const io_val = std.Io.Threaded.global_single_threaded.io();
        self.dir.close(io_val);
        // Remove the tmp directory tree from disk; keeping it around in /tmp
        // floods the partition over many test runs.
        const path = self.path_buf[0..self.path_len];
        std.Io.Dir.cwd().deleteTree(io_val, path) catch {};
    }
};

fn makeTmpDir() !TmpDir {
    if (builtin.is_test) {
        return std.testing.tmpDir(.{});
    } else {
        const created = try createTempDir();
        return .{ .dir = created.dir, .path_buf = created.path_buf, .path_len = created.path_len };
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    // Increase stack size limit to handle deeply nested Sass evaluation.
    // The evaluator's recursive expression evaluation (evalExprRaw  ->
    // evalBuiltinFunction  ->  evalCallable chains) can require deep call stacks,
    // especially with forwarded keyword arguments and nested function calls.
    {
        const rl = try std.posix.getrlimit(.STACK);
        const RLIM_INFINITY = std.math.maxInt(@TypeOf(rl.cur));
        const target: @TypeOf(rl.cur) = 256 * 1024 * 1024;
        if (rl.cur != RLIM_INFINITY and rl.cur < target) {
            const new_cur = if (rl.max == RLIM_INFINITY) target else @min(target, rl.max);
            std.posix.setrlimit(.STACK, .{ .cur = new_cur, .max = rl.max }) catch {};
        }
    }

    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const leak_check = gpa.deinit();
        if (leak_check == .leak) {
            std.log.err("spec runner detected leaked allocations", .{});
        }
    }
    const allocator = gpa.allocator();

    var args_list: std.ArrayList([:0]const u8) = .empty;
    defer args_list.deinit(allocator);
    {
        var it: std.process.Args.Iterator = .init(init.args);
        while (it.next()) |arg| {
            args_list.append(allocator, arg) catch @panic("OOM");
        }
    }
    const args = args_list.items;

    // Default spec directory is tests/sass-spec/spec relative to project root
    var spec_dir: []const u8 = "tests/sass-spec/spec";
    var filter: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--spec-dir")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("--spec-dir requires an argument\n", .{});
                std.process.exit(1);
            }
            spec_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--filter")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("--filter requires an argument\n", .{});
                std.process.exit(1);
            }
            filter = args[i];
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            quiet_mode = true;
        } else if (std.mem.eql(u8, arg, "--error-summary")) {
            structured_errors = true;
        } else if (std.mem.eql(u8, arg, "--info")) {
            printSpecRunnerBuildInfo(.text);
            return;
        } else if (std.mem.startsWith(u8, arg, "--info=")) {
            const value = arg["--info=".len..];
            const fmt: TextJsonFormat = if (std.mem.eql(u8, value, "json"))
                .json
            else if (std.mem.eql(u8, value, "text"))
                .text
            else {
                std.debug.print("--info format must be 'text' or 'json'\n", .{});
                std.process.exit(1);
            };
            printSpecRunnerBuildInfo(fmt);
            return;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\Usage: spec_runner [options]
                \\
                \\Options:
                \\  --spec-dir <path>   Path to sass-spec/spec directory
                \\  --filter <pattern>  Only run tests matching pattern
                \\  -q, --quiet         Only show failures and progress summary
                \\  --error-summary     Aggregate compile-error tags and print summary.
                \\  --info[=text|json] Print build metadata and exit
                \\  -h, --help          Show this help
                \\
            , .{});
            return;
        } else {
            // Treat positional argument as filter
            filter = arg;
        }
    }

    // Resolve relative paths without requiring the target directory to exist.
    const abs_spec_dir = try resolveSpecDirPath(allocator, spec_dir);
    defer allocator.free(abs_spec_dir);

    std.debug.print("Running sass-spec tests from: {s}\n", .{abs_spec_dir});
    std.debug.print("Engine: zsass API (compileSourceToCss)\n", .{});
    if (filter) |f| {
        std.debug.print("Filter: {s}\n", .{f});
    }

    const summary = try runSpecTests(allocator, abs_spec_dir, filter);

    // Print machine-readable summary line for orchestrator parsing.
    // Total excludes skipped tests to match commit message convention.
    std.debug.print("RESULT: passed={d} failed={d} errors={d} total={d}\n", .{
        summary.passed, summary.failed, summary.errors, summary.total - summary.skipped,
    });

    if (summary.failed != 0 or summary.errors != 0) {
        std.process.exit(1);
    }
}

// ============================================================
// HRX Parser Tests
// ============================================================

test "parse simple HRX" {
    const content =
        \\<===> input.scss
        \\body { color: red; }
        \\
        \\<===> output.css
        \\body {
        \\  color: red;
        \\}
        \\
    ;
    var archive = try parseHrx(std.testing.allocator, content);
    defer archive.deinit();

    try std.testing.expectEqual(@as(usize, 2), archive.entries.items.len);

    const input = archive.getEntry("input.scss");
    try std.testing.expect(input != null);
    try std.testing.expectEqualStrings("body { color: red; }\n\n", input.?);

    const output = archive.getEntry("output.css");
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("body {\n  color: red;\n}\n", output.?);
}

test "parse HRX with nested directories" {
    const content =
        \\<===> sub/dir/input.scss
        \\a { b: c; }
        \\
        \\<===> sub/dir/output.css
        \\a {
        \\  b: c;
        \\}
        \\
    ;
    var archive = try parseHrx(std.testing.allocator, content);
    defer archive.deinit();

    try std.testing.expectEqual(@as(usize, 2), archive.entries.items.len);

    const input = archive.getEntry("sub/dir/input.scss");
    try std.testing.expect(input != null);

    const output = archive.getEntry("sub/dir/output.css");
    try std.testing.expect(output != null);
}

test "resolveSpecDirPath returns absolute path for missing relative directory" {
    const spec_dir = "tests/sass-spec/spec";
    const abs = try resolveSpecDirPath(std.testing.allocator, spec_dir);
    defer std.testing.allocator.free(abs);

    try std.testing.expect(std.fs.path.isAbsolute(abs));
    try std.testing.expect(std.mem.endsWith(u8, abs, spec_dir));
}

test "runSpecTests reports error when spec directory is missing" {
    const missing_spec_dir = "tests/sass-spec/spec/__missing__";
    const abs = try resolveSpecDirPath(std.testing.allocator, missing_spec_dir);
    defer std.testing.allocator.free(abs);

    const summary = try runSpecTests(std.testing.allocator, abs, null);
    try std.testing.expectEqual(@as(u32, 1), summary.errors);
    try std.testing.expectEqual(@as(u32, 0), summary.total);
}

test "parse HRX with separator lines" {
    const content =
        "<===> first/input.scss\na { b: c; }\n\n<===> first/output.css\na {\n  b: c;\n}\n\n<===>\n================================================================================\n<===> second/input.scss\nd { e: f; }\n\n<===> second/output.css\nd {\n  e: f;\n}\n";
    var archive = try parseHrx(std.testing.allocator, content);
    defer archive.deinit();

    try std.testing.expectEqual(@as(usize, 4), archive.entries.items.len);

    try std.testing.expect(archive.getEntry("first/input.scss") != null);
    try std.testing.expect(archive.getEntry("first/output.css") != null);
    try std.testing.expect(archive.getEntry("second/input.scss") != null);
    try std.testing.expect(archive.getEntry("second/output.css") != null);
}

test "parse HRX with error entries" {
    const content =
        "<===> error/test/input.scss\n[a b] {c: d}\n\n<===> error/test/error\nError: Expected \"]\".\n";
    var archive = try parseHrx(std.testing.allocator, content);
    defer archive.deinit();

    try std.testing.expectEqual(@as(usize, 2), archive.entries.items.len);

    const err_entry = archive.getEntry("error/test/error");
    try std.testing.expect(err_entry != null);
}

test "getEntry returns null for missing entry" {
    const content =
        \\<===> input.scss
        \\body { color: red; }
        \\
    ;
    var archive = try parseHrx(std.testing.allocator, content);
    defer archive.deinit();

    try std.testing.expect(archive.getEntry("nonexistent.file") == null);
}

test "getTestCases extracts scss test prefixes" {
    const content =
        "<===> first/input.scss\na { b: c; }\n\n<===> first/output.css\na {\n  b: c;\n}\n\n<===>\n================================================================================\n<===> second/input.scss\nd { e: f; }\n\n<===> second/output.css\nd {\n  e: f;\n}\n";
    var archive = try parseHrx(std.testing.allocator, content);
    defer archive.deinit();

    var cases = try archive.getTestCases(std.testing.allocator);
    defer cases.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), cases.items.len);
    try std.testing.expectEqualStrings("first/", cases.items[0]);
    try std.testing.expectEqualStrings("second/", cases.items[1]);
}

test "getTestCases with root level input" {
    const content =
        \\<===> input.scss
        \\body { color: red; }
        \\
        \\<===> output.css
        \\body {
        \\  color: red;
        \\}
        \\
    ;
    var archive = try parseHrx(std.testing.allocator, content);
    defer archive.deinit();

    var cases = try archive.getTestCases(std.testing.allocator);
    defer cases.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), cases.items.len);
    try std.testing.expectEqualStrings("", cases.items[0]);
}

test "getTestCases deduplicates duplicate prefixes" {
    const content =
        "<===> first/input.scss\na { b: c; }\n\n" ++
        "<===> first/output.css\na { b: c; }\n\n" ++
        "<===> first/input.scss\na { b: d; }\n\n";
    var archive = try parseHrx(std.testing.allocator, content);
    defer archive.deinit();

    var cases = try archive.getTestCases(std.testing.allocator);
    defer cases.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), cases.items.len);
    try std.testing.expectEqualStrings("first/", cases.items[0]);
}

test "getTestCases includes sass input prefixes" {
    const content =
        "<===> sass_case/input.sass\na\n  b: c\n\n" ++
        "<===> sass_case/output.css\na {\n  b: c;\n}\n";
    var archive = try parseHrx(std.testing.allocator, content);
    defer archive.deinit();

    var cases = try archive.getTestCases(std.testing.allocator);
    defer cases.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), cases.items.len);
    try std.testing.expectEqualStrings("sass_case/", cases.items[0]);
}

test "parse HRX boundary without trailing space" {
    const content =
        "<===>input.scss\nbody { color: red; }\n\n<===>output.css\nbody { color: red; }\n";
    var archive = try parseHrx(std.testing.allocator, content);
    defer archive.deinit();

    try std.testing.expect(archive.getEntry("input.scss") != null);
    try std.testing.expect(archive.getEntry("output.css") != null);
}

test "parse empty HRX" {
    var archive = try parseHrx(std.testing.allocator, "");
    defer archive.deinit();

    try std.testing.expectEqual(@as(usize, 0), archive.entries.items.len);
}

test "parse HRX boundary only" {
    const content = "<===>\n";
    var archive = try parseHrx(std.testing.allocator, content);
    defer archive.deinit();

    try std.testing.expectEqual(@as(usize, 0), archive.entries.items.len);
}

test "hasSupplementaryFiles detects extra files" {
    const content =
        "<===> input.scss\n@use \"other\";\na { b: other.$var; }\n\n<===> _other.scss\n$var: red;\n\n<===> output.css\na {\n  b: red;\n}\n";
    var archive = try parseHrx(std.testing.allocator, content);
    defer archive.deinit();

    // Root prefix "" should have supplementary file _other.scss
    try std.testing.expect(archive.hasSupplementaryFiles(""));
}

test "hasSupplementaryFiles returns false without extra files" {
    const content =
        "<===> input.scss\nbody { color: red; }\n\n<===> output.css\nbody {\n  color: red;\n}\n";
    var archive = try parseHrx(std.testing.allocator, content);
    defer archive.deinit();

    // Root prefix "" should have no supplementary files
    try std.testing.expect(!archive.hasSupplementaryFiles(""));
}

test "hasSupplementaryFiles ignores error and warning files" {
    const content =
        "<===> input.scss\nbody { color: red; }\n\n<===> output.css\nbody {\n  color: red;\n}\n\n<===> error\nsome error\n\n<===> warning\nsome warning\n";
    var archive = try parseHrx(std.testing.allocator, content);
    defer archive.deinit();

    // error and warning are not supplementary files
    try std.testing.expect(!archive.hasSupplementaryFiles(""));
}

test "hasSupplementaryFiles with prefixed test case" {
    const content =
        "<===> sub/input.scss\n@import 'vars';\n\n<===> sub/_vars.scss\n$x: 1;\n\n<===> sub/output.css\n\n";
    var archive = try parseHrx(std.testing.allocator, content);
    defer archive.deinit();

    try std.testing.expect(archive.hasSupplementaryFiles("sub/"));
}
