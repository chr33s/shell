#!/bin/bash
# Run the ShellTests unit-test bundle and print a de-duplicated error summary
# plus a pass/fail tally.
#
# Usage: ./scripts/test.sh [--ios | --catalyst] [log-path]
#
#   --ios        iOS Simulator, iPhone 17 (default). Named rather than UDID
#                destination so it survives a simulator reset.
#   --catalyst   My Mac (Mac Catalyst). The local-shell stack (ShellTokenizer,
#                ShellParser, ShellInterpreter, ShellJobs, Features/LocalShell)
#                compiles on every platform since LocalShellBackend made the
#                ios_system interpreter the sandboxed Catalyst shell (spec 9.6),
#                so the same tests run here. Each destination gets its own log
#                so two runs do not overwrite each other.
#
# Catalyst needs the ios_system product linked without a platform filter in
# the shell target's Frameworks phase; with the filter the build fails on
# "no such module 'ios_system'" before any test runs.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DESTINATION='platform=iOS Simulator,name=iPhone 17'
FLAVOR=ios
case "${1:-}" in
    --catalyst)
        DESTINATION='platform=macOS,variant=Mac Catalyst'
        FLAVOR=catalyst
        shift
        ;;
    --ios)
        shift
        ;;
esac

LOG="${1:-$ROOT/.derivedData/test-$FLAVOR.log}"
mkdir -p "$(dirname "$LOG")"

echo "destination=$DESTINATION"
xcodebuild \
    -project "$ROOT/shell.xcodeproj" \
    -scheme shell \
    -configuration Debug \
    -destination "$DESTINATION" \
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

# XCTest reports "Test Case ... passed"; Swift Testing reports "✔ Test ..." and
# "✘ Test ...", plus one "Test run with N tests" summary. Count both.
grep -E "^Test Case .* (passed|failed)|^✘ " "$LOG" \
    | sed "s|$ROOT/||" \
    | sort \
    | uniq \
    | head -200
xctest_passed=$(grep -cE "^Test Case .* passed" "$LOG")
xctest_failed=$(grep -cE "^Test Case .* failed" "$LOG")
swift_passed=$(grep -cE "^✔ Test " "$LOG")
swift_failed=$(grep -cE "^✘ Test " "$LOG")
echo "--- passed: $((xctest_passed + swift_passed)) failed: $((xctest_failed + swift_failed)) ---"
grep -E "Test run with [0-9]+ tests" "$LOG" | tail -1
grep -E '^\*\* TEST (SUCCEEDED|FAILED) \*\*' "$LOG" | tail -1
exit $status
