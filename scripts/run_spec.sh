#!/bin/bash
# Spec test runner wrapper - always saves output to timestamped log file
set -euo pipefail

SPEC_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)/tests/sass-spec/spec}"
LOG_DIR="$(cd "$(dirname "$0")/.." && pwd)/logs"
mkdir -p "$LOG_DIR"

LOGFILE="$LOG_DIR/spec_$(date +%Y%m%d_%H%M%S).log"

cd "$(dirname "$0")/.."
zig build spec -- --spec-dir "$SPEC_DIR" 2>&1 | tee "$LOGFILE"

echo ""
echo "Log saved: $LOGFILE"
