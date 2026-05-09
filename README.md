# zsass

[![CI](https://github.com/nihen/zsass/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/nihen/zsass/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/nihen/zsass?display_name=tag&sort=semver)](https://github.com/nihen/zsass/releases/latest)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Zig 0.16+](https://img.shields.io/badge/zig-0.16%2B-orange.svg)](https://ziglang.org/)
[![sass-spec](https://img.shields.io/badge/sass--spec-13885%2F13885-brightgreen.svg)](https://github.com/sass/sass-spec)

A Zig implementation of the Sass compiler, designed for speed and native
Zig ergonomics. Built around a small Rule IR and a single-pass writer;
no external libsass / dart-sass runtime required.

> Clean-room implementation: zsass was written without reading the Dart Sass
> source. Behavior is verified against the official `sass-spec` suite and the
> `sass` CLI's observable output only.

### sass-spec compatibility

This release passes the upstream `sass-spec` suite vendored at the
submodule pin in `tests/sass-spec`: **13,885 / 13,885 cases pass, 6
skipped** (see `tests/sass-spec/.gitmodules` for the exact commit and
`tests/spec_runner.zig` for the runner). Compatibility is validated
against that suite and the official `sass` CLI's observable output;
behavior outside cases the suite covers may diverge from dart-sass.
Re-run with `zig build test` after updating the submodule to verify the
current pin yourself.

## Performance vs dart-sass

Wall-clock time compiling the upstream `sass-spec` suite end-to-end
(`scripts/bench.sh`, ReleaseFast, batch mode, single process). Lower
`ratio` is better; values under `1.00x` mean zsass finished faster than
the Dart implementation.

| Suite (entries) | zsass | dart-sass | ratio |
| --- | ---: | ---: | ---: |
| sass-spec (~13400) | 3865 ms | 10323 ms | **0.37x** |

`sass-spec` is the only suite shipped with this repository (vendored as
a submodule under `tests/sass-spec`), which makes it the easiest number
to reproduce; private real-world bundles tend to follow the same
ordering on our setup.

*Measured on 2026-05-08, Linux x86_64 (zsass ReleaseFast vs
`sass --no-source-map` from the bundled dart-sass release).* Numbers
will drift as both compilers evolve and depend on CPU / OS / Zig
optimize mode -- rerun `scripts/bench.sh` on your machine for current
values.

## Install

The installer detects your OS / arch, downloads the matching tarball
from GitHub Releases, verifies its SHA256, and drops the binary into
`~/.local/bin` (Unix) or `%LOCALAPPDATA%\zsass\bin` (Windows).

Linux / macOS:

```bash
curl -fsSL https://raw.githubusercontent.com/nihen/zsass/main/scripts/install.sh | sh
```

Windows (PowerShell):

```powershell
iwr -useb https://raw.githubusercontent.com/nihen/zsass/main/scripts/install.ps1 | iex
```

Pin a version or change the prefix:

```bash
curl -fsSL https://raw.githubusercontent.com/nihen/zsass/main/scripts/install.sh \
  | sh -s -- --version v0.1.0 --prefix ~/opt/zsass
```

If you would rather audit the installer first, the scripts live at
[`scripts/install.sh`](scripts/install.sh) /
[`scripts/install.ps1`](scripts/install.ps1).

### Manual download

Each release publishes `tar.gz` archives for Linux x86_64 / aarch64 and
macOS x86_64 / aarch64, plus a `zip` for Windows x86_64. Every asset
has a sibling `.sha256` file (and a `.sig` / `.pem` for Sigstore-aware
setups).

```bash
sha256sum -c zsass-v0.1.0-linux-x86_64.tar.gz.sha256
tar -xzf zsass-v0.1.0-linux-x86_64.tar.gz
install -m 0755 zsass-v0.1.0-linux-x86_64/zsass ~/.local/bin/
```

For a stronger provenance check than SHA256 -- typically only worth
wiring up in unattended / CI / production setups -- verify the Sigstore
signature with [`cosign`](https://github.com/sigstore/cosign):

```bash
cosign verify-blob \
  --certificate            zsass-v0.1.0-linux-x86_64.tar.gz.pem \
  --signature              zsass-v0.1.0-linux-x86_64.tar.gz.sig \
  --certificate-identity   'https://github.com/nihen/zsass/.github/workflows/release.yml@refs/tags/v0.1.0' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  zsass-v0.1.0-linux-x86_64.tar.gz
```

`Verified OK` proves the artifact came from this repository's release
workflow. The signing material lives in the public Sigstore Rekor
transparency log - no secret keys are involved.

### From source (Zig 0.16+)

```bash
zig build -Doptimize=ReleaseFast        # binary at zig-out/bin/zsass
zig build install --prefix ~/.local     # install to ~/.local/bin
```

For repeatable CI builds the repo also ships
[`scripts/install_cli.sh`](scripts/install_cli.sh) (Linux / macOS) and
[`scripts/install_cli.ps1`](scripts/install_cli.ps1) (Windows), which
honour `ZSASS_INSTALL_PREFIX` / `ZSASS_INSTALL_OPTIMIZE` /
`ZSASS_GLOBAL_CACHE_DIR`. See [docs/cli.md](docs/cli.md) for details.

## Usage

```bash
# Compile SCSS to CSS (file-to-file; also writes input.css.map by default)
zsass input.scss output.css

# Stdin/stdout
echo 'a { b: 1 + 2; }' | zsass --stdin

# Directory compilation
zsass src/styles/:dist/css/

# Diagnostics
zsass --version
zsass --info
```

Notes:

- stdin is explicit: pass `--stdin` or `-` when piping input
- file outputs enable detached source maps by default; stdout keeps source
  maps off unless you request `--embed-source-map`

## Embed as Zig library

Add zsass as a dependency (writes the entry into your `build.zig.zon`):

```bash
zig fetch --save=zsass \
  https://github.com/nihen/zsass/archive/refs/tags/v0.1.0.tar.gz
```

Then wire it up in `build.zig`:

```zig
const zsass_dep = b.dependency("zsass", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zsass", zsass_dep.module("compiler"));
```

```zig
// usage
const std = @import("std");
const zsass = @import("zsass");

pub fn buildCss(alloc: std.mem.Allocator, source: []const u8) ![]u8 {
    return try zsass.compileSourceToCss(alloc, source, "<stdin>", &.{}, .{});
}
```

The trailing `CompileOptions` lets you pick a different output style or
suppress `@warn` / `@debug`:

```zig
const css = try zsass.compileSourceToCss(alloc, source, "<stdin>", &.{}, .{
    .output_style = .compressed,
    .quiet = true,
});
```

For source-map output use `compileSourceToCssWithSourceMap`, which returns a
`CompileCssWithSourceMapResult` owning both the CSS and the source-map JSON.

For multi-file batches the embedding surface also exposes a parallel
`compileFiles`, which mirrors the CLI's worker pool / shared source &
parsed-AST caches but writes results into in-memory `CompileFileResult`
records:

```zig
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
```

When the build is configured with `-Dprofile=true`, embedders can dump the
aggregated `perf` counters via `zsass.dumpProfile()` (no-op otherwise).

See [docs/api.md](docs/api.md) for the full embedding surface and
[examples/](examples/) for runnable samples.

## Development

```bash
git submodule update --init  # fetch sass-spec (required for spec tests)
zig build            # build CLI
zig build unit-test  # unit tests only (fast)
zig build test       # unit tests + sass-spec
zig build spec       # sass-spec only (with --filter, --quiet options)
zig build realworld  # external fixture runner; defaults to all suites
                     # under ../zsass-realworld-fixtures (see docs)
```

Embedding examples (also handy as smoke tests):

```bash
zig build api-example       # in-memory compile demo (examples/embed_basic.zig)
zig build api-file-example  # file-based compile demo (examples/embed_file.zig)
zig build api-files-example # parallel batch compile demo (examples/embed_files.zig)
zig build api-smoke         # all three examples back-to-back (regression check)
zig build quickstart        # CLI smoke + api-smoke (fastest "is it wired?" check)
```

See [docs/realworld-fixture.md](docs/realworld-fixture.md) for the
external-fixture workflow used for large real-world compatibility
snapshots.

## Project structure

```
src/
  main.zig                  # CLI entry point (delegates to runtime/driver.zig)
  api.zig                   # Public embedding API (compileSourceToCss*)
  frontend/                 # Lexer + parser (.scss / .sass) -> flat AST
    lexer.zig
    parser.zig
    ast_flat.zig
    sass_converter.zig
  resolve/                  # AST -> ResolvedProgram (scope, @use/@forward,
                            # @import expansion, mixin/function decls)
    resolver.zig            # main entry; statement handlers split into stmt_*.zig
    data.zig                # shared records (Resolved AST, ModuleResolver, ...)
    module_*.zig            # @use / @forward / @import clusters
    stmt_*.zig              # @media / @at-root / @content / ... handlers
  ir/                       # ResolvedProgram -> bytecode Program
    compiler.zig
    opcode.zig
    rule_ir.zig             # the Rule IR the VM appends to
    source_map.zig          # SourceMap v3 emitter
  runtime/                  # VM + driver + I/O
    vm.zig                  # bytecode dispatcher; appends Rule IR
    driver.zig              # CLI driver (stdin / file / dir / watch / REPL)
    io.zig                  # threaded std.Io facility shared by callers
  selector/                 # Selector model + @extend unification
    selector.zig
    extend.zig
  builtin/                  # sass:math / sass:color / sass:string / sass:list
                            # / sass:map / sass:meta / sass:selector
  color/                    # color value model + format dispatch
tests/
  spec_runner.zig           # sass-spec HRX test runner
  sass-spec/                # git submodule (official test suite)
docs/
  api.md                    # Embedding API guide
  cli.md                    # CLI reference
  ci.md                     # CI/CD setup
  realworld-fixture.md      # External fixture workflow
examples/
  embed_basic.zig           # In-memory compile + source map demo
  embed_file.zig            # File-based compile demo
  embed_files.zig           # Parallel batch compile + compressed output demo
  sample.scss               # Sample stylesheet (input for embed_file.zig)
```

Pipeline:

```
.scss / .sass -> Lexer -> Parser -> Resolve -> Compile (bytecode)
              -> VM (appends Rule IR) -> Writer (1-pass + optional source map)
              -> CSS (+ .map)
```

## License

[MIT](LICENSE)
