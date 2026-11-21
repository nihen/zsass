# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

Tracks Dart Sass 1.108.2. The vendored `sass-spec` pin moves to
`acbdcd391`.

### Changed
- CSS escapes for U+0000, surrogates, and values past U+10FFFF become
  U+FFFD in expressions and selectors instead of an error or an escaped
  spelling (Dart Sass 1.106.0). An identifier that is exactly `\0` is still
  written as `\0 `.
- Function, mixin, variable, parameter, and unit names treat every escaped
  spelling of a name as the same name, so `\24` and `\$` name one member,
  `$a\5f b` is `$a-b`, and `1\65 m` equals `1em` (Dart Sass 1.106.0). A
  string passed to `sass:meta` functions or used as a keyword in a map
  splat is matched as written: `"\\$"` finds that member while `"$"` and
  `"\\24"` do not (Dart Sass 1.108.0).
- An unquoted string built at runtime, such as `string.unquote("\\24")`,
  and the prelude of an unknown at-rule are emitted as written rather than
  with their escapes re-normalized (Dart Sass 1.106.0).
- A plain CSS function call prints its name with escapes decoded, and an
  escaped spelling of `url`, `!important`, `!default`, or `!global` is
  recognized as the plain one (Dart Sass 1.106.0).
- Escapes in the arguments of special functions are canonicalized when the
  value is compiled: `url(\41)` is `url(A)`, and `element(\31)` keeps
  `\31 ` (Dart Sass 1.106.0).
- A unit that reads like an exponent is serialized with an escaped `e`, such
  as `1\65 1` for the unit `e1` (Dart Sass 1.106.0).
- `meta.module-functions()` and `meta.module-mixins()` return maps keyed by
  quoted strings, and `meta.inspect()` writes a function or mixin reference
  as `get-function("name")` without a `$module` argument.
- `even`, `odd`, and `n` in `:nth-child()` and `:nth-last-child()` are
  written lowercase, with escaped letters decoded.
- Private-use code points U+FFFFE, U+FFFFF, U+10FFFE, and U+10FFFF are
  written as escapes in expanded output, like the rest of planes 15 and 16.

### Fixed
- A parameter list that declares the same parameter twice is an error
  ("Duplicate parameter."), including when one of them is a rest parameter
  (Dart Sass 1.106.0).
- In the indented syntax, an indented first statement is an error wherever
  in the file it appears (Dart Sass 1.106.0).
- A surrogate escape such as `\d800` in a declaration value no longer
  crashes the compiler.
- A string literal with escapes is no longer compared or concatenated as
  source text when an expression is folded at compile time, so a top-level
  `@if \61 == a` is true. A module configured with such a literal
  (`@use "m" with ($a: "\61")`) receives its decoded value.
- `-\41` is the identifier `-A` rather than a negated `\41`.

## 0.4.1 (2026-10-21)

### Fixed
- A loud comment before `@use` or `@forward` is emitted once, even when a
  later module loads the same dependency again (Dart Sass 1.104.1).
- `%` with a negative divisor returns a result with the divisor's sign in
  release builds, such as `-3` for `1 % -4`. Earlier release binaries
  returned the dividend's remainder instead (`1`).

## 0.4.0 (2026-10-21)

Tracks Dart Sass 1.105.2. The vendored `sass-spec` pin moves to
`530e761ec`.

### Added
- First-class modules (Dart Sass 1.105.0): `meta.load()` and
  `meta.get-module()` return module values, which `meta.css()` and the
  `$module` argument of `sass:meta` functions such as
  `meta.module-variables()` and `meta.function-exists()` accept.

### Changed
- Exact negative zero is serialized as `-0` (Dart Sass 1.104.0).
  `math.sqrt()`, `math.pow()`, `math.log()`, and the trigonometric functions
  keep the sign of a zero result. Zero `%`/`mod()` results are positive, and
  zero `rem()` results are negative when the operand signs differ.
- Legacy `rgb()`/`rgba()` colors with a non-integer channel are serialized
  with percentage channels (Dart Sass 1.101.4).
- rec2020 uses the 2.4 gamma transfer function (Dart Sass 1.102.0).
- Color space conversions preserve analogous sets of missing channels, and
  NaN, negative zero, and infinite polar hues become 0 (Dart Sass 1.103.0,
  1.104.0).
- A type selector written directly after another compound (`[a]b`) starts a
  new compound joined by a descendant combinator (Dart Sass 1.100.0). The
  `adjacent-compounds` deprecation warning is not emitted yet.
- Color conversion matrices and hue normalization match Dart Sass to the
  last bit for far out-of-range channels, and rec2020 converts to OKLab
  directly through LMS.
- Plain-CSS `if()` branch values use their CSS serialization, so quoted
  strings keep their quotes (Dart Sass 1.101.4).

### Fixed
- `@extend` inside `@media` no longer applies to rules in a different media
  query; it fails with "You may not @extend selectors across media
  queries.", and extending the same selector from different media queries
  fails as in Dart Sass 1.105.1.
- A `/` right after a `:` in a variable value parses as a unary slash.
- A variable value starting with an at-rule keyword is rejected.

## 0.3.5 (2026-07-07)

### Added
- `CompileFileResult.err_css` in the batch embedding API (`compileFiles`):
  a CSS payload for failed entries that renders the diagnostic as a comment
  plus a `body::before` rule, so embedders that write compile output to disk
  can mirror the CLI's `--error-css` behavior and surface the error on the
  page instead of silently serving stale CSS. Parse errors in the entry file
  reconstruct the inner-most source frame (file, line, caret) the same way
  the CLI does; resolver/VM errors reuse the rendered diagnostic including
  the `@use`/`@import` trace.

## 0.3.4 (2026-07-04)

### Fixed
- Report errors inside `@import`-inlined files at their actual file and
  position with a dart-sass compatible stack trace (`{inner} l:c @import` /
  `{parent} l:c root stylesheet`). Previously the inner file's span was
  projected onto the parent source, producing a bogus location in the
  importing file.

### Added
- `CompileFileResult.err_rendered` in the batch embedding API
  (`compileFiles`): a dart-style rendered diagnostic (message, inner-most
  source frame, and the `@import`/`@use` chain) for failed entries, so
  embedders such as build watchers can show the full error instead of a
  bare error tag.

## 0.3.3 (2026-06-10)

### Changed
- Improve real-world batch compilation throughput by optimizing resolver, VM,
  driver, emitter, builtins, and selector extend hot paths (#20).
- Add import preamble checkpoint reuse and pure-top module state replay across
  batch entries, with guards for configuration, `meta.load-css`, and stateful
  builtins (#20).
- Reduce hot lookup, selector/declaration scan, map, unit, and VM dispatch
  overhead while preserving Sass semantics (#20).

## 0.3.2 (2026-05-19)

### Added
- Publish multi-arch Linux container images to GitHub Container Registry,
  built from the signed GitHub Release archives with SHA256 verification.
- Add a manual workflow for publishing GHCR images for existing release tags.

### Changed
- Document GHCR usage and package the container image on Debian 13
  `trixie-slim` with the project MIT license included in the image.

## 0.3.1 (2026-05-18)

### Fixed
- Improve Sass output compatibility for selector extension, color conversion
  and formatting, calculations, and module resolution edge cases (#16).
- Prevent configured modules from leaking through persistent resolver reuse
  when batch entries may reach `@use ... with (...)` directly or through
  imported sources (#16).
- Harden sass-spec expected-error matching so generic Sass nouns such as
  `function`, `mixin`, and `variable` no longer mask clear diagnostic
  mismatches (#16).

### Changed
- Make real-world fixture normalized CSS comparison diagnostic-only; raw CSS
  differences remain failures (#16).
- Remove project/fixture-specific compatibility shortcuts and replace them
  with general Sass/CSS semantics backed by sass-spec or clean-room Sass CLI
  observations (#16).
- Harden disposable fixture source checks so GitHub SSH/scp URLs for
  prohibited clean-room sources are normalized before denylist validation
  (#16).

## 0.3.0 (2026-05-11)

### Removed
- Drop non-spec `sass:string` / `sass:math` members
  (`string.string`, `string.contains`, `string.replace`, `math.exp`,
  `math.sign`, `math.mod`, `math.rem`) and the legacy globals
  `str-contains` / `str-replace`. Dart Sass treats every one of these
  as undefined; zsass now matches. CSS Values L4 globals
  (`mod()`, `rem()`, `exp()`, `sign()`) still resolve as bare names
  (#14).

## 0.2.0 (2026-05-10)

### Added
- Native filesystem watcher: inotify / kqueue / ReadDirectoryChangesW
  per OS (#9).
- Batch compile keeps going after a failure and reports every error
  (#6).
- Watch prints `[ts] Compiled X to Y.` per file and rebuilds only the
  entries whose `@import` chain changed (#7, #8).

### Fixed
- Batch compile no longer SEGVs on unresolved `@import` (#5).
- Repeated stdio writes append in order when redirected (#7).
- Path splitter handles Windows drive-letter paths (#10).

### Changed
- Watch banner: `zsass is watching for changes.` (#7).
- Release pipeline self-drives via `auto-tag` + chained homebrew
  job (#12).

## 0.1.1 (2026-05-10)

### Documentation
- Overhaul `--help` output: document `<input_dir>:<output_dir>`
  directory mode, drop silently-noop flags from the visible options,
  regroup flags into Diagnostics / Source maps / Input syntax / Build
  behavior sections, and list `ZSASS_CSS_CACHE_STRICT` in the
  Environment block.
- Regenerate bash/zsh/fish completion scripts to cover the full public
  flag set with value-enum completion (and fix a malformed
  `--dry-run=json` entry in the fish script).
- Add a directory-compilation example to `docs/cli.md`.

### Removed
- Drop the unimplemented `--exec` dispatch (the bytecode runner was
  never wired up and only ever exited 64).

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
