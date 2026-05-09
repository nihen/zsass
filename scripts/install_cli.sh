#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/install_cli.sh [options]

Builds a release binary and installs it via "zig build install".

Options:
  --prefix <dir>        Installation prefix (default: $HOME/.local or $ZSASS_INSTALL_PREFIX)
  --optimize <lvl>      Zig optimize mode (default: ReleaseFast)
  --completions <shell> Install shell completions after building (bash, zsh, fish). Repeatable.
  -h, --help            Show this help text
USAGE
}

PREFIX="${ZSASS_INSTALL_PREFIX:-$HOME/.local}"
OPTIMIZE="${ZSASS_INSTALL_OPTIMIZE:-ReleaseFast}"
COMPLETIONS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      [[ $# -ge 2 ]] || { echo "--prefix requires a path" >&2; exit 64; }
      PREFIX="$2"
      shift 2
      continue
      ;;
    --optimize)
      [[ $# -ge 2 ]] || { echo "--optimize requires a value" >&2; exit 64; }
      OPTIMIZE="$2"
      shift 2
      continue
      ;;
    --completions)
      [[ $# -ge 2 ]] || { echo "--completions requires a shell (bash, zsh, fish)" >&2; exit 64; }
      COMPLETIONS+=("$2")
      shift 2
      continue
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
GLOBAL_CACHE_DIR="${ZSASS_GLOBAL_CACHE_DIR:-$REPO_ROOT/.zig-global-cache}"

if ! command -v zig >/dev/null 2>&1; then
  echo "zig not found in PATH" >&2
  exit 127
fi

mkdir -p "$GLOBAL_CACHE_DIR"
printf '[zsass-install] building optimize=%s\n' "$OPTIMIZE"
zig build -Doptimize="$OPTIMIZE" --global-cache-dir "$GLOBAL_CACHE_DIR"

printf '[zsass-install] installing to %s\n' "$PREFIX"
mkdir -p "$PREFIX"
zig build -Doptimize="$OPTIMIZE" install --prefix "$PREFIX" --global-cache-dir "$GLOBAL_CACHE_DIR"

BIN_PATH="$PREFIX/bin/zsass"
if [[ -x "$BIN_PATH" ]]; then
  printf '[zsass-install] done -> %s\n' "$BIN_PATH"
else
  printf '[zsass-install] warning: expected binary not found at %s\n' "$BIN_PATH" >&2
fi

if [[ -x "$BIN_PATH" && ${#COMPLETIONS[@]} -gt 0 ]]; then
  for shell in "${COMPLETIONS[@]}"; do
    printf '[zsass-install] installing %s completions\n' "$shell"
    "$SCRIPT_DIR/install_completions.sh" --shell "$shell" --bin "$BIN_PATH"
  done
fi
