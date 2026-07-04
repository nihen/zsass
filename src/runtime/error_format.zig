//! User-facing error message formatting. Zig internal error tag  ->  converted to official Sass CLI compatible English text.
//!
//! CLI-FIX-E Step 1: Format the driver's error output with a dart-compatible `Error: {message}.` prefix.
//! source frame (`| | |`) and stack trace line (`{path} {line}:{col} root stylesheet`) are
//! Scheduled to be added after span pluming in Step 2.

const std = @import("std");
const zsass_io = @import("io.zig");

pub fn stderrPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    var err_file = std.Io.File.stderr();
    // Streaming (write(2)) honors the kernel stdio file position so
    // back-to-back diagnostic prints append. The default `writer(...)`
    // initializes positional with `pos = 0`, which silently rewinds when
    // stderr is redirected to a regular file.
    var w = err_file.writerStreaming(zsass_io.io, buf[0..]);
    w.interface.print(fmt, args) catch return;
    w.interface.flush() catch return;
}

threadlocal var cli_diag_ansi: bool = true;
threadlocal var cli_diag_unicode: bool = true;

/// Configure stderr diagnostics for the current compile (CLI `--color` / `--unicode`).
pub fn setCliDiagnostics(ansi: bool, unicode: bool) void {
    cli_diag_ansi = ansi;
    cli_diag_unicode = unicode;
}

pub fn ansiDiagnosticsEnabled() bool {
    return cli_diag_ansi;
}

pub fn unicodeDiagnosticsEnabled() bool {
    return cli_diag_unicode;
}

/// User-facing diagnostics (dart-compatible frames). Avoid std.debug.print (zlint no-print).
fn eprint(comptime fmt: []const u8, args: anytype) void {
    var buf: [16384]u8 = undefined;
    var err_file = std.Io.File.stderr();
    // See `stderrPrint` -- positional mode rewinds on regular files.
    var w = err_file.writerStreaming(zsass_io.io, buf[0..]);
    w.interface.print(fmt, args) catch return;
    w.interface.flush() catch return;
}

/// CLI-FIX-E Step 2c+ Phase 2: context-aware error message. with callsite (builtin / VM exec)
/// Thread-local rich messages such as `setContextMessage("1px and 1em have incompatible units.")`
/// Save it in buffer, and `errorToUserMessage` returns this with priority. If not set
/// Table fallback for `error tag  ->  static message`.
pub fn setContextMessage(msg: []const u8) void {
    const n = @min(msg.len, error_state.context_message_buf.len);
    @memcpy(error_state.context_message_buf[0..n], msg[0..n]);
    error_state.context_message_len = n;
}

pub fn clearContextMessage() void {
    error_state.context_message_len = 0;
}

pub fn currentContextMessage() ?[]const u8 {
    if (error_state.context_message_len == 0) return null;
    return error_state.context_message_buf[0..error_state.context_message_len];
}

pub fn missingArgumentMessage() []const u8 {
    return "Missing argument.";
}

pub fn formatTooManyArguments(buf: []u8, expected: usize, got: usize) ![]u8 {
    const arg_noun = if (expected == 1) "argument" else "arguments";
    return std.fmt.bufPrint(buf, "Only {d} {s} allowed, but {d} were passed.", .{ expected, arg_noun, got });
}

/// Zig error tag  ->  official Sass CLI compatible user-facing message.
/// tag that is not in table returns generic `An error occurred.`.
/// Include the period (`.`) at the end to match dart.
/// Callers who want to prioritize thread-local context messages (rich error messages)
/// Use `errorToUserMessageWithContext`.
fn errorToUserMessage(err: anyerror) []const u8 {
    return switch (err) {
        // resolver / scope
        error.UnknownVar => "Undefined variable.",
        error.UnknownMixin => "Undefined mixin.",
        error.UnknownFunctionInBuiltinNs,
        error.UnknownFunctionInUserNs,
        error.UnknownFunctionNsMissing,
        => "Undefined function.",
        error.AmbiguousImport => "It's not clear which file to import.",

        // user module loader
        error.UsermoduleNotFound,
        error.UsermoduleIoFailure,
        error.UsermoduleBasePathMissing,
        error.UsermodulePathEmpty,
        => "Can't find stylesheet to import.",
        error.UsermoduleCircular => "This file is already being loaded.",
        error.UsermoduleLexFailure,
        error.UsermoduleParseFailure,
        => "Failed to parse imported file.",
        error.UsermoduleRootMismatch => "Imported file root mismatch.",

        // syntax / parser
        error.SyntaxError,
        error.SassSyntaxError,
        error.HardSyntaxError,
        error.UnexpectedEof,
        => "Invalid CSS syntax.",

        // builtin
        error.BuiltinArity => "Wrong number of arguments.",
        error.BuiltinType => "Argument type mismatch.",
        error.BuiltinUnsupported => "This function is not supported.",

        // value / runtime
        error.NonStaticExpr => "This value is not statically resolvable.",
        error.InvalidParentSelector => "Invalid parent selector.",

        // VM execution
        error.StackOverflow,
        error.FrameOverflow,
        error.ProgramTooLarge,
        => "Internal: stack/frame overflow.",
        error.StackUnderflow,
        error.BadJump,
        error.InternalError,
        error.CrossAssignOverflow,
        => "Internal compiler error.",

        // generic compile / sass error
        error.CompileFailed,
        error.SassError,
        => "Compilation failed.",

        // deprecation
        error.FatalDeprecation => "Fatal deprecation.",

        // memory / io
        error.OutOfMemory => "Out of memory.",

        // entry / file IO failures (e.g. CLI input path missing, unreadable).
        // Module-loader IO errors have their own UsermoduleIoFailure tag above;
        // these are the raw std.fs errors that escape to the driver.
        error.FileNotFound,
        error.AccessDenied,
        error.PermissionDenied,
        error.IsDir,
        error.NotDir,
        error.BadPathName,
        error.NameTooLong,
        error.SymLinkLoop,
        error.SharingViolation,
        error.PipeBusy,
        error.NoDevice,
        error.DeviceBusy,
        error.FileBusy,
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.WouldBlock,
        error.InputOutput,
        => "Cannot open file.",

        else => "An error occurred.",
    };
}

/// Wrapper used for error output of driver. If thread-local context message is set
/// Return it, otherwise fallback to static table (errorToUserMessage).
/// Callers such as test are not contaminated by context message by using errorToUserMessage.
pub fn errorToUserMessageWithContext(err: anyerror) []const u8 {
    if (currentContextMessage()) |m| return m;
    return errorToUserMessage(err);
}

/// CLI-FIX-E Step 1: Gate the debug line for each phase/VM with `ZSASS_VERBOSE_ERRORS` env var.
/// official Sass CLI doesn't output any debug lines, so you can set it to default suppress. Cache once per-thread.
/// `threadlocal` here means each batch worker reads / writes its own slot, so
/// the previous process-global cache that could race when several workers
/// hit `verboseErrorsEnabled()` for the first time concurrently is gone.
threadlocal var verbose_errors_cached: ?bool = null;
pub fn verboseErrorsEnabled() bool {
    if (verbose_errors_cached) |v| return v;
    const enabled = std.c.getenv("ZSASS_VERBOSE_ERRORS") != null;
    verbose_errors_cached = enabled;
    return enabled;
}

/// CLI-FIX-E Step 2: Mechanism to record span of the most recent error occurrence using thread-local.
/// With VM step error etc., extract the record and driver's catch route and construct the source frame.
pub const ErrorContext = struct {
    span_start: u32 = 0,
    span_end: u32 = 0,
    file_id: u32 = 0,
    has_value: bool = false,
    /// Zig error tag of the most recent error (optionally set from upper layer). without using `|err|` with errdefer
    /// To handle error type as thread-local.
    last_err: ?anyerror = null,
};

pub fn recordErrorSpan(start: u32, end: u32, file_id: u32) void {
    error_state.last_error_ctx.span_start = start;
    error_state.last_error_ctx.span_end = end;
    error_state.last_error_ctx.file_id = file_id;
    error_state.last_error_ctx.has_value = true;
    // To enable the stack frame format trace, update + snapshot also confirms the span of the current frame.
    // No-op if the stack is empty so that callers that don't use the Stack route (such as test) are not affected.
    if (error_state.error_stack_len > 0) {
        var f = &error_state.error_stack[error_state.error_stack_len - 1];
        f.span_start = start;
        f.span_end = end;
        f.has_span = true;
        snapshotErrorStack();
    }
}

pub fn recordErrorTag(err: anyerror) void {
    error_state.last_error_ctx.last_err = err;
}

/// If span is already recorded, it will not be overwritten. In the `errdefer` route of resolver/compiler
/// Used to hold the span of the innermost error frame (upper frames respect recorded ones).
pub fn recordErrorSpanIfUnset(start: u32, end: u32, file_id: u32) void {
    if (error_state.last_error_ctx.has_value) return;
    recordErrorSpan(start, end, file_id);
}

pub fn clearErrorContext() void {
    error_state.last_error_ctx = .{};
    error_state.error_stack_len = 0;
    error_state.error_stack_overflow = 0;
    error_state.error_stack_snapshot_len = 0;
    error_state.context_message_len = 0;
}

/// CLI-FIX-E Step 2c+: dart compatible multi-level stack trace (`{inner} {l}:{c} @use\n {entry} {l}:{c} root stylesheet`)
/// per-frame state for drawing. push at the entrance of resolveSingleAst (common to entry/imported),
/// Pop on exit. During the @use/@forward statement that resolves the imported, the caller frame (= parent)
/// By updating span to @use statement span with `setCurrentSpan`, trace line `{entry} 1:1 @use` is
/// Can be drawn.
pub const ErrorStackFrame = struct {
    /// File path (absolute or entry_path passed from driver) to which this frame's source belongs.
    path: []const u8,
    /// Same source bytes (for frame drawing, line_starts is recalculated on the driver side).
    source: []const u8,
    /// Label at the end of stack trace line (`root stylesheet` / `@use` / `@forward` / `@import`).
    label: []const u8,
    /// The last recorded error position within this frame (updated with recordErrorSpan/setCurrentSpan).
    span_start: u32 = 0,
    span_end: u32 = 0,
    has_span: bool = false,
};

/// max 16 stages. The actual stack for dart is usually 4-8 layers, so 16 is enough. If over, keep inner-most
/// (silently drop new push).
pub const max_error_stack: usize = 16;

/// snapshot inline the **pre-extracted** information of error_stack at the time of calling recordErrorSpan
/// Fixed to buffer. The slice pointer in source/path has been resolved (= scratch arena deinit /
/// To dangling with owned source free), line_text / line_no / col_no / path/label
/// Dup and save everything to fixed-size buffer. Now it's safe until it reaches the driver catch path.
pub const ErrorTraceFrame = struct {
    /// Path string (absolute or passed by driver). Truncate (rare path) if the 256 bytes limit is exceeded.
    path_buf: [256]u8 = [_]u8{0} ** 256,
    path_len: usize = 0,
    /// stack trace end-of-line labels (`root stylesheet` / `@use`, etc.). 32 is enough.
    label_buf: [32]u8 = [_]u8{0} ** 32,
    label_len: usize = 0,
    /// 1-base line / 1-base column (value already +1 for drawing).
    line_no: u32 = 1,
    col_no: u32 = 1,
    /// caret end (= span_end line/col). If they are on the same line, draw caret to that column.
    end_line_no: u32 = 1,
    end_col_no: u32 = 1,
    /// text of frame line (bytes of the line pointed to by line_no). truncate at 512 limit.
    line_text_buf: [512]u8 = [_]u8{0} ** 512,
    line_text_len: usize = 0,
    /// Whether this frame had a span (= recordErrorSpan or @use updated).
    /// If false, trace line will be output with fallback of line=1 col=1.
    has_span: bool = false,
};

/// Single thread-local bundle for error context / resolver stack / snapshot (avoids torn reads across fields).
pub const ErrorState = struct {
    context_message_buf: [512]u8 = [_]u8{0} ** 512,
    context_message_len: usize = 0,
    last_error_ctx: ErrorContext = .{},
    error_stack: [max_error_stack]ErrorStackFrame = [_]ErrorStackFrame{.{ .path = "", .source = "", .label = "" }} ** max_error_stack,
    error_stack_len: usize = 0,
    /// Frames dropped by `pushFrame` because the stack was full. `popFrame`
    /// consumes this before touching `error_stack_len` so callers'
    /// unconditional `defer popFrame()` stays balanced past max depth.
    error_stack_overflow: usize = 0,
    error_stack_snapshot: [max_error_stack]ErrorTraceFrame = [_]ErrorTraceFrame{.{}} ** max_error_stack,
    error_stack_snapshot_len: usize = 0,
};

pub threadlocal var error_state: ErrorState = std.mem.zeroes(ErrorState);

pub fn pushFrame(path: []const u8, source: []const u8, label: []const u8) void {
    if (error_state.error_stack_len >= max_error_stack) {
        // Keep push/pop balanced for callers' `defer popFrame()`: count the
        // dropped frame so the matching pop doesn't remove an unrelated one.
        error_state.error_stack_overflow += 1;
        return;
    }
    error_state.error_stack[error_state.error_stack_len] = .{ .path = path, .source = source, .label = label };
    error_state.error_stack_len += 1;
}

pub fn popFrame() void {
    if (error_state.error_stack_overflow > 0) {
        error_state.error_stack_overflow -= 1;
        return;
    }
    if (error_state.error_stack_len > 0) error_state.error_stack_len -= 1;
}

/// Record the caller-side span that triggered a child load on the current
/// top frame before pushing the child frame. Pass the span dart-sass points
/// its parent trace line at -- for `@import` that is the URL token span
/// (quote start), not the statement head. The trace line for the parent then
/// reads `{parent} {l}:{c} {label}` instead of the 1:1 fallback. No-op when
/// the stack is empty.
pub fn setTopFrameSpan(start: u32, end: u32) void {
    if (error_state.error_stack_len == 0) return;
    var f = &error_state.error_stack[error_state.error_stack_len - 1];
    f.span_start = start;
    f.span_end = end;
    f.has_span = true;
}

/// Copy the current error_stack to snapshot. Automatically called with recordErrorSpan. caller is
/// Not expected to be called directly (published for testing purposes). Since slice pointer of path/source is short-lived,
/// Dup path/label/line_text into fixed-size buffer for each frame.
fn snapshotErrorStack() void {
    var i: usize = 0;
    while (i < error_state.error_stack_len) : (i += 1) {
        const src = error_state.error_stack[i];
        var dst = ErrorTraceFrame{};

        // path dup (truncate if > 256)
        const plen = @min(src.path.len, dst.path_buf.len);
        @memcpy(dst.path_buf[0..plen], src.path[0..plen]);
        dst.path_len = plen;

        // label dup
        const llen = @min(src.label.len, dst.label_buf.len);
        @memcpy(dst.label_buf[0..llen], src.label[0..llen]);
        dst.label_len = llen;

        if (src.has_span and src.source.len > 0) {
            const start_pos = offsetToLineColFromSource(src.source, src.span_start);
            const end_pos = offsetToLineColFromSource(src.source, src.span_end);
            dst.line_no = start_pos.line + 1;
            dst.col_no = start_pos.col + 1;
            dst.end_line_no = end_pos.line + 1;
            dst.end_col_no = end_pos.col + 1;
            dst.has_span = true;

            // Extract the corresponding line  ->  dup to line_text_buf (truncate if > 512)
            const line_text = extractLineFromSource(src.source, start_pos.line);
            const tlen = @min(line_text.len, dst.line_text_buf.len);
            @memcpy(dst.line_text_buf[0..tlen], line_text[0..tlen]);
            dst.line_text_len = tlen;
        } else {
            dst.has_span = false;
        }

        error_state.error_stack_snapshot[i] = dst;
    }
    error_state.error_stack_snapshot_len = error_state.error_stack_len;
}

/// Helper to extract the corresponding line (excluding newline) from source bytes using line index (0-base).
fn extractLineFromSource(source: []const u8, line: u32) []const u8 {
    var current_line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (current_line == line) break;
        if (source[i] == '\n') {
            current_line += 1;
            line_start = i + 1;
        }
    }
    if (current_line < line) return "";
    var line_end: usize = line_start;
    while (line_end < source.len and source[line_end] != '\n') : (line_end += 1) {}
    if (line_end > line_start and source[line_end - 1] == '\r') line_end -= 1;
    return source[line_start..line_end];
}

/// Return last_error_ctx.last_err (fallback if not set).
pub fn lastErrorOr(fallback: anyerror) anyerror {
    return error_state.last_error_ctx.last_err orelse fallback;
}

/// Write official Sass CLI compatible source frame to stderr.
/// Example output:
/// |
/// 1 | .foo { color: 1px + 1em; }
/// | ^^^^^^^^^^
/// |
///   path/to/file.scss 1:15  root stylesheet
///
/// If span spans multiple lines, indicate only the first line with a caret indicator (dart compatible, truncate).
pub fn writeSourceFrame(
    source: []const u8,
    line_starts: []const u32,
    span_start: u32,
    span_end: u32,
    path: []const u8,
) void {
    writeSourceFrameWithLabel(source, line_starts, span_start, span_end, path, "root stylesheet");
}

/// Single frame drawing + optional label (`root stylesheet` / `@use` / function name etc).
fn writeSourceFrameWithLabel(
    source: []const u8,
    line_starts: []const u32,
    span_start: u32,
    span_end: u32,
    path: []const u8,
    label: []const u8,
) void {
    const start_pos = offsetToLineCol(line_starts, source.len, span_start);
    const end_pos = offsetToLineCol(line_starts, source.len, span_end);
    const line_text = extractLine(source, line_starts, start_pos.line);
    const lineno_text = formatLinenoText(start_pos.line + 1);

    // Top of source-frame bar.
    if (unicodeDiagnosticsEnabled()) {
        eprint("  \u{2577}\n", .{});
    } else {
        eprint("  >\n", .{});
    }
    // caret indicator
    const lineno_pad = " " ** 8;
    const pad_count = lineno_text.len;
    const indicator_pad_str = lineno_pad[0..pad_count];
    if (unicodeDiagnosticsEnabled()) {
        eprint("{s} \u{2502} ", .{indicator_pad_str});
    } else {
        eprint("{s} | ", .{indicator_pad_str});
    }
    var col: usize = 0;
    while (col < start_pos.col) : (col += 1) eprint(" ", .{});

    // End-start number of bytes if span is within the same line (UTF-8 byte count ~ col in BMP range, assuming ASCII).
    // If multi-byte characters are included, dart is also column-based, so approximation is OK.
    const caret_len: usize = if (start_pos.line == end_pos.line)
        @max(end_pos.col -| start_pos.col, 1)
    else
        @max(line_text.len -| start_pos.col, 1);
    var ci: usize = 0;
    while (ci < caret_len) : (ci += 1) eprint("^", .{});
    eprint("\n", .{});

    // Bottom of source-frame bar.
    if (unicodeDiagnosticsEnabled()) {
        eprint("  \u{2575}\n", .{});
    } else {
        eprint("  <\n", .{});
    }
    eprint("  {s} {d}:{d}  {s}\n", .{
        path,
        start_pos.line + 1,
        start_pos.col + 1,
        label,
    });
}

/// Draw a multi-level stack trace from error_stack_snapshot. If snapshot is empty, do nothing,
/// The caller (driver) issues a one-stage trace (entry only) via a separate route.
///
/// Output layout:
/// |
/// 1 | ...
/// | ^^^...
/// |
///   {inner} l:c  {label_inner}
///   {next}  l:c  {label_next}
///   ...
///   {outer} l:c  root stylesheet
///
/// Align the width of path+pos across the entire stack and column-align the label column (dart compatible).
/// The inner-most (path,source,span,label) traces the top of the stack, and the outer traces the stack toward the bottom.
pub fn writeStackTrace(allocator: std.mem.Allocator) !void {
    if (error_state.error_stack_snapshot_len == 0) return;
    const slen = error_state.error_stack_snapshot_len;

    // Precompute the path+position string for all frames and calculate the max width.
    var pieces: [max_error_stack][]u8 = undefined;
    var owned: [max_error_stack]bool = .{false} ** max_error_stack;
    defer {
        var k: usize = 0;
        while (k < slen) : (k += 1) {
            if (owned[k]) allocator.free(pieces[k]);
        }
    }

    // snapshot[slen-1] is inner-most (= error occurrence position). Drawing is done in inner -> outer order.
    var max_width: usize = 0;
    var i: usize = 0;
    while (i < slen) : (i += 1) {
        const idx = slen - 1 - i;
        const f = error_state.error_stack_snapshot[idx];
        const path = f.path_buf[0..f.path_len];
        const text = try std.fmt.allocPrint(allocator, "{s} {d}:{d}", .{
            path,
            f.line_no,
            f.col_no,
        });
        pieces[idx] = text;
        owned[idx] = true;
        if (text.len > max_width) max_width = text.len;
    }

    // Draw the source frame (frame ASCII) of the inner-most frame.
    {
        const inner = error_state.error_stack_snapshot[slen - 1];
        if (inner.has_span) {
            const line_text = inner.line_text_buf[0..inner.line_text_len];
            writeSourceFrameAsciiOnlyFromSnapshot(line_text, inner.line_no, inner.col_no, inner.end_line_no, inner.end_col_no);
        }
    }

    // Print trace lines for each frame. inner -> outer order.
    var j: usize = 0;
    while (j < slen) : (j += 1) {
        const idx = slen - 1 - j;
        const f = error_state.error_stack_snapshot[idx];
        const label = f.label_buf[0..f.label_len];
        const pad = max_width - pieces[idx].len + 2;
        eprint("  {s}", .{pieces[idx]});
        var p: usize = 0;
        while (p < pad) : (p += 1) eprint(" ", .{});
        eprint("{s}\n", .{label});
    }
}

fn writeSourceFrameAsciiOnlyFromSnapshot(
    line_text: []const u8,
    line_no: u32,
    col_no: u32,
    end_line_no: u32,
    end_col_no: u32,
) void {
    const lineno_text = formatLinenoText(line_no);

    if (unicodeDiagnosticsEnabled()) {
        eprint("  \u{2577}\n", .{});
        eprint("{s} \u{2502} {s}\n", .{ lineno_text, line_text });
    } else {
        eprint("  >\n", .{});
        eprint("{s} | {s}\n", .{ lineno_text, line_text });
    }

    const lineno_pad = " " ** 8;
    const pad_count = lineno_text.len;
    const indicator_pad_str = lineno_pad[0..pad_count];
    if (unicodeDiagnosticsEnabled()) {
        eprint("{s} \u{2502} ", .{indicator_pad_str});
    } else {
        eprint("{s} | ", .{indicator_pad_str});
    }
    var col: u32 = 1;
    while (col < col_no) : (col += 1) eprint(" ", .{});

    const caret_len: u32 = if (line_no == end_line_no)
        @max(end_col_no -| col_no, 1)
    else
        @max(@as(u32, @intCast(line_text.len)) -| (col_no - 1), 1);
    var ci: u32 = 0;
    while (ci < caret_len) : (ci += 1) eprint("^", .{});
    eprint("\n", .{});

    if (unicodeDiagnosticsEnabled()) {
        eprint("  \u{2575}\n", .{});
    } else {
        eprint("  <\n", .{});
    }
}

/// Render the current diagnostic (message + inner-most source frame + stack
/// trace from `error_stack_snapshot`) into an `allocator`-owned string.
/// Embedding-API counterpart of the stderr renderers above (writeSourceFrame /
/// writeStackTrace): batch compiles (`embed_batch.zig`) attach this to the
/// per-file result so watchers can show dart-style diagnostics instead of a
/// bare error tag. Returns null when allocation fails.
pub fn formatDiagnosticAlloc(allocator: std.mem.Allocator, err: anyerror) ?[]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    formatDiagnosticToWriter(&aw.writer, err) catch return null;
    return aw.toOwnedSlice() catch null;
}

fn writeSpaces(w: *std.Io.Writer, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try w.writeAll(" ");
}

fn formatDiagnosticToWriter(w: *std.Io.Writer, err: anyerror) !void {
    try w.print("Error: {s}\n", .{errorToUserMessageWithContext(err)});
    const slen = error_state.error_stack_snapshot_len;
    if (slen == 0) return;

    // Inner-most source frame (same layout as writeSourceFrameAsciiOnlyFromSnapshot,
    // honoring the unicode/ASCII diagnostics toggle).
    const unicode = unicodeDiagnosticsEnabled();
    const bar_top: []const u8 = if (unicode) "  \u{2577}\n" else "  >\n";
    const bar_mid: []const u8 = if (unicode) " \u{2502} " else " | ";
    const bar_bottom: []const u8 = if (unicode) "  \u{2575}\n" else "  <\n";
    const inner = &error_state.error_stack_snapshot[slen - 1];
    if (inner.has_span and inner.line_text_len > 0) {
        const line_text = inner.line_text_buf[0..inner.line_text_len];
        var lineno_text_buf: [12]u8 = undefined;
        const lineno_text = std.fmt.bufPrint(&lineno_text_buf, "{d}", .{inner.line_no}) catch "?";
        try w.writeAll(bar_top);
        try w.print("{s}{s}{s}\n", .{ lineno_text, bar_mid, line_text });
        try writeSpaces(w, lineno_text.len);
        try w.writeAll(bar_mid);
        try writeSpaces(w, inner.col_no -| 1);
        const caret_len: u32 = if (inner.line_no == inner.end_line_no)
            @max(inner.end_col_no -| inner.col_no, 1)
        else
            @max(@as(u32, @intCast(line_text.len)) -| (inner.col_no - 1), 1);
        var ci: u32 = 0;
        while (ci < caret_len) : (ci += 1) try w.writeAll("^");
        try w.writeAll("\n");
        try w.writeAll(bar_bottom);
    }

    // Trace lines, inner -> outer, with the label column aligned (dart compatible).
    var piece_bufs: [max_error_stack][300]u8 = undefined;
    var pieces: [max_error_stack][]const u8 = undefined;
    var max_width: usize = 0;
    var i: usize = 0;
    while (i < slen) : (i += 1) {
        const f = &error_state.error_stack_snapshot[i];
        pieces[i] = std.fmt.bufPrint(&piece_bufs[i], "{s} {d}:{d}", .{
            f.path_buf[0..f.path_len],
            f.line_no,
            f.col_no,
        }) catch "?";
        if (pieces[i].len > max_width) max_width = pieces[i].len;
    }
    var j: usize = 0;
    while (j < slen) : (j += 1) {
        const idx = slen - 1 - j;
        const f = &error_state.error_stack_snapshot[idx];
        try w.print("  {s}", .{pieces[idx]});
        try writeSpaces(w, max_width - pieces[idx].len + 2);
        try w.print("{s}\n", .{f.label_buf[0..f.label_len]});
    }
}

/// Simple helper to calculate LineCol directly from source bytes (no need for line_starts, for stack trace).
fn offsetToLineColFromSource(source: []const u8, offset: u32) LineCol {
    var line: u32 = 0;
    var col_base: u32 = 0;
    var i: u32 = 0;
    const limit = if (offset > source.len) @as(u32, @intCast(source.len)) else offset;
    while (i < limit) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            col_base = i + 1;
        }
    }
    return .{ .line = line, .col = limit - col_base };
}

const LineCol = struct { line: u32, col: u32 };

fn offsetToLineCol(line_starts: []const u32, source_len: usize, offset: u32) LineCol {
    if (line_starts.len == 0) return .{ .line = 0, .col = offset };
    var lo: usize = 0;
    var hi: usize = line_starts.len;
    while (lo + 1 < hi) {
        const mid = lo + (hi - lo) / 2;
        if (line_starts[mid] <= offset) lo = mid else hi = mid;
    }
    const line: u32 = @intCast(lo);
    const col_base = line_starts[lo];
    const safe_offset = if (offset > source_len) @as(u32, @intCast(source_len)) else offset;
    const col: u32 = if (safe_offset > col_base) safe_offset - col_base else 0;
    return .{ .line = line, .col = col };
}

fn extractLine(source: []const u8, line_starts: []const u32, line: u32) []const u8 {
    if (line_starts.len == 0) {
        const newline = std.mem.indexOfScalar(u8, source, '\n') orelse source.len;
        return source[0..newline];
    }
    const idx: usize = @intCast(line);
    if (idx >= line_starts.len) return "";
    const start: usize = line_starts[idx];
    const end: usize = if (idx + 1 < line_starts.len) line_starts[idx + 1] else source.len;
    var line_end = end;
    if (line_end > 0 and line_end <= source.len and line_end > start) {
        if (source[line_end - 1] == '\n') line_end -= 1;
        if (line_end > start and source[line_end - 1] == '\r') line_end -= 1;
    }
    if (start > source.len) return "";
    if (line_end > source.len) line_end = source.len;
    if (line_end < start) line_end = start;
    return source[start..line_end];
}

threadlocal var lineno_buf: [16]u8 = undefined;
fn formatLinenoText(lineno: u32) []const u8 {
    return std.fmt.bufPrint(&lineno_buf, "{d}", .{lineno}) catch "?";
}

/// CLI-FIX-E Step 3 (C-6): error CSS template to write to the output file when an error occurs in file output mode.
/// official Sass CLI compatible: CSS comment block (frame ASCII fallback `,/|/'`) + body::before content
// Embed frame in /// with Unicode escape (`\2577 ` `\2502 ` `\2575 ` `\a `).
///
/// If there is an error without input (such as an error before parse), only message and path are output without frame.
pub fn writeErrorCssTemplate(
    writer: *std.Io.Writer,
    err: anyerror,
    path: []const u8,
    source: ?[]const u8,
    line_starts: ?[]const u32,
    span_start: u32,
    span_end: u32,
    has_frame: bool,
) !void {
    const msg = errorToUserMessage(err);

    // CSS comment block: ASCII frame fallback.
    try writer.print("/* Error: {s}\n", .{msg});
    if (has_frame and source != null and line_starts != null) {
        const src = source.?;
        const ls = line_starts.?;
        const start_pos = offsetToLineCol(ls, src.len, span_start);
        const end_pos = offsetToLineCol(ls, src.len, span_end);
        const line_text = extractLine(src, ls, start_pos.line);
        const lineno = start_pos.line + 1;
        try writer.writeAll(" *   ,\n");
        try writer.print(" * {d} | {s}\n", .{ lineno, line_text });
        try writer.writeAll(" *   | ");
        var col: usize = 0;
        while (col < start_pos.col) : (col += 1) try writer.writeByte(' ');
        const caret_len: usize = if (start_pos.line == end_pos.line)
            @max(end_pos.col -| start_pos.col, 1)
        else
            @max(line_text.len -| start_pos.col, 1);
        var ci: usize = 0;
        while (ci < caret_len) : (ci += 1) try writer.writeByte('^');
        try writer.writeByte('\n');
        try writer.writeAll(" *   '\n");
        try writer.print(" *   {s} {d}:{d}  root stylesheet */\n\n", .{ path, lineno, start_pos.col + 1 });
    } else {
        try writer.print(" *   {s} */\n\n", .{path});
    }

    try writer.writeAll(
        \\body::before {
        \\  font-family: "Source Code Pro", "SF Mono", Monaco, Inconsolata, "Fira Mono",
        \\      "Droid Sans Mono", monospace, monospace;
        \\  white-space: pre;
        \\  display: block;
        \\  padding: 1em;
        \\  margin-bottom: 1em;
        \\  border-bottom: 2px solid black;
        \\  content: "
    );
    // CSS string content. Unicode escape for frame characters (such as `\2577 `) and newline as `\a `.
    try writeEscapedErrorContent(writer, err, path, source, line_starts, span_start, span_end, has_frame);
    try writer.writeAll("\";\n}\n");
}

fn writeEscapedErrorContent(
    writer: *std.Io.Writer,
    err: anyerror,
    path: []const u8,
    source: ?[]const u8,
    line_starts: ?[]const u32,
    span_start: u32,
    span_end: u32,
    has_frame: bool,
) !void {
    const msg = errorToUserMessage(err);
    try writer.print("Error: {s}", .{msg});
    if (has_frame and source != null and line_starts != null) {
        const src = source.?;
        const ls = line_starts.?;
        const start_pos = offsetToLineCol(ls, src.len, span_start);
        const end_pos = offsetToLineCol(ls, src.len, span_end);
        const line_text = extractLine(src, ls, start_pos.line);
        const lineno = start_pos.line + 1;
        try writer.writeAll("\\a   \\2577 ");
        try writer.print("\\a {d} \\2502  ", .{lineno});
        try writeCssEscapedString(writer, line_text);
        try writer.writeAll("\\a   \\2502  ");
        var col: usize = 0;
        while (col < start_pos.col) : (col += 1) try writer.writeByte(' ');
        const caret_len: usize = if (start_pos.line == end_pos.line)
            @max(end_pos.col -| start_pos.col, 1)
        else
            @max(line_text.len -| start_pos.col, 1);
        var ci: usize = 0;
        while (ci < caret_len) : (ci += 1) try writer.writeByte('^');
        try writer.writeAll("\\a   \\2575 ");
        try writer.print("\\a   {s} {d}:{d}  root stylesheet", .{ path, lineno, start_pos.col + 1 });
    } else {
        try writer.print("\\a   {s}", .{path});
    }
}

fn writeCssEscapedString(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            else => try writer.writeByte(c),
        }
    }
}

test "errorToUserMessage covers main resolver errors" {
    try std.testing.expectEqualStrings("Undefined variable.", errorToUserMessage(error.UnknownVar));
    try std.testing.expectEqualStrings("Undefined mixin.", errorToUserMessage(error.UnknownMixin));
    try std.testing.expectEqualStrings("Undefined function.", errorToUserMessage(error.UnknownFunctionInBuiltinNs));
    try std.testing.expectEqualStrings("Invalid CSS syntax.", errorToUserMessage(error.SyntaxError));
    try std.testing.expectEqualStrings("Compilation failed.", errorToUserMessage(error.SassError));
}

test "errorToUserMessage falls back to generic" {
    try std.testing.expectEqualStrings("An error occurred.", errorToUserMessage(error.SkipZigTest));
}

test "errorToUserMessage maps file IO errors" {
    try std.testing.expectEqualStrings("Cannot open file.", errorToUserMessage(error.FileNotFound));
    try std.testing.expectEqualStrings("Cannot open file.", errorToUserMessage(error.AccessDenied));
    try std.testing.expectEqualStrings("Cannot open file.", errorToUserMessage(error.IsDir));
    try std.testing.expectEqualStrings("Cannot open file.", errorToUserMessage(error.BadPathName));
}
