#!/bin/bash
# Test the control protocol package, the broker, and the host daemon/CLI.
#
# Usage: ./scripts/test-control.sh
#
# These are plain SwiftPM packages, so they run on the Mac toolchain without a
# simulator. `scripts/test.sh` still covers the iOS app.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
status=0

for package in "Packages/ShellControlCore" "services/shell-control" "cmd"; do
    echo "=== $package ==="
    ( cd "$ROOT/$package" && swift test 2>&1 ) | tee "/tmp/shell-control-$(basename "$package").log" \
        | grep -E "error:|Executed [0-9]+ tests" | sort -u
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then status=1; fi
done

exit $status
