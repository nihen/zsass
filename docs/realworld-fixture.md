# Real-World Fixture Runner

This repo keeps the runner, not the private assets. Real-world Sass trees, fixed Dart Sass outputs, and perf baselines live in an external private fixture repo, and `zsass` can run against those local suites through `zig build`.

## Commands

```bash
zig build realworld
```

By default, `realworld` does one `zsass` compile per entry, validates the CSS output, and records elapsed time and RSS from that same invocation. If the full check passes and a fixed Dart Sass baseline exists, it also prints ratio reports.

If `../zsass-realworld-fixtures/` contains multiple suite directories, plain `zig build realworld` runs all of them in sorted order. Point `--suite-root` at one suite directory when you want to scope the run.

Extra options are passed after `--`.

```bash
zig build realworld -- --help
zig build realworld -- --fail-fast
zig build realworld -- --jobs 16
zig build realworld -- --mode bench --runs 5
zig build realworld -- --suite-root ../zsass-realworld-fixtures/<suite-name>
```

Modes:

- `check`
  The normal mode. Compile with `zsass`, compare against fixed reference CSS, and only if everything matches print perf ratios against the fixed Dart Sass baseline. This mode uses 8 workers by default and shows a live `[check] elapsed n/m % file` progress counter.
- `bench`
  Dedicated benchmark mode. Re-runs each entry serially and reports median elapsed time and RSS against the fixed Dart Sass baseline.

The default mode is `check`.

## Default Fixture Location

The default lookup root is the repo sibling `../zsass-realworld-fixtures/`.

Example:

```bash
cd ..
git clone <private-fixture-repo> zsass-realworld-fixtures
cd zsass
zig build realworld
```

That default also works when the fixture repo contains multiple suites. In that case `zig build realworld` runs every child suite under that directory. Pass one suite directory explicitly with `--suite-root` when you want a narrower run.

If you do not want to use that sibling path at all, override it with `--suite-root` or `ZSASS_REALWORLD_SUITE_ROOT`.

```bash
ZSASS_REALWORLD_SUITE_ROOT=/abs/path/private-fixtures zig build realworld
zig build realworld -- --suite-root ../zsass-realworld-fixtures/<suite-name>
```

## suite.env

Each suite directory must contain a `suite.env` file with shell-style variables.

### layout=tree

Use this for a fixed snapshot with one source tree and one expected-output tree.

```bash
layout=tree
suite_name=main-site
source_dir=source
expected_dir=expected
entries_file=entries.txt
perf_baseline=perf.tsv
perf_baseline_wall_sec=12.34
perf_baseline_jobs=8
compile_timeout=60
bench_timeout=30
```

- `source_dir`
  The source tree. If `entries.txt` exists it is used as an explicit override. Otherwise the runner asks `zsass --dry-run=json` to expand the directory, then collapses colliding output paths so each expected CSS file is checked once.
- `expected_dir`
  The fixed Dart Sass CSS outputs. The runner compares against `<expected_dir>/<entry>.css`.
- `perf_baseline`
  Fixed Dart Sass measurements. The TSV only needs `rel_path`, `dart_sec`, and `dart_rss_kb` as its first three columns. In normal `check` mode this is used only for reporting after CSS validation succeeds.
- `perf_baseline_wall_sec`
  Optional fixed Dart Sass suite wall time. Use this when you want the top-level wall-time summary to compare against a parallel Dart Sass run instead of the serial per-entry sum.
- `perf_baseline_jobs`
  Optional worker count paired with `perf_baseline_wall_sec`, for example `8`.

### layout=samples

Use this when each source file has its own `*.ref.css` neighbor.

```bash
layout=samples
suite_name=sample-matrix
samples_dir=samples
reference_suffix=.ref.css
perf_baseline=perf.tsv
```

- `samples_dir`
  A root containing multiple projects.
- `reference_suffix`
  The reference CSS suffix. The default is `.ref.css`.

Auto-discovery is based on `zsass` directory compilation semantics. That means it sees `.scss`, `.sass`, and plain `.css` entrypoints and only excludes files whose basenames begin with `_`. If multiple inputs would write the same output path, the runner keeps one check target for that output and prefers `.scss` or `.sass` over plain `.css`.

## load_paths.txt

Use `load_paths.txt` when the suite needs extra load paths. Add one path per line, either relative to the suite root or absolute.

```text
compat
overlay
```

For `tree`, `source_dir` is added automatically. For `samples`, the project root of each entry is added automatically. `load_paths.txt` is for anything extra before that.

## Output

By default, each invocation writes to `<suite-root>/.zsass-realworld-runs/<suite_name>/<mode>/<run-id>/` and refreshes a `latest` symlink beside it. Use `--work-root` if you want a different history root.

- `check/actual/`
  Latest `zsass` outputs
- `check/logs/`
  Compile logs
- `check/diffs/`
  Unified diffs for mismatches
- `check/perf-report.tsv`
  Inline perf report from the same compile used for correctness checks
- `bench/perf-results.tsv`
  Dedicated benchmark results

Each run gets its own timestamped directory. The runner no longer deletes previous runs by default.
