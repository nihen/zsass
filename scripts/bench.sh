#!/usr/bin/env bash
# Quick zsass vs dart-sass comparison table across all realworld suites.
# Both compilers receive all entries as multi-input args in a single process.
# With the default zig-out binaries this script always refreshes ReleaseFast
# first. A plain `zig build` overwrites zig-out/bin/zsass with Debug, and mtime
# checks cannot distinguish that from a fresh ReleaseFast binary.
# Usage: scripts/bench.sh [--runs N] [--suite NAME]
set -euo pipefail

RUNS=1
WARMUP=0
FILTER=""
FIXTURES="${ZSASS_REALWORLD_SUITE_ROOT:-../zsass-realworld-fixtures}"
ZSASS="${ZSASS_BIN:-./zig-out/bin/zsass}"
SPEC_RUNNER="${SPEC_RUNNER:-./zig-out/bin/spec_runner}"
SPEC_DIR="$(pwd)/tests/sass-spec/spec"
OUTFILE="bench-results.md"
DIFF_DIR="${BENCH_DIFF_DIR:-bench-results.diffs}"
DART_CACHE_FILE="${DART_CACHE_FILE:-.bench-dart-cache.json}"
# Number of dart runs used to populate the timing cache.
# Keep this cold by default: no hyperfine warmup, one fresh process run.
# zsass is always measured with --runs (default 1) per the --runs option.
DART_CACHE_RUNS="${DART_CACHE_RUNS:-1}"
DART_CACHE_WARMUP="${DART_CACHE_WARMUP:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Seconds since epoch for path (GNU/BSD stat).
_bench_mtime() {
  if stat -c %Y "$1" >/dev/null 2>&1; then stat -c %Y "$1"
  else stat -f %m "$1"
  fi
}

# When using default zig-out binaries, always refresh ReleaseFast first.
# This is intentionally unconditional: `zig build` writes a newer Debug
# zig-out/bin/zsass, so an mtime-only check can silently benchmark Debug.
ensure_releasefast_bench_bins() {
  [[ -z "${ZSASS_BIN:-}" ]] || return 0
  [[ "$SPEC_RUNNER" == "./zig-out/bin/spec_runner" ]] || return 0

  echo "bench: ensuring ReleaseFast zsass/spec_runner..." >&2
  (cd "$REPO_ROOT" && zig build -Doptimize=ReleaseFast && zig build spec-runner -Doptimize=ReleaseFast)
}

# Refuse to benchmark Debug zsass/spec_runner (--info=json exposes builtin.mode as "optimize").
refuse_debug_bench_bins() {
  [[ -n "${BENCH_ALLOW_DEBUG:-}" ]] && return 0
  _bench_refuse_debug_one "$ZSASS" "zsass"
  _bench_refuse_debug_one "$SPEC_RUNNER" "spec_runner"
}

_bench_refuse_debug_one() {
  local bin=$1
  local label=$2
  local brun=$bin
  [[ "$brun" == /* ]] || brun="$(pwd)/$brun"
  [[ -x "$brun" ]] || return 0
  local opt
# pipefail resistance: --info=json Even if binary is not supported, keep it at warn and continue
  opt=$("$brun" --info=json 2>/dev/null | jq -r '.optimize // empty' || true)
  [[ -n "$opt" ]] || {
    echo "bench: warning: could not read optimize from $label ($brun --info=json); skipping Debug check for this binary" >&2
    return 0
  }
  if [[ "$opt" == "Debug" ]]; then
    echo "bench: error: $label is a Debug build ($brun, optimize=$opt); benchmark results are not comparable to ReleaseFast." >&2
    echo "bench: Run: zig build -Doptimize=ReleaseFast && zig build spec-runner -Doptimize=ReleaseFast   Or: BENCH_ALLOW_DEBUG=1 $0 ..." >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs)   RUNS="$2"; shift 2;;
    --suite)  FILTER="$2"; shift 2;;
    -h|--help) echo "Usage: $0 [--runs N] [--suite NAME]
  From repo root, default zig-out/bin/zsass and spec_runner are refreshed as
  ReleaseFast before measuring (skip only if ZSASS_BIN is set or SPEC_RUNNER differs).
  Refuses to run if zsass or spec_runner --info=json reports optimize=Debug (override with BENCH_ALLOW_DEBUG=1).

  --runs N controls zsass measurement runs (default 1, no warmup).
  Dart-sass times are cached in .bench-dart-cache.json (keyed by sass version
  + entries.txt mtime). On cache miss, dart is measured cold with DART_CACHE_RUNS
  (default 1) hyperfine run and DART_CACHE_WARMUP (default 0) warmups.
  Set DART_CACHE_REFRESH=1 to force re-measurement; delete the cache file to
  reset everything."; exit 0;;
    *) echo "Unknown option: $1" >&2; exit 1;;
  esac
done

ensure_releasefast_bench_bins

[[ -x "$ZSASS" ]] || { echo "error: $ZSASS not found. Run: zig build -Doptimize=ReleaseFast" >&2; exit 1; }
command -v hyperfine >/dev/null || { echo "error: hyperfine not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "error: jq not found" >&2; exit 1; }
refuse_debug_bench_bins

# -- dart cache --
# dart-sass is deterministic; we cache its measured time per (suite + dart version
# + entries.txt mtime + load_paths.txt mtime). zsass is always re-measured fresh.
# Set DART_CACHE_REFRESH=1 to force re-measurement; delete DART_CACHE_FILE to clear.
DART_VERSION=""
if command -v sass >/dev/null 2>&1; then
  DART_VERSION=$(sass --version 2>/dev/null | head -1 | tr -d ' \n\t' || true)
fi
[[ -n "$DART_VERSION" ]] || DART_VERSION="unknown"

dart_cache_get() {
  local suite=$1 key=$2
  [[ -f "$DART_CACHE_FILE" ]] || return 1
  [[ -z "${DART_CACHE_REFRESH:-}" ]] || return 1
  local cached
  cached=$(jq -r --arg s "$suite" --arg k "$key" \
    '(.[$s] // {}) | select(.key == $k) | .ms // empty' \
    "$DART_CACHE_FILE" 2>/dev/null) || return 1
  [[ -n "$cached" && "$cached" != "null" ]] || return 1
  printf '%s' "$cached"
}

dart_cache_put() {
  local suite=$1 key=$2 ms=$3
  local existing="{}"
  [[ -f "$DART_CACHE_FILE" ]] && existing=$(cat "$DART_CACHE_FILE" 2>/dev/null || echo "{}")
  [[ -n "$existing" ]] || existing="{}"
  local tmp="${DART_CACHE_FILE}.tmp.$$"
  printf '%s' "$existing" | jq --arg s "$suite" --arg k "$key" --argjson m "$ms" \
    '.[$s] = {key: $k, ms: $m}' > "$tmp" 2>/dev/null && mv "$tmp" "$DART_CACHE_FILE"
}

# Build cache key from dart version + entries.txt mtime + load_paths.txt mtime.
# Bumps when dart-sass is upgraded or when the suite definition changes.
dart_cache_key_for() {
  local suite_dir=$1 entries_file=$2
  local em=0 lm=0
  em=$(_bench_mtime "$suite_dir/$entries_file" 2>/dev/null || echo 0)
  if [[ -f "$suite_dir/load_paths.txt" ]]; then
    lm=$(_bench_mtime "$suite_dir/load_paths.txt" 2>/dev/null || echo 0)
  fi
  printf '%s|%s|%s' "$DART_VERSION" "$em" "$lm"
}

tmpdir=$(mktemp -d)
# shellcheck disable=SC2064  # we want $tmpdir expanded NOW so the EXIT trap
# always references the directory we just created (not a later rebinding).
trap "rm -rf $tmpdir" EXIT

# -- Collect suites --
declare -a SUITES=()
declare -A SUITE_N=()
declare -A SUITE_SCRIPT_Z=()
declare -A SUITE_SCRIPT_D=()
declare -A SUITE_DART_KEY=()
declare -A SUITE_OUT_Z=()
declare -A SUITE_OUT_D=()
# shellcheck disable=SC2034  # SUITE_DIR is read by suite-emitting helpers below.
declare -A SUITE_DIR=()

for d in "$FIXTURES"/*/; do
  suite=$(basename "$d")
  env="$d/suite.env"
  [[ -f "$env" ]] || continue
  [[ -z "$FILTER" || "$suite" == "$FILTER" ]] || continue

  # shellcheck source=/dev/null  # `$env` is fixture-controlled per suite.
  layout=$( source "$env" && echo "${layout:-tree}" )
  # shellcheck source=/dev/null
  src_dir=$( source "$env" && echo "${source_dir:-source}" )
  # shellcheck source=/dev/null
  samples_dir=$( source "$env" && echo "${samples_dir:-}" )
  # shellcheck source=/dev/null
  ef_name=$( source "$env" && echo "${entries_file:-entries.txt}" )
  [[ -f "$d/$ef_name" ]] || continue

  # Build load path args (matching realworld_suite.sh)
  lp=""
  if [[ "$layout" == "tree" ]]; then
    printf -v lp_arg '%q' "--load-path=$d/$src_dir"
    lp="$lp $lp_arg"
  elif [[ "$layout" == "samples" && -n "$samples_dir" ]]; then
    printf -v lp_arg '%q' "--load-path=$d/$samples_dir"
    lp="$lp $lp_arg"
  fi
  [[ ! -f "$d/load_paths.txt" ]] || while IFS= read -r p; do
    if [[ -n "$p" ]]; then
      printf -v lp_arg '%q' "--load-path=$d/$p"
      lp="$lp $lp_arg"
    fi
  done < "$d/load_paths.txt"

  # Build multi-input args: input1:output1 input2:output2 ...
  z_outd="$tmpdir/out/$suite/zsass"
  d_outd="$tmpdir/out/$suite/dart"
  mkdir -p "$z_outd" "$d_outd"
  multi_args_z=""
  multi_args_d=""
  n=0
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    if [[ "$layout" == "samples" ]]; then
      input="$d$samples_dir/$rel"
    else
      input="$d$src_dir/$rel"
    fi
    [[ -f "$input" ]] || continue
    z_out="$z_outd/${rel%.*}.css"
    d_out="$d_outd/${rel%.*}.css"
    mkdir -p "$(dirname "$z_out")" "$(dirname "$d_out")"
    printf -v io_arg '%q' "$input:$z_out"
    multi_args_z="$multi_args_z $io_arg"
    printf -v io_arg '%q' "$input:$d_out"
    multi_args_d="$multi_args_d $io_arg"
    n=$((n+1))
  done < "$d/$ef_name"
  [[ $n -gt 0 ]] || continue

  # Write compile scripts (single process, all entries)
  z_script="$tmpdir/$suite.z.sh"
  d_script="$tmpdir/$suite.d.sh"
  echo "#!/bin/bash" > "$z_script"
  echo "ZSASS_CSS_CACHE=0 $ZSASS --no-source-map --quiet$lp$multi_args_z 2>/dev/null" >> "$z_script"
  chmod +x "$z_script"
  echo "#!/bin/bash" > "$d_script"
  echo "sass --no-source-map --quiet-deps$lp$multi_args_d 2>/dev/null" >> "$d_script"
  chmod +x "$d_script"

  SUITES+=("$suite")
  SUITE_N[$suite]=$n
  SUITE_SCRIPT_Z[$suite]="$z_script"
  SUITE_SCRIPT_D[$suite]="$d_script"
  SUITE_OUT_Z[$suite]="$z_outd"
  SUITE_OUT_D[$suite]="$d_outd"
  # shellcheck disable=SC2034  # SUITE_DIR is consulted by post-loop reporting.
  SUITE_DIR[$suite]="$d"
  SUITE_DART_KEY[$suite]=$(dart_cache_key_for "$d" "$ef_name")
done

# -- Benchmark --
declare -A Z_MS=()
declare -A D_MS=()
rm -rf "$DIFF_DIR"
mkdir -p "$DIFF_DIR"
total=${#SUITES[@]}
count=0

for suite in "${SUITES[@]}"; do
  count=$((count+1))
  n="${SUITE_N[$suite]}"
  printf "\r[%d/%d] %s (%d)...              " "$count" "$total" "$suite" "$n" >&2

  json="$tmpdir/$suite.json"

  # Test both can compile and produce the same raw CSS before benchmarking.
  z_ok=true; bash "${SUITE_SCRIPT_Z[$suite]}" || z_ok=false
  d_ok=true; bash "${SUITE_SCRIPT_D[$suite]}" || d_ok=false
  if $z_ok && $d_ok; then
    diff_file="$DIFF_DIR/$suite.diff"
    if diff -ru "${SUITE_OUT_D[$suite]}" "${SUITE_OUT_Z[$suite]}" > "$diff_file"; then
      rm -f "$diff_file"
    else
      z_ok=false
    fi
  fi

  if $z_ok && $d_ok; then
    cache_key="${SUITE_DART_KEY[$suite]}"
    cached_d=$(dart_cache_get "$suite" "$cache_key" 2>/dev/null || true)
    if [[ -n "$cached_d" ]]; then
      # Cache hit: only measure zsass
      hyperfine --warmup "$WARMUP" --runs "$RUNS" --export-json "$json" \
        -n zsass "bash ${SUITE_SCRIPT_Z[$suite]}" \
        >/dev/null 2>&1
      Z_MS[$suite]=$(jq -r '.results[0].mean * 1000 | . * 10 | floor | . / 10' "$json")
      D_MS[$suite]="$cached_d"
    else
      # Cache miss: measure both, populate cache with stable dart timing
      hyperfine --warmup "$DART_CACHE_WARMUP" --runs "$DART_CACHE_RUNS" --export-json "$json" \
        -n zsass "bash ${SUITE_SCRIPT_Z[$suite]}" \
        -n dart "bash ${SUITE_SCRIPT_D[$suite]}" \
        >/dev/null 2>&1
      Z_MS[$suite]=$(jq -r '.results[0].mean * 1000 | . * 10 | floor | . / 10' "$json")
      D_MS[$suite]=$(jq -r '.results[1].mean * 1000 | . * 10 | floor | . / 10' "$json")
      dart_cache_put "$suite" "$cache_key" "${D_MS[$suite]}"
    fi
  elif $z_ok; then
    hyperfine --warmup "$WARMUP" --runs "$RUNS" --export-json "$json" \
      -n zsass "bash ${SUITE_SCRIPT_Z[$suite]}" >/dev/null 2>&1
    Z_MS[$suite]=$(jq -r '.results[0].mean * 1000 | . * 10 | floor | . / 10' "$json")
    D_MS[$suite]="FAIL"
  elif $d_ok; then
# zsass fails but dart succeeds -- measure dart, record zsass as FAIL
    cache_key="${SUITE_DART_KEY[$suite]}"
    cached_d=$(dart_cache_get "$suite" "$cache_key" 2>/dev/null || true)
    if [[ -n "$cached_d" ]]; then
      D_MS[$suite]="$cached_d"
    else
      hyperfine --warmup "$DART_CACHE_WARMUP" --runs "$DART_CACHE_RUNS" --export-json "$json" \
        -n dart "bash ${SUITE_SCRIPT_D[$suite]}" >/dev/null 2>&1
      D_MS[$suite]=$(jq -r '.results[0].mean * 1000 | . * 10 | floor | . / 10' "$json")
      dart_cache_put "$suite" "$cache_key" "${D_MS[$suite]}"
    fi
    Z_MS[$suite]="FAIL"
  else
    Z_MS[$suite]="FAIL"
    D_MS[$suite]="FAIL"
  fi
done
printf "\r%50s\r" "" >&2

# -- sass-spec --
spec_z=""
spec_d=""
if [[ -x "$SPEC_RUNNER" && -d "$SPEC_DIR" ]] && [[ -z "$FILTER" || "$FILTER" == "sass-spec" ]]; then
  printf "\r[spec] sass-spec (extract)...       " >&2
  # Extract test inputs from HRX
  spec_inputs="$tmpdir/spec-inputs"
  spec_out="$tmpdir/spec-out"
  mkdir -p "$spec_inputs" "$spec_out"
  python3 -c "
import os, pathlib, shutil, sys
sd, od = sys.argv[1], sys.argv[2]
n = 0
for root, dirs, files in os.walk(sd):
    for f in files:
        if not f.endswith('.hrx'): continue
        hp = os.path.join(root, f)
        content = pathlib.Path(hp).read_text(errors='replace')
        cn = None; cl = []
        for line in content.split('\n'):
            if line.startswith('<===> ') or line == '<===>':
                if cn and cn.endswith('input.scss'):
                    rel = os.path.relpath(hp, sd).replace('.hrx','')
                    td = cn.rsplit('input.scss',1)[0].rstrip('/')
                    op = os.path.join(od, rel, td, 'input.scss') if td else os.path.join(od, rel, 'input.scss')
                    os.makedirs(os.path.dirname(op), exist_ok=True)
                    pathlib.Path(op).write_text('\n'.join(cl))
                    n += 1
                cn = line[6:].strip() if line.startswith('<===> ') else None
                cl = []
            else:
                cl.append(line)
        if cn and cn.endswith('input.scss'):
            rel = os.path.relpath(hp, sd).replace('.hrx','')
            td = cn.rsplit('input.scss',1)[0].rstrip('/')
            op = os.path.join(od, rel, td, 'input.scss') if td else os.path.join(od, rel, 'input.scss')
            os.makedirs(os.path.dirname(op), exist_ok=True)
            pathlib.Path(op).write_text('\n'.join(cl))
            n += 1
    if 'input.scss' in files:
        src = os.path.join(root, 'input.scss')
        dst = os.path.join(od, os.path.relpath(src, sd))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)
        n += 1
print(n)
" "$SPEC_DIR" "$spec_inputs" >/dev/null

  json="$tmpdir/sass-spec.json"
  # sass-spec dart cache key: dart version + SPEC_DIR mtime
  spec_dir_mtime=$(_bench_mtime "$SPEC_DIR" 2>/dev/null || echo 0)
  spec_cache_key="${DART_VERSION}|${spec_dir_mtime}"
  cached_spec_d=$(dart_cache_get "__sass_spec__" "$spec_cache_key" 2>/dev/null || true)
  if [[ -n "$cached_spec_d" ]]; then
    printf "\r[spec] sass-spec (zsass)...         " >&2
    hyperfine --warmup "$WARMUP" --runs "$RUNS" -i --export-json "$json" \
      -n zsass "$SPEC_RUNNER --spec-dir $SPEC_DIR" \
      >/dev/null 2>&1
    spec_z=$(jq -r '.results[0].mean * 1000 | floor' "$json")
    # Cache stores ms as float; spec_d is integer
    spec_d=$(printf '%.0f' "$cached_spec_d")
  else
    printf "\r[spec] sass-spec (zsass+dart)...    " >&2
    hyperfine --warmup "$DART_CACHE_WARMUP" --runs "$DART_CACHE_RUNS" -i --export-json "$json" \
      -n zsass "$SPEC_RUNNER --spec-dir $SPEC_DIR" \
      -n dart "sass --no-source-map --quiet-deps $spec_inputs:$spec_out" \
      >/dev/null 2>&1
    spec_z=$(jq -r '.results[0].mean * 1000 | floor' "$json")
    spec_d=$(jq -r '.results[1].mean * 1000 | floor' "$json")
    dart_cache_put "__sass_spec__" "$spec_cache_key" "$spec_d"
  fi
  printf "\r%50s\r" "" >&2
fi

# -- Table --
{
lines=()
for suite in "${SUITES[@]}"; do
  z="${Z_MS[$suite]}"
  d="${D_MS[$suite]}"
  [[ "$z" != "FAIL" || "$d" != "FAIL" ]] || continue
  n="${SUITE_N[$suite]}"
  label="$suite"; [[ "$n" -le 1 ]] || label="$suite ($n)"
  if [[ "$z" == "FAIL" ]]; then
    ratio="\u{2014}"    ratio_key="9999.000000"
  elif [[ "$d" == "FAIL" ]]; then
    ratio="\u{2014}"    ratio_key="9999.000000"
  else
    ratio=$(awk "BEGIN{d=$d+0; z=$z+0; if(d>0.1) printf \"%.2f\", z/d; else printf \"\u{2014}\"}" 2>/dev/null || printf "\u{2014}")
    if [[ "$ratio" == "\u{2014}" ]]; then
      ratio_key="9998.000000"
    else
      ratio_key=$(awk "BEGIN{printf \"%.6f\", $ratio}")
    fi
  fi
  lines+=("${ratio_key}|${label}|${z}|${d}|${ratio}")
done
if [[ -n "$spec_z" ]]; then
  if [[ -n "$spec_d" ]]; then
    spec_ratio=$(awk "BEGIN{printf \"%.2f\", $spec_z/$spec_d}")
    spec_ratio_key=$(awk "BEGIN{printf \"%.6f\", $spec_ratio}")
    lines+=("${spec_ratio_key}|sass-spec (~13400)|${spec_z}|${spec_d}|${spec_ratio}")
  else
    lines+=("9998.000000|sass-spec (~13400)|${spec_z}|\u{2014}|\u{2014}")
  fi
fi
mapfile -t sorted < <(printf '%s\n' "${lines[@]}" | sort -t'|' -k1,1g)

printf "| %-26s | %9s | %9s | %7s |\n" "Suite" "zsass" "dart" "ratio"
printf "|%-28s|%11s|%11s|%9s|\n" "----------------------------" "-----------" "-----------" "---------"
for line in "${sorted[@]}"; do
  rest=${line#*|}
  label=${rest%%|*}
  rest=${rest#*|}
  z=${rest%%|*}
  rest=${rest#*|}
  d=${rest%%|*}
  ratio=${rest#*|}
  if [[ "$z" == "FAIL" ]]; then
    if [[ "$d" == "FAIL" ]]; then
      printf "| %-26s | %9s | %9s | %7s |\n" "$label" "FAIL" "FAIL" "\u{2014}"
    else
      printf "| %-26s | %9s | %8sms | %7s |\n" "$label" "FAIL" "$d" "\u{2014}"
    fi
  elif [[ "$d" == "FAIL" ]]; then
    printf "| %-26s | %8sms | %9s | %7s |\n" "$label" "$z" "FAIL" "\u{2014}"
  else
    if [[ "$ratio" == "\u{2014}" ]]; then
      printf "| %-26s | %8sms | %8sms | %7s |\n" "$label" "$z" "$d" "\u{2014}"
    else
      printf "| %-26s | %8sms | %8sms | %5sx |\n" "$label" "$z" "$d" "$ratio"
    fi
  fi
done
} > "$OUTFILE"
cat "$OUTFILE"
echo "" >&2
echo "Saved to $OUTFILE" >&2
if [[ -n "$(find "$DIFF_DIR" -type f -name '*.diff' -print -quit 2>/dev/null)" ]]; then
  echo "Raw CSS diffs saved to $DIFF_DIR" >&2
fi
