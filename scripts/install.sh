#!/bin/sh
# zsass binary installer.
#
# Detects OS / arch, downloads the matching tarball from GitHub Releases,
# verifies its SHA256, and installs the binary into <prefix>/bin.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/nihen/zsass/main/scripts/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --version v0.1.0 --prefix ~/opt/zsass
#
# Or invoke directly from a checkout:
#   scripts/install.sh --prefix ~/.local
#
# Environment overrides:
#   ZSASS_INSTALL_PREFIX   default install prefix (default: $HOME/.local)
#   ZSASS_VERSION          default version to install (default: latest release)

set -eu

REPO="nihen/zsass"
BIN_NAME="zsass"

PREFIX="${ZSASS_INSTALL_PREFIX:-$HOME/.local}"
VERSION="${ZSASS_VERSION:-}"

usage() {
  cat <<'EOF'
Usage: install.sh [options]

Options:
  --prefix <dir>     Install prefix; binary goes to <dir>/bin (default: $HOME/.local)
  --version <ver>    Version tag to install, e.g. v0.1.0 (default: latest)
  -h, --help         Show this help text
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)
      [ $# -ge 2 ] || { echo "--prefix requires a value" >&2; exit 64; }
      PREFIX="$2"; shift 2 ;;
    --version)
      [ $# -ge 2 ] || { echo "--version requires a value" >&2; exit 64; }
      VERSION="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64 ;;
  esac
done

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[zsass-install] required tool not found: $1" >&2
    exit 1
  }
}

require curl
require tar
require uname
require mktemp

uname_s="$(uname -s)"
case "$uname_s" in
  Linux)  os="linux" ;;
  Darwin) os="macos" ;;
  *)
    echo "[zsass-install] unsupported OS: $uname_s" >&2
    echo "[zsass-install] for Windows, use scripts/install.ps1 in PowerShell" >&2
    exit 1 ;;
esac

uname_m="$(uname -m)"
case "$uname_m" in
  x86_64|amd64)   arch="x86_64" ;;
  arm64|aarch64) arch="aarch64" ;;
  *)
    echo "[zsass-install] unsupported arch: $uname_m" >&2
    exit 1 ;;
esac

if [ -z "$VERSION" ]; then
  echo "[zsass-install] resolving latest release"
  VERSION="$(
    curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
      | sed -n 's/.*"tag_name":[[:space:]]*"\(v[^"]*\)".*/\1/p' \
      | head -n1
  )"
  [ -n "$VERSION" ] || {
    echo "[zsass-install] failed to resolve latest version (rate-limited?)" >&2
    echo "[zsass-install] retry with --version <tag>" >&2
    exit 1
  }
fi
case "$VERSION" in
  v*) ;;
  *) VERSION="v$VERSION" ;;
esac

asset="zsass-${VERSION}-${os}-${arch}.tar.gz"
url="https://github.com/$REPO/releases/download/${VERSION}/${asset}"
sha_url="${url}.sha256"

tmp="$(mktemp -d 2>/dev/null || mktemp -d -t 'zsass-install')"
trap 'rm -rf "$tmp"' EXIT INT HUP TERM

echo "[zsass-install] downloading $asset"
curl -fSL --retry 3 "$url"     -o "$tmp/$asset"
curl -fSL --retry 3 "$sha_url" -o "$tmp/$asset.sha256"

echo "[zsass-install] verifying sha256"
if command -v sha256sum >/dev/null 2>&1; then
  ( cd "$tmp" && sha256sum -c "$asset.sha256" )
elif command -v shasum >/dev/null 2>&1; then
  ( cd "$tmp" && shasum -a 256 -c "$asset.sha256" )
else
  echo "[zsass-install] no sha256sum / shasum available; cannot verify download" >&2
  exit 1
fi

# Opportunistic sigstore verification: when `cosign` is on PATH, we
# additionally download the .sig / .pem sidecars and require a clean
# verify-blob against the tag-specific OIDC identity. If cosign is missing
# we skip silently (SHA256 + GitHub TLS still apply); if cosign is
# present but verification fails, we abort.
if [ "${ZSASS_INSTALL_SKIP_SIGSTORE:-0}" = "1" ]; then
  echo "[zsass-install] note: ZSASS_INSTALL_SKIP_SIGSTORE=1 set; skipping signature verification"
elif command -v cosign >/dev/null 2>&1; then
  echo "[zsass-install] cosign found; verifying sigstore signature (fail-closed)"
  if ! curl -fSL --retry 3 "${url}.sig" -o "$tmp/$asset.sig"; then
    echo "[zsass-install] FAILED to download ${asset}.sig from a release that should publish it." >&2
    echo "[zsass-install] Aborting install. Set ZSASS_INSTALL_SKIP_SIGSTORE=1 to bypass." >&2
    exit 1
  fi
  if ! curl -fSL --retry 3 "${url}.pem" -o "$tmp/$asset.pem"; then
    echo "[zsass-install] FAILED to download ${asset}.pem from a release that should publish it." >&2
    echo "[zsass-install] Aborting install. Set ZSASS_INSTALL_SKIP_SIGSTORE=1 to bypass." >&2
    exit 1
  fi
  if ! cosign verify-blob \
       --certificate "$tmp/$asset.pem" \
       --signature   "$tmp/$asset.sig" \
       --certificate-identity   "https://github.com/$REPO/.github/workflows/release.yml@refs/tags/${VERSION}" \
       --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
       "$tmp/$asset"; then
    echo "[zsass-install] cosign verification FAILED for $asset" >&2
    exit 1
  fi
  echo "[zsass-install] sigstore signature OK"
else
  echo "[zsass-install] note: cosign not in PATH; skipping signature verification (run cosign verify-blob manually for hardened install)"
fi

echo "[zsass-install] extracting"
tar -xzf "$tmp/$asset" -C "$tmp"
extracted="$tmp/zsass-${VERSION}-${os}-${arch}"
[ -x "$extracted/$BIN_NAME" ] || {
  echo "[zsass-install] binary not found in archive at $extracted/$BIN_NAME" >&2
  exit 1
}

# Atomic install: stage at <bin>/.<name>.installtmp, then mv -f over the
# final path. mv across the same directory is rename(2), so a process
# with the previous binary still mapped keeps running until it exits.
# A second EXIT trap layered on top of the existing one ensures the
# stage file is removed if the script is killed between cp and mv.
mkdir -p "$PREFIX/bin"
tmp_bin="$PREFIX/bin/.$BIN_NAME.installtmp.$$"
trap 'rm -rf "$tmp" 2>/dev/null; rm -f "$tmp_bin" 2>/dev/null' EXIT INT HUP TERM
cp "$extracted/$BIN_NAME" "$tmp_bin"
chmod 0755 "$tmp_bin"
mv -f "$tmp_bin" "$PREFIX/bin/$BIN_NAME"

echo "[zsass-install] installed -> $PREFIX/bin/$BIN_NAME"
"$PREFIX/bin/$BIN_NAME" --version || true

case ":${PATH:-}:" in
  *":$PREFIX/bin:"*) ;;
  *)
    echo
    echo "[zsass-install] note: $PREFIX/bin is not in your PATH"
    echo "[zsass-install] add this to your shell rc:"
    echo "    export PATH=\"$PREFIX/bin:\$PATH\""
    ;;
esac
