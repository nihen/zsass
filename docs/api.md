# zsass Compiler API Quickstart

> Need the command-line interface? See `docs/cli.md` for build and usage tips.

The compiler is exposed as a named build module (`compiler`) so other Zig
projects can consume it directly without vendoring source files.

## Adding the dependency

1. Add zsass to your `build.zig.zon` dependency list:

```
.{
    .dependencies = .{
        .zsass = .{ .url = "https://github.com/nihen/zsass/archive/<tag>.tar.gz" },
    },
}
```

2. Import the compiler module from your `build.zig`:

```
const zsass_dep = b.dependency("zsass", .{ .target = target, .optimize = optimize });
const zsass_compiler = zsass_dep.module("compiler");
exe.root_module.addImport("zsass", zsass_compiler);
```

### Pinning releases via `zig fetch`

Instead of editing `build.zig.zon` by hand, ask Zig to pull and record the
release you want:

```bash
zig fetch https://github.com/nihen/zsass/archive/v0.1.0.tar.gz --save=zsass
```

- Swap `v0.1.0` for the tag you need (the command prints the exact hash).
- The `--save=zsass` flag tells Zig to write/update the `dependencies.zsass`
  entry, so teammates and CI reuse the same tarball automatically.

Re-run the command whenever you upgrade to a newer release; Zig will refresh
the URL and hash in-place.

## Public surface (`src/api.zig`)

The compiler module exposes:

- two in-memory single-source compile entry points (`compileSourceToCss`,
  `compileSourceToCssWithSourceMap`) that accept `CompileOptions` for
  output style, quiet mode, resource limits, cancellation, and which files a
  stylesheet may load,
- a parallel file-batch entry point (`compileFiles`) that mirrors the CLI's
  shared source / parsed-AST cache pipeline and returns each result in
  memory, and
- a profile dump helper (`dumpProfile`) that no-ops unless the build was
  configured with `-Dprofile=true`.

Everything else (rule IR, VM internals, etc.) lives behind module boundaries
and is not part of the stable embedding surface.

```zig
pub const OutputStyle = enum { expanded, compressed };

pub const CompileOptions = struct {
    output_style: OutputStyle = .expanded,
    quiet: bool = false, // suppress @warn / @debug
    diagnostic_sink: ?DiagnosticSink = null,
    diagnostic_ctx: ?*anyopaque = null,
    limits: CompileLimits = .{},
    cancellation_check: ?CancellationCheck = null,
    cancellation_ctx: ?*anyopaque = null,
    file_import_policy: FileImportPolicy = .unrestricted,

    pub fn forUntrustedInput(import_roots: []const []const u8) CompileOptions;
};

pub const CompileLimits = struct {
    max_source_bytes: usize = 128 * 1024 * 1024,
    max_syntax_depth: u32 = 512,
    max_vm_steps: u64 = 500_000_000,
    max_selector_candidates: usize = 200_000,
    max_ir_nodes: usize = 5_000_000,
    max_output_bytes: usize = 128 * 1024 * 1024,
    max_memory_bytes: usize = 2 * 1024 * 1024 * 1024,
    stack_bytes: usize = 4 * 1024 * 1024,

    pub fn unlimited() CompileLimits;
};

pub const CancellationCheck = *const fn (ctx: ?*anyopaque) bool;

pub const FileImportPolicy = union(enum) {
    disabled,
    unrestricted,
    roots: []const []const u8,
};

pub fn isLimitError(err: anyerror) bool;

pub fn compileSourceToCss(
    alloc: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    load_paths: []const []const u8,
    opts: CompileOptions,
) anyerror![]u8;

pub fn compileSourceToCssWithSourceMap(
    alloc: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    load_paths: []const []const u8,
    source_map_output_css_path: ?[]const u8,
    opts: CompileOptions,
) anyerror!CompileCssWithSourceMapResult;

pub const CompileCssWithSourceMapResult = struct {
    css: []u8,
    source_map_json: []u8,

    pub fn deinit(self: *CompileCssWithSourceMapResult, allocator: std.mem.Allocator) void;
};

pub const CompileFileResult = struct {
    css: ?[]u8 = null,
    source_map_json: ?[]u8 = null,
    err: ?anyerror = null,

    pub fn deinit(self: *CompileFileResult, allocator: std.mem.Allocator) void;
};

pub const CompileFilesOptions = struct {
    output_style: OutputStyle = .expanded,
    source_map: bool = false,
    quiet: bool = false,
    load_paths: []const []const u8 = &.{},
    jobs: usize = 0, // 0 = auto (std.Thread.getCpuCount())
    limits: CompileLimits = .{}, // applied to each entry separately
    cancellation_check: ?CancellationCheck = null, // called from worker threads
    cancellation_ctx: ?*anyopaque = null,
    file_import_policy: FileImportPolicy = .unrestricted,
};

pub fn compileFiles(
    alloc: std.mem.Allocator,
    paths: []const []const u8,
    opts: CompileFilesOptions,
) anyerror![]CompileFileResult;

pub fn dumpProfile() void; // no-op unless built with `-Dprofile=true`
```

The single-source helpers return `alloc`-owned slices; the caller frees them
(`alloc.free(css)` for the no-source-map variant, `result.deinit(alloc)` for
the source-map variant). `compileFiles` returns an `alloc`-owned slice of
`CompileFileResult`; the caller iterates and calls `result.deinit(alloc)` on
each entry, then frees the outer slice with `alloc.free(results)`.

`load_paths` is the user-module search list consulted by `@use` / `@forward` /
bare relative `@import` when a path is not found relative to `dirname(file_path)`.
Pass `&.{}` if you have no extra roots. `file_path` and `load_paths` decide
where URLs are looked up; they do not confine what a stylesheet can load. See
[Compiling untrusted input](#compiling-untrusted-input). `file_path` is also stored as the source
identifier for source maps; use a meaningful virtual path (e.g. `"<stdin>"` or
`"src/app.scss"`) even when compiling in-memory strings.

`source_map_output_css_path` is optional. When non-null, the source-map writer
treats it as the eventual on-disk location of the CSS file and rewrites
`sources` entries to POSIX paths relative to its directory - the same rule the
CLI applies. Pass `null` when the CSS will not be persisted.

## Minimal in-memory compile

```zig
const std = @import("std");
const zsass = @import("zsass"); // matches the addImport name from build.zig

pub fn buildCss(alloc: std.mem.Allocator, source: []const u8) ![]u8 {
    return try zsass.compileSourceToCss(alloc, source, "<stdin>", &.{}, .{});
}
```

## Compile with source map

```zig
const std = @import("std");
const zsass = @import("zsass");

pub fn buildCssWithMap(
    alloc: std.mem.Allocator,
    source: []const u8,
    css_output_path: []const u8,
) !void {
    var result = try zsass.compileSourceToCssWithSourceMap(
        alloc,
        source,
        "src/app.scss",
        &.{ "shared/styles", "vendor/sass" },
        css_output_path,
        .{}, // .output_style = .compressed, .quiet = true, ...
    );
    defer result.deinit(alloc);
    // result.css and result.source_map_json are ready to write to disk.
}
```

## Compile a parallel batch of files

`compileFiles` is the embedding-friendly counterpart to the CLI's batch mode.
It uses the same shared source / parsed-AST / persistent-resolver caches as
the CLI so vendor `@use` / `@forward` chains are not re-parsed for every
entry, but writes results into in-memory `CompileFileResult` records instead
of disk:

```zig
const std = @import("std");
const zsass = @import("zsass");

pub fn buildAll(alloc: std.mem.Allocator, paths: []const []const u8) !void {
    const results = try zsass.compileFiles(alloc, paths, .{
        .output_style = .compressed,
        .source_map = false,
        .quiet = true,
        .load_paths = &.{ "shared/styles", "vendor/sass" },
        .jobs = 0, // 0 = std.Thread.getCpuCount()
    });
    defer {
        for (results) |*r| r.deinit(alloc);
        alloc.free(results);
    }

    for (paths, results) |path, result| {
        if (result.err) |err| {
            std.debug.print("FAIL  {s}: {}\n", .{ path, err });
            continue;
        }
        const css = result.css orelse continue;
        // write `css` (and `result.source_map_json` when source_map = true) wherever you want.
        _ = path;
        _ = css;
    }
}
```

Workers share `zsass.io_facility.io`. It starts as Zig's single-threaded
`Io`, which does not support several threads at once, so `compileFiles`
compiles one entry at a time until the embedder installs a thread-capable
one, for example `zsass.io_facility.io = init.io;` in `main`, as the
examples do.

`results.len == paths.len` and the order is preserved. When `source_map` is
`false`, `result.source_map_json` is `null`. Failed entries leave
`result.err` non-null and `result.css` `null` - `compileFiles` itself returns
the slice; per-entry failures are surfaced through the result records, not
through the outer return.

## Compiling untrusted input

Every compilation runs under `CompileOptions.limits`. The defaults are
finite, so a stylesheet that nests too deeply, loops forever, or expands
`@extend` combinatorially fails with an error instead of exhausting the
process:

| Limit | Default | Error | Diagnostic code |
| --- | --- | --- | --- |
| `max_source_bytes` (each stylesheet) | 128 MiB | `error.SourceSizeLimit` | `ZSASS_LIMIT_SOURCE_BYTES` |
| `max_syntax_depth` | 512 | `error.SyntaxNestingLimit` | `ZSASS_LIMIT_SYNTAX_DEPTH` |
| `stack_bytes` (values and selectors built at run time) | 4 MiB | `error.NestingLimit` | `ZSASS_LIMIT_NESTING_DEPTH` |
| `max_vm_steps` | 500,000,000 | `error.ExecutionLimit` | `ZSASS_LIMIT_VM_STEPS` |
| `max_selector_candidates` | 200,000 | `error.SelectorExpansionLimit` | `ZSASS_LIMIT_SELECTOR_CANDIDATES` |
| `max_ir_nodes` | 5,000,000 | `error.IrNodeLimit` | `ZSASS_LIMIT_IR_NODES` |
| `max_output_bytes` | 128 MiB | `error.OutputSizeLimit` | `ZSASS_LIMIT_OUTPUT_BYTES` |
| `max_memory_bytes` (held at once through the given allocator) | 2 GiB | `error.MemoryLimit` | `ZSASS_LIMIT_MEMORY_BYTES` |

One budget covers the whole compilation: every module it loads and every
`meta.load-css()` counts against it. Each `compileFiles` entry gets its own,
and the caches its entries share have one more `max_memory_bytes` of their
own.
Syntax depth counts blocks, parentheses, brackets, interpolation, unary
operators, each operator of a chain such as `a + b + c`, and the brackets of
a selector, which is parsed again at run time. `max_selector_candidates`
bounds the selectors `@extend` holds at once: the extenders registered for
the rules being written, plus what extending one selector makes along the
way. A selector counts once per compound and combinator, because the memory
it takes grows with its length. The defaults leave wide
room over the sass-spec suite and a corpus of real-world projects; raise a
limit when a trusted stylesheet needs more, or use `CompileLimits.unlimited()`.
`isLimitError(err)` tells these errors apart from Sass errors, and the final
`Diagnostic` carries the code in `code`.

The compiler recurses on the native stack of the calling thread. It uses up
to `stack_bytes` below the call; give the thread at least twice that, or
lower `stack_bytes` and `max_syntax_depth` together on a small stack.

The limits count work, not time. For a wall-clock timeout, pass
`cancellation_check`; it is called about every thousand VM instructions and
between the phases of the compilation, and returning `true` stops it with
`error.CompilationCancelled`:

```zig
const Deadline = struct {
    io: std.Io,
    end_ns: i96,
    fn expired(ctx: ?*anyopaque) bool {
        const self: *const Deadline = @ptrCast(@alignCast(ctx.?));
        return std.Io.Clock.awake.now(self.io).nanoseconds >= self.end_ns;
    }
};

const io = zsass.io_facility.io;
var deadline: Deadline = .{ .io = io, .end_ns = std.Io.Clock.awake.now(io).nanoseconds + 2 * std.time.ns_per_s };
var opts = zsass.CompileOptions.forUntrustedInput(&.{});
opts.cancellation_check = Deadline.expired;
opts.cancellation_ctx = &deadline;
const css = try zsass.compileSourceToCss(alloc, source, "input.scss", &.{}, opts);
```

`@use`, `@forward`, `@import`, and `meta.load-css()` read files the way Sass
does: relative to `file_path`, through `load_paths`, and through `../`. Set
`file_import_policy` to keep a stylesheet from reading files you did not
mean to expose:

- `.unrestricted` (the default) loads any Sass or CSS file the process can
  read.
- `.disabled` loads none. Built-in modules such as `sass:math` still work,
  and a plain CSS `@import` stays in the output.
- `.{ .roots = &.{"/srv/styles"} }` loads only files inside the given
  directories, both as the URL names them and after symbolic links are
  resolved. A `pkg:` URL is refused.

A refused URL fails with `error.FileImportDenied` (`ZSASS_IMPORT_DENIED`),
with the same message whether or not the file exists.
`CompileOptions.forUntrustedInput(roots)` returns options with the default
limits and file imports confined to `roots`, or disabled when `roots` is
empty. The roots slice must outlive the compile call.

Limits and the import policy are not a sandbox. When the input is hostile,
also run the compiler in a process or container with CPU, memory, and
wall-clock limits.

## Profile dump (`-Dprofile=true` only)

When you build the compiler module with `-Dprofile=true`, every internal
phase increments a counter that you can dump from your embedder:

```zig
const std = @import("std");
const zsass = @import("zsass");
const build_options = @import("build_options"); // your own options module

pub fn maybeDumpProfile() void {
    if (comptime !build_options.profile) return;
    zsass.dumpProfile();
}
```

`zsass.dumpProfile()` itself compiles to nothing when zsass was built without
`-Dprofile=true`, so it is safe to call unconditionally.

## Mirroring CLI behavior

The single-source entry points do not read env vars or stdin, and they read
no file but the stylesheets that the source loads (see
`file_import_policy`). `compileFiles` also opens and reads each input path,
but otherwise leaves env-var defaults and output-path conventions to the
caller. If you need the same behaviors as the CLI (env-var defaults,
output path inference), wrap these helpers in your own driver:

| CLI behavior | How to mirror it from the API |
| --- | --- |
| `--style` | Set `CompileOptions.output_style` or `CompileFilesOptions.output_style` to `.expanded` or `.compressed`. |
| `--source-map` / `--embed-source-map` | Use `compileSourceToCssWithSourceMap` and decide yourself whether to emit the JSON to disk, embed it, or attach it to a bundler. |
| `<input>:<output>` / `-o <output>` / `--output <output>` | Pass your eventual CSS path as `source_map_output_css_path` so `sources` paths in the map become posix-relative. |
| `-I` / `--load-path` / `SASS_PATH` | Build a `[][]const u8` and pass it as `load_paths`. The API consults the array in order before resolving relative to `dirname(file_path)`. |
| `--stdin-filepath` | Pass that virtual path as `file_path` when compiling in-memory source. |
| `--no-charset` / `--charset` | The API does not auto-insert `@charset`. Prepend it yourself if you need parity. |
| `--plain-css` / `--scss` | The API always evaluates SCSS. Use the CLI for raw passthrough mode. |
| `--no-limits` | Set `limits = CompileLimits.unlimited()`. |

## Runnable examples

The examples live under `examples/` and are wired through `build.zig`:

- `zig build api-example` - runs `examples/embed_basic.zig`, an in-memory
  `compileSourceToCssWithSourceMap` demo. Prints CSS + source-map JSON to
  stdout.
- `zig build api-file-example` - runs `examples/embed_file.zig`, which reads
  `examples/sample.scss` (or any path you pass), compiles it, and writes both
  the CSS and `.map` file under `zig-out/examples/`.
- `zig build api-files-example` - runs `examples/embed_files.zig`, which
  parallelises `compileFiles` over its argument paths (defaults to
  `examples/sample.scss`) and emits compressed CSS to stdout.
- `zig build api-smoke` - chains the three embedding examples for a single
  regression check (CI / downstream consumers can run this after upgrading).
- `zig build quickstart` - CLI smoke (`--version` + `--info`) followed by the
  API smoke chain. Fastest "is everything wired correctly?" command for new
  machines.
