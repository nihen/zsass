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
    error_format_mod.clearContextMessage();
    const prev_diag = pushDiagnosticSink(opts);
    defer restoreDiagnosticSink(prev_diag);
    errdefer |err| reportFinalErrorDiagnostic(err, file_path, opts);
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
    error_format_mod.clearContextMessage();
    const prev_diag = pushDiagnosticSink(opts);
    defer restoreDiagnosticSink(prev_diag);
    errdefer |err| reportFinalErrorDiagnostic(err, file_path, opts);
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
