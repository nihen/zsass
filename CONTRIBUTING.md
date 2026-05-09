# Contributing to zsass

Thanks for taking the time to look at zsass. Patches, bug reports, and
sass-spec compatibility findings are all welcome.

## Clean-room policy (please read first)

zsass is a clean-room Sass implementation. **Contributors must not read,
copy, or paraphrase the Dart Sass source code**, including vendored
copies, decompiled artifacts, or AI-generated derivatives of it. Sass
behavior is verified through two channels only:

1. The upstream [`sass-spec`](https://github.com/sass/sass-spec) suite,
   vendored as a submodule under `tests/sass-spec`.
2. The observable input / output of the official `sass` CLI invoked from
   the shell.

If a behavior is unclear, write a minimal `.scss` reproducer and run it
through `sass`. Don't infer it from Dart Sass source.

This policy is not negotiable - it protects the project's license
position. PRs that look like they may have referenced Dart Sass source
will be closed.

## Toolchain

- **Zig:** 0.16.0 or newer (see `.minimum_zig_version` in
  `build.zig.zon`).
- **Git submodules:** sass-spec is required for spec tests:
  ```bash
  git submodule update --init
  ```

## Build & test

```bash
zig build                # debug build (zig-out/bin/zsass)
zig build unit-test      # in-source unit tests (fast, no sass-spec)
zig build test           # unit + full sass-spec suite
zig build spec -- --filter "your-filter"   # focused sass-spec run
zig fmt --check src/ tests/spec_runner.zig examples/ build.zig
```

The pre-merge checklist is just three commands:

```bash
zig fmt --check src/ tests/spec_runner.zig examples/ build.zig
zig build unit-test
zig build test           # only required when behavior may affect spec
```

If a change is large enough to need real-world validation, run the
external fixture suite (set up per `docs/realworld-fixture.md`):

```bash
zig build realworld
```

## Style

- **English-only ASCII** in source, comments, and identifiers
  (`src/**`, `tests/**`, `examples/**`, `build.zig`). User-facing docs
  (`README.md`, `CHANGELOG.md`, `docs/**`) are also English.
- Default to **no comments**. Add one only when the *why* is non-obvious -
  a hidden constraint, a subtle invariant, or a documented workaround.
- Prefer editing existing files over creating new ones. Don't add
  speculative abstractions, fallbacks, or feature flags for hypothetical
  futures.
- Keep functions small and named for what they do.
- Don't introduce backwards-compatibility shims for unreleased internal
  APIs - just change the code.

## Commits & PRs

- Open a pull request against `main`; do not push directly.
- Keep commits focused. Don't piggyback unrelated refactors onto a bug
  fix.
- Include reproducer / test in the same commit as the behavior change
  whenever practical.
- Don't skip pre-commit / pre-push hooks (`--no-verify`,
  `--no-gpg-sign`, etc.) without an explicit reason in the PR
  description.
- The PR description should answer: *what* changed, *why*, and *how it
  was tested*.

## Release pipeline notes

Two pieces of release tooling intentionally cover different contexts:

- `.github/workflows/release.yml` is the canonical pipeline. It runs on
  hosted runners with a per-target matrix and produces the artifacts
  attached to GitHub releases.
- `scripts/build-release.sh` is a **local-only** helper that builds all
  five targets in one shot for smoke-testing before tagging.

The `targets=(...)` list and the bundled side-files (`README.md`,
`CHANGELOG.md`, `LICENSE`) must stay in sync between the two. CI does
not diff them; if you change one, mirror the change in the other in the
same commit.

Asset filenames intentionally differ: `build-release.sh` uses the
zig-target string (`zsass-0.1.0-x86_64-linux-gnu.tar.gz`) while
`release.yml` uses an `os-arch` form prefixed with `v`
(`zsass-v0.1.0-linux-x86_64.tar.gz`). The mismatch is a feature - it
keeps a locally-built smoke archive from being mistaken for a published
release artifact.

## Reporting bugs

Use the `Bug report` issue template at
<https://github.com/nihen/zsass/issues/new/choose>. The most valuable
information is:

- Output of `zsass --version` and `zsass --info`.
- The `dart-sass` version you compared against, if relevant.
- A minimal `.scss` reproducer (5-15 lines is plenty in most cases).
- The exact CLI command that triggered the behavior.

For sass-spec-shaped failures, copy the smallest matching `.hrx` slice
into the issue if you can; that makes the gap easy to triage and turns
into a regression test.

## Security issues

Please do **not** file a public issue. See [SECURITY.md](SECURITY.md)
for the private reporting channels.

## Code of conduct

Be excellent to each other. Disagree on technical merit, not on people.
We follow the spirit of the
[Contributor Covenant v2.1](https://www.contributor-covenant.org/version/2/1/code_of_conduct/);
maintainers reserve the right to remove abusive comments and ban repeat
offenders.
