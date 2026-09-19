#!/bin/bash
# Run a development Shell Control broker on localhost.
#
# Usage: ./scripts/run-broker.sh [port]
#
# It generates an account id, an admin secret, a cursor secret, and a Shell
# origin identity (ID plus P-256 signing key) on first run and keeps them in
# .derivedData so the same state file keeps working across restarts. This is a
# development service: it speaks plain HTTP on loopback, which the iPhone
# accepts only as a `loopback_http` route in the simulator. Pair with
# ./scripts/dev-pair.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${1:-8443}"
ENV_FILE="$ROOT/.derivedData/dev-broker.env"
mkdir -p "$ROOT/.derivedData"

if [ ! -f "$ENV_FILE" ]; then
    cat > "$ENV_FILE" <<ENV
SHELL_CONTROL_ACCOUNT_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
SHELL_CONTROL_ADMIN_SECRET=$(head -c 32 /dev/urandom | xxd -p -c 64)
SHELL_CONTROL_CURSOR_SECRET=$(head -c 32 /dev/urandom | xxd -p -c 64)
SHELL_CONTROL_ORIGIN_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
ENV
    echo "wrote $ENV_FILE"
fi
# Environments written before the gateway profile have no origin id yet.
if ! grep -q '^SHELL_CONTROL_ORIGIN_ID=' "$ENV_FILE"; then
    echo "SHELL_CONTROL_ORIGIN_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')" >> "$ENV_FILE"
fi
ORIGIN_KEY="$ROOT/.derivedData/dev-origin-key.pem"
if [ ! -f "$ORIGIN_KEY" ]; then
    ( umask 077 && openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$ORIGIN_KEY" ) || exit 1
    echo "wrote $ORIGIN_KEY"
fi
# shellcheck disable=SC1090
. "$ENV_FILE"

# A broker already on this port would otherwise fail deep in bind(2).
EXISTING="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -1)"
if [ -n "$EXISTING" ]; then
    echo "port ${PORT} is already in use by pid ${EXISTING}:" >&2
    ps -p "$EXISTING" -o pid=,command= >&2
    echo "stop it first (kill ${EXISTING}), or pass a different port: ./scripts/run-broker.sh 8444" >&2
    exit 1
fi

( cd "$ROOT/services/shell-control" && swift build -c release ) || exit 1

echo "broker:     http://localhost:${PORT}"
echo "account:    ${SHELL_CONTROL_ACCOUNT_ID}"
echo "origin:     ${SHELL_CONTROL_ORIGIN_ID:-}"
echo "pair with:  ./scripts/dev-pair.sh"
echo "confirm at: ./scripts/dev-confirm.sh <USER-CODE>"

SHELL_CONTROL_PORT="$PORT" \
SHELL_CONTROL_STATE="$ROOT/.derivedData/dev-broker.json" \
SHELL_CONTROL_ACCOUNT_ID="$SHELL_CONTROL_ACCOUNT_ID" \
SHELL_CONTROL_ADMIN_SECRET="$SHELL_CONTROL_ADMIN_SECRET" \
SHELL_CONTROL_CURSOR_SECRET="$SHELL_CONTROL_CURSOR_SECRET" \
SHELL_CONTROL_VERIFICATION_URI="http://localhost:${PORT}/v1/oauth/confirm" \
SHELL_CONTROL_APNS_TOPICS="dev.chr33s.shell.watchkitapp,dev.chr33s.shell" \
SHELL_CONTROL_IDENTITY="shell-control-dev" \
SHELL_CONTROL_ORIGIN_ID="$SHELL_CONTROL_ORIGIN_ID" \
SHELL_CONTROL_ORIGIN_KEY_FILE="$ORIGIN_KEY" \
exec "$ROOT/services/shell-control/.build/release/shell-control-broker"
