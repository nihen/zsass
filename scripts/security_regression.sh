#!/usr/bin/env bash
# Run generated deep-nesting, endless-loop, and @extend-expansion inputs
# through a zsass binary and require a controlled limit error for each: exit
# code 65 with the expected message, never a crash, a hang, or an allocator
# failure. The unit tests assert the limits; this catches what only a
# release build can show, such as a native stack overflow.
#
# Usage: scripts/security_regression.sh <zsass-binary>
set -euo pipefail

zsass="${1:?usage: $0 <zsass-binary>}"
time_limit="${ZSASS_SECURITY_TIMEOUT:-20}"
# Virtual memory cap in KiB for each compile.
memory_limit="${ZSASS_SECURITY_MEMORY_KB:-1048576}"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

repeat() {
  local text="$1" count="$2"
  local i
  for ((i = 0; i < count; i++)); do printf '%s' "${text}"; done
}

{ printf 'a{x:'; repeat '(' 16000; printf '1'; repeat ')' 16000; printf ';}\n'; } > "${work}/parens.scss"
{ repeat 'a{' 8000; printf 'x:y;'; repeat '}' 8000; printf '\n'; } > "${work}/rules.scss"
{ printf 'a{x:1'; repeat '+1' 20000; printf ';}\n'; } > "${work}/chain.scss"
{ printf 'a{x:'; repeat '#{' 20000; printf '1'; repeat '}' 20000; printf ';}\n'; } > "${work}/interp.scss"
# shellcheck disable=SC2016 # Sass variables, not shell expansions.
printf '%s\n' '$l: 1; @for $i from 1 through 100000 { $l: [$l]; } a { x: inspect($l); }' > "${work}/values.scss"
printf '%s\n' '@function spin() { @while true {} @return 1; } a { x: spin(); }' > "${work}/spin.scss"
printf '%s\n' '@while true {}' > "${work}/while.scss"
# shellcheck disable=SC2016
printf '%s\n' '@for $i from 1 through 1000000000 {}' > "${work}/for.scss"
# shellcheck disable=SC2016
printf '%s\n' '$s: a; @for $i from 1 through 40 { $s: $s + $s; } a { x: str-length($s); }' > "${work}/doubling.scss"
# shellcheck disable=SC2016
printf '%s\n' '$l: 1px; @for $i from 1 through 20000 { $l: calc($l + 1%); } a { x: $l; }' > "${work}/calc.scss"
for n in 14 20; do
  {
    for ((i = 0; i < n; i++)); do printf '.a%d ' "${i}"; done
    printf '{x:y}\n'
    for ((i = 0; i < n; i++)); do printf '.x%d {@extend .a%d}\n' "${i}" "${i}"; done
  } > "${work}/extend${n}.scss"
done

failures=0
expect() {
  local name="$1" pattern="$2" cap="${3:-${memory_limit}}"
  local status=0
  (
    ulimit -v "${cap}"
    exec timeout "${time_limit}" "${zsass}" --no-source-map "${work}/${name}.scss"
  ) > /dev/null 2> "${work}/${name}.err" || status=$?
  if [[ "${status}" -eq 65 ]] && grep -Eq "${pattern}" "${work}/${name}.err"; then
    printf 'ok      %s\n' "${name}"
  else
    printf 'FAILED  %s (exit %d)\n' "${name}" "${status}"
    sed -n '1,5p' "${work}/${name}.err"
    failures=$((failures + 1))
  fi
}

expect parens 'Syntax nesting limit exceeded'
expect rules 'Syntax nesting limit exceeded'
expect chain 'Syntax nesting limit exceeded'
expect interp 'Syntax nesting limit exceeded'
expect values 'Nesting limit exceeded'
expect spin 'Execution step limit exceeded'
expect while 'limit exceeded'
expect for 'limit exceeded'
expect extend14 'Selector expansion limit exceeded'
expect extend20 'Selector expansion limit exceeded'
# The default memory limit is 2 GiB, so these run under a larger cap.
expect doubling 'Memory limit exceeded' 4194304
expect calc 'Memory limit exceeded' 4194304

if [[ "${failures}" -ne 0 ]]; then
  printf '%d security regression case(s) failed\n' "${failures}"
  exit 1
fi
