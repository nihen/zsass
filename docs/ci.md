# zsass CI adoption guide

Developers embedding zsass in bigger build graphs often need a copy-pasteable
pipeline to build the CLI once and reuse it for smoke checks or `--check`
runs. Use the snippets below as starting points.

## GitHub Actions: build once, reuse everywhere

```yaml
name: sass-check

on:
  push:
    branches: [main]
  pull_request:

jobs:
  sass:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: mlugg/setup-zig@v2
        with:
          version: 0.16.0 # matches build.zig.zon .minimum_zig_version
      - name: Cache compiled artifacts
        uses: actions/cache@v4
        with:
          path: |
            .zig-global-cache
            ~/.local/bin/zsass
          key: zsass-${{ runner.os }}-${{ hashFiles('build.zig', 'build.zig.zon', 'scripts/install_cli.sh') }}
      - name: Build & install zsass
        run: |
          scripts/install_cli.sh --prefix "$HOME/.local" --optimize ReleaseFast
      - name: Run style checks
        run: |
          ~/.local/bin/zsass --check src/app.scss:dist/app.css
```

### Why this layout?
- `setup-zig` pins the Zig toolchain so CI and dev machines match the
  `.minimum_zig_version` declared in `build.zig.zon`.
- `scripts/install_cli.sh` builds and installs a ReleaseFast binary once,
  setting you up for follow-up steps that just call `zsass ...`.
- The cache block restores the installer helper's `.zig-global-cache` before the build and also persists the installed binary for later jobs.
- The final command runs your preferred invocation (`--check`,
  `zsass src:dist`, etc.). Swap in multiple lines if you need a batch run.

### Ready-to-copy workflow file

Prefer cloning a complete workflow instead of copying snippets? `examples/ci-gh-action.yml`
is a drop-in file you can place under `.github/workflows/zsass.yml`. It:

1. Pins Zig via `mlugg/setup-zig`.
2. Builds and installs zsass with `scripts/install_cli.sh`, reusing `ZSASS_GLOBAL_CACHE_DIR`
   so caches stay warm between runs.
3. Reads `ZSASS_CHECK_TARGETS` (colon-delimited `input.scss:output.css` pairs) to run
   `zsass --check` for every entrypoint, grouping the logs for readability.
4. Runs `zig build api-smoke` at the end so API consumers verify their embedding path too.

Edit the `env` block in that file to match your paths (for example, change
`ZSASS_INSTALL_PREFIX` if you install to `$HOME/.local`). Add more entries under
`ZSASS_CHECK_TARGETS` to validate multiple Sass inputs without duplicating steps.

## Reusing the API example in CI

Need to ensure downstream code that embeds zsass keeps compiling? Add another
step that runs the shipped example executable:

```yaml
      - name: API smoke test
        run: zig build api-example
```

`zig build api-example` builds the sample at `examples/embed_basic.zig` and
executes it immediately. A failing invocation will stop the job, so you get
confidence that the public API stayed stable for consumers.

## General tips for other CI providers
- Always set `ZSASS_GLOBAL_CACHE_DIR` (or pass `--global-cache-dir`) to a
  location the host can cache between runs (e.g. `/tmp/zig-cache` on Buildkite
  agents). That drops repeated install times sharply.
- Pair `scripts/install_completions.sh` with your install step when runners
  publish artifacts people will download interactively; shell completions ride
  along automatically.
- Remember that the CLI supports `input:output` pairs in a single process. In a
  matrix build, pass the per-target pair via `${INPUT}:${OUTPUT}` to cut down on
  redundant `zsass` processes.
