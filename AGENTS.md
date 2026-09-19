# zsass

Clean-room Sass implementation in Zig 0.16+.

## Non-negotiable clean-room boundary

- Do not read, quote, or derive code from Dart Sass source, vendored copies, or decompiled artifacts.
- Determine behavior from Sass documentation, the vendored `tests/sass-spec` suite, and observable input/output of the official `sass` CLI only.
- When behavior is unclear, create a minimal `.scss` reproducer and compare CLI output.

## Compiler semantics

Real-world fixtures expose general Sass bugs; they must not define compiler behavior.

- Do not add package-, project-, theme-, framework-, helper-, vendor-, or fixture-specific branches under `src/**`.
- A semantic fix needs evidence from the specification, sass-spec, or a minimal clean-room reproducer verified with the official CLI.
- Reduce failures to Sass semantics before fixing them. Do not skip, normalize away, or special-case a failing fixture.
- Environment-only fixture workarounds belong in `scripts/**` or fixture metadata and must not hide compiler errors or CSS differences.
- For a semantic audit or a compatibility fix before commit, read [docs/agent/semantic-audit.md](docs/agent/semantic-audit.md).

## Build and verification

```bash
zig build
zig build unit-test
zig build test                    # full sass-spec; use for semantic/spec changes
zig build -Doptimize=ReleaseFast
zig build realworld               # external fixtures in ../zsass-realworld-fixtures
```

Initialize `tests/sass-spec` with `git submodule update --init` after cloning. Run verification proportionate to the changed behavior; a compiler-semantic change requires the relevant unit/spec coverage.

## Repository conventions

- `src/frontend`, `src/ir`, `src/resolve`, `src/runtime`, `src/selector`, `src/builtin`, and `src/color` contain the compiler subsystems.
- User-facing documentation (`README.md`, `CHANGELOG.md`, `docs/**`) is English.
- Code identifiers and comments are English ASCII. Add comments only for non-obvious constraints or rationale.
- Keep a focused change focused. Do not introduce speculative compatibility shims for unreleased internal APIs.
- Do not bypass Git hooks. Do not push directly to `main` when collaborating.
