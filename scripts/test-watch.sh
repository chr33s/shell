#!/bin/bash
# Run the ShellWatchTests bundle on the watchOS Simulator and print a
# de-duplicated error summary plus a pass/fail tally.
#
# Usage: ./scripts/test-watch.sh [log-path]
#
# ShellWatchTests is hosted by ShellWatch.app, which is a Watch-only app
# (WKWatchOnly), so it installs and runs without a paired iPhone app.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="${1:-$ROOT/.derivedData/watch-test.log}"
mkdir -p "$(dirname "$LOG")"

xcodebuild \
    -project "$ROOT/shell.xcodeproj" \
    -scheme ShellWatchTests \
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

grep -E "^Test case .* (passed|failed) on" "$LOG" | sort | uniq | head -200
echo "--- passed: $(grep -cE "^Test case .* passed on" "$LOG") failed: $(grep -cE "^Test case .* failed on" "$LOG") ---"
exit $status
