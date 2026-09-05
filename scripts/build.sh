#!/bin/bash
# Build Shell for the iOS Simulator and print a de-duplicated error summary.
#
# Usage: ./scripts/build.sh [log-path]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="${1:-$ROOT/.derivedData/build.log}"
mkdir -p "$(dirname "$LOG")"

xcodebuild \
    -project "$ROOT/shell.xcodeproj" \
    -scheme shell \
    -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$ROOT/.derivedData" \
    build > "$LOG" 2>&1
status=$?

echo "exit=$status"
grep "error:" "$LOG" \
    | sed "s|$ROOT/||" \
    | sed 's/:[0-9]*:[0-9]*: error: /: /' \
    | sort \
    | uniq -c \
    | sort -rn \
    | head -60
echo "--- error count: $(grep -c 'error:' "$LOG") ---"
exit $status
