# zsass

[![CI](https://github.com/nihen/zsass/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/nihen/zsass/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/nihen/zsass?display_name=tag&sort=semver)](https://github.com/nihen/zsass/releases/latest)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Zig 0.16+](https://img.shields.io/badge/zig-0.16%2B-orange.svg)](https://ziglang.org/)
[![sass-spec](https://img.shields.io/badge/sass--spec-13885%2F13885-brightgreen.svg)](https://github.com/sass/sass-spec)

A clean-room Sass compiler written in Zig for native and Zig
build-tooling workflows. zsass provides a standalone CLI and an
embeddable Zig API, with no Dart Sass or libsass runtime dependency.

## Status

zsass is an early v0.1 clean-room Sass compiler written in Zig.

Dart Sass is already fast and mature. zsass is not positioned as a
revolutionary speedup or a universal drop-in replacement. The goal is
to provide a native, embeddable Sass implementation that fits naturally
into Zig and native build-tooling workflows.

zsass passes the pinned `sass-spec` suite used in this repository, but
this is not a full compatibility guarantee. Real-world stylesheets may
still expose differences from Dart Sass. If you find a divergence,
please open a [compatibility report](.github/ISSUE_TEMPLATE/compatibility_report.yml)
with a minimal SCSS reproducer.

## Who is this for?

zsass may be interesting if you:

- want a Sass compiler that can be built and embedded from Zig;
- want a standalone native binary for build pipelines;
- are building native CSS tooling;
- are interested in compiler implementation techniques;
- want to test real-world Sass compatibility against a clean-room
  implementation.

If you only need a mature, widely deployed Sass compiler today,
Dart Sass remains the default recommendation.

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

### Homebrew (macOS / Linux)

```bash
brew install nihen/tap/zsass
```

The formula lives in [`nihen/homebrew-tap`](https://github.com/nihen/homebrew-tap)
and is regenerated on every release by
[`.github/workflows/release.yml`](.github/workflows/release.yml).
Each upgrade reuses the same SHA256 sidecars that the release workflow
publishes alongside the archives.

### Container image (Linux amd64 / arm64)

Release images are published to GitHub Container Registry:

```bash
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD":/work -w /work ghcr.io/nihen/zsass:latest input.scss output.css
```

For reproducible builds, pin the release tag instead of `latest`:

```bash
docker run --rm ghcr.io/nihen/zsass:0.3.2 --version
```

The `--user` flag keeps generated files owned by your host user on
Linux. The image is built from the same Linux release archives that are
published on GitHub Releases. The Docker build verifies the downloaded
archive against its `.sha256` sidecar before extraction; Sigstore
provenance materials (`.sig` / `.pem`) are still published with each
release for separate provenance checks.

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

## sass-spec compatibility

This release passes the upstream `sass-spec` suite vendored at the
submodule pin in `tests/sass-spec`: **13,885 / 13,885 cases pass, 6
skipped** (see `tests/sass-spec/.gitmodules` for the exact commit and
`tests/spec_runner.zig` for the runner). This validates behavior
against the cases the suite covers; outside that, real-world
stylesheets may still diverge from Dart Sass. Re-run with
`zig build test` after updating the submodule to verify the pin
yourself, and please file a [compatibility report](.github/ISSUE_TEMPLATE/compatibility_report.yml)
if you hit a divergence.

## Benchmarks

zsass ships reproducible benchmark scripts. On the benchmark set used
in this repository it is competitive with Dart Sass and faster in some
cases, but performance depends on workload, machine, and build mode.
Treat the numbers as a starting point and rerun on your own setup.

Wall-clock time compiling the upstream `sass-spec` suite end-to-end
(`scripts/bench.sh`, ReleaseFast, batch mode, single process):

| Suite (entries) | zsass | dart-sass | ratio |
| --- | ---: | ---: | ---: |
| sass-spec (~13400) | 3865 ms | 10323 ms | 0.37x |

Measured on 2026-05-08, Linux x86_64 (zsass ReleaseFast vs
`sass --no-source-map` from the bundled dart-sass release). Numbers
will drift as both compilers evolve and depend on CPU / OS / Zig
optimize mode.

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

## Provenance and clean-room policy

zsass follows a clean-room policy: Dart Sass source code, vendored
copies, decompiled artifacts, and AI-generated derivatives of Dart Sass
source must not be used. Behavior is validated through `sass-spec`,
[Sass documentation](https://sass-lang.com/documentation), and the
observable output of the official `sass` CLI.

AI coding assistants may be used as part of the development workflow;
the maintainer is responsible for code review, tests, and releases.

## License

[MIT](LICENSE)
