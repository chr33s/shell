#!/bin/bash
# Confirm a pending Watch enrollment against the development broker.
#
# Usage: ./scripts/dev-confirm.sh <USER-CODE> [port]
#
# This stands in for the authenticated browser page: device enrollment requires
# account administration, not an ordinary decision credential, so it presents
# the admin secret that ./scripts/run-broker.sh generated.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODE="${1:?usage: dev-confirm.sh <USER-CODE> [port]}"
PORT="${2:-8443}"
# shellcheck disable=SC1090
. "$ROOT/.derivedData/dev-broker.env"

echo "--- what is being granted ---"
curl -sS -H "Authorization: Admin ${SHELL_CONTROL_ADMIN_SECRET}" \
    "http://localhost:${PORT}/v1/oauth/confirm?user_code=${CODE}"
echo
echo "--- confirming ---"
curl -sS -X POST \
    -H "Authorization: Admin ${SHELL_CONTROL_ADMIN_SECRET}" \
    -H "Content-Type: application/json" \
    -d "{\"user_code\":\"${CODE}\",\"approve\":true}" \
    "http://localhost:${PORT}/v1/oauth/confirm"
echo
