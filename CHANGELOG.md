# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.5.2 (2026-11-28)

### Fixed
- A `calc()` with a variable no longer adds units of different kinds as
  if they converted: `calc($x + 2ms)` with `$x: 1px` gave `1.002px`.
- A `calc()` with interpolation, such as `calc(#{2} * 1px + 1s)`, is kept
  as CSS instead of failing.
- Units are case-sensitive, as in the official CLI: `1PX + 1in` and
  `1Px + 1px` fail with incompatible units instead of converting, and the
  known units are spelled `q`, `Hz`, and `kHz`.
- A top-level read of a global that only an unrun `!global` in a flow
  block sets fails with "Undefined variable.", as one in a callable does.
- A function or mixin that reads a global only a `!global` assignment
  inside a callable or flow block sets, which has not run, fails with
  "Undefined variable." instead of reading null.
- Deprecation warnings from built-in functions are located where the
  function was called, instead of at `0:0`.
- `math.random()`, `list.nth()`, and `list.set-nth()` warn
  (`function-units`) about a number with a unit they ignore, and only the
  global `abs()` warns (`abs-percent`) about a percentage, not
  `math.abs()`, as the official CLI does.
- A parameter default that reads a variable nothing has set, such as
  `@mixin m($x: $u)`, fails with "Undefined variable." instead of an
  internal compiler error.
- A new variable assigned in a top-level `@if` or loop stays in that
  block even when a function or mixin names a global of that name, so the
  mixin's read is undefined, as in the official CLI.
- `meta.load-css()` passes a configured number with a unit, such as
  `$with: (u: 2px)`, to the module; it was lost, leaving the default or
  nothing.
- `min()`, `max()`, `math.min()`, and `math.max()` compare numbers with
  compound units, such as `calc(1px * 1px)` or `1px / 1s`, when every
  unit factor converts, instead of failing; incompatible ones report
  `calc(1px * 1px) and 1px have incompatible units.` as the official CLI
  does.
- `meta.get-function("min")` and `"max"` return the Sass functions, which
  refuse incompatible units and `var()`, as the official CLI does; a plain
  `min()` call still stays as CSS.
- `string.unquote("&")` gives the text `&`, not the parent selector,
  as the official CLI does.
- A list built up with `list.append()` in a loop takes memory and time in
  proportion to its length. Each append copied the whole list, so 25000
  appends needed about 2.5 GB and hit the memory limit; they now take
  10 MB.
- Many independent `@extend`s compile in about linear time: 8000 rules
  each extended by its own rule took 0.95 s and 30000 took about 13 s;
  they now take 0.10 s and 0.45 s.
- A function or mixin that reads a variable nothing has set fails with
  "Undefined variable." instead of reading it as null, which dropped the
  declaration and compiled without an error.
- An error raised while a function or mixin runs shows the source line,
  underlines the whole expression, and lists each call down to the root
  stylesheet (`f()`, `m()`), and it is reported once, not twice, as the
  official CLI does.
- `@supports` drops parentheses around a single parenthesized condition
  inside `and`/`or` too, such as `((x)) and ((y))`, and so does the
  `supports()` condition of a plain-CSS `@import`, as the official CLI
  does.
- An error on a very long line is reported quickly: the indentation and
  carets under the line were written one character at a time, which took
  2.3 s for a 7.5 MB line and now takes 0.02 s.
- `list.nth()` and `list.set-nth()` refuse an index that is not an int,
  such as `1.5`, instead of rounding it down, and `math.min()` and
  `math.max()` refuse numbers with incompatible units, such as `1px` and
  `2em`, as the official CLI does. The global CSS `min()` and `max()`
  still keep such a call as CSS.
- `string.split()` accepts a `$limit` with a unit, as the official CLI does.
- Error messages for invalid arguments to `list.nth()`, `list.set-nth()`,
  `list.join()`, `list.append()`, `math.random()`, `math.min()`,
  `math.max()`, `string.slice()`, `string.insert()`, and `string.split()`
  match the official CLI, such as `$n: 1.5 is not an int.`; an unquoted
  string in such a message is written without quotes; and "1 was passed"
  replaces "1 were passed".
- The `sass:selector` functions accept comments in a selector argument,
  such as `selector.parse(".a /* note */ .b")`, as the official CLI does.

### Changed

- `@extend` with many extenders of one selector is about 8% faster: the
  duplicate-extender check looks only at entries with an equal extender.


## 0.5.1 (2026-11-27)

### Changed
- The release workflow uses newer pinned versions of actions/checkout
  (7.0.1), actions/download-artifact (8.0.2), docker/login-action (4.8.0),
  and docker/setup-buildx-action (4.4.1). The compiler and the published
  binaries are unchanged from 0.5.0.

## 0.5.0 (2026-11-27)

### Security
- The installers require the release archive's Sigstore signature: without
  cosign they stop and say how to install it, and `--skip-signature`
  (`-SkipSignature` on Windows) installs with the SHA256 check only. The
  installers are published, signed, with each release, and the README
  installs by downloading and verifying them instead of piping the default
  branch into a shell. The container image and the Homebrew formula are
  built only from archives whose signature verifies.
- `scripts/compat_disposable.py` installs a downloaded project's packages
  with lifecycle scripts disabled and skips bower, unless
  `--allow-lifecycle-scripts` is given.
- Compilation stops with an error instead of crashing, hanging, or running
  out of memory on small hostile inputs: deeply nested syntax, values or
  selectors nested at run time, endless loops, and `@extend`s whose
  combinations multiply. Limits on syntax depth, VM steps, generated rules,
  `@extend` expansion, source size, output size, and memory apply by
  default, so values that double each step stop as well. Each
  has a stable diagnostic code, such as `ZSASS_LIMIT_VM_STEPS`, and fails
  with exit code 65.
- Numbers too large for a 64-bit integer, passed to `list.nth()`,
  `math.random()`, the string functions, and similar, are refused instead
  of being converted out of range, which crashed a safety build and was
  undefined behavior in a release build. 2^63 reads as the largest 64-bit
  integer, as in the official CLI. `math.random()` refuses a limit above
  2^32, as the official CLI does.
- Comparing values counts toward the step limit by the values and text it
  visits, so equality on lists that share structure, map keys that are
  maps or long strings, and large map literals stop at the limit.
- The CLI's Docker image runs as an unprivileged user, is built from the
  release tag it is published for, and pins its base image by digest.

### Added
- `CompileOptions.limits` and `CompileFilesOptions.limits`
  (`CompileLimits`), with `CompileLimits.unlimited()`, and `--no-limits` for
  the CLI.
- `CompileOptions.cancellation_check` stops a compilation from the caller,
  for example at a deadline.
- `CompileOptions.file_import_policy` (`.disabled`, `.unrestricted`, or
  `.roots`) decides which files `@use`, `@forward`, `@import`, and
  `meta.load-css()` may read; `CompileOptions.forUntrustedInput(roots)` sets
  it with the default limits. The default stays `.unrestricted`, as in Sass.

### Fixed
- The CLI's CSS cache is keyed by where the input and load paths lead and
  by the output style, syntax, fatal deprecations, and limits. Compiling
  again with another `--style` returned the cached CSS, and projects
  sharing `ZSASS_CSS_CACHE_DIR` could get each other's CSS. The cache moves
  to a new directory, so older entries are not used.
- `compileFiles` and a CLI batch no longer let an entry that configures a
  module, or uses Sass `@import`, change what another entry gets from that
  module, including when the configuring `@use ... with` or `@import` is in
  a module the entry loads.
- A fatal deprecation (`--fatal-deprecation`) fails the compilation with
  `--quiet` or `--silence-deprecation` too, as in the official CLI; before,
  `--quiet` turned it into a success.
- `compileFiles` compiles one entry at a time until a thread-capable
  `io_facility.io` is installed, since the default one provides no
  concurrency.
- `@extend` applied by many rules to the same selector no longer holds the
  work of every rule at once: 1000 rules extending one placeholder take
  tens of megabytes instead of nearly a gigabyte.
- A selector with `:is()`, `:not()`, or another pseudo-class nested more than
  32 levels deep is no longer an "Invalid CSS syntax" error.
- `@use`, `@forward`, `@import`, and `meta.load-css()` load a stylesheet
  named by an absolute path, as the official CLI does.

## 0.4.4 (2026-11-26)

### Changed
- Building from source needs Zig 0.17.1 or newer (0.16.0 before). The
  released binaries and the container image are built with it; what
  `zsass` writes for a stylesheet is unchanged.
- Large stylesheets compile about 3% faster: three scans over each
  declaration value end early when the value cannot hold what they look
  for.

### Fixed
- `mix()`, `complement()`, `invert()`, `grayscale()` and `ie-hex-str()`,
  and the same functions of `sass:color`, no longer report a
  `color-functions` deprecation. Sass does not deprecate them, so a
  stylesheet that used one failed under
  `--fatal-deprecation=color-functions` and warned otherwise.

## 0.4.3 (2026-11-25)

### Fixed
- Numbers written with a slash between them stay that text when they are
  divided by something that is not a number: `grid-area: 1 / 2 / auto` is
  `1/2/auto`, not `0.5/auto`. In parentheses, on the right of an operator,
  and through a variable the division still happens.
- Compressed output keeps `/*!` comments, and a stylesheet does not end
  with a semicolon.
- Compressed output leaves the prelude of an at-rule as it is, apart from
  a media query list: `@layer a, b`, `@supports (a: b) or (c: d)`, and
  `@container` keep their spaces. `@import` has no space before its URL,
  and `(width >= 64rem)` keeps the spaces around `>=`.
- Compressed output writes a color in the shorter of `rgb()` and `hsl()`
  whichever form it had, as the official CLI does: `hsl(40, 70%, 30%)` is
  `rgb(51%,37%,9%)`, and `rgba(204, 204, 204, 0.5)` is
  `hsla(0,0%,80%,.5)`.
- Compressed output keeps the arguments of a function as they are
  (`linear-gradient(to right, white, transparent 0.5%)`), except in
  `calc()` and the other calculations, where numbers lose their leading
  zero and commas their space. `:nth-child(2n + 1)` keeps its spaces.
- Compressed output leaves a value that is one unquoted string as it is,
  shortens a number beside an interpolation, treats a custom property whose
  name comes from an interpolation (`#{$name}: $value`) as an ordinary
  declaration, and in plain CSS keeps color names and `rgb()` calls.
- Compressed output drops the zero of a number that was rounded to be
  written, after a minus sign as well (`-.075em`), and keeps the zero of
  one with ten decimals as they are (`0.0333333333em`).
- Compressed output leaves an unquoted string in a list as it is, and the
  parts of a value joined by `/` when one of them is not a number
  (`center/0.4rem`). A string made by an interpolation stays when it
  reads as a comment.
- In a calculation kept in a variable or returned by a function, compressed
  output keeps the zero of a number an interpolation put there
  (`calc(0.375rem + var(--w))`) and drops the zero of one written beside it.
- Compressed output picks the shorter of `rgb()` and `hsl()` from the
  channels of a color before they are rounded, so the last digit matches.
- In plain CSS, compressed output shortens the `rgba()` a hex color with an
  alpha channel becomes.
- Compressed output writes a string given to `clamp()`, `min()`, or
  `max()` as it is (`clamp(13px,0.875rem,22px)`), and keeps the zero of a
  number an interpolation put into a calculation that is written in the
  declaration itself.
- `@extend` with the target repeated in a selector leaves out a result
  that another result covers (`.g .f .f:hover` next to `.g .f .f`), as the
  official CLI does after each `@extend` rule for a list of up to 100
  selectors. This is done where the selector is two simple selectors
  (`.a .a`) and its extenders are plain chains of descendants. A single
  extender that has both an ancestor and a sibling combinator is also
  combined with itself (`.x .f + .g .f + .g`).
- `compileSourceToCss` and `compileSourceToCssWithSourceMap` no longer
  leak with an allocator that is not an arena. Lists returned by built-in
  functions (`list.append()`, `map.merge()`, `selector.nest()`, ...) were
  never freed. Each compile now runs in an arena of its own on top of the
  given allocator, as the CLI does, and only the result is allocated with
  the allocator itself.
- `selector.is-superselector()` follows the official CLI on `:not()`
  (`:not(.c.d)` covers `:not(.c)`, `:not(a)` covers `b`, nothing without a
  `:not()` of its own is covered otherwise), on `:is()` and its kin (a list
  is covered only when every selector in it is; two of different names are
  not compared list against list), and on `*` beside other selectors
  (`*.c` covers `a.c`, not `.c`).
- Numbers written with a slash follow the official CLI inside parentheses
  and in the arguments of a call too: `foo(1/2/x)` and `(a 1/2/x)` keep the
  text, `(1/2/x a)` and `(foo(1/2/x))` divide.
- A signed number right after a word is added to it: `x+1` is `x1`, as in
  the official CLI, where it was left as `x+1`.
- `@extend` is not applied a second time to a selector it produced when
  the target left in it is the extender's own: with `.c + .g {@extend .c}`
  and another extension on the same rule, `.a .c + .g + .g` is no longer
  written.
- `@extend` leaves out a result that its original selector covers when the
  extender has the target itself and is no more specific than the original:
  `b.c {@extend .c}` adds nothing to `:focus.c`.
- `@extend` is reimplemented after the Sass specification's model, with the
  parts the specification leaves open taken from the official CLI's output:
  the order `@extend`s are applied in, how an extender is itself extended,
  how the parents of an extender are woven in, and which generated
  selectors are trimmed. On random stylesheets with chained `@extend`s the
  output now agrees with the official CLI about 98% of the time, up from
  70%; selectors the official CLI writes are no longer missing, and
  stylesheets that made the old implementation loop (a target repeated in
  its own extender, such as `.c .c .c {@extend .c}`) now compile.
- `@extend` keeps the selectors that come of an extender extended by
  itself: with `.d {…}`, `.f.c > .k {@extend .d}`, and
  `.d .m.f {@extend .f}`, the rule gains
  `.f.c > .k .c.m.f > .k .c.m.f > .k` as with the official CLI.
- A mandatory `@extend` reports "The target selector was not found" by
  what the extension itself saw. `.x {@extend :is(.a)}` followed by
  `.y {@extend .a}` and `:is(.a) {…}` is now an error, as with the
  official CLI; `.f .g {@extend .f}` alone, whose own selector holds the
  target, now compiles.
- `selector.replace()` and `selector.extend()` take several extendees one
  after the other, each on what the one before left:
  `selector.replace(".a.b.c", ".a.b, .a.c", ".x")` is `.c.x`, and
  `selector.replace(".c", ".c", ".x, .c")` is `.x, .c`.
- A selector written twice in one list is dropped only when it stands
  next to its repeat: `.a.c, .a.c {…}` extended by `.z {@extend .a}` is
  `.a.c, .c.z, .a.c`.
- A rule whose selector has an escaped space is extended like any other:
  `.a.foo\ bar {…}` with `.x {@extend .a}` is `.a.foo\ bar, .foo\ bar.x`.
- `selector.unify()` uses the unification and weaving of `@extend`, and
  the older code for both is removed. With selectors that hold `:host`,
  `:root`, `:scope`, or a pseudo-element it now gives what the official
  CLI gives: `selector.unify(":host(.x):is(.r)", ":is(.q)")` is
  `:host(.x):is(.r):is(.q)`, `selector.unify(":hover", "::after:hover")`
  is `:hover::after:hover`, and
  `selector.unify(":root ~ .x .a", ".y .b")` is
  `:root ~ .x :root ~ .y .a.b, :root ~ .y :root ~ .x .a.b`. The same
  rules apply where `@extend` unifies: `.c:host(.x):is(.r) {…}` with
  `.d:is(.q) {@extend .c}` gains `.d:host(.x):is(.r):is(.q)`.
- `selector.extend()` and `selector.replace()` use the same implementation.
- `selector.is-superselector()` matches front to back as the official CLI
  does: `.a .x` does not cover `.a.e + .a.b .x`, and `::foo` covers
  `::foo.baz`.
- A style rule counts the `@extend`s that ran before its block was entered,
  also when its first declaration comes after an `@extend` of its own.

## 0.4.2 (2026-11-23)

Tracks Dart Sass 1.108.2. The vendored `sass-spec` pin moves to
`acbdcd391`.

### Added
- `--fatal-deprecation` accepts `-<id>` to exclude a deprecation that a
  version would include, in any order and across repeated flags, and the
  `dart-sass-2` group (Dart Sass 1.107.0). Excluding an id that was not
  included is a usage error.
- The three deprecation flags accept every deprecation id of the official
  CLI, including the ones zsass does not report, so
  `--silence-deprecation=global-builtin` no longer fails.

### Changed
- A stylesheet that is not valid UTF-8 is an error ("Invalid UTF-8.")
  instead of being copied into the output.
- Escapes in selectors have one canonical spelling: `.\61` is `.a`, also
  for `@extend`, `&`, and `sass:selector` functions, while `.\31 0` and
  `.sm\:w-1\/2` keep the escapes they need. An attribute value is decoded
  and written back as an identifier or a string, so `[a="\62"]` is `[a=b]`.
- String functions, `==`, and map or list lookups use the text of a string
  as it is. `string.length("\\61")` is 3 and `"\\61" == "a"` is false;
  earlier releases decoded the backslash a second time.
- `--fatal-deprecation=<version>` no longer includes obsolete deprecations
  and accepts versions up to 1.108.2. A deprecation that is both silenced
  and fatal stays fatal.
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
- `@extend` covers every combination when its target appears more than
  once in a selector. `.a + .a` extended by `.f` is now
  `.a + .a, .f + .a, .a + .f, .f + .f`; `.f + .f` was missing, and
  `.a .a .a` gave four of its eight selectors. `selector.extend()` and
  `selector.replace()` follow, so `selector.replace(".a .a", ".a", ".f")`
  is `.f .f`. A selector whose extensions would make more than 1024
  combinations is extended one compound at a time as before.
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
- `meta.load-css()` works inside `@media`, `@supports`, and other at-rule
  blocks; it failed with a compile error. Nested in a style rule or an
  at-rule, the loaded rules are no longer separated by blank lines,
  comments get a rule of their own, and keyframe selectors are left alone.
  A chain of more than 200 modules that load one another is an error
  instead of a crash.
- Compressed output removes an empty rule without the block around it.
  `@media print { a { /* x */ } b { c: d } }` lost its `@media`.
- A module loaded through `@forward ... with ($a: 1 !default)` takes the
  value the using module configured when a top-level `@if` is evaluated,
  and an outer `@forward` default takes precedence over an inner one. A
  prefixed name (`@forward "m" as p-*`) reaches the forwarded module the
  same way.
- `url(a/.5.png)` keeps its path instead of becoming `url(a/0.5.png)`.
- A private-use character in a quoted string is followed by a space when a
  hex digit or a space comes next, so `"\f00c Done"` is no longer printed
  as `"\f00cDone"`. `"#{\f00c}"` and `string.quote(\f00c)` hold the
  character rather than its escape.
- `min(a-b)` and other math functions keep the hyphen of an identifier
  instead of printing a subtraction, and keep space-separated operands such
  as `min(var(--a) var(--b))` instead of adding them.
- An attribute selector value with an escape, such as
  `a[href^="http\3a //"]`, is no longer printed with a doubled backslash.
- A selector name with an escaped comma or bracket, such as
  `.grid-cols-\[1fr\2c 2fr\]`, compiles.
- An escape followed by an interpolation in a function name, such as
  `a\62#{1}(2)`, no longer produces a different character.
- The space that ends a hex escape is kept apart from the whitespace after
  it: `.\31  .b` stays a descendant selector instead of becoming the
  compound `.\31 .b`, and `\31  x` stays two values. The same holds across
  a comment, in custom properties, after `@extend`, and in compressed
  output, which printed `.\31 +.b` as `.\31+.b`. A lone escaped hyphen is
  written `\2d ` and a hyphen before a digit as `-\31 `.
- `selector.nest()` returns a selector list rather than a string.
- Compressed output writes the selectors given to `:is()`, `:not()`, and
  the other selector pseudo-classes without a space after the comma, and
  turns a line break inside a custom property value into a space instead
  of joining the two tokens. A `/* */` inside a string or a custom
  property value is kept; it was removed as if it were a comment. A
  string keeps a space before `{` and a `;` before `}`, and an escaped
  `;` or one inside `url()` is no longer dropped before a closing brace.

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
