#!/bin/bash
# Run the ShellTests unit-test bundle on the iOS Simulator and print a
# de-duplicated error summary plus a pass/fail tally.
#
# Usage: ./scripts/test.sh [log-path]
#
# The destination MUST be an iOS Simulator, never Mac Catalyst: the entire
# local-shell stack (ShellTokenizer, ShellParser, ShellInterpreter, ShellJobs,
# Features/LocalShell, ...) sits behind `#if !targetEnvironment(macCatalyst)`
# and does not exist on a Catalyst destination, so the tests do not compile
# there. Named rather than UDID destination so it survives a simulator reset.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="${1:-$ROOT/.derivedData/test.log}"
mkdir -p "$(dirname "$LOG")"

xcodebuild \
    -project "$ROOT/shell.xcodeproj" \
    -scheme shell \
    -configuration Debug \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
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

grep -E "^Test Case .* (passed|failed)" "$LOG" \
    | sed "s|$ROOT/||" \
    | sort \
    | uniq \
    | head -200
echo "--- passed: $(grep -cE "^Test Case .* passed" "$LOG") failed: $(grep -cE "^Test Case .* failed" "$LOG") ---"
grep -E '^\*\* TEST (SUCCEEDED|FAILED) \*\*' "$LOG" | tail -1
exit $status
