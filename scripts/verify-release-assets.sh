#!/usr/bin/env bash
# Verify release archives before something else is built from them: each
# archive must carry a Sigstore signature from this repository's release
# workflow at the tag, and its published .sha256 must match it.
#
# Usage: scripts/verify-release-assets.sh <tag> <asset>...
#   e.g. scripts/verify-release-assets.sh v0.4.4 zsass-v0.4.4-linux-x86_64.tar.gz
#
# Needs curl, cosign, and sha256sum (or shasum). Set ZSASS_REPO to verify a
# fork's releases.
set -euo pipefail

tag="${1:?usage: $0 <tag> <asset>...}"
shift
[[ $# -gt 0 ]] || { echo "usage: $0 <tag> <asset>..." >&2; exit 64; }
repo="${ZSASS_REPO:-nihen/zsass}"
base="https://github.com/${repo}/releases/download/${tag}"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

for asset in "$@"; do
  for f in "${asset}" "${asset}.sha256" "${asset}.sig" "${asset}.pem"; do
    curl -fsSL --retry 3 -o "${work}/${f}" "${base}/${f}"
  done
  cosign verify-blob \
    --certificate "${work}/${asset}.pem" \
    --signature "${work}/${asset}.sig" \
    --certificate-identity "https://github.com/${repo}/.github/workflows/release.yml@refs/tags/${tag}" \
    --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
    "${work}/${asset}" >/dev/null
  actual="$(sha256_of "${work}/${asset}")"
  published="$(awk '{print $1; exit}' "${work}/${asset}.sha256")"
  if [[ "${actual}" != "${published}" ]]; then
    echo "::error::${asset}: published sha256 ${published} does not match the signed archive (${actual})" >&2
    exit 1
  fi
  echo "verified ${asset} ${actual}"
done
