# Security Policy

## Supported Versions

zsass is pre-1.0; only the latest minor release receives security fixes.

| Version | Supported          |
| ------- | ------------------ |
| 0.4.x   | :white_check_mark: |
| < 0.4   | :x:                |

## Reporting a Vulnerability

Please **do not** open a public GitHub issue for security-sensitive
problems. Instead use one of the private channels below:

1. **Preferred:** GitHub Security Advisories - go to
   <https://github.com/nihen/zsass/security/advisories/new> and submit a
   private report. This is the most reliable channel and lets us
   coordinate a fix before disclosure.
2. **Email:** <nihen@megabbs.com>. Use a clear subject line such as
   `[zsass security] <one-line summary>`.

We aim to acknowledge new reports within **3 business days** and to
provide a remediation plan or patch timeline within **14 days**. Critical
issues affecting confidentiality / integrity will be handled on a
shorter clock.

When reporting, please include:

- Affected version (`zsass --version`) and platform.
- A minimal reproducer (`.scss` snippet plus the exact CLI invocation, or
  an embedding-API call).
- Observed behavior vs. expected, and any impact assessment you have.
- Whether you intend to publish a write-up; we will coordinate timing.

We do not currently run a paid bug bounty programme. We are happy to
credit reporters in release notes and the published advisory unless you
prefer to remain anonymous.

## Compiling untrusted input

zsass is a Sass compiler, not a sandbox. Sass lets a stylesheet read other
stylesheets through `@use`, `@forward`, `@import`, and `meta.load-css()`, and
lets it compute without bound. When you compile input you do not trust:

- Use a release with resource limits and the file import policy (see
  `CompileOptions.limits` and `CompileOptions.file_import_policy` in
  [docs/api.md](docs/api.md#compiling-untrusted-input)).
  `CompileOptions.forUntrustedInput(roots)` sets both. The CLI applies the
  default limits too; `--no-limits` lifts them and is meant for trusted
  input only.
- Pass a wall-clock deadline through `cancellation_check`. The limits count
  work, not time.
- Still run the compiler in a separate process or container with CPU,
  memory, and wall-clock limits. The limits stop known ways to exhaust a
  process; they do not bound every allocation.
- Releases without resource limits can be made to crash, loop forever, or
  use unbounded memory with small inputs. Run them only in an isolated
  process or container with those limits, never in the same process as
  other work.

## Verifying release artifacts

Every release archive is published with two integrity layers:

1. **SHA256 sidecar (`<asset>.sha256`)** - guards against transport
   corruption and obvious tampering. Verify with
   `sha256sum -c <asset>.sha256`.
2. **Sigstore keyless signature (`<asset>.sig` + `<asset>.pem`)** - proves
   the archive was produced by this repository's GitHub Actions release
   workflow. Verify with [`cosign`](https://github.com/sigstore/cosign):

   ```bash
   # Pin the verification to the exact tag you downloaded - never accept "@.*".
   TAG=v0.1.0
   cosign verify-blob \
     --certificate <asset>.pem \
     --signature   <asset>.sig \
     --certificate-identity   "https://github.com/nihen/zsass/.github/workflows/release.yml@refs/tags/${TAG}" \
     --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
     <asset>
   ```

If signature verification fails for an artifact downloaded from
<https://github.com/nihen/zsass/releases>, please report it through the
private channels above before installing.

## Scope

In scope:

- The `zsass` CLI binary and its release artifacts published on
  <https://github.com/nihen/zsass/releases>.
- The embedding API exposed via `@import("zsass")`. We treat
  zsass-as-a-library as a code path that may be fed untrusted Sass
  input, so the items below carry a heavier weight when they affect
  embedders rather than the CLI alone.
- Build / install scripts under `scripts/` shipped from this repository.

In scope, with extra emphasis when zsass is embedded in a server /
service that compiles untrusted user input on a hot path:

- Memory safety bugs (out-of-bounds, use-after-free, double-free, leaks)
  reachable from any reasonable Sass input.
- Resource exhaustion (RSS / CPU blowup, infinite loops, runaway
  recursion) triggered by reasonably-sized inputs under the default
  limits -- treat denial of service against an embedder as in scope.
- Reading a file outside the roots of `FileImportPolicy.roots`, or any file
  with `FileImportPolicy.disabled`. The bar is "an attacker
  cannot make a 1-MiB stylesheet take exponential time or RAM"; pure
  pathological inputs at multi-MiB scale that grow linearly fall under
  the out-of-scope crash bullet below.

Out of scope:

- Bugs affecting only third-party forks or repackaged distributions.
- Issues in upstream dependencies (Zig stdlib, sass-spec) unless they
  manifest specifically through zsass; report those upstream first.
- Crashes on intentionally malformed input when zsass is invoked as a
  stand-alone CLI (one process per build, fault-tolerant build
  pipeline). These are still functional bugs we want to fix -- file a
  normal issue. Embedder-side crashes on the same inputs are in scope
  per the bullet above.
