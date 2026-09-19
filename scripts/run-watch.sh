#!/bin/bash
# Build, install, and launch Shell Watch on the watchOS Simulator.
#
# Usage: ./scripts/run-watch.sh [simulator-name]
#
# The Watch has no broker URL: it reaches the Mac only through its paired
# iPhone over WatchConnectivity (spec.iphone-gateway.md). Run the phone app on
# the paired iPhone simulator and pair it with `shell-control setup
# --mode loopback` for an end-to-end simulator loop.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE="${1:-Apple Watch Series 11 (46mm)}"
LOG="$ROOT/.derivedData/watch-run.log"
mkdir -p "$ROOT/.derivedData"

xcodebuild \
    -project "$ROOT/shell.xcodeproj" \
    -scheme ShellWatch \
    -configuration Debug \
    -destination "platform=watchOS Simulator,name=${DEVICE}" \
    -derivedDataPath "$ROOT/.derivedData" \
    build > "$LOG" 2>&1
status=$?
if [ $status -ne 0 ]; then
    echo "exit=$status"
    grep "error:" "$LOG" | sed "s|$ROOT/||" | sort -u | head -20
    exit $status
fi

APP="$ROOT/.derivedData/Build/Products/Debug-watchsimulator/ShellWatch.app"
xcrun simctl boot "$DEVICE" 2>/dev/null
xcrun simctl bootstatus "$DEVICE" -b > /dev/null 2>&1
xcrun simctl install "$DEVICE" "$APP" || exit 1
xcrun simctl launch --console-pty "$DEVICE" dev.chr33s.shell.watchkitapp
