# zsass CLI Quickstart

The `zsass` binary behaves like the `sass`/`dart-sass` CLI but adds a few
quality-of-life switches for Zig-native workflows. This guide covers the
minimum needed to build it locally, wire it into scripts, and take advantage of
machine-friendly outputs.

## Build & Install

### Pre-built binary (no Zig required)

For day-to-day use you don't need a Zig toolchain - just download the
release tarball and run the installer:

```bash
# Linux / macOS
curl -fsSL https://raw.githubusercontent.com/nihen/zsass/main/scripts/install.sh | sh

# Windows (PowerShell)
iwr -useb https://raw.githubusercontent.com/nihen/zsass/main/scripts/install.ps1 | iex
```

The installer auto-detects OS / arch, downloads the matching artifact from
[GitHub Releases](https://github.com/nihen/zsass/releases), verifies its
SHA256, and installs the binary under `<prefix>/bin` (default
`~/.local/bin` on Unix, `%LOCALAPPDATA%\zsass\bin` on Windows). Pin a
version with `--version v0.1.0` or change the destination with
`--prefix ~/opt/zsass`.

### From source

1. Build a release binary:
   ```bash
   zig build -Doptimize=ReleaseFast
   ```
   The executable is placed at `zig-out/bin/zsass` (on Windows, `zsass.exe`).
2. Optionally install it somewhere on your `$PATH`:
   ```bash
   zig build install --prefix ~/.local
   ```
   Adjust `--prefix` as needed; the binary still lives under
   `<prefix>/bin/zsass`.
3. Verify your install:
```bash
zig-out/bin/zsass --version
zig-out/bin/zsass --info
zig-out/bin/zsass --help
```
Need to see the API samples succeed in the same pass? `zig build quickstart` now chains the CLI smoke test with all three embedding demos (`zig build api-smoke`) so new environments prove out every surface in one go.

### Hands-on sample compile

Need a zero-setup artifact to show teammates what the CLI emits? `zig build cli-sample` builds zsass and runs it against `examples/sample.scss`, writing `zig-out/examples/sample.css` plus `sample.css.map`. It's a quick sanity check for new environments and doubles as a copy/paste baseline when you're wiring bundle outputs.

### Fast install helper

Use the repo-provided script to build and install in one go (helpful for CI or onboarding instructions):

```bash
scripts/install_cli.sh --prefix ~/.local   # defaults to ReleaseFast
scripts/install_cli.sh --optimize ReleaseSafe --prefix /tmp/zsass-test
```

The script honors `ZSASS_INSTALL_PREFIX`, `ZSASS_INSTALL_OPTIMIZE`, and `ZSASS_GLOBAL_CACHE_DIR` environment variables, prints each step, and confirms where the binary was placed.

Working from PowerShell? Run the equivalent helper so Windows developers don't need WSL just to get the CLI:

```powershell
pwsh -File scripts/install_cli.ps1 -Prefix "$env:LOCALAPPDATA/zsass"
pwsh -File scripts/install_cli.ps1 -Optimize ReleaseSafe -GlobalCacheDir C:\zig-cache
```

It reads the same env vars as the Bash version and installs to `<Prefix>\bin\zsass.exe`.

Both helpers can also write shell completion scripts:

- Bash helper: pass `--completions <shell>` (bash, zsh, or fish) one or more
  times to chain-run `scripts/install_completions.sh` with the fresh binary.
  The helper reuses the installed executable instead of searching `PATH`.
- PowerShell helper: pass `-Completions <shell>[,<shell>...]`. Generated
  scripts land at `<Prefix>\completions\zsass.<shell>`; move them to your
  shell's completion directory by hand (e.g. `~/.zsh/completions/_zsass`,
  `~/.config/fish/completions/zsass.fish`, etc.).

## Everyday Usage Patterns
- Compile a file and stream the result to stdout:
  ```bash
  zsass src/styles/app.scss > dist/styles/app.css
  ```
  Passing a single positional argument writes CSS to stdout — `zsass`
  intentionally does not infer a sibling output path. Redirect or pipe the
  output as needed.
- Compile to an explicit target (stdout stays untouched):
  ```bash
  zsass src/styles/app.scss dist/styles/app.css
  zsass src/styles/app.scss -o dist/styles/app.css
  ```
- Batch multiple entrypoints using `input:output` pairs:
  ```bash
  zsass src/app.scss:dist/app.css src/admin.scss:dist/admin.css
  ```
- Compile a whole tree by pointing the pair at directories:
  ```bash
  zsass src/styles:dist/css
  ```
  When the left side of an `input:output` pair is a directory, zsass walks it
  recursively, mirrors the structure under the output directory, compiles every
  `.scss`/`.sass` file (skipping `_partial.*` files), and rewrites the
  extension to `.css`. Directory and single-file pairs can be mixed in one
  invocation.
- Pipe input from another tool while keeping relative imports working:
  ```bash
  cat src/app.scss | zsass --stdin --stdin-filepath src/app.scss -o dist/app.css
  ```
  `--stdin-filepath` seeds the virtual path so `@use`/`@import` statements keep
  resolving relative to `src/` instead of the current working directory.
- Read from stdin explicitly when you want shell pipelines to feed zsass:
  ```bash
  cat src/app.scss | zsass --stdin
  zsass -    # explicit stdin input path also works
  ```
  zsass no longer auto-reads stdin when no input path is provided; pass
  `--stdin` or `-` explicitly so scripts fail loudly when they forget inputs.
- Treat stdin like a scratch pad (adds the current directory as a fallback load
  path automatically):
  ```bash
  zsass --stdin
  ```
- Let file outputs keep detached source maps automatically:
  ```bash
  zsass src/app.scss dist/app.css
  ```
  This writes both `dist/app.css` and `dist/app.css.map` by default. When
  writing CSS to stdout, source maps stay off unless you explicitly request
  `--embed-source-map` (or `--source-map=inline`).

## Managing Load Paths & Working Directories
- Add search paths via CLI flags (repeat `-I` or use platform delimiters):
  ```bash
  zsass -I shared/styles -I ../vendor/sass src/app.scss
  ```
- Provide default load paths through the Sass-compatible `SASS_PATH` env var before running your build scripts:
  ```bash
  export SASS_PATH="shared/styles:../vendor/sass"  # use ; instead of : on Windows
  zsass src/app.scss dist/app.css
  ```
- Confirm what the process will search without doing any compilation:
  ```bash
  zsass --list-load-paths
  ```
  The output is the effective load-path list assembled from repeated `-I` flags and `SASS_PATH`.
- Use `--chdir` (or `-C`) when invoking zsass from monorepo tooling that runs in
  a higher-level directory:
  ```bash
  zsass -C frontend/styles app.scss ../build/app.css
  ```
## Inspecting Environment Defaults
- Print the build metadata and effective load paths as JSON:
  ```bash
  zsass --env-report | jq
  ```
  The payload includes the zsass version, Zig optimize mode, Zig version, and the active load-path list.

## Environment Variable Cheat Sheet

When you cannot touch the CLI flags directly, seed the supported defaults via env vars.

| Variable | Accepts | Effect | Compatibility |
| --- | --- | --- | --- |
| `SASS_PATH` | Platform-delimited `dir[:dir2...]` (`;` on Windows) | Appends default search roots after any `-I` flags so shared partials resolve consistently. | Sass-compatible. |
| `ZSASS_CSS_CACHE` | `0` or `false` | Disables the internal CSS cache. | zsass-specific. |
| `ZSASS_CSS_CACHE_DIR` | directory path | Overrides the internal CSS cache directory. | zsass-specific. |
| `ZSASS_CSS_CACHE_STRICT` | `1` / `true` | Forces a SHA-256 content recheck of every cached source on lookup. | zsass-specific. |
| `ZSASS_TRACE_SLOT` | integer slot | Enables VM slot tracing for diagnostics. | Developer-only. |

### CSS cache trade-offs

The internal CSS cache is **enabled by default** when the entry path, the
output path, and the run mode all support it (no source map, no stdin, no
trace-diff, no observability flags, no `ZSASS_CSS_CACHE=0`). Cache freshness
checks compare each source's `(size, mtime)`; a content hash is only
recomputed when the recorded mtime differs from disk, or when
`ZSASS_CSS_CACHE_STRICT=1` is set. That makes warm rebuilds fast but means
an edit that preserves both size and mtime — for example
`touch -r original copy && cp -p`, certain `git restore` paths, or an
in-place editor that resets mtime — can still serve cached CSS until the
next genuine change. Set `ZSASS_CSS_CACHE_STRICT=1` for builds where this
trade-off is unacceptable, or disable the cache entirely with
`ZSASS_CSS_CACHE=0`.

`--update` reuses the same cache manifest: when the manifest exists and
every dependency's `(size, mtime[, hash])` is intact, the entry is skipped
even though only `app.scss`'s own mtime has been updated. With the cache
disabled (`ZSASS_CSS_CACHE=0`) or unavailable (source map mode, stdin,
trace-diff, etc.), `--update` falls back to the entry-file mtime check and
will not notice partials that were edited without touching the entry —
re-run without `--update` (or rely on `--watch`) when that happens.

Installer helpers respect a few additional knobs: `ZSASS_INSTALL_PREFIX` and
`ZSASS_INSTALL_OPTIMIZE` override the default prefix/optimization in
`scripts/install_cli.sh`, while `ZSASS_GLOBAL_CACHE_DIR` lets reproducible build
setups reuse a shared Zig cache across invocations.

## CI-Friendly Checks
Grab a turnkey GitHub Actions + cache recipe in `docs/ci.md` if you need to drop the CLI into CI without reinventing the workflow.

- Catch syntax errors without writing output (combine with `input:output`
  pairs to validate multiple targets in one invocation):
  ```bash
  zsass --check src/app.scss
  zsass --check src/app.scss:dist/app.css src/admin.scss:dist/admin.css
  ```
- Preview how zsass will expand compile targets, style, and load paths (great for debugging CI
  runners that manipulate `$PWD`):
  ```bash
  zsass --dry-run=json src:dist | jq '.load_paths'
  ```
- Report configured load paths as plain text:
  ```bash
  zsass --list-load-paths
  ```

## Machine-Readable Output Hooks
Use the JSON variants whenever you need structured data:
use `--version=json`, `--info=json`, `--env-report=json`, or `--dry-run=json`.

| Command | What it returns |
| --- | --- |
| `zsass --version=json` | `{ "name": "zsass", "version": "...", "implementation_name": "zsass", "implementation_version": "..." }` |
| `zsass --info=json` | `{ "name": "zsass", "version": "...", "zig": "0.16.0", "target": "x86_64-linux-gnu", "optimize": "ReleaseFast", "exe_path": "/home/me/.local/bin/zsass", ... }` |
| `zsass --dry-run=json` | Effective inputs, outputs, style, and load paths |
| `zsass --list-load-paths` | One effective load path per line |

These are stable entry points for coordinator scripts or editor plugins that
need to introspect configuration before invoking the compiler.

`--info` is especially handy when packaging binaries for CI/CD - record the JSON
payload once to confirm the Zig toolchain, target triple, libc/threading
choices, and the exact on-disk executable path match what your environment
expects (the text output prints the `exe:` line too).

## Deprecation Flags

zsass now parses the three deprecation flags with one shared grammar:

```bash
zsass --silence-deprecation=import,slash-div input.scss
zsass --future-deprecation=<id1>,<id2> input.scss
zsass --fatal-deprecation=1.55.0,import input.scss
```

- `--silence-deprecation` and `--future-deprecation` accept comma-separated
  deprecation IDs and may be repeated.
- `--fatal-deprecation` accepts the same IDs plus full Sass versions like
  `1.55.0`. A version expands to every supported deprecation that was already
  active in or before that Dart Sass release.
- Unknown values are treated as errors instead of being ignored.

## Shell Completions
- Need disposable completion files without touching your home directory? Run `zig build completions-bash`, `completions-zsh`, or `completions-fish` to generate the scripts under `zig-out/completions/` (making it easy to inspect them into CI artifacts). `zig build completions` runs all three so onboarding guides can copy from `zig-out/completions/` without invoking the CLI directly.
- Use the helper script when you want a one-liner install (it writes to `~/.config` and prints sourcing tips):
  ```bash
  scripts/install_completions.sh bash
  scripts/install_completions.sh --shell zsh --bin zig-out/bin/zsass
  scripts/install_completions.sh fish   # auto-installs to ~/.config/fish/completions/
  ```
  Pass `--output <path>` if you prefer a different destination.
- Bash: `zsass --completions bash > ~/.config/zsass/completions.bash` and
  `source ~/.config/zsass/completions.bash` (or add it to your shell startup
  file). The function suggests all primary flags plus the structured values for
  `--style`, `--list-load-paths`, `--dry-run`, `--source-map-urls`, and
  `--completions`.
- Zsh: `zsass --completions zsh > ~/.config/zsass/completions.zsh` and add
  `source ~/.config/zsass/completions.zsh` to `.zshrc`. The script wraps
  `bashcompinit`, so no extra tooling is required; just ensure the file is
  sourced after `autoload -U +X bashcompinit && bashcompinit` (the generated
  snippet already performs that step).
- Fish: `zsass --completions fish > ~/.config/fish/completions/zsass.fish`
  instantly wires completions into fish (any file placed under
  `~/.config/fish/completions/` is autoloaded). The generated file covers the
  high-signal flags plus value suggestions for `--style`, `--source-map-urls`,
  and other enum-style switches.
