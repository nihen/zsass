# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.1.0 (2026-05-10)

Initial public release.

### Features
- SCSS and indented `.sass` compilation (lexer -> parser -> Rule IR ->
  VM-based evaluator) without an external libsass / dart-sass runtime.
- Passes the upstream `sass-spec` suite vendored in this release at the
  pin in `tests/sass-spec`: 13,885 / 13,885 cases pass, 6 skipped.
  Compatibility outside cases the suite covers may diverge from
  dart-sass.
- Module system: `@use`, `@forward`, `@import` (legacy).
- Full builtin coverage: `sass:math`, `sass:string`, `sass:list`,
  `sass:map`, `sass:selector`, `sass:meta`, `sass:color`.
- CSS Color Level 4 spaces: `oklab`, `oklch`, `lab`, `lch`, `hwb`,
  `color()`.
- `@extend` with compound unification and recursive extension into
  `:not()` / `:has()`.
- CLI flags compatible with dart-sass: `--style`, `--color`, `--quiet`,
  `--watch`, `--update`, `--load-path`, `--embed-source-map`,
  `--indented` / `--no-indented` / `--scss` / `--plain-css`,
  `--check` / `--dry-run`, `--compile-only`, `--source-map`,
  `--source-map-file`, `--source-map-url`, `--source-map-urls`,
  `--embed-sources`, etc. POSIX `--` terminator is honoured. `--check`
  runs the full parse / resolve / compile / VM / emit pipeline and
  discards the rendered CSS, so `@error`, runtime evaluation, and
  emission failures still surface. `--update` consults the CSS-cache
  manifest when available so changes to imported partials trigger a
  rebuild even though the entry's mtime did not change.
- Source map v3 emission (detached or embedded), `sourcesContent`
  optional.
- Directory and glob compilation.
- Embeddable Zig API (`@import("zsass")`) with structured diagnostics:
  `CompileOptions.diagnostic_sink` runs alongside the legacy fd sink
  and receives `Diagnostic{ level, message, code, file, line, column,
  end_line, end_column }` payloads.
- Shell completions for bash / zsh / fish.
- Cross-platform release binaries: Linux x86_64 / aarch64, macOS
  x86_64 / aarch64, Windows x86_64. Each archive ships a sibling
  `.sha256`, plus `.sig` / `.pem` for Sigstore (cosign) verification.
