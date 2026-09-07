#!/bin/bash
# Run the ShellWatchTests bundle on the watchOS Simulator and print a
# de-duplicated error summary plus a pass/fail tally.
#
# Usage: ./scripts/test-watch.sh [log-path]
#
# ShellWatchTests is hosted by ShellWatch.app and runs from the shared
# ShellWatch scheme, whose test action covers the bundle. ShellWatch.app is
# embedded in the iPhone app but runs independently of it
# (WKRunsIndependentlyOfCompanionApp), so it installs without one.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="${1:-$ROOT/.derivedData/watch-test.log}"
mkdir -p "$(dirname "$LOG")"

xcodebuild \
    -project "$ROOT/shell.xcodeproj" \
    -scheme ShellWatch \
    -configuration Debug \
    -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' \
    -derivedDataPath "$ROOT/.derivedData" \
    test > "$LOG" 2>&1
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

grep -iE "test case .* (passed|failed)( on| \()" "$LOG" | sort | uniq | head -200
echo "--- passed: $(grep -ciE "test case .* passed( on| \()" "$LOG") failed: $(grep -ciE "test case .* failed( on| \()" "$LOG") ---"
exit $status
