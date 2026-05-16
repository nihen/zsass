#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "realworld-suite: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  scripts/realworld_suite.sh [options]

Options:
  --mode MODE            check | bench. Default: check
  --suite-root DIR       Local suite dir or fixture-repo root. Default: ../zsass-realworld-fixtures
  --work-root DIR        Output root for per-run logs/results. Default: <suite-root>/.zsass-realworld-runs
  --zsass-bin PATH       zsass binary path. Default: zig-out/bin/zsass
  --jobs N               Check-mode worker count. Default: cpu*2 (fallback: 8)
  --fail-fast            Stop on the first compile failure or CSS diff
  --allow-normalized-pass
                          Deprecated no-op. Raw CSS mismatches always fail;
                          normalization is recorded as diagnostic context only.
  --runs N               Benchmark repetitions for bench mode. Default: 3
  -h, --help             Show this help

Suite root layout:
  suite.env              Required shell-style config
  load_paths.txt         Optional extra load paths, one per line, in order

Supported suite.env keys:
  layout=tree|samples

For layout=tree:
  source_dir=source
  expected_dir=expected
  entries_file=entries.txt        Optional; defaults to auto-discovery
  perf_baseline=perf.tsv          Optional for perf mode
  compile_timeout=60              Optional
  bench_timeout=30                Optional

For layout=samples:
  samples_dir=samples
  reference_suffix=.ref.css
  entries_file=entries.txt        Optional; defaults to auto-discovery
  perf_baseline=perf.tsv          Optional for perf mode
  compile_timeout=60              Optional
  bench_timeout=30                Optional

Notes:
  - Real assets, expected CSS, and perf baselines are intentionally local-only.
  - Set ZSASS_REALWORLD_SUITE_ROOT to override the default suite location.
  - If suite-root itself has no suite.env but contains child suite directories,
    every child suite is run in sorted order.
  - tree layout compares against expected_dir/<entry>.css.
  - samples layout compares against <entry><reference_suffix> beside each source file.
  - check mode records elapsed time and RSS during the same compile used for CSS validation.
  - check mode runs in parallel by default; bench mode stays serial.
EOF
}

repo_root() {
  local script_dir
  script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  cd -- "$script_dir/.." && pwd
}

absolute_path() {
  local path="$1"
  if [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s\n' "$PWD/$path"
  fi
}

now_sec() {
  date +%s.%N
}

elapsed_sec() {
  awk "BEGIN { printf \"%.2f\", $2 - $1 }"
}

default_check_jobs() {
  local cpus
  cpus=""

  if command -v nproc >/dev/null 2>&1; then
    cpus=$(nproc 2>/dev/null || true)
  fi
  if [[ ! "$cpus" =~ ^[1-9][0-9]*$ ]] && command -v getconf >/dev/null 2>&1; then
    cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)
  fi
  if [[ ! "$cpus" =~ ^[1-9][0-9]*$ ]] && command -v sysctl >/dev/null 2>&1; then
    cpus=$(sysctl -n hw.ncpu 2>/dev/null || true)
  fi
  if [[ ! "$cpus" =~ ^[1-9][0-9]*$ ]]; then
    cpus=4
  fi

  printf '%s\n' "$((cpus * 2))"
}

collect_suite_roots_arg() {
  local candidate="$1"
  if [[ -f "$candidate/suite.env" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  local -a nested_suite_envs=()
  local line
  while IFS= read -r line; do
    nested_suite_envs+=("$line")
  done < <(find "$candidate" -mindepth 2 -maxdepth 2 -type f -name 'suite.env' | sort)

  if [[ ${#nested_suite_envs[@]} -eq 0 ]]; then
    die "missing suite.env under $candidate (pass --suite-root <suite-dir> or add child suites)"
  fi

  for line in "${nested_suite_envs[@]}"; do
    dirname "$line"
  done
}

resolve_suite_path() {
  local path="$1"
  if [[ -z "$path" ]]; then
    return 0
  fi
  if [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s\n' "$suite_root/$path"
  fi
}

normalize_rel() {
  local rel="$1"
  rel=${rel#./}
  printf '%s\n' "$rel"
}

append_unique_path() {
  local candidate="$1"
  local existing
  for existing in "${load_paths[@]}"; do
    if [[ "$existing" == "$candidate" ]]; then
      return 0
    fi
  done
  load_paths+=("$candidate")
}

read_load_paths_file() {
  local file="$suite_root/load_paths.txt"
  [[ -f "$file" ]] || return 0
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%%#*}
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [[ -n "$line" ]] || continue
    append_unique_path "$(resolve_suite_path "$line")"
  done < "$file"
}

css_rel_for_entry() {
  local rel="$1"
  printf '%s.css\n' "${rel%.*}"
}

collect_entries_from_file() {
  local file="$1"
  [[ -f "$file" ]] || die "missing entries_file: $file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%%#*}
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [[ -n "$line" ]] || continue
    entries+=("$(normalize_rel "$line")")
  done < "$file"
}

collect_entries_with_zsass() {
  local root="$1"
  local tmp_dir json_file
  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/realworld-zsass-dryrun.XXXXXX")
  json_file="$tmp_dir/targets.json"
  mkdir -p "$tmp_dir/out"
  "$zsass_bin" --dry-run=json "$root:$tmp_dir/out/" > "$json_file"
  python3 - "$root" "$tmp_dir/out" "$json_file" <<'PY'
import json
import os
import pathlib
import sys

root = os.path.abspath(sys.argv[1])
out_root = os.path.abspath(sys.argv[2])
payload = json.loads(pathlib.Path(sys.argv[3]).read_text())
selected = {}
order = []

def rank(path_str: str) -> int:
    ext = pathlib.Path(path_str).suffix.lower()
    if ext in (".scss", ".sass"):
        return 0
    if ext == ".css":
        return 1
    return 2

for target in payload.get("targets", []):
    if target.get("input_kind") != "file":
        continue
    input_path = target.get("input_path")
    output_path = target.get("output_path")
    if not input_path:
        continue
    if not output_path:
        continue
    rel = os.path.relpath(os.path.abspath(input_path), root)
    if rel == ".." or rel.startswith(f"..{os.sep}"):
        raise SystemExit(f"realworld-suite: dry-run target escaped root: {input_path}")
    output_rel = os.path.relpath(os.path.abspath(output_path), out_root)
    if output_rel == ".." or output_rel.startswith(f"..{os.sep}"):
        raise SystemExit(f"realworld-suite: dry-run output escaped temp root: {output_path}")
    rel = rel.replace(os.sep, "/")
    output_rel = output_rel.replace(os.sep, "/")
    chosen = selected.get(output_rel)
    if chosen is None:
        selected[output_rel] = rel
        order.append(output_rel)
        continue
    if rank(rel) < rank(chosen):
        selected[output_rel] = rel

for output_rel in sorted(order):
    print(selected[output_rel])
PY
  rm -rf "$tmp_dir"
}

collect_entries_tree() {
  if [[ -n "${entries_file:-}" ]]; then
    collect_entries_from_file "$(resolve_suite_path "$entries_file")"
    return 0
  fi

  while IFS= read -r line; do
    entries+=("$line")
  done < <(collect_entries_with_zsass "$source_root")
}

collect_entries_samples() {
  if [[ -n "${entries_file:-}" ]]; then
    collect_entries_from_file "$(resolve_suite_path "$entries_file")"
    return 0
  fi

  while IFS= read -r line; do
    entries+=("$line")
  done < <(collect_entries_with_zsass "$samples_root")
}

entry_input_path() {
  local rel="$1"
  case "$layout" in
    tree) printf '%s/%s\n' "$source_root" "$rel" ;;
    samples) printf '%s/%s\n' "$samples_root" "$rel" ;;
    *) die "unsupported layout: $layout" ;;
  esac
}

entry_expected_path() {
  local rel="$1"
  case "$layout" in
    tree) printf '%s/%s\n' "$expected_root" "$(css_rel_for_entry "$rel")" ;;
    samples)
      local input
      input=$(entry_input_path "$rel")
      printf '%s%s\n' "${input%.*}" "$reference_suffix"
      ;;
    *)
      die "unsupported layout: $layout"
      ;;
  esac
}

entry_compile_load_paths() {
  local rel="$1"
  case "$layout" in
    tree)
      compile_load_paths=("$source_root" "${load_paths[@]}")
      ;;
    samples)
      local project_root
      if [[ "$rel" == */* ]]; then
        project_root="$samples_root/${rel%%/*}"
      else
        project_root="$samples_root"
      fi
      compile_load_paths=("$project_root" "$samples_root" "${load_paths[@]}")
      ;;
    *)
      die "unsupported layout: $layout"
      ;;
  esac
}

run_zsass_timed() {
  local timeout_secs="$1"
  local input="$2"
  local output="$3"
  local log="$4"
  local time_file="$5"
  shift 5
  local -a cmd
  if [[ "${ZSASS_REALWORLD_ALLOW_CSS_CACHE:-0}" == "1" ]]; then
    cmd=("/usr/bin/time" "-f" "%e\t%M\t%x" "-o" "$time_file" "timeout" "$timeout_secs" "$zsass_bin")
  else
    cmd=("/usr/bin/time" "-f" "%e\t%M\t%x" "-o" "$time_file" "timeout" "$timeout_secs" "env" "ZSASS_CSS_CACHE=0" "$zsass_bin")
  fi
  if [[ "${quiet_deps:-1}" == "1" ]]; then
    cmd+=("--quiet")
  fi
  while [[ $# -gt 0 ]]; do
    cmd+=("--load-path" "$1")
    shift
  done
  cmd+=("--no-source-map" "$input:$output")
  mkdir -p "$(dirname "$output")" "$(dirname "$log")" "$(dirname "$time_file")"
  "${cmd[@]}" >"$log" 2>&1
}

read_timing_file() {
  local time_file="$1"
  timing_sec="nan"
  timing_rss="0"
  timing_exit="missing"
  if [[ -f "$time_file" ]]; then
    IFS=$'\t' read -r timing_sec timing_rss timing_exit < "$time_file"
  fi
}

compile_entry() {
  local input="$1"
  local output="$2"
  local log="$3"
  local time_file="$4"
  shift 4
  run_zsass_timed "$compile_timeout" "$input" "$output" "$log" "$time_file" "$@"
}

read_suite() {
  local suite_env="$suite_root/suite.env"
  [[ -f "$suite_env" ]] || die "missing suite.env: $suite_env"

  unset layout suite_name source_dir expected_dir samples_dir entries_file
  unset perf_baseline perf_baseline_wall_sec perf_baseline_jobs
  unset compile_timeout bench_timeout quiet_deps reference_suffix
  unset source_root expected_root samples_root

  # shellcheck disable=SC1090
  source "$suite_env"

  layout=${layout:-tree}
  suite_name=${suite_name:-$(basename "$suite_root")}
  compile_timeout=${compile_timeout:-60}
  bench_timeout=${bench_timeout:-30}
  quiet_deps=${quiet_deps:-1}
  reference_suffix=${reference_suffix:-.ref.css}

  load_paths=()
  read_load_paths_file

  case "$layout" in
    tree)
      source_root=$(resolve_suite_path "${source_dir:-source}")
      expected_root=$(resolve_suite_path "${expected_dir:-expected}")
      [[ -d "$source_root" ]] || die "missing tree source_dir: $source_root"
      [[ -d "$expected_root" || "$mode" == "bench" ]] || die "missing tree expected_dir: $expected_root"
      ;;
    samples)
      samples_root=$(resolve_suite_path "${samples_dir:-samples}")
      [[ -d "$samples_root" ]] || die "missing samples_dir: $samples_root"
      ;;
    *)
      die "unsupported layout in suite.env: $layout"
      ;;
  esac

  entries=()
  case "$layout" in
    tree) collect_entries_tree ;;
    samples) collect_entries_samples ;;
  esac
  [[ ${#entries[@]} -gt 0 ]] || die "no entries found in suite: $suite_root"

  perf_baseline_path=""
  if [[ -n "${perf_baseline:-}" ]]; then
    perf_baseline_path=$(resolve_suite_path "$perf_baseline")
  elif [[ -f "$suite_root/perf.tsv" ]]; then
    perf_baseline_path="$suite_root/perf.tsv"
  fi
  perf_baseline_wall_sec=${perf_baseline_wall_sec:-}
  perf_baseline_jobs=${perf_baseline_jobs:-}
}

print_check_summary() {
  cat <<EOF
realworld-suite check summary
  suite:    $suite_name
  root:     $suite_root
  total:    $total_count
  matched:  $matched_count
  diffs:    $diff_count
  normalized: $normalized_count
  failed:   $failed_count
  missing:  $missing_count
  results:  $run_root
EOF
}

progress_setup() {
  progress_label="$1"
  progress_total="$2"
  # shellcheck disable=SC2034  # consumed by the progress renderer below.
  progress_width="${#progress_total}"
  progress_started_at=$(now_sec)
  if [[ -t 1 ]]; then
    progress_use_tty=1
  else
    progress_use_tty=0
  fi
}

progress_percent() {
  local current="$1"
  awk "BEGIN { printf \"%.1f%%\", (100 * $current) / $progress_total }"
}

format_elapsed() {
  local start="$1"
  local now="$2"
  awk "BEGIN {
    total = int(($now - $start) + 0.5)
    hours = int(total / 3600)
    mins = int((total % 3600) / 60)
    secs = total % 60
    if (hours > 0) {
      printf \"%d:%02d:%02d\", hours, mins, secs
    } else {
      printf \"%02d:%02d\", mins, secs
    }
  }"
}

progress_update() {
  local current="$1"
  local rel="${2:-}"
  local msg
  local pct elapsed now count
  pct=$(progress_percent "$current")
  now=$(now_sec)
  elapsed=$(format_elapsed "$progress_started_at" "$now")
  count=$(printf '%d/%d' "$current" "$progress_total")
  msg=$(printf '  [%s] %s %s %s' "$progress_label" "$elapsed" "$count" "$pct")
  if [[ -n "$rel" ]]; then
    msg="$msg  $rel"
  fi

  if [[ "$progress_use_tty" == "1" ]]; then
    printf '\r\033[2K%s' "$msg"
  else
    printf '%s\n' "$msg"
  fi
}

progress_finish() {
  if [[ "${progress_use_tty:-0}" == "1" ]]; then
    printf '\r\033[2K'
  fi
}

entry_key() {
  printf '%05d\n' "$1"
}

check_status_file() {
  printf '%s/%s.status\n' "$check_results_dir" "$(entry_key "$1")"
}

check_metrics_file() {
  printf '%s/%s.metrics\n' "$check_metrics_dir" "$(entry_key "$1")"
}

process_check_entry() {
  local entry_index="$1"
  local rel="$2"
  local input expected output log diff_file time_file status_file metrics_file
  status_file=$(check_status_file "$entry_index")
  metrics_file=$(check_metrics_file "$entry_index")

  input=$(entry_input_path "$rel")
  expected=$(entry_expected_path "$rel")
  output="$run_root/actual/$(css_rel_for_entry "$rel")"
  log="$run_root/logs/${rel%.*}.log"
  time_file="$run_root/time/${rel%.*}.time"
  diff_file="$run_root/diffs/$(css_rel_for_entry "$rel").diff"

  mkdir -p "$(dirname "$diff_file")" "$(dirname "$status_file")" "$(dirname "$metrics_file")"

  if [[ ! -f "$expected" ]]; then
    mkdir -p "$(dirname "$status_file")"
    printf 'missing\t%s\t%s\n' "$rel" "$expected" > "$status_file"
    [[ "$fail_fast" == "1" ]] && return 1
    return 0
  fi

  load_paths=("${base_load_paths[@]}")
  entry_compile_load_paths "$rel"
  if ! compile_entry "$input" "$output" "$log" "$time_file" "${compile_load_paths[@]}"; then
    read_timing_file "$time_file"
    mkdir -p "$(dirname "$status_file")" "$(dirname "$metrics_file")"
    printf '%s\t%s\t%s\t%s\n' "$rel" "$timing_sec" "$timing_rss" "$timing_exit" > "$metrics_file"
    printf 'compile_fail\t%s\t%s\n' "$rel" "$log" > "$status_file"
    [[ "$fail_fast" == "1" ]] && return 1
    return 0
  fi

  read_timing_file "$time_file"
  mkdir -p "$(dirname "$status_file")" "$(dirname "$metrics_file")"
  printf '%s\t%s\t%s\t%s\n' "$rel" "$timing_sec" "$timing_rss" "$timing_exit" > "$metrics_file"

  if cmp -s "$output" "$expected"; then
    printf 'match\t%s\n' "$rel" > "$status_file"
    return 0
  fi

  diff -u "$expected" "$output" > "$diff_file" || true
  local normalized_log status_kind
  normalized_log="$run_root/normalized/$(css_rel_for_entry "$rel").log"
  mkdir -p "$(dirname "$normalized_log")"
  status_kind="diff"
  if python3 "$normalizer" "$expected" "$output" > "$normalized_log" 2>&1; then
    rm -f "$normalized_log"
  elif grep -q '^normalized_equal: raw CSS differs' "$normalized_log"; then
    status_kind="diff_normalized_equal"
  else
    rm -f "$normalized_log"
  fi
  printf '%s\t%s\t%s\n' "$status_kind" "$rel" "$diff_file" > "$status_file"
  [[ "$fail_fast" == "1" ]] && return 1
  return 0
}

rebuild_check_outputs() {
  : > "$summary_file"
  printf 'rel_path\tzsass_sec\tzsass_rss_kb\tzsass_exit\n' > "$metrics_file"

  total_count=0
  matched_count=0
  normalized_count=0
  diff_count=0
  failed_count=0
  missing_count=0

  local entry_index rel status_file metrics_part kind a b
  for (( entry_index = 1; entry_index <= entry_total; entry_index += 1 )); do
    status_file=$(check_status_file "$entry_index")
    metrics_part=$(check_metrics_file "$entry_index")
    [[ -f "$status_file" ]] || continue

    total_count=$((total_count + 1))
    IFS=$'\t' read -r kind a b < "$status_file"
    case "$kind" in
      match)
        matched_count=$((matched_count + 1))
        printf 'match\t%s\n' "$a" >> "$summary_file"
        ;;
      diff)
        diff_count=$((diff_count + 1))
        printf 'diff\t%s\t%s\n' "$a" "$b" >> "$summary_file"
        ;;
      diff_normalized_equal)
        diff_count=$((diff_count + 1))
        normalized_count=$((normalized_count + 1))
        printf 'diff_normalized_equal\t%s\t%s\n' "$a" "$b" >> "$summary_file"
        ;;
      compile_fail)
        failed_count=$((failed_count + 1))
        printf 'compile_fail\t%s\t%s\n' "$a" "$b" >> "$summary_file"
        ;;
      missing)
        missing_count=$((missing_count + 1))
        printf 'missing\t%s\t%s\n' "$a" "$b" >> "$summary_file"
        ;;
      *)
        die "unknown check result kind in $status_file: $kind"
        ;;
    esac

    if [[ -f "$metrics_part" ]]; then
      cat "$metrics_part" >> "$metrics_file"
      printf '\n' >> "$metrics_file"
    fi
  done
}

kill_active_check_jobs() {
  local pid
  for pid in "${active_pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in "${active_pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  active_pids=()
  active_indexes=()
}

wait_for_check_job() {
  local i pid rc rel
  while :; do
    for i in "${!active_pids[@]}"; do
      pid="${active_pids[$i]}"
      if ! kill -0 "$pid" 2>/dev/null; then
        if wait "$pid"; then
          rc=0
        else
          rc=$?
        fi
        check_last_finished_index="${active_indexes[$i]}"
        rel="${entries[$((check_last_finished_index - 1))]}"
        unset 'active_pids[i]' 'active_indexes[i]'
        active_pids=("${active_pids[@]}")
        active_indexes=("${active_indexes[@]}")
        completed_count=$((completed_count + 1))
        progress_update "$completed_count" "$rel"
        if [[ "$fail_fast" == "1" && "$rc" -ne 0 ]]; then
          check_failed_index="$check_last_finished_index"
          return 1
        fi
        return 0
      fi
    done
    sleep 0.05
  done
}

print_check_failure_and_die() {
  local status_file kind rel extra
  status_file=$(check_status_file "$check_failed_index")
  [[ -f "$status_file" ]] || die "check failed before a status file was written"

  IFS=$'\t' read -r kind rel extra < "$status_file"
  case "$kind" in
    compile_fail)
      tail -n 20 "$extra" >&2 || true
      print_check_summary
      die "compile failed for $rel"
      ;;
    diff|diff_normalized_equal)
      sed -n '1,120p' "$extra" >&2 || true
      print_check_summary
      die "css diff for $rel"
      ;;
    missing)
      print_check_summary
      die "missing expected CSS for $rel"
      ;;
    *)
      die "unexpected fail-fast result kind: $kind"
      ;;
  esac
}

print_perf_report() {
  local measured_file="$1"
  local output_file="$2"
  local title="$3"
  [[ -n "$perf_baseline_path" ]] || return 0
  [[ -f "$perf_baseline_path" ]] || return 0

  printf 'rel_path\tzsass_sec\tzsass_rss_kb\tzsass_exit\tdart_sec\tdart_rss_kb\ttime_ratio\trss_ratio\n' > "$output_file"

  local rel dart_sec dart_rss rest measured_line zsass_sec zsass_rss zsass_exit time_ratio rss_ratio
  while IFS=$'\t' read -r rel dart_sec dart_rss rest; do
    [[ -n "$rel" ]] || continue
    [[ "$rel" == "rel_path" ]] && continue

    measured_line=$(awk -F'\t' -v rel="$rel" '$1 == rel { print; exit }' "$measured_file")
    if [[ -z "$measured_line" ]]; then
      continue
    fi
    IFS=$'\t' read -r _ zsass_sec zsass_rss zsass_exit <<< "$measured_line"

    time_ratio="inf"
    rss_ratio="inf"
    if [[ "$zsass_sec" != "nan" ]] && awk "BEGIN { exit !($dart_sec > 0) }"; then
      time_ratio=$(awk "BEGIN { printf \"%.3f\", $zsass_sec / $dart_sec }")
    fi
    if awk "BEGIN { exit !($dart_rss > 0) }"; then
      rss_ratio=$(awk "BEGIN { printf \"%.3f\", $zsass_rss / $dart_rss }")
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$rel" "$zsass_sec" "$zsass_rss" "$zsass_exit" "$dart_sec" "$dart_rss" "$time_ratio" "$rss_ratio" \
      >> "$output_file"
  done < "$perf_baseline_path"

  echo "$title"
  echo "  baseline:     $perf_baseline_path"
  echo "  results:      $output_file"
  awk -F'\t' \
    -v wall_sec="${suite_wall_sec:-}" \
    -v worker_count="${suite_worker_count:-}" \
    -v baseline_wall_sec="${perf_baseline_wall_sec:-}" \
    -v baseline_jobs="${perf_baseline_jobs:-}" '
    function fmt_sec(v) {
      v += 0
      if (v < 0.005) return "<0.01s"
      return sprintf("%.2fs", v)
    }
    NR == 1 { next }
    {
      total += 1
      zsass_sum += $2 + 0
      dart_sum += $5 + 0
      rss_ratio_sum += $8 + 0
      rss_ratio_rows += 1
      if ($7 == "inf") {
        zero_dart_rows += 1
      } else {
        finite_time_rows += 1
        if (($7 + 0) > worst_time_ratio) {
          worst_time_ratio = $7 + 0
          worst_time_path = $1
        }
      }
      if (($2 + 0) > slowest_zsass_sec) {
        slowest_zsass_sec = $2 + 0
        slowest_zsass_path = $1
      }
      if ($8 != "inf" && ($8 + 0) > worst_rss_ratio) {
        worst_rss_ratio = $8 + 0
        worst_rss_path = $1
      }
    }
    END {
      print "  overall:"
      if (wall_sec != "") {
        printf "    wall time:        %s", fmt_sec(wall_sec)
        if (worker_count != "") {
          printf "  (%s jobs)", worker_count
        }
        if (baseline_wall_sec != "") {
          printf "  vs %s dart wall", fmt_sec(baseline_wall_sec)
          if (baseline_jobs != "") {
            printf " (%s jobs)", baseline_jobs
          }
          printf " (%.2fx)\n", wall_sec / baseline_wall_sec
        } else if (dart_sum > 0) {
          printf "  vs %s dart serial (%.2fx)\n", fmt_sec(dart_sum), wall_sec / dart_sum
        } else {
          print ""
        }
      }
      printf "    entry sum:        %s vs %s", fmt_sec(zsass_sum), fmt_sec(dart_sum)
      if (dart_sum > 0) {
        printf "  isolated baseline (%.2fx)\n", zsass_sum / dart_sum
      } else {
        print "  (n/a)"
      }
      if (rss_ratio_rows > 0) {
        printf "    avg rss ratio:    %.2fx\n", rss_ratio_sum / rss_ratio_rows
      } else {
        print "    avg rss ratio:    n/a"
      }
      printf "    measurable time:  %d / %d\n", finite_time_rows, total
      printf "    zero dart rows:   %d / %d\n", zero_dart_rows, total
      if (slowest_zsass_path != "") {
        printf "    slowest entry:    %s (%s)\n", slowest_zsass_path, fmt_sec(slowest_zsass_sec)
      }
      if (worst_time_path != "") {
        printf "    worst time ratio: %s (%.2fx)\n", worst_time_path, worst_time_ratio
      }
      if (worst_rss_path != "") {
        printf "    worst rss ratio:  %s (%.2fx)\n", worst_rss_path, worst_rss_ratio
      }
    }
  ' "$output_file"

  local sorted_time_file finite_time_file finite_rss_file
  sorted_time_file="${output_file%.tsv}.slowest-zsass.tsv"
  finite_time_file="${output_file%.tsv}.worst-time-ratio.tsv"
  finite_rss_file="${output_file%.tsv}.worst-rss-ratio.tsv"

  tail -n +2 "$output_file" | sort -t$'\t' -k2,2gr > "$sorted_time_file"
  awk -F'\t' 'NR > 1 && $7 != "inf"' "$output_file" | sort -t$'\t' -k7,7gr > "$finite_time_file"
  awk -F'\t' 'NR > 1 && $8 != "inf"' "$output_file" | sort -t$'\t' -k8,8gr > "$finite_rss_file"

  echo "  slowest zsass entries:"
  awk -F'\t' '
    function fmt_sec(v) {
      v += 0
      if (v < 0.005) return "<0.01s"
      return sprintf("%.2fs", v)
    }
    function fmt_ratio(v) {
      if (v == "" || v == "inf") return "n/a"
      return sprintf("%.2fx", v + 0)
    }
    NR > 5 { exit }
    {
      printf "    %2d. %7s  dart %7s  ratio %6s  %s\n",
        NR, fmt_sec($2), fmt_sec($5), fmt_ratio($7), $1
    }
  ' "$sorted_time_file"

  echo "  worst finite time ratios:"
  if [[ -s "$finite_time_file" ]]; then
    awk -F'\t' '
      function fmt_sec(v) {
        v += 0
        if (v < 0.005) return "<0.01s"
        return sprintf("%.2fs", v)
      }
      NR > 5 { exit }
      {
        printf "    %2d. %6.2fx  zsass %7s  dart %7s  %s\n",
          NR, $7 + 0, fmt_sec($2), fmt_sec($5), $1
      }
    ' "$finite_time_file"
  else
    echo "    none"
  fi

  echo "  worst rss ratios:"
  if [[ -s "$finite_rss_file" ]]; then
    awk -F'\t' '
      NR > 5 { exit }
      {
        printf "    %2d. %6.2fx  zsass %7s KB  dart %7s KB  %s\n",
          NR, $8 + 0, $3, $6, $1
      }
    ' "$finite_rss_file"
  else
    echo "    none"
  fi
}

run_check() {
  local suite_wall_start suite_wall_end
  summary_file="$run_root/check-summary.tsv"
  metrics_file="$run_root/check-metrics.tsv"
  check_results_dir="$run_root/results"
  check_metrics_dir="$run_root/result-metrics"
  entry_total="${#entries[@]}"
  completed_count=0
  check_failed_index=""
  active_pids=()
  active_indexes=()

  mkdir -p "$check_results_dir" "$check_metrics_dir"

  progress_setup "check" "$entry_total"
  progress_update 0
  suite_wall_start=$(now_sec)

  local entry_index rel
  for (( entry_index = 1; entry_index <= entry_total; entry_index += 1 )); do
    rel="${entries[$((entry_index - 1))]}"
    process_check_entry "$entry_index" "$rel" &
    active_pids+=("$!")
    active_indexes+=("$entry_index")

    while (( ${#active_pids[@]} >= check_jobs )); do
      if ! wait_for_check_job; then
        kill_active_check_jobs
        progress_finish
        rebuild_check_outputs
        print_check_failure_and_die
      fi
    done
  done

  while (( ${#active_pids[@]} > 0 )); do
    if ! wait_for_check_job; then
      kill_active_check_jobs
      progress_finish
      rebuild_check_outputs
      print_check_failure_and_die
    fi
  done

  progress_finish
  suite_wall_end=$(now_sec)
  suite_wall_sec=$(elapsed_sec "$suite_wall_start" "$suite_wall_end")
  suite_worker_count="$check_jobs"
  rebuild_check_outputs
  print_check_summary
  if (( failed_count > 0 || diff_count > 0 || missing_count > 0 )); then
    return 1
  fi

  print_perf_report "$metrics_file" "$run_root/perf-report.tsv" "realworld-suite perf summary"
}

median_of_numbers() {
  printf '%s\n' "$@" | sort -g | awk '
    {
      values[NR] = $1
    }
    END {
      if (NR == 0) {
        exit 1
      }
      if (NR % 2 == 1) {
        print values[(NR + 1) / 2]
      } else {
        printf "%.6f\n", (values[NR / 2] + values[(NR / 2) + 1]) / 2
      }
    }
  '
}

run_bench() {
  local suite_wall_start suite_wall_end
  [[ -n "$perf_baseline_path" ]] || die "missing perf_baseline in suite.env"
  [[ -f "$perf_baseline_path" ]] || die "perf baseline not found: $perf_baseline_path"

  local results_file="$run_root/perf-results.tsv"
  local measured_file="$run_root/bench-metrics.tsv"
  local entry_total="${#entries[@]}"
  printf 'rel_path\tzsass_sec\tzsass_rss_kb\tzsass_exit\n' > "$measured_file"

  local rel input output log time_file run_idx entry_index
  entry_index=0
  progress_setup "bench" "$entry_total"
  progress_update 0
  suite_wall_start=$(now_sec)
  for rel in "${entries[@]}"; do
    entry_index=$((entry_index + 1))
    input=$(entry_input_path "$rel")
    [[ -f "$input" ]] || die "bench entry missing from suite source: $rel"
    progress_update "$entry_index" "$rel"

    load_paths=("${base_load_paths[@]}")
    entry_compile_load_paths "$rel"
    local -a run_secs=()
    local -a run_rss=()
    local last_exit="0"
    for (( run_idx = 1; run_idx <= bench_runs; run_idx += 1 )); do
      output="$run_root/bench/actual/run-$run_idx/$(css_rel_for_entry "$rel")"
      log="$run_root/bench/logs/${rel%.*}.run-$run_idx.log"
      time_file="$run_root/bench/time/${rel%.*}.run-$run_idx.time"
      if ! run_zsass_timed "$bench_timeout" "$input" "$output" "$log" "$time_file" "${compile_load_paths[@]}"; then
        read_timing_file "$time_file"
        tail -n 20 "$log" >&2 || true
        die "bench compile failed for $rel on run $run_idx (exit=${timing_exit})"
      fi
      read_timing_file "$time_file"
      last_exit="$timing_exit"
      run_secs+=("$timing_sec")
      run_rss+=("$timing_rss")
    done

    local median_sec median_rss
    median_sec=$(median_of_numbers "${run_secs[@]}")
    median_rss=$(median_of_numbers "${run_rss[@]}")
    printf '%s\t%s\t%s\t%s\n' "$rel" "$median_sec" "$median_rss" "$last_exit" >> "$measured_file"
  done
  progress_finish
  suite_wall_end=$(now_sec)
  suite_wall_sec=$(elapsed_sec "$suite_wall_start" "$suite_wall_end")
  suite_worker_count=1

  print_perf_report "$measured_file" "$results_file" "realworld-suite bench summary"
  echo "  suite:        $suite_name"
  echo "  root:         $suite_root"
  echo "  runs:         $bench_runs"
}

print_suite_banner() {
  local current="$1"
  local total="$2"
  local suite_dir="$3"
  local label
  if [[ "$current" -gt 0 && "$total" -gt 0 ]]; then
    label=$(printf '%d/%d' "$current" "$total")
    echo "realworld-suite [$label] $(basename "$suite_dir")"
  else
    echo "realworld-suite $(basename "$suite_dir")"
  fi
}

print_multi_suite_summary() {
  local root="$1"
  local total="$2"
  local passed="$3"
  local failed="$4"
  shift 4

  echo "realworld aggregate summary"
  echo "  root:     $root"
  echo "  suites:   $total"
  echo "  passed:   $passed"
  echo "  failed:   $failed"
  if [[ $# -gt 0 ]]; then
    echo "  results:"
    local item
    for item in "$@"; do
      echo "    $item"
    done
  fi
}

run_suite() {
  local suite_dir="$1"
  suite_root="$suite_dir"
  if [[ "$explicit_work_root" != "1" ]]; then
    work_root="$suite_root/.zsass-realworld-runs"
  fi

  read_suite
  base_load_paths=("${load_paths[@]}")
  run_id=$(date +%Y%m%d-%H%M%S)-$$
  run_root="$work_root/$suite_name/$mode/$run_id"
  mkdir -p "$run_root"
  latest_root="$work_root/$suite_name/$mode/latest"
  rm -rf "$latest_root"
  ln -s "$run_root" "$latest_root"

  case "$mode" in
    check) run_check ;;
    bench) run_bench ;;
    *)
      usage
      die "unknown mode: $mode"
      ;;
  esac
}

main() {
  local repo
  repo=$(repo_root)

  mode="check"
  if [[ $# -gt 0 && "$1" != -* ]]; then
    mode="$1"
    shift
  fi

  suite_root="${ZSASS_REALWORLD_SUITE_ROOT:-$repo/../zsass-realworld-fixtures}"
  work_root=""
  explicit_work_root=0
  zsass_bin="$repo/zig-out/bin/zsass"
  normalizer="$repo/scripts/css_normalized_equal.py"
  check_jobs=$(default_check_jobs)
  fail_fast=0
  bench_runs=3

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        [[ $# -ge 2 ]] || die "--mode requires a value"
        mode="$2"
        shift 2
        ;;
      --suite-root)
        [[ $# -ge 2 ]] || die "--suite-root requires a value"
        suite_root=$(absolute_path "$2")
        shift 2
        ;;
      --work-root)
        [[ $# -ge 2 ]] || die "--work-root requires a value"
        work_root=$(absolute_path "$2")
        explicit_work_root=1
        shift 2
        ;;
      --zsass-bin)
        [[ $# -ge 2 ]] || die "--zsass-bin requires a value"
        zsass_bin=$(absolute_path "$2")
        shift 2
        ;;
      --jobs)
        [[ $# -ge 2 ]] || die "--jobs requires a value"
        check_jobs="$2"
        shift 2
        ;;
      --fail-fast)
        fail_fast=1
        shift
        ;;
      --allow-normalized-pass)
        shift
        ;;
      --runs)
        [[ $# -ge 2 ]] || die "--runs requires a value"
        bench_runs="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  [[ -x "$zsass_bin" ]] || die "zsass binary is not executable: $zsass_bin"
  [[ -d "$suite_root" ]] || die "suite root not found: $suite_root"
  [[ "$check_jobs" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"

  local requested_suite_root resolved_suite_root
  requested_suite_root="$suite_root"
  resolved_suite_root=$(absolute_path "$suite_root")

  local -a suite_roots=()
  local line
  while IFS= read -r line; do
    suite_roots+=("$line")
  done < <(collect_suite_roots_arg "$resolved_suite_root")
  [[ ${#suite_roots[@]} -gt 0 ]] || die "no suites resolved under $resolved_suite_root"

  if [[ ${#suite_roots[@]} -eq 1 ]]; then
    run_suite "${suite_roots[0]}"
    return 0
  fi

  local total_suites="${#suite_roots[@]}"
  local passed_suites=0
  local failed_suites=0
  local suite_index=0
  local overall_status=0
  local -a suite_results=()
  local suite_dir
  for suite_dir in "${suite_roots[@]}"; do
    suite_index=$((suite_index + 1))
    if [[ "$suite_index" -gt 1 ]]; then
      echo
    fi
    print_suite_banner "$suite_index" "$total_suites" "$suite_dir"
    if run_suite "$suite_dir"; then
      passed_suites=$((passed_suites + 1))
      suite_results+=("ok    $(basename "$suite_dir")")
    else
      failed_suites=$((failed_suites + 1))
      overall_status=1
      suite_results+=("fail  $(basename "$suite_dir")")
      if [[ "$fail_fast" == "1" ]]; then
        break
      fi
    fi
  done

  echo
  print_multi_suite_summary "$requested_suite_root" "$total_suites" "$passed_suites" "$failed_suites" "${suite_results[@]}"
  return "$overall_status"
}

main "$@"
