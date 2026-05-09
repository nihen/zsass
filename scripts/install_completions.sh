#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/install_completions.sh [--shell <bash|zsh|fish>] [--bin <path>] [--output <path>]

Generates shell completions by invoking an existing zsass binary and writes them to a config file.

Options:
  --shell <shell>   Target shell (bash, zsh, or fish). You can also pass the shell name as the first argument.
  --bin <path>      Path to the zsass binary (default: zig-out/bin/zsass if it exists, otherwise the zsass found in PATH).
  --output <path>   Destination file (default: ~/.config/zsass/completions.<shell> for bash/zsh, ~/.config/fish/completions/zsass.fish for fish).
  -h, --help        Show this help text.

Environment:
  ZSASS_COMPLETIONS_BIN  Same as --bin; overrides the auto-detected binary when set.
USAGE
}

expand_path() {
  case "$1" in
    "~") printf '%s\n' "$HOME" ;;
    ~/*) printf '%s/%s\n' "$HOME" "${1#~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
SHELL_TYPE=""
OUTPUT_PATH=""
BIN_PATH="${ZSASS_COMPLETIONS_BIN:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --shell)
      [[ $# -ge 2 ]] || { echo "--shell requires a value" >&2; exit 64; }
      SHELL_TYPE="$2"
      shift 2
      continue
      ;;
    --bin)
      [[ $# -ge 2 ]] || { echo "--bin requires a path" >&2; exit 64; }
      BIN_PATH="$2"
      shift 2
      continue
      ;;
    --output)
      [[ $# -ge 2 ]] || { echo "--output requires a path" >&2; exit 64; }
      OUTPUT_PATH="$2"
      shift 2
      continue
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    bash|zsh|fish)
      if [[ -n "$SHELL_TYPE" ]]; then
        echo "Shell already provided via --shell" >&2
        exit 64
      fi
      SHELL_TYPE="$1"
      shift
      continue
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [[ -z "$SHELL_TYPE" ]]; then
  echo "Specify a shell via --shell <bash|zsh|fish>" >&2
  exit 64
fi

case "$SHELL_TYPE" in
  bash|zsh|fish) ;;
  *)
    echo "Unsupported shell: $SHELL_TYPE (use bash, zsh, or fish)" >&2
    exit 64
    ;;
esac

if [[ -z "$BIN_PATH" ]]; then
  if [[ -x "zig-out/bin/zsass" ]]; then
    BIN_PATH="zig-out/bin/zsass"
  elif command -v zsass >/dev/null 2>&1; then
    BIN_PATH="$(command -v zsass)"
  else
    echo "zsass binary not found (build it with 'zig build' or specify --bin)" >&2
    exit 127
  fi
fi

if [[ ! -x "$BIN_PATH" ]]; then
  echo "zsass binary is not executable: $BIN_PATH" >&2
  exit 126
fi

if [[ -z "$OUTPUT_PATH" ]]; then
  case "$SHELL_TYPE" in
    bash)
      OUTPUT_PATH="$CONFIG_HOME/zsass/completions.bash"
      ;;
    zsh)
      OUTPUT_PATH="$CONFIG_HOME/zsass/completions.zsh"
      ;;
    fish)
      OUTPUT_PATH="$CONFIG_HOME/fish/completions/zsass.fish"
      ;;
  esac
fi

OUTPUT_PATH="$(expand_path "$OUTPUT_PATH")"
mkdir -p "$(dirname "$OUTPUT_PATH")"

TMP_FILE="$(mktemp "${TMPDIR:-/tmp}/zsass-completions.XXXXXX")"
trap 'rm -f "$TMP_FILE"' EXIT

printf '[zsass-completions] generating %s completions using %s\n' "$SHELL_TYPE" "$BIN_PATH"
"$BIN_PATH" --completions "$SHELL_TYPE" >"$TMP_FILE"
mv "$TMP_FILE" "$OUTPUT_PATH"
trap - EXIT
printf '[zsass-completions] wrote %s\n' "$OUTPUT_PATH"

case "$SHELL_TYPE" in
  bash)
    cat <<EOF
Add the following to ~/.bashrc (or equivalent) to enable completions:
  source "$OUTPUT_PATH"
EOF
    ;;
  zsh)
    cat <<EOF
Ensure bashcompinit is enabled, then source the file (e.g., in ~/.zshrc):
  autoload -U +X bashcompinit && bashcompinit
  source "$OUTPUT_PATH"
EOF
    ;;
  fish)
    echo "Fish autoloads completions from ~/.config/fish/completions/, so no extra steps are required."
    ;;
esac
