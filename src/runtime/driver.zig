//! zsass driver -- bytecode VM entry point (formerly `zsass-bc-poc`).
//!
//! Usage:
//!   zsass <input.scss> <output.css>
//!   zsass --compile-only <input.scss>
//!   zsass --exec <input.bc> <output.css>

const std = @import("std");
const builtin = @import("builtin");
const zsass_options = @import("zsass_options");
const value_mod = @import("value.zig");
const opcode_mod = @import("../ir/opcode.zig");
const observe_mod = @import("observe.zig");
const perf = @import("perf.zig");
const compiler_mod = @import("../ir/compiler.zig");
const rule_ir_mod = @import("../ir/rule_ir.zig");
const vm_mod = @import("vm.zig");
const api_mod = @import("../api.zig");
const deprecation_mod = @import("deprecation.zig");
const error_format = @import("error_format.zig");
const intern_pool_mod = @import("../runtime/intern_pool.zig");
const source_cache_mod = @import("../resolve/source_cache.zig");
const ast_cache_mod = @import("../resolve/ast_cache.zig");
const persistent_resolver_mod = @import("../resolve/persistent_resolver.zig");
const source_map_mod = @import("../ir/source_map.zig");
const syntax_override_mod = @import("syntax_override.zig");

const zsass_io_mod = @import("io.zig");

comptime {
    _ = observe_mod.PhaseTimer;
    _ = observe_mod.disassemble;
    _ = vm_mod.VM;
}

const USAGE =
    \\Usage: zsass [options] <input.scss> [output.css]
    \\       zsass [options] <input.scss>:<output.css> [more-pairs...]
    \\       zsass [options] --stdin [-o output.css]
    \\
    \\Options:
    \\  --style, -s <expanded|compressed>  Output style (default: expanded)
    \\  -I, --load-path <path>      Add load path (repeatable)
    \\  -C, --chdir <dir>           Change working directory before resolving paths
    \\  -o, --output <path>         Write CSS to file
    \\  --stdin                     Read from stdin
    \\  --stdin-filepath <path>     Virtual path for stdin source
    \\  --[no-]stdin                Read from stdin / require file input
    \\  -v, -V, --version[=text|json] Print version
    \\  --info[=text|json]          Print build information
    \\  --completions <bash|zsh|fish> Print shell completion script
    \\  -h, --help                  Print this help
    \\
    \\  -q, --[no-]quiet            Suppress @warn and @debug output
    \\  --[no-]verbose              Show all warnings including duplicates
    \\  --[no-]quiet-deps           Suppress warnings from dependencies
    \\  --silence-deprecation=<id>[,<id>...]
    \\                              Suppress specific deprecation warnings. Repeatable.
    \\  --future-deprecation=<id>[,<id>...]
    \\                              Opt in to future deprecation warnings. Repeatable.
    \\  --fatal-deprecation=<id|version>[,...]
    \\                              Treat specific deprecations as errors. Repeatable.
    \\
    \\  --source-map                Generate source maps (default: on for file, off for stdout)
    \\  --source-map=<inline|file|off> Explicit map mode
    \\  --source-map-file <path>    Override source map output path
    \\  --source-map-url <path|url> Override sourceMappingURL comment in trailing CSS comment
    \\  --source-map-urls <relative|absolute> Source paths in `.map` JSON (default: relative)
    \\  --[no-]embed-source-map     Embed source map contents in CSS
    \\  --[no-]embed-sources        Include sourcesContent in source map
    \\  --no-source-map             Disable source map generation
    \\
    \\  --charset                   Enable @charset "UTF-8" emission (default)
    \\  --no-charset                Disable @charset "UTF-8" emission
    \\  --plain-css                 Treat input as CSS
    \\  --scss                      Re-enable SCSS evaluation (default)
    \\  --indented                  Force indented (.sass) syntax
    \\  --no-indented               Force SCSS syntax
    \\  -c, --[no-]color            Force / disable ANSI color in diagnostics
    \\  --[no-]unicode              Use / disable Unicode glyphs in diagnostics
    \\  --[no-]trace                Print full call stack on @error
    \\  --error-css                 Emit error as CSS on failure (default for file output)
    \\  --no-error-css              Disable error CSS (default for stdout)
    \\
    \\  --watch, -w                 Recompile on changes (polling; use --poll with --watch)
    \\  --[no-]poll                 Polling vs native watcher (--no-poll unsupported; requires --watch)
    \\  --update                    Recompile only when output is not older than input
    \\  --stop-on-error / --no-stop-on-error (batch behavior)
    \\  -i, --interactive           Run interactive SassScript REPL (stdin lines)
    \\
    \\  --check / --dry-run         Compile without writing files
    \\  --compile-only <input>      Parse/resolve/compile only
    \\  --list-load-paths           Print resolved load paths
    \\  --env-report                Emit env report as JSON
    \\
    \\Dev/observation:
    \\  --phase-timer               Print per-phase timing
    \\  --dump-bc                   Disassemble bytecode
    \\  --opcode-histogram          Print opcode frequency
    \\  --trace-diff <reference>    Diff output against reference CSS
    \\
    \\Use \"--\" before filenames to stop parsing options when paths begin with \"-\".
    \\
    \\Environment:
    \\  SASS_PATH                   Platform path-delimited load paths
    \\  ZSASS_TRACE_SLOT            Enable per-slot VM tracing
    \\  ZSASS_CSS_CACHE             Set to \"0\" or \"false\" to disable CSS cache
    \\  ZSASS_CSS_CACHE_DIR         Override CSS cache directory
    \\
;

const SourceMapMode = enum { off, file, @"inline", auto };

fn cliErrPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    var err_file = std.Io.File.stderr();
    var w = err_file.writer(zsass_io_mod.io, buf[0..]);
    w.interface.print(fmt, args) catch return;
    w.interface.flush() catch return;
}

fn parseSourceMapUrlsMode(val: []const u8) source_map_mod.SourceMapUrlsMode {
    if (std.mem.eql(u8, val, "relative")) return .relative;
    if (std.mem.eql(u8, val, "absolute")) return .absolute;
    cliErrPrint("error: --source-map-urls must be 'relative' or 'absolute' (got '{s}')\n", .{val});
    std.process.exit(EX_USAGE);
}

fn requireNonEmptyUrlArg(flag_for_msg: []const u8, val: []const u8) void {
    if (val.len == 0) {
        cliErrPrint("error: {s} requires a non-empty path or URL\n", .{flag_for_msg});
        std.process.exit(EX_USAGE);
    }
    // The value is interpolated verbatim into the trailing
    // `/*# sourceMappingURL=... */` comment we emit alongside CSS. Reject
    // bytes that would let a caller close the comment, smuggle CSS, or
    // smuggle terminal control sequences. This is a defence-in-depth
    // measure against build pipelines that forward unsanitised values
    // (env vars, query strings, CI substitutions) into `--source-map-url`.
    if (std.mem.indexOf(u8, val, "*/") != null) {
        cliErrPrint("error: {s} value must not contain `*/` (would close the sourceMappingURL CSS comment)\n", .{flag_for_msg});
        std.process.exit(EX_USAGE);
    }
    for (val) |c| {
        if (c == 0 or c == '\n' or c == '\r' or c < 0x20) {
            cliErrPrint("error: {s} value must not contain NUL or control characters\n", .{flag_for_msg});
            std.process.exit(EX_USAGE);
        }
    }
}
const CompletionShell = enum { bash, zsh, fish };
const BuildInfoFormat = enum { text, json };
const VersionFormatCli = enum { text, json };

const version_string = zsass_options.version;

fn parseVersionCliArg(arg: []const u8) ?VersionFormatCli {
    if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) return .text;
    if (std.mem.eql(u8, arg, "--version=text")) return .text;
    if (std.mem.eql(u8, arg, "--version=json")) return .json;
    if (std.mem.startsWith(u8, arg, "--version=")) {
        const rest = arg["--version=".len..];
        if (std.mem.eql(u8, rest, "text")) return .text;
        if (std.mem.eql(u8, rest, "json")) return .json;
        return null;
    }
    return null;
}

const EX_USAGE: u8 = 64;
const EX_DATAERR: u8 = 65;
const EX_NOINPUT: u8 = 66;
const EX_SOFTWARE: u8 = 70;

fn exitCodeForError(err: anyerror) u8 {
    return switch (err) {
        error.FileNotFound, error.AccessDenied, error.IsDir, error.NotDir => EX_NOINPUT,
        // Source-map --embed-sources read failure: report as input error
        // (matches FileNotFound / AccessDenied semantics).
        error.SourceMapEmbedReadFailed => EX_NOINPUT,
        // CLI usage misuse surfaced from runEnd2EndWithPool (was previously
        // a direct std.process.exit(EX_USAGE)).
        error.TraceDiffStdoutMisuse => EX_USAGE,
        // CLI-FIX-E: All user-fixable Sass errors are EX_DATAERR=65 (dart-sass compatible).
        // Internal compiler error / OOM only branch to EX_SOFTWARE=70.
        error.OutOfMemory,
        error.InternalError,
        error.BadJump,
        error.StackUnderflow,
        error.CrossAssignOverflow,
        error.InvalidGeneratedLine,
        error.InvalidGeneratedColumn,
        error.InvalidMatchedSlice,
        error.InvalidSourceLocation,
        error.InvalidVlq,
        => EX_SOFTWARE,
        else => EX_DATAERR,
    };
}

/// CLI-FIX-E Step 1+2/2c: Format error with dart-sass compatible `Error: {message}` prefix + source frame.
/// If span is included in thread-local error context (record in vm.step / resolver errdefer),
/// Reload the source of the module and frame (`| | |` + caret + `{path} {line}:{col} root stylesheet`)
// Output ///. file_id == 0 is input_path of entry, != 0 needs to be obtained via ResolvedBundle.
/// Because program may have already been deinited in the upper catch path (via printUserFacingError)
/// Only entry is supported. Errors in imported module are handled by VM exec catch path (via resolveFrameInfo).
fn printUserFacingError(err: anyerror, input_path: []const u8) void {
    if (error_format.verboseErrorsEnabled()) {
        cliErrPrint("zsass: driver error: {}\n", .{err});
    }
    const msg = error_format.errorToUserMessageWithContext(err);
    if (error_format.ansiDiagnosticsEnabled()) {
        cliErrPrint("\x1b[31mError:\x1b[0m {s}\n", .{msg});
    } else {
        cliErrPrint("Error: {s}\n", .{msg});
    }

    // CLI-FIX-E Step 2c+: If there is a snapshot stack, draw a multi-stage trace (resolver-time error route).
    // The snapshot is finalized at the time recordErrorSpan is called and is retained until the driver catch path is reached.
    if (error_format.error_state.error_stack_snapshot_len > 0) {
        const allocator = std.heap.c_allocator;
        error_format.writeStackTrace(allocator) catch {
            cliErrPrint("  {s}\n", .{input_path});
        };
        return;
    }

    const ctx = error_format.error_state.last_error_ctx;
    if (ctx.has_value and ctx.file_id == 0 and !std.mem.eql(u8, input_path, "<stdin>")) {
        // error in entry module: frame is constructed by reloading file. line_starts is recalculated.
        const allocator = std.heap.c_allocator;
        const source = readFileToStringAlloc(allocator, input_path) catch {
            cliErrPrint("  {s}\n", .{input_path});
            return;
        };
        defer allocator.free(source);
        const line_starts = computeLineStarts(allocator, source) catch {
            cliErrPrint("  {s}\n", .{input_path});
            return;
        };
        defer allocator.free(line_starts);
        error_format.writeSourceFrame(source, line_starts, ctx.span_start, ctx.span_end, input_path);
    } else {
        cliErrPrint("  {s}\n", .{input_path});
    }
}

/// CLI-FIX-E Step 2c: Look at file_id in error context and resolve source/line_starts/path for drawing frame.
/// file_id == 0: Use entry's source/path as is, line_starts is calculated from entry or via modules[0].
/// file_id != 0: Reload source from program.modules[file_id].module_path, get line_starts from the same module.
const FrameInfo = struct {
    has_frame: bool,
    source: ?[]const u8 = null,
    line_starts: ?[]const u32 = null,
    path: []const u8,
    source_owned: ?[]const u8 = null,
};

fn resolveFrameInfoEx(
    allocator: std.mem.Allocator,
    program_ptr: *compiler_mod.Program,
    ctx: error_format.ErrorContext,
    entry_source: []const u8,
    entry_path: []const u8,
    is_entry: bool,
) FrameInfo {
    if (!ctx.has_value) return .{ .has_frame = false, .path = entry_path };

    const modules = program_ptr.modules;
    const file_idx: usize = @intCast(ctx.file_id);
    if (is_entry) {
        const root_mod = program_ptr.rootMod();
        if (root_mod.line_starts.len > 0 and entry_source.len > 0) {
            return .{
                .has_frame = true,
                .source = entry_source,
                .line_starts = root_mod.line_starts,
                .path = entry_path,
            };
        }
        return .{ .has_frame = false, .path = entry_path };
    }
    if (file_idx >= modules.len) return .{ .has_frame = false, .path = entry_path };
    const m = modules[file_idx];
    if (m.module_path.len == 0) return .{ .has_frame = false, .path = entry_path };
    const src = readFileToStringAlloc(allocator, m.module_path) catch return .{ .has_frame = false, .path = m.module_path };
    if (m.line_starts.len == 0) {
        allocator.free(src);
        return .{ .has_frame = false, .path = m.module_path };
    }
    return .{
        .has_frame = true,
        .source = src,
        .line_starts = m.line_starts,
        .path = m.module_path,
        .source_owned = src,
    };
}

/// CLI-FIX-E Step 2c+ Phase 2: Programmatically build error_stack_snapshot for VM error.
/// snapshot[0] = entry frame (label=root stylesheet, fallback span 1:1),
/// snapshot[1] = inner frame (= imported source, label="@function" etc., ctx span).
/// Since the error via VM does not go through the resolver-time stack push route, it is directly snapshotd on the driver side.
// Write ///. The dup of path/source is performed on the inline buffer of ErrorTraceFrame, so
/// Does not depend on caller's lifetime.
/// CLI-FIX-E Step 2c+ Phase 3: Build a two-stage snapshot reflecting VM info.
/// - inner frame: inner_path / inner_source / ctx span / label = `{chunk.name}()` (function/mixin)
/// - entry frame: entry_path / entry_source / callsite span taken from outermostCallerInfo of VM /
/// label = `root stylesheet` (for entry) or `@function`/`@include` (nested case, simplification)
///
/// 1st row inner is dart exact match, 2nd row outer is entry path + exact callsite span
/// Achieved dart compatibility. In nested call (entry  ->  A  ->  B  ->  error), `outermostCallerInfo` is
/// Since the caller info (= entry) of the outermost frame is returned, the middle A frame is not drawn.
/// (= fixed at 2 stages). Dart releases all intermediate frames, but stops at 2 stages in Phase 3.
fn buildVmErrorSnapshotV3(
    vm: *vm_mod.VM,
    program_ptr: *compiler_mod.Program,
    allocator: std.mem.Allocator,
    inner_source: []const u8,
    inner_path: []const u8,
    span_start: u32,
    span_end: u32,
    entry_source: []const u8,
    entry_path: []const u8,
) void {
    _ = allocator;
    _ = program_ptr;

    // entry frame
    var entry: error_format.ErrorTraceFrame = .{};
    const ep_len = @min(entry_path.len, entry.path_buf.len);
    @memcpy(entry.path_buf[0..ep_len], entry_path[0..ep_len]);
    entry.path_len = ep_len;
    const elabel = "root stylesheet";
    @memcpy(entry.label_buf[0..elabel.len], elabel);
    entry.label_len = elabel.len;

    // Get callsite span of entry from VM frame_stack (outer frame with sentinel skipped)
    if (vm.outermostCallerInfo()) |caller| {
        const cs_start = caller.span_start;
        const cs_end = caller.span_end;
        // Take position in entry_source (assuming caller.source_module_id == entry module).
        // In the nested case that calls imported from imported, there is a mismatch, but even in that case the entry
        // is the root stylesheet display, and span is the position within "caller's callsite" = imported.
        // Simplification: caller_source is fixed at entry_source (accuracy equivalent to dart is handled by multistage, Phase 4).
        const sp = computeLineColInline(entry_source, cs_start);
        const ep = computeLineColInline(entry_source, cs_end);
        entry.line_no = sp.line + 1;
        entry.col_no = sp.col + 1;
        entry.end_line_no = ep.line + 1;
        entry.end_col_no = ep.col + 1;
        entry.has_span = true;
    } else {
        // Cannot be taken (error in top execution, etc.): fallback 1:1
        entry.has_span = false;
    }

    // inner frame
    var inner: error_format.ErrorTraceFrame = .{};
    const ip_len = @min(inner_path.len, inner.path_buf.len);
    @memcpy(inner.path_buf[0..ip_len], inner_path[0..ip_len]);
    inner.path_len = ip_len;

    // inner label: determined by chunk kind + chunk name
    const chunk_ref = vm.innerMostChunkRef();
    const chunk_name = vm.innerMostChunkName();
    const inner_label_buf_size = inner.label_buf.len;
    const inner_label = formatInnerLabel(chunk_ref, chunk_name, inner.label_buf[0..inner_label_buf_size]);
    inner.label_len = inner_label.len;

    // Extract line/col + line_text from inner span
    const ip = computeLineColInline(inner_source, span_start);
    const iep = computeLineColInline(inner_source, span_end);
    inner.line_no = ip.line + 1;
    inner.col_no = ip.col + 1;
    inner.end_line_no = iep.line + 1;
    inner.end_col_no = iep.col + 1;
    inner.has_span = true;

    const line_text = extractLineInline(inner_source, ip.line);
    const tlen = @min(line_text.len, inner.line_text_buf.len);
    @memcpy(inner.line_text_buf[0..tlen], line_text[0..tlen]);
    inner.line_text_len = tlen;

    error_format.error_state.error_stack_snapshot[0] = entry;
    error_format.error_state.error_stack_snapshot[1] = inner;
    error_format.error_state.error_stack_snapshot_len = 2;
}

const InlineLineCol = struct { line: u32, col: u32 };

fn computeLineColInline(source: []const u8, offset: u32) InlineLineCol {
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

fn extractLineInline(source: []const u8, line: u32) []const u8 {
    var current_line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < source.len and current_line < line) : (i += 1) {
        if (source[i] == '\n') {
            current_line += 1;
            line_start = i + 1;
        }
    }
    var line_end: usize = line_start;
    while (line_end < source.len and source[line_end] != '\n') : (line_end += 1) {}
    if (line_end > line_start and source[line_end - 1] == '\r') line_end -= 1;
    return source[line_start..line_end];
}

/// dart compatible inner label format.
/// - function: `name()`
/// - mixin: `@include name`
/// - content / placeholder / top: simple fallback
fn formatInnerLabel(ref: vm_mod.ChunkRef, name: []const u8, buf: []u8) []const u8 {
    const written = switch (ref) {
        .function => std.fmt.bufPrint(buf, "{s}()", .{name}) catch return buf[0..0],
        .mixin => std.fmt.bufPrint(buf, "@include {s}", .{name}) catch return buf[0..0],
        .content => std.fmt.bufPrint(buf, "@content", .{}) catch return buf[0..0],
        .placeholder => std.fmt.bufPrint(buf, "@extend", .{}) catch return buf[0..0],
        .top => std.fmt.bufPrint(buf, "root stylesheet", .{}) catch return buf[0..0],
    };
    return written;
}

fn computeLineStarts(allocator: std.mem.Allocator, source: []const u8) ![]u32 {
    var nl_count: usize = 1;
    for (source) |c| {
        if (c == '\n') nl_count += 1;
    }
    var list: std.ArrayListUnmanaged(u32) = .empty;
    defer list.deinit(allocator);
    try list.ensureTotalCapacity(allocator, nl_count);
    list.appendAssumeCapacity(0);
    for (source, 0..) |c, i| {
        if (c == '\n') {
            list.appendAssumeCapacity(@intCast(i + 1));
        }
    }
    return try list.toOwnedSlice(allocator);
}

/// CLI-FIX-E Step 3 (C-6): Write error CSS template when error occurs in file output mode.
/// Existing output file (if partially written) is overwritten. If stdout (-), do nothing.
/// If `--no-error-css` is specified, do nothing (= do not create any file, compatible with dart).
fn writeErrorCssIfNeeded(
    allocator: std.mem.Allocator,
    output_path: []const u8,
    err: anyerror,
    input_path: []const u8,
    opts: RunOpts,
    source_hint: ?[]const u8,
    line_starts_hint: ?[]const u32,
) void {
    if (!opts.error_css_enabled) return;
    if (std.mem.eql(u8, output_path, "-")) return;

    // Resolve source / line_starts: use hint if present, reread entry if not.
    var source_owned: ?[]const u8 = null;
    var line_starts_owned: ?[]u32 = null;
    defer if (source_owned) |s| allocator.free(s);
    defer if (line_starts_owned) |ls| allocator.free(ls);

    var source: ?[]const u8 = source_hint;
    var line_starts: ?[]const u32 = line_starts_hint;
    const ctx = error_format.error_state.last_error_ctx;
    if (source == null and ctx.file_id == 0 and !std.mem.eql(u8, input_path, "<stdin>")) {
        const s = readFileToStringAlloc(allocator, input_path) catch null;
        if (s) |sv| {
            source_owned = sv;
            source = sv;
        }
    }
    // Calculate if source is present and line_starts is not passed in hint.
    if (source != null and line_starts == null) {
        const ls = computeLineStarts(allocator, source.?) catch null;
        if (ls) |lsv| {
            line_starts_owned = lsv;
            line_starts = lsv;
        }
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
    error_format.writeErrorCssTemplate(
        &aw.writer,
        err,
        input_path,
        source,
        line_starts,
        ctx.span_start,
        ctx.span_end,
        ctx.has_value,
    ) catch return;
    buf = aw.toArrayList();

    // Atomic write: a partial error CSS is worse than no file at all, so we
    // stage on a sibling temp and only replace on success. The replacement
    // failures are best-effort (matches the previous silent-drop semantics
    // for mkdir / write failure - the user already saw the diagnostic on
    // stderr).
    writeFileAtomic(output_path, buf.items) catch |write_err| {
        switch (write_err) {
            else => {},
        }
    };
}

/// A dart-sass CLI compatible flag whose behavior completely matches that of zsass and can be accepted.
/// Explicitly no-op as "compatible" instead of silent drop.
const compat_noop_flags = std.StaticStringMap(void).initComptime(.{
    .{ "--stop-on-error", {} },
    .{ "--no-stop-on-error", {} },
    .{ "--no-embed-source-map", {} },
    .{ "--no-stdin", {} },
});

/// dart-sass CLI compatible flags that return error 64 because they are not implemented.
const not_implemented_bool_flags = std.StaticStringMap([]const u8).initComptime(.{});

/// Of dart-sass CLI flags that accept values, only default values are accepted.
/// key: flag name, value: Acceptable default value.
const value_checked_flags = std.StaticStringMap([]const u8).initComptime(.{
    .{ "--indent-type", "space" },
    .{ "--indent-width", "2" },
    .{ "--linefeed", "lf" },
});

/// Noop related to deprecation that cannot be handled by the deprecation infrastructure.
const deprecation_compat_flags = std.StaticStringMap(void).initComptime(.{
    .{ "--quiet-deps", {} },
    .{ "--no-quiet-deps", {} },
});

fn isValueFlag(flag_name: []const u8) bool {
    return value_checked_flags.has(flag_name);
}

fn checkValueFlag(flag_name: []const u8, val: []const u8) bool {
    if (value_checked_flags.get(flag_name)) |expected| {
        if (std.mem.eql(u8, val, expected)) return true;
        cliErrPrint("error: unsupported value: {s}={s} (zsass only supports '{s}')\n", .{ flag_name, val, expected });
        std.process.exit(64);
    }
    unreachable;
}

fn isUnsupportedPkgImporterFlag(flag: []const u8) bool {
    return std.mem.eql(u8, flag, "--pkg-importer") or
        std.mem.eql(u8, flag, "-p") or
        std.mem.startsWith(u8, flag, "--pkg-importer=") or
        std.mem.startsWith(u8, flag, "-p=");
}

fn isDeprecationValueFlag(flag_name: []const u8) bool {
    return std.mem.eql(u8, flag_name, "--silence-deprecation") or
        std.mem.eql(u8, flag_name, "--future-deprecation") or
        std.mem.eql(u8, flag_name, "--fatal-deprecation");
}

fn handleDeprecationValueFlag(opts: *RunOpts, flag: []const u8, val: []const u8) deprecation_mod.ParseDeprecationError!void {
    const set_type: deprecation_mod.DeprecationSetType = if (std.mem.eql(u8, flag, "--silence-deprecation"))
        .silence
    else if (std.mem.eql(u8, flag, "--fatal-deprecation"))
        .fatal
    else
        .future;
    try deprecation_mod.parseDeprecationList(&opts.deprecation, set_type, val);
}

const bash_completion_script =
    \\# zsass CLI completion for bash
    \\_zsass_cli_completions()
    \\{
    \\    local cur prev opts
    \\    COMPREPLY=()
    \\    cur="${COMP_WORDS[COMP_CWORD]}"
    \\    prev="${COMP_WORDS[COMP_CWORD-1]}"
    \\    opts="--help -h --version -v -V --interactive -i --style --source-map --no-source-map --source-map-file --source-map-url --source-map-urls --embed-source-map --no-embed-source-map --embed-sources --no-embed-sources --charset --no-charset --plain-css --scss --indented --no-indented --quiet -q --no-quiet --verbose --no-verbose --update --quiet-deps --no-quiet-deps --stop-on-error --no-stop-on-error --silence-deprecation --future-deprecation --fatal-deprecation --color -c --no-color --unicode --no-unicode --error-css --no-error-css --watch -w --poll --no-poll --trace --no-trace --stdin --stdin-filepath --chdir -C --load-path -I --output -o --list-load-paths --env-report --dry-run --dry-run=json --check --completions"
    \\    if [[ "$prev" == "--completions" ]]; then
    \\        COMPREPLY=( $(compgen -W "bash zsh fish" -- "$cur") )
    \\        return 0
    \\    fi
    \\    COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
    \\}
    \\complete -F _zsass_cli_completions zsass
;

const zsh_completion_script =
    \\#compdef zsass
    \\_zsass() {
    \\    _arguments -s -S -C \
    \\      '(-h --help)'{-h,--help}'[Print help text]' \
    \\      '(-v -V --version)'{-v,-V,--version}'[Print version information]' \
    \\      '(-i --interactive)'{-i,--interactive}'[Run interactive REPL]' \
    \\      '*'{-I,--load-path}'[Add load path]:dir:_directories' \
    \\      '(-o --output)'{-o,--output}'[Write CSS to file]:file:_files' \
    \\      '(-C --chdir)'{-C,--chdir}'[Change working directory]:dir:_directories' \
    \\      '--stdin[Read from stdin]' \
    \\      '--stdin-filepath[Virtual path for stdin]:path:_files' \
    \\      '--source-map-file[Override source map path]:file:_files' \
    \\      '--source-map-url[Override sourceMappingURL]:url:' \
    \\      '--source-map-urls[Source map URL mode]:mode:(relative absolute)' \
    \\      '--list-load-paths[List resolved load paths]' \
    \\      '--env-report[Emit env report as JSON]' \
    \\      '--check[Compile without writing output]' \
    \\      '--dry-run[Alias for --check]' \
    \\      '--dry-run=json[Print expanded compile targets as JSON]' \
    \\      '--completions[Print completion script]:shell:(bash zsh fish)' \
    \\      '*:input file:_files -g "*.{scss,sass,css}"'
    \\}
    \\_zsass "$@"
;

const fish_completion_script =
    \\# zsass CLI completion for fish
    \\complete -c zsass -s h -l help -d "Print help text"
    \\complete -c zsass -s v -l version -d "Print version information"
    \\complete -c zsass -s V -d "Alias for --version"
    \\complete -c zsass -s i -l interactive -d "Run interactive SCSS REPL"
    \\complete -c zsass -s I -l load-path -d "Add load path" -r -a "(__fish_complete_directories)"
    \\complete -c zsass -s o -l output -d "Write CSS to file" -r -a "(__fish_complete_path)"
    \\complete -c zsass -s C -l chdir -d "Change working directory" -r -a "(__fish_complete_directories)"
    \\complete -c zsass -l stdin -d "Read from stdin"
    \\complete -c zsass -l stdin-filepath -d "Virtual path for stdin" -r -a "(__fish_complete_path)"
    \\complete -c zsass -l list-load-paths -d "List resolved load paths"
    \\complete -c zsass -l env-report -d "Emit env report as JSON"
    \\complete -c zsass -l check -d "Compile without writing output"
    \\complete -c zsass -l dry-run -d "Alias for --check"
    \\complete -c zsass -l dry-run=json -d "Print expanded compile targets as JSON"
    \\complete -c zsass -l completions -d "Print completion script" -r -a "bash zsh fish"
;

const RunOpts = struct {
    phase_timer: bool = false,
    dump_bc: bool = false,
    opcode_histogram: bool = false,
    trace_diff: ?[]const u8 = null,
    source_map_mode: SourceMapMode = .auto,
    output_style: rule_ir_mod.OutputStyle = .expanded,
    load_paths: []const []const u8 = &.{},
    source_map_file: ?[]const u8 = null,
    stdin_source: ?[]const u8 = null,
    stdin_module_path: ?[]const u8 = null,
    deprecation: deprecation_mod.DeprecationOpts = .{},
    /// CLI-FIX-E Step 3 (C-6): Use error CSS template when error occurs in file output mode
    /// Write to the output file. The dart-sass default is on, `--no-error-css` turns it off.
    error_css_enabled: bool = true,
    /// Emit @charset "UTF-8" for non-ASCII output (default on, --no-charset suppresses).
    charset: bool = true,
    /// Override URL written in the `sourceMappingURL` trailing CSS comment (file source-map mode).
    source_map_url: ?[]const u8 = null,
    /// How `sources` paths are encoded in the emitted `.map` JSON.
    source_map_urls_mode: source_map_mod.SourceMapUrlsMode = .relative,
    /// Skip compile when output file exists and is at least as new as the input (`--update`).
    update_mode: bool = false,
    /// Run the full parse/resolve/compile/VM/emit pipeline like a normal
    /// build, but discard the rendered CSS instead of writing it. Used by
    /// `--check` / `--dry-run` so callers can observe `@error`, runtime
    /// evaluation, and emission failures that the lighter `--compile-only`
    /// path skips.
    check_mode: bool = false,
    /// Include `sourcesContent` in emitted `.map` JSON (`--embed-sources`).
    embed_sources: bool = false,
    /// ANSI color in user-facing diagnostics (`--color` / `--no-color`).
    diagnostic_ansi: bool = true,
    /// Unicode box-drawing in source frames (`--unicode` / `--no-unicode`).
    diagnostic_unicode: bool = true,
    /// When non-null, runEnd2EndWithPool refills this carrier with the
    /// resolved module paths after a successful compile so the `--watch`
    /// loop can stat dependency mtimes (not just the entry). Paths are
    /// stored back-to-back inside the `WatchDeps` flat byte buffer; the
    /// caller only needs to manage the `WatchDeps` lifecycle (`deinit`).
    watch_out_deps: ?*WatchDeps = null,
    /// Force a particular source-syntax interpretation regardless of the
    /// entry path's extension. `null` means "infer from the path" (`.sass`
    /// -> indented, `.css` -> plain CSS, anything else -> SCSS), matching
    /// dart-sass `--scss` (default) / `--indented` / `--no-indented` /
    /// `--plain-css` semantics.
    syntax_override: ?syntax_override_mod.SyntaxOverride = null,
};

/// Out-parameter carrier for `RunOpts.watch_out_deps`. The watcher owns
/// the underlying flat buffer and is responsible for calling `deinit` once
/// it is done with the snapshot. Paths are stored back-to-back in `bytes`
/// with `offsets` recording each entry's slice range, so refreshing the
/// snapshot needs no per-path heap dupe.
const WatchDeps = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    offsets: std.ArrayListUnmanaged(WatchDepRange) = .empty,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WatchDeps) void {
        self.bytes.deinit(self.allocator);
        self.offsets.deinit(self.allocator);
    }

    pub fn clearForRefresh(self: *WatchDeps) void {
        self.bytes.clearRetainingCapacity();
        self.offsets.clearRetainingCapacity();
    }

    pub fn append(self: *WatchDeps, path: []const u8) !void {
        const start: u32 = @intCast(self.bytes.items.len);
        try self.bytes.appendSlice(self.allocator, path);
        const end: u32 = @intCast(self.bytes.items.len);
        try self.offsets.append(self.allocator, .{ .start = start, .end = end });
    }

    pub fn count(self: *const WatchDeps) usize {
        return self.offsets.items.len;
    }

    pub fn pathAt(self: *const WatchDeps, i: usize) []const u8 {
        const o = self.offsets.items[i];
        return self.bytes.items[o.start..o.end];
    }
};

const WatchDepRange = struct {
    start: u32,
    end: u32,
};

/// Locate the colon that separates `input` from `output` in a positional
/// argument such as `src/app.scss:dist/app.css`, while leaving Windows
/// drive-letter colons (`C:\src\app.scss`) alone. The drive prefix is only
/// recognised at the very start of the argument; a stray `D:\out.css` on
/// the right-hand side stays in the output portion because we split on the
/// first non-drive colon we find.
fn findInputOutputSeparator(p: []const u8) ?usize {
    var start: usize = 0;
    if (p.len >= 3 and isAlphaAscii(p[0]) and p[1] == ':' and (p[2] == '\\' or p[2] == '/')) {
        start = 3;
    }
    if (std.mem.indexOfScalar(u8, p[start..], ':')) |rel| {
        return start + rel;
    }
    return null;
}

fn isAlphaAscii(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

const FileJob = struct {
    input_path: []const u8,
    output_path: []const u8,
    opts: RunOpts,
    /// True when input_path / output_path were heap-allocated by
    /// collectDirJobs (or other directory-compile paths) and therefore
    /// need to be freed when the job list is torn down. Single-shot
    /// CLI / stdin paths leave this false because their paths are
    /// borrowed from argv.
    owns_paths: bool = false,

    pub fn deinit(self: *FileJob, allocator: std.mem.Allocator) void {
        if (self.owns_paths) {
            allocator.free(self.input_path);
            allocator.free(self.output_path);
            self.input_path = &.{};
            self.output_path = &.{};
            self.owns_paths = false;
        }
    }
};

fn deinitJobList(allocator: std.mem.Allocator, jobs: *std.ArrayListUnmanaged(FileJob)) void {
    for (jobs.items) |*job| job.deinit(allocator);
    jobs.deinit(allocator);
}

const WeightedJob = struct {
    index: usize,
    size: u64,
};

/// CLI entry: parse args, compile a single SCSS input, and write CSS to stdout
/// or the `-o` path. Supports `--source-map`, `--load-path`, `--trace-diff`,
/// and `--opcode-histogram`. Exits the process with non-zero on error.
pub fn main(init: std.process.Init) !void {
    zsass_io_mod.io = init.io;
    const allocator = std.heap.c_allocator;
    defer dumpPerfCountersIfEnabled();

    var args_list: std.ArrayList([:0]const u8) = .empty;
    const args_owned_on_windows = @import("builtin").target.os.tag == .windows;
    var args_storage: ?[]u8 = null;
    defer {
        if (args_storage) |s| allocator.free(s);
        args_list.deinit(allocator);
    }
    if (args_owned_on_windows) {
        // Pack every CLI arg into a single NUL-separated buffer, then
        // expose each entry as a `[:0]const u8` slice into that buffer.
        // Avoids per-arg dupeZ-in-loop while still giving callers a
        // sentinel-terminated view (needed for the Win32 chdir/exec paths).
        var args_bytes: std.ArrayListUnmanaged(u8) = .empty;
        errdefer args_bytes.deinit(allocator);
        var arg_starts: std.ArrayListUnmanaged(u32) = .empty;
        defer arg_starts.deinit(allocator);

        var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
        defer it.deinit();
        while (it.next()) |arg| {
            try arg_starts.append(allocator, @intCast(args_bytes.items.len));
            try args_bytes.appendSlice(allocator, arg);
            try args_bytes.append(allocator, 0);
        }
        const storage = try args_bytes.toOwnedSlice(allocator);
        args_storage = storage;

        try args_list.ensureTotalCapacity(allocator, arg_starts.items.len);
        for (arg_starts.items, 0..) |start_u32, i| {
            const start: usize = @intCast(start_u32);
            const end: usize = if (i + 1 < arg_starts.items.len)
                @as(usize, @intCast(arg_starts.items[i + 1])) - 1
            else
                storage.len - 1;
            std.debug.assert(storage[end] == 0);
            const arg_z: [:0]const u8 = storage[start..end :0];
            args_list.appendAssumeCapacity(arg_z);
        }
    } else {
        var it: std.process.Args.Iterator = .init(init.minimal.args);
        while (it.next()) |arg| {
            try args_list.append(allocator, arg);
        }
    }
    const args = args_list.items;
    applyEarlyChdir(args);

    if (args.len < 2) {
        writeStdoutAll(USAGE);
        std.process.exit(64);
    }

    const first = args[1];

    if (std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help")) {
        writeStdoutAll(USAGE);
        std.process.exit(64);
    }
    if (parseVersionCliArg(first)) |vf| {
        printVersion(vf);
        return;
    }
    if (std.mem.startsWith(u8, first, "--version=")) {
        cliErrPrint("error: --version format must be 'text' or 'json'\n", .{});
        std.process.exit(64);
    }
    if (parseBuildInfoFormat(first)) |format| {
        printBuildInfo(format);
        return;
    }
    if (std.mem.startsWith(u8, first, "--info=")) exitInvalidBuildInfoFormat();
    if (std.mem.eql(u8, first, "--completions") and args.len >= 3) {
        if (parseCompletionShell(args[2])) |shell| {
            printCompletions(shell);
            return;
        }
        cliErrPrint("error: --completions requires one of bash|zsh|fish\n", .{});
        std.process.exit(EX_USAGE);
    }
    if (std.mem.startsWith(u8, first, "--completions=")) {
        const raw = first["--completions=".len..];
        if (parseCompletionShell(raw)) |shell| {
            printCompletions(shell);
            return;
        }
        cliErrPrint("error: --completions requires one of bash|zsh|fish\n", .{});
        std.process.exit(EX_USAGE);
    }

    if (std.mem.eql(u8, first, "--compile-only")) {
        if (args.len != 3) {
            cliErrPrint("{s}", .{USAGE});
            std.process.exit(EX_USAGE);
        }
        runCompileOnly(allocator, args[2]) catch |err| {
            cliErrPrint("error: {}\n", .{err});
            std.process.exit(exitCodeForError(err));
        };
        return;
    }

    if (std.mem.eql(u8, first, "--exec")) {
        cliErrPrint("--exec: not implemented yet\n", .{});
        std.process.exit(EX_USAGE);
    }

    var opts: RunOpts = .{};
    var positional: std.ArrayListUnmanaged([:0]const u8) = .empty;
    defer positional.deinit(allocator);
    var load_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer load_paths.deinit(allocator);

    var watch_mode = false;
    var update_mode = false;
    var poll_flag_seen = false;
    var poll_no = false;
    var interactive_mode = false;

    var stdin_mode = false;
    var stdin_filepath: ?[]const u8 = null;
    var output_path_flag: ?[]const u8 = null;
    var compile_only_alias = false;
    var dry_run_json = false;
    var list_load_paths_mode = false;
    var env_report_mode = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            writeStdoutAll(USAGE);
            // POSIX/GNU convention: explicit help is a successful invocation.
            // Returning 64 broke `tool --help >/dev/null`, package-manager
            // smoke tests and shell-completion generators.
            std.process.exit(0);
        } else if (std.mem.eql(u8, a, "--")) {
            // POSIX `--` terminator: every remaining arg is positional, even
            // if it starts with `-`.
            i += 1;
            while (i < args.len) : (i += 1) {
                try positional.append(allocator, args[i]);
            }
            break;
        } else if (parseVersionCliArg(a)) |vf| {
            printVersion(vf);
            return;
        } else if (parseBuildInfoFormat(a)) |format| {
            printBuildInfo(format);
            return;
        } else if (std.mem.startsWith(u8, a, "--info=")) {
            exitInvalidBuildInfoFormat();
        } else if (std.mem.eql(u8, a, "--phase-timer")) {
            opts.phase_timer = true;
        } else if (std.mem.eql(u8, a, "--dump-bc")) {
            opts.dump_bc = true;
        } else if (std.mem.eql(u8, a, "--opcode-histogram")) {
            opts.opcode_histogram = true;
        } else if (std.mem.eql(u8, a, "--trace-diff")) {
            if (i + 1 >= args.len) {
                cliErrPrint("error: --trace-diff requires a reference path\n", .{});
                std.process.exit(EX_USAGE);
            }
            i += 1;
            opts.trace_diff = args[i];
        } else if (std.mem.eql(u8, a, "--source-map")) {
            opts.source_map_mode = .file;
        } else if (std.mem.eql(u8, a, "--no-source-map")) {
            opts.source_map_mode = .off;
        } else if (std.mem.eql(u8, a, "--error-css")) {
            opts.error_css_enabled = true;
        } else if (std.mem.eql(u8, a, "--no-error-css")) {
            opts.error_css_enabled = false;
        } else if (std.mem.eql(u8, a, "--source-map-urls")) {
            if (i + 1 >= args.len) {
                cliErrPrint("error: --source-map-urls requires 'relative' or 'absolute'\n", .{});
                std.process.exit(EX_USAGE);
            }
            i += 1;
            opts.source_map_urls_mode = parseSourceMapUrlsMode(args[i]);
        } else if (std.mem.startsWith(u8, a, "--source-map-urls=")) {
            const value = a["--source-map-urls=".len..];
            opts.source_map_urls_mode = parseSourceMapUrlsMode(value);
        } else if (std.mem.eql(u8, a, "--source-map-url")) {
            if (i + 1 >= args.len) {
                cliErrPrint("error: --source-map-url requires a path or URL\n", .{});
                std.process.exit(EX_USAGE);
            }
            i += 1;
            requireNonEmptyUrlArg("--source-map-url", args[i]);
            opts.source_map_url = args[i];
        } else if (std.mem.startsWith(u8, a, "--source-map=")) {
            const value = a["--source-map=".len..];
            if (std.ascii.eqlIgnoreCase(value, "inline")) {
                opts.source_map_mode = .@"inline";
            } else if (std.ascii.eqlIgnoreCase(value, "file") or value.len == 0) {
                opts.source_map_mode = .file;
            } else if (std.ascii.eqlIgnoreCase(value, "off")) {
                opts.source_map_mode = .off;
            } else {
                cliErrPrint("error: --source-map must be one of file|inline|off\n", .{});
                std.process.exit(EX_USAGE);
            }
        } else if (std.mem.eql(u8, a, "--load-path") or std.mem.eql(u8, a, "-I")) {
            if (i + 1 >= args.len) {
                cliErrPrint("error: {s} requires a directory\n", .{a});
                std.process.exit(EX_USAGE);
            }
            i += 1;
            try load_paths.append(allocator, args[i]);
        } else if (std.mem.startsWith(u8, a, "--load-path=")) {
            try load_paths.append(allocator, a["--load-path=".len..]);
        } else if (std.mem.eql(u8, a, "--stdin")) {
            stdin_mode = true;
        } else if (std.mem.eql(u8, a, "--completions")) {
            if (i + 1 >= args.len) {
                cliErrPrint("error: --completions requires one of bash|zsh|fish\n", .{});
                std.process.exit(EX_USAGE);
            }
            i += 1;
            if (parseCompletionShell(args[i])) |shell| {
                printCompletions(shell);
                return;
            }
            cliErrPrint("error: --completions requires one of bash|zsh|fish\n", .{});
            std.process.exit(EX_USAGE);
        } else if (std.mem.startsWith(u8, a, "--completions=")) {
            const raw = a["--completions=".len..];
            if (parseCompletionShell(raw)) |shell| {
                printCompletions(shell);
                return;
            }
            cliErrPrint("error: --completions requires one of bash|zsh|fish\n", .{});
            std.process.exit(EX_USAGE);
        } else if (std.mem.eql(u8, a, "--dry-run=json")) {
            dry_run_json = true;
        } else if (std.mem.eql(u8, a, "--list-load-paths")) {
            list_load_paths_mode = true;
        } else if (std.mem.eql(u8, a, "--env-report") or std.mem.eql(u8, a, "--env-report=json")) {
            env_report_mode = true;
        } else if (std.mem.eql(u8, a, "--compile-only")) {
            // `--compile-only` is the legacy zsass alias for the lightweight
            // parse / resolve / compile path -- it skips VM execution and
            // CSS emission. Useful for "did this file at least parse?"
            // checks but cannot detect `@error`, runtime-only failures, or
            // emit bugs.
            compile_only_alias = true;
        } else if (std.mem.eql(u8, a, "--check") or std.mem.eql(u8, a, "--dry-run")) {
            // dart-sass `--check` / `--dry-run`: run the entire pipeline
            // and report failures, but never write CSS / source-map files.
            opts.check_mode = true;
        } else if (std.mem.eql(u8, a, "--stdin-filepath")) {
            if (i + 1 >= args.len) {
                cliErrPrint("error: --stdin-filepath requires a path\n", .{});
                std.process.exit(EX_USAGE);
            }
            i += 1;
            stdin_filepath = args[i];
        } else if (std.mem.startsWith(u8, a, "--stdin-filepath=")) {
            stdin_filepath = a["--stdin-filepath=".len..];
        } else if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--output")) {
            if (i + 1 >= args.len) {
                cliErrPrint("error: {s} requires a path\n", .{a});
                std.process.exit(EX_USAGE);
            }
            i += 1;
            output_path_flag = args[i];
        } else if (std.mem.startsWith(u8, a, "--output=")) {
            output_path_flag = a["--output=".len..];
        } else if (std.mem.eql(u8, a, "--source-map-file")) {
            if (i + 1 >= args.len) {
                cliErrPrint("error: --source-map-file requires a path\n", .{});
                std.process.exit(EX_USAGE);
            }
            i += 1;
            opts.source_map_file = args[i];
            opts.source_map_mode = .file;
        } else if (std.mem.startsWith(u8, a, "--source-map-file=")) {
            opts.source_map_file = a["--source-map-file=".len..];
            opts.source_map_mode = .file;
        } else if (std.mem.eql(u8, a, "-")) {
            stdin_mode = true;
        } else if (std.mem.eql(u8, a, "--interactive") or std.mem.eql(u8, a, "-i")) {
            interactive_mode = true;
        } else if (std.mem.eql(u8, a, "--watch") or std.mem.eql(u8, a, "-w")) {
            watch_mode = true;
        } else if (std.mem.eql(u8, a, "--update")) {
            update_mode = true;
        } else if (std.mem.eql(u8, a, "--poll")) {
            poll_flag_seen = true;
        } else if (std.mem.eql(u8, a, "--no-poll")) {
            poll_flag_seen = true;
            poll_no = true;
        } else if (std.mem.eql(u8, a, "--chdir") or std.mem.eql(u8, a, "-C")) {
            if (i + 1 >= args.len) {
                cliErrPrint("error: {s} requires a directory\n", .{a});
                std.process.exit(64);
            }
            i += 1;
            // already handled by applyEarlyChdir
        } else if (std.mem.startsWith(u8, a, "--chdir=")) {
            // already handled by applyEarlyChdir
        } else if (std.mem.eql(u8, a, "--embed-source-map")) {
            opts.source_map_mode = .@"inline";
        } else if (std.mem.eql(u8, a, "--verbose")) {
            opts.deprecation.verbose = true;
        } else if (std.mem.eql(u8, a, "--no-verbose")) {
            opts.deprecation.verbose = false;
        } else if (std.mem.eql(u8, a, "--quiet") or std.mem.eql(u8, a, "-q")) {
            opts.deprecation.quiet = true;
        } else if (std.mem.eql(u8, a, "--no-quiet")) {
            opts.deprecation.quiet = false;
        } else if (std.mem.eql(u8, a, "--trace")) {
            opts.deprecation.trace_deprecation = true;
        } else if (std.mem.eql(u8, a, "--no-trace")) {
            opts.deprecation.trace_deprecation = false;
        } else if (std.mem.eql(u8, a, "--color") or std.mem.eql(u8, a, "-c")) {
            opts.diagnostic_ansi = true;
        } else if (std.mem.eql(u8, a, "--no-color")) {
            opts.diagnostic_ansi = false;
        } else if (std.mem.eql(u8, a, "--unicode")) {
            opts.diagnostic_unicode = true;
        } else if (std.mem.eql(u8, a, "--no-unicode")) {
            opts.diagnostic_unicode = false;
        } else if (std.mem.eql(u8, a, "--embed-sources")) {
            opts.embed_sources = true;
        } else if (std.mem.eql(u8, a, "--no-embed-sources")) {
            opts.embed_sources = false;
        } else if (std.mem.eql(u8, a, "--charset")) {
            opts.charset = true;
        } else if (std.mem.eql(u8, a, "--no-charset")) {
            opts.charset = false;
        } else if (std.mem.eql(u8, a, "--indented")) {
            opts.syntax_override = .sass;
        } else if (std.mem.eql(u8, a, "--no-indented") or std.mem.eql(u8, a, "--scss")) {
            opts.syntax_override = .scss;
        } else if (std.mem.eql(u8, a, "--plain-css")) {
            opts.syntax_override = .css;
        } else if (compat_noop_flags.has(a)) {
            // compatible no-op flags (dart-sass CLI superset)
        } else if (not_implemented_bool_flags.has(a)) {
            const msg = not_implemented_bool_flags.get(a).?;
            cliErrPrint("error: {s}\n", .{msg});
            std.process.exit(64);
        } else if (deprecation_compat_flags.has(a)) {
            // --quiet-deps / --no-quiet-deps accepted (cross-module deprecation filter not implemented yet)
        } else if (std.mem.indexOfScalar(u8, a, '=')) |eq| {
            const flag = a[0..eq];
            const val = a[eq + 1 ..];
            if (std.mem.eql(u8, flag, "--style")) {
                if (std.mem.eql(u8, val, "expanded")) {
                    opts.output_style = .expanded;
                } else if (std.mem.eql(u8, val, "compressed")) {
                    opts.output_style = .compressed;
                } else {
                    cliErrPrint("error: unsupported value: --style={s}\n", .{val});
                    std.process.exit(64);
                }
            } else if (std.mem.eql(u8, flag, "--source-map-url")) {
                requireNonEmptyUrlArg("--source-map-url", val);
                opts.source_map_url = val;
            } else if (std.mem.eql(u8, flag, "--source-map-urls")) {
                opts.source_map_urls_mode = parseSourceMapUrlsMode(val);
            } else if (isValueFlag(flag)) {
                _ = checkValueFlag(flag, val);
            } else if (isDeprecationValueFlag(flag)) {
                handleDeprecationValueFlag(&opts, flag, val) catch {
                    std.process.exit(64);
                };
            } else if (compat_noop_flags.has(flag) or deprecation_compat_flags.has(flag)) {
                // compat flag with '=' form, accept
            } else if (not_implemented_bool_flags.has(flag)) {
                const msg = not_implemented_bool_flags.get(flag).?;
                cliErrPrint("error: {s}\n", .{msg});
                std.process.exit(64);
            } else if (isUnsupportedPkgImporterFlag(flag) or isUnsupportedPkgImporterFlag(a)) {
                cliErrPrint("error: --pkg-importer / -p is not supported in zsass v0.1.x; the dart-sass `pkg:` URL importer is on the roadmap (see CHANGELOG)\n", .{});
                std.process.exit(64);
            } else {
                cliErrPrint("error: unknown flag {s}\n", .{a});
                std.process.exit(64);
            }
        } else if (std.mem.eql(u8, a, "--style") or (a.len > 2 and a[0] == '-' and a[1] == 's') or std.mem.eql(u8, a, "-s")) {
            const val: []const u8 = blk: {
                if (std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--style")) {
                    if (i + 1 >= args.len) {
                        cliErrPrint("error: --style requires a value\n", .{});
                        std.process.exit(64);
                    }
                    i += 1;
                    break :blk args[i];
                } else {
                    break :blk a[2..];
                }
            };
            if (std.mem.eql(u8, val, "expanded")) {
                opts.output_style = .expanded;
            } else if (std.mem.eql(u8, val, "compressed")) {
                opts.output_style = .compressed;
            } else {
                cliErrPrint("error: unsupported value: --style={s}\n", .{val});
                std.process.exit(64);
            }
        } else if (isValueFlag(a)) {
            if (i + 1 >= args.len) {
                cliErrPrint("error: {s} requires a value\n", .{a});
                std.process.exit(64);
            }
            i += 1;
            _ = checkValueFlag(a, args[i]);
        } else if (isDeprecationValueFlag(a)) {
            if (i + 1 >= args.len) {
                cliErrPrint("error: {s} requires a value\n", .{a});
                std.process.exit(64);
            }
            i += 1;
            handleDeprecationValueFlag(&opts, a, args[i]) catch {
                std.process.exit(64);
            };
        } else if (std.mem.startsWith(u8, a, "-")) {
            if (isUnsupportedPkgImporterFlag(a)) {
                cliErrPrint("error: --pkg-importer / -p is not supported in zsass v0.1.x; the dart-sass `pkg:` URL importer is on the roadmap (see CHANGELOG)\n", .{});
                std.process.exit(64);
            }
            cliErrPrint("error: unknown flag {s}\n", .{a});
            std.process.exit(64);
        } else {
            try positional.append(allocator, a);
        }
    }

    if (std.c.getenv("SASS_PATH")) |raw_z| {
        const raw = std.mem.sliceTo(raw_z, 0);
        var it = std.mem.splitScalar(u8, raw, std.fs.path.delimiter);
        while (it.next()) |part| {
            if (part.len > 0) {
                try load_paths.append(allocator, part);
            }
        }
    }
    opts.load_paths = load_paths.items;
    opts.update_mode = update_mode;

    // Push the parsed `--indented` / `--no-indented` / `--scss` /
    // `--plain-css` choice into the shared override slot so the parser /
    // resolver pick it up regardless of the entry path's extension. The
    // value persists for the rest of the CLI run; embed_batch workers
    // refresh their own thread-local copy at spawn time.
    syntax_override_mod.set(opts.syntax_override);

    if (poll_flag_seen and !watch_mode) {
        cliErrPrint("error: --poll/--no-poll can only be used with --watch\n", .{});
        std.process.exit(EX_USAGE);
    }
    if (watch_mode and poll_no) {
        cliErrPrint("error: native file watcher is not implemented in zsass; omit --no-poll to use polling\n", .{});
        std.process.exit(EX_USAGE);
    }

    if (interactive_mode) {
        runInteractive(allocator, opts.load_paths) catch |err| {
            cliErrPrint("error: {}\n", .{err});
            std.process.exit(exitCodeForError(err));
        };
        return;
    }

    if (list_load_paths_mode) {
        printLoadPaths(opts.load_paths);
        return;
    }
    if (env_report_mode) {
        printEnvReportJson(opts.load_paths);
        return;
    }
    if (stdin_mode) {
        if (watch_mode) {
            cliErrPrint("error: --watch cannot be used with stdin\n", .{});
            std.process.exit(EX_USAGE);
        }
        if (positional.items.len > 1) {
            cliErrPrint("error: stdin mode accepts at most one positional input (`-`)\n", .{});
            std.process.exit(EX_USAGE);
        }
        if (dry_run_json) {
            const single = [_]FileJob{.{
                .input_path = stdin_filepath orelse "<stdin>",
                .output_path = output_path_flag orelse "-",
                .opts = opts,
            }};
            printDryRunJson(&single, opts);
            return;
        }
        const stdin_source = try readStdinToStringAlloc(allocator);
        defer allocator.free(stdin_source);
        opts.stdin_source = stdin_source;
        opts.stdin_module_path = stdin_filepath orelse "<stdin>";
        const stdin_output = output_path_flag orelse "-";
        runEnd2End(allocator, "-", stdin_output, opts) catch |err| {
            printUserFacingError(err, "<stdin>");
            std.process.exit(exitCodeForError(err));
        };
        return;
    }
    if (compile_only_alias and !dry_run_json) {
        if (positional.items.len == 0) {
            cliErrPrint("error: --compile-only requires at least one input\n", .{});
            std.process.exit(EX_USAGE);
        }
        for (positional.items) |p| {
            // Reuse the shared `input:output` splitter so a Windows
            // drive-letter colon (`C:\src\app.scss`) is not mistaken for
            // the input/output separator.
            const sep = findInputOutputSeparator(p);
            const input_path = if (sep) |s| p[0..s] else p;
            runCompileOnlyWithLoadPaths(allocator, input_path, opts.load_paths) catch |err| {
                printUserFacingError(err, input_path);
                std.process.exit(exitCodeForError(err));
            };
        }
        return;
    }
    if (opts.check_mode and !dry_run_json) {
        if (positional.items.len == 0) {
            cliErrPrint("error: --check requires at least one input\n", .{});
            std.process.exit(EX_USAGE);
        }
        for (positional.items) |p| {
            const sep = findInputOutputSeparator(p);
            const input_path = if (sep) |s| p[0..s] else p;
            // `output_path = "-"` keeps the same plumbing the regular
            // single-input path uses; `RunOpts.check_mode` short-circuits
            // the actual write inside `runEnd2EndWithPool`.
            runEnd2End(allocator, input_path, "-", opts) catch |err| {
                printUserFacingError(err, input_path);
                std.process.exit(exitCodeForError(err));
            };
        }
        return;
    }

    // dart-sass compatible positional format:
    // 1 argument `in:out` -- single (used by realworld_suite.sh)
    // 2 arguments `in out` (no `:` in either) -- single (space separated)
    // N arguments `in1:out1 in2:out2 ...` -- multiple batch (used by bench.sh)
    if (positional.items.len == 0) {
        cliErrPrint("{s}", .{USAGE});
        std.process.exit(EX_USAGE);
    }

    const space_separated_pair =
        positional.items.len == 2 and
        std.mem.indexOfScalar(u8, positional.items[0], ':') == null and
        std.mem.indexOfScalar(u8, positional.items[1], ':') == null;

    if (space_separated_pair) {
        if (output_path_flag != null) {
            cliErrPrint("error: --output cannot be combined with `<input> <output>` positional form\n", .{});
            std.process.exit(EX_USAGE);
        }
        if (dry_run_json) {
            const single = [_]FileJob{.{
                .input_path = positional.items[0],
                .output_path = positional.items[1],
                .opts = opts,
            }};
            printDryRunJson(&single, opts);
            return;
        }
        if (watch_mode) {
            if (stdin_mode) {
                cliErrPrint("error: --watch cannot be used with stdin\n", .{});
                std.process.exit(EX_USAGE);
            }
            const single = [_]FileJob{.{
                .input_path = positional.items[0],
                .output_path = positional.items[1],
                .opts = opts,
            }};
            runWatchLoop(allocator, &single) catch |err| {
                cliErrPrint("error: {}\n", .{err});
                std.process.exit(exitCodeForError(err));
            };
            return;
        }
        runEnd2End(allocator, positional.items[0], positional.items[1], opts) catch |err| {
            printUserFacingError(err, positional.items[0]);
            std.process.exit(exitCodeForError(err));
        };
        return;
    }

    if (output_path_flag) |output_path| {
        if (positional.items.len != 1 or std.mem.indexOfScalar(u8, positional.items[0], ':') != null) {
            cliErrPrint("error: --output requires exactly one positional input path\n", .{});
            std.process.exit(EX_USAGE);
        }
        if (dry_run_json) {
            const single = [_]FileJob{.{
                .input_path = positional.items[0],
                .output_path = output_path,
                .opts = opts,
            }};
            printDryRunJson(&single, opts);
            return;
        }
        if (watch_mode) {
            if (stdin_mode) {
                cliErrPrint("error: --watch cannot be used with stdin\n", .{});
                std.process.exit(EX_USAGE);
            }
            const single = [_]FileJob{.{
                .input_path = positional.items[0],
                .output_path = output_path,
                .opts = opts,
            }};
            runWatchLoop(allocator, &single) catch |err| {
                cliErrPrint("error: {}\n", .{err});
                std.process.exit(exitCodeForError(err));
            };
            return;
        }
        runEnd2End(allocator, positional.items[0], output_path, opts) catch |err| {
            printUserFacingError(err, positional.items[0]);
            std.process.exit(exitCodeForError(err));
        };
        return;
    }

    if (positional.items.len == 1 and std.mem.indexOfScalar(u8, positional.items[0], ':') == null) {
        if (dry_run_json) {
            const single = [_]FileJob{.{
                .input_path = positional.items[0],
                .output_path = "-",
                .opts = opts,
            }};
            printDryRunJson(&single, opts);
            return;
        }
        if (watch_mode) {
            if (stdin_mode) {
                cliErrPrint("error: --watch cannot be used with stdin\n", .{});
                std.process.exit(EX_USAGE);
            }
            const single = [_]FileJob{.{
                .input_path = positional.items[0],
                .output_path = "-",
                .opts = opts,
            }};
            runWatchLoop(allocator, &single) catch |err| {
                cliErrPrint("error: {}\n", .{err});
                std.process.exit(exitCodeForError(err));
            };
            return;
        }
        runEnd2End(allocator, positional.items[0], "-", opts) catch |err| {
            printUserFacingError(err, positional.items[0]);
            std.process.exit(exitCodeForError(err));
        };
        return;
    }

    var jobs: std.ArrayListUnmanaged(FileJob) = .empty;
    defer deinitJobList(allocator, &jobs);
    try jobs.ensureTotalCapacity(allocator, positional.items.len);
    for (positional.items) |p| {
        const sep = findInputOutputSeparator(p) orelse {
            cliErrPrint("error: positional `{s}` is not in `input:output` form\n", .{p});
            std.process.exit(EX_USAGE);
        };
        const input = p[0..sep];
        const output = p[sep + 1 ..];
        if (tryIsDir(input)) {
            try collectDirJobs(allocator, &jobs, input, output, opts);
        } else {
            jobs.append(allocator, .{
                .input_path = input,
                .output_path = output,
                .opts = opts,
            }) catch |err| {
                cliErrPrint("error: failed to prepare compile jobs: {}\n", .{err});
                std.process.exit(EX_SOFTWARE);
            };
        }
    }
    if (dry_run_json) {
        printDryRunJson(jobs.items, opts);
        return;
    }
    filterJobsForUpdate(allocator, &jobs) catch |err| {
        cliErrPrint("error: {}\n", .{err});
        std.process.exit(EX_SOFTWARE);
    };
    if (jobs.items.len == 0) return;

    if (watch_mode) {
        if (stdin_mode) {
            cliErrPrint("error: --watch cannot be used with stdin\n", .{});
            std.process.exit(EX_USAGE);
        }
        runWatchLoop(allocator, jobs.items) catch |err| {
            cliErrPrint("error: {}\n", .{err});
            std.process.exit(exitCodeForError(err));
        };
        return;
    }

    compileFiles(allocator, jobs.items) catch |err| {
        cliErrPrint("error: {}\n", .{err});
        std.process.exit(exitCodeForError(err));
    };
}

/// `-Dprofile=true` Emit aggregated perf counter to stderr only during build.
/// With disabled build, `perf.dumpAll` itself is a no-op, and `if (comptime ...)`
/// This function body also disappears into the optimizer.
fn dumpPerfCountersIfEnabled() void {
    if (comptime !perf.enabled) return;
    var stderr_file = std.Io.File.stderr();
    var buf: [4096]u8 = undefined;
    var w = stderr_file.writer(zsass_io_mod.io, buf[0..]);
    perf.dumpAll(&w.interface) catch return;
    w.interface.flush() catch return;
}

fn buildJobOrderByFileSize(allocator: std.mem.Allocator, jobs: []const FileJob) ![]usize {
    const weighted = try allocator.alloc(WeightedJob, jobs.len);
    defer allocator.free(weighted);

    for (jobs, 0..) |job, idx| {
        const st = std.Io.Dir.cwd().statFile(zsass_io_mod.io, job.input_path, .{}) catch null;
        weighted[idx] = .{
            .index = idx,
            .size = if (st) |stat| stat.size else 0,
        };
    }

    std.mem.sort(WeightedJob, weighted, {}, struct {
        fn lessThan(_: void, a: WeightedJob, b: WeightedJob) bool {
            if (a.size == b.size) return a.index < b.index;
            return a.size > b.size;
        }
    }.lessThan);

    const order = try allocator.alloc(usize, jobs.len);
    for (weighted, 0..) |entry, order_idx| {
        order[order_idx] = entry.index;
    }
    return order;
}

fn compileFiles(allocator: std.mem.Allocator, jobs: []const FileJob) !void {
    if (jobs.len == 0) return;

    const order = try buildJobOrderByFileSize(allocator, jobs);
    defer allocator.free(order);

    if (jobs.len == 1) {
        const job = jobs[order[0]];
        return runEnd2End(allocator, job.input_path, job.output_path, job.opts);
    }

    const cpu_count = std.Thread.getCpuCount() catch 4;
    const worker_count = @min(jobs.len, cpu_count);
    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);

    // Worker over source shared cache (legacy zsass equivalent). Many entries have the same partial
    // Eliminate disk IO duplication in large-scale compilation with `@import`.
    var source_cache = source_cache_mod.SharedSourceCache.init(std.heap.c_allocator);
    defer source_cache.deinit();

    const Shared = struct {
        jobs: []const FileJob,
        order: []const usize,
        source_cache: *source_cache_mod.SharedSourceCache,
        phase_aggregator: ?*PhaseAggregator,
        next_index: usize = 0,
        mutex: std.Io.Mutex = .init,
        first_err: ?struct { err: anyerror, input_path: []const u8 } = null,
        stop: bool = false,
    };

    var phase_agg: PhaseAggregator = .{};
    const phase_agg_ptr: ?*PhaseAggregator = if (jobs.len > 0 and jobs[0].opts.phase_timer) &phase_agg else null;

    var shared: Shared = .{
        .jobs = jobs,
        .order = order,
        .source_cache = &source_cache,
        .phase_aggregator = phase_agg_ptr,
    };

    var started: usize = 0;
    errdefer {
        // Spawn loop bailed mid-way: signal active workers to stop pulling
        // new slots, then join them before our caller unwinds the
        // stack-allocated `shared` (which they're still touching).
        shared.mutex.lockUncancelable(zsass_io_mod.io);
        shared.stop = true;
        shared.mutex.unlock(zsass_io_mod.io);
        for (threads[0..started]) |t| t.join();
    }

    for (threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, struct {
            fn run(state: *Shared) void {
                defer perf.flushThread();
                var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
                defer arena.deinit();
                var pool_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
                defer pool_arena.deinit();
                const pool_alloc = pool_arena.allocator();
                var shared_pool = intern_pool_mod.InternPool.init(pool_alloc) catch |err| {
                    state.mutex.lockUncancelable(zsass_io_mod.io);
                    defer state.mutex.unlock(zsass_io_mod.io);
                    if (state.first_err == null) {
                        state.first_err = .{
                            .err = err,
                            .input_path = "<worker-init>",
                        };
                    }
                    return;
                };
                defer shared_pool.deinit(pool_alloc);

                // per-worker parsed AST cache. Since InternPool is in worker units, AST cache is also
                // Worker unit (cannot be shared because intern_id does not match in cross-worker).
                var local_ast_cache = ast_cache_mod.ParsedAstCache.init(std.heap.c_allocator, &shared_pool);
                defer local_ast_cache.deinit();

                // Cross-entry resolve/compile artifact reuse (Plan C).
                // Skip re-resolve+re-compile for the same vendor module across workers sharing records/id_by_path.
                // Design: `.plans/ideal/20260502-cross-entry-resolve-reuse-design.md`
                var persistent_state = persistent_resolver_mod.PersistentResolverState.init(
                    std.heap.c_allocator,
                    &shared_pool,
                    state.source_cache,
                    &local_ast_cache,
                );
                defer persistent_state.deinit();

                while (true) {
                    const maybe_job: ?FileJob = blk: {
                        state.mutex.lockUncancelable(zsass_io_mod.io);
                        defer state.mutex.unlock(zsass_io_mod.io);

                        if (state.stop) break :blk null;
                        if (state.first_err != null) break :blk null;
                        if (state.next_index >= state.order.len) break :blk null;

                        const slot = state.next_index;
                        state.next_index += 1;
                        break :blk state.jobs[state.order[slot]];
                    };
                    const job = maybe_job orelse return;
                    const arena_alloc = arena.allocator();
                    runEnd2EndWithPool(arena_alloc, job.input_path, job.output_path, job.opts, &shared_pool, state.source_cache, &local_ast_cache, state.phase_aggregator, &persistent_state) catch |err| {
                        state.mutex.lockUncancelable(zsass_io_mod.io);
                        defer state.mutex.unlock(zsass_io_mod.io);
                        if (state.first_err == null) {
                            state.first_err = .{
                                .err = err,
                                .input_path = job.input_path,
                            };
                        }
                        return;
                    };
                    _ = arena.reset(.retain_capacity);
                }
            }
        }.run, .{&shared});
        started += 1;
    }

    for (threads) |thread| thread.join();
    if (shared.first_err) |first| {
        printUserFacingError(first.err, first.input_path);
        // Surface the original error type so the top-level CLI's
        // exitCodeForError(err) maps OOM / internal errors to
        // EX_SOFTWARE rather than collapsing everything to EX_DATAERR.
        return first.err;
    }

    if (phase_agg_ptr) |agg| {
        var pbuf: std.ArrayList(u8) = .empty;
        defer pbuf.deinit(allocator);
        var paw = std.Io.Writer.Allocating.fromArrayList(allocator, &pbuf);
        try paw.writer.print("[phase aggregate over {d} entries, {d} workers]\n", .{ agg.entry_count, worker_count });
        try agg.timer.report(&paw.writer);
        pbuf = paw.toArrayList();
        try writeStderrAll(zsass_io_mod.io, pbuf.items);
    }
}

fn printVersion(fmt: VersionFormatCli) void {
    switch (fmt) {
        .text => {
            var buf: [128]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "zsass {s}\n", .{version_string}) catch "zsass\n";
            writeStdoutAll(text);
        },
        .json => printVersionJson(),
    }
}

fn printVersionJson() void {
    var out_file = std.Io.File.stdout();
    var out_buf: [512]u8 = undefined;
    var out_w = out_file.writer(zsass_io_mod.io, out_buf[0..]);
    out_w.interface.print(
        "{{\"name\":\"zsass\",\"version\":\"{s}\",\"implementation_name\":\"zsass\",\"implementation_version\":\"{s}\"}}\n",
        .{ version_string, version_string },
    ) catch return;
    out_w.interface.flush() catch return;
}

fn parseBuildInfoFormat(arg: []const u8) ?BuildInfoFormat {
    if (std.mem.eql(u8, arg, "--info") or std.mem.eql(u8, arg, "--info=text")) return .text;
    if (std.mem.eql(u8, arg, "--info=json")) return .json;
    return null;
}

fn exitInvalidBuildInfoFormat() noreturn {
    cliErrPrint("--info format must be 'text' or 'json'\n", .{});
    std.process.exit(EX_USAGE);
}

fn printLoadPaths(paths: []const []const u8) void {
    var out_file = std.Io.File.stdout();
    var out_buf: [2048]u8 = undefined;
    var out_w = out_file.writer(zsass_io_mod.io, out_buf[0..]);
    for (paths) |p| {
        out_w.interface.print("{s}\n", .{p}) catch return;
    }
    out_w.interface.flush() catch return;
}

fn printEnvReportJson(paths: []const []const u8) void {
    var out_file = std.Io.File.stdout();
    var out_buf: [4096]u8 = undefined;
    var out_w = out_file.writer(zsass_io_mod.io, out_buf[0..]);
    out_w.interface.print(
        "{{\"name\":\"zsass\",\"version\":\"{s}\",\"optimize\":\"{s}\",\"zig\":\"{s}\",\"load_paths\":[",
        .{ version_string, @tagName(builtin.mode), builtin.zig_version_string },
    ) catch return;
    for (paths, 0..) |p, idx| {
        if (idx != 0) out_w.interface.writeAll(",") catch return;
        writeJsonString(&out_w.interface, p);
    }
    out_w.interface.writeAll("]}\n") catch return;
    out_w.interface.flush() catch return;
}

fn writeJsonString(out_w: *std.Io.Writer, value: []const u8) void {
    var jw = std.json.Stringify{
        .writer = out_w,
        .options = .{},
    };
    jw.write(value) catch return;
}

fn printDryRunJson(jobs: []const FileJob, opts: RunOpts) void {
    var out_file = std.Io.File.stdout();
    var out_buf: [4096]u8 = undefined;
    var out_w = out_file.writer(zsass_io_mod.io, out_buf[0..]);
    out_w.interface.writeAll("{\"style\":") catch return;
    writeJsonString(&out_w.interface, switch (opts.output_style) {
        .expanded => "expanded",
        .compressed => "compressed",
    });
    out_w.interface.writeAll(",\"load_paths\":[") catch return;
    for (opts.load_paths, 0..) |path, idx| {
        if (idx != 0) out_w.interface.writeAll(",") catch return;
        writeJsonString(&out_w.interface, path);
    }
    out_w.interface.writeAll("],\"targets\":[") catch return;
    for (jobs, 0..) |job, idx| {
        if (idx != 0) out_w.interface.writeAll(",") catch return;
        out_w.interface.writeAll("{\"input_kind\":") catch return;
        writeJsonString(&out_w.interface, if (std.mem.eql(u8, job.input_path, "-") or std.mem.eql(u8, job.input_path, "<stdin>")) "stdin" else "file");
        out_w.interface.writeAll(",\"input_path\":") catch return;
        writeJsonString(&out_w.interface, job.input_path);
        out_w.interface.writeAll(",\"output_path\":") catch return;
        writeJsonString(&out_w.interface, job.output_path);
        out_w.interface.writeAll("}") catch return;
    }
    out_w.interface.writeAll("]}\n") catch return;
    out_w.interface.flush() catch return;
}

fn parseCompletionShell(raw: []const u8) ?CompletionShell {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "bash")) return .bash;
    if (std.ascii.eqlIgnoreCase(trimmed, "zsh")) return .zsh;
    if (std.ascii.eqlIgnoreCase(trimmed, "fish")) return .fish;
    return null;
}

fn printCompletions(shell: CompletionShell) void {
    const script = switch (shell) {
        .bash => bash_completion_script,
        .zsh => zsh_completion_script,
        .fish => fish_completion_script,
    };
    writeStdoutAll(script);
}

fn applyEarlyChdir(args: []const [:0]const u8) void {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        // Honor the POSIX `--` terminator: anything after it is a positional
        // argument, never a `--chdir` invocation.
        if (std.mem.eql(u8, a, "--")) break;
        var chdir_target: ?[]const u8 = null;
        if (std.mem.eql(u8, a, "--chdir") or std.mem.eql(u8, a, "-C")) {
            if (i + 1 >= args.len) {
                cliErrPrint("error: {s} requires a directory\n", .{a});
                std.process.exit(EX_USAGE);
            }
            i += 1;
            chdir_target = args[i];
        } else if (std.mem.startsWith(u8, a, "--chdir=")) {
            chdir_target = a["--chdir=".len..];
        }
        if (chdir_target) |target| {
            const target_z = std.heap.c_allocator.dupeZ(u8, target) catch {
                cliErrPrint("error: failed to allocate chdir path\n", .{});
                std.process.exit(EX_SOFTWARE);
            };
            defer std.heap.c_allocator.free(target_z);
            if (std.c.chdir(target_z.ptr) != 0) {
                cliErrPrint("error: failed to chdir to {s}\n", .{target});
                std.process.exit(EX_NOINPUT);
            }
        }
    }
}

fn runCompileOnly(allocator: std.mem.Allocator, input_path: []const u8) !void {
    try runCompileOnlyWithLoadPaths(allocator, input_path, &.{});
}

fn runCompileOnlyWithLoadPaths(allocator: std.mem.Allocator, input_path: []const u8, load_paths: []const []const u8) !void {
    const source = try readFileToStringAlloc(allocator, input_path);
    defer allocator.free(source);

    var r = try compiler_mod.parseResolveCompileWithPath(allocator, source, input_path, load_paths);
    defer r.pool.deinit(allocator);
    defer r.color_pool.deinit(allocator);
    defer r.resolved.deinit();
    defer r.program.deinit();

    cliErrPrint("zsass: compile ok (top chunk {d} instructions)\n", .{r.program.rootMod().top.code.len});
}

fn writeStderrAll(io: std.Io, bytes: []const u8) !void {
    var err_file = std.Io.File.stderr();
    var err_buf: [2048]u8 = undefined;
    var err_w = err_file.writer(io, err_buf[0..]);
    try err_w.interface.writeAll(bytes);
    try err_w.interface.flush();
}

fn writeStdoutAll(bytes: []const u8) void {
    var out_file = std.Io.File.stdout();
    var out_buf: [1024]u8 = undefined;
    var out_w = out_file.writer(zsass_io_mod.io, out_buf[0..]);
    out_w.interface.writeAll(bytes) catch return;
    out_w.interface.flush() catch return;
}

fn printBuildInfo(format: BuildInfoFormat) void {
    switch (format) {
        .text => printBuildInfoText(),
        .json => printBuildInfoJson(),
    }
}

fn formatTargetTriple(buffer: []u8) []const u8 {
    // SAFETY: buffer is large enough for arch-os-abi tag names from std.builtin.
    return std.fmt.bufPrint(
        buffer,
        "{s}-{s}-{s}",
        .{
            @tagName(builtin.target.cpu.arch),
            @tagName(builtin.target.os.tag),
            @tagName(builtin.target.abi),
        },
    ) catch |err| {
        std.debug.panic("formatTargetTriple: {s}", .{@errorName(err)});
    };
}

const BuildInfoJson = struct {
    name: []const u8,
    version: []const u8,
    zig: []const u8,
    target: []const u8,
    optimize: []const u8,
    link_libc: bool,
    single_threaded: bool,
    exe_path: ?[]const u8,
};

fn printBuildInfoText() void {
    var target_buf: [96]u8 = undefined;
    const target = formatTargetTriple(&target_buf);
    const exe_path = std.process.executablePathAlloc(zsass_io_mod.io, std.heap.page_allocator) catch null;
    defer if (exe_path) |buf| std.heap.page_allocator.free(buf);
    var out_file = std.Io.File.stdout();
    var out_buf: [1024]u8 = undefined;
    var out_w = out_file.writer(zsass_io_mod.io, out_buf[0..]);
    out_w.interface.writeAll("zsass build info\n") catch return;
    out_w.interface.print("  version: {s}\n", .{version_string}) catch return;
    out_w.interface.print("  zig: {s}\n", .{builtin.zig_version_string}) catch return;
    out_w.interface.print("  target: {s}\n", .{target}) catch return;
    out_w.interface.print("  optimize: {s}\n", .{@tagName(builtin.mode)}) catch return;
    out_w.interface.print("  link_libc: {s}\n", .{if (builtin.link_libc) "true" else "false"}) catch return;
    out_w.interface.print("  single_threaded: {s}\n", .{if (builtin.single_threaded) "true" else "false"}) catch return;
    if (exe_path) |path| {
        out_w.interface.print("  exe: {s}\n", .{path}) catch return;
    } else {
        out_w.interface.writeAll("  exe: <unknown>\n") catch return;
    }
    out_w.interface.flush() catch return;
}

fn printBuildInfoJson() void {
    var target_buf: [96]u8 = undefined;
    const target = formatTargetTriple(&target_buf);
    const exe_path = std.process.executablePathAlloc(zsass_io_mod.io, std.heap.page_allocator) catch null;
    defer if (exe_path) |buf| std.heap.page_allocator.free(buf);
    const payload = BuildInfoJson{
        .name = "zsass",
        .version = version_string,
        .zig = builtin.zig_version_string,
        .target = target,
        .optimize = @tagName(builtin.mode),
        .link_libc = builtin.link_libc,
        .single_threaded = builtin.single_threaded,
        .exe_path = exe_path,
    };
    var out_file = std.Io.File.stdout();
    var out_buf: [1024]u8 = undefined;
    var out_w = out_file.writer(zsass_io_mod.io, out_buf[0..]);
    var jw = std.json.Stringify{
        .writer = &out_w.interface,
        .options = .{ .whitespace = .indent_2 },
    };
    jw.write(payload) catch return;
    out_w.interface.writeByte('\n') catch return;
    out_w.interface.flush() catch return;
}

const PhaseAggregator = struct {
    timer: observe_mod.PhaseTimer = .{},
    mutex: std.Io.Mutex = .init,
    entry_count: usize = 0,
};

fn shouldSkipForUpdate(allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8, opts: RunOpts) bool {
    const input_stat = std.Io.Dir.cwd().statFile(zsass_io_mod.io, input_path, .{}) catch return false;
    const output_stat = std.Io.Dir.cwd().statFile(zsass_io_mod.io, output_path, .{}) catch return false;
    if (output_stat.mtime.nanoseconds < input_stat.mtime.nanoseconds) return false;

    // Best effort: if a CSS-cache manifest exists for this entry, every
    // resolved `@use` / `@forward` / `@import` partial appears there
    // alongside its size + mtime + hash, so we can prove the dependency
    // graph is still fresh without running the full pipeline. Anything
    // that drifts -- size mismatch, mtime mismatch (or strict-mode hash
    // mismatch) -- short-circuits to `false` and the entry is recompiled.
    //
    // When the manifest is unavailable (cache off, source-map mode, very
    // first build, etc.) we fall back to the entry-only mtime comparison
    // above. That preserves the v0.1 contract: with cache disabled,
    // `--update` only sees the entry file, which is documented in
    // `docs/cli.md`.
    if (!cssCacheEligible(input_path, output_path, opts)) return true;
    const paths = cssCachePaths(allocator, input_path, opts) catch return true;
    defer allocator.free(paths.root);
    defer allocator.free(paths.css);
    defer allocator.free(paths.manifest);
    const manifest = std.Io.Dir.cwd().readFileAlloc(zsass_io_mod.io, paths.manifest, allocator, .limited(1 << 24)) catch return true;
    defer allocator.free(manifest);
    return manifestDepsStillFresh(allocator, manifest);
}

fn filterJobsForUpdate(allocator: std.mem.Allocator, jobs: *std.ArrayListUnmanaged(FileJob)) !void {
    if (jobs.items.len == 0) return;
    if (!jobs.items[0].opts.update_mode) return;

    var kept: std.ArrayListUnmanaged(FileJob) = .empty;
    errdefer {
        // Once a job's path strings have been moved into `kept`, the source
        // entry's `owns_paths` is flipped to false (line below) so the
        // caller's deinitJobList will not free them either. If `append`
        // fails partway through, free what we have already moved before
        // discarding the staging buffer.
        for (kept.items) |*k| k.deinit(allocator);
        kept.deinit(allocator);
    }
    try kept.ensureTotalCapacity(allocator, jobs.items.len);
    for (jobs.items) |*job| {
        const stdout_out = std.mem.eql(u8, job.output_path, "-");
        const stdin_in = std.mem.eql(u8, job.input_path, "-");
        if (stdout_out or stdin_in or !shouldSkipForUpdate(allocator, job.input_path, job.output_path, job.opts)) {
            kept.appendAssumeCapacity(job.*);
            // Ownership of input_path / output_path moved to `kept`; mark
            // the original entry as no-op so the upcoming `jobs.deinit`
            // does not double-free.
            job.owns_paths = false;
        } else {
            // Dropped job: free its owned paths now (otherwise nobody
            // will).
            job.deinit(allocator);
        }
    }
    jobs.deinit(allocator);
    jobs.* = kept;
}

fn sleepPollMs(ms: u32) void {
    // std.Io's vtable handles the OS-specific sleep primitive (nanosleep on
    // POSIX, Sleep on Windows), so the watch-loop poller stays portable.
    const dur = std.Io.Duration.fromMilliseconds(@intCast(ms));
    zsass_io_mod.io.sleep(dur, .awake) catch |err| {
        // The watch loop polls again on the next iteration, so a missed
        // sleep tick is not a failure - just record it at debug level.
        std.log.debug("sleepPollMs: ignored {s}", .{@errorName(err)});
    };
}

/// One mtime per watched path so we can detect any rebuild trigger
/// (entry or dependency) without losing per-file granularity.
const WatchedPath = struct {
    path: []u8,
    mtime: i96,
};

fn pathStillFresh(path: []const u8, prev_mtime: i96) bool {
    const st = std.Io.Dir.cwd().statFile(zsass_io_mod.io, path, .{}) catch return false;
    return st.mtime.nanoseconds == prev_mtime;
}

fn collectWatchedPaths(
    allocator: std.mem.Allocator,
    jobs: []const FileJob,
    deps_per_job: []const WatchDeps,
    out: *std.ArrayListUnmanaged(WatchedPath),
) !void {
    // Build the new snapshot in a staging list. If any allocation fails
    // partway through we discard `staged` and leave `out` intact - the
    // watcher then keeps using the previous snapshot rather than going
    // blind to mtime changes.
    var staged: std.ArrayListUnmanaged(WatchedPath) = .empty;
    errdefer {
        for (staged.items) |w| allocator.free(w.path);
        staged.deinit(allocator);
    }

    for (jobs, 0..) |job, i| {
        try addWatchedPath(allocator, &staged, job.input_path);
        var k: usize = 0;
        while (k < deps_per_job[i].count()) : (k += 1) {
            try addWatchedPath(allocator, &staged, deps_per_job[i].pathAt(k));
        }
    }

    // Commit: replace the previous snapshot atomically.
    for (out.items) |w| allocator.free(w.path);
    out.deinit(allocator);
    out.* = staged;
}

fn addWatchedPath(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(WatchedPath),
    path: []const u8,
) !void {
    if (path.len == 0) return;
    if (std.mem.eql(u8, path, "-") or std.mem.eql(u8, path, "<stdin>")) return;
    // De-duplicate: a single header may be imported by multiple entries.
    for (out.items) |w| {
        if (std.mem.eql(u8, w.path, path)) return;
    }
    const dup = try allocator.dupe(u8, path);
    errdefer allocator.free(dup);
    const st = std.Io.Dir.cwd().statFile(zsass_io_mod.io, path, .{}) catch {
        // The file might not exist yet (e.g. deleted between rebuilds);
        // record a sentinel mtime so the next stat is always considered
        // a change.
        try out.append(allocator, .{ .path = dup, .mtime = 0 });
        return;
    };
    try out.append(allocator, .{ .path = dup, .mtime = st.mtime.nanoseconds });
}

fn anyWatchedPathChanged(watched: []const WatchedPath) bool {
    for (watched) |w| {
        if (!pathStillFresh(w.path, w.mtime)) return true;
    }
    return false;
}

fn freeWatchedPaths(allocator: std.mem.Allocator, watched: *std.ArrayListUnmanaged(WatchedPath)) void {
    for (watched.items) |w| allocator.free(w.path);
    watched.deinit(allocator);
}

fn runWatchLoop(allocator: std.mem.Allocator, jobs: []const FileJob) !void {
    var deps_per_job = try allocator.alloc(WatchDeps, jobs.len);
    defer {
        for (deps_per_job) |*d| d.deinit();
        allocator.free(deps_per_job);
    }
    for (deps_per_job) |*d| d.* = .{ .allocator = allocator };

    // Initial compile: collect deps for each job (errors print but never
    // tear down the watcher; the user typically saves the file again
    // with the fix in place).
    for (jobs, 0..) |job, i| {
        var local_opts = job.opts;
        local_opts.watch_out_deps = &deps_per_job[i];
        runEnd2End(allocator, job.input_path, job.output_path, local_opts) catch |err| {
            printUserFacingError(err, job.input_path);
        };
    }

    try writeStderrAll(zsass_io_mod.io, "\nSass is watching for changes. Press Ctrl-C to stop.\n\n");

    var watched: std.ArrayListUnmanaged(WatchedPath) = .empty;
    defer freeWatchedPaths(allocator, &watched);
    try collectWatchedPaths(allocator, jobs, deps_per_job, &watched);

    while (true) {
        sleepPollMs(100);
        if (!anyWatchedPathChanged(watched.items)) continue;

        for (jobs, 0..) |job, i| {
            var local_opts = job.opts;
            local_opts.watch_out_deps = &deps_per_job[i];
            runEnd2End(allocator, job.input_path, job.output_path, local_opts) catch |err| {
                // Sass / IO errors must NOT terminate the watcher: the user
                // typically saves the file again with the fix in place. Print
                // the diagnostic and keep polling.
                printUserFacingError(err, job.input_path);
            };
        }
        // Refresh the watched-path set so newly added imports start being
        // watched and removed ones stop. Failure here is handled the same
        // way the previous initial collect was: every path that fails
        // gets a sentinel mtime so the next poll triggers a rebuild.
        collectWatchedPaths(allocator, jobs, deps_per_job, &watched) catch |e| {
            cliErrPrint("zsass-watch: failed to refresh watch list: {s}\n", .{@errorName(e)});
        };
    }
}

fn extractReplCssValue(css: []const u8) ?[]const u8 {
    const needle = "--zsass-repl:";
    const idx = std.mem.indexOf(u8, css, needle) orelse return null;
    var i = idx + needle.len;
    while (i < css.len and std.ascii.isWhitespace(css[i])) i += 1;
    var end = i;
    while (end < css.len) : (end += 1) {
        switch (css[end]) {
            ';', '\n', '}' => break,
            else => {},
        }
    }
    if (end == i) return null;
    return css[i..end];
}

fn runInteractive(allocator: std.mem.Allocator, load_paths: []const []const u8) !void {
    var stdin_file = std.Io.File.stdin();
    var rb: [4096]u8 = undefined;
    var rd = stdin_file.reader(zsass_io_mod.io, &rb);

    var wrapped: std.ArrayListUnmanaged(u8) = .empty;
    defer wrapped.deinit(allocator);

    while (true) {
        try writeStderrAll(zsass_io_mod.io, ">> ");
        const line_raw = rd.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                try writeStderrAll(zsass_io_mod.io, "Error: line too long (max reader buffer)\n");
                continue;
            },
            else => |e| return e,
        };
        const line_inclusive = line_raw orelse break;
        const line = std.mem.trimEnd(u8, line_inclusive, "\r");
        if (line.len == 0) continue;

        wrapped.clearRetainingCapacity();
        try wrapped.print(
            allocator,
            ".__zsass_repl__{{\n  --zsass-repl: #{{{s}}};\n}}\n",
            .{line},
        );

        const css = api_mod.compileSourceToCss(allocator, wrapped.items, "<repl>", load_paths, .{}) catch |err| {
            cliErrPrint("Error: {s}\n", .{error_format.errorToUserMessageWithContext(err)});
            continue;
        };
        defer allocator.free(css);

        const value = extractReplCssValue(css) orelse {
            try writeStderrAll(zsass_io_mod.io, "Error: could not read expression result from compiled output\n");
            continue;
        };

        var stdout_file = std.Io.File.stdout();
        var ob: [4096]u8 = undefined;
        var ow = stdout_file.writer(zsass_io_mod.io, ob[0..]);
        try ow.interface.print("{s}\n", .{value});
        try ow.interface.flush();
    }
}

fn runEnd2End(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    output_path: []const u8,
    opts: RunOpts,
) !void {
    return runEnd2EndWithPool(allocator, input_path, output_path, opts, null, null, null, null, null);
}

fn runEnd2EndWithPool(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    output_path: []const u8,
    opts: RunOpts,
    shared_pool: ?*intern_pool_mod.InternPool,
    source_cache: ?*source_cache_mod.SharedSourceCache,
    ast_cache: ?*ast_cache_mod.ParsedAstCache,
    phase_aggregator: ?*PhaseAggregator,
    persistent_state: ?*persistent_resolver_mod.PersistentResolverState,
) !void {
    if (opts.update_mode) {
        if (opts.stdin_source == null and
            !std.mem.eql(u8, input_path, "-") and
            !std.mem.eql(u8, output_path, "-") and
            shouldSkipForUpdate(allocator, input_path, output_path, opts))
        {
            return;
        }
    }

    if (try tryServeCssCache(allocator, input_path, output_path, opts)) {
        return;
    }

    // CLI-FIX-E Step 2: 1 Clear error context before starting compile. The top thread is
    // Avoid referencing the remains of the previous compile.
    error_format.clearErrorContext();
    error_format.setCliDiagnostics(opts.diagnostic_ansi, opts.diagnostic_unicode);

    var deprecation_opts = opts.deprecation;

    const source, const module_path, const source_owned = blk: {
        if (opts.stdin_source) |stdin_source| {
            break :blk .{ stdin_source, opts.stdin_module_path orelse "<stdin>", false };
        }
        const file_source = try readFileToStringAlloc(allocator, input_path);
        break :blk .{ file_source, input_path, true };
    };
    defer if (source_owned) allocator.free(source);

    // CLI-FIX-E Step 3 (C-6): Exit runEnd2EndWithPool error CSS template with error path
    //Write to the output file (if file output mode and --no-error-css are not specified).
    // Note: In batch mode (1 process / multi-entry / parallel thread) thread arena is the next entry
    // There is a conflict that is reset with //. skip for batch (= with phase_aggregator, = jobs len > 1 route).
    // Single-entry path errdefer is sufficient (in case of batch error, catch separately at driver level).
    // The `suppress_error_css` flag lets sub-paths (e.g. --trace-diff) skip
    // the error CSS replacement when they have already produced a real
    // CSS payload and only want to surface a mismatch upstream.
    var suppress_error_css = false;
    errdefer if (phase_aggregator == null and !suppress_error_css) {
        const tag = error_format.lastErrorOr(error.CompileFailed);
        const ctx_for_css = error_format.error_state.last_error_ctx;
        const css_source: ?[]const u8 = if (ctx_for_css.has_value and ctx_for_css.file_id != 0) null else source;
        writeErrorCssIfNeeded(allocator, output_path, tag, module_path, opts, css_source, null);
    };

    var phase_timer: observe_mod.PhaseTimer = .{};
    const phase_timer_ptr: ?*observe_mod.PhaseTimer = if (opts.phase_timer) &phase_timer else null;

    var owned_result: ?compiler_mod.ParseResolveCompileResult = null;
    var borrowed_result: ?compiler_mod.ParseResolveCompileBorrowedPoolResult = null;
    // SAFETY: Assigned from shared or owned compile result before any use.
    var pool_ptr: *intern_pool_mod.InternPool = undefined;
    // SAFETY: Assigned from shared or owned compile result before any use.
    var color_pool_ptr: *value_mod.ColorPool = undefined;
    // SAFETY: Assigned from shared or owned compile result before any use.
    var program_ptr: *compiler_mod.Program = undefined;
    if (shared_pool) |pool| {
        const persistent_ctx: ?compiler_mod.PersistentCompileContext = if (persistent_state) |ps| ps.compileContext() else null;
        borrowed_result = try compiler_mod.parseResolveCompileWithPoolPhaseTimerCachesAndPersistent(allocator, source, module_path, opts.load_paths, phase_timer_ptr, pool, source_cache, ast_cache, persistent_ctx, &deprecation_opts);
        pool_ptr = pool;
        color_pool_ptr = &borrowed_result.?.color_pool;
        program_ptr = &borrowed_result.?.program;
    } else {
        owned_result = try compiler_mod.parseResolveCompileWithPathAndPhaseTimer(allocator, source, module_path, opts.load_paths, phase_timer_ptr, &deprecation_opts);
        pool_ptr = &owned_result.?.pool;
        color_pool_ptr = &owned_result.?.color_pool;
        program_ptr = &owned_result.?.program;
    }
    defer {
        if (borrowed_result) |*r| {
            if (!r.borrowed_color_pool) r.color_pool.deinit(allocator);
            r.resolved.deinit();
            r.program.deinit();
        }
        if (owned_result) |*r| {
            r.pool.deinit(allocator);
            r.color_pool.deinit(allocator);
            r.resolved.deinit();
            r.program.deinit();
        }
    }

    if (opts.dump_bc) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        const w = &aw.writer;
        observe_mod.disassemble("top", program_ptr.rootMod().top.argc, program_ptr.rootMod().top.local_count, program_ptr.rootMod().top.code, program_ptr.rootMod().top.const_pool, pool_ptr, w) catch |e| {
            cliErrPrint("zsass: disassemble top: {}\n", .{e});
            return e;
        };
        for (program_ptr.rootMod().mixins, 0..) |ch, mid| {
            var name_buf: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "mixin_{d}", .{mid}) catch "mixin_?";
            observe_mod.disassemble(name, ch.argc, ch.local_count, ch.code, ch.const_pool, pool_ptr, w) catch |e| {
                cliErrPrint("zsass: disassemble mixin: {}\n", .{e});
                return e;
            };
        }
        for (program_ptr.rootMod().functions, 0..) |ch, fid| {
            var name_buf: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "function_{d}", .{fid}) catch "function_?";
            observe_mod.disassemble(name, ch.argc, ch.local_count, ch.code, ch.const_pool, pool_ptr, w) catch |e| {
                cliErrPrint("zsass: disassemble function: {}\n", .{e});
                return e;
            };
        }
        for (program_ptr.rootMod().content_blocks, 0..) |ch, cid| {
            var name_buf: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "content_{d}", .{cid}) catch "content_?";
            observe_mod.disassemble(name, ch.argc, ch.local_count, ch.code, ch.const_pool, pool_ptr, w) catch |e| {
                cliErrPrint("zsass: disassemble content: {}\n", .{e});
                return e;
            };
        }
        buf = aw.toArrayList();
        try writeStderrAll(zsass_io_mod.io, buf.items);
    }

    // --watch dependency tracking: the resolver has populated
    // `program_ptr.modules` by now. Snapshot every module path so the
    // watch loop can stat their mtimes on the next poll. Allocations are
    // owned by the WatchDeps allocator (the watch loop) and freed there.
    if (opts.watch_out_deps) |deps_out| {
        deps_out.clearForRefresh();
        // Pre-reserve the offsets list (one entry per surviving module
        // path) so the in-loop `WatchDeps.append` does not regrow the
        // ArrayList each iteration. The byte buffer still grows lazily
        // because path lengths are not known up front.
        deps_out.offsets.ensureTotalCapacity(deps_out.allocator, program_ptr.modules.len) catch {};
        for (program_ptr.modules) |mod| {
            if (mod.module_path.len == 0) continue;
            // `<stdin>` is virtual; never put it in the dep list.
            if (std.mem.eql(u8, mod.module_path, "<stdin>")) continue;
            deps_out.append(mod.module_path) catch continue;
        }
    }

    var rule_ir = rule_ir_mod.RuleIR.init();
    defer rule_ir.deinit(allocator);

    var vm = try vm_mod.VM.init(allocator, pool_ptr, color_pool_ptr, &rule_ir, program_ptr);
    vm.error_sink_fd = api_mod.compileErrorSinkFd();
    defer vm.deinit();
    vm.deprecation_opts = deprecation_opts;
    if (std.c.getenv("ZSASS_TRACE_SLOT")) |slot_z| {
        const slot_str = std.mem.sliceTo(slot_z, 0);
        if (std.fmt.parseInt(u32, slot_str, 10)) |v| {
            vm.trace_slot = v;
        } else |_| {}
    }
    const output_to_stdout = std.mem.eql(u8, output_path, "-");
    const resolved_sm_mode = resolveSourceMapMode(opts.source_map_mode, output_to_stdout);
    vm.configureStreamChunkFlush(
        resolved_sm_mode == .off and opts.trace_diff == null,
        1024,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    var histogram: observe_mod.OpcodeHistogram = .{};
    if (opts.opcode_histogram) {
        vm.histogram = &histogram;
    }

    const exec_start: i128 = if (opts.phase_timer) observe_mod.PhaseTimer.begin() else 0;
    const perf_exec_start = perf.timeBegin();
    vm_mod.VM.runTop(&vm) catch |err| {
        if (error_format.verboseErrorsEnabled()) {
            cliErrPrint("zsass: VM error: {}\n", .{err});
        }
        cliErrPrint("Error: {s}\n", .{error_format.errorToUserMessageWithContext(err)});
        // CLI-FIX-E Step 2/2c: Output source frame from span recorded by VM step.
        // file_id == root_index uses entry source, != root_index is program.modules[file_id]
        // Reload source from path + line_starts already exists in modules[file_id].
        const ctx = error_format.error_state.last_error_ctx;
        const root_idx: u32 = program_ptr.root_index;
        const file_id_is_entry = (ctx.file_id == root_idx);
        const frame_info = resolveFrameInfoEx(allocator, program_ptr, ctx, source, module_path, file_id_is_entry);
        defer if (frame_info.source_owned) |s| allocator.free(s);

        // CLI-FIX-E Step 2c+ Phase 3: VM error in imported module is 2-step trace
        // Rendered with (`{imported} l:c {fn-name}()\n {entry} l:c root stylesheet`).
        // Take exact callsite span of entry in outermostCallerInfo() of VM and innerMostChunkName()
        // Reflect the function/mixin name in the inner frame label.
        if (frame_info.has_frame and !file_id_is_entry) {
            buildVmErrorSnapshotV3(&vm, program_ptr, allocator, frame_info.source.?, frame_info.path, ctx.span_start, ctx.span_end, source, module_path);
            error_format.writeStackTrace(allocator) catch {
                error_format.writeSourceFrame(frame_info.source.?, frame_info.line_starts.?, ctx.span_start, ctx.span_end, frame_info.path);
            };
        } else if (frame_info.has_frame) {
            error_format.writeSourceFrame(frame_info.source.?, frame_info.line_starts.?, ctx.span_start, ctx.span_end, frame_info.path);
        } else {
            cliErrPrint("  {s}\n", .{frame_info.path});
        }
        // CLI-FIX-E Step 3 (C-6): Write error CSS template to out.css in file output mode.
        writeErrorCssIfNeeded(
            allocator,
            output_path,
            err,
            frame_info.path,
            opts,
            if (frame_info.has_frame) frame_info.source else null,
            if (frame_info.has_frame) frame_info.line_starts else null,
        );
        // Worker thread must not call std.process.exit; let the caller
        // (single-entry top-level / batch coordinator) decide the exit code
        // after all sibling workers have flushed.
        return err;
    };
    perf.timeEnd(.phase_execute_ns, perf_exec_start);
    if (opts.phase_timer) phase_timer.record(.execute, exec_start);

    if (opts.opcode_histogram) {
        var hbuf: std.ArrayList(u8) = .empty;
        defer hbuf.deinit(allocator);
        var haw = std.Io.Writer.Allocating.fromArrayList(allocator, &hbuf);
        histogram.report(&haw.writer) catch |e| {
            cliErrPrint("zsass: histogram: {}\n", .{e});
            return e;
        };
        hbuf = haw.toArrayList();
        try writeStderrAll(zsass_io_mod.io, hbuf.items);
    }

    if (!output_to_stdout) {
        if (std.fs.path.dirname(output_path)) |dir| {
            if (dir.len != 0) {
                try std.Io.Dir.cwd().createDirPath(zsass_io_mod.io, dir);
            }
        }
    }

    // Writer's blank-line / inline-comment judgment depends on the line number of source_locations, so
    // Always pass line_starts even when source-map is off.
    var source_locations: []rule_ir_mod.SourceLocation = &.{};
    defer if (source_locations.len != 0) allocator.free(source_locations);
    source_locations = try allocator.alloc(rule_ir_mod.SourceLocation, program_ptr.modules.len);
    for (program_ptr.modules, 0..) |mod, idx| {
        source_locations[idx] = .{
            .source_path = mod.module_path,
            .line_starts = mod.line_starts,
            .source_len = mod.source_len,
        };
    }
    var source_map: ?source_map_mod.SourceMap = null;
    if (resolved_sm_mode != .off) {
        source_map = source_map_mod.SourceMap.init(allocator);
    }
    defer if (source_map) |*sm| sm.deinit();

    var sm_out_dir_owned: ?[]const u8 = null;
    defer if (sm_out_dir_owned) |d| allocator.free(d);
    if (!output_to_stdout and resolved_sm_mode != .off) {
        const dir_raw = std.fs.path.dirname(output_path) orelse ".";
        sm_out_dir_owned = zsass_io_mod.realPathAlloc(std.Io.Dir.cwd(), dir_raw, allocator) catch null;
    }

    const emit_start: i128 = if (opts.phase_timer) observe_mod.PhaseTimer.begin() else 0;
    const perf_emit_start = perf.timeBegin();
    defer perf.timeEnd(.phase_emit_ns, perf_emit_start);
    const write_sm_opts: rule_ir_mod.WriteToWithSourceMapOpts = .{
        .source_map_url_override = opts.source_map_url,
        .source_map_urls_mode = opts.source_map_urls_mode,
        .emit_charset = opts.charset,
        .source_map_output_dir_abs = sm_out_dir_owned,
    };
    if (opts.check_mode) {
        // --check / --dry-run: drive the same emit code path as a real
        // build (so writer-side OOM / format bugs surface) but throw the
        // bytes away. Trace-diff comparison, atomic file writes, source-
        // map trailers, and CSS-cache storage are all skipped because
        // they presuppose a real output destination.
        var discard_buf: [4096]u8 = undefined;
        var discard = std.Io.Writer.Discarding.init(discard_buf[0..]);
        var tw = TrackingWriter.init(&discard.writer);
        if (source_map) |*sm| {
            rule_ir.writeToWithSourceMap(&tw.writer, pool_ptr, sm, source_locations, opts.output_style, write_sm_opts) catch |err| {
                cliErrPrint("zsass-check phase=writeTo-sm err={}\n", .{err});
                return err;
            };
            if (opts.embed_sources) sm.populateEmbedContents(allocator, module_path, source) catch |err| {
                cliErrPrint("zsass-check phase=embed-sources err={}\n", .{err});
                return err;
            };
        } else {
            rule_ir.writeToWithSourceMap(&tw.writer, pool_ptr, null, source_locations, opts.output_style, write_sm_opts) catch |err| {
                cliErrPrint("zsass-check phase=writeTo err={}\n", .{err});
                return err;
            };
        }
        try tw.flush();
        if (opts.phase_timer) phase_timer.record(.emit, emit_start);
        return;
    }
    if (opts.trace_diff) |ref_path| {
        if (output_to_stdout) {
            cliErrPrint("error: --trace-diff requires a file output path\n", .{});
            return error.TraceDiffStdoutMisuse;
        }
        // trace-diff requires all bytes because it is a line diff with the reference CSS.
        // Leave the traditional in-memory buffer route only here.
        var css_out: std.ArrayList(u8) = .empty;
        defer css_out.deinit(allocator);
        {
            var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &css_out);
            var tw = TrackingWriter.init(&aw.writer);
            if (source_map) |*sm| {
                try rule_ir.writeToWithSourceMap(&tw.writer, pool_ptr, sm, source_locations, opts.output_style, write_sm_opts);
                if (opts.embed_sources) try sm.populateEmbedContents(allocator, module_path, source);
                try appendSourceMapTrailer(&tw, allocator, sm, resolved_sm_mode, output_path, opts.source_map_file, opts.source_map_url);
            } else {
                try rule_ir.writeToWithSourceMap(&tw.writer, pool_ptr, null, source_locations, opts.output_style, write_sm_opts);
            }
            if (tw.bytes_written == 0 and source_map == null) {
                try tw.writeAll("\n");
            }
            try tw.flush();
            css_out = aw.toArrayList();
        }
        try writeFileAtomic(output_path, css_out.items);

        var dbuf: std.ArrayList(u8) = .empty;
        defer dbuf.deinit(allocator);
        var daw = std.Io.Writer.Allocating.fromArrayList(allocator, &dbuf);
        const ok = try observe_mod.traceDiff(ref_path, css_out.items, &daw.writer, allocator);
        dbuf = daw.toArrayList();
        if (dbuf.items.len != 0) try writeStderrAll(zsass_io_mod.io, dbuf.items);
        // Worker thread must not call std.process.exit; the caller
        // (single-entry top-level / batch coordinator) decides exit code
        // after sibling workers flush. exitCodeForError maps this to
        // EX_DATAERR (= original behaviour). Suppress the error-CSS
        // errdefer so the just-written real CSS is not clobbered with a
        // diagnostic stub.
        if (!ok) {
            suppress_error_css = true;
            return error.TraceDiffMismatch;
        }
    } else {
        var atomic_writer: ?std.Io.File.Atomic = null;
        defer if (atomic_writer) |*a| a.deinit(zsass_io_mod.io);
        var out_file_buf: [64 * 1024]u8 = undefined;
        var out_writer_buf: [4096]u8 = undefined;
        // SAFETY: When writing to a file, `fw` is assigned in the `blk` below before use; stdout path only uses `stdout_writer`.
        var fw: std.Io.File.Writer = undefined;
        var stdout_file = std.Io.File.stdout();
        var stdout_writer = stdout_file.writer(zsass_io_mod.io, out_writer_buf[0..]);
        const target_writer: *std.Io.Writer = if (output_to_stdout) &stdout_writer.interface else blk: {
            const created = try std.Io.Dir.cwd().createFileAtomic(zsass_io_mod.io, output_path, .{
                .replace = true,
                .make_path = true,
            });
            fw = created.file.writer(zsass_io_mod.io, out_file_buf[0..]);
            atomic_writer = created;
            break :blk &fw.interface;
        };
        var tw = TrackingWriter.init(target_writer);
        if (source_map) |*sm| {
            rule_ir.writeToWithSourceMap(&tw.writer, pool_ptr, sm, source_locations, opts.output_style, write_sm_opts) catch |err| {
                cliErrPrint("zsass-emit phase=writeTo-sm err={}\n", .{err});
                return err;
            };
            if (opts.embed_sources) sm.populateEmbedContents(allocator, module_path, source) catch |err| {
                cliErrPrint("zsass-emit phase=embed-sources err={}\n", .{err});
                return err;
            };
            try appendSourceMapTrailer(&tw, allocator, sm, resolved_sm_mode, output_path, opts.source_map_file, opts.source_map_url);
        } else {
            rule_ir.writeToWithSourceMap(&tw.writer, pool_ptr, null, source_locations, opts.output_style, write_sm_opts) catch |err| {
                cliErrPrint("zsass-emit phase=writeTo err={}\n", .{err});
                return err;
            };
            if (tw.bytes_written == 0 and !output_to_stdout) try tw.writeAll("\n");
        }
        try tw.flush();
        if (atomic_writer) |*a| try a.replace(zsass_io_mod.io);
    }
    if (opts.phase_timer) phase_timer.record(.emit, emit_start);

    if (opts.phase_timer) {
        if (phase_aggregator) |agg| {
            agg.mutex.lockUncancelable(zsass_io_mod.io);
            defer agg.mutex.unlock(zsass_io_mod.io);
            agg.timer.parse_ns += phase_timer.parse_ns;
            agg.timer.resolve_ns += phase_timer.resolve_ns;
            agg.timer.compile_ns += phase_timer.compile_ns;
            agg.timer.execute_ns += phase_timer.execute_ns;
            agg.timer.emit_ns += phase_timer.emit_ns;
            agg.entry_count += 1;
        } else {
            var pbuf: std.ArrayList(u8) = .empty;
            defer pbuf.deinit(allocator);
            var paw = std.Io.Writer.Allocating.fromArrayList(allocator, &pbuf);
            try phase_timer.report(&paw.writer);
            pbuf = paw.toArrayList();
            try writeStderrAll(zsass_io_mod.io, pbuf.items);
        }
    }

    try storeCssCache(allocator, input_path, output_path, opts, program_ptr);
}

fn cssCacheEligible(input_path: []const u8, output_path: []const u8, opts: RunOpts) bool {
    if (std.mem.eql(u8, input_path, "-")) return false;
    if (std.mem.eql(u8, output_path, "-")) return false;
    if (opts.stdin_source != null) return false;
    if (resolveSourceMapMode(opts.source_map_mode, false) != .off) return false;
    if (opts.trace_diff != null) return false;
    if (opts.phase_timer or opts.dump_bc or opts.opcode_histogram) return false;
    if (std.c.getenv("ZSASS_CSS_CACHE")) |raw_z| {
        const raw = std.mem.sliceTo(raw_z, 0);
        if (std.mem.eql(u8, raw, "0") or std.ascii.eqlIgnoreCase(raw, "false")) return false;
    }
    return true;
}

fn cssCacheRoot(allocator: std.mem.Allocator) ![]const u8 {
    if (std.c.getenv("ZSASS_CSS_CACHE_DIR")) |raw_z| {
        const raw = std.mem.sliceTo(raw_z, 0);
        if (raw.len != 0) return try allocator.dupe(u8, raw);
    }
    return try allocator.dupe(u8, ".zig-cache/zsass-css-cache-v3");
}

fn appendU64KeyMaterial(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u64) !void {
    var tmp: [8]u8 = undefined;
    std.mem.writeInt(u64, &tmp, value, .little);
    try buf.appendSlice(allocator, &tmp);
}

fn appendI128KeyMaterial(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: i128) !void {
    var tmp: [16]u8 = undefined;
    std.mem.writeInt(i128, &tmp, value, .little);
    try buf.appendSlice(allocator, &tmp);
}

fn cssCacheKeyHex(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    opts: RunOpts,
) ![64]u8 {
    var material: std.ArrayListUnmanaged(u8) = .empty;
    defer material.deinit(allocator);
    try material.appendSlice(allocator, "zsass-css-cache-v3\n");
    try material.appendSlice(allocator, builtin.zig_version_string);
    try material.append(allocator, '\n');
    try material.appendSlice(allocator, @tagName(builtin.mode));
    try material.append(allocator, '\n');
    try material.appendSlice(allocator, input_path);
    try material.append(allocator, '\n');
    var lp_total: usize = 0;
    for (opts.load_paths) |lp| lp_total += lp.len;
    try material.ensureUnusedCapacity(allocator, lp_total + opts.load_paths.len * 3);
    for (opts.load_paths) |lp| {
        material.appendSliceAssumeCapacity("I:");
        material.appendSliceAssumeCapacity(lp);
        material.appendAssumeCapacity('\n');
    }
    try material.appendSlice(allocator, "charset:");
    try material.append(allocator, if (opts.charset) '1' else '0');
    try material.append(allocator, '\n');
    try material.appendSlice(allocator, "sm_urls:");
    try material.appendSlice(allocator, @tagName(opts.source_map_urls_mode));
    try material.append(allocator, '\n');
    try material.appendSlice(allocator, "sm_url:");
    if (opts.source_map_url) |u| {
        try material.appendSlice(allocator, u);
    }
    try material.append(allocator, '\n');
    if (std.process.executablePathAlloc(zsass_io_mod.io, allocator)) |exe_path| {
        defer allocator.free(exe_path);
        try material.appendSlice(allocator, "exe:");
        try material.appendSlice(allocator, exe_path);
        try material.append(allocator, '\n');
        if (std.Io.Dir.cwd().statFile(zsass_io_mod.io, exe_path, .{})) |st| {
            try appendU64KeyMaterial(&material, allocator, st.size);
            try appendI128KeyMaterial(&material, allocator, @as(i128, st.mtime.nanoseconds));
        } else |_| {}
    } else |_| {}

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(material.items, &digest, .{});
    var hex: [64]u8 = undefined;
    const alphabet = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        hex[i * 2] = alphabet[b >> 4];
        hex[i * 2 + 1] = alphabet[b & 0x0f];
    }
    return hex;
}

fn cssCachePaths(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    opts: RunOpts,
) !struct { root: []const u8, css: []const u8, manifest: []const u8 } {
    const root = try cssCacheRoot(allocator);
    errdefer allocator.free(root);
    const key = try cssCacheKeyHex(allocator, input_path, opts);
    const css = try std.fmt.allocPrint(allocator, "{s}/{s}.css", .{ root, key });
    errdefer allocator.free(css);
    const manifest = try std.fmt.allocPrint(allocator, "{s}/{s}.manifest", .{ root, key });
    return .{ .root = root, .css = css, .manifest = manifest };
}

/// Write `bytes` to `path` atomically: stage to a sibling temp file, flush,
/// then rename. A crash mid-write or a failing flush leaves the original
/// `path` untouched (the temp file is cleaned up by `Atomic.deinit`).
fn writeFileAtomic(path: []const u8, bytes: []const u8) !void {
    var af = try std.Io.Dir.cwd().createFileAtomic(zsass_io_mod.io, path, .{
        .replace = true,
        .make_path = true,
    });
    defer af.deinit(zsass_io_mod.io);
    var buf: [64 * 1024]u8 = undefined;
    var w = af.file.writer(zsass_io_mod.io, buf[0..]);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
    try af.replace(zsass_io_mod.io);
}

fn copyWholeFile(allocator: std.mem.Allocator, from: []const u8, to: []const u8) !void {
    const bytes = try readFileToStringAlloc(allocator, from);
    defer allocator.free(bytes);
    try writeFileAtomic(to, bytes);
}

/// True when `ZSASS_CSS_CACHE_STRICT=1` is set in the environment. In strict
/// mode every dependency is content-hashed on each cache lookup so that a
/// same-size, mtime-preserving edit (e.g. `cp -p`, `git restore`, an editor
/// that writes within the same filesystem-mtime tick) cannot return stale
/// CSS.
fn cssCacheStrict() bool {
    if (std.c.getenv("ZSASS_CSS_CACHE_STRICT")) |raw_z| {
        const raw = std.mem.sliceTo(raw_z, 0);
        return std.mem.eql(u8, raw, "1") or std.ascii.eqlIgnoreCase(raw, "true");
    }
    return false;
}

fn fileSha256Hex(allocator: std.mem.Allocator, path: []const u8) !?[64]u8 {
    const data = readFileToStringAlloc(allocator, path) catch return null;
    defer allocator.free(data);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    var hex: [64]u8 = undefined;
    const written = std.fmt.bufPrint(&hex, "{x}", .{&hash}) catch return null;
    if (written.len != 64) return null;
    return hex;
}

fn manifestDepsStillFresh(allocator: std.mem.Allocator, manifest_bytes: []const u8) bool {
    var lines = std.mem.splitScalar(u8, manifest_bytes, '\n');
    const header = lines.next() orelse return false;
    // v1, v2, and unknown headers are treated as stale; this is graceful
    // invalidation when the manifest format bumps.
    if (!std.mem.eql(u8, header, "zsass-css-cache-v3")) return false;
    const strict = cssCacheStrict();
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab1 = std.mem.indexOfScalar(u8, line, '\t') orelse return false;
        const rest1 = line[tab1 + 1 ..];
        const tab2_rel = std.mem.indexOfScalar(u8, rest1, '\t') orelse return false;
        const tab2 = tab1 + 1 + tab2_rel;
        const rest2 = line[tab2 + 1 ..];
        const tab3_rel = std.mem.indexOfScalar(u8, rest2, '\t') orelse return false;
        const tab3 = tab2 + 1 + tab3_rel;
        const size = std.fmt.parseInt(u64, line[0..tab1], 10) catch return false;
        const mtime_ns = std.fmt.parseInt(i128, line[tab1 + 1 .. tab2], 10) catch return false;
        const expected_hash_hex = line[tab2 + 1 .. tab3];
        if (expected_hash_hex.len != 64) return false;
        const path = line[tab3 + 1 ..];
        const st = std.Io.Dir.cwd().statFile(zsass_io_mod.io, path, .{}) catch return false;
        if (st.size != size) return false;
        const mtime_match = @as(i128, st.mtime.nanoseconds) == mtime_ns;
        if (!mtime_match or strict) {
            // Either mtime drifted (e.g. cp -p, git restore) or strict
            // mode forced a content check. Re-hash the file and compare
            // against the manifest. Failure to read = treat as stale.
            const actual_hex = (fileSha256Hex(allocator, path) catch return false) orelse return false;
            if (!std.mem.eql(u8, expected_hash_hex, &actual_hex)) return false;
        }
        const rp = zsass_io_mod.realPathAlloc(std.Io.Dir.cwd(), path, allocator) catch return false;
        defer allocator.free(rp);
        if (!std.mem.eql(u8, path, rp)) return false;
    }
    return true;
}

fn tryServeCssCache(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    output_path: []const u8,
    opts: RunOpts,
) !bool {
    if (!cssCacheEligible(input_path, output_path, opts)) return false;
    const paths = try cssCachePaths(allocator, input_path, opts);
    defer allocator.free(paths.root);
    defer allocator.free(paths.css);
    defer allocator.free(paths.manifest);

    const manifest = readFileToStringAlloc(allocator, paths.manifest) catch return false;
    defer allocator.free(manifest);
    if (!manifestDepsStillFresh(allocator, manifest)) return false;
    std.Io.Dir.cwd().access(zsass_io_mod.io, paths.css, .{}) catch return false;
    try copyWholeFile(allocator, paths.css, output_path);
    return true;
}

fn storeCssCache(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    output_path: []const u8,
    opts: RunOpts,
    program: *const compiler_mod.Program,
) !void {
    if (!cssCacheEligible(input_path, output_path, opts)) return;
    const paths = try cssCachePaths(allocator, input_path, opts);
    defer allocator.free(paths.root);
    defer allocator.free(paths.css);
    defer allocator.free(paths.manifest);
    try std.Io.Dir.cwd().createDirPath(zsass_io_mod.io, paths.root);

    var manifest: std.ArrayListUnmanaged(u8) = .empty;
    defer manifest.deinit(allocator);
    try manifest.appendSlice(allocator, "zsass-css-cache-v3\n");
    for (program.modules) |mod| {
        if (mod.module_path.len == 0) continue;
        const st = std.Io.Dir.cwd().statFile(zsass_io_mod.io, mod.module_path, .{}) catch return;
        const canon = zsass_io_mod.realPathAlloc(std.Io.Dir.cwd(), mod.module_path, allocator) catch return;
        defer allocator.free(canon);
        const hash = (fileSha256Hex(allocator, mod.module_path) catch return) orelse return;
        try manifest.print(allocator, "{d}\t{d}\t{s}\t{s}\n", .{
            st.size,
            st.mtime.nanoseconds,
            hash,
            canon,
        });
    }

    try copyWholeFile(allocator, output_path, paths.css);
    try writeFileAtomic(paths.manifest, manifest.items);
}

fn resolveSourceMapMode(mode: SourceMapMode, output_to_stdout: bool) SourceMapMode {
    return switch (mode) {
        .auto => if (output_to_stdout) .off else .file,
        else => mode,
    };
}

fn tryIsDir(path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(zsass_io_mod.io, path, .{}) catch return false;
    return st.kind == .directory;
}

fn collectDirJobs(
    allocator: std.mem.Allocator,
    jobs: *std.ArrayListUnmanaged(FileJob),
    input_dir: []const u8,
    output_dir: []const u8,
    opts: RunOpts,
) !void {
    const dir = try std.Io.Dir.cwd().openDir(zsass_io_mod.io, input_dir, .{ .iterate = true });
    defer dir.close(zsass_io_mod.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var css_rel_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer css_rel_buf.deinit(allocator);
    while (try walker.next(zsass_io_mod.io)) |entry| {
        switch (entry.kind) {
            .file => {
                const ext = std.fs.path.extension(entry.basename);
                if (!std.mem.eql(u8, ext, ".scss") and !std.mem.eql(u8, ext, ".sass")) continue;
                if (std.mem.startsWith(u8, entry.basename, "_")) continue;
                const input_rel = entry.path;
                const full_input = try std.fs.path.resolve(allocator, &.{ input_dir, input_rel });
                errdefer allocator.free(full_input);
                css_rel_buf.clearRetainingCapacity();
                try css_rel_buf.ensureTotalCapacity(allocator, input_rel.len - ext.len + ".css".len);
                css_rel_buf.appendSliceAssumeCapacity(input_rel[0 .. input_rel.len - ext.len]);
                css_rel_buf.appendSliceAssumeCapacity(".css");
                const output_name = try std.fs.path.resolve(allocator, &.{ output_dir, css_rel_buf.items });
                errdefer allocator.free(output_name);
                try jobs.append(allocator, .{
                    .input_path = full_input,
                    .output_path = output_name,
                    .opts = opts,
                    .owns_paths = true,
                });
            },
            else => {},
        }
    }
}

fn inferSourceMapPath(allocator: std.mem.Allocator, output_path: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}.map", .{output_path});
}

const TrackingWriter = struct {
    inner: *std.Io.Writer,
    writer: std.Io.Writer,
    bytes_written: usize = 0,
    last_byte: ?u8 = null,

    fn init(inner: *std.Io.Writer) TrackingWriter {
        return .{
            .inner = inner,
            .writer = .{
                .vtable = &.{
                    .drain = TrackingWriter.drain,
                    .flush = TrackingWriter.flushVTable,
                },
                .buffer = &.{},
            },
        };
    }

    fn noteWrite(self: *TrackingWriter, bytes: []const u8) void {
        if (bytes.len == 0) return;
        self.bytes_written += bytes.len;
        self.last_byte = bytes[bytes.len - 1];
    }

    fn writeAll(self: *TrackingWriter, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.writer.writeAll(bytes);
    }

    fn flush(self: *TrackingWriter) !void {
        try self.writer.flush();
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *TrackingWriter = @alignCast(@fieldParentPtr("writer", w));
        if (w.end != 0) {
            const buffered = w.buffer[0..w.end];
            try self.inner.writeAll(buffered);
            self.noteWrite(buffered);
            w.end = 0;
        }

        const static = data[0 .. data.len - 1];
        const pattern = data[data.len - 1];
        var written: usize = 0;
        for (static) |chunk| {
            if (chunk.len == 0) continue;
            try self.inner.writeAll(chunk);
            self.noteWrite(chunk);
            written += chunk.len;
        }
        if (pattern.len != 0 and splat != 0) {
            var i: usize = 0;
            while (i < splat) : (i += 1) {
                try self.inner.writeAll(pattern);
                self.noteWrite(pattern);
            }
        }
        written += pattern.len * splat;
        return written;
    }

    fn flushVTable(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *TrackingWriter = @alignCast(@fieldParentPtr("writer", w));
        if (w.end != 0) {
            const buffered = w.buffer[0..w.end];
            try self.inner.writeAll(buffered);
            self.noteWrite(buffered);
            w.end = 0;
        }
        try self.inner.flush();
    }
};

fn appendSourceMapTrailer(
    out: *TrackingWriter,
    allocator: std.mem.Allocator,
    source_map: *source_map_mod.SourceMap,
    mode: SourceMapMode,
    output_path: []const u8,
    source_map_file: ?[]const u8,
    source_map_url_override: ?[]const u8,
) !void {
    switch (mode) {
        .off, .auto => {},
        .@"inline" => {
            const inline_comment = try source_map.toInlineCommentAlloc(allocator);
            defer allocator.free(inline_comment);
            try appendCssComment(out, inline_comment);
        },
        .file => {
            const map_path = if (source_map_file) |smf|
                try allocator.dupe(u8, smf)
            else
                try inferSourceMapPath(allocator, output_path);
            defer allocator.free(map_path);

            const map_url: []const u8 = if (source_map_url_override) |u| u else std.fs.path.basename(map_path);
            try appendSourceMapUrlComment(out, allocator, map_url);

            const json = try source_map.toJsonAlloc(allocator);
            defer allocator.free(json);
            try writeSourceMapFile(map_path, json);
        },
    }
}

fn appendCssComment(out: *TrackingWriter, comment: []const u8) !void {
    if (out.bytes_written == 0 or out.last_byte != '\n') {
        try out.writeAll("\n");
    }
    try out.writeAll(comment);
    try out.writeAll("\n");
}

fn appendSourceMapUrlComment(out: *TrackingWriter, allocator: std.mem.Allocator, map_url: []const u8) !void {
    const comment = try std.fmt.allocPrint(allocator, "/*# sourceMappingURL={s} */", .{map_url});
    defer allocator.free(comment);
    try appendCssComment(out, comment);
}

fn writeSourceMapFile(path: []const u8, json: []const u8) !void {
    try writeFileAtomic(path, json);
}

fn readFileToStringAlloc(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(zsass_io_mod.io, path, .{});
    defer file.close(zsass_io_mod.io);
    var rb: [2048]u8 = undefined;
    var rd = file.reader(zsass_io_mod.io, &rb);
    return try rd.interface.allocRemaining(allocator, .limited(1 << 29));
}

fn readStdinToStringAlloc(allocator: std.mem.Allocator) ![]const u8 {
    var stdin_file = std.Io.File.stdin();
    var rb: [2048]u8 = undefined;
    var rd = stdin_file.reader(zsass_io_mod.io, &rb);
    return try rd.interface.allocRemaining(allocator, .limited(1 << 29));
}

test "value size is 8 bytes" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(value_mod.Value));
}

test "instruction size is 8 bytes" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(opcode_mod.Instruction));
}

test "value extended lanes (calc/interp/callable)" {
    const v_calc = value_mod.Value.calcFragment(42);
    try std.testing.expectEqual(@as(u32, 42), v_calc.calcHandle());
    try std.testing.expect(v_calc.isTruthy());

    const v_interp = value_mod.Value.interpFragment(99);
    try std.testing.expectEqual(@as(u32, 99), v_interp.interpHandle());

    var cpp: value_mod.CallablePayloadPool = .empty;
    defer cpp.deinit(std.testing.allocator);
    const v_call = try value_mod.Value.callable(7, 0b101, &cpp, std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 7), v_call.callableHandle(&cpp));
    try std.testing.expectEqual(@as(u32, 0b101), v_call.callableFlags(&cpp));

    var pool = try intern_pool_mod.InternPool.init(std.testing.allocator);
    defer pool.deinit(std.testing.allocator);
    const name_id = try pool.intern("callable-name");
    const callable_packed = try value_mod.Value.callableMake(
        11,
        value_mod.callable_flag_is_mixin |
            value_mod.callable_flag_is_builtin |
            value_mod.callable_flag_has_module |
            value_mod.callable_flag_accepts_content,
        23,
        name_id,
        &cpp,
        std.testing.allocator,
    );
    try std.testing.expectEqual(@as(u32, 11), callable_packed.callableHandle(&cpp));
    try std.testing.expect(callable_packed.callableIsMixin(&cpp));
    try std.testing.expect(callable_packed.callableIsBuiltin(&cpp));
    try std.testing.expect(callable_packed.callableHasModule(&cpp));
    try std.testing.expect(!callable_packed.callableIsCss(&cpp));
    try std.testing.expect(callable_packed.callableAcceptsContent(&cpp));
    try std.testing.expectEqual(@as(u16, 23), callable_packed.callableModuleId(&cpp));
    try std.testing.expectEqual(name_id, callable_packed.callableNameIntern(&cpp));
}

fn writeFileAll(path: []const u8, bytes: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(zsass_io_mod.io, path, .{ .truncate = true });
    defer file.close(zsass_io_mod.io);
    var buf: [2048]u8 = undefined;
    var w = file.writer(zsass_io_mod.io, buf[0..]);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

fn buildExpectedCssWithTrailer(
    allocator: std.mem.Allocator,
    base_css: []const u8,
    mode: SourceMapMode,
    output_path: []const u8,
    source_map_json: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
    var tw = TrackingWriter.init(&aw.writer);
    try tw.writeAll(base_css);
    switch (mode) {
        .off, .auto => {},
        .file => {
            const map_path = try inferSourceMapPath(allocator, output_path);
            defer allocator.free(map_path);
            try appendSourceMapUrlComment(&tw, allocator, std.fs.path.basename(map_path));
        },
        .@"inline" => {
            const encoded = try source_map_mod.percentEncode(allocator, source_map_json);
            defer allocator.free(encoded);
            const inline_comment = try std.fmt.allocPrint(
                allocator,
                "/*# sourceMappingURL=data:application/json;charset=utf-8,{s} */",
                .{encoded},
            );
            defer allocator.free(inline_comment);
            try appendCssComment(&tw, inline_comment);
        },
    }
    try tw.flush();
    out = aw.toArrayList();
    return try out.toOwnedSlice(allocator);
}

test "runEnd2End output matches API for source map off/file/inline" {
    const allocator = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const source =
        \\.a { color: red; }
        \\.b { width: 10px; }
        \\
    ;

    const tmp_sub = td.sub_path[0..];
    const input_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/input.scss", .{tmp_sub});
    defer allocator.free(input_path);
    try writeFileAll(input_path, source);

    const output_off = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/out-off.css", .{tmp_sub});
    defer allocator.free(output_off);
    try runEnd2End(allocator, input_path, output_off, .{ .source_map_mode = .off });
    const got_off = try readFileToStringAlloc(allocator, output_off);
    defer allocator.free(got_off);
    const expected_off = try api_mod.compileSourceToCss(allocator, source, input_path, &.{}, .{});
    defer allocator.free(expected_off);
    try std.testing.expectEqualStrings(expected_off, got_off);

    const output_file = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/out-file.css", .{tmp_sub});
    defer allocator.free(output_file);
    try runEnd2End(allocator, input_path, output_file, .{ .source_map_mode = .file });
    const got_file = try readFileToStringAlloc(allocator, output_file);
    defer allocator.free(got_file);
    var expected_file_base = try api_mod.compileSourceToCssWithSourceMap(allocator, source, input_path, &.{}, output_file, .{});
    defer expected_file_base.deinit(allocator);
    const expected_file = try buildExpectedCssWithTrailer(
        allocator,
        expected_file_base.css,
        .file,
        output_file,
        expected_file_base.source_map_json,
    );
    defer allocator.free(expected_file);
    try std.testing.expectEqualStrings(expected_file, got_file);

    const map_path = try inferSourceMapPath(allocator, output_file);
    defer allocator.free(map_path);
    const got_map = try readFileToStringAlloc(allocator, map_path);
    defer allocator.free(got_map);
    try std.testing.expectEqualStrings(expected_file_base.source_map_json, got_map);

    const output_inline = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/out-inline.css", .{tmp_sub});
    defer allocator.free(output_inline);
    try runEnd2End(allocator, input_path, output_inline, .{ .source_map_mode = .@"inline" });
    const got_inline = try readFileToStringAlloc(allocator, output_inline);
    defer allocator.free(got_inline);
    var expected_inline_base = try api_mod.compileSourceToCssWithSourceMap(allocator, source, input_path, &.{}, output_inline, .{});
    defer expected_inline_base.deinit(allocator);
    const expected_inline = try buildExpectedCssWithTrailer(
        allocator,
        expected_inline_base.css,
        .@"inline",
        output_inline,
        expected_inline_base.source_map_json,
    );
    defer allocator.free(expected_inline);
    try std.testing.expectEqualStrings(expected_inline, got_inline);
}

test "appendCssComment keeps exactly one separator newline" {
    const allocator = std.testing.allocator;

    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
        var tw = TrackingWriter.init(&aw.writer);
        try tw.writeAll(".a {}\n");
        try appendCssComment(&tw, "/*# sourceMappingURL=a.css.map */");
        try tw.flush();
        out = aw.toArrayList();
        try std.testing.expectEqualStrings(".a {}\n/*# sourceMappingURL=a.css.map */\n", out.items);
    }

    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
        var tw = TrackingWriter.init(&aw.writer);
        try tw.writeAll(".a {}");
        try appendCssComment(&tw, "/*# sourceMappingURL=b.css.map */");
        try tw.flush();
        out = aw.toArrayList();
        try std.testing.expectEqualStrings(".a {}\n/*# sourceMappingURL=b.css.map */\n", out.items);
    }
}

test "buildJobOrderByFileSize sorts larger files first" {
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const allocator = std.testing.allocator;
    const small = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/small.scss", .{td.sub_path[0..]});
    defer allocator.free(small);
    const mid = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/mid.scss", .{td.sub_path[0..]});
    defer allocator.free(mid);
    const large = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/large.scss", .{td.sub_path[0..]});
    defer allocator.free(large);
    try writeFileAll(small, "a{}\n");
    try writeFileAll(mid, "aaaaaaaaaaaa\n");
    try writeFileAll(large, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n");

    const jobs = [_]FileJob{
        .{ .input_path = small, .output_path = "-", .opts = .{} },
        .{ .input_path = large, .output_path = "-", .opts = .{} },
        .{ .input_path = mid, .output_path = "-", .opts = .{} },
    };
    const order = try buildJobOrderByFileSize(allocator, &jobs);
    defer allocator.free(order);

    try std.testing.expectEqual(@as(usize, 3), order.len);
    try std.testing.expectEqual(@as(usize, 1), order[0]);
    try std.testing.expectEqual(@as(usize, 2), order[1]);
    try std.testing.expectEqual(@as(usize, 0), order[2]);
}
