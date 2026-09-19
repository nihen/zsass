# Semantic compatibility audit

Read this when auditing fixture-specific hacks or reviewing a compatibility fix before commit. For a fix, review each added branch, exception, and normalizer and record the general Sass/CSS behavior that justifies it.

- Read every line of the target files; search results are only a starting point.
- Classify conditionals, lookup tables, normalization rules, fallbacks, and setup workarounds as `spec`, `sass-cli-observed`, `fixture-setup-only`, or `suspect`.
- Treat `suspect` as blocking until it is removed, generalized, or supported by a minimal clean-room reproducer checked with the official `sass` CLI.
- Record file, range, classification, evidence, and action in an audit ledger under `.plans/`.
