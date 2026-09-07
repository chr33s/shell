#!/bin/bash
# Build the Shell Watch companion for the watchOS Simulator and print a
# de-duplicated error summary.
#
# Usage: ./scripts/build-watch.sh [log-path]
#
# The Watch target is built separately from the iOS target on purpose: it does
# not share the iOS bridging header, bundle identity, or Ghostty linker flags
# (spec.watch.md section 18).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="${1:-$ROOT/.derivedData/watch-build.log}"
mkdir -p "$(dirname "$LOG")"

xcodebuild \
    -project "$ROOT/shell.xcodeproj" \
    -scheme ShellWatch \
    -configuration Debug \
    -destination 'generic/platform=watchOS Simulator' \
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
