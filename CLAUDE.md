# Agent Notes for zsass

These instructions are for Claude Code, codex, cursor-agent, or any other
LLM-based assistant working on this repository. Human contributors can read
them too - they are short on purpose.

## Clean-room Policy (MUST)

zsass is a clean-room Sass implementation.

- **Do not read Dart Sass source.** That includes the `sass/dart-sass`
  GitHub repo, vendored copies, decompiled artifacts, or any code derived
  from it. Treat its source as if it were proprietary.
- Sass behavior is verified two ways only: (1) the upstream
  [`sass-spec`](https://github.com/sass/sass-spec) suite (vendored as a
  submodule under `tests/sass-spec`), and (2) the observable input/output
  of the official `sass` CLI invoked from the shell. Both are allowed.
- Specifications come from <https://sass-lang.com/documentation>.
- If a behavior is unclear, write a minimal `.scss` reproducer and run it
  through `sass`; do not infer it from Dart Sass source.

This policy avoids license contamination and is non-negotiable.

## Repository Layout

- `src/` - compiler, organized as `frontend/` (lexer/parser/AST),
  `ir/` (rule IR + compiler), `resolve/` (`@use`/`@forward`/`@import`),
  `runtime/` (VM, value, intern pool, driver, I/O), `selector/`
  (selector engine + `@extend`), `builtin/` (Sass standard library),
  `color/` (color types and conversion).
- `tests/sass-spec/` - submodule. Run `git submodule update --init` after
  cloning.
- `tests/spec_runner.zig` - sass-spec test runner.
- `examples/` - embeddable API samples.
- `docs/` - user-facing docs.
- `scripts/` - installer scripts and the cross-compile release helper.

## Build / Test

Requires Zig 0.16+.

```
zig build                                        # Debug
zig build -Doptimize=ReleaseFast                 # release binary
zig build unit-test                              # in-source unit tests
zig build test                                   # full sass-spec
zig build install --prefix ~/.local              # install to ~/.local/bin
zig build realworld                              # external fixture runner
                                                 # (../zsass-realworld-fixtures)
```

Cross-compile release tarballs (linux x86_64/arm64, macOS x86_64/arm64,
windows x86_64) live in `scripts/build-release.sh`.

## Code Style

- **Comments and identifiers in code: English only (ASCII).** This applies
  to `src/**`, `tests/**`, `examples/**`, `build.zig`, and any Zig source.
  User-facing docs (`README.md`, `CHANGELOG.md`, `docs/**`) are also
  English.
- Default to writing no comments. Add one only when the *why* is
  non-obvious - a hidden constraint, a subtle invariant, or a documented
  workaround. Don't narrate what well-named code already shows.
- Prefer editing existing files over creating new ones. Don't add
  speculative abstractions, fallbacks, or feature flags for hypothetical
  futures.
- Keep functions small and named for what they do.

## Working Habits

- Keep changes minimal and focused. Don't piggyback unrelated refactors
  onto a bug fix.
- Run `zig build && zig build unit-test` (and `zig build test` for spec
  changes) before declaring done.
- Don't introduce backwards-compatibility shims for unreleased internal
  APIs - just change the code.
- Don't skip pre-commit / pre-push hooks (`--no-verify`, `--no-gpg-sign`,
  etc.) without an explicit, written reason from the maintainer.
- Don't push to `main` directly when collaborating; open a pull request.
