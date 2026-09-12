#!/bin/bash
# Native CLI unit/integration tests. Test fixtures use isolated state roots and
# fake service ownership; this script never addresses a developer installation.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/cmd"
swift build --product shell-control
swift test

# Parser smoke checks against the built executable. No command may create this
# root while parsing help, version, or an invalid invocation.
STATE="$(mktemp -d "${TMPDIR:-/tmp}/shell-native-cli.XXXXXX")/state"
trap 'rm -rf "$(dirname "$STATE")"' EXIT
SHELL_CONTROL_STATE_DIR="$STATE" .build/debug/shell-control >/dev/null
test ! -e "$STATE"
SHELL_CONTROL_STATE_DIR="$STATE" .build/debug/shell-control --version >/dev/null
test ! -e "$STATE"
if SHELL_CONTROL_STATE_DIR="$STATE" .build/debug/shell-control setup --port 0 extra >/dev/null 2>&1; then
  echo "invalid invocation unexpectedly succeeded" >&2; exit 1
fi
test ! -e "$STATE"
