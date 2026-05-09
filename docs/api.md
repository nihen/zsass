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
  output-style / quiet selection,
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
};

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
Pass `&.{}` if you have no extra roots. `file_path` is also stored as the source
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

`results.len == paths.len` and the order is preserved. When `source_map` is
`false`, `result.source_map_json` is `null`. Failed entries leave
`result.err` non-null and `result.css` `null` - `compileFiles` itself returns
the slice; per-entry failures are surfaced through the result records, not
through the outer return.

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

The API does **not** read files, env vars, or stdin on your behalf for the
single-source entry points. `compileFiles` does open and read each input
path, but otherwise leaves env-var defaults and output-path conventions to
the caller. If you need the same behaviors as the CLI (env-var defaults,
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
