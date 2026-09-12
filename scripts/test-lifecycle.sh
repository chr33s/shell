#!/bin/bash
# Isolated CLI lifecycle tests. They never touch a developer's real
# ~/.local/state/shell-control or LaunchAgents.
#
# Usage: ./scripts/test-lifecycle.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SHELL_CONTROL_STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shell-lifecycle.XXXXXX")"
export SHELL_CONTROL_LIB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shell-lib.XXXXXX")"
export SHELL_CONTROL_LAUNCH_AGENTS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shell-agents.XXXXXX")"
trap 'rm -rf "$SHELL_CONTROL_STATE_DIR" "$SHELL_CONTROL_LIB_DIR" "$SHELL_CONTROL_LAUNCH_AGENTS_DIR"' EXIT

cd "$ROOT"
node --test cli/src/lifecycle.test.ts cli/src/cli.test.ts cli/src/services.test.ts cli/src/state.test.ts cli/src/tunnel.test.ts cli/src/health.test.ts
