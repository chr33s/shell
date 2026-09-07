#!/bin/bash
# Build, install, and launch Shell Watch on the watchOS Simulator, pointed at a
# broker.
#
# Usage: ./scripts/run-watch.sh [broker-url] [simulator-name]
#
# Defaults to the development broker from ./scripts/run-broker.sh. The
# simulator shares the Mac's network stack, so http://localhost works — and
# loopback plain HTTP is the one case the client accepts without TLS.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BROKER="${1:-http://localhost:8443}"
DEVICE="${2:-Apple Watch Series 11 (46mm)}"
LOG="$ROOT/.derivedData/watch-run.log"
mkdir -p "$ROOT/.derivedData"

# xcconfig treats `//` as a comment, so the URL is split with `$()` the same way
# Configuration/Watch.xcconfig does. sed keeps this the same under bash and zsh.
ESCAPED="$(printf '%s' "$BROKER" | sed 's|://|:/$()/|')"

xcodebuild \
    -project "$ROOT/shell.xcodeproj" \
    -scheme ShellWatch \
    -configuration Debug \
    -destination "platform=watchOS Simulator,name=${DEVICE}" \
    -derivedDataPath "$ROOT/.derivedData" \
    SHELL_CONTROL_BROKER_URL="$ESCAPED" \
    build > "$LOG" 2>&1
status=$?
if [ $status -ne 0 ]; then
    echo "exit=$status"
    grep "error:" "$LOG" | sed "s|$ROOT/||" | sort -u | head -20
    exit $status
fi

APP="$ROOT/.derivedData/Build/Products/Debug-watchsimulator/ShellWatch.app"
CONFIGURED="$(/usr/libexec/PlistBuddy -c 'Print :SHELLControlBrokerURL' "$APP/Info.plist" 2>/dev/null)"
echo "broker in bundle: ${CONFIGURED}"

xcrun simctl boot "$DEVICE" 2>/dev/null
xcrun simctl bootstatus "$DEVICE" -b > /dev/null 2>&1
xcrun simctl install "$DEVICE" "$APP" || exit 1
xcrun simctl launch --console-pty "$DEVICE" dev.chr33s.shell.watchkitapp
