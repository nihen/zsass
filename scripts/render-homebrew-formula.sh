#!/usr/bin/env bash
# Render the Homebrew Formula for zsass at a given release version.
#
# Fetches the .sha256 sidecars published alongside each release tarball
# from GitHub Releases (build/sign workflow) and substitutes them into
# the formula template. Output is written to stdout, or to the path
# given by --output.
#
# Usage:
#   scripts/render-homebrew-formula.sh <version> [--output <path>]
#
#   <version> may be `0.1.0` or `v0.1.0`; the leading `v` is stripped.
#
# The four release archives are required (linux x86_64/aarch64, macOS
# x86_64/aarch64); any missing checksum aborts the script.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <version> [--output <path>]" >&2
    exit 64
fi

raw_version="$1"
shift

output_path=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)
            output_path="${2:-}"
            if [[ -z "${output_path}" ]]; then
                echo "$0: --output requires a path" >&2
                exit 64
            fi
            shift 2
            ;;
        *)
            echo "$0: unknown argument: $1" >&2
            exit 64
            ;;
    esac
done

version="${raw_version#v}"
if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]]; then
    echo "$0: invalid version '${raw_version}' (expected semver like 0.1.0)" >&2
    exit 65
fi

repo="${ZSASS_RELEASE_REPO:-nihen/zsass}"
release_url_base="https://github.com/${repo}/releases/download/v${version}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

declare -A sha=()
fetch_sha() {
    local os="$1" arch="$2"
    local archive="zsass-v${version}-${os}-${arch}.tar.gz"
    local url="${release_url_base}/${archive}.sha256"
    local out="${tmpdir}/${archive}.sha256"

    if ! curl -fsSL "${url}" -o "${out}"; then
        echo "$0: failed to fetch ${url}" >&2
        exit 65
    fi
    # The file is `<sha256>  <filename>`; pick the first token.
    local digest
    digest="$(awk 'NR==1{print $1}' "${out}")"
    if [[ ! "${digest}" =~ ^[0-9a-f]{64}$ ]]; then
        echo "$0: malformed checksum in ${url}: ${digest}" >&2
        exit 65
    fi
    sha["${os}-${arch}"]="${digest}"
}

fetch_sha macos aarch64
fetch_sha macos x86_64
fetch_sha linux aarch64
fetch_sha linux x86_64

formula=$(cat <<EOF
class Zsass < Formula
  desc "Sass compiler implemented in Zig"
  homepage "https://github.com/nihen/zsass"
  version "${version}"
  license "MIT"

  on_macos do
    on_arm do
      url "${release_url_base}/zsass-v${version}-macos-aarch64.tar.gz"
      sha256 "${sha[macos-aarch64]}"
    end
    on_intel do
      url "${release_url_base}/zsass-v${version}-macos-x86_64.tar.gz"
      sha256 "${sha[macos-x86_64]}"
    end
  end

  on_linux do
    on_arm do
      url "${release_url_base}/zsass-v${version}-linux-aarch64.tar.gz"
      sha256 "${sha[linux-aarch64]}"
    end
    on_intel do
      url "${release_url_base}/zsass-v${version}-linux-x86_64.tar.gz"
      sha256 "${sha[linux-x86_64]}"
    end
  end

  def install
    bin.install "zsass"
  end

  test do
    assert_match "zsass #{version}", shell_output("#{bin}/zsass --version").strip
  end
end
EOF
)

if [[ -n "${output_path}" ]]; then
    printf '%s\n' "${formula}" > "${output_path}"
else
    printf '%s\n' "${formula}"
fi
