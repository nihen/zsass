#!/usr/bin/env bash
#
# Cross-compile ReleaseFast binaries for the GitHub release.
# Outputs are placed under release/<target>/{bin,lib,share}/... and then
# archived as release/zsass-<version>-<target>.{tar.gz,zip} with a sha256 sidecar.
#
# Usage:  scripts/build-release.sh [VERSION]
# Default version is read from build.zig.zon (".version =" line).
#
# IMPORTANT - this is a LOCAL helper, not the canonical release pipeline.
# The published GitHub release is built by .github/workflows/release.yml,
# which uses a per-target matrix on hosted runners. If you change any of
# the items below here, mirror the change in release.yml as well (and
# vice-versa); CI does not currently diff the two.
#   - the `targets=( ... )` list (line ~26 below) and the matrix in
#     release.yml must cover the same set of triples
#   - the side-files bundled with the binary (README.md, CHANGELOG.md,
#     LICENSE) must match
#
# Asset filenames intentionally differ between the two pipelines:
#   - build-release.sh:  zsass-<ver>-<zig-target>.{tar.gz,zip}
#                          e.g. zsass-0.1.0-x86_64-linux-gnu.tar.gz
#   - release.yml:       zsass-v<ver>-<os>-<arch>.{tar.gz,zip}
#                          e.g. zsass-v0.1.0-linux-x86_64.tar.gz
# This makes it impossible to confuse a locally-built smoke archive with a
# published release artifact. The script exists for local smoke-testing
# of the cross-compile matrix before tagging a release; the artifacts it
# produces are not what users download.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ $# -ge 1 ]]; then
    version="$1"
else
    version="$(awk -F'"' '/^[[:space:]]*\.version[[:space:]]*=/ { print $2; exit }' build.zig.zon)"
fi
if [[ -z "$version" ]]; then
    echo "scripts/build-release.sh: cannot determine version (pass it explicitly)" >&2
    exit 1
fi
echo "Building zsass v${version} cross-compile artifacts"

targets=(
    "x86_64-linux-gnu"
    "aarch64-linux-gnu"
    "x86_64-macos"
    "aarch64-macos"
    "x86_64-windows-gnu"
)

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$@"
    else
        shasum -a 256 "$@"
    fi
}

release_dir="$repo_root/release"
rm -rf "$release_dir"
mkdir -p "$release_dir"

for target in "${targets[@]}"; do
    out_dir="$release_dir/$target"
    archive_dir="zsass-${version}-${target}"
    echo "==> $target"
    zig build \
        -Dtarget="$target" \
        -Doptimize=ReleaseFast \
        --prefix "$out_dir" \
        --summary none

    # Stage a flattened tree (bin/, share/) under release/<archive_dir>/
    stage="$release_dir/$archive_dir"
    rm -rf "$stage"
    mkdir -p "$stage"
    cp -R "$out_dir"/. "$stage"/
    cp README.md CHANGELOG.md LICENSE "$stage"/

    if [[ "$target" == *windows* ]]; then
        archive="$release_dir/${archive_dir}.zip"
        (cd "$release_dir" && zip -r "${archive_dir}.zip" "$archive_dir" >/dev/null)
    else
        archive="$release_dir/${archive_dir}.tar.gz"
        tar -C "$release_dir" -czf "$archive" "$archive_dir"
    fi
    (cd "$release_dir" && sha256_file "$(basename "$archive")" > "$(basename "$archive").sha256")
    echo "    -> $archive  ($(cat "${archive}.sha256"))"
done

# Aggregate sha256 manifest (one row per artifact, sha256 + filename).
sha_manifest="$release_dir/zsass-${version}-SHA256SUMS.txt"
( cd "$release_dir" && sha256_file zsass-*.tar.gz zsass-*.zip 2>/dev/null ) > "$sha_manifest"
echo
echo "Done. Aggregated manifest: $sha_manifest"
ls -la "$release_dir"/zsass-*.tar.gz "$release_dir"/zsass-*.zip 2>/dev/null || true
