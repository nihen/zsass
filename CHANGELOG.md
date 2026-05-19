# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
