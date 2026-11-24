//!zsass embedding API. You can receive CSS by simply passing source from spec_runner or external embedder
//!memory-only compile entry point. driver.zig is only for CLI (file path input/output), and this file is
//!Does not have file I/O.
//!
//!Design intent:
//!- Consolidated spec_runner into a single fn so that it can be called in the same way as `compile` in legacy `src/compiler.zig`
//!- Also serves as a scaffold for future public embedding APIs (via `pub usingnamespace`)
//!
//!Relative resolution of @import starts from `file_path`. If `file_path` is empty, @import is an absolute path
//!or URL format only (relative paths will fail).

const std = @import("std");
const builtin = @import("builtin");
const compiler_mod = @import("ir/compiler.zig");
const rule_ir_mod = @import("ir/rule_ir.zig");
const source_map_mod = @import("ir/source_map.zig");
const vm_mod = @import("runtime/vm.zig");
const zsass_io = @import("runtime/io.zig");
const perf_mod = @import("runtime/perf.zig");
const embed_batch_mod = @import("runtime/embed_batch.zig");

comptime {
    //export symbol (`zsass_builtin_meta_dispatch`) of runtime/vm_meta.zig
    //import anchor to ensure linking to all build targets.
    _ = @import("runtime/vm_meta.zig");
}

/// Re-export the runtime I/O facility (`io`, `realPathAlloc`) so examples and
/// embedders can share the same threaded `std.Io` instance the compiler uses.
pub const io_facility = zsass_io;

/// CSS output style. Mirrors the CLI `--style` flag.
pub const OutputStyle = rule_ir_mod.OutputStyle;

/// Severity level associated with a `Diagnostic` reported through
/// `CompileOptions.diagnostic_sink`. `err` corresponds to compilation
/// failure (the same condition the API also surfaces via the returned
/// `anyerror`); `warning` covers `@warn` / lexer-level warnings;
/// `deprecation` is official Sass CLI-style deprecation notices.
pub const DiagnosticLevel = enum { warning, deprecation, err };

/// Structured per-event payload delivered to a `DiagnosticSink`. All
/// slices are valid for the duration of the callback only -- if the
/// caller needs them to outlive the call, it must `dupe` them.
pub const Diagnostic = struct {
    level: DiagnosticLevel,
    /// Human-readable English message (the same string the legacy fd
    /// sink would have written).
    message: []const u8,
    /// Stable identifier suitable for routing / suppression. May be
    /// `null` for events that do not yet have a code assigned.
    code: ?[]const u8 = null,
    /// Source location of the offending construct. Both 1-based.
    file: ?[]const u8 = null,
    line: ?u32 = null,
    column: ?u32 = null,
    end_line: ?u32 = null,
    end_column: ?u32 = null,
};

/// Receives a `Diagnostic` for every warning / deprecation / error the
/// compile pipeline raises. The optional `ctx` is forwarded verbatim
/// from `CompileOptions.diagnostic_ctx` so embedders can attach state
/// without going through globals.
pub const DiagnosticSink = *const fn (diag: *const Diagnostic, ctx: ?*anyopaque) void;

/// Per-call options shared by the in-memory compile entry points.
pub const CompileOptions = struct {
    /// `.expanded` (default, official Sass CLI `expanded`) or `.compressed`.
    output_style: OutputStyle = .expanded,
    /// Suppress `@warn` / `@debug` output (mirrors the CLI `--quiet`).
    quiet: bool = false,
    /// Optional callback invoked for every diagnostic the pipeline
    /// raises (warnings, deprecations, errors). When non-null this runs
    /// alongside -- not instead of -- the legacy fd sink configured via
    /// `setCompileErrorSinkFd`. Use `null` to opt out.
    diagnostic_sink: ?DiagnosticSink = null,
    /// Opaque pointer threaded back into every `diagnostic_sink` call.
    diagnostic_ctx: ?*anyopaque = null,
};

threadlocal var diagnostic_sink_tls: ?DiagnosticSink = null;
threadlocal var diagnostic_ctx_tls: ?*anyopaque = null;

/// Read the current thread-local diagnostic sink / context. Called from
/// the runtime when it needs to deliver a `Diagnostic` outside the API
/// helpers (e.g. inside `vm.zig` warning paths).
pub fn currentDiagnosticSink() ?DiagnosticSink {
    return diagnostic_sink_tls;
}
pub fn currentDiagnosticCtx() ?*anyopaque {
    return diagnostic_ctx_tls;
}

/// Snapshot of the thread-local sink/ctx pair returned by
/// `pushDiagnosticSink`. Pass it back to `restoreDiagnosticSink` so
/// callers above us see the same values they configured.
pub const DiagnosticSinkSnapshot = struct {
    sink: ?DiagnosticSink,
    ctx: ?*anyopaque,
};

/// Push the sink/ctx pair from `opts` onto the thread-local slots,
/// returning the previous values. Pair with `restoreDiagnosticSink`
/// using `defer` to keep the slot unchanged for callers above us.
pub fn pushDiagnosticSink(opts: CompileOptions) DiagnosticSinkSnapshot {
    const prev: DiagnosticSinkSnapshot = .{ .sink = diagnostic_sink_tls, .ctx = diagnostic_ctx_tls };
    diagnostic_sink_tls = opts.diagnostic_sink;
    diagnostic_ctx_tls = opts.diagnostic_ctx;
    return prev;
}

pub fn restoreDiagnosticSink(prev: DiagnosticSinkSnapshot) void {
    diagnostic_sink_tls = prev.sink;
    diagnostic_ctx_tls = prev.ctx;
}

/// Convenience helper for runtime layers that have already constructed
/// a `Diagnostic`. Returns silently if no sink is registered.
pub fn deliverDiagnostic(diag: *const Diagnostic) void {
    if (diagnostic_sink_tls) |sink| sink(diag, diagnostic_ctx_tls);
}

const error_format_mod = @import("runtime/error_format.zig");

/// Used by the public compile entry points: when the pipeline returns
/// an error, fan out a final `level = .err` diagnostic carrying the
/// caller-facing English message. Warnings / deprecations are delivered
/// by the runtime as they happen; this helper bridges the legacy
/// `anyerror` exit to the structured `DiagnosticSink`.
fn reportFinalErrorDiagnostic(err: anyerror, file_path: []const u8, opts: CompileOptions) void {
    const sink = opts.diagnostic_sink orelse return;
    const diag = Diagnostic{
        .level = .err,
        .message = error_format_mod.errorToUserMessageWithContext(err),
        .file = if (file_path.len > 0) file_path else null,
    };
    sink(&diag, opts.diagnostic_ctx);
}

/// Re-exports for the file-batch embedding API (see `embed_batch.zig`).
pub const CompileFileResult = embed_batch_mod.CompileFileResult;
pub const CompileFilesOptions = embed_batch_mod.CompileFilesOptions;
pub const compileFiles = embed_batch_mod.compileFiles;

/// Emit aggregated `perf` counters to stderr. Compiles to nothing unless
/// the build was configured with `-Dprofile=true`.
pub fn dumpProfile() void {
    if (comptime !perf_mod.enabled) return;
    var stderr_file = std.Io.File.stderr();
    var buf: [4096]u8 = undefined;
    var w = stderr_file.writer(zsass_io.io, buf[0..]);
    perf_mod.dumpAll(&w.interface) catch return;
    w.interface.flush() catch return;
}

/// Thread-local fd copied onto each `VM` at compile time (spec_runner fork child sets this to a pipe).
threadlocal var compile_error_sink_fd_tls: ?i32 = null;

/// Set TAGD sink for subsequent `compileSourceToCss*` calls on this thread (use `null` to disable).
pub fn setCompileErrorSinkFd(fd: ?i32) void {
    compile_error_sink_fd_tls = fd;
}

/// Current TAGD sink fd for this thread (used by driver when constructing a VM outside the API helpers).
pub fn compileErrorSinkFd() ?i32 {
    return compile_error_sink_fd_tls;
}

/// Result of `compileSourceToCssWithSourceMap`. Both slices are `alloc`-owned;
/// caller must `deinit(alloc)` to free them.
pub const CompileCssWithSourceMapResult = struct {
    /// Expanded CSS output.
    css: []u8,
    /// Source Map v3 JSON (UTF-8).
    source_map_json: []u8,

    pub fn deinit(self: *CompileCssWithSourceMapResult, allocator: std.mem.Allocator) void {
        allocator.free(self.css);
        allocator.free(self.source_map_json);
    }
};

/// SCSS source  ->  expanded CSS. The return value comes from `alloc` and caller `alloc.free`.
/// The compile itself runs in an arena on top of `alloc`, which is returned
/// when the call ends; only the result is copied out. An `alloc` that cannot
/// give memory back, such as another arena, keeps both until it is reset.
/// The error set returned is a union of parser / resolver / compiler / VM / writer.
/// If you need to grep them individually, use a separate wrapper.
///
/// `load_paths` is the user module resolution of `@use` / `@forward` / bare relative `@import`,
/// It is scanned in order when it is not found relative to dir of `file_path`. HRX included SCSS/sass-spec
/// Assuming a use where the embedder passes multiple roots such as `tmp_path` / `hrx_dir` / `base_path`. If empty
/// base_dir relative only (compatible with existing behavior).
pub fn compileSourceToCss(
    alloc: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    load_paths: []const []const u8,
    opts: CompileOptions,
) anyerror![]u8 {
    // The compiler keeps what it allocates for the whole compile and gives
    // it back in one go, as the CLI does. Values made along the way, such
    // as the lists built-in functions return, have no other owner.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    // Declared after the arena so it runs first: the message may point into
    // memory the compile allocated. It also covers the copy below.
    errdefer |err| reportFinalErrorDiagnostic(err, file_path, opts);
    const css = try compileSourceToCssInArena(arena.allocator(), source, file_path, load_paths, opts);
    return try alloc.dupe(u8, css);
}

fn compileSourceToCssInArena(
    alloc: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    load_paths: []const []const u8,
    opts: CompileOptions,
) anyerror![]u8 {
    error_format_mod.clearContextMessage();
    const prev_diag = pushDiagnosticSink(opts);
    defer restoreDiagnosticSink(prev_diag);
    var r = try compiler_mod.parseResolveCompileWithPath(alloc, source, file_path, load_paths);
    defer r.pool.deinit(alloc);
    defer r.color_pool.deinit(alloc);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = rule_ir_mod.RuleIR.init();
    defer rule_ir.deinit(alloc);

    var vm = try vm_mod.VM.init(alloc, &r.pool, &r.color_pool, &rule_ir, &r.program);
    vm.error_sink_fd = compile_error_sink_fd_tls;
    vm.deprecation_opts.quiet = opts.quiet or builtin.is_test;
    defer vm.deinit();

    try vm_mod.VM.runTop(&vm);

    const source_locations = try alloc.alloc(rule_ir_mod.SourceLocation, r.program.modules.len);
    defer alloc.free(source_locations);
    for (r.program.modules, 0..) |mod, idx| {
        source_locations[idx] = .{
            .source_path = mod.module_path,
            .line_starts = mod.line_starts,
            .source_len = mod.source_len,
        };
    }

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    try rule_ir.writeToWithSourceMap(&aw.writer, &r.pool, null, source_locations, opts.output_style, .{});
    return try aw.toOwnedSlice();
}

/// Same as `compileSourceToCss`, but also emits a Source Map v3 JSON side-by-side.
/// Returned struct owns both `css` and `source_map_json` slices; caller must
/// call `.deinit(alloc)` on the result.
pub fn compileSourceToCssWithSourceMap(
    alloc: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    load_paths: []const []const u8,
    /// When non-null, `sources` paths in the map use the same rules as the CLI (posix-relative to this file's directory).
    source_map_output_css_path: ?[]const u8,
    opts: CompileOptions,
) anyerror!CompileCssWithSourceMapResult {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    errdefer |err| reportFinalErrorDiagnostic(err, file_path, opts);
    const result = try compileSourceToCssWithSourceMapInArena(arena.allocator(), source, file_path, load_paths, source_map_output_css_path, opts);
    const css = try alloc.dupe(u8, result.css);
    errdefer alloc.free(css);
    return .{ .css = css, .source_map_json = try alloc.dupe(u8, result.source_map_json) };
}

fn compileSourceToCssWithSourceMapInArena(
    alloc: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    load_paths: []const []const u8,
    source_map_output_css_path: ?[]const u8,
    opts: CompileOptions,
) anyerror!CompileCssWithSourceMapResult {
    error_format_mod.clearContextMessage();
    const prev_diag = pushDiagnosticSink(opts);
    defer restoreDiagnosticSink(prev_diag);
    var r = try compiler_mod.parseResolveCompileWithPath(alloc, source, file_path, load_paths);
    defer r.pool.deinit(alloc);
    defer r.color_pool.deinit(alloc);
    defer r.resolved.deinit();
    defer r.program.deinit();

    var rule_ir = rule_ir_mod.RuleIR.init();
    defer rule_ir.deinit(alloc);

    var vm = try vm_mod.VM.init(alloc, &r.pool, &r.color_pool, &rule_ir, &r.program);
    vm.error_sink_fd = compile_error_sink_fd_tls;
    vm.deprecation_opts.quiet = opts.quiet or builtin.is_test;
    defer vm.deinit();

    try vm_mod.VM.runTop(&vm);

    const source_locations = try alloc.alloc(rule_ir_mod.SourceLocation, r.program.modules.len);
    defer alloc.free(source_locations);
    for (r.program.modules, 0..) |mod, idx| {
        source_locations[idx] = .{
            .source_path = mod.module_path,
            .line_starts = mod.line_starts,
            .source_len = mod.source_len,
        };
    }

    var sm = source_map_mod.SourceMap.init(alloc);
    defer sm.deinit();

    var sm_out_dir: ?[]const u8 = null;
    defer if (sm_out_dir) |d| alloc.free(d);
    if (source_map_output_css_path) |css_out| {
        const dir_raw = std.fs.path.dirname(css_out) orelse ".";
        sm_out_dir = zsass_io.realPathAlloc(std.Io.Dir.cwd(), dir_raw, alloc) catch null;
    }

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    try rule_ir.writeToWithSourceMap(&aw.writer, &r.pool, &sm, source_locations, opts.output_style, .{
        .source_map_output_dir_abs = sm_out_dir,
    });
    const css = try aw.toOwnedSlice();
    errdefer alloc.free(css);

    const source_map_json = try sm.toJsonAlloc(alloc);
    return .{
        .css = css,
        .source_map_json = source_map_json,
    };
}

fn expectCompileErrorOneOf(
    allocator: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    allowed: []const anyerror,
) !void {
    _ = compileSourceToCss(allocator, source, file_path, &.{}, .{}) catch |err| {
        for (allowed) |want| {
            if (err == want) return;
        }
        return err;
    };
    return error.TestUnexpectedResult;
}

test "api: compile trivial literal rule" {
    const alloc = std.testing.allocator;
    const src = ".a { color: red; }\n";
    const css = try compileSourceToCss(alloc, src, "", &.{}, .{});
    defer alloc.free(css);
    try std.testing.expectEqualStrings(".a {\n  color: red;\n}\n", css);
}

test "api: compile arithmetic" {
    const alloc = std.testing.allocator;
    const src = "$w: 10px;\n.a { width: $w * 2; }\n";
    const css = try compileSourceToCss(alloc, src, "", &.{}, .{});
    defer alloc.free(css);
    try std.testing.expectEqualStrings(".a {\n  width: 20px;\n}\n", css);
}

test "api: compile clears stale context message before final diagnostic" {
    const alloc = std.testing.allocator;

    const type_error_src = "@use \"sass:map\"; a { b: map.get(1, 2) }";
    _ = compileSourceToCss(alloc, type_error_src, "", &.{}, .{}) catch {};

    const Capture = struct {
        messages: std.ArrayList(u8) = .empty,

        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.messages.deinit(allocator);
        }

        fn sink(diag: *const Diagnostic, ctx: ?*anyopaque) void {
            if (diag.level != .err) return;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.messages.appendSlice(alloc, diag.message) catch {};
            self.messages.append(alloc, '\n') catch {};
        }
    };

    var capture = Capture{};
    defer capture.deinit(alloc);

    const unknown_function_src = "@use \"sass:map\"; a { b: map.map-get((c: d), c) }";
    _ = compileSourceToCss(alloc, unknown_function_src, "", &.{}, .{
        .diagnostic_sink = Capture.sink,
        .diagnostic_ctx = &capture,
    }) catch {};

    try std.testing.expect(std.mem.indexOf(u8, capture.messages.items, "Undefined function.") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.messages.items, "$map: 1 is not a map.") == null);
}

test "api: plain css import condition preserves raw condition text" {
    const alloc = std.testing.allocator;
    const src = "@import \"a\" b(c);\n";
    const css = try compileSourceToCss(alloc, src, "/tmp/in.scss", &.{}, .{});
    defer alloc.free(css);
    try std.testing.expectEqualStrings("@import \"a\" b(c);\n", css);
}

test "api: css special function strips silent comment indentation to one space" {
    const alloc = std.testing.allocator;
    const src =
        \\a {
        \\  b: element(//
        \\    c);
        \\}
    ;
    const css = try compileSourceToCss(alloc, src, "/tmp/in.scss", &.{}, .{});
    defer alloc.free(css);
    try std.testing.expectEqualStrings(
        \\a {
        \\  b: element( c);
        \\}
        \\
    , css);
}

test "api: interpolation body ignores comment text that looks like nested interpolation" {
    const alloc = std.testing.allocator;
    const src =
        \\a  {
        \\  content: "#{ a /*#{"}*/ }";
        \\}
    ;
    const css = try compileSourceToCss(alloc, src, "/tmp/in.scss", &.{}, .{});
    defer alloc.free(css);
    try std.testing.expectEqualStrings(
        \\a {
        \\  content: "a";
        \\}
        \\
    , css);
}

test "api: plain css selector accepts escaped ampersand literal" {
    const alloc = std.testing.allocator;
    const src =
        \\.\\[\\.component-button\\:hover_\\&\\]\\:u-opacity-100 { opacity: 1; }
    ;
    const css = try compileSourceToCss(alloc, src, "/tmp/in.scss", &.{}, .{});
    defer alloc.free(css);
    try std.testing.expectEqualStrings(
        \\.\\[\\.component-button\\:hover_\\&\\]\\:u-opacity-100 {
        \\  opacity: 1;
        \\}
        \\
    , css);
}

test "api: compile with source map" {
    // The `sources` JSON entry is asserted with a POSIX-style path
    // (`/tmp/in.scss`), but on Windows the source-map writer normalises
    // the entry path through `realpath`, which substitutes the working
    // drive prefix and switches to backslash separators. Source-map
    // emission itself works on Windows; the expectation on this test
    // is just POSIX-shaped, so skip rather than weakening the assertion.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const src = ".a { color: red; }\n";
    var out = try compileSourceToCssWithSourceMap(alloc, src, "/tmp/in.scss", &.{}, null, .{});
    defer out.deinit(alloc);

    try std.testing.expectEqualStrings(".a {\n  color: red;\n}\n", out.css);
    try std.testing.expect(std.mem.find(u8, out.source_map_json, "\"version\":3") != null);
    try std.testing.expect(std.mem.find(u8, out.source_map_json, "\"sources\":[\"/tmp/in.scss\"]") != null);
}

test "api: invalid @supports prelude errors" {
    const alloc = std.testing.allocator;
    const src = "@supports {@a}\n";
    try std.testing.expectError(error.SassError, compileSourceToCss(alloc, src, "/tmp/in.scss", &.{}, .{}));
}

test "api: invalid @supports negation errors" {
    const alloc = std.testing.allocator;
    const src = "@supports not {@a}\n";
    try std.testing.expectError(error.SassError, compileSourceToCss(alloc, src, "/tmp/in.scss", &.{}, .{}));
}

test "api: supports evaluates declaration operands" {
    const alloc = std.testing.allocator;
    const src =
        \\$x: 1;
        \\@supports (a: 1 + $x) { @d; }
    ;
    const css = try compileSourceToCss(alloc, src, "/tmp/in.scss", &.{}, .{});
    defer alloc.free(css);

    try std.testing.expectEqualStrings(
        \\@supports (a: 2) {
        \\  @d;
        \\}
        \\
    , css);
}

test "api: supports evaluates declaration arithmetic without variables" {
    const alloc = std.testing.allocator;
    const src = "@supports (a: 1 + 1) { @d; }\n";
    const css = try compileSourceToCss(alloc, src, "/tmp/in.scss", &.{}, .{});
    defer alloc.free(css);

    try std.testing.expectEqualStrings(
        \\@supports (a: 2) {
        \\  @d;
        \\}
        \\
    , css);
}

test "api: supports preserves calc while substituting variables" {
    const alloc = std.testing.allocator;
    const src =
        \\$x: 2;
        \\@supports (a: calc(1 + $x)) { @d; }
    ;
    const css = try compileSourceToCss(alloc, src, "/tmp/in.scss", &.{}, .{});
    defer alloc.free(css);

    try std.testing.expectEqualStrings(
        \\@supports (a: calc(1 + 2)) {
        \\  @d;
        \\}
        \\
    , css);
}

test "api: supports evaluates interpolated calc operands" {
    const alloc = std.testing.allocator;
    const src = "@supports (a: #{calc(1 + 2)}) { @d; }\n";
    const css = try compileSourceToCss(alloc, src, "/tmp/in.scss", &.{}, .{});
    defer alloc.free(css);

    try std.testing.expectEqualStrings(
        \\@supports (a: 3) {
        \\  @d;
        \\}
        \\
    , css);
}

test "api: supports unwraps redundant declaration parens" {
    const alloc = std.testing.allocator;
    const src = "@supports ((((a: b)))) { @c; }\n";
    const css = try compileSourceToCss(alloc, src, "/tmp/in.scss", &.{}, .{});
    defer alloc.free(css);

    try std.testing.expectEqualStrings(
        \\@supports (a: b) {
        \\  @c;
        \\}
        \\
    , css);
}

test "api: supports interpolation preserves declaration parens" {
    const alloc = std.testing.allocator;
    const src = "@supports (#{\"(a: b)\"}) { @c; }\n";
    const css = try compileSourceToCss(alloc, src, "/tmp/in.scss", &.{}, .{});
    defer alloc.free(css);

    try std.testing.expectEqualStrings(
        \\@supports ((a: b)) {
        \\  @c;
        \\}
        \\
    , css);
}

test "api: invalid @supports declaration lhs errors" {
    const alloc = std.testing.allocator;
    const src = "@supports (a b: c) { @c; }\n";
    try std.testing.expectError(error.SassError, compileSourceToCss(alloc, src, "/tmp/in.scss", &.{}, .{}));
}

test "api: invalid @supports declaration punctuation errors" {
    const alloc = std.testing.allocator;
    const src = "@supports (a !:$) { @c; }\n";
    try std.testing.expectError(error.SassError, compileSourceToCss(alloc, src, "/tmp/in.scss", &.{}, .{}));
}

test "api: invalid @supports empty custom property value errors" {
    const alloc = std.testing.allocator;
    const src = "@supports (--a:) { @c; }\n";
    try std.testing.expectError(error.SassError, compileSourceToCss(alloc, src, "/tmp/in.scss", &.{}, .{}));
}

test "api: supports rejects leaked indented continuations in sass" {
    const alloc = std.testing.allocator;
    const cases = [_][]const u8{
        \\@supports
        \\  (a: b)
        \\    c
        \\      d: e
        ,
        \\@supports #{"(a: b)"} 
        \\  and (c: d)
        \\    @d
        ,
        \\@supports #{"(a: b)"} and
        \\  (c: d)
        \\    @d
        ,
        \\@supports #{"(a: b)"} and (c: d) 
        \\  and (e: f)
        \\    @d
        ,
        \\@supports (a)
        \\ and (b)
        \\    c
        \\      d: e
        ,
        \\@supports (a) and
        \\  (b)
        \\    c
        \\      d: e
        ,
        \\@supports not
        \\ (a) 
        \\    b
        \\      c: d
        ,
    };

    for (cases) |src| {
        try expectCompileErrorOneOf(alloc, src, "/tmp/input.sass", &.{
            error.SassError,
            error.SyntaxError,
        });
    }
}

test "api: indented control-flow header does not consume child leading combinator" {
    const alloc = std.testing.allocator;
    const src =
        \\@mixin m
        \\  @for $i from 1 through 1
        \\    > .x
        \\      a: b
        \\.a
        \\  @include m
        \\
    ;
    const css = try compileSourceToCss(alloc, src, "/tmp/in.sass", &.{}, .{});
    defer alloc.free(css);

    try std.testing.expectEqualStrings(
        \\.a > .x {
        \\  a: b;
        \\}
        \\
    , css);
}

test "api: mixin import url interpolation errors for undeclared caller local variable" {
    const alloc = std.testing.allocator;
    const src =
        \\@use "sass:string";
        \\@mixin import-google-fonts() {
        \\  @import url("http://fonts.googleapis.com/css?family=#{$family}");
        \\}
        \\foo {
        \\  $family: string.unquote("Droid+Sans");
        \\  @include import-google-fonts();
        \\}
    ;
    try std.testing.expectError(error.SassError, compileSourceToCss(alloc, src, "/tmp/input.scss", &.{}, .{}));
}

fn writeApiTmpFileAll(tmp_dir: *std.testing.TmpDir, rel_path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(rel_path)) |parent| {
        try tmp_dir.dir.createDirPath(zsass_io.io, parent);
    }
    const file = try tmp_dir.dir.createFile(zsass_io.io, rel_path, .{ .truncate = true });
    defer file.close(zsass_io.io);
    var fb: [4096]u8 = undefined;
    var fw = file.writerStreaming(zsass_io.io, &fb);
    try fw.interface.writeAll(bytes);
    try fw.flush();
}

test "api: import-forwarded callables override prior local hyphen aliases" {
    const alloc = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeApiTmpFileAll(&tmp_dir, "_upstream.scss",
        \\@mixin foo_bar { .from { mixin: upstream; } }
        \\@function foo_bar() { @return upstream; }
    );
    try writeApiTmpFileAll(&tmp_dir, "_bridge.scss",
        \\@forward "upstream";
    );

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", alloc);
    defer alloc.free(tmp_path);
    const entry_path = try std.fs.path.join(alloc, &.{ tmp_path, "entry.scss" });
    defer alloc.free(entry_path);

    const src =
        \\@mixin foo-bar { .from { mixin: local; } }
        \\@function foo-bar() { @return local; }
        \\@import "bridge";
        \\.x {
        \\  @include foo_bar;
        \\  y: foo_bar();
        \\}
    ;
    const css = try compileSourceToCss(alloc, src, entry_path, &.{}, .{});
    defer alloc.free(css);

    try std.testing.expectEqualStrings(
        \\.x .from {
        \\  mixin: upstream;
        \\}
        \\.x {
        \\  y: upstream;
        \\}
        \\
    , css);
}

test "api: callable body can still read a global declared after the mixin" {
    const alloc = std.testing.allocator;
    const src =
        \\@mixin apply-gap() {
        \\  width: $theme-gap;
        \\}
        \\$theme-gap: 11px;
        \\.a {
        \\  @include apply-gap();
        \\}
    ;
    const css = try compileSourceToCss(alloc, src, "/tmp/input.scss", &.{}, .{});
    defer alloc.free(css);

    try std.testing.expectEqualStrings(
        \\.a {
        \\  width: 11px;
        \\}
        \\
    , css);
}

test "api: content block sees preceding global assignment in caller module" {
    const alloc = std.testing.allocator;
    const src =
        \\$x: null;
        \\@mixin outer($v) {
        \\  $x: $v !global;
        \\  @content;
        \\}
        \\@mixin inner($v: 2) {
        \\  @include outer($v) {
        \\    a { b: $x * 0.5; }
        \\  }
        \\}
        \\@include inner(4);
    ;
    const css = try compileSourceToCss(alloc, src, "/tmp/input.scss", &.{}, .{});
    defer alloc.free(css);

    try std.testing.expectEqualStrings(
        \\a {
        \\  b: 2;
        \\}
        \\
    , css);
}

test "api: missing namespace inside executed callable body errors at runtime" {
    const alloc = std.testing.allocator;
    const src =
        \\@mixin use-missing-namespace() {
        \\  a: list.join((a), (b));
        \\}
        \\.x {
        \\  @include use-missing-namespace();
        \\}
    ;
    try std.testing.expectError(error.SassError, compileSourceToCss(alloc, src, "/tmp/input.scss", &.{}, .{}));
}

test "api: @page declarations are valid inside @media" {
    const alloc = std.testing.allocator;
    const src = "@media print { @page { margin: 0.5cm; } }\n";
    const css = try compileSourceToCss(alloc, src, "/tmp/input.scss", &.{}, .{});
    defer alloc.free(css);

    try std.testing.expectEqualStrings(
        \\@media print {
        \\  @page {
        \\    margin: 0.5cm;
        \\  }
        \\}
        \\
    , css);
}

test "api: a forwarded !default configuration yields to the using module" {
    const alloc = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeApiTmpFileAll(&tmp_dir, "_lib.scss",
        \\$a: 1 !default;
        \\$b: 1 !default;
        \\@if $a == 1 { x { y: one; } } @else if $a == 2 { x { y: two; } } @else { x { y: other; } }
        \\@if $b == 1 { v { y: one; } } @else { v { y: other; } }
        \\z { a: $a; b: $b; }
    );
    try writeApiTmpFileAll(&tmp_dir, "_inner.scss",
        \\@forward "lib" with ($a: 1 !default);
    );
    try writeApiTmpFileAll(&tmp_dir, "_outer.scss",
        \\@forward "inner" with ($a: 7 !default);
    );

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", alloc);
    defer alloc.free(tmp_path);
    const entry_path = try std.fs.path.join(alloc, &.{ tmp_path, "entry.scss" });
    defer alloc.free(entry_path);

    // The using module overrides the forwarded default and configures a
    // variable the `@forward` does not mention.
    const overridden = try compileSourceToCss(alloc, "@use \"inner\" with ($a: 2, $b: 3);\n", entry_path, &.{}, .{});
    defer alloc.free(overridden);
    try std.testing.expectEqualStrings(
        \\x {
        \\  y: two;
        \\}
        \\
        \\v {
        \\  y: other;
        \\}
        \\
        \\z {
        \\  a: 2;
        \\  b: 3;
        \\}
        \\
    , overridden);

    // `null` leaves a default in place, from the using module and from an
    // outer `@forward`.
    try writeApiTmpFileAll(&tmp_dir, "_outer_null.scss",
        \\@forward "inner" with ($a: null !default);
    );
    inline for (.{ "@use \"inner\" with ($a: null);\n", "@use \"outer_null\";\n" }) |entry| {
        const with_null = try compileSourceToCss(alloc, entry, entry_path, &.{}, .{});
        defer alloc.free(with_null);
        try std.testing.expectEqualStrings(
            \\x {
            \\  y: one;
            \\}
            \\
            \\v {
            \\  y: one;
            \\}
            \\
            \\z {
            \\  a: 1;
            \\  b: 1;
            \\}
            \\
        , with_null);
    }

    // The outer `!default` takes precedence over the inner one.
    const chained = try compileSourceToCss(alloc, "@use \"outer\";\n", entry_path, &.{}, .{});
    defer alloc.free(chained);
    try std.testing.expectEqualStrings(
        \\x {
        \\  y: other;
        \\}
        \\
        \\v {
        \\  y: one;
        \\}
        \\
        \\z {
        \\  a: 7;
        \\  b: 1;
        \\}
        \\
    , chained);
}

test "api: string functions and equality use the text of a string as is" {
    const alloc = std.testing.allocator;
    const src =
        \\@use "sass:string";
        \\@use "sass:map";
        \\a {
        \\  length: string.length("\\61") string.length(a\.b);
        \\  upper: string.to-upper-case("\\61") string.to-upper-case(a\.b);
        \\  index: string.index("a\\b", "b");
        \\  slice: string.slice("\\61 b", 2);
        \\  equal: ("\\61" == "a") ("\61" == a);
        \\  key: map.get(("\\61": 1), "a") == null;
        \\  quote: string.quote(string.unquote("\\61"));
        \\  name: foo#{string.length("\\61")}(1);
        \\}
    ;
    const css = try compileSourceToCss(alloc, src, "", &.{}, .{});
    defer alloc.free(css);
    try std.testing.expectEqualStrings(
        \\a {
        \\  length: 3 4;
        \\  upper: "\\61" A\.B;
        \\  index: 3;
        \\  slice: "61 b";
        \\  equal: false true;
        \\  key: true;
        \\  quote: "\\61";
        \\  name: foo3(1);
        \\}
        \\
    , css);
}

test "api: a private-use character in a quoted string" {
    const alloc = std.testing.allocator;
    const src =
        \\@use "sass:string";
        \\$icon: \f00c;
        \\a {
        \\  spaced: "\f00c Done" "\f00c  x" "x\f00c y";
        \\  joined: "\f00c" + "Done";
        \\  interpolated: "#{$icon}" "#{$icon}Done";
        \\  appended: "" + $icon;
        \\  quoted: string.quote($icon);
        \\}
        \\@mixin m($i: \f00c, $s: "#{$i}Done") { b { default: $s string.length($s); } }
        \\@include m;
    ;
    const css = try compileSourceToCss(alloc, src, "", &.{}, .{});
    defer alloc.free(css);
    try std.testing.expectEqualStrings(
        \\a {
        \\  spaced: "\f00c Done" "\f00c  x" "x\f00cy";
        \\  joined: "\f00c Done";
        \\  interpolated: "\f00c" "\f00c Done";
        \\  appended: "\f00c";
        \\  quoted: "\f00c";
        \\}
        \\
        \\b {
        \\  default: "\f00c Done" 5;
        \\}
        \\
    , css);
}

test "api: identifier hyphens in math functions and decimals in url()" {
    const alloc = std.testing.allocator;
    const src =
        \\$v: var(--x);
        \\a {
        \\  ident: min(a-b) clamp(a-b, c-d, e-f) min(a\2d b);
        \\  spaced: min(a-b - c-d) min(a -b);
        \\  number: max(0px, (48px - $v) / 2);
        \\  url: url(a/.5.png) .5s;
        \\}
    ;
    const css = try compileSourceToCss(alloc, src, "", &.{}, .{});
    defer alloc.free(css);
    try std.testing.expectEqualStrings(
        \\a {
        \\  ident: min(a-b) clamp(a-b, c-d, e-f) min(a-b);
        \\  spaced: min(a-b - c-d) min(a -b);
        \\  number: max(0px, (48px - var(--x)) / 2);
        \\  url: url(a/.5.png) 0.5s;
        \\}
        \\
    , css);
}

test "api: meta.load-css() nested in a style rule or an at-rule" {
    const alloc = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeApiTmpFileAll(&tmp_dir, "_lib.scss",
        \\/* note */
        \\a { b: c; d { e: f; } }
        \\@keyframes z { from { g: h; } }
    );

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", alloc);
    defer alloc.free(tmp_path);
    const entry_path = try std.fs.path.join(alloc, &.{ tmp_path, "entry.scss" });
    defer alloc.free(entry_path);

    // Inside a style rule: no blank lines between the loaded rules, a
    // comment gets a rule of its own, and keyframe selectors stay as written.
    const in_rule = try compileSourceToCss(alloc,
        \\@use "sass:meta";
        \\.w { @include meta.load-css("lib"); }
        \\q { r: s; }
    , entry_path, &.{}, .{});
    defer alloc.free(in_rule);
    try std.testing.expectEqualStrings(
        \\.w {
        \\  /* note */
        \\}
        \\.w a {
        \\  b: c;
        \\}
        \\.w a d {
        \\  e: f;
        \\}
        \\@keyframes z {
        \\  from {
        \\    g: h;
        \\  }
        \\}
        \\
        \\q {
        \\  r: s;
        \\}
        \\
    , in_rule);

    const in_media = try compileSourceToCss(alloc,
        \\@use "sass:meta";
        \\@media screen { @include meta.load-css("lib"); }
    , entry_path, &.{}, .{});
    defer alloc.free(in_media);
    try std.testing.expectEqualStrings(
        \\@media screen {
        \\  /* note */
        \\  a {
        \\    b: c;
        \\  }
        \\  a d {
        \\    e: f;
        \\  }
        \\  @keyframes z {
        \\    from {
        \\      g: h;
        \\    }
        \\  }
        \\}
        \\
    , in_media);

    // At the top level every loaded rule is a top-level statement.
    const at_top = try compileSourceToCss(alloc,
        \\@use "sass:meta";
        \\@include meta.load-css("lib");
    , entry_path, &.{}, .{});
    defer alloc.free(at_top);
    try std.testing.expectEqualStrings(
        \\/* note */
        \\a {
        \\  b: c;
        \\}
        \\
        \\a d {
        \\  e: f;
        \\}
        \\
        \\@keyframes z {
        \\  from {
        \\    g: h;
        \\  }
        \\}
        \\
    , at_top);
}

test "api: escapes in selectors have one canonical spelling" {
    const alloc = std.testing.allocator;
    const src =
        \\.\61 b, #\61, \61, a:\68over, a:not(.\62) { x: y; }
        \\.\31 0, .sm\:w-1\/2, .a\2c b, .g\[1fr\2c 2fr\] { x: y; }
        \\[\61=b], [a="\62"], [a=\62], [a="\31 b"], a[href^="http\3a //"], [a="b\"c"] { x: y; }
        \\.\61 { x: y; }
        \\.c { @extend .a; }
    ;
    const css = try compileSourceToCss(alloc, src, "", &.{}, .{});
    defer alloc.free(css);
    try std.testing.expectEqualStrings(
        \\.ab, #a, a, a:hover, a:not(.b) {
        \\  x: y;
        \\}
        \\
        \\.\31 0, .sm\:w-1\/2, .a\,b, .g\[1fr\,2fr\] {
        \\  x: y;
        \\}
        \\
        \\[a=b], [a=b], [a=b], [a="1b"], a[href^="http://"], [a='b"c'] {
        \\  x: y;
        \\}
        \\
        \\.a, .c {
        \\  x: y;
        \\}
        \\
    , css);
}

test "api: an escape next to an interpolation in a function name" {
    const alloc = std.testing.allocator;
    const src =
        \\$x: 1;
        \\a {
        \\  literal: a\62#{1}(2) \31#{1}(2) a\.#{1}(2);
        \\  variable: a\62#{$x}(2) #{$x}\62 c(2);
        \\  operands: min(var(--a) var(--b)) min(1px + 1px + var(--c));
        \\}
    ;
    const css = try compileSourceToCss(alloc, src, "", &.{}, .{});
    defer alloc.free(css);
    try std.testing.expectEqualStrings(
        \\a {
        \\  literal: ab1(2) \31 1(2) a\.1(2);
        \\  variable: ab1(2) 1bc(2);
        \\  operands: min(var(--a) var(--b)) min(2px + var(--c));
        \\}
        \\
    , css);
}

test "api: a forwarded module is not configured through names the @forward hides" {
    const alloc = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeApiTmpFileAll(&tmp_dir, "_lib.scss",
        \\$a: 0 !default;
        \\$b: 0 !default;
        \\@if $a == 1 { x { a: one; } } @else { x { a: other; } }
        \\@if $b == 0 { x { b: zero; } } @else { x { b: other; } }
    );
    try writeApiTmpFileAll(&tmp_dir, "_hidden.scss",
        \\@forward "lib" hide $b with ($a: 1 !default);
        \\$b: 0 !default;
        \\z { b: $b; }
    );
    try writeApiTmpFileAll(&tmp_dir, "_prefixed.scss",
        \\@forward "lib" as p-*;
    );

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", alloc);
    defer alloc.free(tmp_path);
    const entry_path = try std.fs.path.join(alloc, &.{ tmp_path, "entry.scss" });
    defer alloc.free(entry_path);

    // `$b` configures the forwarding module's own variable, not the hidden
    // one of the forwarded module.
    const hidden = try compileSourceToCss(alloc, "@use \"hidden\" with ($b: 3);\n", entry_path, &.{}, .{});
    defer alloc.free(hidden);
    try std.testing.expectEqualStrings(
        \\x {
        \\  a: one;
        \\}
        \\
        \\x {
        \\  b: zero;
        \\}
        \\
        \\z {
        \\  b: 3;
        \\}
        \\
    , hidden);

    // Without `with`, a prefixed name still reaches the forwarded module.
    const prefixed = try compileSourceToCss(alloc, "@use \"prefixed\" with ($p-a: 1);\n", entry_path, &.{}, .{});
    defer alloc.free(prefixed);
    try std.testing.expectEqualStrings(
        \\x {
        \\  a: one;
        \\}
        \\
        \\x {
        \\  b: zero;
        \\}
        \\
    , prefixed);
}

test "api: meta.load-css() keeps @at-root and at-rule comments in place" {
    const alloc = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeApiTmpFileAll(&tmp_dir, "_root.scss",
        \\@at-root (without: media) { a { b: c; } }
    );
    try writeApiTmpFileAll(&tmp_dir, "_notes.scss",
        \\/* one */
        \\/* two */
        \\@font-face { /* face */ font-family: x; }
        \\@media print { /* print */ a { b: c; } }
        \\@notkeyframes k { a { b: c; } }
        \\@-webkit-keyframes k { from { b: c; } }
    );

    const tmp_path = try zsass_io.realPathAlloc(tmp_dir.dir, ".", alloc);
    defer alloc.free(tmp_path);
    const entry_path = try std.fs.path.join(alloc, &.{ tmp_path, "entry.scss" });
    defer alloc.free(entry_path);

    // `@at-root` cannot leave the block the module was loaded into.
    const in_media = try compileSourceToCss(alloc,
        \\@use "sass:meta";
        \\@media print { @include meta.load-css("root"); }
    , entry_path, &.{}, .{});
    defer alloc.free(in_media);
    try std.testing.expectEqualStrings(
        \\@media print {
        \\  a {
        \\    b: c;
        \\  }
        \\}
        \\
    , in_media);

    const in_rule = try compileSourceToCss(alloc,
        \\@use "sass:meta";
        \\.w { @include meta.load-css("notes"); }
    , entry_path, &.{}, .{});
    defer alloc.free(in_rule);
    try std.testing.expectEqualStrings(
        \\.w {
        \\  /* one */
        \\  /* two */
        \\}
        \\@font-face { /* face */
        \\  font-family: x;
        \\}
        \\@media print {
        \\  .w {
        \\    /* print */
        \\  }
        \\  .w a {
        \\    b: c;
        \\  }
        \\}
        \\@notkeyframes k {
        \\  .w a {
        \\    b: c;
        \\  }
        \\}
        \\@-webkit-keyframes k {
        \\  from {
        \\    b: c;
        \\  }
        \\}
        \\
    , in_rule);
}

test "api: a lone escaped hyphen stays escaped in a selector" {
    const alloc = std.testing.allocator;
    const css = try compileSourceToCss(alloc, ".\\-, .\\-a, .\\- .b, .\\-1 { x: y; }\n", "", &.{}, .{});
    defer alloc.free(css);
    try std.testing.expectEqualStrings(".\\2d , .-a, .\\2d  .b, .-\\31  {\n  x: y;\n}\n", css);
}

test "api: the space that ends a hex escape is kept apart from what follows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source =
        \\@use "sass:selector";
        \\.\31  .b, .\31 .c, .\31  > .d, .\31 /* x */ .e { x: y; }
        \\.\32  { & + & { x: y; } }
        \\.f { @extend .\31 ; }
        \\a {
        \\  b: \31  x;
        \\  --c: \31  x;
        \\  d: selector.append(".\\-", "a");
        \\}
        \\
    ;
    const css = try compileSourceToCss(alloc, source, "", &.{}, .{});
    try std.testing.expectEqualStrings(
        \\.\31  .b, .f .b, .\31 .c, .c.f, .\31  > .d, .f > .d, .\31  .e, .f .e {
        \\  x: y;
        \\}
        \\
        \\.\32  + .\32  {
        \\  x: y;
        \\}
        \\
        \\a {
        \\  b: \31  x;
        \\  --c: \31  x;
        \\  d: .-a;
        \\}
        \\
    , css);

    const compressed = try compileSourceToCss(alloc, ".\\31  .b, .\\31  + .c, .\\31  { x: y; }\n", "", &.{}, .{ .output_style = .compressed });
    try std.testing.expectEqualStrings(".\\31  .b,.\\31 +.c,.\\31 {x:y}\n", compressed);
}

test "api: compressed output keeps selector pseudo-class arguments and custom property lines apart" {
    const alloc = std.testing.allocator;
    const source =
        \\:is(.a, .b):not(.c, [d="e, f"]) :lang(en, fr) { g: h(i, j); }
        \\k { --l: m
        \\  n; }
        \\
    ;
    const css = try compileSourceToCss(alloc, source, "", &.{}, .{ .output_style = .compressed });
    defer alloc.free(css);
    try std.testing.expectEqualStrings(":is(.a,.b):not(.c,[d=\"e, f\"]) :lang(en, fr){g:h(i, j)}k{--l: m n}\n", css);
}

test "api: compressed output reads strings and parentheses when it looks for a statement" {
    const alloc = std.testing.allocator;
    const source =
        \\@supports selector([x=";"]:is(.a, .b)) { a { x: y; } }
        \\[x=";"]:is(.a, .b) { --c: "d;e" f
        \\  g; }
        \\
    ;
    const css = try compileSourceToCss(alloc, source, "", &.{}, .{ .output_style = .compressed });
    defer alloc.free(css);
    try std.testing.expectEqualStrings("@supports selector([x=\";\"]:is(.a, .b)){a{x:y}}[x=\";\"]:is(.a,.b){--c: \"d;e\" f g}\n", css);
}

test "api: compressed output follows the official CLI" {
    const cases = [_]struct { source: []const u8, css: []const u8 }{
        // A `/*!` comment stays, without the indentation of its block.
        .{
            .source =
            \\/*! a
            \\ * b */
            \\.x { b: c; /*! d */ }
            \\/* gone */
            \\@media screen { /*! e */ .y { f: g; } }
            \\
            ,
            .css = "/*! a\n * b */.x{b:c;/*! d */}@media screen{/*! e */.y{f:g}}\n",
        },
        // Only a media query list is shortened among at-rule preludes.
        .{
            .source =
            \\@import "b.css" screen and (min-width: 10px);
            \\@layer a, b;
            \\@media (width >= 64rem) and (height < 3px), print { a { b: c; } }
            \\@supports (a: b) or (c: d) { a { b: c; } }
            \\@container sidebar (min-width: 400px) and (max-width: 700px) { a { b: c; } }
            \\a:nth-of-type(10n + 1) > b { c: d; }
            \\@font-face { font-family: x; }
            \\
            ,
            .css = "@import\"b.css\"screen and (min-width: 10px);@layer a, b;@media(width >= 64rem)and (height < 3px),print{a{b:c}}@supports(a: b) or (c: d){a{b:c}}@container sidebar (min-width: 400px) and (max-width: 700px){a{b:c}}a:nth-of-type(10n + 1)>b{c:d}@font-face{font-family:x}\n",
        },
        // A value that is one interpolation stays as written in front of
        // nested properties and after a name made by interpolation.
        .{
            .source =
            \\$color: white;
            \\$v: calc(0.5px + 1%);
            \\a {
            \\  b: #{$color} { c: 1px; }
            \\  #{"d"}: #{$v};
            \\}
            \\
            ,
            .css = "a{b:white;b-c:1px;d:calc(0.5px + 1%)}\n",
        },
        // A value that is one interpolation stays as written whatever it
        // holds, and a brace in a comment does not end the interpolation.
        .{
            .source =
            \\$v: 1px, 2px;
            \\a {
            \\  b: #{$v};
            \\  c: #{white};
            \\  d: #{/* } */ 0.5em};
            \\  e: #{url(http://a/b), white};
            \\  f: (#{"0.5em"});
            \\}
            \\
            ,
            .css = "a{b:1px, 2px;c:white;d:0.5em;e:url(http://a/b), white;f:0.5em}\n",
        },
        // The space that ends an escape stays in an import URL.
        .{
            .source = "@import url(a\\ );\n@import url(  b.css  );\n",
            .css = "@import\"a\\ \";@import\"b.css\"\n",
        },
        // Comments on one line, and a comment in a custom property whose
        // name came from interpolation.
        .{
            .source =
            \\@use "sass:string";
            \\@function s($v) { @return string.unquote("#{$v}"); }
            \\x {
            \\  /*! c */ /*! d */
            \\  y: s(0.5rem);
            \\}
            \\a { #{"--x"}: #{"a/*keep*/b"}; }
            \\
            ,
            .css = "x{/*! c *//*! d */y:0.5rem}a{--x:a/*keep*/b}\n",
        },
        // A color is written in the shorter of its forms, whichever it had.
        .{
            .source =
            \\@use "sass:color";
            \\a {
            \\  b: hsl(40, 70%, 30%);
            \\  c: rgb(15%, 15%, 15%);
            \\  d: color.adjust(#abc, $lightness: -7%);
            \\  e: rgba(204, 204, 204, 0.5);
            \\  f: rgba(255, 255, 255, 0.2);
            \\  g: hsl(0, 0%, 100%);
            \\  h: hsla(24, 20%, 50%, 0.08);
            \\  i: 1px solid white;
            \\}
            \\
            ,
            .css = "a{b:rgb(51%,37%,9%);c:hsl(0,0%,15%);d:hsl(210,25%,66.3333333333%);e:hsla(0,0%,80%,.5);f:rgba(255,255,255,.2);g:#fff;h:rgba(60%,48%,40%,.08);i:1px solid #fff}\n",
        },
        // The arguments of a function stay as they are, except in a
        // calculation.
        .{
            .source =
            \\$w: white;
            \\a {
            \\  b: linear-gradient(to right, $w, transparent 0.5%);
            \\  c: translate3d(calc(var(--x) * -2), 0, 0.5px);
            \\  d: calc(0.375em - var(--w, 0.5em) * 2);
            \\  e: clamp(0.5px, 0.5vw + 1px, 2px);
            \\  f: rgb(var(--x), 0.1);
            \\  g: max(0.5px, 0.25px, var(--x));
            \\}
            \\
            ,
            .css = "a{b:linear-gradient(to right, white, transparent 0.5%);c:translate3d(calc(var(--x) * -2), 0, 0.5px);d:calc(.375em - var(--w, 0.5em)*2);e:clamp(.5px,.5vw + 1px,2px);f:rgb(var(--x), 0.1);g:max(.5px,.25px,var(--x))}\n",
        },
        // A value that is a string stays as it is, and a custom property
        // whose name comes from an interpolation is an ordinary declaration.
        .{
            .source =
            \\@use "sass:string";
            \\@function s($v) { @return string.unquote("#{$v}"); }
            \\@mixin v($name, $value) { #{"--" + $name}: #{$value}; }
            \\a {
            \\  b: s(0.875rem);
            \\  d: url(#{"x"}) 0.5em;
            \\  @include v(e, var(--f));
            \\  @include v(g, 0.5em transparent);
            \\  --h: 0.5em;
            \\  #{"--i"}: 0.5em, white;
            \\}
            \\
            ,
            .css = "a{b:0.875rem;d:url(x) .5em;--e:var(--f);--g:0.5em transparent;--h: 0.5em;--i:.5em,#fff}\n",
        },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const css = try compileSourceToCss(arena.allocator(), case.source, "", &.{}, .{ .output_style = .compressed });
        try std.testing.expectEqualStrings(case.css, css);
    }
}

test "api: compressed output writes a token the way its value says" {
    const cases = [_]struct { source: []const u8, path: []const u8 = "", css: []const u8 }{
        // A number that was rounded to be written loses its zero after a
        // minus sign too; one with ten decimals as they are keeps it. A
        // string in a list is written as it is, and a color in its
        // shortest form, worked out before its channels are rounded.
        .{
            .source =
            \\@use "sass:color";
            \\@function shadow($n) {
            \\  $val: 0px 0px transparent;
            \\  @for $i from 1 through $n {
            \\    $val: #{$val}, #{$i * 0.5}px #aaa;
            \\  }
            \\  @return $val;
            \\}
            \\a {
            \\  b: (0.3 - 0.375) * 1em 0.0333333333em -0.5em;
            \\  c: (0.3 - 0.375) * 1em;
            \\  d: 0.5 + rem 0.5rem;
            \\  e: shadow(2);
            \\  f: 1px solid color.mix(#6f42c1, white, 20.3%);
            \\  g: color.adjust(#26a69a, $lightness: 54.5%);
            \\  h: center / 0.4rem 0.5rem, 0.5 / 0.4, 0.5em/1foo-bar;
            \\  i: 0.5rem (0.5 + rem), -0.075em (0.3 - 0.375) * 1em;
            \\}
            \\
            ,
            .css = "a{b:-.075em 0.0333333333em -0.5em;c:-.075em;d:0.5rem .5rem;e:0px 0px transparent, 0.5px #aaa,1px #aaa;f:1px solid rgb(88.5364705882%,84.9541176471%,95.0643137255%);g:hsl(174.375,62.7450980392%,94.5%);h:center/0.4rem .5rem,.5/.4,.5em/1foo-bar;i:.5rem 0.5rem,-0.075em -.075em}\n",
        },
        // In a calculation kept in a variable, a number an interpolation
        // put there keeps its zero and one written beside it does not. A
        // string that reads as a comment is text.
        .{
            .source =
            \\$a: 0.375rem;
            \\$w: var(--w);
            \\@function add($x, $y) {
            \\  @return calc(#{$x} + #{$y});
            \\}
            \\$t: calc(
            \\  #{$a} - 1px -
            \\    #{$w} * 0.25
            \\);
            \\a {
            \\  b: add($a, $w);
            \\  c: add($a, 0.5px) 0.5em;
            \\  d: $t 0.75rem;
            \\  e: calc(#{$w} * 0.75);
            \\  e2: calc(#{"var(--x)"} * 0.5) calc(0.1234567891px + #{0.5});
            \\  f: var(--x, "/") #{"/* rtl:"} var(--y) #{"*/"};
            \\  g: #{"/* x */"};
            \\  #{"--h"}: #{0.5em} 0.5em, 0.5em;
            \\}
            \\
            ,
            .css = "a{b:calc(0.375rem + var(--w));c:calc(0.375rem + 0.5px) .5em;d:calc(0.375rem - 1px - var(--w)*.25) .75rem;e:calc(var(--w)*.75);e2:calc(var(--x)*.5) calc(0.1234567891px + 0.5);f:var(--x, \"/\") /* rtl: var(--y) */;g:/* x */;--h:0.5em .5em,.5em}\n",
        },
        // A string and the arguments of a function that is not a
        // calculation are left alone inside one. An item in brackets is
        // told apart from a string that reads the same.
        .{
            .source =
            \\$c: calc(#{"var(--w)"} * 0.5 + var(--x, "\\0.5", 0.5px));
            \\a {
            \\  b: $c;
            \\  c: [0.5 0.3] unquote("0.5"), 0.5em/1\26, [0.5/2];
            \\}
            \\
            ,
            .css = "a{b:calc(var(--w)*.5 + var(--x, \"\\\\0.5\", 0.5px));c:[.5 .3] 0.5,.5em/1\\&,[.5/2]}\n",
        },
        // A comment kept as text is copied whole, a color is told apart
        // from a string that reads the same, and the spaces of a string
        // inside a calculation do not hide it from its override.
        .{
            .source =
            \\$c: calc(#{0.5px} + var(--x, "a  b") * 0.25);
            \\a {
            \\  b: #{"/* ( */"};
            \\  c: 0.5em rgba(0, 0, 0, 0.5) unquote("rgba(0, 0, 0, 0.5)");
            \\  c2: white unquote("white") transparent unquote("transparent");
            \\  d: $c;
            \\}
            \\
            ,
            .css = "a{b:/* ( */;c:.5em rgba(0,0,0,.5) rgba(0, 0, 0, 0.5);c2:#fff white rgba(0,0,0,0) transparent;d:calc(0.5px + var(--x, \"a  b\")*.25)}\n",
        },
        // A string given to a calculation function is written as it is,
        // and so is what an interpolation put into a calculation written
        // in the declaration itself, whatever parentheses and spaces the
        // declaration ends up with.
        .{
            .source =
            \\$a: 0.375rem;
            \\$s: #{0.875}rem;
            \\@mixin c($w) {
            \\  left: calc(50% - (#{$w} * 0.5));
            \\}
            \\a {
            \\  b: clamp(13px, $s, 22px) min($s, 0.5px);
            \\  c: calc(#{$a}*2 + 0.5px);
            \\  d: calc(0.5px + #{$a}) 0.5em;
            \\  e: clamp(0.5px, 0.5vw + 1px, 2px);
            \\  @include c(1em);
            \\}
            \\
            ,
            .css = "a{b:clamp(13px,0.875rem,22px) min(0.875rem,.5px);c:calc(0.375rem*2 + .5px);d:calc(.5px + 0.375rem) .5em;e:clamp(.5px,.5vw + 1px,2px);left:calc(50% - 1em*.5)}\n",
        },
        // In plain CSS a hex color with an alpha channel is a color, an
        // `rgba()` of the stylesheet is not, and a number with ten
        // decimals keeps its zero.
        .{
            .source =
            \\a {
            \\  b: #00000040 #abcd;
            \\  c: 0.1428571429em 0.142857142em;
            \\  d: rgba(0, 0, 0, 0.25) white;
            \\}
            \\
            ,
            .path = "plain.css",
            .css = "a{b:rgba(0,0,0,.2509803922) rgba(170,187,204,.8666666667);c:0.1428571429em .142857142em;d:rgba(0, 0, 0, 0.25) white}\n",
        },
    };
    const alloc = std.testing.allocator;
    for (cases) |case| {
        const css = try compileSourceToCss(alloc, case.source, case.path, &.{}, .{ .output_style = .compressed });
        defer alloc.free(css);
        try std.testing.expectEqualStrings(case.css, css);
        // Expanded output never shows what is passed along for it.
        const expanded = try compileSourceToCss(alloc, case.source, case.path, &.{}, .{});
        defer alloc.free(expanded);
        try std.testing.expect(std.mem.indexOfAny(u8, expanded, &.{ 0x01, 0x02, 0x03, 0x04 }) == null);
    }
}

test "api: compressed output keeps a comment that is text" {
    const alloc = std.testing.allocator;
    const source =
        \\a {
        \\  --b: c
        \\    /*d*/e;
        \\  f: "g /* h */ i" /* j */ k;
        \\  --o: p /*{};("*/ white, q;
        \\  --r: url(s;t) /* {u}
        \\    v */ w\/*x;
        \\  --y: z\;
        \\    1 /*{*/ + 2;
        \\}
        \\l { m: url(#{"n;o"}) 0.5em; }
        \\
    ;
    const css = try compileSourceToCss(alloc, source, "", &.{}, .{ .output_style = .compressed });
    defer alloc.free(css);
    try std.testing.expectEqualStrings("a{--b: c /*d*/e;f:\"g /* h */ i\" k;--o: p /*{};(\"*/ white, q;--r: url(s;t) /* {u} v */ w\\/*x;--y: z\\; 1 /*{*/ + 2}l{m:url(n;o) .5em}\n", css);
}

test "api: compressed output leaves string contents alone and resets after an empty rule" {
    const alloc = std.testing.allocator;
    const source =
        \\a { b: "c {" "d ;}" ";}"; }
        \\e { /* f */ }
        \\:is(.g, .h) { i: j; }
        \\k { l: m\; }
        \\n { o: url(p;}) }
        \\
    ;
    const css = try compileSourceToCss(alloc, source, "", &.{}, .{ .output_style = .compressed });
    defer alloc.free(css);
    try std.testing.expectEqualStrings("a{b:\"c {\" \"d ;}\" \";}\"}:is(.g,.h){i:j}k{l:m\\;}n{o:url(p;})}\n", css);
}

test "api: a hex escape gets its space only where a selector name ends" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source =
        \\@use "sass:selector";
        \\:lang(\31), :not(.\31 ), :is(:lang(\32), .\33 ) { x: selector.append(".a\\20 "); }
        \\
    ;
    const css = try compileSourceToCss(alloc, source, "", &.{}, .{});
    try std.testing.expectEqualStrings(":lang(\\31), :not(.\\31 ), :is(:lang(\\32), .\\33 ) {\n  x: .a\\ ;\n}\n", css);
}

test "api: selector.nest returns a selector list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source =
        \\@use "sass:selector";
        \\@use "sass:meta";
        \\a { b: meta.type-of(selector.nest(".c", ".d")); e: meta.inspect(selector.nest(".c", ".d")); }
        \\
    ;
    const css = try compileSourceToCss(alloc, source, "", &.{}, .{});
    try std.testing.expectEqualStrings("a {\n  b: list;\n  e: (.c .d,);\n}\n", css);
}

test "api: compressed output drops an empty rule without its enclosing block" {
    const alloc = std.testing.allocator;
    const src =
        \\@media print { .w { /* x */ } .w a { b: c; } }
        \\@media print { a { b: c; } d { } }
        \\e { f: g; h { } }
        \\[style*="display: none;"] { /* x */ }
        \\[data-x="a{b"] { }
        \\.i\;j { }
        \\k { l: url(a;b); n: o; }
        \\@supports (content: "a;b") { .w { /* x */ } }
    ;
    const css = try compileSourceToCss(alloc, src, "", &.{}, .{ .output_style = .compressed });
    defer alloc.free(css);
    try std.testing.expectEqualStrings("@media print{.w a{b:c}}@media print{a{b:c}}e{f:g}k{l:url(a;b);n:o}\n", css);
}

test "api: numbers written with a slash follow the parentheses the official CLI sees" {
    const alloc = std.testing.allocator;
    // Inside parentheses `1/2` is a division; a call and brackets pass
    // that on. The second item of a space-separated list ends it for the
    // rest of the parentheses, and the list is read again from its first
    // item when that item was simple.
    const source =
        \\a {
        \\  b: foo(1/2/x) (foo(1/2/x)) (foo(1/2/x) b);
        \\  c: (a 1/2/x) (1/2/x a) (1/2/x a 1/2/y);
        \\  d: (1/2/x foo(1/2/y)) (1+2 foo(1/2/y));
        \\  e: (a (1/2/x)) (a (b 1/2/x)) ((a 1/2/x) 1/2/y);
        \\  f: [1/2/x] ([1/2/x]) (a [1/2/x]);
        \\  g: (a b, 1/2/x) (1/2/x, 1/2/y);
        \\  h: (nth(1/2/x 1, 1) b) (if(true, 1/2/x, 0) b);
        \\  i: (1/2/x, foo(1/2/y) b) (1/x foo(1/2/y));
        \\  j: (a), 1/2/x;
        \\}
        \\
    ;
    const css = try compileSourceToCss(alloc, source, "", &.{}, .{ .quiet = true });
    defer alloc.free(css);
    try std.testing.expectEqualStrings(
        \\a {
        \\  b: foo(1/2/x) foo(0.5/x) foo(1/2/x) b;
        \\  c: a 1/2/x 0.5/x a 0.5/x a 1/2/y;
        \\  d: 0.5/x foo(0.5/y) 3 foo(0.5/y);
        \\  e: a 0.5/x a b 1/2/x a 1/2/x 1/2/y;
        \\  f: [1/2/x] [0.5/x] a [1/2/x];
        \\  g: a b, 1/2/x 0.5/x, 0.5/y;
        \\  h: 0.5/x b 1/2/x b;
        \\  i: 0.5/x, foo(1/2/y) b 1/x foo(1/2/y);
        \\  j: a, 1/2/x;
        \\}
        \\
    , css);
}

test "api: nested lists in parentheses are followed once each" {
    const alloc = std.testing.allocator;
    // Every level is read again when its second item comes; what is
    // nested in it is not followed anew each time.
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(alloc);
    try source.appendSlice(alloc, "a {b: ");
    try source.appendNTimes(alloc, '(', 40);
    try source.appendSlice(alloc, "foo(1/2/x)");
    for (0..40) |_| try source.appendSlice(alloc, " b)");
    try source.appendSlice(alloc, "}\n");
    const css = try compileSourceToCss(alloc, source.items, "", &.{}, .{ .quiet = true });
    defer alloc.free(css);
    try std.testing.expect(std.mem.startsWith(u8, css, "a {\n  b: foo(1/2/x) b b"));
}

test "api: numbers written with a slash stay that text in front of something else" {
    const alloc = std.testing.allocator;
    // Outside parentheses `1/2` is still `1/2` when what it is divided by
    // is not a number. In parentheses, on the right of an operator, and
    // through a variable it is 0.5.
    const source =
        \\@use "sass:map";
        \\@function f() {
        \\  @return 1/2/x;
        \\}
        \\@mixin m($a) {
        \\  m: $a;
        \\}
        \\$v: 1/2;
        \\a {
        \\  b: 1 / 2 / auto;
        \\  c: 1/2/3/x 1px/2px/"y", -1/2/x;
        \\  d: 1.0/2.50/x 6/3/x/2/4;
        \\  e: (1/2/x) (1/2)/x $v/x;
        \\  f: (1/2/x, 1/2/y) foo((1/2/x));
        \\  g: f() [1/2/x] 1/2/x + y;
        \\  h: map.get((k: 1/2/x), k) y + 1/2/x;
        \\  i: 1/2/3 1/2 + x "0.5/x" == 1/2/x;
        \\  @include m(1/2/x);
        \\}
        \\@if 1/2/x == "1/2/x" {
        \\  j {
        \\    k: l;
        \\  }
        \\}
        \\@if 1/2/"x" == '1/2/"x"' {
        \\  m {
        \\    n: 1/2/"x";
        \\  }
        \\}
        \\
    ;
    const css = try compileSourceToCss(alloc, source, "", &.{}, .{ .quiet = true });
    defer alloc.free(css);
    try std.testing.expectEqualStrings(
        \\a {
        \\  b: 1/2/auto;
        \\  c: 1/2/3/x 1px/2px/"y", -1/2/x;
        \\  d: 1/2.5/x 6/3/x/2/4;
        \\  e: 0.5/x 0.5/x 0.5/x;
        \\  f: 0.5/x, 0.5/y foo(0.5/x);
        \\  g: 1/2/x [1/2/x] 1/2/xy;
        \\  h: 0.5/x y0.5/x;
        \\  i: 1/2/3 0.5x true;
        \\  m: 1/2/x;
        \\}
        \\
        \\j {
        \\  k: l;
        \\}
        \\
        \\m {
        \\  n: 1/2/"x";
        \\}
        \\
    , css);
}

test "api: lists made by built-in functions are freed" {
    // `std.testing.allocator` reports what is still allocated at the end.
    const alloc = std.testing.allocator;
    const source =
        \\@use "sass:list";
        \\@use "sass:map";
        \\@use "sass:selector";
        \\@use "sass:string";
        \\@use "sass:color";
        \\$m: map.merge((a: 1), (b: 2));
        \\a {
        \\  b: list.append(1 2, 3);
        \\  c: list.join(1 2, 3 4);
        \\  d: list.zip(1 2, 3 4);
        \\  e: map.keys($m);
        \\  f: map.values(map.remove($m, a));
        \\  g: selector.nest(".a", ".b");
        \\  h: selector.parse(".a .b, .c");
        \\  i: string.split("a b", " ");
        \\  j: list.set-nth(1 2 3, 2, 4);
        \\  k: list.slash(1, 2);
        \\  l: color.to-space(#abc, hsl);
        \\}
        \\
    ;
    const css = try compileSourceToCss(alloc, source, "", &.{}, .{});
    defer alloc.free(css);
    try std.testing.expect(std.mem.indexOf(u8, css, "b: 1 2 3;") != null);

    var mapped = try compileSourceToCssWithSourceMap(alloc, source, "", &.{}, null, .{});
    defer mapped.deinit(alloc);
    try std.testing.expectEqualStrings(css, mapped.css);
}

test "api: a failed copy of the result is reported as an error diagnostic" {
    const Counter = struct {
        fn sink(diag: *const Diagnostic, ctx: ?*anyopaque) void {
            const errors: *usize = @ptrCast(@alignCast(ctx.?));
            if (diag.level == .err) errors.* += 1;
        }
    };
    const source = "a { b: c; }\n";

    // The copy handed back to the caller is the last allocation of a
    // compile, so failing that one leaves the compile itself intact.
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const css = try compileSourceToCss(counting.allocator(), source, "", &.{}, .{});
    counting.allocator().free(css);
    const map_start = counting.alloc_index;
    const mapped = try compileSourceToCssWithSourceMap(counting.allocator(), source, "", &.{}, null, .{});
    const map_allocs = counting.alloc_index - map_start;
    counting.allocator().free(mapped.css);
    counting.allocator().free(mapped.source_map_json);

    var errors: usize = 0;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = map_start - 1 });
    try std.testing.expectError(error.OutOfMemory, compileSourceToCss(failing.allocator(), source, "", &.{}, .{
        .diagnostic_sink = Counter.sink,
        .diagnostic_ctx = &errors,
    }));
    try std.testing.expectEqual(@as(usize, 1), errors);

    // The CSS copy and the source map copy are the last two allocations.
    for ([_]usize{ map_allocs - 2, map_allocs - 1 }) |fail_index| {
        errors = 0;
        var failing_map = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, compileSourceToCssWithSourceMap(failing_map.allocator(), source, "", &.{}, null, .{
            .diagnostic_sink = Counter.sink,
            .diagnostic_ctx = &errors,
        }));
        try std.testing.expectEqual(@as(usize, 1), errors);
    }
}

test "api: @extend covers every combination of a repeated target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source =
        \\@use "sass:selector";
        \\.a + .a { x: y; }
        \\.b .c .b { x: y; }
        \\%p > %p { x: y; }
        \\.f { @extend .a; }
        \\.g { @extend .b; }
        \\.h { @extend .c; }
        \\.i, .j { @extend %p; }
        \\k {
        \\  l: selector.extend(".m .m", ".m", ".n .o");
        \\  p: selector.replace(".m .m", ".m", ".n");
        \\}
        \\
    ;
    const css = try compileSourceToCss(alloc, source, "", &.{}, .{});
    try std.testing.expectEqualStrings(
        \\.a + .a, .f + .a, .a + .f, .f + .f {
        \\  x: y;
        \\}
        \\
        \\.b .c .b, .b .h .b, .g .c .b, .g .h .b, .b .c .g, .b .h .g, .g .c .g, .g .h .g {
        \\  x: y;
        \\}
        \\
        \\.i > .i, .j > .i, .i > .j, .j > .j {
        \\  x: y;
        \\}
        \\
        \\k {
        \\  l: .m .m, .n .o .m, .m .n .o, .n .m .o, .n .o .o;
        \\  p: .n .n;
        \\}
        \\
    , css);
}

test "api: a repeated @extend target leaves out covered extenders and keeps sibling combinators" {
    const alloc = std.testing.allocator;
    const source =
        \\.a .a { x: y; }
        \\.b .b { x: y; }
        \\.c .c { x: y; }
        \\.q .f, .f { @extend .a; }
        \\.g + .h { @extend .b; }
        \\.i, #j.i { @extend .c; }
        \\
    ;
    const css = try compileSourceToCss(alloc, source, "", &.{}, .{});
    defer alloc.free(css);
    try std.testing.expectEqualStrings(
        \\.a .a, .f .a, .a .f, .f .f {
        \\  x: y;
        \\}
        \\
        \\.b .b, .g + .h .b, .b .g + .h, .g + .h .g + .h {
        \\  x: y;
        \\}
        \\
        \\.c .c, .i .c, #j.i .c, .c .i, .i .i, #j.i .i, .c #j.i, .i #j.i {
        \\  x: y;
        \\}
        \\
    , css);
}

test "api: a repeated @extend target leaves out results another result covers" {
    const alloc = std.testing.allocator;
    const source =
        \\.a .a { x: y; }
        \\.f:hover, .g .f { @extend .a; }
        \\
    ;
    const css = try compileSourceToCss(alloc, source, "", &.{}, .{});
    defer alloc.free(css);
    // `.g .f .f:hover` and `.g .f:hover .f` are covered by `.g .f .f`.
    try std.testing.expectEqualStrings(
        \\.a .a, .f:hover .a, .g .f .a, .a .f:hover, .f:hover .f:hover, .a .g .f, .g .a .f, .f:hover .g .f, .g .f .f {
        \\  x: y;
        \\}
        \\
    , css);
}

test "api: a covered @extend result is judged by the extensions applied to it" {
    const alloc = std.testing.allocator;
    // `#q` comes with a later rule, so it does not keep `.g .f .f:hover`.
    const source =
        \\.a .a { x: y; }
        \\.f:hover, .g .f { @extend .a; }
        \\#q { @extend .a; }
        \\
    ;
    const css = try compileSourceToCss(alloc, source, "", &.{}, .{});
    defer alloc.free(css);
    try std.testing.expectEqualStrings(
        \\.a .a, #q .a, .a #q, #q #q, .f:hover .a, .f:hover #q, .g .f .a, .g .f #q, .a .f:hover, #q .f:hover, .f:hover .f:hover, .a .g .f, #q .g .f, .g .a .f, .g #q .f, .f:hover .g .f, .g .f .f {
        \\  x: y;
        \\}
        \\
    , css);
}

test "api: covered @extend results are left out after each extension" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { source: []const u8, selectors: usize, covered_kept: bool }{
        // One extension, 109 results: too many to compare.
        .{
            .source =
            \\.a .a { x: y; }
            \\.f:hover, .g .f, .h1, .h2, .h3, .h4, .h5, .h6, .h7 { @extend .a; }
            \\
            ,
            .selectors = 109,
            .covered_kept = true,
        },
        // The first extension makes 9 results and loses two of them.
        .{
            .source =
            \\.a .a { x: y; }
            \\.f:hover, .g .f { @extend .a; }
            \\.h1, .h2, .h3, .h4, .h5, .h6, .h7 { @extend .a; }
            \\
            ,
            .selectors = 107,
            .covered_kept = false,
        },
        // The second extension brings the list to 109 results.
        .{
            .source =
            \\.a .a { x: y; }
            \\.h1, .h2, .h3, .h4, .h5, .h6, .h7 { @extend .a; }
            \\.f:hover, .g .f { @extend .a; }
            \\
            ,
            .selectors = 109,
            .covered_kept = true,
        },
    };
    for (cases) |case| {
        const css = try compileSourceToCss(alloc, case.source, "", &.{}, .{});
        defer alloc.free(css);
        const prelude = css[0 .. std.mem.indexOf(u8, css, " {") orelse return error.TestUnexpectedResult];
        try std.testing.expectEqual(case.selectors, std.mem.count(u8, prelude, ", ") + 1);
        try std.testing.expectEqual(case.covered_kept, std.mem.indexOf(u8, prelude, ", .g .f .f:hover,") != null);
    }
}

test "api: a covered @extend result stays where covering is not a plain match" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { source: []const u8, kept: []const u8 }{
        // A child combinator.
        .{ .source = ".a .a { x: y; }\n.k .f > a, .f { @extend .a; }\n", .kept = ", .k .f > a .f > a," },
        // `*` leaves no trace in what it is unified with.
        .{ .source = ".a.b .a.b { x: y; }\n.f:hover, #x *.f:hover { @extend .a; }\n", .kept = ", #x .b.f:hover .b.f:hover," },
        .{ .source = "div.a div.a { x: y; }\n.f:hover, #x *|div.f:hover { @extend .a; }\n", .kept = ", #x div.f:hover div.f:hover," },
        // Unifying with `.a.f` and `.a.g` makes compounds that cover others.
        .{ .source = ".a.f .a.g { x: y; }\n.f .g { @extend .a; }\n", .kept = ", .f .f.g .a.g," },
        // The ancestor `.f` of one extender is what another one ends with.
        .{ .source = ".a .a .a { x: y; }\n.f :hover, .f, .g.h, .f.k { @extend .a; }\n", .kept = ", .a .a .f :hover," },
        // The ancestors `.g` and `.f.g.k` of two extenders cover each other.
        .{ .source = ".a .a { x: y; }\n.f.g.k .h, .g .h, .x .h { @extend .a; }\n", .kept = ", .x .h .f.g.k .h," },
        // With three places not every combination is made.
        .{ .source = ".a .a .a { x: y; }\nspan, .k :hover, .d span { @extend .a; }\n", .kept = ", .d .k :hover span .a," },
        // `:where()` adds no specificity.
        .{ .source = ".a .a { x: y; }\n.f:hover, .g :where(.f) { @extend .a; }\n", .kept = ", .g :where(.f) .f:hover," },
    };
    for (cases) |case| {
        const css = try compileSourceToCss(alloc, case.source, "", &.{}, .{});
        defer alloc.free(css);
        try std.testing.expect(std.mem.indexOf(u8, css, case.kept) != null);
    }
}

test "api: an ancestor the extender's last compound matches is not shared" {
    const alloc = std.testing.allocator;
    const css = try compileSourceToCss(alloc, ".a .a { x: y; }\ndiv .f + div { @extend .a; }\n", "", &.{}, .{});
    defer alloc.free(css);
    try std.testing.expect(std.mem.indexOf(u8, css, ", div .f + div .f + div") == null);
}

test "api: an extender's ancestors are not shared past a sibling combinator" {
    const alloc = std.testing.allocator;
    const css = try compileSourceToCss(alloc, ".p + .a .a { x: y; }\n.x .f + .g ~ .h { @extend .a; }\n", "", &.{}, .{});
    defer alloc.free(css);
    try std.testing.expect(std.mem.indexOf(u8, css, ".x .f .g ~ .p + .h .f + .g ~ .h") == null);
}

test "api: an extender's ancestors are shared only when it is the sole extender" {
    const alloc = std.testing.allocator;
    const css = try compileSourceToCss(alloc, ".a .a { x: y; }\n.g { @extend .a; }\n.x .f + .g { @extend .a; }\n", "", &.{}, .{});
    defer alloc.free(css);
    try std.testing.expect(std.mem.indexOf(u8, css, ".x .f + .g .f + .g") == null);
}

test "api: an extender with ancestors and a sibling joins a repeated @extend target" {
    const alloc = std.testing.allocator;
    const source =
        \\.x .p .a .a { x: y; }
        \\.x .f + .g { @extend .a; }
        \\
    ;
    const css = try compileSourceToCss(alloc, source, "", &.{}, .{});
    defer alloc.free(css);
    try std.testing.expectEqualStrings(
        \\.x .p .a .a, .x .p .f + .g .a, .x .p .a .f + .g, .x .p .f + .g .f + .g {
        \\  x: y;
        \\}
        \\
    , css);
}

test "api: a signed number right after a word is added to it" {
    const alloc = std.testing.allocator;
    // `x+1` is `x` plus 1, not one word. A unicode range stays as it is.
    const source =
        \\$v: 2;
        \\a {
        \\  b: x+1 x+1px 2 x+0.4rem;
        \\  c: x+y+1 a, b+1;
        \\  d: n+1 2n+1 -n+1;
        \\  e: x-1 x+$v $v+1 1+x;
        \\  f: U+26 u+1F;
        \\  g: x+1 !important;
        \\}
        \\
    ;
    const css = try compileSourceToCss(alloc, source, "", &.{}, .{ .quiet = true });
    defer alloc.free(css);
    try std.testing.expectEqualStrings(
        \\a {
        \\  b: x1 x1px 2 x0.4rem;
        \\  c: xy1 a, b1;
        \\  d: n1 3n -n1;
        \\  e: x-1 x2 3 1x;
        \\  f: U+26 u+1F;
        \\  g: x1 !important;
        \\}
        \\
    , css);
}

test "api: a repeated @extend target past the limit is still extended" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // Weaving `.x .f` into ten compounds makes more selectors than the
    // combined path allows, so the selector takes the ordinary path.
    const source =
        \\.p0 .a .p1 .a .p2 .a .p3 .a .p4 .a .p5 .a .p6 .a .p7 .a .p8 .a .p9 .a { x: y; }
        \\.x .f { @extend .a; }
        \\
    ;
    const css = try compileSourceToCss(alloc, source, "", &.{}, .{});
    // One compound at a time: the original and, for each of the ten
    // compounds, the two ways of weaving `.x` in.
    const selector_list = css[0..std.mem.indexOfScalar(u8, css, '{').?];
    try std.testing.expectEqual(@as(usize, 21), std.mem.count(u8, selector_list, ", ") + 1);
    for (0..10) |i| {
        var buf: [32]u8 = undefined;
        const direct = try std.fmt.bufPrint(&buf, ".p{d} .x .f", .{i});
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, selector_list, direct));
        const woven = try std.fmt.bufPrint(&buf, ".p{d} .f", .{i});
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, selector_list, woven));
    }
}

test "api: is-superselector follows the official CLI on :not(), :is(), and the universal selector" {
    const alloc = std.testing.allocator;
    const source =
        \\@use "sass:selector";
        \\@function s($a, $b) {
        \\  @return selector.is-superselector($a, $b);
        \\}
        \\a {
        \\  not: s(":not(.c)", ".d .e") s(":not(.c)", "b:not(.c)") s(":not(.c.d)", ":not(.c)") s(":not(.c, .d)", ":not(.c)") s(":not(.c, .d)", ":not(.c):not(.d)") s(":not(a)", "b") s(":not(.c)", ":not(.c)::before");
        \\  is: s(":is(.c)", ":any(.c)") s(":is(.c, .d)", ":any(.c, .d)") s(":is(.c, .d)", ".e:is(.c, .d)") s(".c", ":is(.c, .d)") s(".c", ":is(.c.d, .c.e)") s(".d", ":is(.c .d)") s("a", ":is(a.c)");
        \\  nth: s(".c", ":nth-child(2n of .c.d)") s(".c", ":nth-child(2n of .c, .d)");
        \\  universal: s("*", ".c") s("*.c", ".c") s("*.c", "a.c") s("*.c", ".c.d") s("*:is(.c)", ".c") s("*:hover", ":hover");
        \\  namespace: s(":not(*|a)", "a") s(":not(ns|*)", "ns|a") s(":not(#i)", "#j");
        \\}
        \\.a .a {
        \\  x: y;
        \\}
        \\.c, :is(.c, .d) {
        \\  @extend .a;
        \\}
        \\
    ;
    const css = try compileSourceToCss(alloc, source, "", &.{}, .{ .quiet = true });
    defer alloc.free(css);
    try std.testing.expectEqualStrings(
        \\a {
        \\  not: false true true false true true false;
        \\  is: true false true false true true true;
        \\  nth: true false;
        \\  universal: true false true true true false;
        \\  namespace: true false true;
        \\}
        \\
        \\.a .a, :is(.c, .d) .a, .a :is(.c, .d), :is(.c, .d) :is(.c, .d) {
        \\  x: y;
        \\}
        \\
    , css);
}
